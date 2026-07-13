<#
  Diagnostics.psm1 - environment health tooling for the Directory Services
  Management Tool: discover domain controllers, probe Windows services,
  check Exchange components, and send/simulate a test message.

  Requires the ActiveDirectory module (RSAT) for discovery. Service probes use
  Get-Service -ComputerName (RPC to the remote Service Control Manager), so the
  targets must allow the 'Remote Service Management' firewall rules and the API
  service account needs remote query rights on them. ICMP ping is used only as
  a hint - probing still proceeds when ping is blocked.
#>

function Get-DomainControllers {
    <#
      Discovers DCs three ways (first that works wins):
        1. Get-ADDomainController (native, transitive)
        2. members of the 'Domain Controllers' security group
        3. objects under the Domain Controllers OU
    #>
    param([string] $Method = 'auto')
    Import-Module ActiveDirectory -ErrorAction Stop
    $dcs = @()
    if ($Method -in @('auto','native')) {
        try { $dcs = Get-ADDomainController -Filter * | Select-Object -Expand HostName } catch {}
    }
    if (-not $dcs -and $Method -in @('auto','group')) {
        try { $dcs = Get-ADGroupMember 'Domain Controllers' | ForEach-Object { (Get-ADComputer $_).DNSHostName } } catch {}
    }
    if (-not $dcs -and $Method -in @('auto','ou')) {
        try {
            $base = (Get-ADDomain).DistinguishedName
            $dcs = Get-ADComputer -SearchBase "OU=Domain Controllers,$base" -Filter * |
                   Select-Object -Expand DNSHostName
        } catch {}
    }
    return @($dcs | Sort-Object -Unique)
}

# Core services that should be running on a healthy DC.
$script:DcServices = 'NTDS','DNS','Netlogon','KDC','W32Time','DFSR','ADWS'

function Test-DcServices {
    <# Probes the standard DC services on each host. Ping is only a hint: when
       ICMP is blocked the RPC service query is attempted anyway, and the host
       counts as reachable if any service answers. If the host looks truly dead
       (ping fails AND the Service Control Manager cannot be opened), remaining
       probes are skipped to avoid stacking RPC timeouts. #>
    param([string[]] $Hosts, [string[]] $Services = $script:DcServices)
    $out = @()
    foreach ($h in $Hosts) {
        $svcResults = @()
        $ping = Test-Connection -ComputerName $h -Count 1 -Quiet -ErrorAction SilentlyContinue
        $answered = $false
        $scmDown  = $false
        foreach ($s in $Services) {
            $state = 'unknown'
            if (-not $scmDown) {
                try { $state = (Get-Service -ComputerName $h -Name $s -ErrorAction Stop).Status.ToString(); $answered = $true }
                catch {
                    if ($_.Exception -is [Microsoft.PowerShell.Commands.ServiceCommandException]) { $state = 'missing'; $answered = $true }
                    elseif ($ping) { $state = 'missing' }
                    else { $scmDown = $true }
                }
            }
            $svcResults += [pscustomobject]@{ name = $s; status = $state }
        }
        $reachable = ([bool]$ping -or $answered)
        $running = ($svcResults | Where-Object { $_.status -eq 'Running' }).Count
        $out += [pscustomobject]@{
            host = $h; reachable = $reachable
            healthy = ($reachable -and $running -eq $Services.Count)
            running = $running; total = $Services.Count
            services = $svcResults
        }
    }
    return $out
}

# Exchange server roles/services to verify.
$script:ExchangeServices = @(
    'MSExchangeADTopology','MSExchangeIS','MSExchangeTransport',
    'MSExchangeFrontendTransport','MSExchangeMailboxAssistants',
    'MSExchangeRPC','MSExchangeServiceHost','W3SVC'
)

function Test-ExchangeServer {
    <# Checks the main Exchange component services on a host. Same ping-is-only-
       a-hint behavior as Test-DcServices. #>
    param([Parameter(Mandatory)][string] $ExchangeHost, [string[]] $Services = $script:ExchangeServices)
    $ping = Test-Connection -ComputerName $ExchangeHost -Count 1 -Quiet -ErrorAction SilentlyContinue
    $results = @()
    $answered = $false
    $scmDown  = $false
    foreach ($s in $Services) {
        $state = 'unknown'
        if (-not $scmDown) {
            try { $state = (Get-Service -ComputerName $ExchangeHost -Name $s -ErrorAction Stop).Status.ToString(); $answered = $true }
            catch {
                if ($_.Exception -is [Microsoft.PowerShell.Commands.ServiceCommandException]) { $state = 'missing'; $answered = $true }
                elseif ($ping) { $state = 'missing' }
                else { $scmDown = $true }
            }
        }
        $results += [pscustomobject]@{ name = $s; status = $state }
    }
    $reachable = ([bool]$ping -or $answered)
    $running = ($results | Where-Object { $_.status -eq 'Running' }).Count
    return [pscustomobject]@{
        host = $ExchangeHost; reachable = $reachable
        healthy = ($reachable -and $running -eq $Services.Count)
        running = $running; total = $Services.Count; services = $results
    }
}

function Test-DcReplication {
    <# Summarizes AD replication health per DC using the native
       Get-ADReplicationPartnerMetadata cmdlet (no external tooling) - for
       each partner link, whether the last attempt succeeded and how long
       since the last successful replication. #>
    param([Parameter(Mandatory)][string[]] $Hosts)
    Import-Module ActiveDirectory -ErrorAction Stop
    $out = @()
    foreach ($h in $Hosts) {
        try {
            $partners = @(Get-ADReplicationPartnerMetadata -Target $h -Scope Server -ErrorAction Stop)
            $failed = @($partners | Where-Object { $_.LastReplicationResult -ne 0 })
            $oldestSuccess = $partners | Sort-Object LastReplicationSuccess | Select-Object -First 1
            $out += [pscustomobject]@{
                host = $h; ok = ($failed.Count -eq 0); partnerCount = $partners.Count; failedCount = $failed.Count
                oldestSuccess = if ($oldestSuccess) { $oldestSuccess.LastReplicationSuccess.ToString('yyyy-MM-dd HH:mm') } else { $null }
                detail = if ($failed.Count -gt 0) { ($failed | ForEach-Object { "$($_.Partner): $($_.LastReplicationResult)" }) -join '; ' } else { 'All partners replicating cleanly' }
            }
        } catch {
            $out += [pscustomobject]@{ host = $h; ok = $false; partnerCount = 0; failedCount = 0; oldestSuccess = $null; detail = $_.Exception.Message }
        }
    }
    return $out
}

function Test-DcHealth {
    <# Runs the native dcdiag.exe (present on every DC / any machine with
       RSAT-AD-Tools) against a target in quiet mode and parses its
       PASS/FAIL summary lines - the standard "is this DC healthy" tool
       AD admins already know, rather than reinventing its checks. #>
    param([Parameter(Mandatory)][string] $DcHost, [int] $TimeoutSeconds = 60)
    $exe = Get-Command dcdiag.exe -ErrorAction SilentlyContinue
    if (-not $exe) {
        return [pscustomobject]@{ host = $DcHost; ok = $null; tests = @(); detail = 'dcdiag.exe not found on this machine (install RSAT: Active Directory Domain Services Tools).' }
    }
    try {
        $raw = & dcdiag.exe /s:$DcHost /q 2>&1 | Out-String
        $lines = @($raw -split "`r?`n" | Where-Object { $_ -match '\.\.\.\.\.\.\.\.\.\.\.\.\.\.\.\.\.\.\.\.\.\. (\S+) (passed|failed) test (\S+)' })
        $tests = @()
        foreach ($l in $lines) {
            if ($l -match '\.\.\.\.\.\.\.\.\.\.\.\.\.\.\.\.\.\.\.\.\.\. (\S+) (passed|failed) test (\S+)') {
                $tests += [pscustomobject]@{ target = $Matches[1]; result = $Matches[2]; name = $Matches[3] }
            }
        }
        $failed = @($tests | Where-Object { $_.result -eq 'failed' })
        return [pscustomobject]@{
            host = $DcHost; ok = ($tests.Count -gt 0 -and $failed.Count -eq 0); tests = $tests
            detail = if ($tests.Count -eq 0) { 'dcdiag produced no parseable test lines - see raw output.' }
                     elseif ($failed.Count -gt 0) { ($failed | ForEach-Object { $_.name }) -join ', ' }
                     else { "$($tests.Count) tests passed" }
        }
    } catch {
        return [pscustomobject]@{ host = $DcHost; ok = $false; tests = @(); detail = $_.Exception.Message }
    }
}

function New-DiagnosticsReportBody {
    <# Composes a plain-text report from whatever check results are passed
       in - used by both the on-demand "Run now" API call and the
       scheduled-task entry script, so the email content is identical
       either way. #>
    param($DcResults = @(), $ReplicationResults = @(), $HealthResults = @(), $ExchangeResults = @())
    $lines = @()
    $lines += "DSMT diagnostics report - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
    $lines += ''
    if ($DcResults.Count -gt 0) {
        $lines += '== Domain controller services =='
        foreach ($d in $DcResults) { $lines += "  $($d.host): $($d.running)/$($d.total) services running $(if($d.healthy){'(healthy)'}else{'(ATTENTION)'})" }
        $lines += ''
    }
    if ($ReplicationResults.Count -gt 0) {
        $lines += '== Replication =='
        foreach ($r in $ReplicationResults) { $lines += "  $($r.host): $(if($r.ok){'OK'}else{'ATTENTION'}) - $($r.detail)" }
        $lines += ''
    }
    if ($HealthResults.Count -gt 0) {
        $lines += '== Extended health (dcdiag) =='
        foreach ($h in $HealthResults) { $lines += "  $($h.host): $(if($h.ok){'OK'}else{'ATTENTION'}) - $($h.detail)" }
        $lines += ''
    }
    if ($ExchangeResults.Count -gt 0) {
        $lines += '== Exchange services =='
        foreach ($e in $ExchangeResults) { $lines += "  $($e.host): $($e.running)/$($e.total) services running $(if($e.healthy){'(healthy)'}else{'(ATTENTION)'})" }
        $lines += ''
    }
    return ($lines -join "`n")
}

function Send-DiagnosticsReport {
    <# End-to-end: runs whichever checks have hosts configured, builds the
       report body, and emails it via Send-TestMessage using the saved SMTP
       config. Shared by the "Run now" API route and the scheduled-task
       entry script (Send-DiagReport.ps1) so behavior never diverges
       between the two trigger paths. #>
    param(
        [Parameter(Mandatory)] $Smtp,
        [string[]] $DcHosts = @(),
        [string[]] $ExchangeHosts = @(),
        [Parameter(Mandatory)][string[]] $Recipients
    )
    $dcResults = @(); $replResults = @(); $healthResults = @(); $exResults = @()
    if ($DcHosts.Count -gt 0) {
        $dcResults = @(Test-DcServices -Hosts $DcHosts)
        try { $replResults = @(Test-DcReplication -Hosts $DcHosts) } catch {}
        foreach ($h in $DcHosts) { $healthResults += (Test-DcHealth -DcHost $h) }
    }
    foreach ($h in $ExchangeHosts) { $exResults += (Test-ExchangeServer -ExchangeHost $h) }
    $body = New-DiagnosticsReportBody -DcResults $dcResults -ReplicationResults $replResults -HealthResults $healthResults -ExchangeResults $exResults
    $anyFailure = (@($dcResults) + @($replResults) + @($healthResults) + @($exResults)) | Where-Object { $_.healthy -eq $false -or $_.ok -eq $false }
    $subject = if ($anyFailure) { 'DSMT diagnostics report - ATTENTION NEEDED' } else { 'DSMT diagnostics report - all clear' }
    $sendResult = $null
    foreach ($to in $Recipients) {
        $sendResult = Send-TestMessage -SmtpServer $Smtp.Server -Port ([int]$Smtp.Port) -To $to -From $Smtp.From -Subject $subject -Body $body -Username $Smtp.Username -Password $Smtp.Password -UseTls:([bool]$Smtp.UseTls)
    }
    return [pscustomobject]@{ ok = $true; subject = $subject; body = $body; sendResult = $sendResult; dcResults = $dcResults; replResults = $replResults; healthResults = $healthResults; exResults = $exResults }
}

function Send-TestMessage {
    <#
      Sends a test email via an SMTP server, OR simulates it (no send) when
      -Simulate is set - useful for verifying mail flow / connectors safely.
      Supports authenticated (username/password) and TLS submission.
    #>
    param(
        [Parameter(Mandatory)][string] $SmtpServer,
        [Parameter(Mandatory)][string] $To,
        [string] $From = 'dsmt@lab.local',
        [string] $Subject = 'DSMT test message',
        [string] $Body = 'This is a test message from the Directory Services Management Tool.',
        [int] $Port = 25,
        [switch] $Simulate,
        [string] $Username = $null,
        [string] $Password = $null,
        [switch] $UseTls
    )
    $useAuth = -not [string]::IsNullOrWhiteSpace($Username)
    if ($Simulate) {
        $detail = "Would send to $To via $SmtpServer`:$Port"
        if ($useAuth) { $detail += " (authenticated as $Username" + $(if ($UseTls) { ', TLS' } else { '' }) + ')' }
        return [pscustomobject]@{ ok = $true; simulated = $true; detail = "$detail (no message sent)." }
    }
    try {
        $params = @{ SmtpServer = $SmtpServer; Port = $Port; To = $To; From = $From; Subject = $Subject; Body = $Body; ErrorAction = 'Stop' }
        if ($UseTls) { $params['UseSsl'] = $true }
        if ($useAuth) {
            $sec = ConvertTo-SecureString $Password -AsPlainText -Force
            $params['Credential'] = New-Object System.Management.Automation.PSCredential ($Username, $sec)
        }
        Send-MailMessage @params
        return [pscustomobject]@{ ok = $true; simulated = $false; detail = "Message sent to $To." }
    } catch {
        return [pscustomobject]@{ ok = $false; simulated = $false; detail = $_.Exception.Message }
    }
}

function Get-RemoteEvents {
    <# Reads a remote Windows server's event log via Get-WinEvent -ComputerName -
       the same RPC channel the graphical Event Viewer uses, so no RDP session is
       needed. Target requires the 'Remote Event Log Management' firewall rules
       and the caller needs Event Log Readers (or admin) rights on it. #>
    param(
        [Parameter(Mandatory)][string] $Server,
        [string] $LogName = 'System',
        [int]    $Hours = 24,
        [int[]]  $Levels = @(1,2,3),   # 1=Critical 2=Error 3=Warning
        [string] $Query = '',
        [int]    $Top = 200
    )
    $filter = @{ LogName = $LogName; StartTime = (Get-Date).AddHours(-1 * $Hours) }
    if ($Levels -and $Levels.Count -gt 0) { $filter['Level'] = $Levels }
    # Get-WinEvent throws "No events were found that match the specified
    # selection criteria" when the filter is valid but simply matches zero
    # events - a normal, successful outcome (nothing happened), not a
    # failure. Without this the API returned it as a 400 and the console
    # rendered a red "query failed" error for what is really an empty result.
    try {
        $events = @(Get-WinEvent -ComputerName $Server -FilterHashtable $filter -MaxEvents $Top -ErrorAction Stop)
    } catch {
        if ($_.Exception.Message -match 'No events were found') { return @() }
        throw
    }
    $rows = $events | ForEach-Object {
        $msg = [string]$_.Message
        if ($msg.Length -gt 400) { $msg = $msg.Substring(0, 400) + '...' }
        [pscustomobject]@{
            time    = $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
            level   = $_.LevelDisplayName
            source  = $_.ProviderName
            eventId = $_.Id
            message = $msg
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Query)) {
        $rows = $rows | Where-Object { $_.message -like "*$Query*" -or $_.source -like "*$Query*" -or "$($_.eventId)" -eq $Query }
    }
    return $rows
}

Export-ModuleMember -Function Get-DomainControllers, Test-DcServices,
    Test-ExchangeServer, Send-TestMessage, Get-RemoteEvents,
    Test-DcReplication, Test-DcHealth, New-DiagnosticsReportBody, Send-DiagnosticsReport

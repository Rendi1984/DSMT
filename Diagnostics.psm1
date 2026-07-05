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

function Test-IsLocalMachine {
    <# True when $Name refers to the machine this code is running on (short
       name or FQDN, case-insensitive). Get-Service/Get-WinEvent -ComputerName
       always force the legacy RPC remoting path, which requires the
       'Remote Service Management' / 'Remote Event Log Management' firewall
       rule groups even when the "remote" target is the local host itself -
       those rules are usually not open for a pure self-query. Skipping
       -ComputerName entirely for a local target avoids RPC altogether. #>
    param([string] $Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $short = $Name.Split('.')[0]
    if ($short -ieq $env:COMPUTERNAME) { return $true }
    try {
        $fqdn = [System.Net.Dns]::GetHostEntry('').HostName
        if ($Name -ieq $fqdn -or $short -ieq $fqdn.Split('.')[0]) { return $true }
    } catch {}
    return $false
}

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
       counts as reachable if any service answers. Each service is probed
       independently - a previous version short-circuited the rest of a host's
       services after the FIRST SCM-open failure (e.g. a firewall/RPC issue),
       which falsely marked every other service 'unknown' even when they were
       genuinely reachable. Also skips the RPC-forcing -ComputerName parameter
       entirely when the target is the machine this code is running on. #>
    param([string[]] $Hosts, [string[]] $Services = $script:DcServices)
    $out = @()
    foreach ($h in $Hosts) {
        $svcResults = @()
        $ping = Test-Connection -ComputerName $h -Count 1 -Quiet -ErrorAction SilentlyContinue
        $answered = $false
        $isLocal = Test-IsLocalMachine -Name $h
        foreach ($s in $Services) {
            $state = 'unknown'
            try {
                $svc = if ($isLocal) { Get-Service -Name $s -ErrorAction Stop } else { Get-Service -ComputerName $h -Name $s -ErrorAction Stop }
                $state = $svc.Status.ToString(); $answered = $true
            }
            catch {
                if ($_.Exception -is [Microsoft.PowerShell.Commands.ServiceCommandException]) { $state = 'missing'; $answered = $true }
                elseif ($ping) { $state = 'missing' }
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
       and the caller needs Event Log Readers (or admin) rights on it.
       -ComputerName always forces that RPC path even when $Server is the
       machine this code runs on, where the firewall rule is usually not
       open for a pure self-query - skip it entirely for a local target so
       "Event Viewer -> this server" works without any RPC firewall rule. #>
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
    if (Test-IsLocalMachine -Name $Server) {
        $events = @(Get-WinEvent -FilterHashtable $filter -MaxEvents $Top -ErrorAction Stop)
    } else {
        $events = @(Get-WinEvent -ComputerName $Server -FilterHashtable $filter -MaxEvents $Top -ErrorAction Stop)
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
    Test-ExchangeServer, Send-TestMessage, Get-RemoteEvents

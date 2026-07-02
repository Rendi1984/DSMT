<#
  Diagnostics.psm1 - environment health tooling for the Directory Services
  Management Tool: discover domain controllers, probe Windows services,
  check Exchange components, and send/simulate a test message.

  Requires the ActiveDirectory module (RSAT) for discovery. Service probes use
  Get-Service via CIM/WinRM so the API service account needs remote query rights.
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
    <# Probes the standard DC services on each host. Returns per-host results. #>
    param([string[]] $Hosts, [string[]] $Services = $script:DcServices)
    $out = @()
    foreach ($h in $Hosts) {
        $svcResults = @()
        $reachable = Test-Connection -ComputerName $h -Count 1 -Quiet -ErrorAction SilentlyContinue
        foreach ($s in $Services) {
            $state = 'unknown'
            if ($reachable) {
                try { $state = (Get-Service -ComputerName $h -Name $s -ErrorAction Stop).Status.ToString() }
                catch { $state = 'missing' }
            }
            $svcResults += [pscustomobject]@{ name = $s; status = $state }
        }
        $running = ($svcResults | Where-Object { $_.status -eq 'Running' }).Count
        $out += [pscustomobject]@{
            host = $h; reachable = [bool]$reachable
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
    <# Checks the main Exchange component services on a host. #>
    param([Parameter(Mandatory)][string] $ExchangeHost, [string[]] $Services = $script:ExchangeServices)
    $reachable = Test-Connection -ComputerName $ExchangeHost -Count 1 -Quiet -ErrorAction SilentlyContinue
    $results = @()
    foreach ($s in $Services) {
        $state = 'unknown'
        if ($reachable) {
            try { $state = (Get-Service -ComputerName $ExchangeHost -Name $s -ErrorAction Stop).Status.ToString() }
            catch { $state = 'missing' }
        }
        $results += [pscustomobject]@{ name = $s; status = $state }
    }
    $running = ($results | Where-Object { $_.status -eq 'Running' }).Count
    return [pscustomobject]@{
        host = $ExchangeHost; reachable = [bool]$reachable
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

Export-ModuleMember -Function Get-DomainControllers, Test-DcServices,
    Test-ExchangeServer, Send-TestMessage

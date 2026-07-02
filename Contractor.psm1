<#
  Contractor.psm1 - contractor account placement verdict.
  Mirrors the logic of the original HafalaTool: a contractor signs in with a
  weak "-Support" account and has a matching strong (admin) account. We detect
  which one was entered, find the AD object, read its Juniper servers
  (extensionAttribute10..15) and report whether it sits in the expected OU.
#>

function Get-ContractorInfo {
    param([Parameter(Mandatory)][string] $Username, [Parameter(Mandatory)] $Config)
    Import-Module ActiveDirectory -ErrorAction Stop

    $isSupport = $Username -match '(?i)-support$'
    $baseName  = $Username -replace '(?i)-support$',''
    $partner   = if ($isSupport) { $baseName } else { "$baseName-Support" }
    $expectedOU = if ($isSupport) { Get-Config 'ContractorExpectedSupportOU' } else { Get-Config 'ContractorExpectedAdminOU' }

    $props = @('DisplayName','Manager','LastLogonDate','Enabled','DistinguishedName') + (10..15 | ForEach-Object { "extensionAttribute$_" })
    $u = $null
    try { $u = Get-ADUser -Identity $Username -Properties $props -ErrorAction Stop } catch { }

    if (-not $u) {
        return [pscustomobject]@{
            entered = $Username; detectedAs = $(if($isSupport){'SUPPORT (weak / login)'}else{'ADMIN (strong / privileged)'})
            partner = $partner; found = $false
            verdictLabel = 'NOT FOUND'; verdictDetail = 'No account matched this name in AD.'
            expectedOU = $expectedOU; juniper = @()
        }
    }

    $juniper = 10..15 | ForEach-Object { [string]$u."extensionAttribute$_" }
    $inOU = $u.DistinguishedName -like "*$expectedOU"
    $label = if ($inOU) { 'OK' } else { 'WARNING' }
    $detail = if ($inOU) { "User is in the expected OU." } else { 'User is not in the configured contractor OU - manual review required.' }

    [pscustomobject]@{
        entered    = $Username
        detectedAs = if ($isSupport) { 'SUPPORT (weak / login)' } else { 'ADMIN (strong / privileged)' }
        partner    = $partner
        found      = $true
        display    = $u.DisplayName
        manager    = if ($u.Manager) { ($u.Manager -split ',')[0] -replace 'CN=','' } else { '(none)' }
        lastLogon  = if ($u.LastLogonDate) { $u.LastLogonDate.ToString('yyyy-MM-dd HH:mm') } else { '-' }
        enabled    = [bool]$u.Enabled
        dn         = $u.DistinguishedName
        juniper    = $juniper
        expectedOU = $expectedOU
        verdictLabel  = $label
        verdictDetail = $detail
    }
}

Export-ModuleMember -Function Get-ContractorInfo

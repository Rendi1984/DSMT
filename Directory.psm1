<#
  Directory.psm1 - Active Directory user & group operations.
  Requires the ActiveDirectory module (RSAT-AD-PowerShell).
  The API service account needs delegated rights for the write actions.
#>

function Assert-ADModule {
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        throw 'ActiveDirectory module not found. Install RSAT: Install-WindowsFeature RSAT-AD-PowerShell'
    }
    Import-Module ActiveDirectory -ErrorAction Stop
}

function Get-DirectoryUsers {
    param([string] $Query = '', [int] $Top = 100)
    Assert-ADModule
    $filter = if ($Query) { "Name -like '*$Query*' -or SamAccountName -like '*$Query*'" } else { '*' }
    Get-ADUser -Filter $filter -Properties DisplayName, Enabled, LockedOut, DistinguishedName, Title -ResultSetSize $Top |
        ForEach-Object {
            [pscustomobject]@{
                sam     = $_.SamAccountName
                name    = $_.DisplayName
                enabled = [bool]$_.Enabled
                locked  = [bool]$_.LockedOut
                ou      = (($_.DistinguishedName -split ',OU=',2)[1] -split ',')[0]
                title   = $_.Title
            }
        }
}

function Get-GroupMembers {
    param([Parameter(Mandatory)][string] $GroupName)
    Assert-ADModule
    Get-ADGroupMember -Identity $GroupName -Recursive |
        Get-ADObject -Properties DisplayName, mail, title, userAccountControl, objectClass, sAMAccountName |
        ForEach-Object {
            [pscustomobject]@{
                sam     = $_.sAMAccountName
                name    = $_.DisplayName
                email   = $_.mail
                title   = $_.title
                type    = if ($_.objectClass -eq 'group') { 'Group' } else { 'User' }
                enabled = -not ([bool]($_.userAccountControl -band 0x2))
            }
        }
}

function Set-UserLock {
    param([string] $Sam, [bool] $Unlock = $true)
    Assert-ADModule
    if ($Unlock) { Unlock-ADAccount -Identity $Sam }
    # AD has no "lock" cmdlet; lockout happens via bad-password policy.
    return [pscustomobject]@{ sam = $Sam; locked = $false }
}

function Set-UserEnabled {
    param([string] $Sam, [bool] $Enabled)
    Assert-ADModule
    if ($Enabled) { Enable-ADAccount -Identity $Sam } else { Disable-ADAccount -Identity $Sam }
    return [pscustomobject]@{ sam = $Sam; enabled = $Enabled }
}

function Reset-UserPassword {
    param([string] $Sam, [string] $NewPassword, [switch] $MustChange)
    Assert-ADModule
    $sec = ConvertTo-SecureString $NewPassword -AsPlainText -Force
    Set-ADAccountPassword -Identity $Sam -NewPassword $sec -Reset
    if ($MustChange) { Set-ADUser -Identity $Sam -ChangePasswordAtLogon $true }
    return [pscustomobject]@{ sam = $Sam; reset = $true }
}

function New-DirectoryUser {
    param([string] $Sam, [string] $DisplayName, [string] $Ou, [string] $InitialPassword)
    Assert-ADModule
    $sec = ConvertTo-SecureString $InitialPassword -AsPlainText -Force
    New-ADUser -Name $DisplayName -SamAccountName $Sam -Path $Ou `
        -AccountPassword $sec -Enabled $true -ChangePasswordAtLogon $true
    return [pscustomobject]@{ sam = $Sam; created = $true }
}

function Invoke-Offboard {
    param([Parameter(Mandatory)][string] $Sam, [string] $DisabledOU = $null)
    Assert-ADModule
    Disable-ADAccount -Identity $Sam
    $rnd = -join ((48..57) + (65..90) + (97..122) + (33,35,37,42) | Get-Random -Count 20 | ForEach-Object { [char]$_ })
    Set-ADAccountPassword -Identity $Sam -NewPassword (ConvertTo-SecureString $rnd -AsPlainText -Force) -Reset
    $u = Get-ADUser -Identity $Sam -Properties MemberOf
    foreach ($g in $u.MemberOf) { try { Remove-ADGroupMember -Identity $g -Members $Sam -Confirm:$false } catch {} }
    try { Set-ADUser -Identity $Sam -Replace @{ msExchHideFromAddressLists = $true } } catch {}
    if ($DisabledOU) { Move-ADObject -Identity $u.DistinguishedName -TargetPath $DisabledOU }
    return [pscustomobject]@{ sam = $Sam; offboarded = $true }
}

function Get-ExpiringPasswords {
    <# Users (enabled, not PasswordNeverExpires) whose password expires within $Days.
       Uses the AD-computed msDS-UserPasswordExpiryTimeComputed attribute, which is
       accurate per user - including fine-grained password policies (PSOs). #>
    param([int] $Days = 14)
    Assert-ADModule
    $now = Get-Date
    Get-ADUser -Filter 'Enabled -eq $true -and PasswordNeverExpires -eq $false' -Properties DisplayName, DistinguishedName, 'msDS-UserPasswordExpiryTimeComputed' |
        ForEach-Object {
            $ft = $_.'msDS-UserPasswordExpiryTimeComputed'
            # 0 / not set / 0x7FFFFFFFFFFFFFFF all mean "never expires" - skip.
            if ($ft -and $ft -gt 0 -and $ft -lt 0x7FFFFFFFFFFFFFFF) {
                $expires = [datetime]::FromFileTime($ft)
                $left = [int][math]::Floor(($expires - $now).TotalDays)
                if ($left -le $Days -and $left -ge 0) {
                    [pscustomobject]@{
                        sam        = $_.SamAccountName
                        name       = $_.DisplayName
                        ou         = (($_.DistinguishedName -split ',OU=',2)[1] -split ',')[0]
                        daysLeft   = $left
                        expiresOn  = $expires.ToString('yyyy-MM-dd')
                    }
                }
            }
        }
}

Export-ModuleMember -Function Get-DirectoryUsers, Get-GroupMembers, Set-UserLock,
    Set-UserEnabled, Reset-UserPassword, New-DirectoryUser, Invoke-Offboard, Get-ExpiringPasswords

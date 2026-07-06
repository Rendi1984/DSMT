<#
  Auth.psm1 - authentication & authorization.
  - Domain users authenticate against LDAP (real bind) and are authorized by
    membership in the configured access security group.
  - Local (break-glass) accounts authenticate against a PBKDF2 hash in SQL and
    bypass the security-group requirement.
#>

# ---------- Password hashing (PBKDF2 / Rfc2898) ----------
function New-PasswordHash {
    param([Parameter(Mandatory)][string] $Password, [int] $Iterations = 120000)
    $salt = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
    $kdf  = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, $Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $hash = $kdf.GetBytes(32)
    return [pscustomobject]@{
        Hash       = [Convert]::ToBase64String($hash)
        Salt       = [Convert]::ToBase64String($salt)
        Iterations = $Iterations
    }
}

function Test-PasswordHash {
    param([string] $Password, [string] $StoredHash, [string] $StoredSalt, [int] $Iterations)
    $salt = [Convert]::FromBase64String($StoredSalt)
    $kdf  = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Password, $salt, $Iterations, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $hash = [Convert]::ToBase64String($kdf.GetBytes(32))
    return ($hash -eq $StoredHash)
}

# ---------- Local accounts ----------
function Test-LocalAccount {
    param([string] $Username, [string] $Password)
    $rows = Invoke-Sql 'SELECT TOP 1 Username,ConsoleRole,PwHash,PwSalt,Iterations,Enabled FROM dbo.LocalAccounts WHERE Username=@u' @{ u = $Username }
    if (-not $rows -or $rows.Count -eq 0) { return $null }
    $r = $rows[0]
    if (-not [bool]$r['Enabled']) { return $null }
    if (Test-PasswordHash $Password $r['PwHash'] $r['PwSalt'] ([int]$r['Iterations'])) {
        return [pscustomobject]@{ Username = $r['Username']; Role = $r['ConsoleRole']; IsLocal = $true }
    }
    return $null
}

# ---------- LDAP bind + group membership ----------
function Test-LdapCredential {
    <# Validates user/password by binding to LDAP. Returns $true/$false. #>
    param([string] $Server, [string] $UserPrincipal, [string] $Password, [switch] $UseSsl)
    Add-Type -AssemblyName System.DirectoryServices.Protocols
    $authType = [System.DirectoryServices.Protocols.AuthType]::Negotiate
    $id = New-Object System.DirectoryServices.Protocols.LdapDirectoryIdentifier($Server, $(if($UseSsl){636}else{389}))
    $conn = New-Object System.DirectoryServices.Protocols.LdapConnection($id)
    $conn.SessionOptions.ProtocolVersion = 3
    if ($UseSsl) { $conn.SessionOptions.SecureSocketLayer = $true }
    $cred = New-Object System.Net.NetworkCredential($UserPrincipal, $Password)
    try { $conn.Bind($cred); return $true }
    catch { return $false }
    finally { $conn.Dispose() }
}

function Get-UserGroups {
    <# Returns the user's group sAMAccountNames (transitive) via tokenGroups->name. #>
    param([string] $Server, [string] $BaseDN, [string] $SamAccountName)
    $root = "LDAP://$Server/$BaseDN"
    $searcher = New-Object System.DirectoryServices.DirectorySearcher
    $searcher.SearchRoot = New-Object System.DirectoryServices.DirectoryEntry($root)
    $searcher.Filter = "(sAMAccountName=$SamAccountName)"
    [void]$searcher.PropertiesToLoad.Add('memberof')
    $res = $searcher.FindOne()
    if (-not $res) { return @() }
    $groups = @()
    foreach ($dn in $res.Properties['memberof']) {
        if ($dn -match '^CN=([^,]+),') { $groups += $Matches[1] }
    }
    return $groups
}

function Resolve-ConsoleRole {
    <# Maps the user's groups to a console role using dbo.RoleMappings.
       'No access' ranks lowest (0) - if a user is ALSO in another group
       mapped to a real role, that real role wins (matches how the rest of
       this rank comparison already works: highest wins). Invoke-SignIn is
       what actually turns a resolved 'No access' into a denied sign-in. #>
    param([string[]] $Groups)
    $maps = Get-RoleMappings
    $best = $null
    $rank = @{ 'System Administrator' = 4; 'Operator' = 3; 'Helpdesk Operator' = 2; 'Read-only' = 1; 'No access' = 0 }
    foreach ($m in $maps) {
        if ($Groups -contains $m['LdapGroup']) {
            $role = $m['ConsoleRole']
            if (-not $best -or ($rank[$role] -gt $rank[$best])) { $best = $role }
        }
    }
    return $best
}

# ---------- Top-level sign-in ----------
function Invoke-SignIn {
    param(
        [Parameter(Mandatory)] $Config,
        [string] $Domain, [string] $Username, [string] $Password
    )
    # Local account path (domain-independent break-glass)
    if ($Domain -eq 'Local account' -or $Domain -eq 'local') {
        $local = Test-LocalAccount -Username $Username -Password $Password
        if ($local) { return [pscustomobject]@{ Ok=$true; Username=$local.Username; Role=$local.Role; IsLocal=$true } }
        return [pscustomobject]@{ Ok=$false; Reason='Invalid local credentials' }
    }

    # Domain path: real LDAP bind
    $upn = if ($Username -like '*@*') { $Username } else { "$Username@$Domain" }
    $ok  = Test-LdapCredential -Server $Config.Directory.LdapServer -UserPrincipal $upn -Password $Password -UseSsl:([bool]$Config.Directory.UseSsl)
    if (-not $ok) { return [pscustomobject]@{ Ok=$false; Reason='Invalid domain credentials' } }

    $groups = Get-UserGroups -Server $Config.Directory.LdapServer -BaseDN $Config.Directory.BaseDN -SamAccountName ($Username -replace '@.*$','')
    $requireGroup = (Get-Config 'RequireSecurityGroup') -eq 'true'
    $accessGroup  = Get-Config 'AccessSecurityGroup'
    if ($requireGroup -and ($groups -notcontains $accessGroup)) {
        return [pscustomobject]@{ Ok=$false; Reason="Not a member of $accessGroup" }
    }
    $role = Resolve-ConsoleRole -Groups $groups
    # Previously 'No access' was just passed through Resolve-ConsoleRole as if
    # it were a normal role name (it's a non-empty string, so the "-not $role"
    # fallback below never caught it either) - mapping a group to 'No access'
    # silently did nothing, the user still signed in. Explicitly deny here.
    if ($role -eq 'No access') { return [pscustomobject]@{ Ok=$false; Reason='Sign-in blocked by role mapping (No access)' } }
    if (-not $role) { $role = 'Read-only' }
    return [pscustomobject]@{ Ok=$true; Username=$Username; Role=$role; IsLocal=$false }
}

Export-ModuleMember -Function New-PasswordHash, Test-PasswordHash, Test-LocalAccount,
    Test-LdapCredential, Get-UserGroups, Resolve-ConsoleRole, Invoke-SignIn

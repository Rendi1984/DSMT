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
    # Returns $null on any failure. On password success it always returns an
    # object so the caller can inspect MfaRequired - a $null return must mean
    # "reject the sign-in", never "let me check MFA later", otherwise a wrong
    # password could be masked by an MFA prompt.
    param([string] $Username, [string] $Password)
    $rows = Invoke-Sql 'SELECT TOP 1 Username,ConsoleRole,PwHash,PwSalt,Iterations,Enabled,MfaEnabled,MfaSecret FROM dbo.LocalAccounts WHERE Username=@u' @{ u = $Username }
    if (-not $rows -or $rows.Count -eq 0) { return $null }
    $r = $rows[0]
    if (-not [bool]$r['Enabled']) { return $null }
    if (-not (Test-PasswordHash $Password $r['PwHash'] $r['PwSalt'] ([int]$r['Iterations']))) { return $null }
    return [pscustomobject]@{
        Username     = $r['Username']
        Role         = $r['ConsoleRole']
        IsLocal      = $true
        MfaEnabled   = [bool]$r['MfaEnabled']
        MfaSecret    = [string]$r['MfaSecret']
    }
}

# ---------- MFA (TOTP, RFC 6238 / RFC 4226) ----------
# Self-contained (no external module) - Base32 secret + HMAC-SHA1-based
# 6-digit code, 30-second step, compatible with Google/Microsoft Authenticator.
function New-TotpSecret {
    # 20 random bytes (160 bits) is the RFC-recommended secret length for HMAC-SHA1.
    $bytes = New-Object byte[] 20
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return ConvertTo-Base32 -Bytes $bytes
}

function ConvertTo-Base32 {
    param([Parameter(Mandatory)][byte[]] $Bytes)
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $bits = ''
    foreach ($b in $Bytes) { $bits += [Convert]::ToString($b, 2).PadLeft(8, '0') }
    $out = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $bits.Length; $i += 5) {
        $chunk = $bits.Substring($i, [Math]::Min(5, $bits.Length - $i)).PadRight(5, '0')
        [void]$out.Append($alphabet[[Convert]::ToInt32($chunk, 2)])
    }
    return $out.ToString()
}

function ConvertFrom-Base32 {
    param([Parameter(Mandatory)][string] $Text)
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $clean = $Text.ToUpperInvariant() -replace '[^A-Z2-7]', ''
    $bits = ''
    foreach ($c in $clean.ToCharArray()) { $bits += [Convert]::ToString($alphabet.IndexOf($c), 2).PadLeft(5, '0') }
    $byteCount = [Math]::Floor($bits.Length / 8)
    $bytes = New-Object byte[] $byteCount
    for ($i = 0; $i -lt $byteCount; $i++) { $bytes[$i] = [Convert]::ToByte($bits.Substring($i * 8, 8), 2) }
    return $bytes
}

function Get-TotpCode {
    # RFC 6238: HOTP(secret, floor(unixTime / 30)), dynamically truncated to 6 digits.
    param([Parameter(Mandatory)][string] $Base32Secret, [int] $TimeStep = 30, [long] $Counter = -1)
    $key = ConvertFrom-Base32 -Text $Base32Secret
    if ($Counter -lt 0) {
        $unixTime = [long]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
        $Counter = [Math]::Floor($unixTime / $TimeStep)
    }
    $counterBytes = [BitConverter]::GetBytes([long]$Counter)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($counterBytes) }
    $hmac = New-Object System.Security.Cryptography.HMACSHA1(,$key)
    $hash = $hmac.ComputeHash($counterBytes)
    $offset = $hash[$hash.Length - 1] -band 0x0F
    $binCode = (($hash[$offset] -band 0x7F) -shl 24) -bor `
               (($hash[$offset + 1] -band 0xFF) -shl 16) -bor `
               (($hash[$offset + 2] -band 0xFF) -shl 8) -bor `
               ($hash[$offset + 3] -band 0xFF)
    return ('{0:D6}' -f ($binCode % 1000000))
}

function Test-TotpCode {
    # Accepts the current 30s window plus one step either side, to tolerate
    # normal clock drift between the server and the user's phone.
    param([Parameter(Mandatory)][string] $Base32Secret, [Parameter(Mandatory)][string] $Code, [int] $Window = 1)
    if ([string]::IsNullOrWhiteSpace($Code)) { return $false }
    $code = $Code.Trim()
    $unixTime = [long]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    $baseCounter = [Math]::Floor($unixTime / 30)
    for ($i = -$Window; $i -le $Window; $i++) {
        if ((Get-TotpCode -Base32Secret $Base32Secret -Counter ($baseCounter + $i)) -eq $code) { return $true }
    }
    return $false
}

function Get-TotpUri {
    # otpauth:// URI for manual entry / QR generation client-side.
    param([Parameter(Mandatory)][string] $Base32Secret, [Parameter(Mandatory)][string] $Username, [string] $Issuer = 'DSMT')
    $label = [Uri]::EscapeDataString("$Issuer`:$Username")
    $iss   = [Uri]::EscapeDataString($Issuer)
    return "otpauth://totp/$label?secret=$Base32Secret&issuer=$iss&algorithm=SHA1&digits=6&period=30"
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

# ---------- Role -> (scope, access level) metadata ----------
# Two independent axes per role: which workspaces it can reach (scope) and
# whether it can make any change at all (level). Both are enforced server-side
# (DSMT_Api.ps1's ReadOnlyGuard/ScopeGuard middleware) - the console also
# hides what a role can't reach, but that's a UX convenience, not the
# security boundary. A role missing from this table defaults to full/all
# (fail-open only for a genuinely unrecognized role string, e.g. one typed
# directly into dbo.RoleMappings/dbo.LocalAccounts by hand outside the UI -
# every role the UI itself can assign is listed here).
$script:RoleMeta = @{
    'System Administrator'   = @{ scope = 'all';    level = 'full';     rank = 5 }
    'Operator'                = @{ scope = 'all';    level = 'full';     rank = 4 }
    'Helpdesk Operator'       = @{ scope = 'all';    level = 'full';     rank = 3 }
    'Hafala Tools Operator'   = @{ scope = 'hafala'; level = 'full';     rank = 2 }
    'Read-only'               = @{ scope = 'all';    level = 'readonly'; rank = 1 }
    'Hafala Tools Read-only'  = @{ scope = 'hafala'; level = 'readonly'; rank = 0 }
}

function Get-RoleScope {
    param([string] $Role)
    if ($script:RoleMeta.ContainsKey($Role)) { return $script:RoleMeta[$Role].scope }
    return 'all'
}

function Get-RoleLevel {
    param([string] $Role)
    if ($script:RoleMeta.ContainsKey($Role)) { return $script:RoleMeta[$Role].level }
    return 'full'
}

function Test-RoleReadOnly {
    param([string] $Role)
    return (Get-RoleLevel -Role $Role) -eq 'readonly'
}

function Get-ConsoleRoleNames {
    <# All assignable role names, for the console's role-mapping picker. #>
    return @($script:RoleMeta.Keys)
}

function Resolve-ConsoleRole {
    <# Maps the user's groups to a console role using dbo.RoleMappings.
       A user not in ANY mapped group resolves to $null - Invoke-SignIn denies
       that outright. There is no separate access-group gate and no 'No access'
       role: being listed here (in some group) IS the access grant, and the
       mapped role IS the permission level - one list controls both. When a
       user is in multiple mapped groups, the highest-ranked role wins (a
       Hafala-scoped role never silently downgrades a broader one, and vice
       versa - highest rank always wins regardless of scope). #>
    param([string[]] $Groups)
    $maps = Get-RoleMappings
    $best = $null
    foreach ($m in $maps) {
        if ($Groups -contains $m['LdapGroup']) {
            $role = $m['ConsoleRole']
            $rank = if ($script:RoleMeta.ContainsKey($role)) { $script:RoleMeta[$role].rank } else { 0 }
            $bestRank = if ($best -and $script:RoleMeta.ContainsKey($best)) { $script:RoleMeta[$best].rank } else { -1 }
            if (-not $best -or $rank -gt $bestRank) { $best = $role }
        }
    }
    return $best
}

# ---------- Top-level sign-in ----------
function Invoke-SignIn {
    param(
        [Parameter(Mandatory)] $Config,
        [string] $Domain, [string] $Username, [string] $Password, [string] $MfaCode = $null
    )
    # Local account path (domain-independent break-glass)
    if ($Domain -eq 'Local account' -or $Domain -eq 'local') {
        $local = Test-LocalAccount -Username $Username -Password $Password
        if (-not $local) { return [pscustomobject]@{ Ok=$false; Reason='Invalid local credentials' } }
        if ($local.MfaEnabled) {
            if ([string]::IsNullOrWhiteSpace($MfaCode)) { return [pscustomobject]@{ Ok=$false; MfaRequired=$true; Reason='MFA code required' } }
            if (-not (Test-TotpCode -Base32Secret $local.MfaSecret -Code $MfaCode)) {
                return [pscustomobject]@{ Ok=$false; MfaRequired=$true; Reason='Invalid MFA code' }
            }
        }
        return [pscustomobject]@{ Ok=$true; Username=$local.Username; Role=$local.Role; IsLocal=$true }
    }

    # Domain path: real LDAP bind
    $upn = if ($Username -like '*@*') { $Username } else { "$Username@$Domain" }
    $ok  = Test-LdapCredential -Server $Config.Directory.LdapServer -UserPrincipal $upn -Password $Password -UseSsl:([bool]$Config.Directory.UseSsl)
    if (-not $ok) { return [pscustomobject]@{ Ok=$false; Reason='Invalid domain credentials' } }

    $groups = Get-UserGroups -Server $Config.Directory.LdapServer -BaseDN $Config.Directory.BaseDN -SamAccountName ($Username -replace '@.*$','')
    # A single list controls both "can this user sign in at all" and "what
    # role do they get": being in a group mapped in dbo.RoleMappings IS the
    # access grant. Not being in any mapped group denies sign-in outright -
    # there is no separate access-group toggle to also satisfy.
    $role = Resolve-ConsoleRole -Groups $groups
    if (-not $role) { return [pscustomobject]@{ Ok=$false; Reason='Not a member of any group mapped for console access' } }
    return [pscustomobject]@{ Ok=$true; Username=$Username; Role=$role; IsLocal=$false }
}

Export-ModuleMember -Function New-PasswordHash, Test-PasswordHash, Test-LocalAccount,
    Test-LdapCredential, Get-UserGroups, Resolve-ConsoleRole, Invoke-SignIn,
    New-TotpSecret, Get-TotpCode, Test-TotpCode, Get-TotpUri, ConvertTo-Base32, ConvertFrom-Base32,
    Get-RoleScope, Get-RoleLevel, Test-RoleReadOnly, Get-ConsoleRoleNames

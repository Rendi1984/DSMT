<#
  Secrets.psm1 - secure storage of sensitive settings (service-account passwords,
  bind credentials, API keys) for the Directory Services Management Tool.

  Values are encrypted with Windows DPAPI at MACHINE scope, so only THIS server
  can decrypt them, and the encrypted blob is stored in SQL (dbo.Secrets).
  Plain text is never written to disk or to the database.

  Requires Db.psm1 (Invoke-Sql) to be imported first.
#>

Add-Type -AssemblyName System.Security

function Protect-Secret {
    <# Encrypts a plain string with DPAPI (LocalMachine). Returns Base64. #>
    param([Parameter(Mandatory)][string] $Plain)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Plain)
    $enc   = [System.Security.Cryptography.ProtectedData]::Protect(
                $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [Convert]::ToBase64String($enc)
}

function Unprotect-Secret {
    <# Decrypts a Base64 DPAPI blob back to the plain string. #>
    param([Parameter(Mandatory)][string] $Cipher)
    $enc   = [Convert]::FromBase64String($Cipher)
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $enc, $null, [System.Security.Cryptography.DataProtectionScope]::LocalMachine)
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Set-Secret {
    <# Stores (or replaces) a named secret, encrypted. #>
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][string] $Value,
        [string] $Account = $null,     # optional DOMAIN\user this secret belongs to
        [string] $By = 'system'
    )
    $cipher = Protect-Secret -Plain $Value
    Invoke-Sql @'
MERGE dbo.Secrets AS t USING (SELECT @n AS Name) AS s ON t.Name = s.Name
WHEN MATCHED THEN UPDATE SET Cipher=@c, Account=@a, UpdatedAt=SYSUTCDATETIME(), UpdatedBy=@by
WHEN NOT MATCHED THEN INSERT(Name, Cipher, Account, UpdatedBy) VALUES(@n,@c,@a,@by);
'@ @{ n = $Name; c = $cipher; a = $Account; by = $By } -NonQuery | Out-Null
}

function Get-Secret {
    <# Returns the decrypted value for a named secret, or $null. #>
    param([Parameter(Mandatory)][string] $Name)
    $cipher = Invoke-Sql 'SELECT Cipher FROM dbo.Secrets WHERE Name=@n' @{ n = $Name } -Scalar
    if (-not $cipher) { return $null }
    return Unprotect-Secret -Cipher $cipher
}

function Get-SecretList {
    <# Lists secret NAMES + metadata only - never the values. #>
    Invoke-Sql 'SELECT Name, Account, UpdatedAt, UpdatedBy FROM dbo.Secrets ORDER BY Name'
}

function Remove-Secret {
    param([Parameter(Mandatory)][string] $Name)
    Invoke-Sql 'DELETE FROM dbo.Secrets WHERE Name=@n' @{ n = $Name } -NonQuery | Out-Null
}

function Test-ServiceAccount {
    <# Validates a DOMAIN\user + password by an LDAP bind. Returns $true/$false. #>
    param([string] $Server, [string] $Account, [string] $Password, [switch] $UseSsl)
    Add-Type -AssemblyName System.DirectoryServices.Protocols
    $id   = New-Object System.DirectoryServices.Protocols.LdapDirectoryIdentifier($Server, $(if($UseSsl){636}else{389}))
    $conn = New-Object System.DirectoryServices.Protocols.LdapConnection($id)
    $conn.SessionOptions.ProtocolVersion = 3
    if ($UseSsl) { $conn.SessionOptions.SecureSocketLayer = $true }
    try { $conn.Bind((New-Object System.Net.NetworkCredential($Account, $Password))); return $true }
    catch { return $false }
    finally { $conn.Dispose() }
}

Export-ModuleMember -Function Protect-Secret, Unprotect-Secret, Set-Secret, Get-Secret,
    Get-SecretList, Remove-Secret, Test-ServiceAccount

<#
  CertAuthority.psm1 - Active Directory Certificate Services operations.
  Uses certutil (always present on a CA / RSAT) so no extra module is required.
  ConfigString form: "CA-HOST\CA-COMMON-NAME".
#>

function Get-IssuedCertificates {
    param([Parameter(Mandatory)][string] $ConfigString, [int] $Top = 200)
    # Restrict to issued certs (Disposition 20). Parse certutil CSV-ish output.
    $raw = certutil -config $ConfigString -view -restrict "Disposition=20" `
        -out "RequestID,CommonName,CertificateTemplate,SerialNumber,NotAfter" csv 2>$null
    $rows = @()
    $lines = $raw | Select-Object -Skip 1   # first line = headers
    foreach ($line in $lines) {
        $f = $line -split '","' | ForEach-Object { $_.Trim('"') }
        if ($f.Count -ge 5) {
            $rows += [pscustomobject]@{
                serial   = $f[3]
                subject  = $f[1]
                template = $f[2]
                expires  = $f[4]
                status   = 'valid'
            }
        }
    }
    return ($rows | Select-Object -First $Top)
}

function Get-PendingRequests {
    param([Parameter(Mandatory)][string] $ConfigString)
    $raw = certutil -config $ConfigString -view -restrict "Disposition=9" `
        -out "RequestID,CommonName,CertificateTemplate,RequesterName,SubmittedWhen" csv 2>$null
    $rows = @()
    foreach ($line in ($raw | Select-Object -Skip 1)) {
        $f = $line -split '","' | ForEach-Object { $_.Trim('"') }
        if ($f.Count -ge 5) {
            $rows += [pscustomobject]@{
                id = $f[0]; subject = $f[1]; template = $f[2]; requester = $f[3]; submitted = $f[4]
            }
        }
    }
    return $rows
}

function Approve-Request {
    param([string] $ConfigString, [int] $RequestId)
    $out = certutil -config $ConfigString -resubmit $RequestId 2>&1
    return [pscustomobject]@{ id = $RequestId; ok = ($LASTEXITCODE -eq 0); detail = ($out -join "`n") }
}

function Deny-Request {
    param([string] $ConfigString, [int] $RequestId)
    $out = certutil -config $ConfigString -deny $RequestId 2>&1
    return [pscustomobject]@{ id = $RequestId; ok = ($LASTEXITCODE -eq 0); detail = ($out -join "`n") }
}

function Revoke-Certificate {
    # Reason 4 = superseded. Others: 0 unspecified, 1 keyCompromise, 3 affiliationChanged.
    param([string] $ConfigString, [string] $Serial, [int] $Reason = 4)
    $out = certutil -config $ConfigString -revoke $Serial $Reason 2>&1
    return [pscustomobject]@{ serial = $Serial; ok = ($LASTEXITCODE -eq 0); detail = ($out -join "`n") }
}

function Publish-Crl {
    param([string] $ConfigString)
    $out = certutil -config $ConfigString -CRL 2>&1
    return [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); detail = ($out -join "`n") }
}

function Test-Ca {
    <# Verifies the CA responds via certutil -ping. #>
    param([Parameter(Mandatory)][string] $ConfigString)
    $out = certutil -config $ConfigString -ping 2>&1
    return [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); detail = ($out -join "`n") }
}

function Get-ExpiringCertificates {
    param([Parameter(Mandatory)][string] $ConfigString, [int] $Days = 30)
    $cutoff = (Get-Date).AddDays($Days)
    Get-IssuedCertificates -ConfigString $ConfigString |
        Where-Object { try { [datetime]$_.expires -le $cutoff } catch { $false } }
}

function Backup-CaDatabase {
    <# Backs up the CA database via certutil -backupdb. The backup is written on
       the machine running the API (certutil pulls from the remote CA). #>
    param([Parameter(Mandatory)][string] $ConfigString, [string] $Path = '')
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path $env:ProgramData ('DSMT\ca-backup\' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $out = certutil -config $ConfigString -backupdb $Path 2>&1
    return [pscustomobject]@{ ok = ($LASTEXITCODE -eq 0); path = $Path; detail = ($out -join "`n") }
}

Export-ModuleMember -Function Get-IssuedCertificates, Get-PendingRequests,
    Approve-Request, Deny-Request, Revoke-Certificate, Publish-Crl, Get-ExpiringCertificates, Test-Ca, Backup-CaDatabase

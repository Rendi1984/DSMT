<#
  Start-Install.ps1 - one-click bootstrap for the Directory Services Management Tool.

  Copy the WHOLE project folder (this file + index.html + the server\ folder) to the
  app server, then just double-click Install.cmd (or run this script). It will:
    1. Self-elevate (prompt for UAC) so you don't have to "Run as administrator".
    2. Set the execution policy for this run only (no system change).
    3. Run server\Install-DSMT.ps1 end to end (prereqs, config, DB, admin, service, IIS).

  ZERO-PROMPT (unattended): copy install-answers.sample.json to install-answers.json,
  fill in your values, and run again - any value you provide is passed through, so the
  installer stops asking. Leave a value blank and it will prompt for that one only.

  COMPATIBILITY: Windows PowerShell 5.1 (no ternary / ?? / && ; ASCII only).
#>
[CmdletBinding()]
param(
    [string] $AnswersFile = ""   # path to a JSON answers file (default: install-answers.json next to this script)
)

$ErrorActionPreference = "Stop"
$self = $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $self

# --- 1) Self-elevate if we are not already an administrator ------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Requesting administrator rights (UAC) ..." -ForegroundColor Yellow
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ('"' + $self + '"'))
    if (-not [string]::IsNullOrWhiteSpace($AnswersFile)) { $argList += @("-AnswersFile", ('"' + $AnswersFile + '"')) }
    try {
        Start-Process -FilePath "powershell.exe" -ArgumentList $argList -Verb RunAs | Out-Null
    } catch {
        Write-Host "Elevation was cancelled. Right-click Install.cmd and choose 'Run as administrator'." -ForegroundColor Red
    }
    return
}

# --- 2) Locate the real installer ------------------------------------------
$installer = Join-Path $root "server\Install-DSMT.ps1"
if (-not (Test-Path $installer)) {
    throw "Could not find server\Install-DSMT.ps1 next to this script. Copy the WHOLE project folder (this file + index.html + the server\ folder), then run again."
}

# --- 3) Optional answers file -> installer parameters -----------------------
if ([string]::IsNullOrWhiteSpace($AnswersFile)) { $AnswersFile = Join-Path $root "install-answers.json" }

$params = @{}
if (Test-Path $AnswersFile) {
    Write-Host ("Using answers from {0}" -f $AnswersFile) -ForegroundColor Cyan
    $a = Get-Content $AnswersFile -Raw | ConvertFrom-Json

    $switchNames = @("SkipPrereqs", "SkipService", "SkipFrontend", "SkipDeploy", "NoOpen", "SetupViaBrowser")
    $secureNames = @("LocalAdminPassword", "ServiceAccountPassword")

    foreach ($prop in $a.PSObject.Properties) {
        $name = $prop.Name
        $val  = $prop.Value
        if ($name.StartsWith("_")) { continue }                     # allow _comment keys
        if ($null -eq $val) { continue }
        if (($val -is [string]) -and [string]::IsNullOrWhiteSpace($val)) { continue }

        if ($switchNames -contains $name) {
            if ($val -eq $true) { $params[$name] = $true }
            continue
        }
        if ($secureNames -contains $name) {
            $params[$name] = ConvertTo-SecureString ([string]$val) -AsPlainText -Force
            continue
        }
        $params[$name] = $val
    }
} else {
    Write-Host "No install-answers.json found - running interactively (you'll be asked for the required values)." -ForegroundColor Yellow
}

# --- 4) Run the full installer ---------------------------------------------
Write-Host ""
Write-Host "Launching the full installer ..." -ForegroundColor White
try {
    & $installer @params
    $code = 0
} catch {
    Write-Host ""
    Write-Host ("Installation failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    $code = 1
}

Write-Host ""
Read-Host "Done. Press Enter to close this window"
exit $code

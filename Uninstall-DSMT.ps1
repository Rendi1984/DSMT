<#
  Uninstall-DSMT.ps1 - removes the Directory Services Management Tool.

  It stops AND deletes the DSMT-Api Windows service (deleting is required so the
  service .exe is released and the install folder can be removed), then deletes
  the install folder. Optionally removes the IIS site + webroot, the firewall
  rules, and (only with -RemoveDatabase) drops the SQL database.

  Double-click Uninstall.cmd (self-elevates via UAC), or run:
      .\Uninstall-DSMT.ps1
  No prompts (unattended):
      .\Uninstall-DSMT.ps1 -Yes
  Full cleanup incl. IIS + firewall (keeps the SQL database):
      .\Uninstall-DSMT.ps1 -RemoveIisSite -RemoveFirewall -Yes

  COMPATIBILITY: Windows PowerShell 5.1 (no ternary / ?? / && ; ASCII only).
#>
[CmdletBinding()]
param(
    [string] $InstallDir   = "C:\Program Files\DSMT",
    [string] $ServiceName  = "DSMT-Api",
    [string] $SiteName     = "DSMT",
    [string] $WebRoot      = "C:\inetpub\dsmt",
    [int]    $ApiPort      = 8780,
    [int]    $FrontendPort = 8080,
    [switch] $RemoveIisSite,    # also remove the IIS site + webroot
    [switch] $RemoveFirewall,   # also remove the DSMT firewall rules
    [switch] $RemoveDatabase,   # also DROP the SQL database (prompts for server/name)
    [switch] $RemoveLogs,       # also delete <InstallDir>\logs (default: the logs folder is KEPT)
    [switch] $Yes               # skip the confirmation prompt
)

$ErrorActionPreference = "Stop"

# --- Self-elevate if not already an administrator ---------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Requesting administrator rights (UAC) ..." -ForegroundColor Yellow
    $a = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ('"' + $MyInvocation.MyCommand.Path + '"'))
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $a += "-$k" } }
        else { $a += @("-$k", ('"' + $v + '"')) }
    }
    try { Start-Process powershell.exe -ArgumentList $a -Verb RunAs | Out-Null }
    catch { Write-Host "Elevation was cancelled. Right-click Uninstall.cmd and choose 'Run as administrator'." -ForegroundColor Red }
    return
}

function Ok($m)   { Write-Host $m -ForegroundColor Green }
function Note($m) { Write-Host $m -ForegroundColor Yellow }
function Step($m) { Write-Host ""; Write-Host ("=== {0} ===" -f $m) -ForegroundColor Cyan }

Write-Host ""
Write-Host "Directory Services Management Tool - uninstaller" -ForegroundColor White
Write-Host "------------------------------------------------" -ForegroundColor DarkGray
Write-Host ("Service : {0}" -f $ServiceName)
Write-Host ("Folder  : {0}" -f $InstallDir)
if ($RemoveIisSite)  { Write-Host ("IIS site: {0}  (+ {1})" -f $SiteName, $WebRoot) }
if ($RemoveFirewall) { Write-Host ("Firewall: DSMT API {0}, DSMT Console {1}" -f $ApiPort, $FrontendPort) }
if ($RemoveDatabase) { Write-Host "Database: WILL BE DROPPED (you will be asked for the server/name)" -ForegroundColor Red }
else                 { Write-Host "Database: left intact (use -RemoveDatabase to drop it)" }

if (-not $Yes) {
    $c = Read-Host "Proceed with uninstall? Type 'yes' to continue"
    if ($c -ne "yes") { Note "Cancelled - nothing was changed."; return }
}

# --- 1) Stop + delete the Windows service ----------------------------------
Step "Stop + remove service '$ServiceName'"
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
    try { Stop-Service $ServiceName -Force -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Seconds 2
    & sc.exe delete $ServiceName | Out-Null
    Start-Sleep -Seconds 2
    Ok "Service stopped and removed."
} else { Note "Service '$ServiceName' not found (already removed)." }

# Kill any orphaned host/API process still holding a file lock.
Get-CimInstance Win32_Process -Filter "Name='DSMT-Api-Service.exe'" -ErrorAction SilentlyContinue |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }

# --- 2) Optional: IIS site + webroot ---------------------------------------
if ($RemoveIisSite) {
    Step "Remove IIS site '$SiteName' + webroot"
    try {
        Import-Module WebAdministration -ErrorAction Stop
        if (Test-Path "IIS:\Sites\$SiteName") { Remove-Website -Name $SiteName; Ok "IIS site removed." }
        else { Note "IIS site '$SiteName' not found." }
    } catch { Note "Could not remove IIS site: $($_.Exception.Message)" }
    if (Test-Path $WebRoot) {
        try { Remove-Item $WebRoot -Recurse -Force; Ok "Removed $WebRoot" }
        catch { Note "Could not remove $WebRoot : $($_.Exception.Message)" }
    }
}

# --- 3) Optional: firewall rules -------------------------------------------
if ($RemoveFirewall) {
    Step "Remove firewall rules"
    foreach ($n in @("DSMT API $ApiPort", "DSMT Console $FrontendPort")) {
        try { Get-NetFirewallRule -DisplayName $n -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue; Ok "Removed rule: $n" }
        catch { Note "Could not remove rule '$n': $($_.Exception.Message)" }
    }
}

# --- 4) Optional: drop the SQL database ------------------------------------
if ($RemoveDatabase) {
    Step "Drop SQL database"
    $dbSrv  = Read-Host "SQL server host (e.g. SQL01 or SQL01\SQLEXPRESS)"
    $dbPort = Read-Host "SQL port [1433]"; if ([string]::IsNullOrWhiteSpace($dbPort)) { $dbPort = "1433" }
    $dbName = Read-Host "Database name [DSMTOOL]"; if ([string]::IsNullOrWhiteSpace($dbName)) { $dbName = "DSMTOOL" }
    # Destructive - always require the operator to retype the database name, even with -Yes.
    Write-Host ("About to PERMANENTLY DROP database '{0}' on {1},{2}. This cannot be undone." -f $dbName, $dbSrv, $dbPort) -ForegroundColor Red
    $confirm = Read-Host ("Type the database name ('{0}') to confirm the drop, or anything else to skip" -f $dbName)
    if ($confirm -ne $dbName) { Note "Database name not confirmed - skipping database drop (database left intact)."; }
    else {
        try {
            $cs = "Server=$dbSrv,$dbPort;Database=master;Integrated Security=SSPI;Encrypt=False;TrustServerCertificate=True;Connect Timeout=15;"
            $cn = New-Object System.Data.SqlClient.SqlConnection $cs
            $cn.Open()
            $cmd = $cn.CreateCommand()
            $cmd.CommandText = "IF DB_ID(N'$dbName') IS NOT NULL BEGIN ALTER DATABASE [$dbName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$dbName]; END"
            [void]$cmd.ExecuteNonQuery()
            $cn.Close()
            Ok "Database '$dbName' dropped."
        } catch { Note "Could not drop database: $($_.Exception.Message)" }
    }
}

# --- 5) Delete the install folder ------------------------------------------
Step "Delete install folder '$InstallDir'"
# If this script is running from inside the install folder, relaunch a temp copy
# so it can finish deleting the folder without removing itself mid-run.
$self = $MyInvocation.MyCommand.Path
if ($self -and $self.ToLower().StartsWith($InstallDir.ToLower())) {
    Note "Running from inside the install folder - relaunching from %TEMP% to finish cleanup."
    $tmp = Join-Path $env:TEMP ("dsmt-uninstall-" + [guid]::NewGuid().ToString("N") + ".ps1")
    Copy-Item $self $tmp -Force
    $a = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", ('"' + $tmp + '"'), "-Yes", "-InstallDir", ('"' + $InstallDir + '"'))
    if ($RemoveLogs) { $a += "-RemoveLogs" }
    Start-Process powershell.exe -ArgumentList $a | Out-Null
    return
}
if (Test-Path $InstallDir) {
    if ($RemoveLogs) {
        try { Remove-Item $InstallDir -Recurse -Force; Ok "Removed $InstallDir (including logs)" }
        catch {
            Note "Could not fully remove $InstallDir : $($_.Exception.Message)"
            Note "A file may still be locked. Reboot and delete the folder manually, or re-run this script."
        }
    } else {
        # Default: keep the logs folder for post-uninstall troubleshooting.
        Get-ChildItem $InstallDir -Force | Where-Object { $_.Name -ne 'logs' } | ForEach-Object {
            try { Remove-Item $_.FullName -Recurse -Force } catch { Note "Could not remove $($_.FullName): $($_.Exception.Message)" }
        }
        Ok "Removed install folder (kept logs at '$InstallDir\logs'). Use -RemoveLogs to delete them too."
    }
} else { Note "Install folder '$InstallDir' not found (already removed)." }

Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host " DSMT uninstall complete." -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host ""
if (-not $Yes) { Read-Host "Press Enter to close this window" }

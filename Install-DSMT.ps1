<#
  Install-DSMT.ps1 - ALL-IN-ONE installer for the Directory Services Management Tool.
  Run ONCE from an ELEVATED Windows PowerShell (Run as administrator) on the
  domain-joined app server, from the server\ folder.

  This single script does every step end to end:
    1. Prerequisites      - RSAT-AD PowerShell + Pode (online or offline).
    2. config.json        - written from the parameters below (prompts for any
                            required value you do not pass)
    3. Database           - creates the SQL database + tables (idempotent)
    4. Local admin        - creates the break-glass console administrator
    5. API service        - registers + starts the REST API as a Windows service
    6. Frontend           - deploys the offline console to IIS and opens it

  Anything you do not pass on the command line is asked for interactively
  (required items only); everything else uses a sensible default. Re-running is
  safe - every step is idempotent.

  EXAMPLES
    # Fully interactive (just answer the prompts):
    .\Install-DSMT.ps1

    # Unattended:
    .\Install-DSMT.ps1 -SqlServer SQL01 -LdapServer DC01.lab.local `
        -BaseDN "DC=lab,DC=local" -Domains "lab.local" `
        -ServiceAccount "LAB\svc_dsmt$" -LocalAdminPassword (Read-Host -AsSecureString)

    # Backend only (skip IIS frontend):
    .\Install-DSMT.ps1 -SqlServer SQL01 -LdapServer DC01 -BaseDN "DC=lab,DC=local" -SkipFrontend

  COMPATIBILITY: Windows PowerShell 5.1 (no ternary / ?? / && operators; ASCII only).
#>
[CmdletBinding()]
param(
    # --- Database ---
    [string] $SqlServer = "",
    [int]    $SqlPort = 1433,
    [string] $DbName  = "DSMTOOL",
    [ValidateSet("Windows","SQL")][string] $SqlAuth = "Windows",
    [string] $SqlUser = "",
    [string] $SqlPassword = "",
    [switch] $EncryptSql,       # off by default - on-prem SQL by name + TLS often trips SSPI/cert-name checks

    # --- Directory ---
    [string] $LdapServer = "",
    [string] $BaseDN = "",
    [string[]] $Domains = @(),

    # --- Integrations (optional) ---
    [string] $AdConnectServer = "",
    [string] $CaConfigString  = "",

    # --- API ---
    [int]    $ApiPort = 8780,

    # --- Local console administrator (break-glass) ---
    [string] $LocalAdminUser = "administrator",
    [System.Security.SecureString] $LocalAdminPassword,

    # --- API Windows service ---
    [string] $ServiceAccount = "",          # e.g. LAB\svc_dsmt$  (blank = NetworkService)
    [System.Security.SecureString] $ServiceAccountPassword,

    # --- Frontend (IIS) ---
    [int]    $FrontendPort = 8080,
    [string] $SiteName = "DSMT",
    [string] $WebRoot = "C:\inetpub\dsmt",
    [string] $ConsoleFile = "",             # blank = ..\index.html (project root)

    # --- Deployment location ---
    [string] $InstallDir = "C:\Program Files\DSMT",  # server files + console are copied here
    [switch] $SkipDeploy,                            # run in place instead of copying

    # --- Step switches ---
    [switch] $SkipPrereqs,
    [switch] $SkipService,
    [switch] $SkipFrontend,
    [switch] $NoOpen,

    # Bootstrap-only install: skip every SQL / directory / admin question, leave
    # config.json blank so the API starts in SETUP MODE, and finish the whole
    # configuration in the browser setup wizard instead.
    [switch] $SetupViaBrowser,

    # Fully air-gapped install: never attempt any network call for prerequisites
    # (no PSGallery, no Windows Update). Requires .\vendor\Pode to be pre-staged
    # (see README "Fully offline / air-gapped installs") and, on a stripped Windows
    # image, -WindowsFeatureSource pointing at a local install-media \sources\sxs.
    [switch] $Offline,
    [string] $WindowsFeatureSource = ""
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

$script:StepNo = 0
function Step($t) {
    $script:StepNo++
    Write-Host ""
    Write-Host ("=== [{0}] {1} ===" -f $script:StepNo, $t) -ForegroundColor Cyan
}
function Ok($m)   { Write-Host $m -ForegroundColor Green }
function Note($m) { Write-Host $m -ForegroundColor Yellow }
function Ask($prompt, $default) {
    if ([string]::IsNullOrWhiteSpace($default)) { $label = $prompt }
    else { $label = "$prompt [$default]" }
    $a = Read-Host $label
    if ([string]::IsNullOrWhiteSpace($a)) { return $default }
    return $a
}

# --- Must be elevated -------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { throw "Please run this script from an ELEVATED PowerShell (Run as administrator)." }

Write-Host ""
Write-Host "Directory Services Management Tool - all-in-one installer" -ForegroundColor White
Write-Host "---------------------------------------------------------" -ForegroundColor DarkGray

# ===========================================================================
# Gather required values (prompt only for what was not supplied)
# ===========================================================================
Step "Collect configuration"

if ($SetupViaBrowser) {
    Note "Browser-setup mode: SQL / directory / admin questions are skipped."
    Note "You will complete them in the web setup wizard after the service starts."
    $SqlServer = ""; $DbName = ""; $SqlUser = ""; $SqlPassword = ""
    $LdapServer = ""; $BaseDN = ""
}

if (-not $SetupViaBrowser) {

if ([string]::IsNullOrWhiteSpace($SqlServer))  { $SqlServer  = Ask "SQL Server host (e.g. SQL01 or SQL01\SQLEXPRESS)" "" }
while ([string]::IsNullOrWhiteSpace($SqlServer)) { $SqlServer = Ask "SQL Server host is required" "" }

$DbName = Ask "Database name" $DbName

if ([string]::IsNullOrWhiteSpace($SqlUser) -and $SqlAuth -eq "Windows") {
    $useSql = Ask "SQL auth mode - 'Windows' (integrated) or 'SQL' (username/password)" $SqlAuth
    if ($useSql) { $SqlAuth = $useSql }
}
if ($SqlAuth -eq "SQL") {
    if ([string]::IsNullOrWhiteSpace($SqlUser))     { $SqlUser = Ask "SQL login (user id)" "sa" }
    if ([string]::IsNullOrWhiteSpace($SqlPassword)) {
        $sp = Read-Host "SQL login password" -AsSecureString
        $SqlPassword = [System.Net.NetworkCredential]::new('', $sp).Password
    }
}

if ([string]::IsNullOrWhiteSpace($LdapServer)) { $LdapServer = Ask "Domain controller / LDAP host (e.g. DC01.lab.local)" "" }
while ([string]::IsNullOrWhiteSpace($LdapServer)) { $LdapServer = Ask "LDAP host is required" "" }

if ([string]::IsNullOrWhiteSpace($BaseDN)) {
    # Offer a guess from the LDAP host's DNS suffix.
    $guess = ""
    if ($LdapServer -like "*.*") {
        $suffix = $LdapServer.Substring($LdapServer.IndexOf('.') + 1)
        $guess = "DC=" + (($suffix -split '\.') -join ',DC=')
    }
    $BaseDN = Ask "Base DN" $guess
}
while ([string]::IsNullOrWhiteSpace($BaseDN)) { $BaseDN = Ask "Base DN is required (e.g. DC=lab,DC=local)" "" }

if (-not $Domains -or $Domains.Count -eq 0) {
    $d = Ask "Allowed sign-in domains (comma-separated, optional)" ""
    if (-not [string]::IsNullOrWhiteSpace($d)) { $Domains = @($d -split '\s*,\s*' | Where-Object { $_ }) }
}

}  # end of interactive questions (skipped with -SetupViaBrowser)

$ApiPort      = [int](Ask "API port" $ApiPort)
if (-not $SkipFrontend) { $FrontendPort = [int](Ask "Console (IIS) port" $FrontendPort) }

# CORS origin: lock to the console URL if frontend is hosted, else allow all.
if ($SkipFrontend) { $ConsoleUrl = "*" }
else { $ConsoleUrl = "http://localhost:$FrontendPort" }

# ===========================================================================
# Deploy program files to a permanent location, so the service never runs from
# a temp/copy folder (which Windows may clean up). Everything below this point
# operates on the install location.
# ===========================================================================
if (-not $SkipDeploy) {
    Step "Deploy program files to $InstallDir"
    $targetServer = Join-Path $InstallDir "server"
    if ($here -ieq $targetServer) {
        Ok "Already running from the install location ($targetServer)."
    } else {
        New-Item -ItemType Directory -Path $targetServer -Force | Out-Null
        # Copy the whole server folder (DSMT_Api.ps1, modules, sql, vendor, installers).
        Copy-Item -Path (Join-Path $here '*') -Destination $targetServer -Recurse -Force
        # The console (index.html) is deployed straight to IIS later - no need to
        # stage a copy under Program Files. Point the IIS step at the original file.
        if ([string]::IsNullOrWhiteSpace($ConsoleFile)) {
            $oc = Join-Path $root "index.html"
            if (Test-Path $oc) { $ConsoleFile = $oc }
        }
        Ok ("Copied server files to {0}" -f $targetServer)
        # Re-point every later step (config, schema, service, console) at the install location.
        $here = $targetServer
        $root = $InstallDir
    }
}

# ===========================================================================
# 1) Prerequisites
# ===========================================================================
if (-not $SkipPrereqs) {
    Step "Install prerequisites (RSAT-AD + Pode)"
    if ($Offline) { Note "Offline mode: no PSGallery or Windows Update calls will be attempted." }

    # RSAT AD tools
    $rsatArgs = @{ Name = "RSAT-AD-PowerShell"; ErrorAction = "Stop" }
    if ($WindowsFeatureSource) { $rsatArgs["Source"] = $WindowsFeatureSource }
    try { Install-WindowsFeature @rsatArgs | Out-Null; Ok "RSAT-AD-PowerShell present." }
    catch {
        if ($Offline) {
            Note "Could not install RSAT-AD-PowerShell from a local source: $($_.Exception.Message)"
            Note "OFFLINE FIX: pass -WindowsFeatureSource pointing at <mounted Windows ISO>\sources\sxs (or a local WIM), then re-run."
        } else {
            try { Enable-WindowsOptionalFeature -Online -FeatureName RSATClient-Roles-AD-Powershell -All -NoRestart -ErrorAction Stop | Out-Null; Ok "RSAT AD tools enabled." }
            catch { Note "Could not auto-install RSAT AD tools: $($_.Exception.Message)" }
        }
    }

    # Pode - offline from .\vendor\Pode, or online from PSGallery (skipped entirely with -Offline)
    if (Get-Module -ListAvailable Pode) {
        Ok "Pode already installed."
    } else {
        $vendorPode = Join-Path $here "vendor\Pode"
        if (Test-Path $vendorPode) {
            $dest = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) "WindowsPowerShell\Modules\Pode"
            Note "Installing Pode from bundled vendor folder (offline) ..."
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            Copy-Item -Path (Join-Path $vendorPode "*") -Destination $dest -Recurse -Force
            Ok "Pode installed (offline)."
        } elseif ($Offline) {
            Note "OFFLINE FIX: on any PC with internet, run:"
            Note "    Save-Module -Name Pode -Path .\vendor"
            Note "  then copy the resulting server\vendor\Pode folder here and re-run with -Offline."
            throw "Pode is required to run the API and .\vendor\Pode was not found (-Offline set, skipping PSGallery)."
        } else {
            try {
                # Install the NuGet provider + trust PSGallery up front so PowerShellGet
                # never stops to prompt "install NuGet provider? [Y/N]" during an unattended run.
                try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
                try { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction Stop | Out-Null } catch {}
                try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch {}
                Install-Module Pode -Scope AllUsers -Force -AllowClobber -Confirm:$false -ErrorAction Stop
                Ok "Pode installed (online)."
            } catch {
                Note "Could not install Pode online and no .\vendor\Pode found."
                Note "OFFLINE FIX: on an internet PC run  Save-Module -Name Pode -Path .\vendor  then copy server\vendor\ here and re-run."
                throw "Pode is required to run the API."
            }
        }
    }

    Ok "Prerequisites done."
}

# ===========================================================================
# 2) Write config.json
# ===========================================================================
Step "Write config.json"
$cfg = [ordered]@{
    Api = [ordered]@{
        ListenAddress = "0.0.0.0"; Port = $ApiPort; Protocol = "http"
        CorsOrigins = @($ConsoleUrl); TokenTtlHours = 8
        RequireMfa = $false; AllowSsoSignIn = $false; CertThumbprint = ""
    }
    Database = [ordered]@{
        Engine = "SQL Server"; Server = $SqlServer; Port = $SqlPort; Name = $DbName
        Auth = $SqlAuth; User = $SqlUser; Password = $SqlPassword
        Encrypt = [bool]$EncryptSql; TrustServerCertificate = $true
    }
    Directory = [ordered]@{
        LdapServer = $LdapServer; BaseDN = $BaseDN; UseSsl = $false
        Domains = @($Domains); BindUser = ""; BindPassword = ""
    }
    Sync = [ordered]@{ ADConnectServer = $AdConnectServer }
    CertificateAuthority = [ordered]@{ ConfigString = $CaConfigString }
}
$cfgPath = Join-Path $here "config.json"
$cfg | ConvertTo-Json -Depth 6 | Set-Content -Path $cfgPath -Encoding UTF8
Ok "Wrote $cfgPath"

# ===========================================================================
# Deployment metadata in the registry. Only metadata lives here - the actual
# settings stay in config.json (bootstrap) and SQL (everything else), where
# the API and console already read them.
# ===========================================================================
Step "Write registry metadata (HKLM:\SOFTWARE\DSMT)"
try {
    if (-not (Test-Path 'HKLM:\SOFTWARE\DSMT')) { New-Item -Path 'HKLM:\SOFTWARE\DSMT' -Force | Out-Null }
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\DSMT' -Name 'InstallDir'   -Value $InstallDir
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\DSMT' -Name 'Version'      -Value '3.28.0'
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\DSMT' -Name 'ApiPort'      -Value $ApiPort
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\DSMT' -Name 'FrontendPort' -Value $FrontendPort
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\DSMT' -Name 'ConfigPath'   -Value $cfgPath
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\DSMT' -Name 'SetupMode'    -Value $(if ($SetupViaBrowser) { 'browser-pending' } else { 'script' })
    Ok "Registry metadata written."
} catch { Note ("Could not write registry metadata: " + $_.Exception.Message) }

# ===========================================================================
# 3) Create database + tables   (skipped with -SetupViaBrowser: the web
#    wizard creates the database, seeds the admin and writes config.json)
# ===========================================================================
if ($SetupViaBrowser) {
    Step "Create database + local administrator"
    Note "Skipped - the web setup wizard will do this. The API starts in SETUP MODE."
} else {
Step "Create database '$DbName' + tables"
$schemaPath = Join-Path $here "sql\schema.sql"
if (-not (Test-Path $schemaPath)) { throw "schema.sql not found at $schemaPath" }
$schema = (Get-Content $schemaPath -Raw) -replace 'DSMTOOL', $DbName

$srv = "$SqlServer,$SqlPort"
$encStr = if ($EncryptSql) { "True" } else { "False" }
if ($SqlAuth -eq "SQL") {
    $masterCs = "Server=$srv;Database=master;User Id=$SqlUser;Password=$SqlPassword;Encrypt=$encStr;TrustServerCertificate=True;Connect Timeout=15;"
} else {
    $masterCs = "Server=$srv;Database=master;Integrated Security=SSPI;Encrypt=$encStr;TrustServerCertificate=True;Connect Timeout=15;"
}
$conn = New-Object System.Data.SqlClient.SqlConnection $masterCs
Note ("Connecting to SQL: " + ($masterCs -replace '(?i)(Password\s*=)[^;]*', '$1***'))
try { $conn.Open() }
catch {
    Write-Host ""
    Write-Host ("SQL connection failed: " + $_.Exception.Message) -ForegroundColor Red
    if ($_.Exception.Message -match 'SSPI|target principal name|principal name is incorrect') {
        Note "This is a Kerberos/TLS-identity error (not a missing database). Common fixes:"
        Note ("  - Confirm you are running the LATEST installer: this build connects with Encrypt=$encStr.")
        Note "    If the line above shows Encrypt=True you are running an OLD copy - re-copy the updated package."
        Note "  - Or re-run with SQL authentication:  .\Install-DSMT.ps1 -SqlAuth SQL -SqlUser <login> -SqlPassword <pwd>"
        Note "  - Or fix the SQL SPN / check time sync between this server and the domain controller."
    }
    throw
}
try {
    foreach ($batch in ($schema -split '(?im)^\s*GO\s*$')) {
        if ($batch.Trim()) {
            $cmd = $conn.CreateCommand()
            $cmd.CommandText = $batch
            [void]$cmd.ExecuteNonQuery()
        }
    }
} finally { $conn.Close() }
Ok "Database schema created / verified."

# Grant the service's RUNTIME identity access to the database. The service runs as
# NetworkService (= the computer account DOMAIN\<host>$) unless -ServiceAccount is set,
# and THAT identity - not the admin running this installer - is what connects to SQL.
# (This is why a fresh install can show "Login failed for user 'DOMAIN\<host>$'".)
if (-not [string]::IsNullOrWhiteSpace($ServiceAccount)) { $sqlPrincipal = $ServiceAccount }
else { $sqlPrincipal = "$($env:USERDOMAIN)\$($env:COMPUTERNAME)`$" }
if ($SqlAuth -ne "SQL") {
    try {
        $gc = New-Object System.Data.SqlClient.SqlConnection $masterCs
        $gc.Open()
        $b1 = "IF SUSER_ID(N'$sqlPrincipal') IS NULL CREATE LOGIN [$sqlPrincipal] FROM WINDOWS;"
        $b2 = "USE [$DbName]; IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name=N'$sqlPrincipal') CREATE USER [$sqlPrincipal] FOR LOGIN [$sqlPrincipal]; ALTER ROLE db_datareader ADD MEMBER [$sqlPrincipal]; ALTER ROLE db_datawriter ADD MEMBER [$sqlPrincipal];"
        foreach ($b in @($b1, $b2)) { $c2 = $gc.CreateCommand(); $c2.CommandText = $b; [void]$c2.ExecuteNonQuery() }
        $gc.Close()
        Ok "Granted SQL access to service account '$sqlPrincipal' (db_datareader + db_datawriter on $DbName)."
    } catch {
        Note "Could not auto-grant SQL access to '$sqlPrincipal': $($_.Exception.Message)"
        Note "Grant it manually on the SQL server (as a sysadmin):"
        Note "    CREATE LOGIN [$sqlPrincipal] FROM WINDOWS;"
        Note "    USE [$DbName]; CREATE USER [$sqlPrincipal] FOR LOGIN [$sqlPrincipal];"
        Note "    ALTER ROLE db_datareader ADD MEMBER [$sqlPrincipal]; ALTER ROLE db_datawriter ADD MEMBER [$sqlPrincipal];"
    }
} else {
    Note "SQL authentication in use - ensure login '$SqlUser' has db_datareader/db_datawriter on $DbName."
}

# ===========================================================================
# 4) Local console administrator (break-glass)
# ===========================================================================
Step "Create local administrator '$LocalAdminUser'"
Import-Module (Join-Path $here "modules\Db.psm1")   -Force
Import-Module (Join-Path $here "modules\Auth.psm1") -Force
Initialize-Db -DbConfig $cfg.Database

if (-not $LocalAdminPassword) {
    $LocalAdminPassword = Read-Host "Set a password for local '$LocalAdminUser'" -AsSecureString
}
$plain = [System.Net.NetworkCredential]::new('', $LocalAdminPassword).Password
if ([string]::IsNullOrWhiteSpace($plain)) { throw "Local administrator password cannot be empty." }
$h = New-PasswordHash -Password $plain
Invoke-Sql @'
MERGE dbo.LocalAccounts AS t USING (SELECT @u AS Username) AS s ON t.Username=s.Username
WHEN MATCHED THEN UPDATE SET PwHash=@h, PwSalt=@s, Iterations=@i, Enabled=1
WHEN NOT MATCHED THEN INSERT(Username,ConsoleRole,PwHash,PwSalt,Iterations,Enabled,BuiltIn)
  VALUES(@u,'Local Administrator',@h,@s,@i,1,1);
'@ @{ u=$LocalAdminUser; h=$h.Hash; s=$h.Salt; i=$h.Iterations } -NonQuery | Out-Null
Ok "Local administrator '$LocalAdminUser' set."

}  # end of database + admin steps (skipped with -SetupViaBrowser)

# ===========================================================================
# 5) Register + start the API as a Windows service
# ===========================================================================
$serviceStarted = $false
if (-not $SkipService) {
    Step "Register + start API service (DSMT-Api)"

    $psExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $psExe) { $psExe = (Get-Command powershell).Source }
    $api    = Join-Path $here "DSMT_Api.ps1"
    $svcExe = Join-Path $here "DSMT-Api-Service.exe"

    # Remove any prior registration so re-runs are clean (also frees the .exe).
    $existing = Get-Service -Name DSMT-Api -ErrorAction SilentlyContinue
    if ($existing) {
        try { Stop-Service DSMT-Api -Force -ErrorAction SilentlyContinue } catch {}
        & sc.exe delete DSMT-Api | Out-Null
        Start-Sleep -Seconds 2
    }

    # Compile a tiny native Windows service host with the in-box .NET compiler.
    # It launches the API and keeps it alive. This is a REAL Windows service -
    # change its logon account any time in services.msc.
    $logDir = Join-Path $root "logs"
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    Note "Building native Windows service host (logs -> $logDir) ..."
    $svcSrc = @'
using System; using System.IO; using System.ServiceProcess; using System.Diagnostics; using System.Threading;
public class DsmtService : ServiceBase {
  private Process _p; private bool _stopping = false; private Thread _watch;
  private string _logDir = @"__LOGDIR__"; private object _lock = new object();
  public DsmtService() { this.ServiceName = "DSMT-Api"; this.CanStop = true; this.CanShutdown = true; }
  private void Log(string m) {
    try { lock (_lock) { Directory.CreateDirectory(_logDir);
      File.AppendAllText(Path.Combine(_logDir, "dsmt-service.log"), DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + m + Environment.NewLine); } } catch {}
  }
  protected override void OnStart(string[] args) { _stopping = false; Log("Service OnStart"); Spawn(); _watch = new Thread(Watch); _watch.IsBackground = true; _watch.Start(); }
  private void Spawn() {
    Log("Starting API process");
    var psi = new ProcessStartInfo();
    psi.FileName = @"__PSEXE__";
    psi.Arguments = @"-NoProfile -ExecutionPolicy Bypass -File ""__API__""";
    psi.WorkingDirectory = @"__HERE__";
    psi.UseShellExecute = false; psi.CreateNoWindow = true;
    psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
    _p = new Process(); _p.StartInfo = psi;
    _p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) Log("OUT " + e.Data); };
    _p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { if (e.Data != null) Log("ERR " + e.Data); };
    _p.Start(); _p.BeginOutputReadLine(); _p.BeginErrorReadLine();
    Log("API process started, PID " + _p.Id);
  }
  private string SafeExit() { try { return _p.ExitCode.ToString(); } catch { return "?"; } }
  private void Watch() { while (!_stopping) { try { if (_p != null) _p.WaitForExit(); } catch {} if (_stopping) break; Log("API process exited (code " + SafeExit() + ") - restarting in 3s"); Thread.Sleep(3000); try { Spawn(); } catch (Exception ex) { Log("Respawn failed: " + ex.Message); } } }
  protected override void OnStop() { _stopping = true; Log("Service OnStop"); Kill(); }
  protected override void OnShutdown() { _stopping = true; Log("Service OnShutdown"); Kill(); }
  private void Kill() { try { if (_p != null && !_p.HasExited) _p.Kill(); } catch {} }
  public static void Main() { ServiceBase.Run(new DsmtService()); }
}
'@
    $svcSrc = $svcSrc.Replace('__PSEXE__', $psExe).Replace('__API__', $api).Replace('__HERE__', $here).Replace('__LOGDIR__', $logDir)
    if (Test-Path $svcExe) { try { Remove-Item $svcExe -Force } catch {} }
    Add-Type -TypeDefinition $svcSrc -ReferencedAssemblies "System.ServiceProcess" -OutputAssembly $svcExe -OutputType ConsoleApplication -ErrorAction Stop
    New-Service -Name DSMT-Api -BinaryPathName ('"' + $svcExe + '"') -DisplayName "DSMT API" -Description "Directory Services Management Tool - REST API" -StartupType Automatic | Out-Null
    Ok "Native service DSMT-Api registered."

    # Logon account: default NetworkService (authenticates on the network as the
    # computer account DOMAIN\<server>$). Pass -ServiceAccount for a gMSA / domain
    # account, or just change it later in services.msc (Log On tab).
    $obj = "NT AUTHORITY\NetworkService"; $svcPlain = ""
    if (-not [string]::IsNullOrWhiteSpace($ServiceAccount)) {
        $obj = $ServiceAccount
        if ($ServiceAccount.EndsWith('$')) { $svcPlain = "" }   # gMSA - no password
        else {
            if (-not $ServiceAccountPassword) { $ServiceAccountPassword = Read-Host "Password for service account $ServiceAccount" -AsSecureString }
            $svcPlain = [System.Net.NetworkCredential]::new('', $ServiceAccountPassword).Password
        }
    }
    & sc.exe config DSMT-Api obj= "$obj" password= "$svcPlain" | Out-Null
    & sc.exe failure DSMT-Api reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
    Ok ("Service logon account: {0}" -f $obj)

    # Let the service account write to the log folder (Program Files is read-only otherwise).
    try { & icacls "$logDir" /grant ("{0}:(OI)(CI)M" -f $obj) /T | Out-Null; Ok ("Log folder: {0}" -f $logDir) } catch { Note "Could not set permissions on $logDir : $($_.Exception.Message)" }

    # Open the API port (lab convenience).
    try { New-NetFirewallRule -DisplayName "DSMT API $ApiPort" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $ApiPort -ErrorAction SilentlyContinue | Out-Null } catch {}

    Start-Service DSMT-Api -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $svc = Get-Service DSMT-Api -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { $serviceStarted = $true; Ok "Service DSMT-Api installed and running." }
    else { $st = "unknown"; if ($svc) { $st = $svc.Status }; Note "Service DSMT-Api installed but status is $st. Check the Application event log." }
} else {
    Note "Skipping service registration (-SkipService). Foreground start:"
    Note "    powershell -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $here 'DSMT_Api.ps1')`""
}

# ===========================================================================
# 6) Deploy the offline console to IIS
# ===========================================================================
if (-not $SkipFrontend) {
    Step "Deploy console to IIS (site '$SiteName' on port $FrontendPort)"

    if ([string]::IsNullOrWhiteSpace($ConsoleFile)) { $ConsoleFile = Join-Path $root "index.html" }
    if (-not (Test-Path $ConsoleFile)) { throw "Console file not found: $ConsoleFile  - pass -ConsoleFile with the path to the offline index.html." }

    # Enable IIS (Server vs client OS).
    $iisArgs = @{ Name = @("Web-Server","Web-Static-Content","Web-Mgmt-Console"); ErrorAction = "Stop" }
    if ($WindowsFeatureSource) { $iisArgs["Source"] = $WindowsFeatureSource }
    try {
        Install-WindowsFeature @iisArgs | Out-Null
    } catch {
        if ($Offline) {
            Note "OFFLINE FIX: pass -WindowsFeatureSource pointing at <mounted Windows ISO>\sources\sxs (or a local WIM), then re-run."
            throw "Could not enable IIS from a local source: $($_.Exception.Message)"
        }
        Enable-WindowsOptionalFeature -Online -FeatureName IIS-WebServerRole,IIS-WebServer,IIS-StaticContent,IIS-WebServerManagementTools,IIS-ManagementConsole -All -NoRestart | Out-Null
    }
    Import-Module WebAdministration

    New-Item -ItemType Directory -Path $WebRoot -Force | Out-Null
    Copy-Item -Path $ConsoleFile -Destination (Join-Path $WebRoot "index.html") -Force
    Ok "Copied console -> $WebRoot\index.html"

    if (Test-Path "IIS:\Sites\$SiteName") {
        Set-ItemProperty "IIS:\Sites\$SiteName" -Name physicalPath -Value $WebRoot
        Get-WebBinding -Name $SiteName | Remove-WebBinding
        New-WebBinding -Name $SiteName -Protocol http -Port $FrontendPort
    } else {
        New-Website -Name $SiteName -Port $FrontendPort -PhysicalPath $WebRoot | Out-Null
    }
    Start-Website -Name $SiteName -ErrorAction SilentlyContinue

    try { New-NetFirewallRule -DisplayName "DSMT Console $FrontendPort" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $FrontendPort -ErrorAction SilentlyContinue | Out-Null } catch {}
    Ok "IIS site '$SiteName' is serving the console."
} else {
    Note "Skipping frontend (-SkipFrontend)."
}

# ===========================================================================
# Done
# ===========================================================================
Write-Host ""
Write-Host "==============================================" -ForegroundColor Green
Write-Host " DSMT installation complete." -ForegroundColor Green
Write-Host "==============================================" -ForegroundColor Green
Write-Host ""
Write-Host ("API:      http://localhost:{0}/api/health" -f $ApiPort)
if (-not $SkipFrontend) { Write-Host ("Console:  http://localhost:{0}/" -f $FrontendPort) }
if ($SetupViaBrowser) {
    Write-Host ""
    Write-Host "NEXT STEP - finish setup in the browser:" -ForegroundColor Yellow
    Write-Host ("  1. Open http://localhost:{0}/ and switch the sign-in screen toggle to Live" -f $FrontendPort)
    Write-Host ("     (API URL: http://localhost:{0})" -f $ApiPort)
    Write-Host "  2. Click 'Run the setup wizard' and answer the SQL / directory questions there."
    Write-Host "  3. Sign in with the administrator you created in the wizard (default admin / admin)"
    Write-Host "     and follow the alerts to finish: change the default password and map an LDAP"
    Write-Host "     security group to the System Administrator role."
} else {
    Write-Host ("Sign in:  {0} (local administrator)" -f $LocalAdminUser)
}
if (-not $SkipDeploy) { Write-Host ("Files:    {0}  (service runs from {0}\server)" -f $InstallDir) }
Write-Host ""

if ($serviceStarted) {
    try {
        Start-Sleep -Seconds 1
        $health = Invoke-RestMethod -Uri ("http://localhost:{0}/api/health" -f $ApiPort) -TimeoutSec 5
        Ok "API health check responded."
    } catch {
        Note "API service is running but the health check did not respond yet - give it a few seconds."
    }
}

$consoleUrlFinal = "http://localhost:$FrontendPort/"
if (-not $SkipFrontend -and -not $NoOpen) { Start-Process $consoleUrlFinal }

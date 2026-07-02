<#
  Install.ps1 - one-time setup for the Directory Services Management Tool API.
  Run from an elevated Windows PowerShell on the (domain-joined) app server.

  Examples:
    .\Install.ps1 -Prereqs
    .\Install.ps1 -InitDb
    .\Install.ps1 -SeedLocalAdmin -LocalAdminUser administrator
    .\Install.ps1 -RegisterService
#>
[CmdletBinding()]
param(
    [switch] $Prereqs,
    [switch] $InitDb,
    [switch] $SeedLocalAdmin,
    [string] $LocalAdminUser = 'administrator',
    [switch] $RegisterService,
    [string] $ServiceAccount             # e.g. LAB\svc_dsmt  (omit to use NetworkService)
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$cfgPath = Join-Path $here 'config.json'

function Require-Config {
    if (-not (Test-Path $cfgPath)) {
        Copy-Item (Join-Path $here 'config.sample.json') $cfgPath
        Write-Warning "Created config.json from sample. EDIT it for your environment, then re-run."
        exit 1
    }
    return Get-Content $cfgPath -Raw | ConvertFrom-Json
}

if ($Prereqs) {
    Write-Host '== Installing prerequisites ==' -ForegroundColor Cyan
    # RSAT AD tools (for ActiveDirectory module)
    try { Install-WindowsFeature RSAT-AD-PowerShell -ErrorAction Stop } catch { Write-Warning $_ }
    # Pode web framework - online from PSGallery, or offline from .\vendor\Pode
    if (-not (Get-Module -ListAvailable Pode)) {
        $vendor = Join-Path $here 'vendor\Pode'
        if (Test-Path $vendor) {
            $dest = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'WindowsPowerShell\Modules\Pode'
            Write-Host "Installing Pode from bundled vendor folder (offline) ..." -ForegroundColor Cyan
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            Copy-Item -Path (Join-Path $vendor '*') -Destination $dest -Recurse -Force
        } else {
            try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
            try { Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers -ErrorAction Stop | Out-Null } catch {}
            try { Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue } catch {}
            try { Install-Module Pode -Scope AllUsers -Force -AllowClobber -Confirm:$false -ErrorAction Stop }
            catch {
                Write-Warning "Could not install Pode online and no .\vendor\Pode found."
                Write-Warning "OFFLINE: on a PC with internet run  Save-Module -Name Pode -Path .\vendor  then copy server\vendor\ here and re-run."
            }
        }
    }
    Write-Host 'Prereqs done.' -ForegroundColor Green
}

if ($InitDb) {
    $cfg = Require-Config
    Write-Host '== Creating database schema ==' -ForegroundColor Cyan
    $schema = Get-Content (Join-Path $here 'sql/schema.sql') -Raw
    # Connect to master to allow CREATE DATABASE; uses the same auth as the API.
    # Encrypt must come from config.json (not left to the driver's default) - newer
    # System.Data.SqlClient builds default Encrypt to True, which trips
    # "The target principal name is incorrect. Cannot generate SSPI context" against
    # an on-prem SQL Server with Windows auth and no matching TLS certificate/SPN.
    $srv = "$($cfg.Database.Server),$($cfg.Database.Port)"
    $encStr = if ($cfg.Database.Encrypt) { 'True' } else { 'False' }
    if ($cfg.Database.Auth -eq 'SQL') {
        $cs = "Server=$srv;Database=master;User Id=$($cfg.Database.User);Password=$($cfg.Database.Password);Encrypt=$encStr;TrustServerCertificate=True;Connect Timeout=15;"
    } else {
        $cs = "Server=$srv;Database=master;Integrated Security=SSPI;Encrypt=$encStr;TrustServerCertificate=True;Connect Timeout=15;"
    }
    $conn = New-Object System.Data.SqlClient.SqlConnection $cs
    $conn.Open()
    foreach ($batch in ($schema -split '(?im)^\s*GO\s*$')) {
        if ($batch.Trim()) { $cmd = $conn.CreateCommand(); $cmd.CommandText = $batch; [void]$cmd.ExecuteNonQuery() }
    }
    $conn.Close()
    Write-Host 'Schema created.' -ForegroundColor Green
}

if ($SeedLocalAdmin) {
    $cfg = Require-Config
    Import-Module (Join-Path $here 'modules/Db.psm1') -Force
    Import-Module (Join-Path $here 'modules/Auth.psm1') -Force
    Initialize-Db -DbConfig $cfg.Database
    $pw  = Read-Host "New password for local '$LocalAdminUser'" -AsSecureString
    $plain = [System.Net.NetworkCredential]::new('', $pw).Password
    $h = New-PasswordHash -Password $plain
    Invoke-Sql @'
MERGE dbo.LocalAccounts AS t USING (SELECT @u AS Username) AS s ON t.Username=s.Username
WHEN MATCHED THEN UPDATE SET PwHash=@h, PwSalt=@s, Iterations=@i, Enabled=1
WHEN NOT MATCHED THEN INSERT(Username,ConsoleRole,PwHash,PwSalt,Iterations,Enabled,BuiltIn)
  VALUES(@u,'Local Administrator',@h,@s,@i,1,1);
'@ @{ u=$LocalAdminUser; h=$h.Hash; s=$h.Salt; i=$h.Iterations } -NonQuery | Out-Null
    Write-Host "Local administrator '$LocalAdminUser' set." -ForegroundColor Green
}

if ($RegisterService) {
    Write-Host '== Registering Windows service ==' -ForegroundColor Cyan
    $pwsh = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $pwsh) { $pwsh = (Get-Command powershell).Source }
    $api    = Join-Path $here 'DSMT.Api.ps1'
    $svcExe = Join-Path $here 'DSMT-Api-Service.exe'

    $existing = Get-Service -Name DSMT-Api -ErrorAction SilentlyContinue
    if ($existing) {
        try { Stop-Service DSMT-Api -Force -ErrorAction SilentlyContinue } catch {}
        & sc.exe delete DSMT-Api | Out-Null
        Start-Sleep -Seconds 2
    }

    # Compile a tiny native service host (in-box .NET compiler).
    $logDir = Join-Path (Split-Path -Parent $here) 'logs'
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
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
    $svcSrc = $svcSrc.Replace('__PSEXE__', $pwsh).Replace('__API__', $api).Replace('__HERE__', $here).Replace('__LOGDIR__', $logDir)
    if (Test-Path $svcExe) { try { Remove-Item $svcExe -Force } catch {} }
    Add-Type -TypeDefinition $svcSrc -ReferencedAssemblies 'System.ServiceProcess' -OutputAssembly $svcExe -OutputType ConsoleApplication -ErrorAction Stop
    New-Service -Name DSMT-Api -BinaryPathName ('"' + $svcExe + '"') -DisplayName 'DSMT API' -Description 'Directory Services Management Tool - REST API' -StartupType Automatic | Out-Null

    $obj = 'NT AUTHORITY\NetworkService'; $svcPlain = ''
    if ($ServiceAccount) {
        $obj = $ServiceAccount
        if (-not $ServiceAccount.EndsWith('$')) { $svcPlain = Read-Host "Password for $ServiceAccount" }
    }
    & sc.exe config DSMT-Api obj= "$obj" password= "$svcPlain" | Out-Null
    & sc.exe failure DSMT-Api reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
    try { & icacls "$logDir" /grant ("{0}:(OI)(CI)M" -f $obj) /T | Out-Null } catch {}
    Start-Service DSMT-Api
    Write-Host "Service DSMT-Api installed and started (logon: $obj; logs: $logDir)." -ForegroundColor Green
}

if (-not ($Prereqs -or $InitDb -or $SeedLocalAdmin -or $RegisterService)) {
    Write-Host 'Nothing to do. Pass -Prereqs, -InitDb, -SeedLocalAdmin and/or -RegisterService.' -ForegroundColor Yellow
}

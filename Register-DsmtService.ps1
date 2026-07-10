<#
  Register-DsmtService.ps1 - shared native-Windows-service registration logic
  for the DSMT API, used by BOTH installers (Install-DSMT.ps1's one-click flow
  and Install.ps1's -RegisterService granular command) so there is exactly one
  copy of the service-host source and the http.sys URL ACL reservation logic,
  not two that can silently drift apart.

  Dot-source this file, then call Register-DsmtApiService with the values the
  caller already collected (interactively or from parameters).
#>

function Register-DsmtApiService {
    param(
        [Parameter(Mandatory)][string] $Here,       # folder containing DSMT_Api.ps1
        [Parameter(Mandatory)][string] $Root,        # install root (logs\ lives here)
        [int]    $ApiPort = 8780,
        [string] $ServiceAccount = "",                # e.g. LAB\svc_dsmt$  (blank = NetworkService)
        [System.Security.SecureString] $ServiceAccountPassword
    )

    $psExe = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
    if (-not $psExe) { $psExe = (Get-Command powershell).Source }
    $api    = Join-Path $Here "DSMT_Api.ps1"
    $svcExe = Join-Path $Here "DSMT-Api-Service.exe"

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
    $logDir = Join-Path $Root "logs"
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    Write-Host "Building native Windows service host (logs -> $logDir) ..." -ForegroundColor Yellow
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
    $svcSrc = $svcSrc.Replace('__PSEXE__', $psExe).Replace('__API__', $api).Replace('__HERE__', $Here).Replace('__LOGDIR__', $logDir)
    if (Test-Path $svcExe) { try { Remove-Item $svcExe -Force } catch {} }
    Add-Type -TypeDefinition $svcSrc -ReferencedAssemblies "System.ServiceProcess" -OutputAssembly $svcExe -OutputType ConsoleApplication -ErrorAction Stop
    New-Service -Name DSMT-Api -BinaryPathName ('"' + $svcExe + '"') -DisplayName "DSMT API" -Description "Directory Services Management Tool - REST API" -StartupType Automatic | Out-Null
    Write-Host "Native service DSMT-Api registered." -ForegroundColor Green

    # Logon account: default NetworkService (authenticates on the network as the
    # computer account DOMAIN\<server>$). Pass -ServiceAccount for a gMSA / domain
    # account, or just change it later in services.msc (Log On tab).
    $obj = "NT AUTHORITY\NetworkService"; $svcPlain = ""
    if (-not [string]::IsNullOrWhiteSpace($ServiceAccount)) {
        $obj = $ServiceAccount
        if ($ServiceAccount.EndsWith('$')) { $svcPlain = "" }   # gMSA - no password
        elseif ($ServiceAccountPassword) { $svcPlain = [System.Net.NetworkCredential]::new('', $ServiceAccountPassword).Password }
        else { $svcPlain = Read-Host "Password for service account $ServiceAccount" }
    }
    & sc.exe config DSMT-Api obj= "$obj" password= "$svcPlain" | Out-Null
    & sc.exe failure DSMT-Api reset= 86400 actions= restart/5000/restart/5000/restart/5000 | Out-Null
    Write-Host ("Service logon account: {0}" -f $obj) -ForegroundColor Green

    # Let the service account write to the log folder (Program Files is read-only otherwise).
    try { & icacls "$logDir" /grant ("{0}:(OI)(CI)M" -f $obj) /T | Out-Null; Write-Host ("Log folder: {0}" -f $logDir) -ForegroundColor Green } catch { Write-Host "Could not set permissions on $logDir : $($_.Exception.Message)" -ForegroundColor Yellow }

    # http.sys requires an explicit URL ACL reservation for any non-admin logon
    # account (NetworkService, a domain service account, a gMSA) to bind an
    # HTTP endpoint - Pode's http listener uses http.sys underneath. Without
    # this, Add-PodeEndpoint throws "Access is denied" *inside* the child
    # process every time it starts; the native service wrapper still shows
    # "Running" (it just keeps respawning the crashing child), so the API
    # silently never listens and every request gets connection-refused.
    $urlAclUrl = "http://+:$ApiPort/"
    try {
        $existingAcl = & netsh http show urlacl url=$urlAclUrl 2>$null
        if ($existingAcl -match 'Reserved URL') { & netsh http delete urlacl url=$urlAclUrl | Out-Null }
        & netsh http add urlacl url=$urlAclUrl user="$obj" | Out-Null
        Write-Host "URL ACL reserved for $obj on $urlAclUrl" -ForegroundColor Green
    } catch {
        Write-Host "Could not reserve the URL ACL ($urlAclUrl) for $obj - the API will fail to bind. Run as admin: netsh http add urlacl url=$urlAclUrl user=`"$obj`"" -ForegroundColor Yellow
    }

    try { New-NetFirewallRule -DisplayName "DSMT API $ApiPort" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $ApiPort -ErrorAction SilentlyContinue | Out-Null } catch {}

    Start-Service DSMT-Api -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    $svc = Get-Service DSMT-Api -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") { Write-Host "Service DSMT-Api installed and running." -ForegroundColor Green; return $true }
    $st = "unknown"; if ($svc) { $st = $svc.Status }
    Write-Host "Service DSMT-Api installed but status is $st. Check the Application event log." -ForegroundColor Yellow
    return $false
}

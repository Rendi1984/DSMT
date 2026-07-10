<#
  Send-DiagReport.ps1 - standalone entry point invoked by the Windows
  scheduled task 'DSMT-DiagReport' (created/managed via the console's
  Diagnostics > Reports & Email tab, POST /api/diag/schedule).

  Deliberately independent of the running DSMT-Api service/Pode process -
  the scheduled task calls this directly with powershell.exe so the report
  still fires even if the API happens to be restarting. It reads the same
  config.json and reuses the same Diagnostics.psm1 functions the API uses
  for "Run now", so scheduled and on-demand reports are always identical.
#>

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

foreach ($m in 'Db', 'Diagnostics') {
    Import-Module (Join-Path $here "modules/$m.psm1") -Force
}

$cfgPath = Join-Path $here 'config.json'
if (-not (Test-Path $cfgPath)) { Write-Error "config.json not found at $cfgPath - cannot run scheduled report."; exit 1 }
$Config = Get-Content $cfgPath -Raw | ConvertFrom-Json

try { Initialize-Db -DbConfig $Config.Database } catch { Write-DbLog "Send-DiagReport: could not connect to SQL for audit logging - $($_.Exception.Message)" }

$dcHosts    = @($Config.Diagnostics.DcHosts -split '[,;\r\n]+' | Where-Object { $_ })
$exHosts    = @($Config.Diagnostics.ExchangeHosts -split '[,;\r\n]+' | Where-Object { $_ })
$recipients = @($Config.Diagnostics.ReportRecipients -split '[,;\r\n]+' | Where-Object { $_ })

if ($recipients.Count -eq 0) {
    Write-DbLog 'Send-DiagReport: no recipients configured - skipping.'
    exit 0
}

try {
    $r = Send-DiagnosticsReport -Smtp $Config.Smtp -DcHosts $dcHosts -ExchangeHosts $exHosts -Recipients $recipients
    Write-Audit -Actor 'SYSTEM (scheduled)' -Action 'Diagnostics report run (scheduled)' -Target ($recipients -join ',') -Result 'Success' -Kind 'diag'
} catch {
    Write-DbLog "Send-DiagReport: failed - $($_.Exception.Message)"
    try { Write-Audit -Actor 'SYSTEM (scheduled)' -Action 'Diagnostics report run (scheduled)' -Target ($recipients -join ',') -Result 'Error' -Kind 'diag' -Detail $_.Exception.Message } catch {}
    exit 1
}

<#
  DSMT.Api.ps1 - REST API for the Directory Services Management Tool.
  Built on Pode (https://badgerati.github.io/Pode/).  Run:  pwsh ./DSMT.Api.ps1
  (or via the Windows service installed by Install.ps1).

  Endpoints (all JSON):
    POST /api/auth/login        { domain, username, password } -> { token, displayName, role, isLocal }
    POST /api/auth/logout
    GET  /api/health
    GET  /api/config
    POST /api/sync              -> delta sync log
    GET  /api/sync/status
    GET  /api/dl/:group         -> distribution-list members
    GET  /api/users?q=          -> AD users
    POST /api/users/:sam/reset  / /lock / /enable
    GET  /api/contractor/:user  -> placement verdict
    GET  /api/audit?kind=
    GET  /api/ca/certs | /api/ca/pending
    POST /api/ca/publish-crl | /api/ca/revoke | /api/ca/approve/:id | /api/ca/deny/:id
#>

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---- Load config ----
$cfgPath = Join-Path $here 'config.json'
$samplePath = Join-Path $here 'config.sample.json'

# Bootstrap: if config.json is missing, seed it from the sample so the API can
# start in SETUP MODE and let the browser wizard finish the SQL connection.
if (-not (Test-Path $cfgPath)) {
    if (Test-Path $samplePath) { Copy-Item $samplePath $cfgPath -Force }
    else { throw "Neither config.json nor config.sample.json found." }
}
$Config = Get-Content $cfgPath -Raw | ConvertFrom-Json

function Save-Config {
    # Persists the in-memory $Config back to config.json (atomic-ish).
    param($Cfg = $Config)
    ($Cfg | ConvertTo-Json -Depth 8) | Set-Content -Path $cfgPath -Encoding UTF8
}

function Test-SetupComplete {
    # Setup is "done" once we have a SQL server + database name AND the schema
    # is reachable. Before that, the API runs in setup mode (no DB calls).
    param($Cfg = $Config)
    $d = $Cfg.Database
    if (-not $d -or [string]::IsNullOrWhiteSpace($d.Server) -or [string]::IsNullOrWhiteSpace($d.Name)) { return $false }
    try { Initialize-Db -DbConfig $d -ProbeOnly; return $true } catch { return $false }
}

# ---- Import modules ----
Import-Module Pode
foreach ($m in 'Db','Auth','Directory','Sync','Contractor','CertAuthority','Secrets','Diagnostics') {
    Import-Module (Join-Path $here "modules/$m.psm1") -Force
}

# Decide mode: normal (DB ready) or setup (wizard still needs to finish the SQL link).
$SetupMode = -not (Test-SetupComplete)
if (-not $SetupMode) {
    Initialize-Db -DbConfig $Config.Database
    Write-Host "DSMT API: database connected - normal mode." -ForegroundColor Green
} else {
    Write-Host "DSMT API: no database yet - SETUP MODE. Finish the wizard in the console (or edit config.json)." -ForegroundColor Yellow
}

# ---- Helpers ----
function New-Token { [Convert]::ToBase64String([guid]::NewGuid().ToByteArray()) -replace '[^A-Za-z0-9]','' }

function Get-Session {
    param($WebEvent)
    $auth = $WebEvent.Request.Headers['Authorization']
    if (-not $auth -or $auth -notlike 'Bearer *') { return $null }
    $token = $auth.Substring(7)
    $rows = Invoke-Sql 'SELECT TOP 1 Username,ConsoleRole,IsLocal,ExpiresAt FROM dbo.Sessions WHERE Token=@t' @{ t = $token }
    if (-not $rows -or $rows.Count -eq 0) { return $null }
    if ([datetime]$rows[0]['ExpiresAt'] -lt (Get-Date).ToUniversalTime()) { return $null }
    return [pscustomobject]@{ token=$token; username=$rows[0]['Username']; role=$rows[0]['ConsoleRole']; isLocal=[bool]$rows[0]['IsLocal'] }
}

Start-PodeServer {
    # Bind the values into THIS scriptblock's scope. Pode's $using: resolver only
    # reliably captures variables that live inside the Start-PodeServer block on
    # Windows PowerShell 5.1; referencing outer-script vars throws
    # "Find-PodeScopedVariableUsingVariableValue ... Key cannot be null" at startup.
    $Config = $Config
    $here   = $here
    $cs     = $Config.CertificateAuthority.ConfigString
    $proto  = $Config.Api.Protocol
    Add-PodeEndpoint -Address $Config.Api.ListenAddress -Port $Config.Api.Port -Protocol $proto

    # CORS so the static HTML console (served anywhere) can call us.
    # The middleware stamps the headers on EVERY response; the explicit catch-all
    # OPTIONS route guarantees preflight requests are routed (so the middleware
    # runs for them) and answered 204 - some Pode builds skip global middleware
    # for an OPTIONS path that has no matching route, which drops the CORS header.
    Add-PodeMiddleware -Name 'CORS' -ScriptBlock {
        Add-PodeHeader -Name 'Access-Control-Allow-Origin'  -Value '*'
        Add-PodeHeader -Name 'Access-Control-Allow-Headers' -Value 'Content-Type, Authorization'
        Add-PodeHeader -Name 'Access-Control-Allow-Methods' -Value 'GET, POST, DELETE, OPTIONS'
        return $true
    }
    Add-PodeRoute -Method Options -Path '*' -ScriptBlock { Set-PodeResponseStatus -Code 204 }

    # Write-401 stamps CORS headers before setting 401 so browsers never see
    # a CORS failure masking an auth failure (the preflight succeeds, but
    # the real request returns 401 - without CORS headers that looks like CORS).
    function Write-401 {
        Add-PodeHeader -Name 'Access-Control-Allow-Origin'  -Value '*'
        Add-PodeHeader -Name 'Access-Control-Allow-Headers' -Value 'Content-Type, Authorization'
        Add-PodeHeader -Name 'Access-Control-Allow-Methods' -Value 'GET, POST, DELETE, OPTIONS'
        Set-PodeResponseStatus -Code 401
        Write-PodeJsonResponse -Value @{ error = 'Unauthorized' }
    }

    # ---------- FILE LOGGING ----------
    # Writes Pode error logs (incl. route 500 stack traces) to <InstallDir>\logs
    # so failures can be diagnosed without attaching a debugger.
    $logDir = Join-Path (Split-Path -Parent $here) 'logs'
    try {
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        New-PodeLoggingMethod -File -Name 'dsmt-error' -Path $logDir | Enable-PodeErrorLogging
        New-PodeLoggingMethod -File -Name 'dsmt-request' -Path $logDir | Enable-PodeRequestLogging
        Write-Host "DSMT API: file logging enabled at $logDir" -ForegroundColor Green
    } catch { Write-Host "DSMT API: could not enable file logging - $($_.Exception.Message)" -ForegroundColor Yellow }

    # ---------- SETUP / BOOTSTRAP (works in setup mode, no auth) ----------
    # The browser wizard drives the first SQL connection so nobody hand-edits
    # config.json. These routes write config.json and create/seed the database.
    Add-PodeRoute -Method Get -Path '/api/setup/status' -ScriptBlock {
        $cfg = $using:Config
        Write-PodeJsonResponse -Value @{ setupComplete = (Test-SetupComplete -Cfg $cfg); database = @{ server = $cfg.Database.Server; name = $cfg.Database.Name } }
    }
    Add-PodeRoute -Method Post -Path '/api/setup/test-server' -ScriptBlock {
        Write-PodeJsonResponse -Value (Test-SqlServer -DbConfig $WebEvent.Data)
    }
    Add-PodeRoute -Method Post -Path '/api/setup/databases' -ScriptBlock {
        try { Write-PodeJsonResponse -Value @{ ok = $true; databases = @(Get-Databases -DbConfig $WebEvent.Data) } }
        catch { Write-PodeJsonResponse -Value @{ ok = $false; error = $_.Exception.Message } }
    }
    Add-PodeRoute -Method Post -Path '/api/setup/create-db' -ScriptBlock {
        $schemaPath = Join-Path $using:here 'sql/schema.sql'
        Write-PodeJsonResponse -Value (New-AppDatabase -DbConfig $WebEvent.Data -SchemaPath $schemaPath -DbName $WebEvent.Data.Name)
    }
    # Persist the SQL connection to config.json and switch the API into normal mode.
    Add-PodeRoute -Method Post -Path '/api/setup/save' -ScriptBlock {
        if (Test-SetupComplete) { Set-PodeResponseStatus -Code 409; Write-PodeJsonResponse -Value @{ error = 'Setup already complete.' }; return }
        $d = $WebEvent.Data
        $Config.Database.Engine                 = $d.Engine
        $Config.Database.Server                 = $d.Server
        $Config.Database.Port                   = [int]$d.Port
        $Config.Database.Name                   = $d.Name
        $Config.Database.Auth                   = $d.Auth
        $Config.Database.User                   = $d.User
        $Config.Database.Password               = $d.Password
        $Config.Database.Encrypt                = [bool]$d.Encrypt
        $Config.Database.TrustServerCertificate = [bool]$d.TrustServerCertificate
        Save-Config
        try { Initialize-Db -DbConfig $Config.Database -ProbeOnly; Initialize-Db -DbConfig $Config.Database; Write-PodeJsonResponse -Value @{ ok = $true } }
        catch { Write-PodeJsonResponse -Value @{ ok = $false; error = $_.Exception.Message } }
    }

    # ---------- AUTH ----------
    Add-PodeRoute -Method Post -Path '/api/auth/login' -ScriptBlock {
        $cfg = $using:Config
        $b = $WebEvent.Data
        $r = Invoke-SignIn -Config $cfg -Domain $b.domain -Username $b.username -Password $b.password
        $ip = $WebEvent.Request.RemoteEndPoint.Address.ToString()
        if (-not $r.Ok) {
            Write-Audit -Actor $b.username -Action 'Console sign-in' -Target 'console' -Result 'Denied' -Kind 'auth' -Detail $r.Reason -SourceIp $ip
            Set-PodeResponseStatus -Code 401; Write-PodeJsonResponse -Value @{ error = $r.Reason }; return
        }
        $token = New-Token
        $ttl = [int]$cfg.Api.TokenTtlHours
        Invoke-Sql 'INSERT INTO dbo.Sessions(Token,Username,ConsoleRole,IsLocal,ExpiresAt) VALUES(@t,@u,@r,@l,DATEADD(hour,@h,SYSUTCDATETIME()))' `
            @{ t=$token; u=$r.Username; r=$r.Role; l=([int][bool]$r.IsLocal); h=$ttl } -NonQuery | Out-Null
        Write-Audit -Actor $r.Username -Action 'Console sign-in' -Target 'console' -Result 'Success' -Kind 'auth' -SourceIp $ip
        Write-PodeJsonResponse -Value @{ token=$token; displayName=$r.Username; role=$r.Role; isLocal=$r.IsLocal }
    }

    Add-PodeRoute -Method Post -Path '/api/auth/logout' -ScriptBlock {
        $s = Get-Session $WebEvent
        if ($s) { Invoke-Sql 'DELETE FROM dbo.Sessions WHERE Token=@t' @{ t=$s.token } -NonQuery | Out-Null }
        Write-PodeJsonResponse -Value @{ ok=$true }
    }

    # ---------- HEALTH ----------
    Add-PodeRoute -Method Get -Path '/api/health' -ScriptBlock {
        $cfg = $using:Config
        $checks = @()
        # SQL
        try { Invoke-Sql 'SELECT 1' -Scalar | Out-Null; $checks += @{ name='SQL database'; status='ok'; detail="$($cfg.Database.Server)" } }
        catch { $checks += @{ name='SQL database'; status='down'; detail=$_.Exception.Message } }
        # LDAP (guard missing Directory section)
        $ldapServer = if ($cfg.Directory) { $cfg.Directory.LdapServer } else { $null }
        $baseDn     = if ($cfg.Directory) { $cfg.Directory.BaseDN }     else { $null }
        if (-not [string]::IsNullOrWhiteSpace($ldapServer)) {
            try {
                Get-UserGroups -Server $ldapServer -BaseDN $baseDn -SamAccountName 'krbtgt' | Out-Null
                $checks += @{ name='LDAP / domain'; status='ok'; detail=$ldapServer }
            } catch { $checks += @{ name='LDAP / domain'; status='down'; detail=$_.Exception.Message } }
        } else { $checks += @{ name='LDAP / domain'; status='warn'; detail='not configured' } }
        # AD Connect (guard missing Sync section + never let it 500 the route)
        try {
            $adc  = if ($cfg.Sync) { $cfg.Sync.ADConnectServer } else { $null }
            $sync = Get-SyncStatus -AdConnectServer $adc
            $checks += @{ name='AD Connect sync'; status=$(if($sync.ok){'ok'}else{'warn'}); detail=$(if($sync.ok){'reachable'}else{'unreachable'}) }
        } catch { $checks += @{ name='AD Connect sync'; status='warn'; detail=$_.Exception.Message } }
        Write-PodeJsonResponse -Value @{ checks=$checks }
    }

    Add-PodeRoute -Method Get -Path '/api/config' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        Write-PodeJsonResponse -Value (Get-Config)
    }

    # ---------- DATABASE SETUP (GUI) ----------
    # Body carries a database config block: { Server, Port, Name, Auth, User, Password, Encrypt, TrustServerCertificate }
    Add-PodeRoute -Method Post -Path '/api/db/test' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        Write-PodeJsonResponse -Value (Test-SqlServer -DbConfig $WebEvent.Data)
    }
    Add-PodeRoute -Method Post -Path '/api/db/list' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        try { Write-PodeJsonResponse -Value @{ ok = $true; databases = @(Get-Databases -DbConfig $WebEvent.Data) } }
        catch { Set-PodeResponseStatus -Code 400; Write-PodeJsonResponse -Value @{ ok = $false; error = $_.Exception.Message } }
    }
    Add-PodeRoute -Method Post -Path '/api/db/create' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $schema = Join-Path $using:here 'sql/schema.sql'
        $r = New-AppDatabase -DbConfig $WebEvent.Data -SchemaPath $schema -DbName $WebEvent.Data.Name
        Write-Audit -Actor $s.username -Action 'Database created' -Target $WebEvent.Data.Name -Result $(if($r.ok){'Success'}else{'Error'}) -Kind 'db' -Detail $r.error
        Write-PodeJsonResponse -Value $r
    }
    # Real connection details + status of the CONFIGURED database (drives the Database tab in Live mode).
    Add-PodeRoute -Method Get -Path '/api/db/info' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        try { Write-PodeJsonResponse -Value (Get-DbInfo) }
        catch { Set-PodeResponseStatus -Code 400; Write-PodeJsonResponse -Value @{ ok = $false; connected = $false; error = $_.Exception.Message } }
    }
    Add-PodeRoute -Method Post -Path '/api/db/migrate' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $schema = Join-Path $using:here 'sql/schema.sql'
        try {
            $r = Invoke-DbMigrate -SchemaPath $schema
            Write-Audit -Actor $s.username -Action 'Schema migrate' -Target 'database' -Result $(if($r.ok){'Success'}else{'Error'}) -Kind 'db'
            Write-PodeJsonResponse -Value $r
        } catch { Set-PodeResponseStatus -Code 400; Write-PodeJsonResponse -Value @{ ok = $false; error = $_.Exception.Message } }
    }
    Add-PodeRoute -Method Post -Path '/api/db/backup' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        try {
            $r = Invoke-DbBackup
            Write-Audit -Actor $s.username -Action 'Database backup' -Target $r.file -Result 'Success' -Kind 'db'
            Write-PodeJsonResponse -Value $r
        } catch { Set-PodeResponseStatus -Code 400; Write-PodeJsonResponse -Value @{ ok = $false; error = $_.Exception.Message } }
    }

    # ---------- SYNC ----------
    Add-PodeRoute -Method Post -Path '/api/sync' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $cfg = $using:Config
        $r = Start-DeltaSync -AdConnectServer $cfg.Sync.ADConnectServer
        Write-Audit -Actor $s.username -Action 'Delta sync cycle' -Target $cfg.Sync.ADConnectServer -Result $(if($r.ok){'Success'}else{'Error'}) -Kind 'sync'
        Write-PodeJsonResponse -Value @{ ok=$r.ok; log=$r.log }
    }
    Add-PodeRoute -Method Get -Path '/api/sync/status' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $cfg = $using:Config
        Write-PodeJsonResponse -Value (Get-SyncStatus -AdConnectServer $cfg.Sync.ADConnectServer)
    }

    # ---------- DL GROUPS ----------
    Add-PodeRoute -Method Get -Path '/api/dl/:group' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        try { Write-PodeJsonResponse -Value @{ members = @(Get-GroupMembers -GroupName $WebEvent.Parameters['group']) } }
        catch { Set-PodeResponseStatus -Code 400; Write-PodeJsonResponse -Value @{ error=$_.Exception.Message } }
    }

    # ---------- USERS ----------
    Add-PodeRoute -Method Get -Path '/api/users' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $q = $WebEvent.Query['q']
        Write-PodeJsonResponse -Value @{ users = @(Get-DirectoryUsers -Query $q) }
    }
    Add-PodeRoute -Method Post -Path '/api/users/:sam/reset' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $sam = $WebEvent.Parameters['sam']; $pw = $WebEvent.Data.password
        Reset-UserPassword -Sam $sam -NewPassword $pw -MustChange | Out-Null
        Write-Audit -Actor $s.username -Action 'Password reset' -Target $sam -Result 'Success' -Kind 'pw'
        Write-PodeJsonResponse -Value @{ ok=$true }
    }
    Add-PodeRoute -Method Post -Path '/api/users/:sam/enable' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $sam = $WebEvent.Parameters['sam']; $en = [bool]$WebEvent.Data.enabled
        Set-UserEnabled -Sam $sam -Enabled $en | Out-Null
        Write-Audit -Actor $s.username -Action $(if($en){'User enabled'}else{'User disabled'}) -Target $sam -Result 'Success' -Kind 'user'
        Write-PodeJsonResponse -Value @{ ok=$true }
    }

    # Bulk action over a list of sAMAccountNames: { action: 'disable'|'reset', sams: [...] }
    Add-PodeRoute -Method Post -Path '/api/users/bulk' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $act = $WebEvent.Data.action; $sams = @($WebEvent.Data.sams)
        foreach ($sam in $sams) {
            try {
                if ($act -eq 'disable') { Set-UserEnabled -Sam $sam -Enabled $false | Out-Null; Write-Audit -Actor $s.username -Action 'User disabled (bulk)' -Target $sam -Result 'Success' -Kind 'user' }
                elseif ($act -eq 'reset') { Reset-UserPassword -Sam $sam -NewPassword ([guid]::NewGuid().ToString('N').Substring(0,14)+'!Aa1') -MustChange | Out-Null; Write-Audit -Actor $s.username -Action 'Password reset (bulk)' -Target $sam -Result 'Success' -Kind 'pw' }
            } catch { Write-Audit -Actor $s.username -Action "Bulk $act failed" -Target $sam -Result 'Error' -Kind 'user' -Detail $_.Exception.Message }
        }
        Write-PodeJsonResponse -Value @{ ok=$true; count=$sams.Count }
    }

    # Offboard (leaver process) for a list of sAMAccountNames.
    Add-PodeRoute -Method Post -Path '/api/users/offboard' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $sams = @($WebEvent.Data.sams); $ou = (Get-Config 'ContractorExpectedSupportOU')
        $log = @()
        foreach ($sam in $sams) {
            try { Invoke-Offboard -Sam $sam | Out-Null; Write-Audit -Actor $s.username -Action 'Account offboarded' -Target $sam -Result 'Success' -Kind 'user'; $log += "Offboarded $sam" }
            catch { Write-Audit -Actor $s.username -Action 'Offboard failed' -Target $sam -Result 'Error' -Kind 'user' -Detail $_.Exception.Message; $log += "FAILED $sam : $($_.Exception.Message)" }
        }
        Write-PodeJsonResponse -Value @{ ok=$true; log=$log }
    }

    # Expiry alerts: certificates + passwords nearing expiry.
    Add-PodeRoute -Method Get -Path '/api/alerts' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $alerts = @()
        try { foreach ($c in (Get-ExpiringCertificates -ConfigString $using:cs -Days 30)) { $alerts += @{ type='Certificate'; title=$c.subject; detail=$c.template; badge="exp $($c.expires)" } } } catch {}
        try { foreach ($p in (Get-ExpiringPasswords -Days 14)) { $alerts += @{ type='Password'; title=$p.sam; detail='AD password expiring'; badge="in $($p.daysLeft)d" } } } catch {}
        Write-PodeJsonResponse -Value @{ alerts=$alerts }
    }

    # ---------- CONTRACTOR ----------
    Add-PodeRoute -Method Get -Path '/api/contractor/:user' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $cfg = $using:Config
        Write-PodeJsonResponse -Value (Get-ContractorInfo -Username $WebEvent.Parameters['user'] -Config $cfg)
    }

    # ---------- AUDIT ----------
    Add-PodeRoute -Method Get -Path '/api/audit' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        Write-PodeJsonResponse -Value @{ events = @(Get-AuditLog -Kind $WebEvent.Query['kind']) }
    }

    # ---------- CERTIFICATE AUTHORITY ----------
    Add-PodeRoute -Method Get -Path '/api/ca/certs' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        Write-PodeJsonResponse -Value @{ certs = @(Get-IssuedCertificates -ConfigString $using:cs) }
    }
    Add-PodeRoute -Method Get -Path '/api/ca/pending' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        Write-PodeJsonResponse -Value @{ pending = @(Get-PendingRequests -ConfigString $using:cs) }
    }
    Add-PodeRoute -Method Post -Path '/api/ca/ping' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $target = if ($WebEvent.Data.configString) { $WebEvent.Data.configString } else { $using:cs }
        Write-PodeJsonResponse -Value (Test-Ca -ConfigString $target)
    }
    Add-PodeRoute -Method Post -Path '/api/ca/publish-crl' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $r = Publish-Crl -ConfigString $using:cs
        Write-Audit -Actor $s.username -Action 'Publish CRL' -Target $using:cs -Result $(if($r.ok){'Success'}else{'Error'}) -Kind 'cert'
        Write-PodeJsonResponse -Value $r
    }
    Add-PodeRoute -Method Post -Path '/api/ca/revoke' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $reason = if ($WebEvent.Data.reason) { [int]$WebEvent.Data.reason } else { 4 }
        $r = Revoke-Certificate -ConfigString $using:cs -Serial $WebEvent.Data.serial -Reason $reason
        Write-Audit -Actor $s.username -Action 'Revoke certificate' -Target $WebEvent.Data.serial -Result $(if($r.ok){'Success'}else{'Error'}) -Kind 'cert'
        Write-PodeJsonResponse -Value $r
    }

    # ---------- SECRETS (DPAPI-encrypted in SQL) ----------
    Add-PodeRoute -Method Get -Path '/api/secrets' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        Write-PodeJsonResponse -Value @{ secrets = @(Get-SecretList) }   # names/metadata only
    }
    Add-PodeRoute -Method Post -Path '/api/secrets' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        Set-Secret -Name $WebEvent.Data.name -Value $WebEvent.Data.value -Account $WebEvent.Data.account -By $s.username
        Write-Audit -Actor $s.username -Action 'Secret saved' -Target $WebEvent.Data.name -Result 'Success' -Kind 'secret'
        Write-PodeJsonResponse -Value @{ ok = $true }
    }
    Add-PodeRoute -Method Post -Path '/api/secrets/test' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $cfg = $using:Config
        $ok = Test-ServiceAccount -Server $cfg.Directory.LdapServer -Account $WebEvent.Data.account -Password $WebEvent.Data.value -UseSsl:([bool]$cfg.Directory.UseSsl)
        Write-PodeJsonResponse -Value @{ ok = $ok }
    }

    # ---------- SETTINGS BACKUP / RESTORE ----------
    Add-PodeRoute -Method Get -Path '/api/settings/export' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        # Config + role mappings (NOT secrets - those never leave the server in clear).
        Write-PodeJsonResponse -Value @{ exportedAt = (Get-Date).ToString('o'); config = (Get-Config); roleMappings = @(Get-RoleMappings) }
    }
    Add-PodeRoute -Method Post -Path '/api/settings/import' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $cfg = $WebEvent.Data.config
        if ($cfg) { foreach ($k in $cfg.PSObject.Properties.Name) { Set-Config -Key $k -Value ([string]$cfg.$k) -By $s.username } }
        Write-Audit -Actor $s.username -Action 'Settings imported' -Target 'config' -Result 'Success' -Kind 'config'
        Write-PodeJsonResponse -Value @{ ok = $true }
    }

    # ---------- DIAGNOSTICS ----------
    Add-PodeRoute -Method Get -Path '/api/diag/dcs' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $m = if ($WebEvent.Query['method']) { $WebEvent.Query['method'] } else { 'auto' }
        $hosts = Get-DomainControllers -Method $m
        Write-PodeJsonResponse -Value @{ controllers = @(Test-DcServices -Hosts $hosts) }
    }
    Add-PodeRoute -Method Post -Path '/api/diag/exchange' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        # Accepts a single 'host' or a 'hosts' array - checks each member server directly.
        $hosts = if ($WebEvent.Data.hosts) { @($WebEvent.Data.hosts) } else { @($WebEvent.Data.host) }
        $results = @()
        foreach ($h in ($hosts | Where-Object { $_ })) { $results += (Test-ExchangeServer -ExchangeHost $h) }
        Write-PodeJsonResponse -Value @{ results = $results }
    }
    Add-PodeRoute -Method Post -Path '/api/diag/message' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $sim = [bool]$WebEvent.Data.simulate
        $r = Send-TestMessage -SmtpServer $WebEvent.Data.smtp -To $WebEvent.Data.to -From $WebEvent.Data.from -Subject $WebEvent.Data.subject -Body $WebEvent.Data.body -Port ([int]$WebEvent.Data.port) -Simulate:$sim -Username $WebEvent.Data.username -Password $WebEvent.Data.password -UseTls:([bool]$WebEvent.Data.useTls)
        Write-Audit -Actor $s.username -Action $(if($sim){'Test message simulated'}else{'Test message sent'}) -Target $WebEvent.Data.to -Result $(if($r.ok){'Success'}else{'Error'}) -Kind 'diag'
        Write-PodeJsonResponse -Value $r
    }

    # ---------- USER LOCK / UNLOCK ----------
    Add-PodeRoute -Method Post -Path '/api/users/:sam/lock' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $sam = $WebEvent.Parameters['sam']
        $lock = [bool]$WebEvent.Data.locked
        if ($lock) {
            # AD has no direct "lock" cmdlet; force lockout via repeated bad password
            # is not safe for automation - we disable the account instead and note it
            Set-UserEnabled -Sam $sam -Enabled $false | Out-Null
            Write-Audit -Actor $s.username -Action 'User locked (disabled)' -Target $sam -Result 'Success' -Kind 'lock'
            Write-PodeJsonResponse -Value @{ ok=$true; locked=$true }
        } else {
            Set-UserLock -Sam $sam -Unlock | Out-Null
            Set-UserEnabled -Sam $sam -Enabled $true | Out-Null
            Write-Audit -Actor $s.username -Action 'User unlocked' -Target $sam -Result 'Success' -Kind 'lock'
            Write-PodeJsonResponse -Value @{ ok=$true; locked=$false }
        }
    }

    # ---------- CREATE USER ----------
    Add-PodeRoute -Method Post -Path '/api/users' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $sam = $WebEvent.Data.sam
        $name = if ($WebEvent.Data.name) { $WebEvent.Data.name } else { $sam }
        $ou   = if ($WebEvent.Data.ou)   { $WebEvent.Data.ou }   else { $using:Config.Directory.BaseDN }
        if (-not $sam) { Set-PodeResponseStatus -Code 400; Write-PodeJsonResponse -Value @{ ok=$false; error='sam is required' }; return }
        $initPw = 'Tmp-' + [guid]::NewGuid().ToString('N').Substring(0,10) + '!Aa1'
        try {
            New-DirectoryUser -Sam $sam -DisplayName $name -Ou $ou -InitialPassword $initPw | Out-Null
            Write-Audit -Actor $s.username -Action 'User created' -Target $sam -Result 'Success' -Kind 'user'
            Write-PodeJsonResponse -Value @{ ok=$true; sam=$sam; initialPassword=$initPw }
        } catch {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ ok=$false; error=$_.Exception.Message }
        }
    }

    # ---------- GROUP MEMBERS (add / remove) ----------
    Add-PodeRoute -Method Post -Path '/api/groups/:name/members' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $group = $WebEvent.Parameters['name']
        $sam   = $WebEvent.Data.sam
        if (-not $sam) { Set-PodeResponseStatus -Code 400; Write-PodeJsonResponse -Value @{ ok=$false; error='sam is required' }; return }
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            Add-ADGroupMember -Identity $group -Members $sam -Confirm:$false
            Write-Audit -Actor $s.username -Action 'Group member added' -Target "$group <- $sam" -Result 'Success' -Kind 'user'
            Write-PodeJsonResponse -Value @{ ok=$true }
        } catch {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ ok=$false; error=$_.Exception.Message }
        }
    }
    Add-PodeRoute -Method Delete -Path '/api/groups/:name/members/:sam' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $group = $WebEvent.Parameters['name']
        $sam   = $WebEvent.Parameters['sam']
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            Remove-ADGroupMember -Identity $group -Members $sam -Confirm:$false
            Write-Audit -Actor $s.username -Action 'Group member removed' -Target "$group -/- $sam" -Result 'Success' -Kind 'user'
            Write-PodeJsonResponse -Value @{ ok=$true }
        } catch {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ ok=$false; error=$_.Exception.Message }
        }
    }

    # ---------- SCHEDULED JOBS (Windows Task Scheduler) ----------
    Add-PodeRoute -Method Post -Path '/api/jobs/:name/toggle' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $name    = $WebEvent.Parameters['name']
        $enabled = [bool]$WebEvent.Data.enabled
        try {
            $task = Get-ScheduledTask -TaskName $name -ErrorAction Stop
            if ($enabled) { Enable-ScheduledTask -InputObject $task | Out-Null } else { Disable-ScheduledTask -InputObject $task | Out-Null }
            Write-Audit -Actor $s.username -Action $(if($enabled){'Job enabled'}else{'Job disabled'}) -Target $name -Result 'Success' -Kind 'sync'
            Write-PodeJsonResponse -Value @{ ok=$true; enabled=$enabled }
        } catch {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ ok=$false; error=$_.Exception.Message }
        }
    }
    Add-PodeRoute -Method Post -Path '/api/jobs/:name/run' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $name = $WebEvent.Parameters['name']
        try {
            Start-ScheduledTask -TaskName $name -ErrorAction Stop
            Write-Audit -Actor $s.username -Action 'Job run manually' -Target $name -Result 'Success' -Kind 'sync'
            Write-PodeJsonResponse -Value @{ ok=$true }
        } catch {
            Set-PodeResponseStatus -Code 400
            Write-PodeJsonResponse -Value @{ ok=$false; error=$_.Exception.Message }
        }
    }

    # ---------- CONFIG SAVE (from console Settings tabs) ----------
    Add-PodeRoute -Method Post -Path '/api/config' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $d = $WebEvent.Data
        $cfg = $using:Config
        if ($d.directory) {
            if ($d.directory.ldapServer) { $cfg.Directory.LdapServer = $d.directory.ldapServer }
            if ($d.directory.baseDN)     { $cfg.Directory.BaseDN     = $d.directory.baseDN }
        }
        try { Save-Config -Cfg $cfg; Write-PodeJsonResponse -Value @{ ok=$true } }
        catch { Set-PodeResponseStatus -Code 400; Write-PodeJsonResponse -Value @{ ok=$false; error=$_.Exception.Message } }
    }
    Add-PodeRoute -Method Post -Path '/api/ca/config' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $d = $WebEvent.Data
        $cfg = $using:Config
        if ($d.host)       { $cfg.CertificateAuthority.Host       = $d.host }
        if ($d.commonName) { $cfg.CertificateAuthority.CommonName = $d.commonName }
        $cfg.CertificateAuthority.ConfigString = "$($cfg.CertificateAuthority.Host)\$($cfg.CertificateAuthority.CommonName)"
        try { Save-Config -Cfg $cfg; Write-PodeJsonResponse -Value @{ ok=$true } }
        catch { Set-PodeResponseStatus -Code 400; Write-PodeJsonResponse -Value @{ ok=$false; error=$_.Exception.Message } }
    }
    Add-PodeRoute -Method Post -Path '/api/db/config' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $d = $WebEvent.Data
        $cfg = $using:Config
        if ($d.host)    { $cfg.Database.Server  = $d.host }
        if ($d.port)    { $cfg.Database.Port     = [int]$d.port }
        if ($d.name)    { $cfg.Database.Name     = $d.name }
        if ($d.auth)    { $cfg.Database.Auth     = $d.auth }
        if ($null -ne $d.encrypt) { $cfg.Database.Encrypt = [bool]$d.encrypt }
        try { Save-Config -Cfg $cfg; Write-PodeJsonResponse -Value @{ ok=$true } }
        catch { Set-PodeResponseStatus -Code 400; Write-PodeJsonResponse -Value @{ ok=$false; error=$_.Exception.Message } }
    }

    Write-Host "Directory Services Management Tool API listening on $proto`://$($Config.Api.ListenAddress):$($Config.Api.Port)"
}

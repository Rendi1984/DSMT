<#
  DSMT_Api.ps1 - REST API for the Directory Services Management Tool.
  Built on Pode (https://badgerati.github.io/Pode/).  Run:  pwsh ./DSMT_Api.ps1
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
    GET/POST /api/settings/smtp -> saved SMTP server config
    GET  /api/diag/dcs?extended=true -> + replication + dcdiag health per DC
    GET/POST/DELETE /api/diag/schedule -> scheduled diagnostics report (Windows Task Scheduler)
    POST /api/diag/report/run -> run the diagnostics report immediately
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
    # $Path defaults to the main script's $cfgPath, which is correct when
    # called from top-level script code - but every Pode route runs in its
    # own runspace, where bare script variables like $cfgPath are not
    # visible (same class of issue as $Config - see the 3.29.20 fix for
    # /api/setup/save). Routes MUST pass -Path $using:cfgPath explicitly;
    # relying on the default here silently threw "Cannot bind argument to
    # parameter 'Path' because it is null" inside every route that calls
    # Save-Config without passing it, surfacing as a generic 400.
    param($Cfg = $Config, [string] $Path = $cfgPath)
    ($Cfg | ConvertTo-Json -Depth 8) | Set-Content -Path $Path -Encoding UTF8
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
foreach ($m in 'Db','Auth','Directory','Sync','Contractor','CertAuthority','Secrets','Diagnostics','VMware') {
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
    try {
        $rows = Invoke-Sql 'SELECT TOP 1 Username,ConsoleRole,IsLocal,ExpiresAt FROM dbo.Sessions WHERE Token=@t' @{ t = $token }
    } catch {
        Write-DbLog ("Get-Session: SQL unreachable, treating as unauthenticated - " + $_.Exception.Message)
        return $null
    }
    if (-not $rows -or $rows.Count -eq 0) { return $null }
    if ([datetime]$rows[0]['ExpiresAt'] -lt (Get-Date).ToUniversalTime()) { return $null }
    $role = $rows[0]['ConsoleRole']
    return [pscustomobject]@{
        token=$token; username=$rows[0]['Username']; role=$role; isLocal=[bool]$rows[0]['IsLocal']
        scope=(Get-RoleScope $role); readOnly=(Test-RoleReadOnly $role)
    }
}

# ---------- RBAC: routes a Hafala-Tools-scoped session may reach ----------
# Everyone signed in reaches auth/health/alerts regardless of scope (the app
# shell itself needs them to function). Beyond that, a 'hafala' scope is
# restricted to exactly the API surface behind the Hafala Tools workspace
# (Azure Cloud Sync, DL Groups, Contractor Info) - enforced here, not just
# hidden in the console, since hiding a workspace is a UX convenience, not
# a security boundary.
$script:HafalaAllowedPrefixes = @('/api/auth/', '/api/health', '/api/alerts', '/api/sync', '/api/dl/', '/api/contractor/')
function Test-HafalaScopeAllowed {
    param([string] $Path)
    foreach ($p in $script:HafalaAllowedPrefixes) { if ($Path.StartsWith($p)) { return $true } }
    return $false
}

# Routes that are semantically reads/probes even though they're POST (login,
# the setup wizard's pre-auth steps, and "test the values in this form"
# probes that don't persist anything) - exempt from the read-only guard.
$script:WriteGuardExempt = @(
    '/api/auth/login', '/api/auth/logout', '/api/auth/sso',
    '/api/setup/test-server', '/api/setup/databases', '/api/setup/create-db', '/api/setup/save',
    '/api/db/test', '/api/db/list', '/api/directory/test', '/api/secrets/test', '/api/ca/ping'
)

Start-PodeServer -Threads 8 {
    # -Threads 8: without this Pode defaults to a single request-processing
    # thread, so any concurrent calls (the console fires loadHealthLive/
    # loadDbInfoLive/loadAlertsLive/loadConfigLive together right after
    # sign-in, plus anything a second browser tab or a slow button click does)
    # queue up strictly one-at-a-time. Under any real load that shows up as
    # exactly what was seen in the field: requests pending for 30+ seconds
    # and eventually timing out with 408s, even though the API itself was up.
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
        Set-PodeHeader -Name 'Access-Control-Allow-Origin'  -Value '*'
        Set-PodeHeader -Name 'Access-Control-Allow-Headers' -Value 'Content-Type, Authorization'
        Set-PodeHeader -Name 'Access-Control-Allow-Methods' -Value 'GET, POST, DELETE, OPTIONS'
        return $true
    }
    Add-PodeRoute -Method Options -Path '*' -ScriptBlock { Set-PodeResponseStatus -Code 204 }

    # ---------- RBAC middleware ----------
    # Runs before every route. Two independent checks, both enforced here
    # (not just in the console) since hiding a button is UX, not security:
    #   1. Read-only roles (Read-only, Hafala Tools Read-only) get a 403 with
    #      a specific, actionable message on any write (POST/DELETE), except
    #      the handful of pre-auth/probe routes in $WriteGuardExempt.
    #   2. Hafala-scoped roles (Hafala Tools Operator/Read-only) get a 403 on
    #      any route outside $HafalaAllowedPrefixes, GET or POST alike - a
    #      Hafala-scoped session genuinely cannot reach Settings/System Team
    #      data, not merely have it hidden in the UI.
    # Both checks are skipped for anonymous/pre-auth requests (no session)
    # since Get-Session/Write-401 in each route already gates those.
    Add-PodeMiddleware -Name 'RBAC' -ScriptBlock {
        $path = $WebEvent.Path
        $auth = $WebEvent.Request.Headers['Authorization']
        if (-not $auth -or $auth -notlike 'Bearer *') { return $true }
        $s = Get-Session $WebEvent
        if (-not $s) { return $true }
        if ($s.scope -eq 'hafala' -and -not (Test-HafalaScopeAllowed -Path $path)) {
            Set-PodeHeader -Name 'Access-Control-Allow-Origin'  -Value '*'
            Set-PodeHeader -Name 'Access-Control-Allow-Headers' -Value 'Content-Type, Authorization'
            Set-PodeHeader -Name 'Access-Control-Allow-Methods' -Value 'GET, POST, DELETE, OPTIONS'
                        Write-PodeJsonResponse -StatusCode 403 -Value @{ error = 'Your role is scoped to Hafala Tools only - this page/action is not available to you.' }
            return $false
        }
        if ($WebEvent.Method -in @('Post', 'Delete') -and $s.readOnly -and ($script:WriteGuardExempt -notcontains $path)) {
            Set-PodeHeader -Name 'Access-Control-Allow-Origin'  -Value '*'
            Set-PodeHeader -Name 'Access-Control-Allow-Headers' -Value 'Content-Type, Authorization'
            Set-PodeHeader -Name 'Access-Control-Allow-Methods' -Value 'GET, POST, DELETE, OPTIONS'
                        Write-PodeJsonResponse -StatusCode 403 -Value @{ error = 'Your role is read-only - you do not have permission to make changes. Contact an administrator to request write access.' }
            return $false
        }
        return $true
    }

    # Friendly response for anyone browsing straight to the API's own URL
    # (no /api/... path) - this API has no home page, but a raw 405 "Method
    # Not Allowed" (Pode's default here, because the OPTIONS catch-all above
    # technically "knows" every path) reads like a real error. GET /favicon.ico
    # is covered too, since browsers request it automatically for any page.
    Add-PodeRoute -Method Get -Path '/' -ScriptBlock {
        Write-PodeJsonResponse -Value @{ service = 'DSMT API'; status = 'up'; health = '/api/health'; docs = 'See README.md / Deployment_Guide.html' }
    }
    Add-PodeRoute -Method Get -Path '/favicon.ico' -ScriptBlock { Set-PodeResponseStatus -Code 204 }

    # Write-401 stamps CORS headers before setting 401 so browsers never see
    # a CORS failure masking an auth failure (the preflight succeeds, but
    # the real request returns 401 - without CORS headers that looks like CORS).
    # MUST use Set-PodeHeader (overwrite), not Add-PodeHeader (append) - the CORS
    # middleware above already stamped these on every response including this one,
    # so Add-PodeHeader here produced "Access-Control-Allow-Origin: *, *", which
    # browsers reject as an invalid header and block the request outright.
    function Write-401 {
        Set-PodeHeader -Name 'Access-Control-Allow-Origin'  -Value '*'
        Set-PodeHeader -Name 'Access-Control-Allow-Headers' -Value 'Content-Type, Authorization'
        Set-PodeHeader -Name 'Access-Control-Allow-Methods' -Value 'GET, POST, DELETE, OPTIONS'
        Write-PodeJsonResponse -StatusCode 401 -Value @{ error = 'Unauthorized' }
    }

    # Uniform JSON error responder for route catch blocks. Two jobs:
    #   1. Always answer with application/json carrying an 'error' field.
    #      (Set-PodeResponseStatus -Code 4xx/5xx made Pode render its HTML
    #      error page, which garbled/replaced the JSON body - the console
    #      then showed 'no error detail returned - check the API server
    #      logs'. Write-PodeJsonResponse -StatusCode never does that.)
    #   2. Translate AD permission failures into an actionable message: they
    #      mean the SERVICE ACCOUNT lacks delegated rights on the target OU,
    #      not that the console user did something wrong.
    function Write-ApiError {
        param($Err, [int]$Code = 400)
        $msg = $Err.Exception.Message
        if ($msg -match 'Insufficient access rights|Access is denied|unwilling to perform') {
            $Code = 403
            $msg = "Active Directory refused the operation: $msg. The DSMT service account (the identity the DSMT-Api Windows service runs as) needs delegated rights on the target OU for this action - see 'Active Directory permissions' in the Deployment Guide."
        }
        Set-PodeHeader -Name 'Access-Control-Allow-Origin'  -Value '*'
        Set-PodeHeader -Name 'Access-Control-Allow-Headers' -Value 'Content-Type, Authorization'
        Set-PodeHeader -Name 'Access-Control-Allow-Methods' -Value 'GET, POST, DELETE, OPTIONS'
        Write-PodeJsonResponse -StatusCode $Code -Value @{ ok = $false; error = $msg }
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
        # Returns everything the wizard needs to PREFILL its forms when an
        # installation already exists, so re-running setup shows the current
        # values instead of blank defaults. No secrets are ever included.
        $adminUser = $null
        try {
            $row = Invoke-Sql 'SELECT TOP 1 Username FROM dbo.LocalAccounts WHERE BuiltIn=1 ORDER BY Id'
            if ($row -and $row.Count -gt 0) { $adminUser = [string]$row[0]['Username'] }
        } catch {}
        Write-PodeJsonResponse -Value @{
            setupComplete = (Test-SetupComplete -Cfg $cfg)
            database  = @{ engine = $cfg.Database.Engine; server = $cfg.Database.Server; port = $cfg.Database.Port; name = $cfg.Database.Name; auth = $cfg.Database.Auth; user = $cfg.Database.User; encrypt = [bool]$cfg.Database.Encrypt }
            directory = @{ ldapServer = $cfg.Directory.LdapServer; baseDN = $cfg.Directory.BaseDN; domains = @($cfg.Directory.Domains) }
            adminExists = (-not [string]::IsNullOrWhiteSpace($adminUser))
            adminUser   = $adminUser
        }
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
        # This route runs in its own Pode runspace - $Config is NOT visible
        # here as a bare variable (unlike the main script scope). Every other
        # route captures it via $using:Config first; this one used to write
        # straight to $Config.Database.* without that capture, which silently
        # operated on $null and crashed before ever reaching Save-Config -
        # so /api/setup/save never actually persisted anything or returned a
        # usable response, no matter how many times the wizard was retried.
        $cfg = $using:Config
        if (Test-SetupComplete -Cfg $cfg) { Write-PodeJsonResponse -StatusCode 409 -Value @{ error = 'Setup already complete.' }; return }
        $d = $WebEvent.Data
        $cfg.Database.Engine                 = $d.Engine
        $cfg.Database.Server                 = $d.Server
        $cfg.Database.Port                   = [int]$d.Port
        $cfg.Database.Name                   = $d.Name
        $cfg.Database.Auth                   = $d.Auth
        $cfg.Database.User                   = $d.User
        $cfg.Database.Password               = $d.Password
        $cfg.Database.Encrypt                = [bool]$d.Encrypt
        $cfg.Database.TrustServerCertificate = [bool]$d.TrustServerCertificate
        # Optional: the browser wizard also sends the directory settings.
        if ($d.Directory -and $cfg.Directory) {
            if ($d.Directory.LdapServer) { $cfg.Directory.LdapServer = $d.Directory.LdapServer }
            if ($d.Directory.BaseDN)     { $cfg.Directory.BaseDN     = $d.Directory.BaseDN }
        }
        Save-Config -Cfg $cfg -Path $using:cfgPath
        try { Initialize-Db -DbConfig $cfg.Database -ProbeOnly; Initialize-Db -DbConfig $cfg.Database }
        catch { Write-PodeJsonResponse -Value @{ ok = $false; error = $_.Exception.Message }; return }
        # Optional: seed the break-glass local administrator collected by the wizard.
        $adminPreserved = $false
        if ($d.LocalAdmin -and $d.LocalAdmin.User -and $d.LocalAdmin.Password) {
            try {
                # NEVER overwrite an existing account's password from the
                # (unauthenticated) setup flow - re-running setup against an
                # existing database must not lock out accounts that already
                # work. Password resets go through Install.ps1 -SeedLocalAdmin.
                $exists = Invoke-Sql 'SELECT COUNT(*) FROM dbo.LocalAccounts WHERE Username=@u' @{ u=[string]$d.LocalAdmin.User } -Scalar
                if ([int]$exists -gt 0) {
                    $adminPreserved = $true
                } else {
                    $h = New-PasswordHash -Password ([string]$d.LocalAdmin.Password)
                    Invoke-Sql @'
INSERT INTO dbo.LocalAccounts(Username,ConsoleRole,PwHash,PwSalt,Iterations,Enabled,BuiltIn)
VALUES(@u,'Local Administrator',@h,@sa,@i,1,1);
'@ @{ u=[string]$d.LocalAdmin.User; h=$h.Hash; sa=$h.Salt; i=$h.Iterations } -NonQuery | Out-Null
                }
            } catch { Write-PodeJsonResponse -Value @{ ok = $false; error = ('Database ready but seeding the local administrator failed: ' + $_.Exception.Message) }; return }
        }
        Write-PodeJsonResponse -Value @{ ok = $true; adminPreserved = $adminPreserved }
    }

    # ---------- AUTH ----------
    Add-PodeRoute -Method Post -Path '/api/auth/login' -ScriptBlock {
        $cfg = $using:Config
        $b = $WebEvent.Data
        $ip = $WebEvent.Request.RemoteEndPoint.Address.ToString()
        # Wrap the whole sign-in attempt: an unreachable LDAP server or a bad
        # bind throws inside Invoke-SignIn/Test-LdapCredential, and an
        # unhandled exception here returns a raw empty 500 to the browser
        # (surfaces as "Unexpected end of JSON input" client-side) instead of
        # a readable error - always give the console a JSON body to show.
        try {
            $r = Invoke-SignIn -Config $cfg -Domain $b.domain -Username $b.username -Password $b.password -MfaCode $b.mfaCode
        } catch {
            Write-Audit -Actor $b.username -Action 'Console sign-in' -Target 'console' -Result 'Error' -Kind 'auth' -Detail $_.Exception.Message -SourceIp $ip
            Write-PodeJsonResponse -StatusCode 502 -Value @{ error = 'Directory unreachable: ' + $_.Exception.Message }; return
        }
        if (-not $r.Ok) {
            # MfaRequired (password already checked out) is a distinct outcome from a
            # denied sign-in - the console shows an MFA-code prompt instead of an
            # error, but it must NOT create a session or count as success either way.
            if ($r.MfaRequired) {
                Write-Audit -Actor $b.username -Action 'Console sign-in (MFA challenge)' -Target 'console' -Result 'Denied' -Kind 'auth' -Detail $r.Reason -SourceIp $ip
                Write-PodeJsonResponse -StatusCode 401 -Value @{ error = $r.Reason; mfaRequired = $true }; return
            }
            Write-Audit -Actor $b.username -Action 'Console sign-in' -Target 'console' -Result 'Denied' -Kind 'auth' -Detail $r.Reason -SourceIp $ip
            Write-PodeJsonResponse -StatusCode 401 -Value @{ error = $r.Reason }; return
        }
        $token = New-Token
        $ttl = [int]$cfg.Api.TokenTtlHours
        try {
            Invoke-Sql 'INSERT INTO dbo.Sessions(Token,Username,ConsoleRole,IsLocal,ExpiresAt) VALUES(@t,@u,@r,@l,DATEADD(hour,@h,SYSUTCDATETIME()))' `
                @{ t=$token; u=$r.Username; r=$r.Role; l=([int][bool]$r.IsLocal); h=$ttl } -NonQuery | Out-Null
        } catch {
            Write-PodeJsonResponse -StatusCode 502 -Value @{ error = 'Database unreachable while creating the session: ' + $_.Exception.Message }; return
        }
        Write-Audit -Actor $r.Username -Action 'Console sign-in' -Target 'console' -Result 'Success' -Kind 'auth' -SourceIp $ip
        # Flag well-known default credentials so the console can nag until they are changed.
        $defPw = ([bool]$r.IsLocal -and ($b.password -eq 'admin' -or $b.password -eq $b.username))
        Write-PodeJsonResponse -Value @{ token=$token; displayName=$r.Username; role=$r.Role; isLocal=$r.IsLocal; defaultPassword=$defPw; scope=(Get-RoleScope $r.Role); readOnly=(Test-RoleReadOnly $r.Role) }
    }

    Add-PodeRoute -Method Post -Path '/api/auth/logout' -ScriptBlock {
        $s = Get-Session $WebEvent
        if ($s) { Invoke-Sql 'DELETE FROM dbo.Sessions WHERE Token=@t' @{ t=$s.token } -NonQuery | Out-Null }
        Write-PodeJsonResponse -Value @{ ok=$true }
    }

    # ---------- MFA (TOTP) enrollment - local accounts only ----------
    # Two-step enrollment: /setup generates and stores a secret (not yet
    # active), the console shows it as a QR/manual-entry code, then /enable
    # proves the user actually captured it correctly before it starts being
    # required at sign-in - avoids locking someone out with a secret they
    # never actually saved.
    Add-PodeRoute -Method Post -Path '/api/auth/mfa/setup' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        if (-not $s.isLocal) { Write-PodeJsonResponse -StatusCode 400 -Value @{ ok=$false; error='MFA is only available for local accounts.' }; return }
        $secret = New-TotpSecret
        Invoke-Sql 'UPDATE dbo.LocalAccounts SET MfaSecret=@sec, MfaEnabled=0 WHERE Username=@u' @{ sec=$secret; u=$s.username } -NonQuery | Out-Null
        Write-Audit -Actor $s.username -Action 'MFA enrollment started' -Target $s.username -Result 'Success' -Kind 'auth'
        Write-PodeJsonResponse -Value @{ ok=$true; secret=$secret; otpauth=(Get-TotpUri -Base32Secret $secret -Username $s.username) }
    }
    Add-PodeRoute -Method Post -Path '/api/auth/mfa/enable' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $row = Invoke-Sql 'SELECT TOP 1 MfaSecret FROM dbo.LocalAccounts WHERE Username=@u' @{ u=$s.username }
        $secret = if ($row -and $row.Count -gt 0) { [string]$row[0]['MfaSecret'] } else { $null }
        if ([string]::IsNullOrWhiteSpace($secret)) { Write-PodeJsonResponse -StatusCode 400 -Value @{ ok=$false; error='Call /api/auth/mfa/setup first.' }; return }
        if (-not (Test-TotpCode -Base32Secret $secret -Code $WebEvent.Data.code)) {
            Write-Audit -Actor $s.username -Action 'MFA enable' -Target $s.username -Result 'Denied' -Kind 'auth' -Detail 'Invalid code'
            Write-PodeJsonResponse -StatusCode 400 -Value @{ ok=$false; error='Invalid code.' }; return
        }
        Invoke-Sql 'UPDATE dbo.LocalAccounts SET MfaEnabled=1 WHERE Username=@u' @{ u=$s.username } -NonQuery | Out-Null
        Write-Audit -Actor $s.username -Action 'MFA enabled' -Target $s.username -Result 'Success' -Kind 'auth'
        Write-PodeJsonResponse -Value @{ ok=$true }
    }
    Add-PodeRoute -Method Post -Path '/api/auth/mfa/disable' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        Invoke-Sql 'UPDATE dbo.LocalAccounts SET MfaEnabled=0, MfaSecret=NULL WHERE Username=@u' @{ u=$s.username } -NonQuery | Out-Null
        Write-Audit -Actor $s.username -Action 'MFA disabled' -Target $s.username -Result 'Success' -Kind 'auth'
        Write-PodeJsonResponse -Value @{ ok=$true }
    }

    # ---------- SSO (Windows Integrated Auth via IIS) ----------
    # DSMT itself never negotiates Kerberos/NTLM - that handshake happens in
    # IIS in front of the console (Windows Authentication enabled on the site,
    # see Deployment_Guide.html). IIS forwards the already-authenticated
    # Windows identity in a header via the reverse-proxy rule; this route only
    # trusts that header when SsoEnabled is explicitly turned on, and maps the
    # user through the exact same group -> role resolution as a normal domain
    # sign-in (no separate access grant for SSO).
    Add-PodeRoute -Method Post -Path '/api/auth/sso' -ScriptBlock {
        $cfg = $using:Config
        $ip = $WebEvent.Request.RemoteEndPoint.Address.ToString()
        if (-not [bool]$cfg.Directory.SsoEnabled) {
            Write-PodeJsonResponse -StatusCode 400 -Value @{ ok=$false; error='SSO is not enabled.' }; return
        }
        $winUser = $WebEvent.Request.Headers['X-Windows-User']
        if ([string]::IsNullOrWhiteSpace($winUser)) {
            Write-PodeJsonResponse -StatusCode 401 -Value @{ ok=$false; error='No Windows identity was forwarded by IIS - check Windows Authentication is enabled on the site.' }; return
        }
        $sam = ($winUser -replace '^.*\\', '')
        $groups = Get-UserGroups -Server $cfg.Directory.LdapServer -BaseDN $cfg.Directory.BaseDN -SamAccountName $sam
        $role = Resolve-ConsoleRole -Groups $groups
        if (-not $role) {
            Write-Audit -Actor $sam -Action 'SSO sign-in' -Target 'console' -Result 'Denied' -Kind 'auth' -Detail 'Not a member of any group mapped for console access' -SourceIp $ip
            Write-PodeJsonResponse -StatusCode 401 -Value @{ ok=$false; error='Not a member of any group mapped for console access' }; return
        }
        $token = New-Token
        $ttl = [int]$cfg.Api.TokenTtlHours
        Invoke-Sql 'INSERT INTO dbo.Sessions(Token,Username,ConsoleRole,IsLocal,ExpiresAt) VALUES(@t,@u,@r,0,DATEADD(hour,@h,SYSUTCDATETIME()))' `
            @{ t=$token; u=$sam; r=$role; h=$ttl } -NonQuery | Out-Null
        Write-Audit -Actor $sam -Action 'SSO sign-in' -Target 'console' -Result 'Success' -Kind 'auth' -SourceIp $ip
        Write-PodeJsonResponse -Value @{ ok=$true; token=$token; displayName=$sam; role=$role; isLocal=$false; scope=(Get-RoleScope $role); readOnly=(Test-RoleReadOnly $role) }
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
        # 'directory' comes from config.json (the same store POST /api/config
        # writes LdapServer/BaseDN into) - previously this route only returned
        # the SQL-backed Get-Config hash, so the console had nothing to load
        # the saved directory settings FROM, and every sign-in re-populated
        # Settings -> General from its hardcoded defaults instead of what was
        # actually saved. Both stores are returned for backward compatibility.
        $cfg = $using:Config
        Write-PodeJsonResponse -Value @{
            directory = @{ ldapServer = $cfg.Directory.LdapServer; baseDN = $cfg.Directory.BaseDN; domains = @($cfg.Directory.Domains); ssoEnabled = [bool]$cfg.Directory.SsoEnabled }
            certificateAuthority = @{ host = $cfg.CertificateAuthority.Host; commonName = $cfg.CertificateAuthority.CommonName }
            sql       = (Get-Config)
        }
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
        catch { Write-ApiError $_ }
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
        catch { Write-PodeJsonResponse -StatusCode 400 -Value @{ ok = $false; connected = $false; error = $_.Exception.Message } }
    }
    Add-PodeRoute -Method Post -Path '/api/db/migrate' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $schema = Join-Path $using:here 'sql/schema.sql'
        try {
            $r = Invoke-DbMigrate -SchemaPath $schema
            Write-Audit -Actor $s.username -Action 'Schema migrate' -Target 'database' -Result $(if($r.ok){'Success'}else{'Error'}) -Kind 'db'
            Write-PodeJsonResponse -Value $r
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/db/backup' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        try {
            $r = Invoke-DbBackup
            Write-Audit -Actor $s.username -Action 'Database backup' -Target $r.file -Result 'Success' -Kind 'db'
            Write-PodeJsonResponse -Value $r
        } catch { Write-ApiError $_ }
    }

    # ---------- SYNC ----------
    Add-PodeRoute -Method Post -Path '/api/sync' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $cfg = $using:Config
        try {
            $r = Start-DeltaSync -AdConnectServer $cfg.Sync.ADConnectServer
            Write-Audit -Actor $s.username -Action 'Delta sync cycle' -Target $cfg.Sync.ADConnectServer -Result $(if($r.ok){'Success'}else{'Error'}) -Kind 'sync'
            Write-PodeJsonResponse -Value @{ ok=$r.ok; log=$r.log }
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Get -Path '/api/sync/status' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $cfg = $using:Config
        try { Write-PodeJsonResponse -Value (Get-SyncStatus -AdConnectServer $cfg.Sync.ADConnectServer) }
        catch { Write-ApiError $_ }
    }

    # ---------- DL GROUPS ----------
    Add-PodeRoute -Method Get -Path '/api/dl/:group' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        try { Write-PodeJsonResponse -Value @{ members = @(Get-GroupMembers -GroupName $WebEvent.Parameters['group']) } }
        catch { Write-ApiError $_ }
    }

    # ---------- GROUPS (System Team -> Groups) ----------
    # Real AD groups, not a fixed demo list - a hardcoded set of group names
    # has no relationship to what actually exists in any given domain, and
    # selecting one always 400'd unless its name happened to match by luck.
    Add-PodeRoute -Method Get -Path '/api/groups' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $q = $WebEvent.Query['q']
        try { Write-PodeJsonResponse -Value @{ groups = @(Get-AllGroups -Query $q) } }
        catch { Write-ApiError $_ }
    }

    # ---------- PASSWORD EXPIRY REPORT ----------
    Add-PodeRoute -Method Get -Path '/api/passwords/expiring' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $days = if ($WebEvent.Query['days']) { [int]$WebEvent.Query['days'] } else { 30 }
        try { Write-PodeJsonResponse -Value @{ users = @(Get-ExpiringPasswords -Days $days) } }
        catch { Write-ApiError $_ }
    }

    # ---------- USERS ----------
    Add-PodeRoute -Method Get -Path '/api/users' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $q = $WebEvent.Query['q']
        try { Write-PodeJsonResponse -Value @{ users = @(Get-DirectoryUsers -Query $q) } }
        catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/users/:sam/reset' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $sam = $WebEvent.Parameters['sam']; $pw = $WebEvent.Data.password
        try {
            Reset-UserPassword -Sam $sam -NewPassword $pw -MustChange | Out-Null
            Write-Audit -Actor $s.username -Action 'Password reset' -Target $sam -Result 'Success' -Kind 'pw'
            Write-PodeJsonResponse -Value @{ ok=$true }
        } catch {
            Write-Audit -Actor $s.username -Action 'Password reset' -Target $sam -Result 'Error' -Kind 'pw' -Detail $_.Exception.Message
            Write-ApiError $_
        }
    }
    Add-PodeRoute -Method Post -Path '/api/users/:sam/enable' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $sam = $WebEvent.Parameters['sam']; $en = [bool]$WebEvent.Data.enabled
        try {
            Set-UserEnabled -Sam $sam -Enabled $en | Out-Null
            Write-Audit -Actor $s.username -Action $(if($en){'User enabled'}else{'User disabled'}) -Target $sam -Result 'Success' -Kind 'user'
            Write-PodeJsonResponse -Value @{ ok=$true }
        } catch {
            Write-Audit -Actor $s.username -Action $(if($en){'User enable failed'}else{'User disable failed'}) -Target $sam -Result 'Error' -Kind 'user' -Detail $_.Exception.Message
            Write-ApiError $_
        }
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
        # Setup task: the console has no LDAP group mapped to the admin role yet.
        try {
            $adminMaps = @(Get-RoleMappings | Where-Object { $_['ConsoleRole'] -eq 'System Administrator' -and -not [string]::IsNullOrWhiteSpace([string]$_['LdapGroup']) })
            if ($adminMaps.Count -eq 0) {
                $alerts += @{ type='Setup'; title='Connect an LDAP admin group'; detail='Map a security group to the System Administrator role (Access Control)'; badge='action required' }
            }
        } catch {}
        try { if (-not [string]::IsNullOrWhiteSpace($using:cs)) { foreach ($c in (Get-ExpiringCertificates -ConfigString $using:cs -Days 30)) { $alerts += @{ type='Certificate'; title=$c.subject; detail=$c.template; badge="exp $($c.expires)" } } } } catch {}
        try { foreach ($p in (Get-ExpiringPasswords -Days 14)) { $alerts += @{ type='Password'; title=$p.sam; detail='AD password expiring'; badge="in $($p.daysLeft)d" } } } catch {}
        Write-PodeJsonResponse -Value @{ alerts=$alerts }
    }

    # ---------- CONTRACTOR ----------
    Add-PodeRoute -Method Get -Path '/api/contractor/:user' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $cfg = $using:Config
        try { Write-PodeJsonResponse -Value (Get-ContractorInfo -Username $WebEvent.Parameters['user'] -Config $cfg) }
        catch { Write-ApiError $_ }
    }

    # ---------- AUDIT ----------
    Add-PodeRoute -Method Get -Path '/api/audit' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        try {
            $rows = @(Get-AuditLog -Kind $WebEvent.Query['kind'] | ForEach-Object {
                @{ time = "$($_['Time'])"; actor = [string]$_['Actor']; action = [string]$_['Action']; target = [string]$_['Target']; result = [string]$_['Result']; kind = [string]$_['Kind'] }
            })
            Write-PodeJsonResponse -Value @{ events = $rows }
        } catch { Write-ApiError $_ }
    }

    # ---------- CERTIFICATE AUTHORITY ----------
    Add-PodeRoute -Method Get -Path '/api/ca/certs' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        # An unconfigured CA (empty ConfigString) used to crash parameter
        # binding here -> raw 500 on every page load. Report it as a state
        # the console can render instead.
        if ([string]::IsNullOrWhiteSpace($using:cs)) {
            Write-PodeJsonResponse -Value @{ certs = @(); configured = $false; hint = 'No Certificate Authority is configured. Set the CA host and common name in Settings, then restart the DSMT-Api service.' }; return
        }
        try { Write-PodeJsonResponse -Value @{ certs = @(Get-IssuedCertificates -ConfigString $using:cs); configured = $true } }
        catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Get -Path '/api/ca/pending' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        if ([string]::IsNullOrWhiteSpace($using:cs)) {
            Write-PodeJsonResponse -Value @{ pending = @(); configured = $false; hint = 'No Certificate Authority is configured. Set the CA host and common name in Settings, then restart the DSMT-Api service.' }; return
        }
        try { Write-PodeJsonResponse -Value @{ pending = @(Get-PendingRequests -ConfigString $using:cs); configured = $true } }
        catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/ca/ping' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $target = if ($WebEvent.Data.configString) { $WebEvent.Data.configString } else { $using:cs }
        if ([string]::IsNullOrWhiteSpace($target)) {
            Write-PodeJsonResponse -Value @{ ok = $false; error = 'No Certificate Authority is configured.' }; return
        }
        try { Write-PodeJsonResponse -Value (Test-Ca -ConfigString $target) }
        catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/ca/publish-crl' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        if ([string]::IsNullOrWhiteSpace($using:cs)) { Write-PodeJsonResponse -StatusCode 400 -Value @{ ok = $false; error = 'No Certificate Authority is configured.' }; return }
        try {
            $r = Publish-Crl -ConfigString $using:cs
            Write-Audit -Actor $s.username -Action 'Publish CRL' -Target $using:cs -Result $(if($r.ok){'Success'}else{'Error'}) -Kind 'cert'
            Write-PodeJsonResponse -Value $r
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/ca/revoke' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $reason = if ($WebEvent.Data.reason) { [int]$WebEvent.Data.reason } else { 4 }
        if ([string]::IsNullOrWhiteSpace($using:cs)) { Write-PodeJsonResponse -StatusCode 400 -Value @{ ok = $false; error = 'No Certificate Authority is configured.' }; return }
        try {
            $r = Revoke-Certificate -ConfigString $using:cs -Serial $WebEvent.Data.serial -Reason $reason
            Write-Audit -Actor $s.username -Action 'Revoke certificate' -Target $WebEvent.Data.serial -Result $(if($r.ok){'Success'}else{'Error'}) -Kind 'cert'
            Write-PodeJsonResponse -Value $r
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/ca/approve' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        if ([string]::IsNullOrWhiteSpace($using:cs)) { Write-PodeJsonResponse -StatusCode 400 -Value @{ ok = $false; error = 'No Certificate Authority is configured.' }; return }
        try {
            $r = Approve-Request -ConfigString $using:cs -RequestId ([int]$WebEvent.Data.id)
            Write-Audit -Actor $s.username -Action 'Approve certificate request' -Target "$($WebEvent.Data.id)" -Result $(if($r.ok){'Success'}else{'Error'}) -Kind 'cert'
            Write-PodeJsonResponse -Value $r
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/ca/deny' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        if ([string]::IsNullOrWhiteSpace($using:cs)) { Write-PodeJsonResponse -StatusCode 400 -Value @{ ok = $false; error = 'No Certificate Authority is configured.' }; return }
        try {
            $r = Deny-Request -ConfigString $using:cs -RequestId ([int]$WebEvent.Data.id)
            Write-Audit -Actor $s.username -Action 'Deny certificate request' -Target "$($WebEvent.Data.id)" -Result $(if($r.ok){'Success'}else{'Error'}) -Kind 'cert'
            Write-PodeJsonResponse -Value $r
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/ca/backup' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        if ([string]::IsNullOrWhiteSpace($using:cs)) { Write-PodeJsonResponse -StatusCode 400 -Value @{ ok = $false; error = 'No Certificate Authority is configured.' }; return }
        try {
            $r = Backup-CaDatabase -ConfigString $using:cs
            Write-Audit -Actor $s.username -Action 'CA database backup' -Target $r.path -Result $(if($r.ok){'Success'}else{'Error'}) -Kind 'cert'
            Write-PodeJsonResponse -Value $r
        } catch { Write-ApiError $_ }
    }

    # ---------- SECRETS (DPAPI-encrypted in SQL) ----------
    Add-PodeRoute -Method Get -Path '/api/secrets' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        try {
            $rows = @(Get-SecretList | ForEach-Object {
                @{ id = [string]$_['Name']; label = [string]$_['Name']; ref = [string]$_['Account']; rotated = if ($_['UpdatedAt']) { "$($_['UpdatedAt'])" } else { 'never' } }
            })
            Write-PodeJsonResponse -Value @{ secrets = $rows }   # names/metadata only, never values
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/secrets' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        try {
            Set-Secret -Name $WebEvent.Data.name -Value $WebEvent.Data.value -Account $WebEvent.Data.account -By $s.username
            Write-Audit -Actor $s.username -Action 'Secret saved' -Target $WebEvent.Data.name -Result 'Success' -Kind 'secret'
            Write-PodeJsonResponse -Value @{ ok = $true }
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/secrets/test' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $cfg = $using:Config
        try {
            $ok = Test-ServiceAccount -Server $cfg.Directory.LdapServer -Account $WebEvent.Data.account -Password $WebEvent.Data.value -UseSsl:([bool]$cfg.Directory.UseSsl)
            Write-PodeJsonResponse -Value @{ ok = $ok }
        } catch { Write-ApiError $_ }
    }

    # ---------- ACCESS CONTROL (role mappings, local accounts, sign-in policy) ----------
    Add-PodeRoute -Method Get -Path '/api/access/mappings' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        try {
            # Skip any row with a blank LdapGroup - the write route has always
            # rejected an empty group with a 400, so a row like this can only
            # be pre-existing stale data (e.g. from testing before that
            # validation existed), never something a real save just produced.
            # Rendering it looked exactly like "the mapping I just added
            # disappeared" - filtering it out here removes the confusion even
            # for a database that already has the bad row sitting in it.
            $rows = @(Get-RoleMappings | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_['LdapGroup']) } | ForEach-Object { @{ id = [int]$_['Id']; group = [string]$_['LdapGroup']; role = [string]$_['ConsoleRole'] } })
            Write-PodeJsonResponse -Value @{ mappings = $rows }
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/access/mappings' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $g = [string]$WebEvent.Data.group; $r = [string]$WebEvent.Data.role
        if ([string]::IsNullOrWhiteSpace($g) -or [string]::IsNullOrWhiteSpace($r)) {
            Write-PodeJsonResponse -StatusCode 400 -Value @{ ok=$false; error='group and role are required' }; return
        }
        try {
            Invoke-Sql @'
MERGE dbo.RoleMappings AS t USING (SELECT @g AS LdapGroup) AS src ON t.LdapGroup=src.LdapGroup
WHEN MATCHED THEN UPDATE SET ConsoleRole=@r
WHEN NOT MATCHED THEN INSERT(LdapGroup,ConsoleRole) VALUES(@g,@r);
'@ @{ g=$g; r=$r } -NonQuery | Out-Null
            $id = Invoke-Sql 'SELECT Id FROM dbo.RoleMappings WHERE LdapGroup=@g' @{ g=$g } -Scalar
            Write-Audit -Actor $s.username -Action 'Role mapping saved' -Target "$g -> $r" -Result 'Success' -Kind 'access'
            Write-PodeJsonResponse -Value @{ ok=$true; id=[int]$id }
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Delete -Path '/api/access/mappings/:id' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        try {
            Invoke-Sql 'DELETE FROM dbo.RoleMappings WHERE Id=@i' @{ i=[int]$WebEvent.Parameters['id'] } -NonQuery | Out-Null
            Write-Audit -Actor $s.username -Action 'Role mapping removed' -Target $WebEvent.Parameters['id'] -Result 'Success' -Kind 'access'
            Write-PodeJsonResponse -Value @{ ok=$true }
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Get -Path '/api/access/local' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        try {
            $rows = @(Invoke-Sql 'SELECT Id,Username,ConsoleRole,Enabled,BuiltIn FROM dbo.LocalAccounts ORDER BY Id' | ForEach-Object {
                @{ id = [int]$_['Id']; user = [string]$_['Username']; role = [string]$_['ConsoleRole']; enabled = [bool]$_['Enabled']; builtin = [bool]$_['BuiltIn'] }
            })
            Write-PodeJsonResponse -Value @{ accounts = $rows }
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/access/local' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $u = [string]$WebEvent.Data.user; $role = [string]$WebEvent.Data.role; $pw = [string]$WebEvent.Data.password
        if ([string]::IsNullOrWhiteSpace($u) -or [string]::IsNullOrWhiteSpace($pw)) {
            Write-PodeJsonResponse -StatusCode 400 -Value @{ ok=$false; error='user and password are required' }; return
        }
        if ([string]::IsNullOrWhiteSpace($role)) { $role = 'Operator' }
        try {
            $h = New-PasswordHash -Password $pw
            Invoke-Sql @'
MERGE dbo.LocalAccounts AS t USING (SELECT @u AS Username) AS src ON t.Username=src.Username
WHEN MATCHED THEN UPDATE SET ConsoleRole=@r, PwHash=@h, PwSalt=@sa, Iterations=@i, Enabled=1
WHEN NOT MATCHED THEN INSERT(Username,ConsoleRole,PwHash,PwSalt,Iterations,Enabled,BuiltIn) VALUES(@u,@r,@h,@sa,@i,1,0);
'@ @{ u=$u; r=$role; h=$h.Hash; sa=$h.Salt; i=$h.Iterations } -NonQuery | Out-Null
            $id = Invoke-Sql 'SELECT Id FROM dbo.LocalAccounts WHERE Username=@u' @{ u=$u } -Scalar
            Write-Audit -Actor $s.username -Action 'Local account saved' -Target $u -Result 'Success' -Kind 'access'
            Write-PodeJsonResponse -Value @{ ok=$true; id=[int]$id }
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/access/local/:id/toggle' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        try {
            $en = [int][bool]$WebEvent.Data.enabled
            Invoke-Sql 'UPDATE dbo.LocalAccounts SET Enabled=@e WHERE Id=@i' @{ e=$en; i=[int]$WebEvent.Parameters['id'] } -NonQuery | Out-Null
            Write-Audit -Actor $s.username -Action $(if($en -eq 1){'Local account enabled'}else{'Local account disabled'}) -Target $WebEvent.Parameters['id'] -Result 'Success' -Kind 'access'
            Write-PodeJsonResponse -Value @{ ok=$true }
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Delete -Path '/api/access/local/:id' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        try {
            $builtin = Invoke-Sql 'SELECT BuiltIn FROM dbo.LocalAccounts WHERE Id=@i' @{ i=[int]$WebEvent.Parameters['id'] } -Scalar
            if ([bool]$builtin) { Write-PodeJsonResponse -StatusCode 400 -Value @{ ok=$false; error='The built-in administrator cannot be removed.' }; return }
            Invoke-Sql 'DELETE FROM dbo.LocalAccounts WHERE Id=@i' @{ i=[int]$WebEvent.Parameters['id'] } -NonQuery | Out-Null
            Write-Audit -Actor $s.username -Action 'Local account removed' -Target $WebEvent.Parameters['id'] -Result 'Success' -Kind 'access'
            Write-PodeJsonResponse -Value @{ ok=$true }
        } catch { Write-ApiError $_ }
    }

    # ---------- SETTINGS BACKUP / RESTORE ----------
    Add-PodeRoute -Method Get -Path '/api/settings/export' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        # Config + role mappings (NOT secrets - those never leave the server in clear).
        try { Write-PodeJsonResponse -Value @{ exportedAt = (Get-Date).ToString('o'); config = (Get-Config); roleMappings = @(Get-RoleMappings) } }
        catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/settings/import' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $cfg = $WebEvent.Data.config
        try {
            if ($cfg) { foreach ($k in $cfg.PSObject.Properties.Name) { Set-Config -Key $k -Value ([string]$cfg.$k) -By $s.username } }
            Write-Audit -Actor $s.username -Action 'Settings imported' -Target 'config' -Result 'Success' -Kind 'config'
            Write-PodeJsonResponse -Value @{ ok = $true }
        } catch { Write-ApiError $_ }
    }

    # ---------- DIAGNOSTICS ----------
    Add-PodeRoute -Method Get -Path '/api/diag/dcs' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $m = if ($WebEvent.Query['method']) { $WebEvent.Query['method'] } else { 'auto' }
        try {
        $hosts = Get-DomainControllers -Method $m
        $controllers = @(Test-DcServices -Hosts $hosts)
        # Extended mode adds replication + dcdiag health per host, on top of
        # the plain service probe - opt-in via query param since both are
        # slower (dcdiag can take 10-30s per host) and not every caller wants
        # to pay that cost (e.g. a quick dashboard refresh).
        if ($WebEvent.Query['extended'] -eq 'true' -and $hosts.Count -gt 0) {
            $repl = @{}
            try { foreach ($r in (Test-DcReplication -Hosts $hosts)) { $repl[$r.host] = $r } } catch {}
            foreach ($c in $controllers) {
                $c | Add-Member -NotePropertyName replication -NotePropertyValue $repl[$c.host] -Force
                $c | Add-Member -NotePropertyName health -NotePropertyValue (Test-DcHealth -DcHost $c.host) -Force
            }
        }
        Write-PodeJsonResponse -Value @{ controllers = $controllers }
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/diag/exchange' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        # Accepts a single 'host' or a 'hosts' array - checks each member server directly.
        $hosts = if ($WebEvent.Data.hosts) { @($WebEvent.Data.hosts) } else { @($WebEvent.Data.host) }
        try {
            $results = @()
            foreach ($h in ($hosts | Where-Object { $_ })) { $results += (Test-ExchangeServer -ExchangeHost $h) }
            Write-PodeJsonResponse -Value @{ results = $results }
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/diag/message' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $cfg = $using:Config
        $sim = [bool]$WebEvent.Data.simulate
        # Falls back to the saved SMTP config (Settings -> Notifications) for
        # any field the caller didn't supply - the console's "send test
        # email" button only needs a To address once the server is set up
        # once, instead of re-typing host/port/credentials every time.
        $smtpServer = if ($WebEvent.Data.smtp) { $WebEvent.Data.smtp } else { $cfg.Smtp.Server }
        $port       = if ($WebEvent.Data.port) { [int]$WebEvent.Data.port } else { [int]$cfg.Smtp.Port }
        $from       = if ($WebEvent.Data.from) { $WebEvent.Data.from } else { $cfg.Smtp.From }
        $username   = if ($null -ne $WebEvent.Data.username -and $WebEvent.Data.username -ne '') { $WebEvent.Data.username } else { $cfg.Smtp.Username }
        $password   = if ($null -ne $WebEvent.Data.password -and $WebEvent.Data.password -ne '') { $WebEvent.Data.password } else { $cfg.Smtp.Password }
        $useTls     = if ($null -ne $WebEvent.Data.useTls) { [bool]$WebEvent.Data.useTls } else { [bool]$cfg.Smtp.UseTls }
        if ([string]::IsNullOrWhiteSpace($smtpServer)) {
            Write-PodeJsonResponse -StatusCode 400 -Value @{ ok=$false; error='No SMTP server configured - set one in Settings > Notifications first.' }; return
        }
        $r = Send-TestMessage -SmtpServer $smtpServer -To $WebEvent.Data.to -From $from -Subject $WebEvent.Data.subject -Body $WebEvent.Data.body -Port $port -Simulate:$sim -Username $username -Password $password -UseTls:$useTls
        Write-Audit -Actor $s.username -Action $(if($sim){'Test message simulated'}else{'Test message sent'}) -Target $WebEvent.Data.to -Result $(if($r.ok){'Success'}else{'Error'}) -Kind 'diag'
        Write-PodeJsonResponse -Value $r
    }

    # ---------- SMTP CONFIG (Settings -> Notifications) ----------
    Add-PodeRoute -Method Get -Path '/api/settings/smtp' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $cfg = $using:Config
        # Password is never sent back to the browser - the console shows a
        # "saved" placeholder instead, same pattern as every other secret
        # field in this app.
        Write-PodeJsonResponse -Value @{ server=$cfg.Smtp.Server; port=$cfg.Smtp.Port; from=$cfg.Smtp.From; username=$cfg.Smtp.Username; hasPassword=(-not [string]::IsNullOrWhiteSpace($cfg.Smtp.Password)); useTls=[bool]$cfg.Smtp.UseTls }
    }
    Add-PodeRoute -Method Post -Path '/api/settings/smtp' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $cfg = $using:Config
        $d = $WebEvent.Data
        if (-not $cfg.Smtp) { $cfg | Add-Member -NotePropertyName Smtp -NotePropertyValue ([pscustomobject]@{}) -Force }
        if ($null -ne $d.server)   { $cfg.Smtp.Server   = $d.server }
        if ($null -ne $d.port)     { $cfg.Smtp.Port     = [int]$d.port }
        if ($null -ne $d.from)     { $cfg.Smtp.From     = $d.from }
        if ($null -ne $d.username) { $cfg.Smtp.Username = $d.username }
        if ($null -ne $d.password -and $d.password -ne '') { $cfg.Smtp.Password = $d.password }
        if ($null -ne $d.useTls)   { $cfg.Smtp.UseTls   = [bool]$d.useTls }
        try { Save-Config -Cfg $cfg -Path $using:cfgPath; Write-Audit -Actor $s.username -Action 'SMTP settings saved' -Target $cfg.Smtp.Server -Result 'Success' -Kind 'diag'; Write-PodeJsonResponse -Value @{ ok=$true } }
        catch { Write-ApiError $_ }
    }

    # ---------- SCHEDULED DIAGNOSTICS REPORT ----------
    # A Windows scheduled task ('DSMT-DiagReport') runs Send-DiagReport.ps1
    # on the configured cadence; the task itself carries no parameters -
    # everything it needs (hosts, recipients, SMTP) lives in config.json,
    # so changing the schedule here never requires re-registering with new
    # arguments, only the trigger time/frequency changes.
    Add-PodeRoute -Method Get -Path '/api/diag/schedule' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $cfg = $using:Config
        $task = Get-ScheduledTask -TaskName 'DSMT-DiagReport' -ErrorAction SilentlyContinue
        $info = if ($task) { Get-ScheduledTaskInfo -InputObject $task } else { $null }
        Write-PodeJsonResponse -Value @{
            enabled = [bool]$cfg.Diagnostics.ReportEnabled
            frequency = $cfg.Diagnostics.ReportFrequency; dayOfWeek = $cfg.Diagnostics.ReportDayOfWeek; time = $cfg.Diagnostics.ReportTime
            dcHosts = $cfg.Diagnostics.DcHosts; exchangeHosts = $cfg.Diagnostics.ExchangeHosts; recipients = $cfg.Diagnostics.ReportRecipients
            registered = [bool]$task
            lastRunTime = if ($info) { "$($info.LastRunTime)" } else { $null }
            lastResult  = if ($info) { $info.LastTaskResult } else { $null }
            nextRunTime = if ($info) { "$($info.NextRunTime)" } else { $null }
        }
    }
    Add-PodeRoute -Method Post -Path '/api/diag/schedule' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $cfg = $using:Config
        $d = $WebEvent.Data
        if (-not $cfg.Diagnostics) { $cfg | Add-Member -NotePropertyName Diagnostics -NotePropertyValue ([pscustomobject]@{}) -Force }
        $cfg.Diagnostics.ReportEnabled    = [bool]$d.enabled
        $cfg.Diagnostics.ReportFrequency  = [string]$d.frequency
        $cfg.Diagnostics.ReportDayOfWeek  = [string]$d.dayOfWeek
        $cfg.Diagnostics.ReportTime       = [string]$d.time
        $cfg.Diagnostics.DcHosts          = [string]$d.dcHosts
        $cfg.Diagnostics.ExchangeHosts    = [string]$d.exchangeHosts
        $cfg.Diagnostics.ReportRecipients = [string]$d.recipients
        try {
            Save-Config -Cfg $cfg -Path $using:cfgPath
            Unregister-ScheduledTask -TaskName 'DSMT-DiagReport' -Confirm:$false -ErrorAction SilentlyContinue
            if ($cfg.Diagnostics.ReportEnabled) {
                $scriptPath = Join-Path $using:here 'Send-DiagReport.ps1'
                $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
                $trigger = if ($cfg.Diagnostics.ReportFrequency -eq 'Weekly') {
                    New-ScheduledTaskTrigger -Weekly -DaysOfWeek $cfg.Diagnostics.ReportDayOfWeek -At $cfg.Diagnostics.ReportTime
                } else {
                    New-ScheduledTaskTrigger -Daily -At $cfg.Diagnostics.ReportTime
                }
                Register-ScheduledTask -TaskName 'DSMT-DiagReport' -Action $action -Trigger $trigger -RunLevel Highest -User 'SYSTEM' -Force | Out-Null
            }
            Write-Audit -Actor $s.username -Action $(if($cfg.Diagnostics.ReportEnabled){'Diagnostics report scheduled'}else{'Diagnostics report schedule disabled'}) -Target $cfg.Diagnostics.ReportRecipients -Result 'Success' -Kind 'diag'
            Write-PodeJsonResponse -Value @{ ok=$true }
        } catch {
            Write-PodeJsonResponse -StatusCode 400 -Value @{ ok=$false; error=$_.Exception.Message }
        }
    }
    Add-PodeRoute -Method Delete -Path '/api/diag/schedule' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $cfg = $using:Config
        try {
            Unregister-ScheduledTask -TaskName 'DSMT-DiagReport' -Confirm:$false -ErrorAction SilentlyContinue
            $cfg.Diagnostics.ReportEnabled = $false
            Save-Config -Cfg $cfg -Path $using:cfgPath
            Write-Audit -Actor $s.username -Action 'Diagnostics report schedule removed' -Target 'DSMT-DiagReport' -Result 'Success' -Kind 'diag'
            Write-PodeJsonResponse -Value @{ ok=$true }
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/diag/report/run' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $cfg = $using:Config
        $dcHosts = @($cfg.Diagnostics.DcHosts -split '[,;\r\n]+' | Where-Object { $_ })
        $exHosts = @($cfg.Diagnostics.ExchangeHosts -split '[,;\r\n]+' | Where-Object { $_ })
        $recipients = @($cfg.Diagnostics.ReportRecipients -split '[,;\r\n]+' | Where-Object { $_ })
        if ($recipients.Count -eq 0) { Write-PodeJsonResponse -StatusCode 400 -Value @{ ok=$false; error='No report recipients configured.' }; return }
        try {
            $r = Send-DiagnosticsReport -Smtp $cfg.Smtp -DcHosts $dcHosts -ExchangeHosts $exHosts -Recipients $recipients
            Write-Audit -Actor $s.username -Action 'Diagnostics report run (manual)' -Target ($recipients -join ',') -Result 'Success' -Kind 'diag'
            Write-PodeJsonResponse -Value $r
        } catch {
            Write-Audit -Actor $s.username -Action 'Diagnostics report run (manual)' -Target ($recipients -join ',') -Result 'Error' -Kind 'diag' -Detail $_.Exception.Message
            Write-PodeJsonResponse -StatusCode 400 -Value @{ ok=$false; error=$_.Exception.Message }
        }
    }

    # ---------- VCENTER / ESXI ----------
    Add-PodeRoute -Method Get -Path '/api/vcenter/connections' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $rows = @(Get-VCenterConnections | ForEach-Object {
            @{ id=[int]$_['Id']; server=[string]$_['Server']; username=[string]$_['Username']; enabled=[bool]$_['Enabled']; allowUntrustedCert=[bool]$_['AllowUntrustedCert']
               lastSyncAt=$(if($_['LastSyncAt']){"$($_['LastSyncAt'])"}else{$null}); lastResult=[string]$_['LastResult']; lastDetail=[string]$_['LastDetail'] }
        })
        Write-PodeJsonResponse -Value @{ connections = $rows; powerCliInstalled = (Test-PowerCli) }
    }
    Add-PodeRoute -Method Post -Path '/api/vcenter/connections' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $d = $WebEvent.Data
        if ([string]::IsNullOrWhiteSpace($d.server) -or [string]::IsNullOrWhiteSpace($d.username) -or [string]::IsNullOrWhiteSpace($d.password)) {
            Write-PodeJsonResponse -StatusCode 400 -Value @{ ok=$false; error='server, username and password are all required.' }; return
        }
        try {
            $id = Add-VCenterConnection -Server $d.server -Username $d.username -Password $d.password -AllowUntrustedCert:([bool]$d.allowUntrustedCert)
            Write-Audit -Actor $s.username -Action 'vCenter connection saved' -Target $d.server -Result 'Success' -Kind 'vcenter'
            Write-PodeJsonResponse -Value @{ ok=$true; id=$id }
        } catch {
            Write-PodeJsonResponse -StatusCode 400 -Value @{ ok=$false; error=$_.Exception.Message }
        }
    }
    Add-PodeRoute -Method Delete -Path '/api/vcenter/connections/:id' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $id = [int]$WebEvent.Parameters['id']
        try {
            Remove-VCenterConnection -Id $id
            Write-Audit -Actor $s.username -Action 'vCenter connection removed' -Target "$id" -Result 'Success' -Kind 'vcenter'
            Write-PodeJsonResponse -Value @{ ok=$true }
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/vcenter/connections/:id/toggle' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $id = [int]$WebEvent.Parameters['id']; $en = [bool]$WebEvent.Data.enabled
        try {
            Set-VCenterConnectionEnabled -Id $id -Enabled $en
            Write-Audit -Actor $s.username -Action $(if($en){'vCenter connection enabled'}else{'vCenter connection disabled'}) -Target "$id" -Result 'Success' -Kind 'vcenter'
            Write-PodeJsonResponse -Value @{ ok=$true }
        } catch { Write-ApiError $_ }
    }
    # Pulls fresh permissions from vCenter/ESXi right now and stores a new
    # timestamped snapshot - can take a while (PowerCLI connect + full
    # permission enumeration), so failures need a specific, readable reason
    # (bad credentials vs. unreachable host vs. PowerCLI missing), not a
    # generic 500 - the console shows $_.Exception.Message directly.
    Add-PodeRoute -Method Post -Path '/api/vcenter/connections/:id/sync' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $id = [int]$WebEvent.Parameters['id']
        try {
            $r = Sync-VCenterConnection -ConnectionId $id
            Write-Audit -Actor $s.username -Action 'vCenter sync' -Target "$id" -Result 'Success' -Kind 'vcenter' -Detail "$($r.count) entries"
            Write-PodeJsonResponse -Value @{ ok=$true; count=$r.count; syncId="$($r.syncId)" }
        } catch {
            Write-Audit -Actor $s.username -Action 'vCenter sync' -Target "$id" -Result 'Error' -Kind 'vcenter' -Detail $_.Exception.Message
            Write-PodeJsonResponse -StatusCode 400 -Value @{ ok=$false; error=$_.Exception.Message }
        }
    }
    Add-PodeRoute -Method Get -Path '/api/vcenter/connections/:id/permissions' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $id = [int]$WebEvent.Parameters['id']
        try {
            $rows = @(Get-VCenterLatestPermissions -ConnectionId $id | ForEach-Object {
                @{ principal=[string]$_['Principal']; role=[string]$_['Role']; entity=[string]$_['Entity']; entityType=[string]$_['EntityType']; propagate=[bool]$_['Propagate']; isGroup=[bool]$_['IsGroup']; capturedAt="$($_['CapturedAt'])" }
            })
            Write-PodeJsonResponse -Value @{ permissions = $rows }
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Get -Path '/api/vcenter/connections/:id/history' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $id = [int]$WebEvent.Parameters['id']
        try {
            $rows = @(Get-VCenterSyncHistory -ConnectionId $id | ForEach-Object {
                @{ syncId="$($_['SyncId'])"; syncedAt="$($_['SyncedAt'])"; entryCount=[int]$_['EntryCount'] }
            })
            Write-PodeJsonResponse -Value @{ history = $rows }
        } catch { Write-ApiError $_ }
    }

    # ---------- REMOTE EVENT VIEWER ----------
    Add-PodeRoute -Method Get -Path '/api/events' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        $server = $WebEvent.Query['server']
        if ([string]::IsNullOrWhiteSpace($server)) { Write-PodeJsonResponse -StatusCode 400 -Value @{ error = 'server is required' }; return }
        $log   = if ($WebEvent.Query['log'])   { $WebEvent.Query['log'] }        else { 'System' }
        $hours = if ($WebEvent.Query['hours']) { [int]$WebEvent.Query['hours'] } else { 24 }
        $q     = $WebEvent.Query['q']
        $lv    = @(1,2,3)
        if ($WebEvent.Query['levels']) { $lv = @($WebEvent.Query['levels'] -split ',' | ForEach-Object { [int]$_ }) }
        try { Write-PodeJsonResponse -Value @{ events = @(Get-RemoteEvents -Server $server -LogName $log -Hours $hours -Levels $lv -Query $q) } }
        catch { Write-ApiError $_ }
    }

    # ---------- USER LOCK / UNLOCK ----------
    Add-PodeRoute -Method Post -Path '/api/users/:sam/lock' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $sam = $WebEvent.Parameters['sam']
        $lock = [bool]$WebEvent.Data.locked
        try {
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
        } catch {
            Write-Audit -Actor $s.username -Action $(if($lock){'User lock failed'}else{'User unlock failed'}) -Target $sam -Result 'Error' -Kind 'lock' -Detail $_.Exception.Message
            Write-ApiError $_
        }
    }

    # ---------- CREATE USER ----------
    Add-PodeRoute -Method Post -Path '/api/users' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $sam = $WebEvent.Data.sam
        $name = if ($WebEvent.Data.name) { $WebEvent.Data.name } else { $sam }
        $cfg = $using:Config
        $ou   = if ($WebEvent.Data.ou)   { $WebEvent.Data.ou }   else { $cfg.Directory.BaseDN }
        if (-not $sam) { Write-PodeJsonResponse -StatusCode 400 -Value @{ ok=$false; error='sam is required' }; return }
        $initPw = 'Tmp-' + [guid]::NewGuid().ToString('N').Substring(0,10) + '!Aa1'
        try {
            New-DirectoryUser -Sam $sam -DisplayName $name -Ou $ou -InitialPassword $initPw | Out-Null
            Write-Audit -Actor $s.username -Action 'User created' -Target $sam -Result 'Success' -Kind 'user'
            Write-PodeJsonResponse -Value @{ ok=$true; sam=$sam; initialPassword=$initPw }
        } catch { Write-ApiError $_ }
    }

    # ---------- GROUP MEMBERS (add / remove) ----------
    Add-PodeRoute -Method Post -Path '/api/groups/:name/members' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $group = $WebEvent.Parameters['name']
        $sam   = $WebEvent.Data.sam
        if (-not $sam) { Write-PodeJsonResponse -StatusCode 400 -Value @{ ok=$false; error='sam is required' }; return }
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
            Add-ADGroupMember -Identity $group -Members $sam -Confirm:$false
            Write-Audit -Actor $s.username -Action 'Group member added' -Target "$group <- $sam" -Result 'Success' -Kind 'user'
            Write-PodeJsonResponse -Value @{ ok=$true }
        } catch { Write-ApiError $_ }
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
        } catch { Write-ApiError $_ }
    }

    # ---------- SCHEDULED JOBS (Windows Task Scheduler) ----------
    # Lists only the scheduled tasks THIS application registers (the
    # 'DSMT-' prefix, e.g. DSMT-DiagReport from Settings > Notifications /
    # Diagnostics) - not every task on the machine. A fixed demo list of
    # unrelated job names had no relationship to what actually exists, and
    # listing the whole Task Scheduler library would be equally irrelevant
    # noise (other software's tasks, none of which this console can act on).
    Add-PodeRoute -Method Get -Path '/api/jobs' -ScriptBlock {
        if (-not (Get-Session $WebEvent)) { Write-401; return }
        try {
            $rows = @(Get-ScheduledTask | Where-Object { $_.TaskName -like 'DSMT-*' } | ForEach-Object {
                $info = Get-ScheduledTaskInfo -InputObject $_ -ErrorAction SilentlyContinue
                @{
                    name        = $_.TaskName
                    path        = $_.TaskPath
                    enabled     = ($_.State -ne 'Disabled')
                    state       = "$($_.State)"
                    lastRunTime = if ($info) { "$($info.LastRunTime)" } else { $null }
                    nextRunTime = if ($info) { "$($info.NextRunTime)" } else { $null }
                    lastResult  = if ($info) { $info.LastTaskResult } else { $null }
                }
            })
            Write-PodeJsonResponse -Value @{ jobs = $rows }
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/jobs/:name/toggle' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $name    = $WebEvent.Parameters['name']
        $enabled = [bool]$WebEvent.Data.enabled
        try {
            $task = Get-ScheduledTask -TaskName $name -ErrorAction Stop
            if ($enabled) { Enable-ScheduledTask -InputObject $task | Out-Null } else { Disable-ScheduledTask -InputObject $task | Out-Null }
            Write-Audit -Actor $s.username -Action $(if($enabled){'Job enabled'}else{'Job disabled'}) -Target $name -Result 'Success' -Kind 'sync'
            Write-PodeJsonResponse -Value @{ ok=$true; enabled=$enabled }
        } catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/jobs/:name/run' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $name = $WebEvent.Parameters['name']
        try {
            Start-ScheduledTask -TaskName $name -ErrorAction Stop
            Write-Audit -Actor $s.username -Action 'Job run manually' -Target $name -Result 'Success' -Kind 'sync'
            Write-PodeJsonResponse -Value @{ ok=$true }
        } catch { Write-ApiError $_ }
    }

    # ---------- CONFIG SAVE (from console Settings tabs) ----------
    Add-PodeRoute -Method Post -Path '/api/config' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $d = $WebEvent.Data
        $cfg = $using:Config
        if ($d.directory) {
            if ($d.directory.ldapServer) { $cfg.Directory.LdapServer = $d.directory.ldapServer }
            if ($d.directory.baseDN)     { $cfg.Directory.BaseDN     = $d.directory.baseDN }
            if ($null -ne $d.directory.ssoEnabled) {
                $cfg.Directory.SsoEnabled = [bool]$d.directory.ssoEnabled
                Write-Audit -Actor $s.username -Action $(if([bool]$d.directory.ssoEnabled){'SSO enabled'}else{'SSO disabled'}) -Target 'console' -Result 'Success' -Kind 'auth'
            }
        }
        try { Save-Config -Cfg $cfg -Path $using:cfgPath; Write-PodeJsonResponse -Value @{ ok=$true } }
        catch { Write-ApiError $_ }
    }
    # Lets the console's Settings -> General "Test connection" button check the
    # LDAP server/Base DN currently typed in the form - before Save, so a typo
    # can be caught without persisting it first. Reuses the same
    # Get-UserGroups probe /api/health already uses for its LDAP check.
    Add-PodeRoute -Method Post -Path '/api/directory/test' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $d = $WebEvent.Data
        $server = $d.ldapServer
        $baseDn = $d.baseDN
        if ([string]::IsNullOrWhiteSpace($server) -or [string]::IsNullOrWhiteSpace($baseDn)) {
            Write-PodeJsonResponse -Value @{ ok = $false; error = 'LDAP server and Base DN are both required.' }; return
        }
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            Get-UserGroups -Server $server -BaseDN $baseDn -SamAccountName 'krbtgt' | Out-Null
            $sw.Stop()
            Write-PodeJsonResponse -Value @{ ok = $true; detail = "Reached $server ($baseDn) in $($sw.ElapsedMilliseconds) ms" }
        } catch {
            Write-PodeJsonResponse -Value @{ ok = $false; error = $_.Exception.Message }
        }
    }
    Add-PodeRoute -Method Post -Path '/api/ca/config' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $d = $WebEvent.Data
        $cfg = $using:Config
        if ($d.host)       { $cfg.CertificateAuthority.Host       = $d.host }
        if ($d.commonName) { $cfg.CertificateAuthority.CommonName = $d.commonName }
        $cfg.CertificateAuthority.ConfigString = "$($cfg.CertificateAuthority.Host)\$($cfg.CertificateAuthority.CommonName)"
        try { Save-Config -Cfg $cfg -Path $using:cfgPath; Write-PodeJsonResponse -Value @{ ok=$true } }
        catch { Write-ApiError $_ }
    }
    Add-PodeRoute -Method Post -Path '/api/db/config' -ScriptBlock {
        $s = Get-Session $WebEvent; if (-not $s) { Write-401; return }
        $d = $WebEvent.Data
        $cfg = $using:Config
        if ($d.host)    { $cfg.Database.Server  = $d.host }
        if ($d.port)    { $cfg.Database.Port     = [int]$d.port }
        if ($d.name)    { $cfg.Database.Name     = $d.name }
        if ($d.auth)    { $cfg.Database.Auth     = $d.auth }
        if ($null -ne $d.user)     { $cfg.Database.User     = $d.user }
        if ($null -ne $d.password) { $cfg.Database.Password = $d.password }
        if ($null -ne $d.encrypt) { $cfg.Database.Encrypt = [bool]$d.encrypt }
        try { Save-Config -Cfg $cfg -Path $using:cfgPath; Write-PodeJsonResponse -Value @{ ok=$true } }
        catch { Write-ApiError $_ }
    }

    Write-Host "Directory Services Management Tool API listening on $proto`://$($Config.Api.ListenAddress):$($Config.Api.Port)"
}

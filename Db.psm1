<#
  Db.psm1 - SQL data access for the Directory Services Management Tool API.
  Uses System.Data.SqlClient (built into Windows PowerShell 5.1).
  On PowerShell 7+, install the SqlServer module OR run under Windows PowerShell.
#>

$script:ConnectionString = $null
$script:DbLogDir = $null

function Get-DbLogPath {
    # <InstallDir>\logs\dsmt-sql.log  (logs sits next to the server\ folder).
    if (-not $script:DbLogDir) {
        try { $script:DbLogDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'logs' }
        catch { $script:DbLogDir = $PSScriptRoot }
    }
    return (Join-Path $script:DbLogDir 'dsmt-sql.log')
}

function Protect-ConnString {
    param([string] $Cs)
    if (-not $Cs) { return '' }
    return ($Cs -replace '(?i)(Password\s*=)[^;]*', '$1***')
}

function Write-DbLog {
    param([string] $Message)
    try {
        $path = Get-DbLogPath
        $dir  = Split-Path -Parent $path
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -Path $path -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '  ' + $Message)
    } catch {}
}

function Initialize-Db {
    param([Parameter(Mandatory)] $DbConfig, [switch] $ProbeOnly)

    $enc   = if ($DbConfig.Encrypt) { 'True' } else { 'False' }
    $trust = if ($DbConfig.TrustServerCertificate) { 'True' } else { 'False' }
    $srv   = "$($DbConfig.Server),$($DbConfig.Port)"

    if ($DbConfig.Auth -eq 'SQL') {
        $script:ConnectionString = "Server=$srv;Database=$($DbConfig.Name);User Id=$($DbConfig.User);Password=$($DbConfig.Password);Encrypt=$enc;TrustServerCertificate=$trust;Connect Timeout=5;"
    } else {
        $script:ConnectionString = "Server=$srv;Database=$($DbConfig.Name);Integrated Security=SSPI;Encrypt=$enc;TrustServerCertificate=$trust;Connect Timeout=5;"
    }

    # ProbeOnly: verify the app database is actually reachable with this string.
    # Throws if not - used by Test-SetupComplete to decide setup vs. normal mode.
    if ($ProbeOnly) {
        $c = New-Object System.Data.SqlClient.SqlConnection ($script:ConnectionString + 'Connect Timeout=5;')
        try { $c.Open(); $cmd = $c.CreateCommand(); $cmd.CommandText = 'SELECT 1'; [void]$cmd.ExecuteScalar() }
        finally { $c.Close() }
    }
}

function Build-ServerConnString {
    <# Connection string to the server's master DB (no app database needed yet). #>
    param([Parameter(Mandatory)] $DbConfig)
    $enc   = if ($DbConfig.Encrypt) { 'True' } else { 'False' }
    $trust = if ($DbConfig.TrustServerCertificate) { 'True' } else { 'False' }
    $srv   = "$($DbConfig.Server),$($DbConfig.Port)"
    if ($DbConfig.Auth -eq 'SQL') {
        return "Server=$srv;Database=master;User Id=$($DbConfig.User);Password=$($DbConfig.Password);Encrypt=$enc;TrustServerCertificate=$trust;Connect Timeout=5;"
    }
    return "Server=$srv;Database=master;Integrated Security=SSPI;Encrypt=$enc;TrustServerCertificate=$trust;Connect Timeout=5;"
}

function Test-SqlServer {
    <# Verifies the server is reachable on its port and the credentials can log in. #>
    param([Parameter(Mandatory)] $DbConfig)
    $conn = New-Object System.Data.SqlClient.SqlConnection (Build-ServerConnString $DbConfig)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand(); $cmd.CommandText = 'SELECT @@VERSION'
        $ver = [string]$cmd.ExecuteScalar()
        return [pscustomobject]@{ ok = $true; version = ($ver -split "`n")[0].Trim() }
    } catch {
        Write-DbLog ("Test-SqlServer failed: " + $_.Exception.Message + "  [" + (Protect-ConnString (Build-ServerConnString $DbConfig)) + "]")
        return [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
    } finally { $conn.Close() }
}

function Get-Databases {
    <# Lists user databases on the server (excludes system DBs). #>
    param([Parameter(Mandatory)] $DbConfig)
    $conn = New-Object System.Data.SqlClient.SqlConnection (Build-ServerConnString $DbConfig)
    try {
        $conn.Open()
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = "SELECT name FROM sys.databases WHERE database_id > 4 ORDER BY name"
        $rd = $cmd.ExecuteReader(); $list = @()
        while ($rd.Read()) { $list += $rd['name'] }
        return $list
    } finally { $conn.Close() }
}

function New-AppDatabase {
    <# Creates the database (if missing) and applies schema.sql to build/seed tables. #>
    param([Parameter(Mandatory)] $DbConfig, [Parameter(Mandatory)][string] $SchemaPath, [string] $DbName = $null)
    $name = if ($DbName) { $DbName } else { $DbConfig.Name }
    $conn = New-Object System.Data.SqlClient.SqlConnection (Build-ServerConnString $DbConfig)
    try {
        $conn.Open()
        $schema = (Get-Content $SchemaPath -Raw) -replace 'DSMTOOL', $name
        foreach ($batch in ($schema -split '(?im)^\s*GO\s*$')) {
            if ($batch.Trim()) { $cmd = $conn.CreateCommand(); $cmd.CommandText = $batch; [void]$cmd.ExecuteNonQuery() }
        }
        return [pscustomobject]@{ ok = $true; name = $name }
    } catch {
        return [pscustomobject]@{ ok = $false; error = $_.Exception.Message }
    } finally { $conn.Close() }
}

function Initialize-DbFromConfigFile {
    # Lazy bootstrap for Pode route runspaces: each route runs in its own
    # runspace where this module is re-imported fresh ($script:ConnectionString
    # = $null), so we re-derive it from config.json (sibling of the server folder)
    # on first use. config.json lives one level up from this module's folder.
    $cfgPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config.json'
    if (-not (Test-Path $cfgPath)) { throw "Database not initialized and config.json not found at $cfgPath." }
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    if (-not $cfg.Database -or [string]::IsNullOrWhiteSpace($cfg.Database.Server) -or [string]::IsNullOrWhiteSpace($cfg.Database.Name)) {
        throw 'Database not initialized: config.json has no Database.Server/Name yet.'
    }
    Initialize-Db -DbConfig $cfg.Database
}

function New-SqlConnection {
    if (-not $script:ConnectionString) { Initialize-DbFromConfigFile }
    $c = New-Object System.Data.SqlClient.SqlConnection $script:ConnectionString
    try { $c.Open() }
    catch { Write-DbLog ("Connection failed: " + $_.Exception.Message + "  [" + (Protect-ConnString $script:ConnectionString) + "]"); throw }
    return $c
}

function Invoke-Sql {
    <# Returns DataRow[] for SELECT, scalar with -Scalar, affected rows with -NonQuery. #>
    param(
        [Parameter(Mandatory)][string] $Query,
        [hashtable] $Params = @{},
        [switch] $Scalar,
        [switch] $NonQuery
    )
    $conn = New-SqlConnection
    try {
        $cmd = $conn.CreateCommand()
        $cmd.CommandText = $Query
        foreach ($k in $Params.Keys) {
            $p = $cmd.Parameters.Add("@$k", [System.Data.SqlDbType]::NVarChar, -1)
            $p.Value = if ($null -eq $Params[$k]) { [DBNull]::Value } else { [string]$Params[$k] }
        }
        if ($Scalar)   { return $cmd.ExecuteScalar() }
        if ($NonQuery) { return $cmd.ExecuteNonQuery() }

        $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
        $dt = New-Object System.Data.DataTable
        [void]$da.Fill($dt)
        return ,$dt.Rows
    }
    finally { $conn.Close() }
}

function Get-Config {
    param([string] $Key)
    if ($Key) {
        return (Invoke-Sql 'SELECT [Value] FROM dbo.Config WHERE [Key]=@k' @{ k = $Key } -Scalar)
    }
    $rows = Invoke-Sql 'SELECT [Key],[Value] FROM dbo.Config'
    $h = @{}
    foreach ($r in $rows) { $h[$r['Key']] = $r['Value'] }
    return $h
}

function Set-Config {
    param([string] $Key, [string] $Value, [string] $By = 'system')
    Invoke-Sql @'
MERGE dbo.Config AS t USING (SELECT @k AS [Key]) AS s ON t.[Key]=s.[Key]
WHEN MATCHED THEN UPDATE SET [Value]=@v, UpdatedAt=SYSUTCDATETIME(), UpdatedBy=@by
WHEN NOT MATCHED THEN INSERT([Key],[Value],UpdatedBy) VALUES(@k,@v,@by);
'@ @{ k = $Key; v = $Value; by = $By } -NonQuery | Out-Null
}

function Write-Audit {
    param(
        [string] $Actor, [string] $Action, [string] $Target,
        [ValidateSet('Success','Denied','Warning','Error')][string] $Result = 'Success',
        [string] $Kind = $null, [string] $Detail = $null, [string] $SourceIp = $null
    )
    Invoke-Sql @'
INSERT INTO dbo.AuditLog(Actor,Action,Target,Result,Kind,Detail,SourceIp)
VALUES(@a,@ac,@t,@r,@k,@d,@ip)
'@ @{ a=$Actor; ac=$Action; t=$Target; r=$Result; k=$Kind; d=$Detail; ip=$SourceIp } -NonQuery | Out-Null
}

function Get-AuditLog {
    param([int] $Top = 200, [string] $Kind = $null)
    $where = if ($Kind) { 'WHERE Kind=@k' } else { '' }
    Invoke-Sql "SELECT TOP $Top [Time],Actor,Action,Target,Result,Kind FROM dbo.AuditLog $where ORDER BY [Time] DESC" @{ k = $Kind }
}

function Get-RoleMappings {
    Invoke-Sql 'SELECT Id,LdapGroup,ConsoleRole FROM dbo.RoleMappings ORDER BY Id'
}

function Get-DbInfo {
    <# Real connection details from config.json + live status/size/schema/backup queries. #>
    $cfgPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config.json'
    if (-not (Test-Path $cfgPath)) { throw "config.json not found at $cfgPath." }
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $d = $cfg.Database
    $info = [ordered]@{
        ok            = $true
        connected     = $false
        host          = "$($d.Server)"
        port          = "$($d.Port)"
        server        = "$($d.Server),$($d.Port)"
        database      = "$($d.Name)"
        auth          = "$($d.Auth)"
        encrypt       = [bool]$d.Encrypt
        schemaVersion = $null
        migrations    = $null
        sizeMb        = $null
        lastBackup    = $null
        recoveryModel = $null
        error         = $null
    }
    try {
        $sv = Invoke-Sql "SELECT [Value] FROM dbo.Config WHERE [Key]='SchemaVersion'" -Scalar
        if ($null -ne $sv -and $sv -ne [DBNull]::Value) { $info.schemaVersion = [string]$sv; $info.migrations = [string]$sv }
        $info.connected = $true
        try { $info.sizeMb = [int](Invoke-Sql "SELECT CAST(SUM(size)*8.0/1024 AS INT) FROM sys.master_files WHERE database_id = DB_ID()" -Scalar) } catch {}
        try { $info.recoveryModel = [string](Invoke-Sql "SELECT recovery_model_desc FROM sys.databases WHERE name = DB_NAME()" -Scalar) } catch {}
        try {
            $lb = Invoke-Sql "SELECT MAX(backup_finish_date) FROM msdb.dbo.backupset WHERE database_name = DB_NAME()" -Scalar
            if ($null -ne $lb -and $lb -ne [DBNull]::Value) { $info.lastBackup = ([datetime]$lb).ToString('yyyy-MM-dd HH:mm') }
        } catch {}
    } catch { $info.connected = $false; $info.error = $_.Exception.Message; Write-DbLog ("Get-DbInfo failed: " + $_.Exception.Message) }
    return [pscustomobject]$info
}

function Invoke-DbBackup {
    <# Full backup of the configured database to the SQL server's default backup path. #>
    $name = [string](Invoke-Sql "SELECT DB_NAME()" -Scalar)
    if ([string]::IsNullOrWhiteSpace($name) -or $name -eq 'master') { throw "Not connected to the application database." }
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $file  = $name + '_' + $stamp + '.bak'
    # Use the instance default backup directory; the [$name] is the live DB_NAME() (safe).
    $sql = "DECLARE @p NVARCHAR(512) = CAST(SERVERPROPERTY('InstanceDefaultBackupPath') AS NVARCHAR(512));" +
           " IF @p IS NULL SET @p = N'';" +
           " DECLARE @f NVARCHAR(1024) = @p + N'$file';" +
           " BACKUP DATABASE [$name] TO DISK = @f WITH INIT;"
    Invoke-Sql $sql -NonQuery | Out-Null
    return [pscustomobject]@{ ok = $true; file = $file }
}

function Invoke-DbMigrate {
    <# Re-applies schema.sql to the configured database (idempotent) and returns the schema version. #>
    param([Parameter(Mandatory)][string] $SchemaPath)
    $cfgPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'config.json'
    $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json
    $r = New-AppDatabase -DbConfig $cfg.Database -SchemaPath $SchemaPath -DbName $cfg.Database.Name
    if (-not $r.ok) { return $r }
    $sv = $null
    try { $sv = [string](Invoke-Sql "SELECT [Value] FROM dbo.Config WHERE [Key]='SchemaVersion'" -Scalar) } catch {}
    return [pscustomobject]@{ ok = $true; schemaVersion = $sv }
}

Export-ModuleMember -Function Initialize-Db, Invoke-Sql, Get-Config, Set-Config,
    Write-Audit, Get-AuditLog, Get-RoleMappings,
    Test-SqlServer, Get-Databases, New-AppDatabase,
    Get-DbInfo, Invoke-DbBackup, Invoke-DbMigrate

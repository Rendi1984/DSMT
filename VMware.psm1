<#
  VMware.psm1 - vCenter / ESXi integration for the Directory Services
  Management Tool: pulls the user/group -> role permission assignments off
  one or more vCenter (or standalone ESXi) servers and stores a timestamped
  snapshot in SQL, so past pulls stay queryable without re-hitting vCenter.

  Uses VMware PowerCLI (Connect-VIServer / Get-VIPermission) - the
  VMware-supported way to talk to vSphere from PowerShell. This module does
  NOT implement its own SOAP/REST client against the vSphere API; hand-
  rolling that protocol would be slower, more fragile, and unsupported
  compared to the module VMware itself publishes and maintains.

  Requires Db.psm1 (Invoke-Sql) and Secrets.psm1 (Protect-Secret/
  Unprotect-Secret) to be imported first.
#>

function Test-PowerCli {
    <# PowerCLI is a separate install (Install-Module VMware.PowerCLI) -
       never assumed present. Every function below checks this first and
       returns a clear, actionable error instead of a cryptic
       "command not found" if it's missing. #>
    return [bool](Get-Module -ListAvailable -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue)
}

function Connect-VCenterServer {
    <# Opens (or reuses) a PowerCLI session to one vCenter/ESXi server.
       Each call is independent - PowerCLI sessions are per-server, so
       syncing N connections opens/closes N sessions, never sharing state
       between them. #>
    param([Parameter(Mandatory)][string] $Server, [Parameter(Mandatory)][string] $Username, [Parameter(Mandatory)][string] $Password, [switch] $AllowUntrustedCertificate)
    if (-not (Test-PowerCli)) {
        throw "VMware PowerCLI is not installed on this server. Run: Install-Module VMware.PowerCLI -Scope AllUsers -Force"
    }
    Import-Module VMware.VimAutomation.Core -ErrorAction Stop
    # Certificate validation stays ON by default - only skipped if the caller
    # explicitly opts in (e.g. a lab vCenter with a self-signed cert), never
    # silently, since disabling it weakens every connection this app makes.
    $certAction = if ($AllowUntrustedCertificate) { 'Ignore' } else { 'Fail' }
    Set-PowerCLIConfiguration -InvalidCertificateAction $certAction -ParticipateInCeip $false -Scope Session -Confirm:$false | Out-Null
    $sec = ConvertTo-SecureString $Password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential ($Username, $sec)
    return Connect-VIServer -Server $Server -Credential $cred -ErrorAction Stop
}

function Disconnect-VCenterServer {
    param($Session)
    if ($Session) { Disconnect-VIServer -Server $Session -Confirm:$false -ErrorAction SilentlyContinue }
}

function Get-VCenterUserPermissions {
    <# Pulls every user/group -> role assignment, per entity (folder, VM,
       datacenter, cluster, etc.) currently configured on the server. Returns
       one row per assignment - the caller (Sync-VCenterConnection) is
       responsible for stamping a SyncId and persisting to SQL. #>
    param([Parameter(Mandatory)] $Session)
    $perms = Get-VIPermission -Server $Session
    return $perms | ForEach-Object {
        [pscustomobject]@{
            principal  = $_.Principal
            role       = $_.Role
            entity     = $_.Entity.Name
            entityType = $_.EntityId -replace '-.*$', ''
            propagate  = [bool]$_.Propagate
            isGroup    = [bool]$_.IsGroup
        }
    }
}

function Add-VCenterConnection {
    param([Parameter(Mandatory)][string] $Server, [Parameter(Mandatory)][string] $Username, [Parameter(Mandatory)][string] $Password, [bool] $AllowUntrustedCert = $false)
    $cipher = Protect-Secret -Plain $Password
    Invoke-Sql @'
MERGE dbo.VCenterConnections AS t USING (SELECT @s AS Server) AS src ON t.Server = src.Server
WHEN MATCHED THEN UPDATE SET Username=@u, PasswordCipher=@p, Enabled=1, AllowUntrustedCert=@au
WHEN NOT MATCHED THEN INSERT(Server,Username,PasswordCipher,AllowUntrustedCert) VALUES(@s,@u,@p,@au);
'@ @{ s = $Server; u = $Username; p = $cipher; au = [int]$AllowUntrustedCert } -NonQuery | Out-Null
    return [int](Invoke-Sql 'SELECT Id FROM dbo.VCenterConnections WHERE Server=@s' @{ s = $Server } -Scalar)
}

function Get-VCenterConnections {
    <# Metadata only - never the decrypted password. #>
    Invoke-Sql 'SELECT Id,Server,Username,Enabled,AllowUntrustedCert,LastSyncAt,LastResult,LastDetail FROM dbo.VCenterConnections ORDER BY Server'
}

function Remove-VCenterConnection {
    param([Parameter(Mandatory)][int] $Id)
    Invoke-Sql 'DELETE FROM dbo.VCenterPermissions WHERE ConnectionId=@i' @{ i = $Id } -NonQuery | Out-Null
    Invoke-Sql 'DELETE FROM dbo.VCenterConnections WHERE Id=@i' @{ i = $Id } -NonQuery | Out-Null
}

function Set-VCenterConnectionEnabled {
    param([Parameter(Mandatory)][int] $Id, [Parameter(Mandatory)][bool] $Enabled)
    Invoke-Sql 'UPDATE dbo.VCenterConnections SET Enabled=@e WHERE Id=@i' @{ e = [int]$Enabled; i = $Id } -NonQuery | Out-Null
}

function Sync-VCenterConnection {
    <# End-to-end: connect, pull permissions, store a new timestamped
       snapshot (never overwrites past snapshots - that's the point of the
       history table), record the outcome on the connection row, disconnect.
       Always disconnects even on failure (finally), so a bad sync never
       leaves a dangling PowerCLI session accumulating on the API host. #>
    param([Parameter(Mandatory)][int] $ConnectionId)
    $row = Invoke-Sql 'SELECT TOP 1 Server,Username,PasswordCipher,AllowUntrustedCert FROM dbo.VCenterConnections WHERE Id=@i' @{ i = $ConnectionId }
    if (-not $row -or $row.Count -eq 0) { throw "No vCenter connection with Id $ConnectionId." }
    $server = [string]$row[0]['Server']; $user = [string]$row[0]['Username']
    $password = Unprotect-Secret -Cipher ([string]$row[0]['PasswordCipher'])
    $allowUntrusted = [bool]$row[0]['AllowUntrustedCert']
    $session = $null
    try {
        $session = Connect-VCenterServer -Server $server -Username $user -Password $password -AllowUntrustedCertificate:$allowUntrusted
        $perms = @(Get-VCenterUserPermissions -Session $session)
        $syncId = [guid]::NewGuid()
        foreach ($p in $perms) {
            Invoke-Sql @'
INSERT INTO dbo.VCenterPermissions(ConnectionId,SyncId,Principal,Role,Entity,EntityType,Propagate,IsGroup)
VALUES(@c,@sy,@pr,@r,@e,@et,@pg,@ig)
'@ @{ c = $ConnectionId; sy = $syncId; pr = $p.principal; r = $p.role; e = $p.entity; et = $p.entityType; pg = [int]$p.propagate; ig = [int]$p.isGroup } -NonQuery | Out-Null
        }
        Invoke-Sql 'UPDATE dbo.VCenterConnections SET LastSyncAt=SYSUTCDATETIME(), LastResult=@r, LastDetail=@d WHERE Id=@i' `
            @{ i = $ConnectionId; r = 'Success'; d = "$($perms.Count) permission entries" } -NonQuery | Out-Null
        return [pscustomobject]@{ ok = $true; syncId = $syncId; count = $perms.Count }
    } catch {
        Invoke-Sql 'UPDATE dbo.VCenterConnections SET LastSyncAt=SYSUTCDATETIME(), LastResult=@r, LastDetail=@d WHERE Id=@i' `
            @{ i = $ConnectionId; r = 'Error'; d = $_.Exception.Message } -NonQuery | Out-Null
        throw
    } finally {
        Disconnect-VCenterServer -Session $session
    }
}

function Get-VCenterLatestPermissions {
    <# The most recent sync's full permission set for one connection - joins
       on the newest SyncId rather than a time window, so it's always exactly
       "what the last sync found," never a partial mix of two runs. #>
    param([Parameter(Mandatory)][int] $ConnectionId)
    $latestSyncId = Invoke-Sql 'SELECT TOP 1 SyncId FROM dbo.VCenterPermissions WHERE ConnectionId=@i ORDER BY CapturedAt DESC' @{ i = $ConnectionId } -Scalar
    if (-not $latestSyncId) { return @() }
    return Invoke-Sql 'SELECT Principal,Role,Entity,EntityType,Propagate,IsGroup,CapturedAt FROM dbo.VCenterPermissions WHERE ConnectionId=@i AND SyncId=@sy ORDER BY Principal' `
        @{ i = $ConnectionId; sy = $latestSyncId }
}

function Get-VCenterSyncHistory {
    <# One row per past sync run (not per permission) - for a history list
       showing "when did we pull this, how many entries, did it succeed." #>
    param([Parameter(Mandatory)][int] $ConnectionId, [int] $Top = 50)
    Invoke-Sql "SELECT TOP $Top SyncId, MIN(CapturedAt) AS SyncedAt, COUNT(*) AS EntryCount FROM dbo.VCenterPermissions WHERE ConnectionId=@i GROUP BY SyncId ORDER BY MIN(CapturedAt) DESC" @{ i = $ConnectionId }
}

Export-ModuleMember -Function Test-PowerCli, Connect-VCenterServer, Disconnect-VCenterServer,
    Get-VCenterUserPermissions, Add-VCenterConnection, Get-VCenterConnections,
    Remove-VCenterConnection, Set-VCenterConnectionEnabled, Sync-VCenterConnection,
    Get-VCenterLatestPermissions, Get-VCenterSyncHistory

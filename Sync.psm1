<#
  Sync.psm1 - Entra ID / Azure AD Connect delta synchronization.
  Opens a remote session to the AD Connect server and runs a delta cycle,
  then reports scheduler state. The API service account needs PSRemoting
  rights (and local admin) on the AD Connect server.
#>

function Start-DeltaSync {
    param([Parameter(Mandatory)][string] $AdConnectServer)

    $log = New-Object System.Collections.ArrayList
    [void]$log.Add(@{ kind='info'; text="Connecting to $AdConnectServer ..." })

    try {
        $session = New-PSSession -ComputerName $AdConnectServer -ErrorAction Stop
        [void]$log.Add(@{ kind='ok'; text='PSSession established.' })

        $result = Invoke-Command -Session $session -ScriptBlock {
            Import-Module ADSync -ErrorAction Stop
            $sched = Get-ADSyncScheduler
            if ($sched.SyncCycleInProgress) {
                return [pscustomobject]@{ started=$false; reason='A sync cycle is already in progress.' }
            }
            Start-ADSyncSyncCycle -PolicyType Delta | Out-Null
            return [pscustomobject]@{ started=$true; nextCycle=$sched.NextSyncCyclePolicyType }
        }

        if ($result.started) {
            [void]$log.Add(@{ kind='ok'; text='Sync cycle started (Delta).' })
            # Poll until the cycle is no longer in progress
            for ($i = 0; $i -lt 24; $i++) {
                Start-Sleep -Seconds 5
                $inProgress = Invoke-Command -Session $session -ScriptBlock {
                    (Get-ADSyncScheduler).SyncCycleInProgress
                }
                [void]$log.Add(@{ kind='info'; text="  cycle in progress: $inProgress" })
                if (-not $inProgress) { break }
            }
            [void]$log.Add(@{ kind='ok'; text='Sync cycle completed.' })
        } else {
            [void]$log.Add(@{ kind='warn'; text=$result.reason })
        }

        Remove-PSSession $session
        return [pscustomobject]@{ ok=$true; log=$log }
    }
    catch {
        [void]$log.Add(@{ kind='error'; text="Sync failed: $($_.Exception.Message)" })
        return [pscustomobject]@{ ok=$false; log=$log }
    }
}

function Get-SyncStatus {
    param([Parameter(Mandatory)][string] $AdConnectServer)
    try {
        $s = Invoke-Command -ComputerName $AdConnectServer -ScriptBlock {
            Import-Module ADSync -ErrorAction Stop
            $sched = Get-ADSyncScheduler
            [pscustomobject]@{
                enabled    = $sched.SyncCycleEnabled
                staging    = $sched.StagingModeEnabled
                inProgress = $sched.SyncCycleInProgress
                nextCycle  = $sched.NextSyncCycleStartTimeInUTC
                interval   = $sched.AllowedSyncCycleInterval.ToString()
            }
        }
        return [pscustomobject]@{ ok=$true; status=$s }
    } catch {
        return [pscustomobject]@{ ok=$false; error=$_.Exception.Message }
    }
}

Export-ModuleMember -Function Start-DeltaSync, Get-SyncStatus

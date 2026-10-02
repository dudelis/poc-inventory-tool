function Invoke-InventorySyncTimer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('AgentBuilder', 'RPA')] [string] $SyncType,
        [Parameter(Mandatory)] $DurableClient
    )

    $definition = if ($SyncType -eq 'AgentBuilder') {
        [pscustomobject] @{
            InstanceId       = 'agent-builder-inventory-sync'
            OrchestratorName = 'AgentSyncOrchestrator'
            DisplayName      = 'Agent'
        }
    }
    else {
        [pscustomobject] @{
            InstanceId       = 'rpa-inventory-sync'
            OrchestratorName = 'RpaSyncOrchestrator'
            DisplayName      = 'RPA'
        }
    }
    $correlationId = Get-InventoryOperationId
    $status = Get-DurableStatus -InstanceId $definition.InstanceId -DurableClient $DurableClient
    $activeStatuses = @('Pending', 'Running', 'ContinuedAsNew', 'Suspended')

    if ($null -ne $status -and [string] $status.RuntimeStatus -in $activeStatuses) {
        try {
            $configuration = Get-InventorySyncConfiguration -SyncType $SyncType
            Write-InventorySyncSkippedRun -Configuration $configuration -SyncType $SyncType `
                -CorrelationId $correlationId -InstanceId $definition.InstanceId `
                -RuntimeStatus ([string] $status.RuntimeStatus) | Out-Null
        }
        catch {
            Write-InventoryTrace -Level Warning `
                -Message "$($definition.DisplayName) sync start skipped because the singleton is active." `
                -CorrelationId $correlationId -Data @{
                    category      = 'RunSkipped'
                    instanceId    = $definition.InstanceId
                    runtimeStatus = [string] $status.RuntimeStatus
                    loggingError  = $_.Exception.Message
                }
        }
        return
    }

    Start-DurableOrchestration -FunctionName $definition.OrchestratorName `
        -InstanceId $definition.InstanceId -InputObject @{ CorrelationId = $correlationId } `
        -DurableClient $DurableClient | Out-Null
}

function Invoke-InventorySyncOrchestrator {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('AgentBuilder', 'RPA')] [string] $SyncType,
        [Parameter(Mandatory)] $Context
    )

    $fallback = if (
        $null -ne $Context.Input -and
        -not [string]::IsNullOrWhiteSpace([string] $Context.Input.CorrelationId)
    ) {
        [string] $Context.Input.CorrelationId
    }
    else {
        [string] $Context.InstanceId
    }
    $activityName = if ($SyncType -eq 'AgentBuilder') {
        'AgentSyncCreateActivity'
    }
    else {
        'RpaSyncActivity'
    }
    Invoke-DurableActivity -FunctionName $activityName -InputObject @{
        CorrelationId = $fallback
    }
}

function Invoke-InventorySyncActivity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('AgentBuilder', 'RPA')] [string] $SyncType,
        [Parameter(Mandatory)] $InputObject
    )

    $correlationId = Get-InventoryOperationId -Fallback ([string] $InputObject.CorrelationId)
    $configuration = Get-InventorySyncConfiguration -SyncType $SyncType
    if ($SyncType -eq 'AgentBuilder') {
        return Invoke-AgentSync -Configuration $configuration -CorrelationId $correlationId
    }
    Invoke-RpaSync -Configuration $configuration -CorrelationId $correlationId
}

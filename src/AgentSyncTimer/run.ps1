param($Timer, $TriggerMetadata, $DurableClient)

$instanceId = 'agent-builder-inventory-sync'
$status = Get-DurableStatus -InstanceId $instanceId -DurableClient $DurableClient
$activeStatuses = @('Pending', 'Running', 'ContinuedAsNew', 'Suspended')

if ($null -ne $status -and [string] $status.RuntimeStatus -in $activeStatuses) {
    Write-InventoryTrace -Level Warning -Message 'Agent sync start skipped because the singleton is active.' `
        -CorrelationId $instanceId -Data @{
            category      = 'RunSkipped'
            instanceId    = $instanceId
            runtimeStatus = [string] $status.RuntimeStatus
        }
    return
}

Start-DurableOrchestration -FunctionName 'AgentSyncOrchestrator' -InstanceId $instanceId `
    -DurableClient $DurableClient | Out-Null

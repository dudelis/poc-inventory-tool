param($Timer, $TriggerMetadata, $DurableClient)

$instanceId = 'rpa-inventory-sync'
$correlationId = [guid]::NewGuid().ToString()
$status = Get-DurableStatus -InstanceId $instanceId -DurableClient $DurableClient
$activeStatuses = @('Pending', 'Running', 'ContinuedAsNew', 'Suspended')

if ($null -ne $status -and [string] $status.RuntimeStatus -in $activeStatuses) {
    try {
        $configuration = Get-InventorySyncConfiguration
        Write-RpaSyncSkippedRun -Configuration $configuration `
            -CorrelationId $correlationId -InstanceId $instanceId `
            -RuntimeStatus ([string] $status.RuntimeStatus) | Out-Null
    }
    catch {
        Write-InventoryTrace -Level Warning -Message 'RPA sync start skipped because the singleton is active.' `
            -CorrelationId $correlationId -Data @{
                category      = 'RunSkipped'
                instanceId    = $instanceId
                runtimeStatus = [string] $status.RuntimeStatus
                loggingError  = $_.Exception.Message
            }
    }
    return
}

Start-DurableOrchestration -FunctionName 'RpaSyncOrchestrator' -InstanceId $instanceId `
    -InputObject @{ CorrelationId = $correlationId } -DurableClient $DurableClient | Out-Null

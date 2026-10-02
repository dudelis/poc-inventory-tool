param($Context)

Invoke-DurableActivity -FunctionName 'AgentSyncCreateActivity' -InputObject @{
    CorrelationId = $Context.InstanceId
}

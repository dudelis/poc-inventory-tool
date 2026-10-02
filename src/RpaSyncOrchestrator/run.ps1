param($Context)

$correlationId = if (
    $null -ne $Context.Input -and
    -not [string]::IsNullOrWhiteSpace([string] $Context.Input.CorrelationId)
) {
    [string] $Context.Input.CorrelationId
}
else {
    [string] $Context.InstanceId
}
Invoke-DurableActivity -FunctionName 'RpaSyncActivity' -InputObject @{
    CorrelationId = $correlationId
}

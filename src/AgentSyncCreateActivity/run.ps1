param($Input)

$configuration = Get-InventorySyncConfiguration
Invoke-AgentSync -Configuration $configuration -CorrelationId $Input.CorrelationId

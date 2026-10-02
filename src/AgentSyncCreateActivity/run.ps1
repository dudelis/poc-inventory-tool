param($Input)

$configuration = Get-InventorySyncConfiguration
Invoke-AgentCreateSync -Configuration $configuration -CorrelationId $Input.CorrelationId

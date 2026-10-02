param($Input)

$configuration = Get-InventorySyncConfiguration
Invoke-RpaSync -Configuration $configuration -CorrelationId $Input.CorrelationId

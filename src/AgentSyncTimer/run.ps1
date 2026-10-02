param($Timer, $TriggerMetadata, $DurableClient)

Invoke-InventorySyncTimer -SyncType AgentBuilder -DurableClient $DurableClient

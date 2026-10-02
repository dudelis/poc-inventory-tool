# Inventory Sync Logging solution

This folder is the unpacked source for the separate **Inventory Sync Logging**
Dataverse solution. It is intentionally unmanaged (`Managed` is `0`) and has
no dependency on the PALP solution.

Pack it with the Power Platform CLI:

```powershell
pac solution pack --zipfile .\InventorySyncLogging.zip `
  --folder .\solutions\InventorySyncLogging --packagetype Unmanaged
```

Import the resulting zip into the target Dataverse environment, grant the
sync application user create/read/write privileges on **Sync Run** and
**Sync Log**, and configure the entity-set names with
`INVENTORY_SYNC_RUN_TABLE` and `INVENTORY_SYNC_LOG_TABLE`.

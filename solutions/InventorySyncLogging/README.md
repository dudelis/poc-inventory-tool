# Inventory Sync Logging solution

This folder is the unpacked source for the separate **Inventory Sync Logging**
Dataverse solution. It is intentionally unmanaged (`Managed` is `0`) and has
no dependency on the PALP solution.

Portable installations should use `deploy\Invoke-InventoryDeployment.ps1 -Mode
DeployPowerPlatform`, which packs this source into a temporary archive on every run,
imports and publishes it in the configured PALP environment, verifies both tables,
and removes the archive.

For an existing installation outside the portable bootstrap, pack it manually with
the Power Platform CLI:

```powershell
pac solution pack --zipfile .\InventorySyncLogging.zip `
  --folder .\solutions\InventorySyncLogging --packagetype Unmanaged
```

Import the resulting zip into the target Dataverse environment, grant the
sync application user create/read/write privileges on **Sync Run** and
**Sync Log**, and configure the entity-set names with
`INVENTORY_SYNC_RUN_TABLE` and `INVENTORY_SYNC_LOG_TABLE`.

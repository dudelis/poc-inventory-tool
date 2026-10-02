# Inventory sync

PowerShell 7.6 Azure Functions project for synchronizing Power Platform inventory.

## Local setup

1. Copy `src/local.settings.example.json` to `src/local.settings.json`.
2. Replace every placeholder. In Azure, set `INVENTORY_CLIENT_SECRET` to a Key Vault reference.
3. Run the Function App from `src` with Azure Functions Core Tools.

The app uses `APPLICATIONINSIGHTS_CONNECTION_STRING`; instrumentation-key configuration and custom telemetry SDKs are not used.

## Required app settings

- `INVENTORY_TENANT_ID`
- `INVENTORY_CLIENT_ID`
- `INVENTORY_CLIENT_SECRET`
- `INVENTORY_TARGET_DATAVERSE_URL`
- `INVENTORY_AGENT_CREATED_IN` (the tenant's Agent Builder `createdIn` value)
- `INVENTORY_AGENT_SCHEDULE` (NCRONTAB, default `0 0 0 * * *`)
- `INVENTORY_AGENT_SUBSCRIPTIONS` (optional comma-separated Resource Graph scope; empty means all accessible subscriptions)
- `INVENTORY_SYNC_RUN_TABLE` (optional Sync Run entity-set name, default `invs_syncruns`)
- `INVENTORY_SYNC_LOG_TABLE` (optional Sync Log entity-set name, default `invs_synclogs`)
- `INVENTORY_MAX_CREATES_PER_RUN` (non-negative integer, default `1000`; overflow is skipped and logged)
- `APPLICATIONINSIGHTS_CONNECTION_STRING`
- `FUNCTIONS_WORKER_RUNTIME=powershell`
- `FUNCTIONS_WORKER_RUNTIME_VERSION=7.6`
- `FUNCTIONS_EXTENSION_VERSION=~4`

The Agent sync timer starts the fixed `agent-builder-inventory-sync` orchestration instance. Use
the timer function's **Test/Run** action for a manual run; an active instance causes the request
to be skipped with a structured `RunSkipped` warning.

Each Agent run reads the existing type-5 component rows once, then creates missing rows, patches
only changed technical fields, and sends no write for unchanged rows. Governance fields are set
when a component is created, restored, or confirmed deleted. After a complete collect/write phase,
active rows outside the collected key set are rechecked individually in Resource Graph without the
`createdIn` filter. Confirmed-missing rows are marked `Geloescht`/`Inaktiv`; a failed or incomplete
recheck marks nothing. Deleted rows that reappear are restored to `Neu`/`Aktiv`. Rows are never
physically deleted.

The separate unmanaged logging solution is in `solutions\InventorySyncLogging`.
Until it is imported, or whenever a logging write fails, sync processing continues
and emits the same correlation ID and structured problem details to Application Insights.

## Tests

```powershell
Invoke-Pester -Path .\tests -Output Detailed -CI
```

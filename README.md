# Inventory sync

PowerShell 7.6 Azure Functions project for synchronizing Power Platform inventory.

## Documentation

See the [customer operations guide](docs/operations-guide.md) for prerequisites,
least-privilege access, every app setting, Key Vault setup, logging-solution import,
deployment, smoke runs, Application Insights checks, and resolution of the spec TBDs.

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
- `INVENTORY_AGENT_CREATED_IN` (required only by Agent entry points; the tenant's
  Agent Builder `createdIn` value)
- `INVENTORY_AGENT_SCHEDULE` (required by the timer binding; the deployment template
  supplies the daily NCRONTAB value `0 0 0 * * *`)
- `INVENTORY_RPA_SCHEDULE` (required by the timer binding; the deployment template
  supplies the daily NCRONTAB value `0 0 0 * * *`)
- `INVENTORY_RPA_ENVIRONMENT_URL_COLUMN` (optional Environment-table URL column, default `palp_dataverseurl`)
- `INVENTORY_RPA_EXCLUDED_SKUS` (optional comma-separated list, default `Standard,Teams`)
- `INVENTORY_RPA_MAX_PARALLEL_ENVIRONMENTS` (positive integer, default `10`)
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

The independent RPA timer starts the fixed `rpa-inventory-sync` orchestration instance. It reads
`palp_environment` without modifying it, scans eligible environments with bounded parallelism,
and reconciles desktop flows only (`palp_typ = 4`). Environments that remain unreachable after
transport retries are logged and make the run `Partial` without stopping the other scans. Its
deletion check considers only environments read successfully in that run, reads source workflow
IDs once per candidate environment, compares their deterministic target keys, and restores
previously deleted flows that reappear.

Each Agent run reads the existing type-5 component rows once, then creates missing rows, patches
only changed technical fields, and sends no write for unchanged rows. Governance fields are set
when a component is created, restored, or confirmed deleted. After a complete collect/write phase,
active rows outside the collected key set are rechecked by candidate environment and configured
`createdIn` type in a tenant-wide Resource Graph query. Source agent IDs are converted to the same
deterministic target keys before comparison, so a synthetic `palp_id` is never queried as a source
ID. Confirmed-missing rows are marked `Geloescht`/`Inaktiv`; a failed or incomplete recheck marks
nothing. Deleted rows that reappear are restored to `Neu`/`Aktiv`. Rows are never physically
deleted.

Sync Log correlation uses the current `System.Diagnostics.Activity` trace ID, which is
the Application Insights operation ID for the executing timer/activity. The Durable
orchestrator only propagates its input to remain replay-safe. If no Activity exists
(for example, a direct local call), a propagated ID is retained; if neither exists, a
new GUID is used.

The separate unmanaged logging solution is in `solutions\InventorySyncLogging`.
Until it is imported, or whenever a logging write fails, sync processing continues
and emits the same correlation ID and structured problem details to Application Insights.

## Tests

```powershell
Invoke-Pester -Path .\tests -Output Detailed -CI
```

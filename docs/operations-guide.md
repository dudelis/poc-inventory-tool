# Inventory sync operations guide

This guide covers the manual customer setup, deployment, and verification of the two
inventory syncs:

- `AgentSyncTimer` inventories Agent Builder agents as component type `5`.
- `RpaSyncTimer` inventories desktop flows as component type `4`.

Both timers start singleton Durable orchestrations. They use one Entra service principal
for Azure Resource Graph and Dataverse, and the Function App's managed identity only to
resolve the service-principal secret from Key Vault.

## 1. Prerequisites

Provision the following before deploying the code:

1. An Azure Function App on **Flex Consumption**, Functions runtime `~4`, with the
   **PowerShell 7.6** runtime stack, a host storage account, and Application Insights.
   Enable its system-assigned managed identity.
2. A Key Vault secret containing the service-principal client secret. On the vault,
   grant the Function App's managed identity the Azure RBAC role
   **Key Vault Secrets User**. Do not grant this role to the service principal and do
   not put the secret value directly in an Azure app setting.
3. An Entra app registration/service principal with a valid client secret.
4. Azure Resource Graph access for that service principal. Assign the read-only
   Microsoft Entra directory role **Global Reader** to the service principal at tenant
   scope. `PowerPlatformResources` authorization is tenant-wide and does not use the
   normal subscription-level Azure RBAC `Reader` role. No delegated API permission is
   used by the implementation. A Privileged Role Administrator or Global Administrator
   must make this assignment; allow several minutes for propagation before testing.
5. An application user for the service principal in the target Dataverse environment
   and in every source environment that the RPA sync can scan. Assign a custom security
   role with the minimum table privileges below. Privilege depth must cover every row
   in scope; in the target, existing component rows may have different owners, so
   organization-level Read/Write is normally required.

| Environment | Table | Minimum application-user privileges used by the code |
|---|---|---|
| Target | Environment (`palp_environment`) | Read and Append To |
| Target | Komponente (`palp_komponente`) | Create, Read, Write, and Append |
| Target | Sync Run (`invs_syncrun`) | Create, Read, Write, and Append To |
| Target | Sync Log (`invs_synclog`) | Create, Read, Write, and Append |
| Every RPA source | Process (`workflow`) | Read |
| Every RPA source | User (`systemuser`) | Read |
| Every RPA source | Team (`team`) | Read |

The Environment/Komponente Append privileges permit the environment lookup on a
component. The Sync Run/Sync Log Append privileges permit the Sync Log-to-Sync Run
lookup. The sync never writes Environment, User, Team, or Process rows and never
deletes Dataverse rows.

Before the first run, confirm that:

- `palp_environment.palp_id` contains each source environment ID and its configured URL
  column contains that environment's Dataverse URL.
- The alternate key on `palp_komponente.palp_id` and the alternate key on
  `palp_environment.palp_id` exist.
- Network restrictions allow the Function App to reach Entra token endpoints,
  `management.azure.com`, the target Dataverse URL, and every included source
  Dataverse URL.

## 2. Import the logging solution

The logging solution is separate from PALP and must be imported into the **target**
Dataverse environment before a smoke run.

From the repository root, use Power Platform CLI to pack the unmanaged source:

```powershell
pac solution pack --zipfile .\InventorySyncLogging.zip `
  --folder .\solutions\InventorySyncLogging --packagetype Unmanaged
```

Import `InventorySyncLogging.zip` in Power Apps under **Solutions > Import solution**,
or with an authenticated Power Platform CLI:

```powershell
pac auth create --environment https://contoso.crm.dynamics.com
pac solution import --path .\InventorySyncLogging.zip
```

Verify that **Sync Run** and **Sync Log** exist and that their entity-set names are
`invs_syncruns` and `invs_synclogs`. If a customer customization changes the entity-set
names, put the actual plural entity-set names—not display names or logical table
names—in `INVENTORY_SYNC_RUN_TABLE` and `INVENTORY_SYNC_LOG_TABLE`.

Create or update the application-user security role with the logging-table privileges
listed above. Operators who inspect smoke results also need Read access to both tables.
If the solution or permissions are missing, inventory processing continues, but
Dataverse logging fails and the failure is written to Application Insights.

## 3. Configure the Function App

Add these values under **Function App > Settings > Environment variables > App
settings**. Examples are illustrative.

| Setting | Required | Purpose and implemented behavior | Example |
|---|---|---|---|
| `AzureWebJobsStorage` | Yes | Host storage used by Azure Functions and Durable Functions. Use the storage connection configured for the Function App; `UseDevelopmentStorage=true` is local-only. | Azure-managed storage connection value |
| `FUNCTIONS_EXTENSION_VERSION` | Yes | Selects Functions runtime v4. | `~4` |
| `FUNCTIONS_WORKER_RUNTIME` | Yes | Selects the PowerShell worker. | `powershell` |
| `FUNCTIONS_WORKER_RUNTIME_VERSION` | Yes | Pins the worker to the implemented and supported runtime. | `7.6` |
| `APPLICATIONINSIGHTS_CONNECTION_STRING` | Yes | Sends host telemetry and the structured records emitted by the sync to Application Insights. The configuration loader also requires a nonblank value. Instrumentation-key-only settings are not used. | `InstrumentationKey=00000000-0000-0000-0000-000000000000;IngestionEndpoint=https://westeurope-5.in.applicationinsights.azure.com/` |
| `INVENTORY_TENANT_ID` | Yes | Entra tenant used for all client-credential token requests. | `11111111-1111-1111-1111-111111111111` |
| `INVENTORY_CLIENT_ID` | Yes | Client ID of the service principal registered as a Dataverse application user. | `22222222-2222-2222-2222-222222222222` |
| `INVENTORY_CLIENT_SECRET` | Yes | Key Vault reference that Functions resolves to the client secret. Keep the trailing `/` to follow the versionless reference form shown. | `@Microsoft.KeyVault(SecretUri=https://contoso-kv.vault.azure.net/secrets/inventory-sync-client-secret/)` |
| `INVENTORY_TARGET_DATAVERSE_URL` | Yes | Base URL of the target PALP environment. A trailing slash is accepted and removed. | `https://contoso.crm.dynamics.com` |
| `INVENTORY_AGENT_CREATED_IN` | Agent only | Exact, case-sensitive `properties.createdIn` value used by the tenant-wide Resource Graph Kusto `==` filter. It is not loaded or required by the RPA entry points. Confirm it from real tenant data before enabling the schedule. | `Microsoft 365 Copilot Agent Builder` |
| `INVENTORY_AGENT_SCHEDULE` | Yes | Six-field NCRONTAB expression used directly by `AgentSyncTimer`. The trigger binding requires it before function code can run. The deployment settings template contains the real daily value; change that app setting to override it. Schedules are UTC unless the Function App platform is configured otherwise. | `0 0 0 * * *` |
| `INVENTORY_RPA_SCHEDULE` | Yes | Six-field NCRONTAB expression used directly by `RpaSyncTimer`. The deployment settings template contains the real daily value and the app setting remains configurable. | `0 0 0 * * *` |
| `INVENTORY_RPA_ENVIRONMENT_URL_COLUMN` | No | Logical column name read from `palp_environment` for the source Dataverse base URL. Only a Dataverse-style alphanumeric/underscore logical name is accepted. | `palp_dataverseurl` (default) |
| `INVENTORY_RPA_EXCLUDED_SKUS` | No | Case-insensitive comma-separated `palp_sku` values skipped by the RPA environment plan. Blank or absent restores the defaults; it does not mean “exclude none.” Skips are logged. | `Standard,Teams` (default) |
| `INVENTORY_RPA_MAX_PARALLEL_ENVIRONMENTS` | No | Maximum concurrent RPA environment reads. Must be a positive integer. | `10` (default) |
| `INVENTORY_SYNC_RUN_TABLE` | No | Sync Run Dataverse entity-set name. Blank or absent uses the shipped solution name. | `invs_syncruns` (default) |
| `INVENTORY_SYNC_LOG_TABLE` | No | Sync Log Dataverse entity-set name. Blank or absent uses the shipped solution name. | `invs_synclogs` (default) |
| `INVENTORY_MAX_CREATES_PER_RUN` | No | Shared per-run creation cap for either sync. Excess new components are skipped and logged and can make the run `Partial`; the cap does not limit update or restore operations. Resulting skips can prevent a deletion check where the sync's completeness guard applies. Must be a non-negative integer; `0` disables creates. | `1000` (default) |

The Key Vault reference must resolve successfully in the app-setting UI. A versionless
URI follows the latest secret version; use
`SecretUri=https://<vault>.vault.azure.net/secrets/<name>/<version>` if change control
requires a pinned version. Restart the Function App after changing settings.

### Actual code and host settings

These settings are committed with the implementation and are not additional Azure app
settings:

| File | Setting | Implemented value and purpose |
|---|---|---|
| `src/requirements.psd1` | `AzureFunctions.PowerShell.Durable.SDK` | `2.*`; managed PowerShell dependency that provides the Durable cmdlets used by both timers and orchestrators. Do not add a similarly named app setting. |
| `src/host.json` | `extensionBundle.version` | `[4.*, 5.0.0)`; supplies the v4 bindings, including Durable and timer bindings. |
| `src/host.json` | `managedDependency.enabled` | `true`; permits Functions to restore `requirements.psd1`. |
| `src/host.json` | Application Insights sampling | Enabled, with `Request` excluded from sampling and live-metrics filters enabled. |
| `src/host.json` | Log levels | `Information` for default, `Host.Results`, and `Function`. |

There is no custom Application Insights SDK. `Write-InventoryTrace` writes compact JSON
with `timestamp`, `level`, `message`, `correlationId`, and `data`; normal Functions
telemetry transports it. Timer and activity entry points capture the current
`System.Diagnostics.Activity` trace ID. The activity that performs the sync therefore
writes the same correlation ID as its Application Insights operation. The Durable
orchestrator propagates its input unchanged so replay remains deterministic. Outside an
Activity, a propagated ID is retained; only a direct call with neither uses a new GUID.

## 4. Deploy the code

Install Azure Functions Core Tools v4, Azure CLI, PowerShell, and Power Platform CLI
(`pac`) on the deployment workstation. Authenticate to the subscription containing the
Function App, then publish the contents of `src`:

```powershell
az login
az account set --subscription 33333333-3333-3333-3333-333333333333
Set-Location .\src
func azure functionapp publish contoso-inventory-sync
```

Core Tools uses the deployment mechanism supported by the Flex Consumption app. Do not
publish the repository root: `host.json`, `requirements.psd1`, `profile.ps1`, the
function folders, and `Modules` must be at the deployment package root.

After deployment:

1. Restart the Function App.
2. Confirm the portal lists `AgentSyncTimer`, `AgentSyncOrchestrator`,
   `AgentSyncCreateActivity`, `RpaSyncTimer`, `RpaSyncOrchestrator`, and
   `RpaSyncActivity`.
3. Check **Diagnose and solve problems** or the log stream for host indexing or managed
   dependency errors before running either sync.

## 5. Manual smoke run

Use a test Dataverse environment and a small, known data set for the first run. Inventory
changes in Resource Graph can lag by about 15 minutes. Do not start a second copy of the
same sync while its fixed orchestration instance is active.

### Agent Builder sync

1. In the Function App, open **Functions > AgentSyncTimer > Code + Test**.
2. Select **Test/Run**, then **Run**. This invokes the timer function; there is no HTTP
   starter.
3. In Durable/Function monitoring, verify that `AgentSyncOrchestrator` and then
   `AgentSyncCreateActivity` ran for the fixed instance ID
   `agent-builder-inventory-sync`.
4. In target Dataverse, find the new **Sync Run** row:
   - Sync Type is `AgentBuilder`.
   - Run ID is the activity trace/operation ID (or the documented local fallback).
   - Status finishes as `Succeeded` and Phase normally finishes as
     `DeletionCheck`.
   - Completed On is populated and Found/Created/Updated/Unchanged/Marked
     Deleted/Restored counts match the test data.
5. Check `palp_komponente` type `5`. New rows have Neu/Aktiv/Undefiniert defaults;
   existing unchanged rows receive no write.
6. Inspect related **Sync Log** rows. A clean run can have **zero** detail rows.
   Warnings/errors/restores produce correlated details. Missing target environment
   mappings, a creation-cap skip, write failure, or verification failure makes the run
   `Partial`. A fatal collection failure makes it `Failed`.

### RPA sync

1. Open **Functions > RpaSyncTimer > Code + Test**, select **Test/Run**, and select
   **Run**.
2. Verify that `RpaSyncOrchestrator` and then `RpaSyncActivity` ran for fixed instance
   ID `rpa-inventory-sync`.
3. Verify the new **Sync Run** row has Sync Type `RPA`, the activity operation ID, Completed
   On, final Phase `DeletionCheck`, expected counts, and `Succeeded` for an error-free
   run.
4. Check `palp_komponente` type `4` for the expected desktop flows in each included
   environment.
5. Inspect related **Sync Log** rows. Expected configured SKU exclusions and missing
   URLs are `Skipped` warnings; a clean run with no skip/restore/problem may have no
   detail rows. An unreachable or unauthorized source environment is logged and makes
   the run `Partial`, while other environments continue. Deletion checks only consider
   environments successfully read in that run.

For either timer, a second Test/Run while the singleton is `Pending`, `Running`,
`ContinuedAsNew`, or `Suspended` does not start another orchestration. It creates a
`Partial` Sync Run and a `RunSkipped` Sync Log warning when Dataverse logging is
available, and always emits the warning to Application Insights.

### Application Insights verification

Wait several minutes for telemetry ingestion, then run this query in the linked
Application Insights **Logs** blade:

```kusto
traces
| where timestamp > ago(30m)
| extend inventory = parse_json(message)
| where isnotempty(tostring(inventory.correlationId))
| project timestamp,
          level=tostring(inventory.level),
          detail=tostring(inventory.message),
          correlationId=tostring(inventory.correlationId),
          data=inventory.data
| order by timestamp asc
```

For a successful run, expect `Agent sync completed with status Succeeded.` or
`RPA sync completed with status Succeeded.` with the same correlation ID as the Sync
Run and a `data.counts` object. Problem details are emitted with the same correlation
ID even when a Sync Run or Sync Log Dataverse write fails. Also check the Functions
request/dependency telemetry for the timer, orchestrator, and activity invocation. If
the query has no result, confirm the connection string, host log level, Application
Insights resource, and telemetry ingestion delay.

## 6. Spec TBD resolution register

No TBD is left without an operational decision. Record customer-approved values in the
deployment record.

| Spec TBD | Resolution setting or action |
|---|---|
| 1. Legacy `palp_komponente` data and `palp_id` behavior | Export representative rows before the first run and confirm no collision with the implemented deterministic name-based GUID derived from environment ID, component type, and source ID. There is no app setting for this algorithm; stop deployment and change the isolated ID function if customer data disproves the assumption. |
| 2. Representative `palp_environment` data | Validate Default, Teams, developer, deleted/disabled, and normal rows in the target table. Resolve inclusion through `INVENTORY_RPA_EXCLUDED_SKUS`; removed/inactive rows and rows without a URL are skipped by implementation. |
| 3. Plug-ins, flows, business rules, workflows, and notifications on `palp_komponente` | Inventory and test automations in the target environment, begin with a conservative `INVENTORY_MAX_CREATES_PER_RUN`, inspect Sync Run counts, then raise the cap after approval. |
| 4. Dataverse URL column | Set `INVENTORY_RPA_ENVIRONMENT_URL_COLUMN` to the confirmed logical column name and populate it with each source environment URL. |
| 5. Meaning of `Standard` and developer-environment policy | Confirm actual `palp_sku` values with the customer and set the complete comma-separated `INVENTORY_RPA_EXCLUDED_SKUS` list. The implemented default is `Standard,Teams`. |
| 6. Actual Agent Builder `createdIn` value | Query representative Resource Graph data, copy the exact case-sensitive value into `INVENTORY_AGENT_CREATED_IN`, and verify Found count in the agent smoke run. |
| 7. Tenant/client/secret/vault/target values | The project lead supplies and the operator configures `INVENTORY_TENANT_ID`, `INVENTORY_CLIENT_ID`, the Key Vault secret and `INVENTORY_CLIENT_SECRET` reference, and `INVENTORY_TARGET_DATAVERSE_URL`. Validate Key Vault reference resolution before deployment. |
| 8. Resource Graph access role | Assign the read-only Microsoft Entra directory role `Global Reader` to the service principal at tenant scope. This is the least-privilege directory role confirmed for app-only `PowerPlatformResources` queries; subscription-level Azure RBAC `Reader` is not the resolving role. Agent collection is always tenant-wide and has no subscription-scope setting. |

# Prerequisites

Everything that must exist before the inventory sync Function App is deployed and
configured. Work through it top to bottom; the [operations guide](operations-guide.md)
covers deployment, app-setting details, and the smoke run that come afterwards.

For a new installation, the [portable deployment package](../deploy/README.md)
can provision a dedicated Azure foundation after an interactive tenant/subscription
login. It does not yet create the runtime identity or Function App. Its deterministic
names and ownership tags are separate from the existing manual setup below; do not
use the screenshot-specific storage/vault names for an automated installation.

## Overview

| Section | What | Where | Who can do it |
|---|---|---|---|
| [1](#1-app-registration-service-principal) | App registration and client secret | Microsoft Entra ID | Application Administrator (or app owner) |
| [2](#2-directory-role-for-azure-resource-graph) | Global Reader role for the service principal | Microsoft Entra ID | Privileged Role Administrator or Global Administrator |
| [3](#3-azure-resources) | Resource group, storage, Application Insights, Key Vault, Function App | Azure subscription | Contributor on the resource group |
| [3](#azure-role-assignments-at-a-glance) | Role assignments for the Function App's managed identity | Azure subscription | Owner, User Access Administrator, or Role Based Access Control Administrator |
| [4](#4-deployment-workstation) | Tools on the deployment workstation | Deployer's machine | Deployer |
| [5](#5-target-dataverse-environment-palp) | Application user, security role, logging solution in the target environment | Power Platform admin center | Power Platform Administrator or System Administrator of the environment |
| [6](#6-source-dataverse-environments-rpa-sync-only) | Application user in every source environment (RPA) | Power Platform admin center | Power Platform Administrator or System Administrator of each environment |
| [7](#7-network) | Network access | Customer network / firewall | Network team (only if outbound traffic is restricted) |
| [8](#8-values-to-hand-over) | Values to hand over | — | Project lead |
| [9](#9-verify-before-deployment) | Resource Graph access check | Any PowerShell 7 session | Anyone holding the client secret |

## Resource names and current setup

Use the names below throughout this checklist. Your screenshot shows that
`keypalp` and `palpstorage` already exist in **North Europe**; reuse them rather than
creating duplicates. Their configuration and permissions still need to be checked.
The other names are proposed names, not confirmation that those resources exist.

| Resource | Name to use | Create or reuse |
|---|---|---|
| Azure resource group | `rg-palp-inventory-sync` | Proposed; reuse the existing resource group containing `keypalp` and `palpstorage` if suitable, and record its actual name |
| Region | **North Europe** (`northeurope`) | Matches both existing resources; use it for the new Azure resources |
| Entra app registration | `palp-inventory-sync` | Create unless already registered |
| Enterprise application / service principal | `palp-inventory-sync` | Created with the app registration; do not create a second application |
| Entra client secret description | `palp-inventory-sync-keyvault` | Create under the app registration; this is a description, not the secret value |
| Storage account | `palpstorage` | Already shown in the screenshot; check suitability in 3.2 |
| Deployment blob container | `inventory-sync-deploy` | Proposed if the creation workflow lets you choose it; otherwise record the generated container name |
| Log Analytics workspace | `log-palp-inventory-sync` | Create unless a suitable workspace already exists |
| Application Insights | `appi-palp-inventory-sync` | Create and link to the workspace above |
| Key Vault | `keypalp` | Already shown in the screenshot; check settings in 3.4 |
| Key Vault secret | `inventory-sync-client-secret` | Create inside `keypalp`; it is not a separate vault |
| Function App | `func-palp-inventory-sync` | Create; if unavailable, append a short unique suffix and use that name everywhere |
| Flex Consumption hosting plan | `asp-palp-inventory-sync` | Proposed if the portal lets you name it; otherwise record the generated plan name |
| Function App managed identity | Same name as the Function App | Enable the system-assigned identity; do not create a separate app registration or user-assigned identity |
| Target Dataverse application user | Select `palp-inventory-sync` | Create in the existing PALP environment; the user is tied to the app's client ID |
| Target Dataverse security role | `PALP Inventory Sync` | Create with the privileges in 5.2 |
| Logging solution | **Inventory Sync Logging** (package `InventorySyncLogging.zip`) | Import the supplied solution into the target environment |
| Source Dataverse application user | Select `palp-inventory-sync` in each source | Create in each existing RPA source environment; use the same client ID |
| Source Dataverse security role | `PALP Inventory RPA Reader` | Create in each RPA source environment with the privileges in section 6 |

The PALP target and RPA source environments are existing customer environments;
record their actual names, environment IDs, and URLs rather than creating new ones
for this setup. Use a non-production PALP copy for the first run.

Azure Function App names must be globally available. The existing storage account
and vault already have their names reserved; do not rename or replace them just to
match a naming convention. If you reuse a resource group or workspace, substitute
its actual name in the steps below.

## 1. App registration (service principal)

One service principal is used for Azure Resource Graph, the target Dataverse
environment, and every source Dataverse environment. It authenticates with the
client-credentials flow; no user account is involved.

1. **Microsoft Entra ID > App registrations > New registration**
   - Name: `palp-inventory-sync`
   - Supported account types: **single tenant**
   - Redirect URI: leave empty
2. Note the **Application (client) ID** and **Directory (tenant) ID**.
3. **Certificates & secrets > New client secret.** Use description
   `palp-inventory-sync-keyvault` and an expiry permitted by the customer's policy.
   Copy the secret **Value**, not its Secret ID, once; it is
   stored only in Key Vault (step 3.4). Record the expiry date and plan rotation
   before it expires; an expired secret stops both syncs.
4. **API permissions:** none are required. Leave the default `User.Read` or remove it.
   Access comes from the directory role (step 2), Dataverse application users
   (steps 5 and 6), and nothing else.

## 2. Directory role for Azure Resource Graph

The Agent sync (and any environment lookup through Resource Graph) queries the
`PowerPlatformResources` table. Azure RBAC roles such as **Reader** do **not** grant
access to this table; it requires a Microsoft Entra directory role
([Power Platform inventory access requirements](https://learn.microsoft.com/power-platform/admin/power-platform-inventory#access-requirements)).

Assign **Global Reader** to the service principal at tenant scope.

- **Portal:** Microsoft Entra ID > Roles and administrators > **Global Reader** >
  Add assignments > select the enterprise application `palp-inventory-sync`.
- **Microsoft Graph PowerShell:**

  ```powershell
  Connect-MgGraph -Scopes 'RoleManagement.ReadWrite.Directory'
  $sp   = Get-MgServicePrincipal -Filter "appId eq '<client-id>'"
  $role = Get-MgRoleManagementDirectoryRoleDefinition -Filter "displayName eq 'Global Reader'"
  New-MgRoleManagementDirectoryRoleAssignment -PrincipalId $sp.Id `
      -RoleDefinitionId $role.Id -DirectoryScopeId '/'
  ```

Allow 5–10 minutes for the assignment to take effect.

Notes for the security review:

- Microsoft documents these roles for signed-in users; app-only access with Global
  Reader is not documented as a supported pattern, but has been confirmed working in
  a test tenant (service principal + Global Reader + client-credentials token).
  Verify it in the customer tenant before go-live (see section 9, probe query).
- Global Reader is read-only but tenant-wide across Microsoft 365. **AI Reader** is a
  narrower alternative that, per Microsoft, can see agents, environments, and
  environment groups — everything the syncs read from Resource Graph. It has not yet
  been tested with a service principal; if the customer prefers it, test it first and
  fall back to Global Reader.
- The Power Platform inventory API and the Power Platform admin API
  (`api.bap.microsoft.com`) are not used: the former rejects service principals, and
  the latter does not honor directory roles for service principals.

## 3. Azure resources

Prefer one resource group and one region. For your current setup, use **North Europe**
to match `keypalp` and `palpstorage`, subject to the customer's region requirements.
Before creating anything, open each existing resource's **Overview** and note its
subscription, resource group, and location. Use the same subscription for the new
resources.

### 3.1 Resource group

- **Name:** `rg-palp-inventory-sync` (proposed; use the existing group's actual name if reusing it).
- **Region:** North Europe.

In **Resource groups**, reuse the group containing `keypalp` and `palpstorage` if it
is suitable for this workload. Otherwise create `rg-palp-inventory-sync` in
**North Europe**. Do not move existing resources solely for this checklist; if they
remain in another group, use their actual resource IDs for role-assignment scopes.
Record the selected subscription ID and resource group name.

### 3.2 Storage account

- **Storage account name:** `palpstorage`.
- **Region:** North Europe.
- **Status:** Already created (shown in your screenshot); reuse it.
- **Deployment container name:** `inventory-sync-deploy` (proposed; keep the generated name if the portal creates one).

In the Azure portal, open **Storage accounts > palpstorage** and check the settings
below. Do not create another storage account unless this one cannot meet the
Function App's requirements.

Host storage for Azure Functions, Durable Functions state (queues, tables, blobs),
and the Flex Consumption deployment package.

- In **Overview / Configuration**, confirm it is a **StorageV2** (general-purpose v2)
  account with blob, queue, and table services. Standard LRS is sufficient.
- Check that its network rules allow the Function App to reach those services.
- When creating the Function App, select `palpstorage` for host storage and, where
  separately requested, deployment storage. Use deployment container
  `inventory-sync-deploy` if selectable; otherwise keep and record the generated
  container. Let the Function App creation workflow configure the deployment
  storage connection.
- If this is a shared account, confirm with its owner that Functions host data,
  Durable state, and deployment packages may be stored there. Do not change shared
  firewall or authentication settings without checking their impact.
- If the Function App connects to it with its managed identity (the portal default for
  new Flex Consumption apps), the managed identity needs these roles on the storage
  account because Durable Functions uses all three services:
  - **Storage Blob Data Owner**
  - **Storage Queue Data Contributor**
  - **Storage Table Data Contributor**

### 3.3 Application Insights

- **Application Insights name:** `appi-palp-inventory-sync`.
- **Log Analytics workspace name:** `log-palp-inventory-sync`.
- **Region:** North Europe.
- **Status:** Proposed new resources; reuse a suitable existing workspace if available.

- Create a **Log Analytics workspace** named `log-palp-inventory-sync` in the
  selected resource group and **North Europe**, or select a suitable existing
  workspace.
- Create workspace-based **Application Insights** named
  `appi-palp-inventory-sync` in the same region and link it to that workspace.
  You can also create it during Function App creation; explicitly select the
  workspace and check the resulting resource names.
- Its **connection string** becomes `APPLICATIONINSIGHTS_CONNECTION_STRING`. The portal
  sets it automatically when Application Insights is enabled during Function App
  creation.

### 3.4 Key Vault

- **Key Vault name:** `keypalp`.
- **Region:** North Europe.
- **Status:** Already created (shown in your screenshot); reuse it.
- **Secret name:** `inventory-sync-client-secret`.

In the Azure portal, open **Key vaults > keypalp** and check the settings below.

- In **Access configuration**, check the permission model is **Azure role-based
  access control**. If this existing vault uses access policies, agree any change
  with its owner first; switching models can affect other users of the vault.
- Under **Secrets > Generate/Import**, create `inventory-sync-client-secret`
  containing the client secret **Value** from step 1.3. Set its expiry date to
  match the client secret.
- The person creating the secret needs secret-write permissions, for example
  **Key Vault Secrets Officer** on `keypalp`; resource-group Contributor alone does
  not grant secret data access.
- Record the versionless secret URI:
  `https://keypalp.vault.azure.net/secrets/inventory-sync-client-secret/`.
- Role assignment: the Function App's **system-assigned managed identity** gets
  **Key Vault Secrets User** on the vault (read-only access to secret values).
  Assign it after the Function App exists (3.5):

  ```powershell
  az role assignment create `
    --assignee-object-id <function-app-principal-id> `
    --assignee-principal-type ServicePrincipal `
    --role 'Key Vault Secrets User' `
    --scope <key-vault-resource-id>
  ```

- Do **not** give the service principal from step 1 any Key Vault access; it never
  reads the vault.
- If the vault's firewall is enabled, the Function App needs VNet integration and the
  vault needs a matching network rule or private endpoint; otherwise the Key Vault
  reference cannot resolve.

### 3.5 Function App

- **Function App name:** `func-palp-inventory-sync`.
- **Hosting plan name:** `asp-palp-inventory-sync` (if editable; otherwise keep the generated name).
- **Region:** North Europe.
- **Status:** Proposed new resources; append a unique suffix to the Function App name if unavailable.

| Setting | Value |
|---|---|
| Function App name | `func-palp-inventory-sync` (or the agreed unique-suffixed name) |
| Subscription / resource group | The subscription and group selected in 3.1 |
| Region | **North Europe** |
| Hosting plan | **Flex Consumption** |
| Hosting plan name | `asp-palp-inventory-sync` if editable; otherwise record the generated name |
| Runtime stack | **PowerShell 7.6** (Functions runtime `~4`) |
| Operating system | Linux (implied by Flex Consumption) |
| Host and deployment storage | `palpstorage` from 3.2 |
| Deployment container | `inventory-sync-deploy` if selectable; otherwise the generated container from 3.2 |
| Application Insights | `appi-palp-inventory-sync` from 3.3 |
| Identity | **System-assigned managed identity: On** |
| Instance memory | Default (2,048 MB) is sufficient |

After creating it:

1. Open **Identity > System assigned**, confirm **Status: On**, and copy the
   **Object (principal) ID**. This is not the client ID from step 1.
2. On **`keypalp` > Access control (IAM) > Add role assignment**, assign
   **Key Vault Secrets User** to **Managed identity > Function App >
   `func-palp-inventory-sync`** (or its actual name).
3. If host storage uses managed identity, assign the storage roles from 3.2 on
   **`palpstorage` > Access control (IAM)** to the same Function App identity.
   Check existing assignments first; the creation workflow may already have
   assigned some of them.
4. Leave the app settings for the [operations guide](operations-guide.md#3-configure-the-function-app);
   the secret setting must look like
   `@Microsoft.KeyVault(SecretUri=https://keypalp.vault.azure.net/secrets/inventory-sync-client-secret/)`
   and must show a green **Key Vault Reference** status in the portal.

### Azure role assignments at a glance

| Principal | Role | Scope |
|---|---|---|
| Function App managed identity | Key Vault Secrets User | Key Vault |
| Function App managed identity | Storage Blob Data Owner, Storage Queue Data Contributor, Storage Table Data Contributor | Storage account (only with identity-based host storage) |
| Sync service principal | *(none)* | — |

## 4. Deployment workstation

The person deploying needs:

- PowerShell 7.6
- Azure CLI, signed in to the subscription (`az login`)
- Azure Functions Core Tools v4 (`func azure functionapp publish`)
- Power Platform CLI (`pac`) to pack and import the logging solution
- Read access to this repository

## 5. Target Dataverse environment (PALP)

The environment that contains `palp_komponente`, `palp_environment`, and later the
logging tables.

### 5.1 Application user

Power Platform admin center > **Environments** > *target* > **Settings** >
**Users + permissions** > **Application users** > **New app user**: select the app
registration from step 1, the root business unit, and the security role from 5.2.
Select **`palp-inventory-sync`** by its client ID; do not select the Function App's
managed identity. If the role does not exist yet, create it using 5.2 first.

### 5.2 Security role

Create a custom role named **`PALP Inventory Sync`** with **Organization** depth for
every privilege below. Existing component rows have various owners, so lower depths
cause silent gaps or failed updates.

| Table | Create | Read | Write | Append | Append To |
|---|---|---|---|---|---|
| Environment (`palp_environment`) | | ✔ | | | ✔ |
| Komponente (`palp_komponente`) | ✔ | ✔ | ✔ | ✔ | |
| Sync Run (`invs_syncrun`) | ✔ | ✔ | ✔ | | ✔ |
| Sync Log (`invs_synclog`) | ✔ | ✔ | ✔ | ✔ | |

No Delete privilege is needed anywhere; the syncs never delete rows. The Sync Run and
Sync Log rows can only be added after the logging solution is imported (5.3).

### 5.3 Logging solution

Pack and import the separate unmanaged solution from
[`solutions/InventorySyncLogging`](../solutions/InventorySyncLogging/README.md):

```powershell
pac solution pack --zipfile .\InventorySyncLogging.zip `
  --folder .\solutions\InventorySyncLogging --packagetype Unmanaged
pac auth create --environment https://<target>.crm<N>.dynamics.com
pac solution import --path .\InventorySyncLogging.zip
```

Then add the Sync Run and Sync Log privileges to the role from 5.2. Without the
solution the syncs still run, but logging goes to Application Insights only.

### 5.4 Data and automation checks

- **Admin GUID (`palp_environment.palp_adminguid`)** must contain the full Power Platform environment ID in the
  same format that Resource Graph returns (for example `Default-<tenant-id>` for the
  default environment, a GUID for others). Matching is case-insensitive. Components
  are linked using the matched row's `palp_environmentid`; no alternate key on
  Admin GUID is required. Each Admin GUID must identify exactly one row. Missing
  mappings are skipped and logged; ambiguous mappings fail the run before component
  writes. Do not use the Environment table's 36-character `palp_id`: it cannot hold
  the 44-character Default environment ID.
- The **alternate key** on `palp_komponente.palp_id` must be active.
  It exists in PALP 2.21.0.1 (`palp_pk_id`). The sync does not use the
  Environment table's alternate key.
- **Automations on `palp_komponente`:** list every plug-in, cloud flow, business rule,
  and classic workflow that fires on create or update, especially notifications to
  owners. For the first run, set `INVENTORY_MAX_CREATES_PER_RUN` to a small value (for
  example `5`) and raise it after reviewing the result.
- **Test first:** run the first syncs against a non-production copy of the PALP
  environment.

## 6. Source Dataverse environments (RPA sync only)

The RPA sync reads desktop flows directly from each environment's Dataverse.

- Add the same app registration as an **application user** in every environment to
  be scanned (same steps as 5.1).
- Create and assign a custom role named **`PALP Inventory RPA Reader`** in each
  source environment with **Organization**-depth **Read** on:
  - Process (`workflow`) — desktop flows are workflows with category 6
  - User (`systemuser`) — to resolve the owner's Entra object ID
  - Team (`team`) — for team-owned flows
- Environments that are in **administration mode** or where the application user is
  missing are logged as failed, and the RPA run ends as `Partial`.

## 7. Network

Only relevant if the Function App's outbound traffic is restricted (VNet integration
with a firewall). Allow HTTPS (443) to:

| Endpoint | Used for |
|---|---|
| `login.microsoftonline.com` | Client-credentials tokens |
| `management.azure.com` | Azure Resource Graph |
| `*.crm*.dynamics.com` (the target and every source environment) | Dataverse Web API |
| `keypalp.vault.azure.net` | Key Vault reference resolution |
| Application Insights ingestion endpoint (from the connection string) | Telemetry |

## 8. Values to hand over

Collect these before configuring the Function App. Each maps to an app setting
described in the [operations guide](operations-guide.md#3-configure-the-function-app).

| Value | App setting | Source |
|---|---|---|
| Directory (tenant) ID | `INVENTORY_TENANT_ID` | Step 1.2 |
| Application (client) ID | `INVENTORY_CLIENT_ID` | Step 1.2 |
| `https://keypalp.vault.azure.net/secrets/inventory-sync-client-secret/` | `INVENTORY_CLIENT_SECRET` (as Key Vault reference) | Step 3.4 |
| Target Dataverse URL, for example `https://palp.crm4.dynamics.com` | `INVENTORY_TARGET_DATAVERSE_URL` | Power Platform admin center |
| Agent Builder `createdIn` value | `INVENTORY_AGENT_CREATED_IN` | Probe query (section 9) |
| Schedules (NCRONTAB, UTC), default daily `0 0 0 * * *` | `INVENTORY_AGENT_SCHEDULE`, `INVENTORY_RPA_SCHEDULE` | Customer decision |
| Excluded environment types | `INVENTORY_RPA_EXCLUDED_SKUS` | Customer decision (default: Default/Standard and Teams) |
| Creation cap for the first run | `INVENTORY_MAX_CREATES_PER_RUN` | Customer decision (start small) |
| Application Insights connection string | `APPLICATIONINSIGHTS_CONNECTION_STRING` | Step 3.3 |

Also hand over the **actual resource names and IDs**, including any deviations from
the naming table: subscription ID, resource group, Function App and hosting plan,
Function App identity's principal ID, storage account and deployment container,
Key Vault, Application Insights, and Log Analytics workspace. For each Dataverse
environment, include its display name, environment ID, URL, and assigned application
user/security role. These are deployment and support details, not additional app
settings.

Never send the client secret itself by e-mail or chat; it goes directly into Key Vault.

## 9. Verify before deployment

Once steps 1 and 2 are done, confirm Resource Graph access with a read-only query run
as the service principal. A `403` means the directory role is missing or has not
propagated yet; an empty result usually means propagation delay.

```powershell
$token = (Invoke-RestMethod -Method Post `
    -Uri "https://login.microsoftonline.com/<tenant-id>/oauth2/v2.0/token" `
    -Body @{
        client_id     = '<client-id>'
        client_secret = $env:INVENTORY_CLIENT_SECRET
        scope         = 'https://management.azure.com/.default'
        grant_type    = 'client_credentials'
    }).access_token

$body = @{
    query = @'
PowerPlatformResources
| where type in~ ("microsoft.copilotstudio/agents", "microsoft.powerplatform/environments")
| extend p = parse_json(properties)
| summarize count() by type, createdIn = tostring(p.createdIn), environmentType = tostring(p.environmentType)
'@
} | ConvertTo-Json

Invoke-RestMethod -Method Post `
    -Uri 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2022-10-01' `
    -Headers @{ Authorization = "Bearer $token" } `
    -ContentType 'application/json' -Body $body |
    Select-Object -ExpandProperty data
```

The result also shows the actual `createdIn` values for agents (needed for
`INVENTORY_AGENT_CREATED_IN`) and the actual `environmentType` values for environments
(needed to decide which environment types to exclude).

## 10. Known gaps in the current code

These must be resolved in the code before the first deployment; they are not customer
tasks, but they affect the setup above.

1. **RPA environment list.** The RPA sync reads `palp_environment` columns that do not
   exist in PALP 2.21.0.1 (`palp_sku`, the URL column `palp_dataverseurl`). The
   environment list and type filter are to move to Resource Graph
   (`microsoft.powerplatform/environments`, `properties.environmentType`). Resource
   Graph does not document a Dataverse URL for environments, so the source of each
   environment's URL is still open.
2. **Function timeout.** Each sync runs in a single Durable activity. Flex Consumption
   defaults to a 30-minute function timeout; large tenants may need `functionTimeout`
   raised in `host.json`.

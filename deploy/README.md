# Inventory deployment: planning and Azure foundation

The portable package supports offline planning (#11) and explicit Azure foundation
deployment (#12). `DeployFoundation` provisions a dedicated resource group, storage,
Key Vault, Log Analytics, and workspace-based Application Insights. It stops there:
it **does not sign in, create runtime credentials, deploy a Function App, publish
Functions, import solutions, assign runtime roles, or enable timers**. The remaining
bootstrap phases are delivered by subsequent tickets under #10.

[main.bicep](./main.bicep) declares the shared input contract and has no resources.
The bootstrap deploys [foundation-group.bicep](./foundation-group.bicep) at subscription
scope and [foundation.bicep](./foundation.bicep) incrementally at resource-group scope.

## Validate and inspect a plan

Run from the repository root in PowerShell 7.6 or later:

```powershell
$plan = .\deploy\Invoke-InventoryDeployment.ps1 `
    -ConfigurationPath .\deploy\example.parameters.json

$plan | Select-Object Status, CloudChangesMade, DeploymentImplemented
$plan.ResourceNames
$plan.Resources
$plan.ApplicationSettings
$plan.Prerequisites | Format-Table Name, Available, RequiredFor, Guidance
$plan.Phases | Format-Table Id, Status, SavedStatus, NeedsRevalidation
```

The example intentionally uses an all-zero subscription ID, a fictitious PALP
URL, and an Agent authoring-tool placeholder. Replace the subscription ID before
deploying the foundation and supply actual runtime values before deploying Functions.
No tenant-specific values, credentials, or Azure login are needed to validate it.

Plan mode requires Azure CLI and an already installed Bicep compiler. It runs
only `az version`, `az bicep version`, and `az bicep build --stdout --no-restore`.
Every local Bicep entry point and module in this directory is compiled. Templates
requiring un-restored external modules fail rather than downloading them.
No generated ARM JSON is written into the repository.

Install missing tools yourself using the reported guidance. The bootstrap never
installs tools. It discovers Functions Core Tools, Power Platform CLI, and Graph
modules as **deployment-only prerequisites**: absence does not prevent an offline
plan, and presence is not a deployment-time version or permission verification.
`PlanValidated` means only local input and compilation validation succeeded, not
that Azure quota, policy, names, region availability, permissions, identity
propagation, or Dataverse readiness have been checked.

## Deploy the Azure foundation

This mode makes live Azure changes and incurs Azure costs. It needs PowerShell 7.6,
Azure CLI, and Bicep, but not Core Tools, Power Platform CLI, or Graph modules yet.
Use an interactive user with permission to create resource groups and subscription
deployments, and to deploy/read the four resource types in the dedicated group
(typically subscription Contributor). The resource providers
`Microsoft.Storage`, `Microsoft.KeyVault`, `Microsoft.OperationalInsights`, and
`Microsoft.Insights` must be registered; if registration is denied, have the
subscription administrator register them. Tenant directory roles and runtime
data-plane role assignments are not required by this phase.

Copy the example as described below, set its `subscriptionId` to the intended
subscription, and authenticate locally. Do not put credentials in the parameter file:

```powershell
az login --tenant <tenant-id>
az account set --subscription <subscription-id>

$foundation = .\deploy\Invoke-InventoryDeployment.ps1 `
    -Mode DeployFoundation `
    -TenantId <tenant-id> `
    -ConfigurationPath .\deploy\.local\parameters.json `
    -StatePath .\deploy\.local\deployment.state.json

$foundation | Select-Object Status, CloudChangesMade, FoundationDeploymentImplemented
$foundation.AzureContext
$foundation.ResourceNames
$foundation.Phases | Format-Table Id, Status, SavedStatus, NeedsRevalidation
```

The bootstrap verifies the active tenant, subscription, enabled account, and user
authentication before its first cloud mutation, and reports the selected context.
`-TenantId` is mandatory in this mode; zero tenant/subscription GUIDs are refused.
It never switches accounts or signs in on your behalf. Every cloud command is
explicitly scoped to the configured subscription.

The dedicated resource group and foundation resources have ownership tags
`inventory-sync-installation` and `inventory-sync-workload`. Existing untagged,
wrong-location, wrong-name/type, or incompatible resources are refused before
deployment, rather than adopted or overwritten. In particular, existing storage
must be Standard LRS StorageV2, the vault must use the intended tenant and RBAC
with 90-day soft-delete retention, and Application Insights must reference the
dedicated workspace. Unrelated later-phase resource types are left untouched.
Missing global names are checked for availability, including on partial reruns.
The package does not recover or purge soft-deleted vaults.

The foundation uses secured public endpoints, with no VNet, private endpoints,
or private DNS. Storage requires HTTPS/TLS 1.2 and disables anonymous blob access;
StorageV2 supports blob, queue, and table use. Key Vault uses RBAC, soft delete,
90-day retention, and purge protection. Purge protection cannot be disabled:
deleting a vault does not immediately release its name. No secret is created and
no secret-read role is granted until later phases. Log Analytics defaults to
30-day retention; Application Insights is linked to that workspace.

On success, live resource reads verify ownership, location, provisioning status,
security settings, retention, and workspace linkage before returning
`FoundationValidated` and marking preflight/foundation complete. All later phases
remain pending, and `DeploymentImplemented` remains false because the complete
runtime deployment is not implemented. `CloudChangesMade=true` indicates successful
mutation commands were issued, not that an idempotent rerun necessarily changed
resource properties.

Repeat the same command to resume or reconcile managed configuration drift. Saved
completion never skips live checks. Policy, provider, quota, permission, compilation,
deployment, or post-deployment validation errors terminate the script with phase
and remediation context; no later phase runs. Azure can leave a resource group or
partial resources behind after a failed deployment. Resolve the reported cause and
rerun; do not delete/purge resources as a recovery shortcut. A failed run does not
record new completion; any previously saved completion remains subject to revalidation.

## Installation configuration

For a local configuration, copy the example to an ignored directory:

```powershell
New-Item -ItemType Directory -Path .\deploy\.local -Force
Copy-Item .\deploy\example.parameters.json .\deploy\.local\parameters.json
```

Only parameters declared in [main.bicep](./main.bicep) are accepted. Defaults and
Bicep type/range constraints come from the compiled template rather than a second
set of PowerShell defaults. Unknown parameters, including client secrets, are
rejected without echoing their values.

Required inputs:

| Input | Meaning |
| --- | --- |
| `subscriptionId` | Subscription GUID; used for deterministic naming, not queried during Plan |
| `targetDataverseUrl` | Existing PALP HTTPS base URL, without credentials, path, query, or fragment |
| `agentCreatedIn` | One exact string such as `Copilot Studio Lite`, not a list |

Optional parameters cover workload naming, location, memory, maximum instances,
log retention, timer state, schedules, creation cap, RPA parallelism, excluded
SKUs, the RPA URL column, and logging entity sets. JSON types must match Bicep
types; for example, timer enablement is a Boolean, not the string `"true"`.
Schedules accept six-field numeric NCRONTAB expressions, including wildcards,
lists, ranges, and positive steps. Named months/weekdays are not accepted.

The default plan uses North Europe, Standard LRS storage, 2,048 MB Flex instances,
maximum 20 instances, 30-day logs, HTTPS/public service endpoints with anonymous
blob access disabled, RBAC Key Vault, and a system-assigned Function identity.
Host/Durable storage is identity-based; the runtime client secret is represented
only as a versionless Key Vault reference. Runtime tenant/client IDs and telemetry
connection string remain explicitly unresolved until cloud deployment.

Both timers are disabled by default, with Agent/RPA schedules of 00:00/01:00 UTC,
a create cap of 5, and RPA parallelism of 5. Change the corresponding parameters
to plan explicit setting changes; do not rely on portal drift. Existing local
Function settings and their historical defaults are not changed by this package.

Global names use a deterministic suffix derived from subscription ID and workload
name. Operational-setting changes do not rename resources. Different subscriptions
or workload names produce different names; this is not a live availability check.
Workload names cannot contain consecutive hyphens, which Azure Key Vault prohibits.

## Non-secret resumable state

State is opt-in and local:

```powershell
$plan = .\deploy\Invoke-InventoryDeployment.ps1 `
    -ConfigurationPath .\deploy\.local\parameters.json `
    -StatePath .\deploy\.local\deployment.state.json
```

A new state file records only schema version, a configuration fingerprint, and
ordered phase IDs/statuses. Plan records every new phase as pending and never
marks a cloud phase completed. Without `-StatePath`, no state file is written.
Each saved completed phase is reported as pending with `NeedsRevalidation=true`;
an offline plan cannot certify external state or skip its validation.

Existing state is strictly validated. Unknown fields, unknown statuses, unexpected
phase order, and a configuration mismatch fail without rewriting the file. Use a
separate state file when deliberately changing configuration. Do not manually
mark phases complete to bypass checks. Secrets, tokens, Dataverse URLs, and
identity objects do not belong in state.

The ordered workflow is preflight, Azure foundation, runtime identity,
runtime credential, Function deployment, logging solution, and readiness
validation. Dependencies are included in the plan. `DeployFoundation` executes
only the first two phases; the remaining cloud phases are not yet implemented.

## Tests and command boundary

```powershell
Invoke-Pester -Path .\tests\InventoryDeployment.Tests.ps1,`
    .\tests\InventoryDeployment.Foundation.Tests.ps1 -Output Detailed -CI
```

Tests use the public bootstrap command. Real Bicep compilation validates the
contract; an optional `-CommandRunner` script block replaces only the external
process boundary for deterministic failure-path tests. It receives a command
name and argument array and returns a dictionary containing `ExitCode` and
`Output`. Do not use this test adapter to bypass compiler validation in normal
operation.

The bootstrap returns one plan/foundation result object or raises a terminating error. Native
compiler errors are reported with their phase and remediation; later phases
never run after failure. When invoked using `pwsh -File`, a terminating error
returns a nonzero process exit code.

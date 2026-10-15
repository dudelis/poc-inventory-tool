# Inventory deployment: Azure, Functions, and logging

The portable package supports offline planning (#11) and explicit Azure foundation
deployment (#12), plus tenant-local runtime identity and credential provisioning
(#13). `DeployFoundation` provisions a dedicated resource group, storage, Key Vault,
Log Analytics, and workspace-based Application Insights. `DeployIdentity` also
authenticates interactively with Microsoft Graph, establishes the managed app and
service principal, assigns Global Reader, and stores a bounded credential in Key Vault.
`DeployFunctions` runs those phases, deploys the Linux Flex Consumption workload,
publishes the repository Functions, and validates the host with both timers disabled
by default (#14). `DeployPowerPlatform` then packs and imports the unmanaged logging
solution, publishes and verifies it in the supplied PALP environment, and returns the
manual runtime-readiness blockers separately from deployment success (#15).

[main.bicep](./main.bicep) declares the shared input contract and has no resources.
The bootstrap deploys [foundation-group.bicep](./foundation-group.bicep) at subscription
scope and [foundation.bicep](./foundation.bicep) incrementally at resource-group scope.
[functions.bicep](./functions.bicep) incrementally deploys the Function hosting plan,
app, private deployment container, runtime settings, and managed-identity roles.

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

## Establish the runtime identity

This mode makes live Azure and Microsoft Entra changes. It revalidates and
incrementally redeploys the foundation first, so retain all foundation permissions.
Install the reported Microsoft Graph PowerShell modules yourself; the bootstrap
never installs modules. The operator must be able to create/manage app registrations
and service principals and assign directory roles (normally a Privileged Role
Administrator or Global Administrator with the necessary activated privileges).
Graph requests delegated `Application.ReadWrite.All` and
`RoleManagement.ReadWrite.Directory`; tenant consent policy may require administrator
consent. These are operator permissions, not runtime app permissions.

The operator also needs Key Vault data-plane permission to list secret metadata and
versions and set secrets, such as **Key Vault Secrets Officer**, on the dedicated
vault. Subscription Contributor alone does not grant this access. Have an authorized
administrator grant it after `DeployFoundation`; this phase does not assign the
operator a vault role or grant the runtime service principal secret-read access.

```powershell
$identity = .\deploy\Invoke-InventoryDeployment.ps1 `
    -Mode DeployIdentity `
    -TenantId <tenant-id> `
    -ConfigurationPath .\deploy\.local\parameters.json `
    -StatePath .\deploy\.local\deployment.state.json

$identity | Select-Object Status, CloudChangesMade
$identity.Identity
$identity.Phases | Format-Table Id, Status, SavedStatus, NeedsRevalidation
```

An interactive Azure CLI user login is still required. Microsoft Graph prompts
interactively with process-scoped authentication. Both contexts must match
`-TenantId` before any cloud mutation or state creation. Never supply an app secret
as an operator login or put one in the configuration.

The bootstrap creates one single-tenant (`AzureADMyOrg`) app with the planned
display name and an `InventorySyncInstallation:<suffix>` ownership tag, then one
service principal for its client ID. It refuses duplicate display-name candidates,
unowned apps, incompatible account types, duplicate service principals, or identity
IDs that differ from saved state. It does not adopt the existing manual installation.
Global Reader is identified by its built-in template ID
`f2ef992c-3afb-46b9-b7cf-a126ee74c451` and assigned at directory scope `/`.
The assignment is read back; if it is not visible yet, the command fails resumably
with non-secret identity/assignment IDs. Wait several minutes and rerun. Assignment
visibility is not a guarantee that downstream Resource Graph authorization has
finished propagating; verify that access before enabling the inventory workload.
Retries validate the saved assignment without posting duplicates. If the saved
assignment stays missing, have a directory-role administrator inspect and restore it.

The managed secret is `inventory-sync-client-secret`. Existing metadata must match
the installation and app, have an enabled current secret and exactly one enabled,
unexpired version, and be unambiguous. Disabled historical versions may remain.
The bootstrap never reads the stored value and never rotates an existing credential
implicitly. A disabled, expired, unowned, or ambiguous secret stops the phase instead.
When no secret exists, it checks for orphaned managed app passwords before creating
one with a 12-calendar-month expiry. Tenant credential-lifetime policy can reject
creation; the bootstrap does not silently choose another lifetime.

The generated value is sent directly to the vault in an in-memory HTTPS request,
not a native command argument or temporary file. Sensitive operations use an isolated
runspace so their diagnostics cannot enter the calling transcript. The command
returns only identity IDs, credential key ID where known, expiry, and secret version;
the local state retains the same non-secret operational/recovery metadata.

**Recovery after credential creation:** if the Key Vault write fails, the command
throws and leaves `PendingKeyVaultWrite` with the key ID and expiry. First inspect
the vault metadata: a network failure can occur after the server accepted a write.
If the managed version exists, rerun to validate it. If it does not, remove the
orphaned app password by the recorded key ID, then set only `identity.credential`
to `null` in the state file and rerun. Never clear the state and blindly retry.
Even without local state, an existing managed app password blocks duplicate creation
and its non-secret metadata is recorded for recovery. If password creation itself
has an unknown outcome, inspect the app's credential metadata before retrying.

`IdentityValidated` marks preflight, foundation, identity, and credential phases
complete. Function deployment and all later phases remain pending. The returned
app settings resolve tenant/client IDs but keep the versionless Key Vault reference;
no Function settings are applied by this mode.

## Deploy and validate the Functions

This mode makes live Azure and Microsoft Entra changes and publishes code. It runs
all foundation/identity/credential checks first. Keep those permissions and install
Functions Core Tools **v4** yourself. The operator additionally needs permission to
deploy `Microsoft.Web` resources, publish to the app, and create/read Azure role
assignments on the storage account and vault (for example Contributor plus Role
Based Access Control Administrator at the dedicated group). Register `Microsoft.Web`
and confirm Flex Consumption and PowerShell 7.6 availability/quota in the selected
region. Power Platform CLI is not required by this mode.

Supply real `subscriptionId`, an **HTTPS** `targetDataverseUrl`, and one confirmed
`agentCreatedIn` string in the ignored parameter file; placeholder authoring-tool
values are refused. Keep both timer flags false until Power Platform permissions,
logging import, and smoke runs have been verified separately.

```powershell
$runtime = .\deploy\Invoke-InventoryDeployment.ps1 `
    -Mode DeployFunctions `
    -TenantId <tenant-id> `
    -ConfigurationPath .\deploy\.local\parameters.json `
    -StatePath .\deploy\.local\deployment.state.json

$runtime | Select-Object Status, CloudChangesMade, FunctionDeploymentImplemented
$runtime.FunctionValidation
$runtime.Phases | Format-Table Id, Status, SavedStatus, NeedsRevalidation
```

The app uses Linux Flex Consumption (`FC1`), Functions v4, PowerShell 7.6, 2,048 MB
instances, and maximum 20 instances by default. Runtime selection is in
`functionAppConfig.runtime`; Flex manages the Functions v4 host itself. Deprecated
`FUNCTIONS_EXTENSION_VERSION`, `FUNCTIONS_WORKER_RUNTIME`, and
`FUNCTIONS_WORKER_RUNTIME_VERSION` app settings are deliberately not deployed.
These settings still apply to local development. See Microsoft's
[Flex app-setting deprecations](https://learn.microsoft.com/azure/azure-functions/functions-app-settings#flex-consumption-plan-deprecations).

The system-assigned identity receives **Storage Blob Data Owner**, **Storage Queue
Data Contributor**, and **Storage Table Data Contributor** on the dedicated storage
account, and **Key Vault Secrets User** on the vault. Blob Data Owner covers the host
and deployment-container access; queue/table roles also support Durable storage.
Both host and Durable use `AzureWebJobsStorage__accountName` plus
`AzureWebJobsStorage__credential=managedidentity`. Deployment storage also uses the
system identity. No storage key, Azure Files connection, or run-from-package setting
is applied. The runtime service principal is separate from this managed identity.

All runtime inputs, versionless secret reference, standalone Durable SDK setting,
logging entity sets, exclusions, URL column, schedules, and limits are IaC-owned.
Bicep reads the telemetry connection string from the managed Application Insights
resource. Both schedules are stored even while disabled: Agent **00:00 UTC**, RPA
**01:00 UTC**. The initial create cap and RPA parallelism are **5**.

Each deployment first applies disabled timer settings, including on reruns. Existing
untagged, ambiguous, or incompatible app/hosting-plan resources are refused, not
adopted or migrated. After infrastructure succeeds, live checks verify the app/plan,
runtime/scale/security properties, exact role scopes/principal, sanitized settings,
and `Resolved` Key Vault reference status. Only then does Core Tools publish from
the repository's `src` directory. Local settings files are excluded by
[.funcignore](../src/.funcignore); the bootstrap never publishes local app settings
or requests function keys. Raw deployment/publication/settings diagnostics are
suppressed because they can contain credentials.

Post-publication checks require exactly the repository's six Functions, matching
timer disabled states, and a running, error-free Functions v4 host through the
Azure-authenticated host-status API. `FunctionsValidated` marks the first five phases
complete, not Power Platform readiness. `DeploymentImplemented` remains false until
the remaining phases are implemented. No inventory sync is invoked as a health check.

RBAC/reference propagation, publication, indexing, or host failures stop the command,
leave Function completion pending, and do not create another runtime credential on
rerun. Wait for propagation or correct the reported problem, inspect Azure deployment
operations and Application Insights without sharing credentials, and rerun the same
command/state. The workflow is fail-fast rather than an unbounded polling loop.
Before changing timer state, make sure no existing orchestration is running: disabling
timers does not cancel work already in progress.

## Deploy logging and report runtime readiness

`DeployPowerPlatform` runs and revalidates the Azure, identity, credential, and
Functions phases before crossing the supported Power Platform boundary. Install
Power Platform CLI yourself and use an interactive account that can import and
publish unmanaged solutions in the supplied existing PALP environment. The bootstrap
does not accept Power Platform administrator credentials.

Both timer inputs must still be `false`; this mode refuses enabled timers before any
cloud mutation. Run it with the same configuration and state used for
`DeployFunctions`:

```powershell
$deployment = .\deploy\Invoke-InventoryDeployment.ps1 `
    -Mode DeployPowerPlatform `
    -TenantId <tenant-id> `
    -ConfigurationPath .\deploy\.local\parameters.json `
    -StatePath .\deploy\.local\deployment.state.json

$deployment | Select-Object Status, AzureEntraDeploymentStatus, CloudChangesMade
$deployment.PowerPlatformValidation
$deployment.RuntimeReadiness.Checks | Format-Table Id, Status, Requirement
```

The bootstrap runs interactive `pac auth create` against `targetDataverseUrl` and
uses `pac env who` to reject a context targeting another environment. It packs
`solutions/InventorySyncLogging` into a unique temporary archive on every run,
imports the unmanaged archive into the explicit target URL, publishes
customizations, verifies the installed unmanaged solution, and queries both logging
tables. The configured Sync Run and Sync Log entity-set names must match the unpacked
solution metadata. The temporary archive is removed whether packing, import,
publication, or verification succeeds or fails; the committed root archive is never
used by this mode.

Successful automation returns `DeploymentCompletedReadinessBlocked`.
`AzureEntraDeploymentStatus=Completed` and completed logging/readiness phases mean
the supported deployment work succeeded; they do **not** mean inventory writes are
ready. `RuntimeReadiness.Status=Blocked` and
`TimerEnablementAllowed=false` remain in force until an operator confirms:

1. the target application user;
2. organization-level target writer privileges;
3. application users in every included RPA source;
4. organization-level source reader privileges;
5. unique PALP Environment mappings and valid source URLs;
6. the active `palp_komponente.palp_id` alternate key; and
7. a reviewed capped smoke run in a non-production environment.

The bootstrap deliberately does not create Dataverse environments, import the core
PALP solution, create application users, assign security roles, populate Environment
rows or URLs, activate the alternate key, or run an inventory sync. Complete those
tenant-sensitive checks using the operations guide. Authentication, packing, import,
publication, and verification failures stop immediately, keep the logging phase
pending, retain earlier non-secret completion metadata, and can be retried with the
same configuration and state.

### Deliberate timer enablement and operational changes

After `DeployPowerPlatform` succeeds and every reported manual readiness check and
smoke run is complete, edit the ignored input JSON and rerun `Plan`, then
`DeployFunctions`. Use a **new state filename** when input values change; the strict
configuration fingerprint intentionally rejects an old state.
Resource names and managed identity/credential discovery remain stable.

| Input | Default | Effect |
| --- | --- | --- |
| `agentTimerEnabled`, `rpaTimerEnabled` | `false` | Explicit opt-in to each timer |
| `agentSchedule`, `rpaSchedule` | `0 0 0 * * *`, `0 0 1 * * *` | UTC NCRONTAB schedules |
| `maxCreatesPerRun` | `5` | Shared per-run creation cap |
| `rpaMaxParallelEnvironments` | `5` | Concurrent source environment reads |
| `instanceMemoryMB`, `maximumInstanceCount` | `2048`, `20` | Flex instance memory and scale cap |

When a timer flag is true, deployment still publishes and validates with both timers
disabled first. Only after those gates succeed does a **second incremental Bicep
deployment** apply the requested opt-in; resource/settings/reference/function/host
checks run again. No second code publication occurs. Timers can start immediately
after that explicit activation; activation or subsequent validation failures do not
roll back cloud changes automatically. To disable them, set both flags false and
rerun with a new state filename. Never create lasting portal/CLI app-setting drift.

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
full identity objects do not belong in state. `DeployIdentity`, `DeployFunctions`,
and `DeployPowerPlatform` additionally retain
strictly allowlisted identity IDs and non-secret credential expiry/version/recovery
metadata; it never stores a credential value.

The ordered workflow is preflight, Azure foundation, runtime identity,
runtime credential, Function deployment, logging solution, and readiness
validation. Dependencies are included in the plan. `DeployFoundation` executes
only the first two phases; `DeployIdentity` executes the first four;
`DeployFunctions` executes the first five; `DeployPowerPlatform` executes all seven.
Completing readiness validation means the blocking checklist was produced, not that
the operator-confirmed items passed.

## Tests and command boundary

```powershell
Invoke-Pester -Path .\tests\InventoryDeployment.Tests.ps1,`
    .\tests\InventoryDeployment.Foundation.Tests.ps1,`
    .\tests\InventoryDeployment.Identity.Tests.ps1,`
    .\tests\InventoryDeployment.Functions.Tests.ps1 -Output Detailed -CI
```

Tests use the public bootstrap command. Real Bicep compilation validates the
contract; an optional `-CommandRunner` script block replaces only the external
process boundary for deterministic failure-path tests. It receives a command
name, argument array, and optional sensitive-input dictionary and returns a
dictionary containing `ExitCode` and `Output`. The default sensitive write uses
HTTPS rather than invoking the nominal `az keyvault secret set` command.
`-GraphRunner` replaces only Microsoft Graph operations; `-Clock` supplies the
credential clock. Sensitive adapters run in an isolated runspace and should capture
any required fake state in a closure. Tests never contact Azure or Graph.
Do not use test adapters to bypass validation in normal operation.

The bootstrap returns one plan/foundation/identity/Functions/Power Platform result
object or raises a terminating error. Native
compiler errors are reported with their phase and remediation; later phases
never run after failure. When invoked using `pwsh -File`, a terminating error
returns a nonzero process exit code.

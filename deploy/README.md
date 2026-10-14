# Inventory deployment: offline contract

This portable package currently implements the offline planning contract in
issue #11. It **does not deploy resources, sign in, create credentials, publish
Functions, import solutions, or enable timers**. Azure provisioning and the
remaining bootstrap phases are delivered by the subsequent tickets under #10.
The Bicep entry point declares the deployment input contract; its compiled ARM
template has no resources. Do not deploy it expecting infrastructure.

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
URL, and an Agent authoring-tool placeholder. These are accepted only to make
offline validation possible; a future deployment must require actual values.
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

The ordered future workflow is preflight, Azure foundation, runtime identity,
runtime credential, Function deployment, logging solution, and readiness
validation. Dependencies are included in the plan. This ticket defines the
contract; executing and resuming those cloud phases is not yet implemented.

## Tests and command boundary

```powershell
Invoke-Pester -Path .\tests\InventoryDeployment.Tests.ps1 -Output Detailed -CI
```

Tests use the public bootstrap command. Real Bicep compilation validates the
contract; an optional `-CommandRunner` script block replaces only the external
process boundary for deterministic failure-path tests. It receives a command
name and argument array and returns a dictionary containing `ExitCode` and
`Output`. Do not use this test adapter to bypass compiler validation in normal
operation.

The bootstrap returns one plan object or raises a terminating error. Native
compiler errors are reported with their phase and remediation; later phases
never run after failure. When invoked using `pwsh -File`, a terminating error
returns a nonzero process exit code.

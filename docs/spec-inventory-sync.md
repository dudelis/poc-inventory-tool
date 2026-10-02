# Spec: Inventory sync for Desktop Flows and Agent Builder agents

> Triage label: `ready-for-agent` (to be applied once an issue tracker is configured)

## Problem Statement

The governance solution (PALP) keeps an inventory of Power Platform components in the Dataverse table **Komponente** (`palp_komponente`). Until now this table has been filled by legacy processes and dataflows that take their data from the CoE Starter Kit. That mechanism is about to be deprecated, and it does not cover the newer component types the customer must govern: **Desktop Flows (RPA)** and **Agent Builder agents** (also known as Copilot Studio Lite).

Administrators therefore have no reliable, unattended, regularly refreshed inventory of these components. They cannot see which desktop flows and agents exist, who owns them, in which environment they live, or which ones have disappeared. Any sync must run without a signed-in user. The Power Platform Inventory API rejects service principals, so it cannot be used.

## Solution

Two independent, unattended PowerShell Azure Function implementations keep `palp_komponente` in sync for the two new component types:

- **RPA sync** reads the list of relevant environments from the customer's **Environment** table (`palp_environment`). It queries each environment's Dataverse for desktop flows and reconciles them into `palp_komponente` with type `DesktopFlow`.
- **Agent sync** runs one tenant-wide Azure Resource Graph query for Agent Builder agents and reconciles them into `palp_komponente` with type `AgentBuilderAgent`.

On each run, every sync does the following:

- **Creates** components that are new.
- **Updates** technical fields of existing components when the source changed.
- **Marks as deleted** components that can no longer be found, after a targeted re-check. Rows are never physically deleted.
- **Restores** components that reappear after being marked deleted.

The syncs run daily by default. The schedule is configurable per function in app settings, and a run can also be started manually from the Azure portal. Every run is logged to Application Insights and to two Dataverse log tables (**Sync Run** and **Sync Log**). Administrators can see sync health and every individual problem, such as an unreachable environment, missing permissions, or a failed write, together with the error message.

Rows written by legacy processes (all other component types) are never read, changed, or marked deleted by these syncs.

## User Stories

### Inventory coverage

1. As a governance administrator, I want every desktop flow in every relevant environment to appear in `palp_komponente`, so that I have a complete RPA inventory.
2. As a governance administrator, I want every Agent Builder agent in the tenant to appear in `palp_komponente`, so that I have a complete agent inventory.
3. As a governance administrator, I want desktop flows stored with type `DesktopFlow` and agents with type `AgentBuilderAgent`, so that I can filter and report on them using the existing type column.
4. As a governance administrator, I want each component linked to its environment record, so that I can navigate from a component to its environment and the reverse.
5. As a governance administrator, I want each component to show its owner's Entra object ID, so that existing governance processes can contact the owner.
6. As a governance administrator, I want each component to carry its original created and last-modified dates from the source, so that I can judge how active it is.
7. As a governance administrator, I want desktop flows in every state (draft, activated, suspended) to be inventoried, so that inactive automation is visible as well.
8. As a governance administrator, I want only Agent Builder agents (not full Copilot Studio agents) to be synced, so that this sync doesn't duplicate data that legacy processes manage.
9. As a governance administrator, I want the same desktop flow deployed to several environments to appear once per environment, so that each deployment is governed separately.

### Create and update behaviour

10. As a governance administrator, I want new components created with default governance values (status Neu, Aktiv, Nutzungsbereich Undefiniert, status-change date = now), so that the existing governance process picks them up from the start.
11. As a governance administrator, I want the sync to update only technical fields (title, owner, description, environment, source dates) on existing components, so that governance decisions stored on the row are never overwritten.
12. As a governance administrator, I want governance fields such as Komponentenstatus, Nutzungsbereich, Regelverstoss, Handlungsbedarf, Stellvertreter, Team and Gesellschaft left untouched on updates, so that manual and process-driven governance work is preserved.
13. As a governance administrator, I want rows written only when a value actually changed, so that audit history stays clean and Dataverse API consumption stays low.
14. As a governance administrator, I want the sync to never touch rows of other component types, so that the legacy CoE-based processes keep working until they're retired.
15. As a governance administrator, I want the sync to never write to the Environment table, so that the customer's environment master data stays under their control.

### Deletion and restore

16. As a governance administrator, I want components that no longer exist at the source marked with Komponentenstatus Geloescht, status Inaktiv, and the status-change date set to now, so that deletions are visible without losing history.
17. As a governance administrator, I want components never physically deleted by the sync, so that the inventory keeps a full historical record.
18. As a governance administrator, I want each deletion candidate re-checked against the source by environment ID, component type, and component ID before it's marked, so that temporary gaps don't cause false deletions.
19. As a governance administrator, I want the deletion check to run only after a fully successful collection run, so that a failed or partial run can never mass-mark components as deleted.
20. As a governance administrator, I want desktop flows in an environment that couldn't be read during the run excluded from the deletion check, so that one broken environment doesn't flag all its flows as deleted.
21. As a governance administrator, I want nothing marked deleted when the targeted re-check itself fails, so that errors are reported instead of acted on.
22. As a governance administrator, I want a component that reappears after being marked deleted restored to status Neu and Aktiv with the status-change date set to now, so that it re-enters the governance process.
23. As a governance administrator, I want every restore recorded in the sync log, so that I can investigate false deletions.

### Environments (RPA)

24. As a governance administrator, I want the RPA sync to use the customer's Environment table as the list of environments to scan, so that the scope matches the customer's own environment master data.
25. As a governance administrator, I want Default and Teams environments excluded from the RPA scan, so that personal and Teams environments are out of scope.
26. As a governance administrator, I want the excluded environment SKUs to be configurable, so that the filter can be adjusted (for example to also exclude developer environments) without a code change.
27. As a governance administrator, I want environments without a Dataverse URL skipped and logged, so that I can see which environments couldn't be scanned and why.
28. As a governance administrator, I want an unreachable environment (permissions, admin mode, timeout, throttling) skipped after retries and logged with the error message, so that the rest of the run completes.
29. As a governance administrator, I want an agent whose environment isn't in the Environment table skipped and logged, so that the required environment lookup never fails a whole batch.

### Scheduling and operation

30. As an operator, I want each sync to run daily by default, so that the inventory is at most one day old.
31. As an operator, I want each function's schedule configurable in app settings, so that I can change the cadence without redeploying.
32. As an operator, I want to start a sync manually from the Azure portal, so that I can refresh the inventory on demand.
33. As an operator, I want a run that starts while another run of the same sync is still active to be skipped and logged, so that two runs never race on writes and deletion checks.
34. As an operator, I want the RPA and Agent syncs to be independent, so that a failure in one never blocks the other.
35. As an operator, I want the number of environments read in parallel to be configurable, so that I can balance run time against throttling.
36. As an operator, I want a configurable cap on the number of components created per run, so that the first run can't flood downstream processes if needed.
37. As an operator, I want throttling responses honoured automatically (Retry-After), so that runs succeed under Dataverse and Resource Graph limits.

### Security and configuration

38. As a security officer, I want the syncs to authenticate as a service principal without any user account, so that the solution runs unattended and doesn't depend on a person.
39. As a security officer, I want the service principal secret stored in Azure Key Vault and referenced from app settings, so that no secret appears in code or plain configuration.
40. As a security officer, I want the Function App's managed identity to have read-only access to Key Vault secrets, so that the blast radius stays minimal.
41. As an operator, I want all configuration values (tenant ID, client ID, target Dataverse URL, Environment table URL column, excluded SKUs, Agent Builder filter value, schedules, parallelism, creation cap, log table names) in app settings, so that the customer can configure the solution manually.
42. As an operator, I want the solution to rely on the service principal already being an application user in every environment, so that no extra provisioning is needed.

### Logging and monitoring

43. As an operator, I want all function executions, traces, and exceptions sent to Application Insights automatically, so that I can troubleshoot without extra tooling.
44. As a governance administrator, I want one Sync Run row per run (sync type, phase, start/end, status, counts of environments, found, created, updated, unchanged, marked deleted, restored, errors), so that I can see sync health in Dataverse.
45. As a governance administrator, I want one Sync Log row per problem (severity, category, environment, component type and ID, operation, HTTP status, error code, full error message, correlation ID), so that I can see exactly what couldn't be obtained and why.
46. As an operator, I want Sync Log rows to carry a correlation ID matching Application Insights, so that I can jump from a Dataverse log entry to the technical trace.
47. As an operator, I want the logging tables shared by both syncs, so that RPA and agent problems are reported the same way.
48. As an operator, I want the logging tables delivered as a separate solution, so that they don't interfere with the PALP solution's lifecycle.

## Implementation Decisions

### Architecture

- **Two separate implementations**: one for RPA (desktop flows) and one for Agent Builder agents. Each consists of a set of functions and is deployed and scheduled independently.
- **Runtime**: Azure Functions, PowerShell 7.6, Flex Consumption plan, Durable Functions with the standalone PowerShell Durable SDK.
- **Infrastructure** (Function App, Storage, Application Insights, Key Vault, role assignments, app settings) is provisioned and configured **manually by the customer**. The deliverable is code, a list of app settings, and the logging solution.
- **Shared PowerShell module** used by both implementations, containing:
  - an **HTTP transport**: the single function through which every REST call goes (token, Resource Graph, Dataverse); it handles retries and honours Retry-After on 429 and Dataverse service-protection errors;
  - **token acquisition** with client credentials, cached per resource;
  - **Dataverse access**: paged reads using `@odata.nextLink`, upsert, and `$batch` writes of up to 1000 operations;
  - **Resource Graph access**: paged query using `$skipToken`;
  - **reconciliation**: comparing collected items with existing rows to produce a write plan (create, update changed technical fields, restore, unchanged);
  - **deletion check**: set comparison, then targeted re-check, then mark deleted;
  - **logging**: Sync Run and Sync Log writers plus structured trace output.
- **Orchestration flow, per sync**: a timer starter checks the singleton guard and starts the orchestrator. The orchestrator then runs:
  1. **Collect.** For RPA this means reading environments, then fanning out bounded and in parallel across environments.
  2. **Read existing rows.** All rows of this sync's type are read once.
  3. **Reconcile.**
  4. **Write in batches.**
  5. **Record the run result.**
  6. **Deletion check**, only if the run was complete. For RPA, "complete" means complete per environment.

  Orchestrators and triggers are thin wrappers with no business logic.
- **Singleton guard**: each sync uses a fixed orchestration instance ID. If that instance is running, the new start is skipped, and a warning is written to Application Insights and the Sync Log.
- **Manual runs** use the portal's Test/Run on the timer function. There is no HTTP starter.
- **Schedules**: daily by default. The CRON expression for each function is read from app settings.

### Sources

- **Agent Builder agents**: one tenant-wide Azure Resource Graph query on the Power Platform resources table. It filters on the Copilot Studio agent type and on the authoring-tool property (`createdIn`). The filter value is configurable, because its actual value (for example "Microsoft 365 Copilot Agent Builder" vs. "Copilot Studio Lite") must be confirmed against real data. Authentication is the service principal against Azure Resource Graph. The Power Platform Inventory API isn't used, because it rejects service principals.
- **Desktop flows**:
  - Each environment's Dataverse workflow table, filtered to the desktop flow category, covering all states.
  - The owner's Entra object ID is resolved from the owning user or team.
  - If the owner can't be resolved, the row is skipped and logged, because the owner field is required.
- **Environment list for RPA**: read from `palp_environment` in the target Dataverse. Environments are excluded when they match configured SKUs (default: Standard/Default and Teams), when they're deleted or removed, or when they have no Dataverse URL. The name of the column holding the Dataverse URL is configurable (TBD).

### Target schema (existing, `palp_komponente`)

- Type column `palp_typ` uses the global option set Komponententyp: **DesktopFlow = 4**, **AgentBuilderAgent = 5**. All queries, writes, and deletion checks are scoped to these values.
- **Unique key**: the existing non-customizable alternate key on `palp_id` (text, 36 characters). The strategy for its value is **TBD** and encapsulated in one function. The default is a deterministic name-based GUID derived from environment ID, component type, and source component ID. This keeps rows unique per environment, because solution-deployed desktop flows keep the same ID across environments. The final choice follows the customer's test data showing how legacy processes fill `palp_id`.
- The **environment lookup** is bound through the Environment table's alternate key on `palp_id` (the environment GUID).
- **Field ownership**:

  | Field | Set on create | Updated by sync | Set on delete | Set on restore |
  |---|---|---|---|---|
  | `palp_id` | yes | – | – | – |
  | `palp_typ` | yes | – | – | – |
  | `palp_titel` | yes | when changed | – | – |
  | `palp_besitzerobjectid` | yes | when changed | – | – |
  | `palp_beschreibung` | yes | when changed | – | – |
  | `palp_environment` | yes | when changed | – | – |
  | `palp_urspruenglicherstelltam` | yes | when changed | – | – |
  | `palp_urspruenglichgeaendertam` | yes | when changed | – | – |
  | `palp_komponentenstatus` | Neu (0) | never | Geloescht (7) | Neu (0) |
  | `palp_status` | Aktiv (0) | never | Inaktiv (1) | Aktiv (0) |
  | `palp_nutzungsbereich` | Undefiniert (0) | never | – | – |
  | `palp_letztestatusaenderung` | now | never | now | now |
  | all other columns | – | never | – | – |

- **Source-to-target mapping**:

  | Target | Desktop flow | Agent Builder agent |
  |---|---|---|
  | `palp_titel` | workflow name | display name |
  | `palp_besitzerobjectid` | owner's Entra object ID | owner object ID |
  | `palp_beschreibung` | workflow description | – |
  | `palp_environment` | environment ID | environment ID |
  | `palp_urspruenglicherstelltam` | created on | created at |
  | `palp_urspruenglichgeaendertam` | modified on | last modified at |

- **No schema changes** to `palp_komponente` or `palp_environment` are required by this design.

### Deletion detection

- **Set comparison, not a "last seen" column**:
  1. After a complete collection, the active rows of this sync's type are compared with the set of collected component keys. For RPA, only environments read successfully in this run are included.
  2. Rows not in the set become candidates.
  3. Each candidate is re-checked at its source by environment ID, component type, and component ID. RPA candidates are checked against that environment's Dataverse, agents against Azure Resource Graph by ID without the authoring-tool filter.
  4. Only components confirmed missing are marked deleted.
- If the re-check fails or is incomplete, **nothing** is marked and the problem is logged.
- When reconciliation finds a collected component whose row is marked Geloescht, the row is restored.

### Authentication and configuration

- One service principal with client credentials is used for Resource Graph, the target Dataverse, and every source environment's Dataverse. It is already registered as an application user in every environment.
- The tenant ID and client ID are plain app settings. The client secret is an app setting that holds a Key Vault reference. The Function App's managed identity has the Key Vault Secrets User role.
- App settings:
  - Target Dataverse URL
  - Environment-table URL column name (TBD)
  - Excluded environment SKUs
  - Agent Builder `createdIn` filter value
  - RPA schedule and Agent schedule
  - Maximum environments read in parallel (default 10)
  - Maximum creates per run
  - Sync Run and Sync Log table names
  - Application Insights connection string

### Logging

- Application Insights is connected through its connection string. Built-in Functions telemetry, plus the warnings, errors, and information records the code writes, is enough. No custom telemetry SDK is used.
- **Sync Run** table (header): run ID, sync type (RPA / AgentBuilder), phase (Collect / Write / DeletionCheck), started on, completed on, status (Running / Succeeded / Partial / Failed), environments total and failed, items found, created, updated, unchanged, marked deleted, restored, errors.
- **Sync Log** table (detail, with a lookup to Sync Run):
  - severity (Warning / Error)
  - category (EnvironmentUnreachable / PermissionDenied / Throttled / ReadFailed / WriteFailed / VerifyFailed / Config / RunSkipped / Restored / Skipped)
  - environment ID and name
  - component type and component ID
  - operation
  - HTTP status, error code, full error message
  - occurred on
  - correlation ID
- Both tables are shipped as a **separate unmanaged Dataverse solution** that the customer imports into the target environment. The service principal gets create and write rights on them. Until the solution is imported, logging goes to Application Insights only.

## Testing Decisions

- **One seam: the HTTP transport.** Every external call goes through the shared module's transport function. Pester tests replace it with canned responses and assert on:
  - the requests sent: URLs, filters, `$batch` contents, and write payloads;
  - the results returned: write plans, counts, and log entries.
- Tests call the shared module's **public sync functions**: collect, reconcile, write, and deletion check, for each sync type. They don't call internal helpers, and they don't run the Durable runtime.
- **A good test** describes external behaviour, for example "a collected desktop flow whose row is Geloescht is restored to Neu/Aktiv and a Restored log entry is written." It doesn't depend on implementation details, so it survives refactoring.
- **Behaviours that must be covered**:
  - Paging: `@odata.nextLink` and `$skipToken`.
  - Retry on 429 or service-protection errors, honouring Retry-After.
  - Environment filtering: excluded SKUs, deleted or removed environments, missing URL.
  - Partial environment failure: the run is marked Partial, and that environment is excluded from the deletion check.
  - Reconciliation:
    - create with defaults;
    - update only changed technical fields;
    - unchanged rows produce no write;
    - governance fields are never in an update payload;
    - restore of a Geloescht row.
  - `palp_id` generation: deterministic, and unique per environment.
  - Deletion check:
    - candidate selection by set comparison;
    - confirmed-missing rows are marked with Geloescht, Inaktiv, and now;
    - candidates that still exist are left untouched;
    - a failed re-check marks nothing and logs VerifyFailed;
    - the deletion check is skipped after an incomplete run.
  - Rows of other component types are never read or written.
  - Missing environment for an agent, and an unresolvable owner for a desktop flow, are skipped and logged.
  - The creation cap is enforced.
  - `$batch` building and handling of partial batch failures.
- **Durable orchestrators and triggers** hold no logic and aren't unit tested. They're covered by a manual smoke run against a test environment.
- **Prior art**: none. The repository has no existing code or tests.

## Out of Scope

- Power Pages, canvas apps, model-driven apps, cloud flows, agent flows, and full Copilot Studio agents. They stay with the legacy processes.
- Flow run history: desktop flow runs and cloud flow runs.
- Writing to the Environment table, or syncing environments.
- Provisioning the service principal as an application user in environments. This already exists.
- Infrastructure as code and CI/CD pipelines. The customer provisions and configures infrastructure manually.
- HTTP-triggered manual starters.
- Logic Apps and Dataflows as implementation options. They were evaluated and rejected: Dataflows lack service-principal support for Resource Graph and support only hard deletes; Logic Apps were dropped by decision.
- The Power Platform Inventory API. It supports only delegated user authentication.
- Physically deleting rows.
- Notifications to owners. Any downstream automation on `palp_komponente` stays the customer's responsibility.

## Further Notes

### TBD register (awaiting the customer)

| # | Item | Interim handling |
|---|---|---|
| 1 | Test data for `palp_komponente`, including how legacy fills `palp_id` and whether the same component exists in several environments | Calculated-GUID default for `palp_id`, isolated in one function |
| 2 | Test data for `palp_environment`, covering Default, Teams, developer, and deleted environments | Filter values in app settings |
| 3 | Plugins, flows, business rules, or workflows on `palp_komponente`, especially notifications | Creation cap in app settings |
| 4 | Dataverse URL column in `palp_environment` | Column name in app settings; environments without a URL are skipped and logged |
| 5 | Confirmation that SKU "Standard" means Default, and whether developer environments are excluded | Excluded SKUs in app settings (default: Standard, Teams) |
| 6 | Actual `createdIn` value for Agent Builder agents | Filter value in app settings; confirm with a distinct query on real data |
| 7 | App setting values (tenant, client ID, Key Vault, target URL), provided by the project lead | Placeholders in the app settings list |
| 8 | Entra role that lets the service principal read Power Platform resources in Resource Graph | Prerequisite for the agent sync |

### Facts verified during design

- The Power Platform Inventory API, and the Power Platform for Admins V2 "Query Power Platform resources" action, support delegated user authentication only. Service principals and managed identities get HTTP 403. A direct Azure Resource Graph query with a service principal works, as confirmed by the project lead.
- The inventory includes Copilot Studio agents, among them Microsoft 365 Copilot Agent Builder agents, distinguishable by the `createdIn` property. It doesn't include desktop flows, flow runs, or (at design time) Power Pages.
- Inventory changes appear within about 15 minutes.
- The Power Query Azure Resource Graph connector supports organizational accounts only. Standard dataflows into Dataverse can only hard-delete rows that are missing from the output.
- Azure Functions support for PowerShell 7.4 ends on 10 November 2026, so the target is PowerShell 7.6.

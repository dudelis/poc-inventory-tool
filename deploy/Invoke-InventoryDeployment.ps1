#Requires -Version 7.6
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ConfigurationPath,

    [ValidateSet('Plan', 'DeployFoundation')]
    [string] $Mode = 'Plan',

    [string] $TenantId,

    [string] $StatePath,

    [scriptblock] $CommandRunner = {
        param([string] $Command, [string[]] $Arguments)
        $output = & $Command @Arguments 2>&1
        @{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
    }
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Invoke-ValidationCommand {
    param([string[]] $Arguments, [string] $Remediation, [string] $Phase = 'Preflight')
    $result = & $CommandRunner 'az' $Arguments
    if ($null -eq $result -or -not $result.Contains('ExitCode') -or -not $result.Contains('Output')) {
        throw "${Phase}: command runner must return ExitCode and Output."
    }
    if ($result.ExitCode -ne 0) {
        throw "${Phase}: az $($Arguments -join ' ') failed. $Remediation`n$($result.Output)"
    }
    return [string] $result.Output
}

function Invoke-AzureJson {
    param([string[]] $Arguments, [string] $Phase, [string] $Remediation)
    $output = Invoke-ValidationCommand -Arguments $Arguments -Phase $Phase -Remediation $Remediation
    try {
        return ConvertFrom-Json -InputObject $output -AsHashtable -NoEnumerate
    }
    catch {
        throw "${Phase}: az $($Arguments -join ' ') returned invalid JSON. $Remediation"
    }
}

function Assert-FoundationProperties {
    param([System.Collections.IDictionary] $Resource, [System.Collections.IDictionary] $Expected)
    foreach ($path in $Expected.Keys) {
        $actual = $Resource
        foreach ($segment in $path -split '\.') {
            if ($actual -isnot [System.Collections.IDictionary] -or -not $actual.Contains($segment)) {
                throw "Azure foundation: resource validation failed for '$path'. Inspect the resource and the deployment before retrying."
            }
            $actual = $actual[$segment]
        }
        if ($actual -ne $Expected[$path]) {
            throw "Azure foundation: incompatible resource '$($Resource.name)': '$path' differs from the deployment contract. Resolve the conflict before retrying."
        }
    }
}

if (-not (Test-Path -LiteralPath $ConfigurationPath -PathType Leaf)) {
    throw 'Configuration: file not found. Supply -ConfigurationPath to a JSON parameter file.'
}
try {
    $inputConfiguration = Get-Content -LiteralPath $ConfigurationPath -Raw |
        ConvertFrom-Json -AsHashtable
}
catch {
    throw 'Configuration: expected a JSON object of non-secret deployment parameters.'
}
if ($inputConfiguration -isnot [System.Collections.IDictionary]) {
    throw 'Configuration: expected a JSON object of non-secret deployment parameters.'
}

$prerequisites = @(
    @{ Name = 'Azure CLI'; Available = [bool] (Get-Command az -ErrorAction SilentlyContinue)
        RequiredFor = 'Validation'; Guidance = 'Install Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli' }
    @{ Name = 'Functions Core Tools v4'; Available = [bool] (Get-Command func -ErrorAction SilentlyContinue)
        RequiredFor = 'Deployment'; Guidance = 'Install Core Tools v4: https://learn.microsoft.com/azure/azure-functions/functions-run-local' }
    @{ Name = 'Power Platform CLI'; Available = [bool] (Get-Command pac -ErrorAction SilentlyContinue)
        RequiredFor = 'Deployment'; Guidance = 'Install pac: https://learn.microsoft.com/power-platform/developer/cli/introduction' }
    @{ Name = 'Microsoft Graph PowerShell'; Available = @(
            Get-Module -ListAvailable Microsoft.Graph.Authentication, Microsoft.Graph.Applications,
                Microsoft.Graph.Identity.Governance | ForEach-Object Name | Select-Object -Unique
        )
        RequiredFor = 'Deployment'; Guidance = 'Install Microsoft.Graph.Authentication, Microsoft.Graph.Applications, and Microsoft.Graph.Identity.Governance modules.' }
)
$prerequisites[3].Available = @($prerequisites[3].Available).Count -eq 3
if (-not $prerequisites[0].Available) {
    throw "Preflight: Azure CLI is missing. $($prerequisites[0].Guidance)"
}
Invoke-ValidationCommand -Arguments @('version', '--output', 'json') `
    -Remediation 'Verify the installed Azure CLI can run without signing in.' | Out-Null
$bicepVersion = Invoke-ValidationCommand -Arguments @('bicep', 'version') `
    -Remediation 'Install Bicep explicitly with az bicep install; this bootstrap never installs tools.'
$prerequisites += @{
    Name = 'Bicep'; Available = $true; RequiredFor = 'Validation'; Version = $bicepVersion.Trim()
    Guidance = 'Install Bicep explicitly with az bicep install.'
}

$compilation = @(
    foreach ($templatePath in Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.bicep' -Recurse |
        Sort-Object FullName) {
        $compiled = Invoke-ValidationCommand -Arguments @(
            'bicep', 'build', '--file', $templatePath.FullName, '--stdout', '--no-restore'
        ) -Remediation 'Fix the indicated Bicep compilation error and rerun Plan.'
        try {
            $template = $compiled | ConvertFrom-Json -AsHashtable
        }
        catch {
            throw "Compilation: $($templatePath.Name) did not produce a valid ARM JSON template."
        }
        @{ Template = $templatePath.FullName; CompiledTemplate = $template }
    }
)
$entryPoint = @($compilation | Where-Object Template -eq (Join-Path $PSScriptRoot 'main.bicep'))
if ($entryPoint.Count -ne 1) {
    throw 'Compilation: exactly one main.bicep entry point is required.'
}
$parameters = $entryPoint[0].CompiledTemplate.parameters
$configuration = [ordered] @{}
foreach ($name in $inputConfiguration.Keys) {
    if (-not $parameters.Contains($name)) {
        throw 'Configuration: unsupported parameter. Use only the non-secret inputs declared in main.bicep; runtime secrets are not accepted.'
    }
}
foreach ($name in $parameters.Keys) {
    $definition = $parameters[$name]
    if ($inputConfiguration.Contains($name)) {
        $value = $inputConfiguration[$name]
    }
    elseif ($definition.Contains('defaultValue')) {
        $value = $definition.defaultValue
    }
    else {
        throw "Configuration: required parameter '$name' is missing."
    }
    $validType = switch ($definition.type) {
        'string' { $value -is [string] }
        'int' { $value -is [int] -or $value -is [long] }
        'bool' { $value -is [bool] }
        default { $false }
    }
    if (-not $validType) {
        throw "Configuration: '$name' must have type $($definition.type)."
    }
    foreach ($constraint in @('minLength', 'maxLength', 'minValue', 'maxValue', 'allowedValues')) {
        if (-not $definition.Contains($constraint)) { continue }
        $valid = switch ($constraint) {
            'minLength' { $value.Length -ge $definition[$constraint] }
            'maxLength' { $value.Length -le $definition[$constraint] }
            'minValue' { $value -ge $definition[$constraint] }
            'maxValue' { $value -le $definition[$constraint] }
            'allowedValues' { $value -in $definition[$constraint] }
        }
        if (-not $valid) { throw "Configuration: '$name' violates $constraint." }
    }
    $configuration[$name] = $value
}
if ($configuration.subscriptionId -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
    throw 'Configuration: subscriptionId must be a GUID; the all-zero GUID is permitted only as an offline example.'
}
if ($configuration.workloadName -notmatch '^[a-z][a-z0-9-]*[a-z0-9]$') {
    throw 'Configuration: workloadName must contain lowercase letters, digits, and internal hyphens.'
}
if ($configuration.workloadName.Contains('--')) {
    throw 'Configuration: workloadName must not contain consecutive hyphens because Azure Key Vault names prohibit them.'
}
$dataverseUri = $null
if (-not [uri]::TryCreate($configuration.targetDataverseUrl, [UriKind]::Absolute, [ref] $dataverseUri) -or
    $dataverseUri.Scheme -ne 'https' -or $dataverseUri.UserInfo -or
    $dataverseUri.Query -or $dataverseUri.Fragment -or $dataverseUri.AbsolutePath -ne '/') {
    throw 'Configuration: targetDataverseUrl must be an HTTPS base URL without credentials, path, query, or fragment.'
}
if ([string]::IsNullOrWhiteSpace($configuration.agentCreatedIn)) {
    throw 'Configuration: agentCreatedIn must be one non-empty authoring-tool string.'
}
foreach ($name in @('rpaEnvironmentUrlColumn', 'syncRunTable', 'syncLogTable')) {
    if ($configuration[$name] -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
        throw "Configuration: '$name' must be a Dataverse logical or entity-set name."
    }
}
foreach ($name in @('agentSchedule', 'rpaSchedule')) {
    $fields = $configuration[$name].Trim() -split '\s+'
    $bounds = @(@(0, 59), @(0, 59), @(0, 23), @(1, 31), @(1, 12), @(0, 6))
    $validSchedule = $fields.Count -eq 6
    for ($fieldIndex = 0; $validSchedule -and $fieldIndex -lt 6; $fieldIndex++) {
        foreach ($term in $fields[$fieldIndex] -split ',') {
            if ($term -notmatch '^(\*|[0-9]+(?:-[0-9]+)?)(?:/([0-9]+))?$') {
                $validSchedule = $false
                break
            }
            $baseTerm = $Matches[1]
            if ($Matches.ContainsKey(2)) {
                $step = 0
                if (-not [int]::TryParse($Matches[2], [ref] $step) -or $step -lt 1) {
                    $validSchedule = $false
                    break
                }
            }
            if ($baseTerm -eq '*') { continue }
            $range = $baseTerm -split '-'
            $start = 0
            $end = 0
            if (-not [int]::TryParse($range[0], [ref] $start) -or
                -not [int]::TryParse($range[-1], [ref] $end) -or
                $start -lt $bounds[$fieldIndex][0] -or
                $end -gt $bounds[$fieldIndex][1] -or $start -gt $end) {
                $validSchedule = $false
                break
            }
        }
    }
    if (-not $validSchedule) {
        throw "Configuration: '$name' must be a valid six-field numeric NCRONTAB schedule in UTC."
    }
}

$namingSeed = "$($configuration.subscriptionId.ToLowerInvariant())|$($configuration.workloadName)"
$suffix = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($namingSeed))
).Substring(0, 12).ToLowerInvariant()
$stem = $configuration.workloadName
$compactStem = $stem.Replace('-', '')
$names = [ordered] @{
    resourceGroup = "rg-$stem-$suffix"
    storage = "st$($compactStem.Substring(0, [Math]::Min(9, $compactStem.Length)))$suffix"
    keyVault = "kv-$($stem.Substring(0, [Math]::Min(7, $stem.Length)).TrimEnd('-'))-$suffix"
    logAnalytics = "log-$stem-$suffix"
    applicationInsights = "appi-$stem-$suffix"
    hostingPlan = "asp-$stem-$suffix"
    functionApp = "func-$stem-$suffix"
    appRegistration = $stem
    deploymentContainer = 'inventory-sync-deploy'
}
$azureContext = $null
if ($Mode -eq 'DeployFoundation') {
    if ($TenantId -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' -or
        [guid] $TenantId -eq [guid]::Empty -or [guid] $configuration.subscriptionId -eq [guid]::Empty) {
        throw 'Preflight: DeployFoundation requires a non-zero -TenantId GUID and subscriptionId.'
    }
    $azureContext = Invoke-AzureJson -Arguments @('account', 'show', '--output', 'json') -Phase 'Preflight' `
        -Remediation 'Sign in interactively with az login --tenant <tenant-id>, then select the configured subscription with az account set.'
    if ($azureContext -isnot [System.Collections.IDictionary] -or
        -not $azureContext.Contains('id') -or -not $azureContext.Contains('tenantId') -or
        -not $azureContext.Contains('state') -or -not $azureContext.Contains('user') -or
        $azureContext.user -isnot [System.Collections.IDictionary] -or
        -not $azureContext.user.Contains('type') -or -not $azureContext.user.Contains('name')) {
        throw 'Preflight: invalid account response. Verify Azure CLI and run az login --tenant <tenant-id> before retrying.'
    }
    if ($azureContext.id -ne $configuration.subscriptionId) {
        throw 'Preflight: active subscription mismatch. Select the configured subscription with az account set --subscription <subscription-id>.'
    }
    if ($azureContext.tenantId -ne $TenantId) {
        throw 'Preflight: active tenant mismatch. Sign in with az login --tenant <tenant-id> and select the configured subscription.'
    }
    if ($azureContext.state -ne 'Enabled' -or $azureContext.user.type -ne 'user') {
        throw 'Preflight: an enabled subscription and an interactively authenticated user are required. Run az login --tenant <tenant-id>.'
    }
    Write-Information "Azure context: tenant $($azureContext.tenantId), subscription $($azureContext.id), operator $($azureContext.user.name)." -InformationAction Continue
}
$settings = [ordered] @{
    FUNCTIONS_EXTENSION_VERSION = '~4'
    FUNCTIONS_WORKER_RUNTIME = 'powershell'
    FUNCTIONS_WORKER_RUNTIME_VERSION = '7.6'
    ExternalDurablePowerShellSDK = 'true'
    AzureWebJobsStorage__accountName = $names.storage
    AzureWebJobsStorage__credential = 'managedidentity'
    APPLICATIONINSIGHTS_CONNECTION_STRING = '<application-insights-connection-string>'
    INVENTORY_TENANT_ID = '<active-tenant-id>'
    INVENTORY_CLIENT_ID = '<generated-client-id>'
    INVENTORY_CLIENT_SECRET = "@Microsoft.KeyVault(SecretUri=https://$($names.keyVault).vault.azure.net/secrets/inventory-sync-client-secret/)"
    INVENTORY_TARGET_DATAVERSE_URL = $configuration.targetDataverseUrl
    INVENTORY_AGENT_CREATED_IN = $configuration.agentCreatedIn
    INVENTORY_AGENT_SCHEDULE = $configuration.agentSchedule
    INVENTORY_RPA_SCHEDULE = $configuration.rpaSchedule
    INVENTORY_RPA_ENVIRONMENT_URL_COLUMN = $configuration.rpaEnvironmentUrlColumn
    INVENTORY_RPA_EXCLUDED_SKUS = $configuration.rpaExcludedSkus
    INVENTORY_RPA_MAX_PARALLEL_ENVIRONMENTS = [string] $configuration.rpaMaxParallelEnvironments
    INVENTORY_SYNC_RUN_TABLE = $configuration.syncRunTable
    INVENTORY_SYNC_LOG_TABLE = $configuration.syncLogTable
    INVENTORY_MAX_CREATES_PER_RUN = [string] $configuration.maxCreatesPerRun
    'AzureWebJobs.AgentSyncTimer.Disabled' = ([string] (-not $configuration.agentTimerEnabled)).ToLowerInvariant()
    'AzureWebJobs.RpaSyncTimer.Disabled' = ([string] (-not $configuration.rpaTimerEnabled)).ToLowerInvariant()
}
$phases = @(
    @{ Id = 'preflight'; DependsOn = @(); Status = 'Pending' }
    @{ Id = 'azure-foundation'; DependsOn = @('preflight'); Status = 'Pending' }
    @{ Id = 'runtime-identity'; DependsOn = @('azure-foundation'); Status = 'Pending' }
    @{ Id = 'runtime-credential'; DependsOn = @('azure-foundation', 'runtime-identity'); Status = 'Pending' }
    @{ Id = 'function-deployment'; DependsOn = @('runtime-credential'); Status = 'Pending' }
    @{ Id = 'logging-solution'; DependsOn = @('function-deployment'); Status = 'Pending' }
    @{ Id = 'readiness-validation'; DependsOn = @('logging-solution'); Status = 'Pending' }
)
$configurationHash = [Convert]::ToHexString(
    [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(
        ($configuration | ConvertTo-Json -Compress)
    ))
).ToLowerInvariant()
$state = [ordered] @{
    schemaVersion = 1
    configurationHash = $configurationHash
    phases = @($phases | ForEach-Object { [ordered] @{ id = $_.Id; status = 'Pending' } })
}
if ($StatePath) {
    $resolvedStatePath = [IO.Path]::GetFullPath($StatePath)
    if (Test-Path -LiteralPath $resolvedStatePath) {
        try {
            $savedState = Get-Content -LiteralPath $resolvedStatePath -Raw |
                ConvertFrom-Json -AsHashtable
        }
        catch {
            throw 'State: expected a non-secret JSON state object. The existing file was not changed.'
        }
        if ($savedState -isnot [System.Collections.IDictionary] -or
            (@($savedState.Keys | Sort-Object) -join ',') -ne 'configurationHash,phases,schemaVersion' -or
            $savedState.schemaVersion -ne 1 -or $savedState.configurationHash -ne $configurationHash -or
            $savedState.phases -isnot [array] -or $savedState.phases.Count -ne $phases.Count) {
            throw 'State: invalid schema or configuration mismatch. Use a separate state file for this configuration; the existing file was not changed.'
        }
        for ($index = 0; $index -lt $phases.Count; $index++) {
            $savedPhase = $savedState.phases[$index]
            if ($savedPhase -isnot [System.Collections.IDictionary] -or
                (@($savedPhase.Keys | Sort-Object) -join ',') -ne 'id,status' -or
                $savedPhase.id -cne $phases[$index].Id -or $savedPhase.status -cnotin @('Pending', 'Completed')) {
                throw 'State: unexpected phase fields, order, or status. Only non-secret phase metadata is allowed; the existing file was not changed.'
            }
        }
        $state = $savedState
    }
    else {
        $parentPath = Split-Path -Parent $resolvedStatePath
        New-Item -Path $parentPath -ItemType Directory -Force | Out-Null
        $temporaryStatePath = Join-Path $parentPath ".$([IO.Path]::GetFileName($resolvedStatePath)).$([guid]::NewGuid()).tmp"
        try {
            $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporaryStatePath -Encoding utf8
            Move-Item -LiteralPath $temporaryStatePath -Destination $resolvedStatePath
        }
        finally {
            if (Test-Path -LiteralPath $temporaryStatePath) {
                Remove-Item -LiteralPath $temporaryStatePath
            }
        }
    }
}
for ($index = 0; $index -lt $phases.Count; $index++) {
    $phases[$index].SavedStatus = $state.phases[$index].status
    $phases[$index].NeedsRevalidation = $state.phases[$index].status -eq 'Completed'
}

$cloudChangesMade = $false
if ($Mode -eq 'DeployFoundation') {
    $remediation = 'Inspect Azure Policy, resource providers, quota, deployment errors, and operator permissions. Fix the reported cause and rerun DeployFoundation; later phases have not run.'
    $scope = @('--subscription', $configuration.subscriptionId, '--output', 'json')
    $groupExists = Invoke-AzureJson -Arguments (@('group', 'exists', '--name', $names.resourceGroup) + $scope) `
        -Phase 'Azure foundation' -Remediation $remediation
    if ($groupExists -isnot [bool]) {
        throw 'Azure foundation: group exists must return a Boolean; no cloud changes were made.'
    }
    $existingResources = @()
    if ($groupExists) {
        $existingGroup = Invoke-AzureJson -Arguments (@('group', 'show', '--name', $names.resourceGroup) + $scope) `
            -Phase 'Azure foundation' -Remediation $remediation
        Assert-FoundationProperties -Resource $existingGroup -Expected @{
            name = $names.resourceGroup; location = $configuration.location
            'tags.inventory-sync-installation' = $suffix; 'tags.inventory-sync-workload' = $stem
        }
        $existingResources = Invoke-AzureJson -Arguments (@(
            'resource', 'list', '--resource-group', $names.resourceGroup
        ) + $scope) -Phase 'Azure foundation' -Remediation $remediation
        if ($existingResources -isnot [array]) {
            throw 'Azure foundation: resource list must return an array; no cloud changes were made.'
        }
        $foundationNames = @{
            'Microsoft.Storage/storageAccounts' = $names.storage
            'Microsoft.KeyVault/vaults' = $names.keyVault
            'Microsoft.OperationalInsights/workspaces' = $names.logAnalytics
            'Microsoft.Insights/components' = $names.applicationInsights
        }
        foreach ($existingResource in $existingResources) {
            if ($existingResource.type -notin $foundationNames.Keys -and
                $existingResource.name -notin $foundationNames.Values) { continue }
            if (-not $foundationNames.Contains($existingResource.type) -or
                $existingResource.name -ne $foundationNames[$existingResource.type]) {
                throw 'Azure foundation: ambiguous resource name or type in the dedicated group. Resolve the conflict before retrying; no cloud changes were made.'
            }
            $id = "/subscriptions/$($configuration.subscriptionId)/resourceGroups/$($names.resourceGroup)/providers/$($existingResource.type)/$($existingResource.name)"
            Assert-FoundationProperties -Resource $existingResource -Expected @{
                id = $id; location = $configuration.location
                'tags.inventory-sync-installation' = $suffix; 'tags.inventory-sync-workload' = $stem
            }
            $details = Invoke-AzureJson -Arguments (@('resource', 'show', '--ids', $id) + $scope) `
                -Phase 'Azure foundation' -Remediation $remediation
            $compatibleProperties = switch ($existingResource.type) {
                'Microsoft.Storage/storageAccounts' { @{
                    kind = 'StorageV2'; 'sku.name' = 'Standard_LRS'
                } }
                'Microsoft.KeyVault/vaults' { @{
                    'properties.tenantId' = $TenantId; 'properties.enableRbacAuthorization' = $true
                    'properties.softDeleteRetentionInDays' = 90
                } }
                'Microsoft.Insights/components' { @{
                    'properties.WorkspaceResourceId' = "/subscriptions/$($configuration.subscriptionId)/resourceGroups/$($names.resourceGroup)/providers/Microsoft.OperationalInsights/workspaces/$($names.logAnalytics)"
                } }
                default { @{} }
            }
            Assert-FoundationProperties -Resource $details -Expected $compatibleProperties
        }
    }
    foreach ($resourceName in @($names.storage, $names.keyVault)) {
        if (@($existingResources | Where-Object name -eq $resourceName).Count -gt 0) { continue }
        if ($resourceName -eq $names.storage) {
            $availability = Invoke-AzureJson -Arguments (@(
                'storage', 'account', 'check-name', '--name', $resourceName
            ) + $scope) -Phase 'Azure foundation' -Remediation $remediation
        }
        else {
            $requestPath = Join-Path ([IO.Path]::GetTempPath()) "inventory-vault-name-$([guid]::NewGuid()).json"
            try {
                @{ name = $resourceName; type = 'Microsoft.KeyVault/vaults' } |
                    ConvertTo-Json -Compress | Set-Content -LiteralPath $requestPath -Encoding utf8
                $availability = Invoke-AzureJson -Arguments (@(
                    'rest', '--method', 'post', '--url',
                    "/subscriptions/$($configuration.subscriptionId)/providers/Microsoft.KeyVault/checkNameAvailability?api-version=2024-11-01",
                    '--body', "@$requestPath"
                ) + $scope) `
                -Phase 'Azure foundation' -Remediation $remediation
            }
            finally {
                if (Test-Path -LiteralPath $requestPath) { Remove-Item -LiteralPath $requestPath }
            }
        }
        if ($availability -isnot [System.Collections.IDictionary] -or
            -not $availability.Contains('nameAvailable') -or $availability.nameAvailable -isnot [bool]) {
            throw 'Azure foundation: invalid name availability response; no cloud changes were made. Verify Azure CLI and provider registration before retrying.'
        }
        if (-not $availability.nameAvailable) {
            throw 'Azure foundation: a deterministic global name is unavailable (including a possible soft-deleted vault). Resolve name ownership or use a different workloadName; no cloud changes were made.'
        }
    }
    if (-not $groupExists) {
        $groupDeployment = Invoke-AzureJson -Arguments (@(
            'deployment', 'sub', 'create', '--name', "inventory-group-$suffix",
            '--location', $configuration.location,
            '--template-file', (Join-Path $PSScriptRoot 'foundation-group.bicep'),
            '--parameters', "resourceGroupName=$($names.resourceGroup)",
            "location=$($configuration.location)", "installationId=$suffix", "workloadName=$stem"
        ) + $scope) -Phase 'Azure foundation' -Remediation $remediation
        $cloudChangesMade = $true
        if ($groupDeployment.properties.provisioningState -ne 'Succeeded') {
            throw "Azure foundation: resource group deployment did not reach Succeeded. $remediation"
        }
    }
    $deploymentArguments = @(
        '--resource-group', $names.resourceGroup, '--name', "inventory-foundation-$suffix",
        '--template-file', (Join-Path $PSScriptRoot 'foundation.bicep'),
        '--mode', 'Incremental', '--parameters',
        "tenantId=$TenantId", "storageName=$($names.storage)", "keyVaultName=$($names.keyVault)",
        "logAnalyticsName=$($names.logAnalytics)", "applicationInsightsName=$($names.applicationInsights)",
        "location=$($configuration.location)", "installationId=$suffix", "workloadName=$stem",
        "logRetentionDays=$($configuration.logRetentionDays)"
    ) + $scope
    Invoke-AzureJson -Arguments (@('deployment', 'group', 'validate') + $deploymentArguments) `
        -Phase 'Azure foundation' -Remediation $remediation | Out-Null
    $deployment = Invoke-AzureJson -Arguments (@('deployment', 'group', 'create') + $deploymentArguments) `
        -Phase 'Azure foundation' -Remediation $remediation
    $cloudChangesMade = $true
    if ($deployment.properties.provisioningState -ne 'Succeeded') {
        throw "Azure foundation: deployment did not reach Succeeded. $remediation"
    }
    $group = Invoke-AzureJson -Arguments (@('group', 'show', '--name', $names.resourceGroup) + $scope) `
        -Phase 'Azure foundation' -Remediation $remediation
    Assert-FoundationProperties -Resource $group -Expected @{
        name = $names.resourceGroup; location = $configuration.location
        'tags.inventory-sync-installation' = $suffix; 'tags.inventory-sync-workload' = $stem
    }
    $foundationResources = @(
        @{ Name = $names.storage; Type = 'Microsoft.Storage/storageAccounts'; Properties = @{
            kind = 'StorageV2'; 'sku.name' = 'Standard_LRS'
            'properties.allowBlobPublicAccess' = $false; 'properties.supportsHttpsTrafficOnly' = $true
            'properties.minimumTlsVersion' = 'TLS1_2'; 'properties.publicNetworkAccess' = 'Enabled'
            'properties.networkAcls.defaultAction' = 'Allow'
        } }
        @{ Name = $names.keyVault; Type = 'Microsoft.KeyVault/vaults'; Properties = @{
            'properties.tenantId' = $TenantId; 'properties.sku.name' = 'standard'
            'properties.sku.family' = 'A'; 'properties.enableRbacAuthorization' = $true
            'properties.enableSoftDelete' = $true; 'properties.enablePurgeProtection' = $true
            'properties.softDeleteRetentionInDays' = 90; 'properties.publicNetworkAccess' = 'Enabled'
            'properties.networkAcls.defaultAction' = 'Allow'
        } }
        @{ Name = $names.logAnalytics; Type = 'Microsoft.OperationalInsights/workspaces'; Properties = @{
            'properties.sku.name' = 'PerGB2018'; 'properties.retentionInDays' = $configuration.logRetentionDays
            'properties.publicNetworkAccessForIngestion' = 'Enabled'; 'properties.publicNetworkAccessForQuery' = 'Enabled'
        } }
        @{ Name = $names.applicationInsights; Type = 'Microsoft.Insights/components'; Properties = @{
            kind = 'web'; 'properties.Application_Type' = 'web'
            'properties.WorkspaceResourceId' = "/subscriptions/$($configuration.subscriptionId)/resourceGroups/$($names.resourceGroup)/providers/Microsoft.OperationalInsights/workspaces/$($names.logAnalytics)"
            'properties.publicNetworkAccessForIngestion' = 'Enabled'; 'properties.publicNetworkAccessForQuery' = 'Enabled'
        } }
    )
    foreach ($definition in $foundationResources) {
        $id = "/subscriptions/$($configuration.subscriptionId)/resourceGroups/$($names.resourceGroup)/providers/$($definition.Type)/$($definition.Name)"
        $resource = Invoke-AzureJson -Arguments (@('resource', 'show', '--ids', $id) + $scope) `
            -Phase 'Azure foundation' -Remediation $remediation
        $expected = @{
            id = $id; name = $definition.Name; type = $definition.Type; location = $configuration.location
            'tags.inventory-sync-installation' = $suffix; 'tags.inventory-sync-workload' = $stem
            'properties.provisioningState' = 'Succeeded'
        }
        foreach ($key in $definition.Properties.Keys) { $expected[$key] = $definition.Properties[$key] }
        Assert-FoundationProperties -Resource $resource -Expected $expected
    }
    for ($index = 0; $index -lt 2; $index++) {
        $phases[$index].Status = 'Completed'
        $phases[$index].NeedsRevalidation = $false
        $state.phases[$index].status = 'Completed'
    }
    if ($StatePath) {
        $temporaryStatePath = "$resolvedStatePath.$([guid]::NewGuid()).tmp"
        try {
            $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporaryStatePath -Encoding utf8
            Move-Item -LiteralPath $temporaryStatePath -Destination $resolvedStatePath -Force
        }
        finally {
            if (Test-Path -LiteralPath $temporaryStatePath) { Remove-Item -LiteralPath $temporaryStatePath }
        }
    }
}

[pscustomobject] @{
    SchemaVersion = 1
    Mode = $Mode
    Status = $(if ($Mode -eq 'DeployFoundation') { 'FoundationValidated' } else { 'PlanValidated' })
    CloudChangesMade = $cloudChangesMade
    DeploymentImplemented = $false
    FoundationDeploymentImplemented = $true
    AzureContext = $azureContext
    DeploymentMode = 'Incremental'
    Configuration = $configuration
    ResourceNames = $names
    Resources = @{
        resourceGroup = @{ name = $names.resourceGroup; location = $configuration.location }
        storage = @{
            name = $names.storage; sku = 'Standard_LRS'; kind = 'StorageV2'
            allowBlobPublicAccess = $false; publicNetworkAccess = 'Enabled'
            supportsHttpsTrafficOnly = $true; minimumTlsVersion = 'TLS1_2'
        }
        keyVault = @{ enableRbacAuthorization = $true; publicNetworkAccess = 'Enabled' }
        logAnalytics = @{ name = $names.logAnalytics; retentionInDays = $configuration.logRetentionDays }
        applicationInsights = @{ name = $names.applicationInsights; workspace = $names.logAnalytics }
        hostingPlan = @{ name = $names.hostingPlan; sku = 'FC1'; tier = 'FlexConsumption' }
        functionApp = @{
            name = $names.functionApp; runtime = 'powershell'; runtimeVersion = '7.6'
            operatingSystem = 'Linux'; identity = 'SystemAssigned'; plan = 'FlexConsumption'
            httpsOnly = $true; minimumTlsVersion = '1.2'
            instanceMemoryMB = $configuration.instanceMemoryMB
            maximumInstanceCount = $configuration.maximumInstanceCount
        }
    }
    ApplicationSettings = $settings
    Prerequisites = $prerequisites
    Compilation = $compilation
    Phases = $phases
    UnresolvedValues = @('INVENTORY_TENANT_ID', 'INVENTORY_CLIENT_ID', 'APPLICATIONINSIGHTS_CONNECTION_STRING')
    StateContract = @{
        SchemaVersion = 1
        PersistsSecrets = $false
        RevalidateBeforeResume = $true
        AllowedStatuses = @('Pending', 'Completed')
        AllowedFields = @('schemaVersion', 'configurationHash', 'phases')
        AllowedPhaseFields = @('id', 'status')
        ConfigurationHash = $configurationHash
    }
}

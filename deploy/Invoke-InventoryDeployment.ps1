#Requires -Version 7.6
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ConfigurationPath,

    [ValidateSet('Plan')]
    [string] $Mode = 'Plan',

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
    param([string[]] $Arguments, [string] $Remediation)
    $result = & $CommandRunner 'az' $Arguments
    if ($null -eq $result -or -not $result.Contains('ExitCode') -or -not $result.Contains('Output')) {
        throw 'Preflight: command runner must return ExitCode and Output.'
    }
    if ($result.ExitCode -ne 0) {
        throw "Preflight: az $($Arguments -join ' ') failed. $Remediation`n$($result.Output)"
    }
    return [string] $result.Output
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

[pscustomobject] @{
    SchemaVersion = 1
    Mode = $Mode
    Status = 'PlanValidated'
    CloudChangesMade = $false
    DeploymentImplemented = $false
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

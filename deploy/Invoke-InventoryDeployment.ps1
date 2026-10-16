#Requires -Version 7.6
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ConfigurationPath,

    [ValidateSet('Plan', 'DeployFoundation', 'DeployIdentity', 'DeployFunctions', 'DeployPowerPlatform')]
    [string] $Mode = 'Plan',

    [string] $TenantId,

    [string] $StatePath,

    [scriptblock] $CommandRunner = {
        param(
            [string] $Command,
            [string[]] $Arguments,
            [System.Collections.IDictionary] $SensitiveArguments
        )
        if ($SensitiveArguments -and $SensitiveArguments.Contains('Value')) {
            $subscription = $Arguments[[array]::IndexOf($Arguments, '--subscription') + 1]
            $vault = $Arguments[[array]::IndexOf($Arguments, '--vault-name') + 1]
            $secret = $Arguments[[array]::IndexOf($Arguments, '--name') + 1]
            $expires = [datetimeoffset] $Arguments[[array]::IndexOf($Arguments, '--expires') + 1]
            $tokenOutput = & $Command account get-access-token --resource https://vault.azure.net `
                --subscription $subscription --output json 2>&1
            if ($LASTEXITCODE -ne 0) {
                return @{ ExitCode = 1; Output = 'Key Vault token acquisition failed. Renew the Azure CLI interactive login.' }
            }
            $client = $null
            $request = $null
            $response = $null
            try {
                $token = ($tokenOutput -join "`n" | ConvertFrom-Json -AsHashtable).accessToken
                if (-not $token) { throw 'Missing access token.' }
                $secretTags = @{}
                for ($index = [array]::IndexOf($Arguments, '--tags') + 1;
                    $index -lt $Arguments.Count -and -not $Arguments[$index].StartsWith('--'); $index++) {
                    $parts = $Arguments[$index] -split '=', 2
                    $secretTags[$parts[0]] = $parts[1]
                }
                $handler = [System.Net.Http.HttpClientHandler]::new()
                $handler.AllowAutoRedirect = $false
                $client = [System.Net.Http.HttpClient]::new($handler)
                $client.Timeout = [timespan]::FromSeconds(100)
                $request = [System.Net.Http.HttpRequestMessage]::new(
                    [System.Net.Http.HttpMethod]::Put,
                    "https://$vault.vault.azure.net/secrets/${secret}?api-version=7.4"
                )
                $request.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new('Bearer', $token)
                $body = @{
                    value = $SensitiveArguments.Value
                    attributes = @{ enabled = $true; exp = $expires.ToUnixTimeSeconds() }
                    tags = $secretTags
                } | ConvertTo-Json -Compress -Depth 5
                $request.Content = [System.Net.Http.StringContent]::new($body, [Text.Encoding]::UTF8, 'application/json')
                $response = $client.SendAsync($request).GetAwaiter().GetResult()
                if (-not $response.IsSuccessStatusCode) {
                    return @{ ExitCode = 1; Output = "Key Vault returned HTTP $([int] $response.StatusCode) ($($response.StatusCode))." }
                }
                $document = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() |
                    ConvertFrom-Json -AsHashtable
                $metadata = @{
                    id = $document.id
                    attributes = @{
                        enabled = $document.attributes.enabled
                        expires = [datetimeoffset]::FromUnixTimeSeconds($document.attributes.exp).ToString('o')
                    }
                    tags = $document.tags
                }
                return @{ ExitCode = 0; Output = ($metadata | ConvertTo-Json -Depth 5 -Compress) }
            }
            catch {
                return @{ ExitCode = 1; Output = 'Key Vault secret write failed. Check network connectivity, vault data-plane permissions, and retained recovery metadata.' }
            }
            finally {
                if ($response) { $response.Dispose() }
                if ($request) { $request.Dispose() }
                if ($client) { $client.Dispose() }
                $token = $null
                $tokenOutput = $null
                $body = $null
                $document = $null
            }
        }
        $output = & $Command @Arguments 2>&1
        @{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
    },

    [scriptblock] $GraphRunner,

    [scriptblock] $DataverseRunner = {
        param([uri] $Uri, [string] $AccessToken)
        $response = Invoke-RestMethod -Method Get -Uri $Uri -Headers @{
            Authorization = "Bearer $AccessToken"
            Accept = 'application/json'
        } -ErrorAction Stop
        @{
            LogicalName = [string] $response.LogicalName
            EntitySetName = [string] $response.EntitySetName
        }
    },

    [scriptblock] $Clock = { [datetimeoffset]::UtcNow }
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Invoke-SensitiveAdapter {
    param([scriptblock] $Adapter, [object[]] $AdapterArguments, [string] $FailureMessage)
    $pipeline = [powershell]::Create()
    $callerErrors = $Error
    $previousErrors = @($callerErrors)
    $succeeded = $false
    $value = $null
    try {
        $null = $pipeline.AddScript({
            param($Adapter, $AdapterArguments)
            $ErrorActionPreference = 'Stop'
            $VerbosePreference = 'SilentlyContinue'
            $DebugPreference = 'SilentlyContinue'
            $PSNativeCommandUseErrorActionPreference = $false
            try {
                $value = & $Adapter @AdapterArguments 3>$null 4>$null 5>$null 6>$null
                @{ Succeeded = $true; Value = $value }
            }
            catch {
                @{ Succeeded = $false; Value = $null }
            }
        }).AddArgument($Adapter).AddArgument($AdapterArguments)
        $results = $pipeline.Invoke()
        if (-not $pipeline.HadErrors -and $results.Count -eq 1 -and $results[0].Succeeded) {
            $value = $results[0].Value
            $succeeded = $true
        }
    }
    catch {
        $succeeded = $false
    }
    finally {
        $pipeline.Dispose()
        # A caller-bound adapter can retain its original error-history scope.
        foreach ($record in @($callerErrors)) {
            if ($record -notin $previousErrors) { $callerErrors.Remove($record) }
        }
    }
    if (-not $succeeded) { throw $FailureMessage }
    return ,$value
}

function Invoke-ValidationCommand {
    param(
        [string[]] $Arguments,
        [string] $Remediation,
        [string] $Phase = 'Preflight',
        [System.Collections.IDictionary] $SensitiveArguments,
        [ValidateSet('az', 'func', 'pac')]
        [string] $Command = 'az',
        [switch] $SanitizeOutput
    )
    if ($SensitiveArguments -or $SanitizeOutput) {
        $result = Invoke-SensitiveAdapter -Adapter $CommandRunner `
            -AdapterArguments @($Command, $Arguments, $SensitiveArguments) `
            -FailureMessage "${Phase}: sensitive command failed. $Remediation"
    }
    else {
        $result = & $CommandRunner $Command $Arguments
    }
    if ($null -eq $result -or -not $result.Contains('ExitCode') -or -not $result.Contains('Output')) {
        throw "${Phase}: command runner must return ExitCode and Output."
    }
    $safeOutput = [string] $result.Output
    if ($SensitiveArguments) {
        foreach ($sensitiveValue in $SensitiveArguments.Values) {
            if ($sensitiveValue) {
                $safeOutput = $safeOutput.Replace([string] $sensitiveValue, '[REDACTED]')
            }
        }
    }
    if ($result.ExitCode -ne 0) {
        if ($SanitizeOutput) {
            throw "${Phase}: $Command command failed; output suppressed because it may contain credentials. $Remediation"
        }
        throw "${Phase}: $Command $($Arguments -join ' ') failed. $Remediation`n$safeOutput"
    }
    return $safeOutput
}

function Invoke-AzureJson {
    param(
        [string[]] $Arguments,
        [string] $Phase,
        [string] $Remediation,
        [System.Collections.IDictionary] $SensitiveArguments,
        [switch] $SanitizeOutput
    )
    $output = Invoke-ValidationCommand -Arguments $Arguments -Phase $Phase -Remediation $Remediation `
        -SensitiveArguments $SensitiveArguments -SanitizeOutput:$SanitizeOutput
    if ($SanitizeOutput) {
        return Invoke-SensitiveAdapter -Adapter {
            param($Json)
            ConvertFrom-Json -InputObject $Json -AsHashtable -NoEnumerate -ErrorAction Stop
        } -AdapterArguments @($output) -FailureMessage "${Phase}: invalid JSON response; output suppressed. $Remediation"
    }
    try {
        return ConvertFrom-Json -InputObject $output -AsHashtable -NoEnumerate
    }
    catch {
        throw "${Phase}: az $($Arguments -join ' ') returned invalid JSON. $Remediation"
    }
}

function Assert-FoundationProperties {
    param(
        [System.Collections.IDictionary] $Resource,
        [System.Collections.IDictionary] $Expected,
        [string] $Phase = 'Azure foundation'
    )
    foreach ($path in $Expected.Keys) {
        $actual = $Resource
        foreach ($segment in $path -split '\.') {
            if ($actual -isnot [System.Collections.IDictionary] -or -not $actual.Contains($segment)) {
                throw "${Phase}: resource validation failed for '$path'. Inspect the resource and the deployment before retrying."
            }
            $actual = $actual[$segment]
        }
        $expectedValue = $Expected[$path]
        $matches = if ($path -eq 'location' -and
            $actual -is [string] -and $expectedValue -is [string]) {
            ($actual -replace '\s', '') -eq ($expectedValue -replace '\s', '')
        }
        else {
            $actual -eq $expectedValue
        }
        if (-not $matches) {
            throw "${Phase}: incompatible resource: '$path' differs from the deployment contract. Resolve the conflict before retrying."
        }
    }
}

function Save-DeploymentState {
    param([System.Collections.IDictionary] $State, [string] $Path)
    $temporaryPath = "$Path.$([guid]::NewGuid()).tmp"
    try {
        $State | ConvertTo-Json -Depth 7 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath }
    }
}

function Invoke-DeploymentGraph {
    param([string] $Operation, [System.Collections.IDictionary] $Parameters)
    $VerbosePreference = 'SilentlyContinue'
    $DebugPreference = 'SilentlyContinue'
    if ($Operation -eq 'Connect') {
        Connect-MgGraph -TenantId $Parameters.TenantId -Scopes $Parameters.Scopes `
            -ContextScope Process -NoWelcome -ErrorAction Stop | Out-Null
        $context = Get-MgContext
        return @{
            TenantId = $context.TenantId
            AuthType = $context.AuthType
            Account = $context.Account
        }
    }
    $root = 'https://graph.microsoft.com/v1.0'
    $body = $null
    $method = 'GET'
    switch ($Operation) {
        'FindApplications' {
            $filter = [uri]::EscapeDataString("displayName eq '$($Parameters.DisplayName)'")
            $uri = "$root/applications?`$filter=$filter&`$select=id,appId,displayName,signInAudience,tags"
        }
        'CreateApplication' {
            $method = 'POST'
            $uri = "$root/applications"
            $body = @{
                displayName = $Parameters.DisplayName
                signInAudience = $Parameters.SignInAudience
                tags = $Parameters.Tags
            }
        }
        'FindServicePrincipals' {
            $filter = [uri]::EscapeDataString("appId eq '$($Parameters.AppId)'")
            $uri = "$root/servicePrincipals?`$filter=$filter&`$select=id,appId,appOwnerOrganizationId"
        }
        'CreateServicePrincipal' {
            $method = 'POST'
            $uri = "$root/servicePrincipals"
            $body = @{ appId = $Parameters.AppId }
        }
        'GetGlobalReaderRole' {
            $filter = [uri]::EscapeDataString("templateId eq '$($Parameters.TemplateId)'")
            $uri = "$root/roleManagement/directory/roleDefinitions?`$filter=$filter"
        }
        'FindRoleAssignments' {
            $filter = [uri]::EscapeDataString(
                "principalId eq '$($Parameters.PrincipalId)' and roleDefinitionId eq '$($Parameters.RoleDefinitionId)' and directoryScopeId eq '/'"
            )
            $uri = "$root/roleManagement/directory/roleAssignments?`$filter=$filter"
        }
        'AssignGlobalReader' {
            $method = 'POST'
            $uri = "$root/roleManagement/directory/roleAssignments"
            $body = @{
                principalId = $Parameters.PrincipalId
                roleDefinitionId = $Parameters.RoleDefinitionId
                directoryScopeId = '/'
            }
        }
        'CreatePassword' {
            $method = 'POST'
            $uri = "$root/applications/$($Parameters.ApplicationObjectId)/addPassword"
            $body = @{ passwordCredential = @{
                displayName = $Parameters.DisplayName
                endDateTime = $Parameters.EndDateTime
            } }
        }
        'GetPasswordCredentials' {
            $document = Invoke-MgGraphRequest -Method GET `
                -Uri "$root/applications/$($Parameters.ApplicationObjectId)?`$select=passwordCredentials" `
                -OutputType Hashtable -ErrorAction Stop -Verbose:$false -Debug:$false
            if ($document -isnot [System.Collections.IDictionary] -or
                -not $document.Contains('passwordCredentials') -or $document.passwordCredentials -isnot [array]) {
                throw 'Runtime credential: Microsoft Graph returned invalid application credential metadata.'
            }
            return $document.passwordCredentials
        }
        default { throw 'Runtime identity: unsupported Microsoft Graph operation.' }
    }
    if ($method -eq 'POST') {
        return Invoke-MgGraphRequest -Method POST -Uri $uri -Body ($body | ConvertTo-Json -Depth 5) `
            -OutputType Hashtable -ErrorAction Stop -Verbose:$false -Debug:$false
    }
    do {
        $page = Invoke-MgGraphRequest -Method GET -Uri $uri -OutputType Hashtable `
            -ErrorAction Stop -Verbose:$false -Debug:$false
        if ($page -isnot [System.Collections.IDictionary] -or -not $page.Contains('value') -or
            $page.value -isnot [array]) {
            throw 'Runtime identity: Microsoft Graph returned an invalid collection.'
        }
        $page.value
        $uri = if ($page.Contains('@odata.nextLink')) { $page['@odata.nextLink'] } else { $null }
        if ($uri -and -not ([string] $uri).StartsWith("$root/", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Runtime identity: Microsoft Graph returned an unexpected pagination URL.'
        }
    } while ($uri)
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
if ($Mode -eq 'DeployPowerPlatform' -and
    ($configuration.agentTimerEnabled -or $configuration.rpaTimerEnabled)) {
    throw 'Readiness validation: timers must remain disabled until every manual readiness check and the capped smoke run are confirmed. Set both timer inputs to false and retry DeployPowerPlatform.'
}
$azureContext = $null
if ($Mode -in @('DeployFoundation', 'DeployIdentity', 'DeployFunctions', 'DeployPowerPlatform')) {
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
    if ($Mode -in @('DeployFunctions', 'DeployPowerPlatform')) {
        if (-not $prerequisites[1].Available) {
            throw "Function deployment: Functions Core Tools v4 is missing. $($prerequisites[1].Guidance)"
        }
        $coreToolsVersion = Invoke-ValidationCommand -Command func -Arguments @('--version') `
            -Phase 'Function deployment' -SanitizeOutput `
            -Remediation 'Install Functions Core Tools v4 explicitly before retrying DeployFunctions.'
        if ($coreToolsVersion.Trim() -notmatch '^4\.\d+\.\d+(?:[-+][^\s]+)?$') {
            throw 'Function deployment: Functions Core Tools v4 is required. Upgrade the installed tool explicitly before retrying.'
        }
        if ($configuration.agentCreatedIn -match '[<>]') {
            throw 'Function deployment: replace the agentCreatedIn placeholder with the tenant authoring-tool value before deploying.'
        }
    }
    if ($Mode -eq 'DeployPowerPlatform') {
        if (-not $prerequisites[2].Available -and -not $PSBoundParameters.ContainsKey('CommandRunner')) {
            throw "Logging solution: Power Platform CLI is missing. $($prerequisites[2].Guidance)"
        }
        Invoke-ValidationCommand -Command pac -Arguments @('help') -Phase 'Logging solution' `
            -Remediation 'Verify that Power Platform CLI can run in this PowerShell session before retrying DeployPowerPlatform.' |
            Out-Null
    }
    if ($Mode -in @('DeployIdentity', 'DeployFunctions', 'DeployPowerPlatform')) {
        if (-not $StatePath) {
            throw 'Runtime identity: DeployIdentity requires -StatePath so non-secret recovery metadata can be retained.'
        }
        if (-not $GraphRunner) {
            if (-not $prerequisites[3].Available) {
                throw "Runtime identity: Microsoft Graph PowerShell is missing. $($prerequisites[3].Guidance)"
            }
            $GraphRunner = ${function:Invoke-DeploymentGraph}
        }
        $graphContext = & $GraphRunner 'Connect' @{
            TenantId = $TenantId
            Scopes = @('Application.ReadWrite.All', 'RoleManagement.ReadWrite.Directory')
        }
        if ($graphContext -isnot [System.Collections.IDictionary] -or
            -not $graphContext.Contains('TenantId') -or -not $graphContext.Contains('AuthType') -or
            -not $graphContext.Contains('Account')) {
            throw 'Runtime identity: Microsoft Graph returned an invalid authentication context. Sign in interactively and retry.'
        }
        if ($graphContext.AuthType -ne 'Delegated' -or -not $graphContext.Account) {
            throw 'Runtime identity: Microsoft Graph requires an interactively authenticated delegated user.'
        }
        if ($graphContext.TenantId -ne $TenantId) {
            throw 'Runtime identity: Graph tenant mismatch. Reconnect Microsoft Graph interactively to the Azure deployment tenant.'
        }
        Write-Information "Microsoft Graph context: tenant $($graphContext.TenantId), operator $($graphContext.Account)." -InformationAction Continue
    }
}
$settings = [ordered] @{
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
        $savedStateFields = if ($savedState -is [System.Collections.IDictionary]) {
            @($savedState.Keys | Sort-Object) -join ','
        }
        else { '' }
        if ($savedState -isnot [System.Collections.IDictionary] -or
            $savedStateFields -notin @(
                'configurationHash,phases,schemaVersion',
                'configurationHash,identity,phases,schemaVersion'
            ) -or
            $savedState.schemaVersion -ne 1 -or $savedState.configurationHash -ne $configurationHash -or
            $savedState.phases -isnot [array] -or $savedState.phases.Count -ne $phases.Count) {
            throw 'State: invalid schema or configuration mismatch. Use a separate state file for this configuration; the existing file was not changed.'
        }
        if ($savedState.Contains('identity')) {
            $savedIdentity = $savedState.identity
            if ($savedIdentity -isnot [System.Collections.IDictionary] -or
                (@($savedIdentity.Keys | Sort-Object) -join ',') -ne
                    'applicationId,applicationObjectId,credential,globalReaderAssignmentId,servicePrincipalId') {
                throw 'State: invalid non-secret identity recovery metadata. The existing file was not changed.'
            }
            foreach ($field in @('applicationId', 'applicationObjectId', 'servicePrincipalId')) {
                if ($savedIdentity[$field] -isnot [string] -or
                    $savedIdentity[$field] -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' -or
                    [guid] $savedIdentity[$field] -eq [guid]::Empty) {
                    throw 'State: invalid identity ID in non-secret recovery metadata. The existing file was not changed.'
                }
            }
            if ($savedIdentity.globalReaderAssignmentId -isnot [string] -or
                $savedIdentity.globalReaderAssignmentId -notmatch '^[a-zA-Z0-9_-]{1,256}$') {
                throw 'State: invalid directory-role assignment ID in non-secret recovery metadata. The existing file was not changed.'
            }
            if ($null -ne $savedIdentity.credential -and (
                $savedIdentity.credential -isnot [System.Collections.IDictionary] -or
                (@($savedIdentity.credential.Keys | Sort-Object) -join ',') -ne
                    'expiresOn,keyId,keyVaultSecretVersion,status' -or
                $savedIdentity.credential.status -notin @('Stored', 'PendingKeyVaultWrite'))) {
                throw 'State: invalid non-secret credential recovery metadata. The existing file was not changed.'
            }
            if ($null -ne $savedIdentity.credential) {
                $savedCredential = $savedIdentity.credential
                if (($null -ne $savedCredential.keyId -and (
                    $savedCredential.keyId -isnot [string] -or
                    $savedCredential.keyId -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$')) -or
                    ($null -ne $savedCredential.keyVaultSecretVersion -and (
                    $savedCredential.keyVaultSecretVersion -isnot [string] -or
                    $savedCredential.keyVaultSecretVersion -notmatch '^[a-zA-Z0-9-]{1,64}$'))) {
                    throw 'State: invalid credential ID in non-secret recovery metadata. The existing file was not changed.'
                }
                try { $null = [datetimeoffset] $savedCredential.expiresOn }
                catch { throw 'State: invalid credential expiry metadata. The existing file was not changed.' }
            }
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
if ($Mode -in @('DeployFoundation', 'DeployIdentity', 'DeployFunctions', 'DeployPowerPlatform')) {
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
        $vaultOmitsOpenNetworkAcls = $definition.Type -eq 'Microsoft.KeyVault/vaults' -and
            $resource.properties -is [System.Collections.IDictionary] -and
            -not $resource.properties.Contains('networkAcls')
        foreach ($key in $definition.Properties.Keys) {
            # Key Vault omits networkAcls when public access is enabled with the default Allow policy.
            if ($vaultOmitsOpenNetworkAcls -and $key -eq 'properties.networkAcls.defaultAction') { continue }
            $expected[$key] = $definition.Properties[$key]
        }
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

$runtimeIdentity = $null
if ($Mode -in @('DeployIdentity', 'DeployFunctions', 'DeployPowerPlatform')) {
    $identityRemediation = 'Verify Microsoft Graph permissions, directory-role privileges, and tenant context, then rerun DeployIdentity.'
    $ownershipTag = "InventorySyncInstallation:$suffix"
    $applicationCandidates = @(& $GraphRunner 'FindApplications' @{
        DisplayName = $names.appRegistration
    })
    if ($applicationCandidates.Count -gt 1) {
        throw "Runtime identity: multiple app registrations use the managed display name. Remove the ambiguity before retrying. $identityRemediation"
    }
    if ($state.Contains('identity') -and (
        $applicationCandidates.Count -ne 1 -or
        $applicationCandidates[0].Id -ne $state.identity.applicationObjectId -or
        $applicationCandidates[0].AppId -ne $state.identity.applicationId)) {
        throw 'Runtime identity: the saved application is missing or changed. Restore the managed identity before retrying; it will not be replaced implicitly.'
    }
    if ($applicationCandidates.Count -eq 0) {
        $application = & $GraphRunner 'CreateApplication' @{
            DisplayName = $names.appRegistration
            SignInAudience = 'AzureADMyOrg'
            Tags = @($ownershipTag, "InventorySyncWorkload:$stem")
        }
        $cloudChangesMade = $true
    }
    else {
        $application = $applicationCandidates[0]
    }
    if ($application -isnot [System.Collections.IDictionary] -or
        -not $application.Contains('Id') -or -not $application.Contains('AppId') -or
        -not $application.Contains('DisplayName') -or -not $application.Contains('SignInAudience') -or
        -not $application.Contains('Tags')) {
        $applicationType = if ($null -eq $application) { 'null' } else { $application.GetType().FullName }
        $applicationFields = if ($application -is [System.Collections.IDictionary]) {
            @($application.Keys | Sort-Object) -join ','
        }
        else { 'none' }
        throw "Runtime identity: Microsoft Graph returned an invalid app registration (type '$applicationType', fields '$applicationFields'). $identityRemediation"
    }
    if ($application.DisplayName -ne $names.appRegistration -or
        $application.SignInAudience -ne 'AzureADMyOrg') {
        throw "Runtime identity: the app registration is incompatible with the deployment contract. $identityRemediation"
    }
    if ($ownershipTag -notin @($application.Tags)) {
        throw "Runtime identity: the app registration is not bootstrap-managed. $identityRemediation"
    }

    $servicePrincipalCandidates = @(& $GraphRunner 'FindServicePrincipals' @{
        AppId = $application.AppId
    })
    if ($servicePrincipalCandidates.Count -gt 1) {
        throw "Runtime identity: multiple service principals match the managed application. Remove the ambiguity before retrying. $identityRemediation"
    }
    if ($state.Contains('identity') -and (
        $servicePrincipalCandidates.Count -ne 1 -or
        $servicePrincipalCandidates[0].Id -ne $state.identity.servicePrincipalId)) {
        throw 'Runtime identity: the saved service principal is missing or changed. Restore it before retrying; it will not be replaced implicitly.'
    }
    if ($servicePrincipalCandidates.Count -eq 0) {
        $servicePrincipal = & $GraphRunner 'CreateServicePrincipal' @{ AppId = $application.AppId }
        $cloudChangesMade = $true
    }
    else {
        $servicePrincipal = $servicePrincipalCandidates[0]
    }
    if ($servicePrincipal -isnot [System.Collections.IDictionary] -or
        -not $servicePrincipal.Contains('Id') -or -not $servicePrincipal.Contains('AppId') -or
        $servicePrincipal.AppId -ne $application.AppId) {
        throw "Runtime identity: Microsoft Graph returned an invalid service principal. $identityRemediation"
    }

    $globalReaderRole = & $GraphRunner 'GetGlobalReaderRole' @{
        TemplateId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
    }
    if ($globalReaderRole -isnot [System.Collections.IDictionary] -or
        -not $globalReaderRole.Contains('Id') -or -not $globalReaderRole.Contains('TemplateId') -or
        $globalReaderRole.TemplateId -ne 'f2ef992c-3afb-46b9-b7cf-a126ee74c451') {
        throw "Runtime identity: Microsoft Graph did not return the Global Reader role definition. $identityRemediation"
    }
    $roleAssignments = @(& $GraphRunner 'FindRoleAssignments' @{
        PrincipalId = $servicePrincipal.Id
        RoleDefinitionId = $globalReaderRole.Id
        DirectoryScopeId = '/'
    })
    if ($roleAssignments.Count -gt 1) {
        throw "Runtime identity: multiple tenant-scope Global Reader assignments match the managed service principal. $identityRemediation"
    }
    $savedAssignmentId = if ($state.Contains('identity')) { $state.identity.globalReaderAssignmentId } else { $null }
    $roleAssignment = if ($savedAssignmentId) { @{ Id = $savedAssignmentId } } else { $null }
    if ($roleAssignments.Count -eq 0 -and -not $savedAssignmentId) {
        try {
            $roleAssignment = & $GraphRunner 'AssignGlobalReader' @{
                PrincipalId = $servicePrincipal.Id
                RoleDefinitionId = $globalReaderRole.Id
                DirectoryScopeId = '/'
            }
        }
        catch {
            throw "Runtime identity: Global Reader assignment failed. $identityRemediation $($_.Exception.Message)"
        }
        if ($roleAssignment -isnot [System.Collections.IDictionary] -or
            -not $roleAssignment.Contains('Id')) {
            throw "Runtime identity: Microsoft Graph returned an invalid Global Reader assignment. $identityRemediation"
        }
        $cloudChangesMade = $true
        $roleAssignments = @(& $GraphRunner 'FindRoleAssignments' @{
            PrincipalId = $servicePrincipal.Id
            RoleDefinitionId = $globalReaderRole.Id
            DirectoryScopeId = '/'
        })
    }
    if ($roleAssignments.Count -ne 1) {
        $savedCredential = if ($state.Contains('identity')) { $state.identity.credential } else { $null }
        $state['identity'] = [ordered] @{
            applicationObjectId = $application.Id
            applicationId = $application.AppId
            servicePrincipalId = $servicePrincipal.Id
            globalReaderAssignmentId = $roleAssignment.Id
            credential = $savedCredential
        }
        $state.phases[2].status = 'Pending'
        $state.phases[3].status = 'Pending'
        Save-DeploymentState -State $state -Path $resolvedStatePath
        throw 'Runtime identity: Global Reader assignment is pending propagation or the saved assignment was removed. Wait several minutes and rerun DeployIdentity; if it remains missing, have a directory-role administrator inspect and restore the saved assignment. No credential was created.'
    }
    $roleAssignment = $roleAssignments[0]
    if ($roleAssignment -isnot [System.Collections.IDictionary] -or
        -not $roleAssignment.Contains('Id') -or -not $roleAssignment.Contains('PrincipalId') -or
        -not $roleAssignment.Contains('RoleDefinitionId') -or -not $roleAssignment.Contains('DirectoryScopeId') -or
        $roleAssignment.PrincipalId -ne $servicePrincipal.Id -or
        $roleAssignment.RoleDefinitionId -ne $globalReaderRole.Id -or
        $roleAssignment.DirectoryScopeId -ne '/') {
        throw "Runtime identity: Global Reader assignment did not validate at tenant scope. $identityRemediation"
    }

    $secretName = 'inventory-sync-client-secret'
    $secretMetadata = Invoke-AzureJson -Arguments @(
        'keyvault', 'secret', 'list', '--vault-name', $names.keyVault,
        '--query', "[?name=='$secretName'].{id:id,attributes:attributes,tags:tags}",
        '--subscription', $configuration.subscriptionId, '--output', 'json'
    ) -Phase 'Runtime credential' `
        -Remediation 'Verify Key Vault data-plane permissions and inspect the managed secret metadata before retrying.'
    if ($secretMetadata -isnot [array] -or $secretMetadata.Count -gt 1) {
        throw 'Runtime credential: Key Vault returned invalid or ambiguous secret metadata.'
    }
    $secretVersions = @()
    if ($secretMetadata.Count -eq 1) {
        $currentSecret = $secretMetadata[0]
        if ($currentSecret -isnot [System.Collections.IDictionary] -or
            -not $currentSecret.Contains('attributes') -or
            $currentSecret.attributes -isnot [System.Collections.IDictionary] -or
            -not $currentSecret.attributes.Contains('enabled') -or
            $currentSecret.attributes.enabled -isnot [bool]) {
            throw 'Runtime credential: Key Vault returned invalid enabled metadata. No credential was replaced.'
        }
        if (-not $currentSecret.attributes.enabled) {
            throw 'Runtime credential: the current managed secret is disabled or expired. Restore it or use explicit credential rotation; DeployIdentity never rotates implicitly.'
        }
        $secretVersions = Invoke-AzureJson -Arguments @(
            'keyvault', 'secret', 'list-versions', '--vault-name', $names.keyVault,
            '--name', $secretName, '--query',
            '[].{id:id,attributes:{enabled:attributes.enabled,expires:attributes.expires},tags:tags}',
            '--subscription', $configuration.subscriptionId, '--output', 'json'
        ) -Phase 'Runtime credential' `
            -Remediation 'Verify Key Vault data-plane permissions and inspect the managed secret metadata before retrying.'
        if ($secretVersions -isnot [array] -or $secretVersions.Count -eq 0) {
            throw 'Runtime credential: an existing secret has no readable versions. Inspect the vault before retrying; no password was created.'
        }
        foreach ($version in $secretVersions) {
            if ($version -isnot [System.Collections.IDictionary] -or
                -not $version.Contains('attributes') -or $version.attributes -isnot [System.Collections.IDictionary] -or
                -not $version.attributes.Contains('enabled') -or $version.attributes.enabled -isnot [bool]) {
                throw 'Runtime credential: Key Vault returned invalid enabled metadata. No credential was replaced.'
            }
        }
        $secretVersions = @($secretVersions | Where-Object { $_.attributes.enabled })
        if ($secretVersions.Count -eq 0) {
            throw 'Runtime credential: no enabled managed secret version is available. Inspect Key Vault; no credential was replaced.'
        }
    }
    if ($secretVersions.Count -gt 1) {
        throw 'Runtime credential: multiple enabled managed Key Vault secret versions are ambiguous. Disable stale versions before retrying.'
    }

    $credentialKeyId = $null
    if ($secretVersions.Count -eq 0) {
        if ($state.Contains('identity') -and
            $state.identity.credential -is [System.Collections.IDictionary] -and
            $state.identity.credential.status -eq 'PendingKeyVaultWrite') {
            throw 'Runtime credential: a previously created application password was not stored in Key Vault. Remove that password by the retained key ID, clear the pending credential metadata, and rerun; no duplicate password was created.'
        }
        $existingPasswords = @(& $GraphRunner 'GetPasswordCredentials' @{
            ApplicationObjectId = $application.Id
        } | Where-Object displayName -eq "$stem-keyvault")
        if ($existingPasswords.Count -gt 0) {
            $orphan = $existingPasswords[0]
            $state['identity'] = [ordered] @{
                applicationObjectId = $application.Id
                applicationId = $application.AppId
                servicePrincipalId = $servicePrincipal.Id
                globalReaderAssignmentId = $roleAssignment.Id
                credential = [ordered] @{
                    keyId = $orphan.keyId
                    expiresOn = $orphan.endDateTime
                    keyVaultSecretVersion = $null
                    status = 'PendingKeyVaultWrite'
                }
            }
            Save-DeploymentState -State $state -Path $resolvedStatePath
            throw 'Runtime credential: a managed application password already exists without a Key Vault secret. Inspect managed passwords and remove orphaned credentials using their key IDs before clearing pending credential metadata and retrying; no duplicate was created.'
        }
        $credentialExpiry = [datetimeoffset]::FromUnixTimeSeconds((& $Clock).ToUnixTimeSeconds()).AddMonths(12)
        $requestedCredentialExpiry = $credentialExpiry
        $password = Invoke-SensitiveAdapter -Adapter $GraphRunner -AdapterArguments @(
            'CreatePassword', @{
                ApplicationObjectId = $application.Id
                DisplayName = "$stem-keyvault"
                EndDateTime = $credentialExpiry.ToString('o')
            }
        ) -FailureMessage "Runtime credential: application password creation failed or its outcome is unknown. Inspect credentials on application '$($application.Id)' before retrying; no Key Vault write was attempted."
        if ($password -isnot [System.Collections.IDictionary] -or
            -not $password.Contains('KeyId') -or -not $password.Contains('SecretText') -or
            -not $password.Contains('EndDateTime') -or -not $password.SecretText) {
            throw 'Runtime credential: Microsoft Graph returned invalid password metadata; no Key Vault write was attempted.'
        }
        $credentialKeyId = $password.KeyId
        $validCredentialExpiry = $true
        try { $credentialExpiry = ([datetimeoffset] $password.EndDateTime).ToUniversalTime() }
        catch { $validCredentialExpiry = $false }
        $state['identity'] = [ordered] @{
            applicationObjectId = $application.Id
            applicationId = $application.AppId
            servicePrincipalId = $servicePrincipal.Id
            globalReaderAssignmentId = $roleAssignment.Id
            credential = [ordered] @{
                keyId = $credentialKeyId
                expiresOn = $credentialExpiry
                keyVaultSecretVersion = $null
                status = 'PendingKeyVaultWrite'
            }
        }
        Save-DeploymentState -State $state -Path $resolvedStatePath
        if (-not $validCredentialExpiry -or $credentialExpiry -ne $requestedCredentialExpiry) {
            $password.SecretText = $null
            throw 'Runtime credential: Microsoft Graph returned unexpected credential expiry. Remove the password using the retained key ID and resolve the credential-lifetime policy before retrying; no Key Vault write was attempted.'
        }
        try {
            $secretValue = [string] $password.SecretText
            $secret = Invoke-AzureJson -Arguments @(
                'keyvault', 'secret', 'set', '--vault-name', $names.keyVault,
                '--name', $secretName, '--expires', $credentialExpiry.ToString('o'),
                '--tags', "inventory-sync-installation=$suffix", "application-id=$($application.AppId)",
                "credential-key-id=$credentialKeyId",
                '--query', '{id:id,attributes:{enabled:attributes.enabled,expires:attributes.expires},tags:tags}',
                '--subscription', $configuration.subscriptionId, '--output', 'json'
            ) -Phase 'Runtime credential' `
                -Remediation 'The application password was created but the Key Vault write failed. Use the retained key ID and expiry metadata to remove the orphaned password before retrying.' `
                -SensitiveArguments @{ Value = $secretValue }
        }
        finally {
            $secretValue = $null
            $password.SecretText = $null
        }
        if ($secret -isnot [System.Collections.IDictionary] -or
            -not $secret.Contains('id') -or -not $secret.Contains('attributes') -or
            $secret.attributes -isnot [System.Collections.IDictionary] -or
            -not $secret.attributes.Contains('expires')) {
            throw 'Runtime credential: Key Vault returned invalid non-secret metadata after writing the managed secret.'
        }
        $secretVersions = @($secret)
        $cloudChangesMade = $true
    }
    elseif ($secretVersions[0] -isnot [System.Collections.IDictionary] -or
        -not $secretVersions[0].Contains('id') -or -not $secretVersions[0].Contains('attributes') -or
        $secretVersions[0].attributes -isnot [System.Collections.IDictionary] -or
        -not $secretVersions[0].attributes.Contains('expires')) {
        throw 'Runtime credential: the enabled managed Key Vault secret version has invalid metadata.'
    }
    $secretRecord = $secretVersions[0]
    if (-not $secretRecord.Contains('tags') -or
        $secretRecord.tags -isnot [System.Collections.IDictionary] -or
        -not $secretRecord.tags.Contains('inventory-sync-installation') -or
        -not $secretRecord.tags.Contains('application-id') -or
        $secretRecord.tags['inventory-sync-installation'] -ne $suffix -or
        $secretRecord.tags['application-id'] -ne $application.AppId) {
        throw 'Runtime credential: Key Vault secret ownership does not match the managed installation and application. No existing credential was replaced.'
    }
    if (-not $secretRecord.attributes.Contains('enabled') -or
        $secretRecord.attributes.enabled -isnot [bool]) {
        throw 'Runtime credential: Key Vault returned invalid enabled metadata. No credential was replaced.'
    }
    try {
        if ($null -eq $secretRecord.attributes.expires) { throw 'Missing expiry.' }
        $storedExpiry = ([datetimeoffset] $secretRecord.attributes.expires).ToUniversalTime()
    }
    catch {
        throw 'Runtime credential: Key Vault returned invalid expiry metadata. No credential was replaced.'
    }
    if ($secretRecord.attributes.enabled -ne $true -or $storedExpiry -le (& $Clock).ToUniversalTime()) {
        throw 'Runtime credential: the managed secret is disabled or expired. Restore it or use explicit credential rotation; DeployIdentity never rotates implicitly.'
    }
    if ($secretRecord.tags.Contains('credential-key-id')) {
        $credentialKeyId = $secretRecord.tags['credential-key-id']
    }
    if ($state.Contains('identity') -and
        $state.identity.credential -is [System.Collections.IDictionary] -and
        $state.identity.credential.status -eq 'Stored') {
        $credentialKeyId = $state.identity.credential.keyId
    }
    $secretVersion = ($secretVersions[0].id -split '/')[-1]
    $identityState = [ordered] @{
        applicationObjectId = $application.Id
        applicationId = $application.AppId
        servicePrincipalId = $servicePrincipal.Id
        globalReaderAssignmentId = $roleAssignment.Id
        credential = [ordered] @{
            keyId = $credentialKeyId
            expiresOn = $storedExpiry
            keyVaultSecretVersion = $secretVersion
            status = 'Stored'
        }
    }
    $state['identity'] = $identityState
    for ($index = 2; $index -lt 4; $index++) {
        $phases[$index].Status = 'Completed'
        $phases[$index].NeedsRevalidation = $false
        $state.phases[$index].status = 'Completed'
    }
    Save-DeploymentState -State $state -Path $resolvedStatePath
    $runtimeIdentity = [pscustomobject] @{
        ApplicationObjectId = $application.Id
        ApplicationId = $application.AppId
        ServicePrincipalId = $servicePrincipal.Id
        GlobalReaderAssignmentId = $roleAssignment.Id
        Credential = [pscustomobject] @{
            KeyId = $credentialKeyId
            ExpiresOn = $storedExpiry
            KeyVaultSecretVersion = $secretVersion
        }
    }
    $settings.INVENTORY_TENANT_ID = $TenantId
    $settings.INVENTORY_CLIENT_ID = $application.AppId
}

$functionValidation = $null
if ($Mode -in @('DeployFunctions', 'DeployPowerPlatform')) {
    $phase = 'Function deployment'
    $functionRemediation = 'Inspect the managed Function deployment, Microsoft.Web registration, Flex region/runtime availability, and Azure RBAC permissions. Correct the cause and rerun DeployFunctions with the same state; do not enable timers in the portal.'
    $resourceRoot = "/subscriptions/$($configuration.subscriptionId)/resourceGroups/$($names.resourceGroup)/providers"
    $appId = "$resourceRoot/Microsoft.Web/sites/$($names.functionApp)"
    $planId = "$resourceRoot/Microsoft.Web/serverfarms/$($names.hostingPlan)"
    $storageId = "$resourceRoot/Microsoft.Storage/storageAccounts/$($names.storage)"
    $vaultId = "$resourceRoot/Microsoft.KeyVault/vaults/$($names.keyVault)"
    $runtimeNames = @{
        'Microsoft.Web/sites' = $names.functionApp
        'Microsoft.Web/serverfarms' = $names.hostingPlan
    }
    foreach ($existingResource in $existingResources) {
        if ($existingResource.type -notin $runtimeNames.Keys -and
            $existingResource.name -notin $runtimeNames.Values) { continue }
        if (-not $runtimeNames.Contains($existingResource.type) -or
            $existingResource.name -ne $runtimeNames[$existingResource.type]) {
            throw "Function deployment: ambiguous resource name or type in the dedicated group. $functionRemediation"
        }
        $expected = @{
            id = "$resourceRoot/$($existingResource.type)/$($existingResource.name)"
            location = $configuration.location
            'tags.inventory-sync-installation' = $suffix
            'tags.inventory-sync-workload' = $stem
        }
        Assert-FoundationProperties -Resource $existingResource -Expected $expected -Phase $phase
        $details = Invoke-AzureJson -Arguments (@('resource', 'show', '--ids', $expected.id) + $scope) `
            -Phase $phase -Remediation $functionRemediation -SanitizeOutput
        $compatible = if ($existingResource.type -eq 'Microsoft.Web/sites') {
            @{ kind = 'functionapp,linux'; 'properties.serverFarmId' = $planId }
        }
        else { @{ 'sku.name' = 'FC1'; 'properties.reserved' = $true } }
        Assert-FoundationProperties -Resource $details -Expected $compatible -Phase $phase
    }

    $state.phases[4].status = 'Pending'
    Save-DeploymentState -State $state -Path $resolvedStatePath
    # Publish and verify with timers disabled before applying an explicit IaC opt-in.
    $activationPasses = @($false)
    if ($configuration.agentTimerEnabled -or $configuration.rpaTimerEnabled) { $activationPasses += $true }
    foreach ($activateTimers in $activationPasses) {
        $parameterFile = Join-Path ([IO.Path]::GetTempPath()) "inventory-functions-$([guid]::NewGuid()).json"
        try {
            $runtimeSettings = [ordered] @{}
            foreach ($key in $settings.Keys) {
                if ($key -ne 'APPLICATIONINSIGHTS_CONNECTION_STRING') { $runtimeSettings[$key] = $settings[$key] }
            }
            if (-not $activateTimers) {
                $runtimeSettings['AzureWebJobs.AgentSyncTimer.Disabled'] = 'true'
                $runtimeSettings['AzureWebJobs.RpaSyncTimer.Disabled'] = 'true'
            }
            $functionParameters = @{
                storageName = $names.storage; keyVaultName = $names.keyVault
                applicationInsightsName = $names.applicationInsights
                hostingPlanName = $names.hostingPlan; functionAppName = $names.functionApp
                deploymentContainerName = $names.deploymentContainer
                location = $configuration.location; installationId = $suffix; workloadName = $stem
                applicationSettings = $runtimeSettings
                instanceMemoryMB = $configuration.instanceMemoryMB
                maximumInstanceCount = $configuration.maximumInstanceCount
            }
            $armParameters = @{}
            foreach ($key in $functionParameters.Keys) {
                $armParameters[$key] = @{ value = $functionParameters[$key] }
            }
            @{ parameters = $armParameters } | ConvertTo-Json -Depth 8 |
                Set-Content -LiteralPath $parameterFile -Encoding utf8
            $deploymentArguments = @(
                '--resource-group', $names.resourceGroup, '--name', "inventory-functions-$suffix",
                '--template-file', (Join-Path $PSScriptRoot 'functions.bicep'),
                '--mode', 'Incremental', '--parameters', "@$parameterFile"
            ) + $scope
            Invoke-AzureJson -Arguments (@('deployment', 'group', 'validate') + $deploymentArguments) `
                -Phase $phase -Remediation $functionRemediation -SanitizeOutput | Out-Null
            $deployment = Invoke-AzureJson -Arguments (@('deployment', 'group', 'create') + $deploymentArguments) `
                -Phase $phase -Remediation $functionRemediation -SanitizeOutput
            $cloudChangesMade = $true
            if ($deployment -isnot [System.Collections.IDictionary] -or -not $deployment.Contains('properties') -or
                $deployment.properties -isnot [System.Collections.IDictionary] -or
                -not $deployment.properties.Contains('provisioningState') -or
                $deployment.properties.provisioningState -ne 'Succeeded') {
                throw "Function deployment: infrastructure did not reach Succeeded. $functionRemediation"
            }
        }
        finally {
            if (Test-Path -LiteralPath $parameterFile) { Remove-Item -LiteralPath $parameterFile }
        }
        foreach ($id in @($planId, $appId)) {
            $resource = Invoke-AzureJson -Arguments (@('resource', 'show', '--ids', $id) + $scope) `
                -Phase $phase -Remediation $functionRemediation -SanitizeOutput
            $expected = @{
                id = $id; location = $configuration.location
                'tags.inventory-sync-installation' = $suffix; 'tags.inventory-sync-workload' = $stem
            }
            $properties = if ($id -eq $planId) {
                @{ 'sku.name' = 'FC1'; 'sku.tier' = 'FlexConsumption'; 'properties.reserved' = $true }
            }
            else {
                @{
                    kind = 'functionapp,linux'; 'identity.type' = 'SystemAssigned'
                    'properties.state' = 'Running'; 'properties.serverFarmId' = $planId
                    'properties.httpsOnly' = $true
                    'properties.functionAppConfig.runtime.name' = 'powershell'
                    'properties.functionAppConfig.runtime.version' = '7.6'
                    'properties.functionAppConfig.scaleAndConcurrency.instanceMemoryMB' = $configuration.instanceMemoryMB
                    'properties.functionAppConfig.scaleAndConcurrency.maximumInstanceCount' = $configuration.maximumInstanceCount
                    'properties.functionAppConfig.deployment.storage.type' = 'blobContainer'
                    'properties.functionAppConfig.deployment.storage.value' = "https://$($names.storage).blob.core.windows.net/$($names.deploymentContainer)"
                    'properties.functionAppConfig.deployment.storage.authentication.type' = 'SystemAssignedIdentity'
                }
            }
            foreach ($key in $properties.Keys) { $expected[$key] = $properties[$key] }
            Assert-FoundationProperties -Resource $resource -Expected $expected -Phase $phase
            if ($id -eq $appId) { $functionApp = $resource }
        }
        $functionConfiguration = Invoke-AzureJson -Arguments (@(
            'functionapp', 'config', 'show',
            '--resource-group', $names.resourceGroup,
            '--name', $names.functionApp
        ) + $scope) -Phase $phase -Remediation $functionRemediation -SanitizeOutput
        Assert-FoundationProperties -Resource $functionConfiguration -Expected @{
            minTlsVersion = '1.2'
        } -Phase $phase
        $principalId = if ($functionApp.identity.Contains('principalId')) { $functionApp.identity.principalId } else { $null }
        if ($principalId -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' -or
            [guid] $principalId -eq [guid]::Empty) {
            throw "Function deployment: the system-assigned principal is unavailable. $functionRemediation"
        }
        $roleScopes = @(
            @{ Id = $storageId; Roles = @(
                'b7e6dc6d-f1e8-4753-8033-0f276bb0955b',
                '974c5e8b-45b9-4653-ba55-5f855dd0fb88',
                '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
            ) }
            @{ Id = $vaultId; Roles = @('4633458b-17de-408a-b874-0445c86b69e6') }
        )
        foreach ($roleScope in $roleScopes) {
            $assignments = Invoke-AzureJson -Arguments (@(
                'role', 'assignment', 'list', '--scope', $roleScope.Id
            ) + $scope) -Phase $phase -Remediation $functionRemediation -SanitizeOutput
            if ($assignments -isnot [array] -or @($assignments | Where-Object {
                $_ -isnot [System.Collections.IDictionary] -or -not $_.Contains('principalId') -or
                -not $_.Contains('scope') -or -not $_.Contains('roleDefinitionId')
            }).Count -gt 0) {
                throw "Function deployment: invalid role assignment metadata. $functionRemediation"
            }
            foreach ($roleId in $roleScope.Roles) {
                $matches = @($assignments | Where-Object {
                    $_.principalId -eq $principalId -and $_.scope -eq $roleScope.Id -and
                    $_.roleDefinitionId -eq "/subscriptions/$($configuration.subscriptionId)/providers/Microsoft.Authorization/roleDefinitions/$roleId"
                })
                if ($matches.Count -ne 1) {
                    throw "Function deployment: managed identity role $roleId is missing or ambiguous. Wait for RBAC propagation and rerun DeployFunctions; no code was published."
                }
            }
        }
        $settingsDocument = Invoke-AzureJson -Arguments (@(
            'rest', '--method', 'post', '--url', "https://management.azure.com$appId/config/appsettings/list?api-version=2024-04-01"
        ) + $scope) -Phase $phase -Remediation $functionRemediation -SanitizeOutput
        if ($settingsDocument -isnot [System.Collections.IDictionary] -or -not $settingsDocument.Contains('properties')) {
            throw "Function deployment: app settings response is invalid; values suppressed. $functionRemediation"
        }
        $actualSettings = $settingsDocument.properties
        if ($actualSettings -isnot [System.Collections.IDictionary]) {
            throw "Function deployment: app settings response is invalid. $functionRemediation"
        }
        foreach ($key in $runtimeSettings.Keys) {
            if (-not $actualSettings.Contains($key) -or $actualSettings[$key] -cne $runtimeSettings[$key]) {
                throw "Function deployment: app setting '$key' differs from the IaC contract; values suppressed. $functionRemediation"
            }
        }
        foreach ($key in @('AzureWebJobsStorage', 'WEBSITE_CONTENTAZUREFILECONNECTIONSTRING', 'WEBSITE_RUN_FROM_PACKAGE',
            'AzureWebJobsStorage__clientId', 'AzureWebJobsStorage__managedIdentityResourceId',
            'AzureWebJobsStorage__blobServiceUri', 'AzureWebJobsStorage__queueServiceUri', 'AzureWebJobsStorage__tableServiceUri')) {
            if ($actualSettings.Contains($key)) {
                throw "Function deployment: conflicting storage or package setting '$key' exists; values suppressed. Reconcile settings through IaC before retrying."
            }
        }
        if (-not $actualSettings.Contains('APPLICATIONINSIGHTS_CONNECTION_STRING') -or
            $actualSettings.APPLICATIONINSIGHTS_CONNECTION_STRING -notmatch '^InstrumentationKey=[0-9a-fA-F-]{36};') {
            throw "Function deployment: telemetry connection string is missing or invalid; value suppressed. $functionRemediation"
        }
        $settings.APPLICATIONINSIGHTS_CONNECTION_STRING = $actualSettings.APPLICATIONINSIGHTS_CONNECTION_STRING
        $actualSettings = $null
        $settingsDocument = $null
        $references = Invoke-AzureJson -Arguments (@(
            'rest', '--method', 'get', '--url', "https://management.azure.com$appId/config/configreferences/appsettings?api-version=2024-04-01"
        ) + $scope) -Phase $phase -Remediation $functionRemediation -SanitizeOutput
        $secretReferenceStatus = $null
        if ($references -is [System.Collections.IDictionary] -and
            $references.Contains('properties') -and
            $references.properties -is [System.Collections.IDictionary] -and
            $references.properties.Contains('INVENTORY_CLIENT_SECRET') -and
            $references.properties.INVENTORY_CLIENT_SECRET -is [System.Collections.IDictionary] -and
            $references.properties.INVENTORY_CLIENT_SECRET.Contains('status')) {
            $secretReferenceStatus = $references.properties.INVENTORY_CLIENT_SECRET.status
        }
        elseif ($references -is [System.Collections.IDictionary] -and
            $references.Contains('value') -and $references.value -is [array]) {
            $secretReferences = @($references.value | Where-Object {
                $_ -is [System.Collections.IDictionary] -and
                $_.Contains('name') -and $_.name -ceq 'INVENTORY_CLIENT_SECRET' -and
                $_.Contains('properties') -and $_.properties -is [System.Collections.IDictionary] -and
                $_.properties.Contains('status')
            })
            if ($secretReferences.Count -eq 1) {
                $secretReferenceStatus = $secretReferences[0].properties.status
            }
        }
        if ($secretReferenceStatus -ne 'Resolved') {
            throw 'Function deployment: Key Vault reference is not Resolved. Wait for RBAC propagation, verify vault access and the active secret, then rerun DeployFunctions; no code was published.'
        }

        if (-not $activateTimers) {
            Push-Location (Join-Path $PSScriptRoot '..\src')
            try {
                Invoke-ValidationCommand -Command func -Arguments @(
                    'azure', 'functionapp', 'publish', $names.functionApp,
                    '--powershell',
                    '--subscription', $configuration.subscriptionId
                ) -Phase $phase -Remediation 'Publication failed. Keep timers disabled, inspect Core Tools and OneDeploy diagnostics without sharing credentials, and rerun DeployFunctions; earlier phases will be revalidated.' `
                    -SanitizeOutput | Out-Null
            }
            finally { Pop-Location }
        }
        $publishedFunctions = Invoke-AzureJson -Arguments (@(
            'functionapp', 'function', 'list', '--resource-group', $names.resourceGroup, '--name', $names.functionApp
        ) + $scope) -Phase $phase -Remediation $functionRemediation -SanitizeOutput
        if ($publishedFunctions -isnot [array] -or @($publishedFunctions | Where-Object {
            $_ -isnot [System.Collections.IDictionary] -or -not $_.Contains('name') -or $_.name -isnot [string]
        }).Count -gt 0) {
            throw "Function deployment: invalid published function metadata. $functionRemediation"
        }
        $expectedFunctions = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot '..\src') -Directory |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'function.json') } |
            ForEach-Object Name | Sort-Object)
        $functionNames = @($publishedFunctions | ForEach-Object { ($_.name -split '/')[-1] } | Sort-Object)
        if (($functionNames -join ',') -cne ($expectedFunctions -join ',')) {
            throw 'Function deployment: published functions do not match the repository. Inspect publication and host indexing diagnostics, then rerun DeployFunctions.'
        }
        foreach ($timerName in @('AgentSyncTimer', 'RpaSyncTimer')) {
            $timer = @($publishedFunctions | Where-Object { ($_.name -split '/')[-1] -ceq $timerName })[0]
            $expectedDisabled = $runtimeSettings["AzureWebJobs.$timerName.Disabled"] -eq 'true'
            if (-not $timer.Contains('isDisabled') -or $timer.isDisabled -isnot [bool] -or
                $timer.isDisabled -ne $expectedDisabled) {
                throw 'Function deployment: published timer state differs from IaC. Wait for host indexing/restart and rerun DeployFunctions; do not change timer state in the portal.'
            }
        }
        $hostStatus = Invoke-AzureJson -Arguments (@(
            'rest', '--method', 'get', '--url', "https://management.azure.com$appId/host/default/properties/status?api-version=2024-04-01"
        ) + $scope) -Phase $phase `
            -Remediation 'Host health check failed. Wait for startup/RBAC propagation, inspect Application Insights and host diagnostics, and rerun DeployFunctions; timers must remain disabled until readiness is confirmed.' `
            -SanitizeOutput
        if ($hostStatus -isnot [System.Collections.IDictionary] -or -not $hostStatus.Contains('properties') -or
            $hostStatus.properties -isnot [System.Collections.IDictionary] -or
            -not $hostStatus.properties.Contains('state') -or -not $hostStatus.properties.Contains('version') -or
            $hostStatus.properties.state -ne 'Running' -or $hostStatus.properties.version -notmatch '^4\.' -or
            ($hostStatus.properties.Contains('errors') -and $null -ne $hostStatus.properties.errors -and
                @($hostStatus.properties.errors).Count -gt 0)) {
            throw 'Function deployment: host is not healthy on Functions v4. Inspect host diagnostics and rerun DeployFunctions; do not enable timers.'
        }
    }
    $phases[4].Status = 'Completed'
    $phases[4].NeedsRevalidation = $false
    $state.phases[4].status = 'Completed'
    Save-DeploymentState -State $state -Path $resolvedStatePath
    $functionValidation = [pscustomobject] @{
        PrincipalId = $principalId
        KeyVaultReferenceStatus = 'Resolved'
        HostState = 'Running'
        Functions = $functionNames
        AgentTimerEnabled = $configuration.agentTimerEnabled
        RpaTimerEnabled = $configuration.rpaTimerEnabled
    }
}

$powerPlatformValidation = $null
$runtimeReadiness = $null
if ($Mode -eq 'DeployPowerPlatform') {
    $phase = 'Logging solution'
    $state.phases[5].status = 'Pending'
    Save-DeploymentState -State $state -Path $resolvedStatePath
    $solutionSource = Join-Path (Split-Path -Parent $PSScriptRoot) 'solutions\InventorySyncLogging'
    $solutionArtifact = Join-Path ([IO.Path]::GetTempPath()) "InventorySyncLogging-$([guid]::NewGuid()).zip"
    try {
        Invoke-ValidationCommand -Command pac -Arguments @(
            'auth', 'create', '--environment', $configuration.targetDataverseUrl
        ) -Phase $phase -SanitizeOutput `
            -Remediation 'Interactive Power Platform authentication failed. Sign in to the supplied PALP environment and retry DeployPowerPlatform.' |
            Out-Null
        $powerPlatformContextOutput = Invoke-ValidationCommand -Command pac -Arguments @(
            'env', 'who', '--environment', $configuration.targetDataverseUrl, '--json'
        ) -Phase $phase -SanitizeOutput `
            -Remediation 'The supplied PALP environment could not be selected. Verify the Dataverse URL and interactive account access.'
        try {
            $powerPlatformContexts = @($powerPlatformContextOutput | ConvertFrom-Json -AsHashtable)
        }
        catch {
            throw 'Logging solution: Power Platform context verification returned invalid JSON. Upgrade Power Platform CLI and retry.'
        }
        $powerPlatformContext = if ($powerPlatformContexts.Count -eq 1) {
            $powerPlatformContexts[0]
        }
        $environmentUrlKey = @('EnvironmentUrl', 'Environment URL', 'OrganizationUrl', 'OrgUrl') |
            Where-Object { $powerPlatformContext -is [System.Collections.IDictionary] -and
                $powerPlatformContext.Contains($_) } |
            Select-Object -First 1
        if (-not $environmentUrlKey) {
            throw 'Logging solution: Power Platform context verification did not identify the active environment. Upgrade Power Platform CLI and retry.'
        }
        $activeEnvironment = ([string] $powerPlatformContext[$environmentUrlKey]).TrimEnd('/')
        $expectedEnvironment = $configuration.targetDataverseUrl.TrimEnd('/')
        if (-not $activeEnvironment.Equals($expectedEnvironment, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Logging solution: Power Platform context target environment mismatch. Sign in interactively to the supplied PALP Dataverse URL and retry.'
        }
        Invoke-ValidationCommand -Command pac -Arguments @(
            'solution', 'pack', '--zipfile', $solutionArtifact, '--folder', $solutionSource,
            '--packagetype', 'Unmanaged'
        ) -Phase $phase -SanitizeOutput `
            -Remediation 'Packing Inventory Sync Logging from its unpacked source failed. Correct the solution source or Power Platform CLI installation and retry.' |
            Out-Null
        if (-not (Test-Path -LiteralPath $solutionArtifact -PathType Leaf)) {
            throw 'Logging solution: packing completed without producing the temporary solution archive. Verify the Power Platform CLI output and retry.'
        }
        Invoke-ValidationCommand -Command pac -Arguments @(
            'solution', 'import', '--path', $solutionArtifact,
            '--environment', $configuration.targetDataverseUrl
        ) -Phase $phase -SanitizeOutput `
            -Remediation 'Importing Inventory Sync Logging failed. Inspect the Dataverse solution import history, correct the reported dependency or permission issue, and retry.' |
            Out-Null
        $cloudChangesMade = $true
        Invoke-ValidationCommand -Command pac -Arguments @(
            'solution', 'publish', '--environment', $configuration.targetDataverseUrl
        ) -Phase $phase -SanitizeOutput `
            -Remediation 'Publishing Dataverse customizations failed. Inspect the target environment solution history and retry.' |
            Out-Null
        $solutionListOutput = Invoke-ValidationCommand -Command pac -Arguments @(
            'solution', 'list', '--environment', $configuration.targetDataverseUrl, '--json'
        ) -Phase $phase -SanitizeOutput `
            -Remediation 'Inventory Sync Logging could not be verified after publication. Confirm the unmanaged solution exists in the target environment and retry.'
        try {
            $installedSolutions = @($solutionListOutput | ConvertFrom-Json -AsHashtable)
        }
        catch {
            throw 'Logging solution: Power Platform CLI returned invalid solution verification data. Upgrade the CLI or inspect the target environment and retry.'
        }
        $loggingSolution = @($installedSolutions | Where-Object {
            $_ -is [System.Collections.IDictionary] -and (
                ($_.Contains('UniqueName') -and $_['UniqueName'] -eq 'InventorySyncLogging') -or
                ($_.Contains('SolutionUniqueName') -and $_['SolutionUniqueName'] -eq 'InventorySyncLogging')
            )
        })
        if ($loggingSolution.Count -ne 1 -or -not $loggingSolution[0].Contains('IsManaged') -or
            $loggingSolution[0]['IsManaged'] -ne $false) {
            throw 'Logging solution: the expected unmanaged InventorySyncLogging solution was not found after import. Inspect solution history and retry.'
        }
        $tableDefinitions = @(
            @{
                LogicalName = 'invs_syncrun'; PrimaryId = 'invs_syncrunid'
                EntitySet = $configuration.syncRunTable
                SourcePath = Join-Path $solutionSource 'Entities\invs_syncrun\Entity.xml'
            }
            @{
                LogicalName = 'invs_synclog'; PrimaryId = 'invs_synclogid'
                EntitySet = $configuration.syncLogTable
                SourcePath = Join-Path $solutionSource 'Entities\invs_synclog\Entity.xml'
            }
        )
        foreach ($table in $tableDefinitions) {
            try {
                [xml] $sourceEntity = Get-Content -LiteralPath $table.SourcePath -Raw
                $sourceEntitySet = [string] $sourceEntity.Entity.EntityInfo.entity.EntitySetName
            }
            catch {
                throw "Logging solution: source metadata for $($table.LogicalName) is invalid. Correct the unpacked solution and retry."
            }
            if ($sourceEntitySet -cne $table.EntitySet) {
                throw "Logging solution: configured entity set '$($table.EntitySet)' does not match source metadata for $($table.LogicalName). Correct the deployment input and retry."
            }
            $fetchXml = "<fetch count='1'><entity name='$($table.LogicalName)'><attribute name='$($table.PrimaryId)' /></entity></fetch>"
            Invoke-ValidationCommand -Command pac -Arguments @(
                'env', 'fetch', '--environment', $configuration.targetDataverseUrl,
                '--xml', $fetchXml
            ) -Phase $phase -SanitizeOutput `
                -Remediation "The $($table.LogicalName) table or configured $($table.EntitySet) entity set is unavailable. Publish the solution and verify the configured entity-set name before retrying." |
                Out-Null
        }
    }
    finally {
        if (Test-Path -LiteralPath $solutionArtifact) {
            Remove-Item -LiteralPath $solutionArtifact -Force
        }
    }
    $phases[5].Status = 'Completed'
    $phases[5].NeedsRevalidation = $false
    $state.phases[5].status = 'Completed'
    Save-DeploymentState -State $state -Path $resolvedStatePath
    $powerPlatformValidation = [pscustomobject] @{
        TargetEnvironment = $configuration.targetDataverseUrl
        SolutionUniqueName = 'InventorySyncLogging'
        Managed = $false
        EntitySets = @($configuration.syncRunTable, $configuration.syncLogTable)
    }
    $runtimeReadiness = [pscustomobject] @{
        Status = 'Blocked'
        TimerEnablementAllowed = $false
        Checks = @(
            [pscustomobject] @{ Id = 'target-application-user'; Status = 'OperatorConfirmationRequired'; Requirement = 'Confirm the runtime service principal is an application user in the target PALP environment.' }
            [pscustomobject] @{ Id = 'target-writer-privileges'; Status = 'OperatorConfirmationRequired'; Requirement = 'Confirm organization-level target writer privileges for Environment, Komponente, Sync Run, and Sync Log.' }
            [pscustomobject] @{ Id = 'source-application-users'; Status = 'OperatorConfirmationRequired'; Requirement = 'Confirm the runtime service principal is an application user in every included RPA source environment.' }
            [pscustomobject] @{ Id = 'source-reader-privileges'; Status = 'OperatorConfirmationRequired'; Requirement = 'Confirm organization-level Process, User, and Team read privileges in every included RPA source environment.' }
            [pscustomobject] @{ Id = 'environment-mappings-and-urls'; Status = 'OperatorConfirmationRequired'; Requirement = 'Confirm unique PALP Environment mappings and valid source Dataverse URLs.' }
            [pscustomobject] @{ Id = 'active-component-alternate-key'; Status = 'OperatorConfirmationRequired'; Requirement = 'Confirm the palp_komponente.palp_id alternate key is active.' }
            [pscustomobject] @{ Id = 'capped-smoke-run'; Status = 'OperatorConfirmationRequired'; Requirement = 'Complete and review a capped non-production smoke run before enabling either timer.' }
        )
    }
    $phases[6].Status = 'Completed'
    $phases[6].NeedsRevalidation = $false
    $state.phases[6].status = 'Completed'
    Save-DeploymentState -State $state -Path $resolvedStatePath
}

[pscustomobject] @{
    SchemaVersion = 1
    Mode = $Mode
    Status = $(switch ($Mode) {
        'DeployFoundation' { 'FoundationValidated' }
        'DeployIdentity' { 'IdentityValidated' }
        'DeployFunctions' { 'FunctionsValidated' }
        'DeployPowerPlatform' { 'DeploymentCompletedReadinessBlocked' }
        default { 'PlanValidated' }
    })
    CloudChangesMade = $cloudChangesMade
    DeploymentImplemented = $false
    AzureEntraDeploymentStatus = $(if ($Mode -eq 'DeployPowerPlatform') { 'Completed' } else { 'NotEvaluated' })
    PowerPlatformDeploymentImplemented = $true
    PowerPlatformValidation = $powerPlatformValidation
    RuntimeReadiness = $runtimeReadiness
    FoundationDeploymentImplemented = $true
    AzureContext = $azureContext
    Identity = $runtimeIdentity
    FunctionDeploymentImplemented = $true
    FunctionValidation = $functionValidation
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
            functionsRuntimeVersion = '4'
            operatingSystem = 'Linux'; identity = 'SystemAssigned'; plan = 'FlexConsumption'
            httpsOnly = $true; minimumTlsVersion = '1.2'
            instanceMemoryMB = $configuration.instanceMemoryMB
            maximumInstanceCount = $configuration.maximumInstanceCount
            storageRoles = @('Storage Blob Data Owner', 'Storage Queue Data Contributor', 'Storage Table Data Contributor')
            keyVaultRole = 'Key Vault Secrets User'
        }
    }
    ApplicationSettings = $settings
    Prerequisites = $prerequisites
    Compilation = $compilation
    Phases = $phases
    UnresolvedValues = $(if ($Mode -in @('DeployFunctions', 'DeployPowerPlatform')) { @() }
    elseif ($Mode -eq 'DeployIdentity') {
        @('APPLICATIONINSIGHTS_CONNECTION_STRING')
    }
    else { @('INVENTORY_TENANT_ID', 'INVENTORY_CLIENT_ID', 'APPLICATIONINSIGHTS_CONNECTION_STRING') })
    StateContract = @{
        SchemaVersion = 1
        PersistsSecrets = $false
        RevalidateBeforeResume = $true
        AllowedStatuses = @('Pending', 'Completed')
        AllowedFields = @('schemaVersion', 'configurationHash', 'phases', 'identity')
        AllowedPhaseFields = @('id', 'status')
        ConfigurationHash = $configurationHash
    }
}

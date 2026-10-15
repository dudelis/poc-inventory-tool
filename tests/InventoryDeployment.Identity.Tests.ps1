BeforeAll {
    $script:bootstrapPath = Join-Path $PSScriptRoot '..\deploy\Invoke-InventoryDeployment.ps1'
    $script:examplePath = Join-Path $PSScriptRoot '..\deploy\example.parameters.json'
    $script:tenantId = '22222222-2222-2222-2222-222222222222'
    $script:subscriptionId = '11111111-1111-1111-1111-111111111111'
    $script:compiledTemplates = @{}
    function Connect-MgGraph { param($TenantId, $Scopes, $ContextScope, [switch] $NoWelcome) }
    function Get-MgContext { }
    function Invoke-MgGraphRequest { param($Method, $Uri, $Body, $OutputType) }
    Get-ChildItem (Join-Path $PSScriptRoot '..\deploy') -Filter '*.bicep' -Recurse | ForEach-Object {
        $json = & az bicep build --file $_.FullName --stdout --no-restore
        if ($LASTEXITCODE -ne 0) { throw "Bicep compilation failed: $($_.Name)" }
        $script:compiledTemplates[$_.Name] = $json -join "`n"
    }
}

Describe 'Runtime identity and Function deployment' {
    BeforeEach {
        $configuration = Get-Content -LiteralPath $examplePath -Raw | ConvertFrom-Json -AsHashtable
        $configuration.subscriptionId = $subscriptionId
        $script:configurationPath = Join-Path $TestDrive 'parameters.json'
        $configuration | ConvertTo-Json | Set-Content -LiteralPath $configurationPath
        $script:statePath = Join-Path $TestDrive "$([guid]::NewGuid()).state.json"
        $script:calls = [System.Collections.Generic.List[string]]::new()
        $script:graphRequests = [System.Collections.Generic.List[object]]::new()
        $script:graphContext = @{ TenantId = $tenantId }
        $script:identity = @{
            Application = $null
            ServicePrincipal = $null
            RoleAssignment = $null
            Passwords = @()
        }
        $script:rolePropagation = @{ Pending = $false }
        $script:graphFailure = @{ Operation = $null; Message = $null }
        $script:vaultState = @{
            Versions = @(
                @{
                    id = 'https://example.vault.azure.net/secrets/inventory-sync-client-secret/existing-version'
                    attributes = @{ enabled = $true; expires = '2027-10-15T00:00:00Z' }
                }
            )
            WriteFailure = $null
        }
        $script:generatedSecret = 'never-echo-this-runtime-secret'
        $script:cloud = @{ Exists = $true }
        $script:azureRunner = {
            param($Command, $Arguments, $SensitiveArguments)
            $calls.Add("azure:$($Arguments -join ' ')")
            $output = switch ($Arguments[0]) {
                'version' { '{}' }
                'bicep' {
                    if ($Arguments[1] -eq 'version') { 'Bicep CLI' }
                    else { $compiledTemplates[[IO.Path]::GetFileName($Arguments[3])] }
                }
                'account' {
                    @{
                        id = $subscriptionId; tenantId = $tenantId; state = 'Enabled'
                        user = @{ type = 'user'; name = 'operator@example.test' }
                    } | ConvertTo-Json -Depth 5
                }
                'group' {
                    switch ($Arguments[1]) {
                        'exists' { $cloud.Exists | ConvertTo-Json }
                        'show' { $group | ConvertTo-Json -Depth 5 }
                        default { throw "Unexpected group command: $($Arguments -join ' ')" }
                    }
                }
                'resource' {
                    if ($Arguments[1] -eq 'list') {
                        ConvertTo-Json -InputObject @($resources) -Depth 10
                    }
                    elseif ($Arguments[1] -eq 'show') {
                        $resource = $resources | Where-Object id -eq $Arguments[3]
                        if ($null -eq $resource) { throw 'Unexpected resource ID.' }
                        $resource | ConvertTo-Json -Depth 10
                    }
                    else { throw "Unexpected resource command: $($Arguments -join ' ')" }
                }
                'deployment' {
                    if ($Arguments[1] -ne 'group' -or $Arguments[2] -notin @('validate', 'create')) {
                        throw "Unexpected deployment command: $($Arguments -join ' ')"
                    }
                    '{"properties":{"provisioningState":"Succeeded"}}'
                }
                'keyvault' {
                    if ($Arguments[1..2] -join ' ' -eq 'secret list') {
                        ConvertTo-Json -InputObject @($vaultState.Versions | Select-Object -First 1) -Depth 5
                    }
                    elseif ($Arguments[1..2] -join ' ' -eq 'secret list-versions') {
                        ConvertTo-Json -InputObject @($vaultState.Versions) -Depth 5
                    }
                    elseif ($Arguments[1..2] -join ' ' -eq 'secret set') {
                        if ($vaultState.WriteFailure) {
                            return @{ ExitCode = 1; Output = "$($vaultState.WriteFailure) $($SensitiveArguments.Value)" }
                        }
                        $vaultState.Versions = @(
                            @{
                                id = 'https://example.vault.azure.net/secrets/inventory-sync-client-secret/new-version'
                                attributes = @{ enabled = $true; expires = $Arguments[$Arguments.IndexOf('--expires') + 1] }
                                tags = @{
                                    'inventory-sync-installation' = $tags.'inventory-sync-installation'
                                    'application-id' = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                                    'credential-key-id' = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
                                }
                            }
                        )
                        ConvertTo-Json -InputObject $vaultState.Versions[0] -Depth 5
                    }
                    else { throw "Unexpected Key Vault command: $($Arguments -join ' ')" }
                }
                default { throw "Unexpected Azure command: $($Arguments -join ' ')" }
            }
            @{ ExitCode = 0; Output = $output }
        }
        $callLog = $script:calls
        $requestLog = $script:graphRequests
        $graphContextState = $script:graphContext
        $identityState = $script:identity
        $rolePropagationState = $script:rolePropagation
        $graphFailureState = $script:graphFailure
        $generatedSecretValue = $script:generatedSecret
        $script:graphRunner = {
            param($Operation, $Parameters)
            $callLog.Add("graph:$Operation")
            $requestLog.Add([pscustomobject] @{ Operation = $Operation; Parameters = $Parameters })
            if ($graphFailureState.Operation -eq $Operation) {
                throw $graphFailureState.Message
            }
            switch ($Operation) {
                'Connect' {
                    return @{
                        TenantId = $graphContextState.TenantId
                        AuthType = 'Delegated'
                        Account = 'operator@example.test'
                    }
                }
                'FindApplications' {
                    if ($identityState.Application) { return $identityState.Application }
                    return
                }
                'CreateApplication' {
                    $identityState.Application = @{
                        Id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                        AppId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                        DisplayName = $Parameters.DisplayName
                        SignInAudience = 'AzureADMyOrg'
                        Tags = @($Parameters.Tags)
                    }
                    return $identityState.Application
                }
                'FindServicePrincipals' {
                    if ($identityState.ServicePrincipal) { return $identityState.ServicePrincipal }
                    return
                }
                'CreateServicePrincipal' {
                    $identityState.ServicePrincipal = @{
                        Id = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
                        AppId = $Parameters.AppId
                    }
                    return $identityState.ServicePrincipal
                }
                'GetGlobalReaderRole' {
                    return @{
                        Id = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
                        TemplateId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
                    }
                }
                'FindRoleAssignments' {
                    if ($identityState.RoleAssignment -and -not $rolePropagationState.Pending) {
                        return $identityState.RoleAssignment
                    }
                    return
                }
                'AssignGlobalReader' {
                    $identityState.RoleAssignment = @{
                        Id = 'YUb1sHQtUEyvox7IA_Eu_mm3jqnUe4lEhvatluHVi2I-1'
                        PrincipalId = $Parameters.PrincipalId
                        RoleDefinitionId = $Parameters.RoleDefinitionId
                        DirectoryScopeId = '/'
                    }
                    return $identityState.RoleAssignment
                }
                'CreatePassword' {
                    $identityState.Passwords = @(@{
                        keyId = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
                        displayName = $Parameters.DisplayName
                        endDateTime = $Parameters.EndDateTime
                    })
                    return @{
                        KeyId = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
                        SecretText = $generatedSecretValue
                        EndDateTime = $Parameters.EndDateTime
                    }
                }
                'GetPasswordCredentials' { return $identityState.Passwords }
                default { throw "Unexpected Graph operation: $Operation" }
            }
        }.GetNewClosure()
        $script:plan = & $bootstrapPath -ConfigurationPath $configurationPath -CommandRunner $azureRunner
        $calls.Clear()
        $graphRequests.Clear()
        $script:tags = @{
            'inventory-sync-installation' = $plan.ResourceNames.storage.Substring($plan.ResourceNames.storage.Length - 12)
            'inventory-sync-workload' = 'palp-inventory-sync'
        }
        $vaultState.Versions[0].tags = @{
            'inventory-sync-installation' = $tags.'inventory-sync-installation'
            'application-id' = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        }
        $script:group = @{
            name = $plan.ResourceNames.resourceGroup
            location = 'northeurope'
            tags = $tags
        }
        $script:resources = @(
            @{
                type = 'Microsoft.Storage/storageAccounts'; name = $plan.ResourceNames.storage
                kind = 'StorageV2'; sku = @{ name = 'Standard_LRS' }
                properties = @{
                    provisioningState = 'Succeeded'; allowBlobPublicAccess = $false
                    supportsHttpsTrafficOnly = $true; minimumTlsVersion = 'TLS1_2'
                    publicNetworkAccess = 'Enabled'; networkAcls = @{ defaultAction = 'Allow' }
                }
            }
            @{
                type = 'Microsoft.KeyVault/vaults'; name = $plan.ResourceNames.keyVault
                properties = @{
                    provisioningState = 'Succeeded'; tenantId = $tenantId
                    enableRbacAuthorization = $true; enableSoftDelete = $true
                    enablePurgeProtection = $true; softDeleteRetentionInDays = 90
                    publicNetworkAccess = 'Enabled'; networkAcls = @{ defaultAction = 'Allow' }
                    sku = @{ family = 'A'; name = 'standard' }
                }
            }
            @{
                type = 'Microsoft.OperationalInsights/workspaces'; name = $plan.ResourceNames.logAnalytics
                properties = @{
                    provisioningState = 'Succeeded'; retentionInDays = 30
                    sku = @{ name = 'PerGB2018' }
                    publicNetworkAccessForIngestion = 'Enabled'
                    publicNetworkAccessForQuery = 'Enabled'
                }
            }
            @{
                type = 'Microsoft.Insights/components'; name = $plan.ResourceNames.applicationInsights
                kind = 'web'
                properties = @{
                    provisioningState = 'Succeeded'; Application_Type = 'web'
                    WorkspaceResourceId = "/subscriptions/$subscriptionId/resourceGroups/$($group.name)/providers/Microsoft.OperationalInsights/workspaces/$($plan.ResourceNames.logAnalytics)"
                    publicNetworkAccessForIngestion = 'Enabled'
                    publicNetworkAccessForQuery = 'Enabled'
                }
            }
        )
        foreach ($resource in $resources) {
            $resource.id = "/subscriptions/$subscriptionId/resourceGroups/$($group.name)/providers/$($resource.type)/$($resource.name)"
            $resource.location = 'northeurope'
            $resource.tags = $tags.Clone()
        }
    }

    Describe 'Function deployment' {
        BeforeEach {
            $configuration = Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json -AsHashtable
            $configuration.agentCreatedIn = 'Copilot Studio Lite'
            $configuration.targetDataverseUrl = 'https://tenant.crm4.dynamics.com'
            $configuration | ConvertTo-Json | Set-Content -LiteralPath $configurationPath
            $script:functionCloud = @{
                Parameters = $null
                Published = $false
                PrincipalId = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
                ResourceLocation = 'northeurope'
                MinTlsVersion = '1.2'
                ConnectionString = 'InstrumentationKey=00000000-0000-0000-0000-000000000000;IngestionEndpoint=https://example.test/'
            }
            $baseRunner = $azureRunner
            $functionState = $functionCloud
            $callLog = $calls
            $resourceNames = $plan.ResourceNames
            $resourceTags = $tags
            $sub = $subscriptionId
            $script:functionRunner = {
                param($Command, $Arguments, $SensitiveArguments)
                $joined = $Arguments -join ' '
                if ($Command -eq 'func') {
                    $callLog.Add("func:$joined")
                    if ($Arguments[0] -eq '--version') {
                        return @{ ExitCode = 0; Output = '4.8.0' }
                    }
                    if ($functionState.Parameters.parameters.applicationSettings.value.'AzureWebJobs.AgentSyncTimer.Disabled' -ne 'true' -or
                        $functionState.Parameters.parameters.applicationSettings.value.'AzureWebJobs.RpaSyncTimer.Disabled' -ne 'true') {
                        throw 'Timers must be disabled until code and host validation finish.'
                    }
                    $functionState.Published = $true
                    return @{ ExitCode = 0; Output = 'Published' }
                }
                if ($Arguments[0..2] -join ' ' -match '^deployment group (validate|create)$' -and
                    $joined -match 'functions.bicep') {
                    $callLog.Add("azure:$joined")
                    $file = $Arguments[$Arguments.IndexOf('--parameters') + 1].TrimStart('@')
                    $functionState.Parameters = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable
                    return @{ ExitCode = 0; Output = '{"properties":{"provisioningState":"Succeeded"}}' }
                }
                if ($Arguments[0] -eq 'resource' -and $Arguments[1] -eq 'show' -and
                    $joined -match '/Microsoft.Web/') {
                    $callLog.Add("azure:$joined")
                    $isApp = $joined -match '/sites/'
                    $resource = @{
                        id = $Arguments[3]
                        name = $(if ($isApp) { $resourceNames.functionApp } else { $resourceNames.hostingPlan })
                        type = $(if ($isApp) { 'Microsoft.Web/sites' } else { 'Microsoft.Web/serverfarms' })
                        location = $functionState.ResourceLocation; tags = $resourceTags; sku = @{ name = 'FC1'; tier = 'FlexConsumption' }
                        kind = 'functionapp,linux'
                        identity = @{ type = 'SystemAssigned'; principalId = $functionState.PrincipalId }
                        properties = @{
                            provisioningState = 'Succeeded'; state = 'Running'; reserved = $true
                            serverFarmId = "/subscriptions/$sub/resourceGroups/$($resourceNames.resourceGroup)/providers/Microsoft.Web/serverfarms/$($resourceNames.hostingPlan)"
                            httpsOnly = $true; siteConfig = @{ minTlsVersion = $null }
                            functionAppConfig = @{
                                runtime = @{ name = 'powershell'; version = '7.6' }
                                scaleAndConcurrency = @{
                                    instanceMemoryMB = $functionState.Parameters.parameters.instanceMemoryMB.value
                                    maximumInstanceCount = $functionState.Parameters.parameters.maximumInstanceCount.value
                                }
                                deployment = @{ storage = @{
                                    type = 'blobContainer'
                                    value = "https://$($resourceNames.storage).blob.core.windows.net/$($resourceNames.deploymentContainer)"
                                    authentication = @{ type = 'SystemAssignedIdentity' }
                                } }
                            }
                        }
                    }
                    return @{ ExitCode = 0; Output = ($resource | ConvertTo-Json -Depth 10) }
                }
                if ($Arguments[0..2] -join ' ' -eq 'functionapp config show') {
                    $callLog.Add("azure:$joined")
                    return @{
                        ExitCode = 0
                        Output = (@{ minTlsVersion = $functionState.MinTlsVersion } | ConvertTo-Json)
                    }
                }
                if ($Arguments[0..2] -join ' ' -eq 'role assignment list') {
                    $callLog.Add("azure:$joined")
                    $scope = $Arguments[$Arguments.IndexOf('--scope') + 1]
                    $roleIds = if ($scope -match '/vaults/') { @('4633458b-17de-408a-b874-0445c86b69e6') }
                    else { @(
                        'b7e6dc6d-f1e8-4753-8033-0f276bb0955b',
                        '974c5e8b-45b9-4653-ba55-5f855dd0fb88',
                        '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
                    ) }
                    $assignments = @($roleIds | ForEach-Object { @{
                        principalId = $functionState.PrincipalId; scope = $scope
                        roleDefinitionId = "/subscriptions/$sub/providers/Microsoft.Authorization/roleDefinitions/$_"
                    } })
                    return @{ ExitCode = 0; Output = (ConvertTo-Json -InputObject $assignments) }
                }
                if ($Arguments[0] -eq 'rest') {
                    $callLog.Add("azure:$joined")
                    $output = switch -Regex ($joined) {
                        '/config/appsettings/list' {
                            $appSettings = $functionState.Parameters.parameters.applicationSettings.value
                            $appSettings['APPLICATIONINSIGHTS_CONNECTION_STRING'] = $functionState.ConnectionString
                            @{ properties = $appSettings } | ConvertTo-Json -Depth 8
                        }
                        '/config/configreferences/appsettings' {
                            if ($Arguments[$Arguments.IndexOf('--method') + 1] -ne 'get' -or
                                $joined -match '/appsettings/list') {
                                throw 'Key Vault reference status requires GET without /list.'
                            }
                            '{"properties":{"INVENTORY_CLIENT_SECRET":{"status":"Resolved"}}}'
                        }
                        '/host/default/properties/status' { '{"properties":{"state":"Running","version":"4.1040.0","errors":[]}}' }
                        default { throw "Unexpected REST request: $joined" }
                    }
                    return @{ ExitCode = 0; Output = $output }
                }
                if ($Arguments[0..2] -join ' ' -eq 'functionapp function list') {
                    $callLog.Add("azure:$joined")
                    $functions = @(
                        'AgentSyncTimer', 'AgentSyncOrchestrator', 'AgentSyncCreateActivity',
                        'RpaSyncTimer', 'RpaSyncOrchestrator', 'RpaSyncActivity'
                    ) | ForEach-Object {
                        $disabledKey = "AzureWebJobs.$_.Disabled"
                        $appSettings = $functionState.Parameters.parameters.applicationSettings.value
                        @{
                            name = "$($resourceNames.functionApp)/$_"
                            isDisabled = $appSettings.Contains($disabledKey) -and $appSettings[$disabledKey] -eq 'true'
                        }
                    }
                    return @{ ExitCode = 0; Output = (ConvertTo-Json -InputObject @($functions)) }
                }
                & $baseRunner $Command $Arguments $SensitiveArguments
            }.GetNewClosure()
        }

        It 'publishes only after identity, credential, infrastructure, roles, and reference settings validate' {
            $result = & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFunctions `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $functionRunner -GraphRunner $graphRunner

            $result.Status | Should -Be 'FunctionsValidated'
            $result.Phases[4].Status | Should -Be 'Completed'
            $result.Phases[5].Status | Should -Be 'Pending'
            $result.UnresolvedValues | Should -HaveCount 0
            $result.ApplicationSettings.INVENTORY_TENANT_ID | Should -Be $tenantId
            $result.ApplicationSettings.INVENTORY_CLIENT_ID | Should -Be 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
            $result.FunctionValidation.HostState | Should -Be 'Running'
            $result.FunctionValidation.Functions | Should -HaveCount 6
            $functionCloud.Parameters.parameters.applicationSettings.value.'AzureWebJobs.AgentSyncTimer.Disabled' | Should -Be 'true'
            $functionCloud.Parameters.parameters.applicationSettings.value.'AzureWebJobs.RpaSyncTimer.Disabled' | Should -Be 'true'
            $publishIndex = $calls.FindIndex({ param($call) $call -like 'func:azure functionapp publish*' })
            $roleIndex = $calls.FindLastIndex({ param($call) $call -like 'azure:role assignment list*' })
            $referenceIndex = $calls.FindIndex({ param($call) $call -like '*config/configreferences/appsettings*' })
            $credentialIndex = $calls.FindIndex({ param($call) $call -like 'azure:keyvault secret list-versions*' })
            $publishIndex | Should -BeGreaterThan $roleIndex
            $publishIndex | Should -BeGreaterThan $referenceIndex
            $roleIndex | Should -BeGreaterThan $credentialIndex
            ($calls -join "`n") | Should -Not -Match 'publish-local-settings|show-keys|AccountKey|secret show'
            ($result | ConvertTo-Json -Depth 30) | Should -Not -Match $generatedSecret
            $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
            $saved.phases[4].status | Should -Be 'Completed'
        }

        It 'accepts the Azure display name for a configured canonical resource location' {
            $functionCloud.ResourceLocation = 'North Europe'

            $result = & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFunctions `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $functionRunner -GraphRunner $graphRunner

            $result.Status | Should -Be 'FunctionsValidated'
            $result.Phases[4].Status | Should -Be 'Completed'
        }

        It 'validates Flex TLS through the Function configuration API' {
            $result = & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFunctions `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $functionRunner -GraphRunner $graphRunner

            $result.Status | Should -Be 'FunctionsValidated'
            ($calls -join "`n") | Should -Match 'azure:functionapp config show'
        }

        It 'enables timers only through a final incremental IaC update after publication and host validation' {
            $configuration = Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json -AsHashtable
            $configuration.agentTimerEnabled = $true
            $configuration.rpaTimerEnabled = $true
            $configuration.agentSchedule = '0 30 2 * * *'
            $configuration.maxCreatesPerRun = 8
            $configuration.rpaMaxParallelEnvironments = 3
            $configuration.maximumInstanceCount = 25
            $configuration | ConvertTo-Json | Set-Content -LiteralPath $configurationPath

            $result = & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFunctions `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $functionRunner -GraphRunner $graphRunner

            $result.FunctionValidation.AgentTimerEnabled | Should -BeTrue
            $result.FunctionValidation.RpaTimerEnabled | Should -BeTrue
            $finalSettings = $functionCloud.Parameters.parameters.applicationSettings.value
            $finalSettings.'AzureWebJobs.AgentSyncTimer.Disabled' | Should -Be 'false'
            $finalSettings.'AzureWebJobs.RpaSyncTimer.Disabled' | Should -Be 'false'
            $finalSettings.INVENTORY_AGENT_SCHEDULE | Should -Be '0 30 2 * * *'
            $finalSettings.INVENTORY_MAX_CREATES_PER_RUN | Should -Be '8'
            $finalSettings.INVENTORY_RPA_MAX_PARALLEL_ENVIRONMENTS | Should -Be '3'
            $healthIndex = $calls.FindIndex({ param($call) $call -like '*host/default/properties/status*' })
            $lastDeployment = $calls.FindLastIndex({ param($call) $call -like 'azure:deployment group create*functions.bicep*' })
            $lastDeployment | Should -BeGreaterThan $healthIndex
        }

        It 'reports malformed Key Vault reference metadata as a resumable deployment failure without publishing' {
            $normalRunner = $functionRunner
            $malformedRunner = {
                param($Command, $Arguments, $SensitiveArguments)
                if (($Arguments -join ' ') -match '/config/configreferences/appsettings') {
                    return @{ ExitCode = 0; Output = '{"properties":{}}' }
                }
                & $normalRunner $Command $Arguments $SensitiveArguments
            }.GetNewClosure()

            { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFunctions `
                    -TenantId $tenantId -StatePath $statePath -CommandRunner $malformedRunner -GraphRunner $graphRunner } |
                Should -Throw '*Function deployment*Key Vault reference*'

            $functionCloud.Published | Should -BeFalse
            $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
            $saved.phases[4].status | Should -Be 'Pending'
        }

        It 'rejects malformed <Stage> responses with deployment context and pending recovery state' -ForEach @(
            @{ Stage = 'infrastructure'; Pattern = 'deployment group create.*functions.bicep'; Published = $false }
            @{ Stage = 'roles'; Pattern = '^role assignment list'; Published = $false }
            @{ Stage = 'settings'; Pattern = '/config/appsettings/list'; Published = $false }
            @{ Stage = 'functions'; Pattern = '^functionapp function list'; Published = $true }
            @{ Stage = 'host'; Pattern = '/host/default/properties/status'; Published = $true }
        ) {
            $normalRunner = $functionRunner
            $responsePattern = $Pattern
            $malformedRunner = {
                param($Command, $Arguments, $SensitiveArguments)
                if ($Command -eq 'az' -and ($Arguments -join ' ') -match $responsePattern) {
                    return @{ ExitCode = 0; Output = '{}' }
                }
                & $normalRunner $Command $Arguments $SensitiveArguments
            }.GetNewClosure()

            { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFunctions `
                    -TenantId $tenantId -StatePath $statePath -CommandRunner $malformedRunner -GraphRunner $graphRunner } |
                Should -Throw '*Function deployment*'

            $functionCloud.Published | Should -Be $Published
            $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
            $saved.phases[4].status | Should -Be 'Pending'
        }

        It 'refuses completion when the host reports a timer enabled despite disabled app settings' {
            $normalRunner = $functionRunner
            $incorrectTimerRunner = {
                param($Command, $Arguments, $SensitiveArguments)
                $result = & $normalRunner $Command $Arguments $SensitiveArguments
                if ($Arguments[0..2] -join ' ' -eq 'functionapp function list') {
                    $functions = $result.Output | ConvertFrom-Json -AsHashtable
                    ($functions | Where-Object name -like '*/AgentSyncTimer').isDisabled = $false
                    $result.Output = ConvertTo-Json -InputObject @($functions)
                }
                $result
            }.GetNewClosure()

            { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFunctions `
                    -TenantId $tenantId -StatePath $statePath -CommandRunner $incorrectTimerRunner -GraphRunner $graphRunner } |
                Should -Throw '*Function deployment*timer*state*'

            $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
            $saved.phases[4].status | Should -Be 'Pending'
        }

        It 'stops safely on <Stage> failure, suppresses sensitive output, and revalidates on resume' -ForEach @(
            @{ Stage = 'infrastructure'; Pattern = 'deployment group create.*functions.bicep'; Response = $null; Published = $false }
            @{ Stage = 'roles'; Pattern = '^role assignment list'; Response = '[]'; Published = $false }
            @{ Stage = 'reference'; Pattern = '/config/configreferences/appsettings'; Response = '{"properties":{"INVENTORY_CLIENT_SECRET":{"status":"AccessToKeyVaultDenied"}}}'; Published = $false }
            @{ Stage = 'publication'; Pattern = '^azure functionapp publish'; Response = $null; Published = $false }
            @{ Stage = 'indexing'; Pattern = '^functionapp function list'; Response = '[]'; Published = $true }
            @{ Stage = 'host'; Pattern = '/host/default/properties/status'; Response = '{"properties":{"state":"Error","version":"4.1040.0","errors":[]}}'; Published = $true }
        ) {
            $configuration = Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json -AsHashtable
            $configuration.agentTimerEnabled = $true
            $configuration | ConvertTo-Json | Set-Content -LiteralPath $configurationPath
            $normalRunner = $functionRunner
            $responsePattern = $Pattern
            $failureResponse = $Response
            $sensitiveValue = $generatedSecret
            $failingRunner = {
                param($Command, $Arguments, $SensitiveArguments)
                if (($Arguments -join ' ') -match $responsePattern) {
                    Write-Warning $sensitiveValue
                    Write-Verbose $sensitiveValue -Verbose
                    Write-Information $sensitiveValue -InformationAction Continue
                    if ($null -eq $failureResponse) {
                        return @{ ExitCode = 1; Output = "Failure: $sensitiveValue" }
                    }
                    return @{ ExitCode = 0; Output = $failureResponse }
                }
                & $normalRunner $Command $Arguments $SensitiveArguments
            }.GetNewClosure()
            $transcriptPath = Join-Path $TestDrive "function-$Stage-transcript.txt"
            $observed = [System.Collections.Generic.List[object]]::new()
            $caught = $null
            Start-Transcript -LiteralPath $transcriptPath | Out-Null
            try {
                & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFunctions `
                    -TenantId $tenantId -StatePath $statePath -CommandRunner $failingRunner `
                    -GraphRunner $graphRunner -Verbose *>&1 | ForEach-Object { $observed.Add($_) }
            }
            catch { $caught = $_ }
            finally { Stop-Transcript | Out-Null }

            $caught | Should -Not -BeNullOrEmpty
            $caught.Exception.Message | Should -Match 'Function deployment'
            $caught.Exception.Message | Should -Not -Match $generatedSecret
            ($observed | Out-String) | Should -Not -Match $generatedSecret
            Get-Content -LiteralPath $transcriptPath -Raw | Should -Not -Match $generatedSecret
            ($Error | ForEach-Object { $_.Exception.ToString() } | Out-String) | Should -Not -Match $generatedSecret
            $functionCloud.Published | Should -Be $Published
            $functionCloud.Parameters.parameters.applicationSettings.value.'AzureWebJobs.AgentSyncTimer.Disabled' | Should -Be 'true'
            $savedContent = Get-Content -LiteralPath $statePath -Raw
            $savedContent | Should -Not -Match $generatedSecret
            ($savedContent | ConvertFrom-Json -AsHashtable).phases[4].status | Should -Be 'Pending'
            $calls.Clear()
            $graphRequests.Clear()

            $resumed = & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFunctions `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $functionRunner -GraphRunner $graphRunner

            $resumed.Status | Should -Be 'FunctionsValidated'
            $resumed.FunctionValidation.AgentTimerEnabled | Should -BeTrue
            @($calls | Where-Object { $_ -like 'azure:role assignment list*' }) | Should -HaveCount 4
            @($graphRequests | Where-Object Operation -in @(
                'CreateApplication', 'CreateServicePrincipal', 'AssignGlobalReader', 'CreatePassword'
            )) | Should -HaveCount 0
        }

        It 'deploys the source logging solution and reports the manual readiness blockers' {
            $baseFunctionRunner = $functionRunner
            $powerPlatformCalls = [System.Collections.Generic.List[object]]::new()
            $artifactState = @{ Path = $null }
            $powerPlatformRunner = {
                param($Command, $Arguments, $SensitiveArguments)
                if ($Command -ne 'pac') {
                    return & $baseFunctionRunner $Command $Arguments $SensitiveArguments
                }
                $powerPlatformCalls.Add([pscustomobject] @{
                    Arguments = @($Arguments)
                    Joined = $Arguments -join ' '
                })
                if ($Arguments[0] -eq '--version') {
                    return @{ ExitCode = 0; Output = '1.45.2' }
                }
                if ($Arguments[0..1] -join ' ' -eq 'solution pack') {
                    $artifactState.Path = $Arguments[$Arguments.IndexOf('--zipfile') + 1]
                    Set-Content -LiteralPath $artifactState.Path -Value 'temporary solution archive'
                }
                $output = if ($Arguments[0..1] -join ' ' -eq 'env who') {
                    '{"EnvironmentUrl":"https://tenant.crm4.dynamics.com"}'
                }
                elseif ($Arguments[0..1] -join ' ' -eq 'solution list') {
                    '[{"UniqueName":"InventorySyncLogging","IsManaged":false}]'
                }
                else { '{}' }
                return @{ ExitCode = 0; Output = $output }
            }.GetNewClosure()

            $result = & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployPowerPlatform `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $powerPlatformRunner `
                -GraphRunner $graphRunner

            $result.Status | Should -Be 'DeploymentCompletedReadinessBlocked'
            $result.AzureEntraDeploymentStatus | Should -Be 'Completed'
            $result.PowerPlatformValidation.TargetEnvironment | Should -Be 'https://tenant.crm4.dynamics.com'
            $result.PowerPlatformValidation.SolutionUniqueName | Should -Be 'InventorySyncLogging'
            $result.PowerPlatformValidation.EntitySets | Should -Be @('invs_syncruns', 'invs_synclogs')
            $result.RuntimeReadiness.Status | Should -Be 'Blocked'
            $result.RuntimeReadiness.TimerEnablementAllowed | Should -BeFalse
            $result.RuntimeReadiness.Checks.Id | Should -Be @(
                'target-application-user', 'target-writer-privileges',
                'source-application-users', 'source-reader-privileges',
                'environment-mappings-and-urls', 'active-component-alternate-key',
                'capped-smoke-run'
            )
            $result.RuntimeReadiness.Checks.Status | Select-Object -Unique |
                Should -Be 'OperatorConfirmationRequired'
            $result.Phases[0..6].Status | Should -Not -Contain 'Pending'

            $joinedCalls = @($powerPlatformCalls.Joined)
            $authIndex = [array]::IndexOf($joinedCalls, (
                'auth create --environment https://tenant.crm4.dynamics.com'
            ))
            $packIndex = [array]::FindIndex($joinedCalls, [Predicate[string]] {
                param($call) $call -like 'solution pack*--folder*solutions\InventorySyncLogging*--packagetype Unmanaged*'
            })
            $importIndex = [array]::FindIndex($joinedCalls, [Predicate[string]] {
                param($call) $call -like 'solution import*--environment https://tenant.crm4.dynamics.com*'
            })
            $publishIndex = [array]::FindIndex($joinedCalls, [Predicate[string]] {
                param($call) $call -eq 'solution publish --environment https://tenant.crm4.dynamics.com'
            })
            $solutionVerifyIndex = [array]::FindIndex($joinedCalls, [Predicate[string]] {
                param($call) $call -eq 'solution list --environment https://tenant.crm4.dynamics.com --json'
            })
            $tableVerifyIndexes = @(
                for ($index = 0; $index -lt $joinedCalls.Count; $index++) {
                    if ($joinedCalls[$index] -like 'env fetch --environment https://tenant.crm4.dynamics.com*') {
                        $index
                    }
                }
            )
            $authIndex | Should -BeGreaterThan -1
            $packIndex | Should -BeGreaterThan $authIndex
            $importIndex | Should -BeGreaterThan $packIndex
            $publishIndex | Should -BeGreaterThan $importIndex
            $solutionVerifyIndex | Should -BeGreaterThan $publishIndex
            $tableVerifyIndexes | Should -HaveCount 2
            $tableVerifyIndexes[0] | Should -BeGreaterThan $solutionVerifyIndex
            $tableVerifyIndexes[1] | Should -BeGreaterThan $tableVerifyIndexes[0]
            $artifactState.Path | Should -Not -BeNullOrEmpty
            $artifactState.Path | Should -Not -Exist

            $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
            $saved.phases[5].status | Should -Be 'Completed'
            $saved.phases[6].status | Should -Be 'Completed'
        }

        It 'refuses timer enablement until the reported readiness checks are confirmed' {
            $configuration = Get-Content -LiteralPath $configurationPath -Raw |
                ConvertFrom-Json -AsHashtable
            $configuration.agentTimerEnabled = $true
            $configuration | ConvertTo-Json | Set-Content -LiteralPath $configurationPath
            $baseFunctionRunner = $functionRunner
            $powerPlatformCalls = [System.Collections.Generic.List[string]]::new()
            $powerPlatformRunner = {
                param($Command, $Arguments, $SensitiveArguments)
                if ($Command -eq 'pac') {
                    $powerPlatformCalls.Add($Arguments -join ' ')
                    return @{ ExitCode = 0; Output = '1.45.2' }
                }
                & $baseFunctionRunner $Command $Arguments $SensitiveArguments
            }.GetNewClosure()

            { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployPowerPlatform `
                    -TenantId $tenantId -StatePath $statePath -CommandRunner $powerPlatformRunner `
                    -GraphRunner $graphRunner } |
                Should -Throw '*Readiness validation*timers must remain disabled*'

            $functionCloud.Published | Should -BeFalse
            @($calls | Where-Object { $_ -like 'azure:deployment*create*' }) |
                Should -HaveCount 0
            @($powerPlatformCalls | Where-Object { $_ -notlike '--version' }) |
                Should -HaveCount 0
            $statePath | Should -Not -Exist
        }

        It 'stops before solution mutation when the interactive Power Platform context targets another environment' {
            $baseFunctionRunner = $functionRunner
            $powerPlatformCalls = [System.Collections.Generic.List[string]]::new()
            $mismatchedContextRunner = {
                param($Command, $Arguments, $SensitiveArguments)
                if ($Command -ne 'pac') {
                    return & $baseFunctionRunner $Command $Arguments $SensitiveArguments
                }
                $joined = $Arguments -join ' '
                $powerPlatformCalls.Add($joined)
                $output = if ($Arguments[0] -eq '--version') { '1.45.2' }
                elseif ($Arguments[0..1] -join ' ' -eq 'env who') {
                    '{"EnvironmentUrl":"https://another.crm4.dynamics.com"}'
                }
                else { '{}' }
                return @{ ExitCode = 0; Output = $output }
            }.GetNewClosure()

            { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployPowerPlatform `
                    -TenantId $tenantId -StatePath $statePath -CommandRunner $mismatchedContextRunner `
                    -GraphRunner $graphRunner } |
                Should -Throw '*Logging solution*Power Platform context*target environment mismatch*'

            $functionCloud.Published | Should -BeTrue
            @($powerPlatformCalls | Where-Object {
                $_ -like 'solution pack*' -or $_ -like 'solution import*' -or
                $_ -like 'solution publish*'
            }) | Should -HaveCount 0
            $saved = Get-Content -LiteralPath $statePath -Raw |
                ConvertFrom-Json -AsHashtable
            $saved.phases[4].status | Should -Be 'Completed'
            $saved.phases[5].status | Should -Be 'Pending'
        }

        It 'fails fast and removes the temporary archive when <Stage> fails' -ForEach @(
            @{
                Stage = 'authentication'; FailurePattern = 'auth create*'
                ErrorPattern = '*Logging solution*Interactive Power Platform authentication failed*'
                ForbiddenPattern = 'env who*'
            }
            @{
                Stage = 'packing'; FailurePattern = 'solution pack*'
                ErrorPattern = '*Logging solution*Packing Inventory Sync Logging*failed*'
                ForbiddenPattern = 'solution import*'
            }
            @{
                Stage = 'import'; FailurePattern = 'solution import*'
                ErrorPattern = '*Logging solution*Importing Inventory Sync Logging failed*'
                ForbiddenPattern = 'solution publish*'
            }
            @{
                Stage = 'publication'; FailurePattern = 'solution publish*'
                ErrorPattern = '*Logging solution*Publishing Dataverse customizations failed*'
                ForbiddenPattern = 'solution list*'
            }
            @{
                Stage = 'verification'; FailurePattern = 'solution list*'
                ErrorPattern = '*Logging solution*could not be verified*'
                ForbiddenPattern = 'env fetch*'
            }
        ) {
            $baseFunctionRunner = $functionRunner
            $powerPlatformCalls = [System.Collections.Generic.List[string]]::new()
            $artifactPaths = [System.Collections.Generic.List[string]]::new()
            $failingPowerPlatformRunner = {
                param($Command, $Arguments, $SensitiveArguments)
                if ($Command -ne 'pac') {
                    return & $baseFunctionRunner $Command $Arguments $SensitiveArguments
                }
                $joined = $Arguments -join ' '
                $powerPlatformCalls.Add($joined)
                if ($Arguments[0..1] -join ' ' -eq 'solution pack') {
                    $path = $Arguments[$Arguments.IndexOf('--zipfile') + 1]
                    $artifactPaths.Add($path)
                    Set-Content -LiteralPath $path -Value 'partial temporary archive'
                }
                if ($joined -like $FailurePattern) {
                    return @{ ExitCode = 1; Output = "simulated $Stage failure" }
                }
                $output = if ($Arguments[0] -eq '--version') { '1.45.2' }
                elseif ($Arguments[0..1] -join ' ' -eq 'env who') {
                    '{"EnvironmentUrl":"https://tenant.crm4.dynamics.com"}'
                }
                elseif ($Arguments[0..1] -join ' ' -eq 'solution list') {
                    '[{"UniqueName":"InventorySyncLogging","IsManaged":false}]'
                }
                else { '{}' }
                return @{ ExitCode = 0; Output = $output }
            }.GetNewClosure()

            { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployPowerPlatform `
                    -TenantId $tenantId -StatePath $statePath -CommandRunner $failingPowerPlatformRunner `
                    -GraphRunner $graphRunner } |
                Should -Throw $ErrorPattern

            @($powerPlatformCalls | Where-Object { $_ -like $ForbiddenPattern }) |
                Should -HaveCount 0
            foreach ($artifactPath in $artifactPaths) {
                $artifactPath | Should -Not -Exist
            }
            $saved = Get-Content -LiteralPath $statePath -Raw |
                ConvertFrom-Json -AsHashtable
            $saved.phases[4].status | Should -Be 'Completed'
            $saved.phases[5].status | Should -Be 'Pending'
            $saved.phases[6].status | Should -Be 'Pending'
        }

        It 'resumes safely after a transient solution import failure' {
            $baseFunctionRunner = $functionRunner
            $powerPlatformCalls = [System.Collections.Generic.List[string]]::new()
            $artifactPaths = [System.Collections.Generic.List[string]]::new()
            $failureState = @{ ImportPending = $true }
            $resumablePowerPlatformRunner = {
                param($Command, $Arguments, $SensitiveArguments)
                if ($Command -ne 'pac') {
                    return & $baseFunctionRunner $Command $Arguments $SensitiveArguments
                }
                $joined = $Arguments -join ' '
                $powerPlatformCalls.Add($joined)
                if ($Arguments[0..1] -join ' ' -eq 'solution pack') {
                    $path = $Arguments[$Arguments.IndexOf('--zipfile') + 1]
                    $artifactPaths.Add($path)
                    Set-Content -LiteralPath $path -Value 'temporary solution archive'
                }
                if ($Arguments[0..1] -join ' ' -eq 'solution import' -and
                    $failureState.ImportPending) {
                    $failureState.ImportPending = $false
                    return @{ ExitCode = 1; Output = 'transient import failure' }
                }
                $output = if ($Arguments[0] -eq '--version') { '1.45.2' }
                elseif ($Arguments[0..1] -join ' ' -eq 'env who') {
                    '{"EnvironmentUrl":"https://tenant.crm4.dynamics.com"}'
                }
                elseif ($Arguments[0..1] -join ' ' -eq 'solution list') {
                    '[{"UniqueName":"InventorySyncLogging","IsManaged":false}]'
                }
                else { '{}' }
                return @{ ExitCode = 0; Output = $output }
            }.GetNewClosure()

            { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployPowerPlatform `
                    -TenantId $tenantId -StatePath $statePath -CommandRunner $resumablePowerPlatformRunner `
                    -GraphRunner $graphRunner } |
                Should -Throw '*Logging solution*Importing Inventory Sync Logging failed*'

            $resumed = & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployPowerPlatform `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $resumablePowerPlatformRunner `
                -GraphRunner $graphRunner

            $resumed.Status | Should -Be 'DeploymentCompletedReadinessBlocked'
            @($powerPlatformCalls | Where-Object { $_ -like 'solution pack*' }) |
                Should -HaveCount 2
            @($powerPlatformCalls | Where-Object { $_ -like 'solution import*' }) |
                Should -HaveCount 2
            foreach ($artifactPath in $artifactPaths) {
                $artifactPath | Should -Not -Exist
            }
            @($graphRequests | Where-Object Operation -in @(
                'CreateApplication', 'CreateServicePrincipal', 'AssignGlobalReader', 'CreatePassword'
            )) | Should -HaveCount 3
            $saved = Get-Content -LiteralPath $statePath -Raw |
                ConvertFrom-Json -AsHashtable
            $saved.phases[5].status | Should -Be 'Completed'
            $saved.phases[6].status | Should -Be 'Completed'
        }
    }

    It 'rejects a Graph tenant mismatch before any cloud or identity mutation' {
        $graphContext.TenantId = '33333333-3333-3333-3333-333333333333'

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $azureRunner `
                -GraphRunner $graphRunner } |
            Should -Throw '*Runtime identity*Graph tenant mismatch*'

        @($calls | Where-Object { $_ -match 'create|set|Assign|Create' }) | Should -HaveCount 0
        $statePath | Should -Not -Exist
    }

    It 'creates one managed identity, assigns Global Reader, and reuses the existing credential' {
        $result = & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
            -TenantId $tenantId -StatePath $statePath -CommandRunner $azureRunner `
            -GraphRunner $graphRunner

        $result.Status | Should -Be 'IdentityValidated'
        $result.Identity.ApplicationId | Should -Be 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $result.Identity.ServicePrincipalId | Should -Be 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        $result.Identity.Credential.ExpiresOn.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') |
            Should -Be '2027-10-15T00:00:00Z'
        $result.Phases[0..3].Status | Should -Not -Contain 'Pending'
        @($graphRequests | Where-Object Operation -eq 'CreateApplication') | Should -HaveCount 1
        @($graphRequests | Where-Object Operation -eq 'CreateServicePrincipal') | Should -HaveCount 1
        @($graphRequests | Where-Object Operation -eq 'AssignGlobalReader') | Should -HaveCount 1
        @($graphRequests | Where-Object Operation -eq 'CreatePassword') | Should -HaveCount 0
        $createApplication = $graphRequests | Where-Object Operation -eq 'CreateApplication'
        $createApplication.Parameters.SignInAudience | Should -Be 'AzureADMyOrg'
        $createApplication.Parameters.Tags | Should -Contain "InventorySyncInstallation:$($tags.'inventory-sync-installation')"
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $saved.identity.applicationId | Should -Be $result.Identity.ApplicationId
        $saved.identity.servicePrincipalId | Should -Be $result.Identity.ServicePrincipalId
        $saved.identity.credential.expiresOn.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') |
            Should -Be '2027-10-15T00:00:00Z'
        Get-Content -LiteralPath $statePath -Raw | Should -Not -Match 'secretText|clientSecret|password'
    }

    It 'revalidates and reuses the managed identity and credential on rerun' {
        $first = & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
            -TenantId $tenantId -StatePath $statePath -CommandRunner $azureRunner `
            -GraphRunner $graphRunner
        $calls.Clear()
        $graphRequests.Clear()

        $second = & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
            -TenantId $tenantId -StatePath $statePath -CommandRunner $azureRunner `
            -GraphRunner $graphRunner

        $second.Status | Should -Be 'IdentityValidated'
        $second.Identity.ApplicationId | Should -Be $first.Identity.ApplicationId
        $second.Identity.ServicePrincipalId | Should -Be $first.Identity.ServicePrincipalId
        @($graphRequests | Where-Object Operation -in @(
            'CreateApplication', 'CreateServicePrincipal', 'AssignGlobalReader', 'CreatePassword'
        )) | Should -HaveCount 0
        @($calls | Where-Object { $_ -like 'azure:keyvault secret set*' }) | Should -HaveCount 0
        $second.Phases[2].SavedStatus | Should -Be 'Completed'
        $second.Phases[3].SavedStatus | Should -Be 'Completed'
    }

    It 'retains resumable identity context when Global Reader propagation is pending' {
        $rolePropagation.Pending = $true

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $azureRunner `
                -GraphRunner $graphRunner } |
            Should -Throw '*Runtime identity*Global Reader*pending propagation*rerun*'

        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $saved.identity.applicationId | Should -Be 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $saved.identity.servicePrincipalId | Should -Be 'cccccccc-cccc-cccc-cccc-cccccccccccc'
        $saved.identity.globalReaderAssignmentId | Should -Be 'YUb1sHQtUEyvox7IA_Eu_mm3jqnUe4lEhvatluHVi2I-1'
        $saved.phases[2].status | Should -Be 'Pending'
        @($calls | Where-Object { $_ -like 'azure:keyvault secret*' }) | Should -HaveCount 0
        @($graphRequests | Where-Object Operation -eq 'CreatePassword') | Should -HaveCount 0
        Get-Content -LiteralPath $statePath -Raw | Should -Not -Match 'secretText|clientSecret|password'

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $azureRunner `
                -GraphRunner $graphRunner } |
            Should -Throw '*Runtime identity*Global Reader*pending propagation*'
        @($graphRequests | Where-Object Operation -eq 'AssignGlobalReader') | Should -HaveCount 1

        $rolePropagation.Pending = $false
        $result = & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
            -TenantId $tenantId -StatePath $statePath -CommandRunner $azureRunner `
            -GraphRunner $graphRunner
        $result.Status | Should -Be 'IdentityValidated'
        @($graphRequests | Where-Object Operation -eq 'AssignGlobalReader') | Should -HaveCount 1
    }

    It 'stops with identity-phase context when Global Reader assignment fails' {
        $graphFailure.Operation = 'AssignGlobalReader'
        $graphFailure.Message = 'Authorization_RequestDenied: privileged role required'

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $azureRunner `
                -GraphRunner $graphRunner } |
            Should -Throw '*Runtime identity*Global Reader assignment failed*privileged role required*'

        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $saved.phases[2].status | Should -Be 'Pending'
        @($calls | Where-Object { $_ -like 'azure:keyvault secret*' }) | Should -HaveCount 0
        @($graphRequests | Where-Object Operation -eq 'CreatePassword') | Should -HaveCount 0
    }

    It 'refuses ambiguous app registrations instead of guessing which identity to reuse' {
        $identity.Application = @(
            @{
                Id = '10101010-1010-1010-1010-101010101010'
                AppId = '20202020-2020-2020-2020-202020202020'
                DisplayName = $plan.ResourceNames.appRegistration
                SignInAudience = 'AzureADMyOrg'
                Tags = @("InventorySyncInstallation:$($tags.'inventory-sync-installation')")
            }
            @{
                Id = '30303030-3030-3030-3030-303030303030'
                AppId = '40404040-4040-4040-4040-404040404040'
                DisplayName = $plan.ResourceNames.appRegistration
                SignInAudience = 'AzureADMyOrg'
                Tags = @("InventorySyncInstallation:$($tags.'inventory-sync-installation')")
            }
        )

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $azureRunner `
                -GraphRunner $graphRunner } |
            Should -Throw '*Runtime identity*multiple app registrations*ambiguity*'

        @($graphRequests | Where-Object Operation -in @(
            'CreateApplication', 'CreateServicePrincipal', 'AssignGlobalReader', 'CreatePassword'
        )) | Should -HaveCount 0
    }

    It 'uses the interactive Graph adapter without requiring callers to supply one' {
        Mock Get-Module {
            @(
                @{ Name = 'Microsoft.Graph.Authentication' }
                @{ Name = 'Microsoft.Graph.Applications' }
                @{ Name = 'Microsoft.Graph.Identity.Governance' }
            )
        } -ParameterFilter { $ListAvailable -and 'Microsoft.Graph.Authentication' -in $Name }
        Mock Connect-MgGraph { }
        Mock Get-MgContext {
            [pscustomobject] @{ TenantId = $tenantId; AuthType = 'Delegated'; Account = 'operator@example.test' }
        }
        Mock Invoke-MgGraphRequest {
            if ($Method -eq 'GET') {
                if ($Uri -like '*applications?*') { return @{ value = @() } }
                if ($Uri -like '*servicePrincipals?*') { return @{ value = @() } }
                if ($Uri -like '*roleDefinitions?*') {
                    return @{ value = @(@{
                        id = 'dddddddd-dddd-dddd-dddd-dddddddddddd'
                        templateId = 'f2ef992c-3afb-46b9-b7cf-a126ee74c451'
                    }) }
                }
                if ($Uri -like '*roleAssignments?*') {
                    return @{ value = @(
                        if ($identity.RoleAssignment) { $identity.RoleAssignment }
                    ) }
                }
            }
            if ($Method -eq 'POST') {
                $requestBody = $Body | ConvertFrom-Json -AsHashtable
                if ($Uri -like '*/applications') {
                    return @{
                        id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
                        appId = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
                        displayName = $requestBody.displayName
                        signInAudience = $requestBody.signInAudience
                        tags = $requestBody.tags
                    }
                }
                if ($Uri -like '*/servicePrincipals') {
                    return @{
                        id = 'cccccccc-cccc-cccc-cccc-cccccccccccc'
                        appId = $requestBody.appId
                    }
                }
                if ($Uri -like '*/roleAssignments') {
                    $identity.RoleAssignment = @{
                        id = 'YUb1sHQtUEyvox7IA_Eu_mm3jqnUe4lEhvatluHVi2I-1'
                        principalId = $requestBody.principalId
                        roleDefinitionId = $requestBody.roleDefinitionId
                        directoryScopeId = $requestBody.directoryScopeId
                    }
                    return $identity.RoleAssignment
                }
            }
            throw "Unexpected Graph request: $Method $Uri"
        }

        $result = & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
            -TenantId $tenantId -StatePath $statePath -CommandRunner $azureRunner

        $result.Status | Should -Be 'IdentityValidated'
        $result.Identity.ApplicationId | Should -Be 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        Should -Invoke Connect-MgGraph -Times 1 -Exactly -ParameterFilter {
            $TenantId -eq '22222222-2222-2222-2222-222222222222' -and
            $ContextScope -eq 'Process' -and $NoWelcome -and
            'Application.ReadWrite.All' -in $Scopes -and
            'RoleManagement.ReadWrite.Directory' -in $Scopes
        }
    }

    It 'creates one 12-month credential and stores it directly in Key Vault when missing' {
        $vaultState.Versions = @()
        $clock = { [datetimeoffset] '2026-10-15T08:00:00Z' }

        $result = & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
            -TenantId $tenantId -StatePath $statePath -CommandRunner $azureRunner `
            -GraphRunner $graphRunner -Clock $clock

        $passwordRequest = $graphRequests | Where-Object Operation -eq 'CreatePassword'
        $passwordRequest | Should -HaveCount 1
        $passwordRequest.Parameters.EndDateTime | Should -Be '2027-10-15T08:00:00.0000000+00:00'
        @($calls | Where-Object { $_ -like 'azure:keyvault secret set*' }) | Should -HaveCount 1
        ($result | ConvertTo-Json -Depth 20) | Should -Not -Match $generatedSecret
        $result.Identity.Credential.KeyVaultSecretVersion | Should -Be 'new-version'
        $result.Identity.Credential.ExpiresOn.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') |
            Should -Be '2027-10-15T08:00:00Z'
        $savedContent = Get-Content -LiteralPath $statePath -Raw
        $savedContent | Should -Not -Match $generatedSecret
        $saved = $savedContent | ConvertFrom-Json -AsHashtable
        $saved.identity.credential.keyId | Should -Be 'ffffffff-ffff-ffff-ffff-ffffffffffff'
        $saved.identity.credential.status | Should -Be 'Stored'
    }

    It 'refuses an application password whose returned expiry exceeds the agreed 12 months' {
        $vaultState.Versions = @()
        $normalGraphRunner = $graphRunner
        $invalidExpiryRunner = {
            param($Operation, $Parameters)
            $result = & $normalGraphRunner $Operation $Parameters
            if ($Operation -eq 'CreatePassword') { $result.EndDateTime = '2030-01-01T00:00:00Z' }
            return $result
        }.GetNewClosure()

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $azureRunner `
                -GraphRunner $invalidExpiryRunner -Clock { [datetimeoffset] '2026-10-15T08:00:00Z' } } |
            Should -Throw '*Runtime credential*unexpected credential expiry*retained key ID*'
        @($calls | Where-Object { $_ -like 'azure:keyvault secret set*' }) | Should -HaveCount 0
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $saved.identity.credential.keyId | Should -Be 'ffffffff-ffff-ffff-ffff-ffffffffffff'
        $saved.identity.credential.status | Should -Be 'PendingKeyVaultWrite'
    }

    It 'refuses an existing credential belonging to another identity without replacing it' {
        $vaultState.Versions[0].tags.'application-id' = '99999999-9999-9999-9999-999999999999'

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $azureRunner `
                -GraphRunner $graphRunner } |
            Should -Throw '*Runtime credential*ownership*'

        @($graphRequests | Where-Object Operation -eq 'CreatePassword') | Should -HaveCount 0
        @($calls | Where-Object { $_ -like 'azure:keyvault secret set*' }) | Should -HaveCount 0
    }

    It 'never silently rotates a disabled, expired, or invalid existing credential' -ForEach @(
        @{ Invalid = 'disabled'; Pattern = '*Runtime credential*disabled or expired*' }
        @{ Invalid = 'expired'; Pattern = '*Runtime credential*disabled or expired*' }
        @{ Invalid = 'expiry'; Pattern = '*Runtime credential*invalid expiry metadata*' }
        @{ Invalid = 'enabled'; Pattern = '*Runtime credential*invalid enabled metadata*' }
    ) {
        switch ($Invalid) {
            'disabled' { $vaultState.Versions[0].attributes.enabled = $false }
            'expired' { $vaultState.Versions[0].attributes.expires = '2000-01-01T00:00:00Z' }
            'expiry' { $vaultState.Versions[0].attributes.expires = 'invalid-date' }
            'enabled' { $vaultState.Versions[0].attributes.Remove('enabled') }
        }

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $azureRunner `
                -GraphRunner $graphRunner } | Should -Throw $Pattern
        @($graphRequests | Where-Object Operation -eq 'CreatePassword') | Should -HaveCount 0
        @($calls | Where-Object { $_ -like 'azure:keyvault secret set*' }) | Should -HaveCount 0
    }

    It 'reuses the enabled current secret when disabled historical versions remain' {
        $vaultState.Versions += @{
            id = 'https://example.vault.azure.net/secrets/inventory-sync-client-secret/stale-version'
            attributes = @{ enabled = $false; expires = '2026-01-01T00:00:00Z' }
            tags = $vaultState.Versions[0].tags.Clone()
        }

        $result = & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
            -TenantId $tenantId -StatePath $statePath -CommandRunner $azureRunner `
            -GraphRunner $graphRunner

        $result.Status | Should -Be 'IdentityValidated'
        $result.Identity.Credential.KeyVaultSecretVersion | Should -Be 'existing-version'
        @($graphRequests | Where-Object Operation -eq 'CreatePassword') | Should -HaveCount 0
    }

    It 'refuses to duplicate an orphaned managed password even when local state is missing' {
        $vaultState.Versions = @()
        $identity.Passwords = @(@{
            keyId = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
            displayName = 'palp-inventory-sync-keyvault'
            endDateTime = '2027-10-15T00:00:00Z'
        })

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $azureRunner `
                -GraphRunner $graphRunner } |
            Should -Throw '*Runtime credential*managed application password already exists*'

        @($graphRequests | Where-Object Operation -eq 'CreatePassword') | Should -HaveCount 0
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $saved.identity.credential.keyId | Should -Be 'ffffffff-ffff-ffff-ffff-ffffffffffff'
        $saved.identity.credential.status | Should -Be 'PendingKeyVaultWrite'
    }

    It 'refuses a changed identity rather than replacing the saved application on resume' {
        & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
            -TenantId $tenantId -StatePath $statePath -CommandRunner $azureRunner `
            -GraphRunner $graphRunner | Out-Null
        $identity.Application = $null
        $calls.Clear()
        $graphRequests.Clear()

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $azureRunner `
                -GraphRunner $graphRunner } |
            Should -Throw '*Runtime identity*saved application*missing or changed*'
        @($graphRequests | Where-Object Operation -eq 'CreateApplication') | Should -HaveCount 0
        @($graphRequests | Where-Object Operation -eq 'CreatePassword') | Should -HaveCount 0
    }

    It 'redacts a failed Key Vault write and refuses to create a duplicate password on resume' {
        $vaultState.Versions = @()
        $vaultState.WriteFailure = 'Forbidden: secret set denied'
        $caught = $null

        try {
            & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $azureRunner `
                -GraphRunner $graphRunner | Out-Null
        }
        catch {
            $caught = $_
        }

        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Message | Should -Match 'Runtime credential.*Key Vault write failed'
        $caught.Exception.Message | Should -Match 'Forbidden'
        $caught.Exception.Message | Should -Not -Match $generatedSecret
        ($calls -join "`n") | Should -Not -Match $generatedSecret
        $savedContent = Get-Content -LiteralPath $statePath -Raw
        $savedContent | Should -Not -Match $generatedSecret
        $saved = $savedContent | ConvertFrom-Json -AsHashtable
        $saved.identity.credential.keyId | Should -Be 'ffffffff-ffff-ffff-ffff-ffffffffffff'
        $saved.identity.credential.status | Should -Be 'PendingKeyVaultWrite'
        $saved.phases[3].status | Should -Be 'Pending'
        $vaultState.WriteFailure = $null

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $azureRunner `
                -GraphRunner $graphRunner } |
            Should -Throw '*previously created application password*retained key ID*no duplicate*'
        @($graphRequests | Where-Object Operation -eq 'CreatePassword') | Should -HaveCount 1
    }

    It 'does not disclose credential values emitted by a failing external adapter' {
        $vaultState.Versions = @()
        $normalRunner = $azureRunner
        $noisyRunner = {
            param($Command, $Arguments, $SensitiveArguments)
            if ($SensitiveArguments) {
                Write-Warning $SensitiveArguments.Value
                Write-Verbose $SensitiveArguments.Value -Verbose
                Write-Information $SensitiveArguments.Value -InformationAction Continue
                throw "Forbidden: $($SensitiveArguments.Value)"
            }
            & $normalRunner $Command $Arguments
        }
        $transcriptPath = Join-Path $TestDrive 'redaction-transcript.txt'
        $observed = [System.Collections.Generic.List[object]]::new()
        $caught = $null
        Start-Transcript -LiteralPath $transcriptPath | Out-Null
        try {
            & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployIdentity `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $noisyRunner `
                -GraphRunner $graphRunner -Verbose *>&1 | ForEach-Object { $observed.Add($_) }
        }
        catch { $caught = $_ }
        finally { Stop-Transcript | Out-Null }

        $caught | Should -Not -BeNullOrEmpty
        $caught.Exception.Message | Should -Match 'Runtime credential'
        $caught.Exception.Message | Should -Not -Match $generatedSecret
        ($Error | ForEach-Object { $_.Exception.ToString() } | Out-String) |
            Should -Not -Match $generatedSecret
        ($observed | Out-String) | Should -Not -Match $generatedSecret
        Get-Content -LiteralPath $transcriptPath -Raw | Should -Not -Match $generatedSecret
        Get-Content -LiteralPath $statePath -Raw | Should -Not -Match $generatedSecret
    }
}

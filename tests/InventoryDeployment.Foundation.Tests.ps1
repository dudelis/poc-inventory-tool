BeforeAll {
    $script:bootstrapPath = Join-Path $PSScriptRoot '..\deploy\Invoke-InventoryDeployment.ps1'
    $script:examplePath = Join-Path $PSScriptRoot '..\deploy\example.parameters.json'
    $script:tenantId = '22222222-2222-2222-2222-222222222222'
    $script:subscriptionId = '11111111-1111-1111-1111-111111111111'
    $script:compiledTemplates = @{}
    Get-ChildItem (Join-Path $PSScriptRoot '..\deploy') -Filter '*.bicep' -Recurse | ForEach-Object {
        $json = & az bicep build --file $_.FullName --stdout --no-restore
        if ($LASTEXITCODE -ne 0) { throw "Bicep compilation failed: $($_.Name)" }
        $script:compiledTemplates[$_.Name] = $json -join "`n"
    }
}

Describe 'Azure foundation deployment' {
BeforeEach {
    $configuration = Get-Content -LiteralPath $examplePath -Raw | ConvertFrom-Json -AsHashtable
    $configuration.subscriptionId = $subscriptionId
    $script:configurationPath = Join-Path $TestDrive 'parameters.json'
    $configuration | ConvertTo-Json | Set-Content -LiteralPath $configurationPath
    $script:calls = [System.Collections.Generic.List[string]]::new()
    $script:account = @{
        id = $subscriptionId; tenantId = $tenantId; state = 'Enabled'
        user = @{ type = 'user'; name = 'operator@example.test' }
    }
    $script:cloud = @{ Exists = $false; NameAvailable = $true; VaultNameAvailable = $true }
    $script:deploymentFailure = $null
    $script:runner = {
        param($Command, $Arguments)
        $calls.Add($Arguments -join ' ')
        switch ($Arguments[0]) {
            'version' { return @{ ExitCode = 0; Output = '{}' } }
            'bicep' {
                $output = if ($Arguments[1] -eq 'version') { 'Bicep CLI' }
                else { $compiledTemplates[[IO.Path]::GetFileName($Arguments[3])] }
                return @{ ExitCode = 0; Output = $output }
            }
            'account' { return @{ ExitCode = 0; Output = ($account | ConvertTo-Json -Depth 5) } }
            'group' {
                $output = switch ($Arguments[1]) {
                    'exists' { $cloud.Exists | ConvertTo-Json }
                    'create' {
                        $cloud.Exists = $true
                        $group | ConvertTo-Json -Depth 5
                    }
                    'show' { $group | ConvertTo-Json -Depth 5 }
                    default { throw "Unexpected group command: $($Arguments -join ' ')" }
                }
                return @{ ExitCode = 0; Output = $output }
            }
            'resource' {
                $output = if ($Arguments[1] -eq 'list') {
                    ConvertTo-Json -InputObject @($resources) -Depth 10
                }
                elseif ($Arguments[1] -eq 'show') {
                    $resource = $resources | Where-Object id -eq $Arguments[3]
                    if ($null -eq $resource) { throw 'Unexpected resource ID.' }
                    $resource | ConvertTo-Json -Depth 10
                }
                else { throw "Unexpected resource command: $($Arguments -join ' ')" }
                return @{ ExitCode = 0; Output = $output }
            }
            'storage' {
                return @{ ExitCode = 0; Output = (@{ nameAvailable = $cloud.NameAvailable } | ConvertTo-Json) }
            }
            'rest' {
                $Arguments[1..3] | Should -Be @('--method', 'post', '--url')
                $Arguments[4] | Should -Be "/subscriptions/$subscriptionId/providers/Microsoft.KeyVault/checkNameAvailability?api-version=2024-11-01"
                $Arguments[5] | Should -Be '--body'
                $Arguments[6] | Should -Match '^@'
                $request = Get-Content -LiteralPath $Arguments[6].Substring(1) -Raw | ConvertFrom-Json -AsHashtable
                $request.name | Should -Be $plan.ResourceNames.keyVault
                $request.type | Should -Be 'Microsoft.KeyVault/vaults'
                return @{ ExitCode = 0; Output = (@{ nameAvailable = $cloud.VaultNameAvailable } | ConvertTo-Json) }
            }
            'deployment' {
                if ($Arguments[1] -eq 'sub' -and $Arguments[2] -eq 'create') {
                    $cloud.Exists = $true
                    return @{ ExitCode = 0; Output = '{"properties":{"provisioningState":"Succeeded"}}' }
                }
                if ($deploymentFailure -and $Arguments[2] -eq $cloud.FailureAt) {
                    return @{ ExitCode = 1; Output = $deploymentFailure }
                }
                if ($Arguments[1] -ne 'group' -or $Arguments[2] -notin @('validate', 'create')) {
                    throw "Unexpected deployment command: $($Arguments -join ' ')"
                }
                if ($Arguments[2] -eq 'create') {
                    $cloud.Exists = $true
                }
                return @{ ExitCode = 0; Output = '{"properties":{"provisioningState":"Succeeded"}}' }
            }
            default { throw "Unexpected command: $Command $($Arguments -join ' ')" }
        }
    }
    $script:plan = & $bootstrapPath -ConfigurationPath $configurationPath -CommandRunner $runner
    $calls.Clear()
    $script:tags = @{
        'inventory-sync-installation' = $plan.ResourceNames.storage.Substring($plan.ResourceNames.storage.Length - 12)
        'inventory-sync-workload' = 'palp-inventory-sync'
    }
    $script:group = @{ name = $plan.ResourceNames.resourceGroup; location = 'northeurope'; tags = $tags }
    $script:resources = @(
        @{ type = 'Microsoft.Storage/storageAccounts'; name = $plan.ResourceNames.storage
            kind = 'StorageV2'; sku = @{ name = 'Standard_LRS' }
            properties = @{ provisioningState = 'Succeeded'; allowBlobPublicAccess = $false
                supportsHttpsTrafficOnly = $true; minimumTlsVersion = 'TLS1_2'
                publicNetworkAccess = 'Enabled'; networkAcls = @{ defaultAction = 'Allow' } } }
        @{ type = 'Microsoft.KeyVault/vaults'; name = $plan.ResourceNames.keyVault
            properties = @{ provisioningState = 'Succeeded'; tenantId = $tenantId
                enableRbacAuthorization = $true; enableSoftDelete = $true; enablePurgeProtection = $true
                publicNetworkAccess = 'Enabled'; networkAcls = @{ defaultAction = 'Allow' }
                sku = @{ family = 'A'; name = 'standard' }; softDeleteRetentionInDays = 90 } }
        @{ type = 'Microsoft.OperationalInsights/workspaces'; name = $plan.ResourceNames.logAnalytics
            properties = @{ provisioningState = 'Succeeded'; retentionInDays = 30
                sku = @{ name = 'PerGB2018' }
                publicNetworkAccessForIngestion = 'Enabled'; publicNetworkAccessForQuery = 'Enabled' } }
        @{ type = 'Microsoft.Insights/components'; name = $plan.ResourceNames.applicationInsights
            kind = 'web'
            properties = @{ provisioningState = 'Succeeded'; Application_Type = 'web'
                WorkspaceResourceId = "/subscriptions/$subscriptionId/resourceGroups/$($group.name)/providers/Microsoft.OperationalInsights/workspaces/$($plan.ResourceNames.logAnalytics)"
                publicNetworkAccessForIngestion = 'Enabled'; publicNetworkAccessForQuery = 'Enabled' } }
    )
    foreach ($resource in $resources) {
        $resource.id = "/subscriptions/$subscriptionId/resourceGroups/$($group.name)/providers/$($resource.type)/$($resource.name)"
        $resource.location = 'northeurope'
        $resource.tags = $tags.Clone()
    }
}

    It 'rejects a different active subscription before any cloud mutation' {
        $account.id = '33333333-3333-3333-3333-333333333333'

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFoundation `
                -TenantId $tenantId -CommandRunner $runner } |
            Should -Throw '*Preflight*subscription*mismatch*az account set*'
        @($calls | Where-Object { $_ -match 'create|delete|set|login' }) | Should -HaveCount 0
    }

    It 'compiles a secure public-endpoint foundation with workspace-based telemetry' {
        $compiledTemplates['foundation.bicep'] | Should -Not -BeNullOrEmpty
        $template = $compiledTemplates['foundation.bicep'] | ConvertFrom-Json -AsHashtable
        $template.resources | Should -HaveCount 4
        $storage = $template.resources | Where-Object type -eq 'Microsoft.Storage/storageAccounts'
        $storage.kind | Should -Be 'StorageV2'
        $storage.sku.name | Should -Be 'Standard_LRS'
        $storage.properties.allowBlobPublicAccess | Should -BeFalse
        $storage.properties.supportsHttpsTrafficOnly | Should -BeTrue
        $storage.properties.minimumTlsVersion | Should -Be 'TLS1_2'
        $storage.properties.publicNetworkAccess | Should -Be 'Enabled'
        $vault = $template.resources | Where-Object type -eq 'Microsoft.KeyVault/vaults'
        $vault.properties.enableRbacAuthorization | Should -BeTrue
        $vault.properties.enableSoftDelete | Should -BeTrue
        $vault.properties.enablePurgeProtection | Should -BeTrue
        $vault.properties.publicNetworkAccess | Should -Be 'Enabled'
        $template.parameters.logRetentionDays.defaultValue | Should -Be 30
        $workspace = $template.resources | Where-Object type -eq 'Microsoft.OperationalInsights/workspaces'
        $workspace.properties.retentionInDays | Should -Be "[parameters('logRetentionDays')]"
        $insights = $template.resources | Where-Object type -eq 'Microsoft.Insights/components'
        $insights.properties.WorkspaceResourceId | Should -Match 'Microsoft.OperationalInsights/workspaces'
        @($template.resources | Where-Object type -match 'private|virtualNetwork') | Should -HaveCount 0
    }

    It 'deploys only the dedicated foundation incrementally and persists validated completion' {
        $statePath = Join-Path $TestDrive 'foundation.state.json'
        $result = & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFoundation `
            -TenantId $tenantId -StatePath $statePath -CommandRunner $runner

        $result.Status | Should -Be 'FoundationValidated'
        $result.AzureContext.tenantId | Should -Be $tenantId
        $result.CloudChangesMade | Should -BeTrue
        $result.Phases[0].Status | Should -Be 'Completed'
        $result.Phases[1].Status | Should -Be 'Completed'
        @($result.Phases | Select-Object -Skip 2 | Where-Object Status -ne 'Pending') | Should -HaveCount 0
        $groupDeployment = @($calls | Where-Object { $_ -like 'deployment sub create*' })
        $groupDeployment | Should -HaveCount 1
        $groupDeployment[0] | Should -Match 'foundation-group.bicep'
        $groupDeployment[0] | Should -Match '--location northeurope'
        $groupDeployment[0] | Should -Match "resourceGroupName=$($group.name)"
        $deployment = @($calls | Where-Object { $_ -like 'deployment group create*' })
        $deployment | Should -HaveCount 1
        $deployment[0] | Should -Match '--mode Incremental'
        $deployment[0] | Should -Match 'foundation.bicep'
        $deployment[0] | Should -Match "--subscription $subscriptionId"
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $saved.phases[1].status | Should -Be 'Completed'
        Get-Content -LiteralPath $statePath -Raw | Should -Not -Match 'tenantId|secret|token|operator'
    }

    It 'refuses to adopt an existing unowned resource before deployment' -ForEach @(
        @{ Conflict = 'group' }
        @{ Conflict = 'storage' }
    ) {
        $cloud.Exists = $true
        if ($Conflict -eq 'group') { $group.tags = @{} }
        else { $resources[0].tags = @{} }

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFoundation `
                -TenantId $tenantId -CommandRunner $runner } |
            Should -Throw '*Azure foundation*tags.inventory-sync-*'
        @($calls | Where-Object { $_ -match 'group create|deployment group (create|validate)' }) |
            Should -HaveCount 0
    }

    It 'revalidates saved completion and refuses incompatible resources before updating' -ForEach @(
        @{ Conflict = 'storage' }
        @{ Conflict = 'vault-tenant' }
        @{ Conflict = 'vault-retention' }
        @{ Conflict = 'workspace-link' }
    ) {
        $statePath = Join-Path $TestDrive "$Conflict.state.json"
        & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFoundation `
            -TenantId $tenantId -StatePath $statePath -CommandRunner $runner | Out-Null
        switch ($Conflict) {
            'storage' { $resources[0].kind = 'BlobStorage' }
            'vault-tenant' { $resources[1].properties.tenantId = '33333333-3333-3333-3333-333333333333' }
            'vault-retention' { $resources[1].properties.softDeleteRetentionInDays = 7 }
            'workspace-link' { $resources[3].properties.WorkspaceResourceId = '/another-workspace' }
        }
        $calls.Clear()

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFoundation `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $runner } |
            Should -Throw '*Azure foundation*incompatible resource*'
        @($calls | Where-Object { $_ -match 'group create|deployment group (create|validate)' }) |
            Should -HaveCount 0
    }

    It 'checks missing global names when resuming a partially created group' {
        $cloud.Exists = $true
        $cloud.NameAvailable = $false
        $script:resources = @()

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFoundation `
                -TenantId $tenantId -CommandRunner $runner } |
            Should -Throw '*Azure foundation*global name*unavailable*'
        @($calls | Where-Object { $_ -match 'group create|deployment group (create|validate)' }) |
            Should -HaveCount 0
    }

    It 'reports an invalid Azure account response before creating state or resources' {
        $script:account = @{ id = $subscriptionId }
        $statePath = Join-Path $TestDrive 'bad-context.state.json'

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFoundation `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $runner } |
            Should -Throw '*Preflight*invalid account response*az login*'
        $statePath | Should -Not -Exist
        @($calls | Where-Object { $_ -match 'create|set|login' }) | Should -HaveCount 0
    }

    It 'rejects tenant mismatch and non-interactive or disabled accounts before mutation' -ForEach @(
        @{ Change = 'tenant'; ErrorPattern = '*Preflight*tenant mismatch*az login*' }
        @{ Change = 'user'; ErrorPattern = '*Preflight*interactively authenticated user*' }
        @{ Change = 'state'; ErrorPattern = '*Preflight*enabled subscription*' }
    ) {
        switch ($Change) {
            'tenant' { $account.tenantId = '33333333-3333-3333-3333-333333333333' }
            'user' { $account.user.type = 'servicePrincipal' }
            'state' { $account.state = 'Disabled' }
        }

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFoundation `
                -TenantId $tenantId -CommandRunner $runner } | Should -Throw $ErrorPattern
        @($calls | Where-Object { $_ -match 'create|set|login' }) | Should -HaveCount 0
    }

    It 'reruns incrementally without recreating the group or trusting saved completion' {
        $statePath = Join-Path $TestDrive 'rerun.state.json'
        $first = & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFoundation `
            -TenantId $tenantId -StatePath $statePath -CommandRunner $runner
        $calls.Clear()

        $second = & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFoundation `
            -TenantId $tenantId -StatePath $statePath -CommandRunner $runner

        $second.Status | Should -Be 'FoundationValidated'
        $second.ResourceNames | ConvertTo-Json | Should -Be ($first.ResourceNames | ConvertTo-Json)
        $second.Phases[1].SavedStatus | Should -Be 'Completed'
        $second.Phases[1].NeedsRevalidation | Should -BeFalse
        @($calls | Where-Object { $_ -match '^group create|^deployment sub create' }) | Should -HaveCount 0
        @($calls | Where-Object { $_ -like 'resource show*' }) | Should -HaveCount 8
        @($calls | Where-Object { $_ -like 'deployment group create*' }) | Should -HaveCount 1
    }

    It 'stops on actionable Azure deployment failures without recording completion' -ForEach @(
        @{ FailureAt = 'validate'; Failure = 'RequestDisallowedByPolicy: public endpoints prohibited' }
        @{ FailureAt = 'validate'; Failure = 'MissingSubscriptionRegistration: Microsoft.Storage' }
        @{ FailureAt = 'validate'; Failure = 'AuthorizationFailed: deployment permission denied' }
        @{ FailureAt = 'create'; Failure = 'QuotaExceeded: workspace quota exceeded' }
    ) {
        $cloud.FailureAt = $FailureAt
        $script:deploymentFailure = $Failure
        $statePath = Join-Path $TestDrive 'failure.state.json'

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFoundation `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $runner } |
            Should -Throw "*Azure foundation*$Failure*"
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        @($saved.phases | Where-Object status -ne 'Pending') | Should -HaveCount 0
        @($calls | Where-Object { $_ -like 'resource show*' }) | Should -HaveCount 0
        if ($FailureAt -eq 'validate') {
            @($calls | Where-Object { $_ -like 'deployment group create*' }) | Should -HaveCount 0
        }
    }

    It 'does not record completion if Azure reports success but deployed security settings are wrong' {
        $resources[0].properties.allowBlobPublicAccess = $true
        $statePath = Join-Path $TestDrive 'invalid-result.state.json'

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFoundation `
                -TenantId $tenantId -StatePath $statePath -CommandRunner $runner } |
            Should -Throw '*Azure foundation*allowBlobPublicAccess*'
        $saved = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $saved.phases[1].status | Should -Be 'Pending'
    }

    It 'refuses an ambiguous foundation name or type in an existing dedicated group' {
        $cloud.Exists = $true
        $resources[0].name = 'some-other-storage'

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFoundation `
                -TenantId $tenantId -CommandRunner $runner } |
            Should -Throw '*Azure foundation*ambiguous resource*'
        @($calls | Where-Object { $_ -match 'group create|deployment group (create|validate)' }) |
            Should -HaveCount 0
    }

    It 'checks the ordinary vault namespace before creating a resource group' {
        $cloud.VaultNameAvailable = $false

        { & $bootstrapPath -ConfigurationPath $configurationPath -Mode DeployFoundation `
                -TenantId $tenantId -CommandRunner $runner } |
            Should -Throw '*Azure foundation*global name*unavailable*'
        @($calls | Where-Object { $_ -like 'rest*Microsoft.KeyVault/checkNameAvailability*' }) | Should -HaveCount 1
        @($calls | Where-Object { $_ -match 'create|keyvault check-name' }) | Should -HaveCount 0
        $requestCall = $calls | Where-Object { $_ -like 'rest*' }
        $requestPath = ($requestCall -split '--body @')[1] -split ' --subscription'
        $requestPath[0] | Should -Not -Exist
    }
}

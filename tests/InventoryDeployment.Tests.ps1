BeforeAll {
    $script:bootstrapPath = Join-Path $PSScriptRoot '..\deploy\Invoke-InventoryDeployment.ps1'
    $script:examplePath = Join-Path $PSScriptRoot '..\deploy\example.parameters.json'
    $compiledJson = & az bicep build --file (Join-Path $PSScriptRoot '..\deploy\main.bicep') --stdout
    if ($LASTEXITCODE -ne 0) { throw 'Test prerequisite: real Bicep compilation failed.' }
    $script:offlineRunner = {
        param($Command, $Arguments)
        if ($Command -ne 'az') { throw "Unexpected command: $Command" }
        if ($Arguments[0] -eq 'version') {
            return @{ ExitCode = 0; Output = '{"azure-cli":"2.91.0"}' }
        }
        if ($Arguments[0] -eq 'bicep' -and $Arguments[1] -eq 'version') {
            return @{ ExitCode = 0; Output = 'Bicep CLI version 0.48.1' }
        }
        if ($Arguments[0] -eq 'bicep' -and $Arguments[1] -eq 'build') {
            return @{ ExitCode = 0; Output = ($compiledJson -join "`n") }
        }
        throw "Unexpected offline arguments: $($Arguments -join ' ')"
    }.GetNewClosure()
}

Describe 'Offline inventory deployment contract' {
    It 'validates the example and plans a safely disabled installation without cloud access' {
        $calls = [System.Collections.Generic.List[string]]::new()
        $runner = {
            param($Command, $Arguments)
            if ($Command -ne 'az' -or $Arguments[0] -notin @('version', 'bicep') -or
                ($Arguments[0] -eq 'bicep' -and $Arguments[1] -notin @('version', 'build'))) {
                throw "Unexpected offline command: $Command $($Arguments -join ' ')"
            }
            $calls.Add("$Command $($Arguments -join ' ')")
            $output = & $Command @Arguments 2>&1
            @{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
        }.GetNewClosure()

        $plan = & $bootstrapPath -ConfigurationPath $examplePath -CommandRunner $runner

        $plan.Status | Should -Be 'PlanValidated'
        $plan.CloudChangesMade | Should -BeFalse
        $plan.Compilation | Should -HaveCount 1
        $plan.Configuration.location | Should -Be 'northeurope'
        $plan.Configuration.instanceMemoryMB | Should -Be 2048
        $plan.Configuration.maximumInstanceCount | Should -Be 20
        $plan.Configuration.logRetentionDays | Should -Be 30
        $plan.ApplicationSettings.'AzureWebJobs.AgentSyncTimer.Disabled' | Should -Be 'true'
        $plan.ApplicationSettings.'AzureWebJobs.RpaSyncTimer.Disabled' | Should -Be 'true'
        $plan.ApplicationSettings.INVENTORY_AGENT_SCHEDULE | Should -Be '0 0 0 * * *'
        $plan.ApplicationSettings.INVENTORY_RPA_SCHEDULE | Should -Be '0 0 1 * * *'
        $plan.ApplicationSettings.INVENTORY_MAX_CREATES_PER_RUN | Should -Be '5'
        $plan.ApplicationSettings.INVENTORY_RPA_MAX_PARALLEL_ENVIRONMENTS | Should -Be '5'
        $plan.ApplicationSettings.AzureWebJobsStorage__credential | Should -Be 'managedidentity'
        $plan.ApplicationSettings.Contains('AzureWebJobsStorage') | Should -BeFalse
        $plan.ApplicationSettings.INVENTORY_CLIENT_SECRET | Should -BeLike '@Microsoft.KeyVault(SecretUri=https://*/secrets/inventory-sync-client-secret/)'
        $plan.ApplicationSettings.INVENTORY_TARGET_DATAVERSE_URL | Should -Be 'https://example.crm.dynamics.com'
        $plan.ApplicationSettings.INVENTORY_AGENT_CREATED_IN | Should -Be '<agent-created-in>'
        $plan.Resources.storage.sku | Should -Be 'Standard_LRS'
        $plan.Resources.storage.allowBlobPublicAccess | Should -BeFalse
        $plan.Resources.keyVault.enableRbacAuthorization | Should -BeTrue
        $plan.Resources.keyVault.publicNetworkAccess | Should -Be 'Enabled'
        $plan.Resources.functionApp.runtime | Should -Be 'powershell'
        $plan.Resources.functionApp.runtimeVersion | Should -Be '7.6'
        $plan.Phases.Id | Should -Be @(
            'preflight', 'azure-foundation', 'runtime-identity', 'runtime-credential',
            'function-deployment', 'logging-solution', 'readiness-validation'
        )
        @($plan.Phases | Where-Object Status -ne 'Pending') | Should -HaveCount 0
        $calls | Should -HaveCount 3
        $plan | ConvertTo-Json -Depth 20 | Should -Not -Match 'UseDevelopmentStorage|AccountKey='
    }

    It 'persists only non-secret phase state and never skips saved phases in an offline plan' {
        $statePath = Join-Path $TestDrive 'deployment.state.json'
        $first = & $bootstrapPath -ConfigurationPath $examplePath -StatePath $statePath -CommandRunner $offlineRunner
        $savedState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        @($savedState.Keys | Sort-Object) | Should -Be @('configurationHash', 'phases', 'schemaVersion')
        $savedState.configurationHash | Should -Match '^[0-9a-f]{64}$'
        $savedState.phases[0].status = 'Completed'
        $savedState | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath

        $resumed = & $bootstrapPath -ConfigurationPath $examplePath -StatePath $statePath -CommandRunner $offlineRunner

        $resumed.Phases[0].Status | Should -Be 'Pending'
        $resumed.Phases[0].SavedStatus | Should -Be 'Completed'
        $resumed.Phases[0].NeedsRevalidation | Should -BeTrue
        $resumed.ResourceNames | ConvertTo-Json | Should -Be ($first.ResourceNames | ConvertTo-Json)
        $after = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $after.phases[0].status | Should -Be 'Completed'
        @($after.phases[0].Keys | Sort-Object) | Should -Be @('id', 'status')
        Get-Content -LiteralPath $statePath -Raw | Should -Not -Match 'secret|token|Dataverse|clientId'
    }

    It 'rejects invalid numeric NCRONTAB values before creating resumable state' -ForEach @(
        @{ Schedule = '60 0 0 * * *' }
        @{ Schedule = '0 0 24 * * *' }
        @{ Schedule = '0 0 0 31-1 * *' }
        @{ Schedule = '0 0 0 * 13 *' }
        @{ Schedule = '0 0 0 * * */0' }
    ) {
        $configuration = Get-Content -LiteralPath $examplePath -Raw | ConvertFrom-Json -AsHashtable
        $configuration.agentSchedule = $Schedule
        $configurationPath = Join-Path $TestDrive 'invalid.parameters.json'
        $statePath = Join-Path $TestDrive "$([guid]::NewGuid()).state.json"
        $configuration | ConvertTo-Json | Set-Content -LiteralPath $configurationPath

        { & $bootstrapPath -ConfigurationPath $configurationPath -StatePath $statePath -CommandRunner $offlineRunner } |
            Should -Throw '*Configuration*agentSchedule*NCRONTAB*'
        $statePath | Should -Not -Exist
    }

    It 'plans HTTPS resources and preserves names when only operational settings change' {
        $configuration = Get-Content -LiteralPath $examplePath -Raw | ConvertFrom-Json -AsHashtable
        $configuration.agentTimerEnabled = $true
        $configuration.rpaSchedule = '0 */15 8-18 * * 1-5'
        $configuration.maxCreatesPerRun = 12
        $configuration.logRetentionDays = 90
        $configuration.instanceMemoryMB = 4096
        $configuration.maximumInstanceCount = 50
        $configuration.agentCreatedIn = 'Copilot Studio Lite'
        $configurationPath = Join-Path $TestDrive 'custom.parameters.json'
        $configuration | ConvertTo-Json | Set-Content -LiteralPath $configurationPath
        $example = & $bootstrapPath -ConfigurationPath $examplePath -CommandRunner $offlineRunner

        $plan = & $bootstrapPath -ConfigurationPath $configurationPath -CommandRunner $offlineRunner

        $plan.ResourceNames | ConvertTo-Json | Should -Be ($example.ResourceNames | ConvertTo-Json)
        $plan.Resources.functionApp.httpsOnly | Should -BeTrue
        $plan.Resources.functionApp.minimumTlsVersion | Should -Be '1.2'
        $plan.Resources.functionApp.instanceMemoryMB | Should -Be 4096
        $plan.Resources.functionApp.maximumInstanceCount | Should -Be 50
        $plan.Resources.storage.supportsHttpsTrafficOnly | Should -BeTrue
        $plan.Resources.storage.minimumTlsVersion | Should -Be 'TLS1_2'
        $plan.Resources.logAnalytics.retentionInDays | Should -Be 90
        $plan.Resources.applicationInsights.workspace | Should -Be $plan.ResourceNames.logAnalytics
        $plan.ApplicationSettings.'AzureWebJobs.AgentSyncTimer.Disabled' | Should -Be 'false'
        $plan.ApplicationSettings.'AzureWebJobs.RpaSyncTimer.Disabled' | Should -Be 'true'
        $plan.ApplicationSettings.INVENTORY_AGENT_CREATED_IN | Should -Be 'Copilot Studio Lite'
        $plan.ApplicationSettings.INVENTORY_RPA_SCHEDULE | Should -Be '0 */15 8-18 * * 1-5'
        $plan.ApplicationSettings.INVENTORY_MAX_CREATES_PER_RUN | Should -Be '12'
        $plan.StateContract.ConfigurationHash | Should -Not -Be $example.StateContract.ConfigurationHash
    }

    It 'rejects unsupported or invalid inputs without echoing their values' -ForEach @(
        @{ Parameter = 'clientSecret'; Value = 'never-echo-this-secret'; ErrorPattern = '*unsupported parameter*' }
        @{ Parameter = 'instanceMemoryMB'; Value = 1024; ErrorPattern = '*instanceMemoryMB*allowedValues*' }
        @{ Parameter = 'maximumInstanceCount'; Value = 1001; ErrorPattern = '*maximumInstanceCount*maxValue*' }
        @{ Parameter = 'logRetentionDays'; Value = 29; ErrorPattern = '*logRetentionDays*minValue*' }
        @{ Parameter = 'agentTimerEnabled'; Value = 'true'; ErrorPattern = '*agentTimerEnabled*type bool*' }
        @{ Parameter = 'rpaMaxParallelEnvironments'; Value = 0; ErrorPattern = '*rpaMaxParallelEnvironments*minValue*' }
        @{ Parameter = 'agentCreatedIn'; Value = @('one', 'two'); ErrorPattern = '*agentCreatedIn*type string*' }
        @{ Parameter = 'workloadName'; Value = 'Bad Name'; ErrorPattern = '*workloadName*lowercase*' }
        @{ Parameter = 'targetDataverseUrl'; Value = 'https://user:never-echo-this-secret@example.crm.dynamics.com'; ErrorPattern = '*HTTPS base URL*' }
        @{ Parameter = 'subscriptionId'; Value = 'not-a-guid'; ErrorPattern = '*subscriptionId*' }
    ) {
        $configuration = Get-Content -LiteralPath $examplePath -Raw | ConvertFrom-Json -AsHashtable
        $configuration[$Parameter] = $Value
        $configurationPath = Join-Path $TestDrive 'rejected.parameters.json'
        $configuration | ConvertTo-Json | Set-Content -LiteralPath $configurationPath

        { & $bootstrapPath -ConfigurationPath $configurationPath -CommandRunner $offlineRunner } |
            Should -Throw $ErrorPattern
        try {
            & $bootstrapPath -ConfigurationPath $configurationPath -CommandRunner $offlineRunner
        }
        catch {
            $_.Exception.Message | Should -Not -Match 'never-echo-this-secret'
        }
    }

    It 'changes globally scoped names for a different subscription while respecting Azure naming bounds' {
        $configuration = Get-Content -LiteralPath $examplePath -Raw | ConvertFrom-Json -AsHashtable
        $configuration.subscriptionId = '11111111-1111-1111-1111-111111111111'
        $configuration.workloadName = 'abcdefghijklmnopqrstuvwx'
        $configurationPath = Join-Path $TestDrive 'other.parameters.json'
        $configuration | ConvertTo-Json | Set-Content -LiteralPath $configurationPath
        $first = & $bootstrapPath -ConfigurationPath $examplePath -CommandRunner $offlineRunner

        $other = & $bootstrapPath -ConfigurationPath $configurationPath -CommandRunner $offlineRunner

        $other.ResourceNames.storage | Should -Not -Be $first.ResourceNames.storage
        $other.ResourceNames.storage | Should -Match '^[a-z0-9]{3,24}$'
        $other.ResourceNames.keyVault | Should -Match '^[a-z][a-z0-9-]{1,22}[a-z0-9]$'
        $other.ResourceNames.keyVault | Should -Not -Match '--'
        $other.ResourceNames.functionApp.Length | Should -BeLessOrEqual 60
    }

    It 'refuses secret-bearing state and leaves the existing file untouched' {
        $statePath = Join-Path $TestDrive 'secret.state.json'
        & $bootstrapPath -ConfigurationPath $examplePath -StatePath $statePath -CommandRunner $offlineRunner | Out-Null
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        $state.phases[0].clientSecret = 'never-echo-this-secret'
        $state | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statePath
        $original = Get-Content -LiteralPath $statePath -Raw

        { & $bootstrapPath -ConfigurationPath $examplePath -StatePath $statePath -CommandRunner $offlineRunner } |
            Should -Throw '*Only non-secret phase metadata is allowed*'
        Get-Content -LiteralPath $statePath -Raw | Should -Be $original
    }

    It 'refuses to resume a changed configuration without rewriting the previous state' {
        $statePath = Join-Path $TestDrive 'original.state.json'
        & $bootstrapPath -ConfigurationPath $examplePath -StatePath $statePath -CommandRunner $offlineRunner | Out-Null
        $original = Get-Content -LiteralPath $statePath -Raw
        $configuration = Get-Content -LiteralPath $examplePath -Raw | ConvertFrom-Json -AsHashtable
        $configuration.maxCreatesPerRun = 6
        $configurationPath = Join-Path $TestDrive 'changed.parameters.json'
        $configuration | ConvertTo-Json | Set-Content -LiteralPath $configurationPath

        { & $bootstrapPath -ConfigurationPath $configurationPath -StatePath $statePath -CommandRunner $offlineRunner } |
            Should -Throw '*configuration mismatch*'
        Get-Content -LiteralPath $statePath -Raw | Should -Be $original
    }

    It 'reports missing Azure CLI before invoking any external command or creating state' {
        Mock Get-Command { $null }
        $statePath = Join-Path $TestDrive 'no-cli.state.json'
        $runner = { throw 'No command may run when Azure CLI is missing.' }

        { & $bootstrapPath -ConfigurationPath $examplePath -StatePath $statePath -CommandRunner $runner } |
            Should -Throw '*Azure CLI is missing*Install Azure CLI*'
        $statePath | Should -Not -Exist
    }

    It 'reports deployment-only prerequisites as unavailable without installing them' {
        Mock Get-Command {
            if ($Name -eq 'az') { [pscustomobject] @{ Name = 'az' } }
        }
        Mock Get-Module { @() } -ParameterFilter { $ListAvailable }

        $plan = & $bootstrapPath -ConfigurationPath $examplePath -CommandRunner $offlineRunner

        $missing = @($plan.Prerequisites | Where-Object { -not $_.Available })
        $missing.Name | Should -Be @('Functions Core Tools v4', 'Power Platform CLI', 'Microsoft Graph PowerShell')
        $missing.RequiredFor | Should -Be @('Deployment', 'Deployment', 'Deployment')
        $plan.DeploymentImplemented | Should -BeFalse
    }

    It 'fails fast if Bicep is missing, without attempting a build or install' {
        $calls = [System.Collections.Generic.List[string]]::new()
        $runner = {
            param($Command, $Arguments)
            $calls.Add($Arguments -join ' ')
            if ($Arguments[0] -eq 'version') {
                return @{ ExitCode = 0; Output = '{"azure-cli":"2.91.0"}' }
            }
            if ($Arguments -join ' ' -eq 'bicep version') {
                return @{ ExitCode = 1; Output = 'Bicep CLI not found.' }
            }
            throw 'No subsequent command should run.'
        }.GetNewClosure()

        { & $bootstrapPath -ConfigurationPath $examplePath -CommandRunner $runner } |
            Should -Throw '*Install Bicep explicitly*never installs tools*'
        $calls | Should -Be @('version --output json', 'bicep version')
    }

    It 'compiles nested modules and fails the plan when any module cannot compile' {
        $deploymentPath = Join-Path $TestDrive 'module-probe'
        $modulePath = Join-Path $deploymentPath 'modules'
        New-Item -ItemType Directory -Path $modulePath -Force | Out-Null
        Copy-Item -LiteralPath $bootstrapPath -Destination $deploymentPath
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\deploy\main.bicep') -Destination $deploymentPath
        Set-Content -LiteralPath (Join-Path $modulePath 'broken.bicep') -Value 'not valid bicep'
        $statePath = Join-Path $deploymentPath 'state.json'
        $calls = [System.Collections.Generic.List[string]]::new()
        $baseRunner = $offlineRunner
        $runner = {
            param($Command, $Arguments)
            if ($Arguments[0] -eq 'bicep' -and $Arguments[1] -eq 'build') {
                $calls.Add($Arguments[3])
                if ($Arguments[3] -like '*broken.bicep') {
                    return @{ ExitCode = 1; Output = 'broken.bicep: BCP007: Unrecognized declaration.' }
                }
                $Arguments | Should -Contain '--no-restore'
            }
            & $baseRunner $Command $Arguments
        }.GetNewClosure()

        { & (Join-Path $deploymentPath 'Invoke-InventoryDeployment.ps1') -ConfigurationPath $examplePath `
                -StatePath $statePath -CommandRunner $runner } |
            Should -Throw '*Fix the indicated Bicep compilation error*BCP007*'
        $calls | Should -HaveCount 2
        $statePath | Should -Not -Exist
    }

    It 'rejects consecutive hyphens before planning invalid Azure resource names' {
        $configuration = Get-Content -LiteralPath $examplePath -Raw | ConvertFrom-Json -AsHashtable
        $configuration.workloadName = 'ab--cdef'
        $configurationPath = Join-Path $TestDrive 'double-hyphen.parameters.json'
        $configuration | ConvertTo-Json | Set-Content -LiteralPath $configurationPath

        { & $bootstrapPath -ConfigurationPath $configurationPath -CommandRunner $offlineRunner } |
            Should -Throw '*workloadName*consecutive hyphens*'
    }
}

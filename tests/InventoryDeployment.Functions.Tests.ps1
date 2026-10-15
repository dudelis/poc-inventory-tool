BeforeAll {
    $script:bootstrapPath = Join-Path $PSScriptRoot '..\deploy\Invoke-InventoryDeployment.ps1'
    $script:examplePath = Join-Path $TestDrive 'example.parameters.json'
    @{
        subscriptionId = '00000000-0000-0000-0000-000000000000'
        targetDataverseUrl = 'https://example.crm.dynamics.com'
        agentCreatedIn = '<agent-created-in>'
    } | ConvertTo-Json | Set-Content -LiteralPath $examplePath
    $script:compiledTemplates = @{}
    Get-ChildItem (Join-Path $PSScriptRoot '..\deploy') -Filter '*.bicep' | ForEach-Object {
        $json = & az bicep build --file $_.FullName --stdout --no-restore
        if ($LASTEXITCODE -ne 0) { throw "Bicep compilation failed: $($_.Name)" }
        $script:compiledTemplates[$_.Name] = $json -join "`n"
    }
    $script:offlineRunner = {
        param($Command, $Arguments)
        $output = switch ($Arguments[0]) {
            'version' { '{}' }
            'bicep' {
                if ($Arguments[1] -eq 'version') { 'Bicep CLI' }
                else { $compiledTemplates[[IO.Path]::GetFileName($Arguments[3])] }
            }
            default { throw "Unexpected offline command: $Command $($Arguments -join ' ')" }
        }
        @{ ExitCode = 0; Output = $output }
    }
}

Describe 'Function infrastructure contract' {
    It 'compiles a Linux Flex app with system identity, identity deployment storage, and scoped data roles' {
        $plan = & $bootstrapPath -ConfigurationPath $examplePath -CommandRunner $offlineRunner
        $functionTemplate = @($plan.Compilation | Where-Object {
            [IO.Path]::GetFileName($_.Template) -eq 'functions.bicep'
        })
        $functionTemplate | Should -HaveCount 1
        $template = $functionTemplate[0].CompiledTemplate
        $app = $template.resources | Where-Object type -eq 'Microsoft.Web/sites'
        $app.kind | Should -Be 'functionapp,linux'
        $app.identity.type | Should -Be 'SystemAssigned'
        $app.properties.functionAppConfig.runtime.name | Should -Be 'powershell'
        $app.properties.functionAppConfig.runtime.version | Should -Be '7.6'
        $app.properties.functionAppConfig.deployment.storage.authentication.type | Should -Be 'SystemAssignedIdentity'
        $app.properties.httpsOnly | Should -BeTrue
        $app.properties.siteConfig.minTlsVersion | Should -Be '1.2'
        $template.parameters.instanceMemoryMB.defaultValue | Should -Be 2048
        $template.parameters.maximumInstanceCount.defaultValue | Should -Be 20
        $hostingPlan = $template.resources | Where-Object type -eq 'Microsoft.Web/serverfarms'
        $hostingPlan.sku.name | Should -Be 'FC1'
        $hostingPlan.sku.tier | Should -Be 'FlexConsumption'
        $hostingPlan.properties.reserved | Should -BeTrue
        $roles = @($template.resources | Where-Object type -eq 'Microsoft.Authorization/roleAssignments')
        $roles | Should -HaveCount 4
        $roles.properties.principalType | Select-Object -Unique | Should -Be 'ServicePrincipal'
        $roles.properties.roleDefinitionId -join ',' | Should -Match 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
        $roles.properties.roleDefinitionId -join ',' | Should -Match '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
        $roles.properties.roleDefinitionId -join ',' | Should -Match '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
        $roles.properties.roleDefinitionId -join ',' | Should -Match '4633458b-17de-408a-b874-0445c86b69e6'
        $template | ConvertTo-Json -Depth 40 | Should -Not -Match 'listKeys|AccountKey|WEBSITE_RUN_FROM_PACKAGE'
    }

    It 'plans Flex-owned runtime properties rather than deprecated worker or runtime app settings' {
        $plan = & $bootstrapPath -ConfigurationPath $examplePath -CommandRunner $offlineRunner

        $plan.ApplicationSettings.Contains('FUNCTIONS_WORKER_RUNTIME') | Should -BeFalse
        $plan.ApplicationSettings.Contains('FUNCTIONS_WORKER_RUNTIME_VERSION') | Should -BeFalse
        $plan.ApplicationSettings.Contains('FUNCTIONS_EXTENSION_VERSION') | Should -BeFalse
        $plan.ApplicationSettings.ExternalDurablePowerShellSDK | Should -Be 'true'
        $plan.Resources.functionApp.functionsRuntimeVersion | Should -Be '4'
        $plan.Resources.functionApp.storageRoles | Should -Be @(
            'Storage Blob Data Owner', 'Storage Queue Data Contributor', 'Storage Table Data Contributor'
        )
        $plan.Resources.functionApp.keyVaultRole | Should -Be 'Key Vault Secrets User'
    }
}

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..\src\Modules\InventorySync\InventorySync.psd1'
    Import-Module $modulePath -Force
}

Describe 'Agent Builder create plan' {
    It 'maps a new agent to the component defaults and environment alternate key' {
        $agent = [pscustomobject] @{
            agentId       = 'agent-1'
            title         = 'Agent one'
            environmentId = 'environment-1'
            ownerId       = 'owner-1'
            createdAt     = '2026-09-01T08:00:00Z'
            modifiedAt    = '2026-09-02T09:00:00Z'
        }
        $now = [datetimeoffset] '2026-10-02T10:00:00Z'

        $plan = New-AgentComponentCreatePlan -Agents @($agent) `
            -Environments @([pscustomobject] @{ palp_id = 'environment-1' }) `
            -ExistingComponentIds @() -Now $now

        $plan.Counts.Created | Should -Be 1
        $plan.Counts.Skipped | Should -Be 0
        $plan.Writes | Should -HaveCount 1
        $plan.Writes[0].Method | Should -Be 'POST'
        $plan.Writes[0].RelativeUri | Should -Be 'palp_komponentes'
        $plan.Writes[0].Payload.palp_id | Should -Be '8c1faa29-db0a-5c1e-9616-f2ede5028847'
        $plan.Writes[0].Payload.palp_typ | Should -Be 5
        $plan.Writes[0].Payload.palp_titel | Should -Be 'Agent one'
        $plan.Writes[0].Payload.palp_besitzerobjectid | Should -Be 'owner-1'
        $plan.Writes[0].Payload.'palp_environment@odata.bind' |
            Should -Be "/palp_environments(palp_id='environment-1')"
        $plan.Writes[0].Payload.palp_urspruenglicherstelltam | Should -Be '2026-09-01T08:00:00Z'
        $plan.Writes[0].Payload.palp_urspruenglichgeaendertam | Should -Be '2026-09-02T09:00:00Z'
        $plan.Writes[0].Payload.palp_komponentenstatus | Should -Be 0
        $plan.Writes[0].Payload.palp_status | Should -Be 0
        $plan.Writes[0].Payload.palp_nutzungsbereich | Should -Be 0
        $plan.Writes[0].Payload.palp_letztestatusaenderung |
            Should -Be '2026-10-02T10:00:00.0000000+00:00'
        $plan.Writes[0].Payload.PSObject.Properties.Name | Should -HaveCount 11
        $plan.Logs | Should -HaveCount 0
    }

    It 'skips and logs an agent whose environment is missing' {
        $agent = [pscustomobject] @{
            agentId       = 'orphan-agent'
            title         = 'Orphan agent'
            environmentId = 'missing-environment'
            ownerId       = 'owner-1'
            createdAt     = '2026-09-01T08:00:00Z'
            modifiedAt    = '2026-09-02T09:00:00Z'
        }

        $plan = New-AgentComponentCreatePlan -Agents @($agent) -Environments @() `
            -ExistingComponentIds @()

        $plan.Writes | Should -HaveCount 0
        $plan.Counts.Created | Should -Be 0
        $plan.Counts.Skipped | Should -Be 1
        $plan.Logs | Should -HaveCount 1
        $plan.Logs[0].Severity | Should -Be 'Warning'
        $plan.Logs[0].Category | Should -Be 'Skipped'
        $plan.Logs[0].EnvironmentId | Should -Be 'missing-environment'
        $plan.Logs[0].ComponentId | Should -Be 'orphan-agent'
        $plan.Logs[0].Message | Should -Match 'not present in palp_environment'
    }
}

targetScope = 'subscription'

@description('Shared deployment input contract. The bootstrap deploys foundation templates separately.')
@minLength(36)
@maxLength(36)
param subscriptionId string

@minLength(1)
param targetDataverseUrl string

@minLength(1)
param agentCreatedIn string

@minLength(3)
@maxLength(24)
param workloadName string = 'palp-inventory-sync'

@minLength(1)
param location string = 'northeurope'

@allowed([512, 2048, 4096])
param instanceMemoryMB int = 2048

@minValue(1)
@maxValue(1000)
param maximumInstanceCount int = 20

@minValue(30)
@maxValue(730)
param logRetentionDays int = 30

param agentTimerEnabled bool = false
param rpaTimerEnabled bool = false

@minLength(1)
param agentSchedule string = '0 0 0 * * *'

@minLength(1)
param rpaSchedule string = '0 0 1 * * *'

@minValue(0)
param maxCreatesPerRun int = 5

@minValue(1)
param rpaMaxParallelEnvironments int = 5

@minLength(1)
param rpaEnvironmentUrlColumn string = 'palp_dataverseurl'

param rpaExcludedSkus string = 'Standard,Teams'

@minLength(1)
param syncRunTable string = 'invs_syncruns'

@minLength(1)
param syncLogTable string = 'invs_synclogs'

output configuration object = {
  subscriptionId: subscriptionId
  targetDataverseUrl: targetDataverseUrl
  agentCreatedIn: agentCreatedIn
  workloadName: workloadName
  location: location
  instanceMemoryMB: instanceMemoryMB
  maximumInstanceCount: maximumInstanceCount
  logRetentionDays: logRetentionDays
  agentTimerEnabled: agentTimerEnabled
  rpaTimerEnabled: rpaTimerEnabled
  agentSchedule: agentSchedule
  rpaSchedule: rpaSchedule
  maxCreatesPerRun: maxCreatesPerRun
  rpaMaxParallelEnvironments: rpaMaxParallelEnvironments
  rpaEnvironmentUrlColumn: rpaEnvironmentUrlColumn
  rpaExcludedSkus: rpaExcludedSkus
  syncRunTable: syncRunTable
  syncLogTable: syncLogTable
}

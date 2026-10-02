function Get-InventorySyncConfiguration {
    [CmdletBinding()]
    param(
        [Parameter()]
        [System.Collections.IDictionary] $Settings = [System.Environment]::GetEnvironmentVariables(),
        [Parameter()]
        [ValidateSet('All', 'AgentBuilder', 'RPA')]
        [string] $SyncType = 'All'
    )

    $requiredSettings = [ordered]@{
        INVENTORY_TENANT_ID                   = 'TenantId'
        INVENTORY_CLIENT_ID                   = 'ClientId'
        INVENTORY_CLIENT_SECRET               = 'ClientSecret'
        INVENTORY_TARGET_DATAVERSE_URL        = 'TargetDataverseUrl'
        APPLICATIONINSIGHTS_CONNECTION_STRING = 'ApplicationInsightsConnectionString'
    }
    if ($SyncType -in @('All', 'AgentBuilder')) {
        $requiredSettings.INVENTORY_AGENT_CREATED_IN = 'AgentCreatedIn'
    }

    $missing = @(
        foreach ($settingName in $requiredSettings.Keys) {
            if (-not $Settings.Contains($settingName) -or [string]::IsNullOrWhiteSpace([string] $Settings[$settingName])) {
                $settingName
            }
        }
    )

    if ($missing.Count -gt 0) {
        throw "Missing required app settings: $($missing -join ', ')."
    }

    $configuration = [ordered]@{}
    foreach ($entry in $requiredSettings.GetEnumerator()) {
        $configuration[$entry.Value] = ([string] $Settings[$entry.Key]).Trim()
    }
    $configuration.TargetDataverseUrl = $configuration.TargetDataverseUrl.TrimEnd('/')
    $configuration.RpaEnvironmentUrlColumn = if (
        $Settings.Contains('INVENTORY_RPA_ENVIRONMENT_URL_COLUMN') -and
        -not [string]::IsNullOrWhiteSpace([string] $Settings['INVENTORY_RPA_ENVIRONMENT_URL_COLUMN'])
    ) {
        ([string] $Settings['INVENTORY_RPA_ENVIRONMENT_URL_COLUMN']).Trim()
    }
    else {
        'palp_dataverseurl'
    }
    if ($configuration.RpaEnvironmentUrlColumn -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
        throw 'INVENTORY_RPA_ENVIRONMENT_URL_COLUMN must be a Dataverse column name.'
    }
    $configuration.RpaExcludedSkus = if (
        $Settings.Contains('INVENTORY_RPA_EXCLUDED_SKUS') -and
        -not [string]::IsNullOrWhiteSpace([string] $Settings['INVENTORY_RPA_EXCLUDED_SKUS'])
    ) {
        @(
            ([string] $Settings['INVENTORY_RPA_EXCLUDED_SKUS']).Split(',') |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }
    else {
        @('Standard', 'Teams')
    }
    $configuration.RpaMaxParallelEnvironments = 10
    if (
        $Settings.Contains('INVENTORY_RPA_MAX_PARALLEL_ENVIRONMENTS') -and
        -not [string]::IsNullOrWhiteSpace([string] $Settings['INVENTORY_RPA_MAX_PARALLEL_ENVIRONMENTS'])
    ) {
        $configuredParallelism = 0
        if (
            -not [int]::TryParse(
                [string] $Settings['INVENTORY_RPA_MAX_PARALLEL_ENVIRONMENTS'],
                [ref] $configuredParallelism
            ) -or
            $configuredParallelism -lt 1
        ) {
            throw 'INVENTORY_RPA_MAX_PARALLEL_ENVIRONMENTS must be a positive integer.'
        }
        $configuration.RpaMaxParallelEnvironments = $configuredParallelism
    }
    $configuration.SyncRunTable = if (
        $Settings.Contains('INVENTORY_SYNC_RUN_TABLE') -and
        -not [string]::IsNullOrWhiteSpace([string] $Settings['INVENTORY_SYNC_RUN_TABLE'])
    ) {
        ([string] $Settings['INVENTORY_SYNC_RUN_TABLE']).Trim()
    }
    else {
        'invs_syncruns'
    }
    $configuration.SyncLogTable = if (
        $Settings.Contains('INVENTORY_SYNC_LOG_TABLE') -and
        -not [string]::IsNullOrWhiteSpace([string] $Settings['INVENTORY_SYNC_LOG_TABLE'])
    ) {
        ([string] $Settings['INVENTORY_SYNC_LOG_TABLE']).Trim()
    }
    else {
        'invs_synclogs'
    }
    $configuration.MaxCreatesPerRun = 1000
    if (
        $Settings.Contains('INVENTORY_MAX_CREATES_PER_RUN') -and
        -not [string]::IsNullOrWhiteSpace([string] $Settings['INVENTORY_MAX_CREATES_PER_RUN'])
    ) {
        $configuredCap = 0
        if (
            -not [int]::TryParse([string] $Settings['INVENTORY_MAX_CREATES_PER_RUN'], [ref] $configuredCap) -or
            $configuredCap -lt 0
        ) {
            throw 'INVENTORY_MAX_CREATES_PER_RUN must be a non-negative integer.'
        }
        $configuration.MaxCreatesPerRun = $configuredCap
    }

    [pscustomobject] $configuration
}

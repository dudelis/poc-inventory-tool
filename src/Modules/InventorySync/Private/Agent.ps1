function Get-AgentBuilderAgents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $CreatedIn,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $AccessToken
    )

    $createdInLiteral = $CreatedIn.Replace('\', '\\').Replace('"', '\"')
    $query = @"
PowerPlatformResources
| where type =~ "microsoft.copilotstudio/agents"
| extend properties = parse_json(properties)
| where tostring(properties.createdIn) == "$createdInLiteral"
| project agentId = tostring(name),
          title = tostring(properties.displayName),
          description = tostring(properties.description),
          environmentId = tostring(properties.environmentId),
          ownerId = tostring(properties.ownerId),
          createdAt = todatetime(properties.createdAt),
          modifiedAt = todatetime(properties.lastModifiedAt)
"@

    Invoke-ResourceGraphPagedQuery -Query $query -AccessToken $AccessToken
}

function Invoke-AgentCreateSync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Configuration,
        [Parameter()] [string] $ResourceGraphAccessToken,
        [Parameter()] [string] $DataverseAccessToken,
        [Parameter()] [datetimeoffset] $Now = [datetimeoffset]::UtcNow,
        [Parameter()] [string] $CorrelationId = ([guid]::NewGuid().ToString())
    )

    if ([string]::IsNullOrWhiteSpace($ResourceGraphAccessToken)) {
        $ResourceGraphAccessToken = Get-InventoryAccessToken `
            -Resource 'https://management.azure.com' -Configuration $Configuration
    }
    if ([string]::IsNullOrWhiteSpace($DataverseAccessToken)) {
        $DataverseAccessToken = Get-InventoryAccessToken `
            -Resource $Configuration.TargetDataverseUrl -Configuration $Configuration
    }

    $syncRunTableProperty = $Configuration.PSObject.Properties['SyncRunTable']
    $syncLogTableProperty = $Configuration.PSObject.Properties['SyncLogTable']
    $loggingConfigured = $null -ne $syncRunTableProperty -and
        $null -ne $syncLogTableProperty -and
        -not [string]::IsNullOrWhiteSpace([string] $syncRunTableProperty.Value) -and
        -not [string]::IsNullOrWhiteSpace([string] $syncLogTableProperty.Value)
    $runHeader = if ($loggingConfigured) {
        Start-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
            -AccessToken $DataverseAccessToken -TableName ([string] $syncRunTableProperty.Value) `
            -RunId $CorrelationId -SyncType AgentBuilder -StartedOn $Now
    }
    else {
        [pscustomobject] @{ Persisted = $false; RecordId = ''; Error = $null }
    }

    $phase = 'Collect'
    $counts = [pscustomobject] @{
        EnvironmentsTotal  = 0
        EnvironmentsFailed = 0
        Found              = 0
        Created            = 0
        Updated            = 0
        Unchanged          = 0
        MarkedDeleted      = 0
        Restored           = 0
        Errors             = 0
        Skipped            = 0
    }
    try {
        $agents = @(Get-AgentBuilderAgents -CreatedIn $Configuration.AgentCreatedIn `
        -AccessToken $ResourceGraphAccessToken)
    $baseUrl = $Configuration.TargetDataverseUrl.TrimEnd('/')
    $environments = @(Get-DataversePagedRecords `
        -Uri "$baseUrl/api/data/v9.2/palp_environments?`$select=palp_id" `
        -AccessToken $DataverseAccessToken)
    $existingComponents = @(Get-DataversePagedRecords `
        -Uri "$baseUrl/api/data/v9.2/palp_komponentes?`$select=palp_id&`$filter=palp_typ%20eq%205" `
        -AccessToken $DataverseAccessToken)
    $existingIds = @($existingComponents | ForEach-Object { [string] $_.palp_id })
    $plan = New-AgentComponentCreatePlan -Agents $agents -Environments $environments `
        -ExistingComponentIds $existingIds -Now $Now

    $runRecordId = if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }
    foreach ($logEntry in $plan.Logs) {
        Write-InventorySyncLogEntry -Entry $logEntry -Configuration $Configuration `
            -AccessToken $DataverseAccessToken -RunRecordId $runRecordId `
            -CorrelationId $CorrelationId -Caller $PSCmdlet | Out-Null
    }

    $phase = 'Write'
    $batch = Write-DataverseBatch -Writes $plan.Writes -DataverseUrl $baseUrl `
        -AccessToken $DataverseAccessToken

    foreach ($failure in $batch.Failures) {
        $logEntry = New-InventorySyncLogEntry -Severity Error -Category WriteFailed `
            -EnvironmentId ([string] $failure.EnvironmentId) `
            -ComponentType ([int] $failure.ComponentType) `
            -ComponentId ([string] $failure.ComponentId) `
            -Operation ([string] $failure.Operation) -HttpStatus ([int] $failure.HttpStatus) `
            -ErrorCode ([string] $failure.ErrorCode) -Message ([string] $failure.Message)
        Write-InventorySyncLogEntry -Entry $logEntry -Configuration $Configuration `
            -AccessToken $DataverseAccessToken -RunRecordId $runRecordId `
            -CorrelationId $CorrelationId -Caller $PSCmdlet | Out-Null
    }

    $environmentIds = @(
        $agents |
            ForEach-Object { ([string] $_.environmentId).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    $failedEnvironmentIds = @(
        @($plan.Logs) + @($batch.Failures) |
            ForEach-Object { ([string] $_.EnvironmentId).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    $counts = [pscustomobject] @{
        EnvironmentsTotal  = $environmentIds.Count
        EnvironmentsFailed = $failedEnvironmentIds.Count
        Found              = $agents.Count
        Created            = $batch.Succeeded
        Updated            = 0
        Unchanged          = $plan.Counts.Unchanged
        MarkedDeleted      = 0
        Restored           = 0
        Errors             = $plan.Counts.Skipped + $batch.Failed
        Skipped            = $plan.Counts.Skipped
    }
    $status = if ($counts.Errors -gt 0) { 'Partial' } else { 'Succeeded' }
    if ($loggingConfigured -and $runHeader.Persisted) {
        Complete-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
            -AccessToken $DataverseAccessToken -TableName ([string] $syncRunTableProperty.Value) `
            -RecordId $runHeader.RecordId -RunId $CorrelationId -Phase Write `
            -Status $status -Counts $counts | Out-Null
    }
    Write-InventoryTrace -Level Information -Message "Agent sync completed with status $status." `
        -CorrelationId $CorrelationId -Data @{
            syncType = 'AgentBuilder'
            status   = $status
            counts   = $counts
        }
    [pscustomobject] @{
        CorrelationId = $CorrelationId
        Status        = $status
        Counts        = $counts
        Logs          = $plan.Logs
        Batch         = $batch
    }
    }
    catch {
        $failure = $_
        $counts.Errors++
        $category = if ($phase -eq 'Collect') { 'ReadFailed' } else { 'WriteFailed' }
        $errorDetails = Get-InventoryErrorDetails -Message $failure.Exception.Message
        $logEntry = New-InventorySyncLogEntry -Severity Error -Category $category `
            -Operation $phase -HttpStatus $errorDetails.HttpStatus `
            -ErrorCode $errorDetails.ErrorCode -Message $failure.Exception.Message
        Write-InventorySyncLogEntry -Entry $logEntry -Configuration $Configuration `
            -AccessToken $DataverseAccessToken `
            -RunRecordId $(if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }) `
            -CorrelationId $CorrelationId -Caller $PSCmdlet -ErrorAction Continue | Out-Null
        if ($loggingConfigured -and $runHeader.Persisted) {
            Complete-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
                -AccessToken $DataverseAccessToken -TableName ([string] $syncRunTableProperty.Value) `
                -RecordId $runHeader.RecordId -RunId $CorrelationId -Phase $phase `
                -Status Failed -Counts $counts | Out-Null
        }
        throw $failure
    }
}

function Invoke-AgentSyncCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Configuration,
        [Parameter()] [string] $ResourceGraphAccessToken,
        [Parameter()] [string] $DataverseAccessToken,
        [Parameter()] [datetimeoffset] $Now = [datetimeoffset]::UtcNow,
        [Parameter()] [string] $CorrelationId = ([guid]::NewGuid().ToString()),
        [Parameter()] [switch] $SuppressPlanTracing
    )

    if ([string]::IsNullOrWhiteSpace($ResourceGraphAccessToken)) {
        $ResourceGraphAccessToken = Get-InventoryAccessToken `
            -Resource 'https://management.azure.com' -Configuration $Configuration
    }
    if ([string]::IsNullOrWhiteSpace($DataverseAccessToken)) {
        $DataverseAccessToken = Get-InventoryAccessToken `
            -Resource $Configuration.TargetDataverseUrl -Configuration $Configuration
    }

    $agents = @(Get-AgentBuilderAgents -CreatedIn $Configuration.AgentCreatedIn `
        -AccessToken $ResourceGraphAccessToken)
    $sourceComponents = @(
        foreach ($agent in $agents) {
            $descriptionProperty = $agent.PSObject.Properties['description']
            [pscustomobject] @{
                SourceId         = [string] $agent.agentId
                EnvironmentId    = [string] $agent.environmentId
                Title            = [string] $agent.title
                OwnerObjectId    = [string] $agent.ownerId
                Description      = if ($null -ne $descriptionProperty) {
                    $descriptionProperty.Value
                }
                else {
                    $null
                }
                SourceCreatedAt  = [string] $agent.createdAt
                SourceModifiedAt = [string] $agent.modifiedAt
            }
        }
    )

    $baseUrl = $Configuration.TargetDataverseUrl.TrimEnd('/')
    $environments = @(Get-DataversePagedRecords `
        -Uri "$baseUrl/api/data/v9.2/palp_environments?`$select=palp_id" `
        -AccessToken $DataverseAccessToken)
    $componentQuery = 'palp_komponentes?' +
        '$select=palp_id,palp_typ,palp_titel,palp_besitzerobjectid,palp_beschreibung,' +
        'palp_urspruenglicherstelltam,palp_urspruenglichgeaendertam,' +
        'palp_komponentenstatus,palp_status' +
        '&$expand=palp_environment($select=palp_id)&$filter=palp_typ%20eq%205'
    $existingComponents = @(Get-DataversePagedRecords `
        -Uri "$baseUrl/api/data/v9.2/$componentQuery" -AccessToken $DataverseAccessToken)
    $capProperty = $Configuration.PSObject.Properties['MaxCreatesPerRun']
    $creationCap = if ($null -ne $capProperty) { [int] $capProperty.Value } else { 1000 }
    $plan = New-InventoryComponentReconciliationPlan `
        -SourceComponents $sourceComponents -Environments $environments `
        -ExistingComponents $existingComponents -ComponentType 5 `
        -CreationCap $creationCap -Now $Now

    if (-not $SuppressPlanTracing) {
        foreach ($logEntry in $plan.Logs) {
            Write-InventoryTrace -Level $logEntry.Severity -Message $logEntry.Message `
                -CorrelationId $CorrelationId -Data @{
                    category      = $logEntry.Category
                    environmentId = $logEntry.EnvironmentId
                    componentType = $logEntry.ComponentType
                    componentId   = $logEntry.ComponentId
                    operation     = $logEntry.Operation
                }
        }
    }

    $writeBatch = Write-DataverseBatch -Writes $plan.Writes -DataverseUrl $baseUrl `
        -AccessToken $DataverseAccessToken
    $failedCreates = @($writeBatch.Failures | Where-Object { $_.Operation -eq 'Create' }).Count
    $failedUpdates = @($writeBatch.Failures | Where-Object { $_.Operation -eq 'Update' }).Count
    $failedRestores = @($writeBatch.Failures | Where-Object { $_.Operation -eq 'Restore' }).Count
    $environmentIds = @(
        $sourceComponents |
            ForEach-Object { [string] $_.EnvironmentId } |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string] $_) } |
            Sort-Object -Unique
    )
    $failedEnvironmentIds = @(
        @($plan.Logs | Where-Object { $_.Category -ne 'Restored' }) + @($writeBatch.Failures) |
            ForEach-Object { ([string] $_.EnvironmentId).Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            Sort-Object -Unique
    )
    $logs = [System.Collections.Generic.List[object]]::new()
    $failedRestoreIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($failure in $writeBatch.Failures) {
        if ($failure.Operation -eq 'Restore') {
            $null = $failedRestoreIds.Add([string] $failure.ComponentId)
        }
    }
    foreach ($entry in $plan.Logs) {
        if ($entry.Category -ne 'Restored' -or -not $failedRestoreIds.Contains([string] $entry.ComponentId)) {
            $logs.Add($entry)
        }
    }
    $counts = [pscustomobject] @{
        EnvironmentsTotal  = $environmentIds.Count
        EnvironmentsFailed = $failedEnvironmentIds.Count
        Found              = $agents.Count
        Created            = [Math]::Max(0, $plan.Counts.Created - $failedCreates)
        Updated            = [Math]::Max(0, $plan.Counts.Updated - $failedUpdates)
        MarkedDeleted      = 0
        Restored           = [Math]::Max(0, $plan.Counts.Restored - $failedRestores)
        Skipped            = $plan.Counts.Skipped
        Unchanged          = $plan.Counts.Unchanged
        Errors             = $plan.Counts.Skipped + $writeBatch.Failed
    }
    $deletionBatch = [pscustomobject] @{
        Batches = 0; Operations = 0; Succeeded = 0; Failed = 0; Failures = @()
    }
    $phase = 'Write'
    if ($counts.Errors -eq 0) {
        $phase = 'DeletionCheck'
        $collectedIds = @(
            foreach ($source in $sourceComponents) {
                New-InventoryComponentId -EnvironmentId ([string] $source.EnvironmentId) `
                    -ComponentType 5 -SourceId ([string] $source.SourceId)
            }
        )
        try {
            $verificationAction = {
                param($candidates)
                Get-MissingAgentCandidateIds -Candidates $candidates `
                    -CreatedIn $Configuration.AgentCreatedIn `
                    -AccessToken $ResourceGraphAccessToken
            }
            $deletionResult = Invoke-InventoryDeletionCheck `
                -ExistingComponents $existingComponents -CollectedComponentIds $collectedIds `
                -ComponentType 5 -Now $Now -VerificationAction $verificationAction `
                -DataverseUrl $baseUrl -DataverseAccessToken $DataverseAccessToken
            $deletionBatch = $deletionResult.Batch
            $counts.MarkedDeleted = $deletionBatch.Succeeded
            $counts.Errors += $deletionBatch.Failed
        }
        catch {
            $counts.Errors++
            $errorDetails = Get-InventoryErrorDetails -Message $_.Exception.Message
            $logs.Add([pscustomobject] [ordered] @{
                Severity      = 'Error'
                Category      = 'VerifyFailed'
                EnvironmentId = ''
                ComponentType = 5
                ComponentId   = ''
                Operation     = 'Delete'
                HttpStatus    = $errorDetails.HttpStatus
                ErrorCode     = $errorDetails.ErrorCode
                Message       = $_.Exception.Message
            })
        }
    }
    else {
        $logs.Add([pscustomobject] [ordered] @{
            Severity      = 'Warning'
            Category      = 'Skipped'
            EnvironmentId = ''
            ComponentType = 5
            ComponentId   = ''
            Operation     = 'Delete'
            Message       = 'Deletion check was skipped because collection or write did not complete successfully.'
        })
    }

    $allFailures = @($writeBatch.Failures) + @($deletionBatch.Failures)
    [pscustomobject] @{
        Counts = $counts
        Logs   = $logs.ToArray()
        Batch  = [pscustomobject] @{
            Batches    = $writeBatch.Batches + $deletionBatch.Batches
            Operations = $writeBatch.Operations + $deletionBatch.Operations
            Succeeded  = $writeBatch.Succeeded + $deletionBatch.Succeeded
            Failed     = $writeBatch.Failed + $deletionBatch.Failed
            Failures   = $allFailures
        }
        Phase = $phase
    }
}

function Invoke-AgentSync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Configuration,
        [Parameter()] [string] $ResourceGraphAccessToken,
        [Parameter()] [string] $DataverseAccessToken,
        [Parameter()] [datetimeoffset] $Now = [datetimeoffset]::UtcNow,
        [Parameter()] [string] $CorrelationId = ([guid]::NewGuid().ToString())
    )

    if ([string]::IsNullOrWhiteSpace($ResourceGraphAccessToken)) {
        $ResourceGraphAccessToken = Get-InventoryAccessToken `
            -Resource 'https://management.azure.com' -Configuration $Configuration
    }
    if ([string]::IsNullOrWhiteSpace($DataverseAccessToken)) {
        $DataverseAccessToken = Get-InventoryAccessToken `
            -Resource $Configuration.TargetDataverseUrl -Configuration $Configuration
    }

    $syncRunTableProperty = $Configuration.PSObject.Properties['SyncRunTable']
    $syncLogTableProperty = $Configuration.PSObject.Properties['SyncLogTable']
    $loggingConfigured = $null -ne $syncRunTableProperty -and
        $null -ne $syncLogTableProperty -and
        -not [string]::IsNullOrWhiteSpace([string] $syncRunTableProperty.Value) -and
        -not [string]::IsNullOrWhiteSpace([string] $syncLogTableProperty.Value)
    $runHeader = if ($loggingConfigured) {
        Start-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
            -AccessToken $DataverseAccessToken -TableName ([string] $syncRunTableProperty.Value) `
            -RunId $CorrelationId -SyncType AgentBuilder -StartedOn $Now
    }
    else {
        [pscustomobject] @{ Persisted = $false; RecordId = ''; Error = $null }
    }

    $counts = [pscustomobject] @{
        EnvironmentsTotal  = 0
        EnvironmentsFailed = 0
        Found              = 0
        Created            = 0
        Updated            = 0
        Unchanged          = 0
        MarkedDeleted      = 0
        Restored           = 0
        Errors             = 0
        Skipped            = 0
    }
    try {
        $result = Invoke-AgentSyncCore -Configuration $Configuration `
            -ResourceGraphAccessToken $ResourceGraphAccessToken `
            -DataverseAccessToken $DataverseAccessToken -Now $Now `
            -CorrelationId $CorrelationId -SuppressPlanTracing

        foreach ($property in @(
                'EnvironmentsTotal', 'EnvironmentsFailed', 'Found', 'Created',
                'Updated', 'Unchanged', 'MarkedDeleted', 'Restored', 'Errors', 'Skipped'
            )) {
            $counts.$property = [int] $result.Counts.$property
        }

        $runRecordId = if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }
        foreach ($logEntry in $result.Logs) {
            Write-InventorySyncLogEntry -Entry $logEntry -Configuration $Configuration `
                -AccessToken $DataverseAccessToken -RunRecordId $runRecordId `
                -CorrelationId $CorrelationId -Caller $PSCmdlet | Out-Null
        }

        foreach ($failure in $result.Batch.Failures) {
            $logEntry = New-InventorySyncLogEntry -Severity Error -Category WriteFailed `
                -EnvironmentId ([string] $failure.EnvironmentId) `
                -ComponentType ([int] $failure.ComponentType) `
                -ComponentId ([string] $failure.ComponentId) `
                -Operation ([string] $failure.Operation) -HttpStatus ([int] $failure.HttpStatus) `
                -ErrorCode ([string] $failure.ErrorCode) -Message ([string] $failure.Message)
            Write-InventorySyncLogEntry -Entry $logEntry -Configuration $Configuration `
                -AccessToken $DataverseAccessToken -RunRecordId $runRecordId `
                -CorrelationId $CorrelationId -Caller $PSCmdlet | Out-Null
        }

        $status = if ($counts.Errors -gt 0) { 'Partial' } else { 'Succeeded' }
        if ($loggingConfigured -and $runHeader.Persisted) {
            Complete-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
                -AccessToken $DataverseAccessToken -TableName ([string] $syncRunTableProperty.Value) `
                -RecordId $runHeader.RecordId -RunId $CorrelationId -Phase $result.Phase `
                -Status $status -Counts $counts | Out-Null
        }
        Write-InventoryTrace -Level Information -Message "Agent sync completed with status $status." `
            -CorrelationId $CorrelationId -Data @{
                syncType = 'AgentBuilder'
                status   = $status
                counts   = $counts
            }
        [pscustomobject] @{
            CorrelationId = $CorrelationId
            Status        = $status
            Counts        = $counts
            Logs          = $result.Logs
            Batch         = $result.Batch
        }
    }
    catch {
        $failure = $_
        $counts.Errors++
        $errorDetails = Get-InventoryErrorDetails -Message $failure.Exception.Message
        $logEntry = New-InventorySyncLogEntry -Severity Error -Category ReadFailed `
            -Operation Collect -HttpStatus $errorDetails.HttpStatus `
            -ErrorCode $errorDetails.ErrorCode -Message $failure.Exception.Message
        Write-InventorySyncLogEntry -Entry $logEntry -Configuration $Configuration `
            -AccessToken $DataverseAccessToken `
            -RunRecordId $(if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }) `
            -CorrelationId $CorrelationId -Caller $PSCmdlet -ErrorAction Continue | Out-Null
        if ($loggingConfigured -and $runHeader.Persisted) {
            Complete-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
                -AccessToken $DataverseAccessToken -TableName ([string] $syncRunTableProperty.Value) `
                -RecordId $runHeader.RecordId -RunId $CorrelationId -Phase Collect `
                -Status Failed -Counts $counts | Out-Null
        }
        throw $failure
    }
}

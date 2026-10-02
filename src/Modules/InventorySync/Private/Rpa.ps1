function Get-RpaEnvironmentPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Environments,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $UrlColumn,
        [Parameter()] [AllowEmptyCollection()] [string[]] $ExcludedSkus = @('Standard', 'Teams')
    )

    $excluded = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($sku in $ExcludedSkus) {
        if (-not [string]::IsNullOrWhiteSpace($sku)) {
            $null = $excluded.Add($sku.Trim())
        }
    }

    $selected = [System.Collections.Generic.List[object]]::new()
    $logs = [System.Collections.Generic.List[object]]::new()
    foreach ($environment in $Environments) {
        $id = [string] $environment.palp_id
        $nameProperty = $environment.PSObject.Properties['palp_name']
        $name = if ($null -ne $nameProperty) { [string] $nameProperty.Value } else { '' }
        $skuProperty = $environment.PSObject.Properties['palp_sku']
        $sku = if ($null -ne $skuProperty) { [string] $skuProperty.Value } else { '' }
        $urlProperty = $environment.PSObject.Properties[$UrlColumn]
        $url = if ($null -ne $urlProperty) { [string] $urlProperty.Value } else { '' }
        $stateProperty = $environment.PSObject.Properties['statecode']
        $deletedProperty = $environment.PSObject.Properties['palp_deleted']
        $removedProperty = $environment.PSObject.Properties['palp_removed']
        $statusProperty = $environment.PSObject.Properties['palp_status']
        $isRemoved = ($null -ne $stateProperty -and [int] $stateProperty.Value -ne 0) -or
            ($null -ne $deletedProperty -and [bool] $deletedProperty.Value) -or
            ($null -ne $removedProperty -and [bool] $removedProperty.Value) -or
            ($null -ne $statusProperty -and [string] $statusProperty.Value -match '^(Deleted|Removed)$')

        $reason = if ($excluded.Contains($sku)) {
            "Environment SKU '$sku' is excluded."
        }
        elseif ($isRemoved) {
            'Environment is deleted or removed.'
        }
        elseif ([string]::IsNullOrWhiteSpace($url)) {
            "Environment has no Dataverse URL in '$UrlColumn'."
        }
        else {
            $null
        }

        if ($null -ne $reason) {
            $logs.Add([pscustomobject] [ordered] @{
                Severity        = 'Warning'
                Category        = 'Skipped'
                EnvironmentId   = $id
                EnvironmentName = $name
                ComponentType   = 4
                ComponentId     = ''
                Operation       = 'Collect'
                HttpStatus      = 0
                ErrorCode       = ''
                Message         = $reason
            })
            continue
        }

        $copy = [ordered] @{}
        foreach ($property in $environment.PSObject.Properties) {
            $copy[$property.Name] = $property.Value
        }
        $copy['DataverseUrl'] = $url.TrimEnd('/')
        $selected.Add([pscustomobject] $copy)
    }

    [pscustomobject] @{
        Environments = $selected.ToArray()
        Logs         = $logs.ToArray()
    }
}

function Get-RpaFailureCategory {
    param([Parameter(Mandatory)] [string] $Message)

    if ($Message -match '(?i)\b(401|403)\b|permission|forbidden|unauthori[sz]ed') {
        return 'PermissionDenied'
    }
    if ($Message -match '(?i)\b429\b|throttl|0x800723(?:21|22|26)') {
        return 'Throttled'
    }
    if ($Message -match '(?i)\b(408|502|503|504)\b|timed?\s*out|timeout|unreachable|admin mode') {
        return 'EnvironmentUnreachable'
    }
    'ReadFailed'
}

function Get-RpaDesktopFlows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Environment,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $AccessToken
    )

    $environmentId = [string] $Environment.palp_id
    $environmentNameProperty = $Environment.PSObject.Properties['palp_name']
    $environmentName = if ($null -ne $environmentNameProperty) {
        [string] $environmentNameProperty.Value
    }
    else {
        ''
    }
    $baseUrl = ([string] $Environment.DataverseUrl).TrimEnd('/')
    $workflowQuery = 'workflows?' +
        '$select=workflowid,name,description,createdon,modifiedon,_ownerid_value' +
        '&$filter=category%20eq%206'
    $workflows = @(Get-DataversePagedRecords `
        -Uri "$baseUrl/api/data/v9.2/$workflowQuery" -AccessToken $AccessToken `
        -AdditionalHeaders @{ Prefer = 'odata.include-annotations="Microsoft.Dynamics.CRM.lookuplogicalname"' })

    $flows = [System.Collections.Generic.List[object]]::new()
    $logs = [System.Collections.Generic.List[object]]::new()
    foreach ($workflow in $workflows) {
        $ownerId = [string] $workflow._ownerid_value
        $ownerTypeProperty = $workflow.PSObject.Properties[
            '_ownerid_value@Microsoft.Dynamics.CRM.lookuplogicalname'
        ]
        $ownerType = if ($null -ne $ownerTypeProperty) {
            [string] $ownerTypeProperty.Value
        }
        else {
            ''
        }
        $ownerEntitySet = switch ($ownerType.ToLowerInvariant()) {
            'systemuser' { 'systemusers' }
            'team' { 'teams' }
            default { '' }
        }
        $entraObjectId = ''
        if (-not [string]::IsNullOrWhiteSpace($ownerId) -and
            -not [string]::IsNullOrWhiteSpace($ownerEntitySet)) {
            try {
                $ownerResponse = Invoke-InventoryHttpRequest `
                    -Uri "$baseUrl/api/data/v9.2/$ownerEntitySet($ownerId)?`$select=azureactivedirectoryobjectid" `
                    -Headers @{
                        Authorization = "Bearer $AccessToken"
                        Accept = 'application/json'
                    }
                $entraObjectId = [string] $ownerResponse.Body.azureactivedirectoryobjectid
            }
            catch {
                $entraObjectId = ''
            }
        }

        if ([string]::IsNullOrWhiteSpace($entraObjectId)) {
            $logs.Add([pscustomobject] [ordered] @{
                Severity        = 'Warning'
                Category        = 'Skipped'
                EnvironmentId   = $environmentId
                EnvironmentName = $environmentName
                ComponentType   = 4
                ComponentId     = [string] $workflow.workflowid
                Operation       = 'Collect'
                HttpStatus      = 0
                ErrorCode       = ''
                Message         = "Desktop flow owner '$ownerId' could not be resolved to an Entra object ID."
            })
            continue
        }

        $descriptionProperty = $workflow.PSObject.Properties['description']
        $flows.Add([pscustomobject] @{
            SourceId         = [string] $workflow.workflowid
            EnvironmentId    = $environmentId
            Title            = [string] $workflow.name
            OwnerObjectId    = $entraObjectId
            Description      = if ($null -ne $descriptionProperty) {
                $descriptionProperty.Value
            }
            else {
                $null
            }
            SourceCreatedAt  = [string] $workflow.createdon
            SourceModifiedAt = [string] $workflow.modifiedon
        })
    }

    [pscustomobject] @{
        Flows = $flows.ToArray()
        Logs  = $logs.ToArray()
        Found = $workflows.Count
    }
}

function Invoke-RpaEnvironmentFanOut {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Environments,
        [Parameter(Mandatory)] [psobject] $Configuration,
        [Parameter()] [ValidateRange(1, [int]::MaxValue)] [int] $MaxParallel = 10,
        [Parameter()] [scriptblock] $CollectionAction
    )

    if ($null -eq $CollectionAction) {
        $modulePath = $MyInvocation.MyCommand.Module.Path
        $CollectionAction = {
            param($environment, $configuration, $inventoryModulePath)
            Import-Module $inventoryModulePath -Force
            $token = Get-InventoryAccessToken -Resource $environment.DataverseUrl `
                -Configuration $configuration
            Get-RpaDesktopFlows -Environment $environment -AccessToken $token
        }
    }
    else {
        $modulePath = ''
    }
    $collectionActionText = $CollectionAction.ToString()

    $jobs = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($environment in $Environments) {
            while (
                @($jobs | Where-Object State -in @('NotStarted', 'Running')).Count -ge $MaxParallel
            ) {
                $activeJobs = @($jobs | Where-Object State -in @('NotStarted', 'Running'))
                $null = Wait-Job -Job $activeJobs -Any -Timeout 1
            }
            $job = Start-ThreadJob -ThrottleLimit $MaxParallel -ScriptBlock {
                param($environmentValue, $configurationValue, $actionText, $inventoryModulePath)
                try {
                    $action = [scriptblock]::Create($actionText)
                    $value = & $action $environmentValue $configurationValue $inventoryModulePath
                    [pscustomobject] @{
                        Succeeded   = $true
                        Environment = $environmentValue
                        Value       = $value
                        Error       = ''
                    }
                }
                catch {
                    [pscustomobject] @{
                        Succeeded   = $false
                        Environment = $environmentValue
                        Value       = $null
                        Error       = $_.Exception.Message
                    }
                }
            } -ArgumentList $environment, $Configuration, $collectionActionText, $modulePath
            $job | Add-Member -NotePropertyName RpaEnvironment -NotePropertyValue $environment
            $jobs.Add($job)
        }
        if ($jobs.Count -gt 0) {
            $null = Wait-Job -Job @($jobs)
        }

        $flows = [System.Collections.Generic.List[object]]::new()
        $logs = [System.Collections.Generic.List[object]]::new()
        $failures = [System.Collections.Generic.List[object]]::new()
        $successfulIds = [System.Collections.Generic.List[string]]::new()
        $found = 0
        foreach ($job in $jobs) {
            $jobResults = @(Receive-Job -Job $job)
            if ($jobResults.Count -eq 0) {
                $reason = if ($null -ne $job.ChildJobs[0].JobStateInfo.Reason) {
                    $job.ChildJobs[0].JobStateInfo.Reason.Message
                }
                else {
                    "Environment collection job ended with state '$($job.State)' without a result."
                }
                $jobResults = @([pscustomobject] @{
                    Succeeded   = $false
                    Environment = $job.RpaEnvironment
                    Value       = $null
                    Error       = $reason
                })
            }
            foreach ($jobResult in $jobResults) {
                if ($jobResult.Succeeded) {
                    $successfulIds.Add([string] $jobResult.Environment.palp_id)
                    foreach ($flow in @($jobResult.Value.Flows)) {
                        $flows.Add($flow)
                    }
                    $foundProperty = $jobResult.Value.PSObject.Properties['Found']
                    $found += if ($null -ne $foundProperty) {
                        [int] $foundProperty.Value
                    }
                    else {
                        @($jobResult.Value.Flows).Count
                    }
                    foreach ($log in @($jobResult.Value.Logs)) {
                        $logs.Add($log)
                    }
                    continue
                }

                $details = Get-InventoryErrorDetails -Message ([string] $jobResult.Error)
                $failure = [pscustomobject] [ordered] @{
                    Severity        = 'Error'
                    Category        = Get-RpaFailureCategory -Message ([string] $jobResult.Error)
                    EnvironmentId   = [string] $jobResult.Environment.palp_id
                    EnvironmentName = [string] $jobResult.Environment.palp_name
                    ComponentType   = 4
                    ComponentId     = ''
                    Operation       = 'Collect'
                    HttpStatus      = $details.HttpStatus
                    ErrorCode       = $details.ErrorCode
                    Message         = [string] $jobResult.Error
                }
                $failures.Add($failure)
                $logs.Add($failure)
            }
        }

        [pscustomobject] @{
            Flows                    = $flows.ToArray()
            Logs                     = $logs.ToArray()
            Failures                 = $failures.ToArray()
            SuccessfulEnvironmentIds = $successfulIds.ToArray()
            Found                    = $found
        }
    }
    finally {
        if ($jobs.Count -gt 0) {
            Remove-Job -Job @($jobs) -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-RpaSync {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Configuration,
        [Parameter()] [string] $DataverseAccessToken,
        [Parameter()] [datetimeoffset] $Now = [datetimeoffset]::UtcNow,
        [Parameter()] [string] $CorrelationId = ([guid]::NewGuid().ToString()),
        [Parameter()] [scriptblock] $EnvironmentCollector
    )

    if ([string]::IsNullOrWhiteSpace($DataverseAccessToken)) {
        $DataverseAccessToken = Get-InventoryAccessToken `
            -Resource $Configuration.TargetDataverseUrl -Configuration $Configuration
    }

    $runTableProperty = $Configuration.PSObject.Properties['SyncRunTable']
    $logTableProperty = $Configuration.PSObject.Properties['SyncLogTable']
    $loggingConfigured = $null -ne $runTableProperty -and $null -ne $logTableProperty -and
        -not [string]::IsNullOrWhiteSpace([string] $runTableProperty.Value) -and
        -not [string]::IsNullOrWhiteSpace([string] $logTableProperty.Value)
    $runHeader = if ($loggingConfigured) {
        Start-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
            -AccessToken $DataverseAccessToken -TableName ([string] $runTableProperty.Value) `
            -RunId $CorrelationId -SyncType RPA -StartedOn $Now
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
    $phase = 'Collect'
    try {
        $baseUrl = $Configuration.TargetDataverseUrl.TrimEnd('/')
        $urlColumn = [string] $Configuration.RpaEnvironmentUrlColumn
        $environmentQuery = 'palp_environments?' +
            "`$select=palp_id,palp_name,palp_sku,statecode,$urlColumn"
        $environmentRows = @(Get-DataversePagedRecords `
            -Uri "$baseUrl/api/data/v9.2/$environmentQuery" -AccessToken $DataverseAccessToken)
        $environmentPlan = Get-RpaEnvironmentPlan -Environments $environmentRows `
            -UrlColumn $urlColumn -ExcludedSkus @($Configuration.RpaExcludedSkus)
        $counts.EnvironmentsTotal = $environmentPlan.Environments.Count

        $fanOutParameters = @{
            Environments  = @($environmentPlan.Environments)
            Configuration = $Configuration
            MaxParallel   = [int] $Configuration.RpaMaxParallelEnvironments
        }
        if ($null -ne $EnvironmentCollector) {
            $fanOutParameters.CollectionAction = $EnvironmentCollector
        }
        $collection = Invoke-RpaEnvironmentFanOut @fanOutParameters
        $counts.EnvironmentsFailed = $collection.Failures.Count
        $counts.Found = $collection.Found

        $componentQuery = 'palp_komponentes?' +
            '$select=palp_id,palp_typ,palp_titel,palp_besitzerobjectid,palp_beschreibung,' +
            'palp_urspruenglicherstelltam,palp_urspruenglichgeaendertam,' +
            'palp_komponentenstatus,palp_status' +
            '&$expand=palp_environment($select=palp_id)&$filter=palp_typ%20eq%204'
        $existingComponents = @(Get-DataversePagedRecords `
            -Uri "$baseUrl/api/data/v9.2/$componentQuery" -AccessToken $DataverseAccessToken)
        $capProperty = $Configuration.PSObject.Properties['MaxCreatesPerRun']
        $creationCap = if ($null -ne $capProperty) { [int] $capProperty.Value } else { 1000 }
        $plan = New-InventoryComponentReconciliationPlan `
            -SourceComponents @($collection.Flows) `
            -Environments @($environmentPlan.Environments) `
            -ExistingComponents $existingComponents -ComponentType 4 `
            -CreationCap $creationCap -Now $Now

        $phase = 'Write'
        $batch = Write-DataverseBatch -Writes $plan.Writes -DataverseUrl $baseUrl `
            -AccessToken $DataverseAccessToken
        $failedCreates = @($batch.Failures | Where-Object Operation -eq 'Create').Count
        $failedUpdates = @($batch.Failures | Where-Object Operation -eq 'Update').Count
        $failedRestores = @($batch.Failures | Where-Object Operation -eq 'Restore').Count
        $counts.Created = [Math]::Max(0, $plan.Counts.Created - $failedCreates)
        $counts.Updated = [Math]::Max(0, $plan.Counts.Updated - $failedUpdates)
        $counts.Restored = [Math]::Max(0, $plan.Counts.Restored - $failedRestores)
        $counts.Unchanged = $plan.Counts.Unchanged
        $counts.Skipped = $plan.Counts.Skipped +
            @($collection.Logs | Where-Object Category -eq 'Skipped').Count
        $counts.Errors = $collection.Failures.Count + $plan.Counts.Skipped +
            @($collection.Logs | Where-Object Category -eq 'Skipped').Count + $batch.Failed

        $failedRestoreIds = [System.Collections.Generic.HashSet[string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase
        )
        foreach ($failure in $batch.Failures) {
            if ($failure.Operation -eq 'Restore') {
                $null = $failedRestoreIds.Add([string] $failure.ComponentId)
            }
        }
        $planLogs = @($plan.Logs | Where-Object {
            $_.Category -ne 'Restored' -or
                -not $failedRestoreIds.Contains([string] $_.ComponentId)
        })
        $deletionBatch = [pscustomobject] @{
            Batches = 0; Operations = 0; Succeeded = 0; Failed = 0; Failures = @()
        }
        $deletionLogs = [System.Collections.Generic.List[object]]::new()
        $phase = 'DeletionCheck'
        $collectedIds = @(
            foreach ($flow in $collection.Flows) {
                New-InventoryComponentId -EnvironmentId ([string] $flow.EnvironmentId) `
                    -ComponentType 4 -SourceId ([string] $flow.SourceId)
            }
        )
        try {
            $verificationAction = {
                param($candidates)
                Get-MissingRpaCandidateIds -Candidates $candidates `
                    -Environments @($environmentPlan.Environments) `
                    -Configuration $Configuration
            }
            $deletionResult = Invoke-InventoryDeletionCheck `
                -ExistingComponents $existingComponents -CollectedComponentIds $collectedIds `
                -ComponentType 4 -Now $Now -VerificationAction $verificationAction `
                -DataverseUrl $baseUrl -DataverseAccessToken $DataverseAccessToken `
                -IncludedEnvironmentIds @($collection.SuccessfulEnvironmentIds)
            $deletionBatch = $deletionResult.Batch
            $counts.MarkedDeleted = $deletionBatch.Succeeded
            $counts.Errors += $deletionBatch.Failed
        }
        catch {
            $counts.Errors++
            $details = Get-InventoryErrorDetails -Message $_.Exception.Message
            $deletionLogs.Add((New-InventorySyncLogEntry -Severity Error `
                    -Category VerifyFailed -ComponentType 4 -Operation Delete `
                    -HttpStatus $details.HttpStatus -ErrorCode $details.ErrorCode `
                    -Message $_.Exception.Message))
        }

        $allFailures = @($batch.Failures) + @($deletionBatch.Failures)
        $writeFailureLogs = @(
            foreach ($failure in $allFailures) {
                New-InventorySyncLogEntry -Severity Error -Category WriteFailed `
                    -EnvironmentId ([string] $failure.EnvironmentId) -ComponentType 4 `
                    -ComponentId ([string] $failure.ComponentId) `
                    -Operation ([string] $failure.Operation) `
                    -HttpStatus ([int] $failure.HttpStatus) `
                    -ErrorCode ([string] $failure.ErrorCode) -Message ([string] $failure.Message)
            }
        )
        $logs = @($environmentPlan.Logs) + @($collection.Logs) +
            $planLogs + $writeFailureLogs + $deletionLogs.ToArray()
        $runRecordId = if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }
        foreach ($log in $logs) {
            Write-InventorySyncLogEntry -Entry $log -Configuration $Configuration `
                -AccessToken $DataverseAccessToken -RunRecordId $runRecordId `
                -CorrelationId $CorrelationId -Caller $PSCmdlet | Out-Null
        }

        $status = if ($counts.Errors -gt 0) { 'Partial' } else { 'Succeeded' }
        if ($loggingConfigured -and $runHeader.Persisted) {
            Complete-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
                -AccessToken $DataverseAccessToken -TableName ([string] $runTableProperty.Value) `
                -RecordId $runHeader.RecordId -RunId $CorrelationId -Phase $phase `
                -Status $status -Counts $counts | Out-Null
        }
        Write-InventoryTrace -Level Information -Message "RPA sync completed with status $status." `
            -CorrelationId $CorrelationId -Data @{
                syncType = 'RPA'
                status   = $status
                counts   = $counts
            }
        [pscustomobject] @{
            CorrelationId = $CorrelationId
            Status        = $status
            Counts        = $counts
            Logs          = $logs
            Batch         = [pscustomobject] @{
                Batches    = $batch.Batches + $deletionBatch.Batches
                Operations = $batch.Operations + $deletionBatch.Operations
                Succeeded  = $batch.Succeeded + $deletionBatch.Succeeded
                Failed     = $batch.Failed + $deletionBatch.Failed
                Failures   = $allFailures
            }
        }
    }
    catch {
        $failure = $_
        $counts.Errors++
        $details = Get-InventoryErrorDetails -Message $failure.Exception.Message
        $logEntry = New-InventorySyncLogEntry -Severity Error `
            -Category $(if ($phase -eq 'Collect') { 'ReadFailed' } else { 'WriteFailed' }) `
            -ComponentType 4 -Operation $phase -HttpStatus $details.HttpStatus `
            -ErrorCode $details.ErrorCode -Message $failure.Exception.Message
        Write-InventorySyncLogEntry -Entry $logEntry -Configuration $Configuration `
            -AccessToken $DataverseAccessToken `
            -RunRecordId $(if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }) `
            -CorrelationId $CorrelationId -Caller $PSCmdlet -ErrorAction Continue | Out-Null
        if ($loggingConfigured -and $runHeader.Persisted) {
            Complete-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
                -AccessToken $DataverseAccessToken -TableName ([string] $runTableProperty.Value) `
                -RecordId $runHeader.RecordId -RunId $CorrelationId -Phase $phase `
                -Status Failed -Counts $counts | Out-Null
        }
        throw $failure
    }
}

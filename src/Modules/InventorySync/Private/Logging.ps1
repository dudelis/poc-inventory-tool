function Start-InventorySyncRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $DataverseUrl,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $AccessToken,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $TableName,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
        [Parameter(Mandatory)] [ValidateSet('RPA', 'AgentBuilder')] [string] $SyncType,
        [Parameter()] [datetimeoffset] $StartedOn = [datetimeoffset]::UtcNow
    )

    $recordId = [guid]::NewGuid().ToString()
    try {
        if ($TableName -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
            throw "Invalid Sync Run table name '$TableName'."
        }

        $payload = [ordered] @{
            invs_syncrunid         = $recordId
            invs_name              = "$SyncType $($StartedOn.ToString('u'))"
            invs_runid             = $RunId
            invs_synctype          = if ($SyncType -eq 'RPA') { 100000000 } else { 100000001 }
            invs_phase             = 100000000
            invs_startedon         = $StartedOn.ToString('o')
            invs_status            = 100000000
            invs_environmentstotal = 0
            invs_environmentsfailed = 0
            invs_found             = 0
            invs_created           = 0
            invs_updated           = 0
            invs_unchanged         = 0
            invs_markeddeleted     = 0
            invs_restored          = 0
            invs_errors            = 0
        }
        $headers = @{
            Authorization = "******"
            Accept        = 'application/json'
        }
        $baseUrl = $DataverseUrl.TrimEnd('/')
        Invoke-InventoryHttpRequest -Uri "$baseUrl/api/data/v9.2/$TableName" -Method POST `
            -Headers $headers -Body $payload | Out-Null
        [pscustomobject] @{
            Persisted = $true
            RecordId  = $recordId
            Error     = $null
        }
    }
    catch {
        Write-InventoryTrace -Level Warning -Message 'Sync Run could not be written to Dataverse; continuing with Application Insights only.' `
            -CorrelationId $RunId -Data @{
                category  = 'WriteFailed'
                operation = 'CreateSyncRun'
                error     = $_.Exception.Message
            }
        [pscustomobject] @{
            Persisted = $false
            RecordId  = $recordId
            Error     = $_.Exception.Message
        }
    }
}

function Complete-InventorySyncRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $DataverseUrl,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $AccessToken,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $TableName,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RecordId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RunId,
        [Parameter(Mandatory)] [ValidateSet('Collect', 'Write', 'DeletionCheck')] [string] $Phase,
        [Parameter(Mandatory)] [ValidateSet('Running', 'Succeeded', 'Partial', 'Failed')] [string] $Status,
        [Parameter(Mandatory)] [psobject] $Counts,
        [Parameter()] [datetimeoffset] $CompletedOn = [datetimeoffset]::UtcNow
    )

    try {
        if ($TableName -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
            throw "Invalid Sync Run table name '$TableName'."
        }
        if ($RecordId -notmatch '^[0-9a-fA-F-]{36}$') {
            throw "Invalid Sync Run record ID '$RecordId'."
        }

        $phaseValue = switch ($Phase) {
            'Collect' { 100000000 }
            'Write' { 100000001 }
            'DeletionCheck' { 100000002 }
        }
        $statusValue = switch ($Status) {
            'Running' { 100000000 }
            'Succeeded' { 100000001 }
            'Partial' { 100000002 }
            'Failed' { 100000003 }
        }
        $payload = [ordered] @{
            invs_phase              = $phaseValue
            invs_completedon        = $CompletedOn.ToString('o')
            invs_status             = $statusValue
            invs_environmentstotal  = [int] $Counts.EnvironmentsTotal
            invs_environmentsfailed = [int] $Counts.EnvironmentsFailed
            invs_found              = [int] $Counts.Found
            invs_created            = [int] $Counts.Created
            invs_updated            = [int] $Counts.Updated
            invs_unchanged          = [int] $Counts.Unchanged
            invs_markeddeleted      = [int] $Counts.MarkedDeleted
            invs_restored           = [int] $Counts.Restored
            invs_errors             = [int] $Counts.Errors
        }
        $headers = @{
            Authorization = "******"
            Accept        = 'application/json'
        }
        $baseUrl = $DataverseUrl.TrimEnd('/')
        Invoke-InventoryHttpRequest -Uri "$baseUrl/api/data/v9.2/$TableName($RecordId)" `
            -Method PATCH -Headers $headers -Body $payload | Out-Null
        [pscustomobject] @{ Persisted = $true; Error = $null }
    }
    catch {
        Write-InventoryTrace -Level Warning -Message 'Sync Run completion could not be written to Dataverse; continuing with Application Insights only.' `
            -CorrelationId $RunId -Data @{
                category  = 'WriteFailed'
                operation = 'CompleteSyncRun'
                error     = $_.Exception.Message
            }
        [pscustomobject] @{ Persisted = $false; Error = $_.Exception.Message }
    }
}

function Write-InventorySyncLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $DataverseUrl,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $AccessToken,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $TableName,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SyncRunTableName,
        [Parameter()] [AllowEmptyString()] [string] $RunRecordId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $CorrelationId,
        [Parameter(Mandatory)] [ValidateSet('Warning', 'Error')] [string] $Severity,
        [Parameter(Mandatory)] [ValidateSet(
            'EnvironmentUnreachable', 'PermissionDenied', 'Throttled', 'ReadFailed',
            'WriteFailed', 'VerifyFailed', 'Config', 'RunSkipped', 'Restored', 'Skipped'
        )] [string] $Category,
        [Parameter()] [AllowEmptyString()] [string] $EnvironmentId,
        [Parameter()] [AllowEmptyString()] [string] $EnvironmentName,
        [Parameter()] [int] $ComponentType,
        [Parameter()] [AllowEmptyString()] [string] $ComponentId,
        [Parameter()] [AllowEmptyString()] [string] $Operation,
        [Parameter()] [int] $HttpStatus,
        [Parameter()] [AllowEmptyString()] [string] $ErrorCode,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Message,
        [Parameter()] [datetimeoffset] $OccurredOn = [datetimeoffset]::UtcNow
    )

    $traceData = [ordered] @{
        category        = $Category
        environmentId   = $EnvironmentId
        environmentName = $EnvironmentName
        componentType   = $ComponentType
        componentId     = $ComponentId
        operation       = $Operation
        httpStatus      = $HttpStatus
        errorCode       = $ErrorCode
    }
    Write-InventoryTrace -Level $Severity -Message $Message -CorrelationId $CorrelationId `
        -Data $traceData -ErrorAction Continue

    try {
        if ($TableName -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
            throw "Invalid Sync Log table name '$TableName'."
        }
        if ($SyncRunTableName -notmatch '^[A-Za-z][A-Za-z0-9_]*$') {
            throw "Invalid Sync Run table name '$SyncRunTableName'."
        }
        if ($RunRecordId -notmatch '^[0-9a-fA-F-]{36}$') {
            throw 'The Sync Run header was not persisted.'
        }

        $categoryValue = switch ($Category) {
            'EnvironmentUnreachable' { 100000000 }
            'PermissionDenied' { 100000001 }
            'Throttled' { 100000002 }
            'ReadFailed' { 100000003 }
            'WriteFailed' { 100000004 }
            'VerifyFailed' { 100000005 }
            'Config' { 100000006 }
            'RunSkipped' { 100000007 }
            'Restored' { 100000008 }
            'Skipped' { 100000009 }
        }
        $payload = [ordered] @{
            invs_synclogid                   = [guid]::NewGuid().ToString()
            'invs_syncrunid@odata.bind'      = "/$SyncRunTableName($RunRecordId)"
            invs_severity                    = if ($Severity -eq 'Warning') { 100000000 } else { 100000001 }
            invs_category                    = $categoryValue
            invs_environmentid               = $EnvironmentId
            invs_environmentname             = $EnvironmentName
            invs_componenttype               = $ComponentType
            invs_componentid                 = $ComponentId
            invs_operation                   = $Operation
            invs_httpstatus                  = $HttpStatus
            invs_errorcode                   = $ErrorCode
            invs_errormessage                = $Message
            invs_occurredon                  = $OccurredOn.ToString('o')
            invs_correlationid               = $CorrelationId
        }
        $headers = @{
            Authorization = "******"
            Accept        = 'application/json'
        }
        $baseUrl = $DataverseUrl.TrimEnd('/')
        Invoke-InventoryHttpRequest -Uri "$baseUrl/api/data/v9.2/$TableName" -Method POST `
            -Headers $headers -Body $payload | Out-Null
        [pscustomobject] @{ Persisted = $true; Error = $null }
    }
    catch {
        Write-InventoryTrace -Level Warning -Message 'Sync Log could not be written to Dataverse; continuing with Application Insights only.' `
            -CorrelationId $CorrelationId -Data @{
                category  = 'WriteFailed'
                operation = 'CreateSyncLog'
                error     = $_.Exception.Message
            }
        [pscustomobject] @{ Persisted = $false; Error = $_.Exception.Message }
    }
}

function New-InventorySyncLogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Warning', 'Error')] [string] $Severity,
        [Parameter(Mandatory)] [string] $Category,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Message,
        [Parameter()] [AllowEmptyString()] [string] $EnvironmentId = '',
        [Parameter()] [AllowEmptyString()] [string] $EnvironmentName = '',
        [Parameter()] [int] $ComponentType = 0,
        [Parameter()] [AllowEmptyString()] [string] $ComponentId = '',
        [Parameter()] [AllowEmptyString()] [string] $Operation = '',
        [Parameter()] [int] $HttpStatus = 0,
        [Parameter()] [AllowEmptyString()] [string] $ErrorCode = '',
        [Parameter()] [datetimeoffset] $OccurredOn = [datetimeoffset]::UtcNow
    )

    [pscustomobject] [ordered] @{
        Severity        = $Severity
        Category        = $Category
        EnvironmentId   = $EnvironmentId
        EnvironmentName = $EnvironmentName
        ComponentType   = $ComponentType
        ComponentId     = $ComponentId
        Operation       = $Operation
        HttpStatus      = $HttpStatus
        ErrorCode       = $ErrorCode
        Message         = $Message
        OccurredOn      = $OccurredOn
    }
}

function Write-InventorySyncLogEntry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Entry,
        [Parameter(Mandatory)] [psobject] $Configuration,
        [Parameter(Mandatory)] [string] $AccessToken,
        [Parameter()] [AllowEmptyString()] [string] $RunRecordId = '',
        [Parameter(Mandatory)] [string] $CorrelationId,
        [Parameter()] [System.Management.Automation.PSCmdlet] $Caller
    )

    $values = [ordered] @{}
    foreach ($definition in @(
            @('EnvironmentId', ''), @('EnvironmentName', ''), @('ComponentType', 0),
            @('ComponentId', ''), @('Operation', ''), @('HttpStatus', 0),
            @('ErrorCode', ''), @('OccurredOn', [datetimeoffset]::UtcNow)
        )) {
        $property = $Entry.PSObject.Properties[$definition[0]]
        $values[$definition[0]] = if ($null -ne $property) { $property.Value } else { $definition[1] }
    }
    $normalized = New-InventorySyncLogEntry -Severity ([string] $Entry.Severity) `
        -Category ([string] $Entry.Category) -Message ([string] $Entry.Message) `
        -EnvironmentId ([string] $values.EnvironmentId) `
        -EnvironmentName ([string] $values.EnvironmentName) `
        -ComponentType ([int] $values.ComponentType) -ComponentId ([string] $values.ComponentId) `
        -Operation ([string] $values.Operation) -HttpStatus ([int] $values.HttpStatus) `
        -ErrorCode ([string] $values.ErrorCode) -OccurredOn ([datetimeoffset] $values.OccurredOn)

    $runTable = $Configuration.PSObject.Properties['SyncRunTable']
    $logTable = $Configuration.PSObject.Properties['SyncLogTable']
    if (
        $null -ne $runTable -and $null -ne $logTable -and
        -not [string]::IsNullOrWhiteSpace([string] $runTable.Value) -and
        -not [string]::IsNullOrWhiteSpace([string] $logTable.Value)
    ) {
        return Write-InventorySyncLog -DataverseUrl $Configuration.TargetDataverseUrl `
            -AccessToken $AccessToken -TableName ([string] $logTable.Value) `
            -SyncRunTableName ([string] $runTable.Value) -RunRecordId $RunRecordId `
            -CorrelationId $CorrelationId -Severity $normalized.Severity `
            -Category $normalized.Category -EnvironmentId $normalized.EnvironmentId `
            -EnvironmentName $normalized.EnvironmentName `
            -ComponentType $normalized.ComponentType -ComponentId $normalized.ComponentId `
            -Operation $normalized.Operation -HttpStatus $normalized.HttpStatus `
            -ErrorCode $normalized.ErrorCode -Message $normalized.Message `
            -OccurredOn $normalized.OccurredOn
    }

    $traceData = [ordered] @{}
    foreach ($name in @(
            'Category', 'EnvironmentId', 'EnvironmentName', 'ComponentType',
            'ComponentId', 'Operation', 'HttpStatus', 'ErrorCode'
        )) {
        $traceData[$name.Substring(0, 1).ToLowerInvariant() + $name.Substring(1)] =
            $normalized.$name
    }
    $traceJson = ConvertTo-InventoryTraceJson -Level $normalized.Severity `
        -Message $normalized.Message -CorrelationId $CorrelationId -Data $traceData
    if ($normalized.Severity -eq 'Warning') {
        if ($null -ne $Caller) {
            $Caller.WriteWarning($traceJson)
        }
        else {
            Write-Warning -Message $traceJson
        }
    }
    else {
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new($traceJson),
            'InventorySync',
            [System.Management.Automation.ErrorCategory]::NotSpecified,
            $null
        )
        if ($null -ne $Caller) {
            $Caller.WriteError($errorRecord)
        }
        else {
            Write-Error -ErrorRecord $errorRecord
        }
    }
    [pscustomobject] @{ Persisted = $false; Error = $null }
}

function Write-InventorySyncSkippedRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Configuration,
        [Parameter(Mandatory)] [ValidateSet('AgentBuilder', 'RPA')] [string] $SyncType,
        [Parameter()] [string] $DataverseAccessToken,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $CorrelationId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $InstanceId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RuntimeStatus,
        [Parameter()] [datetimeoffset] $Now = [datetimeoffset]::UtcNow
    )

    $displayName = if ($SyncType -eq 'AgentBuilder') { 'Agent' } else { 'RPA' }
    $componentType = if ($SyncType -eq 'AgentBuilder') { 5 } else { 4 }
    $message = "$displayName sync start skipped because singleton '$InstanceId' is $RuntimeStatus."
    $counts = [pscustomobject] @{
        EnvironmentsTotal = 0; EnvironmentsFailed = 0; Found = 0; Created = 0
        Updated = 0; Unchanged = 0; MarkedDeleted = 0; Restored = 0
        Errors = 1; Skipped = 1
    }
    try {
        if ([string]::IsNullOrWhiteSpace($DataverseAccessToken)) {
            $DataverseAccessToken = Get-InventoryAccessToken `
                -Resource $Configuration.TargetDataverseUrl -Configuration $Configuration
        }
        $runHeader = Start-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
            -AccessToken $DataverseAccessToken -TableName $Configuration.SyncRunTable `
            -RunId $CorrelationId -SyncType $SyncType -StartedOn $Now
        $logEntry = New-InventorySyncLogEntry -Severity Warning -Category RunSkipped `
            -ComponentType $componentType -Operation Start -Message $message
        Write-InventorySyncLogEntry -Entry $logEntry -Configuration $Configuration `
            -AccessToken $DataverseAccessToken `
            -RunRecordId $(if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }) `
            -CorrelationId $CorrelationId -Caller $PSCmdlet | Out-Null
        if ($runHeader.Persisted) {
            Complete-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
                -AccessToken $DataverseAccessToken -TableName $Configuration.SyncRunTable `
                -RecordId $runHeader.RecordId -RunId $CorrelationId -Phase Collect `
                -Status Partial -Counts $counts -CompletedOn $Now | Out-Null
        }
    }
    catch {
        Write-InventoryTrace -Level Warning -Message $message -CorrelationId $CorrelationId `
            -Data @{
                category = 'RunSkipped'; instanceId = $InstanceId
                runtimeStatus = $RuntimeStatus; loggingError = $_.Exception.Message
            }
    }

    [pscustomobject] @{
        CorrelationId = $CorrelationId
        Status = 'Partial'
        Counts = $counts
    }
}

function Write-AgentSyncSkippedRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Configuration,
        [Parameter()] [string] $DataverseAccessToken,
        [Parameter(Mandatory)] [string] $CorrelationId,
        [Parameter(Mandatory)] [string] $InstanceId,
        [Parameter(Mandatory)] [string] $RuntimeStatus,
        [Parameter()] [datetimeoffset] $Now = [datetimeoffset]::UtcNow
    )
    Write-InventorySyncSkippedRun -Configuration $Configuration -SyncType AgentBuilder `
        -DataverseAccessToken $DataverseAccessToken -CorrelationId $CorrelationId `
        -InstanceId $InstanceId -RuntimeStatus $RuntimeStatus -Now $Now
}

function Write-RpaSyncSkippedRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Configuration,
        [Parameter()] [string] $DataverseAccessToken,
        [Parameter(Mandatory)] [string] $CorrelationId,
        [Parameter(Mandatory)] [string] $InstanceId,
        [Parameter(Mandatory)] [string] $RuntimeStatus,
        [Parameter()] [datetimeoffset] $Now = [datetimeoffset]::UtcNow
    )
    Write-InventorySyncSkippedRun -Configuration $Configuration -SyncType RPA `
        -DataverseAccessToken $DataverseAccessToken -CorrelationId $CorrelationId `
        -InstanceId $InstanceId -RuntimeStatus $RuntimeStatus -Now $Now
}

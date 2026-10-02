Set-StrictMode -Version Latest

$script:TokenCache = @{}
$script:TokenRefreshBuffer = [timespan]::FromMinutes(5)

function Get-InventorySyncConfiguration {
    [CmdletBinding()]
    param(
        [Parameter()]
        [System.Collections.IDictionary] $Settings = [System.Environment]::GetEnvironmentVariables()
    )

    $requiredSettings = [ordered]@{
        INVENTORY_TENANT_ID                   = 'TenantId'
        INVENTORY_CLIENT_ID                   = 'ClientId'
        INVENTORY_CLIENT_SECRET               = 'ClientSecret'
        INVENTORY_TARGET_DATAVERSE_URL        = 'TargetDataverseUrl'
        INVENTORY_AGENT_CREATED_IN            = 'AgentCreatedIn'
        APPLICATIONINSIGHTS_CONNECTION_STRING = 'ApplicationInsightsConnectionString'
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
    $configuration.AgentSchedule = if (
        $Settings.Contains('INVENTORY_AGENT_SCHEDULE') -and
        -not [string]::IsNullOrWhiteSpace([string] $Settings['INVENTORY_AGENT_SCHEDULE'])
    ) {
        ([string] $Settings['INVENTORY_AGENT_SCHEDULE']).Trim()
    }
    else {
        '0 0 0 * * *'
    }
    $configuration.RpaSchedule = if (
        $Settings.Contains('INVENTORY_RPA_SCHEDULE') -and
        -not [string]::IsNullOrWhiteSpace([string] $Settings['INVENTORY_RPA_SCHEDULE'])
    ) {
        ([string] $Settings['INVENTORY_RPA_SCHEDULE']).Trim()
    }
    else {
        '0 0 0 * * *'
    }
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
    $configuration.AgentSubscriptions = if (
        $Settings.Contains('INVENTORY_AGENT_SUBSCRIPTIONS') -and
        -not [string]::IsNullOrWhiteSpace([string] $Settings['INVENTORY_AGENT_SUBSCRIPTIONS'])
    ) {
        @(
            ([string] $Settings['INVENTORY_AGENT_SUBSCRIPTIONS']).Split(',') |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
    }
    else {
        @()
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

function Get-ResponseHeaderValue {
    param(
        [Parameter(Mandatory)] $Headers,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($Headers -is [System.Collections.IDictionary]) {
        foreach ($key in $Headers.Keys) {
            if ([string] $key -ieq $Name) {
                return [string] $Headers[$key]
            }
        }
        return $null
    }

    try {
        $values = $Headers.GetValues($Name)
        if ($null -ne $values) {
            return [string] ($values | Select-Object -First 1)
        }
    }
    catch {
        return $null
    }
}

function Get-RetryDelaySeconds {
    param(
        [Parameter(Mandatory)] $Headers,
        [Parameter(Mandatory)] [int] $RetryNumber
    )

    $retryAfter = Get-ResponseHeaderValue -Headers $Headers -Name 'Retry-After'
    $seconds = 0.0
    if ([double]::TryParse(
            $retryAfter,
            [System.Globalization.NumberStyles]::Number,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [ref] $seconds
        )) {
        return [Math]::Max(0, $seconds)
    }

    $retryAt = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse(
            $retryAfter,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal,
            [ref] $retryAt
        )) {
        return [Math]::Max(0, ($retryAt - [datetimeoffset]::UtcNow).TotalSeconds)
    }

    [Math]::Min(60, [Math]::Pow(2, $RetryNumber - 1))
}

function ConvertFrom-InventoryJson {
    param([AllowNull()] [string] $Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $null
    }

    try {
        return $Content | ConvertFrom-Json -Depth 100
    }
    catch {
        return $Content
    }
}

function Invoke-InventoryHttpRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [uri] $Uri,
        [Parameter()] [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')] [string] $Method = 'GET',
        [Parameter()] [System.Collections.IDictionary] $Headers = @{},
        [Parameter()] [AllowNull()] $Body,
        [Parameter()] [string] $ContentType = 'application/json',
        [Parameter()] [ValidateRange(0, 10)] [int] $MaxRetryCount = 3,
        [Parameter()] [ValidateRange(1, 600)] [int] $TimeoutSec = 100,
        [Parameter()] [scriptblock] $Invoker = {
            param($request)
            Invoke-WebRequest @request -SkipHttpErrorCheck
        },
        [Parameter()] [scriptblock] $SleepAction = {
            param([double] $seconds)
            Start-Sleep -Seconds $seconds
        }
    )

    $request = @{
        Uri         = $Uri
        Method      = $Method
        Headers     = $Headers
        ContentType = $ContentType
        TimeoutSec  = $TimeoutSec
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $request.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 100 -Compress }
    }

    for ($attempt = 1; $attempt -le ($MaxRetryCount + 1); $attempt++) {
        try {
            $rawResponse = & $Invoker $request
        }
        catch {
            if ($attempt -le $MaxRetryCount) {
                $delay = Get-RetryDelaySeconds -Headers @{} -RetryNumber $attempt
                & $SleepAction $delay
                continue
            }
            throw "HTTP request to '$Uri' failed before a response was received: $($_.Exception.Message)"
        }

        $statusCode = [int] $rawResponse.StatusCode
        $content = [string] $rawResponse.Content
        $bodyValue = ConvertFrom-InventoryJson -Content $content

        if ($statusCode -ge 200 -and $statusCode -lt 300) {
            return [pscustomobject] @{
                StatusCode = $statusCode
                Headers    = $rawResponse.Headers
                Body       = $bodyValue
            }
        }

        $isServiceProtection = $content -match '0x800723(?:21|22|26)'
        $isRetryable = $statusCode -in @(408, 429, 500, 502, 503, 504) -or $isServiceProtection
        if ($isRetryable -and $attempt -le $MaxRetryCount) {
            $delay = Get-RetryDelaySeconds -Headers $rawResponse.Headers -RetryNumber $attempt
            & $SleepAction $delay
            continue
        }

        $errorMessage = $null
        if ($null -ne $bodyValue -and $bodyValue -isnot [string]) {
            $errorProperty = $bodyValue.PSObject.Properties['error']
            if ($null -ne $errorProperty -and $null -ne $errorProperty.Value) {
                $messageProperty = $errorProperty.Value.PSObject.Properties['message']
                if ($null -ne $messageProperty) {
                    $errorMessage = [string] $messageProperty.Value
                }
            }
            if ([string]::IsNullOrWhiteSpace($errorMessage)) {
                $titleProperty = $bodyValue.PSObject.Properties['title']
                if ($null -ne $titleProperty) {
                    $errorMessage = [string] $titleProperty.Value
                }
            }
        }
        if ([string]::IsNullOrWhiteSpace($errorMessage)) {
            $errorMessage = if (-not [string]::IsNullOrWhiteSpace($content)) {
                $content
            }
            else {
                'The service returned no error details.'
            }
        }
        throw "HTTP $statusCode from '$Uri': $errorMessage"
    }
}

function Clear-InventoryTokenCache {
    [CmdletBinding()]
    param()

    $script:TokenCache.Clear()
}

function ConvertTo-FormValue {
    param([Parameter(Mandatory)] [string] $Value)

    [System.Net.WebUtility]::UrlEncode($Value)
}

function Get-InventoryAccessToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Resource,
        [Parameter(Mandatory)] [psobject] $Configuration,
        [Parameter()] [datetimeoffset] $Now = [datetimeoffset]::UtcNow
    )

    $normalizedResource = $Resource.Trim().TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($normalizedResource)) {
        throw 'Resource must not be empty.'
    }

    $cacheKey = "$($Configuration.TenantId)|$($Configuration.ClientId)|$($normalizedResource.ToLowerInvariant())"
    if ($script:TokenCache.ContainsKey($cacheKey)) {
        $cachedToken = $script:TokenCache[$cacheKey]
        if ($Now -lt ($cachedToken.ExpiresOn - $script:TokenRefreshBuffer)) {
            return $cachedToken.AccessToken
        }
    }

    $tokenUri = "https://login.microsoftonline.com/$($Configuration.TenantId)/oauth2/v2.0/token"
    $formFields = [ordered]@{
        client_id     = [string] $Configuration.ClientId
        client_secret = [string] $Configuration.ClientSecret
        grant_type    = 'client_credentials'
        scope         = "$normalizedResource/.default"
    }
    $formBody = @(
        foreach ($entry in $formFields.GetEnumerator()) {
            '{0}={1}' -f (ConvertTo-FormValue $entry.Key), (ConvertTo-FormValue $entry.Value)
        }
    ) -join '&'

    $response = Invoke-InventoryHttpRequest -Uri $tokenUri -Method POST `
        -ContentType 'application/x-www-form-urlencoded' -Body $formBody
    if ($null -eq $response.Body -or [string]::IsNullOrWhiteSpace([string] $response.Body.access_token)) {
        throw "Token endpoint '$tokenUri' returned no access token."
    }

    $expiresIn = 3600
    if ($null -ne $response.Body.expires_in) {
        $expiresIn = [int] $response.Body.expires_in
    }
    if ($expiresIn -le 0) {
        throw "Token endpoint '$tokenUri' returned an invalid expiry."
    }

    $script:TokenCache[$cacheKey] = [pscustomobject] @{
        AccessToken = [string] $response.Body.access_token
        ExpiresOn   = $Now.AddSeconds($expiresIn)
    }

    [string] $response.Body.access_token
}

function Get-DataversePagedRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [uri] $Uri,
        [Parameter(Mandatory)] [string] $AccessToken,
        [Parameter()] [System.Collections.IDictionary] $AdditionalHeaders = @{}
    )

    $headers = @{
        Authorization    = "Bearer $AccessToken"
        Accept           = 'application/json'
        'OData-MaxVersion' = '4.0'
        'OData-Version'  = '4.0'
    }
    foreach ($header in $AdditionalHeaders.GetEnumerator()) {
        $headers[[string] $header.Key] = $header.Value
    }
    $nextUri = [string] $Uri
    $visitedUris = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    while (-not [string]::IsNullOrWhiteSpace($nextUri)) {
        if (-not $visitedUris.Add($nextUri)) {
            throw "Dataverse returned a repeated @odata.nextLink: '$nextUri'."
        }

        $response = Invoke-InventoryHttpRequest -Uri $nextUri -Headers $headers
        foreach ($record in @($response.Body.value)) {
            $record
        }

        $nextLinkProperty = $response.Body.PSObject.Properties['@odata.nextLink']
        $nextUri = if ($null -ne $nextLinkProperty) { [string] $nextLinkProperty.Value } else { $null }
    }
}

function Invoke-ResourceGraphPagedQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Query,
        [Parameter()] [AllowEmptyCollection()] [string[]] $Subscriptions = @(),
        [Parameter(Mandatory)] [string] $AccessToken
    )

    $uri = 'https://management.azure.com/providers/Microsoft.ResourceGraph/resources?api-version=2024-04-01'
    $headers = @{
        Authorization = "Bearer $AccessToken"
        Accept        = 'application/json'
    }
    $skipToken = $null
    $seenTokens = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    do {
        $options = [ordered]@{
            resultFormat = 'objectArray'
        }
        if (-not [string]::IsNullOrWhiteSpace($skipToken)) {
            $options['$skipToken'] = $skipToken
        }
        $requestBody = [ordered]@{
            query   = $Query
            options = [pscustomobject] $options
        }
        if ($Subscriptions.Count -gt 0) {
            $requestBody['subscriptions'] = $Subscriptions
        }

        $response = Invoke-InventoryHttpRequest -Uri $uri -Method POST -Headers $headers -Body $requestBody
        foreach ($record in @($response.Body.data)) {
            $record
        }

        $skipTokenProperty = $response.Body.PSObject.Properties['$skipToken']
        $skipToken = if ($null -ne $skipTokenProperty) { [string] $skipTokenProperty.Value } else { $null }
        $truncatedProperty = $response.Body.PSObject.Properties['resultTruncated']
        if (
            $null -ne $truncatedProperty -and
            [string] $truncatedProperty.Value -ieq 'true' -and
            [string]::IsNullOrWhiteSpace($skipToken)
        ) {
            throw 'Resource Graph returned an incomplete result without a continuation token.'
        }
        if (-not [string]::IsNullOrWhiteSpace($skipToken) -and -not $seenTokens.Add($skipToken)) {
            throw "Resource Graph returned a repeated `$skipToken: '$skipToken'."
        }
    } while (-not [string]::IsNullOrWhiteSpace($skipToken))
}

function Get-AgentBuilderAgents {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $CreatedIn,
        [Parameter()] [AllowEmptyCollection()] [string[]] $Subscriptions = @(),
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

    Invoke-ResourceGraphPagedQuery -Query $query -Subscriptions $Subscriptions -AccessToken $AccessToken
}

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

function New-InventoryComponentId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $EnvironmentId,
        [Parameter(Mandatory)] [ValidateRange(0, [int]::MaxValue)] [int] $ComponentType,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $SourceId
    )

    $namespaceBytes = ([guid] '89d605f0-44cb-497c-a664-96c6c13d2bfc').ToByteArray()
    [array]::Reverse($namespaceBytes, 0, 4)
    [array]::Reverse($namespaceBytes, 4, 2)
    [array]::Reverse($namespaceBytes, 6, 2)

    $name = '{0}|{1}|{2}' -f $EnvironmentId.Trim().ToLowerInvariant(), $ComponentType,
        $SourceId.Trim().ToLowerInvariant()
    $nameBytes = [System.Text.Encoding]::UTF8.GetBytes($name)
    $inputBytes = [byte[]]::new($namespaceBytes.Length + $nameBytes.Length)
    [array]::Copy($namespaceBytes, 0, $inputBytes, 0, $namespaceBytes.Length)
    [array]::Copy($nameBytes, 0, $inputBytes, $namespaceBytes.Length, $nameBytes.Length)

    $hash = [System.Security.Cryptography.SHA1]::HashData($inputBytes)
    $guidBytes = [byte[]] $hash[0..15]
    $guidBytes[6] = [byte] (($guidBytes[6] -band 0x0f) -bor 0x50)
    $guidBytes[8] = [byte] (($guidBytes[8] -band 0x3f) -bor 0x80)
    [array]::Reverse($guidBytes, 0, 4)
    [array]::Reverse($guidBytes, 4, 2)
    [array]::Reverse($guidBytes, 6, 2)

    ([guid]::new($guidBytes)).ToString()
}

function Test-InventoryTechnicalValueEqual {
    param(
        [Parameter(Mandatory)] [string] $FieldName,
        [AllowNull()] $ExistingValue,
        [AllowNull()] $SourceValue
    )

    if ($FieldName -in @('palp_urspruenglicherstelltam', 'palp_urspruenglichgeaendertam')) {
        $existingTimestamp = [datetimeoffset]::MinValue
        $sourceTimestamp = [datetimeoffset]::MinValue
        if (
            [datetimeoffset]::TryParse([string] $ExistingValue, [ref] $existingTimestamp) -and
            [datetimeoffset]::TryParse([string] $SourceValue, [ref] $sourceTimestamp)
        ) {
            return $existingTimestamp.UtcTicks -eq $sourceTimestamp.UtcTicks
        }
    }
    if ($FieldName -eq 'palp_besitzerobjectid') {
        return [string] $ExistingValue -ieq [string] $SourceValue
    }

    [string] $ExistingValue -ceq [string] $SourceValue
}

function New-InventoryComponentReconciliationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $SourceComponents,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Environments,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $ExistingComponents,
        [Parameter(Mandatory)] [ValidateRange(0, [int]::MaxValue)] [int] $ComponentType,
        [Parameter()] [ValidateRange(0, [int]::MaxValue)] [int] $CreationCap = [int]::MaxValue,
        [Parameter()] [datetimeoffset] $Now = [datetimeoffset]::UtcNow
    )

    $existingById = @{}
    foreach ($existing in $ExistingComponents) {
        $typeProperty = $existing.PSObject.Properties['palp_typ']
        if ($null -ne $typeProperty -and [int] $typeProperty.Value -ne $ComponentType) {
            continue
        }
        $idProperty = $existing.PSObject.Properties['palp_id']
        if ($null -ne $idProperty -and -not [string]::IsNullOrWhiteSpace([string] $idProperty.Value)) {
            $existingById[[string] $idProperty.Value] = $existing
        }
    }
    $knownEnvironmentIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($environment in $Environments) {
        $environmentIdProperty = $environment.PSObject.Properties['palp_id']
        if (
            $null -ne $environmentIdProperty -and
            -not [string]::IsNullOrWhiteSpace([string] $environmentIdProperty.Value)
        ) {
            $null = $knownEnvironmentIds.Add(([string] $environmentIdProperty.Value).Trim())
        }
    }

    $writes = [System.Collections.Generic.List[object]]::new()
    $logs = [System.Collections.Generic.List[object]]::new()
    $created = 0
    $updated = 0
    $restored = 0
    $unchanged = 0
    $skipped = 0
    foreach ($source in $SourceComponents) {
        $environmentId = ([string] $source.EnvironmentId).Trim()
        $componentId = New-InventoryComponentId -EnvironmentId $environmentId `
            -ComponentType $ComponentType -SourceId ([string] $source.SourceId)
        $escapedEnvironmentId = $environmentId.Replace("'", "''")
        if ($existingById.ContainsKey($componentId)) {
            $existing = $existingById[$componentId]
            $payload = [ordered] @{}
            $componentStatusProperty = $existing.PSObject.Properties['palp_komponentenstatus']
            $isDeleted = $null -ne $componentStatusProperty -and
                [int] $componentStatusProperty.Value -eq 7
            $fieldMappings = [ordered] @{
                palp_titel                    = [string] $source.Title
                palp_besitzerobjectid         = [string] $source.OwnerObjectId
                palp_beschreibung             = $source.Description
                palp_urspruenglicherstelltam  = [string] $source.SourceCreatedAt
                palp_urspruenglichgeaendertam = [string] $source.SourceModifiedAt
            }
            foreach ($mapping in $fieldMappings.GetEnumerator()) {
                $existingProperty = $existing.PSObject.Properties[$mapping.Key]
                $existingValue = if ($null -ne $existingProperty) { $existingProperty.Value } else { $null }
                if (-not (Test-InventoryTechnicalValueEqual -FieldName $mapping.Key `
                            -ExistingValue $existingValue -SourceValue $mapping.Value)) {
                    $payload[$mapping.Key] = $mapping.Value
                }
            }

            $existingEnvironmentId = $null
            $environmentProperty = $existing.PSObject.Properties['palp_environment']
            if ($null -ne $environmentProperty -and $null -ne $environmentProperty.Value) {
                $environmentIdProperty = $environmentProperty.Value.PSObject.Properties['palp_id']
                if ($null -ne $environmentIdProperty) {
                    $existingEnvironmentId = [string] $environmentIdProperty.Value
                }
            }
            if ($existingEnvironmentId -ine $environmentId) {
                $payload['palp_environment@odata.bind'] =
                    "/palp_environments(palp_id='$escapedEnvironmentId')"
            }
            if ($isDeleted) {
                $payload.palp_komponentenstatus = 0
                $payload.palp_status = 0
                $payload.palp_letztestatusaenderung = $Now.ToString('o')
            }

            if ($payload.Count -gt 0) {
                $escapedComponentId = $componentId.Replace("'", "''")
                $writes.Add([pscustomobject] @{
                    Method        = 'PATCH'
                    RelativeUri   = "palp_komponentes(palp_id='$escapedComponentId')"
                    Payload       = [pscustomobject] $payload
                    EnvironmentId = $environmentId
                    ComponentType = $ComponentType
                    ComponentId   = [string] $source.SourceId
                    Operation     = if ($isDeleted) { 'Restore' } else { 'Update' }
                })
                if ($isDeleted) {
                    $restored++
                    $logs.Add([pscustomobject] [ordered] @{
                        Severity      = 'Warning'
                        Category      = 'Restored'
                        EnvironmentId = $environmentId
                        ComponentType = $ComponentType
                        ComponentId   = [string] $source.SourceId
                        Operation     = 'Restore'
                        Message       = 'A previously deleted component was restored to Neu and Aktiv.'
                    })
                }
                else {
                    $updated++
                }
            }
            else {
                $unchanged++
            }
            continue
        }

        if (-not $knownEnvironmentIds.Contains($environmentId)) {
            $logs.Add([pscustomobject] [ordered] @{
                Severity      = 'Warning'
                Category      = 'Skipped'
                EnvironmentId = $environmentId
                ComponentType = $ComponentType
                ComponentId   = [string] $source.SourceId
                Operation     = 'Create'
                Message       = "Environment '$environmentId' is not present in palp_environment."
            })
            $skipped++
            continue
        }

        if ($created -ge $CreationCap) {
            $logs.Add([pscustomobject] [ordered] @{
                Severity      = 'Warning'
                Category      = 'Skipped'
                EnvironmentId = $environmentId
                ComponentType = $ComponentType
                ComponentId   = [string] $source.SourceId
                Operation     = 'Create'
                Message       = "Component was not created because the creation cap of $CreationCap was reached."
            })
            $skipped++
            continue
        }

        $writes.Add([pscustomobject] @{
            Method        = 'POST'
            RelativeUri   = 'palp_komponentes'
            Payload       = [pscustomobject] [ordered] @{
                palp_id                       = $componentId
                palp_typ                      = $ComponentType
                palp_titel                    = [string] $source.Title
                palp_besitzerobjectid         = [string] $source.OwnerObjectId
                palp_beschreibung             = $source.Description
                'palp_environment@odata.bind' = "/palp_environments(palp_id='$escapedEnvironmentId')"
                palp_urspruenglicherstelltam  = [string] $source.SourceCreatedAt
                palp_urspruenglichgeaendertam = [string] $source.SourceModifiedAt
                palp_komponentenstatus        = 0
                palp_status                   = 0
                palp_nutzungsbereich          = 0
                palp_letztestatusaenderung    = $Now.ToString('o')
            }
            EnvironmentId = $environmentId
            ComponentType = $ComponentType
            ComponentId   = [string] $source.SourceId
            Operation     = 'Create'
        })
        $created++
    }

    [pscustomobject] @{
        Writes = $writes.ToArray()
        Logs   = $logs.ToArray()
        Counts = [pscustomobject] @{
            Created   = $created
            Updated   = $updated
            Restored  = $restored
            Skipped   = $skipped
            Unchanged = $unchanged
        }
    }
}

function New-AgentComponentCreatePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Agents,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Environments,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ExistingComponentIds,
        [Parameter()] [datetimeoffset] $Now = [datetimeoffset]::UtcNow
    )

    $knownEnvironmentIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($environment in $Environments) {
        if (-not [string]::IsNullOrWhiteSpace([string] $environment.palp_id)) {
            $null = $knownEnvironmentIds.Add(([string] $environment.palp_id).Trim())
        }
    }

    $existingIds = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($existingId in $ExistingComponentIds) {
        if (-not [string]::IsNullOrWhiteSpace($existingId)) {
            $null = $existingIds.Add($existingId.Trim())
        }
    }

    $writes = [System.Collections.Generic.List[object]]::new()
    $logs = [System.Collections.Generic.List[object]]::new()
    $created = 0
    $skipped = 0
    $unchanged = 0

    foreach ($agent in $Agents) {
        $environmentId = ([string] $agent.environmentId).Trim()
        $sourceId = ([string] $agent.agentId).Trim()
        $componentId = New-InventoryComponentId -EnvironmentId $environmentId `
            -ComponentType 5 -SourceId $sourceId

        if ($existingIds.Contains($componentId)) {
            $unchanged++
            continue
        }

        if (-not $knownEnvironmentIds.Contains($environmentId)) {
            $logs.Add([pscustomobject] [ordered] @{
                Severity      = 'Warning'
                Category      = 'Skipped'
                EnvironmentId = $environmentId
                ComponentType = 5
                ComponentId   = $sourceId
                Operation     = 'Create'
                Message       = "Environment '$environmentId' is not present in palp_environment."
            })
            $skipped++
            continue
        }

        $escapedEnvironmentId = $environmentId.Replace("'", "''")
        $payload = [ordered] @{
            palp_id                       = $componentId
            palp_typ                      = 5
            palp_titel                    = [string] $agent.title
            palp_besitzerobjectid         = [string] $agent.ownerId
            'palp_environment@odata.bind' = "/palp_environments(palp_id='$escapedEnvironmentId')"
            palp_urspruenglicherstelltam  = [string] $agent.createdAt
            palp_urspruenglichgeaendertam = [string] $agent.modifiedAt
            palp_komponentenstatus        = 0
            palp_status                   = 0
            palp_nutzungsbereich          = 0
            palp_letztestatusaenderung    = $Now.ToString('o')
        }
        $writes.Add([pscustomobject] @{
            Method        = 'POST'
            RelativeUri   = 'palp_komponentes'
            Payload       = [pscustomobject] $payload
            EnvironmentId = $environmentId
            ComponentType = 5
            ComponentId   = $sourceId
            Operation     = 'Create'
        })
        $created++
    }

    [pscustomobject] @{
        Writes = $writes.ToArray()
        Logs   = $logs.ToArray()
        Counts = [pscustomobject] @{
            Created   = $created
            Skipped   = $skipped
            Unchanged = $unchanged
        }
    }
}

function Get-InventoryErrorDetails {
    param([Parameter(Mandatory)] [string] $Message)

    $httpStatus = 0
    if ($Message -match '(?i)\bHTTP(?:/1\.[01])?\s+(?<status>[45][0-9]{2})\b') {
        $httpStatus = [int] $Matches.status
    }
    $errorCode = ''
    if ($Message -match '(?i)\b(?<code>0x[0-9a-f]+)\b') {
        $errorCode = [string] $Matches.code
    }
    [pscustomobject] @{
        HttpStatus = $httpStatus
        ErrorCode  = $errorCode
    }
}

function Write-DataverseBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Writes,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $DataverseUrl,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $AccessToken,
        [Parameter()] [ValidateRange(1, 1000)] [int] $BatchSize = 1000
    )

    $baseUrl = $DataverseUrl.TrimEnd('/')
    $batchCount = 0
    $operationCount = 0
    $succeededCount = 0
    $failures = [System.Collections.Generic.List[object]]::new()
    for ($offset = 0; $offset -lt $Writes.Count; $offset += $BatchSize) {
        $lastIndex = [Math]::Min($offset + $BatchSize - 1, $Writes.Count - 1)
        $batchWrites = @($Writes[$offset..$lastIndex])
        $batchBoundary = 'batch_{0}' -f ([guid]::NewGuid().ToString('N'))
        $changeSetBoundary = 'changeset_{0}' -f ([guid]::NewGuid().ToString('N'))
        $lines = [System.Collections.Generic.List[string]]::new()
        $lines.Add("--$batchBoundary")
        $lines.Add("Content-Type: multipart/mixed;boundary=$changeSetBoundary")
        $lines.Add('')

        $contentId = 0
        foreach ($write in $batchWrites) {
            $contentId++
            $lines.Add("--$changeSetBoundary")
            $lines.Add('Content-Type: application/http')
            $lines.Add('Content-Transfer-Encoding: binary')
            $lines.Add("Content-ID: $contentId")
            $lines.Add('')
            $lines.Add("$($write.Method) $($write.RelativeUri) HTTP/1.1")
            $lines.Add('Content-Type: application/json;type=entry')
            $lines.Add('Accept: application/json')
            $lines.Add('')
            $lines.Add(($write.Payload | ConvertTo-Json -Depth 100 -Compress))
            $lines.Add('')
        }
        $lines.Add("--$changeSetBoundary--")
        $lines.Add("--$batchBoundary--")
        $lines.Add('')

        $headers = @{
            Authorization = "Bearer $AccessToken"
            Accept        = 'application/json'
        }
        $contentType = "multipart/mixed;boundary=$batchBoundary"
        $body = $lines -join "`r`n"
        try {
            $response = Invoke-InventoryHttpRequest -Uri "$baseUrl/api/data/v9.2/`$batch" `
                -Method POST -Headers $headers -ContentType $contentType -Body $body
            if ($response.Body -is [string] -and
                $response.Body -match '(?im)^HTTP/1\.[01]\s+[45][0-9]{2}\b') {
                throw "Dataverse batch contained a failed operation: $($response.Body)"
            }
            $succeededCount += $batchWrites.Count
        }
        catch {
            $errorDetails = Get-InventoryErrorDetails -Message $_.Exception.Message
            foreach ($write in $batchWrites) {
                $failures.Add([pscustomobject] @{
                    EnvironmentId = [string] $write.EnvironmentId
                    ComponentType = [int] $write.ComponentType
                    ComponentId   = [string] $write.ComponentId
                    Operation     = [string] $write.Operation
                    HttpStatus    = $errorDetails.HttpStatus
                    ErrorCode     = $errorDetails.ErrorCode
                    Message       = $_.Exception.Message
                })
            }
        }
        $batchCount++
        $operationCount += $batchWrites.Count
    }

    [pscustomobject] @{
        Batches    = $batchCount
        Operations = $operationCount
        Succeeded  = $succeededCount
        Failed     = $failures.Count
        Failures   = $failures.ToArray()
    }
}

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

function Write-AgentSyncSkippedRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Configuration,
        [Parameter()] [string] $DataverseAccessToken,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $CorrelationId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $InstanceId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RuntimeStatus,
        [Parameter()] [datetimeoffset] $Now = [datetimeoffset]::UtcNow
    )

    $message = "Agent sync start skipped because singleton '$InstanceId' is $RuntimeStatus."
    $counts = [pscustomobject] @{
        EnvironmentsTotal  = 0
        EnvironmentsFailed = 0
        Found              = 0
        Created            = 0
        Updated            = 0
        Unchanged          = 0
        MarkedDeleted      = 0
        Restored           = 0
        Errors             = 1
        Skipped            = 1
    }
    try {
        if ([string]::IsNullOrWhiteSpace($DataverseAccessToken)) {
            $DataverseAccessToken = Get-InventoryAccessToken `
                -Resource $Configuration.TargetDataverseUrl -Configuration $Configuration
        }
        $runHeader = Start-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
            -AccessToken $DataverseAccessToken -TableName $Configuration.SyncRunTable `
            -RunId $CorrelationId -SyncType AgentBuilder -StartedOn $Now
        Write-InventorySyncLog -DataverseUrl $Configuration.TargetDataverseUrl `
            -AccessToken $DataverseAccessToken -TableName $Configuration.SyncLogTable `
            -SyncRunTableName $Configuration.SyncRunTable `
            -RunRecordId $(if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }) `
            -CorrelationId $CorrelationId -Severity Warning -Category RunSkipped `
            -Operation Start -Message $message | Out-Null
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
                category      = 'RunSkipped'
                instanceId    = $InstanceId
                runtimeStatus = $RuntimeStatus
                loggingError  = $_.Exception.Message
            }
    }

    [pscustomobject] @{
        CorrelationId = $CorrelationId
        Status        = 'Partial'
        Counts        = $counts
    }
}

function Write-RpaSyncSkippedRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [psobject] $Configuration,
        [Parameter()] [string] $DataverseAccessToken,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $CorrelationId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $InstanceId,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $RuntimeStatus,
        [Parameter()] [datetimeoffset] $Now = [datetimeoffset]::UtcNow
    )

    $message = "RPA sync start skipped because singleton '$InstanceId' is $RuntimeStatus."
    $counts = [pscustomobject] @{
        EnvironmentsTotal  = 0
        EnvironmentsFailed = 0
        Found              = 0
        Created            = 0
        Updated            = 0
        Unchanged          = 0
        MarkedDeleted      = 0
        Restored           = 0
        Errors             = 1
        Skipped            = 1
    }
    try {
        if ([string]::IsNullOrWhiteSpace($DataverseAccessToken)) {
            $DataverseAccessToken = Get-InventoryAccessToken `
                -Resource $Configuration.TargetDataverseUrl -Configuration $Configuration
        }
        $runHeader = Start-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
            -AccessToken $DataverseAccessToken -TableName $Configuration.SyncRunTable `
            -RunId $CorrelationId -SyncType RPA -StartedOn $Now
        Write-InventorySyncLog -DataverseUrl $Configuration.TargetDataverseUrl `
            -AccessToken $DataverseAccessToken -TableName $Configuration.SyncLogTable `
            -SyncRunTableName $Configuration.SyncRunTable `
            -RunRecordId $(if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }) `
            -CorrelationId $CorrelationId -Severity Warning -Category RunSkipped `
            -ComponentType 4 -Operation Start -Message $message | Out-Null
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
                category      = 'RunSkipped'
                instanceId    = $InstanceId
                runtimeStatus = $RuntimeStatus
                loggingError  = $_.Exception.Message
            }
    }

    [pscustomobject] @{
        CorrelationId = $CorrelationId
        Status        = 'Partial'
        Counts        = $counts
    }
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
        -Subscriptions @($Configuration.AgentSubscriptions) -AccessToken $ResourceGraphAccessToken)
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

    foreach ($logEntry in $plan.Logs) {
        if ($loggingConfigured) {
            Write-InventorySyncLog -DataverseUrl $Configuration.TargetDataverseUrl `
                -AccessToken $DataverseAccessToken -TableName ([string] $syncLogTableProperty.Value) `
                -SyncRunTableName ([string] $syncRunTableProperty.Value) `
                -RunRecordId $(if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }) `
                -CorrelationId $CorrelationId -Severity $logEntry.Severity `
                -Category $logEntry.Category -EnvironmentId $logEntry.EnvironmentId `
                -ComponentType $logEntry.ComponentType -ComponentId $logEntry.ComponentId `
                -Operation $logEntry.Operation -Message $logEntry.Message | Out-Null
        }
        else {
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

    $phase = 'Write'
    $batch = Write-DataverseBatch -Writes $plan.Writes -DataverseUrl $baseUrl `
        -AccessToken $DataverseAccessToken

    foreach ($failure in $batch.Failures) {
        if ($loggingConfigured) {
            Write-InventorySyncLog -DataverseUrl $Configuration.TargetDataverseUrl `
                -AccessToken $DataverseAccessToken -TableName ([string] $syncLogTableProperty.Value) `
                -SyncRunTableName ([string] $syncRunTableProperty.Value) `
                -RunRecordId $(if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }) `
                -CorrelationId $CorrelationId -Severity Error -Category WriteFailed `
                -EnvironmentId $failure.EnvironmentId -ComponentType $failure.ComponentType `
                -ComponentId $failure.ComponentId -Operation $failure.Operation `
                -HttpStatus $failure.HttpStatus -ErrorCode $failure.ErrorCode `
                -Message $failure.Message | Out-Null
        }
        else {
            Write-InventoryTrace -Level Error -Message $failure.Message `
                -CorrelationId $CorrelationId -Data @{
                    category      = 'WriteFailed'
                    environmentId = $failure.EnvironmentId
                    componentType = $failure.ComponentType
                    componentId   = $failure.ComponentId
                    operation     = $failure.Operation
                    httpStatus    = $failure.HttpStatus
                    errorCode     = $failure.ErrorCode
                }
        }
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
        if ($loggingConfigured) {
            Write-InventorySyncLog -DataverseUrl $Configuration.TargetDataverseUrl `
                -AccessToken $DataverseAccessToken -TableName ([string] $syncLogTableProperty.Value) `
                -SyncRunTableName ([string] $syncRunTableProperty.Value) `
                -RunRecordId $(if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }) `
                -CorrelationId $CorrelationId -Severity Error -Category $category `
                -Operation $phase -HttpStatus $errorDetails.HttpStatus `
                -ErrorCode $errorDetails.ErrorCode -Message $failure.Exception.Message `
                -ErrorAction Continue | Out-Null
        }
        else {
            Write-InventoryTrace -Level Error -Message $failure.Exception.Message `
                -CorrelationId $CorrelationId -Data @{
                    category  = $category
                    operation = $phase
                    httpStatus = $errorDetails.HttpStatus
                    errorCode = $errorDetails.ErrorCode
                } -ErrorAction Continue
        }
        if ($loggingConfigured -and $runHeader.Persisted) {
            Complete-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
                -AccessToken $DataverseAccessToken -TableName ([string] $syncRunTableProperty.Value) `
                -RecordId $runHeader.RecordId -RunId $CorrelationId -Phase $phase `
                -Status Failed -Counts $counts | Out-Null
        }
        throw $failure
    }
}

function Get-InventoryDeletionCandidates {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $ExistingComponents,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $CollectedComponentIds,
        [Parameter(Mandatory)] [int] $ComponentType,
        [Parameter()] [AllowEmptyCollection()] [string[]] $IncludedEnvironmentIds
    )

    $collected = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($componentId in $CollectedComponentIds) {
        if (-not [string]::IsNullOrWhiteSpace($componentId)) {
            $null = $collected.Add($componentId)
        }
    }
    $includedEnvironments = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    if ($PSBoundParameters.ContainsKey('IncludedEnvironmentIds')) {
        foreach ($environmentId in $IncludedEnvironmentIds) {
            if (-not [string]::IsNullOrWhiteSpace($environmentId)) {
                $null = $includedEnvironments.Add($environmentId)
            }
        }
    }

    foreach ($existing in $ExistingComponents) {
        $typeProperty = $existing.PSObject.Properties['palp_typ']
        if ($null -ne $typeProperty -and [int] $typeProperty.Value -ne $ComponentType) {
            continue
        }
        $statusProperty = $existing.PSObject.Properties['palp_status']
        if ($null -ne $statusProperty -and [int] $statusProperty.Value -ne 0) {
            continue
        }
        $componentStatusProperty = $existing.PSObject.Properties['palp_komponentenstatus']
        if ($null -ne $componentStatusProperty -and [int] $componentStatusProperty.Value -eq 7) {
            continue
        }
        if ($PSBoundParameters.ContainsKey('IncludedEnvironmentIds')) {
            $environmentId = [string] $existing.palp_environment.palp_id
            if (-not $includedEnvironments.Contains($environmentId)) {
                continue
            }
        }
        $componentId = [string] $existing.palp_id
        if (-not [string]::IsNullOrWhiteSpace($componentId) -and -not $collected.Contains($componentId)) {
            $existing
        }
    }
}

function Get-MissingAgentCandidateIds {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Candidates,
        [Parameter()] [AllowEmptyCollection()] [string[]] $Subscriptions = @(),
        [Parameter(Mandatory)] [string] $AccessToken
    )

    foreach ($candidate in $Candidates) {
        $candidateId = [string] $candidate.palp_id
        $candidateLiteral = $candidateId.Replace('\', '\\').Replace('"', '\"')
        $query = @"
PowerPlatformResources
| where type =~ "microsoft.copilotstudio/agents"
| where tostring(name) =~ "$candidateLiteral" or tostring(id) =~ "$candidateLiteral"
| project agentId = tostring(name)
"@
        $matches = @(Invoke-ResourceGraphPagedQuery -Query $query `
            -Subscriptions $Subscriptions -AccessToken $AccessToken)
        if ($matches.Count -eq 0) {
            $candidateId
        }
    }
}

function New-InventoryDeletionWrites {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Candidates,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ConfirmedMissingIds,
        [Parameter(Mandatory)] [int] $ComponentType,
        [Parameter(Mandatory)] [datetimeoffset] $Now
    )

    $confirmedMissing = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($componentId in $ConfirmedMissingIds) {
        $null = $confirmedMissing.Add($componentId)
    }

    foreach ($candidate in $Candidates) {
        $componentId = [string] $candidate.palp_id
        if (-not $confirmedMissing.Contains($componentId)) {
            continue
        }
        $environmentId = ''
        $environmentProperty = $candidate.PSObject.Properties['palp_environment']
        if ($null -ne $environmentProperty -and $null -ne $environmentProperty.Value) {
            $environmentId = [string] $environmentProperty.Value.palp_id
        }
        $escapedComponentId = $componentId.Replace("'", "''")
        [pscustomobject] @{
            Method        = 'PATCH'
            RelativeUri   = "palp_komponentes(palp_id='$escapedComponentId')"
            Payload       = [pscustomobject] [ordered] @{
                palp_komponentenstatus     = 7
                palp_status                = 1
                palp_letztestatusaenderung = $Now.ToString('o')
            }
            EnvironmentId = $environmentId
            ComponentType = $ComponentType
            ComponentId   = $componentId
            Operation     = 'Delete'
        }
    }
}

function Invoke-InventoryDeletionCheck {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $ExistingComponents,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $CollectedComponentIds,
        [Parameter(Mandatory)] [int] $ComponentType,
        [Parameter(Mandatory)] [datetimeoffset] $Now,
        [Parameter(Mandatory)] [scriptblock] $VerificationAction,
        [Parameter(Mandatory)] [string] $DataverseUrl,
        [Parameter(Mandatory)] [string] $DataverseAccessToken,
        [Parameter()] [AllowEmptyCollection()] [string[]] $IncludedEnvironmentIds
    )

    $candidateParameters = @{
        ExistingComponents    = $ExistingComponents
        CollectedComponentIds = $CollectedComponentIds
        ComponentType         = $ComponentType
    }
    if ($PSBoundParameters.ContainsKey('IncludedEnvironmentIds')) {
        $candidateParameters.IncludedEnvironmentIds = $IncludedEnvironmentIds
    }
    $candidates = @(Get-InventoryDeletionCandidates @candidateParameters)
    $confirmedMissingIds = @(& $VerificationAction $candidates)
    $writes = @(New-InventoryDeletionWrites -Candidates $candidates `
        -ConfirmedMissingIds $confirmedMissingIds -ComponentType $ComponentType -Now $Now)
    $batch = Write-DataverseBatch -Writes $writes -DataverseUrl $DataverseUrl `
        -AccessToken $DataverseAccessToken

    [pscustomobject] @{
        Candidates = $candidates
        Batch      = $batch
    }
}

function Get-MissingRpaCandidateIds {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Candidates,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Environments,
        [Parameter(Mandatory)] [psobject] $Configuration
    )

    $environmentsById = @{}
    foreach ($environment in $Environments) {
        $environmentsById[[string] $environment.palp_id] = $environment
    }
    foreach ($candidate in $Candidates) {
        $environmentId = [string] $candidate.palp_environment.palp_id
        if (-not $environmentsById.ContainsKey($environmentId)) {
            throw "No successfully read environment '$environmentId' is available for targeted re-check."
        }
        $environment = $environmentsById[$environmentId]
        $accessToken = Get-InventoryAccessToken -Resource ([string] $environment.DataverseUrl) `
            -Configuration $Configuration
        $componentId = [string] $candidate.palp_id
        $query = 'workflows?$select=workflowid' +
            "&`$filter=category%20eq%206%20and%20workflowid%20eq%20$componentId" +
            '&$top=1'
        $matches = @(Get-DataversePagedRecords `
            -Uri "$($environment.DataverseUrl)/api/data/v9.2/$query" `
            -AccessToken $accessToken)
        if ($matches.Count -eq 0) {
            $componentId
        }
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
        -Subscriptions @($Configuration.AgentSubscriptions) -AccessToken $ResourceGraphAccessToken)
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
                    -Subscriptions @($Configuration.AgentSubscriptions) `
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
            $deletionLogs.Add([pscustomobject] [ordered] @{
                Severity        = 'Error'
                Category        = 'VerifyFailed'
                EnvironmentId   = ''
                EnvironmentName = ''
                ComponentType   = 4
                ComponentId     = ''
                Operation       = 'Delete'
                HttpStatus      = $details.HttpStatus
                ErrorCode       = $details.ErrorCode
                Message         = $_.Exception.Message
            })
        }

        $allFailures = @($batch.Failures) + @($deletionBatch.Failures)
        $writeFailureLogs = @(
            foreach ($failure in $allFailures) {
                [pscustomobject] [ordered] @{
                    Severity        = 'Error'
                    Category        = 'WriteFailed'
                    EnvironmentId   = [string] $failure.EnvironmentId
                    EnvironmentName = ''
                    ComponentType   = 4
                    ComponentId     = [string] $failure.ComponentId
                    Operation       = [string] $failure.Operation
                    HttpStatus      = [int] $failure.HttpStatus
                    ErrorCode       = [string] $failure.ErrorCode
                    Message         = [string] $failure.Message
                }
            }
        )
        $logs = @($environmentPlan.Logs) + @($collection.Logs) +
            $planLogs + $writeFailureLogs + $deletionLogs.ToArray()
        foreach ($log in $logs) {
            if ($loggingConfigured) {
                Write-InventorySyncLog -DataverseUrl $Configuration.TargetDataverseUrl `
                    -AccessToken $DataverseAccessToken -TableName ([string] $logTableProperty.Value) `
                    -SyncRunTableName ([string] $runTableProperty.Value) `
                    -RunRecordId $(if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }) `
                    -CorrelationId $CorrelationId -Severity $log.Severity -Category $log.Category `
                    -EnvironmentId ([string] $log.EnvironmentId) `
                    -EnvironmentName $(if ($null -ne $log.PSObject.Properties['EnvironmentName']) {
                        [string] $log.EnvironmentName
                    } else { '' }) `
                    -ComponentType 4 -ComponentId ([string] $log.ComponentId) `
                    -Operation ([string] $log.Operation) `
                    -HttpStatus $(if ($null -ne $log.PSObject.Properties['HttpStatus']) {
                        [int] $log.HttpStatus
                    } else { 0 }) `
                    -ErrorCode $(if ($null -ne $log.PSObject.Properties['ErrorCode']) {
                        [string] $log.ErrorCode
                    } else { '' }) `
                    -Message ([string] $log.Message) | Out-Null
            }
            else {
                Write-InventoryTrace -Level $log.Severity -Message $log.Message `
                    -CorrelationId $CorrelationId -Data @{
                        syncType      = 'RPA'
                        category      = $log.Category
                        environmentId = $log.EnvironmentId
                        componentId   = $log.ComponentId
                        operation     = $log.Operation
                    }
            }
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
        if ($loggingConfigured) {
            Write-InventorySyncLog -DataverseUrl $Configuration.TargetDataverseUrl `
                -AccessToken $DataverseAccessToken -TableName ([string] $logTableProperty.Value) `
                -SyncRunTableName ([string] $runTableProperty.Value) `
                -RunRecordId $(if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }) `
                -CorrelationId $CorrelationId -Severity Error `
                -Category $(if ($phase -eq 'Collect') { 'ReadFailed' } else { 'WriteFailed' }) `
                -ComponentType 4 -Operation $phase -HttpStatus $details.HttpStatus `
                -ErrorCode $details.ErrorCode -Message $failure.Exception.Message `
                -ErrorAction Continue | Out-Null
            if ($runHeader.Persisted) {
                Complete-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
                    -AccessToken $DataverseAccessToken -TableName ([string] $runTableProperty.Value) `
                    -RecordId $runHeader.RecordId -RunId $CorrelationId -Phase $phase `
                    -Status Failed -Counts $counts | Out-Null
            }
        }
        throw $failure
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

        foreach ($logEntry in $result.Logs) {
            $httpStatusProperty = $logEntry.PSObject.Properties['HttpStatus']
            $errorCodeProperty = $logEntry.PSObject.Properties['ErrorCode']
            $httpStatus = if ($null -ne $httpStatusProperty) {
                [int] $httpStatusProperty.Value
            }
            else {
                0
            }
            $errorCode = if ($null -ne $errorCodeProperty) {
                [string] $errorCodeProperty.Value
            }
            else {
                ''
            }
            if ($loggingConfigured) {
                Write-InventorySyncLog -DataverseUrl $Configuration.TargetDataverseUrl `
                    -AccessToken $DataverseAccessToken -TableName ([string] $syncLogTableProperty.Value) `
                    -SyncRunTableName ([string] $syncRunTableProperty.Value) `
                    -RunRecordId $(if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }) `
                    -CorrelationId $CorrelationId -Severity $logEntry.Severity `
                    -Category $logEntry.Category -EnvironmentId $logEntry.EnvironmentId `
                    -ComponentType $logEntry.ComponentType -ComponentId $logEntry.ComponentId `
                    -Operation $logEntry.Operation -HttpStatus $httpStatus `
                    -ErrorCode $errorCode -Message $logEntry.Message | Out-Null
            }
            else {
                Write-InventoryTrace -Level $logEntry.Severity -Message $logEntry.Message `
                    -CorrelationId $CorrelationId -Data @{
                        category      = $logEntry.Category
                        environmentId = $logEntry.EnvironmentId
                        componentType = $logEntry.ComponentType
                        componentId   = $logEntry.ComponentId
                        operation     = $logEntry.Operation
                        httpStatus    = $httpStatus
                        errorCode     = $errorCode
                    }
            }
        }

        foreach ($failure in $result.Batch.Failures) {
            if ($loggingConfigured) {
                Write-InventorySyncLog -DataverseUrl $Configuration.TargetDataverseUrl `
                    -AccessToken $DataverseAccessToken -TableName ([string] $syncLogTableProperty.Value) `
                    -SyncRunTableName ([string] $syncRunTableProperty.Value) `
                    -RunRecordId $(if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }) `
                    -CorrelationId $CorrelationId -Severity Error -Category WriteFailed `
                    -EnvironmentId $failure.EnvironmentId -ComponentType $failure.ComponentType `
                    -ComponentId $failure.ComponentId -Operation $failure.Operation `
                    -HttpStatus $failure.HttpStatus -ErrorCode $failure.ErrorCode `
                    -Message $failure.Message | Out-Null
            }
            else {
                Write-InventoryTrace -Level Error -Message $failure.Message `
                    -CorrelationId $CorrelationId -Data @{
                        category      = 'WriteFailed'
                        environmentId = $failure.EnvironmentId
                        componentType = $failure.ComponentType
                        componentId   = $failure.ComponentId
                        operation     = $failure.Operation
                        httpStatus    = $failure.HttpStatus
                        errorCode     = $failure.ErrorCode
                    } -ErrorAction Continue
            }
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
        if ($loggingConfigured) {
            Write-InventorySyncLog -DataverseUrl $Configuration.TargetDataverseUrl `
                -AccessToken $DataverseAccessToken -TableName ([string] $syncLogTableProperty.Value) `
                -SyncRunTableName ([string] $syncRunTableProperty.Value) `
                -RunRecordId $(if ($runHeader.Persisted) { $runHeader.RecordId } else { '' }) `
                -CorrelationId $CorrelationId -Severity Error -Category ReadFailed `
                -Operation Collect -HttpStatus $errorDetails.HttpStatus `
                -ErrorCode $errorDetails.ErrorCode -Message $failure.Exception.Message `
                -ErrorAction Continue | Out-Null
        }
        else {
            Write-InventoryTrace -Level Error -Message $failure.Exception.Message `
                -CorrelationId $CorrelationId -Data @{
                    category   = 'ReadFailed'
                    operation  = 'Collect'
                    httpStatus = $errorDetails.HttpStatus
                    errorCode  = $errorDetails.ErrorCode
                } -ErrorAction Continue
        }
        if ($loggingConfigured -and $runHeader.Persisted) {
            Complete-InventorySyncRun -DataverseUrl $Configuration.TargetDataverseUrl `
                -AccessToken $DataverseAccessToken -TableName ([string] $syncRunTableProperty.Value) `
                -RecordId $runHeader.RecordId -RunId $CorrelationId -Phase Collect `
                -Status Failed -Counts $counts | Out-Null
        }
        throw $failure
    }
}

function Write-InventoryTrace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Information', 'Warning', 'Error')] [string] $Level,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Message,
        [Parameter()] [AllowEmptyString()] [string] $CorrelationId,
        [Parameter()] [System.Collections.IDictionary] $Data = @{}
    )

    $record = [ordered]@{
        timestamp     = [datetimeoffset]::UtcNow.ToString('o')
        level         = $Level
        message       = $Message
        correlationId = $CorrelationId
        data          = $Data
    }
    $json = $record | ConvertTo-Json -Depth 20 -Compress

    switch ($Level) {
        'Information' { Write-Information -MessageData $json -Tags 'InventorySync' }
        'Warning' { Write-Warning -Message $json }
        'Error' { Write-Error -Message $json -ErrorId 'InventorySync' -Category NotSpecified }
    }
}

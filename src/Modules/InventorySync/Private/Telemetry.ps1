function Get-InventoryOperationId {
    [CmdletBinding()]
    param(
        [Parameter()] [AllowEmptyString()] [string] $Fallback
    )

    $activity = [System.Diagnostics.Activity]::Current
    if ($null -ne $activity) {
        $traceId = $activity.TraceId.ToString()
        if ($traceId -notmatch '^0+$') {
            return $traceId
        }
        if (-not [string]::IsNullOrWhiteSpace($activity.RootId)) {
            return [string] $activity.RootId
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($Fallback)) {
        return $Fallback
    }
    [guid]::NewGuid().ToString()
}

function ConvertTo-InventoryTraceJson {
    param(
        [Parameter(Mandatory)] [string] $Level,
        [Parameter(Mandatory)] [string] $Message,
        [Parameter()] [AllowEmptyString()] [string] $CorrelationId,
        [Parameter()] [System.Collections.IDictionary] $Data = @{}
    )

    [ordered] @{
        timestamp     = [datetimeoffset]::UtcNow.ToString('o')
        level         = $Level
        message       = $Message
        correlationId = $CorrelationId
        data          = $Data
    } | ConvertTo-Json -Depth 20 -Compress
}

function Write-InventoryTrace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('Information', 'Warning', 'Error')] [string] $Level,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string] $Message,
        [Parameter()] [AllowEmptyString()] [string] $CorrelationId,
        [Parameter()] [System.Collections.IDictionary] $Data = @{}
    )

    $json = ConvertTo-InventoryTraceJson -Level $Level -Message $Message `
        -CorrelationId $CorrelationId -Data $Data

    switch ($Level) {
        'Information' { Write-Information -MessageData $json -Tags 'InventorySync' }
        'Warning' { Write-Warning -Message $json }
        'Error' { Write-Error -Message $json -ErrorId 'InventorySync' -Category NotSpecified }
    }
}

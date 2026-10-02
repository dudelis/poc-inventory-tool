Set-StrictMode -Version Latest

$script:TokenCache = @{}
$script:TokenRefreshBuffer = [timespan]::FromMinutes(5)

$privateScripts = @(
    'Configuration.ps1'
    'Transport.ps1'
    'Agent.ps1'
    'Rpa.ps1'
    'Reconciliation.ps1'
    'Logging.ps1'
    'Deletion.ps1'
    'Telemetry.ps1'
    'Functions.ps1'
)
foreach ($privateScript in $privateScripts) {
    . (Join-Path $PSScriptRoot 'Private' $privateScript)
}

Import-Module AzureFunctions.PowerShell.Durable.SDK -RequiredVersion 2.4.0 -ErrorAction Stop
$modulePath = Join-Path $PSScriptRoot 'Modules\InventorySync\InventorySync.psd1'
Import-Module $modulePath -Force

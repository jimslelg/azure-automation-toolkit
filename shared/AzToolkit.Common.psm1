# AzToolkit.Common root module.
# Public functions live in the four feature folders; internal helpers in private/.
# Export list is duplicated in AzToolkit.Common.psd1 (FunctionsToExport) by design:
# explicit lists keep the public API auditable and module auto-loading fast.

foreach ($folder in @('logging', 'authentication', 'helpers', 'configuration', 'private')) {
    foreach ($file in Get-ChildItem -Path (Join-Path $PSScriptRoot $folder) -Filter '*.ps1' -ErrorAction SilentlyContinue) {
        . $file.FullName
    }
}

# Module-scoped logging context, populated by Initialize-ToolkitLog and read by
# Write-ToolkitLog / Get-ToolkitCorrelationId.
$script:LogContext = $null

Export-ModuleMember -Function @(
    # logging
    'Initialize-ToolkitLog'
    'Write-ToolkitLog'
    'Get-ToolkitCorrelationId'
    # authentication
    'Connect-ToolkitAzure'
    'Test-ToolkitAzureConnection'
    # helpers
    'Invoke-WithRetry'
    'Test-RetryableError'
    'Export-ToolkitCsv'
    'Export-ToolkitJson'
    'Get-ToolkitOutputPath'
    # configuration
    'Get-ToolkitConfig'
)

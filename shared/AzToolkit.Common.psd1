@{
    RootModule        = 'AzToolkit.Common.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = 'e476600a-6500-49c7-b06f-965f8545877f'
    Author            = 'Jim Eligio'
    CompanyName       = 'azure-automation-toolkit'
    Copyright         = '(c) 2026 Jim Eligio. MIT License.'
    Description       = 'Shared authentication, logging, retry, configuration, and export helpers for the azure-automation-toolkit scripts and runbooks.'
    PowerShellVersion = '7.0'

    # Az.Accounts is intentionally NOT listed in RequiredModules: the module must
    # import on CI runners without Az installed (unit tests stub the Az cmdlets).
    # Az cmdlets are late-bound — they resolve when Connect-ToolkitAzure runs.
    # Az.Accounts 2.x+ is required at runtime for authentication functions.

    FunctionsToExport = @(
        'Initialize-ToolkitLog'
        'Write-ToolkitLog'
        'Get-ToolkitCorrelationId'
        'Connect-ToolkitAzure'
        'Test-ToolkitAzureConnection'
        'Invoke-WithRetry'
        'Test-RetryableError'
        'Export-ToolkitCsv'
        'Export-ToolkitJson'
        'Get-ToolkitOutputPath'
        'Get-ToolkitConfig'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData       = @{
        PSData = @{
            Tags                       = @('Azure', 'Automation', 'DevOps', 'Operations', 'Logging', 'Retry')
            LicenseUri                 = 'https://github.com/jimslelg/azure-automation-toolkit/blob/main/LICENSE'
            ProjectUri                 = 'https://github.com/jimslelg/azure-automation-toolkit'
            ExternalModuleDependencies = @('Az.Accounts')
        }
    }
}

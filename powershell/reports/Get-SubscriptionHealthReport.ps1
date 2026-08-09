#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources, Az.ResourceGraph

<#
.SYNOPSIS
    Produces a composite health snapshot of a subscription as one finding per check.
.DESCRIPTION
    Runs a set of read-only checks and emits one finding object per check (checkName,
    status Ok/Warning/Critical, detail): registration state of commonly-used resource
    providers (Microsoft.Compute/Network/Storage/KeyVault/Sql), resource groups
    approaching the per-group resource limit (more than 900 resources), presence of
    classic (ASM) resources, regional spread (distinct locations in use), and the
    total resource count. Uses Az.Resources for providers and Azure Resource Graph
    for the rest. Findings can be exported with -ExportPath.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ExportPath
    Optional directory to export findings to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Get-SubscriptionHealthReport.ps1

    Emits one finding object per health check for the current subscription.
.EXAMPLE
    ./Get-SubscriptionHealthReport.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 -ExportPath ./output

    Checks the given subscription and exports the findings as CSV.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Reader on the target scope.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure
                (some checks failed), 4 invalid parameters/configuration.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ExportPath,

    [Parameter()]
    [ValidateSet('Csv', 'Json')]
    [string]$ExportFormat = 'Csv'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'AzToolkit.Common.psd1') -Force

$exitCode = 0
try {
    $null = Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name
    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    $checks = @(
        @{
            Name   = 'ProviderRegistration'
            Script = {
                $namespaces = @('Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.KeyVault', 'Microsoft.Sql')
                $providers = @(Invoke-WithRetry -OperationName 'List resource providers' -ScriptBlock {
                        Get-AzResourceProvider -ListAvailable
                    })
                $problem = @($providers | Where-Object {
                        $_.ProviderNamespace -in $namespaces -and $_.RegistrationState -in @('Registering', 'NotRegistered')
                    })
                if ($problem.Count -gt 0) {
                    $list = ($problem | ForEach-Object { "$($_.ProviderNamespace)=$($_.RegistrationState)" }) -join ', '
                    @{ Status = 'Warning'; Detail = "Providers not fully registered: $list" }
                }
                else {
                    @{ Status = 'Ok'; Detail = 'All commonly-used resource providers are registered' }
                }
            }
        }
        @{
            Name   = 'ResourceGroupCapacity'
            Script = {
                $query = 'resources | summarize resourceCount = count() by resourceGroup | where resourceCount > 900 | order by resourceCount desc'
                $rows = @(Invoke-WithRetry -OperationName 'Query crowded resource groups' -ScriptBlock {
                        Search-AzGraph -Query $query -First 1000
                    })
                if ($rows.Count -gt 0) {
                    $list = ($rows | ForEach-Object { "$($_.resourceGroup)=$($_.resourceCount)" }) -join ', '
                    @{ Status = 'Critical'; Detail = "Resource group(s) near the per-group resource limit: $list" }
                }
                else {
                    @{ Status = 'Ok'; Detail = 'No resource group holds more than 900 resources' }
                }
            }
        }
        @{
            Name   = 'ClassicResources'
            Script = {
                $query = "resources | where type startswith 'microsoft.classic' | summarize classicCount = count()"
                $rows = @(Invoke-WithRetry -OperationName 'Query classic resources' -ScriptBlock {
                        Search-AzGraph -Query $query -First 1000
                    })
                $classicCount = if ($rows.Count -gt 0) { [int]$rows[0].classicCount } else { 0 }
                if ($classicCount -gt 0) {
                    @{ Status = 'Warning'; Detail = "$classicCount classic (ASM) resource(s) present - migrate before ASM retirement" }
                }
                else {
                    @{ Status = 'Ok'; Detail = 'No classic (ASM) resources found' }
                }
            }
        }
        @{
            Name   = 'RegionalSpread'
            Script = {
                $query = 'resources | summarize locationCount = dcount(location)'
                $rows = @(Invoke-WithRetry -OperationName 'Query regional spread' -ScriptBlock {
                        Search-AzGraph -Query $query -First 1000
                    })
                $locationCount = if ($rows.Count -gt 0) { [int]$rows[0].locationCount } else { 0 }
                if ($locationCount -gt 10) {
                    @{ Status = 'Warning'; Detail = "Resources span $locationCount distinct locations - review for sprawl" }
                }
                else {
                    @{ Status = 'Ok'; Detail = "Resources span $locationCount distinct location(s)" }
                }
            }
        }
        @{
            Name   = 'TotalResourceCount'
            Script = {
                $query = 'resources | summarize totalCount = count()'
                $rows = @(Invoke-WithRetry -OperationName 'Query total resource count' -ScriptBlock {
                        Search-AzGraph -Query $query -First 1000
                    })
                $totalCount = if ($rows.Count -gt 0) { [int]$rows[0].totalCount } else { 0 }
                @{ Status = 'Ok'; Detail = "$totalCount resource(s) in the subscription" }
            }
        }
    )

    $findings = [System.Collections.Generic.List[pscustomobject]]::new()
    $failures = 0

    foreach ($check in $checks) {
        try {
            $outcome = & $check.Script
            Write-ToolkitLog -Message 'Health check completed' -Data @{
                check  = $check.Name
                status = $outcome.Status
            }
            $findings.Add([pscustomobject]@{
                    CheckName = $check.Name
                    Status    = $outcome.Status
                    Detail    = $outcome.Detail
                })
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Health check '$($check.Name)' failed" -ErrorRecord $_
            $findings.Add([pscustomobject]@{
                    CheckName = $check.Name
                    Status    = 'Critical'
                    Detail    = "Check failed: $($_.Exception.Message)"
                })
        }
    }

    if ($failures -gt 0 -and $failures -lt $checks.Count) { $exitCode = 3 }
    elseif ($failures -gt 0) { throw "All $failures health checks failed." }

    $findings

    if ($ExportPath -and $findings.Count -gt 0) {
        $exportParams = @{ InputObject = $findings; Name = 'subscription-health-report'; OutputDirectory = $ExportPath }
        $null = if ($ExportFormat -eq 'Csv') { Export-ToolkitCsv @exportParams } else { Export-ToolkitJson @exportParams }
    }
}
catch {
    $exitCode = switch -Wildcard ($_.FullyQualifiedErrorId) {
        'AzToolkit.AuthenticationFailed*' { 2 }
        'AzToolkit.ConfigurationInvalid*' { 4 }
        default { 1 }
    }
    Write-ToolkitLog -Level Error -Message "Unhandled failure: $($_.Exception.Message)" -ErrorRecord $_
    Write-Error -ErrorRecord $_ -ErrorAction Continue
}
finally {
    Write-ToolkitLog -Message "Completed with exit code $exitCode"
}
exit $exitCode

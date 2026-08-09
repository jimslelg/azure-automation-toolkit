#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Sql

<#
.SYNOPSIS
    Checks the backup health of every Azure SQL database: PITR window, STR days, LTR policy.
.DESCRIPTION
    For every user database on every SQL server in scope (master is skipped), reports the
    earliest restore date, how many days of point-in-time restore (PITR) window that
    represents, the short-term retention policy in days, and whether a long-term
    retention (LTR) policy is configured. Databases without a restore point are flagged
    NoRestorePoint; databases whose PITR window is shorter than -MinimumPitrDays are
    flagged LimitedPitrWindow. Read-only; results can be exported with -ExportPath.
    Exits 3 when some databases could not be evaluated.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Optional resource group to limit the scan; the whole subscription otherwise.
.PARAMETER MinimumPitrDays
    Minimum days of PITR window required for a database to count as Ok (default 1).
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Test-SqlBackupStatus.ps1 -MinimumPitrDays 2

    Reports backup health subscription-wide, requiring at least two days of PITR window.
.EXAMPLE
    ./Test-SqlBackupStatus.ps1 -ResourceGroupName rg-data-prod -ExportPath ./output

    Checks one resource group and exports the findings as CSV.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Reader on the target scope.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure
                (some databases could not be evaluated), 4 invalid parameters/configuration.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ResourceGroupName,

    [Parameter()]
    [ValidateRange(1, 35)]
    [int]$MinimumPitrDays = 1,

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

    $getServerParams = @{}
    if ($ResourceGroupName) {
        $getServerParams.ResourceGroupName = $ResourceGroupName
    }
    $servers = @(Invoke-WithRetry -OperationName 'List SQL servers' -ScriptBlock { Get-AzSqlServer @getServerParams })

    if ($servers.Count -eq 0) {
        Write-ToolkitLog -Level Warning -Message 'No SQL servers matched the selection criteria'
    }
    Write-ToolkitLog -Message "Checking backup status across $($servers.Count) SQL server(s)"

    $now = [datetime]::UtcNow
    $failures = 0
    $databaseCount = 0
    $report = foreach ($server in $servers) {
        try {
            $databases = @(Invoke-WithRetry -OperationName "List databases on $($server.ServerName)" -ScriptBlock {
                    Get-AzSqlDatabase -ServerName $server.ServerName -ResourceGroupName $server.ResourceGroupName
                } | Where-Object DatabaseName -NE 'master')
        }
        catch {
            $failures++
            $databaseCount++
            Write-ToolkitLog -Level Error -Message "Failed to list databases on '$($server.ServerName)'" -ErrorRecord $_
            continue
        }

        foreach ($database in $databases) {
            $databaseCount++
            try {
                $shortTermPolicy = Invoke-WithRetry -OperationName "STR policy for $($database.DatabaseName)" -ScriptBlock {
                    Get-AzSqlDatabaseBackupShortTermRetentionPolicy -ResourceGroupName $server.ResourceGroupName `
                        -ServerName $server.ServerName -DatabaseName $database.DatabaseName
                }
                $longTermPolicy = Invoke-WithRetry -OperationName "LTR policy for $($database.DatabaseName)" -ScriptBlock {
                    Get-AzSqlDatabaseBackupLongTermRetentionPolicy -ResourceGroupName $server.ResourceGroupName `
                        -ServerName $server.ServerName -DatabaseName $database.DatabaseName
                }
                $ltrConfigured = @($longTermPolicy.WeeklyRetention, $longTermPolicy.MonthlyRetention, $longTermPolicy.YearlyRetention |
                        Where-Object { $_ -and $_ -ne 'PT0S' }).Count -gt 0

                $daysOfPitrAvailable = $null
                if ($null -eq $database.EarliestRestoreDate) {
                    $status = 'NoRestorePoint'
                }
                else {
                    $daysOfPitrAvailable = [Math]::Round(($now - $database.EarliestRestoreDate.ToUniversalTime()).TotalDays, 1)
                    $status = if ($daysOfPitrAvailable -ge $MinimumPitrDays) { 'Ok' } else { 'LimitedPitrWindow' }
                }

                [pscustomobject]@{
                    ServerName             = $server.ServerName
                    ResourceGroupName      = $server.ResourceGroupName
                    DatabaseName           = $database.DatabaseName
                    EarliestRestoreDate    = $database.EarliestRestoreDate
                    DaysOfPitrAvailable    = $daysOfPitrAvailable
                    ShortTermRetentionDays = $shortTermPolicy.RetentionDays
                    LtrConfigured          = $ltrConfigured
                    Status                 = $status
                }
            }
            catch {
                $failures++
                Write-ToolkitLog -Level Error -Message "Failed to evaluate database '$($database.DatabaseName)' on '$($server.ServerName)'" -ErrorRecord $_
            }
        }
    }

    $report = @($report)
    if ($failures -gt 0 -and $failures -lt $databaseCount) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $databaseCount -gt 0) { throw "Backup evaluation failed for all $failures item(s)." }

    Write-ToolkitLog -Message "$($report.Count) database(s) evaluated for backup health"
    $report

    if ($ExportPath -and $report.Count -gt 0) {
        $exportParams = @{ InputObject = $report; Name = 'sql-backup-status'; OutputDirectory = $ExportPath }
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

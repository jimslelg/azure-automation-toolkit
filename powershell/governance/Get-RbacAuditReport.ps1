#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources

<#
.SYNOPSIS
    Audits subscription role assignments for privileged, orphaned, and guest access.
.DESCRIPTION
    Reads every role assignment visible at the subscription scope and flags findings:
    Owner or User Access Administrator assignments (High severity for users, Medium
    otherwise), assignments whose principal no longer exists (ObjectType 'Unknown' -
    orphaned, High), and guest users identified by '#EXT#' in the sign-in name
    (Medium). Each finding row includes the scope level (Subscription, ResourceGroup,
    Resource, or ManagementGroup). Read-only and exportable with -ExportPath.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Get-RbacAuditReport.ps1

    Emits one object per RBAC finding for the current subscription.
.EXAMPLE
    ./Get-RbacAuditReport.ps1 -SubscriptionId 00000000-0000-0000-0000-000000000000 `
        -ExportPath ./output -ExportFormat Json

    Audits a specific subscription and exports the findings as JSON.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Reader (plus Microsoft Entra read access for principal resolution).
    Exit codes: 0 success, 1 general failure, 2 auth failure,
                4 invalid parameters/configuration.
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

$privilegedRoles = @('Owner', 'User Access Administrator')

$exitCode = 0
try {
    $null = Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name
    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    $assignments = @(Invoke-WithRetry -OperationName 'List role assignments' -ScriptBlock {
            Get-AzRoleAssignment
        })
    Write-ToolkitLog -Message "Evaluating $($assignments.Count) role assignment(s)"

    $findings = foreach ($assignment in $assignments) {
        $segments = @(($assignment.Scope).Trim('/') -split '/' | Where-Object { $_ })
        $scopeLevel = if ($assignment.Scope -match '^/providers/Microsoft\.Management/') { 'ManagementGroup' }
        elseif ($segments.Count -le 2) { 'Subscription' }
        elseif ($segments.Count -eq 4) { 'ResourceGroup' }
        else { 'Resource' }

        $flags = [System.Collections.Generic.List[pscustomobject]]::new()
        if ($assignment.RoleDefinitionName -in $privilegedRoles) {
            $severity = if ($assignment.ObjectType -eq 'User') { 'High' } else { 'Medium' }
            $flags.Add([pscustomobject]@{
                    Finding  = 'PrivilegedRole'
                    Severity = $severity
                    Detail   = "$($assignment.RoleDefinitionName) assigned to $($assignment.ObjectType)"
                })
        }
        if ($assignment.ObjectType -eq 'Unknown') {
            $flags.Add([pscustomobject]@{
                    Finding  = 'OrphanedAssignment'
                    Severity = 'High'
                    Detail   = 'Principal no longer exists; assignment should be removed'
                })
        }
        if ($assignment.SignInName -like '*#EXT#*') {
            $flags.Add([pscustomobject]@{
                    Finding  = 'GuestUser'
                    Severity = 'Medium'
                    Detail   = 'External (guest) user holds a role assignment'
                })
        }

        foreach ($flag in $flags) {
            [pscustomobject]@{
                PrincipalName      = $assignment.DisplayName
                SignInName         = $assignment.SignInName
                ObjectId           = $assignment.ObjectId
                ObjectType         = $assignment.ObjectType
                RoleDefinitionName = $assignment.RoleDefinitionName
                Scope              = $assignment.Scope
                ScopeLevel         = $scopeLevel
                Finding            = $flag.Finding
                Severity           = $flag.Severity
                Detail             = $flag.Detail
            }
        }
    }

    $findings = @($findings)
    $highCount = @($findings | Where-Object { $_.Severity -eq 'High' }).Count
    Write-ToolkitLog -Message "$($findings.Count) RBAC finding(s) ($highCount high severity)" -Data @{
        assignments = $assignments.Count
        findings    = $findings.Count
        high        = $highCount
    }

    $findings

    if ($ExportPath -and $findings.Count -gt 0) {
        $exportParams = @{ InputObject = $findings; Name = 'rbac-audit-report'; OutputDirectory = $ExportPath }
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

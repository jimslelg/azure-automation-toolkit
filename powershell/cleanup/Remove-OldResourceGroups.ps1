#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources

<#
.SYNOPSIS
    Deletes temporary resource groups that match a name pattern AND a lifecycle tag.
.DESCRIPTION
    Deliberately narrow, defense-in-depth deletion of throwaway resource groups. A
    resource group is only a candidate when ALL of these hold: its name matches the
    mandatory -NamePattern wildcard, it carries the -RequiredTagName tag with exactly
    the -RequiredTagValue value, and it contains no resources (unless -IncludeNonEmpty
    is passed). ConfirmImpact is High, so each deletion prompts unless -Confirm:$false
    or -Force-style automation is intended. Emits one result object per candidate.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER NamePattern
    Mandatory wildcard pattern the resource group name must match (e.g. 'rg-tmp-*').
    Deliberately has no default: you must state what you intend to delete.
.PARAMETER RequiredTagName
    Tag name the resource group must carry to qualify (default 'Lifecycle').
.PARAMETER RequiredTagValue
    Tag value that must match exactly (default 'temporary').
.PARAMETER IncludeNonEmpty
    Also delete resource groups that still contain resources. Off by default:
    non-empty groups are reported as Skipped instead.
.EXAMPLE
    ./Remove-OldResourceGroups.ps1 -NamePattern 'rg-tmp-*' -WhatIf

    Previews which empty, tagged temporary resource groups would be deleted.
.EXAMPLE
    ./Remove-OldResourceGroups.ps1 -NamePattern 'rg-sandbox-*' -RequiredTagName Lifecycle -RequiredTagValue temporary -IncludeNonEmpty

    Deletes matching sandbox groups even when they still contain resources,
    prompting per group (ConfirmImpact High).
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Contributor on the subscription (resource group delete rights).
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure,
                4 invalid parameters/configuration.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$NamePattern,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RequiredTagName = 'Lifecycle',

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$RequiredTagValue = 'temporary',

    [Parameter()]
    [switch]$IncludeNonEmpty
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'AzToolkit.Common.psd1') -Force

$exitCode = 0
try {
    $null = Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name
    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    $allGroups = @(Invoke-WithRetry -OperationName 'List resource groups' -ScriptBlock { Get-AzResourceGroup })

    # Gate 1 + 2: name pattern AND required lifecycle tag with the exact value.
    $candidates = @($allGroups | Where-Object {
            $_.ResourceGroupName -like $NamePattern -and
            $_.Tags -and
            $_.Tags.ContainsKey($RequiredTagName) -and
            $_.Tags[$RequiredTagName] -eq $RequiredTagValue
        })

    Write-ToolkitLog -Message "$($candidates.Count) resource group(s) match pattern and tag gate" -Data @{
        namePattern = $NamePattern
        tagName     = $RequiredTagName
        tagValue    = $RequiredTagValue
    }
    if ($candidates.Count -eq 0) {
        Write-ToolkitLog -Level Warning -Message "No resource groups matched '$NamePattern' with tag $RequiredTagName=$RequiredTagValue"
    }

    $failures = 0
    $results = foreach ($group in $candidates) {
        $status = $null
        $reason = $null

        $resources = @(Invoke-WithRetry -OperationName "List resources in $($group.ResourceGroupName)" -ScriptBlock {
                Get-AzResource -ResourceGroupName $group.ResourceGroupName
            })

        # Gate 3: must be empty unless the caller explicitly opted in.
        if ($resources.Count -gt 0 -and -not $IncludeNonEmpty) {
            Write-ToolkitLog -Message "Skipping '$($group.ResourceGroupName)' - not empty" -Data @{ resourceCount = $resources.Count }
            $status = 'Skipped'
            $reason = "Contains $($resources.Count) resource(s); pass -IncludeNonEmpty to delete anyway"
        }
        elseif (-not $PSCmdlet.ShouldProcess($group.ResourceGroupName, "Remove resource group and its $($resources.Count) resource(s) PERMANENTLY")) {
            $status = 'Skipped'
            $reason = 'Confirmation declined or -WhatIf'
        }
        else {
            try {
                Write-ToolkitLog -Message 'Deleting resource group' -Data @{
                    resourceGroup = $group.ResourceGroupName
                    location      = $group.Location
                    resourceCount = $resources.Count
                }
                $null = Invoke-WithRetry -OperationName "Remove resource group $($group.ResourceGroupName)" -ScriptBlock {
                    Remove-AzResourceGroup -Name $group.ResourceGroupName -Force
                }
                $status = 'Deleted'
            }
            catch {
                $failures++
                Write-ToolkitLog -Level Error -Message "Failed to delete resource group '$($group.ResourceGroupName)'" -ErrorRecord $_
                $status = 'Failed'
                $reason = $_.Exception.Message
            }
        }

        [pscustomobject]@{
            Name          = $group.ResourceGroupName
            Location      = $group.Location
            ResourceCount = $resources.Count
            TagValue      = $group.Tags[$RequiredTagName]
            Status        = $status
            Reason        = $reason
        }
    }

    if ($failures -gt 0 -and $failures -lt $candidates.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $candidates.Count -gt 0) { throw "All $failures resource group deletion(s) failed." }

    $results
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

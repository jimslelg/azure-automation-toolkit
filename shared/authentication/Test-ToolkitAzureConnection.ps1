function Test-ToolkitAzureConnection {
    <#
    .SYNOPSIS
        Tests whether a usable Azure connection exists.
    .DESCRIPTION
        Returns $true when an Az context with an authenticated account is present —
        and, if -SubscriptionId is given, when the context points at that subscription.
        Never throws; intended for guard clauses and pre-flight checks.
    .PARAMETER SubscriptionId
        When supplied, the current context must be on this subscription.
    .EXAMPLE
        if (-not (Test-ToolkitAzureConnection)) { Connect-ToolkitAzure }
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [string]$SubscriptionId
    )

    try {
        $context = Get-AzContext -ErrorAction SilentlyContinue
        if (-not $context -or -not $context.Account) {
            return $false
        }
        if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
            return $false
        }
        return $true
    }
    catch {
        return $false
    }
}

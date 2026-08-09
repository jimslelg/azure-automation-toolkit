#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Network

<#
.SYNOPSIS
    Exports a network inventory: VNet details plus per-resource-group NIC/PIP/NSG counts.
.DESCRIPTION
    Collects every virtual network in scope (address space, subnet count, peering
    count, DNS servers) and builds a per-resource-group summary of network interface,
    public IP, and network security group counts. Emits both row sets to the pipeline
    and always writes timestamped inventory files to -OutputDirectory. Read-only; the
    typical input to network reviews and CMDB loads.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER OutputDirectory
    Directory for the inventory files (created if missing). Defaults to ./output.
.PARAMETER ExportFormat
    Csv (default) or Json.
.EXAMPLE
    ./Export-NetworkInventory.ps1

    Writes ./output/network-vnet-inventory_<timestamp>.csv and
    ./output/network-rg-summary_<timestamp>.csv for the current subscription.
.EXAMPLE
    ./Export-NetworkInventory.ps1 -OutputDirectory ./reports -ExportFormat Json

    JSON network inventory written to ./reports.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Reader on the target scope.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure,
                4 invalid parameters/configuration.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory = './output',

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

    $vnets = @(Invoke-WithRetry -OperationName 'List virtual networks' -ScriptBlock { Get-AzVirtualNetwork })
    $nics = @(Invoke-WithRetry -OperationName 'List network interfaces' -ScriptBlock { Get-AzNetworkInterface })
    $publicIps = @(Invoke-WithRetry -OperationName 'List public IP addresses' -ScriptBlock { Get-AzPublicIpAddress })
    $nsgs = @(Invoke-WithRetry -OperationName 'List network security groups' -ScriptBlock { Get-AzNetworkSecurityGroup })
    Write-ToolkitLog -Message 'Network resources collected' -Data @{
        vnets     = $vnets.Count
        nics      = $nics.Count
        publicIps = $publicIps.Count
        nsgs      = $nsgs.Count
    }

    $failures = 0
    $vnetInventory = foreach ($vnet in $vnets) {
        try {
            [pscustomobject]@{
                Name              = $vnet.Name
                ResourceGroupName = $vnet.ResourceGroupName
                Location          = $vnet.Location
                AddressSpace      = (@($vnet.AddressSpace.AddressPrefixes) -join ';')
                SubnetCount       = @($vnet.Subnets).Count
                PeeringCount      = @($vnet.VirtualNetworkPeerings).Count
                DnsServers        = if (@($vnet.DhcpOptions.DnsServers).Count -gt 0) { @($vnet.DhcpOptions.DnsServers) -join ';' } else { 'AzureProvided' }
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed processing VNet '$($vnet.Name)'" -ErrorRecord $_
        }
    }
    $vnetInventory = @($vnetInventory)

    $resourceGroups = @(@($nics.ResourceGroupName) + @($publicIps.ResourceGroupName) + @($nsgs.ResourceGroupName) |
            Where-Object { $_ } |
            Sort-Object -Unique)
    $rgSummary = foreach ($rg in $resourceGroups) {
        [pscustomobject]@{
            ResourceGroupName = $rg
            NicCount          = @($nics | Where-Object ResourceGroupName -EQ $rg).Count
            PublicIpCount     = @($publicIps | Where-Object ResourceGroupName -EQ $rg).Count
            NsgCount          = @($nsgs | Where-Object ResourceGroupName -EQ $rg).Count
        }
    }
    $rgSummary = @($rgSummary)

    if ($failures -gt 0 -and $failures -lt $vnets.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $vnets.Count -gt 0) { throw "All $failures VNet(s) failed processing." }

    $vnetInventory
    $rgSummary

    if ($vnetInventory.Count -gt 0) {
        $exportParams = @{ InputObject = $vnetInventory; Name = 'network-vnet-inventory'; OutputDirectory = $OutputDirectory }
        $null = if ($ExportFormat -eq 'Csv') { Export-ToolkitCsv @exportParams } else { Export-ToolkitJson @exportParams }
    }
    else {
        Write-ToolkitLog -Level Warning -Message 'No virtual networks found in scope; VNet inventory not exported'
    }

    if ($rgSummary.Count -gt 0) {
        $exportParams = @{ InputObject = $rgSummary; Name = 'network-rg-summary'; OutputDirectory = $OutputDirectory }
        $null = if ($ExportFormat -eq 'Csv') { Export-ToolkitCsv @exportParams } else { Export-ToolkitJson @exportParams }
    }
    else {
        Write-ToolkitLog -Level Warning -Message 'No NICs, public IPs, or NSGs found in scope; summary not exported'
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

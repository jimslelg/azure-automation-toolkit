#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Compute

<#
.SYNOPSIS
    Exports a full VM inventory (size, OS, power state, disks, tags) to CSV or JSON.
.DESCRIPTION
    Collects every VM in scope with its instance view, flattens the useful operational
    properties (power state, size, OS, disk layout, availability zone, tags), emits the
    objects to the pipeline, and writes a timestamped inventory file. Read-only; the
    typical input to capacity reviews, CMDB loads, and patching waves.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Optional resource group to limit the inventory; the whole subscription otherwise.
.PARAMETER OutputDirectory
    Directory for the inventory file (created if missing). Defaults to ./output.
.PARAMETER ExportFormat
    Csv (default) or Json.
.EXAMPLE
    ./Export-VmInventory.ps1

    Writes ./output/vm-inventory_<timestamp>.csv for the current subscription.
.EXAMPLE
    ./Export-VmInventory.ps1 -ResourceGroupName rg-app-prod -ExportFormat Json

    JSON inventory for one resource group.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Reader on the target scope.
    Exit codes: 0 success, 1 general failure, 2 auth failure,
                4 invalid parameters/configuration.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ResourceGroupName,

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

    $getVmParams = @{ Status = $true }
    if ($ResourceGroupName) {
        $getVmParams.ResourceGroupName = $ResourceGroupName
    }
    $vms = @(Invoke-WithRetry -OperationName 'List VMs' -ScriptBlock { Get-AzVM @getVmParams })
    Write-ToolkitLog -Message "Building inventory for $($vms.Count) VM(s)"

    $inventory = foreach ($vm in $vms) {
        [pscustomobject]@{
            Name              = $vm.Name
            ResourceGroupName = $vm.ResourceGroupName
            Location          = $vm.Location
            Zone              = $vm.Zones -join ','
            PowerState        = $vm.PowerState
            VmSize            = $vm.HardwareProfile.VmSize
            OsType            = $vm.StorageProfile.OsDisk.OsType
            OsDiskSizeGb      = $vm.StorageProfile.OsDisk.DiskSizeGB
            DataDiskCount     = $vm.StorageProfile.DataDisks.Count
            ImagePublisher    = $vm.StorageProfile.ImageReference.Publisher
            ImageSku          = $vm.StorageProfile.ImageReference.Sku
            LicenseType       = $vm.LicenseType
            Tags              = ($vm.Tags.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'
            VmId              = $vm.VmId
        }
    }

    $inventory = @($inventory)
    $inventory

    if ($inventory.Count -gt 0) {
        $exportParams = @{ InputObject = $inventory; Name = 'vm-inventory'; OutputDirectory = $OutputDirectory }
        $null = if ($ExportFormat -eq 'Csv') { Export-ToolkitCsv @exportParams } else { Export-ToolkitJson @exportParams }
    }
    else {
        Write-ToolkitLog -Level Warning -Message 'No VMs found in scope; nothing exported'
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

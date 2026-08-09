#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Compute

<#
.SYNOPSIS
    Resizes an Azure VM after validating the target size is available.
.DESCRIPTION
    Checks the requested size against Get-AzVMSize for the VM (which reflects what the
    current hardware cluster can host) before applying it with Update-AzVM. Resizing
    reboots the VM; a deallocated VM is resized without a reboot but may land on
    different hardware. Supports -WhatIf and emits a before/after result object.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Resource group containing the VM.
.PARAMETER Name
    Name of the VM to resize.
.PARAMETER NewSize
    Target VM size, e.g. Standard_D4s_v5.
.EXAMPLE
    ./Set-VmSize.ps1 -ResourceGroupName rg-app-prod -Name web-01 -NewSize Standard_D4s_v5 -WhatIf

    Validates availability and shows what would change without resizing.
.EXAMPLE
    ./Set-VmSize.ps1 -ResourceGroupName rg-app-prod -Name web-01 -NewSize Standard_D8s_v5

    Resizes the VM (reboots it if running).
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Virtual Machine Contributor on the target scope.
    Exit codes: 0 success, 1 general failure, 2 auth failure,
                4 invalid parameters/configuration (size unavailable).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Name,

    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9_]+$')]
    [string]$NewSize
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'AzToolkit.Common.psd1') -Force

$exitCode = 0
try {
    $null = Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name
    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    $vm = Invoke-WithRetry -OperationName "Get VM $Name" -ScriptBlock {
        Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name
    }
    $currentSize = $vm.HardwareProfile.VmSize

    if ($currentSize -eq $NewSize) {
        Write-ToolkitLog -Level Warning -Message "VM '$Name' is already size $NewSize; nothing to do"
        [pscustomobject]@{
            Name              = $Name
            ResourceGroupName = $ResourceGroupName
            PreviousSize      = $currentSize
            NewSize           = $NewSize
            Status            = 'NoChange'
        }
    }
    else {
        $availableSizes = Invoke-WithRetry -OperationName 'List available sizes' -ScriptBlock {
            Get-AzVMSize -ResourceGroupName $ResourceGroupName -VMName $Name
        }
        if ($NewSize -notin $availableSizes.Name) {
            $exitCode = 4
            throw "Size '$NewSize' is not available for VM '$Name' on its current cluster. " +
            "Deallocate the VM first or pick one of: $($availableSizes.Name -join ', ')"
        }

        if ($PSCmdlet.ShouldProcess($Name, "Resize VM from $currentSize to $NewSize (reboots a running VM)")) {
            Write-ToolkitLog -Message 'Resizing VM' -Data @{
                vm       = $Name
                fromSize = $currentSize
                toSize   = $NewSize
            }
            $vm.HardwareProfile.VmSize = $NewSize
            $null = Invoke-WithRetry -OperationName "Resize $Name" -ScriptBlock {
                Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vm
            }
            [pscustomobject]@{
                Name              = $Name
                ResourceGroupName = $ResourceGroupName
                PreviousSize      = $currentSize
                NewSize           = $NewSize
                Status            = 'Resized'
            }
        }
    }
}
catch {
    if ($exitCode -eq 0) {
        $exitCode = switch -Wildcard ($_.FullyQualifiedErrorId) {
            'AzToolkit.AuthenticationFailed*' { 2 }
            'AzToolkit.ConfigurationInvalid*' { 4 }
            default { 1 }
        }
    }
    Write-ToolkitLog -Level Error -Message "Unhandled failure: $($_.Exception.Message)" -ErrorRecord $_
    Write-Error -ErrorRecord $_ -ErrorAction Continue
}
finally {
    Write-ToolkitLog -Message "Completed with exit code $exitCode"
}
exit $exitCode

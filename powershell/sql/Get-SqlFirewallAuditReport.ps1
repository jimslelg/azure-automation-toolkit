#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Sql

<#
.SYNOPSIS
    Audits Azure SQL server firewall rules and flags overly permissive ranges.
.DESCRIPTION
    Enumerates the firewall rules of every SQL server in scope and rates each rule:
    High when the range covers the whole IPv4 space or spans more than 65536 addresses
    (OpenToInternet/BroadRange), Medium for the Azure-services allowance
    (AllowAllWindowsAzureIps / 0.0.0.0-0.0.0.0, reported as AzureServicesAllowed), and
    Info for scoped ranges. Each row also carries the server's public network access
    setting. Read-only; results can be exported with -ExportPath.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Optional resource group to limit the scan; the whole subscription otherwise.
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Get-SqlFirewallAuditReport.ps1

    Audits the firewall rules of every SQL server in the current subscription.
.EXAMPLE
    ./Get-SqlFirewallAuditReport.ps1 -ResourceGroupName rg-data-prod -ExportPath ./output

    Audits one resource group and exports the findings as CSV.
.NOTES
    Author  : Jim Eligio
    Version : 1.0.0
    Requires: Reader on the target scope.
    Exit codes: 0 success, 1 general failure, 2 auth failure, 3 partial failure
                (some servers could not be audited), 4 invalid parameters/configuration.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$SubscriptionId,

    [Parameter()]
    [string]$ResourceGroupName,

    [Parameter()]
    [string]$ExportPath,

    [Parameter()]
    [ValidateSet('Csv', 'Json')]
    [string]$ExportFormat = 'Csv'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'AzToolkit.Common.psd1') -Force

function ConvertTo-UInt32Address {
    <#
    .SYNOPSIS
        Converts a dotted-quad IPv4 address to its numeric value for range math.
    #>
    [CmdletBinding()]
    [OutputType([uint32])]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$IpAddress
    )
    $bytes = [System.Net.IPAddress]::Parse($IpAddress).GetAddressBytes()
    [Array]::Reverse($bytes)
    return [BitConverter]::ToUInt32($bytes, 0)
}

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
    Write-ToolkitLog -Message "Auditing firewall rules on $($servers.Count) SQL server(s)"

    $failures = 0
    $report = foreach ($server in $servers) {
        try {
            $rules = @(Invoke-WithRetry -OperationName "List firewall rules on $($server.ServerName)" -ScriptBlock {
                    Get-AzSqlServerFirewallRule -ServerName $server.ServerName -ResourceGroupName $server.ResourceGroupName
                })
            Write-ToolkitLog -Message 'Server audited' -Data @{
                server              = $server.ServerName
                ruleCount           = $rules.Count
                publicNetworkAccess = $server.PublicNetworkAccess
            }

            foreach ($rule in $rules) {
                $startAddress = ConvertTo-UInt32Address -IpAddress $rule.StartIpAddress
                $endAddress = ConvertTo-UInt32Address -IpAddress $rule.EndIpAddress
                $addressCount = [long]$endAddress - [long]$startAddress + 1

                $isAzureServicesRule = $rule.FirewallRuleName -eq 'AllowAllWindowsAzureIps' -or
                ($rule.StartIpAddress -eq '0.0.0.0' -and $rule.EndIpAddress -eq '0.0.0.0')

                if ($rule.StartIpAddress -eq '0.0.0.0' -and $rule.EndIpAddress -eq '255.255.255.255') {
                    $severity = 'High'
                    $finding = 'OpenToInternet'
                }
                elseif (-not $isAzureServicesRule -and $addressCount -gt 65536) {
                    $severity = 'High'
                    $finding = 'BroadRange'
                }
                elseif ($isAzureServicesRule) {
                    $severity = 'Medium'
                    $finding = 'AzureServicesAllowed'
                }
                else {
                    $severity = 'Info'
                    $finding = 'ScopedRange'
                }

                [pscustomobject]@{
                    ServerName          = $server.ServerName
                    ResourceGroupName   = $server.ResourceGroupName
                    RuleName            = $rule.FirewallRuleName
                    StartIpAddress      = $rule.StartIpAddress
                    EndIpAddress        = $rule.EndIpAddress
                    AddressCount        = $addressCount
                    Severity            = $severity
                    Finding             = $finding
                    PublicNetworkAccess = $server.PublicNetworkAccess
                }
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed to audit server '$($server.ServerName)'" -ErrorRecord $_
        }
    }

    $report = @($report)
    if ($failures -gt 0 -and $failures -lt $servers.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $servers.Count -gt 0) { throw "Firewall audit failed for all $failures server(s)." }

    Write-ToolkitLog -Message "$($report.Count) firewall rule(s) audited"
    $report

    if ($ExportPath -and $report.Count -gt 0) {
        $exportParams = @{ InputObject = $report; Name = 'sql-firewall-audit-report'; OutputDirectory = $ExportPath }
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

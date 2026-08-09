#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Network

<#
.SYNOPSIS
    Audits NSGs for inbound Allow rules exposing sensitive ports to the internet.
.DESCRIPTION
    Inspects every network security group in scope and flags inbound Allow rules whose
    source is open ('*', '0.0.0.0/0', or 'Internet') and whose destination port range
    covers a sensitive port (22, 3389, 1433, 3306, 5432, 5985, 5986, 8080). Port
    expressions '*', single ports, ranges ('a-b'), and comma lists are all evaluated.
    Read-only: emits one finding object per offending rule with the matched ports,
    priority, severity (High for SSH/RDP, Medium otherwise), and how many subnets and
    NICs the NSG protects. Exportable with -ExportPath.
.PARAMETER SubscriptionId
    Target subscription. Defaults to the current Az context.
.PARAMETER ResourceGroupName
    Optional resource group to limit the audit; the whole subscription otherwise.
.PARAMETER ExportPath
    Optional directory to export results to (created if missing; timestamped filename).
.PARAMETER ExportFormat
    Export format when -ExportPath is supplied. Csv (default) or Json.
.EXAMPLE
    ./Get-NsgAuditReport.ps1

    Audits every NSG in the subscription and emits findings to the pipeline.
.EXAMPLE
    ./Get-NsgAuditReport.ps1 -ResourceGroupName rg-network -ExportPath ./output -ExportFormat Json

    Audits one resource group and exports the findings as JSON.
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
    [string]$ResourceGroupName,

    [Parameter()]
    [string]$ExportPath,

    [Parameter()]
    [ValidateSet('Csv', 'Json')]
    [string]$ExportFormat = 'Csv'
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..' '..' 'shared' 'AzToolkit.Common.psd1') -Force

function Get-SensitivePortMatch {
    <#
    .SYNOPSIS
        Returns the sensitive ports covered by a rule's destination port expressions.
    #>
    param(
        [string[]]$PortRanges,
        [int[]]$SensitivePorts
    )
    $matchedPorts = [System.Collections.Generic.HashSet[int]]::new()
    foreach ($entry in @($PortRanges)) {
        if ([string]::IsNullOrWhiteSpace($entry)) {
            continue
        }
        foreach ($token in ($entry -split ',')) {
            $token = $token.Trim()
            if ($token -eq '*') {
                foreach ($port in $SensitivePorts) {
                    $null = $matchedPorts.Add($port)
                }
            }
            elseif ($token -match '^(\d+)\s*-\s*(\d+)$') {
                $low = [int]$Matches[1]
                $high = [int]$Matches[2]
                foreach ($port in $SensitivePorts) {
                    if ($port -ge $low -and $port -le $high) {
                        $null = $matchedPorts.Add($port)
                    }
                }
            }
            elseif ($token -match '^\d+$') {
                $port = [int]$token
                if ($SensitivePorts -contains $port) {
                    $null = $matchedPorts.Add($port)
                }
            }
        }
    }
    return @($matchedPorts | Sort-Object)
}

$exitCode = 0
try {
    $null = Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name
    $null = Connect-ToolkitAzure -SubscriptionId $SubscriptionId

    $nsgParams = @{}
    if ($ResourceGroupName) {
        $nsgParams.ResourceGroupName = $ResourceGroupName
    }
    $nsgs = @(Invoke-WithRetry -OperationName 'List network security groups' -ScriptBlock {
            Get-AzNetworkSecurityGroup @nsgParams
        })
    Write-ToolkitLog -Message "Auditing $($nsgs.Count) network security group(s)"

    $sensitivePorts = @(22, 3389, 1433, 3306, 5432, 5985, 5986, 8080)
    $highSeverityPorts = @(22, 3389)
    $openSources = @('*', '0.0.0.0/0', 'Internet')
    $failures = 0

    $findings = foreach ($nsg in $nsgs) {
        try {
            $inboundAllowRules = @($nsg.SecurityRules |
                    Where-Object { $_.Direction -eq 'Inbound' -and $_.Access -eq 'Allow' })

            foreach ($rule in $inboundAllowRules) {
                $sourcePrefixes = @($rule.SourceAddressPrefix)
                $openPrefixes = @($sourcePrefixes | Where-Object { $_ -in $openSources })
                if ($openPrefixes.Count -eq 0) {
                    continue
                }

                $portsMatched = @(Get-SensitivePortMatch -PortRanges @($rule.DestinationPortRange) -SensitivePorts $sensitivePorts)
                if ($portsMatched.Count -eq 0) {
                    continue
                }

                $severity = if (@($portsMatched | Where-Object { $_ -in $highSeverityPorts }).Count -gt 0) { 'High' } else { 'Medium' }
                Write-ToolkitLog -Level Warning -Message 'Exposed sensitive port(s) found' -Data @{
                    nsg      = $nsg.Name
                    rule     = $rule.Name
                    ports    = ($portsMatched -join ',')
                    severity = $severity
                }
                [pscustomobject]@{
                    NsgName           = $nsg.Name
                    ResourceGroupName = $nsg.ResourceGroupName
                    Location          = $nsg.Location
                    RuleName          = $rule.Name
                    Priority          = $rule.Priority
                    Source            = ($sourcePrefixes -join ',')
                    DestinationPorts  = (@($rule.DestinationPortRange) -join ',')
                    MatchedPorts      = ($portsMatched -join ',')
                    Severity          = $severity
                    AttachedSubnets   = @($nsg.Subnets).Count
                    AttachedNics      = @($nsg.NetworkInterfaces).Count
                }
            }
        }
        catch {
            $failures++
            Write-ToolkitLog -Level Error -Message "Failed to audit NSG '$($nsg.Name)'" -ErrorRecord $_
        }
    }

    $findings = @($findings)
    if ($failures -gt 0 -and $failures -lt $nsgs.Count) { $exitCode = 3 }
    elseif ($failures -gt 0 -and $nsgs.Count -gt 0) { throw "All $failures NSG(s) failed auditing." }

    Write-ToolkitLog -Message "$($findings.Count) finding(s) across $($nsgs.Count) NSG(s)"
    $findings

    if ($ExportPath -and $findings.Count -gt 0) {
        $exportParams = @{ InputObject = $findings; Name = 'nsg-audit-report'; OutputDirectory = $ExportPath }
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

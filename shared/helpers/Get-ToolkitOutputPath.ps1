function Get-ToolkitOutputPath {
    <#
    .SYNOPSIS
        Builds a timestamped output file path, creating the output directory if needed.
    .DESCRIPTION
        Returns '<OutputDirectory>/<Name>_<yyyyMMdd_HHmmss>.<Extension>' so repeated
        runs never overwrite earlier results. Used by the CSV/JSON exporters and
        available to scripts that write other formats.
    .PARAMETER Name
        Base file name (no extension), e.g. 'vm-inventory'.
    .PARAMETER Extension
        File extension without the dot, e.g. 'csv'.
    .PARAMETER OutputDirectory
        Target directory (created if missing). Defaults to ./output.
    .EXAMPLE
        Get-ToolkitOutputPath -Name 'nsg-audit' -Extension 'json'

        Returns ./output/nsg-audit_20260810_142255.json
    .OUTPUTS
        System.String. The full output file path.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[\w\.-]+$')]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Za-z0-9]+$')]
        [string]$Extension,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$OutputDirectory = './output'
    )

    if (-not (Test-Path -Path $OutputDirectory)) {
        $null = New-Item -ItemType Directory -Path $OutputDirectory -Force
    }

    return Join-Path $OutputDirectory ('{0}_{1}.{2}' -f $Name, (Get-Date -Format 'yyyyMMdd_HHmmss'), $Extension)
}

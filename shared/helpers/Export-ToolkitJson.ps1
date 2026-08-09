function Export-ToolkitJson {
    <#
    .SYNOPSIS
        Exports objects to a timestamped JSON file in the toolkit output directory.
    .DESCRIPTION
        Buffers pipeline input, serializes it to '<OutputDirectory>/<Name>_<timestamp>.json',
        logs the export, and returns the FileInfo of the created file. The output is
        always a JSON array, even for a single object, so consumers can parse it
        uniformly.
    .PARAMETER InputObject
        Objects to export. Accepts pipeline input.
    .PARAMETER Name
        Base file name (no extension), e.g. 'nsg-audit'.
    .PARAMETER OutputDirectory
        Target directory (created if missing). Defaults to ./output.
    .PARAMETER Depth
        Serialization depth passed to ConvertTo-Json. Defaults to 10.
    .EXAMPLE
        $findings | Export-ToolkitJson -Name 'nsg-audit' -Depth 6
    .OUTPUTS
        System.IO.FileInfo. The created JSON file.
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [object[]]$InputObject,

        [Parameter(Mandatory)]
        [ValidatePattern('^[\w\.-]+$')]
        [string]$Name,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$OutputDirectory = './output',

        [Parameter()]
        [ValidateRange(1, 100)]
        [int]$Depth = 10
    )

    begin {
        $buffer = [System.Collections.Generic.List[object]]::new()
    }
    process {
        foreach ($item in $InputObject) {
            $buffer.Add($item)
        }
    }
    end {
        $path = Get-ToolkitOutputPath -Name $Name -Extension 'json' -OutputDirectory $OutputDirectory
        ConvertTo-Json -InputObject $buffer -Depth $Depth | Set-Content -Path $path
        Write-ToolkitLog -Message "Exported $($buffer.Count) record(s) to $path" -Data @{
            path    = $path
            records = $buffer.Count
            format  = 'json'
        }
        Get-Item -Path $path
    }
}

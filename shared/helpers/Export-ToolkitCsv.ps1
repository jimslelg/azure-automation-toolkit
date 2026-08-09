function Export-ToolkitCsv {
    <#
    .SYNOPSIS
        Exports objects to a timestamped CSV file in the toolkit output directory.
    .DESCRIPTION
        Buffers pipeline input, writes it to '<OutputDirectory>/<Name>_<timestamp>.csv',
        logs the export, and returns the FileInfo of the created file.
    .PARAMETER InputObject
        Objects to export. Accepts pipeline input.
    .PARAMETER Name
        Base file name (no extension), e.g. 'vm-inventory'.
    .PARAMETER OutputDirectory
        Target directory (created if missing). Defaults to ./output.
    .EXAMPLE
        $results | Export-ToolkitCsv -Name 'idle-vms'
    .OUTPUTS
        System.IO.FileInfo. The created CSV file.
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
        [string]$OutputDirectory = './output'
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
        $path = Get-ToolkitOutputPath -Name $Name -Extension 'csv' -OutputDirectory $OutputDirectory
        $buffer | Export-Csv -Path $path
        Write-ToolkitLog -Message "Exported $($buffer.Count) record(s) to $path" -Data @{
            path    = $path
            records = $buffer.Count
            format  = 'csv'
        }
        Get-Item -Path $path
    }
}

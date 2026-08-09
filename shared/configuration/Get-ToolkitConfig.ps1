function Get-ToolkitConfig {
    <#
    .SYNOPSIS
        Loads toolkit configuration from JSON with optional environment overlays.
    .DESCRIPTION
        Reads the base JSON configuration file and, when an environment is specified
        (via -Environment or $env:AZTOOLKIT_ENVIRONMENT), deep-merges a
        'toolkit.settings.<environment>.json' overlay found beside the base file —
        overlay values win, nested objects merge key by key. Throws a terminating
        error with FullyQualifiedErrorId 'AzToolkit.ConfigurationInvalid' on a missing
        file or malformed JSON, which toolkit scripts map to exit code 4.
    .PARAMETER Path
        Path to the base configuration file.
        Defaults to ./examples/config/toolkit.settings.json.
    .PARAMETER Environment
        Overlay environment name (e.g. 'dev', 'prod'). Defaults to
        $env:AZTOOLKIT_ENVIRONMENT; no overlay is applied when empty.
    .PARAMETER Section
        Returns only this top-level section of the configuration (e.g. 'cleanup').
    .EXAMPLE
        $config = Get-ToolkitConfig -Path ./examples/config/toolkit.settings.json -Environment dev
    .EXAMPLE
        $cleanupSettings = Get-ToolkitConfig -Section cleanup
    .OUTPUTS
        System.Collections.Hashtable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Path = './examples/config/toolkit.settings.json',

        [Parameter()]
        [string]$Environment = $env:AZTOOLKIT_ENVIRONMENT,

        [Parameter()]
        [string]$Section
    )

    try {
        if (-not (Test-Path -Path $Path -PathType Leaf)) {
            throw "Configuration file not found: $Path"
        }
        $config = Get-Content -Path $Path -Raw | ConvertFrom-Json -AsHashtable

        if ($Environment) {
            $directory = Split-Path -Path $Path -Parent
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Path)
            $extension = [System.IO.Path]::GetExtension($Path)
            $overlayName = '{0}.{1}{2}' -f $baseName, $Environment, $extension
            $overlayPath = Join-Path $directory $overlayName
            if (Test-Path -Path $overlayPath -PathType Leaf) {
                $overlay = Get-Content -Path $overlayPath -Raw | ConvertFrom-Json -AsHashtable
                $config = Merge-ToolkitHashtable -Base $config -Overlay $overlay
                Write-ToolkitLog -Level Debug -Message "Applied configuration overlay '$overlayName'"
            }
            else {
                Write-ToolkitLog -Level Debug -Message "No overlay found for environment '$Environment' (looked for $overlayName)"
            }
        }

        if ($Section) {
            if (-not $config.ContainsKey($Section)) {
                throw "Section '$Section' not found in configuration file $Path"
            }
            return $config[$Section]
        }
        return $config
    }
    catch {
        $exception = [System.InvalidOperationException]::new(
            "Failed to load configuration: $($_.Exception.Message)", $_.Exception)
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $exception,
            'AzToolkit.ConfigurationInvalid',
            [System.Management.Automation.ErrorCategory]::InvalidData,
            $Path)
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }
}

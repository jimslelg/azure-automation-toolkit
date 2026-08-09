function Initialize-ToolkitLog {
    <#
    .SYNOPSIS
        Initializes the toolkit logging context for the current session.
    .DESCRIPTION
        Sets up the module-scoped logging context used by Write-ToolkitLog: the owning
        script name, the JSON-lines log file, the minimum level to emit, and a
        correlation ID stamped on every subsequent log record. Call once at the top of
        each script. When -NoFile is specified only console logging is active.
    .PARAMETER ScriptName
        Name of the calling script, recorded on every log line. Pass
        $MyInvocation.MyCommand.Name from the caller.
    .PARAMETER LogDirectory
        Directory for the log file (created if missing). Defaults to ./logs.
    .PARAMETER MinimumLevel
        Lowest level that gets emitted (Debug, Info, Warning, Error). Defaults to Info.
    .PARAMETER CorrelationId
        Correlation ID to stamp on log records. A new GUID is generated when omitted.
        Pass an existing ID to correlate logs across chained scripts.
    .PARAMETER NoFile
        Disables the file sink; log records go to the console only.
    .EXAMPLE
        Initialize-ToolkitLog -ScriptName $MyInvocation.MyCommand.Name

        Starts logging to ./logs/<script>_<timestamp>.log with a fresh correlation ID.
    .OUTPUTS
        System.String. The full path of the log file, or $null when -NoFile is used.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$ScriptName = 'AzToolkit',

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$LogDirectory = './logs',

        [Parameter()]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$MinimumLevel = 'Info',

        [Parameter()]
        [string]$CorrelationId,

        [Parameter()]
        [switch]$NoFile
    )

    if (-not $CorrelationId) {
        $CorrelationId = [guid]::NewGuid().ToString()
    }

    $logFile = $null
    if (-not $NoFile) {
        if (-not (Test-Path -Path $LogDirectory)) {
            $null = New-Item -ItemType Directory -Path $LogDirectory -Force
        }
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($ScriptName)
        $logFile = Join-Path $LogDirectory ('{0}_{1}.log' -f $baseName, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }

    $script:LogContext = @{
        ScriptName    = $ScriptName
        LogFile       = $logFile
        MinimumLevel  = $MinimumLevel
        CorrelationId = $CorrelationId
    }

    Write-ToolkitLog -Level Debug -Message 'Logging initialized' -Data @{
        logFile       = $logFile
        minimumLevel  = $MinimumLevel
        correlationId = $CorrelationId
    }

    return $logFile
}

function Get-ToolkitCorrelationId {
    <#
    .SYNOPSIS
        Returns the correlation ID of the current logging context.
    .DESCRIPTION
        Retrieves the correlation ID established by Initialize-ToolkitLog so it can be
        passed to downstream scripts, HTTP headers, or Azure tags for end-to-end
        traceability. If no logging context exists yet, a console-only context with a
        fresh GUID is created so the ID remains stable for the rest of the session.
    .EXAMPLE
        $correlationId = Get-ToolkitCorrelationId
    .OUTPUTS
        System.String. The correlation ID (GUID format).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (-not $script:LogContext) {
        $script:LogContext = @{
            ScriptName    = 'AzToolkit'
            LogFile       = $null
            MinimumLevel  = 'Info'
            CorrelationId = [guid]::NewGuid().ToString()
        }
    }

    return $script:LogContext.CorrelationId
}

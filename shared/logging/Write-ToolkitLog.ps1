function Write-ToolkitLog {
    <#
    .SYNOPSIS
        Writes a structured log record to the console and the JSON-lines log file.
    .DESCRIPTION
        The single logging entry point for all toolkit scripts. Emits a colored,
        human-readable line to the console and (when Initialize-ToolkitLog configured a
        file sink) appends a machine-parseable JSON object to the log file including
        timestamp, level, message, correlation ID, script name, structured data, and
        error details. Safe to call before Initialize-ToolkitLog — it falls back to
        console-only output.
    .PARAMETER Message
        The log message.
    .PARAMETER Level
        Severity: Debug, Info (default), Warning, or Error. Records below the
        configured minimum level are suppressed.
    .PARAMETER Data
        Optional hashtable of structured context serialized into the JSON record
        (e.g. @{ vm = $vm.Name; resourceGroup = $rg }).
    .PARAMETER ErrorRecord
        Optional ErrorRecord whose message, type, and script stack trace are captured
        in the JSON record.
    .EXAMPLE
        Write-ToolkitLog -Message 'Stopping VM' -Data @{ vm = 'web-01' }
    .EXAMPLE
        Write-ToolkitLog -Level Error -Message 'Stop failed' -ErrorRecord $_
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Debug', 'Info', 'Warning', 'Error')]
        [string]$Level = 'Info',

        [Parameter()]
        [hashtable]$Data,

        [Parameter()]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $levelRank = @{ Debug = 0; Info = 1; Warning = 2; Error = 3 }
    $minimumLevel = if ($script:LogContext) { $script:LogContext.MinimumLevel } else { 'Info' }
    if ($levelRank[$Level] -lt $levelRank[$minimumLevel]) {
        return
    }

    $timestamp = Get-Date
    $color = @{ Debug = 'DarkGray'; Info = 'Gray'; Warning = 'Yellow'; Error = 'Red' }[$Level]
    $consoleLine = '[{0:HH:mm:ss}] [{1,-7}] {2}' -f $timestamp, $Level.ToUpper(), $Message
    if ($ErrorRecord) {
        $consoleLine += ' :: ' + $ErrorRecord.Exception.Message
    }
    Write-Host $consoleLine -ForegroundColor $color

    if ($script:LogContext -and $script:LogContext.LogFile) {
        $entry = Format-LogEntry -Timestamp $timestamp -Level $Level -Message $Message `
            -Data $Data -ErrorRecord $ErrorRecord -Context $script:LogContext
        Add-Content -Path $script:LogContext.LogFile -Value $entry
    }
}

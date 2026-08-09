function Format-LogEntry {
    # Internal: builds one JSON-lines record for the file sink of Write-ToolkitLog.
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [datetime]$Timestamp,

        [Parameter(Mandatory)]
        [string]$Level,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,

        [Parameter()]
        [hashtable]$Data,

        [Parameter()]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    $record = [ordered]@{
        timestamp     = $Timestamp.ToUniversalTime().ToString('o')
        level         = $Level
        message       = $Message
        correlationId = $Context.CorrelationId
        script        = $Context.ScriptName
    }

    if ($Data) {
        $record.data = $Data
    }

    if ($ErrorRecord) {
        $record.error = [ordered]@{
            message    = $ErrorRecord.Exception.Message
            type       = $ErrorRecord.Exception.GetType().FullName
            errorId    = $ErrorRecord.FullyQualifiedErrorId
            stackTrace = $ErrorRecord.ScriptStackTrace
        }
    }

    return ($record | ConvertTo-Json -Compress -Depth 8)
}

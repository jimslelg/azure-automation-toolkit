function Test-RetryableError {
    <#
    .SYNOPSIS
        Classifies whether an error is transient and safe to retry.
    .DESCRIPTION
        Inspects the error's HTTP status code (walking inner exceptions for a Response
        or StatusCode property) and its message. HTTP 408/429/500/502/503/504 are
        retryable; 400/401/403/404/409 fail fast. When no status code is found, the
        exception message is matched against known transient patterns (throttling,
        gateway timeouts, dropped connections). Unrecognized errors are NOT retryable —
        the toolkit fails fast by default.
    .PARAMETER ErrorRecord
        The error to classify (typically $_ inside a catch block).
    .PARAMETER AdditionalPatterns
        Extra regex patterns to treat as retryable for caller-specific cases.
    .EXAMPLE
        if (Test-RetryableError -ErrorRecord $_) { Start-Sleep 5; ... }
    .OUTPUTS
        System.Boolean.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,

        [Parameter()]
        [string[]]$AdditionalPatterns = @()
    )

    $retryableStatusCodes = @(408, 429, 500, 502, 503, 504)
    $nonRetryableStatusCodes = @(400, 401, 403, 404, 409)

    $statusCode = $null
    $exception = $ErrorRecord.Exception
    while ($exception) {
        $responseProperty = $exception.PSObject.Properties['Response']
        if ($responseProperty -and $responseProperty.Value -and $responseProperty.Value.PSObject.Properties['StatusCode']) {
            $statusCode = [int]$responseProperty.Value.StatusCode
            break
        }
        $statusProperty = $exception.PSObject.Properties['StatusCode']
        if ($statusProperty -and $null -ne $statusProperty.Value) {
            $statusCode = [int]$statusProperty.Value
            break
        }
        $exception = $exception.InnerException
    }

    if ($null -ne $statusCode) {
        if ($statusCode -in $retryableStatusCodes) {
            return $true
        }
        if ($statusCode -in $nonRetryableStatusCodes) {
            return $false
        }
    }

    $transientPatterns = @(
        'TooManyRequests'
        'Request rate is large'
        'ServiceUnavailable'
        'GatewayTimeout'
        'InternalServerError'
        'operation timed out'
        'connection was (closed|reset)'
        'temporarily unavailable'
        'retry (the request )?later'
    ) + $AdditionalPatterns

    $message = $ErrorRecord.Exception.Message
    foreach ($pattern in $transientPatterns) {
        if ($message -match $pattern) {
            return $true
        }
    }

    return $false
}

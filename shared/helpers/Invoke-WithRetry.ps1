function Invoke-WithRetry {
    <#
    .SYNOPSIS
        Executes a script block with exponential backoff retry on transient failures.
    .DESCRIPTION
        Runs the script block and, when it throws a transient error (as classified by
        Test-RetryableError), retries with exponential backoff plus random jitter:
        delay = min(InitialDelaySeconds * 2^(attempt-1), MaxDelaySeconds) + 0-1s jitter.
        Non-retryable errors (400/401/403/404/409 and unrecognized failures) are
        rethrown immediately. Each retry is logged at Warning level. The last attempt's
        error is rethrown unchanged so callers keep the original error record.
    .PARAMETER ScriptBlock
        The operation to execute — keep it to a single Azure call so retries stay
        idempotent.
    .PARAMETER MaxAttempts
        Total attempts including the first (default 4).
    .PARAMETER InitialDelaySeconds
        Base delay before the first retry (default 2).
    .PARAMETER MaxDelaySeconds
        Backoff ceiling (default 60).
    .PARAMETER RetryableErrorPatterns
        Additional regex patterns (matched against the exception message) to treat as
        retryable, on top of the built-in transient classifications.
    .PARAMETER OperationName
        Friendly name used in retry log messages.
    .EXAMPLE
        $vms = Invoke-WithRetry -OperationName 'List VMs' -ScriptBlock { Get-AzVM -Status }
    .OUTPUTS
        Whatever the script block returns.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,

        [Parameter()]
        [ValidateRange(1, 10)]
        [int]$MaxAttempts = 4,

        [Parameter()]
        [ValidateRange(0.1, 300)]
        [double]$InitialDelaySeconds = 2,

        [Parameter()]
        [ValidateRange(1, 3600)]
        [double]$MaxDelaySeconds = 60,

        [Parameter()]
        [string[]]$RetryableErrorPatterns = @(),

        [Parameter()]
        [string]$OperationName = 'operation'
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $ScriptBlock
        }
        catch {
            $isRetryable = Test-RetryableError -ErrorRecord $_ -AdditionalPatterns $RetryableErrorPatterns
            if ($attempt -eq $MaxAttempts -or -not $isRetryable) {
                throw
            }

            $delay = [Math]::Min($InitialDelaySeconds * [Math]::Pow(2, $attempt - 1), $MaxDelaySeconds)
            $delay += (Get-Random -Minimum 0 -Maximum 1000) / 1000.0
            Write-ToolkitLog -Level Warning `
                -Message ("Attempt {0}/{1} of '{2}' failed; retrying in {3:N1}s" -f $attempt, $MaxAttempts, $OperationName, $delay) `
                -Data @{ error = $_.Exception.Message; attempt = $attempt }
            Start-Sleep -Seconds $delay
        }
    }
}

BeforeAll {
    Import-Module "$PSScriptRoot/../../shared/AzToolkit.Common.psd1" -Force
}

Describe 'Invoke-WithRetry' {
    BeforeEach {
        Mock Start-Sleep { } -ModuleName AzToolkit.Common
    }

    It 'returns the result on first success without sleeping' {
        $result = Invoke-WithRetry -ScriptBlock { 'ok' }

        $result | Should -Be 'ok'
        Should -Invoke Start-Sleep -ModuleName AzToolkit.Common -Times 0 -Exactly
    }

    It 'retries transient errors until the operation succeeds' {
        $state = @{ Attempts = 0 }
        $result = Invoke-WithRetry -MaxAttempts 4 -ScriptBlock {
            $state.Attempts++
            if ($state.Attempts -lt 3) {
                throw 'connection was reset'
            }
            "ok after $($state.Attempts)"
        }

        $result | Should -Be 'ok after 3'
        Should -Invoke Start-Sleep -ModuleName AzToolkit.Common -Times 2 -Exactly
    }

    It 'fails fast on non-retryable errors' {
        $state = @{ Attempts = 0 }
        {
            Invoke-WithRetry -MaxAttempts 4 -ScriptBlock {
                $state.Attempts++
                throw 'ResourceNotFound: the resource does not exist'
            }
        } | Should -Throw '*ResourceNotFound*'

        $state.Attempts | Should -Be 1
        Should -Invoke Start-Sleep -ModuleName AzToolkit.Common -Times 0 -Exactly
    }

    It 'rethrows the original error after exhausting all attempts' {
        $state = @{ Attempts = 0 }
        {
            Invoke-WithRetry -MaxAttempts 3 -ScriptBlock {
                $state.Attempts++
                throw 'ServiceUnavailable'
            }
        } | Should -Throw '*ServiceUnavailable*'

        $state.Attempts | Should -Be 3
        Should -Invoke Start-Sleep -ModuleName AzToolkit.Common -Times 2 -Exactly
    }

    It 'treats caller-supplied patterns as retryable' {
        $state = @{ Attempts = 0 }
        $result = Invoke-WithRetry -MaxAttempts 2 -RetryableErrorPatterns @('my custom flake') -ScriptBlock {
            $state.Attempts++
            if ($state.Attempts -eq 1) {
                throw 'my custom flake happened'
            }
            'recovered'
        }

        $result | Should -Be 'recovered'
    }

    It 'caps the backoff delay at MaxDelaySeconds (plus jitter)' {
        $state = @{ Attempts = 0 }
        {
            Invoke-WithRetry -MaxAttempts 5 -InitialDelaySeconds 100 -MaxDelaySeconds 5 -ScriptBlock {
                $state.Attempts++
                throw 'GatewayTimeout'
            }
        } | Should -Throw

        Should -Invoke Start-Sleep -ModuleName AzToolkit.Common -Times 4 -Exactly `
            -ParameterFilter { $Seconds -le 6 }
    }
}

Describe 'Test-RetryableError' {
    BeforeAll {
        function script:New-TestErrorRecord {
            param([System.Exception]$Exception)
            [System.Management.Automation.ErrorRecord]::new(
                $Exception, 'TestError',
                [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
        }
    }

    It 'classifies HTTP <status> as retryable=<expected>' -ForEach @(
        @{ status = 408; expected = $true }
        @{ status = 429; expected = $true }
        @{ status = 500; expected = $true }
        @{ status = 502; expected = $true }
        @{ status = 503; expected = $true }
        @{ status = 504; expected = $true }
        @{ status = 400; expected = $false }
        @{ status = 401; expected = $false }
        @{ status = 403; expected = $false }
        @{ status = 404; expected = $false }
        @{ status = 409; expected = $false }
    ) {
        $exception = [System.Net.Http.HttpRequestException]::new(
            'http failure', $null, [System.Net.HttpStatusCode]$status)
        $record = New-TestErrorRecord -Exception $exception

        Test-RetryableError -ErrorRecord $record | Should -Be $expected
    }

    It 'finds the status code on an inner exception' {
        $inner = [System.Net.Http.HttpRequestException]::new(
            'throttled', $null, [System.Net.HttpStatusCode]::TooManyRequests)
        $outer = [System.Exception]::new('wrapper', $inner)
        $record = New-TestErrorRecord -Exception $outer

        Test-RetryableError -ErrorRecord $record | Should -BeTrue
    }

    It 'recognizes transient message patterns without a status code' -ForEach @(
        @{ message = 'TooManyRequests: slow down' }
        @{ message = 'Request rate is large' }
        @{ message = 'The operation timed out' }
        @{ message = 'The connection was reset by the remote host' }
        @{ message = 'Service is temporarily unavailable, retry later' }
    ) {
        $record = New-TestErrorRecord -Exception ([System.Exception]::new($message))
        Test-RetryableError -ErrorRecord $record | Should -BeTrue
    }

    It 'does not retry unrecognized errors' {
        $record = New-TestErrorRecord -Exception ([System.Exception]::new('invalid parameter value'))
        Test-RetryableError -ErrorRecord $record | Should -BeFalse
    }

    It 'honors additional caller-supplied patterns' {
        $record = New-TestErrorRecord -Exception ([System.Exception]::new('flaky widget error'))

        Test-RetryableError -ErrorRecord $record | Should -BeFalse
        Test-RetryableError -ErrorRecord $record -AdditionalPatterns @('flaky widget') | Should -BeTrue
    }
}

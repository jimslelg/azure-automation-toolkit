BeforeAll {
    Import-Module "$PSScriptRoot/../../shared/AzToolkit.Common.psd1" -Force
}

Describe 'Initialize-ToolkitLog' {
    It 'creates the log directory and returns a timestamped log file path' {
        $logDir = Join-Path $TestDrive 'logs'
        $logFile = Initialize-ToolkitLog -ScriptName 'My-Script.ps1' -LogDirectory $logDir

        $logFile | Should -Match 'My-Script_\d{8}_\d{6}\.log$'
        Test-Path $logDir | Should -BeTrue
    }

    It 'returns null and creates nothing when -NoFile is used' {
        $logDir = Join-Path $TestDrive 'nofile-logs'
        $logFile = Initialize-ToolkitLog -ScriptName 'My-Script.ps1' -LogDirectory $logDir -NoFile

        $logFile | Should -BeNullOrEmpty
        Test-Path $logDir | Should -BeFalse
    }

    It 'honors a caller-supplied correlation ID' {
        $null = Initialize-ToolkitLog -ScriptName 'x.ps1' -LogDirectory $TestDrive -CorrelationId 'my-correlation-id'
        Get-ToolkitCorrelationId | Should -Be 'my-correlation-id'
    }

    It 'generates a GUID correlation ID when none is supplied' {
        $null = Initialize-ToolkitLog -ScriptName 'x.ps1' -LogDirectory $TestDrive
        Get-ToolkitCorrelationId | Should -Match '^[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}$'
    }
}

Describe 'Write-ToolkitLog' {
    BeforeEach {
        $script:logFile = Initialize-ToolkitLog -ScriptName 'Log-Test.ps1' -LogDirectory (Join-Path $TestDrive ([guid]::NewGuid())) -MinimumLevel Debug
    }

    It 'appends one parseable JSON object per log call' {
        Write-ToolkitLog -Message 'first'
        Write-ToolkitLog -Level Warning -Message 'second'

        $lines = Get-Content $script:logFile | Where-Object { $_ -notmatch 'Logging initialized' }
        $lines | Should -HaveCount 2
        foreach ($line in $lines) {
            { $line | ConvertFrom-Json } | Should -Not -Throw
        }
    }

    It 'stamps every record with timestamp, level, correlation ID, and script name' {
        Write-ToolkitLog -Message 'stamped'

        $record = Get-Content $script:logFile | Select-Object -Last 1 | ConvertFrom-Json
        $record.timestamp | Should -Not -BeNullOrEmpty
        $record.level | Should -Be 'Info'
        $record.message | Should -Be 'stamped'
        $record.correlationId | Should -Be (Get-ToolkitCorrelationId)
        $record.script | Should -Be 'Log-Test.ps1'
    }

    It 'serializes the -Data hashtable into the record' {
        Write-ToolkitLog -Message 'with data' -Data @{ vm = 'web-01'; count = 3 }

        $record = Get-Content $script:logFile | Select-Object -Last 1 | ConvertFrom-Json
        $record.data.vm | Should -Be 'web-01'
        $record.data.count | Should -Be 3
    }

    It 'captures error details from -ErrorRecord' {
        try {
            throw 'boom'
        }
        catch {
            Write-ToolkitLog -Level Error -Message 'failed' -ErrorRecord $_
        }

        $record = Get-Content $script:logFile | Select-Object -Last 1 | ConvertFrom-Json
        $record.error.message | Should -Be 'boom'
        $record.error.type | Should -Not -BeNullOrEmpty
    }

    It 'suppresses records below the minimum level' {
        $quietLog = Initialize-ToolkitLog -ScriptName 'Quiet.ps1' -LogDirectory (Join-Path $TestDrive 'quiet') -MinimumLevel Warning
        Write-ToolkitLog -Level Info -Message 'should not appear'
        Write-ToolkitLog -Level Warning -Message 'should appear'

        $content = Get-Content $quietLog -Raw
        $content | Should -Not -Match 'should not appear'
        $content | Should -Match 'should appear'
    }

    It 'does not throw when called before Initialize-ToolkitLog' {
        InModuleScope AzToolkit.Common { $script:LogContext = $null }
        { Write-ToolkitLog -Message 'console only' } | Should -Not -Throw
    }
}

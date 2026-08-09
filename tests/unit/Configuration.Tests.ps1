BeforeAll {
    Import-Module "$PSScriptRoot/../../shared/AzToolkit.Common.psd1" -Force

    $script:savedEnvironment = $env:AZTOOLKIT_ENVIRONMENT
}

AfterAll {
    [Environment]::SetEnvironmentVariable('AZTOOLKIT_ENVIRONMENT', $script:savedEnvironment)
}

Describe 'Get-ToolkitConfig' {
    BeforeEach {
        $env:AZTOOLKIT_ENVIRONMENT = $null

        $script:configDir = Join-Path $TestDrive ([guid]::NewGuid())
        $null = New-Item -ItemType Directory -Path $script:configDir
        $script:basePath = Join-Path $script:configDir 'toolkit.settings.json'

        @{
            azure   = @{ defaultLocation = 'canadacentral'; subscriptionId = '' }
            logging = @{ minimumLevel = 'Info'; directory = './logs' }
            cleanup = @{ snapshotMinimumAgeDays = 90 }
        } | ConvertTo-Json | Set-Content -Path $script:basePath

        @{
            logging = @{ minimumLevel = 'Debug' }
            cleanup = @{ snapshotMinimumAgeDays = 30 }
        } | ConvertTo-Json | Set-Content -Path (Join-Path $script:configDir 'toolkit.settings.dev.json')
    }

    It 'loads the base configuration as a hashtable' {
        $config = Get-ToolkitConfig -Path $script:basePath

        $config | Should -BeOfType [hashtable]
        $config.azure.defaultLocation | Should -Be 'canadacentral'
        $config.logging.minimumLevel | Should -Be 'Info'
    }

    It 'deep-merges the environment overlay: overlay wins, untouched keys survive' {
        $config = Get-ToolkitConfig -Path $script:basePath -Environment dev

        $config.logging.minimumLevel | Should -Be 'Debug'
        $config.logging.directory | Should -Be './logs'
        $config.cleanup.snapshotMinimumAgeDays | Should -Be 30
        $config.azure.defaultLocation | Should -Be 'canadacentral'
    }

    It 'uses AZTOOLKIT_ENVIRONMENT as the default overlay environment' {
        $env:AZTOOLKIT_ENVIRONMENT = 'dev'
        $config = Get-ToolkitConfig -Path $script:basePath

        $config.logging.minimumLevel | Should -Be 'Debug'
    }

    It 'ignores a missing overlay file' {
        $config = Get-ToolkitConfig -Path $script:basePath -Environment prod

        $config.logging.minimumLevel | Should -Be 'Info'
    }

    It 'returns just one section with -Section' {
        $section = Get-ToolkitConfig -Path $script:basePath -Section cleanup

        $section.snapshotMinimumAgeDays | Should -Be 90
        $section.Keys | Should -Not -Contain 'azure'
    }

    It 'throws AzToolkit.ConfigurationInvalid for a missing file' {
        { Get-ToolkitConfig -Path (Join-Path $script:configDir 'nope.json') } |
            Should -Throw -ErrorId 'AzToolkit.ConfigurationInvalid,Get-ToolkitConfig'
    }

    It 'throws AzToolkit.ConfigurationInvalid for malformed JSON' {
        Set-Content -Path $script:basePath -Value '{ this is not json'

        { Get-ToolkitConfig -Path $script:basePath } |
            Should -Throw -ErrorId 'AzToolkit.ConfigurationInvalid,Get-ToolkitConfig'
    }

    It 'throws AzToolkit.ConfigurationInvalid for an unknown section' {
        { Get-ToolkitConfig -Path $script:basePath -Section doesNotExist } |
            Should -Throw -ErrorId 'AzToolkit.ConfigurationInvalid,Get-ToolkitConfig'
    }
}

Describe 'shipped example configuration' {
    It 'examples/config/toolkit.settings.json is valid and complete' {
        $examplePath = "$PSScriptRoot/../../examples/config/toolkit.settings.json"
        $config = Get-ToolkitConfig -Path $examplePath

        foreach ($section in @('azure', 'logging', 'output', 'governance', 'cleanup', 'compute', 'keyVault')) {
            $config.Keys | Should -Contain $section
        }
    }

    It 'the dev overlay merges cleanly over the example base' {
        $examplePath = "$PSScriptRoot/../../examples/config/toolkit.settings.json"
        $config = Get-ToolkitConfig -Path $examplePath -Environment dev

        $config.logging.minimumLevel | Should -Be 'Debug'
    }
}

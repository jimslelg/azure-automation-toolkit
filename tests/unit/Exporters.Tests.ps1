BeforeAll {
    Import-Module "$PSScriptRoot/../../shared/AzToolkit.Common.psd1" -Force
}

Describe 'Get-ToolkitOutputPath' {
    It 'returns a timestamped path and creates the directory' {
        $outDir = Join-Path $TestDrive 'out'
        $path = Get-ToolkitOutputPath -Name 'vm-inventory' -Extension 'csv' -OutputDirectory $outDir

        $path | Should -Match 'vm-inventory_\d{8}_\d{6}\.csv$'
        Test-Path $outDir | Should -BeTrue
    }

    It 'rejects names with path separators' {
        { Get-ToolkitOutputPath -Name '../escape' -Extension 'csv' -OutputDirectory $TestDrive } |
            Should -Throw
    }
}

Describe 'Export-ToolkitCsv' {
    BeforeEach {
        $script:records = @(
            [pscustomobject]@{ Name = 'vm-01'; Location = 'canadacentral'; Cores = 4 }
            [pscustomobject]@{ Name = 'vm-02'; Location = 'eastus'; Cores = 8 }
        )
    }

    It 'writes pipeline input to a timestamped CSV and returns the FileInfo' {
        $file = $script:records | Export-ToolkitCsv -Name 'vms' -OutputDirectory $TestDrive

        $file | Should -BeOfType [System.IO.FileInfo]
        $file.Name | Should -Match '^vms_\d{8}_\d{6}\.csv$'

        $roundTrip = Import-Csv $file.FullName
        $roundTrip | Should -HaveCount 2
        $roundTrip[0].Name | Should -Be 'vm-01'
        $roundTrip[1].Cores | Should -Be '8'
    }

    It 'accepts -InputObject directly' {
        $file = Export-ToolkitCsv -InputObject $script:records -Name 'vms' -OutputDirectory $TestDrive

        (Import-Csv $file.FullName) | Should -HaveCount 2
    }
}

Describe 'Export-ToolkitJson' {
    It 'writes a parseable JSON array and returns the FileInfo' {
        $records = @(
            [pscustomobject]@{ Name = 'kv-01'; ExpiresOn = '2026-09-01' }
            [pscustomobject]@{ Name = 'kv-02'; ExpiresOn = '2026-10-01' }
        )
        $file = $records | Export-ToolkitJson -Name 'secrets' -OutputDirectory $TestDrive

        $file.Name | Should -Match '^secrets_\d{8}_\d{6}\.json$'
        $parsed = Get-Content $file.FullName -Raw | ConvertFrom-Json
        $parsed | Should -HaveCount 2
        $parsed[0].Name | Should -Be 'kv-01'
    }

    It 'emits an array even for a single object' {
        $file = Export-ToolkitJson -InputObject ([pscustomobject]@{ Only = 1 }) -Name 'single' -OutputDirectory $TestDrive

        (Get-Content $file.FullName -Raw).TrimStart() | Should -Match '^\['
    }

    It 'serializes nested objects to the requested depth' {
        $nested = [pscustomobject]@{
            Name  = 'nsg-01'
            Rules = @([pscustomobject]@{ Port = 22; Source = [pscustomobject]@{ Cidr = '0.0.0.0/0' } })
        }
        $file = Export-ToolkitJson -InputObject $nested -Name 'nested' -OutputDirectory $TestDrive -Depth 6

        $parsed = Get-Content $file.FullName -Raw | ConvertFrom-Json
        $parsed[0].Rules[0].Source.Cidr | Should -Be '0.0.0.0/0'
    }
}

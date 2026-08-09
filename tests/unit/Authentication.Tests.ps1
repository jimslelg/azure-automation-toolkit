BeforeAll {
    Import-Module "$PSScriptRoot/../../shared/AzToolkit.Common.psd1" -Force

    # Az.Accounts is not installed on CI runners: define stubs inside the module
    # scope so Pester can mock them. Parameter blocks must cover every parameter
    # the module passes, because mocks inherit the stub's parameter block.
    InModuleScope AzToolkit.Common {
        function script:Get-AzContext {
            [CmdletBinding()] param()
        }
        function script:Connect-AzAccount {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Test stub: parameters exist only so mocks inherit them.')]
            [CmdletBinding()]
            param(
                [switch]$Identity,
                [switch]$ServicePrincipal,
                [pscredential]$Credential,
                [string]$Tenant
            )
        }
        function script:Set-AzContext {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '',
                Justification = 'Test stub: parameters exist only so mocks inherit them.')]
            [CmdletBinding()] param([string]$SubscriptionId)
        }
    }

    $script:fakeContext = [pscustomobject]@{
        Account      = [pscustomobject]@{ Id = 'user@contoso.com' }
        Subscription = [pscustomobject]@{ Id = '11111111-1111-1111-1111-111111111111'; Name = 'sub-prod' }
        Tenant       = [pscustomobject]@{ Id = '22222222-2222-2222-2222-222222222222' }
    }

    $script:authEnvVars = @(
        'AZTOOLKIT_AUTH_MODE', 'IDENTITY_ENDPOINT', 'MSI_ENDPOINT',
        'AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET', 'AZURE_TENANT_ID'
    )
    $script:savedEnv = @{}
    foreach ($name in $script:authEnvVars) {
        $script:savedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}

AfterAll {
    foreach ($name in $script:authEnvVars) {
        [Environment]::SetEnvironmentVariable($name, $script:savedEnv[$name])
    }
}

Describe 'Connect-ToolkitAzure' {
    BeforeEach {
        foreach ($name in $script:authEnvVars) {
            [Environment]::SetEnvironmentVariable($name, $null)
        }
        Mock Get-AzContext { $script:fakeContext } -ModuleName AzToolkit.Common
        Mock Connect-AzAccount { } -ModuleName AzToolkit.Common
        Mock Set-AzContext { } -ModuleName AzToolkit.Common
    }

    Context 'auto-detection' {
        It 'uses Managed Identity when IDENTITY_ENDPOINT is present' {
            $env:IDENTITY_ENDPOINT = 'http://169.254.169.254/metadata/identity'
            $null = Connect-ToolkitAzure

            Should -Invoke Connect-AzAccount -ModuleName AzToolkit.Common -Times 1 -Exactly `
                -ParameterFilter { $Identity -eq $true }
        }

        It 'uses Managed Identity when the legacy MSI_ENDPOINT is present' {
            $env:MSI_ENDPOINT = 'http://127.0.0.1:41234/MSI/token'
            $null = Connect-ToolkitAzure

            Should -Invoke Connect-AzAccount -ModuleName AzToolkit.Common -Times 1 -Exactly `
                -ParameterFilter { $Identity -eq $true }
        }

        It 'uses a service principal when the AZURE_* variables are all set' {
            $env:AZURE_CLIENT_ID = 'app-id'
            $env:AZURE_CLIENT_SECRET = 'app-secret'
            $env:AZURE_TENANT_ID = '22222222-2222-2222-2222-222222222222'
            $null = Connect-ToolkitAzure

            Should -Invoke Connect-AzAccount -ModuleName AzToolkit.Common -Times 1 -Exactly `
                -ParameterFilter {
                $ServicePrincipal -eq $true -and
                $Credential.UserName -eq 'app-id' -and
                $Tenant -eq '22222222-2222-2222-2222-222222222222'
            }
        }

        It 'reuses an existing context without re-authenticating' {
            $context = Connect-ToolkitAzure

            Should -Invoke Connect-AzAccount -ModuleName AzToolkit.Common -Times 0 -Exactly
            $context.Account.Id | Should -Be 'user@contoso.com'
        }

        It 'falls back to interactive login when there is no context and no environment hints' {
            Mock Get-AzContext { if ($script:connected) { $script:fakeContext } } -ModuleName AzToolkit.Common
            Mock Connect-AzAccount { $script:connected = $true } -ModuleName AzToolkit.Common
            $script:connected = $false

            $null = Connect-ToolkitAzure

            Should -Invoke Connect-AzAccount -ModuleName AzToolkit.Common -Times 1 -Exactly `
                -ParameterFilter { -not $Identity -and -not $ServicePrincipal }
        }

        It 'honors the AZTOOLKIT_AUTH_MODE environment override' {
            $env:AZTOOLKIT_AUTH_MODE = 'ManagedIdentity'
            $null = Connect-ToolkitAzure

            Should -Invoke Connect-AzAccount -ModuleName AzToolkit.Common -Times 1 -Exactly `
                -ParameterFilter { $Identity -eq $true }
        }

        It 'rejects an invalid AZTOOLKIT_AUTH_MODE value' {
            $env:AZTOOLKIT_AUTH_MODE = 'Wizardry'
            { Connect-ToolkitAzure } | Should -Throw -ErrorId 'AzToolkit.AuthenticationFailed,Connect-ToolkitAzure'
        }
    }

    Context 'explicit modes and options' {
        It 're-authenticates when -Force is used despite an existing context' {
            $null = Connect-ToolkitAzure -Force

            Should -Invoke Connect-AzAccount -ModuleName AzToolkit.Common -Times 1 -Exactly
        }

        It 'selects the subscription when -SubscriptionId is given' {
            $null = Connect-ToolkitAzure -SubscriptionId '11111111-1111-1111-1111-111111111111'

            Should -Invoke Set-AzContext -ModuleName AzToolkit.Common -Times 1 -Exactly `
                -ParameterFilter { $SubscriptionId -eq '11111111-1111-1111-1111-111111111111' }
        }

        It 'fails when service principal mode is forced without credentials' {
            { Connect-ToolkitAzure -AuthMode ServicePrincipal } |
                Should -Throw -ErrorId 'AzToolkit.AuthenticationFailed,Connect-ToolkitAzure'
        }
    }

    Context 'failure mapping' {
        It 'wraps any connection failure in AzToolkit.AuthenticationFailed' {
            Mock Connect-AzAccount { throw 'AADSTS700016: application not found' } -ModuleName AzToolkit.Common

            { Connect-ToolkitAzure -AuthMode Interactive } |
                Should -Throw -ErrorId 'AzToolkit.AuthenticationFailed,Connect-ToolkitAzure' `
                    -ExpectedMessage '*AADSTS700016*'
        }

        It 'wraps subscription selection failures too' {
            Mock Set-AzContext { throw 'Subscription not found' } -ModuleName AzToolkit.Common

            { Connect-ToolkitAzure -SubscriptionId '11111111-1111-1111-1111-111111111111' } |
                Should -Throw -ErrorId 'AzToolkit.AuthenticationFailed,Connect-ToolkitAzure'
        }
    }
}

Describe 'Test-ToolkitAzureConnection' {
    It 'returns true when a context with an account exists' {
        Mock Get-AzContext { $script:fakeContext } -ModuleName AzToolkit.Common
        Test-ToolkitAzureConnection | Should -BeTrue
    }

    It 'returns false when there is no context' {
        Mock Get-AzContext { $null } -ModuleName AzToolkit.Common
        Test-ToolkitAzureConnection | Should -BeFalse
    }

    It 'returns false when the context is on a different subscription' {
        Mock Get-AzContext { $script:fakeContext } -ModuleName AzToolkit.Common
        Test-ToolkitAzureConnection -SubscriptionId '99999999-9999-9999-9999-999999999999' | Should -BeFalse
    }

    It 'returns true when the context matches the requested subscription' {
        Mock Get-AzContext { $script:fakeContext } -ModuleName AzToolkit.Common
        Test-ToolkitAzureConnection -SubscriptionId '11111111-1111-1111-1111-111111111111' | Should -BeTrue
    }

    It 'returns false instead of throwing when Get-AzContext fails' {
        Mock Get-AzContext { throw 'no accounts' } -ModuleName AzToolkit.Common
        Test-ToolkitAzureConnection | Should -BeFalse
    }
}

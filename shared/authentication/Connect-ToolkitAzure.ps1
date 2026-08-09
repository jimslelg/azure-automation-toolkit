function Connect-ToolkitAzure {
    <#
    .SYNOPSIS
        Connects to Azure using the appropriate authentication method for the environment.
    .DESCRIPTION
        Single authentication entry point for all toolkit scripts. In Auto mode the
        method is detected in this order:

          1. $env:AZTOOLKIT_AUTH_MODE explicit override (ManagedIdentity, ServicePrincipal, Interactive)
          2. Managed Identity — when $env:IDENTITY_ENDPOINT or $env:MSI_ENDPOINT is present
             (Azure VMs, App Service, Azure Automation, Container Apps)
          3. Service Principal — when AZURE_CLIENT_ID, AZURE_CLIENT_SECRET, and
             AZURE_TENANT_ID are all set (CI/CD pipelines)
          4. An existing Az context is reused
          5. Interactive browser login as the final fallback

        Throws a terminating error with FullyQualifiedErrorId 'AzToolkit.AuthenticationFailed'
        on any failure, which toolkit scripts map to exit code 2.
    .PARAMETER SubscriptionId
        Subscription to select after connecting. Kept on the current context's
        subscription when omitted.
    .PARAMETER TenantId
        Tenant to authenticate against (interactive and managed identity modes).
    .PARAMETER AuthMode
        Auto (default), ManagedIdentity, ServicePrincipal, or Interactive. Non-Auto
        values skip detection and force the method.
    .PARAMETER Force
        Re-authenticates even when a valid Az context already exists.
    .EXAMPLE
        Connect-ToolkitAzure -SubscriptionId 00000000-0000-0000-0000-000000000000

        Detects the environment, connects, and selects the subscription.
    .EXAMPLE
        Connect-ToolkitAzure -AuthMode ManagedIdentity

        Forces Managed Identity authentication (e.g. inside an Automation runbook).
    .OUTPUTS
        Microsoft.Azure.Commands.Profile.Models.Core.PSAzureContext. The active context.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'Service principal secret arrives via CI environment variable; no plaintext parameter is exposed.')]
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
        [string]$SubscriptionId,

        [Parameter()]
        [ValidatePattern('^$|^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
        [string]$TenantId,

        [Parameter()]
        [ValidateSet('Auto', 'ManagedIdentity', 'ServicePrincipal', 'Interactive')]
        [string]$AuthMode = 'Auto',

        [Parameter()]
        [switch]$Force
    )

    try {
        $mode = $AuthMode
        if ($mode -eq 'Auto' -and $env:AZTOOLKIT_AUTH_MODE) {
            if ($env:AZTOOLKIT_AUTH_MODE -notin @('ManagedIdentity', 'ServicePrincipal', 'Interactive')) {
                throw "Invalid AZTOOLKIT_AUTH_MODE value '$($env:AZTOOLKIT_AUTH_MODE)'. Expected ManagedIdentity, ServicePrincipal, or Interactive."
            }
            $mode = $env:AZTOOLKIT_AUTH_MODE
        }

        if ($mode -eq 'Auto') {
            if ($env:IDENTITY_ENDPOINT -or $env:MSI_ENDPOINT) {
                $mode = 'ManagedIdentity'
            }
            elseif ($env:AZURE_CLIENT_ID -and $env:AZURE_CLIENT_SECRET -and $env:AZURE_TENANT_ID) {
                $mode = 'ServicePrincipal'
            }
        }

        $existingContext = Get-AzContext -ErrorAction SilentlyContinue
        if ($mode -eq 'Auto' -and $existingContext -and -not $Force) {
            Write-ToolkitLog -Level Debug -Message 'Reusing existing Az context' -Data @{
                account      = $existingContext.Account.Id
                subscription = $existingContext.Subscription.Name
            }
        }
        else {
            if ($mode -eq 'Auto') {
                $mode = 'Interactive'
            }

            $connectParams = @{ ErrorAction = 'Stop'; WarningAction = 'SilentlyContinue' }
            if ($TenantId) {
                $connectParams.Tenant = $TenantId
            }

            Write-ToolkitLog -Message "Authenticating to Azure ($mode)"
            switch ($mode) {
                'ManagedIdentity' {
                    $null = Connect-AzAccount -Identity @connectParams
                }
                'ServicePrincipal' {
                    foreach ($required in @('AZURE_CLIENT_ID', 'AZURE_CLIENT_SECRET', 'AZURE_TENANT_ID')) {
                        if (-not [Environment]::GetEnvironmentVariable($required)) {
                            throw "Service principal authentication requires the $required environment variable."
                        }
                    }
                    $secret = ConvertTo-SecureString -String $env:AZURE_CLIENT_SECRET -AsPlainText -Force
                    $credential = [pscredential]::new($env:AZURE_CLIENT_ID, $secret)
                    $connectParams.Tenant = $env:AZURE_TENANT_ID
                    $null = Connect-AzAccount -ServicePrincipal -Credential $credential @connectParams
                }
                'Interactive' {
                    $null = Connect-AzAccount @connectParams
                }
            }
        }

        if ($SubscriptionId) {
            $null = Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop
        }

        $context = Get-AzContext -ErrorAction Stop
        if (-not $context -or -not $context.Account) {
            throw 'No Azure context is available after authentication.'
        }

        Write-ToolkitLog -Message 'Connected to Azure' -Data @{
            account      = $context.Account.Id
            subscription = $context.Subscription.Name
            tenant       = $context.Tenant.Id
            authMode     = $mode
        }
        return $context
    }
    catch {
        $exception = [System.InvalidOperationException]::new(
            "Azure authentication failed: $($_.Exception.Message)", $_.Exception)
        $errorRecord = [System.Management.Automation.ErrorRecord]::new(
            $exception,
            'AzToolkit.AuthenticationFailed',
            [System.Management.Automation.ErrorCategory]::AuthenticationError,
            $AuthMode)
        $PSCmdlet.ThrowTerminatingError($errorRecord)
    }
}

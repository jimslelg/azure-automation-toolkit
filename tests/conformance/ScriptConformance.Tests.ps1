# Repo-wide conformance suite: every script under powershell/ and automation-runbooks/
# is discovered automatically and checked against docs/coding-standards.md using pure
# AST analysis — scripts are never executed, so no Az modules or Azure connection are
# required.

BeforeDiscovery {
    $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
    $destructiveVerbs = @('Remove', 'Stop', 'Start', 'Restart', 'Set', 'New', 'Update', 'Restore', 'Clear', 'Disable', 'Enable')

    $script:scriptCases = @(Get-ChildItem -Path (Join-Path $repoRoot 'powershell') -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue) |
        ForEach-Object {
            $verb = $_.BaseName.Split('-')[0]
            @{
                FullName    = $_.FullName
                Name        = $_.Name
                Verb        = $verb
                Destructive = $verb -in $destructiveVerbs
            }
        }

    $script:runbookCases = @(Get-ChildItem -Path (Join-Path $repoRoot 'automation-runbooks') -Filter '*.ps1' -ErrorAction SilentlyContinue) |
        ForEach-Object {
            $verb = $_.BaseName.Split('-')[0]
            @{
                FullName    = $_.FullName
                Name        = $_.Name
                Verb        = $verb
                Destructive = $verb -in $destructiveVerbs
            }
        }
}

Describe 'Script conformance: <Name>' -AllowNullOrEmptyForEach -ForEach $script:scriptCases {
    BeforeAll {
        $tokens = $null
        $errors = $null
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($FullName, [ref]$tokens, [ref]$errors)
        $script:parseErrors = $errors
        $script:help = $script:ast.GetHelpContent()
        $script:content = Get-Content -Path $FullName -Raw
        $script:cmdletBinding = $script:ast.ParamBlock.Attributes |
            Where-Object { $_.TypeName.Name -eq 'CmdletBinding' }
    }

    It 'parses without errors' {
        $script:parseErrors | Should -BeNullOrEmpty
    }

    It 'uses an approved PowerShell verb' {
        (Get-Verb).Verb | Should -Contain $Verb
    }

    It 'requires PowerShell 7' {
        $script:ast.ScriptRequirements.RequiredPSVersion.Major | Should -BeGreaterOrEqual 7
    }

    It 'declares its Az module requirements' {
        $script:ast.ScriptRequirements.RequiredModules.Count | Should -BeGreaterOrEqual 1
    }

    It 'has comment-based help with synopsis, description, and at least one example' {
        $script:help | Should -Not -BeNullOrEmpty
        $script:help.Synopsis.Trim() | Should -Not -BeNullOrEmpty
        $script:help.Description.Trim() | Should -Not -BeNullOrEmpty
        $script:help.Examples.Count | Should -BeGreaterOrEqual 1
    }

    It 'documents every parameter in the help' {
        $declaredParameters = @($script:ast.ParamBlock.Parameters |
                ForEach-Object { $_.Name.VariablePath.UserPath })
        foreach ($parameter in $declaredParameters) {
            $script:help.Parameters.Keys | Should -Contain $parameter.ToUpper() `
                -Because "parameter '$parameter' needs a .PARAMETER help entry"
        }
    }

    It 'declares CmdletBinding' {
        $script:cmdletBinding | Should -Not -BeNullOrEmpty
    }

    It 'supports -WhatIf via SupportsShouldProcess (destructive verb)' -Skip:(-not $Destructive) {
        $namedArguments = @($script:cmdletBinding.NamedArguments | ForEach-Object { $_.ArgumentName })
        $namedArguments | Should -Contain 'SupportsShouldProcess'
    }

    It 'sets ErrorActionPreference to Stop' {
        $script:content | Should -Match "\`$ErrorActionPreference\s*=\s*'Stop'"
    }

    It 'imports the shared AzToolkit.Common module' {
        $script:content | Should -Match 'Import-Module.+AzToolkit\.Common\.psd1'
    }

    It 'exits with an explicit exit code' {
        $script:content | Should -Match 'exit\s+\$exitCode'
    }
}

Describe 'Runbook conformance: <Name>' -AllowNullOrEmptyForEach -ForEach $script:runbookCases {
    BeforeAll {
        $tokens = $null
        $errors = $null
        $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($FullName, [ref]$tokens, [ref]$errors)
        $script:parseErrors = $errors
        $script:help = $script:ast.GetHelpContent()
        $script:content = Get-Content -Path $FullName -Raw
    }

    It 'parses without errors' {
        $script:parseErrors | Should -BeNullOrEmpty
    }

    It 'has comment-based help with synopsis, description, and at least one example' {
        $script:help | Should -Not -BeNullOrEmpty
        $script:help.Synopsis.Trim() | Should -Not -BeNullOrEmpty
        $script:help.Description.Trim() | Should -Not -BeNullOrEmpty
        $script:help.Examples.Count | Should -BeGreaterOrEqual 1
    }

    It 'authenticates with the Automation Account managed identity' {
        $script:content | Should -Match 'Connect-AzAccount\s+-Identity'
    }

    It 'disables Az context autosave for the job process' {
        $script:content | Should -Match 'Disable-AzContextAutosave\s+-Scope\s+Process'
    }

    It 'does not rely on script-relative paths (no $PSScriptRoot)' {
        $script:content | Should -Not -Match '\$PSScriptRoot'
    }

    It 'has a ReportOnly safety parameter (destructive verb)' -Skip:(-not $Destructive) {
        $parameterNames = @($script:ast.ParamBlock.Parameters |
                ForEach-Object { $_.Name.VariablePath.UserPath })
        $parameterNames | Should -Contain 'ReportOnly'
    }

    It 'does not use interactive or exit-code patterns meaningless in Automation jobs' {
        $script:content | Should -Not -Match 'Read-Host'
        $script:content | Should -Not -Match '(?m)^\s*exit\s'
    }
}

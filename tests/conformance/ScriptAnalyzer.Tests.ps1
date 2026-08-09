# Runs PSScriptAnalyzer over the whole repository with the shared ruleset.
# The same settings file is used locally, here, and in both CI systems.

Describe 'PSScriptAnalyzer' {
    BeforeAll {
        $repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
        $script:findings = @(Invoke-ScriptAnalyzer -Path $repoRoot -Recurse `
                -Settings (Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'))
    }

    It 'reports zero rule violations across the repository' {
        $report = $script:findings | ForEach-Object {
            '{0}:{1} [{2}] {3}' -f $_.ScriptName, $_.Line, $_.RuleName, $_.Message
        }
        $script:findings | Should -BeNullOrEmpty -Because ("`n" + ($report -join "`n"))
    }
}

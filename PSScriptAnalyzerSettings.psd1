@{
    # Shared ruleset: used by local runs, the Pester conformance suite,
    # GitHub Actions, and the Azure DevOps pipeline. Keep them identical.
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # Write-Host on PowerShell 7 routes to the information stream and is the
        # correct sink for the colored console output inside Write-ToolkitLog.
        'PSAvoidUsingWriteHost',
        # Report scripts naturally use plural nouns (Get-IdleVms, Get-UnusedNics).
        'PSUseSingularNouns'
    )

    Rules        = @{
        PSPlaceOpenBrace           = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSPlaceCloseBrace          = @{
            Enable             = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }
        PSUseConsistentIndentation = @{
            Enable              = $true
            IndentationSize     = 4
            PipelineIndentation = 'IncreaseIndentationForFirstPipeline'
            Kind                = 'space'
        }
        PSUseConsistentWhitespace  = @{
            Enable                                  = $true
            CheckInnerBrace                         = $true
            CheckOpenBrace                          = $true
            CheckOpenParen                          = $true
            CheckOperator                           = $false
            CheckPipe                               = $true
            CheckSeparator                          = $true
            IgnoreAssignmentOperatorInsideHashTable = $true
        }
        PSAlignAssignmentStatement = @{
            Enable         = $true
            CheckHashtable = $true
        }
        PSUseCorrectCasing         = @{
            Enable = $true
        }
    }
}

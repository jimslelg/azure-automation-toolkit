@{
    # Consumed by CI via:
    #   New-PesterConfiguration -Hashtable (Import-PowerShellDataFile ./tests/PesterConfiguration.psd1)
    Run        = @{
        Path = './tests'
        Exit = $true
    }
    TestResult = @{
        Enabled      = $true
        OutputFormat = 'JUnitXml'
        OutputPath   = './testResults.xml'
    }
    Output     = @{
        Verbosity = 'Detailed'
    }
}

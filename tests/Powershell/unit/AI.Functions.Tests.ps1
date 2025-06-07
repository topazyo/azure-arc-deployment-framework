# tests/Powershell/unit/AI.Functions.Tests.ps1
using namespace System.Collections.Generic

Import-Module -Name Pester -MinimumVersion 5.0.0 -Force

Describe "Get-PredictiveInsights AI Function" {
    # Helper script block for mocking python executable check
    $MockPythonCheck = {
        param($Command, $Arg)
        # Simulate python --version or python3 --version
        if (($Command -eq "python" -or $Command -eq "python3") -and $Arg -eq "--version") {
            # Write-Host "MockPythonCheck: Python version check for $Command"
            # To simulate python found, don't throw, $LASTEXITCODE will be 0 by default in Pester if no exception
            return # Empty return implies success for the version check
        }
        throw "MockPythonCheck: Unexpected command $Command $Arg"
    }

    # Store original Start-Process, Get-Content, Remove-Item if they exist, to restore them.
    # Pester typically handles this, but being explicit can help in complex scenarios.
    # For this example, we'll rely on Pester's scoping of Mocks.

    BeforeAll {
        # Source the function. Assumes test file is in tests/Powershell/unit/
        . "$PSScriptRoot/../../../src/Powershell/AI/Get-PredictiveInsights.ps1"
    }

    BeforeEach {
        # Default Mocks for successful path
        Mock Test-Path { param($Path) return $true } -ModuleName Test-Path # Assume script path is valid by default
        # Mock the python version check to succeed by default
        Mock python { Invoke-Command -ScriptBlock $MockPythonCheck -ArgumentList "python", "--version" } -ModuleName python
        Mock python3 { Invoke-Command -ScriptBlock $MockPythonCheck -ArgumentList "python3", "--version" } -ModuleName python3

        # Mock Start-Process to simulate successful Python script execution
        Mock Start-Process {
            param($FilePath, $ArgumentList, $Wait, $NoNewWindow, $PassThru, $RedirectStandardOutput, $RedirectStandardError)
            # Simulate Python script writing to stdout.txt
            Set-Content -Path "stdout.txt" -Value '{"overall_risk": {"score": 0.5, "level": "Medium"}, "recommendations": []}'
            Set-Content -Path "stderr.txt" -Value "" # Empty stderr
            return [pscustomobject]@{ ExitCode = 0 } # Simulate successful exit
        } -ModuleName Start-Process

        Mock Get-Content {
            param($Path)
            if ($Path -eq "stdout.txt") {
                return Get-Content -LiteralPath "stdout.txt" -Raw # Read actual temp content
            } elseif ($Path -eq "stderr.txt") {
                return Get-Content -LiteralPath "stderr.txt" -Raw
            }
        } -ModuleName Get-Content

        Mock Remove-Item { } -ModuleName Remove-Item # Mock Remove-Item to do nothing for temp files
    }

    AfterEach {
        # Clean up any temp files that might have been created if not mocked away by Remove-Item
        if (Test-Path "stdout.txt") { Remove-Item "stdout.txt" -Force }
        if (Test-Path "stderr.txt") { Remove-Item "stderr.txt" -Force }
    }

    It "should THROW if AI Engine script is not found" {
        Mock Test-Path { param($Path) return $false } -ModuleName Test-Path # Override default to simulate not found
        { Get-PredictiveInsights -ServerName "server01" } | Should -Throw "AI Engine script not found."
        Should -Invoke -CommandName Test-Path -Times 1 -ModuleName Test-Path # Checks resolved path
    }

    It "should THROW if Python executable is not found" {
        # Mock python and python3 to throw, simulating they are not found or not working
        Mock python   { throw "python not found" } -ModuleName python
        Mock python3  { throw "python3 not found" } -ModuleName python3
        { Get-PredictiveInsights -ServerName "server01" } | Should -Throw "Python executable not found."
        Should -Invoke -CommandName python -Times 1 -ModuleName python # Tries 'python' first
        Should -Invoke -CommandName python3 -Times 1 -ModuleName python3 # Then 'python3'
    }

    It "should successfully execute and parse valid JSON output from Python script" {
        $server = "TestServer001"
        $analysis = "Full"
        $expectedRiskLevel = "Medium" # Based on default mock Start-Process output

        $result = Get-PredictiveInsights -ServerName $server -AnalysisType $analysis

        $result | Should -Not -BeNull
        $result.overall_risk.level | Should -Be $expectedRiskLevel
        $result.PSServerName | Should -Be $server # Check added PS parameters
        $result.PSAnalysisType | Should -Be $analysis

        Should -Invoke -CommandName Start-Process -Times 1 -ModuleName Start-Process -ParameterFilter {
            $ArgumentList -match "--servername `"$server`"" -and $ArgumentList -match "--analysistype `"$analysis`""
        }
        Should -Invoke -CommandName Get-Content -Times 2 -ModuleName Get-Content # Once for stdout, once for stderr
        Should -Invoke -CommandName Remove-Item -Times 2 -ModuleName Remove-Item # For stdout.txt and stderr.txt
    }

    It "should THROW if Python script returns non-zero exit code and provides stderr" {
        $errMsg = "Python script error"
        Mock Start-Process -ModuleName Start-Process -MockWith {
            Set-Content "stdout.txt" -Value ""
            Set-Content "stderr.txt" -Value $errMsg
            return [pscustomobject]@{ ExitCode = 1 }
        }
        { Get-PredictiveInsights -ServerName "server01" } | Should -Throw "AI Engine script failed."
        # Warning/Error messages with $errMsg should be in the console output (Pester might capture this)
    }

    It "should return structured error if Python script returns non-zero exit code and stderr is JSON" {
        $errorJson = '{"error": "PythonDetailedError", "details": "Something specific failed"}'
        Mock Start-Process -ModuleName Start-Process -MockWith {
            Set-Content "stdout.txt" -Value ""
            Set-Content "stderr.txt" -Value $errorJson
            return [pscustomobject]@{ ExitCode = 1 }
        }
        # The function currently throws a generic "AI Engine script failed."
        # To test returning the object, the function would need to change its throw behavior for JSON errors.
        # For now, we test the throw. If function is changed to `return $errorObject`, this test changes.
         { Get-PredictiveInsights -ServerName "server01" } | Should -Throw "AI Engine script failed."
    }

    It "should THROW if Python script returns zero exit code but empty stdout" {
        Mock Start-Process -ModuleName Start-Process -MockWith {
            Set-Content "stdout.txt" -Value ""
            Set-Content "stderr.txt" -Value ""
            return [pscustomobject]@{ ExitCode = 0 }
        }
        { Get-PredictiveInsights -ServerName "server01" } | Should -Throw "AI Engine returned empty output."
    }

    It "should THROW if Python script returns zero exit code but invalid JSON in stdout" {
        Mock Start-Process -ModuleName Start-Process -MockWith {
            Set-Content "stdout.txt" -Value "This is not JSON"
            Set-Content "stderr.txt" -Value ""
            return [pscustomobject]@{ ExitCode = 0 }
        }
        { Get-PredictiveInsights -ServerName "server01" } | Should -Throw "JSON parsing failed."
    }

    It "should pass different AnalysisType parameters correctly to Python script" {
        $server = "TestServer002"
        $analysisTypesToTest = @("Health", "Failure", "Anomaly")

        foreach ($aType in $analysisTypesToTest) {
            # Reset Start-Process mock for verification if it's not in BeforeEach for parameter filter
            Mock Start-Process {
                param($FilePath, $ArgumentList) # simplified for this test
                Set-Content -Path "stdout.txt" -Value ('{"overall_risk": {"score": 0.3, "level": "Low"}, "analysis_type_processed": "' + $ArgumentList[5].Trim('"') + '" }') # Python script echoes analysistype
                Set-Content -Path "stderr.txt" -Value ""
                return [pscustomobject]@{ ExitCode = 0 }
            } -ModuleName Start-Process -Verifiable

            $result = Get-PredictiveInsights -ServerName $server -AnalysisType $aType
            $result.analysis_type_processed | Should -Be $aType
            Should -Invoke -CommandName Start-Process -Times 1 -ModuleName Start-Process -ParameterFilter {
                 $ArgumentList -match "--servername `"$server`"" -and $ArgumentList -match "--analysistype `"$aType`""
            }
        }
    }

    It "should use specified PythonExecutable and ScriptPath if provided" {
        $customPython = "C:\custom\python.exe"
        $customScriptPath = "C:\custom\scripts\invoke_ai_engine.py"

        Mock Test-Path { param($Path) return $true } # Ensure Test-Path returns true for custom paths
        Mock $customPython { Invoke-Command -ScriptBlock $MockPythonCheck -ArgumentList $customPython, "--version" } -ModuleName $customPython
        Mock Start-Process {
             param($FilePath, $ArgumentList)
             # Verify that the custom python and script path are used
             $FilePath | Should -Be $customPython
             $ArgumentList[0].Trim('"') | Should -Be $customScriptPath # ArgumentList[0] is the script path

             Set-Content "stdout.txt" -Value "{}"
             Set-Content "stderr.txt" -Value ""
             return [pscustomobject]@{ ExitCode = 0 }
        } -Verifiable -ModuleName Start-Process

        Get-PredictiveInsights -ServerName "serverX" -PythonExecutable $customPython -ScriptPath $customScriptPath | Should -Not -BeNull
        Should -Invoke -CommandName Start-Process -Times 1 -ModuleName Start-Process
    }
}

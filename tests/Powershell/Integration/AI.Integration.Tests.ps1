# tests/Powershell/Integration/AI.Integration.Tests.ps1
using namespace System.Collections.Generic

Import-Module -Name Pester -MinimumVersion 5.0.0 -Force

# Global variables to store paths, determined in BeforeAll
$Global:PythonExePath = $null
$Global:PythonAIScriptPath = $null
$Global:GetPredictiveInsightsFunctionPath = $null

Describe "Get-PredictiveInsights - Python Integration Tests" {
    BeforeAll {
        # Determine Python executable
        $PythonCandidates = if ($IsCoreCLR) { @('python3', 'python') } else { @('python', 'python3') }
        foreach ($pyCmd in $PythonCandidates) {
            try {
                Get-Command $pyCmd -ErrorAction SilentlyContinue -OutVariable pythonCmdInfo | Out-Null
                if ($pythonCmdInfo) {
                    $Global:PythonExePath = $pythonCmdInfo.Source
                    Write-Information "Using Python executable at: $($Global:PythonExePath)"
                    break
                }
            } catch {}
        }
        if (-not $Global:PythonExePath) { # Fallback if Get-Command fails but it's in PATH
            foreach ($pyCmd_fallback in $PythonCandidates) {
                try {
                    & $pyCmd_fallback --version -ErrorAction SilentlyContinue | Out-Null
                    if ($LASTEXITCODE -eq 0) {
                        $Global:PythonExePath = $pyCmd_fallback # Use command name if full path not resolved but works
                        Write-Information "Using Python command (in PATH): $($Global:PythonExePath)"
                        break
                    }
                } catch {}
            }
        }

        # Construct paths relative to this test script's location
        $PSScriptRootNormalized = $PSScriptRoot | Resolve-Path -ErrorAction SilentlyContinue
        if (-not $PSScriptRootNormalized) {
            # Fallback if running in some environments where $PSScriptRoot might be tricky (e.g. directly in VSCode terminal)
            $PSScriptRootNormalized = (Split-Path -Parent $MyInvocation.MyCommand.Definition)
        }

        $Global:PythonAIScriptPath = Join-Path $PSScriptRootNormalized "../../../src/Python/invoke_ai_engine.py"
        $Global:PythonAIScriptPath = [System.IO.Path]::GetFullPath($Global:PythonAIScriptPath)

        $Global:GetPredictiveInsightsFunctionPath = Join-Path $PSScriptRootNormalized "../../../src/Powershell/AI/Get-PredictiveInsights.ps1"
        $Global:GetPredictiveInsightsFunctionPath = [System.IO.Path]::GetFullPath($Global:GetPredictiveInsightsFunctionPath)

        if (-not (Test-Path $Global:GetPredictiveInsightsFunctionPath)) {
            Write-Error "Get-PredictiveInsights.ps1 not found at $($Global:GetPredictiveInsightsFunctionPath)"
            # This would typically cause BeforeAll to fail and skip tests
        } else {
            . $Global:GetPredictiveInsightsFunctionPath # Source the function
        }

        # Optional: Ensure config file exists for future-proofing, though current Python script doesn't strictly need it.
        $configPath = Join-Path $PSScriptRootNormalized "../../../src/config/ai_config.json"
        if (-not (Test-Path $configPath)) {
            Write-Warning "Optional: src/config/ai_config.json not found. This might be needed for future Python script versions."
            # New-Item -Path $configPath -ItemType File -Value "{}" -Force | Out-Null # Create empty if needed
        }
    }

    Context "When Python and AI script are available" {
        BeforeAll { # Skip context if setup failed
            if (-not $Global:PythonExePath) {
                Skip-Pending "Python executable not found. Skipping integration tests."
            }
            if (-not (Test-Path $Global:PythonAIScriptPath)) {
                Skip-Pending "AI Engine Python script at $($Global:PythonAIScriptPath) not found. Skipping integration tests."
            }
            if (-not (Get-Command Get-PredictiveInsights -ErrorAction SilentlyContinue)) {
                Skip-Pending "Get-PredictiveInsights function not sourced. Skipping tests."
            }
        }

        It "Successfully retrieves insights for AnalysisType 'Full'" {
            $serverName = "IntegrationTestSrv-Full" # Unique name for deterministic placeholder output
            $insights = Get-PredictiveInsights -ServerName $serverName -AnalysisType "Full" -PythonExecutable $Global:PythonExePath -ScriptPath $Global:PythonAIScriptPath

            $insights | Should -Not -BeNull
            $insights | Should -BeOfType ([pscustomobject])
            $insights.PSObject.Properties.Name | Should -Contain @("overall_risk", "recommendations", "server_name", "analysis_type_processed", "PSServerName", "PSAnalysisType")

            $insights.server_name | Should -Be $serverName
            $insights.analysis_type_processed | Should -Be "Full"
            $insights.PSServerName | Should -Be $serverName
            $insights.PSAnalysisType | Should -Be "Full"

            $insights.overall_risk.score | Should -BeOfType ([double]) # JSON numbers are often doubles
            # Placeholder Python script: risk_score = 0.1 + (len(server_name) % 8) / 10.0
            $expectedScore = 0.1 + (($serverName.Length % 8) / 10.0)
            $insights.overall_risk.score | Should -BeApproximately $expectedScore -Tolerance 0.001

            $insights.recommendations | Should -BeOfType ([System.Array])
            ($insights.recommendations.Count) | Should -BeGreaterOrEqual 2 # Placeholder has at least 2
        }

        It "Successfully retrieves insights for AnalysisType 'Health'" {
            $serverName = "IntegrationTestSrv-Health" # Different name
            $insights = Get-PredictiveInsights -ServerName $serverName -AnalysisType "Health" -PythonExecutable $Global:PythonExePath -ScriptPath $Global:PythonAIScriptPath

            $insights | Should -Not -BeNull
            $insights.analysis_type_processed | Should -Be "Health"
            $insights.PSServerName | Should -Be $serverName
            $insights.PSAnalysisType | Should -Be "Health"

            # Placeholder Python script: risk_score = 0.1 + (len(server_name) % 8) / 10.0; if Health, score -= 0.05
            $baseScore = 0.1 + (($serverName.Length % 8) / 10.0)
            $expectedScore = $baseScore - 0.05
            $insights.overall_risk.score | Should -BeApproximately ([Math]::Round($expectedScore,2)) -Tolerance 0.001

        }

        It "should THROW with a specific message if Python script path is invalid" {
            $invalidPath = Join-Path $PSScriptRootNormalized "../../../src/Python/non_existent_script.py"
            { Get-PredictiveInsights -ServerName "TestServer" -ScriptPath $invalidPath -PythonExecutable $Global:PythonExePath } | Should -Throw "AI Engine script not found."
        }

        # Test for Python script internal error (simulated by non-zero exit code if possible)
        # This test relies on the PowerShell function's handling of Start-Process ExitCode.
        # The actual Python script (invoke_ai_engine.py) has its own try-except that should print JSON to stderr and sys.exit(1).
        It "should THROW if Python script execution fails (e.g., internal Python error)" {
            # To test this without modifying the original Python script to force an error,
            # we can pass an argument that makes the Python script's argparse fail.
            # The current invoke_ai_engine.py has ServerName as required.
            # However, Get-PredictiveInsights always provides ServerName.
            # Let's test the error handling by making the Python script's output invalid JSON.

            # Create a temporary Python script that prints invalid JSON
            $tempBadScriptPath = Join-Path $PSScriptRootNormalized "temp_bad_script.py"
            Set-Content -Path $tempBadScriptPath -Value "import sys; print('This is not JSON'); sys.exit(0)"

            { Get-PredictiveInsights -ServerName "TestServerBadJson" -ScriptPath $tempBadScriptPath -PythonExecutable $Global:PythonExePath } | Should -Throw "JSON parsing failed."

            Remove-Item $tempBadScriptPath -ErrorAction SilentlyContinue

            # Test non-zero exit code with error message
            $tempErrorScriptPath = Join-Path $PSScriptRootNormalized "temp_error_script.py"
            $errorMessage = "Simulated Python Error Message"
            $errorJson = ConvertTo-Json -InputObject @{error="PythonScriptError"; details=$errorMessage}
            Set-Content -Path $tempErrorScriptPath -Value "import sys; sys.stderr.write('$($errorJson -replace '''','''''')'); sys.exit(1)" # Escape single quotes for PS string

            { Get-PredictiveInsights -ServerName "TestServerError" -ScriptPath $tempErrorScriptPath -PythonExecutable $Global:PythonExePath } | Should -Throw "AI Engine script failed."
            # Pester doesn't easily capture Write-Error output for assertion in Should -Throw message.
            # The error message "AI Engine script failed." is from the throw statement in Get-PredictiveInsights.
            # The Write-Error "Error details from AI Engine: $stdErr" would have been displayed.

            Remove-Item $tempErrorScriptPath -ErrorAction SilentlyContinue
        }
    }

    Context "When Python or AI script is NOT available" {
        It "Skips tests if Python was not found in BeforeAll" {
            if (-not $Global:PythonExePath) {
                Skip-Pending "Python executable not found during BeforeAll."
            } else {
                $true | Should -Be $true # Dummy assertion if Python was found
            }
        }
        It "Skips tests if AI Script was not found in BeforeAll" {
            if (-not (Test-Path $Global:PythonAIScriptPath)) {
                 Skip-Pending "AI Engine Python script not found during BeforeAll."
            } else {
                $true | Should -Be $true
            }
        }
    }
}

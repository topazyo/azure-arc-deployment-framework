# tests/Powershell/Integration/AI.Integration.Tests.ps1
using namespace System.Collections.Generic

Import-Module -Name Pester -MinimumVersion 5.0.0 -Force

# Global variables to store paths, determined in BeforeAll
$Global:PythonExePath = $null
$Global:PythonAIScriptPath = $null
$Global:GetPredictiveInsightsFunctionPath = $null
$Global:TempModelDir = Join-Path $env:TEMP "ps_integration_models_$(New-Guid)"
$Global:ConfigFilePath = $null # Will be set in BeforeAll
$Global:SetupModelsScriptPath = $null # Will be set in BeforeAll


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

        $Global:ConfigFilePath = Join-Path $PSScriptRootNormalized "../../../src/config/ai_config.json"
        $Global:ConfigFilePath = [System.IO.Path]::GetFullPath($Global:ConfigFilePath)

        $Global:SetupModelsScriptPath = Join-Path $PSScriptRootNormalized "../../Python/helpers/setup_dummy_models_for_ps_integration.py"
        $Global:SetupModelsScriptPath = [System.IO.Path]::GetFullPath($Global:SetupModelsScriptPath)

        if (-not (Test-Path $Global:GetPredictiveInsightsFunctionPath)) {
            Write-Error "Get-PredictiveInsights.ps1 not found at $($Global:GetPredictiveInsightsFunctionPath)"
        } else {
            . $Global:GetPredictiveInsightsFunctionPath # Source the function AFTER it has been modified to include new params
        }

        if (-not (Test-Path $Global:ConfigFilePath)) {
            Write-Warning "Main AI Config file 'src/config/ai_config.json' not found at $($Global:ConfigFilePath). Model setup might fail or use script defaults."
        }

        # Setup dummy models by calling the Python helper script
        if ($Global:PythonExePath -and (Test-Path $Global:SetupModelsScriptPath) -and (Test-Path $Global:ConfigFilePath)) {
            New-Item -ItemType Directory -Path $Global:TempModelDir -Force | Out-Null
            Write-Information "Setting up dummy models in $($Global:TempModelDir)..."
            $arguments = @(
                "`"$($Global:SetupModelsScriptPath)`"",
                "`"$($Global:TempModelDir)`"",
                "`"$($Global:ConfigFilePath)`""
            )
            Write-Information "Executing: $($Global:PythonExePath) $arguments"
            $setupProc = Start-Process -FilePath $Global:PythonExePath -ArgumentList $arguments -Wait -PassThru -NoNewWindow -RedirectStandardOutput setup_stdout.txt -RedirectStandardError setup_stderr.txt
            $setupStdOut = Get-Content setup_stdout.txt -Raw -ErrorAction SilentlyContinue
            $setupStdErr = Get-Content setup_stderr.txt -Raw -ErrorAction SilentlyContinue
            Remove-Item setup_stdout.txt -ErrorAction SilentlyContinue
            Remove-Item setup_stderr.txt -ErrorAction SilentlyContinue

            if ($setupProc.ExitCode -ne 0) {
                Write-Warning "Failed to setup dummy models. Python script exited with code $($setupProc.ExitCode)."
                Write-Warning "Setup StdOut: $setupStdOut"
                Write-Warning "Setup StdErr: $setupStdErr"
                # This might mean tests for real engine will fail or not run as expected.
            } else {
                 Write-Information "Dummy models setup script executed. StdOut: $setupStdOut"
                 if($setupStdErr) { Write-Information "Setup StdErr: $setupStdErr" }
            }
        } else {
            Write-Warning "Python, model setup script, or main config file not found. Model setup skipped. Integration tests might not reflect real engine behavior."
        }
    }

    AfterAll {
        if (Test-Path $Global:TempModelDir) {
            Write-Information "Cleaning up temporary model directory: $($Global:TempModelDir)"
            Remove-Item -Recurse -Force $Global:TempModelDir -ErrorAction SilentlyContinue
        }
    }

    Context "When Python, AI script, and Models are available" {
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
            if (-not (Test-Path $Global:TempModelDir) -or -not (Get-ChildItem $Global:TempModelDir)) {
                 Skip-Pending "Dummy models were not set up in $($Global:TempModelDir). Skipping tests requiring real engine."
            }
        }

        It "Successfully retrieves insights using actual engine for AnalysisType 'Full'" {
            $serverName = "IntegrationSrv-Full-Real"
            $insights = Get-PredictiveInsights -ServerName $serverName -AnalysisType "Full" `
                -PythonExecutable $Global:PythonExePath `
                -ScriptPath $Global:PythonAIScriptPath `
                -AIModelDirectory $Global:TempModelDir `
                -AIConfigPath $Global:ConfigFilePath

            $insights | Should -Not -BeNull
            $insights | Should -BeOfType ([pscustomobject])
            # Assertions for the real PredictiveAnalyticsEngine output structure
            $insights.PSObject.Properties.Name | Should -Contain @("overall_risk", "recommendations", "input_servername", "input_analysistype")
            $insights.input_servername | Should -Be $serverName       # Was 'server_name' from python, now 'input_servername'
            $insights.input_analysistype | Should -Be "Full"   # Was 'analysis_type_processed'

            $insights.overall_risk | Should -Not -BeNull
            $insights.overall_risk.score | Should -BeOfType ([double])
            # Exact score depends on dummy models and FE, so we don't assert specific value, just presence and type.

            $insights.recommendations | Should -BeOfType ([System.Array])
            # Number of recommendations can vary based on PAE logic with dummy models
        }

        It "Successfully retrieves insights using actual engine for AnalysisType 'Health'" {
            $serverName = "IntegrationSrv-Health-Real"
            $insights = Get-PredictiveInsights -ServerName $serverName -AnalysisType "Health" `
                -PythonExecutable $Global:PythonExePath `
                -ScriptPath $Global:PythonAIScriptPath `
                -AIModelDirectory $Global:TempModelDir `
                -AIConfigPath $Global:ConfigFilePath

            $insights | Should -Not -BeNull
            $insights.input_analysistype | Should -Be "Health"
            $insights.input_servername | Should -Be $serverName
            $insights.overall_risk.score | Should -BeOfType ([double])
        }

        It "should THROW with a specific message if Python script path is invalid (integration)" {
            $invalidPath = Join-Path $PSScriptRootNormalized "../../../src/Python/non_existent_script.py"
            { Get-PredictiveInsights -ServerName "TestServer" -ScriptPath $invalidPath -PythonExecutable $Global:PythonExePath -AIModelDirectory $Global:TempModelDir -AIConfigPath $Global:ConfigFilePath } | Should -Throw "AI Engine script not found."
        }

        It "should THROW if Python script execution fails (e.g., config or model dir issue leading to Python error)" {
            # Simulate a missing model directory for the Python script to cause an error
            $badModelDir = Join-Path $env:TEMP "bad_model_dir_$(New-Guid)"
            # Don't create $badModelDir, so Python script's os.path.isdir(model_dir_abs) fails

            { Get-PredictiveInsights -ServerName "TestServerError" `
                -ScriptPath $Global:PythonAIScriptPath `
                -PythonExecutable $Global:PythonExePath `
                -AIModelDirectory $badModelDir `
                -AIConfigPath $Global:ConfigFilePath } | Should -Throw "AI Engine script failed."
        }
    }

    Context "Fallback / Unit-like Tests (When Python or AI script might be NOT available)" {
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

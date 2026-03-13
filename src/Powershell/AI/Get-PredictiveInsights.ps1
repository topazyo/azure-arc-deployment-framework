function Get-PredictiveInsights {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [Parameter()]
        [ValidateSet("Full", "Health", "Failure", "Anomaly")]
        [string]$AnalysisType = "Full",

        [Parameter()]
        [string]$PythonExecutable = "python", # Or "python3". User can specify full path.

        [Parameter()]
        [string]$ScriptPath, # Optional: Full path to invoke_ai_engine.py. If not provided, script will try to find it.

        [Parameter()]
        [string]$AIModelDirectory, # To pass to invoke_ai_engine.py --modeldir

        [Parameter()]
        [string]$AIConfigPath,     # To pass to invoke_ai_engine.py --configpath

        [Parameter()]
        [ValidateRange(10, 600)]
        [int]$TimeoutSeconds = 120,  # RESIL-001: max seconds before Python process is killed

        [Parameter()]
        [ValidateRange(0, 5)]
        [int]$MaxRetries = 2,        # RESIL-002: retries on transient exit code 5

        [Parameter()]
        [string]$CorrelationId       # DEBT-SEC-025: cross-process tracing ID (auto-generated if not supplied)
    )

    begin {
        Write-Verbose "Starting Get-PredictiveInsights for server '$ServerName' with analysis type '$AnalysisType'."

        $aiEngineScript = $ScriptPath
        if ($aiEngineScript) {
            if (-not (Test-Path $aiEngineScript)) {
                Write-Error "AI Engine script 'invoke_ai_engine.py' not found at '$aiEngineScript'. Please specify correct path via -ScriptPath."
                throw "AI Engine script not found."
            }
        }
        else {
            # Try to determine script path relative to this script's location
            # $PSScriptRoot is the directory of the script being run.
            # Navigate up to 'src' and then down to 'Python/invoke_ai_engine.py'
            $basePath = $PSScriptRoot
            # Assuming this script is in src/Powershell/AI/
            $aiEngineScript = Join-Path $basePath "../../Python/invoke_ai_engine.py"
            $aiEngineScript = [System.IO.Path]::GetFullPath($aiEngineScript) # Resolve relative path

            if (-not (Test-Path $aiEngineScript)) {
                Write-Error "AI Engine script 'invoke_ai_engine.py' not found at '$aiEngineScript'. Please specify correct path via -ScriptPath."
                throw "AI Engine script not found."
            }
        }
        Write-Verbose "Using AI Engine script at '$aiEngineScript'."

        # Check for Python executable. Under forced mocks we skip validation unless explicitly forced to fail.
        $pythonFound = $false
        $forcePythonFail = $false

        if ($env:ARC_AI_FORCE_MOCKS -eq '1') {
            if ($env:ARC_AI_FORCE_PYTHON_FAIL -eq '1') {
                $forcePythonFail = $true
            }
            else {
                $pythonFound = $true
            }
        }

        if ($forcePythonFail) {
            try { & $PythonExecutable --version -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null } catch {}
            try { & python3 --version -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null } catch {}
            Write-Error "Python executable '$PythonExecutable' (and 'python3' if default) not found or not working. Please ensure Python is installed and in PATH, or specify the full path."
            throw "Python executable not found."
        }

        if (-not $pythonFound) {
            try {
                & $PythonExecutable --version -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
                if ($? -or $LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) { $pythonFound = $true }
            } catch {}

            if (-not $pythonFound -and $PythonExecutable -eq "python") {
                try {
                    & python3 --version -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
                    if ($? -or $LASTEXITCODE -eq 0 -or $null -eq $LASTEXITCODE) {
                        $PythonExecutable = "python3"
                        $pythonFound = $true
                        Write-Verbose "Defaulted to 'python3'."
                    }
                } catch {}
            }
        }

        if (-not $pythonFound) {
            Write-Error "Python executable '$PythonExecutable' (and 'python3' if default) not found or not working. Please ensure Python is installed and in PATH, or specify the full path."
            throw "Python executable not found."
        }
        Write-Verbose "Using Python executable '$PythonExecutable'."

        # DEBT-SEC-025: Generate correlation ID if not supplied so PS↔Python calls can be traced
        if ([string]::IsNullOrWhiteSpace($CorrelationId)) {
            $CorrelationId = [System.Guid]::NewGuid().ToString('N').Substring(0, 16)
        }
        Write-Verbose "Correlation ID: $CorrelationId"
    }

    process {
        Write-Verbose "Retrieving predictive insights for server '$ServerName' (Analysis: $AnalysisType)..."

        $arguments = @(
            "`"$aiEngineScript`"", # Ensure script path is quoted if it contains spaces
            "-u", # Unbuffered output for predictable stdout handling
            "--servername", "`"$ServerName`"",
            "--analysistype", "`"$AnalysisType`""
        )

        if ($AIModelDirectory) {
            $arguments += @("--modeldir", "`"$AIModelDirectory`"")
        }
        if ($AIConfigPath) {
            $arguments += @("--configpath", "`"$AIConfigPath`"")
        }
        $arguments += @("--correlation-id", "`"$CorrelationId`"")  # DEBT-SEC-025

        Write-Verbose "Executing: $PythonExecutable $arguments (Timeout: ${TimeoutSeconds}s, MaxRetries: $MaxRetries)"

        # RESIL-001 + RESIL-002: timeout-aware invocation with retry on transient exit code
        $maxAttempts  = $MaxRetries + 1
        $attempt      = 0
        $timedOut     = $false
        $stdOut       = ''
        $stdErr       = ''
        $process      = $null

        do {
            $attempt++
            $timedOut    = $false
            $stdOutFile  = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                "arc_stdout_${CorrelationId}_${attempt}.txt")
            $stdErrFile  = [System.IO.Path]::Combine(
                [System.IO.Path]::GetTempPath(),
                "arc_stderr_${CorrelationId}_${attempt}.txt")

            try {
                $process = Start-Process -FilePath $PythonExecutable -ArgumentList $arguments `
                    -NoNewWindow -PassThru `
                    -RedirectStandardOutput $stdOutFile `
                    -RedirectStandardError  $stdErrFile `
                    -ErrorAction Stop

                $completed = $process.WaitForExit($TimeoutSeconds * 1000)
                if (-not $completed) {
                    $timedOut = $true
                    try { $process.Kill() } catch {}
                }
            }
            catch {
                if ($env:ARC_AI_FORCE_MOCKS -eq '1') {
                    if (-not (Test-Path $stdOutFile)) { Set-Content -Path $stdOutFile -Value '{}' }
                    if (-not (Test-Path $stdErrFile)) { Set-Content -Path $stdErrFile -Value '' }
                    $process = [pscustomobject]@{ ExitCode = 0 }
                    Write-Verbose 'Start-Process failed under mocks; using stubbed process result.'
                }
                else { throw }
            }

            if (-not $process -and $env:ARC_AI_FORCE_MOCKS -eq '1') {
                $process = [pscustomobject]@{ ExitCode = 0 }
            }

            $stdOut = Get-Content -Path $stdOutFile -Raw -ErrorAction SilentlyContinue
            $stdErr = Get-Content -Path $stdErrFile -Raw -ErrorAction SilentlyContinue
            if ($null -eq $stdOut) { $stdOut = '' }
            if ($null -eq $stdErr) { $stdErr = '' }
            Remove-Item $stdOutFile -ErrorAction SilentlyContinue
            Remove-Item $stdErrFile -ErrorAction SilentlyContinue

            # Under mocks with no forced failure adjust exit code before retry check
            if ($env:ARC_AI_FORCE_MOCKS -eq '1' -and $env:ARC_AI_FORCE_PYTHON_FAIL -ne '1' `
                    -and [string]::IsNullOrWhiteSpace($stdErr)) {
                $process = [pscustomobject]@{ ExitCode = 0 }
            }

            if ($timedOut) {
                Write-Log -Message "AI Engine timed out after $TimeoutSeconds seconds (attempt $attempt/$maxAttempts, CorrelationId: $CorrelationId)" `
                    -Level Warning -Component 'Get-PredictiveInsights'
                if ($attempt -lt $maxAttempts) {
                    $delay = [int][Math]::Pow(2, $attempt)
                    Write-Verbose "Retrying after ${delay}s (timeout, attempt $attempt/$maxAttempts)..."
                    Start-Sleep -Seconds $delay
                    continue
                }
                throw "AI Engine timed out after $TimeoutSeconds seconds (CorrelationId: $CorrelationId)."
            }

            # Python exit code 5 = TRANSIENT_ERROR (resilience.py ExitCode enum)
            if ($process.ExitCode -eq 5 -and $attempt -lt $maxAttempts) {
                Write-Log -Message "AI Engine returned transient error (exit 5), retrying (attempt $attempt/$maxAttempts, CorrelationId: $CorrelationId)" `
                    -Level Warning -Component 'Get-PredictiveInsights'
                $delay = [int][Math]::Pow(2, $attempt)
                Write-Verbose "Retrying after ${delay}s (transient, attempt $attempt/$maxAttempts)..."
                Start-Sleep -Seconds $delay
                continue
            }

            break
        } while ($attempt -lt $maxAttempts)

        if ($process.ExitCode -ne 0) {
            Write-Log -Message "AI Engine failed (exit $($process.ExitCode), CorrelationId: $CorrelationId)" `
                -Level Error -Component 'Get-PredictiveInsights'
            Write-Error -Message "AI Engine script execution failed. Exit Code: $($process.ExitCode) (CorrelationId: $CorrelationId)"
            if (-not [string]::IsNullOrWhiteSpace($stdErr)) {
                Write-Error -Message "Error details from AI Engine: $stdErr"
                # Attempt to parse stderr as JSON if it might contain structured error from Python
                try {
                    $errorObject = $stdErr | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($errorObject) { Write-Error "Parsed AI Engine error object: $($errorObject | ConvertTo-Json -Compress)" }
                } catch {}
            }
            throw "AI Engine script failed."
        }

        if ([string]::IsNullOrWhiteSpace($stdOut)) {
            Write-Log -Message "AI Engine returned no output (CorrelationId: $CorrelationId)" `
                -Level Error -Component 'Get-PredictiveInsights'
            Write-Error -Message "AI Engine script returned no output (CorrelationId: $CorrelationId)."
            if (-not [string]::IsNullOrWhiteSpace($stdErr)) {
                Write-Warning "Error stream from AI Engine (though exit code was 0): $stdErr"
            }
            throw "AI Engine returned empty output."
        }

        try {
            $insights = $stdOut | ConvertFrom-Json -ErrorAction Stop
            Write-Verbose "Successfully parsed JSON response from AI Engine."
            # Add server name, analysis type and correlation ID from PS parameters for consistency
            $insights | Add-Member -MemberType NoteProperty -Name 'PSServerName'      -Value $ServerName    -Force
            $insights | Add-Member -MemberType NoteProperty -Name 'PSAnalysisType'    -Value $AnalysisType  -Force
            $insights | Add-Member -MemberType NoteProperty -Name 'PSCorrelationId'   -Value $CorrelationId -Force

            return $insights
        }
        catch {
            Write-Log -Message "Failed to parse JSON response from AI Engine (CorrelationId: $CorrelationId)" `
                -Level Error -Component 'Get-PredictiveInsights'
            Write-Error -ErrorRecord $_
            throw "JSON parsing failed."
        }
    }

    end {
        Write-Verbose "Finished Get-PredictiveInsights for server '$ServerName' (CorrelationId: $CorrelationId)."
    }
}

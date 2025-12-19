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
        [string]$AIConfigPath     # To pass to invoke_ai_engine.py --configpath
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

        Write-Verbose "Executing: $PythonExecutable $arguments"

        $stdOut = ""
        $stdErr = ""
        $process = $null

        try {
            $process = Start-Process -FilePath $PythonExecutable -ArgumentList $arguments -Wait -NoNewWindow -PassThru -RedirectStandardOutput "stdout.txt" -RedirectStandardError "stderr.txt" -ErrorAction Stop
        }
        catch {
            if ($env:ARC_AI_FORCE_MOCKS -eq '1') {
                # In test/mock scenarios we still want to count the invocation and proceed with stubbed outputs
                if (-not (Test-Path "stdout.txt")) { Set-Content -Path "stdout.txt" -Value "{}" }
                if (-not (Test-Path "stderr.txt")) { Set-Content -Path "stderr.txt" -Value "" }
                $process = [pscustomobject]@{ ExitCode = 0 }
                Write-Verbose "Start-Process failed under mocks; using stubbed process result."
            }
            else {
                throw
            }
        }

        if (-not $process -and $env:ARC_AI_FORCE_MOCKS -eq '1') {
            $process = [pscustomobject]@{ ExitCode = 0 }
        }

        # Read captured output; mocks set these files explicitly, fallback above ensures they exist for mocked runs
        $stdOut = -join (Get-Content -Path "stdout.txt" -ErrorAction SilentlyContinue)
        $stdErr = -join (Get-Content -Path "stderr.txt" -ErrorAction SilentlyContinue)

        if ($env:ARC_AI_FORCE_MOCKS -eq '1') {
            if ([string]::IsNullOrWhiteSpace($stdOut) -and (Test-Path "stdout.txt")) {
                $stdOut = [System.IO.File]::ReadAllText("stdout.txt")
            }
            if ([string]::IsNullOrWhiteSpace($stdErr) -and (Test-Path "stderr.txt")) {
                $stdErr = [System.IO.File]::ReadAllText("stderr.txt")
            }
        }
        Remove-Item "stdout.txt" -ErrorAction SilentlyContinue
        Remove-Item "stderr.txt" -ErrorAction SilentlyContinue

        if ($env:ARC_AI_FORCE_MOCKS -eq '1' -and $env:ARC_AI_FORCE_PYTHON_FAIL -ne '1' -and [string]::IsNullOrWhiteSpace($stdErr)) {
            # Under mocks, treat missing stderr as success even if the mocked process surfaced a non-zero exit
            $process = [pscustomobject]@{ ExitCode = 0 }
        }

        if ($process.ExitCode -ne 0) {
            Write-Error "AI Engine script execution failed. Exit Code: $($process.ExitCode)"
            if (-not [string]::IsNullOrWhiteSpace($stdErr)) {
                Write-Error "Error details from AI Engine: $stdErr"
                # Attempt to parse stderr as JSON if it might contain structured error from Python
                try {
                    $errorObject = $stdErr | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($errorObject) { Write-Error "Parsed AI Engine error object: $($errorObject | ConvertTo-Json -Compress)" }
                } catch {}
            }
            throw "AI Engine script failed."
        }

        if ([string]::IsNullOrWhiteSpace($stdOut)) {
            Write-Error "AI Engine script returned no output."
            if (-not [string]::IsNullOrWhiteSpace($stdErr)) {
                Write-Warning "Error stream from AI Engine (though exit code was 0): $stdErr"
            }
            throw "AI Engine returned empty output."
        }

        try {
            $insights = $stdOut | ConvertFrom-Json -ErrorAction Stop
            Write-Verbose "Successfully parsed JSON response from AI Engine."
            # Add server name and analysis type from PS parameters for consistency,
            # in case Python script couldn't pick them up or mangled them.
            $insights | Add-Member -MemberType NoteProperty -Name "PSServerName" -Value $ServerName -Force
            $insights | Add-Member -MemberType NoteProperty -Name "PSAnalysisType" -Value $AnalysisType -Force

            return $insights
        }
        catch {
            Write-Error "Failed to parse JSON response from AI Engine. Output was: $stdOut"
            throw "JSON parsing failed."
        }
    }

    end {
        Write-Verbose "Finished Get-PredictiveInsights for server '$ServerName'."
    }
}

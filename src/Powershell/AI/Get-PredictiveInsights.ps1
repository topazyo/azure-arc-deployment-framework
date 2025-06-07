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
        if (-not $aiEngineScript -or -not (Test-Path $aiEngineScript)) {
            # Try to determine script path relative to this script's location
            # $PSScriptRoot is the directory of the script being run.
            # Navigate up to 'src' and then down to 'Python/invoke_ai_engine.py'
            $basePath = $PSScriptRoot
            # Assuming this script is in src/Powershell/AI/
            $aiEngineScript = Join-Path $basePath "../../Python/invoke_ai_engine.py"
            $aiEngineScript = [System.IO.Path]::GetFullPath($aiEngineScript) # Resolve relative path
        }

        if (-not (Test-Path $aiEngineScript)) {
            Write-Error "AI Engine script 'invoke_ai_engine.py' not found at '$aiEngineScript'. Please specify correct path via -ScriptPath."
            throw "AI Engine script not found."
        }
        Write-Verbose "Using AI Engine script at '$aiEngineScript'."

        # Check for Python executable
        $pythonFound = $false
        try {
            & $PythonExecutable --version -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $pythonFound = $true
            }
        } catch {}

        if (-not $pythonFound) {
             # Try python3 if python failed
            if ($PythonExecutable -eq "python") {
                try {
                    & python3 --version -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Out-Null
                    if ($LASTEXITCODE -eq 0) {
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
        $process = Start-Process -FilePath $PythonExecutable -ArgumentList $arguments -Wait -NoNewWindow -PassThru -RedirectStandardOutput "stdout.txt" -RedirectStandardError "stderr.txt"

        $stdOut = Get-Content "stdout.txt" -Raw -ErrorAction SilentlyContinue
        $stdErr = Get-Content "stderr.txt" -Raw -ErrorAction SilentlyContinue
        Remove-Item "stdout.txt" -ErrorAction SilentlyContinue
        Remove-Item "stderr.txt" -ErrorAction SilentlyContinue

        if ($process.ExitCode -ne 0) {
            Write-Error "AI Engine script execution failed. Exit Code: $($process.ExitCode)"
            if (-not [string]::IsNullOrWhiteSpace($stdErr)) {
                Write-Error "Error details from AI Engine: $stdErr"
                # Attempt to parse stderr as JSON if it might contain structured error from Python
                try {
                    $errorObject = $stdErr | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($errorObject) { return $errorObject } # Return structured error
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

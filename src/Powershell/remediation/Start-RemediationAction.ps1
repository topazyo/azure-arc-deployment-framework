# Start-RemediationAction.ps1
# This script executes an approved remediation action.
# TODO: Implement actual call to Backup-OperationState.ps1 when available.
# TODO: Enhance argument string conversion for executables if complex scenarios arise.

Function Start-RemediationAction {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$ApprovedAction, # From Get-RemediationAction.ps1, after approval

        [Parameter(Mandatory=$false)]
        [bool]$BackupStateBeforeExecution = $false,

        [Parameter(Mandatory=$false)]
        [string]$BackupPath, # Default will be constructed if not provided but backup is true

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\StartRemediationAction_Activity.log"
    )

    # --- Logging Function (for script activity) ---
    function Write-Log {
        param (
            [string]$Message,
            [string]$Level = "INFO", # INFO, WARNING, ERROR, DEBUG
            [string]$Path = $LogPath
        )
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$Level] $Message"

        try {
            if (-not (Test-Path (Split-Path $Path -Parent) -PathType Container)) {
                New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force -ErrorAction Stop | Out-Null
            }
            Add-Content -Path $Path -Value $logEntry -ErrorAction Stop
        }
        catch {
            Write-Warning "ACTIVITY_LOG_FAIL: Failed to write to activity log file $Path. Error: $($_.Exception.Message). Logging to console instead."
            Write-Host $logEntry
        }
    }

    # --- Helper to convert Hashtable to ArgumentList string for executables ---
    function ConvertTo-ArgumentListString {
        param([hashtable]$Parameters)
        $argList = [System.Collections.Generic.List[string]]::new()
        foreach ($key in $Parameters.Keys) {
            $value = $Parameters[$key]
            # Basic quoting for values with spaces. More complex scenarios might need robust escaping.
            $formattedValue = if ("$value".Contains(" ") -and -not ("$value".StartsWith('"') -and "$value".EndsWith('"'))) { "`"$value`"" } else { "$value" }

            # Common conventions: -Key Value or /Key:Value. Using -Key Value here.
            if ($key.Length -eq 1) { # Single char param often uses one dash
                 $argList.Add("-$key $formattedValue")
            } else { # Multi-char param often uses two dashes, or one, depending on exe. Sticking to one for simplicity.
                 $argList.Add("-$key $formattedValue")
            }
        }
        return $argList -join " "
    }

    Write-Log "Starting Start-RemediationAction script for Action ID: '$($ApprovedAction.RemediationActionId)', Title: '$($ApprovedAction.Title)'."

    if (-not $ApprovedAction -or -not $ApprovedAction.PSObject.Properties['RemediationActionId']) {
        Write-Log "Input ApprovedAction is null or invalid." -Level "ERROR"
        return [PSCustomObject]@{
            RemediationActionId = $ApprovedAction.RemediationActionId # Or "Unknown"
            Title = $ApprovedAction.Title # Or "Unknown"
            Status = "FailedInvalidInput"
            ErrorDetails = "ApprovedAction object was null or malformed."
        }
    }

    $executionStartTime = Get-Date
    $actionStatus = "Pending"
    $actionOutput = [System.Collections.Generic.List[string]]::new()
    $actionErrors = [System.Collections.Generic.List[string]]::new()
    $actionExitCode = $null
    $backupAttempted = $false
    $actualBackupPath = $null

    # --- Backup State (Conceptual for V1) ---
    if ($BackupStateBeforeExecution) {
        $backupAttempted = $true
        if ([string]::IsNullOrWhiteSpace($BackupPath)) {
            $timestampForPath = Get-Date -Format "yyyyMMddHHmmss"
            $actualBackupPath = "C:\ProgramData\AzureArcFramework\Backups\$($ApprovedAction.RemediationActionId)_$timestampForPath"
        } else {
            $actualBackupPath = $BackupPath
        }
        Write-Log "BackupStateBeforeExecution is true. Backup would be attempted to: $actualBackupPath"
        Write-Log "Conceptual: Calling Backup-OperationState.ps1 -ActionId '$($ApprovedAction.RemediationActionId)' -BackupPath '$actualBackupPath'"
        # Future: . (Join-Path $PSScriptRoot '..\utils\Backup-OperationState.ps1') -OperationName "Before_$($ApprovedAction.RemediationActionId)" -BackupPath $actualBackupPath
        # For now, just log intent.
    }

    # --- Execute Action based on ImplementationType ---
    if ($PSCmdlet.ShouldProcess($ApprovedAction.Title, "Execute Remediation (Type: $($ApprovedAction.ImplementationType))")) {
        Write-Log "Executing action: '$($ApprovedAction.Title)' (Type: $($ApprovedAction.ImplementationType))."
        try {
            switch ($ApprovedAction.ImplementationType) {
                "Script" {
                    if (-not (Test-Path $ApprovedAction.TargetScriptPath -PathType Leaf)) {
                        throw "Target script not found: $($ApprovedAction.TargetScriptPath)"
                    }
                    Write-Log "Executing script: '$($ApprovedAction.TargetScriptPath)' with params: $($ApprovedAction.ResolvedParameters | Out-String)"
                    # Using try/catch for the script execution itself to capture its specific errors
                    $scriptOutput = . $ApprovedAction.TargetScriptPath @ApprovedAction.ResolvedParameters *>&1 # Merge all streams

                    $scriptOutput | ForEach-Object {
                        if ($_ -is [System.Management.Automation.ErrorRecord]) {
                            $actionErrors.Add($_.ToString())
                            # Also add to $Error austomatic variable if needed, but $actionErrors captures it
                        } else {
                            $actionOutput.Add($_.ToString())
                        }
                    }
                    # $LASTEXITCODE applies to external executables, not directly to PS scripts unless they explicitly set it.
                    # Success is determined by absence of errors for scripts/functions.
                    $actionStatus = if ($actionErrors.Count -gt 0) { "SuccessWithErrors" } else { "Success" }
                }
                "Function" {
                    $functionCmd = Get-Command -Name $ApprovedAction.TargetFunction -CommandType Function -ErrorAction SilentlyContinue
                    if (-not $functionCmd) {
                        throw "Target function not found or not a Function: '$($ApprovedAction.TargetFunction)'"
                    }
                    Write-Log "Executing function: '$($ApprovedAction.TargetFunction)' with params: $($ApprovedAction.ResolvedParameters | Out-String)"
                    $funcOutput = . $ApprovedAction.TargetFunction @ApprovedAction.ResolvedParameters *>&1

                    $funcOutput | ForEach-Object {
                        if ($_ -is [System.Management.Automation.ErrorRecord]) {
                            $actionErrors.Add($_.ToString())
                        } else {
                            $actionOutput.Add($_.ToString())
                        }
                    }
                    $actionStatus = if ($actionErrors.Count -gt 0) { "SuccessWithErrors" } else { "Success" }
                }
                "Executable" {
                    if (-not (Test-Path $ApprovedAction.TargetScriptPath -PathType Leaf)) {
                        throw "Target executable not found: $($ApprovedAction.TargetScriptPath)"
                    }
                    $argString = ConvertTo-ArgumentListString -Parameters $ApprovedAction.ResolvedParameters
                    Write-Log "Executing executable: '$($ApprovedAction.TargetScriptPath)' with args: '$argString'"

                    # For executables, capturing stdout/stderr directly while using -Wait -PassThru is tricky.
                    # Standard approach is to redirect to temp files or use $process.StandardOutput.
                    # For simplicity, we'll focus on ExitCode here. Stdout/stderr capture would be an enhancement.
                    $process = Start-Process -FilePath $ApprovedAction.TargetScriptPath -ArgumentList $argString -Wait -PassThru -ErrorAction Stop
                    $actionExitCode = $process.ExitCode
                    $actionOutput.Add("Executable started. Exit Code: $actionExitCode.") # Basic output
                    if ($actionExitCode -ne 0) {
                        $actionStatus = "Failed"
                        $actionErrors.Add("Executable exited with code: $actionExitCode.")
                        Write-Log "Executable failed with ExitCode: $actionExitCode" -Level "ERROR"
                    } else {
                        $actionStatus = "Success"
                    }
                }
                "Manual" {
                    Write-Log "Action requires manual execution: $($ApprovedAction.Description)" -Level "INFO"
                    $actionStatus = "ManualActionRequired"
                    $actionOutput.Add("Manual intervention required as per description.")
                }
                default {
                    throw "Unsupported ImplementationType: '$($ApprovedAction.ImplementationType)'"
                }
            }
            Write-Log "Action '$($ApprovedAction.Title)' execution finished. Status: $actionStatus."
        } catch {
            Write-Log "Error during execution of action '$($ApprovedAction.Title)'. Error: $($_.Exception.Message)" -Level "ERROR"
            Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "DEBUG"
            $actionStatus = "Failed"
            $actionErrors.Add($_.Exception.Message)
            $actionErrors.Add($_.ScriptStackTrace)
        }
    } else {
        Write-Log "Execution of action '$($ApprovedAction.Title)' was skipped due to ShouldProcess (e.g., -WhatIf)." -Level "INFO"
        $actionStatus = "SkippedWhatIf"
        $actionOutput.Add("Execution skipped by -WhatIf or user choice.")
    }

    $executionEndTime = Get-Date
    $result = [PSCustomObject]@{
        RemediationActionId   = $ApprovedAction.RemediationActionId
        Title                 = $ApprovedAction.Title
        ImplementationType    = $ApprovedAction.ImplementationType
        ExecutionStartTime    = $executionStartTime
        ExecutionEndTime      = $executionEndTime
        DurationSeconds       = ($executionEndTime - $executionStartTime).TotalSeconds
        Status                = $actionStatus
        Output                = $actionOutput -join [System.Environment]::NewLine
        Errors                = $actionErrors -join [System.Environment]::NewLine
        ExitCode              = $actionExitCode # Relevant for executables
        BackupPerformed       = $backupAttempted
        BackupPathUsed        = $actualBackupPath
    }

    Write-Log "Start-RemediationAction script finished. Final Status: $actionStatus for Action ID '$($ApprovedAction.RemediationActionId)'."
    return $result
}

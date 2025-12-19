# Start-RemediationAction.ps1
# This script executes an approved remediation action.
# Requires admin rights for registry/service changes. Use -BackupStateBeforeExecution with optional -BackupCompress/-BackupKeepUncompressed to capture state.
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
        [string]$BackupScriptPath, # Optional override for Backup-OperationState.ps1

        [Parameter(Mandatory=$false)]
        [switch]$BackupCompress,

        [Parameter(Mandatory=$false)]
        [switch]$BackupKeepUncompressed,

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
        $targetPath = if (-not [string]::IsNullOrWhiteSpace($Path)) { $Path } elseif (-not [string]::IsNullOrWhiteSpace($LogPath)) { $LogPath } else { $null }
        
        try {
            if (-not $targetPath) { Write-Host $logEntry; return }

            if ($WhatIfPreference) { Write-Host $logEntry; return }

            $parentPath = if (-not [string]::IsNullOrWhiteSpace($targetPath)) { Split-Path -Path $targetPath -Parent } else { $null }
            if ($parentPath -and -not (Test-Path $parentPath -PathType Container)) {
                New-Item -ItemType Directory -Path $parentPath -Force -ErrorAction Stop | Out-Null
            }
            Add-Content -Path $targetPath -Value $logEntry -ErrorAction Stop
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
    $backupSucceeded = $false
    $actualBackupPath = $null
    $resolvedParameters = @{}
    if ($ApprovedAction.PSObject.Properties['ResolvedParameters'] -and $ApprovedAction.ResolvedParameters -is [hashtable]) {
        $resolvedParameters = $ApprovedAction.ResolvedParameters
    }

    # Resolve backup script path relative to remediation folder if not provided
    if (-not $BackupScriptPath) {
        $callerPath = $MyInvocation.PSCommandPath
        if (-not $callerPath) { $callerPath = $MyInvocation.MyCommand.Path }
        $resolvedRoot = if (-not [string]::IsNullOrWhiteSpace($callerPath)) { Split-Path -Parent $callerPath } elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath } elseif ($PSScriptRoot) { $PSScriptRoot } else { Get-Location }
        $BackupScriptPath = Join-Path $resolvedRoot "..\utils\Backup-OperationState.ps1"
    }

    # --- Backup State (Conceptual for V1) ---
    if ($BackupStateBeforeExecution) {
        $backupAttempted = $true
        if ([string]::IsNullOrWhiteSpace($BackupPath)) {
            $timestampForPath = Get-Date -Format "yyyyMMddHHmmss"
            $actualBackupPath = "C:\ProgramData\AzureArcFramework\Backups\$($ApprovedAction.RemediationActionId)_$timestampForPath"
        } else {
            $actualBackupPath = $BackupPath
        }
        if (Test-Path $BackupScriptPath -PathType Leaf) {
            try {
                Write-Log "Initiating backup using '$BackupScriptPath' to '$actualBackupPath' for action '$($ApprovedAction.RemediationActionId)'."
                $backupParams = @{ OperationName = "Before_$($ApprovedAction.RemediationActionId)"; BackupPath = $actualBackupPath; ErrorAction = 'Stop' }
                $backupCmd = Get-Command -Path $BackupScriptPath -ErrorAction SilentlyContinue
                if ($backupCmd -and $backupCmd.Parameters.ContainsKey('Compress') -and $BackupCompress) { $backupParams.Compress = $true }
                if ($backupCmd -and $backupCmd.Parameters.ContainsKey('KeepUncompressed') -and $BackupKeepUncompressed) { $backupParams.KeepUncompressed = $true }
                & $BackupScriptPath @backupParams
                $backupSucceeded = $true
                Write-Log "Backup completed for action '$($ApprovedAction.RemediationActionId)' to '$actualBackupPath'."
            } catch {
                Write-Log "Backup script failed for '$($ApprovedAction.RemediationActionId)'. Error: $($_.Exception.Message)" -Level "ERROR"
            }
        } else {
            Write-Log "Backup-OperationState.ps1 not found at '$BackupScriptPath'. Proceeding without backup." -Level "WARNING"
        }
    }

    if (-not $backupSucceeded -and $backupAttempted -and $actualBackupPath -and (Test-Path $actualBackupPath -ErrorAction SilentlyContinue)) {
        $backupSucceeded = $true
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
                    $scriptOutput = . $ApprovedAction.TargetScriptPath @resolvedParameters *>&1 # Merge all streams
                    
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
                    $funcOutput = . $ApprovedAction.TargetFunction @resolvedParameters *>&1

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
                    $argString = ConvertTo-ArgumentListString -Parameters $resolvedParameters
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
        BackupSuccessful      = $backupSucceeded
        BackupPathUsed        = $actualBackupPath
        BackupCompressRequested = [bool]$BackupCompress
        BackupKeepUncompressedRequested = [bool]$BackupKeepUncompressed
    }
    
    Write-Log "Start-RemediationAction script finished. Final Status: $actionStatus for Action ID '$($ApprovedAction.RemediationActionId)'."
    return $result
}

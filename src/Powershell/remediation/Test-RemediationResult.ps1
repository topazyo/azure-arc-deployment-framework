# Test-RemediationResult.ps1
# This script executes defined validation steps to test the outcome of a remediation action.
# TODO: Implement full EventLogQuery (requires WorkspaceID, Az module).
# TODO: Enhance ScriptExecutionCheck/FunctionCall to handle parameters and more complex ExpectedResult evaluations.

Function Test-RemediationResult {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject[]]$ValidationSteps, # Array of objects from Get-ValidationStep.ps1

        [Parameter(Mandatory=$false)]
        [PSCustomObject]$RemediationActionResult, # Optional: output from Start-RemediationAction.ps1

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\TestRemediationResult_Activity.log"
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

    Write-Log "Starting Test-RemediationResult script. Number of validation steps: $($ValidationSteps.Count)."

    function Test-ExpectedOutcome {
        param(
            [string]$Expected,
            [string]$Actual,
            [System.Collections.IEnumerable]$StdOutput,
            [System.Collections.IEnumerable]$Errors
        )

        if ([string]::IsNullOrWhiteSpace($Expected)) {
            return ($Errors -eq $null -or ($Errors | Measure-Object).Count -eq 0)
        }

        switch -regex ($Expected) {
            '^\$true$' { return ($StdOutput -contains $true) }
            '^\$false$' { return ($StdOutput -contains $false) }
            '^0$' { return (($Errors -eq $null -or ($Errors | Measure-Object).Count -eq 0)) }
            '^Contains\s+"(.+)"$' { return (($Actual) -match $Matches[1]) }
            '^Regex\s*:(.+)$' { return (($Actual) -match $Matches[1]) }
            default { return ($Actual -eq $Expected) }
        }
    }

    if (-not $ValidationSteps -or $ValidationSteps.Count -eq 0) {
        Write-Log "No validation steps provided. Cannot perform test." -Level "WARNING"
        return @{ OverallValidationStatus = "SkippedNoSteps"; ValidationStepResults = @() }
    }

    # Ensure the step objects are modifiable and carry writable properties when sourced from ConvertFrom-Json
    $modifiableValidationSteps = @()
    foreach($s in $ValidationSteps){
        $copyHashtable = @{}
        $s.PSObject.Properties | ForEach-Object { $copyHashtable[$_.Name] = $_.Value }

        foreach ($propName in @('Status','Timestamp','ActualResult','Notes')) {
            if (-not $copyHashtable.ContainsKey($propName)) { $copyHashtable[$propName] = $null }
        }

        $modifiableValidationSteps += [PSCustomObject]$copyHashtable
    }


    foreach ($step in $modifiableValidationSteps) {
        Write-Log "Executing Validation Step: '$($step.ValidationStepId)' - Type: '$($step.ValidationType)' - Description: '$($step.Description)'"
        $step.Status = "InProgress"
        $step.Timestamp = Get-Date -Format o
        $stepOutput = $null
        $stepError = $null

        try {
            $invocationParams = @{}
            if ($step.PSObject.Properties['Parameters'] -and $step.Parameters -is [hashtable]) {
                $invocationParams = $step.Parameters
            }

            switch ($step.ValidationType) {
                "ServiceStateCheck" {
                    $serviceName = $step.ValidationTarget
                    $expectedStatusStr = $step.ExpectedResult # e.g., "Running", "Stopped"
                    
                    Write-Log "ServiceStateCheck: ServiceName='$serviceName', ExpectedStatus='$expectedStatusStr'"
                    $actualService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue # Change to Stop to catch error below
                    
                    if ($actualService) {
                        $step.ActualResult = $actualService.Status.ToString()
                        if ($actualService.Status.ToString() -eq $expectedStatusStr) {
                            $step.Status = "Success"
                            Write-Log "Service '$serviceName' is in expected state '$expectedStatusStr'."
                        } else {
                            $step.Status = "Failed"
                            Write-Log "Service '$serviceName' is in state '$($actualService.Status)', expected '$expectedStatusStr'." -Level "WARNING"
                        }
                    } else {
                        $step.Status = "Failed"
                        $step.ActualResult = "NotFound"
                        $stepError = "Service '$serviceName' not found."
                        Write-Log $stepError -Level "ERROR"
                    }
                }
                "EventLogQuery" {
                    $kqlQueryPlaceholder = $step.ValidationTarget
                    $expectedOutcome = $step.ExpectedResult # e.g., "EventFound"
                    
                    Write-Log "EventLogQuery (Simulated): TargetQuery='$kqlQueryPlaceholder', ExpectedOutcome='$expectedOutcome'." -Level "INFO"
                    Write-Log "Actual KQL execution against Log Analytics is not implemented in this version. This step type requires manual verification or external scripting with Azure context." -Level "WARNING"
                    $step.Status = "RequiresManualCheck" # Or "NotImplemented"
                    $step.ActualResult = "NotImplemented_AzureContextRequired"
                }
                "ScriptExecutionCheck" {
                    $scriptPath = $step.ValidationTarget
                    $expectedResultStr = $step.ExpectedResult # e.g., "$true", "0", "Contains 'Success'"
                    Write-Log "ScriptExecutionCheck: Path='$scriptPath', ExpectedResultString='$expectedResultStr'"

                    if (Test-Path $scriptPath -PathType Leaf) {
                        $scriptOutput = & $scriptPath @invocationParams *>&1 # Capture all streams
                        $errorsInOutput = $scriptOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
                        $stdOutput = $scriptOutput | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
                        $stdOutputArray = @($stdOutput)
                        $errorsArray = @($errorsInOutput)
                        
                        $step.ActualResult = $stdOutputArray -join [System.Environment]::NewLine
                        if ($errorsInOutput) { $stepError = $errorsArray -join [System.Environment]::NewLine }

                        $step.Status = if (Test-ExpectedOutcome -Expected $expectedResultStr -Actual $step.ActualResult -StdOutput $stdOutputArray -Errors $errorsArray) { "Success" } else { "Failed" }
                        Write-Log "Script execution result: Status='$($step.Status)'. Output captured. Errors: '$stepError'"
                    } else {
                        $step.Status = "Failed"
                        $step.ActualResult = "NotFound"
                        $stepError = "Validation script not found: $scriptPath"
                        Write-Log $stepError -Level "ERROR"
                    }
                }
                "FunctionCall" { # Similar to ScriptExecutionCheck
                    $functionName = $step.ValidationTarget
                    $expectedResultStr = $step.ExpectedResult
                    Write-Log "FunctionCall: Name='$functionName', ExpectedResultString='$expectedResultStr'"
                    $funcCmd = Get-Command -Name $functionName -CommandType Function -ErrorAction SilentlyContinue
                    if ($funcCmd) {
                        $funcOutput = & $functionName @invocationParams *>&1 # Add parameters if step defines them
                        $errorsInOutput = $funcOutput | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }
                        $stdOutput = $funcOutput | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
                        $stdOutputArray = @($stdOutput)
                        $errorsArray = @($errorsInOutput)

                        $step.ActualResult = $stdOutputArray -join [System.Environment]::NewLine
                        if ($errorsInOutput) { $stepError = $errorsArray -join [System.Environment]::NewLine }
                        
                        $step.Status = if (Test-ExpectedOutcome -Expected $expectedResultStr -Actual $step.ActualResult -StdOutput $stdOutputArray -Errors $errorsArray) { "Success" } else { "Failed" }
                        Write-Log "Function call result: Status='$($step.Status)'. Output captured. Errors: '$stepError'"
                    } else {
                        $step.Status = "Failed"
                        $step.ActualResult = "NotFound"
                        $stepError = "Validation function not found: $functionName"
                        Write-Log $stepError -Level "ERROR"
                    }
                }
                "ManualCheck" {
                    Write-Log "ManualCheck required for StepID '$($step.ValidationStepId)': $($step.Description)" -Level "INFO"
                    $step.Status = "RequiresManualConfirmation"
                    $step.ActualResult = "PendingOperatorConfirmation"
                    # Optionally prompt:
                    # $manualConfirm = Read-Host "Was manual check '$($step.Description)' successful? (y/n)"
                    # if ($manualConfirm -eq 'y') { $step.Status = "Success"; $step.ActualResult = "OperatorConfirmedSuccess" }
                    # else { $step.Status = "Failed"; $step.ActualResult = "OperatorConfirmedFailure" }
                }
                default {
                    Write-Log "Unsupported ValidationType: '$($step.ValidationType)' for StepID '$($step.ValidationStepId)'." -Level "WARNING"
                    $step.Status = "NotImplemented"
                    $step.ActualResult = "UnsupportedValidationType"
                }
            }
        } catch {
            Write-Log "Error executing validation step '$($step.ValidationStepId)'. Error: $($_.Exception.Message)" -Level "ERROR"
            $step.Status = "FailedExecutionError"
            $step.ActualResult = "ExecutionError"
            $stepError = $_.Exception.Message
        }
        if($stepError){ $step.Notes = $stepError }

    } # End foreach step

    # Determine OverallValidationStatus
    $overallStatus = "Success"
    if ($modifiableValidationSteps | Where-Object { $_.Status -eq "Failed" -or $_.Status -eq "FailedExecutionError" }) {
        $overallStatus = "Failed"
    } elseif ($modifiableValidationSteps | Where-Object { $_.Status -eq "RequiresManualConfirmation" -or $_.Status -eq "NotImplemented" }) {
        $overallStatus = "RequiresManualActionOrNotImplemented"
    } elseif ($modifiableValidationSteps | Where-Object { $_.Status -eq "InProgress" -or $_.Status -eq "NotRun" }) { # Should not happen if all run
        $overallStatus = "PartialExecution"
    } elseif ((($modifiableValidationSteps | Where-Object { $_.Status -eq "Success" }) | Measure-Object).Count -eq $modifiableValidationSteps.Count) {
        $overallStatus = "Success" # All success
    } else { # Mix of success and manual/notimplemented
         $overallStatus = "PartialSuccessRequiresAttention"
    }


    Write-Log "Test-RemediationResult script finished. OverallValidationStatus: $overallStatus."
    
    return @{
        OverallValidationStatus = $overallStatus
        ValidationStepResults   = $modifiableValidationSteps
        ReportTimestamp         = Get-Date -Format o
    }
}

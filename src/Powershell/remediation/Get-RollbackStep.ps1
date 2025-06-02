# Get-RollbackStep.ps1
# This script defines rollback steps for a given remediation action,
# prioritizing explicit definitions from rules or the action object.

Function Get-RollbackStep {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$RemediationAction, # From Get-RemediationAction.ps1

        [Parameter(Mandatory=$false)]
        [string]$RollbackRulesPath,

        [Parameter(Mandatory=$false)]
        [string]$OriginalStateBackupPath, # Path to pre-remediation backup data

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\GetRollbackStep_Activity.log"
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

    Write-Log "Starting Get-RollbackStep script for RemediationActionId: '$($RemediationAction.RemediationActionId)'."
    if ($OriginalStateBackupPath) { Write-Log "OriginalStateBackupPath provided: $OriginalStateBackupPath" }

    $rollbackSteps = [System.Collections.ArrayList]::new()
    $rollbackRules = @()

    if (-not $RemediationAction -or -not $RemediationAction.PSObject.Properties['RemediationActionId']) {
        Write-Log "Input RemediationAction is null or missing RemediationActionId. Cannot proceed." -Level "ERROR"
        return $rollbackSteps # Return empty array
    }

    if (-not [string]::IsNullOrWhiteSpace($RollbackRulesPath)) {
        Write-Log "Loading rollback rules from: $RollbackRulesPath"
        if (Test-Path $RollbackRulesPath -PathType Leaf) {
            try {
                $jsonContent = Get-Content -Path $RollbackRulesPath -Raw | ConvertFrom-Json -ErrorAction Stop
                if ($jsonContent.rollbackRules) {
                    $rollbackRules = $jsonContent.rollbackRules
                    Write-Log "Successfully loaded $($rollbackRules.Count) rollback rules from JSON file."
                } else {
                    Write-Log "Rules file '$RollbackRulesPath' does not contain a 'rollbackRules' array at the root." -Level "WARNING"
                }
            } catch {
                Write-Log "Failed to load or parse rollback rules file '$RollbackRulesPath'. Error: $($_.Exception.Message)" -Level "ERROR"
            }
        } else {
            Write-Log "Rollback rules file not found at: $RollbackRulesPath" -Level "WARNING"
        }
    }

    $specificRule = $rollbackRules | Where-Object { $_.AppliesToRemediationActionId -eq $RemediationAction.RemediationActionId } | Select-Object -First 1

    if ($specificRule) {
        Write-Log "Found specific rollback rule for '$($RemediationAction.RemediationActionId)' (RuleId: $($specificRule.RollbackStepId)). Using defined step(s)."
        # Assuming a rule can define one or more steps, though example shows one.
        # For simplicity, if a rule defines multiple steps, they should be an array in the rule.
        $ruleSteps = if ($specificRule.Steps -is [array]) { $specificRule.Steps } else { @($specificRule) } # Adapt if rule structure is different
        
        foreach($stepDef in $ruleSteps){
            $params = if ($stepDef.Parameters -is [hashtable]) { $stepDef.Parameters.Clone() } else { @{} }
            if ($OriginalStateBackupPath) { $params.OriginalStateBackupPath = $OriginalStateBackupPath }

            $rollbackSteps.Add([PSCustomObject]@{
                RollbackStepId      = $stepDef.RollbackStepId # Or generate one
                RemediationActionId = $RemediationAction.RemediationActionId
                Title               = $stepDef.Title
                Description         = $stepDef.Description
                ImplementationType  = $stepDef.ImplementationType
                RollbackTarget      = $stepDef.TargetScriptPath # Or TargetFunction, etc.
                ResolvedParameters  = $params
                ConfirmationRequired = if($stepDef.PSObject.Properties.Contains('ConfirmationRequired')) { $stepDef.ConfirmationRequired } else { $true }
            }) | Out-Null
             Write-Log "Added rollback step from specific rule: Title='$($stepDef.Title)'."
        }
    } elseif ($RemediationAction.PSObject.Properties['RollbackScript'] -and -not [string]::IsNullOrWhiteSpace($RemediationAction.RollbackScript)) {
        Write-Log "Found RollbackScript defined in RemediationAction object: '$($RemediationAction.RollbackScript)'."
        $params = @{}
        if ($OriginalStateBackupPath) { $params.OriginalStateBackupPath = $OriginalStateBackupPath }
        # Potentially extract other parameters if RemediationAction has a RollbackParameters property

        $rollbackSteps.Add([PSCustomObject]@{
            RollbackStepId      = "ROLL_FromActionScript_$(($RemediationAction.RemediationActionId -replace '\W','_'))"
            RemediationActionId = $RemediationAction.RemediationActionId
            Title               = "Execute defined rollback script for '$($RemediationAction.Title)'"
            Description         = "Runs the script specified in the RollbackScript property of the remediation action: '$($RemediationAction.RollbackScript)'."
            ImplementationType  = "Script" 
            RollbackTarget      = $RemediationAction.RollbackScript
            ResolvedParameters  = $params
            ConfirmationRequired = $true # Default for script-based rollback
        }) | Out-Null
        Write-Log "Added rollback step based on RemediationAction.RollbackScript."
    } else {
        Write-Log "No specific rollback rule or RollbackScript found for '$($RemediationAction.RemediationActionId)'. Defaulting to ManualRollback." -Level "INFO"
        $manualDescription = "Manually revert the changes made by remediation action '$($RemediationAction.Title)' (ID: $($RemediationAction.RemediationActionId))."
        if ($RemediationAction.Description) { $manualDescription += " Original action description: $($RemediationAction.Description)." }
        if ($OriginalStateBackupPath) { $manualDescription += " An original state backup may be available at: $OriginalStateBackupPath." }
        
        $rollbackSteps.Add([PSCustomObject]@{
            RollbackStepId      = "ROLL_Manual_$(($RemediationAction.RemediationActionId -replace '\W','_'))"
            RemediationActionId = $RemediationAction.RemediationActionId
            Title               = "Manual Rollback for '$($RemediationAction.Title)'"
            Description         = $manualDescription
            ImplementationType  = "Manual"
            RollbackTarget      = "Operator/User"
            ResolvedParameters  = if ($OriginalStateBackupPath) { @{ OriginalStateBackupPath = $OriginalStateBackupPath } } else { @{} }
            ConfirmationRequired = $true
        }) | Out-Null
        Write-Log "Added default ManualRollback step."
    }
    
    Write-Log "Get-RollbackStep script finished. Generated $($rollbackSteps.Count) rollback step(s)."
    return $rollbackSteps
}

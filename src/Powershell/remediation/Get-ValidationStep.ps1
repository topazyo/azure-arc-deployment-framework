# Get-ValidationStep.ps1
# This script translates a remediation action's success criteria into structured validation steps.
# TODO: Enhance heuristic parsing of SuccessCriteria.
# TODO: Implement merging logic for JSON rules vs. derived steps instead of just replacement.

Function Get-ValidationStep {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$RemediationAction, # Expected from Get-RemediationAction.ps1

        [Parameter(Mandatory=$false)]
        [string]$ValidationRulesPath,

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\GetValidationStep_Activity.log"
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

    Write-Log "Starting Get-ValidationStep script for RemediationActionId: '$($RemediationAction.RemediationActionId)'."

    $validationSteps = [System.Collections.ArrayList]::new()
    $validationRules = @()

    if (-not $RemediationAction -or -not $RemediationAction.PSObject.Properties['RemediationActionId']) {
        Write-Log "Input RemediationAction is null or missing RemediationActionId. Cannot proceed." -Level "ERROR"
        return $validationSteps # Return empty array
    }

    if (-not [string]::IsNullOrWhiteSpace($ValidationRulesPath)) {
        Write-Log "Loading validation rules from: $ValidationRulesPath"
        if (Test-Path $ValidationRulesPath -PathType Leaf) {
            try {
                $jsonContent = Get-Content -Path $ValidationRulesPath -Raw | ConvertFrom-Json -ErrorAction Stop
                if ($jsonContent.validationRules) {
                    $validationRules = $jsonContent.validationRules
                    Write-Log "Successfully loaded $($validationRules.Count) validation rules from JSON file."
                } else {
                    Write-Log "Rules file '$ValidationRulesPath' does not contain a 'validationRules' array at the root." -Level "WARNING"
                }
            } catch {
                Write-Log "Failed to load or parse validation rules file '$ValidationRulesPath'. Error: $($_.Exception.Message)" -Level "ERROR"
            }
        } else {
            Write-Log "Validation rules file not found at: $ValidationRulesPath" -Level "WARNING"
        }
    }

    # Check for rule overrides and append/replace derived steps based on MergeBehavior
    $overrideRules = $validationRules | Where-Object { $_.AppliesToRemediationActionId -eq $RemediationAction.RemediationActionId }
    $mergeBehavior = "Replace"

    if ($overrideRules -and $overrideRules.Count -gt 0) {
        Write-Log "Found $($overrideRules.Count) validation rule(s) for '$($RemediationAction.RemediationActionId)'." -Level "DEBUG"
        foreach ($overrideRule in $overrideRules) {
            if ($overrideRule.PSObject.Properties['MergeBehavior']) { $mergeBehavior = $overrideRule.MergeBehavior }

            $stepsToAdd = @()
            if ($overrideRule.PSObject.Properties['Steps'] -and $overrideRule.Steps -is [System.Collections.IEnumerable]) {
                $stepsToAdd = $overrideRule.Steps
            } else {
                $stepsToAdd = @($overrideRule)
            }

            foreach ($ruleStep in $stepsToAdd) {
                $validationSteps.Add([PSCustomObject]@{
                    ValidationStepId    = $ruleStep.ValidationStepId
                    RemediationActionId = $RemediationAction.RemediationActionId
                    Description         = $ruleStep.Description
                    ValidationType      = $ruleStep.ValidationType
                    ValidationTarget    = $ruleStep.ValidationTarget
                    ExpectedResult      = $ruleStep.ExpectedResult
                    ActualResult        = $null
                    Status              = "NotRun"
                    Parameters          = if ($ruleStep.PSObject.Properties['Parameters']) { $ruleStep.Parameters } else { $null }
                }) | Out-Null
            }
        }
        Write-Log "Added $($validationSteps.Count) validation step(s) from rule overrides (MergeBehavior=$mergeBehavior)." -Level "DEBUG"
    }

    if (-not $overrideRules -or $mergeBehavior -eq "AppendDerived") {
        Write-Log "Deriving validation steps from RemediationAction.SuccessCriteria." -Level "DEBUG"
        $successCriteriaText = $RemediationAction.SuccessCriteria
        
        if ([string]::IsNullOrWhiteSpace($successCriteriaText)) {
            Write-Log "SuccessCriteria is empty for '$($RemediationAction.RemediationActionId)'. Defaulting to ManualCheck." -Level "WARNING"
            $validationSteps.Add([PSCustomObject]@{
                ValidationStepId    = "VAL_ManualCheck_$(($RemediationAction.RemediationActionId -replace '\W','_'))"
                RemediationActionId = $RemediationAction.RemediationActionId
                Description         = "Manual Check Required: Please verify the success of remediation action '$($RemediationAction.Title)' as per operational guidelines."
                ValidationType      = "ManualCheck"
                ValidationTarget    = "Operator/User"
                ExpectedResult      = "ConfirmationOfSuccess"
                ActualResult        = $null
                Status              = "NotRun"
                Parameters          = $null
            }) | Out-Null
        } else {
            # Heuristic parsing of SuccessCriteria
            $derivedStep = $null
            Write-Log "Parsing SuccessCriteria: '$successCriteriaText'" -Level "DEBUG"

            # Heuristic 1: Service State Check
            if ($successCriteriaText -match "service\s*'(.*?)'\s*should be\s*'(Running|Stopped)'" -or `
                $successCriteriaText -match "service\s*should be\s*'(Running|Stopped)'.*name\s*'(.*?)'" ) {
                
                $serviceName = $Matches[1]
                $expectedState = $Matches[2]
                if ($Matches.Count -ge 3 -and -not [string]::IsNullOrWhiteSpace($Matches[3])) { # Second regex pattern
                    $serviceName = $Matches[3]
                }

                # Try to get service name from ResolvedParameters if not in regex match directly
                if (($serviceName -eq '$ServiceName' -or [string]::IsNullOrWhiteSpace($serviceName)) -and $RemediationAction.ResolvedParameters.ServiceName) {
                    $serviceName = $RemediationAction.ResolvedParameters.ServiceName
                } elseif (($serviceName -eq '$ServiceNameFromEvent' -or [string]::IsNullOrWhiteSpace($serviceName)) -and $RemediationAction.ResolvedParameters.ServiceNameFromEvent) {
                    $serviceName = $RemediationAction.ResolvedParameters.ServiceNameFromEvent
                }
                
                if (-not [string]::IsNullOrWhiteSpace($serviceName)) {
                    $derivedStep = @{
                        ValidationStepId    = "VAL_ServiceCheck_$(($serviceName -replace '\W','_'))_$(($RemediationAction.RemediationActionId -replace '\W','_'))"
                        Description         = "Verify that service '$serviceName' is in '$expectedState' state."
                        ValidationType      = "ServiceStateCheck"
                        ValidationTarget    = $serviceName
                        ExpectedResult      = $expectedState
                        Parameters          = $null
                    }
                    Write-Log "Derived ServiceStateCheck for service '$serviceName', expected state '$expectedState'."
                }
            }
            # Heuristic 2: Event Log Query (very basic)
            # Example: "Event ID 7036 should be logged by 'Service Control Manager'"
            elseif ($successCriteriaText -match "Event ID\s*(\d+)\s*should be logged by.*?source\s*'(.*?)'") {
                 $eventId = $Matches[1]
                 $eventSource = $Matches[2]
                 $kqlQueryPlaceholder = "Event | where EventID == $eventId and Source == '$eventSource' | take 1" # Placeholder
                 $derivedStep = @{
                    ValidationStepId    = "VAL_EventLog_$(($eventId))_$(($eventSource -replace '\W','_'))_$(($RemediationAction.RemediationActionId -replace '\W','_'))"
                    Description         = "Verify Event ID $eventId from source '$eventSource' is logged after remediation."
                    ValidationType      = "EventLogQuery"
                    ValidationTarget    = $kqlQueryPlaceholder # This would be the KQL query or parameters for Get-WinEvent
                    ExpectedResult      = "EventFound"
                          Parameters          = $null
                 }
                 Write-Log "Derived EventLogQuery for EventID '$eventId', Source '$eventSource'."
            }
            # Add more heuristics here...

            # Default to ManualCheck if no specific heuristic matched or if derived step is still null
            if (-not $derivedStep) {
                Write-Log "Could not derive specific validation step from SuccessCriteria. Defaulting to ManualCheck."
                $derivedStep = @{
                    ValidationStepId    = "VAL_ManualVerify_$(($RemediationAction.RemediationActionId -replace '\W','_'))"
                    Description         = "Manual Verification: Please verify success based on criteria: '$successCriteriaText'."
                    ValidationType      = "ManualCheck"
                    ValidationTarget    = "Operator/User based on criteria"
                    ExpectedResult      = "CriteriaMet"
                    Parameters          = $null
                }
            }

            $validationSteps.Add([PSCustomObject]@{
                ValidationStepId    = $derivedStep.ValidationStepId
                RemediationActionId = $RemediationAction.RemediationActionId
                Description         = $derivedStep.Description
                ValidationType      = $derivedStep.ValidationType
                ValidationTarget    = $derivedStep.ValidationTarget
                ExpectedResult      = $derivedStep.ExpectedResult
                ActualResult        = $null
                Status              = "NotRun"
                Parameters          = $derivedStep.Parameters
            }) | Out-Null
        }
    }
    
    Write-Log "Get-ValidationStep script finished. Generated $($validationSteps.Count) validation step(s)."
    return $validationSteps
}

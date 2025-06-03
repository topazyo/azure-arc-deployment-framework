# Get-RemediationAction.ps1
# This script determines appropriate remediation actions based on input issues or root cause analyses.
# TODO: Implement more sophisticated parameter resolution from input context.
# TODO: Add rule prioritization or conflict resolution if multiple rules match.

Function Get-RemediationAction {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [object[]]$InputObject, # Can be output from Find-IssuePatterns, Get-RootCauseAnalysis, or string IDs

        [Parameter(Mandatory=$false)]
        [string]$RemediationRulesPath,

        [Parameter(Mandatory=$false)]
        [int]$MaxActionsPerInput = 1,

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\GetRemediationAction_Activity.log"
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

    Write-Log "Starting Get-RemediationAction script. InputObject count: $($InputObject.Count)."

    $remediationRules = @()

    if (-not [string]::IsNullOrWhiteSpace($RemediationRulesPath)) {
        Write-Log "Loading remediation rules from: $RemediationRulesPath"
        if (Test-Path $RemediationRulesPath -PathType Leaf) {
            try {
                $jsonContent = Get-Content -Path $RemediationRulesPath -Raw | ConvertFrom-Json -ErrorAction Stop
                if ($jsonContent.remediationRules) {
                    $remediationRules = $jsonContent.remediationRules
                    Write-Log "Successfully loaded $($remediationRules.Count) remediation rules from JSON file."
                } else {
                    Write-Log "Rules file '$RemediationRulesPath' does not contain a 'remediationRules' array at the root." -Level "WARNING"
                }
            } catch {
                Write-Log "Failed to load or parse remediation rules file '$RemediationRulesPath'. Error: $($_.Exception.Message)" -Level "ERROR"
            }
        } else {
            Write-Log "Remediation rules file not found at: $RemediationRulesPath" -Level "WARNING"
        }
    }

    if ($remediationRules.Count -eq 0) {
        Write-Log "Using hardcoded remediation rule definitions."
        $remediationRules = @(
            @{
                AppliesToId = "ServiceCrashUnexpected" # MatchedIssueId
                RemediationActionId = "REM_RestartService_Generic"
                Title = "Attempt Generic Service Restart"
                Description = "Attempts to restart the service that was reported as crashed."
                ImplementationType = "Function" # Placeholder for a local function or module function
                TargetFunction = "Restart-AffectedService"
                # Parameter value is a string path to the property in the $item.MatchedItem object
                Parameters = @{ ServiceNameFromEvent = '$InputContext.MatchedItem.Properties[0].Value' } # Assumes EventData[0] has service name for 7034
                ConfirmationRequired = $true
                Impact = "Medium"
                SuccessCriteria = "Service should be in 'Running' state after execution."
                RollbackScript = "Stop-Service -Name '$($InputContext.MatchedItem.Properties[0].Value)'" # Example, needs context
            },
            @{
                AppliesToId = "RCA_ServiceCrash_Dependency" # RootCauseRuleId
                RemediationActionId = "REM_CheckServiceDependencies"
                Title = "Check and Restart Service Dependencies"
                Description = "Identifies and attempts to start known dependencies of the crashed service."
                ImplementationType = "Manual" # Or a more complex script
                TargetScriptPath = ""
                Parameters = @{ CrashedServiceName = '$InputContext.OriginalIssue.MatchedItem.Properties[0].Value' }
                ConfirmationRequired = $true
                Impact = "Medium"
                SuccessCriteria = "Dependencies are running, primary service can start."
            },
            @{
                AppliesToId = "LowDiskSpaceSystemDrive"
                RemediationActionId = "REM_RunDiskCleanup"
                Title = "Run System Disk Cleanup (Elevated)"
                Description = "Initiates cleanmgr.exe with automated settings for system drive cleanup."
                ImplementationType = "Executable"
                TargetScriptPath = "cleanmgr.exe"
                Parameters = @{ Args = "/sagerun:1"} # Assumes a sagerun profile 1 is configured for temp files
                ConfirmationRequired = $true
                Impact = "Low"
                SuccessCriteria = "Disk space on C: increases measurably."
            }
        )
        Write-Log "Loaded $($remediationRules.Count) hardcoded remediation rules."
    }

    $allSuggestedActions = [System.Collections.ArrayList]::new()

    foreach ($item in $InputObject) {
        $lookupId = $null
        $inputContextForParameterResolution = $item # The whole item is the context

        if ($item -is [string]) {
            $lookupId = $item
        } elseif ($item.PSObject.Properties['SuggestedRemediationId'] -and -not [string]::IsNullOrWhiteSpace($item.SuggestedRemediationId) ) {
            $lookupId = $item.SuggestedRemediationId # This would typically be a RemediationActionId directly
        } elseif ($item.PSObject.Properties['PotentialRootCauses'] -and $item.PotentialRootCauses -is [array] -and $item.PotentialRootCauses.Count -gt 0) {
            # Use the ID of the top potential root cause
            $lookupId = $item.PotentialRootCauses[0].RootCauseRuleId
        } elseif ($item.PSObject.Properties['MatchedIssueId']) {
            $lookupId = $item.MatchedIssueId
        } else {
            Write-Log "Could not determine a suitable LookupID from input item: $($item | Out-String -Depth 1)" -Level "WARNING"
            continue
        }

        Write-Log "Processing input item with LookupID: '$lookupId'." -Level "DEBUG"

        $actionsForThisItem = [System.Collections.ArrayList]::new()
        $matchingRules = $remediationRules | Where-Object { $_.AppliesToId -eq $lookupId -or $_.RemediationActionId -eq $lookupId }


        foreach ($rule in $matchingRules) {
            if ($actionsForThisItem.Count -ge $MaxActionsPerInput) { break }

            Write-Log "Rule '$($rule.RemediationActionId)' matches LookupID '$lookupId'." -Level "DEBUG"
            $resolvedParameters = @{}
            if ($rule.Parameters -is [hashtable]) {
                foreach ($paramName in $rule.Parameters.Keys) {
                    $paramValueOrPath = $rule.Parameters[$paramName]
                    if ($paramValueOrPath -is [string] -and $paramValueOrPath.StartsWith('$InputContext.')) {
                        $expression = $paramValueOrPath.Replace('$InputContext', '$inputContextForParameterResolution')
                        try {
                            $resolvedParameters[$paramName] = Invoke-Expression $expression
                            Write-Log "Resolved parameter '$paramName' to '$($resolvedParameters[$paramName])' from expression '$expression'." -Level "DEBUG"
                        } catch {
                            Write-Log "Failed to resolve parameter '$paramName' using expression '$expression'. Error: $($_.Exception.Message)" -Level "WARNING"
                            $resolvedParameters[$paramName] = $paramValueOrPath # Keep original path as value if resolution fails
                        }
                    } else {
                        $resolvedParameters[$paramName] = $paramValueOrPath # Static value
                    }
                }
            }

            $action = [PSCustomObject]@{
                RemediationActionId = $rule.RemediationActionId
                Title = $rule.Title
                Description = $rule.Description
                ImplementationType = $rule.ImplementationType
                TargetScriptPath = $rule.TargetScriptPath
                TargetFunction = $rule.TargetFunction
                ResolvedParameters = $resolvedParameters
                ConfirmationRequired = if($rule.PSObject.Properties.Contains('ConfirmationRequired')) { $rule.ConfirmationRequired } else { $true } # Default to true
                Impact = $rule.Impact
                SuccessCriteria = $rule.SuccessCriteria
                RollbackScript = $rule.RollbackScript # May need parameter resolution too
            }
            $actionsForThisItem.Add($action) | Out-Null
        }

        if ($actionsForThisItem.Count -gt 0) {
            # Sorting by Impact or a predefined priority could be added here if rules had such fields
            $allSuggestedActions.Add([PSCustomObject]@{
                InputContext = $item
                SuggestedActions = $actionsForThisItem # Already limited by MaxActionsPerInput if multiple rules matched one ID
                Timestamp = (Get-Date -Format o)
            }) | Out-Null
            Write-Log "Found $($actionsForThisItem.Count) actions for LookupID '$lookupId'."
        } else {
            Write-Log "No matching remediation rules found for LookupID '$lookupId'." -Level "INFO"
        }
    }

    Write-Log "Get-RemediationAction script finished. Generated action plans for $($allSuggestedActions.Count) input items."
    return $allSuggestedActions
}

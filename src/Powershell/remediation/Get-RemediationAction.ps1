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
                AppliesToId = "ServiceCrashUnexpected"
                RemediationActionId = "REM_RestartService_Generic"
                Title = "Restart impacted service"
                Description = "Restart the service that terminated unexpectedly and verify it reaches Running state."
                ImplementationType = "Manual"
                TargetFunction = ""
                Parameters = @{ ServiceName = '$InputContext.MatchedItem.ServiceName' }
                ConfirmationRequired = $true
                Impact = "Medium"
                SuccessCriteria = "Service reports Running and dependent workloads recover."
            },
            @{
                AppliesToId = "ServiceRestartLoop"
                RemediationActionId = "REM_CheckServiceRecoveryOptions"
                Title = "Inspect service recovery options"
                Description = "Review failure actions, restart delay, and dependency health for a flapping service."
                ImplementationType = "Manual"
                TargetScriptPath = ""
                Parameters = @{ ServiceName = '$InputContext.MatchedItem.ServiceName' }
                ConfirmationRequired = $true
                Impact = "Medium"
                SuccessCriteria = "Service remains stable for multiple restart intervals."
            },
            @{
                AppliesToId = "RCA_ServiceCrash_Dependency"
                RemediationActionId = "REM_CheckServiceDependencies"
                Title = "Check and restart dependencies"
                Description = "Identify failed dependencies and bring them online before retrying the primary service."
                ImplementationType = "Manual"
                TargetScriptPath = ""
                Parameters = @{ CrashedServiceName = '$InputContext.OriginalIssue.MatchedItem.ServiceName' }
                ConfirmationRequired = $true
                Impact = "Medium"
                SuccessCriteria = "Dependencies and primary service are Running."
            },
            @{
                AppliesToId = "ExtensionInstallFailure"
                RemediationActionId = "REM_RetryExtensionDeployment"
                Title = "Retry extension deployment"
                Description = "Retry the failed Arc/guest extension with prerequisite checks (network, permissions, disk)."
                ImplementationType = "Manual"
                TargetScriptPath = ""
                Parameters = @{ ExtensionName = '$InputContext.MatchedItem.ExtensionName' }
                ConfirmationRequired = $true
                Impact = "Medium"
                SuccessCriteria = "Extension reports ProvisioningState=Succeeded."
            },
            @{
                AppliesToId = "ArcAgentDisconnected"
                RemediationActionId = "REM_RestartArcAgent"
                Title = "Restart Arc agent services"
                Description = "Restart himds/AzureConnectedMachineAgent and verify heartbeat recovery."
                ImplementationType = "Manual"
                TargetScriptPath = ""
                Parameters = @{ Services = @('himds','AzureConnectedMachineAgent') }
                ConfirmationRequired = $true
                Impact = "High"
                SuccessCriteria = "Heartbeat events resume; resource status is Connected."
            },
            @{
                AppliesToId = "CertificateExpiringSoon"
                RemediationActionId = "REM_RenewCertificate"
                Title = "Renew expiring certificate"
                Description = "Renew or reissue certificates nearing expiration and update bound services."
                ImplementationType = "Manual"
                TargetScriptPath = ""
                Parameters = @{ CertificateName = '$InputContext.MatchedItem.Thumbprint' }
                ConfirmationRequired = $true
                Impact = "Medium"
                SuccessCriteria = "New certificate is present and bound; expiration > 180 days."
            },
            @{
                AppliesToId = "PolicyAssignmentNonCompliant"
                RemediationActionId = "REM_ReapplyPolicyAssignment"
                Title = "Re-apply policy remediation"
                Description = "Trigger policy remediation task or rerun baselines for non-compliant assignments."
                ImplementationType = "Manual"
                TargetScriptPath = ""
                Parameters = @{ PolicyName = '$InputContext.MatchedItem.PolicyName' }
                ConfirmationRequired = $true
                Impact = "Medium"
                SuccessCriteria = "Policy reports Compliant after remediation task."
            },
            @{
                AppliesToId = "LowDiskSpaceSystemDrive"
                RemediationActionId = "REM_RunDiskCleanup"
                Title = "Run System Disk Cleanup (Elevated)"
                Description = "Initiates cleanmgr.exe with automated settings for system drive cleanup."
                ImplementationType = "Executable"
                TargetScriptPath = "cleanmgr.exe"
                Parameters = @{ Args = "/sagerun:1"}
                ConfirmationRequired = $true
                Impact = "Low"
                SuccessCriteria = "Disk space on C: increases measurably."
            },
            @{
                AppliesToId = "LowDiskSpaceSystemDrive"
                RemediationActionId = "REM_ClearTempFiles"
                Title = "Clear temporary files and package cache"
                Description = "Delete temp folders, old logs, and package caches contributing to low disk space."
                ImplementationType = "Manual"
                TargetScriptPath = ""
                Parameters = @{ TargetDrive = 'C:' }
                ConfirmationRequired = $true
                Impact = "Low"
                SuccessCriteria = "System drive free space exceeds alert threshold."
            },
            @{
                AppliesToId = "DNSResolutionFailure"
                RemediationActionId = "REM_TestDNS"
                Title = "Test DNS resolution and switch to fallback resolver"
                Description = "Run nslookup/dig against primary and fallback resolvers; adjust DNS servers if primary fails."
                ImplementationType = "Manual"
                TargetScriptPath = ""
                Parameters = @{ PrimaryResolver = '$InputContext.MatchedItem.DNSServer' }
                ConfirmationRequired = $true
                Impact = "Medium"
                SuccessCriteria = "Name resolution succeeds for required endpoints."
            },
            @{
                AppliesToId = "CPUSustainedHigh"
                RemediationActionId = "REM_CaptureTopProcesses"
                Title = "Capture top CPU consumers"
                Description = "Collect top processes/threads and assess runaway workloads before mitigation."
                ImplementationType = "Manual"
                TargetScriptPath = ""
                Parameters = @{ SampleSeconds = 60 }
                ConfirmationRequired = $true
                Impact = "Low"
                SuccessCriteria = "CPU pressure relieved or offending process identified."
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
        } elseif ($item.PSObject.Properties['IssueId']) {
            $lookupId = $item.IssueId
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
            $parameterBag = @{}
            if ($rule.PSObject.Properties['Parameters']) {
                $rawParams = $rule.Parameters
                if ($rawParams -is [hashtable]) {
                    $parameterBag = $rawParams
                } elseif ($rawParams -is [psobject]) {
                    foreach ($p in $rawParams.PSObject.Properties) { $parameterBag[$p.Name] = $p.Value }
                }
            }

            foreach ($paramName in $parameterBag.Keys) {
                $paramValueOrPath = $parameterBag[$paramName]
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

            $action = [PSCustomObject]@{
                RemediationActionId = $rule.RemediationActionId
                Title = $rule.Title
                Description = $rule.Description
                ImplementationType = $rule.ImplementationType
                TargetScriptPath = $rule.TargetScriptPath
                TargetFunction = $rule.TargetFunction
                ResolvedParameters = $resolvedParameters
                ConfirmationRequired = if($rule.PSObject.Properties['ConfirmationRequired']) { $rule.ConfirmationRequired } else { $true }
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

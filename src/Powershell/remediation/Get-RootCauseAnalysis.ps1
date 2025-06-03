# Get-RootCauseAnalysis.ps1
# This script suggests potential root causes for identified issues based on a rule set.
# TODO: Implement executable DiagnosticChecks for more dynamic RCA.
# TODO: Refine confidence adjustment based on evidence.

Function Get-RootCauseAnalysis {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [object[]]$MatchedIssues, # Expected from Find-IssuePatterns.ps1

        [Parameter(Mandatory=$false)]
        [string]$RCARulesPath,

        [Parameter(Mandatory=$false)]
        [int]$MaxRCAsPerIssue = 1,

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\GetRootCauseAnalysis_Activity.log"
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

    Write-Log "Starting Get-RootCauseAnalysis script. MatchedIssues count: $($MatchedIssues.Count)."

    $rcaRules = @()

    if (-not [string]::IsNullOrWhiteSpace($RCARulesPath)) {
        Write-Log "Loading RCA rules from: $RCARulesPath"
        if (Test-Path $RCARulesPath -PathType Leaf) {
            try {
                $jsonContent = Get-Content -Path $RCARulesPath -Raw | ConvertFrom-Json -ErrorAction Stop
                if ($jsonContent.rcaRules) {
                    $rcaRules = $jsonContent.rcaRules
                    Write-Log "Successfully loaded $($rcaRules.Count) RCA rules from JSON file."
                } else {
                    Write-Log "RCA rules file '$RCARulesPath' does not contain an 'rcaRules' array at the root." -Level "WARNING"
                }
            } catch {
                Write-Log "Failed to load or parse RCA rules file '$RCARulesPath'. Error: $($_.Exception.Message)" -Level "ERROR"
            }
        } else {
            Write-Log "RCA rules file not found at: $RCARulesPath" -Level "WARNING"
        }
    }

    if ($rcaRules.Count -eq 0) {
        Write-Log "Using hardcoded RCA rule definitions."
        $rcaRules = @(
            @{
                RuleId = "RCA_ServiceCrash_CorruptBinary"
                AppliesToIssueId = "ServiceCrashUnexpected" # From Find-IssuePatterns.ps1
                RootCauseDescription = "The service executable or a critical DLL may be corrupted, misconfigured, or missing."
                Confidence = 0.5
                # SupportingEvidenceKeywords could be used to check for specific error codes in MatchedItem.Message
            },
            @{
                RuleId = "RCA_ServiceCrash_Dependency"
                AppliesToIssueId = "ServiceCrashUnexpected"
                RootCauseDescription = "A critical dependency service for this service might not be running or failed to start."
                Confidence = 0.7
                SupportingEvidenceKeywords = @{
                    Message = @("dependency", "service cannot be started", "failed to start", "is not running")
                }
            },
            @{
                RuleId = "RCA_ServiceCrash_Permissions"
                AppliesToIssueId = "ServiceCrashUnexpected"
                RootCauseDescription = "The service account may lack necessary permissions for its resources or log on as a service right."
                Confidence = 0.6
                SupportingEvidenceKeywords = @{ Message = @("access denied", "permission", "failed to log on") }
            },
            @{
                RuleId = "RCA_LowDisk_SystemTemp"
                AppliesToIssueId = "LowDiskSpaceSystemDrive"
                RootCauseDescription = "High volume of temporary files in system temp directories (e.g., C:\Windows\Temp, user temp folders)."
                Confidence = 0.6
                # SupportingEvidenceKeywords could check MatchedItem.Message for specific paths if event provides it
            },
             @{
                RuleId = "RCA_LowDisk_ApplicationLogs"
                AppliesToIssueId = "LowDiskSpaceSystemDrive"
                RootCauseDescription = "Application logs or trace files consuming excessive disk space."
                Confidence = 0.7
            },
            @{
                RuleId = "RCA_DNS_ServerIssue"
                AppliesToIssueId = "DNSResolutionFailure"
                RootCauseDescription = "The configured DNS server(s) might be unreachable or experiencing issues."
                Confidence = 0.8
            }
        )
        Write-Log "Loaded $($rcaRules.Count) hardcoded RCA rules."
    }

    $analysisResults = [System.Collections.ArrayList]::new()

    foreach ($issue in $MatchedIssues) {
        Write-Log "Analyzing issue: '$($issue.MatchedIssueId)' - $($issue.MatchedIssueDescription)" -Level "DEBUG"
        $potentialRCAsForThisIssue = [System.Collections.ArrayList]::new()

        $applicableRules = $rcaRules | Where-Object { $_.AppliesToIssueId -eq $issue.MatchedIssueId }
        Write-Log "Found $($applicableRules.Count) RCA rules applicable to IssueId '$($issue.MatchedIssueId)'." -Level "DEBUG"

        foreach ($rule in $applicableRules) {
            $evidenceFound = $true # Assume true unless keywords are specified and not found
            $matchingKeywordsSummary = [System.Collections.ArrayList]::new()

            if ($rule.SupportingEvidenceKeywords -is [hashtable]) {
                $allKeywordPropertiesFound = $true
                foreach ($propName in $rule.SupportingEvidenceKeywords.Keys) {
                    if (-not ($issue.MatchedItem.PSObject.Properties[$propName])) {
                        Write-Log "Keyword check: Property '$propName' not found in MatchedItem for rule '$($rule.RuleId)'." -Level "DEBUG"
                        $allKeywordPropertiesFound = $false
                        break
                    }

                    $itemValue = $issue.MatchedItem.$($propName)
                    if (-not ($itemValue -is [string])) {
                        Write-Log "Keyword check: Property '$propName' is not a string in MatchedItem for rule '$($rule.RuleId)'." -Level "DEBUG"
                        $allKeywordPropertiesFound = $false
                        break
                    }

                    $keywordsForProperty = @($rule.SupportingEvidenceKeywords[$propName])
                    $anyKeywordFoundInProperty = $false
                    foreach ($keyword in $keywordsForProperty) {
                        if ($itemValue -match [regex]::Escape($keyword)) { # Case-insensitive substring match
                            $anyKeywordFoundInProperty = $true
                            $matchingKeywordsSummary.Add("'$keyword' in '$propName'") | Out-Null
                            # Write-Log "Keyword '$keyword' found in '$propName' for rule '$($rule.RuleId)'." -Level "DEBUG"
                            break # Found one keyword for this property, that's enough
                        }
                    }
                    if (-not $anyKeywordFoundInProperty) {
                        Write-Log "Keyword check: No specified keywords for '$propName' found in item for rule '$($rule.RuleId)'." -Level "DEBUG"
                        $allKeywordPropertiesFound = $false
                        break
                    }
                }
                $evidenceFound = $allKeywordPropertiesFound
            }

            # If SupportingEvidenceKeywords were defined, but not found, we might lower confidence or exclude.
            # For this version, we'll just note if evidence was found.
            if ($rule.SupportingEvidenceKeywords -and (-not $evidenceFound)) {
                 Write-Log "Rule '$($rule.RuleId)' specified SupportingEvidenceKeywords, but they were not all found in the MatchedItem. This RCA is considered less likely for this specific item." -Level "INFO"
                 # Optionally skip this rule: continue
            }

            $rcaEntry = @{
                RootCauseRuleId = $rule.RuleId
                Description = $rule.RootCauseDescription
                Confidence = $rule.Confidence # Original confidence from the rule
                EvidenceFoundDetails = if($matchingKeywordsSummary.Count -gt 0) { $matchingKeywordsSummary -join "; " } else {$null}
                RequiresFurtherDiagnostics = ($rule.DiagnosticChecks -ne $null -and $rule.DiagnosticChecks.Count -gt 0) # Placeholder
            }
            $potentialRCAsForThisIssue.Add([PSCustomObject]$rcaEntry) | Out-Null
        } # End foreach rule

        # Sort by confidence and take top N
        $sortedRCAs = $potentialRCAsForThisIssue | Sort-Object Confidence -Descending | Select-Object -First $MaxRCAsPerIssue

        $analysisResults.Add([PSCustomObject]@{
            OriginalIssue       = $issue
            PotentialRootCauses = $sortedRCAs
            Timestamp           = (Get-Date -Format o)
        }) | Out-Null
        Write-Log "Added $($sortedRCAs.Count) potential RCA(s) for issue '$($issue.MatchedIssueId)'."
    } # End foreach issue

    Write-Log "Get-RootCauseAnalysis script finished. Processed $($MatchedIssues.Count) issues, generated analysis for $($analysisResults.Count) of them."
    return $analysisResults
}

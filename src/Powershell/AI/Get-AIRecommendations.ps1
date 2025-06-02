# Get-AIRecommendations.ps1
# This script uses a rule-based approach to generate recommendations based on input features or patterns.
# TODO: Implement more sophisticated condition evaluation (e.g., GreaterThan, Contains, regex matching).
# TODO: Consider confidence scoring based on rule strength or multiple matching rules.

Function Get-AIRecommendations {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [object[]]$InputFeatures, # Expected to be array of PSCustomObjects/Hashtables

        [Parameter(Mandatory=$false)]
        [string]$RecommendationRulesPath,

        [Parameter(Mandatory=$false)]
        [int]$MaxRecommendationsPerInput = 3,

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\GetAIRecommendations_Activity.log"
    )

    # --- Logging Function (for script activity) ---
    function Write-Log {
        param (
            [string]$Message,
            [string]$Level = "INFO", # INFO, WARNING, ERROR
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

    Write-Log "Starting Get-AIRecommendations script. InputFeatures count: $($InputFeatures.Count)."

    $recommendationRules = @()

    if (-not [string]::IsNullOrWhiteSpace($RecommendationRulesPath)) {
        Write-Log "Loading recommendation rules from: $RecommendationRulesPath"
        if (Test-Path $RecommendationRulesPath -PathType Leaf) {
            try {
                $jsonContent = Get-Content -Path $RecommendationRulesPath -Raw | ConvertFrom-Json -ErrorAction Stop
                if ($jsonContent.rules) {
                    $recommendationRules = $jsonContent.rules
                    Write-Log "Successfully loaded $($recommendationRules.Count) rules from JSON file."
                } else {
                    Write-Log "Rules file '$RecommendationRulesPath' does not contain a 'rules' array at the root." -Level "WARNING"
                }
            } catch {
                Write-Log "Failed to load or parse rules file '$RecommendationRulesPath'. Error: $($_.Exception.Message)" -Level "ERROR"
            }
        } else {
            Write-Log "Recommendation rules file not found at: $RecommendationRulesPath" -Level "WARNING"
        }
    }

    if ($recommendationRules.Count -eq 0) {
        Write-Log "Using hardcoded recommendation rules."
        $recommendationRules = @(
            @{
                RuleName = "ServiceUnexpectedTerminationRule"
                IfCondition = @{ PatternName = "ServiceTerminatedUnexpectedly" } # Matches output from Find-DiagnosticPattern
                # Alternate condition for features from ConvertTo-AIFeatures (less specific)
                # IfCondition = @{ "Feature_Message_Keyword_terminated_unexpectedly_Count" = @{ GreaterThan = 0 } } # TODO: Implement GreaterThan
                ThenRecommend = @(
                    @{ RecommendationId="REC_SVC001"; Title="Check Service Logs"; Description="Review detailed logs for the affected service to find specific error messages leading to termination."; Severity="High"; Confidence=0.8 },
                    @{ RecommendationId="REC_SVC002"; Title="Verify Service Dependencies"; Description="Ensure all service dependencies are running correctly."; Severity="Medium"; Confidence=0.7 },
                    @{ RecommendationId="REC_SVC003"; Title="Restart Service (Controlled)"; Description="Attempt a controlled restart of the service. Monitor closely after restart."; Severity="Medium"; Confidence=0.6 }
                )
            },
            @{
                RuleName = "NetworkConnectionFailureRule"
                IfCondition = @{ PatternName = "NetworkConnectionFailure" }
                ThenRecommend = @(
                    @{ RecommendationId="REC_NET001"; Title="Verify Network Adapter Status"; Description="Check the status of network adapters on the machine (ipconfig, Get-NetAdapter)."; Severity="High"; Confidence=0.8 },
                    @{ RecommendationId="REC_NET002"; Title="Check DNS Client Configuration"; Description="Ensure DNS client settings are correct and DNS servers are reachable (nslookup, Test-DnsServer)."; Severity="Medium"; Confidence=0.75 },
                    @{ RecommendationId="REC_NET003"; Title="Test Connectivity to Endpoints"; Description="Use ping, Test-NetConnection, or tracert to verify connectivity to essential network endpoints or gateways."; Severity="Medium"; Confidence=0.7 }
                )
            },
            @{ # Example rule for feature from ConvertTo-AIFeatures.ps1
                RuleName = "HighApplicationErrorCountRule"
                # This condition assumes a feature like 'Feature_Message_Keyword_application_error_Count'
                # The current IfCondition logic only supports exact match on property names.
                # A more advanced evaluator would be needed for 'GreaterThan' etc.
                # For now, let's assume a specific feature name indicates this.
                IfCondition = @{ "Feature_Message_Keyword_application_error_Count_Exists" = $true } # A way to check if this feature was generated and non-zero
                ThenRecommend = @(
                     @{ RecommendationId="REC_APP001"; Title="Investigate Application Logs"; Description="High count of 'application error' keywords detected. Review specific application logs for details."; Severity="High"; Confidence=0.7 }
                )
            }
        )
        Write-Log "Loaded $($recommendationRules.Count) hardcoded rules."
    }

    $results = [System.Collections.ArrayList]::new()

    foreach ($inputItem in $InputFeatures) {
        $itemRecommendations = [System.Collections.ArrayList]::new()
        Write-Log "Processing input item: $($inputItem | Out-String -Width 200)" -Level "DEBUG"

        foreach ($rule in $recommendationRules) {
            if ($itemRecommendations.Count -ge $MaxRecommendationsPerInput) {
                break # Max recommendations for this item reached
            }

            $conditionMet = $false
            # --- Condition Evaluation (Simplified: exact match for now) ---
            if ($rule.IfCondition -is [hashtable]) {
                $allSubConditionsMet = $true
                foreach ($key in $rule.IfCondition.Keys) {
                    if ($inputItem.PSObject.Properties[$key]) {
                        $inputValue = $inputItem.$($key)
                        $conditionValue = $rule.IfCondition[$key]

                        if ($conditionValue -is [hashtable] -and $conditionValue.ContainsKey("GreaterThan")) {
                             # Placeholder for GreaterThan logic - current version will not satisfy this
                            if (-not ($inputValue -is [int] -or $inputValue -is [double])) { $allSubConditionsMet = $false; break }
                            if ($inputValue -gt $conditionValue.GreaterThan) { 
                                # Condition met
                            } else { $allSubConditionsMet = $false; break }
                        } elseif ($key -eq "Feature_Message_Keyword_application_error_Count_Exists") {
                            # Special handling for the example rule (checking existence and non-zero)
                            if ($inputItem.PSObject.Properties["Feature_Message_Keyword_application_error_Count"] -and `
                                $inputItem."Feature_Message_Keyword_application_error_Count" -gt 0) {
                                # Condition met
                            } else { $allSubConditionsMet = $false; break}
                        }
                        elseif ($inputValue -ne $conditionValue) { # Simple equality check
                            $allSubConditionsMet = $false
                            break
                        }
                        # TODO: Add more operators like Contains, RegexMatch, LessThan etc.
                    } else { # Property for condition does not exist on input item
                        $allSubConditionsMet = $false
                        break
                    }
                }
                if ($allSubConditionsMet) { $conditionMet = $true }
            }

            if ($conditionMet) {
                Write-Log "Rule '$($rule.RuleName)' matched for an input item."
                foreach($rec in $rule.ThenRecommend){
                    if ($itemRecommendations.Count -lt $MaxRecommendationsPerInput) {
                        $itemRecommendations.Add($rec) | Out-Null
                    } else { break }
                }
            }
        }

        if ($itemRecommendations.Count -gt 0) {
            $results.Add([PSCustomObject]@{
                InputItem       = $inputItem 
                Recommendations = $itemRecommendations
            }) | Out-Null
            Write-Log "Added $($itemRecommendations.Count) recommendations for an input item."
        }
    }

    Write-Log "Get-AIRecommendations script finished. Generated recommendations for $($results.Count) input items."
    return $results
}

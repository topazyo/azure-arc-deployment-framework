# Get-IssueRecommendation.ps1
# This script provides recommendations for a given issue object based on a set of rules.
# TODO: Enhance rule condition logic (e.g., regex matching for descriptions, more complex property checks).
# TODO: Allow multiple recommendations per rule, or prioritization of rules.

Function Get-IssueRecommendation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Issue, # Expected to have Type, Component, Severity, Description, IssueId properties

        [Parameter(Mandatory=$false)]
        [object]$RecommendationRules, # Path to JSON file or direct PSCustomObject/Hashtable

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\GetIssueRecommendation_Activity.log"
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

    # --- Severity Order Mapping ---
    $severityOrder = @{
        "Critical" = 4
        "High" = 3
        "Medium" = 2
        "Low" = 1
        "Informational" = 0
        "Unknown" = -1 # Or however you want to treat unknown severity
    }

    Write-Log "Starting Get-IssueRecommendation for Issue: $($Issue | Out-String -Depth 2 -Width 100)."

    if (-not $Issue -or -not $Issue.PSObject.Properties['Type'] -or -not $Issue.PSObject.Properties['Severity'] -or -not $Issue.PSObject.Properties['Description']) {
        Write-Log "Input -Issue object is missing one or more required properties (Type, Severity, Description)." -Level "ERROR"
        return @(
            [PSCustomObject]@{
                RecommendationId = "REC_ERR_BADINPUT"
                IssueType = $Issue.Type # Or "Unknown"
                IssueComponent = $Issue.Component # Or "Unknown"
                RecommendationText = "Invalid input issue object provided. Cannot generate recommendations."
                FurtherDiagnosticsSuggested = @()
                SourceRuleName = "InputValidation"
                Severity = "Critical" # Severity of the recommendation itself
            }
        )
    }


    $loadedRules = @()
    if ($RecommendationRules) {
        if ($RecommendationRules -is [string]) {
            $rulesPath = $RecommendationRules
            Write-Log "Loading recommendation rules from path: $rulesPath"
            if (Test-Path $rulesPath -PathType Leaf) {
                try {
                    $jsonContent = Get-Content -Path $rulesPath -Raw | ConvertFrom-Json -ErrorAction Stop
                    if ($jsonContent.recommendations) {
                        $loadedRules = $jsonContent.recommendations
                        Write-Log "Successfully loaded $($loadedRules.Count) recommendation rules from JSON file."
                    } else {
                        Write-Log "Rules file '$rulesPath' does not contain a 'recommendations' array at the root." -Level "WARNING"
                    }
                } catch {
                    Write-Log "Failed to load or parse recommendation rules file '$rulesPath'. Error: $($_.Exception.Message)" -Level "ERROR"
                }
            } else { Write-Log "Recommendation rules file not found at: $rulesPath" -Level "WARNING" }
        } elseif (($RecommendationRules -is [hashtable] -or $RecommendationRules -is [pscustomobject]) -and $RecommendationRules.recommendations) {
            Write-Log "Using provided RecommendationRules object."
            $loadedRules = $RecommendationRules.recommendations
        } elseif ($RecommendationRules -is [array]) { # If an array of rules is passed directly
             Write-Log "Using provided array of RecommendationRules."
             $loadedRules = $RecommendationRules
        }
         else {
            Write-Log "Invalid RecommendationRules parameter. Expected path (string), object with 'recommendations' property, or array of rules." -Level "ERROR"
        }
    }

    if ($loadedRules.Count -eq 0) {
        Write-Log "Using hardcoded default recommendation rules."
        $loadedRules = @(
            @{
                RuleName = "DefaultArcConnectivityRule"
                AppliesToIssueType = "Connectivity"
                AppliesToComponent = "ArcAgent" # Optional
                KeywordsInDescription = @("Cannot reach", "endpoint", "failed to connect")
                MinSeverity = "Warning"
                RecommendationText = "Verify firewall outbound rules for Azure Arc endpoints (TCP 443 to *.guestconfiguration.azure.com, etc.). Check local DNS resolution for Azure service endpoints. Run connectivity tests."
                RecommendationId = "REC_ARC_CONN_001"
                FurtherDiagnostics = @("Test-ArcConnectivity -Detailed", "Test-NetConnection -ComputerName <specific-endpoint> -Port 443")
            },
            @{
                RuleName = "DefaultHimdsServiceRule"
                AppliesToIssueType = "Service"
                AppliesToComponent = "himds"
                RecommendationText = "The 'himds' (Azure Connected Machine Agent) service is critical. Attempt to restart it. If restart fails, check 'C:\ProgramData\AzureConnectedMachineAgent\Log\himds.log' for errors."
                RecommendationId = "REC_ARC_SVC_HIMDS_001"
                FurtherDiagnostics = @("Get-Service himds", "Get-WinEvent -LogName 'Microsoft-Windows-AzureConnectedMachineAgent/Operational' -MaxEvents 10")
            },
            @{
                RuleName = "DefaultAMAServiceRule"
                AppliesToIssueType = "DataCollection" # Assuming AMA issues are typed as DataCollection
                AppliesToComponent = "AzureMonitorAgent"
                RecommendationText = "The Azure Monitor Agent (AMA) is having issues. Check DCR associations using Get-DataCollectionRules.ps1. Review AMA logs at 'C:\Resources\AzureMonitorAgent\*\Logs'."
                RecommendationId = "REC_AMA_GEN_001"
                FurtherDiagnostics = @("Get-Service AzureMonitorAgent", "Get-DataCollectionRules -ServerName $env:COMPUTERNAME")
            }
        )
        Write-Log "Loaded $($loadedRules.Count) hardcoded rules."
    }

    $matchingRecommendations = [System.Collections.ArrayList]::new()

    foreach ($rule in $loadedRules) {
        $ruleMatches = $true # Assume match until a condition fails

        # Type Check (Mandatory)
        if ($rule.PSObject.Properties['AppliesToIssueType'] -and $Issue.Type -notmatch [regex]::Escape($rule.AppliesToIssueType)) { # Allow regex for Type matching if needed, else -ne
            $ruleMatches = $false
            Write-Log "Rule '$($rule.RuleName)': IssueType mismatch (Rule: '$($rule.AppliesToIssueType)', Issue: '$($Issue.Type)')" -Level "DEBUG"
        }

        # Component Check (Optional in rule)
        if ($ruleMatches -and $rule.PSObject.Properties['AppliesToComponent'] -and -not [string]::IsNullOrWhiteSpace($rule.AppliesToComponent)) {
            if (-not $Issue.PSObject.Properties['Component'] -or $Issue.Component -notmatch [regex]::Escape($rule.AppliesToComponent)) {
                $ruleMatches = $false
                Write-Log "Rule '$($rule.RuleName)': Component mismatch (Rule: '$($rule.AppliesToComponent)', Issue: '$($Issue.Component)')" -Level "DEBUG"
            }
        }

        # MinSeverity Check (Optional in rule)
        if ($ruleMatches -and $rule.PSObject.Properties['MinSeverity'] -and -not [string]::IsNullOrWhiteSpace($rule.MinSeverity)) {
            $issueSeverityValue = if ($severityOrder.ContainsKey($Issue.Severity)) { $severityOrder[$Issue.Severity] } else { -1 }
            $ruleMinSeverityValue = if ($severityOrder.ContainsKey($rule.MinSeverity)) { $severityOrder[$rule.MinSeverity] } else { 0 } # Default to Info if rule severity is weird

            if ($issueSeverityValue -lt $ruleMinSeverityValue) {
                $ruleMatches = $false
                Write-Log "Rule '$($rule.RuleName)': Severity mismatch (Rule Min: '$($rule.MinSeverity)' ($ruleMinSeverityValue), Issue: '$($Issue.Severity)' ($issueSeverityValue))" -Level "DEBUG"
            }
        }

        # KeywordsInDescription Check (Optional in rule)
        if ($ruleMatches -and $rule.PSObject.Properties['KeywordsInDescription'] -and $rule.KeywordsInDescription -is [array]) {
            $allKeywordsFound = $true
            foreach ($keyword in $rule.KeywordsInDescription) {
                if ($Issue.Description -notmatch [regex]::Escape($keyword)) { # Case-insensitive substring
                    $allKeywordsFound = $false
                    break
                }
            }
            if (-not $allKeywordsFound) {
                $ruleMatches = $false
                Write-Log "Rule '$($rule.RuleName)': Not all keywords found in description." -Level "DEBUG"
            }
        }

        if ($ruleMatches) {
            Write-Log "Rule '$($rule.RuleName)' matched the input issue."
            $matchingRecommendations.Add([PSCustomObject]@{
                RecommendationId          = $rule.RecommendationId
                IssueType                 = $Issue.Type
                IssueComponent            = $Issue.Component
                RecommendationText        = $rule.RecommendationText
                FurtherDiagnosticsSuggested = if($rule.PSObject.Properties['FurtherDiagnostics']){ @($rule.FurtherDiagnostics) } else { @() }
                SourceRuleName            = $rule.RuleName
                RecommendationSeverity    = $rule.Severity # Severity of the recommendation itself, if defined by rule
            }) | Out-Null
        }
    }

    if ($matchingRecommendations.Count -eq 0) {
        Write-Log "No specific recommendation rules matched. Providing a generic recommendation."
        $matchingRecommendations.Add([PSCustomObject]@{
            RecommendationId          = "REC_GENERIC_001"
            IssueType                 = $Issue.Type
            IssueComponent            = $Issue.Component
            RecommendationText        = "No specific automated recommendation found for '$($Issue.Type)' on component '$($Issue.Component)'. Review issue description: '$($Issue.Description)'. Consider checking relevant service logs, event logs, and component-specific documentation or diagnostic tools."
            FurtherDiagnosticsSuggested = @("Get-EventLog -LogName Application -Newest 50 | Where-Object Message -match '$($Issue.Type|$Issue.Component)'") # Generic idea
            SourceRuleName            = "GenericFallback"
            RecommendationSeverity    = "Medium"
        }) | Out-Null
    }

    Write-Log "Get-IssueRecommendation script finished. Found $($matchingRecommendations.Count) recommendations."
    return $matchingRecommendations
}

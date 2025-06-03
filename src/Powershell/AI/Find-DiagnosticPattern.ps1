# Find-DiagnosticPattern.ps1
# This script finds diagnostic patterns in data based on keyword matching.
# TODO: Implement more advanced pattern types like EventSequence.

Function Find-DiagnosticPattern {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [object[]]$InputData,

        [Parameter(Mandatory=$false)]
        [string]$PatternDefinitionPath,

        [Parameter(Mandatory=$false)]
        [int]$MaxPatternsToReturn = 10,

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\FindDiagnosticPattern_Activity.log"
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
            Write-Warning "Failed to write to activity log file $Path. Error: $($_.Exception.Message). Logging to console instead."
            Write-Host $logEntry # Fallback to console
        }
    }

    Write-Log "Starting Find-DiagnosticPattern script."
    Write-Log "InputData count: $($InputData.Count). MaxPatternsToReturn: $MaxPatternsToReturn."

    $patterns = @()

    if (-not [string]::IsNullOrWhiteSpace($PatternDefinitionPath)) {
        Write-Log "Loading pattern definitions from: $PatternDefinitionPath"
        if (Test-Path $PatternDefinitionPath -PathType Leaf) {
            try {
                $jsonContent = Get-Content -Path $PatternDefinitionPath -Raw | ConvertFrom-Json -ErrorAction Stop
                if ($jsonContent.patterns) {
                    $patterns = $jsonContent.patterns
                    Write-Log "Successfully loaded $($patterns.Count) patterns from JSON file."
                } else {
                    Write-Log "Pattern file '$PatternDefinitionPath' does not contain a 'patterns' array at the root." -Level "WARNING"
                }
            } catch {
                Write-Log "Failed to load or parse pattern definition file '$PatternDefinitionPath'. Error: $($_.Exception.Message)" -Level "ERROR"
                # Fallback to hardcoded or exit, for now, use hardcoded if file load fails
            }
        } else {
            Write-Log "Pattern definition file not found at: $PatternDefinitionPath" -Level "WARNING"
        }
    }

    if ($patterns.Count -eq 0) {
        Write-Log "Using hardcoded pattern definitions."
        $patterns = @(
            @{
                PatternName = "ServiceTerminatedUnexpectedly"
                Description = "Events indicating a service terminated unexpectedly (e.g., Event ID 7034 or similar)."
                Type = "KeywordMatch"
                Conditions = @(
                    @{ EventProperty="Message"; Keywords=@("terminated unexpectedly"); MinOccurrences=1 }
                    # Optionally, add EventID or Source checks here if desired for this specific pattern
                    # e.g. @{ EventProperty="EventId"; ExactValue=7034 } # Not implemented in this version's matching
                )
            },
            @{
                PatternName = "ApplicationErrorGeneric"
                Description = "Generic application error messages."
                Type = "KeywordMatch"
                Conditions = @(
                    @{ EventProperty="Message"; Keywords=@("application error", "failed"); MinOccurrences=1 }
                )
            },
            @{
                PatternName = "NetworkConnectionFailure"
                Description = "Events indicating network connection failures or DNS issues."
                Type = "KeywordMatch"
                Conditions = @(
                    @{ EventProperty="Message"; Keywords=@("network connection", "failed to connect", "dns resolution"); MinOccurrences=1 }
                    # Example of targeting a specific source:
                    # @{ EventProperty="Source"; ExactValue="Microsoft-Windows-DNS-Client" } # Not implemented in this version
                )
            }
        )
        Write-Log "Loaded $($patterns.Count) hardcoded patterns."
    }

    $matchedPatternsOutput = [System.Collections.ArrayList]::new()

    foreach ($pattern in $patterns) {
        if ($matchedPatternsOutput.Count -ge $MaxPatternsToReturn) {
            Write-Log "Reached MaxPatternsToReturn ($MaxPatternsToReturn). Stopping pattern search."
            break
        }

        Write-Log "Processing pattern: '$($pattern.PatternName)' of Type: '$($pattern.Type)'"
        if ($pattern.Type -ne "KeywordMatch") {
            Write-Log "Skipping pattern '$($pattern.PatternName)' as its type '$($pattern.Type)' is not supported in this version." -Level "WARNING"
            continue
        }

        $overallMatchingItems = [System.Collections.ArrayList]::new()
        $allConditionsMetForPattern = $true

        foreach ($condition in $pattern.Conditions) {
            if ($condition.EventProperty -ne "Message") { # Simplified: only supporting Message property for keywords
                Write-Log "Skipping condition for pattern '$($pattern.PatternName)' as EventProperty '$($condition.EventProperty)' is not 'Message' (only 'Message' supported for KeywordMatch)." -Level "WARNING"
                continue
            }

            $keywords = @($condition.Keywords) # Ensure it's an array
            $minOccurrences = if ($condition.PSObject.Properties.Name -contains 'MinOccurrences') { $condition.MinOccurrences } else { 1 }

            $conditionMatchingItems = [System.Collections.ArrayList]::new()

            foreach ($item in $InputData) {
                if (-not ($item.PSObject.Properties.Name -contains $condition.EventProperty)) {
                    # Write-Log "Input item does not have property '$($condition.EventProperty)'. Skipping item for this condition." -Level "DEBUG" # Can be too verbose
                    continue
                }

                $propertyValue = $item.($condition.EventProperty)
                if (-not ($propertyValue -is [string])) {
                    # Write-Log "Property '$($condition.EventProperty)' is not a string. Skipping item for this condition." -Level "DEBUG"
                    continue
                }

                $allKeywordsInItem = $true
                foreach ($keyword in $keywords) {
                    if ($propertyValue -notmatch [regex]::Escape($keyword)) { # Use -notmatch for simple substring check, case-insensitive by default
                        $allKeywordsInItem = $false
                        break
                    }
                }

                if ($allKeywordsInItem) {
                    $conditionMatchingItems.Add($item) | Out-Null
                }
            }

            Write-Log "Pattern '$($pattern.PatternName)', Condition (Keywords: $($keywords -join ', ')): Found $($conditionMatchingItems.Count) items."
            if ($conditionMatchingItems.Count -lt $minOccurrences) {
                $allConditionsMetForPattern = $false
                Write-Log "Pattern '$($pattern.PatternName)' did not meet MinOccurrences ($minOccurrences) for a condition. Required: $minOccurrences, Found: $($conditionMatchingItems.Count)."
                break # Stop processing other conditions for this pattern
            }

            # For simplicity, if multiple conditions, this adds all items that met *this* condition.
            # A more complex AND logic would require intersection of items across conditions.
            # Current logic: if all conditions meet their minOccurrences independently, the pattern is a match.
            # The items added are from the last processed condition if multiple keyword conditions existed (which is not typical for this simplified version).
            # For this version with single "Message" property condition, this is fine.
            $overallMatchingItems.AddRange($conditionMatchingItems) # This might add duplicates if item matched multiple keyword sets for a pattern
        }


        if ($allConditionsMetForPattern -and $overallMatchingItems.Count -gt 0) {
            # Remove duplicates if items were added from multiple conditions (though current logic implies one keyword condition per pattern)
            $distinctMatchingItems = $overallMatchingItems | Sort-Object -Unique # Simple way to get distinct items

            Write-Log "Pattern '$($pattern.PatternName)' MATCHED with $($distinctMatchingItems.Count) distinct items." -Level "INFO"

            $exampleItems = $distinctMatchingItems | Select-Object -First 5 # Take up to 5 examples

            $matchedPatternsOutput.Add([PSCustomObject]@{
                PatternName         = $pattern.PatternName
                Description         = $pattern.Description
                MatchedItemCount    = $distinctMatchingItems.Count
                ExampleMatchedItems = $exampleItems
            }) | Out-Null
        }
    }

    Write-Log "Find-DiagnosticPattern script finished. Found $($matchedPatternsOutput.Count) distinct patterns."
    return $matchedPatternsOutput
}

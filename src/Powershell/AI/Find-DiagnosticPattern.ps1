# Find-DiagnosticPattern.ps1
# This script finds diagnostic patterns in data based on keyword matching.
# TODO: Implement more advanced pattern types like EventSequence.

[CmdletBinding()]
param(
    [Parameter()] [object[]]$InputData,
    [Parameter()] [string]$PatternDefinitionPath,
    [Parameter()] [int]$MaxPatternsToReturn = 10,
    [Parameter()] [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\FindDiagnosticPattern_Activity.log"
)

if (-not (Get-Command -Name Write-Log -ErrorAction SilentlyContinue)) {
    function Write-Log {
        param (
            [string]$Message,
            [string]$Level = "INFO",
            [string]$Path = $LogPath
        )
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$Level] $Message"
        try {
            if (-not (Test-Path (Split-Path $Path -Parent) -PathType Container)) {
                New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force -ErrorAction Stop | Out-Null
            }
            Add-Content -Path $Path -Value $logEntry -ErrorAction Stop
        } catch {
            Write-Warning "Failed to write to activity log file $Path. Error: $($_.Exception.Message). Logging to console instead."
            Write-Host $logEntry
        }
    }
}

function Find-DiagnosticPattern {
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

    Write-Log -Message "Starting Find-DiagnosticPattern script." -Path $LogPath
    Write-Log -Message "InputData count: $($InputData.Count). MaxPatternsToReturn: $MaxPatternsToReturn." -Path $LogPath

    $patterns = @()

    if (-not [string]::IsNullOrWhiteSpace($PatternDefinitionPath)) {
        Write-Log -Message "Loading pattern definitions from: $PatternDefinitionPath" -Path $LogPath
        if (Test-Path $PatternDefinitionPath -PathType Leaf) {
            try {
                $jsonContent = Get-Content -Path $PatternDefinitionPath -Raw | ConvertFrom-Json -ErrorAction Stop
                $parsedPatterns = $null
                if ($jsonContent -is [hashtable]) {
                    if ($jsonContent.ContainsKey('patterns')) { $parsedPatterns = $jsonContent['patterns'] }
                } elseif ($jsonContent.PSObject.Properties.Name -contains 'patterns') {
                    $parsedPatterns = $jsonContent.patterns
                }

                if ($parsedPatterns) {
                    $patterns = @($parsedPatterns)
                    Write-Log -Message "Successfully loaded $($patterns.Count) patterns from JSON file." -Path $LogPath
                } else {
                    Write-Log -Message "Pattern file '$PatternDefinitionPath' does not contain a 'patterns' array at the root." -Level "WARNING" -Path $LogPath
                }
            } catch {
                Write-Log -Message "Failed to load or parse pattern definition file '$PatternDefinitionPath'. Error: $($_.Exception.Message)" -Level "ERROR" -Path $LogPath
            }
        } else {
            Write-Log -Message "Pattern definition file not found at: $PatternDefinitionPath" -Level "WARNING" -Path $LogPath
        }
    }

    if ($patterns.Count -eq 0) {
        Write-Log -Message "Using hardcoded pattern definitions." -Path $LogPath
        $patterns = @(
            @{
                PatternName = "ServiceTerminatedUnexpectedly"
                Description = "Events indicating a service terminated unexpectedly (e.g., Event ID 7034 or similar)."
                Type = "KeywordMatch"
                Conditions = @(
                    @{ EventProperty="Message"; Keywords=@("terminated unexpectedly"); MinOccurrences=1 }
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
                )
            }
        )
        Write-Log -Message "Loaded $($patterns.Count) hardcoded patterns." -Path $LogPath
    }

    $matchedPatternsOutput = [System.Collections.ArrayList]::new()

    foreach ($pattern in $patterns) {
        if ($matchedPatternsOutput.Count -ge $MaxPatternsToReturn) {
            Write-Log "Reached MaxPatternsToReturn ($MaxPatternsToReturn). Stopping pattern search." -Path $LogPath
            break
        }

        Write-Log -Message "Processing pattern: '$($pattern.PatternName)' of Type: '$($pattern.Type)'" -Path $LogPath
        if ($pattern.Type -ne "KeywordMatch") {
            Write-Log -Message "Skipping pattern '$($pattern.PatternName)' as its type '$($pattern.Type)' is not supported in this version." -Level "WARNING" -Path $LogPath
            continue
        }

        $overallMatchingItems = [System.Collections.ArrayList]::new()
        $allConditionsMetForPattern = $true

        foreach ($condition in $pattern.Conditions) {
            if ($condition.EventProperty -ne "Message") {
                Write-Log "Skipping condition for pattern '$($pattern.PatternName)' as EventProperty '$($condition.EventProperty)' is not 'Message' (only 'Message' supported for KeywordMatch)." -Level "WARNING" -Path $LogPath
                continue
            }

            $keywords = @($condition.Keywords)
            $minOccurrences = if ($condition.PSObject.Properties.Name -contains 'MinOccurrences') { $condition.MinOccurrences } else { 1 }
            
            $conditionMatchingItems = [System.Collections.ArrayList]::new()

            foreach ($item in $InputData) {
                if (-not ($item.PSObject.Properties.Name -contains $condition.EventProperty)) {
                    continue
                }
                
                $propertyValue = $item.($condition.EventProperty)
                if (-not ($propertyValue -is [string])) {
                    continue
                }

                $allKeywordsInItem = $true
                foreach ($keyword in $keywords) {
                    if ($propertyValue -notmatch [regex]::Escape($keyword)) {
                        $allKeywordsInItem = $false
                        break
                    }
                }

                if ($allKeywordsInItem) {
                    $conditionMatchingItems.Add($item) | Out-Null
                }
            }
            
            Write-Log -Message "Pattern '$($pattern.PatternName)', Condition (Keywords: $($keywords -join ', ')): Found $($conditionMatchingItems.Count) items." -Path $LogPath
            if ($conditionMatchingItems.Count -lt $minOccurrences) {
                $allConditionsMetForPattern = $false
                Write-Log -Message "Pattern '$($pattern.PatternName)' did not meet MinOccurrences ($minOccurrences) for a condition. Required: $minOccurrences, Found: $($conditionMatchingItems.Count)." -Path $LogPath
                break
            }
            
            $overallMatchingItems.AddRange($conditionMatchingItems)
        }

        if ($allConditionsMetForPattern -and $overallMatchingItems.Count -gt 0) {
            $distinctMatchingItems = $overallMatchingItems
            Write-Log -Message "Pattern '$($pattern.PatternName)' MATCHED with $($distinctMatchingItems.Count) distinct items." -Level "INFO" -Path $LogPath
            
            $exampleItems = $distinctMatchingItems | Select-Object -First 5

            $matchedPatternsOutput.Add([PSCustomObject]@{
                PatternName         = $pattern.PatternName
                Description         = $pattern.Description
                MatchedItemCount    = $distinctMatchingItems.Count
                ExampleMatchedItems = $exampleItems
            }) | Out-Null
        }
    }

    Write-Log -Message "Pattern search completed with $($matchedPatternsOutput.Count) matched patterns." -Path $LogPath
    return ,$matchedPatternsOutput
}

if ($PSBoundParameters.Count -gt 0) {
    return Find-DiagnosticPattern @PSBoundParameters
}

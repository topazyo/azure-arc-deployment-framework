# Find-CommonPatterns.ps1
# This script identifies common patterns or frequently occurring issues from input data.
# V1: Definition-based mode looks for co-occurrence of specified issue types/components.
# V1: No-definition mode identifies frequently occurring individual issue type/component pairs.
# TODO: Enhance no-definition mode for true co-occurrence pattern mining if needed.
# TODO: Add time window considerations for definition-based patterns.

Function Find-CommonPatterns {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [object[]]$IdentifiedIssues,

        [Parameter(Mandatory=$false)]
        [object]$PatternDefinitions, # Path to JSON file or direct PSCustomObject/Hashtable

        [Parameter(Mandatory=$false)]
        [int]$MinFrequency = 2, # For no-definition mode: min occurrences of an IssueType_Component. For definition mode, MinOccurrenceOfEach in pattern is used.

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\FindCommonPatterns_Activity.log"
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

    Write-Log "Starting Find-CommonPatterns script. IdentifiedIssues count: $($IdentifiedIssues.Count)."

    $loadedPatternDefs = $null
    if ($PatternDefinitions) {
        if ($PatternDefinitions -is [string]) {
            $defPath = $PatternDefinitions
            Write-Log "Loading PatternDefinitions from path: $defPath"
            if (Test-Path $defPath -PathType Leaf) {
                try {
                    $loadedPatternDefs = Get-Content -Path $defPath -Raw | ConvertFrom-Json -ErrorAction Stop
                    Write-Log "Successfully loaded PatternDefinitions from JSON."
                } catch {
                    Write-Log "Failed to load or parse PatternDefinitions JSON from '$defPath'. Error: $($_.Exception.Message)" -Level "ERROR"
                }
            } else { Write-Log "PatternDefinitions path not found: $defPath" -Level "ERROR" }
        } elseif ($PatternDefinitions -is [hashtable] -or $PatternDefinitions -is [pscustomobject]) {
            Write-Log "Using provided PatternDefinitions object."
            $loadedPatternDefs = $PatternDefinitions
        } else {
            Write-Log "Invalid PatternDefinitions parameter type: $($PatternDefinitions.GetType().FullName)." -Level "ERROR"
        }
    }

    $foundCommonPatterns = [System.Collections.ArrayList]::new()

    if ($loadedPatternDefs -and $loadedPatternDefs.commonIssueCombinations) {
        Write-Log "Processing using defined commonIssueCombinations from PatternDefinitions. Rule count: $($loadedPatternDefs.commonIssueCombinations.Count)."
        foreach ($patternDef in $loadedPatternDefs.commonIssueCombinations) {
            Write-Log "Evaluating defined pattern: '$($patternDef.PatternName)'." -Level "DEBUG"
            $minOccurrenceOfEach = if ($patternDef.PSObject.Properties.Contains('MinOccurrenceOfEach')) { $patternDef.MinOccurrenceOfEach } else { 1 }
            $allCriteriaMet = $true
            $contributingIssueTypeCounts = @{} # Store counts for each criterion
            $sourceIssuesForPattern = [System.Collections.ArrayList]::new()

            for ($i = 0; $i -lt $patternDef.LookForIssueTypes.Count; $i++) {
                $targetType = $patternDef.LookForIssueTypes[$i]
                $targetComponent = if ($patternDef.AndComponents -and $i -lt $patternDef.AndComponents.Count) { $patternDef.AndComponents[$i] } else { $null }

                $matchingIssuesThisCriterion = $IdentifiedIssues | Where-Object {
                    $typeMatch = ($_.PSObject.Properties['Type'] -and $_.Type -eq $targetType)
                    $componentMatch = $true # Assume true if no target component specified
                    if ($targetComponent) {
                        $componentMatch = ($_.PSObject.Properties['Component'] -and $_.Component -eq $targetComponent)
                    }
                    $typeMatch -and $componentMatch
                }

                $criterionKey = if($targetComponent) { "$($targetType)_$($targetComponent)" } else { $targetType }
                $contributingIssueTypeCounts[$criterionKey] = $matchingIssuesThisCriterion.Count

                if ($matchingIssuesThisCriterion.Count -lt $minOccurrenceOfEach) {
                    $allCriteriaMet = $false
                    Write-Log "Pattern '$($patternDef.PatternName)' not met: Criterion '$criterionKey' found $($matchingIssuesThisCriterion.Count) times, need $minOccurrenceOfEach." -Level "DEBUG"
                    break
                }
                # Add these specific matching issues to a temporary list for this pattern
                $matchingIssuesThisCriterion | ForEach-Object { $sourceIssuesForPattern.Add($_) | Out-Null }
            }

            if ($allCriteriaMet) {
                Write-Log "Defined pattern '$($patternDef.PatternName)' matched."
                $foundCommonPatterns.Add([PSCustomObject]@{
                    PatternName             = $patternDef.PatternName
                    Description             = $patternDef.Description
                    Severity                = $patternDef.Severity # Will be null if not defined
                    ContributingIssueCounts = $contributingIssueTypeCounts # Show counts for each part of the combo
                    SourceIssues            = ($sourceIssuesForPattern | Sort-Object -Unique) # All issues that contributed
                    Timestamp               = (Get-Date -Format o)
                }) | Out-Null
            }
        }

    } else {
        Write-Log "No PatternDefinitions provided or loaded, or no 'commonIssueCombinations' found. Performing simple frequency analysis of individual issue types."

        # Simplified V1: Count frequency of each "IssueType_Component"
        $groupedIssues = $IdentifiedIssues | Where-Object {
            $_.PSObject.Properties['Type'] -and $_.PSObject.Properties['Component']
        } | Group-Object { "$($_.Type)_$($_.Component)" }

        foreach ($group in $groupedIssues) {
            if ($group.Count -ge $MinFrequency) {
                Write-Log "Frequent individual issue pattern found: '$($group.Name)' (Count: $($group.Count))."
                $exampleIssues = $group.Group | Select-Object -First 3 # Take a few examples

                $foundCommonPatterns.Add([PSCustomObject]@{
                    PatternName             = "FrequentIssue_$($group.Name -replace '\W','_')"
                    Description             = "The issue type-component pair '$($group.Name)' occurred frequently."
                    Frequency               = $group.Count
                    ExampleIssues           = $exampleIssues
                    Timestamp               = (Get-Date -Format o)
                }) | Out-Null
            }
        }
        if ($foundCommonPatterns.Count -eq 0) {
            Write-Log "No individual issue types met the MinFrequency of $MinFrequency."
        }
    }

    Write-Log "Find-CommonPatterns script finished. Found $($foundCommonPatterns.Count) common patterns/frequent issues."
    return $foundCommonPatterns
}

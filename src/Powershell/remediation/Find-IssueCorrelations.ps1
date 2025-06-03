# Find-IssueCorrelations.ps1
# This script finds time-based correlations between issue/event occurrences in input data.
# TODO: Offer more sophisticated correlation methods (e.g., statistical measures).
# TODO: Enhance identifier creation for more generic input objects.

Function Find-IssueCorrelations {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [object[]]$InputEvents,

        [Parameter(Mandatory=$false)]
        [int]$CorrelationTimeWindowSeconds = 300,

        [Parameter(Mandatory=$false)]
        [string]$PrimaryIssueIdPattern, # If specified, correlates other events around this primary one

        [Parameter(Mandatory=$false)]
        [int]$MinCorrelationCount = 2,

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\FindIssueCorrelations_Activity.log"
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

    Write-Log "Starting Find-IssueCorrelations script. InputEvents count: $($InputEvents.Count)."
    Write-Log "Params: CorrelationTimeWindowSeconds=$CorrelationTimeWindowSeconds, PrimaryIssueIdPattern='$PrimaryIssueIdPattern', MinCorrelationCount=$MinCorrelationCount."

    if ($InputEvents.Count -lt 2) {
        Write-Log "Not enough input events (need at least 2) to find correlations. Exiting." -Level "WARNING"
        return @()
    }

    # --- Input Preparation: Ensure Timestamp and create an Identifier ---
    $processedEvents = [System.Collections.ArrayList]::new()
    foreach ($event in $InputEvents) {
        $timestamp = $null
        try {
            if ($event.PSObject.Properties['Timestamp']) {
                $timestamp = [datetime]$event.Timestamp
            } else {
                Write-Log "Input event missing 'Timestamp' property. $($event | Out-String -Depth 1)" -Level "WARNING"
                continue
            }
        } catch {
            Write-Log "Failed to convert Timestamp to DateTime for an event. Error: $($_.Exception.Message). Event: $($event | Out-String -Depth 1)" -Level "WARNING"
            continue
        }

        # Determine Identifier: Prioritize MatchedIssueId, then PatternName, then try to build one for generic events
        $identifier = $null
        if ($event.PSObject.Properties['MatchedIssueId']) { $identifier = $event.MatchedIssueId }
        elseif ($event.PSObject.Properties['PatternName']) { $identifier = $event.PatternName }
        elseif ($event.PSObject.Properties['EventId'] -and $event.PSObject.Properties['Source']) { $identifier = "Event:$($event.Source):$($event.EventId)" }
        elseif ($event.PSObject.Properties['Source'] -and $event.PSObject.Properties['Message']) { $identifier = "Source:$($event.Source):MsgSubstr:$($event.Message.Substring(0, [System.Math]::Min($event.Message.Length, 20)))" } # Fallback
        else { $identifier = "UnknownEvent_Idx$($processedEvents.Count)" } # Last resort

        $processedEvents.Add([PSCustomObject]@{
            OriginalEvent = $event
            Timestamp = $timestamp
            Identifier = $identifier
            UniqueId = [guid]::NewGuid().ToString() # To distinguish identical events at same timestamp if necessary
        }) | Out-Null
    }

    if ($processedEvents.Count -lt 2) {
        Write-Log "Not enough processable input events (with valid Timestamps and Identifiers) to find correlations. Exiting." -Level "WARNING"
        return @()
    }

    # Sort by Timestamp
    $sortedEvents = $processedEvents | Sort-Object Timestamp
    Write-Log "Processed and sorted $($sortedEvents.Count) events."


    # --- Determine Primary Event Type if not specified ---
    $effectivePrimaryIssueIdPattern = $PrimaryIssueIdPattern
    if ([string]::IsNullOrWhiteSpace($effectivePrimaryIssueIdPattern)) {
        Write-Log "PrimaryIssueIdPattern not specified. Identifying most frequent event type to use as primary."
        $mostFrequent = $sortedEvents | Group-Object Identifier | Sort-Object Count -Descending | Select-Object -First 1
        if ($mostFrequent) {
            $effectivePrimaryIssueIdPattern = $mostFrequent.Name
            Write-Log "Using '$effectivePrimaryIssueIdPattern' (Count: $($mostFrequent.Count)) as the implicit primary event type for correlation."
        } else {
            Write-Log "Could not determine a most frequent event type. Cannot proceed with 'primary event' correlation logic without a PrimaryIssueIdPattern." -Level "ERROR"
            return @()
        }
    }

    $correlations = @{} # Hashtable to store counts of correlated pairs
    $primaryEventOccurrences = [System.Collections.ArrayList]::new()

    Write-Log "Finding correlations around primary event type: '$effectivePrimaryIssueIdPattern'"

    $primaryEvents = $sortedEvents | Where-Object { $_.Identifier -eq $effectivePrimaryIssueIdPattern }

    if ($primaryEvents.Count -eq 0) {
        Write-Log "No instances of primary event type '$effectivePrimaryIssueIdPattern' found in the input data." -Level "WARNING"
        return @()
    }
    Write-Log "Found $($primaryEvents.Count) instances of the primary event type '$effectivePrimaryIssueIdPattern'."

    foreach ($pEvent in $primaryEvents) {
        $primaryEventOccurrences.Add($pEvent.Timestamp) | Out-Null # Store timestamp for output later
        $windowStart = $pEvent.Timestamp.AddSeconds(-$CorrelationTimeWindowSeconds / 2)
        $windowEnd = $pEvent.Timestamp.AddSeconds($CorrelationTimeWindowSeconds / 2)

        Write-Log "Analyzing window for primary event at $($pEvent.Timestamp): $windowStart to $windowEnd" -Level "DEBUG"

        # Iterate through ALL sorted events to find those within the window of pEvent
        # Exclude the primary event itself from being correlated with itself in this direct manner
        $eventsInWindow = $sortedEvents | Where-Object {
            $_.UniqueId -ne $pEvent.UniqueId -and # Not the exact same event instance
            $_.Timestamp -ge $windowStart -and $_.Timestamp -le $windowEnd
        }

        foreach ($sEvent in $eventsInWindow) {
            # Create a consistent key for the pair (sort identifiers alphabetically)
            $pair = @($pEvent.Identifier, $sEvent.Identifier) | Sort-Object
            $correlationKey = "$($pair[0]) <-> $($pair[1])"

            if ($correlations.ContainsKey($correlationKey)) {
                $correlations[$correlationKey]++
            } else {
                $correlations[$correlationKey] = 1
            }
            Write-Log "Found potential correlation: Key='$correlationKey', pEventTime='$($pEvent.Timestamp)', sEventTime='$($sEvent.Timestamp)'" -Level "DEBUG"
        }
    }

    # --- Filter by MinCorrelationCount and Format Output ---
    $outputCorrelations = [System.Collections.ArrayList]::new()
    foreach ($key in $correlations.Keys) {
        if ($correlations[$key] -ge $MinCorrelationCount) {
            $identifiers = $key.Split(" <-> ")
            # Ensure the PrimaryEventIdentifier in output matches the one we focused on
            $primaryOut = $identifiers | Where-Object { $_ -eq $effectivePrimaryIssueIdPattern } | Select-Object -First 1
            $correlatedOut = $identifiers | Where-Object { $_ -ne $effectivePrimaryIssueIdPattern } | Select-Object -First 1

            # If both are same as primary (self-correlation for frequent primary events within window of another primary)
            if (-not $correlatedOut -and $identifiers[0] -eq $identifiers[1] -and $identifiers[0] -eq $effectivePrimaryIssueIdPattern) {
                $correlatedOut = $effectivePrimaryIssueIdPattern # Self-correlation case
            } elseif (-not $primaryOut) { # Should not happen if logic is correct
                 $primaryOut = $identifiers[0]
                 $correlatedOut = $identifiers[1]
            }


            $outputCorrelations.Add([PSCustomObject]@{
                PrimaryEventIdentifier    = $primaryOut
                CorrelatedEventIdentifier = $correlatedOut
                CorrelationCount          = $correlations[$key]
                TimeWindowSeconds         = $CorrelationTimeWindowSeconds
                # ExampleTimestamps could be a list of $pEvent.Timestamp where this correlation was observed.
                # This requires more complex tracking if we want timestamps for each pair occurrence.
                # For now, we'll list timestamps of the primary event type used for this analysis batch.
                ExamplePrimaryEventTimestamps = ($primaryEventOccurrences | Select-Object -Unique | Sort-Object | Select -First 5)
            }) | Out-Null
            Write-Log "Significant correlation found: '$key', Count: $($correlations[$key])"
        }
    }

    Write-Log "Find-IssueCorrelations script finished. Found $($outputCorrelations.Count) significant correlations meeting MinCorrelationCount=$MinCorrelationCount."
    return $outputCorrelations | Sort-Object CorrelationCount -Descending
}

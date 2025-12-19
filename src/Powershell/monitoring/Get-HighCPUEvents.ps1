# Get-HighCPUEvents.ps1
# This script retrieves events that may indicate periods of high CPU utilization.
# Note: Windows Event Log does not typically log CPU percentage directly by default. 
# This script looks for indirect evidence or events from specific diagnostic logs.

param (
    [Parameter(Mandatory = $false)]
    [int]$CpuThreshold = 90, # Conceptual: for interpreting event messages if they contain such data
    [Parameter(Mandatory = $false)]
    [int]$DurationThresholdSeconds = 300, # Conceptual: for interpreting event messages

    [Parameter(Mandatory = $false)]
    [int]$MaxEventsPerQuery = 20,

    [Parameter(Mandatory = $false)]
    [datetime]$StartTime,

    [Parameter(Mandatory = $false)]
    [string]$ServerName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\HighCPUEvents_Activity.log"
)

# --- Logging (shared utility) ---
. (Join-Path $PSScriptRoot '..\utils\Write-Log.ps1')

# --- Main Script Logic ---
try {
    Write-Log "Starting Get-HighCPUEvents script."
    Write-Log "Parameters: CpuThreshold='$CpuThreshold' (conceptual), DurationThresholdSeconds='$DurationThresholdSeconds' (conceptual), MaxEventsPerQuery='$MaxEventsPerQuery', StartTime='$StartTime', ServerName='$ServerName'"
    Write-Log "Note: This script looks for indirect logged evidence of high CPU, not direct CPU metrics history."

    if (-not $StartTime) {
        $StartTime = (Get-Date).AddDays(-1) # Default to last 24 hours
        Write-Log "StartTime not specified, defaulting to last 24 hours: $StartTime"
    }

    $allHighCpuRelatedEvents = [System.Collections.ArrayList]::new()

    # Define queries for events that *might* indicate high CPU
    # This is heuristic and depends on what's logged on the system.
    $queries = @(
        @{ 
            LogName='System'; 
            ProviderName='Microsoft-Windows-Resource-Exhaustion-Detector'; 
            Id=2004; # Windows Resource Exhaustion Detector detected a condition
            KeywordsFilter = "CPU", "processor"; # Filter for high CPU related messages
            Label="Resource Exhaustion (System)" 
        },
        @{
            LogName='Microsoft-Windows-Resource-Exhaustion-Resolver/Operational';
            # ProviderName = 'Microsoft-Windows-Resource-Exhaustion-Resolver'; # Optional, if log has multiple providers
            # No specific ID, look for messages mentioning CPU
            KeywordsFilter = "CPU"; # Custom property for filtering messages
            Label="Resource Resolver CPU Related (Operational)"
        },
        @{
            LogName='Microsoft-Windows-Diagnosis-Scheduled/Operational';
            # ProviderName = 'Microsoft-Windows-Diagnosis-Scheduled';
            KeywordsFilter = "CPU", "processor"; # Look for events with these keywords in the message
            Label="Diagnosis Scheduled CPU Related (Operational)"
        }
        # Add other application-specific events if known, e.g., from SCOM agent, APM tools, etc.
        # Example: Application Hang events (ID 1002, source Application Hang) could be correlated
        # but are too broad without further filtering on process names known to be CPU intensive.
    )

    Write-Log "Querying event logs for potential high CPU indicators..."
    
    foreach ($query in $queries) {
        Write-Log "Executing query: LogName='$($query.LogName)', ProviderName='$($query.ProviderName)', ID='$($query.Id)', Label='$($query.Label)', Keywords='$($query.KeywordsFilter)' on '$ServerName' since '$StartTime'."
        try {
            $filterHashtable = @{
                LogName = $query.LogName
                StartTime = $StartTime
            }
            if ($query.Id) { $filterHashtable.Id = $query.Id }
            if ($query.ProviderName) { $filterHashtable.ProviderName = $query.ProviderName }

            $getWinEventParams = @{
                FilterHashtable = $filterHashtable
                MaxEvents = $MaxEventsPerQuery 
                ErrorAction = 'Stop'
            }

            if ($ServerName -ne $env:COMPUTERNAME -and -not ([string]::IsNullOrWhiteSpace($ServerName))) {
                $getWinEventParams.ComputerName = $ServerName
            }
            
            $events = Get-WinEvent @getWinEventParams

            if ($events) {
                $eventCount = 0
                foreach ($event in $events) {
                    $message = $event.Message
                    $match = $true # Assume match unless KeywordsFilter is present

                    if ($query.KeywordsFilter) {
                        $match = $false
                        foreach($keyword in $query.KeywordsFilter){
                            if($message -match $keyword){
                                $match = $true
                                break
                            }
                        }
                    }
                    
                    if($match){
                        $eventCount++
                        $allHighCpuRelatedEvents.Add([PSCustomObject]@{
                            Timestamp   = $event.TimeCreated
                            SourceLog   = $event.LogName
                            EventId     = $event.Id
                            ProviderName= $event.ProviderName
                            Message     = $message 
                            MachineName = $event.MachineName
                            QueryLabel  = $query.Label
                        }) | Out-Null
                    }
                }
                 Write-Log "Found $eventCount relevant events for query [Label: $($query.Label)]."

            } else {
                Write-Log "No events found for query [Label: $($query.Label)] before keyword filtering."
            }
        }
        catch [System.Diagnostics.Eventing.Reader.EventLogNotFoundException],[System.UnauthorizedAccessException] { 
            Write-Log "Failed to execute query [Label: $($query.Label)]. Log '$($query.LogName)' might not exist or is inaccessible on '$ServerName'. Error: $($_.Exception.Message)" -Level "WARNING"
        }
        catch { 
            Write-Log "An error occurred while executing query [Label: $($query.Label)] on '$ServerName'. Error: $($_.Exception.Message)" -Level "ERROR"
        }
    }

    # Sort all collected events by Timestamp
    $sortedEvents = $allHighCpuRelatedEvents | Sort-Object Timestamp -Descending
    
    Write-Log "Get-HighCPUEvents script finished. Total potentially relevant events retrieved: $($sortedEvents.Count)."
    return $sortedEvents

}
catch {
    Write-Log "A critical error occurred in Get-HighCPUEvents script: $($_.Exception.Message)" -Level "FATAL"
    if ($_.ScriptStackTrace) {
        Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "FATAL"
    }
    return @() 
}

# Get-MemoryPressureEvents.ps1
# This script retrieves events that may indicate periods of memory pressure.
# Note: Windows Event Log does not typically log memory utilization percentages directly by default.
# This script looks for indirect evidence or events from specific diagnostic logs.

param (
    [Parameter(Mandatory = $false)]
    [int]$MemoryThresholdPercent = 90, # Conceptual: for interpreting event messages
    [Parameter(Mandatory = $false)]
    [int]$MinAvailableMemoryMB = 100,  # Conceptual: for interpreting event messages

    [Parameter(Mandatory = $false)]
    [int]$MaxEventsPerQuery = 20,

    [Parameter(Mandatory = $false)]
    [datetime]$StartTime,

    [Parameter(Mandatory = $false)]
    [string]$ServerName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\MemoryPressureEvents_Activity.log"
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
        if (-not (Test-Path (Split-Path $Path -Parent))) {
            New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force -ErrorAction Stop | Out-Null
        }
        Add-Content -Path $Path -Value $logEntry -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to write to activity log file $Path. Error: $($_.Exception.Message). Logging to console instead."
        Write-Host $logEntry
    }
}

# --- Main Script Logic ---
try {
    Write-Log "Starting Get-MemoryPressureEvents script."
    Write-Log "Parameters: MemoryThresholdPercent='$MemoryThresholdPercent' (conceptual), MinAvailableMemoryMB='$MinAvailableMemoryMB' (conceptual), MaxEventsPerQuery='$MaxEventsPerQuery', StartTime='$StartTime', ServerName='$ServerName'"
    Write-Log "Note: This script looks for indirect logged evidence of memory pressure, not direct memory metrics history."

    if (-not $StartTime) {
        $StartTime = (Get-Date).AddDays(-1) # Default to last 24 hours
        Write-Log "StartTime not specified, defaulting to last 24 hours: $StartTime"
    }

    $allMemoryPressureEvents = [System.Collections.ArrayList]::new()

    # Define queries for events that *might* indicate memory pressure
    $queries = @(
        @{
            LogName='System';
            ProviderName='Microsoft-Windows-Resource-Exhaustion-Detector';
            Id=2004;
            KeywordsFilter = "memory", "virtual memory"; # Check if message specifically mentions memory
            Label="Resource Exhaustion (System - Memory Related)"
        },
        @{
            LogName='System';
            ProviderName='Microsoft-Windows-ResourcePolicy'; # Provider for event 1106
            Id=1106; # "The system is experiencing memory pressure." - More direct
            Label="Memory Pressure Detected (System)"
        },
        @{
            LogName='Microsoft-Windows-Resource-Exhaustion-Resolver/Operational';
            KeywordsFilter = "memory", "low memory", "virtual memory";
            Label="Resource Resolver Memory Related (Operational)"
        }
        # Application Log: OutOfMemoryExceptions (e.g., .NET Runtime Event ID 1026 with "OutOfMemoryException")
        # are too application-specific to generalize here but could be added with known process/provider names.
    )

    Write-Log "Querying event logs for potential memory pressure indicators..."

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
                    $match = $true

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
                        $allMemoryPressureEvents.Add([PSCustomObject]@{
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
        catch [System.Management.Automation.भूतियाException] {
             Write-Log "Failed to execute query [Label: $($query.Label)]. Log '$($query.LogName)' might not exist or is inaccessible on '$ServerName'. Error: $($_.Exception.Message)" -Level "WARNING"
        }
        catch {
            Write-Log "An error occurred while executing query [Label: $($query.Label)] on '$ServerName'. Error: $($_.Exception.Message)" -Level "ERROR"
        }
    }

    $sortedEvents = $allMemoryPressureEvents | Sort-Object Timestamp -Descending

    Write-Log "Get-MemoryPressureEvents script finished. Total potentially relevant events retrieved: $($sortedEvents.Count)."
    return $sortedEvents

}
catch {
    Write-Log "A critical error occurred in Get-MemoryPressureEvents script: $($_.Exception.Message)" -Level "FATAL"
    if ($_.ScriptStackTrace) {
        Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "FATAL"
    }
    return @()
}

# Get-DiskPressureEvents.ps1
# This script retrieves events that may indicate periods of disk pressure or disk-related issues.

param (
    [Parameter(Mandatory = $false)]
    [int]$DiskSpaceWarningThresholdPercent = 15, # Conceptual for interpreting event messages

    [Parameter(Mandatory = $false)]
    [int]$MaxEventsPerQuery = 20,

    [Parameter(Mandatory = $false)]
    [datetime]$StartTime,

    [Parameter(Mandatory = $false)]
    [string]$ServerName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\DiskPressureEvents_Activity.log"
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

# --- Helper to Extract Drive Letter from Event 2013 Message ---
function Get-DriveLetterFromSrvEvent2013 {
    param ([string]$Message)
    # Message for Event ID 2013 from SRV is typically:
    # "The <DriveLetter>: disk is at or near capacity. You may need to delete some files."
    if ($Message -match "The (.*?): disk is at or near capacity.") {
        return $Matches[1]
    }
    return $null
}


# --- Main Script Logic ---
try {
    Write-Log "Starting Get-DiskPressureEvents script."
    Write-Log "Parameters: DiskSpaceWarningThresholdPercent='$DiskSpaceWarningThresholdPercent' (conceptual), MaxEventsPerQuery='$MaxEventsPerQuery', StartTime='$StartTime', ServerName='$ServerName'"
    Write-Log "Note: This script looks for logged evidence of disk pressure or issues."

    if (-not $StartTime) {
        $StartTime = (Get-Date).AddDays(-1) # Default to last 24 hours
        Write-Log "StartTime not specified, defaulting to last 24 hours: $StartTime"
    }

    $allDiskRelatedEvents = [System.Collections.ArrayList]::new()

    # Define queries for events that *might* indicate disk pressure
    $queries = @(
        @{
            LogName='System';
            ProviderName='srv'; # LanmanServer
            Id=2013;
            Label="Low Disk Space Warning (SRV)"
        },
        @{
            LogName='System';
            ProviderName='Microsoft-Windows-Resource-Exhaustion-Detector';
            Id=2004;
            KeywordsFilter = "disk space", "storage"; # Check if message specifically mentions disk
            Label="Resource Exhaustion (System - Disk Related)"
        },
        @{
            LogName='System';
            ProviderName='Microsoft-Windows-Ntfs'; # Or 'Ntfs' for older systems
            Id= @(9000, 9001); # NTFS errors, can be general disk health not just pressure
            Label="NTFS Error (System)"
        }
        # Microsoft-Windows-StorageSpaces-Driver/Operational for Storage Spaces issues
        # Application logs for specific app errors due to disk full (e.g., database, backup software)
    )

    Write-Log "Querying event logs for potential disk pressure indicators..."

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
                    $driveLetter = $null

                    if ($query.KeywordsFilter) {
                        $match = $false
                        foreach($keyword in $query.KeywordsFilter){
                            if($message -match $keyword){
                                $match = $true
                                break
                            }
                        }
                    }

                    if ($query.Id -eq 2013 -and $event.ProviderName -match "srv") { # Specific to LanmanServer
                         $driveLetter = Get-DriveLetterFromSrvEvent2013 -Message $message
                    }

                    if($match){
                        $eventCount++
                        $allDiskRelatedEvents.Add([PSCustomObject]@{
                            Timestamp   = $event.TimeCreated
                            SourceLog   = $event.LogName
                            EventId     = $event.Id
                            ProviderName= $event.ProviderName
                            Message     = $message
                            DriveLetter = $driveLetter # Populated for event 2013
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

    $sortedEvents = $allDiskRelatedEvents | Sort-Object Timestamp -Descending

    Write-Log "Get-DiskPressureEvents script finished. Total potentially relevant events retrieved: $($sortedEvents.Count)."
    return $sortedEvents

}
catch {
    Write-Log "A critical error occurred in Get-DiskPressureEvents script: $($_.Exception.Message)" -Level "FATAL"
    if ($_.ScriptStackTrace) {
        Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "FATAL"
    }
    return @()
}

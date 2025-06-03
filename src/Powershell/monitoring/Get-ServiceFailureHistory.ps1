# Get-ServiceFailureHistory.ps1
# This script retrieves service failure events from the System event log.

param (
    [Parameter(Mandatory = $false)]
    [string[]]$ServiceName, # Array of service names to filter for, e.g., "himds", "AzureMonitorAgent"

    [Parameter(Mandatory = $false)]
    [int]$MaxEvents = 50, # Max events to retrieve overall, then filter if ServiceName is specified

    [Parameter(Mandatory = $false)]
    [datetime]$StartTime,

    [Parameter(Mandatory = $false)]
    [string]$ServerName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\ServiceFailureHistory_Activity.log"
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

# --- Helper to Extract Service Name from Event ---
function Get-ServiceNameFromEvent {
    param ($Event)
    # Event ID 7034 & 7031: Service name is often Param1 (EventData[0])
    # Event ID 7023 & 7024: Service name is often Param1 (EventData[0])
    if ($Event.Id -in @(7034, 7031, 7023, 7024)) {
        if ($Event.Properties.Count -ge 1) {
            return $Event.Properties[0].Value
        }
    }
    # Fallback: Try to parse from the message (less reliable)
    if ($Event.Message -match "The (.*?) service terminated unexpectedly.") { return $Matches[1] }
    if ($Event.Message -match "The (.*?) service terminated with the following error:") { return $Matches[1] }
    if ($Event.Message -match "The (.*?) service terminated with the following service-specific error:") { return $Matches[1] }
    return "Unknown"
}

# --- Helper to Extract Error Code from Event ---
function Get-ErrorCodeFromEvent {
    param ($Event)
    # Event ID 7023: Error code is often Param2 (EventData[1])
    if ($Event.Id -eq 7023) {
        if ($Event.Properties.Count -ge 2) {
            return $Event.Properties[1].Value
        }
    }
    return $null # Or "N/A"
}

# --- Helper to Extract Service Specific Error Code from Event ---
function Get-ServiceSpecificErrorCodeFromEvent {
    param ($Event)
    # Event ID 7024: Service-specific error code is often Param2 (EventData[1])
    if ($Event.Id -eq 7024) {
        if ($Event.Properties.Count -ge 2) {
            return $Event.Properties[1].Value
        }
    }
    return $null # Or "N/A"
}


# --- Main Script Logic ---
try {
    Write-Log "Starting Get-ServiceFailureHistory script."
    Write-Log "Parameters: ServiceName='$($ServiceName -join ', ')', MaxEvents='$MaxEvents', StartTime='$StartTime', ServerName='$ServerName'"

    if (-not $StartTime) {
        $StartTime = (Get-Date).AddDays(-7) # Default to last 7 days
        Write-Log "StartTime not specified, defaulting to last 7 days: $StartTime"
    }

    $allFailureEvents = [System.Collections.ArrayList]::new()
    $serviceFailureEventIDs = @(7034, 7031, 7023, 7024)

    Write-Log "Querying System event log for service failures (IDs: $($serviceFailureEventIDs -join ', ')) on server '$ServerName' since '$StartTime'."

    try {
        $filterHashtable = @{
            LogName = 'System'
            Id = $serviceFailureEventIDs
            StartTime = $StartTime
        }

        $getWinEventParams = @{
            FilterHashtable = $filterHashtable
            MaxEvents = $MaxEvents # Retrieve general pool of max events
            ErrorAction = 'Stop'
        }

        if ($ServerName -ne $env:COMPUTERNAME -and -not ([string]::IsNullOrWhiteSpace($ServerName))) {
            $getWinEventParams.ComputerName = $ServerName
            Write-Log "Targeting remote server: $ServerName"
        } else {
            Write-Log "Targeting local server."
        }

        $events = Get-WinEvent @getWinEventParams

        if ($events) {
            Write-Log "Found $($events.Count) potential service failure events in System log before filtering by service name."

            foreach ($event in $events) {
                $eventServiceName = Get-ServiceNameFromEvent -Event $event

                # Filter by ServiceName if provided
                if ($ServiceName -and $ServiceName.Count -gt 0) {
                    if ($ServiceName -contains $eventServiceName) {
                        # Matched one of the specified services
                    } else {
                        continue # Skip this event, it's not for a service we're interested in
                    }
                }

                $errorCode = Get-ErrorCodeFromEvent -Event $event
                $serviceSpecificErrorCode = Get-ServiceSpecificErrorCodeFromEvent -Event $event

                $allFailureEvents.Add([PSCustomObject]@{
                    Timestamp       = $event.TimeCreated
                    EventId         = $event.Id
                    ServiceName     = $eventServiceName
                    Message         = $event.Message
                    ErrorCode       = $errorCode
                    ServiceSpecificErrorCode = $serviceSpecificErrorCode
                    MachineName     = $event.MachineName
                }) | Out-Null
            }
            Write-Log "After filtering by ServiceName (if specified), collected $($allFailureEvents.Count) failure events."

        } else {
            Write-Log "No service failure events found in System log for the specified criteria."
        }
    }
    catch [System.Management.Automation.भूतियाException] {
         Write-Log "Failed to query System log on '$ServerName'. Log might be inaccessible. Error: $($_.Exception.Message)" -Level "WARNING"
    }
    catch {
        Write-Log "An error occurred while querying System log on '$ServerName'. Error: $($_.Exception.Message)" -Level "ERROR"
    }


    Write-Log "Get-ServiceFailureHistory script finished. Total events returned: $($allFailureEvents.Count)."
    return $allFailureEvents

}
catch {
    Write-Log "A critical error occurred in Get-ServiceFailureHistory script: $($_.Exception.Message)" -Level "FATAL"
    if ($_.ScriptStackTrace) {
        Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "FATAL"
    }
    return @()
}

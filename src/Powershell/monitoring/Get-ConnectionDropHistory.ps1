# Get-ConnectionDropHistory.ps1
# This script retrieves events that may indicate network connection drops or significant network issues.

param (
    [Parameter(Mandatory = $false)]
    [int]$MaxEventsPerQuery = 25, # Max events for each specific query type

    [Parameter(Mandatory = $false)]
    [datetime]$StartTime,

    [Parameter(Mandatory = $false)]
    [string]$ServerName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\ConnectionDropHistory_Activity.log"
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

# --- Helper to Extract Interface Alias ---
function Get-InterfaceAliasFromEvent {
    param($Event)
    # For Microsoft-Windows-NetworkProfile/Operational, Event ID 10000, 10001
    if ($Event.ProviderName -eq "Microsoft-Windows-NetworkProfile" -and $Event.Id -in @(10000, 10001)) {
        $xml = [xml]$Event.ToXml()
        $interfaceAlias = $xml.Event.EventData.Data | Where-Object { $_.Name -eq "InterfaceAlias" } | Select-Object -ExpandProperty '#text'
        return $interfaceAlias
    }
    # Add other extraction logic if known for other events
    return $null
}


# --- Main Script Logic ---
try {
    Write-Log "Starting Get-ConnectionDropHistory script."
    Write-Log "Parameters: MaxEventsPerQuery='$MaxEventsPerQuery', StartTime='$StartTime', ServerName='$ServerName'"

    if (-not $StartTime) {
        $StartTime = (Get-Date).AddDays(-7) # Default to last 7 days
        Write-Log "StartTime not specified, defaulting to last 7 days: $StartTime"
    }

    $allNetworkEvents = [System.Collections.ArrayList]::new()

    # Define queries
    # Note: NIC driver events (link up/down) are very hardware specific.
    # Examples: Intel (e1iexpress, ixgbe) IDs 27/32. Broadcom (b57nd60a). vmxnet3 IDs 1,4.
    # These would need to be added specifically if known for the target environment.
    $queries = @(
        @{ LogName='System'; ProviderName='Microsoft-Windows-DNS-Client'; Id=1014; Label="DNS Resolution Failure" }
        @{ LogName='System'; ProviderName='Tcpip'; Id=4227; Label="TCP Concurrent Connection Limit" } # Older, less common now
        # @{ LogName='System'; ProviderName='e1iexpress'; Id=27; Label="Intel NIC Link Down" } # Example NIC driver event
        # @{ LogName='System'; ProviderName='e1iexpress'; Id=32; Label="Intel NIC Link Restored" } # Example NIC driver event
        @{ LogName='Microsoft-Windows-NetworkProfile/Operational'; Id=4004; Label="Network State Change Disconnected" } # Often generic
        @{ LogName='Microsoft-Windows-NetworkProfile/Operational'; Id=10000; Label="Network Interface Connected" }
        @{ LogName='Microsoft-Windows-NetworkProfile/Operational'; Id=10001; Label="Network Interface Disconnected" }
        # Microsoft-Windows-TCPIP/Operational can be very verbose. Add specific event IDs if known to be useful.
        # Example: Event ID 100 (NBLs dropped) from Microsoft-Windows-TCPIP - but needs careful interpretation
    )

    Write-Log "Querying event logs for potential connection drop indicators..."

    foreach ($query in $queries) {
        Write-Log "Executing query: LogName='$($query.LogName)', ProviderName='$($query.ProviderName)', ID='$($query.Id)', Label='$($query.Label)' on '$ServerName' since '$StartTime'."
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
                Write-Log "Found $($events.Count) events for query [Label: $($query.Label)]."
                foreach ($event in $events) {
                    $interface = Get-InterfaceAliasFromEvent -Event $event
                    $allNetworkEvents.Add([PSCustomObject]@{
                        Timestamp   = $event.TimeCreated
                        EventId     = $event.Id
                        LogName     = $event.LogName
                        Source      = $event.ProviderName
                        Interface   = $interface
                        Message     = $event.Message
                        MachineName = $event.MachineName
                        QueryLabel  = $query.Label # To know which query found this event
                    }) | Out-Null
                }
            } else {
                Write-Log "No events found for query [Label: $($query.Label)]."
            }
        }
        catch [System.Management.Automation.भूतियाException] {
             Write-Log "Failed to execute query [Label: $($query.Label)]. Log '$($query.LogName)' might not exist or is inaccessible on '$ServerName'. Error: $($_.Exception.Message)" -Level "WARNING"
        }
        catch {
            Write-Log "An error occurred while executing query [Label: $($query.Label)] on '$ServerName'. Error: $($_.Exception.Message)" -Level "ERROR"
        }
    }

    # Sort all collected events by Timestamp
    $sortedEvents = $allNetworkEvents | Sort-Object Timestamp -Descending

    # If MaxEvents was meant to be an overall limit, truncate here.
    # For now, MaxEventsPerQuery applies to each query.
    # if ($sortedEvents.Count -gt $OverallMaxEvents) { $sortedEvents = $sortedEvents[0..($OverallMaxEvents-1)]}


    Write-Log "Get-ConnectionDropHistory script finished. Total relevant events retrieved: $($sortedEvents.Count)."
    return $sortedEvents

}
catch {
    Write-Log "A critical error occurred in Get-ConnectionDropHistory script: $($_.Exception.Message)" -Level "FATAL"
    if ($_.ScriptStackTrace) {
        Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "FATAL"
    }
    return @()
}

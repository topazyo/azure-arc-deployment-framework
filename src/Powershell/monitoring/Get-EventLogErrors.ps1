# Get-EventLogErrors.ps1
# This script retrieves error events from specified Windows Event Logs.

param (
    [Parameter(Mandatory = $false)]
    [string[]]$LogName = @(
        'Application', 
        'System', 
        'Microsoft-Windows-AzureConnectedMachineAgent/Operational', 
        'Microsoft-Windows-GuestAgent/Operational', # Azure VM Guest Agent log
        'Microsoft-AzureArc-GuestConfig/Operational' # Guest Configuration log
    ),

    [Parameter(Mandatory = $false)]
    [int]$MaxEvents = 100,

    [Parameter(Mandatory = $false)]
    [datetime]$StartTime,

    [Parameter(Mandatory = $false)]
    [string]$ServerName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\EventLogErrors_Activity.log" # Log script activity
)

# --- Logging (shared utility) ---
. (Join-Path $PSScriptRoot '..\utils\Write-Log.ps1')

# --- Main Script Logic ---
try {
    Write-Log "Starting Get-EventLogErrors script."
    Write-Log "Parameters: LogName='$($LogName -join ', ')', MaxEvents='$MaxEvents', StartTime='$StartTime', ServerName='$ServerName'"

    if (-not $StartTime) {
        $StartTime = (Get-Date).AddDays(-1)
        Write-Log "StartTime not specified, defaulting to last 24 hours: $StartTime"
    }

    $allErrorEvents = [System.Collections.ArrayList]::new()

    Write-Log "Querying event logs..."
    foreach ($singleLogName in $LogName) {
        Write-Log "Querying errors from log: '$singleLogName' on server '$ServerName' since '$StartTime'."
        try {
            $filterHashtable = @{
                LogName = $singleLogName
                Level = 2 # 2 for Error, 3 for Warning, 4 for Information
                StartTime = $StartTime
            }

            # Add ComputerName only if it's not the local machine, as it can slow things down locally.
            $getWinEventParams = @{
                FilterHashtable = $filterHashtable
                MaxEvents = $MaxEvents
                ErrorAction = 'Stop' # Promote non-terminating errors to terminating for the catch block
            }

            if ($ServerName -ne $env:COMPUTERNAME -and -not ([string]::IsNullOrWhiteSpace($ServerName))) {
                $getWinEventParams.ComputerName = $ServerName
                Write-Log "Targeting remote server: $ServerName"
            } else {
                Write-Log "Targeting local server."
            }
            
            $events = Get-WinEvent @getWinEventParams

            if ($events) {
                Write-Log "Found $($events.Count) error events in '$singleLogName'."
                foreach ($event in $events) {
                    $allErrorEvents.Add([PSCustomObject]@{
                        Timestamp    = $event.TimeCreated
                        LogName      = $event.LogName
                        EventId      = $event.Id
                        Level        = $event.LevelDisplayName
                        Source       = $event.ProviderName
                        Message      = $event.Message # Keep it concise, full message can be long
                        MachineName  = $event.MachineName
                    }) | Out-Null
                }
            } else {
                Write-Log "No error events found in '$singleLogName' for the specified criteria."
            }
        }
        catch [System.Diagnostics.Eventing.Reader.EventLogNotFoundException],[System.UnauthorizedAccessException] { # Log not found / access issues
            Write-Log "Failed to query log '$singleLogName' on '$ServerName'. Log might not exist or is inaccessible. Error: $($_.Exception.Message)" -Level "WARNING"
        }
        catch { # Catch other errors from Get-WinEvent
            Write-Log "An error occurred while querying log '$singleLogName' on '$ServerName'. Error: $($_.Exception.Message)" -Level "ERROR"
            # Optionally, include $_.ScriptStackTrace for debugging
        }
    }

    Write-Log "Total error events retrieved: $($allErrorEvents.Count)."
    Write-Log "Get-EventLogErrors script finished."
    
    return $allErrorEvents

}
catch {
    Write-Log "A critical error occurred in Get-EventLogErrors script: $($_.Exception.Message)" -Level "FATAL"
    if ($_.ScriptStackTrace) {
        Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "FATAL"
    }
    # Return an empty array or rethrow, depending on desired behavior for critical failure
    return @() 
}

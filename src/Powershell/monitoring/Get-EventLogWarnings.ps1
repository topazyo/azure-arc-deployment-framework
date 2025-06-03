# Get-EventLogWarnings.ps1
# This script retrieves warning events from specified Windows Event Logs.

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
    [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\EventLogWarnings_Activity.log" # Log script activity
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
    Write-Log "Starting Get-EventLogWarnings script."
    Write-Log "Parameters: LogName='$($LogName -join ', ')', MaxEvents='$MaxEvents', StartTime='$StartTime', ServerName='$ServerName'"

    if (-not $StartTime) {
        $StartTime = (Get-Date).AddDays(-1)
        Write-Log "StartTime not specified, defaulting to last 24 hours: $StartTime"
    }

    $allWarningEvents = [System.Collections.ArrayList]::new()

    Write-Log "Querying event logs for warnings..."
    foreach ($singleLogName in $LogName) {
        Write-Log "Querying warnings from log: '$singleLogName' on server '$ServerName' since '$StartTime'."
        try {
            $filterHashtable = @{
                LogName = $singleLogName
                Level = 3 # 3 for Warning, 2 for Error, 4 for Information
                StartTime = $StartTime
            }

            $getWinEventParams = @{
                FilterHashtable = $filterHashtable
                MaxEvents = $MaxEvents
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
                Write-Log "Found $($events.Count) warning events in '$singleLogName'."
                foreach ($event in $events) {
                    $allWarningEvents.Add([PSCustomObject]@{
                        Timestamp    = $event.TimeCreated
                        LogName      = $event.LogName
                        EventId      = $event.Id
                        Level        = $event.LevelDisplayName
                        Source       = $event.ProviderName
                        Message      = $event.Message
                        MachineName  = $event.MachineName
                    }) | Out-Null
                }
            } else {
                Write-Log "No warning events found in '$singleLogName' for the specified criteria."
            }
        }
        catch [System.Management.Automation.भूतियाException] {
             Write-Log "Failed to query log '$singleLogName' on '$ServerName' for warnings. Log might not exist or is inaccessible. Error: $($_.Exception.Message)" -Level "WARNING"
        }
        catch {
            Write-Log "An error occurred while querying log '$singleLogName' on '$ServerName' for warnings. Error: $($_.Exception.Message)" -Level "ERROR"
        }
    }

    Write-Log "Total warning events retrieved: $($allWarningEvents.Count)."
    Write-Log "Get-EventLogWarnings script finished."

    return $allWarningEvents

}
catch {
    Write-Log "A critical error occurred in Get-EventLogWarnings script: $($_.Exception.Message)" -Level "FATAL"
    if ($_.ScriptStackTrace) {
        Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "FATAL"
    }
    return @()
}

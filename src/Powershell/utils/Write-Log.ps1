function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Message,
        [Parameter()]
        [ValidateSet('Information', 'Warning', 'Error', 'Debug', 'Verbose')]
        [string]$Level = ($global:AzureArcFramework_LogLevel | Get-Variable -ErrorAction SilentlyContinue -ValueOnly),
        [Parameter()]
        [string]$Component = 'General',
        [Parameter()]
        [string]$LogPath = ($global:AzureArcFramework_LogPath | Get-Variable -ErrorAction SilentlyContinue -ValueOnly),
        [Parameter()]
        [switch]$PassThru
    )

    begin {
        # Set effective defaults if parameters were not passed and global vars were not set (or null/empty)
        if ([string]::IsNullOrEmpty($LogPath)) {
            $LogPath = Join-Path $env:TEMP "AzureArcFramework/Default.log"
        }
        if ([string]::IsNullOrEmpty($Level)) {
            $Level = 'Information'
        }

        # Ensure log directory exists
        $logDir = Split-Path $LogPath -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -Path $logDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $logEntry = "[{0}] [{1}] [{2}] {3}" -f $timestamp, $Level.ToUpper(), $Component, $Message
    }

    process {
        try {
            # Write to log file
            Add-Content -Path $LogPath -Value $logEntry

            # Write to appropriate output stream
            switch ($Level) {
                'Error' { 
                    Write-Error $Message
                    $host.UI.WriteErrorLine($logEntry)
                }
                'Warning' { Write-Warning $Message }
                'Debug' { Write-Debug $Message }
                'Verbose' { Write-Verbose $Message }
                default { Write-Host $logEntry }
            }

            if ($PassThru) {
                return $logEntry
            }
        }
        catch {
            Write-Error "Failed to write log entry: $_"
        }
    }
}

function Write-StructuredLog {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [hashtable]$LogEntry,
        [Parameter()]
        [string]$LogPath = ".\Logs\Structured",
        [Parameter()]
        [string]$Format = "JSON"
    )

    try {
        # Ensure log directory exists
        if (-not (Test-Path $LogPath)) {
            New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
        }

        # Add timestamp and machine info
        $LogEntry.Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $LogEntry.Computer = $env:COMPUTERNAME
        $LogEntry.ProcessId = $PID

        # Format log entry
        $formattedLog = switch ($Format) {
            "JSON" { $LogEntry | ConvertTo-Json }
            "CSV" { $LogEntry | ConvertTo-Csv -NoTypeInformation }
            default { $LogEntry | ConvertTo-Json }
        }

        # Write to file
        $logFile = Join-Path $LogPath "structured_log_$(Get-Date -Format 'yyyyMMdd').log"
        $formattedLog | Out-File -FilePath $logFile -Append

        return $true
    }
    catch {
        Write-Error "Failed to write structured log: $_"
        return $false
    }
}

function Start-LogRotation {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]$LogPath = ".\Logs",
        [Parameter()]
        [int]$RetentionDays = 30,
        [Parameter()]
        [int]$MaxSizeMB = 100
    )

    try {
        # Get all log files
        $logFiles = Get-ChildItem -Path $LogPath -Filter "*.log" -Recurse

        foreach ($file in $logFiles) {
            # Check age
            if ($file.LastWriteTime -lt (Get-Date).AddDays(-$RetentionDays)) {
                Remove-Item $file.FullName -Force
                Write-Log -Message "Removed old log file: $($file.Name)" -Level Information
                continue
            }

            # Check size
            if ($file.Length/1MB -gt $MaxSizeMB) {
                $archiveName = $file.FullName -replace '\.log$', "_$(Get-Date -Format 'yyyyMMdd_HHmmss').archive"
                Move-Item $file.FullName $archiveName
                Write-Log -Message "Archived large log file: $($file.Name)" -Level Information
            }
        }

        return $true
    }
    catch {
        Write-Error "Log rotation failed: $_"
        return $false
    }
}
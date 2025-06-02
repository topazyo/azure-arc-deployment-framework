# Backup-OperationState.ps1
# This script backs up specified files, directories, registry keys, and service configurations.
# TODO: Add more backup item types if needed (e.g., Scheduled Tasks, WMI Objects).
# TODO: Consider compression for backups.

Function Backup-OperationState {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory=$true)]
        [string]$OperationId,

        [Parameter(Mandatory=$false)]
        [string]$BackupPathBase = "C:\ProgramData\AzureArcFramework\StateBackups",

        [Parameter(Mandatory=$true)]
        [object[]]$ItemsToBackup, # Array of hashtables/PSCustomObjects

        [Parameter(Mandatory=$false)]
        [int]$MaxBackupVersions = 3,

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\BackupOperationState_Activity.log"
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

    # --- Helper to convert PS Registry Path to reg.exe format ---
    function ConvertTo-RegExePath {
        param([string]$PsPath)
        $psPath = $psPath.TrimEnd('\')
        if ($PsPath -match "^HKLM:") { return $PsPath -replace "HKLM:", "HKEY_LOCAL_MACHINE\" }
        if ($PsPath -match "^HKCU:") { return $PsPath -replace "HKCU:", "HKEY_CURRENT_USER\" }
        if ($PsPath -match "^HKCR:") { return $PsPath -replace "HKCR:", "HKEY_CLASSES_ROOT\" }
        if ($PsPath -match "^HKU:") { return $PsPath -replace "HKU:", "HKEY_USERS\" }
        if ($PsPath -match "^HKCC:") { return $PsPath -replace "HKCC:", "HKEY_CURRENT_CONFIG\" }
        Write-Log "Unrecognized registry hive in path: $PsPath" -Level "WARNING"
        return $PsPath # Return as is if no match, reg.exe will likely fail
    }

    Write-Log "Starting Backup-OperationState for OperationId: '$OperationId'."

    $overallStatus = "Success"
    $backedUpItemsResults = [System.Collections.ArrayList]::new()
    $errorsEncountered = [System.Collections.ArrayList]::new()
    $versionsCleaned = [System.Collections.ArrayList]::new()
    
    $targetOperationBackupDir = Join-Path -Path $BackupPathBase -ChildPath ($OperationId -replace '[^a-zA-Z0-9_-]', '_') # Sanitize OperationId for path
    $currentTimestampForDir = Get-Date -Format "yyyyMMdd_HHmmss"
    $currentVersionBackupDir = Join-Path -Path $targetOperationBackupDir -ChildPath $currentTimestampForDir

    try {
        # --- Create Backup Directories ---
        if (-not (Test-Path -Path $targetOperationBackupDir -PathType Container)) {
            Write-Log "Creating base backup directory for OperationId: $targetOperationBackupDir"
            if ($PSCmdlet.ShouldProcess($targetOperationBackupDir, "Create Directory")) {
                New-Item -ItemType Directory -Path $targetOperationBackupDir -Force -ErrorAction Stop | Out-Null
            }
        }
        Write-Log "Creating timestamped backup directory: $currentVersionBackupDir"
        if ($PSCmdlet.ShouldProcess($currentVersionBackupDir, "Create Timestamped Directory")) {
            New-Item -ItemType Directory -Path $currentVersionBackupDir -Force -ErrorAction Stop | Out-Null
        }

        # --- Iterate through ItemsToBackup ---
        foreach ($item in $ItemsToBackup) {
            $itemType = $item.Type
            $itemPath = $item.Path
            $itemName = if ($item.PSObject.Properties.Contains('Name')) { $item.Name } else { (Split-Path $itemPath -Leaf) }
            $itemBackupStatus = "Pending"
            $backupFileName = $null # For reg/service config

            Write-Log "Processing item: Type='$itemType', Path='$itemPath', Name='$itemName'."
            try {
                if (-not $PSCmdlet.ShouldProcess($itemPath, "Backup Item (Type: $itemType)")) {
                    Write-Log "Backup for item '$itemPath' skipped due to -WhatIf." -Level "INFO"
                    $itemBackupStatus = "SkippedWhatIf"
                    $backedUpItemsResults.Add([PSCustomObject]@{ ItemType=$itemType; SourcePath=$itemPath; BackupName=$itemName; Status=$itemBackupStatus }) | Out-Null
                    continue
                }

                switch ($itemType) {
                    "File" {
                        if (Test-Path $itemPath -PathType Leaf) {
                            Copy-Item -Path $itemPath -Destination $currentVersionBackupDir -Force -ErrorAction Stop
                            $itemBackupStatus = "Success"
                            Write-Log "File '$itemPath' backed up successfully."
                        } else { throw "File not found at '$itemPath'." }
                    }
                    "Directory" {
                        if (Test-Path $itemPath -PathType Container) {
                            $destinationDir = Join-Path $currentVersionBackupDir (Split-Path $itemPath -Leaf)
                            Copy-Item -Path $itemPath -Destination $destinationDir -Recurse -Force -ErrorAction Stop
                            $itemBackupStatus = "Success"
                            Write-Log "Directory '$itemPath' backed up successfully to '$destinationDir'."
                        } else { throw "Directory not found at '$itemPath'." }
                    }
                    "RegistryKey" {
                        $regExePath = ConvertTo-RegExePath -PsPath $itemPath
                        $backupFileName = ($itemPath -split '\\')[-1] + ".reg" # Use last part of key name for filename
                        $backupRegFilePath = Join-Path $currentVersionBackupDir $backupFileName
                        
                        Write-Log "Exporting registry key '$regExePath' to '$backupRegFilePath'."
                        Invoke-Expression -Command "reg.exe export `"$regExePath`" `"$backupRegFilePath`" /y" # `reg.exe` handles Test-Path internally
                        # Check $LASTEXITCODE for reg.exe success, though it might not always be reliable for export success.
                        # A more robust check would be if the file was created and not empty.
                        if (Test-Path $backupRegFilePath -PathType Leaf -ErrorAction SilentlyContinue) {
                             $itemBackupStatus = "Success"
                             Write-Log "Registry key '$itemPath' exported successfully."
                        } else {
                            throw "Registry export failed or file not created for '$itemPath'."
                        }
                    }
                    "ServiceConfiguration" {
                        $serviceName = $item.Name
                        if ([string]::IsNullOrWhiteSpace($serviceName)) { throw "Service 'Name' not provided for ServiceConfiguration backup." }
                        
                        $serviceConfig = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction Stop
                        if ($serviceConfig) {
                            $backupFileName = "$($serviceName)_service_config.json"
                            $backupServiceConfigPath = Join-Path $currentVersionBackupDir $backupFileName
                            $serviceConfig | ConvertTo-Json -Depth 3 | Out-File -FilePath $backupServiceConfigPath -Encoding UTF8 -Force -ErrorAction Stop
                            $itemBackupStatus = "Success"
                            Write-Log "Service configuration for '$serviceName' backed up successfully."
                        } else { throw "Service '$serviceName' not found." }
                    }
                    default {
                        throw "Unsupported ItemType: '$itemType'."
                    }
                }
            } catch {
                $itemBackupStatus = "Failed"
                $errorMessage = "Failed to backup item: Type='$itemType', Path='$itemPath', Name='$itemName'. Error: $($_.Exception.Message)"
                Write-Log $errorMessage -Level "ERROR"
                $errorsEncountered.Add($errorMessage) | Out-Null
                $overallStatus = "PartialSuccess" # Mark overall as partial if any item fails
            }
            $backedUpItemsResults.Add([PSCustomObject]@{ 
                ItemType   = $itemType
                SourcePath = $itemPath
                BackupName = if($backupFileName){$backupFileName}else{(Split-Path $itemPath -Leaf)} 
                Status     = $itemBackupStatus
            }) | Out-Null
        } # End foreach item

        # --- Manage Backup Versions ---
        if ($MaxBackupVersions -gt 0) {
            Write-Log "Managing backup versions for OperationId '$OperationId'. Max versions: $MaxBackupVersions."
            $existingVersions = Get-ChildItem -Path $targetOperationBackupDir -Directory | Sort-Object Name # Name is YYYYMMDD_HHMMSS
            $versionsToDeleteCount = $existingVersions.Count - $MaxBackupVersions
            
            if ($versionsToDeleteCount -gt 0) {
                $versionsToDelete = $existingVersions | Select-Object -First $versionsToDeleteCount
                foreach ($oldVersion in $versionsToDelete) {
                    Write-Log "Max versions exceeded. Deleting oldest backup version: $($oldVersion.FullName)" -Level "INFO"
                    if ($PSCmdlet.ShouldProcess($oldVersion.FullName, "Delete Old Backup Version")) {
                        try {
                            Remove-Item -Path $oldVersion.FullName -Recurse -Force -ErrorAction Stop
                            $versionsCleaned.Add($oldVersion.FullName) | Out-Null
                            Write-Log "Successfully deleted old backup version: $($oldVersion.FullName)."
                        } catch {
                            $errorMessage = "Failed to delete old backup version '$($oldVersion.FullName)'. Error: $($_.Exception.Message)"
                            Write-Log $errorMessage -Level "ERROR"
                            $errorsEncountered.Add($errorMessage) | Out-Null
                            if ($overallStatus -ne "Failed") {$overallStatus = "PartialSuccess"}
                        }
                    } else {
                         Write-Log "Deletion of old backup version '$($oldVersion.FullName)' skipped due to -WhatIf." -Level "INFO"
                    }
                }
            } else {
                 Write-Log "Backup version count ($($existingVersions.Count)) is within limit ($MaxBackupVersions). No cleanup needed."
            }
        }

    } catch {
        Write-Log "A critical error occurred during backup operation setup or version management: $($_.Exception.Message)" -Level "FATAL"
        Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "DEBUG"
        $overallStatus = "Failed"
        $errorsEncountered.Add("Critical failure: $($_.Exception.Message)") | Out-Null
    } finally {
        if ($errorsEncountered.Count -gt 0 -and $overallStatus -ne "Failed") { $overallStatus = "PartialSuccess" }
        
        $operationEndTime = Get-Date
        Write-Log "Backup-OperationState finished for OperationId: '$OperationId'. Overall Status: $overallStatus."
        
        $summary = [PSCustomObject]@{
            OperationId         = $OperationId
            BackupTimestamp     = $currentTimestampForDir # The YYYYMMDD_HHMMSS string for this run
            BackupLocation      = $currentVersionBackupDir # Full path to this specific backup version
            Status              = $overallStatus
            BackedUpItems       = $backedUpItemsResults
            ErrorsEncountered   = $errorsEncountered
            VersionsCleaned     = $versionsCleaned
            OperationEndTime    = $operationEndTime
        }
    }
    return $summary
}

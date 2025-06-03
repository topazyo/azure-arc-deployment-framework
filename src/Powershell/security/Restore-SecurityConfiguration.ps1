# Restore-SecurityConfiguration.ps1
# This script restores various security-related configurations from a specified backup location.
# TODO V2: Consider more robust service configuration restoration (e.g., StartName if credentials can be handled).
# TODO V2: Add restoration for Local Security Policy if Backup-SecurityConfiguration adds it.

Function Restore-SecurityConfiguration {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory=$true)]
        [string]$BackupLocation, # Full path to a specific timestamped backup directory

        [Parameter(Mandatory=$false)]
        [ValidateSet("TLS", "Firewall", "AuditPolicy", "Services")]
        [string[]]$ItemsToRestore = @("TLS", "Firewall", "AuditPolicy", "Services"),

        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME, # Currently operates on local machine

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\RestoreSecurityConfiguration_Activity.log"
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

    Write-Log "Starting Restore-SecurityConfiguration on server '$ServerName' from BackupLocation: '$BackupLocation'."
    Write-Log "Items to restore: $($ItemsToRestore -join ', ')."

    if ($ServerName -ne $env:COMPUTERNAME) {
        Write-Log "Warning: Most operations are local. Remote server functionality is limited for this script." -Level "WARNING"
    }

    # --- Administrator Privilege Check ---
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Administrator privileges are required for restoring security configurations. Script cannot proceed." -Level "ERROR"
        throw "Administrator privileges required."
    } else {
        Write-Log "Running with Administrator privileges."
    }

    # --- Verify BackupLocation Exists ---
    if (-not (Test-Path -Path $BackupLocation -PathType Container)) {
        Write-Log "BackupLocation '$BackupLocation' not found. Cannot proceed with restore." -Level "ERROR"
        throw "BackupLocation not found: $BackupLocation"
    }

    $overallStatus = "Success"
    $restoredItemsResults = [System.Collections.ArrayList]::new()
    $errorsEncountered = [System.Collections.ArrayList]::new()

    try {
        foreach ($itemTypeToRestore in $ItemsToRestore) {
            $itemStatus = "Pending"
            $restoredFiles = [System.Collections.ArrayList]::new()
            Write-Log "Restoring Area: '$itemTypeToRestore'."

            try {
                if (-not $PSCmdlet.ShouldProcess($itemTypeToRestore, "Restore Configuration Area from $BackupLocation")) {
                    Write-Log "Restore for area '$itemTypeToRestore' skipped due to -WhatIf." -Level "INFO"
                    $itemStatus = "SkippedWhatIf"
                    $restoredItemsResults.Add([PSCustomObject]@{ Component=$itemTypeToRestore; FilesImported=$null; Status=$itemStatus }) | Out-Null
                    continue
                }

                switch ($itemTypeToRestore) {
                    "TLS" {
                        $regFileNames = @("TLS_SCHANNEL.reg", "DOTNET_TLS_Machine.reg", "DOTNET_TLS_Wow6432.reg")
                        $tlsRestoreStatus = "Success"
                        foreach ($regFileName in $regFileNames) {
                            $regFilePath = Join-Path $BackupLocation $regFileName
                            if (Test-Path $regFilePath -PathType Leaf) {
                                Write-Log "Importing TLS registry file: '$regFilePath'."
                                Invoke-Expression -Command "reg.exe import `"$regFilePath`""
                                if ($LASTEXITCODE -ne 0) {
                                    Write-Warning "reg.exe import for '$regFilePath' exited with code $LASTEXITCODE."
                                    $tlsRestoreStatus = "PartialSuccess" # One file failed but others might succeed
                                } else {
                                    $restoredFiles.Add($regFileName) | Out-Null
                                }
                            } else {
                                Write-Log "TLS backup file '$regFileName' not found in '$BackupLocation'. Skipping." -Level "WARNING"
                                $tlsRestoreStatus = "PartialSuccess" # File missing
                            }
                        }
                        $itemStatus = if ($restoredFiles.Count -eq 0 -and $regFileNames.Count -gt 0) {"FailedNoFileFound"} elseif($restoredFiles.Count -lt $regFileNames.Count){"PartialSuccess"} else {$tlsRestoreStatus}
                        Write-Log "TLS configuration restore status: $itemStatus."
                    }
                    "Firewall" {
                        $fwFile = "FirewallPolicy.wfw"
                        $fwFilePath = Join-Path $BackupLocation $fwFile
                        if (Test-Path $fwFilePath -PathType Leaf) {
                            Write-Log "Importing firewall policy from '$fwFilePath'."
                            Invoke-Expression -Command "netsh advfirewall import `"$fwFilePath`""
                            # Checking netsh success can be tricky, often requires parsing output or assuming success if no error.
                            # For simplicity, we assume success if Invoke-Expression doesn't throw hard.
                            # A better check might be to compare a rule count before/after if possible or specific rule presence.
                            $itemStatus = "Success" # Assume success if command doesn't throw catastrophically
                            $restoredFiles.Add($fwFile) | Out-Null
                            Write-Log "Firewall policy import status: $itemStatus. Note: netsh success detection is basic."
                        } else {
                            throw "Firewall backup file '$fwFile' not found in '$BackupLocation'."
                        }
                    }
                    "AuditPolicy" {
                        $apFile = "AuditPolicy.csv"
                        $apFilePath = Join-Path $BackupLocation $apFile
                        if (Test-Path $apFilePath -PathType Leaf) {
                            Write-Log "Restoring audit policy from '$apFilePath'."
                            Invoke-Expression -Command "auditpol /restore /file:`"$apFilePath`""
                             if ($LASTEXITCODE -ne 0 -and -not ($Error[0].ToString() -match "The operation completed successfully")) {
                                throw "auditpol /restore failed with exit code $LASTEXITCODE. Error: $($Error[0])"
                            }
                            $itemStatus = "Success"
                            $restoredFiles.Add($apFile) | Out-Null
                            Write-Log "Audit policy restore status: $itemStatus."
                        } else {
                            throw "Audit policy backup file '$apFile' not found in '$BackupLocation'."
                        }
                    }
                    "Services" {
                        $serviceConfigFiles = Get-ChildItem -Path $BackupLocation -Filter "*_service_config.json" -ErrorAction SilentlyContinue
                        if ($serviceConfigFiles.Count -eq 0) {
                            Write-Log "No service configuration JSON files found in '$BackupLocation' for restore." -Level "INFO"
                            $itemStatus = "NoActionTaken" # Or "PartialSuccess" if other items were expected
                        } else {
                            $serviceRestoreStatus = "Success"
                            foreach ($configFile in $serviceConfigFiles) {
                                $serviceNameFromFile = $configFile.BaseName -replace "_service_config",""
                                Write-Log "Processing service config backup: $($configFile.Name) for service '$serviceNameFromFile'."
                                try {
                                    $serviceConfig = Get-Content -Path $configFile.FullName -Raw | ConvertFrom-Json -ErrorAction Stop

                                    $currentService = Get-Service -Name $serviceConfig.Name -ErrorAction SilentlyContinue
                                    $currentServiceCim = Get-CimInstance Win32_Service -Filter "Name='$($serviceConfig.Name)'" -ErrorAction SilentlyContinue

                                    if (-not $currentService) {
                                        Write-Log "Service '$($serviceConfig.Name)' not found. Cannot restore its configuration." -Level "WARNING"
                                        $serviceRestoreStatus = "PartialSuccess"
                                        continue
                                    }

                                    # V1: Restore StartupType only
                                    if ($serviceConfig.StartMode -ne $currentService.StartupType.ToString()) {
                                        Write-Log "Service '$($serviceConfig.Name)': Restoring StartupType from '$($currentService.StartupType)' to '$($serviceConfig.StartMode)'."
                                        Set-Service -Name $serviceConfig.Name -StartupType $serviceConfig.StartMode -ErrorAction Stop
                                        $restoredFiles.Add($configFile.Name) | Out-Null # Add to list of processed files for this component
                                    } else {
                                        Write-Log "Service '$($serviceConfig.Name)': StartupType ('$($serviceConfig.StartMode)') already matches backup. No change needed."
                                    }

                                    # V1: Report on StartName (Account) mismatch
                                    if ($currentServiceCim -and $serviceConfig.StartName -ne $currentServiceCim.StartName) {
                                        Write-Log "Service '$($serviceConfig.Name)': Account in backup ('$($serviceConfig.StartName)') differs from current ('$($currentServiceCim.StartName)'). Manual review/change may be needed." -Level "WARNING"
                                    }
                                } catch {
                                    Write-Log "Failed to restore configuration for service '$serviceNameFromFile' from '$($configFile.Name)'. Error: $($_.Exception.Message)" -Level "ERROR"
                                    $serviceRestoreStatus = "PartialSuccess"
                                }
                            }
                            $itemStatus = $serviceRestoreStatus
                            Write-Log "Services configuration restore status: $itemStatus."
                        }
                    }
                    default {
                        throw "Unsupported ItemToRestore: '$itemTypeToRestore'."
                    }
                }
            } catch {
                $itemStatus = "Failed"
                $errorMessage = "Failed to restore item '$itemTypeToRestore'. Error: $($_.Exception.Message)"
                Write-Log $errorMessage -Level "ERROR"
                $errorsEncountered.Add($errorMessage) | Out-Null
                $overallStatus = "PartialSuccess"
            }
            $restoredItemsResults.Add([PSCustomObject]@{ Component=$itemTypeToRestore; FilesImported=($restoredFiles -join "; "); Status=$itemStatus }) | Out-Null
        } # End foreach ItemsToRestore

    } catch {
        Write-Log "A critical error occurred during restore pre-loop setup: $($_.Exception.Message)" -Level "FATAL"
        Write-Log $_.ScriptStackTrace -Level "DEBUG"
        $overallStatus = "Failed"
        $errorsEncountered.Add("Critical failure during setup: $($_.Exception.Message)") | Out-Null
    } finally {
        if ($errorsEncountered.Count -gt 0 -and $overallStatus -ne "Failed") { $overallStatus = "PartialSuccess" }

        $operationEndTime = Get-Date
        Write-Log "Restore-SecurityConfiguration finished. Overall Status: $overallStatus."

        $summary = [PSCustomObject]@{
            BackupSource      = $BackupLocation
            Status            = $overallStatus
            RestoredItems     = $restoredItemsResults
            ErrorsEncountered = $errorsEncountered
            Timestamp         = $operationEndTime.ToString("o")
        }
    }
    return $summary
}

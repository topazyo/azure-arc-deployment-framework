# Backup-SecurityConfiguration.ps1
# This script backs up various security-related configurations like TLS, Firewall, AuditPolicy, and specific service configs.
# TODO: Add backup for Local Security Policy (secedit /export).
# TODO: Consider more granular selection of items within each ConfigurationArea.

Function Backup-SecurityConfiguration {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME, # Currently operates on local machine due to toolset

        [Parameter(Mandatory=$false)]
        [string]$BackupPathBase = "C:\ProgramData\AzureArcFramework\SecurityBackups",

        [Parameter(Mandatory=$false)]
        [ValidateSet("TLS", "Firewall", "AuditPolicy", "Services")]
        [string[]]$ItemsToBackup = @("TLS", "Firewall", "AuditPolicy", "Services"),

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\BackupSecurityConfiguration_Activity.log"
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
        $regPath = $PsPath.TrimEnd('\')
        if ($regPath -match "^HKLM:") { return $regPath -replace "HKLM:", "HKEY_LOCAL_MACHINE\" }
        if ($regPath -match "^HKCU:") { return $regPath -replace "HKCU:", "HKEY_CURRENT_USER\" }
        if ($regPath -match "^HKCR:") { return $regPath -replace "HKCR:", "HKEY_CLASSES_ROOT\" }
        if ($regPath -match "^HKU:") { return $regPath -replace "HKU:", "HKEY_USERS\" }
        if ($regPath -match "^HKCC:") { return $regPath -replace "HKCC:", "HKEY_CURRENT_CONFIG\" }
        Write-Log "Unrecognized registry hive in path: $PsPath for reg.exe" -Level "WARNING"
        return $PsPath
    }

    Write-Log "Starting Backup-SecurityConfiguration on server '$ServerName'."
    Write-Log "Items to backup: $($ItemsToBackup -join ', ')."

    if ($ServerName -ne $env:COMPUTERNAME) {
        Write-Log "Warning: Most operations are local. Remote server functionality is limited for this script." -Level "WARNING"
        # For now, proceed assuming local operations or that tools like reg.exe/netsh are remoted by a calling script.
    }

    # --- Administrator Privilege Check ---
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Administrator privileges are required for most security configuration backups. Script may fail." -Level "ERROR"
        # Allow script to attempt and fail on individual commands if not admin, to see what's possible.
        # Alternatively, uncomment to throw: throw "Administrator privileges required."
    } else {
        Write-Log "Running with Administrator privileges."
    }

    $overallStatus = "Success"
    $backedUpItemsResults = [System.Collections.ArrayList]::new()
    $errorsEncountered = [System.Collections.ArrayList]::new()

    $timestampForDir = Get-Date -Format "yyyyMMddHHmmss"
    $targetBackupDir = Join-Path -Path $BackupPathBase -ChildPath "SecurityConfigBackup_$timestampForDir"

    try {
        if (-not (Test-Path -Path $targetBackupDir -PathType Container)) {
            Write-Log "Creating backup directory: $targetBackupDir"
            if ($PSCmdlet.ShouldProcess($targetBackupDir, "Create Directory")) {
                New-Item -ItemType Directory -Path $targetBackupDir -Force -ErrorAction Stop | Out-Null
            }
        }

        foreach ($itemTypeToBackup in $ItemsToBackup) {
            $itemStatus = "Pending"
            $backupFile = ""
            Write-Log "Backing up Area: '$itemTypeToBackup'."

            try {
                if (-not $PSCmdlet.ShouldProcess($itemTypeToBackup, "Backup Configuration Area")) {
                    Write-Log "Backup for area '$itemTypeToBackup' skipped due to -WhatIf." -Level "INFO"
                    $itemStatus = "SkippedWhatIf"
                    $backedUpItemsResults.Add([PSCustomObject]@{ Component=$itemTypeToBackup; File=$null; Status=$itemStatus }) | Out-Null
                    continue
                }

                switch ($itemTypeToBackup) {
                    "TLS" {
                        $regKeysToBackup = @{
                            "TLS_SCHANNEL" = "HKLM\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL";
                            "DOTNET_TLS_Machine" = "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319";
                            "DOTNET_TLS_Wow6432" = "HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319"
                        }
                        $tlsBackupStatus = "Success"
                        foreach($keyName in $regKeysToBackup.Keys){
                            $regPath = $regKeysToBackup[$keyName]
                            $regExePath = ConvertTo-RegExePath -PsPath $regPath
                            $backupFile = "$($keyName).reg"
                            $backupFilePath = Join-Path $targetBackupDir $backupFile
                            Write-Log "Exporting TLS registry key '$regPath' to '$backupFilePath'."
                            Invoke-Expression -Command "reg.exe export `"$regExePath`" `"$backupFilePath`" /y" # reg.exe handles Test-Path
                            if ($LASTEXITCODE -ne 0) { Write-Warning "reg.exe exited with code $LASTEXITCODE for $regPath"; $tlsBackupStatus = "PartialSuccess" }
                        }
                        $itemStatus = $tlsBackupStatus
                        $backupFile = "Multiple .reg files (see logs)" # General name for summary
                         Write-Log "TLS configuration backup status: $itemStatus."
                    }
                    "Firewall" {
                        $backupFile = "FirewallPolicy.wfw"
                        $backupFilePath = Join-Path $targetBackupDir $backupFile
                        Write-Log "Exporting firewall policy to '$backupFilePath'."
                        Invoke-Expression -Command "netsh advfirewall export `"$backupFilePath`"" # netsh handles Test-Path
                        # netsh usually doesn't set LASTEXITCODE reliably on success/failure, check file existence
                        if(Test-Path $backupFilePath -PathType Leaf){ $itemStatus = "Success" } else { throw "netsh export failed or file not created."}
                        Write-Log "Firewall policy backup status: $itemStatus."
                    }
                    "AuditPolicy" {
                        $backupFile = "AuditPolicy.csv"
                        $backupFilePath = Join-Path $targetBackupDir $backupFile
                        Write-Log "Exporting audit policy to '$backupFilePath'."
                        Invoke-Expression -Command "auditpol /backup /file:`"$backupFilePath`""
                        if ($LASTEXITCODE -ne 0 -and -not ($Error[0].ToString() -match "The operation completed successfully")) { # auditpol can put success in stderr
                            throw "auditpol /backup failed with exit code $LASTEXITCODE. Error: $($Error[0])"
                        }
                        $itemStatus = "Success"
                        Write-Log "Audit policy backup status: $itemStatus."
                    }
                    "Services" {
                        $servicesToBackup = @("himds", "AzureMonitorAgent", "GCService") # Arc related services
                        $serviceBackupStatus = "Success"
                        $serviceFiles = [System.Collections.ArrayList]::new()
                        foreach ($serviceName in $servicesToBackup) {
                            $serviceConfig = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue
                            if ($serviceConfig) {
                                $svcBackupFile = "$($serviceName)_service_config.json"
                                $backupFilePath = Join-Path $targetBackupDir $svcBackupFile
                                $serviceConfig | Select-Object Name, DisplayName, StartMode, PathName, StartName, ServiceType, State, Status, Dependencies, ServiceAccount | ConvertTo-Json -Depth 3 | Out-File -FilePath $backupFilePath -Encoding UTF8 -Force -ErrorAction Stop
                                $serviceFiles.Add($svcBackupFile) | Out-Null
                                Write-Log "Service configuration for '$serviceName' backed up."
                            } else {
                                Write-Log "Service '$serviceName' not found for backup." -Level "WARNING"
                                $serviceBackupStatus = "PartialSuccess" # If one service is missing
                            }
                        }
                        $itemStatus = $serviceBackupStatus
                        $backupFile = ($serviceFiles -join "; ")
                        Write-Log "Services configuration backup status: $itemStatus."
                    }
                    default {
                        throw "Unsupported ItemToBackup: '$itemTypeToBackup'."
                    }
                }
            } catch {
                $itemStatus = "Failed"
                $errorMessage = "Failed to backup item '$itemTypeToBackup'. Error: $($_.Exception.Message)"
                Write-Log $errorMessage -Level "ERROR"
                $errorsEncountered.Add($errorMessage) | Out-Null
                $overallStatus = "PartialSuccess"
            }
            $backedUpItemsResults.Add([PSCustomObject]@{ Component=$itemTypeToBackup; File=$backupFile; Status=$itemStatus }) | Out-Null
        } # End foreach ItemsToBackup

    } catch {
        Write-Log "A critical error occurred during backup directory setup: $($_.Exception.Message)" -Level "FATAL"
        Write-Log $_.ScriptStackTrace -Level "DEBUG"
        $overallStatus = "Failed"
        $errorsEncountered.Add("Critical failure during setup: $($_.Exception.Message)") | Out-Null
    } finally {
        if ($errorsEncountered.Count -gt 0 -and $overallStatus -ne "Failed") { $overallStatus = "PartialSuccess" }

        $operationEndTime = Get-Date
        Write-Log "Backup-SecurityConfiguration finished. Overall Status: $overallStatus."

        $summary = [PSCustomObject]@{
            BackupLocation    = $targetBackupDir
            Status            = $overallStatus
            BackedUpItems     = $backedUpItemsResults
            ErrorsEncountered = $errorsEncountered
            Timestamp         = $operationEndTime.ToString("o") # Use a consistent timestamp format
        }
    }
    return $summary
}

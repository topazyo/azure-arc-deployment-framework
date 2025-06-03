# Set-ServiceAccountSecurity.ps1
# This script checks and configures service settings like StartupType.
# V1: Enforces StartupType. Reports on AccountName, Permissions, Dependencies.
# TODO V2: Implement changing service account (requires credential handling).
# TODO V2: Implement detailed permission checks/settings (complex ACL/SDDL).

Function Set-ServiceAccountSecurity {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory=$true)]
        [object]$Settings, # Expected to be the serviceSettings section from a baseline

        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME, # Currently operates on local machine

        [Parameter(Mandatory=$false)]
        [bool]$EnforceSettings = $true,

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\SetServiceAccountSecurity_Activity.log"
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

    Write-Log "Starting Set-ServiceAccountSecurity on server '$ServerName'."
    Write-Log "Parameters: EnforceSettings='$EnforceSettings'."
    if ($ServerName -ne $env:COMPUTERNAME) {
        Write-Log "Warning: Script currently designed for local server operations. Remote functionality via -ServerName is not fully implemented for all checks/sets." -Level "WARNING"
    }

    # --- Administrator Privilege Check ---
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Administrator privileges are required to set service configurations. Script may fail or run in audit-only effective mode." -Level "ERROR"
        if ($EnforceSettings) {
            # throw "Administrator privileges required to enforce settings." # Option to hard fail
            Write-Log "EnforceSettings is true, but script lacks admin rights. Proceeding in audit mode for safety." -Level "WARNING"
            $EnforceSettings = $false # Force audit mode
        }
    } else {
        Write-Log "Running with Administrator privileges."
    }

    $resultsList = [System.Collections.ArrayList]::new()
    $overallStatus = "NoChangesNeeded" # Potential values: NoChangesNeeded, ChangesMade, AuditMismatchesFound, Failed, PartialSuccess

    if (-not $Settings) {
        Write-Log "Input -Settings object is null. Cannot proceed." -Level "ERROR"
        # Return an error status object
        return [PSCustomObject]@{
            ServerName = $ServerName; SettingsAppliedOrChecked = @(); OverallStatus = "FailedNoSettings"; Timestamp = (Get-Date -Format o)
        }
    }

    # Iterate through service entries in the $Settings object (e.g., arcAgent, amaAgent)
    foreach ($serviceEntryKey in $Settings.PSObject.Properties.Name) {
        $serviceConfig = $Settings.$serviceEntryKey
        $serviceName = $serviceConfig.serviceName

        if ([string]::IsNullOrWhiteSpace($serviceName)) {
            Write-Log "Skipping entry '$serviceEntryKey' as it's missing a 'serviceName'." -Level "WARNING"
            continue
        }
        Write-Log "Processing service: '$serviceName' (Entry: '$serviceEntryKey')."

        try {
            # Get current service configuration
            # Get-Service for StartupType and Dependencies, Get-CimInstance for StartName (account)
            $currentService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            $currentServiceCim = Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction SilentlyContinue

            if (-not $currentService -or -not $currentServiceCim) {
                Write-Log "Service '$serviceName' not found." -Level "ERROR"
                $resultsList.Add([PSCustomObject]@{ ServiceName=$serviceName; Property="Existence"; Expected="Present"; Current="NotFound"; ActionTaken="Error"; Status="Failed" }) | Out-Null
                if ($overallStatus -ne "Failed") { $overallStatus = if($overallStatus -eq "NoChangesNeeded") {"Failed"} else {"PartialSuccess"} } # If some succeeded before
                continue
            }

            # 1. StartupType Check & Set
            if ($serviceConfig.PSObject.Properties['startupType']) {
                $expectedStartupType = $serviceConfig.startupType
                $currentStartupType = $currentService.StartupType.ToString()
                $actionTaken = "NoChangeNeeded"
                $status = "Success"

                if ($currentStartupType -ne $expectedStartupType) {
                    Write-Log "Service [$serviceName]: StartupType mismatch. Current: [$currentStartupType], Expected: [$expectedStartupType]."
                    if ($EnforceSettings) {
                        if ($PSCmdlet.ShouldProcess("Service '$serviceName' on server '$ServerName'", "Set StartupType to '$expectedStartupType'")) {
                            try {
                                Set-Service -Name $serviceName -StartupType $expectedStartupType -ErrorAction Stop
                                $actionTaken = "Set to $expectedStartupType"
                                Write-Log "Service [$serviceName]: Successfully set StartupType to '$expectedStartupType'."
                                if ($overallStatus -eq "NoChangesNeeded") { $overallStatus = "ChangesMade" }
                            } catch {
                                $actionTaken = "FailedToSetStartupType"
                                $status = "Failed"
                                Write-Log "Service [$serviceName]: FAILED to set StartupType. Error: $($_.Exception.Message)" -Level "ERROR"
                                if ($overallStatus -ne "Failed") { $overallStatus = if($overallStatus -eq "NoChangesNeeded") {"Failed"} else {"PartialSuccess"} }
                            }
                        } else {
                            $actionTaken = "SkippedWhatIf_SetStartupType"
                            Write-Log "Service [$serviceName]: Set StartupType SKIPPED due to -WhatIf."
                        }
                    } else { # Audit mode
                        $actionTaken = "AuditMismatch_StartupType"
                        if ($overallStatus -ne "Failed" -and $overallStatus -ne "PartialSuccess") { $overallStatus = "AuditMismatchesFound" }
                        Write-Log "AUDIT: Service [$serviceName]: StartupType mismatch detected." -Level "INFO"
                    }
                } else { Write-Log "Service [$serviceName]: StartupType is compliant ('$currentStartupType')."}
                $resultsList.Add([PSCustomObject]@{ ServiceName=$serviceName; Property="StartupType"; Expected=$expectedStartupType; Current=$currentStartupType; ActionTaken=$actionTaken; Status=$status }) | Out-Null
            }

            # 2. Service Account Check (V1 - Reporting Only)
            if ($serviceConfig.PSObject.Properties['accountName']) {
                $expectedAccount = $serviceConfig.accountName
                $currentAccount = $currentServiceCim.StartName
                $actionTaken = "InfoOnly_NoChangeAttempted"
                $status = "Info"
                if ($currentAccount -ne $expectedAccount) {
                    Write-Log "Service [$serviceName]: Account mismatch. Current: [$currentAccount], Expected (from baseline): [$expectedAccount]. Manual change may be required." -Level "WARNING"
                    $actionTaken = "InfoOnly_AccountMismatchDetected"
                    if ($overallStatus -ne "Failed" -and $overallStatus -ne "PartialSuccess" -and $overallStatus -ne "ChangesMade") { $overallStatus = "AuditMismatchesFound" } # If only audit mismatches so far
                } else { Write-Log "Service [$serviceName]: Account name is as expected ('$currentAccount')." }
                 $resultsList.Add([PSCustomObject]@{ ServiceName=$serviceName; Property="AccountName"; Expected=$expectedAccount; Current=$currentAccount; ActionTaken=$actionTaken; Status=$status }) | Out-Null
            }

            # 3. Permissions Check (V1 - Reporting Only)
            if ($serviceConfig.PSObject.Properties['requiredPermissions']) {
                Write-Log "Service [$serviceName]: Required permissions check is conceptual in V1. Baseline specifies: [$($serviceConfig.requiredPermissions -join ', ')]." -Level "INFO"
                $resultsList.Add([PSCustomObject]@{ ServiceName=$serviceName; Property="Permissions"; Expected=($serviceConfig.requiredPermissions -join ', '); Current="NotChecked_V1"; ActionTaken="InfoOnly_NotChecked"; Status="Info" }) | Out-Null
            }

            # 4. Dependencies Check (V1 - Reporting Only)
            if ($serviceConfig.PSObject.Properties['dependencies'] -and $serviceConfig.dependencies -is [array]) {
                $expectedDependencies = $serviceConfig.dependencies | Sort-Object
                $currentDependencies = $currentService.ServicesDependedOn.Name | Sort-Object
                $actionTaken = "InfoOnly_NoChangeAttempted"
                $status = "Info"

                if (Compare-Object $expectedDependencies $currentDependencies -PassThru) { # If there are differences
                    Write-Log "Service [$serviceName]: Dependencies mismatch. Expected: [$($expectedDependencies -join ', ')], Current: [$($currentDependencies -join ', ')]." -Level "WARNING"
                    $actionTaken = "InfoOnly_DependenciesMismatch"
                    if ($overallStatus -ne "Failed" -and $overallStatus -ne "PartialSuccess" -and $overallStatus -ne "ChangesMade") { $overallStatus = "AuditMismatchesFound" }
                } else { Write-Log "Service [$serviceName]: Dependencies match baseline."}
                $resultsList.Add([PSCustomObject]@{ ServiceName=$serviceName; Property="Dependencies"; Expected=($expectedDependencies-join ', '); Current=($currentDependencies -join ', '); ActionTaken=$actionTaken; Status=$status }) | Out-Null
            }

        } catch {
            Write-Log "Failed to process service '$serviceName'. Error: $($_.Exception.Message)" -Level "ERROR"
            $resultsList.Add([PSCustomObject]@{ ServiceName=$serviceName; Property="OverallProcessing"; Expected="ConfiguredAsPerBaseline"; Current="ErrorProcessing"; ActionTaken="Error"; Status="Failed" }) | Out-Null
            if ($overallStatus -ne "Failed") { $overallStatus = if($overallStatus -eq "NoChangesNeeded") {"Failed"} else {"PartialSuccess"} }
        }
    } # End foreach serviceEntryKey

    # Final overall status adjustment if only Info/Audit changes occurred but no actual "ChangesMade" or "Failures"
    if ($overallStatus -eq "AuditMismatchesFound" -and -not ($resultsList | Where-Object {$_.Status -eq "Failed" -or $_.ActionTaken -like "Set to*"})) {
        # All good, just audit mismatches
    } elseif ($overallStatus -eq "NoChangesNeeded" -and ($resultsList | Where-Object {$_.Status -eq "Failed"})) {
        $overallStatus = "Failed" # Should have been caught, but as a safeguard
    }


    Write-Log "Set-ServiceAccountSecurity script finished. Overall Status: $overallStatus."
    return [PSCustomObject]@{
        ServerName               = $ServerName
        SettingsAppliedOrChecked = $resultsList
        OverallStatus            = $overallStatus
        Timestamp                = (Get-Date -Format o)
    }
}

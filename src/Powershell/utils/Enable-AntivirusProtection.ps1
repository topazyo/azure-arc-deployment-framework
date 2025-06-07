# Enable-AntivirusProtection.ps1
# This script attempts to enable Antivirus protection features, primarily focusing on Windows Defender.
# TODO V2: Add more robust handling for Update-MpSignature (e.g., run as job, check results async).
# TODO V2: Explore specific cmdlets for common 3rd party AVs if needed.

Function Enable-AntivirusProtection {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory=$false)]
        [string]$ProductName, # If specified and not "Windows Defender", V1 will be informational.

        [Parameter(Mandatory=$false)]
        [bool]$EnsureRealTimeProtection = $true,

        [Parameter(Mandatory=$false)]
        [bool]$EnsureSignaturesUpToDate = $true,

        [Parameter(Mandatory=$false)]
        [int]$SignatureMaxAgeHours = 24, # Consider signatures outdated if older than this

        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME, # For logging/context, Defender cmdlets are local

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\EnableAntivirusProtection_Activity.log"
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

    Write-Log "Starting Enable-AntivirusProtection on server '$ServerName'."
    Write-Log "Parameters: EnsureRealTimeProtection='$EnsureRealTimeProtection', EnsureSignaturesUpToDate='$EnsureSignaturesUpToDate', ProductName='$ProductName'."
    if ($ServerName -ne $env:COMPUTERNAME) {
        Write-Log "Warning: Windows Defender operations are local. '$ServerName' parameter is for reporting context." -Level "WARNING"
    }

    # --- Administrator Privilege Check ---
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Administrator privileges are required to manage Antivirus settings. Script cannot proceed." -Level "ERROR"
        throw "Administrator privileges required."
    } else {
        Write-Log "Running with Administrator privileges."
    }

    $actionsAttempted = [System.Collections.ArrayList]::new()
    $overallStatus = "NoActionTaken" # Default status
    $processedDefender = $false


    # --- Focus on Windows Defender if ProductName is not specified or is "Windows Defender" ---
    if ([string]::IsNullOrWhiteSpace($ProductName) -or $ProductName -like "Windows Defender*") {
        Write-Log "Focusing on Windows Defender."
        $defenderModule = Get-Module -Name Defender -ListAvailable
        if (-not $defenderModule) {
            Write-Log "Windows Defender PowerShell module not found. Cannot manage Defender." -Level "ERROR"
            $actionsAttempted.Add([PSCustomObject]@{ Action="DefenderModuleCheck"; TargetProduct="Windows Defender"; Status="Failed"; Details="Defender module not found."}) | Out-Null
            $overallStatus = "Failed"
        } else {
            $processedDefender = $true
            try {
                # Check current status
                $defenderStatus = Get-MpComputerStatus -ErrorAction SilentlyContinue # Use SilentlyContinue to check $null later
                if (-not $defenderStatus) {
                    Write-Log "Could not retrieve Windows Defender status via Get-MpComputerStatus. Defender might be disabled or uninstalled." -Level "ERROR"
                    $actionsAttempted.Add([PSCustomObject]@{ Action="GetDefenderStatus"; TargetProduct="Windows Defender"; Status="Failed"; Details="Get-MpComputerStatus failed."}) | Out-Null
                    $overallStatus = "Failed"
                } else {
                     Write-Log "Initial Defender Status: RealTimeProtectionEnabled='$($defenderStatus.RealTimeProtectionEnabled)', AV Sig Age='$($defenderStatus.AntivirusSignatureAge)', AS Sig Age='$($defenderStatus.AntispywareSignatureAge)'." -Level "DEBUG"

                    # 1. Real-Time Protection
                    if ($EnsureRealTimeProtection) {
                        $actionName = "EnableRealTimeProtection"
                        if ($defenderStatus.RealTimeProtectionEnabled) {
                            Write-Log "Windows Defender Real-Time Protection is already enabled."
                            $actionsAttempted.Add([PSCustomObject]@{ Action=$actionName; TargetProduct="Windows Defender"; Status="AlreadyEnabled"; Details="Real-time protection was already enabled."}) | Out-Null
                            if ($overallStatus -eq "NoActionTaken") {$overallStatus = "SuccessNoChangeNeeded"}
                        } else {
                            if ($PSCmdlet.ShouldProcess($ServerName, "Enable Windows Defender Real-Time Protection")) {
                                Write-Log "Attempting to enable Windows Defender Real-Time Protection..."
                                try {
                                    Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
                                    $newStatus = Get-MpComputerStatus
                                    if ($newStatus.RealTimeProtectionEnabled) {
                                        Write-Log "Successfully enabled Windows Defender Real-Time Protection."
                                        $actionsAttempted.Add([PSCustomObject]@{ Action=$actionName; TargetProduct="Windows Defender"; Status="Success"; Details="Real-time protection enabled."}) | Out-Null
                                        if ($overallStatus -ne "Failed") {$overallStatus = "Success"}
                                    } else {
                                        Write-Log "Set-MpPreference executed but Real-Time Protection is still reported as disabled." -Level "ERROR"
                                        $actionsAttempted.Add([PSCustomObject]@{ Action=$actionName; TargetProduct="Windows Defender"; Status="Failed"; Details="Set-MpPreference ran but RealTimeProtectionEnabled is still false."}) | Out-Null
                                        $overallStatus = "Failed"
                                    }
                                } catch {
                                    Write-Log "Failed to enable Real-Time Protection: $($_.Exception.Message)" -Level "ERROR"
                                    $actionsAttempted.Add([PSCustomObject]@{ Action=$actionName; TargetProduct="Windows Defender"; Status="Failed"; Details="$($_.Exception.Message)"}) | Out-Null
                                    $overallStatus = "Failed"
                                }
                            } else {
                                Write-Log "Enable Real-Time Protection skipped due to -WhatIf."
                                $actionsAttempted.Add([PSCustomObject]@{ Action=$actionName; TargetProduct="Windows Defender"; Status="SkippedWhatIf"; Details="Enable Real-Time Protection skipped."}) | Out-Null
                            }
                        }
                    } # End EnsureRealTimeProtection

                    # 2. Signature Updates
                    if ($EnsureSignaturesUpToDate) {
                        $actionName = "SignatureUpdate"
                        # Check age based on AntivirusSignatureAge (number of days since last update)
                        # MpComputerStatus also has AntispywareSignatureAge
                        if ($defenderStatus.AntivirusSignatureAge -le ($SignatureMaxAgeHours / 24) ) { # Age is in days
                             Write-Log "Windows Defender Antivirus signatures are current (Last updated: $($defenderStatus.AntivirusSignaturesLastUpdated), Age: $($defenderStatus.AntivirusSignatureAge) days)."
                             $actionsAttempted.Add([PSCustomObject]@{ Action=$actionName; TargetProduct="Windows Defender"; Status="NoUpdateNeeded"; Details="Signatures are current."}) | Out-Null
                             if ($overallStatus -eq "NoActionTaken") {$overallStatus = "SuccessNoChangeNeeded"}
                        } else {
                            if ($PSCmdlet.ShouldProcess($ServerName, "Initiate Windows Defender Signature Update (Last Update: $($defenderStatus.AntivirusSignaturesLastUpdated))")) {
                                Write-Log "Attempting to update Windows Defender signatures (Last Update: $($defenderStatus.AntivirusSignaturesLastUpdated), Age: $($defenderStatus.AntivirusSignatureAge) days)."
                                try {
                                    Update-MpSignature -ErrorAction Stop # This can take some time.
                                    Write-Log "Windows Defender signature update process initiated/completed." # Update-MpSignature is synchronous by default
                                    $actionsAttempted.Add([PSCustomObject]@{ Action=$actionName; TargetProduct="Windows Defender"; Status="StartedOrCompleted"; Details="Signature update process initiated/completed."}) | Out-Null
                                    if ($overallStatus -ne "Failed") {$overallStatus = "Success"} # Assuming success if no error, actual check would re-run Get-MpComputerStatus
                                } catch {
                                    Write-Log "Failed to update signatures: $($_.Exception.Message)" -Level "ERROR"
                                    $actionsAttempted.Add([PSCustomObject]@{ Action=$actionName; TargetProduct="Windows Defender"; Status="Failed"; Details="$($_.Exception.Message)"}) | Out-Null
                                    $overallStatus = "Failed"
                                }
                            } else {
                                Write-Log "Signature update skipped due to -WhatIf."
                                $actionsAttempted.Add([PSCustomObject]@{ Action=$actionName; TargetProduct="Windows Defender"; Status="SkippedWhatIf"; Details="Signature update skipped."}) | Out-Null
                            }
                        }
                    } # End EnsureSignaturesUpToDate
                } # End else Get-MpComputerStatus succeeded
            } catch { # Catch from the outer try for Defender operations
                 Write-Log "An unexpected error occurred during Windows Defender operations: $($_.Exception.Message)" -Level "ERROR"
                 $actionsAttempted.Add([PSCustomObject]@{ Action="DefenderOperations"; TargetProduct="Windows Defender"; Status="Failed"; Details="$($_.Exception.Message)"}) | Out-Null
                 $overallStatus = "Failed"
            }
        } # End if Defender module found
    } # End if focus on Defender

    # --- Generic WMI for other AVs (Informational for V1) ---
    if (-not $processedDefender -or ($ProductName -and $ProductName -notlike "Windows Defender*")) {
        $targetAV = if ($ProductName) { $ProductName } else { "Any Non-Defender AV" }
        Write-Log "Checking for non-Defender AV: '$targetAV' (V1: Informational Only)." -Level "INFO"
        $actionsAttempted.Add([PSCustomObject]@{ Action="ManageThirdPartyAV"; TargetProduct=$targetAV; Status="NotImplementedV1"; Details="V1 does not actively manage non-Defender AVs. Manual check/action required."}) | Out-Null
        if ($overallStatus -eq "NoActionTaken") { $overallStatus = "ManualActionRequired" }
        # Could add WMI query here to list products for informational purposes if desired
        try {
            $wmiAVs = Get-CimInstance -Namespace "root\SecurityCenter2" -ClassName AntiVirusProduct -ErrorAction SilentlyContinue
            if ($wmiAVs) {
                foreach ($av in $wmiAVs) {
                     Write-Log "Informational: Found WMI AV Product: Name='$($av.displayName)', State='$($av.productState)' (Hex: 0x$($av.productState.ToString('X')))." -Level "DEBUG"
                }
            }
        } catch { Write-Log "Minor error querying WMI for AV products: $($_.Exception.Message)" -Level "DEBUG" }
    }

    # Final overall status determination
    if ($overallStatus -eq "NoActionTaken" -and $actionsAttempted.Count -eq 0) {
        # This can happen if no specific productName was given and Defender module was missing.
        $overallStatus = "FailedPrereq" # More specific than NoActionTaken
    } elseif ($overallStatus -eq "NoActionTaken" -and $actionsAttempted.Count -gt 0) {
        # All actions resulted in NoUpdateNeeded or AlreadyEnabled or SkippedWhatIf
        $overallStatus = "SuccessNoChangeNeeded"
    }


    Write-Log "Enable-AntivirusProtection script finished. Overall Status: $overallStatus."
    return [PSCustomObject]@{
        ActionsAttempted    = $actionsAttempted
        OverallStatus       = $overallStatus
        Timestamp           = (Get-Date -Format o)
        ServerName          = $ServerName
    }
}

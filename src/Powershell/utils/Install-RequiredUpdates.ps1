# Install-RequiredUpdates.ps1
# This script installs required or missing system updates using the Windows Update Agent (WUA) COM objects.
# TODO: Add more sophisticated error code interpretation from WUA.
# TODO: Consider options for specific KB exclusion even if in a category.

Function Install-RequiredUpdates {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory=$false)]
        [string[]]$CategoriesToInstall, # e.g., "Critical Updates", "Security Updates"

        [Parameter(Mandatory=$false)]
        [bool]$AcceptEula = $false,

        [Parameter(Mandatory=$false)]
        [bool]$AutoReboot = $false,

        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME, # For logging/context, WUA operations are local

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\InstallRequiredUpdates_Activity.log"
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

    Write-Log "Starting Install-RequiredUpdates on server '$ServerName'."
    Write-Log "Parameters: CategoriesToInstall='$($CategoriesToInstall -join ', ')', AcceptEula='$AcceptEula', AutoReboot='$AutoReboot'."
    if ($ServerName -ne $env:COMPUTERNAME) {
        Write-Log "Warning: Windows Update operations are local. '$ServerName' parameter is for reporting context." -Level "WARNING"
    }

    # --- Administrator Privilege Check ---
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Administrator privileges are required to search for and install Windows Updates. Script cannot proceed." -Level "ERROR"
        throw "Administrator privileges required."
    } else {
        Write-Log "Running with Administrator privileges."
    }

    $updatesAttemptedCount = 0
    $successfullyInstalledUpdates = [System.Collections.ArrayList]::new()
    $failedToInstallUpdates = [System.Collections.ArrayList]::new()
    $rebootRequiredByInstall = $false
    $rebootInitiated = $false
    $overallStatus = "NoUpdatesFound" # Default status
    $downloadResultCode = $null
    $installResultCode = $null

    try {
        Write-Log "Initializing Windows Update Session..."
        $updateSession = New-Object -ComObject Microsoft.Update.Session -ErrorAction Stop
        $updateSearcher = $updateSession.CreateUpdateSearcher()
        $updateSearcher.Online = $true # Search online, not just cached metadata
        Write-Log "Update session created. Searching for applicable updates..."

        # V1: Search for all applicable, then filter by category in PowerShell if specified
        $searchCriteria = "IsInstalled=0 and Type='Software' and IsHidden=0 and IsAssigned=1" # IsAssigned=1 for WSUS/MU approved
        $searchResult = $updateSearcher.Search($searchCriteria)
        Write-Log "Initial search found $($searchResult.Updates.Count) total applicable updates."

        $updatesToProcess = New-Object -ComObject Microsoft.Update.UpdateColl -ErrorAction Stop

        if ($CategoriesToInstall -and $CategoriesToInstall.Count -gt 0) {
            Write-Log "Filtering updates by specified categories: $($CategoriesToInstall -join ', ')"
            foreach ($update in $searchResult.Updates) {
                $belongsToCategory = $false
                foreach ($categoryName in $CategoriesToInstall) {
                    if ($update.Categories | Where-Object { $_.Name -eq $categoryName }) {
                        $belongsToCategory = $true
                        break
                    }
                }
                if ($belongsToCategory) {
                    $updatesToProcess.Add($update) | Out-Null
                    Write-Log "Added update to process list (category match): '$($update.Title)'" -Level "DEBUG"
                }
            }
        } else {
            Write-Log "No specific categories provided. Processing all $($searchResult.Updates.Count) applicable updates found."
            foreach ($update in $searchResult.Updates) {
                $updatesToProcess.Add($update) | Out-Null
            }
        }

        $updatesAttemptedCount = $updatesToProcess.Count

        if ($updatesAttemptedCount -eq 0) {
            Write-Log "No updates found matching the specified criteria to download/install."
            $overallStatus = "NoUpdatesFoundOrNeeded"
        } else {
            Write-Log "Found $updatesAttemptedCount update(s) to download and install."
            $updatesToProcess | ForEach-Object { Write-Log "  - $($_.Title) (KB: $($_.KBArticleIDs -join ','))" }


            # --- EULA Acceptance ---
            if ($AcceptEula) {
                Write-Log "Attempting to accept EULAs for selected updates..."
                foreach ($update in $updatesToProcess) {
                    if (-not $update.EulaAccepted) {
                        if ($PSCmdlet.ShouldProcess($update.Title, "Accept EULA")) {
                            try {
                                $update.AcceptEula() | Out-Null # Some updates return void, some bool.
                                Write-Log "EULA accepted for update: '$($update.Title)'."
                            } catch {
                                Write-Log "Failed to accept EULA for '$($update.Title)'. Error: $($_.Exception.Message)" -Level "WARNING"
                                # Depending on strictness, could remove this update from $updatesToProcess or mark for failure
                            }
                        } else {
                            Write-Log "EULA acceptance for '$($update.Title)' skipped due to -WhatIf." -Level "INFO"
                        }
                    }
                }
            } else {
                 Write-Log "AcceptEula is false. Updates requiring EULA acceptance might fail to install if not pre-accepted." -Level "WARNING"
            }

            # --- Download Updates ---
            Write-Log "Starting download of $updatesAttemptedCount update(s)..."
            $downloader = $updateSession.CreateUpdateDownloader()
            $downloader.Updates = $updatesToProcess
            $downloadResult = $downloader.Download() # This is a synchronous call
            $downloadResultCode = $downloadResult.ResultCode
            Write-Log "Download ResultCode: $downloadResultCode (2=Succeeded, 3=SucceededWithErrors, 4=Failed)"

            if ($downloadResultCode -in @(2,3)) { # Succeeded or SucceededWithErrors
                Write-Log "Download completed with status code $downloadResultCode. Proceeding to installation."
                $overallStatus = "InstallInProgress"

                # --- Install Updates ---
                Write-Log "Starting installation of downloaded updates..."
                $installer = $updateSession.CreateUpdateInstaller()
                $installer.Updates = $updatesToProcess # Install the same collection that was downloaded

                # Note: Some updates cannot be installed if $installer.IsBusy is true from another process.
                if($installer.IsBusy){
                     Write-Log "WUA Installer is busy. Waiting for a short period." -Level "WARNING"
                     Start-Sleep -Seconds 30 # Brief wait
                     if($installer.IsBusy){ throw "WUA Installer remained busy. Cannot proceed."}
                }

                $installationResult = $installer.Install() # This is a synchronous call
                $installResultCode = $installationResult.ResultCode
                $rebootRequiredByInstall = $installationResult.RebootRequired
                Write-Log "Installation ResultCode: $installResultCode (2=Succeeded, 3=SucceededWithErrors, 4=Failed)"
                Write-Log "Reboot Required by installation: $rebootRequiredByInstall"

                # Log individual update results
                for ($i = 0; $i -lt $updatesToProcess.Count; $i++) {
                    $updateTitle = $updatesToProcess.Item($i).Title
                    $kb = ($updatesToProcess.Item($i).KBArticleIDs -join ',')
                    $resultForThisUpdate = $installationResult.GetUpdateResult($i) # IUpdateInstallationResult

                    if ($resultForThisUpdate.ResultCode -eq 2) { # OperationResultCode orcSuceeded
                        $successfullyInstalledUpdates.Add([PSCustomObject]@{ Title=$updateTitle; KB=$kb; Result="Success" }) | Out-Null
                        Write-Log "Successfully installed: $updateTitle"
                    } else {
                        $failedToInstallUpdates.Add([PSCustomObject]@{ Title=$updateTitle; KB=$kb; Result="Failed"; ErrorCode=$resultForThisUpdate.ResultCode; HResult=$resultForThisUpdate.HResult }) | Out-Null
                        Write-Log "Failed to install: $updateTitle. ResultCode: $($resultForThisUpdate.ResultCode), HResult: $($resultForThisUpdate.HResult)" -Level "ERROR"
                    }
                }

                if ($installResultCode -eq 2) { # All succeeded
                    $overallStatus = if ($rebootRequiredByInstall) { "SuccessRebootRequired" } else { "Success" }
                } elseif ($installResultCode -eq 3) { # Some succeeded, some failed
                    $overallStatus = if ($rebootRequiredByInstall) { "PartialSuccessRebootRequired" } else { "PartialSuccess" }
                } else { # 0, 1, 4, 5
                    $overallStatus = "Failed"
                }
            } else { # Download failed
                $overallStatus = "DownloadFailed"
                Write-Log "Download failed with ResultCode $downloadResultCode. Cannot proceed to install." -Level "ERROR"
            }
        }
    } catch {
        Write-Log "An error occurred during Windows Update operations: $($_.Exception.Message)" -Level "FATAL"
        Write-Log $_.ScriptStackTrace -Level "DEBUG"
        $overallStatus = "CriticalError"
        # Populate error details in the return object if possible
    } finally {
        # --- Handle Reboot ---
        if ($rebootRequiredByInstall -and $AutoReboot) {
            if ($PSCmdlet.ShouldProcess($ServerName, "Initiate Reboot for Windows Updates")) {
                Write-Log "AutoReboot is true and reboot is required. Initiating reboot..." -Level "INFO"
                Restart-Computer -Force
                $rebootInitiated = $true
            } else {
                Write-Log "AutoReboot is true and reboot is required, but -WhatIf prevented reboot." -Level "INFO"
            }
        } elseif ($rebootRequiredByInstall) {
            Write-Log "Reboot is required to complete update installation. AutoReboot is false or -WhatIf was used." -Level "WARNING"
        }
    }

    Write-Log "Install-RequiredUpdates script finished. Overall Status: $overallStatus."
    return [PSCustomObject]@{
        UpdatesAttemptedCount        = $updatesAttemptedCount
        UpdatesSuccessfullyInstalled = $successfullyInstalledUpdates
        UpdatesFailedToInstall       = $failedToInstallUpdates
        RebootRequired               = $rebootRequiredByInstall
        RebootInitiated              = $rebootInitiated
        Status                       = $overallStatus
        DownloadResultCode           = $downloadResultCode
        InstallResultCode            = $installResultCode
        Timestamp                    = (Get-Date -Format o)
    }
}

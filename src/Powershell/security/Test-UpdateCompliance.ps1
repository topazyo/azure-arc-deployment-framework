# Test-UpdateCompliance.ps1
# This script tests system update compliance against a baseline using the Windows Update Agent COM object.
# TODO: Enhance LastInstallDate check to be more specific if needed (e.g., specific update types from event log).
# TODO: Add more granular checks based on specific KBs if baseline defines them.

Function Test-UpdateCompliance {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$BaselineSettings, # Expected to have an 'updates' section

        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME, # For future remoting, COM object usage is local by default

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\TestUpdateCompliance_Activity.log"
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

    Write-Log "Starting Test-UpdateCompliance on server '$ServerName'."
    if ($ServerName -ne $env:COMPUTERNAME) {
        Write-Log "Warning: Windows Update COM object operations are local. Testing against '$ServerName' will reflect local machine's status." -Level "WARNING"
    }

    # --- Administrator Privilege Check ---
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Administrator privileges are recommended for full Windows Update Agent access. Results may be limited or fail." -Level "WARNING"
    } else {
        Write-Log "Running with Administrator privileges."
    }

    $allChecks = [System.Collections.ArrayList]::new()
    $script:overallCompliant = $true # Use script scope for helper function to modify

    # Helper function to add check results
    function Add-CheckResult {
        param([string]$Name, [bool]$IsCompliant, [object]$Expected, [object]$Actual, [string]$Details, [string]$RemediationSuggestion = "")
        $check = [PSCustomObject]@{ Name = $Name; Compliant = $IsCompliant; Expected = $Expected; Actual = $Actual; Details = $Details; Remediation = $RemediationSuggestion }
        $allChecks.Add($check) | Out-Null
        if (-not $IsCompliant) { $script:overallCompliant = $false }
        Write-Log "Check '$Name': Compliant=$IsCompliant. Expected='$Expected', Actual='$Actual'. Details: $Details" -Level (if($IsCompliant){"DEBUG"}else{"WARNING"})
    }

    $updateBaseline = $BaselineSettings.updates
    if (-not $updateBaseline) {
        Write-Log "No 'updates' section found in BaselineSettings. Cannot perform checks." -Level "ERROR"
        return [PSCustomObject]@{ Compliant = $false; Checks = $allChecks; Summary = @{}; Timestamp = (Get-Date -Format o); Error = "Missing updates baseline settings."}
    }

    # --- Initialize Summary Data ---
    $summary = @{
        PendingCriticalUpdatesCount = 0
        PendingSecurityUpdatesCount = 0
        OtherPendingUpdatesCount = 0
        LastSearchSuccessDate = $null
        LastInstallSuccessDate = $null # From AutoUpdate COM object
        IsRebootPending = $false
    }

    try {
        Write-Log "Initializing Windows Update COM Session..."
        $updateSession = New-Object -ComObject Microsoft.Update.Session -ErrorAction Stop
        $updateSearcher = $updateSession.CreateUpdateSearcher()
        Write-Log "Update session created. Searching for pending updates..."

        # --- Last Update Search Date ---
        try {
            $summary.LastSearchSuccessDate = $updateSearcher.GetTotalHistoryCount() # Triggers query that updates LastSearchSuccessDate
            $summary.LastSearchSuccessDate = $updateSearcher.LastSearchSuccessDate # Now it should be populated
             if ($summary.LastSearchSuccessDate -is [datetime] -and $summary.LastSearchSuccessDate -lt (Get-Date).AddYears(-20)) { # Com object can return minvalue
                $summary.LastSearchSuccessDate = "Never or Unknown"
            }
            $maxDaysSearch = if($updateBaseline.PSObject.Properties.Contains('maxDaysSinceLastUpdateSearch')) { $updateBaseline.maxDaysSinceLastUpdateSearch } else { 7 }
            $searchCompliant = $true
            if ($summary.LastSearchSuccessDate -isnot [datetime] -or $summary.LastSearchSuccessDate -lt (Get-Date).AddDays(-$maxDaysSearch)) {
                $searchCompliant = $false
            }
            Add-CheckResult "LastUpdateSearchDate" $searchCompliant "Within $maxDaysSearch days" $summary.LastSearchSuccessDate "Last successful search date for updates." "Run Windows Update check for updates."
        } catch {
            Write-Log "Could not determine LastSearchSuccessDate. Error: $($_.Exception.Message)" -Level "WARNING"
            Add-CheckResult "LastUpdateSearchDate" $false "Within specified days" "Error Retrieving" "$($_.Exception.Message)" "Investigate WUAgent."
        }

        # --- Pending Updates (Critical/Security) ---
        Write-Log "Searching for installed=0 and Type='Software' updates."
        $searchResult = $updateSearcher.Search("IsInstalled=0 and Type='Software'") # All pending software updates
        $pendingUpdates = $searchResult.Updates
        Write-Log "Found $($pendingUpdates.Count) total pending software updates."

        $critCatId = "e6cf1350-c01b-414d-a61f-263d14d133b4" # Critical Updates
        $secCatId  = "0fa1201d-4330-4fa8-8ae9-b877473b6441" # Security Updates

        foreach ($update in $pendingUpdates) {
            $isCritical = $false
            $isSecurity = $false
            foreach ($category in $update.Categories) {
                if ($category.CategoryID -eq $critCatId) { $isCritical = $true }
                if ($category.CategoryID -eq $secCatId)  { $isSecurity = $true }
            }
            if ($isCritical) { $summary.PendingCriticalUpdatesCount++ }
            if ($isSecurity) { $summary.PendingSecurityUpdatesCount++ }
            if (-not $isCritical -and -not $isSecurity) {$summary.OtherPendingUpdatesCount++}
        }
        Write-Log "Pending Critical: $($summary.PendingCriticalUpdatesCount), Security: $($summary.PendingSecurityUpdatesCount), Other: $($summary.OtherPendingUpdatesCount)."

        $maxCrit = if($updateBaseline.PSObject.Properties.Contains('maxPendingCriticalUpdates')) { $updateBaseline.maxPendingCriticalUpdates } else { 0 }
        $maxSec  = if($updateBaseline.PSObject.Properties.Contains('maxPendingSecurityUpdates')) { $updateBaseline.maxPendingSecurityUpdates } else { 0 }

        Add-CheckResult "PendingCriticalUpdates" ($summary.PendingCriticalUpdatesCount -le $maxCrit) "<= $maxCrit" $summary.PendingCriticalUpdatesCount "Count of pending critical updates." "Install critical updates."
        Add-CheckResult "PendingSecurityUpdates" ($summary.PendingSecurityUpdatesCount -le $maxSec) "<= $maxSec" $summary.PendingSecurityUpdatesCount "Count of pending security updates." "Install security updates."

        # --- Last Update Install Date ---
        if ($updateBaseline.PSObject.Properties.Contains('maxDaysSinceLastInstall')) {
            try {
                $autoUpdate = New-Object -ComObject Microsoft.Update.AutoUpdate -ErrorAction Stop
                $summary.LastInstallSuccessDate = $autoUpdate.Results.LastInstallationSuccessDate
                if ($summary.LastInstallSuccessDate -is [datetime] -and $summary.LastInstallSuccessDate -lt (Get-Date).AddYears(-20)) { # Com object can return minvalue
                     $summary.LastInstallSuccessDate = "Never or Unknown"
                }
                $maxDaysInstall = $updateBaseline.maxDaysSinceLastInstall
                $installCompliant = $true
                if ($summary.LastInstallSuccessDate -isnot [datetime] -or $summary.LastInstallSuccessDate -lt (Get-Date).AddDays(-$maxDaysInstall)) {
                    $installCompliant = $false
                }
                 Add-CheckResult "LastUpdateInstallDate" $installCompliant "Within $maxDaysInstall days" $summary.LastInstallSuccessDate "Last successful update installation date (any type)." "Ensure updates are installing regularly."
            } catch {
                Write-Log "Could not determine LastInstallationSuccessDate from AutoUpdate object. Error: $($_.Exception.Message)" -Level "WARNING"
                Add-CheckResult "LastUpdateInstallDate" $false "Within specified days" "Error Retrieving" "$($_.Exception.Message)" "Investigate WUAgent AutoUpdate."
            }
        }

    } catch {
        Write-Log "Failed to interact with Windows Update Agent: $($_.Exception.Message)" -Level "ERROR"
        Add-CheckResult "WUA_Interaction" $false "Successful" "Failed" "$($_.Exception.Message)" "Ensure Windows Update Service is running and COM object is accessible."
    }

    # --- Reboot Pending Status ---
    $rebootIsPending = $false
    $rebootReasons = [System.Collections.ArrayList]::new()
    # Key paths that indicate a pending reboot
    $rebootKeys = @(
        "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired",
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending"
    )
    foreach ($keyPath in $rebootKeys) {
        if (Test-Path $keyPath) { # Existence of key/value indicates reboot needed
            $rebootIsPending = $true
            $reasons.Add("KeyExists:$keyPath") | Out-Null # Using $reasons, should be $rebootReasons
            Write-Log "Reboot pending indicated by: $keyPath" -Level "DEBUG"
        }
    }
    $summary.IsRebootPending = $rebootIsPending
    $expectedRebootPending = if($updateBaseline.PSObject.Properties.Contains('rebootPending')) { [bool]$updateBaseline.rebootPending } else { $false } # Baseline expects reboot *not* to be pending

    Add-CheckResult "RebootPending" ($rebootIsPending -eq $expectedRebootPending) $expectedRebootPending $rebootIsPending "Checks for common reboot pending flags in registry." "Reboot server if pending and baseline requires no pending reboot."


    Write-Log "Test-UpdateCompliance script finished. Overall Compliance: $script:overallCompliant."
    return [PSCustomObject]@{
        Compliant           = $script:overallCompliant
        Checks              = $allChecks
        Summary             = $summary
        Timestamp           = (Get-Date -Format o)
        ServerName          = $ServerName
    }
}

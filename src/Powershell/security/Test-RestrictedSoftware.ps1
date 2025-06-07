# Test-RestrictedSoftware.ps1
# This script checks if any restricted software (by name/publisher pattern) is installed.
# V1: Focuses on checking installed programs via Uninstall registry keys.
# TODO: Add options for checking running processes or services if needed in future.
# TODO: Add more sophisticated pattern matching (e.g., regex, version checks) if baseline defines it.

Function Test-RestrictedSoftware {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$BaselineSettings, # Expected to have restrictedSoftware.software array

        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME, # For reporting context

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\TestRestrictedSoftware_Activity.log"
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

    Write-Log "Starting Test-RestrictedSoftware on server '$ServerName'."
    if ($ServerName -ne $env:COMPUTERNAME) {
        Write-Log "Warning: Software checks are performed locally. '$ServerName' parameter is for reporting context." -Level "WARNING"
    }

    # --- Administrator Privilege Check (Recommended for full HKLM Uninstall key access) ---
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Administrator privileges are recommended for comprehensive software checks (especially HKLM Uninstall keys). Results might be incomplete." -Level "WARNING"
    } else {
        Write-Log "Running with Administrator privileges (or current user context for HKCU if ever added)."
    }

    $restrictedSoftwareChecks = [System.Collections.ArrayList]::new()
    $script:overallCompliant = $true # Assume compliant until restricted software is found

    $restrictedPatterns = $null
    if ($BaselineSettings.PSObject.Properties['restrictedSoftware'] -and $BaselineSettings.restrictedSoftware.PSObject.Properties['software'] -is [array]) {
        $restrictedPatterns = $BaselineSettings.restrictedSoftware.software
    }

    if (-not $restrictedPatterns -or $restrictedPatterns.Count -eq 0) {
        Write-Log "No restricted software patterns defined in BaselineSettings.restrictedSoftware.software array. Test will pass by default." -Level "INFO"
        return [PSCustomObject]@{
            Compliant = $true
            Checks = $restrictedSoftwareChecks # Empty
            Timestamp = (Get-Date -Format o)
            ServerName = $ServerName
        }
    }
    Write-Log "Checking against $($restrictedPatterns.Count) restricted software patterns."

    # --- Registry Paths for Installed Software ---
    $uninstallPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
        # Future: "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    $installedPrograms = [System.Collections.ArrayList]::new()
    foreach ($path in $uninstallPaths) {
        if (Test-Path $path) {
            Get-ChildItem -Path $path -ErrorAction SilentlyContinue | ForEach-Object {
                $prog = $_ | Get-ItemProperty -ErrorAction SilentlyContinue
                if ($prog.DisplayName) { # Only consider items with a DisplayName
                    $installedPrograms.Add([PSCustomObject]@{
                        Name = $prog.DisplayName
                        Publisher = $prog.Publisher
                        Version = $prog.DisplayVersion
                        InstallLocation = $prog.InstallLocation
                        UninstallString = $prog.UninstallString
                        RegistryPath = $_.PSPath # Path to the specific uninstall key
                    }) | Out-Null
                }
            }
        } else {
            Write-Log "Registry path not found: $path" -Level "DEBUG"
        }
    }
    Write-Log "Found $($installedPrograms.Count) installed programs in Uninstall registry keys for checking." -Level "INFO"
    if ($installedPrograms.Count -eq 0) {
         Write-Log "No installed programs found in registry to check against restricted list." -Level "INFO"
         # If no programs installed, then compliant by default with respect to restricted software.
    }


    foreach ($pattern in $restrictedPatterns) {
        Write-Log "Checking for pattern: '$pattern'" -Level "DEBUG"
        $foundItemsForThisPattern = [System.Collections.ArrayList]::new()

        foreach ($program in $installedPrograms) {
            $matchFound = $false
            if ($program.Name -like $pattern) {
                $matchFound = $true
                Write-Log "Pattern '$pattern' matched program DisplayName: '$($program.Name)' (Publisher: $($program.Publisher))." -Level "INFO"
            }
            elseif ($program.Publisher -like $pattern) {
                $matchFound = $true
                Write-Log "Pattern '$pattern' matched program Publisher: '$($program.Publisher)' (Name: $($program.Name))." -Level "INFO"
            }
            # Could add checks for other properties like version if pattern definition was more complex

            if ($matchFound) {
                $foundItemsForThisPattern.Add($program) | Out-Null
            }
        }

        if ($foundItemsForThisPattern.Count -gt 0) {
            $script:overallCompliant = $false
            $remediationSuggestion = "Review and uninstall software matching pattern '$pattern'. Use details from 'FoundItems' (e.g., UninstallString or Name/Publisher) to locate and remove."
            $checkDetails = "Found $($foundItemsForThisPattern.Count) installed program(s) matching pattern '$pattern'."

            $restrictedSoftwareChecks.Add([PSCustomObject]@{
                RestrictedPattern = $pattern
                FoundItems        = $foundItemsForThisPattern # Array of matched program objects
                Details           = $checkDetails
                Remediation       = $remediationSuggestion
            }) | Out-Null
            Write-Log $checkDetails -Level "WARNING"
        } else {
            Write-Log "No installed software found matching pattern '$pattern'." -Level "DEBUG"
        }
    }

    # V1: Placeholder for checking processes/services
    Write-Log "Note: V1 does not actively scan running processes or services for restricted software. Manual review may be warranted for deeper inspection." -Level "INFO"


    Write-Log "Test-RestrictedSoftware script finished. Overall Compliance: $script:overallCompliant."
    return [PSCustomObject]@{
        Compliant           = $script:overallCompliant
        Checks              = $restrictedSoftwareChecks # Only populated if non-compliant items are found
        Timestamp           = (Get-Date -Format o)
        ServerName          = $ServerName
    }
}

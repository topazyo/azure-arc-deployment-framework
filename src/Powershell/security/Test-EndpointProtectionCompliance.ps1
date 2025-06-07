# Test-EndpointProtectionCompliance.ps1
# This script tests endpoint protection status, primarily focusing on Windows Defender.
# TODO: Enhance detection and status checks for common 3rd party AV products if needed.
# TODO: More sophisticated parsing/checking of ScanSchedule based on baseline string.

Function Test-EndpointProtectionCompliance {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$BaselineSettings, # Expected to have antiMalware section

        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME, # Currently operates on local machine

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\TestEndpointProtectionCompliance_Activity.log"
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

    Write-Log "Starting Test-EndpointProtectionCompliance on server '$ServerName'."
    if ($ServerName -ne $env:COMPUTERNAME) {
        Write-Log "Warning: Script currently designed for local server operations for Defender cmdlets. Remote functionality for these is not directly used." -Level "WARNING"
    }

    # --- Administrator Privilege Check ---
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Administrator privileges may be required for full endpoint protection status access. Results may be incomplete." -Level "WARNING"
    } else {
        Write-Log "Running with Administrator privileges."
    }

    $allChecks = [System.Collections.ArrayList]::new()
    $overallCompliant = $true
    $detectedAVs = [System.Collections.ArrayList]::new()

    # Helper function to add check results
    function Add-CheckResult {
        param([string]$Name, [bool]$IsCompliant, [object]$Expected, [object]$Actual, [string]$Details, [string]$RemediationSuggestion = "")
        $check = [PSCustomObject]@{ Name = $Name; Compliant = $IsCompliant; Expected = $Expected; Actual = $Actual; Details = $Details; Remediation = $RemediationSuggestion }
        $allChecks.Add($check) | Out-Null
        if (-not $IsCompliant) { $Global:overallCompliant = $false } # Use script scope
        Write-Log "Check '$Name': Compliant=$IsCompliant. Expected='$Expected', Actual='$Actual'. Details: $Details" -Level (if($IsCompliant){"DEBUG"}else{"WARNING"})
    }
    $script:overallCompliant = $true # Initialize script-scoped variable

    # --- Baseline Checks ---
    $antiMalwareBaseline = $BaselineSettings.antiMalware
    if (-not $antiMalwareBaseline) {
        Write-Log "No 'antiMalware' section found in BaselineSettings. Cannot perform checks." -Level "ERROR"
        return [PSCustomObject]@{ Compliant = $false; Checks = $allChecks; DetectedAVProducts = $detectedAVs; Timestamp = (Get-Date -Format o); Error = "Missing antiMalware baseline settings."}
    }

    # --- Attempt to use Windows Defender cmdlets first (most reliable if Defender is in use) ---
    $defenderModule = Get-Module -Name Defender -ListAvailable
    if (-not $defenderModule) {
        Write-Log "Windows Defender PowerShell module not found. Defender status checks will be skipped." -Level "WARNING"
        Add-CheckResult -Name "DefenderModule" -IsCompliant $false -Expected "Present" -Actual "Not Found" -Details "Defender PowerShell module missing." -RemediationSuggestion "Ensure Windows Defender feature is installed."
    } else {
        Write-Log "Windows Defender module found. Proceeding with Defender status checks."
        try {
            $defenderStatus = Get-MpComputerStatus -ErrorAction Stop
            $defenderProductInfo = @{ Name = "Windows Defender"; ProductState = "Unknown"; SignaturesUpToDate = $false; RealTimeProtectionEnabled = $defenderStatus.RealTimeProtectionEnabled }

            # Real-time Protection
            if ($antiMalwareBaseline.PSObject.Properties.Contains('realTimeProtection')) {
                $expectedRTP = [bool]$antiMalwareBaseline.realTimeProtection
                Add-CheckResult -Name "DefenderRealTimeProtection" -IsCompliant ($defenderStatus.RealTimeProtectionEnabled -eq $expectedRTP) `
                    -Expected $expectedRTP -Actual $defenderStatus.RealTimeProtectionEnabled `
                    -Details "Checks Get-MpComputerStatus | Select-Object RealTimeProtectionEnabled." `
                    -RemediationSuggestion "Set Windows Defender Real-Time Protection to $expectedRTP."
            }
            $defenderProductInfo.RealTimeProtectionEnabled = $defenderStatus.RealTimeProtectionEnabled # For detected AV summary

            # Signature Freshness (Antivirus)
            $maxSigAgeDays = if($antiMalwareBaseline.PSObject.Properties.Contains('maxSignatureAgeDays')) { $antiMalwareBaseline.maxSignatureAgeDays } else { 3 }
            $sigAgeOk = ($defenderStatus.AntivirusSignaturesLastUpdated -ge (Get-Date).AddDays(-$maxSigAgeDays))
            Add-CheckResult -Name "DefenderAntivirusSignatureFreshness" -IsCompliant $sigAgeOk `
                -Expected "Within $maxSigAgeDays days" -Actual $defenderStatus.AntivirusSignaturesLastUpdated `
                -Details "Checks Get-MpComputerStatus | Select-Object AntivirusSignaturesLastUpdated." `
                -RemediationSuggestion "Ensure Windows Defender signatures are updated regularly."
            $defenderProductInfo.SignaturesUpToDate = $sigAgeOk # Simplified for summary

            # Scan Schedule (Basic Check for Daily Quick Scan - can be more complex)
            if ($antiMalwareBaseline.PSObject.Properties.Contains('scanSchedule')) {
                $expectedScanSchedule = $antiMalwareBaseline.scanSchedule # e.g., "Daily"
                $mpPrefs = Get-MpPreference -ErrorAction SilentlyContinue
                $actualScanDesc = "NotConfigured"
                $scanCompliant = $false
                if ($mpPrefs) {
                    # This is a simplified check. "Daily" could mean ScanScheduleDay=8 (EveryDay) or specific daily jobs.
                    # A quick scan being enabled is also a factor: $mpPrefs.QuickScanTime
                    if ($expectedScanSchedule -eq "Daily" -and ($mpPrefs.ScanScheduleDay -eq 8 -or $mpPrefs.ScanScheduleQuickScanTime)) {
                        $actualScanDesc = "Daily (Day: $($mpPrefs.ScanScheduleDay), QuickScanTime: $($mpPrefs.ScanScheduleQuickScanTime))"
                        $scanCompliant = $true
                    } else {
                         $actualScanDesc = "Day: $($mpPrefs.ScanScheduleDay), Time: $($mpPrefs.ScanScheduleTime), QuickScanTime: $($mpPrefs.ScanScheduleQuickScanTime)"
                    }
                }
                Add-CheckResult -Name "DefenderScanSchedule" -IsCompliant $scanCompliant `
                    -Expected $expectedScanSchedule -Actual $actualScanDesc `
                    -Details "Checks Get-MpPreference for scan schedule settings (simplified check)." `
                    -RemediationSuggestion "Configure Windows Defender scan schedule as per baseline."
            }
             # Product State for Defender (derived)
            if ($defenderStatus.AntivirusEnabled -and $defenderStatus.RealTimeProtectionEnabled) {
                $defenderProductInfo.ProductState = "Enabled and Active"
            } elseif ($defenderStatus.AntivirusEnabled) {
                $defenderProductInfo.ProductState = "Enabled (RTP Disabled)"
            } else {$defenderProductInfo.ProductState = "Disabled"}

            $detectedAVs.Add([pscustomobject]$defenderProductInfo) | Out-Null

        } catch {
            Write-Log "Failed to get Windows Defender status using Get-MpComputerStatus or Get-MpPreference. Error: $($_.Exception.Message)" -Level "ERROR"
            Add-CheckResult -Name "DefenderStatusCmdlets" -IsCompliant $false -Expected "CmdletsAccessible" -Actual "Failed" -Details "$($_.Exception.Message)" -RemediationSuggestion "Ensure Defender services are running and module is functional."
        }
    }

    # --- Generic WMI Check for AV Products (Informational, less reliable on Servers) ---
    Write-Log "Attempting generic WMI check for AntiVirusProduct (root\SecurityCenter2 - mainly for Client OS)." -Level "INFO"
    try {
        $wmiAVs = Get-CimInstance -Namespace "root\SecurityCenter2" -ClassName AntiVirusProduct -ErrorAction SilentlyContinue
        if ($wmiAVs) {
            foreach ($av in $wmiAVs) {
                $avName = $av.displayName
                $avProductStateHex = "0x$($av.productState.ToString('X'))" # Display state in hex
                Write-Log "WMI (SecurityCenter2): Found AV '$avName', ProductState: $avProductStateHex."
                # Decoding productState is complex: e.g., 262144 (disabled), 266240 (enabled), 393216 (snoozed but active), 397312 (active & up to date)
                # For V1, just list them. If Defender wasn't found above, this might be the primary AV.
                if (-not ($detectedAVs | Where-Object {$_.Name -eq $avName})) {
                     $detectedAVs.Add([PSCustomObject]@{ Name=$avName; ProductState=$avProductStateHex; SignaturesUpToDate="UnknownWMI"; RealTimeProtectionEnabled="UnknownWMI" }) | Out-Null
                }
                # A baseline might specify an expected AV product name.
                if ($antiMalwareBaseline.PSObject.Properties.Contains('expectedProductName') -and $avName -notmatch $antiMalwareBaseline.expectedProductName) {
                     Add-CheckResult -Name "ExpectedAVProduct_WMI" -IsCompliant $false `
                        -Expected $antiMalwareBaseline.expectedProductName -Actual $avName `
                        -Details "An unexpected or non-primary AV product found via WMI."
                }
            }
        } else { Write-Log "No AV products found via WMI root\SecurityCenter2."}
    } catch { Write-Log "Error querying WMI root\SecurityCenter2: $($_.Exception.Message)" -Level "WARNING"}

    # Final check: Is at least one AV active and compliant (if Defender was checked)?
    if ($detectedAVs.Count -eq 0) {
        Add-CheckResult -Name "AVProductActive" -IsCompliant $false -Expected "At least one active AV" -Actual "NoneDetected" -Details "No AV product detected via Defender cmdlets or WMI." -RemediationSuggestion "Ensure an AV product is installed and running."
    } elseif (($detectedAVs | Where-Object {$_.Name -eq "Windows Defender" -and $_.ProductState -like "Enabled*" -and $_.RealTimeProtectionEnabled -eq $true -and $_.SignaturesUpToDate -eq $true}).Count -gt 0 ) {
         Add-CheckResult -Name "AVProductActiveAndCompliant" -IsCompliant $true -Expected "Defender Active & Compliant" -Actual "Windows Defender Active & Compliant" -Details "Windows Defender meets basic compliance."
    } else { # Some AV detected, but not necessarily Defender or not fully compliant
         Add-CheckResult -Name "AVProductActiveAndCompliant" -IsCompliant $false -Expected "Defender Active & Compliant (or other specified AV)" -Actual "See DetectedAVProducts" -Details "Review DetectedAVProducts for specific AV status; Defender may not be fully compliant or active."
    }


    Write-Log "Test-EndpointProtectionCompliance script finished. Overall Compliance: $script:overallCompliant."
    return [PSCustomObject]@{
        Compliant           = $script:overallCompliant
        Checks              = $allChecks
        DetectedAVProducts  = $detectedAVs
        Timestamp           = (Get-Date -Format o)
        ServerName          = $ServerName
    }
}

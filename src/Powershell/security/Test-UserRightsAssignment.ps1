# Test-UserRightsAssignment.ps1
# This script tests user rights assignments against a baseline.
# V1: This script is a placeholder and reports expected user rights assignments.
# Actual verification requires parsing secedit.exe output or using LocalSecurityPolicy cmdlets/APIs, which is not implemented here.

Function Test-UserRightsAssignment {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$BaselineSettings, # Expected to have localSecurityPolicy.localPolicies.userRightsAssignment

        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME, # For reporting context

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\TestUserRightsAssignment_Activity.log"
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

    Write-Log "Starting Test-UserRightsAssignment on server '$ServerName'."
    Write-Log "V1: This script reports expected User Rights Assignments from baseline; actual system state is not queried automatically." -Level "INFO"
    if ($ServerName -ne $env:COMPUTERNAME) {
        Write-Log "Warning: User Rights Assignment checks are local. '$ServerName' parameter is for reporting context." -Level "WARNING"
    }

    # --- Administrator Privilege Check (as secedit.exe would require it) ---
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Administrator privileges would be required to accurately query all User Rights Assignments (e.g., using secedit.exe). Reporting based on baseline only." -Level "WARNING"
        # Allow to proceed as V1 is report-only for expected values, but actual verification would be hampered.
    } else {
        Write-Log "Running with Administrator privileges (noted for future system queries)."
    }

    $allChecks = [System.Collections.ArrayList]::new()
    # Overall status: If there are items to check, and we can't check them, it's not truly "Compliant".
    # It's more like "ManualVerificationRequired" or "NotImplemented".
    $script:overallStatusString = "NoUserRightsDefinedInBaseline"

    function Add-URACheckResult {
        param([string]$UserRightName, [string]$ComplianceStatus, [object]$ExpectedPrincipals, [string]$Details, [string]$RemediationSuggestion = "")
        $check = [PSCustomObject]@{
            Name = $UserRightName
            Compliant = $false # V1 cannot confirm compliance
            StatusString = $ComplianceStatus
            Expected = $ExpectedPrincipals
            Actual = "Not Queried (V1)"
            Details = $Details
            Remediation = $RemediationSuggestion
        }
        $allChecks.Add($check) | Out-Null
        # Update overall status string: If any check is added, it means manual verification is needed.
        if ($script:overallStatusString -eq "NoUserRightsDefinedInBaseline" -or $script:overallStatusString -eq "CompliantPlaceholder") {
             $script:overallStatusString = "ManualVerificationRequired"
        }
        Write-Log "Check '$UserRightName': Status='$ComplianceStatus'. Expected='($($ExpectedPrincipals -join ', '))'. Actual='Not Queried (V1)'. Details: $Details" -Level "INFO"
    }

    $uraBaseline = $null
    if ($BaselineSettings.PSObject.Properties['localSecurityPolicy'] -and `
        $BaselineSettings.localSecurityPolicy.PSObject.Properties['localPolicies'] -and `
        $BaselineSettings.localSecurityPolicy.localPolicies.PSObject.Properties['userRightsAssignment']) {
        $uraBaseline = $BaselineSettings.localSecurityPolicy.localPolicies.userRightsAssignment
    }

    if (-not $uraBaseline) {
        Write-Log "No 'localSecurityPolicy.localPolicies.userRightsAssignment' section found in BaselineSettings or it's empty." -Level "INFO"
        # $overallStatusString remains "NoUserRightsDefinedInBaseline"
    } else {
        Write-Log "Processing User Rights Assignments defined in baseline (V1: Reporting expected values only)."
        if ($uraBaseline.PSObject.Properties.Count -eq 0) {
            Write-Log "User Rights Assignment baseline section is empty. No specific rights to check." -Level "INFO"
            # $overallStatusString remains "NoUserRightsDefinedInBaseline"
        } else {
             $script:overallStatusString = "ManualVerificationRequired" # Items are defined, so manual check needed
        }

        foreach ($property in $uraBaseline.PSObject.Properties) {
            $userRightName = $property.Name
            $expectedPrincipals = @($property.Value) # Ensure it's an array

            Add-URACheckResult -UserRightName $userRightName `
                -ComplianceStatus "NotImplemented_RequiresSeceditOrAPI" `
                -ExpectedPrincipals ($expectedPrincipals -join ', ') `
                -Details "V1: Automated check requires parsing secedit.exe output or using LSA APIs (not implemented)." `
                -RemediationSuggestion "Manually verify '$userRightName' using Local Security Policy editor (secpol.msc) or 'secedit /export'."
        }
    }

    # Determine boolean overall compliance for the 'Compliant' field
    # For V1, if there were any URA settings in baseline, it's not compliant automatically.
    $finalOverallCompliantBoolean = $false
    if ($script:overallStatusString -eq "NoUserRightsDefinedInBaseline") {
        $finalOverallCompliantBoolean = $true # No URA settings to check, so vacuously compliant
    }
    # Otherwise, it's ManualVerificationRequired, which means not automatically compliant.

    Write-Log "Test-UserRightsAssignment script finished. Overall Status String: $script:overallStatusString."
    return [PSCustomObject]@{
        Compliant           = $finalOverallCompliantBoolean
        OverallStatusString = $script:overallStatusString # More descriptive status for URA V1
        Checks              = $allChecks
        Timestamp           = (Get-Date -Format o)
        ServerName          = $ServerName
    }
}

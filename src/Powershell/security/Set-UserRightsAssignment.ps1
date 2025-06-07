# Set-UserRightsAssignment.ps1
# This script processes User Rights Assignments from a baseline.
# V1: This script is a placeholder. It reports expected User Rights Assignments based on the baseline
# but does not automatically apply them. Manual configuration or 'secedit.exe /configure' is required.
# TODO V2: Implement actual setting of User Rights using secedit.exe /configure with a dynamically generated INF,
# or by using LSA P/Invoke calls (complex) or a module like Carbon.

Function Set-UserRightsAssignment {
    [CmdletBinding(SupportsShouldProcess = $true)] # SupportsShouldProcess for consistency, though V1 doesn't change state
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$BaselineSettings, # Expected to have localSecurityPolicy.localPolicies.userRightsAssignment

        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME, # For reporting context

        [Parameter(Mandatory=$false)]
        [bool]$EnforceSettings = $true, # In V1, this only affects logging/reporting of intent

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\SetUserRightsAssignment_Activity.log"
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

    Write-Log "Starting Set-UserRightsAssignment on server '$ServerName'."
    Write-Log "V1: This script reports expected User Rights Assignments. No system changes will be made regarding User Rights." -Level "INFO"
    Write-Log "Parameter EnforceSettings = $EnforceSettings (In V1, this influences reporting of intent only for User Rights)."

    if ($ServerName -ne $env:COMPUTERNAME) {
        Write-Log "Warning: User Rights Assignments are local policies. '$ServerName' parameter is for reporting context." -Level "WARNING"
    }

    # --- Administrator Privilege Check (as secedit.exe or LSA APIs would require it) ---
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Administrator privileges would be required to apply User Rights Assignments. Reporting expected state only." -Level "WARNING"
        # No hard stop if not enforcing, but good to note. If $EnforceSettings were true for real changes, we'd throw.
    } else {
        Write-Log "Running with Administrator privileges (noted for future system-modifying versions)."
    }

    $actionsToTakeManually = [System.Collections.ArrayList]::new()
    $overallStatus = "NoUserRightsDefinedInBaseline"

    $uraBaseline = $null
    if ($BaselineSettings.PSObject.Properties['localSecurityPolicy'] -and `
        $BaselineSettings.localSecurityPolicy.PSObject.Properties['localPolicies'] -and `
        $BaselineSettings.localSecurityPolicy.localPolicies.PSObject.Properties['userRightsAssignment']) {
        $uraBaseline = $BaselineSettings.localSecurityPolicy.localPolicies.userRightsAssignment
    }

    if (-not $uraBaseline) {
        Write-Log "No 'localSecurityPolicy.localPolicies.userRightsAssignment' section found in BaselineSettings or it's empty." -Level "INFO"
    } elseif ($uraBaseline.PSObject.Properties.Count -eq 0) {
        Write-Log "User Rights Assignment baseline section is empty. No specific rights to process." -Level "INFO"
    } else {
        Write-Log "Processing User Rights Assignments defined in baseline (V1: Reporting only)."
        $overallStatus = "ManualActionsRequired" # Items are defined, so manual action/review is implied by V1 nature

        foreach ($property in $uraBaseline.PSObject.Properties) {
            $userRightName = $property.Name
            $expectedPrincipals = @($property.Value) # Ensure it's an array

            $detailsMsg = "V1 does not automate User Rights Assignments. Use secpol.msc or 'secedit.exe /configure' with an appropriate INF file."
            if ($EnforceSettings) {
                Write-Log "User Right: '$userRightName'. Baseline Expects: '$($expectedPrincipals -join ', ')'. Action: $detailsMsg" -Level "INFO"
            } else {
                Write-Log "AUDIT User Right: '$userRightName'. Baseline Expects: '$($expectedPrincipals -join ', ')'. Action: $detailsMsg" -Level "INFO"
            }

            $actionsToTakeManually.Add([PSCustomObject]@{
                UserRightName      = $userRightName
                ExpectedPrincipals = $expectedPrincipals
                Status             = "ManualConfigurationRequired_V1"
                Details            = $detailsMsg
            }) | Out-Null
        }
    }

    Write-Log "Set-UserRightsAssignment script (V1) finished. Overall Status: $overallStatus."
    return [PSCustomObject]@{
        ActionsToTakeManually = $actionsToTakeManually
        OverallStatus         = $overallStatus
        Timestamp             = (Get-Date -Format o)
        ServerName            = $ServerName
        EnforceMode           = $EnforceSettings
    }
}

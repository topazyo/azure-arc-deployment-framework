# Repair-CertificateIssues.ps1
# This script attempts to repair identified issues for a specific certificate.
# V1: Focuses on calling Repair-CertificateChain.ps1 for chain issues and logging manual steps for others.
# TODO V2: Implement automated renewal attempts for expired/nearing-expiry certs.
# TODO V2: Explore certutil -repairstore automation if feasible and safe for MissingPrivateKey.

Function Repair-CertificateIssues {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory=$true)]
        [string]$CertificateThumbprint,

        [Parameter(Mandatory=$true)]
        [string[]]$Issues, # e.g., @("Expired", "ChainError", "MissingPrivateKey")

        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME, # For context, operations are local

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\RepairCertificateIssues_Activity.log"
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

    Write-Log "Starting Repair-CertificateIssues for Thumbprint: '$CertificateThumbprint'."
    Write-Log "Identified Issues: $($Issues -join ', ')."
    if ($ServerName -ne $env:COMPUTERNAME) {
        Write-Log "Warning: Certificate operations are performed locally. '$ServerName' parameter is for reporting context." -Level "WARNING"
    }

    $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path -Resolve
    $PathRepairCertificateChain = Join-Path $PSScriptRoot "Repair-CertificateChain.ps1"


    # --- Administrator Privilege Check ---
    # Needed for Repair-CertificateChain if it installs intermediates to LocalMachine, or for future repair actions.
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Administrator privileges may be required for some certificate repair actions (e.g., installing intermediates). Script may have limited capabilities." -Level "WARNING"
    } else {
        Write-Log "Running with Administrator privileges (or current user with sufficient cert store access)."
    }

    # --- Get the certificate object ---
    $certificateToRepair = Get-Item -Path "Cert:\LocalMachine\My\$CertificateThumbprint" -ErrorAction SilentlyContinue
    if (-not $certificateToRepair) {
        # Try other common stores if not in LocalMachine\My, though machine certs are typically there.
        $certificateToRepair = Get-Item -Path "Cert:\CurrentUser\My\$CertificateThumbprint" -ErrorAction SilentlyContinue
        if ($certificateToRepair) { Write-Log "Certificate found in CurrentUser\My store." }
    } else { Write-Log "Certificate found in LocalMachine\My store."}

    if (-not $certificateToRepair) {
        Write-Log "Certificate with Thumbprint '$CertificateThumbprint' not found in LocalMachine\My or CurrentUser\My. Cannot proceed." -Level "ERROR"
        return [PSCustomObject]@{
            CertificateSubject = "NotFound"
            CertificateThumbprint = $CertificateThumbprint
            AttemptedRepairs = @()
            OverallRepairStatus = "FailedCertificateNotFound"
            Timestamp = (Get-Date -Format o)
        }
    }
    Write-Log "Found certificate: Subject='$($certificateToRepair.Subject)', Thumbprint='$($certificateToRepair.Thumbprint)'."

    $attemptedRepairs = [System.Collections.ArrayList]::new()
    $overallStatus = "NoActionTaken" # Default if no repairable issues or actions taken
    $anyActionAttempted = $false
    $anyActionFailed = $false
    $anyManualActionRequired = $false


    foreach ($issueType in $Issues) {
        $repairStatus = "NoActionTaken"
        $repairDetails = "No automated repair action defined for this issue type in V1."

        Write-Log "Addressing issue: '$issueType' for certificate '$($certificateToRepair.Subject)'."

        if (-not $PSCmdlet.ShouldProcess("Certificate '$($certificateToRepair.Subject)' for issue '$issueType'", "Attempt Repair Action")) {
            Write-Log "Repair attempt for issue '$issueType' on certificate '$($certificateToRepair.Subject)' skipped due to -WhatIf." -Level "INFO"
            $repairStatus = "SkippedWhatIf"
            $repairDetails = "Repair attempt skipped by -WhatIf."
            $attemptedRepairs.Add([PSCustomObject]@{ IssueType=$issueType; Status=$repairStatus; Details=$repairDetails }) | Out-Null
            continue
        }
        $anyActionAttempted = $true

        switch -Wildcard ($issueType.ToLower()) {
            "expired" -or "*nearingexpiry*" {
                $repairStatus = "ManualActionRequired"
                $repairDetails = "V1 does not automate certificate renewal. Manual renewal through CA or certlm.msc is required for $($certificateToRepair.Subject) (Thumbprint: $CertificateThumbprint)."
                Write-Log $repairDetails -Level "WARNING"
                $anyManualActionRequired = $true
            }
            "missingprivatekey" {
                $repairStatus = "ManualActionRequired"
                $repairDetails = "V1 does not automate private key repair (e.g., via 'certutil -repairstore'). This often requires the original key or a PFX backup. Manual intervention needed for $($certificateToRepair.Subject)."
                Write-Log $repairDetails -Level "WARNING"
                $anyManualActionRequired = $true
            }
            "hostnamemismatch" {
                $repairStatus = "ManualActionRequired_ReissueCertificate"
                $repairDetails = "V1 does not automate certificate re-issuance for hostname mismatches. A new certificate with correct Subject Alternative Names (SANs) is typically required for $($certificateToRepair.Subject)."
                Write-Log $repairDetails -Level "WARNING"
                $anyManualActionRequired = $true
            }
            "chainerror" -or "partialchain" {
                Write-Log "Issue '$issueType' detected. Attempting to call Repair-CertificateChain.ps1."
                if (-not (Test-Path $PathRepairCertificateChain -PathType Leaf)) {
                    $repairStatus = "FailedDependencyMissing"
                    $repairDetails = "Dependency script Repair-CertificateChain.ps1 not found at '$PathRepairCertificateChain'."
                    Write-Log $repairDetails -Level "ERROR"
                    $anyActionFailed = $true
                } else {
                    try {
                        # Assuming Repair-CertificateChain.ps1 takes the cert object and install flags
                        $chainRepairResult = . $PathRepairCertificateChain -Certificate $certificateToRepair -InstallMissingIntermediates $true -LogPath $LogPath -ErrorAction Stop

                        if ($chainRepairResult -and $chainRepairResult.PSObject.Properties['OverallResult']) {
                            $repairDetails = "Repair-CertificateChain.ps1 executed. Final Chain Status: $($chainRepairResult.OverallResult). Initial: $($chainRepairResult.InitialChainStatus -join ', '). Final: $($chainRepairResult.FinalChainStatus -join ', ')."
                            if ($chainRepairResult.OverallResult -eq "Success" -or $chainRepairResult.OverallResult -eq "SuccessAfterRepair" -or $chainRepairResult.OverallResult -eq "NoActionNeeded") {
                                $repairStatus = "Success" # Or "ChainRepairAttempted_Success"
                                Write-Log "Repair-CertificateChain.ps1 reported success or no action needed for '$($certificateToRepair.Subject)'."
                            } else {
                                $repairStatus = "Failed" # Or "ChainRepairAttempted_Failed"
                                $anyActionFailed = $true
                                Write-Log "Repair-CertificateChain.ps1 reported issues or failure for '$($certificateToRepair.Subject)'. Details: $repairDetails" -Level "WARNING"
                            }
                        } else {
                             $repairStatus = "Failed"
                             $repairDetails = "Repair-CertificateChain.ps1 did not return expected result structure."
                             Write-Log $repairDetails -Level "ERROR"
                             $anyActionFailed = $true
                        }
                    } catch {
                        $repairStatus = "FailedExecutionError"
                        $repairDetails = "Error executing Repair-CertificateChain.ps1: $($_.Exception.Message)"
                        Write-Log $repairDetails -Level "ERROR"
                        $anyActionFailed = $true
                    }
                }
            }
            default {
                $repairStatus = "UnsupportedIssueType"
                $repairDetails = "No specific automated repair action defined in V1 for issue type: '$issueType'."
                Write-Log $repairDetails -Level "WARNING"
                # $anyManualActionRequired = $true # Or consider this a form of no action taken for this issue.
            }
        }
        $attemptedRepairs.Add([PSCustomObject]@{ IssueType=$issueType; Status=$repairStatus; Details=$repairDetails }) | Out-Null
    } # End foreach issueType

    # Determine OverallRepairStatus
    if (-not $anyActionAttempted) {
        $overallStatus = "NoActionTaken" # Could be because no issues were repairable by this script
    } elseif ($anyActionFailed) {
        $overallStatus = "Failed" # If any critical step like dependency call failed
    } elseif ($anyManualActionRequired -and ($attemptedRepairs | Where-Object {$_.Status -ne "Success" -and $_.Status -ne "SkippedWhatIf"}).Count -gt 0) {
        # If manual actions are needed AND other actions didn't all succeed (or were not applicable)
        $overallStatus = "ManualActionsRequired"
    } elseif (($attemptedRepairs | Where-Object {$_.Status -ne "Success" -and $_.Status -ne "SkippedWhatIf" -and $_.Status -ne "NoActionTaken" -and $_.Status -ne "UnsupportedIssueType"}).Count -eq 0) {
        # All attempted actions (that weren't manual placeholders from the start) succeeded or were skipped
        $overallStatus = "Success"
        if($anyManualActionRequired){ $overallStatus = "PartialSuccess_ManualActionsRequired"} # Some succeeded, some manual
    }
     else {
        $overallStatus = "PartialSuccess" # Mix of success and other states
    }


    Write-Log "Repair-CertificateIssues script finished for Thumbprint '$CertificateThumbprint'. Overall Repair Status: $overallStatus."
    return [PSCustomObject]@{
        CertificateSubject        = $certificateToRepair.Subject
        CertificateThumbprint     = $CertificateThumbprint
        AttemptedRepairs          = $attemptedRepairs
        OverallRepairStatus       = $overallStatus
        Timestamp                 = (Get-Date -Format o)
    }
}

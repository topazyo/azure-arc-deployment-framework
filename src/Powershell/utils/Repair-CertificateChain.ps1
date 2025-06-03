# Repair-CertificateChain.ps1
# This script attempts to repair the certificate chain for a given end-entity certificate
# by downloading and installing missing intermediate certificates from AIA URLs.

Function Repair-CertificateChain {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory=$true)]
        [System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,

        [Parameter(Mandatory=$false)]
        [bool]$InstallMissingIntermediates = $true,

        [Parameter(Mandatory=$false)] # Assuming intermediates go to LocalMachine\CA
        [string]$IntermediateStoreLocation = "LocalMachine",
        [Parameter(Mandatory=$false)]
        [string]$IntermediateStoreName = "CA",


        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\RepairCertificateChain_Activity.log"
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

    # --- Helper to get Chain Status strings ---
    function Get-ChainStatusStrings {
        param([System.Security.Cryptography.X509Certificates.X509ChainStatus[]]$ChainStatus)
        if ($ChainStatus.Count -eq 0) { return "NoErrors" }
        return ($ChainStatus | ForEach-Object { $_.Status.ToString() }) -join ", "
    }

    Write-Log "Starting Repair-CertificateChain for certificate: Subject='$($Certificate.Subject)', Thumbprint='$($Certificate.Thumbprint)'."
    Write-Log "Parameters: InstallMissingIntermediates='$InstallMissingIntermediates'."

    $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path -Resolve
    $PathInstallIntermediateCerts = Join-Path $PSScriptRoot "Install-IntermediateCertificates.ps1"


    # --- Administrator Privilege Check (if installing to LocalMachine) ---
    if ($InstallMissingIntermediates -and $IntermediateStoreLocation -eq "LocalMachine") {
        if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Write-Log "Administrator privileges are required to install intermediate certificates to LocalMachine store. AIA fetching and installation will be skipped if needed." -Level "WARNING"
            # Allow to proceed for chain check, but installation might fail or be skipped.
            # $InstallMissingIntermediates = $false # Optionally force it off
        } else {
            Write-Log "Running with Administrator privileges."
        }
    }

    $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
    $chainPolicy = New-Object System.Security.Cryptography.X509Certificates.X509ChainPolicy
    $chainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
    # $chainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::AllowUnknownCertificateAuthority # Use if self-signed roots are okay
    $chain.ChainPolicy = $chainPolicy

    $initialChainBuilt = $false
    $initialChainStatus = @()
    $intermediatesDownloadedAndInstalled = [System.Collections.ArrayList]::new()
    $overallResult = "NoActionNeeded" # Default

    try {
        Write-Log "Performing initial chain build..."
        $initialChainBuilt = $chain.Build($Certificate)
        $initialChainStatus = $chain.ChainStatus | ForEach-Object { $_.Status } # Store as string array
        Write-Log "Initial chain build attempt completed. Success: $initialChainBuilt. Status: $(Get-ChainStatusStrings $chain.ChainStatus)"

        if ($chain.ChainElements.Count -gt 0) {
            Write-Log "Initial chain elements ($($chain.ChainElements.Count)): "
            $chain.ChainElements | ForEach-Object { Write-Log "  Subject: $($_.Certificate.Subject), Issuer: $($_.Certificate.Issuer), Status: $(Get-ChainStatusStrings $_.ChainElementStatus)" -Level "DEBUG" }
        }

        if (-not $initialChainBuilt -and $InstallMissingIntermediates -and ($initialChainStatus -contains "PartialChain" -or $initialChainStatus -contains "OfflineRevocation")) {
            Write-Log "Initial chain is incomplete. Attempting to download and install missing intermediates from AIA."
            $overallResult = "AttemptedRepair" # Mark that we are trying something
            $installedSomethingNew = $false

            # Iterate from the end entity cert up to (but not including) the root
            for ($i = 0; $i -lt ($chain.ChainElements.Count - 1); $i++) {
                $element = $chain.ChainElements[$i]
                $elementCert = $element.Certificate
                $elementStatus = $element.ChainElementStatus | ForEach-Object { $_.Status }

                # If this element has issues that AIA might resolve (e.g. its issuer is missing or issuer's revocation offline)
                if ($elementStatus -contains "PartialChain" -or $elementStatus -contains "OfflineRevocation") {
                    Write-Log "Chain element '$($elementCert.Subject)' has status indicating potential missing issuer. Checking AIA." -Level "DEBUG"

                    $aiaExtension = $elementCert.Extensions | Where-Object { $_.Oid.FriendlyName -eq 'Authority Information Access' }
                    if ($aiaExtension) {
                        $aiaFormatted = $aiaExtension.Format($false) # Multi-line false gives one line per entry
                        Write-Log "AIA extension found for '$($elementCert.Subject)': $aiaFormatted" -Level "DEBUG"

                        # Regex to find CA Issuers URLs (typically HTTP for .crt or .cer)
                        $aiaUrls = [regex]::Matches($aiaFormatted, "CA Issuers\s*URI:(http://[^\s,]+(\.crt|\.cer|\.p7c))", "IgnoreCase") | ForEach-Object { $_.Groups[1].Value }

                        foreach ($url in $aiaUrls) {
                            Write-Log "Found CA Issuers AIA URL: $url"
                            $tempCertFileName = "$(New-Guid).tmpcert" # More specific extension later
                            if ($url -match "\.p7c$") { $tempCertFileName = "$(New-Guid).p7c" }
                            elseif ($url -match "\.cer$") { $tempCertFileName = "$(New-Guid).cer" }
                            else { $tempCertFileName = "$(New-Guid).crt" } # Default to .crt

                            $tempCertPath = Join-Path $env:TEMP $tempCertFileName

                            $downloadStatus = "Failed"
                            $installStatus = "NotAttempted"
                            $downloadedCertThumbprint = $null

                            if ($PSCmdlet.ShouldProcess($url, "Download Potential Intermediate Certificate")) {
                                try {
                                    Write-Log "Attempting to download from '$url' to '$tempCertPath'."
                                    Invoke-WebRequest -Uri $url -OutFile $tempCertPath -TimeoutSec 10 -ErrorAction Stop
                                    Write-Log "Downloaded successfully."
                                    $downloadStatus = "Success"

                                    if (-not (Test-Path $PathInstallIntermediateCerts -PathType Leaf)) {
                                        Write-Log "Install-IntermediateCertificates.ps1 not found at '$PathInstallIntermediateCerts'. Cannot install downloaded certificate." -Level "ERROR"
                                        throw "Dependency script Install-IntermediateCertificates.ps1 not found."
                                    }

                                    # If it's a p7c, Install-IntermediateCertificates would need to handle it (it might just try Import-Certificate which can handle some p7c)
                                    Write-Log "Attempting to install '$tempCertPath' to $IntermediateStoreLocation\$IntermediateStoreName."
                                    $installResult = . $PathInstallIntermediateCerts -CertificatePaths $tempCertPath -StoreLocation $IntermediateStoreLocation -StoreName $IntermediateStoreName -LogPath $LogPath -ErrorAction SilentlyContinue

                                    # Check result of Install-IntermediateCertificates.ps1 (assuming it returns array of status objects)
                                    if ($installResult -and $installResult[0].Status -eq "Success") {
                                        $installStatus = "Success"
                                        $downloadedCertThumbprint = $installResult[0].Thumbprint
                                        $installedSomethingNew = $true
                                        Write-Log "Successfully installed certificate from '$url' (Thumbprint: $downloadedCertThumbprint)."
                                    } else {
                                        $installStatus = "Failed"
                                        Write-Log "Failed to install certificate from '$url'. Install script msg: $($installResult[0].ErrorMessage)" -Level "WARNING"
                                    }
                                } catch {
                                    Write-Log "Failed to download or process certificate from '$url'. Error: $($_.Exception.Message)" -Level "WARNING"
                                    $downloadStatus = "FailedDownloadOrProcess"
                                    $installStatus = "NotAttemptedDueToDownloadFailure"
                                } finally {
                                    if (Test-Path $tempCertPath) { Remove-Item $tempCertPath -ErrorAction SilentlyContinue }
                                }
                            } else {
                                Write-Log "Download from '$url' skipped due to -WhatIf."
                                $downloadStatus = "SkippedWhatIf"
                            }
                            $intermediatesDownloadedAndInstalled.Add([PSCustomObject]@{ Url = $url; DownloadStatus = $downloadStatus; InstallStatus = $installStatus; Thumbprint = $downloadedCertThumbprint }) | Out-Null
                        } # End foreach AIA URL
                    } else { Write-Log "No AIA extension found for '$($elementCert.Subject)'." -Level "DEBUG" }
                } # End if element has partial chain/offline revocation
            } # End for loop through chain elements

            if ($installedSomethingNew) {
                Write-Log "Re-building chain after attempting intermediate certificate installations..."
                # Need a new chain object for a clean build, or clear status on existing.
                $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
                $chain.ChainPolicy = $chainPolicy # Apply same policy
                $initialChainBuilt = $chain.Build($Certificate) # Re-assign to initialChainBuilt for final status check
                Write-Log "Second chain build attempt completed. Success: $initialChainBuilt. Status: $(Get-ChainStatusStrings $chain.ChainStatus)"
                if ($chain.ChainElements.Count -gt 0) {
                    Write-Log "Final chain elements ($($chain.ChainElements.Count)): "
                    $chain.ChainElements | ForEach-Object { Write-Log "  Subject: $($_.Certificate.Subject), Issuer: $($_.Certificate.Issuer), Status: $(Get-ChainStatusStrings $_.ChainElementStatus)" -Level "DEBUG" }
                }
            }
        } # End if should attempt AIA download

        # Determine final result
        if ($initialChainBuilt) { # Check the result of the latest chain.Build()
            $overallResult = "Success" # Chain built without errors
            Write-Log "Final chain validation successful."
        } elseif ($overallResult -ne "AttemptedRepair") { # If no repair was attempted and it failed initially
            $overallResult = "FailedToBuildValidChain"
            Write-Log "Final chain validation failed, and no repair was attempted or conditions not met for repair." -Level "WARNING"
        } else { # Repair was attempted, but it still might not be perfect
             $overallResult = if($initialChainBuilt) {"SuccessAfterRepair"} else {"FailedDespiteRepair"}
             Write-Log "Final chain validation after repair attempt: $overallResult" -Level (if($initialChainBuilt){"INFO"}else{"WARNING"})
        }

    } catch {
        Write-Log "A critical error occurred during chain processing: $($_.Exception.Message)" -Level "FATAL"
        Write-Log $_.ScriptStackTrace -Level "DEBUG"
        $overallResult = "CriticalErrorInScript"
    } finally {
        if ($chain) { $chain.Dispose() } # Dispose of the chain object
    }

    $finalOutput = [PSCustomObject]@{
        InputCertificateSubject         = $Certificate.Subject
        InputCertificateThumbprint      = $Certificate.Thumbprint
        InitialChainStatus              = $initialChainStatus # Array of X509ChainStatusFlags strings
        IntermediatesDownloadedAndInstalled = $intermediatesDownloadedAndInstalled
        FinalChainStatus                = if($chain){ ($chain.ChainStatus | ForEach-Object { $_.Status }) } else { $initialChainStatus }
        OverallResult                   = $overallResult
        Timestamp                       = Get-Date -Format o
    }
    Write-Log "Repair-CertificateChain script finished. Overall Result: $overallResult."
    return $finalOutput
}

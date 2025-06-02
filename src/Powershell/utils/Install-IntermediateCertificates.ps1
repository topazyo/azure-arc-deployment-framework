# Install-IntermediateCertificates.ps1
# This script installs specified intermediate certificate files to the target certificate store.
# It is very similar to Install-RootCertificates.ps1, with a different default StoreName.
# TODO: Consider adding -Force to Import-Certificate if re-importing existing certs is desired.

Function Install-IntermediateCertificates {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory=$true)]
        [string[]]$CertificatePaths,

        [Parameter(Mandatory=$false)]
        [ValidateSet("LocalMachine", "CurrentUser")]
        [string]$StoreLocation = "LocalMachine",

        [Parameter(Mandatory=$false)]
        [string]$StoreName = "CA", # Intermediate Certification Authorities (PowerShell's Import-Certificate often uses "CA" or "Intermediate")

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\InstallIntermediateCertificates_Activity.log"
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

    Write-Log "Starting Install-IntermediateCertificates script."
    Write-Log "Parameters: StoreLocation='$StoreLocation', StoreName='$StoreName', CertificatePaths count='$($CertificatePaths.Count)'."

    # --- Administrator Privilege Check for LocalMachine store ---
    if ($StoreLocation -eq "LocalMachine") {
        if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Write-Log "Administrator privileges are required to install certificates to LocalMachine store. This script may fail." -Level "WARNING"
            # Let Import-Certificate handle the specific error if privileges are insufficient.
        } else {
            Write-Log "Running with Administrator privileges, proceeding with LocalMachine store installation."
        }
    }

    $results = [System.Collections.ArrayList]::new()
    $fullStorePath = "Cert:\$StoreLocation\$StoreName"
    Write-Log "Target certificate store path: $fullStorePath"

    foreach ($certPath in $CertificatePaths) {
        $currentCertResult = [PSCustomObject]@{
            CertificatePath = $certPath
            Status          = "Pending"
            Thumbprint      = $null
            Subject         = $null
            Store           = $fullStorePath
            ErrorMessage    = $null
            Timestamp       = Get-Date -Format o
        }

        Write-Log "Processing certificate file: '$certPath'."

        if (-not (Test-Path -Path $certPath -PathType Leaf)) {
            $currentCertResult.Status = "FileNotFound"
            $currentCertResult.ErrorMessage = "Certificate file not found at specified path."
            Write-Log $currentCertResult.ErrorMessage -Level "ERROR"
            $results.Add($currentCertResult) | Out-Null
            continue
        }

        if (-not $PSCmdlet.ShouldProcess($certPath, "Import Certificate to Store '$fullStorePath'")) {
            $currentCertResult.Status = "SkippedWhatIf"
            $currentCertResult.ErrorMessage = "Import skipped due to -WhatIf or user choice."
            Write-Log $currentCertResult.ErrorMessage -Level "INFO"
            $results.Add($currentCertResult) | Out-Null
            continue
        }

        try {
            $importedCert = Import-Certificate -FilePath $certPath -CertStoreLocation $fullStorePath -ErrorAction Stop
            
            if ($importedCert) {
                $currentCertResult.Status = "Success"
                $currentCertResult.Thumbprint = $importedCert.Thumbprint
                $currentCertResult.Subject = $importedCert.Subject
                Write-Log "Successfully imported certificate '$($currentCertResult.Subject)' (Thumbprint: $($currentCertResult.Thumbprint)) from '$certPath' to '$fullStorePath'."
            } else {
                $currentCertResult.Status = "Failed" # Should be caught by ErrorAction Stop if something went wrong
                $currentCertResult.ErrorMessage = "Import-Certificate returned no object, but no error was caught by ErrorAction Stop. This may indicate an unexpected issue."
                Write-Log $currentCertResult.ErrorMessage -Level "ERROR"
            }
        }
        catch {
            $currentCertResult.Status = "Failed"
            $currentCertResult.ErrorMessage = "Error importing certificate from '$certPath': $($_.Exception.Message)"
            Write-Log $currentCertResult.ErrorMessage -Level "ERROR"
            Write-Log "Exception Details: $($_.ToString())" -Level "DEBUG"
        }
        $results.Add($currentCertResult) | Out-Null
    }
    
    Write-Log "Install-IntermediateCertificates script finished. Processed $($CertificatePaths.Count) certificate paths."
    return $results
}

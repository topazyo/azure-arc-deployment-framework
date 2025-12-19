# Install-RootCertificates.ps1
# This script installs specified root certificate files to the target certificate store.
# TODO: Consider adding -Force to Import-Certificate if re-importing existing certs is desired (though usually not needed for roots).

Function Install-RootCertificates {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory=$true)]
        [string[]]$CertificatePaths,

        [Parameter(Mandatory=$false)]
        [ValidateSet("LocalMachine", "CurrentUser")]
        [string]$StoreLocation = "LocalMachine",

        [Parameter(Mandatory=$false)]
        [string]$StoreName = "AuthRoot", # Trusted Root Certification Authorities (PowerShell's Import-Certificate often uses "Root" as an alias)

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\InstallRootCertificates_Activity.log",

        [Parameter(Mandatory=$false)]
        [switch]$SkipIfExists = $true,

        [Parameter(Mandatory=$false)]
        [switch]$ForceImport
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

    Write-Log "Starting Install-RootCertificates script."
    Write-Log "Parameters: StoreLocation='$StoreLocation', StoreName='$StoreName', CertificatePaths count='$($CertificatePaths.Count)'."

    # --- Administrator Privilege Check for LocalMachine store ---
    if ($StoreLocation -eq "LocalMachine") {
        if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            Write-Log "Administrator privileges are required to install certificates to LocalMachine store. Script cannot proceed." -Level "ERROR"
            # To make this function more testable for non-admin, one might return a specific status object
            # For now, it effectively stops by not being able to import.
            # We'll let Import-Certificate fail with access denied if not admin, rather than throwing here.
            Write-Warning "Attempting to install to LocalMachine without Administrator privileges. This is likely to fail."
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

        $certFileObject = $null
        try { $certFileObject = Get-PfxCertificate -FilePath $certPath -ErrorAction Stop } catch {}

        if ($SkipIfExists -and $certFileObject) {
            try {
                $existing = Get-ChildItem -Path $fullStorePath -ErrorAction Stop | Where-Object { $_.Thumbprint -eq $certFileObject.Thumbprint }
                if ($existing) {
                    $currentCertResult.Status = "AlreadyExists"
                    $currentCertResult.Thumbprint = $certFileObject.Thumbprint
                    $currentCertResult.Subject = $certFileObject.Subject
                    Write-Log "Certificate already present in store; skipping import. Thumbprint: $($certFileObject.Thumbprint)" -Level "INFO"
                    $results.Add($currentCertResult) | Out-Null
                    continue
                }
            } catch {
                Write-Log "Existing-certificate check failed for '$fullStorePath': $($_.Exception.Message)" -Level "WARNING"
            }
        }

        if (-not $PSCmdlet.ShouldProcess($certPath, "Import Certificate to Store '$fullStorePath'")) {
            $currentCertResult.Status = "SkippedWhatIf"
            $currentCertResult.ErrorMessage = "Import skipped due to -WhatIf or user choice."
            Write-Log $currentCertResult.ErrorMessage -Level "INFO"
            $results.Add($currentCertResult) | Out-Null
            continue
        }

        try {
            # Import-Certificate is generally flexible with "Root" vs "AuthRoot" for the system store.
            # Using the specified $StoreName for consistency.
            $importParams = @{ FilePath = $certPath; CertStoreLocation = $fullStorePath; ErrorAction = 'Stop' }
            $importedCert = Import-Certificate @importParams
            
            if ($importedCert) {
                $currentCertResult.Status = "Success"
                $currentCertResult.Thumbprint = $importedCert.Thumbprint
                $currentCertResult.Subject = $importedCert.Subject
                Write-Log "Successfully imported certificate '$($currentCertResult.Subject)' (Thumbprint: $($currentCertResult.Thumbprint)) from '$certPath' to '$fullStorePath'."
            } else {
                # Should not happen if ErrorAction is Stop and no error, but as a safeguard
                $currentCertResult.Status = "Failed"
                $currentCertResult.ErrorMessage = "Import-Certificate returned no object, but no error was thrown."
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
    
    Write-Log "Install-RootCertificates script finished. Processed $($CertificatePaths.Count) certificate paths."
    return $results
}

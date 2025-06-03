# Update-CertificateStore.ps1
# This script manages and validates certificates in the Windows certificate store.

param (
    [Parameter(Mandatory = $false)]
    [bool]$UpdateRootCertificates = $true,

    [Parameter(Mandatory = $false)]
    [bool]$ValidateChain = $true,

    # MinimumKeySize, AllowedSignatureAlgorithms, DisallowedSignatureAlgorithms will be read from JSON by default
    [Parameter(Mandatory = $false)]
    [int]$MinimumKeySizeOverride,

    [Parameter(Mandatory = $false)]
    [string[]]$AllowedSignatureAlgorithmsOverride,

    [Parameter(Mandatory = $false)]
    [string[]]$DisallowedSignatureAlgorithmsOverride,

    [Parameter(Mandatory = $false)]
    [bool]$BackupCertificates = $true # Placeholder for future backup functionality
)

# Function for logging messages
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO" # Levels: INFO, WARNING, ERROR, DEBUG
    )
    # Simple Write-Host for now, can be expanded for more sophisticated logging
    Write-Host "[$Level] $Message"
}

# --- Helper Functions ---
function Test-CertificateExists {
    param (
        [string]$Thumbprint,
        [string]$StorePath = "Cert:\LocalMachine\Root"
    )
    return Test-Path -Path "$StorePath\$Thumbprint"
}

# --- Main Script Logic ---
try {
    Write-Log "Starting certificate store update and validation script."

    # Define paths
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $ConfigFile = Join-Path -Path $ScriptRoot -ChildPath "..\..\config\security-baseline.json"

    # Read configuration
    Write-Log "Reading configuration from $ConfigFile..."
    if (-not (Test-Path -Path $ConfigFile)) {
        Write-Log "Configuration file $ConfigFile not found." -Level "ERROR"
        exit 1
    }
    $Config = Get-Content -Path $ConfigFile | ConvertFrom-Json
    $CertSettings = $Config.certificateSettings

    if (-not $CertSettings) {
        Write-Log "certificateSettings section not found in the configuration file." -Level "ERROR"
        exit 1
    }

    # Determine effective settings (override if parameters are provided)
    $MinimumKeySize = if ($PSBoundParameters.ContainsKey('MinimumKeySizeOverride')) { $MinimumKeySizeOverride } else { $CertSettings.minimumKeySize }
    $AllowedSignatureAlgorithms = if ($PSBoundParameters.ContainsKey('AllowedSignatureAlgorithmsOverride')) { $AllowedSignatureAlgorithmsOverride } else { $CertSettings.allowedSignatureAlgorithms }
    $DisallowedSignatureAlgorithms = if ($PSBoundParameters.ContainsKey('DisallowedSignatureAlgorithmsOverride')) { $DisallowedSignatureAlgorithmsOverride } else { $CertSettings.disallowedSignatureAlgorithms }

    Write-Log "Effective MinimumKeySize: $MinimumKeySize"
    Write-Log "Effective AllowedSignatureAlgorithms: $($AllowedSignatureAlgorithms -join ', ')"
    Write-Log "Effective DisallowedSignatureAlgorithms: $($DisallowedSignatureAlgorithms -join ', ')"

    # Placeholder for Backup Functionality
    if ($BackupCertificates) {
        Write-Log "Certificate backup functionality is not yet implemented." -Level "WARNING"
        # TODO: Implement certificate export logic if required for a backup step
    }

    # 1. Update Root Certificates
    if ($UpdateRootCertificates) {
        Write-Log "--- Updating Root Certificates ---"
        if ($CertSettings.requiredCertificates) {
            foreach ($reqCert in $CertSettings.requiredCertificates) {
                $certSubject = $reqCert.subject
                $certThumbprint = $reqCert.thumbprint
                $certStore = $reqCert.store # e.g., "Root", "CA"
                $certSourcePath = $reqCert.sourcePath # Path to the .cer file

                Write-Log "Checking required certificate: Subject='$certSubject', Thumbprint='$certThumbprint', Store='$certStore'"

                $targetStorePath = "Cert:\LocalMachine\$certStore"
                if (-not (Test-CertificateExists -Thumbprint $certThumbprint -StorePath $targetStorePath)) {
                    Write-Log "Required certificate $certThumbprint ('$certSubject') not found in $targetStorePath." -Level "WARNING"
                    if ($certSourcePath -and (Test-Path $certSourcePath)) {
                        try {
                            Write-Log "Attempting to import $certThumbprint from $certSourcePath into $targetStorePath..."
                            Import-Certificate -FilePath $certSourcePath -CertStoreLocation $targetStorePath | Out-Null
                            Write-Log "Successfully imported certificate $certThumbprint into $targetStorePath."
                        }
                        catch {
                            Write-Log "Failed to import certificate $certThumbprint from $certSourcePath. Error: $($_.Exception.Message)" -Level "ERROR"
                        }
                    } else {
                        Write-Log "Source path for certificate $certThumbprint ('$certSubject') is not defined or invalid: '$certSourcePath'. Manual installation may be required." -Level "ERROR"
                    }
                } else {
                    Write-Log "Required certificate $certThumbprint ('$certSubject') already exists in $targetStorePath."
                }
            }
        } else {
            Write-Log "No requiredCertificates section found in configuration." -Level "INFO"
        }
    } else {
        Write-Log "Skipping root certificate update as UpdateRootCertificates is set to false."
    }

    # 2. Validate Existing Certificates
    if ($ValidateChain) {
        Write-Log "--- Validating Existing Certificates ---"
        $storesToValidate = $CertSettings.certificateStoresToValidate | ForEach-Object {
            # Ensure the path is compatible with Get-ChildItem -Path Cert:\
            if ($_ -notlike "Cert:\*") { "Cert:\$_" } else { $_ }
        }

        if (-not $storesToValidate) {
            Write-Log "No certificateStoresToValidate defined in configuration. Using default stores." -Level "WARNING"
            $storesToValidate = @("Cert:\LocalMachine\My", "Cert:\LocalMachine\Root", "Cert:\LocalMachine\CA")
        }

        foreach ($storePath in $storesToValidate) {
            Write-Log "Validating certificates in store: $storePath"
            if (-not (Test-Path $storePath)) {
                Write-Log "Store path $storePath does not exist. Skipping." -Level "WARNING"
                continue
            }

            $certificates = Get-ChildItem -Path $storePath -Recurse | Where-Object {$_.PSIsContainer -eq $false}
            if (-not $certificates) {
                Write-Log "No certificates found in $storePath."
                continue
            }

            foreach ($cert in $certificates) {
                Write-Log "Analyzing certificate: Subject='$($cert.Subject)', Thumbprint='$($cert.Thumbprint)', Store='$storePath'"

                # Check Key Size
                if ($cert.PublicKey.Key.KeySize -lt $MinimumKeySize) {
                    Write-Log "Key size validation FAILED for $($cert.Thumbprint): Actual $($cert.PublicKey.Key.KeySize)-bit < Minimum $MinimumKeySize-bit." -Level "WARNING"
                } else {
                    Write-Log "Key size validation PASSED for $($cert.Thumbprint): $($cert.PublicKey.Key.KeySize)-bit."
                }

                # Check Signature Algorithm
                $sigAlg = $cert.SignatureAlgorithm.FriendlyName
                if ($DisallowedSignatureAlgorithms -contains $sigAlg) {
                    Write-Log "Signature algorithm validation FAILED for $($cert.Thumbprint): '$sigAlg' is disallowed." -Level "WARNING"
                } elseif ($AllowedSignatureAlgorithms -and ($AllowedSignatureAlgorithms -notcontains $sigAlg)) {
                    Write-Log "Signature algorithm validation FAILED for $($cert.Thumbprint): '$sigAlg' is not in the allowed list." -Level "WARNING"
                } else {
                    Write-Log "Signature algorithm validation PASSED for $($cert.Thumbprint): '$sigAlg'."
                }

                # Perform Chain Validation (Basic)
                $validationParams = @{
                    AllowUntrustedRoot = -not $CertSettings.certificateValidation.checkTrustChain # Test-Certificate has -AllowUntrustedRoot
                }
                if ($CertSettings.certificateValidation.checkRevocation) {
                    # Test-Certificate default is NoCheck. Online/Offline requires network access.
                    # For simplicity, we are not setting DnsResolution, which means it might try online.
                    # $validationParams.RevocationMode = 'Online' # or 'Offline'
                    Write-Log "Revocation checking is configured but Test-Certificate's default is NoCheck. More advanced revocation checks might be needed." -Level "INFO"
                }


                $certValidationResult = $cert | Test-Certificate @validationParams
                if ($certValidationResult.IsValid) {
                    Write-Log "Chain validation PASSED for $($cert.Thumbprint)."
                } else {
                    Write-Log "Chain validation FAILED for $($cert.Thumbprint). Status: $($certValidationResult.StatusMessage) ($($certValidationResult.Status))" -Level "WARNING"
                }
            }
        }
    } else {
        Write-Log "Skipping certificate validation as ValidateChain is set to false."
    }

    Write-Log "Certificate store update and validation script completed."
}
catch {
    Write-Log "An unexpected error occurred: $($_.Exception.Message)" -Level "FATAL"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "FATAL"
    exit 1
}

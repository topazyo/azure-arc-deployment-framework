# Repair-MachineCertificates.ps1
# This script inspects machine certificates for common issues like expiry, hostname mismatch, missing private keys, and EKU.
# V1 focuses on identification. Actual repair/renewal actions are not implemented.
# TODO: Implement $AttemptRenewal functionality in a future version.
# TODO: Add more detailed EKU checks or allow specific EKUs to be passed as parameters.

Function Repair-MachineCertificates {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)]
        [string]$HostName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [int]$ExpiryWarningDays = 30,

        [Parameter(Mandatory=$false)]
        [bool]$CheckPrivateKey = $true,

        [Parameter(Mandatory=$false)]
        [ValidateSet("LocalMachine")] # Machine certs are typically LocalMachine
        [string]$StoreLocation = "LocalMachine",

        [Parameter(Mandatory=$false)]
        [string]$StoreName = "My", # Personal store

        [Parameter(Mandatory=$false)]
        [bool]$AttemptRenewal = $false, # Placeholder for future functionality

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\RepairMachineCertificates_Activity.log",

        [Parameter(Mandatory=$false)]
        [switch]$OnlyProblematic,

        [Parameter(Mandatory=$false)]
        [string]$ReportPath
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

    Write-Log "Starting Repair-MachineCertificates script."
    Write-Log "Parameters: HostName='$HostName', ExpiryWarningDays='$ExpiryWarningDays', CheckPrivateKey='$CheckPrivateKey', StoreLocation='$StoreLocation', StoreName='$StoreName', AttemptRenewal='$AttemptRenewal'."

    # --- Administrator Privilege Check ---
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Administrator privileges are required to access LocalMachine certificate store and private keys. Script cannot proceed." -Level "ERROR"
        # For robust error reporting, return an object indicating failure.
        return [PSCustomObject]@{ 
            Error = "Administrator privileges required."; 
            CertificatesProcessed = @() 
        } 
    } else {
        Write-Log "Running with Administrator privileges."
    }

    $fullStorePath = "Cert:\$StoreLocation\$StoreName"
    $certificatesToProcess = @()
    try {
        $certificatesToProcess = Get-ChildItem -Path $fullStorePath -ErrorAction Stop
        Write-Log "Found $($certificatesToProcess.Count) certificates in '$fullStorePath'."
    } catch {
        Write-Log "Failed to access certificate store '$fullStorePath'. Error: $($_.Exception.Message)" -Level "ERROR"
        return [PSCustomObject]@{ 
            Error = "Failed to access certificate store: $($_.Exception.Message)"; 
            CertificatesProcessed = @() 
        }
    }
    
    $results = [System.Collections.ArrayList]::new()
    $ServerAuthOid = "1.3.6.1.5.5.7.3.1" # Server Authentication EKU OID

    foreach ($cert in $certificatesToProcess) {
        Write-Log "Inspecting certificate: Subject='$($cert.Subject)', Thumbprint='$($cert.Thumbprint)'." -Level "DEBUG"
        $issuesFound = [System.Collections.ArrayList]::new()
        $suggestedActionsForCert = [System.Collections.ArrayList]::new()

        # 1. Expiry Check
        $expiryStatus = "Valid"
        if ($cert.NotAfter -lt (Get-Date)) {
            $expiryStatus = "Expired"
            $issuesFound.Add("Expired") | Out-Null
            $suggestedActionsForCert.Add("Certificate is EXPIRED (Expiry: $($cert.NotAfter)). Immediate renewal or replacement required.") | Out-Null
        } elseif ($cert.NotAfter -lt (Get-Date).AddDays($ExpiryWarningDays)) {
            $expiryStatus = "NearingExpiry"
            $issuesFound.Add("NearingExpiry") | Out-Null
            $suggestedActionsForCert.Add("Certificate is NEARING EXPIRY (Expiry: $($cert.NotAfter), Warning Days: $ExpiryWarningDays). Plan for renewal.") | Out-Null
        }

        # 2. Hostname Check
        $hostnameMatchStatus = "NotChecked"
        if (-not [string]::IsNullOrWhiteSpace($HostName)) {
            $hostnameMatchStatus = "Mismatch" # Assume mismatch until a match is found
            # Check Subject CN
            $cnMatch = $cert.Subject -match "CN=([^,]+)"
            if ($cnMatch -and $Matches[1].Trim() -eq $HostName) {
                $hostnameMatchStatus = "Match (SubjectCN)"
            } else {
                # Check Subject Alternative Names (SANs) - DNSName type
                $sans = $cert.Extensions | Where-Object { $_.Oid.FriendlyName -eq "Subject Alternative Name" } | ForEach-Object { $_.Format($false) }
                if ($sans) {
                    # Format() output is a single string like "DNS Name=host1.com, DNS Name=host2.com"
                    $dnsNames = ($sans -split ',') | ForEach-Object { ($_.Trim() -replace "DNS Name=","").Trim() }
                    if ($dnsNames -contains $HostName) {
                        $hostnameMatchStatus = "Match (SAN)"
                    }
                }
            }
            if ($hostnameMatchStatus -eq "Mismatch") {
                $issuesFound.Add("HostnameMismatch") | Out-Null
                $suggestedActionsForCert.Add("Hostname '$HostName' does not match certificate Subject CN ('$($Matches[1].Trim())') or its SAN DNS names ('$($dnsNames -join "; ")').") | Out-Null
            }
        } else { $hostnameMatchStatus = "NotChecked (No HostName Provided)" }


        # 3. Private Key Check
        $privateKeyStatus = "NotChecked"
        if ($CheckPrivateKey) {
            if ($cert.HasPrivateKey) {
                $privateKeyStatus = "Present"
            } else {
                $privateKeyStatus = "Missing"
                $issuesFound.Add("MissingPrivateKey") | Out-Null
                $suggestedActionsForCert.Add("Certificate is missing its associated private key.") | Out-Null
            }
        }

        # 4. EKU Check (Basic for Server Authentication)
        $ekuStatus = "NotApplicable" # Or "ContainsServerAuth", "LacksServerAuth"
        $ekus = $cert.Extensions | Where-Object { $_.Oid.FriendlyName -eq "Enhanced Key Usage" }
        if ($ekus) {
            # The OidValueList property contains the OIDs.
            # For .NET objects directly, EnhancedKeyUsageList has Oid objects with Value property.
            $hasServerAuth = $false
            if ($cert.Extensions.EnhancedKeyUsageList) { # More direct way if available
                 foreach($ekuOid in $cert.Extensions.EnhancedKeyUsageList.Oids){
                     if($ekuOid.Value -eq $ServerAuthOid){ $hasServerAuth = $true; break}
                 }
            } else { # Fallback parsing if EnhancedKeyUsageList not populated directly
                $ekuString = $ekus[0].Format($false) # Example: "Server Authentication (1.3.6.1.5.5.7.3.1), Client Authentication (1.3.6.1.5.5.7.3.2)"
                 if ($ekuString -match [regex]::Escape($ServerAuthOid)) { $hasServerAuth = $true }
            }

            if ($hasServerAuth) {
                $ekuStatus = "ContainsServerAuth"
            } else {
                $ekuStatus = "LacksServerAuth"
                $issuesFound.Add("LacksServerAuthEKU") | Out-Null
                $suggestedActionsForCert.Add("Certificate EKU does not explicitly include Server Authentication ('$ServerAuthOid'). May not be suitable for server roles like HTTPS.") | Out-Null
            }
        } else { $ekuStatus = "NoEKUPresent" }


        # Overall Status
        $overallCertStatus = if ($issuesFound.Count -gt 0) { "Problematic" } else { "Valid" }
        
        $results.Add([PSCustomObject]@{
            Subject             = $cert.Subject
            Thumbprint          = $cert.Thumbprint
            NotAfter            = $cert.NotAfter
            NotBefore           = $cert.NotBefore # Added for completeness
            HostNameMatchStatus = $hostnameMatchStatus
            PrivateKeyStatus    = $privateKeyStatus
            ExpiryStatus        = $expiryStatus
            EKUStatus           = $ekuStatus
            IdentifiedIssues    = $issuesFound # Array
            OverallCertStatus   = $overallCertStatus
            SuggestedActions    = $suggestedActionsForCert # Array
            StorePath           = $fullStorePath
        }) | Out-Null

        if ($AttemptRenewal -and $overallCertStatus -eq "Problematic") {
            Write-Log "RENEWAL_PLACEHOLDER: Automatic renewal attempt for certificate '$($cert.Subject)' (Thumbprint: $($cert.Thumbprint)) would occur here if implemented." -Level "INFO"
            # Future: Call renewal logic
        }
    }
    
    $filteredResults = if ($OnlyProblematic) { $results | Where-Object { $_.OverallCertStatus -eq "Problematic" } } else { $results }

    $summary = [PSCustomObject]@{
        Total               = $results.Count
        Problematic         = ($results | Where-Object { $_.OverallCertStatus -eq "Problematic" }).Count
        Expired             = ($results | Where-Object { $_.ExpiryStatus -eq "Expired" }).Count
        NearingExpiry       = ($results | Where-Object { $_.ExpiryStatus -eq "NearingExpiry" }).Count
        MissingPrivateKey   = ($results | Where-Object { $_.PrivateKeyStatus -eq "Missing" }).Count
        HostnameMismatch    = ($results | Where-Object { $_.IdentifiedIssues -contains "HostnameMismatch" }).Count
        LacksServerAuthEKU  = ($results | Where-Object { $_.IdentifiedIssues -contains "LacksServerAuthEKU" }).Count
    }

    if (-not [string]::IsNullOrWhiteSpace($ReportPath)) {
        try {
            $reportPayload = [PSCustomObject]@{ Summary = $summary; Certificates = $filteredResults }
            $reportPayload | ConvertTo-Json -Depth 5 | Out-File -FilePath $ReportPath -Encoding UTF8 -Force -ErrorAction Stop
            Write-Log "Report written to '$ReportPath'."
        } catch {
            Write-Log "Failed to write report to '$ReportPath': $($_.Exception.Message)" -Level "WARNING"
        }
    }

    Write-Log "Repair-MachineCertificates script finished. Inspected $($certificatesToProcess.Count) certificates. Problematic=$($summary.Problematic)."
    return [PSCustomObject]@{ Summary = $summary; Certificates = $filteredResults }
}

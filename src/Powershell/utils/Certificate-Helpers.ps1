function Test-CertificateRequirements {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [switch]$Remediate
    )

    $results = @{
        ServerName = $ServerName
        StartTime = Get-Date
        Checks = @()
        Success = $true
        Remediation = @()
    }

    try {
        # Check Root Certificates
        $rootCerts = Test-RootCertificates -ServerName $ServerName
        $results.Checks += @{
            Type = "RootCertificates"
            Status = $rootCerts.Valid
            Details = $rootCerts.Details
            Required = $true
        }

        # Check Intermediate Certificates
        $intermediateCerts = Test-IntermediateCertificates -ServerName $ServerName
        $results.Checks += @{
            Type = "IntermediateCertificates"
            Status = $intermediateCerts.Valid
            Details = $intermediateCerts.Details
            Required = $true
        }

        # Check Machine Certificates
        $machineCerts = Test-MachineCertificates -ServerName $ServerName
        $results.Checks += @{
            Type = "MachineCertificates"
            Status = $machineCerts.Valid
            Details = $machineCerts.Details
            Required = $true
        }

        # Check Certificate Chain
        $chainValidation = Test-CertificateChain -ServerName $ServerName
        $results.Checks += @{
            Type = "CertificateChain"
            Status = $chainValidation.Valid
            Details = $chainValidation.Details
            Required = $true
        }

        # Remediate if requested
        if ($Remediate) {
            foreach ($check in $results.Checks | Where-Object { -not $_.Status }) {
                $remediation = Switch ($check.Type) {
                    "RootCertificates" { Install-RootCertificates -ServerName $ServerName }
                    "IntermediateCertificates" { Install-IntermediateCertificates -ServerName $ServerName }
                    "MachineCertificates" { Repair-MachineCertificates -ServerName $ServerName }
                    "CertificateChain" { Repair-CertificateChain -ServerName $ServerName }
                }

                $results.Remediation += @{
                    Type = $check.Type
                    Success = $remediation.Success
                    Details = $remediation.Details
                }
            }
        }

        # Update overall success status
        $results.Success = ($results.Checks | Where-Object { $_.Required -and -not $_.Status }).Count -eq 0
    }
    catch {
        $results.Success = $false
        $results.Error = $_.Exception.Message
        Write-Error "Certificate validation failed: $_"
    }
    finally {
        $results.EndTime = Get-Date
        $results.Duration = $results.EndTime - $results.StartTime
    }

    return [PSCustomObject]$results
}

function Test-RootCertificates {
    [CmdletBinding()]
    param ([string]$ServerName)
    
    try {
        $requiredRoots = @(
            "Baltimore CyberTrust Root",
            "DigiCert Global Root CA",
            "Microsoft Root Certificate Authority 2011"
        )

        $results = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            param ($roots)
            
            $certs = Get-ChildItem -Path 'Cert:\LocalMachine\Root' | 
                Where-Object { $_.Subject -match ($roots -join '|') }
            
            return @{
                Found = $certs | Select-Object -Property Subject, Thumbprint, NotAfter
                Missing = $roots | Where-Object { 
                    $root = $_
                    -not ($certs | Where-Object { $_.Subject -match $root })
                }
            }
        } -ArgumentList $requiredRoots

        return @{
            Valid = $results.Missing.Count -eq 0
            Details = @{
                FoundCertificates = $results.Found
                MissingCertificates = $results.Missing
            }
        }
    }
    catch {
        Write-Error "Root certificate validation failed: $_"
        return @{
            Valid = $false
            Details = $_.Exception.Message
        }
    }
}

function Test-CertificateChain {
    [CmdletBinding()]
    param ([string]$ServerName)
    
    try {
        $results = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            $certs = Get-ChildItem -Path 'Cert:\LocalMachine\My' | 
                Where-Object { $_.Subject -match 'Azure|Arc|Monitor' }
            
            $chainResults = @()
            foreach ($cert in $certs) {
                $chain = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Chain
                $chain.Build($cert) | Out-Null
                
                $chainElements = $chain.ChainElements | ForEach-Object {
                    @{
                        Certificate = $_.Certificate.Subject
                        Status = $_.Status
                        StatusInformation = $_.StatusInformation
                    }
                }
                
                $chainResults += @{
                    Certificate = $cert.Subject
                    ChainValid = $chain.ChainStatus.Length -eq 0
                    ChainElements = $chainElements
                    Errors = $chain.ChainStatus | ForEach-Object { $_.StatusInformation }
                }
                
                $chain.Dispose()
            }
            
            return $chainResults
        }

        return @{
            Valid = ($results | Where-Object { -not $_.ChainValid }).Count -eq 0
            Details = $results
        }
    }
    catch {
        Write-Error "Certificate chain validation failed: $_"
        return @{
            Valid = $false
            Details = $_.Exception.Message
        }
    }
}
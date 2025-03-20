function Test-SecurityValidation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [ValidateSet('Basic', 'Enhanced', 'Comprehensive')]
        [string]$ValidationLevel = 'Enhanced',
        [Parameter()]
        [string]$BaselinePath = ".\Config\security-baseline.json",
        [Parameter()]
        [switch]$Remediate
    )

    begin {
        $securityResults = @{
            ServerName = $ServerName
            StartTime = Get-Date
            ValidationLevel = $ValidationLevel
            Checks = @()
            Status = "Unknown"
            Remediation = @()
        }

        # Load security baseline
        try {
            if (Test-Path $BaselinePath) {
                $baseline = Get-Content $BaselinePath | ConvertFrom-Json
            }
            else {
                Write-Warning "Security baseline not found at $BaselinePath. Using default baseline."
                $baseline = Get-DefaultSecurityBaseline
            }
        }
        catch {
            Write-Error "Failed to load security baseline: $_"
            return
        }

        Write-Log -Message "Starting security validation for $ServerName" -Level Information
    }

    process {
        try {
            # TLS Configuration
            $tlsCheck = Test-TLSConfiguration -ServerName $ServerName
            $securityResults.Checks += @{
                Category = "TLS"
                Status = $tlsCheck.Success
                Details = $tlsCheck.Details
                Severity = "Critical"
                Baseline = $baseline.TLS
                Remediation = $tlsCheck.Remediation
            }

            # Certificate Validation
            $certCheck = Test-CertificateValidation -ServerName $ServerName
            $securityResults.Checks += @{
                Category = "Certificates"
                Status = $certCheck.Success
                Details = $certCheck.Details
                Severity = "Critical"
                Baseline = $baseline.Certificates
                Remediation = $certCheck.Remediation
            }

            # Firewall Configuration
            $firewallCheck = Test-FirewallConfiguration -ServerName $ServerName
            $securityResults.Checks += @{
                Category = "Firewall"
                Status = $firewallCheck.Success
                Details = $firewallCheck.Details
                Severity = "High"
                Baseline = $baseline.Firewall
                Remediation = $firewallCheck.Remediation
            }

            # Service Account Security
            $serviceCheck = Test-ServiceAccountSecurity -ServerName $ServerName
            $securityResults.Checks += @{
                Category = "ServiceAccounts"
                Status = $serviceCheck.Success
                Details = $serviceCheck.Details
                Severity = "High"
                Baseline = $baseline.ServiceAccounts
                Remediation = $serviceCheck.Remediation
            }

            # Enhanced Security Checks
            if ($ValidationLevel -in 'Enhanced', 'Comprehensive') {
                # Windows Updates
                $updateCheck = Test-WindowsUpdateStatus -ServerName $ServerName
                $securityResults.Checks += @{
                    Category = "WindowsUpdates"
                    Status = $updateCheck.Success
                    Details = $updateCheck.Details
                    Severity = "Medium"
                    Baseline = $baseline.WindowsUpdates
                    Remediation = $updateCheck.Remediation
                }

                # Antivirus Status
                $avCheck = Test-AntivirusStatus -ServerName $ServerName
                $securityResults.Checks += @{
                    Category = "Antivirus"
                    Status = $avCheck.Success
                    Details = $avCheck.Details
                    Severity = "High"
                    Baseline = $baseline.Antivirus
                    Remediation = $avCheck.Remediation
                }

                # Local Security Policy
                $policyCheck = Test-LocalSecurityPolicy -ServerName $ServerName
                $securityResults.Checks += @{
                    Category = "SecurityPolicy"
                    Status = $policyCheck.Success
                    Details = $policyCheck.Details
                    Severity = "High"
                    Baseline = $baseline.SecurityPolicy
                    Remediation = $policyCheck.Remediation
                }
            }

            # Comprehensive Security Checks
            if ($ValidationLevel -eq 'Comprehensive') {
                # Audit Policy
                $auditCheck = Test-AuditPolicy -ServerName $ServerName
                $securityResults.Checks += @{
                    Category = "AuditPolicy"
                    Status = $auditCheck.Success
                    Details = $auditCheck.Details
                    Severity = "Medium"
                    Baseline = $baseline.AuditPolicy
                    Remediation = $auditCheck.Remediation
                }

                # Registry Security
                $registryCheck = Test-RegistrySecurity -ServerName $ServerName
                $securityResults.Checks += @{
                    Category = "Registry"
                    Status = $registryCheck.Success
                    Details = $registryCheck.Details
                    Severity = "Medium"
                    Baseline = $baseline.Registry
                    Remediation = $registryCheck.Remediation
                }

                # User Rights Assignment
                $rightsCheck = Test-UserRightsAssignment -ServerName $ServerName
                $securityResults.Checks += @{
                    Category = "UserRights"
                    Status = $rightsCheck.Success
                    Details = $rightsCheck.Details
                    Severity = "High"
                    Baseline = $baseline.UserRights
                    Remediation = $rightsCheck.Remediation
                }

                # Restricted Software
                $softwareCheck = Test-RestrictedSoftware -ServerName $ServerName
                $securityResults.Checks += @{
                    Category = "RestrictedSoftware"
                    Status = $softwareCheck.Success
                    Details = $softwareCheck.Details
                    Severity = "Medium"
                    Baseline = $baseline.RestrictedSoftware
                    Remediation = $softwareCheck.Remediation
                }
            }

            # Remediate if requested
            if ($Remediate) {
                foreach ($check in $securityResults.Checks | Where-Object { -not $_.Status }) {
                    Write-Log -Message "Attempting remediation for $($check.Category)" -Level Warning
                    
                    $remediationResult = switch ($check.Category) {
                        "TLS" { Set-TLSConfiguration -ServerName $ServerName -Configuration $check.Baseline }
                        "Certificates" { Repair-CertificateIssues -ServerName $ServerName -Issues $check.Details }
                        "Firewall" { Set-FirewallRules -ServerName $ServerName -Rules $check.Baseline.Rules }
                        "ServiceAccounts" { Set-ServiceAccountSecurity -ServerName $ServerName -Configuration $check.Baseline }
                        "WindowsUpdates" { Install-RequiredUpdates -ServerName $ServerName }
                        "Antivirus" { Enable-AntivirusProtection -ServerName $ServerName }
                        "SecurityPolicy" { Set-LocalSecurityPolicy -ServerName $ServerName -Policies $check.Baseline.Policies }
                        "AuditPolicy" { Set-AuditPolicy -ServerName $ServerName -Policies $check.Baseline.Policies }
                        "Registry" { Set-RegistrySecurity -ServerName $ServerName -Settings $check.Baseline.Settings }
                        "UserRights" { Set-UserRightsAssignment -ServerName $ServerName -Rights $check.Baseline.Rights }
                        "RestrictedSoftware" { Remove-RestrictedSoftware -ServerName $ServerName -Software $check.Baseline.Software }
                        default { $null }
                    }

                    if ($remediationResult) {
                        $securityResults.Remediation += @{
                            Category = $check.Category
                            Success = $remediationResult.Success
                            Details = $remediationResult.Details
                            Timestamp = Get-Date
                        }
                    }
                }

                # Re-validate after remediation
                $revalidation = Test-SecurityValidation -ServerName $ServerName -ValidationLevel $ValidationLevel
                $securityResults.RevalidationStatus = $revalidation.Status
                $securityResults.RevalidationChecks = $revalidation.Checks
            }

            # Calculate Overall Status
            $criticalChecks = $securityResults.Checks | Where-Object { $_.Severity -in 'Critical', 'High' }
            $securityResults.Status = if (
                ($criticalChecks | Where-Object { -not $_.Status }).Count -eq 0
            ) {
                "Success"
            }
            else {
                "Failed"
            }

            # Calculate Security Score
            $securityResults.SecurityScore = Get-SecurityScore -Checks $securityResults.Checks

            Write-Log -Message "Security validation completed with status: $($securityResults.Status)" -Level Information
        }
        catch {
            $securityResults.Status = "Error"
            $securityResults.Error = $_.Exception.Message
            Write-Error "Security validation failed: $_"
        }
    }

    end {
        $securityResults.EndTime = Get-Date
        $securityResults.Duration = $securityResults.EndTime - $securityResults.StartTime
        return [PSCustomObject]$securityResults
    }
}

function Test-TLSConfiguration {
    [CmdletBinding()]
    param ([string]$ServerName)

    $results = @{
        Success = $false
        Details = @()
        Remediation = @()
    }

    try {
        # Check TLS 1.2 Registry Settings
        $tlsSettings = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            $paths = @(
                "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client",
                "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server"
            )
            
            $results = @{}
            foreach ($path in $paths) {
                if (Test-Path $path) {
                    $enabled = (Get-ItemProperty -Path $path -Name "Enabled" -ErrorAction SilentlyContinue).Enabled
                    $results[$path] = $enabled
                }
                else {
                    $results[$path] = "Missing"
                }
            }

            # Check for disabled protocols
            $disabledProtocols = @(
                "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0",
                "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1",
                "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\SSL 2.0",
                "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\SSL 3.0"
            )

            foreach ($protocol in $disabledProtocols) {
                $clientPath = "$protocol\Client"
                $serverPath = "$protocol\Server"
                
                if (Test-Path $clientPath) {
                    $enabled = (Get-ItemProperty -Path $clientPath -Name "Enabled" -ErrorAction SilentlyContinue).Enabled
                    $results[$clientPath] = $enabled
                }
                
                if (Test-Path $serverPath) {
                    $enabled = (Get-ItemProperty -Path $serverPath -Name "Enabled" -ErrorAction SilentlyContinue).Enabled
                    $results[$serverPath] = $enabled
                }
            }

            # Check .NET Framework settings
            $netFrameworkPaths = @(
                "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319",
                "HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319"
            )

            foreach ($path in $netFrameworkPaths) {
                if (Test-Path $path) {
                    $systemDefaultTlsVersions = (Get-ItemProperty -Path $path -Name "SystemDefaultTlsVersions" -ErrorAction SilentlyContinue).SystemDefaultTlsVersions
                    $schUseStrongCrypto = (Get-ItemProperty -Path $path -Name "SchUseStrongCrypto" -ErrorAction SilentlyContinue).SchUseStrongCrypto
                    
                    $results["$path\SystemDefaultTlsVersions"] = $systemDefaultTlsVersions
                    $results["$path\SchUseStrongCrypto"] = $schUseStrongCrypto
                }
            }

            return $results
        }

        # Validate TLS 1.2 is enabled
        $tls12ClientEnabled = $tlsSettings["HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client"] -eq 1
        $tls12ServerEnabled = $tlsSettings["HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server"] -eq 1

        if (-not $tls12ClientEnabled) {
            $results.Details += "TLS 1.2 Client is not enabled"
            $results.Remediation += "Enable TLS 1.2 Client in registry"
        }

        if (-not $tls12ServerEnabled) {
            $results.Details += "TLS 1.2 Server is not enabled"
            $results.Remediation += "Enable TLS 1.2 Server in registry"
        }

        # Validate older protocols are disabled
        $oldProtocols = @(
            "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Client",
            "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Server",
            "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Client",
            "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Server",
            "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\SSL 2.0\Client",
            "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\SSL 2.0\Server",
            "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\SSL 3.0\Client",
            "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\SSL 3.0\Server"
        )

        foreach ($protocol in $oldProtocols) {
            if ($tlsSettings.ContainsKey($protocol) -and $tlsSettings[$protocol] -ne 0) {
                $protocolName = $protocol -replace "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\SecurityProviders\\SCHANNEL\\Protocols\\", "" -replace "\\(Client|Server)", ""
                $endpointType = if ($protocol -match "Client$") { "Client" } else { "Server" }
                
                $results.Details += "$protocolName $endpointType is not disabled"
                $results.Remediation += "Disable $protocolName $endpointType in registry"
            }
        }

        # Validate .NET Framework settings
        $netFrameworkPaths = @(
            "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319"
        )

        foreach ($path in $netFrameworkPaths) {
            $systemDefaultTlsVersions = $tlsSettings["$path\SystemDefaultTlsVersions"]
            $schUseStrongCrypto = $tlsSettings["$path\SchUseStrongCrypto"]
            
            if ($systemDefaultTlsVersions -ne 1) {
                $pathName = $path -replace "HKLM:\\", ""
                $results.Details += "SystemDefaultTlsVersions not enabled in $pathName"
                $results.Remediation += "Enable SystemDefaultTlsVersions in $pathName"
            }
            
            if ($schUseStrongCrypto -ne 1) {
                $pathName = $path -replace "HKLM:\\", ""
                $results.Details += "SchUseStrongCrypto not enabled in $pathName"
                $results.Remediation += "Enable SchUseStrongCrypto in $pathName"
            }
        }

        # Determine overall success
        $results.Success = $results.Details.Count -eq 0
    }
    catch {
        $results.Success = $false
        $results.Details += "Error checking TLS configuration: $($_.Exception.Message)"
        $results.Remediation += "Manually verify TLS configuration"
    }

    return $results
}

function Test-CertificateValidation {
    [CmdletBinding()]
    param ([string]$ServerName)

    $results = @{
        Success = $false
        Details = @()
        Remediation = @()
    }

    try {
        # Check Machine Certificates
        $certificates = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            $certs = @{
                MachineCerts = Get-ChildItem -Path 'Cert:\LocalMachine\My' | 
                    Where-Object { 
                        $_.Subject -match 'Azure|Arc|Monitor' -or 
                        $_.Issuer -match 'Microsoft|Azure' 
                    } | 
                    Select-Object -Property Subject, Thumbprint, NotBefore, NotAfter, Issuer, HasPrivateKey
                
                RootCerts = Get-ChildItem -Path 'Cert:\LocalMachine\Root' | 
                    Where-Object { 
                        $_.Subject -match 'Microsoft|DigiCert|Baltimore|Verisign' 
                    } | 
                    Select-Object -Property Subject, Thumbprint, NotBefore, NotAfter, Issuer
                
                IntermediateCerts = Get-ChildItem -Path 'Cert:\LocalMachine\CA' | 
                    Where-Object { 
                        $_.Subject -match 'Microsoft|DigiCert|Baltimore|Verisign' 
                    } | 
                    Select-Object -Property Subject, Thumbprint, NotBefore, NotAfter, Issuer
            }
            
            return $certs
        }

        # Check for expired certificates
        $now = Get-Date
        $expirationWarningDays = 30

        # Check machine certificates
        foreach ($cert in $certificates.MachineCerts) {
            # Check expiration
            if ($cert.NotAfter -lt $now) {
                $results.Details += "Certificate expired: $($cert.Subject) (Thumbprint: $($cert.Thumbprint))"
                $results.Remediation += "Renew expired certificate: $($cert.Subject)"
            }
            elseif ($cert.NotAfter -lt $now.AddDays($expirationWarningDays)) {
                $daysUntilExpiration = ($cert.NotAfter - $now).Days
                $results.Details += "Certificate expiring soon: $($cert.Subject) (Thumbprint: $($cert.Thumbprint), Days remaining: $daysUntilExpiration)"
                $results.Remediation += "Plan renewal for certificate: $($cert.Subject)"
            }

            # Check private key
            if (-not $cert.HasPrivateKey) {
                $results.Details += "Certificate missing private key: $($cert.Subject) (Thumbprint: $($cert.Thumbprint))"
                $results.Remediation += "Restore private key for certificate: $($cert.Subject)"
            }
        }

        # Check for required root certificates
        $requiredRootCerts = @(
            "CN=Microsoft Root Certificate Authority 2011",
            "CN=Baltimore CyberTrust Root",
            "CN=DigiCert Global Root CA"
        )

        foreach ($requiredCert in $requiredRootCerts) {
            $found = $false
            foreach ($cert in $certificates.RootCerts) {
                if ($cert.Subject -match $requiredCert) {
                    $found = $true
                    break
                }
            }

            if (-not $found) {
                $results.Details += "Required root certificate missing: $requiredCert"
                $results.Remediation += "Install required root certificate: $requiredCert"
            }
        }

        # Check certificate chain
        $chainCheck = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            $arcCerts = Get-ChildItem -Path 'Cert:\LocalMachine\My' | 
                Where-Object { $_.Subject -match 'Azure|Arc|Monitor' }
            
            $chainResults = @()
            foreach ($cert in $arcCerts) {
                $chain = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Chain
                $chain.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::Online
                $chain.ChainPolicy.RevocationFlag = [System.Security.Cryptography.X509Certificates.X509RevocationFlag]::EntireChain
                
                $isValid = $chain.Build($cert)
                $chainStatus = $chain.ChainStatus | ForEach-Object { $_.Status }
                
                $chainResults += @{
                    Subject = $cert.Subject
                    IsValid = $isValid
                    ChainStatus = $chainStatus
                }
            }
            
            return $chainResults
        }

        foreach ($chainResult in $chainCheck) {
            if (-not $chainResult.IsValid) {
                $results.Details += "Certificate chain validation failed for: $($chainResult.Subject)"
                $results.Remediation += "Fix certificate chain for: $($chainResult.Subject)"
            }
        }

        # Determine overall success
        $results.Success = $results.Details.Count -eq 0
    }
    catch {
        $results.Success = $false
        $results.Details += "Error checking certificates: $($_.Exception.Message)"
        $results.Remediation += "Manually verify certificate configuration"
    }

    return $results
}

function Test-FirewallConfiguration {
    [CmdletBinding()]
    param ([string]$ServerName)

    $results = @{
        Success = $false
        Details = @()
        Remediation = @()
    }

    try {
        # Check firewall status
        $firewallStatus = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            $fw = New-Object -ComObject HNetCfg.FwPolicy2
            $profiles = @{
                Domain = $fw.FirewallEnabled($fw.CurrentProfileTypes -band 1)
                Private = $fw.FirewallEnabled($fw.CurrentProfileTypes -band 2)
                Public = $fw.FirewallEnabled($fw.CurrentProfileTypes -band 4)
            }
            
            # Get Arc-related rules
            $arcRules = Get-NetFirewallRule | Where-Object { 
                $_.DisplayName -like "*Azure*" -or 
                $_.DisplayName -like "*Arc*" -or 
                $_.DisplayName -like "*Monitor*" 
            } | Select-Object -Property DisplayName, Enabled, Direction, Action

            return @{
                Profiles = $profiles
                ArcRules = $arcRules
            }
        }

        # Check if firewall is enabled
        foreach ($profile in $firewallStatus.Profiles.GetEnumerator()) {
            if (-not $profile.Value) {
                $results.Details += "Firewall is disabled for $($profile.Key) profile"
                $results.Remediation += "Enable firewall for $($profile.Key) profile"
            }
        }

        # Required outbound rules
        $requiredOutboundRules = @(
            "*Azure Arc*",
            "*Azure Monitor*",
            "*Azure Connected Machine*"
        )

        # Check for required outbound rules
        foreach ($rule in $requiredOutboundRules) {
            $found = $false
            foreach ($arcRule in $firewallStatus.ArcRules) {
                if ($arcRule.DisplayName -like $rule -and 
                    $arcRule.Direction -eq "Outbound" -and 
                    $arcRule.Action -eq "Allow" -and 
                    $arcRule.Enabled) {
                    $found = $true
                    break
                }
            }

            if (-not $found) {
                $results.Details += "Required outbound rule missing or disabled: $rule"
                $results.Remediation += "Create or enable outbound rule: $rule"
            }
        }

        # Check required ports
        $requiredPorts = @(
            @{ Port = 443; Protocol = "TCP"; Description = "HTTPS" },
            @{ Port = 80; Protocol = "TCP"; Description = "HTTP" }
        )

        $portCheck = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            param ($ports)
            
            $results = @()
            foreach ($port in $ports) {
                $rules = Get-NetFirewallRule -Direction Outbound -Action Allow -Enabled True |
                    Get-NetFirewallPortFilter | 
                    Where-Object { $_.RemotePort -contains $port.Port -or $_.RemotePort -contains "Any" } |
                    Where-Object { $_.Protocol -eq $port.Protocol }
                
                $results += @{
                    Port = $port.Port
                    Protocol = $port.Protocol
                    Description = $port.Description
                    HasRule = $rules.Count -gt 0
                }
            }
            
            return $results
        } -ArgumentList $requiredPorts

        foreach ($port in $portCheck) {
            if (-not $port.HasRule) {
                $results.Details += "Required outbound port rule missing: $($port.Port)/$($port.Protocol) ($($port.Description))"
                $results.Remediation += "Create outbound rule for port $($port.Port)/$($port.Protocol)"
            }
        }

        # Determine overall success
        $results.Success = $results.Details.Count -eq 0
    }
    catch {
        $results.Success = $false
        $results.Details += "Error checking firewall configuration: $($_.Exception.Message)"
        $results.Remediation += "Manually verify firewall configuration"
    }

    return $results
}

function Test-ServiceAccountSecurity {
    [CmdletBinding()]
    param ([string]$ServerName)

    $results = @{
        Success = $false
        Details = @()
        Remediation = @()
    }

    try {
        # Check service accounts
        $serviceAccounts = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            $services = @(
                "himds",
                "GCArcService",
                "AzureMonitorAgent"
            )
            
            $results = @()
            foreach ($service in $services) {
                $svc = Get-WmiObject -Class Win32_Service -Filter "Name='$service'" -ErrorAction SilentlyContinue
                if ($svc) {
                    $results += @{
                        Name = $service
                        StartName = $svc.StartName
                        StartMode = $svc.StartMode
                        State = $svc.State
                    }
                }
            }
            
            return $results
        }

        # Check service account privileges
        foreach ($service in $serviceAccounts) {
            # Check for services running as LocalSystem
            if ($service.StartName -eq "LocalSystem") {
                $results.Details += "Service $($service.Name) is running as LocalSystem"
                $results.Remediation += "Consider using a more restricted service account for $($service.Name)"
            }

            # Check for disabled services
            if ($service.StartMode -eq "Disabled") {
                $results.Details += "Service $($service.Name) is disabled"
                $results.Remediation += "Enable service $($service.Name)"
            }

            # Check for stopped services that should be running
            if ($service.State -ne "Running" -and $service.StartMode -ne "Disabled") {
                $results.Details += "Service $($service.Name) is not running"
                $results.Remediation += "Start service $($service.Name)"
            }
        }

        # Check service permissions
        $servicePermissions = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            $services = @(
                "himds",
                "GCArcService",
                "AzureMonitorAgent"
            )
            
            $results = @()
            foreach ($service in $services) {
                $svc = Get-WmiObject -Class Win32_Service -Filter "Name='$service'" -ErrorAction SilentlyContinue
                if ($svc) {
                    $sd = $svc.GetSecurityDescriptor().Descriptor
                    
                    $results += @{
                        Name = $service
                        DACL = $sd.DACL | ForEach-Object {
                            @{
                                Trustee = $_.Trustee.Name
                                AccessMask = $_.AccessMask
                                AceType = $_.AceType
                            }
                        }
                    }
                }
            }
            
            return $results
        }

        # Check for overly permissive service permissions
        foreach ($service in $servicePermissions) {
            foreach ($ace in $service.DACL) {
                # Check for "Everyone" or "Users" with modify permissions
                if (($ace.Trustee -eq "Everyone" -or $ace.Trustee -eq "Users") -and 
                    ($ace.AccessMask -band 0x40000) -eq 0x40000) {
                    $results.Details += "Service $($service.Name) has overly permissive ACL for $($ace.Trustee)"
                    $results.Remediation += "Restrict permissions for $($ace.Trustee) on service $($service.Name)"
                }
            }
        }

        # Determine overall success
        $results.Success = $results.Details.Count -eq 0
    }
    catch {
        $results.Success = $false
        $results.Details += "Error checking service account security: $($_.Exception.Message)"
        $results.Remediation += "Manually verify service account configuration"
    }

    return $results
}

function Get-SecurityScore {
    [CmdletBinding()]
    param ([array]$Checks)

    # Define severity weights
    $weights = @{
        "Critical" = 40
        "High" = 30
        "Medium" = 20
        "Low" = 10
    }

    # Calculate maximum possible score
    $maxScore = 0
    foreach ($check in $Checks) {
        $weight = $weights[$check.Severity]
        $maxScore += $weight
    }

    # Calculate actual score
    $actualScore = 0
    foreach ($check in $Checks) {
        $weight = $weights[$check.Severity]
        if ($check.Status) {
            $actualScore += $weight
        }
    }

    # Calculate percentage
    $percentage = if ($maxScore -gt 0) { ($actualScore / $maxScore) * 100 } else { 0 }
    
    return [math]::Round($percentage, 2)
}

function Get-DefaultSecurityBaseline {
    return @{
        TLS = @{
            RequireTLS12 = $true
            DisableOldProtocols = $true
            RequireStrongCrypto = $true
        }
        Certificates = @{
            RequiredRoots = @(
                "CN=Microsoft Root Certificate Authority 2011",
                "CN=Baltimore CyberTrust Root",
                "CN=DigiCert Global Root CA"
            )
            MinimumKeySize = 2048
            MaximumValidityDays = 365
        }
        Firewall = @{
            EnabledProfiles = @("Domain", "Private", "Public")
            Rules = @(
                @{
                    DisplayName = "Azure Arc - HTTPS"
                    Direction = "Outbound"
                    Protocol = "TCP"
                    Port = 443
                    Action = "Allow"
                },
                @{
                    DisplayName = "Azure Monitor - HTTPS"
                    Direction = "Outbound"
                    Protocol = "TCP"
                    Port = 443
                    Action = "Allow"
                }
            )
        }
        ServiceAccounts = @{
            PreferredAccount = "NT SERVICE\AzureConnectedMachineAgent"
            StartupType = "Automatic"
            RequiredState = "Running"
        }
        WindowsUpdates = @{
            MaximumPendingUpdates = 5
            MaximumDaysSinceLastUpdate = 30
            CriticalUpdatesRequired = $true
        }
        Antivirus = @{
            Required = $true
            RealtimeProtection = $true
            MaximumDaysSinceLastScan = 7
        }
        SecurityPolicy = @{
            Policies = @{
                "PasswordComplexity" = 1
                "LockoutThreshold" = 5
                "AuditLogonEvents" = 3
            }
        }
        AuditPolicy = @{
            Policies = @{
                "Account Logon" = "Success, Failure"
                "Account Management" = "Success, Failure"
                "System" = "Success, Failure"
            }
        }
        Registry = @{
            Settings = @{
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\EnableLUA" = 1
                "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa\LmCompatibilityLevel" = 5
            }
        }
        UserRights = @{
            Rights = @{
                "SeBackupPrivilege" = @("Administrators")
                "SeRestorePrivilege" = @("Administrators")
                "SeTakeOwnershipPrivilege" = @("Administrators")
            }
        }
        RestrictedSoftware = @{
            Software = @(
                "Unauthorized Remote Access Tools",
                "Peer-to-Peer File Sharing"
            )
        }
    }
}
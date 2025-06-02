# tests/Powershell/unit/Security.Tests.ps1
using namespace System.Management.Automation

# Ensure Pester is available. Adjust MinimumVersion as needed for your environment.
Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

Describe 'Set-TLSConfiguration.ps1 Tests' {
    # Path to the script being tested. Assuming this test script is in tests/Powershell/unit/
    $TestScriptRoot = (Split-Path $MyInvocation.MyCommand.Path -Parent)
    $ScriptPath = Join-Path $TestScriptRoot '..\..\..\src\Powershell\security\Set-TLSConfiguration.ps1'
    
    # Mocked JSON content
    $MockTlsSettings = @{
        tlsSettings = @{
            protocols = @{
                "TLS 1.0" = @{ enabled = $false }
                "TLS 1.1" = @{ enabled = $false }
                "TLS 1.2" = @{ enabled = $true }
                "TLS 1.3" = @{ enabled = $true }
            }
            cipherSuites = @{
                allowed = @(
                    "TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384",
                    "TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256"
                )
                disallowed = @( 
                    "TLS_RSA_WITH_AES_256_CBC_SHA256" 
                ) 
            }
            dotNetSettings = @{
                schUseStrongCrypto = $true
                systemDefaultTlsVersions = $true
            }
        }
    }
    $MockJsonContentForTls = ConvertTo-Json -InputObject $MockTlsSettings -Depth 5 

    $Global:MockedRegistryExportCommand = $null 
    $Global:MockedNetshExportCommand = $null 
    $Global:AuditpolCommands = [System.Collections.Generic.List[string]]::new() # For Set-AuditPolicies
    $Global:MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new()

    BeforeEach { 
        $Global:MockedRegistryExportCommand = $null
        # $Global:MockedWriteLogMessages.Clear() # Cleared in each Describe's BeforeEach

        Mock Get-Content { param($Path) Write-Verbose "Mock Get-Content for TLS called for $Path"; return $MockJsonContentForTls } -ModuleName $ScriptPath -Verifiable
        Mock Test-Path { param($Path) Write-Verbose "Mock Test-Path for TLS for $Path"; return $true } -ModuleName $ScriptPath -Verifiable
        Mock New-Item { param($Path, $ItemType, $Force) Write-Verbose "Mock New-Item for TLS for $Path" } -ModuleName $ScriptPath -Verifiable
        Mock Set-ItemProperty { 
            param($Path, $Name, $Value, $Type, $Force) 
            Write-Verbose "Mock Set-ItemProperty for TLS Path: $Path, Name: $Name, Value: $Value"
        } -ModuleName $ScriptPath -Verifiable
        Mock Get-ItemProperty {
             param($Path, $Name) 
             Write-Verbose "Mock Get-ItemProperty for TLS Path $Path, Name $Name"
             return $null 
        } -ModuleName $ScriptPath -Verifiable
        
        Mock Invoke-Expression {
            param ([string]$Command)
            Write-Verbose "Mock Invoke-Expression for TLS called with: $Command"
            if ($Command -like "reg export*") {
                $Global:MockedRegistryExportCommand = $Command
            }
        } -ModuleName $ScriptPath -Verifiable

        Mock Write-Log -ModuleName $ScriptPath -MockWith { 
            param([string]$Message, [string]$Level="INFO")
            $Global:MockedWriteLogMessages.Add("TLS_SCRIPT_LOG: [$Level] $Message") 
        } -ErrorAction SilentlyContinue 
    }
    
    Context 'Script Loading and Basic Parameter Handling' {
        It 'Should load and run with default parameters (Enforce=$true, Backup=$true)' {
            . $ScriptPath 
            
            $Global:MockedRegistryExportCommand | Should -Not -BeNullOrEmpty 
            Assert-MockCalled Set-ItemProperty -ModuleName $ScriptPath -Scope It -Times 1 -ParameterFilter {
                $Path -like "*TLS 1.2\Client" -and $Name -eq "Enabled" -and $Value -eq 1 
            } -PassThru
            Assert-MockCalled Set-ItemProperty -ModuleName $ScriptPath -Scope It -Times 1 -ParameterFilter {
                $Path -like "*.NETFramework\v4.0.30319" -and $Name -eq "SchUseStrongCrypto" -and $Value -eq 1 
            } -PassThru
        }

        It 'Should NOT enforce settings if -EnforceSettings $false' {
            . $ScriptPath -EnforceSettings $false
            Assert-MockCalled Set-ItemProperty -ModuleName $ScriptPath -Scope It -Times 0 -ParameterFilter { $Name -eq 'Enabled' }
            Assert-MockCalled Set-ItemProperty -ModuleName $ScriptPath -Scope It -Times 0 -ParameterFilter { $Name -eq 'SchUseStrongCrypto' }
            $Global:MockedRegistryExportCommand | Should -Not -BeNullOrEmpty 
        }

        It 'Should NOT attempt backup if -BackupRegistry $false' {
             . $ScriptPath -BackupRegistry $false
             $Global:MockedRegistryExportCommand | Should -BeNullOrEmpty
             Assert-MockCalled Set-ItemProperty -ModuleName $ScriptPath -Scope It -ParameterFilter { $Name -eq 'Enabled' -and $Value -eq 1 } -Times 4 -PassThru 
        }

        It 'Should use the correct config file path from script''s relative location' {
            . $ScriptPath
            Assert-MockCalled Get-Content -ModuleName $ScriptPath -Scope It -Times 1 -ParameterFilter { $Path -like "*config\security-baseline.json" } -PassThru
        }
    }

    Context 'TLS Protocol Configuration' {
        It 'Should ENABLE TLS 1.2 Client and Server according to JSON' {
            . $ScriptPath
            $basePath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2"
            Assert-MockCalled Set-ItemProperty -ModuleName $ScriptPath -Scope It -Times 1 -ParameterFilter { $Path -eq "$basePath\Client" -and $Name -eq "Enabled" -and $Value -eq 1 } -PassThru
            Assert-MockCalled Set-ItemProperty -ModuleName $ScriptPath -Scope It -Times 1 -ParameterFilter { $Path -eq "$basePath\Client" -and $Name -eq "DisabledByDefault" -and $Value -eq 0 } -PassThru
            Assert-MockCalled Set-ItemProperty -ModuleName $ScriptPath -Scope It -Times 1 -ParameterFilter { $Path -eq "$basePath\Server" -and $Name -eq "Enabled" -and $Value -eq 1 } -PassThru
            Assert-MockCalled Set-ItemProperty -ModuleName $ScriptPath -Scope It -Times 1 -ParameterFilter { $Path -eq "$basePath\Server" -and $Name -eq "DisabledByDefault" -and $Value -eq 0 } -PassThru
        }

        It 'Should DISABLE TLS 1.0 Client and Server according to JSON' {
            . $ScriptPath
            $basePath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0"
            Assert-MockCalled Set-ItemProperty -ModuleName $ScriptPath -Scope It -Times 1 -ParameterFilter { $Path -eq "$basePath\Client" -and $Name -eq "Enabled" -and $Value -eq 0 } -PassThru
            Assert-MockCalled Set-ItemProperty -ModuleName $ScriptPath -Scope It -Times 1 -ParameterFilter { $Path -eq "$basePath\Client" -and $Name -eq "DisabledByDefault" -and $Value -eq 1 } -PassThru
            Assert-MockCalled Set-ItemProperty -ModuleName $ScriptPath -Scope It -Times 1 -ParameterFilter { $Path -eq "$basePath\Server" -and $Name -eq "Enabled" -and $Value -eq 0 } -PassThru
            Assert-MockCalled Set-ItemProperty -ModuleName $ScriptPath -Scope It -Times 1 -ParameterFilter { $Path -eq "$basePath\Server" -and $Name -eq "DisabledByDefault" -and $Value -eq 1 } -PassThru
        }
        
        It 'Should create protocol keys if Test-Path returns false for them' {
            Mock Test-Path -ModuleName $ScriptPath -MockWith { param($PathValue) 
                if ($PathValue -eq "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2" ) { return $false }
                if ($PathValue -eq "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client") { return $false }
                if ($PathValue -eq "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server") { return $false }
                return $true 
            }
            . $ScriptPath
            Assert-MockCalled New-Item -ModuleName $ScriptPath -Scope It -ParameterFilter { $Path -eq "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2" } -Times 1 -PassThru
            Assert-MockCalled New-Item -ModuleName $ScriptPath -Scope It -ParameterFilter { $Path -eq "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client" } -Times 1 -PassThru
            Assert-MockCalled New-Item -ModuleName $ScriptPath -Scope It -ParameterFilter { $Path -eq "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server" } -Times 1 -PassThru
        }
    }

    Context '.NET Framework Configuration' {
        It 'Should set SchUseStrongCrypto and SystemDefaultTlsVersions for .NET v4.0.30319' {
            . $ScriptPath
            $dotNetPath = "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319"
            Assert-MockCalled Set-ItemProperty -ModuleName $ScriptPath -Scope It -Times 1 -ParameterFilter { $Path -eq $dotNetPath -and $Name -eq "SchUseStrongCrypto" -and $Value -eq 1 } -PassThru
            Assert-MockCalled Set-ItemProperty -ModuleName $ScriptPath -Scope It -Times 1 -ParameterFilter { $Path -eq $dotNetPath -and $Name -eq "SystemDefaultTlsVersions" -and $Value -eq 1 } -PassThru
        }
        
        It 'Should set SchUseStrongCrypto and SystemDefaultTlsVersions for .NET v4.0.30319 (Wow6432Node)' {
            . $ScriptPath
            $dotNetWowPath = "HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319"
            Assert-MockCalled Set-ItemProperty -ModuleName $ScriptPath -Scope It -Times 1 -ParameterFilter { $Path -eq $dotNetWowPath -and $Name -eq "SchUseStrongCrypto" -and $Value -eq 1 } -PassThru
            Assert-MockCalled Set-ItemProperty -ModuleName $ScriptPath -Scope It -Times 1 -ParameterFilter { $Path -eq $dotNetWowPath -and $Name -eq "SystemDefaultTlsVersions" -and $Value -eq 1 } -PassThru
        }
    }

    Context 'Cipher Suite Configuration' {
        It 'Should set the cipher suite order' {
            . $ScriptPath
            $cryptoFunctionsPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Cryptography\Configuration\Local\SSL\00010002"
            $expectedCipherOrder = $MockTlsSettings.tlsSettings.cipherSuites.allowed
            
            Assert-MockCalled Set-ItemProperty -ModuleName $ScriptPath -Scope It -Times 1 -ParameterFilter {
                $Path -eq $cryptoFunctionsPath -and 
                $Name -eq "Functions" -and 
                ($Value -is [array] -and ($Value -join ',') -eq ($expectedCipherOrder -join ',')) -and
                $Type -eq "MultiString"
            } -PassThru
        }
        
        It 'Should attempt to disable a disallowed cipher suite if it exists' {
            Mock Test-Path -ModuleName $ScriptPath -MockWith { param($PathValue) 
                if ($PathValue -eq "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\CipherSuites\TLS_RSA_WITH_AES_256_CBC_SHA256") { return $true }
                return $true 
            }
            . $ScriptPath
            $disallowedCipherPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\CipherSuites\TLS_RSA_WITH_AES_256_CBC_SHA256"
            Assert-MockCalled Set-ItemProperty -ModuleName $ScriptPath -Scope It -Times 1 -ParameterFilter {
                $Path -eq $disallowedCipherPath -and $Name -eq "Enabled" -and $Value -eq 0 -and $Type -eq "DWord"
            } -PassThru
        }

        It 'Should NOT attempt to disable a disallowed cipher suite if its key does not exist' {
             Mock Test-Path -ModuleName $ScriptPath -MockWith { param($PathValue) 
                if ($PathValue -like "*SCHANNEL\CipherSuites\*") { return $false } 
                return $true 
            }
            . $ScriptPath
            $disallowedCipherPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\CipherSuites\TLS_RSA_WITH_AES_256_CBC_SHA256"
            Assert-MockCalled Set-ItemProperty -ModuleName $ScriptPath -Scope It -Times 0 -ParameterFilter {
                $Path -eq $disallowedCipherPath -and $Name -eq "Enabled"
            } -PassThru
        }
    }
    
    Context 'Logging Output' {
        It 'Should log key actions using the internal Write-Log function' {
            . $ScriptPath 
            
            $Global:MockedWriteLogMessages | Should -ContainMatch "\*Starting TLS configuration script\*"
            $Global:MockedWriteLogMessages | Should -ContainMatch "\*Configuring TLS protocols...\*"
            $Global:MockedWriteLogMessages | Should -ContainMatch "\*TLS_SCRIPT_LOG: \[INFO\] Configured TLS 1.2 Client: Enabled=True\*" 
            $Global:MockedWriteLogMessages | Should -ContainMatch "\*Configuring .NET Framework settings...\*"
            $Global:MockedWriteLogMessages | Should -ContainMatch "\*TLS configuration script completed successfully.\*"
        }
    }
}

Describe 'Update-CertificateStore.ps1 Tests' {
    $TestScriptRoot = (Split-Path $MyInvocation.MyCommand.Path -Parent)
    $ScriptPathUpdateCert = Join-Path $TestScriptRoot '..\..\..\src\Powershell\security\Update-CertificateStore.ps1'

    $mockCertSettings = @{
        certificateSettings = @{
            minimumKeySize = 2048
            allowedSignatureAlgorithms = @("sha256RSA", "sha384RSA", "ecdsa_secp256r1_sha256")
            disallowedSignatureAlgorithms = @("md5RSA", "sha1RSA")
            requiredCertificates = @(
                @{ subject = "CN=TestRoot1"; thumbprint = "THUMBPRINT1"; store = "Root"; sourcePath = "C:\certs\TestRoot1.cer" },
                @{ subject = "CN=TestIntermediate1"; thumbprint = "THUMBPRINT2"; store = "CA"; sourcePath = "C:\certs\TestIntermediate1.cer" }
            )
            certificateValidation = @{ 
                checkRevocation = $true
                checkTrustChain = $true 
                allowUserTrust = $false 
            }
            certificateStoresToValidate = @("Cert:\LocalMachine\My", "Cert:\LocalMachine\Root")
        }
    }
    $MockJsonContentForCert = ConvertTo-Json -InputObject $mockCertSettings -Depth 8

    function New-MockCertificate {
        param (
            [string]$Thumbprint = (New-Guid).ToString(),
            [string]$Subject = "CN=TestCert",
            [int]$KeySize = 2048,
            [string]$SignatureAlgorithmFriendlyName = "sha256RSA",
            [string]$PSParentPath = "Cert:\LocalMachine\My",
            [bool]$IsValidForTestCertificate = $true 
        )
        return [PSCustomObject]@{
            Thumbprint = $Thumbprint
            Subject = $Subject
            PublicKey = [PSCustomObject]@{ Key = [PSCustomObject]@{ KeySize = $KeySize } }
            SignatureAlgorithm = [PSCustomObject]@{ FriendlyName = $SignatureAlgorithmFriendlyName }
            PSPath = "$PSParentPath\$Thumbprint" 
            PSIsContainer = $false 
            _IsValidForTestCertificate = $IsValidForTestCertificate 
        }
    }

    BeforeEach {
        $Global:MockedWriteLogMessages.Clear() 

        Mock Get-Content { param($Path) Write-Verbose "Mock Get-Content for Certs called for $Path"; return $MockJsonContentForCert } -ModuleName $ScriptPathUpdateCert -Verifiable
        
        Mock Test-Path { param($Path)
            Write-Verbose "Mock Test-Path for Certs for $Path"
            if ($Path -like "C:\certs\*" -or $Path -like "Cert:\LocalMachine\*") { return $true }
            return $false 
        } -ModuleName $ScriptPathUpdateCert -Verifiable
        
        Mock Get-ChildItem { param($Path, $Recurse) 
            Write-Verbose "Mock Get-ChildItem for Certs for $Path"
            return @() 
        } -ModuleName $ScriptPathUpdateCert -Verifiable

        Mock Import-Certificate { param($FilePath, $CertStoreLocation) 
            Write-Verbose "Mock Import-Certificate for $FilePath to $CertStoreLocation"
        } -ModuleName $ScriptPathUpdateCert -Verifiable
        
        Mock Test-Certificate { param($PathOrCert) 
            Write-Verbose "Mock Test-Certificate called"
            if ($PathOrCert -is [PSCustomObject] -and $PathOrCert.PSObject.Properties.Name -contains '_IsValidForTestCertificate') {
                return [PSCustomObject]@{ IsValid = $PathOrCert._IsValidForTestCertificate; Status = if($PathOrCert._IsValidForTestCertificate){"Valid"}else{"Revoked"} }
            }
            return [PSCustomObject]@{ IsValid = $true; Status = "Valid" } 
        } -ModuleName $ScriptPathUpdateCert -Verifiable

        Mock Write-Log -ModuleName $ScriptPathUpdateCert -MockWith { 
            param([string]$Message, [string]$Level="INFO")
            $Global:MockedWriteLogMessages.Add("CERT_SCRIPT_LOG: [$Level] $Message")
        } -ErrorAction SilentlyContinue
    }

    Context 'Parameter Handling (Update-CertificateStore)' {
        It 'Should use JSON values for MinimumKeySize, Allowed/Disallowed Algorithms by default' {
            . $ScriptPathUpdateCert
            $Global:MockedWriteLogMessages | Should -ContainMatch "*Effective MinimumKeySize: 2048*"
            $Global:MockedWriteLogMessages | Should -ContainMatch "*Effective AllowedSignatureAlgorithms: sha256RSA, sha384RSA, ecdsa_secp256r1_sha256*"
            $Global:MockedWriteLogMessages | Should -ContainMatch "*Effective DisallowedSignatureAlgorithms: md5RSA, sha1RSA*"
        }

        It 'Should override MinimumKeySize with parameter' {
            . $ScriptPathUpdateCert -MinimumKeySizeOverride 4096
            $Global:MockedWriteLogMessages | Should -ContainMatch "*Effective MinimumKeySize: 4096*"
        }

        It 'Should override AllowedSignatureAlgorithms with parameter' {
            . $ScriptPathUpdateCert -AllowedSignatureAlgorithmsOverride @("ecdsa_secp384r1_sha384")
            $Global:MockedWriteLogMessages | Should -ContainMatch "*Effective AllowedSignatureAlgorithms: ecdsa_secp384r1_sha384*"
        }
        
        It 'Should not update root certificates if -UpdateRootCertificates $false' {
            . $ScriptPathUpdateCert -UpdateRootCertificates $false
            Assert-MockCalled Import-Certificate -ModuleName $ScriptPathUpdateCert -Scope It -Times 0
            $Global:MockedWriteLogMessages | Should -ContainMatch "*Skipping root certificate update*"
        }

        It 'Should not validate existing certificates if -ValidateChain $false' {
            $mockCert = New-MockCertificate
            Mock Get-ChildItem -ModuleName $ScriptPathUpdateCert -MockWith { param($Path) if ($Path -eq 'Cert:\LocalMachine\My') { return @($mockCert) } return @() }
            
            . $ScriptPathUpdateCert -ValidateChain $false
            $Global:MockedWriteLogMessages | Should -Not -ContainMatch "*Analyzing certificate: Subject='CN=TestCert'*"
            $Global:MockedWriteLogMessages | Should -ContainMatch "*Skipping certificate validation*"
        }
    }

    Context 'Root Certificate Updates (Update-CertificateStore)' {
        It 'Should attempt to import a required cert if not found in store and sourcePath exists' {
            Mock Test-Path -ModuleName $ScriptPathUpdateCert -MockWith { param($PathValue) 
                if ($PathValue -eq "Cert:\LocalMachine\Root\THUMBPRINT1") { Write-Verbose "Mock Test-Path returning FALSE for THUMBPRINT1"; return $false } 
                if ($PathValue -eq "C:\certs\TestRoot1.cer") { Write-Verbose "Mock Test-Path returning TRUE for C:\certs\TestRoot1.cer"; return $true } 
                if ($PathValue -like "Cert:\LocalMachine\*") { return $true } 
                return $false
            }

            . $ScriptPathUpdateCert -UpdateRootCertificates $true
            
            Assert-MockCalled Import-Certificate -ModuleName $ScriptPathUpdateCert -Scope It -Times 1 -ParameterFilter {
                $_.FilePath -eq "C:\certs\TestRoot1.cer" -and $_.CertStoreLocation -eq "Cert:\LocalMachine\Root"
            } -PassThru
            $Global:MockedWriteLogMessages | Should -ContainMatch "*Attempting to import THUMBPRINT1 from C:\\certs\\TestRoot1.cer*"
        }

        It 'Should NOT import a required cert if already found in store' {
             Mock Test-Path -ModuleName $ScriptPathUpdateCert -MockWith { param($PathValue)
                if ($PathValue -eq "Cert:\LocalMachine\Root\THUMBPRINT1") { return $true } 
                if ($PathValue -eq "C:\certs\TestRoot1.cer") { return $true } 
                return $true 
            }
            . $ScriptPathUpdateCert -UpdateRootCertificates $true
            Assert-MockCalled Import-Certificate -ModuleName $ScriptPathUpdateCert -Scope It -Times 0
            $Global:MockedWriteLogMessages | Should -ContainMatch "*Required certificate THUMBPRINT1 .* already exists*"
        }

        It 'Should log ERROR if required cert sourcePath does NOT exist' { 
            Mock Test-Path -ModuleName $ScriptPathUpdateCert -MockWith { param($PathValue)
                if ($PathValue -eq "Cert:\LocalMachine\Root\THUMBPRINT1") { return $false } 
                if ($PathValue -eq "C:\certs\TestRoot1.cer") { return $false } 
                return $true
            }
            . $ScriptPathUpdateCert -UpdateRootCertificates $true
            Assert-MockCalled Import-Certificate -ModuleName $ScriptPathUpdateCert -Scope It -Times 0
            $Global:MockedWriteLogMessages | Should -ContainMatch "*CERT_SCRIPT_LOG: \[ERROR\] Source path for certificate THUMBPRINT1 .* is not defined or invalid: 'C:\\certs\\TestRoot1.cer'*"
        }
    }

    Context 'Existing Certificate Validation (Update-CertificateStore)' {
        $mockGoodCert = New-MockCertificate -Subject "CN=GoodCert" -KeySize 2048 -SignatureAlgorithmFriendlyName "sha256RSA" -PSParentPath "Cert:\LocalMachine\My"
        $mockSmallKeyCert = New-MockCertificate -Subject "CN=SmallKeyCert" -KeySize 1024 -SignatureAlgorithmFriendlyName "sha256RSA" -PSParentPath "Cert:\LocalMachine\My"
        $mockBadAlgoCert = New-MockCertificate -Subject "CN=BadAlgoCert" -KeySize 2048 -SignatureAlgorithmFriendlyName "md5RSA" -PSParentPath "Cert:\LocalMachine\My"
        $mockInvalidChainCert = New-MockCertificate -Subject "CN=InvalidChainCert" -KeySize 2048 -SignatureAlgorithmFriendlyName "sha256RSA" -PSParentPath "Cert:\LocalMachine\My" -IsValidForTestCertificate $false

        It 'Should PASS a compliant certificate' {
            Mock Get-ChildItem -ModuleName $ScriptPathUpdateCert -MockWith { param($Path) if ($Path -eq 'Cert:\LocalMachine\My') { return @($mockGoodCert) } return @() }
            . $ScriptPathUpdateCert -ValidateChain $true
            $Global:MockedWriteLogMessages | Should -ContainMatch "*Key size validation PASSED for $($mockGoodCert.Thumbprint)*"
            $Global:MockedWriteLogMessages | Should -ContainMatch "*Signature algorithm validation PASSED for $($mockGoodCert.Thumbprint)*"
            $Global:MockedWriteLogMessages | Should -ContainMatch "*Chain validation PASSED for $($mockGoodCert.Thumbprint)*"
        }

        It 'Should WARN for certificate with key size smaller than MinimumKeySize' {
            Mock Get-ChildItem -ModuleName $ScriptPathUpdateCert -MockWith { param($Path) if ($Path -eq 'Cert:\LocalMachine\My') { return @($mockSmallKeyCert) } return @() }
            . $ScriptPathUpdateCert -ValidateChain $true
            $Global:MockedWriteLogMessages | Should -ContainMatch "*CERT_SCRIPT_LOG: \[WARNING\] Key size validation FAILED for $($mockSmallKeyCert.Thumbprint): Actual 1024-bit < Minimum 2048-bit.*"
        }

        It 'Should WARN for certificate with a disallowed signature algorithm' {
            Mock Get-ChildItem -ModuleName $ScriptPathUpdateCert -MockWith { param($Path) if ($Path -eq 'Cert:\LocalMachine\My') { return @($mockBadAlgoCert) } return @() }
            . $ScriptPathUpdateCert -ValidateChain $true
            $Global:MockedWriteLogMessages | Should -ContainMatch "*CERT_SCRIPT_LOG: \[WARNING\] Signature algorithm validation FAILED for $($mockBadAlgoCert.Thumbprint): 'md5RSA' is disallowed.*"
        }
        
        It 'Should WARN for certificate not in allowed signature algorithm list (if list is restrictive)' {
            $restrictedCertSettings = $mockCertSettings.PSObject.Copy() 
            $restrictedCertSettings.certificateSettings.allowedSignatureAlgorithms = @("sha256RSA") 
            $MockJsonContentForCertRestricted = ConvertTo-Json -InputObject $restrictedCertSettings -Depth 8
            Mock Get-Content { return $MockJsonContentForCertRestricted } -ModuleName $ScriptPathUpdateCert

            $nonListedAlgoCert = New-MockCertificate -Subject "CN=NonListedAlgo" -SignatureAlgorithmFriendlyName "sha384RSA" -PSParentPath "Cert:\LocalMachine\My"
            Mock Get-ChildItem -ModuleName $ScriptPathUpdateCert -MockWith { param($Path) if ($Path -eq 'Cert:\LocalMachine\My') { return @($nonListedAlgoCert) } return @() }
            
            . $ScriptPathUpdateCert -ValidateChain $true
            $Global:MockedWriteLogMessages | Should -ContainMatch "*CERT_SCRIPT_LOG: \[WARNING\] Signature algorithm validation FAILED for $($nonListedAlgoCert.Thumbprint): 'sha384RSA' is not in the allowed list.*"
        }

        It 'Should WARN for certificate that fails Test-Certificate chain validation' {
            Mock Get-ChildItem -ModuleName $ScriptPathUpdateCert -MockWith { param($Path) if ($Path -eq 'Cert:\LocalMachine\My') { return @($mockInvalidChainCert) } return @() }
            . $ScriptPathUpdateCert -ValidateChain $true
            $Global:MockedWriteLogMessages | Should -ContainMatch "*CERT_SCRIPT_LOG: \[WARNING\] Chain validation FAILED for $($mockInvalidChainCert.Thumbprint). Status: Revoked*"
        }
    }
}

Describe 'Set-FirewallRules.ps1 Tests' {
    $TestScriptRoot = (Split-Path $MyInvocation.MyCommand.Path -Parent)
    $ScriptPathFirewall = Join-Path $TestScriptRoot '..\..\..\src\Powershell\security\Set-FirewallRules.ps1'

    $mockFirewallSettings = @{
        firewallRules = @{
            outbound = @(
                @{ name = "Allow Azure Arc Management"; protocol = "TCP"; port = 443; destination = "*.management.azure.com"; required = $true; action = "Allow" },
                @{ name = "Block Old App"; protocol = "TCP"; port = 8080; destination = "old.app.com"; required = $true; action = "Block" },
                @{ name = "Allow Specific UDP"; protocol = "UDP"; port = 123; destination = "time.google.com"; required = $true; action = "Allow"; profile = "Any"}
            )
            inbound = @(
                @{ name = "Allow WinRM"; protocol = "TCP"; port = 5985; source = "192.168.1.0/24"; required = $false }
            )
        }
    }
    $MockJsonContentForFirewall = ConvertTo-Json -InputObject $mockFirewallSettings -Depth 5
    
    $Global:isAdmin = $true 

    BeforeEach {
        $Global:MockedWriteLogMessages.Clear()
        $Global:MockedNetshExportCommand = $null 
        $Global:isAdmin = $true 

        Mock Get-Content { param($Path) Write-Verbose "Mock Get-Content for Firewall called for $Path"; return $MockJsonContentForFirewall } -ModuleName $ScriptPathFirewall -Verifiable
        
        Mock Test-Path { param($Path) Write-Verbose "Mock Test-Path for Firewall for $Path"; return $true } -ModuleName $ScriptPathFirewall -Verifiable 
        Mock New-Item { param($ItemTypeOrPath, $PathOrName, $ItemTypeOrForce, $ForceValue) # Adjusted for varied New-Item calls
            if ($PSBoundParameters.ContainsKey('ItemTypeOrPath') -and $PSBoundParameters.ContainsKey('PathOrName') -and $PSBoundParameters.ContainsKey('ItemTypeOrForce')) {
                 Write-Verbose "Mock New-Item (Path,Type,Force) for Firewall for Path: $($PathOrName)"
            } else {
                 Write-Verbose "Mock New-Item (Type,Path,Force) for Firewall for Path: $($ItemTypeOrPath)"
            }
        } -ModuleName $ScriptPathFirewall -Verifiable 
        
        Mock Invoke-Expression {
            param ([string]$Command)
            Write-Verbose "Mock Invoke-Expression for Firewall called with: $Command"
            if ($Command -like "netsh advfirewall export*") {
                $Global:MockedNetshExportCommand = $Command
            }
        } -ModuleName $ScriptPathFirewall -Verifiable

        Mock Get-NetFirewallRule { param($DisplayName) Write-Verbose "Mock Get-NetFirewallRule for $DisplayName"; return $null } -ModuleName $ScriptPathFirewall -Verifiable 
        Mock New-NetFirewallRule { Write-Verbose "Mock New-NetFirewallRule called with: $($PSBoundParameters | Out-String)" } -ModuleName $ScriptPathFirewall -Verifiable
        Mock Set-NetFirewallRule { Write-Verbose "Mock Set-NetFirewallRule called with: $($PSBoundParameters | Out-String)" } -ModuleName $ScriptPathFirewall -Verifiable
        
        Mock Write-Log -ModuleName $ScriptPathFirewall -MockWith { 
            param([string]$Message, [string]$Level="INFO", [string]$Path) 
            $Global:MockedWriteLogMessages.Add("FIREWALL_SCRIPT_LOG: [$Level] $Message")
        } -ErrorAction SilentlyContinue
    }

    Context 'Administrator Check (Set-FirewallRules)' {
        It 'Should log an error and throw if not run as Administrator' {
            Skip "Skipping direct test of non-admin scenario due to .NET mocking limitations with current Pester setup."
        }
    }

    Context 'Parameter Handling (Set-FirewallRules)' {
        It 'Should run with default parameters (EnforceRules=$true, BackupRules=$true)' {
            . $ScriptPathFirewall
            $Global:MockedNetshExportCommand | Should -Not -BeNullOrEmpty 
            Assert-MockCalled New-NetFirewallRule -ModuleName $ScriptPathFirewall -Scope It -Times $(@($mockFirewallSettings.firewallRules.outbound).Count + @($mockFirewallSettings.firewallRules.inbound).Count) -PassThru 
        }

        It 'Should NOT enforce rules if -EnforceRules $false' {
            . $ScriptPathFirewall -EnforceRules $false
            Assert-MockCalled New-NetFirewallRule -ModuleName $ScriptPathFirewall -Scope It -Times 0
            Assert-MockCalled Set-NetFirewallRule -ModuleName $ScriptPathFirewall -Scope It -Times 0
            $Global:MockedNetshExportCommand | Should -BeNullOrEmpty 
        }

        It 'Should NOT attempt backup if -BackupRules $false (but still enforce)' {
             . $ScriptPathFirewall -BackupRules $false
             $Global:MockedNetshExportCommand | Should -BeNullOrEmpty
             Assert-MockCalled New-NetFirewallRule -ModuleName $ScriptPathFirewall -Scope It -Times $(@($mockFirewallSettings.firewallRules.outbound).Count + @($mockFirewallSettings.firewallRules.inbound).Count) -PassThru
        }
    }

    Context 'Firewall Rule Processing (Set-FirewallRules)' {
        It 'Should CREATE a new OUTBOUND rule "Allow Azure Arc Management" if it does not exist' {
            . $ScriptPathFirewall
            Assert-MockCalled New-NetFirewallRule -ModuleName $ScriptPathFirewall -Scope It -Times 1 -ParameterFilter {
                $_.DisplayName -eq 'Allow Azure Arc Management' -and
                $_.Direction -eq 'Outbound' -and
                $_.Action -eq 'Allow' -and
                $_.Protocol -eq 'TCP' -and
                $_.RemotePort -eq 443 -and
                $_.RemoteAddress -eq '*.management.azure.com' -and
                $_.Enabled -eq $true 
            } -PassThru
        }

        It 'Should CREATE a new OUTBOUND rule "Block Old App" with Action Block' {
            . $ScriptPathFirewall
            Assert-MockCalled New-NetFirewallRule -ModuleName $ScriptPathFirewall -Scope It -Times 1 -ParameterFilter {
                $_.DisplayName -eq 'Block Old App' -and
                $_.Direction -eq 'Outbound' -and
                $_.Action -eq 'Block' -and 
                $_.Protocol -eq 'TCP' -and
                $_.RemotePort -eq 8080 -and
                $_.RemoteAddress -eq 'old.app.com' -and
                $_.Enabled -eq $true
            } -PassThru
        }
        
        It 'Should CREATE a new INBOUND rule "Allow WinRM" and set Enabled based on "required=false"' {
            . $ScriptPathFirewall
            Assert-MockCalled New-NetFirewallRule -ModuleName $ScriptPathFirewall -Scope It -Times 1 -ParameterFilter {
                $_.DisplayName -eq 'Allow WinRM' -and
                $_.Direction -eq 'Inbound' -and
                $_.Action -eq 'Allow' -and 
                $_.Protocol -eq 'TCP' -and
                $_.LocalPort -eq 5985 -and 
                $_.RemoteAddress -eq '192.168.1.0/24' -and
                $_.Enabled -eq $false 
            } -PassThru
        }

        It 'Should UPDATE an existing rule if Get-NetFirewallRule returns a different rule' {
            $existingRule = [pscustomobject]@{
                DisplayName = 'Allow Azure Arc Management'
                Direction = 'Outbound'
                Action = 'Allow'
                Protocol = 'UDP' 
                RemotePort = 1234 
                RemoteAddress = '*.management.contoso.com' 
                Enabled = $false 
                Profile = "Domain" 
            }
            Mock Get-NetFirewallRule -ModuleName $ScriptPathFirewall -MockWith { param($DisplayName) 
                if($DisplayName -eq 'Allow Azure Arc Management') { return $existingRule } 
                return $null 
            }

            . $ScriptPathFirewall
            Assert-MockCalled Set-NetFirewallRule -ModuleName $ScriptPathFirewall -Scope It -Times 1 -ParameterFilter {
                $_.DisplayName -eq 'Allow Azure Arc Management' -and
                $_.Direction -eq 'Outbound' -and 
                $_.Action -eq 'Allow' -and
                $_.Protocol -eq 'TCP' -and       
                $_.RemotePort -eq 443 -and      
                $_.RemoteAddress -eq '*.management.azure.com' -and 
                $_.Enabled -eq $true -and      
                $_.Profile -eq 'Any' 
            } -PassThru
            Assert-MockCalled New-NetFirewallRule -ModuleName $ScriptPathFirewall -Scope It -ParameterFilter { $_.DisplayName -eq 'Allow Azure Arc Management' } -Times 0 
        }
         It 'Should use specified Profile if provided in JSON for a new rule' {
            . $ScriptPathFirewall
            Assert-MockCalled New-NetFirewallRule -ModuleName $ScriptPathFirewall -Scope It -Times 1 -ParameterFilter {
                $_.DisplayName -eq 'Allow Specific UDP' -and
                $_.Profile -eq 'Any' 
            } -PassThru
        }
    }

    Context 'Backup Logic (Set-FirewallRules)' {
        It 'Should call "netsh advfirewall export" when BackupRules is $true (default) and EnforceRules is $true (default)' {
            . $ScriptPathFirewall
            $Global:MockedNetshExportCommand | Should -Match "netsh advfirewall export `".*FirewallPolicyBackup-.*\.wfw`""
            Assert-MockCalled Invoke-Expression -ModuleName $ScriptPathFirewall -Scope It -Times 1 -PassThru
        }

        It 'Should NOT call "netsh advfirewall export" when BackupRules is $false' {
            . $ScriptPathFirewall -BackupRules $false
            $Global:MockedNetshExportCommand | Should -BeNullOrEmpty
            Assert-MockCalled Invoke-Expression -ModuleName $ScriptPathFirewall -Scope It -Times 0 -ParameterFilter {$_ -like "netsh advfirewall export*"}
        }
        
        It 'Should NOT call "netsh advfirewall export" when EnforceRules is $false' {
            . $ScriptPathFirewall -EnforceRules $false
            $Global:MockedNetshExportCommand | Should -BeNullOrEmpty
            Assert-MockCalled Invoke-Expression -ModuleName $ScriptPathFirewall -Scope It -Times 0 -ParameterFilter {$_ -like "netsh advfirewall export*"}
        }
    }

    Context 'Logging Output (Set-FirewallRules)' {
        It 'Should log key actions' {
            . $ScriptPathFirewall
            $Global:MockedWriteLogMessages | Should -ContainMatch "*FIREWALL_SCRIPT_LOG: \[INFO\] Starting firewall configuration script.*"
            $Global:MockedWriteLogMessages | Should -ContainMatch "*FIREWALL_SCRIPT_LOG: \[INFO\] Backing up current firewall policy to*"
            $Global:MockedWriteLogMessages | Should -ContainMatch "*FIREWALL_SCRIPT_LOG: \[INFO\] Processing outbound rules...*"
            $Global:MockedWriteLogMessages | Should -ContainMatch "*FIREWALL_SCRIPT_LOG: \[INFO\] Rule 'Allow Azure Arc Management' does not exist. Creating...*"
            $Global:MockedWriteLogMessages | Should -ContainMatch "*FIREWALL_SCRIPT_LOG: \[INFO\] Processing inbound rules...*"
            $Global:MockedWriteLogMessages | Should -ContainMatch "*FIREWALL_SCRIPT_LOG: \[INFO\] Firewall configuration script completed.*"
        }
    }
}

Describe 'Set-AuditPolicies.ps1 Tests' {
    $TestScriptRoot = (Split-Path $MyInvocation.MyCommand.Path -Parent)
    $ScriptPathAudit = Join-Path $TestScriptRoot '..\..\..\src\Powershell\security\Set-AuditPolicies.ps1'

    $mockAuditSettings = @{
        auditPolicies = @{
            accountLogon = @{
                credentialValidation = "Success,Failure" # Needs to become "Credential Validation"
            }
            detailedTracking = @{
                processCreation = "Success" # Becomes "Process Creation"
            }
            logon = @{
                logon = "Failure" # Becomes "Logon"
            }
            objectAccess = @{
                fileSystem = "No Auditing" # Becomes "File System"
            }
        }
    }
    $MockJsonContentForAudit = ConvertTo-Json -InputObject $mockAuditSettings -Depth 5

    BeforeEach {
        $Global:MockedWriteLogMessages.Clear()
        $Global:AuditpolCommands.Clear() # Use specific global for auditpol commands

        Mock Get-Content { param($Path) Write-Verbose "Mock Get-Content for Audit called for $Path"; return $MockJsonContentForAudit } -ModuleName $ScriptPathAudit -Verifiable
        
        # Admin check - same challenge as Set-FirewallRules.ps1. Assume admin for most tests.
        # The script itself has the IsInRole check.
        
        Mock Test-Path { param($Path) Write-Verbose "Mock Test-Path for Audit for $Path"; return $true } -ModuleName $ScriptPathAudit -Verifiable 
        Mock New-Item { param($ItemType, $Path, $Force) Write-Verbose "Mock New-Item for Audit for $Path" } -ModuleName $ScriptPathAudit -Verifiable
        
        # Mock Invoke-Expression for auditpol calls
        Mock Invoke-Expression {
            param ([string]$Command)
            Write-Verbose "Mock Invoke-Expression for Audit called with: $Command"
            $Global:AuditpolCommands.Add($Command) # Store all calls for verification
        } -ModuleName $ScriptPathAudit -Verifiable
        
        # Mock LASTEXITCODE for auditpol success
        Mock Get-Variable -ModuleName $ScriptPathAudit -MockWith {
            param($Name, $ValueOnly)
            if ($Name -eq 'LASTEXITCODE') { return 0 } # Simulate success
            return (Get-Variable @PSBoundParameters) # Default behavior for other variables
        } -ParameterFilter {$Name -eq 'LASTEXITCODE'}


        Mock Write-Log -ModuleName $ScriptPathAudit -MockWith { 
            param([string]$Message, [string]$Level="INFO", [string]$Path) 
            $Global:MockedWriteLogMessages.Add("AUDIT_SCRIPT_LOG: [$Level] $Message")
        } -ErrorAction SilentlyContinue
    }

    Context 'Administrator Check (Set-AuditPolicies)' {
        It 'Should log an error and throw if not run as Administrator' {
             Skip "Skipping direct test of non-admin scenario due to .NET mocking limitations with current Pester setup."
        }
    }

    Context 'Parameter Handling (Set-AuditPolicies)' {
        It 'Should run with default parameters (EnforceSettings=$true, BackupSettings=$true)' {
            . $ScriptPathAudit
            ($Global:AuditpolCommands | Where-Object { $_ -match 'auditpol /backup /file:' }).Count | Should -Be 1
            ($Global:AuditpolCommands | Where-Object { $_ -match 'auditpol /set /subcategory:' }).Count | Should -Be 4 # For the 4 policies in mock JSON
        }

        It 'Should NOT enforce settings if -EnforceSettings $false' {
            . $ScriptPathAudit -EnforceSettings $false
            ($Global:AuditpolCommands | Where-Object { $_ -match 'auditpol /set /subcategory:' }).Count | Should -Be 0
            ($Global:AuditpolCommands | Where-Object { $_ -match 'auditpol /backup /file:' }).Count | Should -Be 1 # Backup should still run
        }

        It 'Should NOT attempt backup if -BackupSettings $false (but still enforce)' {
             . $ScriptPathAudit -BackupSettings $false
             ($Global:AuditpolCommands | Where-Object { $_ -match 'auditpol /backup /file:' }).Count | Should -Be 0
             ($Global:AuditpolCommands | Where-Object { $_ -match 'auditpol /set /subcategory:' }).Count | Should -Be 4
        }
    }

    Context 'Audit Policy Processing (Set-AuditPolicies)' {
        It 'Should set "Credential Validation" to Success and Failure' {
            . $ScriptPathAudit
            $Global:AuditpolCommands | Should -ContainMatch 'auditpol /set /subcategory:"Credential Validation" /success:enable /failure:enable'
        }

        It 'Should set "Process Creation" to Success only' {
            . $ScriptPathAudit
            $Global:AuditpolCommands | Should -ContainMatch 'auditpol /set /subcategory:"Process Creation" /success:enable /failure:disable'
        }

        It 'Should set "Logon" to Failure only' { # Note: JSON key is "logon", script converts to "Logon"
            . $ScriptPathAudit
            $Global:AuditpolCommands | Should -ContainMatch 'auditpol /set /subcategory:"Logon" /success:disable /failure:enable'
        }

        It 'Should set "File System" to No Auditing (both disabled)' {
            . $ScriptPathAudit
            $Global:AuditpolCommands | Should -ContainMatch 'auditpol /set /subcategory:"File System" /success:disable /failure:disable'
        }
    }

    Context 'Backup Logic (Set-AuditPolicies)' {
        It 'Should call "auditpol /backup /file:" when BackupSettings and EnforceSettings are $true (default)' {
            . $ScriptPathAudit
            ($Global:AuditpolCommands | Where-Object { $_ -match 'auditpol /backup /file:".*AuditPolicyBackup-.*\.csv"' }).Count | Should -Be 1
        }

        It 'Should NOT call "auditpol /backup" when BackupSettings is $false' {
            . $ScriptPathAudit -BackupSettings $false
            ($Global:AuditpolCommands | Where-Object { $_ -match 'auditpol /backup /file:' }).Count | Should -Be 0
        }
        
        It 'Should NOT call "auditpol /backup" when EnforceSettings is $false (but BackupSettings is true - script logic)' {
            # The script logic is: if ($BackupSettings -and $EnforceSettings) { Backup-AuditPolicy }
            . $ScriptPathAudit -EnforceSettings $false # BackupSettings is $true by default
            ($Global:AuditpolCommands | Where-Object { $_ -match 'auditpol /backup /file:' }).Count | Should -Be 0
        }
    }

    Context 'Logging Output (Set-AuditPolicies)' {
        It 'Should log key actions' {
            . $ScriptPathAudit
            $Global:MockedWriteLogMessages | Should -ContainMatch "*AUDIT_SCRIPT_LOG: \[INFO\] Starting audit policy configuration script.*"
            $Global:MockedWriteLogMessages | Should -ContainMatch "*AUDIT_SCRIPT_LOG: \[INFO\] Backing up current audit policy to *"
            $Global:MockedWriteLogMessages | Should -ContainMatch "*AUDIT_SCRIPT_LOG: \[INFO\] Setting policy for Subcategory: 'Credential Validation' to 'Success,Failure'*"
            $Global:MockedWriteLogMessages | Should -ContainMatch "*AUDIT_SCRIPT_LOG: \[INFO\] Executing: auditpol /set /subcategory:`"Credential Validation`" /success:enable /failure:enable*"
            $Global:MockedWriteLogMessages | Should -ContainMatch "*AUDIT_SCRIPT_LOG: \[INFO\] Audit policy configuration script completed.*"
        }
    }
}

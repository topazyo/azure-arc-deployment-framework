# tests/Powershell/unit/Security.Tests.ps1
using namespace System.Management.Automation

# Ensure Pester is available. Adjust MinimumVersion as needed for your environment.
Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

BeforeAll {
    # Ensure cmdlet modules are loaded so -ModuleName mocks work reliably in Pester 5
    Import-Module Microsoft.PowerShell.Management -ErrorAction SilentlyContinue
    Import-Module Microsoft.PowerShell.Utility -ErrorAction SilentlyContinue
    Import-Module PKI -ErrorAction SilentlyContinue
    Import-Module NetSecurity -ErrorAction SilentlyContinue
}

$Global:RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
$Global:WriteLogPath = Join-Path $Global:RepoRoot 'src\Powershell\utils\Write-Log.ps1'
$Global:TestIsAdminPath = Join-Path $Global:RepoRoot 'src\Powershell\utils\Test-IsAdministrator.ps1'

# Load shared logging so Write-Log exists for Pester mocks
. $Global:WriteLogPath

function script:New-MockCertificate {
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

function script:Assert-LogLike {
    param(
        [Parameter(Mandatory)]
        [string]$Pattern
    )

    @($Global:MockedWriteLogMessages | Where-Object { $_ -like $Pattern }).Count | Should -BeGreaterThan 0
}

function script:Assert-LogNotLike {
    param(
        [Parameter(Mandatory)]
        [string]$Pattern
    )

    @($Global:MockedWriteLogMessages | Where-Object { $_ -like $Pattern }).Count | Should -Be 0
}

Describe 'Set-TLSConfiguration.ps1 Tests' {
    # Path to the script being tested. Assuming this test script is in tests/Powershell/unit/
    $TestScriptRoot = $PSScriptRoot
    $ScriptPath = Join-Path $TestScriptRoot '..\..\..\src\Powershell\security\Set-TLSConfiguration.ps1'
    
    # Mocked JSON content
    $Global:MockTlsSettings = @{
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
    $Global:MockJsonContentForTls = ConvertTo-Json -InputObject $Global:MockTlsSettings -Depth 5 

    $Global:MockedRegistryExportCommand = $null 
    $Global:MockedNetshExportCommand = $null 
    $Global:AuditpolCommands = [System.Collections.Generic.List[string]]::new() # For Set-AuditPolicies
    $Global:MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new()

    BeforeAll {
        $script:ScriptPathTLS = Join-Path $PSScriptRoot '..\..\..\src\Powershell\security\Set-TLSConfiguration.ps1'
        . $Global:WriteLogPath
    }

    BeforeEach { 
        $Global:MockedRegistryExportCommand = $null
        $Global:MockedWriteLogMessages.Clear()

        if ($null -eq $Global:MockTlsConfigObject) {
            $Global:MockTlsConfigObject = Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $Global:MockJsonContentForTls
        }

            Mock Get-Content { param($Path) Write-Verbose "Mock Get-Content for TLS called for $Path"; return $Global:MockJsonContentForTls } -Verifiable
            Mock ConvertFrom-Json { param($InputObject) return $Global:MockTlsConfigObject } -Verifiable
            Mock Test-Path { param($Path) Write-Verbose "Mock Test-Path for TLS for $Path"; return $true } -Verifiable
            Mock New-Item { param([string]$Path, [string]$ItemType, [switch]$Force, $ErrorAction) Write-Verbose "Mock New-Item for TLS for $Path" } -Verifiable
            Mock Set-ItemProperty { 
                param([string]$Path, [string]$Name, $Value, [switch]$Force, $ErrorAction) 
            Write-Verbose "Mock Set-ItemProperty for TLS Path: $Path, Name: $Name, Value: $Value"
        } -Verifiable
        Mock Get-ItemProperty {
             param($Path, $Name) 
             Write-Verbose "Mock Get-ItemProperty for TLS Path $Path, Name $Name"
             return $null 
        } -Verifiable
        
        Mock Invoke-Expression {
            param ([string]$Command)
            Write-Verbose "Mock Invoke-Expression for TLS called with: $Command"
            if ($Command -like "reg export*") {
                $Global:MockedRegistryExportCommand = $Command
            }
        } -Verifiable

        Mock Write-Host { } -Verifiable

        $sink = {
            param(
                [string]$Path,
                [string]$Value
            )
            $Global:MockedWriteLogMessages.Add($Value)
        }

        Set-Item -Path Function:Write-LogSink -Value $sink
        Set-Item -Path Function:global:Write-LogSink -Value $sink
    }
    
    Context 'Script Loading and Basic Parameter Handling' {
        It 'Should load and run with default parameters (Enforce=$true, Backup=$true)' {
            . $script:ScriptPathTLS 
            
            $Global:MockedRegistryExportCommand | Should -Not -BeNullOrEmpty 
            Assert-MockCalled Set-ItemProperty -Scope It -Times 1 -ParameterFilter {
                $Path -like "*TLS 1.2\Client" -and $Name -eq "Enabled" -and $Value -eq 1 
            }
            Assert-MockCalled Set-ItemProperty -Scope It -Times 1 -ParameterFilter {
                $Path -like "*.NETFramework\v4.0.30319" -and $Name -eq "SchUseStrongCrypto" -and $Value -eq 1 
            }
        }

        It 'Should NOT enforce settings if -EnforceSettings $false' {
            . $script:ScriptPathTLS -EnforceSettings $false
            Assert-MockCalled Set-ItemProperty -Scope It -Times 0 -ParameterFilter { $Name -eq 'Enabled' }
            Assert-MockCalled Set-ItemProperty -Scope It -Times 0 -ParameterFilter { $Name -eq 'SchUseStrongCrypto' }
            $Global:MockedRegistryExportCommand | Should -Not -BeNullOrEmpty 
        }

        It 'Should NOT attempt backup if -BackupRegistry $false' {
               . $script:ScriptPathTLS -BackupRegistry $false
             $Global:MockedRegistryExportCommand | Should -BeNullOrEmpty
                             Assert-MockCalled Set-ItemProperty -Scope It -ParameterFilter { $Name -eq 'Enabled' -and $Value -eq 1 } -Times 4 
        }

        It 'Should use the correct config file path from script''s relative location' {
            . $script:ScriptPathTLS
            Assert-MockCalled Get-Content -Scope It -Times 1 -ParameterFilter { $Path -like "*config\security-baseline.json" }
        }
    }

    Context 'TLS Protocol Configuration' {
        It 'Should ENABLE TLS 1.2 Client and Server according to JSON' {
            . $script:ScriptPathTLS
            $basePath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2"
            Assert-MockCalled Set-ItemProperty -Scope It -Times 1 -ParameterFilter { $Path -eq "$basePath\Client" -and $Name -eq "Enabled" -and $Value -eq 1 }
            Assert-MockCalled Set-ItemProperty -Scope It -Times 1 -ParameterFilter { $Path -eq "$basePath\Client" -and $Name -eq "DisabledByDefault" -and $Value -eq 0 }
            Assert-MockCalled Set-ItemProperty -Scope It -Times 1 -ParameterFilter { $Path -eq "$basePath\Server" -and $Name -eq "Enabled" -and $Value -eq 1 }
            Assert-MockCalled Set-ItemProperty -Scope It -Times 1 -ParameterFilter { $Path -eq "$basePath\Server" -and $Name -eq "DisabledByDefault" -and $Value -eq 0 }
        }

        It 'Should DISABLE TLS 1.0 Client and Server according to JSON' {
            . $script:ScriptPathTLS
            $basePath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0"
            Assert-MockCalled Set-ItemProperty -Scope It -Times 1 -ParameterFilter { $Path -eq "$basePath\Client" -and $Name -eq "Enabled" -and $Value -eq 0 }
            Assert-MockCalled Set-ItemProperty -Scope It -Times 1 -ParameterFilter { $Path -eq "$basePath\Client" -and $Name -eq "DisabledByDefault" -and $Value -eq 1 }
            Assert-MockCalled Set-ItemProperty -Scope It -Times 1 -ParameterFilter { $Path -eq "$basePath\Server" -and $Name -eq "Enabled" -and $Value -eq 0 }
            Assert-MockCalled Set-ItemProperty -Scope It -Times 1 -ParameterFilter { $Path -eq "$basePath\Server" -and $Name -eq "DisabledByDefault" -and $Value -eq 1 }
        }
        
        It 'Should create protocol keys if Test-Path returns false for them' {
            Mock Test-Path -MockWith { param($PathValue) 
                if ($PathValue -eq "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2" ) { return $false }
                if ($PathValue -eq "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client") { return $false }
                if ($PathValue -eq "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server") { return $false }
                return $true 
            }
            . $script:ScriptPathTLS
            Assert-MockCalled New-Item -Scope It -ParameterFilter { $Path -eq "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2" } -Times 1
            Assert-MockCalled New-Item -Scope It -ParameterFilter { $Path -eq "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client" } -Times 1
            Assert-MockCalled New-Item -Scope It -ParameterFilter { $Path -eq "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server" } -Times 1
        }
    }

    Context '.NET Framework Configuration' {
        It 'Should set SchUseStrongCrypto and SystemDefaultTlsVersions for .NET v4.0.30319' {
            . $script:ScriptPathTLS
            $dotNetPath = "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319"
            Assert-MockCalled Set-ItemProperty -Scope It -Times 1 -ParameterFilter { $Path -eq $dotNetPath -and $Name -eq "SchUseStrongCrypto" -and $Value -eq 1 }
            Assert-MockCalled Set-ItemProperty -Scope It -Times 1 -ParameterFilter { $Path -eq $dotNetPath -and $Name -eq "SystemDefaultTlsVersions" -and $Value -eq 1 }
        }
        
        It 'Should set SchUseStrongCrypto and SystemDefaultTlsVersions for .NET v4.0.30319 (Wow6432Node)' {
            . $script:ScriptPathTLS
            $dotNetWowPath = "HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319"
            Assert-MockCalled Set-ItemProperty -Scope It -Times 1 -ParameterFilter { $Path -eq $dotNetWowPath -and $Name -eq "SchUseStrongCrypto" -and $Value -eq 1 }
            Assert-MockCalled Set-ItemProperty -Scope It -Times 1 -ParameterFilter { $Path -eq $dotNetWowPath -and $Name -eq "SystemDefaultTlsVersions" -and $Value -eq 1 }
        }
    }

    Context 'Cipher Suite Configuration' {
        It 'Should set the cipher suite order' {
            . $script:ScriptPathTLS
            $cryptoFunctionsPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Cryptography\Configuration\Local\SSL\00010002"
            $expectedCipherOrder = $Global:MockTlsSettings.tlsSettings.cipherSuites.allowed
            
            Assert-MockCalled Set-ItemProperty -Scope It -Times 1 -ParameterFilter {
                $Path -eq $cryptoFunctionsPath -and 
                $Name -eq "Functions" -and 
                ($Value -is [array] -and ($Value -join ',') -eq ($expectedCipherOrder -join ','))
            }
        }
        
        It 'Should attempt to disable a disallowed cipher suite if it exists' {
            Mock Test-Path -MockWith { param($PathValue) 
                if ($PathValue -eq "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\CipherSuites\TLS_RSA_WITH_AES_256_CBC_SHA256") { return $true }
                return $true 
            }
            . $script:ScriptPathTLS
            $disallowedCipherPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\CipherSuites\TLS_RSA_WITH_AES_256_CBC_SHA256"
            Assert-MockCalled Set-ItemProperty -Scope It -Times 1 -ParameterFilter {
                $Path -eq $disallowedCipherPath -and $Name -eq "Enabled" -and $Value -eq 0
            }
        }

        It 'Should NOT attempt to disable a disallowed cipher suite if its key does not exist' {
             Mock Test-Path -MockWith { param($PathValue) 
                if ($PathValue -like "*SCHANNEL\CipherSuites\*") { return $false } 
                return $true 
            }
            . $script:ScriptPathTLS
            $disallowedCipherPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\CipherSuites\TLS_RSA_WITH_AES_256_CBC_SHA256"
            Assert-MockCalled Set-ItemProperty -Scope It -Times 0 -ParameterFilter {
                $Path -eq $disallowedCipherPath -and $Name -eq "Enabled"
            }
        }
    }
    
    Context 'Logging Output' {
        It 'Should log key actions using the internal Write-Log function' {
            . $script:ScriptPathTLS 
            
            Assert-LogLike '*Starting TLS configuration script*'
            Assert-LogLike '*Configuring TLS protocols...*'
            Assert-LogLike '*Configured TLS 1.2 Client: Enabled=True*'
            Assert-LogLike '*Configuring .NET Framework settings...*'
            Assert-LogLike '*TLS configuration script completed successfully.*'
        }
    }
}

Describe 'Update-CertificateStore.ps1 Tests' {
    $TestScriptRoot = $PSScriptRoot
    $ScriptPathUpdateCert = Join-Path $TestScriptRoot '..\..\..\src\Powershell\security\Update-CertificateStore.ps1'

    BeforeAll {
        $script:ScriptPathUpdateCert = Join-Path $PSScriptRoot '..\..\..\src\Powershell\security\Update-CertificateStore.ps1'
        . (Join-Path $PSScriptRoot '..\..\..\src\Powershell\utils\Write-Log.ps1')
    }

    $Global:MockCertSettings = @{
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
    $Global:MockJsonContentForCert = ConvertTo-Json -InputObject $Global:MockCertSettings -Depth 8

    BeforeEach {
        $Global:MockedWriteLogMessages.Clear() 
        $Global:MockCertificatesByStore = @{}
        $Global:MockedGetChildItemPaths = [System.Collections.Generic.List[string]]::new()

        if ($null -eq $Global:MockCertConfigObject) {
            $Global:MockCertConfigObject = Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $Global:MockJsonContentForCert
        }

        Mock Get-Content { param($Path) Write-Verbose "Mock Get-Content for Certs called for $Path"; return $Global:MockJsonContentForCert } -Verifiable
        Mock ConvertFrom-Json { param($InputObject) return $Global:MockCertConfigObject } -Verifiable
        
        Mock Test-Path { param($Path)
            Write-Verbose "Mock Test-Path for Certs for $Path"
            if ($Path -like "*\config\security-baseline.json") { return $true }
            if ($Path -like "C:\certs\*" -or $Path -like "Cert:\LocalMachine\*") { return $true }
            return $false 
        } -Verifiable
        
        Mock Get-ChildItem { param([string]$Path, [switch]$Recurse) 
            Write-Verbose "Mock Get-ChildItem for Certs for $Path"
            $null = $Global:MockedGetChildItemPaths.Add($Path)

            $Global:LastMockCertificatesByStoreCount = if ($null -ne $Global:MockCertificatesByStore) { $Global:MockCertificatesByStore.Count } else { -1 }
            $Global:LastMockCertificatesByStoreKeys = if ($null -ne $Global:MockCertificatesByStore) { @($Global:MockCertificatesByStore.Keys) } else { @() }

            if ($null -ne $Global:MockCertificatesByStore) {
                if ($Global:MockCertificatesByStore.ContainsKey($Path)) {
                    $Global:LastMockCertificatesReturnCount = @($Global:MockCertificatesByStore[$Path]).Count
                    $first = @($Global:MockCertificatesByStore[$Path]) | Select-Object -First 1
                    $Global:LastMockCertificateType = if ($null -ne $first) { $first.GetType().FullName } else { '<null>' }
                    $Global:LastMockCertificatePSIsContainer = if ($null -ne $first) { $first.PSIsContainer } else { $null }
                    return $Global:MockCertificatesByStore[$Path]
                }

                $normalizedPath = ($Path -replace '[\\/]+$','')
                foreach ($key in @($Global:MockCertificatesByStore.Keys)) {
                    $normalizedKey = ([string]$key -replace '[\\/]+$','')
                    if ($normalizedKey -ieq $normalizedPath) {
                        return $Global:MockCertificatesByStore[$key]
                    }
                }
            }
            return @() 
        } -Verifiable

        Mock Import-Certificate { param($FilePath, $CertStoreLocation) 
            Write-Verbose "Mock Import-Certificate for $FilePath to $CertStoreLocation"
        } -Verifiable
        
        Mock Test-Certificate {
            param(
                $Cert,
                [switch]$AllowUntrustedRoot
            )
            Write-Verbose "Mock Test-Certificate called"

            if ($null -ne $Cert -and ($Cert.PSObject.Properties.Name -contains '_IsValidForTestCertificate')) {
                $isValid = [bool]$Cert._IsValidForTestCertificate
                $status = if ($isValid) { 'Valid' } else { 'Revoked' }
                return [PSCustomObject]@{
                    IsValid = $isValid
                    Status = $status
                    StatusMessage = $status
                }
            }

            return [PSCustomObject]@{ IsValid = $true; Status = 'Valid'; StatusMessage = 'Valid' }
        } -Verifiable

        Mock Write-Host { } -Verifiable

        $sink = {
            param(
                [string]$Path,
                [string]$Value
            )
            $Global:MockedWriteLogMessages.Add($Value)
        }

        Set-Item -Path Function:Write-LogSink -Value $sink
        Set-Item -Path Function:global:Write-LogSink -Value $sink
    }

    Context 'Parameter Handling (Update-CertificateStore)' {
        It 'Should use JSON values for MinimumKeySize, Allowed/Disallowed Algorithms by default' {
            . $script:ScriptPathUpdateCert
            Assert-LogLike '*Effective MinimumKeySize: 2048*'
            Assert-LogLike '*Effective AllowedSignatureAlgorithms: sha256RSA, sha384RSA, ecdsa_secp256r1_sha256*'
            Assert-LogLike '*Effective DisallowedSignatureAlgorithms: md5RSA, sha1RSA*'
        }

        It 'Should override MinimumKeySize with parameter' {
            . $script:ScriptPathUpdateCert -MinimumKeySizeOverride 4096
            Assert-LogLike '*Effective MinimumKeySize: 4096*'
        }

        It 'Should override AllowedSignatureAlgorithms with parameter' {
            . $script:ScriptPathUpdateCert -AllowedSignatureAlgorithmsOverride @("ecdsa_secp384r1_sha384")
            Assert-LogLike '*Effective AllowedSignatureAlgorithms: ecdsa_secp384r1_sha384*'
        }
        
        It 'Should not update root certificates if -UpdateRootCertificates $false' {
            . $script:ScriptPathUpdateCert -UpdateRootCertificates $false
            Assert-MockCalled Import-Certificate -Scope It -Times 0
            Assert-LogLike '*Skipping root certificate update*'
        }

        It 'Should not validate existing certificates if -ValidateChain $false' {
            $mockCert = New-MockCertificate
            Mock Get-ChildItem -MockWith { param($Path) if ($Path -eq 'Cert:\LocalMachine\My') { return @($mockCert) } return @() }
            
            . $script:ScriptPathUpdateCert -ValidateChain $false
            Assert-LogNotLike "*Analyzing certificate: Subject='CN=TestCert'*"
            Assert-LogLike '*Skipping certificate validation*'
        }
    }

    Context 'Root Certificate Updates (Update-CertificateStore)' {
        It 'Should attempt to import a required cert if not found in store and sourcePath exists' {
            Mock Test-Path -MockWith { param($PathValue) 
                if ($PathValue -like "*\config\security-baseline.json") { return $true }
                if ($PathValue -eq "Cert:\LocalMachine\Root\THUMBPRINT1") { Write-Verbose "Mock Test-Path returning FALSE for THUMBPRINT1"; return $false } 
                if ($PathValue -eq "C:\certs\TestRoot1.cer") { Write-Verbose "Mock Test-Path returning TRUE for C:\certs\TestRoot1.cer"; return $true } 
                if ($PathValue -like "Cert:\LocalMachine\*") { return $true } 
                return $false
            }

            . $script:ScriptPathUpdateCert -UpdateRootCertificates $true
            
            Assert-MockCalled Import-Certificate -Scope It -Times 1 -ParameterFilter {
                $FilePath -eq "C:\certs\TestRoot1.cer" -and $CertStoreLocation -eq "Cert:\LocalMachine\Root"
            }
            Assert-LogLike '*Attempting to import THUMBPRINT1 from C:\certs\TestRoot1.cer*'
        }

        It 'Should NOT import a required cert if already found in store' {
             Mock Test-Path -MockWith { param($PathValue)
                if ($PathValue -eq "Cert:\LocalMachine\Root\THUMBPRINT1") { return $true } 
                if ($PathValue -eq "C:\certs\TestRoot1.cer") { return $true } 
                return $true 
            }
            . $script:ScriptPathUpdateCert -UpdateRootCertificates $true
            Assert-MockCalled Import-Certificate -Scope It -Times 0
            Assert-LogLike '*Required certificate THUMBPRINT1*already exists*'
        }

        It 'Should log ERROR if required cert sourcePath does NOT exist' { 
            Mock Test-Path -MockWith { param($PathValue)
                if ($PathValue -eq "Cert:\LocalMachine\Root\THUMBPRINT1") { return $false } 
                if ($PathValue -eq "C:\certs\TestRoot1.cer") { return $false } 
                return $true
            }
            . $script:ScriptPathUpdateCert -UpdateRootCertificates $true
            Assert-MockCalled Import-Certificate -Scope It -Times 0
            Assert-LogLike "*Source path for certificate THUMBPRINT1*is not defined or invalid: 'C:\certs\TestRoot1.cer'*"
        }
    }

    Context 'Existing Certificate Validation (Update-CertificateStore)' {
        It 'Should PASS a compliant certificate' {
            $mockGoodCert = New-MockCertificate -Subject "CN=GoodCert" -KeySize 2048 -SignatureAlgorithmFriendlyName "sha256RSA" -PSParentPath "Cert:\LocalMachine\My"
            $Global:MockCertificatesByStore['Cert:\LocalMachine\My'] = @($mockGoodCert)
            . $script:ScriptPathUpdateCert -ValidateChain $true
            Assert-LogLike "*Key size validation PASSED for $($mockGoodCert.Thumbprint)*"
            Assert-LogLike "*Signature algorithm validation PASSED for $($mockGoodCert.Thumbprint)*"
            Assert-LogLike "*Chain validation PASSED for $($mockGoodCert.Thumbprint)*"
        }

        It 'Should WARN for certificate with key size smaller than MinimumKeySize' {
            $mockSmallKeyCert = New-MockCertificate -Subject "CN=SmallKeyCert" -KeySize 1024 -SignatureAlgorithmFriendlyName "sha256RSA" -PSParentPath "Cert:\LocalMachine\My"
            $Global:MockCertificatesByStore['Cert:\LocalMachine\My'] = @($mockSmallKeyCert)
            . $script:ScriptPathUpdateCert -ValidateChain $true
            Assert-LogLike "*Key size validation FAILED for $($mockSmallKeyCert.Thumbprint): Actual 1024-bit < Minimum 2048-bit*"
        }

        It 'Should WARN for certificate with a disallowed signature algorithm' {
            $mockBadAlgoCert = New-MockCertificate -Subject "CN=BadAlgoCert" -KeySize 2048 -SignatureAlgorithmFriendlyName "md5RSA" -PSParentPath "Cert:\LocalMachine\My"
            $Global:MockCertificatesByStore['Cert:\LocalMachine\My'] = @($mockBadAlgoCert)
            . $script:ScriptPathUpdateCert -ValidateChain $true
            Assert-LogLike "*Signature algorithm validation FAILED for $($mockBadAlgoCert.Thumbprint): 'md5RSA' is disallowed*"
        }
        
        It 'Should WARN for certificate not in allowed signature algorithm list (if list is restrictive)' {
            $restrictedCertSettings = $Global:MockCertSettings.PSObject.Copy() 
            $restrictedCertSettings.certificateSettings.allowedSignatureAlgorithms = @("sha256RSA") 
            $MockJsonContentForCertRestricted = ConvertTo-Json -InputObject $restrictedCertSettings -Depth 8
            Mock Get-Content { return $MockJsonContentForCertRestricted }

            $restrictedConfigObject = [PSCustomObject]@{
                certificateSettings = [PSCustomObject]@{
                    minimumKeySize = $Global:MockCertSettings.certificateSettings.minimumKeySize
                    allowedSignatureAlgorithms = @('sha256RSA')
                    disallowedSignatureAlgorithms = $Global:MockCertSettings.certificateSettings.disallowedSignatureAlgorithms
                    requiredCertificates = $Global:MockCertSettings.certificateSettings.requiredCertificates
                    certificateValidation = $Global:MockCertSettings.certificateSettings.certificateValidation
                    certificateStoresToValidate = $Global:MockCertSettings.certificateSettings.certificateStoresToValidate
                }
            }
            Mock ConvertFrom-Json { param($InputObject) return $restrictedConfigObject }

            $nonListedAlgoCert = New-MockCertificate -Subject "CN=NonListedAlgo" -SignatureAlgorithmFriendlyName "sha384RSA" -PSParentPath "Cert:\LocalMachine\My"
            $Global:MockCertificatesByStore['Cert:\LocalMachine\My'] = @($nonListedAlgoCert)
            
            . $script:ScriptPathUpdateCert -ValidateChain $true
            Assert-LogLike "*Signature algorithm validation FAILED for $($nonListedAlgoCert.Thumbprint): 'sha384RSA' is not in the allowed list*"
        }

        It 'Should WARN for certificate that fails Test-Certificate chain validation' {
            $mockInvalidChainCert = New-MockCertificate -Subject "CN=InvalidChainCert" -KeySize 2048 -SignatureAlgorithmFriendlyName "sha256RSA" -PSParentPath "Cert:\LocalMachine\My" -IsValidForTestCertificate $false
            $Global:MockCertificatesByStore['Cert:\LocalMachine\My'] = @($mockInvalidChainCert)
            . $script:ScriptPathUpdateCert -ValidateChain $true
            Assert-LogLike "*Chain validation FAILED for $($mockInvalidChainCert.Thumbprint).*Revoked*"
        }
    }
}

Describe 'Set-FirewallRules.ps1 Tests' {
    $TestScriptRoot = $PSScriptRoot
    $ScriptPathFirewall = Join-Path $TestScriptRoot '..\..\..\src\Powershell\security\Set-FirewallRules.ps1'

    BeforeAll {
        $script:ScriptPathFirewall = Join-Path $PSScriptRoot '..\..\..\src\Powershell\security\Set-FirewallRules.ps1'
        . (Join-Path $PSScriptRoot '..\..\..\src\Powershell\utils\Write-Log.ps1')
    }

    $Global:MockFirewallSettings = @{
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
    $Global:MockJsonContentForFirewall = ConvertTo-Json -InputObject $Global:MockFirewallSettings -Depth 5
    
    $Global:isAdmin = $true 

    BeforeEach {
        $Global:MockedWriteLogMessages.Clear()
        $Global:MockedNetshExportCommand = $null 
        $Global:isAdmin = $true 

        . $Global:TestIsAdminPath
        . (Join-Path $PSScriptRoot '..\..\..\src\Powershell\utils\Invoke-NetFirewallRule.ps1')

        if ($null -eq $Global:MockFirewallConfigObject) {
            $Global:MockFirewallConfigObject = Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $Global:MockJsonContentForFirewall
        }

        Mock Test-IsAdministrator { return $true } -Verifiable

        Mock Get-Content { param($Path) Write-Verbose "Mock Get-Content for Firewall called for $Path"; return $Global:MockJsonContentForFirewall } -Verifiable
        Mock ConvertFrom-Json { param($InputObject) return $Global:MockFirewallConfigObject } -Verifiable
        
        Mock Test-Path { param($Path) Write-Verbose "Mock Test-Path for Firewall for $Path"; return $true } -Verifiable 
        Mock New-Item {
            param(
                [string]$Path,
                [string]$ItemType,
                [switch]$Force,
                $ErrorAction
            )
            Write-Verbose "Mock New-Item for Firewall for Path: $Path"
        } -Verifiable 
        
        Mock Invoke-Expression {
            param ([string]$Command)
            Write-Verbose "Mock Invoke-Expression for Firewall called with: $Command"
            if ($Command -like "netsh advfirewall export*") {
                $Global:MockedNetshExportCommand = $Command
            }
        } -Verifiable

        Mock Write-Host { } -Verifiable

        Mock Invoke-GetNetFirewallRule {
            param(
                [string]$DisplayName
            )
            Write-Verbose "Mock Invoke-GetNetFirewallRule for $DisplayName"
            return $null
        } -Verifiable

        Mock Invoke-NewNetFirewallRule {
            param(
                [hashtable]$Params
            )
            Write-Verbose "Mock Invoke-NewNetFirewallRule called with: $($Params | Out-String)"
        } -Verifiable

        Mock Invoke-SetNetFirewallRule {
            param(
                [hashtable]$Params
            )
            Write-Verbose "Mock Invoke-SetNetFirewallRule called with: $($Params | Out-String)"
        } -Verifiable
        
        $sink = {
            param(
                [string]$Path,
                [string]$Value
            )
            $Global:MockedWriteLogMessages.Add($Value)
        }

        Set-Item -Path Function:Write-LogSink -Value $sink
        Set-Item -Path Function:global:Write-LogSink -Value $sink
    }

    Context 'Administrator Check (Set-FirewallRules)' {
        It 'SKIPPED: Should log an error and throw if not run as Administrator (non-admin scenario is hard to simulate reliably under current Pester setup)' -Skip { }
    }

    Context 'Parameter Handling (Set-FirewallRules)' {
        It 'Should run with default parameters (EnforceRules=$true, BackupRules=$true)' {
            . $script:ScriptPathFirewall
            $Global:MockedNetshExportCommand | Should -Not -BeNullOrEmpty 
            Assert-MockCalled Invoke-NewNetFirewallRule -Scope It -Times $(@($Global:MockFirewallSettings.firewallRules.outbound).Count + @($Global:MockFirewallSettings.firewallRules.inbound).Count)
        }

        It 'Should NOT enforce rules if -EnforceRules $false' {
            . $script:ScriptPathFirewall -EnforceRules $false
            Assert-MockCalled Invoke-NewNetFirewallRule -Scope It -Times 0
            Assert-MockCalled Invoke-SetNetFirewallRule -Scope It -Times 0
            $Global:MockedNetshExportCommand | Should -BeNullOrEmpty 
        }

        It 'Should NOT attempt backup if -BackupRules $false (but still enforce)' {
               . $script:ScriptPathFirewall -BackupRules $false
             $Global:MockedNetshExportCommand | Should -BeNullOrEmpty
               Assert-MockCalled Invoke-NewNetFirewallRule -Scope It -Times $(@($Global:MockFirewallSettings.firewallRules.outbound).Count + @($Global:MockFirewallSettings.firewallRules.inbound).Count)
        }
    }

    Context 'Firewall Rule Processing (Set-FirewallRules)' {
        It 'Should CREATE a new OUTBOUND rule "Allow Azure Arc Management" if it does not exist' {
            . $script:ScriptPathFirewall
            Assert-MockCalled Invoke-NewNetFirewallRule -Scope It -Times 1 -ParameterFilter {
                $Params.DisplayName -eq 'Allow Azure Arc Management' -and
                $Params.Direction -eq 'Outbound' -and
                $Params.Action -eq 'Allow' -and
                $Params.Protocol -eq 'TCP' -and
                $Params.RemotePort -eq 443 -and
                $Params.RemoteAddress -eq '*.management.azure.com' -and
                $Params.Enabled -eq 'True'
            }
        }

        It 'Should CREATE a new OUTBOUND rule "Block Old App" with Action Block' {
            . $script:ScriptPathFirewall
            Assert-MockCalled Invoke-NewNetFirewallRule -Scope It -Times 1 -ParameterFilter {
                $Params.DisplayName -eq 'Block Old App' -and
                $Params.Direction -eq 'Outbound' -and
                $Params.Action -eq 'Block' -and 
                $Params.Protocol -eq 'TCP' -and
                $Params.RemotePort -eq 8080 -and
                $Params.RemoteAddress -eq 'old.app.com' -and
                $Params.Enabled -eq 'True'
            }
        }
        
        It 'Should CREATE a new INBOUND rule "Allow WinRM" and set Enabled based on "required=false"' {
            . $script:ScriptPathFirewall
            Assert-MockCalled Invoke-NewNetFirewallRule -Scope It -Times 1 -ParameterFilter {
                $Params.DisplayName -eq 'Allow WinRM' -and
                $Params.Direction -eq 'Inbound' -and
                $Params.Action -eq 'Allow' -and 
                $Params.Protocol -eq 'TCP' -and
                $Params.LocalPort -eq 5985 -and 
                $Params.RemoteAddress -eq '192.168.1.0/24' -and
                $Params.Enabled -eq 'False'
            }
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
            Mock Invoke-GetNetFirewallRule -MockWith { param($DisplayName)
                if($DisplayName -eq 'Allow Azure Arc Management') { return $existingRule }
                return $null
            }

            . $script:ScriptPathFirewall
            
            Assert-MockCalled Invoke-SetNetFirewallRule -Scope It -Times 1 -ParameterFilter {
                $Params.DisplayName -eq 'Allow Azure Arc Management' -and
                $Params.Direction -eq 'Outbound' -and 
                $Params.Action -eq 'Allow' -and
                $Params.Protocol -eq 'TCP' -and       
                $Params.RemotePort -eq 443 -and      
                $Params.RemoteAddress -eq '*.management.azure.com' -and 
                $Params.Enabled -eq 'True' -and      
                $Params.Profile -eq 'Any' 
            }
            Assert-MockCalled Invoke-NewNetFirewallRule -Scope It -ParameterFilter { $Params.DisplayName -eq 'Allow Azure Arc Management' } -Times 0 
        }
         It 'Should use specified Profile if provided in JSON for a new rule' {
            . $script:ScriptPathFirewall
            Assert-MockCalled Invoke-NewNetFirewallRule -Scope It -Times 1 -ParameterFilter {
                $Params.DisplayName -eq 'Allow Specific UDP' -and
                $Params.Profile -eq 'Any' 
            }
        }
    }

    Context 'Backup Logic (Set-FirewallRules)' {
        It 'Should call "netsh advfirewall export" when BackupRules is $true (default) and EnforceRules is $true (default)' {
            . $script:ScriptPathFirewall
            $Global:MockedNetshExportCommand | Should -Match "netsh advfirewall export `".*FirewallPolicyBackup-.*\.wfw`""
            Assert-MockCalled Invoke-Expression -Scope It -Times 1
        }

        It 'Should NOT call "netsh advfirewall export" when BackupRules is $false' {
            . $script:ScriptPathFirewall -BackupRules $false
            $Global:MockedNetshExportCommand | Should -BeNullOrEmpty
            Assert-MockCalled Invoke-Expression -Scope It -Times 0 -ParameterFilter {$_ -like "netsh advfirewall export*"}
        }
        
        It 'Should NOT call "netsh advfirewall export" when EnforceRules is $false' {
            . $script:ScriptPathFirewall -EnforceRules $false
            $Global:MockedNetshExportCommand | Should -BeNullOrEmpty
            Assert-MockCalled Invoke-Expression -Scope It -Times 0 -ParameterFilter {$_ -like "netsh advfirewall export*"}
        }
    }

    Context 'Logging Output (Set-FirewallRules)' {
        It 'Should log key actions' {
            . $script:ScriptPathFirewall
            Assert-LogLike '*Starting firewall configuration script*'
            Assert-LogLike '*Backing up current firewall policy to*'
            Assert-LogLike '*Processing outbound rules...*'
            Assert-LogLike "*Rule 'Allow Azure Arc Management' does not exist. Creating...*"
            Assert-LogLike '*Processing inbound rules...*'
            Assert-LogLike '*Firewall configuration script completed*'
        }
    }
}

Describe 'Set-AuditPolicies.ps1 Tests' {
    $TestScriptRoot = $PSScriptRoot
    $ScriptPathAudit = Join-Path $TestScriptRoot '..\..\..\src\Powershell\security\Set-AuditPolicies.ps1'

    BeforeAll {
        $script:ScriptPathAudit = Join-Path $PSScriptRoot '..\..\..\src\Powershell\security\Set-AuditPolicies.ps1'
        . (Join-Path $PSScriptRoot '..\..\..\src\Powershell\utils\Write-Log.ps1')
    }

    $Global:MockAuditSettings = @{
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
    $Global:MockJsonContentForAudit = ConvertTo-Json -InputObject $Global:MockAuditSettings -Depth 5

    BeforeEach {
        $Global:MockedWriteLogMessages.Clear()
        $Global:AuditpolCommands.Clear() # Use specific global for auditpol commands

        . $Global:TestIsAdminPath

        if ($null -eq $Global:MockAuditConfigObject) {
            $Global:MockAuditConfigObject = Microsoft.PowerShell.Utility\ConvertFrom-Json -InputObject $Global:MockJsonContentForAudit
        }

        Mock Test-IsAdministrator { return $true } -Verifiable

        Mock Get-Content { param($Path) Write-Verbose "Mock Get-Content for Audit called for $Path"; return $Global:MockJsonContentForAudit } -Verifiable
        Mock ConvertFrom-Json { param($InputObject) return $Global:MockAuditConfigObject } -Verifiable
        
        # Admin check - same challenge as Set-FirewallRules.ps1. Assume admin for most tests.
        # The script itself has the IsInRole check.
        
        Mock Test-Path { param($Path) Write-Verbose "Mock Test-Path for Audit for $Path"; return $true } -Verifiable 
        Mock New-Item { param([string]$Path, [string]$ItemType, [switch]$Force, $ErrorAction) Write-Verbose "Mock New-Item for Audit for $Path" } -Verifiable
        
        # Mock Invoke-Expression for auditpol calls
        Mock Invoke-Expression {
            param ([string]$Command)
            Write-Verbose "Mock Invoke-Expression for Audit called with: $Command"
            $Global:AuditpolCommands.Add($Command) # Store all calls for verification
            $global:LASTEXITCODE = 0
        } -Verifiable

        Mock Write-Host { } -Verifiable
        
        # Script checks $LASTEXITCODE directly; set it in the Invoke-Expression mock.


        $sink = {
            param(
                [string]$Path,
                [string]$Value
            )
            $Global:MockedWriteLogMessages.Add($Value)
        }

        Set-Item -Path Function:Write-LogSink -Value $sink
        Set-Item -Path Function:global:Write-LogSink -Value $sink
    }

    Context 'Administrator Check (Set-AuditPolicies)' {
        It 'SKIPPED: Should log an error and throw if not run as Administrator (non-admin scenario is hard to simulate reliably under current Pester setup)' -Skip { }
    }

    Context 'Parameter Handling (Set-AuditPolicies)' {
        It 'Should run with default parameters (EnforceSettings=$true, BackupSettings=$true)' {
            . $script:ScriptPathAudit
            ($Global:AuditpolCommands | Where-Object { $_ -match 'auditpol /backup /file:' }).Count | Should -Be 1
            ($Global:AuditpolCommands | Where-Object { $_ -match 'auditpol /set /subcategory:' }).Count | Should -Be 4 # For the 4 policies in mock JSON
        }

        It 'Should NOT enforce settings if -EnforceSettings $false' {
            . $script:ScriptPathAudit -EnforceSettings $false
            ($Global:AuditpolCommands | Where-Object { $_ -match 'auditpol /set /subcategory:' }).Count | Should -Be 0
            ($Global:AuditpolCommands | Where-Object { $_ -match 'auditpol /backup /file:' }).Count | Should -Be 0 # Script only backs up when BackupSettings and EnforceSettings are true
        }

        It 'Should NOT attempt backup if -BackupSettings $false (but still enforce)' {
               . $script:ScriptPathAudit -BackupSettings $false
             ($Global:AuditpolCommands | Where-Object { $_ -match 'auditpol /backup /file:' }).Count | Should -Be 0
             ($Global:AuditpolCommands | Where-Object { $_ -match 'auditpol /set /subcategory:' }).Count | Should -Be 4
        }
    }

    Context 'Audit Policy Processing (Set-AuditPolicies)' {
        It 'Should set "Credential Validation" to Success and Failure' {
            . $script:ScriptPathAudit
            @($Global:AuditpolCommands | Where-Object { $_ -eq 'auditpol /set /subcategory:"Credential Validation" /success:enable /failure:enable' }).Count | Should -BeGreaterThan 0
        }

        It 'Should set "Process Creation" to Success only' {
            . $script:ScriptPathAudit
            @($Global:AuditpolCommands | Where-Object { $_ -eq 'auditpol /set /subcategory:"Process Creation" /success:enable /failure:disable' }).Count | Should -BeGreaterThan 0
        }

        It 'Should set "Logon" to Failure only' { # Note: JSON key is "logon", script converts to "Logon"
            . $script:ScriptPathAudit
            @($Global:AuditpolCommands | Where-Object { $_ -eq 'auditpol /set /subcategory:"Logon" /success:disable /failure:enable' }).Count | Should -BeGreaterThan 0
        }

        It 'Should set "File System" to No Auditing (both disabled)' {
            . $script:ScriptPathAudit
            @($Global:AuditpolCommands | Where-Object { $_ -eq 'auditpol /set /subcategory:"File System" /success:disable /failure:disable' }).Count | Should -BeGreaterThan 0
        }
    }

    Context 'Backup Logic (Set-AuditPolicies)' {
        It 'Should call "auditpol /backup /file:" when BackupSettings and EnforceSettings are $true (default)' {
            . $script:ScriptPathAudit
            ($Global:AuditpolCommands | Where-Object { $_ -match 'auditpol /backup /file:".*AuditPolicyBackup-.*\.csv"' }).Count | Should -Be 1
        }

        It 'Should NOT call "auditpol /backup" when BackupSettings is $false' {
            . $script:ScriptPathAudit -BackupSettings $false
            ($Global:AuditpolCommands | Where-Object { $_ -match 'auditpol /backup /file:' }).Count | Should -Be 0
        }
        
        It 'Should NOT call "auditpol /backup" when EnforceSettings is $false (but BackupSettings is true - script logic)' {
            # The script logic is: if ($BackupSettings -and $EnforceSettings) { Backup-AuditPolicy }
            . $script:ScriptPathAudit -EnforceSettings $false # BackupSettings is $true by default
            ($Global:AuditpolCommands | Where-Object { $_ -match 'auditpol /backup /file:' }).Count | Should -Be 0
        }
    }

    Context 'Logging Output (Set-AuditPolicies)' {
        It 'Should log key actions' {
            . $script:ScriptPathAudit
            Assert-LogLike '*Starting audit policy configuration script*'
            Assert-LogLike '*Backing up current audit policy to*'
            Assert-LogLike "*Setting policy for Subcategory: 'Credential Validation' to 'Success,Failure'*"
            Assert-LogLike '*Executing: auditpol /set /subcategory:*Credential Validation* /success:enable /failure:enable*'
            Assert-LogLike '*Audit policy configuration script completed*'
        }
    }
}

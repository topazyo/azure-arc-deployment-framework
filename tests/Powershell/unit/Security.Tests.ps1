BeforeAll {
    # Import module and dependencies
    $modulePath = Join-Path $PSScriptRoot "..\..\..\src\PowerShell"
    Import-Module $modulePath\ArcDeploymentFramework.psd1 -Force

    # Mock configurations
    $mockConfig = @{
        ServerName = "TEST-SERVER"
        BaselinePath = ".\Config\security-baseline.json"
    }
}

Describe 'Test-SecurityCompliance' {
    BeforeAll {
        Mock Test-TLSCompliance { 
            return @{
                Compliant = $true
                Details = @()
            }
        }
        Mock Test-CertificateCompliance { 
            return @{
                Compliant = $true
                Details = @()
            }
        }
        Mock Test-ServiceAccountCompliance { 
            return @{
                Compliant = $true
                Details = @()
            }
        }
    }

    It 'Should pass when all security checks are compliant' {
        $result = Test-SecurityCompliance -ServerName $mockConfig.ServerName
        $result.CompliantStatus | Should -Be $true
        $result.SecurityScore | Should -Be 1.0
    }

    It 'Should fail when TLS is not compliant' {
        Mock Test-TLSCompliance { 
            return @{
                Compliant = $false
                Details = @("TLS 1.2 not enabled")
            }
        }
        
        $result = Test-SecurityCompliance -ServerName $mockConfig.ServerName
        $result.CompliantStatus | Should -Be $false
        $result.Checks | Should -Contain { $_.Category -eq "TLS" -and -not $_.Status }
    }

    It 'Should generate appropriate recommendations' {
        Mock Test-CertificateCompliance { 
            return @{
                Compliant = $false
                Details = @("Certificate expired")
            }
        }
        
        $result = Test-SecurityCompliance -ServerName $mockConfig.ServerName
        $result.Recommendations | Should -Not -BeNullOrEmpty
        $result.Recommendations | Should -Contain { $_.Category -eq "Certificates" }
    }
}

Describe 'Set-SecurityBaseline' {
    BeforeAll {
        Mock Backup-SecurityConfiguration { 
            return @{
                Path = "C:\Backup\Security"
                Timestamp = Get-Date
            }
        }
        Mock Set-TLSConfiguration { return @{ Success = $true } }
        Mock Set-ServiceAccountSecurity { return @{ Success = $true } }
        Mock Set-FirewallRules { return @{ Success = $true } }
    }

    It 'Should successfully apply security baseline' {
        $result = Set-SecurityBaseline -ServerName $mockConfig.ServerName
        $result.Status | Should -Be "Success"
        Should -Invoke Set-TLSConfiguration -Times 1
        Should -Invoke Set-ServiceAccountSecurity -Times 1
    }

    It 'Should take backup before applying changes' {
        $result = Set-SecurityBaseline -ServerName $mockConfig.ServerName
        $result.BackupPath | Should -Not -BeNullOrEmpty
        Should -Invoke Backup-SecurityConfiguration -Times 1
    }

    It 'Should rollback on failure' {
        Mock Set-TLSConfiguration { throw "Configuration failed" }
        Mock Restore-SecurityConfiguration { return @{ Success = $true } }
        
        $result = Set-SecurityBaseline -ServerName $mockConfig.ServerName
        $result.Status | Should -Be "Failed"
        Should -Invoke Restore-SecurityConfiguration -Times 1
    }
}

Describe 'Test-CertificateRequirements' {
    BeforeAll {
        Mock Test-RootCertificates { 
            return @{
                Valid = $true
                Details = @{
                    FoundCertificates = @()
                    MissingCertificates = @()
                }
            }
        }
        Mock Test-CertificateChain { 
            return @{
                Valid = $true
                Details = @()
            }
        }
    }

    It 'Should validate all certificate requirements' {
        $result = Test-CertificateRequirements -ServerName $mockConfig.ServerName
        $result.Success | Should -Be $true
        $result.Checks | Should -Contain { $_.Type -eq "RootCertificates" }
        $result.Checks | Should -Contain { $_.Type -eq "CertificateChain" }
    }

    It 'Should handle missing certificates' {
        Mock Test-RootCertificates { 
            return @{
                Valid = $false
                Details = @{
                    MissingCertificates = @("Required Root CA")
                }
            }
        }
        
        $result = Test-CertificateRequirements -ServerName $mockConfig.ServerName
        $result.Success | Should -Be $false
        $result.Checks | Should -Contain { $_.Type -eq "RootCertificates" -and -not $_.Status }
    }

    It 'Should perform remediation when specified' {
        Mock Install-RootCertificates { return @{ Success = $true } }
        
        $result = Test-CertificateRequirements -ServerName $mockConfig.ServerName -Remediate
        $result.Remediation | Should -Not -BeNullOrEmpty
        Should -Invoke Install-RootCertificates -Times 1
    }
}
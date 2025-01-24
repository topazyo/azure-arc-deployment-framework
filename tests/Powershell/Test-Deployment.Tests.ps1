BeforeAll {
    . $PSScriptRoot/../../src/PowerShell/Core/Deploy-ArcAgent.ps1
    . $PSScriptRoot/../../src/PowerShell/Core/Test-ArcPrerequisites.ps1
}

Describe 'Deploy-ArcAgent' {
    Context 'Pre-deployment validation' {
        It 'Should validate prerequisites before deployment' {
            Mock Test-ArcPrerequisites { return @{ Success = $true } }
            Mock Install-ArcAgent { return $true }

            $result = Deploy-ArcAgent -ServerName 'TestServer'
            Should -Invoke Test-ArcPrerequisites -Times 1
            $result.Success | Should -Be $true
        }

        It 'Should fail if prerequisites are not met' {
            Mock Test-ArcPrerequisites { return @{ Success = $false; Error = 'TLS 1.2 not enabled' } }

            $result = Deploy-ArcAgent -ServerName 'TestServer'
            $result.Success | Should -Be $false
            $result.Error | Should -Be 'TLS 1.2 not enabled'
        }
    }

    Context 'Deployment process' {
        It 'Should handle network errors gracefully' {
            Mock Test-ArcPrerequisites { return @{ Success = $true } }
            Mock Install-ArcAgent { throw 'Network timeout' }

            $result = Deploy-ArcAgent -ServerName 'TestServer'
            $result.Success | Should -Be $false
            $result.Error | Should -Match 'Network timeout'
        }

        It 'Should perform rollback on failure' {
            Mock Test-ArcPrerequisites { return @{ Success = $true } }
            Mock Install-ArcAgent { throw 'Installation failed' }
            Mock Invoke-Rollback { return $true }

            $result = Deploy-ArcAgent -ServerName 'TestServer'
            Should -Invoke Invoke-Rollback -Times 1
        }
    }
}
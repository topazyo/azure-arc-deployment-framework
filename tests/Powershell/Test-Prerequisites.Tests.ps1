Describe 'Test-ArcPrerequisites' {
    BeforeAll {
        . $PSScriptRoot/../../src/PowerShell/Core/Test-ArcPrerequisites.ps1
    }

    Context 'When checking server prerequisites' {
        It 'Should return success for valid server' {
            $result = Test-ArcPrerequisites -ServerName 'ValidServer'
            $result.Success | Should -Be $true
        }

        It 'Should check TLS configuration' {
            $result = Test-ArcPrerequisites -ServerName 'ValidServer'
            $result.TLSConfig | Should -Not -BeNullOrEmpty
        }

        It 'Should handle connection failures gracefully' {
            $result = Test-ArcPrerequisites -ServerName 'InvalidServer'
            $result.Success | Should -Be $false
            $result.Error | Should -Not -BeNullOrEmpty
        }
    }
}
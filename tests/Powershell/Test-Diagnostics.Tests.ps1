BeforeAll {
    . $PSScriptRoot/../../src/PowerShell/Core/Start-ArcDiagnostics.ps1
}

Describe 'Start-ArcDiagnostics' {
    Context 'System state collection' {
        It 'Should collect OS information' {
            $result = Start-ArcDiagnostics -ServerName 'TestServer'
            $result.SystemState.OS | Should -Not -BeNullOrEmpty
        }

        It 'Should collect network state' {
            $result = Start-ArcDiagnostics -ServerName 'TestServer'
            $result.SystemState.Network | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Detailed analysis' {
        It 'Should perform certificate validation' {
            $result = Start-ArcDiagnostics -ServerName 'TestServer' -DetailedScan
            $result.DetailedAnalysis.CertificateChain | Should -Not -BeNullOrEmpty
        }

        It 'Should check proxy configuration' {
            $result = Start-ArcDiagnostics -ServerName 'TestServer' -DetailedScan
            $result.DetailedAnalysis.ProxyConfiguration | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Error handling' {
        It 'Should handle unreachable servers' {
            Mock Test-Connection { return $false }
            
            $result = Start-ArcDiagnostics -ServerName 'UnreachableServer'
            $result.Success | Should -Be $false
            $result.Error | Should -Match 'Unable to connect'
        }
    }
}
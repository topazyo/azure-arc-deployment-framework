BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\..\..\src\Powershell\AzureArcFramework.psd1') -Force
    . (Join-Path $PSScriptRoot '..\..\..\src\Powershell\core\Start-ArcDiagnostics.ps1')
    . (Join-Path $PSScriptRoot '..\..\..\src\Powershell\utils\Write-Log.ps1')

    $testServer = "TestServer"
    $testWorkspaceId = "TestWorkspaceId"
    $env:ARC_DIAG_TESTDATA = '1'

    # Ensure helper commands exist for mocking
    $commandsToStub = @(
        'Get-SystemState','Get-ArcAgentConfig','Get-LastHeartbeat','Get-AMAConfig','Get-DataCollectionStatus',
        'Test-ArcConnectivity','Test-AMAConnectivity','Get-ProxyConfiguration','Test-NetworkPaths',
        'Get-ArcAgentLogs','Get-AMALogs','Get-SystemLogs','Get-SecurityLogs','Get-DCRAssociationStatus',
        'Test-CertificateTrust','Get-DetailedProxyConfig','Get-FirewallConfiguration','Get-PerformanceMetrics','Test-SecurityBaseline'
    )
    foreach ($cmd in $commandsToStub) {
        if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
            Set-Item -Path "Function:global:$cmd" -Value ([scriptblock]::Create("throw 'Command $cmd must be mocked in unit tests.'"))
        }
    }

    # Baseline mocks to keep diagnostics self-contained (overridden in contexts as needed)
    Mock Get-SystemState { @{ OS = @{ Version = "10.0.17763"; BuildNumber = "17763" }; Hardware = @{ CPU = @{ LoadPercentage = 10 }; Memory = @{ AvailableGB = 16 } } } }
    Mock Get-ArcAgentConfig { @{ Version = "1.0"; Settings = @{} } }
    Mock Get-LastHeartbeat { (Get-Date).AddMinutes(-5) }
    Mock Test-ArcConnectivity { @{ Success = $true } }
    Mock Test-AMAConnectivity { @{ Success = $true } }
    Mock Get-ProxyConfiguration { @{ ProxyServer = $null; ProxyPort = $null } }
    Mock Test-NetworkPaths { @() }
    Mock Get-ArcAgentLogs { @() }
    Mock Get-AMALogs { @() }
    Mock Get-SystemLogs { @() }
    Mock Get-SecurityLogs { @() }
    Mock Get-AMAConfig { @{ Version = "1.0" } }
    Mock Get-DataCollectionStatus { @{ Status = "Active"; LastHeartbeat = (Get-Date) } }
    Mock Get-DCRAssociationStatus { @{ State = "Enabled" } }
}

Describe 'Start-ArcDiagnostics' {
    Context 'System State Collection' {
        BeforeEach {
            Mock Get-SystemState {
                return @{
                    OS = @{
                        Version = "10.0.17763"
                        BuildNumber = "17763"
                    }
                    Hardware = @{
                        CPU = @{ LoadPercentage = 50 }
                        Memory = @{ AvailableGB = 8 }
                    }
                }
            }
        }

        It 'Should collect system state information' {
            $result = Start-ArcDiagnostics -ServerName $testServer
            $result.SystemState | Should -Not -BeNullOrEmpty
            $result.SystemState.OS.Version | Should -Be "10.0.17763"
        }

        It 'Should handle system state collection failures' {
            $env:ARC_DIAG_TESTDATA = '0'
            Mock Get-SystemState { throw "Collection error" }

            try {
                $result = Start-ArcDiagnostics -ServerName $testServer
            }
            finally {
                $env:ARC_DIAG_TESTDATA = '1'
            }
            $result.Error | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Arc Agent Status' {
        BeforeEach {
            Mock Get-Service {
                return [PSCustomObject]@{
                    Name = "himds"
                    Status = "Running"
                    StartType = "Automatic"
                }
            }
        }

        It 'Should check Arc agent service status' {
            $result = Start-ArcDiagnostics -ServerName $testServer
            $result.ArcStatus.ServiceStatus | Should -Be "Running"
        }

        It 'Should collect Arc agent configuration' {
            Mock Get-ArcAgentConfig {
                return @{
                    Version = "1.0"
                    Settings = @{}
                }
            }

            $result = Start-ArcDiagnostics -ServerName $testServer
            $result.ArcStatus.Configuration | Should -Not -BeNullOrEmpty
        }
    }

    Context 'AMA Status' {
        BeforeEach {
            Mock Get-Service {
                return [PSCustomObject]@{
                    Name = "AzureMonitorAgent"
                    Status = "Running"
                    StartType = "Automatic"
                }
            }
        }

        It 'Should check AMA service status when workspace provided' {
            $result = Start-ArcDiagnostics -ServerName $testServer -WorkspaceId $testWorkspaceId
            $result.AMAStatus.ServiceStatus | Should -Be "Running"
        }

        It 'Should collect AMA configuration' {
            Mock Get-AMAConfig {
                return @{
                    WorkspaceId = $testWorkspaceId
                    Settings = @{}
                }
            }

            $result = Start-ArcDiagnostics -ServerName $testServer -WorkspaceId $testWorkspaceId
            $result.AMAStatus.Configuration | Should -Not -BeNullOrEmpty
        }

        It 'Should check data collection status' {
            Mock Get-DataCollectionStatus {
                return @{
                    Status = "Active"
                    LastHeartbeat = (Get-Date)
                }
            }

            $result = Start-ArcDiagnostics -ServerName $testServer -WorkspaceId $testWorkspaceId
            $result.AMAStatus.DataCollection.Status | Should -Be "Active"
        }
    }

    Context 'Connectivity Tests' {
        It 'Should test all required endpoints' {
            Mock Test-NetworkPaths {
                return @(
                    @{
                        Endpoint = "Arc Management"
                        Success = $true
                    },
                    @{
                        Endpoint = "Log Analytics"
                        Success = $true
                    }
                )
            }

            $result = Start-ArcDiagnostics -ServerName $testServer
            $result.Connectivity | Should -Not -BeNullOrEmpty
            $result.Connectivity.Arc | Should -Not -BeNullOrEmpty
        }

        It 'Should include proxy configuration' {
            Mock Get-ProxyConfiguration {
                return @{
                    ProxyServer = "proxy.contoso.com"
                    ProxyPort = 8080
                }
            }

            $result = Start-ArcDiagnostics -ServerName $testServer
            $result.Connectivity.Proxy | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Log Collection' {
        It 'Should collect relevant logs' {
            Mock Get-ArcAgentLogs {
                return @{
                    LastLines = @("Log entry 1", "Log entry 2")
                    ErrorCount = 0
                }
            }

            $result = Start-ArcDiagnostics -ServerName $testServer
            $result.Logs.Arc | Should -Not -BeNullOrEmpty
        }

        It 'Should collect AMA logs when applicable' {
            Mock Get-AMALogs {
                return @{
                    LastLines = @("AMA log 1", "AMA log 2")
                    ErrorCount = 0
                }
            }

            $result = Start-ArcDiagnostics -ServerName $testServer -WorkspaceId $testWorkspaceId
            $result.Logs.AMA | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Detailed Analysis' {
        It 'Should perform detailed analysis when requested' {
            Mock Test-CertificateTrust { return @{ Valid = $true } }
            Mock Get-DetailedProxyConfig { return @{ } }
            Mock Get-FirewallConfiguration { return @{ } }
            Mock Get-PerformanceMetrics { return @{ } }

            $result = Start-ArcDiagnostics -ServerName $testServer -DetailedScan
            $result.DetailedAnalysis | Should -Not -BeNullOrEmpty
        }
    }

    Context 'Error Handling and Logging' {
        It 'Should log diagnostic activities' {
            Mock Write-Log { }

            Start-ArcDiagnostics -ServerName $testServer
            Should -Invoke Write-Log -ParameterFilter { 
                $Level -eq 'Information' -and $Message -match 'Starting diagnostic collection'
            }
        }

        It 'Should handle and log errors appropriately' {
            $env:ARC_DIAG_TESTDATA = '0'
            Mock Write-Log { }
            Mock Get-SystemState { throw "Test error" }

            try {
                $result = Start-ArcDiagnostics -ServerName $testServer
            }
            finally {
                $env:ARC_DIAG_TESTDATA = '1'
            }
            Should -Invoke Write-Log -ParameterFilter { 
                $Level -eq 'Error' -and $Message -match 'Test error'
            }
            $result.Error | Should -Not -BeNullOrEmpty
        }
    }
}
BeforeAll {
    # Import module and dependencies
    $modulePath = Join-Path $PSScriptRoot "..\..\..\src\PowerShell"
    Import-Module $modulePath\ArcDeploymentFramework.psd1 -Force

    # Mock configurations
    $mockConfig = @{
        ServerName = "TEST-SERVER"
        WorkspaceId = "mock-workspace-id"
    }
}

Describe 'Get-AMAHealthStatus' {
    BeforeAll {
        Mock Get-Service { 
            return [PSCustomObject]@{
                Name = "AzureMonitorAgent"
                Status = "Running"
                StartType = "Automatic"
            }
        }
        Mock Get-AMADataCollectionStatus { 
            return @{
                IngestionStatus = "Active"
                LastIngestionTime = (Get-Date).AddMinutes(-5)
            }
        }
    }

    It 'Should return comprehensive health status' {
        $result = Get-AMAHealthStatus -ServerName $mockConfig.ServerName -WorkspaceId $mockConfig.WorkspaceId
        $result.AgentStatus | Should -Not -BeNullOrEmpty
        $result.DataCollection | Should -Not -BeNullOrEmpty
        $result.OverallHealth | Should -Be "Healthy"
    }

    It 'Should detect agent issues' {
        Mock Get-Service { 
            return [PSCustomObject]@{
                Name = "AzureMonitorAgent"
                Status = "Stopped"
                StartType = "Automatic"
            }
        }
        
        $result = Get-AMAHealthStatus -ServerName $mockConfig.ServerName -WorkspaceId $mockConfig.WorkspaceId
        $result.OverallHealth | Should -Be "Critical"
        $result.Issues | Should -Contain { $_.Type -eq "Service" }
    }

    It 'Should detect data collection issues' {
        Mock Get-AMADataCollectionStatus { 
            return @{
                IngestionStatus = "Inactive"
                LastIngestionTime = (Get-Date).AddHours(-1)
            }
        }
        
        $result = Get-AMAHealthStatus -ServerName $mockConfig.ServerName -WorkspaceId $mockConfig.WorkspaceId
        $result.Issues | Should -Contain { $_.Type -eq "DataCollection" }
    }
}

Describe 'Test-LogIngestion' {
    BeforeAll {
        Mock Invoke-AzOperationalInsightsQuery {
            return @{
                Results = @{
                    LastHeartbeat = (Get-Date).AddMinutes(-5)
                    HeartbeatCount = 10
                    HeartbeatStatus = "Healthy"
                }
            }
        }
    }

    It 'Should validate log ingestion status' {
        $result = Test-LogIngestion -ServerName $mockConfig.ServerName -WorkspaceId $mockConfig.WorkspaceId
        $result.Status | Should -Be "Healthy"
        $result.Metrics.Heartbeat.Status | Should -Be "Healthy"
    }

    It 'Should detect ingestion delays' {
        Mock Invoke-AzOperationalInsightsQuery {
            return @{
                Results = @{
                    LastHeartbeat = (Get-Date).AddHours(-1)
                    HeartbeatCount = 5
                    HeartbeatStatus = "Delayed"
                }
            }
        }
        
        $result = Test-LogIngestion -ServerName $mockConfig.ServerName -WorkspaceId $mockConfig.WorkspaceId
        $result.Status | Should -Be "Unhealthy"
        $result.Metrics.Heartbeat.Status | Should -Be "Delayed"
    }

    It 'Should handle query failures' {
        Mock Invoke-AzOperationalInsightsQuery { throw "Query failed" }
        
        $result = Test-LogIngestion -ServerName $mockConfig.ServerName -WorkspaceId $mockConfig.WorkspaceId
        $result.Status | Should -Be "Error"
        $result.Error | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-AMAPerformanceMetrics' {
    BeforeAll {
        Mock Get-Counter {
            return [PSCustomObject]@{
                CounterSamples = @(
                    @{ Path = "\Process(AzureMonitorAgent)\% Processor Time"; CookedValue = 5 },
                    @{ Path = "\Process(AzureMonitorAgent)\Working Set"; CookedValue = 100MB }
                )
            }
        }
    }

    It 'Should collect performance metrics' {
        $result = Get-AMAPerformanceMetrics -ServerName $mockConfig.ServerName
        $result.Summary.CPUUsage | Should -Not -BeNullOrEmpty
        $result.Summary.MemoryUsageMB | Should -Not -BeNullOrEmpty
    }

    It 'Should generate recommendations when thresholds exceeded' {
        Mock Get-Counter {
            return [PSCustomObject]@{
                CounterSamples = @(
                    @{ Path = "\Process(AzureMonitorAgent)\% Processor Time"; CookedValue = 90 },
                    @{ Path = "\Process(AzureMonitorAgent)\Working Set"; CookedValue = 1GB }
                )
            }
        }
        
        $result = Get-AMAPerformanceMetrics -ServerName $mockConfig.ServerName
        $result.Recommendations | Should -Not -BeNullOrEmpty
        $result.Recommendations | Should -Contain { $_.Severity -eq "High" }
    }
}
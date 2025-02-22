BeforeAll {
    # Import module and dependencies
    $modulePath = Join-Path $PSScriptRoot "..\..\..\src\PowerShell"
    Import-Module $modulePath\ArcDeploymentFramework.psd1 -Force

    # Mock configurations
    $mockConfig = @{
        ServerName = "TEST-SERVER"
        WorkspaceId = "mock-workspace-id"
        WorkspaceKey = "mock-workspace-key"
    }
}

Describe 'Test-ArcPrerequisites' {
    BeforeAll {
        # Mock system commands
        Mock Get-WmiObject { 
            return [PSCustomObject]@{
                Version = "10.0.19041"
                BuildNumber = "19041"
                OSArchitecture = "64-bit"
            }
        }
        Mock Test-NetConnection { 
            return [PSCustomObject]@{
                ComputerName = $ComputerName
                TcpTestSucceeded = $true
                PingSucceeded = $true
            }
        }
        Mock Get-Service { 
            return [PSCustomObject]@{
                Name = "himds"
                Status = "Running"
                StartType = "Automatic"
            }
        }
    }

    It 'Should pass when all prerequisites are met' {
        $result = Test-ArcPrerequisites -ServerName $mockConfig.ServerName
        $result.Success | Should -Be $true
        $result.Checks.Count | Should -BeGreaterThan 0
    }

    It 'Should fail when OS version is not supported' {
        Mock Get-WmiObject { 
            return [PSCustomObject]@{
                Version = "6.1.7601"  # Windows Server 2008
                BuildNumber = "7601"
                OSArchitecture = "64-bit"
            }
        }
        $result = Test-ArcPrerequisites -ServerName $mockConfig.ServerName
        $result.Success | Should -Be $false
    }

    It 'Should fail when network connectivity check fails' {
        Mock Test-NetConnection { 
            return [PSCustomObject]@{
                ComputerName = $ComputerName
                TcpTestSucceeded = $false
                PingSucceeded = $false
            }
        }
        $result = Test-ArcPrerequisites -ServerName $mockConfig.ServerName
        $result.Success | Should -Be $false
    }

    It 'Should include workspace validation when WorkspaceId is provided' {
        $result = Test-ArcPrerequisites -ServerName $mockConfig.ServerName -WorkspaceId $mockConfig.WorkspaceId
        $result.Checks | Should -Contain 'LogAnalytics'
    }
}

Describe 'Deploy-ArcAgent' {
    BeforeAll {
        Mock Test-ArcPrerequisites { return @{ Success = $true } }
        Mock Install-ArcAgentInternal { return @{ Success = $true } }
        Mock Test-DeploymentHealth { return @{ Success = $true } }
        Mock Backup-ArcConfiguration { return @{ Path = "C:\Backup\Arc" } }
    }

    It 'Should successfully deploy Arc agent' {
        $result = Deploy-ArcAgent -ServerName $mockConfig.ServerName
        $result.Status | Should -Be "Success"
        Should -Invoke Test-ArcPrerequisites -Times 1
        Should -Invoke Install-ArcAgentInternal -Times 1
    }

    It 'Should handle deployment failure gracefully' {
        Mock Install-ArcAgentInternal { throw "Installation failed" }
        Mock Restore-ArcConfiguration { return @{ Success = $true } }

        $result = Deploy-ArcAgent -ServerName $mockConfig.ServerName
        $result.Status | Should -Be "Failed"
        $result.Error | Should -Not -BeNullOrEmpty
        Should -Invoke Restore-ArcConfiguration -Times 1
    }

    It 'Should deploy AMA when specified' {
        Mock Install-AMAExtension { return @{ Success = $true } }
        
        $result = Deploy-ArcAgent -ServerName $mockConfig.ServerName -DeployAMA -WorkspaceId $mockConfig.WorkspaceId
        $result.Status | Should -Be "Success"
        $result.AMADeployed | Should -Be $true
        Should -Invoke Install-AMAExtension -Times 1
    }
}

Describe 'Start-ArcDiagnostics' {
    BeforeAll {
        Mock Get-Service { 
            return [PSCustomObject]@{
                Name = "himds"
                Status = "Running"
                StartType = "Automatic"
            }
        }
        Mock Get-ArcAgentConfig { return @{ Version = "1.0" } }
        Mock Test-ArcConnectivity { return @{ Success = $true } }
    }

    It 'Should collect all diagnostic information' {
        $result = Start-ArcDiagnostics -ServerName $mockConfig.ServerName
        $result.SystemState | Should -Not -BeNullOrEmpty
        $result.ArcStatus | Should -Not -BeNullOrEmpty
        $result.Connectivity | Should -Not -BeNullOrEmpty
    }

    It 'Should include AMA diagnostics when specified' {
        Mock Get-Service { 
            return [PSCustomObject]@{
                Name = "AzureMonitorAgent"
                Status = "Running"
                StartType = "Automatic"
            }
        }
        
        $result = Start-ArcDiagnostics -ServerName $mockConfig.ServerName -WorkspaceId $mockConfig.WorkspaceId
        $result.AMAStatus | Should -Not -BeNullOrEmpty
    }

    It 'Should handle diagnostic collection failures' {
        Mock Get-Service { throw "Service query failed" }
        
        $result = Start-ArcDiagnostics -ServerName $mockConfig.ServerName
        $result.Error | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-ArcAnalysis' {
    BeforeAll {
        $mockDiagnosticData = @{
            ServerName = $mockConfig.ServerName
            SystemState = @{
                OS = @{ Version = "10.0.19041" }
                Memory = @{ Available = "8GB" }
            }
            ArcStatus = @{
                Service = "Running"
                LastHeartbeat = (Get-Date).AddMinutes(-5)
            }
        }
    }

    It 'Should analyze diagnostic data and provide insights' {
        $result = Invoke-ArcAnalysis -DiagnosticData $mockDiagnosticData
        $result.Findings | Should -Not -BeNullOrEmpty
        $result.Recommendations | Should -Not -BeNullOrEmpty
    }

    It 'Should include AMA analysis when specified' {
        $mockDiagnosticData.AMAStatus = @{
            Service = "Running"
            DataCollection = "Active"
        }
        
        $result = Invoke-ArcAnalysis -DiagnosticData $mockDiagnosticData -IncludeAMA
        $result.Findings | Should -Contain 'AMA'
    }

    It 'Should calculate risk score correctly' {
        $result = Invoke-ArcAnalysis -DiagnosticData $mockDiagnosticData
        $result.RiskScore | Should -BeOfType [double]
        $result.RiskScore | Should -BeLessOrEqual 1.0
        $result.RiskScore | Should -BeGreaterOrEqual 0.0
    }
}
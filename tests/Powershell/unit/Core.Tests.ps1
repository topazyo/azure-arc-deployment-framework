BeforeAll {
    # Import module and dependencies
    $modulePath = Join-Path $PSScriptRoot "..\..\..\src\Powershell"
    Import-Module (Join-Path $modulePath 'AzureArcFramework.psd1') -Force

    $script:ModuleName = 'AzureArcFramework'

    # Use synthetic prerequisite data to avoid external dependencies during tests
    $env:ARC_PREREQ_TESTDATA = '1'

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
        # Mock for module and global scopes to avoid real WMI calls
        Mock Get-WmiObject -ModuleName $script:ModuleName -MockWith {
            param(
                [string]$Class,
                [string]$ComputerName,
                [string]$Filter
            )

            $className = if (-not [string]::IsNullOrEmpty($Class)) { $Class } elseif ($args.Count -gt 0) { [string]$args[0] } else { $null }

            if ($className -eq 'Win32_OperatingSystem') {
                return [PSCustomObject]@{
                    Version = '10.0.19041'
                    BuildNumber = '19041'
                    OSArchitecture = '64-bit'
                    Caption = 'Windows Server (Mock)'
                }
            }

            if ($className -eq 'Win32_LogicalDisk') {
                return [PSCustomObject]@{
                    FreeSpace = 10GB
                }
            }

            return $null
        }

        Mock Get-WmiObject -MockWith {
            param(
                [string]$Class,
                [string]$ComputerName,
                [string]$Filter
            )

            $className = if (-not [string]::IsNullOrEmpty($Class)) { $Class } elseif ($args.Count -gt 0) { [string]$args[0] } else { $null }

            if ($className -eq 'Win32_OperatingSystem') {
                return [PSCustomObject]@{
                    Version = '10.0.19041'
                    BuildNumber = '19041'
                    OSArchitecture = '64-bit'
                    Caption = 'Windows Server (Mock)'
                }
            }

            if ($className -eq 'Win32_LogicalDisk') {
                return [PSCustomObject]@{
                    FreeSpace = 10GB
                }
            }

            return $null
        }

        Mock Invoke-Command -ModuleName $script:ModuleName -MockWith { return [version]'5.1.0' }
        Mock Invoke-Command -MockWith { return [version]'5.1.0' }

        Mock Test-NetConnection -ModuleName $script:ModuleName -MockWith {
            return [PSCustomObject]@{
                ComputerName = $ComputerName
                TcpTestSucceeded = $true
                PingSucceeded = $true
            }
        }
        Mock Test-NetConnection -MockWith {
            return [PSCustomObject]@{
                ComputerName = $ComputerName
                TcpTestSucceeded = $true
                PingSucceeded = $true
            }
        }

        Mock Test-OSCompatibility -ModuleName $script:ModuleName -MockWith { return $true }
        Mock Test-TLSConfiguration -ModuleName $script:ModuleName -MockWith { return @{ Success = $true; Version = 'TLS1.2' } }
        Mock Test-LAWorkspace -ModuleName $script:ModuleName -MockWith { return @{ Success = $true; Details = 'Mock workspace OK' } }

        Mock Get-Service -ModuleName $script:ModuleName -MockWith {
            return [PSCustomObject]@{
                Name = 'himds'
                Status = 'Running'
                StartType = 'Automatic'
            }
        }

        Mock Get-Service -MockWith {
            return [PSCustomObject]@{
                Name = 'himds'
                Status = 'Running'
                StartType = 'Automatic'
            }
        }
    }

    It 'Should pass when all prerequisites are met' {
        $result = Test-ArcPrerequisites -ServerName $mockConfig.ServerName
        $result.Success | Should -Be $true
        $result.Checks.Count | Should -BeGreaterThan 0
    }

    It 'Should fail when OS version is not supported' {
        Mock Get-WmiObject -ModuleName $script:ModuleName -MockWith {
            param(
                [string]$Class,
                [string]$ComputerName,
                [string]$Filter
            )

            $className = if (-not [string]::IsNullOrEmpty($Class)) { $Class } elseif ($args.Count -gt 0) { [string]$args[0] } else { $null }

            if ($className -eq 'Win32_OperatingSystem') {
                return [PSCustomObject]@{
                    Version = "6.1.7601"  # Windows Server 2008
                    BuildNumber = "7601"
                    OSArchitecture = "64-bit"
                    Caption = 'Windows Server (Mock)'
                }
            }

            if ($className -eq 'Win32_LogicalDisk') {
                return [PSCustomObject]@{ FreeSpace = 10GB }
            }

            return $null
        }
        Mock Test-OSCompatibility -ModuleName $script:ModuleName -MockWith { return $false }
        $result = Test-ArcPrerequisites -ServerName $mockConfig.ServerName
        $result.Success | Should -Be $false
    }

    It 'Should fail when network connectivity check fails' {
        Mock Test-NetConnection -ModuleName $script:ModuleName -MockWith { 
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
        ($result.Checks.Component) | Should -Contain 'LogAnalytics'
    }
}

Describe 'Deploy-ArcAgent' {
    BeforeEach {
        Mock Test-ArcPrerequisites -ModuleName $script:ModuleName -MockWith { return @{ Success = $true } }
        Mock Install-ArcAgentInternal -ModuleName $script:ModuleName -MockWith { return @{ Success = $true } }
        Mock Test-DeploymentHealth -ModuleName $script:ModuleName -MockWith { return @{ Success = $true } }
        Mock Backup-ArcConfiguration -ModuleName $script:ModuleName -MockWith { return @{ Path = 'C:\Backup\Arc' } }
        Mock Restore-ArcConfiguration -ModuleName $script:ModuleName -MockWith { return @{ Success = $true } }
    }

    It 'Should successfully deploy Arc agent' {
        $result = Deploy-ArcAgent -ServerName $mockConfig.ServerName
        $result.Status | Should -Be "Success"
        Should -Invoke Test-ArcPrerequisites -ModuleName $script:ModuleName -Times 1
        Should -Invoke Install-ArcAgentInternal -ModuleName $script:ModuleName -Times 1
    }

    It 'Should handle deployment failure gracefully' {
        Mock Install-ArcAgentInternal -ModuleName $script:ModuleName -MockWith { throw 'Installation failed' }

        $result = Deploy-ArcAgent -ServerName $mockConfig.ServerName
        $result.Status | Should -Be "Failed"
        $result.Error | Should -Not -BeNullOrEmpty
        Should -Invoke Restore-ArcConfiguration -ModuleName $script:ModuleName -Times 1
    }

    It 'Should deploy AMA when specified' {
        Mock Install-ArcAgentInternal -ModuleName $script:ModuleName -MockWith { return @{ Success = $true } }
        Mock Install-AMAExtension -ModuleName $script:ModuleName -MockWith { return @{ Success = $true } }
        Mock Set-DataCollectionRules -ModuleName $script:ModuleName -MockWith { return @{ Status = 'Success'; Changes = @() } }
        
        $result = Deploy-ArcAgent -ServerName $mockConfig.ServerName -DeployAMA -WorkspaceId $mockConfig.WorkspaceId -WorkspaceKey $mockConfig.WorkspaceKey
        $result.Status | Should -Be "Success"
        $result.AMADeployed | Should -Be $true
        Should -Invoke Install-AMAExtension -ModuleName $script:ModuleName -Times 1
    }
}

Describe 'Start-ArcDiagnostics' {
    BeforeAll {
        Mock Get-Service -ModuleName $script:ModuleName -MockWith { 
            return [PSCustomObject]@{
                Name = "himds"
                Status = "Running"
                StartType = "Automatic"
                DependentServices = @()
            }
        }
        Mock Get-ArcAgentConfig -ModuleName $script:ModuleName -MockWith { return @{ Version = "1.0" } }
        Mock Get-LastHeartbeat -ModuleName $script:ModuleName -MockWith { return (Get-Date).AddMinutes(-5) }
        Mock Test-ArcConnectivity -ModuleName $script:ModuleName -MockWith { return @{ Success = $true } }
        Mock Test-AMAConnectivity -ModuleName $script:ModuleName -MockWith { return @{ Success = $true } }
        Mock Get-SystemState -ModuleName $script:ModuleName -MockWith { return @{ OS = @{ Version = '10.0.19041' } } }

        Mock Get-AMAConfig -ModuleName $script:ModuleName -MockWith { return @{ Version = '1.0' } }
        Mock Get-DataCollectionStatus -ModuleName $script:ModuleName -MockWith { return @{ Status = 'Active'; LastHeartbeat = (Get-Date) } }
        Mock Get-DCRAssociationStatus -ModuleName $script:ModuleName -MockWith { return @{ State = 'Enabled' } }

        Mock Get-ProxyConfiguration -ModuleName $script:ModuleName -MockWith { return @{ Proxy = $null } }
        Mock Test-NetworkPaths -ModuleName $script:ModuleName -MockWith { return @() }

        Mock Get-ArcAgentLogs -ModuleName $script:ModuleName -MockWith { return @() }
        Mock Get-AMALogs -ModuleName $script:ModuleName -MockWith { return @() }
        Mock Get-SystemLogs -ModuleName $script:ModuleName -MockWith { return @() }
        Mock Get-SecurityLogs -ModuleName $script:ModuleName -MockWith { return @() }
    }

    It 'Should collect all diagnostic information' {
        $result = Start-ArcDiagnostics -ServerName $mockConfig.ServerName
        $result.SystemState | Should -Not -BeNullOrEmpty
        $result.ArcStatus | Should -Not -BeNullOrEmpty
        $result.Connectivity | Should -Not -BeNullOrEmpty
    }

    It 'Should include AMA diagnostics when specified' {
        Mock Get-Service -ModuleName $script:ModuleName -MockWith { 
            return [PSCustomObject]@{
                Name = "AzureMonitorAgent"
                Status = "Running"
                StartType = "Automatic"
                DependentServices = @()
            }
        }
        
        $result = Start-ArcDiagnostics -ServerName $mockConfig.ServerName -WorkspaceId $mockConfig.WorkspaceId
        $result.AMAStatus | Should -Not -BeNullOrEmpty
    }

    It 'Should handle diagnostic collection failures' {
        Mock Get-Service -ModuleName $script:ModuleName -MockWith { throw "Service query failed" }
        
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
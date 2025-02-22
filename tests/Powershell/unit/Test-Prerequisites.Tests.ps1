BeforeAll {
    . $PSScriptRoot/../../src/PowerShell/Core/Test-ArcPrerequisites.ps1
    . $PSScriptRoot/../../src/PowerShell/Utils/Test-Connectivity.ps1
    . $PSScriptRoot/../../src/PowerShell/Utils/Write-Log.ps1

    $testServer = "TestServer"
    $testWorkspaceId = "TestWorkspaceId"
}

Describe 'Test-ArcPrerequisites' {
    Context 'System Requirements Validation' {
        It 'Should validate OS version compatibility' {
            Mock Get-WmiObject {
                return [PSCustomObject]@{
                    Version = '10.0.17763'
                    Caption = 'Microsoft Windows Server 2019'
                    BuildNumber = '17763'
                }
            }

            $result = Test-ArcPrerequisites -ServerName $testServer
            $result.Checks | Where-Object { $_.Component -eq 'OperatingSystem' } | 
                Select-Object -ExpandProperty Status | Should -Be $true
        }

        It 'Should validate PowerShell version' {
            Mock Invoke-Command {
                return [version]'5.1'
            } -ParameterFilter { $ScriptBlock.ToString() -match 'PSVersionTable' }

            $result = Test-ArcPrerequisites -ServerName $testServer
            $result.Checks | Where-Object { $_.Component -eq 'PowerShell' } | 
                Select-Object -ExpandProperty Status | Should -Be $true
        }

        It 'Should validate disk space requirements' {
            Mock Get-WmiObject {
                return [PSCustomObject]@{
                    FreeSpace = 10GB
                }
            } -ParameterFilter { $Class -eq 'Win32_LogicalDisk' }

            $result = Test-ArcPrerequisites -ServerName $testServer
            $result.Checks | Where-Object { $_.Component -eq 'DiskSpace' } | 
                Select-Object -ExpandProperty Status | Should -Be $true
        }
    }

    Context 'Network Connectivity Validation' {
        BeforeEach {
            Mock Test-NetConnection { 
                return [PSCustomObject]@{
                    ComputerName = $ComputerName
                    TcpTestSucceeded = $true
                    PingSucceeded = $true
                }
            }
        }

        It 'Should validate Arc endpoint connectivity' {
            $result = Test-ArcPrerequisites -ServerName $testServer
            $result.Checks | Where-Object { $_.Component -eq 'Network-Arc' } | 
                Select-Object -ExpandProperty Status | Should -Be $true
        }

        It 'Should validate AMA endpoint connectivity when workspace provided' {
            $result = Test-ArcPrerequisites -ServerName $testServer -WorkspaceId $testWorkspaceId
            $result.Checks | Where-Object { $_.Component -eq 'Network-AMA' } | 
                Select-Object -ExpandProperty Status | Should -Be $true
        }

        It 'Should handle network connectivity failures' {
            Mock Test-NetConnection { 
                return [PSCustomObject]@{
                    ComputerName = $ComputerName
                    TcpTestSucceeded = $false
                    PingSucceeded = $false
                }
            }

            $result = Test-ArcPrerequisites -ServerName $testServer
            $result.Success | Should -Be $false
        }
    }

    Context 'Workspace Validation' {
        It 'Should validate Log Analytics workspace when provided' {
            Mock Test-LAWorkspace {
                return @{
                    Success = $true
                    Details = "Workspace validation successful"
                }
            }

            $result = Test-ArcPrerequisites -ServerName $testServer -WorkspaceId $testWorkspaceId
            $result.Checks | Where-Object { $_.Component -eq 'LogAnalytics' } | 
                Select-Object -ExpandProperty Status | Should -Be $true
        }

        It 'Should handle workspace validation failures' {
            Mock Test-LAWorkspace {
                return @{
                    Success = $false
                    Details = "Invalid workspace ID"
                }
            }

            $result = Test-ArcPrerequisites -ServerName $testServer -WorkspaceId $testWorkspaceId
            $result.Checks | Where-Object { $_.Component -eq 'LogAnalytics' } | 
                Select-Object -ExpandProperty Status | Should -Be $false
        }
    }

    Context 'TLS Configuration' {
        It 'Should validate TLS 1.2 configuration' {
            Mock Test-TLSConfiguration {
                return @{
                    Success = $true
                    Version = "1.2"
                }
            }

            $result = Test-ArcPrerequisites -ServerName $testServer
            $result.Checks | Where-Object { $_.Component -eq 'TLS' } | 
                Select-Object -ExpandProperty Status | Should -Be $true
        }
    }

    Context 'Error Handling' {
        It 'Should handle WMI query failures gracefully' {
            Mock Get-WmiObject { throw "WMI error" }

            $result = Test-ArcPrerequisites -ServerName $testServer
            $result.Success | Should -Be $false
            $result.Error | Should -Not -BeNullOrEmpty
        }

        It 'Should log errors appropriately' {
            Mock Write-Log { }
            Mock Get-WmiObject { throw "Test error" }

            $result = Test-ArcPrerequisites -ServerName $testServer
            Should -Invoke Write-Log -ParameterFilter { 
                $Level -eq 'Error' -and $Message -match 'Test error'
            }
        }
    }
}
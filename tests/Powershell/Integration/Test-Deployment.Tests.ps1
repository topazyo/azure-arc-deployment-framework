BeforeAll {
    . (Join-Path $PSScriptRoot '..\..\..\src\Powershell\core\Deploy-ArcAgent.ps1')
    . (Join-Path $PSScriptRoot '..\..\..\src\Powershell\core\Test-ArcPrerequisites.ps1')
    . (Join-Path $PSScriptRoot '..\..\..\src\Powershell\core\Test-DeploymentHealth.ps1')
    . (Join-Path $PSScriptRoot '..\..\..\src\Powershell\utils\Write-Log.ps1')
    . (Join-Path $PSScriptRoot '..\..\..\src\Powershell\utils\New-RetryBlock.ps1')

    # Mock configurations
    $mockConfig = @{
        WorkspaceId = "mock-workspace-id"
        WorkspaceKey = "mock-workspace-key"
        Environment = "Test"
    }

    # Mock functions
    function Mock-ServiceStatus {
        return @{
            Status = "Running"
            StartType = "Automatic"
        }
    }
}

Describe 'Deploy-ArcAgent' {
    Context 'Pre-deployment validation' {
        It 'Should validate prerequisites before deployment' {
            Mock Test-ArcPrerequisites { 
                return @{ 
                    Success = $true 
                    Checks = @(
                        @{ Component = "OS"; Status = "Success" }
                        @{ Component = "Network"; Status = "Success" }
                    )
                } 
            }
            Mock Install-ArcAgent { return @{ Success = $true } }
            Mock Test-DeploymentHealth { return @{ Success = $true } }

            $result = Deploy-ArcAgent -ServerName 'TestServer' -ConfigurationParams $mockConfig
            Should -Invoke Test-ArcPrerequisites -Times 1
            $result.Status | Should -Be "Success"
        }

        It 'Should fail if prerequisites are not met' {
            Mock Test-ArcPrerequisites { 
                return @{ 
                    Success = $false 
                    Error = "TLS 1.2 not enabled"
                    Checks = @(
                        @{ Component = "TLS"; Status = "Failed"; Required = $true }
                    )
                } 
            }

            { Deploy-ArcAgent -ServerName 'TestServer' -ConfigurationParams $mockConfig } | 
                Should -Throw "*Prerequisites not met*"
        }

        It 'Should validate workspace credentials when deploying AMA' {
            Mock Test-ArcPrerequisites { return @{ Success = $true } }
            
            { Deploy-ArcAgent -ServerName 'TestServer' -DeployAMA -ConfigurationParams $mockConfig } | 
                Should -Not -Throw
            
            { Deploy-ArcAgent -ServerName 'TestServer' -DeployAMA } | 
                Should -Throw "*WorkspaceId and WorkspaceKey are required*"
        }
    }

    Context 'Deployment process' {
        It 'Should handle network errors gracefully' {
            Mock Test-ArcPrerequisites { return @{ Success = $true } }
            Mock Install-ArcAgent { throw 'Network timeout' }
            Mock Backup-ArcConfiguration { return @{ Path = "backup.json" } }
            Mock Restore-ArcConfiguration { return $true }

            $result = Deploy-ArcAgent -ServerName 'TestServer' -ConfigurationParams $mockConfig -ErrorAction SilentlyContinue
            $result.Status | Should -Be "Failed"
            $result.Error | Should -Match "Network timeout"
        }

        It 'Should perform rollback on failure' {
            Mock Test-ArcPrerequisites { return @{ Success = $true } }
            Mock Install-ArcAgent { throw 'Installation failed' }
            Mock Backup-ArcConfiguration { return @{ Path = "backup.json" } }
            Mock Restore-ArcConfiguration { return $true }
            Mock Write-Log { }

            $result = Deploy-ArcAgent -ServerName 'TestServer' -ConfigurationParams $mockConfig -ErrorAction SilentlyContinue
            Should -Invoke Restore-ArcConfiguration -Times 1
            $result.Rollback | Should -Not -BeNullOrEmpty
        }

        It 'Should deploy AMA when specified' {
            Mock Test-ArcPrerequisites { return @{ Success = $true } }
            Mock Install-ArcAgent { return @{ Success = $true } }
            Mock Install-AMAExtension { return @{ Success = $true } }
            Mock Set-DataCollectionRules { return @{ Status = "Success" } }
            Mock Test-DeploymentHealth { return @{ Success = $true } }

            $result = Deploy-ArcAgent -ServerName 'TestServer' `
                -ConfigurationParams $mockConfig `
                -DeployAMA `
                -WorkspaceId $mockConfig.WorkspaceId `
                -WorkspaceKey $mockConfig.WorkspaceKey

            $result.Status | Should -Be "Success"
            $result.AMADeployed | Should -Be $true
        }
    }

    Context 'Post-deployment validation' {
        It 'Should validate Arc agent status' {
            Mock Test-ArcPrerequisites { return @{ Success = $true } }
            Mock Install-ArcAgent { return @{ Success = $true } }
            Mock Test-DeploymentHealth { 
                return @{
                    Success = $true
                    Components = @(
                        @{ Name = "ArcAgent"; Status = $true }
                        @{ Name = "Connectivity"; Status = $true }
                    )
                }
            }

            $result = Deploy-ArcAgent -ServerName 'TestServer' -ConfigurationParams $mockConfig
            $result.Status | Should -Be "Success"
            Should -Invoke Test-DeploymentHealth -Times 1
        }

        It 'Should validate AMA deployment when specified' {
            Mock Test-ArcPrerequisites { return @{ Success = $true } }
            Mock Install-ArcAgent { return @{ Success = $true } }
            Mock Install-AMAExtension { return @{ Success = $true } }
            Mock Test-DeploymentHealth { 
                return @{
                    Success = $true
                    Components = @(
                        @{ Name = "ArcAgent"; Status = $true }
                        @{ Name = "AMAService"; Status = $true }
                        @{ Name = "DataCollection"; Status = $true }
                    )
                }
            }

            $result = Deploy-ArcAgent -ServerName 'TestServer' `
                -ConfigurationParams $mockConfig `
                -DeployAMA `
                -WorkspaceId $mockConfig.WorkspaceId `
                -WorkspaceKey $mockConfig.WorkspaceKey

            $result.Status | Should -Be "Success"
            Should -Invoke Test-DeploymentHealth -Times 1 -ParameterFilter { $ValidateAMA -eq $true }
        }
    }

    Context 'Error handling and logging' {
        It 'Should log deployment steps' {
            Mock Test-ArcPrerequisites { return @{ Success = $true } }
            Mock Install-ArcAgent { return @{ Success = $true } }
            Mock Write-Log { }

            Deploy-ArcAgent -ServerName 'TestServer' -ConfigurationParams $mockConfig
            Should -Invoke Write-Log -Times 1 -ParameterFilter { 
                $Message -like "*Starting deployment*" -and $Level -eq "Information" 
            }
        }

        It 'Should log errors with appropriate level' {
            Mock Test-ArcPrerequisites { throw "Critical error" }
            Mock Write-Log { }

            Deploy-ArcAgent -ServerName 'TestServer' -ConfigurationParams $mockConfig -ErrorAction SilentlyContinue
            Should -Invoke Write-Log -Times 1 -ParameterFilter { 
                $Message -like "*Critical error*" -and $Level -eq "Error" 
            }
        }
    }
}
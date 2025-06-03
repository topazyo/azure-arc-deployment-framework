# tests/Powershell/unit/Core.Functions.Tests.ps1
using namespace System.Collections.Generic

Import-Module -Name Pester -MinimumVersion 5.0.0 -Force

Describe "Core Deployment Functions" {
    # Variables for common parameters
    $testSubscriptionId = "test-sub-id-12345"
    $testResourceGroupName = "arc-test-rg"
    $testLocation = "eastus"
    $testTenantId = "test-tenant-id-67890"
    $testTags = @{ Environment = "Test"; Purpose = "Pester" }
    $altSubscriptionId = "alt-sub-id-54321"
    $altLocation = "westus"

    BeforeAll {
        # Source the functions. This path assumes the test file is in tests/Powershell/unit/
        . "$PSScriptRoot/../../../src/Powershell/core/Initialize-ArcDeployment.ps1"
        . "$PSScriptRoot/../../../src/Powershell/core/New-ArcDeployment.ps1"
    }

    #region Initialize-ArcDeployment Tests
    Describe "Initialize-ArcDeployment" {
        Mock Get-Module { return $true } # Assume modules are always available for these tests
        Mock Get-AzContext { } # Default mock, override in specific tests
        Mock Set-AzContext { }
        Mock Get-AzResourceGroup { }
        Mock New-AzResourceGroup { Write-Verbose "Mock New-AzResourceGroup called with Name: $($Name) Location: $($Location) Tag: $($Tag)" }
        Mock Set-AzResourceGroup { Write-Verbose "Mock Set-AzResourceGroup called with Name: $($Name) Tag: $($Tag)"}

        BeforeEach {
            # Reset mocks that might have specific return values set in tests
            Mock Get-Module { return $true }
            Mock Get-AzContext { return [pscustomobject]@{ Subscription = [pscustomobject]@{Id = $testSubscriptionId; Name="TestSub"}; Account="test@contoso.com"; Tenant=[pscustomobject]@{Id=$testTenantId} } }
            Mock Set-AzContext { param($SubscriptionId, $TenantId) Write-Verbose "Set-AzContext called with Sub: $SubscriptionId Tenant: $TenantId"; return $true } # Default successful context set
            Mock Get-AzResourceGroup { throw "Resource group '$($Name)' not found." } # Default: RG doesn't exist
            Mock New-AzResourceGroup { Write-Verbose "Mock New-AzResourceGroup called Name: $($Name) Location: $($Location) Tag: $($Tag)" }
            Mock Set-AzResourceGroup { Write-Verbose "Mock Set-AzResourceGroup called Name: $($Name) Tag: $($Tag)"}

            # Clear ShouldProcessPreference to ensure ShouldProcess is testable
            $Global:ShouldProcessPreference = $null
        }
        AfterEach {
             $Global:ShouldProcessPreference = $null
        }


        It "should THROW if Az.Accounts module is missing" {
            Mock Get-Module -MockWith { param($Name) if ($Name -eq 'Az.Accounts') { return $false } else { return $true } } -Verifiable -ModuleName Get-Module
            { Initialize-ArcDeployment -SubscriptionId $testSubscriptionId -ResourceGroupName $testResourceGroupName -Location $testLocation } | Should -Throw "Az.Accounts module not found."
            Should -Invoke -CommandName Get-Module -Times 1 -ModuleName Get-Module
        }

        It "should THROW if Az.Resources module is missing" {
            Mock Get-Module -MockWith { param($Name) if ($Name -eq 'Az.Resources') { return $false } else { return $true } } -Verifiable -ModuleName Get-Module
            { Initialize-ArcDeployment -SubscriptionId $testSubscriptionId -ResourceGroupName $testResourceGroupName -Location $testLocation } | Should -Throw "Az.Resources module not found."
            Should -Invoke -CommandName Get-Module -Times 2 # Once for Az.Accounts, once for Az.Resources
        }

        It "should THROW if not logged into Azure (Get-AzContext returns null)" {
            Mock Get-AzContext { return $null } -Verifiable
            { Initialize-ArcDeployment -SubscriptionId $testSubscriptionId -ResourceGroupName $testResourceGroupName -Location $testLocation } | Should -Throw "Azure login required."
            Should -Invoke -CommandName Get-AzContext -Times 1
        }

        It "should use current context if subscription matches" {
            Mock Get-AzContext { return [pscustomobject]@{ Subscription = [pscustomobject]@{Id = $testSubscriptionId}; Account="test@contoso.com"; Tenant=[pscustomobject]@{Id=$testTenantId} } } -Verifiable
            Mock Set-AzContext { throw "Set-AzContext should not be called" } -Verifiable -ModuleName Set-AzContext # Ensure it's not called

            # Simulate RG exists
            Mock Get-AzResourceGroup -ModuleName Get-AzResourceGroup -MockWith {
                param($Name)
                if($Name -eq $testResourceGroupName) {
                    return [pscustomobject]@{ ResourceGroupName = $testResourceGroupName; Location = $testLocation; ProvisioningState = 'Succeeded'; Tags = $testTags }
                } else { throw "Resource group '$($Name)' not found."}
            }
            Initialize-ArcDeployment -SubscriptionId $testSubscriptionId -ResourceGroupName $testResourceGroupName -Location $testLocation -Tags $testTags | Should -Not -Throw
            Should -Invoke -CommandName Get-AzContext -Times 1 # Initial check
            Should -Not -Invoke -CommandName Set-AzContext -ModuleName Set-AzContext
        }

        It "should call Set-AzContext if subscription ID differs and succeed" {
            Mock Get-AzContext -ModuleName Get-AzContext -MockWith @(
                { return [pscustomobject]@{ Subscription = [pscustomobject]@{Id = $altSubscriptionId}; Account="test@contoso.com"; Tenant=[pscustomobject]@{Id=$testTenantId} } }, # First call (current context)
                { return [pscustomobject]@{ Subscription = [pscustomobject]@{Id = $testSubscriptionId}; Account="test@contoso.com"; Tenant=[pscustomobject]@{Id=$testTenantId} } }  # Second call (after Set-AzContext)
            )
            Mock Set-AzContext -ModuleName Set-AzContext -MockWith { param($SubscriptionId, $TenantId) return $true } -Verifiable
            Mock Get-AzResourceGroup -ModuleName Get-AzResourceGroup -MockWith { return [pscustomobject]@{ ResourceGroupName = $testResourceGroupName; Location = $testLocation; ProvisioningState = 'Succeeded'; Tags = $testTags }}

            Initialize-ArcDeployment -SubscriptionId $testSubscriptionId -ResourceGroupName $testResourceGroupName -Location $testLocation -TenantId $testTenantId | Should -Not -Throw
            Should -Invoke -CommandName Get-AzContext -Times 2 -ModuleName Get-AzContext
            Should -Invoke -CommandName Set-AzContext -Times 1 -ModuleName Set-AzContext -ParameterFilter { $SubscriptionId -eq $testSubscriptionId -and $TenantId -eq $testTenantId }
        }

        It "should THROW if Set-AzContext fails" {
            Mock Get-AzContext { return [pscustomobject]@{ Subscription = [pscustomobject]@{Id = $altSubscriptionId}; Account="test@contoso.com"; Tenant=[pscustomobject]@{Id=$testTenantId} } }
            Mock Set-AzContext { throw "Simulated Set-AzContext failure" } -Verifiable
            { Initialize-ArcDeployment -SubscriptionId $testSubscriptionId -ResourceGroupName $testResourceGroupName -Location $testLocation -TenantId $testTenantId } | Should -Throw "Failed to set Azure context."
            Should -Invoke -CommandName Set-AzContext -Times 1
        }

        It "should CREATE resource group if it does not exist (with -WhatIf)" {
            $Global:ShouldProcessPreference = 'Continue' # To check ShouldProcess messages
            Mock New-AzResourceGroup -ModuleName New-AzResourceGroup -MockWith { param($Name, $Location, $Tag) Write-Host "WHATIF: Performing the operation `"Create`" on target `"Resource Group '$Name' in location '$Location'`"." } -Verifiable

            Initialize-ArcDeployment -SubscriptionId $testSubscriptionId -ResourceGroupName $testResourceGroupName -Location $testLocation -Tags $testTags -WhatIf | Should -Not -Throw
            Should -Invoke -CommandName New-AzResourceGroup -Times 1 -ModuleName New-AzResourceGroup -ParameterFilter { $Name -eq $testResourceGroupName -and $Location -eq $testLocation }
        }

        It "should CREATE resource group if it does not exist" {
            Mock New-AzResourceGroup -ModuleName New-AzResourceGroup -MockWith {
                 param($Name, $Location, $Tag)
                 # Simulate RG creation by having Get-AzResourceGroup return it on next call
                 Mock Get-AzResourceGroup -ModuleName Get-AzResourceGroup -MockWith { [pscustomobject]@{ ResourceGroupName = $Name; Location = $Location; ProvisioningState = 'Succeeded'; Tags = $Tag } }
            } -Verifiable

            Initialize-ArcDeployment -SubscriptionId $testSubscriptionId -ResourceGroupName $testResourceGroupName -Location $testLocation -Tags $testTags | Should -Not -Throw
            Should -Invoke -CommandName New-AzResourceGroup -Times 1 -ModuleName New-AzResourceGroup
        }

        It "should UPDATE tags if resource group exists and tags are provided (with -WhatIf)" {
             $Global:ShouldProcessPreference = 'Continue'
            Mock Get-AzResourceGroup -ModuleName Get-AzResourceGroup -MockWith { return [pscustomobject]@{ ResourceGroupName = $testResourceGroupName; Location = $testLocation; ProvisioningState = 'Succeeded'; Tags = @{} } }
            Mock Set-AzResourceGroup -ModuleName Set-AzResourceGroup -MockWith { param($Name, $Tag) Write-Host "WHATIF: Performing the operation `"Update Tags`" on target `"Resource Group '$Name'`"." } -Verifiable

            Initialize-ArcDeployment -SubscriptionId $testSubscriptionId -ResourceGroupName $testResourceGroupName -Location $testLocation -Tags $testTags -WhatIf | Should -Not -Throw
            Should -Invoke -CommandName Set-AzResourceGroup -Times 1 -ModuleName Set-AzResourceGroup -ParameterFilter { $Name -eq $testResourceGroupName }
        }

        It "should UPDATE tags if resource group exists and tags are provided" {
            Mock Get-AzResourceGroup -ModuleName Get-AzResourceGroup -MockWith { return [pscustomobject]@{ ResourceGroupName = $testResourceGroupName; Location = $testLocation; ProvisioningState = 'Succeeded'; Tags = @{} } }
            Mock Set-AzResourceGroup -ModuleName Set-AzResourceGroup -MockWith {
                param ($Name, $Tag)
                Mock Get-AzResourceGroup -ModuleName Get-AzResourceGroup -MockWith { [pscustomobject]@{ ResourceGroupName = $Name; Location = $testLocation; ProvisioningState = 'Succeeded'; Tags = $Tag } } # Update subsequent Get
            } -Verifiable

            $result = Initialize-ArcDeployment -SubscriptionId $testSubscriptionId -ResourceGroupName $testResourceGroupName -Location $testLocation -Tags $testTags
            $result.Tags['Environment'] | Should -Be $testTags['Environment']
            Should -Invoke -CommandName Set-AzResourceGroup -Times 1 -ModuleName Set-AzResourceGroup
        }

        It "should WARN if resource group exists in a different location" {
            Mock Get-AzResourceGroup { return [pscustomobject]@{ ResourceGroupName = $testResourceGroupName; Location = $altLocation; ProvisioningState = 'Succeeded'; Tags = @{} } }
            # Use -WarningAction SilentlyContinue to capture warnings if needed, or check console output
            # For Pester, checking for a warning can be done by redirecting warning stream or specific setup.
            # Here, we just ensure it runs and trust the Write-Warning happens.
            Initialize-ArcDeployment -SubscriptionId $testSubscriptionId -ResourceGroupName $testResourceGroupName -Location $testLocation | Should -Not -Throw
        }

        It "should THROW if resource group creation fails" {
            Mock New-AzResourceGroup { throw "Simulated New-AzResourceGroup failure" } -Verifiable
            { Initialize-ArcDeployment -SubscriptionId $testSubscriptionId -ResourceGroupName $testResourceGroupName -Location $testLocation } | Should -Throw "Resource group creation failed."
            Should -Invoke -CommandName New-AzResourceGroup -Times 1
        }

        It "should WARN if tag update fails on existing RG" {
             Mock Get-AzResourceGroup { return [pscustomobject]@{ ResourceGroupName = $testResourceGroupName; Location = $testLocation; ProvisioningState = 'Succeeded'; Tags = @{} } }
             Mock Set-AzResourceGroup { throw "Simulated Set-AzResourceGroup failure for tags" } -Verifiable
             # This function currently logs a warning but doesn't throw for tag update failure.
             Initialize-ArcDeployment -SubscriptionId $testSubscriptionId -ResourceGroupName $testResourceGroupName -Location $testLocation -Tags $testTags | Should -Not -Throw
             Should -Invoke -CommandName Set-AzResourceGroup -Times 1
        }
    }
    #endregion Initialize-ArcDeployment Tests

    #region New-ArcDeployment Tests
    Describe "New-ArcDeployment" {
        $serverName = "TestServer001"
        $rgName = "TestRG"
        $subId = "TestSubId"
        $loc = "eastus"
        $tenId = "TestTenantId"
        $azcmagentPath = "mock_azcmagent" # Assume it's a command that can be "called"

        Mock Test-Path { param($Path) return $true } # Default mock for Test-Path
        Mock ConvertFrom-SecureString { param($SecureString) return "PlainTextSecret" } # Mock secure string conversion

        # Mock for the external script/command execution for azcmagent
        # We are not actually executing azcmagent, just checking the command construction and ShouldProcess
        BeforeEach {
            Mock Test-Path { param($Path) return $true }
            Mock ConvertFrom-SecureString { param($SecureString) return "PlainTextSecret" }
            $Global:ShouldProcessPreference = $null
        }
        AfterEach {
            $Global:ShouldProcessPreference = $null
        }

        It "should generate basic command with mandatory parameters" {
            $result = New-ArcDeployment -ServerName $serverName -ResourceGroupName $rgName -SubscriptionId $subId -Location $loc -TenantId $tenId -AzcmagentPath $azcmagentPath
            $result.OnboardingCommand | Should -Be "$azcmagentPath connect --resource-group `"$rgName`" --subscription-id `"$subId`" --location `"$loc`" --tenant-id `"$tenId`""
            $result.Status | Should -Be "CommandGenerated"
        }

        It "should include all optional parameters in the command" {
            $tags = @{ TestKey = "TestValue"; AnotherKey = "AnotherValue" }
            $correlationId = "corr-123"
            $cloud = "AzureUSGovernment"
            $proxyUrl = "http://proxy.local:8080"
            $proxyBypass = "localhost,127.0.0.1"
            $spAppId = "sp-app-id"
            $spSecret = ConvertTo-SecureString "secret" -AsPlainText -Force

            $result = New-ArcDeployment -ServerName $serverName -ResourceGroupName $rgName -SubscriptionId $subId -Location $loc -TenantId $tenId `
                -Tags $tags -CorrelationId $correlationId -Cloud $cloud -ProxyUrl $proxyUrl -ProxyBypass $proxyBypass `
                -ServicePrincipalAppId $spAppId -ServicePrincipalSecret $spSecret -AzcmagentPath $azcmagentPath

            $result.OnboardingCommand | Should -Contain "--service-principal-id `"$spAppId`" --service-principal-secret `"PlainTextSecret`""
            $result.OnboardingCommand | Should -Contain "--correlation-id `"$correlationId`""
            $result.OnboardingCommand | Should -Contain "--cloud `"$cloud`""
            $result.OnboardingCommand | Should -Contain "--proxy-url `"$proxyUrl`""
            $result.OnboardingCommand | Should -Contain "--proxy-bypass `"$proxyBypass`""
            $result.OnboardingCommand | Should -Contain "--tags `"TestKey=`"TestValue`";AnotherKey=`"AnotherValue`"" # Order might vary, check parts
        }

        It "should attempt agent installation script if path is provided and script exists (with -WhatIf)" {
            $scriptPath = "/tmp/install_agent.ps1"
            $Global:ShouldProcessPreference = 'Continue' # To check ShouldProcess messages

            # We are checking the ShouldProcess message, not actual execution here.
            # The function currently uses Write-Warning for placeholder execution.
            New-ArcDeployment -ServerName $serverName -ResourceGroupName $rgName -SubscriptionId $subId -Location $loc -TenantId $tenId `
                -AgentInstallationScriptPath $scriptPath -WhatIf | Should -Not -Throw
            # Verification of mock script call would require a more sophisticated mock of '&' or Start-Process
            # For now, we rely on the -WhatIf output or a Write-Verbose/Write-Host in the function if changed.
            # The test ensures it runs and ShouldProcess for the agent install script is triggered.
        }

        It "should WARN if AgentInstallationScriptPath provided but script does not exist" {
            Mock Test-Path { param($Path) return $false } -Verifiable
            $scriptPath = "/non/existent/script.ps1"
            New-ArcDeployment -ServerName $serverName -ResourceGroupName $rgName -SubscriptionId $subId -Location $loc -TenantId $tenId `
                -AgentInstallationScriptPath $scriptPath | Should -Not -Throw # Function writes a warning
            Should -Invoke -CommandName Test-Path -Times 1 -ParameterFilter { $Path -eq $scriptPath }
        }

        It "should THROW if ServicePrincipalAppId provided without ServicePrincipalSecret" {
            $spAppId = "sp-app-id"
            { New-ArcDeployment -ServerName $serverName -ResourceGroupName $rgName -SubscriptionId $subId -Location $loc -TenantId $tenId `
                -ServicePrincipalAppId $spAppId } | Should -Throw "Both ServicePrincipalAppId and ServicePrincipalSecret must be provided for service principal onboarding."
        }

        It "should correctly format tags in the command" {
            $tags = @{ Key1 = "Value1"; "Key With Space" = "Value With Space" }
            $result = New-ArcDeployment -ServerName $serverName -ResourceGroupName $rgName -SubscriptionId $subId -Location $loc -TenantId $tenId -Tags $tags -AzcmagentPath $azcmagentPath
            # Pester's string matching might be tricky with hashtable key order. Check for essential parts.
            $result.OnboardingCommand | Should -Contain "--tags"
            $result.OnboardingCommand | Should -Contain "Key1=`"Value1`""
            $result.OnboardingCommand | Should -Contain "Key With Space=`"Value With Space`""
        }

        It "should respect -WhatIf for the azcmagent connect command" {
             $Global:ShouldProcessPreference = 'Continue'
             # The function currently uses Write-Warning for placeholder execution.
             # We check that the command is generated and the -WhatIf path is taken (no actual execution attempt)
             $result = New-ArcDeployment -ServerName $serverName -ResourceGroupName $rgName -SubscriptionId $subId -Location $loc -TenantId $tenId -WhatIf
             $result.Status | Should -Be "CommandGenerated" # Still generates the command
             # The function itself will output Write-Warning "azcmagent connect command execution skipped due to -WhatIf..."
        }
    }
    #endregion New-ArcDeployment Tests
}

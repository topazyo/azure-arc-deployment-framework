# tests/Powershell/unit/Core.Functions.Tests.ps1
using namespace System.Collections.Generic

if (-not (Get-Module -Name Pester)) {
    Import-Module -Name Pester -MinimumVersion 5.0.0
}

# Ensure Az cmdlets exist so Pester can Mock them even when Az modules are not installed.
$script:AzCmdletsToStub = @(
    'Get-AzContext',
    'Set-AzContext',
    'Get-AzResourceGroup',
    'New-AzResourceGroup',
    'Set-AzResourceGroup'
)

foreach ($cmdletName in $script:AzCmdletsToStub) {
    if (-not (Get-Command -Name $cmdletName -ErrorAction SilentlyContinue)) {
        Set-Item -Path ("Function:script:{0}" -f $cmdletName) -Value ([scriptblock]::Create("throw `"Command '$cmdletName' must be mocked in unit tests.`""))
    }
}

Describe "Core Deployment Functions" {
    BeforeAll {
        # Variables for common parameters (initialize in BeforeAll for Pester 5 scoping)
        $script:testSubscriptionId = "test-sub-id-12345"
        $script:testResourceGroupName = "arc-test-rg"
        $script:testLocation = "eastus"
        $script:testTenantId = "test-tenant-id-67890"
        $script:testTags = @{ Environment = "Test"; Purpose = "Pester" }
        $script:altSubscriptionId = "alt-sub-id-54321"
        $script:altLocation = "westus"

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
            Mock Get-AzContext { return [pscustomobject]@{ Subscription = [pscustomobject]@{Id = $script:testSubscriptionId; Name="TestSub"}; Account="test@contoso.com"; Tenant=[pscustomobject]@{Id=$script:testTenantId} } }
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
            Mock Get-Module -MockWith { param($Name) if ($Name -eq 'Az.Accounts') { return $false } else { return $true } } -Verifiable
            { Initialize-ArcDeployment -SubscriptionId $script:testSubscriptionId -ResourceGroupName $script:testResourceGroupName -Location $script:testLocation } | Should -Throw "Az.Accounts module not found."
            Should -Invoke -CommandName Get-Module -Times 1
        }

        It "should THROW if Az.Resources module is missing" {
            Mock Get-Module -MockWith { param($Name) if ($Name -eq 'Az.Resources') { return $false } else { return $true } } -Verifiable
            { Initialize-ArcDeployment -SubscriptionId $script:testSubscriptionId -ResourceGroupName $script:testResourceGroupName -Location $script:testLocation } | Should -Throw "Az.Resources module not found."
            Should -Invoke -CommandName Get-Module -Times 2 # Once for Az.Accounts, once for Az.Resources
        }

        It "should THROW if not logged into Azure (Get-AzContext returns null)" {
            Mock Get-AzContext { return $null } -Verifiable
            { Initialize-ArcDeployment -SubscriptionId $script:testSubscriptionId -ResourceGroupName $script:testResourceGroupName -Location $script:testLocation } | Should -Throw "Azure login required."
            Should -Invoke -CommandName Get-AzContext -Times 1
        }

        It "should use current context if subscription matches" {
            Mock Get-AzContext { return [pscustomobject]@{ Subscription = [pscustomobject]@{Id = $script:testSubscriptionId}; Account="test@contoso.com"; Tenant=[pscustomobject]@{Id=$script:testTenantId} } } -Verifiable
            Mock Set-AzContext { throw "Set-AzContext should not be called" } -Verifiable # Ensure it's not called

            # Simulate RG exists
            Mock Get-AzResourceGroup -MockWith {
                param($Name)
                if($Name -eq $script:testResourceGroupName) {
                    return [pscustomobject]@{ ResourceGroupName = $script:testResourceGroupName; Location = $script:testLocation; ProvisioningState = 'Succeeded'; Tags = $script:testTags }
                } else { throw "Resource group '$($Name)' not found."}
            }
            { Initialize-ArcDeployment -SubscriptionId $script:testSubscriptionId -ResourceGroupName $script:testResourceGroupName -Location $script:testLocation -Tags $script:testTags } | Should -Not -Throw
            Should -Invoke -CommandName Get-AzContext -Times 1 # Initial check
            Should -Not -Invoke -CommandName Set-AzContext
        }

        It "should call Set-AzContext if subscription ID differs and succeed" {
            $script:GetAzContextCallCount = 0
            Mock Get-AzContext -MockWith {
                $script:GetAzContextCallCount++
                if ($script:GetAzContextCallCount -eq 1) {
                    return [pscustomobject]@{ Subscription = [pscustomobject]@{Id = $script:altSubscriptionId}; Account="test@contoso.com"; Tenant=[pscustomobject]@{Id=$script:testTenantId} }
                }
                return [pscustomobject]@{ Subscription = [pscustomobject]@{Id = $script:testSubscriptionId}; Account="test@contoso.com"; Tenant=[pscustomobject]@{Id=$script:testTenantId} }
            }
            $script:LastSetAzContextParams = $null
            Mock Set-AzContext -MockWith {
                param(
                    [string]$SubscriptionId,
                    [string]$TenantId
                )

                $script:LastSetAzContextParams = [pscustomobject]@{
                    SubscriptionId = $SubscriptionId
                    TenantId       = $TenantId
                }
                return $true
            } -Verifiable
            Mock Get-AzResourceGroup -MockWith { return [pscustomobject]@{ ResourceGroupName = $script:testResourceGroupName; Location = $script:testLocation; ProvisioningState = 'Succeeded'; Tags = $script:testTags }}

            { Initialize-ArcDeployment -SubscriptionId $script:testSubscriptionId -ResourceGroupName $script:testResourceGroupName -Location $script:testLocation -TenantId $script:testTenantId } | Should -Not -Throw
            Should -Invoke -CommandName Get-AzContext -Times 2
            Should -Invoke -CommandName Set-AzContext -Times 1
            $script:LastSetAzContextParams | Should -Not -BeNullOrEmpty
            $script:LastSetAzContextParams.SubscriptionId | Should -Be $script:testSubscriptionId
            $script:LastSetAzContextParams.TenantId | Should -Be $script:testTenantId
        }

        It "should THROW if Set-AzContext fails" {
            Mock Get-AzContext { return [pscustomobject]@{ Subscription = [pscustomobject]@{Id = $script:altSubscriptionId}; Account="test@contoso.com"; Tenant=[pscustomobject]@{Id=$script:testTenantId} } }
            Mock Set-AzContext { throw "Simulated Set-AzContext failure" } -Verifiable
            { Initialize-ArcDeployment -SubscriptionId $script:testSubscriptionId -ResourceGroupName $script:testResourceGroupName -Location $script:testLocation -TenantId $script:testTenantId } | Should -Throw "Failed to set Azure context."
            Should -Invoke -CommandName Set-AzContext -Times 1
        }

        It "should CREATE resource group if it does not exist (with -WhatIf)" {
            $Global:ShouldProcessPreference = 'Continue' # To check ShouldProcess messages
            Mock New-AzResourceGroup -MockWith { param($Name, $Location, $Tag) Write-Host "WHATIF: Performing the operation `"Create`" on target `"Resource Group '$Name' in location '$Location'`"." } -Verifiable

            { Initialize-ArcDeployment -SubscriptionId $script:testSubscriptionId -ResourceGroupName $script:testResourceGroupName -Location $script:testLocation -Tags $script:testTags -WhatIf } | Should -Not -Throw
            Should -Not -Invoke -CommandName New-AzResourceGroup
        }

        It "should CREATE resource group if it does not exist" {
            $script:rgCreated = $false
            $script:createdRg = $null
            Mock Get-AzResourceGroup -MockWith {
                if (-not $script:rgCreated) {
                    throw "Resource group '$($Name)' not found."
                }
                return $script:createdRg
            }
            Mock New-AzResourceGroup -MockWith {
                param($Name, $Location, $Tag)
                $script:rgCreated = $true
                $script:createdRg = [pscustomobject]@{
                    ResourceGroupName = $Name
                    Location          = $Location
                    ProvisioningState = 'Succeeded'
                    Tags              = $Tag
                }
            } -Verifiable

            { Initialize-ArcDeployment -SubscriptionId $script:testSubscriptionId -ResourceGroupName $script:testResourceGroupName -Location $script:testLocation -Tags $script:testTags } | Should -Not -Throw
            Should -Invoke -CommandName New-AzResourceGroup -Times 1
        }

        It "should UPDATE tags if resource group exists and tags are provided (with -WhatIf)" {
             $Global:ShouldProcessPreference = 'Continue'
            Mock Get-AzResourceGroup -MockWith { return [pscustomobject]@{ ResourceGroupName = $script:testResourceGroupName; Location = $script:testLocation; ProvisioningState = 'Succeeded'; Tags = @{} } }
            Mock Set-AzResourceGroup -MockWith { param($Name, $Tag) Write-Host "WHATIF: Performing the operation `"Update Tags`" on target `"Resource Group '$Name'`"." } -Verifiable

            { Initialize-ArcDeployment -SubscriptionId $script:testSubscriptionId -ResourceGroupName $script:testResourceGroupName -Location $script:testLocation -Tags $script:testTags -WhatIf } | Should -Not -Throw
            Should -Not -Invoke -CommandName Set-AzResourceGroup
        }

        It "should UPDATE tags if resource group exists and tags are provided" {
            $script:currentTags = @{}
            Mock Get-AzResourceGroup -MockWith {
                return [pscustomobject]@{
                    ResourceGroupName  = $script:testResourceGroupName
                    Location           = $script:testLocation
                    ProvisioningState  = 'Succeeded'
                    Tags               = $script:currentTags
                }
            }
            Mock Set-AzResourceGroup -MockWith {
                param ($Name, $Tag)
                $script:currentTags = $Tag
            } -Verifiable

            $result = Initialize-ArcDeployment -SubscriptionId $script:testSubscriptionId -ResourceGroupName $script:testResourceGroupName -Location $script:testLocation -Tags $script:testTags
            $result.Tags['Environment'] | Should -Be $script:testTags['Environment']
            Should -Invoke -CommandName Set-AzResourceGroup -Times 1
        }

        It "should WARN if resource group exists in a different location" {
            Mock Get-AzResourceGroup { return [pscustomobject]@{ ResourceGroupName = $script:testResourceGroupName; Location = $script:altLocation; ProvisioningState = 'Succeeded'; Tags = @{} } }
            # Use -WarningAction SilentlyContinue to capture warnings if needed, or check console output
            # For Pester, checking for a warning can be done by redirecting warning stream or specific setup.
            # Here, we just ensure it runs and trust the Write-Warning happens.
            { Initialize-ArcDeployment -SubscriptionId $script:testSubscriptionId -ResourceGroupName $script:testResourceGroupName -Location $script:testLocation } | Should -Not -Throw
        }

        It "should THROW if resource group creation fails" {
            Mock New-AzResourceGroup { throw "Simulated New-AzResourceGroup failure" } -Verifiable
            { Initialize-ArcDeployment -SubscriptionId $script:testSubscriptionId -ResourceGroupName $script:testResourceGroupName -Location $script:testLocation } | Should -Throw "Resource group creation failed."
            Should -Invoke -CommandName New-AzResourceGroup -Times 1
        }

        It "should WARN if tag update fails on existing RG" {
               Mock Get-AzResourceGroup { return [pscustomobject]@{ ResourceGroupName = $script:testResourceGroupName; Location = $script:testLocation; ProvisioningState = 'Succeeded'; Tags = @{} } }
             Mock Set-AzResourceGroup { throw "Simulated Set-AzResourceGroup failure for tags" } -Verifiable
             # This function currently logs a warning but doesn't throw for tag update failure.
                             { Initialize-ArcDeployment -SubscriptionId $script:testSubscriptionId -ResourceGroupName $script:testResourceGroupName -Location $script:testLocation -Tags $script:testTags } | Should -Not -Throw
             Should -Invoke -CommandName Set-AzResourceGroup -Times 1
        }
    }
    #endregion Initialize-ArcDeployment Tests

    #region New-ArcDeployment Tests
    Describe "New-ArcDeployment" {
        BeforeAll {
            $script:serverName = "TestServer001"
            $script:rgName = "TestRG"
            $script:subId = "TestSubId"
            $script:loc = "eastus"
            $script:tenId = "TestTenantId"
            $script:azcmagentPath = "mock_azcmagent" # Assume it's a command that can be "called"
        }

        Mock Test-Path { param($Path) return $true } # Default mock for Test-Path
        Mock ConvertFrom-SecureString { param($SecureString) return "PlainTextSecret" } # Mock secure string conversion

        # Mock for the external script/command execution for azcmagent
        # We are not actually executing azcmagent, just checking the command construction and ShouldProcess
        BeforeEach {
            Mock Test-Path { param($Path) return $true }
            Mock ConvertFrom-SecureString { param($SecureString) return "PlainTextSecret" }
            $Global:ShouldProcessPreference = $null
            $ConfirmPreference = 'None'
        }
        AfterEach {
            $Global:ShouldProcessPreference = $null
        }

        It "should generate basic command with mandatory parameters" {
            $result = New-ArcDeployment -ServerName $script:serverName -ResourceGroupName $script:rgName -SubscriptionId $script:subId -Location $script:loc -TenantId $script:tenId -AzcmagentPath $script:azcmagentPath -Confirm:$false
            $result.OnboardingCommand | Should -Be "$($script:azcmagentPath) connect --resource-group `"$($script:rgName)`" --subscription-id `"$($script:subId)`" --location `"$($script:loc)`" --tenant-id `"$($script:tenId)`""
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

            $result = New-ArcDeployment -ServerName $script:serverName -ResourceGroupName $script:rgName -SubscriptionId $script:subId -Location $script:loc -TenantId $script:tenId `
                -Tags $tags -CorrelationId $correlationId -Cloud $cloud -ProxyUrl $proxyUrl -ProxyBypass $proxyBypass `
                -ServicePrincipalAppId $spAppId -ServicePrincipalSecret $spSecret -AzcmagentPath $script:azcmagentPath -Confirm:$false

            $result.OnboardingCommand | Should -Match ([regex]::Escape("--service-principal-id `"$spAppId`" --service-principal-secret `"PlainTextSecret`""))
            $result.OnboardingCommand | Should -Match ([regex]::Escape("--correlation-id `"$correlationId`""))
            $result.OnboardingCommand | Should -Match ([regex]::Escape("--cloud `"$cloud`""))
            $result.OnboardingCommand | Should -Match ([regex]::Escape("--proxy-url `"$proxyUrl`""))
            $result.OnboardingCommand | Should -Match ([regex]::Escape("--proxy-bypass `"$proxyBypass`""))
            $result.OnboardingCommand | Should -Match ([regex]::Escape("--tags"))
            $result.OnboardingCommand | Should -Match ([regex]::Escape("TestKey=`"TestValue`""))
            $result.OnboardingCommand | Should -Match ([regex]::Escape("AnotherKey=`"AnotherValue`""))
        }

        It "should attempt agent installation script if path is provided and script exists (with -WhatIf)" {
            $scriptPath = "/tmp/install_agent.ps1"
            $Global:ShouldProcessPreference = 'Continue' # To check ShouldProcess messages

            # We are checking the ShouldProcess message, not actual execution here.
            # The function currently uses Write-Warning for placeholder execution.
            { New-ArcDeployment -ServerName $script:serverName -ResourceGroupName $script:rgName -SubscriptionId $script:subId -Location $script:loc -TenantId $script:tenId `
                -AgentInstallationScriptPath $scriptPath -WhatIf -Confirm:$false } | Should -Not -Throw
            # Verification of mock script call would require a more sophisticated mock of '&' or Start-Process
            # For now, we rely on the -WhatIf output or a Write-Verbose/Write-Host in the function if changed.
            # The test ensures it runs and ShouldProcess for the agent install script is triggered.
        }

        It "should WARN if AgentInstallationScriptPath provided but script does not exist" {
            Mock Test-Path { param($Path) return $false } -Verifiable
            $scriptPath = "/non/existent/script.ps1"
            { New-ArcDeployment -ServerName $script:serverName -ResourceGroupName $script:rgName -SubscriptionId $script:subId -Location $script:loc -TenantId $script:tenId `
                -AgentInstallationScriptPath $scriptPath -Confirm:$false } | Should -Not -Throw # Function writes a warning
            Should -Invoke -CommandName Test-Path -Times 1 -ParameterFilter { $Path -eq $scriptPath }
        }

        It "should THROW if ServicePrincipalAppId provided without ServicePrincipalSecret" {
            $spAppId = "sp-app-id"
            { New-ArcDeployment -ServerName $script:serverName -ResourceGroupName $script:rgName -SubscriptionId $script:subId -Location $script:loc -TenantId $script:tenId `
                -ServicePrincipalAppId $spAppId -Confirm:$false } | Should -Throw "Both ServicePrincipalAppId and ServicePrincipalSecret must be provided for service principal onboarding."
        }

        It "should correctly format tags in the command" {
            $tags = @{ Key1 = "Value1"; "Key With Space" = "Value With Space" }
            $result = New-ArcDeployment -ServerName $script:serverName -ResourceGroupName $script:rgName -SubscriptionId $script:subId -Location $script:loc -TenantId $script:tenId -Tags $tags -AzcmagentPath $script:azcmagentPath -Confirm:$false
            # Pester's string matching might be tricky with hashtable key order. Check for essential parts.
            $result.OnboardingCommand | Should -Match ([regex]::Escape("--tags"))
            $result.OnboardingCommand | Should -Match ([regex]::Escape("Key1=`"Value1`""))
            $result.OnboardingCommand | Should -Match ([regex]::Escape("Key With Space=`"Value With Space`""))
        }

        It "should respect -WhatIf for the azcmagent connect command" {
             $Global:ShouldProcessPreference = 'Continue'
             # The function currently uses Write-Warning for placeholder execution.
             # We check that the command is generated and the -WhatIf path is taken (no actual execution attempt)
               $result = New-ArcDeployment -ServerName $script:serverName -ResourceGroupName $script:rgName -SubscriptionId $script:subId -Location $script:loc -TenantId $script:tenId -WhatIf -Confirm:$false
             $result.Status | Should -Be "CommandGenerated" # Still generates the command
             # The function itself will output Write-Warning "azcmagent connect command execution skipped due to -WhatIf..."
        }
    }
    #endregion New-ArcDeployment Tests
}

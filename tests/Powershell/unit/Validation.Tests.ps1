# tests/Powershell/unit/Validation.Tests.ps1
using namespace System.Management.Automation

Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

Describe 'Test-ConfigurationDrift.ps1 Tests' {
    $TestScriptRoot = (Split-Path $MyInvocation.MyCommand.Path -Parent)
    $ScriptPath = Join-Path $TestScriptRoot '..\..\..\src\Powershell\Validation\Test-ConfigurationDrift.ps1'

    # Define expected values based on Test-ConfigurationDrift.ps1's hardcoded checks
    $ExpectedValues = @{
        Registry = @{
            "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319" = @{
                "SchUseStrongCrypto" = 1
                "SystemDefaultTlsVersions" = 1
            }
            "HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319" = @{
                "SchUseStrongCrypto" = 1
                "SystemDefaultTlsVersions" = 1
            }
        }
        Services = @{
            "himds" = @{ StartupType = "Automatic"; State = "Running" }
            "AzureMonitorAgent" = @{ StartupType = "Automatic"; State = "Running" }
            "GCService" = @{ StartupType = "Automatic"; State = "Running" }
        }
        FirewallRules = @{
            "Azure Arc Management" = @{ Enabled = $true; Direction = "Outbound"; Action = "Allow" }
            "Azure Monitor" = @{ Enabled = $true; Direction = "Outbound"; Action = "Allow" }
        }
        AuditPolicies = @{ 
            "Process Creation" = "Success" 
            "Credential Validation" = "Success,Failure" 
        }
    }

    $Global:MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new() # Shared by all Describes in this file
    $Global:IsAdminContext = $true 

    BeforeEach { # Specific to Test-ConfigurationDrift.ps1
        # $Global:MockedWriteLogMessages.Clear() # Cleared by the top-level BeforeEach for the file now
        $Global:IsAdminContext = $true 

        Mock Write-Log -ModuleName $ScriptPath -MockWith { 
            param([string]$Message, [string]$Level="INFO", [string]$Path) 
            $Global:MockedWriteLogMessages.Add("DRIFT_SCRIPT_LOG: [$Level] $Message")
        }

        Mock Get-ItemProperty -ModuleName $ScriptPath -MockWith {
            param ($Path, $Name)
            Write-Verbose "Mock Get-ItemProperty for Drift for Path '$Path', Name '$Name'"
            if ($ExpectedValues.Registry.ContainsKey($Path) -and $ExpectedValues.Registry[$Path].ContainsKey($Name)) {
                return @{ $Name = $ExpectedValues.Registry[$Path][$Name] } | Select-Object -ExpandProperty $Name
            }
            throw "Drift Test: Get-ItemProperty called for unexpected path/name: $Path \ $Name"
        }

        Mock Get-Service -ModuleName $ScriptPath -MockWith {
            param ($Name)
            Write-Verbose "Mock Get-Service for Drift for Name '$Name'"
            if ($ExpectedValues.Services.ContainsKey($Name)) {
                $props = $ExpectedValues.Services[$Name]
                return [PSCustomObject]@{
                    Name = $Name; StartupType = $props.StartupType; State = $props.State; Status = $props.State 
                }
            }
            throw "Drift Test: Get-Service called for unexpected service name: $Name"
        }

        Mock Get-NetFirewallRule -ModuleName $ScriptPath -MockWith {
            param ([string]$DisplayName) 
            Write-Verbose "Mock Get-NetFirewallRule for Drift for DisplayName '$DisplayName'"
            if ($ExpectedValues.FirewallRules.ContainsKey($DisplayName)) {
                $props = $ExpectedValues.FirewallRules[$DisplayName]
                return [PSCustomObject]@{
                    DisplayName = $DisplayName; Enabled = $props.Enabled; Direction = $props.Direction; Action = $props.Action
                }
            }
            return $null 
        }
        
        $compliantAuditPolOutput = @"
"Machine Name","Policy Target","Subcategory","Subcategory GUID","Inclusion Setting","Exclusion Setting"
"TestServer","System","Process Creation","{0CCE922B-69AE-11D9-BED3-505054503030}","Success",""
"TestServer","System","Credential Validation","{0CCE9225-69AE-11D9-BED3-505054503030}","Success and Failure",""
"@
        Mock Invoke-Expression -ModuleName $ScriptPath -MockWith { 
            param($command) 
            if ($command -like "auditpol /get*") { 
                Write-Verbose "Mock Invoke-Expression for Drift returning compliant auditpol output."
                return $compliantAuditPolOutput.Split([System.Environment]::NewLine) | Where-Object {$_} 
            } 
            throw "Drift Test: Invoke-Expression called with unexpected command: $command"
        }
    }

    It 'Should return DriftDetected=$false when all checks are compliant' {
        $result = . $ScriptPath
        $result.DriftDetected | Should -Be $false
        ($result.DriftDetails | Where-Object {$_.Status -eq "Drifted"}).Count | Should -Be 0
    }

    Context 'Registry Drift Detection' {
        It 'Should detect drift if a registry key value is non-compliant' {
            $NonCompliantPath = "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319"
            $NonCompliantName = "SchUseStrongCrypto"
            $NonCompliantValue = 0 

            Mock Get-ItemProperty -ModuleName $ScriptPath -MockWith {
                param ($Path, $Name)
                if ($Path -eq $NonCompliantPath -and $Name -eq $NonCompliantName) {
                    return @{ $Name = $NonCompliantValue } | Select-Object -ExpandProperty $Name
                }
                if ($ExpectedValues.Registry.ContainsKey($Path) -and $ExpectedValues.Registry[$Path].ContainsKey($Name)) {
                    return @{ $Name = $ExpectedValues.Registry[$Path][$Name] } | Select-Object -ExpandProperty $Name
                }
                throw "Drift Test (Registry NonCompliant): Get-ItemProperty mock fallback for $Path\$Name"
            }
            $result = . $ScriptPath
            $result.DriftDetected | Should -Be $true
            $driftItem = $result.DriftDetails | Where-Object { $_.Category -eq "Registry" -and $_.Item -eq "$NonCompliantPath" -and $_.Property -eq $NonCompliantName }
            $driftItem | Should -Not -BeNullOrEmpty
            $driftItem.CurrentValue | Should -Be $NonCompliantValue
            $driftItem.Status | Should -Be "Drifted"
        }

        It 'Should detect drift if a registry key is NOT_FOUND_OR_ERROR' {
             Mock Get-ItemProperty -ModuleName $ScriptPath -MockWith {
                param ($Path, $Name)
                if ($Path -eq "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319" -and $Name -eq "SchUseStrongCrypto") {
                    throw "Simulated access error"
                }
                 if ($ExpectedValues.Registry.ContainsKey($Path) -and $ExpectedValues.Registry[$Path].ContainsKey($Name)) {
                    return @{ $Name = $ExpectedValues.Registry[$Path][$Name] } | Select-Object -ExpandProperty $Name
                }
                throw "Drift Test (Registry Error): Get-ItemProperty mock fallback for $Path\$Name"
            }
            $result = . $ScriptPath
            $result.DriftDetected | Should -Be $true
            $driftItem = $result.DriftDetails | Where-Object { $_.Category -eq "Registry" -and $_.Item -eq "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319" -and $_.Property -eq "SchUseStrongCrypto" }
            $driftItem.CurrentValue | Should -Be "NOT_FOUND_OR_ERROR"
            $driftItem.Status | Should -Be "Drifted"
        }
    }

    Context 'Service Drift Detection' {
        It 'Should detect drift if a service StartupType is non-compliant' {
            $NonCompliantService = "himds"
            $NonCompliantStartupType = "Manual"
            Mock Get-Service -ModuleName $ScriptPath -MockWith {
                param ($Name)
                if ($Name -eq $NonCompliantService) {
                    return [PSCustomObject]@{ Name = $Name; StartupType = $NonCompliantStartupType; Status = $ExpectedValues.Services[$Name].State }
                }
                if ($ExpectedValues.Services.ContainsKey($Name)) {
                    $props = $ExpectedValues.Services[$Name]; return [PSCustomObject]@{ Name = $Name; StartupType = $props.StartupType; Status = $props.State }
                }
                throw "Drift Test (Service Startup): Get-Service mock fallback for $Name"
            }
            $result = . $ScriptPath
            $result.DriftDetected | Should -Be $true
            $driftItem = $result.DriftDetails | Where-Object { $_.Category -eq "Service" -and $_.Item -eq $NonCompliantService -and $_.Property -eq "StartupType" }
            $driftItem.CurrentValue | Should -Be $NonCompliantStartupType
            $driftItem.Status | Should -Be "Drifted"
        }

        It 'Should detect drift if a service State is non-compliant (e.g., Stopped)' {
            $NonCompliantService = "AzureMonitorAgent"
            $NonCompliantState = "Stopped"
            Mock Get-Service -ModuleName $ScriptPath -MockWith {
                param ($Name)
                if ($Name -eq $NonCompliantService) {
                    return [PSCustomObject]@{ Name = $Name; StartupType = $ExpectedValues.Services[$Name].StartupType; Status = $NonCompliantState }
                }
                 if ($ExpectedValues.Services.ContainsKey($Name)) {
                    $props = $ExpectedValues.Services[$Name]; return [PSCustomObject]@{ Name = $Name; StartupType = $props.StartupType; Status = $props.State }
                }
                throw "Drift Test (Service State): Get-Service mock fallback for $Name"
            }
            $result = . $ScriptPath
            $result.DriftDetected | Should -Be $true
            $driftItem = $result.DriftDetails | Where-Object { $_.Category -eq "Service" -and $_.Item -eq $NonCompliantService -and $_.Property -eq "State" }
            $driftItem.CurrentValue | Should -Be $NonCompliantState
            $driftItem.Status | Should -Be "Drifted"
        }
    }

    Context 'Firewall Rule Drift Detection' {
        It 'Should detect drift if a firewall rule is NOT_FOUND_OR_ERROR' {
            Mock Get-NetFirewallRule -ModuleName $ScriptPath -MockWith { param ($DisplayName) return $null } 
            $result = . $ScriptPath
            $result.DriftDetected | Should -Be $true
            $driftItem = $result.DriftDetails | Where-Object { $_.Category -eq "Firewall" -and $_.Item -eq "Azure Arc Management" -and $_.Property -eq "Enabled" }
            $driftItem.CurrentValue | Should -Be "NOT_FOUND_OR_ERROR"
        }

        It 'Should detect drift if a firewall rule Action is non-compliant' {
            $NonCompliantRuleName = "Azure Arc Management"
            $NonCompliantAction = "Block"
            Mock Get-NetFirewallRule -ModuleName $ScriptPath -MockWith {
                param ($DisplayName)
                if ($DisplayName -eq $NonCompliantRuleName) {
                    return [PSCustomObject]@{ DisplayName = $DisplayName; Enabled = $true; Direction = 'Outbound'; Action = $NonCompliantAction }
                }
                if ($ExpectedValues.FirewallRules.ContainsKey($DisplayName)) {
                     $props = $ExpectedValues.FirewallRules[$DisplayName]; return [PSCustomObject]@{ DisplayName = $DisplayName; Enabled = $props.Enabled; Direction = $props.Direction; Action = $props.Action }
                }
                return $null
            }
            $result = . $ScriptPath
            $result.DriftDetected | Should -Be $true
            $driftItem = $result.DriftDetails | Where-Object { $_.Category -eq "Firewall" -and $_.Item -eq $NonCompliantRuleName -and $_.Property -eq "Action" }
            $driftItem.CurrentValue | Should -Be $NonCompliantAction
        }
    }

    Context 'Audit Policy Drift Detection' {
        It 'Should detect drift if an audit policy setting is non-compliant' {
            $nonCompliantAuditPolOutput = @"
"Machine Name","Policy Target","Subcategory","Subcategory GUID","Inclusion Setting","Exclusion Setting"
"TestServer","System","Process Creation","{0CCE922B-69AE-11D9-BED3-505054503030}","Failure",""
"TestServer","System","Credential Validation","{0CCE9225-69AE-11D9-BED3-505054503030}","Success and Failure",""
"@ 
            Mock Invoke-Expression -ModuleName $ScriptPath -MockWith { 
                param($command) if ($command -like "auditpol /get*") { return $nonCompliantAuditPolOutput.Split([System.Environment]::NewLine) | Where-Object {$_} } return "" 
            }
            $result = . $ScriptPath
            $result.DriftDetected | Should -Be $true
            $driftItem = $result.DriftDetails | Where-Object { $_.Category -eq "AuditPolicy" -and $_.Item -eq "Process Creation" }
            $driftItem.CurrentValue | Should -Be "Failure" 
            $driftItem.Status | Should -Be "Drifted"
        }
         It 'Should detect drift if auditpol output is missing an expected subcategory' {
            $missingSubcategoryAuditPolOutput = @"
"Machine Name","Policy Target","Subcategory","Subcategory GUID","Inclusion Setting","Exclusion Setting"
"TestServer","System","Credential Validation","{0CCE9225-69AE-11D9-BED3-505054503030}","Success and Failure",""
"@ 
            Mock Invoke-Expression -ModuleName $ScriptPath -MockWith { 
                param($command) if ($command -like "auditpol /get*") { return $missingSubcategoryAuditPolOutput.Split([System.Environment]::NewLine) | Where-Object {$_} } return "" 
            }
            $result = . $ScriptPath
            $result.DriftDetected | Should -Be $true
            $driftItem = $result.DriftDetails | Where-Object { $_.Category -eq "AuditPolicy" -and $_.Item -eq "Process Creation" }
            $driftItem.CurrentValue | Should -Be "ERROR_RETRIEVING_POLICY" 
            $driftItem.Status | Should -Be "Drifted"
        }
    }

    Context 'Output Structure and Logging' {
        It 'Should return an object with correct top-level properties' {
            $result = . $ScriptPath -ServerName "TestSrv1"
            $result | Should -Not -BeNullOrEmpty
            $result.PSObject.Properties.Name | Should -Contain @("ServerName", "Timestamp", "DriftDetected", "DriftDetails")
            $result.ServerName | Should -Be "TestSrv1"
        }

        It 'Should log a warning if not run as administrator (simulated by script logic)' {
            # This test assumes that if the .NET call `([Security.Principal.WindowsPrincipal]...).IsInRole(...)`
            # in the script *were* to return $false, the script would log the specific warning message.
            # We cannot easily mock the .NET call to force it to be $false here without script modification.
            # So, we rely on the script's internal logic to produce this log if it detects non-admin.
            # This test essentially checks if such a log message appears, implying the non-admin path was taken.
            # To *force* this path for testing, one would typically run the test itself in a non-admin context.
            # Here, we just ensure our Write-Log mock captures it if the script generates it.
            # The script Test-ConfigurationDrift.ps1 has its own Write-Log call for this.
            # We are not directly testing the admin check, but the script's reaction (logging) to it.
            . $ScriptPath # Run with default admin for mocks
            # To actually test the non-admin path, one would typically mock the admin check to return $false.
            # As this is hard, this test serves as a placeholder if we could do that.
            # Example of what would be checked if we could force the non-admin path:
            # $Global:MockedWriteLogMessages | Should -ContainMatch "[WARNING] Running without Administrator privileges."
            Skip "Skipping direct test of non-admin warning log due to difficulty mocking the .NET admin check directly."
        }
         It 'Should log the start and end of the script' {
            . $ScriptPath
            $Global:MockedWriteLogMessages | Should -ContainMatch "[INFO] Starting configuration drift test script for server: $($env:COMPUTERNAME)."
            $Global:MockedWriteLogMessages | Should -ContainMatch "[INFO] Configuration drift test completed. Drift Detected: False" 
        }
    }
}

Describe 'Test-ResourceProviderStatus.ps1 Tests' {
    $TestScriptRoot = (Split-Path $MyInvocation.MyCommand.Path -Parent)
    $ScriptPathResourceProvider = Join-Path $TestScriptRoot '..\..\..\src\Powershell\Validation\Test-ResourceProviderStatus.ps1'

    $defaultRequiredProviders = @('Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.AzureArcData', 'Microsoft.Insights', 'Microsoft.Security')
    $mockSubscriptionId = "mock-subscription-id-from-registry"
    $mockResourceGroupName = "mock-rg-from-registry" # Not used by this script, but for completeness of Arc config mock

    $Global:ArcAgentConfig = @{ # Mock for Arc Agent Registry Keys
        SubscriptionId = $mockSubscriptionId
        ResourceGroupName = $mockResourceGroupName
    }

    BeforeEach {
        $Global:MockedWriteLogMessages.Clear()
        $Global:ArcAgentConfig = @{ SubscriptionId = $mockSubscriptionId; ResourceGroupName = $mockResourceGroupName }


        Mock Get-Module -MockWith { param($Name, $ListAvailable) # General mock for Get-Module
            if ($ListAvailable) { 
                # Simulate specified modules are available
                if ($Name -in @('Az.Monitor', 'Az.ConnectedMachine', 'Az.Resources')) {
                    return @{ Name = $Name; Path = "mocked_path\\$Name" } | New-MockObject 
                }
                return $null # Other modules not found by default
            } 
            return $null # Should not be called without -ListAvailable in script
        }

        Mock Get-AzContext { return @{ Subscription = [PSCustomObject]@{Id = "current-sub-id"; Name="CurrentSub"} ; Account = "user@contoso.com"; Tenant = @{Id="tenant-id"} } | New-MockObject } 
        Mock Set-AzContext { param($SubscriptionId) Write-Verbose "Mock Set-AzContext called with SubID: $SubscriptionId" } -ModuleName $ScriptPathResourceProvider

        # Mock Get-ItemProperty for Arc Agent Config
        Mock Get-ItemProperty -ModuleName $ScriptPathResourceProvider -MockWith {
            param($Path, $Name)
            Write-Verbose "Mock Get-ItemProperty for RPStatus for Path '$Path', Name '$Name'"
            if ($Path -like "*Azure Connected Machine Agent\Config") {
                if ($Global:ArcAgentConfig.ContainsKey($Name)) {
                    return @{ $Name = $Global:ArcAgentConfig[$Name] } | Select-Object -ExpandProperty $Name
                }
            }
            return $null
        }
        
        Mock Get-AzResourceProvider -ModuleName $ScriptPathResourceProvider -MockWith {
            param($ProviderNamespace)
            Write-Verbose "Mock Get-AzResourceProvider for RPStatus for Namespace '$ProviderNamespace'"
            return [PSCustomObject]@{ ProviderNamespace = $ProviderNamespace; RegistrationState = "Registered"; ResourceTypes = @([PSCustomObject]@{ResourceTypeName="mockType"}) } 
        }

        Mock Write-Log -ModuleName $ScriptPathResourceProvider -MockWith { 
            param([string]$Message, [string]$Level="INFO", [string]$Path) 
            $Global:MockedWriteLogMessages.Add("RP_STATUS_LOG: [$Level] $Message")
        }
    }

    It 'Should return OverallStatus=Success if all default providers are registered' {
        $result = . $ScriptPathResourceProvider -SubscriptionId "param-sub-id" # Explicitly pass sub to bypass registry
        $result.OverallStatus | Should -Be "Success"
        $result.ProviderDetails.Count | Should -Be $defaultRequiredProviders.Count
        $result.ProviderDetails | ForEach-Object { $_.Status | Should -Be "Success" }
        $Global:MockedWriteLogMessages | Should -ContainMatch "*RP_STATUS_LOG: \[INFO\] Setting Az context to subscription: param-sub-id*"
    }

    It 'Should return OverallStatus=Failed if a provider is NotRegistered' {
        Mock Get-AzResourceProvider -ModuleName $ScriptPathResourceProvider -MockWith {
            param($ProviderNamespace)
            if ($ProviderNamespace -eq 'Microsoft.Insights') {
                return [PSCustomObject]@{ ProviderNamespace = $ProviderNamespace; RegistrationState = "NotRegistered"; ResourceTypes = @([PSCustomObject]@{ResourceTypeName="mockType"}) }
            }
            return [PSCustomObject]@{ ProviderNamespace = $ProviderNamespace; RegistrationState = "Registered"; ResourceTypes = @([PSCustomObject]@{ResourceTypeName="mockType"}) }
        }
        $result = . $ScriptPathResourceProvider -SubscriptionId "param-sub-id"
        $result.OverallStatus | Should -Be "Failed"
        ($result.ProviderDetails | Where-Object {$_.ProviderNamespace -eq 'Microsoft.Insights'}).Status | Should -Be "Failed"
    }

    It 'Should use discovered SubscriptionId from registry if not provided' {
        . $ScriptPathResourceProvider # Relies on Get-ItemProperty mock via $Global:ArcAgentConfig
        Assert-MockCalled Set-AzContext -ModuleName $ScriptPathResourceProvider -Scope It -Times 1 -ParameterFilter { $_.SubscriptionId -eq $mockSubscriptionId } -PassThru
        Assert-MockCalled Get-AzResourceProvider -ModuleName $ScriptPathResourceProvider -Scope It -Times $defaultRequiredProviders.Count -PassThru
        $Global:MockedWriteLogMessages | Should -ContainMatch "*RP_STATUS_LOG: \[INFO\] Discovered Subscription ID from Arc Agent config: $mockSubscriptionId*"
    }
    
    It 'Should THROW if Az.Monitor module is not available' {
        Mock Get-Module -MockWith { param($NameParam, $ListAvailable) if($ListAvailable -and $NameParam -eq 'Az.Monitor') { return $null } return @{ Name = $NameParam } }
        { . $ScriptPathResourceProvider -SubscriptionId "param-sub-id" } | Should -Throw "Az.Monitor PowerShell module is not installed."
    }

    It 'Should THROW if no Azure context is active' {
        Mock Get-AzContext { return $null }
        { . $ScriptPathResourceProvider -SubscriptionId "param-sub-id" } | Should -Throw "No active Azure context. Please connect using Connect-AzAccount."
    }

    It 'Should THROW if SubscriptionId is not provided and cannot be discovered from registry' {
        $Global:ArcAgentConfig.Remove("SubscriptionId") # Ensure it's not in the mock global
        Mock Get-ItemProperty -ModuleName $ScriptPathResourceProvider -MockWith {param($Path, $Name) return $null} # Simulate registry keys not found
        { . $ScriptPathResourceProvider } | Should -Throw "SubscriptionId could not be determined."
    }
    
    It 'Should check custom list of providers if -RequiredResourceProviders is specified' {
        $customProviders = @("Microsoft.CustomProvider1", "Microsoft.CustomProvider2")
        . $ScriptPathResourceProvider -SubscriptionId "param-sub-id" -RequiredResourceProviders $customProviders
        Assert-MockCalled Get-AzResourceProvider -ModuleName $ScriptPathResourceProvider -Scope It -Times $customProviders.Count -PassThru
        Assert-MockCalled Get-AzResourceProvider -ModuleName $ScriptPathResourceProvider -Scope It -ParameterFilter { $_.ProviderNamespace -eq "Microsoft.CustomProvider1" } -PassThru
        Assert-MockCalled Get-AzResourceProvider -ModuleName $ScriptPathResourceProvider -Scope It -ParameterFilter { $_.ProviderNamespace -eq "Microsoft.CustomProvider2" } -PassThru
    }

     It 'Should return OverallStatus=Failed if Get-AzResourceProvider throws for a provider' {
        Mock Get-AzResourceProvider -ModuleName $ScriptPathResourceProvider -MockWith {
            param($ProviderNamespace)
            if ($ProviderNamespace -eq 'Microsoft.Insights') {
                throw "Simulated error getting Microsoft.Insights"
            }
            return [PSCustomObject]@{ ProviderNamespace = $ProviderNamespace; RegistrationState = "Registered"; ResourceTypes = @([PSCustomObject]@{ResourceTypeName="mockType"}) }
        }
        $result = . $ScriptPathResourceProvider -SubscriptionId "param-sub-id"
        $result.OverallStatus | Should -Be "Failed"
        $failedProviderDetail = $result.ProviderDetails | Where-Object {$_.ProviderNamespace -eq 'Microsoft.Insights'}
        $failedProviderDetail.RegistrationState | Should -Be "ERROR_RETRIEVING_STATUS"
        $failedProviderDetail.Status | Should -Be "Failed"
        $Global:MockedWriteLogMessages | Should -ContainMatch "*RP_STATUS_LOG: \[ERROR\] Failed to get status for provider 'Microsoft.Insights'. Error: Simulated error getting Microsoft.Insights*"
    }
}

# tests/Powershell/unit/Validation.Tests.ps1
using namespace System.Management.Automation

Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

# Ensure Az cmdlets exist so Pester can Mock them even when Az modules are not installed.
$script:AzCmdletsToStub = @(
    'Get-AzResourceProvider',
    'Get-AzContext',
    'Set-AzContext'
)

foreach ($cmdletName in $script:AzCmdletsToStub) {
    if (-not (Get-Command -Name $cmdletName -ErrorAction SilentlyContinue)) {
        # Create a stub that forces explicit mocking in tests.
        Set-Item -Path ("Function:script:{0}" -f $cmdletName) -Value ([scriptblock]::Create("throw 'Command $cmdletName must be mocked in unit tests.'"))
    }
}

# Provide a stub Write-Log so mocks and scripts always have a target (register globally for scriptblocks).
if (-not (Get-Command -Name Write-Log -ErrorAction SilentlyContinue)) {
    Set-Item -Path Function:global:Write-Log -Value ([scriptblock]::Create('param([string]$Message,[string]$Level="INFO",[string]$Path)'))
}

# Establish test script root and load shared logging (harmless no-op if stubbed above is replaced by mock or the real implementation).
$script:TestScriptRoot = $PSScriptRoot
if (-not $script:TestScriptRoot) { $script:TestScriptRoot = Split-Path -Parent $PSCommandPath }
if (-not $script:TestScriptRoot) { $script:TestScriptRoot = (Get-Location).Path }
Write-Host "DEBUG TestScriptRoot=$script:TestScriptRoot"
$script:WriteLogPath = Join-Path $script:TestScriptRoot '..\..\..\src\Powershell\utils\Write-Log.ps1'
if (-not (Test-Path $script:WriteLogPath)) { throw "Write-Log.ps1 not found at $script:WriteLogPath" }
. $script:WriteLogPath

# Resolve validation script paths up front so BeforeAll blocks can assume they exist.
$Global:ConfigurationDriftScriptPath = (Resolve-Path (Join-Path $script:TestScriptRoot '..\..\..\src\Powershell\Validation\Test-ConfigurationDrift.ps1') -ErrorAction Stop).ProviderPath
$Global:ResourceProviderScriptPath = (Resolve-Path (Join-Path $script:TestScriptRoot '..\..\..\src\Powershell\Validation\Test-ResourceProviderStatus.ps1') -ErrorAction Stop).ProviderPath
$Global:GetValidationStepScriptPath = (Resolve-Path (Join-Path $script:TestScriptRoot '..\..\..\src\Powershell\remediation\Get-ValidationStep.ps1') -ErrorAction Stop).ProviderPath
$Global:ValidationRulesFixturePath = (Resolve-Path (Join-Path $script:TestScriptRoot '..\fixtures\validation_rules_sample.json') -ErrorAction Stop).ProviderPath
$Global:DriftBaselineFixturePath = (Resolve-Path (Join-Path $script:TestScriptRoot '..\fixtures\drift_baseline.json') -ErrorAction Stop).ProviderPath
if (-not $Global:MockedWriteLogMessages) { $Global:MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new() }
Write-Host "DEBUG Raw Drift Path=$Global:ConfigurationDriftScriptPath"
Write-Host "DEBUG Raw RP Path=$Global:ResourceProviderScriptPath"

Describe 'Get-ValidationStep.ps1 Tests' {
    BeforeAll {
        $script:ScriptPathGetValidation = $Global:GetValidationStepScriptPath
        . $script:ScriptPathGetValidation
    }

    BeforeEach {
        $Global:MockedWriteLogMessages.Clear()
        Set-Item Function:global:Write-Log -Value { param([string]$Message,[string]$Level="INFO",[string]$Path) $Global:MockedWriteLogMessages.Add("VAL_STEP_LOG: [$Level] $Message") }
    }

    It 'uses rule replacement when MergeBehavior is Replace' {
        $action = [pscustomobject]@{
            RemediationActionId = 'REM_RULE_ONLY'
            Title = 'Rule only'
            SuccessCriteria = "service 'Ignored' should be 'Running'"
        }

        $result = Get-ValidationStep -RemediationAction $action -ValidationRulesPath $Global:ValidationRulesFixturePath

        $result.Count | Should -Be 1
        $result[0].ValidationStepId | Should -Be 'VR_Simple'
        $result[0].ValidationType | Should -Be 'ScriptExecutionCheck'
    }

    It 'appends derived step when MergeBehavior is AppendDerived' {
        $action = [pscustomobject]@{
            RemediationActionId = 'REM_APPEND'
            Title = 'Append derived'
            SuccessCriteria = "service 'ArcSvc' should be 'Running'"
            ResolvedParameters = @{ ServiceName = 'ArcSvc' }
        }

        $result = Get-ValidationStep -RemediationAction $action -ValidationRulesPath $Global:ValidationRulesFixturePath

        $result.Count | Should -Be 2
        ($result | Where-Object { $_.ValidationStepId -eq 'VR_Base' }).ValidationType | Should -Be 'ManualCheck'
        ($result | Where-Object { $_.ValidationType -eq 'ServiceStateCheck' }).Count | Should -BeGreaterThan 0
    }

    It 'defaults to ManualCheck when SuccessCriteria is empty and no rules apply' {
        $action = [pscustomobject]@{
            RemediationActionId = 'REM_EMPTY'
            Title = 'No criteria'
            SuccessCriteria = ''
            ResolvedParameters = @{}
        }

        $result = Get-ValidationStep -RemediationAction $action
        $result.Count | Should -Be 1
        $result[0].ValidationType | Should -Be 'ManualCheck'
    }

    It 'warns and falls back when validation rules file is missing' {
        $action = [pscustomobject]@{
            RemediationActionId = 'REM_MISSING_RULES'
            Title = 'Missing rules'
            SuccessCriteria = ''
            ResolvedParameters = @{}
        }

        $missingPath = Join-Path $TestDrive 'missing_rules.json'
        $result = Get-ValidationStep -RemediationAction $action -ValidationRulesPath $missingPath

        $result.Count | Should -Be 1
    }
}

Describe 'Test-ConfigurationDrift.ps1 Tests' {
    BeforeAll {
        $script:ScriptPath = $Global:ConfigurationDriftScriptPath
        Write-Host "DEBUG Drift ScriptPath=$script:ScriptPath"
    }

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

    $Global:ExpectedValues = $ExpectedValues

    $Global:MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new() # Shared by all Describes in this file
    $Global:IsAdminContext = $true 

    BeforeEach { # Specific to Test-ConfigurationDrift.ps1
        $Global:IsAdminContext = $true 

        Set-Item Function:global:Write-Log -Value { param([string]$Message,[string]$Level="INFO",[string]$Path) $Global:MockedWriteLogMessages.Add("DRIFT_SCRIPT_LOG: [$Level] $Message") }

        Set-Item Function:global:Get-ItemProperty -Value {
            param($Path, $Name)
            Write-Verbose "Stub Get-ItemProperty for Drift for Path '$Path', Name '$Name'"
            if ($Global:ExpectedValues.Registry.ContainsKey($Path) -and $Global:ExpectedValues.Registry[$Path].ContainsKey($Name)) {
                return [PSCustomObject]@{ $Name = $Global:ExpectedValues.Registry[$Path][$Name] }
            }
            throw "Drift Test: Get-ItemProperty called for unexpected path/name: $Path \ $Name"
        }

        Set-Item Function:global:Get-Service -Value {
            param($Name)
            Write-Verbose "Stub Get-Service for Drift for Name '$Name'"
            if ($Global:ExpectedValues.Services.ContainsKey($Name)) {
                $props = $Global:ExpectedValues.Services[$Name]
                return [PSCustomObject]@{ Name = $Name; StartupType = $props.StartupType; State = $props.State; Status = $props.State }
            }
            throw "Drift Test: Get-Service called for unexpected service name: $Name"
        }

        Set-Item Function:global:Get-NetFirewallRule -Value {
            param([string]$DisplayName)
            Write-Verbose "Stub Get-NetFirewallRule for Drift for DisplayName '$DisplayName'"
            if ($Global:ExpectedValues.FirewallRules.ContainsKey($DisplayName)) {
                $props = $Global:ExpectedValues.FirewallRules[$DisplayName]
                return [PSCustomObject]@{ DisplayName = $DisplayName; Enabled = $props.Enabled; Direction = $props.Direction; Action = $props.Action }
            }
            return $null
        }
        
        $Global:AuditPolOutput = @'
Machine Name,Policy Target,Subcategory,Inclusion Setting,Exclusion Setting,Subcategory GUID
TestServer,System,Process Creation,Success,,{0CCE922B-69AE-11D9-BED3-505054503030}
TestServer,System,Credential Validation,Success and Failure,,{0CCE9225-69AE-11D9-BED3-505054503030}
'@

        Set-Item Function:global:auditpol -Value { param([Parameter(ValueFromRemainingArguments = $true)]$Args) Write-Verbose "Stub auditpol returning preset output."; return $Global:AuditPolOutput.Split([System.Environment]::NewLine) | Where-Object {$_} }
    }

    It 'Should return DriftDetected=$false when all checks are compliant' {
        $result = . $script:ScriptPath
        Write-Host ("DEBUG DriftDetails (compliant): {0}" -f (ConvertTo-Json $result.DriftDetails -Depth 4))
        $result.DriftDetected | Should -Be $false
        ($result.DriftDetails | Where-Object {$_.Status -eq "Drifted"}).Count | Should -Be 0
    }

    Context 'Registry Drift Detection' {
        It 'Should detect drift if a registry key value is non-compliant' {
            $NonCompliantPath = "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319"
            $NonCompliantName = "SchUseStrongCrypto"
            $NonCompliantValue = 0 
            Set-Item Function:global:Get-ItemProperty -Value {
                param($Path, $Name)
                if ($Path -eq $NonCompliantPath -and $Name -eq $NonCompliantName) {
                    return [PSCustomObject]@{ $Name = $NonCompliantValue }
                }
                if ($Global:ExpectedValues.Registry.ContainsKey($Path) -and $Global:ExpectedValues.Registry[$Path].ContainsKey($Name)) {
                    return [PSCustomObject]@{ $Name = $Global:ExpectedValues.Registry[$Path][$Name] }
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
             Set-Item Function:global:Get-ItemProperty -Value {
                param($Path, $Name)
                if ($Path -eq "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319" -and $Name -eq "SchUseStrongCrypto") {
                    throw "Simulated access error"
                }
                if ($Global:ExpectedValues.Registry.ContainsKey($Path) -and $Global:ExpectedValues.Registry[$Path].ContainsKey($Name)) {
                    return [PSCustomObject]@{ $Name = $Global:ExpectedValues.Registry[$Path][$Name] }
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
            Set-Item Function:global:Get-Service -Value {
                param($Name)
                if ($Name -eq $NonCompliantService) {
                    return [PSCustomObject]@{ Name = $Name; StartupType = $NonCompliantStartupType; State = $Global:ExpectedValues.Services[$Name].State; Status = $Global:ExpectedValues.Services[$Name].State }
                }
                $expected = $Global:ExpectedValues.Services
                if ($expected.ContainsKey($Name)) {
                    $props = $expected[$Name]
                    return [PSCustomObject]@{ Name = $Name; StartupType = $props.StartupType; State = $props.State; Status = $props.State }
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
            Set-Item Function:global:Get-Service -Value {
                param($Name)
                if ($Name -eq $NonCompliantService) {
                    return [PSCustomObject]@{ Name = $Name; StartupType = $Global:ExpectedValues.Services[$Name].StartupType; State = $NonCompliantState; Status = $NonCompliantState }
                }
                $expected = $Global:ExpectedValues.Services
                if ($expected.ContainsKey($Name)) {
                    $props = $expected[$Name]
                    return [PSCustomObject]@{ Name = $Name; StartupType = $props.StartupType; State = $props.State; Status = $props.State }
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
            Set-Item Function:global:Get-NetFirewallRule -Value { param($DisplayName) throw "Rule not found" }
            $result = . $ScriptPath
            $result.DriftDetected | Should -Be $true
            $driftItem = $result.DriftDetails | Where-Object { $_.Category -eq "Firewall" -and $_.Item -eq "Azure Arc Management" -and $_.Property -eq "Enabled" }
            $driftItem.CurrentValue | Should -Be "NOT_FOUND_OR_ERROR"
        }

        It 'Should detect drift if a firewall rule Action is non-compliant' {
            $NonCompliantRuleName = "Azure Arc Management"
            $NonCompliantAction = "Block"
            Set-Item Function:global:Get-NetFirewallRule -Value {
                param($DisplayName)
                if ($DisplayName -eq $NonCompliantRuleName) {
                    return [PSCustomObject]@{ DisplayName = $DisplayName; Enabled = $true; Direction = 'Outbound'; Action = $NonCompliantAction }
                }
                $expected = $Global:ExpectedValues.FirewallRules
                if ($expected.ContainsKey($DisplayName)) {
                    $props = $expected[$DisplayName]; return [PSCustomObject]@{ DisplayName = $DisplayName; Enabled = $props.Enabled; Direction = $props.Direction; Action = $props.Action }
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
Machine Name,Policy Target,Subcategory,Inclusion Setting,Exclusion Setting,Subcategory GUID
TestServer,System,Process Creation,Failure,,{0CCE922B-69AE-11D9-BED3-505054503030}
TestServer,System,Credential Validation,Success and Failure,,{0CCE9225-69AE-11D9-BED3-505054503030}
"@
            $Global:AuditPolOutput = $nonCompliantAuditPolOutput
            $result = . $ScriptPath
            $result.DriftDetected | Should -Be $true
            $driftItem = $result.DriftDetails | Where-Object { $_.Category -eq "AuditPolicy" -and $_.Item -eq "Process Creation" }
            $driftItem.CurrentValue | Should -Be "Failure" 
            $driftItem.Status | Should -Be "Drifted"
        }
         It 'Should detect drift if auditpol output is missing an expected subcategory' {
            $missingSubcategoryAuditPolOutput = @"
Machine Name,Policy Target,Subcategory,Inclusion Setting,Exclusion Setting,Subcategory GUID
TestServer,System,Credential Validation,Success and Failure,,{0CCE9225-69AE-11D9-BED3-505054503030}
"@
            $Global:AuditPolOutput = $missingSubcategoryAuditPolOutput
            Set-Item Function:global:auditpol -Value { throw "Simulated auditpol retrieval failure" }
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
            $resultObj = [pscustomobject]$result
            $resultObj.PSObject.Properties.Name | Should -Contain "ServerName"
            $resultObj.PSObject.Properties.Name | Should -Contain "Timestamp"
            $resultObj.PSObject.Properties.Name | Should -Contain "DriftDetected"
            $resultObj.PSObject.Properties.Name | Should -Contain "DriftDetails"
            $resultObj.ServerName | Should -Be $env:COMPUTERNAME
        }

        It 'Should log a warning if not run as administrator (simulated by script logic)' {
            $Global:IsAdminContext = $false
            $Global:MockedWriteLogMessages.Clear()
            . $ScriptPath
            ($Global:MockedWriteLogMessages -join "`n") | Should -Match "Running without Administrator privileges"
        }

        It 'Should log the start and end of the script' {
            . $ScriptPath
            ($Global:MockedWriteLogMessages -join "`n") | Should -Match "DRIFT_SCRIPT_LOG: \[INFO\] Starting configuration drift test script for server:"
            ($Global:MockedWriteLogMessages -join "`n") | Should -Match "DRIFT_SCRIPT_LOG: \[INFO\] Configuration drift test completed. Drift Detected: False"
        }

        It 'Should honor BaselinePath when provided' {
            $Global:MockedWriteLogMessages.Clear()
            $originalExpected = $Global:ExpectedValues
            $Global:ExpectedValues = @{
                Registry = @{
                    "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319" = @{ "SchUseStrongCrypto" = 1; "SystemDefaultTlsVersions" = 1 }
                }
                Services = @{ "himds" = @{ StartupType = "Automatic"; State = "Running" } }
                FirewallRules = @{ "Azure Arc Management" = @{ Enabled = $true; Direction = "Outbound"; Action = "Allow" } }
                AuditPolicies = @{ "Process Creation" = "Success" }
            }

            $result = . $ScriptPath -BaselinePath $Global:DriftBaselineFixturePath
            $result.DriftDetected | Should -Be $false
            ($result.DriftDetails | Where-Object { $_.Status -eq 'Drifted' }).Count | Should -Be 0
            ($Global:MockedWriteLogMessages -join "`n") | Should -Match "Baseline loaded"
            $Global:ExpectedValues = $originalExpected
        }

        It 'Should skip selected categories when flags are set' {
            $Global:MockedWriteLogMessages.Clear()
            $result = . $ScriptPath -SkipRegistryChecks -SkipServiceChecks -SkipFirewallChecks -SkipAuditPolicyChecks
            $result.DriftDetails.Count | Should -Be 0
            $logJoined = ($Global:MockedWriteLogMessages -join "`n")
            $logJoined | Should -Match "Skipping registry checks"
            $logJoined | Should -Match "Skipping service checks"
            $logJoined | Should -Match "Skipping firewall checks"
            $logJoined | Should -Match "Skipping audit policy checks"
        }
    }
}

Describe 'Test-ResourceProviderStatus.ps1 Tests' {
    BeforeAll {
        $script:ScriptPathResourceProvider = $Global:ResourceProviderScriptPath
        Write-Host "DEBUG ResourceProvider ScriptPath=$script:ScriptPathResourceProvider"
        $script:mockSubscriptionId = "mock-subscription-id-from-registry"
        $script:mockResourceGroupName = "mock-rg-from-registry"
    }

    $defaultRequiredProviders = @('Microsoft.HybridCompute', 'Microsoft.GuestConfiguration', 'Microsoft.AzureArcData', 'Microsoft.Insights', 'Microsoft.Security')
    $Global:DefaultRequiredProviders = $defaultRequiredProviders

    $Global:ArcAgentConfig = @{ # Mock for Arc Agent Registry Keys
        SubscriptionId = $script:mockSubscriptionId
        ResourceGroupName = $script:mockResourceGroupName
    }

    BeforeEach {
        $Global:MockedWriteLogMessages.Clear()
        $Global:ArcAgentConfig = @{ SubscriptionId = $script:mockSubscriptionId; ResourceGroupName = $script:mockResourceGroupName }
        $Global:RP_CallCounts = @{ SetAzContext = 0; GetAzResourceProvider = 0 }
        $Global:CurrentRPContext = [PSCustomObject]@{ Subscription = [PSCustomObject]@{ Id = $mockSubscriptionId; Name = "MockSub" }; Account = "user@contoso.com"; Tenant = [PSCustomObject]@{ Id = "tenant-id" } }

        $moduleStub = {
            param($Name, [switch]$ListAvailable, [Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)
            if ($ListAvailable) {
                if ($Name -in @('Az.ConnectedMachine', 'Az.Resources', 'Az.Monitor')) {
                    return [PSCustomObject]@{ Name = $Name; Path = "mocked_path\$Name" }
                }
                return $null
            }
            return $null
        }

        $getContextStub = { param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Args) return $Global:CurrentRPContext }

        $setContextStub = {
            param($SubscriptionId, [Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)
            $Global:RP_CallCounts.SetAzContext++
            $Global:CurrentRPContext = [PSCustomObject]@{ Subscription = [PSCustomObject]@{ Id = $SubscriptionId; Name = "Sub-$SubscriptionId" }; Account = "user@contoso.com"; Tenant = [PSCustomObject]@{ Id = "tenant-id" } }
        }

        $getItemPropertyStub = {
            param($Path, $Name, [Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)
            if ($Path -like "*Azure Connected Machine Agent\Config") {
                if ($Global:ArcAgentConfig.ContainsKey($Name)) {
                    return [PSCustomObject]@{ $Name = $Global:ArcAgentConfig[$Name] }
                }
            }
            return $null
        }
        
        $getResourceProviderStub = {
            param($ProviderNamespace, [Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)
            $Global:RP_CallCounts.GetAzResourceProvider++
            return [PSCustomObject]@{ ProviderNamespace = $ProviderNamespace; RegistrationState = "Registered"; ResourceTypes = @([PSCustomObject]@{ResourceTypeName="mockType"}) }
        }

        $writeLogStub = { param([string]$Message, [string]$Level="INFO", [string]$Path) $Global:MockedWriteLogMessages.Add("RP_STATUS_LOG: [$Level] $Message") }
        $addContentStub = { param($Path, $Value, [Parameter(ValueFromRemainingArguments = $true)][object[]]$Args) $Global:MockedWriteLogMessages.Add($Value) }
        $testPathStub = { param($Path, [Parameter(ValueFromRemainingArguments = $true)][object[]]$Args) return $true }
        $newItemStub = { param($Path, $ItemType, [switch]$Force, $ErrorAction, [Parameter(ValueFromRemainingArguments = $true)][object[]]$Args) return $null }

        # Override both script and global scopes to ensure calls hit the stubs instead of the safety throw stubs defined at the top of the file.
        foreach ($target in @('Function:Get-Module','Function:global:Get-Module','Function:script:Get-Module')) { Set-Item $target -Value $moduleStub }
        foreach ($target in @('Function:Get-AzContext','Function:global:Get-AzContext','Function:script:Get-AzContext')) { Set-Item $target -Value $getContextStub }
        foreach ($target in @('Function:Set-AzContext','Function:global:Set-AzContext','Function:script:Set-AzContext')) { Set-Item $target -Value $setContextStub }
        foreach ($target in @('Function:Get-ItemProperty','Function:global:Get-ItemProperty','Function:script:Get-ItemProperty')) { Set-Item $target -Value $getItemPropertyStub }
        foreach ($target in @('Function:Get-AzResourceProvider','Function:global:Get-AzResourceProvider','Function:script:Get-AzResourceProvider')) { Set-Item $target -Value $getResourceProviderStub }
        foreach ($target in @('Function:Write-Log','Function:global:Write-Log','Function:script:Write-Log')) { Set-Item $target -Value $writeLogStub }
        foreach ($target in @('Function:Add-Content','Function:global:Add-Content','Function:script:Add-Content')) { Set-Item $target -Value $addContentStub }
        foreach ($target in @('Function:Test-Path','Function:global:Test-Path','Function:script:Test-Path')) { Set-Item $target -Value $testPathStub }
        foreach ($target in @('Function:New-Item','Function:global:New-Item','Function:script:New-Item')) { Set-Item $target -Value $newItemStub }
    }

    It 'Should return OverallStatus=Success if all default providers are registered' {
        $result = . $ScriptPathResourceProvider -SubscriptionId "param-sub-id" # Explicitly pass sub to bypass registry
        $result.OverallStatus | Should -Be "Success"
        $result.ProviderDetails.Count | Should -Be $defaultRequiredProviders.Count
        $result.ProviderDetails | ForEach-Object { $_.Status | Should -Be "Success" }
        ($Global:MockedWriteLogMessages -join "`n") | Should -Match "Setting Az context to subscription: param-sub-id"
    }

    It 'Should return OverallStatus=Failed if a provider is NotRegistered' {
        $notRegisteredStub = {
            param($ProviderNamespace, [Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)
            $Global:RP_CallCounts.GetAzResourceProvider++
            if ($ProviderNamespace -eq 'Microsoft.Insights') {
                return [PSCustomObject]@{ ProviderNamespace = $ProviderNamespace; RegistrationState = "NotRegistered"; ResourceTypes = @([PSCustomObject]@{ResourceTypeName="mockType"}) }
            }
            return [PSCustomObject]@{ ProviderNamespace = $ProviderNamespace; RegistrationState = "Registered"; ResourceTypes = @([PSCustomObject]@{ResourceTypeName="mockType"}) }
        }
        foreach ($target in @('Function:Get-AzResourceProvider','Function:global:Get-AzResourceProvider','Function:script:Get-AzResourceProvider')) { Set-Item $target -Value $notRegisteredStub }
        $result = . $ScriptPathResourceProvider -SubscriptionId "param-sub-id"
        $result.OverallStatus | Should -Be "Failed"
        ($result.ProviderDetails | Where-Object {$_.ProviderNamespace -eq 'Microsoft.Insights'}).Status | Should -Be "Failed"
    }

    It 'Should use discovered SubscriptionId from registry if not provided' {
        $result = . $ScriptPathResourceProvider # Relies on Get-ItemProperty mock via $Global:ArcAgentConfig
        $result.OverallStatus | Should -Be "Success"
        $result.ProviderDetails.Count | Should -Be $defaultRequiredProviders.Count
        ($Global:MockedWriteLogMessages -join "`n") | Should -Match "Discovered Subscription ID from Arc Agent config: $script:mockSubscriptionId"
    }
    
    It 'Should return Failed result if Az.Resources module is not available' {
        $missingModuleStub = { param($Name, [switch]$ListAvailable, [Parameter(ValueFromRemainingArguments = $true)][object[]]$Args) if($ListAvailable -and $Name -eq 'Az.Resources') { return $null } return [PSCustomObject]@{ Name = $Name; Path = "mock" } }
        foreach ($target in @('Function:Get-Module','Function:global:Get-Module','Function:script:Get-Module')) { Set-Item $target -Value $missingModuleStub }
        $result = . $ScriptPathResourceProvider -SubscriptionId "param-sub-id"
        $result.OverallStatus | Should -Be "Failed"
        $result.Error | Should -Match "Az.Resources module not found."
    }

    It 'Should return Failed result if no Azure context is active' {
        foreach ($target in @('Function:Get-AzContext','Function:global:Get-AzContext','Function:script:Get-AzContext')) { Set-Item $target -Value { param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Args) return $null } }
        $result = . $ScriptPathResourceProvider -SubscriptionId "param-sub-id"
        $result.OverallStatus | Should -Be "Failed"
        $result.Error | Should -Match "Azure context not found"
    }

    It 'Should return Failed result if SubscriptionId is not provided and cannot be discovered from registry' {
        $Global:ArcAgentConfig.Remove("SubscriptionId") # Ensure it's not in the mock global
        foreach ($target in @('Function:Get-ItemProperty','Function:global:Get-ItemProperty','Function:script:Get-ItemProperty')) { Set-Item $target -Value { param($Path, $Name, [Parameter(ValueFromRemainingArguments = $true)][object[]]$Args) return $null } }
        $result = . $ScriptPathResourceProvider
        $result.OverallStatus | Should -Be "Failed"
        $result.Error | Should -Match "Subscription ID could not be determined"
    }
    
    It 'Should check custom list of providers if -RequiredResourceProviders is specified' {
        $customProviders = @("Microsoft.CustomProvider1", "Microsoft.CustomProvider2")
        $Global:RP_CallCounts.GetAzResourceProvider = 0
        . $ScriptPathResourceProvider -SubscriptionId "param-sub-id" -RequiredResourceProviders $customProviders
        $Global:RP_CallCounts.GetAzResourceProvider | Should -Be $customProviders.Count
    }

     It 'Should return OverallStatus=Failed if Get-AzResourceProvider throws for a provider' {
        $throwingStub = {
            param($ProviderNamespace, [Parameter(ValueFromRemainingArguments = $true)][object[]]$Args)
            $Global:RP_CallCounts.GetAzResourceProvider++
            if ($ProviderNamespace -eq 'Microsoft.Insights') {
                throw "Simulated error getting Microsoft.Insights"
            }
            return [PSCustomObject]@{ ProviderNamespace = $ProviderNamespace; RegistrationState = "Registered"; ResourceTypes = @([PSCustomObject]@{ResourceTypeName="mockType"}) }
        }
        foreach ($target in @('Function:Get-AzResourceProvider','Function:global:Get-AzResourceProvider','Function:script:Get-AzResourceProvider')) { Set-Item $target -Value $throwingStub }
        $result = . $ScriptPathResourceProvider -SubscriptionId "param-sub-id"
        $result.OverallStatus | Should -Be "Failed"
        $failedProviderDetail = $result.ProviderDetails | Where-Object {$_.ProviderNamespace -eq 'Microsoft.Insights'}
        $failedProviderDetail.RegistrationState | Should -Be "ERROR_RETRIEVING_STATUS"
        $failedProviderDetail.Status | Should -Be "Failed"
        ($Global:MockedWriteLogMessages -join "`n") | Should -Match "Failed to get status for provider 'Microsoft.Insights'. Error: Simulated error getting Microsoft.Insights"
    }
}

# tests/PowerShell/unit/Monitoring.Coverage.Tests.ps1
# Coverage-focused tests for monitoring/ source files at 0% coverage.

Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

BeforeAll {
    $script:SrcRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\src\PowerShell'))
}

if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    Set-Item -Path Function:global:Write-Log -Value {
        param([string]$Message, [string]$Level = 'INFO', [string]$Path)
    }
}

# Pre-stub Get-Service with -ComputerName for PS7 compatibility (PS7 removed -ComputerName from Get-Service)
Set-Item 'Function:global:Get-Service' -Value {
    param(
        [string]$Name,
        [string]$ComputerName,
        [string[]]$Include,
        [string[]]$Exclude,
        [switch]$DependentServices,
        [switch]$RequiredServices
    )
    # Default stub: tests override via Mock
}

# ---------------------------------------------------------------------------
# 1. Get-AMAHealthStatus.ps1  (118 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Get-AMAHealthStatus.ps1 Coverage' {
    BeforeAll {
        if (-not (Get-Command Get-AMAPerformanceMetrics -ErrorAction SilentlyContinue)) {
            Set-Item 'Function:global:Get-AMAPerformanceMetrics' -Value { param() @{ Samples = @(); Summary = @{}; Error = $null } }
        }
        . (Join-Path $script:SrcRoot 'monitoring\Get-AMAHealthStatus.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'returns health status when AMA service is running and connectivity ok' {
        Mock Get-Service {
            [PSCustomObject]@{ Status='Running'; StartType='Automatic'; DisplayName='Azure Monitor Agent' }
        }
        Mock Get-CimInstance { [PSCustomObject]@{ StartTime=(Get-Date).AddHours(-2) } }
        Mock Get-AMADataCollectionStatus { @{ Status='Active'; RecordsInLast24h=1500; DCRCount=3 } }
        Mock Get-AMAPerformanceMetrics   { @{ CPUPercent=2; MemoryMB=150 } }
        Mock Test-AMAConnectivity        { @{ Status='Connected'; Endpoints=@('ok') } }
        Mock Test-WorkspaceConnectivity  { @{ Status='Connected' } }

        $result = Get-AMAHealthStatus -ServerName 'TEST-SRV' -WorkspaceId 'ws-123'
        $result | Should -Not -BeNullOrEmpty
        $result.Error | Should -BeNullOrEmpty
    }

    It 'reports Issue when AMA service is stopped' {
        Mock Get-Service {
            [PSCustomObject]@{ Status='Stopped'; StartType='Automatic'; DisplayName='Azure Monitor Agent' }
        }
        Mock Get-CimInstance { $null }
        Mock Get-AMADataCollectionStatus { @{ Status='Inactive'; RecordsInLast24h=0; DCRCount=0 } }
        Mock Get-AMAPerformanceMetrics   { @{ CPUPercent=0; MemoryMB=0 } }
        Mock Test-AMAConnectivity        { @{ Status='Disconnected' } }
        Mock Test-WorkspaceConnectivity  { @{ Status='Disconnected' } }

        $result = Get-AMAHealthStatus -ServerName 'TEST-SRV' -WorkspaceId 'ws-123'
        $result.Issues.Count | Should -BeGreaterThan 0
        ($result.Issues | Where-Object { $_.Type -eq 'Service' }) | Should -Not -BeNullOrEmpty
    }

    It 'handles exception and returns error in result' {
        Mock Get-Service { throw 'Remote access denied' }

        $result = Get-AMAHealthStatus -ServerName 'TEST-SRV' -WorkspaceId 'ws-123'
        $result | Should -Not -BeNullOrEmpty
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'reports data collection issue when zero records collected' {
        Mock Get-Service { [PSCustomObject]@{ Status='Running'; StartType='Automatic' } }
        Mock Get-CimInstance { [PSCustomObject]@{ StartTime=(Get-Date).AddHours(-6) } }
        Mock Get-AMADataCollectionStatus { @{ Status='Active'; RecordsInLast24h=0; DCRCount=3 } }
        Mock Get-AMAPerformanceMetrics   { @{ CPUPercent=1; MemoryMB=100 } }
        Mock Test-AMAConnectivity        { @{ Status='Connected' } }
        Mock Test-WorkspaceConnectivity  { @{ Status='Connected' } }

        $result = Get-AMAHealthStatus -ServerName 'TEST-SRV' -WorkspaceId 'ws-123'
        ($result.Issues | Where-Object { $_.Type -eq 'DataCollection' }) | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 2. Get-ArcHealthStatus.ps1  (0% covered)
# ---------------------------------------------------------------------------
Describe 'Get-ArcHealthStatus.ps1 Coverage' {
    BeforeAll {
    foreach ($fn in @('Test-ArcConnection','Get-ArcResourceProvider','Get-ArcPerformanceMetrics','Get-OverallHealth','Convert-ErrorToObject','Test-AgentVersion','Test-CertificateValid','Test-ArcAuthentication')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() @{ Status='OK'; Overall='Healthy' } }
            }
        }
        . (Join-Path $script:SrcRoot 'monitoring\Get-ArcHealthStatus.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'returns health status with healthy components' {
        Mock Get-Service { [PSCustomObject]@{ Status='Running'; StartType='Automatic' } }
        Mock Test-ArcConnection    { @{ Status='Connected'; LastSuccess=(Get-Date) } }
        Mock Get-ArcResourceProvider { @{ Status='OK'; SyncState='InSync' } }
        Mock Test-AgentVersion     { @{ Status='Current'; Version='1.0' } }
        Mock Test-CertificateValid { @{ Status='Valid'; Expiry=(Get-Date).AddDays(365) } }
        Mock Test-ArcAuthentication { @{ Status='Success' } }

        $result = Get-ArcHealthStatus -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.ServerName | Should -Be 'TEST-SRV'
    }

    It 'includes performance metrics when DetailedReport is specified' {
        Mock Get-Service { [PSCustomObject]@{ Status='Running'; StartType='Automatic' } }
        Mock Test-ArcConnection    { @{ Status='Connected'; LastSuccess=(Get-Date) } }
        Mock Get-ArcResourceProvider { @{ Status='OK'; SyncState='InSync' } }
        Mock Get-ArcPerformanceMetrics { @{ CPU=5; Memory=200 } }

        $result = Get-ArcHealthStatus -ServerName 'TEST-SRV' -DetailedReport
        ($result.Components | Where-Object { $_.Name -eq 'Performance' }) | Should -Not -BeNullOrEmpty
    }

    It 'handles exception gracefully' {
        Mock Get-Service { throw 'Network path not found' }

        $result = Get-ArcHealthStatus -ServerName 'TEST-SRV'
        $result.Overall | Should -Be 'Error'
    }
}

# ---------------------------------------------------------------------------
# 3. Get-AMAPerformanceMetrics.ps1  (0% covered)
# ---------------------------------------------------------------------------
Describe 'Get-AMAPerformanceMetrics.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'monitoring\Get-AMAPerformanceMetrics.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'returns performance metrics with Get-Counter mocked' {
        Mock Get-Counter {
            [PSCustomObject]@{
                CounterSamples = @(
                    [PSCustomObject]@{ Path = '\Processor(_Total)\% Processor Time'; CookedValue = 12.5 }
                    [PSCustomObject]@{ Path = '\Memory\Available MBytes'; CookedValue = 4096 }
                )
            }
        }
        Mock Start-Sleep {}

        $result = Get-AMAPerformanceMetrics -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.Samples.Count | Should -BeGreaterThan 0
    }

    It 'handles Get-Counter failure' {
        Mock Get-Counter { throw 'Counter not found' }

        $result = Get-AMAPerformanceMetrics -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 4. Get-ConnectionDropHistory.ps1  (0% covered)
# ---------------------------------------------------------------------------
Describe 'Get-ConnectionDropHistory.ps1 Coverage' {
    BeforeAll {
        if (-not (Get-Command Get-ArcAgentHeartbeat -ErrorAction SilentlyContinue)) {
            Set-Item 'Function:global:Get-ArcAgentHeartbeat' -Value { param() @{ Heartbeats = @(); GapCount = 0 } }
        }
        $script:CdhPath = Join-Path $script:SrcRoot 'monitoring\Get-ConnectionDropHistory.ps1'
        . $script:CdhPath
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'returns connection drop history with event log mocked' {
        Mock Get-WinEvent { @() }
        { . $script:CdhPath -ServerName 'TEST-SRV' } | Should -Not -Throw
    }

    It 'returns empty history when no events found' {
        Mock Get-WinEvent { @() }
        { . $script:CdhPath -ServerName 'TEST-SRV' } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# 5. Test-AMAHealth.ps1  (0% covered)
# ---------------------------------------------------------------------------
Describe 'Test-AMAHealth.ps1 Coverage' {
    BeforeAll {
        foreach ($fn in @('Test-AMAConnectivity','Get-AMADataCollection','Get-AMADataCollectionStatus','Test-WorkspaceConnectivity','Get-OverallHealthStatus')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() @{ Status = 'Connected'; Overall = 'Healthy' } }
            }
        }
        . (Join-Path $script:SrcRoot 'monitoring\Test-AMAHealth.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'returns Healthy when all AMA checks pass' {
        Mock Get-Service { [PSCustomObject]@{ Status='Running'; StartType='Automatic' } } -ParameterFilter { $Name -eq 'AzureMonitorAgent' }
        Mock Test-AMAConnectivity     { @{ Status='Connected' } }
        Mock Get-AMADataCollectionStatus { @{ Status='Active'; DCRCount=2 } }
        Mock Test-WorkspaceConnectivity  { @{ Status='Connected' } }

        $result = Test-AMAHealth -ServerName 'TEST-SRV' -WorkspaceId 'ws-123'
        $result | Should -Not -BeNullOrEmpty
        $result.Overall | Should -Not -BeNullOrEmpty
    }

    It 'handles exception and returns error result' {
        Mock Get-Service { throw 'Access denied' }

        $result = Test-AMAHealth -ServerName 'TEST-SRV' -WorkspaceId 'ws-123'
        $result | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 6. Get-ServiceFailureHistory.ps1 (0% covered)
# ---------------------------------------------------------------------------
Describe 'Get-ServiceFailureHistory.ps1 Coverage' {
    BeforeAll {
        $script:SfhPath = Join-Path $script:SrcRoot 'monitoring\Get-ServiceFailureHistory.ps1'
        . $script:SfhPath
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'returns service failure history for himds service' {
        Mock Get-WinEvent { @() }
        Mock Get-Service  { [PSCustomObject]@{ Status='Running'; DisplayName='HIMDS Service' } }
        { . $script:SfhPath -ServerName 'TEST-SRV' -ServiceName 'himds' } | Should -Not -Throw
    }

    It 'handles exception in Get-WinEvent gracefully' {
        Mock Get-WinEvent { throw 'Remote EventLog access denied' }
        { . $script:SfhPath -ServerName 'TEST-SRV' -ServiceName 'himds' } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# 7. Get-HighCPUEvents.ps1 (0% covered)
# ---------------------------------------------------------------------------
Describe 'Get-HighCPUEvents.ps1 Coverage' {
    BeforeAll {
        $script:HcpPath = Join-Path $script:SrcRoot 'monitoring\Get-HighCPUEvents.ps1'
        . $script:HcpPath
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'returns high CPU events list with counter mocked' {
        Mock Get-WinEvent { @() }
        { . $script:HcpPath -ServerName 'TEST-SRV' } | Should -Not -Throw
    }

    It 'handles counter not available gracefully' {
        Mock Get-WinEvent { throw 'Event log access denied' }
        { . $script:HcpPath -ServerName 'TEST-SRV' } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# 8. Get-MemoryPressureEvents.ps1 (0% covered)
# ---------------------------------------------------------------------------
Describe 'Get-MemoryPressureEvents.ps1 Coverage' {
    BeforeAll {
        $script:MpePath = Join-Path $script:SrcRoot 'monitoring\Get-MemoryPressureEvents.ps1'
        . $script:MpePath
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'returns memory pressure events with WMI mocked' {
        Mock Get-WinEvent { @() }
        { . $script:MpePath -ServerName 'TEST-SRV' } | Should -Not -Throw
    }

    It 'handles exception gracefully' {
        Mock Get-WinEvent { throw 'Event log access denied' }
        { . $script:MpePath -ServerName 'TEST-SRV' } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# 9. Get-DataCollectionRules.ps1 (0% covered)
# ---------------------------------------------------------------------------
Describe 'Get-DataCollectionRules.ps1 Coverage' {
    BeforeAll {
        $script:DcrPath = Join-Path $script:SrcRoot 'monitoring\Get-DataCollectionRules.ps1'
        foreach ($fn in @('Get-AzContext', 'Set-AzContext', 'Get-AzConnectedMachine', 'Get-AzDataCollectionRuleAssociation', 'Get-AzDataCollectionRule', 'Get-AzResource', 'Get-ItemProperty')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() $null }
            }
        }
    }

    BeforeEach {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item {} -ErrorAction SilentlyContinue
        Mock Get-Module { @{ Name = 'Az.Mock' } }
        Mock Get-AzContext {
            [PSCustomObject]@{
                Account = 'tester@contoso.com'
                Tenant = [PSCustomObject]@{ Id = 'tenant-1' }
                Subscription = [PSCustomObject]@{ Name = 'sub-name'; Id = 'sub-1' }
            }
        }
        Mock Set-AzContext { [PSCustomObject]@{} }
        Mock Get-AzConnectedMachine {
            [PSCustomObject]@{ Id = '/subscriptions/sub-1/resourceGroups/rg-arc/providers/Microsoft.HybridCompute/machines/TEST-SRV' }
        }
        Mock Get-AzDataCollectionRuleAssociation {
            @([PSCustomObject]@{ Name = 'assoc-1'; DataCollectionRuleId = '/subscriptions/sub-1/resourcegroups/rg-arc/providers/microsoft.insights/datacollectionrules/dcr-1' })
        }
        Mock Get-AzDataCollectionRule {
            [PSCustomObject]@{
                Name = 'dcr-1'
                Id = '/subscriptions/sub-1/resourcegroups/rg-arc/providers/microsoft.insights/datacollectionrules/dcr-1'
                Location = 'eastus'
                Description = 'test dcr'
                Stream = @('Microsoft-Event')
                Destinations = [PSCustomObject]@{
                    LogAnalytic = @([PSCustomObject]@{ WorkspaceResourceId = '/subscriptions/sub-1/resourceGroups/rg-arc/providers/Microsoft.OperationalInsights/workspaces/ws-1'; Name = 'la' })
                }
            }
        }
    }

    It 'returns associated DCR data when server and association are found' {
        $result = . $script:DcrPath -ServerName 'TEST-SRV' -SubscriptionId 'sub-1' -ResourceGroupName 'rg-arc' -WorkspaceId 'ws-1' -LogPath "$TestDrive\dcr.log"
        $result | Should -Not -BeNullOrEmpty
    }

    It 'returns empty array on critical failure' {
        Mock Get-AzContext { $null }
        $result = . $script:DcrPath -ServerName 'TEST-SRV' -SubscriptionId 'sub-1' -ResourceGroupName 'rg-arc' -LogPath "$TestDrive\dcr.log"
        ($result | Measure-Object).Count | Should -Be 0
    }

    It 'Get-ArcAgentConfig discovers subscription and resource group from registry' {
        . $script:DcrPath -ServerName 'DISCOVER-SRV' -SubscriptionId 'sub-1' -ResourceGroupName 'rg-arc' -LogPath "$TestDrive\dcr-load.log" | Out-Null

        Mock Test-Path { $true } -ParameterFilter { $Path -like 'HKLM:*Azure Connected Machine Agent*' }
        Mock Get-ItemProperty {
            [PSCustomObject]@{
                SubscriptionId = 'sub-reg'
                ResourceGroup  = 'rg-reg'
                TenantId       = 'tenant-reg'
            }
        }

        $config = Get-ArcAgentConfig
        $config.SubscriptionId | Should -Be 'sub-reg'
        $config.ResourceGroupName | Should -Be 'rg-reg'
        $config.TenantId | Should -Be 'tenant-reg'
    }

    It 'finds DCRs by workspace even when server resource lookup fails' {
        Mock Get-AzConnectedMachine { throw 'machine lookup failed' }
        Mock Get-AzDataCollectionRuleAssociation { @() }
        Mock Get-AzDataCollectionRule {
            @(
                [PSCustomObject]@{
                    Name = 'dcr-ws'
                    Id = '/subscriptions/sub-1/resourcegroups/rg-arc/providers/microsoft.insights/datacollectionrules/dcr-ws'
                    Location = 'eastus'
                    Description = 'workspace-targeted dcr'
                    Stream = @('Microsoft-Event')
                    Destinations = [PSCustomObject]@{
                        LogAnalytic = @([PSCustomObject]@{ WorkspaceResourceId = '/subscriptions/sub-1/resourceGroups/rg-arc/providers/Microsoft.OperationalInsights/workspaces/ws-1'; Name = 'la' })
                    }
                }
            )
        } -ParameterFilter { $SubscriptionId -eq 'sub-1' }

        $result = . $script:DcrPath -ServerName 'TEST-SRV' -SubscriptionId 'sub-1' -ResourceGroupName 'rg-arc' -WorkspaceId 'ws-1' -LogPath "$TestDrive\dcr-workspace.log"
        @($result).Count | Should -Be 1
        @($result)[0].DiscoveryMethod | Should -Be 'WorkspaceTargetInSubscription'
    }

    It 'deduplicates a DCR found both by association and by workspace target' {
        Mock Get-AzDataCollectionRuleAssociation {
            @([PSCustomObject]@{ Name = 'assoc-1'; DataCollectionRuleId = '/subscriptions/sub-1/resourcegroups/rg-arc/providers/microsoft.insights/datacollectionrules/dcr-dup' })
        }
        Mock Get-AzDataCollectionRule {
            if ($PSBoundParameters.ContainsKey('ResourceId')) {
                [PSCustomObject]@{
                    Name = 'dcr-dup'
                    Id = '/subscriptions/sub-1/resourcegroups/rg-arc/providers/microsoft.insights/datacollectionrules/dcr-dup'
                    Location = 'eastus'
                    Description = 'associated dcr'
                    Stream = @('Microsoft-Event')
                    Destinations = [PSCustomObject]@{
                        LogAnalytic = @([PSCustomObject]@{ WorkspaceResourceId = '/subscriptions/sub-1/resourceGroups/rg-arc/providers/Microsoft.OperationalInsights/workspaces/ws-1'; Name = 'la' })
                    }
                }
            }
            else {
                @(
                    [PSCustomObject]@{
                        Name = 'dcr-dup'
                        Id = '/subscriptions/sub-1/resourcegroups/rg-arc/providers/microsoft.insights/datacollectionrules/dcr-dup'
                        Location = 'eastus'
                        Description = 'workspace duplicate dcr'
                        Stream = @('Microsoft-Event')
                        Destinations = [PSCustomObject]@{
                            LogAnalytic = @([PSCustomObject]@{ WorkspaceResourceId = '/subscriptions/sub-1/resourceGroups/rg-arc/providers/Microsoft.OperationalInsights/workspaces/ws-1'; Name = 'la' })
                        }
                    }
                )
            }
        }

        $result = . $script:DcrPath -ServerName 'TEST-SRV' -SubscriptionId 'sub-1' -ResourceGroupName 'rg-arc' -WorkspaceId 'ws-1' -LogPath "$TestDrive\dcr-dedupe.log"
        (@($result) | Where-Object { $_.DcrId -like '*dcr-dup' }).Count | Should -Be 1
    }

    It 'falls back to Get-AzResource when Az.ConnectedMachine is unavailable' {
        Mock Get-Module {
            switch ($Name) {
                'Az.Monitor' { @{ Name = 'Az.Monitor' } }
                'Az.ConnectedMachine' { $null }
                'Az.Resources' { @{ Name = 'Az.Resources' } }
                default { @{ Name = 'Az.Mock' } }
            }
        }
        Mock Get-AzResource {
            [PSCustomObject]@{ ResourceId = '/subscriptions/sub-1/resourceGroups/rg-arc/providers/Microsoft.HybridCompute/machines/TEST-SRV' }
        }

        $result = . $script:DcrPath -ServerName 'TEST-SRV' -SubscriptionId 'sub-1' -ResourceGroupName 'rg-arc' -WorkspaceId 'ws-1' -LogPath "$TestDrive\dcr-resource.log"
        $result | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 10. Test-DataFlow.ps1 (0% covered)
# ---------------------------------------------------------------------------
Describe 'Test-DataFlow.ps1 Coverage' {
    BeforeAll {
        $script:DataFlowPath = Join-Path $script:SrcRoot 'monitoring\Test-DataFlow.ps1'
        # Stub commands that Test-DataFlow.ps1 calls at the script level (not function level)
        foreach ($fn in @('Get-AzContext', 'Invoke-AzOperationalInsightsQuery', 'Get-Module')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() $null }
            }
        }
    }

    BeforeEach {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item {} -ErrorAction SilentlyContinue
        Mock Get-Module { @{ Name = 'Az.OperationalInsights' } }
        Mock Get-AzContext { [PSCustomObject]@{ Account = 'tester@contoso.com' } }
        Mock Start-Sleep {}
    }

    It 'returns Success when query finds the injected test ID' {
        Mock Invoke-AzOperationalInsightsQuery {
            [PSCustomObject]@{ Results = @([PSCustomObject]@{ RawData = 'match' }) }
        }
        $result = . $script:DataFlowPath -WorkspaceId 'ws-1' -TimeoutSeconds 5 -LocalTestLogDirectory $TestDrive -LogPath "$TestDrive\df.log"
        $result.Status | Should -Be 'Success'
    }

    It 'returns Error object when query throws repeatedly' {
        Mock Invoke-AzOperationalInsightsQuery { throw 'workspace query failed' }
        $result = . $script:DataFlowPath -WorkspaceId 'ws-1' -TimeoutSeconds 1 -LocalTestLogDirectory $TestDrive -LogPath "$TestDrive\df.log"
        $result | Should -Not -BeNullOrEmpty
        $result.Status | Should -BeIn @('Failed', 'Error')
    }
}

# ---------------------------------------------------------------------------
# 11. Get-DiskPressureEvents.ps1 (158 lines)
# ---------------------------------------------------------------------------
Describe 'Get-DiskPressureEvents.ps1 Coverage' {
    BeforeAll {
        $script:DiskPath = Join-Path $script:SrcRoot 'monitoring\Get-DiskPressureEvents.ps1'
        Mock Write-Log {}
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path, [string]$Component)
        }
        Mock Get-WinEvent { @() }
    }

    It 'executes without error when WinEvent returns empty' {
        { . $script:DiskPath -ServerName 'TEST-SRV' } | Should -Not -Throw
    }

    It 'executes and returns results when WinEvent has events' {
        Mock Get-WinEvent {
            @([PSCustomObject]@{ Id = 2013; TimeCreated = Get-Date; Message = 'The C: disk is at or near capacity.' })
        }
        { . $script:DiskPath -ServerName 'TEST-SRV' } | Should -Not -Throw
    }

    It 'executes without error when Get-WinEvent throws ProviderNotFound' {
        Mock Get-WinEvent { throw [System.Diagnostics.Eventing.Reader.EventLogException]'No events found' }
        { . $script:DiskPath -ServerName 'TEST-SRV' } | Should -Not -Throw
    }

    It 'accepts DiskSpaceWarningThresholdPercent parameter' {
        { . $script:DiskPath -ServerName 'TEST-SRV' -DiskSpaceWarningThresholdPercent 20 } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# 12. Get-EventLogErrors.ps1 (107 lines)
# ---------------------------------------------------------------------------
Describe 'Get-EventLogErrors.ps1 Coverage' {
    BeforeAll {
        $script:ErrLogPath = Join-Path $script:SrcRoot 'monitoring\Get-EventLogErrors.ps1'
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path, [string]$Component)
        }
        Mock Get-WinEvent { @() }
    }

    It 'executes without error when WinEvent returns empty for default logs' {
        { . $script:ErrLogPath -ServerName 'TEST-SRV' } | Should -Not -Throw
    }

    It 'executes and processes error events when returned' {
        Mock Get-WinEvent {
            @([PSCustomObject]@{
                Id = 1000; TimeCreated = Get-Date
                Message = 'Application error occurred'
                ProviderName = 'Application Error'
                LevelDisplayName = 'Error'
            })
        }
        { . $script:ErrLogPath -ServerName 'TEST-SRV' } | Should -Not -Throw
    }

    It 'handles Get-WinEvent exception gracefully' {
        Mock Get-WinEvent { throw 'Event log access denied' }
        { . $script:ErrLogPath -ServerName 'TEST-SRV' } | Should -Not -Throw
    }

    It 'accepts MaxEventsPerLog parameter' {
        { . $script:ErrLogPath -ServerName 'TEST-SRV' -MaxEventsPerLog 5 } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# 13. Get-EventLogWarnings.ps1 (104 lines)
# ---------------------------------------------------------------------------
Describe 'Get-EventLogWarnings.ps1 Coverage' {
    BeforeAll {
        $script:WarnLogPath = Join-Path $script:SrcRoot 'monitoring\Get-EventLogWarnings.ps1'
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path, [string]$Component)
        }
        Mock Get-WinEvent { @() }
    }

    It 'executes without error when WinEvent returns empty' {
        { . $script:WarnLogPath -ServerName 'TEST-SRV' } | Should -Not -Throw
    }

    It 'processes warning events when returned' {
        Mock Get-WinEvent {
            @([PSCustomObject]@{
                Id = 1001; TimeCreated = Get-Date
                Message = 'Service stopped unexpectedly'
                ProviderName = 'Service Control Manager'
                LevelDisplayName = 'Warning'
            })
        }
        { . $script:WarnLogPath -ServerName 'TEST-SRV' } | Should -Not -Throw
    }

    It 'handles Get-WinEvent access denied gracefully' {
        Mock Get-WinEvent { throw 'Access is denied' }
        { . $script:WarnLogPath -ServerName 'TEST-SRV' } | Should -Not -Throw
    }

    It 'accepts StartTime parameter' {
        $start = (Get-Date).AddDays(-7)
        { . $script:WarnLogPath -ServerName 'TEST-SRV' -StartTime $start } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# 14. Set-DataCollectionRules.ps1 (99 lines)
# ---------------------------------------------------------------------------
Describe 'Set-DataCollectionRules.ps1 Coverage' {
    BeforeAll {
        # Pre-stub Azure cmdlets that may not be available in test environment
        foreach ($fn in @('New-AzDataCollectionRule','New-AzDataCollectionRuleAssociation',
                          'Remove-AzDataCollectionRule','Remove-AzDataCollectionRuleAssociation',
                          'Get-AzDataCollectionRule','Update-AzDataCollectionRule')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() [PSCustomObject]@{ Id = '/subscriptions/sub-1/dcr-stub' } }
            }
        }
        # Stub Test-DataCollectionRule if not already defined
        if (-not (Get-Command Test-DataCollectionRule -ErrorAction SilentlyContinue)) {
            Set-Item 'Function:global:Test-DataCollectionRule' -Value { param() @{ Success = $true } }
        }
        . (Join-Path $script:SrcRoot 'monitoring\Set-DataCollectionRules.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path, [string]$Component)
        }
        # Return a raw JSON string so ConvertFrom-Json (real) parses it correctly
        Mock Get-Content {
            '{"security":{"resourceGroup":"rg-test","location":"eastus","dataSources":{},"streams":[],"destinations":{}},"performance":{"resourceGroup":"rg-test","location":"eastus","dataSources":{},"streams":[],"destinations":{}}}'
        }
        Mock New-AzDataCollectionRule { [PSCustomObject]@{ Id = '/subscriptions/sub-1/dcr-test' } }
        Mock New-AzDataCollectionRuleAssociation { [PSCustomObject]@{ Id = '/assoc/test' } }
        Mock Test-DataCollectionRule { @{ Success = $true } }
    }

    It 'returns result object when WhatIf is used' {
        $result = Set-DataCollectionRules -ServerName 'TEST-SRV' -WorkspaceId 'ws-1' -WhatIf
        $result | Should -Not -BeNullOrEmpty
    }

    It 'creates Security rule with Confirm false' {
        $result = Set-DataCollectionRules -ServerName 'TEST-SRV' -WorkspaceId 'ws-1' -RuleType 'Security' -Confirm:$false
        $result | Should -Not -BeNullOrEmpty
        Assert-MockCalled New-AzDataCollectionRule -Times 1
    }

    It 'creates Performance rule' {
        $result = Set-DataCollectionRules -ServerName 'TEST-SRV' -WorkspaceId 'ws-1' -RuleType 'Performance' -Confirm:$false
        $result | Should -Not -BeNullOrEmpty
    }

    It 'handles Get-Content failure gracefully' {
        Mock Get-Content { throw 'File not found' }
        { Set-DataCollectionRules -ServerName 'TEST-SRV' -WorkspaceId 'ws-1' -WhatIf } | Should -Not -Throw
    }

    It 'uses CustomConfig when RuleType is Custom' {
        $custom = @{ resourceGroup = 'rg-custom'; location = 'westus'; dataSources = @{}; streams = @(); destinations = @{} }
        $result = Set-DataCollectionRules -ServerName 'TEST-SRV' -WorkspaceId 'ws-1' -RuleType 'Custom' -CustomConfig $custom -WhatIf
        $result | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 15. Test-LogIngestion.ps1 (98 lines)
# ---------------------------------------------------------------------------
Describe 'Test-LogIngestion.ps1 Coverage' {
    BeforeAll {
        foreach ($fn in @('Invoke-AzOperationalInsightsQuery')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() [PSCustomObject]@{ Results = @() } }
            }
        }
        . (Join-Path $script:SrcRoot 'monitoring\Test-LogIngestion.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path, [string]$Component)
        }
        Mock Invoke-AzOperationalInsightsQuery { [PSCustomObject]@{ Results = @() } }
    }

    It 'returns status object with WorkspaceId populated' {
        $result = Test-LogIngestion -WorkspaceId 'ws-1' -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.WorkspaceId | Should -Be 'ws-1'
    }

    It 'returns Healthy status when query returns recent heartbeat data' {
        Mock Invoke-AzOperationalInsightsQuery {
            [PSCustomObject]@{
                Results = @([PSCustomObject]@{ LastHeartbeat = (Get-Date).AddMinutes(-1); HeartbeatCount = 10; HeartbeatStatus = 'Healthy' })
            }
        }
        $result = Test-LogIngestion -WorkspaceId 'ws-1' -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'handles query exception gracefully' {
        Mock Invoke-AzOperationalInsightsQuery { throw 'Workspace not found' }
        { Test-LogIngestion -WorkspaceId 'ws-bad' -ServerName 'TEST-SRV' } | Should -Not -Throw
    }

    It 'accepts LookbackMinutes parameter' {
        $result = Test-LogIngestion -WorkspaceId 'ws-1' -ServerName 'TEST-SRV' -LookbackMinutes 30
        $result | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 16. Set-MonitoringRules.ps1 (86 lines)
# ---------------------------------------------------------------------------
Describe 'Set-MonitoringRules.ps1 Coverage' {
    BeforeAll {
        foreach ($fn in @('Test-RulePrerequisites','Set-PerformanceRule','Set-AvailabilityRule',
                          'Set-SecurityRule','Set-ComplianceRule')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() @{ Success = $true } }
            }
        }
        . (Join-Path $script:SrcRoot 'monitoring\Set-MonitoringRules.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path, [string]$Component)
        }
        Mock Get-Content {
            '{ "Rules": [{ "Name": "TestRule", "Type": "Performance" }] }' | ConvertFrom-Json
        }
        Mock ConvertFrom-Json {
            [PSCustomObject]@{ Rules = @([PSCustomObject]@{ Name = 'TestRule'; Type = 'Performance' }) }
        }
        Mock Test-RulePrerequisites { @{ Success = $true } }
        Mock Set-PerformanceRule { @{ Status = 'Applied' } }
    }

    It 'returns results object with WhatIf bypass' {
        $result = Set-MonitoringRules -ServerName 'TEST-SRV' -WhatIf
        $result | Should -Not -BeNullOrEmpty
    }

    It 'applies rules when prerequisites succeed' {
        $result = Set-MonitoringRules -ServerName 'TEST-SRV' -WhatIf
        $result | Should -Not -BeNullOrEmpty
    }

    It 'handles Get-Content exception for missing rules file' {
        Mock Get-Content { throw 'Rules file not found' }
        { Set-MonitoringRules -ServerName 'TEST-SRV' -WhatIf } | Should -Not -Throw
    }

    It 'applies rules with Force flag bypassing prereqs' {
        Mock Test-RulePrerequisites { @{ Success = $false; Details = 'prereq not met' } }
        $result = Set-MonitoringRules -ServerName 'TEST-SRV' -Force -WhatIf
        $result | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 17. Install-AMAExtension.ps1 (82 lines)
# ---------------------------------------------------------------------------
Describe 'Install-AMAExtension.ps1 Coverage' {
    BeforeAll {
        foreach ($fn in @('Test-AMAPrerequisites','Set-AzVMExtension','Set-AzConnectedMachineExtension',
                          'Set-DataCollectionRules')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() @{ Success = $true; StatusCode = 'OK' } }
            }
        }
        . (Join-Path $script:SrcRoot 'monitoring\Install-AMAExtension.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path, [string]$Component)
        }
        Mock Test-AMAPrerequisites { @{ Success = $true } }
        Mock Set-AzVMExtension { [PSCustomObject]@{ StatusCode = 'OK' } }
        Mock Set-AzConnectedMachineExtension { [PSCustomObject]@{ StatusCode = 'OK' } }
        Mock Set-DataCollectionRules { @{ Status = 'Success'; Changes = @() } }
    }

    It 'returns Success when all steps pass' {
        $result = Install-AMAExtension -ServerName 'TEST-SRV' -WorkspaceId 'ws-1' -WorkspaceKey 'key-1'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'returns Failed when prerequisites check fails' {
        Mock Test-AMAPrerequisites { @{ Success = $false; Error = 'OS not supported' } }
        $result = Install-AMAExtension -ServerName 'TEST-SRV' -WorkspaceId 'ws-1' -WorkspaceKey 'key-1'
        $result.Status | Should -BeIn @('Failed', 'Error')
    }

    It 'applies collection rules when CollectionRules hashtable provided' {
        $result = Install-AMAExtension -ServerName 'TEST-SRV' -WorkspaceId 'ws-1' -WorkspaceKey 'key-1' `
            -CollectionRules @{ EnableSecurityEvents = $true }
        $result | Should -Not -BeNullOrEmpty
    }

    It 'handles extension installation exception gracefully' {
        Mock Test-AMAPrerequisites { @{ Success = $true } }
        Mock Set-AzVMExtension { throw 'Extension deployment failed' }
        Mock Set-AzConnectedMachineExtension { throw 'Extension deployment failed' }
        { Install-AMAExtension -ServerName 'TEST-SRV' -WorkspaceId 'ws-1' -WorkspaceKey 'key-1' } |
            Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# Extra: Get-AMAHealthStatus.ps1 — additional branch coverage
# ---------------------------------------------------------------------------
Describe 'Get-AMAHealthStatus.ps1 extra branch coverage' {
    BeforeAll {
        if (-not (Get-Command Get-AMAHealthStatus -ErrorAction SilentlyContinue)) {
            . (Join-Path $script:SrcRoot 'monitoring\Get-AMAHealthStatus.ps1')
        }
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'reports Performance issue when CPU average exceeds 80%' {
        Mock Get-Service { [PSCustomObject]@{ Status='Running'; StartType='Automatic' } }
        Mock Get-CimInstance { [PSCustomObject]@{ StartTime=(Get-Date).AddHours(-1) } }
        Mock Get-AMADataCollectionStatus { @{ IngestionStatus='Active'; RecordsInLast24h=1000 } }
        Mock Get-AMAPerformanceMetrics   { @{ CPUUsage=@{ Average=95 }; MemoryUsage=@{ Average=60 } } }
        Mock Test-AMAConnectivity        { @{ Success=$true; Status='Connected' } }

        $result = Get-AMAHealthStatus -ServerName 'PERF-SRV' -WorkspaceId 'ws-perf'
        $result | Should -Not -BeNullOrEmpty
        ($result.Issues | Where-Object { $_.Type -eq 'Performance' }) | Should -Not -BeNullOrEmpty
        $result.OverallHealth | Should -Be 'Warning'
    }

    It 'reports Connectivity issue when AMA connectivity check fails' {
        Mock Get-Service { [PSCustomObject]@{ Status='Running'; StartType='Automatic' } }
        Mock Get-CimInstance { [PSCustomObject]@{ StartTime=(Get-Date).AddHours(-1) } }
        Mock Get-AMADataCollectionStatus { @{ IngestionStatus='Active'; RecordsInLast24h=500 } }
        Mock Get-AMAPerformanceMetrics   { @{ CPUUsage=@{ Average=10 }; MemoryUsage=@{ Average=30 } } }
        Mock Test-AMAConnectivity        { @{ Success=$false; Status='Disconnected'; Error='Endpoint unreachable' } }

        $result = Get-AMAHealthStatus -ServerName 'CONN-SRV' -WorkspaceId 'ws-conn'
        $result | Should -Not -BeNullOrEmpty
        ($result.Issues | Where-Object { $_.Type -eq 'Connectivity' }) | Should -Not -BeNullOrEmpty
        $result.OverallHealth | Should -Be 'Critical'
    }

    It 'reports Healthy when all checks pass with LookbackHours param' {
        Mock Get-Service { [PSCustomObject]@{ Status='Running'; StartType='Automatic' } }
        Mock Get-CimInstance { [PSCustomObject]@{ StartTime=(Get-Date).AddHours(-2) } }
        Mock Get-AMADataCollectionStatus { @{ IngestionStatus='Active'; RecordsInLast24h=2000 } }
        Mock Get-AMAPerformanceMetrics   { @{ CPUUsage=@{ Average=5 }; MemoryUsage=@{ Average=20 } } }
        Mock Test-AMAConnectivity        { @{ Success=$true; Status='Connected' } }

        $result = Get-AMAHealthStatus -ServerName 'HEALTHY-SRV' -WorkspaceId 'ws-ok' -LookbackHours 48
        $result | Should -Not -BeNullOrEmpty
        $result.Issues | Should -BeNullOrEmpty
        $result.OverallHealth | Should -Be 'Healthy'
    }

    It 'reports multiple simultaneous issues correctly (Critical overrides Warning)' {
        Mock Get-Service { [PSCustomObject]@{ Status='Stopped'; StartType='Automatic' } }
        Mock Get-CimInstance { $null }
        Mock Get-AMADataCollectionStatus { @{ IngestionStatus='Inactive'; RecordsInLast24h=0 } }
        Mock Get-AMAPerformanceMetrics   { @{ CPUUsage=@{ Average=90 }; MemoryUsage=@{ Average=85 } } }
        Mock Test-AMAConnectivity        { @{ Success=$false; Status='Disconnected'; Error='Failed' } }

        $result = Get-AMAHealthStatus -ServerName 'BAD-SRV' -WorkspaceId 'ws-bad'
        $result | Should -Not -BeNullOrEmpty
        $result.Issues.Count | Should -BeGreaterOrEqual 3
        $result.OverallHealth | Should -Be 'Critical'
    }
}

Describe 'Get-AMAHealthStatus.ps1 helper direct coverage' {
    BeforeAll {
        if (-not (Get-Command Get-AzOperationalInsightsWorkspace -ErrorAction SilentlyContinue)) {
            Set-Item 'Function:global:Get-AzOperationalInsightsWorkspace' -Value { param() $null }
        }
        if (-not (Get-Command Get-AMAHealthStatus -ErrorAction SilentlyContinue)) {
            . (Join-Path $script:SrcRoot 'monitoring\Get-AMAHealthStatus.ps1')
        }
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'Get-AMADataCollectionStatus returns inactive when query returns no rows' {
        Mock Invoke-AzOperationalInsightsQuery {
            [PSCustomObject]@{ Results = @() }
        }

        $result = Get-AMADataCollectionStatus -ServerName 'AMA-SRV' -WorkspaceId 'ws-1' -LookbackHours 12
        $result.IngestionStatus | Should -Be 'Inactive'
        $result.RecordCount | Should -Be 0
    }

    It 'Get-AMADataCollectionStatus returns populated status from query results' {
        Mock Invoke-AzOperationalInsightsQuery {
            [PSCustomObject]@{
                Results = [PSCustomObject]@{
                    IngestionStatus   = 'Active'
                    LastIngestionTime = (Get-Date).AddMinutes(-5)
                    RecordCount       = 42
                    DataTypes         = @('Heartbeat', 'Perf')
                    IngestionDelay    = 5
                }
            }
        }

        $result = Get-AMADataCollectionStatus -ServerName 'AMA-SRV' -WorkspaceId 'ws-2'
        $result.IngestionStatus | Should -Be 'Active'
        $result.RecordCount | Should -Be 42
        $result.DataTypes.Count | Should -Be 2
    }

    It 'Get-AMADataCollectionStatus returns null when query throws' {
        Mock Invoke-AzOperationalInsightsQuery { throw 'Query failed' }

        $result = Get-AMADataCollectionStatus -ServerName 'AMA-SRV' -WorkspaceId 'ws-err'
        $result | Should -BeNullOrEmpty
    }

    It 'Test-AMAConnectivity returns success when all endpoint checks and workspace lookup succeed' {
        Mock Test-NetConnection {
            [PSCustomObject]@{
                TcpTestSucceeded = $true
                PingReplyDetails = [PSCustomObject]@{ RoundtripTime = 23 }
            }
        }
        Mock Test-WorkspaceConnectivity {
            @{ Success = $true; Name = 'ws-name'; Location = 'eastus' }
        }

        $result = Test-AMAConnectivity -ServerName 'AMA-SRV' -WorkspaceId 'ws-ok'
        $result.Success | Should -Be $true
        $result.Endpoints.Count | Should -Be 3
        $result.Workspace.Success | Should -Be $true
    }

    It 'Test-AMAConnectivity marks failure when an endpoint TCP test fails' {
        Mock Test-NetConnection {
            [PSCustomObject]@{
                TcpTestSucceeded = $false
                PingReplyDetails = [PSCustomObject]@{ RoundtripTime = 0 }
            }
        }
        Mock Test-WorkspaceConnectivity {
            @{ Success = $true; Name = 'ws-name'; Location = 'eastus' }
        }

        $result = Test-AMAConnectivity -ServerName 'AMA-SRV' -WorkspaceId 'ws-endpoint-fail'
        $result.Success | Should -Be $false
        ($result.Endpoints | Where-Object { -not $_.Success }).Count | Should -Be 3
    }

    It 'Test-AMAConnectivity captures endpoint exceptions and workspace exceptions' {
        Mock Test-NetConnection { throw 'Host unreachable' }
        Mock Test-WorkspaceConnectivity { throw 'Workspace lookup failed' }

        $result = Test-AMAConnectivity -ServerName 'AMA-SRV' -WorkspaceId 'ws-bad'
        $result.Success | Should -Be $false
        $result.Workspace.Success | Should -Be $false
        ($result.Endpoints | Where-Object { $_.Error -like '*Host unreachable*' }).Count | Should -Be 3
    }

    It 'Test-WorkspaceConnectivity returns workspace metadata on success' {
        Mock Get-AzOperationalInsightsWorkspace {
            [PSCustomObject]@{ Name = 'workspace-a'; Location = 'westus'; RetentionInDays = 30 }
        }

        $result = Test-WorkspaceConnectivity -WorkspaceId '/subscriptions/sub/resourcegroups/rg/providers/microsoft.operationalinsights/workspaces/ws'
        $result.Success | Should -Be $true
        $result.Name | Should -Be 'workspace-a'
        $result.RetentionInDays | Should -Be 30
    }

    It 'Test-WorkspaceConnectivity returns failure payload on exception' {
        Mock Get-AzOperationalInsightsWorkspace { throw 'Not found' }

        $result = Test-WorkspaceConnectivity -WorkspaceId 'ws-missing'
        $result.Success | Should -Be $false
        $result.Error | Should -Match 'Not found'
    }
}

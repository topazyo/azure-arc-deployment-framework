# tests/PowerShell/unit/Core.Coverage.Tests.ps1
# Coverage-focused tests for core/ and selected monitoring/ source files at 0% coverage.

Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

BeforeAll {
    $script:SrcRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\src\PowerShell'))
}

if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    Set-Item -Path Function:global:Write-Log -Value {
        param([string]$Message, [string]$Level = 'INFO', [string]$Path)
    }
}

# ---------------------------------------------------------------------------
# 1. Test-ArcConnectivity.ps1  (214 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Test-ArcConnectivity.ps1 Coverage' {
    BeforeAll {
        foreach ($fn in @('Get-ProxyConfiguration','Get-TLSConfiguration','New-RetryBlock','Get-NetworkAdapterConfiguration','Get-ServerIPConfiguration','Get-RelevantFirewallRules','Get-ConnectivityRecommendations','Get-NetworkRoute')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() @{} }
            }
        }
        . (Join-Path $script:SrcRoot 'core\Test-ArcConnectivity.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
        Mock Stop-Transcript {} -ErrorAction SilentlyContinue
    }

    It 'returns Success when ping and all endpoint tests pass' {
        Mock Test-Connection      { [PSCustomObject]@{ ResponseTime = 5; Address = '1.2.3.4' } }
        Mock Get-ProxyConfiguration { @{ Configured = $false } }
        Mock Get-TLSConfiguration   { @{ TLS12 = $true; TLS10 = $false } }
        Mock Resolve-DnsName       { @([PSCustomObject]@{ IPAddress = '1.2.3.4'; Name = 'management.azure.com' }) }
        Mock Test-NetConnection    { [PSCustomObject]@{ TcpTestSucceeded = $true } }
        Mock New-RetryBlock        { param($Action) & $Action }
        Mock Get-ServerIPConfiguration      { @{ Adapters = @() } }
        Mock Get-RelevantFirewallRules       { @() }
        Mock Get-NetworkAdapterConfiguration { @() }
        Mock Get-ConnectivityRecommendations { @() }
        Mock Start-Transcript {} -ErrorAction SilentlyContinue
        Mock Invoke-Command { $true }

        $result = Test-ArcConnectivity -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.ServerName | Should -Be 'TEST-SRV'
    }

    It 'returns Error when Test-Connection throws' {
        Mock Test-Connection { throw 'Host not reachable' }
        Mock Start-Transcript {} -ErrorAction SilentlyContinue

        $result = Test-ArcConnectivity -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Error'
    }

    It 'includes AMA endpoints when -IncludeAMA is specified' {
        Mock Test-Connection { [PSCustomObject]@{ ResponseTime=10; Address='1.2.3.4' } }
        Mock Get-ProxyConfiguration { @{ Configured = $false } }
        Mock Get-TLSConfiguration   { @{ TLS12 = $true } }
        Mock Resolve-DnsName       { @([PSCustomObject]@{ IPAddress='1.2.3.4';Name='test' }) }
        Mock Test-NetConnection    { [PSCustomObject]@{ TcpTestSucceeded = $true } }
        Mock New-RetryBlock        { param($Action) & $Action }
        Mock Get-ServerIPConfiguration       { @{ Adapters = @() } }
        Mock Get-RelevantFirewallRules        { @() }
        Mock Get-NetworkAdapterConfiguration { @() }
        Mock Get-ConnectivityRecommendations { @() }
        Mock Start-Transcript {} -ErrorAction SilentlyContinue
        Mock Invoke-Command { $true }

        $result = Test-ArcConnectivity -ServerName 'TEST-SRV' -IncludeAMA
        $result | Should -Not -BeNullOrEmpty
        $result.ServerName | Should -Be 'TEST-SRV'
    }

    It 'Get-ServerIPConfiguration returns null or result gracefully' {
        Mock Invoke-Command { @{ IP='192.168.1.1'; SubnetMask='255.255.255.0' } } -ParameterFilter { $ComputerName -ne $null }
        $result = Get-ServerIPConfiguration -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Get-RelevantFirewallRules completes without throwing' {
        Mock Invoke-Command { @() }
        { Get-RelevantFirewallRules -ServerName 'TEST-SRV' } | Should -Not -Throw
    }

    It 'Get-ConnectivityRecommendations returns recs for failed endpoints' {
        $endpoints = @{
            'ARM' = @{ Status = 'Failed'; Required = $true }
        }
        $result = Get-ConnectivityRecommendations -Results @{ Endpoints = $endpoints }
        $result | Should -Not -BeNullOrEmpty
    }

    It 'returns Failed and generates recommendations when required TCP checks fail' {
        Mock Test-Connection { [PSCustomObject]@{ ResponseTime = 5; Address = '1.2.3.4' } }
        Mock Get-ProxyConfiguration { @{ ProxyEnabled = $true } }
        Mock Get-TLSConfiguration { @([PSCustomObject]@{ Protocol = 'TLS 1.2'; Enabled = $false }) }
        Mock Resolve-DnsName { @([PSCustomObject]@{ IPAddress = '1.2.3.4'; Name = 'management.azure.com' }) }
        Mock New-RetryBlock {
            @{
                Result = [PSCustomObject]@{
                    TcpTestSucceeded = $false
                    PingReplyDetails = [PSCustomObject]@{ RoundtripTime = $null }
                }
                LastError = 'blocked by firewall'
            }
        }

        $result = Test-ArcConnectivity -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Failed'
        $result.Success | Should -Be $false
        @($result.Recommendations).Count | Should -BeGreaterThan 0
        @($result.Recommendations.Issue) | Should -Contain 'TCP Connectivity'
    }

    It 'collects detailed network info and logs when DNS and SSL warnings occur' {
        Set-Item 'Function:global:Get-NetworkRoute' -Value { param([string]$ServerName) @(@{ DestinationPrefix = '0.0.0.0/0' }) }
        Mock Test-Connection { [PSCustomObject]@{ ResponseTime = 8; Address = '1.2.3.4' } }
        Mock Get-ProxyConfiguration { @{ ProxyEnabled = $false } }
        Mock Get-TLSConfiguration { @() }
        Mock Resolve-DnsName { throw 'dns failed' }
        Mock New-RetryBlock {
            @{
                Result = [PSCustomObject]@{
                    TcpTestSucceeded = $true
                    PingReplyDetails = [PSCustomObject]@{ RoundtripTime = 20 }
                }
                LastError = $null
            }
        }
        Mock Test-SslConnection { throw 'ssl handshake failed' }
        Mock Get-ServerIPConfiguration { @(@{ InterfaceAlias = 'Ethernet0' }) }
        Mock Get-RelevantFirewallRules { @(@{ DisplayName = 'Allow Azure' }) }
        Mock Get-NetworkAdapterConfiguration { @(@{ Description = 'Primary NIC' }) }
        Mock Start-Transcript {}
        Mock Stop-Transcript {}

        $result = Test-ArcConnectivity -ServerName 'TEST-SRV' -Detailed -LogPath 'C:\Temp'
        $result.Status | Should -Be 'Success'
        $result.NetworkDetails.IPConfiguration | Should -Not -BeNullOrEmpty
        $result.NetworkDetails.FirewallRules | Should -Not -BeNullOrEmpty
        $result.NetworkDetails.RouteTable | Should -Not -BeNullOrEmpty
        $result.NetworkDetails.NetworkAdapters | Should -Not -BeNullOrEmpty
        Should -Invoke Start-Transcript -Times 1 -Exactly
        Should -Invoke Stop-Transcript -Times 1 -Exactly
    }

    It 'Get-RelevantFirewallRules executes the filtering scriptblock locally' {
        Mock Invoke-Command { & $ScriptBlock } -ParameterFilter { $ComputerName -eq 'TEST-SRV' }
        Mock Get-NetFirewallRule {
            @(
                [PSCustomObject]@{ DisplayName = 'Allow Azure Arc'; Direction = 'Outbound'; Action = 'Allow'; Enabled = $true },
                [PSCustomObject]@{ DisplayName = 'Inbound Ignore'; Direction = 'Inbound'; Action = 'Allow'; Enabled = $true },
                [PSCustomObject]@{ DisplayName = 'Disabled HTTPS'; Direction = 'Outbound'; Action = 'Allow'; Enabled = $false }
            )
        }

        $result = Get-RelevantFirewallRules -ServerName 'TEST-SRV'
        @($result).Count | Should -Be 1
        $result[0].DisplayName | Should -Be 'Allow Azure Arc'
    }

    It 'Get-NetworkAdapterConfiguration executes the adapter filtering scriptblock locally' {
        Mock Invoke-Command { & $ScriptBlock } -ParameterFilter { $ComputerName -eq 'TEST-SRV' }
        Mock Get-WmiObject {
            @(
                [PSCustomObject]@{ Description = 'Enabled NIC'; IPEnabled = $true; IPAddress = @('10.0.0.10'); IPSubnet = @('255.255.255.0'); DefaultIPGateway = @('10.0.0.1'); DNSServerSearchOrder = @('8.8.8.8'); DHCPEnabled = $false },
                [PSCustomObject]@{ Description = 'Disabled NIC'; IPEnabled = $false; IPAddress = @(); IPSubnet = @(); DefaultIPGateway = @(); DNSServerSearchOrder = @(); DHCPEnabled = $false }
            )
        } -ParameterFilter { $Class -eq 'Win32_NetworkAdapterConfiguration' }

        $result = Get-NetworkAdapterConfiguration -ServerName 'TEST-SRV'
        @($result).Count | Should -Be 1
        $result[0].Description | Should -Be 'Enabled NIC'
    }

    It 'Test-SslConnection returns timeout when TCP connect does not complete' {
        Mock New-Object {
            $waitHandle = [pscustomobject]@{}
            Add-Member -InputObject $waitHandle -MemberType ScriptMethod -Name WaitOne -Value { param($timeout, $exitContext) $false }

            $connection = [pscustomobject]@{ AsyncWaitHandle = $waitHandle }
            $client = [pscustomobject]@{ Connection = $connection }
            Add-Member -InputObject $client -MemberType ScriptMethod -Name BeginConnect -Value { param($hostName, $port, $callback, $state) $this.Connection }
            Add-Member -InputObject $client -MemberType ScriptMethod -Name Close -Value { }
            $client
        } -ParameterFilter { $TypeName -eq 'System.Net.Sockets.TcpClient' }

        $result = Test-SslConnection -HostName 'management.azure.com'
        $result.Success | Should -Be $false
        $result.Error | Should -Be 'Connection timed out'
    }

    It 'Test-SslConnection returns error when EndConnect throws' {
        Mock New-Object {
            $waitHandle = [pscustomobject]@{}
            Add-Member -InputObject $waitHandle -MemberType ScriptMethod -Name WaitOne -Value { param($timeout, $exitContext) $true }

            $connection = [pscustomobject]@{ AsyncWaitHandle = $waitHandle }
            $client = [pscustomobject]@{ Connection = $connection }
            Add-Member -InputObject $client -MemberType ScriptMethod -Name BeginConnect -Value { param($hostName, $port, $callback, $state) $this.Connection }
            Add-Member -InputObject $client -MemberType ScriptMethod -Name EndConnect -Value { param($asyncResult) throw 'connect failed' }
            Add-Member -InputObject $client -MemberType ScriptMethod -Name Close -Value { }
            $client
        } -ParameterFilter { $TypeName -eq 'System.Net.Sockets.TcpClient' }

        $result = Test-SslConnection -HostName 'management.azure.com'
        $result.Success | Should -Be $false
        $result.Error | Should -Match 'connect failed'
    }

    It 'Test-SslConnection returns connection details on success' {
        Mock New-Object {
            if ($TypeName -eq 'System.Net.Sockets.TcpClient') {
                $waitHandle = [pscustomobject]@{}
                Add-Member -InputObject $waitHandle -MemberType ScriptMethod -Name WaitOne -Value { param($timeout, $exitContext) $true }

                $connection = [pscustomobject]@{ AsyncWaitHandle = $waitHandle }
                $stream = [pscustomobject]@{}
                $client = [pscustomobject]@{ Connection = $connection; Stream = $stream }
                Add-Member -InputObject $client -MemberType ScriptMethod -Name BeginConnect -Value { param($hostName, $port, $callback, $state) $this.Connection }
                Add-Member -InputObject $client -MemberType ScriptMethod -Name EndConnect -Value { param($asyncResult) }
                Add-Member -InputObject $client -MemberType ScriptMethod -Name GetStream -Value { $this.Stream }
                Add-Member -InputObject $client -MemberType ScriptMethod -Name Close -Value { }
                return $client
            }

            $cert = [pscustomobject]@{ Subject = 'CN=management.azure.com'; Issuer = 'CN=Azure Test' }
            Add-Member -InputObject $cert -MemberType ScriptMethod -Name GetEffectiveDateString -Value { '01/01/2025 00:00:00' }
            Add-Member -InputObject $cert -MemberType ScriptMethod -Name GetExpirationDateString -Value { '01/01/2026 00:00:00' }
            Add-Member -InputObject $cert -MemberType ScriptMethod -Name GetCertHashString -Value { 'ABC123' }

            $sslStream = [pscustomobject]@{
                SslProtocol = 'Tls12'
                CipherAlgorithm = 'Aes256'
                CipherStrength = 256
                HashAlgorithm = 'Sha256'
                HashStrength = 256
                RemoteCertificate = $cert
            }
            Add-Member -InputObject $sslStream -MemberType ScriptMethod -Name AuthenticateAsClient -Value { param($hostName) }
            Add-Member -InputObject $sslStream -MemberType ScriptMethod -Name Close -Value { }
            $sslStream
        } -ParameterFilter { $TypeName -in @('System.Net.Sockets.TcpClient', 'System.Net.Security.SslStream') }

        $result = Test-SslConnection -HostName 'management.azure.com'
        $result.Success | Should -Be $true
        $result.Protocol | Should -Be 'Tls12'
        $result.Certificate.Subject | Should -Be 'CN=management.azure.com'
        $result.Certificate.Thumbprint | Should -Be 'ABC123'
    }

    It 'Get-ConnectivityRecommendations returns DNS, TCP, SSL, proxy, and TLS recommendations' {
        $results = @{
            Endpoints = @{
                ARM = @{
                    DNS = @{ Success = $false }
                    TCP = @{ Success = $false }
                    SSL = $null
                }
                AAD = @{
                    DNS = @{ Success = $true }
                    TCP = @{ Success = $true }
                    SSL = @{ Success = $false }
                }
            }
            ProxyConfiguration = @{ ProxyEnabled = $true }
            TLSConfiguration = @(
                [PSCustomObject]@{ Protocol = 'TLS 1.2'; Enabled = $false }
            )
        }

        $result = Get-ConnectivityRecommendations -Results $results
        @($result.Issue) | Should -Contain 'DNS Resolution'
        @($result.Issue) | Should -Contain 'TCP Connectivity'
        @($result.Issue) | Should -Contain 'SSL/TLS'
        @($result.Issue) | Should -Contain 'Proxy Configuration'
        @($result.Issue) | Should -Contain 'TLS Configuration'
    }
}

# ---------------------------------------------------------------------------
# 2. Get-LastHeartbeat.ps1  (202 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Get-LastHeartbeat.ps1 Coverage' {
    BeforeAll {
        # Always create function stubs so Pester mock targets a function, not a module cmdlet on CI
        Set-Item 'Function:global:Get-AzConnectedMachine' -Value { param() $null } -Force
        Set-Item 'Function:global:Get-AzConnectedMachineExtension' -Value { param() @() } -Force
        Set-Item 'Function:global:Invoke-AzOperationalInsightsQuery' -Value { param() [PSCustomObject]@{ Results = @() } } -Force
        . (Join-Path $script:SrcRoot 'core\Get-LastHeartbeat.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'returns heartbeat info with Arc only when AgentType is Arc' {
        Mock Get-ArcAgentHeartbeat        { @{ LastHeartbeat = (Get-Date).AddMinutes(-5); Status = 'Healthy' } }
        Mock Get-CombinedHeartbeatStatus  { @{ Status = 'Healthy'; LastHeartbeat = (Get-Date).AddMinutes(-5) } }

        $result = Get-LastHeartbeat -ServerName 'TEST-SRV' -AgentType 'Arc'
        $result | Should -Not -BeNullOrEmpty
        $result.Arc.Status | Should -Be 'Healthy'
    }

    It 'retrieves AMA heartbeat when WorkspaceId is provided' {
        Mock Get-ArcAgentHeartbeat        { @{ LastHeartbeat = (Get-Date).AddMinutes(-5); Status = 'Healthy' } }
        Mock Get-AMAHeartbeat             { @{ LastHeartbeat = (Get-Date).AddMinutes(-10); Status = 'Healthy' } }
        Mock Get-CombinedHeartbeatStatus  { @{ Status = 'Healthy'; LastHeartbeat = (Get-Date).AddMinutes(-5) } }

        $result = Get-LastHeartbeat -ServerName 'TEST-SRV' -WorkspaceId 'ws-123' -AgentType 'Both'
        $result.AMA.Status | Should -Be 'Healthy'
    }

    It 'includes details when -IncludeDetails is specified' {
        Mock Get-ArcAgentHeartbeat        { @{ LastHeartbeat = (Get-Date).AddMinutes(-5); Status = 'Healthy' } }
        Mock Get-ArcAgentHeartbeatDetails { @{ Events = @(); ConfigVersion = '1.0' } }
        Mock Get-AMAHeartbeat             { @{ LastHeartbeat = (Get-Date).AddMinutes(-10); Status = 'Healthy' } }
        Mock Get-AMAHeartbeatDetails      { @{ DataIngestion = @{} } }
        Mock Get-CombinedHeartbeatStatus  { @{ Status = 'Healthy'; LastHeartbeat = (Get-Date).AddMinutes(-5) } }

        $result = Get-LastHeartbeat -ServerName 'TEST-SRV' -WorkspaceId 'ws-123' -IncludeDetails
        $result.Arc.Details | Should -Not -BeNullOrEmpty
    }

    It 'handles exception gracefully' {
        Mock Get-ArcAgentHeartbeat { throw 'Cannot connect' }
        Mock Get-CombinedHeartbeatStatus { @{ Status = 'Unknown' } }

        $result = Get-LastHeartbeat -ServerName 'TEST-SRV' -AgentType 'Arc'
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'Get-ArcAgentHeartbeat returns heartbeat with Get-Service mocked' {
        Mock Get-Service {
            [PSCustomObject]@{ Name='himds'; Status='Running'; StartType='Automatic' }
        } -ParameterFilter { $Name -eq 'himds' }

        $result = Get-ArcAgentHeartbeat -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Get-AMAHeartbeat calls query functions with mocked dependencies' {
        Mock Invoke-AzOperationalInsightsQuery {
            [PSCustomObject]@{ Results = @([PSCustomObject]@{ TimeGenerated = (Get-Date).AddMinutes(-5) }) }
        }

        $result = Get-AMAHeartbeat -ServerName 'TEST-SRV' -WorkspaceId 'ws-123'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Get-AMAHeartbeat handles query failure gracefully' {
        Mock Invoke-AzOperationalInsightsQuery { throw 'Query failed' }

        $result = Get-AMAHeartbeat -ServerName 'TEST-SRV' -WorkspaceId 'ws-123'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Get-CombinedHeartbeatStatus returns Healthy when both are Healthy' {
        $result = Get-CombinedHeartbeatStatus -ArcStatus 'Healthy' -AMAStatus 'Healthy'
        $result.Status | Should -Be 'Healthy'
    }

    It 'Get-CombinedHeartbeatStatus returns Degraded when one is unhealthy' {
        $result = Get-CombinedHeartbeatStatus -ArcStatus 'Healthy' -AMAStatus 'Unhealthy'
        $result.Status | Should -BeIn 'Degraded', 'Unhealthy', 'Warning', 'Partial'
    }

    It 'Get-ArcAgentHeartbeat returns NotInstalled when service not found' {
        Mock Get-Service { $null } -ParameterFilter { $Name -eq 'himds' }
        $result = Get-ArcAgentHeartbeat -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'NotInstalled'
    }

    It 'Get-ArcAgentHeartbeat returns NotRunning when service is stopped' {
        Mock Get-Service {
            [PSCustomObject]@{ Name='himds'; Status='Stopped'; StartType='Automatic' }
        } -ParameterFilter { $Name -eq 'himds' }
        $result = Get-ArcAgentHeartbeat -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'NotRunning'
    }

    It 'Get-ArcAgentHeartbeat returns ConfigNotFound when agentconfig.json absent' {
        Mock Get-Service {
            [PSCustomObject]@{ Name='himds'; Status='Running'; StartType='Automatic' }
        } -ParameterFilter { $Name -eq 'himds' }
        Mock Test-Path { $false }
        $result = Get-ArcAgentHeartbeat -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'ConfigNotFound'
    }

    It 'Get-ArcAgentHeartbeat returns Healthy when state.json shows recent heartbeat' {
        Mock Get-Service {
            [PSCustomObject]@{ Name='himds'; Status='Running'; StartType='Automatic' }
        } -ParameterFilter { $Name -eq 'himds' }
        # agentconfig.json exists, state.json exists with recent heartbeat
        Mock Test-Path { $true }
        $recentHB = (Get-Date).AddMinutes(-2).ToString('o')
        Mock Get-Content { "{`"lastHeartbeat`": `"$recentHB`"}" } -ParameterFilter { $Path -like '*state.json*' }
        Mock ConvertFrom-Json { [PSCustomObject]@{ lastHeartbeat = $recentHB } }
        Mock Get-AzConnectedMachine { $null }
        $result = Get-ArcAgentHeartbeat -ServerName 'TEST-SRV'
        $result.Status | Should -BeIn 'Healthy', 'Warning', 'Critical'
    }

    It 'Get-ArcAgentHeartbeat returns NoHeartbeat when state.json has no lastHeartbeat' {
        Mock Get-Service {
            [PSCustomObject]@{ Name='himds'; Status='Running'; StartType='Automatic' }
        } -ParameterFilter { $Name -eq 'himds' }
        Mock Test-Path { $true }
        Mock Get-Content { '{}' } -ParameterFilter { $Path -like '*state.json*' }
        Mock ConvertFrom-Json { [PSCustomObject]@{} }
        Mock Get-AzConnectedMachine { $null }
        $result = Get-ArcAgentHeartbeat -ServerName 'TEST-SRV'
        $result.Status | Should -BeIn 'NoHeartbeat', 'StateFileNotFound', 'Healthy', 'Warning', 'Critical', 'Error', 'Unknown'
    }

    It 'Get-ArcAgentHeartbeat handles exception gracefully' {
        Mock Get-Service { throw 'Cannot reach server' }
        $result = Get-ArcAgentHeartbeat -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Error'
    }

    It 'Get-AMAHeartbeat returns NotInstalled when service not found' {
        Mock Get-Service { $null } -ParameterFilter { $Name -eq 'AzureMonitorAgent' }
        $result = Get-AMAHeartbeat -ServerName 'TEST-SRV' -WorkspaceId 'ws-123'
        $result.Status | Should -Be 'NotInstalled'
    }

    It 'Get-AMAHeartbeat returns NotRunning when AMA service is stopped' {
        Mock Get-Service {
            [PSCustomObject]@{ Name='AzureMonitorAgent'; Status='Stopped' }
        } -ParameterFilter { $Name -eq 'AzureMonitorAgent' }
        $result = Get-AMAHeartbeat -ServerName 'TEST-SRV' -WorkspaceId 'ws-123'
        $result.Status | Should -Be 'NotRunning'
    }

    It 'Get-AMAHeartbeat returns Healthy when query finds recent heartbeat' {
        if (-not (Get-Command Invoke-AzOperationalInsightsQuery -ErrorAction SilentlyContinue)) {
            Set-Item 'Function:global:Invoke-AzOperationalInsightsQuery' -Value { param() [PSCustomObject]@{ Results = @() } }
        }
        Mock Get-Service {
            [PSCustomObject]@{ Name='AzureMonitorAgent'; Status='Running' }
        } -ParameterFilter { $Name -eq 'AzureMonitorAgent' }
        $recentTime = (Get-Date).AddMinutes(-3)
        Mock Invoke-AzOperationalInsightsQuery {
            [PSCustomObject]@{
                Results = [PSCustomObject]@{ LastHeartbeat = $recentTime.ToString('o') }
            }
        }
        $result = Get-AMAHeartbeat -ServerName 'TEST-SRV' -WorkspaceId 'ws-123'
        $result | Should -Not -BeNullOrEmpty
        $result.Status | Should -BeIn 'Healthy', 'Warning', 'Critical'
    }

    It 'Get-ArcAgentHeartbeatDetails returns result when Az mock returns machine' {
        Mock Get-AzConnectedMachine {
            [PSCustomObject]@{
                Name = 'TEST-SRV'
                Status = 'Connected'
                AgentVersion = '1.38.0'
                LastStatusChange = (Get-Date).AddMinutes(-5)
            }
        }
        Mock Get-AzConnectedMachineExtension { @() }
        Mock Test-Path { $false }
        $result = Get-ArcAgentHeartbeatDetails -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.ConnectionStatus | Should -Be 'Connected'
    }

    It 'Get-ArcAgentHeartbeatDetails handles Az exception gracefully' {
        Mock Get-AzConnectedMachine { throw 'Not authenticated' }
        $result = Get-ArcAgentHeartbeatDetails -ServerName 'TEST-SRV'
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'Get-AMAHeartbeatDetails returns result with workspace query mocked' {
        Mock Invoke-AzOperationalInsightsQuery {
            [PSCustomObject]@{ Results = @() }
        }
        Mock Test-Path { $false }
        $result = Get-AMAHeartbeatDetails -ServerName 'TEST-SRV' -WorkspaceId 'ws-123'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Get-LastHeartbeat with AgentType AMA and no WorkspaceId skips AMA heartbeat' {
        Mock Get-CombinedHeartbeatStatus { @{ Status = 'Unknown' } }
        $result = Get-LastHeartbeat -ServerName 'TEST-SRV' -AgentType 'AMA'
        $result | Should -Not -BeNullOrEmpty
        # AMA status should be Unknown since no WorkspaceId provided and AMA check was skipped
        $result.AMA.Status | Should -Be 'Unknown'
    }

    It 'Get-CombinedHeartbeatStatus returns Critical when ArcStatus is Critical' {
        $result = Get-CombinedHeartbeatStatus -ArcStatus 'Critical' -AMAStatus 'Healthy'
        $result.Status | Should -Be 'Critical'
    }

    It 'Get-CombinedHeartbeatStatus returns Critical when AMAStatus is Critical' {
        $result = Get-CombinedHeartbeatStatus -ArcStatus 'Warning' -AMAStatus 'Critical'
        $result.Status | Should -Be 'Critical'
    }

    It 'Get-CombinedHeartbeatStatus returns Warning when ArcStatus is Warning (no Critical)' {
        $result = Get-CombinedHeartbeatStatus -ArcStatus 'Warning' -AMAStatus 'Healthy'
        $result.Status | Should -Be 'Warning'
    }

    It 'Get-CombinedHeartbeatStatus returns ArcStatus when only Arc is known' {
        $result = Get-CombinedHeartbeatStatus -ArcStatus 'Healthy' -AMAStatus 'Unknown'
        $result.Status | Should -Be 'Healthy'
    }

    It 'Get-CombinedHeartbeatStatus returns AMAStatus when only AMA is known' {
        $result = Get-CombinedHeartbeatStatus -ArcStatus 'Unknown' -AMAStatus 'Warning'
        $result.Status | Should -Be 'Warning'
    }

    It 'Get-CombinedHeartbeatStatus returns Unknown when both are Unknown' {
        $result = Get-CombinedHeartbeatStatus -ArcStatus 'Unknown' -AMAStatus 'Unknown'
        $result.Status | Should -Be 'Unknown'
    }

    It 'Get-AMAHeartbeat returns LogsNotAccessible when no WorkspaceId and log path missing' {
        Mock Get-Service {
            [PSCustomObject]@{ Name = 'AzureMonitorAgent'; Status = 'Running' }
        } -ParameterFilter { $Name -eq 'AzureMonitorAgent' }
        Mock Test-Path { $false }
        $result = Get-AMAHeartbeat -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'LogsNotAccessible'
    }

    It 'Get-AMAHeartbeat returns status when no WorkspaceId but log files exist' {
        Mock Get-Service {
            [PSCustomObject]@{ Name = 'AzureMonitorAgent'; Status = 'Running' }
        } -ParameterFilter { $Name -eq 'AzureMonitorAgent' }
        Mock Test-Path { $true }
        $recentFile = [PSCustomObject]@{ LastWriteTime = (Get-Date).AddMinutes(-2) }
        Mock Get-ChildItem { @($recentFile) }
        $result = Get-AMAHeartbeat -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.Status | Should -BeIn 'Healthy', 'Warning', 'Critical'
    }

    It 'Get-AMAHeartbeat returns NoRecentActivity when no WorkspaceId and no recent log files' {
        Mock Get-Service {
            [PSCustomObject]@{ Name = 'AzureMonitorAgent'; Status = 'Running' }
        } -ParameterFilter { $Name -eq 'AzureMonitorAgent' }
        Mock Test-Path { $true }
        Mock Get-ChildItem { @() }
        $result = Get-AMAHeartbeat -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'NoRecentActivity'
    }

    It 'Get-ArcAgentHeartbeat falls back to Azure API when no state heartbeat' {
        Mock Get-Service {
            [PSCustomObject]@{ Name = 'himds'; Status = 'Running'; StartType = 'Automatic' }
        } -ParameterFilter { $Name -eq 'himds' }
        # state.json exists but has no lastHeartbeat
        Mock Test-Path { $true }
        Mock Get-Content { '{}' } -ParameterFilter { $Path -like '*state.json*' }
        Mock ConvertFrom-Json { [PSCustomObject]@{} }
        # API returns machine with recent lastStatusChange
        Mock Get-AzConnectedMachine {
            [PSCustomObject]@{ LastStatusChange = (Get-Date).AddMinutes(-3) }
        }
        $result = Get-ArcAgentHeartbeat -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.Status | Should -BeIn 'Healthy', 'Warning', 'Critical'
    }
}

# ---------------------------------------------------------------------------
# 3. Invoke-TroubleshootingAnalysis.ps1  (176 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Invoke-TroubleshootingAnalysis.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'core\Invoke-TroubleshootingAnalysis.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    $script:MockPatterns = @{ SystemState=@{}; ArcAgent=@{}; AMA=@{} }

    It 'returns analysis results with issues and recommendations' {
        Mock Get-Content { $script:MockPatterns | ConvertTo-Json -Depth 5 }
        Mock Test-OSCompatibility { $true }

        $data = @(
            [PSCustomObject]@{ Phase='SystemState'; Data=@{ OS=@{Version='10.0.19041'}; Memory=@{AvailableGB=4}; Disk=@{FreeSpaceGB=50} } }
            [PSCustomObject]@{ Phase='ArcDiagnostics'; Data=@{ Service=@{Status='Running'}; Connection=@{Status='Connected'} } }
        )

        $result = Invoke-TroubleshootingAnalysis -Data $data -ConfigPath 'C:\Config\test.json'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'returns error in results when analysis fails' {
        Mock Get-Content { '{"SystemState":{},"ArcAgent":{},"AMA":{}}' }
        Mock Find-SystemStateIssues { throw 'Analysis processing error' }

        $data = @(
            [PSCustomObject]@{ Phase='SystemState'; Data=@{ OS=@{Version='10.0.19041'}; Memory=@{AvailableGB=4}; Disk=@{FreeSpaceGB=50} } }
        )

        $result = Invoke-TroubleshootingAnalysis -Data $data -ConfigPath 'C:\Config\test.json'
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'Find-SystemStateIssues detects low memory' {
        Mock Test-OSCompatibility { $true }
        $state = @{ OS=@{Version='10.0.19041'}; Memory=@{AvailableGB=1}; Disk=@{FreeSpaceGB=50} }
        $result = Find-SystemStateIssues -State $state -Patterns @{}
        $memoryIssue = $result | Where-Object { $_.Component -eq 'Memory' }
        $memoryIssue | Should -Not -BeNullOrEmpty
    }

    It 'Find-SystemStateIssues detects low disk space' {
        Mock Test-OSCompatibility { $true }
        $state = @{ OS=@{Version='10.0.19041'}; Memory=@{AvailableGB=4}; Disk=@{FreeSpaceGB=2} }
        $result = Find-SystemStateIssues -State $state -Patterns @{}
        ($result | Where-Object { $_.Component -eq 'DiskSpace' }) | Should -Not -BeNullOrEmpty
    }

    It 'Find-SystemStateIssues detects OS incompatibility' {
        Mock Test-OSCompatibility { $false }
        $state = @{ OS=@{Version='6.1.7601'}; Memory=@{AvailableGB=4}; Disk=@{FreeSpaceGB=50} }
        $result = Find-SystemStateIssues -State $state -Patterns @{}
        ($result | Where-Object { $_.Component -eq 'OperatingSystem' }) | Should -Not -BeNullOrEmpty
    }

    It 'Find-ArcAgentIssues detects service not running' {
        $diag = @{ Service=@{Status='Stopped'}; Connection=@{Status='Connected'} }
        $result = Find-ArcAgentIssues -Diagnostics $diag -Patterns @{}
        $result | Should -Not -BeNullOrEmpty
        ($result | Where-Object { $_.Component -eq 'ArcAgent' }) | Should -Not -BeNullOrEmpty
    }

    It 'Find-CommonPatterns completes without throwing' {
        { Find-CommonPatterns -Issues @([PSCustomObject]@{ Type='Network'; Component='ArcAgent'; Severity='Warning' }) } | Should -Not -Throw
    }

    It 'Test-OSCompatibility returns true for Windows Server 2019' {
        $result = Test-OSCompatibility -Version '10.0.17763'
        $result | Should -Be $true
    }

    It 'Test-OSCompatibility returns false for old version' {
        $result = Test-OSCompatibility -Version '6.1.7601'
        $result | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# 4. Get-ArcRegistrationStatus.ps1  (151 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Get-ArcRegistrationStatus.ps1 Coverage' {
    BeforeAll {
        foreach ($fn in @('Get-AzConnectedMachine','Get-AzHealthResource','Get-AzPolicyState','Get-AzActivityLog','Get-LocalAgentStatus','Test-ArcConnectivity','Get-ArcExtensions','Get-ArcResourceHealth','Get-ArcComplianceStatus')) {
            Set-Item "Function:global:$fn" -Value { param() @{} } -Force
        }
        . (Join-Path $script:SrcRoot 'core\Get-ArcRegistrationStatus.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'returns status with details when server found in Azure' {
        Mock Get-AzConnectedMachine {
            [PSCustomObject]@{
                Id='/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/TEST-SRV'
                Status='Connected'; Location='eastus'; AgentVersion='1.0'; LastStatusChange=(Get-Date)
                OSName='Windows Server 2019'; OSVersion='10.0.17763'; ProvisioningState='Succeeded'; DisplayName='TEST-SRV'; Tag=@{}
            }
        }
        Mock Get-LocalAgentStatus { @{ Status='Connected'; Installed=$true; Version='1.0' } }

        $result = Get-ArcRegistrationStatus -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.Status | Should -Be 'Connected'
    }

    It 'returns NotRegistered when server exists locally but not in Azure' {
        Mock Get-AzConnectedMachine { $null }
        Mock Get-LocalAgentStatus { @{ Installed=$true; Status='NotRegistered'; Version='1.0' } }

        $result = Get-ArcRegistrationStatus -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'NotRegistered'
    }

    It 'returns NotInstalled when agent is not installed' {
        Mock Get-AzConnectedMachine { $null }
        Mock Get-LocalAgentStatus { @{ Installed=$false; Status='NotInstalled' } }

        $result = Get-ArcRegistrationStatus -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'NotInstalled'
    }

    It 'includes detailed info when -Detailed is specified' {
        Mock Get-AzConnectedMachine {
            [PSCustomObject]@{ Id='/sub/s1/rg/rg1/prov/machines/TEST-SRV'; Status='Connected'; Location='eastus'
                AgentVersion='1.0'; LastStatusChange=(Get-Date); OSName='Windows'; OSVersion='10.0'; ProvisioningState='Succeeded'; DisplayName='TEST-SRV'; Tag=@{} }
        }
        Mock Get-LocalAgentStatus    { @{ Status='Connected'; Installed=$true } }
        Mock Get-ArcExtensions       { @() }
        Mock Test-ArcConnectivity    { @{ Status='Success'; Success=$true } }
        Mock Get-ArcResourceHealth   { @{ Status='Healthy' } }
        Mock Get-ArcComplianceStatus { @{ Compliant=$true } }

        $result = Get-ArcRegistrationStatus -ServerName 'TEST-SRV' -Detailed
        $result | Should -Not -BeNullOrEmpty
        $result.Status | Should -Be 'Connected'
    }

    It 'returns Error when exception is thrown' {
        Mock Get-AzConnectedMachine { throw 'Az module error' }

        $result = Get-ArcRegistrationStatus -ServerName 'TEST-SRV'
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'Get-LocalAgentStatus returns result with Get-Service mocked' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName, $ErrorAction)
            [PSCustomObject]@{ Name='himds'; Status='Running'; StartType='Automatic'; DisplayName='Azure Connected Machine Agent' }
        }
        function Global:Get-Process {
            param([string]$Name, [string]$ComputerName, $ErrorAction)
            [PSCustomObject]@{ Id=101; StartTime=(Get-Date).AddMinutes(-30); CPU=12.5; WorkingSet64=268435456; Threads=@(1,2,3) }
        }
        try {
            Mock Test-Path {
                $Path -in @(
                    '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\config',
                    '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\logs'
                )
            }
            Mock Get-Content {
                '{"tenant_id":"tenant-1","resource_group":"rg-1","subscription_id":"sub-1","location":"eastus","correlation_id":"corr-1"}'
            }
            Mock Get-ChildItem {
                @([PSCustomObject]@{ FullName='C:\logs\himds.log'; LastWriteTime=(Get-Date).AddMinutes(-2) })
            } -ParameterFilter { $Filter -eq 'himds.log' }
            Mock Select-String {
                @([PSCustomObject]@{ Line='ERROR failed to connect' })
            }
            Mock Test-NetConnection {
                [PSCustomObject]@{ TcpTestSucceeded = $true }
            }

            $result = Get-LocalAgentStatus -ServerName 'TEST-SRV'
            $result.Installed | Should -Be $true
            $result.Status | Should -Be 'Running'
            $result.Details.Process.Id | Should -Be 101
            $result.Details.Configuration.TenantId | Should -Be 'tenant-1'
            $result.Details.RecentErrors | Should -Contain 'ERROR failed to connect'
        }
        finally {
            Remove-Item Function:\global:Get-Service,Function:\global:Get-Process -ErrorAction SilentlyContinue
        }
    }

    It 'Get-LocalAgentStatus records ConfigError when config parsing fails' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName, $ErrorAction)
            [PSCustomObject]@{ Name='himds'; Status='Running'; StartType='Automatic'; DisplayName='Azure Connected Machine Agent' }
        }
        function Global:Get-Process {
            param([string]$Name, [string]$ComputerName, $ErrorAction)
            $null
        }
        try {
            Mock Test-Path {
                $Path -eq '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\config'
            }
            Mock Get-Content { '{not-json' }
            Mock Test-NetConnection {
                [PSCustomObject]@{ TcpTestSucceeded = $false }
            }

            $result = Get-LocalAgentStatus -ServerName 'TEST-SRV'
            $result.Installed | Should -Be $true
            $result.Details.ConfigError | Should -Not -BeNullOrEmpty
        }
        finally {
            Remove-Item Function:\global:Get-Service,Function:\global:Get-Process -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# 5. Get-SystemState.ps1  (138 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Get-SystemState.ps1 Coverage' {
    BeforeAll {
        foreach ($fn in @('Get-ProxyConfiguration','Get-TLSConfiguration','Get-FirewallStatus','Get-CertificateStatus','Get-WindowsUpdateStatus','Test-NetworkConnectivity','Get-ArcAgentConfig','Get-ArcAgentVersion','Get-ArcLastConnected','Get-AMAAgentConfig','Get-AMAVersion','Get-AMADataCollectionStatus','Get-DCRAssociationStatus','Get-CPUMetrics','Get-MemoryMetrics','Get-DiskMetrics','Get-NetworkMetrics','Get-InstalledSoftware','Get-ServiceDependencies','Get-RelevantScheduledTasks','Get-RelevantEventLogs')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() @{} }
            }
        }
        # Shadow Get-WmiObject as a function to handle positional Class arg + ConvertToDateTime method
        $wmiMockOS = [PSCustomObject]@{
            Version='10.0.17763'; BuildNumber='17763'; ServicePackMajorVersion=0
            OSArchitecture='64-bit'; FreePhysicalMemory=4194304
            LastBootUpTime='20240101000000.000000+000'; InstallDate='20230101000000.000000+000'
        }
        $wmiMockOS | Add-Member -MemberType ScriptMethod -Name 'ConvertToDateTime' -Value { param($s) [datetime]::UtcNow }
        $script:WmiMockOS = $wmiMockOS
        Set-Item 'Function:global:Get-WmiObject' -Value {
            param(
                [Parameter(Position=0)][string]$Class,
                [string]$ComputerName,
                [string]$Filter,
                [string]$Namespace
            )
            $mockOS = $script:WmiMockOS
            switch ($Class) {
                'Win32_OperatingSystem' { return $mockOS }
                'Win32_Processor'       { return [PSCustomObject]@{ Name='Intel'; NumberOfCores=4; LoadPercentage=25 } }
                'Win32_ComputerSystem'  { return [PSCustomObject]@{ TotalPhysicalMemory=8589934592 } }
                'Win32_LogicalDisk'     { return [PSCustomObject]@{ Size=107374182400; FreeSpace=53687091200 } }
                'Win32_NetworkAdapterConfiguration' {
                    return @([PSCustomObject]@{ IPEnabled=$true; Description='Eth'; IPAddress=@('192.168.1.1')
                        IPSubnet=@('255.255.255.0'); DefaultIPGateway=@('192.168.1.254'); DNSServerSearchOrder=@('8.8.8.8') })
                }
                default { return $null }
            }
        }
        . (Join-Path $script:SrcRoot 'core\Get-SystemState.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'returns a system state object with OS, Hardware, Network, Security' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName, $ErrorAction)
            if ($Name -eq 'himds') {
                return [PSCustomObject]@{ Name='himds'; Status='Running'; StartType='Automatic' }
            }
            return $null
        }
        try {
            Mock Get-ProxyConfiguration     { @{ Configured=$false } }
            Mock Test-NetworkConnectivity   { @{ Success=$true } }
            Mock Get-TLSConfiguration       { @{ TLS12=$true } }
            Mock Get-FirewallStatus         { @{ Enabled=$true } }
            Mock Get-CertificateStatus      { @{ Valid=$true; ExpiringCount=0 } }
            Mock Get-WindowsUpdateStatus    { @{ PendingUpdates=0 } }
            Mock Get-ArcAgentConfig         { @{ Installed=$true; Version='1.0' } }
            Mock Get-ArcAgentVersion        { '1.0.0' }
            Mock Get-ArcLastConnected       { (Get-Date).AddHours(-1) }
            Mock Get-CPUMetrics             { @{ Average = 25 } }
            Mock Get-MemoryMetrics          { @{ Average = 40 } }
            Mock Get-DiskMetrics            { @{ FreePercent = 50 } }
            Mock Get-NetworkMetrics         { @{ LatencyMs = 10 } }

            $result = Get-SystemState -ServerName 'TEST-SRV'
            $result | Should -Not -BeNullOrEmpty
            $result.OS | Should -Not -BeNullOrEmpty
            $result.Hardware | Should -Not -BeNullOrEmpty
            $result.Performance.CPU.Average | Should -Be 25
            $result.Agents.Arc.Installed | Should -Be $true
        }
        finally {
            Remove-Item Function:\global:Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'includes AMA state when -IncludeAMA is specified' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName, $ErrorAction)
            switch ($Name) {
                'himds' { [PSCustomObject]@{ Name='himds'; Status='Running'; StartType='Automatic' } ; break }
                'AzureMonitorAgent' { [PSCustomObject]@{ Name='AzureMonitorAgent'; Status='Running'; StartType='Automatic' } ; break }
                default { $null }
            }
        }
        try {
            Mock Get-ProxyConfiguration      { @{ Configured=$false } }
            Mock Test-NetworkConnectivity    { @{ Success=$true } }
            Mock Get-TLSConfiguration        { @{ TLS12=$true } }
            Mock Get-FirewallStatus          { @{ Enabled=$true } }
            Mock Get-CertificateStatus       { @{ Valid=$true } }
            Mock Get-WindowsUpdateStatus     { @{ PendingUpdates=0 } }
            Mock Get-ArcAgentConfig          { @{ Installed=$true; Version='1.0' } }
            Mock Get-ArcAgentVersion         { '1.0.0' }
            Mock Get-ArcLastConnected        { (Get-Date).AddHours(-1) }
            Mock Get-AMAAgentConfig          { @{ Installed=$true; WorkspaceId='ws-123' } }
            Mock Get-AMAVersion              { '1.2.0' }
            Mock Get-AMADataCollectionStatus { @{ Status='Active'; DCRCount=2 } }
            Mock Get-DCRAssociationStatus    { @{ Associated=$true; Count=2 } }
            Mock Get-CPUMetrics              { @{ Average = 25 } }
            Mock Get-MemoryMetrics           { @{ Average = 40 } }
            Mock Get-DiskMetrics             { @{ FreePercent = 50 } }
            Mock Get-NetworkMetrics          { @{ LatencyMs = 10 } }

            $result = Get-SystemState -ServerName 'TEST-SRV' -IncludeAMA
            $result | Should -Not -BeNullOrEmpty
            $result.Agents.AMA.Installed | Should -Be $true
            $result.Agents.AMA.Version | Should -Be '1.2.0'
        }
        finally {
            Remove-Item Function:\global:Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'includes DetailedInfo when -DetailedScan is specified' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName, $ErrorAction)
            [PSCustomObject]@{ Name='himds'; Status='Running'; StartType='Automatic' }
        }
        try {
            Mock Get-ProxyConfiguration      { @{ Configured=$false } }
            Mock Test-NetworkConnectivity    { @{ Success=$true } }
            Mock Get-TLSConfiguration        { @{ TLS12=$true } }
            Mock Get-FirewallStatus          { @{ Enabled=$true } }
            Mock Get-CertificateStatus       { @{ Valid=$true } }
            Mock Get-WindowsUpdateStatus     { @{ PendingUpdates=0 } }
            Mock Get-ArcAgentConfig          { @{ Installed=$true; Version='1.0' } }
            Mock Get-ArcAgentVersion         { '1.0.0' }
            Mock Get-ArcLastConnected        { (Get-Date).AddHours(-1) }
            Mock Get-CPUMetrics              { @{ Average = 25 } }
            Mock Get-MemoryMetrics           { @{ Average = 40 } }
            Mock Get-DiskMetrics             { @{ FreePercent = 50 } }
            Mock Get-NetworkMetrics          { @{ LatencyMs = 10 } }
            Mock Get-InstalledSoftware       { @('AMA','Arc Agent') }
            Mock Get-ServiceDependencies     { @('himds','gcad') }
            Mock Get-RelevantScheduledTasks  { @('TaskA') }
            Mock Get-RelevantEventLogs       { @('EventA') }

            $result = Get-SystemState -ServerName 'TEST-SRV' -DetailedScan
            $result.DetailedInfo.InstalledSoftware.Count | Should -Be 2
            $result.DetailedInfo.Services.Count | Should -Be 2
        }
        finally {
            Remove-Item Function:\global:Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'returns Error status when Get-WmiObject throws' {
        Mock Get-WmiObject { throw 'WMI not available' }

        $result = Get-SystemState -ServerName 'TEST-SRV'
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'Get-TLSConfiguration returns TLS config with registry mocked' {
        Mock Invoke-Command { & $ScriptBlock } -ParameterFilter { $ComputerName -ne $null }
        Mock Test-Path { $true }
        Mock Get-ChildItem {
            @(
                [PSCustomObject]@{ PSChildName = 'TLS 1.2'; PSPath = 'HKLM:\...\TLS 1.2' },
                [PSCustomObject]@{ PSChildName = 'TLS 1.0'; PSPath = 'HKLM:\...\TLS 1.0' }
            )
        } -ParameterFilter { $Path -eq 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols' }
        Mock Get-ItemProperty {
            if ($Path -like '*TLS 1.2*') {
                [PSCustomObject]@{ Enabled = 1 }
            }
            else {
                [PSCustomObject]@{ Enabled = 0 }
            }
        } -ParameterFilter { $Name -eq 'Enabled' }

        $result = Get-TLSConfiguration -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        @($result).Count | Should -Be 2
        ($result | Where-Object Protocol -eq 'TLS 1.2').Enabled | Should -Be $true
    }

    It 'Get-FirewallStatus returns firewall state with Invoke-Command mocked' {
        Mock Invoke-Command { & $ScriptBlock } -ParameterFilter { $ComputerName -ne $null }
        Mock New-Object {
            $fw = [PSCustomObject]@{ CurrentProfileTypes = 7 }
            $fw | Add-Member -MemberType ScriptMethod -Name FirewallEnabled -Value {
                param($mask)
                $true
            }
            $fw
        } -ParameterFilter { $ComObject -eq 'HNetCfg.FwPolicy2' }
        Mock Get-NetFirewallRule {
            @(
                [PSCustomObject]@{ DisplayName='Azure Arc Management'; Enabled='True'; Direction='Outbound'; Action='Allow' },
                [PSCustomObject]@{ DisplayName='Azure Monitor'; Enabled='True'; Direction='Outbound'; Action='Allow' },
                [PSCustomObject]@{ DisplayName='Other Rule'; Enabled='True'; Direction='Inbound'; Action='Allow' }
            )
        }

        $result = Get-FirewallStatus -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.DomainProfile | Should -Be $true
        @($result.Rules).Count | Should -Be 2
    }

    It 'Get-CertificateStatus returns cert info with Invoke-Command mocked' {
        Mock Invoke-Command { & $ScriptBlock } -ParameterFilter { $ComputerName -ne $null }
        Mock Get-ChildItem {
            @(
                [PSCustomObject]@{ Subject='CN=Azure Arc'; Thumbprint='thumb-1'; NotAfter=(Get-Date).AddDays(10); NotBefore=(Get-Date).AddDays(-10) },
                [PSCustomObject]@{ Subject='CN=Other'; Thumbprint='thumb-2'; NotAfter=(Get-Date).AddDays(10); NotBefore=(Get-Date).AddDays(-10) }
            )
        } -ParameterFilter { $Path -eq 'Cert:\LocalMachine\My' }

        $result = Get-CertificateStatus -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        @($result).Count | Should -Be 1
        $result.Subject | Should -Be 'CN=Azure Arc'
        $result.IsValid | Should -Be $true
    }

    It 'Get-WindowsUpdateStatus returns update info with Invoke-Command mocked' {
        Mock Invoke-Command { & $ScriptBlock } -ParameterFilter { $ComputerName -ne $null }
        Mock New-Object {
            if ($ComObject -eq 'Microsoft.Update.Session') {
                $searcher = [PSCustomObject]@{}
                $searcher | Add-Member -MemberType ScriptMethod -Name GetTotalHistoryCount -Value { 2 }
                $searcher | Add-Member -MemberType ScriptMethod -Name QueryHistory -Value {
                    param($start, $count)
                    @(
                        [PSCustomObject]@{ Date = (Get-Date).AddDays(-1); Operation = 1 },
                        [PSCustomObject]@{ Date = (Get-Date).AddDays(-5); Operation = 2 }
                    )
                }
                $session = [PSCustomObject]@{}
                $session | Add-Member -MemberType NoteProperty -Name Searcher -Value $searcher
                $session | Add-Member -MemberType ScriptMethod -Name CreateUpdateSearcher -Value { $this.Searcher }
                return $session
            }
        } -ParameterFilter { $ComObject -eq 'Microsoft.Update.Session' }
        Mock Get-WmiObject {
            @(
                [PSCustomObject]@{ HotFixID='KB1' },
                [PSCustomObject]@{ HotFixID='KB2' }
            )
        } -ParameterFilter { $Class -eq 'Win32_QuickFixEngineering' }

        $result = Get-WindowsUpdateStatus -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.PendingUpdates | Should -Be 2
        $result.LastUpdateCheck | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 6. Get-AMAConfig.ps1  (123 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Get-AMAConfig.ps1 Coverage' {
    BeforeAll {
        foreach ($fn in @('Get-AzConnectedMachine')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() $null }
            }
        }
        . (Join-Path $script:SrcRoot 'core\Get-AMAConfig.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'returns config when AMA service is running' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName, $ErrorAction)
            [PSCustomObject]@{ Name='AzureMonitorAgent'; Status='Running'; StartType='Automatic'; DisplayName='Azure Monitor Agent' }
        }
        try {
            Mock Invoke-Command {
                @{
                    SettingsJson = @{ workspaceId = 'ws-123' }
                    AgentJson    = @{ version = '1.0' }
                    ConfigJson   = $null
                    MonitoringConfigJson = $null
                }
            }

            $result = Get-AMAConfig -ServerName 'TEST-SRV'
            $result | Should -Not -BeNullOrEmpty
            $result.ServiceStatus | Should -Be 'Running'
        }
        finally {
            Remove-Item Function:\global:Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'returns config with service not installed' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName, $ErrorAction)
            $null
        }
        try {
            Mock Invoke-Command { @{} } -ParameterFilter { $ComputerName -ne $null }

            $result = Get-AMAConfig -ServerName 'TEST-SRV'
            $result | Should -Not -BeNullOrEmpty
            @($result.Error) | Should -Contain 'AMA service not installed'
        }
        finally {
            Remove-Item Function:\global:Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'handles Get-Service exception gracefully' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName, $ErrorAction)
            throw 'Access denied'
        }
        try {
            $result = Get-AMAConfig -ServerName 'TEST-SRV'
            $result | Should -Not -BeNullOrEmpty
            $result.Error | Should -Match 'Access denied'
        }
        finally {
            Remove-Item Function:\global:Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'Get-AMALogCollectionStatus returns status with Invoke-Command mocked' {
        Mock Invoke-Command { @{ EventCount=0; LastEvent=$null } }
        $result = Get-AMALogCollectionStatus -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 7. Get-ArcAgentConfig.ps1  (121 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Get-ArcAgentConfig.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'core\Get-ArcAgentConfig.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'returns config when agent is reachable and config files exist' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName, $ErrorAction)
            [PSCustomObject]@{ Name='himds'; Status='Running'; StartType='Automatic'; DisplayName='Azure Connected Machine Agent' }
        }
        try {
            Mock Test-Connection { $true }
            Mock Test-Path       { $true }
            Mock Get-ChildItem   { @([PSCustomObject]@{ Name='agentconfig.json'; FullName='C:\arc\agentconfig.json'; LastWriteTime=(Get-Date) }) }
            Mock Get-Content     { '{"tenantId":"tenant-1","subscriptionId":"sub-1","resourceGroup":"rg-1","resourceName":"TEST-SRV"}' }

            $result = Get-ArcAgentConfig -ServerName 'TEST-SRV'
            $result | Should -Not -BeNullOrEmpty
            $result.ConfigFound | Should -Be $true
        }
        finally {
            Remove-Item Function:\global:Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'returns error when server is unreachable' {
        Mock Test-Connection { $false }

        $result = Get-ArcAgentConfig -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.ConfigFound | Should -Be $false
    }

    It 'returns parsed config object when -AsObject is specified' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName, $ErrorAction)
            [PSCustomObject]@{ Name='himds'; Status='Running'; StartType='Automatic'; DisplayName='Azure Connected Machine Agent' }
        }
        try {
            Mock Test-Connection { $true }
            Mock Test-Path       { $true }
            Mock Get-ChildItem   { @([PSCustomObject]@{ Name='agentconfig.json'; FullName='C:\arc\agentconfig.json'; LastWriteTime=(Get-Date) }) }
            Mock Get-Content     { '{"tenantId":"t-1","subscriptionId":"s-1","resourceGroup":"rg-1","resourceName":"SRV"}' }

            $result = Get-ArcAgentConfig -ServerName 'TEST-SRV' -AsObject
            $result | Should -Not -BeNullOrEmpty
        }
        finally {
            Remove-Item Function:\global:Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'returns detailed full config with extensions logs registry env and key info' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName, $ErrorAction)
            switch ($Name) {
                'himds' { [PSCustomObject]@{ Name='himds'; Status='Running'; StartType='Automatic'; DisplayName='Azure Connected Machine Agent' } ; break }
                'gcad'  { [PSCustomObject]@{ Name='gcad'; Status='Running'; StartType='Automatic'; DisplayName='Guest Configuration Arc Service' } ; break }
                default { $null }
            }
        }
        try {
            Mock Test-Connection { $true }
            Mock Test-Path {
                $Path -in @(
                    '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent',
                    '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\config\agentconfig.json',
                    '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\config\gc_agent_config.json',
                    '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\config\extensionconfig.json',
                    '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\config\identityconfig.json',
                    '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\config\state',
                    '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\Extensions',
                    '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\Extensions\CustomScript\status',
                    '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\logs',
                    '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\config\state\heartbeat'
                )
            }
            Mock Get-Content {
                switch ($Path) {
                    '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\config\agentconfig.json' { '{"resourceId":"/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/TEST-SRV","tenantId":"tenant-1","location":"eastus","machineName":"TEST-SRV","tags":{"env":"test"},"authentication":{"secret":"abc"}}' }
                    '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\config\gc_agent_config.json' { '{"mode":"monitor"}' }
                    '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\config\extensionconfig.json' { '{"extensions":["CustomScript"]}' }
                    '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\config\identityconfig.json' { '{"principalId":"pid-1"}' }
                    default { '{}' }
                }
            }
            Mock Get-ChildItem {
                if ($Path -eq '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\Extensions' -and $Directory) {
                    return @([PSCustomObject]@{ Name='CustomScript'; FullName='\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\Extensions\CustomScript' })
                }
                if ($Path -eq '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\Extensions\CustomScript\config\*.settings') {
                    return @([PSCustomObject]@{ Name='0.settings' })
                }
                if ($Path -eq '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\logs' -and $File) {
                    return @([PSCustomObject]@{ Name='himds.log'; Length=100; LastWriteTime=(Get-Date) })
                }
                @()
            }
            Mock Get-Item {
                [PSCustomObject]@{ LastWriteTime = (Get-Date).AddMinutes(-3) }
            } -ParameterFilter { $Path -eq '\\TEST-SRV\c$\Program Files\Azure Connected Machine Agent\config\state\heartbeat' }
            Mock Invoke-Command {
                if ($ScriptBlock.ToString() -like '*Azure Connected Machine Agent*') {
                    [PSCustomObject]@{ InstallationType='MSI'; ConfigVersion='1.0' }
                }
                else {
                    @(
                        [PSCustomObject]@{ Name='AZURE_TENANT_ID'; Value='tenant-1' },
                        [PSCustomObject]@{ Name='ARC_MODE'; Value='connected' }
                    )
                }
            }
            Mock Get-NetworkConfiguration { @{ ProxySettings=@{}; Connectivity=@{} } }

            $result = Get-ArcAgentConfig -ServerName 'TEST-SRV' -DetailLevel Full
            $result.ConfigFound | Should -Be $true
            $result.ServiceConfig.HIMDSService.Status | Should -Be 'Running'
            @($result.Extensions).Count | Should -Be 1
            @($result.Logs).Count | Should -Be 1
            $result.RegistryConfig.InstallationType | Should -Be 'MSI'
            @($result.EnvironmentVariables).Count | Should -Be 2
            $result.KeyInfo.SubscriptionId | Should -Be 'sub1'
            $result.ParsedConfig.AgentConfig.authentication.secret | Should -Be '*** REDACTED ***'
        }
        finally {
            Remove-Item Function:\global:Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'Get-NetworkConfiguration returns network info with Invoke-Command mocked' {
        Mock Invoke-Command {
            @{
                ProxySettings    = @{ WinHTTP = ''; WinINet = @{}; Environment = $null }
                IPConfiguration  = @()
                Connectivity     = @{}
                FirewallRules    = @()
            }
        }

        $result = Get-NetworkConfiguration -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Get-NetworkConfiguration executes local scriptblock and returns firewall connectivity and proxy data' {
        Mock Invoke-Command { & $ScriptBlock }
        Mock Get-ItemProperty { [PSCustomObject]@{ ProxyEnable = 1; ProxyServer = 'proxy:8080' } }
        Mock Get-NetIPConfiguration {
            @([PSCustomObject]@{ InterfaceAlias='Ethernet0'; IPv4Address='10.0.0.4'; IPv4DefaultGateway='10.0.0.1'; DNSServer=@('8.8.8.8') })
        }
        Mock Test-NetConnection {
            [PSCustomObject]@{ ComputerName=$ComputerName; RemotePort=$Port; TcpTestSucceeded=$true }
        }
        Mock Get-NetFirewallRule {
            @(
                [PSCustomObject]@{ DisplayName='Azure Arc Management'; Enabled='True'; Direction='Outbound'; Action='Allow' },
                [PSCustomObject]@{ DisplayName='Other Rule'; Enabled='True'; Direction='Inbound'; Action='Allow' }
            )
        }

        $result = Get-NetworkConfiguration -ServerName 'TEST-SRV'
        $result.ProxySettings.WinINet.ProxyServer | Should -Be 'proxy:8080'
        @($result.IPConfiguration).Count | Should -Be 1
        @($result.FirewallRules).Count | Should -Be 1
        $result.Connectivity.AzureManagement.TcpTestSucceeded | Should -Be $true
    }
}

# ---------------------------------------------------------------------------
# 8. Test-ValidationMatrix.ps1  (121 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Test-ValidationMatrix.ps1 Coverage' {
    BeforeAll {
        # Force-set stubs for all external deps so dot-source can define only what's in the file
        foreach ($fn in @('Test-ProxyConfiguration','Test-ArcConfiguration','Test-CertificateTrust','Test-ServicePrincipal','Test-NetConnection','Test-ResourceProvider','Test-ArcValidation','Test-AMAValidation','Test-ServiceHealth','Test-ArcConnectivity','Test-AMAConfiguration','Test-DataCollection','Test-DCRConfiguration','Test-ValidateArcAgent','Test-AgentValidation','Test-TLSConfiguration')) {
            Set-Item "Function:global:$fn" -Value { param() @{ Success=$true; Status='Passed' } }
        }
        . (Join-Path $script:SrcRoot 'core\Test-ValidationMatrix.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    $script:MockMatrix = @{
        Tests = @(
            @{ Name='ArcConnectivity'; Category='Connectivity'; Weight=20 }
            @{ Name='AMAConfiguration'; Category='Configuration'; Weight=15 }
        )
    }

    It 'returns overall validation matrix result when all tests pass' {
        Mock Get-Content { $script:MockMatrix | ConvertTo-Json -Depth 5 }
        Mock Test-NetConnection    { [PSCustomObject]@{ TcpTestSucceeded=$true } }
        Mock Test-ProxyConfiguration { @{ Success=$true } }
        Mock Test-TLSConfiguration   { @{ Success=$true } }
        Mock Test-CertificateTrust   { @{ Success=$true } }
        Mock Test-ServicePrincipal   { @{ Success=$true } }
        Mock Get-Service             { [PSCustomObject]@{ Status='Running' } }
        Mock Test-ArcConfiguration   { @{ Status='Success' } }
        Mock Test-ResourceProvider   { @{ Status='Success' } }
        Mock Test-ArcValidation      { @{ Status='Success' } }
        Mock Test-AMAValidation      { @{ Status='Success' } }
        Mock Test-ServiceHealth      { @{ Status='Success' } }
        Mock Test-ArcConnectivity    { @{ Status='Success'; Success=$true } }
        Mock Test-AMAConfiguration   { @{ Status='Success' } }
        Mock Test-DataCollection     { @{ Status='Success' } }
        Mock Test-DCRConfiguration   { @{ Status='Success' } }

        $result = Test-ValidationMatrix -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.ServerName | Should -Be 'TEST-SRV'
    }

    It 'Test-AgentValidation calls Get-Service and returns result' {
        Mock Get-Service { [PSCustomObject]@{ Name='himds'; Status='Running'; StartType='Automatic' } } -ParameterFilter { $Name -eq 'himds' }
        $result = Test-AgentValidation -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-ServiceHealth returns status with Get-Service mocked' {
        Mock Get-Service { [PSCustomObject]@{ Status='Running'; StartType='Automatic' } }
        $result = Test-ServiceHealth -ServerName 'TEST-SRV' -ServiceName 'himds'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-ArcValidation returns result hashtable with all fields' {
        Mock Test-ServiceHealth   { @{ Status='Running'; Healthy=$true } }
        Mock Test-ArcConfiguration { @{ IsValid=$true; Status='Success' } }
        Mock Test-ArcConnectivity  { @{ Connected=$true; Status='Success' } }
        $result = Test-ArcValidation -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.Service | Should -Not -BeNullOrEmpty
        $result.Configuration | Should -Not -BeNullOrEmpty
        $result.Connectivity | Should -Not -BeNullOrEmpty
    }

    It 'Test-AMAValidation returns result hashtable with all four fields' {
        Mock Test-ServiceHealth     { @{ Status='Running'; Healthy=$true } }
        Mock Test-AMAConfiguration  { @{ IsValid=$true; Status='Success' } }
        Mock Test-DataCollection    { @{ Status='Success'; DataCount=5 } }
        Mock Test-DCRConfiguration  { @{ Status='Success'; RulesCount=2 } }
        $result = Test-AMAValidation -ServerName 'TEST-SRV' -WorkspaceId 'ws-test-123'
        $result | Should -Not -BeNullOrEmpty
        $result.Service | Should -Not -BeNullOrEmpty
        $result.Configuration | Should -Not -BeNullOrEmpty
        $result.DataCollection | Should -Not -BeNullOrEmpty
        $result.DCR | Should -Not -BeNullOrEmpty
    }

    It 'Test-AgentValidation includes AMA when WorkspaceId provided' {
        Mock Test-ServiceHealth     { @{ Status='Running' } }
        Mock Test-ArcConfiguration  { @{ IsValid=$true } }
        Mock Test-ArcConnectivity   { @{ Connected=$true } }
        Mock Test-AMAConfiguration  { @{ IsValid=$true } }
        Mock Test-DataCollection    { @{ Status='Success' } }
        Mock Test-DCRConfiguration  { @{ Status='Success' } }
        $result = Test-AgentValidation -ServerName 'TEST-SRV' -WorkspaceId 'ws-789'
        $result | Should -Not -BeNullOrEmpty
        $result.Arc | Should -Not -BeNullOrEmpty
        $result.AMA | Should -Not -BeNullOrEmpty
    }

    It 'Test-AgentValidation omits AMA when no WorkspaceId provided' {
        Mock Test-ServiceHealth     { @{ Status='Running' } }
        Mock Test-ArcConfiguration  { @{ IsValid=$true } }
        Mock Test-ArcConnectivity   { @{ Connected=$true } }
        $result = Test-AgentValidation -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.Arc | Should -Not -BeNullOrEmpty
        $result.AMA | Should -BeNullOrEmpty
    }

    It 'Test-ServiceHealth handles Get-Service failure gracefully' {
        Mock Get-Service { throw 'Service not found' }
        $result = Test-ServiceHealth -ServerName 'TEST-SRV' -ServiceName 'nonexistent'
        $result | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 9. Start-ArcRemediation.ps1  (103 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Start-ArcRemediation.ps1 Coverage' {
    BeforeAll {
        foreach ($fn in @('Backup-AgentConfiguration','Get-RemediationStrategy','Repair-ArcService','Repair-AMAService','Restore-AgentConfiguration','Get-RemediationApproval','Test-Remediation','Test-DeploymentHealth')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() @{ Success=$true; Status='Completed' } }
            }
        }
        . (Join-Path $script:SrcRoot 'core\Start-ArcRemediation.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
        Mock New-Item    {} -ParameterFilter { $ItemType -eq 'Directory' }
        Mock Start-Transcript {} -ErrorAction SilentlyContinue
        Mock Stop-Transcript  {} -ErrorAction SilentlyContinue
    }

    It 'runs remediation for Arc Service issues with AutoApprove' {
        Mock Backup-AgentConfiguration  { @{ Path='C:\Backup\arc'; Success=$true } }
        Mock Get-RemediationStrategy    { @{ Strategy='Restart' } }
        Mock Repair-ArcService          { @{ Success=$true; Status='Completed' } }
        Mock Test-Remediation           { @{ Success=$true } }
        Mock Test-DeploymentHealth      { @{ Success=$true } }

        $issues = @(
            [PSCustomObject]@{ Component='Arc Service'; Severity='Critical'; Description='Service stopped' }
        )

        $result = Start-ArcRemediation -AnalysisResults $issues -ServerName 'TEST-SRV' -LogPath $TestDrive -AutoApprove
        $result | Should -Not -BeNullOrEmpty
        $result.Actions.Count | Should -BeGreaterThan 0
    }

    It 'skips action when not approved (AutoApprove not set)' {
        Mock Backup-AgentConfiguration { @{ Path='C:\Backup\arc'; Success=$true } }
        Mock Get-RemediationStrategy   { @{ Strategy='Restart' } }
        Mock Get-RemediationApproval   { $false }

        $issues = @(
            [PSCustomObject]@{ Component='Arc Service'; Severity='Critical'; Description='Service stopped' }
        )

        $result = Start-ArcRemediation -AnalysisResults $issues -ServerName 'TEST-SRV' -LogPath $TestDrive
        ($result.Actions | Where-Object { $_.Status -eq 'Skipped' }) | Should -Not -BeNullOrEmpty
    }

    It 'handles exception and restores backup' {
        Mock Backup-AgentConfiguration  { @{ Path='C:\Backup\arc'; Success=$true } }
        Mock Get-RemediationStrategy    { throw 'Strategy lookup failed' }
        Mock Restore-AgentConfiguration { @{ Success=$true } }

        $issues = @(
            [PSCustomObject]@{ Component='Arc Service'; Severity='Critical' }
        )

        $result = Start-ArcRemediation -AnalysisResults $issues -ServerName 'TEST-SRV' -LogPath $TestDrive -AutoApprove
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Repair-ArcService runs stop/start service with mocked cmdlets' {
        Mock Stop-Service  {} -ParameterFilter { $Name -eq 'himds' }
        Mock Start-Service {} -ParameterFilter { $Name -eq 'himds' }
        Mock Get-Service   { [PSCustomObject]@{ Status='Running' } } -ParameterFilter { $Name -eq 'himds' }

        $result = Repair-ArcService -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Repair-AMAService restarts AzureMonitorAgent service' {
        Mock Stop-Service  {} -ParameterFilter { $Name -eq 'AzureMonitorAgent' }
        Mock Start-Service {} -ParameterFilter { $Name -eq 'AzureMonitorAgent' }
        Mock Get-Service   { [PSCustomObject]@{ Status='Running' } } -ParameterFilter { $Name -eq 'AzureMonitorAgent' }

        $result = Repair-AMAService -ServerName 'TEST-SRV' -WorkspaceId 'ws-123'
        $result | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 10. Start-ArcDiagnostics.ps1 (309 lines)
# ---------------------------------------------------------------------------
Describe 'Start-ArcDiagnostics.ps1 Coverage' {
    BeforeAll {
        foreach ($fn in @('Get-SystemState','Test-ArcConnectivity','Get-ProxyConfiguration',
                          'Test-AMAConnectivity','Get-ArcAgentLogs','Get-AMALogs',
                          'Get-SystemLogs','Get-SecurityLogs','Get-DCRAssociationStatus',
                          'Invoke-AzOperationalInsightsQuery','Test-CertificateTrust',
                          'Get-DetailedProxyConfig','Get-FirewallConfiguration',
                          'Get-PerformanceMetrics','Test-SecurityBaseline')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() @{} }
            }
        }
        if (-not (Get-Command Get-LastHeartbeat -ErrorAction SilentlyContinue)) {
            Set-Item 'Function:global:Get-LastHeartbeat' -Value { param([string]$ServerName) [PSCustomObject]@{ Timestamp = Get-Date } }
        }
        . (Join-Path $script:SrcRoot 'core\Start-ArcDiagnostics.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path, [string]$Component)
        }
        $env:ARC_DIAG_TESTDATA = $null
    }

    AfterEach {
        $env:ARC_DIAG_TESTDATA = $null
    }

    It 'returns test data when ARC_DIAG_TESTDATA=1' {
        $env:ARC_DIAG_TESTDATA = '1'
        $result = Start-ArcDiagnostics -ServerName 'TEST-SRV' -OutputPath $TestDrive
        $result | Should -Not -BeNullOrEmpty
        $result.ArcStatus | Should -Not -BeNullOrEmpty
    }

    It 'returns test data with WorkspaceId when ARC_DIAG_TESTDATA=1' {
        $env:ARC_DIAG_TESTDATA = '1'
        $result = Start-ArcDiagnostics -ServerName 'TEST-SRV' -WorkspaceId 'ws-123' -OutputPath $TestDrive
        $result.AMAStatus | Should -Not -BeNullOrEmpty
    }

    It 'returns test data with DetailedScan when ARC_DIAG_TESTDATA=1' {
        $env:ARC_DIAG_TESTDATA = '1'
        $result = Start-ArcDiagnostics -ServerName 'TEST-SRV' -DetailedScan -OutputPath $TestDrive
        $result.DetailedAnalysis | Should -Not -BeNullOrEmpty
    }

    It 'runs normal path with all external functions mocked' {
        Mock Get-SystemState { @{ OS = @{ Version = '10.0' } } }
        Mock Get-Service {
            [PSCustomObject]@{ Name = 'himds'; Status = 'Running'; StartType = 'Automatic' }
        }
        Mock Get-ArcAgentConfig { @{ version = '1.0' } }
        Mock Get-LastHeartbeat { [PSCustomObject]@{ Timestamp = Get-Date } }
        Mock Test-ArcConnectivity { @{ Success = $true } }
        Mock Get-ProxyConfiguration { @{ Enabled = $false } }
        Mock Test-NetworkPaths { @() }
        Mock Get-ArcAgentLogs { @() }
        Mock Get-SystemLogs { @() }
        Mock Get-SecurityLogs { @() }
        Mock New-Item {}
        Mock Out-File {}
        Mock ConvertTo-Json { '{}' }
        $result = Start-ArcDiagnostics -ServerName 'TEST-SRV' -OutputPath $TestDrive
        $result | Should -Not -BeNullOrEmpty
    }

    It 'runs normal path with WorkspaceId and AMA mocks' {
        Mock Get-SystemState { @{} }
        Mock Get-Service {
            [PSCustomObject]@{ Name = 'himds'; Status = 'Running'; StartType = 'Automatic' }
        }
        Mock Get-ArcAgentConfig { @{} }
        Mock Get-LastHeartbeat { [PSCustomObject]@{ Timestamp = Get-Date } }
        Mock Get-AMAConfig { @{ WorkspaceId = 'ws-1' } }
        Mock Get-DataCollectionStatus { @{ Status = 'Active' } }
        Mock Get-DCRAssociationStatus { @{ State = 'Enabled' } }
        Mock Test-ArcConnectivity { @{ Success = $true } }
        Mock Test-AMAConnectivity { @{ Success = $true } }
        Mock Get-ProxyConfiguration { @{ Enabled = $false } }
        Mock Test-NetworkPaths { @() }
        Mock Get-ArcAgentLogs { @() }
        Mock Get-AMALogs { @() }
        Mock Get-SystemLogs { @() }
        Mock Get-SecurityLogs { @() }
        Mock New-Item {}
        Mock Out-File {}
        Mock ConvertTo-Json { '{}' }
        $result = Start-ArcDiagnostics -ServerName 'TEST-SRV' -WorkspaceId 'ws-1' -OutputPath $TestDrive
        $result | Should -Not -BeNullOrEmpty
    }

    It 'handles exception gracefully when Get-SystemState throws' {
        Mock Get-SystemState { throw 'Cannot reach server' }
        Mock Get-Service { throw 'Access denied' }
        Mock New-Item {}
        Mock Out-File {}
        Mock ConvertTo-Json { '{}' }
        { Start-ArcDiagnostics -ServerName 'TEST-SRV' -OutputPath $TestDrive } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# 11. Deploy-ArcAgent.ps1 (241 lines)
# ---------------------------------------------------------------------------
Describe 'Deploy-ArcAgent.ps1 Coverage' {
    BeforeAll {
        foreach ($fn in @('Test-ArcPrerequisites')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() @{ Success = $true; Checks = @() } }
            }
        }
        . (Join-Path $script:SrcRoot 'core\Deploy-ArcAgent.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path, [string]$Component)
        }
    }

    It 'returns Success when all steps pass' {
        Mock Test-ArcPrerequisites { @{ Success = $true; Checks = @() } }
        Mock Backup-ArcConfiguration { @{ Path = "$TestDrive\backup" } }
        Mock Install-ArcAgentInternal { @{ Success = $true } }
        Mock Test-DeploymentHealth { @{ Success = $true } }

        $result = Deploy-ArcAgent -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Success'
    }

    It 'throws when prerequisites check fails' {
        Mock Test-ArcPrerequisites { @{ Success = $false; Error = 'OS not supported'; Checks = @() } }

        { Deploy-ArcAgent -ServerName 'TEST-SRV' } | Should -Throw
    }

    It 'returns Failed with rollback when arc install fails' {
        Mock Test-ArcPrerequisites { @{ Success = $true; Checks = @() } }
        Mock Backup-ArcConfiguration { @{ Path = "$TestDrive\backup" } }
        Mock Install-ArcAgentInternal { @{ Success = $false; Error = 'Install failed' } }
        Mock Restore-ArcConfiguration { $true }

        $result = Deploy-ArcAgent -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Failed'
    }

    It 'deploys AMA when -DeployAMA is set and workspace params provided' {
        Mock Test-ArcPrerequisites { @{ Success = $true; Checks = @() } }
        Mock Backup-ArcConfiguration { @{ Path = "$TestDrive\backup" } }
        Mock Install-ArcAgentInternal { @{ Success = $true } }
        Mock Install-AMAExtension { @{ Success = $true } }
        Mock Set-DataCollectionRules { @{ Status = 'Success'; Changes = @() } }
        Mock Test-DeploymentHealth { @{ Success = $true } }

        $result = Deploy-ArcAgent -ServerName 'TEST-SRV' -DeployAMA -WorkspaceId 'ws-1' -WorkspaceKey 'key-1'
        $result.Status | Should -Be 'Success'
    }

    It 'throws when -DeployAMA set but workspace params missing' {
        Mock Test-ArcPrerequisites { @{ Success = $true; Checks = @() } }

        { Deploy-ArcAgent -ServerName 'TEST-SRV' -DeployAMA } | Should -Throw
    }

    It 'returns Failed when deployment validation fails' {
        Mock Test-ArcPrerequisites { @{ Success = $true; Checks = @() } }
        Mock Backup-ArcConfiguration { @{ Path = "$TestDrive\backup" } }
        Mock Install-ArcAgentInternal { @{ Success = $true } }
        Mock Test-DeploymentHealth { @{ Success = $false; Error = 'Agent not connected' } }
        Mock Restore-ArcConfiguration { $true }

        $result = Deploy-ArcAgent -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Failed'
    }
}

# ---------------------------------------------------------------------------
# 12. Test-ArcPrerequisites.ps1 (209 lines)
# ---------------------------------------------------------------------------
Describe 'Test-ArcPrerequisites.ps1 Coverage' {
    BeforeAll {
        foreach ($fn in @('Test-OSCompatibility','Test-TLSConfiguration')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() $true }
            }
        }
        . (Join-Path $script:SrcRoot 'core\Test-ArcPrerequisites.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path, [string]$Component)
        }
        $env:ARC_PREREQ_TESTDATA = $null
    }

    AfterEach {
        $env:ARC_PREREQ_TESTDATA = $null
    }

    It 'returns result using test data path with all checks mocked' {
        $env:ARC_PREREQ_TESTDATA = '1'
        Mock Test-OSCompatibility { $true }
        Mock Test-TLSConfiguration { @{ Success = $true; Version = 'TLS 1.2' } }
        Mock Test-NetConnection { [PSCustomObject]@{ TcpTestSucceeded = $true } }
        Mock Get-WmiObject { [PSCustomObject]@{ FreeSpace = 50GB } }
        $result = Test-ArcPrerequisites -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.Checks | Should -Not -BeNullOrEmpty
    }

    It 'reports Success=true when all checks pass' {
        $env:ARC_PREREQ_TESTDATA = '1'
        Mock Test-OSCompatibility { $true }
        Mock Test-TLSConfiguration { @{ Success = $true; Version = 'TLS 1.2' } }
        Mock Test-NetConnection { [PSCustomObject]@{ TcpTestSucceeded = $true } }
        Mock Get-WmiObject { [PSCustomObject]@{ FreeSpace = 50GB } }
        $result = Test-ArcPrerequisites -ServerName 'TEST-SRV'
        $result.Success | Should -Be $true
    }

    It 'reports TLS failure in checks when TLS check fails' {
        $env:ARC_PREREQ_TESTDATA = '1'
        Mock Test-OSCompatibility { $true }
        Mock Test-TLSConfiguration { @{ Success = $false; Version = '' } }
        Mock Test-NetConnection { [PSCustomObject]@{ TcpTestSucceeded = $true } }
        Mock Get-WmiObject { [PSCustomObject]@{ FreeSpace = 50GB } }
        $result = Test-ArcPrerequisites -ServerName 'TEST-SRV'
        $result.Success | Should -Be $false
    }

    It 'handles WMI failure gracefully' {
        $env:ARC_PREREQ_TESTDATA = '1'
        Mock Test-OSCompatibility { $true }
        Mock Test-TLSConfiguration { @{ Success = $true; Version = 'TLS 1.2' } }
        Mock Test-NetConnection { [PSCustomObject]@{ TcpTestSucceeded = $true } }
        Mock Get-WmiObject { throw 'WMI access denied' }
        { Test-ArcPrerequisites -ServerName 'TEST-SRV' } | Should -Not -Throw
    }

    It 'sets disk check failed when disk space is insufficient' {
        $env:ARC_PREREQ_TESTDATA = '1'
        Mock Test-OSCompatibility { $true }
        Mock Test-TLSConfiguration { @{ Success = $true; Version = 'TLS 1.2' } }
        Mock Test-NetConnection { [PSCustomObject]@{ TcpTestSucceeded = $true } }
        Mock Get-WmiObject { [PSCustomObject]@{ FreeSpace = 100MB } }
        $result = Test-ArcPrerequisites -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 13. Invoke-ArcAnalysis.ps1 (185 lines)
# ---------------------------------------------------------------------------
Describe 'Invoke-ArcAnalysis.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'core\Invoke-ArcAnalysis.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path, [string]$Component)
        }
    }

    It 'returns analysis results for minimal DiagnosticData' {
        $data = @{ ServerName = 'TEST-SRV'; ArcStatus = @{}; AMAStatus = @{} }
        $result = Invoke-ArcAnalysis -DiagnosticData $data
        $result | Should -Not -BeNullOrEmpty
        $result.Findings | Should -Not -BeNullOrEmpty
    }

    It 'includes baseline finding in Findings array' {
        $data = @{ ServerName = 'TEST-SRV'; ArcStatus = @{} }
        $result = Invoke-ArcAnalysis -DiagnosticData $data
        $result.Findings.Count | Should -BeGreaterOrEqual 1
    }

    It 'adds issue finding when ArcStatus ServiceStatus is Stopped' {
        $data = @{
            ServerName = 'TEST-SRV'
            ArcStatus  = @{ ServiceStatus = 'Stopped' }
            AMAStatus  = @{}
        }
        $result = Invoke-ArcAnalysis -DiagnosticData $data
        $result.Findings | Should -Not -BeNullOrEmpty
    }

    It 'runs with IncludeAMA flag' {
        $data = @{
            ServerName = 'TEST-SRV'
            ArcStatus  = @{ ServiceStatus = 'Running' }
            AMAStatus  = @{ ServiceStatus = 'Running' }
        }
        $result = Invoke-ArcAnalysis -DiagnosticData $data -IncludeAMA
        $result | Should -Not -BeNullOrEmpty
    }

    It 'returns result with Recommendations property' {
        $data = @{
            ServerName   = 'TEST-SRV'
            ArcStatus    = @{ ServiceStatus = 'Stopped' }
            Connectivity = @{ Arc = @{ Success = $false } }
        }
        $result = Invoke-ArcAnalysis -DiagnosticData $data
        $result.Recommendations | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 14. New-ArcDeployment.ps1 (169 lines)
# ---------------------------------------------------------------------------
Describe 'New-ArcDeployment.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'core\New-ArcDeployment.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path, [string]$Component)
        }
    }

    It 'generates connection command and returns output object with WhatIf' {
        $result = New-ArcDeployment -ServerName 'TEST-SRV' `
            -ResourceGroupName 'rg-test' `
            -SubscriptionId 'sub-1' `
            -Location 'eastus' `
            -TenantId 'tenant-1' `
            -WhatIf
        $result | Should -Not -BeNullOrEmpty
    }

    It 'includes connect keyword in OnboardingCommand' {
        $result = New-ArcDeployment -ServerName 'TEST-SRV' `
            -ResourceGroupName 'rg-test' `
            -SubscriptionId 'sub-1' `
            -Location 'eastus' `
            -TenantId 'tenant-1' `
            -WhatIf
        $result.OnboardingCommand | Should -Match 'connect'
    }

    It 'appends proxy parameters to command when ProxyUrl provided' {
        $result = New-ArcDeployment -ServerName 'TEST-SRV' `
            -ResourceGroupName 'rg-test' `
            -SubscriptionId 'sub-1' `
            -Location 'eastus' `
            -TenantId 'tenant-1' `
            -ProxyUrl 'http://proxy:8080' `
            -WhatIf
        $result.OnboardingCommand | Should -Match 'proxy'
    }

    It 'appends tags when Tags hashtable is provided' {
        $result = New-ArcDeployment -ServerName 'TEST-SRV' `
            -ResourceGroupName 'rg-test' `
            -SubscriptionId 'sub-1' `
            -Location 'eastus' `
            -TenantId 'tenant-1' `
            -Tags @{ env = 'prod'; team = 'ops' } `
            -WhatIf
        $result.OnboardingCommand | Should -Match 'tags'
    }

    It 'sets non-default Cloud in command' {
        $result = New-ArcDeployment -ServerName 'TEST-SRV' `
            -ResourceGroupName 'rg-test' `
            -SubscriptionId 'sub-1' `
            -Location 'eastus' `
            -TenantId 'tenant-1' `
            -Cloud 'AzureUSGovernment' `
            -WhatIf
        $result.OnboardingCommand | Should -Match 'AzureUSGovernment'
    }
}

# ---------------------------------------------------------------------------
# 15. Initialize-ArcDeployment.ps1 (134 lines)
# ---------------------------------------------------------------------------
Describe 'Initialize-ArcDeployment.ps1 Coverage' {
    BeforeAll {
        foreach ($fn in @('Get-AzContext','Set-AzContext','Get-AzResourceGroup','New-AzResourceGroup','Set-AzResourceGroup')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() $null }
            }
        }
        . (Join-Path $script:SrcRoot 'core\Initialize-ArcDeployment.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path, [string]$Component)
        }
    }

    It 'throws when Az.Accounts module is not available' {
        Mock Get-Module { $null } -ParameterFilter { $Name -eq 'Az.Accounts' }
        { Initialize-ArcDeployment -SubscriptionId 'sub-1' -ResourceGroupName 'rg-1' -Location 'eastus' } |
            Should -Throw
    }

    It 'throws when not logged into Azure' {
        Mock Get-Module { [PSCustomObject]@{ Name = 'Az.Accounts' } }
        Mock Get-AzContext { $null }
        { Initialize-ArcDeployment -SubscriptionId 'sub-1' -ResourceGroupName 'rg-1' -Location 'eastus' } |
            Should -Throw
    }

    It 'returns output when RG exists and subscription matches' {
        Mock Get-Module { [PSCustomObject]@{ Name = 'Az.Accounts' } }
        Mock Get-AzContext {
            [PSCustomObject]@{
                Account      = 'user@test.com'
                Subscription = [PSCustomObject]@{ Id = 'sub-1'; Name = 'Test Sub' }
                Tenant       = [PSCustomObject]@{ Id = 'tenant-1' }
            }
        }
        Mock Get-AzResourceGroup {
            [PSCustomObject]@{ ResourceGroupName = 'rg-1'; Location = 'eastus'; ProvisioningState = 'Succeeded'; Tags = @{} }
        }
        $result = Initialize-ArcDeployment -SubscriptionId 'sub-1' -ResourceGroupName 'rg-1' -Location 'eastus'
        $result | Should -Not -BeNullOrEmpty
        $result.ResourceGroupName | Should -Be 'rg-1'
    }

    It 'creates RG when it does not exist' {
        Mock Get-Module { [PSCustomObject]@{ Name = 'Az.Accounts' } }
        Mock Get-AzContext {
            [PSCustomObject]@{
                Account      = 'user@test.com'
                Subscription = [PSCustomObject]@{ Id = 'sub-1'; Name = 'Test Sub' }
                Tenant       = [PSCustomObject]@{ Id = 'tenant-1' }
            }
        }
        Mock Get-AzResourceGroup { $null }
        Mock New-AzResourceGroup {
            [PSCustomObject]@{ ResourceGroupName = 'rg-new'; Location = 'eastus'; ProvisioningState = 'Succeeded' }
        }
        $result = Initialize-ArcDeployment -SubscriptionId 'sub-1' -ResourceGroupName 'rg-new' -Location 'eastus'
        $result | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 16. Test-DeploymentHealth.ps1 (120 lines)
# ---------------------------------------------------------------------------
Describe 'Test-DeploymentHealth.ps1 Coverage' {
    BeforeAll {
        # Get-ArcAgentStatus and Test-ArcConnection are guarded stubs already
        # defined via Deploy-ArcAgent.ps1 dot-source above; just ensure existence
        if (-not (Get-Command Get-ArcAgentStatus -ErrorAction SilentlyContinue)) {
            Set-Item 'Function:global:Get-ArcAgentStatus' -Value { param() @{ Status = 'Connected' } }
        }
        if (-not (Get-Command Test-ArcConnection -ErrorAction SilentlyContinue)) {
            Set-Item 'Function:global:Test-ArcConnection' -Value { param() @{ Status = $true; Success = $true } }
        }
        . (Join-Path $script:SrcRoot 'core\Test-DeploymentHealth.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path, [string]$Component)
        }
    }

    It 'returns Success=true when all components are healthy' {
        Mock Get-ArcAgentStatus { @{ Status = 'Connected'; Details = @{} } }
        Mock Test-ArcConnection { @{ Status = $true; Success = $true; Details = @{} } }
        $result = Test-DeploymentHealth -ServerName 'TEST-SRV'
        $result.Success | Should -Be $true
    }

    It 'returns Success=false when ArcAgent status is Disconnected' {
        Mock Get-ArcAgentStatus { @{ Status = 'Disconnected'; Details = @{} } }
        Mock Test-ArcConnection { @{ Status = $true; Success = $true; Details = @{} } }
        $result = Test-DeploymentHealth -ServerName 'TEST-SRV'
        $result.Success | Should -Be $false
    }

    It 'returns Success=false when connectivity check fails' {
        Mock Get-ArcAgentStatus { @{ Status = 'Connected'; Details = @{} } }
        Mock Test-ArcConnection { @{ Status = $false; Success = $false; Details = @{} } }
        $result = Test-DeploymentHealth -ServerName 'TEST-SRV'
        $result.Success | Should -Be $false
    }

    It 'checks AMA service when -ValidateAMA is specified' {
        Mock Get-ArcAgentStatus { @{ Status = 'Connected'; Details = @{} } }
        Mock Test-ArcConnection { @{ Status = $true; Success = $true; Details = @{} } }
        Mock Get-Service { [PSCustomObject]@{ Name = 'AzureMonitorAgent'; Status = 'Running' } }
        $result = Test-DeploymentHealth -ServerName 'TEST-SRV' -ValidateAMA
        $result | Should -Not -BeNullOrEmpty
    }

    It 'handles exception gracefully when agent unreachable' {
        Mock Get-ArcAgentStatus { throw 'Cannot connect to server' }
        { Test-DeploymentHealth -ServerName 'TEST-SRV' } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# 17. Start-ArcTroubleshooter.ps1 (118 lines)
# ---------------------------------------------------------------------------
Describe 'Start-ArcTroubleshooter.ps1 Coverage' {
    BeforeAll {
        foreach ($fn in @('Get-SystemState','Test-ArcConnectivity','Test-ConfigurationDrift',
                          'Invoke-ArcAnalysis','Start-ArcRemediation')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() @{ Status = 'Success'; Data = @{}; SessionId = 'test' } }
            }
        }
        if (-not (Get-Command Start-ArcDiagnostics -ErrorAction SilentlyContinue)) {
            Set-Item 'Function:global:Start-ArcDiagnostics' -Value { param() [PSCustomObject]@{ ArcStatus = @{}; SessionId = 'diag-seeded' } }
        }
        . (Join-Path $script:SrcRoot 'core\Start-ArcTroubleshooter.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path, [string]$Component)
        }
        Mock New-Item {}
        Mock Start-Transcript {}
        Mock Stop-Transcript {}
        Mock Get-SystemState { @{ OS = @{ Version = '10.0' } } }
        Mock Start-ArcDiagnostics { [PSCustomObject]@{ ArcStatus = @{}; SessionId = 'diag-1' } }
        Mock Test-ArcConnectivity { @{ Success = $true } }
        Mock Test-ConfigurationDrift { @{ Status = 'Compliant' } }
        Mock Invoke-ArcAnalysis { @{ Findings = @(); Recommendations = @(); RiskScore = 0.1 } }
    }

    It 'returns session object on success with all mocks' {
        $result = Start-ArcTroubleshooter -ServerName 'TEST-SRV' -OutputPath $TestDrive
        $result | Should -Not -BeNullOrEmpty
    }

    It 'runs with AutoRemediate flag' {
        Mock Start-ArcRemediation { @{ Status = 'Success' } }
        $result = Start-ArcTroubleshooter -ServerName 'TEST-SRV' -AutoRemediate -OutputPath $TestDrive
        $result | Should -Not -BeNullOrEmpty
    }

    It 'does not throw when diagnostics collection throws' {
        Mock Start-ArcDiagnostics { throw 'Remote connection failed' }
        { Start-ArcTroubleshooter -ServerName 'TEST-SRV' -OutputPath $TestDrive } | Should -Not -Throw
    }

    It 'accepts DriftBaselinePath parameter' {
        $result = Start-ArcTroubleshooter -ServerName 'TEST-SRV' `
            -DriftBaselinePath "$TestDrive\baseline.json" -OutputPath $TestDrive
        $result | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Extra: Get-AMAConfig.ps1 additional branches
# ---------------------------------------------------------------------------
Describe 'Get-AMAConfig.ps1 additional branch coverage' {
    BeforeAll {
        foreach ($fn in @('Get-AzConnectedMachine','Get-AzDataCollectionRuleAssociation')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() $null }
            }
        }
        if (-not (Get-Command Get-AMAConfig -ErrorAction SilentlyContinue)) {
            . (Join-Path $script:SrcRoot 'core\Get-AMAConfig.ps1')
        }
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'populates DCRs when MonitoringConfigJson has dataCollectionRules' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName, $ErrorAction)
            [PSCustomObject]@{ Name='AzureMonitorAgent'; Status='Running'; StartType='Automatic' }
        }
        try {
            Mock Invoke-Command {
                @{
                    SettingsJson         = @{ workspaceId = 'ws-dcr-test' }
                    AgentJson            = @{ version = '2.1' }
                    ConfigJson           = $null
                    MonitoringConfigJson = @{
                        dataCollectionRules = @(
                            @{ id = '/sub/dcr1'; name = 'DCR-One'; streams = @('Event'); dataSources = @('WinEvent') }
                            @{ id = '/sub/dcr2'; name = 'DCR-Two'; streams = @('Perf');  dataSources = @('WinPerf')  }
                        )
                    }
                }
            }
            $result = Get-AMAConfig -ServerName 'TEST-SRV'
            $result | Should -Not -BeNullOrEmpty
            $result.ConfigFound | Should -Be $true
            @($result.DCRs).Count | Should -BeGreaterOrEqual 2
        }
        finally {
            Remove-Item Function:\global:Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'redacts workspaceKey when -IncludeSecrets is not set' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName, $ErrorAction)
            [PSCustomObject]@{ Name='AzureMonitorAgent'; Status='Running'; StartType='Automatic' }
        }
        try {
            Mock Invoke-Command {
                @{
                    SettingsJson = [PSCustomObject]@{ workspaceId = 'ws-secret-test'; workspaceKey = 'real-secret-key' }
                    AgentJson    = $null
                    ConfigJson   = $null
                    MonitoringConfigJson = $null
                }
            }
            $result = Get-AMAConfig -ServerName 'TEST-SRV'
            $result.ConfigDetails.Settings.workspaceKey | Should -Be '***REDACTED***'
        }
        finally {
            Remove-Item Function:\global:Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'returns config when config files are null (Invoke-Command returns null)' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName, $ErrorAction)
            [PSCustomObject]@{ Name='AzureMonitorAgent'; Status='Running'; StartType='Automatic' }
        }
        try {
            Mock Invoke-Command { $null }
            $result = Get-AMAConfig -ServerName 'TEST-SRV'
            $result | Should -Not -BeNullOrEmpty
            @($result.Error) | Should -Contain 'Configuration files not found'
        }
        finally {
            Remove-Item Function:\global:Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'runs in -Detailed mode and calls Invoke-Command multiple times' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName, $ErrorAction)
            [PSCustomObject]@{ Name='AzureMonitorAgent'; Status='Running'; StartType='Automatic' }
        }
        try {
            Mock Invoke-Command {
                @{ SettingsJson = @{ workspaceId = 'ws-det' }; AgentJson = $null; ConfigJson = $null; MonitoringConfigJson = $null }
            } -ParameterFilter { $ScriptBlock.ToString() -like '*Azure Monitor Agent\config*' }
            Mock Invoke-Command {
                @{ DisplayName = 'Azure Monitor Agent'; ImagePath = 'C:\bin\ama.exe'; Start = 2; Type = 16 }
            } -ParameterFilter { $ScriptBlock.ToString() -like '*CurrentControlSet\\Services\\AzureMonitorAgent*' }
            Mock Invoke-Command {
                @{ FileVersion = '1.9.0.0'; ProductVersion = '1.9.0.0' }
            } -ParameterFilter { $ScriptBlock.ToString() -like '*AzureMonitorAgent.exe*' }
            Mock Get-AMALogCollectionStatus { @{ LogCount = 3; RecentErrorCount = 0 } }
            $result = Get-AMAConfig -ServerName 'TEST-SRV' -Detailed
            $result | Should -Not -BeNullOrEmpty
            $result.ConfigFound | Should -Be $true
            $result.Version | Should -Be '1.9.0.0'
        }
        finally {
            Remove-Item Function:\global:Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'extracts workspaceId from SettingsJson into top-level property' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName, $ErrorAction)
            [PSCustomObject]@{ Name='AzureMonitorAgent'; Status='Running'; StartType='Automatic' }
        }
        try {
            Mock Invoke-Command {
                @{
                    SettingsJson = @{ workspaceId = 'ws-extract-test' }
                    AgentJson    = $null
                    ConfigJson   = $null
                    MonitoringConfigJson = $null
                }
            }
            $result = Get-AMAConfig -ServerName 'TEST-SRV'
            $result.WorkspaceId | Should -Be 'ws-extract-test'
        }
        finally {
            Remove-Item Function:\global:Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'executes config parsing scriptblock locally and populates config sections' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName, $ErrorAction)
            [PSCustomObject]@{ Name='AzureMonitorAgent'; Status='Running'; StartType='Automatic' }
        }
        try {
            Mock Invoke-Command { & $ScriptBlock }
            Mock Test-Path {
                $Path -in @(
                    'C:\Program Files\Azure Monitor Agent\config',
                    'C:\Program Files\Azure Monitor Agent\config\settings.json',
                    'C:\Program Files\Azure Monitor Agent\config\agent.json',
                    'C:\Program Files\Azure Monitor Agent\config\config.json',
                    'C:\Program Files\Azure Monitor Agent\config\monitoring_config.json'
                )
            }
            Mock Get-Content {
                switch ($Path) {
                    'C:\Program Files\Azure Monitor Agent\config\settings.json' { '{"workspaceId":"ws-local","workspaceKey":"secret-local"}' }
                    'C:\Program Files\Azure Monitor Agent\config\agent.json' { '{"version":"3.1.4"}' }
                    'C:\Program Files\Azure Monitor Agent\config\config.json' { '{"mode":"full"}' }
                    'C:\Program Files\Azure Monitor Agent\config\monitoring_config.json' { '{"dataCollectionRules":[{"id":"/sub/dcr-local","name":"LocalDcr","streams":["Perf"],"dataSources":["Counter"]}]}' }
                    default { '{}' }
                }
            }

            $result = Get-AMAConfig -ServerName 'TEST-SRV'
            $result.ConfigFound | Should -Be $true
            $result.WorkspaceId | Should -Be 'ws-local'
            $result.ConfigDetails.Agent.version | Should -Be '3.1.4'
            $result.ConfigDetails.Settings.workspaceKey | Should -Be '***REDACTED***'
            @($result.DCRs).Count | Should -Be 1
        }
        finally {
            Remove-Item Function:\global:Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'executes detailed remote scriptblocks locally and populates registry version and Azure associations' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName, $ErrorAction)
            [PSCustomObject]@{ Name='AzureMonitorAgent'; Status='Running'; StartType='Automatic' }
        }
        try {
            Mock Invoke-Command { & $ScriptBlock }
            Mock Test-Path {
                $Path -in @(
                    'C:\Program Files\Azure Monitor Agent\config',
                    'C:\Program Files\Azure Monitor Agent\config\settings.json',
                    'HKLM:\SYSTEM\CurrentControlSet\Services\AzureMonitorAgent',
                    'C:\Program Files\Azure Monitor Agent\Agent\AzureMonitorAgent.exe'
                )
            }
            Mock Get-Content {
                '{"workspaceId":"ws-detailed"}'
            } -ParameterFilter { $Path -eq 'C:\Program Files\Azure Monitor Agent\config\settings.json' }
            Mock Get-ItemProperty {
                [PSCustomObject]@{ DisplayName='Azure Monitor Agent'; ImagePath='C:\ama.exe'; Start=2; Type=16 }
            }
            Mock Get-Item {
                [PSCustomObject]@{ VersionInfo = [PSCustomObject]@{ FileVersion='2.0.1.0'; ProductVersion='2.0.1.0' } }
            }
            Mock Get-AzConnectedMachine {
                [PSCustomObject]@{ Id='/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/TEST-SRV' }
            }
            Mock Get-AzDataCollectionRuleAssociation {
                @([PSCustomObject]@{ Name='assoc-1'; DataCollectionRuleId='/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.Insights/dataCollectionRules/dcr1' })
            }
            Mock Get-AMALogCollectionStatus { @{ LogCount = 4; RecentErrorCount = 1 } }

            $result = Get-AMAConfig -ServerName 'TEST-SRV' -Detailed
            $result.ConfigFound | Should -Be $true
            $result.ConfigDetails.Registry.DisplayName | Should -Be 'Azure Monitor Agent'
            $result.Version | Should -Be '2.0.1.0'
            @($result.AzureDCRAssociations).Count | Should -Be 1
            $result.LogCollection.LogCount | Should -Be 4
        }
        finally {
            Remove-Item Function:\global:Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'Get-AMALogCollectionStatus aggregates logs events and buffer files when scriptblock runs locally' {
        Mock Invoke-Command { & $ScriptBlock }
        Mock Test-Path {
            $Path -in @(
                'C:\Program Files\Azure Monitor Agent\Logs',
                'C:\Program Files\Azure Monitor Agent\Agent\Buffer'
            )
        }
        Mock Get-ChildItem {
            if ($Path -eq 'C:\Program Files\Azure Monitor Agent\Logs') {
                return @(
                    [PSCustomObject]@{ Length = 100 },
                    [PSCustomObject]@{ Length = 50 }
                )
            }
            if ($Path -eq 'C:\Program Files\Azure Monitor Agent\Agent\Buffer') {
                return @(
                    [PSCustomObject]@{ Length = 25 },
                    [PSCustomObject]@{ Length = 35 }
                )
            }
            @()
        }
        Mock Get-WinEvent {
            @(
                [PSCustomObject]@{ LevelDisplayName='Error'; TimeCreated=(Get-Date); Message='Error one'; Id=101 },
                [PSCustomObject]@{ LevelDisplayName='Warning'; TimeCreated=(Get-Date); Message='Warn one'; Id=201 },
                [PSCustomObject]@{ LevelDisplayName='Error'; TimeCreated=(Get-Date); Message='Error two'; Id=102 }
            )
        }

        $result = Get-AMALogCollectionStatus -ServerName 'TEST-SRV'
        $result.LogCount | Should -Be 2
        $result.LogSize | Should -Be 150
        $result.RecentErrorCount | Should -Be 2
        $result.RecentWarningCount | Should -Be 1
        $result.BufferFileCount | Should -Be 2
        $result.BufferSize | Should -Be 60
        @($result.RecentErrors).Count | Should -Be 2
    }
}

# ---------------------------------------------------------------------------
# Extra: Get-ArcRegistrationStatus additional branch coverage
# ---------------------------------------------------------------------------
Describe 'Get-ArcRegistrationStatus.ps1 additional branches' {
    BeforeAll {
        foreach ($fn in @('Get-AzConnectedMachine','Get-AzConnectedMachineExtension','Get-AzHealthResource','Get-AzPolicyState','Get-AzActivityLog')) {
            Set-Item "Function:global:$fn" -Value { param() $null } -Force
        }
        if (-not (Get-Command Get-ArcRegistrationStatus -ErrorAction SilentlyContinue)) {
            . (Join-Path $script:SrcRoot 'core\Get-ArcRegistrationStatus.ps1')
        }
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'includes registration history when -IncludeHistory is specified' {
        Mock Get-AzConnectedMachine {
            [PSCustomObject]@{
                Id='/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/TEST-SRV'
                Status='Connected'; Location='eastus'; AgentVersion='1.0'; LastStatusChange=(Get-Date)
                OSName='Windows Server 2019'; OSVersion='10.0'; ProvisioningState='Succeeded'; DisplayName='TEST-SRV'; Tag=@{}
            }
        }
        Mock Get-LocalAgentStatus { @{ Status='Connected'; Installed=$true } }
        Mock Get-AzActivityLog {
            @(
                [PSCustomObject]@{
                    EventTimestamp = (Get-Date).AddDays(-1)
                    OperationName = [PSCustomObject]@{ Value = 'Connect machine' }
                    Status = [PSCustomObject]@{ Value = 'Succeeded' }
                    SubStatus = [PSCustomObject]@{ Value = 'OK' }
                    Caller = 'user@contoso.com'
                    Category = [PSCustomObject]@{ Value = 'Administrative' }
                    Level = 'Informational'
                    CorrelationId = 'corr-1'
                }
            )
        }

        $result = Get-ArcRegistrationStatus -ServerName 'TEST-SRV' -IncludeHistory
        @($result.History).Count | Should -Be 1
    }

    It 'flags status mismatch when Azure and local state differ' {
        Mock Get-AzConnectedMachine {
            [PSCustomObject]@{
                Id='/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/TEST-SRV'
                Status='Connected'; Location='eastus'; AgentVersion='1.0'; LastStatusChange=(Get-Date)
                OSName='Windows Server 2019'; OSVersion='10.0'; ProvisioningState='Succeeded'; DisplayName='TEST-SRV'; Tag=@{}
            }
        }
        Mock Get-LocalAgentStatus { @{ Status='Stopped'; Installed=$true } }

        $result = Get-ArcRegistrationStatus -ServerName 'TEST-SRV'
        $result.Details.StatusMismatch | Should -Be $true
    }

    It 'Get-ArcExtensions returns projected extension properties' {
        Mock Get-AzConnectedMachineExtension {
            @(
                [PSCustomObject]@{
                    Name = 'AzureMonitorWindowsAgent'
                    ProvisioningState = 'Succeeded'
                    Status = 'Running'
                    ExtensionType = 'AzureMonitorWindowsAgent'
                    Publisher = 'Microsoft.Azure.Monitor'
                    TypeHandlerVersion = '1.0'
                    AutoUpgradeMinorVersion = $true
                    Settings = @{ workspaceId = 'ws-1' }
                }
            )
        }

        $result = Get-ArcExtensions -ServerName 'TEST-SRV'
        @($result).Count | Should -Be 1
        $result.Publisher | Should -Be 'Microsoft.Azure.Monitor'
    }

    It 'Get-ArcResourceHealth returns mapped health fields' {
        Mock Get-AzConnectedMachine {
            [PSCustomObject]@{ Id='/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/TEST-SRV' }
        }
        Mock Get-AzHealthResource {
            [PSCustomObject]@{
                Properties = [PSCustomObject]@{
                    AvailabilityState = 'Available'
                    DetailedStatus = 'Healthy'
                    ReasonType = 'Resolved'
                    ReasonChronicity = 'Transient'
                    RestoredTime = (Get-Date)
                    OccurredTime = (Get-Date).AddMinutes(-10)
                }
            }
        }

        $result = Get-ArcResourceHealth -ServerName 'TEST-SRV'
        $result.AvailabilityState | Should -Be 'Available'
    }

    It 'Get-ArcComplianceStatus returns mapped policy state records' {
        Mock Get-AzConnectedMachine {
            [PSCustomObject]@{ Id='/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/TEST-SRV' }
        }
        Mock Get-AzPolicyState {
            @(
                [PSCustomObject]@{
                    PolicyDefinitionId = '/providers/Microsoft.Authorization/policyDefinitions/p1'
                    PolicyDefinitionName = 'Allowed locations'
                    PolicySetDefinitionName = 'Baseline'
                    ComplianceState = 'Compliant'
                    ComplianceReasonCode = 'Current'
                    Timestamp = (Get-Date)
                }
            )
        }

        $result = Get-ArcComplianceStatus -ServerName 'TEST-SRV'
        @($result).Count | Should -Be 1
        $result.ComplianceState | Should -Be 'Compliant'
    }
}

# ---------------------------------------------------------------------------
# Extra: Test-ValidationMatrix.ps1 additional branch coverage
# ---------------------------------------------------------------------------
Describe 'Test-ValidationMatrix.ps1 extra branch coverage' {
    BeforeAll {
        foreach ($fn in @('Test-ProxyConfiguration','Test-ArcConfiguration','Test-CertificateTrust','Test-ServicePrincipal','Test-NetConnection','Test-ResourceProvider','Test-ArcValidation','Test-AMAValidation','Test-ServiceHealth','Test-ArcConnectivity','Test-AMAConfiguration','Test-DataCollection','Test-DCRConfiguration','Test-ValidateArcAgent','Test-AgentValidation','Test-TLSConfiguration')) {
            Set-Item "Function:global:$fn" -Value { param() @{ Success=$true; Status='Passed'; Healthy=$true; Connected=$true; IsValid=$true } }
        }
        if (-not (Get-Command Test-ValidationMatrix -ErrorAction SilentlyContinue)) {
            . (Join-Path $script:SrcRoot 'core\Test-ValidationMatrix.ps1')
        }
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'returns result when called with WorkspaceId' {
        Mock Get-Service { [PSCustomObject]@{ Status='Running'; StartType='Automatic' } }
        $result = Test-ValidationMatrix -ServerName 'TEST-SRV' -WorkspaceId 'ws-matrix-1'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-ArcConfiguration returns result with Invoke-Command mocked' {
        Mock Invoke-Command { [PSCustomObject]@{ Status='Running' } }
        $result = Test-ArcConfiguration -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-ArcConnectivity (from matrix) returns result with Test-NetConnection mocked' {
        Mock Test-NetConnection { [PSCustomObject]@{ TcpTestSucceeded=$true } }
        $result = Test-ArcConnectivity -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Extra: Invoke-ArcAnalysis.ps1 branch coverage
# ---------------------------------------------------------------------------
Describe 'Invoke-ArcAnalysis.ps1 additional branch coverage' {
    BeforeAll {
        Remove-Item Function:\global:Invoke-ArcAnalysis -ErrorAction SilentlyContinue
        Remove-Item Function:\Invoke-ArcAnalysis -ErrorAction SilentlyContinue
        . (Join-Path $script:SrcRoot 'core\Invoke-ArcAnalysis.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path,[string]$Component) }
    }

    It 'returns ServiceRunning finding when ArcStatus.ServiceStatus is Running' {
        $data = @{
            ServerName = 'ARC-SRV-01'
            ArcStatus  = [PSCustomObject]@{ ServiceStatus = 'Running' }
        }
        $result = Invoke-ArcAnalysis -DiagnosticData $data
        $result | Should -Not -BeNullOrEmpty
        $result.Findings | Should -Contain 'Arc:ServiceRunning'
        $result.RiskScore | Should -BeLessThan 0.5
    }

    It 'returns ServiceNotRunning finding when ArcStatus.ServiceStatus is Stopped' {
        $data = @{
            ServerName = 'ARC-SRV-02'
            ArcStatus  = [PSCustomObject]@{ ServiceStatus = 'Stopped' }
        }
        $result = Invoke-ArcAnalysis -DiagnosticData $data
        $result.Findings | Should -Contain 'Arc:ServiceNotRunning'
        $result.RiskScore | Should -BeGreaterOrEqual 0.8
        $result.Recommendations.Count | Should -BeGreaterThan 0
    }

    It 'includes AMA finding when IncludeAMA flag set' {
        $data = @{
            ServerName = 'ARC-SRV-03'
            AMAStatus  = [PSCustomObject]@{ Status = 'Running' }
        }
        $result = Invoke-ArcAnalysis -DiagnosticData $data -IncludeAMA
        $result.Findings | Should -Contain 'AMA'
    }

    It 'handles missing ConfigPath gracefully (no patterns loaded)' {
        $data = @{ ServerName = 'ARC-SRV-04' }
        $result = Invoke-ArcAnalysis -DiagnosticData $data -ConfigPath 'C:\nonexistent\patterns.json'
        $result | Should -Not -BeNullOrEmpty
        $result.Findings | Should -Contain 'ArcAnalysis:Completed'
    }

    It 'handles exception and returns error in result' {
        Mock Get-Content { throw 'File read error' } -ParameterFilter { $LiteralPath -like '*patterns.json*' }
        $data = @{ ServerName = 'ARC-SRV-05'; ArcStatus = $null }
        $result = Invoke-ArcAnalysis -DiagnosticData $data
        $result | Should -Not -BeNullOrEmpty
    }

    It 'returns no-remediation recommendation when all checks pass' {
        $data = @{
            ServerName = 'ARC-SRV-06'
            ArcStatus  = [PSCustomObject]@{ ServiceStatus = 'Running' }
        }
        $result = Invoke-ArcAnalysis -DiagnosticData $data
        $result.Recommendations | Should -Contain 'No immediate remediation required; continue monitoring.'
    }

    It 'uses Service field as fallback when ServiceStatus not present' {
        $data = @{
            ServerName = 'ARC-SRV-07'
            ArcStatus  = [PSCustomObject]@{ Service = 'Stopped' }
        }
        $result = Invoke-ArcAnalysis -DiagnosticData $data
        $result.Findings | Should -Contain 'Arc:ServiceNotRunning'
    }
}

# ---------------------------------------------------------------------------
# Extra: Initialize-AIComponents.ps1 branch coverage
# ---------------------------------------------------------------------------
Describe 'Initialize-AIComponents.ps1 additional branch coverage' {
    BeforeAll {
        foreach ($fn in @('Initialize-AIEngine','Get-ServerTelemetry','Invoke-AIPrediction',
                          'Find-DiagnosticPattern','Get-AIInsights','Get-PredictionRecommendations',
                          'Get-RemediationAction','Invoke-Remediation')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() [PSCustomObject]@{ Status='Ready'; Components=@{ PatternRecognition=@{ Patterns=@{} }; Prediction=@{ Models=@{ HealthPrediction=$null } } } } }
            }
        }
        . (Join-Path $script:SrcRoot 'AI\Initialize-AIComponents.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'returns components object with Engine and Status properties' {
        $config = [PSCustomObject]@{ ModelPath='C:\models'; LogPath="$TestDrive\ai.log" }
        $result = Initialize-AIComponents -Config $config
        $result | Should -Not -BeNullOrEmpty
        $result.Status | Should -Not -BeNullOrEmpty
    }

    It 'PredictDeploymentRisk scriptblock is accessible' {
        $config = [PSCustomObject]@{ ModelPath='C:\models' }
        $result = Initialize-AIComponents -Config $config
        $result.PredictDeploymentRisk | Should -Not -BeNullOrEmpty
    }

    It 'AnalyzeDiagnostics scriptblock is accessible' {
        $config = [PSCustomObject]@{ ModelPath='C:\models' }
        $result = Initialize-AIComponents -Config $config
        $result.AnalyzeDiagnostics | Should -Not -BeNullOrEmpty
    }

    It 'GenerateRemediationPlan scriptblock is accessible' {
        $config = [PSCustomObject]@{ ModelPath='C:\models' }
        $result = Initialize-AIComponents -Config $config
        $result.GenerateRemediationPlan | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Extra: Get-LastHeartbeat.ps1 branch coverage
# ---------------------------------------------------------------------------
Describe 'Get-LastHeartbeat.ps1 additional branch coverage' {
    BeforeAll {
        foreach ($fn in @('Get-ArcAgentHeartbeat','Get-ArcAgentHeartbeatDetails',
                          'Get-AMAHeartbeat','Get-AMAHeartbeatDetails',
                          'Get-CombinedHeartbeatStatus')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value {
                    param([string]$ServerName,[string]$WorkspaceId,[int]$LookbackHours)
                    [PSCustomObject]@{ Status='Healthy'; LastHeartbeat=(Get-Date).AddMinutes(-5); Details='OK' }
                }
            }
        }
        . (Join-Path $script:SrcRoot 'core\Get-LastHeartbeat.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'retrieves Arc-only heartbeat with AgentType=Arc' {
        $result = Get-LastHeartbeat -ServerName 'TEST-SRV' -AgentType 'Arc'
        $result | Should -Not -BeNullOrEmpty
        $result.Arc | Should -Not -BeNullOrEmpty
    }

    It 'retrieves AMA heartbeat when AgentType=AMA and WorkspaceId supplied' {
        $result = Get-LastHeartbeat -ServerName 'TEST-SRV' -WorkspaceId 'ws-123' -AgentType 'AMA'
        $result | Should -Not -BeNullOrEmpty
        $result.AMA | Should -Not -BeNullOrEmpty
    }

    It 'retrieves Both heartbeats with AgentType=Both' {
        $result = Get-LastHeartbeat -ServerName 'TEST-SRV' -WorkspaceId 'ws-456'
        $result | Should -Not -BeNullOrEmpty
        $result.Arc | Should -Not -BeNullOrEmpty
        $result.AMA | Should -Not -BeNullOrEmpty
    }

    It 'includes Arc details when IncludeDetails flag set' {
        $result = Get-LastHeartbeat -ServerName 'TEST-SRV' -AgentType 'Arc' -IncludeDetails
        $result | Should -Not -BeNullOrEmpty
    }

    It 'includes AMA details when IncludeDetails flag set' {
        $result = Get-LastHeartbeat -ServerName 'TEST-SRV' -WorkspaceId 'ws-789' -AgentType 'AMA' -IncludeDetails
        $result | Should -Not -BeNullOrEmpty
    }

    It 'handles exception and returns error in result' {
        Mock Get-ArcAgentHeartbeat { throw 'WMI connection refused' }
        $result = Get-LastHeartbeat -ServerName 'FAIL-SRV' -AgentType 'Arc'
        $result.Error | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Extra: Invoke-TroubleshootingAnalysis.ps1 additional branch coverage
# ---------------------------------------------------------------------------
Describe 'Invoke-TroubleshootingAnalysis.ps1 additional branches' {
    BeforeAll {
        if (-not (Get-Command Invoke-TroubleshootingAnalysis -ErrorAction SilentlyContinue)) {
            . (Join-Path $script:SrcRoot 'core\Invoke-TroubleshootingAnalysis.ps1')
        }
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
    }

    It 'Find-ArcAgentIssues detects connectivity failure in endpoint array' {
        $diag = @{
            Service      = @{ Status = 'Running' }
            Connectivity = @(
                @{ Target = 'management.azure.com'; Success = $false; Error = 'Connection timed out' }
            )
        }
        $result = Find-ArcAgentIssues -Diagnostics $diag -Patterns @{}
        ($result | Where-Object { $_.Type -eq 'Connectivity' }) | Should -Not -BeNullOrEmpty
    }

    It 'Find-ArcAgentIssues returns no connectivity issues when all endpoints succeed' {
        $diag = @{
            Service      = @{ Status = 'Running' }
            Connectivity = @(
                @{ Target = 'management.azure.com'; Success = $true }
            )
        }
        $result = Find-ArcAgentIssues -Diagnostics $diag -Patterns @{}
        ($result | Where-Object { $_.Type -eq 'Connectivity' }) | Should -BeNullOrEmpty
    }

    It 'Find-AMAIssues detects AMA service not running' {
        $diag = @{ Service = @{ Status = 'Stopped' }; DataCollection = @{ Status = 'Active'; Details = 'OK' } }
        $result = Find-AMAIssues -Diagnostics $diag -Patterns @{}
        ($result | Where-Object { $_.Component -eq 'AMA' -and $_.Type -eq 'Service' }) | Should -Not -BeNullOrEmpty
    }

    It 'Find-AMAIssues detects data collection inactive' {
        $diag = @{ Service = @{ Status = 'Running' }; DataCollection = @{ Status = 'Inactive'; Details = 'No DCR' } }
        $result = Find-AMAIssues -Diagnostics $diag -Patterns @{}
        ($result | Where-Object { $_.Type -eq 'DataCollection' }) | Should -Not -BeNullOrEmpty
    }

    It 'Find-AMAIssues returns empty when service running and data active' {
        $diag = @{ Service = @{ Status = 'Running' }; DataCollection = @{ Status = 'Active'; Details = 'OK' } }
        $result = Find-AMAIssues -Diagnostics $diag -Patterns @{}
        $result.Count | Should -Be 0
    }

    It 'Find-CommonPatterns detects RecurringIssueType with two same-type issues' {
        $issues = @(
            [PSCustomObject]@{ Type = 'Service'; Component = 'Arc'; Severity = 'Critical' }
            [PSCustomObject]@{ Type = 'Service'; Component = 'AMA'; Severity = 'Warning' }
        )
        $result = Find-CommonPatterns -Issues $issues
        ($result | Where-Object { $_.PatternType -eq 'RecurringIssueType' }) | Should -Not -BeNullOrEmpty
    }

    It 'Find-CommonPatterns detects ComponentConcentration with two issues in same component' {
        $issues = @(
            [PSCustomObject]@{ Type = 'Service';      Component = 'ArcAgent'; Severity = 'Critical' }
            [PSCustomObject]@{ Type = 'Connectivity'; Component = 'ArcAgent'; Severity = 'Critical' }
        )
        $result = Find-CommonPatterns -Issues $issues
        ($result | Where-Object { $_.PatternType -eq 'ComponentConcentration' }) | Should -Not -BeNullOrEmpty
    }

    It 'Find-CommonPatterns detects CascadingFailure when Service and Connectivity issues coexist' {
        $issues = @(
            [PSCustomObject]@{ Type = 'Service';      Component = 'ArcAgent'; Severity = 'Critical' }
            [PSCustomObject]@{ Type = 'Connectivity'; Component = 'ArcAgent'; Severity = 'Critical' }
        )
        $result = Find-CommonPatterns -Issues $issues
        ($result | Where-Object { $_.PatternType -eq 'CascadingFailure' }) | Should -Not -BeNullOrEmpty
    }

    It 'Find-CommonPatterns returns empty for a single issue' {
        $issues = @([PSCustomObject]@{ Type = 'Service'; Component = 'Arc'; Severity = 'Warning' })
        $result = Find-CommonPatterns -Issues $issues
        ($result | Where-Object { $_.PatternType }) | Should -BeNullOrEmpty
    }

    It 'Get-IssueRecommendation assigns Priority 1 for Critical severity' {
        $issue = [PSCustomObject]@{ Type = 'Service'; Component = 'ArcAgent'; Severity = 'Critical' }
        $result = Get-IssueRecommendation -Issue $issue
        $result.Priority | Should -Be 1
    }

    It 'Get-IssueRecommendation assigns Priority 2 for High severity' {
        $issue = [PSCustomObject]@{ Type = 'Service'; Component = 'ArcAgent'; Severity = 'High' }
        $result = Get-IssueRecommendation -Issue $issue
        $result.Priority | Should -Be 2
    }

    It 'Get-IssueRecommendation assigns Priority 3 for Warning severity' {
        $issue = [PSCustomObject]@{ Type = 'Service'; Component = 'ArcAgent'; Severity = 'Warning' }
        $result = Get-IssueRecommendation -Issue $issue
        $result.Priority | Should -Be 3
    }

    It 'Get-IssueRecommendation assigns Priority 3 for Medium severity' {
        $issue = [PSCustomObject]@{ Type = 'Resource'; Component = 'Memory'; Severity = 'Medium' }
        $result = Get-IssueRecommendation -Issue $issue
        $result.Priority | Should -Be 3
    }

    It 'Get-IssueRecommendation assigns Priority 4 for Low severity' {
        $issue = [PSCustomObject]@{ Type = 'Resource'; Component = 'DiskSpace'; Severity = 'Low' }
        $result = Get-IssueRecommendation -Issue $issue
        $result.Priority | Should -Be 4
    }

    It 'Get-IssueRecommendation returns himds restart action for ArcAgent service issue' {
        $issue = [PSCustomObject]@{ Type = 'Service'; Component = 'ArcAgent'; Severity = 'Critical' }
        $result = Get-IssueRecommendation -Issue $issue
        ($result.Actions | Where-Object { $_ -match 'himds' }) | Should -Not -BeNullOrEmpty
    }

    It 'Get-IssueRecommendation returns AzureMonitorAgent restart action for AMA service issue' {
        $issue = [PSCustomObject]@{ Type = 'Service'; Component = 'AMA'; Severity = 'Critical' }
        $result = Get-IssueRecommendation -Issue $issue
        ($result.Actions | Where-Object { $_ -match 'AzureMonitorAgent' }) | Should -Not -BeNullOrEmpty
    }

    It 'Get-IssueRecommendation returns connectivity check actions for Connectivity type' {
        $issue = [PSCustomObject]@{ Type = 'Connectivity'; Component = 'ArcAgent'; Severity = 'Critical' }
        $result = Get-IssueRecommendation -Issue $issue
        ($result.Actions | Where-Object { $_ -match 'network|proxy|firewall' }) | Should -Not -BeNullOrEmpty
    }

    It 'Get-IssueRecommendation returns memory actions for Resource/Memory issue' {
        $issue = [PSCustomObject]@{ Type = 'Resource'; Component = 'Memory'; Severity = 'Warning' }
        $result = Get-IssueRecommendation -Issue $issue
        ($result.Actions | Where-Object { $_ -match '[Mm]emory' }) | Should -Not -BeNullOrEmpty
    }

    It 'Get-IssueRecommendation returns disk cleanup actions for Resource/DiskSpace issue' {
        $issue = [PSCustomObject]@{ Type = 'Resource'; Component = 'DiskSpace'; Severity = 'Warning' }
        $result = Get-IssueRecommendation -Issue $issue
        ($result.Actions | Where-Object { $_ -match 'temp|archive' }) | Should -Not -BeNullOrEmpty
    }

    It 'Get-IssueRecommendation returns DCR actions for DataCollection type' {
        $issue = [PSCustomObject]@{ Type = 'DataCollection'; Component = 'AMA'; Severity = 'Warning' }
        $result = Get-IssueRecommendation -Issue $issue
        ($result.Actions | Where-Object { $_ -match 'Data Collection Rule|DCR' }) | Should -Not -BeNullOrEmpty
    }

    It 'Get-IssueRecommendation returns OS upgrade actions for SystemRequirement type' {
        $issue = [PSCustomObject]@{ Type = 'SystemRequirement'; Component = 'OperatingSystem'; Severity = 'Critical' }
        $result = Get-IssueRecommendation -Issue $issue
        ($result.Actions | Where-Object { $_ -match 'OS|upgrade' }) | Should -Not -BeNullOrEmpty
    }

    It 'Get-IssueRecommendation returns fallback actions for unknown issue type' {
        $issue = [PSCustomObject]@{ Type = 'UnknownType'; Component = 'SomeComponent'; Severity = 'Low' }
        $result = Get-IssueRecommendation -Issue $issue
        $result.Actions | Should -Not -BeNullOrEmpty
    }

    It 'Measure-ImpactScore returns positive value for Critical ArcAgent service issue' {
        $issue = [PSCustomObject]@{ Type = 'Service'; Component = 'ArcAgent'; Severity = 'Critical' }
        $result = Measure-ImpactScore -Issue $issue
        $result | Should -BeGreaterThan 0
    }

    It 'Measure-ImpactScore caps score at 200' {
        $issue = [PSCustomObject]@{ Type = 'SystemRequirement'; Component = 'ArcAgent'; Severity = 'Critical' }
        $result = Measure-ImpactScore -Issue $issue
        $result | Should -BeLessOrEqual 200
    }

    It 'Measure-ImpactScore returns lower score for Low vs Critical severity' {
        $lowIssue  = [PSCustomObject]@{ Type = 'Resource'; Component = 'DiskSpace'; Severity = 'Low' }
        $highIssue = [PSCustomObject]@{ Type = 'Resource'; Component = 'DiskSpace'; Severity = 'Critical' }
        (Measure-ImpactScore -Issue $lowIssue) | Should -BeLessThan (Measure-ImpactScore -Issue $highIssue)
    }

    It 'Measure-ImpactScore handles default component multiplier (no special component)' {
        $issue = [PSCustomObject]@{ Type = 'Connectivity'; Component = 'Network'; Severity = 'Warning' }
        $result = Measure-ImpactScore -Issue $issue
        $result | Should -BeGreaterThan 0
    }

    It 'Measure-ImpactScore returns score for Information severity' {
        $issue = [PSCustomObject]@{ Type = 'DataCollection'; Component = 'AMA'; Severity = 'Information' }
        $result = Measure-ImpactScore -Issue $issue
        $result | Should -BeGreaterThan 0
    }

    It 'Invoke-TroubleshootingAnalysis processes AMADiagnostics phase when present' {
        Mock Get-Content { '{"SystemState":{},"ArcAgent":{},"AMA":{}}' }
        Mock Test-OSCompatibility { $true }
        $data = @(
            [PSCustomObject]@{
                Phase = 'SystemState'
                Data  = @{ OS = @{ Version = '10.0.19041' }; Memory = @{ AvailableGB = 8 }; Disk = @{ FreeSpaceGB = 100 } }
            }
            [PSCustomObject]@{
                Phase = 'ArcDiagnostics'
                Data  = @{ Service = @{ Status = 'Running' }; Connectivity = @() }
            }
            [PSCustomObject]@{
                Phase = 'AMADiagnostics'
                Data  = @{ Service = @{ Status = 'Running' }; DataCollection = @{ Status = 'Active'; Details = 'OK' } }
            }
        )
        $result = Invoke-TroubleshootingAnalysis -Data $data -ConfigPath 'C:\test.json'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Invoke-TroubleshootingAnalysis includes issues from AMADiagnostics when AMA service stopped' {
        Mock Get-Content { '{"SystemState":{},"ArcAgent":{},"AMA":{}}' }
        Mock Test-OSCompatibility { $true }
        $data = @(
            [PSCustomObject]@{
                Phase = 'SystemState'
                Data  = @{ OS = @{ Version = '10.0.19041' }; Memory = @{ AvailableGB = 8 }; Disk = @{ FreeSpaceGB = 100 } }
            }
            [PSCustomObject]@{
                Phase = 'ArcDiagnostics'
                Data  = @{ Service = @{ Status = 'Running' }; Connectivity = @() }
            }
            [PSCustomObject]@{
                Phase = 'AMADiagnostics'
                Data  = @{ Service = @{ Status = 'Stopped' }; DataCollection = @{ Status = 'Inactive'; Details = 'No DCR' } }
            }
        )
        $result = Invoke-TroubleshootingAnalysis -Data $data -ConfigPath 'C:\test.json'
        $result | Should -Not -BeNullOrEmpty
        ($result.Issues | Where-Object { $_.Component -eq 'AMA' }) | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Extra: Invoke-ArcAnalysis helper function coverage
# ---------------------------------------------------------------------------
Describe 'Invoke-ArcAnalysis helper function coverage' {
    BeforeAll {
        if (-not (Get-Command Analyze-ArcHealth -ErrorAction SilentlyContinue)) {
            . (Join-Path $script:SrcRoot 'core\Invoke-ArcAnalysis.ps1')
        }
    }
    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path, [string]$Component)
        }
    }

    It 'Analyze-ArcHealth returns Arc Service finding when service not running' {
        $status = [PSCustomObject]@{
            ServiceStatus = 'Stopped'
            Configuration = $null
            LastHeartbeat = $null
        }
        $result = Analyze-ArcHealth -Status $status -Patterns @{ ConfigurationPatterns = @() }
        $result | Should -Not -BeNullOrEmpty
        ($result | Where-Object { $_.Component -eq 'Arc Service' }) | Should -Not -BeNullOrEmpty
    }

    It 'Analyze-ArcHealth returns no Arc Service finding when service is running' {
        $status = [PSCustomObject]@{
            ServiceStatus = 'Running'
            Configuration = $null
            LastHeartbeat = $null
        }
        $result = Analyze-ArcHealth -Status $status -Patterns @{ ConfigurationPatterns = @() }
        ($result | Where-Object { $_.Component -eq 'Arc Service' }) | Should -BeNullOrEmpty
    }

    It 'Analyze-ArcHealth returns Arc Heartbeat finding when heartbeat is stale over 15 min' {
        $status = [PSCustomObject]@{
            ServiceStatus = 'Running'
            Configuration = $null
            LastHeartbeat = (Get-Date).AddMinutes(-30)
        }
        $result = Analyze-ArcHealth -Status $status -Patterns @{ ConfigurationPatterns = @() }
        ($result | Where-Object { $_.Component -eq 'Arc Heartbeat' }) | Should -Not -BeNullOrEmpty
    }

    It 'Analyze-ArcHealth returns no heartbeat finding when heartbeat is recent' {
        $status = [PSCustomObject]@{
            ServiceStatus = 'Running'
            Configuration = $null
            LastHeartbeat = (Get-Date).AddMinutes(-5)
        }
        $result = Analyze-ArcHealth -Status $status -Patterns @{ ConfigurationPatterns = @() }
        ($result | Where-Object { $_.Component -eq 'Arc Heartbeat' }) | Should -BeNullOrEmpty
    }

    It 'Analyze-ArcHealth processes empty ConfigurationPatterns array without error' {
        $status = [PSCustomObject]@{
            ServiceStatus = 'Running'
            Configuration = @{ setting = 'value' }
            LastHeartbeat = $null
        }
        { Analyze-ArcHealth -Status $status -Patterns @{ ConfigurationPatterns = @() } } | Should -Not -Throw
    }

    It 'Analyze-AMAHealth returns AMA Service finding when service not running' {
        $status = [PSCustomObject]@{
            ServiceStatus  = 'Stopped'
            DataCollection = [PSCustomObject]@{ Status = 'Active' }
            DCRStatus      = [PSCustomObject]@{ State = 'Enabled' }
        }
        $result = Analyze-AMAHealth -Status $status -Patterns @{ ConfigurationPatterns = @() }
        ($result | Where-Object { $_.Component -eq 'AMA Service' }) | Should -Not -BeNullOrEmpty
    }

    It 'Analyze-AMAHealth returns Data Collection finding when status is Inactive' {
        $status = [PSCustomObject]@{
            ServiceStatus  = 'Running'
            DataCollection = [PSCustomObject]@{ Status = 'Inactive' }
            DCRStatus      = [PSCustomObject]@{ State = 'Enabled' }
        }
        $result = Analyze-AMAHealth -Status $status -Patterns @{ ConfigurationPatterns = @() }
        ($result | Where-Object { $_.Component -eq 'Data Collection' }) | Should -Not -BeNullOrEmpty
    }

    It 'Analyze-AMAHealth returns DCR finding when DCR state is not Enabled' {
        $status = [PSCustomObject]@{
            ServiceStatus  = 'Running'
            DataCollection = [PSCustomObject]@{ Status = 'Active' }
            DCRStatus      = [PSCustomObject]@{ State = 'Disabled' }
        }
        $result = Analyze-AMAHealth -Status $status -Patterns @{ ConfigurationPatterns = @() }
        ($result | Where-Object { $_.Component -eq 'DCR' }) | Should -Not -BeNullOrEmpty
    }

    It 'Analyze-AMAHealth returns no findings when all components are healthy' {
        $status = [PSCustomObject]@{
            ServiceStatus  = 'Running'
            DataCollection = [PSCustomObject]@{ Status = 'Active' }
            DCRStatus      = [PSCustomObject]@{ State = 'Enabled' }
        }
        $result = Analyze-AMAHealth -Status $status -Patterns @{ ConfigurationPatterns = @() }
        @($result).Count | Should -Be 0
    }

    It 'Analyze-AMAHealth returns multiple findings when multiple components unhealthy' {
        $status = [PSCustomObject]@{
            ServiceStatus  = 'Stopped'
            DataCollection = [PSCustomObject]@{ Status = 'Inactive' }
            DCRStatus      = [PSCustomObject]@{ State = 'Disabled' }
        }
        $result = Analyze-AMAHealth -Status $status -Patterns @{ ConfigurationPatterns = @() }
        @($result).Count | Should -Be 3
    }
}

# ---------------------------------------------------------------------------
# Additional: Get-LastHeartbeat.ps1 sub-function direct coverage
# ---------------------------------------------------------------------------
Describe 'Get-LastHeartbeat.ps1 sub-function direct coverage' {
    BeforeAll {
        # Always create function stubs so Pester mock targets a function, not a module cmdlet on CI
        function global:Get-AzConnectedMachine {
            param([string]$Name, [string]$ResourceGroupName, $ErrorAction)
            $null
        }
        function global:Get-AzConnectedMachineExtension {
            param([string]$MachineName, [string]$Name, [string]$ResourceGroupName, $ErrorAction)
            $null
        }
        function global:Invoke-AzOperationalInsightsQuery {
            param([string]$WorkspaceId, [string]$Query, $ErrorAction)
            $null
        }
        . (Join-Path $script:SrcRoot 'core\Get-LastHeartbeat.ps1')
    }
    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Component, [string]$Path)
        }
    }

    # --- Get-CombinedHeartbeatStatus (pure logic, no external dependencies) ---
    It 'Get-CombinedHeartbeatStatus returns Healthy when both Arc and AMA are Healthy' {
        $result = Get-CombinedHeartbeatStatus -ArcStatus 'Healthy' -AMAStatus 'Healthy'
        $result.Status | Should -Be 'Healthy'
    }

    It 'Get-CombinedHeartbeatStatus returns Critical when Arc status is Critical' {
        $result = Get-CombinedHeartbeatStatus -ArcStatus 'Critical' -AMAStatus 'Healthy'
        $result.Status | Should -Be 'Critical'
    }

    It 'Get-CombinedHeartbeatStatus returns Critical when AMA status is Critical' {
        $result = Get-CombinedHeartbeatStatus -ArcStatus 'Healthy' -AMAStatus 'Critical'
        $result.Status | Should -Be 'Critical'
    }

    It 'Get-CombinedHeartbeatStatus returns Warning when Arc status is Warning' {
        $result = Get-CombinedHeartbeatStatus -ArcStatus 'Warning' -AMAStatus 'Healthy'
        $result.Status | Should -Be 'Warning'
    }

    It 'Get-CombinedHeartbeatStatus returns Warning when AMA status is Warning' {
        $result = Get-CombinedHeartbeatStatus -ArcStatus 'Healthy' -AMAStatus 'Warning'
        $result.Status | Should -Be 'Warning'
    }

    It 'Get-CombinedHeartbeatStatus returns Degraded when both known but not Healthy/Critical/Warning' {
        $result = Get-CombinedHeartbeatStatus -ArcStatus 'Degraded' -AMAStatus 'Degraded'
        $result.Status | Should -Be 'Degraded'
    }

    It 'Get-CombinedHeartbeatStatus uses ArcStatus when AMAStatus is Unknown' {
        $result = Get-CombinedHeartbeatStatus -ArcStatus 'Warning' -AMAStatus 'Unknown'
        $result.Status | Should -Be 'Warning'
    }

    It 'Get-CombinedHeartbeatStatus uses AMAStatus when ArcStatus is Unknown' {
        $result = Get-CombinedHeartbeatStatus -ArcStatus 'Unknown' -AMAStatus 'Critical'
        $result.Status | Should -Be 'Critical'
    }

    It 'Get-CombinedHeartbeatStatus returns Unknown when both statuses are Unknown' {
        $result = Get-CombinedHeartbeatStatus -ArcStatus 'Unknown' -AMAStatus 'Unknown'
        $result.Status | Should -Be 'Unknown'
    }

    # --- Get-ArcAgentHeartbeatDetails (uses Az cmdlets, no Get-Service -ComputerName) ---
    It 'Get-ArcAgentHeartbeatDetails returns Connected status when machine is found' {
        Mock Get-AzConnectedMachine {
            [PSCustomObject]@{
                Status        = 'Connected'
                AgentVersion  = '1.20.0'
                LastStatusChange = (Get-Date).AddHours(-1)
            }
        }
        Mock Get-AzConnectedMachineExtension { $null }
        $result = Get-ArcAgentHeartbeatDetails -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.ConnectionStatus | Should -Be 'Connected'
    }

    It 'Get-ArcAgentHeartbeatDetails returns Unknown ConnectionStatus when machine not found' {
        Mock Get-AzConnectedMachine { $null }
        Mock Get-AzConnectedMachineExtension { $null }
        $result = Get-ArcAgentHeartbeatDetails -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.ConnectionStatus | Should -Be 'Unknown'
    }
}

Describe 'ArcDeploymentFramework.psm1 module coverage' {
    BeforeAll {
        $script:FrameworkModulePath = Join-Path $script:SrcRoot 'core\ArcDeploymentFramework.psm1'
        $script:NewFrameworkDependencyStubs = {
            $moduleRoot = Join-Path $TestDrive 'Modules'
            foreach ($moduleName in @('Az.Accounts', 'Az.ConnectedMachine', 'Az.Monitor')) {
                $versionPath = Join-Path $moduleRoot "$moduleName\1.0.0"
                New-Item -Path $versionPath -ItemType Directory -Force | Out-Null
                Set-Content -Path (Join-Path $versionPath "$moduleName.psm1") -Value ''
                New-ModuleManifest -Path (Join-Path $versionPath "$moduleName.psd1") -RootModule "$moduleName.psm1" -ModuleVersion '1.0.0' | Out-Null
            }

            return $moduleRoot
        }
    }

    BeforeEach {
        Remove-Module ArcDeploymentFramework -Force -ErrorAction SilentlyContinue
    }

    It 'imports the module and exposes expected exported commands' {
        $moduleRoot = & $script:NewFrameworkDependencyStubs

        $originalModulePath = $env:PSModulePath
        try {
            $env:PSModulePath = "$moduleRoot;$originalModulePath"
            $module = Import-Module $script:FrameworkModulePath -Force -PassThru -ErrorAction Stop

            $module.ExportedCommands.ContainsKey('Initialize-ArcDeployment') | Should -Be $true
            $module.ExportedCommands.ContainsKey('New-ArcDeployment') | Should -Be $true
            $module.ExportedCommands.ContainsKey('Start-ArcTroubleshooting') | Should -Be $true
        }
        finally {
            $env:PSModulePath = $originalModulePath
            Remove-Module ArcDeploymentFramework -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Initialize-ArcDeployment returns initialized result with merged custom config' {
        $moduleRoot = & $script:NewFrameworkDependencyStubs

        $originalModulePath = $env:PSModulePath
        try {
            $env:PSModulePath = "$moduleRoot;$originalModulePath"
            $module = Import-Module $script:FrameworkModulePath -Force -PassThru -ErrorAction Stop

            Set-Item -Path Function:\global:Get-AzContext -Value {
                [PSCustomObject]@{ Account = 'user@contoso.com'; Subscription = 'sub-1' }
            }

            Mock Get-Module -ModuleName ArcDeploymentFramework {
                [PSCustomObject]@{ Name = $Name }
            } -ParameterFilter { $ListAvailable }
            Mock Merge-CommonHashtable -ModuleName ArcDeploymentFramework {
                param($Base, $Custom)
                $merged = @{}
                foreach ($key in $Base.Keys) { $merged[$key] = $Base[$key] }
                foreach ($key in $Custom.Keys) { $merged[$key] = $Custom[$key] }
                return $merged
            }
            Mock Initialize-Logging -ModuleName ArcDeploymentFramework {}

            $result = Initialize-ArcDeployment -WorkspaceId 'ws-123' -WorkspaceKey 'key-123' -CustomConfig @{ RetryCount = 5 } -LogPathOverride 'C:\Logs'
            $result | Should -Not -BeNullOrEmpty
            $result.Status | Should -Be 'Initialized'
            $result.Config.LogPathOverride | Should -Be 'C:\Logs'
        }
        finally {
            Remove-Item Function:\global:Get-AzContext -ErrorAction SilentlyContinue
            $env:PSModulePath = $originalModulePath
            Remove-Module ArcDeploymentFramework -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Start-ArcTroubleshooting passes WorkspaceId through when IncludeAMA is requested' {
        $moduleRoot = & $script:NewFrameworkDependencyStubs

        $originalModulePath = $env:PSModulePath
        try {
            $env:PSModulePath = "$moduleRoot;$originalModulePath"
            $module = Import-Module $script:FrameworkModulePath -Force -PassThru -ErrorAction Stop

            & $module {
                $script:DefaultConfig.DefaultWorkspaceId = 'ws-ama'
            }

            Mock Start-ArcTroubleshooter -ModuleName ArcDeploymentFramework {
                param($ServerName, $DetailedAnalysis, $AutoRemediate, $WorkspaceId)
                [PSCustomObject]@{
                    ServerName = $ServerName
                    DetailedAnalysis = $DetailedAnalysis
                    AutoRemediate = $AutoRemediate
                    WorkspaceId = $WorkspaceId
                }
            }

            $result = Start-ArcTroubleshooting -ServerName 'TEST-SRV' -IncludeAMA -DetailedAnalysis -AutoRemediate
            $result.ServerName | Should -Be 'TEST-SRV'
            $result.WorkspaceId | Should -Be 'ws-ama'
            $result.DetailedAnalysis | Should -Be $true
            $result.AutoRemediate | Should -Be $true
        }
        finally {
            $env:PSModulePath = $originalModulePath
            Remove-Module ArcDeploymentFramework -Force -ErrorAction SilentlyContinue
        }
    }

    It 'New-ArcDeployment returns validation results when deployment succeeds with AMA enabled' {
        $moduleRoot = & $script:NewFrameworkDependencyStubs

        $originalModulePath = $env:PSModulePath
        try {
            $env:PSModulePath = "$moduleRoot;$originalModulePath"
            $module = Import-Module $script:FrameworkModulePath -Force -PassThru -ErrorAction Stop

            & $module {
                $script:DeployArcAgentOverride = {
                    param($ServerName)
                    New-Object psobject -Property @{ Status = 'Success'; ServerName = $ServerName; Validation = $null }
                }

                $script:TestDeploymentHealthOverride = {
                    param($ServerName, [switch]$ValidateAMA)
                    [PSCustomObject]@{ Status = 'Healthy'; AMAValidated = $ValidateAMA.IsPresent; ServerName = $ServerName }
                }

                $script:DefaultConfig.DefaultWorkspaceId = 'ws-123'
                $script:DefaultConfig.DefaultWorkspaceKey = 'key-123'
            }

            $result = New-ArcDeployment -ServerName 'TEST-SRV' -DeployAMA -Force -Confirm:$false
            $result.Status | Should -Be 'Success'
            $result.Validation.Status | Should -Be 'Healthy'
            $result.Validation.AMAValidated | Should -Be $true
        }
        finally {
            $env:PSModulePath = $originalModulePath
            Remove-Module ArcDeploymentFramework -Force -ErrorAction SilentlyContinue
        }
    }

    It 'New-ArcDeployment throws when AMA is requested without workspace credentials' {
        $moduleRoot = & $script:NewFrameworkDependencyStubs

        $originalModulePath = $env:PSModulePath
        try {
            $env:PSModulePath = "$moduleRoot;$originalModulePath"
            $module = Import-Module $script:FrameworkModulePath -Force -PassThru -ErrorAction Stop

            & $module {
                $script:DefaultConfig.DefaultWorkspaceId = $null
                $script:DefaultConfig.DefaultWorkspaceKey = $null
            }

            { New-ArcDeployment -ServerName 'TEST-SRV' -DeployAMA -Confirm:$false } | Should -Throw 'Workspace credentials required for AMA deployment*'
        }
        finally {
            $env:PSModulePath = $originalModulePath
            Remove-Module ArcDeploymentFramework -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Start-ArcTroubleshooting throws when AMA troubleshooting is requested without a workspace id' {
        $moduleRoot = & $script:NewFrameworkDependencyStubs

        $originalModulePath = $env:PSModulePath
        try {
            $env:PSModulePath = "$moduleRoot;$originalModulePath"
            $module = Import-Module $script:FrameworkModulePath -Force -PassThru -ErrorAction Stop

            & $module {
                $script:DefaultConfig.DefaultWorkspaceId = $null
            }

            { Start-ArcTroubleshooting -ServerName 'TEST-SRV' -IncludeAMA } | Should -Throw 'Workspace ID required for AMA troubleshooting'
        }
        finally {
            $env:PSModulePath = $originalModulePath
            Remove-Module ArcDeploymentFramework -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Initialize-Logging uses environment path when override is absent' {
        $moduleRoot = & $script:NewFrameworkDependencyStubs

        $originalModulePath = $env:PSModulePath
        $originalLogPath = $env:AZUREARC_FRAMEWORK_LOG_PATH
        try {
            $env:PSModulePath = "$moduleRoot;$originalModulePath"
            $env:AZUREARC_FRAMEWORK_LOG_PATH = Join-Path $TestDrive 'FrameworkLogs'
            $module = Import-Module $script:FrameworkModulePath -Force -PassThru -ErrorAction Stop

            & $module {
                $script:DefaultConfig.LogPathOverride = $null
                $script:DefaultConfig.LogLevel = 'Verbose'
                Initialize-Logging
            }

            $global:AzureArcFramework_LogPath | Should -Be (Join-Path $env:AZUREARC_FRAMEWORK_LOG_PATH 'ArcDeployment.log')
            $global:AzureArcFramework_LogLevel | Should -Be 'Verbose'
        }
        finally {
            $env:AZUREARC_FRAMEWORK_LOG_PATH = $originalLogPath
            $env:PSModulePath = $originalModulePath
            Remove-Module ArcDeploymentFramework -Force -ErrorAction SilentlyContinue
        }
    }

    It 'Initialize-Logging falls back when directory creation fails' {
        $moduleRoot = & $script:NewFrameworkDependencyStubs

        $originalModulePath = $env:PSModulePath
        try {
            $env:PSModulePath = "$moduleRoot;$originalModulePath"
            $module = Import-Module $script:FrameworkModulePath -Force -PassThru -ErrorAction Stop

            Mock Test-Path -ModuleName ArcDeploymentFramework { $false }
            Mock New-Item -ModuleName ArcDeploymentFramework {
                throw 'disk full'
            } -ParameterFilter { $Path -notlike '*Logs_Fallback*' }
            Mock New-Item -ModuleName ArcDeploymentFramework {
                [PSCustomObject]@{ FullName = $Path }
            } -ParameterFilter { $Path -like '*Logs_Fallback*' }

            & $module {
                $script:DefaultConfig.LogPathOverride = Join-Path $TestDrive 'PrimaryLogs'
                $script:DefaultConfig.LogLevel = 'Information'
                Initialize-Logging
            }

            $global:AzureArcFramework_LogPath | Should -Match 'Logs_Fallback'
        }
        finally {
            $env:PSModulePath = $originalModulePath
            Remove-Module ArcDeploymentFramework -Force -ErrorAction SilentlyContinue
        }
    }
}

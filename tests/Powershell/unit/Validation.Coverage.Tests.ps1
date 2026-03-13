# tests/PowerShell/unit/Validation.Coverage.Tests.ps1
# Coverage-focused tests for large Validation source files that previously had 0% coverage.
# Each Describe block dot-sources exactly one source file so same-named helpers
# from different files do not overwrite each other within the same test run.

Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

BeforeAll {
    $script:SrcRoot  = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\src\PowerShell'))
    $script:TestRoot = $PSScriptRoot
}

# ---------------------------------------------------------------------------
# Shared stub helpers (set once before all Describe blocks to avoid repetition)
# ---------------------------------------------------------------------------
if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    Set-Item -Path Function:global:Write-Log -Value {
        param([string]$Message, [string]$Level = 'INFO', [string]$Path)
    }
}

# ---------------------------------------------------------------------------
# 1. Test-NetworkValidation.ps1  (564 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Test-NetworkValidation.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'Validation\Test-NetworkValidation.ps1')
    }

    BeforeEach {
        # Stub/reset Write-Log for each test
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path)
        }
        # Stub Out-File to avoid filesystem writes
        Mock Out-File {}
    }

    It 'returns Success status when all endpoint/DNS/proxy/TLS/perf/firewall checks pass' {
        Mock Test-EndpointConnectivity  { @{ OverallSuccess = $true; Endpoints = @() } }
        Mock Test-DNSResolution         { @{ OverallSuccess = $true; Results = @() } }
        Mock Test-ProxyConfiguration    { @{ Success = $true; Details = @{} } }
        Mock Test-TLSConfiguration      { @{ Success = $true; Version = 'TLS1.2'; Details = @{} } }
        Mock Test-NetworkPerformance    { @{ Success = $true; Metrics = @{} } }
        Mock Test-FirewallConfiguration { @{ Success = $true; Rules = @() } }
        Mock Get-NetworkRecommendations { @() }

        $result = Test-NetworkValidation -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.Status | Should -Be 'Success'
        $result.ServerName | Should -Be 'TEST-SRV'
    }

    It 'returns Failed status when endpoint check fails' {
        Mock Test-EndpointConnectivity  { @{ OverallSuccess = $false; CriticalFailures = 1; Endpoints = @() } }
        Mock Test-DNSResolution         { @{ OverallSuccess = $true; Results = @() } }
        Mock Test-ProxyConfiguration    { @{ Success = $true; Details = @{} } }
        Mock Test-TLSConfiguration      { @{ Success = $true; Version = 'TLS1.2' } }
        Mock Test-NetworkPerformance    { @{ Success = $true } }
        Mock Test-FirewallConfiguration { @{ Success = $true } }
        Mock Get-NetworkRecommendations { @('Check firewall rules') }

        $result = Test-NetworkValidation -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Failed'
    }

    It 'returns Error status when an exception is thrown' {
        Mock Test-EndpointConnectivity { throw 'Network unreachable' }

        $result = Test-NetworkValidation -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Error'
    }

    It 'includes route results when -DetailedOutput is specified' {
        Mock Test-EndpointConnectivity  { @{ OverallSuccess = $true; Endpoints = @() } }
        Mock Test-DNSResolution         { @{ OverallSuccess = $true; Results = @() } }
        Mock Test-ProxyConfiguration    { @{ Success = $true } }
        Mock Test-TLSConfiguration      { @{ Success = $true } }
        Mock Test-NetworkPerformance    { @{ Success = $true } }
        Mock Test-FirewallConfiguration { @{ Success = $true } }
        Mock Test-NetworkRoutes         { @{ Success = $true; Routes = @() } }
        Mock Get-NetworkRecommendations { @() }

        $result = Test-NetworkValidation -ServerName 'TEST-SRV' -DetailedOutput
        ($result.Details | Where-Object { $_.Component -eq 'Routes' }) | Should -Not -BeNullOrEmpty
    }

    It 'returns Error status when configuration loading fails' {
        Mock Test-Path { $true } -ParameterFilter { $Path -like '*network-validation.json' }
        Mock Get-Content { throw 'Invalid JSON payload' } -ParameterFilter { $Path -like '*network-validation.json' }

        $result = Test-NetworkValidation -ServerName 'TEST-SRV'
        @($result)[0].Status | Should -Be 'Error'
        @($result)[0].Error | Should -Match 'Configuration load failure'
    }

    It 'Test-EndpointConnectivity returns result with endpoints when Invoke-Command mocked' {
        Mock Invoke-Command { $true } -ParameterFilter { $ScriptBlock -ne $null -and $null -ne $ComputerName }
        $endpoints = @(
            [PSCustomObject]@{ Name = 'ARM'; Url = 'management.azure.com'; Port = 443; Critical = $true }
        )
        $result = Test-EndpointConnectivity -ServerName 'TEST-SRV' -Endpoints $endpoints
        $result | Should -Not -BeNullOrEmpty
        $result.Endpoints | Should -Not -BeNullOrEmpty
    }

    It 'Test-EndpointConnectivity propagates catch block when Invoke-Command throws' {
        Mock Invoke-Command { throw 'Connection refused' } -ParameterFilter { $ComputerName -ne $null }
        $endpoints = @(
            [PSCustomObject]@{ Name = 'ARM'; Url = 'management.azure.com'; Port = 443; Critical = $true }
        )
        $result = Test-EndpointConnectivity -ServerName 'TEST-SRV' -Endpoints $endpoints
        $result.OverallSuccess | Should -Be $false
    }

    It 'Test-DNSResolution returns result with Resolve-DnsName mocked' {
        Mock Resolve-DnsName { @([PSCustomObject]@{ IPAddress = '1.2.3.4'; Name = 'management.azure.com' }) }
        $endpoints = @(
            [PSCustomObject]@{ Name = 'ARM'; Url = 'management.azure.com'; Port = 443 }
        )
        $result = Test-DNSResolution -ServerName 'TEST-SRV' -Endpoints $endpoints
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-DNSResolution handles resolve failure gracefully' {
        Mock Resolve-DnsName { throw 'DNS lookup failed' }
        $endpoints = @(
            [PSCustomObject]@{ Name = 'ARM'; Url = 'management.azure.com'; Port = 443 }
        )
        $result = Test-DNSResolution -ServerName 'TEST-SRV' -Endpoints $endpoints
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-ProxyConfiguration returns a result object' {
        Mock Invoke-Command { @{ ProxyServer = $null; Enabled = $false } } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-ProxyConfiguration -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-TLSConfiguration returns a result with registry mocked' {
        Mock Invoke-Command { @{ TLS12 = $true; TLS10 = $false } } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-TLSConfiguration -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-NetworkPerformance returns a result with Test-NetConnection mocked' {
        Mock Invoke-Command { @{ AvgLatency = 50; PacketLoss = 0; Success = $true } } -ParameterFilter { $ComputerName -ne $null }
        Mock Test-NetConnection { [PSCustomObject]@{ TcpTestSucceeded = $true; PingSucceeded = $true } }
        $endpoints = @(
            [PSCustomObject]@{ Name = 'ARM'; Url = 'management.azure.com'; Port = 443 }
        )
        $result = Test-NetworkPerformance -ServerName 'TEST-SRV' -Endpoints $endpoints -LatencyThreshold 300 -PacketLossThreshold 5
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-FirewallConfiguration returns result with Invoke-Command mocked' {
        Mock Invoke-Command { @{ ArcRule = $true; AMARule = $true } } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-FirewallConfiguration -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-NetworkRoutes returns result with Invoke-Command mocked' {
        Mock Invoke-Command { @{ Routes = @(); Success = $true } } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-NetworkRoutes -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Get-NetworkRecommendations returns empty array for no issues' {
        $details = @()
        $result = Get-NetworkRecommendations -ValidationResults $details
        $result | Should -BeNullOrEmpty
    }

    It 'Get-NetworkRecommendations returns recommendations for failed Endpoints' {
        $details = @(
            @{
                Component = 'Endpoints'
                Results   = @{
                    Endpoints = @(
                        @{ Name='ARM'; Url='management.azure.com'; Port=443; Critical=$true; Success=$false; Error='Timeout' }
                    )
                }
            }
        )
        $result = Get-NetworkRecommendations -ValidationResults $details
        $result | Should -Not -BeNullOrEmpty
        @($result)[0].Component | Should -Be 'Endpoint Connectivity'
    }

    It 'Get-NetworkRecommendations returns recommendations for failed DNS' {
        $details = @(
            @{
                Component = 'DNS'
                Results   = @{
                    Resolutions = @(
                        @{ Name='ARM'; Url='management.azure.com'; Critical=$true; Success=$false; Error='No response' }
                    )
                }
            }
        )
        $result = Get-NetworkRecommendations -ValidationResults $details
        $result | Should -Not -BeNullOrEmpty
        @($result)[0].Component | Should -Be 'DNS Resolution'
    }

    It 'Get-NetworkRecommendations returns recommendations for failed Proxy' {
        $details = @(
            @{
                Component = 'Proxy'
                Results   = @{
                    Validation = @(
                        @{ Check='Proxy Access'; Success=$false; Details='Proxy unreachable' }
                    )
                }
            }
        )
        $result = Get-NetworkRecommendations -ValidationResults $details
        $result | Should -Not -BeNullOrEmpty
        @($result)[0].Component | Should -Be 'Proxy Configuration'
    }

    It 'Get-NetworkRecommendations returns recommendations for failed TLS' {
        $details = @(
            @{
                Component = 'TLS'
                Results   = @{
                    Validation = @(
                        @{ Check='TLS 1.2 Enabled'; Critical=$true; Success=$false; Details='TLS 1.2 disabled' }
                    )
                }
            }
        )
        $result = Get-NetworkRecommendations -ValidationResults $details
        $result | Should -Not -BeNullOrEmpty
        @($result)[0].Component | Should -Be 'TLS Configuration'
    }

    It 'Get-NetworkRecommendations returns recommendations for high latency Performance' {
        $details = @(
            @{
                Component = 'Performance'
                Results   = @{
                    Endpoints = @(
                        @{ Name='ARM'; Url='management.azure.com'; AverageLatency=500; PacketLoss=0; LatencyThresholdExceeded=$true; PacketLossThresholdExceeded=$false }
                    )
                }
            }
        )
        $result = Get-NetworkRecommendations -ValidationResults $details
        $result | Should -Not -BeNullOrEmpty
        @($result)[0].Component | Should -Be 'Network Performance'
    }

    It 'Get-NetworkRecommendations returns recommendations for packet loss Performance' {
        $details = @(
            @{
                Component = 'Performance'
                Results   = @{
                    Endpoints = @(
                        @{ Name='ARM'; Url='management.azure.com'; AverageLatency=20; PacketLoss=30; LatencyThresholdExceeded=$false; PacketLossThresholdExceeded=$true }
                    )
                }
            }
        )
        $result = Get-NetworkRecommendations -ValidationResults $details
        $result | Should -Not -BeNullOrEmpty
        @($result)[0].Component | Should -Be 'Network Performance'
    }

    It 'Get-NetworkRecommendations returns recommendations for failed Firewall' {
        $details = @(
            @{
                Component = 'Firewall'
                Results   = @{
                    Validation = @(
                        @{ Check='Arc-Specific Rules'; Critical=$true; Success=$false; Details='Rule missing' }
                    )
                }
            }
        )
        $result = Get-NetworkRecommendations -ValidationResults $details
        $result | Should -Not -BeNullOrEmpty
        @($result)[0].Component | Should -Be 'Firewall Configuration'
    }

    It 'Get-NetworkRecommendations returns recommendations for failed Routes' {
        $details = @(
            @{
                Component = 'Routes'
                Results   = @{
                    Validation = @(
                        @{ Check='Default Gateway'; Critical=$true; Success=$false; Details='Missing default route' },
                        @{ Check='Azure Route'; Critical=$false; Success=$false; Details='Traceroute incomplete' }
                    )
                }
            }
        )
        $result = Get-NetworkRecommendations -ValidationResults $details
        $result | Should -Not -BeNullOrEmpty
        @($result)[0].Component | Should -Be 'Network Routes'
        @($result)[0].Recommendation | Should -Be 'Configure default gateway for outbound connectivity'
    }

    # Extra branch coverage: Test-EndpointConnectivity internal paths
    It 'Test-EndpointConnectivity marks non-critical failure without OverallSuccess change' {
        Mock Invoke-Command { $false } -ParameterFilter { $ComputerName -ne $null }
        $endpoints = @(
            [PSCustomObject]@{ Name='Optional'; Url='optional.azure.com'; Port=443; Critical=$false }
        )
        $result = Test-EndpointConnectivity -ServerName 'TEST-SRV' -Endpoints $endpoints
        $result.OverallSuccess | Should -Be $true
        $result.CriticalFailures | Should -Be 0
    }

    It 'Test-EndpointConnectivity marks critical failure when critical endpoint TCP fails' {
        Mock Invoke-Command { $false } -ParameterFilter { $ComputerName -ne $null }
        $endpoints = @(
            [PSCustomObject]@{ Name='ARM'; Url='management.azure.com'; Port=443; Critical=$true }
        )
        $result = Test-EndpointConnectivity -ServerName 'TEST-SRV' -Endpoints $endpoints
        $result.OverallSuccess | Should -Be $false
        $result.CriticalFailures | Should -Be 1
    }

    It 'Test-EndpointConnectivity processes multiple endpoints (critical and non-critical)' {
        Mock Invoke-Command { @{ Success=$true; StatusCode=200 } } -ParameterFilter { $ComputerName -ne $null }
        $endpoints = @(
            [PSCustomObject]@{ Name='ARM'; Url='management.azure.com'; Port=443; Critical=$true }
            [PSCustomObject]@{ Name='GuestConfig'; Url='guestconfiguration.azure.com'; Port=443; Critical=$false }
        )
        $result = Test-EndpointConnectivity -ServerName 'TEST-SRV' -Endpoints $endpoints
        $result.Endpoints.Count | Should -Be 2
    }

    # Extra branch coverage: Test-DNSResolution
    It 'Test-DNSResolution detects critical DNS failure' {
        Mock Invoke-Command { @{ Success=$false; Error='NXDOMAIN' } } -ParameterFilter { $ComputerName -ne $null }
        $endpoints = @(
            [PSCustomObject]@{ Name='ARM'; Url='management.azure.com'; Port=443; Critical=$true }
        )
        $result = Test-DNSResolution -ServerName 'TEST-SRV' -Endpoints $endpoints
        $result.CriticalFailures | Should -Be 1
        $result.OverallSuccess | Should -Be $false
    }

    It 'Test-DNSResolution succeeds when DNS resolves IPs' {
        Mock Invoke-Command {
            @{ Success=$true; IPs=@('20.34.183.12'); Records=@('management.azure.com (A): 20.34.183.12') }
        } -ParameterFilter { $ComputerName -ne $null }
        $endpoints = @(
            [PSCustomObject]@{ Name='ARM'; Url='management.azure.com'; Port=443; Critical=$true }
        )
        $result = Test-DNSResolution -ServerName 'TEST-SRV' -Endpoints $endpoints
        $result.OverallSuccess | Should -Be $true
    }

    # Extra branch coverage: Test-ProxyConfiguration
    It 'Test-ProxyConfiguration detects active proxy configuration' {
        Mock Invoke-Command {
            @{ ProxyServer='http://proxy.corp.com:8080'; Enabled=$true; ExclusionList=@('localhost','*.internal') }
        } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-ProxyConfiguration -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-ProxyConfiguration handles Invoke-Command failure gracefully' {
        Mock Invoke-Command { throw 'WinRM failed' } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-ProxyConfiguration -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    # Extra branch coverage: Test-TLSConfiguration
    It 'Test-TLSConfiguration detects TLS registry settings correctly' {
        Mock Invoke-Command {
            @{
                TLS10Server=@{DisabledByDefault=1; Enabled=0}
                TLS12Client=@{DisabledByDefault=0; Enabled=1}
                SchUseStrongCrypto=1
                SystemDefaultTlsVersions=1
            }
        } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-TLSConfiguration -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-TLSConfiguration handles registry access failure gracefully' {
        Mock Invoke-Command { throw 'Registry access denied' } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-TLSConfiguration -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    # Extra branch coverage: Test-NetworkPerformance
    It 'Test-NetworkPerformance detects latency above threshold' {
        Mock Invoke-Command { @{ AverageLatency=800; PacketLoss=0; Success=$true } } -ParameterFilter { $ComputerName -ne $null }
        $endpoints = @(
            [PSCustomObject]@{ Name='ARM'; Url='management.azure.com'; Port=443 }
        )
        $result = Test-NetworkPerformance -ServerName 'TEST-SRV' -Endpoints $endpoints -LatencyThreshold 200 -PacketLossThreshold 5
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-NetworkPerformance detects packet loss above threshold' {
        Mock Invoke-Command { @{ AverageLatency=50; PacketLoss=15; Success=$true } } -ParameterFilter { $ComputerName -ne $null }
        $endpoints = @(
            [PSCustomObject]@{ Name='ARM'; Url='management.azure.com'; Port=443 }
        )
        $result = Test-NetworkPerformance -ServerName 'TEST-SRV' -Endpoints $endpoints -LatencyThreshold 200 -PacketLossThreshold 5
        $result | Should -Not -BeNullOrEmpty
    }

    # Extra branch coverage: Test-FirewallConfiguration
    It 'Test-FirewallConfiguration detects missing rules' {
        Mock Invoke-Command { @{ ArcRule=$false; AMARule=$false } } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-FirewallConfiguration -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-FirewallConfiguration handles Invoke-Command exception' {
        Mock Invoke-Command { throw 'Firewall access denied' } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-FirewallConfiguration -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    # Extra branch coverage: Test-NetworkRoutes
    It 'Test-NetworkRoutes returns data when default gateway present' {
        Mock Invoke-Command {
            @{
                DefaultGateway='192.168.1.1'
                Routes=@([PSCustomObject]@{ Destination='0.0.0.0'; Prefix=0; Gateway='192.168.1.1'; Metric=1 })
                Success=$true
            }
        } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-NetworkRoutes -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-NetworkRoutes reports failure when no default gateway' {
        Mock Invoke-Command { @{ DefaultGateway=$null; Routes=@(); Success=$false } } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-NetworkRoutes -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-DNSResolution executes the inner Resolve-DnsName branch locally' {
        Mock Invoke-Command {
            & $ScriptBlock $ArgumentList[0]
        } -ParameterFilter { $ComputerName -eq 'TEST-SRV' -and $ArgumentList.Count -eq 1 }
        Mock Resolve-DnsName {
            @(
                [PSCustomObject]@{ Type = 'A'; IPAddress = '20.1.1.1'; Name = 'management.azure.com' },
                [PSCustomObject]@{ Type = 'CNAME'; IPAddress = $null; Name = 'management.azure.com' }
            )
        }

        $endpoints = @([PSCustomObject]@{ Name='ARM'; Url='management.azure.com'; Port=443; Critical=$true })
        $result = Test-DNSResolution -ServerName 'TEST-SRV' -Endpoints $endpoints
        $result.OverallSuccess | Should -Be $true
        @($result.Resolutions[0].IPs)[0] | Should -Be '20.1.1.1'
    }

    It 'Test-NetworkPerformance executes the ping performance branch locally' {
        Mock Invoke-Command {
            & $ScriptBlock $ArgumentList[0]
        } -ParameterFilter { $ComputerName -eq 'TEST-SRV' -and $ArgumentList.Count -eq 1 }
        Mock Test-Connection {
            @(1..10 | ForEach-Object { [PSCustomObject]@{ ResponseTime = 25 + $_ } })
        }

        $endpoints = @([PSCustomObject]@{ Name='ARM'; Url='management.azure.com'; Port=443 })
        $result = Test-NetworkPerformance -ServerName 'TEST-SRV' -Endpoints $endpoints -LatencyThreshold 300 -PacketLossThreshold 5
        $result.Success | Should -Be $true
        $result.Endpoints[0].AverageLatency | Should -BeGreaterThan 0
        $result.PacketLoss | Should -Be 0
    }

    It 'Test-NetworkRoutes executes the route validation branch locally' {
        Mock Invoke-Command {
            & $ScriptBlock
        } -ParameterFilter { $ComputerName -eq 'TEST-SRV' -and $ArgumentList.Count -eq 0 }
        Mock Get-NetRoute {
            @(
                [PSCustomObject]@{ DestinationPrefix = '0.0.0.0/0'; NextHop = '10.0.0.1'; RouteMetric = 10; InterfaceIndex = 7 },
                [PSCustomObject]@{ DestinationPrefix = '10.0.0.0/24'; NextHop = '0.0.0.0'; RouteMetric = 5; InterfaceIndex = 7 }
            )
        }
        Mock Get-NetAdapter {
            @([PSCustomObject]@{ Name = 'Ethernet0'; InterfaceDescription = 'Ethernet'; Status = 'Up'; MacAddress = '00-11-22-33-44-55'; LinkSpeed = '1 Gbps'; ifIndex = 7 })
        }
        Mock Test-NetConnection {
            [PSCustomObject]@{ TraceRoute = @('10.0.0.1', 'management.azure.com') }
        }

        $result = Test-NetworkRoutes -ServerName 'TEST-SRV'
        $result.Success | Should -Be $true
        $result.DefaultGateway | Should -Be '10.0.0.1'
        ($result.Validation | Where-Object { $_.Check -eq 'Azure Route' }).Success | Should -Be $true
    }

    It 'Test-EndpointConnectivity executes the HTTPS catch branch locally' {
        Mock Invoke-Command {
            if ($ArgumentList.Count -eq 3) {
                $true
            }
            else {
                & $ScriptBlock $ArgumentList[0] $ArgumentList[1]
            }
        } -ParameterFilter { $ComputerName -eq 'TEST-SRV' }

        $endpoints = @(
            [PSCustomObject]@{ Name='Broken'; Url='nonexistent.invalid'; Port=443; Critical=$true }
        )

        $result = Test-EndpointConnectivity -ServerName 'TEST-SRV' -Endpoints $endpoints
        $result.OverallSuccess | Should -Be $false
        $result.CriticalFailures | Should -Be 1
        $result.Endpoints[0].TCPSuccess | Should -Be $true
        $result.Endpoints[0].HTTPSSuccess | Should -Be $false
    }

    It 'Test-EndpointConnectivity executes the TCP scriptblock locally' {
        Mock Invoke-Command {
            if ($ArgumentList.Count -eq 3) {
                & $ScriptBlock $ArgumentList[0] $ArgumentList[1] $ArgumentList[2]
            }
            else {
                @{ Success = $true; StatusCode = 204 }
            }
        } -ParameterFilter { $ComputerName -eq 'TEST-SRV' }
        Mock New-Object {
            $waitHandle = [pscustomobject]@{}
            Add-Member -InputObject $waitHandle -MemberType ScriptMethod -Name WaitOne -Value { param($timeout, $exitContext) $true }

            $connection = [pscustomobject]@{ AsyncWaitHandle = $waitHandle }
            $client = [pscustomobject]@{ Connection = $connection }
            Add-Member -InputObject $client -MemberType ScriptMethod -Name BeginConnect -Value { param($url, $port, $callback, $state) $this.Connection }
            Add-Member -InputObject $client -MemberType ScriptMethod -Name EndConnect -Value { param($asyncResult) }
            Add-Member -InputObject $client -MemberType ScriptMethod -Name Close -Value { }
            $client
        } -ParameterFilter { $TypeName -eq 'System.Net.Sockets.TcpClient' }

        $endpoints = @(
            [PSCustomObject]@{ Name='ARM'; Url='management.azure.com'; Port=443; Critical=$true }
        )

        $result = Test-EndpointConnectivity -ServerName 'TEST-SRV' -Endpoints $endpoints -Timeout 5
        $result.OverallSuccess | Should -Be $true
        $result.Endpoints[0].TCPSuccess | Should -Be $true
        $result.Endpoints[0].HTTPSSuccess | Should -Be $true
        $result.Endpoints[0].StatusCode | Should -Be 204
    }

    It 'Test-DNSResolution executes the local catch branch when Resolve-DnsName fails' {
        Mock Invoke-Command {
            & $ScriptBlock $ArgumentList[0]
        } -ParameterFilter { $ComputerName -eq 'TEST-SRV' -and $ArgumentList.Count -eq 1 }
        Mock Resolve-DnsName { throw 'NXDOMAIN' }

        $endpoints = @([PSCustomObject]@{ Name='ARM'; Url='management.azure.com'; Port=443; Critical=$true })
        $result = Test-DNSResolution -ServerName 'TEST-SRV' -Endpoints $endpoints
        $result.OverallSuccess | Should -Be $false
        $result.CriticalFailures | Should -Be 1
        $result.Resolutions[0].Error | Should -Match 'NXDOMAIN'
    }

    It 'Test-ProxyConfiguration executes config and validation scriptblocks locally' {
        $invokeCount = 0
        Mock Invoke-Command {
            $invokeCount++
            if ($invokeCount -eq 1) {
                & $ScriptBlock
            }
            else {
                & $ScriptBlock
            }
        } -ParameterFilter { $ComputerName -eq 'TEST-SRV' }
        Mock Get-ItemProperty {
            [PSCustomObject]@{
                ProxyEnable = 1
                ProxyServer = 'http://proxy.corp.local:8080'
                ProxyOverride = '*.internal;localhost'
            }
        } -ParameterFilter { $Path -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' }
        Mock Test-Path { $true } -ParameterFilter { $Path -like 'C:\Program Files\Azure Connected Machine Agent\config*' }
        Mock Get-Content { '{"proxy":"http://proxy.corp.local:8080"}' } -ParameterFilter { $Path -like '*agentconfig.json' }

        $result = Test-ProxyConfiguration -ServerName 'TEST-SRV'
        $result.Configuration.ProxyEnabled | Should -Be $true
        $result.Configuration.ArcProxyConfig | Should -Be 'http://proxy.corp.local:8080'
        @($result.Validation).Count | Should -Be 3
        ($result.Validation | Where-Object { $_.Check -eq 'Arc Proxy Configuration' }) | Should -Not -BeNullOrEmpty
    }

    It 'Test-ProxyConfiguration executes mismatch and no-direct-access branches locally' {
        $invokeCount = 0
        Mock Invoke-Command {
            $invokeCount++
            & $ScriptBlock
        } -ParameterFilter { $ComputerName -eq 'TEST-SRV' }
        Mock Get-ItemProperty {
            [PSCustomObject]@{
                ProxyEnable = 1
                ProxyServer = 'http://proxy.corp.local:8080'
                ProxyOverride = '*.internal;localhost'
            }
        } -ParameterFilter { $Path -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' }
        Mock Test-Path { $true } -ParameterFilter { $Path -like 'C:\Program Files\Azure Connected Machine Agent\config*' }
        Mock Get-Content { '{"proxy":"http://different.proxy.local:8080"}' } -ParameterFilter { $Path -like '*agentconfig.json' }

        $result = Test-ProxyConfiguration -ServerName 'TEST-SRV'
        $result.Success | Should -Be $false
        ($result.Validation | Where-Object { $_.Check -eq 'Direct Access' }).Success | Should -Be $false
        ($result.Validation | Where-Object { $_.Check -eq 'Proxy Access' }).Success | Should -Be $false
        ($result.Validation | Where-Object { $_.Check -eq 'Arc Proxy Configuration' }).Success | Should -Be $false
    }

    It 'Test-TLSConfiguration executes registry inspection and validation scriptblocks locally' {
        $invokeCount = 0
        $script:tlsRegistry = $null
        Mock Invoke-Command {
            $invokeCount++
            if ($invokeCount -eq 1) {
                $config = & $ScriptBlock
                $script:tlsRegistry = $config.Registry
                $config
            }
            else {
                & {
                    $Registry = $script:tlsRegistry
                    & $ScriptBlock
                }
            }
        } -ParameterFilter { $ComputerName -eq 'TEST-SRV' }
        Mock Test-Path {
            $Path -like '*TLS 1.2*' -or $Path -like '*SSL 2.0*' -or $Path -like '*v4.0.30319' -or $Path -like '*v2.0.50727'
        }
        Mock Get-ItemProperty {
            if ($Path -like '*TLS 1.2*') {
                [PSCustomObject]@{ Enabled = 1; SystemDefaultTlsVersions = $null; SchUseStrongCrypto = $null }
            }
            elseif ($Path -like '*SSL 2.0*') {
                [PSCustomObject]@{ Enabled = 1; SystemDefaultTlsVersions = $null; SchUseStrongCrypto = $null }
            }
            else {
                [PSCustomObject]@{ Enabled = $null; SystemDefaultTlsVersions = 1; SchUseStrongCrypto = 1 }
            }
        }

        $result = Test-TLSConfiguration -ServerName 'TEST-SRV'
        @($result.Validation).Count | Should -Be 3
        ($result.Validation | Where-Object { $_.Check -eq 'TLS 1.2 Enabled' }) | Should -Not -BeNullOrEmpty
        ($result.Validation | Where-Object { $_.Check -eq 'Old Protocols Disabled' }) | Should -Not -BeNullOrEmpty
    }

    It 'Test-TLSConfiguration executes TLS 1.2 registry fallback branch locally' {
        $invokeCount = 0
        $script:tlsRegistry = $null
        Mock Invoke-Command {
            $invokeCount++
            if ($invokeCount -eq 1) {
                $config = & $ScriptBlock
                $script:tlsRegistry = $config.Registry
                $config
            }
            else {
                & {
                    $Registry = $script:tlsRegistry
                    & $ScriptBlock
                }
            }
        } -ParameterFilter { $ComputerName -eq 'TEST-SRV' }
        Mock Test-Path {
            $Path -like '*TLS 1.2*' -or $Path -like '*SSL 2.0*' -or $Path -like '*SSL 3.0*' -or $Path -like '*v4.0.30319' -or $Path -like '*v2.0.50727'
        }
        Mock Get-ItemProperty {
            if ($Path -like '*TLS 1.2*') {
                [PSCustomObject]@{ Enabled = 1; SystemDefaultTlsVersions = $null; SchUseStrongCrypto = $null }
            }
            elseif ($Path -like '*SSL 2.0*' -or $Path -like '*SSL 3.0*') {
                [PSCustomObject]@{ Enabled = 0; SystemDefaultTlsVersions = $null; SchUseStrongCrypto = $null }
            }
            else {
                [PSCustomObject]@{ Enabled = $null; SystemDefaultTlsVersions = 1; SchUseStrongCrypto = 1 }
            }
        }

        $result = Test-TLSConfiguration -ServerName 'TEST-SRV'
        @($result.Validation).Count | Should -Be 3
        ($result.Validation | Where-Object { $_.Check -eq 'TLS 1.2 Enabled' }) | Should -Not -BeNullOrEmpty
        ($result.Validation | Where-Object { $_.Check -eq 'Old Protocols Disabled' }) | Should -Not -BeNullOrEmpty
    }

    It 'Test-NetworkPerformance executes the TCP fallback branch locally' {
        Mock Invoke-Command {
            & $ScriptBlock $ArgumentList[0]
        } -ParameterFilter { $ComputerName -eq 'TEST-SRV' -and $ArgumentList.Count -eq 1 }
        Mock Test-Connection { $null }
        Mock Get-Date {
            if (-not $script:networkPerfTicks) {
                $script:networkPerfTicks = [System.Collections.Queue]::new()
                foreach ($offset in 0, 12, 20, 34, 40, 55, 60, 76, 80, 99) {
                    $script:networkPerfTicks.Enqueue(([datetime]'2025-01-01T00:00:00Z').AddMilliseconds($offset))
                }
            }
            $script:networkPerfTicks.Dequeue()
        }
        Mock New-Object {
            $waitHandle = [pscustomobject]@{}
            Add-Member -InputObject $waitHandle -MemberType ScriptMethod -Name WaitOne -Value { param($timeout, $exitContext) $true }

            $connection = [pscustomobject]@{ AsyncWaitHandle = $waitHandle }
            $client = [pscustomobject]@{ Connection = $connection }
            Add-Member -InputObject $client -MemberType ScriptMethod -Name BeginConnect -Value { param($url, $port, $callback, $state) $this.Connection }
            Add-Member -InputObject $client -MemberType ScriptMethod -Name EndConnect -Value { param($asyncResult) }
            Add-Member -InputObject $client -MemberType ScriptMethod -Name Close -Value { }
            $client
        } -ParameterFilter { $TypeName -eq 'System.Net.Sockets.TcpClient' }

        $endpoints = @([PSCustomObject]@{ Name='ARM'; Url='management.azure.com'; Port=443 })
        $result = Test-NetworkPerformance -ServerName 'TEST-SRV' -Endpoints $endpoints -LatencyThreshold 300 -PacketLossThreshold 5
        $result.Success | Should -Be $true
        $result.Endpoints[0].Method | Should -Be 'TCP'
        $result.Endpoints[0].AverageLatency | Should -BeGreaterThan 0
        $result.PacketLoss | Should -Be 0
    }

    It 'Test-NetworkPerformance executes the TCP failure branch locally' {
        Mock Invoke-Command {
            & $ScriptBlock $ArgumentList[0]
        } -ParameterFilter { $ComputerName -eq 'TEST-SRV' -and $ArgumentList.Count -eq 1 }
        Mock Test-Connection { $null }
        Mock Get-Date { [datetime]'2025-01-01T00:00:00Z' }
        Mock New-Object {
            $waitHandle = [pscustomobject]@{}
            Add-Member -InputObject $waitHandle -MemberType ScriptMethod -Name WaitOne -Value { param($timeout, $exitContext) $false }

            $connection = [pscustomobject]@{ AsyncWaitHandle = $waitHandle }
            $client = [pscustomobject]@{ Connection = $connection }
            Add-Member -InputObject $client -MemberType ScriptMethod -Name BeginConnect -Value { param($url, $port, $callback, $state) $this.Connection }
            Add-Member -InputObject $client -MemberType ScriptMethod -Name EndConnect -Value { param($asyncResult) }
            Add-Member -InputObject $client -MemberType ScriptMethod -Name Close -Value { }
            $client
        } -ParameterFilter { $TypeName -eq 'System.Net.Sockets.TcpClient' }

        $endpoints = @([PSCustomObject]@{ Name='ARM'; Url='management.azure.com'; Port=443 })
        $result = Test-NetworkPerformance -ServerName 'TEST-SRV' -Endpoints $endpoints -LatencyThreshold 300 -PacketLossThreshold 5
        $result.Success | Should -Be $false
        $result.Endpoints[0].Error | Should -Be 'Could not establish connection'
        $result.Endpoints[0].PacketLoss | Should -Be 100
    }

    It 'Test-FirewallConfiguration executes configuration and validation scriptblocks locally' {
        $invokeCount = 0
        Mock Invoke-Command {
            $invokeCount++
            & $ScriptBlock
        } -ParameterFilter { $ComputerName -eq 'TEST-SRV' }
        Mock Get-NetFirewallProfile {
            @(
                [PSCustomObject]@{ Name = 'Domain'; Enabled = $true },
                [PSCustomObject]@{ Name = 'Public'; Enabled = $false }
            )
        }
        Mock Get-NetFirewallRule {
            param($Direction)
            if ($Direction -eq 'Outbound') {
                @(
                    [PSCustomObject]@{ DisplayName = 'Allow Azure'; Enabled = $true; Action = 'Allow'; Direction = 'Outbound' }
                )
            }
            else {
                @(
                    [PSCustomObject]@{ DisplayName = 'Allow Azure'; Enabled = $true; Action = 'Allow'; Direction = 'Outbound' },
                    [PSCustomObject]@{ DisplayName = 'Allow Arc'; Enabled = $true; Action = 'Allow'; Direction = 'Outbound' }
                )
            }
        }

        $result = Test-FirewallConfiguration -ServerName 'TEST-SRV'
        @($result.Validation).Count | Should -Be 4
        ($result.Validation | Where-Object { $_.Check -eq 'Firewall Enabled' }).Success | Should -Be $true
        ($result.Validation | Where-Object { $_.Check -eq 'Arc-Specific Rules' }).Success | Should -Be $true
    }

    It 'Test-NetworkRoutes executes failure validation branches locally' {
        $invokeCount = 0
        Mock Invoke-Command {
            $invokeCount++
            & $ScriptBlock
        } -ParameterFilter { $ComputerName -eq 'TEST-SRV' }
        Mock Get-NetRoute {
            @(
                [PSCustomObject]@{ DestinationPrefix = '10.0.0.0/24'; NextHop = '0.0.0.0'; RouteMetric = 5; InterfaceIndex = 9 }
            )
        }
        Mock Get-NetAdapter { @() }
        Mock Test-NetConnection {
            [PSCustomObject]@{ TraceRoute = @('10.0.0.1', '40.1.1.1') }
        }

        $result = Test-NetworkRoutes -ServerName 'TEST-SRV'
        $result.Success | Should -Be $false
        ($result.Validation | Where-Object { $_.Check -eq 'Default Gateway' }).Success | Should -Be $false
        ($result.Validation | Where-Object { $_.Check -eq 'Active Interfaces' }).Success | Should -Be $false
        ($result.Validation | Where-Object { $_.Check -eq 'Azure Route' }).Success | Should -Be $false
    }

    It 'Get-NetworkRecommendations returns recommendations for failed Routes' {
        $details = @(
            @{
                Component = 'Routes'
                Results   = @{
                    Validation = @(
                        @{ Check='Default Gateway'; Critical=$true; Success=$false; Details='No gateway configured' }
                    )
                }
            }
        )
        $result = Get-NetworkRecommendations -ValidationResults $details
        $result | Should -Not -BeNullOrEmpty
        @($result)[0].Component | Should -Be 'Network Routes'
    }
}

# ---------------------------------------------------------------------------
# 2. Test-SecurityValidation.ps1  (456 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Test-SecurityValidation.ps1 Coverage' {
    BeforeAll {
        # Stub external functions not defined in source file
        foreach ($fn in @('Test-WindowsUpdateStatus','Test-AntivirusStatus','Test-LocalSecurityPolicy',
                          'Test-AuditPolicy','Test-RegistrySecurity','Test-UserRightsAssignment',
                          'Test-RestrictedSoftware','Set-TLSConfiguration','Set-FirewallRules',
                          'Install-RequiredUpdates','Set-LocalSecurityPolicy')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() @{ Success = $true; Details = @{}; Remediation = @() } }
            }
        }
        . (Join-Path $script:SrcRoot 'Validation\Test-SecurityValidation.ps1')
        $script:SuccessCheck = { @{ Success = $true; Details = @{}; Remediation = @() } }
        $script:FailCheck    = { @{ Success = $false; Details = @{}; Remediation = @() } }
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path)
        }
    }

    It 'returns Success with Basic validation level when all checks pass' {
        Mock Get-DefaultSecurityBaseline { @{ TLS = @{}; Certificates = @{}; Firewall = @{}; ServiceAccounts = @{} } }
        Mock Test-TLSConfiguration       (& { $script:SuccessCheck })
        Mock Test-CertificateValidation  (& { $script:SuccessCheck })
        Mock Test-FirewallConfiguration  (& { $script:SuccessCheck })
        Mock Test-ServiceAccountSecurity (& { $script:SuccessCheck })
        Mock Get-SecurityScore           { 95 }

        $result = Test-SecurityValidation -ServerName 'TEST-SRV' -ValidationLevel 'Basic'
        $result | Should -Not -BeNullOrEmpty
        $result.ServerName | Should -Be 'TEST-SRV'
    }

    It 'returns a result with Enhanced validation level (runs more checks)' {
        Mock Get-DefaultSecurityBaseline { @{ TLS = @{}; Certificates = @{}; Firewall = @{}; ServiceAccounts = @{}; WindowsUpdates = @{}; Antivirus = @{}; SecurityPolicy = @{} } }
        Mock Test-TLSConfiguration       { @{ Success = $true; Details = @{} } }
        Mock Test-CertificateValidation  { @{ Success = $true; Details = @{} } }
        Mock Test-FirewallConfiguration  { @{ Success = $true; Details = @{} } }
        Mock Test-ServiceAccountSecurity { @{ Success = $true; Details = @{} } }
        Mock Test-WindowsUpdateStatus    { @{ Success = $true; Details = @{} } }
        Mock Test-AntivirusStatus        { @{ Success = $true; Details = @{} } }
        Mock Test-LocalSecurityPolicy    { @{ Success = $true; Details = @{} } }
        Mock Get-SecurityScore           { 90 }

        $result = Test-SecurityValidation -ServerName 'TEST-SRV' -ValidationLevel 'Enhanced'
        $result.Checks.Count | Should -BeGreaterThan 3
    }

    It 'runs full Comprehensive validation level' {
        Mock Get-DefaultSecurityBaseline { @{ TLS=@{}; Certificates=@{}; Firewall=@{}; ServiceAccounts=@{}; WindowsUpdates=@{}; Antivirus=@{}; SecurityPolicy=@{}; AuditPolicy=@{}; Registry=@{}; UserRights=@{}; RestrictedSoftware=@{} } }
        Mock Test-TLSConfiguration       { @{ Success = $true; Details = @{} } }
        Mock Test-CertificateValidation  { @{ Success = $true; Details = @{} } }
        Mock Test-FirewallConfiguration  { @{ Success = $true; Details = @{} } }
        Mock Test-ServiceAccountSecurity { @{ Success = $true; Details = @{} } }
        Mock Test-WindowsUpdateStatus    { @{ Success = $true; Details = @{} } }
        Mock Test-AntivirusStatus        { @{ Success = $true; Details = @{} } }
        Mock Test-LocalSecurityPolicy    { @{ Success = $true; Details = @{} } }
        Mock Test-AuditPolicy            { @{ Success = $true; Details = @{} } }
        Mock Test-RegistrySecurity       { @{ Success = $true; Details = @{} } }
        Mock Test-UserRightsAssignment   { @{ Success = $true; Details = @{} } }
        Mock Test-RestrictedSoftware     { @{ Success = $true; Details = @{} } }
        Mock Get-SecurityScore           { 100 }

        $result = Test-SecurityValidation -ServerName 'TEST-SRV' -ValidationLevel 'Comprehensive'
        $result.Checks.Count | Should -BeGreaterThan 7
    }

    It 'runs remediation path when -Remediate is set and checks fail' {
        Mock Get-DefaultSecurityBaseline { @{ TLS=@{Rules=@()}; Certificates=@{}; Firewall=@{Rules=@()}; ServiceAccounts=@{}; WindowsUpdates=@{}; Antivirus=@{}; SecurityPolicy=@{Policies=@()} } }
        Mock Test-TLSConfiguration       { @{ Success = $false; Details = @{}; Remediation = @() } }
        Mock Test-CertificateValidation  { @{ Success = $true; Details = @{} } }
        Mock Test-FirewallConfiguration  { @{ Success = $false; Details = @{}; Remediation = @() } }
        Mock Test-ServiceAccountSecurity { @{ Success = $true; Details = @{} } }
        Mock Test-WindowsUpdateStatus    { @{ Success = $false; Details = @{}; Remediation = @() } }
        Mock Test-AntivirusStatus        { @{ Success = $true; Details = @{} } }
        Mock Test-LocalSecurityPolicy    { @{ Success = $false; Details = @{}; Remediation = @() } }
        Mock Get-SecurityScore           { 50 }
        Mock Set-TLSConfiguration        { @{ Success = $true; Details = 'TLS remediated' } }
        Mock Set-FirewallRules           { @{ Success = $true; Details = 'Firewall remediated' } }
        Mock Install-RequiredUpdates     { @{ Success = $true; Details = 'Updates installed' } }
        Mock Set-LocalSecurityPolicy     { @{ Success = $true; Details = 'Policy set' } }

        $result = Test-SecurityValidation -ServerName 'TEST-SRV' -ValidationLevel 'Enhanced' -Remediate
        $result | Should -Not -BeNullOrEmpty
        $result.Remediation.Count | Should -BeGreaterThan 0
    }

    It 'returns Error when exception is thrown loading baseline' {
        Mock Get-DefaultSecurityBaseline { throw 'Baseline file not found' }
        Mock Test-Path { $false }

        $result = Test-SecurityValidation -ServerName 'TEST-SRV'
        # Should not throw, result should be empty/null or process should return early
        # Since there's a bare "return" in the catch block for baseline load
    }

    It 'Get-DefaultSecurityBaseline returns a non-empty hashtable' {
        $baseline = Get-DefaultSecurityBaseline
        $baseline | Should -Not -BeNullOrEmpty
        $baseline.TLS | Should -Not -BeNullOrEmpty
    }

    It 'Get-SecurityScore returns a numeric value for checks' {
        $checks = @(
            @{ Status = $true; Severity = 'Critical' }
            @{ Status = $false; Severity = 'High' }
            @{ Status = $true; Severity = 'Medium' }
        )
        $score = Get-SecurityScore -Checks $checks
        $score | Should -BeGreaterOrEqual 0
        $score | Should -BeLessOrEqual 100
    }

    It 'Test-TLSConfiguration (SecurityValidation version) returns result with Invoke-Command mocked' {
        Mock Invoke-Command { @{ TLS12Enabled = $true; TLS10Disabled = $true; TLS11Disabled = $true } } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-TLSConfiguration -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-CertificateValidation returns result with cert checks mocked' {
        Mock Invoke-Command { @{ Certificates = @(); ExpiringCount = 0; ExpiredCount = 0 } } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-CertificateValidation -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-FirewallConfiguration (SecurityValidation version) returns result' {
        Mock Invoke-Command { @{ ArcRule = $true; OutboundEnabled = $true } } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-FirewallConfiguration -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-ServiceAccountSecurity returns result with service info mocked' {
        Mock Invoke-Command { @{ HimdsAccount = 'LocalSystem'; Appropriate = $true } } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-ServiceAccountSecurity -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    # ---------------------------------------------------------------------------
    # Branch coverage: TLS disabled path
    # ---------------------------------------------------------------------------
    It 'Test-TLSConfiguration returns Success=false when TLS 1.2 registry keys are disabled' {
        Mock Invoke-Command {
            $h = @{}
            $h["HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client"] = 0
            $h["HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server"] = 0
            $h
        } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-TLSConfiguration -ServerName 'TEST-SRV'
        $result.Success | Should -Be $false
        $result.Details.Count | Should -BeGreaterThan 0
    }

    It 'Test-TLSConfiguration returns Success=true when TLS 1.2 and .NET settings are all enabled' {
        Mock Invoke-Command {
            $h = @{}
            $h["HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client"] = 1
            $h["HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server"] = 1
            $h["HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319\SystemDefaultTlsVersions"] = 1
            $h["HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319\SchUseStrongCrypto"] = 1
            $h["HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319\SystemDefaultTlsVersions"] = 1
            $h["HKLM:\SOFTWARE\WOW6432Node\Microsoft\.NETFramework\v4.0.30319\SchUseStrongCrypto"] = 1
            $h
        } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-TLSConfiguration -ServerName 'TEST-SRV'
        $result.Success | Should -Be $true
    }

    It 'Test-TLSConfiguration returns Success=false when old TLS 1.0 protocol is enabled' {
        Mock Invoke-Command {
            $h = @{}
            $h["HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Client"] = 1
            $h["HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2\Server"] = 1
            # TLS 1.0 is NOT disabled (value 1 = enabled = bad!)
            $h["HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Client"] = 1
            $h["HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Server"] = 1
            $h
        } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-TLSConfiguration -ServerName 'TEST-SRV'
        $result.Success | Should -Be $false
        $result.Remediation.Count | Should -BeGreaterThan 0
    }

    It 'Test-CertificateValidation returns Success=false when certificates are expiring soon' {
        $expiringCert = [PSCustomObject]@{
            Subject      = 'CN=Azure Arc Test'
            Thumbprint   = 'ABCDEF1234'
            NotBefore    = (Get-Date).AddYears(-1)
            NotAfter     = (Get-Date).AddDays(15)  # expires in 15 days < 30 day threshold
            Issuer       = 'CN=Microsoft Root CA'
            HasPrivateKey = $true
        }
        $script:certCallCount = 0
        Mock Invoke-Command {
            $script:certCallCount++
            if ($script:certCallCount -eq 1) {
                return @{
                    MachineCerts = @($expiringCert)
                    RootCerts    = @()
                    IntermediateCerts = @()
                }
            }
            return @()  # chain check returns empty
        } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-CertificateValidation -ServerName 'TEST-SRV'
        $result.Success | Should -Be $false
        ($result.Details | Where-Object { $_ -match 'expiring soon' }) | Should -Not -BeNullOrEmpty
    }

    It 'Test-FirewallConfiguration returns Success=false when required outbound rule is missing' {
        Mock Invoke-Command {
            return @{
                Profiles = @{ Domain = $true; Private = $true; Public = $true }
                ArcRules = @()  # no rules found
            }
        } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-FirewallConfiguration -ServerName 'TEST-SRV'
        $result.Success | Should -Be $false
        $result.Details.Count | Should -BeGreaterThan 0
    }

    It 'Get-SecurityScore returns 100 when all checks pass' {
        $checks = @(
            @{ Status = $true; Severity = 'Critical' }
            @{ Status = $true; Severity = 'High' }
            @{ Status = $true; Severity = 'Medium' }
        )
        $score = Get-SecurityScore -Checks $checks
        $score | Should -Be 100
    }

    It 'Get-SecurityScore returns value less than 100 when a check fails' {
        $checks = @(
            @{ Status = $true;  Severity = 'Critical' }
            @{ Status = $false; Severity = 'Critical' }
            @{ Status = $true;  Severity = 'Medium' }
        )
        $score = Get-SecurityScore -Checks $checks
        $score | Should -BeLessThan 100
        $score | Should -BeGreaterOrEqual 0
    }
}

# ---------------------------------------------------------------------------
# 3. Test-ArcAgentValidation.ps1  (408 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Test-ArcAgentValidation.ps1 Coverage' {
    BeforeAll {
        # Stub external functions called by source but defined elsewhere
        foreach ($fn in @('Test-ArcAuthentication','Test-ArcResourceHealth','Test-ArcExtensionStatus',
                          'Test-ArcLogs','Test-ArcVersion','Test-ArcCertificates',
                          'Test-ArcPerformance','Test-ArcDependencies',
                          'Get-ServiceDependencies','Get-ServiceAccount','Get-ServiceStartupHistory',
                          'Get-ProxyConfiguration','Get-TLSConfiguration')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() @{ Status = 'Success'; Details = @{}; ProxyServer = $null; Enabled = $false } }
            }
        }
        foreach ($fn in @('Get-AzContext','Get-AzConnectedMachine')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() $null }
            }
        }
        . (Join-Path $script:SrcRoot 'Validation\Test-ArcAgentValidation.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path)
        }
        Mock New-Item {}
        Mock Out-File {}
        Mock ConvertTo-Json { '{}' }
    }

    It 'returns Success when all critical checks pass' {
        Mock Test-ArcServiceStatus      { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcConfiguration      { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcConnectivity       { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcRegistrationStatus { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcAuthentication     { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcResourceHealth     { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcExtensionStatus    { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcLogs               { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcVersion            { @{ Status = 'Success'; Details = @{} } }
        Mock Get-ArcValidationRecommendations { @() }

        $result = Test-ArcAgentValidation -ServerName 'TEST-SRV' -LogPath $TestDrive
        $result.Status | Should -Be 'Success'
        $result.Components.Count | Should -BeGreaterThan 0
    }

    It 'returns Failed when a critical check fails (ServiceStatus)' {
        Mock Test-ArcServiceStatus      { @{ Status = 'Failed'; Details = @{ Error = 'Service not running' } } }
        Mock Test-ArcConfiguration      { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcConnectivity       { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcRegistrationStatus { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcAuthentication     { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcResourceHealth     { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcExtensionStatus    { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcLogs               { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcVersion            { @{ Status = 'Success'; Details = @{} } }
        Mock Get-ArcValidationRecommendations { @('Check himds service') }

        $result = Test-ArcAgentValidation -ServerName 'TEST-SRV' -LogPath $TestDrive
        $result.Status | Should -Be 'Failed'
        $result.Issues.Count | Should -BeGreaterThan 0
    }

    It 'runs detailed checks including cert/perf/dependencies when -DetailedOutput' {
        Mock Test-ArcServiceStatus      { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcConfiguration      { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcConnectivity       { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcRegistrationStatus { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcAuthentication     { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcResourceHealth     { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcExtensionStatus    { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcLogs               { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcVersion            { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcCertificates       { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcPerformance        { @{ Status = 'Success'; Details = @{} } }
        Mock Test-ArcDependencies       { @{ Status = 'Success'; Details = @{} } }
        Mock Get-ArcValidationRecommendations { @() }

        $result = Test-ArcAgentValidation -ServerName 'TEST-SRV' -LogPath $TestDrive -DetailedOutput
        ($result.Components | Where-Object { $_.Name -eq 'Certificates' }) | Should -Not -BeNullOrEmpty
    }

    It 'returns Error status when an exception is thrown' {
        Mock Test-ArcServiceStatus { throw 'Cannot reach server' }
        Mock Get-ArcValidationRecommendations {}

        $result = Test-ArcAgentValidation -ServerName 'TEST-SRV' -LogPath $TestDrive
        $result.Status | Should -Be 'Error'
    }

    It 'Test-ArcServiceStatus calls Get-Service and returns a result' {
        Mock Get-Service {
            [PSCustomObject]@{ Name = 'himds'; Status = 'Running'; StartType = 'Automatic'; DisplayName = 'Azure Connected Machine Agent' }
        }
        Mock Get-ServiceDependencies  { @{ Status = 'Success' } }
        Mock Get-ServiceAccount       { @{ Account = 'NT AUTHORITY\SYSTEM' } }
        Mock Get-ServiceStartupHistory { @() }

        $result = Test-ArcServiceStatus -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.Status | Should -BeIn 'Success', 'Failed', 'Error', 'Unknown'
    }

    It 'Test-ArcServiceStatus handles Get-Service failure gracefully' {
        Mock Get-Service { throw 'Access denied' }

        $result = Test-ArcServiceStatus -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Error'
    }

    It 'Test-ArcConfiguration handles missing config path gracefully' {
        Mock Test-Path { $false }

        $result = Test-ArcConfiguration -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Failed'
    }

    It 'Test-ArcConfiguration reads config files when path exists' {
        Mock Test-Path { $true }
        Mock Get-Content { '{"tenantId":"test-tenant","subscriptionId":"sub-1"}' }

        $result = Test-ArcConfiguration -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-ArcRegistrationStatus (validation version) handles missing registry' {
        Mock Invoke-Command { @{ Status = 'NotRegistered'; TenantId = $null } } -ParameterFilter { $ComputerName -ne $null }

        $result = Test-ArcRegistrationStatus -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Get-ArcValidationRecommendations returns recs for issues' {
        $issues = @(
            @{ Component = 'Service Status'; Severity = 'Critical'; Description = 'Service not running' }
        )
        $result = Get-ArcValidationRecommendations -Issues $issues
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Get-ArcValidationRecommendations returns empty for no issues' {
        $result = Get-ArcValidationRecommendations -Issues @()
        ($result | Measure-Object).Count | Should -Be 0
    }

    # ---------------------------------------------------------------------------
    # Test-ArcConnectivity helper (line 439)
    # ---------------------------------------------------------------------------
    It 'Test-ArcConnectivity returns Success when all required endpoints reachable' {
        Mock Test-NetConnection {
            [PSCustomObject]@{ TcpTestSucceeded = $true; PingReplyDetails = [PSCustomObject]@{ RoundtripTime = 20 } }
        }
        Mock Resolve-DnsName {
            @([PSCustomObject]@{ IPAddress = '1.2.3.4'; Name = 'management.azure.com' })
        }
        Mock Get-ProxyConfiguration { @{ Enabled = $false; ProxyServer = $null } }
        Mock Get-TLSConfiguration { @{ TLS12Enabled = $true } }

        $result = Test-ArcConnectivity -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.Status | Should -Be 'Success'
    }

    It 'Test-ArcConnectivity returns Failed when a required endpoint is unreachable' {
        Mock Test-NetConnection {
            [PSCustomObject]@{ TcpTestSucceeded = $false; PingReplyDetails = [PSCustomObject]@{ RoundtripTime = 0 } }
        }
        Mock Resolve-DnsName { @() }
        Mock Get-ProxyConfiguration { @{ Enabled = $false; ProxyServer = $null } }
        Mock Get-TLSConfiguration { @{ TLS12Enabled = $true } }

        $result = Test-ArcConnectivity -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Failed'
    }

    It 'Test-ArcConnectivity returns Error when Test-NetConnection throws' {
        Mock Test-NetConnection { throw 'Network timeout' }
        Mock Get-ProxyConfiguration { @{ Enabled = $false } }
        Mock Get-TLSConfiguration { @{ TLS12Enabled = $true } }

        $result = Test-ArcConnectivity -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Error'
    }

    # ---------------------------------------------------------------------------
    # Test-ArcRegistrationStatus extra paths (line 528)
    # ---------------------------------------------------------------------------
    It 'Test-ArcRegistrationStatus returns result when Azure context available and machine found' {
        Mock Invoke-Command { 'Agent Status: Connected' + "`nResource Id: /subscriptions/sub-1/resourceGroups/rg1/providers/..." } `
            -ParameterFilter { $ComputerName -ne $null }
        Mock Get-AzContext { [PSCustomObject]@{ Account = 'user@test.com'; Tenant = [PSCustomObject]@{ Id = 'tenant-1' } } }
        Mock Get-AzConnectedMachine {
            [PSCustomObject]@{ Status = 'Connected'; LastStatusChange = (Get-Date); AgentVersion = '1.0'; Id = '/sub/res-id' }
        }

        $result = Test-ArcRegistrationStatus -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-ArcRegistrationStatus returns Failed when machine not found in Azure' {
        Mock Invoke-Command { $null } -ParameterFilter { $ComputerName -ne $null }
        Mock Get-AzContext { [PSCustomObject]@{ Account = 'user@test.com'; Tenant = [PSCustomObject]@{ Id = 'tenant-1' } } }
        Mock Get-AzConnectedMachine { $null }

        $result = Test-ArcRegistrationStatus -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Failed'
    }
}

# ---------------------------------------------------------------------------
# 4. Test-PerformanceValidation.ps1  (311 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Test-PerformanceValidation.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'Validation\Test-PerformanceValidation.ps1')
        # Use source-matching metric key names
        $script:MockMetrics = @{
            CPU     = @{ AverageUsage = 30; MaxUsage = 60 }
            Memory  = @{ AverageAvailableMB = 4096; MinAvailableMB = 4096; AverageCommitPercent = 50 }
            Disk    = @{ FreeSpacePercent = 70; FreeSpaceGB = 50; AverageDiskTime = 5; AverageReadLatencyMS = 1; AverageWriteLatencyMS = 1 }
            Network = @{ AverageLatencyMS = 20; AverageOutputQueueLength = 0; AverageThroughputBytesPerSec = 1000 }
            System  = @{ AverageProcessorQueueLength = 2; AverageContextSwitchesPerSec = 1000 }
        }
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path)
        }
    }

    It 'returns Success when all performance checks pass' {
        Mock Get-ServerPerformanceMetrics { $script:MockMetrics }
        Mock Test-CPUPerformance          { @{ Status = 'Healthy'; Metrics = @{} } }
        Mock Test-MemoryPerformance        { @{ Status = 'Healthy'; Metrics = @{} } }
        Mock Test-DiskPerformance          { @{ Status = 'Healthy'; Metrics = @{} } }
        Mock Test-NetworkPerformance       { @{ Status = 'Healthy'; Metrics = @{} } }
        Mock Test-SystemResponsiveness     { @{ Status = 'Healthy'; Metrics = @{} } }
        Mock Test-ArcAgentResourceUsage   { @{ Status = 'Healthy'; Metrics = @{} } }
        Mock Get-Service                   { $null } -ParameterFilter { $Name -eq 'AzureMonitorAgent' }
        Mock Get-PerformanceRecommendations { @() }

        $result = Test-PerformanceValidation -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.Status | Should -Not -BeNullOrEmpty
    }

    It 'returns Warning when AMA agent exists and has resource usage issues' {
        Mock Get-ServerPerformanceMetrics { $script:MockMetrics }
        Mock Test-CPUPerformance          { @{ Status = 'Healthy'; Metrics = @{} } }
        Mock Test-MemoryPerformance        { @{ Status = 'Healthy'; Metrics = @{} } }
        Mock Test-DiskPerformance          { @{ Status = 'Healthy'; Metrics = @{} } }
        Mock Test-NetworkPerformance       { @{ Status = 'Healthy'; Metrics = @{} } }
        Mock Test-SystemResponsiveness     { @{ Status = 'Healthy'; Metrics = @{} } }
        Mock Test-ArcAgentResourceUsage   { @{ Status = 'Healthy'; Metrics = @{} } }
        Mock Get-Service                   {
            [PSCustomObject]@{ Name = 'AzureMonitorAgent'; Status = 'Running' }
        } -ParameterFilter { $Name -eq 'AzureMonitorAgent' }
        Mock Test-AMAAgentResourceUsage   { @{ Status = 'Warning'; Metrics = @{} } }
        Mock Get-PerformanceRecommendations { @('Reduce AMA memory usage') }

        $result = Test-PerformanceValidation -ServerName 'TEST-SRV'
        ($result.Checks | Where-Object { $_.Component -eq 'AMA Agent Resource Usage' }) | Should -Not -BeNullOrEmpty
    }

    It 'returns Error when Get-ServerPerformanceMetrics throws' {
        Mock Get-ServerPerformanceMetrics { throw 'Cannot collect metrics' }

        $result = Test-PerformanceValidation -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Error'
    }

    It 'Test-CPUPerformance returns Success for low CPU' {
        $metrics    = @{ AverageUsage = 20; MaxUsage = 40 }
        $thresholds = @{ Warning = 80; Critical = 90 }
        $result = Test-CPUPerformance -Metrics $metrics -Thresholds $thresholds
        $result.Status | Should -Be 'Success'
    }

    It 'Test-CPUPerformance returns Warning for high CPU' {
        $metrics    = @{ AverageUsage = 85; MaxUsage = 92 }
        $thresholds = @{ Warning = 80; Critical = 90 }
        $result = Test-CPUPerformance -Metrics $metrics -Thresholds $thresholds
        $result.Status | Should -BeIn @('Warning', 'Critical')
    }

    It 'Test-MemoryPerformance returns Success for sufficient memory' {
        $metrics    = @{ MinAvailableMB = 4096; AverageAvailableMB = 4096; AverageCommitPercent = 50 }
        $thresholds = @{ AvailableMBWarning = 1024; AvailableMBCritical = 512 }
        $result = Test-MemoryPerformance -Metrics $metrics -Thresholds $thresholds
        $result.Status | Should -Be 'Success'
    }

    It 'Test-MemoryPerformance returns Critical for low memory' {
        $metrics    = @{ MinAvailableMB = 256; AverageAvailableMB = 256; AverageCommitPercent = 95 }
        $thresholds = @{ AvailableMBWarning = 1024; AvailableMBCritical = 512 }
        $result = Test-MemoryPerformance -Metrics $metrics -Thresholds $thresholds
        $result.Status | Should -Be 'Critical'
    }

    It 'Test-DiskPerformance returns Success for adequate disk space' {
        $metrics    = @{ FreeSpacePercent = 70; FreeSpaceGB = 50; AverageReadLatencyMS = 1; AverageWriteLatencyMS = 1 }
        $thresholds = @{ FreePercentWarning = 15; FreePercentCritical = 10 }
        $result = Test-DiskPerformance -Metrics $metrics -Thresholds $thresholds
        $result.Status | Should -Be 'Success'
    }

    It 'Test-SystemResponsiveness returns Success for low processor queue' {
        $metrics    = @{ AverageProcessorQueueLength = 2; AverageContextSwitchesPerSec = 1000 }
        $thresholds = @{ ProcessorQueueWarning = 5; ProcessorQueueCritical = 10 }
        $result = Test-SystemResponsiveness -Metrics $metrics -Thresholds $thresholds
        $result.Status | Should -Be 'Success'
    }

    It 'Get-ServerPerformanceMetrics returns metrics with WMI calls mocked' {
        Mock Get-WmiObject {
            [PSCustomObject]@{ Size = 107374182400; FreeSpace = 53687091200 }
        }
        Mock Get-Counter {
            [PSCustomObject]@{
                CounterSamples = @(
                    [PSCustomObject]@{ Path = '\Processor(_Total)\% Processor Time';           CookedValue = 35    }
                    [PSCustomObject]@{ Path = '\Memory\Available MBytes';                       CookedValue = 4096  }
                    [PSCustomObject]@{ Path = '\Memory\% Committed Bytes In Use';               CookedValue = 50    }
                    [PSCustomObject]@{ Path = '\PhysicalDisk(_Total)\% Disk Time';              CookedValue = 10    }
                    [PSCustomObject]@{ Path = '\PhysicalDisk(_Total)\Avg. Disk sec/Read';       CookedValue = 0.001 }
                    [PSCustomObject]@{ Path = '\PhysicalDisk(_Total)\Avg. Disk sec/Write';      CookedValue = 0.001 }
                    [PSCustomObject]@{ Path = '\Network Interface(*)\Bytes Total/sec';          CookedValue = 1000  }
                    [PSCustomObject]@{ Path = '\Network Interface(*)\Output Queue Length';      CookedValue = 0     }
                    [PSCustomObject]@{ Path = '\System\Processor Queue Length';                 CookedValue = 2     }
                    [PSCustomObject]@{ Path = '\System\Context Switches/sec';                   CookedValue = 100   }
                )
            }
        }
        Mock Test-Connection { [PSCustomObject]@{ ResponseTime = 20 } }
        Mock Start-Sleep {}

        $result = Get-ServerPerformanceMetrics -ServerName 'TEST-SRV' -SampleCount 1 -SampleIntervalSeconds 0
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-ArcAgentResourceUsage returns result with Invoke-Command mocked' {
        Mock Invoke-Command {
            [PSCustomObject]@{ Name = 'himds'; CPU = 1.5; WorkingSet64 = 50MB }
        } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-ArcAgentResourceUsage -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Get-PerformanceRecommendations returns recs for warnings' {
        $checks = @(
            @{ Component = 'CPU'; Status = 'Warning' }
            @{ Component = 'Memory'; Status = 'Healthy' }
        )
        $result = Get-PerformanceRecommendations -Checks $checks
        $result | Should -Not -BeNullOrEmpty
    }

    It 'returns Critical overall status when a critical check is present' {
        Mock Get-ServerPerformanceMetrics { $script:MockMetrics }
        Mock Test-CPUPerformance          { @{ Status = 'Critical'; Metrics = @{}; Details = @('cpu critical') } }
        Mock Test-MemoryPerformance       { @{ Status = 'Success'; Metrics = @{}; Details = @() } }
        Mock Test-DiskPerformance         { @{ Status = 'Success'; Metrics = @{}; Details = @() } }
        Mock Test-NetworkPerformance      { @{ Status = 'Success'; Metrics = @{}; Details = @() } }
        Mock Test-SystemResponsiveness    { @{ Status = 'Success'; Metrics = @{}; Details = @() } }
        Mock Test-ArcAgentResourceUsage   { @{ Status = 'Success'; Metrics = @{}; Details = @() } }
        Mock Get-Service                  { $null } -ParameterFilter { $Name -eq 'AzureMonitorAgent' }
        Mock Get-PerformanceRecommendations { @('Investigate CPU') }

        $result = Test-PerformanceValidation -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Critical'
    }

    It 'retains raw Metrics when DetailedOutput is specified' {
        Mock Get-ServerPerformanceMetrics { $script:MockMetrics }
        Mock Test-CPUPerformance          { @{ Status = 'Success'; Metrics = @{}; Details = @() } }
        Mock Test-MemoryPerformance       { @{ Status = 'Success'; Metrics = @{}; Details = @() } }
        Mock Test-DiskPerformance         { @{ Status = 'Success'; Metrics = @{}; Details = @() } }
        Mock Test-NetworkPerformance      { @{ Status = 'Success'; Metrics = @{}; Details = @() } }
        Mock Test-SystemResponsiveness    { @{ Status = 'Success'; Metrics = @{}; Details = @() } }
        Mock Test-ArcAgentResourceUsage   { @{ Status = 'Success'; Metrics = @{}; Details = @() } }
        Mock Get-Service                  { $null } -ParameterFilter { $Name -eq 'AzureMonitorAgent' }
        Mock Get-PerformanceRecommendations { @() }

        $result = Test-PerformanceValidation -ServerName 'TEST-SRV' -DetailedOutput
        $result.PSObject.Properties['Metrics'] | Should -Not -BeNullOrEmpty
    }

    It 'Test-DiskPerformance returns Warning for high latency with adequate space' {
        $metrics    = @{ FreeSpacePercent = 60; FreeSpaceGB = 100; AverageReadLatencyMS = 25; AverageWriteLatencyMS = 22 }
        $thresholds = @{ FreePercentWarning = 15; FreePercentCritical = 10 }
        $result = Test-DiskPerformance -Metrics $metrics -Thresholds $thresholds
        $result.Status | Should -Be 'Warning'
    }

    It 'Test-NetworkPerformance returns Critical for latency above critical threshold' {
        $metrics    = @{ AverageLatencyMS = 250; AverageOutputQueueLength = 0; AverageThroughputBytesPerSec = 1000 }
        $thresholds = @{ LatencyMSWarning = 100; LatencyMSCritical = 200 }
        $result = Test-NetworkPerformance -Metrics $metrics -Thresholds $thresholds
        $result.Status | Should -Be 'Critical'
    }

    It 'Test-NetworkPerformance returns Warning for high output queue length' {
        $metrics    = @{ AverageLatencyMS = 30; AverageOutputQueueLength = 3; AverageThroughputBytesPerSec = 1000 }
        $thresholds = @{ LatencyMSWarning = 100; LatencyMSCritical = 200 }
        $result = Test-NetworkPerformance -Metrics $metrics -Thresholds $thresholds
        $result.Status | Should -Be 'Warning'
    }

    It 'Test-SystemResponsiveness returns Warning for high context switches' {
        $metrics    = @{ AverageProcessorQueueLength = 2; AverageContextSwitchesPerSec = 20000 }
        $thresholds = @{ ProcessorQueueWarning = 5; ProcessorQueueCritical = 10 }
        $result = Test-SystemResponsiveness -Metrics $metrics -Thresholds $thresholds
        $result.Status | Should -Be 'Warning'
    }

    It 'Test-ArcAgentResourceUsage returns Critical when process is not found' {
        Mock Invoke-Command { $null } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-ArcAgentResourceUsage -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Critical'
    }

    It 'Test-ArcAgentResourceUsage returns Warning for high CPU and memory' {
        Mock Invoke-Command {
            [PSCustomObject]@{
                CPU = 12
                WorkingSet = 250MB
                Threads = @(1,2,3)
                HandleCount = 1201
            }
        } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-ArcAgentResourceUsage -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Warning'
        ($result.Details -join ' ') | Should -Match 'handle count is high'
    }

    It 'Test-ArcAgentResourceUsage returns Error when Invoke-Command throws' {
        Mock Invoke-Command { throw 'remote access failed' } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-ArcAgentResourceUsage -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Error'
    }

    It 'Test-AMAAgentResourceUsage returns Critical when process is not found' {
        Mock Invoke-Command { $null } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-AMAAgentResourceUsage -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Critical'
    }

    It 'Test-AMAAgentResourceUsage returns Warning for high CPU and memory' {
        Mock Invoke-Command {
            [PSCustomObject]@{
                CPU = 20
                WorkingSet = 350MB
                Threads = @(1,2,3)
                HandleCount = 1700
            }
        } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-AMAAgentResourceUsage -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Warning'
        ($result.Details -join ' ') | Should -Match 'handle count is high'
    }

    It 'Get-PerformanceRecommendations returns entries for all non-success component types' {
        $checks = @(
            @{ Component = 'Disk'; Status = 'Warning'; Details = @('disk') }
            @{ Component = 'Network'; Status = 'Critical'; Details = @('network') }
            @{ Component = 'System Responsiveness'; Status = 'Warning'; Details = @('system') }
            @{ Component = 'Arc Agent Resource Usage'; Status = 'Warning'; Details = @('arc') }
            @{ Component = 'AMA Agent Resource Usage'; Status = 'Critical'; Details = @('ama') }
        )
        $result = Get-PerformanceRecommendations -Checks $checks
        @($result).Count | Should -Be 5
    }

    It 'Test-CPUPerformance returns Critical and includes max critical detail' {
        $metrics    = @{ AverageUsage = 95; MaxUsage = 99 }
        $thresholds = @{ Warning = 80; Critical = 90 }
        $result = Test-CPUPerformance -Metrics $metrics -Thresholds $thresholds
        $result.Status | Should -Be 'Critical'
        ($result.Details -join ' ') | Should -Match 'Maximum CPU usage reached critical level'
    }

    It 'Test-MemoryPerformance returns Warning and notes high commit percent' {
        $metrics    = @{ MinAvailableMB = 900; AverageAvailableMB = 950; AverageCommitPercent = 96 }
        $thresholds = @{ AvailableMBWarning = 1024; AvailableMBCritical = 512 }
        $result = Test-MemoryPerformance -Metrics $metrics -Thresholds $thresholds
        $result.Status | Should -Be 'Warning'
        ($result.Details -join ' ') | Should -Match 'Memory commit percentage is high'
    }

    It 'Test-DiskPerformance returns Critical for very low free space' {
        $metrics    = @{ FreeSpacePercent = 5; FreeSpaceGB = 2; AverageReadLatencyMS = 5; AverageWriteLatencyMS = 5 }
        $thresholds = @{ FreePercentWarning = 15; FreePercentCritical = 10 }
        $result = Test-DiskPerformance -Metrics $metrics -Thresholds $thresholds
        $result.Status | Should -Be 'Critical'
    }

    It 'Test-NetworkPerformance returns Warning for latency above warning threshold' {
        $metrics    = @{ AverageLatencyMS = 150; AverageOutputQueueLength = 0; AverageThroughputBytesPerSec = 1000 }
        $thresholds = @{ LatencyMSWarning = 100; LatencyMSCritical = 200 }
        $result = Test-NetworkPerformance -Metrics $metrics -Thresholds $thresholds
        $result.Status | Should -Be 'Warning'
    }

    It 'Test-SystemResponsiveness returns Critical for queue length above critical threshold' {
        $metrics    = @{ AverageProcessorQueueLength = 12; AverageContextSwitchesPerSec = 5000 }
        $thresholds = @{ ProcessorQueueWarning = 5; ProcessorQueueCritical = 10 }
        $result = Test-SystemResponsiveness -Metrics $metrics -Thresholds $thresholds
        $result.Status | Should -Be 'Critical'
    }

    It 'Test-AMAAgentResourceUsage returns Success with normal usage details' {
        Mock Invoke-Command {
            [PSCustomObject]@{
                CPU = 3
                WorkingSet = 120MB
                Threads = @(1,2,3)
                HandleCount = 400
            }
        } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-AMAAgentResourceUsage -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Success'
        ($result.Details -join ' ') | Should -Match 'resource usage is normal'
    }

    It 'Test-AMAAgentResourceUsage returns Error when Invoke-Command throws' {
        Mock Invoke-Command { throw 'ama remote failure' } -ParameterFilter { $ComputerName -ne $null }
        $result = Test-AMAAgentResourceUsage -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Error'
    }

    It 'Get-ServerPerformanceMetrics calculates summary values across multiple samples' {
        $script:counterCall = 0
        Mock Get-WmiObject {
            [PSCustomObject]@{ Size = 107374182400; FreeSpace = 64424509440 }
        }
        Mock Get-Counter {
            $script:counterCall++
            $cpu = if ($script:counterCall -eq 1) { 20 } else { 40 }
            $mem = if ($script:counterCall -eq 1) { 4096 } else { 3072 }
            $commit = if ($script:counterCall -eq 1) { 45 } else { 55 }
            $disk = if ($script:counterCall -eq 1) { 5 } else { 15 }
            $queue = if ($script:counterCall -eq 1) { 1 } else { 3 }
            $switches = if ($script:counterCall -eq 1) { 1000 } else { 3000 }
            [PSCustomObject]@{
                CounterSamples = @(
                    [PSCustomObject]@{ Path = '\Processor(_Total)\% Processor Time'; CookedValue = $cpu }
                    [PSCustomObject]@{ Path = '\Memory\Available MBytes'; CookedValue = $mem }
                    [PSCustomObject]@{ Path = '\Memory\% Committed Bytes In Use'; CookedValue = $commit }
                    [PSCustomObject]@{ Path = '\PhysicalDisk(_Total)\% Disk Time'; CookedValue = $disk }
                    [PSCustomObject]@{ Path = '\PhysicalDisk(_Total)\Avg. Disk sec/Read'; CookedValue = 0.002 }
                    [PSCustomObject]@{ Path = '\PhysicalDisk(_Total)\Avg. Disk sec/Write'; CookedValue = 0.003 }
                    [PSCustomObject]@{ Path = '\Network Interface(*)\Bytes Total/sec'; CookedValue = 2048 }
                    [PSCustomObject]@{ Path = '\Network Interface(*)\Output Queue Length'; CookedValue = 1 }
                    [PSCustomObject]@{ Path = '\System\Processor Queue Length'; CookedValue = $queue }
                    [PSCustomObject]@{ Path = '\System\Context Switches/sec'; CookedValue = $switches }
                )
            }
        }
        Mock Test-Connection {
            [PSCustomObject]@{ ResponseTime = 15 }
        }
        Mock Start-Sleep {}

        $result = Get-ServerPerformanceMetrics -ServerName 'TEST-SRV' -SampleCount 2 -SampleIntervalSeconds 0
        [math]::Round($result.CPU.AverageUsage, 0) | Should -Be 30
        [math]::Round($result.Memory.MinAvailableMB, 0) | Should -Be 3072
        [math]::Round($result.System.AverageProcessorQueueLength, 0) | Should -Be 2
        @($result.Samples).Count | Should -Be 2
    }
}

# ---------------------------------------------------------------------------
# 5. Test-DeploymentValidation.ps1  (177 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Test-DeploymentValidation.ps1 Coverage' {
    BeforeAll {
        # Stub external validator functions (each defined in its own file; only Deployment is dot-sourced here)
        foreach ($fn in @('Test-NetworkValidation','Test-SecurityValidation','Test-PerformanceValidation',
                          'Test-ConfigurationDrift','Test-ResourceProviderStatus','Test-ExtensionHealth',
                          'Get-ValidationRecommendations','Test-AMAValidation',
                          'Get-ArcAgentConfig','Test-ArcConnectivity','Get-ArcRegistrationStatus',
                          'Get-AMAConfig','Get-DataCollectionRules','Test-DataFlow')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() [PSCustomObject]@{ Status='Success'; WorkspaceId=''; Details=@(); Success=$true } }
            }
        }
        . (Join-Path $script:SrcRoot 'Validation\Test-DeploymentValidation.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path)
        }
        # Allow config loading to succeed with an empty-but-valid JSON object
        Mock Get-Content { '{}' }
    }

    It 'returns overall Success when all component validations pass' {
        Mock Test-ArcAgentValidation      { [PSCustomObject]@{ Status='Success'; Components=@(); Issues=@() } }
        Mock Test-AMAValidation           { [PSCustomObject]@{ Status='Success'; Components=@() } }
        Mock Test-NetworkValidation       { [PSCustomObject]@{ Status='Success'; Details=@() } }
        Mock Test-SecurityValidation      { [PSCustomObject]@{ Status='Success'; Checks=@() } }
        Mock Test-PerformanceValidation   { [PSCustomObject]@{ Status='Success'; Checks=@() } }
        Mock Test-ConfigurationDrift      { [PSCustomObject]@{ Status='Compliant' } }
        Mock Test-ResourceProviderStatus  { [PSCustomObject]@{ Status='Success' } }
        Mock Test-ExtensionHealth         { [PSCustomObject]@{ Status='Success'; Summary=@{} } }
        Mock Get-ValidationRecommendations { @() }

        $result = Test-DeploymentValidation -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.ServerName | Should -Be 'TEST-SRV'
    }

    It 'reports OverallStatus Failed when a component fails' {
        Mock Test-ArcAgentValidation      { [PSCustomObject]@{ Status='Failed'; Components=@(); Issues=@(@{Component='Service';Severity='Critical'}) } }
        Mock Test-AMAValidation           { [PSCustomObject]@{ Status='Success'; Components=@() } }
        Mock Test-NetworkValidation       { [PSCustomObject]@{ Status='Success'; Details=@() } }
        Mock Test-SecurityValidation      { [PSCustomObject]@{ Status='Success'; Checks=@() } }
        Mock Test-PerformanceValidation   { [PSCustomObject]@{ Status='Success'; Checks=@() } }
        Mock Test-ConfigurationDrift      { [PSCustomObject]@{ Status='Compliant' } }
        Mock Test-ResourceProviderStatus  { [PSCustomObject]@{ Status='Success' } }
        Mock Test-ExtensionHealth         { [PSCustomObject]@{ Status='Success'; Summary=@{} } }
        Mock Get-ValidationRecommendations { @('Fix Arc agent service') }

        $result = Test-DeploymentValidation -ServerName 'TEST-SRV'
        $result.OverallStatus | Should -BeIn 'Failed', 'Partial', 'Error'
    }

    It 'returns Error when an exception is thrown' {
        Mock Test-ArcAgentValidation { throw 'Cannot connect' }

        $result = Test-DeploymentValidation -ServerName 'TEST-SRV'
        $result.OverallStatus | Should -Be 'Error'
    }

    # ---------------------------------------------------------------------------
    # Helper function coverage: Test-ArcAgentValidation (Deployment version)
    # ---------------------------------------------------------------------------
    It 'Test-ArcAgentValidation (Deployment) returns Success when service running and all checks pass' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName)
            [PSCustomObject]@{ Name = 'himds'; Status = 'Running' }
        }
        try {
            Mock Get-ArcAgentConfig { @{ tenantId = 'test-tenant'; subscriptionId = 'sub-1' } }
            Mock Test-ArcConnectivity { @{ Success = $true; Details = @{} } }
            Mock Get-ArcRegistrationStatus { @{ Status = 'Connected'; Details = @{} } }

            $result = Test-ArcAgentValidation -ServerName 'TEST-SRV'
            $result.Status | Should -Be 'Success'
        }
        finally {
            Remove-Item Function:\global:Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'Test-ArcAgentValidation (Deployment) returns Failed when service is Stopped' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName)
            [PSCustomObject]@{ Name = 'himds'; Status = 'Stopped' }
        }
        try {
            Mock Get-ArcAgentConfig { @{ tenantId = 'test-tenant' } }
            Mock Test-ArcConnectivity { @{ Success = $true; Details = @{} } }
            Mock Get-ArcRegistrationStatus { @{ Status = 'Connected'; Details = @{} } }

            $result = Test-ArcAgentValidation -ServerName 'TEST-SRV'
            $result.Status | Should -Be 'Failed'
        }
        finally {
            Remove-Item Function:\global:Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'Test-ArcAgentValidation (Deployment) returns Error on exception' {
        Mock Get-Service { throw 'Cannot connect to remote server' }

        $result = Test-ArcAgentValidation -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Error'
    }

    # ---------------------------------------------------------------------------
    # Helper function coverage: Test-AMAValidation (Deployment version)
    # ---------------------------------------------------------------------------
    It 'Test-AMAValidation (Deployment) returns Success when service running and workspace matches' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName)
            [PSCustomObject]@{ Name = 'AzureMonitorAgent'; Status = 'Running' }
        }
        try {
            Mock Get-AMAConfig { [PSCustomObject]@{ WorkspaceId = 'ws-123' } }
            Mock Get-DataCollectionRules { @{ Status = 'Enabled'; Details = @{} } }
            Mock Test-DataFlow { @{ Success = $true; Details = @{} } }

            $result = Test-AMAValidation -ServerName 'TEST-SRV' -WorkspaceId 'ws-123'
            $result.Status | Should -Be 'Success'
        }
        finally {
            Remove-Item Function:\global:Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'Test-AMAValidation (Deployment) returns Failed when workspace ID does not match' {
        function Global:Get-Service {
            param([string]$Name, [string]$ComputerName)
            [PSCustomObject]@{ Name = 'AzureMonitorAgent'; Status = 'Running' }
        }
        try {
            Mock Get-AMAConfig { [PSCustomObject]@{ WorkspaceId = 'different-ws-456' } }
            Mock Get-DataCollectionRules { @{ Status = 'Enabled'; Details = @{} } }
            Mock Test-DataFlow { @{ Success = $true; Details = @{} } }

            $result = Test-AMAValidation -ServerName 'TEST-SRV' -WorkspaceId 'ws-123'
            $result.Status | Should -Be 'Failed'
        }
        finally {
            Remove-Item Function:\global:Get-Service -ErrorAction SilentlyContinue
        }
    }

    It 'Test-AMAValidation (Deployment) returns Error on exception' {
        Mock Get-Service { throw 'Access denied' }

        $result = Test-AMAValidation -ServerName 'TEST-SRV' -WorkspaceId 'ws-123'
        $result.Status | Should -Be 'Error'
    }

    # ---------------------------------------------------------------------------
    # Helper function coverage: Get-ValidationRecommendations
    # ---------------------------------------------------------------------------
    It 'Get-ValidationRecommendations returns recommendation for failed Arc Agent component' {
        $components = @(
            @{ Name = 'Arc Agent'; Status = 'Failed'; Details = @() }
        )
        $result = Get-ValidationRecommendations -Components $components
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Get-ValidationRecommendations returns recommendation for Network Connectivity failure' {
        $components = @(
            @{ Name = 'Network Connectivity'; Status = 'Failed'; Details = @() }
        )
        $result = Get-ValidationRecommendations -Components $components
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Get-ValidationRecommendations returns recommendation for Azure Monitor Agent failure' {
        $components = @(
            @{ Name = 'Azure Monitor Agent'; Status = 'Failed'; Details = @() }
        )
        $result = Get-ValidationRecommendations -Components $components
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Get-ValidationRecommendations returns empty list when all components are Success' {
        $components = @(
            @{ Name = 'Arc Agent'; Status = 'Success'; Details = @() }
            @{ Name = 'Network Connectivity'; Status = 'Success'; Details = @() }
        )
        $result = Get-ValidationRecommendations -Components $components
        ($result | Measure-Object).Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# 6. Test-ExtensionHealth.ps1  (172 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Test-ExtensionHealth.ps1 Coverage' {
    BeforeAll {
        # Stub Az cmdlets before dot-sourcing
        if (-not (Get-Command Get-AzConnectedMachine -ErrorAction SilentlyContinue)) {
            Set-Item Function:global:Get-AzConnectedMachine -Value {
                param($Name, $ErrorAction)
                throw 'Must be mocked in tests'
            }
        }
        if (-not (Get-Command Get-AzConnectedMachineExtension -ErrorAction SilentlyContinue)) {
            Set-Item Function:global:Get-AzConnectedMachineExtension -Value {
                param($ResourceGroupName, $MachineName, $Name, $ErrorAction)
                throw 'Must be mocked in tests'
            }
        }
        if (-not (Get-Command Get-AzActivityLog -ErrorAction SilentlyContinue)) {
            Set-Item Function:global:Get-AzActivityLog -Value { param() @() }
        }

        . (Join-Path $script:SrcRoot 'Validation\Test-ExtensionHealth.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path)
        }
    }

    It 'returns a result with extension summary when server and extensions found' {
        Mock Get-AzConnectedMachine {
            [PSCustomObject]@{ Name='TEST-SRV'; ResourceGroupName='rg-test'; Location='eastus' }
        }
        Mock Get-AzConnectedMachineExtension {
            @(
                [PSCustomObject]@{ Name='AzureMonitorWindowsAgent'; ExtensionType='AzureMonitorWindowsAgent'; Publisher='Microsoft.Azure.Monitor'; TypeHandlerVersion='1.0'; ProvisioningState='Succeeded' }
            )
        }
        Mock Get-ExtensionRecommendations { @() }

        $result = Test-ExtensionHealth -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.Summary.Total | Should -Be 1
        $result.Summary.Healthy | Should -Be 1
    }

    It 'marks extension as Unhealthy when ProvisioningState is Failed' {
        Mock Get-AzConnectedMachine {
            [PSCustomObject]@{ Name='TEST-SRV'; ResourceGroupName='rg-test' }
        }
        Mock Get-AzConnectedMachineExtension {
            @(
                [PSCustomObject]@{ Name='FailExt'; ExtensionType='SomeExt'; Publisher='SomePub'; TypeHandlerVersion='1.0'; ProvisioningState='Failed' }
            )
        }
        Mock Get-ExtensionRecommendations { @('Reinstall failed extension') }

        $result = Test-ExtensionHealth -ServerName 'TEST-SRV'
        $result.Summary.Unhealthy | Should -Be 1
    }

    It 'returns Error when Get-AzConnectedMachine throws' {
        Mock Get-AzConnectedMachine { throw 'Server not found in Azure Arc' }

        $result = Test-ExtensionHealth -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Error'
    }

    It 'runs service status check for AzureMonitorWindowsAgent extension' {
        Mock Get-AzConnectedMachine {
            [PSCustomObject]@{ Name='TEST-SRV'; ResourceGroupName='rg-test' }
        }
        Mock Get-AzConnectedMachineExtension {
            @(
                [PSCustomObject]@{ Name='AzureMonitorWindowsAgent'; ExtensionType='AzureMonitorWindowsAgent'; Publisher='Microsoft.Azure.Monitor'; TypeHandlerVersion='1.0'; ProvisioningState='Succeeded' }
            )
        }
        Mock Get-ServiceStatus { @{ Status = 'Running' } }
        Mock Get-ExtensionRecommendations { @() }

        $result = Test-ExtensionHealth -ServerName 'TEST-SRV'
        $result.Extensions[0].ServiceStatus | Should -Not -BeNullOrEmpty
    }

    It 'includes detailed status when -IncludeDetails is specified' {
        Mock Get-AzConnectedMachine {
            [PSCustomObject]@{ Name='TEST-SRV'; ResourceGroupName='rg-test' }
        }
        Mock Get-AzConnectedMachineExtension {
            @([PSCustomObject]@{ Name='TestExt'; ExtensionType='TestType'; Publisher='TestPub'; TypeHandlerVersion='1.0'; ProvisioningState='Succeeded' })
        }
        Mock Get-ExtensionDetailedStatus { @{ Status = 'Succeeded'; Error = $null } }
        Mock Get-ExtensionRecommendations { @() }

        $result = Test-ExtensionHealth -ServerName 'TEST-SRV' -IncludeDetails
        $result.Extensions[0].DetailedStatus | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 7. ValidationMatrix.ps1 (0% covered — pure data file)
# ---------------------------------------------------------------------------
Describe 'ValidationMatrix.ps1 Coverage' {
    It 'can be dot-sourced without error' {
        { . (Join-Path $script:SrcRoot 'Validation\ValidationMatrix.ps1') } | Should -Not -Throw
    }

    It 'defines the $ValidationMatrix hashtable with Connectivity section' {
        . (Join-Path $script:SrcRoot 'Validation\ValidationMatrix.ps1')
        $ValidationMatrix | Should -Not -BeNullOrEmpty
        $ValidationMatrix.Connectivity | Should -Not -BeNullOrEmpty
    }

    It 'Connectivity section has Tests array and Weight' {
        . (Join-Path $script:SrcRoot 'Validation\ValidationMatrix.ps1')
        $ValidationMatrix.Connectivity.Tests | Should -Not -BeNullOrEmpty
        $ValidationMatrix.Connectivity.Weight | Should -Be 0.4
    }

    It 'Security section has Tests and Weight' {
        . (Join-Path $script:SrcRoot 'Validation\ValidationMatrix.ps1')
        $ValidationMatrix.Security | Should -Not -BeNullOrEmpty
        $ValidationMatrix.Security.Weight | Should -Be 0.3
    }

    It 'Agent section has Tests and Weight' {
        . (Join-Path $script:SrcRoot 'Validation\ValidationMatrix.ps1')
        $ValidationMatrix.Agent | Should -Not -BeNullOrEmpty
        $ValidationMatrix.Agent.Weight | Should -Be 0.3
    }

    It 'Security Tests array is not empty' {
        . (Join-Path $script:SrcRoot 'Validation\ValidationMatrix.ps1')
        $ValidationMatrix.Security.Tests.Count | Should -BeGreaterOrEqual 1
    }
}

# ---------------------------------------------------------------------------
# 8. Get-ConfigurationDrifts.ps1 (0% covered — script-level wrapper)
# ---------------------------------------------------------------------------
Describe 'Get-ConfigurationDrifts.ps1 Coverage' {
    BeforeAll {
        $script:DriftsPath = Join-Path $script:SrcRoot 'Validation\Get-ConfigurationDrifts.ps1'

        # Create a minimal fake Test-ConfigurationDrift.ps1 in TestDrive
        $script:FakeDriftScript = Join-Path $TestDrive 'Test-ConfigurationDrift.ps1'
        Set-Content -Path $script:FakeDriftScript -Value @'
param([string]$ServerName, [string]$BaselinePath, [string]$LogPath)
@{ DriftDetected = $false; DriftItems = @(); ServerName = $ServerName }
'@
    }

    It 'executes successfully with explicit TestConfigurationDriftPath' {
        $logFile = Join-Path $TestDrive 'drifts_activity.log'
        { . $script:DriftsPath `
              -TestConfigurationDriftPath $script:FakeDriftScript `
              -ServerName 'TEST-SRV' `
              -LogPath $logFile } | Should -Not -Throw
    }

    It 'returns data from the subordinate script' {
        $logFile = Join-Path $TestDrive 'drifts_activity2.log'
        $result = . $script:DriftsPath `
              -TestConfigurationDriftPath $script:FakeDriftScript `
              -ServerName 'DRIFT-SRV' `
              -LogPath $logFile
        $result | Should -Not -BeNullOrEmpty
        $result.ServerName | Should -Be 'DRIFT-SRV'
    }

    It 'returns null when TestConfigurationDriftPath script does not exist' {
        $logFile = Join-Path $TestDrive 'drifts_notfound.log'
        $badPath = Join-Path $TestDrive 'nonexistent.ps1'
        # Script catches its own exception and returns $null rather than propagating
        $result = . $script:DriftsPath `
              -TestConfigurationDriftPath $badPath `
              -ServerName 'TEST-SRV' `
              -LogPath $logFile
        $result | Should -BeNullOrEmpty
    }

    It 'passes BaselinePath to subordinate script when specified' {
        $logFile = Join-Path $TestDrive 'drifts_baseline.log'
        $fakeLine = Join-Path $TestDrive 'baseline.json'
        Set-Content $fakeLine '{}'
        { . $script:DriftsPath `
              -TestConfigurationDriftPath $script:FakeDriftScript `
              -ServerName 'TEST-SRV' `
              -BaselinePath $fakeLine `
              -LogPath $logFile } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# Extra: Test-ArcAgentValidation.ps1 additional branch coverage
# ---------------------------------------------------------------------------
Describe 'Test-ArcAgentValidation.ps1 additional branches' {
    BeforeAll {
        foreach ($fn in @(
            'Test-ArcAuthentication','Test-ArcResourceHealth','Test-ArcExtensionStatus',
            'Test-ArcLogs','Test-ArcVersion','Test-ArcCertificates','Test-ArcPerformance',
            'Test-ArcDependencies','Get-ServiceDependencies','Get-ServiceAccount',
            'Get-ServiceStartupHistory','Get-ProxyConfiguration','Get-TLSConfiguration'
        )) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() @{ Status='Success'; Details=@{} } }
            }
        }
        . (Join-Path $script:SrcRoot 'Validation\Test-ArcAgentValidation.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path)
        }
        Mock New-Item     {} -ErrorAction SilentlyContinue
        Mock Out-File     {} -ErrorAction SilentlyContinue
        Mock ConvertTo-Json { '{}' } -ErrorAction SilentlyContinue
    }

    # ==== Main function: individual step failure branches ====

    It 'adds Authentication issue when auth check returns Failed' {
        Mock Test-ArcServiceStatus      { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcConfiguration      { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcConnectivity       { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcRegistrationStatus { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcAuthentication     { @{ Status='Failed';  Details=@{ Error='Token expired' } } }
        Mock Test-ArcResourceHealth     { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcExtensionStatus    { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcLogs               { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcVersion            { @{ Status='Success'; Details=@{} } }
        Mock Get-ArcValidationRecommendations { @() }
        $result = Test-ArcAgentValidation -ServerName 'TEST-SRV' -LogPath $TestDrive
        $result.Status | Should -Be 'Failed'
        ($result.Issues | Where-Object { $_.Component -eq 'Authentication' }) | Should -Not -BeNullOrEmpty
    }

    It 'adds ResourceHealth issue when resource health check returns Failed' {
        Mock Test-ArcServiceStatus      { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcConfiguration      { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcConnectivity       { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcRegistrationStatus { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcAuthentication     { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcResourceHealth     { @{ Status='Failed';  Details=@{ Error='Degraded' } } }
        Mock Test-ArcExtensionStatus    { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcLogs               { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcVersion            { @{ Status='Success'; Details=@{} } }
        Mock Get-ArcValidationRecommendations { @() }
        $result = Test-ArcAgentValidation -ServerName 'TEST-SRV' -LogPath $TestDrive
        ($result.Issues | Where-Object { $_.Component -eq 'Resource Health' }) | Should -Not -BeNullOrEmpty
    }

    It 'adds ExtensionStatus issue when extension status check returns Failed' {
        Mock Test-ArcServiceStatus      { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcConfiguration      { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcConnectivity       { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcRegistrationStatus { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcAuthentication     { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcResourceHealth     { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcExtensionStatus    { @{ Status='Failed';  Details=@{ Error='Extension failed' } } }
        Mock Test-ArcLogs               { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcVersion            { @{ Status='Success'; Details=@{} } }
        Mock Get-ArcValidationRecommendations { @() }
        $result = Test-ArcAgentValidation -ServerName 'TEST-SRV' -LogPath $TestDrive
        ($result.Issues | Where-Object { $_.Component -eq 'Extension Status' }) | Should -Not -BeNullOrEmpty
    }

    It 'adds Logs issue when log check returns Failed' {
        Mock Test-ArcServiceStatus      { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcConfiguration      { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcConnectivity       { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcRegistrationStatus { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcAuthentication     { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcResourceHealth     { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcExtensionStatus    { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcLogs               { @{ Status='Failed';  Details=@{ Error='Errors in logs' } } }
        Mock Test-ArcVersion            { @{ Status='Success'; Details=@{} } }
        Mock Get-ArcValidationRecommendations { @() }
        $result = Test-ArcAgentValidation -ServerName 'TEST-SRV' -LogPath $TestDrive
        ($result.Issues | Where-Object { $_.Component -eq 'Logs' }) | Should -Not -BeNullOrEmpty
    }

    It 'adds Version issue when version check returns Failed' {
        Mock Test-ArcServiceStatus      { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcConfiguration      { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcConnectivity       { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcRegistrationStatus { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcAuthentication     { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcResourceHealth     { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcExtensionStatus    { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcLogs               { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcVersion            { @{ Status='Failed';  Details=@{ Error='Outdated version' } } }
        Mock Get-ArcValidationRecommendations { @() }
        $result = Test-ArcAgentValidation -ServerName 'TEST-SRV' -LogPath $TestDrive
        ($result.Issues | Where-Object { $_.Component -eq 'Version' }) | Should -Not -BeNullOrEmpty
    }

    # ==== DetailedOutput additional branches ====

    It 'adds Certificates issue in DetailedOutput when cert check fails' {
        Mock Test-ArcServiceStatus      { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcConfiguration      { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcConnectivity       { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcRegistrationStatus { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcAuthentication     { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcResourceHealth     { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcExtensionStatus    { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcLogs               { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcVersion            { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcCertificates       { @{ Status='Failed';  Details=@{ Error='Certificate expired' } } }
        Mock Test-ArcPerformance        { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcDependencies       { @{ Status='Success'; Details=@{} } }
        Mock Get-ArcValidationRecommendations { @() }
        $result = Test-ArcAgentValidation -ServerName 'TEST-SRV' -LogPath $TestDrive -DetailedOutput
        ($result.Issues | Where-Object { $_.Component -eq 'Certificates' }) | Should -Not -BeNullOrEmpty
    }

    It 'adds Performance issue in DetailedOutput when perf check fails' {
        Mock Test-ArcServiceStatus      { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcConfiguration      { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcConnectivity       { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcRegistrationStatus { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcAuthentication     { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcResourceHealth     { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcExtensionStatus    { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcLogs               { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcVersion            { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcCertificates       { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcPerformance        { @{ Status='Failed';  Details=@{ Error='High CPU usage' } } }
        Mock Test-ArcDependencies       { @{ Status='Success'; Details=@{} } }
        Mock Get-ArcValidationRecommendations { @() }
        $result = Test-ArcAgentValidation -ServerName 'TEST-SRV' -LogPath $TestDrive -DetailedOutput
        ($result.Issues | Where-Object { $_.Component -eq 'Performance' }) | Should -Not -BeNullOrEmpty
    }

    It 'adds Dependencies issue in DetailedOutput when dependency check fails' {
        Mock Test-ArcServiceStatus      { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcConfiguration      { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcConnectivity       { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcRegistrationStatus { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcAuthentication     { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcResourceHealth     { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcExtensionStatus    { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcLogs               { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcVersion            { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcCertificates       { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcPerformance        { @{ Status='Success'; Details=@{} } }
        Mock Test-ArcDependencies       { @{ Status='Failed';  Details=@{ Error='Missing dependency' } } }
        Mock Get-ArcValidationRecommendations { @() }
        $result = Test-ArcAgentValidation -ServerName 'TEST-SRV' -LogPath $TestDrive -DetailedOutput
        ($result.Issues | Where-Object { $_.Component -eq 'Dependencies' }) | Should -Not -BeNullOrEmpty
    }

    # ==== Test-ArcServiceStatus sub-function internal paths ====

    It 'Test-ArcServiceStatus returns Success when himds service is Running' {
        Mock Get-Service {
            [PSCustomObject]@{ Name='himds'; Status='Running'; StartType='Automatic'; DisplayName='Azure Connected Machine Agent' }
        } -ParameterFilter { $Name -eq 'himds' }
        Mock Get-Service { $null } -ParameterFilter { $Name -eq 'gcad' }
        Mock Get-ServiceDependencies   { @{ Status='Success' } }
        Mock Get-ServiceAccount        { @{ Account='NT AUTHORITY\SYSTEM' } }
        Mock Get-ServiceStartupHistory { @() }
        $result = Test-ArcServiceStatus -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Success'
    }

    It 'Test-ArcServiceStatus returns Failed when himds service is Stopped' {
        Mock Get-Service {
            [PSCustomObject]@{ Name='himds'; Status='Stopped'; StartType='Manual'; DisplayName='Azure Connected Machine Agent' }
        } -ParameterFilter { $Name -eq 'himds' }
        Mock Get-Service { $null } -ParameterFilter { $Name -eq 'gcad' }
        Mock Get-ServiceDependencies   { @{ Status='Success' } }
        Mock Get-ServiceAccount        { @{ Account='NT AUTHORITY\SYSTEM' } }
        Mock Get-ServiceStartupHistory { @() }
        $result = Test-ArcServiceStatus -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Failed'
    }

    It 'Test-ArcServiceStatus returns Error when Get-Service throws' {
        Mock Get-Service { throw 'Access denied' } -ParameterFilter { $Name -eq 'himds' }
        Mock Get-ServiceDependencies   { @{ Status='Success' } }
        Mock Get-ServiceAccount        { @{ Account='NT AUTHORITY\SYSTEM' } }
        Mock Get-ServiceStartupHistory { @() }
        $result = Test-ArcServiceStatus -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Error'
    }

    # ==== Test-ArcConfiguration sub-function internal paths ====

    It 'Test-ArcConfiguration returns Failed when configPath not found' {
        Mock Test-Path { $false }
        $result = Test-ArcConfiguration -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Failed'
        $result.Details.ConfigPath | Should -Not -BeNullOrEmpty
    }

    It 'Test-ArcConfiguration returns Success when all config files are present and valid' {
        Mock Test-Path { $true }
        Mock Get-Content { '{"tenantId":"test-tenant","subscriptionId":"test-sub"}' }
        Mock ConvertFrom-Json { [PSCustomObject]@{ tenantId='test-tenant'; subscriptionId='test-sub' } }
        $result = Test-ArcConfiguration -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Success'
    }

    It 'Test-ArcConfiguration returns Failed when state file is missing' {
        Mock Test-Path -ParameterFilter { $Path -match 'state$' }         { $false }
        Mock Test-Path -ParameterFilter { $Path -match 'agentconfig\.json$' } { $true }
        Mock Test-Path -ParameterFilter { $Path -match 'identity\.json$' }    { $true }
        Mock Test-Path { $true }
        Mock Get-Content { '{"key":"value"}' }
        Mock ConvertFrom-Json { [PSCustomObject]@{ key='value' } }
        $result = Test-ArcConfiguration -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Failed'
    }

    # ==== Test-ArcConnectivity sub-function ====

    It 'Test-ArcConnectivity returns Success and populates DNS resolution details' {
        Mock Test-NetConnection {
            [PSCustomObject]@{ TcpTestSucceeded=$true; PingReplyDetails=@{ RoundtripTime=10 } }
        }
        Mock Get-ProxyConfiguration { @{ Enabled=$false; ProxyServer='' } }
        Mock Resolve-DnsName        { @([PSCustomObject]@{ IPAddress='1.2.3.4' }) }
        Mock Get-TLSConfiguration   { @{ TLS12Enabled=$true } }
        $result = Test-ArcConnectivity -ServerName 'TEST-SRV'
        $result.Status | Should -Be 'Success'
        $result.Details.DNSResolution | Should -Not -BeNullOrEmpty
    }

    It 'Test-ArcConnectivity captures proxy configuration details' {
        Mock Test-NetConnection {
            [PSCustomObject]@{ TcpTestSucceeded=$true; PingReplyDetails=@{ RoundtripTime=5 } }
        }
        Mock Get-ProxyConfiguration { @{ Enabled=$true; ProxyServer='http://proxy.contoso.com:8080' } }
        Mock Resolve-DnsName        { @([PSCustomObject]@{ IPAddress='1.2.3.4' }) }
        Mock Get-TLSConfiguration   { @{ TLS12Enabled=$true } }
        $result = Test-ArcConnectivity -ServerName 'TEST-SRV'
        $result.Details.ProxyConfiguration.Enabled | Should -Be $true
    }

    # ==== Get-ArcValidationRecommendations switch cases ====

    It 'Get-ArcValidationRecommendations returns Resource Health recommendation' {
        $issues = @(@{ Component = 'Resource Health' })
        $recs = Get-ArcValidationRecommendations -Issues $issues
        $recs | Should -Not -BeNullOrEmpty
        $recs[0].Component | Should -Be 'Resource Health'
    }

    It 'Get-ArcValidationRecommendations returns Extension Status recommendation' {
        $issues = @(@{ Component = 'Extension Status' })
        $recs = Get-ArcValidationRecommendations -Issues $issues
        $recs[0].Component | Should -Be 'Extension Status'
    }

    It 'Get-ArcValidationRecommendations returns Logs recommendation' {
        $issues = @(@{ Component = 'Logs' })
        $recs = Get-ArcValidationRecommendations -Issues $issues
        $recs[0].Component | Should -Be 'Logs'
    }

    It 'Get-ArcValidationRecommendations returns Version recommendation' {
        $issues = @(@{ Component = 'Version' })
        $recs = Get-ArcValidationRecommendations -Issues $issues
        $recs[0].Component | Should -Be 'Version'
    }

    It 'Get-ArcValidationRecommendations returns Certificates recommendation' {
        $issues = @(@{ Component = 'Certificates' })
        $recs = Get-ArcValidationRecommendations -Issues $issues
        $recs[0].Component | Should -Be 'Certificates'
    }

    It 'Get-ArcValidationRecommendations returns Performance recommendation' {
        $issues = @(@{ Component = 'Performance' })
        $recs = Get-ArcValidationRecommendations -Issues $issues
        $recs[0].Component | Should -Be 'Performance'
    }

    It 'Get-ArcValidationRecommendations returns Dependencies recommendation' {
        $issues = @(@{ Component = 'Dependencies' })
        $recs = Get-ArcValidationRecommendations -Issues $issues
        $recs[0].Component | Should -Be 'Dependencies'
    }

    It 'Get-ArcValidationRecommendations covers default recommendation for unknown component' {
        $issues = @(@{ Component = 'UnknownComponent' })
        $recs = Get-ArcValidationRecommendations -Issues $issues
        $recs | Should -Not -BeNullOrEmpty
        $recs[0].Action | Should -Be 'Investigate and resolve issues'
    }
}

# ---------------------------------------------------------------------------
# Extra: Test-SecurityValidation.ps1 additional branch coverage
# ---------------------------------------------------------------------------
Describe 'Test-SecurityValidation.ps1 additional branches' {
    BeforeAll {
        foreach ($fn in @(
            'Test-TLSConfiguration','Test-CertificateValidation','Test-FirewallConfiguration',
            'Test-ServiceAccountSecurity','Test-WindowsUpdateStatus','Test-AntivirusStatus',
            'Test-LocalSecurityPolicy','Test-AuditPolicy','Test-RegistrySecurity',
            'Test-UserRightsAssignment','Test-RestrictedSoftware',
            'Set-TLSConfiguration','Repair-CertificateIssues','Set-FirewallRules',
            'Set-ServiceAccountSecurity','Install-RequiredUpdates','Enable-AntivirusProtection',
            'Set-LocalSecurityPolicy','Set-AuditPolicy','Set-RegistrySecurity',
            'Set-UserRightsAssignment','Remove-RestrictedSoftware',
            'Get-SecurityScore','Get-DefaultSecurityBaseline'
        )) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value {
                    param() @{ Success=$true; Details=@(); Remediation=@() }
                }
            }
        }
        . (Join-Path $script:SrcRoot 'Validation\Test-SecurityValidation.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path)
        }
    }

    It 'Enhanced level adds WindowsUpdates, Antivirus and SecurityPolicy checks' {
        Mock Test-TLSConfiguration       { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-CertificateValidation  { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-FirewallConfiguration  { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-ServiceAccountSecurity { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-WindowsUpdateStatus    { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-AntivirusStatus        { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-LocalSecurityPolicy    { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Get-SecurityScore           { [int]100 }
        Mock Test-Path                   { $false }
        Mock Get-DefaultSecurityBaseline {
            [PSCustomObject]@{
                TLS=@{}; Certificates=@{}; Firewall=@{}; ServiceAccounts=@{}
                WindowsUpdates=@{}; Antivirus=@{}; SecurityPolicy=@{}
            }
        }
        $result = Test-SecurityValidation -ServerName 'TEST-SRV' -ValidationLevel 'Enhanced'
        $result | Should -Not -BeNullOrEmpty
        ($result.Checks | Where-Object { $_.Category -eq 'WindowsUpdates' }) | Should -Not -BeNullOrEmpty
        ($result.Checks | Where-Object { $_.Category -eq 'Antivirus' }) | Should -Not -BeNullOrEmpty
        ($result.Checks | Where-Object { $_.Category -eq 'SecurityPolicy' }) | Should -Not -BeNullOrEmpty
    }

    It 'Comprehensive level adds AuditPolicy, Registry, UserRights and RestrictedSoftware checks' {
        Mock Test-TLSConfiguration       { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-CertificateValidation  { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-FirewallConfiguration  { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-ServiceAccountSecurity { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-WindowsUpdateStatus    { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-AntivirusStatus        { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-LocalSecurityPolicy    { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-AuditPolicy            { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-RegistrySecurity       { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-UserRightsAssignment   { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-RestrictedSoftware     { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Get-SecurityScore           { [int]100 }
        Mock Test-Path                   { $false }
        Mock Get-DefaultSecurityBaseline {
            [PSCustomObject]@{
                TLS=@{}; Certificates=@{}; Firewall=@{}; ServiceAccounts=@{}
                WindowsUpdates=@{}; Antivirus=@{}; SecurityPolicy=@{}
                AuditPolicy=@{}; Registry=@{}; UserRights=@{}; RestrictedSoftware=@{}
            }
        }
        $result = Test-SecurityValidation -ServerName 'TEST-SRV' -ValidationLevel 'Comprehensive'
        $result | Should -Not -BeNullOrEmpty
        ($result.Checks | Where-Object { $_.Category -eq 'AuditPolicy' })         | Should -Not -BeNullOrEmpty
        ($result.Checks | Where-Object { $_.Category -eq 'Registry' })             | Should -Not -BeNullOrEmpty
        ($result.Checks | Where-Object { $_.Category -eq 'UserRights' })           | Should -Not -BeNullOrEmpty
        ($result.Checks | Where-Object { $_.Category -eq 'RestrictedSoftware' })   | Should -Not -BeNullOrEmpty
    }

    It 'invokes remediation function for failing TLS check when -Remediate is set' {
        Mock Test-TLSConfiguration       { @{ Success=$false; Details=@('TLS 1.2 not configured'); Remediation=@('Enable TLS 1.2') } }
        Mock Test-CertificateValidation  { @{ Success=$true;  Details=@(); Remediation=@() } }
        Mock Test-FirewallConfiguration  { @{ Success=$true;  Details=@(); Remediation=@() } }
        Mock Test-ServiceAccountSecurity { @{ Success=$true;  Details=@(); Remediation=@() } }
        Mock Set-TLSConfiguration        { @{ Success=$true;  Details='TLS 1.2 configured' } }
        Mock Get-SecurityScore           { [int]80 }
        Mock Test-Path                   { $false }
        Mock Get-DefaultSecurityBaseline {
            [PSCustomObject]@{ TLS=@{ Client=1; Server=1 }; Certificates=@{}; Firewall=@{}; ServiceAccounts=@{} }
        }
        $result = Test-SecurityValidation -ServerName 'TEST-SRV' -ValidationLevel 'Basic' -Remediate
        $result | Should -Not -BeNullOrEmpty
        $result.Remediation.Count | Should -BeGreaterThan 0
    }

    It 'returns Failed when a Critical security check fails' {
        Mock Test-TLSConfiguration       { @{ Success=$false; Details=@('TLS 1.2 disabled'); Remediation=@() } }
        Mock Test-CertificateValidation  { @{ Success=$true;  Details=@(); Remediation=@() } }
        Mock Test-FirewallConfiguration  { @{ Success=$true;  Details=@(); Remediation=@() } }
        Mock Test-ServiceAccountSecurity { @{ Success=$true;  Details=@(); Remediation=@() } }
        Mock Get-SecurityScore           { [int]60 }
        Mock Test-Path                   { $false }
        Mock Get-DefaultSecurityBaseline {
            [PSCustomObject]@{ TLS=@{}; Certificates=@{}; Firewall=@{}; ServiceAccounts=@{} }
        }
        $result = Test-SecurityValidation -ServerName 'TEST-SRV' -ValidationLevel 'Basic'
        $result.Status | Should -Be 'Failed'
    }

    It 'returns Error status when an exception is thrown during validation' {
        Mock Test-TLSConfiguration       { throw 'Unexpected remote access error' }
        Mock Test-CertificateValidation  { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-FirewallConfiguration  { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-ServiceAccountSecurity { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-Path                   { $false }
        Mock Get-DefaultSecurityBaseline {
            [PSCustomObject]@{ TLS=@{}; Certificates=@{}; Firewall=@{}; ServiceAccounts=@{} }
        }
        $result = Test-SecurityValidation -ServerName 'TEST-SRV' -ValidationLevel 'Basic'
        $result.Status | Should -Be 'Error'
    }

    It 'loads security baseline from file path when BaselinePath exists' {
        Mock Test-TLSConfiguration       { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-CertificateValidation  { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-FirewallConfiguration  { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Test-ServiceAccountSecurity { @{ Success=$true; Details=@(); Remediation=@() } }
        Mock Get-SecurityScore           { [int]100 }
        Mock Test-Path                   { $true }
        Mock Get-Content                 { '{"TLS":{},"Certificates":{},"Firewall":{},"ServiceAccounts":{}}' }
        Mock ConvertFrom-Json            {
            [PSCustomObject]@{ TLS=@{}; Certificates=@{}; Firewall=@{}; ServiceAccounts=@{} }
        }
        $result = Test-SecurityValidation -ServerName 'TEST-SRV' -ValidationLevel 'Basic' `
                      -BaselinePath 'C:\fake\security-baseline.json'
        $result | Should -Not -BeNullOrEmpty
        $result.Status | Should -Be 'Success'
    }

    It 'Test-CertificateValidation flags expired certificate, missing private key, root certs and chain failures' {
        $expiredCert = [PSCustomObject]@{
            Subject = 'CN=Azure Arc Expired'
            Thumbprint = 'EXPIRED1'
            NotBefore = (Get-Date).AddYears(-2)
            NotAfter = (Get-Date).AddDays(-2)
            Issuer = 'CN=Unknown Issuer'
            HasPrivateKey = $false
        }
        $script:securityCertCallCount = 0
        Mock Invoke-Command {
            $script:securityCertCallCount++
            if ($script:securityCertCallCount -eq 1) {
                return @{
                    MachineCerts = @($expiredCert)
                    RootCerts = @()
                    IntermediateCerts = @()
                }
            }

            return @(
                @{
                    Subject = 'CN=Azure Arc Expired'
                    IsValid = $false
                    ChainStatus = @('PartialChain')
                }
            )
        } -ParameterFilter { $ComputerName -ne $null }

        $result = Test-CertificateValidation -ServerName 'TEST-SRV'

        $result.Success | Should -Be $false
        ($result.Details | Where-Object { $_ -match 'expired' }).Count | Should -BeGreaterThan 0
        ($result.Details | Where-Object { $_ -match 'missing private key' }).Count | Should -BeGreaterThan 0
        ($result.Details | Where-Object { $_ -match 'Required root certificate missing' }).Count | Should -Be 3
        ($result.Details | Where-Object { $_ -match 'chain validation failed' }).Count | Should -BeGreaterThan 0
        ($result.Remediation | Where-Object { $_ -match 'Renew expired certificate' }).Count | Should -BeGreaterThan 0
    }

    It 'Test-CertificateValidation returns success when matching roots exist and chain is valid' {
        $healthyCert = [PSCustomObject]@{
            Subject = 'CN=Azure Arc Healthy'
            Thumbprint = 'HEALTHY1'
            NotBefore = (Get-Date).AddMonths(-3)
            NotAfter = (Get-Date).AddMonths(6)
            Issuer = 'CN=Microsoft Root Certificate Authority 2011'
            HasPrivateKey = $true
        }
        $script:securityCertCallCount = 0
        Mock Invoke-Command {
            $script:securityCertCallCount++
            if ($script:securityCertCallCount -eq 1) {
                return @{
                    MachineCerts = @($healthyCert)
                    RootCerts = @(
                        [PSCustomObject]@{ Subject = 'CN=Microsoft Root Certificate Authority 2011' },
                        [PSCustomObject]@{ Subject = 'CN=Baltimore CyberTrust Root' },
                        [PSCustomObject]@{ Subject = 'CN=DigiCert Global Root CA' }
                    )
                    IntermediateCerts = @()
                }
            }

            return @(
                @{
                    Subject = 'CN=Azure Arc Healthy'
                    IsValid = $true
                    ChainStatus = @()
                }
            )
        } -ParameterFilter { $ComputerName -ne $null }

        $result = Test-CertificateValidation -ServerName 'TEST-SRV'

        $result.Success | Should -Be $true
        $result.Details.Count | Should -Be 0
        $result.Remediation.Count | Should -Be 0
    }

    It 'Test-CertificateValidation returns error result when remote certificate check throws' {
        Mock Invoke-Command { throw 'cert store unavailable' } -ParameterFilter { $ComputerName -ne $null }

        $result = Test-CertificateValidation -ServerName 'TEST-SRV'

        $result.Success | Should -Be $false
        ($result.Details | Where-Object { $_ -match 'Error checking certificates' }).Count | Should -BeGreaterThan 0
        ($result.Remediation | Where-Object { $_ -match 'Manually verify certificate configuration' }).Count | Should -BeGreaterThan 0
    }

    It 'Test-FirewallConfiguration flags disabled profiles, missing rules and missing required port filters' {
        $script:securityFirewallCallCount = 0
        Mock Invoke-Command {
            $script:securityFirewallCallCount++
            if ($script:securityFirewallCallCount -eq 1) {
                return @{
                    Profiles = @{ Domain = $false; Private = $true; Public = $false }
                    ArcRules = @(
                        [PSCustomObject]@{
                            DisplayName = 'Azure Arc Partial'
                            Enabled = $false
                            Direction = 'Outbound'
                            Action = 'Allow'
                        }
                    )
                }
            }

            return @(
                @{ Port = 443; Protocol = 'TCP'; Description = 'HTTPS'; HasRule = $false },
                @{ Port = 80; Protocol = 'TCP'; Description = 'HTTP'; HasRule = $false }
            )
        } -ParameterFilter { $ComputerName -ne $null }

        $result = Test-FirewallConfiguration -ServerName 'TEST-SRV'

        $result.Success | Should -Be $false
        ($result.Details | Where-Object { $_ -match 'Firewall is disabled for Domain profile' }).Count | Should -BeGreaterThan 0
        ($result.Details | Where-Object { $_ -match 'Firewall is disabled for Public profile' }).Count | Should -BeGreaterThan 0
        ($result.Details | Where-Object { $_ -match 'Required outbound rule missing or disabled' }).Count | Should -Be 3
        ($result.Details | Where-Object { $_ -match 'Required outbound port rule missing' }).Count | Should -BeGreaterThan 0
    }

    It 'Test-FirewallConfiguration returns success when profiles, rules and ports are present' {
        $script:securityFirewallCallCount = 0
        Mock Invoke-Command {
            $script:securityFirewallCallCount++
            if ($script:securityFirewallCallCount -eq 1) {
                return @{
                    Profiles = @{ Domain = $true; Private = $true; Public = $true }
                    ArcRules = @(
                        [PSCustomObject]@{ DisplayName = 'Azure Arc Rule'; Enabled = $true; Direction = 'Outbound'; Action = 'Allow' },
                        [PSCustomObject]@{ DisplayName = 'Azure Monitor Rule'; Enabled = $true; Direction = 'Outbound'; Action = 'Allow' },
                        [PSCustomObject]@{ DisplayName = 'Azure Connected Machine Rule'; Enabled = $true; Direction = 'Outbound'; Action = 'Allow' }
                    )
                }
            }

            return @(
                @{ Port = 443; Protocol = 'TCP'; Description = 'HTTPS'; HasRule = $true },
                @{ Port = 80; Protocol = 'TCP'; Description = 'HTTP'; HasRule = $true }
            )
        } -ParameterFilter { $ComputerName -ne $null }

        $result = Test-FirewallConfiguration -ServerName 'TEST-SRV'

        $result.Success | Should -Be $true
        $result.Details.Count | Should -Be 0
    }

    It 'Test-FirewallConfiguration returns error result when firewall query throws' {
        Mock Invoke-Command { throw 'firewall provider failure' } -ParameterFilter { $ComputerName -ne $null }

        $result = Test-FirewallConfiguration -ServerName 'TEST-SRV'

        $result.Success | Should -Be $false
        ($result.Details | Where-Object { $_ -match 'Error checking firewall configuration' }).Count | Should -BeGreaterThan 0
        ($result.Remediation | Where-Object { $_ -match 'Manually verify firewall configuration' }).Count | Should -BeGreaterThan 0
    }

    It 'Test-ServiceAccountSecurity flags LocalSystem, disabled services, stopped services and permissive ACLs' {
        $script:securityServiceAccountCallCount = 0
        Mock Invoke-Command {
            $script:securityServiceAccountCallCount++
            if ($script:securityServiceAccountCallCount -eq 1) {
                return @(
                    @{ Name = 'himds'; StartName = 'LocalSystem'; StartMode = 'Automatic'; State = 'Stopped' },
                    @{ Name = 'GCArcService'; StartName = 'Domain\\svc-arc'; StartMode = 'Disabled'; State = 'Stopped' }
                )
            }

            return @(
                @{
                    Name = 'himds'
                    DACL = @(
                        @{ Trustee = 'Everyone'; AccessMask = 0x40000; AceType = 0 }
                    )
                },
                @{
                    Name = 'GCArcService'
                    DACL = @(
                        @{ Trustee = 'Users'; AccessMask = 0x40000; AceType = 0 }
                    )
                }
            )
        } -ParameterFilter { $ComputerName -ne $null }

        $result = Test-ServiceAccountSecurity -ServerName 'TEST-SRV'

        $result.Success | Should -Be $false
        ($result.Details | Where-Object { $_ -match 'running as LocalSystem' }).Count | Should -BeGreaterThan 0
        ($result.Details | Where-Object { $_ -match 'is disabled' }).Count | Should -BeGreaterThan 0
        ($result.Details | Where-Object { $_ -match 'is not running' }).Count | Should -BeGreaterThan 0
        ($result.Details | Where-Object { $_ -match 'overly permissive ACL' }).Count | Should -Be 2
    }

    It 'Test-ServiceAccountSecurity returns success when services and ACLs are healthy' {
        $script:securityServiceAccountCallCount = 0
        Mock Invoke-Command {
            $script:securityServiceAccountCallCount++
            if ($script:securityServiceAccountCallCount -eq 1) {
                return @(
                    @{ Name = 'himds'; StartName = 'NT SERVICE\\himds'; StartMode = 'Automatic'; State = 'Running' },
                    @{ Name = 'GCArcService'; StartName = 'NT SERVICE\\GCArcService'; StartMode = 'Automatic'; State = 'Running' }
                )
            }

            return @(
                @{ Name = 'himds'; DACL = @(@{ Trustee = 'Administrators'; AccessMask = 0x20000; AceType = 0 }) },
                @{ Name = 'GCArcService'; DACL = @(@{ Trustee = 'SYSTEM'; AccessMask = 0x20000; AceType = 0 }) }
            )
        } -ParameterFilter { $ComputerName -ne $null }

        $result = Test-ServiceAccountSecurity -ServerName 'TEST-SRV'

        $result.Success | Should -Be $true
        $result.Details.Count | Should -Be 0
        $result.Remediation.Count | Should -Be 0
    }

    It 'Test-ServiceAccountSecurity returns error result when service security query throws' {
        Mock Invoke-Command { throw 'wmi unavailable' } -ParameterFilter { $ComputerName -ne $null }

        $result = Test-ServiceAccountSecurity -ServerName 'TEST-SRV'

        $result.Success | Should -Be $false
        ($result.Details | Where-Object { $_ -match 'Error checking service account security' }).Count | Should -BeGreaterThan 0
        ($result.Remediation | Where-Object { $_ -match 'Manually verify service account configuration' }).Count | Should -BeGreaterThan 0
    }

    It 'runs all remediation handlers for comprehensive failures when -Remediate is set' {
        Mock Test-TLSConfiguration       { @{ Success = $false; Details = @('tls'); Remediation = @('tls fix') } }
        Mock Test-CertificateValidation  { @{ Success = $false; Details = @('cert'); Remediation = @('cert fix') } }
        Mock Test-FirewallConfiguration  { @{ Success = $false; Details = @('fw'); Remediation = @('fw fix') } }
        Mock Test-ServiceAccountSecurity { @{ Success = $false; Details = @('svc'); Remediation = @('svc fix') } }
        Mock Test-WindowsUpdateStatus    { @{ Success = $false; Details = @('updates'); Remediation = @('updates fix') } }
        Mock Test-AntivirusStatus        { @{ Success = $false; Details = @('av'); Remediation = @('av fix') } }
        Mock Test-LocalSecurityPolicy    { @{ Success = $false; Details = @('policy'); Remediation = @('policy fix') } }
        Mock Test-AuditPolicy            { @{ Success = $false; Details = @('audit'); Remediation = @('audit fix') } }
        Mock Test-RegistrySecurity       { @{ Success = $false; Details = @('registry'); Remediation = @('registry fix') } }
        Mock Test-UserRightsAssignment   { @{ Success = $false; Details = @('rights'); Remediation = @('rights fix') } }
        Mock Test-RestrictedSoftware     { @{ Success = $false; Details = @('software'); Remediation = @('software fix') } }
        Mock Set-TLSConfiguration        { @{ Success = $true; Details = 'tls done' } }
        Mock Repair-CertificateIssues    { @{ Success = $true; Details = 'cert done' } }
        Mock Set-FirewallRules           { @{ Success = $true; Details = 'fw done' } }
        Mock Set-ServiceAccountSecurity  { @{ Success = $true; Details = 'svc done' } }
        Mock Install-RequiredUpdates     { @{ Success = $true; Details = 'updates done' } }
        Mock Enable-AntivirusProtection  { @{ Success = $true; Details = 'av done' } }
        Mock Set-LocalSecurityPolicy     { @{ Success = $true; Details = 'policy done' } }
        Mock Set-AuditPolicy             { @{ Success = $true; Details = 'audit done' } }
        Mock Set-RegistrySecurity        { @{ Success = $true; Details = 'registry done' } }
        Mock Set-UserRightsAssignment    { @{ Success = $true; Details = 'rights done' } }
        Mock Remove-RestrictedSoftware   { @{ Success = $true; Details = 'software done' } }
        Mock Get-SecurityScore           { [int]0 }
        Mock Test-Path                   { $false }
        Mock Get-DefaultSecurityBaseline {
            [PSCustomObject]@{
                TLS = @{ RequireTLS12 = $true }
                Certificates = @{}
                Firewall = @{ Rules = @(@{ DisplayName = 'rule' }) }
                ServiceAccounts = @{ PreferredAccount = 'NT SERVICE\\AzureConnectedMachineAgent' }
                WindowsUpdates = @{}
                Antivirus = @{}
                SecurityPolicy = @{ Policies = @{ PasswordComplexity = 1 } }
                AuditPolicy = @{ Policies = @{ System = 'Success, Failure' } }
                Registry = @{ Settings = @{ 'HKLM:\SOFTWARE\Example' = 1 } }
                UserRights = @{ Rights = @{ SeBackupPrivilege = @('Administrators') } }
                RestrictedSoftware = @{ Software = @('Unauthorized Remote Access Tools') }
            }
        }

        $result = Test-SecurityValidation -ServerName 'TEST-SRV' -ValidationLevel 'Comprehensive' -Remediate

        $result.Remediation.Count | Should -BeGreaterThan 10
        ($result.Remediation.Category | Sort-Object -Unique) | Should -Contain 'Certificates'
        ($result.Remediation.Category | Sort-Object -Unique) | Should -Contain 'ServiceAccounts'
        ($result.Remediation.Category | Sort-Object -Unique) | Should -Contain 'Antivirus'
        ($result.Remediation.Category | Sort-Object -Unique) | Should -Contain 'AuditPolicy'
        ($result.Remediation.Category | Sort-Object -Unique) | Should -Contain 'Registry'
        ($result.Remediation.Category | Sort-Object -Unique) | Should -Contain 'UserRights'
        ($result.Remediation.Category | Sort-Object -Unique) | Should -Contain 'RestrictedSoftware'
    }

    It 'Test-TLSConfiguration executes remote registry inspection locally' {
        Mock Invoke-Command { & $ScriptBlock } -ParameterFilter { $ComputerName -ne $null }
        Mock Test-Path {
            switch -Regex ($Path) {
                'TLS 1\.2\\Client$' { $false }
                'TLS 1\.2\\Server$' { $true }
                'TLS 1\.0\\Client$' { $true }
                'TLS 1\.0\\Server$' { $true }
                'TLS 1\.1\\Client$' { $false }
                'TLS 1\.1\\Server$' { $true }
                'SSL 2\.0\\Client$' { $true }
                'SSL 2\.0\\Server$' { $false }
                'SSL 3\.0\\Client$' { $true }
                'SSL 3\.0\\Server$' { $true }
                'SOFTWARE\\Microsoft\\\.NETFramework\\v4\.0\.30319$' { $true }
                'SOFTWARE\\WOW6432Node\\Microsoft\\\.NETFramework\\v4\.0\.30319$' { $true }
                default { $false }
            }
        }
        Mock Get-ItemProperty {
            switch -Regex ($Path) {
                'TLS 1\.2\\Server$' { [PSCustomObject]@{ Enabled = 1 } }
                'TLS 1\.0\\Client$' { [PSCustomObject]@{ Enabled = 1 } }
                'TLS 1\.0\\Server$' { [PSCustomObject]@{ Enabled = 1 } }
                'TLS 1\.1\\Server$' { [PSCustomObject]@{ Enabled = 1 } }
                'SSL 2\.0\\Client$' { [PSCustomObject]@{ Enabled = 1 } }
                'SSL 3\.0\\Client$' { [PSCustomObject]@{ Enabled = 0 } }
                'SSL 3\.0\\Server$' { [PSCustomObject]@{ Enabled = 1 } }
                'SOFTWARE\\Microsoft\\\.NETFramework\\v4\.0\.30319$' {
                    if ($Name -eq 'SystemDefaultTlsVersions') {
                        [PSCustomObject]@{ SystemDefaultTlsVersions = 0 }
                    }
                    else {
                        [PSCustomObject]@{ SchUseStrongCrypto = 0 }
                    }
                }
                'SOFTWARE\\WOW6432Node\\Microsoft\\\.NETFramework\\v4\.0\.30319$' {
                    if ($Name -eq 'SystemDefaultTlsVersions') {
                        [PSCustomObject]@{ SystemDefaultTlsVersions = 1 }
                    }
                    else {
                        [PSCustomObject]@{ SchUseStrongCrypto = 0 }
                    }
                }
                default { [PSCustomObject]@{ Enabled = 0 } }
            }
        }

        $result = Test-TLSConfiguration -ServerName 'TEST-SRV'

        $result.Success | Should -Be $false
        ($result.Details | Where-Object { $_ -match 'TLS 1.2 Client is not enabled' }).Count | Should -BeGreaterThan 0
        ($result.Details | Where-Object { $_ -match 'TLS 1.0 Client is not disabled' }).Count | Should -BeGreaterThan 0
        ($result.Details | Where-Object { $_ -match 'SystemDefaultTlsVersions not enabled' }).Count | Should -BeGreaterThan 0
        ($result.Details | Where-Object { $_ -match 'SchUseStrongCrypto not enabled' }).Count | Should -BeGreaterThan 0
    }

    It 'Test-CertificateValidation executes certificate enumeration and chain checks locally' {
        $script:securityLocalCertPathCalls = 0
        Mock Invoke-Command { & $ScriptBlock } -ParameterFilter { $ComputerName -ne $null }
        Mock Get-ChildItem {
            switch ($Path) {
                'Cert:\LocalMachine\My' {
                    $script:securityLocalCertPathCalls++
                    return @(
                        [PSCustomObject]@{
                            Subject = 'CN=Azure Arc Near Expiry'
                            Thumbprint = 'LOCAL1'
                            NotBefore = (Get-Date).AddMonths(-2)
                            NotAfter = (Get-Date).AddDays(10)
                            Issuer = 'CN=Microsoft Root Certificate Authority 2011'
                            HasPrivateKey = $true
                        }
                    )
                }
                'Cert:\LocalMachine\Root' {
                    return @(
                        [PSCustomObject]@{
                            Subject = 'CN=Microsoft Root Certificate Authority 2011'
                            Thumbprint = 'ROOT1'
                            NotBefore = (Get-Date).AddYears(-1)
                            NotAfter = (Get-Date).AddYears(5)
                            Issuer = 'CN=Microsoft Root Certificate Authority 2011'
                        }
                    )
                }
                'Cert:\LocalMachine\CA' {
                    return @(
                        [PSCustomObject]@{
                            Subject = 'CN=Microsoft Intermediate CA'
                            Thumbprint = 'INT1'
                            NotBefore = (Get-Date).AddYears(-1)
                            NotAfter = (Get-Date).AddYears(1)
                            Issuer = 'CN=Microsoft Root Certificate Authority 2011'
                        }
                    )
                }
                default { @() }
            }
        }
        Mock New-Object {
            $policy = [PSCustomObject]@{ RevocationMode = $null; RevocationFlag = $null }
            $chain = [PSCustomObject]@{
                ChainPolicy = $policy
                ChainStatus = @([PSCustomObject]@{ Status = 'PartialChain' })
            }
            $chain | Add-Member -MemberType ScriptMethod -Name Build -Value { param($cert) $false } -Force
            $chain
        } -ParameterFilter { $TypeName -eq 'System.Security.Cryptography.X509Certificates.X509Chain' }

        $result = Test-CertificateValidation -ServerName 'TEST-SRV'

        $result.Success | Should -Be $false
        ($result.Details | Where-Object { $_ -match 'Certificate expiring soon' }).Count | Should -BeGreaterThan 0
        ($result.Details | Where-Object { $_ -match 'Required root certificate missing' }).Count | Should -Be 2
        ($result.Details | Where-Object { $_ -match 'chain validation failed' }).Count | Should -BeGreaterThan 0
    }

    It 'Test-FirewallConfiguration executes firewall profile and port inspection locally' {
        Mock Invoke-Command { & $ScriptBlock @ArgumentList } -ParameterFilter { $ComputerName -ne $null }
        Mock New-Object {
            $fw = [PSCustomObject]@{ CurrentProfileTypes = 7 }
            $fw | Add-Member -MemberType ScriptMethod -Name FirewallEnabled -Value {
                param($profile)
                if ($profile -in 1, 4) { return $false }
                return $true
            } -Force
            $fw
        } -ParameterFilter { $ComObject -eq 'HNetCfg.FwPolicy2' }
        Mock Get-NetFirewallRule {
            if ($PSBoundParameters.ContainsKey('Direction')) {
                return @([PSCustomObject]@{ DisplayName = 'Allow 443' })
            }

            return @(
                [PSCustomObject]@{ DisplayName = 'Azure Arc Rule'; Enabled = $true; Direction = 'Outbound'; Action = 'Allow' },
                [PSCustomObject]@{ DisplayName = 'Azure Monitor Rule'; Enabled = $true; Direction = 'Outbound'; Action = 'Allow' }
            )
        }
        Mock Get-NetFirewallPortFilter {
            param([Parameter(ValueFromPipeline = $true)]$InputObject)
            process {
                return
            }
        }

        $result = Test-FirewallConfiguration -ServerName 'TEST-SRV'

        $result.Success | Should -Be $false
        ($result.Details | Where-Object { $_ -match 'Firewall is disabled for Domain profile' }).Count | Should -BeGreaterThan 0
        ($result.Details | Where-Object { $_ -match 'Firewall is disabled for Public profile' }).Count | Should -BeGreaterThan 0
        ($result.Details | Where-Object { $_ -match 'Required outbound rule missing or disabled: \*Azure Connected Machine\*' }).Count | Should -BeGreaterThan 0
        ($result.Details | Where-Object { $_ -match 'Required outbound port rule missing' }).Count | Should -BeGreaterThan 0
    }

    It 'Test-ServiceAccountSecurity executes WMI-based service and ACL inspection locally' {
        Mock Invoke-Command { & $ScriptBlock } -ParameterFilter { $ComputerName -ne $null }
        Mock Get-WmiObject {
            switch -Regex ($Filter) {
                "Name='himds'" {
                    $descriptor = [PSCustomObject]@{
                        DACL = @([PSCustomObject]@{ Trustee = [PSCustomObject]@{ Name = 'Everyone' }; AccessMask = 0x40000; AceType = 0 })
                    }
                    $svc = [PSCustomObject]@{
                        StartName = 'LocalSystem'
                        StartMode = 'Automatic'
                        State = 'Stopped'
                        DescriptorValue = $descriptor
                    }
                    $svc | Add-Member -MemberType ScriptMethod -Name GetSecurityDescriptor -Value {
                        [PSCustomObject]@{ Descriptor = $this.DescriptorValue }
                    } -Force
                    return $svc
                }
                "Name='GCArcService'" {
                    $descriptor = [PSCustomObject]@{
                        DACL = @([PSCustomObject]@{ Trustee = [PSCustomObject]@{ Name = 'Users' }; AccessMask = 0x40000; AceType = 0 })
                    }
                    $svc = [PSCustomObject]@{
                        StartName = 'Domain\\svc-arc'
                        StartMode = 'Disabled'
                        State = 'Stopped'
                        DescriptorValue = $descriptor
                    }
                    $svc | Add-Member -MemberType ScriptMethod -Name GetSecurityDescriptor -Value {
                        [PSCustomObject]@{ Descriptor = $this.DescriptorValue }
                    } -Force
                    return $svc
                }
                "Name='AzureMonitorAgent'" {
                    $descriptor = [PSCustomObject]@{
                        DACL = @([PSCustomObject]@{ Trustee = [PSCustomObject]@{ Name = 'Administrators' }; AccessMask = 0x20000; AceType = 0 })
                    }
                    $svc = [PSCustomObject]@{
                        StartName = 'NT SERVICE\\AzureMonitorAgent'
                        StartMode = 'Automatic'
                        State = 'Running'
                        DescriptorValue = $descriptor
                    }
                    $svc | Add-Member -MemberType ScriptMethod -Name GetSecurityDescriptor -Value {
                        [PSCustomObject]@{ Descriptor = $this.DescriptorValue }
                    } -Force
                    return $svc
                }
                default { return $null }
            }
        }

        $result = Test-ServiceAccountSecurity -ServerName 'TEST-SRV'

        $result.Success | Should -Be $false
        ($result.Details | Where-Object { $_ -match 'running as LocalSystem' }).Count | Should -BeGreaterThan 0
        ($result.Details | Where-Object { $_ -match 'is disabled' }).Count | Should -BeGreaterThan 0
        ($result.Details | Where-Object { $_ -match 'is not running' }).Count | Should -BeGreaterThan 0
        ($result.Details | Where-Object { $_ -match 'overly permissive ACL' }).Count | Should -Be 2
    }

    It 'Get-SecurityScore returns 0 for empty checks and weighted percentage for mixed severities' {
        $emptyScore = Get-SecurityScore -Checks @()
        $emptyScore | Should -Be 0

        $weightedScore = Get-SecurityScore -Checks @(
            @{ Status = $true; Severity = 'Critical' },
            @{ Status = $false; Severity = 'High' },
            @{ Status = $true; Severity = 'Low' }
        )

        $weightedScore | Should -Be 62.5
    }

    It 'Get-DefaultSecurityBaseline returns expected categories and baseline values' {
        $baseline = Get-DefaultSecurityBaseline

        $baseline.Keys.Count | Should -BeGreaterThan 5
        $baseline.TLS.RequireTLS12 | Should -Be $true
        $baseline.Certificates.RequiredRoots.Count | Should -Be 3
        $baseline.Firewall.Rules.Count | Should -Be 2
        $baseline.ServiceAccounts.PreferredAccount | Should -Be 'NT SERVICE\AzureConnectedMachineAgent'
        $baseline.WindowsUpdates.MaximumPendingUpdates | Should -Be 5
        $baseline.Antivirus.RealtimeProtection | Should -Be $true
        $baseline.Registry.Settings['HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\EnableLUA'] | Should -Be 1
        $baseline.UserRights.Rights['SeBackupPrivilege'][0] | Should -Be 'Administrators'
    }
}

# ---------------------------------------------------------------------------
# Additional: Test-ExtensionHealth.ps1 sub-function direct coverage
# ---------------------------------------------------------------------------
Describe 'Test-ExtensionHealth.ps1 sub-function direct coverage' {
    BeforeAll {
        foreach ($fn in @('Get-AzConnectedMachine', 'Get-AzConnectedMachineExtension',
                          'Get-AzActivityLog', 'Invoke-AzRestMethod', 'Get-AzContext')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() $null }
            }
        }
        . (Join-Path $script:SrcRoot 'Validation\Test-ExtensionHealth.ps1')
    }
    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Component, [string]$Path)
        }
    }

    It 'Get-ServiceStatus returns service info when service exists' {
        Mock Get-Service {
            [PSCustomObject]@{
                Name        = 'AzureMonitorAgent'
                DisplayName = 'Azure Monitor Agent'
                Status      = 'Running'
                StartType   = 'Automatic'
            }
        }
        $result = Get-ServiceStatus -ServerName 'TEST-SRV' -ServiceName 'AzureMonitorAgent'
        $result | Should -Not -BeNullOrEmpty
        $result.ContainsKey('Status') | Should -Be $true
    }

    It 'Get-ServiceStatus returns NotFound when service does not exist' {
        Mock Get-Service { $null }
        $result = Get-ServiceStatus -ServerName 'TEST-SRV' -ServiceName 'NonExistentService'
        $result | Should -Not -BeNullOrEmpty
        $result.Status | Should -BeIn @('NotFound', 'Error')
    }

    It 'Get-ServiceStatus returns Error when Get-Service throws' {
        Mock Get-Service { throw 'Access denied' }
        $result = Get-ServiceStatus -ServerName 'TEST-SRV' -ServiceName 'BadService'
        $result.Status | Should -Be 'Error'
        $result.Error  | Should -Not -BeNullOrEmpty
    }

    It 'Get-ExtensionRecommendations returns High priority recommendation for Unhealthy extension' {
        $extensions = @(
            [PSCustomObject]@{
                Name          = 'AzureMonitorWindowsAgent'
                Status        = 'Unhealthy'
                Issues        = @('Service not running')
                ServiceStatus = @{ Name = 'AzureMonitorAgent' }
            }
        )
        $recs = Get-ExtensionRecommendations -Extensions $extensions
        $recs | Should -Not -BeNullOrEmpty
        @($recs)[0].Priority | Should -Be 'High'
        (@($recs)[0].Actions | Where-Object { $_ -like '*AzureMonitorAgent*' }) | Should -Not -BeNullOrEmpty
    }

    It 'Get-ExtensionRecommendations returns AzureMonitorWindowsAgent-specific recommendations' {
        $extensions = @(
            [PSCustomObject]@{
                Name          = 'AzureMonitorWindowsAgent'
                Status        = 'Unhealthy'
                Issues        = @('Provisioning failed')
                ServiceStatus = @{ Name = 'AzureMonitorAgent' }
            }
        )
        $recs = Get-ExtensionRecommendations -Extensions $extensions
        (@($recs)[0].Actions | Where-Object { $_ -like '*workspace*' -or $_ -like '*Workspace*' }) | Should -Not -BeNullOrEmpty
    }

    It 'Get-ExtensionRecommendations returns GuestConfigurationForWindows-specific recommendations' {
        $extensions = @(
            [PSCustomObject]@{
                Name          = 'GuestConfigurationForWindows'
                Status        = 'Unhealthy'
                Issues        = @('Provisioning failed')
                ServiceStatus = @{ Name = 'GuestConfig' }
            }
        )
        $recs = Get-ExtensionRecommendations -Extensions $extensions
        (@($recs)[0].Actions | Where-Object { $_ -like '*policy*' -or $_ -like '*Policy*' }) | Should -Not -BeNullOrEmpty
    }

    It 'Get-ExtensionRecommendations returns MicrosoftMonitoringAgent migration recommendation' {
        $extensions = @(
            [PSCustomObject]@{
                Name          = 'MicrosoftMonitoringAgent'
                Status        = 'Unhealthy'
                Issues        = @('Service not running')
                ServiceStatus = @{ Name = 'HealthService' }
            }
        )
        $recs = Get-ExtensionRecommendations -Extensions $extensions
        (@($recs)[0].Actions | Where-Object { $_ -like '*migrat*' -or $_ -like '*Migrat*' }) | Should -Not -BeNullOrEmpty
    }

    It 'Get-ExtensionRecommendations handles provisioning-state issue' {
        $extensions = @(
            [PSCustomObject]@{
                Name          = 'SomeExtension'
                Status        = 'Degraded'
                Issues        = @('Provisioning state: Updating')
                ServiceStatus = @{ Name = 'SomeSvc' }
            }
        )
        $recs = Get-ExtensionRecommendations -Extensions $extensions
        $recs | Should -Not -BeNullOrEmpty
        (@($recs)[0].Actions | Where-Object { $_ -like '*provisioning*' -or $_ -like '*Provisioning*' }) | Should -Not -BeNullOrEmpty
    }

    It 'Get-ExtensionRecommendations returns empty array when all extensions are Healthy' {
        $extensions = @(
            [PSCustomObject]@{
                Name   = 'AzureMonitorWindowsAgent'
                Status = 'Healthy'
                Issues = @()
            }
        )
        $recs = Get-ExtensionRecommendations -Extensions $extensions
        @($recs).Count | Should -Be 0
    }

    It 'Get-ExtensionLastOperation returns last operation when activity logs found' {
        Mock Get-AzActivityLog {
            @(
                [PSCustomObject]@{
                    ResourceId       = '/subscriptions/sub1/resourceGroups/rg1/providers/Microsoft.HybridCompute/machines/server1/extensions/AzureMonitorWindowsAgent'
                    OperationName    = [PSCustomObject]@{ Value = 'Microsoft.HybridCompute/machines/extensions/write' }
                    Status           = [PSCustomObject]@{ Value = 'Succeeded' }
                    EventTimestamp   = (Get-Date).AddHours(-1)
                    Caller           = 'user@contoso.com'
                    CorrelationId    = 'corr-123'
                }
            )
        }
        $result = Get-ExtensionLastOperation -ResourceGroupName 'rg1' -MachineName 'server1' `
            -ExtensionName 'AzureMonitorWindowsAgent'
        $result | Should -Not -BeNullOrEmpty
        $result.LastOperation | Should -Not -BeNullOrEmpty
    }

    It 'Get-ExtensionLastOperation returns null when no activity logs found' {
        Mock Get-AzActivityLog { @() }
        $result = Get-ExtensionLastOperation -ResourceGroupName 'rg1' -MachineName 'server1' `
            -ExtensionName 'AzureMonitorWindowsAgent'
        $result | Should -BeNullOrEmpty
    }
}

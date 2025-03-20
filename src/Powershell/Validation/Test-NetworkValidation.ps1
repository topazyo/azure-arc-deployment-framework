function Test-NetworkValidation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [switch]$DetailedOutput,
        [Parameter()]
        [int]$TimeoutSeconds = 30,
        [Parameter()]
        [string]$ConfigPath = ".\Config\network-validation.json"
    )

    begin {
        $validationResults = @{
            ServerName = $ServerName
            StartTime = Get-Date
            Status = "Unknown"
            Details = @()
            Recommendations = @()
        }

        # Load network validation configuration
        try {
            if (Test-Path $ConfigPath) {
                $networkConfig = Get-Content $ConfigPath | ConvertFrom-Json
            }
            else {
                # Default configuration if file not found
                $networkConfig = @{
                    RequiredEndpoints = @(
                        @{
                            Name = "Azure Resource Manager"
                            Url = "management.azure.com"
                            Port = 443
                            Critical = $true
                        },
                        @{
                            Name = "Azure Login"
                            Url = "login.microsoftonline.com"
                            Port = 443
                            Critical = $true
                        },
                        @{
                            Name = "Azure Monitor"
                            Url = "global.handler.control.monitor.azure.com"
                            Port = 443
                            Critical = $true
                        },
                        @{
                            Name = "Log Analytics"
                            Url = "*.ods.opinsights.azure.com"
                            Port = 443
                            Critical = $true
                        }
                    )
                    ProxyValidation = $true
                    TLSValidation = $true
                    DNSValidation = $true
                    LatencyThresholdMs = 300
                    PacketLossThreshold = 5
                }
            }
        }
        catch {
            Write-Error "Failed to load network validation configuration: $_"
            $validationResults.Status = "Error"
            $validationResults.Error = "Configuration load failure: $($_.Exception.Message)"
            return [PSCustomObject]$validationResults
        }

        Write-Log -Message "Starting network validation for $ServerName" -Level Information
    }

    process {
        try {
            # 1. Endpoint Connectivity Tests
            $endpointResults = Test-EndpointConnectivity -ServerName $ServerName -Endpoints $networkConfig.RequiredEndpoints -Timeout $TimeoutSeconds
            $validationResults.Details += @{
                Component = "Endpoints"
                Results = $endpointResults
                Success = $endpointResults.OverallSuccess
            }

            # 2. DNS Resolution Tests
            if ($networkConfig.DNSValidation) {
                $dnsResults = Test-DNSResolution -ServerName $ServerName -Endpoints $networkConfig.RequiredEndpoints
                $validationResults.Details += @{
                    Component = "DNS"
                    Results = $dnsResults
                    Success = $dnsResults.OverallSuccess
                }
            }

            # 3. Proxy Configuration Tests
            if ($networkConfig.ProxyValidation) {
                $proxyResults = Test-ProxyConfiguration -ServerName $ServerName
                $validationResults.Details += @{
                    Component = "Proxy"
                    Results = $proxyResults
                    Success = $proxyResults.Success
                }
            }

            # 4. TLS Configuration Tests
            if ($networkConfig.TLSValidation) {
                $tlsResults = Test-TLSConfiguration -ServerName $ServerName
                $validationResults.Details += @{
                    Component = "TLS"
                    Results = $tlsResults
                    Success = $tlsResults.Success
                }
            }

            # 5. Network Performance Tests
            $performanceResults = Test-NetworkPerformance -ServerName $ServerName -Endpoints $networkConfig.RequiredEndpoints -LatencyThreshold $networkConfig.LatencyThresholdMs -PacketLossThreshold $networkConfig.PacketLossThreshold
            $validationResults.Details += @{
                Component = "Performance"
                Results = $performanceResults
                Success = $performanceResults.Success
            }

            # 6. Firewall Configuration Tests
            $firewallResults = Test-FirewallConfiguration -ServerName $ServerName
            $validationResults.Details += @{
                Component = "Firewall"
                Results = $firewallResults
                Success = $firewallResults.Success
            }

            # 7. Network Route Tests (if detailed output requested)
            if ($DetailedOutput) {
                $routeResults = Test-NetworkRoutes -ServerName $ServerName
                $validationResults.Details += @{
                    Component = "Routes"
                    Results = $routeResults
                    Success = $routeResults.Success
                }
            }

            # Determine overall status
            $criticalComponents = $validationResults.Details | 
                Where-Object { 
                    $_.Component -in @("Endpoints", "DNS", "Proxy", "TLS") -and 
                    -not $_.Success 
                }
            
            $validationResults.Status = if ($criticalComponents.Count -eq 0) {
                "Success"
            }
            else {
                "Failed"
            }

            # Generate recommendations
            $validationResults.Recommendations = Get-NetworkRecommendations -ValidationResults $validationResults.Details
        }
        catch {
            $validationResults.Status = "Error"
            $validationResults.Error = $_.Exception.Message
            Write-Error "Network validation failed: $_"
        }
    }

    end {
        $validationResults.EndTime = Get-Date
        $validationResults.Duration = $validationResults.EndTime - $validationResults.StartTime
        return [PSCustomObject]$validationResults
    }
}

function Test-EndpointConnectivity {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter(Mandatory)]
        [array]$Endpoints,
        [Parameter()]
        [int]$Timeout = 30
    )

    $results = @{
        Endpoints = @()
        OverallSuccess = $true
        CriticalFailures = 0
    }

    try {
        foreach ($endpoint in $Endpoints) {
            $endpointUrl = $endpoint.Url -replace '\*', 'dc'  # Replace wildcard with 'dc' for testing
            
            # Test TCP connectivity
            $tcpTest = Invoke-Command -ComputerName $ServerName -ScriptBlock {
                param($url, $port, $timeout)
                
                $tcpClient = New-Object System.Net.Sockets.TcpClient
                $connection = $tcpClient.BeginConnect($url, $port, $null, $null)
                $success = $connection.AsyncWaitHandle.WaitOne($timeout * 1000, $true)
                
                if ($success) {
                    $tcpClient.EndConnect($connection)
                }
                
                $tcpClient.Close()
                return $success
            } -ArgumentList $endpointUrl, $endpoint.Port, $Timeout
            
            # Test HTTPS connectivity if TCP succeeds
            $httpsTest = if ($tcpTest) {
                Invoke-Command -ComputerName $ServerName -ScriptBlock {
                    param($url, $timeout)
                    
                    try {
                        $request = [System.Net.WebRequest]::Create("https://$url")
                        $request.Timeout = $timeout * 1000
                        $request.Method = "HEAD"
                        
                        $response = $request.GetResponse()
                        $statusCode = [int]$response.StatusCode
                        $response.Close()
                        
                        return @{
                            Success = $statusCode -ge 200 -and $statusCode -lt 400
                            StatusCode = $statusCode
                        }
                    }
                    catch [System.Net.WebException] {
                        if ($_.Exception.Response) {
                            $statusCode = [int]$_.Exception.Response.StatusCode
                            return @{
                                Success = $false
                                StatusCode = $statusCode
                                Error = $_.Exception.Message
                            }
                        }
                        else {
                            return @{
                                Success = $false
                                Error = $_.Exception.Message
                            }
                        }
                    }
                    catch {
                        return @{
                            Success = $false
                            Error = $_.Exception.Message
                        }
                    }
                } -ArgumentList $endpointUrl, $Timeout
            }
            else {
                @{
                    Success = $false
                    Error = "TCP connection failed"
                }
            }
            
            $endpointResult = @{
                Name = $endpoint.Name
                Url = $endpoint.Url
                Port = $endpoint.Port
                Critical = $endpoint.Critical
                TCPSuccess = $tcpTest
                HTTPSSuccess = $httpsTest.Success
                StatusCode = $httpsTest.StatusCode
                Error = $httpsTest.Error
                Success = $tcpTest -and $httpsTest.Success
            }
            
            $results.Endpoints += $endpointResult
            
            if (-not $endpointResult.Success -and $endpoint.Critical) {
                $results.CriticalFailures++
                $results.OverallSuccess = $false
            }
        }
    }
    catch {
        Write-Error "Endpoint connectivity test failed: $_"
        $results.Error = $_.Exception.Message
        $results.OverallSuccess = $false
    }

    return $results
}

function Test-DNSResolution {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter(Mandatory)]
        [array]$Endpoints
    )

    $results = @{
        Resolutions = @()
        OverallSuccess = $true
        CriticalFailures = 0
    }

    try {
        foreach ($endpoint in $Endpoints) {
            $endpointUrl = $endpoint.Url -replace '\*', 'dc'  # Replace wildcard with 'dc' for testing
            
            $dnsResult = Invoke-Command -ComputerName $ServerName -ScriptBlock {
                param($url)
                
                try {
                    $resolution = Resolve-DnsName -Name $url -ErrorAction Stop
                    return @{
                        Success = $true
                        IPs = $resolution | Where-Object { $_.Type -eq 'A' } | Select-Object -ExpandProperty IPAddress
                        Records = $resolution | ForEach-Object { "$($_.Name) ($($_.Type)): $($_.IPAddress)" }
                    }
                }
                catch {
                    return @{
                        Success = $false
                        Error = $_.Exception.Message
                    }
                }
            } -ArgumentList $endpointUrl
            
            $resolutionResult = @{
                Name = $endpoint.Name
                Url = $endpoint.Url
                Success = $dnsResult.Success
                IPs = $dnsResult.IPs
                Records = $dnsResult.Records
                Error = $dnsResult.Error
                Critical = $endpoint.Critical
            }
            
            $results.Resolutions += $resolutionResult
            
            if (-not $resolutionResult.Success -and $endpoint.Critical) {
                $results.CriticalFailures++
                $results.OverallSuccess = $false
            }
        }
    }
    catch {
        Write-Error "DNS resolution test failed: $_"
        $results.Error = $_.Exception.Message
        $results.OverallSuccess = $false
    }

    return $results
}

function Test-ProxyConfiguration {
    [CmdletBinding()]
    param ([string]$ServerName)

    $results = @{
        Success = $false
        Configuration = $null
        Validation = @()
    }

    try {
        # Get proxy configuration
        $proxyConfig = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            $config = @{
                WinHTTP = netsh winhttp show proxy
                WinINet = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
                Environment = [System.Environment]::GetEnvironmentVariable('HTTP_PROXY')
                ArcConfig = if (Test-Path 'C:\Program Files\Azure Connected Machine Agent\config') {
                    Get-Content 'C:\Program Files\Azure Connected Machine Agent\config\agentconfig.json' -ErrorAction SilentlyContinue | ConvertFrom-Json
                } else { $null }
            }
            return $config
        }
        
        $results.Configuration = @{
            WinHTTPProxy = $proxyConfig.WinHTTP
            WinINetProxy = $proxyConfig.WinINet.ProxyServer
            WinINetBypass = $proxyConfig.WinINet.ProxyOverride
            EnvironmentProxy = $proxyConfig.Environment
            ProxyEnabled = $proxyConfig.WinINet.ProxyEnable -eq 1
            ArcProxyConfig = if ($proxyConfig.ArcConfig.proxy) { $proxyConfig.ArcConfig.proxy } else { $null }
        }
        
        # Validate proxy configuration
        $proxyValidation = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            $validations = @()
            
            # Test if proxy is needed
            $directAccess = try {
                $request = [System.Net.WebRequest]::Create("https://management.azure.com")
                $request.Timeout = 10000
                $request.Method = "HEAD"
                $request.Proxy = [System.Net.GlobalProxySelection]::GetEmptyWebProxy()
                
                $response = $request.GetResponse()
                $statusCode = [int]$response.StatusCode
                $response.Close()
                
                $statusCode -ge 200 -and $statusCode -lt 400
            }
            catch {
                $false
            }
            
            $validations += @{
                Check = "Direct Access"
                Success = $directAccess
                Details = if ($directAccess) { "Direct access to Azure endpoints is possible" } else { "Direct access to Azure endpoints is blocked" }
            }
            
            # Test if proxy is working (if configured)
            $proxySettings = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
            if ($proxySettings.ProxyEnable -eq 1 -and $proxySettings.ProxyServer) {
                $proxyAccess = try {
                    $request = [System.Net.WebRequest]::Create("https://management.azure.com")
                    $request.Timeout = 10000
                    $request.Method = "HEAD"
                    
                    $response = $request.GetResponse()
                    $statusCode = [int]$response.StatusCode
                    $response.Close()
                    
                    $statusCode -ge 200 -and $statusCode -lt 400
                }
                catch {
                    $false
                }
                
                $validations += @{
                    Check = "Proxy Access"
                    Success = $proxyAccess
                    Details = if ($proxyAccess) { "Access through proxy is working" } else { "Access through proxy is failing" }
                }
            }
            
            # Check if Arc agent proxy settings match system settings
            $arcConfig = if (Test-Path 'C:\Program Files\Azure Connected Machine Agent\config\agentconfig.json') {
                Get-Content 'C:\Program Files\Azure Connected Machine Agent\config\agentconfig.json' -ErrorAction SilentlyContinue | ConvertFrom-Json
            } else { $null }
            
            if ($arcConfig -and $arcConfig.proxy) {
                $arcProxyMatch = $arcConfig.proxy -eq $proxySettings.ProxyServer
                
                $validations += @{
                    Check = "Arc Proxy Configuration"
                    Success = $arcProxyMatch
                    Details = if ($arcProxyMatch) { "Arc proxy settings match system settings" } else { "Arc proxy settings do not match system settings" }
                }
            }
            
            return $validations
        }
        
        $results.Validation = $proxyValidation
        
        # Determine overall success
        $results.Success = ($proxyValidation | Where-Object { -not $_.Success }).Count -eq 0
    }
    catch {
        Write-Error "Proxy configuration test failed: $_"
        $results.Error = $_.Exception.Message
    }

    return $results
}

function Test-TLSConfiguration {
    [CmdletBinding()]
    param ([string]$ServerName)

    $results = @{
        Success = $false
        Configuration = $null
        Validation = @()
    }

    try {
        # Get TLS configuration
        $tlsConfig = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            $config = @{
                SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol
                Registry = @{}
            }
            
            # Check registry settings
            $protocols = @('SSL 2.0', 'SSL 3.0', 'TLS 1.0', 'TLS 1.1', 'TLS 1.2')
            $sides = @('Client', 'Server')
            
            foreach ($protocol in $protocols) {
                foreach ($side in $sides) {
                    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\$protocol\$side"
                    if (Test-Path $regPath) {
                        $enabled = (Get-ItemProperty -Path $regPath -Name "Enabled" -ErrorAction SilentlyContinue).Enabled
                        $config.Registry["$protocol-$side"] = $enabled
                    }
                    else {
                        $config.Registry["$protocol-$side"] = "Not configured"
                    }
                }
            }
            
            # Check .NET Framework settings
            $frameworkVersions = @('v2.0.50727', 'v4.0.30319')
            foreach ($version in $frameworkVersions) {
                $regPath = "HKLM:\SOFTWARE\Microsoft\.NETFramework\$version"
                $config.Registry["DotNet-$version"] = @{
                    SystemDefaultTlsVersions = (Get-ItemProperty -Path $regPath -Name "SystemDefaultTlsVersions" -ErrorAction SilentlyContinue).SystemDefaultTlsVersions
                    SchUseStrongCrypto = (Get-ItemProperty -Path $regPath -Name "SchUseStrongCrypto" -ErrorAction SilentlyContinue).SchUseStrongCrypto
                }
            }
            
            return $config
        }
        
        $results.Configuration = $tlsConfig
        
        # Validate TLS configuration
        $tlsValidation = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            $validations = @()
            
            # Check if TLS 1.2 is enabled
            $tls12Enabled = $false
            if ([Net.ServicePointManager]::SecurityProtocol -match 'Tls12') {
                $tls12Enabled = $true
            }
            elseif ($Registry.'TLS 1.2-Client' -eq 1) {
                $tls12Enabled = $true
            }
            
            $validations += @{
                Check = "TLS 1.2 Enabled"
                Success = $tls12Enabled
                Details = if ($tls12Enabled) { "TLS 1.2 is enabled" } else { "TLS 1.2 is not enabled" }
                Critical = $true
            }
            
            # Check if older protocols are disabled
            $oldProtocolsDisabled = $true
            foreach ($protocol in @('SSL 2.0', 'SSL 3.0')) {
                if ($Registry."$protocol-Client" -eq 1) {
                    $oldProtocolsDisabled = $false
                    break
                }
            }
            
            $validations += @{
                Check = "Old Protocols Disabled"
                Success = $oldProtocolsDisabled
                Details = if ($oldProtocolsDisabled) { "Insecure protocols are disabled" } else { "Insecure protocols are enabled" }
                Critical = $true
            }
            
            # Test TLS connection to Azure endpoints
            $tlsConnection = try {
                $request = [System.Net.WebRequest]::Create("https://management.azure.com")
                $request.Timeout = 10000
                $request.Method = "HEAD"
                
                $response = $request.GetResponse()
                $statusCode = [int]$response.StatusCode
                $response.Close()
                
                $statusCode -ge 200 -and $statusCode -lt 400
            }
            catch {
                $false
            }
            
            $validations += @{
                Check = "TLS Connection"
                Success = $tlsConnection
                Details = if ($tlsConnection) { "TLS connection to Azure endpoints is successful" } else { "TLS connection to Azure endpoints is failing" }
                Critical = $true
            }
            
            return $validations
        }
        
        $results.Validation = $tlsValidation
        
        # Determine overall success
        $criticalChecks = $tlsValidation | Where-Object { $_.Critical -and -not $_.Success }
        $results.Success = $criticalChecks.Count -eq 0
    }
    catch {
        Write-Error "TLS configuration test failed: $_"
        $results.Error = $_.Exception.Message
    }

    return $results
}

function Test-NetworkPerformance {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter(Mandatory)]
        [array]$Endpoints,
        [Parameter()]
        [int]$LatencyThreshold = 300,
        [Parameter()]
        [int]$PacketLossThreshold = 5
    )

    $results = @{
        Endpoints = @()
        Success = $true
        AverageLatency = 0
        PacketLoss = 0
    }

    try {
        $totalLatency = 0
        $totalEndpoints = 0
        $totalPacketLoss = 0
        
        foreach ($endpoint in $Endpoints) {
            $endpointUrl = $endpoint.Url -replace '\*', 'dc'  # Replace wildcard with 'dc' for testing
            
            # Test network performance
            $performanceTest = Invoke-Command -ComputerName $ServerName -ScriptBlock {
                param($url)
                
                $pingResults = Test-Connection -ComputerName $url -Count 10 -ErrorAction SilentlyContinue
                
                if ($pingResults) {
                    $successCount = ($pingResults | Measure-Object).Count
                    $packetLoss = 100 - ($successCount * 10)
                    $avgLatency = ($pingResults | Measure-Object -Property ResponseTime -Average).Average
                    
                    return @{
                        Success = $true
                        AverageLatency = $avgLatency
                        PacketLoss = $packetLoss
                        MinLatency = ($pingResults | Measure-Object -Property ResponseTime -Minimum).Minimum
                        MaxLatency = ($pingResults | Measure-Object -Property ResponseTime -Maximum).Maximum
                    }
                }
                else {
                    # If ping fails, try TCP test for latency
                    $tcpLatencies = @()
                    for ($i = 0; $i -lt 5; $i++) {
                        $startTime = Get-Date
                        $tcpClient = New-Object System.Net.Sockets.TcpClient
                        $connection = $tcpClient.BeginConnect($url, 443, $null, $null)
                        $success = $connection.AsyncWaitHandle.WaitOne(5000, $true)
                        $endTime = Get-Date
                        
                        if ($success) {
                            $tcpClient.EndConnect($connection)
                            $latency = ($endTime - $startTime).TotalMilliseconds
                            $tcpLatencies += $latency
                        }
                        
                        $tcpClient.Close()
                    }
                    
                    if ($tcpLatencies.Count -gt 0) {
                        $avgLatency = ($tcpLatencies | Measure-Object -Average).Average
                        $packetLoss = 100 - (($tcpLatencies.Count / 5) * 100)
                        
                        return @{
                            Success = $true
                            AverageLatency = $avgLatency
                            PacketLoss = $packetLoss
                            MinLatency = ($tcpLatencies | Measure-Object -Minimum).Minimum
                            MaxLatency = ($tcpLatencies | Measure-Object -Maximum).Maximum
                            Method = "TCP"
                        }
                    }
                    else {
                        return @{
                            Success = $false
                            PacketLoss = 100
                            Error = "Could not establish connection"
                        }
                    }
                }
            } -ArgumentList $endpointUrl
            
            $endpointResult = @{
                Name = $endpoint.Name
                Url = $endpoint.Url
                Success = $performanceTest.Success
                AverageLatency = $performanceTest.AverageLatency
                MinLatency = $performanceTest.MinLatency
                MaxLatency = $performanceTest.MaxLatency
                PacketLoss = $performanceTest.PacketLoss
                Method = $performanceTest.Method
                LatencyThresholdExceeded = $performanceTest.AverageLatency -gt $LatencyThreshold
                PacketLossThresholdExceeded = $performanceTest.PacketLoss -gt $PacketLossThreshold
                Error = $performanceTest.Error
            }
            
            $results.Endpoints += $endpointResult
            
            if ($performanceTest.Success) {
                $totalLatency += $performanceTest.AverageLatency
                $totalPacketLoss += $performanceTest.PacketLoss
                $totalEndpoints++
                
                if ($performanceTest.AverageLatency -gt $LatencyThreshold -or $performanceTest.PacketLoss -gt $PacketLossThreshold) {
                    $results.Success = $false
                }
            }
            else {
                $results.Success = $false
            }
        }
        
        if ($totalEndpoints -gt 0) {
            $results.AverageLatency = $totalLatency / $totalEndpoints
            $results.PacketLoss = $totalPacketLoss / $totalEndpoints
        }
    }
    catch {
        Write-Error "Network performance test failed: $_"
        $results.Error = $_.Exception.Message
        $results.Success = $false
    }

    return $results
}

function Test-FirewallConfiguration {
    [CmdletBinding()]
    param ([string]$ServerName)

    $results = @{
        Success = $false
        Configuration = $null
        Validation = @()
    }

    try {
        # Get firewall configuration
        $firewallConfig = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            $config = @{
                Profiles = Get-NetFirewallProfile | Select-Object Name, Enabled
                ArcRules = Get-NetFirewallRule | Where-Object { 
                    $_.DisplayName -like "*Azure*" -or 
                    $_.DisplayName -like "*Arc*" -or 
                    $_.DisplayName -like "*Monitor*" 
                } | Select-Object DisplayName, Enabled, Direction, Action
                OutboundRules = Get-NetFirewallRule -Direction Outbound | Where-Object { $_.Enabled -eq $true -and $_.Action -eq "Allow" } | Select-Object -First 10
            }
            return $config
        }
        
        $results.Configuration = $firewallConfig
        
        # Validate firewall configuration
        $firewallValidation = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            $validations = @()
            
            # Check if any firewall profile is enabled
            $firewallEnabled = (Get-NetFirewallProfile | Where-Object { $_.Enabled -eq $true }).Count -gt 0
            
            $validations += @{
                Check = "Firewall Enabled"
                Success = $firewallEnabled
                Details = if ($firewallEnabled) { "At least one firewall profile is enabled" } else { "No firewall profiles are enabled" }
            }
            
            # Check outbound connectivity
            $outboundAllowed = (Get-NetFirewallRule -Direction Outbound | Where-Object { 
                $_.Enabled -eq $true -and 
                $_.Action -eq "Allow" 
            }).Count -gt 0
            
            $validations += @{
                Check = "Outbound Connectivity"
                Success = $outboundAllowed
                Details = if ($outboundAllowed) { "Outbound connectivity is allowed" } else { "Outbound connectivity may be restricted" }
                Critical = $true
            }
            
            # Check for Arc-specific rules
            $arcRules = Get-NetFirewallRule | Where-Object { 
                $_.DisplayName -like "*Azure*" -or 
                $_.DisplayName -like "*Arc*" -or 
                $_.DisplayName -like "*Monitor*" 
            }
            
            $arcRulesExist = $arcRules.Count -gt 0
            
            $validations += @{
                Check = "Arc-Specific Rules"
                Success = $arcRulesExist
                Details = if ($arcRulesExist) { "Arc-specific firewall rules exist" } else { "No Arc-specific firewall rules found" }
            }
            
            # Test outbound connectivity to Azure endpoints
            $azureConnectivity = try {
                $request = [System.Net.WebRequest]::Create("https://management.azure.com")
                $request.Timeout = 10000
                $request.Method = "HEAD"
                
                $response = $request.GetResponse()
                $statusCode = [int]$response.StatusCode
                $response.Close()
                
                $statusCode -ge 200 -and $statusCode -lt 400
            }
            catch {
                $false
            }
            
            $validations += @{
                Check = "Azure Connectivity"
                Success = $azureConnectivity
                Details = if ($azureConnectivity) { "Outbound connectivity to Azure is working" } else { "Outbound connectivity to Azure is blocked" }
                Critical = $true
            }
            
            return $validations
        }
        
        $results.Validation = $firewallValidation
        
        # Determine overall success
        $criticalChecks = $firewallValidation | Where-Object { $_.Critical -and -not $_.Success }
        $results.Success = $criticalChecks.Count -eq 0
    }
    catch {
        Write-Error "Firewall configuration test failed: $_"
        $results.Error = $_.Exception.Message
    }

    return $results
}

function Test-NetworkRoutes {
    [CmdletBinding()]
    param ([string]$ServerName)

    $results = @{
        Success = $true
        Routes = @()
        Interfaces = @()
    }

    try {
        # Get network routes and interfaces
        $networkData = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            $data = @{
                Routes = Get-NetRoute | Where-Object { 
                    $_.DestinationPrefix -notlike '169.254.*' -and
                    $_.DestinationPrefix -notlike '224.0.0.*'
                } | Select-Object DestinationPrefix, NextHop, RouteMetric, InterfaceIndex
                
                Interfaces = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' } | Select-Object Name, InterfaceDescription, Status, MacAddress, LinkSpeed, ifIndex
                
                DefaultGateway = (Get-NetRoute | Where-Object { 
                    $_.DestinationPrefix -eq '0.0.0.0/0' -or 
                    $_.DestinationPrefix -eq '::/0' 
                }).NextHop
            }
            return $data
        }
        
        $results.Routes = $networkData.Routes
        $results.Interfaces = $networkData.Interfaces
        $results.DefaultGateway = $networkData.DefaultGateway
        
        # Validate routes
        $routeValidation = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            $validations = @()
            
            # Check if default gateway exists
            $defaultGatewayExists = (Get-NetRoute | Where-Object { 
                $_.DestinationPrefix -eq '0.0.0.0/0' -or 
                $_.DestinationPrefix -eq '::/0' 
            }).Count -gt 0
            
            $validations += @{
                Check = "Default Gateway"
                Success = $defaultGatewayExists
                Details = if ($defaultGatewayExists) { "Default gateway is configured" } else { "No default gateway found" }
                Critical = $true
            }
            
            # Check if interfaces are up
            $activeInterfaces = (Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }).Count
            
            $validations += @{
                Check = "Active Interfaces"
                Success = $activeInterfaces -gt 0
                Details = if ($activeInterfaces -gt 0) { "$activeInterfaces active network interfaces found" } else { "No active network interfaces found" }
                Critical = $true
            }
            
            # Check route to Azure endpoints
            $azureRouteTest = Test-NetConnection -ComputerName "management.azure.com" -TraceRoute
            $azureRouteSuccess = $azureRouteTest.TraceRoute[-1] -eq "management.azure.com"
            
            $validations += @{
                Check = "Azure Route"
                Success = $azureRouteSuccess
                Details = if ($azureRouteSuccess) { "Route to Azure endpoints is valid" } else { "Route to Azure endpoints may be invalid" }
                TraceRoute = $azureRouteTest.TraceRoute
            }
            
            return $validations
        }
        
        $results.Validation = $routeValidation
        
        # Determine overall success
        $criticalChecks = $routeValidation | Where-Object { $_.Critical -and -not $_.Success }
        $results.Success = $criticalChecks.Count -eq 0
    }
    catch {
        Write-Error "Network routes test failed: $_"
        $results.Error = $_.Exception.Message
        $results.Success = $false
    }

    return $results
}

function Get-NetworkRecommendations {
    [CmdletBinding()]
    param ([array]$ValidationResults)

    $recommendations = @()

    foreach ($component in $ValidationResults) {
        switch ($component.Component) {
            "Endpoints" {
                $failedEndpoints = $component.Results.Endpoints | Where-Object { -not $_.Success }
                foreach ($endpoint in $failedEndpoints) {
                    $recommendations += @{
                        Component = "Endpoint Connectivity"
                        Priority = if ($endpoint.Critical) { "High" } else { "Medium" }
                        Issue = "Cannot connect to $($endpoint.Name) ($($endpoint.Url):$($endpoint.Port))"
                        Recommendation = "Ensure outbound connectivity to $($endpoint.Url) on port $($endpoint.Port) is allowed"
                        Details = $endpoint.Error
                    }
                }
            }
            
            "DNS" {
                $failedResolutions = $component.Results.Resolutions | Where-Object { -not $_.Success }
                foreach ($resolution in $failedResolutions) {
                    $recommendations += @{
                        Component = "DNS Resolution"
                        Priority = if ($resolution.Critical) { "High" } else { "Medium" }
                        Issue = "Cannot resolve $($resolution.Name) ($($resolution.Url))"
                        Recommendation = "Verify DNS configuration and ensure $($resolution.Url) can be resolved"
                        Details = $resolution.Error
                    }
                }
            }
            
            "Proxy" {
                $failedChecks = $component.Results.Validation | Where-Object { -not $_.Success }
                foreach ($check in $failedChecks) {
                    $recommendations += @{
                        Component = "Proxy Configuration"
                        Priority = "High"
                        Issue = "Proxy validation failed: $($check.Check)"
                        Recommendation = switch ($check.Check) {
                            "Direct Access" { "Configure proxy settings to allow access to Azure endpoints" }
                            "Proxy Access" { "Verify proxy server is working correctly and can access Azure endpoints" }
                            "Arc Proxy Configuration" { "Update Arc agent proxy settings to match system proxy settings" }
                            default { "Review proxy configuration" }
                        }
                        Details = $check.Details
                    }
                }
            }
            
            "TLS" {
                $failedChecks = $component.Results.Validation | Where-Object { -not $_.Success }
                foreach ($check in $failedChecks) {
                    $recommendations += @{
                        Component = "TLS Configuration"
                        Priority = if ($check.Critical) { "High" } else { "Medium" }
                        Issue = "TLS validation failed: $($check.Check)"
                        Recommendation = switch ($check.Check) {
                            "TLS 1.2 Enabled" { "Enable TLS 1.2 protocol in Windows registry" }
                            "Old Protocols Disabled" { "Disable insecure protocols (SSL 2.0, SSL 3.0) in Windows registry" }
                            "TLS Connection" { "Verify TLS configuration and ensure secure connection to Azure endpoints" }
                            default { "Review TLS configuration" }
                        }
                        Details = $check.Details
                    }
                }
            }
            
            "Performance" {
                $poorPerformance = $component.Results.Endpoints | Where-Object { 
                    $_.LatencyThresholdExceeded -or $_.PacketLossThresholdExceeded 
                }
                foreach ($endpoint in $poorPerformance) {
                    $recommendations += @{
                        Component = "Network Performance"
                        Priority = "Medium"
                        Issue = if ($endpoint.LatencyThresholdExceeded) {
                            "High latency to $($endpoint.Name) ($($endpoint.AverageLatency)ms)"
                        } else {
                            "High packet loss to $($endpoint.Name) ($($endpoint.PacketLoss)%)"
                        }
                        Recommendation = if ($endpoint.LatencyThresholdExceeded) {
                            "Investigate network latency issues to $($endpoint.Url)"
                        } else {
                            "Investigate packet loss issues to $($endpoint.Url)"
                        }
                        Details = "Latency: $($endpoint.AverageLatency)ms, Packet Loss: $($endpoint.PacketLoss)%"
                    }
                }
            }
            
            "Firewall" {
                $failedChecks = $component.Results.Validation | Where-Object { -not $_.Success }
                foreach ($check in $failedChecks) {
                    $recommendations += @{
                        Component = "Firewall Configuration"
                        Priority = if ($check.Critical) { "High" } else { "Medium" }
                        Issue = "Firewall validation failed: $($check.Check)"
                        Recommendation = switch ($check.Check) {
                            "Outbound Connectivity" { "Configure firewall to allow outbound connectivity to Azure endpoints" }
                            "Azure Connectivity" { "Verify firewall rules allow connectivity to Azure endpoints" }
                            "Arc-Specific Rules" { "Create firewall rules for Azure Arc and Azure Monitor" }
                            default { "Review firewall configuration" }
                        }
                        Details = $check.Details
                    }
                }
            }
            
            "Routes" {
                $failedChecks = $component.Results.Validation | Where-Object { -not $_.Success }
                foreach ($check in $failedChecks) {
                    $recommendations += @{
                        Component = "Network Routes"
                        Priority = if ($check.Critical) { "High" } else { "Medium" }
                        Issue = "Network route validation failed: $($check.Check)"
                        Recommendation = switch ($check.Check) {
                            "Default Gateway" { "Configure default gateway for outbound connectivity" }
                            "Active Interfaces" { "Ensure at least one network interface is active" }
                            "Azure Route" { "Verify network route to Azure endpoints" }
                            default { "Review network routes" }
                        }
                        Details = $check.Details
                    }
                }
            }
        }
    }

    return $recommendations | Sort-Object -Property Priority
}
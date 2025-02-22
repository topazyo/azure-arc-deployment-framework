function Test-ArcEndpoints {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [int]$TimeoutSeconds = 30,
        [Parameter()]
        [switch]$DetailedOutput
    )

    $endpoints = @{
        'Azure Arc Service' = @{
            Url = 'management.azure.com'
            Port = 443
            Required = $true
        }
        'Azure Identity' = @{
            Url = 'login.microsoftonline.com'
            Port = 443
            Required = $true
        }
        'Azure Monitor' = @{
            Url = 'global.handler.control.monitor.azure.com'
            Port = 443
            Required = $true
        }
        'Log Analytics' = @{
            Url = 'ods.opinsights.azure.com'
            Port = 443
            Required = $true
        }
    }

    $results = @{
        ServerName = $ServerName
        StartTime = Get-Date
        EndpointTests = @{}
        ProxyStatus = $null
        DNSResolution = @{}
        Success = $true
    }

    try {
        foreach ($endpoint in $endpoints.GetEnumerator()) {
            Write-Verbose "Testing connection to $($endpoint.Key) ($($endpoint.Value.Url))"
            
            # Test DNS resolution
            $dns = Resolve-DnsName -Name $endpoint.Value.Url -ErrorAction SilentlyContinue
            $results.DNSResolution[$endpoint.Key] = @{
                Resolved = $null -ne $dns
                IPs = $dns.IPAddress
            }

            # Test connectivity
            $test = Test-NetConnection -ComputerName $endpoint.Value.Url -Port $endpoint.Value.Port -WarningAction SilentlyContinue
            
            $results.EndpointTests[$endpoint.Key] = @{
                Url = $endpoint.Value.Url
                Port = $endpoint.Value.Port
                Required = $endpoint.Value.Required
                TCPTestSucceeded = $test.TcpTestSucceeded
                PingSucceeded = $test.PingSucceeded
                LatencyMS = $test.PingReplyDetails.RoundtripTime
                Error = if (-not $test.TcpTestSucceeded) { "Connection failed" } else { $null }
            }

            if ($endpoint.Value.Required -and -not $test.TcpTestSucceeded) {
                $results.Success = $false
            }
        }

        # Get proxy configuration
        $results.ProxyStatus = Get-ProxyConfiguration -ServerName $ServerName

        if ($DetailedOutput) {
            # Get network route
            $results.NetworkRoute = Get-NetworkRoute -ServerName $ServerName
            
            # Get firewall status
            $results.FirewallStatus = Get-FirewallStatus -ServerName $ServerName
            
            # Get TLS configuration
            $results.TLSConfig = Get-TLSConfiguration -ServerName $ServerName
        }
    }
    catch {
        $results.Success = $false
        $results.Error = $_.Exception.Message
        Write-Error "Network test failed: $_"
    }
    finally {
        $results.EndTime = Get-Date
        $results.Duration = $results.EndTime - $results.StartTime
    }

    return [PSCustomObject]$results
}

function Get-NetworkRoute {
    [CmdletBinding()]
    param ([string]$ServerName)
    
    try {
        $routes = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            Get-NetRoute | Where-Object { 
                $_.DestinationPrefix -notlike '169.254.*' -and
                $_.DestinationPrefix -notlike '224.0.0.*'
            }
        }

        return $routes | Select-Object -Property DestinationPrefix, NextHop, RouteMetric, InterfaceIndex
    }
    catch {
        Write-Error "Failed to get network routes: $_"
        return $null
    }
}

function Get-ProxyConfiguration {
    [CmdletBinding()]
    param ([string]$ServerName)
    
    try {
        $proxyConfig = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            $config = @{
                WinHTTP = netsh winhttp show proxy
                WinINet = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
                Environment = [System.Environment]::GetEnvironmentVariable('HTTP_PROXY')
            }
            return $config
        }

        return @{
            WinHTTPProxy = $proxyConfig.WinHTTP
            WinINetProxy = $proxyConfig.WinINet.ProxyServer
            WinINetBypass = $proxyConfig.WinINet.ProxyOverride
            EnvironmentProxy = $proxyConfig.Environment
            ProxyEnabled = $proxyConfig.WinINet.ProxyEnable -eq 1
        }
    }
    catch {
        Write-Error "Failed to get proxy configuration: $_"
        return $null
    }
}
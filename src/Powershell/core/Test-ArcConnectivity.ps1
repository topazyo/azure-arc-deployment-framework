function Test-ArcConnectivity {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [switch]$IncludeAMA,
        [Parameter()]
        [switch]$Detailed,
        [Parameter()]
        [int]$TimeoutSeconds = 30,
        [Parameter()]
        [string]$LogPath
    )

    begin {
        $connectivityResults = @{
            ServerName = $ServerName
            StartTime = Get-Date
            Status = "Unknown"
            Endpoints = @{}
            NetworkDetails = @{}
            ProxyConfiguration = $null
            TLSConfiguration = $null
            Success = $false
        }

        # Define required endpoints
        $arcEndpoints = @{
            'Azure Resource Manager' = @{
                Url = 'management.azure.com'
                Port = 443
                Required = $true
                Service = 'Arc'
            }
            'Azure Active Directory' = @{
                Url = 'login.microsoftonline.com'
                Port = 443
                Required = $true
                Service = 'Arc'
            }
            'Azure Service Bus' = @{
                Url = 'servicebus.windows.net'
                Port = 443
                Required = $true
                Service = 'Arc'
            }
        }

        # Add AMA endpoints if requested
        if ($IncludeAMA) {
            $amaEndpoints = @{
                'Log Analytics' = @{
                    Url = 'ods.opinsights.azure.com'
                    Port = 443
                    Required = $true
                    Service = 'AMA'
                }
                'Log Analytics Gateway' = @{
                    Url = 'oms.opinsights.azure.com'
                    Port = 443
                    Required = $true
                    Service = 'AMA'
                }
                'Azure Monitor' = @{
                    Url = 'global.handler.control.monitor.azure.com'
                    Port = 443
                    Required = $true
                    Service = 'AMA'
                }
            }
            $arcEndpoints += $amaEndpoints
        }

        # Start logging if path provided
        if ($LogPath) {
            $logFile = Join-Path $LogPath "ArcConnectivity_$($ServerName)_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
            Start-Transcript -Path $logFile
        }

        Write-Log -Message "Starting connectivity test for $ServerName" -Level Information
    }

    process {
        try {
            # Test server reachability first
            Write-Verbose "Testing basic connectivity to $ServerName"
            $pingTest = Test-Connection -ComputerName $ServerName -Count 1 -ErrorAction Stop
            $connectivityResults.NetworkDetails.Ping = @{
                Success = $true
                ResponseTime = $pingTest.ResponseTime
                Address = $pingTest.Address
            }

            # Get proxy configuration
            Write-Verbose "Retrieving proxy configuration from $ServerName"
            $proxyConfig = Get-ProxyConfiguration -ServerName $ServerName
            $connectivityResults.ProxyConfiguration = $proxyConfig

            # Get TLS configuration
            Write-Verbose "Retrieving TLS configuration from $ServerName"
            $tlsConfig = Get-TLSConfiguration -ServerName $ServerName
            $connectivityResults.TLSConfiguration = $tlsConfig

            # Test each endpoint
            foreach ($endpoint in $arcEndpoints.GetEnumerator()) {
                Write-Verbose "Testing connectivity to $($endpoint.Key) ($($endpoint.Value.Url):$($endpoint.Value.Port))"
                
                # Test DNS resolution
                try {
                    $dns = Resolve-DnsName -Name $endpoint.Value.Url -ErrorAction Stop
                    $dnsStatus = @{
                        Success = $true
                        IPs = $dns.IPAddress
                    }
                }
                catch {
                    $dnsStatus = @{
                        Success = $false
                        Error = $_.Exception.Message
                    }
                    Write-Log -Message "DNS resolution failed for $($endpoint.Value.Url): $_" -Level Warning
                }

                # Test TCP connectivity
                $tcpTest = New-RetryBlock -ScriptBlock {
                    Test-NetConnection -ComputerName $endpoint.Value.Url -Port $endpoint.Value.Port -WarningAction SilentlyContinue
                } -RetryCount 2 -RetryDelaySeconds 5

                # Test SSL/TLS if TCP successful
                $sslTest = $null
                if ($tcpTest.Result.TcpTestSucceeded) {
                    try {
                        $sslTest = Test-SslConnection -HostName $endpoint.Value.Url -Port $endpoint.Value.Port
                    }
                    catch {
                        Write-Log -Message "SSL test failed for $($endpoint.Value.Url): $_" -Level Warning
                        $sslTest = @{
                            Success = $false
                            Error = $_.Exception.Message
                        }
                    }
                }

                # Store results
                $connectivityResults.Endpoints[$endpoint.Key] = @{
                    Url = $endpoint.Value.Url
                    Port = $endpoint.Value.Port
                    Required = $endpoint.Value.Required
                    Service = $endpoint.Value.Service
                    DNS = $dnsStatus
                    TCP = @{
                        Success = $tcpTest.Result.TcpTestSucceeded
                        ResponseTime = $tcpTest.Result.PingReplyDetails.RoundtripTime
                        Error = if (-not $tcpTest.Result.TcpTestSucceeded) { $tcpTest.LastError } else { $null }
                    }
                    SSL = $sslTest
                }
            }

            # Get detailed network information if requested
            if ($Detailed) {
                Write-Verbose "Collecting detailed network information"
                $connectivityResults.NetworkDetails += @{
                    IPConfiguration = Get-ServerIPConfiguration -ServerName $ServerName
                    FirewallRules = Get-RelevantFirewallRules -ServerName $ServerName
                    RouteTable = Get-NetworkRoute -ServerName $ServerName
                    NetworkAdapters = Get-NetworkAdapterConfiguration -ServerName $ServerName
                }
            }

            # Determine overall success
            $requiredEndpoints = $connectivityResults.Endpoints.GetEnumerator() | 
                Where-Object { $_.Value.Required }
            
            $failedRequired = $requiredEndpoints | 
                Where-Object { -not $_.Value.TCP.Success }

            $connectivityResults.Success = $failedRequired.Count -eq 0
            $connectivityResults.Status = $connectivityResults.Success ? "Success" : "Failed"

            # Generate recommendations if there are failures
            if (-not $connectivityResults.Success) {
                $connectivityResults.Recommendations = Get-ConnectivityRecommendations -Results $connectivityResults
            }

            Write-Log -Message "Connectivity test completed with status: $($connectivityResults.Status)" -Level Information
        }
        catch {
            $connectivityResults.Status = "Error"
            $connectivityResults.Error = $_.Exception.Message
            Write-Error "Connectivity test failed: $_"
            Write-Log -Message "Connectivity test failed: $_" -Level Error
        }
    }

    end {
        $connectivityResults.EndTime = Get-Date
        $connectivityResults.Duration = $connectivityResults.EndTime - $connectivityResults.StartTime

        # Stop logging if started
        if ($LogPath) {
            Stop-Transcript
        }

        return [PSCustomObject]$connectivityResults
    }
}

function Get-ServerIPConfiguration {
    [CmdletBinding()]
    param ([string]$ServerName)
    
    try {
        $ipConfig = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            Get-NetIPConfiguration | Select-Object -Property InterfaceAlias, IPv4Address, IPv4DefaultGateway, DNSServer
        }
        return $ipConfig
    }
    catch {
        Write-Error "Failed to get IP configuration: $_"
        return $null
    }
}

function Get-RelevantFirewallRules {
    [CmdletBinding()]
    param ([string]$ServerName)
    
    try {
        $firewallRules = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            Get-NetFirewallRule | Where-Object {
                $_.Direction -eq "Outbound" -and
                $_.Enabled -eq $true -and
                ($_.DisplayName -like "*Azure*" -or
                 $_.DisplayName -like "*Arc*" -or
                 $_.DisplayName -like "*443*" -or
                 $_.DisplayName -like "*HTTPS*")
            } | Select-Object -Property DisplayName, Direction, Action, Enabled
        }
        return $firewallRules
    }
    catch {
        Write-Error "Failed to get firewall rules: $_"
        return $null
    }
}

function Get-NetworkAdapterConfiguration {
    [CmdletBinding()]
    param ([string]$ServerName)
    
    try {
        $adapters = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            Get-WmiObject Win32_NetworkAdapterConfiguration | 
                Where-Object { $_.IPEnabled } | 
                Select-Object -Property Description, IPAddress, IPSubnet, DefaultIPGateway, DNSServerSearchOrder, DHCPEnabled
        }
        return $adapters
    }
    catch {
        Write-Error "Failed to get network adapter configuration: $_"
        return $null
    }
}

function Test-SslConnection {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$HostName,
        [Parameter()]
        [int]$Port = 443,
        [Parameter()]
        [int]$TimeoutMilliseconds = 10000
    )

    try {
        # Create TCP client
        $client = New-Object System.Net.Sockets.TcpClient
        $connection = $client.BeginConnect($HostName, $Port, $null, $null)
        $success = $connection.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)

        if (-not $success) {
            $client.Close()
            return @{
                Success = $false
                Error = "Connection timed out"
            }
        }

        try {
            $client.EndConnect($connection)
        }
        catch {
            return @{
                Success = $false
                Error = $_.Exception.Message
            }
        }

        # Create SSL stream
        $sslStream = New-Object System.Net.Security.SslStream($client.GetStream(), $false, {
            param($sender, $certificate, $chain, $sslPolicyErrors)
            return $true  # Accept all certificates for testing
        })

        # Authenticate
        $sslStream.AuthenticateAsClient($HostName)

        # Get connection details
        $result = @{
            Success = $true
            Protocol = $sslStream.SslProtocol
            CipherAlgorithm = $sslStream.CipherAlgorithm
            CipherStrength = $sslStream.CipherStrength
            HashAlgorithm = $sslStream.HashAlgorithm
            HashStrength = $sslStream.HashStrength
            Certificate = @{
                Subject = $sslStream.RemoteCertificate.Subject
                Issuer = $sslStream.RemoteCertificate.Issuer
                ValidFrom = $sslStream.RemoteCertificate.GetEffectiveDateString()
                ValidTo = $sslStream.RemoteCertificate.GetExpirationDateString()
                Thumbprint = $sslStream.RemoteCertificate.GetCertHashString()
            }
        }

        # Clean up
        $sslStream.Close()
        $client.Close()

        return $result
    }
    catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

function Get-ConnectivityRecommendations {
    [CmdletBinding()]
    param ([hashtable]$Results)

    $recommendations = @()

    # Check for DNS issues
    $dnsIssues = $Results.Endpoints.GetEnumerator() | 
        Where-Object { -not $_.Value.DNS.Success }
    
    if ($dnsIssues.Count -gt 0) {
        $recommendations += @{
            Issue = "DNS Resolution"
            Priority = "High"
            Description = "DNS resolution failed for one or more endpoints"
            Endpoints = $dnsIssues.Key -join ", "
            Recommendation = "Verify DNS configuration and ensure DNS servers can resolve Azure endpoints"
        }
    }

    # Check for TCP connectivity issues
    $tcpIssues = $Results.Endpoints.GetEnumerator() | 
        Where-Object { -not $_.Value.TCP.Success }
    
    if ($tcpIssues.Count -gt 0) {
        $recommendations += @{
            Issue = "TCP Connectivity"
            Priority = "High"
            Description = "TCP connectivity failed for one or more endpoints"
            Endpoints = $tcpIssues.Key -join ", "
            Recommendation = "Check firewall rules and network routes to ensure outbound connectivity to Azure endpoints"
        }
    }

    # Check for SSL/TLS issues
    $sslIssues = $Results.Endpoints.GetEnumerator() | 
        Where-Object { $_.Value.TCP.Success -and $_.Value.SSL -and -not $_.Value.SSL.Success }
    
    if ($sslIssues.Count -gt 0) {
        $recommendations += @{
            Issue = "SSL/TLS"
            Priority = "High"
            Description = "SSL/TLS handshake failed for one or more endpoints"
            Endpoints = $sslIssues.Key -join ", "
            Recommendation = "Verify TLS configuration and certificate trust"
        }
    }

    # Check for proxy issues
    if ($Results.ProxyConfiguration.ProxyEnabled) {
        $proxyIssues = $Results.Endpoints.GetEnumerator() | 
            Where-Object { -not $_.Value.TCP.Success }
        
        if ($proxyIssues.Count -gt 0) {
            $recommendations += @{
                Issue = "Proxy Configuration"
                Priority = "Medium"
                Description = "Proxy is enabled and may be blocking connections"
                Recommendation = "Verify proxy configuration and ensure Azure endpoints are allowed"
            }
        }
    }

    # Check for TLS configuration issues
    $tlsIssues = $Results.TLSConfiguration | 
        Where-Object { $_.Protocol -eq "TLS 1.2" -and -not $_.Enabled }
    
    if ($tlsIssues) {
        $recommendations += @{
            Issue = "TLS Configuration"
            Priority = "High"
            Description = "TLS 1.2 is not enabled"
            Recommendation = "Enable TLS 1.2 protocol support"
        }
    }

    return $recommendations
}
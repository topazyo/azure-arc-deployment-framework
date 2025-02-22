function Test-Connectivity {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [hashtable]$Endpoints,
        [Parameter()]
        [int]$TimeoutSeconds = 30,
        [Parameter()]
        [switch]$DetailedOutput
    )

    begin {
        if (-not $Endpoints) {
            $Endpoints = @{
                'Arc Management' = @{
                    Host = 'management.azure.com'
                    Port = 443
                    Required = $true
                }
                'Arc Authentication' = @{
                    Host = 'login.microsoftonline.com'
                    Port = 443
                    Required = $true
                }
                'Log Analytics' = @{
                    Host = 'ods.opinsights.azure.com'
                    Port = 443
                    Required = $true
                }
                'Monitor Gateway' = @{
                    Host = 'global.handler.control.monitor.azure.com'
                    Port = 443
                    Required = $true
                }
            }
        }

        $results = @{
            ServerName = $ServerName
            StartTime = Get-Date
            EndPoints = @{}
            OverallStatus = 'Unknown'
            NetworkDetails = @{}
        }
    }

    process {
        try {
            # Test server reachability first
            $pingTest = Test-Connection -ComputerName $ServerName -Count 1 -ErrorAction Stop
            $results.NetworkDetails.Ping = @{
                Success = $true
                ResponseTime = $pingTest.ResponseTime
                Address = $pingTest.Address
            }

            # Test each endpoint
            foreach ($endpoint in $Endpoints.GetEnumerator()) {
                $testResult = @{
                    Name = $endpoint.Key
                    Required = $endpoint.Value.Required
                    TestResults = @()
                }

                # TCP Test
                $tcpTest = New-RetryBlock -ScriptBlock {
                    Test-NetConnection -ComputerName $endpoint.Value.Host -Port $endpoint.Value.Port -WarningAction SilentlyContinue
                } -RetryCount 2 -RetryDelaySeconds 5

                $testResult.TestResults += @{
                    Type = 'TCP'
                    Success = $tcpTest.Result.TcpTestSucceeded
                    ResponseTime = $tcpTest.Result.PingReplyDetails.RoundtripTime
                    Error = $tcpTest.LastError
                }

                # SSL/TLS Test if TCP successful
                if ($tcpTest.Result.TcpTestSucceeded) {
                    $sslTest = Test-SslConnection -HostName $endpoint.Value.Host -Port $endpoint.Value.Port
                    $testResult.TestResults += @{
                        Type = 'SSL'
                        Success = $sslTest.Success
                        Protocol = $sslTest.Protocol
                        Certificate = $sslTest.Certificate
                        Error = $sslTest.Error
                    }
                }

                $results.EndPoints[$endpoint.Key] = $testResult
            }

            # Calculate overall status
            $requiredEndpoints = $results.EndPoints.Values | Where-Object { $_.Required }
            $failedRequired = $requiredEndpoints | 
                Where-Object { -not ($_.TestResults | Where-Object { $_.Type -eq 'TCP' -and $_.Success }) }

            $results.OverallStatus = if ($failedRequired) {
                'Failed'
            }
            else {
                'Success'
            }

            # Add detailed network information if requested
            if ($DetailedOutput) {
                $results.NetworkDetails += @{
                    IPConfiguration = Get-ServerIPConfiguration -ServerName $ServerName
                    ProxySettings = Get-ProxyConfiguration -ServerName $ServerName
                    FirewallRules = Get-RelevantFirewallRules -ServerName $ServerName
                    RouteTable = Get-NetworkRoute -ServerName $ServerName
                }
            }
        }
        catch {
            $results.OverallStatus = 'Error'
            $results.Error = Convert-ErrorToObject -ErrorRecord $_
            Write-Error "Connectivity test failed: $_"
        }
    }

    end {
        $results.EndTime = Get-Date
        $results.Duration = $results.EndTime - $results.StartTime
        return [PSCustomObject]$results
    }
}
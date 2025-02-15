function Test-ValidationMatrix {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [string]$ConfigPath = ".\Config\validation-matrix.json",
        [Parameter()]
        [switch]$DetailedOutput
    )

    begin {
        $validationMatrix = Get-Content $ConfigPath | ConvertFrom-Json
        $results = @{
            ServerName = $ServerName
            Timestamp = Get-Date
            Tests = @()
            OverallStatus = 'Unknown'
            Score = 0.0
        }
    }

    process {
        try {
            # Connectivity Tests
            $connectivityTests = @{
                Category = 'Connectivity'
                Weight = 0.4
                Tests = @(
                    @{
                        Name = 'Azure Management Endpoint'
                        Test = { Test-NetConnection -ComputerName "management.azure.com" -Port 443 }
                        ExpectedResult = { param($result) $result.TcpTestSucceeded }
                        Critical = $true
                    },
                    @{
                        Name = 'Azure Identity Endpoint'
                        Test = { Test-NetConnection -ComputerName "login.microsoftonline.com" -Port 443 }
                        ExpectedResult = { param($result) $result.TcpTestSucceeded }
                        Critical = $true
                    },
                    @{
                        Name = 'Proxy Configuration'
                        Test = { Test-ProxyConfiguration -ServerName $ServerName }
                        ExpectedResult = { param($result) $result.IsValid }
                        Critical = $false
                    }
                )
            }

            # Security Tests
            $securityTests = @{
                Category = 'Security'
                Weight = 0.3
                Tests = @(
                    @{
                        Name = 'TLS 1.2 Configuration'
                        Test = { Test-TLSConfiguration -ServerName $ServerName }
                        ExpectedResult = { param($result) $result.TLS12Enabled }
                        Critical = $true
                    },
                    @{
                        Name = 'Certificate Validation'
                        Test = { Test-CertificateTrust -ServerName $ServerName }
                        ExpectedResult = { param($result) $result.IsValid }
                        Critical = $true
                    },
                    @{
                        Name = 'Service Principal'
                        Test = { Test-ServicePrincipal -ServerName $ServerName }
                        ExpectedResult = { param($result) $result.IsValid }
                        Critical = $true
                    }
                )
            }

            # Agent Tests
            $agentTests = @{
                Category = 'Agent'
                Weight = 0.3
                Tests = @(
                    @{
                        Name = 'Service Status'
                        Test = { Get-Service -Name himds -ComputerName $ServerName }
                        ExpectedResult = { param($result) $result.Status -eq 'Running' }
                        Critical = $true
                    },
                    @{
                        Name = 'Configuration Status'
                        Test = { Test-ArcConfiguration -ServerName $ServerName }
                        ExpectedResult = { param($result) $result.IsValid }
                        Critical = $false
                    },
                    @{
                        Name = 'Resource Provider'
                        Test = { Test-ResourceProvider -ServerName $ServerName }
                        ExpectedResult = { param($result) $result.IsRegistered }
                        Critical = $true
                    }
                )
            }

            # Execute all test categories
            $testCategories = @($connectivityTests, $securityTests, $agentTests)
            foreach ($category in $testCategories) {
                $categoryResults = @{
                    Category = $category.Category
                    Weight = $category.Weight
                    TestResults = @()
                    Score = 0.0
                }

                foreach ($test in $category.Tests) {
                    $testResult = @{
                        Name = $test.Name
                        Critical = $test.Critical
                        Status = 'Unknown'
                        Error = $null
                    }

                    try {
                        $result = & $test.Test
                        $testResult.Status = & $test.ExpectedResult $result
                    }
                    catch {
                        $testResult.Status = $false
                        $testResult.Error = $_.Exception.Message
                    }

                    $categoryResults.TestResults += $testResult
                }

                # Calculate category score
                $categoryResults.Score = ($categoryResults.TestResults | 
                    Where-Object Status -eq $true).Count / $category.Tests.Count

                $results.Tests += $categoryResults
            }

            # Calculate overall score
            $results.Score = ($results.Tests | 
                Measure-Object -Property Score -Average).Average

            # Determine overall status
            $results.OverallStatus = if ($results.Score -ge 0.95) {
                'Healthy'
            }
            elseif ($results.Score -ge 0.80) {
                'Warning'
            }
            else {
                'Critical'
            }
        }
        catch {
            $results.OverallStatus = 'Error'
            $results.Error = Convert-ErrorToObject $_
            Write-Error -Exception $_.Exception
        }
    }

    end {
        if (-not $DetailedOutput) {
            $results = $results | Select-Object ServerName, OverallStatus, Score
        }
        return [PSCustomObject]$results
    }
}
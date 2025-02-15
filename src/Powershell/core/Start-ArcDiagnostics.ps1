function Start-ArcDiagnostics {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [switch]$DetailedScan,
        [Parameter()]
        [string]$OutputPath = ".\Diagnostics",
        [Parameter()]
        [switch]$CollectLogs,
        [Parameter()]
        [int]$TimeoutSeconds = 300
    )

    begin {
        $diagnosticResults = @{
            ServerName = $ServerName
            Timestamp = Get-Date
            SystemState = @{}
            Connectivity = @{}
            Security = @{}
            AgentHealth = @{}
            DetailedAnalysis = @{}
            Recommendations = @()
            Errors = @()
        }

        if (-not (Test-Path $OutputPath)) {
            New-Item -Path $OutputPath -ItemType Directory -Force
        }

        Write-Log -Message "Starting diagnostic scan for server: $ServerName" -Level Information
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    }

    process {
        try {
            # System State Collection
            Write-Progress -Activity "Arc Diagnostics" -Status "Collecting System State" -PercentComplete 20
            $diagnosticResults.SystemState = Get-SystemState -ServerName $ServerName

            # Connectivity Analysis with enhanced endpoint checking
            Write-Progress -Activity "Arc Diagnostics" -Status "Analyzing Connectivity" -PercentComplete 40
            $diagnosticResults.Connectivity = Test-ArcConnectivity -ServerName $ServerName -TimeoutSeconds $TimeoutSeconds

            # Enhanced Security Assessment
            Write-Progress -Activity "Arc Diagnostics" -Status "Performing Security Assessment" -PercentComplete 60
            $diagnosticResults.Security = Test-SecurityState -ServerName $ServerName
            
            # Agent Health Check with extended metrics
            Write-Progress -Activity "Arc Diagnostics" -Status "Checking Agent Health" -PercentComplete 80
            $diagnosticResults.AgentHealth = Get-ArcAgentHealth -ServerName $ServerName

            if ($DetailedScan) {
                $diagnosticResults.DetailedAnalysis = @{
                    CertificateChain = Test-CertificateTrust -ServerName $ServerName
                    ProxyConfiguration = Get-ProxyConfiguration -ServerName $ServerName
                    FirewallRules = Get-ArcFirewallRules -ServerName $ServerName
                    PerformanceMetrics = Get-DetailedPerformanceMetrics -ServerName $ServerName
                    NetworkLatency = Test-NetworkLatency -ServerName $ServerName
                }
            }

            if ($CollectLogs) {
                $logCollection = Collect-ArcLogs -ServerName $ServerName -OutputPath $OutputPath
                $diagnosticResults.Logs = $logCollection.Summary
            }

            # Enhanced Recommendations with severity tracking
            $diagnosticResults.Recommendations = Get-DiagnosticRecommendations -DiagnosticData $diagnosticResults
        }
        catch {
            Write-Error "Diagnostic scan failed: $_"
            $diagnosticResults.Errors += Convert-ErrorToObject $_
        }
        finally {
            $stopwatch.Stop()
            $diagnosticResults.ExecutionTime = $stopwatch.Elapsed.TotalSeconds

            # Export Results with timestamp
            $fileName = "ArcDiagnostics_${ServerName}_$(Get-Date -Format 'yyyyMMddHHmmss').json"
            $diagnosticResults | ConvertTo-Json -Depth 10 | 
                Out-File (Join-Path $OutputPath $fileName)
            
            Write-Log -Message "Diagnostic scan completed. Results saved to: $fileName" -Level Information
        }
    }

    end {
        return [PSCustomObject]$diagnosticResults
    }
}

# Helper function for certificate trust verification
function Test-CertificateTrust {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName
    )

    $results = @{
        ChainStatus = @()
        ValidFrom = $null
        ValidTo = $null
        Issuer = $null
        CertificateErrors = @()
    }

    try {
        $cert = Get-ChildItem Cert:\LocalMachine\My | 
            Where-Object { $_.Subject -match $ServerName } |
            Select-Object -First 1

        if ($cert) {
            $chain = New-Object -TypeName System.Security.Cryptography.X509Certificates.X509Chain
            $chain.Build($cert) | Out-Null

            $results.ChainStatus = $chain.ChainElements | ForEach-Object {
                @{
                    Certificate = $_.Certificate.Subject
                    Status = $_.Certificate.Verify()
                    StatusFlags = $_.ChainElementStatus.Status
                }
            }
            
            $results.ValidFrom = $cert.NotBefore
            $results.ValidTo = $cert.NotAfter
            $results.Issuer = $cert.Issuer
        }
    }
    catch {
        $results.CertificateErrors += $_.Exception.Message
    }

    return $results
}
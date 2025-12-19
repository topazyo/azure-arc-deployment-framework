function Invoke-ArcAnalysis {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [hashtable]$DiagnosticData,
        [Parameter()]
        [switch]$IncludeAMA,
        [Parameter()]
        [string]$ConfigPath = (Join-Path $PSScriptRoot '..\..\config\analysis-patterns.json')
    )

    begin {
        $analysisResults = @{
            Timestamp = Get-Date
            ServerName = $DiagnosticData.ServerName
            Findings = @()
            Recommendations = @()
            RiskScore = 0.0
        }

        # Load analysis patterns (optional; analysis still works without them)
        $patterns = $null
        if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $ConfigPath)) {
            try {
                $patterns = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
            }
            catch {
                Write-Warning "Failed to load analysis patterns from '$ConfigPath': $($_.Exception.Message)"
                $patterns = $null
            }
        }
    }

    process {
        try {
            $findings = New-Object System.Collections.Generic.List[string]
            $recommendations = New-Object System.Collections.Generic.List[string]

            # Always include a baseline finding so callers have stable output.
            $findings.Add('ArcAnalysis:Completed')

            # Arc service status (supports either Service or ServiceStatus field)
            if ($DiagnosticData.ContainsKey('ArcStatus') -and $null -ne $DiagnosticData.ArcStatus) {
                $serviceStatus = $null
                if ($DiagnosticData.ArcStatus.PSObject.Properties.Match('ServiceStatus').Count -gt 0) {
                    $serviceStatus = $DiagnosticData.ArcStatus.ServiceStatus
                } elseif ($DiagnosticData.ArcStatus.PSObject.Properties.Match('Service').Count -gt 0) {
                    $serviceStatus = $DiagnosticData.ArcStatus.Service
                }

                if (-not [string]::IsNullOrWhiteSpace($serviceStatus)) {
                    if ($serviceStatus -ne 'Running') {
                        $findings.Add('Arc:ServiceNotRunning')
                        $recommendations.Add('Restart the Azure Arc agent service (himds).')
                    } else {
                        $findings.Add('Arc:ServiceRunning')
                    }
                }
            }

            # AMA analysis (only when requested)
            if ($IncludeAMA -and $DiagnosticData.ContainsKey('AMAStatus') -and $null -ne $DiagnosticData.AMAStatus) {
                $findings.Add('AMA')
                $recommendations.Add('Verify Azure Monitor Agent (AMA) service health and DCR assignment.')
            }

            if ($recommendations.Count -eq 0) {
                $recommendations.Add('No immediate remediation required; continue monitoring.')
            }

            # Risk score: simple heuristic returning a stable double in [0,1].
            $risk = 0.1
            if ($findings -contains 'Arc:ServiceNotRunning') {
                $risk = 0.9
            }
            $analysisResults.Findings = @($findings)
            $analysisResults.Recommendations = @($recommendations)
            $analysisResults.RiskScore = [double]$risk
        }
        catch {
            Write-Error "Analysis failed: $_"
            $analysisResults.Error = $_.Exception.Message
        }
    }

    end {
        return [PSCustomObject]$analysisResults
    }
}

function Analyze-ArcHealth {
    param ($Status, $Patterns)
    
    $findings = @()

    # Service Status Analysis
    if ($Status.ServiceStatus -ne "Running") {
        $findings += @{
            Component = "Arc Service"
            Category = "Service Health"
            Severity = "Critical"
            Finding = "Arc service is not running"
            Impact = "Agent is not functional"
            Context = $Status.ServiceStatus
        }
    }

    # Configuration Analysis
    if ($Status.Configuration) {
        foreach ($pattern in $Patterns.ConfigurationPatterns) {
            if (Test-Pattern -Data $Status.Configuration -Pattern $pattern) {
                $findings += @{
                    Component = "Arc Configuration"
                    Category = "Configuration"
                    Severity = $pattern.Severity
                    Finding = $pattern.Description
                    Impact = $pattern.Impact
                    Context = $pattern.MatchedValue
                }
            }
        }
    }

    # Heartbeat Analysis
    if ($Status.LastHeartbeat) {
        $heartbeatAge = (Get-Date) - $Status.LastHeartbeat
        if ($heartbeatAge.TotalMinutes -gt 15) {
            $findings += @{
                Component = "Arc Heartbeat"
                Category = "Connectivity"
                Severity = "Warning"
                Finding = "No recent heartbeat detected"
                Impact = "Agent may be disconnected"
                Context = "Last heartbeat: $($Status.LastHeartbeat)"
            }
        }
    }

    return $findings
}

function Analyze-AMAHealth {
    param ($Status, $Patterns)
    
    $findings = @()

    # Service Status Analysis
    if ($Status.ServiceStatus -ne "Running") {
        $findings += @{
            Component = "AMA Service"
            Category = "Service Health"
            Severity = "Critical"
            Finding = "AMA service is not running"
            Impact = "Data collection is not functional"
            Context = $Status.ServiceStatus
        }
    }

    # Data Collection Analysis
    if ($Status.DataCollection.Status -ne "Active") {
        $findings += @{
            Component = "Data Collection"
            Category = "Monitoring"
            Severity = "Warning"
            Finding = "Data collection is not active"
            Impact = "Monitoring data may be missing"
            Context = $Status.DataCollection.Status
        }
    }

    # DCR Status Analysis
    if ($Status.DCRStatus.State -ne "Enabled") {
        $findings += @{
            Component = "DCR"
            Category = "Configuration"
            Severity = "Warning"
            Finding = "Data Collection Rules not properly configured"
            Impact = "Data collection may be incomplete"
            Context = $Status.DCRStatus.State
        }
    }

    return $findings
}
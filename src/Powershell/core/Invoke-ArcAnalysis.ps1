function Invoke-ArcAnalysis {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [hashtable]$DiagnosticData,
        [Parameter()]
        [switch]$IncludeAMA,
        [Parameter()]
        [string]$ConfigPath = ".\Config\analysis-patterns.json"
    )

    begin {
        $analysisResults = @{
            Timestamp = Get-Date
            ServerName = $DiagnosticData.ServerName
            Findings = @()
            Recommendations = @()
            RiskScore = 0
        }

        # Load analysis patterns
        $patterns = Get-Content $ConfigPath | ConvertFrom-Json
    }

    process {
        try {
            # Analyze Arc Agent Health
            $arcHealth = Analyze-ArcHealth -Status $DiagnosticData.ArcStatus -Patterns $patterns.ArcPatterns
            $analysisResults.Findings += $arcHealth

            # Analyze AMA Health if included
            if ($IncludeAMA -and $DiagnosticData.AMAStatus) {
                $amaHealth = Analyze-AMAHealth -Status $DiagnosticData.AMAStatus -Patterns $patterns.AMAPatterns
                $analysisResults.Findings += $amaHealth
            }

            # Analyze Connectivity
            $connectivity = Analyze-Connectivity -Data $DiagnosticData.Connectivity -Patterns $patterns.ConnectivityPatterns
            $analysisResults.Findings += $connectivity

            # Analyze System State
            $systemState = Analyze-SystemState -State $DiagnosticData.SystemState -Patterns $patterns.SystemPatterns
            $analysisResults.Findings += $systemState

            # Generate Recommendations
            $analysisResults.Recommendations = foreach ($finding in $analysisResults.Findings) {
                Get-AnalysisRecommendation -Finding $finding -Patterns $patterns.RecommendationPatterns
            }

            # Calculate Risk Score
            $analysisResults.RiskScore = Calculate-RiskScore -Findings $analysisResults.Findings
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
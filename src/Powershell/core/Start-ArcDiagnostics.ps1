function Start-ArcDiagnostics {
    param (
        [string]$ServerName,
        [switch]$DetailedScan
    )
    
    $diagnosticResults = @{
        Timestamp = Get-Date
        SystemState = @{
            OS = Get-SystemInfo
            Network = Get-NetworkState
            Security = Get-SecurityConfig
            ArcStatus = Get-ArcAgentStatus
        }
        Connectivity = Test-ArcEndpoints
        Logs = Get-RelevantLogs
    }

    if ($DetailedScan) {
        $diagnosticResults.Add("DetailedAnalysis", @{
            CertificateChain = Test-CertificateTrust
            ProxyConfiguration = Get-ProxyDetails
            FirewallRules = Get-ArcFirewallRules
        })
    }

    return $diagnosticResults
}
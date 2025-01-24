function Invoke-ArcAnalysis {
    param (
        [Parameter(Mandatory)]
        [hashtable]$DiagnosticData
    )

    $analysisPatterns = @{
        ConnectivityIssues = {
            param($data)
            $data.Connectivity | 
                Where-Object { -not $_.TCPTestSucceeded } |
                Select-Object Endpoint, ErrorDetails
        }
        SecurityIssues = {
            param($data)
            @(
                $data.SystemState.Security.TLS12Enabled -eq $false
                $data.SystemState.Security.CertificateValid -eq $false
            ) | Where-Object { $_ }
        }
        AgentIssues = {
            param($data)
            $data.SystemState.ArcStatus |
                Where-Object Status -ne 'Connected'
        }
    }

    $results = foreach ($pattern in $analysisPatterns.GetEnumerator()) {
        @{
            Pattern = $pattern.Key
            Issues = & $pattern.Value $DiagnosticData
            Severity = Get-IssueSeverity -Issues $issues
            RecommendedAction = Get-RecommendedAction -PatternName $pattern.Key
        }
    }

    return $results
}
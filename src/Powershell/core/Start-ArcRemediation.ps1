function Start-ArcRemediation {
    param (
        [Parameter(Mandatory)]
        [array]$AnalysisResults
    )

    $remediationActions = @{
        ConnectivityIssues = {
            param($issue)
            try {
                $backup = Backup-NetworkConfig
                Set-ProxyConfiguration -NewConfig $issue.RecommendedConfig
                if (-not (Test-Connectivity)) { 
                    throw "Connectivity test failed after remediation" 
                }
            }
            catch {
                Restore-NetworkConfig -Backup $backup
                throw
            }
        }
        SecurityIssues = {
            param($issue)
            try {
                $backup = Backup-SecurityConfig
                Enable-TLS12
                Update-CertificateStore
                if (-not (Test-SecurityConfig)) { 
                    throw "Security validation failed after remediation" 
                }
            }
            catch {
                Restore-SecurityConfig -Backup $backup
                throw
            }
        }
    }

    foreach ($result in $AnalysisResults) {
        if ($remediationActions.ContainsKey($result.Pattern)) {
            & $remediationActions[$result.Pattern] $result
        }
    }
}
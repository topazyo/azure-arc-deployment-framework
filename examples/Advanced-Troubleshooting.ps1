# Advanced Troubleshooting Example
# Demonstrates comprehensive troubleshooting workflow

# Import required modules
Import-Module .\src\PowerShell\AzureArcDeployment.psm1

# Configuration
$troubleshootingParams = @{
    ServerName = "PROD-DB-01"
    DetailedAnalysis = $true
    GenerateReport = $true
    OutputPath = ".\troubleshooting_reports"
}

# Initialize logging
$logPath = ".\logs\troubleshooting_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
Start-Transcript -Path $logPath

try {
    # Step 1: Run AI-enhanced diagnostics
    Write-Host "Running AI-enhanced diagnostics..." -ForegroundColor Cyan
    $aiDiagnostics = Start-AIEnhancedTroubleshooting -ServerName $troubleshootingParams.ServerName

    # Step 2: Analyze patterns
    Write-Host "Analyzing patterns..." -ForegroundColor Cyan
    $patternAnalysis = Invoke-AIPatternAnalysis -LogPath $logPath

    # Step 3: Generate comprehensive report
    if ($troubleshootingParams.GenerateReport) {
        $reportData = @{
            ServerInfo = Get-ServerInventory -ServerName $troubleshootingParams.ServerName
            Diagnostics = $aiDiagnostics
            Patterns = $patternAnalysis
            Recommendations = Get-AIRecommendations -AnalysisData $patternAnalysis
        }

        $reportPath = Join-Path $troubleshootingParams.OutputPath "TroubleshootingReport_$(Get-Date -Format 'yyyyMMdd').json"
        $reportData | ConvertTo-Json -Depth 10 | Out-File $reportPath
        Write-Host "Report generated: $reportPath" -ForegroundColor Green
    }

    # Step 4: Display summary
    Write-Host "`nTroubleshooting Summary:" -ForegroundColor Yellow
    Write-Host "------------------------"
    Write-Host "Issues Found: $($aiDiagnostics.IssuesCount)"
    Write-Host "Critical Problems: $($aiDiagnostics.CriticalIssues.Count)"
    Write-Host "Recommended Actions: $($reportData.Recommendations.Count)"
} catch {
    Write-Error "Troubleshooting failed: $_"
} finally {
    Stop-Transcript
}
BeforeAll {
    # Import module and dependencies
    $modulePath = Join-Path $PSScriptRoot "..\..\..\src\PowerShell"
    Import-Module $modulePath\ArcDeploymentFramework.psd1 -Force

    # Test configurations
    $testConfig = @{
        ServerName = $env:TEST_SERVER_NAME
        WorkspaceId = $env:TEST_WORKSPACE_ID
        WorkspaceKey = $env:TEST_WORKSPACE_KEY
        Environment = "Test"
    }
}

Describe 'End-to-End Arc Deployment' {
    BeforeAll {
        # Initialize the framework
        Initialize-ArcDeployment -WorkspaceId $testConfig.WorkspaceId -WorkspaceKey $testConfig.WorkspaceKey
    }

    It 'Should complete full deployment lifecycle' {
        # 1. Prerequisites Check
        $prereqs = Test-ArcPrerequisites -ServerName $testConfig.ServerName -WorkspaceId $testConfig.WorkspaceId
        $prereqs.Success | Should -Be $true

        # 2. Security Baseline
        $security = Test-SecurityCompliance -ServerName $testConfig.ServerName
        $security.CompliantStatus | Should -Be $true

        # 3. Deploy Arc Agent
        $deployment = Deploy-ArcAgent -ServerName $testConfig.ServerName -DeployAMA
        $deployment.Status | Should -Be "Success"

        # 4. Validate Deployment
        $validation = Test-DeploymentHealth -ServerName $testConfig.ServerName -ValidateAMA
        $validation.Success | Should -Be $true

        # 5. Check Monitoring
        $monitoring = Get-AMAHealthStatus -ServerName $testConfig.ServerName -WorkspaceId $testConfig.WorkspaceId
        $monitoring.OverallHealth | Should -Be "Healthy"
    }
}

Describe 'End-to-End Troubleshooting' {
    It 'Should perform comprehensive troubleshooting' {
        # 1. Run Diagnostics
        $diagnostics = Start-ArcDiagnostics -ServerName $testConfig.ServerName -WorkspaceId $testConfig.WorkspaceId
        $diagnostics.Error | Should -BeNullOrEmpty

        # 2. Analyze Results
        $analysis = Invoke-ArcAnalysis -DiagnosticData $diagnostics
        $analysis.Findings | Should -Not -BeNullOrEmpty

        # 3. AI-Enhanced Analysis
        $aiAnalysis = Start-AIEnhancedTroubleshooting -ServerName $testConfig.ServerName
        $aiAnalysis.Insights | Should -Not -BeNullOrEmpty

        # 4. Verify Remediation
        if ($analysis.Recommendations) {
            $remediation = Start-ArcRemediation -AnalysisResults $analysis
            $remediation.Status | Should -Be "Success"
        }
    }
}

Describe 'End-to-End Performance Monitoring' {
    It 'Should monitor and analyze performance' {
        # 1. Collect Performance Metrics
        $metrics = Get-AMAPerformanceMetrics -ServerName $testConfig.ServerName
        $metrics.Summary | Should -Not -BeNullOrEmpty

        # 2. Check Log Ingestion
        $logIngestion = Test-LogIngestion -ServerName $testConfig.ServerName -WorkspaceId $testConfig.WorkspaceId
        $logIngestion.Status | Should -Be "Healthy"

        # 3. Analyze Trends
        $trends = $metrics.Samples | Measure-Object -Property 'CPUUsage' -Average -Maximum
        $trends.Average | Should -BeLessThan 80  # CPU usage should be under 80%

        # 4. Verify Recommendations
        if ($metrics.Recommendations) {
            $metrics.Recommendations | Should -Not -BeNullOrEmpty
            $metrics.Recommendations | ForEach-Object {
                $_.Component | Should -Not -BeNullOrEmpty
                $_.Recommendation | Should -Not -BeNullOrEmpty
            }
        }
    }
}
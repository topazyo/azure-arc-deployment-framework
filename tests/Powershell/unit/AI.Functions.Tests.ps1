# tests/Powershell/unit/AI.Functions.Tests.ps1
using namespace System.Collections.Generic

Import-Module -Name Pester -MinimumVersion 5.0.0 -Force

Describe "AI Functions" {
    BeforeAll {
        . "$PSScriptRoot/../../../src/Powershell/AI/Get-PredictiveInsights.ps1"
    }

    Context "Get-PredictiveInsights" {
        It "should run without errors with mandatory ServerName" {
            { Get-PredictiveInsights -ServerName "server01" } | Should -Not -Throw
        }

        It "should return a PSCustomObject" {
            Get-PredictiveInsights -ServerName "server01" | Should -BeOfType ([pscustomobject])
        }

        It "should return expected keys for Full analysis" {
            $insights = Get-PredictiveInsights -ServerName "server01" -AnalysisType "Full"
            $insights | Should -HaveParameter ("ServerName") -WithValue "server01"
            $insights | Should -HaveParameter ("AnalysisType") -WithValue "Full"
            $insights | Should -HaveParameter ("RiskScore")
            $insights.RiskScore | Should -BeGreaterOrEqual 0.1 | Should -BeLessOrEqual 0.9
            $insights | Should -HaveParameter ("Recommendations")
            $insights.Recommendations | Should -BeOfType ([System.Array])
        }
         It "should include PredictedFailures when RiskScore is high" {
            # This test might be flaky due to Get-Random. Consider mocking Get-Random for robust tests.
            # For now, we'll accept potential flakiness for placeholder functions.
            Mock-Command Get-Random -MockWith { param($Minimum, $Maximum) return if ($Minimum -eq 0.1) { 0.8 } else { 0.7 } } -Verifiable # Mock high risk score

            $insights = Get-PredictiveInsights -ServerName "server01" -AnalysisType "Full"
            $insights.PredictedFailures | Should -Not -BeNullOrEmpty
            $insights.PredictedFailures[0] | Should -HaveParameter ("Component")

            Assert-VerifiableMocks
        }
    }
}

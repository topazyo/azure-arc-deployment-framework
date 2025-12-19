# tests/Powershell/unit/InvokeAIPatternAnalysis.Tests.ps1
Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

Describe 'Invoke-AIPatternAnalysis.ps1' {
    BeforeAll {
        $script:TestScriptRootSafe = if ($PSCommandPath) { Split-Path $PSCommandPath -Parent } elseif ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent } else { (Get-Location).Path }
        $script:ScriptPath_Patterns = [System.IO.Path]::GetFullPath((Join-Path $script:TestScriptRootSafe '..\..\..\src\Powershell\AI\Invoke-AIPatternAnalysis.ps1'))
        if (-not (Test-Path $script:ScriptPath_Patterns -PathType Leaf)) { throw "Script not found at $script:ScriptPath_Patterns" }
        . $script:ScriptPath_Patterns
    }

    It 'groups patterns, scores severity, and returns recommendations' {
        . $script:ScriptPath_Patterns
        $logs = @(
            '2025-12-15 10:00:00 ERROR Disk failure detected on node01',
            '2025-12-15 11:00:00 WARN CPU usage high on node02'
        )

        $result = Invoke-AIPatternAnalysis -LogPath 'unused' -LogContent $logs -DaysToAnalyze 30 -GenerateRecommendations

        $result.Patterns.Count | Should -Be 2
        $result.Statistics.TotalErrors | Should -Be 2
        $result.Statistics.MostCommonCategory | Should -Not -BeNullOrEmpty
        ($result.Patterns | Where-Object { $_.Category -eq 'Storage' }).SeverityScore | Should -BeGreaterThan 0
        $result.Recommendations.Count | Should -Be 2
    }

    It 'respects DaysToAnalyze cutoff' {
        . $script:ScriptPath_Patterns
        $recent = (Get-Date).AddDays(-5).ToString('yyyy-MM-dd HH:mm:ss') + ' ERROR Service crash'
        $stale = (Get-Date).AddDays(-60).ToString('yyyy-MM-dd HH:mm:ss') + ' ERROR Old issue'
        $result = Invoke-AIPatternAnalysis -LogPath 'unused' -LogContent @($recent, $stale) -DaysToAnalyze 30

        $result.Statistics.TotalErrors | Should -Be 1
        $result.Patterns.Count | Should -Be 1
    }
}

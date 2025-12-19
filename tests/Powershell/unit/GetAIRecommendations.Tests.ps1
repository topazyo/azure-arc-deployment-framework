# tests/Powershell/unit/GetAIRecommendations.Tests.ps1
Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

Describe 'Get-AIRecommendations.ps1' {
    BeforeAll {
        $script:TestScriptRootSafe = if ($PSCommandPath) { Split-Path $PSCommandPath -Parent } elseif ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent } else { (Get-Location).Path }
        $script:ScriptPath_Recommendations = [System.IO.Path]::GetFullPath((Join-Path $script:TestScriptRootSafe '..\..\..\src\Powershell\AI\Get-AIRecommendations.ps1'))
        if (-not (Test-Path $script:ScriptPath_Recommendations -PathType Leaf)) {
            throw "Script not found at $script:ScriptPath_Recommendations"
        }
        . $script:ScriptPath_Recommendations
    }

    AfterAll {
        Remove-Item -Path (Join-Path $script:TestScriptRootSafe 'rules-gt.json') -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $script:TestScriptRootSafe 'rules-regex.json') -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $script:TestScriptRootSafe 'rules-none.json') -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $script:TestScriptRootSafe 'log1.log') -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $script:TestScriptRootSafe 'log2.log') -ErrorAction SilentlyContinue
        Remove-Item -Path (Join-Path $script:TestScriptRootSafe 'log3.log') -ErrorAction SilentlyContinue
    }
    It 'applies GreaterThan rule and emits recommendation' {
        . $script:ScriptPath_Recommendations
        $rulesPath = Join-Path $script:TestScriptRootSafe 'rules-gt.json'
        $rules = @{ rules = @(
            @{ RuleName='HighCPU'; IfCondition=@{ CpuUsage = @{ GreaterThan = 80 } }; ThenRecommend = @(
                @{ RecommendationId='REC_HIGHCPU'; Title='Scale Out'; Description=''; Severity='High'; Confidence=0.9 }
            ) }
        )}
        $rules | ConvertTo-Json -Depth 5 | Set-Content -Path $rulesPath -Encoding ASCII

        $input = @([pscustomobject]@{ CpuUsage = 85 })
        $result = Get-AIRecommendations -InputFeatures $input -RecommendationRulesPath $rulesPath -LogPath (Join-Path $script:TestScriptRootSafe 'log1.log')

        $result.Count | Should -Be 1
        $result[0].Recommendations.Count | Should -Be 1
        $result[0].Recommendations[0].RecommendationId | Should -Be 'REC_HIGHCPU'
    }

    It 'enforces MaxRecommendationsPerInput and matches regex' {
        . $script:ScriptPath_Recommendations
        $rulesPath = Join-Path $script:TestScriptRootSafe 'rules-regex.json'
        $logPath = Join-Path $script:TestScriptRootSafe 'log2.log'
        $rules = @{ rules = @(
            @{ RuleName='DiskAlerts'; IfCondition=@{ Message = @{ RegexMatch = 'disk\s+failure' } }; ThenRecommend = @(
                @{ RecommendationId='REC_DISK1'; Title='Check Disk'; Description=''; Severity='High'; Confidence=0.8 },
                @{ RecommendationId='REC_DISK2'; Title='Failover'; Description=''; Severity='High'; Confidence=0.7 }
            ) }
        )}
        $rules | ConvertTo-Json -Depth 5 | Set-Content -Path $rulesPath -Encoding ASCII

        $input = @([pscustomobject]@{ Message = 'Disk failure observed on node' })
        $result = Get-AIRecommendations -InputFeatures $input -RecommendationRulesPath $rulesPath -MaxRecommendationsPerInput 1 -LogPath $logPath

        $logContent = Get-Content -Path $logPath -ErrorAction SilentlyContinue
        $logContent | Should -Not -BeNullOrEmpty
        ($logContent -join "`n") | Should -Not -Match 'Failed to load or parse'


        $result.Count | Should -Be 1
        $result[0].Recommendations.Count | Should -Be 1
        $result[0].Recommendations[0].RecommendationId | Should -Be 'REC_DISK1'
    }

    It 'returns no recommendations when conditions do not match' {
        . $script:ScriptPath_Recommendations
        $rulesPath = Join-Path $script:TestScriptRootSafe 'rules-none.json'
        $rules = @{ rules = @(
            @{ RuleName='MemoryPressure'; IfCondition=@{ MemoryUsage = @{ GreaterThan = 90 } }; ThenRecommend = @(
                @{ RecommendationId='REC_MEM1'; Title='Scale Memory'; Description=''; Severity='High'; Confidence=0.6 }
            ) }
        )}
        $rules | ConvertTo-Json -Depth 5 | Set-Content -Path $rulesPath -Encoding ASCII

        $input = @([pscustomobject]@{ CpuUsage = 20 })
        $result = Get-AIRecommendations -InputFeatures $input -RecommendationRulesPath $rulesPath -LogPath (Join-Path $script:TestScriptRootSafe 'log3.log')

        $result | Should -BeNullOrEmpty
    }
}

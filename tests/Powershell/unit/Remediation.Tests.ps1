# tests/Powershell/unit/Remediation.Tests.ps1
using namespace System.Management.Automation

Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

$script:TestScriptRootSafe = if ($PSCommandPath) { Split-Path $PSCommandPath -Parent } elseif ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent } else { (Get-Location).Path }

Describe 'Start-RemediationAction.ps1' {
    BeforeAll {
        if (-not $script:TestScriptRootSafe) {
            $script:TestScriptRootSafe = if ($PSCommandPath) { Split-Path $PSCommandPath -Parent } elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent } else { (Get-Location).Path }
        }
        $script:ScriptPath_StartRemediation = [System.IO.Path]::GetFullPath((Join-Path $script:TestScriptRootSafe '..\..\..\src\Powershell\remediation\Start-RemediationAction.ps1'))
        . $script:ScriptPath_StartRemediation
    }


    It 'skips execution when -WhatIf is used' {
        $approvedAction = [PSCustomObject]@{
            RemediationActionId = 'REM_Skip'
            Title = 'Skip run'
            ImplementationType = 'Manual'
            Description = 'Manual action not executed under WhatIf.'
            ResolvedParameters = @{}
        }

        $result = Start-RemediationAction -ApprovedAction $approvedAction -LogPath (Join-Path $TestDrive 'start-remediation-skip.log') -WhatIf

        $result.Status | Should -Be 'SkippedWhatIf'
        $result.Output | Should -Match 'Execution skipped'
    }

    It 'executes a function action and captures output' {
        function Invoke-RemediationProbe {
            param([string]$Name)
            return "Hello $Name"
        }

        $approvedAction = [PSCustomObject]@{
            RemediationActionId = 'REM_Function'
            Title = 'Call function'
            ImplementationType = 'Function'
            TargetFunction = 'Invoke-RemediationProbe'
            ResolvedParameters = @{ Name = 'Arc' }
        }

        $result = Start-RemediationAction -ApprovedAction $approvedAction -LogPath (Join-Path $TestDrive 'start-remediation-func.log')

        $result.Status | Should -Be 'Success'
        $result.Output | Should -Match 'Hello Arc'
        $result.Errors | Should -BeNullOrEmpty
    }

    It 'runs backup script when backup is enabled' {
        $backupScript = Join-Path $TestDrive 'Backup-OperationState.ps1'
        @"
param([string]$OperationName,[string]$BackupPath)
if (-not (Test-Path $BackupPath)) { New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null }
Set-Content -Path (Join-Path $BackupPath 'backup.marker') -Value $OperationName
"@ | Set-Content -Path $backupScript -Encoding ASCII

        $approvedAction = [PSCustomObject]@{
            RemediationActionId = 'REM_Backup'
            Title = 'Manual with backup'
            ImplementationType = 'Manual'
            Description = 'Backup before manual step'
            ResolvedParameters = @{}
        }

        $backupTarget = Join-Path $TestDrive 'backup-target'
        $result = Start-RemediationAction -ApprovedAction $approvedAction -BackupStateBeforeExecution:$true -BackupScriptPath $backupScript -BackupPath $backupTarget -LogPath (Join-Path $TestDrive 'start-remediation-backup.log')

        $result.BackupPerformed | Should -BeTrue
        $result.BackupPathUsed | Should -Be $backupTarget
    }

    It 'passes compress flags to backup script when available' {
        $backupScript = Join-Path $TestDrive 'Backup-OperationState.ps1'
        @"
param([string]$OperationName,[string]$BackupPath,[switch]$Compress,[switch]$KeepUncompressed)
if (-not (Test-Path $BackupPath)) { New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null }
Set-Content -Path (Join-Path $BackupPath 'flags.txt') -Value "Compress=$Compress;Keep=$KeepUncompressed"
"@ | Set-Content -Path $backupScript -Encoding ASCII

        $approvedAction = [PSCustomObject]@{
            RemediationActionId = 'REM_BackupFlags'
            Title = 'Manual with compressed backup'
            ImplementationType = 'Manual'
            Description = 'Backup with flags'
            ResolvedParameters = @{}
        }

        $backupTarget = Join-Path $TestDrive 'backup-flags'
        $result = Start-RemediationAction -ApprovedAction $approvedAction -BackupStateBeforeExecution:$true -BackupScriptPath $backupScript -BackupPath $backupTarget -BackupCompress -BackupKeepUncompressed -LogPath (Join-Path $TestDrive 'start-remediation-backupflags.log')

        $result.BackupPerformed | Should -BeTrue
        $result.BackupCompressRequested | Should -BeTrue
        $result.BackupKeepUncompressedRequested | Should -BeTrue
    }

    It 'captures exit code when executable fails' {
        $exePath = Join-Path $TestDrive 'fail.cmd'
        "@echo off`nexit 5" | Set-Content -Path $exePath -Encoding ASCII

        $approvedAction = [PSCustomObject]@{
            RemediationActionId = 'REM_ExeFail'
            Title = 'Failing exe'
            ImplementationType = 'Executable'
            TargetScriptPath = $exePath
            ResolvedParameters = @{}
        }

        $result = Start-RemediationAction -ApprovedAction $approvedAction -LogPath (Join-Path $TestDrive 'start-remediation-exe.log')

        $result.Status | Should -Be 'Failed'
        $result.ExitCode | Should -Be 5
        $result.Errors | Should -Match 'code: 5'
    }
}

Describe 'Test-RemediationResult.ps1' {
    BeforeAll {
        if (-not $script:TestScriptRootSafe) {
            $script:TestScriptRootSafe = if ($PSCommandPath) { Split-Path $PSCommandPath -Parent } elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent } else { (Get-Location).Path }
        }
        $script:ScriptPath_TestRemediation = [System.IO.Path]::GetFullPath((Join-Path $script:TestScriptRootSafe '..\..\..\src\Powershell\remediation\Test-RemediationResult.ps1'))
        . $script:ScriptPath_TestRemediation
    }


    It 'returns success when function validation matches expected result' {
        function Invoke-ValidationProbe {
            param([bool]$Flag)
            return $Flag
        }

        $steps = @(
            [PSCustomObject]@{
                ValidationStepId = 'VAL_FUNC_OK'
                ValidationType = 'FunctionCall'
                ValidationTarget = 'Invoke-ValidationProbe'
                ExpectedResult = '$true'
                Parameters = @{ Flag = $true }
                Description = 'Function returns true when Flag is true'
            }
        )

        $result = Test-RemediationResult -ValidationSteps $steps -LogPath (Join-Path $TestDrive 'test-remediation-success.log')

        $result.OverallValidationStatus | Should -Be 'Success'
        $result.ValidationStepResults[0].Status | Should -Be 'Success'
    }

    It 'flags failure when validation target is missing' {
        $missingScriptPath = Join-Path $TestDrive 'missing-validation.ps1'
        $steps = @(
            [PSCustomObject]@{
                ValidationStepId = 'VAL_SCRIPT_MISSING'
                ValidationType = 'ScriptExecutionCheck'
                ValidationTarget = $missingScriptPath
                ExpectedResult = '$true'
                Parameters = @{}
                Description = 'Missing validation script should fail'
            }
        )

        $result = Test-RemediationResult -ValidationSteps $steps -LogPath (Join-Path $TestDrive 'test-remediation-missing.log')

        $result.OverallValidationStatus | Should -Be 'Failed'
        $result.ValidationStepResults[0].Status | Should -Be 'Failed'
        $result.ValidationStepResults[0].ActualResult | Should -Be 'NotFound'
    }

    It 'marks manual checks as requiring confirmation' {
        $steps = @(
            [PSCustomObject]@{
                ValidationStepId = 'VAL_MANUAL'
                ValidationType = 'ManualCheck'
                ValidationTarget = 'Manual review'
                ExpectedResult = ''
                Parameters = @{}
                Description = 'Operator must confirm'
            }
        )

        $result = Test-RemediationResult -ValidationSteps $steps -LogPath (Join-Path $TestDrive 'test-remediation-manual.log')

        $result.OverallValidationStatus | Should -Be 'RequiresManualActionOrNotImplemented'
        $result.ValidationStepResults[0].Status | Should -Be 'RequiresManualConfirmation'
        $result.ValidationStepResults[0].ActualResult | Should -Be 'PendingOperatorConfirmation'
    }

    It 'marks unknown validation types as not implemented' {
        $steps = @(
            [PSCustomObject]@{
                ValidationStepId = 'VAL_UNKNOWN'
                ValidationType = 'UnknownType'
                ValidationTarget = 'n/a'
                ExpectedResult = ''
                Parameters = @{}
                Description = 'Unknown validation type'
            }
        )

        $result = Test-RemediationResult -ValidationSteps $steps -LogPath (Join-Path $TestDrive 'test-remediation-unknown.log')

        $result.OverallValidationStatus | Should -Be 'RequiresManualActionOrNotImplemented'
        $result.ValidationStepResults[0].Status | Should -Be 'NotImplemented'
        $result.ValidationStepResults[0].ActualResult | Should -Be 'UnsupportedValidationType'
    }

    It 'flags function exceptions as execution errors' {
        function Invoke-ValidationFailure {
            throw 'boom'
        }

        $steps = @(
            [PSCustomObject]@{
                ValidationStepId = 'VAL_FUNC_FAIL'
                ValidationType = 'FunctionCall'
                ValidationTarget = 'Invoke-ValidationFailure'
                ExpectedResult = '$true'
                Parameters = @{}
                Description = 'Function throws'
            }
        )

        $result = Test-RemediationResult -ValidationSteps $steps -LogPath (Join-Path $TestDrive 'test-remediation-func-fail.log')

        $result.OverallValidationStatus | Should -Be 'Failed'
        $result.ValidationStepResults[0].Status | Should -Be 'FailedExecutionError'
        $result.ValidationStepResults[0].ActualResult | Should -Be 'ExecutionError'
        $result.ValidationStepResults[0].Notes | Should -Match 'boom'
    }
}

Describe 'Start-AIRemediationWorkflow.ps1' {
    BeforeAll {
        if (-not $script:TestScriptRootSafe) {
            $script:TestScriptRootSafe = if ($PSCommandPath) { Split-Path $PSCommandPath -Parent } elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent } else { (Get-Location).Path }
        }
        $script:ScriptPath_Workflow = [System.IO.Path]::GetFullPath((Join-Path $script:TestScriptRootSafe '..\..\..\src\Powershell\AI\Start-AIRemediationWorkflow.ps1'))
        . $script:ScriptPath_Workflow

        $script:WorkflowScriptRoot = Split-Path $ScriptPath_Workflow -Parent
        $script:PathConvertToAIFeatures = Join-Path $WorkflowScriptRoot 'ConvertTo-AIFeatures.ps1'
        $script:PathGetAIRecommendations = Join-Path $WorkflowScriptRoot 'Get-AIRecommendations.ps1'
        $script:PathStartRemediationAction = Join-Path $WorkflowScriptRoot '..\remediation\Start-RemediationAction.ps1'
        $script:PathGetValidationStep = Join-Path $WorkflowScriptRoot '..\remediation\Get-ValidationStep.ps1'
        $script:PathTestRemediationResult = Join-Path $WorkflowScriptRoot '..\remediation\Test-RemediationResult.ps1'
    }

    It 'runs automatic remediation flow with mocks and returns summary' {
        $features = @([PSCustomObject]@{ FeatureA = 1 })
        $recommendations = @(
            [PSCustomObject]@{
                InputItem = $features[0]
                Recommendations = @(
                    [PSCustomObject]@{
                        RecommendationId = 'REC_SVC001'
                        Title = 'Check Service Logs'
                        Description = 'desc'
                        Severity = 'High'
                        Confidence = 0.9
                    }
                )
            }
        )

        $global:PSScriptRoot = $script:WorkflowScriptRoot
        $global:PSCommandPath = $script:ScriptPath_Workflow
        $global:StartAIRemediationWorkflowRoot = $script:TestScriptRootSafe
        $script:StartAIRemediationWorkflowRoot = $script:TestScriptRootSafe

        $localConvertPath = Join-Path $script:TestScriptRootSafe 'ConvertTo-AIFeatures.ps1'
        $localRecoPath = Join-Path $script:TestScriptRootSafe 'Get-AIRecommendations.ps1'
        $localRemediationDir = Join-Path $script:TestScriptRootSafe '..\remediation'
        if (-not (Test-Path $localRemediationDir)) { New-Item -ItemType Directory -Path $localRemediationDir -Force | Out-Null }
        $localStartRemediationPath = Join-Path $localRemediationDir 'Start-RemediationAction.ps1'

        $global:WorkflowStubFeatures = $features
        $global:WorkflowStubRecommendations = $recommendations

$convertStub = @'
param([object[]]$InputData,[string]$LogPath)
return $global:WorkflowStubFeatures
'@
        Set-Content -Path $localConvertPath -Value $convertStub -Encoding ASCII

$recoStub = @'
param([object[]]$InputFeatures,[string]$RecommendationRulesPath,[string]$LogPath)
return $global:WorkflowStubRecommendations
'@
        Set-Content -Path $localRecoPath -Value $recoStub -Encoding ASCII

$remediationStub = @'
param([pscustomobject]$ApprovedAction,[string]$LogPath)
return [pscustomobject]@{ RemediationActionId = $ApprovedAction.RemediationActionId; Status = 'Success'; Output = 'ok'; Errors = '' }
'@
        Set-Content -Path $localStartRemediationPath -Value $remediationStub -Encoding ASCII

        Mock Test-Path -MockWith {
            param($Path, $PathType)
            if (-not $Path) { return $false }
            if ($Path -like '*ConvertTo-AIFeatures.ps1') { return $true }
            if ($Path -like '*Get-AIRecommendations.ps1') { return $true }
            if ($Path -like '*Start-RemediationAction.ps1') { return $true }
            if ($Path -like '*Get-ValidationStep.ps1') { return $false }
            if ($Path -like '*Test-RemediationResult.ps1') { return $false }
            return $false
        }

        Mock $script:PathConvertToAIFeatures -MockWith { param($InputData, $LogPath) return $features }
        Mock (Join-Path $script:TestScriptRootSafe 'ConvertTo-AIFeatures.ps1') -MockWith { param($InputData, $LogPath) return $features }
        Mock $script:PathGetAIRecommendations -MockWith { param($InputFeatures, $RecommendationRulesPath, $LogPath) return $recommendations }
        Mock (Join-Path $script:TestScriptRootSafe 'Get-AIRecommendations.ps1') -MockWith { param($InputFeatures, $RecommendationRulesPath, $LogPath) return $recommendations }
        Mock $script:PathStartRemediationAction -MockWith {
            param($ApprovedAction, $LogPath)
            return [PSCustomObject]@{
                RemediationActionId = $ApprovedAction.RemediationActionId
                Status = 'Success'
                Output = 'ok'
                Errors = ''
            }
        }
        Mock (Join-Path $script:TestScriptRootSafe '..\remediation\Start-RemediationAction.ps1') -MockWith {
            param($ApprovedAction, $LogPath)
            return [PSCustomObject]@{
                RemediationActionId = $ApprovedAction.RemediationActionId
                Status = 'Success'
                Output = 'ok'
                Errors = ''
            }
        }

        $input = @([PSCustomObject]@{ Name = 'srv1'; Message = 'Service terminated unexpectedly' })
        $result = Start-AIRemediationWorkflow -InputData $input -RemediationMode 'Automatic' -LogPath (Join-Path $TestDrive 'workflow.log') -ScriptRootOverride $script:TestScriptRootSafe -ConvertToAIFeaturesPath $localConvertPath -GetAIRecommendationsPath $localRecoPath -StartRemediationActionPath $localStartRemediationPath -GetValidationStepPath (Join-Path $script:TestScriptRootSafe '..\remediation\Get-ValidationStep.ps1') -TestRemediationResultPath (Join-Path $script:TestScriptRootSafe '..\remediation\Test-RemediationResult.ps1')

        $result.OverallStatus | Should -Be 'Completed'
        $result.InputItemCount | Should -Be 1
        $result.FeaturesGeneratedCount | Should -Be 1
        $result.RecommendationsOutputCount | Should -Be 1
        $result.RemediationResults.Count | Should -Be 1
        $result.RemediationResults[0].Status | Should -Be 'Success'
    }

    It 'surfaces remediation failures in overall status' {
        $features = @([PSCustomObject]@{ FeatureA = 1 })
        $recommendations = @(
            [PSCustomObject]@{
                InputItem = $features[0]
                Recommendations = @(
                    [PSCustomObject]@{
                        RecommendationId = 'REC_OK'
                        Title = 'OK action'
                        Description = 'desc'
                        Severity = 'High'
                        Confidence = 0.9
                    },
                    [PSCustomObject]@{
                        RecommendationId = 'REC_FAIL'
                        Title = 'Fail action'
                        Description = 'desc'
                        Severity = 'High'
                        Confidence = 0.9
                    }
                )
            }
        )

        $global:PSScriptRoot = $script:WorkflowScriptRoot
        $global:PSCommandPath = $script:ScriptPath_Workflow
        $global:StartAIRemediationWorkflowRoot = $script:TestScriptRootSafe
        $script:StartAIRemediationWorkflowRoot = $script:TestScriptRootSafe

        $localConvertPath = Join-Path $script:TestScriptRootSafe 'ConvertTo-AIFeatures.ps1'
        $localRecoPath = Join-Path $script:TestScriptRootSafe 'Get-AIRecommendations.ps1'
        $localRemediationDir = Join-Path $script:TestScriptRootSafe '..\remediation'
        if (-not (Test-Path $localRemediationDir)) { New-Item -ItemType Directory -Path $localRemediationDir -Force | Out-Null }
        $localStartRemediationPath = Join-Path $localRemediationDir 'Start-RemediationAction.ps1'

        "param([object[]]`$InputData,[string]`$LogPath)`nreturn `$global:featuresData" | Set-Content -Path $localConvertPath -Encoding ASCII

        $global:featuresData = $features
        $global:recommendationsData = $recommendations
        "param([object[]]`$InputFeatures,[string]`$RecommendationRulesPath,[string]`$LogPath)`nreturn `$global:recommendationsData" | Set-Content -Path $localRecoPath -Encoding ASCII

        "param([pscustomobject]`$ApprovedAction,[string]`$LogPath) if (`$ApprovedAction.RemediationActionId -eq 'REM_REC_FAIL') { return [pscustomobject]@{ RemediationActionId = `$ApprovedAction.RemediationActionId; Status = 'Failed'; Output = ''; Errors = 'boom' } } return [pscustomobject]@{ RemediationActionId = `$ApprovedAction.RemediationActionId; Status = 'Success'; Output = 'ok'; Errors = '' }" | Set-Content -Path $localStartRemediationPath -Encoding ASCII

        Mock Test-Path -MockWith {
            param($Path, $PathType)
            if ($Path -like '*ConvertTo-AIFeatures.ps1') { return $true }
            if ($Path -like '*Get-AIRecommendations.ps1') { return $true }
            if ($Path -like '*Start-RemediationAction.ps1') { return $true }
            if ($Path -like '*Get-ValidationStep.ps1') { return $false }
            if ($Path -like '*Test-RemediationResult.ps1') { return $false }
            return $false
        }

        Mock $localConvertPath -MockWith { param($InputData, $LogPath) return $features }
        Mock $localRecoPath -MockWith { param($InputFeatures, $RecommendationRulesPath, $LogPath) return $recommendations }
        Mock $localStartRemediationPath -MockWith {
            param($ApprovedAction, $LogPath)
            if ($ApprovedAction.RemediationActionId -eq 'REM_REC_FAIL') {
                return [PSCustomObject]@{ RemediationActionId = $ApprovedAction.RemediationActionId; Status = 'Failed'; Output = ''; Errors = 'boom' }
            }
            return [PSCustomObject]@{ RemediationActionId = $ApprovedAction.RemediationActionId; Status = 'Success'; Output = 'ok'; Errors = '' }
        }

        $input = @([PSCustomObject]@{ Name = 'srv1'; Message = 'Service terminated unexpectedly' })
        $result = Start-AIRemediationWorkflow -InputData $input -RemediationMode 'Automatic' -LogPath (Join-Path $TestDrive 'workflow-fail.log') -ScriptRootOverride $script:TestScriptRootSafe -ConvertToAIFeaturesPath $localConvertPath -GetAIRecommendationsPath $localRecoPath -StartRemediationActionPath $localStartRemediationPath -GetValidationStepPath (Join-Path $script:TestScriptRootSafe '..\remediation\Get-ValidationStep.ps1') -TestRemediationResultPath (Join-Path $script:TestScriptRootSafe '..\remediation\Test-RemediationResult.ps1')

        $result.OverallStatus | Should -Be 'CompletedWithFailures'
        $result.RemediationResults.Count | Should -Be 2
    }

    It 'runs validation when rules are provided' {
        $features = @([PSCustomObject]@{ FeatureA = 1 })
        $recommendations = @(
            [PSCustomObject]@{
                InputItem = $features[0]
                Recommendations = @(
                    [PSCustomObject]@{
                        RecommendationId = 'REC_VAL'
                        Title = 'Validate action'
                        Description = 'desc'
                        Severity = 'High'
                        Confidence = 0.9
                    }
                )
            }
        )

        $global:PSScriptRoot = $script:WorkflowScriptRoot
        $global:PSCommandPath = $script:ScriptPath_Workflow
        $global:StartAIRemediationWorkflowRoot = $script:TestScriptRootSafe
        $script:StartAIRemediationWorkflowRoot = $script:TestScriptRootSafe

        $localConvertPath = Join-Path $script:TestScriptRootSafe 'ConvertTo-AIFeatures.ps1'
        $localRecoPath = Join-Path $script:TestScriptRootSafe 'Get-AIRecommendations.ps1'
        $localRemediationDir = Join-Path $script:TestScriptRootSafe '..\remediation'
        if (-not (Test-Path $localRemediationDir)) { New-Item -ItemType Directory -Path $localRemediationDir -Force | Out-Null }
        $localStartRemediationPath = Join-Path $localRemediationDir 'Start-RemediationAction.ps1'
        $localGetValidationPath = Join-Path $localRemediationDir 'Get-ValidationStep.ps1'
        $localTestValidationPath = Join-Path $localRemediationDir 'Test-RemediationResult.ps1'

        "param([object[]]`$InputData,[string]`$LogPath)`nreturn `$global:featuresData" | Set-Content -Path $localConvertPath -Encoding ASCII
        $global:featuresData = $features
        $global:recommendationsData = $recommendations
        "param([object[]]`$InputFeatures,[string]`$RecommendationRulesPath,[string]`$LogPath)`nreturn `$global:recommendationsData" | Set-Content -Path $localRecoPath -Encoding ASCII
        "param([pscustomobject]`$ApprovedAction,[string]`$LogPath) return [pscustomobject]@{ RemediationActionId = `$ApprovedAction.RemediationActionId; Status = 'Success'; Output = 'ok'; Errors = '' }" | Set-Content -Path $localStartRemediationPath -Encoding ASCII
        "param([pscustomobject]`$RemediationAction,[string]`$ValidationRulesPath,[string]`$LogPath) return @([pscustomobject]@{ ValidationStepId = 'VAL_RULE'; RemediationActionId = `$RemediationAction.RemediationActionId; Description = 'rule step'; ValidationType = 'ManualCheck'; ValidationTarget = 'Operator'; ExpectedResult = 'Confirmed'; ActualResult = $null; Status = 'NotRun'; Parameters = $null })" | Set-Content -Path $localGetValidationPath -Encoding ASCII
        "param([object[]]`$ValidationSteps,[pscustomobject]`$RemediationActionResult,[string]`$LogPath) return [pscustomobject]@{ OverallValidationStatus = 'Failed'; ValidationStepResults = $ValidationSteps }" | Set-Content -Path $localTestValidationPath -Encoding ASCII

        Mock Test-Path -MockWith {
            param($Path, $PathType)
            if ($Path -like '*ConvertTo-AIFeatures.ps1') { return $true }
            if ($Path -like '*Get-AIRecommendations.ps1') { return $true }
            if ($Path -like '*Start-RemediationAction.ps1') { return $true }
            if ($Path -like '*Get-ValidationStep.ps1') { return $true }
            if ($Path -like '*Test-RemediationResult.ps1') { return $true }
            return $false
        }

        $input = @([PSCustomObject]@{ Name = 'srv1'; Message = 'Service terminated unexpectedly' })
        $result = Start-AIRemediationWorkflow -InputData $input -RemediationMode 'Automatic' -LogPath (Join-Path $TestDrive 'workflow-validate.log') -ScriptRootOverride $script:TestScriptRootSafe -ConvertToAIFeaturesPath $localConvertPath -GetAIRecommendationsPath $localRecoPath -StartRemediationActionPath $localStartRemediationPath -GetValidationStepPath $localGetValidationPath -TestRemediationResultPath $localTestValidationPath -ValidationRulesPath (Join-Path $TestDrive 'rules.json')

        $result.OverallStatus | Should -Be 'CompletedWithValidationFailures'
        $result.RemediationResults.Count | Should -Be 1
        $result.ValidationReports.Count | Should -Be 1
        $result.ValidationReports[0].OverallValidationStatus | Should -Be 'Failed'
    }
}

Describe 'Find-IssuePatterns.ps1' {
    BeforeAll {
        if (-not $script:TestScriptRootSafe) {
            $script:TestScriptRootSafe = if ($PSCommandPath) { Split-Path $PSCommandPath -Parent } elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent } else { (Get-Location).Path }
        }
        $script:ScriptPath_FindIssuePatterns = [System.IO.Path]::GetFullPath((Join-Path $script:TestScriptRootSafe '..\..\..\src\Powershell\remediation\Find-IssuePatterns.ps1'))
        . $script:ScriptPath_FindIssuePatterns
    }

    It 'loads patterns from JSON and matches items' {
        $patternsPath = [System.IO.Path]::GetFullPath((Join-Path $script:TestScriptRootSafe '..\fixtures\issue_patterns_sample.json'))

        $input = @(
            [PSCustomObject]@{ Message = 'json-hit present'; Source = 'app' },
            [PSCustomObject]@{ CpuPercentage = 92; DurationSeconds = 180; Source = 'perf' },
            [PSCustomObject]@{ Message = 'prefix:disconnected agent'; Source = 'AzureConnectedMachineAgent' }
        )

        $result = Find-IssuePatterns -InputData $input -IssuePatternDefinitionsPath $patternsPath -LogPath (Join-Path $TestDrive 'find-issue-patterns-json.log')

        $result.Count | Should -Be 3
        ($result | Where-Object { $_.MatchedIssueId -eq 'JSONDetected' }).Count | Should -Be 1
        ($result | Where-Object { $_.MatchedIssueId -eq 'CPUSustainedHighJson' }).Count | Should -Be 1
        ($result | Where-Object { $_.MatchedIssueId -eq 'AgentPrefixDown' }).Count | Should -Be 1

        $cpuMatch = $result | Where-Object { $_.MatchedIssueId -eq 'CPUSustainedHighJson' } | Select-Object -First 1
        $cpuMatch.SuggestedRemediationId | Should -Be 'REM_JSON_CPUCapture'
    }

    It 'evaluates diagnostics sample and hits builtin patterns' {
        $diagnosticsPath = [System.IO.Path]::GetFullPath((Join-Path $script:TestScriptRootSafe '..\fixtures\diagnostics_pattern_sample.json'))
        $diagnosticItems = Get-Content -Path $diagnosticsPath -Raw | ConvertFrom-Json

        $findError = $null
        try {
            $result = Find-IssuePatterns -InputData $diagnosticItems -LogPath (Join-Path $TestDrive 'find-issue-patterns-diagnostics.log') -ErrorAction Stop
        } catch {
            $findError = $_
        }

        $findError | Should -BeNullOrEmpty

        $result.Count | Should -BeGreaterOrEqual 4
        ($result | Where-Object { $_.MatchedIssueId -eq 'ArcAgentDisconnected' }).Count | Should -Be 1
        ($result | Where-Object { $_.MatchedIssueId -eq 'ExtensionInstallFailure' }).Count | Should -Be 1
        ($result | Where-Object { $_.MatchedIssueId -eq 'CPUSustainedHigh' }).Count | Should -Be 1
        ($result | Where-Object { $_.MatchedIssueId -eq 'PolicyAssignmentNonCompliant' }).Count | Should -Be 1
    }
}

Describe 'Get-RemediationAction.ps1' {
    BeforeAll {
        if (-not $script:TestScriptRootSafe) {
            $script:TestScriptRootSafe = if ($PSCommandPath) { Split-Path $PSCommandPath -Parent } elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent } else { (Get-Location).Path }
        }
        $script:ScriptPath_GetRemediationAction = [System.IO.Path]::GetFullPath((Join-Path $script:TestScriptRootSafe '..\..\..\src\Powershell\remediation\Get-RemediationAction.ps1'))
        . $script:ScriptPath_GetRemediationAction
    }

    It 'loads remediation rules from JSON and resolves parameters' {
        $rulesPath = [System.IO.Path]::GetFullPath((Join-Path $script:TestScriptRootSafe '..\fixtures\remediation_rules_sample.json'))

        $matchedIssues = @(
            [PSCustomObject]@{
                MatchedIssueId = 'JSONDetected'
                MatchedIssueDescription = 'json match'
                MatchedItem = [PSCustomObject]@{ Message = 'json-hit present'; Source = 'app' }
                PatternSeverity = 'High'
                SuggestedRemediationId = 'REM_JSON_Action'
            },
            [PSCustomObject]@{
                MatchedIssueId = 'CPUSustainedHighJson'
                MatchedIssueDescription = 'cpu high'
                MatchedItem = [PSCustomObject]@{ CpuPercentage = 92; DurationSeconds = 180; Source = 'perf' }
                PatternSeverity = 'Medium'
                SuggestedRemediationId = 'REM_JSON_CPUCapture'
            }
        )

        $issueIdOnly = [PSCustomObject]@{
            IssueId = 'AgentPrefixDown'
            Message = 'prefix:disconnected agent'
            Source = 'AzureConnectedMachineAgent'
        }

        $input = @($matchedIssues[0], $matchedIssues[1], $issueIdOnly)

        $result = Get-RemediationAction -InputObject $input -RemediationRulesPath $rulesPath -MaxActionsPerInput 1 -LogPath (Join-Path $TestDrive 'get-remediation-action-json.log')

        $result.Count | Should -Be 3

        $jsonAction = $result | Where-Object { $_.InputContext.MatchedIssueId -eq 'JSONDetected' } | Select-Object -First 1
        $jsonAction.SuggestedActions.Count | Should -Be 1
        $jsonAction.SuggestedActions[0].RemediationActionId | Should -Be 'REM_JSON_Action'
        $jsonAction.SuggestedActions[0].ResolvedParameters.MessageSnippet | Should -Be 'json-hit present'

        $cpuAction = $result | Where-Object { $_.InputContext.MatchedIssueId -eq 'CPUSustainedHighJson' } | Select-Object -First 1
        $cpuAction.SuggestedActions[0].RemediationActionId | Should -Be 'REM_JSON_CPUCapture'
        $cpuAction.SuggestedActions[0].ResolvedParameters.SampleSeconds | Should -Be 180

        $agentAction = $result | Where-Object { $_.InputContext.IssueId -eq 'AgentPrefixDown' } | Select-Object -First 1
        $agentAction.SuggestedActions[0].RemediationActionId | Should -Be 'REM_JSON_RestartAgent'
        $agentAction.SuggestedActions[0].ResolvedParameters.ServiceSource | Should -Be 'AzureConnectedMachineAgent'
    }
}

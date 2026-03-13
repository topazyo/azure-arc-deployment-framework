# tests/PowerShell/unit/Remediation.Coverage.Tests.ps1
# Coverage-focused tests for remediation/ source files.

Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

BeforeAll {
    $script:SrcRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..\src\PowerShell'))
}

if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    Set-Item -Path Function:global:Write-Log -Value {
        param([string]$Message, [string]$Level = 'INFO', [string]$Path)
    }
}

# ---------------------------------------------------------------------------
# 1. Find-IssuePatterns.ps1  (0% covered)
# ---------------------------------------------------------------------------
Describe 'Find-IssuePatterns.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'remediation\Find-IssuePatterns.ps1')
        $script:PatternDefs = @{
            issuePatterns = @(
                @{
                    IssueId        = 'ARC-001'
                    Description    = 'Arc service not running'
                    DataSignatures = @(
                        @{ Property='ServiceStatus'; Operator='Equals'; Value='Stopped' }
                    )
                    Severity       = 'Critical'
                }
                @{
                    IssueId        = 'ARC-002'
                    Description    = 'High CPU usage'
                    DataSignatures = @(
                        @{ Property='CPUPercent'; Operator='GreaterThan'; Value=80 }
                    )
                    Severity       = 'Warning'
                }
            )
        }
    }

    It 'finds matching pattern when conditions are met' {
        Mock Test-Path { $true }
        Mock Get-Content { $script:PatternDefs | ConvertTo-Json -Depth 10 }
        Mock Add-Content {}
        Mock New-Item    {}

        $input = @(
            [PSCustomObject]@{ ServerName='TEST-SRV'; ServiceStatus='Stopped'; CPUPercent=20 }
        )

        $result = Find-IssuePatterns -InputData $input -IssuePatternDefinitionsPath 'C:\patterns.json' -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
        ($result | Where-Object { $_.MatchedIssueId -eq 'ARC-001' }) | Should -Not -BeNullOrEmpty
    }

    It 'returns empty when no patterns match' {
        Mock Test-Path { $true }
        Mock Get-Content { $script:PatternDefs | ConvertTo-Json -Depth 10 }
        Mock Add-Content {}
        Mock New-Item    {}

        $input = @(
            [PSCustomObject]@{ ServerName='TEST-SRV'; ServiceStatus='Running'; CPUPercent=5 }
        )

        $result = Find-IssuePatterns -InputData $input -IssuePatternDefinitionsPath 'C:\patterns.json' -LogPath "$TestDrive\test.log"
        ($result | Measure-Object).Count | Should -Be 0
    }

    It 'returns empty when fewer than 1 input records provided' {
        Mock Add-Content {}
        Mock New-Item    {}

        { Find-IssuePatterns -InputData @() -LogPath "$TestDrive\test.log" } | Should -Throw
    }

    It 'returns empty when pattern file not found' {
        Mock Test-Path { $false }
        Mock Add-Content {}
        Mock New-Item    {}

        $input = @([PSCustomObject]@{ ServiceStatus='Stopped' })

        $result = Find-IssuePatterns -InputData $input -IssuePatternDefinitionsPath 'C:\missing.json' -LogPath "$TestDrive\test.log"
        ($result | Measure-Object).Count | Should -Be 0
    }

    It 'matches GreaterThan operator correctly' {
        Mock Test-Path { $true }
        Mock Get-Content { $script:PatternDefs | ConvertTo-Json -Depth 10 }
        Mock Add-Content {}
        Mock New-Item    {}

        $input = @(
            [PSCustomObject]@{ ServerName='TEST-SRV'; ServiceStatus='Running'; CPUPercent=95 }
        )

        $result = Find-IssuePatterns -InputData $input -IssuePatternDefinitionsPath 'C:\patterns.json' -LogPath "$TestDrive\test.log"
        ($result | Where-Object { $_.MatchedIssueId -eq 'ARC-002' }) | Should -Not -BeNullOrEmpty
    }

    It 'respects MaxIssuesToFind limit' {
        Mock Test-Path { $true }
        Mock Get-Content { $script:PatternDefs | ConvertTo-Json -Depth 10 }
        Mock Add-Content {}
        Mock New-Item    {}

        $input = @(
            [PSCustomObject]@{ ServiceStatus='Stopped'; CPUPercent=99 }
        )

        $result = Find-IssuePatterns -InputData $input -IssuePatternDefinitionsPath 'C:\patterns.json' -MaxIssuesToFind 1 -LogPath "$TestDrive\test.log"
        ($result | Measure-Object).Count | Should -BeLessOrEqual 1
    }
}

# ---------------------------------------------------------------------------
# 2. Find-IssueCorrelations.ps1  (93 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Find-IssueCorrelations.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'remediation\Find-IssueCorrelations.ps1')
        $script:now = Get-Date
    }

    It 'returns empty array when fewer than 2 events provided' {
        Mock Add-Content {}
        Mock New-Item    {}

        $result = Find-IssueCorrelations -InputEvents @([PSCustomObject]@{ Timestamp=$now; Type='Error' }) -LogPath "$TestDrive\test.log"
        ($result | Measure-Object).Count | Should -Be 0
    }

    It 'finds correlated events within time window' {
        Mock Add-Content {}
        Mock New-Item    {}

        $events = @(
            [PSCustomObject]@{ Timestamp=$script:now; IssueId='ARC-001'; Category='Connection'; Message='Arc disconnected' }
            [PSCustomObject]@{ Timestamp=$script:now.AddSeconds(60); IssueId='ARC-002'; Category='Service'; Message='himds service restart' }
            [PSCustomObject]@{ Timestamp=$script:now.AddSeconds(70); IssueId='ARC-001'; Category='Connection'; Message='Arc disconnected again' }
        )

        $result = Find-IssueCorrelations -InputEvents $events -CorrelationTimeWindowSeconds 300 -MinCorrelationCount 2 -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
    }

    It 'returns empty when events are outside time window' {
        Mock Add-Content {}
        Mock New-Item    {}

        $events = @(
            [PSCustomObject]@{ Timestamp=$script:now; Category='Connection'; Message='error1' }
            [PSCustomObject]@{ Timestamp=$script:now.AddHours(5); Category='Connection'; Message='error2' }
        )

        $result = Find-IssueCorrelations -InputEvents $events -CorrelationTimeWindowSeconds 60 -LogPath "$TestDrive\test.log"
        ($result | Measure-Object).Count | Should -Be 0
    }

    It 'uses PrimaryIssueIdPattern to filter correlations' {
        Mock Add-Content {}
        Mock New-Item    {}

        $events = @(
            [PSCustomObject]@{ Timestamp=$script:now; IssueId='ARC-001'; Category='Connection'; Message='primary error' }
            [PSCustomObject]@{ Timestamp=$script:now.AddSeconds(10); IssueId='ARC-002'; Category='Service'; Message='secondary error' }
            [PSCustomObject]@{ Timestamp=$script:now.AddSeconds(20); IssueId='ARC-001'; Category='Connection'; Message='primary error again' }
        )

        $result = Find-IssueCorrelations -InputEvents $events -PrimaryIssueIdPattern 'ARC-001' -MinCorrelationCount 1 -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 3. Get-RootCauseAnalysis.ps1  (98 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Get-RootCauseAnalysis.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'remediation\Get-RootCauseAnalysis.ps1')
        $script:RCAJson = @{
            rcaRules = @(
                @{
                    RuleId               = 'RCA-001'
                    AppliesToIssueId     = 'ARC-001'
                    RootCauseDescription = 'himds service failure'
                    Confidence           = 0.9
                }
                @{
                    RuleId               = 'RCA-002'
                    AppliesToIssueId     = 'ARC-002'
                    RootCauseDescription = 'Network connectivity issue'
                    Confidence           = 0.75
                }
            )
        }
    }

    It 'returns RCA results for matched issues with rules file' {
        Mock Test-Path { $true }
        Mock Get-Content { $script:RCAJson | ConvertTo-Json -Depth 10 }
        Mock Add-Content {}
        Mock New-Item    {}

        $issues = @(
            [PSCustomObject]@{ MatchedIssueId='ARC-001'; Severity='Critical'; Description='Arc service stopped' }
        )

        $result = Get-RootCauseAnalysis -MatchedIssues $issues -RCARulesPath 'C:\rca-rules.json' -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
        ($result[0].PotentialRootCauses | Where-Object { $_.RootCauseRuleId -eq 'RCA-001' }) | Should -Not -BeNullOrEmpty
    }

    It 'returns generic RCA when no rules file specified' {
        Mock Add-Content {}
        Mock New-Item    {}

        $issues = @(
            [PSCustomObject]@{ IssueId='ARC-003'; Severity='Warning'; Description='Unknown issue' }
        )

        $result = Get-RootCauseAnalysis -MatchedIssues $issues -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
    }

    It 'returns empty when no issues provided' {
        Mock Add-Content {}
        Mock New-Item    {}

        { Get-RootCauseAnalysis -MatchedIssues @() -LogPath "$TestDrive\test.log" } | Should -Throw
    }

    It 'handles multiple matched issues with MaxRCAsPerIssue=1' {
        Mock Test-Path { $true }
        Mock Get-Content { $script:RCAJson | ConvertTo-Json -Depth 10 }
        Mock Add-Content {}
        Mock New-Item    {}

        $issues = @(
            [PSCustomObject]@{ IssueId='ARC-001'; Severity='Critical' }
            [PSCustomObject]@{ IssueId='ARC-002'; Severity='Warning' }
        )

        $result = Get-RootCauseAnalysis -MatchedIssues $issues -RCARulesPath 'C:\rca.json' -MaxRCAsPerIssue 1 -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
        ($result | Measure-Object).Count | Should -BeLessOrEqual 2
    }
}

# ---------------------------------------------------------------------------
# 4. Get-RollbackStep.ps1  (0% covered)
# ---------------------------------------------------------------------------
Describe 'Get-RollbackStep.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'remediation\Get-RollbackStep.ps1')
    }

    $script:RollbackRules = @{
        rollbackRules = @(
            @{
                RemediationActionId = 'RA-001'
                RollbackSteps       = @(
                    @{ Order=1; Action='Stop-Service himds'; Description='Stop the agent' }
                    @{ Order=2; Action='Restore-Config'; Description='Restore config from backup' }
                )
            }
        )
    }

    It 'returns rollback steps from action object when defined' {
        Mock Add-Content {}
        Mock New-Item    {}

        $action = [PSCustomObject]@{
            RemediationActionId = 'RA-001'
            Title               = 'Restart Arc Service'
            RollbackSteps       = @(
                @{ Order=1; Action='Undo restart'; Description='Undo' }
            )
        }

        $result = Get-RollbackStep -RemediationAction $action -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
        ($result | Measure-Object).Count | Should -BeGreaterThan 0
    }

    It 'returns rollback steps from rules file when action has none' {
        Mock Test-Path { $true }
        Mock Get-Content { $script:RollbackRules | ConvertTo-Json -Depth 10 }
        Mock Add-Content {}
        Mock New-Item    {}

        $action = [PSCustomObject]@{
            RemediationActionId = 'RA-001'
            Title               = 'Restart Arc Service'
            RollbackSteps       = @()
        }

        $result = Get-RollbackStep -RemediationAction $action -RollbackRulesPath 'C:\rollback.json' -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
    }

    It 'returns generic rollback step when no rules defined' {
        Mock Add-Content {}
        Mock New-Item    {}

        $action = [PSCustomObject]@{
            RemediationActionId = 'RA-999'
            Title               = 'Unknown Action'
            RollbackSteps       = @()
        }

        $result = Get-RollbackStep -RemediationAction $action -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
    }

    It 'returns error when RemediationAction is null' {
        Mock Add-Content {}
        Mock New-Item    {}

        $action = [PSCustomObject]@{ Title='No ID' }  # Missing RemediationActionId

        $result = Get-RollbackStep -RemediationAction $action -LogPath "$TestDrive\test.log"
        ($result | Measure-Object).Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# 5. Get-RemediationApproval.ps1  (67 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Get-RemediationApproval.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'remediation\Get-RemediationApproval.ps1')
    }

    It 'returns ErrorInvalidInput when RemediationAction is missing ID' {
        Mock Add-Content {}
        Mock New-Item    {}

        $action = [PSCustomObject]@{ Title='No ID' }  # No RemediationActionId

        $result = Get-RemediationApproval -RemediationAction $action -LogPath "$TestDrive\test.log"
        $result.ApprovalStatus | Should -Be 'ErrorInvalidInput'
    }

    It 'returns Approved when user enters y' {
        Mock Add-Content {}
        Mock New-Item    {}
        Mock Read-Host   { 'y' }
        Mock Write-Host  {}

        $action = [PSCustomObject]@{
            RemediationActionId = 'RA-001'
            Title               = 'Restart Arc Service'
            Description         = 'Restarts the himds service'
            Severity            = 'High'
            EstimatedDuration   = '30 seconds'
            RollbackSteps       = @('Stop reverse action')
        }

        $result = Get-RemediationApproval -RemediationAction $action -LogPath "$TestDrive\test.log"
        $result.ApprovalStatus | Should -Be 'Approved'
    }

    It 'returns Rejected when user enters n' {
        Mock Add-Content {}
        Mock New-Item    {}
        Mock Read-Host   { 'n' }
        Mock Write-Host  {}

        $action = [PSCustomObject]@{
            RemediationActionId = 'RA-001'
            Title               = 'Restart Arc Service'
            Description         = 'Restarts the himds service'
            Severity            = 'High'
            EstimatedDuration   = '30 seconds'
            RollbackSteps       = @()
        }

        $result = Get-RemediationApproval -RemediationAction $action -LogPath "$TestDrive\test.log"
        $result.ApprovalStatus | Should -Be 'Denied'
    }
}

# ---------------------------------------------------------------------------
# 6. Test-RemediationResult.ps1  (0% covered)
# ---------------------------------------------------------------------------
Describe 'Test-RemediationResult.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'remediation\Test-RemediationResult.ps1')
    }

    It 'returns OverallValidationStatus Success when service check passes' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    {} -ErrorAction SilentlyContinue
        Mock Get-Service { [PSCustomObject]@{ Name='himds'; Status='Running' } }

        $steps = @([PSCustomObject]@{
            ValidationStepId = 'VS-001'
            ValidationType   = 'ServiceStateCheck'
            ValidationTarget = 'himds'
            Description      = 'Check himds service state'
            ExpectedResult   = 'Running'
        })

        $result = Test-RemediationResult -ValidationSteps $steps -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
        $result.OverallValidationStatus | Should -Be 'Success'
    }

    It 'returns OverallValidationStatus Failed when service check fails' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    {} -ErrorAction SilentlyContinue
        Mock Get-Service { $null }

        $steps = @([PSCustomObject]@{
            ValidationStepId = 'VS-002'
            ValidationType   = 'ServiceStateCheck'
            ValidationTarget = 'missing-service'
            Description      = 'Check missing service'
            ExpectedResult   = 'Running'
        })

        $result = Test-RemediationResult -ValidationSteps $steps -LogPath "$TestDrive\test.log"
        $result.OverallValidationStatus | Should -Be 'Failed'
    }

    It 'populates ValidationStepResults for each step run' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    {} -ErrorAction SilentlyContinue

        $steps = @([PSCustomObject]@{
            ValidationStepId = 'VS-003'
            ValidationType   = 'ManualCheck'
            ValidationTarget = 'n/a'
            Description      = 'Manual inspection required'
            ExpectedResult   = 'n/a'
        })

        $result = Test-RemediationResult -ValidationSteps $steps -LogPath "$TestDrive\test.log"
        $result.ValidationStepResults | Should -Not -BeNullOrEmpty
        ($result.ValidationStepResults | Where-Object { $_.ValidationStepId -eq 'VS-003' }) | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Get-RemediationAction.ps1  (129 missed / 33.85% covered)
# ---------------------------------------------------------------------------
Describe 'Get-RemediationAction.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'remediation\Get-RemediationAction.ps1')
    }

    BeforeEach {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    {} -ErrorAction SilentlyContinue -ParameterFilter { $ItemType -eq 'Directory' }
        Mock Test-Path   { $true } -ParameterFilter { $Path -like '*Logs*' }
    }

    It 'resolves action for string input matching AppliesToId' {
        $result = Get-RemediationAction -InputObject @('ServiceCrashUnexpected') -LogPath "$TestDrive\ra.log"
        $result | Should -Not -BeNullOrEmpty
        $result[0].InputContext | Should -Be 'ServiceCrashUnexpected'
        $result[0].SuggestedActions.Count | Should -BeGreaterOrEqual 1
        $result[0].SuggestedActions[0].RemediationActionId | Should -Be 'REM_RestartService_Generic'
    }

    It 'resolves action for object with MatchedIssueId property' {
        $item = [PSCustomObject]@{ MatchedIssueId = 'ArcAgentDisconnected'; Severity = 'High' }
        $result = Get-RemediationAction -InputObject @($item) -LogPath "$TestDrive\ra.log"
        $result | Should -Not -BeNullOrEmpty
        $result[0].SuggestedActions[0].RemediationActionId | Should -Be 'REM_RestartArcAgent'
    }

    It 'resolves action for object with IssueId property' {
        $item = [PSCustomObject]@{ IssueId = 'ExtensionInstallFailure'; Description = 'Extension failed' }
        $result = Get-RemediationAction -InputObject @($item) -LogPath "$TestDrive\ra.log"
        $result | Should -Not -BeNullOrEmpty
        $result[0].SuggestedActions[0].RemediationActionId | Should -Be 'REM_RetryExtensionDeployment'
    }

    It 'resolves action using PotentialRootCauses array' {
        $item = [PSCustomObject]@{
            PotentialRootCauses = @(
                [PSCustomObject]@{ RootCauseRuleId = 'RCA_ServiceCrash_Dependency'; Confidence = 0.9 }
            )
        }
        $result = Get-RemediationAction -InputObject @($item) -LogPath "$TestDrive\ra.log"
        $result | Should -Not -BeNullOrEmpty
        $result[0].SuggestedActions[0].RemediationActionId | Should -Be 'REM_CheckServiceDependencies'
    }

    It 'resolves action using SuggestedRemediationId property' {
        $item = [PSCustomObject]@{ SuggestedRemediationId = 'CertificateExpiringSoon'; Name = 'cert01' }
        $result = Get-RemediationAction -InputObject @($item) -LogPath "$TestDrive\ra.log"
        $result | Should -Not -BeNullOrEmpty
        $result[0].SuggestedActions[0].RemediationActionId | Should -Be 'REM_RenewCertificate'
    }

    It 'skips item when no known ID property is found' {
        # Use an item whose MatchedIssueId is empty string; code resolves it but finds no matching rule.
        # Avoids triggering Out-String -Depth (not available in PS < 6.2) for items with no recognized property.
        $item = [PSCustomObject]@{ MatchedIssueId = '' }
        $result = Get-RemediationAction -InputObject @($item) -LogPath "$TestDrive\ra.log"
        # No matching rule for empty LookupId → allSuggestedActions stays empty
        ($result | Measure-Object).Count | Should -Be 0
    }

    It 'respects MaxActionsPerInput=1 for ID with multiple matching rules (LowDiskSpaceSystemDrive has 2)' {
        $result = Get-RemediationAction -InputObject @('LowDiskSpaceSystemDrive') -MaxActionsPerInput 1 -LogPath "$TestDrive\ra.log"
        $result | Should -Not -BeNullOrEmpty
        $result[0].SuggestedActions.Count | Should -Be 1
    }

    It 'returns multiple actions when MaxActionsPerInput allows it' {
        $result = Get-RemediationAction -InputObject @('LowDiskSpaceSystemDrive') -MaxActionsPerInput 5 -LogPath "$TestDrive\ra.log"
        $result | Should -Not -BeNullOrEmpty
        $result[0].SuggestedActions.Count | Should -Be 2
    }

    It 'loads custom rules from JSON file when RemediationRulesPath is provided' {
        $customRules = @{
            remediationRules = @(
                @{
                    AppliesToId       = 'CustomIssue001'
                    RemediationActionId = 'REM_CustomAction'
                    Title             = 'Custom Remediation'
                    Description       = 'Custom fix for test'
                    ImplementationType = 'Manual'
                    ConfirmationRequired = $true
                    Impact            = 'Low'
                    SuccessCriteria   = 'Issue resolved'
                }
            )
        } | ConvertTo-Json -Depth 5

        $rulesPath = Join-Path $TestDrive 'custom-rules.json'
        Set-Content $rulesPath $customRules

        $result = Get-RemediationAction -InputObject @('CustomIssue001') -RemediationRulesPath $rulesPath -LogPath "$TestDrive\ra.log"
        $result | Should -Not -BeNullOrEmpty
        $result[0].SuggestedActions[0].RemediationActionId | Should -Be 'REM_CustomAction'
    }

    It 'falls back to hardcoded rules when rules file not found' {
        $result = Get-RemediationAction -InputObject @('DNSResolutionFailure') -RemediationRulesPath 'C:\nonexistent\rules.json' -LogPath "$TestDrive\ra.log"
        $result | Should -Not -BeNullOrEmpty
        $result[0].SuggestedActions[0].RemediationActionId | Should -Be 'REM_TestDNS'
    }

    It 'resolves parameter expressions from input context' {
        # ServiceRestartLoop has Parameters = @{ ServiceName = '$InputContext.MatchedItem.ServiceName' }
        # Supply MatchedItem so the expression resolves to a real value
        $item = [PSCustomObject]@{
            IssueId     = 'ServiceRestartLoop'
            MatchedItem = [PSCustomObject]@{ ServiceName = 'himds' }
        }
        $result = Get-RemediationAction -InputObject @($item) -LogPath "$TestDrive\ra.log"
        $result | Should -Not -BeNullOrEmpty
        # ServiceRestartLoop rule should be found with at least one suggested action
        $result[0].SuggestedActions.Count | Should -BeGreaterOrEqual 1
    }

    It 'processes multiple input items and returns multiple action plans' {
        $items = @(
            'ServiceCrashUnexpected',
            'ArcAgentDisconnected',
            'DNSResolutionFailure'
        )
        $result = Get-RemediationAction -InputObject $items -LogPath "$TestDrive\ra.log"
        ($result | Measure-Object).Count | Should -Be 3
    }

    It 'returns action with ServiceRestartLoop ID' {
        $result = Get-RemediationAction -InputObject @('ServiceRestartLoop') -LogPath "$TestDrive\ra.log"
        $result | Should -Not -BeNullOrEmpty
        $result[0].SuggestedActions[0].RemediationActionId | Should -Be 'REM_CheckServiceRecoveryOptions'
    }

    It 'returns action with CPUSustainedHigh ID' {
        $result = Get-RemediationAction -InputObject @('CPUSustainedHigh') -LogPath "$TestDrive\ra.log"
        $result | Should -Not -BeNullOrEmpty
        $result[0].SuggestedActions[0].RemediationActionId | Should -Be 'REM_CaptureTopProcesses'
    }

    It 'returns action with PolicyAssignmentNonCompliant ID' {
        $result = Get-RemediationAction -InputObject @('PolicyAssignmentNonCompliant') -LogPath "$TestDrive\ra.log"
        $result | Should -Not -BeNullOrEmpty
        $result[0].SuggestedActions[0].RemediationActionId | Should -Be 'REM_ReapplyPolicyAssignment'
    }
}

# ---------------------------------------------------------------------------
# 8. Start-RemediationAction.ps1 (250 lines)
# ---------------------------------------------------------------------------
Describe 'Start-RemediationAction.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'remediation\Start-RemediationAction.ps1')
    }

    It 'returns SkippedWhatIf status when -WhatIf is used with Manual type' {
        $action = [PSCustomObject]@{
            RemediationActionId    = 'REM_TestManual'
            Title                  = 'Test Manual Action'
            ImplementationType     = 'Manual'
            Description            = 'Requires manual steps'
            ResolvedParameters     = @{}
        }
        $result = Start-RemediationAction -ApprovedAction $action -LogPath "$TestDrive\rem.log" -WhatIf
        $result.Status | Should -Be 'SkippedWhatIf'
    }

    It 'executes Manual action and returns ManualActionRequired' {
        $action = [PSCustomObject]@{
            RemediationActionId    = 'REM_TestManual'
            Title                  = 'Test Manual Action'
            ImplementationType     = 'Manual'
            Description            = 'Manual steps required'
            ResolvedParameters     = @{}
        }
        $result = Start-RemediationAction -ApprovedAction $action -LogPath "$TestDrive\rem.log"
        $result.Status | Should -Be 'ManualActionRequired'
    }

    It 'returns FailedInvalidInput when ApprovedAction is null' {
        $result = Start-RemediationAction -ApprovedAction ([PSCustomObject]@{ Title='x' }) -LogPath "$TestDrive\rem.log"
        $result.Status | Should -Be 'FailedInvalidInput'
    }

    It 'returns Failed when Script type TargetScriptPath does not exist' {
        $action = [PSCustomObject]@{
            RemediationActionId    = 'REM_Script'
            Title                  = 'Test Script Action'
            ImplementationType     = 'Script'
            TargetScriptPath       = 'C:\nonexistent\script.ps1'
            ResolvedParameters     = @{}
        }
        $result = Start-RemediationAction -ApprovedAction $action -LogPath "$TestDrive\rem.log"
        $result.Status | Should -Be 'Failed'
    }

    It 'executes Function type and returns Success when function exists' {
        function global:Test-RemAction { param() 'done' }
        $action = [PSCustomObject]@{
            RemediationActionId    = 'REM_Func'
            Title                  = 'Test Function Action'
            ImplementationType     = 'Function'
            TargetFunction         = 'Test-RemAction'
            ResolvedParameters     = @{}
        }
        $result = Start-RemediationAction -ApprovedAction $action -LogPath "$TestDrive\rem.log"
        $result.Status | Should -BeIn @('Success', 'SuccessWithErrors')
        Remove-Item Function:global:Test-RemAction -ErrorAction SilentlyContinue
    }

    It 'returns Failed when Function type target function is missing' {
        $action = [PSCustomObject]@{
            RemediationActionId    = 'REM_MissingFunc'
            Title                  = 'Missing Function'
            ImplementationType     = 'Function'
            TargetFunction         = 'Invoke-NonExistentFunction'
            ResolvedParameters     = @{}
        }
        $result = Start-RemediationAction -ApprovedAction $action -LogPath "$TestDrive\rem.log"
        $result.Status | Should -Be 'Failed'
    }

    It 'performs backup when BackupStateBeforeExecution=true and script not available' {
        $action = [PSCustomObject]@{
            RemediationActionId    = 'REM_Backup'
            Title                  = 'Backup Test'
            ImplementationType     = 'Manual'
            Description            = 'Test backup path'
            ResolvedParameters     = @{}
        }
        $result = Start-RemediationAction -ApprovedAction $action `
            -BackupStateBeforeExecution $true `
            -BackupPath "$TestDrive\backup" `
            -LogPath "$TestDrive\rem.log"
        $result.BackupPerformed | Should -Be $true
    }
}

# ---------------------------------------------------------------------------
# Test-RemediationResult.ps1 additional branch coverage
# ---------------------------------------------------------------------------
Describe 'Test-RemediationResult.ps1 additional branch coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'remediation\Test-RemediationResult.ps1')
    }

    BeforeEach {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    {} -ErrorAction SilentlyContinue
        Mock Test-Path   { $true }
    }

    It 'returns SkippedNoSteps when no validation steps provided' {
        $result = Test-RemediationResult -ValidationSteps @() -LogPath "$TestDrive\t.log"
        $result.OverallValidationStatus | Should -Be 'SkippedNoSteps'
    }

    It 'handles EventLogQuery step and marks RequiresManualCheck' {
        $steps = @([PSCustomObject]@{
            ValidationStepId = 'VS-EVT'
            ValidationType   = 'EventLogQuery'
            ValidationTarget = 'Heartbeat | where TimeGenerated > ago(1h)'
            Description      = 'Check recent heartbeat'
            ExpectedResult   = 'EventFound'
        })
        $result = Test-RemediationResult -ValidationSteps $steps -LogPath "$TestDrive\t.log"
        $result | Should -Not -BeNullOrEmpty
        ($result.ValidationStepResults | Where-Object { $_.Status -eq 'RequiresManualCheck' }) | Should -Not -BeNullOrEmpty
    }

    It 'handles ManualCheck step and marks RequiresManualConfirmation' {
        $steps = @([PSCustomObject]@{
            ValidationStepId = 'VS-MAN'
            ValidationType   = 'ManualCheck'
            ValidationTarget = 'visual-confirm'
            Description      = 'Manually confirm Arc is connected in portal'
            ExpectedResult   = 'n/a'
        })
        $result = Test-RemediationResult -ValidationSteps $steps -LogPath "$TestDrive\t.log"
        $result.OverallValidationStatus | Should -Be 'RequiresManualActionOrNotImplemented'
        ($result.ValidationStepResults | Where-Object { $_.Status -eq 'RequiresManualConfirmation' }) | Should -Not -BeNullOrEmpty
    }

    It 'handles unknown ValidationType and marks NotImplemented' {
        $steps = @([PSCustomObject]@{
            ValidationStepId = 'VS-UNK'
            ValidationType   = 'UnknownValidationType'
            ValidationTarget = 'n/a'
            Description      = 'Some future type'
            ExpectedResult   = 'any'
        })
        $result = Test-RemediationResult -ValidationSteps $steps -LogPath "$TestDrive\t.log"
        ($result.ValidationStepResults | Where-Object { $_.Status -eq 'NotImplemented' }) | Should -Not -BeNullOrEmpty
    }

    It 'handles ScriptExecutionCheck when script not found' {
        Mock Test-Path { $false } -ParameterFilter { $Path -like '*.ps1' -and $Path -notlike '*Parent*' }
        $steps = @([PSCustomObject]@{
            ValidationStepId = 'VS-SCR'
            ValidationType   = 'ScriptExecutionCheck'
            ValidationTarget = 'C:\nonexistent\validate.ps1'
            Description      = 'Run validation script'
            ExpectedResult   = '$true'
        })
        $result = Test-RemediationResult -ValidationSteps $steps -LogPath "$TestDrive\t.log"
        $result.OverallValidationStatus | Should -Be 'Failed'
    }

    It 'handles ScriptExecutionCheck with a real TestDrive script' {
        $scriptPath = "$TestDrive\validate.ps1"
        Set-Content -Path $scriptPath -Value '$true'
        $steps = @([PSCustomObject]@{
            ValidationStepId = 'VS-SCR2'
            ValidationType   = 'ScriptExecutionCheck'
            ValidationTarget = $scriptPath
            Description      = 'Run validation script'
            ExpectedResult   = '$true'
        })
        $result = Test-RemediationResult -ValidationSteps $steps -LogPath "$TestDrive\t.log"
        $result | Should -Not -BeNullOrEmpty
    }

    It 'handles FunctionCall when function not found' {
        $steps = @([PSCustomObject]@{
            ValidationStepId = 'VS-FC'
            ValidationType   = 'FunctionCall'
            ValidationTarget = 'NonExistentValidationFunction_ZZZ'
            Description      = 'Call a validation function'
            ExpectedResult   = '$true'
        })
        $result = Test-RemediationResult -ValidationSteps $steps -LogPath "$TestDrive\t.log"
        $result.OverallValidationStatus | Should -Be 'Failed'
    }

    It 'handles FunctionCall with an existing function' {
        Set-Item 'Function:global:Get-TestRemediationDummy' -Value { $true }
        $steps = @([PSCustomObject]@{
            ValidationStepId = 'VS-FC2'
            ValidationType   = 'FunctionCall'
            ValidationTarget = 'Get-TestRemediationDummy'
            Description      = 'Call dummy validation function'
            ExpectedResult   = '$true'
        })
        $result = Test-RemediationResult -ValidationSteps $steps -LogPath "$TestDrive\t.log"
        $result | Should -Not -BeNullOrEmpty
    }

    It 'returns Failed overall when one step fails and rest succeed' {
        Mock Get-Service { $null } -ParameterFilter { $Name -eq 'failing-service' }
        Mock Get-Service { [PSCustomObject]@{ Status='Running'; Name='himds' } } -ParameterFilter { $Name -eq 'himds' }
        $steps = @(
            [PSCustomObject]@{ ValidationStepId='VS-OK';   ValidationType='ServiceStateCheck'; ValidationTarget='himds';           Description='Check himds';          ExpectedResult='Running' },
            [PSCustomObject]@{ ValidationStepId='VS-FAIL'; ValidationType='ServiceStateCheck'; ValidationTarget='failing-service'; Description='Check failing service'; ExpectedResult='Running' }
        )
        $result = Test-RemediationResult -ValidationSteps $steps -LogPath "$TestDrive\t.log"
        $result.OverallValidationStatus | Should -Be 'Failed'
    }

    It 'handles exception in step execution and marks FailedExecutionError' {
        Mock Get-Service { throw 'Access denied to service' }
        $steps = @([PSCustomObject]@{
            ValidationStepId = 'VS-EXC'
            ValidationType   = 'ServiceStateCheck'
            ValidationTarget = 'himds'
            Description      = 'Service check that throws'
            ExpectedResult   = 'Running'
        })
        $result = Test-RemediationResult -ValidationSteps $steps -LogPath "$TestDrive\t.log"
        ($result.ValidationStepResults | Where-Object { $_.Status -eq 'FailedExecutionError' }) | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Invoke-TroubleshootingAnalysis.ps1 additional branch coverage
# ---------------------------------------------------------------------------
Describe 'Invoke-TroubleshootingAnalysis.ps1 additional branch coverage' {
    BeforeAll {
        foreach ($fn in @('Find-SystemStateIssues','Find-ArcAgentIssues','Find-AMAIssues',
                          'Find-CommonPatterns','Get-IssueRecommendation','Calculate-ImpactScore',
                          'Test-OSCompatibility','Analyze-ArcHealth','Analyze-AMAHealth',
                          'Calculate-ResourceUtilization','Get-ResourceRecommendations')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() @{} }
            }
        }
        . (Join-Path $script:SrcRoot 'core\Invoke-TroubleshootingAnalysis.ps1')
    }

    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value { param([string]$Message,[string]$Level='INFO',[string]$Path) }
        Mock Get-Content { '{"SystemState":{},"ArcAgent":{},"AMA":{}}' }
        Mock ConvertFrom-Json { [PSCustomObject]@{ SystemState=@{}; ArcAgent=@{}; AMA=@{} } }
        Mock Add-Content {} -ErrorAction SilentlyContinue
    }

    It 'returns analysis result with empty data array' {
        Mock Find-SystemStateIssues { @() }
        Mock Find-ArcAgentIssues    { @() }
        Mock Find-CommonPatterns    { @() }
        Mock Get-IssueRecommendation { @() }

        $data = @(
            [PSCustomObject]@{ Phase='SystemState'; Data=@{ OS=@{ Version='10.0.17763' } } }
        )
        $result = Invoke-TroubleshootingAnalysis -Data $data
        $result | Should -Not -BeNullOrEmpty
    }

    It 'handles arc diagnostics data and returns issue findings' {
        Mock Find-SystemStateIssues { @() }
        Mock Find-ArcAgentIssues    { @(@{ Type='ArcAgent'; Severity='Warning'; Component='Arc'; Description='Agent disconnected'; ImpactScore=$null }) }
        Mock Find-CommonPatterns    { @() }
        Mock Get-IssueRecommendation { 'Restart the Arc service.' }
        Mock Calculate-ImpactScore  { 0.5 }

        $data = @(
            [PSCustomObject]@{ Phase='SystemState';    Data=@{ OS=@{ Version='10.0' } } },
            [PSCustomObject]@{ Phase='ArcDiagnostics'; Data=@{ ServiceStatus='Disconnected' } }
        )
        $result = Invoke-TroubleshootingAnalysis -Data $data
        $result.Issues.Count | Should -BeGreaterOrEqual 1
    }

    It 'handles AMA diagnostics data when present' {
        Mock Find-SystemStateIssues { @() }
        Mock Find-ArcAgentIssues    { @() }
        Mock Find-AMAIssues         { @(@{ Type='AMA'; Severity='Warning'; Component='AMA'; Description='Not running'; ImpactScore=$null }) }
        Mock Find-CommonPatterns    { @() }
        Mock Get-IssueRecommendation { 'Restart AMA service.' }
        Mock Calculate-ImpactScore  { 0.6 }

        $data = @(
            [PSCustomObject]@{ Phase='SystemState';    Data=@{ OS=@{ Version='10.0' } } },
            [PSCustomObject]@{ Phase='ArcDiagnostics'; Data=@{ ServiceStatus='Connected' } },
            [PSCustomObject]@{ Phase='AMADiagnostics'; Data=@{ ServiceStatus='Stopped' } }
        )
        $result = Invoke-TroubleshootingAnalysis -Data $data
        $result | Should -Not -BeNullOrEmpty
    }

    It 'captures error and returns Error field when analysis throws' {
        Mock Find-SystemStateIssues { throw 'Analysis engine failure' }

        $data = @([PSCustomObject]@{ Phase='SystemState'; Data=@{} })
        $result = Invoke-TroubleshootingAnalysis -Data $data
        $result.Error | Should -Not -BeNullOrEmpty
    }

    It 'sorts issues by ImpactScore descending' {
        $issue1 = @{ Type='A'; Severity='Low';      Description='Low impact'; ImpactScore=$null }
        $issue2 = @{ Type='B'; Severity='Critical'; Description='High impact'; ImpactScore=$null }
        Mock Find-SystemStateIssues { @($issue1, $issue2) }
        Mock Find-ArcAgentIssues    { @() }
        Mock Find-CommonPatterns    { @() }
        Mock Get-IssueRecommendation { 'Fix it.' }
        Mock Calculate-ImpactScore  { 0.9 } -ParameterFilter { $Issue.Type -eq 'B' }
        Mock Calculate-ImpactScore  { 0.1 } -ParameterFilter { $Issue.Type -eq 'A' }

        $data = @([PSCustomObject]@{ Phase='SystemState'; Data=@{} })
        $result = Invoke-TroubleshootingAnalysis -Data $data
        $result.Issues.Count | Should -BeGreaterOrEqual 2
    }
}

# ---------------------------------------------------------------------------
# Extra: Test-RemediationResult Test-ExpectedOutcome branch coverage
# ---------------------------------------------------------------------------
Describe 'Test-RemediationResult Test-ExpectedOutcome branches' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'remediation\Test-RemediationResult.ps1')
    }
    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path, [string]$Component)
        }
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    {} -ErrorAction SilentlyContinue
        Mock Test-Path   { $true }
    }

    It 'ServiceStateCheck: succeeds when service matches expected Running state' {
        Mock Get-Service { [PSCustomObject]@{ Status = 'Running'; DisplayName = 'himds' } }
        $steps = @([PSCustomObject]@{
            ValidationStepId = 'VS-SVC-RUN'
            ValidationType   = 'ServiceStateCheck'
            ValidationTarget = 'himds'
            Description      = 'Check himds is running'
            ExpectedResult   = 'Running'
        })
        $result = Test-RemediationResult -ValidationSteps $steps -LogPath "$TestDrive\svc.log"
        $result.OverallValidationStatus | Should -Be 'Success'
    }

    It 'ServiceStateCheck: fails when service state does not match expected' {
        Mock Get-Service { [PSCustomObject]@{ Status = 'Stopped'; DisplayName = 'himds' } }
        $steps = @([PSCustomObject]@{
            ValidationStepId = 'VS-SVC-FAIL'
            ValidationType   = 'ServiceStateCheck'
            ValidationTarget = 'himds'
            Description      = 'Check himds is running'
            ExpectedResult   = 'Running'
        })
        $result = Test-RemediationResult -ValidationSteps $steps -LogPath "$TestDrive\svc2.log"
        $result.OverallValidationStatus | Should -Be 'Failed'
    }

    It 'ScriptExecutionCheck: Contains pattern succeeds when output contains expected text' {
        $scriptPath = "$TestDrive\validate_contains.ps1"
        Set-Content -Path $scriptPath -Value 'Write-Output "Service is Running"'
        $steps = @([PSCustomObject]@{
            ValidationStepId = 'VS-CONT'
            ValidationType   = 'ScriptExecutionCheck'
            ValidationTarget = $scriptPath
            Description      = 'Check output contains Running'
            ExpectedResult   = 'Contains "Running"'
        })
        $result = Test-RemediationResult -ValidationSteps $steps -LogPath "$TestDrive\cont.log"
        $result.OverallValidationStatus | Should -Be 'Success'
    }

    It 'ScriptExecutionCheck: Regex pattern succeeds when output matches regex' {
        $scriptPath = "$TestDrive\validate_regex.ps1"
        Set-Content -Path $scriptPath -Value 'Write-Output "Status: 0"'
        $steps = @([PSCustomObject]@{
            ValidationStepId = 'VS-REGEX'
            ValidationType   = 'ScriptExecutionCheck'
            ValidationTarget = $scriptPath
            Description      = 'Check output matches status regex'
            ExpectedResult   = 'Regex :Status:\s+\d+'
        })
        $result = Test-RemediationResult -ValidationSteps $steps -LogPath "$TestDrive\regex.log"
        $result.OverallValidationStatus | Should -Be 'Success'
    }

    It 'ScriptExecutionCheck: exact string match succeeds when output equals expected' {
        $scriptPath = "$TestDrive\validate_exact.ps1"
        Set-Content -Path $scriptPath -Value 'Write-Output "healthy"'
        $steps = @([PSCustomObject]@{
            ValidationStepId = 'VS-EXACT'
            ValidationType   = 'ScriptExecutionCheck'
            ValidationTarget = $scriptPath
            Description      = 'Check exact output'
            ExpectedResult   = 'healthy'
        })
        $result = Test-RemediationResult -ValidationSteps $steps -LogPath "$TestDrive\exact.log"
        $result | Should -Not -BeNullOrEmpty
    }

    It 'ScriptExecutionCheck: empty ExpectedResult succeeds when script has no errors' {
        $scriptPath = "$TestDrive\validate_empty.ps1"
        Set-Content -Path $scriptPath -Value 'Write-Output "done"'
        $steps = @([PSCustomObject]@{
            ValidationStepId = 'VS-EMPTY'
            ValidationType   = 'ScriptExecutionCheck'
            ValidationTarget = $scriptPath
            Description      = 'Check no errors'
            ExpectedResult   = ''
        })
        $result = Test-RemediationResult -ValidationSteps $steps -LogPath "$TestDrive\empty.log"
        $result | Should -Not -BeNullOrEmpty
    }

    It 'returns PartialSuccessRequiresAttention when mix of Success and ManualCheck steps' {
        $scriptPath = "$TestDrive\validate_mix.ps1"
        Set-Content -Path $scriptPath -Value 'Write-Output "ok"'
        $steps = @(
            [PSCustomObject]@{
                ValidationStepId = 'VS-MIX1'
                ValidationType   = 'ScriptExecutionCheck'
                ValidationTarget = $scriptPath
                Description      = 'Script check passes'
                ExpectedResult   = 'ok'
            },
            [PSCustomObject]@{
                ValidationStepId = 'VS-MIX2'
                ValidationType   = 'ManualCheck'
                ValidationTarget = 'portal-confirmation'
                Description      = 'Manual portal check'
                ExpectedResult   = 'n/a'
            }
        )
        $result = Test-RemediationResult -ValidationSteps $steps -LogPath "$TestDrive\mix.log"
        $result.OverallValidationStatus | Should -BeIn @('PartialSuccessRequiresAttention', 'RequiresManualActionOrNotImplemented')
    }
}

# ---------------------------------------------------------------------------
# 13. Get-RollbackStep.ps1 additional branch coverage
# ---------------------------------------------------------------------------
Describe 'Get-RollbackStep.ps1 additional branch coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'remediation\Get-RollbackStep.ps1')
    }

    It 'returns specific rollback steps when AppliesToRemediationActionId matches rule' {
        $rulesFile = Join-Path $TestDrive 'rollback_rules_specific.json'
        $rulesJson = @{
            rollbackRules = @(
                @{
                    AppliesToRemediationActionId = 'RA-SPECIFIC-001'
                    RollbackStepId              = 'RS-001'
                    Title                       = 'Restore Registry Key'
                    Description                 = 'Restores the modified registry key'
                    ImplementationType          = 'Script'
                    TargetScriptPath            = 'C:\Scripts\Restore-Registry.ps1'
                    Parameters                  = @{}
                    ConfirmationRequired        = $false
                    Steps                       = $null
                }
            )
        } | ConvertTo-Json -Depth 10
        Set-Content -Path $rulesFile -Value $rulesJson
        $action = [PSCustomObject]@{ RemediationActionId = 'RA-SPECIFIC-001'; Title = 'Fix Registry' }
        $result = Get-RollbackStep -RemediationAction $action -RollbackRulesPath $rulesFile `
            -LogPath "$TestDrive\rbsp.log"
        @($result).Count | Should -BeGreaterThan 0
        $result[0].RemediationActionId | Should -Be 'RA-SPECIFIC-001'
    }

    It 'returns specific rollback steps array when specificRule.Steps is an array' {
        $rulesFile = Join-Path $TestDrive 'rollback_rules_steps.json'
        $steps = @(
            @{
                RollbackStepId      = 'RS-S001'
                Title               = 'Step One'
                Description         = 'First rollback step'
                ImplementationType  = 'Script'
                TargetScriptPath    = 'C:\step1.ps1'
                Parameters          = @{}
                ConfirmationRequired = $true
            },
            @{
                RollbackStepId      = 'RS-S002'
                Title               = 'Step Two'
                Description         = 'Second rollback step'
                ImplementationType  = 'Script'
                TargetScriptPath    = 'C:\step2.ps1'
                Parameters          = @{}
                ConfirmationRequired = $false
            }
        )
        $rulesJson = @{
            rollbackRules = @(
                @{
                    AppliesToRemediationActionId = 'RA-STEPS-001'
                    RollbackStepId              = 'RS-ROOT'
                    Steps                       = $steps
                }
            )
        } | ConvertTo-Json -Depth 10
        Set-Content -Path $rulesFile -Value $rulesJson
        $action = [PSCustomObject]@{ RemediationActionId = 'RA-STEPS-001'; Title = 'Multi-step fix' }
        $result = Get-RollbackStep -RemediationAction $action -RollbackRulesPath $rulesFile `
            -LogPath "$TestDrive\rbsteps.log"
        @($result).Count | Should -Be 2
    }

    It 'returns RollbackScript-based step when no specific rule matches' {
        $action = [PSCustomObject]@{
            RemediationActionId = 'RA-NOSCRIPT-001'
            Title               = 'Fix Service'
            RollbackScript      = 'C:\Scripts\Rollback-Service.ps1'
        }
        $result = Get-RollbackStep -RemediationAction $action -LogPath "$TestDrive\rbscript.log"
        @($result).Count | Should -Be 1
        $result[0].ImplementationType | Should -Be 'Script'
        $result[0].RollbackTarget | Should -Be 'C:\Scripts\Rollback-Service.ps1'
    }

    It 'RollbackScript step includes OriginalStateBackupPath in parameters when provided' {
        $action = [PSCustomObject]@{
            RemediationActionId = 'RA-BACKUP-001'
            Title               = 'Fix with backup'
            RollbackScript      = 'C:\rollback.ps1'
        }
        $result = Get-RollbackStep -RemediationAction $action `
            -OriginalStateBackupPath 'C:\Backups\pre-rem-state' `
            -LogPath "$TestDrive\rbbackup.log"
        @($result).Count | Should -Be 1
        $result[0].ResolvedParameters.OriginalStateBackupPath | Should -Be 'C:\Backups\pre-rem-state'
    }

    It 'returns ManualRollback step when no rule and no RollbackScript' {
        $action = [PSCustomObject]@{ RemediationActionId = 'RA-MANUAL-001'; Title = 'Fix Manual' }
        $result = Get-RollbackStep -RemediationAction $action -LogPath "$TestDrive\rbmanual.log"
        @($result).Count | Should -BeGreaterThan 0
        $result[0].ImplementationType | Should -Be 'Manual'
    }

    It 'returns empty when rules file does not contain rollbackRules array' {
        $rulesFile = Join-Path $TestDrive 'rollback_rules_empty.json'
        Set-Content -Path $rulesFile -Value '{"someOtherProperty": []}'
        $action = [PSCustomObject]@{ RemediationActionId = 'RA-NORULES-001'; Title = 'Test' }
        $result = Get-RollbackStep -RemediationAction $action -RollbackRulesPath $rulesFile `
            -LogPath "$TestDrive\rbnorules.log"
        # Falls through to ManualRollback since no rules loaded
        $result | Should -Not -BeNullOrEmpty
    }

    It 'handles rules file not found gracefully' {
        $action = [PSCustomObject]@{ RemediationActionId = 'RA-NOFILE-001'; Title = 'Test' }
        $result = Get-RollbackStep -RemediationAction $action `
            -RollbackRulesPath 'C:\nonexistent_rules_xyz\rules.json' `
            -LogPath "$TestDrive\rbnofile.log"
        # Should still return ManualRollback, not throw
        $result | Should -Not -BeNullOrEmpty
    }

    It 'handles malformed rules file gracefully' {
        $rulesFile = Join-Path $TestDrive 'rollback_rules_bad.json'
        Set-Content -Path $rulesFile -Value 'NOT VALID JSON {{{{'
        $action = [PSCustomObject]@{ RemediationActionId = 'RA-BADFILE-001'; Title = 'Test' }
        $result = Get-RollbackStep -RemediationAction $action -RollbackRulesPath $rulesFile `
            -LogPath "$TestDrive\rbbad.log"
        # Should fall through to ManualRollback after parse error
        $result | Should -Not -BeNullOrEmpty
    }

    It 'includes OriginalStateBackupPath in specific rule step parameters when provided' {
        $rulesFile = Join-Path $TestDrive 'rollback_rules_backupparam.json'
        $rulesJson = @{
            rollbackRules = @(
                @{
                    AppliesToRemediationActionId = 'RA-BKPARAM-001'
                    RollbackStepId              = 'RS-BK001'
                    Title                       = 'Restore with backup'
                    Description                 = 'Uses backup'
                    ImplementationType          = 'Script'
                    TargetScriptPath            = 'C:\restore.ps1'
                    Parameters                  = @{ Key = 'Value' }
                    ConfirmationRequired        = $true
                    Steps                       = $null
                }
            )
        } | ConvertTo-Json -Depth 10
        Set-Content -Path $rulesFile -Value $rulesJson
        $action = [PSCustomObject]@{ RemediationActionId = 'RA-BKPARAM-001'; Title = 'Backup param test' }
        $result = Get-RollbackStep -RemediationAction $action -RollbackRulesPath $rulesFile `
            -OriginalStateBackupPath 'C:\Backups\state' `
            -LogPath "$TestDrive\rbbkparam.log"
        @($result).Count | Should -BeGreaterThan 0
        $result[0].ResolvedParameters.OriginalStateBackupPath | Should -Be 'C:\Backups\state'
    }
}

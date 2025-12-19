# tests/Powershell/unit/AI.Tests.ps1
using namespace System.Management.Automation

Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

$script:TestScriptRootSafe = if ($PSCommandPath) { Split-Path $PSCommandPath -Parent } elseif ($PSScriptRoot) { $PSScriptRoot } elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent } else { (Get-Location).Path }

Describe 'Find-DiagnosticPattern.ps1 Tests' {
    BeforeAll {
        if (-not $script:TestScriptRootSafe) {
            $script:TestScriptRootSafe = if ($PSCommandPath) { Split-Path $PSCommandPath -Parent } elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent } else { (Get-Location).Path }
        }
        $script:ScriptPath_FindPattern = [System.IO.Path]::GetFullPath((Join-Path $script:TestScriptRootSafe '..\..\..\src\Powershell\AI\Find-DiagnosticPattern.ps1'))
        $script:SampleInputData_FindPattern = @(
            [PSCustomObject]@{ EventId = 7034; Source = 'Service Control Manager'; Message = 'Service MySvc terminated unexpectedly. Failure 1.' }
            [PSCustomObject]@{ EventId = 1001; Source = 'SomeApp'; Message = 'Application error occurred in module X.' }
            [PSCustomObject]@{ EventId = 2001; Source = 'NetSvc'; Message = 'Network connection failed to connect due to DNS resolution failure.' }
            [PSCustomObject]@{ EventId = 404;  Source = 'WebApp'; Message = 'The requested page was not found (error).' }
            [PSCustomObject]@{ EventId = 7034; Source = 'OtherSvc'; Message = 'OtherSvc also terminated unexpectedly.' }
            [PSCustomObject]@{ EventId = 7034; Source = 'Service Control Manager'; Message = 'Service MySvc terminated unexpectedly again.' }
            [PSCustomObject]@{ EventId = 123;  Source = 'DebugSource'; Message = 'This is a DEBUG message with keyword success.' }
        )
        $script:MockPatternFileContent_FindPattern = @{
            patterns = @(
                @{ PatternName = 'CustomSvcUnexpectedTermination'; Description = 'Custom service MySvc terminated unexpectedly from JSON.'; Type = 'KeywordMatch'; Conditions = @(@{ EventProperty = 'Message'; Keywords = @('MySvc', 'terminated unexpectedly'); MinOccurrences = 1 })},
                @{ PatternName = 'GenericApplicationErrorFromJson'; Description = 'A generic application error from JSON.'; Type = 'KeywordMatch'; Conditions = @(@{ EventProperty = 'Message'; Keywords = @('application error'); MinOccurrences = 1 })},
                @{ PatternName = 'UnsupportedPatternType'; Description = 'This pattern type is not supported.'; Type = 'EventSequence'; Conditions = @(@{})}
            )
        }
        $script:MockJsonString_FindPattern = $script:MockPatternFileContent_FindPattern | ConvertTo-Json -Depth 5
        . $script:ScriptPath_FindPattern
    }

    BeforeEach {
        if (-not $script:FindPattern_MockedWriteLogMessages) {
            $script:FindPattern_MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new()
        }
        $script:FindPattern_MockedWriteLogMessages.Clear()

        Mock Write-Log -MockWith {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path)
            $script:FindPattern_MockedWriteLogMessages.Add("[$Level] $Message")
        }
        Mock Test-Path -MockWith { param($Path, $PathType) return $false }
        Mock Get-Content -MockWith { param($Path, [switch]$Raw, $ErrorAction) throw "Get-Content: Unexpected path $Path" }
    }

    It 'Should use hardcoded patterns if PatternDefinitionPath is not provided' {
        $results = Find-DiagnosticPattern -InputData $script:SampleInputData_FindPattern
        if ($null -eq $results) { Write-Host 'DEBUG Find: results is null' } else { Write-Host "DEBUG Find: type=$($results.GetType().FullName) count=$($results.Count)" }
        Write-Host ('DEBUG Find logs: ' + ($script:FindPattern_MockedWriteLogMessages -join ' | '))
        $serviceTerminatedPattern = $results | Where-Object { $_.PatternName -eq 'ServiceTerminatedUnexpectedly' }
        $serviceTerminatedPattern | Should -Not -BeNullOrEmpty
        $serviceTerminatedPattern.MatchedItemCount | Should -Be 3
        ($script:FindPattern_MockedWriteLogMessages -join "`n") | Should -Match '\[INFO\] Using hardcoded pattern definitions.'
    }

    It 'Should use hardcoded patterns if PatternDefinitionPath is invalid (Test-Path returns $false)' {
        $jsonPath = 'C:\invalid\patterns.json'
        Mock Test-Path -MockWith { param($Path, $PathType) return $false }
        $results = Find-DiagnosticPattern -InputData $script:SampleInputData_FindPattern -PatternDefinitionPath $jsonPath
        if ($null -eq $results) { Write-Host 'DEBUG Find invalid path: results is null' } else { Write-Host "DEBUG Find invalid path: count=$($results.Count)" }
        Write-Host ('DEBUG Find invalid logs: ' + ($script:FindPattern_MockedWriteLogMessages -join ' | '))
        ($results | Where-Object { $_.PatternName -eq 'ServiceTerminatedUnexpectedly' }).MatchedItemCount | Should -Be 3
        $script:FindPattern_MockedWriteLogMessages | Should -Contain "[WARNING] Pattern definition file not found at: $jsonPath"
        $script:FindPattern_MockedWriteLogMessages | Should -Contain '[INFO] Using hardcoded pattern definitions.'
    }

    It 'Should load and use patterns from JSON file if PatternDefinitionPath is valid' {
        $jsonPath = 'C:\valid\patterns.json'
        Mock Test-Path -MockWith { param($Path, $PathType) return ($Path -eq $jsonPath -and $PathType -eq 'Leaf') }
        Mock Get-Content -MockWith { param($Path, [switch]$Raw, $ErrorAction) if ($Path -eq $jsonPath -and $Raw) { return $script:MockJsonString_FindPattern } throw "Get-Content: Unexpected path $Path" }

        $results = Find-DiagnosticPattern -InputData $script:SampleInputData_FindPattern -PatternDefinitionPath $jsonPath
        if ($null -eq $results) { Write-Host 'DEBUG Find JSON: results is null' } else { Write-Host "DEBUG Find JSON: count=$($results.Count) names=$($results.PatternName -join ',')" }
        Write-Host ('DEBUG Find JSON logs: ' + ($script:FindPattern_MockedWriteLogMessages -join ' | '))

        ($results | Where-Object { $_.PatternName -eq 'CustomSvcUnexpectedTermination' }).MatchedItemCount | Should -Be 2
        ($results | Where-Object { $_.PatternName -eq 'GenericApplicationErrorFromJson' }).MatchedItemCount | Should -Be 1
        ($results | Where-Object { $_.PatternName -eq 'UnsupportedPatternType' }) | Should -BeNullOrEmpty
        $script:FindPattern_MockedWriteLogMessages | Should -Contain '[INFO] Successfully loaded 3 patterns from JSON file.'
    }

    It 'Should handle malformed JSON file by falling back to hardcoded patterns' {
        $jsonPath = 'C:\malformed\patterns.json'
        Mock Test-Path -MockWith { param($Path, $PathType) return ($Path -eq $jsonPath -and $PathType -eq 'Leaf') }
        Mock Get-Content -MockWith { param($Path, [switch]$Raw, $ErrorAction) if ($Path -eq $jsonPath -and $Raw) { return 'this is not valid json' } throw "Get-Content: Unexpected path $Path" }

        $results = Find-DiagnosticPattern -InputData $script:SampleInputData_FindPattern -PatternDefinitionPath $jsonPath
        if ($null -eq $results) { Write-Host 'DEBUG Find malformed: results is null' } else { Write-Host "DEBUG Find malformed: count=$($results.Count)" }
        Write-Host ('DEBUG Find malformed logs: ' + ($script:FindPattern_MockedWriteLogMessages -join ' | '))
        ($script:FindPattern_MockedWriteLogMessages -join "`n") | Should -Match '\[ERROR\] Failed to load or parse pattern definition file ''C:\\malformed\\patterns\.json''' 
        $script:FindPattern_MockedWriteLogMessages | Should -Contain '[INFO] Using hardcoded pattern definitions.'
        ($results | Where-Object { $_.PatternName -eq 'ServiceTerminatedUnexpectedly' }).MatchedItemCount | Should -Be 3
    }

    Context 'KeywordMatch Logic' {
        BeforeEach {
            Mock Test-Path -MockWith { param($Path, $PathType) return $true }
            Mock Get-Content -MockWith {
                param($Path, [switch]$Raw, $ErrorAction)
                return '{"patterns":[{"PatternName":"TestKeywordPattern","Description":"Test for keywords","Type":"KeywordMatch","Conditions":[{"EventProperty":"Message","Keywords":["keywordA","KEYWORDB"],"MinOccurrences":2}]}]}'
            }
        }

        It 'Should match if all keywords are present in Message (case-insensitive) and MinOccurrences met' {
            $data = @(
                [PSCustomObject]@{ Message = 'Contains keywordA and KEYWORDB.' },
                [PSCustomObject]@{ Message = 'keyworda is here, and also keywordb.' },
                [PSCustomObject]@{ Message = 'Only keywordA.' },
                [PSCustomObject]@{ Message = 'No relevant keywords.' }
            )
            $results = Find-DiagnosticPattern -InputData $data -PatternDefinitionPath 'mock.json'
            if ($null -eq $results) { Write-Host 'DEBUG Find keyword match: results is null' } else { Write-Host "DEBUG Find keyword match: count=$($results.Count)" }
            Write-Host ('DEBUG Find keyword logs: ' + ($script:FindPattern_MockedWriteLogMessages -join ' | '))
            $results.Count | Should -Be 1
            $results[0].MatchedItemCount | Should -Be 2
            $results[0].ExampleMatchedItems.Message | Should -Contain 'Contains keywordA and KEYWORDB.'
            $results[0].ExampleMatchedItems.Message | Should -Contain 'keyworda is here, and also keywordb.'
        }

        It 'Should NOT match if not all keywords are present in Message' {
            $data = @([PSCustomObject]@{ Message = 'Only keywordA is present.' })
            $results = Find-DiagnosticPattern -InputData $data -PatternDefinitionPath 'mock.json'
            $results.Count | Should -Be 0
        }

        It 'Should NOT match if MinOccurrences is not met' {
            $data = @([PSCustomObject]@{ Message = 'Contains keywordA and KEYWORDB.' })
            $results = Find-DiagnosticPattern -InputData $data -PatternDefinitionPath 'mock.json'
            $results.Count | Should -Be 0
        }

        It 'Should skip items with missing, null or non-string Message property for Message-based conditions' {
            $dataWithBadItems = @(
                [PSCustomObject]@{ Message = 'keywordA and KEYWORDB here.' },
                [PSCustomObject]@{ Message = $null },
                [PSCustomObject]@{ Message = 12345 },
                [PSCustomObject]@{ DifferentProperty = 'keywordA KEYWORDB' },
                [PSCustomObject]@{ Message = 'Another one with keywordA and KEYWORDB.' }
            )
            $results = Find-DiagnosticPattern -InputData $dataWithBadItems -PatternDefinitionPath 'mock.json'
            $results.Count | Should -Be 1
            $results[0].MatchedItemCount | Should -Be 2
        }
    }

    It 'Should limit returned patterns with -MaxPatternsToReturn' {
        Mock Test-Path -MockWith { param($Path, $PathType) return $true }
        Mock Get-Content -MockWith { param($Path, [switch]$Raw, $ErrorAction) return $script:MockJsonString_FindPattern }

        $results = Find-DiagnosticPattern -InputData $script:SampleInputData_FindPattern -PatternDefinitionPath 'mock.json' -MaxPatternsToReturn 1
        if ($null -eq $results) { Write-Host 'DEBUG Find max: results is null' } else { Write-Host "DEBUG Find max: count=$($results.Count)" }
        Write-Host ('DEBUG Find max logs: ' + ($script:FindPattern_MockedWriteLogMessages -join ' | '))
        $results.Count | Should -Be 1
        $script:FindPattern_MockedWriteLogMessages | Should -Contain '[INFO] Reached MaxPatternsToReturn (1). Stopping pattern search.'
    }

    It 'Should include example matched items in output (up to 5)' {
        $manyMatchesData = @()
        1..10 | ForEach-Object { $manyMatchesData += [PSCustomObject]@{ Message = "MySvc item $_ terminated unexpectedly" } }
        
        $patternDataContent = @{ patterns = @(@{ PatternName='ExampleTest'; Description='Desc'; Type='KeywordMatch'; Conditions=@(@{EventProperty='Message'; Keywords=@('MySvc', 'terminated unexpectedly'); MinOccurrences=1})})}
        $patternDataJson = $patternDataContent | ConvertTo-Json -Depth 5
        Mock Test-Path -MockWith { param($Path, $PathType) return $true }
        Mock Get-Content -MockWith { param($Path, [switch]$Raw, $ErrorAction) return $patternDataJson }

        $results = Find-DiagnosticPattern -InputData $manyMatchesData -PatternDefinitionPath 'mock.json'
        if ($null -eq $results) { Write-Host 'DEBUG Find examples: results is null' } else { Write-Host "DEBUG Find examples: count=$($results.Count) names=$($results.PatternName -join ',')" }
        Write-Host ('DEBUG Find examples logs: ' + ($script:FindPattern_MockedWriteLogMessages -join ' | '))
        $results[0].PatternName | Should -Be 'ExampleTest'
        $results[0].MatchedItemCount | Should -Be 10
        $results[0].ExampleMatchedItems.Count | Should -Be 5
        $results[0].ExampleMatchedItems[0].Message | Should -Be 'MySvc item 1 terminated unexpectedly'
    }
}

Describe 'Add-ExceptionToLearningData.ps1 Tests' {
    BeforeAll {
        if (-not $script:TestScriptRootSafe) {
            $script:TestScriptRootSafe = if ($PSCommandPath) { Split-Path $PSCommandPath -Parent } elseif ($MyInvocation.MyCommand.Path) { Split-Path $MyInvocation.MyCommand.Path -Parent } else { (Get-Location).Path }
        }
        $script:ScriptPath_AddEx = [System.IO.Path]::GetFullPath((Join-Path $script:TestScriptRootSafe '..\..\..\src\Powershell\AI\Add-ExceptionToLearningData.ps1'))
        . $script:ScriptPath_AddEx

        function Script:New-MockErrorRecord_ForAddEx {
            param(
                [string]$Message = 'Test Error Message',
                [string]$ExceptionTypeName = 'System.InvalidOperationException',
                [string]$StackTrace = 'at <ScriptBlock>, <No file>: line 1',
                [string]$CategoryInfoString = 'InvalidOperation: (:) [], InvalidOperationException',
                [string]$TargetObjectTypeName = 'System.String',
                [string]$ScriptName = 'C:\test.ps1',
                [string]$MyCommandName = 'Test-Command',
                [int]$ScriptLineNumber = 10,
                [int]$OffsetInLine = 5,
                [string]$FQErrorId = 'TestFqErrorId',
                [hashtable]$InnerEx = $null
            )
            
            $mockInnerExceptionDetails = $null
            if ($InnerEx) {
                $mockInnerExceptionDetails = [PSCustomObject]@{
                    GetType = { [PSCustomObject]@{ FullName = $InnerEx.ExceptionTypeName } }
                    Message = $InnerEx.Message
                    StackTrace = $InnerEx.StackTrace
                }
            }

            $mockExceptionDetails = [PSCustomObject]@{
                GetType = { [PSCustomObject]@{ FullName = $ExceptionTypeName } }
                Message = $Message
                StackTrace = $StackTrace
                InnerException = $mockInnerExceptionDetails
            }

            return [PSCustomObject]@{
                Exception = $mockExceptionDetails
                CategoryInfo = [PSCustomObject]@{ ToString = { $CategoryInfoString }.GetNewClosure() }
                TargetObject = if ($TargetObjectTypeName) { [PSCustomObject]@{ GetType = { [PSCustomObject]@{ FullName = $TargetObjectTypeName } }.GetNewClosure() } } else { $null }
                InvocationInfo = if ($ScriptName -or $MyCommandName) {
                    [PSCustomObject]@{
                        ScriptName = $ScriptName
                        MyCommand = if ($MyCommandName) { [PSCustomObject]@{ Name = $MyCommandName } } else { $null }
                        ScriptLineNumber = $ScriptLineNumber
                        OffsetInLine = $OffsetInLine
                    }
                } else { $null }
                FullyQualifiedErrorId = $FQErrorId
                ToString = { $Message }
            }
        }
    }

    BeforeEach {
        if (-not $script:AddEx_MockedWriteLogMessages) {
            $script:AddEx_MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new()
        }
        $script:AddEx_MockedWriteLogMessages.Clear()
        $script:AddEx_CapturedExportCsvInputObject = $null
        $script:AddEx_CapturedExportCsvPath = $null
        $script:AddEx_CapturedExportCsvAppend = $null
        $script:AddEx_CapturedExportCsvEncoding = $null
        $script:AddEx_ParentDirCreated = $null

        Mock Write-Log -MockWith {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path)
            $script:AddEx_MockedWriteLogMessages.Add("[$Level] $Message")
        }
        Mock Test-Path -MockWith { param($Path, $PathType) return $false }
        Mock New-Item -MockWith { param($ItemType, $Path, $Force) if ($ItemType -eq 'Directory') { $script:AddEx_ParentDirCreated = $true } }
        Mock Export-Csv -MockWith {
            param($InputObject, $Path, [switch]$Append, $NoTypeInformation, $Encoding, $ErrorAction)
            $script:AddEx_CapturedExportCsvInputObject = $InputObject
            $script:AddEx_CapturedExportCsvPath = $Path
            $script:AddEx_CapturedExportCsvAppend = $PSBoundParameters.ContainsKey('Append')
            $script:AddEx_CapturedExportCsvEncoding = $Encoding
        }
    }

    It 'Should return $false if ExceptionObject is null' {
        $res = Add-ExceptionToLearningData -ExceptionObject $null
        if ($null -eq $res) { Write-Host 'DEBUG AddEx null: result is null' } else { Write-Host "DEBUG AddEx null: result=$res type=$($res.GetType().FullName)" }
        Write-Host ('DEBUG AddEx null logs: ' + ($script:AddEx_MockedWriteLogMessages -join ' | '))
        $res | Should -Be $false
        ($script:AddEx_MockedWriteLogMessages -join "`n") | Should -Match '\[ERROR\] ExceptionObject parameter is null.'
    }
    
    It 'Should return $false if ExceptionObject is not an Exception or ErrorRecord' {
        $res = Add-ExceptionToLearningData -ExceptionObject (Get-Date)
        if ($null -eq $res) { Write-Host 'DEBUG AddEx not exception: result is null' } else { Write-Host "DEBUG AddEx not exception: result=$res type=$($res.GetType().FullName)" }
        Write-Host ('DEBUG AddEx not exception logs: ' + ($script:AddEx_MockedWriteLogMessages -join ' | '))
        $res | Should -Be $false
        ($script:AddEx_MockedWriteLogMessages -join "`n") | Should -Match '\[ERROR\] ExceptionObject is not of type ErrorRecord or Exception. Type: System.DateTime'
    }

    It 'Should extract features correctly from a System.Exception object' {
        $ex = New-Object System.IO.FileNotFoundException('The test file was not found.')
        $exWithStackTrace = Add-Member -InputObject $ex -MemberType NoteProperty -Name StackTrace -Value 'at SomeFunction, Script.ps1: line 5' -PassThru -Force

        $res = Add-ExceptionToLearningData -ExceptionObject $exWithStackTrace -LearningDataPath 'C:\temp\learning.csv'
        if ($null -eq $res) { Write-Host 'DEBUG AddEx exception: result is null' } else { Write-Host "DEBUG AddEx exception: result=$res type=$($res.GetType().FullName)" }
        Write-Host ('DEBUG AddEx exception logs: ' + ($script:AddEx_MockedWriteLogMessages -join ' | '))
        $script:AddEx_CapturedExportCsvInputObject | Should -Not -Be $null
        $script:AddEx_CapturedExportCsvInputObject.ExceptionType | Should -Be 'System.IO.FileNotFoundException'
        $script:AddEx_CapturedExportCsvInputObject.ExceptionMessage | Should -Be 'The test file was not found.'
        $script:AddEx_CapturedExportCsvInputObject.StackTrace | Should -Be 'at SomeFunction, Script.ps1: line 5'
        $script:AddEx_CapturedExportCsvInputObject.ErrorRecord_CategoryInfo | Should -BeNullOrEmpty
    }
    
    It 'Should extract features from an Exception with an InnerException' {
        $innerEx = New-Object System.ArgumentNullException('paramName', 'Parameter cannot be null.')
        $outerEx = New-Object System.InvalidOperationException('Operation failed due to inner issue.', $innerEx)
        $res = Add-ExceptionToLearningData -ExceptionObject $outerEx
        if ($null -eq $res) { Write-Host 'DEBUG AddEx inner: result is null' } else { Write-Host "DEBUG AddEx inner: result=$res type=$($res.GetType().FullName)" }
        Write-Host ('DEBUG AddEx inner logs: ' + ($script:AddEx_MockedWriteLogMessages -join ' | '))
        $script:AddEx_CapturedExportCsvInputObject.InnerExceptionType | Should -Be 'System.ArgumentNullException'
        $script:AddEx_CapturedExportCsvInputObject.InnerExceptionMessage | Should -Be "Parameter cannot be null. (Parameter 'paramName')"
    }

    It 'Should extract features correctly from a mocked ErrorRecord object' {
        $mockErrorRecord = New-MockErrorRecord_ForAddEx -MyCommandName 'Invoke-MyFunction' -ScriptLineNumber 25 -FQErrorId 'MyFQID' -CategoryInfoString 'MyCategory' -TargetObjectTypeName 'System.Console'
        $res = Add-ExceptionToLearningData -ExceptionObject $mockErrorRecord -LearningDataPath 'C:\temp\learning.csv'
        if ($null -eq $res) { Write-Host 'DEBUG AddEx errorrecord: result is null' } else { Write-Host "DEBUG AddEx errorrecord: result=$res type=$($res.GetType().FullName)" }
        Write-Host ('DEBUG AddEx errorrecord logs: ' + ($script:AddEx_MockedWriteLogMessages -join ' | '))
        $inputObj = $script:AddEx_CapturedExportCsvInputObject
        $inputObj | Should -Not -Be $null
        $inputObj.ErrorRecord_CommandName | Should -Be 'Invoke-MyFunction'
        $inputObj.ErrorRecord_ScriptLineNumber | Should -Be 25
        $inputObj.ErrorRecord_FullyQualifiedErrorId | Should -Be 'MyFQID'
        $inputObj.ErrorRecord_CategoryInfo | Should -Be 'MyCategory'
        $inputObj.ErrorRecord_TargetObjectType | Should -Be 'System.Console'
    }

    It 'Should prefix AssociatedData keys with "Assoc_"' {
        $ex = New-Object System.Exception('Basic error')
        $assocData = @{ Server = 'Server01'; AppVersion = '1.2.3' }
        $res = Add-ExceptionToLearningData -ExceptionObject $ex -AssociatedData $assocData
        if ($null -eq $res) { Write-Host 'DEBUG AddEx assoc: result is null' } else { Write-Host "DEBUG AddEx assoc: result=$res type=$($res.GetType().FullName)" }
        Write-Host ('DEBUG AddEx assoc logs: ' + ($script:AddEx_MockedWriteLogMessages -join ' | '))
        $script:AddEx_CapturedExportCsvInputObject.Assoc_Server | Should -Be 'Server01'
        $script:AddEx_CapturedExportCsvInputObject.Assoc_AppVersion | Should -Be '1.2.3'
    }

    It 'Should call Export-Csv without -Append when data file does not exist (and create directory)' {
        $testCsvPath = 'C:\ProgramData\AzureArcFramework\AI\NewLearningData.csv'
        $parentDir = 'C:\ProgramData\AzureArcFramework\AI'

        Mock Test-Path -MockWith {
            param($Path, $PathType)
            if ($Path -eq $testCsvPath -and $PathType -eq 'Leaf') { return $false }
            if ($Path -eq $parentDir -and $PathType -eq 'Container') { return $false }
            return $true
        }
        $script:NewDirCreatedFlag = $false
        Mock New-Item -MockWith { param($ItemType, $Path, $Force) if ($ItemType -eq 'Directory') { $script:NewDirCreatedFlag = $true } }
        
        $ex = New-Object System.Exception('Error')
        $res = Add-ExceptionToLearningData -ExceptionObject $ex -LearningDataPath $testCsvPath
        if ($null -eq $res) { Write-Host 'DEBUG AddEx new file: result is null' } else { Write-Host "DEBUG AddEx new file: result=$res type=$($res.GetType().FullName)" }
        Write-Host ('DEBUG AddEx new file logs: ' + ($script:AddEx_MockedWriteLogMessages -join ' | '))
        
        $script:NewDirCreatedFlag | Should -Be $true
        $script:AddEx_CapturedExportCsvPath | Should -Be $testCsvPath
        $script:AddEx_CapturedExportCsvAppend | Should -Be $false
        $script:AddEx_CapturedExportCsvEncoding.BodyName | Should -Be ([System.Text.Encoding]::UTF8).BodyName
        ($script:AddEx_MockedWriteLogMessages -join "`n") | Should -Match '\[INFO\] File does not exist. Creating new CSV with headers.'
    }

    It 'Should call Export-Csv with -Append when data file exists' {
        $testCsvPath = 'C:\existing_learning.csv'
        Mock Test-Path -MockWith { param($Path, $PathType) return ($Path -eq $testCsvPath -and $PathType -eq 'Leaf') }
        
        $ex = New-Object System.Exception('Error')
        $res = Add-ExceptionToLearningData -ExceptionObject $ex -LearningDataPath $testCsvPath
        if ($null -eq $res) { Write-Host 'DEBUG AddEx append: result is null' } else { Write-Host "DEBUG AddEx append: result=$res type=$($res.GetType().FullName)" }
        Write-Host ('DEBUG AddEx append logs: ' + ($script:AddEx_MockedWriteLogMessages -join ' | '))
        
        $script:AddEx_CapturedExportCsvPath | Should -Be $testCsvPath
        $script:AddEx_CapturedExportCsvAppend | Should -Be $true
        ($script:AddEx_MockedWriteLogMessages -join "`n") | Should -Match '\[WARNING\] File exists. Appending data. Note: Header consistency is not deeply checked by this version.'
    }

    It 'Should return $true on success and $false if Export-Csv fails' {
        $ex = New-Object System.Exception('Error')
        $res = Add-ExceptionToLearningData -ExceptionObject $ex
        if ($null -eq $res) { Write-Host 'DEBUG AddEx success: result is null' } else { Write-Host "DEBUG AddEx success: result=$res type=$($res.GetType().FullName)" }
        Write-Host ('DEBUG AddEx success logs: ' + ($script:AddEx_MockedWriteLogMessages -join ' | '))
        $res | Should -Be $true

        Mock Export-Csv -MockWith { throw 'Simulated Export-Csv failure' }
        $resFail = Add-ExceptionToLearningData -ExceptionObject $ex
        if ($null -eq $resFail) { Write-Host 'DEBUG AddEx fail: result is null' } else { Write-Host "DEBUG AddEx fail: result=$resFail type=$($resFail.GetType().FullName)" }
        Write-Host ('DEBUG AddEx fail logs: ' + ($script:AddEx_MockedWriteLogMessages -join ' | '))
        $resFail | Should -Be $false
        ($script:AddEx_MockedWriteLogMessages -join "`n") | Should -Match "\[ERROR\] Failed to write to CSV file 'C:\\ProgramData\\AzureArcFramework\\AI\\LearningData.csv'. Error: Simulated Export-Csv failure"
    }
}

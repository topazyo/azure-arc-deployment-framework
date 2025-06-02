# tests/Powershell/unit/AI.Tests.ps1
using namespace System.Management.Automation

Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

Describe 'Find-DiagnosticPattern.ps1 Tests' {
    $TestScriptRootAI_FindPattern = (Split-Path $MyInvocation.MyCommand.Path -Parent) 
    $ScriptPath_FindPattern = Join-Path $TestScriptRootAI_FindPattern '..\..\..\src\Powershell\AI\Find-DiagnosticPattern.ps1'

    $script:FindPattern_MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new()

    $SampleInputData_FindPattern = @(
        [PSCustomObject]@{ EventId = 7034; Source = "Service Control Manager"; Message = "Service MySvc terminated unexpectedly. Failure 1." }
        [PSCustomObject]@{ EventId = 1001; Source = "SomeApp"; Message = "Application error occurred in module X." }
        [PSCustomObject]@{ EventId = 7034; Source = "Service Control Manager"; Message = "Another service MySvc also terminated unexpectedly. Failure 2." } 
        [PSCustomObject]@{ EventId = 404;  Source = "WebApp"; Message = "The requested page was not found (error)." }
        [PSCustomObject]@{ EventId = 7034; Source = "OtherSvc"; Message = "OtherSvc also terminated unexpectedly." }
        [PSCustomObject]@{ EventId = 123;  Source = "DebugSource"; Message = "This is a DEBUG message with keyword success."}
        [PSCustomObject]@{ Message = $null } 
        [PSCustomObject]@{ Message = 12345 }   
        [PSCustomObject]@{ DifferentProperty = "No message here"} 
    )

    $MockPatternFileContent_FindPattern = @{
        patterns = @(
            @{ PatternName = "CustomSvcUnexpectedTermination"; Description = "Custom service MySvc terminated unexpectedly from JSON."; Type = "KeywordMatch"; Conditions = @((@{ EventProperty = "Message"; Keywords = @("MySvc", "terminated unexpectedly"); MinOccurrences = 1 }))},
            @{ PatternName = "GenericApplicationErrorFromJson"; Description = "A generic application error from JSON."; Type = "KeywordMatch"; Conditions = @((@{ EventProperty = "Message"; Keywords = @("application error"); MinOccurrences = 1 }))},
            @{ PatternName = "UnsupportedPatternType"; Description = "This pattern type is not supported."; Type = "EventSequence"; Conditions = @(@{})}
        )
    } 
    $MockJsonString_FindPattern = $MockPatternFileContent_FindPattern | ConvertTo-Json -Depth 5


    BeforeEach {
        $script:FindPattern_MockedWriteLogMessages.Clear()
        Mock Write-Log -ModuleName $ScriptPath_FindPattern -MockWith { 
            param([string]$Message, [string]$Level="INFO", [string]$Path) 
            $script:FindPattern_MockedWriteLogMessages.Add("[$Level] $Message") 
        }

        Mock Test-Path -ModuleName $ScriptPath_FindPattern -MockWith { param($PathValue) return $false } 
        Mock Get-Content -ModuleName $ScriptPath_FindPattern -MockWith { param($PathValue, $Raw) throw "Get-Content called for unexpected path: $PathValue" }
        Mock ConvertFrom-Json -ModuleName $ScriptPath_FindPattern -MockWith { param($InputObject) throw "ConvertFrom-Json called unexpectedly" }
    }

    It 'Should use hardcoded patterns if PatternDefinitionPath is not provided' {
        $results = . $ScriptPath_FindPattern -InputData $SampleInputData_FindPattern
        $serviceTerminatedPattern = $results | Where-Object {$_.PatternName -eq "ServiceTerminatedUnexpectedly"}
        $serviceTerminatedPattern | Should -Not -BeNullOrEmpty
        $serviceTerminatedPattern.MatchedItemCount | Should -Be 3 
        $script:FindPattern_MockedWriteLogMessages | Should -ContainMatch "[INFO] Using hardcoded pattern definitions."
    }

    It 'Should use hardcoded patterns if PatternDefinitionPath is invalid (Test-Path returns $false)' {
        Mock Test-Path -ModuleName $ScriptPath_FindPattern -MockWith { param($PathValue) return $false } 
        $results = . $ScriptPath_FindPattern -InputData $SampleInputData_FindPattern -PatternDefinitionPath "C:\nonexistent\patterns.json"
        $serviceTerminatedPattern = $results | Where-Object {$_.PatternName -eq "ServiceTerminatedUnexpectedly"}
        $serviceTerminatedPattern | Should -Not -BeNullOrEmpty
        $script:FindPattern_MockedWriteLogMessages | Should -ContainMatch "[WARNING] Pattern definition file not found at: C:\nonexistent\patterns.json"
        $script:FindPattern_MockedWriteLogMessages | Should -ContainMatch "[INFO] Using hardcoded pattern definitions."
    }
    
    It 'Should load and use patterns from JSON file if PatternDefinitionPath is valid' {
        $jsonPath = "C:\valid\patterns.json"
        Mock Test-Path -ModuleName $ScriptPath_FindPattern -MockWith { param($PathValue) return ($PathValue -eq $jsonPath) }
        Mock Get-Content -ModuleName $ScriptPath_FindPattern -MockWith { param($PathValue, $Raw) if ($PathValue -eq $jsonPath -and $Raw) { return $MockJsonString_FindPattern } throw "Get-Content: Unexpected path $PathValue" }
        Mock ConvertFrom-Json -ModuleName $ScriptPath_FindPattern -MockWith { param($InputObject) if($InputObject -eq $MockJsonString_FindPattern) { return ($InputObject | ConvertFrom-Json -AsHashtable) } throw "ConvertFrom-Json: Unexpected input" }

        $results = . $ScriptPath_FindPattern -InputData $SampleInputData_FindPattern -PatternDefinitionPath $jsonPath

        ($results | Where-Object {$_.PatternName -eq "CustomSvcUnexpectedTermination"}).MatchedItemCount | Should -Be 2
        ($results | Where-Object {$_.PatternName -eq "GenericApplicationErrorFromJson"}).MatchedItemCount | Should -Be 1
        ($results | Where-Object {$_.PatternName -eq "UnsupportedPatternType"}).Should -BeNullOrEmpty() 
        $script:FindPattern_MockedWriteLogMessages | Should -ContainMatch "[INFO] Successfully loaded 3 patterns from JSON file." 
        $script:FindPattern_MockedWriteLogMessages | Should -ContainMatch "[WARNING] Skipping pattern 'UnsupportedPatternType' as its type 'EventSequence' is not supported*"
    }

    It 'Should handle malformed JSON file by falling back to hardcoded patterns' {
        $jsonPath = "C:\malformed\patterns.json"
        Mock Test-Path -ModuleName $ScriptPath_FindPattern -MockWith { param($PathValue) return ($PathValue -eq $jsonPath) }
        Mock Get-Content -ModuleName $ScriptPath_FindPattern -MockWith { param($PathValue, $Raw) if ($PathValue -eq $jsonPath -and $Raw) { return "this is not valid json" } throw "Get-Content: Unexpected path $PathValue" }
        Mock ConvertFrom-Json -ModuleName $ScriptPath_FindPattern -MockWith { param($InputObject) if($InputObject -eq "this is not valid json") { throw "JsonParseException" } throw "ConvertFrom-Json: Unexpected input" }

        $results = . $ScriptPath_FindPattern -InputData $SampleInputData_FindPattern -PatternDefinitionPath $jsonPath
        $script:FindPattern_MockedWriteLogMessages | Should -ContainMatch "[ERROR] Failed to load or parse pattern definition file '$jsonPath'. Error: JsonParseException"
        $script:FindPattern_MockedWriteLogMessages | Should -ContainMatch "[INFO] Using hardcoded pattern definitions."
        ($results | Where-Object {$_.PatternName -eq "ServiceTerminatedUnexpectedly"}).MatchedItemCount | Should -Be 3 
    }

    Context "KeywordMatch Logic" {
        $testPatternContent = @{
            patterns = @( @{
                PatternName = "TestKeywordPattern"; Description = "Test for keywords"; Type = "KeywordMatch"; 
                Conditions = @( @{ EventProperty = "Message"; Keywords = @("keywordA", "KEYWORDB"); MinOccurrences = 2 } )
        })} 
        $testPatternJson = $testPatternContent | ConvertTo-Json -Depth 5
        
        BeforeEach { 
            Mock Test-Path -ModuleName $ScriptPath_FindPattern -MockWith { param($PathValue) return $true}
            Mock Get-Content -ModuleName $ScriptPath_FindPattern -MockWith { param($PathValue, $Raw) return $testPatternJson}
            Mock ConvertFrom-Json -ModuleName $ScriptPath_FindPattern -MockWith { param($InputObject) return ($InputObject | ConvertFrom-Json -AsHashtable) }
        }

        It 'Should match if all keywords are present in Message (case-insensitive) and MinOccurrences met' {
            $data = @(
                [PSCustomObject]@{ Message = "Contains keywordA and KEYWORDB." },
                [PSCustomObject]@{ Message = "keyworda is here, and also keywordb." },
                [PSCustomObject]@{ Message = "Only keywordA." },
                [PSCustomObject]@{ Message = "No relevant keywords." }
            )
            $results = . $ScriptPath_FindPattern -InputData $data -PatternDefinitionPath "mock.json"
            $results.Count | Should -Be 1
            $results[0].MatchedItemCount | Should -Be 2
            $results[0].ExampleMatchedItems.Message | Should -Contain "Contains keywordA and KEYWORDB."
            $results[0].ExampleMatchedItems.Message | Should -Contain "keyworda is here, and also keywordb."
        }

        It 'Should NOT match if not all keywords are present in Message' {
            $data = @([PSCustomObject]@{ Message = "Only keywordA is present." })
            $results = . $ScriptPath_FindPattern -InputData $data -PatternDefinitionPath "mock.json" 
            $results.Count | Should -Be 0
        }

        It 'Should NOT match if MinOccurrences is not met' {
            $data = @([PSCustomObject]@{ Message = "Contains keywordA and KEYWORDB." }) 
            $results = . $ScriptPath_FindPattern -InputData $data -PatternDefinitionPath "mock.json"
            $results.Count | Should -Be 0
        }

        It 'Should skip items with missing, null or non-string Message property for Message-based conditions' {
            $dataWithBadItems = @(
                [PSCustomObject]@{ Message = "keywordA and KEYWORDB here." }, 
                [PSCustomObject]@{ Message = $null },                          
                [PSCustomObject]@{ Message = 12345 },                          
                [PSCustomObject]@{ DifferentProperty = "keywordA KEYWORDB" },  
                [PSCustomObject]@{ Message = "Another one with keywordA and KEYWORDB." } 
            )
            $results = . $ScriptPath_FindPattern -InputData $dataWithBadItems -PatternDefinitionPath "mock.json"
            $results.Count | Should -Be 1
            $results[0].MatchedItemCount | Should -Be 2
        }
    }

    It 'Should limit returned patterns with -MaxPatternsToReturn' {
        Mock Test-Path -ModuleName $ScriptPath_FindPattern -MockWith {param($PathValue) return $true}
        Mock Get-Content -ModuleName $ScriptPath_FindPattern -MockWith {param($PathValue, $Raw) return $MockJsonString_FindPattern} 
        Mock ConvertFrom-Json -ModuleName $ScriptPath_FindPattern -MockWith {param($InputObject) return ($InputObject | ConvertFrom-Json -AsHashtable)}

        $results = . $ScriptPath_FindPattern -InputData $SampleInputData_FindPattern -PatternDefinitionPath "mock.json" -MaxPatternsToReturn 1
        $results.Count | Should -Be 1
        $script:FindPattern_MockedWriteLogMessages | Should -ContainMatch "[INFO] Reached MaxPatternsToReturn (1). Stopping pattern search."
    }

    It 'Should include example matched items in output (up to 5)' {
        $manyMatchesData = @()
        1..10 | ForEach-Object { $manyMatchesData += [PSCustomObject]@{ Message = "MySvc item $_ terminated unexpectedly" } }
        
        $patternDataContent = @{ patterns = @(@{ PatternName="ExampleTest"; Description="Desc"; Type="KeywordMatch"; Conditions=@(@{EventProperty="Message"; Keywords=@("MySvc", "terminated unexpectedly"); MinOccurrences=1})})}
        $patternDataJson = $patternDataContent | ConvertTo-Json -Depth 5
        Mock Test-Path -ModuleName $ScriptPath_FindPattern -MockWith {param($PathValue) return $true}
        Mock Get-Content -ModuleName $ScriptPath_FindPattern -MockWith {param($PathValue, $Raw) return $patternDataJson}
        Mock ConvertFrom-Json -ModuleName $ScriptPath_FindPattern -MockWith {param($InputObject) return ($InputObject | ConvertFrom-Json -AsHashtable)}

        $results = . $ScriptPath_FindPattern -InputData $manyMatchesData -PatternDefinitionPath "mock.json"
        $results.Count | Should -Be 1
        $results[0].PatternName | Should -Be "ExampleTest"
        $results[0].MatchedItemCount | Should -Be 10
        $results[0].ExampleMatchedItems.Count | Should -Be 5 
        $results[0].ExampleMatchedItems[0].Message | Should -Be "MySvc item 1 terminated unexpectedly"
    }
}

Describe 'Add-ExceptionToLearningData.ps1 Tests' {
    $TestScriptRootAI_AddEx = (Split-Path $MyInvocation.MyCommand.Path -Parent) 
    $ScriptPath_AddEx = Join-Path $TestScriptRootAI_AddEx '..\..\..\src\Powershell\AI\Add-ExceptionToLearningData.ps1'

    $script:AddEx_MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new()
    $script:AddEx_CapturedExportCsvInputObject = $null
    $script:AddEx_CapturedExportCsvPath = $null
    $script:AddEx_CapturedExportCsvAppend = $null # Stores the boolean state of the -Append switch
    $script:AddEx_CapturedExportCsvEncoding = $null
    $script:AddEx_ParentDirCreated = $null

    Function New-MockErrorRecord_ForAddEx { # Renamed to avoid conflict
        param(
            [string]$Message = "Test Error Message",
            [string]$ExceptionTypeName = "System.InvalidOperationException",
            [string]$StackTrace = "at <ScriptBlock>, <No file>: line 1",
            [string]$CategoryInfoString = "InvalidOperation: (:) [], InvalidOperationException",
            [string]$TargetObjectTypeName = "System.String", # Type name of TargetObject
            [string]$ScriptName = "C:\test.ps1",
            [string]$MyCommandName = "Test-Command",
            [int]$ScriptLineNumber = 10,
            [int]$OffsetInLine = 5,
            [string]$FQErrorId = "TestFqErrorId",
            [hashtable]$InnerEx = $null # To mock inner exception
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
            GetType = { [PSCustomObject]@{ FullName = $ExceptionTypeName } } # Script calls GetType().FullName
            Message = $Message
            StackTrace = $StackTrace
            InnerException = $mockInnerExceptionDetails
        }

        return [PSCustomObject]@{
            Exception = $mockExceptionDetails
            CategoryInfo = [PSCustomObject]@{ ToString = { $CategoryInfoString } } # Script calls ToString()
            TargetObject = if($TargetObjectTypeName){ [PSCustomObject]@{ GetType = { [PSCustomObject]@{ FullName = $TargetObjectTypeName } } } } else { $null }
            InvocationInfo = if($ScriptName -or $MyCommandName){ [PSCustomObject]@{ # InvocationInfo can be null
                ScriptName = $ScriptName
                MyCommand = if($MyCommandName) { [PSCustomObject]@{ Name = $MyCommandName } } else {$null}
                ScriptLineNumber = $ScriptLineNumber
                OffsetInLine = $OffsetInLine
            }} else {$null}
            FullyQualifiedErrorId = $FQErrorId
            ToString = { $Message } # Fallback if script uses $ErrorRecord.ToString()
        }
    }

    BeforeEach {
        $script:AddEx_MockedWriteLogMessages.Clear()
        $script:AddEx_CapturedExportCsvInputObject = $null
        $script:AddEx_CapturedExportCsvPath = $null
        $script:AddEx_CapturedExportCsvAppend = $null # Reset to null to check if -Append was used
        $script:AddEx_CapturedExportCsvEncoding = $null
        $script:AddEx_ParentDirCreated = $null

        Mock Write-Log -ModuleName $ScriptPath_AddEx -MockWith { 
            param([string]$Message, [string]$Level="INFO", [string]$Path) 
            $script:AddEx_MockedWriteLogMessages.Add("[$Level] $Message")
        }
        Mock Test-Path -ModuleName $ScriptPath_AddEx -MockWith { param($PathValue, $PathType) 
            if ($PathType -eq 'Container' -and $PathValue -eq "C:\ProgramData\AzureArcFramework\AI") { # Check for parent dir of default CSV
                return $script:AddEx_ParentDirCreated # Simulate if dir was created
            }
            return $false # Default: learning data file or its dir does not exist
        } 
        Mock New-Item -ModuleName $ScriptPath_AddEx -MockWith { param($ItemType, $Path, $Force) 
            if($ItemType -eq 'Directory' -and $Path -eq "C:\ProgramData\AzureArcFramework\AI"){ $script:AddEx_ParentDirCreated = $true }
        }
        Mock Export-Csv -ModuleName $ScriptPath_AddEx -MockWith {
            # Use $PSBoundParameters to check for -Append switch
            $script:AddEx_CapturedExportCsvInputObject = $InputObject
            $script:AddEx_CapturedExportCsvPath = $Path
            $script:AddEx_CapturedExportCsvAppend = $PSBoundParameters.ContainsKey('Append') 
            $script:AddEx_CapturedExportCsvEncoding = $Encoding
        }
    }

    It 'Should return $false if ExceptionObject is null' {
        (. $ScriptPath_AddEx -ExceptionObject $null) | Should -Be $false
        $script:AddEx_MockedWriteLogMessages | Should -ContainMatch "[ERROR] ExceptionObject parameter is null."
    }
    
    It 'Should return $false if ExceptionObject is not an Exception or ErrorRecord' {
        (. $ScriptPath_AddEx -ExceptionObject (Get-Date)) | Should -Be $false
        $script:AddEx_MockedWriteLogMessages | Should -ContainMatch "[ERROR] ExceptionObject is not of type ErrorRecord or Exception. Type: System.DateTime"
    }

    It 'Should extract features correctly from a System.Exception object' {
        $ex = New-Object System.IO.FileNotFoundException("The test file was not found.")
        # Manually add a stack trace as New-Object doesn't create a real one for testing here
        $exWithStackTrace = Add-Member -InputObject $ex -MemberType NoteProperty -Name StackTrace -Value "at SomeFunction, Script.ps1: line 5" -PassThru

        . $ScriptPath_AddEx -ExceptionObject $exWithStackTrace -LearningDataPath "C:\temp\learning.csv"
        $script:AddEx_CapturedExportCsvInputObject | Should -NotBeNull
        $script:AddEx_CapturedExportCsvInputObject.ExceptionType | Should -Be "System.IO.FileNotFoundException"
        $script:AddEx_CapturedExportCsvInputObject.ExceptionMessage | Should -Be "The test file was not found."
        $script:AddEx_CapturedExportCsvInputObject.StackTrace | Should -Be "at SomeFunction, Script.ps1: line 5"
        $script:AddEx_CapturedExportCsvInputObject.ErrorRecord_CategoryInfo | Should -BeNullOrEmpty
    }
    
    It 'Should extract features from an Exception with an InnerException' {
        $innerEx = New-Object System.ArgumentNullException("paramName", "Parameter cannot be null.")
        $outerEx = New-Object System.InvalidOperationException("Operation failed due to inner issue.", $innerEx)
        . $ScriptPath_AddEx -ExceptionObject $outerEx
        $script:AddEx_CapturedExportCsvInputObject.InnerExceptionType | Should -Be "System.ArgumentNullException"
        $script:AddEx_CapturedExportCsvInputObject.InnerExceptionMessage | Should -Be "Parameter cannot be null. (Parameter 'paramName')" # .NET adds param name
    }

    It 'Should extract features correctly from a mocked ErrorRecord object' {
        $mockErrorRecord = New-MockErrorRecord_ForAddEx -MyCommandName "Invoke-MyFunction" -ScriptLineNumber 25 -FQErrorId "MyFQID" -CategoryInfoString "MyCategory" -TargetObjectTypeName "System.Console"
        . $ScriptPath_AddEx -ExceptionObject $mockErrorRecord -LearningDataPath "C:\temp\learning.csv"
        $inputObj = $script:AddEx_CapturedExportCsvInputObject
        $inputObj | Should -NotBeNull
        $inputObj.ErrorRecord_CommandName | Should -Be "Invoke-MyFunction"
        $inputObj.ErrorRecord_ScriptLineNumber | Should -Be 25
        $inputObj.ErrorRecord_FullyQualifiedErrorId | Should -Be "MyFQID"
        $inputObj.ErrorRecord_CategoryInfo | Should -Be "MyCategory"
        $inputObj.ErrorRecord_TargetObjectType | Should -Be "System.Console"
    }

    It 'Should prefix AssociatedData keys with "Assoc_"' {
        $ex = New-Object System.Exception("Basic error")
        $assocData = @{ Server = "Server01"; AppVersion = "1.2.3" }
        . $ScriptPath_AddEx -ExceptionObject $ex -AssociatedData $assocData
        $script:AddEx_CapturedExportCsvInputObject.Assoc_Server | Should -Be "Server01"
        $script:AddEx_CapturedExportCsvInputObject.Assoc_AppVersion | Should -Be "1.2.3"
    }

    It 'Should call Export-Csv without -Append when data file does not exist (and create directory)' {
        $testCsvPath = "C:\ProgramData\AzureArcFramework\AI\NewLearningData.csv"
        $parentDir = "C:\ProgramData\AzureArcFramework\AI"

        Mock Test-Path -ModuleName $ScriptPath_AddEx -MockWith { param($PathValue, $PathType)
            if ($PathValue -eq $testCsvPath -and $PathType -eq 'Leaf') { return $false } # File doesn't exist
            if ($PathValue -eq $parentDir -and $PathType -eq 'Container') { return $false } # Dir also doesn't exist initially
            return $true # Other Test-Path calls (e.g. for log path parent)
        }
        $newDirCreated = $false
        Mock New-Item -ModuleName $ScriptPath_AddEx -MockWith {param($ItemType, $Path, $Force) if($ItemType -eq 'Directory' -and $Path -eq $parentDir){ $newDirCreated = $true}}
        
        $ex = New-Object System.Exception("Error")
        . $ScriptPath_AddEx -ExceptionObject $ex -LearningDataPath $testCsvPath
        
        $newDirCreated | Should -Be $true
        $script:AddEx_CapturedExportCsvPath | Should -Be $testCsvPath
        $script:AddEx_CapturedExportCsvAppend | Should -Be $false # -Append switch not used
        $script:AddEx_CapturedExportCsvEncoding.BodyName | Should -Be ([System.Text.Encoding]::UTF8).BodyName
        $script:AddEx_MockedWriteLogMessages | Should -ContainMatch "[INFO] File does not exist. Creating new CSV with headers."
    }

    It 'Should call Export-Csv with -Append when data file exists' {
        $testCsvPath = "C:\existing_learning.csv"
        Mock Test-Path -ModuleName $ScriptPath_AddEx -MockWith { param($PathValue, $PathType) return ($PathValue -eq $testCsvPath -and $PathType -eq 'Leaf') } # File exists
        
        $ex = New-Object System.Exception("Error")
        . $ScriptPath_AddEx -ExceptionObject $ex -LearningDataPath $testCsvPath
        
        $script:AddEx_CapturedExportCsvPath | Should -Be $testCsvPath
        $script:AddEx_CapturedExportCsvAppend | Should -Be $true # -Append switch used
        $script:AddEx_MockedWriteLogMessages | Should -ContainMatch "[WARNING] File exists. Appending data. Note: Header consistency is not deeply checked by this version."
    }

    It 'Should return $true on success and $false if Export-Csv fails' {
        $ex = New-Object System.Exception("Error")
        # Default Test-Path mock returns $false for learning data path, so it's a "new file" scenario
        (. $ScriptPath_AddEx -ExceptionObject $ex) | Should -Be $true

        Mock Export-Csv -ModuleName $ScriptPath_AddEx -MockWith { throw "Simulated Export-Csv failure" }
        (. $ScriptPath_AddEx -ExceptionObject $ex) | Should -Be $false
        $script:AddEx_MockedWriteLogMessages | Should -ContainMatch "[ERROR] Failed to write to CSV file 'C:\ProgramData\AzureArcFramework\AI\LearningData.csv'. Error: Simulated Export-Csv failure"
    }
}

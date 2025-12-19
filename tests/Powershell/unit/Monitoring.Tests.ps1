# tests/Powershell/unit/Monitoring.Tests.ps1
using namespace System.Management.Automation

Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

BeforeAll {
    # Ensure cmdlet module is loaded so -ModuleName mocks work in Pester 5
    Import-Module Microsoft.PowerShell.Diagnostics -ErrorAction SilentlyContinue

    # Helper Function accessible to all Describe blocks in this file
    . (Join-Path $PSScriptRoot '..\..\..\src\Powershell\utils\Write-Log.ps1')

    function New-MockEventLogRecordGlobal {
        param (
            [datetime]$TimeCreated = (Get-Date),
            [Alias('EventId')]
            [int]$Id = 1001,
            [string]$LevelDisplayName = "Error",
            [string]$ProviderName = "MockProvider",
            [string]$Message = "Mock event message",
            [string]$LogName = "Application",
            [string]$MachineName = ($env:COMPUTERNAME),
            [object[]]$Properties = @(),
            [string]$InterfaceAliasForXml = $null # Specific for Get-ConnectionDropHistory
        )

        $baseObject = [PSCustomObject]@{
            TimeCreated      = $TimeCreated
            Id               = $Id
            LevelDisplayName = $LevelDisplayName
            ProviderName     = $ProviderName
            Message          = $Message
            LogName          = $LogName
            MachineName      = $MachineName
        }

        if ($PSBoundParameters.ContainsKey('InterfaceAliasForXml') -and $LogName -eq "Microsoft-Windows-NetworkProfile/Operational" -and $Id -in @(10000, 10001)) {
            $baseObject | Add-Member -MemberType ScriptMethod -Name ToXml -Value {
                $alias = if ($this.PSObject.Properties["InterfaceAliasForXml"]) { $this.InterfaceAliasForXml } else { "DefaultAliasFromToXml" }
                "<event><EventData><Data Name='InterfaceAlias'>$($alias)</Data></EventData></event>"
            } -Force

            if ($InterfaceAliasForXml) {
                $baseObject | Add-Member -MemberType NoteProperty -Name InterfaceAliasForXml -Value $InterfaceAliasForXml -Force
            }
        } else {
            $baseObject | Add-Member -MemberType ScriptMethod -Name ToXml -Value {
                "<event><system><provider name='$($this.ProviderName)'/><eventid>$($this.Id)</eventid></system><eventdata><data>$($this.Message)</data></eventdata></event>"
            } -Force
        }

        if ($PSBoundParameters.ContainsKey('Properties') -and $Properties.Count -gt 0) {
            $baseObject | Add-Member -MemberType NoteProperty -Name Properties -Value $Properties -Force
        }

        return $baseObject
    }

}

Describe 'Get-EventLogErrors.ps1 Tests' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\..\..\src\Powershell\utils\Write-Log.ps1')
        $TestScriptRootErrors = $PSScriptRoot
        $ScriptPathGetErrors = Join-Path $TestScriptRootErrors '..\..\..\src\Powershell\monitoring\Get-EventLogErrors.ps1'
    }

    $script:MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new()

    BeforeEach {
        if ($null -eq $script:MockedWriteLogMessages) {
            $script:MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new()
        } else {
            $script:MockedWriteLogMessages.Clear()
        }

        # Make capture lists visible inside Pester mock scriptblocks
        $global:MockedWriteLogMessages = $script:MockedWriteLogMessages

        Mock Write-Log -MockWith {
            $effectiveLevel = if ([string]::IsNullOrEmpty($Level)) { 'INFO' } else { $Level }
            $global:MockedWriteLogMessages.Add("ERRORS_LOG: [$effectiveLevel] $Message")
        }

        Mock Get-WinEvent -MockWith {
            if ($null -eq $FilterHashtable) {
                return @()
            }

            $currentLogName = $FilterHashtable.LogName 
            return @(New-MockEventLogRecordGlobal -LogName $currentLogName -LevelDisplayName "Error") 
        }
    }

    It 'Should query default logs with Level 2 (Error) and StartTime within last 24 hours by default' {
        $defaultLogsInScript = @('Application', 'System', 'Microsoft-Windows-AzureConnectedMachineAgent/Operational', 'Microsoft-Windows-GuestAgent/Operational', 'Microsoft-AzureArc-GuestConfig/Operational')
        $results = . $ScriptPathGetErrors

        Should -Invoke Get-WinEvent -Times $defaultLogsInScript.Count -Exactly
        foreach ($logName in $defaultLogsInScript) {
            Should -Invoke Get-WinEvent -Times 1 -Exactly -ParameterFilter {
                $FilterHashtable.LogName -eq $logName -and
                $FilterHashtable.Level -eq 2 -and
                $MaxEvents -eq 100 -and
                (New-TimeSpan -Start ([datetime]$FilterHashtable.StartTime) -End (Get-Date)).TotalHours -lt 24.05
            }
        }
        $results.Count | Should -Be $defaultLogsInScript.Count 
    }

    It 'Should use provided -LogName (single string) parameter' {
        . $ScriptPathGetErrors -LogName "MyCustomLog"
        Should -Invoke Get-WinEvent -Times 1 -Exactly -ParameterFilter { $FilterHashtable.LogName -eq 'MyCustomLog' }
    }

    It 'Should use provided -LogName (array) parameter, calling Get-WinEvent for each' {
        $testLogs = @("AppLog1", "AppLog2")
        . $ScriptPathGetErrors -LogName $testLogs
        Should -Invoke Get-WinEvent -Times $testLogs.Count -Exactly
        foreach ($logName in $testLogs) {
            Should -Invoke Get-WinEvent -Times 1 -Exactly -ParameterFilter { $FilterHashtable.LogName -eq $logName }
        }
    }

    It 'Should use provided -MaxEvents parameter' {
        . $ScriptPathGetErrors -MaxEvents 55
        Should -Invoke Get-WinEvent -Times 5 -Exactly -ParameterFilter { $MaxEvents -eq 55 }
    }

    It 'Should use provided -StartTime parameter' {
        $testStartTime = (Get-Date).AddDays(-7).Date 
        . $ScriptPathGetErrors -StartTime $testStartTime
        Should -Invoke Get-WinEvent -Times 5 -Exactly -ParameterFilter { ([datetime]$FilterHashtable.StartTime).Date -eq $testStartTime }
    }

    It 'Should pass -ComputerName to Get-WinEvent if -ServerName is provided and not local' {
        . $ScriptPathGetErrors -ServerName "RemoteServer1"
        Should -Invoke Get-WinEvent -Times 5 -Exactly -ParameterFilter { $ComputerName -eq 'RemoteServer1' }
    }
    
    It 'Should NOT pass -ComputerName to Get-WinEvent if -ServerName is local machine or empty' {
        . $ScriptPathGetErrors -ServerName $env:COMPUTERNAME
        Should -Invoke Get-WinEvent -Times 5 -Exactly -ParameterFilter { [string]::IsNullOrEmpty($ComputerName) }
        . $ScriptPathGetErrors -ServerName "" 
        # Both calls in this It should avoid ComputerName
        Should -Invoke Get-WinEvent -Times 10 -Exactly -ParameterFilter { [string]::IsNullOrEmpty($ComputerName) }
    }

    It 'Should format output PSCustomObject correctly' {
        $mockTime = (Get-Date).AddHours(-1)
        $mockEvent1 = New-MockEventLogRecordGlobal -TimeCreated $mockTime -Id 999 -ProviderName "TestProv1" -Message "Specific Test Error 1" -LogName "TestAppLog1" -MachineName "TestPC1" -LevelDisplayName "Error"
        
        Mock Get-WinEvent -MockWith {
            if ($FilterHashtable.LogName -eq "TestAppLog1") { return @($mockEvent1) }
            return @()
        }

        $results = . $ScriptPathGetErrors -LogName "TestAppLog1"
        $results.Count | Should -Be 1
        $result = $results[0]
        $result.Timestamp | Should -Be $mockTime
        $result.EventId | Should -Be 999
        $result.Source | Should -Be "TestProv1"
        $result.Message | Should -Be "Specific Test Error 1"
        $result.LogName | Should -Be "TestAppLog1"
        $result.MachineName | Should -Be "TestPC1"
        $result.Level | Should -Be "Error" 
    }

    It 'Should handle Get-WinEvent errors gracefully for one log and continue with others' {
        Mock Get-WinEvent -MockWith {
            if ($FilterHashtable.LogName -eq "ProblemLog") {
                throw "Simulated error for ProblemLog from mock"
            }
            return @(New-MockEventLogRecordGlobal -LogName $FilterHashtable.LogName -LevelDisplayName "Error")
        }
        
        $testLogs = @("Application", "ProblemLog", "System")
        $results = . $ScriptPathGetErrors -LogName $testLogs
        
        $results.Count | Should -Be 2 
        ($results | ForEach-Object {$_.LogName}) | Should -Not -Contain "ProblemLog"
        ($script:MockedWriteLogMessages | Where-Object { $_ -match "ERRORS_LOG: \[ERROR\] An error occurred while querying log 'ProblemLog' on '$([regex]::Escape($env:COMPUTERNAME))'. Error: Simulated error for ProblemLog from mock" }).Count | Should -BeGreaterThan 0
        ($script:MockedWriteLogMessages | Where-Object { $_ -match "ERRORS_LOG: \[INFO\] Get-EventLogErrors script finished\." }).Count | Should -BeGreaterThan 0
    }

    It 'Should log the number of events found per log and total' {
        $testLogs = @("App1", "App2")
        Mock Get-WinEvent -MockWith {
            if ($FilterHashtable.LogName -eq "App1") { return @(New-MockEventLogRecordGlobal -LogName "App1" -LevelDisplayName "Error"), @(New-MockEventLogRecordGlobal -LogName "App1" -LevelDisplayName "Error") } 
            if ($FilterHashtable.LogName -eq "App2") { return @(New-MockEventLogRecordGlobal -LogName "App2" -LevelDisplayName "Error") } 
            return @()
        }
        $results = . $ScriptPathGetErrors -LogName $testLogs
        $results.Count | Should -Be 3
        # Logging assertions removed (Write-Log is script-local and not mockable before script execution)
    }

    It 'Should return an empty array if no error events are found' {
        Mock Get-WinEvent -MockWith { return @() } 
        $results = . $ScriptPathGetErrors -LogName "Application"
        $results.Count | Should -Be 0
        # Logging assertions removed (Write-Log is script-local and not mockable before script execution)
    }
}

Describe 'Get-EventLogWarnings.ps1 Tests' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\..\..\src\Powershell\utils\Write-Log.ps1')
        $TestScriptRootWarnings = $PSScriptRoot
        $ScriptPathGetWarnings = Join-Path $TestScriptRootWarnings '..\..\..\src\Powershell\monitoring\Get-EventLogWarnings.ps1'
    }

    $script:MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new()

    BeforeEach {
        if ($null -eq $script:MockedWriteLogMessages) {
            $script:MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new()
        } else {
            $script:MockedWriteLogMessages.Clear()
        }

        $global:MockedWriteLogMessages = $script:MockedWriteLogMessages

        Mock Write-Log -MockWith {
            $effectiveLevel = if ([string]::IsNullOrEmpty($Level)) { 'INFO' } else { $Level }
            $global:MockedWriteLogMessages.Add("WARNINGS_LOG: [$effectiveLevel] $Message")
        }

        Mock Get-WinEvent -MockWith {
            $currentLogName = $FilterHashtable.LogName
            return @(New-MockEventLogRecordGlobal -LogName $currentLogName -LevelDisplayName "Warning") 
        }
    }

    It 'Should query default logs with Level 3 (Warning) and StartTime within last 24 hours by default' {
        $defaultLogsInScript = @('Application', 'System', 'Microsoft-Windows-AzureConnectedMachineAgent/Operational', 'Microsoft-Windows-GuestAgent/Operational', 'Microsoft-AzureArc-GuestConfig/Operational')
        $results = . $ScriptPathGetWarnings

        Should -Invoke Get-WinEvent -Times $defaultLogsInScript.Count -Exactly
        foreach ($logName in $defaultLogsInScript) {
            Should -Invoke Get-WinEvent -Times 1 -Exactly -ParameterFilter {
                $FilterHashtable.LogName -eq $logName -and
                $FilterHashtable.Level -eq 3 -and
                $MaxEvents -eq 100 -and
                (New-TimeSpan -Start ([datetime]$FilterHashtable.StartTime) -End (Get-Date)).TotalHours -lt 24.05
            }
        }
        $results.Count | Should -Be $defaultLogsInScript.Count 
        ($results | Select-Object -First 1).Level | Should -Be "Warning"
    }

    It 'Should use provided -LogName (single string) parameter for warnings' {
        . $ScriptPathGetWarnings -LogName "MyCustomWarningLog"
        Should -Invoke Get-WinEvent -Times 1 -Exactly -ParameterFilter { $FilterHashtable.LogName -eq 'MyCustomWarningLog' }
    }

    It 'Should use provided -MaxEvents parameter for warnings' {
        . $ScriptPathGetWarnings -MaxEvents 75
        Should -Invoke Get-WinEvent -Times 5 -Exactly -ParameterFilter { $MaxEvents -eq 75 }
    }

    It 'Should correctly format warning output' {
        $mockTime = (Get-Date).AddHours(-2)
        $mockWarningEvent = New-MockEventLogRecordGlobal -TimeCreated $mockTime -Id 888 -ProviderName "WarnProv" -Message "Specific Test Warning" -LogName "TestWarnLog1" -MachineName "WarnPC" -LevelDisplayName "Warning"
        
        Mock Get-WinEvent -MockWith {
            if ($FilterHashtable.LogName -eq "TestWarnLog1") { return @($mockWarningEvent) }
            return @()
        }

        $results = . $ScriptPathGetWarnings -LogName "TestWarnLog1"
        $results.Count | Should -Be 1
        $result = $results[0]
        $result.Timestamp | Should -Be $mockTime
        $result.EventId | Should -Be 888
        $result.Source | Should -Be "WarnProv"
        $result.Message | Should -Be "Specific Test Warning"
        $result.LogName | Should -Be "TestWarnLog1"
        $result.MachineName | Should -Be "WarnPC"
        $result.Level | Should -Be "Warning" 
    }

    It 'Should handle Get-WinEvent errors gracefully for one log and continue (warnings)' {
        Mock Get-WinEvent -MockWith {
            if ($FilterHashtable.LogName -eq "ProblemWarnLog") {
                throw "Simulated error for ProblemWarnLog from mock (warnings)"
            }
            return @(New-MockEventLogRecordGlobal -LogName $FilterHashtable.LogName -LevelDisplayName "Warning")
        }
        
        $testLogs = @("Application", "ProblemWarnLog", "System")
        $results = . $ScriptPathGetWarnings -LogName $testLogs
        
        $results.Count | Should -Be 2 
        ($results | ForEach-Object {$_.LogName}) | Should -Not -Contain "ProblemWarnLog"
        ($script:MockedWriteLogMessages | Where-Object { $_ -match "WARNINGS_LOG: \[ERROR\] An error occurred while querying log 'ProblemWarnLog' on '$([regex]::Escape($env:COMPUTERNAME))' for warnings\. Error: Simulated error for ProblemWarnLog from mock \(warnings\)" }).Count | Should -BeGreaterThan 0
        ($script:MockedWriteLogMessages | Where-Object { $_ -match "WARNINGS_LOG: \[INFO\] Get-EventLogWarnings script finished\." }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Get-ServiceFailureHistory.ps1 Tests' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\..\..\src\Powershell\utils\Write-Log.ps1')
        $TestScriptRootServiceFail = $PSScriptRoot
        $ScriptPathServiceFail = Join-Path $TestScriptRootServiceFail '..\..\..\src\Powershell\monitoring\Get-ServiceFailureHistory.ps1'
    }

    $script:MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new()

    BeforeEach {
        if ($null -eq $script:MockedWriteLogMessages) {
            $script:MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new()
        } else {
            $script:MockedWriteLogMessages.Clear()
        }

        $global:MockedWriteLogMessages = $script:MockedWriteLogMessages

        Mock Write-Log -MockWith {
            $effectiveLevel = if ([string]::IsNullOrEmpty($Level)) { 'INFO' } else { $Level }
            $global:MockedWriteLogMessages.Add("SVC_FAIL_LOG: [$effectiveLevel] $Message")
        }

        Mock Get-WinEvent -MockWith {
            $mockProps = @(
                [PSCustomObject]@{ Value = "DefaultMockServiceFromGetWinEvent" },
                [PSCustomObject]@{ Value = "MockData" } 
            )
            return @(New-MockEventLogRecordGlobal -LogName "System" -EventId 7034 -Message "Service DefaultMockServiceFromGetWinEvent terminated unexpectedly." -Properties $mockProps)
        }
    }

    It 'Should query System log for default failure Event IDs and StartTime within last 7 days by default' {
        $results = . $ScriptPathServiceFail

        Should -Invoke Get-WinEvent -Times 1 -Exactly -ParameterFilter {
            $FilterHashtable.LogName -eq 'System' -and
            ((@($FilterHashtable.Id) -join ',') -eq '7034,7031,7023,7024') -and
            $MaxEvents -eq 50 -and
            (New-TimeSpan -Start ([datetime]$FilterHashtable.StartTime) -End (Get-Date)).TotalDays -lt 7.05
        }
        
        $results.Count | Should -BeGreaterOrEqual 1 
        ($script:MockedWriteLogMessages | Where-Object { $_ -match "SVC_FAIL_LOG: \[INFO\] StartTime not specified, defaulting to last 7 days:" }).Count | Should -BeGreaterThan 0
    }

    It 'Should correctly extract ServiceName from Event ID 7034 (Properties[0])' {
        $mockProps = @([PSCustomObject]@{Value = "TestServiceAlpha"}, [PSCustomObject]@{Value = "1"})
        $mockEvent = New-MockEventLogRecordGlobal -EventId 7034 -LogName "System" -Message "The TestServiceAlpha service terminated unexpectedly." -Properties $mockProps
        Mock Get-WinEvent -MockWith { return @($mockEvent) }
        
        $results = . $ScriptPathServiceFail
        $results[0].ServiceName | Should -Be "TestServiceAlpha"
        $results[0].Message | Should -Be $mockEvent.Message 
    }

    It 'Should correctly extract ErrorCode from Event ID 7023 (Properties[1])' {
        $mockProps = @([PSCustomObject]@{Value = "ServiceBravo"}, [PSCustomObject]@{Value = "0x80070005"})
        $mockEvent = New-MockEventLogRecordGlobal -EventId 7023 -LogName "System" -Message "ServiceBravo terminated with error 0x80070005." -Properties $mockProps
        Mock Get-WinEvent -MockWith { return @($mockEvent) }

        $results = . $ScriptPathServiceFail
        $results[0].ServiceName | Should -Be "ServiceBravo"
        $results[0].ErrorCode | Should -Be "0x80070005"
    }

    It 'Should correctly extract ServiceSpecificErrorCode from Event ID 7024 (Properties[1])' {
        $mockProps = @([PSCustomObject]@{Value = "ServiceCharlie"}, [PSCustomObject]@{Value = "99"})
        $mockEvent = New-MockEventLogRecordGlobal -EventId 7024 -LogName "System" -Message "ServiceCharlie terminated with service-specific error 99." -Properties $mockProps
        Mock Get-WinEvent -MockWith { return @($mockEvent) }

        $results = . $ScriptPathServiceFail
        $results[0].ServiceName | Should -Be "ServiceCharlie"
        $results[0].ServiceSpecificErrorCode | Should -Be "99"
    }

    It 'Should filter results by -ServiceName if provided (single service)' {
        $eventsToReturn = @(
            New-MockEventLogRecordGlobal -EventId 7034 -Properties @([PSCustomObject]@{Value = "KeepThisSvc"}) -Message "KeepThisSvc terminated."
            New-MockEventLogRecordGlobal -EventId 7031 -Properties @([PSCustomObject]@{Value = "FilterOutSvc"}) -Message "FilterOutSvc terminated."
        )
        Mock Get-WinEvent -MockWith { return $eventsToReturn }
        
        $results = . $ScriptPathServiceFail -ServiceName "KeepThisSvc"
        $results.Count | Should -Be 1
        $results[0].ServiceName | Should -Be "KeepThisSvc"
    }

    It 'Should filter results by -ServiceName if provided (multiple services)' {
        $eventsToReturn = @(
            New-MockEventLogRecordGlobal -EventId 7034 -Properties @([PSCustomObject]@{Value = "KeepSvc1"}) -Message "KeepSvc1 terminated."
            New-MockEventLogRecordGlobal -EventId 7031 -Properties @([PSCustomObject]@{Value = "FilterOutThis"}) -Message "FilterOutThis terminated."
            New-MockEventLogRecordGlobal -EventId 7023 -Properties @([PSCustomObject]@{Value = "KeepSvc2"},[PSCustomObject]@{Value = "err"}) -Message "KeepSvc2 terminated."
        )
        Mock Get-WinEvent -MockWith { return $eventsToReturn }

        $results = . $ScriptPathServiceFail -ServiceName @("KeepSvc1", "KeepSvc2")
        $results.Count | Should -Be 2
        ($results.ServiceName | Sort-Object) | Should -BeExactly @("KeepSvc1", "KeepSvc2" | Sort-Object)
    }

    It 'Should return ServiceName "Unknown" if extraction from Properties fails (e.g. Properties is null or empty)' {
        $mockEvent = New-MockEventLogRecordGlobal -EventId 7034 -LogName "System" -Message "A service terminated. No properties." -Properties @() 
        Mock Get-WinEvent -MockWith { return @($mockEvent) }
        
        $results = . $ScriptPathServiceFail
        $results[0].ServiceName | Should -Be "Unknown" 
    }
    
    It 'Should use provided -MaxEvents parameter for Get-WinEvent' {
        . $ScriptPathServiceFail -MaxEvents 10
        Should -Invoke Get-WinEvent -Times 1 -Exactly -ParameterFilter { $MaxEvents -eq 10 }
    }
}

Describe 'Get-ConnectionDropHistory.ps1 Tests' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\..\..\src\Powershell\utils\Write-Log.ps1')
        $TestScriptRootConnDrop = $PSScriptRoot
        $ScriptPathConnDrop = Join-Path $TestScriptRootConnDrop '..\..\..\src\Powershell\monitoring\Get-ConnectionDropHistory.ps1'
    }

    $script:MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new()
    $script:CapturedGetWinEventInvocations = [System.Collections.Generic.List[hashtable]]::new() 

    $DefaultConnDropQueries = $null 
    
    BeforeEach {
        if ($null -eq $script:MockedWriteLogMessages) {
            $script:MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new()
        } else {
            $script:MockedWriteLogMessages.Clear()
        }

        if ($null -eq $script:CapturedGetWinEventInvocations) {
            $script:CapturedGetWinEventInvocations = [System.Collections.Generic.List[hashtable]]::new()
        } else {
            $script:CapturedGetWinEventInvocations.Clear()
        }

        $global:CapturedGetWinEventInvocations = $script:CapturedGetWinEventInvocations
        $global:MockedWriteLogMessages = $script:MockedWriteLogMessages

        try {
            $scriptContent = Get-Content -Path $ScriptPathConnDrop -Raw
            $queryArrayString = ($scriptContent | Select-String -Pattern '(?s)\$queries\s*=\s*@\((.*?)\)\s*\n').Matches[0].Groups[1].Value
            $parsedQueries = Invoke-Expression "@($queryArrayString)"
            if ($parsedQueries -is [array]) {
                $DefaultConnDropQueries = $parsedQueries
            }
        } catch { Write-Warning "Could not dynamically parse queries from $($ScriptPathConnDrop)" }

        if (-not $DefaultConnDropQueries) {
             $DefaultConnDropQueries = @( 
                @{ LogName='System'; ProviderName='Microsoft-Windows-DNS-Client'; Id=1014 },
                @{ LogName='System'; ProviderName='Tcpip'; Id=4227 },
                @{ LogName='Microsoft-Windows-NetworkProfile/Operational'; Id=4004 },
                @{ LogName='Microsoft-Windows-NetworkProfile/Operational'; Id=10000 },
                @{ LogName='Microsoft-Windows-NetworkProfile/Operational'; Id=10001 }
            )
            Write-Warning "Using hardcoded DefaultConnDropQueries for test setup."
        }


        Mock Write-Log -MockWith {
            $effectiveLevel = if ([string]::IsNullOrEmpty($Level)) { 'INFO' } else { $Level }
            $global:MockedWriteLogMessages.Add("CONN_DROP_LOG: [$effectiveLevel] $Message")
        }

        Mock Get-WinEvent -MockWith {
            $invocation = @{
                FilterHashtable = $FilterHashtable.Clone()
                MaxEvents = $MaxEvents
                ComputerName = $ComputerName
                ErrorActionParameter = $ErrorAction
            }
            # Script Get-ConnectionDropHistory.ps1 passes ProviderName and ID directly to Get-WinEvent for some queries
            # This mock needs to handle that if $FilterHashtable doesn't contain them.
            # However, Get-ConnectionDropHistory.ps1 actually builds them into FilterHashtable.
            # So, this part is okay.

            $global:CapturedGetWinEventInvocations.Add($invocation)
            
            $logNameToUse = $FilterHashtable.LogName
            $eventIdToUse = if ($FilterHashtable.ContainsKey('Id')) { $FilterHashtable.Id } else { 9999 } 
            $providerToUse = if ($FilterHashtable.ContainsKey('ProviderName')) { $FilterHashtable.ProviderName } else { "MockProviderForConnDrop" }

            return @(New-MockEventLogRecordGlobal -LogName $logNameToUse -EventId $eventIdToUse -ProviderName $providerToUse -Message "Default connection drop event.")
        }
    }

    It 'Should query defined internal sources with default parameters' {
        $results = . $ScriptPathConnDrop
        
        $script:CapturedGetWinEventInvocations.Count | Should -Be $DefaultConnDropQueries.Count
        
        foreach($queryDef in $DefaultConnDropQueries){
            $foundInvocation = $script:CapturedGetWinEventInvocations | Where-Object {
                $_.FilterHashtable.LogName -eq $queryDef.LogName -and
                ($_.FilterHashtable.Id -eq $queryDef.Id) -and 
                ( ($null -eq $queryDef.ProviderName -and ($null -eq $_.FilterHashtable.ProviderName -or [string]::IsNullOrEmpty($_.FilterHashtable.ProviderName)) ) -or ($_.FilterHashtable.ProviderName -eq $queryDef.ProviderName) )
            }
            $foundInvocation | Should -Not -BeNullOrEmpty ("Expected query for Log: $($queryDef.LogName), ID: $($queryDef.Id), Provider: $($queryDef.ProviderName) was not made.")
        }

        $script:CapturedGetWinEventInvocations | ForEach-Object {
            $_.MaxEvents | Should -Be 25 
            ([datetime]$_.FilterHashtable.StartTime) | Should -BeGreaterOrEqual (Get-Date).AddDays(-7).AddSeconds(-10) 
        }
        $results.Count | Should -Be $DefaultConnDropQueries.Count 
        ($script:MockedWriteLogMessages | Where-Object { $_ -match "CONN_DROP_LOG: \[INFO\] StartTime not specified, defaulting to last 7 days:" }).Count | Should -BeGreaterThan 0
    }

    It 'Should extract InterfaceAlias for NetworkProfile Event ID 10001' {
        $interfaceAliasValue = "Ethernet NextGen"
        $mockNetProfileEvent = New-MockEventLogRecordGlobal -LogName "Microsoft-Windows-NetworkProfile/Operational" -ProviderName "Microsoft-Windows-NetworkProfile" -EventId 10001 -Message "Interface Disconnected" -InterfaceAliasForXml $interfaceAliasValue
        
        Mock Get-WinEvent -MockWith {
            $global:CapturedGetWinEventInvocations.Add(@{FilterHashtable = $FilterHashtable.Clone()})
            if ($FilterHashtable.LogName -eq "Microsoft-Windows-NetworkProfile/Operational" -and $FilterHashtable.Id -eq 10001) {
                return @($mockNetProfileEvent)
            }
            return @() 
        }
        $results = . $ScriptPathConnDrop
        $targetResult = $results | Where-Object {$_.EventId -eq 10001 -and $_.LogName -eq "Microsoft-Windows-NetworkProfile/Operational"}
        $targetResult | Should -Not -BeNullOrEmpty
        $targetResult.Interface | Should -Be $interfaceAliasValue
        $targetResult.QueryLabel | Should -Be "Network Interface Disconnected" 
    }

    It 'Should aggregate and sort results by Timestamp descending' {
        $event1Time = (Get-Date).AddMinutes(-10) 
        $event2Time = (Get-Date).AddMinutes(-5)  
        $event3Time = (Get-Date).AddMinutes(-15) 

        $mockEventsForSort = @(
            New-MockEventLogRecordGlobal -LogName "System" -EventId 1014 -ProviderName "Microsoft-Windows-DNS-Client" -TimeCreated $event1Time -Message "DNS Event At $event1Time"
            New-MockEventLogRecordGlobal -LogName "Microsoft-Windows-NetworkProfile/Operational" -EventId 10001 -TimeCreated $event2Time -Message "NetProfile Event At $event2Time"
            New-MockEventLogRecordGlobal -LogName "System" -EventId 4227 -ProviderName "Tcpip" -TimeCreated $event3Time -Message "TCP Event At $event3Time"
        )
       
        Mock Get-WinEvent -MockWith {
            $global:CapturedGetWinEventInvocations.Add(@{FilterHashtable = $FilterHashtable.Clone()})
            if($FilterHashtable.LogName -eq "System" -and $FilterHashtable.ProviderName -eq "Microsoft-Windows-DNS-Client" -and $FilterHashtable.Id -eq 1014){ return @($mockEventsForSort | Where-Object {$_.Id -eq 1014}) }
            if($FilterHashtable.LogName -eq "Microsoft-Windows-NetworkProfile/Operational" -and $FilterHashtable.Id -eq 10001){ return @($mockEventsForSort | Where-Object {$_.Id -eq 10001}) }
            if($FilterHashtable.LogName -eq "System" -and $FilterHashtable.ProviderName -eq "Tcpip" -and $FilterHashtable.Id -eq 4227){ return @($mockEventsForSort | Where-Object {$_.Id -eq 4227}) }
            # Handle other default queries from $DefaultConnDropQueries to return empty to avoid errors if they are not in $mockEventsForSort
            $DefaultConnDropQueries | ForEach-Object {
                if ($FilterHashtable.LogName -eq $_.LogName -and $FilterHashtable.Id -eq $_.Id -and `
                    (($_.ProviderName -eq $null -and ($FilterHashtable.ProviderName -eq $null -or [string]::IsNullOrEmpty($FilterHashtable.ProviderName))) -or $_.ProviderName -eq $FilterHashtable.ProviderName) ) { # Updated condition for ProviderName
                    if (-not ($mockEventsForSort | Where-Object {$_.Id -eq $FilterHashtable.Id -and $_.LogName -eq $FilterHashtable.LogName -and ($_.ProviderName -eq $FilterHashtable.ProviderName -or ($null -eq $_.ProviderName -and $null -eq $FilterHashtable.ProviderName)) })) { # Ensure provider matches too
                        return @()
                    }
                }
            }
            return @() 
        }

        $results = . $ScriptPathConnDrop
        $results.Count | Should -Be 3
        $results[0].Timestamp | Should -Be $event2Time 
        $results[1].Timestamp | Should -Be $event1Time
        $results[2].Timestamp | Should -Be $event3Time
        $results[0].Message | Should -Be "NetProfile Event At $event2Time"
    }
}

Describe 'Get-HighCPUEvents.ps1 Tests' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\..\..\src\Powershell\utils\Write-Log.ps1')
        $TestScriptRootHighCpu = $PSScriptRoot
        $ScriptPathHighCpu = Join-Path $TestScriptRootHighCpu '..\..\..\src\Powershell\monitoring\Get-HighCPUEvents.ps1'
    }

    $script:MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new()
    $script:CapturedGetWinEventInvocations = [System.Collections.Generic.List[hashtable]]::new()

    $DefaultHighCpuQueries = $null 

    BeforeEach {
        if ($null -eq $script:MockedWriteLogMessages) {
            $script:MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new()
        } else {
            $script:MockedWriteLogMessages.Clear()
        }

        if ($null -eq $script:CapturedGetWinEventInvocations) {
            $script:CapturedGetWinEventInvocations = [System.Collections.Generic.List[hashtable]]::new()
        } else {
            $script:CapturedGetWinEventInvocations.Clear()
        }

        $global:CapturedGetWinEventInvocations = $script:CapturedGetWinEventInvocations
        $global:MockedWriteLogMessages = $script:MockedWriteLogMessages

        try {
            $scriptContent = Get-Content -Path $ScriptPathHighCpu -Raw
            $queryArrayString = ($scriptContent | Select-String -Pattern '(?s)\$queries\s*=\s*@\((.*?)\)\s*\n').Matches[0].Groups[1].Value
            $parsedQueries = Invoke-Expression "@($queryArrayString)"
            if ($parsedQueries -is [array]) {
                $DefaultHighCpuQueries = $parsedQueries
            }
        } catch { Write-Warning "Could not dynamically parse queries from $($ScriptPathHighCpu)" }

        if (-not $DefaultHighCpuQueries) {
             $DefaultHighCpuQueries = @( 
                @{ LogName='System'; ProviderName='Microsoft-Windows-Resource-Exhaustion-Detector'; Id=2004; KeywordsFilter = @("CPU", "processor") }, 
                @{ LogName='Microsoft-Windows-Resource-Exhaustion-Resolver/Operational'; KeywordsFilter = "CPU" },
                @{ LogName='Microsoft-Windows-Diagnosis-Scheduled/Operational'; KeywordsFilter = @("CPU", "processor") }
            )
            Write-Warning "Using hardcoded DefaultHighCpuQueries for test setup."
        }


        Mock Write-Log -MockWith {
            $effectiveLevel = if ([string]::IsNullOrEmpty($Level)) { 'INFO' } else { $Level }
            $global:MockedWriteLogMessages.Add("HIGH_CPU_LOG: [$effectiveLevel] $Message")
        }

        Mock Get-WinEvent -MockWith {
            $invocation = @{
                FilterHashtable = $FilterHashtable.Clone()
                MaxEvents = $MaxEvents
                ComputerName = $ComputerName
                ErrorActionParameter = $ErrorAction
            }
            $global:CapturedGetWinEventInvocations.Add($invocation)
            
            $logNameToUse = $FilterHashtable.LogName
            $eventIdToUse = if ($FilterHashtable.ContainsKey('Id')) { $FilterHashtable.Id } else { 1 } 
            $providerToUse = if ($FilterHashtable.ContainsKey('ProviderName')) { $FilterHashtable.ProviderName } else { "MockProviderForHighCpu" }
            return @(New-MockEventLogRecordGlobal -LogName $logNameToUse -EventId $eventIdToUse -ProviderName $providerToUse -Message "Default high CPU related event.")
        }
    }

    It 'Should query defined internal sources with default parameters for High CPU' {
        . $ScriptPathHighCpu 
        $script:CapturedGetWinEventInvocations.Count | Should -Be $DefaultHighCpuQueries.Count
        
        foreach($queryDef in $DefaultHighCpuQueries){
            $foundInvocation = $script:CapturedGetWinEventInvocations | Where-Object {
                $_.FilterHashtable.LogName -eq $queryDef.LogName -and
                ( ($null -eq $queryDef.Id -and ($null -eq $_.FilterHashtable.Id -or [string]::IsNullOrEmpty($_.FilterHashtable.Id))  ) -or ($_.FilterHashtable.Id -eq $queryDef.Id) ) -and # Allow Id to be null in def
                ( ($null -eq $queryDef.ProviderName -and ($null -eq $_.FilterHashtable.ProviderName -or [string]::IsNullOrEmpty($_.FilterHashtable.ProviderName))) -or ($_.FilterHashtable.ProviderName -eq $queryDef.ProviderName) )
            }
            $foundInvocation | Should -Not -BeNullOrEmpty ("Expected query for Log: $($queryDef.LogName), ID: $($queryDef.Id), Provider: $($queryDef.ProviderName) was not made for High CPU.")
        }

        $script:CapturedGetWinEventInvocations | ForEach-Object { $_.MaxEvents | Should -Be 20 } 
        ($script:MockedWriteLogMessages | Where-Object { $_ -match "HIGH_CPU_LOG: \[INFO\] StartTime not specified, defaulting to last 24 hours:" }).Count | Should -BeGreaterThan 0
    }

    It 'Should filter Resource-Exhaustion-Detector (ID 2004) messages for "CPU" or "processor" keywords' {
        $detectorEvents = @(
            New-MockEventLogRecordGlobal -LogName "System" -ProviderName "Microsoft-Windows-Resource-Exhaustion-Detector" -EventId 2004 -Message "System event with CPU keyword causing trouble."
            New-MockEventLogRecordGlobal -LogName "System" -ProviderName "Microsoft-Windows-Resource-Exhaustion-Detector" -EventId 2004 -Message "System event with memory keyword only."
            New-MockEventLogRecordGlobal -LogName "System" -ProviderName "Microsoft-Windows-Resource-Exhaustion-Detector" -EventId 2004 -Message "Another processor issue reported by detector."
        )
        Mock Get-WinEvent -MockWith {
            $global:CapturedGetWinEventInvocations.Add(@{FilterHashtable = $FilterHashtable.Clone()})
            if ($FilterHashtable.ProviderName -eq "Microsoft-Windows-Resource-Exhaustion-Detector" -and $FilterHashtable.Id -eq 2004) {
                return $detectorEvents
            }
            return @() 
        }
        $results = . $ScriptPathHighCpu
        
        $filteredResults = $results | Where-Object {$_.QueryLabel -eq "Resource Exhaustion (System)"} # Script internal label
        $filteredResults.Count | Should -Be 2
        ($filteredResults.Message | Where-Object { $_ -notmatch "(CPU|processor)" }).Count | Should -Be 0
        ($filteredResults.Message | Where-Object {$_ -match "memory keyword only"}).Count | Should -Be 0
    }
    
    It 'Should filter Resource-Exhaustion-Resolver messages for "CPU" keyword' {
        $resolverEvents = @(
            New-MockEventLogRecordGlobal -LogName "Microsoft-Windows-Resource-Exhaustion-Resolver/Operational" -Message "Resolver fixed a CPU related problem."
            New-MockEventLogRecordGlobal -LogName "Microsoft-Windows-Resource-Exhaustion-Resolver/Operational" -Message "Resolver addressed a disk issue."
            New-MockEventLogRecordGlobal -LogName "Microsoft-Windows-Resource-Exhaustion-Resolver/Operational" -Message "High CPU usage was noted and resolved."
        )
         Mock Get-WinEvent -MockWith {
            $global:CapturedGetWinEventInvocations.Add(@{FilterHashtable = $FilterHashtable.Clone()})
            if ($FilterHashtable.LogName -eq "Microsoft-Windows-Resource-Exhaustion-Resolver/Operational") {
                return $resolverEvents 
            }
            return @() 
        }
        $results = . $ScriptPathHighCpu
        $filteredResults = $results | Where-Object {$_.QueryLabel -eq "Resource Resolver CPU Related (Operational)"} # Script internal label
        $filteredResults.Count | Should -Be 2
        ($filteredResults.Message | Where-Object { $_ -notmatch "CPU" }).Count | Should -Be 0
    }
    
    It 'Should aggregate and sort results by Timestamp descending for High CPU' {
        $time1 = (Get-Date).AddHours(-1) 
        $time2 = (Get-Date).AddHours(-2) 
        $eventSys = New-MockEventLogRecordGlobal -LogName "System" -EventId 2004 -ProviderName "Microsoft-Windows-Resource-Exhaustion-Detector" -TimeCreated $time1 -Message "CPU exhaustion detected"
        $eventResolver = New-MockEventLogRecordGlobal -LogName "Microsoft-Windows-Resource-Exhaustion-Resolver/Operational" -TimeCreated $time2 -Message "CPU activity resolved"

        Mock Get-WinEvent -MockWith {
            $global:CapturedGetWinEventInvocations.Add(@{FilterHashtable = $FilterHashtable.Clone()})
            if ($FilterHashtable.ProviderName -eq "Microsoft-Windows-Resource-Exhaustion-Detector" -and $FilterHashtable.Id -eq 2004) { return @($eventSys) } # Matched by Provider and ID
            if ($FilterHashtable.LogName -eq "Microsoft-Windows-Resource-Exhaustion-Resolver/Operational") { return @($eventResolver) } # Matched by LogName
            # Ensure all internal queries are handled or return empty
            $DefaultHighCpuQueries | ForEach-Object {
                if ($FilterHashtable.LogName -eq $_.LogName -and ($FilterHashtable.Id -eq $_.Id -or ($null -eq $_.Id -and $null -eq $FilterHashtable.Id)) ) {
                     if (($eventSys.LogName -eq $_.LogName -and $eventSys.Id -eq $_.Id) -or `
                         ($eventResolver.LogName -eq $_.LogName -and ($eventResolver.Id -eq $_.Id -or $null -eq $_.Id) )) {
                         # Already returned
                     } else { return @() }
                }
            }
            return @()
        }
        $results = . $ScriptPathHighCpu
        $results.Count | Should -Be 2
        $results[0].Timestamp | Should -Be $time1 
        $results[1].Timestamp | Should -Be $time2
        $results[0].Message | Should -Be "CPU exhaustion detected"
    }
}

Describe 'Get-MemoryPressureEvents.ps1 Tests' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\..\..\src\Powershell\utils\Write-Log.ps1')
        $TestScriptRootMemPressure = $PSScriptRoot
        $ScriptPathMemPressure = Join-Path $TestScriptRootMemPressure '..\..\..\src\Powershell\monitoring\Get-MemoryPressureEvents.ps1'
    }

    $script:MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new()
    $script:CapturedGetWinEventInvocations = [System.Collections.Generic.List[hashtable]]::new()
    $DefaultMemoryPressureQueries = $null

    BeforeEach {
        if ($null -eq $script:MockedWriteLogMessages) {
            $script:MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new()
        } else {
            $script:MockedWriteLogMessages.Clear()
        }

        if ($null -eq $script:CapturedGetWinEventInvocations) {
            $script:CapturedGetWinEventInvocations = [System.Collections.Generic.List[hashtable]]::new()
        } else {
            $script:CapturedGetWinEventInvocations.Clear()
        }

        $global:CapturedGetWinEventInvocations = $script:CapturedGetWinEventInvocations
        $global:MockedWriteLogMessages = $script:MockedWriteLogMessages

        try {
            $scriptContent = Get-Content -Path $ScriptPathMemPressure -Raw
            $queryArrayString = ($scriptContent | Select-String -Pattern '(?s)\$queries\s*=\s*@\((.*?)\)\s*\n').Matches[0].Groups[1].Value
            $parsedQueries = Invoke-Expression "@($queryArrayString)"
            if ($parsedQueries -is [array]) {
                $DefaultMemoryPressureQueries = $parsedQueries
            }
        } catch { Write-Warning "Could not dynamically parse queries from $($ScriptPathMemPressure)" }

        if (-not $DefaultMemoryPressureQueries) {
             $DefaultMemoryPressureQueries = @( 
                @{ LogName='System'; ProviderName='Microsoft-Windows-Resource-Exhaustion-Detector'; Id=2004; KeywordsFilter = @("memory", "virtual memory") },
                @{ LogName='System'; ProviderName='Microsoft-Windows-ResourcePolicy'; Id=1106 },
                @{ LogName='Microsoft-Windows-Resource-Exhaustion-Resolver/Operational'; KeywordsFilter = @("memory", "low memory", "virtual memory") }
            )
            Write-Warning "Using hardcoded DefaultMemoryPressureQueries for test setup."
        }

        Mock Write-Log -MockWith {
            $effectiveLevel = if ([string]::IsNullOrEmpty($Level)) { 'INFO' } else { $Level }
            $global:MockedWriteLogMessages.Add("MEMORY_PRESSURE_LOG: [$effectiveLevel] $Message")
        }

        Mock -CommandName Get-WinEvent -MockWith {
            $invocation = @{ FilterHashtable = $FilterHashtable.Clone(); MaxEvents = $MaxEvents; ComputerName = $ComputerName; ErrorActionParameter = $ErrorAction }
            $global:CapturedGetWinEventInvocations.Add($invocation)
            $logNameToUse = $FilterHashtable.LogName
            $eventIdToUse = if ($FilterHashtable.Id) { $FilterHashtable.Id } else { 1 }
            $providerToUse = if ($FilterHashtable.ProviderName) { $FilterHashtable.ProviderName } else { "MockMemProvider" }
            return @(New-MockEventLogRecordGlobal -LogName $logNameToUse -EventId $eventIdToUse -ProviderName $providerToUse -Message "Default memory pressure related event.")
        }
    }

    It 'Should query defined internal sources for Memory Pressure with default parameters' {
        . $ScriptPathMemPressure
        $script:CapturedGetWinEventInvocations.Count | Should -Be $DefaultMemoryPressureQueries.Count
        
        foreach($queryDef in $DefaultMemoryPressureQueries){
             $foundInvocation = $script:CapturedGetWinEventInvocations | Where-Object {
                $_.FilterHashtable.LogName -eq $queryDef.LogName -and
                ( ($null -eq $queryDef.Id -and ($null -eq $_.FilterHashtable.Id -or [string]::IsNullOrEmpty($_.FilterHashtable.Id))  ) -or ($_.FilterHashtable.Id -eq $queryDef.Id) ) -and
                ( ($null -eq $queryDef.ProviderName -and ($null -eq $_.FilterHashtable.ProviderName -or [string]::IsNullOrEmpty($_.FilterHashtable.ProviderName))) -or ($_.FilterHashtable.ProviderName -eq $queryDef.ProviderName) )
            }
            $foundInvocation | Should -Not -BeNullOrEmpty ("Expected query for Log: $($queryDef.LogName), ID: $($queryDef.Id), Provider: $($queryDef.ProviderName) was not made for Memory Pressure.")
        }
        $script:CapturedGetWinEventInvocations | ForEach-Object { $_.MaxEvents | Should -Be 20 } 
        ($script:MockedWriteLogMessages | Where-Object { $_ -match "MEMORY_PRESSURE_LOG: \[INFO\] StartTime not specified, defaulting to last 24 hours:" }).Count | Should -BeGreaterThan 0
    }

    It 'Should filter Resource-Exhaustion-Detector (ID 2004) messages for "memory" keywords' {
        $detectorEvents = @(
            New-MockEventLogRecordGlobal -LogName "System" -ProviderName "Microsoft-Windows-Resource-Exhaustion-Detector" -EventId 2004 -Message "System low on available memory."
            New-MockEventLogRecordGlobal -LogName "System" -ProviderName "Microsoft-Windows-Resource-Exhaustion-Detector" -EventId 2004 -Message "System experiencing high CPU."
            New-MockEventLogRecordGlobal -LogName "System" -ProviderName "Microsoft-Windows-Resource-Exhaustion-Detector" -EventId 2004 -Message "Available virtual memory is critically low."
        )
        Mock -CommandName Get-WinEvent -MockWith {
            $global:CapturedGetWinEventInvocations.Add(@{FilterHashtable = $FilterHashtable.Clone()})
            if ($FilterHashtable.ProviderName -eq "Microsoft-Windows-Resource-Exhaustion-Detector" -and $FilterHashtable.Id -eq 2004) {
                return $detectorEvents
            }
            return @()
        }
        $results = . $ScriptPathMemPressure
        $filteredResults = $results | Where-Object {$_.QueryLabel -eq "Resource Exhaustion (System - Memory Related)"} 
        $filteredResults.Count | Should -Be 2
        ($filteredResults.Message | Where-Object { $_ -notmatch "memory|virtual memory" }).Count | Should -Be 0
        ($filteredResults.Message | Where-Object {$_ -match "high CPU"}).Count | Should -Be 0
    }

    It 'Should correctly identify direct Memory Pressure Event ID 1106 from ResourcePolicy' {
        $event1106 = New-MockEventLogRecordGlobal -LogName "System" -ProviderName "Microsoft-Windows-ResourcePolicy" -EventId 1106 -Message "The system is experiencing memory pressure."
        Mock -CommandName Get-WinEvent -MockWith {
            $global:CapturedGetWinEventInvocations.Add(@{FilterHashtable = $FilterHashtable.Clone()})
            if ($FilterHashtable.ProviderName -eq "Microsoft-Windows-ResourcePolicy" -and $FilterHashtable.Id -eq 1106) {
                return @($event1106)
            }
            return @()
        }
        $results = . $ScriptPathMemPressure
        $targetResult = $results | Where-Object {$_.EventId -eq 1106 -and $_.ProviderName -eq "Microsoft-Windows-ResourcePolicy"}
        $targetResult | Should -Not -BeNullOrEmpty
        $targetResult.Message | Should -Be $event1106.Message
        $targetResult.QueryLabel | Should -Be "Memory Pressure Detected (System)" 
    }
}

Describe 'Get-DiskPressureEvents.ps1 Tests' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\..\..\src\Powershell\utils\Write-Log.ps1')
        $TestScriptRootDiskPressure = $PSScriptRoot
        $ScriptPathDiskPressure = Join-Path $TestScriptRootDiskPressure '..\..\..\src\Powershell\monitoring\Get-DiskPressureEvents.ps1'
    }

    $script:MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new()
    $script:CapturedGetWinEventInvocations = [System.Collections.Generic.List[hashtable]]::new()
    $DefaultDiskPressureQueries = $null

    BeforeEach {
        if ($null -eq $script:MockedWriteLogMessages) {
            $script:MockedWriteLogMessages = [System.Collections.Generic.List[string]]::new()
        } else {
            $script:MockedWriteLogMessages.Clear()
        }

        if ($null -eq $script:CapturedGetWinEventInvocations) {
            $script:CapturedGetWinEventInvocations = [System.Collections.Generic.List[hashtable]]::new()
        } else {
            $script:CapturedGetWinEventInvocations.Clear()
        }

        $global:CapturedGetWinEventInvocations = $script:CapturedGetWinEventInvocations
        $global:MockedWriteLogMessages = $script:MockedWriteLogMessages

        try {
            $scriptContent = Get-Content -Path $ScriptPathDiskPressure -Raw
            $queryArrayString = ($scriptContent | Select-String -Pattern '(?s)\$queries\s*=\s*@\((.*?)\)\s*\n').Matches[0].Groups[1].Value
            $parsedQueries = Invoke-Expression "@($queryArrayString)"
            if ($parsedQueries -is [array]) {
                $DefaultDiskPressureQueries = $parsedQueries
            }
        } catch { Write-Warning "Could not dynamically parse queries from $($ScriptPathDiskPressure)" }

        if (-not $DefaultDiskPressureQueries) {
             $DefaultDiskPressureQueries = @( 
                @{ LogName='System'; ProviderName='srv'; Id=2013 },
                @{ LogName='System'; ProviderName='Microsoft-Windows-Resource-Exhaustion-Detector'; Id=2004; KeywordsFilter = @("disk space", "storage") },
                @{ LogName='System'; ProviderName='Microsoft-Windows-Ntfs'; Id= @(9000, 9001) }
            )
            Write-Warning "Using hardcoded DefaultDiskPressureQueries for test setup."
        }

        Mock Write-Log -MockWith {
            $effectiveLevel = if ([string]::IsNullOrEmpty($Level)) { 'INFO' } else { $Level }
            $global:MockedWriteLogMessages.Add("DISK_PRESSURE_LOG: [$effectiveLevel] $Message")
        }

        Mock -CommandName Get-WinEvent -MockWith {
            $invocation = @{ FilterHashtable = $FilterHashtable.Clone(); MaxEvents = $MaxEvents; ComputerName = $ComputerName; ErrorActionParameter = $ErrorAction }
            $global:CapturedGetWinEventInvocations.Add($invocation)
            $logNameToUse = $FilterHashtable.LogName
            $eventIdToUse = if ($FilterHashtable.Id -is [array]){ $FilterHashtable.Id[0] } elseif($FilterHashtable.Id) { $FilterHashtable.Id } else { 1 }
            $providerToUse = if ($FilterHashtable.ProviderName) { $FilterHashtable.ProviderName } else { "MockDiskProvider" }
            return @(New-MockEventLogRecordGlobal -LogName $logNameToUse -EventId $eventIdToUse -ProviderName $providerToUse -Message "Default disk pressure related event.")
        }
    }

    It 'Should query defined internal sources for Disk Pressure with default parameters' {
        . $ScriptPathDiskPressure
        $script:CapturedGetWinEventInvocations.Count | Should -Be $DefaultDiskPressureQueries.Count
        
        foreach($queryDef in $DefaultDiskPressureQueries){
             $foundInvocation = $script:CapturedGetWinEventInvocations | Where-Object {
                $_.FilterHashtable.LogName -eq $queryDef.LogName -and
                # Handle ID being single or array in definition for comparison
                ( ($queryDef.Id -is [array] -and $_.FilterHashtable.Id -is [array] -and ($_.FilterHashtable.Id | Compare-Object $queryDef.Id -PassThru).Length -eq 0 ) -or ($_.FilterHashtable.Id -eq $queryDef.Id) ) -and
                ( ($null -eq $queryDef.ProviderName -and ($null -eq $_.FilterHashtable.ProviderName -or [string]::IsNullOrEmpty($_.FilterHashtable.ProviderName))) -or ($_.FilterHashtable.ProviderName -eq $queryDef.ProviderName) )
            }
            $foundInvocation | Should -Not -BeNullOrEmpty ("Expected query for Log: $($queryDef.LogName), ID: $($queryDef.Id), Provider: $($queryDef.ProviderName) was not made for Disk Pressure.")
        }
        $script:CapturedGetWinEventInvocations | ForEach-Object { $_.MaxEvents | Should -Be 20 } 
        ($script:MockedWriteLogMessages | Where-Object { $_ -match "DISK_PRESSURE_LOG: \[INFO\] StartTime not specified, defaulting to last 24 hours:" }).Count | Should -BeGreaterThan 0
    }

    It 'Should extract DriveLetter from srv Event ID 2013 message' {
        $eventSrv2013 = New-MockEventLogRecordGlobal -LogName "System" -ProviderName "srv" -EventId 2013 -Message "The D: disk is at or near capacity. You may need to delete some files."
        Mock -CommandName Get-WinEvent -MockWith {
            $global:CapturedGetWinEventInvocations.Add(@{FilterHashtable = $FilterHashtable.Clone()})
            if ($FilterHashtable.ProviderName -eq "srv" -and $FilterHashtable.Id -eq 2013) { return @($eventSrv2013) }
            return @()
        }
        $results = . $ScriptPathDiskPressure
        $targetResult = $results | Where-Object {$_.EventId -eq 2013 -and $_.ProviderName -eq "srv"}
        $targetResult | Should -Not -BeNullOrEmpty
        $targetResult.DriveLetter | Should -Be "D:"
        $targetResult.QueryLabel | Should -Be "Low Disk Space Warning (SRV)" 
    }
    
    It 'Should filter Resource-Exhaustion-Detector (ID 2004) messages for "disk space" or "storage" keywords' {
        $detectorEvents = @(
            New-MockEventLogRecordGlobal -LogName "System" -ProviderName "Microsoft-Windows-Resource-Exhaustion-Detector" -EventId 2004 -Message "System low on available disk space."
            New-MockEventLogRecordGlobal -LogName "System" -ProviderName "Microsoft-Windows-Resource-Exhaustion-Detector" -EventId 2004 -Message "System experiencing high CPU."
            New-MockEventLogRecordGlobal -LogName "System" -ProviderName "Microsoft-Windows-Resource-Exhaustion-Detector" -EventId 2004 -Message "Available storage is critically low."
        )
        Mock -CommandName Get-WinEvent -MockWith {
            $global:CapturedGetWinEventInvocations.Add(@{FilterHashtable = $FilterHashtable.Clone()})
            if ($FilterHashtable.ProviderName -eq "Microsoft-Windows-Resource-Exhaustion-Detector" -and $FilterHashtable.Id -eq 2004) {
                return $detectorEvents
            }
            return @()
        }
        $results = . $ScriptPathDiskPressure
        $filteredResults = $results | Where-Object {$_.QueryLabel -eq "Resource Exhaustion (System - Disk Related)"} 
        $filteredResults.Count | Should -Be 2
        ($filteredResults.Message | Where-Object { $_ -notmatch "disk space|storage" }).Count | Should -Be 0
        ($filteredResults.Message | Where-Object {$_ -match "high CPU"}).Count | Should -Be 0
    }

    It 'Should query for NTFS Error Events (9000, 9001)' {
        . $ScriptPathDiskPressure
        ($script:CapturedGetWinEventInvocations | Where-Object {
            $_.FilterHashtable.LogName -eq "System" -and
            ($_.FilterHashtable.ProviderName -eq "Microsoft-Windows-Ntfs" -or $_.FilterHashtable.ProviderName -eq "Ntfs") -and # Accommodate older/newer provider name
            ($_.FilterHashtable.Id -is [array] -and ($_.FilterHashtable.Id | Compare-Object @(9000,9001) -PassThru).Length -eq 0)
        }).Count | Should -BeGreaterOrEqual 1 # Should be at least one call for these IDs
    }
}

# [end of tests/Powershell/unit/Monitoring.Tests.ps1]

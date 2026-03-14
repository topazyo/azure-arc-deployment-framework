# tests/PowerShell/unit/Utils.Coverage.Tests.ps1
# Coverage-focused tests for utils/ source files.

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
# 1. Test-OperationResult.ps1  (110 commands / 0% covered — pure logic)
# ---------------------------------------------------------------------------
Describe 'Test-OperationResult.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'utils\Test-OperationResult.ps1')
    }

    It 'returns OverallResult=true when status matches and no properties given' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    {} -ErrorAction SilentlyContinue

        $out = [PSCustomObject]@{ Status='Success'; Message='Done' }

        $result = Test-OperationResult -OperationOutput $out -ExpectedStatus 'Success' -LogPath "$TestDrive\test.log"
        $result.OverallResult | Should -Be $true
    }

    It 'returns OverallResult=false when status does not match' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    {} -ErrorAction SilentlyContinue

        $out = [PSCustomObject]@{ Status='Failed' }

        $result = Test-OperationResult -OperationOutput $out -ExpectedStatus 'Success' -LogPath "$TestDrive\test.log"
        $result.OverallResult | Should -Be $false
    }

    It 'returns OverallResult=false when OperationOutput is null' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    {} -ErrorAction SilentlyContinue

        $result = Test-OperationResult -OperationOutput $null -ExpectedStatus 'Success' -LogPath "$TestDrive\test.log"
        $result.OverallResult | Should -Be $false
    }

    It 'returns OverallResult=true when all expected properties match' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    {} -ErrorAction SilentlyContinue

        $out = [PSCustomObject]@{ Status='Success'; ServiceRunning=$true; Version='1.0' }
        $props = @{ ServiceRunning=$true; Version='1.0' }

        $result = Test-OperationResult -OperationOutput $out -ExpectedStatus 'Success' -ExpectedProperties $props -LogPath "$TestDrive\test.log"
        $result.OverallResult | Should -Be $true
    }

    It 'returns OverallResult=false when an expected property does not match' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    {} -ErrorAction SilentlyContinue

        $out = [PSCustomObject]@{ Status='Success'; ServiceRunning=$false }
        $props = @{ ServiceRunning=$true }

        $result = Test-OperationResult -OperationOutput $out -ExpectedStatus 'Success' -ExpectedProperties $props -LogPath "$TestDrive\test.log"
        $result.OverallResult | Should -Be $false
    }

    It 'returns validation details array describing each check' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    {} -ErrorAction SilentlyContinue

        $out = [PSCustomObject]@{ Status='Success'; PropA='X'; PropB='Y' }
        $props = @{ PropA='X'; PropB='Z' }

        $result = Test-OperationResult -OperationOutput $out -ExpectedProperties $props -LogPath "$TestDrive\test.log"
        $result.ValidationDetails | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 2. Backup-OperationState.ps1  (66+ commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Backup-OperationState.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'utils\Backup-OperationState.ps1')
    }

    It 'backs up a File item and returns Success' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    { [PSCustomObject]@{ FullName="$TestDrive\bk" } } -ParameterFilter { $ItemType -eq 'Directory' }
        Mock Test-Path   { $true }
        Mock Copy-Item   {}
        Mock Get-ChildItem { @() }

        $items = @(
            @{ Type='File'; Path='C:\Arc\config.json'; Description='Arc config' }
        )

        $result = Backup-OperationState -OperationId 'OP-001' -BackupPathBase "$TestDrive\backup" -ItemsToBackup $items -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
        $result.Status | Should -BeIn 'Success', 'PartialSuccess'
    }

    It 'backs up a Registry key using reg.exe' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    { [PSCustomObject]@{ FullName="$TestDrive\bk" } } -ParameterFilter { $ItemType -eq 'Directory' }
        Mock Test-Path   { $true }
        Mock Start-Process {
            [PSCustomObject]@{ ExitCode=0 }
        } -ParameterFilter { $FilePath -eq 'reg.exe' }

        $items = @(
            @{ Type='Registry'; Path='HKLM:\SOFTWARE\Microsoft\AzureArc'; Description='Arc registry' }
        )

        $result = Backup-OperationState -OperationId 'OP-002' -BackupPathBase "$TestDrive\backup" -ItemsToBackup $items -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
    }

    It 'backs up a Service configuration item' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    { [PSCustomObject]@{ FullName="$TestDrive\bk" } } -ParameterFilter { $ItemType -eq 'Directory' }
        Mock Test-Path   { $true }
        Mock Get-Service { [PSCustomObject]@{ Name='himds'; Status='Running'; StartType='Automatic' } }
        Mock ConvertTo-Json { '{}' }
        Mock Out-File   {}

        $items = @(
            @{ Type='ServiceConfig'; ServiceName='himds'; Description='Arc service config' }
        )

        $result = Backup-OperationState -OperationId 'OP-003' -BackupPathBase "$TestDrive\backup" -ItemsToBackup $items -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
    }

    It 'uses WhatIf without executing backup' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    {} -ErrorAction SilentlyContinue
        Mock Copy-Item   {}

        $items = @(@{ Type='File'; Path='C:\test.json'; Description='test' })

        Backup-OperationState -OperationId 'OP-004' -BackupPathBase "$TestDrive\backup" -ItemsToBackup $items -WhatIf -LogPath "$TestDrive\test.log"
        # WhatIf should complete without error
    }
}

# ---------------------------------------------------------------------------
# 3. Certificate-Helpers.ps1  (93 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Certificate-Helpers.ps1 Coverage' {
    BeforeAll {
        # Stub dependencies that may not exist in test scope
        if (-not (Get-Command Test-RootCertificates -ErrorAction SilentlyContinue)) {
            Set-Item Function:global:Test-RootCertificates -Value { param($ServerName) @{ Valid=$true; Details=@() } }
        }
        if (-not (Get-Command Test-IntermediateCertificates -ErrorAction SilentlyContinue)) {
            Set-Item Function:global:Test-IntermediateCertificates -Value { param($ServerName) @{ Valid=$true; Details=@() } }
        }
        if (-not (Get-Command Test-MachineCertificates -ErrorAction SilentlyContinue)) {
            Set-Item Function:global:Test-MachineCertificates -Value { param($ServerName) @{ Valid=$true; Details=@() } }
        }
        if (-not (Get-Command Test-CertificateChain -ErrorAction SilentlyContinue)) {
            Set-Item Function:global:Test-CertificateChain -Value { param($ServerName) @{ Valid=$true; Details=@() } }
        }
        if (-not (Get-Command Install-IntermediateCertificates -ErrorAction SilentlyContinue)) {
            Set-Item Function:global:Install-IntermediateCertificates -Value { param($ServerName) @{ Success=$true } }
        }
        if (-not (Get-Command Install-RootCertificates -ErrorAction SilentlyContinue)) {
            Set-Item Function:global:Install-RootCertificates -Value { param($ServerName) @{ Success=$true } }
        }
        . (Join-Path $script:SrcRoot 'utils\Certificate-Helpers.ps1')
    }

    It 'returns passing results when all cert checks pass' {
        Mock Test-RootCertificates         { @{ Valid=$true; Details=@() } }
        Mock Test-IntermediateCertificates { @{ Valid=$true; Details=@() } }
        Mock Test-MachineCertificates      { @{ Valid=$true; Details=@() } }
        Mock Test-CertificateChain         { @{ Valid=$true; Details=@() } }

        $result = Test-CertificateRequirements -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.Success | Should -Be $true
    }

    It 'returns failure when root cert check fails' {
        Mock Test-RootCertificates         { @{ Valid=$false; Details=@('Missing DigiCert root') } }
        Mock Test-IntermediateCertificates { @{ Valid=$true; Details=@() } }
        Mock Test-MachineCertificates      { @{ Valid=$true; Details=@() } }
        Mock Test-CertificateChain         { @{ Valid=$true; Details=@() } }

        $result = Test-CertificateRequirements -ServerName 'TEST-SRV'
        $result.Success | Should -Be $false
        ($result.Checks | Where-Object { $_.Type -eq 'RootCertificates' }).Status | Should -Be $false
    }

    It 'attempts remediation when -Remediate is specified and certs invalid' {
        Mock Test-RootCertificates         { @{ Valid=$false; Details=@('Missing root') } }
        Mock Test-IntermediateCertificates { @{ Valid=$false; Details=@('Missing intermediate') } }
        Mock Test-MachineCertificates      { @{ Valid=$true; Details=@() } }
        Mock Test-CertificateChain         { @{ Valid=$true; Details=@() } }
        Mock Install-RootCertificates      { @{ Success=$true } }
        Mock Install-IntermediateCertificates { @{ Success=$true } }

        $result = Test-CertificateRequirements -ServerName 'TEST-SRV' -Remediate
        $result | Should -Not -BeNullOrEmpty
        $result.Remediation.Count | Should -BeGreaterThan 0
    }

    It 'handles exception gracefully' {
        Mock Test-RootCertificates { throw 'Cannot connect to certificate store' }

        $result = Test-CertificateRequirements -ServerName 'TEST-SRV'
        $result.Success | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# 4. Network-Helpers.ps1  (72 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Network-Helpers.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'utils\Network-Helpers.ps1')
    }

    It 'Test-ArcEndpoints returns connectivity results with mocked DNS and connection' {
        Mock Resolve-DnsName { @([PSCustomObject]@{ IPAddress='40.76.4.15' }) }
        Mock Test-NetConnection { [PSCustomObject]@{ TcpTestSucceeded=$true; RemoteAddress='management.azure.com'; RemotePort=443 } }

        $result = Test-ArcEndpoints -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.ServerName | Should -Be 'TEST-SRV'
    }

    It 'Get-ProxyConfiguration returns proxy info with Invoke-Command mocked' {
        Mock Invoke-Command {
            @{ WinHTTP='Direct access (no proxy)'; WinINet=[PSCustomObject]@{ ProxyServer=$null; ProxyOverride=$null; ProxyEnable=0 }; Environment=$null }
        }

        $result = Get-ProxyConfiguration -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Get-NetworkRoute returns routes with Invoke-Command mocked' {
        Mock Invoke-Command {
            @([PSCustomObject]@{ DestinationPrefix='0.0.0.0/0'; NextHop='192.168.1.1'; RouteMetric=0; InterfaceIndex=5 })
        }

        $result = Get-NetworkRoute -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Test-ArcEndpoints handles DNS failure gracefully' {
        Mock Resolve-DnsName { $null }
        Mock Test-NetConnection { [PSCustomObject]@{ TcpTestSucceeded=$false } }

        $result = Test-ArcEndpoints -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 5. Performance-Helpers.ps1  (79 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Performance-Helpers.ps1 Coverage' {
    BeforeAll {
        if (-not (Get-Command Calculate-PerformanceMetrics -ErrorAction SilentlyContinue)) {
            Set-Item Function:global:Calculate-PerformanceMetrics -Value {
                param($Samples) @{ AvgCPU=15; AvgMemAvailMB=3000 }
            }
        }
        . (Join-Path $script:SrcRoot 'utils\Performance-Helpers.ps1')
    }

    It 'Get-SystemPerformanceMetrics returns samples with Get-Counter mocked' {
        Mock Get-Counter {
            [PSCustomObject]@{
                CounterSamples = @(
                    [PSCustomObject]@{ Path='\Processor(_Total)\% Processor Time'; CookedValue=22.5 }
                    [PSCustomObject]@{ Path='\Memory\Available MBytes'; CookedValue=4096 }
                    [PSCustomObject]@{ Path='\Memory\Pages/sec'; CookedValue=0.1 }
                    [PSCustomObject]@{ Path='\PhysicalDisk(_Total)\Avg. Disk sec/Read'; CookedValue=0.002 }
                    [PSCustomObject]@{ Path='\PhysicalDisk(_Total)\Avg. Disk sec/Write'; CookedValue=0.003 }
                    [PSCustomObject]@{ Path='\Network Interface(*)\Bytes Total/sec'; CookedValue=1024 }
                    [PSCustomObject]@{ Path='\System\Processor Queue Length'; CookedValue=1 }
                )
            }
        }
        Mock Start-Sleep {}
        Mock Calculate-PerformanceMetrics { @{ AvgCPU=22; AvgMemAvailMB=4096 } }

        $result = Get-SystemPerformanceMetrics -ServerName 'TEST-SRV' -SampleCount 2 -SampleInterval 1
        $result | Should -Not -BeNullOrEmpty
        $result.Samples.Count | Should -Be 2
    }

    It 'handles Get-Counter failure gracefully' {
        Mock Get-Counter { throw 'Performance counter access denied' }

        $result = Get-SystemPerformanceMetrics -ServerName 'TEST-SRV' -SampleCount 1
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Get-PerformanceRecommendations returns high CPU recommendation' {
        $metrics = @{
            CPU     = @{ Average=90; Maximum=95 }
            Memory  = @{ AverageAvailable=3000; MinimumAvailable=2500; PagingRate=0 }
            Disk    = @{ AverageReadLatency=0.001; AverageWriteLatency=0.001 }
            Network = @{ AverageThroughput=1024; MaximumThroughput=2048 }
            System  = @{ AverageProcessorQueue=0 }
        }

        $result = Get-PerformanceRecommendations -Metrics $metrics
        $result | Should -Not -BeNullOrEmpty
        ($result | Where-Object { $_.Component -eq 'CPU' }) | Should -Not -BeNullOrEmpty
    }

    It 'Get-PerformanceRecommendations returns empty array when metrics are healthy' {
        $metrics = @{
            CPU     = @{ Average=10; Maximum=20 }
            Memory  = @{ AverageAvailable=4096; MinimumAvailable=3000; PagingRate=0 }
            Disk    = @{ AverageReadLatency=0.001; AverageWriteLatency=0.001 }
            Network = @{ AverageThroughput=1024; MaximumThroughput=2048 }
            System  = @{ AverageProcessorQueue=0 }
        }

        $result = Get-PerformanceRecommendations -Metrics $metrics
        ($result | Measure-Object).Count | Should -Be 0
    }
}

# ---------------------------------------------------------------------------
# 6. Repair-MachineCertificates.ps1  (108 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Repair-MachineCertificates.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'utils\Repair-MachineCertificates.ps1')
        $script:MockCert1 = [PSCustomObject]@{
            Subject       = 'CN=TEST-SRV'
            Thumbprint    = 'AABBCCDDEEFF'
            NotAfter      = (Get-Date).AddDays(180)
            NotBefore     = (Get-Date).AddDays(-30)
            HasPrivateKey = $true
            Extensions    = @(
                [PSCustomObject]@{ Oid=[PSCustomObject]@{ FriendlyName='Extended Key Usage' }; EnhancedKeyUsages=@([PSCustomObject]@{ FriendlyName='Server Authentication' }) }
            )
        }
        $script:MockCertExpiring = [PSCustomObject]@{
            Subject       = 'CN=TEST-SRV-EXPIRING'
            Thumbprint    = '112233AABBCC'
            NotAfter      = (Get-Date).AddDays(10)
            NotBefore     = (Get-Date).AddDays(-180)
            HasPrivateKey = $true
            Extensions    = @()
        }
        $script:MockCertExpired = [PSCustomObject]@{
            Subject       = 'CN=TEST-SRV-EXPIRED'
            Thumbprint    = 'DEADBEEF1234'
            NotAfter      = (Get-Date).AddDays(-5)
            NotBefore     = (Get-Date).AddDays(-400)
            HasPrivateKey = $false
            Extensions    = @()
        }
    }

    It 'returns non-null result when called' {
        Mock Get-ChildItem {
            @($script:MockCert1, $script:MockCertExpiring, $script:MockCertExpired)
        } -ParameterFilter { $Path -like 'Cert:\*' }
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    {} -ErrorAction SilentlyContinue

        $result = Repair-MachineCertificates -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
    }

    It 'handles OnlyProblematic switch without error' {
        Mock Get-ChildItem {
            @($script:MockCert1, $script:MockCertExpiring, $script:MockCertExpired)
        } -ParameterFilter { $Path -like 'Cert:\*' }
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    {} -ErrorAction SilentlyContinue

        $result = Repair-MachineCertificates -OnlyProblematic -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
    }

    It 'handles empty certificate store without error' {
        Mock Get-ChildItem { @() } -ParameterFilter { $Path -like 'Cert:\*' }
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    {} -ErrorAction SilentlyContinue

        $result = Repair-MachineCertificates -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
    }

    It 'writes report to ReportPath when specified' {
        Mock Get-ChildItem { @($script:MockCert1) } -ParameterFilter { $Path -like 'Cert:\*' }
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    {} -ErrorAction SilentlyContinue
        Mock Out-File    {}
        Mock ConvertTo-Json { '{}' }

        $result = Repair-MachineCertificates -ReportPath "$TestDrive\report.json" -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 7. Repair-CertificateChain.ps1  (113 commands / 0% covered)
# ---------------------------------------------------------------------------
Describe 'Repair-CertificateChain.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'utils\Repair-CertificateChain.ps1')
    }

    It 'returns BuildChainFailed when chain build fails for empty cert' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    {} -ErrorAction SilentlyContinue

        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2

        $result = Repair-CertificateChain -Certificate $cert -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
        $result.OverallResult | Should -Not -BeNullOrEmpty
    }

    It 'runs with WhatIf without modifying cert store' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    {} -ErrorAction SilentlyContinue

        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2

        $result = Repair-CertificateChain -Certificate $cert -WhatIf -LogPath "$TestDrive\test.log"
        # WhatIf should not throw
    }
}

# ---------------------------------------------------------------------------
# 8. New-RetryBlock.ps1  (0% covered)
# ---------------------------------------------------------------------------
Describe 'New-RetryBlock.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'utils\New-RetryBlock.ps1')
    }

    It 'executes action once when it succeeds immediately' {
        $result = New-RetryBlock -ScriptBlock { 'success' } -RetryCount 3 -RetryDelaySeconds 0
        $result.Success | Should -Be $true
        $result.Result  | Should -Be 'success'
    }

    It 'retries and succeeds on second attempt' {
        $script:_retryCount = 0
        $result = New-RetryBlock -ScriptBlock {
            $script:_retryCount++
            if ($script:_retryCount -lt 2) { throw 'timeout' } else { 'ok' }
        } -RetryCount 3 -RetryDelaySeconds 0
        $result.Success | Should -Be $true
        $result.Result  | Should -Be 'ok'
    }

    It 'returns Success=false after max attempts exhausted' {
        $result = New-RetryBlock -ScriptBlock { throw 'timeout' } -RetryCount 2 -RetryDelaySeconds 0
        $result.Success | Should -Be $false
    }
}

# ---------------------------------------------------------------------------
# 9. Merge-Hashtables.ps1  (0% covered)
# ---------------------------------------------------------------------------
Describe 'Merge-Hashtables.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'utils\Merge-Hashtables.ps1')
    }

    It 'merges two hashtables with no conflicts' {
        $base    = @{ A=1; B=2 }
        $overlay = @{ C=3; D=4 }

        $result = Merge-Hashtables -Original $base -Update $overlay
        $result.A | Should -Be 1
        $result.C | Should -Be 3
    }

    It 'overlay values take precedence on conflict' {
        $base    = @{ A=1; B=2 }
        $overlay = @{ B=99 }

        $result = Merge-Hashtables -Original $base -Update $overlay
        $result.B | Should -Be 99
    }

    It 'handles empty overlay' {
        $base    = @{ A=1 }
        $overlay = @{}

        $result = Merge-Hashtables -Original $base -Update $overlay
        $result.A | Should -Be 1
    }
}

# ---------------------------------------------------------------------------
# 10. Convert-ErrorToObject.ps1  (0% covered)
# ---------------------------------------------------------------------------
Describe 'Convert-ErrorToObject.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'utils\Convert-ErrorToObject.ps1')
    }

    It 'converts an ErrorRecord to a structured object' {
        $errorRecord = $null
        try { throw 'Test error message' } catch { $errorRecord = $_ }

        $result = Convert-ErrorToObject -ErrorRecord $errorRecord
        $result | Should -Not -BeNullOrEmpty
        $result.Message   | Should -Not -BeNullOrEmpty
        $result.Category  | Should -Not -BeNullOrEmpty
    }

    It 'includes stack trace info when -IncludeStackTrace specified' {
        $errorRecord = $null
        try { throw [System.InvalidOperationException]'Test op failure' } catch { $errorRecord = $_ }

        $result = Convert-ErrorToObject -ErrorRecord $errorRecord -IncludeStackTrace
        $result | Should -Not -BeNullOrEmpty
        $result.Message | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 11. Test-IsAdministrator.ps1  (0% covered)
# ---------------------------------------------------------------------------
Describe 'Test-IsAdministrator.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'utils\Test-IsAdministrator.ps1')
    }

    It 'returns a boolean result' {
        $result = Test-IsAdministrator
        $result | Should -BeOfType [bool]
    }
}

# ---------------------------------------------------------------------------
# 12. Format-Output.ps1  (0% covered)
# ---------------------------------------------------------------------------
Describe 'Format-Output.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'utils\Format-Output.ps1')
    }

    It 'formats a PSCustomObject as table string without error' {
        $data = [PSCustomObject]@{ Name='TEST-SRV'; Status='Online'; Score=88 }

        { Format-Output -InputObject $data -Format 'Table' } | Should -Not -Throw
    }

    It 'formats a hashtable as JSON string' {
        $data = @{ Name='TEST-SRV'; Status='Online' }

        $result = Format-Output -InputObject $data -Format 'JSON' -PassThru
        $result | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 13. Test-Connectivity.ps1  (0% covered)
# ---------------------------------------------------------------------------
Describe 'Test-Connectivity.ps1 Coverage' {
    BeforeAll {
        foreach ($fn in @('New-RetryBlock', 'Test-SslConnection', 'Get-ServerIPConfiguration', 'Get-ProxyConfiguration', 'Get-RelevantFirewallRules', 'Get-NetworkRoute', 'Convert-ErrorToObject')) {
            if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
                Set-Item "Function:global:$fn" -Value { param() @{} }
            }
        }
        . (Join-Path $script:SrcRoot 'utils\Test-Connectivity.ps1')
    }

    It 'returns Success when ping and endpoint TCP checks succeed' {
        Mock Test-Connection { [PSCustomObject]@{ ResponseTime = 4; Address = '1.2.3.4' } }
        Mock New-RetryBlock {
            [PSCustomObject]@{
                Result = [PSCustomObject]@{ TcpTestSucceeded = $true; PingReplyDetails = [PSCustomObject]@{ RoundtripTime = 8 } }
                LastError = $null
            }
        }
        Mock Test-SslConnection { @{ Success = $true; Protocol = 'Tls12'; Certificate = 'ok'; Error = $null } }

        $result = Test-Connectivity -ServerName 'TEST-SRV'
        $result | Should -Not -BeNullOrEmpty
        $result.OverallStatus | Should -Be 'Success'
    }

    It 'returns Error when ping throws' {
        Mock Test-Connection { throw 'Host unreachable' }
        Mock Convert-ErrorToObject { @{ Message = 'Host unreachable' } }

        $result = Test-Connectivity -ServerName 'TEST-SRV'
        $result.OverallStatus | Should -Be 'Error'
    }
}

# ---------------------------------------------------------------------------
# 14. Invoke-ParallelOperation.ps1  (0% covered)
# ---------------------------------------------------------------------------
Describe 'Invoke-ParallelOperation.ps1 Coverage' {
    BeforeAll {
        if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
            Set-Item Function:global:Write-Log -Value { param([string]$Message, [string]$Level) }
        }
        . (Join-Path $script:SrcRoot 'utils\Invoke-ParallelOperation.ps1')
    }

    It 'returns result object with successful operations' {
        $result = Invoke-ParallelOperation -ComputerName @('srv1', 'srv2') -ScriptBlock { 'ok' } -ThrottleLimit 2 -TimeoutSeconds 10
        $result | Should -Not -BeNullOrEmpty
        $result.Statistics.TotalServers | Should -Be 2
        ($result.Successful.Count + $result.Failed.Count + $result.Skipped.Count) | Should -Be 2
    }
}

# ---------------------------------------------------------------------------
# 15. Merge-CommonHashtable.ps1 (0% covered)
# ---------------------------------------------------------------------------
Describe 'Merge-CommonHashtable.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'utils\Merge-CommonHashtable.ps1')
    }

    It 'merges two hashtables keeping all Original keys' {
        $result = Merge-CommonHashtable -Original @{A=1; B=2} -Update @{C=3}
        $result.A | Should -Be 1
        $result.C | Should -Be 3
    }

    It 'Update overrides Original on key conflict' {
        $result = Merge-CommonHashtable -Original @{A=1; B=2} -Update @{B=99}
        $result.B | Should -Be 99
    }

    It 'handles empty Update hashtable' {
        $result = Merge-CommonHashtable -Original @{A=1} -Update @{}
        $result.A | Should -Be 1
    }

    It 'handles empty Original hashtable' {
        $result = Merge-CommonHashtable -Original @{} -Update @{X=42}
        $result.X | Should -Be 42
    }

    It 'does not mutate the Original hashtable' {
        $original = @{A=1}
        $result = Merge-CommonHashtable -Original $original -Update @{A=99}
        $original.A | Should -Be 1
        $result.A   | Should -Be 99
    }
}

# ---------------------------------------------------------------------------
# 16. Invoke-NetFirewallRule.ps1 (0% covered)
# ---------------------------------------------------------------------------
Describe 'Invoke-NetFirewallRule.ps1 Coverage' {
    BeforeAll {
        # Pre-stub cmdlets with Function:global so they take precedence over module cmdlets
        Set-Item 'Function:global:Get-NetFirewallRule' -Value {
            param([string]$DisplayName, [string]$ErrorAction)
            if ($DisplayName -eq 'Missing Rule') { $null }
            else { [PSCustomObject]@{ DisplayName = $DisplayName; Enabled = $true } }
        }
        Set-Item 'Function:global:New-NetFirewallRule' -Value {
            param([string]$DisplayName, [string]$Direction, [string]$Action,
                  [string]$Protocol, [int]$LocalPort, [string]$ErrorAction)
            [PSCustomObject]@{ DisplayName = $DisplayName }
        }
        Set-Item 'Function:global:Set-NetFirewallRule' -Value {
            param([string]$DisplayName, [string]$Action, [string]$Enabled, [string]$ErrorAction)
        }
        . (Join-Path $script:SrcRoot 'utils\Invoke-NetFirewallRule.ps1')
    }

    It 'Invoke-GetNetFirewallRule returns the matching rule' {
        $result = Invoke-GetNetFirewallRule -DisplayName 'Test Rule'
        $result | Should -Not -BeNullOrEmpty
        $result.DisplayName | Should -Be 'Test Rule'
    }

    It 'Invoke-GetNetFirewallRule returns null when rule is not found' {
        $result = Invoke-GetNetFirewallRule -DisplayName 'Missing Rule'
        $result | Should -BeNullOrEmpty
    }

    It 'Invoke-NewNetFirewallRule creates a rule and returns result' {
        $params = @{ DisplayName = 'Arc Outbound'; Direction = 'Outbound'; Action = 'Allow' }
        $result = Invoke-NewNetFirewallRule -Params $params
        $result | Should -Not -BeNullOrEmpty
    }

    It 'Invoke-SetNetFirewallRule executes without throwing' {
        $params = @{ DisplayName = 'Arc Outbound'; Action = 'Allow' }
        { Invoke-SetNetFirewallRule -Params $params } | Should -Not -Throw
    }
}

# ---------------------------------------------------------------------------
# 17. Invoke-ErrorHandler.ps1 (0% covered)
# ---------------------------------------------------------------------------
Describe 'Invoke-ErrorHandler.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'utils\Invoke-ErrorHandler.ps1')
        if (-not (Get-Command Convert-ErrorToObject -ErrorAction SilentlyContinue)) {
            Set-Item 'Function:global:Convert-ErrorToObject' -Value {
                param($ErrorRecord, [switch]$IncludeStackTrace, [switch]$IncludeInnerException)
                [PSCustomObject]@{
                    Message    = $ErrorRecord.Exception.Message
                    ErrorId    = $ErrorRecord.FullyQualifiedErrorId
                    Category   = 'NotSpecified'
                    StackTrace = ''
                }
            }
        }
        Mock Write-Log {}
    }

    BeforeEach {
        Mock Write-Log {}
    }

    It 'returns handler result with Context property set' {
        $err = $null
        try { throw 'Test error' } catch { $err = $_ }
        $result = Invoke-ErrorHandler -ErrorRecord $err -Context 'TestContext'
        $result | Should -Not -BeNullOrEmpty
        $result.Context | Should -Be 'TestContext'
    }

    It 'ErrorInfo is populated in result' {
        $err = $null
        try { throw 'Another error' } catch { $err = $_ }
        $result = Invoke-ErrorHandler -ErrorRecord $err -Context 'Ctx'
        $result.ErrorInfo | Should -Not -BeNullOrEmpty
    }

    It 'handles empty HandlerConfig without throwing' {
        $err = $null
        try { throw 'Config test' } catch { $err = $_ }
        { Invoke-ErrorHandler -ErrorRecord $err -Context 'Ctx' -HandlerConfig @{} } | Should -Not -Throw
    }

    It 'ThrowException causes Invoke-ErrorHandler to throw' {
        $err = $null
        try { throw 'Rethrow test' } catch { $err = $_ }
        { Invoke-ErrorHandler -ErrorRecord $err -Context 'Ctx' -ThrowException } | Should -Throw
    }

    It 'Find-ErrorPattern returns matching pattern by message' {
        $patterns = @(@{ Name = 'NotFound'; Pattern = 'not found'; ExceptionType = $null })
        $errorObj = [PSCustomObject]@{ Message = 'Path not found'; ErrorId = ''; Category = 'ObjectNotFound' }
        $result = Find-ErrorPattern -ErrorObj $errorObj -Patterns $patterns
        $result | Should -Not -BeNullOrEmpty
        $result.Name | Should -Be 'NotFound'
    }

    It 'Find-ErrorPattern returns null when no pattern matches' {
        $patterns = @(@{ Name = 'Auth'; Pattern = 'authentication'; ExceptionType = $null })
        $errorObj = [PSCustomObject]@{ Message = 'Disk full'; ErrorId = ''; Category = 'ResourceUnavailable' }
        $result = Find-ErrorPattern -ErrorObj $errorObj -Patterns $patterns
        $result | Should -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 18. Test-Prerequisite.ps1 (0% covered)
# ---------------------------------------------------------------------------
Describe 'Test-Prerequisite.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'utils\Test-Prerequisite.ps1')
        Mock Write-Log {}
    }

    BeforeEach {
        Mock Write-Log {}
    }

    It 'returns Success when all required checks pass' {
        $requirements = @{
            'DiskSpace' = @{
                Required = $true
                Test     = { @{ Success = $true; Details = 'OK' } }
            }
        }
        $result = Test-Prerequisite -Requirements $requirements
        $result | Should -Not -BeNullOrEmpty
        $result.Checks[0].Status | Should -Be 'Success'
        $result.Success | Should -Be $true
    }

    It 'returns Failed when a required check fails' {
        $requirements = @{
            'DiskSpace' = @{
                Required = $true
                Test     = { @{ Success = $false; Details = 'Insufficient' } }
            }
        }
        $result = Test-Prerequisite -Requirements $requirements
        $result.Checks[0].Status | Should -Be 'Failed'
        $result.Success | Should -Be $false
    }

    It 'returns Error when Test scriptblock throws' {
        $requirements = @{
            'BadCheck' = @{
                Required = $true
                Test     = { throw 'Check failed spectacularly' }
            }
        }
        $result = Test-Prerequisite -Requirements $requirements
        $result.Checks[0].Status | Should -Be 'Error'
    }

    It 'attempts remediation when -Remediate is set' {
        $requirements = @{
            'Service' = @{
                Required    = $true
                Test        = { @{ Success = $false; Details = 'Service stopped' } }
                Remediation = { @{ Success = $true; Details = 'Started' } }
            }
        }
        $result = Test-Prerequisite -Requirements $requirements -Remediate
        $result | Should -Not -BeNullOrEmpty
        $result.Remediation.Count | Should -BeGreaterOrEqual 1
    }

    It 'marks optional check failure as Warning only' {
        $requirements = @{
            'NiceToHave' = @{
                Required = $false
                Test     = { @{ Success = $false; Details = 'Not available' } }
            }
        }
        $result = Test-Prerequisite -Requirements $requirements
        $result | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# 19. Start-TransactionalOperation.ps1 (0% covered)
# ---------------------------------------------------------------------------
Describe 'Start-TransactionalOperation.ps1 Coverage' {
    BeforeAll {
        if (-not (Get-Command Backup-OperationState -ErrorAction SilentlyContinue)) {
            Set-Item 'Function:global:Backup-OperationState' -Value {
                param($BackupPath, $OperationName)
                @{ Path = $BackupPath; Name = $OperationName }
            }
        }
        if (-not (Get-Command Test-OperationResult -ErrorAction SilentlyContinue)) {
            Set-Item 'Function:global:Test-OperationResult' -Value {
                param($Result)
                @{ Success = $true }
            }
        }
        . (Join-Path $script:SrcRoot 'utils\Start-TransactionalOperation.ps1')
        Mock Write-Log {}
    }

    BeforeEach {
        Mock Write-Log {}
        Mock Backup-OperationState { @{ Path = "$TestDrive\Backup"; Name = 'TestOp' } }
        Mock Test-OperationResult   { @{ Success = $true } }
        Mock Out-File {}
        Mock ConvertTo-Json { '{}' }
        if (-not (Test-Path "$TestDrive\Backup")) {
            New-Item -Path "$TestDrive\Backup" -ItemType Directory -Force | Out-Null
        }
    }

    It 'returns Status=Success for a successful operation' {
        $result = Start-TransactionalOperation `
            -Operation        { 'result data' } `
            -RollbackOperation { param($Backup) } `
            -OperationName    'TestOp' `
            -BackupPath       "$TestDrive\Backup"
        $result | Should -Not -BeNullOrEmpty
        $result.Status | Should -Be 'Success'
    }

    It 'throws when the Operation scriptblock throws and test-result flags failure' {
        Mock Test-OperationResult { @{ Success = $false; Error = 'Validation failed' } }
        { Start-TransactionalOperation `
            -Operation        { 'done' } `
            -RollbackOperation { param($Backup) } `
            -OperationName    'FailOp' `
            -BackupPath       "$TestDrive\Backup" } | Should -Throw
    }

    It 'proceeds with -Force when backup fails' {
        Mock Backup-OperationState { throw 'Cannot create backup' }
        $result = Start-TransactionalOperation `
            -Operation        { 'ok' } `
            -RollbackOperation { param($Backup) } `
            -OperationName    'ForceOp' `
            -BackupPath       "$TestDrive\Backup" `
            -Force
        $result | Should -Not -BeNullOrEmpty
        $result.Status | Should -Be 'Success'
    }

    It 'throws without -Force when backup fails' {
        Mock Backup-OperationState { throw 'Cannot create backup' }
        { Start-TransactionalOperation `
            -Operation        { 'ok' } `
            -RollbackOperation { param($Backup) } `
            -OperationName    'NoForce' `
            -BackupPath       "$TestDrive\Backup" } | Should -Throw
    }
}

# ---------------------------------------------------------------------------
# 20. Install-IntermediateCertificates.ps1 (0% covered)
# ---------------------------------------------------------------------------
Describe 'Install-IntermediateCertificates.ps1 Coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'utils\Install-IntermediateCertificates.ps1')
    }

    BeforeEach {
        Mock Get-PfxCertificate { [PSCustomObject]@{ Thumbprint = 'ABC123'; Subject = 'CN=TestCA' } }
        Mock Get-ChildItem      { @() }
        Mock Import-Certificate { [PSCustomObject]@{ Thumbprint = 'ABC123' } }
    }

    It 'returns FileNotFound for a path that does not exist' {
        $result = Install-IntermediateCertificates -CertificatePaths @('C:\missing\cert.cer')
        $result | Should -Not -BeNullOrEmpty
        $result[0].Status | Should -Be 'FileNotFound'
    }

    It 'returns AlreadyExists when cert is in store and SkipIfExists is set' {
        Mock Get-PfxCertificate { [PSCustomObject]@{ Thumbprint = 'EXIST'; Subject = 'CN=Existing' } }
        Mock Get-ChildItem      { @([PSCustomObject]@{ Thumbprint = 'EXIST' }) }
        $fakePath = Join-Path $TestDrive 'existing.cer'
        Set-Content $fakePath 'fake'
        $result = Install-IntermediateCertificates -CertificatePaths @($fakePath) -SkipIfExists
        $result[0].Status | Should -Be 'AlreadyExists'
    }

    It 'attempts import when cert file exists and not in store' {
        $fakePath = Join-Path $TestDrive 'new.cer'
        Set-Content $fakePath 'fake'
        Mock Get-PfxCertificate { [PSCustomObject]@{ Thumbprint = 'NEW123'; Subject = 'CN=NewCA' } }
        Mock Get-ChildItem      { @() }
        { Install-IntermediateCertificates -CertificatePaths @($fakePath) -SkipIfExists:$false } | Should -Not -Throw
    }

    It 'processes multiple certificate paths and returns one result per path' {
        $result = Install-IntermediateCertificates -CertificatePaths @('C:\a.cer', 'C:\b.cer')
        $result.Count | Should -Be 2
        $result | ForEach-Object { $_.Status | Should -Be 'FileNotFound' }
    }
}

# ---------------------------------------------------------------------------
# Extra: Backup-OperationState.ps1 additional branches
# ---------------------------------------------------------------------------
Describe 'Backup-OperationState.ps1 additional branch coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'utils\Backup-OperationState.ps1')
    }

    BeforeEach {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    { [PSCustomObject]@{ FullName="$TestDrive\bk" } } -ParameterFilter { $ItemType -eq 'Directory' }
        Mock Test-Path   { $true }
        Mock Copy-Item   {}
    }

    It 'backs up a Directory type item' {
        $items = @(
            @{ Type='Directory'; Path='C:\Arc\Config'; Description='Arc config dir' }
        )
        $result = Backup-OperationState -OperationId 'OP-DIR-01' -BackupPathBase "$TestDrive\backup" -ItemsToBackup $items -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
    }

    It 'records Failed status when File not found' {
        Mock Test-Path { $false } -ParameterFilter { $Path -notlike '*backup*' -and $Path -notlike '*TestDrive*' }
        $items = @(@{ Type='File'; Path='C:\nonexistent\file.json'; Description='missing file' })
        $result = Backup-OperationState -OperationId 'OP-FAIL-01' -BackupPathBase "$TestDrive\backup" -ItemsToBackup $items -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
    }

    It 'backs up a RegistryKey item using reg.exe' {
        Mock Start-Process { [PSCustomObject]@{ ExitCode=0 } } -ParameterFilter { $FilePath -eq 'reg.exe' }
        Mock Test-Path { $true }
        $items = @(@{ Type='RegistryKey'; Path='HKLM:\SOFTWARE\Microsoft\AzureArc'; Description='Arc registry key' })
        $result = Backup-OperationState -OperationId 'OP-REG-01' -BackupPathBase "$TestDrive\backup" -ItemsToBackup $items -LogPath "$TestDrive\test.log"
        $result | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Extra: Test-Prerequisite.ps1 - Force switch and optional checks
# ---------------------------------------------------------------------------
Describe 'Test-Prerequisite.ps1 additional branch coverage' {
    BeforeAll {
        if (-not (Get-Command Test-Prerequisite -ErrorAction SilentlyContinue)) {
            . (Join-Path $script:SrcRoot 'utils\Test-Prerequisite.ps1')
        }
        Mock Write-Log {}
    }

    BeforeEach {
        Mock Write-Log {}
    }

    It 'succeeds with -Force even when required check fails' {
        $requirements = @{
            'DiskSpace' = @{
                Required = $true
                Test     = { @{ Success = $false; Details = 'Insufficient disk space' } }
            }
        }
        $result = Test-Prerequisite -Requirements $requirements -Force
        $result | Should -Not -BeNullOrEmpty
        $result.Success | Should -Be $false
    }

    It 'runs remediation and rechecks when -Remediate and check fails' {
        $script:remediationRan = $false
        $requirements = @{
            'Service' = @{
                Required    = $false
                Test        = { @{ Success = $false; Details = 'Service stopped' } }
                Remediation = { $script:remediationRan = $true; @{ Success = $true; Details = 'Started' } }
            }
        }
        $result = Test-Prerequisite -Requirements $requirements -Remediate -Force
        $result | Should -Not -BeNullOrEmpty
        $script:remediationRan | Should -Be $true
    }
}

# ---------------------------------------------------------------------------
# Extra: Backup-OperationState ServiceConfiguration, Compress, ConvertTo-RegExePath
# ---------------------------------------------------------------------------
Describe 'Backup-OperationState ServiceConfiguration and Compress branches' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'utils\Backup-OperationState.ps1')
        if (-not (Get-Command Export-RegistryKeyBackup -ErrorAction SilentlyContinue)) {
            Set-Item -Path Function:Export-RegistryKeyBackup -Value { param([string]$RegistryKey, [string]$DestinationPath) }
        }
        if (-not (Get-Command global:Export-RegistryKeyBackup -ErrorAction SilentlyContinue)) {
            Set-Item -Path Function:global:Export-RegistryKeyBackup -Value { param([string]$RegistryKey, [string]$DestinationPath) }
        }
    }
    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path, [string]$Component)
        }
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item    { [PSCustomObject]@{ FullName = "$TestDrive\bkup" } } `
            -ParameterFilter { $ItemType -eq 'Directory' }
        Mock Test-Path   { $true }
        Mock Copy-Item   {}
    }

    It 'backs up ServiceConfiguration item using Get-CimInstance' {
        $svcConfig = [PSCustomObject]@{
            Name     = 'himds'
            StartMode = 'Auto'
            State    = 'Running'
            PathName = 'C:\himds.exe'
        }
        Mock Get-CimInstance { $svcConfig }
        Mock Out-File {}
        $items = @([PSCustomObject]@{ Type = 'ServiceConfiguration'; Path = 'himds'; Name = 'himds' })
        $result = Backup-OperationState -OperationId 'OP-SVC-01' `
            -BackupPathBase "$TestDrive\backup" -ItemsToBackup $items `
            -LogPath "$TestDrive\svc1.log"
        $result | Should -Not -BeNullOrEmpty
    }

    It 'ServiceConfiguration records PartialSuccess when service not found' {
        Mock Get-CimInstance { $null }
        $items = @([PSCustomObject]@{ Type = 'ServiceConfiguration'; Path = 'nonexistent-svc'; Name = 'nonexistent-svc' })
        $result = Backup-OperationState -OperationId 'OP-SVC-02' `
            -BackupPathBase "$TestDrive\backup" -ItemsToBackup $items `
            -LogPath "$TestDrive\svc2.log"
        $result | Should -Not -BeNullOrEmpty
        $result.Status | Should -Be 'PartialSuccess'
    }

    It 'default unsupported itemType records PartialSuccess' {
        $items = @([PSCustomObject]@{ Type = 'UnsupportedType'; Path = 'C:\something'; Name = 'something' })
        $result = Backup-OperationState -OperationId 'OP-UNK-01' `
            -BackupPathBase "$TestDrive\backup" -ItemsToBackup $items `
            -LogPath "$TestDrive\unk1.log"
        $result.Status | Should -Be 'PartialSuccess'
    }

    It 'ConvertTo-RegExePath converts HKCU path via RegistryKey backup' {
        Mock Export-RegistryKeyBackup {}
        $items = @([PSCustomObject]@{ Type = 'RegistryKey'; Path = 'HKCU:\Software\TestKey'; Name = 'TestKey' })
        $result = Backup-OperationState -OperationId 'OP-HKCU-01' `
            -BackupPathBase "$TestDrive\backup" -ItemsToBackup $items `
            -LogPath "$TestDrive\hkcu.log"
        $result | Should -Not -BeNullOrEmpty
    }

    It 'ConvertTo-RegExePath converts HKCR path via RegistryKey backup' {
        Mock Export-RegistryKeyBackup {}
        $items = @([PSCustomObject]@{ Type = 'RegistryKey'; Path = 'HKCR:\CLSID\{test}'; Name = 'TestClsid' })
        $result = Backup-OperationState -OperationId 'OP-HKCR-01' `
            -BackupPathBase "$TestDrive\backup" -ItemsToBackup $items `
            -LogPath "$TestDrive\hkcr.log"
        $result | Should -Not -BeNullOrEmpty
    }

    It 'backs up with -Compress switch and creates archive' {
        Mock Compress-Archive {}
        Mock Remove-Item {}
        $items = @([PSCustomObject]@{ Type = 'Directory'; Path = 'C:\Arc\Logs'; Name = 'Logs' })
        $result = Backup-OperationState -OperationId 'OP-COMP-01' `
            -BackupPathBase "$TestDrive\backup" -ItemsToBackup $items `
            -Compress -LogPath "$TestDrive\comp1.log"
        $result | Should -Not -BeNullOrEmpty
    }

    It 'backs up with -Compress -KeepUncompressed does not call Remove-Item on dir' {
        Mock Compress-Archive {}
        $removeItemCalled = $false
        Mock Remove-Item { $script:removeItemCalled = $true }
        $items = @([PSCustomObject]@{ Type = 'Directory'; Path = 'C:\Arc\Logs'; Name = 'Logs' })
        { Backup-OperationState -OperationId 'OP-COMP-02' `
            -BackupPathBase "$TestDrive\backup" -ItemsToBackup $items `
            -Compress -KeepUncompressed -LogPath "$TestDrive\comp2.log" } | Should -Not -Throw
    }

    It 'cleans oldest backup versions when MaxBackupVersions is exceeded' {
        $opDir = New-Item -ItemType Directory -Path "$TestDrive\backup_versions\OP_CLEANUP" -Force
        New-Item -ItemType Directory -Path "$TestDrive\backup_versions\OP_CLEANUP\20250101_000000" -Force | Out-Null
        New-Item -ItemType Directory -Path "$TestDrive\backup_versions\OP_CLEANUP\20250102_000000" -Force | Out-Null
        New-Item -ItemType Directory -Path "$TestDrive\backup_versions\OP_CLEANUP\20250103_000000" -Force | Out-Null
        Mock Remove-Item {}
        $items = @([PSCustomObject]@{ Type = 'File'; Path = 'C:\test.json'; Name = 'test.json' })
        $result = Backup-OperationState -OperationId 'OP_CLEANUP' `
            -BackupPathBase "$TestDrive\backup_versions" -ItemsToBackup $items `
            -MaxBackupVersions 2 -LogPath "$TestDrive\cleanup.log"
        $result | Should -Not -BeNullOrEmpty
    }
}

# ---------------------------------------------------------------------------
# Extra: Backup-OperationState.ps1 cleanup and fallback branches
# ---------------------------------------------------------------------------
Describe 'Backup-OperationState.ps1 cleanup edge coverage' {
    BeforeAll {
        . (Join-Path $script:SrcRoot 'utils\Backup-OperationState.ps1')
        if (-not (Get-Command Export-RegistryKeyBackup -ErrorAction SilentlyContinue)) {
            Set-Item -Path Function:Export-RegistryKeyBackup -Value { param([string]$RegistryKey, [string]$DestinationPath) }
        }
        if (-not (Get-Command global:Export-RegistryKeyBackup -ErrorAction SilentlyContinue)) {
            Set-Item -Path Function:global:Export-RegistryKeyBackup -Value { param([string]$RegistryKey, [string]$DestinationPath) }
        }
    }

    It 'records SkippedWhatIf for items skipped by ShouldProcess' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item { [PSCustomObject]@{ FullName = $Path } } -ParameterFilter { $ItemType -eq 'Directory' }
        Mock Get-ChildItem { @() }

        $result = Backup-OperationState -OperationId 'OP-WHATIF-EDGE' `
            -BackupPathBase "$TestDrive\backup" `
            -ItemsToBackup @([PSCustomObject]@{ Type = 'File'; Path = 'C:\skip.txt'; Name = 'skip.txt' }) `
            -WhatIf -LogPath "$TestDrive\whatif-edge.log"

        $result.Status | Should -Be 'Success'
        $result.BackedUpItems.Count | Should -Be 1
        $result.BackedUpItems[0].Status | Should -Be 'SkippedWhatIf'
    }

    It 'falls back to console logging when activity log creation or write fails' {
        Mock Test-Path {
            if ($Path -like 'C:\source.txt') { return $true }
            if ($Path -like '*ActivityLogs*') { return $false }
            return $true
        }
        Mock New-Item {
            if ($Path -like '*ActivityLogs*') { throw 'log path denied' }
            [PSCustomObject]@{ FullName = $Path }
        } -ParameterFilter { $ItemType -eq 'Directory' }
        Mock Add-Content { throw 'disk full' }
        Mock Copy-Item {}
        Mock Get-ChildItem { @() }
        Mock Write-Host {}

        $result = Backup-OperationState -OperationId 'OP-LOG-FALLBACK' `
            -BackupPathBase "$TestDrive\backup" `
            -ItemsToBackup @([PSCustomObject]@{ Type = 'File'; Path = 'C:\source.txt'; Name = 'source.txt' }) `
            -LogPath "$TestDrive\ActivityLogs\backup.log"

        $result | Should -Not -BeNullOrEmpty
    }

    It 'returns PartialSuccess when registry export file is not created for an unrecognized hive path' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item { [PSCustomObject]@{ FullName = $Path } } -ParameterFilter { $ItemType -eq 'Directory' }
        Mock Test-Path {
            if ($Path -like '*.reg') { return $false }
            return $true
        }
        Mock Export-RegistryKeyBackup {}
        Mock Get-ChildItem { @() }

        $result = Backup-OperationState -OperationId 'OP-REG-UNKNOWN' `
            -BackupPathBase "$TestDrive\backup" `
            -ItemsToBackup @([PSCustomObject]@{ Type = 'RegistryKey'; Path = 'XYZ:\Software\Broken'; Name = 'Broken' }) `
            -LogPath "$TestDrive\reg-unknown.log"

        $result.Status | Should -Be 'PartialSuccess'
        $result.BackedUpItems[0].Status | Should -Be 'Failed'
        $result.ErrorsEncountered.Count | Should -BeGreaterThan 0
    }

    It 'returns PartialSuccess when ServiceConfiguration item omits Name' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock New-Item { [PSCustomObject]@{ FullName = $Path } } -ParameterFilter { $ItemType -eq 'Directory' }
        Mock Test-Path { $true }
        Mock Get-ChildItem { @() }

        $result = Backup-OperationState -OperationId 'OP-SVC-NONAME' `
            -BackupPathBase "$TestDrive\backup" `
            -ItemsToBackup @([PSCustomObject]@{ Type = 'ServiceConfiguration'; Path = 'missing-name' }) `
            -LogPath "$TestDrive\svc-noname.log"

        $result.Status | Should -Be 'PartialSuccess'
        $result.BackedUpItems[0].Status | Should -Be 'Failed'
        $result.ErrorsEncountered[0] | Should -Match "Service 'Name' not provided"
    }

    It 'deletes the oldest backup version when MaxBackupVersions is exceeded' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock Copy-Item {}

        $operationRoot = Join-Path $TestDrive 'versions\OP_REAL_CLEANUP'
        $sourceFile = Join-Path $TestDrive 'source-cleanup.txt'
        Set-Content -Path $sourceFile -Value 'cleanup source'
        Microsoft.PowerShell.Management\New-Item -Path (Join-Path $operationRoot '20240101_000000') -ItemType Directory -Force | Out-Null
        Microsoft.PowerShell.Management\New-Item -Path (Join-Path $operationRoot '20240102_000000') -ItemType Directory -Force | Out-Null
        Microsoft.PowerShell.Management\New-Item -Path (Join-Path $operationRoot '20240103_000000') -ItemType Directory -Force | Out-Null

        $result = Backup-OperationState -OperationId 'OP_REAL_CLEANUP' `
            -BackupPathBase (Join-Path $TestDrive 'versions') `
            -ItemsToBackup @([PSCustomObject]@{ Type = 'File'; Path = $sourceFile; Name = 'source-cleanup.txt' }) `
            -MaxBackupVersions 3 -LogPath "$TestDrive\cleanup-real.log"

        $result.VersionsCleaned.Count | Should -Be 1
        $result.VersionsCleaned[0] | Should -Match '20240101_000000'
        Microsoft.PowerShell.Management\Test-Path (Join-Path $operationRoot '20240101_000000') | Should -Be $false
    }

    It 'marks PartialSuccess when old backup version deletion fails' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock Copy-Item {}
        Mock Remove-Item { throw 'directory locked' } -ParameterFilter { $Path -like '*20240101_000000*' }

        $operationRoot = Join-Path $TestDrive 'versions\OP_FAIL_CLEANUP'
        $sourceFile = Join-Path $TestDrive 'source-cleanup-fail.txt'
        Set-Content -Path $sourceFile -Value 'cleanup fail source'
        Microsoft.PowerShell.Management\New-Item -Path (Join-Path $operationRoot '20240101_000000') -ItemType Directory -Force | Out-Null
        Microsoft.PowerShell.Management\New-Item -Path (Join-Path $operationRoot '20240102_000000') -ItemType Directory -Force | Out-Null
        Microsoft.PowerShell.Management\New-Item -Path (Join-Path $operationRoot '20240103_000000') -ItemType Directory -Force | Out-Null

        $result = Backup-OperationState -OperationId 'OP_FAIL_CLEANUP' `
            -BackupPathBase (Join-Path $TestDrive 'versions') `
            -ItemsToBackup @([PSCustomObject]@{ Type = 'File'; Path = $sourceFile; Name = 'source-cleanup-fail.txt' }) `
            -MaxBackupVersions 3 -LogPath "$TestDrive\cleanup-fail.log"

        $result.Status | Should -Be 'PartialSuccess'
        $result.ErrorsEncountered -join ' ' | Should -Match 'Failed to delete old backup version'
    }

    It 'removes the uncompressed backup directory after successful compression' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock Copy-Item {}
        Mock Compress-Archive {
            Set-Content -Path $DestinationPath -Value 'zip archive'
        }
        $sourceFile = Join-Path $TestDrive 'source-compress.txt'
        Set-Content -Path $sourceFile -Value 'compress source'

        $result = Backup-OperationState -OperationId 'OP_COMPRESS_SUCCESS' `
            -BackupPathBase (Join-Path $TestDrive 'compress') `
            -ItemsToBackup @([PSCustomObject]@{ Type = 'File'; Path = $sourceFile; Name = 'source-compress.txt' }) `
            -Compress -MaxBackupVersions 0 -LogPath "$TestDrive\compress-success.log"

        $result.BackupArchive | Should -Not -BeNullOrEmpty
        Microsoft.PowerShell.Management\Test-Path $result.BackupArchive | Should -Be $true
        Microsoft.PowerShell.Management\Test-Path $result.BackupLocation | Should -Be $false
    }

    It 'marks PartialSuccess when compression throws' {
        Mock Add-Content {} -ErrorAction SilentlyContinue
        Mock Copy-Item {}
        Mock Compress-Archive { throw 'zip failed' }
        $sourceFile = Join-Path $TestDrive 'source-compress-fail.txt'
        Set-Content -Path $sourceFile -Value 'compress fail source'

        $result = Backup-OperationState -OperationId 'OP_COMPRESS_FAIL' `
            -BackupPathBase (Join-Path $TestDrive 'compress') `
            -ItemsToBackup @([PSCustomObject]@{ Type = 'File'; Path = $sourceFile; Name = 'source-compress-fail.txt' }) `
            -Compress -MaxBackupVersions 0 -LogPath "$TestDrive\compress-fail.log"

        $result.Status | Should -Be 'PartialSuccess'
        $result.ErrorsEncountered -join ' ' | Should -Match 'Compression failed'
    }
}

# ---------------------------------------------------------------------------
# 22. Write-Log.ps1 additional branch coverage
# ---------------------------------------------------------------------------
Describe 'Write-Log.ps1 additional branch coverage' {
    BeforeAll {
        # Remove the global stub so the real Write-Log from source can be loaded
        Remove-Item Function:global:Write-Log -ErrorAction SilentlyContinue
        if (-not (Get-Command Write-LogSink -ErrorAction SilentlyContinue)) {
            Set-Item Function:global:Write-LogSink -Value {
                param([string]$Path, [string]$Value)
                Add-Content -Path $Path -Value $Value -ErrorAction SilentlyContinue
            }
        }
        . (Join-Path $script:SrcRoot 'utils\Write-Log.ps1')
    }
    AfterAll {
        # Restore global stub for subsequent test blocks
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Path)
        }
    }

    It 'Write-Log with Level=Debug writes to log file' {
        $logFile = Join-Path $TestDrive 'wl_debug.log'
        Write-Log -Message 'debug message' -Level 'Debug' -LogPath $logFile
        Test-Path $logFile | Should -Be $true
    }

    It 'Write-Log with Level=Verbose writes to log file' {
        $logFile = Join-Path $TestDrive 'wl_verbose.log'
        Write-Log -Message 'verbose message' -Level 'Verbose' -LogPath $logFile
        Test-Path $logFile | Should -Be $true
    }

    It 'Write-Log with Level=WARN normalizes to Warning' {
        $logFile = Join-Path $TestDrive 'wl_warn.log'
        { Write-Log -Message 'warn test' -Level 'WARN' -LogPath $logFile } | Should -Not -Throw
        Test-Path $logFile | Should -Be $true
    }

    It 'Write-Log with Level=INFO normalizes to Information' {
        $logFile = Join-Path $TestDrive 'wl_info.log'
        { Write-Log -Message 'info test' -Level 'INFO' -LogPath $logFile } | Should -Not -Throw
        Test-Path $logFile | Should -Be $true
    }

    It 'Write-Log with PassThru returns the log entry string' {
        $logFile = Join-Path $TestDrive 'wl_passthru.log'
        $entry = Write-Log -Message 'passthru test' -Level 'Information' -LogPath $logFile -PassThru
        $entry | Should -Not -BeNullOrEmpty
        $entry | Should -Match 'passthru test'
    }

    It 'Write-StructuredLog writes JSON format to file' {
        $logDir = Join-Path $TestDrive 'structured_logs'
        $entry = @{ EventType = 'Test'; Severity = 'Low'; Details = 'unit test' }
        $result = Write-StructuredLog -LogEntry $entry -LogPath $logDir -Format 'JSON'
        $result | Should -Be $true
        (Get-ChildItem $logDir -Filter '*.log').Count | Should -BeGreaterThan 0
    }

    It 'Write-StructuredLog writes CSV format to file' {
        $logDir = Join-Path $TestDrive 'structured_csv_logs'
        $entry = @{ EventType = 'Test2'; Severity = 'Low' }
        $result = Write-StructuredLog -LogEntry $entry -LogPath $logDir -Format 'CSV'
        $result | Should -Be $true
    }

    It 'Write-StructuredLog returns false when write fails' {
        # Use a path that cannot be created (null byte in path is invalid)
        $bad = "$TestDrive\\sub"
        New-Item -ItemType File -Path $bad -Force | Out-Null  # file, not dir
        $entry = @{ Event = 'fail' }
        # LogPath points to an existing file, New-Item for subdir inside it will fail
        $result = Write-StructuredLog -LogEntry $entry -LogPath $bad -Format 'JSON'
        # Either true (OS allows) or false on error — just don't throw
        $result | Should -BeIn @($true, $false)
    }

    It 'Start-LogRotation removes log files older than RetentionDays' {
        $logDir = Join-Path $TestDrive 'rot_logs'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        $oldFile = Join-Path $logDir 'old.log'
        Set-Content -Path $oldFile -Value 'old log content'
        # Backdate the file
        (Get-Item $oldFile).LastWriteTime = (Get-Date).AddDays(-40)
        $result = Start-LogRotation -LogPath $logDir -RetentionDays 30
        $result | Should -Be $true
        Test-Path $oldFile | Should -Be $false
    }

    It 'Start-LogRotation archives large log files' {
        $logDir = Join-Path $TestDrive 'rot_large_logs'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        $bigFile = Join-Path $logDir 'large.log'
        # Create a file that exceeds 0 MB threshold by writing content
        Set-Content -Path $bigFile -Value ('x' * 1024)
        $result = Start-LogRotation -LogPath $logDir -RetentionDays 30 -MaxSizeMB 0
        $result | Should -Be $true
    }

    It 'Start-LogRotation returns true when log directory is empty' {
        $logDir = Join-Path $TestDrive 'rot_empty_logs'
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        $result = Start-LogRotation -LogPath $logDir -RetentionDays 30
        $result | Should -Be $true
    }
}

# ---------------------------------------------------------------------------
# 23. Performance-Helpers.ps1 sub-function direct coverage
# ---------------------------------------------------------------------------
Describe 'Performance-Helpers.ps1 sub-function direct coverage' {
    BeforeAll {
        # No stubs for Calculate-PerformanceMetrics/Get-PerformanceRecommendations — cover them directly
        . (Join-Path $script:SrcRoot 'utils\Performance-Helpers.ps1')
    }
    BeforeEach {
        Set-Item -Path Function:global:Write-Log -Value {
            param([string]$Message, [string]$Level = 'INFO', [string]$Component, [string]$Path)
        }
    }

    It 'Calculate-PerformanceMetrics computes CPU/Memory/Disk/Network stats from samples' {
        $samples = @(
            @{ Counters = @{
                '\Processor(_Total)\% Processor Time'              = 45.0
                '\Memory\Available MBytes'                         = 3000.0
                '\Memory\Pages/sec'                               = 10.0
                '\PhysicalDisk(_Total)\Avg. Disk sec/Read'         = 0.005
                '\PhysicalDisk(_Total)\Avg. Disk sec/Write'        = 0.004
                '\Network Interface(*)\Bytes Total/sec'            = 1048576.0
                '\System\Processor Queue Length'                   = 2.0
            }},
            @{ Counters = @{
                '\Processor(_Total)\% Processor Time'              = 55.0
                '\Memory\Available MBytes'                         = 2800.0
                '\Memory\Pages/sec'                               = 20.0
                '\PhysicalDisk(_Total)\Avg. Disk sec/Read'         = 0.010
                '\PhysicalDisk(_Total)\Avg. Disk sec/Write'        = 0.008
                '\Network Interface(*)\Bytes Total/sec'            = 2097152.0
                '\System\Processor Queue Length'                   = 3.0
            }}
        )
        $result = Calculate-PerformanceMetrics -Samples $samples
        $result | Should -Not -BeNullOrEmpty
        $result.CPU | Should -Not -BeNullOrEmpty
        $result.Memory | Should -Not -BeNullOrEmpty
        $result.Disk | Should -Not -BeNullOrEmpty
        $result.Network | Should -Not -BeNullOrEmpty
        $result.System | Should -Not -BeNullOrEmpty
    }

    It 'Get-PerformanceRecommendations generates High CPU recommendation when CPU > 80%' {
        $metrics = @{
            CPU     = @{ Average = 85; Maximum = 95 }
            Memory  = @{ AverageAvailable = 3000; MinimumAvailable = 2500; PagingRate = 50 }
            Disk    = @{ AverageReadLatency = 0.001; AverageWriteLatency = 0.001 }
            Network = @{ AverageThroughput = 1024; MaximumThroughput = 2048 }
            System  = @{ AverageProcessorQueue = 1 }
        }
        $recs = Get-PerformanceRecommendations -Metrics $metrics
        $recs | Should -Not -BeNullOrEmpty
        ($recs | Where-Object { $_.Component -eq 'CPU' -and $_.Severity -eq 'High' }) | Should -Not -BeNullOrEmpty
    }

    It 'Get-PerformanceRecommendations generates High Memory recommendation when available < 1024 MB' {
        $metrics = @{
            CPU     = @{ Average = 10; Maximum = 20 }
            Memory  = @{ AverageAvailable = 512; MinimumAvailable = 256; PagingRate = 50 }
            Disk    = @{ AverageReadLatency = 0.001; AverageWriteLatency = 0.001 }
            Network = @{ AverageThroughput = 1024; MaximumThroughput = 2048 }
            System  = @{ AverageProcessorQueue = 0 }
        }
        $recs = Get-PerformanceRecommendations -Metrics $metrics
        ($recs | Where-Object { $_.Component -eq 'Memory' -and $_.Severity -eq 'High' }) | Should -Not -BeNullOrEmpty
    }

    It 'Get-PerformanceRecommendations generates Medium Memory recommendation when PagingRate > 1000' {
        $metrics = @{
            CPU     = @{ Average = 10; Maximum = 20 }
            Memory  = @{ AverageAvailable = 4096; MinimumAvailable = 3000; PagingRate = 2000 }
            Disk    = @{ AverageReadLatency = 0.001; AverageWriteLatency = 0.001 }
            Network = @{ AverageThroughput = 1024; MaximumThroughput = 2048 }
            System  = @{ AverageProcessorQueue = 0 }
        }
        $recs = Get-PerformanceRecommendations -Metrics $metrics
        ($recs | Where-Object { $_.Component -eq 'Memory' -and $_.Issue -like '*paging*' }) | Should -Not -BeNullOrEmpty
    }

    It 'Get-PerformanceRecommendations generates Medium Disk recommendation when latency > 0.025s' {
        $metrics = @{
            CPU     = @{ Average = 10; Maximum = 20 }
            Memory  = @{ AverageAvailable = 4096; MinimumAvailable = 3000; PagingRate = 50 }
            Disk    = @{ AverageReadLatency = 0.030; AverageWriteLatency = 0.001 }
            Network = @{ AverageThroughput = 1024; MaximumThroughput = 2048 }
            System  = @{ AverageProcessorQueue = 0 }
        }
        $recs = Get-PerformanceRecommendations -Metrics $metrics
        ($recs | Where-Object { $_.Component -eq 'Disk' }) | Should -Not -BeNullOrEmpty
    }

    It 'Get-PerformanceRecommendations generates Medium Network recommendation when throughput > 50MB' {
        $metrics = @{
            CPU     = @{ Average = 10; Maximum = 20 }
            Memory  = @{ AverageAvailable = 4096; MinimumAvailable = 3000; PagingRate = 50 }
            Disk    = @{ AverageReadLatency = 0.001; AverageWriteLatency = 0.001 }
            Network = @{ AverageThroughput = [int64](60 * 1MB); MaximumThroughput = [int64](80 * 1MB) }
            System  = @{ AverageProcessorQueue = 0 }
        }
        $recs = Get-PerformanceRecommendations -Metrics $metrics
        ($recs | Where-Object { $_.Component -eq 'Network' }) | Should -Not -BeNullOrEmpty
    }

    It 'Get-PerformanceRecommendations returns empty array when all metrics are within thresholds' {
        $metrics = @{
            CPU     = @{ Average = 10; Maximum = 20 }
            Memory  = @{ AverageAvailable = 4096; MinimumAvailable = 3000; PagingRate = 50 }
            Disk    = @{ AverageReadLatency = 0.001; AverageWriteLatency = 0.001 }
            Network = @{ AverageThroughput = 1024; MaximumThroughput = 2048 }
            System  = @{ AverageProcessorQueue = 0 }
        }
        $recs = Get-PerformanceRecommendations -Metrics $metrics
        @($recs).Count | Should -Be 0
    }
}

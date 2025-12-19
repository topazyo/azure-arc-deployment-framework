# tests/Powershell/unit/CertificatesAndBackup.Tests.ps1
using namespace System.Management.Automation

Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

Describe 'Install-RootCertificates.ps1' {
    BeforeAll {
        $base = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
        $script:RootScriptPath = [System.IO.Path]::GetFullPath((Join-Path $base '..\..\..\src\Powershell\utils\Install-RootCertificates.ps1'))
        . $script:RootScriptPath
    }

    It 'skips import when thumbprint already exists (SkipIfExists)' {
        $certPath = Join-Path $TestDrive 'existing.cer'
        '' | Set-Content -Path $certPath -Encoding ASCII
        $fakeCert = [pscustomobject]@{ Thumbprint = 'ABC123'; Subject = 'CN=Existing' }

        Mock Get-PfxCertificate { return $fakeCert }
        Mock Get-ChildItem { return @([pscustomobject]@{ Thumbprint = 'ABC123'; Subject = 'CN=Existing' }) }
        Mock Import-Certificate { throw 'Import should be skipped' }

        $result = Install-RootCertificates -CertificatePaths @($certPath) -SkipIfExists

        $result[0].Status | Should -Be 'AlreadyExists'
        Assert-MockCalled Import-Certificate -Times 0
    }

    It 'forces import when requested' {
        $certPath = Join-Path $TestDrive 'force.cer'
        '' | Set-Content -Path $certPath -Encoding ASCII
        $fakeCert = [pscustomobject]@{ Thumbprint = 'FORCE1'; Subject = 'CN=Force' }

        Mock Get-PfxCertificate { return $fakeCert }
        Mock Get-ChildItem { return @() }
        Mock Import-Certificate { [pscustomobject]@{ Thumbprint = 'FORCE1'; Subject = 'CN=Force' } }

        $result = Install-RootCertificates -CertificatePaths @($certPath) -SkipIfExists:$false -ForceImport

        $result[0].Status | Should -Be 'Success'
        Assert-MockCalled Import-Certificate -Times 1
    }
}

Describe 'Backup-OperationState.ps1' {
    BeforeAll {
        $base = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path } else { (Get-Location).Path }
        $script:BackupScriptPath = [System.IO.Path]::GetFullPath((Join-Path $base '..\..\..\src\Powershell\utils\Backup-OperationState.ps1'))
        . $script:BackupScriptPath
    }

    It 'produces an archive when Compress is used' {
        $filePath = Join-Path $TestDrive 'data.txt'
        'sample' | Set-Content -Path $filePath -Encoding ASCII
        $items = @(@{ Type = 'File'; Path = $filePath })

        $summary = Backup-OperationState -OperationId 'TEST_OP' -BackupPathBase $TestDrive -ItemsToBackup $items -Compress

        $summary.BackupArchive | Should -Not -BeNullOrEmpty
        Test-Path $summary.BackupArchive | Should -BeTrue
        Test-Path $summary.BackupLocation | Should -BeFalse
    }

    It 'retains directory when KeepUncompressed is set' {
        $filePath = Join-Path $TestDrive 'data2.txt'
        'sample2' | Set-Content -Path $filePath -Encoding ASCII
        $items = @(@{ Type = 'File'; Path = $filePath })

        $summary = Backup-OperationState -OperationId 'TEST_OP2' -BackupPathBase $TestDrive -ItemsToBackup $items -Compress -KeepUncompressed

        Test-Path $summary.BackupArchive | Should -BeTrue
        Test-Path $summary.BackupLocation | Should -BeTrue
    }
}

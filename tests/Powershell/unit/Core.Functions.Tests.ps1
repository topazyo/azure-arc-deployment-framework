# tests/Powershell/unit/Core.Functions.Tests.ps1
using namespace System.Collections.Generic

Import-Module -Name Pester -MinimumVersion 5.0.0 -Force

# Mock necessary Az module functions if they are directly called by the functions being tested.
# For these placeholder functions, direct Az calls might not be present, but this is good practice.
# Example: Mock-Command Get-AzSubscription -MockWith { return [pscustomobject]@{Name='TestSubscription'; Id='test-sub-id'} }

Describe "Core Deployment Functions" {
    BeforeAll {
        # Import the module or source the scripts directly if not using a module structure for tests
        # This assumes the functions are available in the session.
        # If AzureArcFramework.psd1 is the manifest, and its RootModule is AzureArcFramework.psm1 which dotsources other .ps1 files,
        # then importing the .psd1 should make functions available.
        # For simplicity here, we'll assume functions are loaded.
        # Ensure these files exist and are accessible:
        . "$PSScriptRoot/../../../src/Powershell/core/Initialize-ArcDeployment.ps1"
        . "$PSScriptRoot/../../../src/Powershell/core/New-ArcDeployment.ps1"
    }

    Context "Initialize-ArcDeployment" {
        It "should run without errors with mandatory parameters" {
            { Initialize-ArcDeployment -SubscriptionId "sub-id" -ResourceGroupName "rg-name" -Location "eastus" } | Should -Not -Throw
        }

        It "should accept TenantId and Tags" {
            # Test output or behavior if possible. For placeholders, just test execution.
            { Initialize-ArcDeployment -SubscriptionId "sub-id" -ResourceGroupName "rg-name" -Location "eastus" -TenantId "tenant-id" -Tags @{Test="Tag"} } | Should -Not -Throw
        }
    }

    Context "New-ArcDeployment" {
        It "should run without errors with mandatory parameters" {
            { New-ArcDeployment -ServerName "server01" -ResourceGroupName "rg-name" } | Should -Not -Throw
        }

        It "should accept CorrelationId and AdditionalParameters" {
            { New-ArcDeployment -ServerName "server01" -ResourceGroupName "rg-name" -CorrelationId "corr-id" -AdditionalParameters @{Param1="Value1"} } | Should -Not -Throw
        }
    }
}

# Test-ConfigurationDrift.ps1
# This script tests for configuration drift against a predefined baseline or specific checks.

param (
    [Parameter(Mandatory = $false)]
    [string]$BaselinePath, # Placeholder for future baseline file functionality

    [Parameter(Mandatory = $false)]
    [string]$ServerName = $env:COMPUTERNAME, # Currently supports local machine checks primarily

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\ConfigurationDrift.log",

    [Parameter(Mandatory = $false)]
    [switch]$SkipRegistryChecks,

    [Parameter(Mandatory = $false)]
    [switch]$SkipServiceChecks,

    [Parameter(Mandatory = $false)]
    [switch]$SkipFirewallChecks,

    [Parameter(Mandatory = $false)]
    [switch]$SkipAuditPolicyChecks
)

# --- Logging (shared utility) ---
$ScriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($PSCommandPath) {
    Split-Path -Parent $PSCommandPath
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    (Get-Location).Path
}

if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . (Join-Path $ScriptRoot '..\utils\Write-Log.ps1')
}
# Fallback stub in case the utility cannot be loaded (e.g., in constrained test sandboxes)
if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    function Write-Log {
        param(
            [string]$Message,
            [string]$Level = "INFO",
            [string]$Path = $LogPath
        )
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$Level] $Message"
        try {
            Add-Content -Path $Path -Value $logEntry -ErrorAction SilentlyContinue
        } catch {
            Write-Host $logEntry
        }
    }
}

# --- Helper Function to Add Drift Detail ---
function Add-DriftDetail {
    param (
        [System.Collections.ArrayList]$DriftDetails,
        [string]$Category,
        [string]$Item,
        [string]$Property,
        [string]$ExpectedValue,
        [string]$CurrentValue
    )
    $status = if ($ExpectedValue -ne $CurrentValue) { "Drifted" } else { "Compliant" }
    $DriftDetails.Add([PSCustomObject]@{
        Category      = $Category
        Item          = $Item
        Property      = $Property
        ExpectedValue = $ExpectedValue
        CurrentValue  = $CurrentValue
        Status        = $status
    }) | Out-Null
    Write-Log "Check: [$Category] Item: $Item, Property: $Property, Expected: '$ExpectedValue', Current: '$CurrentValue', Status: $status"
}

# --- Main Script Logic ---
try {
    Write-Log "Starting configuration drift test script for server: $ServerName."

    # Administrator check (tests may override via $Global:IsAdminContext)
    $isAdmin = $null
    try {
        $globalAdminOverride = Get-Variable -Name IsAdminContext -Scope Global -ErrorAction SilentlyContinue
        if ($globalAdminOverride) {
            $isAdmin = [bool]$globalAdminOverride.Value
        }
    } catch { }

    if ($null -eq $isAdmin) {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    if (-not $isAdmin) {
        Write-Log "Running without Administrator privileges. Some checks might be limited or fail." -Level "WARNING"
    }

    if ($ServerName -ne $env:COMPUTERNAME) {
        Write-Log "Remote server checks are not fully implemented in this version. Forcing to local machine." -Level "WARNING"
        $ServerName = $env:COMPUTERNAME # For now, focus on local machine
    }

    $driftCollection = [System.Collections.ArrayList]::new()
    $overallDriftDetected = $false

    # Load baseline (JSON supported; fallback to hardcoded)
    $baselineRegistryChecks = @()
    $baselineServiceChecks = @()
    $baselineFirewallChecks = @()
    $baselineAuditPolicies = @()

    if ($BaselinePath) {
        try {
            Write-Log "Loading baseline from '$BaselinePath'."
            $baselineContent = Get-Content -Path $BaselinePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($baselineContent.registryChecks) { $baselineRegistryChecks = $baselineContent.registryChecks }
            if ($baselineContent.serviceChecks) { $baselineServiceChecks = $baselineContent.serviceChecks }
            if ($baselineContent.firewallChecks) { $baselineFirewallChecks = $baselineContent.firewallChecks }
            if ($baselineContent.auditPolicies) { $baselineAuditPolicies = $baselineContent.auditPolicies }
            Write-Log "Baseline loaded: RegistryChecks=$($baselineRegistryChecks.Count), ServiceChecks=$($baselineServiceChecks.Count), FirewallChecks=$($baselineFirewallChecks.Count), AuditPolicies=$($baselineAuditPolicies.Count)."
        } catch {
            Write-Log "Failed to load baseline file '$BaselinePath'. Falling back to hardcoded checks. Error: $($_.Exception.Message)" -Level "WARNING"
        }
    }

    if ($baselineRegistryChecks.Count -eq 0) {
        $baselineRegistryChecks = @(
            @{ Path = "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319"; Name = "SchUseStrongCrypto"; Expected = 1 },
            @{ Path = "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319"; Name = "SystemDefaultTlsVersions"; Expected = 1 },
            @{ Path = "HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319"; Name = "SchUseStrongCrypto"; Expected = 1 },
            @{ Path = "HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319"; Name = "SystemDefaultTlsVersions"; Expected = 1 }
        )
    }

    if ($baselineServiceChecks.Count -eq 0) {
        $baselineServiceChecks = @(
            @{ Name = "himds"; StartupType = "Automatic"; State = "Running" },
            @{ Name = "AzureMonitorAgent"; StartupType = "Automatic"; State = "Running" },
            @{ Name = "GCService"; StartupType = "Automatic"; State = "Running" }
        )
    }

    Write-Log "--- Performing Baseline Checks ---"

    # 1. Registry Checks (from baseline)
    if ($SkipRegistryChecks) {
        Write-Log "Skipping registry checks per configuration." -Level "INFO"
    } else {
        Write-Log "Checking Registry Settings..."
        foreach ($regCheck in $baselineRegistryChecks) {
            $regPath = $regCheck.Path
            $keyName = $regCheck.Name
            $expectedValue = $regCheck.Expected
            try {
                $currentValue = (Get-ItemProperty -Path $regPath -Name $keyName -ErrorAction Stop).$keyName
                Add-DriftDetail $driftCollection "Registry" $regPath $keyName $expectedValue $currentValue
            } catch { Add-DriftDetail $driftCollection "Registry" $regPath $keyName $expectedValue "NOT_FOUND_OR_ERROR" }
        }
    }

    # 2. Service State Checks
    if ($SkipServiceChecks) {
        Write-Log "Skipping service checks per configuration." -Level "INFO"
    } else {
        Write-Log "Checking Service States..."
        foreach ($svcCheck in $baselineServiceChecks) {
            $serviceName = $svcCheck.Name
            $hasStartup = ($svcCheck -is [hashtable] -and $svcCheck.ContainsKey('StartupType')) -or $svcCheck.PSObject.Properties['StartupType']
            $hasState = ($svcCheck -is [hashtable] -and $svcCheck.ContainsKey('State')) -or $svcCheck.PSObject.Properties['State']
            $expectedStartup = if ($svcCheck -is [hashtable]) { $svcCheck['StartupType'] } else { $svcCheck.StartupType }
            $expectedState = if ($svcCheck -is [hashtable]) { $svcCheck['State'] } else { $svcCheck.State }

            try {
                $service = Get-Service -Name $serviceName -ErrorAction Stop
                if ($hasStartup) { Add-DriftDetail $driftCollection "Service" $serviceName "StartupType" $expectedStartup $service.StartupType }
                if ($hasState) { Add-DriftDetail $driftCollection "Service" $serviceName "State" $expectedState $service.Status }
            } catch {
                if ($hasStartup) { Add-DriftDetail $driftCollection "Service" $serviceName "StartupType" $expectedStartup "NOT_FOUND_OR_ERROR" }
                if ($hasState) { Add-DriftDetail $driftCollection "Service" $serviceName "State" $expectedState "NOT_FOUND_OR_ERROR" }
            }
        }
    }

    # 3. Firewall Rule Checks (Basic - from Set-FirewallRules.ps1)
    if ($SkipFirewallChecks) {
        Write-Log "Skipping firewall checks per configuration." -Level "INFO"
    } else {
        Write-Log "Checking Firewall Rules..."
        $firewallRulesToTest = @{}
        if ($baselineFirewallChecks -and $baselineFirewallChecks.Count -gt 0) {
            foreach ($fw in $baselineFirewallChecks) {
                $firewallRulesToTest[$fw.Name] = @{ Enabled = $fw.Enabled; Direction = $fw.Direction; Action = $fw.Action }
            }
        } else {
            $firewallRulesToTest = @{
                "Azure Arc Management" = @{ Enabled = $true; Direction = "Outbound"; Action = "Allow" }
                "Azure Monitor" = @{ Enabled = $true; Direction = "Outbound"; Action = "Allow" }
            }
        }

        foreach ($ruleName in $firewallRulesToTest.Keys) {
            $expectedProps = $firewallRulesToTest[$ruleName]
            try {
                $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction Stop
                Add-DriftDetail $driftCollection "Firewall" $ruleName "Enabled" $expectedProps.Enabled $rule.Enabled
                Add-DriftDetail $driftCollection "Firewall" $ruleName "Direction" $expectedProps.Direction $rule.Direction
                Add-DriftDetail $driftCollection "Firewall" $ruleName "Action" $expectedProps.Action $rule.Action
            } catch {
                Add-DriftDetail $driftCollection "Firewall" $ruleName "Enabled" $expectedProps.Enabled "NOT_FOUND_OR_ERROR"
            }
        }
    }

    # 4. Audit Policy Checks (Basic - from Set-AuditPolicies.ps1)
    if ($SkipAuditPolicyChecks) {
        Write-Log "Skipping audit policy checks per configuration." -Level "INFO"
    } else {
        Write-Log "Checking Audit Policies..."
        $auditSubcategoriesToTest = @{}
        if ($baselineAuditPolicies -and $baselineAuditPolicies.Count -gt 0) {
            foreach ($ap in $baselineAuditPolicies) {
                $auditSubcategoriesToTest[$ap.Name] = $ap.Setting
            }
        } else {
            $auditSubcategoriesToTest = @{
                "Process Creation" = "Success"
                "Credential Validation" = "Success,Failure"
            }
        }

        try {
            $auditPolOutput = auditpol /get /category:* /r
            foreach($line in ($auditPolOutput | Where-Object {$_ -match "System,"})){ # Focus on System policy area
                $parts = $line.Split(',')
                if($parts.Length -ge 4){
                    $subcategoryNameFromAuditPol = $parts[2].Trim('"')
                    $currentSetting = $parts[3].Trim('"')

                    foreach($definedSubcategoryKey in $auditSubcategoriesToTest.Keys){
                        if($subcategoryNameFromAuditPol -eq $definedSubcategoryKey){
                            $expectedSetting = $auditSubcategoriesToTest[$definedSubcategoryKey]
                            $normalizedCurrent = $currentSetting -replace " and ", ","
                            $normalizedExpected = $expectedSetting -replace " and ", ","

                            Add-DriftDetail $driftCollection "AuditPolicy" $definedSubcategoryKey "Setting" $normalizedExpected $normalizedCurrent
                        }
                    }
                }
            }
        } catch {
            Write-Log "Failed to retrieve or parse audit policy. Error: $($_.Exception.Message)" -Level "ERROR"
            foreach($definedSubcategoryKey in $auditSubcategoriesToTest.Keys){
                 Add-DriftDetail $driftCollection "AuditPolicy" $definedSubcategoryKey "Setting" $auditSubcategoriesToTest[$definedSubcategoryKey] "ERROR_RETRIEVING_POLICY"
            }
        }
    }
    
    # Determine overall drift status
    $overallDriftDetected = ($driftCollection | Where-Object { $_.Status -eq "Drifted" } | Measure-Object).Count -gt 0

    $result = @{
        ServerName    = $ServerName
        Timestamp     = Get-Date
        DriftDetected = $overallDriftDetected
        DriftDetails  = $driftCollection
    }

    Write-Log "Configuration drift test completed. Drift Detected: $overallDriftDetected"
    return $result

}
catch {
    Write-Log "An critical error occurred during the drift test: $($_.Exception.Message)" -Level "FATAL"
    if ($_.ScriptStackTrace) {
        Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "FATAL"
    }
    # Return an error object or rethrow
    return @{
        ServerName    = $ServerName
        Timestamp     = Get-Date
        DriftDetected = $true # Assume drift on error
        Error         = "Critical error during script execution: $($_.Exception.Message)"
        DriftDetails  = @()
    }
}

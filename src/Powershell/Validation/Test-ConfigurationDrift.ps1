<#
.SYNOPSIS
Tests the local or target server for configuration drift.

.DESCRIPTION
Evaluates registry, service, firewall, and audit-policy state against either a
JSON baseline file or the built-in baseline checks. Results are logged and
returned as a structured drift report.

.PARAMETER BaselinePath
Optional path to a JSON drift-baseline file.

.PARAMETER ServerName
Target server name. Current implementation primarily evaluates the local machine.

.PARAMETER LogPath
Log file path for drift-check activity.

.PARAMETER SkipRegistryChecks
Skips registry-based validation.

.PARAMETER SkipServiceChecks
Skips service-based validation.

.PARAMETER SkipFirewallChecks
Skips firewall-rule validation.

.PARAMETER SkipAuditPolicyChecks
Skips audit-policy validation.

.OUTPUTS
PSCustomObject

.EXAMPLE
.\Test-ConfigurationDrift.ps1 -BaselinePath '.\tests\Powershell\fixtures\drift_baseline.json' -LogPath '.\Logs\drift.log'
#>

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

function Write-DriftLog {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [string]$Path = $LogPath
    )

    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log -Message $Message -Level $Level -Path $Path
        return
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    try {
        Add-Content -Path $Path -Value $logEntry -ErrorAction SilentlyContinue
    } catch {
        Write-Verbose $logEntry
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
    Write-DriftLog "Check: [$Category] Item: $Item, Property: $Property, Expected: '$ExpectedValue', Current: '$CurrentValue', Status: $status"
}

# --- Main Script Logic ---
try {
    Write-DriftLog "Starting configuration drift test script for server: $ServerName."

    # Administrator check (tests may override via $Global:IsAdminContext)
    $isAdmin = $null
    try {
        $globalAdminOverride = Get-Variable -Name IsAdminContext -Scope Global -ErrorAction SilentlyContinue
        if ($globalAdminOverride) {
            $isAdmin = [bool]$globalAdminOverride.Value
        }
    } catch { Write-Verbose 'Failed to read global administrator override; falling back to the current Windows principal.' }

    if ($null -eq $isAdmin) {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    if (-not $isAdmin) {
        Write-DriftLog "Running without Administrator privileges. Some checks might be limited or fail." -Level "WARNING"
    }

    if ($ServerName -ne $env:COMPUTERNAME) {
        Write-DriftLog "Remote server checks are not fully implemented in this version. Forcing to local machine." -Level "WARNING"
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
            Write-DriftLog "Loading baseline from '$BaselinePath'."
            $baselineContent = Get-Content -Path $BaselinePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($baselineContent.registryChecks) { $baselineRegistryChecks = $baselineContent.registryChecks }
            if ($baselineContent.serviceChecks) { $baselineServiceChecks = $baselineContent.serviceChecks }
            if ($baselineContent.firewallChecks) { $baselineFirewallChecks = $baselineContent.firewallChecks }
            if ($baselineContent.auditPolicies) { $baselineAuditPolicies = $baselineContent.auditPolicies }
            Write-DriftLog "Baseline loaded: RegistryChecks=$($baselineRegistryChecks.Count), ServiceChecks=$($baselineServiceChecks.Count), FirewallChecks=$($baselineFirewallChecks.Count), AuditPolicies=$($baselineAuditPolicies.Count)."
        } catch {
            Write-DriftLog "Failed to load baseline file '$BaselinePath'. Falling back to hardcoded checks. Error: $($_.Exception.Message)" -Level "WARNING"
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

    Write-DriftLog "--- Performing Baseline Checks ---"

    # 1. Registry Checks (from baseline)
    if ($SkipRegistryChecks) {
        Write-DriftLog "Skipping registry checks per configuration." -Level "INFO"
    } else {
        Write-DriftLog "Checking Registry Settings..."
        foreach ($regCheck in $baselineRegistryChecks) {
            $regPath = $regCheck.Path
            $keyName = $regCheck.Name
            $expectedValue = $regCheck.Expected
            try {
                $currentValue = (Get-ItemProperty -Path $regPath -Name $keyName -ErrorAction Stop).$keyName
                Add-DriftDetail -DriftDetails $driftCollection -Category "Registry" -Item $regPath -Property $keyName -ExpectedValue $expectedValue -CurrentValue $currentValue
            } catch { Add-DriftDetail -DriftDetails $driftCollection -Category "Registry" -Item $regPath -Property $keyName -ExpectedValue $expectedValue -CurrentValue "NOT_FOUND_OR_ERROR" }
        }
    }

    # 2. Service State Checks
    if ($SkipServiceChecks) {
        Write-DriftLog "Skipping service checks per configuration." -Level "INFO"
    } else {
        Write-DriftLog "Checking Service States..."
        foreach ($svcCheck in $baselineServiceChecks) {
            $serviceName = $svcCheck.Name
            $hasStartup = ($svcCheck -is [hashtable] -and $svcCheck.ContainsKey('StartupType')) -or $svcCheck.PSObject.Properties['StartupType']
            $hasState = ($svcCheck -is [hashtable] -and $svcCheck.ContainsKey('State')) -or $svcCheck.PSObject.Properties['State']
            $expectedStartup = if ($svcCheck -is [hashtable]) { $svcCheck['StartupType'] } else { $svcCheck.StartupType }
            $expectedState = if ($svcCheck -is [hashtable]) { $svcCheck['State'] } else { $svcCheck.State }

            try {
                $service = Get-Service -Name $serviceName -ErrorAction Stop
                if ($hasStartup) { Add-DriftDetail -DriftDetails $driftCollection -Category "Service" -Item $serviceName -Property "StartupType" -ExpectedValue $expectedStartup -CurrentValue $service.StartupType }
                if ($hasState) { Add-DriftDetail -DriftDetails $driftCollection -Category "Service" -Item $serviceName -Property "State" -ExpectedValue $expectedState -CurrentValue $service.Status }
            } catch {
                if ($hasStartup) { Add-DriftDetail -DriftDetails $driftCollection -Category "Service" -Item $serviceName -Property "StartupType" -ExpectedValue $expectedStartup -CurrentValue "NOT_FOUND_OR_ERROR" }
                if ($hasState) { Add-DriftDetail -DriftDetails $driftCollection -Category "Service" -Item $serviceName -Property "State" -ExpectedValue $expectedState -CurrentValue "NOT_FOUND_OR_ERROR" }
            }
        }
    }

    # 3. Firewall Rule Checks (Basic - from Set-FirewallRules.ps1)
    if ($SkipFirewallChecks) {
        Write-DriftLog "Skipping firewall checks per configuration." -Level "INFO"
    } else {
        Write-DriftLog "Checking Firewall Rules..."
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
                Add-DriftDetail -DriftDetails $driftCollection -Category "Firewall" -Item $ruleName -Property "Enabled" -ExpectedValue $expectedProps.Enabled -CurrentValue $rule.Enabled
                Add-DriftDetail -DriftDetails $driftCollection -Category "Firewall" -Item $ruleName -Property "Direction" -ExpectedValue $expectedProps.Direction -CurrentValue $rule.Direction
                Add-DriftDetail -DriftDetails $driftCollection -Category "Firewall" -Item $ruleName -Property "Action" -ExpectedValue $expectedProps.Action -CurrentValue $rule.Action
            } catch {
                Add-DriftDetail -DriftDetails $driftCollection -Category "Firewall" -Item $ruleName -Property "Enabled" -ExpectedValue $expectedProps.Enabled -CurrentValue "NOT_FOUND_OR_ERROR"
            }
        }
    }

    # 4. Audit Policy Checks (Basic - from Set-AuditPolicies.ps1)
    if ($SkipAuditPolicyChecks) {
        Write-DriftLog "Skipping audit policy checks per configuration." -Level "INFO"
    } else {
        Write-DriftLog "Checking Audit Policies..."
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

                            Add-DriftDetail -DriftDetails $driftCollection -Category "AuditPolicy" -Item $definedSubcategoryKey -Property "Setting" -ExpectedValue $normalizedExpected -CurrentValue $normalizedCurrent
                        }
                    }
                }
            }
        } catch {
              Write-DriftLog "Failed to retrieve or parse audit policy. Error: $($_.Exception.Message)" -Level "ERROR"
            foreach($definedSubcategoryKey in $auditSubcategoriesToTest.Keys){
                 Add-DriftDetail -DriftDetails $driftCollection -Category "AuditPolicy" -Item $definedSubcategoryKey -Property "Setting" -ExpectedValue $auditSubcategoriesToTest[$definedSubcategoryKey] -CurrentValue "ERROR_RETRIEVING_POLICY"
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

    Write-DriftLog "Configuration drift test completed. Drift Detected: $overallDriftDetected"
    return $result

}
catch {
    Write-DriftLog "An critical error occurred during the drift test: $($_.Exception.Message)" -Level "FATAL"
    if ($_.ScriptStackTrace) {
        Write-DriftLog "Stack Trace: $($_.ScriptStackTrace)" -Level "FATAL"
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

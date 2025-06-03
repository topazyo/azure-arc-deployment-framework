# Test-ConfigurationDrift.ps1
# This script tests for configuration drift against a predefined baseline or specific checks.

param (
    [Parameter(Mandatory = $false)]
    [string]$BaselinePath, # Placeholder for future baseline file functionality

    [Parameter(Mandatory = $false)]
    [string]$ServerName = $env:COMPUTERNAME, # Currently supports local machine checks primarily

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\ConfigurationDrift.log"
)

# --- Logging Function ---
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO", # INFO, WARNING, ERROR, DEBUG
        [string]$Path = $LogPath
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    try {
        if (-not (Test-Path (Split-Path $Path -Parent))) {
            New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force -ErrorAction Stop | Out-Null
        }
        Add-Content -Path $Path -Value $logEntry -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to write to log file $Path. Error: $($_.Exception.Message). Logging to console instead."
        Write-Host $logEntry
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

    # Administrator check (recommended for full access, though some checks might work without)
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Log "Running without Administrator privileges. Some checks might be limited or fail." -Level "WARNING"
    }

    if ($ServerName -ne $env:COMPUTERNAME) {
        Write-Log "Remote server checks are not fully implemented in this version. Forcing to local machine." -Level "WARNING"
        $ServerName = $env:COMPUTERNAME # For now, focus on local machine
    }

    $driftCollection = [System.Collections.ArrayList]::new()
    $overallDriftDetected = $false

    # Load baseline (placeholder for now)
    if ($BaselinePath) {
        Write-Log "Baseline file functionality is not yet implemented. Using hardcoded checks." -Level "WARNING"
        # TODO: Implement logic to load and parse $BaselinePath
    }

    Write-Log "--- Performing Hardcoded Baseline Checks ---"

    # 1. Registry Checks (from Set-TLSConfiguration.ps1)
    Write-Log "Checking Registry Settings..."
    $regPathNetFx = "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319"
    $regPathNetFxWow64 = "HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319"

    $expectedRegValues = @{
        "SchUseStrongCrypto" = 1
        "SystemDefaultTlsVersions" = 1
    }

    foreach ($keyName in $expectedRegValues.Keys) {
        $expectedValue = $expectedRegValues[$keyName]
        # Check main path
        try {
            $currentValue = (Get-ItemProperty -Path $regPathNetFx -Name $keyName -ErrorAction Stop).$keyName
            Add-DriftDetail $driftCollection "Registry" $regPathNetFx $keyName $expectedValue $currentValue
        } catch { Add-DriftDetail $driftCollection "Registry" $regPathNetFx $keyName $expectedValue "NOT_FOUND_OR_ERROR" }
        # Check Wow6432Node path
        try {
            $currentValueWow = (Get-ItemProperty -Path $regPathNetFxWow64 -Name $keyName -ErrorAction Stop).$keyName
            Add-DriftDetail $driftCollection "Registry" $regPathNetFxWow64 $keyName $expectedValue $currentValueWow
        } catch { Add-DriftDetail $driftCollection "Registry" $regPathNetFxWow64 $keyName $expectedValue "NOT_FOUND_OR_ERROR" }
    }

    # 2. Service State Checks
    Write-Log "Checking Service States..."
    $servicesToTest = @{
        "himds" = @{ StartupType = "Automatic"; State = "Running" } # Azure Connected Machine Agent
        "AzureMonitorAgent" = @{ StartupType = "Automatic"; State = "Running" } # AMA
        "GCService" = @{ StartupType = "Automatic"; State = "Running" } # Guest Config
    }
    foreach ($serviceName in $servicesToTest.Keys) {
        $expectedProps = $servicesToTest[$serviceName]
        try {
            $service = Get-Service -Name $serviceName -ErrorAction Stop
            Add-DriftDetail $driftCollection "Service" $serviceName "StartupType" $expectedProps.StartupType $service.StartupType
            Add-DriftDetail $driftCollection "Service" $serviceName "State" $expectedProps.State $service.State
        } catch {
            Add-DriftDetail $driftCollection "Service" $serviceName "StartupType" $expectedProps.StartupType "NOT_FOUND_OR_ERROR"
            Add-DriftDetail $driftCollection "Service" $serviceName "State" $expectedProps.State "NOT_FOUND_OR_ERROR"
        }
    }

    # 3. Firewall Rule Checks (Basic - from Set-FirewallRules.ps1)
    Write-Log "Checking Firewall Rules..."
    $firewallRulesToTest = @{
        "Azure Arc Management" = @{ Enabled = $true; Direction = "Outbound"; Action = "Allow" }
        # Add another key rule if desired, e.g., a Log Analytics outbound rule
        "Azure Monitor" = @{ Enabled = $true; Direction = "Outbound"; Action = "Allow" }

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

    # 4. Audit Policy Checks (Basic - from Set-AuditPolicies.ps1)
    Write-Log "Checking Audit Policies..."
    $auditSubcategoriesToTest = @{
        "Process Creation" = "Success" # Expected: Success, or Success and Failure
        "Credential Validation" = "Success,Failure"
    }
    try {
        # Get all audit policy settings. This requires admin rights.
        $auditPolOutput = auditpol /get /category:* /r # CSV output
        # Very basic parsing - this can be fragile
        foreach($line in ($auditPolOutput | Where-Object {$_ -match "System,"})){ #Focus on System policy area
            $parts = $line.Split(',')
            if($parts.Length -ge 4){
                $machine = $parts[0]
                $policyArea = $parts[1] # e.g. System
                $subcategoryNameFromAuditPol = $parts[2].Trim('"') # Subcategory Name
                $currentSetting = $parts[3].Trim('"') # Inclusion Setting

                foreach($definedSubcategoryKey in $auditSubcategoriesToTest.Keys){
                    # Convert defined key (e.g. "Process Creation") to match auditpol output if needed, or assume direct match
                    if($subcategoryNameFromAuditPol -eq $definedSubcategoryKey){
                        $expectedSetting = $auditSubcategoriesToTest[$definedSubcategoryKey]

                        # Normalize settings for comparison (e.g. "Success and Failure" vs "Success,Failure")
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

    # Determine overall drift status
    $overallDriftDetected = $driftCollection | Where-Object { $_.Status -eq "Drifted" } | Select-Object -First 1
    $overallDriftDetected = [bool]$overallDriftDetected # Cast to boolean

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

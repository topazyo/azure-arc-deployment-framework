# Test-LocalSecurityPolicy.ps1
# This script tests local security policy settings against a baseline.
# V1 Focus: Registry-backed settings under "Security Options".
# V1 Limitations: Password/Lockout policies and User Rights Assignments are report-only for expected values.

Function Test-LocalSecurityPolicy {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$BaselineSettings, # Expected to have localSecurityPolicy section

        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME, # Primarily for reporting context in V1

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\TestLocalSecurityPolicy_Activity.log"
    )

    # --- Logging Function (for script activity) ---
    function Write-Log {
        param (
            [string]$Message,
            [string]$Level = "INFO", # INFO, WARNING, ERROR, DEBUG
            [string]$Path = $LogPath
        )
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$Level] $Message"

        try {
            if (-not (Test-Path (Split-Path $Path -Parent) -PathType Container)) {
                New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force -ErrorAction Stop | Out-Null
            }
            Add-Content -Path $Path -Value $logEntry -ErrorAction Stop
        }
        catch {
            Write-Warning "ACTIVITY_LOG_FAIL: Failed to write to activity log file $Path. Error: $($_.Exception.Message). Logging to console instead."
            Write-Host $logEntry
        }
    }

    Write-Log "Starting Test-LocalSecurityPolicy on server '$ServerName'."
    if ($ServerName -ne $env:COMPUTERNAME) {
        Write-Log "Warning: Most checks are local. '$ServerName' parameter is primarily for reporting context." -Level "WARNING"
    }

    # --- Administrator Privilege Check ---
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Administrator privileges are required for many local security policy checks. Results may be incomplete or inaccurate." -Level "ERROR"
    } else {
        Write-Log "Running with Administrator privileges."
    }

    $allChecks = [System.Collections.ArrayList]::new()
    $script:overallCompliant = $true

    function Add-LSPCheckResult {
        param([string]$Name, [string]$ComplianceStatus, [object]$Expected, [object]$Actual, [string]$Details, [string]$RemediationSuggestion = "")
        $isTrulyCompliant = ($ComplianceStatus -eq "Compliant" -or $ComplianceStatus -eq "Compliant (Informational)")
        $check = [PSCustomObject]@{ Name = $Name; Compliant = $isTrulyCompliant; StatusString = $ComplianceStatus; Expected = $Expected; Actual = $Actual; Details = $Details; Remediation = $RemediationSuggestion }
        $allChecks.Add($check) | Out-Null
        if (-not $isTrulyCompliant -and $ComplianceStatus -notlike "NotImplemented*" -and $ComplianceStatus -ne "RequiresManualCheck") {
            $script:overallCompliant = $false
        }
        Write-Log "Check '$Name': Status='$ComplianceStatus'. Expected='$Expected', Actual='$Actual'. Details: $Details" -Level (if($isTrulyCompliant -or $ComplianceStatus -like "NotImplemented*" -or $ComplianceStatus -eq "RequiresManualCheck"){"DEBUG"}else{"WARNING"})
    }

    function Get-LSPRegValue {
        param([string]$RegPath, [string]$RegName)
        try {
            return (Get-ItemProperty -Path $RegPath -Name $RegName -ErrorAction Stop).$RegName
        } catch { Write-Log "Registry value not found or error accessing '$RegPath\$RegName': $($_.Exception.Message)" -Level "DEBUG"; return "ErrorReadingValue" }
    }

    $lspBaseline = $BaselineSettings.localSecurityPolicy
    if (-not $lspBaseline) {
        Write-Log "No 'localSecurityPolicy' section found in BaselineSettings. Cannot perform checks." -Level "ERROR"
        return [PSCustomObject]@{ Compliant = $false; Checks = $allChecks; Timestamp = (Get-Date -Format o); ServerName = $ServerName; Error = "Missing localSecurityPolicy baseline."}
    }

    # --- Account Policies - Password Policy (V1: Report Only) ---
    if ($lspBaseline.PSObject.Properties['accountPolicies'] -and $lspBaseline.accountPolicies.PSObject.Properties['passwordPolicy']) {
        $ppBaseline = $lspBaseline.accountPolicies.passwordPolicy
        Write-Log "Checking Account Policies - Password Policy (V1: Reporting Expected Values)."
        foreach($prop in $ppBaseline.PSObject.Properties.Name){
            Add-LSPCheckResult -Name "PasswordPolicy_$prop" -ComplianceStatus "NotImplemented_UseNetAccounts" -Expected $ppBaseline.$prop -Actual "N/A" -Details "Verify using 'net accounts' or Local Security Policy snap-in." -RemediationSuggestion "Configure via Group Policy or Local Security Policy."
        }
    }

    # --- Account Policies - Account Lockout Policy (V1: Report Only) ---
    if ($lspBaseline.PSObject.Properties['accountPolicies'] -and $lspBaseline.accountPolicies.PSObject.Properties['accountLockout']) {
        $aloBaseline = $lspBaseline.accountPolicies.accountLockout
        Write-Log "Checking Account Policies - Account Lockout Policy (V1: Reporting Expected Values)."
         foreach($prop in $aloBaseline.PSObject.Properties.Name){
            Add-LSPCheckResult -Name "AccountLockout_$prop" -ComplianceStatus "NotImplemented_UseNetAccounts" -Expected $aloBaseline.$prop -Actual "N/A" -Details "Verify using 'net accounts /domain' (if domain joined) or Local Security Policy snap-in." -RemediationSuggestion "Configure via Group Policy or Local Security Policy."
        }
    }

    # --- Local Policies - Security Options (V1: Registry-backed) ---
    if ($lspBaseline.PSObject.Properties['localPolicies'] -and $lspBaseline.localPolicies.PSObject.Properties['securityOptions']) {
        $secOptBaseline = $lspBaseline.localPolicies.securityOptions
        Write-Log "Checking Local Policies - Security Options."

        if ($secOptBaseline.PSObject.Properties['accounts']) {
            $accOptBaseline = $secOptBaseline.accounts
            $lsaRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"

            if ($accOptBaseline.PSObject.Properties.Contains('limitLocalAccountUseOfBlankPasswords')) {
                $expected = if([bool]$accOptBaseline.limitLocalAccountUseOfBlankPasswords){1}else{0}
                $actual = Get-LSPRegValue -RegPath $lsaRegPath -RegName "LimitBlankPasswordUse"
                Add-LSPCheckResult "SecurityOptions_LimitBlankPasswordUse" ($actual -eq $expected) $expected $actual "$lsaRegPath\LimitBlankPasswordUse" "Set to $expected"
            }
            if ($accOptBaseline.PSObject.Properties.Contains('renameAdministratorAccount')) {
                $admin = Get-LocalUser -Name "Administrator" -ErrorAction SilentlyContinue
                $isAdminActive = ($null -ne $admin -and $admin.Enabled)
                $expectedIsRenamedOrDisabled = [bool]$accOptBaseline.renameAdministratorAccount
                # If baseline expects it to be renamed/disabled, then $isAdminActive should be $false
                $compliant = ($expectedIsRenamedOrDisabled -eq (-not $isAdminActive))
                Add-LSPCheckResult "SecurityOptions_RenameAdministratorAccount" $compliant "Renamed/Disabled: $expectedIsRenamedOrDisabled" "Account 'Administrator' Active: $isAdminActive" "Ensure admin account is renamed or disabled if required." "Rename or disable the built-in Administrator account."
            }
             if ($accOptBaseline.PSObject.Properties.Contains('renameGuestAccount')) {
                $guest = Get-LocalUser -Name "Guest" -ErrorAction SilentlyContinue
                $isGuestActive = ($null -ne $guest -and $guest.Enabled)
                $expectedIsRenamedOrDisabled = [bool]$accOptBaseline.renameGuestAccount
                $compliant = ($expectedIsRenamedOrDisabled -eq (-not $isGuestActive))
                Add-LSPCheckResult "SecurityOptions_RenameGuestAccount" $compliant "Renamed/Disabled: $expectedIsRenamedOrDisabled" "Account 'Guest' Active: $isGuestActive" "Ensure guest account is renamed or disabled if required." "Rename or disable the built-in Guest account."
            }
        } # End accounts options

        if ($secOptBaseline.PSObject.Properties['networkSecurity']) {
            $netSecBaseline = $secOptBaseline.networkSecurity
            $lsaRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
            $msv1_0RegPath = "$lsaRegPath\MSV1_0"

            if ($netSecBaseline.PSObject.Properties.Contains('DoNotStoreLanManagerHash')) {
                $expected = if([bool]$netSecBaseline.DoNotStoreLanManagerHash){1}else{0}
                $actual = Get-LSPRegValue -RegPath $lsaRegPath -RegName "NoLMHash"
                Add-LSPCheckResult "NetSec_NoLMHash" ($actual -eq $expected) $expected $actual "$lsaRegPath\NoLMHash" "Set to $expected"
            }
            if ($netSecBaseline.PSObject.Properties.Contains('LanManagerAuthenticationLevel')) {
                $expected = $netSecBaseline.LanManagerAuthenticationLevel
                $actual = Get-LSPRegValue -RegPath $lsaRegPath -RegName "LmCompatibilityLevel"
                Add-LSPCheckResult "NetSec_LmCompatibilityLevel" ($actual -eq $expected) $expected $actual "$lsaRegPath\LmCompatibilityLevel" "Set to $expected"
            }
            # Assuming baseline specifies DWORD values for MinimumSessionSecurity components
            if ($netSecBaseline.PSObject.Properties.Contains('MinimumSessionSecurity_Client_DWORD')) {
                $expected = $netSecBaseline.MinimumSessionSecurity_Client_DWORD
                $actual = Get-LSPRegValue -RegPath $msv1_0RegPath -RegName "NtlmMinClientSec"
                Add-LSPCheckResult "NetSec_NtlmMinClientSec" ($actual -eq $expected) ("0x{0:X8}" -f $expected) ("0x{0:X8}" -f $actual) "$msv1_0RegPath\NtlmMinClientSec" "Set to 0x$($expected.ToString('X8'))"
            }
            if ($netSecBaseline.PSObject.Properties.Contains('MinimumSessionSecurity_Server_DWORD')) {
                $expected = $netSecBaseline.MinimumSessionSecurity_Server_DWORD
                $actual = Get-LSPRegValue -RegPath $msv1_0RegPath -RegName "NtlmMinServerSec"
                Add-LSPCheckResult "NetSec_NtlmMinServerSec" ($actual -eq $expected) ("0x{0:X8}" -f $expected) ("0x{0:X8}" -f $actual) "$msv1_0RegPath\NtlmMinServerSec" "Set to 0x$($expected.ToString('X8'))"
            }
        } # End networkSecurity options
    } # End securityOptions

    # --- Local Policies - User Rights Assignment (V1: Report Only) ---
    if ($lspBaseline.PSObject.Properties['localPolicies'] -and $lspBaseline.localPolicies.PSObject.Properties['userRightsAssignment']) {
        $uraBaseline = $lspBaseline.localPolicies.userRightsAssignment
        Write-Log "Checking Local Policies - User Rights Assignments (V1: Reporting Expected Values)."
        foreach($right in $uraBaseline.PSObject.Properties.Name){
            Add-LSPCheckResult -Name "UserRights_$right" -ComplianceStatus "NotImplemented_RequiresSeceditParsing" -Expected ($uraBaseline.$right -join ', ') -Actual "N/A" -Details "Verify using Local Security Policy snap-in or secedit.exe /export." -RemediationSuggestion "Configure via Group Policy or Local Security Policy."
        }
    }

    Write-Log "Test-LocalSecurityPolicy script finished. Overall Compliance: $script:overallCompliant."
    return [PSCustomObject]@{
        Compliant           = $script:overallCompliant
        Checks              = $allChecks
        Timestamp           = (Get-Date -Format o)
        ServerName          = $ServerName
    }
}

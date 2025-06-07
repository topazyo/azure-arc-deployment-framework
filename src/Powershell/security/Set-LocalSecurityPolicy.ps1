# Set-LocalSecurityPolicy.ps1
# This script applies Local Security Policy settings, focusing on registry-backed Security Options in V1.
# V1 Limitations: Account Policies (Password/Lockout) and User Rights Assignments are report-only for expected values and not automatically set.
# TODO V2: Implement setting Account Policies and User Rights using secedit.exe /configure with a dynamically generated INF.

Function Set-LocalSecurityPolicy {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$BaselineSettings, # Expected to have localSecurityPolicy section

        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME, # Primarily for reporting context in V1

        [Parameter(Mandatory=$false)]
        [bool]$EnforceSettings = $true,

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\SetLocalSecurityPolicy_Activity.log"
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

    Write-Log "Starting Set-LocalSecurityPolicy on server '$ServerName'."
    Write-Log "Parameters: EnforceSettings='$EnforceSettings'."
    if ($ServerName -ne $env:COMPUTERNAME) {
        Write-Log "Warning: Most operations are local. '$ServerName' parameter is primarily for reporting context." -Level "WARNING"
    }

    # --- Administrator Privilege Check ---
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        if ($EnforceSettings) {
            Write-Log "Administrator privileges are required to enforce Local Security Policy settings. Script cannot proceed with enforcement." -Level "ERROR"
            throw "Administrator privileges required to enforce settings."
        } else {
            Write-Log "Administrator privileges are recommended for accurate reading of all settings. Proceeding in audit mode." -Level "WARNING"
        }
    } else {
        Write-Log "Running with Administrator privileges."
    }

    $changesMadeList = [System.Collections.ArrayList]::new()
    $checksPerformedList = [System.Collections.ArrayList]::new()
    $script:overallStatus = if($EnforceSettings){"NoChangesNeeded"}else{"AuditNoMismatchesFound"}

    # Helper to get current registry value safely
    function Get-LSPRegValueSafe {
        param([string]$RegPath, [string]$RegName)
        try {
            if (Test-Path $RegPath) { # Check if path exists before trying to get property
                return (Get-ItemProperty -Path $RegPath -Name $RegName -ErrorAction SilentlyContinue).$RegName
            }
            return $null # Path doesn't exist
        } catch { Write-Log "Registry value not found or error accessing '$RegPath\$RegName': $($_.Exception.Message)" -Level "DEBUG"; return "ErrorReadingValue" }
    }

    # Helper to set registry value
    function Set-LSPRegValue {
        param([string]$RegPath, [string]$RegName, [object]$Value, [Microsoft.Win32.RegistryValueKind]$Type)
        Write-Log "Setting registry value: Path='$RegPath', Name='$RegName', Value='$Value', Type='$Type'."
        if (-not (Test-Path $RegPath)) {
            Write-Log "Registry path '$RegPath' does not exist. Creating path..." -Level "INFO"
            New-Item -Path $RegPath -Force -ErrorAction Stop | Out-Null
        }
        Set-ItemProperty -Path $RegPath -Name $RegName -Value $Value -Type $Type -Force -ErrorAction Stop
        Write-Log "Successfully set registry value '$RegName' at '$RegPath'."
    }


    $lspBaseline = $BaselineSettings.localSecurityPolicy
    if (-not $lspBaseline) {
        Write-Log "No 'localSecurityPolicy' section found in BaselineSettings. Cannot proceed." -Level "ERROR"
        return [PSCustomObject]@{ ChangesMade = @(); ChecksPerformed = $checksPerformedList; OverallStatus = "FailedNoBaseline"; Timestamp = (Get-Date -Format o); ServerName = $ServerName; Error = "Missing localSecurityPolicy baseline."}
    }

    # --- Account Policies - Password Policy (V1: Report Only) ---
    if ($lspBaseline.PSObject.Properties['accountPolicies'] -and $lspBaseline.accountPolicies.PSObject.Properties['passwordPolicy']) {
        Write-Log "Account Policies - Password Policy: V1 does not enforce these settings. Reporting expected values." -Level "INFO"
        $lspBaseline.accountPolicies.passwordPolicy.PSObject.Properties | ForEach-Object {
            $checksPerformedList.Add([PSCustomObject]@{ Name="PasswordPolicy_$($_.Name)"; Status="SkippedV1"; Expected=$_.Value; Details="Manual configuration or secedit.exe required for enforcement."}) | Out-Null
        }
        if ($script:overallStatus -notin @("ChangesMade", "Failed", "PartialSuccess", "AuditMismatchesFound")) { $script:overallStatus = "ManualStepsRequired" }
    }

    # --- Account Policies - Account Lockout Policy (V1: Report Only) ---
    if ($lspBaseline.PSObject.Properties['accountPolicies'] -and $lspBaseline.accountPolicies.PSObject.Properties['accountLockout']) {
        Write-Log "Account Policies - Account Lockout Policy: V1 does not enforce these settings. Reporting expected values." -Level "INFO"
        $lspBaseline.accountPolicies.accountLockout.PSObject.Properties | ForEach-Object {
            $checksPerformedList.Add([PSCustomObject]@{ Name="AccountLockout_$($_.Name)"; Status="SkippedV1"; Expected=$_.Value; Details="Manual configuration or secedit.exe required for enforcement."}) | Out-Null
        }
         if ($script:overallStatus -notin @("ChangesMade", "Failed", "PartialSuccess", "AuditMismatchesFound")) { $script:overallStatus = "ManualStepsRequired" }
    }

    # --- Local Policies - Security Options (V1: Registry-backed) ---
    if ($lspBaseline.PSObject.Properties['localPolicies'] -and $lspBaseline.localPolicies.PSObject.Properties['securityOptions']) {
        $secOptBaseline = $lspBaseline.localPolicies.securityOptions
        Write-Log "Processing Local Policies - Security Options."

        if ($secOptBaseline.PSObject.Properties['accounts']) {
            $accOptBaseline = $secOptBaseline.accounts
            $lsaRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"

            if ($accOptBaseline.PSObject.Properties.Contains('limitLocalAccountUseOfBlankPasswords')) {
                $expectedVal = if([bool]$accOptBaseline.limitLocalAccountUseOfBlankPasswords){1}else{0}
                $currentVal = Get-LSPRegValueSafe -RegPath $lsaRegPath -RegName "LimitBlankPasswordUse"
                $action = "NoChangeNeeded"
                if ($currentVal -ne $expectedVal) {
                    if ($EnforceSettings) {
                        if ($PSCmdlet.ShouldProcess("$lsaRegPath\LimitBlankPasswordUse", "Set to '$expectedVal' (Current: '$currentVal')")) {
                            try { Set-LSPRegValue -RegPath $lsaRegPath -RegName "LimitBlankPasswordUse" -Value $expectedVal -Type DWord; $action = "SetTo_$expectedVal"; $script:overallStatus = "ChangesMade" }
                            catch { $action = "ErrorSettingValue: $($_.Exception.Message)"; $script:overallStatus = "PartialSuccess" }
                        } else { $action = "SkippedWhatIf_SetTo_$expectedVal" }
                    } else { $action = "AuditMismatch"; if ($script:overallStatus -ne "ChangesMade") {$script:overallStatus = "AuditMismatchesFound"} }
                }
                $checksPerformedList.Add([PSCustomObject]@{ Name="SecurityOptions_LimitBlankPasswordUse"; Expected=$expectedVal; Actual=$currentVal; Action=$action; Details="$lsaRegPath\LimitBlankPasswordUse"}) | Out-Null
            }
            if ($accOptBaseline.PSObject.Properties.Contains('renameAdministratorAccount')) {
                 Write-Log "SecurityOptions_RenameAdministratorAccount: V1 does not automatically rename accounts. Manual action required if baseline is 'true'." -Level "INFO"
                 $checksPerformedList.Add([PSCustomObject]@{ Name="SecurityOptions_RenameAdministratorAccount"; Status="ManualActionRequired"; Expected=$accOptBaseline.renameAdministratorAccount; Details="Manual rename required if baseline is 'true'."}) | Out-Null
                 if ($script:overallStatus -notin @("ChangesMade", "Failed", "PartialSuccess", "AuditMismatchesFound")) { $script:overallStatus = "ManualStepsRequired" }
            }
             if ($accOptBaseline.PSObject.Properties.Contains('renameGuestAccount')) {
                 Write-Log "SecurityOptions_RenameGuestAccount: V1 does not automatically rename accounts. Manual action required if baseline is 'true'." -Level "INFO"
                 $checksPerformedList.Add([PSCustomObject]@{ Name="SecurityOptions_RenameGuestAccount"; Status="ManualActionRequired"; Expected=$accOptBaseline.renameGuestAccount; Details="Manual rename required if baseline is 'true'."}) | Out-Null
                 if ($script:overallStatus -notin @("ChangesMade", "Failed", "PartialSuccess", "AuditMismatchesFound")) { $script:overallStatus = "ManualStepsRequired" }
            }
        } # End accounts options

        if ($secOptBaseline.PSObject.Properties['networkSecurity']) {
            $netSecBaseline = $secOptBaseline.networkSecurity
            $lsaRegPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
            $msv1_0RegPath = Join-Path $lsaRegPath "MSV1_0" # Using Join-Path

            if ($netSecBaseline.PSObject.Properties.Contains('DoNotStoreLanManagerHash')) {
                $expectedVal = if([bool]$netSecBaseline.DoNotStoreLanManagerHash){1}else{0}
                $currentVal = Get-LSPRegValueSafe -RegPath $lsaRegPath -RegName "NoLMHash"
                $action = "NoChangeNeeded"
                if ($currentVal -ne $expectedVal) {
                    if ($EnforceSettings) {
                        if ($PSCmdlet.ShouldProcess("$lsaRegPath\NoLMHash", "Set to '$expectedVal' (Current: '$currentVal')")) {
                            try { Set-LSPRegValue -RegPath $lsaRegPath -RegName "NoLMHash" -Value $expectedVal -Type DWord; $action = "SetTo_$expectedVal"; $script:overallStatus = "ChangesMade" }
                            catch { $action = "ErrorSettingValue: $($_.Exception.Message)"; $script:overallStatus = "PartialSuccess" }
                        } else { $action = "SkippedWhatIf_SetTo_$expectedVal" }
                    } else { $action = "AuditMismatch"; if ($script:overallStatus -ne "ChangesMade") {$script:overallStatus = "AuditMismatchesFound"} }
                }
                $checksPerformedList.Add([PSCustomObject]@{ Name="NetSec_NoLMHash"; Expected=$expectedVal; Actual=$currentVal; Action=$action; Details="$lsaRegPath\NoLMHash"}) | Out-Null
            }
            if ($netSecBaseline.PSObject.Properties.Contains('LanManagerAuthenticationLevel')) {
                $expectedVal = $netSecBaseline.LanManagerAuthenticationLevel
                $currentVal = Get-LSPRegValueSafe -RegPath $lsaRegPath -RegName "LmCompatibilityLevel"
                $action = "NoChangeNeeded"
                if ($currentVal -ne $expectedVal) {
                    if ($EnforceSettings) {
                        if ($PSCmdlet.ShouldProcess("$lsaRegPath\LmCompatibilityLevel", "Set to '$expectedVal' (Current: '$currentVal')")) {
                            try { Set-LSPRegValue -RegPath $lsaRegPath -RegName "LmCompatibilityLevel" -Value $expectedVal -Type DWord; $action = "SetTo_$expectedVal"; $script:overallStatus = "ChangesMade" }
                            catch { $action = "ErrorSettingValue: $($_.Exception.Message)"; $script:overallStatus = "PartialSuccess" }
                        } else { $action = "SkippedWhatIf_SetTo_$expectedVal" }
                    } else { $action = "AuditMismatch"; if ($script:overallStatus -ne "ChangesMade") {$script:overallStatus = "AuditMismatchesFound"} }
                }
                $checksPerformedList.Add([PSCustomObject]@{ Name="NetSec_LmCompatibilityLevel"; Expected=$expectedVal; Actual=$currentVal; Action=$action; Details="$lsaRegPath\LmCompatibilityLevel"}) | Out-Null
            }
            if ($netSecBaseline.PSObject.Properties.Contains('MinimumSessionSecurity_Client_DWORD')) { # Assuming baseline key name
                $expectedVal = $netSecBaseline.MinimumSessionSecurity_Client_DWORD
                $currentVal = Get-LSPRegValueSafe -RegPath $msv1_0RegPath -RegName "NtlmMinClientSec"
                $action = "NoChangeNeeded"
                if ($currentVal -ne $expectedVal) {
                    if ($EnforceSettings) {
                        if ($PSCmdlet.ShouldProcess("$msv1_0RegPath\NtlmMinClientSec", "Set to '$('0x{0:X8}' -f $expectedVal)' (Current: '$('0x{0:X8}' -f $currentVal)')")) {
                            try { Set-LSPRegValue -RegPath $msv1_0RegPath -RegName "NtlmMinClientSec" -Value $expectedVal -Type DWord; $action = "SetTo_0x$($expectedVal.ToString('X8'))"; $script:overallStatus = "ChangesMade" }
                            catch { $action = "ErrorSettingValue: $($_.Exception.Message)"; $script:overallStatus = "PartialSuccess" }
                        } else { $action = "SkippedWhatIf_SetTo_0x$($expectedVal.ToString('X8'))" }
                    } else { $action = "AuditMismatch"; if ($script:overallStatus -ne "ChangesMade") {$script:overallStatus = "AuditMismatchesFound"} }
                }
                 $checksPerformedList.Add([PSCustomObject]@{ Name="NetSec_NtlmMinClientSec"; Expected=("0x{0:X8}" -f $expectedVal); Actual=("0x{0:X8}" -f $currentVal); Action=$action; Details="$msv1_0RegPath\NtlmMinClientSec"}) | Out-Null
            }
             if ($netSecBaseline.PSObject.Properties.Contains('MinimumSessionSecurity_Server_DWORD')) { # Assuming baseline key name
                $expectedVal = $netSecBaseline.MinimumSessionSecurity_Server_DWORD
                $currentVal = Get-LSPRegValueSafe -RegPath $msv1_0RegPath -RegName "NtlmMinServerSec"
                $action = "NoChangeNeeded"
                if ($currentVal -ne $expectedVal) {
                    if ($EnforceSettings) {
                        if ($PSCmdlet.ShouldProcess("$msv1_0RegPath\NtlmMinServerSec", "Set to '$('0x{0:X8}' -f $expectedVal)' (Current: '$('0x{0:X8}' -f $currentVal)')")) {
                            try { Set-LSPRegValue -RegPath $msv1_0RegPath -RegName "NtlmMinServerSec" -Value $expectedVal -Type DWord; $action = "SetTo_0x$($expectedVal.ToString('X8'))"; $script:overallStatus = "ChangesMade" }
                            catch { $action = "ErrorSettingValue: $($_.Exception.Message)"; $script:overallStatus = "PartialSuccess" }
                        } else { $action = "SkippedWhatIf_SetTo_0x$($expectedVal.ToString('X8'))" }
                    } else { $action = "AuditMismatch"; if ($script:overallStatus -ne "ChangesMade") {$script:overallStatus = "AuditMismatchesFound"} }
                }
                 $checksPerformedList.Add([PSCustomObject]@{ Name="NetSec_NtlmMinServerSec"; Expected=("0x{0:X8}" -f $expectedVal); Actual=("0x{0:X8}" -f $currentVal); Action=$action; Details="$msv1_0RegPath\NtlmMinServerSec"}) | Out-Null
            }
        } # End networkSecurity options
    } # End securityOptions

    # --- Local Policies - User Rights Assignment (V1: Report Only) ---
    if ($lspBaseline.PSObject.Properties['localPolicies'] -and $lspBaseline.localPolicies.PSObject.Properties['userRightsAssignment']) {
        Write-Log "Local Policies - User Rights Assignments: V1 does not enforce these settings. Reporting expected values." -Level "INFO"
        $lspBaseline.localPolicies.userRightsAssignment.PSObject.Properties | ForEach-Object {
            $checksPerformedList.Add([PSCustomObject]@{ Name="UserRights_$($_.Name)"; Status="SkippedV1"; Expected=($_.Value -join ', '); Details="Manual configuration or secedit.exe /configure required for enforcement."}) | Out-Null
        }
        if ($script:overallStatus -notin @("ChangesMade", "Failed", "PartialSuccess", "AuditMismatchesFound")) { $script:overallStatus = "ManualStepsRequired" }
    }

    Write-Log "Set-LocalSecurityPolicy script finished. Overall Status: $script:overallStatus."
    return [PSCustomObject]@{
        ChangesMade         = if($EnforceSettings){ ($checksPerformedList | Where-Object {$_.Action -like "SetTo_*" -or $_.Action -like "ErrorSettingValue*"}) } else { @() }
        ChecksPerformed     = $checksPerformedList
        OverallStatus       = $script:overallStatus
        Timestamp           = (Get-Date -Format o)
        ServerName          = $ServerName
    }
}

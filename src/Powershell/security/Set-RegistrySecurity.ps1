# Set-RegistrySecurity.ps1
# This script applies defined security settings (values and types) to specified registry keys.
# TODO: Add support for setting registry key ACLs/permissions in a future version.

Function Set-RegistrySecurity {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$BaselineSettings, # Expected to have registrySettings.securityKeys array

        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME, # For reporting context, registry operations are local

        [Parameter(Mandatory=$false)]
        [bool]$EnforceSettings = $true,

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\SetRegistrySecurity_Activity.log"
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

    Write-Log "Starting Set-RegistrySecurity on server '$ServerName'."
    Write-Log "Parameters: EnforceSettings='$EnforceSettings'."
    if ($ServerName -ne $env:COMPUTERNAME) {
        Write-Log "Warning: Registry operations are performed locally. '$ServerName' parameter is for reporting context." -Level "WARNING"
    }

    # --- Administrator Privilege Check ---
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        if ($EnforceSettings) {
            Write-Log "Administrator privileges are required to set registry values. Script cannot proceed with enforcement." -Level "ERROR"
            throw "Administrator privileges required to enforce settings."
        } else {
            Write-Log "Administrator privileges are recommended for accurate reading of all registry settings. Proceeding in audit mode." -Level "WARNING"
        }
    } else {
        Write-Log "Running with Administrator privileges."
    }

    $changesMadeList = [System.Collections.ArrayList]::new()
    $checksPerformedList = [System.Collections.ArrayList]::new()
    $script:overallStatus = if($EnforceSettings){"NoChangesNeeded"}else{"AuditNoMismatchesFound"}

    # Helper to compare MULTISTRING values
    function Compare-MultiStringArrays {
        param ($arr1, $arr2)
        if ($null -eq $arr1 -and $null -eq $arr2) { return $true }
        if ($null -eq $arr1 -or $null -eq $arr2) { return $false } # One is null, other is not
        if ($arr1.Count -ne $arr2.Count) { return $false }
        # Order matters for MultiString in registry generally for direct comparison
        for ($i = 0; $i -lt $arr1.Count; $i++) {
            if ($arr1[$i] -ne $arr2[$i]) { return $false }
        }
        return $true
    }

    # Helper to compare BINARY values
    function Compare-ByteArrays {
        param ([byte[]]$arr1, [byte[]]$arr2)
        if ($null -eq $arr1 -and $null -eq $arr2) { return $true }
        if ($null -eq $arr1 -or $null -eq $arr2) { return $false }
        return ($arr1 | Compare-Object $arr2 -PassThru).Length -eq 0
    }

    $regSecurityKeys = $BaselineSettings.registrySettings.securityKeys
    if (-not $regSecurityKeys -or $regSecurityKeys -isnot [array]) {
        Write-Log "No 'registrySettings.securityKeys' array found in BaselineSettings or it's not an array. Cannot proceed." -Level "ERROR"
        return [PSCustomObject]@{ ChangesMade = @(); ChecksPerformed = $checksPerformedList; OverallStatus = "FailedNoBaseline"; Timestamp = (Get-Date -Format o); ServerName = $ServerName; Error = "Missing or invalid registrySettings.securityKeys baseline."}
    }

    Write-Log "Processing $($regSecurityKeys.Count) registry security key settings from baseline."

    foreach ($entry in $regSecurityKeys) {
        $regPath = $entry.path
        $regValueName = $entry.key
        $expectedValueFromBaseline = $entry.value
        $expectedRegTypeStr = $entry.type.ToUpper()
        $actionTaken = "NoChangeNeeded"
        $currentValueForReport = "ValueNotFound" # Default if not found
        $statusForCheck = "Success" # Per check

        try {
            $currentValue = Get-ItemPropertyValue -Path $regPath -Name $regValueName -ErrorAction SilentlyContinue
            if ($null -ne $Error[0] -and $Error[0].Exception -is [System.Management.Automation.ItemNotFoundException]) {
                $currentValue = $null # Ensure $currentValue is null if value name doesn't exist
                $Error.Clear()
            } elseif ($null -ne $Error[0]) { # Other errors reading value
                throw $Error[0]
            }

            if ($null -ne $currentValue) { $currentValueForReport = $currentValue }

            # Prepare expected value based on type
            $typedExpectedValue = $expectedValueFromBaseline
            $registryValueKind = [Microsoft.Win32.RegistryValueKind]::Unknown
            switch ($expectedRegTypeStr) {
                "DWORD"       { $typedExpectedValue = [System.Convert]::ToInt32($expectedValueFromBaseline); $registryValueKind = [Microsoft.Win32.RegistryValueKind]::DWord }
                "QWORD"       { $typedExpectedValue = [System.Convert]::ToInt64($expectedValueFromBaseline); $registryValueKind = [Microsoft.Win32.RegistryValueKind]::QWord }
                "STRING"      { $registryValueKind = [Microsoft.Win32.RegistryValueKind]::String }
                "EXPANDSTRING"{ $registryValueKind = [Microsoft.Win32.RegistryValueKind]::ExpandString }
                "MULTISTRING" {
                    $typedExpectedValue = [string[]]$expectedValueFromBaseline # Ensure it's an array
                    $registryValueKind = [Microsoft.Win32.RegistryValueKind]::MultiString
                }
                "BINARY"      { # Expecting hex string from baseline, convert to byte array
                    try {
                        $hexString = ($expectedValueFromBaseline -replace '[^0-9a-fA-F]').ToUpper()
                        if ($hexString.Length % 2 -ne 0) { throw "Invalid hex string length."}
                        $bytes = for ($i = 0; $i -lt $hexString.Length; $i += 2) { [System.Convert]::ToByte($hexString.Substring($i, 2), 16) }
                        $typedExpectedValue = $bytes
                    } catch { throw "Cannot convert baseline value '$expectedValueFromBaseline' to byte[] for BINARY type. Ensure it's a valid hex string. Error: $($_.Exception.Message)" }
                    $registryValueKind = [Microsoft.Win32.RegistryValueKind]::Binary
                }
                default       { Write-Log "Unsupported ExpectedType '$expectedRegTypeStr' for registry value '$regValueName' at '$regPath'. Will attempt to set as String if different." -Level "WARNING"; $registryValueKind = [Microsoft.Win32.RegistryValueKind]::String }
            }

            # Comparison logic
            $needsSetting = $false
            if ($null -eq $currentValue) { # Value doesn't exist
                $needsSetting = $true
                $details = "Registry value '$regValueName' not found at '$regPath'. Expected '$typedExpectedValue'."
                Write-Log $details -Level (if($EnforceSettings){"INFO"}else{"WARNING"})
            } else {
                # Type-aware comparison
                $valuesDiffer = $false
                switch ($expectedRegTypeStr) {
                    "DWORD"; "QWORD" { $valuesDiffer = ($currentValue -ne $typedExpectedValue) } # Numerically
                    "STRING"; "EXPANDSTRING" { $valuesDiffer = ($currentValue -ne $typedExpectedValue) } # String comparison
                    "MULTISTRING" { $valuesDiffer = -not (Compare-MultiStringArrays $currentValue $typedExpectedValue) }
                    "BINARY" { $valuesDiffer = -not (Compare-ByteArrays $currentValue $typedExpectedValue) }
                    default { $valuesDiffer = ("$currentValue" -ne "$typedExpectedValue") } # Fallback to string
                }
                if ($valuesDiffer) {
                    $needsSetting = $true
                    $details = "Registry value '$regValueName' at '$regPath' is '$currentValue', expected '$typedExpectedValue'."
                    Write-Log $details -Level (if($EnforceSettings){"INFO"}else{"WARNING"})
                } else {
                    $details = "Registry value '$regValueName' at '$regPath' is already compliant ('$currentValue')."
                    Write-Log $details -Level "DEBUG"
                }
            }

            if ($needsSetting) {
                if ($EnforceSettings) {
                    if ($PSCmdlet.ShouldProcess("Registry value '$regValueName' at '$regPath'", "Set to '$($typedExpectedValue -join ',' # Handles arrays for logging nicely
                    )' (Type: $expectedRegTypeStr)")) {
                        try {
                            if (-not (Test-Path $regPath)) {
                                Write-Log "Registry path '$regPath' does not exist. Creating path..." -Level "INFO"
                                New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
                            }
                            Set-ItemProperty -Path $regPath -Name $regValueName -Value $typedExpectedValue -Type $registryValueKind -Force -ErrorAction Stop
                            $actionTaken = "SetTo_$($entry.value)" # Use original baseline value for log
                            $changesMadeList.Add([PSCustomObject]@{ Path=$regPath; ValueName=$regValueName; OldValue=$currentValueForReport; NewValue=$entry.value; Type=$expectedRegTypeStr; Status="Success" }) | Out-Null
                            if ($script:overallStatus -ne "PartialSuccess" -and $script:overallStatus -ne "Failed") {$script:overallStatus = "ChangesMade"}
                        } catch {
                            $actionTaken = "ErrorSettingValue: $($_.Exception.Message)"
                            $statusForCheck = "Failed"
                            $errorsEncountered.Add($actionTaken) | Out-Null
                            if ($script:overallStatus -ne "Failed") {$script:overallStatus = "PartialSuccess"}
                        }
                    } else { $actionTaken = "SkippedWhatIf_SetTo_$($entry.value)" }
                } else { # Audit mode
                    $actionTaken = "AuditMismatch"
                    if ($script:overallStatus -notin @("ChangesMade","PartialSuccess","Failed")) {$script:overallStatus = "AuditMismatchesFound"}
                }
            }
            $checksPerformedList.Add([PSCustomObject]@{ Path=$regPath; ValueName=$regValueName; Compliant=(-not $needsSetting); Expected=$entry.value; Actual=$currentValueForReport; Action=$actionTaken; Details=$details; ExpectedType=$expectedRegTypeStr }) | Out-Null

        } catch {
            $errorMessage = "Error processing registry entry Path:'$($entry.path)', Key:'$($entry.key)'. Detail: $($_.Exception.Message)"
            Write-Log $errorMessage -Level "ERROR"
            $errorsEncountered.Add($errorMessage) | Out-Null
            $checksPerformedList.Add([PSCustomObject]@{ Path=$entry.path; ValueName=$entry.key; Compliant=$false; Expected=$entry.value; Actual="ErrorProcessing"; Action="Error"; Details=$errorMessage; ExpectedType=$entry.type }) | Out-Null
            if ($script:overallStatus -ne "Failed") {$script:overallStatus = "PartialSuccess"}
        }
    }

    Write-Log "Set-RegistrySecurity script finished. Overall Status: $script:overallStatus."
    return [PSCustomObject]@{
        ChangesMade         = $changesMadeList
        ChecksPerformed     = $checksPerformedList
        OverallStatus       = $script:overallStatus
        Timestamp           = (Get-Date -Format o)
        ServerName          = $ServerName
        ErrorsEncountered   = $errorsEncountered
    }
}

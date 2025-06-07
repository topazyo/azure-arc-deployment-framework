# Test-RegistrySecurity.ps1
# This script tests specific registry key values and types against a security baseline.
# TODO: Enhance type checking for Binary, MultiString, QWORD if more precision is needed.
# TODO: Add ACL/permission checking for registry keys in a future version.

Function Test-RegistrySecurity {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$BaselineSettings, # Expected to have registrySettings.securityKeys array

        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME, # For reporting context, registry checks are local

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\TestRegistrySecurity_Activity.log"
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

    Write-Log "Starting Test-RegistrySecurity on server '$ServerName'."
    if ($ServerName -ne $env:COMPUTERNAME) {
        Write-Log "Warning: Registry checks are performed locally. '$ServerName' parameter is for reporting context." -Level "WARNING"
    }

    # --- Administrator Privilege Check ---
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Administrator privileges may be required for accessing certain registry keys (especially HKLM). Results may be incomplete." -Level "WARNING"
    } else {
        Write-Log "Running with Administrator privileges."
    }

    $allChecks = [System.Collections.ArrayList]::new()
    $script:overallCompliant = $true

    function Add-RegCheckResult {
        param([string]$Path, [string]$ValueName, [bool]$IsCompliant, [object]$ExpectedValue, [object]$ActualValue, [string]$ExpectedType, [string]$ActualType, [string]$Details, [string]$RemediationSuggestion = "")
        $check = [PSCustomObject]@{ Path=$Path; ValueName=$ValueName; Compliant=$IsCompliant; ExpectedValue=$ExpectedValue; ActualValue=$ActualValue; ExpectedType=$ExpectedType; ActualType=$ActualType; Details=$Details; Remediation=$RemediationSuggestion }
        $allChecks.Add($check) | Out-Null
        if (-not $IsCompliant) { $script:overallCompliant = $false }
        Write-Log "Check: Path='$Path', ValueName='$ValueName': Compliant=$IsCompliant. Expected='$ExpectedValue' (Type:$ExpectedType), Actual='$ActualValue' (Type:$ActualType). Details: $Details" -Level (if($IsCompliant){"DEBUG"}else{"WARNING"})
    }

    $regSecurityKeys = $BaselineSettings.registrySettings.securityKeys
    if (-not $regSecurityKeys -or $regSecurityKeys -isnot [array]) {
        Write-Log "No 'registrySettings.securityKeys' array found in BaselineSettings or it's not an array. Cannot perform checks." -Level "ERROR"
        return [PSCustomObject]@{ Compliant = $false; Checks = $allChecks; Timestamp = (Get-Date -Format o); ServerName = $ServerName; Error = "Missing or invalid registrySettings.securityKeys baseline."}
    }

    Write-Log "Processing $($regSecurityKeys.Count) registry security key checks from baseline."

    foreach ($entry in $regSecurityKeys) {
        $regPath = $entry.path
        $regValueName = $entry.key # This is the 'Value Name'
        $expectedValue = $entry.value
        $expectedType = $entry.type.ToUpper() # Normalize to uppercase for comparison

        $actualValue = $null
        $actualValueType = "NotFound"
        $compliant = $false
        $details = ""
        $remediation = "Ensure registry value '$regValueName' at '$regPath' is set to '$expectedValue' with type '$expectedType'."

        try {
            if (-not (Test-Path -Path $regPath)) {
                $details = "Registry path '$regPath' does not exist."
                $actualValue = "PathNotFound"
                Add-RegCheckResult -Path $regPath -ValueName $regValueName -IsCompliant $false -ExpectedValue $expectedValue -ActualValue $actualValue -ExpectedType $expectedType -ActualType $actualValueType -Details $details -RemediationSuggestion $remediation
                continue
            }

            $itemProperty = Get-ItemProperty -Path $regPath -Name $regValueName -ErrorAction SilentlyContinue

            if ($null -eq $itemProperty -or -not $itemProperty.PSObject.Properties[$regValueName]) {
                $details = "Registry value '$regValueName' not found at path '$regPath'."
                $actualValue = "ValueNotFound"
                Add-RegCheckResult -Path $regPath -ValueName $regValueName -IsCompliant $false -ExpectedValue $expectedValue -ActualValue $actualValue -ExpectedType $expectedType -ActualType $actualValueType -Details $details -RemediationSuggestion $remediation
                continue
            }

            $actualValue = $itemProperty.$regValueName
            $actualValueType = $actualValue.GetType().Name # Get .NET type name

            # Type and Value Comparison Logic
            $typeMatch = $false
            $valueMatch = $false

            switch ($expectedType) {
                "DWORD" {
                    $typeMatch = ($actualValue -is [int] -or $actualValue -is [uint32] -or $actualValue -is [long] -or $actualValue -is [uint64]) # PowerShell unboxes to Int32 or Int64 for DWORD/QWORD
                    if ($typeMatch) {
                        $valueMatch = ([System.Convert]::ToInt64($actualValue) -eq [System.Convert]::ToInt64($expectedValue))
                    } else {$actualValueType = "TypeMismatch (Expected $expectedType, Got $($actualValue.GetType().Name))"}
                }
                "QWORD" {
                    $typeMatch = ($actualValue -is [long] -or $actualValue -is [uint64] -or $actualValue -is [int] -or $actualValue -is [uint32])
                     if ($typeMatch) {
                        $valueMatch = ([System.Convert]::ToInt64($actualValue) -eq [System.Convert]::ToInt64($expectedValue))
                    } else {$actualValueType = "TypeMismatch (Expected $expectedType, Got $($actualValue.GetType().Name))"}
                }
                "STRING" -or "EXPANDSTRING" {
                    $typeMatch = ($actualValue -is [string])
                    if ($typeMatch) { $valueMatch = ($actualValue -eq $expectedValue) }
                    else {$actualValueType = "TypeMismatch (Expected $expectedType, Got $($actualValue.GetType().Name))"}
                }
                "MULTISTRING" {
                    $typeMatch = ($actualValue -is [string[]])
                    if ($typeMatch) {
                        if ($expectedValue -isnot [array]) { $expectedValue = @($expectedValue) } # Ensure expected is array for comparison
                        $compare = Compare-Object -ReferenceObject $expectedValue -DifferenceObject $actualValue -PassThru
                        $valueMatch = ($null -eq $compare)
                    } else {$actualValueType = "TypeMismatch (Expected $expectedType, Got $($actualValue.GetType().Name))"}
                }
                "BINARY" { # Binary comparison is tricky; compare hex strings for V1
                    $typeMatch = ($actualValue -is [byte[]])
                    if ($typeMatch) {
                        $actualHexString = ($actualValue | ForEach-Object { $_.ToString("X2") }) -join ""
                        $expectedHexString = $expectedValue -replace '\s','' # Assuming expected might be space-separated hex
                        $valueMatch = ($actualHexString -eq $expectedHexString.ToUpper())
                    } else {$actualValueType = "TypeMismatch (Expected $expectedType, Got $($actualValue.GetType().Name))"}
                }
                default {
                    Write-Log "Unsupported ExpectedType '$expectedType' for registry check at '$regPath' - '$regValueName'. Performing string comparison." -Level "WARNING"
                    $typeMatch = $true # Avoid failing on type for unknown, just try string compare
                    $valueMatch = ("$actualValue" -eq "$expectedValue")
                }
            }

            $compliant = $typeMatch -and $valueMatch
            $details = if ($compliant) { "Registry value matches baseline." }
                       elseif(-not $typeMatch) { "Type mismatch. Expected $expectedType, got $($actualValue.GetType().Name)." }
                       else { "Value mismatch." }

            Add-RegCheckResult -Path $regPath -ValueName $regValueName -IsCompliant $compliant -ExpectedValue $expectedValue -ActualValue $actualValue -ExpectedType $expectedType -ActualType $actualValue.GetType().Name -Details $details -RemediationSuggestion $remediation

        } catch {
            $details = "Error checking registry value '$regValueName' at '$regPath': $($_.Exception.Message)"
            Add-RegCheckResult -Path $regPath -ValueName $regValueName -IsCompliant $false -ExpectedValue $expectedValue -ActualValue "ErrorReadingValue" -ExpectedType $expectedType -ActualType "Error" -Details $details -RemediationSuggestion $remediation
        }
    }

    Write-Log "Test-RegistrySecurity script finished. Overall Compliance: $script:overallCompliant."
    return [PSCustomObject]@{
        Compliant           = $script:overallCompliant
        Checks              = $allChecks
        Timestamp           = (Get-Date -Format o)
        ServerName          = $ServerName
    }
}

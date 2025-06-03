# Test-OSCompatibility.ps1
# This script tests if an OS version is compatible based on defined rules.
# TODO: Enhance SKU checking if reliable local/remote method is available without heavy WMI/CIM parsing for all cases.
# TODO: Add more detailed Linux compatibility checks if rules are expanded.

Function Test-OSCompatibility {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)]
        [string]$OSVersionString, # e.g., "10.0.17763.1234"

        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [string]$CompatibilityRulesPath,

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\TestOSCompatibility_Activity.log"
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

    Write-Log "Starting Test-OSCompatibility script."
    Write-Log "Parameters: OSVersionString='$OSVersionString', ServerName='$ServerName', CompatibilityRulesPath='$CompatibilityRulesPath'."

    $currentOSVersion = $null
    $currentOSName = "Unknown"
    $rulesSource = "Hardcoded"
    $compatibilityStatus = "Unknown"
    $message = ""

    # --- Get OS Information ---
    if (-not [string]::IsNullOrWhiteSpace($OSVersionString)) {
        Write-Log "Using provided OSVersionString: $OSVersionString"
        try {
            $currentOSVersion = [System.Version]$OSVersionString
            # OSName might not be available if only version string is passed, could be a param too
        } catch {
            Write-Log "Failed to parse provided OSVersionString '$OSVersionString' into System.Version. Error: $($_.Exception.Message)" -Level "ERROR"
            return [PSCustomObject]@{
                TestedOSVersion = $OSVersionString; OSName = $currentOSName; CompatibilityStatus = "Error";
                Message = "Invalid OSVersionString provided."; RulesSource = "None"; Timestamp = (Get-Date -Format o)
            }
        }
    } else {
        Write-Log "OSVersionString not provided. Attempting to get OS info from '$ServerName'."
        try {
            $compInfo = $null
            if ($ServerName -eq $env:COMPUTERNAME -or [string]::IsNullOrWhiteSpace($ServerName)) {
                $compInfo = Get-ComputerInfo
            } else {
                # Remoting requires WinRM to be configured and accessible. This might fail.
                Write-Log "Attempting remote Get-ComputerInfo to '$ServerName'. Ensure WinRM is configured." -Level "INFO"
                $compInfo = Invoke-Command -ComputerName $ServerName -ScriptBlock { Get-ComputerInfo } -ErrorAction Stop
            }
            $currentOSVersion = [System.Version]$compInfo.OsVersion
            $currentOSName = $compInfo.OsName
            Write-Log "Retrieved OS Version: $($currentOSVersion.ToString()), Name: $currentOSName from '$ServerName'."
        } catch {
            Write-Log "Failed to get OS information from '$ServerName'. Error: $($_.Exception.Message)" -Level "ERROR"
             return [PSCustomObject]@{
                TestedOSVersion = "N/A"; OSName = "N/A"; CompatibilityStatus = "Error";
                Message = "Failed to retrieve OS info from '$ServerName': $($_.Exception.Message)"; RulesSource = "None"; Timestamp = (Get-Date -Format o)
            }
        }
    }

    # --- Load Compatibility Rules ---
    $rules = $null
    if (-not [string]::IsNullOrWhiteSpace($CompatibilityRulesPath)) {
        Write-Log "Loading compatibility rules from: $CompatibilityRulesPath"
        if (Test-Path $CompatibilityRulesPath -PathType Leaf) {
            try {
                $rules = Get-Content -Path $CompatibilityRulesPath -Raw | ConvertFrom-Json -ErrorAction Stop
                $rulesSource = $CompatibilityRulesPath
                Write-Log "Successfully loaded compatibility rules from JSON."
            } catch {
                Write-Log "Failed to load or parse compatibility rules file '$CompatibilityRulesPath'. Error: $($_.Exception.Message). Falling back to hardcoded rules." -Level "ERROR"
                $rules = $null # Ensure fallback
            }
        } else {
            Write-Log "Compatibility rules file not found at: $CompatibilityRulesPath. Falling back to hardcoded rules." -Level "WARNING"
        }
    }

    if (-not $rules) {
        Write-Log "Using hardcoded default compatibility rules (Windows Server focus)."
        $rulesSource = "Hardcoded"
        # Azure Arc supported OS: https://docs.microsoft.com/en-us/azure/azure-arc/servers/prerequisites#supported-operating-systems
        # For this example, let's set a baseline of Windows Server 2016
        $rules = @{
            windowsServer = @{
                minVersion = "10.0.14393.0" # Windows Server 2016 RTM build. Revision often updated by KBs.
                # supportedSkus = @("Datacenter", "Standard") # SKU check is harder from version alone.
                # blockedVersions = @()
            }
            # linux = @{ ... } # Placeholder
        }
    }

    # --- Compatibility Check (V1: Windows Server Focus) ---
    try {
        if ($currentOSName -match "Windows Server") {
            $serverRules = $rules.windowsServer
            if (-not $serverRules) { throw "No 'windowsServer' rules found in the provided or default rule set." }

            $minVersion = [System.Version]$serverRules.minVersion

            Write-Log "Current OS Version: $($currentOSVersion.ToString()), Min Required Version (WinSrv): $($minVersion.ToString())" -Level "DEBUG"

            if ($currentOSVersion -ge $minVersion) {
                # Check blocked versions if any
                $isBlocked = $false
                if ($serverRules.blockedVersions) {
                    foreach ($blockedVerStr in $serverRules.blockedVersions) {
                        try {
                            $blockedVer = [System.Version]$blockedVerStr
                            if ($currentOSVersion.Major -eq $blockedVer.Major -and `
                                $currentOSVersion.Minor -eq $blockedVer.Minor -and `
                                $currentOSVersion.Build -eq $blockedVer.Build -and `
                                ($currentOSVersion.Revision -eq $blockedVer.Revision -or $blockedVer.Revision -eq -1)) { # -1 can mean any revision
                                $isBlocked = $true
                                break
                            }
                        } catch { Write-Log "Could not parse blockedVersion string '$blockedVerStr' to System.Version" -Level "WARNING"}
                    }
                }

                if ($isBlocked) {
                    $compatibilityStatus = "NotCompatible"
                    $message = "OS Version $($currentOSVersion.ToString()) is explicitly blocked by compatibility rules."
                    Write-Log $message -Level "WARNING"
                } else {
                    $compatibilityStatus = "Compatible"
                    $message = "OS Version $($currentOSVersion.ToString()) meets the minimum requirement of $($minVersion.ToString()) and is not in a blocked list."
                    Write-Log $message
                    # Could add a "Warning" if version is old but still supported.
                    # Example: if ($currentOSVersion.Build -lt <SomeHigherButStillSupportedBuild>) { $compatibilityStatus = "WarningPotentiallyCompatible"; $message += " Consider updating to a more recent build." }
                }
            } else {
                $compatibilityStatus = "NotCompatible"
                $message = "OS Version $($currentOSVersion.ToString()) is older than the minimum required version $($minVersion.ToString())."
                Write-Log $message -Level "WARNING"
            }
        }
        elseif ($currentOSName -match "Linux") { # Placeholder for Linux
            $compatibilityStatus = "NotImplemented"
            $message = "Linux OS compatibility checks are not fully implemented in this version."
            Write-Log $message -Level "WARNING"
        }
        else { # Other OS (e.g. Windows Client)
            $compatibilityStatus = "NotChecked" # Or "NotApplicable" if rules are server-specific
            $message = "OS '$currentOSName' is not Windows Server. Compatibility rules used are primarily for Windows Server in this version."
            Write-Log $message -Level "INFO"
        }
    } catch {
        Write-Log "Error during compatibility check logic: $($_.Exception.Message)" -Level "ERROR"
        $compatibilityStatus = "ErrorInCheck"
        $message = "An error occurred during the compatibility check: $($_.Exception.Message)"
    }


    $result = [PSCustomObject]@{
        TestedOSVersion     = if($currentOSVersion){$currentOSVersion.ToString()}else{$OSVersionString}
        OSName              = $currentOSName
        CompatibilityStatus = $compatibilityStatus
        Message             = $message
        RulesSource         = $rulesSource
        Timestamp           = (Get-Date -Format o)
    }

    Write-Log "Test-OSCompatibility script finished. Status: $compatibilityStatus."
    return $result
}

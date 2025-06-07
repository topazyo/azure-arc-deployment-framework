# Test-AntivirusStatus.ps1
# This script checks Antivirus status by calling the more comprehensive Test-EndpointProtectionCompliance.ps1.
# It acts as a wrapper for compatibility or simpler invocation if needed.
# TODO: Ensure Test-EndpointProtectionCompliance.ps1 is in the expected path relative to this script.

Function Test-AntivirusStatus {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [object]$BaselineSettings, # Expects an object containing an 'antiMalware' property/key

        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\TestAntivirusStatus_Wrapper_Activity.log" # Optional separate log for wrapper
    )

    # --- Logging Function (minimal for this wrapper) ---
    function Write-LogWrapper { # Renamed to avoid conflict if dot-sourcing multiple scripts with same function name
        param (
            [string]$Message,
            [string]$Level = "INFO",
            [string]$Path = $LogPath
        )
        # Only log if LogPath was explicitly provided to this wrapper, to avoid duplicate logging
        # if the main orchestrator already handles overall logging.
        # For now, this function will be minimal as Test-EndpointProtectionCompliance.ps1 does detailed logging.
        if ($PSBoundParameters.ContainsKey('LogPath')) {
            $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            $logEntry = "[$timestamp] [$Level] [Test-AntivirusStatusWrapper] $Message"
            try {
                if (-not (Test-Path (Split-Path $Path -Parent) -PathType Container)) {
                    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force -ErrorAction Stop | Out-Null
                }
                Add-Content -Path $Path -Value $logEntry -ErrorAction Stop
            } catch { Write-Warning "WRAPPER_LOG_FAIL: $logEntry" }
        } else {
            # If no specific LogPath for wrapper, just Write-Verbose for traceability during tests/debug
            Write-Verbose "[Test-AntivirusStatusWrapper] [$Level] $Message"
        }
    }

    Write-LogWrapper "Executing Test-AntivirusStatus wrapper for server '$ServerName'."

    # Determine path to Test-EndpointProtectionCompliance.ps1 (assuming same directory for simplicity)
    # In a module structure, one might just call the function if both are exported module functions.
    $PSScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path -Resolve
    $ComplianceScriptPath = Join-Path $PSScriptRoot "Test-EndpointProtectionCompliance.ps1"

    if (-not (Test-Path $ComplianceScriptPath -PathType Leaf)) {
        Write-LogWrapper "Core script Test-EndpointProtectionCompliance.ps1 not found at '$ComplianceScriptPath'." -Level "ERROR"
        # Return a consistent error object structure
        return [PSCustomObject]@{
            Compliant          = $false
            Checks             = @(
                @{ Name = "AntivirusStatusCheck"; Compliant = $false; Expected = "ExecutableScriptFound"; Actual = "NotFound"; Details = "Dependency script Test-EndpointProtectionCompliance.ps1 not found at $ComplianceScriptPath."; Remediation = "Ensure script is present in the correct location." }
            )
            DetectedAVProducts = @()
            Timestamp          = (Get-Date -Format o)
            ServerName         = $ServerName
            Error              = "DependencyScriptNotFound"
        }
    }

    # Extract the antiMalware settings for Test-EndpointProtectionCompliance.ps1
    $epBaselineSettings = $null
    if ($BaselineSettings.PSObject.Properties['antiMalware']) {
        $epBaselineSettings = $BaselineSettings.antiMalware
    } else {
        Write-LogWrapper "Required 'antiMalware' section not found in BaselineSettings input." -Level "ERROR"
        return [PSCustomObject]@{
            Compliant          = $false
            Checks             = @(
                @{ Name = "AntivirusStatusCheck"; Compliant = $false; Expected = "AntiMalwareBaselinePresent"; Actual = "NotFound"; Details = "Required 'antiMalware' section missing from BaselineSettings."; Remediation = "Provide valid BaselineSettings." }
            )
            DetectedAVProducts = @()
            Timestamp          = (Get-Date -Format o)
            ServerName         = $ServerName
            Error              = "MissingAntiMalwareBaseline"
        }
    }

    Write-LogWrapper "Calling Test-EndpointProtectionCompliance.ps1 with extracted antiMalware baseline."

    try {
        # Parameters for Test-EndpointProtectionCompliance.ps1: -BaselineSettings (this is the antiMalware section itself)
        # and -ServerName. It has its own default LogPath.
        $result = & $ComplianceScriptPath -BaselineSettings $epBaselineSettings -ServerName $ServerName
        Write-LogWrapper "Test-EndpointProtectionCompliance.ps1 executed. Overall Compliance: $($result.Compliant)."
        return $result
    }
    catch {
        Write-LogWrapper "Error executing Test-EndpointProtectionCompliance.ps1: $($_.Exception.Message)" -Level "ERROR"
        Write-LogWrapper "Stack Trace: $($_.ScriptStackTrace)" -Level "DEBUG"
        return [PSCustomObject]@{
            Compliant          = $false
            Checks             = @(
                @{ Name = "AntivirusStatusCheck"; Compliant = $false; Expected = "SuccessfulExecution"; Actual = "ExecutionError"; Details = "Error calling Test-EndpointProtectionCompliance.ps1: $($_.Exception.Message)"; Remediation = "Investigate error in Test-EndpointProtectionCompliance.ps1 execution." }
            )
            DetectedAVProducts = @()
            Timestamp          = (Get-Date -Format o)
            ServerName         = $ServerName
            Error              = "ExecutionErrorInComplianceScript"
            ErrorRecord        = $_ # Include the full error record for more details
        }
    }
}

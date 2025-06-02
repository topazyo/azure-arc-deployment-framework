# Get-ConfigurationDrifts.ps1
# This script acts as a wrapper to execute Test-ConfigurationDrift.ps1 and return its results.

param (
    [Parameter(Mandatory = $false)]
    [string]$BaselinePath, # Optional: Path to a baseline file for Test-ConfigurationDrift.ps1

    [Parameter(Mandatory = $false)]
    [string]$ServerName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\GetConfigurationDrifts_Activity.log", # Activity log for this wrapper script

    [Parameter(Mandatory = $false)]
    [string]$TestConfigurationDriftPath # Path to the Test-ConfigurationDrift.ps1 script
)

# --- Logging Function (for this wrapper script's activity) ---
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO", # INFO, WARNING, ERROR
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
        Write-Warning "Failed to write to activity log file $Path. Error: $($_.Exception.Message). Logging to console instead."
        Write-Host $logEntry
    }
}

# --- Main Script Logic ---
try {
    Write-Log "Starting Get-ConfigurationDrifts script."
    Write-Log "Parameters: BaselinePath='$BaselinePath', ServerName='$ServerName', TestConfigurationDriftPath='$TestConfigurationDriftPath'"

    # Determine the path to Test-ConfigurationDrift.ps1
    if ([string]::IsNullOrWhiteSpace($TestConfigurationDriftPath)) {
        try {
            # Assuming Test-ConfigurationDrift.ps1 is in the same directory as this script ($PSScriptRoot)
            # $PSScriptRoot is only reliable when the script is run directly, not necessarily in all ISE/hosting scenarios.
            # Using Get-Location as a fallback if $PSScriptRoot is null/empty, though less robust.
            $ScriptDirectory = $PSScriptRoot
            if ([string]::IsNullOrEmpty($ScriptDirectory)) {
                $ScriptDirectory = Split-Path -Path (Get-Location).Path -Resolve # Fallback, might not be script dir
                Write-Log "PSScriptRoot was not available. Using Get-Location: $ScriptDirectory" -Level "DEBUG"
            }
            $TestConfigurationDriftPath = Join-Path $ScriptDirectory 'Test-ConfigurationDrift.ps1'
            $TestConfigurationDriftPath = (Resolve-Path $TestConfigurationDriftPath -ErrorAction Stop).Path
            Write-Log "Resolved TestConfigurationDriftPath to: $TestConfigurationDriftPath"
        } catch {
             Write-Log "Could not automatically resolve path to Test-ConfigurationDrift.ps1. Error: $($_.Exception.Message)" -Level "ERROR"
             throw "Could not determine path to Test-ConfigurationDrift.ps1. Please specify -TestConfigurationDriftPath."
        }
    }
    
    if (-not (Test-Path -Path $TestConfigurationDriftPath -PathType Leaf)) {
        Write-Log "Test-ConfigurationDrift.ps1 not found at the specified path: $TestConfigurationDriftPath" -Level "ERROR"
        throw "Test-ConfigurationDrift.ps1 not found at path: $TestConfigurationDriftPath"
    }

    Write-Log "Found Test-ConfigurationDrift.ps1 at: $TestConfigurationDriftPath"

    # Construct parameters for Test-ConfigurationDrift.ps1
    $paramsForTestScript = @{
        ServerName = $ServerName
    }
    if ($PSBoundParameters.ContainsKey('BaselinePath')) { # Only pass BaselinePath if it was provided to this script
        $paramsForTestScript.BaselinePath = $BaselinePath
        Write-Log "Passing BaselinePath '$BaselinePath' to Test-ConfigurationDrift.ps1"
    }
    # Note: The LogPath for Test-ConfigurationDrift.ps1 is managed by itself with its own default.

    Write-Log "Executing Test-ConfigurationDrift.ps1..."
    $driftTestData = & $TestConfigurationDriftPath @paramsForTestScript
    
    if ($driftTestData) {
        Write-Log "Successfully executed Test-ConfigurationDrift.ps1 and received data."
        # The $driftTestData object (typically a hashtable or PSCustomObject) contains DriftDetected, DriftDetails etc.
        # It can be returned as-is or further processed if needed.
        # Example: if ($driftTestData.DriftDetected) { Write-Log "Drift was detected by Test-ConfigurationDrift.ps1" -Level "WARNING" }
    } else {
        Write-Log "Test-ConfigurationDrift.ps1 executed but returned no data or null." -Level "WARNING"
        # Depending on requirements, this might be an error or just an indication of no drift / no checks performed.
    }

    Write-Log "Get-ConfigurationDrifts script finished."
    return $driftTestData

}
catch {
    Write-Log "An error occurred in Get-ConfigurationDrifts script: $($_.Exception.Message)" -Level "FATAL"
    if ($_.ScriptStackTrace) {
        Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "FATAL"
    }
    # Return null or an empty structure on error to indicate failure
    return $null 
}

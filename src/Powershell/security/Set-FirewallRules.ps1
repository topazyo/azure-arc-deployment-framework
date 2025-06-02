# Set-FirewallRules.ps1
# This script configures Windows Firewall rules based on a JSON configuration file.

param (
    [Parameter(Mandatory = $false)]
    [bool]$EnforceRules = $true,

    [Parameter(Mandatory = $false)]
    [bool]$BackupRules = $true,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\FirewallConfiguration.log"
    # In a real scenario, ensure C:\ProgramData\AzureArcFramework\Logs exists or create it.
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

# --- Backup Function ---
function Backup-FirewallPolicy {
    param(
        [string]$BackupFilePath
    )
    Write-Log "Backing up current firewall policy to $BackupFilePath..."
    try {
        if (-not (Test-Path (Split-Path $BackupFilePath -Parent))) {
            New-Item -ItemType Directory -Path (Split-Path $BackupFilePath -Parent) -Force -ErrorAction Stop | Out-Null
        }
        netsh advfirewall export "$BackupFilePath" | Out-Null
        Write-Log "Firewall policy successfully backed up to $BackupFilePath."
    }
    catch {
        Write-Log "Failed to back up firewall policy. Error: $($_.Exception.Message)" -Level "ERROR"
        throw "Firewall policy backup failed." # Rethrow to stop script if backup is critical
    }
}

# --- Main Script Logic ---
try {
    Write-Log "Starting firewall configuration script."

    # Check for Admin Privileges
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "This script requires Administrator privileges to manage firewall rules." -Level "ERROR"
        throw "Administrator privileges required."
    }

    # Define paths
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    $ConfigFile = Join-Path -Path $ScriptRoot -ChildPath "..\..\config\security-baseline.json"

    # Read configuration
    Write-Log "Reading configuration from $ConfigFile..."
    if (-not (Test-Path -Path $ConfigFile)) {
        Write-Log "Configuration file $ConfigFile not found." -Level "ERROR"
        throw "Configuration file not found."
    }
    $Config = Get-Content -Path $ConfigFile | ConvertFrom-Json
    $FirewallSettings = $Config.firewallRules

    if (-not $FirewallSettings) {
        Write-Log "firewallRules section not found in the configuration file." -Level "ERROR"
        throw "firewallRules section not found."
    }

    # Backup existing rules
    if ($BackupRules -and $EnforceRules) {
        $timestamp = Get-Date -Format "yyyyMMddHHmmss"
        $backupDir = Join-Path -Path (Split-Path $LogPath -Parent) -ChildPath "FirewallBackups"
        $backupFile = Join-Path -Path $backupDir -ChildPath "FirewallPolicyBackup-$timestamp.wfw"
        Backup-FirewallPolicy -BackupFilePath $backupFile
    }

    if (-not $EnforceRules) {
        Write-Log "EnforceRules is set to false. Exiting without applying new firewall rules."
        exit 0
    }

    Write-Log "Applying firewall rules..."

    # Process rules (Outbound and Inbound)
    foreach ($direction in @("outbound", "inbound")) {
        Write-Log "Processing $direction rules..."
        if ($FirewallSettings.$direction) {
            foreach ($ruleDef in $FirewallSettings.$direction) {
                $ruleName = $ruleDef.name
                Write-Log "Processing rule: '$ruleName' (Direction: $direction)"

                try {
                    $existingRule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

                    $params = @{
                        DisplayName = $ruleName
                        Direction   = $direction
                        Action      = if ($ruleDef.action) { $ruleDef.action } else { "Allow" } # Default to Allow
                        Protocol    = if ($ruleDef.protocol) { $ruleDef.protocol } else { "Any" } # Default to Any
                        Enabled     = if ($null -ne $ruleDef.required) { [bool]$ruleDef.required } else { $true } # Default to enabled
                    }

                    if ($ruleDef.port) {
                        if ($direction -eq "outbound") { $params.RemotePort = $ruleDef.port }
                        else { $params.LocalPort = $ruleDef.port }
                    }
                    if ($direction -eq "outbound" -and $ruleDef.destination) {
                        $params.RemoteAddress = $ruleDef.destination
                    } elseif ($direction -eq "inbound" -and $ruleDef.source) {
                        $params.RemoteAddress = $ruleDef.source # 'source' in JSON maps to RemoteAddress for inbound
                    }
                    
                    if ($ruleDef.program) { $params.Program = $ruleDef.program }
                    if ($ruleDef.service) { $params.Service = $ruleDef.service }
                    if ($ruleDef.interfacealias) { $params.InterfaceAlias = $ruleDef.interfacealias } # e.g., "Ethernet", "Wi-Fi"
                    if ($ruleDef.profile) { 
                        # Ensure profile is one of Domain, Private, Public, Any
                        $validProfiles = @("Domain", "Private", "Public", "Any")
                        if ($validProfiles -contains $ruleDef.profile) {
                             $params.Profile = $ruleDef.profile 
                        } else {
                            Write-Log "Invalid profile '$($ruleDef.profile)' for rule '$ruleName'. Defaulting to 'Any'." -Level "WARNING"
                            $params.Profile = "Any"
                        }
                    } else {
                        $params.Profile = "Any" # Default if not specified
                    }


                    if ($existingRule) {
                        Write-Log "Rule '$ruleName' already exists. Updating..."
                        # Note: Comparing all properties to see if an update is truly needed can be complex.
                        # For simplicity, we're using Set-NetFirewallRule, which will update if different.
                        Set-NetFirewallRule -DisplayName $ruleName @params -ErrorAction Stop
                        Write-Log "Rule '$ruleName' updated successfully."
                    } else {
                        Write-Log "Rule '$ruleName' does not exist. Creating..."
                        New-NetFirewallRule @params -ErrorAction Stop
                        Write-Log "Rule '$ruleName' created successfully."
                    }
                }
                catch {
                    Write-Log "Failed to process rule '$ruleName'. Error: $($_.Exception.Message) Details: $($_.ScriptStackTrace)" -Level "ERROR"
                    # Continue to next rule
                }
            }
        } else {
            Write-Log "No $direction rules defined in the configuration."
        }
    }

    # TODO: Consider how to handle rules not defined in the baseline (e.g., remove them or audit them).
    # This script currently only ensures that rules defined in the baseline are present and configured.

    Write-Log "Firewall configuration script completed."
}
catch {
    Write-Log "An critical error occurred: $($_.Exception.Message)" -Level "FATAL"
    if ($_.ScriptStackTrace) {
        Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "FATAL"
    }
    # Ensure non-zero exit code for critical errors
    exit 1
}

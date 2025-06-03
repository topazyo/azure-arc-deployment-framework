# Set-TLSConfiguration.ps1
# This script configures TLS settings based on a provided settings object.

param (
    [Parameter(Mandatory = $true)]
    [object]$Settings, # This object should be the tlsSettings section from the JSON

    [Parameter(Mandatory = $false)]
    [bool]$EnforceSettings = $true,

    [Parameter(Mandatory = $false)]
    [bool]$BackupRegistry = $true
)

# Function for logging messages
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO"
    )
    Write-Host "[$Level] $Message"
}

# Define paths
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
# $ConfigFile = Join-Path -Path $ScriptRoot -ChildPath "..\..\config\security-baseline.json" # Adjusted path - REMOVED

# --- Registry Backup Function ---
function Backup-RegistryKeys {
    param (
        [string[]]$RegistryKeys,
        [string]$BackupPath
    )
    Write-Log "Starting registry backup..."
    if (-not (Test-Path -Path $BackupPath)) {
        New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
    }
    foreach ($key in $RegistryKeys) {
        $keyName = $key -replace "[^a-zA-Z0-9]", "_"
        $exportPath = Join-Path -Path $BackupPath -ChildPath "$keyName.reg"
        Write-Log "Backing up $key to $exportPath"
        try {
            Invoke-Expression "reg export `"$key`" `"$exportPath`" /y"
            Write-Log "Successfully backed up $key."
        }
        catch {
            Write-Log "Failed to back up $key. Error: $($_.Exception.Message)" -Level "ERROR"
        }
    }
    Write-Log "Registry backup completed."
}

# --- Main Script Logic ---
try {
    Write-Log "Starting TLS configuration script."

    # Validate input Settings object
    if (-not $Settings) {
        Write-Log "The -Settings parameter is null. Configuration cannot be applied." -Level "ERROR"
        exit 1 # Or handle as appropriate, e.g., return a specific error object
    }
    # $TlsSettings will now be the $Settings parameter directly.
    # Write-Log "Using provided TLS settings object." # Optional: Log that settings are from parameter

    # Registry keys to back up
    $SchannelProtocolsKey = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols"
    $SchannelCiphersKey = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\CipherSuites"
    $CryptographyConfigKey = "HKLM:\SYSTEM\CurrentControlSet\Control\Cryptography\Configuration\Local\SSL\00010002"
    $DotNetFrameworkKey = "HKLM:\SOFTWARE\Microsoft\.NETFramework\v4.0.30319"
    $DotNetFrameworkWow6432NodeKey = "HKLM:\SOFTWARE\Wow6432Node\Microsoft\.NETFramework\v4.0.30319"

    $keysToBackup = @(
        $SchannelProtocolsKey,
        $SchannelCiphersKey,
        $CryptographyConfigKey,
        $DotNetFrameworkKey,
        $DotNetFrameworkWow6432NodeKey
    )

    if ($BackupRegistry) {
        $timestamp = Get-Date -Format "yyyyMMddHHmmss"
        $backupDir = Join-Path -Path $ScriptRoot -ChildPath "RegistryBackups\$timestamp"
        Backup-RegistryKeys -RegistryKeys $keysToBackup -BackupPath $backupDir
    }

    if (-not $EnforceSettings) {
        Write-Log "EnforceSettings is set to false. Exiting without applying changes."
        exit 0
    }

    Write-Log "Applying TLS configuration settings..."

    # Configure TLS Protocols
    Write-Log "Configuring TLS protocols..."
    foreach ($protocolName in $Settings.protocols.PSObject.Properties.Name) {
        $protocolConfig = $Settings.protocols.$protocolName
        $protocolKeyPath = Join-Path -Path $SchannelProtocolsKey -ChildPath $protocolName

        # Ensure protocol key exists
        if (-not (Test-Path -Path $protocolKeyPath)) {
            New-Item -Path $protocolKeyPath -Force | Out-Null
        }

        # Client settings
        $clientKeyPath = Join-Path -Path $protocolKeyPath -ChildPath "Client"
        if (-not (Test-Path -Path $clientKeyPath)) {
            New-Item -Path $clientKeyPath -Force | Out-Null
        }
        Set-ItemProperty -Path $clientKeyPath -Name "DisabledByDefault" -Value (if ($protocolConfig.enabled) { 0 } else { 1 }) -Type DWord -Force
        Set-ItemProperty -Path $clientKeyPath -Name "Enabled" -Value (if ($protocolConfig.enabled) { 1 } else { 0 }) -Type DWord -Force
        Write-Log "Configured $protocolName Client: Enabled=$($protocolConfig.enabled)"

        # Server settings
        $serverKeyPath = Join-Path -Path $protocolKeyPath -ChildPath "Server"
        if (-not (Test-Path -Path $serverKeyPath)) {
            New-Item -Path $serverKeyPath -Force | Out-Null
        }
        Set-ItemProperty -Path $serverKeyPath -Name "DisabledByDefault" -Value (if ($protocolConfig.enabled) { 0 } else { 1 }) -Type DWord -Force
        Set-ItemProperty -Path $serverKeyPath -Name "Enabled" -Value (if ($protocolConfig.enabled) { 1 } else { 0 }) -Type DWord -Force
        Write-Log "Configured $protocolName Server: Enabled=$($protocolConfig.enabled)"
    }

    # Configure Cipher Suites
    Write-Log "Configuring cipher suites..."
    # Disabling specific disallowed cipher suites (example - actual list can be long)
    if ($Settings.cipherSuites.disallowed) {
        foreach ($cipherSuiteName in $Settings.cipherSuites.disallowed) {
            $cipherKeyPath = Join-Path -Path $SchannelCiphersKey -ChildPath $cipherSuiteName
            if (Test-Path -Path $cipherKeyPath) { # Only try to disable if it exists
                Set-ItemProperty -Path $cipherKeyPath -Name "Enabled" -Value 0 -Type DWord -Force
                Write-Log "Disabled cipher suite: $cipherSuiteName"
            } else {
                Write-Log "Cipher suite $cipherSuiteName not found, skipping disable." -Level "WARNING"
            }
        }
    }

    # Set allowed cipher suite order
    if ($Settings.cipherSuites.allowed) {
        Write-Log "Setting cipher suite order..."
        try {
            Set-ItemProperty -Path $CryptographyConfigKey -Name "Functions" -Value $Settings.cipherSuites.allowed -Type MultiString -Force
            Write-Log "Successfully set cipher suite order."
        }
        catch {
            Write-Log "Failed to set cipher suite order. Error: $($_.Exception.Message)" -Level "ERROR"
            Write-Log "Make sure the Cryptography\Configuration\Local\SSL\00010002 key exists. It might need to be created manually or by other GPO." -Level "WARNING"
        }
    }


    # Configure .NET Framework Settings
    Write-Log "Configuring .NET Framework settings..."
    if ($Settings.dotNetSettings) {
        $schUseStrongCrypto = if ($Settings.dotNetSettings.schUseStrongCrypto) { 1 } else { 0 }
        $systemDefaultTlsVersions = if ($Settings.dotNetSettings.systemDefaultTlsVersions) { 1 } else { 0 }

        # .NET v4.0.30319
        if (-not (Test-Path -Path $DotNetFrameworkKey)) { New-Item -Path $DotNetFrameworkKey -Force | Out-Null }
        Set-ItemProperty -Path $DotNetFrameworkKey -Name "SchUseStrongCrypto" -Value $schUseStrongCrypto -Type DWord -Force
        Write-Log "Set $DotNetFrameworkKey\SchUseStrongCrypto to $schUseStrongCrypto"
        Set-ItemProperty -Path $DotNetFrameworkKey -Name "SystemDefaultTlsVersions" -Value $systemDefaultTlsVersions -Type DWord -Force
        Write-Log "Set $DotNetFrameworkKey\SystemDefaultTlsVersions to $systemDefaultTlsVersions"

        # .NET v4.0.30319 (Wow6432Node)
        if (-not (Test-Path -Path $DotNetFrameworkWow6432NodeKey)) { New-Item -Path $DotNetFrameworkWow6432NodeKey -Force | Out-Null }
        Set-ItemProperty -Path $DotNetFrameworkWow6432NodeKey -Name "SchUseStrongCrypto" -Value $schUseStrongCrypto -Type DWord -Force
        Write-Log "Set $DotNetFrameworkWow6432NodeKey\SchUseStrongCrypto to $schUseStrongCrypto"
        Set-ItemProperty -Path $DotNetFrameworkWow6432NodeKey -Name "SystemDefaultTlsVersions" -Value $systemDefaultTlsVersions -Type DWord -Force
        Write-Log "Set $DotNetFrameworkWow6432NodeKey\SystemDefaultTlsVersions to $systemDefaultTlsVersions"
    }

    Write-Log "TLS configuration script completed successfully."
}
catch {
    Write-Log "An unexpected error occurred: $($_.Exception.Message)" -Level "FATAL"
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "FATAL"
    exit 1
}

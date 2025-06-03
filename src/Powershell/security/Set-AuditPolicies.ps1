# Set-AuditPolicies.ps1
# This script configures system audit policies based on a provided policies object.

param (
    [Parameter(Mandatory = $true)]
    [object]$Policies, # This object should be the auditPolicies section from the JSON

    [Parameter(Mandatory = $false)]
    [bool]$EnforceSettings = $true,

    [Parameter(Mandatory = $false)]
    [bool]$BackupSettings = $true,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\AuditPolicyConfiguration.log"
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
function Backup-AuditPolicy {
    param(
        [string]$BackupFilePath
    )
    Write-Log "Backing up current audit policy to $BackupFilePath..."
    try {
        if (-not (Test-Path (Split-Path $BackupFilePath -Parent))) {
            New-Item -ItemType Directory -Path (Split-Path $BackupFilePath -Parent) -Force -ErrorAction Stop | Out-Null
        }
        auditpol /backup /file:"$BackupFilePath" | Out-Null
        Write-Log "Audit policy successfully backed up to $BackupFilePath."
    }
    catch {
        $errorMessage = $_.Exception.Message
        # auditpol.exe might write to stderr for success messages too, check output
        if ($_.FullyQualifiedErrorId -like "*NativeCommandError*" -and ($_.Exception.Message -match "The operation completed successfully")) {
             Write-Log "Audit policy successfully backed up to $BackupFilePath (message via stderr)."
        } else {
            Write-Log "Failed to back up audit policy. Error: $errorMessage" -Level "ERROR"
            throw "Audit policy backup failed."
        }
    }
}

# --- Helper to Convert JSON Subcategory Name to AuditPol Format ---
# Example: "credentialValidation" -> "Credential Validation"
function ConvertTo-AuditPolSubcategoryName {
    param ([string]$JsonName)
    return ($JsonName -replace '([A-Z])', ' $1').Trim()
}


# --- Main Script Logic ---
try {
    Write-Log "Starting audit policy configuration script."

    # Check for Admin Privileges
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "This script requires Administrator privileges to manage audit policies." -Level "ERROR"
        throw "Administrator privileges required."
    }

    # Define paths - ScriptRoot might still be useful for backup path construction
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    # $ConfigFile = Join-Path -Path $ScriptRoot -ChildPath "..\..\config\security-baseline.json" # REMOVED

    # Validate input Policies object
    if (-not $Policies) {
        Write-Log "The -Policies parameter is null. Configuration cannot be applied." -Level "ERROR"
        throw "Policies object not provided."
    }
    # $AuditPolicySettings will now be the $Policies parameter directly.
    # Write-Log "Using provided audit policies object." # Optional

    # Backup current settings
    if ($BackupSettings -and $EnforceSettings) {
        $timestamp = Get-Date -Format "yyyyMMddHHmmss"
        $backupDir = Join-Path -Path (Split-Path $LogPath -Parent) -ChildPath "AuditPolicyBackups"
        $backupFile = Join-Path -Path $backupDir -ChildPath "AuditPolicyBackup-$timestamp.csv" # auditpol backup is a CSV
        Backup-AuditPolicy -BackupFilePath $backupFile
    }

    if (-not $EnforceSettings) {
        Write-Log "EnforceSettings is set to false. Exiting without applying audit policy settings."
        exit 0
    }

    Write-Log "Applying audit policy settings..."

    # Process audit policies
    foreach ($categoryKey in $Policies.PSObject.Properties.Name) {
        $categoryObject = $Policies.$categoryKey
        Write-Log "Processing category: '$categoryKey'"
        foreach ($subcategoryKey in $categoryObject.PSObject.Properties.Name) {
            $policyValue = $categoryObject.$subcategoryKey
            # Convert JSON key to AuditPol subcategory name (e.g., credentialValidation -> "Credential Validation")
            $subcategoryName = ConvertTo-AuditPolSubcategoryName -JsonName $subcategoryKey

            Write-Log "Setting policy for Subcategory: '$subcategoryName' to '$policyValue'"

            $successArg = "/success:disable"
            $failureArg = "/failure:disable"

            if ($policyValue -eq "Success") {
                $successArg = "/success:enable"
            } elseif ($policyValue -eq "Failure") {
                $failureArg = "/failure:enable"
            } elseif ($policyValue -eq "Success,Failure" -or $policyValue -eq "Failure,Success") {
                $successArg = "/success:enable"
                $failureArg = "/failure:enable"
            } elseif ($policyValue -eq "No Auditing" -or $policyValue -eq "") {
                # No Auditing means both are disabled
            } else {
                Write-Log "Invalid policy value '$policyValue' for subcategory '$subcategoryName'. Skipping." -Level "WARNING"
                continue
            }

            $auditPolArgs = "/set /subcategory:`"$subcategoryName`" $successArg $failureArg"
            Write-Log "Executing: auditpol $auditPolArgs"

            try {
                Invoke-Expression "auditpol $auditPolArgs" | Out-Null
                # Check for errors from auditpol (it might not throw terminating errors)
                if ($LASTEXITCODE -ne 0) {
                    # Attempt to get error output if possible (may require more complex handling for stderr)
                    Write-Log "auditpol.exe exited with code $LASTEXITCODE for subcategory '$subcategoryName'." -Level "ERROR"
                } else {
                    Write-Log "Successfully set audit policy for subcategory '$subcategoryName'."
                }
            }
            catch {
                Write-Log "Failed to set audit policy for subcategory '$subcategoryName'. Error: $($_.Exception.Message)" -Level "ERROR"
                # Continue to next subcategory
            }
        }
    }

    Write-Log "Audit policy configuration script completed."
}
catch {
    Write-Log "A critical error occurred: $($_.Exception.Message)" -Level "FATAL"
    if ($_.ScriptStackTrace) {
        Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "FATAL"
    }
    # Ensure non-zero exit code for critical errors
    exit 1
}

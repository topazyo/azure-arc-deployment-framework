# Set-AuditPolicies.ps1
# This script configures system audit policies based on a JSON configuration file.

param (
    [Parameter(Mandatory = $false)]
    [bool]$EnforceSettings = $true,

    [Parameter(Mandatory = $false)]
    [bool]$BackupSettings = $true,

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\AuditPolicyConfiguration.log"
)

# --- Logging (shared utility) ---
$ScriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} elseif ($PSCommandPath) {
    Split-Path -Parent $PSCommandPath
} elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    (Get-Location).Path
}

if (-not (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
    . (Join-Path $ScriptRoot '..\utils\Write-Log.ps1')
}

if (-not (Get-Command Test-IsAdministrator -ErrorAction SilentlyContinue)) {
    . (Join-Path $ScriptRoot '..\utils\Test-IsAdministrator.ps1')
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
        Invoke-Expression "auditpol /backup /file:`"$BackupFilePath`"" | Out-Null
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
    param (
        [Parameter(Mandatory)]
        [object]$JsonName
    )

    # Normalize input (string, char[], string[], nested arrays) to a plain string.
    $normalized = $JsonName
    if ($normalized -is [System.Collections.IEnumerable] -and -not ($normalized -is [string])) {
        $normalized = -join $normalized
    }
    $normalized = ([string]$normalized).Trim()

    # If the input already looks like "C R E D ...", collapse it first.
    if ($normalized -match '^[A-Za-z](?:\s+[A-Za-z])+$') {
        $normalized = ($normalized -replace '\s+', '')
    }

    # Normalize aggressively: keep only letters/digits and key separators.
    # This handles inputs like "C R E D ..." (or other separator chars) by collapsing to "CREDENTIALVALIDATION".
    $compact = -join ($normalized.ToCharArray() | Where-Object {
        [char]::IsLetterOrDigit($_) -or $_ -eq '_' -or $_ -eq '-'
    })

    # Convert camelCase/PascalCase + underscores/dashes to spaced words.
    $spaced = ($compact -replace '[_-]+', ' ')
    $spaced = ($spaced -replace '(?<=[a-z0-9])(?=[A-Z])', ' ')
    $spaced = $spaced.Trim()

    # Known auditpol subcategories are title-cased with spaces.
    # This also fixes scenarios where original casing was lost (e.g. "CREDENTIALVALIDATION").
    $compactKey = ($compact -replace '[_-]+', '').ToLowerInvariant()
    switch ($compactKey) {
        'credentialvalidation' { return 'Credential Validation' }
        'processcreation'      { return 'Process Creation' }
        'filesystem'           { return 'File System' }
        'logon'                { return 'Logon' }
    }

    # Title-case for auditpol display.
    return (Get-Culture).TextInfo.ToTitleCase($spaced.ToLowerInvariant())
}


# --- Main Script Logic ---
try {
    Write-Log "Starting audit policy configuration script."

    # Check for Admin Privileges
    if (-not (Test-IsAdministrator)) {
        Write-Log "This script requires Administrator privileges to manage audit policies." -Level "ERROR"
        throw "Administrator privileges required."
    }

    # Define paths
    $ConfigFile = Join-Path -Path $ScriptRoot -ChildPath "..\..\config\security-baseline.json"
    $ConfigFile = [System.IO.Path]::GetFullPath($ConfigFile)

    # Read configuration
    Write-Log "Reading configuration from $ConfigFile..."
    if (-not (Test-Path -Path $ConfigFile)) {
        Write-Log "Configuration file $ConfigFile not found." -Level "ERROR"
        throw "Configuration file not found."
    }
    $Config = Get-Content -Path $ConfigFile | ConvertFrom-Json
    $AuditPolicySettings = $Config.auditPolicies

    if (-not $AuditPolicySettings) {
        Write-Log "auditPolicies section not found in the configuration file." -Level "ERROR"
        throw "auditPolicies section not found."
    }

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
    foreach ($categoryKey in @($AuditPolicySettings.PSObject.Properties.Name)) {
        $categoryObject = $AuditPolicySettings.$categoryKey
        Write-Log "Processing category: '$categoryKey'"
        foreach ($subcategoryKey in @($categoryObject.PSObject.Properties.Name)) {
            $policyValue = $categoryObject.$subcategoryKey
            # Convert JSON key to AuditPol subcategory name (e.g., credentialValidation -> "Credential Validation")
            $subcategoryName = ConvertTo-AuditPolSubcategoryName -JsonName $subcategoryKey
            # Normalize again defensively in case the first conversion produced an enumerable (which PowerShell
            # would otherwise stringify as spaced letters when interpolated into strings).
            $subcategoryName = ConvertTo-AuditPolSubcategoryName -JsonName $subcategoryName

            # Force to a plain string (arrays/enumerables stringify as spaced letters in interpolation).
            if ($subcategoryName -is [System.Collections.IEnumerable] -and -not ($subcategoryName -is [string])) {
                $subcategoryName = -join $subcategoryName
            }
            $subcategoryName = ([string]$subcategoryName).Trim()

            # Final guard: if the name still looks like spaced letters ("L O G O N"), collapse and re-convert.
            if (([string]$subcategoryName) -match '^[A-Za-z](?:\s+[A-Za-z])+$') {
                $collapsed = ($subcategoryName -replace '\s+', '')
                $subcategoryName = ConvertTo-AuditPolSubcategoryName -JsonName $collapsed
            }
            
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

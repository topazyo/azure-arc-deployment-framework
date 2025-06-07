# Test-AuditPolicy.ps1
# This script tests current system audit policy settings against a defined baseline.
# TODO: Enhance error handling for unexpected auditpol output formats.

Function Test-AuditPolicy {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$BaselineSettings, # Expected to be the auditPolicies section from a baseline JSON

        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME, # auditpol is local, ServerName is for context

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\TestAuditPolicy_Activity.log"
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

    # --- Helper to Convert JSON Subcategory Name to AuditPol Format ---
    function ConvertTo-AuditPolSubcategoryName {
        param ([string]$JsonName)
        # Simple conversion: insert space before capital letters, then trim.
        # E.g., credentialValidation -> Credential Validation
        # E.g., ipsecDriver -> IPsec Driver (assuming script handles this if needed)
        return ($JsonName -replace '([A-Z])', ' $1').Trim()
    }

    # --- Helper to normalize auditpol output strings to baseline strings ---
    function Normalize-AuditPolSetting {
        param ([string]$AuditPolSetting)
        if ([string]::IsNullOrWhiteSpace($AuditPolSetting)) { return "No Auditing" } # Treat empty as No Auditing
        switch -regex ($AuditPolSetting.Trim()) {
            "Success and Failure" { return "Success,Failure" }
            "Success"             { return "Success" }
            "Failure"             { return "Failure" }
            "No Auditing"         { return "No Auditing" }
            default {
                Write-Log "Unrecognized AuditPol Inclusion Setting: '$AuditPolSetting'. Treating as 'Unknown'." -Level "WARNING"
                return "Unknown" # Or handle as error
            }
        }
    }

    Write-Log "Starting Test-AuditPolicy on server '$ServerName'."
    if ($ServerName -ne $env:COMPUTERNAME) {
        Write-Log "Warning: auditpol.exe operates locally. '$ServerName' parameter is for reporting context." -Level "WARNING"
    }

    # --- Administrator Privilege Check ---
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Administrator privileges are required to run 'auditpol /get'. Script cannot proceed." -Level "ERROR"
        return [PSCustomObject]@{ Compliant = $false; Checks = @(); Timestamp = (Get-Date -Format o); ServerName = $ServerName; Error = "Administrator privileges required."}
    } else {
        Write-Log "Running with Administrator privileges."
    }

    $allChecks = [System.Collections.ArrayList]::new()
    $script:overallCompliant = $true

    function Add-AuditCheckResult {
        param([string]$Category, [string]$Subcategory, [bool]$IsCompliant, [object]$Expected, [object]$Actual, [string]$Details, [string]$RemediationSuggestion = "")
        $check = [PSCustomObject]@{ Category = $Category; Subcategory = $Subcategory; Compliant = $IsCompliant; Expected = $Expected; Actual = $Actual; Details = $Details; Remediation = $RemediationSuggestion }
        $allChecks.Add($check) | Out-Null
        if (-not $IsCompliant) { $script:overallCompliant = $false }
        Write-Log "Check: Category='$Category', Subcategory='$Subcategory': Compliant=$IsCompliant. Expected='$Expected', Actual='$Actual'." -Level (if($IsCompliant){"DEBUG"}else{"WARNING"})
    }

    $auditPoliciesBaseline = $BaselineSettings.auditPolicies
    if (-not $auditPoliciesBaseline) {
        Write-Log "No 'auditPolicies' section found in BaselineSettings. Cannot perform checks." -Level "ERROR"
        return [PSCustomObject]@{ Compliant = $false; Checks = $allChecks; Timestamp = (Get-Date -Format o); ServerName = $ServerName; Error = "Missing auditPolicies baseline settings."}
    }

    # --- Get Current Audit Policy ---
    $currentPoliciesRaw = ""
    $currentPoliciesLookup = @{}
    try {
        Write-Log "Executing 'auditpol /get /category:* /r' to retrieve current audit policy."
        # Using Invoke-Expression as auditpol is an external command
        $currentPoliciesRaw = Invoke-Expression "auditpol /get /category:* /r"
        if ($LASTEXITCODE -ne 0 -and -not ($Error[0].ToString() -match "The operation completed successfully")) {
            throw "auditpol /get failed with exit code $LASTEXITCODE. Error: $($Error[0])"
        }

        # Convert CSV output (skipping header) to PSCustomObjects and then to a lookup hashtable
        # Auditpol output might have a leading blank line or informational lines before CSV
        $csvLines = $currentPoliciesRaw | Where-Object { $_ -match '^\s*".*?",' } # Try to find CSV lines
        if ($csvLines.Count -eq 0) { throw "Could not parse CSV output from auditpol."}

        # Need to handle the "Machine Name" column potentially having spaces if not quoted by auditpol /r
        # ConvertFrom-Csv assumes comma delimiter. If subcategory names have commas, this could be an issue.
        # However, standard subcategory names do not.
        $currentPolicyObjects = $csvLines | ConvertFrom-Csv -ErrorAction Stop

        foreach($policyObj in $currentPolicyObjects){
            # Standardize Subcategory name from auditpol output for lookup (sometimes it might have extra spaces)
            $cleanSubcategoryName = $policyObj.Subcategory.Trim()
            $currentPoliciesLookup[$cleanSubcategoryName] = Normalize-AuditPolSetting -AuditPolSetting $policyObj."Inclusion Setting"
        }
        Write-Log "Successfully retrieved and parsed $($currentPoliciesLookup.Count) current audit policy settings."
    } catch {
        Write-Log "Failed to get or parse current audit policy. Error: $($_.Exception.Message)" -Level "ERROR"
        return [PSCustomObject]@{ Compliant = $false; Checks = $allChecks; Timestamp = (Get-Date -Format o); ServerName = $ServerName; Error = "Failed to retrieve audit policy: $($_.Exception.Message)"}
    }

    # --- Compare with Baseline ---
    Write-Log "Comparing current audit policy with baseline..."
    foreach ($categoryKey in $auditPoliciesBaseline.PSObject.Properties.Name) {
        $categoryObject = $auditPoliciesBaseline.$categoryKey
        Write-Log "Processing baseline category: '$categoryKey'" -Level "DEBUG"
        foreach ($subcategoryJsonKey in $categoryObject.PSObject.Properties.Name) {
            $expectedSetting = $categoryObject.$subcategoryJsonKey
            $auditPolSubcategoryName = ConvertTo-AuditPolSubcategoryName -JsonName $subcategoryJsonKey

            $actualSetting = "NotFoundInCurrentPolicy" # Default if not found
            if ($currentPoliciesLookup.ContainsKey($auditPolSubcategoryName)) {
                $actualSetting = $currentPoliciesLookup[$auditPolSubcategoryName]
            } else {
                Write-Log "Subcategory '$auditPolSubcategoryName' (from baseline key '$subcategoryJsonKey') not found in current auditpol output." -Level "WARNING"
            }

            # Normalize baseline value "Success,Failure" to match normalized "Success and Failure"
            $normalizedExpectedSetting = if ($expectedSetting -eq "Success,Failure") { "Success,Failure" } else { $expectedSetting }


            $isCompliant = ($actualSetting -eq $normalizedExpectedSetting)
            if ($actualSetting -eq "Unknown") { $isCompliant = $false } # If we couldn't parse the auditpol value

            Add-AuditCheckResult -Category $categoryKey -Subcategory $auditPolSubcategoryName `
                -IsCompliant $isCompliant `
                -Expected $expectedSetting -Actual $actualSetting `
                -Details "Compares baseline setting with 'auditpol /get /category:* /r' output for subcategory." `
                -RemediationSuggestion "Set audit policy for '$auditPolSubcategoryName' to '$expectedSetting' using auditpol /set or Group Policy."
        }
    }

    Write-Log "Test-AuditPolicy script finished. Overall Compliance: $script:overallCompliant."
    return [PSCustomObject]@{
        Compliant           = $script:overallCompliant
        Checks              = $allChecks
        Timestamp           = (Get-Date -Format o)
        ServerName          = $ServerName
    }
}

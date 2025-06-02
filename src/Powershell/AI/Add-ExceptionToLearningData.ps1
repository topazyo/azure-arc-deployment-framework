# Add-ExceptionToLearningData.ps1
# This script adds structured information about exceptions and associated context to a CSV learning dataset.
# TODO: Implement more sophisticated CSV header management for evolving schemas.

Function Add-ExceptionToLearningData {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [object]$ExceptionObject, # Should be System.Management.Automation.ErrorRecord or System.Exception

        [Parameter(Mandatory=$false)]
        [hashtable]$AssociatedData,

        [Parameter(Mandatory=$false)]
        [string]$LearningDataPath = "C:\ProgramData\AzureArcFramework\AI\LearningData.csv",

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\AddExceptionToLearningData_Activity.log"
    )

    # --- Logging Function (for script activity) ---
    function Write-Log {
        param (
            [string]$Message,
            [string]$Level = "INFO", # INFO, WARNING, ERROR
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
            Write-Host $logEntry # Fallback to console
        }
    }

    Write-Log "Starting Add-ExceptionToLearningData script."

    if (-not $ExceptionObject) {
        Write-Log "ExceptionObject parameter is null. Script cannot proceed." -Level "ERROR"
        return $false # Or throw
    }

    $actualException = $null
    $errorRecord = $null

    if ($ExceptionObject -is [System.Management.Automation.ErrorRecord]) {
        $errorRecord = $ExceptionObject
        $actualException = $errorRecord.Exception
        Write-Log "Processing System.Management.Automation.ErrorRecord."
    } elseif ($ExceptionObject -is [System.Exception]) {
        $actualException = $ExceptionObject
        Write-Log "Processing System.Exception."
    } else {
        Write-Log "ExceptionObject is not of type ErrorRecord or Exception. Type: $($ExceptionObject.GetType().FullName)" -Level "ERROR"
        return $false # Or throw
    }

    # --- Extract Features from Exception ---
    $features = [ordered]@{} # Use ordered dictionary to maintain some column order in CSV
    $features.Add("CaptureTimestamp", (Get-Date -Format o))
    
    if ($actualException) {
        $features.Add("ExceptionType", $actualException.GetType().FullName)
        $features.Add("ExceptionMessage", $actualException.Message)
        # StackTrace can be multi-line; ensure it's handled well by CSV (Export-Csv usually quotes it)
        $features.Add("StackTrace", $actualException.StackTrace) 
        if ($actualException.InnerException) {
            $features.Add("InnerExceptionType", $actualException.InnerException.GetType().FullName)
            $features.Add("InnerExceptionMessage", $actualException.InnerException.Message)
        } else {
            $features.Add("InnerExceptionType", $null)
            $features.Add("InnerExceptionMessage", $null)
        }
    } else { # Should not happen if initial type check is good, but as a fallback
        $features.Add("ExceptionType", "N/A (Original object was ErrorRecord without Exception property)")
        $features.Add("ExceptionMessage", $errorRecord.ToString()) # Use ErrorRecord string representation
        $features.Add("StackTrace", $null)
        $features.Add("InnerExceptionType", $null)
        $features.Add("InnerExceptionMessage", $null)
    }

    if ($errorRecord) {
        $features.Add("ErrorRecord_CategoryInfo", $errorRecord.CategoryInfo.ToString())
        $features.Add("ErrorRecord_TargetObjectType", $errorRecord.TargetObject.GetType().FullName)
        if ($errorRecord.InvocationInfo) {
            $features.Add("ErrorRecord_ScriptName", $errorRecord.InvocationInfo.ScriptName)
            $features.Add("ErrorRecord_CommandName", $errorRecord.InvocationInfo.MyCommand.Name)
            $features.Add("ErrorRecord_LineNumber", $errorRecord.InvocationInfo.ScriptLineNumber)
            $features.Add("ErrorRecord_OffsetInLine", $errorRecord.InvocationInfo.OffsetInLine) # Sometimes useful
        } else {
            $features.Add("ErrorRecord_ScriptName", $null)
            $features.Add("ErrorRecord_CommandName", $null)
            $features.Add("ErrorRecord_LineNumber", $null)
            $features.Add("ErrorRecord_OffsetInLine", $null)
        }
        $features.Add("ErrorRecord_FullyQualifiedErrorId", $errorRecord.FullyQualifiedErrorId)
    } else { # Fill with nulls if it was a raw System.Exception
        $features.Add("ErrorRecord_CategoryInfo", $null)
        $features.Add("ErrorRecord_TargetObjectType", $null)
        $features.Add("ErrorRecord_ScriptName", $null)
        $features.Add("ErrorRecord_CommandName", $null)
        $features.Add("ErrorRecord_LineNumber", $null)
        $features.Add("ErrorRecord_OffsetInLine", $null)
        $features.Add("ErrorRecord_FullyQualifiedErrorId", $null)
    }

    # --- Combine with AssociatedData ---
    if ($AssociatedData) {
        Write-Log "Adding $($AssociatedData.Count) associated data items."
        foreach ($key in $AssociatedData.Keys) {
            $prefixedKey = "Assoc_$key" # Prefix to avoid collision with exception fields
            if ($features.ContainsKey($prefixedKey)) {
                Write-Log "AssociatedData key '$key' (prefixed to '$prefixedKey') collides with an existing feature key. It will be overwritten by AssociatedData." -Level "WARNING"
            }
            $features.Add($prefixedKey, $AssociatedData[$key])
        }
    }

    # --- Append to CSV ---
    $learningDataFileExists = Test-Path -Path $LearningDataPath -PathType Leaf
    
    try {
        Write-Log "Preparing to append data to $LearningDataPath. File exists: $learningDataFileExists"
        $dataToExport = [PSCustomObject]$features

        if ($learningDataFileExists) {
            # Basic check: If appending, just append. Export-Csv handles quoting.
            # More robust: Read existing headers, compare, align. This is complex and deferred.
            # For now, we rely on Export-Csv -Append 's behavior.
            # If headers mismatch, it might only populate existing columns or add new ones (can be messy).
            Write-Log "File exists. Appending data. Note: Header consistency is not deeply checked by this version." -Level "WARNING"
        } else {
            Write-Log "File does not exist. Creating new CSV with headers."
            # Ensure directory exists for the new file
             $DirectoryPath = Split-Path -Path $LearningDataPath -Parent
             if (-not (Test-Path -Path $DirectoryPath -PathType Container)) {
                 Write-Log "Creating directory for learning data: $DirectoryPath"
                 New-Item -ItemType Directory -Path $DirectoryPath -Force | Out-Null
             }
        }
        
        $dataToExport | Export-Csv -Path $LearningDataPath -Append -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        Write-Log "Successfully appended data to $LearningDataPath."
        return $true
    } catch {
        Write-Log "Failed to write to CSV file '$LearningDataPath'. Error: $($_.Exception.Message)" -Level "ERROR"
        Write-Log "Data that was not saved: $($features | Out-String)" -Level "DEBUG" # Log the data if it failed
        return $false
    }
    finally {
        Write-Log "Add-ExceptionToLearningData script finished."
    }
}

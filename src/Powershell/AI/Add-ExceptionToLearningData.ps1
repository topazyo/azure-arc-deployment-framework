# Add-ExceptionToLearningData.ps1
# This script adds structured information about exceptions and associated context to a CSV learning dataset.
# TODO: Implement more sophisticated CSV header management for evolving schemas.

[CmdletBinding()]
param(
    [Parameter()] [object]$ExceptionObject,
    [Parameter()] [hashtable]$AssociatedData,
    [Parameter()] [string]$LearningDataPath = "C:\ProgramData\AzureArcFramework\AI\LearningData.csv",
    [Parameter()] [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\AddExceptionToLearningData_Activity.log"
)

if (-not (Get-Command -Name Write-Log -ErrorAction SilentlyContinue)) {
    function Write-Log {
        param (
            [string]$Message,
            [string]$Level = "INFO",
            [string]$Path = $LogPath
        )
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$Level] $Message"
        try {
            if (-not (Test-Path (Split-Path $Path -Parent) -PathType Container)) {
                New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force -ErrorAction Stop | Out-Null
            }
            Add-Content -Path $Path -Value $logEntry -ErrorAction Stop
        } catch {
            Write-Warning "ACTIVITY_LOG_FAIL: Failed to write to activity log file $Path. Error: $($_.Exception.Message). Logging to console instead."
            Write-Host $logEntry
        }
    }
}

Function Add-ExceptionToLearningData {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)]
        [object]$ExceptionObject, # Should be System.Management.Automation.ErrorRecord or System.Exception

        [Parameter(Mandatory=$false)]
        [hashtable]$AssociatedData,

        [Parameter(Mandatory=$false)]
        [string]$LearningDataPath = "C:\ProgramData\AzureArcFramework\AI\LearningData.csv",

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\AddExceptionToLearningData_Activity.log"
    )

    Write-Log -Message "Starting Add-ExceptionToLearningData script." -Path $LogPath

    if (-not $ExceptionObject) {
        Write-Log -Message "ExceptionObject parameter is null. Script cannot proceed." -Level "ERROR" -Path $LogPath
        return $false # Or throw
    }

    function Get-TypeNameSafe {
        param($Object)
        if (-not $Object) { return $null }

        $customGetType = $Object.PSObject.Properties['GetType']
        if ($customGetType -and $customGetType.Value -is [scriptblock]) {
            try {
                $result = & $customGetType.Value
                if ($result -and $result.FullName) { return $result.FullName }
            } catch {}
            try {
                $result = & ($customGetType.Value.GetNewClosure())
                if ($result -and $result.FullName) { return $result.FullName }
            } catch { return $null }
        }

        try { return $Object.GetType().FullName } catch { return $null }
    }

    function Get-StringSafe {
        param($Object)
        if (-not $Object) { return $null }

        $customToString = $Object.PSObject.Properties['ToString']
        if ($customToString -and $customToString.Value -is [scriptblock]) {
            try {
                $result = & $customToString.Value
                if ($null -ne $result) { return $result }
            } catch {}
            try { return & ($customToString.Value.GetNewClosure()) } catch { return $null }
        }

        try { return $Object.ToString() } catch { return $null }
    }

    function Get-NestedPropertyValue {
        param($Object, [string[]]$PropertyPath)
        $current = $Object
        foreach ($name in $PropertyPath) {
            if (-not $current) { return $null }
            if ($current.PSObject.Properties.Name -contains $name) {
                $current = $current.$name
            } else {
                return $null
            }
        }
        return $current
    }

    $actualException = $null
    $errorRecord = $null

    if ($ExceptionObject -is [System.Management.Automation.ErrorRecord]) {
        $errorRecord = $ExceptionObject
        $actualException = $errorRecord.Exception
        Write-Log -Message "Processing System.Management.Automation.ErrorRecord." -Path $LogPath
    } elseif ($ExceptionObject -is [System.Exception]) {
        $actualException = $ExceptionObject
        Write-Log -Message "Processing System.Exception." -Path $LogPath
    } elseif ($ExceptionObject.PSObject.Properties.Name -contains 'Exception') {
        # Accept objects that look like ErrorRecords for testing and custom callers
        $errorRecord = $ExceptionObject
        $actualException = $ExceptionObject.Exception
        Write-Log -Message ("DEBUG ErrorRecord-like input: " + ($ExceptionObject | ConvertTo-Json -Depth 4)) -Level "DEBUG" -Path $LogPath
        Write-Log -Message "Processing object with ErrorRecord-like shape." -Path $LogPath
    } else {
        Write-Log -Message "ExceptionObject is not of type ErrorRecord or Exception. Type: $($ExceptionObject.GetType().FullName)" -Level "ERROR" -Path $LogPath
        return $false # Or throw
    }

    # --- Extract Features from Exception ---
    $features = [ordered]@{} # Use ordered dictionary to maintain some column order in CSV
    $features.Add("CaptureTimestamp", (Get-Date -Format o))
    
    if ($actualException) {
        $features.Add("ExceptionType", (Get-TypeNameSafe $actualException))
        $features.Add("ExceptionMessage", $actualException.Message)
        # StackTrace can be multi-line; ensure it's handled well by CSV (Export-Csv usually quotes it)
        $features.Add("StackTrace", $actualException.StackTrace) 
        if ($actualException.InnerException) {
            $features.Add("InnerExceptionType", (Get-TypeNameSafe $actualException.InnerException))
            $features.Add("InnerExceptionMessage", $actualException.InnerException.Message)
        } else {
            $features.Add("InnerExceptionType", $null)
            $features.Add("InnerExceptionMessage", $null)
        }
    } else { # Should not happen if initial type check is good, but as a fallback
        $features.Add("ExceptionType", "N/A (Original object was ErrorRecord without Exception property)")
        $features.Add("ExceptionMessage", (Get-StringSafe $errorRecord)) # Use ErrorRecord string representation
        $features.Add("StackTrace", $null)
        $features.Add("InnerExceptionType", $null)
        $features.Add("InnerExceptionMessage", $null)
    }

    if ($errorRecord) {
        $features.Add("ErrorRecord_CategoryInfo", (Get-StringSafe $errorRecord.CategoryInfo))
        $targetObjectType = Get-TypeNameSafe $errorRecord.TargetObject
        $features.Add("ErrorRecord_TargetObjectType", $targetObjectType)

        $scriptName = Get-NestedPropertyValue $errorRecord @('InvocationInfo','ScriptName')
        $commandName = Get-NestedPropertyValue $errorRecord @('InvocationInfo','MyCommand','Name')
        $lineNumber = Get-NestedPropertyValue $errorRecord @('InvocationInfo','ScriptLineNumber')
        if (-not $lineNumber -and $errorRecord.InvocationInfo -and ($errorRecord.InvocationInfo.PSObject.Properties.Name -contains 'ScriptLineNumber')) {
            # Fallback for loosely shaped ErrorRecord-like inputs
            $lineNumber = $errorRecord.InvocationInfo.ScriptLineNumber
        }
        if (-not $lineNumber -and ($errorRecord.PSObject.Properties.Name -contains 'ScriptLineNumber')) {
            $lineNumber = $errorRecord.ScriptLineNumber
        }

        $offsetInLine = Get-NestedPropertyValue $errorRecord @('InvocationInfo','OffsetInLine')
        if (-not $offsetInLine -and $errorRecord.InvocationInfo -and ($errorRecord.InvocationInfo.PSObject.Properties.Name -contains 'OffsetInLine')) {
            $offsetInLine = $errorRecord.InvocationInfo.OffsetInLine
        }
        if (-not $offsetInLine -and ($errorRecord.PSObject.Properties.Name -contains 'OffsetInLine')) {
            $offsetInLine = $errorRecord.OffsetInLine
        }

        $features.Add("ErrorRecord_ScriptName", $scriptName)
        $features.Add("ErrorRecord_CommandName", $commandName)
        $features.Add("ErrorRecord_ScriptLineNumber", $lineNumber)
        $features.Add("ErrorRecord_OffsetInLine", $offsetInLine)
        $features.Add("ErrorRecord_FullyQualifiedErrorId", $errorRecord.FullyQualifiedErrorId)
    } else { # Fill with nulls if it was a raw System.Exception
        $features.Add("ErrorRecord_CategoryInfo", $null)
        $features.Add("ErrorRecord_TargetObjectType", $null)
        $features.Add("ErrorRecord_ScriptName", $null)
        $features.Add("ErrorRecord_CommandName", $null)
        $features.Add("ErrorRecord_ScriptLineNumber", $null)
        $features.Add("ErrorRecord_OffsetInLine", $null)
        $features.Add("ErrorRecord_FullyQualifiedErrorId", $null)
    }

    # --- Combine with AssociatedData ---
    if ($AssociatedData) {
        Write-Log -Message "Adding $($AssociatedData.Count) associated data items." -Path $LogPath
        foreach ($key in $AssociatedData.Keys) {
            $prefixedKey = "Assoc_$key" # Prefix to avoid collision with exception fields
            if ($features.Keys -contains $prefixedKey) {
                Write-Log -Message "AssociatedData key '$key' (prefixed to '$prefixedKey') collides with an existing feature key. It will be overwritten by AssociatedData." -Level "WARNING" -Path $LogPath
            }
            $features.Add($prefixedKey, $AssociatedData[$key])
        }
    }

    # --- Append to CSV ---
    $learningDataFileExists = Test-Path -Path $LearningDataPath -PathType Leaf
    
    try {
        Write-Log -Message "Preparing to append data to $LearningDataPath. File exists: $learningDataFileExists" -Path $LogPath
        $dataToExport = [PSCustomObject]$features

        if ($learningDataFileExists) {
            Write-Log -Message "File exists. Appending data. Note: Header consistency is not deeply checked by this version." -Level "WARNING" -Path $LogPath
            $dataToExport | Export-Csv -Path $LearningDataPath -Append -NoTypeInformation -Encoding ([System.Text.Encoding]::UTF8) -ErrorAction Stop
        } else {
            Write-Log -Message "File does not exist. Creating new CSV with headers." -Path $LogPath
            $DirectoryPath = Split-Path -Path $LearningDataPath -Parent
            if (-not (Test-Path -Path $DirectoryPath -PathType Container)) {
                Write-Log -Message "Creating directory for learning data: $DirectoryPath" -Path $LogPath
                New-Item -ItemType Directory -Path $DirectoryPath -Force | Out-Null
            }
            $dataToExport | Export-Csv -Path $LearningDataPath -NoTypeInformation -Encoding ([System.Text.Encoding]::UTF8) -ErrorAction Stop
        }
        
        Write-Log -Message "Successfully appended data to $LearningDataPath." -Path $LogPath
        return $true
    } catch {
        Write-Log -Message "Failed to write to CSV file '$LearningDataPath'. Error: $($_.Exception.Message)" -Level "ERROR" -Path $LogPath
        Write-Log -Message "Data that was not saved: $($features | Out-String)" -Level "DEBUG" -Path $LogPath # Log the data if it failed
        return $false
    }
    finally {
        Write-Log -Message "Add-ExceptionToLearningData script finished." -Path $LogPath
    }
}

# If the script is invoked directly with parameters, forward to the function
if ($PSBoundParameters.Count -gt 0) {
    return Add-ExceptionToLearningData @PSBoundParameters
}

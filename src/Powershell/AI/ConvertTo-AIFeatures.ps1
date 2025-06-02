# ConvertTo-AIFeatures.ps1
# This script converts raw data into features suitable for AI model consumption.
# TODO: Implement more advanced feature engineering techniques (e.g., TF-IDF, proper OneHotEncoding, scaling).

Function ConvertTo-AIFeatures {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [object[]]$InputData,

        [Parameter(Mandatory=$false)]
        [object]$FeatureDefinition, # Can be a hashtable or path to JSON file

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\ConvertToAIFeatures_Activity.log"
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
            Write-Host $logEntry 
        }
    }

    Write-Log "Starting ConvertTo-AIFeatures script. InputData count: $($InputData.Count)."

    $loadedFeatureDef = $null
    if ($FeatureDefinition) {
        if ($FeatureDefinition -is [string]) { # Assume it's a path
            $featureDefPath = $FeatureDefinition
            Write-Log "Loading FeatureDefinition from path: $featureDefPath"
            if (Test-Path $featureDefPath -PathType Leaf) {
                try {
                    $loadedFeatureDef = Get-Content -Path $featureDefPath -Raw | ConvertFrom-Json -ErrorAction Stop
                    Write-Log "Successfully loaded FeatureDefinition from JSON."
                } catch {
                    Write-Log "Failed to load or parse FeatureDefinition JSON from '$featureDefPath'. Error: $($_.Exception.Message)" -Level "ERROR"
                }
            } else {
                Write-Log "FeatureDefinition path not found: $featureDefPath" -Level "ERROR"
            }
        } elseif ($FeatureDefinition -is [hashtable] -or $FeatureDefinition -is [pscustomobject]) {
            Write-Log "Using provided FeatureDefinition object."
            $loadedFeatureDef = $FeatureDefinition
        } else {
            Write-Log "Invalid FeatureDefinition parameter type: $($FeatureDefinition.GetType().FullName). Expected path (string) or object (hashtable/pscustomobject)." -Level "ERROR"
        }
    }

    $engineeredData = [System.Collections.ArrayList]::new()

    if (-not $loadedFeatureDef) {
        Write-Log "No valid FeatureDefinition provided or loaded. Using default hardcoded feature engineering."
        $defaultKeywords = @("error", "fail", "success", "warning", "timeout", "unavailable", "exception", "critical", "fatal")
        
        foreach ($item in $InputData) {
            $features = [ordered]@{}
            # $features.Add("InputObject_Original", $item) # Optional: include original for reference, can make output large

            # Default: Keyword counts from 'Message' property
            if ($item.PSObject.Properties['Message'] -and $item.Message -is [string]) {
                foreach ($keyword in $defaultKeywords) {
                    $count = ([regex]::Matches($item.Message, [regex]::Escape($keyword), "IgnoreCase")).Count
                    $features.Add("Feature_Message_Keyword_$(($keyword -replace '\s','_'))_Count", $count)
                }
            }

            # Default: Include EventId if it exists and is numeric
            if ($item.PSObject.Properties['EventId'] -and $item.EventId -match "^\d+$") { # Check if it's a string of digits or a number
                $features.Add("Feature_EventId", [int]$item.EventId)
            }
            
            # Default: Include Value if it exists and is numeric (example for performance counters)
            if ($item.PSObject.Properties['Value'] -and $item.Value -is [double] -or $item.Value -is [int] -or $item.Value -is [long]) {
                 $features.Add("Feature_Value", $item.Value)
            } elseif ($item.PSObject.Properties['Count'] -and $item.Count -is [double] -or $item.Count -is [int] -or $item.Count -is [long]) { # Common for grouped events
                 $features.Add("Feature_Count", $item.Count)
            }


            $engineeredData.Add([PSCustomObject]$features) | Out-Null
        }
    } else {
        Write-Log "Using FeatureDefinition to engineer features."
        foreach ($item in $InputData) {
            $features = [ordered]@{}
            # $features.Add("InputObject_Original", $item)

            # Process Text Properties
            if ($loadedFeatureDef.textProperties) {
                foreach ($textPropDef in $loadedFeatureDef.textProperties) {
                    $propName = $textPropDef.propertyName
                    if ($item.PSObject.Properties[$propName] -and $item.$propName -is [string]) {
                        $propValue = $item.$propName
                        if ($textPropDef.vectorization -eq "KeywordCount" -and $textPropDef.keywords) {
                            foreach ($keyword in $textPropDef.keywords) {
                                $count = ([regex]::Matches($propValue, [regex]::Escape($keyword), "IgnoreCase")).Count
                                $features.Add("Feature_$(($propName -replace '\s','_'))_Keyword_$(($keyword -replace '\s','_'))_Count", $count)
                            }
                        } elseif ($textPropDef.vectorization -eq "CategoricalMapping") {
                             Write-Log "FeatureDefinition: 'CategoricalMapping' for text is noted but not fully implemented in this version. Requires predefined categories." -Level "WARNING"
                             # Placeholder: $features.Add("Feature_$(($propName -replace '\s','_'))_Category", $propValue) # Or map to int if categories provided
                        } else {
                            Write-Log "FeatureDefinition: Unsupported text vectorization '$($textPropDef.vectorization)' for property '$propName'." -Level "WARNING"
                        }
                    } else { Write-Log "FeatureDefinition: Text property '$propName' not found or not a string in input item." -Level "DEBUG" }
                }
            }

            # Process Numerical Properties
            if ($loadedFeatureDef.numericalProperties) {
                foreach ($numPropDef in $loadedFeatureDef.numericalProperties) {
                    $propName = $numPropDef.propertyName
                    if ($item.PSObject.Properties[$propName] -and ($item.$propName -is [double] -or $item.$propName -is [int] -or $item.$propName -is [long])) {
                        if ($numPropDef.normalization -eq "None" -or -not $numPropDef.normalization) {
                            $features.Add("Feature_$(($propName -replace '\s','_'))", $item.$propName)
                        } else {
                            Write-Log "FeatureDefinition: Normalization type '$($numPropDef.normalization)' for numerical property '$propName' is noted but not implemented. Using raw value." -Level "WARNING"
                            $features.Add("Feature_$(($propName -replace '\s','_'))", $item.$propName) # Default to raw value
                        }
                    } else { Write-Log "FeatureDefinition: Numerical property '$propName' not found or not a number in input item." -Level "DEBUG" }
                }
            }

            # Process DateTime Properties
            if ($loadedFeatureDef.dateTimeProperties) {
                foreach ($dtPropDef in $loadedFeatureDef.dateTimeProperties) {
                    $propName = $dtPropDef.propertyName
                    if ($item.PSObject.Properties[$propName] -and $item.$propName -is [datetime]) {
                        $dtValue = $item.$propName
                        if ($dtPropDef.extract -contains "DayOfWeek") {
                            $features.Add("Feature_$(($propName -replace '\s','_'))_DayOfWeek", [int]$dtValue.DayOfWeek)
                        }
                        if ($dtPropDef.extract -contains "HourOfDay") {
                            $features.Add("Feature_$(($propName -replace '\s','_'))_HourOfDay", $dtValue.Hour)
                        }
                        # Add more extractions like Month, Year, Minute etc. if needed
                    } else { Write-Log "FeatureDefinition: DateTime property '$propName' not found or not a DateTime object in input item." -Level "DEBUG" }
                }
            }
            $engineeredData.Add([PSCustomObject]$features) | Out-Null
        }
    }

    Write-Log "ConvertTo-AIFeatures script finished. Processed $($InputData.Count) items, generated $($engineeredData.Count) feature sets."
    return $engineeredData
}

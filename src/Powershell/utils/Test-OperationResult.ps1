# Test-OperationResult.ps1
# This script tests the result of an operation based on its output object and expected conditions.
# TODO: Add more comparison operators for ExpectedProperties if needed (e.g., GreaterThan, LessThan directly).

Function Test-OperationResult {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$false)] # Allow null/empty if the operation itself might not produce output on failure
        [PSCustomObject]$OperationOutput,

        [Parameter(Mandatory=$false)]
        [string]$ExpectedStatus = "Success",

        [Parameter(Mandatory=$false)]
        [hashtable]$ExpectedProperties,

        [Parameter(Mandatory=$false)]
        [bool]$SuccessIfAllExpectedPropertiesMatch = $true,

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\TestOperationResult_Activity.log"
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

    Write-Log "Starting Test-OperationResult script."
    Write-Log "Parameters: ExpectedStatus='$ExpectedStatus', SuccessIfAllExpectedPropertiesMatch='$SuccessIfAllExpectedPropertiesMatch'."
    if ($ExpectedProperties) { Write-Log "ExpectedProperties provided: $($ExpectedProperties.Keys -join ', ')" -Level "DEBUG" }
    if ($OperationOutput) { Write-Log "OperationOutput received: $($OperationOutput | Out-String -Depth 2 -Width 120)" -Level "DEBUG"} else { Write-Log "OperationOutput is null."}


    $validationDetails = [System.Collections.ArrayList]::new()
    $statusCheckPassed = $false
    $actualStatus = $null

    # --- Status Check ---
    Write-Log "Performing Status Check..."
    if ($null -eq $OperationOutput) {
        $actualStatus = "NullObject"
        $statusCheckPassed = ($ExpectedStatus -eq "NullObject") # Pass only if specifically expecting null
        $validationDetails.Add([PSCustomObject]@{
            Check    = "OperationOutput Object"
            Expected = "Not Null (generally, unless ExpectedStatus is NullObject)"
            Actual   = "Null"
            Result   = if($statusCheckPassed){"Passed"}else{"Failed"}
            Message  = "OperationOutput object was null."
        }) | Out-Null
        Write-Log "OperationOutput is null. Status check: $($validationDetails[-1].Result)." -Level "WARNING"
    }
    elseif (-not $OperationOutput.PSObject.Properties['Status']) {
        $actualStatus = "StatusPropertyMissing"
        $statusCheckPassed = ($ExpectedStatus -eq "StatusPropertyMissing")
        $validationDetails.Add([PSCustomObject]@{
            Check    = "Status Property Existence"
            Expected = "Property 'Status' to exist"
            Actual   = "Missing"
            Result   = if($statusCheckPassed){"Passed"}else{"Failed"}
            Message  = "OperationOutput object lacks a 'Status' property."
        }) | Out-Null
        Write-Log "OperationOutput lacks a 'Status' property. Status check: $($validationDetails[-1].Result)." -Level "WARNING"
    } else {
        $actualStatus = $OperationOutput.Status
        if ($actualStatus -eq $ExpectedStatus) {
            $statusCheckPassed = $true
            $validationDetails.Add([PSCustomObject]@{
                Check    = "Status Value"
                Expected = $ExpectedStatus
                Actual   = $actualStatus
                Result   = "Passed"
                Message  = "Actual status '$actualStatus' matches expected status."
            }) | Out-Null
            Write-Log "Status check passed. Expected: '$ExpectedStatus', Actual: '$actualStatus'."
        } else {
            $statusCheckPassed = $false
            $validationDetails.Add([PSCustomObject]@{
                Check    = "Status Value"
                Expected = $ExpectedStatus
                Actual   = $actualStatus
                Result   = "Failed"
                Message  = "Actual status '$actualStatus' does not match expected status '$ExpectedStatus'."
            }) | Out-Null
            Write-Log "Status check failed. Expected: '$ExpectedStatus', Actual: '$actualStatus'." -Level "WARNING"
        }
    }

    # --- Expected Properties Check ---
    $allPropertiesMatched = $true # Assume true if no ExpectedProperties are provided or all match
    if ($ExpectedProperties) {
        Write-Log "Performing Expected Properties Check..."
        foreach ($propKey in $ExpectedProperties.Keys) {
            $expectedPropCondition = $ExpectedProperties[$propKey]
            $propertyExists = $false
            $actualPropValue = $null
            $propMatch = $false
            $propCheckMessage = ""

            if ($null -ne $OperationOutput -and $OperationOutput.PSObject.Properties[$propKey]) {
                $propertyExists = $true
                $actualPropValue = $OperationOutput.$($propKey)

                try {
                    if ($expectedPropCondition -is [ScriptBlock]) {
                        Write-Log "Evaluating ScriptBlock for property '$propKey'." -Level "DEBUG"
                        # Invoke scriptblock, passing the actual value as $_ or $args[0]
                        $propMatch = Invoke-Command -ScriptBlock $expectedPropCondition -ArgumentList $actualPropValue # Or $actualPropValue | & $expectedPropCondition
                        $propCheckMessage = "Property '$propKey': Custom logic (ScriptBlock) evaluated to $propMatch. Actual value: '$actualPropValue'."
                        Write-Log $propCheckMessage -Level (if($propMatch){"DEBUG"}else{"WARNING"})
                    } else { # Static value comparison
                        $propMatch = ($actualPropValue -eq $expectedPropCondition)
                        $propCheckMessage = "Property '$propKey': Expected: '$expectedPropCondition', Actual: '$actualPropValue'."
                        Write-Log $propCheckMessage -Level (if($propMatch){"DEBUG"}else{"WARNING"})
                    }
                } catch {
                    $propMatch = $false
                    $propCheckMessage = "Property '$propKey': Error during evaluation. Expected: '$expectedPropCondition', Actual: '$actualPropValue'. Error: $($_.Exception.Message)"
                    Write-Log $propCheckMessage -Level "ERROR"
                }
            } else { # Property does not exist on OperationOutput
                $propMatch = $false
                $propCheckMessage = "Property '$propKey': Expected to exist, but was not found on OperationOutput."
                Write-Log $propCheckMessage -Level "WARNING"
                $actualPropValue = "PropertyNotFoun_d" # Special value
            }

            if (-not $propMatch) {
                $allPropertiesMatched = $false
            }
            $validationDetails.Add([PSCustomObject]@{
                Check    = "Property '$propKey'"
                Expected = $expectedPropCondition.ToString() # Convert scriptblock to string for summary
                Actual   = $actualPropValue
                Result   = if($propMatch){"Passed"}else{"Failed"}
                Message  = $propCheckMessage
            }) | Out-Null
        }
        Write-Log "Expected Properties check completed. All matched: $allPropertiesMatched."
    } else {
        Write-Log "No ExpectedProperties provided; skipping this check."
        # $allPropertiesMatched remains true by default
    }

    # --- Determine Overall Result ---
    $overallTestPassed = $false
    if ($SuccessIfAllExpectedPropertiesMatch) {
        $overallTestPassed = $statusCheckPassed -and $allPropertiesMatched
    } else {
        $overallTestPassed = $statusCheckPassed # Only status matters for overall pass/fail
    }
    Write-Log "Overall test result: $(if($overallTestPassed){'Passed'}else{'Failed'}). (StatusCheck: $statusCheckPassed, PropertiesMatch: $allPropertiesMatched, SuccessIfAllPropsMatch: $SuccessIfAllExpectedPropertiesMatch)"

    $finalResult = [PSCustomObject]@{
        OverallResult          = $overallTestPassed
        ExpectedStatus         = $ExpectedStatus
        ActualStatus           = $actualStatus
        StatusCheckPassed      = $statusCheckPassed
        AllPropertiesMatched   = if ($ExpectedProperties) { $allPropertiesMatched } else { $null } # Null if not checked
        ValidationDetails      = $validationDetails
        Timestamp              = Get-Date -Format o
    }

    Write-Log "Test-OperationResult script finished."
    return $finalResult
}

# Find-IssuePatterns.ps1
# This script finds defined issue patterns in structured input data.
# TODO: Enhance operator set (e.g., date comparisons, list operations).
# TODO: Refine MaxIssuesToFind logic for distinct IssueIds if needed.

Function Find-IssuePatterns {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [object[]]$InputData,

        [Parameter(Mandatory=$false)]
        [string]$IssuePatternDefinitionsPath,

        [Parameter(Mandatory=$false)]
        [int]$MaxIssuesToFind = 0, # 0 means all

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\FindIssuePatterns_Activity.log"
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

    Write-Log "Starting Find-IssuePatterns script. InputData count: $($InputData.Count). MaxIssuesToFind: $MaxIssuesToFind."

    $issuePatterns = @()

    if (-not [string]::IsNullOrWhiteSpace($IssuePatternDefinitionsPath)) {
        Write-Log "Loading issue pattern definitions from: $IssuePatternDefinitionsPath"
        if (Test-Path $IssuePatternDefinitionsPath -PathType Leaf) {
            try {
                $jsonContent = Get-Content -Path $IssuePatternDefinitionsPath -Raw | ConvertFrom-Json -ErrorAction Stop
                if ($jsonContent.issuePatterns) {
                    $issuePatterns = $jsonContent.issuePatterns
                    Write-Log "Successfully loaded $($issuePatterns.Count) issue patterns from JSON file."
                } else {
                    Write-Log "Pattern file '$IssuePatternDefinitionsPath' does not contain an 'issuePatterns' array at the root." -Level "WARNING"
                }
            } catch {
                Write-Log "Failed to load or parse issue pattern file '$IssuePatternDefinitionsPath'. Error: $($_.Exception.Message)" -Level "ERROR"
            }
        } else {
            Write-Log "Issue pattern definitions file not found at: $IssuePatternDefinitionsPath" -Level "WARNING"
        }
    }

    if ($issuePatterns.Count -eq 0) {
        Write-Log "Using hardcoded issue pattern definitions."
        $issuePatterns = @(
            @{
                IssueId = "ServiceCrashUnexpected"
                Description = "A service terminated unexpectedly."
                DataSignatures = @(
                    @{ Property = "EventId"; Operator = "Equals"; Value = 7034 },
                    @{ Property = "Message"; Operator = "Contains"; Value = "terminated unexpectedly" }
                )
                Severity = "High"
                SuggestedRemediationId = "REM_RestartService"
            },
            @{
                IssueId = "LowDiskSpaceSystemDrive"
                Description = "The system drive (C:) is reported as low on disk space."
                DataSignatures = @(
                    @{ Property = "EventId"; Operator = "Equals"; Value = 2013 },
                    @{ Property = "Source"; Operator = "Equals"; Value = "srv" }, # LanmanServer
                    @{ Property = "Message"; Operator = "MatchesRegex"; Value = "The C: disk is at or near capacity" } # Regex for C: drive specifically
                )
                Severity = "Medium"
                SuggestedRemediationId = "REM_ClearTempFiles"
            },
            @{
                IssueId = "DNSResolutionFailure"
                Description = "DNS client failed to resolve a name."
                DataSignatures = @(
                    @{ Property = "EventId"; Operator = "Equals"; Value = 1014 },
                    @{ Property = "Source"; Operator = "Equals"; Value = "Microsoft-Windows-DNS-Client" }
                )
                Severity = "Medium"
                SuggestedRemediationId = "REM_TestDNS"
            }
        )
        Write-Log "Loaded $($issuePatterns.Count) hardcoded issue patterns."
    }

    $foundIssues = [System.Collections.ArrayList]::new()

    foreach ($item in $InputData) {
        if ($MaxIssuesToFind -gt 0 -and $foundIssues.Count -ge $MaxIssuesToFind) {
            Write-Log "Reached MaxIssuesToFind ($MaxIssuesToFind). Stopping further processing of input items."
            break
        }

        Write-Log "Processing input item: $($item | Out-String -Width 200 -Depth 2)" -Level "DEBUG"

        foreach ($pattern in $issuePatterns) {
            $allSignaturesMatch = $true # Assume match until a signature fails
            if (-not $pattern.DataSignatures -or $pattern.DataSignatures.Count -eq 0) {
                Write-Log "Pattern '$($pattern.IssueId)' has no DataSignatures defined. Skipping." -Level "WARNING"
                $allSignaturesMatch = $false
            }

            foreach ($signature in $pattern.DataSignatures) {
                if (-not ($item.PSObject.Properties[$signature.Property])) {
                    Write-Log "Input item does not have property '$($signature.Property)' required by pattern '$($pattern.IssueId)'. Signature does not match." -Level "DEBUG"
                    $allSignaturesMatch = $false
                    break
                }

                $itemValue = $item.$($signature.Property)
                $conditionValue = $signature.Value
                $operator = $signature.Operator

                $signatureMatched = $false
                switch ($operator) {
                    "Equals"       { $signatureMatched = ($itemValue -eq $conditionValue) }
                    "NotEquals"    { $signatureMatched = ($itemValue -ne $conditionValue) }
                    "Contains"     {
                        if ($itemValue -is [string]) { $signatureMatched = ($itemValue -match [regex]::Escape($conditionValue)) } # Using -match for substring
                        else { Write-Log "Operator 'Contains' used on non-string property '$($signature.Property)' for pattern '$($pattern.IssueId)'." -Level "DEBUG"; $signatureMatched = $false }
                    }
                    "GreaterThan"  {
                        if (($itemValue -is [int] -or $itemValue -is [double] -or $itemValue -is [long]) -and `
                            ($conditionValue -is [int] -or $conditionValue -is [double] -or $conditionValue -is [long])) {
                             $signatureMatched = ($itemValue -gt $conditionValue)
                        } else {$signatureMatched = $false}
                    }
                    "LessThan"     {
                         if (($itemValue -is [int] -or $itemValue -is [double] -or $itemValue -is [long]) -and `
                            ($conditionValue -is [int] -or $conditionValue -is [double] -or $conditionValue -is [long])) {
                             $signatureMatched = ($itemValue -lt $conditionValue)
                        } else {$signatureMatched = $false}
                    }
                    "MatchesRegex" {
                        if ($itemValue -is [string]) { $signatureMatched = ($itemValue -match $conditionValue) }
                        else { Write-Log "Operator 'MatchesRegex' used on non-string property '$($signature.Property)' for pattern '$($pattern.IssueId)'." -Level "DEBUG"; $signatureMatched = $false }
                    }
                    default {
                        Write-Log "Unsupported operator '$operator' in pattern '$($pattern.IssueId)' for property '$($signature.Property)'." -Level "WARNING"
                        $signatureMatched = $false
                    }
                }

                if (-not $signatureMatched) {
                    $allSignaturesMatch = $false
                    Write-Log "Signature did not match for pattern '$($pattern.IssueId)': Prop='$($signature.Property)', Op='$operator', Val='$conditionValue', ItemVal='$itemValue'." -Level "DEBUG"
                    break
                }
            } # End foreach signature

            if ($allSignaturesMatch) {
                Write-Log "Item matched all signatures for pattern '$($pattern.IssueId)' (Description: $($pattern.Description))." -Level "INFO"
                $foundIssues.Add([PSCustomObject]@{
                    MatchedIssueId          = $pattern.IssueId
                    MatchedIssueDescription = $pattern.Description
                    MatchedItem             = $item
                    PatternSeverity         = $pattern.Severity # Will be null if not defined in pattern
                    SuggestedRemediationId  = $pattern.SuggestedRemediationId # Will be null if not defined
                    Timestamp               = (Get-Date -Format o)
                }) | Out-Null

                # If MaxIssuesToFind is about distinct IssueIDs, logic would be more complex here.
                # Current simple interpretation: stop if total found issues (items) reach the max.
                if ($MaxIssuesToFind -gt 0 -and $foundIssues.Count -ge $MaxIssuesToFind) {
                    Write-Log "Reached MaxIssuesToFind ($MaxIssuesToFind) based on total matched items. Halting search for this item." -Level "DEBUG"
                    break # Stop checking more patterns for this item
                }
            }
        } # End foreach pattern

        if ($MaxIssuesToFind -gt 0 -and $foundIssues.Count -ge $MaxIssuesToFind) {
            Write-Log "Total matched items reached MaxIssuesToFind ($MaxIssuesToFind). Further input items will be skipped."
            break # Stop processing further input items
        }
    } # End foreach item

    Write-Log "Find-IssuePatterns script finished. Found $($foundIssues.Count) matching issue instances."
    return $foundIssues
}

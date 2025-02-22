function Test-Prerequisite {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [hashtable]$Requirements,
        [Parameter()]
        [switch]$Remediate,
        [Parameter()]
        [switch]$Force
    )

    begin {
        $results = @{
            StartTime = Get-Date
            Checks = @()
            Success = $false
            Remediation = @()
        }

        Write-Log -Message "Starting prerequisite checks" -Level Information
    }

    process {
        try {
            foreach ($requirement in $Requirements.GetEnumerator()) {
                $check = @{
                    Name = $requirement.Key
                    Required = $requirement.Value.Required
                    Status = "Pending"
                }

                try {
                    $checkResult = & $requirement.Value.Test
                    $check.Status = $checkResult.Success ? "Success" : "Failed"
                    $check.Details = $checkResult.Details

                    if (-not $checkResult.Success -and $Remediate -and $requirement.Value.Remediation) {
                        Write-Log -Message "Attempting remediation for $($requirement.Key)" -Level Warning
                        $remediationResult = & $requirement.Value.Remediation
                        $results.Remediation += @{
                            Check = $requirement.Key
                            Success = $remediationResult.Success
                            Details = $remediationResult.Details
                        }

                        # Recheck after remediation
                        $recheckResult = & $requirement.Value.Test
                        $check.Status = $recheckResult.Success ? "Remediated" : "RemediationFailed"
                        $check.Details = $recheckResult.Details
                    }
                }
                catch {
                    $check.Status = "Error"
                    $check.Error = $_.Exception.Message
                    Write-Log -Message "Prerequisite check failed for $($requirement.Key): $_" -Level Error
                }

                $results.Checks += $check
            }

            # Determine overall success
            $failedRequired = $results.Checks | 
                Where-Object { $_.Required -and $_.Status -notin @('Success', 'Remediated') }
            
            $results.Success = $failedRequired.Count -eq 0

            if (-not $results.Success -and -not $Force) {
                throw "Required prerequisites not met: $($failedRequired.Name -join ', ')"
            }
        }
        catch {
            Write-Error $_
            Write-Log -Message "Prerequisite check failed: $_" -Level Error
        }
    }

    end {
        $results.EndTime = Get-Date
        $results.Duration = $results.EndTime - $results.StartTime
        return [PSCustomObject]$results
    }
}
function Set-MonitoringRules {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [string]$RulesPath = ".\Config\monitoring-rules.json",
        [Parameter()]
        [switch]$Force
    )

    begin {
        $monitoringRules = Get-Content $RulesPath | ConvertFrom-Json
        $results = @{
            ServerName = $ServerName
            RulesApplied = @()
            Warnings = @()
            Errors = @()
        }
    }

    process {
        try {
            foreach ($rule in $monitoringRules.Rules) {
                $ruleResult = @{
                    Name = $rule.Name
                    Status = 'Pending'
                    Details = $null
                }

                if ($PSCmdlet.ShouldProcess($ServerName, "Apply monitoring rule: $($rule.Name)")) {
                    try {
                        # Validate rule prerequisites
                        $prerequisiteCheck = Test-RulePrerequisites -Rule $rule -ServerName $ServerName
                        if (-not $prerequisiteCheck.Success -and -not $Force) {
                            throw "Prerequisites not met: $($prerequisiteCheck.Details)"
                        }

                        # Apply rule
                        switch ($rule.Type) {
                            'Performance' {
                                Set-PerformanceRule -Rule $rule -ServerName $ServerName
                            }
                            'Availability' {
                                Set-AvailabilityRule -Rule $rule -ServerName $ServerName
                            }
                            'Security' {
                                Set-SecurityRule -Rule $rule -ServerName $ServerName
                            }
                            'Compliance' {
                                Set-ComplianceRule -Rule $rule -ServerName $ServerName
                            }
                            default {
                                throw "Unsupported rule type: $($rule.Type)"
                            }
                        }

                        $ruleResult.Status = 'Applied'
                        $results.RulesApplied += $ruleResult
                    }
                    catch {
                        $ruleResult.Status = 'Failed'
                        $ruleResult.Details = $_.Exception.Message
                        $results.Errors += $ruleResult
                    }
                }
            }

            # Verify rules application
            $verificationResults = Test-MonitoringRules -ServerName $ServerName
            foreach ($verify in $verificationResults) {
                if (-not $verify.Success) {
                    $results.Warnings += "Rule verification failed: $($verify.Name)"
                }
            }
        }
        catch {
            Write-Error "Failed to apply monitoring rules: $_"
            $results.Errors += $_.Exception.Message
        }
    }

    end {
        return [PSCustomObject]$results
    }
}
function Deploy-ArcAgent {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [hashtable]$ConfigurationParams,
        [Parameter()]
        [switch]$Force,
        [Parameter()]
        [int]$RetryCount = 3,
        [Parameter()]
        [int]$RetryDelaySeconds = 30,
        [Parameter()]
        [switch]$SkipMonitoring
    )

    begin {
        $ErrorActionPreference = 'Stop'
        Write-Log -Message "Starting Arc agent deployment for server: $ServerName" -Level Information
        
        # Initialize deployment state
        $deploymentState = @{
            ServerName = $ServerName
            StartTime = Get-Date
            Status = 'Starting'
            Steps = @()
            RollbackSteps = @()
        }

        # Define deployment steps with rollback actions
        $deploymentSteps = @(
            @{
                Name = 'Prerequisites'
                Action = { Test-ArcPrerequisites -ServerName $ServerName }
                Rollback = $null  # No rollback needed for validation
            },
            @{
                Name = 'Backup'
                Action = { Backup-ArcConfiguration -ServerName $ServerName }
                Rollback = { Remove-ArcBackup -BackupPath $stepResult.BackupPath }
            },
            @{
                Name = 'SecurityCheck'
                Action = { Test-SecurityCompliance -ServerName $ServerName }
                Rollback = $null
            },
            @{
                Name = 'Installation'
                Action = { 
                    Install-ArcAgentInternal -ServerName $ServerName -Configuration $ConfigurationParams 
                }
                Rollback = { Uninstall-ArcAgent -ServerName $ServerName }
            },
            @{
                Name = 'Validation'
                Action = { Test-ArcDeployment -ServerName $ServerName }
                Rollback = $null
            },
            @{
                Name = 'Monitoring'
                Action = { Set-MonitoringRules -ServerName $ServerName }
                Rollback = { Remove-MonitoringRules -ServerName $ServerName }
            }
        )
    }

    process {
        try {
            foreach ($step in $deploymentSteps) {
                # Skip monitoring step if specified
                if ($step.Name -eq 'Monitoring' -and $SkipMonitoring) {
                    continue
                }

                # Handle security check with Force parameter
                if ($step.Name -eq 'SecurityCheck' -and $Force) {
                    Write-Log -Message "Skipping security check due to Force parameter" -Level Warning
                    continue
                }

                if ($PSCmdlet.ShouldProcess($ServerName, "Executing step: $($step.Name)")) {
                    Write-Log -Message "Starting step: $($step.Name)" -Level Information

                    # Execute step with retry logic
                    $stepResult = New-RetryBlock `
                        -ScriptBlock $step.Action `
                        -RetryCount $RetryCount `
                        -RetryDelaySeconds $RetryDelaySeconds

                    if (-not $stepResult.Success) {
                        throw "Step $($step.Name) failed: $($stepResult.Error)"
                    }

                    # Record successful step and its rollback action
                    $deploymentState.Steps += @{
                        Name = $step.Name
                        Status = 'Success'
                        CompletedTime = Get-Date
                        Result = $stepResult
                    }

                    if ($step.Rollback) {
                        $deploymentState.RollbackSteps = @{
                            Name = $step.Name
                            Action = $step.Rollback
                            Params = $stepResult
                        } + $deploymentState.RollbackSteps  # Prepend for reverse order
                    }
                }
            }

            $deploymentState.Status = 'Success'
            $deploymentState.EndTime = Get-Date
        }
        catch {
            $deploymentState.Status = 'Failed'
            $deploymentState.Error = Convert-ErrorToObject $_

            # Execute rollback steps in reverse order
            if ($deploymentState.RollbackSteps.Count -gt 0) {
                Write-Log -Message "Initiating rollback for $ServerName" -Level Warning
                
                foreach ($rollbackStep in $deploymentState.RollbackSteps) {
                    try {
                        & $rollbackStep.Action -Params $rollbackStep.Params
                        Write-Log -Message "Rollback step $($rollbackStep.Name) completed" -Level Information
                    }
                    catch {
                        Write-Log -Message "Rollback step $($rollbackStep.Name) failed: $_" -Level Error
                    }
                }
            }

            Write-Error -Exception $_.Exception
        }
        finally {
            # Export deployment state
            $deploymentState | Export-DeploymentState -Path ".\Logs\$ServerName-$(Get-Date -Format 'yyyyMMdd')"
        }
    }

    end {
        Write-Log -Message "Deployment completed with status: $($deploymentState.Status)" -Level Information
        return [PSCustomObject]$deploymentState
    }
}

# Helper function for retry logic
function New-RetryBlock {
    param (
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        [Parameter()]
        [int]$RetryCount = 3,
        [Parameter()]
        [int]$RetryDelaySeconds = 30
    )

    $attempt = 1
    $result = $null

    do {
        try {
            $result = @{
                Success = $true
                Result = & $ScriptBlock
            }
            break
        }
        catch {
            if ($attempt -eq $RetryCount) {
                return @{
                    Success = $false
                    Error = $_
                    Attempts = $attempt
                }
            }
            
            Write-Log -Message "Attempt $attempt failed, retrying in $RetryDelaySeconds seconds..." -Level Warning
            Start-Sleep -Seconds $RetryDelaySeconds
            $attempt++
        }
    } while ($attempt -le $RetryCount)

    $result.Attempts = $attempt
    return $result
}
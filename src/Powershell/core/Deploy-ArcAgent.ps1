function Deploy-ArcAgent {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [hashtable]$ConfigurationParams,
        [Parameter()]
        [string]$WorkspaceId,
        [Parameter()]
        [string]$WorkspaceKey,
        [Parameter()]
        [switch]$DeployAMA,
        [Parameter()]
        [switch]$Force
    )

    begin {
        $deploymentState = @{
            ServerName = $ServerName
            StartTime = Get-Date
            Status = "Starting"
            Steps = @()
            AMADeployed = $false
        }
    }

    process {
        try {
            # Prerequisite Check
            $prereqCheck = Test-ArcPrerequisites -ServerName $ServerName -WorkspaceId $WorkspaceId
            if (-not $prereqCheck.Success) {
                throw "Prerequisites not met: $($prereqCheck.Error)"
            }
            $deploymentState.Steps += @{ Name = "Prerequisites"; Status = "Success" }

            # Backup existing configuration
            if ($PSCmdlet.ShouldProcess($ServerName, "Backup Configuration")) {
                $backup = Backup-ArcConfiguration -ServerName $ServerName
                $deploymentState.Steps += @{ Name = "Backup"; Status = "Success" }
            }

            # Deploy Arc Agent
            $arcDeployment = Install-ArcAgentInternal -ServerName $ServerName -Config $ConfigurationParams
            if (-not $arcDeployment.Success) {
                throw "Arc deployment failed: $($arcDeployment.Error)"
            }
            $deploymentState.Steps += @{ Name = "ArcInstallation"; Status = "Success" }

            # Deploy AMA if requested
            if ($DeployAMA) {
                if (-not $WorkspaceId -or -not $WorkspaceKey) {
                    throw "WorkspaceId and WorkspaceKey are required for AMA deployment"
                }

                $amaParams = @{
                    ServerName = $ServerName
                    WorkspaceId = $WorkspaceId
                    WorkspaceKey = $WorkspaceKey
                }

                $amaDeployment = Install-AMAExtension @amaParams
                if (-not $amaDeployment.Success) {
                    throw "AMA deployment failed: $($amaDeployment.Error)"
                }
                $deploymentState.Steps += @{ Name = "AMAInstallation"; Status = "Success" }
                $deploymentState.AMADeployed = $true

                # Configure Data Collection Rules
                $dcrParams = @{
                    ServerName = $ServerName
                    WorkspaceId = $WorkspaceId
                    RuleType = 'Security'
                }
                $dcrSetup = Set-DataCollectionRules @dcrParams
                $deploymentState.Steps += @{ 
                    Name = "DCRConfiguration"
                    Status = $dcrSetup.Status
                    Details = $dcrSetup.Changes
                }
            }

            # Validate Deployment
            $validation = Test-DeploymentHealth -ServerName $ServerName -ValidateAMA:$DeployAMA
            if (-not $validation.Success) {
                throw "Deployment validation failed: $($validation.Error)"
            }
            $deploymentState.Steps += @{ Name = "Validation"; Status = "Success" }

            $deploymentState.Status = "Success"
            $deploymentState.EndTime = Get-Date
        }
        catch {
            $deploymentState.Status = "Failed"
            $deploymentState.Error = $_.Exception.Message

            # Attempt rollback if backup exists
            if ($backup) {
                Write-Warning "Deployment failed. Attempting rollback..."
                $rollback = Restore-ArcConfiguration -ServerName $ServerName -Backup $backup
                $deploymentState.Rollback = $rollback
            }

            Write-Error $_
        }
    }

    end {
        return [PSCustomObject]$deploymentState
    }
}
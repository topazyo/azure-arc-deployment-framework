# Core deployment function
function Deploy-ArcAgent {
    param (
        [string]$ServerName,
        [hashtable]$ConfigurationParams
    )
    
    try {
        # Pre-deployment validation
        $preChecks = Test-ArcPrerequisites -ServerName $ServerName
        if (-not $preChecks.AllPassed) {
            throw "Prerequisites not met: $($preChecks.FailedChecks)"
        }

        # Deployment steps with rollback capability
        $deploymentSteps = @(
            { Install-ArcPrerequisites },
            { Configure-NetworkSettings },
            { Install-ArcAgent },
            { Validate-Installation }
        )

        foreach ($step in $deploymentSteps) {
            & $step
        }
    }
    catch {
        Write-Error "Deployment failed: $_"
        Invoke-Rollback
    }
}
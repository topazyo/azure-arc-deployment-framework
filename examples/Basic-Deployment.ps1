# Basic Azure Arc Deployment Example
# This example demonstrates a simple deployment scenario

# Import required modules
Import-Module .\src\PowerShell\AzureArcDeployment.psm1

# Configuration parameters
$deploymentParams = @{
    ServerName = "PROD-WEB-01"
    Environment = "Production"
    Region = "eastus2"
    Tags = @{
        Department = "IT"
        Application = "WebServer"
        Environment = "Production"
    }
}

# Step 1: Run prerequisite checks
Write-Host "Running prerequisite checks..." -ForegroundColor Cyan
$preCheckResults = Test-ArcPrerequisites -ServerName $deploymentParams.ServerName
if (-not $preCheckResults.Success) {
    Write-Error "Prerequisites not met: $($preCheckResults.Error)"
    exit 1
}

# Step 2: Deploy Arc agent
Write-Host "Deploying Arc agent..." -ForegroundColor Cyan
try {
    $deploymentResult = Deploy-ArcAgent @deploymentParams
    if ($deploymentResult.Success) {
        Write-Host "Deployment successful!" -ForegroundColor Green
    }
} catch {
    Write-Error "Deployment failed: $_"
    exit 1
}

# Step 3: Validate deployment
Write-Host "Validating deployment..." -ForegroundColor Cyan
$validationResult = Start-ArcTroubleshooter -ServerName $deploymentParams.ServerName
Write-Host "Validation Results:" -ForegroundColor Yellow
$validationResult | Format-Table -AutoSize
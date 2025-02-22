#Requires -Modules Az.Accounts, Az.ConnectedMachine, Az.Monitor
#Requires -Version 5.1

# Import the Arc Framework module
Import-Module AzureArcFramework

# Configuration
$config = @{
    # Azure Configuration
    SubscriptionId = "<subscription-id>"
    ResourceGroup = "Arc-Servers-RG"
    Location = "eastus"

    # Log Analytics Configuration
    WorkspaceId = "<workspace-id>"
    WorkspaceKey = "<workspace-key>"

    # Deployment Configuration
    DeploymentType = "Standard"  # Standard, Minimal, or Compliance
    BatchSize = 10
    RetryCount = 3
    RetryDelaySeconds = 30

    # Monitoring Configuration
    DataCollectionRules = @{
        SecurityEvents = $true
        PerformanceCounters = $true
        WindowsEvents = @{
            System = @("Error", "Warning")
            Application = @("Error", "Warning")
            Security = @("Audit Success", "Audit Failure")
        }
    }
}

# Initialize the framework
try {
    Write-Host "Initializing Arc Framework..." -ForegroundColor Cyan
    Initialize-ArcDeployment -CustomConfig $config # Removed $init = as it was unused
    Write-Host "Framework initialized successfully" -ForegroundColor Green
}
catch {
    Write-Error "Framework initialization failed: $_"
    exit 1
}

# Function to deploy Arc to a single server
function Deploy-SingleServer {
    param (
        [string]$ServerName,
        [hashtable]$Config
    )

    try {
        # 1. Validate prerequisites
        Write-Host "Validating prerequisites for $ServerName..." -ForegroundColor Cyan
        $prereqs = Test-ArcPrerequisites -ServerName $ServerName
        if (-not $prereqs.Success) {
            throw "Prerequisites check failed: $($prereqs.Error)"
        }

        # 2. Deploy Arc agent
        Write-Host "Deploying Arc agent to $ServerName..." -ForegroundColor Cyan
        $deployParams = @{
            ServerName = $ServerName
            ConfigurationParams = $Config
            DeployAMA = $true
            WorkspaceId = $Config.WorkspaceId
            WorkspaceKey = $Config.WorkspaceKey
        }
        $deployment = New-ArcDeployment @deployParams

        # 3. Validate deployment
        Write-Host "Validating deployment for $ServerName..." -ForegroundColor Cyan
        $validation = Test-DeploymentValidation -ServerName $ServerName -WorkspaceId $Config.WorkspaceId

        # 4. Configure monitoring
        if ($validation.OverallStatus -eq "Success") {
            Write-Host "Configuring monitoring for $ServerName..." -ForegroundColor Cyan
            $monitoring = Set-DataCollectionRules -ServerName $ServerName -Rules $Config.DataCollectionRules
        }

        # Return results
        return @{
            ServerName = $ServerName
            DeploymentStatus = $deployment.Status
            ValidationStatus = $validation.OverallStatus
            MonitoringStatus = $monitoring.Status
            Timestamp = Get-Date
        }
    }
    catch {
        Write-Error "Deployment failed for $ServerName: $_"
        return @{
            ServerName = $ServerName
            Status = "Failed"
            Error = $_.Exception.Message
            Timestamp = Get-Date
        }
    }
}

# Main deployment script
try {
    # Get server list
    $servers = Get-Content ".\servers.txt"
    $totalServers = $servers.Count
    Write-Host "Starting deployment for $totalServers servers..." -ForegroundColor Cyan

    # Create result arrays
    $successful = @()
    $failed = @()

    # Process servers in batches
    for ($i = 0; $i -lt $totalServers; $i += $config.BatchSize) {
        $batch = $servers[$i..([Math]::Min($i + $config.BatchSize - 1, $totalServers - 1))]
        Write-Host "Processing batch $(([Math]::Floor($i/$config.BatchSize) + 1))..." -ForegroundColor Cyan

        # Deploy to batch in parallel
        $batchResults = $batch | ForEach-Object -ThrottleLimit $config.BatchSize -Parallel {
            Deploy-SingleServer -ServerName $_ -Config $using:config
        }

        # Process batch results
        foreach ($result in $batchResults) {
            if ($result.DeploymentStatus -eq "Success") {
                $successful += $result
                Write-Host "Deployment successful: $($result.ServerName)" -ForegroundColor Green
            }
            else {
                $failed += $result
                Write-Host "Deployment failed: $($result.ServerName)" -ForegroundColor Red
            }
        }

        # Progress update
        $progress = @{
            Activity = "Arc Deployment Progress"
            Status = "Completed: $($successful.Count + $failed.Count)/$totalServers"
            PercentComplete = (($successful.Count + $failed.Count) / $totalServers) * 100
        }
        Write-Progress @progress
    }

    # Generate deployment report
    $report = @{
        StartTime = Get-Date
        TotalServers = $totalServers
        Successful = $successful.Count
        Failed = $failed.Count
        SuccessRate = ($successful.Count / $totalServers) * 100
        FailedServers = $failed | Select-Object ServerName, Error
    }

    # Export report
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $reportFilename = ".\DeploymentReport_$timestamp.json"
    $report | ConvertTo-Json -Depth 10 | Out-File $reportFilename

    # Final summary
    Write-Host "`nDeployment Summary:" -ForegroundColor Cyan
    Write-Host "Total Servers: $totalServers" -ForegroundColor White
    Write-Host "Successful: $($successful.Count)" -ForegroundColor Green
    Write-Host "Failed: $($failed.Count)" -ForegroundColor Red
    Write-Host "Success Rate: $($report.SuccessRate)%" -ForegroundColor Cyan
}
catch {
    Write-Error "Deployment script failed: $_"
    exit 1
}
finally {
    # Cleanup and logging
    Write-Host "Cleaning up resources..." -ForegroundColor Cyan
    Stop-Transcript
}
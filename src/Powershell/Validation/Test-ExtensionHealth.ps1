function Test-ExtensionHealth {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [string[]]$ExtensionNames,
        [Parameter()]
        [switch]$IncludeDetails,
        [Parameter()]
        [int]$TimeoutSeconds = 60
    )

    begin {
        $extensionHealth = @{
            ServerName = $ServerName
            StartTime = Get-Date
            Status = "Unknown"
            Extensions = @()
            Summary = @{
                Total = 0
                Healthy = 0
                Unhealthy = 0
                Warning = 0
                Unknown = 0
            }
        }

        Write-Log -Message "Starting extension health check for $ServerName" -Level Information
    }

    process {
        try {
            # Get Arc server resource
            $arcServer = Get-AzConnectedMachine -Name $ServerName -ErrorAction Stop
            
            if (-not $arcServer) {
                throw "Server $ServerName not found as an Arc-enabled server"
            }

            # Get all extensions if not specified
            if (-not $ExtensionNames) {
                $extensions = Get-AzConnectedMachineExtension -ResourceGroupName $arcServer.ResourceGroupName -MachineName $ServerName
            }
            else {
                $extensions = @()
                foreach ($extName in $ExtensionNames) {
                    $ext = Get-AzConnectedMachineExtension -ResourceGroupName $arcServer.ResourceGroupName -MachineName $ServerName -Name $extName -ErrorAction SilentlyContinue
                    if ($ext) {
                        $extensions += $ext
                    }
                    else {
                        Write-Warning "Extension $extName not found on server $ServerName"
                    }
                }
            }

            $extensionHealth.Summary.Total = $extensions.Count

            # Check each extension
            foreach ($extension in $extensions) {
                $extHealth = @{
                    Name = $extension.Name
                    Type = $extension.ExtensionType
                    Publisher = $extension.Publisher
                    Version = $extension.TypeHandlerVersion
                    ProvisioningState = $extension.ProvisioningState
                    Status = "Unknown"
                    LastOperation = $null
                    Issues = @()
                }

                # Check provisioning state
                if ($extension.ProvisioningState -eq "Succeeded") {
                    $extHealth.Status = "Healthy"
                    $extensionHealth.Summary.Healthy++
                }
                elseif ($extension.ProvisioningState -eq "Failed") {
                    $extHealth.Status = "Unhealthy"
                    $extensionHealth.Summary.Unhealthy++
                    $extHealth.Issues += "Provisioning failed"
                }
                else {
                    $extHealth.Status = "Warning"
                    $extensionHealth.Summary.Warning++
                    $extHealth.Issues += "Provisioning state: $($extension.ProvisioningState)"
                }

                # Get detailed status
                if ($IncludeDetails) {
                    $detailedStatus = Get-ExtensionDetailedStatus -ResourceGroupName $arcServer.ResourceGroupName -MachineName $ServerName -ExtensionName $extension.Name
                    
                    if ($detailedStatus) {
                        $extHealth.DetailedStatus = $detailedStatus
                        
                        # Update status based on detailed information
                        if ($detailedStatus.Status -eq "Failed") {
                            $extHealth.Status = "Unhealthy"
                            $extensionHealth.Summary.Healthy--
                            $extensionHealth.Summary.Unhealthy++
                            $extHealth.Issues += $detailedStatus.Error
                        }
                    }
                }

                # Check agent service for specific extensions
                if ($extension.Name -eq "AzureMonitorWindowsAgent") {
                    $serviceStatus = Get-ServiceStatus -ServerName $ServerName -ServiceName "AzureMonitorAgent"
                    $extHealth.ServiceStatus = $serviceStatus
                    
                    if ($serviceStatus.Status -ne "Running") {
                        $extHealth.Status = "Unhealthy"
                        if ($extHealth.Status -eq "Healthy") {
                            $extensionHealth.Summary.Healthy--
                            $extensionHealth.Summary.Unhealthy++
                        }
                        $extHealth.Issues += "Service not running"
                    }
                }
                elseif ($extension.Name -eq "GuestConfigurationForWindows") {
                    $serviceStatus = Get-ServiceStatus -ServerName $ServerName -ServiceName "GCService"
                    $extHealth.ServiceStatus = $serviceStatus
                    
                    if ($serviceStatus.Status -ne "Running") {
                        $extHealth.Status = "Unhealthy"
                        if ($extHealth.Status -eq "Healthy") {
                            $extensionHealth.Summary.Healthy--
                            $extensionHealth.Summary.Unhealthy++
                        }
                        $extHealth.Issues += "Service not running"
                    }
                }

                # Get last operation
                $extHealth.LastOperation = Get-ExtensionLastOperation -ResourceGroupName $arcServer.ResourceGroupName -MachineName $ServerName -ExtensionName $extension.Name

                # Add to results
                $extensionHealth.Extensions += $extHealth
            }

            # Determine overall status
            if ($extensionHealth.Summary.Unhealthy -gt 0) {
                $extensionHealth.Status = "Failed"
            }
            elseif ($extensionHealth.Summary.Warning -gt 0) {
                $extensionHealth.Status = "Warning"
            }
            elseif ($extensionHealth.Summary.Healthy -eq $extensionHealth.Summary.Total) {
                $extensionHealth.Status = "Success"
            }
            else {
                $extensionHealth.Status = "Unknown"
            }

            # Generate recommendations
            $extensionHealth.Recommendations = Get-ExtensionRecommendations -Extensions $extensionHealth.Extensions
        }
        catch {
            $extensionHealth.Status = "Error"
            $extensionHealth.Error = $_.Exception.Message
            Write-Error "Extension health check failed: $_"
        }
    }

    end {
        $extensionHealth.EndTime = Get-Date
        $extensionHealth.Duration = $extensionHealth.EndTime - $extensionHealth.StartTime
        Write-Log -Message "Extension health check completed with status: $($extensionHealth.Status)" -Level Information
        return [PSCustomObject]$extensionHealth
    }
}

function Get-ExtensionDetailedStatus {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory)]
        [string]$MachineName,
        [Parameter(Mandatory)]
        [string]$ExtensionName
    )

    try {
        # Get extension instance view
        $instanceView = Invoke-AzRestMethod -Method GET -Path "/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.HybridCompute/machines/{2}/extensions/{3}?api-version=2021-05-20&expand=instanceView" -f 
            (Get-AzContext).Subscription.Id, 
            $ResourceGroupName, 
            $MachineName, 
            $ExtensionName

        if ($instanceView.StatusCode -eq 200) {
            $instanceViewContent = $instanceView.Content | ConvertFrom-Json
            
            if ($instanceViewContent.properties.instanceView) {
                $status = $instanceViewContent.properties.instanceView.status
                $statusMessage = $instanceViewContent.properties.instanceView.statusMessage
                
                return @{
                    Status = $status.code
                    DisplayStatus = $status.displayStatus
                    Message = $statusMessage
                    Error = if ($status.code -eq "Failed") { $statusMessage } else { $null }
                    LastUpdated = $status.time
                }
            }
        }
        
        return $null
    }
    catch {
        Write-Warning "Failed to get detailed status for extension $ExtensionName on $MachineName`: $_"
        return $null
    }
}

function Get-ExtensionLastOperation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory)]
        [string]$MachineName,
        [Parameter(Mandatory)]
        [string]$ExtensionName
    )

    try {
        # Get activity logs for the extension
        $endTime = Get-Date
        $startTime = $endTime.AddDays(-7) # Last 7 days
        
        $logs = Get-AzActivityLog -ResourceGroupName $ResourceGroupName -StartTime $startTime -EndTime $endTime |
            Where-Object { 
                $_.ResourceId -like "*/machines/$MachineName/extensions/$ExtensionName" -or
                ($_.ResourceId -like "*/machines/$MachineName" -and $_.OperationName.Value -like "*extensions*")
            } |
            Sort-Object EventTimestamp -Descending |
            Select-Object -First 5
        
        if ($logs) {
            return @{
                LastOperation = $logs[0].OperationName.Value
                Status = $logs[0].Status.Value
                Timestamp = $logs[0].EventTimestamp
                Caller = $logs[0].Caller
                CorrelationId = $logs[0].CorrelationId
                RecentOperations = $logs | ForEach-Object {
                    @{
                        Operation = $_.OperationName.Value
                        Status = $_.Status.Value
                        Timestamp = $_.EventTimestamp
                    }
                }
            }
        }
        
        return $null
    }
    catch {
        Write-Warning "Failed to get last operation for extension $ExtensionName on $MachineName`: $_"
        return $null
    }
}

function Get-ServiceStatus {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter(Mandatory)]
        [string]$ServiceName
    )

    try {
        $service = Get-Service -ComputerName $ServerName -Name $ServiceName -ErrorAction SilentlyContinue
        
        if ($service) {
            return @{
                Name = $service.Name
                DisplayName = $service.DisplayName
                Status = $service.Status
                StartType = $service.StartType
            }
        }
        else {
            return @{
                Name = $ServiceName
                Status = "NotFound"
                Error = "Service not found"
            }
        }
    }
    catch {
        Write-Warning "Failed to get service status for $ServiceName on $ServerName`: $_"
        return @{
            Name = $ServiceName
            Status = "Error"
            Error = $_.Exception.Message
        }
    }
}

function Get-ExtensionRecommendations {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [array]$Extensions
    )

    $recommendations = @()

    foreach ($extension in $Extensions) {
        if ($extension.Status -ne "Healthy") {
            $recommendation = @{
                ExtensionName = $extension.Name
                Priority = if ($extension.Status -eq "Unhealthy") { "High" } else { "Medium" }
                Actions = @()
            }

            # Add specific recommendations based on issues
            foreach ($issue in $extension.Issues) {
                switch -Wildcard ($issue) {
                    "Service not running" {
                        $recommendation.Actions += "Restart the $($extension.ServiceStatus.Name) service"
                        $recommendation.Actions += "Check service dependencies and configuration"
                    }
                    "Provisioning failed" {
                        $recommendation.Actions += "Check extension configuration and permissions"
                        $recommendation.Actions += "Review detailed error message in Azure portal"
                        $recommendation.Actions += "Reinstall the extension"
                    }
                    "Provisioning state: *" {
                        $recommendation.Actions += "Wait for provisioning to complete"
                        $recommendation.Actions += "Check for resource constraints"
                    }
                    default {
                        $recommendation.Actions += "Investigate issue: $issue"
                        $recommendation.Actions += "Check extension logs"
                    }
                }
            }

            # Add extension-specific recommendations
            switch ($extension.Name) {
                "AzureMonitorWindowsAgent" {
                    $recommendation.Actions += "Verify Log Analytics workspace configuration"
                    $recommendation.Actions += "Check data collection rules"
                    $recommendation.Actions += "Validate network connectivity to Log Analytics endpoints"
                }
                "GuestConfigurationForWindows" {
                    $recommendation.Actions += "Verify policy assignments"
                    $recommendation.Actions += "Check guest configuration permissions"
                }
                "MicrosoftMonitoringAgent" {
                    $recommendation.Actions += "Consider migrating to Azure Monitor Agent"
                    $recommendation.Actions += "Verify workspace key and ID"
                }
            }

            # Remove duplicates and add to recommendations
            $recommendation.Actions = $recommendation.Actions | Select-Object -Unique
            $recommendations += $recommendation
        }
    }

    return $recommendations
}
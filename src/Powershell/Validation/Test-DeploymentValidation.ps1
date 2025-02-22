function Test-DeploymentValidation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [string]$WorkspaceId,
        [Parameter()]
        [ValidateSet('Basic', 'Enhanced', 'Comprehensive')]
        [string]$ValidationLevel = 'Enhanced',
        [Parameter()]
        [string]$ConfigPath = ".\Config\validation-matrix.json"
    )

    begin {
        $validationResults = @{
            ServerName = $ServerName
            StartTime = Get-Date
            ValidationLevel = $ValidationLevel
            Components = @()
            OverallStatus = "Unknown"
        }

        # Load validation configuration
        try {
            $validationConfig = Get-Content $ConfigPath | ConvertFrom-Json
        }
        catch {
            Write-Error "Failed to load validation configuration: $_"
            return
        }

        Write-Log -Message "Starting deployment validation for $ServerName" -Level Information
    }

    process {
        try {
            # Arc Agent Validation
            $arcValidation = Test-ArcAgentValidation -ServerName $ServerName
            $validationResults.Components += @{
                Name = "Arc Agent"
                Status = $arcValidation.Status
                Details = $arcValidation.Details
                Critical = $true
            }

            # AMA Validation (if workspace provided)
            if ($WorkspaceId) {
                $amaValidation = Test-AMAValidation -ServerName $ServerName -WorkspaceId $WorkspaceId
                $validationResults.Components += @{
                    Name = "Azure Monitor Agent"
                    Status = $amaValidation.Status
                    Details = $amaValidation.Details
                    Critical = $true
                }
            }

            # Enhanced Validation Checks
            if ($ValidationLevel -in 'Enhanced', 'Comprehensive') {
                # Network Connectivity
                $networkValidation = Test-NetworkValidation -ServerName $ServerName
                $validationResults.Components += @{
                    Name = "Network Connectivity"
                    Status = $networkValidation.Status
                    Details = $networkValidation.Details
                    Critical = $true
                }

                # Security Configuration
                $securityValidation = Test-SecurityValidation -ServerName $ServerName
                $validationResults.Components += @{
                    Name = "Security Configuration"
                    Status = $securityValidation.Status
                    Details = $securityValidation.Details
                    Critical = $true
                }

                # Performance Metrics
                $performanceValidation = Test-PerformanceValidation -ServerName $ServerName
                $validationResults.Components += @{
                    Name = "Performance Metrics"
                    Status = $performanceValidation.Status
                    Details = $performanceValidation.Details
                    Critical = $false
                }
            }

            # Comprehensive Validation Checks
            if ($ValidationLevel -eq 'Comprehensive') {
                # Configuration Drift
                $driftValidation = Test-ConfigurationDrift -ServerName $ServerName
                $validationResults.Components += @{
                    Name = "Configuration Drift"
                    Status = $driftValidation.Status
                    Details = $driftValidation.Details
                    Critical = $false
                }

                # Resource Provider Status
                $rpValidation = Test-ResourceProviderStatus -ServerName $ServerName
                $validationResults.Components += @{
                    Name = "Resource Provider"
                    Status = $rpValidation.Status
                    Details = $rpValidation.Details
                    Critical = $true
                }

                # Extension Health
                $extensionValidation = Test-ExtensionHealth -ServerName $ServerName
                $validationResults.Components += @{
                    Name = "Extension Health"
                    Status = $extensionValidation.Status
                    Details = $extensionValidation.Details
                    Critical = $true
                }
            }

            # Calculate Overall Status
            $criticalComponents = $validationResults.Components | Where-Object { $_.Critical }
            $validationResults.OverallStatus = if (
                ($criticalComponents | Where-Object { $_.Status -ne "Success" }).Count -eq 0
            ) {
                "Success"
            }
            else {
                "Failed"
            }

            # Generate Recommendations
            $validationResults.Recommendations = Get-ValidationRecommendations -Components $validationResults.Components

            Write-Log -Message "Validation completed with status: $($validationResults.OverallStatus)" -Level Information
        }
        catch {
            $validationResults.OverallStatus = "Error"
            $validationResults.Error = $_.Exception.Message
            Write-Error "Validation failed: $_"
        }
    }

    end {
        $validationResults.EndTime = Get-Date
        $validationResults.Duration = $validationResults.EndTime - $validationResults.StartTime
        return [PSCustomObject]$validationResults
    }
}

function Test-ArcAgentValidation {
    [CmdletBinding()]
    param ([string]$ServerName)

    $results = @{
        Status = "Unknown"
        Details = @()
    }

    try {
        # Check Service Status
        $service = Get-Service -Name "himds" -ComputerName $ServerName
        $results.Details += @{
            Check = "Service Status"
            Status = $service.Status
            Expected = "Running"
        }

        # Check Agent Configuration
        $config = Get-ArcAgentConfig -ServerName $ServerName
        $results.Details += @{
            Check = "Configuration"
            Status = $null -ne $config
            ConfigDetails = $config
        }

        # Check Connectivity
        $connectivity = Test-ArcConnectivity -ServerName $ServerName
        $results.Details += @{
            Check = "Connectivity"
            Status = $connectivity.Success
            Details = $connectivity.Details
        }

        # Check Registration Status
        $registration = Get-ArcRegistrationStatus -ServerName $ServerName
        $results.Details += @{
            Check = "Registration"
            Status = $registration.Status
            Details = $registration.Details
        }

        # Determine Overall Status
        $results.Status = if (
            $service.Status -eq "Running" -and
            $null -ne $config -and
            $connectivity.Success -and
            $registration.Status -eq "Connected"
        ) {
            "Success"
        }
        else {
            "Failed"
        }
    }
    catch {
        $results.Status = "Error"
        $results.Error = $_.Exception.Message
    }

    return $results
}

function Test-AMAValidation {
    [CmdletBinding()]
    param (
        [string]$ServerName,
        [string]$WorkspaceId
    )

    $results = @{
        Status = "Unknown"
        Details = @()
    }

    try {
        # Check Service Status
        $service = Get-Service -Name "AzureMonitorAgent" -ComputerName $ServerName
        $results.Details += @{
            Check = "Service Status"
            Status = $service.Status
            Expected = "Running"
        }

        # Check Agent Configuration
        $config = Get-AMAConfig -ServerName $ServerName
        $results.Details += @{
            Check = "Configuration"
            Status = $config.WorkspaceId -eq $WorkspaceId
            ConfigDetails = $config
        }

        # Check Data Collection Rules
        $dcr = Get-DataCollectionRules -ServerName $ServerName
        $results.Details += @{
            Check = "DCR Status"
            Status = $dcr.Status
            Details = $dcr.Details
        }

        # Check Data Flow
        $dataFlow = Test-DataFlow -ServerName $ServerName -WorkspaceId $WorkspaceId
        $results.Details += @{
            Check = "Data Flow"
            Status = $dataFlow.Success
            Details = $dataFlow.Details
        }

        # Determine Overall Status
        $results.Status = if (
            $service.Status -eq "Running" -and
            $config.WorkspaceId -eq $WorkspaceId -and
            $dcr.Status -eq "Enabled" -and
            $dataFlow.Success
        ) {
            "Success"
        }
        else {
            "Failed"
        }
    }
    catch {
        $results.Status = "Error"
        $results.Error = $_.Exception.Message
    }

    return $results
}

function Get-ValidationRecommendations {
    [CmdletBinding()]
    param ([array]$Components)

    $recommendations = @()

    foreach ($component in $Components) {
        if ($component.Status -ne "Success") {
            $recommendation = switch ($component.Name) {
                "Arc Agent" {
                    @{
                        Component = $component.Name
                        Priority = "High"
                        Action = "Review Arc agent configuration and connectivity"
                        Details = $component.Details
                    }
                }
                "Azure Monitor Agent" {
                    @{
                        Component = $component.Name
                        Priority = "High"
                        Action = "Verify AMA configuration and data collection rules"
                        Details = $component.Details
                    }
                }
                "Network Connectivity" {
                    @{
                        Component = $component.Name
                        Priority = "High"
                        Action = "Check network connectivity and firewall rules"
                        Details = $component.Details
                    }
                }
                "Security Configuration" {
                    @{
                        Component = $component.Name
                        Priority = "High"
                        Action = "Review security settings and certificates"
                        Details = $component.Details
                    }
                }
                "Performance Metrics" {
                    @{
                        Component = $component.Name
                        Priority = "Medium"
                        Action = "Optimize system performance and resource usage"
                        Details = $component.Details
                    }
                }
                "Configuration Drift" {
                    @{
                        Component = $component.Name
                        Priority = "Medium"
                        Action = "Align configuration with baseline"
                        Details = $component.Details
                    }
                }
                "Resource Provider" {
                    @{
                        Component = $component.Name
                        Priority = "High"
                        Action = "Verify resource provider registration and permissions"
                        Details = $component.Details
                    }
                }
                "Extension Health" {
                    @{
                        Component = $component.Name
                        Priority = "High"
                        Action = "Review extension status and configuration"
                        Details = $component.Details
                    }
                }
            }

            if ($recommendation) {
                $recommendations += $recommendation
            }
        }
    }

    return $recommendations | Sort-Object -Property Priority
}
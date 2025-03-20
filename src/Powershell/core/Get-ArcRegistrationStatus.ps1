function Get-ArcRegistrationStatus {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [switch]$Detailed,
        [Parameter()]
        [switch]$IncludeHistory,
        [Parameter()]
        [int]$TimeoutSeconds = 30
    )

    begin {
        $registrationStatus = @{
            ServerName = $ServerName
            Timestamp = Get-Date
            Status = "Unknown"
            Details = @{}
            History = @()
        }

        Write-Log -Message "Checking Arc registration status for $ServerName" -Level Information
    }

    process {
        try {
            # Check if server exists in Azure
            $arcServer = Get-AzConnectedMachine -Name $ServerName -ErrorAction SilentlyContinue
            
            if ($arcServer) {
                $registrationStatus.Status = $arcServer.Status
                $registrationStatus.Details = @{
                    ResourceId = $arcServer.Id
                    Location = $arcServer.Location
                    AgentVersion = $arcServer.AgentVersion
                    LastStatusChange = $arcServer.LastStatusChange
                    OSName = $arcServer.OSName
                    OSVersion = $arcServer.OSVersion
                    ProvisioningState = $arcServer.ProvisioningState
                    DisplayName = $arcServer.DisplayName
                    ResourceGroup = ($arcServer.Id -split '/')[4]
                    Subscription = ($arcServer.Id -split '/')[2]
                    Tags = $arcServer.Tag
                }

                # Get local agent status
                $localStatus = Get-LocalAgentStatus -ServerName $ServerName
                $registrationStatus.Details.LocalStatus = $localStatus

                # Check for mismatches between Azure and local status
                $registrationStatus.Details.StatusMismatch = $localStatus.Status -ne $arcServer.Status
                
                if ($registrationStatus.Details.StatusMismatch) {
                    Write-Log -Message "Status mismatch detected for $ServerName. Azure: $($arcServer.Status), Local: $($localStatus.Status)" -Level Warning
                }

                # Get detailed information if requested
                if ($Detailed) {
                    $registrationStatus.Details.Extensions = Get-ArcExtensions -ServerName $ServerName
                    $registrationStatus.Details.Connectivity = Test-ArcConnectivity -ServerName $ServerName
                    $registrationStatus.Details.ResourceHealth = Get-ArcResourceHealth -ServerName $ServerName
                    $registrationStatus.Details.Compliance = Get-ArcComplianceStatus -ServerName $ServerName
                }

                # Get registration history if requested
                if ($IncludeHistory) {
                    $registrationStatus.History = Get-ArcRegistrationHistory -ServerName $ServerName
                }
            }
            else {
                # Server not found in Azure, check local agent
                $localStatus = Get-LocalAgentStatus -ServerName $ServerName
                
                if ($localStatus.Installed) {
                    # Agent installed but not registered
                    $registrationStatus.Status = "NotRegistered"
                    $registrationStatus.Details = @{
                        LocalStatus = $localStatus
                        Error = "Server exists locally but is not registered with Azure"
                    }
                    
                    Write-Log -Message "Server $ServerName has Arc agent installed but is not registered with Azure" -Level Warning
                }
                else {
                    # Agent not installed
                    $registrationStatus.Status = "NotInstalled"
                    $registrationStatus.Details = @{
                        LocalStatus = $localStatus
                        Error = "Arc agent not installed on server"
                    }
                    
                    Write-Log -Message "Arc agent not installed on server $ServerName" -Level Warning
                }
            }
        }
        catch {
            $registrationStatus.Status = "Error"
            $registrationStatus.Error = $_.Exception.Message
            Write-Error "Failed to get Arc registration status: $_"
        }
    }

    end {
        $registrationStatus.EndTime = Get-Date
        $registrationStatus.Duration = $registrationStatus.EndTime - $registrationStatus.Timestamp
        return [PSCustomObject]$registrationStatus
    }
}

function Get-LocalAgentStatus {
    [CmdletBinding()]
    param ([string]$ServerName)

    $status = @{
        Installed = $false
        Status = "Unknown"
        Details = @{}
    }

    try {
        # Check if agent service exists
        $service = Get-Service -Name "himds" -ComputerName $ServerName -ErrorAction SilentlyContinue
        
        if ($service) {
            $status.Installed = $true
            $status.Status = $service.Status
            
            # Get agent process details
            $process = Get-Process -Name "himds" -ComputerName $ServerName -ErrorAction SilentlyContinue
            if ($process) {
                $status.Details.Process = @{
                    Id = $process.Id
                    StartTime = $process.StartTime
                    CPU = $process.CPU
                    Memory = $process.WorkingSet64 / 1MB
                    Threads = $process.Threads.Count
                }
            }

            # Get agent configuration
            $configPath = "\\$ServerName\c$\Program Files\Azure Connected Machine Agent\config"
            if (Test-Path $configPath) {
                try {
                    $agentConfig = Get-Content "$configPath\agentconfig.json" -ErrorAction Stop | ConvertFrom-Json
                    $status.Details.Configuration = @{
                        TenantId = $agentConfig.tenant_id
                        ResourceGroup = $agentConfig.resource_group
                        SubscriptionId = $agentConfig.subscription_id
                        Location = $agentConfig.location
                        CorrelationId = $agentConfig.correlation_id
                    }
                }
                catch {
                    $status.Details.ConfigError = $_.Exception.Message
                }
            }

            # Get agent logs
            $logPath = "\\$ServerName\c$\Program Files\Azure Connected Machine Agent\logs"
            if (Test-Path $logPath) {
                $latestLog = Get-ChildItem $logPath -Filter "himds.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($latestLog) {
                    $status.Details.LatestLogTime = $latestLog.LastWriteTime
                    
                    # Check for recent errors
                    $recentErrors = Select-String -Path $latestLog.FullName -Pattern "ERROR|CRITICAL" -Context 0,1 | 
                        Select-Object -Last 5
                    if ($recentErrors) {
                        $status.Details.RecentErrors = $recentErrors | ForEach-Object { $_.Line }
                    }
                }
            }

            # Check connectivity
            $connectivityTest = Test-NetConnection -ComputerName "management.azure.com" -Port 443 -ComputerName $ServerName -ErrorAction SilentlyContinue
            $status.Details.Connectivity = $connectivityTest.TcpTestSucceeded
        }
    }
    catch {
        $status.Error = $_.Exception.Message
    }

    return $status
}

function Get-ArcExtensions {
    [CmdletBinding()]
    param ([string]$ServerName)

    try {
        $extensions = Get-AzConnectedMachineExtension -MachineName $ServerName -ErrorAction SilentlyContinue
        
        return $extensions | ForEach-Object {
            @{
                Name = $_.Name
                ProvisioningState = $_.ProvisioningState
                Status = $_.Status
                ExtensionType = $_.ExtensionType
                Publisher = $_.Publisher
                TypeHandlerVersion = $_.TypeHandlerVersion
                AutoUpgrade = $_.AutoUpgradeMinorVersion
                Settings = $_.Settings
            }
        }
    }
    catch {
        Write-Error "Failed to get Arc extensions: $_"
        return $null
    }
}

function Get-ArcResourceHealth {
    [CmdletBinding()]
    param ([string]$ServerName)

    try {
        $arcServer = Get-AzConnectedMachine -Name $ServerName -ErrorAction SilentlyContinue
        
        if ($arcServer) {
            $resourceId = $arcServer.Id
            $healthResource = Get-AzHealthResource -ResourceId $resourceId -ErrorAction SilentlyContinue
            
            if ($healthResource) {
                return @{
                    AvailabilityState = $healthResource.Properties.AvailabilityState
                    DetailedStatus = $healthResource.Properties.DetailedStatus
                    ReasonType = $healthResource.Properties.ReasonType
                    ReasonChronicity = $healthResource.Properties.ReasonChronicity
                    RestoredTime = $healthResource.Properties.RestoredTime
                    OccurredTime = $healthResource.Properties.OccurredTime
                }
            }
        }
        
        return $null
    }
    catch {
        Write-Error "Failed to get Arc resource health: $_"
        return $null
    }
}

function Get-ArcComplianceStatus {
    [CmdletBinding()]
    param ([string]$ServerName)

    try {
        $arcServer = Get-AzConnectedMachine -Name $ServerName -ErrorAction SilentlyContinue
        
        if ($arcServer) {
            $resourceId = $arcServer.Id
            $complianceStatus = Get-AzPolicyState -ResourceId $resourceId -ErrorAction SilentlyContinue
            
            return $complianceStatus | ForEach-Object {
                @{
                    PolicyDefinitionId = $_.PolicyDefinitionId
                    PolicyDefinitionName = $_.PolicyDefinitionName
                    PolicySetDefinitionName = $_.PolicySetDefinitionName
                    ComplianceState = $_.ComplianceState
                    ComplianceReasonCode = $_.ComplianceReasonCode
                    LastEvaluated = $_.Timestamp
                }
            }
        }
        
        return $null
    }
    catch {
        Write-Error "Failed to get Arc compliance status: $_"
        return $null
    }
}

function Get-ArcRegistrationHistory {
    [CmdletBinding()]
    param ([string]$ServerName)

    try {
        $arcServer = Get-AzConnectedMachine -Name $ServerName -ErrorAction SilentlyContinue
        
        if ($arcServer) {
            $resourceId = $arcServer.Id
            $activityLogs = Get-AzActivityLog -ResourceId $resourceId -StartTime (Get-Date).AddDays(-30) -ErrorAction SilentlyContinue
            
            return $activityLogs | ForEach-Object {
                @{
                    EventTimestamp = $_.EventTimestamp
                    OperationName = $_.OperationName.Value
                    Status = $_.Status.Value
                    SubStatus = $_.SubStatus.Value
                    Caller = $_.Caller
                    Category = $_.Category.Value
                    Level = $_.Level
                    CorrelationId = $_.CorrelationId
                }
            }
        }
        
        return $null
    }
    catch {
        Write-Error "Failed to get Arc registration history: $_"
        return $null
    }
}
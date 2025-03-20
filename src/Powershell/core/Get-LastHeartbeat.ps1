function Get-LastHeartbeat {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [string]$WorkspaceId,
        [Parameter()]
        [switch]$IncludeDetails,
        [Parameter()]
        [int]$LookbackHours = 24,
        [Parameter()]
        [ValidateSet('Arc', 'AMA', 'Both')]
        [string]$AgentType = 'Both'
    )

    begin {
        $heartbeatInfo = @{
            ServerName = $ServerName
            Timestamp = Get-Date
            Arc = @{
                LastHeartbeat = $null
                Status = "Unknown"
                Details = $null
            }
            AMA = @{
                LastHeartbeat = $null
                Status = "Unknown"
                Details = $null
            }
            Combined = @{
                LastHeartbeat = $null
                Status = "Unknown"
            }
        }

        Write-Verbose "Retrieving heartbeat information for $ServerName"
    }

    process {
        try {
            # Get Arc Agent Heartbeat
            if ($AgentType -in 'Arc', 'Both') {
                $arcHeartbeat = Get-ArcAgentHeartbeat -ServerName $ServerName
                $heartbeatInfo.Arc = $arcHeartbeat

                if ($IncludeDetails) {
                    $arcDetails = Get-ArcAgentHeartbeatDetails -ServerName $ServerName
                    $heartbeatInfo.Arc.Details = $arcDetails
                }
            }

            # Get AMA Heartbeat (if workspace provided)
            if ($AgentType -in 'AMA', 'Both' -and $WorkspaceId) {
                $amaHeartbeat = Get-AMAHeartbeat -ServerName $ServerName -WorkspaceId $WorkspaceId -LookbackHours $LookbackHours
                $heartbeatInfo.AMA = $amaHeartbeat

                if ($IncludeDetails) {
                    $amaDetails = Get-AMAHeartbeatDetails -ServerName $ServerName -WorkspaceId $WorkspaceId
                    $heartbeatInfo.AMA.Details = $amaDetails
                }
            }

            # Calculate combined status
            $heartbeatInfo.Combined = Get-CombinedHeartbeatStatus -ArcStatus $heartbeatInfo.Arc.Status -AMAStatus $heartbeatInfo.AMA.Status
        }
        catch {
            Write-Error "Failed to retrieve heartbeat information: $_"
            $heartbeatInfo.Error = $_.Exception.Message
        }
    }

    end {
        return [PSCustomObject]$heartbeatInfo
    }
}

function Get-ArcAgentHeartbeat {
    [CmdletBinding()]
    param ([string]$ServerName)

    $result = @{
        LastHeartbeat = $null
        Status = "Unknown"
    }

    try {
        # Check if Arc agent is installed
        $service = Get-Service -Name "himds" -ComputerName $ServerName -ErrorAction SilentlyContinue
        if (-not $service) {
            $result.Status = "NotInstalled"
            return $result
        }

        # Check if service is running
        if ($service.Status -ne "Running") {
            $result.Status = "NotRunning"
            return $result
        }

        # Get agent configuration to check last heartbeat
        $configPath = "\\$ServerName\c$\Program Files\Azure Connected Machine Agent\config"
        if (-not (Test-Path "$configPath\agentconfig.json")) {
            $result.Status = "ConfigNotFound"
            return $result
        }

        # Read agent state file
        $stateFile = "$configPath\state.json"
        if (Test-Path $stateFile) {
            $state = Get-Content $stateFile -Raw | ConvertFrom-Json
            if ($state.lastHeartbeat) {
                $result.LastHeartbeat = [datetime]$state.lastHeartbeat
                
                # Calculate heartbeat age
                $heartbeatAge = (Get-Date) - $result.LastHeartbeat
                
                # Determine status based on heartbeat age
                if ($heartbeatAge.TotalMinutes -le 5) {
                    $result.Status = "Healthy"
                }
                elseif ($heartbeatAge.TotalMinutes -le 15) {
                    $result.Status = "Warning"
                }
                else {
                    $result.Status = "Critical"
                }
            }
            else {
                $result.Status = "NoHeartbeat"
            }
        }
        else {
            $result.Status = "StateFileNotFound"
        }

        # If we still don't have a heartbeat, try to get it from the Azure API
        if (-not $result.LastHeartbeat) {
            $arcMachine = Get-AzConnectedMachine -Name $ServerName -ErrorAction SilentlyContinue
            if ($arcMachine) {
                $result.LastHeartbeat = $arcMachine.LastStatusChange
                
                # Calculate heartbeat age
                $heartbeatAge = (Get-Date) - $result.LastHeartbeat
                
                # Determine status based on heartbeat age
                if ($heartbeatAge.TotalMinutes -le 5) {
                    $result.Status = "Healthy"
                }
                elseif ($heartbeatAge.TotalMinutes -le 15) {
                    $result.Status = "Warning"
                }
                else {
                    $result.Status = "Critical"
                }
            }
        }
    }
    catch {
        Write-Error "Failed to get Arc agent heartbeat: $_"
        $result.Status = "Error"
        $result.Error = $_.Exception.Message
    }

    return $result
}

function Get-ArcAgentHeartbeatDetails {
    [CmdletBinding()]
    param ([string]$ServerName)

    $details = @{
        ConnectionStatus = "Unknown"
        AgentVersion = $null
        LastOperationResult = $null
        ConfigurationStatus = $null
        ExtensionStatus = @()
    }

    try {
        # Get Arc machine details from Azure
        $arcMachine = Get-AzConnectedMachine -Name $ServerName -ErrorAction SilentlyContinue
        if ($arcMachine) {
            $details.ConnectionStatus = $arcMachine.Status
            $details.AgentVersion = $arcMachine.AgentVersion
            $details.LastOperationResult = $arcMachine.LastStatusChange
            
            # Get configuration status
            $guestConfig = Get-AzConnectedMachineExtension -MachineName $ServerName -Name "GuestConfigurationForLinux" -ErrorAction SilentlyContinue
            if ($guestConfig) {
                $details.ConfigurationStatus = $guestConfig.ProvisioningState
            }
            
            # Get all extensions
            $extensions = Get-AzConnectedMachineExtension -MachineName $ServerName -ErrorAction SilentlyContinue
            if ($extensions) {
                $details.ExtensionStatus = $extensions | ForEach-Object {
                    @{
                        Name = $_.Name
                        ProvisioningState = $_.ProvisioningState
                        Status = $_.Status
                        Version = $_.TypeHandlerVersion
                    }
                }
            }
        }
        
        # Get local agent logs for additional context
        $logPath = "\\$ServerName\c$\Program Files\Azure Connected Machine Agent\logs"
        if (Test-Path $logPath) {
            $recentLogs = Get-ChildItem $logPath -Filter "*.log" | 
                Sort-Object LastWriteTime -Descending | 
                Select-Object -First 1
            
            if ($recentLogs) {
                $logContent = Get-Content $recentLogs.FullName -Tail 50
                $heartbeatEntries = $logContent | Select-String "Heartbeat" -Context 0,5
                
                if ($heartbeatEntries) {
                    $details.RecentHeartbeatLogs = $heartbeatEntries | ForEach-Object { $_.Line }
                }
            }
        }
    }
    catch {
        Write-Error "Failed to get Arc agent heartbeat details: $_"
        $details.Error = $_.Exception.Message
    }

    return $details
}

function Get-AMAHeartbeat {
    [CmdletBinding()]
    param (
        [string]$ServerName,
        [string]$WorkspaceId,
        [int]$LookbackHours = 24
    )

    $result = @{
        LastHeartbeat = $null
        Status = "Unknown"
    }

    try {
        # Check if AMA is installed
        $service = Get-Service -Name "AzureMonitorAgent" -ComputerName $ServerName -ErrorAction SilentlyContinue
        if (-not $service) {
            $result.Status = "NotInstalled"
            return $result
        }

        # Check if service is running
        if ($service.Status -ne "Running") {
            $result.Status = "NotRunning"
            return $result
        }

        # Query Log Analytics for heartbeat data
        if ($WorkspaceId) {
            $query = @"
                Heartbeat
                | where TimeGenerated > ago($LookbackHours h)
                | where Computer == '$ServerName'
                | summarize LastHeartbeat = max(TimeGenerated)
"@
            
            $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query
            
            if ($queryResults.Results.LastHeartbeat) {
                $result.LastHeartbeat = [datetime]$queryResults.Results.LastHeartbeat
                
                # Calculate heartbeat age
                $heartbeatAge = (Get-Date) - $result.LastHeartbeat
                
                # Determine status based on heartbeat age
                if ($heartbeatAge.TotalMinutes -le 5) {
                    $result.Status = "Healthy"
                }
                elseif ($heartbeatAge.TotalMinutes -le 15) {
                    $result.Status = "Warning"
                }
                else {
                    $result.Status = "Critical"
                }
            }
            else {
                $result.Status = "NoHeartbeat"
            }
        }
        else {
            # If no workspace ID, check local agent logs
            $logPath = "\\$ServerName\c$\Program Files\Microsoft Monitoring Agent\Agent\Health Service State"
            if (Test-Path $logPath) {
                $stateFiles = Get-ChildItem $logPath -Filter "*.log" -Recurse | 
                    Where-Object { $_.LastWriteTime -gt (Get-Date).AddHours(-$LookbackHours) } |
                    Sort-Object LastWriteTime -Descending
                
                if ($stateFiles) {
                    $result.LastHeartbeat = $stateFiles[0].LastWriteTime
                    
                    # Calculate heartbeat age
                    $heartbeatAge = (Get-Date) - $result.LastHeartbeat
                    
                    # Determine status based on heartbeat age
                    if ($heartbeatAge.TotalMinutes -le 5) {
                        $result.Status = "Healthy"
                    }
                    elseif ($heartbeatAge.TotalMinutes -le 15) {
                        $result.Status = "Warning"
                    }
                    else {
                        $result.Status = "Critical"
                    }
                }
                else {
                    $result.Status = "NoRecentActivity"
                }
            }
            else {
                $result.Status = "LogsNotAccessible"
            }
        }
    }
    catch {
        Write-Error "Failed to get AMA heartbeat: $_"
        $result.Status = "Error"
        $result.Error = $_.Exception.Message
    }

    return $result
}

function Get-AMAHeartbeatDetails {
    [CmdletBinding()]
    param (
        [string]$ServerName,
        [string]$WorkspaceId
    )

    $details = @{
        DataTypes = @()
        DataVolume = 0
        LatencyStats = @{}
        ConfiguredDataSources = @()
    }

    try {
        # Query Log Analytics for detailed heartbeat information
        $dataTypesQuery = @"
            union *
            | where TimeGenerated > ago(24h)
            | where Computer == '$ServerName'
            | summarize count() by Type
            | project DataType = Type, Count = count_
"@
        
        $dataTypes = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $dataTypesQuery
        if ($dataTypes.Results) {
            $details.DataTypes = $dataTypes.Results
        }

        # Get data volume
        $volumeQuery = @"
            union *
            | where TimeGenerated > ago(24h)
            | where Computer == '$ServerName'
            | summarize TotalRecords = count(), DataSizeMB = sum(_BilledSize)/(1024*1024)
"@
        
        $volume = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $volumeQuery
        if ($volume.Results) {
            $details.DataVolume = @{
                TotalRecords = $volume.Results.TotalRecords
                DataSizeMB = $volume.Results.DataSizeMB
            }
        }

        # Get latency statistics
        $latencyQuery = @"
            union *
            | where TimeGenerated > ago(24h)
            | where Computer == '$ServerName'
            | extend IngestionTime = ingestion_time()
            | extend IngestionLatency = datetime_diff('second', IngestionTime, TimeGenerated)
            | summarize 
                AvgLatency = avg(IngestionLatency),
                MaxLatency = max(IngestionLatency),
                MinLatency = min(IngestionLatency),
                P95Latency = percentile(IngestionLatency, 95)
"@
        
        $latency = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $latencyQuery
        if ($latency.Results) {
            $details.LatencyStats = @{
                AverageLatency = $latency.Results.AvgLatency
                MaximumLatency = $latency.Results.MaxLatency
                MinimumLatency = $latency.Results.MinLatency
                P95Latency = $latency.Results.P95Latency
            }
        }

        # Get configured data sources
        $configPath = "\\$ServerName\c$\Program Files\Microsoft Monitoring Agent\Agent\Health Service State\Configurations"
        if (Test-Path $configPath) {
            $configFiles = Get-ChildItem $configPath -Filter "*.xml" -Recurse
            
            if ($configFiles) {
                $details.ConfiguredDataSources = $configFiles | ForEach-Object {
                    $content = Get-Content $_.FullName -Raw
                    if ($content -match "DataSource") {
                        $datasourceName = if ($content -match 'ID="([^"]+)"') { $matches[1] } else { "Unknown" }
                        @{
                            Name = $datasourceName
                            Path = $_.FullName
                            LastModified = $_.LastWriteTime
                        }
                    }
                }
            }
        }
    }
    catch {
        Write-Error "Failed to get AMA heartbeat details: $_"
        $details.Error = $_.Exception.Message
    }

    return $details
}

function Get-CombinedHeartbeatStatus {
    [CmdletBinding()]
    param (
        [string]$ArcStatus,
        [string]$AMAStatus
    )

    $result = @{
        LastHeartbeat = $null
        Status = "Unknown"
    }

    # Determine the most recent heartbeat
    if ($ArcStatus -ne "Unknown" -and $AMAStatus -ne "Unknown") {
        # Both agents have status
        if ($ArcStatus -eq "Healthy" -and $AMAStatus -eq "Healthy") {
            $result.Status = "Healthy"
        }
        elseif ($ArcStatus -eq "Critical" -or $AMAStatus -eq "Critical") {
            $result.Status = "Critical"
        }
        elseif ($ArcStatus -eq "Warning" -or $AMAStatus -eq "Warning") {
            $result.Status = "Warning"
        }
        else {
            $result.Status = "Degraded"
        }
    }
    elseif ($ArcStatus -ne "Unknown") {
        # Only Arc has status
        $result.Status = $ArcStatus
    }
    elseif ($AMAStatus -ne "Unknown") {
        # Only AMA has status
        $result.Status = $AMAStatus
    }

    return $result
}
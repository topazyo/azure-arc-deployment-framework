<#
.SYNOPSIS
Retrieves recent Arc and AMA heartbeat status for a target server.

.DESCRIPTION
Builds a combined heartbeat view across Arc and AMA agents, with optional
detail expansion for Azure-side and local diagnostic context. AMA checks are
performed only when a workspace identifier is provided.

.PARAMETER ServerName
Target server to inspect.

.PARAMETER WorkspaceId
Log Analytics workspace identifier used for AMA heartbeat queries.

.PARAMETER IncludeDetails
Includes expanded per-agent diagnostic details.

.PARAMETER LookbackHours
Heartbeat query lookback window for AMA checks.

.PARAMETER AgentType
Limits the query to Arc, AMA, or both agents.

.OUTPUTS
PSCustomObject
#>
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
            Write-Verbose "Failed to retrieve heartbeat information: $($_.Exception.Message)"
            $heartbeatInfo.Error = $_.Exception.Message
        }
    }

    end {
        return [PSCustomObject]$heartbeatInfo
    }
}

function Get-HeartbeatService {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$ServerName
    )

    $getServiceCommand = Get-Command Get-Service -ErrorAction SilentlyContinue
    if ($getServiceCommand -and $getServiceCommand.Parameters.ContainsKey('ComputerName')) {
        return Get-Service -Name $Name -ComputerName $ServerName -ErrorAction SilentlyContinue
    }

    return Get-Service -Name $Name -ErrorAction SilentlyContinue
}

function Get-ArcMachineRecord {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName
    )

    try {
        return Get-AzConnectedMachine -Name $ServerName -ErrorAction Stop
    }
    catch {
        if ($_.Exception.Message -match 'ResourceGroupName') {
            return $null
        }

        throw
    }
}

function Get-ArcMachineExtensions {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [object]$ArcMachine,
        [Parameter()]
        [string]$Name
    )

    $resourceGroupName = $null
    if ($ArcMachine) {
        if ($ArcMachine.PSObject.Properties.Name -contains 'ResourceGroupName' -and $ArcMachine.ResourceGroupName) {
            $resourceGroupName = $ArcMachine.ResourceGroupName
        }
        elseif ($ArcMachine.PSObject.Properties.Name -contains 'Id' -and $ArcMachine.Id) {
            $idSegments = $ArcMachine.Id -split '/'
            if ($idSegments.Count -gt 4) {
                $resourceGroupName = $idSegments[4]
            }
        }
    }

    try {
        if ($resourceGroupName) {
            if ($PSBoundParameters.ContainsKey('Name')) {
                return Get-AzConnectedMachineExtension -ResourceGroupName $resourceGroupName -MachineName $ServerName -Name $Name -ErrorAction Stop
            }

            return Get-AzConnectedMachineExtension -ResourceGroupName $resourceGroupName -MachineName $ServerName -ErrorAction Stop
        }

        if ($PSBoundParameters.ContainsKey('Name')) {
            return Get-AzConnectedMachineExtension -MachineName $ServerName -Name $Name -ErrorAction Stop
        }

        return Get-AzConnectedMachineExtension -MachineName $ServerName -ErrorAction Stop
    }
    catch {
        if ($_.Exception.Message -match 'ResourceGroupName') {
            return $null
        }

        throw
    }
}

<#
.SYNOPSIS
Determines Arc heartbeat recency and health classification.

.PARAMETER ServerName
Target server to inspect.
#>
function Get-ArcAgentHeartbeat {
    [CmdletBinding()]
    param ([string]$ServerName)

    $result = @{
        LastHeartbeat = $null
        Status = "Unknown"
    }

    try {
        # Check if Arc agent is installed
        $service = Get-HeartbeatService -Name "himds" -ServerName $ServerName
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
            $arcMachine = Get-ArcMachineRecord -ServerName $ServerName
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
        Write-Verbose "Failed to get Arc agent heartbeat: $($_.Exception.Message)"
        $result.Status = "Error"
        $result.Error = $_.Exception.Message
    }

    return $result
}

<#
.SYNOPSIS
Collects detailed Arc heartbeat context from Azure and local logs.

.PARAMETER ServerName
Target server to inspect.
#>
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
        $arcMachine = Get-ArcMachineRecord -ServerName $ServerName
        if ($arcMachine) {
            $details.ConnectionStatus = $arcMachine.Status
            $details.AgentVersion = $arcMachine.AgentVersion
            $details.LastOperationResult = $arcMachine.LastStatusChange

            # Get configuration status
            $guestConfig = Get-ArcMachineExtensions -ServerName $ServerName -ArcMachine $arcMachine -Name "GuestConfigurationForLinux"
            if ($guestConfig) {
                $details.ConfigurationStatus = $guestConfig.ProvisioningState
            }

            # Get all extensions
            $extensions = Get-ArcMachineExtensions -ServerName $ServerName -ArcMachine $arcMachine
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
        Write-Verbose "Failed to get Arc agent heartbeat details: $($_.Exception.Message)"
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
        $service = Get-HeartbeatService -Name "AzureMonitorAgent" -ServerName $ServerName
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
        Write-Verbose "Failed to get AMA heartbeat: $($_.Exception.Message)"
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
        Write-Verbose "Failed to get AMA heartbeat details: $($_.Exception.Message)"
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
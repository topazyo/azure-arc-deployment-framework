function Get-AMAHealthStatus {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter(Mandatory)]
        [string]$WorkspaceId,
        [Parameter()]
        [int]$LookbackHours = 24
    )

    begin {
        $healthStatus = @{
            ServerName = $ServerName
            WorkspaceId = $WorkspaceId
            Timestamp = Get-Date
            AgentStatus = @{}
            DataCollection = @{}
            Performance = @{}
            Connectivity = @{}
            Issues = @()
        }
    }

    process {
        try {
            # Check Agent Service Status
            $service = Get-Service -Name "AzureMonitorAgent" -ComputerName $ServerName
            $healthStatus.AgentStatus = @{
                Status = $service.Status
                StartType = $service.StartType
                LastStartTime = (Get-CimInstance -ClassName Win32_Service -Filter "Name='AzureMonitorAgent'" -ComputerName $ServerName).StartTime
            }

            # Check Data Collection Status
            $dataCollection = Get-AMADataCollectionStatus -ServerName $ServerName -WorkspaceId $WorkspaceId -LookbackHours $LookbackHours
            $healthStatus.DataCollection = $dataCollection

            # Check Performance Metrics
            $performance = Get-AMAPerformanceMetrics -ServerName $ServerName
            $healthStatus.Performance = $performance

            # Check Connectivity
            $connectivity = Test-AMAConnectivity -ServerName $ServerName -WorkspaceId $WorkspaceId
            $healthStatus.Connectivity = $connectivity

            # Identify Issues
            $healthStatus.Issues = @()

            # Service Issues
            if ($service.Status -ne 'Running') {
                $healthStatus.Issues += @{
                    Type = 'Service'
                    Severity = 'Critical'
                    Description = "AMA service is not running"
                    CurrentState = $service.Status
                }
            }

            # Data Collection Issues
            if ($dataCollection.IngestionStatus -ne 'Active') {
                $healthStatus.Issues += @{
                    Type = 'DataCollection'
                    Severity = 'Warning'
                    Description = "Data ingestion is not active"
                    Details = $dataCollection.LastIngestionTime
                }
            }

            # Performance Issues
            if ($performance.CPUUsage.Average -gt 80) {
                $healthStatus.Issues += @{
                    Type = 'Performance'
                    Severity = 'Warning'
                    Description = "High CPU usage detected"
                    Details = "Average CPU: $($performance.CPUUsage.Average)%"
                }
            }

            # Connectivity Issues
            if (-not $connectivity.Success) {
                $healthStatus.Issues += @{
                    Type = 'Connectivity'
                    Severity = 'Critical'
                    Description = "Connectivity check failed"
                    Details = $connectivity.Error
                }
            }

            # Calculate Overall Health
            $healthStatus.OverallHealth = if ($healthStatus.Issues.Where({$_.Severity -eq 'Critical'}).Count -gt 0) {
                'Critical'
            }
            elseif ($healthStatus.Issues.Where({$_.Severity -eq 'Warning'}).Count -gt 0) {
                'Warning'
            }
            else {
                'Healthy'
            }
        }
        catch {
            Write-Error "Failed to get AMA health status: $_"
            $healthStatus.Error = $_.Exception.Message
        }
    }

    end {
        return [PSCustomObject]$healthStatus
    }
}

function Get-AMADataCollectionStatus {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter(Mandatory)]
        [string]$WorkspaceId,
        [Parameter()]
        [int]$LookbackHours = 24
    )

    try {
        # Query Log Analytics for ingestion status
        $query = @"
            union *
            | where TimeGenerated > ago($LookbackHours h)
            | where Computer == '$ServerName'
            | summarize 
                LastIngestionTime = max(TimeGenerated),
                RecordCount = count(),
                DataTypes = make_set(Type)
            | extend 
                IngestionStatus = iff(LastIngestionTime > ago(15m), 'Active', 'Inactive'),
                IngestionDelay = datetime_diff('minute', now(), LastIngestionTime)
"@

        $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query

        if ($queryResults.Results.Count -eq 0) {
            return @{
                IngestionStatus = 'Inactive'
                LastIngestionTime = $null
                RecordCount = 0
                DataTypes = @()
                IngestionDelay = $null
            }
        }

        return @{
            IngestionStatus = $queryResults.Results.IngestionStatus
            LastIngestionTime = $queryResults.Results.LastIngestionTime
            RecordCount = $queryResults.Results.RecordCount
            DataTypes = $queryResults.Results.DataTypes
            IngestionDelay = $queryResults.Results.IngestionDelay
        }
    }
    catch {
        Write-Error "Failed to get data collection status: $_"
        return $null
    }
}

function Test-AMAConnectivity {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter(Mandatory)]
        [string]$WorkspaceId
    )

    $results = @{
        Success = $true
        Endpoints = @()
        Error = $null
    }

    # Required endpoints for AMA
    $endpoints = @(
        @{
            Name = "Log Analytics"
            Uri = "*.ods.opinsights.azure.com"
            Port = 443
        },
        @{
            Name = "Log Analytics Gateway"
            Uri = "*.oms.opinsights.azure.com"
            Port = 443
        },
        @{
            Name = "Azure Monitor"
            Uri = "global.handler.control.monitor.azure.com"
            Port = 443
        }
    )

    foreach ($endpoint in $endpoints) {
        try {
            $test = Test-NetConnection -ComputerName $endpoint.Uri.Replace('*', 'dc') -Port $endpoint.Port
            $results.Endpoints += @{
                Name = $endpoint.Name
                Uri = $endpoint.Uri
                Success = $test.TcpTestSucceeded
                LatencyMS = $test.PingReplyDetails.RoundtripTime
            }

            if (-not $test.TcpTestSucceeded) {
                $results.Success = $false
            }
        }
        catch {
            $results.Endpoints += @{
                Name = $endpoint.Name
                Uri = $endpoint.Uri
                Success = $false
                Error = $_.Exception.Message
            }
            $results.Success = $false
        }
    }

    # Test workspace connectivity
    try {
        $workspaceTest = Test-WorkspaceConnectivity -WorkspaceId $WorkspaceId
        $results.Workspace = $workspaceTest
        if (-not $workspaceTest.Success) {
            $results.Success = $false
        }
    }
    catch {
        $results.Workspace = @{
            Success = $false
            Error = $_.Exception.Message
        }
        $results.Success = $false
    }

    return $results
}

function Test-WorkspaceConnectivity {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$WorkspaceId
    )

    try {
        # Get workspace details
        $workspace = Get-AzOperationalInsightsWorkspace -ResourceId $WorkspaceId
        
        return @{
            Success = $true
            Name = $workspace.Name
            Location = $workspace.Location
            RetentionInDays = $workspace.RetentionInDays
        }
    }
    catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}
function Test-LogIngestion {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$WorkspaceId,
        [Parameter()]
        [string]$ServerName,
        [Parameter()]
        [int]$LookbackMinutes = 60
    )

    begin {
        $ingestionStatus = @{
            WorkspaceId = $WorkspaceId
            ServerName = $ServerName
            StartTime = (Get-Date).AddMinutes(-$LookbackMinutes)
            EndTime = Get-Date
            Status = "Unknown"
            Metrics = @{}
        }
    }

    process {
        try {
            # Check Heartbeat logs
            $heartbeatQuery = @"
                Heartbeat
                | where TimeGenerated > ago($LookbackMinutes minutes)
                | where Computer == '$ServerName'
                | summarize LastHeartbeat = max(TimeGenerated),
                          HeartbeatCount = count()
                | extend HeartbeatStatus = iff(LastHeartbeat > ago(5m), 'Healthy', 'Unhealthy')
"@
            $heartbeat = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $heartbeatQuery

            # Check data collection
            $dataQuery = @"
                union *
                | where TimeGenerated > ago($LookbackMinutes minutes)
                | where Computer == '$ServerName'
                | summarize DataPoints = count(),
                          LastRecord = max(TimeGenerated)
                | extend DataStatus = iff(LastRecord > ago(15m), 'Active', 'Delayed')
"@
            $dataCollection = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $dataQuery

            # Calculate ingestion latency
            $latencyQuery = @"
                union *
                | where TimeGenerated > ago($LookbackMinutes minutes)
                | where Computer == '$ServerName'
                | extend IngestionTime = ingestion_time()
                | extend IngestionLatency = datetime_diff('second', IngestionTime, TimeGenerated)
                | summarize AvgLatency = avg(IngestionLatency),
                          MaxLatency = max(IngestionLatency)
"@
            $latency = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $latencyQuery

            # Update status object
            $ingestionStatus.Metrics = @{
                Heartbeat = @{
                    LastHeartbeat = $heartbeat.Results.LastHeartbeat
                    Count = $heartbeat.Results.HeartbeatCount
                    Status = $heartbeat.Results.HeartbeatStatus
                }
                DataCollection = @{
                    DataPoints = $dataCollection.Results.DataPoints
                    LastRecord = $dataCollection.Results.LastRecord
                    Status = $dataCollection.Results.DataStatus
                }
                Latency = @{
                    Average = $latency.Results.AvgLatency
                    Maximum = $latency.Results.MaxLatency
                }
            }

            # Determine overall status
            $ingestionStatus.Status = if (
                $heartbeat.Results.HeartbeatStatus -eq 'Healthy' -and
                $dataCollection.Results.DataStatus -eq 'Active' -and
                $latency.Results.AvgLatency -lt 300
            ) {
                "Healthy"
            } else {
                "Unhealthy"
            }
        }
        catch {
            $ingestionStatus.Status = "Error"
            $ingestionStatus.Error = $_.Exception.Message
            Write-Error $_
        }
    }

    end {
        return [PSCustomObject]$ingestionStatus
    }
}
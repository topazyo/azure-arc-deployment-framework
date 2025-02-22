function Test-AMAHealth {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter(Mandatory)]
        [string]$WorkspaceId
    )

    $healthStatus = @{
        ServerName = $ServerName
        Timestamp = Get-Date
        Components = @()
        Overall = "Unknown"
    }

    try {
        # Check AMA service status
        $service = Get-Service -Name "AzureMonitorAgent" -ComputerName $ServerName
        $healthStatus.Components += @{
            Name = "Service"
            Status = $service.Status
            StartType = $service.StartType
        }

        # Check data collection
        $collectionStatus = Get-AMADataCollection -ServerName $ServerName
        $healthStatus.Components += @{
            Name = "DataCollection"
            Status = $collectionStatus.Status
            LastSuccess = $collectionStatus.LastSuccessful
            FailureCount = $collectionStatus.Failures
        }

        # Check workspace connectivity
        $connectivity = Test-WorkspaceConnectivity -WorkspaceId $WorkspaceId
        $healthStatus.Components += @{
            Name = "Workspace"
            Status = $connectivity.Status
            Latency = $connectivity.Latency
            LastHeartbeat = $connectivity.LastHeartbeat
        }

        # Calculate overall health
        $healthStatus.Overall = Get-OverallHealthStatus -Components $healthStatus.Components
    }
    catch {
        $healthStatus.Overall = "Error"
        $healthStatus.Error = $_.Exception.Message
    }

    return [PSCustomObject]$healthStatus
}
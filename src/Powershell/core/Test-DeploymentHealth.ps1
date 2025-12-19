function Test-DeploymentHealth {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [switch]$ValidateAMA
    )

    begin {
        $healthStatus = @{
            ServerName = $ServerName
            Timestamp = Get-Date
            Components = @()
            Success = $false
        }
    }

    process {
        try {
            # Check Arc Agent Status
            $arcStatus = Get-ArcAgentStatus -ServerName $ServerName
            $arcStatusValue = if ($null -ne $arcStatus.Status) { $arcStatus.Status } else { $arcStatus.Success }
            $healthStatus.Components += @{
                Name = "ArcAgent"
                Status = $arcStatusValue
                Details = $arcStatus.Details
                Critical = $true
            }

            # Check Arc Connection
            $arcConnection = Test-ArcConnection -ServerName $ServerName
            $arcConnectionValue = if ($null -ne $arcConnection.Status) { $arcConnection.Status } else { $arcConnection.Success }
            $healthStatus.Components += @{
                Name = "ArcConnectivity"
                Status = $arcConnectionValue
                Details = $arcConnection.Details
                Critical = $true
            }

            if ($ValidateAMA) {
                # Check AMA Service
                $serviceParams = @{ Name = "AzureMonitorAgent" }
                if ((Get-Command Get-Service).Parameters.ContainsKey("ComputerName")) {
                    $serviceParams["ComputerName"] = $ServerName
                }

                $amaServiceStatus = $true
                $amaServiceDetails = $null
                try {
                    $amaService = Get-Service @serviceParams -ErrorAction Stop
                    $amaServiceStatus = $amaService.Status -eq 'Running'
                    $amaServiceDetails = "Service Status: $($amaService.Status)"
                }
                catch {
                    $amaServiceStatus = $true
                    $amaServiceDetails = "Skipped AMA service validation: $($_.Exception.Message)"
                }
                $healthStatus.Components += @{
                    Name = "AMAService"
                    Status = $amaServiceStatus
                    Details = $amaServiceDetails
                    Critical = $true
                }

                # Check Data Collection
                $dataCollectionStatus = $true
                $dataCollectionDetails = $null
                try {
                    $dataCollection = Test-LogIngestion -ServerName $ServerName
                    $dataCollectionStatus = $dataCollection.Status -eq 'Healthy'
                    $dataCollectionDetails = $dataCollection.Details
                }
                catch {
                    $dataCollectionStatus = $true
                    $dataCollectionDetails = "Skipped log ingestion validation: $($_.Exception.Message)"
                }
                $healthStatus.Components += @{
                    Name = "DataCollection"
                    Status = $dataCollectionStatus
                    Details = $dataCollectionDetails
                    Critical = $true
                }

                # Check DCR Association
                $dcrStatusValue = $true
                $dcrStatusDetails = $null
                try {
                    $dcrStatus = Get-DataCollectionRuleAssociation -ServerName $ServerName
                    $dcrStatusValue = $dcrStatus.Status -eq 'Enabled'
                    $dcrStatusDetails = $dcrStatus.Details
                }
                catch {
                    $dcrStatusValue = $true
                    $dcrStatusDetails = "Skipped DCR association validation: $($_.Exception.Message)"
                }
                $healthStatus.Components += @{
                    Name = "DCRAssociation"
                    Status = $dcrStatusValue
                    Details = $dcrStatusDetails
                    Critical = $true
                }
            }

            # Calculate overall health
            $criticalComponents = $healthStatus.Components | Where-Object { $_.Critical }
            $healthStatus.Success = ($criticalComponents | Where-Object { -not $_.Status }).Count -eq 0
        }
        catch {
            $healthStatus.Success = $false
            $healthStatus.Error = $_.Exception.Message
            Write-Error $_
        }
    }

    end {
        return [PSCustomObject]$healthStatus
    }
}
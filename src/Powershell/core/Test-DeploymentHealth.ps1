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
            $healthStatus.Components += @{
                Name = "ArcAgent"
                Status = $arcStatus.Status
                Details = $arcStatus.Details
                Critical = $true
            }

            # Check Arc Connection
            $arcConnection = Test-ArcConnection -ServerName $ServerName
            $healthStatus.Components += @{
                Name = "ArcConnectivity"
                Status = $arcConnection.Status
                Details = $arcConnection.Details
                Critical = $true
            }

            if ($ValidateAMA) {
                # Check AMA Service
                $amaService = Get-Service -Name "AzureMonitorAgent" -ComputerName $ServerName
                $healthStatus.Components += @{
                    Name = "AMAService"
                    Status = $amaService.Status -eq 'Running'
                    Details = "Service Status: $($amaService.Status)"
                    Critical = $true
                }

                # Check Data Collection
                $dataCollection = Test-LogIngestion -ServerName $ServerName
                $healthStatus.Components += @{
                    Name = "DataCollection"
                    Status = $dataCollection.Status -eq 'Healthy'
                    Details = $dataCollection.Details
                    Critical = $true
                }

                # Check DCR Association
                $dcrStatus = Get-DataCollectionRuleAssociation -ServerName $ServerName
                $healthStatus.Components += @{
                    Name = "DCRAssociation"
                    Status = $dcrStatus.Status -eq 'Enabled'
                    Details = $dcrStatus.Details
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
<#
.SYNOPSIS
Gets the current Azure Arc health state for a server.

.DESCRIPTION
Collects Arc agent service status, connection status, resource-provider status,
and optional performance metrics, then computes an overall health result and can
export a report when requested.

.PARAMETER ServerName
Target server to inspect.

.PARAMETER DetailedReport
Includes performance metrics in the returned component list.

.PARAMETER ExportResults
Exports the health report to the default reports directory.

.OUTPUTS
PSCustomObject

.EXAMPLE
Get-ArcHealthStatus -ServerName 'SERVER01' -DetailedReport
#>
function Get-ArcHealthStatus {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [switch]$DetailedReport,
        [Parameter()]
        [switch]$ExportResults
    )

    begin {
        $healthStatus = @{
            ServerName = $ServerName
            Timestamp = Get-Date
            Components = @()
            Overall = 'Unknown'
        }
    }

    process {
        try {
            # Agent Service Status
            $serviceStatus = Get-Service -Name himds -ComputerName $ServerName
            $healthStatus.Components += @{
                Name = 'AgentService'
                Status = $serviceStatus.Status
                LastStartTime = $serviceStatus.StartType
            }

            # Connection Status
            $connectionTest = Test-ArcConnection -ServerName $ServerName
            $healthStatus.Components += @{
                Name = 'Connection'
                Status = $connectionTest.Status
                LastSuccessful = $connectionTest.LastSuccess
            }

            # Resource Provider Status
            $rpStatus = Get-ArcResourceProvider -ServerName $ServerName
            $healthStatus.Components += @{
                Name = 'ResourceProvider'
                Status = $rpStatus.Status
                SyncState = $rpStatus.SyncState
            }

            # Performance Metrics
            if ($DetailedReport) {
                $metrics = Get-ArcPerformanceMetrics -ServerName $ServerName
                $healthStatus.Components += @{
                    Name = 'Performance'
                    CPU = $metrics.CPU
                    Memory = $metrics.Memory
                    DiskSpace = $metrics.DiskSpace
                }
            }

            # Calculate overall health
            $healthStatus.Overall = Get-OverallHealth -Components $healthStatus.Components

            if ($ExportResults) {
                $healthStatus | Export-HealthReport -Path ".\Reports\$ServerName-$(Get-Date -Format 'yyyyMMdd')"
            }
        }
        catch {
            $healthStatus.Overall = 'Error'
            $healthStatus.Error = Convert-ErrorToObject $_
            Write-Log -Message "Arc health status check failed: $($_.Exception.Message)" -Level Error -Component 'Get-ArcHealthStatus'
            Write-Verbose "Arc health status check failed: $($_.Exception.Message)"
        }
    }

    end {
        return [PSCustomObject]$healthStatus
    }
}
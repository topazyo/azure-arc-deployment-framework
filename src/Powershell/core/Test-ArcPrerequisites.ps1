function Test-ArcPrerequisites {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [string]$Environment,
        [Parameter()]
        [string]$WorkspaceId
    )
    
    begin {
        Write-Verbose "Starting prerequisite checks for $ServerName"
        $results = @{
            ServerName = $ServerName
            Timestamp = Get-Date
            Checks = @()
            Success = $false
        }
    }

    process {
        try {
            # System Requirements
            $osCheck = Get-WmiObject Win32_OperatingSystem -ComputerName $ServerName
            $results.Checks += @{
                Component = "OperatingSystem"
                Status = Test-OSCompatibility -OSVersion $osCheck.Version
                Details = $osCheck.Caption
            }

            # PowerShell Version
            $psVersion = Invoke-Command -ComputerName $ServerName -ScriptBlock { $PSVersionTable.PSVersion }
            $results.Checks += @{
                Component = "PowerShell"
                Status = $psVersion.Major -ge 5
                Details = "Version $psVersion"
            }

            # TLS Configuration
            $tlsCheck = Test-TLSConfiguration -ServerName $ServerName
            $results.Checks += @{
                Component = "TLS"
                Status = $tlsCheck.Success
                Details = $tlsCheck.Version
            }

            # Network Connectivity
            $networkChecks = @(
                @{
                    Endpoint = "management.azure.com"
                    Service = "Arc"
                    Required = $true
                },
                @{
                    Endpoint = "login.microsoftonline.com"
                    Service = "Authentication"
                    Required = $true
                },
                @{
                    Endpoint = "ods.opinsights.azure.com"
                    Service = "AMA"
                    Required = $true
                },
                @{
                    Endpoint = "oms.opinsights.azure.com"
                    Service = "LogAnalytics"
                    Required = $true
                }
            )

            foreach ($check in $networkChecks) {
                $connectivity = Test-NetConnection -ComputerName $check.Endpoint -Port 443
                $results.Checks += @{
                    Component = "Network-$($check.Service)"
                    Status = $connectivity.TcpTestSucceeded
                    Details = "Endpoint: $($check.Endpoint)"
                    Required = $check.Required
                }
            }

            # Workspace Validation (if provided)
            if ($WorkspaceId) {
                $workspaceCheck = Test-LAWorkspace -WorkspaceId $WorkspaceId
                $results.Checks += @{
                    Component = "LogAnalytics"
                    Status = $workspaceCheck.Success
                    Details = $workspaceCheck.Details
                    Required = $true
                }
            }

            # Disk Space
            $diskSpace = Get-WmiObject Win32_LogicalDisk -ComputerName $ServerName -Filter "DeviceID='C:'"
            $freeSpaceGB = [math]::Round($diskSpace.FreeSpace / 1GB, 2)
            $results.Checks += @{
                Component = "DiskSpace"
                Status = $freeSpaceGB -ge 5
                Details = "Free Space: $freeSpaceGB GB"
                Required = $true
            }

            # Overall Status
            $results.Success = ($results.Checks | 
                Where-Object { $_.Required } | 
                Where-Object { -not $_.Status }).Count -eq 0
        }
        catch {
            $results.Success = $false
            $results.Error = $_.Exception.Message
            Write-Error $_
        }
    }

    end {
        return [PSCustomObject]$results
    }
}
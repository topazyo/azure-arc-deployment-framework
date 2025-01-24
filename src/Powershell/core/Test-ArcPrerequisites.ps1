function Test-ArcPrerequisites {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [string]$Environment = 'Production'
    )

    begin {
        $ErrorActionPreference = 'Stop'
        Write-Verbose "Starting prerequisite checks for server: $ServerName"
    }

    process {
        try {
            $results = @{
                ServerName = $ServerName
                Timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                Checks = @{}
            }

            # System Checks
            $results.Checks.System = @{
                OSVersion = Get-WmiObject Win32_OperatingSystem | 
                    Select-Object -ExpandProperty Version
                PowerShellVersion = $PSVersionTable.PSVersion.ToString()
                TLSVersion = [Net.ServicePointManager]::SecurityProtocol
            }

            # Network Checks
            $results.Checks.Network = @{
                AzureConnectivity = Test-NetConnection -ComputerName "management.azure.com" -Port 443
                ProxyConfiguration = Get-ProxyConfiguration
            }

            # Security Checks
            $results.Checks.Security = @{
                TLS12Enabled = Test-TLS12Configuration
                CertificateStore = Test-CertificateStore
            }

            return $results
        }
        catch {
            Write-Error "Prerequisite check failed: $_"
            throw
        }
    }

    end {
        Write-Verbose "Completed prerequisite checks for server: $ServerName"
    }
}
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
        $useTestData = $env:ARC_PREREQ_TESTDATA -eq '1'

        try {
            # System Requirements
            $osCheck = $null
            if ($useTestData) {
                $osCheck = [pscustomobject]@{
                    Version        = '10.0.19041'
                    BuildNumber    = '19041'
                    OSArchitecture = '64-bit'
                    Caption        = 'Windows Server (Mock)'
                }
            } else {
                try {
                    $osCheck = Get-WmiObject Win32_OperatingSystem -ComputerName $ServerName -ErrorAction Stop
                } catch {
                    if ($env:ARC_PREREQ_FAILFAST -eq '1') { throw }
                    $osCheck = $null
                }
            }

            $osVersion = $null
            if ($null -ne $osCheck -and $osCheck.PSObject.Properties.Name -contains 'Version') {
                $osVersion = [string]$osCheck.Version
            }

            $osStatus = $false
            if (-not [string]::IsNullOrWhiteSpace($osVersion)) {
                $osStatus = Test-OSCompatibility -OSVersion $osVersion
            }

            $osDetails = $null
            if ($null -ne $osCheck -and $osCheck.PSObject.Properties.Name -contains 'Caption') {
                $osDetails = [string]$osCheck.Caption
            }
            if ([string]::IsNullOrWhiteSpace($osDetails)) {
                $osDetails = 'Unknown OS'
            }
            if ([string]::IsNullOrWhiteSpace($osVersion)) {
                $osDetails = "$osDetails (Version not detected)"
            }

            $results.Checks += @{
                Component = "OperatingSystem"
                Status = $osStatus
                Details = $osDetails
                Required = $true
            }

            # PowerShell Version
            $psVersion = if ($useTestData) { [version]'5.1.0' } else { Invoke-Command -ComputerName $ServerName -ScriptBlock { $PSVersionTable.PSVersion } }
            $results.Checks += @{
                Component = "PowerShell"
                Status = $psVersion.Major -ge 5
                Details = "Version $psVersion"
                Required = $true
            }

            # TLS Configuration
            $tlsCheck = Test-TLSConfiguration -ServerName $ServerName
            $results.Checks += @{
                Component = "TLS"
                Status = $tlsCheck.Success
                Details = $tlsCheck.Version
                Required = $true
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
            $diskSpace = $null
            if ($useTestData) {
                $diskSpace = [pscustomobject]@{ FreeSpace = 10GB }
            } else {
                try {
                    $diskSpace = Get-WmiObject Win32_LogicalDisk -ComputerName $ServerName -Filter "DeviceID='C:'" -ErrorAction Stop
                } catch {
                    if ($env:ARC_PREREQ_FAILFAST -eq '1') { throw }
                    $diskSpace = $null
                }
            }

            $freeSpaceBytes = $null
            if ($null -ne $diskSpace) {
                $diskObj = $diskSpace | Select-Object -First 1
                if ($null -ne $diskObj) {
                    if ($diskObj.PSObject.Properties.Name -contains 'FreeSpace') {
                        $freeSpaceBytes = $diskObj.FreeSpace
                    } elseif ($diskObj.PSObject.Properties.Name -contains 'SizeRemaining') {
                        # Some disk objects expose SizeRemaining instead of FreeSpace.
                        $freeSpaceBytes = $diskObj.SizeRemaining
                    }
                }
            }

            if ($null -eq $freeSpaceBytes) {
                $results.Checks += @{
                    Component = "DiskSpace"
                    Status = $false
                    Details = "Free space could not be determined"
                    Required = $true
                }
            } else {
                $freeSpaceGB = [math]::Round(([double]$freeSpaceBytes) / 1GB, 2)
                $results.Checks += @{
                    Component = "DiskSpace"
                    Status = $freeSpaceGB -ge 5
                    Details = "Free Space: $freeSpaceGB GB"
                    Required = $true
                }
            }

            if ($env:ARC_PREREQ_DEBUG -eq '1') {
                try {
                    $debugPath = Join-Path -Path $env:TEMP -ChildPath "arc_prereq_checks.json"
                    $debugPayload = [ordered]@{
                        Checks   = $results.Checks
                        Success = $results.Success
                        ChecksType = $results.Checks.GetType().FullName
                        OSRaw    = $osCheck
                        DiskRaw  = $diskSpace
                    }
                    $debugPayload | ConvertTo-Json -Depth 6 | Out-File -FilePath $debugPath -Encoding utf8
                } catch {
                    # Best-effort debug logging; ignore failures
                }
            }

            # Overall Status
            $failedRequired = @($results.Checks | Where-Object { $_.Required -and -not $_.Status })
            $results.Success = $failedRequired.Count -eq 0
        }
        catch {
            $results.Success = $false
            $results.Error = $_.Exception.Message
            Write-Error $_
            try { Write-Log -Level Error -Message "$($_)" } catch {}
        }
    }

    end {
        return [PSCustomObject]$results
    }
}
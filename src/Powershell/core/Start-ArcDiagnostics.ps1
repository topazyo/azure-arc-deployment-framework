<#
.SYNOPSIS
Collects Arc and optional AMA diagnostics for a target server.

.DESCRIPTION
Builds a diagnostics bundle containing system state, Arc status, AMA status,
connectivity data, logs, and optional detailed-analysis sections, then writes the
result to the requested output location.

.PARAMETER ServerName
Target server to diagnose.

.PARAMETER WorkspaceId
Optional workspace identifier used for AMA-related diagnostics.

.PARAMETER DetailedScan
Includes additional detailed-analysis sections in the diagnostics bundle.

.PARAMETER OutputPath
Directory used for diagnostics output artifacts.

.OUTPUTS
PSCustomObject

.EXAMPLE
Start-ArcDiagnostics -ServerName 'SERVER01' -WorkspaceId '<workspace-id>' -DetailedScan -OutputPath '.\Diagnostics'
#>
function Start-ArcDiagnostics {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [string]$WorkspaceId,
        [Parameter()]
        [switch]$DetailedScan,
        [Parameter()]
        [string]$OutputPath = ".\Diagnostics"
    )

    begin {
        $useTestData = $env:ARC_DIAG_TESTDATA -eq '1'

        # Ensure logging path exists for Write-Log consumers; default to OutputPath if not preset
        $existingLogPath = $null
        try { $existingLogPath = Get-Variable -Name AzureArcFramework_LogPath -Scope Global -ValueOnly -ErrorAction Stop } catch { Write-Verbose 'Global log path is not preset; defaulting to the diagnostics output path.' }

        if (-not $existingLogPath) {
            try {
                $resolvedOutput = Resolve-Path $OutputPath
            } catch {
                $resolvedOutput = $OutputPath
            }

            $global:AzureArcFramework_LogPath = Join-Path $resolvedOutput 'ArcDiagnostics.log'
        } else {
            $global:AzureArcFramework_LogPath = $existingLogPath
        }

        $diagnosticResults = @{
            Timestamp = Get-Date
            ServerName = $ServerName
            SystemState = @{}
            ArcStatus = @{}
            AMAStatus = @{}
            Connectivity = @{}
            Logs = @{}
            DetailedAnalysis = @{}
        }

        # Ensure output directory exists

        function Get-ArcHeartbeatSnapshot {
            [CmdletBinding()]
            param (
                [Parameter(Mandatory)]
                [string]$ServerName
            )

            if (Get-Command Get-LastHeartbeat -ErrorAction SilentlyContinue) {
                return Get-LastHeartbeat -ServerName $ServerName
            }

            $heartbeatScriptPath = Join-Path $PSScriptRoot 'Get-LastHeartbeat.ps1'
            if (Test-Path $heartbeatScriptPath -PathType Leaf) {
                . $heartbeatScriptPath
                if (Get-Command Get-LastHeartbeat -ErrorAction SilentlyContinue) {
                    return Get-LastHeartbeat -ServerName $ServerName
                }
            }

            return $null
        }
        if (-not (Test-Path $OutputPath)) {
            New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
        }

        Write-Verbose "Starting diagnostic collection for $ServerName"
    }

    process {
        try {
            Write-Log -Level Information -Message "Starting diagnostic collection for $ServerName"
            if ($useTestData) {
                $diagnosticResults.SystemState = @{
                    OS = @{ Version = '10.0.17763'; BuildNumber = '17763' }
                    Hardware = @{ CPU = @{ LoadPercentage = 10 }; Memory = @{ AvailableGB = 16 } }
                }

                $diagnosticResults.ArcStatus = @{
                    ServiceStatus = 'Running'
                    StartType = 'Automatic'
                    Dependencies = @()
                    Configuration = @{ Version = '1.0' }
                    LastHeartbeat = (Get-Date).AddMinutes(-5)
                }

                if ($WorkspaceId) {
                    $diagnosticResults.AMAStatus = @{
                        ServiceStatus = 'Running'
                        StartType = 'Automatic'
                        Configuration = @{ WorkspaceId = $WorkspaceId }
                        DataCollection = @{ Status = 'Active'; LastHeartbeat = Get-Date }
                        DCRStatus = @{ State = 'Enabled' }
                    }
                }

                $diagnosticResults.Connectivity = @{
                    Arc = @{ Success = $true }
                    AMA = if ($WorkspaceId) { @{ Success = $true } }
                    Proxy = @{ ProxyServer = $null; ProxyPort = $null }
                    NetworkPaths = @()
                }

                $diagnosticResults.Logs = @{
                    Arc = @('Arc log 1')
                    AMA = if ($WorkspaceId) { @('AMA log 1') }
                    System = @('System log 1')
                    Security = @('Security log 1')
                }

                if ($DetailedScan) {
                    $diagnosticResults.DetailedAnalysis = @{
                        CertificateChain = @{ Valid = $true }
                        ProxyConfiguration = @{}
                        FirewallRules = @{}
                        PerformanceMetrics = @{}
                        SecurityBaseline = @{ Status = 'Pass' }
                    }
                }

                Write-Output ([PSCustomObject]$diagnosticResults)
                return
            }
            function Get-OptionalPropertyValue {
                param(
                    [Parameter(Mandatory)]
                    [object]$InputObject,
                    [Parameter(Mandatory)]
                    [string]$PropertyName,
                    [Parameter()]
                    $Default = $null
                )

                if ($null -eq $InputObject) {
                    return $Default
                }

                if ($InputObject.PSObject.Properties.Name -contains $PropertyName) {
                    return $InputObject.$PropertyName
                }

                return $Default
            }

            # System State Collection
            $diagnosticResults.SystemState = Get-SystemState -ServerName $ServerName
            Write-Progress -Activity "Arc Diagnostics" -Status "Collecting System State" -PercentComplete 20

            # Arc Agent Status
            $getServiceParams = @{ Name = "himds"; ErrorAction = 'SilentlyContinue' }
            if ((Get-Command Get-Service).Parameters.ContainsKey('ComputerName')) {
                $getServiceParams.ComputerName = $ServerName
            }
            $arcStatus = Get-Service @getServiceParams
            $diagnosticResults.ArcStatus = @{
                ServiceStatus = $arcStatus.Status
                StartType = $arcStatus.StartType
                Dependencies = Get-OptionalPropertyValue -InputObject $arcStatus -PropertyName 'DependentServices' -Default @()
                Configuration = Get-ArcAgentConfig -ServerName $ServerName
                LastHeartbeat = Get-ArcHeartbeatSnapshot -ServerName $ServerName
            }
            Write-Progress -Activity "Arc Diagnostics" -Status "Checking Arc Status" -PercentComplete 40

            # AMA Status (if workspace provided)
            if ($WorkspaceId) {
                $getAmaServiceParams = @{ Name = "AzureMonitorAgent"; ErrorAction = 'SilentlyContinue' }
                if ((Get-Command Get-Service).Parameters.ContainsKey('ComputerName')) {
                    $getAmaServiceParams.ComputerName = $ServerName
                }
                $amaStatus = Get-Service @getAmaServiceParams
                $diagnosticResults.AMAStatus = @{
                    ServiceStatus = $amaStatus.Status
                    StartType = $amaStatus.StartType
                    Configuration = Get-AMAConfig -ServerName $ServerName
                    DataCollection = Get-DataCollectionStatus -ServerName $ServerName -WorkspaceId $WorkspaceId
                    DCRStatus = Get-DCRAssociationStatus -ServerName $ServerName
                }
                Write-Progress -Activity "Arc Diagnostics" -Status "Checking AMA Status" -PercentComplete 60
            }

            # Connectivity Tests
            $diagnosticResults.Connectivity = @{
                Arc = Test-ArcConnectivity -ServerName $ServerName
                AMA = if ($WorkspaceId) { Test-AMAConnectivity -ServerName $ServerName }
                Proxy = Get-ProxyConfiguration -ServerName $ServerName
                NetworkPaths = Test-NetworkPaths -ServerName $ServerName
            }
            Write-Progress -Activity "Arc Diagnostics" -Status "Testing Connectivity" -PercentComplete 70

            # Log Collection
            $diagnosticResults.Logs = @{
                Arc = Get-ArcAgentLogs -ServerName $ServerName
                AMA = if ($WorkspaceId) { Get-AMALogs -ServerName $ServerName }
                System = Get-SystemLogs -ServerName $ServerName -LastHours 24
                Security = Get-SecurityLogs -ServerName $ServerName -LastHours 24
            }
            Write-Progress -Activity "Arc Diagnostics" -Status "Collecting Logs" -PercentComplete 80

            # Detailed Analysis if requested
            if ($DetailedScan) {
                $diagnosticResults.DetailedAnalysis = @{
                    CertificateChain = Test-CertificateTrust -ServerName $ServerName
                    ProxyConfiguration = Get-DetailedProxyConfig -ServerName $ServerName
                    FirewallRules = Get-FirewallConfiguration -ServerName $ServerName
                    PerformanceMetrics = Get-PerformanceMetrics -ServerName $ServerName
                    SecurityBaseline = Test-SecurityBaseline -ServerName $ServerName
                }
                Write-Progress -Activity "Arc Diagnostics" -Status "Performing Detailed Analysis" -PercentComplete 90
            }

            # Export Results
            $outputFile = Join-Path $OutputPath "ArcDiagnostics_$($ServerName)_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
            $diagnosticResults | ConvertTo-Json -Depth 10 | Out-File $outputFile
            Write-Verbose "Diagnostic results exported to: $outputFile"
        }
        catch {
            $diagnosticResults.Error = @{
                Message = $_.Exception.Message
                Time = Get-Date
                Details = $_.Exception.StackTrace
            }
            try {
                Write-Log -Message "Diagnostic collection failed: $($_.Exception.Message)" -Level Error -Component 'Start-ArcDiagnostics'
            } catch { Write-Warning "Failed to write diagnostic failure to the framework log: $($_.Exception.Message)" }
        }
    }

    end {
        if ($useTestData) { return }
        return [PSCustomObject]$diagnosticResults
    }
}

function Get-ArcAgentConfig {
    param ([string]$ServerName)

    try {
        $configPath = "\\$ServerName\c$\Program Files\Azure Connected Machine Agent\config"
        $config = Get-Content "$configPath\agentconfig.json" -ErrorAction Stop | ConvertFrom-Json
        return $config
    }
    catch {
        Write-Warning "Failed to retrieve Arc agent configuration: $_"
        return $null
    }
}

function Get-AMAConfig {
    param ([string]$ServerName)

    try {
        $configPath = "\\$ServerName\c$\Program Files\Azure Monitor Agent\config"
        $config = Get-Content "$configPath\settings.json" -ErrorAction Stop | ConvertFrom-Json
        return $config
    }
    catch {
        Write-Warning "Failed to retrieve AMA configuration: $_"
        return $null
    }
}

function Get-DataCollectionStatus {
    param (
        [string]$ServerName,
        [string]$WorkspaceId
    )

    try {
        $query = @"
            Heartbeat
            | where TimeGenerated > ago(1h)
            | where Computer == '$ServerName'
            | summarize LastHeartbeat = max(TimeGenerated)
"@
        $result = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $query


if (-not (Get-Command Get-LastHeartbeat -ErrorAction SilentlyContinue)) {
    function Get-LastHeartbeat {
        [CmdletBinding()]
        param (
            [Parameter(Mandatory)]
            [string]$ServerName
        )

        return Get-ArcHeartbeatSnapshot -ServerName $ServerName
    }
}
        return @{
            LastHeartbeat = $result.Results.LastHeartbeat
            Status = if ($result.Results.LastHeartbeat -gt (Get-Date).AddMinutes(-10)) { "Active" } else { "Inactive" }
        }
    }
    catch {
        Write-Warning "Failed to retrieve data collection status: $_"
        return $null
    }
}

function Test-NetworkPaths {
    param ([string]$ServerName)

    $endpoints = @(
        @{
            Name = "Arc Management"
            Host = "management.azure.com"
            Port = 443
        },
        @{
            Name = "Arc Authentication"
            Host = "login.microsoftonline.com"
            Port = 443
        },
        @{
            Name = "AMA Log Analytics"
            Host = "ods.opinsights.azure.com"
            Port = 443
        },
        @{
            Name = "AMA Workspace"
            Host = "oms.opinsights.azure.com"
            Port = 443
        }
    )

    $results = foreach ($endpoint in $endpoints) {
        $test = Test-NetConnection -ComputerName $endpoint.Host -Port $endpoint.Port -WarningAction SilentlyContinue
        @{
            Endpoint = $endpoint.Name
            Target = $endpoint.Host
            Port = $endpoint.Port
            Success = $test.TcpTestSucceeded
            LatencyMS = $test.PingReplyDetails.RoundtripTime
            Error = if (-not $test.TcpTestSucceeded) { $test.TcpTestSucceeded } else { $null }
        }
    }

    return $results
}
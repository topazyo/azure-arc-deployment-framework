function Get-AMAConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [switch]$Detailed,
        [Parameter()]
        [switch]$IncludeSecrets
    )

    begin {
        $configResult = @{
            ServerName = $ServerName
            Timestamp = Get-Date
            ConfigFound = $false
            ConfigDetails = @{}
            WorkspaceId = $null
            DCRs = @()
        }

        Write-Verbose "Retrieving AMA configuration for $ServerName"
        Write-Log -Message "Retrieving AMA configuration for $ServerName" -Level Information
    }

    process {
        try {
            # Check if AMA service exists
            $service = Get-Service -Name "AzureMonitorAgent" -ComputerName $ServerName -ErrorAction SilentlyContinue
            if (-not $service) {
                Write-Verbose "AMA service not found on $ServerName"
                Write-Log -Message "AMA service not found on $ServerName" -Level Warning
                $configResult.Error = "AMA service not installed"
                return $configResult
            }

            $configResult.ServiceStatus = $service.Status
            $configResult.ServiceStartType = $service.StartType

            # Get AMA configuration files
            $configFiles = Invoke-Command -ComputerName $ServerName -ScriptBlock {
                $configPath = "C:\Program Files\Azure Monitor Agent\config"
                if (Test-Path $configPath) {
                    $files = @{
                        SettingsJson = if (Test-Path "$configPath\settings.json") { 
                            Get-Content "$configPath\settings.json" -Raw | ConvertFrom-Json 
                        } else { $null }
                        
                        AgentJson = if (Test-Path "$configPath\agent.json") { 
                            Get-Content "$configPath\agent.json" -Raw | ConvertFrom-Json 
                        } else { $null }
                        
                        ConfigJson = if (Test-Path "$configPath\config.json") { 
                            Get-Content "$configPath\config.json" -Raw | ConvertFrom-Json 
                        } else { $null }
                        
                        MonitoringConfigJson = if (Test-Path "$configPath\monitoring_config.json") { 
                            Get-Content "$configPath\monitoring_config.json" -Raw | ConvertFrom-Json 
                        } else { $null }
                    }
                    return $files
                }
                return $null
            }

            if (-not $configFiles) {
                Write-Verbose "AMA configuration files not found on $ServerName"
                Write-Log -Message "AMA configuration files not found on $ServerName" -Level Warning
                $configResult.Error = "Configuration files not found"
                return $configResult
            }

            $configResult.ConfigFound = $true
            
            # Extract workspace information
            if ($configFiles.SettingsJson) {
                $configResult.ConfigDetails.Settings = $configFiles.SettingsJson
                
                # Extract workspace ID
                if ($configFiles.SettingsJson.workspaceId) {
                    $configResult.WorkspaceId = $configFiles.SettingsJson.workspaceId
                }
                
                # Remove secrets if not requested
                if (-not $IncludeSecrets -and $configFiles.SettingsJson.PSObject.Properties.Name -contains "workspaceKey") {
                    $configResult.ConfigDetails.Settings.workspaceKey = "***REDACTED***"
                }
            }
            
            # Extract agent configuration
            if ($configFiles.AgentJson) {
                $configResult.ConfigDetails.Agent = $configFiles.AgentJson
            }
            
            # Extract monitoring configuration
            if ($configFiles.MonitoringConfigJson) {
                $configResult.ConfigDetails.MonitoringConfig = $configFiles.MonitoringConfigJson
                
                # Extract DCR information
                if ($configFiles.MonitoringConfigJson.dataCollectionRules) {
                    foreach ($dcr in $configFiles.MonitoringConfigJson.dataCollectionRules) {
                        $configResult.DCRs += @{
                            Id = $dcr.id
                            Name = $dcr.name
                            Streams = $dcr.streams
                            DataSources = $dcr.dataSources
                        }
                    }
                }
            }
            
            # Get additional details if requested
            if ($Detailed) {
                # Get registry configuration
                $registryConfig = Invoke-Command -ComputerName $ServerName -ScriptBlock {
                    $regPath = "HKLM:\SYSTEM\CurrentControlSet\Services\AzureMonitorAgent"
                    if (Test-Path $regPath) {
                        $regValues = Get-ItemProperty -Path $regPath
                        return $regValues
                    }
                    return $null
                }
                
                if ($registryConfig) {
                    $configResult.ConfigDetails.Registry = @{
                        DisplayName = $registryConfig.DisplayName
                        ImagePath = $registryConfig.ImagePath
                        Start = $registryConfig.Start
                        Type = $registryConfig.Type
                    }
                }
                
                # Get installed version
                $versionInfo = Invoke-Command -ComputerName $ServerName -ScriptBlock {
                    $amaPath = "C:\Program Files\Azure Monitor Agent\Agent\AzureMonitorAgent.exe"
                    if (Test-Path $amaPath) {
                        $fileVersion = (Get-Item $amaPath).VersionInfo.FileVersion
                        $productVersion = (Get-Item $amaPath).VersionInfo.ProductVersion
                        return @{
                            FileVersion = $fileVersion
                            ProductVersion = $productVersion
                        }
                    }
                    return $null
                }
                
                if ($versionInfo) {
                    $configResult.Version = $versionInfo.ProductVersion
                    $configResult.FileVersion = $versionInfo.FileVersion
                }
                
                # Get DCR associations from Azure
                try {
                    $arcServer = Get-AzConnectedMachine -Name $ServerName -ErrorAction SilentlyContinue
                    if ($arcServer) {
                        $dcrAssociations = Get-AzDataCollectionRuleAssociation -TargetResourceId $arcServer.Id
                        $configResult.AzureDCRAssociations = $dcrAssociations | ForEach-Object {
                            @{
                                Name = $_.Name
                                RuleId = $_.DataCollectionRuleId
                            }
                        }
                    }
                }
                catch {
                    Write-Verbose "Could not retrieve DCR associations from Azure: $_"
                    Write-Log -Message "Could not retrieve DCR associations from Azure: $_" -Level Warning
                }
                
                # Get log collection status
                $logCollectionStatus = Get-AMALogCollectionStatus -ServerName $ServerName
                if ($logCollectionStatus) {
                    $configResult.LogCollection = $logCollectionStatus
                }
            }
        }
        catch {
            $configResult.Error = $_.Exception.Message
            Write-Error "Failed to retrieve AMA configuration: $_"
            Write-Log -Message "Failed to retrieve AMA configuration: $_" -Level Error
        }
    }

    end {
        return [PSCustomObject]$configResult
    }
}

function Get-AMALogCollectionStatus {
    [CmdletBinding()]
    param ([string]$ServerName)
    
    try {
        $logStatus = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            # Check log directories
            $logPath = "C:\Program Files\Azure Monitor Agent\Logs"
            $logFiles = if (Test-Path $logPath) { Get-ChildItem $logPath -Recurse -File } else { @() }
            
            # Check event logs
            $amaEvents = Get-WinEvent -LogName "Microsoft-Azure-Monitor-Agent/Operational" -MaxEvents 100 -ErrorAction SilentlyContinue
            $errorEvents = $amaEvents | Where-Object { $_.LevelDisplayName -eq "Error" }
            $warningEvents = $amaEvents | Where-Object { $_.LevelDisplayName -eq "Warning" }
            
            # Check buffer files
            $bufferPath = "C:\Program Files\Azure Monitor Agent\Agent\Buffer"
            $bufferFiles = if (Test-Path $bufferPath) { Get-ChildItem $bufferPath -Recurse -File } else { @() }
            $bufferSize = ($bufferFiles | Measure-Object -Property Length -Sum).Sum
            
            return @{
                LogCount = $logFiles.Count
                LogSize = ($logFiles | Measure-Object -Property Length -Sum).Sum
                RecentErrorCount = $errorEvents.Count
                RecentWarningCount = $warningEvents.Count
                BufferFileCount = $bufferFiles.Count
                BufferSize = $bufferSize
                RecentErrors = $errorEvents | Select-Object -First 5 | ForEach-Object {
                    @{
                        TimeCreated = $_.TimeCreated
                        Message = $_.Message
                        Id = $_.Id
                    }
                }
            }
        }
        
        return $logStatus
    }
    catch {
        Write-Verbose "Failed to retrieve log collection status: $_"
        return $null
    }
}
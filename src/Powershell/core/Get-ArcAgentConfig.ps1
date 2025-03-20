function Get-ArcAgentConfig {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [ValidateSet('Basic', 'Detailed', 'Full')]
        [string]$DetailLevel = 'Basic',
        [Parameter()]
        [switch]$IncludeSecrets,
        [Parameter()]
        [switch]$AsObject
    )

    begin {
        $configResult = @{
            ServerName = $ServerName
            Timestamp = Get-Date
            ConfigFound = $false
            ConfigFiles = @{}
            ParsedConfig = @{}
            ServiceConfig = @{}
            Error = $null
        }

        # Define config file paths
        $configPaths = @{
            AgentConfig = "\\$ServerName\c$\Program Files\Azure Connected Machine Agent\config\agentconfig.json"
            GuestConfig = "\\$ServerName\c$\Program Files\Azure Connected Machine Agent\config\gc_agent_config.json"
            ExtensionConfig = "\\$ServerName\c$\Program Files\Azure Connected Machine Agent\config\extensionconfig.json"
            IdentityConfig = "\\$ServerName\c$\Program Files\Azure Connected Machine Agent\config\identityconfig.json"
            StateConfig = "\\$ServerName\c$\Program Files\Azure Connected Machine Agent\config\state"
        }

        Write-Verbose "Retrieving Arc agent configuration from $ServerName"
    }

    process {
        try {
            # Check if server is reachable
            if (-not (Test-Connection -ComputerName $ServerName -Count 1 -Quiet)) {
                throw "Server $ServerName is not reachable"
            }

            # Check if Arc agent is installed
            $agentPath = "\\$ServerName\c$\Program Files\Azure Connected Machine Agent"
            if (-not (Test-Path $agentPath)) {
                throw "Azure Connected Machine Agent is not installed on $ServerName"
            }

            # Get service configuration
            $himdsService = Get-Service -Name "himds" -ComputerName $ServerName -ErrorAction SilentlyContinue
            $gcadService = Get-Service -Name "gcad" -ComputerName $ServerName -ErrorAction SilentlyContinue

            $configResult.ServiceConfig = @{
                HIMDSService = if ($himdsService) {
                    @{
                        Status = $himdsService.Status
                        StartType = $himdsService.StartType
                        DisplayName = $himdsService.DisplayName
                    }
                } else { $null }
                GCADService = if ($gcadService) {
                    @{
                        Status = $gcadService.Status
                        StartType = $gcadService.StartType
                        DisplayName = $gcadService.DisplayName
                    }
                } else { $null }
            }

            # Read configuration files
            foreach ($configFile in $configPaths.GetEnumerator()) {
                if (Test-Path $configFile.Value) {
                    try {
                        $content = Get-Content -Path $configFile.Value -Raw -ErrorAction Stop
                        $configResult.ConfigFiles[$configFile.Key] = $content
                        $configResult.ConfigFound = $true
                    }
                    catch {
                        $configResult.ConfigFiles[$configFile.Key] = "Error reading file: $_"
                    }
                }
                else {
                    $configResult.ConfigFiles[$configFile.Key] = "File not found"
                }
            }

            # Parse JSON configuration files
            foreach ($configFile in $configResult.ConfigFiles.GetEnumerator()) {
                if ($configFile.Value -notmatch "Error|not found") {
                    try {
                        $parsedConfig = $configFile.Value | ConvertFrom-Json -ErrorAction Stop
                        
                        # Remove secrets if not requested
                        if (-not $IncludeSecrets -and $configFile.Key -eq 'AgentConfig') {
                            if ($parsedConfig.PSObject.Properties.Name -contains 'authentication') {
                                $parsedConfig.authentication.PSObject.Properties | 
                                    Where-Object { $_.Name -match 'key|secret|password|credential' } | 
                                    ForEach-Object { $_.Value = '*** REDACTED ***' }
                            }
                        }
                        
                        $configResult.ParsedConfig[$configFile.Key] = $parsedConfig
                    }
                    catch {
                        $configResult.ParsedConfig[$configFile.Key] = "Error parsing JSON: $_"
                    }
                }
            }

            # Get additional details based on detail level
            if ($DetailLevel -in 'Detailed', 'Full') {
                # Get installed extensions
                $extensionsPath = "\\$ServerName\c$\Program Files\Azure Connected Machine Agent\Extensions"
                if (Test-Path $extensionsPath) {
                    $extensions = Get-ChildItem -Path $extensionsPath -Directory | ForEach-Object {
                        $extensionConfig = Join-Path $_.FullName "config\*.settings"
                        $configFiles = Get-ChildItem -Path $extensionConfig -ErrorAction SilentlyContinue
                        
                        @{
                            Name = $_.Name
                            Path = $_.FullName
                            ConfigFiles = $configFiles | ForEach-Object { $_.Name }
                            Status = if (Test-Path (Join-Path $_.FullName "status")) { "Installed" } else { "Unknown" }
                        }
                    }
                    $configResult.Extensions = $extensions
                }

                # Get logs summary
                $logsPath = "\\$ServerName\c$\Program Files\Azure Connected Machine Agent\logs"
                if (Test-Path $logsPath) {
                    $logs = Get-ChildItem -Path $logsPath -File | ForEach-Object {
                        @{
                            Name = $_.Name
                            Size = $_.Length
                            LastWriteTime = $_.LastWriteTime
                        }
                    }
                    $configResult.Logs = $logs
                }
            }

            # Get full system details for 'Full' detail level
            if ($DetailLevel -eq 'Full') {
                # Get registry configuration
                $registryConfig = Invoke-Command -ComputerName $ServerName -ScriptBlock {
                    $arcRegPath = "HKLM:\SOFTWARE\Microsoft\Azure Connected Machine Agent"
                    if (Test-Path $arcRegPath) {
                        Get-ItemProperty -Path $arcRegPath
                    }
                }
                $configResult.RegistryConfig = $registryConfig

                # Get environment variables
                $envVars = Invoke-Command -ComputerName $ServerName -ScriptBlock {
                    Get-ChildItem Env: | Where-Object { $_.Name -like "*AZURE*" -or $_.Name -like "*ARC*" }
                }
                $configResult.EnvironmentVariables = $envVars

                # Get network configuration
                $networkConfig = Get-NetworkConfiguration -ServerName $ServerName
                $configResult.NetworkConfig = $networkConfig
            }

            # Extract key information for easier access
            if ($configResult.ParsedConfig.ContainsKey('AgentConfig')) {
                $agentConfig = $configResult.ParsedConfig.AgentConfig
                $configResult.KeyInfo = @{
                    ResourceId = $agentConfig.resourceId
                    TenantId = $agentConfig.tenantId
                    Location = $agentConfig.location
                    SubscriptionId = if ($agentConfig.resourceId) {
                        $agentConfig.resourceId.Split('/')[2]
                    } else { $null }
                    ResourceGroup = if ($agentConfig.resourceId) {
                        $agentConfig.resourceId.Split('/')[4]
                    } else { $null }
                    MachineName = $agentConfig.machineName
                    Tags = $agentConfig.tags
                    LastHeartbeat = if (Test-Path "\\$ServerName\c$\Program Files\Azure Connected Machine Agent\config\state\heartbeat") {
                        (Get-Item "\\$ServerName\c$\Program Files\Azure Connected Machine Agent\config\state\heartbeat").LastWriteTime
                    } else { $null }
                }
            }
        }
        catch {
            $configResult.Error = $_.Exception.Message
            Write-Error "Failed to retrieve Arc agent configuration: $_"
        }
    }

    end {
        # Return as PSObject if requested
        if ($AsObject -and $configResult.ConfigFound) {
            return [PSCustomObject]$configResult.ParsedConfig.AgentConfig
        }
        
        return [PSCustomObject]$configResult
    }
}

function Get-NetworkConfiguration {
    [CmdletBinding()]
    param ([string]$ServerName)
    
    try {
        $networkConfig = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            @{
                ProxySettings = @{
                    WinHTTP = netsh winhttp show proxy
                    WinINet = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
                    Environment = [System.Environment]::GetEnvironmentVariable('HTTP_PROXY')
                }
                IPConfiguration = Get-NetIPConfiguration | Select-Object InterfaceAlias, IPv4Address, IPv4DefaultGateway, DNSServer
                Connectivity = @{
                    AzureManagement = Test-NetConnection -ComputerName management.azure.com -Port 443 -WarningAction SilentlyContinue
                    AzureIdentity = Test-NetConnection -ComputerName login.microsoftonline.com -Port 443 -WarningAction SilentlyContinue
                }
                FirewallRules = Get-NetFirewallRule | Where-Object { 
                    $_.DisplayName -like "*Azure*" -or 
                    $_.DisplayName -like "*Arc*" 
                } | Select-Object DisplayName, Enabled, Direction, Action
            }
        }
        
        return $networkConfig
    }
    catch {
        Write-Error "Failed to get network configuration: $_"
        return $null
    }
}
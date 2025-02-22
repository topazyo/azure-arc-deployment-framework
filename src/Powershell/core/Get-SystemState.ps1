function Get-SystemState {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [switch]$IncludeAMA,
        [Parameter()]
        [switch]$DetailedScan
    )

    begin {
        $systemState = @{
            ServerName = $ServerName
            Timestamp = Get-Date
            OS = @{}
            Hardware = @{}
            Network = @{}
            Security = @{}
            Agents = @{
                Arc = @{}
                AMA = @{}
            }
            Performance = @{}
        }
    }

    process {
        try {
            # OS Information
            $os = Get-WmiObject Win32_OperatingSystem -ComputerName $ServerName
            $systemState.OS = @{
                Version = $os.Version
                BuildNumber = $os.BuildNumber
                ServicePack = $os.ServicePackMajorVersion
                LastBoot = $os.ConvertToDateTime($os.LastBootUpTime)
                Architecture = $os.OSArchitecture
                InstallDate = $os.ConvertToDateTime($os.InstallDate)
            }

            # Hardware Resources
            $cpu = Get-WmiObject Win32_Processor -ComputerName $ServerName
            $memory = Get-WmiObject Win32_ComputerSystem -ComputerName $ServerName
            $disk = Get-WmiObject Win32_LogicalDisk -ComputerName $ServerName -Filter "DeviceID='C:'"
            
            $systemState.Hardware = @{
                CPU = @{
                    Name = $cpu.Name
                    NumberOfCores = $cpu.NumberOfCores
                    LoadPercentage = $cpu.LoadPercentage
                }
                Memory = @{
                    TotalGB = [math]::Round($memory.TotalPhysicalMemory / 1GB, 2)
                    FreeGB = [math]::Round(($os.FreePhysicalMemory / 1MB), 2)
                }
                Disk = @{
                    TotalGB = [math]::Round($disk.Size / 1GB, 2)
                    FreeGB = [math]::Round($disk.FreeSpace / 1GB, 2)
                    PercentFree = [math]::Round(($disk.FreeSpace / $disk.Size) * 100, 2)
                }
            }

            # Network Configuration
            $network = Get-WmiObject Win32_NetworkAdapterConfiguration -ComputerName $ServerName | 
                Where-Object { $_.IPEnabled }
            $systemState.Network = @{
                Adapters = $network | ForEach-Object {
                    @{
                        Name = $_.Description
                        IPAddress = $_.IPAddress
                        SubnetMask = $_.IPSubnet
                        DefaultGateway = $_.DefaultIPGateway
                        DNSServers = $_.DNSServerSearchOrder
                    }
                }
                Proxy = Get-ProxyConfiguration -ServerName $ServerName
                Connectivity = Test-NetworkConnectivity -ServerName $ServerName
            }

            # Security Settings
            $systemState.Security = @{
                TLS = Get-TLSConfiguration -ServerName $ServerName
                Firewall = Get-FirewallStatus -ServerName $ServerName
                Certificates = Get-CertificateStatus -ServerName $ServerName
                WindowsUpdate = Get-WindowsUpdateStatus -ServerName $ServerName
            }

            # Arc Agent State
            $arcService = Get-Service -Name "himds" -ComputerName $ServerName -ErrorAction SilentlyContinue
            $systemState.Agents.Arc = @{
                Installed = $null -ne $arcService
                Status = $arcService.Status
                StartType = $arcService.StartType
                Configuration = Get-ArcAgentConfig -ServerName $ServerName
                Version = Get-ArcAgentVersion -ServerName $ServerName
                LastConnected = Get-ArcLastConnected -ServerName $ServerName
            }

            # AMA State (if requested)
            if ($IncludeAMA) {
                $amaService = Get-Service -Name "AzureMonitorAgent" -ComputerName $ServerName -ErrorAction SilentlyContinue
                $systemState.Agents.AMA = @{
                    Installed = $null -ne $amaService
                    Status = $amaService.Status
                    StartType = $amaService.StartType
                    Configuration = Get-AMAAgentConfig -ServerName $ServerName
                    Version = Get-AMAVersion -ServerName $ServerName
                    DataCollection = Get-AMADataCollectionStatus -ServerName $ServerName
                    DCRStatus = Get-DCRAssociationStatus -ServerName $ServerName
                }
            }

            # Performance Metrics
            $systemState.Performance = @{
                CPU = Get-CPUMetrics -ServerName $ServerName
                Memory = Get-MemoryMetrics -ServerName $ServerName
                Disk = Get-DiskMetrics -ServerName $ServerName
                Network = Get-NetworkMetrics -ServerName $ServerName
            }

            # Detailed Scan if requested
            if ($DetailedScan) {
                $systemState.DetailedInfo = @{
                    InstalledSoftware = Get-InstalledSoftware -ServerName $ServerName
                    Services = Get-ServiceDependencies -ServerName $ServerName
                    ScheduledTasks = Get-RelevantScheduledTasks -ServerName $ServerName
                    EventLogs = Get-RelevantEventLogs -ServerName $ServerName
                }
            }
        }
        catch {
            Write-Error "Failed to collect system state: $_"
            $systemState.Error = @{
                Message = $_.Exception.Message
                Time = Get-Date
                Details = $_.Exception.StackTrace
            }
        }
    }

    end {
        return [PSCustomObject]$systemState
    }
}

function Get-TLSConfiguration {
    param ([string]$ServerName)
    
    try {
        $result = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            $protocols = @()
            $regPath = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols"
            if (Test-Path $regPath) {
                Get-ChildItem $regPath | ForEach-Object {
                    $protocolName = $_.PSChildName
                    $enabled = Get-ItemProperty -Path "$($_.PSPath)\Client" -Name "Enabled" -ErrorAction SilentlyContinue
                    if ($enabled) {
                        $protocols += @{
                            Protocol = $protocolName
                            Enabled = $enabled.Enabled -eq 1
                        }
                    }
                }
            }
            return $protocols
        }
        return $result
    }
    catch {
        Write-Warning "Failed to get TLS configuration: $_"
        return $null
    }
}

function Get-FirewallStatus {
    param ([string]$ServerName)
    
    try {
        $firewallStatus = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            $fw = New-Object -ComObject HNetCfg.FwPolicy2
            @{
                DomainProfile = $fw.FirewallEnabled($fw.CurrentProfileTypes -band 1)
                PrivateProfile = $fw.FirewallEnabled($fw.CurrentProfileTypes -band 2)
                PublicProfile = $fw.FirewallEnabled($fw.CurrentProfileTypes -band 4)
                Rules = Get-NetFirewallRule | Where-Object { 
                    $_.DisplayName -like "*Azure*" -or 
                    $_.DisplayName -like "*Arc*" -or 
                    $_.DisplayName -like "*Monitor*" 
                }
            }
        }
        return $firewallStatus
    }
    catch {
        Write-Warning "Failed to get firewall status: $_"
        return $null
    }
}

function Get-CertificateStatus {
    param ([string]$ServerName)
    
    try {
        $certStatus = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            Get-ChildItem Cert:\LocalMachine\My | Where-Object {
                $_.Subject -like "*Azure*" -or 
                $_.Subject -like "*Arc*" -or 
                $_.Subject -like "*Monitor*"
            } | ForEach-Object {
                @{
                    Subject = $_.Subject
                    Thumbprint = $_.Thumbprint
                    NotAfter = $_.NotAfter
                    NotBefore = $_.NotBefore
                    IsValid = $_.NotAfter -gt (Get-Date) -and $_.NotBefore -lt (Get-Date)
                }
            }
        }
        return $certStatus
    }
    catch {
        Write-Warning "Failed to get certificate status: $_"
        return $null
    }
}

function Get-WindowsUpdateStatus {
    param ([string]$ServerName)
    
    try {
        $updateStatus = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            $session = New-Object -ComObject Microsoft.Update.Session
            $searcher = $session.CreateUpdateSearcher()
            $pendingCount = $searcher.GetTotalHistoryCount()
            $history = $searcher.QueryHistory(0, $pendingCount)
            
            @{
                LastUpdateCheck = $searcher.GetTotalHistoryCount() -gt 0 ? $history[0].Date : $null
                PendingUpdates = @(Get-WmiObject -Class Win32_QuickFixEngineering).Count
                LastInstalledUpdate = $history | Where-Object { $_.Operation -eq 1 } | 
                    Select-Object -First 1 | ForEach-Object { $_.Date }
            }
        }
        return $updateStatus
    }
    catch {
        Write-Warning "Failed to get Windows Update status: $_"
        return $null
    }
}
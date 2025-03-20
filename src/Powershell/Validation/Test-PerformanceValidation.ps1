function Test-PerformanceValidation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [hashtable]$Thresholds,
        [Parameter()]
        [int]$SampleCount = 5,
        [Parameter()]
        [int]$SampleIntervalSeconds = 10,
        [Parameter()]
        [switch]$DetailedOutput
    )

    begin {
        $validationResults = @{
            ServerName = $ServerName
            StartTime = Get-Date
            Status = "Unknown"
            Checks = @()
            Metrics = @{}
            Recommendations = @()
        }

        # Default thresholds if not provided
        if (-not $Thresholds) {
            $Thresholds = @{
                CPU = @{
                    Warning = 80
                    Critical = 90
                }
                Memory = @{
                    AvailableMBWarning = 1024  # 1GB
                    AvailableMBCritical = 512  # 512MB
                }
                Disk = @{
                    FreePercentWarning = 15
                    FreePercentCritical = 10
                }
                Network = @{
                    LatencyMSWarning = 100
                    LatencyMSCritical = 200
                }
                SystemResponsiveness = @{
                    ProcessorQueueWarning = 5
                    ProcessorQueueCritical = 10
                }
            }
        }

        Write-Log -Message "Starting performance validation for $ServerName" -Level Information
    }

    process {
        try {
            # Collect performance metrics
            $performanceMetrics = Get-ServerPerformanceMetrics -ServerName $ServerName `
                -SampleCount $SampleCount -SampleIntervalSeconds $SampleIntervalSeconds
            $validationResults.Metrics = $performanceMetrics

            # CPU Validation
            $cpuCheck = Test-CPUPerformance -Metrics $performanceMetrics.CPU -Thresholds $Thresholds.CPU
            $validationResults.Checks += @{
                Component = "CPU"
                Status = $cpuCheck.Status
                Details = $cpuCheck.Details
                Metrics = $cpuCheck.Metrics
            }

            # Memory Validation
            $memoryCheck = Test-MemoryPerformance -Metrics $performanceMetrics.Memory -Thresholds $Thresholds.Memory
            $validationResults.Checks += @{
                Component = "Memory"
                Status = $memoryCheck.Status
                Details = $memoryCheck.Details
                Metrics = $memoryCheck.Metrics
            }

            # Disk Validation
            $diskCheck = Test-DiskPerformance -Metrics $performanceMetrics.Disk -Thresholds $Thresholds.Disk
            $validationResults.Checks += @{
                Component = "Disk"
                Status = $diskCheck.Status
                Details = $diskCheck.Details
                Metrics = $diskCheck.Metrics
            }

            # Network Validation
            $networkCheck = Test-NetworkPerformance -Metrics $performanceMetrics.Network -Thresholds $Thresholds.Network
            $validationResults.Checks += @{
                Component = "Network"
                Status = $networkCheck.Status
                Details = $networkCheck.Details
                Metrics = $networkCheck.Metrics
            }

            # System Responsiveness Validation
            $responsivenessCheck = Test-SystemResponsiveness -Metrics $performanceMetrics.System `
                -Thresholds $Thresholds.SystemResponsiveness
            $validationResults.Checks += @{
                Component = "System Responsiveness"
                Status = $responsivenessCheck.Status
                Details = $responsivenessCheck.Details
                Metrics = $responsivenessCheck.Metrics
            }

            # Arc Agent Resource Usage Validation
            $arcAgentCheck = Test-ArcAgentResourceUsage -ServerName $ServerName
            $validationResults.Checks += @{
                Component = "Arc Agent Resource Usage"
                Status = $arcAgentCheck.Status
                Details = $arcAgentCheck.Details
                Metrics = $arcAgentCheck.Metrics
            }

            # AMA Agent Resource Usage Validation (if installed)
            $amaService = Get-Service -Name "AzureMonitorAgent" -ComputerName $ServerName -ErrorAction SilentlyContinue
            if ($amaService) {
                $amaAgentCheck = Test-AMAAgentResourceUsage -ServerName $ServerName
                $validationResults.Checks += @{
                    Component = "AMA Agent Resource Usage"
                    Status = $amaAgentCheck.Status
                    Details = $amaAgentCheck.Details
                    Metrics = $amaAgentCheck.Metrics
                }
            }

            # Determine Overall Status
            $criticalChecks = $validationResults.Checks | Where-Object { $_.Status -eq "Critical" }
            $warningChecks = $validationResults.Checks | Where-Object { $_.Status -eq "Warning" }

            if ($criticalChecks.Count -gt 0) {
                $validationResults.Status = "Critical"
            }
            elseif ($warningChecks.Count -gt 0) {
                $validationResults.Status = "Warning"
            }
            else {
                $validationResults.Status = "Success"
            }

            # Generate Recommendations
            $validationResults.Recommendations = Get-PerformanceRecommendations -Checks $validationResults.Checks

            Write-Log -Message "Performance validation completed with status: $($validationResults.Status)" -Level Information
        }
        catch {
            $validationResults.Status = "Error"
            $validationResults.Error = $_.Exception.Message
            Write-Error "Performance validation failed: $_"
        }
    }

    end {
        $validationResults.EndTime = Get-Date
        $validationResults.Duration = $validationResults.EndTime - $validationResults.StartTime

        # If detailed output requested, include raw metrics
        if (-not $DetailedOutput) {
            $validationResults.Remove('Metrics')
        }

        return [PSCustomObject]$validationResults
    }
}

function Get-ServerPerformanceMetrics {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [int]$SampleCount = 5,
        [Parameter()]
        [int]$SampleIntervalSeconds = 10
    )

    $metrics = @{
        CPU = @{}
        Memory = @{}
        Disk = @{}
        Network = @{}
        System = @{}
        Samples = @()
    }

    try {
        # Define performance counters to collect
        $counters = @(
            "\Processor(_Total)\% Processor Time",
            "\Memory\Available MBytes",
            "\Memory\% Committed Bytes In Use",
            "\PhysicalDisk(_Total)\% Disk Time",
            "\PhysicalDisk(_Total)\Avg. Disk sec/Read",
            "\PhysicalDisk(_Total)\Avg. Disk sec/Write",
            "\Network Interface(*)\Bytes Total/sec",
            "\Network Interface(*)\Output Queue Length",
            "\System\Processor Queue Length",
            "\System\Context Switches/sec"
        )

        # Collect samples
        for ($i = 1; $i -le $SampleCount; $i++) {
            $sample = @{
                Timestamp = Get-Date
                Counters = @{}
            }

            $counterResults = Get-Counter -ComputerName $ServerName -Counter $counters -ErrorAction Stop
            foreach ($counterResult in $counterResults.CounterSamples) {
                $sample.Counters[$counterResult.Path] = $counterResult.CookedValue
            }

            # Get disk space information
            $diskInfo = Get-WmiObject -Class Win32_LogicalDisk -ComputerName $ServerName -Filter "DeviceID='C:'"
            $sample.DiskSpace = @{
                TotalGB = [math]::Round($diskInfo.Size / 1GB, 2)
                FreeGB = [math]::Round($diskInfo.FreeSpace / 1GB, 2)
                FreePercent = [math]::Round(($diskInfo.FreeSpace / $diskInfo.Size) * 100, 2)
            }

            # Get network latency
            $ping = Test-Connection -ComputerName $ServerName -Count 1 -ErrorAction SilentlyContinue
            $sample.NetworkLatency = if ($ping) { $ping.ResponseTime } else { $null }

            $metrics.Samples += $sample

            if ($i -lt $SampleCount) {
                Start-Sleep -Seconds $SampleIntervalSeconds
            }
        }

        # Calculate summary metrics
        $metrics.CPU = @{
            AverageUsage = ($metrics.Samples.Counters."\Processor(_Total)\% Processor Time" | Measure-Object -Average).Average
            MaxUsage = ($metrics.Samples.Counters."\Processor(_Total)\% Processor Time" | Measure-Object -Maximum).Maximum
            MinUsage = ($metrics.Samples.Counters."\Processor(_Total)\% Processor Time" | Measure-Object -Minimum).Minimum
        }

        $metrics.Memory = @{
            AverageAvailableMB = ($metrics.Samples.Counters."\Memory\Available MBytes" | Measure-Object -Average).Average
            MinAvailableMB = ($metrics.Samples.Counters."\Memory\Available MBytes" | Measure-Object -Minimum).Minimum
            AverageCommitPercent = ($metrics.Samples.Counters."\Memory\% Committed Bytes In Use" | Measure-Object -Average).Average
        }

        $metrics.Disk = @{
            AverageDiskTime = ($metrics.Samples.Counters."\PhysicalDisk(_Total)\% Disk Time" | Measure-Object -Average).Average
            AverageReadLatencyMS = ($metrics.Samples.Counters."\PhysicalDisk(_Total)\Avg. Disk sec/Read" | Measure-Object -Average).Average * 1000
            AverageWriteLatencyMS = ($metrics.Samples.Counters."\PhysicalDisk(_Total)\Avg. Disk sec/Write" | Measure-Object -Average).Average * 1000
            FreeSpaceGB = $metrics.Samples[-1].DiskSpace.FreeGB
            FreeSpacePercent = $metrics.Samples[-1].DiskSpace.FreePercent
        }

        $metrics.Network = @{
            AverageThroughputBytesPerSec = ($metrics.Samples.Counters."\Network Interface(*)\Bytes Total/sec" | Measure-Object -Average).Average
            AverageOutputQueueLength = ($metrics.Samples.Counters."\Network Interface(*)\Output Queue Length" | Measure-Object -Average).Average
            AverageLatencyMS = ($metrics.Samples.NetworkLatency | Measure-Object -Average).Average
        }

        $metrics.System = @{
            AverageProcessorQueueLength = ($metrics.Samples.Counters."\System\Processor Queue Length" | Measure-Object -Average).Average
            AverageContextSwitchesPerSec = ($metrics.Samples.Counters."\System\Context Switches/sec" | Measure-Object -Average).Average
        }
    }
    catch {
        Write-Error "Failed to collect performance metrics: $_"
        throw
    }

    return $metrics
}

function Test-CPUPerformance {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [hashtable]$Metrics,
        [Parameter(Mandatory)]
        [hashtable]$Thresholds
    )

    $result = @{
        Status = "Success"
        Details = @()
        Metrics = $Metrics
    }

    # Check average CPU usage
    if ($Metrics.AverageUsage -ge $Thresholds.Critical) {
        $result.Status = "Critical"
        $result.Details += "Average CPU usage is critical: $([math]::Round($Metrics.AverageUsage, 2))% (Threshold: $($Thresholds.Critical)%)"
    }
    elseif ($Metrics.AverageUsage -ge $Thresholds.Warning) {
        $result.Status = "Warning"
        $result.Details += "Average CPU usage is high: $([math]::Round($Metrics.AverageUsage, 2))% (Threshold: $($Thresholds.Warning)%)"
    }
    else {
        $result.Details += "CPU usage is normal: $([math]::Round($Metrics.AverageUsage, 2))%"
    }

    # Check maximum CPU usage
    if ($Metrics.MaxUsage -ge $Thresholds.Critical) {
        $result.Details += "Maximum CPU usage reached critical level: $([math]::Round($Metrics.MaxUsage, 2))%"
    }

    return $result
}

function Test-MemoryPerformance {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [hashtable]$Metrics,
        [Parameter(Mandatory)]
        [hashtable]$Thresholds
    )

    $result = @{
        Status = "Success"
        Details = @()
        Metrics = $Metrics
    }

    # Check available memory
    if ($Metrics.MinAvailableMB -le $Thresholds.AvailableMBCritical) {
        $result.Status = "Critical"
        $result.Details += "Available memory is critically low: $([math]::Round($Metrics.MinAvailableMB, 2)) MB (Threshold: $($Thresholds.AvailableMBCritical) MB)"
    }
    elseif ($Metrics.MinAvailableMB -le $Thresholds.AvailableMBWarning) {
        $result.Status = "Warning"
        $result.Details += "Available memory is low: $([math]::Round($Metrics.MinAvailableMB, 2)) MB (Threshold: $($Thresholds.AvailableMBWarning) MB)"
    }
    else {
        $result.Details += "Memory availability is normal: $([math]::Round($Metrics.AverageAvailableMB, 2)) MB"
    }

    # Check memory commit percentage
    if ($Metrics.AverageCommitPercent -gt 90) {
        $result.Details += "Memory commit percentage is high: $([math]::Round($Metrics.AverageCommitPercent, 2))%"
    }

    return $result
}

function Test-DiskPerformance {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [hashtable]$Metrics,
        [Parameter(Mandatory)]
        [hashtable]$Thresholds
    )

    $result = @{
        Status = "Success"
        Details = @()
        Metrics = $Metrics
    }

    # Check disk free space percentage
    if ($Metrics.FreeSpacePercent -le $Thresholds.FreePercentCritical) {
        $result.Status = "Critical"
        $result.Details += "Disk free space is critically low: $([math]::Round($Metrics.FreeSpacePercent, 2))% (Threshold: $($Thresholds.FreePercentCritical)%)"
    }
    elseif ($Metrics.FreeSpacePercent -le $Thresholds.FreePercentWarning) {
        $result.Status = "Warning"
        $result.Details += "Disk free space is low: $([math]::Round($Metrics.FreeSpacePercent, 2))% (Threshold: $($Thresholds.FreePercentWarning)%)"
    }
    else {
        $result.Details += "Disk free space is normal: $([math]::Round($Metrics.FreeSpacePercent, 2))% ($([math]::Round($Metrics.FreeSpaceGB, 2)) GB)"
    }

    # Check disk latency
    if ($Metrics.AverageReadLatencyMS -gt 20 -or $Metrics.AverageWriteLatencyMS -gt 20) {
        $result.Details += "Disk latency is high: Read $([math]::Round($Metrics.AverageReadLatencyMS, 2)) ms, Write $([math]::Round($Metrics.AverageWriteLatencyMS, 2)) ms"
        if ($result.Status -ne "Critical") {
            $result.Status = "Warning"
        }
    }

    return $result
}

function Test-NetworkPerformance {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [hashtable]$Metrics,
        [Parameter(Mandatory)]
        [hashtable]$Thresholds
    )

    $result = @{
        Status = "Success"
        Details = @()
        Metrics = $Metrics
    }

    # Check network latency
    if ($Metrics.AverageLatencyMS -ge $Thresholds.LatencyMSCritical) {
        $result.Status = "Critical"
        $result.Details += "Network latency is critically high: $([math]::Round($Metrics.AverageLatencyMS, 2)) ms (Threshold: $($Thresholds.LatencyMSCritical) ms)"
    }
    elseif ($Metrics.AverageLatencyMS -ge $Thresholds.LatencyMSWarning) {
        $result.Status = "Warning"
        $result.Details += "Network latency is high: $([math]::Round($Metrics.AverageLatencyMS, 2)) ms (Threshold: $($Thresholds.LatencyMSWarning) ms)"
    }
    else {
        $result.Details += "Network latency is normal: $([math]::Round($Metrics.AverageLatencyMS, 2)) ms"
    }

    # Check network output queue
    if ($Metrics.AverageOutputQueueLength -gt 2) {
        $result.Details += "Network output queue length is high: $([math]::Round($Metrics.AverageOutputQueueLength, 2))"
        if ($result.Status -ne "Critical") {
            $result.Status = "Warning"
        }
    }

    return $result
}

function Test-SystemResponsiveness {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [hashtable]$Metrics,
        [Parameter(Mandatory)]
        [hashtable]$Thresholds
    )

    $result = @{
        Status = "Success"
        Details = @()
        Metrics = $Metrics
    }

    # Check processor queue length
    if ($Metrics.AverageProcessorQueueLength -ge $Thresholds.ProcessorQueueCritical) {
        $result.Status = "Critical"
        $result.Details += "Processor queue length is critically high: $([math]::Round($Metrics.AverageProcessorQueueLength, 2)) (Threshold: $($Thresholds.ProcessorQueueCritical))"
    }
    elseif ($Metrics.AverageProcessorQueueLength -ge $Thresholds.ProcessorQueueWarning) {
        $result.Status = "Warning"
        $result.Details += "Processor queue length is high: $([math]::Round($Metrics.AverageProcessorQueueLength, 2)) (Threshold: $($Thresholds.ProcessorQueueWarning))"
    }
    else {
        $result.Details += "System responsiveness is normal"
    }

    # Check context switches
    if ($Metrics.AverageContextSwitchesPerSec -gt 15000) {
        $result.Details += "Context switches per second is high: $([math]::Round($Metrics.AverageContextSwitchesPerSec, 2))"
        if ($result.Status -ne "Critical") {
            $result.Status = "Warning"
        }
    }

    return $result
}

function Test-ArcAgentResourceUsage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName
    )

    $result = @{
        Status = "Success"
        Details = @()
        Metrics = @{}
    }

    try {
        # Get Arc agent process information
        $arcProcess = Get-Process -Name "himds" -ComputerName $ServerName -ErrorAction SilentlyContinue
        
        if (-not $arcProcess) {
            $result.Status = "Critical"
            $result.Details += "Arc agent process (himds) not found"
            return $result
        }

        $result.Metrics = @{
            CPUPercent = $arcProcess.CPU
            MemoryMB = [math]::Round($arcProcess.WorkingSet / 1MB, 2)
            Threads = $arcProcess.Threads.Count
            Handles = $arcProcess.HandleCount
        }

        # Check CPU usage
        if ($result.Metrics.CPUPercent -gt 10) {
            $result.Status = "Warning"
            $result.Details += "Arc agent CPU usage is high: $($result.Metrics.CPUPercent)%"
        }

        # Check memory usage
        if ($result.Metrics.MemoryMB -gt 200) {
            $result.Status = "Warning"
            $result.Details += "Arc agent memory usage is high: $($result.Metrics.MemoryMB) MB"
        }

        # Check handle count
        if ($result.Metrics.Handles -gt 1000) {
            $result.Details += "Arc agent handle count is high: $($result.Metrics.Handles)"
        }

        if ($result.Details.Count -eq 0) {
            $result.Details += "Arc agent resource usage is normal"
        }
    }
    catch {
        $result.Status = "Error"
        $result.Error = $_.Exception.Message
        Write-Error "Failed to check Arc agent resource usage: $_"
    }

    return $result
}

function Test-AMAAgentResourceUsage {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName
    )

    $result = @{
        Status = "Success"
        Details = @()
        Metrics = @{}
    }

    try {
        # Get AMA agent process information
        $amaProcess = Get-Process -Name "AzureMonitorAgent" -ComputerName $ServerName -ErrorAction SilentlyContinue
        
        if (-not $amaProcess) {
            $result.Status = "Critical"
            $result.Details += "AMA agent process not found"
            return $result
        }

        $result.Metrics = @{
            CPUPercent = $amaProcess.CPU
            MemoryMB = [math]::Round($amaProcess.WorkingSet / 1MB, 2)
            Threads = $amaProcess.Threads.Count
            Handles = $amaProcess.HandleCount
        }

        # Check CPU usage
        if ($result.Metrics.CPUPercent -gt 15) {
            $result.Status = "Warning"
            $result.Details += "AMA agent CPU usage is high: $($result.Metrics.CPUPercent)%"
        }

        # Check memory usage
        if ($result.Metrics.MemoryMB -gt 300) {
            $result.Status = "Warning"
            $result.Details += "AMA agent memory usage is high: $($result.Metrics.MemoryMB) MB"
        }

        # Check handle count
        if ($result.Metrics.Handles -gt 1500) {
            $result.Details += "AMA agent handle count is high: $($result.Metrics.Handles)"
        }

        if ($result.Details.Count -eq 0) {
            $result.Details += "AMA agent resource usage is normal"
        }
    }
    catch {
        $result.Status = "Error"
        $result.Error = $_.Exception.Message
        Write-Error "Failed to check AMA agent resource usage: $_"
    }

    return $result
}

function Get-PerformanceRecommendations {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [array]$Checks
    )

    $recommendations = @()

    foreach ($check in $Checks) {
        if ($check.Status -ne "Success") {
            $recommendation = switch ($check.Component) {
                "CPU" {
                    @{
                        Component = $check.Component
                        Priority = if ($check.Status -eq "Critical") { "High" } else { "Medium" }
                        Action = "Investigate high CPU usage and consider resource optimization"
                        Details = $check.Details
                    }
                }
                "Memory" {
                    @{
                        Component = $check.Component
                        Priority = if ($check.Status -eq "Critical") { "High" } else { "Medium" }
                        Action = "Address memory constraints by optimizing applications or adding memory"
                        Details = $check.Details
                    }
                }
                "Disk" {
                    @{
                        Component = $check.Component
                        Priority = if ($check.Status -eq "Critical") { "High" } else { "Medium" }
                        Action = "Free up disk space and optimize disk I/O patterns"
                        Details = $check.Details
                    }
                }
                "Network" {
                    @{
                        Component = $check.Component
                        Priority = if ($check.Status -eq "Critical") { "High" } else { "Medium" }
                        Action = "Investigate network latency and bandwidth issues"
                        Details = $check.Details
                    }
                }
                "System Responsiveness" {
                    @{
                        Component = $check.Component
                        Priority = if ($check.Status -eq "Critical") { "High" } else { "Medium" }
                        Action = "Optimize system performance and reduce contention"
                        Details = $check.Details
                    }
                }
                "Arc Agent Resource Usage" {
                    @{
                        Component = $check.Component
                        Priority = if ($check.Status -eq "Critical") { "High" } else { "Medium" }
                        Action = "Investigate Arc agent resource consumption and consider agent optimization"
                        Details = $check.Details
                    }
                }
                "AMA Agent Resource Usage" {
                    @{
                        Component = $check.Component
                        Priority = if ($check.Status -eq "Critical") { "High" } else { "Medium" }
                        Action = "Optimize AMA agent configuration and data collection rules"
                        Details = $check.Details
                    }
                }
            }

            if ($recommendation) {
                $recommendations += $recommendation
            }
        }
    }

    return $recommendations | Sort-Object -Property Priority
}
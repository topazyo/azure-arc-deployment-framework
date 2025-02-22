function Get-AMAPerformanceMetrics {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [int]$SampleInterval = 300, # 5 minutes
        [Parameter()]
        [int]$SampleCount = 12, # 1 hour of data
        [Parameter()]
        [switch]$IncludeLogMetrics
    )

    begin {
        $metrics = @{
            ServerName = $ServerName
            StartTime = Get-Date
            SampleInterval = $SampleInterval
            Samples = @()
            Summary = @{}
        }

        # Enhanced performance counter paths
        $counterPaths = @(
            "\Process(AzureMonitorAgent)\% Processor Time",
            "\Process(AzureMonitorAgent)\Working Set",
            "\Process(AzureMonitorAgent)\IO Data Operations/sec",
            "\Process(AzureMonitorAgent)\Handle Count",
            "\Network Interface(*)\Bytes Sent/sec"
        )
    }

    process {
        try {
            for ($i = 1; $i -le $SampleCount; $i++) {
                $sample = @{
                    Timestamp = Get-Date
                    Counters = @{}
                }

                foreach ($path in $counterPaths) {
                    $value = Get-Counter -ComputerName $ServerName -Counter $path -ErrorAction Stop
                    $sample.Counters[$path] = $value.CounterSamples[0].CookedValue
                }

                # Optional log collection metrics
                if ($IncludeLogMetrics) {
                    $logMetrics = Get-AMALogCollectionMetrics -ServerName $ServerName
                    $sample.LogCollection = $logMetrics
                }

                $metrics.Samples += $sample
                
                if ($i -lt $SampleCount) {
                    Start-Sleep -Seconds $SampleInterval
                }
            }

            # Enhanced summary statistics
            $metrics.Summary = @{
                CPUUsage = @{
                    Average = ($metrics.Samples.Counters."\Process(AzureMonitorAgent)\% Processor Time" | Measure-Object -Average).Average
                    Maximum = ($metrics.Samples.Counters."\Process(AzureMonitorAgent)\% Processor Time" | Measure-Object -Maximum).Maximum
                }
                MemoryUsageMB = @{
                    Average = ($metrics.Samples.Counters."\Process(AzureMonitorAgent)\Working Set" | Measure-Object -Average).Average / 1MB
                    Maximum = ($metrics.Samples.Counters."\Process(AzureMonitorAgent)\Working Set" | Measure-Object -Maximum).Maximum / 1MB
                }
                IOOperations = @{
                    Average = ($metrics.Samples.Counters."\Process(AzureMonitorAgent)\IO Data Operations/sec" | Measure-Object -Average).Average
                    Maximum = ($metrics.Samples.Counters."\Process(AzureMonitorAgent)\IO Data Operations/sec" | Measure-Object -Maximum).Maximum
                }
                Handles = @{
                    Average = ($metrics.Samples.Counters."\Process(AzureMonitorAgent)\Handle Count" | Measure-Object -Average).Average
                    Maximum = ($metrics.Samples.Counters."\Process(AzureMonitorAgent)\Handle Count" | Measure-Object -Maximum).Maximum
                }
                Network = @{
                    AverageBytesPerSec = ($metrics.Samples.Counters."\Network Interface(*)\Bytes Sent/sec" | Measure-Object -Average).Average
                    TotalBytes = ($metrics.Samples.Counters."\Network Interface(*)\Bytes Sent/sec" | Measure-Object -Sum).Sum * $SampleInterval
                }
            }

            # Add enhanced recommendations
            $metrics.Recommendations = Get-PerformanceRecommendations -Metrics $metrics.Summary
        }
        catch {
            Write-Error "Failed to collect performance metrics: $_"
            $metrics.Error = $_.Exception.Message
        }
    }

    end {
        return [PSCustomObject]$metrics
    }
}

function Get-PerformanceRecommendations {
    param (
        [Parameter(Mandatory)]
        [hashtable]$Metrics
    )

    $recommendations = @()

    # Enhanced recommendations including all metrics
    if ($Metrics.CPUUsage.Average -gt 10) {
        $recommendations += @{
            Component = "CPU"
            Severity = if ($Metrics.CPUUsage.Average -gt 20) { "High" } else { "Medium" }
            Issue = "High CPU usage detected"
            Recommendation = "Consider adjusting data collection frequency or filtering"
            CurrentValue = "$([math]::Round($Metrics.CPUUsage.Average, 2))%"
        }
    }

    if ($Metrics.MemoryUsageMB.Average -gt 500) {
        $recommendations += @{
            Component = "Memory"
            Severity = if ($Metrics.MemoryUsageMB.Average -gt 1000) { "High" } else { "Medium" }
            Issue = "High memory usage detected"
            Recommendation = "Review data collection rules and buffer settings"
            CurrentValue = "$([math]::Round($Metrics.MemoryUsageMB.Average, 2)) MB"
        }
    }

    if ($Metrics.IOOperations.Average -gt 1000) {
        $recommendations += @{
            Component = "IO"
            Severity = if ($Metrics.IOOperations.Average -gt 2000) { "High" } else { "Medium" }
            Issue = "High I/O operations detected"
            Recommendation = "Consider adjusting log collection volume or frequency"
            CurrentValue = "$([math]::Round($Metrics.IOOperations.Average, 2)) ops/sec"
        }
    }

    if ($Metrics.Handles.Average -gt 1000) {
        $recommendations += @{
            Component = "Handles"
            Severity = if ($Metrics.Handles.Average -gt 2000) { "High" } else { "Medium" }
            Issue = "High handle count detected"
            Recommendation = "Investigate potential handle leaks"
            CurrentValue = "$([math]::Round($Metrics.Handles.Average, 2)) handles"
        }
    }

    if ($Metrics.Network.AverageBytesPerSec -gt 1MB) {
        $recommendations += @{
            Component = "Network"
            Severity = if ($Metrics.Network.AverageBytesPerSec -gt 5MB) { "High" } else { "Medium" }
            Issue = "High network usage detected"
            Recommendation = "Review data upload frequency and compression settings"
            CurrentValue = "$([math]::Round($Metrics.Network.AverageBytesPerSec / 1MB, 2)) MB/sec"
        }
    }

    return $recommendations
}
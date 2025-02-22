function Get-SystemPerformanceMetrics {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [int]$SampleInterval = 5,
        [Parameter()]
        [int]$SampleCount = 12
    )

    $metrics = @{
        ServerName = $ServerName
        StartTime = Get-Date
        Samples = @()
        Summary = @{}
        Recommendations = @()
    }

    try {
        $counters = @(
            "\Processor(_Total)\% Processor Time",
            "\Memory\Available MBytes",
            "\Memory\Pages/sec",
            "\PhysicalDisk(_Total)\Avg. Disk sec/Read",
            "\PhysicalDisk(_Total)\Avg. Disk sec/Write",
            "\Network Interface(*)\Bytes Total/sec",
            "\System\Processor Queue Length"
        )

        for ($i = 1; $i -le $SampleCount; $i++) {
            $sample = @{
                Timestamp = Get-Date
                Counters = @{}
            }

            $counterResults = Get-Counter -ComputerName $ServerName -Counter $counters -ErrorAction Stop
            foreach ($counterResult in $counterResults.CounterSamples) {
                $sample.Counters[$counterResult.Path] = $counterResult.CookedValue
            }

            $metrics.Samples += $sample
            
            if ($i -lt $SampleCount) {
                Start-Sleep -Seconds $SampleInterval
            }
        }

        # Calculate summary statistics
        $metrics.Summary = Calculate-PerformanceMetrics -Samples $metrics.Samples

        # Generate recommendations
        $metrics.Recommendations = Get-PerformanceRecommendations -Metrics $metrics.Summary
    }
    catch {
        Write-Error "Failed to collect performance metrics: $_"
        $metrics.Error = $_.Exception.Message
    }
    finally {
        $metrics.EndTime = Get-Date
        $metrics.Duration = $metrics.EndTime - $metrics.StartTime
    }

    return [PSCustomObject]$metrics
}

function Calculate-PerformanceMetrics {
    [CmdletBinding()]
    param ([array]$Samples)

    $summary = @{
        CPU = @{
            Average = ($Samples.Counters."\Processor(_Total)\% Processor Time" | Measure-Object -Average).Average
            Maximum = ($Samples.Counters."\Processor(_Total)\% Processor Time" | Measure-Object -Maximum).Maximum
        }
        Memory = @{
            AverageAvailable = ($Samples.Counters."\Memory\Available MBytes" | Measure-Object -Average).Average
            MinimumAvailable = ($Samples.Counters."\Memory\Available MBytes" | Measure-Object -Minimum).Minimum
            PagingRate = ($Samples.Counters."\Memory\Pages/sec" | Measure-Object -Average).Average
        }
        Disk = @{
            AverageReadLatency = ($Samples.Counters."\PhysicalDisk(_Total)\Avg. Disk sec/Read" | Measure-Object -Average).Average
            AverageWriteLatency = ($Samples.Counters."\PhysicalDisk(_Total)\Avg. Disk sec/Write" | Measure-Object -Average).Average
        }
        Network = @{
            AverageThroughput = ($Samples.Counters."\Network Interface(*)\Bytes Total/sec" | Measure-Object -Average).Average
            MaximumThroughput = ($Samples.Counters."\Network Interface(*)\Bytes Total/sec" | Measure-Object -Maximum).Maximum
        }
        System = @{
            AverageProcessorQueue = ($Samples.Counters."\System\Processor Queue Length" | Measure-Object -Average).Average
        }
    }

    return $summary
}

function Get-PerformanceRecommendations {
    [CmdletBinding()]
    param ([hashtable]$Metrics)

    $recommendations = @()

    # CPU Recommendations
    if ($Metrics.CPU.Average -gt 80) {
        $recommendations += @{
            Component = "CPU"
            Severity = "High"
            Issue = "High CPU utilization"
            Recommendation = "Investigate high CPU usage and consider resource optimization"
            CurrentValue = "$([math]::Round($Metrics.CPU.Average, 2))%"
        }
    }

    # Memory Recommendations
    if ($Metrics.Memory.AverageAvailable -lt 1024) {
        $recommendations += @{
            Component = "Memory"
            Severity = "High"
            Issue = "Low available memory"
            Recommendation = "Investigate memory usage and consider increasing memory"
            CurrentValue = "$([math]::Round($Metrics.Memory.AverageAvailable, 2)) MB"
        }
    }

    if ($Metrics.Memory.PagingRate -gt 1000) {
        $recommendations += @{
            Component = "Memory"
            Severity = "Medium"
            Issue = "High paging rate"
            Recommendation = "Investigate memory pressure and paging activity"
            CurrentValue = "$([math]::Round($Metrics.Memory.PagingRate, 2)) pages/sec"
        }
    }

    # Disk Recommendations
    if ($Metrics.Disk.AverageReadLatency -gt 0.025 -or $Metrics.Disk.AverageWriteLatency -gt 0.025) {
        $recommendations += @{
            Component = "Disk"
            Severity = "Medium"
            Issue = "High disk latency"
            Recommendation = "Investigate disk performance and I/O patterns"
            CurrentValue = "Read: $([math]::Round($Metrics.Disk.AverageReadLatency * 1000, 2))ms, Write: $([math]::Round($Metrics.Disk.AverageWriteLatency * 1000, 2))ms"
        }
    }

    # Network Recommendations
    if ($Metrics.Network.AverageThroughput -gt 50MB) {
        $recommendations += @{
            Component = "Network"
            Severity = "Medium"
            Issue = "High network utilization"
            Recommendation = "Monitor network traffic patterns and optimize if necessary"
            CurrentValue = "$([math]::Round($Metrics.Network.AverageThroughput / 1MB, 2)) MB/s"
        }
    }

    return $recommendations
}
function Invoke-AIPatternAnalysis {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$LogPath,
        [Parameter()]
        [int]$DaysToAnalyze = 30,
        [Parameter()]
        [string]$OutputPath,
        [Parameter()]
        [switch]$GenerateRecommendations,
        [Parameter()]
        [switch]$UseCloudAnalysis,
        [Parameter()]
        [string[]]$LogContent
    )

    $analysisResults = @{
        StartTime = Get-Date
        LogSource = $LogPath
        TimeFrame = $DaysToAnalyze
        Patterns = @()
        Recommendations = @()
        Statistics = @{}
        CloudInsights = @()
    }

    try {
        $lines = $null
        if ($PSBoundParameters.ContainsKey('LogContent') -and $LogContent) {
            $lines = $LogContent
        } else {
            $lines = Get-Content -Path $LogPath -ErrorAction Stop
        }

        $records = Get-PatternRecords -LogLines $lines -DaysToAnalyze $DaysToAnalyze
        $analysisResults.Patterns = $records | Group-Object -Property Category | ForEach-Object {
            $impact = Get-ErrorImpact -Errors $_.Group
            @{
                Category = $_.Name
                Count = $_.Count
                Samples = $_.Group | Select-Object -First 5
                Impact = $impact
                TimeDistribution = Get-TimeDistribution -Errors $_.Group
                SeverityScore = Get-SeverityScore -Impact $impact
            }
        }

        $analysisResults.Statistics = @{
            TotalErrors = $records.Count
            UniquePatterns = ($records | Select-Object -ExpandProperty Pattern -Unique).Count
            MostCommonCategory = if ($records.Count -gt 0) { ($analysisResults.Patterns | Sort-Object Count -Descending | Select-Object -First 1).Category } else { $null }
            TimeBasedDistribution = Get-ErrorTimeDistribution -Errors $records
            SeverityDistribution = Get-ErrorSeverityDistribution -Errors $records
            AnomalyScore = Get-LocalAnomalyScore -Patterns $analysisResults.Patterns
        }

        if ($UseCloudAnalysis) {
            $cloudCmd = Get-Command -Name Connect-AzCognitiveService -ErrorAction SilentlyContinue
            if ($cloudCmd) {
                try {
                    $cognitiveService = & $cloudCmd -Name "arc-pattern-analysis"
                    $analysisResults.CloudInsights = $cognitiveService.AnalyzePatterns(@{ LogContent = $lines; TimeFrame = (Get-Date).AddDays(-$DaysToAnalyze) })
                } catch {
                    Write-Warning "Cloud analysis failed; continuing with local results. Error: $($_.Exception.Message)"
                }
            } else {
                Write-Warning "Connect-AzCognitiveService not available. Skipping cloud analysis."
            }
        }

        if ($GenerateRecommendations) {
            $analysisResults.Recommendations = $analysisResults.Patterns | ForEach-Object {
                $localRecommendation = Get-LocalRecommendation -Pattern $_
                if ($analysisResults.CloudInsights -and $analysisResults.CloudInsights.Recommendations) {
                    $cloudRecommendation = $analysisResults.CloudInsights.Recommendations | Where-Object { $_.Category -eq $_.Category } | Select-Object -First 1
                    Merge-Recommendations -Local $localRecommendation -Cloud $cloudRecommendation
                } else {
                    $localRecommendation
                }
            }
        }

        if ($OutputPath) {
            $analysisResults | ConvertTo-Json -Depth 10 | Out-File (Join-Path $OutputPath "PatternAnalysis_$(Get-Date -Format 'yyyyMMdd').json")
        }
    }
    catch {
        Write-Error "Pattern analysis failed: $_"
        $analysisResults.Error = $_.Exception.Message
    }

    return [PSCustomObject]$analysisResults
}

function Get-PatternRecords {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string[]]$LogLines,
        [Parameter(Mandatory)] [int]$DaysToAnalyze
    )

    $cutoff = (Get-Date).AddDays(-$DaysToAnalyze)
    $records = [System.Collections.ArrayList]::new()

    foreach ($line in $LogLines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $timestamp = Get-LogTimestamp -Line $line
        if ($timestamp -and $timestamp -lt $cutoff) { continue }

        $category = Get-CategoryFromLine -Line $line
        $severity = Get-SeverityFromLine -Line $line
        $pattern = Get-PatternName -Line $line -Category $category

        $records.Add([PSCustomObject]@{
            Category = $category
            Severity = $severity
            Pattern = $pattern
            Timestamp = if ($timestamp) { $timestamp } else { Get-Date }
            Message = $line
        }) | Out-Null
    }

    return $records
}

function Get-LogTimestamp {
    param([string]$Line)
    $match = [regex]::Match($Line, '^(?<ts>\d{4}-\d{2}-\d{2}(?:[ T]\d{2}:\d{2}:\d{2})?)')
    if ($match.Success) {
        $tsString = $match.Groups['ts'].Value
        try { return [datetime]::Parse($tsString) } catch { return $null }
    }
    return $null
}

function Get-CategoryFromLine {
    param([string]$Line)
    if ($Line -match 'disk|storage') { return 'Storage' }
    if ($Line -match 'network|connect') { return 'Network' }
    if ($Line -match 'service|daemon') { return 'Service' }
    if ($Line -match 'cpu|memory|latency|performance') { return 'Performance' }
    return 'General'
}

function Get-SeverityFromLine {
    param([string]$Line)
    if ($Line -match 'fatal|panic|critical') { return 'Critical' }
    if ($Line -match 'error|fail|exception') { return 'High' }
    if ($Line -match 'warn') { return 'Medium' }
    return 'Low'
}

function Get-PatternName {
    param([string]$Line, [string]$Category)
    if ($Category -eq 'Storage' -and $Line -match 'disk') { return 'DiskFailure' }
    if ($Category -eq 'Network' -and $Line -match 'timeout') { return 'NetworkTimeout' }
    if ($Category -eq 'Service' -and $Line -match 'crash|stopped') { return 'ServiceCrash' }
    if ($Category -eq 'Performance' -and $Line -match 'latency|cpu|memory') { return 'PerformanceDegradation' }
    return 'GeneralIssue'
}

function Get-ErrorImpact {
    param([Parameter(Mandatory)] [object[]]$Errors)
    $impact = @{
        ServiceDisruption = 0
        SecurityIssues = 0
        DataLoss = 0
        PerformanceImpact = 0
    }

    foreach ($err in $Errors) {
        switch ($err.Category) {
            'Service' { $impact.ServiceDisruption += 1 }
            'Network' { $impact.ServiceDisruption += 1 }
            'Storage' { $impact.DataLoss += 1 }
            'Performance' { $impact.PerformanceImpact += 1 }
            default { $impact.PerformanceImpact += 0 }
        }
        if ($err.Severity -eq 'Critical') { $impact.ServiceDisruption += 1 }
    }
    return $impact
}

function Get-TimeDistribution {
    param([Parameter(Mandatory)] [object[]]$Errors)
    return ($Errors | Group-Object { $_.Timestamp.Date } | ForEach-Object { @{ Date = $_.Name; Count = $_.Count } })
}

function Get-ErrorTimeDistribution {
    param([Parameter(Mandatory)] [object[]]$Errors)
    return Get-TimeDistribution -Errors $Errors
}

function Get-ErrorSeverityDistribution {
    param([Parameter(Mandatory)] [object[]]$Errors)
    return ($Errors | Group-Object -Property Severity | ForEach-Object { @{ Severity = $_.Name; Count = $_.Count } })
}

function Get-LocalAnomalyScore {
    param([Parameter(Mandatory)] [object[]]$Patterns)
    if (-not $Patterns -or $Patterns.Count -eq 0) { return 0 }
    $highImpact = ($Patterns | Where-Object { $_.SeverityScore -ge 0.5 }).Count
    return [math]::Round($highImpact / $Patterns.Count, 2)
}

function Get-SeverityScore {
    param (
        [Parameter(Mandatory)]
        [hashtable]$Impact
    )
    
    $weights = @{
        ServiceDisruption = 0.4
        SecurityIssues = 0.3
        DataLoss = 0.2
        PerformanceImpact = 0.1
    }

    $score = 0
    foreach ($metric in $Impact.Keys) {
        if ($weights.ContainsKey($metric)) {
            $score += $Impact[$metric] * $weights[$metric]
        }
    }

    return [math]::Round($score, 2)
}

function Get-LocalRecommendation {
    param([Parameter(Mandatory)] [hashtable]$Pattern)
    $priority = if ($Pattern.SeverityScore -ge 0.6) { 'High' } elseif ($Pattern.SeverityScore -ge 0.3) { 'Medium' } else { 'Low' }
    $actions = @()
    switch ($Pattern.Category) {
        'Storage' { $actions += 'Inspect disks and storage connectivity' }
        'Network' { $actions += 'Validate network endpoints and latency' }
        'Service' { $actions += 'Restart impacted service after log review' }
        'Performance' { $actions += 'Tune resource allocation and retry workload' }
        default { $actions += 'Review logs for recurring issues' }
    }

    return @{
        Category = $Pattern.Category
        Priority = $priority
        Actions = $actions
    }
}

function Merge-Recommendations {
    param (
        [Parameter(Mandatory)]
        [hashtable]$Local,
        [Parameter(Mandatory)]
        [hashtable]$Cloud
    )

    if (-not $Local -and -not $Cloud) { return $null }
    if (-not $Local) { return $Cloud }
    if (-not $Cloud) { return $Local }

    $merged = @{
        Category = if ($Local.Category) { $Local.Category } else { $Cloud.Category }
        Priority = if ($Local.Priority -and $Cloud.Priority) { ($Local.Priority, $Cloud.Priority | Sort-Object | Select-Object -First 1) } elseif ($Local.Priority) { $Local.Priority } else { $Cloud.Priority }
        Actions = @()
    }

    $merged.Actions = @($Local.Actions) + @($Cloud.Actions) | Where-Object { $_ } | Sort-Object -Unique
    return $merged
}
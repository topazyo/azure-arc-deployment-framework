<#
.SYNOPSIS
Analyzes collected troubleshooting phases into issues, patterns, and actions.

.DESCRIPTION
Consumes the staged output from system-state, diagnostics, and AMA collection,
applies configured analysis patterns, generates recommendations, calculates
impact scores, and returns issues prioritized for operator review.

.PARAMETER Data
Collected troubleshooting phases to analyze.

.PARAMETER ConfigPath
Pattern definition file used during analysis.

.OUTPUTS
PSCustomObject
#>
function Invoke-TroubleshootingAnalysis {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [array]$Data,
        [Parameter()]
        [string]$ConfigPath = ".\Config\analysis-patterns.json"
    )

    begin {
        $analysisResults = @{
            Timestamp = Get-Date
            Issues = @()
            Patterns = @()
            Recommendations = @()
        }

        # Load analysis patterns
        $patterns = Get-Content $ConfigPath | ConvertFrom-Json
    }

    process {
        try {
            # Analyze System State
            $systemState = $Data | Where-Object { $_.Phase -eq "SystemState" } | Select-Object -ExpandProperty Data
            $systemIssues = Find-SystemStateIssues -State $systemState -Patterns $patterns.SystemState
            $analysisResults.Issues += $systemIssues

            # Analyze Arc Agent Issues
            $arcDiagnostics = $Data | Where-Object { $_.Phase -eq "ArcDiagnostics" } | Select-Object -ExpandProperty Data
            $arcIssues = Find-ArcAgentIssues -Diagnostics $arcDiagnostics -Patterns $patterns.ArcAgent
            $analysisResults.Issues += $arcIssues

            # Analyze AMA Issues (if present)
            $amaDiagnostics = $Data | Where-Object { $_.Phase -eq "AMADiagnostics" } | Select-Object -ExpandProperty Data
            if ($amaDiagnostics) {
                $amaIssues = Find-AMAIssues -Diagnostics $amaDiagnostics -Patterns $patterns.AMA
                $analysisResults.Issues += $amaIssues
            }

            # Pattern Recognition
            $analysisResults.Patterns = Find-CommonPatterns -Issues $analysisResults.Issues

            # Generate Recommendations
            $analysisResults.Recommendations = foreach ($issue in $analysisResults.Issues) {
                Get-IssueRecommendation -Issue $issue -Patterns $patterns
            }

            # Calculate impact scores
            foreach ($issue in $analysisResults.Issues) {
                $issue.ImpactScore = Measure-ImpactScore -Issue $issue -Patterns $patterns
            }

            # Prioritize Issues
            $analysisResults.Issues = $analysisResults.Issues |
                Sort-Object -Property ImpactScore -Descending
        }
        catch {
            Write-Error "Analysis failed: $_"
            $analysisResults.Error = $_.Exception.Message
        }
    }

    end {
        return [PSCustomObject]$analysisResults
    }
}

<#
.SYNOPSIS
Evaluates system-state data for compatibility and resource issues.

.PARAMETER State
System-state payload to inspect.

.PARAMETER Patterns
Pattern definitions available to the analysis pass.
#>
function Find-SystemStateIssues {
    param ($State, $Patterns)

    $issues = @()

    # Check OS Requirements
    if (-not (Test-OSCompatibility -Version $State.OS.Version)) {
        $issues += @{
            Type = "SystemRequirement"
            Component = "OperatingSystem"
            Severity = "Critical"
            Description = "OS version not compatible"
            Details = $State.OS.Version
        }
    }

    # Check Resource Availability
    if ($State.Memory.AvailableGB -lt 2) {
        $issues += @{
            Type = "Resource"
            Component = "Memory"
            Severity = "Warning"
            Description = "Low memory available"
            Details = "Available: $($State.Memory.AvailableGB)GB"
        }
    }

    # Check Disk Space
    if ($State.Disk.FreeSpaceGB -lt 5) {
        $issues += @{
            Type = "Resource"
            Component = "DiskSpace"
            Severity = "Warning"
            Description = "Low disk space"
            Details = "Free: $($State.Disk.FreeSpaceGB)GB"
        }
    }

    return $issues
}

<#
.SYNOPSIS
Extracts Arc-agent issues from diagnostics results.

.PARAMETER Diagnostics
Arc diagnostics payload to inspect.

.PARAMETER Patterns
Pattern definitions available to the analysis pass.
#>
function Find-ArcAgentIssues {
    param ($Diagnostics, $Patterns)

    $issues = @()

    # Check Service Status
    if ($Diagnostics.Service.Status -ne "Running") {
        $issues += @{
            Type = "Service"
            Component = "ArcAgent"
            Severity = "Critical"
            Description = "Arc agent service not running"
            Details = $Diagnostics.Service.Status
        }
    }

    # Check Connectivity
    foreach ($endpoint in $Diagnostics.Connectivity) {
        if (-not $endpoint.Success) {
            $issues += @{
                Type = "Connectivity"
                Component = "ArcAgent"
                Severity = "Critical"
                Description = "Cannot reach $($endpoint.Target)"
                Details = $endpoint.Error
            }
        }
    }

    return $issues
}

<#
.SYNOPSIS
Extracts AMA issues from diagnostics results.

.PARAMETER Diagnostics
AMA diagnostics payload to inspect.

.PARAMETER Patterns
Pattern definitions available to the analysis pass.
#>
function Find-AMAIssues {
    param ($Diagnostics, $Patterns)

    $issues = @()

    # Check AMA Service
    if ($Diagnostics.Service.Status -ne "Running") {
        $issues += @{
            Type = "Service"
            Component = "AMA"
            Severity = "Critical"
            Description = "AMA service not running"
            Details = $Diagnostics.Service.Status
        }
    }

    # Check Data Collection
    if ($Diagnostics.DataCollection.Status -ne "Active") {
        $issues += @{
            Type = "DataCollection"
            Component = "AMA"
            Severity = "Warning"
            Description = "Data collection inactive"
            Details = $Diagnostics.DataCollection.Details
        }
    }

    return $issues
}

function Find-CommonPatterns {
    <#
    .SYNOPSIS
        Identifies common patterns across multiple issues.
    #>
    param (
        [Parameter(Mandatory)]
        [array]$Issues
    )

    $patterns = @()

    if ($null -eq $Issues -or $Issues.Count -eq 0) {
        return $patterns
    }

    # Group issues by type
    $byType = $Issues | Group-Object -Property Type
    foreach ($group in $byType) {
        if ($group.Count -gt 1) {
            $patterns += @{
                PatternType = "RecurringIssueType"
                Type = $group.Name
                Count = $group.Count
                Severity = ($group.Group | ForEach-Object { $_.Severity } | Sort-Object -Unique)[0]
                Description = "Multiple $($group.Name) issues detected ($($group.Count) occurrences)"
            }
        }
    }

    # Group issues by component
    $byComponent = $Issues | Group-Object -Property Component
    foreach ($group in $byComponent) {
        if ($group.Count -gt 1) {
            $patterns += @{
                PatternType = "ComponentConcentration"
                Component = $group.Name
                Count = $group.Count
                Description = "Multiple issues in $($group.Name) component"
            }
        }
    }

    # Check for cascading failures
    $serviceIssues = $Issues | Where-Object { $_.Type -eq 'Service' }
    $connectivityIssues = $Issues | Where-Object { $_.Type -eq 'Connectivity' }
    if ($serviceIssues.Count -gt 0 -and $connectivityIssues.Count -gt 0) {
        $patterns += @{
            PatternType = "CascadingFailure"
            Description = "Service and connectivity issues suggest cascading failure"
            Severity = "Critical"
        }
    }

    return $patterns
}

function Get-IssueRecommendation {
    <#
    .SYNOPSIS
        Generates recommendations for identified issues.
    #>
    param (
        [Parameter(Mandatory)]
        [object]$Issue,

        [Parameter()]
        [object]$Patterns
    )

    $recommendation = @{
        IssueType = $Issue.Type
        Component = $Issue.Component
        Severity = $Issue.Severity
        Actions = @()
        Priority = switch ($Issue.Severity) {
            'Critical' { 1 }
            'High' { 2 }
            'Warning' { 3 }
            'Medium' { 3 }
            'Low' { 4 }
            default { 3 }
        }
    }

    # Generate recommendations based on issue type
    switch ($Issue.Type) {
        'Service' {
            $recommendation.Actions += "Check service status: Get-Service $($Issue.Component)"
            $recommendation.Actions += "Review Windows Event Log for errors"
            if ($Issue.Component -eq 'ArcAgent') {
                $recommendation.Actions += "Restart Arc agent: Restart-Service himds"
            }
            elseif ($Issue.Component -eq 'AMA') {
                $recommendation.Actions += "Restart AMA: Restart-Service AzureMonitorAgent"
            }
        }
        'Connectivity' {
            $recommendation.Actions += "Verify network connectivity to Azure endpoints"
            $recommendation.Actions += "Check proxy configuration"
            $recommendation.Actions += "Validate firewall rules for HTTPS (443)"
        }
        'Resource' {
            if ($Issue.Component -eq 'Memory') {
                $recommendation.Actions += "Identify high memory processes"
                $recommendation.Actions += "Consider increasing memory"
            }
            elseif ($Issue.Component -eq 'DiskSpace') {
                $recommendation.Actions += "Clean up temporary files"
                $recommendation.Actions += "Archive old data"
            }
        }
        'DataCollection' {
            $recommendation.Actions += "Verify Data Collection Rule configuration"
            $recommendation.Actions += "Check DCR association"
            $recommendation.Actions += "Validate workspace permissions"
        }
        'SystemRequirement' {
            $recommendation.Actions += "Review OS compatibility requirements"
            $recommendation.Actions += "Consider upgrading OS version"
        }
        default {
            $recommendation.Actions += "Review issue details and investigate"
            $recommendation.Actions += "Check relevant logs"
        }
    }

    return [PSCustomObject]$recommendation
}

function Measure-ImpactScore {
    <#
    .SYNOPSIS
        Measures impact score for an issue based on severity and patterns.
    #>
    param (
        [Parameter(Mandatory)]
        [object]$Issue,

        [Parameter()]
        [object]$Patterns
    )

    # Base score from severity
    $baseScore = switch ($Issue.Severity) {
        'Critical' { 100 }
        'High' { 75 }
        'Warning' { 50 }
        'Medium' { 50 }
        'Low' { 25 }
        'Information' { 10 }
        default { 25 }
    }

    # Component multiplier
    $componentMultiplier = switch ($Issue.Component) {
        'ArcAgent' { 1.5 }
        'AMA' { 1.3 }
        'OperatingSystem' { 1.4 }
        'Memory' { 1.2 }
        'DiskSpace' { 1.1 }
        default { 1.0 }
    }

    # Type multiplier
    $typeMultiplier = switch ($Issue.Type) {
        'Service' { 1.4 }
        'Connectivity' { 1.3 }
        'SystemRequirement' { 1.5 }
        'Resource' { 1.1 }
        'DataCollection' { 1.2 }
        default { 1.0 }
    }

    $score = [math]::Round($baseScore * $componentMultiplier * $typeMultiplier, 2)

    # Cap at 200
    return [math]::Min($score, 200)
}

function Test-OSCompatibility {
    <#
    .SYNOPSIS
        Tests if OS version is compatible with Azure Arc.
    #>
    param (
        [Parameter()]
        [string]$Version
    )

    if ([string]::IsNullOrEmpty($Version)) {
        return $false
    }

    # Extract major version
    if ($Version -match '^(\d+)\.') {
        $majorVersion = [int]$Matches[1]
        # Windows Server 2012 R2 (6.3) and later, or Windows 10 (10.0) and later
        return ($majorVersion -ge 10) -or ($majorVersion -eq 6 -and $Version -match '^6\.[23]')
    }

    return $false
}
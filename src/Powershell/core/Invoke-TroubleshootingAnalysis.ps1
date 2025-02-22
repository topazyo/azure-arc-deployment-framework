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

            # Calculate Impact Scores
            foreach ($issue in $analysisResults.Issues) {
                $issue.ImpactScore = Calculate-ImpactScore -Issue $issue -Patterns $patterns
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
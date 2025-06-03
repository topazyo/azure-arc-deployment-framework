# Calculate-ImpactScore.ps1
# This script calculates an impact score for an issue based on its properties and defined rules.
# TODO: Add more sophisticated adjustment factors or weighting in rules.

Function Calculate-ImpactScore {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$Issue, # Expected to have Type, Component, Severity properties

        [Parameter(Mandatory=$false)]
        [object]$ImpactRules, # Path to JSON file or direct PSCustomObject/Hashtable

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\CalculateImpactScore_Activity.log"
    )

    # --- Logging Function (for script activity) ---
    function Write-Log {
        param (
            [string]$Message,
            [string]$Level = "INFO", # INFO, WARNING, ERROR, DEBUG
            [string]$Path = $LogPath
        )
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$Level] $Message"

        try {
            if (-not (Test-Path (Split-Path $Path -Parent) -PathType Container)) {
                New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force -ErrorAction Stop | Out-Null
            }
            Add-Content -Path $Path -Value $logEntry -ErrorAction Stop
        }
        catch {
            Write-Warning "ACTIVITY_LOG_FAIL: Failed to write to activity log file $Path. Error: $($_.Exception.Message). Logging to console instead."
            Write-Host $logEntry
        }
    }

    Write-Log "Starting Calculate-ImpactScore for Issue: $($Issue | Out-String -Depth 1 -Width 100)."

    # --- Default values for issue properties if missing ---
    $issueType = if ($Issue.PSObject.Properties['Type']) { $Issue.Type } else { "Unknown" }
    $issueComponent = if ($Issue.PSObject.Properties['Component']) { $Issue.Component } else { "Generic" }
    $issueSeverity = if ($Issue.PSObject.Properties['Severity']) { $Issue.Severity } else { "Unknown" }

    if ($issueType -eq "Unknown" -or $issueComponent -eq "Generic" -or $issueSeverity -eq "Unknown") {
        Write-Log "Input Issue object was missing Type, Component, or Severity. Using defaults for calculation: Type='$issueType', Component='$issueComponent', Severity='$issueSeverity'." -Level "WARNING"
    }

    $loadedImpactRules = $null
    if ($ImpactRules) {
        if ($ImpactRules -is [string]) {
            $rulesPath = $ImpactRules
            Write-Log "Loading ImpactRules from path: $rulesPath"
            if (Test-Path $rulesPath -PathType Leaf) {
                try {
                    $loadedImpactRules = Get-Content -Path $rulesPath -Raw | ConvertFrom-Json -ErrorAction Stop
                    Write-Log "Successfully loaded ImpactRules from JSON."
                } catch {
                    Write-Log "Failed to load or parse ImpactRules JSON from '$rulesPath'. Error: $($_.Exception.Message)" -Level "ERROR"
                }
            } else { Write-Log "ImpactRules path not found: $rulesPath" -Level "ERROR" }
        } elseif (($ImpactRules -is [hashtable] -or $ImpactRules -is [pscustomobject]) -and $ImpactRules.impactScoring) {
            Write-Log "Using provided ImpactRules object."
            $loadedImpactRules = $ImpactRules.impactScoring # Expecting the "impactScoring" sub-object
        } elseif (($ImpactRules -is [hashtable] -or $ImpactRules -is [pscustomobject]) -and $ImpactRules.baseSeverityScores) { # Allow passing impactScoring object directly
             Write-Log "Using provided ImpactRules object (assumed to be impactScoring structure)."
             $loadedImpactRules = $ImpactRules
        }
        else {
            Write-Log "Invalid ImpactRules parameter type or structure: $($ImpactRules.GetType().FullName). Expected path, or object with 'impactScoring' or 'baseSeverityScores' property." -Level "ERROR"
        }
    }

    $baseScore = 0
    $componentMultiplier = 1.0
    $typeAdjustment = 0.0 # Additive adjustment
    $calculatedScore = 0
    $scoreComponents = @{}

    if ($loadedImpactRules) {
        Write-Log "Calculating score using loaded ImpactRules."
        $baseSeverityScores = $loadedImpactRules.baseSeverityScores
        $defaultScore = if ($loadedImpactRules.PSObject.Properties.Contains('defaultScore')) { $loadedImpactRules.defaultScore } else { 10 }

        if ($baseSeverityScores -and $baseSeverityScores.PSObject.Properties[$issueSeverity]) {
            $baseScore = $baseSeverityScores[$issueSeverity]
        } else {
            Write-Log "Severity '$issueSeverity' not found in baseSeverityScores. Using default score: $defaultScore." -Level "WARNING"
            $baseScore = $defaultScore
        }
        $scoreComponents.BaseScoreFromSeverity = $baseScore

        if ($loadedImpactRules.componentMultipliers -and $loadedImpactRules.componentMultipliers.PSObject.Properties[$issueComponent]) {
            $componentMultiplier = $loadedImpactRules.componentMultipliers[$issueComponent]
            Write-Log "Applying component multiplier for '$issueComponent': $componentMultiplier."
        } else { Write-Log "No component multiplier found for '$issueComponent'. Using default 1.0." }
        $scoreComponents.ComponentMultiplier = $componentMultiplier

        if ($loadedImpactRules.typeAdjustments -and $loadedImpactRules.typeAdjustments.PSObject.Properties[$issueType]) {
            $typeAdjustment = $loadedImpactRules.typeAdjustments[$issueType] # Assuming additive
            Write-Log "Applying type adjustment for '$issueType': $typeAdjustment."
        } else { Write-Log "No type adjustment found for '$issueType'. Using default 0.0."}
        $scoreComponents.TypeAdjustment = $typeAdjustment

        # Calculation: (Base * Multiplier) + Adjustment
        $calculatedScore = ($baseScore * $componentMultiplier) + $typeAdjustment

    } else {
        Write-Log "No ImpactRules provided or loaded. Using default hardcoded scoring logic."
        switch ($issueSeverity.ToLower()) {
            "critical" { $baseScore = 80 }
            "high"     { $baseScore = 60 }
            "medium"   { $baseScore = 40 }
            "warning"  { $baseScore = 40 } # Treat warning as medium
            "low"      { $baseScore = 20 }
            default    { $baseScore = 10 } # Informational or Unknown
        }
        $scoreComponents.BaseScoreFromSeverity = $baseScore
        Write-Log "Default base score for severity '$issueSeverity': $baseScore."

        # Simple default component multiplier example
        switch ($issueComponent.ToLower()) {
            "arcagent" { $componentMultiplier = 1.2 }
            "ama"      { $componentMultiplier = 1.1 }
            "os"       { $componentMultiplier = 1.15 } # OS level issues often broad
            "network"  { $componentMultiplier = 1.05 }
            default    { $componentMultiplier = 1.0 }
        }
        $scoreComponents.ComponentMultiplier = $componentMultiplier
        Write-Log "Default component multiplier for '$issueComponent': $componentMultiplier."

        # Simple default type adjustment example (additive)
         switch ($issueType.ToLower()) {
            "connectivity" { $typeAdjustment = 5 }
            "performance"  { $typeAdjustment = 2 }
            default        { $typeAdjustment = 0 }
        }
        $scoreComponents.TypeAdjustment = $typeAdjustment
        Write-Log "Default type adjustment for '$issueType': $typeAdjustment."

        $calculatedScore = ($baseScore * $componentMultiplier) + $typeAdjustment
    }

    # Clamp score to 0-100 range
    if ($calculatedScore -gt 100) { $calculatedScore = 100 }
    if ($calculatedScore -lt 0) { $calculatedScore = 0 }

    $scoreComponents.FinalCalculatedScore = $calculatedScore
    Write-Log "Calculated Impact Score for Issue Type '$issueType', Component '$issueComponent', Severity '$issueSeverity' is: $calculatedScore."

    $result = [PSCustomObject]@{
        IssueType             = $issueType
        IssueComponent        = $issueComponent
        IssueSeverity         = $issueSeverity
        CalculatedImpactScore = [math]::Round($calculatedScore, 2) # Round to 2 decimal places
        ScoreComponents       = $scoreComponents
        Timestamp             = (Get-Date -Format o)
    }

    Write-Log "Calculate-ImpactScore script finished."
    return $result
}

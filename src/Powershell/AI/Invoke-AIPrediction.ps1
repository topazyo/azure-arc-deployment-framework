function Invoke-AIPrediction {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject]$AIEngine,
        [Parameter(Mandatory)]
        [hashtable]$TelemetryData,
        [Parameter()]
        [string]$ModelType = "HealthPrediction",
        [Parameter()]
        [switch]$DetailedOutput
    )

    begin {
        $predictionResults = @{
            Timestamp = Get-Date
            ModelType = $ModelType
            Predictions = @()
            Confidence = 0.0
            Recommendations = @()
        }
    }

    process {
        try {
            # Validate AI Engine
            if ($AIEngine.Status -ne "Ready") {
                throw "AI Engine not ready. Current status: $($AIEngine.Status)"
            }

            # Prepare features for prediction
            $features = Convert-TelemetryToFeatures -TelemetryData $TelemetryData -ModelType $ModelType

            # Get prediction model
            $model = $AIEngine.Components.Prediction.Models[$ModelType]
            if (-not $model) {
                throw "Model not found for type: $ModelType"
            }

            # Generate predictions
            $prediction = Get-ModelPrediction -Features $features -Model $model
            $predictionResults.Predictions = $prediction.Results
            $predictionResults.Confidence = $prediction.Confidence

            # Generate feature importance analysis
            if ($DetailedOutput) {
                $predictionResults.FeatureImportance = Get-FeatureImportance -Features $features -Model $model
            }

            # Generate recommendations based on predictions
            $predictionResults.Recommendations = Get-PredictionRecommendations -Predictions $prediction -Model $model

            # Add risk assessment
            $predictionResults.RiskAssessment = Get-RiskAssessment -Predictions $prediction -Thresholds $model.Thresholds
        }
        catch {
            Write-Log -Message "AI prediction failed: $($_.Exception.Message)" -Level Error -Component 'Invoke-AIPrediction'
            Write-Verbose "Invoke-AIPrediction caught error: $($_.Exception.Message)"
            $predictionResults.Error = $_.Exception.Message
        }
    }

    end {
        return [PSCustomObject]$predictionResults
    }
}

function Convert-TelemetryToFeatures {
    param (
        [hashtable]$TelemetryData,
        [string]$ModelType
    )

    $features = @{}

    switch ($ModelType) {
        "HealthPrediction" {
            $features = @{
                CPUUsage = $TelemetryData.Performance.CPU.Average
                MemoryUsage = $TelemetryData.Performance.Memory.Average
                DiskSpace = $TelemetryData.Performance.Disk.FreeGB
                LastHeartbeat = (New-TimeSpan -Start $TelemetryData.LastHeartbeat -End (Get-Date)).TotalMinutes
                ErrorCount = $TelemetryData.Errors.Count
                WarningCount = $TelemetryData.Warnings.Count
                ConnectionStatus = if ($TelemetryData.Connected) { 1 } else { 0 }
            }
        }
        "FailurePrediction" {
            $features = @{
                ServiceFailures = $TelemetryData.ServiceFailures
                ConnectionDrops = $TelemetryData.ConnectionDrops
                HighCPUEvents = $TelemetryData.HighCPUEvents
                MemoryPressureEvents = $TelemetryData.MemoryPressureEvents
                DiskPressureEvents = $TelemetryData.DiskPressureEvents
                ConfigurationDrifts = $TelemetryData.ConfigurationDrifts
            }
        }
        default {
            throw "Unsupported model type: $ModelType"
        }
    }

    return $features
}

function Get-ModelPrediction {
    param (
        [hashtable]$Features,
        [hashtable]$Model
    )

    $prediction = @{
        Results = @()
        Confidence = 0.0
        Details = @{}
    }

    # Apply model parameters and thresholds
    $weightedScore = 0
    $totalWeight = 0

    foreach ($feature in $Features.Keys) {
        if ($Model.FeatureImportance.ContainsKey($feature)) {
            $weight = $Model.FeatureImportance[$feature]
            $normalizedValue = Normalize-FeatureValue -Value $Features[$feature] -Feature $feature
            $weightedScore += $normalizedValue * $weight
            $totalWeight += $weight

            $prediction.Details[$feature] = @{
                Value = $Features[$feature]
                NormalizedValue = $normalizedValue
                Weight = $weight
                Impact = $normalizedValue * $weight
            }
        }
    }

    $prediction.Results = $weightedScore / $totalWeight
    $prediction.Confidence = Calculate-PredictionConfidence -Details $prediction.Details

    return $prediction
}

function Get-PredictionRecommendations {
    param (
        [hashtable]$Predictions,
        [hashtable]$Model
    )

    $recommendations = @()

    # Generate recommendations based on prediction results and model thresholds
    foreach ($detail in $Predictions.Details.GetEnumerator()) {
        if ($detail.Value.Impact -gt $Model.Parameters.recommendationThreshold) {
            $recommendations += @{
                Feature = $detail.Key
                Impact = $detail.Value.Impact
                Severity = Get-ImpactSeverity -Impact $detail.Value.Impact
                Recommendation = Get-FeatureRecommendation -Feature $detail.Key -Value $detail.Value.Value
                Priority = Calculate-RecommendationPriority -Impact $detail.Value.Impact -Confidence $Predictions.Confidence
            }
        }
    }

    return $recommendations | Sort-Object -Property Priority -Descending
}

function Get-RiskAssessment {
    param (
        [hashtable]$Predictions,
        [hashtable]$Thresholds
    )

    $score = 0.0
    if ($Predictions -and $Predictions.ContainsKey('Results') -and $null -ne $Predictions.Results) {
        $rawScore = $Predictions.Results

        if ($rawScore -is [System.Array] -or ($rawScore -is [System.Collections.IEnumerable] -and -not ($rawScore -is [string]))) {
            $numericScore = $rawScore |
                Where-Object { $_ -is [ValueType] -or $_ -is [string] } |
                ForEach-Object {
                    try {
                        [double]$_
                    }
                    catch {
                        Write-Verbose "Ignoring non-numeric prediction result value '$($_)'."
                    }
                } |
                Select-Object -First 1

            if ($null -ne $numericScore) {
                $score = [double]$numericScore
            }
        }
        else {
            try {
                $score = [double]$rawScore
            }
            catch {
                $score = 0.0
            }
        }
    }

    $warningThreshold = 0.5
    $criticalThreshold = 0.8

    if ($Thresholds) {
        if ($Thresholds.ContainsKey('warning') -and $null -ne $Thresholds.warning) {
            $warningThreshold = [double]$Thresholds.warning
        }
        if ($Thresholds.ContainsKey('critical') -and $null -ne $Thresholds.critical) {
            $criticalThreshold = [double]$Thresholds.critical
        }
    }

    $level = if ($score -ge $criticalThreshold) {
        'Critical'
    }
    elseif ($score -ge $warningThreshold) {
        'Warning'
    }
    else {
        'Low'
    }

    return [PSCustomObject]@{
        Score = $score
        Level = $level
        Thresholds = [PSCustomObject]@{
            Warning = $warningThreshold
            Critical = $criticalThreshold
        }
    }
}
<#
.SYNOPSIS
Runs the AI learning and model update workflow.

.DESCRIPTION
Loads training data, updates the pattern-recognition, prediction, and anomaly
detection components, calculates aggregate learning metrics, and saves updated
models when improvement is recorded.

.PARAMETER AIEngine
Initialized AI engine object containing the components to update.

.PARAMETER TrainingDataPath
Path to the training data input directory.

.PARAMETER ModelOutputPath
Path used when saving updated model artifacts.

.PARAMETER ForceTrain
Forces prediction model retraining where supported by the implementation.

.OUTPUTS
PSCustomObject

.EXAMPLE
Start-AILearning -AIEngine $engine -TrainingDataPath '.\Data\Training' -ModelOutputPath '.\Models'
#>
function Start-AILearning {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [PSCustomObject]$AIEngine,
        [Parameter()]
        [string]$TrainingDataPath = ".\Data\Training",
        [Parameter()]
        [string]$ModelOutputPath = ".\Models",
        [Parameter()]
        [switch]$ForceTrain
    )

    begin {
        $learningResults = @{
            StartTime = Get-Date
            Status = "Starting"
            ModelUpdates = @()
            Metrics = @{}
        }
    }

    process {
        try {
            # Load training data
            $trainingData = Import-TrainingData -Path $TrainingDataPath

            # Update pattern recognition
            $patternUpdate = Update-PatternRecognition `
                -Engine $AIEngine.Components.PatternRecognition `
                -TrainingData $trainingData.Patterns
            $learningResults.ModelUpdates += @{
                Component = "PatternRecognition"
                Status = $patternUpdate.Status
                Metrics = $patternUpdate.Metrics
            }

            # Update prediction models
            $predictionUpdate = Update-PredictionModels `
                -Engine $AIEngine.Components.Prediction `
                -TrainingData $trainingData.Predictions `
                -ForceTrain:$ForceTrain
            $learningResults.ModelUpdates += @{
                Component = "Prediction"
                Status = $predictionUpdate.Status
                Metrics = $predictionUpdate.Metrics
            }

            # Update anomaly detection
            $anomalyUpdate = Update-AnomalyDetection `
                -Engine $AIEngine.Components.AnomalyDetection `
                -TrainingData $trainingData.Anomalies
            $learningResults.ModelUpdates += @{
                Component = "AnomalyDetection"
                Status = $anomalyUpdate.Status
                Metrics = $anomalyUpdate.Metrics
            }

            # Calculate overall metrics
            $learningResults.Metrics = Calculate-LearningMetrics -Updates $learningResults.ModelUpdates

            # Save updated models
            if ($learningResults.Metrics.Improvement -gt 0 -and $PSCmdlet.ShouldProcess($ModelOutputPath, 'Save updated AI models')) {
                Save-MLModels -Models $AIEngine.Models -Path $ModelOutputPath
            }

            $learningResults.Status = "Completed"
        }
        catch {
            $learningResults.Status = "Failed"
            $learningResults.Error = $_.Exception.Message
            Write-Log -Message "AI learning failed: $($_.Exception.Message)" -Level Error -Component 'Start-AILearning'
            Write-Error -ErrorRecord $_
        }
    }

    end {
        $learningResults.EndTime = Get-Date
        return [PSCustomObject]$learningResults
    }
}
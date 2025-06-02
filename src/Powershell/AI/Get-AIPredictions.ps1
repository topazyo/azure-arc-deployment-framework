# Get-AIPredictions.ps1
# This script uses a loaded AI model to generate predictions based on input features.
# TODO: Enhance ONNX input preparation to be more configurable (input names, shapes, types from model metadata or params).
# TODO: Develop more concrete examples or interfaces for 'CustomPSObject' models.

Function Get-AIPredictions {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [object[]]$InputFeatures,

        [Parameter(Mandatory=$true)]
        [object]$ModelObject,

        [Parameter(Mandatory=$true)]
        [ValidateSet('ONNX', 'CustomPSObject', 'RuleBasedPlaceholder')] # Added RuleBasedPlaceholder for clarity
        [string]$ModelType,

        [Parameter(Mandatory=$false)]
        [string]$PredictionType = 'Classification', # Hint for interpreting output, not heavily used in this version

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\GetAIPredictions_Activity.log"
    )

    # --- Logging Function (for script activity) ---
    function Write-Log {
        param (
            [string]$Message,
            [string]$Level = "INFO", # INFO, WARNING, ERROR
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

    Write-Log "Starting Get-AIPredictions script. InputFeatures count: $($InputFeatures.Count), ModelType: $ModelType."

    if (-not $ModelObject) {
        Write-Log "ModelObject is null. Cannot proceed with predictions." -Level "ERROR"
        # Return an array of error objects matching the expected output structure
        return $InputFeatures | ForEach-Object {
            [PSCustomObject]@{
                InputItemFeatures = $_
                Prediction = $null
                Probability = $null
                ModelUsedType = $ModelType
                Status = "Error"
                ErrorDetails = "ModelObject was null."
            }
        }
    }

    $allPredictions = [System.Collections.ArrayList]::new()

    foreach ($featureVectorItem in $InputFeatures) {
        $currentPredictionResult = [PSCustomObject]@{
            InputItemFeatures = $featureVectorItem
            Prediction = $null
            Probability = $null # Or other confidence score
            ModelUsedType = $ModelType
            Status = "Pending"
            ErrorDetails = $null
        }

        try {
            Write-Log "Processing feature vector: $($featureVectorItem | Out-String -Width 200)" -Level "DEBUG"

            switch ($ModelType) {
                'ONNX' {
                    Write-Log "Attempting prediction with ONNX model."
                    if (-not ($ModelObject -is [Microsoft.ML.OnnxRuntime.InferenceSession])) {
                        $currentPredictionResult.Status = "Error"
                        $currentPredictionResult.ErrorDetails = "ModelObject is not a valid ONNX InferenceSession. Type: $($ModelObject.GetType().FullName)"
                        Write-Log $currentPredictionResult.ErrorDetails -Level "ERROR"
                        $allPredictions.Add($currentPredictionResult) | Out-Null
                        continue # Next featureVectorItem
                    }

                    # --- ONNX Input Preparation (Simplified Best-Effort) ---
                    # 1. Extract numerical features and order them by name for consistency
                    $numericalFeatureValues = [System.Collections.Generic.List[float]]::new()
                    $featureVectorItem.PSObject.Properties | Where-Object { $_.Value -is [int] -or $_.Value -is [double] -or $_.Value -is [float] -or $_.Value -is [long] } | Sort-Object Name | ForEach-Object {
                        $numericalFeatureValues.Add([float]$_.Value)
                    }

                    if ($numericalFeatureValues.Count -eq 0) {
                        $currentPredictionResult.Status = "Error"
                        $currentPredictionResult.ErrorDetails = "No numerical features found in InputFeatures item for ONNX model. ONNX model requires numerical input."
                        Write-Log $currentPredictionResult.ErrorDetails -Level "ERROR"
                        $allPredictions.Add($currentPredictionResult) | Out-Null
                        continue 
                    }
                    
                    Write-Log "Extracted $($numericalFeatureValues.Count) numerical features for ONNX input." -Level "DEBUG"
                    Write-Log "ONNX Input Preparation Warning: This script uses a simplified approach. Input tensor name, shape, type, and feature order must align with the specific ONNX model requirements." -Level "WARNING"

                    # 2. Determine input node name (heuristic: use the first one)
                    $inputNodeName = $ModelObject.InputMetadata.Keys[0]
                    if ([string]::IsNullOrWhiteSpace($inputNodeName)) {
                        $currentPredictionResult.Status = "Error"
                        $currentPredictionResult.ErrorDetails = "Could not determine input node name from ONNX model metadata."
                        Write-Log $currentPredictionResult.ErrorDetails -Level "ERROR"
                        $allPredictions.Add($currentPredictionResult) | Out-Null
                        continue
                    }
                    Write-Log "Using ONNX input node name: $inputNodeName (heuristic)" -Level "DEBUG"

                    # 3. Define shape (heuristic: [1, number of features])
                    $shape = [long[]](1, $numericalFeatureValues.Count)
                    
                    # 4. Create DenseTensor
                    $inputTensor = New-Object Microsoft.ML.OnnxRuntime.DenseTensor[float]($numericalFeatureValues.ToArray(), $shape)
                    
                    # 5. Create NamedOnnxValue
                    $onnxInputs = [System.Collections.Generic.List[Microsoft.ML.OnnxRuntime.NamedOnnxValue]]::new()
                    $onnxInputs.Add([Microsoft.ML.OnnxRuntime.NamedOnnxValue]::CreateFromTensor($inputNodeName, $inputTensor))

                    # 6. Run Inference
                    Write-Log "Running ONNX inference..."
                    $results = $ModelObject.Run($onnxInputs) # This returns IDisposableReadOnlyCollection<DisposableNamedOnnxValue>
                    
                    # 7. Process Output Tensor (highly model-specific)
                    # Assuming the first output tensor contains the prediction.
                    # And assuming it's a classification model where output can be interpreted.
                    $outputValue = $results[0] # This is a DisposableNamedOnnxValue
                    
                    # Example for classification: output might be probabilities or a class label.
                    # This part is extremely model dependent.
                    if ($outputValue.ValueType -eq "Tensor") {
                        if ($outputValue.ElementType -eq "System.Single") { # float
                             $predictionArray = $outputValue.AsTensor[float]().ToArray()
                             # For classification, this might be an array of probabilities for each class.
                             # Find the index of the max probability.
                             $maxProb = $predictionArray | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
                             $predictedClassIndex = [array]::IndexOf($predictionArray, $maxProb)
                             $currentPredictionResult.Prediction = "Class_$predictedClassIndex" # Example output
                             $currentPredictionResult.Probability = $maxProb
                        } elseif ($outputValue.ElementType -eq "System.Int64") { # int64 for class labels
                             $predictionArray = $outputValue.AsTensor[long]().ToArray()
                             $currentPredictionResult.Prediction = "Class_$($predictionArray[0])" # Assuming direct class label
                             $currentPredictionResult.Probability = 1.0 # If direct label, confidence might be assumed or not applicable
                        } else {
                             $currentPredictionResult.Prediction = "Output tensor type $($outputValue.ElementType) not processed by this script."
                             Write-Log $currentPredictionResult.Prediction -Level "WARNING"
                        }
                    } else {
                         $currentPredictionResult.Prediction = "Output value type $($outputValue.ValueType) not processed."
                         Write-Log $currentPredictionResult.Prediction -Level "WARNING"
                    }

                    $currentPredictionResult.Status = "Success"
                    Write-Log "ONNX prediction successful."
                    $results.Dispose() # Dispose of the results collection
                }
                'CustomPSObject' {
                    Write-Log "Attempting prediction with CustomPSObject model."
                    if ($ModelObject.PSObject.Methods['Predict']) {
                        Write-Log "Calling Predict() method on CustomPSObject model."
                        $predictionOutput = $ModelObject.Predict($featureVectorItem)
                        # Assume predictionOutput is a simple value or a hashtable with 'Prediction' and 'Probability'
                        if ($predictionOutput -is [hashtable] -and $predictionOutput.ContainsKey('Prediction')) {
                            $currentPredictionResult.Prediction = $predictionOutput.Prediction
                            if ($predictionOutput.ContainsKey('Probability')) {
                                $currentPredictionResult.Probability = $predictionOutput.Probability
                            }
                        } else {
                            $currentPredictionResult.Prediction = $predictionOutput
                        }
                        $currentPredictionResult.Status = "Success"
                    } else {
                        $currentPredictionResult.Status = "Error"
                        $currentPredictionResult.ErrorDetails = "CustomPSObject model does not have a 'Predict()' method."
                        Write-Log $currentPredictionResult.ErrorDetails -Level "WARNING"
                        $currentPredictionResult.Prediction = "No Predict() method on model"
                    }
                }
                'RuleBasedPlaceholder' { # Example, if Import-AIModel returned a set of rules
                    Write-Log "Attempting prediction with RuleBasedPlaceholder model."
                    $matchedRulePrediction = "NoRuleMatched"
                    if ($ModelObject -is [array]) { # Assuming rules are an array
                        foreach($rule in $ModelObject) {
                            if ($rule.Condition.Invoke($featureVectorItem)) { # Rule condition is a scriptblock
                                $matchedRulePrediction = $rule.Prediction
                                break
                            }
                        }
                    }
                    $currentPredictionResult.Prediction = $matchedRulePrediction
                    $currentPredictionResult.Status = "Success"
                }
                default {
                    $currentPredictionResult.Status = "Error"
                    $currentPredictionResult.ErrorDetails = "ModelType '$ModelType' is not supported for prediction by this script."
                    Write-Log $currentPredictionResult.ErrorDetails -Level "ERROR"
                }
            }
        } catch {
            $currentPredictionResult.Status = "Error"
            $currentPredictionResult.ErrorDetails = "Exception during prediction: $($_.Exception.Message)"
            Write-Log $currentPredictionResult.ErrorDetails -Level "ERROR"
            Write-Log "Stack Trace for error: $($_.ScriptStackTrace)" -Level "DEBUG"
        }
        finally {
            $allPredictions.Add($currentPredictionResult) | Out-Null
        }
    }

    Write-Log "Get-AIPredictions script finished. Processed $($InputFeatures.Count) items."
    return $allPredictions
}

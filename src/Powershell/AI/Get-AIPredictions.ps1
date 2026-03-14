<#
.SYNOPSIS
Generates predictions from engineered features using a loaded model.

.DESCRIPTION
Supports ONNX, custom PowerShell object, and rule-based placeholder model types.
The function orders input features as needed, executes model inference, and returns
prediction objects along with activity-log output.

.PARAMETER InputFeatures
Engineered feature objects to submit for prediction.

.PARAMETER ModelObject
Loaded model object used for inference.

.PARAMETER ModelType
Model implementation type.

.PARAMETER PredictionType
Hint for interpreting the output, such as classification or regression.

.PARAMETER OnnxInputName
Optional ONNX input node name override.

.PARAMETER OnnxFeatureOrder
Optional ordered feature list for ONNX inference.

.PARAMETER FeatureSchema
Optional schema with default values for missing features.

.PARAMETER ClassLabels
Optional class labels for classification outputs.

.PARAMETER LogPath
Activity log path for inference steps.

.OUTPUTS
PSCustomObject[]

.EXAMPLE
Get-AIPredictions -InputFeatures $features -ModelObject $model -ModelType CustomPSObject -PredictionType Classification

.NOTES
Missing features default to `0.0` in several inference paths, matching the broader
predictive contract used in this repository.
#>

Function Get-AIPredictions {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [object[]]$InputFeatures,

        [Parameter(Mandatory=$false)]
        [object]$ModelObject,

        [Parameter(Mandatory=$true)]
        [ValidateSet('ONNX', 'CustomPSObject', 'RuleBasedPlaceholder')] # Added RuleBasedPlaceholder for clarity
        [string]$ModelType,

        [Parameter(Mandatory=$false)]
        [string]$PredictionType = 'Classification', # Hint for interpreting output, not heavily used in this version

        [Parameter(Mandatory=$false)]
        [string]$OnnxInputName,

        [Parameter(Mandatory=$false)]
        [string[]]$OnnxFeatureOrder,

        [Parameter(Mandatory=$false)]
        [hashtable]$FeatureSchema,

        [Parameter(Mandatory=$false)]
        [string[]]$ClassLabels,

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\GetAIPredictions_Activity.log"
    )

    # --- Logging Function (for script activity) ---
    function Write-ActivityLog {
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
            Write-Verbose $logEntry
        }
    }

    Write-ActivityLog "Starting Get-AIPredictions script. InputFeatures count: $($InputFeatures.Count), ModelType: $ModelType."

    function Get-OrderedFeatureValues {
        param(
            [Parameter(Mandatory=$true)] [object]$Item,
            [Parameter(Mandatory=$true)] [string[]]$Order,
            [Parameter()] [hashtable]$Schema,
            [Parameter(Mandatory=$true)] [ref]$Missing
        )

        $values = [System.Collections.Generic.List[float]]::new()
        foreach ($name in $Order) {
            $raw = $null
            if ($Item.PSObject.Properties[$name]) {
                $raw = $Item.$name
            } elseif ($Schema -and $Schema[$name] -and $Schema[$name].ContainsKey('default')) {
                $raw = $Schema[$name].default
            }

            if ($null -eq $raw -or $raw -eq '') {
                $Missing.Value.Add($name) | Out-Null
                $values.Add(0.0) | Out-Null
                continue
            }

            try {
                $values.Add([float]$raw) | Out-Null
            } catch {
                $Missing.Value.Add($name) | Out-Null
                $values.Add(0.0) | Out-Null
            }
        }

        return $values.ToArray()
    }

    if (-not $ModelObject) {
        Write-ActivityLog "ModelObject is null. Cannot proceed with predictions." -Level "ERROR"
        # Return an array of error objects matching the expected output structure
        return $InputFeatures | ForEach-Object {
            [PSCustomObject]@{
                InputItemFeatures = $_
                PredictedClass = 'Error'
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
            Write-ActivityLog "Processing feature vector: $($featureVectorItem | Out-String -Width 200)" -Level "DEBUG"

            switch ($ModelType) {
                'ONNX' {
                    Write-ActivityLog "Attempting prediction with ONNX model."
                    $onnxSessionType = [type]::GetType('Microsoft.ML.OnnxRuntime.InferenceSession')
                    $supportsOnnx = ($onnxSessionType -and ($ModelObject -is $onnxSessionType)) -or ($ModelObject.PSObject.Methods.Name -contains 'Run' -and $ModelObject.PSObject.Properties.Name -contains 'InputMetadata')
                    if (-not $supportsOnnx) {
                        $currentPredictionResult.Status = "Error"
                        $currentPredictionResult.ErrorDetails = "ModelObject is not an ONNX-compatible session (missing Run/InputMetadata). Type: $($ModelObject.GetType().FullName)"
                        Write-ActivityLog $currentPredictionResult.ErrorDetails -Level "ERROR"
                        $allPredictions.Add($currentPredictionResult) | Out-Null
                        continue # Next featureVectorItem
                    }

                    # --- ONNX Input Preparation (configurable) ---
                    # 1. Resolve feature order using override -> schema -> model metadata -> alphabetical properties
                    $inferredOrder = @()
                    if ($OnnxFeatureOrder -and $OnnxFeatureOrder.Count -gt 0) {
                        $inferredOrder = $OnnxFeatureOrder
                    } elseif ($FeatureSchema) {
                        $inferredOrder = $FeatureSchema.Keys
                    } elseif ($ModelObject.PSObject.Properties['InputMetadata'] -and $ModelObject.InputMetadata.Keys.Count -gt 0) {
                        $inferredOrder = $ModelObject.InputMetadata.Keys
                    } else {
                        $inferredOrder = $featureVectorItem.PSObject.Properties.Name | Sort-Object
                    }

                    $missingNames = [System.Collections.Generic.List[string]]::new()
                    $numericalFeatureValues = Get-OrderedFeatureValues -Item $featureVectorItem -Order $inferredOrder -Schema $FeatureSchema -Missing ([ref]$missingNames)

                    if ($numericalFeatureValues.Count -eq 0) {
                        $currentPredictionResult.Status = "Error"
                        $currentPredictionResult.ErrorDetails = "No numerical features found in InputFeatures item for ONNX model. ONNX model requires numerical input."
                        Write-ActivityLog $currentPredictionResult.ErrorDetails -Level "ERROR"
                        $allPredictions.Add($currentPredictionResult) | Out-Null
                        continue
                    }

                    if ($missingNames.Count -gt 0) {
                        Write-ActivityLog "Missing or defaulted feature values: $($missingNames -join ', ')" -Level "WARNING"
                    }

                    Write-ActivityLog "Extracted $($numericalFeatureValues.Count) numerical features for ONNX input in order: $($inferredOrder -join ', ')." -Level "DEBUG"
                    Write-ActivityLog "ONNX Input Preparation Warning: This script uses a simplified approach. Input tensor name, shape, type, and feature order must align with the specific ONNX model requirements." -Level "WARNING"

                    # 2. Determine input node name (overrideable)
                    $inputNodeName = if (-not [string]::IsNullOrWhiteSpace($OnnxInputName)) { $OnnxInputName } elseif ($ModelObject.PSObject.Properties['InputMetadata'] -and $ModelObject.InputMetadata.Keys.Count -gt 0) { $ModelObject.InputMetadata.Keys[0] } else { $null }
                    if ([string]::IsNullOrWhiteSpace($inputNodeName)) {
                        $currentPredictionResult.Status = "Error"
                        $currentPredictionResult.ErrorDetails = "Could not determine input node name from ONNX model metadata."
                        Write-ActivityLog $currentPredictionResult.ErrorDetails -Level "ERROR"
                        $allPredictions.Add($currentPredictionResult) | Out-Null
                        continue
                    }
                    Write-ActivityLog "Using ONNX input node name: $inputNodeName (heuristic)" -Level "DEBUG"

                    # 3. Define shape (heuristic: [1, number of features])
                    $shape = [long[]](1, $numericalFeatureValues.Count)

                    # 4. Create DenseTensor (fallback to raw array if OnnxRuntime not available)
                    $inputTensor = $numericalFeatureValues
                    try {
                        $denseType = [type]::GetType('Microsoft.ML.OnnxRuntime.DenseTensor`1[[System.Single]]')
                        if ($denseType) {
                            $inputTensor = New-Object Microsoft.ML.OnnxRuntime.DenseTensor[float]($numericalFeatureValues, $shape)
                        } else {
                            Write-ActivityLog "DenseTensor type not available; using raw float array." -Level "WARNING"
                        }
                    } catch {
                        Write-ActivityLog "Failed to construct DenseTensor; using raw float array. Error: $($_.Exception.Message)" -Level "WARNING"
                        $inputTensor = $numericalFeatureValues
                    }

                    # 5. Create NamedOnnxValue (fallback to lightweight payload if type missing)
                    $onnxInputs = [System.Collections.Generic.List[object]]::new()
                    try {
                        $namedType = [type]::GetType('Microsoft.ML.OnnxRuntime.NamedOnnxValue')
                        if ($namedType) {
                            $onnxInputs.Add([Microsoft.ML.OnnxRuntime.NamedOnnxValue]::CreateFromTensor($inputNodeName, $inputTensor))
                        } else {
                            $onnxInputs.Add([pscustomobject]@{ Name = $inputNodeName; Tensor = $inputTensor })
                            Write-ActivityLog "NamedOnnxValue type not available; using simplified input payload." -Level "WARNING"
                        }
                    } catch {
                        $onnxInputs.Add([pscustomobject]@{ Name = $inputNodeName; Tensor = $inputTensor })
                        Write-ActivityLog "Failed to construct NamedOnnxValue; using simplified input payload. Error: $($_.Exception.Message)" -Level "WARNING"
                    }

                    # 6. Run Inference
                    Write-ActivityLog "Running ONNX inference..."
                    $results = $ModelObject.Run($onnxInputs) # This returns IDisposableReadOnlyCollection<DisposableNamedOnnxValue> or a compatible object

                    # 7. Process Output Tensor (highly model-specific)
                    # Assuming the first output tensor contains the prediction.
                    # And assuming it's a classification model where output can be interpreted.
                    $outputValue = $results[0] # This is a DisposableNamedOnnxValue

                    # Example for classification: output might be probabilities or a class label.
                    # This part is extremely model dependent.
                    $predictionArray = $null
                    if ($outputValue.PSObject.Methods.Name -contains 'AsTensor') {
                        try {
                            $tensor = $outputValue.AsTensor()
                            if ($tensor -is [System.Array]) {
                                $predictionArray = [float[]]$tensor
                            } elseif ($tensor -is [System.Collections.IEnumerable]) {
                                $predictionArray = @($tensor)
                            }
                        } catch {
                            Write-ActivityLog "AsTensor invocation failed: $($_.Exception.Message)" -Level "WARNING"
                        }
                    }

                    if (-not $predictionArray -and $outputValue.PSObject.Properties['Data']) {
                        $predictionArray = [float[]]$outputValue.Data
                    }

                    if (-not $predictionArray -and $outputValue.ValueType -eq "Tensor" -and $outputValue.ElementType -eq "System.Int64") {
                        try { $predictionArray = [long[]]$outputValue.AsTensor() } catch { Write-Verbose "Failed to coerce ONNX Int64 tensor output to a long array: $($_.Exception.Message)" }
                    }

                    if ($predictionArray -and $predictionArray.Count -gt 0) {
                        $maxProb = [double]($predictionArray | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum)
                        $predictedClassIndex = 0
                        for ($index = 0; $index -lt $predictionArray.Count; $index++) {
                            if ([double]$predictionArray[$index] -eq $maxProb) {
                                $predictedClassIndex = $index
                                break
                            }
                        }
                        $predictedLabel = if ($ClassLabels -and $ClassLabels.Count -gt $predictedClassIndex -and $ClassLabels[$predictedClassIndex]) { $ClassLabels[$predictedClassIndex] } else { "Class_$predictedClassIndex" }
                        $currentPredictionResult.Prediction = $predictedLabel
                        $currentPredictionResult.Probability = $maxProb
                    } else {
                        $currentPredictionResult.Prediction = "Output could not be interpreted as a tensor."
                        Write-ActivityLog $currentPredictionResult.Prediction -Level "WARNING"
                    }

                    $currentPredictionResult.Status = "Success"
                    Write-ActivityLog "ONNX prediction successful."
                    if ($results -and $results.PSObject.Methods.Name -contains 'Dispose') {
                        $results.Dispose() # Dispose of the results collection when supported
                    }
                }
                'CustomPSObject' {
                    Write-ActivityLog "Attempting prediction with CustomPSObject model."
                    if ($ModelObject.PSObject.Methods['Predict']) {
                        Write-ActivityLog "Calling Predict() method on CustomPSObject model."
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
                        Write-ActivityLog $currentPredictionResult.ErrorDetails -Level "WARNING"
                        $currentPredictionResult.Prediction = "No Predict() method on model"
                    }
                }
                'RuleBasedPlaceholder' { # Example, if Import-AIModel returned a set of rules
                    Write-ActivityLog "Attempting prediction with RuleBasedPlaceholder model."
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
                    Write-ActivityLog $currentPredictionResult.ErrorDetails -Level "ERROR"
                }
            }
        } catch {
            $currentPredictionResult.Status = "Error"
            $currentPredictionResult.ErrorDetails = "Exception during prediction: $($_.Exception.Message)"
            Write-ActivityLog $currentPredictionResult.ErrorDetails -Level "ERROR"
            Write-ActivityLog "Stack Trace for error: $($_.ScriptStackTrace)" -Level "DEBUG"
        }
        finally {
            $allPredictions.Add($currentPredictionResult) | Out-Null
        }
    }

    Write-ActivityLog "Get-AIPredictions script finished. Processed $($InputFeatures.Count) items."
    return $allPredictions
}

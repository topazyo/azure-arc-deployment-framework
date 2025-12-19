# Start-AIRemediationWorkflow.ps1
# This script orchestrates an AI-driven diagnostic and remediation workflow.
# TODO: Implement actual remediation action execution and verification steps.
# TODO: Add more robust error handling and decision logic based on script outputs.

Function Start-AIRemediationWorkflow {
    [CmdletBinding(SupportsShouldProcess = $true)] # Added SupportsShouldProcess for -WhatIf on actions
    param (
        [Parameter(Mandatory=$true)]
        [object[]]$InputData,

        [Parameter(Mandatory=$false)]
        [string]$AIModelNameOrPath,

        [Parameter(Mandatory=$false)]
        [string]$AIModelType, # e.g., 'ONNX', 'CustomPSObject'

        [Parameter(Mandatory=$false)]
        [string]$FeatureDefinitionPath,

        [Parameter(Mandatory=$false)]
        [string]$RecommendationRulesPath,

        [Parameter(Mandatory=$false)]
        [double]$PredictionConfidenceThreshold = 0.5,

        [Parameter(Mandatory=$false)]
        [ValidateSet('Assisted', 'Automatic')]
        [string]$RemediationMode = 'Assisted',

        [Parameter(Mandatory=$false)]
        [string]$ValidationRulesPath,

        [Parameter(Mandatory=$false)]
        [string]$IssuePatternDefinitionsPath,

        [Parameter(Mandatory=$false)]
        [string]$RemediationRulesPath,

        [Parameter(Mandatory=$false)]
        [string]$ScriptRootOverride,

        [Parameter(Mandatory=$false)]
        [string]$ConvertToAIFeaturesPath,

        [Parameter(Mandatory=$false)]
        [string]$GetAIRecommendationsPath,

        [Parameter(Mandatory=$false)]
        [string]$FindIssuePatternsPath,

        [Parameter(Mandatory=$false)]
        [string]$GetRemediationActionPath,

        [Parameter(Mandatory=$false)]
        [string]$StartRemediationActionPath,

        [Parameter(Mandatory=$false)]
        [string]$GetValidationStepPath,

        [Parameter(Mandatory=$false)]
        [string]$TestRemediationResultPath,

        [Parameter(Mandatory=$false)]
        [string]$ServerName,

        [Parameter(Mandatory=$false)]
        [switch]$EnableRemediationTelemetry,

        [Parameter(Mandatory=$false)]
        [string]$PythonExecutable = "python",

        [Parameter(Mandatory=$false)]
        [string]$AIEngineScriptPath,

        [Parameter(Mandatory=$false)]
        [string]$AIModelDirectory,

        [Parameter(Mandatory=$false)]
        [string]$AIConfigPath,

        [Parameter(Mandatory=$false)]
        [string]$RetrainExportPath,

        [Parameter(Mandatory=$false)]
        [switch]$ConsumeRetrainQueue,

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\StartAIRemediationWorkflow_Activity.log"
    )

    # --- Logging Function (for script activity) ---
    function Write-Log {
        param (
            [string]$Message,
                [Parameter(Mandatory=$false)]
                [string]$IssuePatternDefinitionsPath,

                [Parameter(Mandatory=$false)]
                [string]$RemediationRulesPath,
            [string]$Level = "INFO", # INFO, WARNING, ERROR, DEBUG
            [string]$Path = $LogPath
        )
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$Level] $Message"
        $targetPath = if (-not [string]::IsNullOrWhiteSpace($Path)) { $Path } elseif (-not [string]::IsNullOrWhiteSpace($LogPath)) { $LogPath } else { $null }
        
        try {
            if (-not $targetPath) { Write-Host $logEntry; return }

            if ($WhatIfPreference) { Write-Host $logEntry; return }

            $parentPath = Split-Path $targetPath -Parent
            if (-not (Test-Path $parentPath -PathType Container)) {
                New-Item -ItemType Directory -Path $parentPath -Force -ErrorAction Stop | Out-Null
            }
            Add-Content -Path $targetPath -Value $logEntry -ErrorAction Stop
        }
        catch {
            Write-Warning "ACTIVITY_LOG_FAIL: Failed to write to activity log file $Path. Error: $($_.Exception.Message). Logging to console instead."
            Write-Host $logEntry 
        }
    }

    function Invoke-RemediationOutcomeTelemetry {
        param(
            [Parameter(Mandatory = $true)][hashtable]$Payload,
            [Parameter(Mandatory = $true)][string]$ServerNameResolved
        )

        if (-not $EnableRemediationTelemetry) { return $null }

        if ($env:ARC_AI_FORCE_MOCKS -eq '1') {
            return [pscustomobject]@{
                status = 'mocked'
                reason = 'ARC_AI_FORCE_MOCKS'
                pending_retrain_requests = @()
                payload_echo = $Payload
            }
        }

        $enginePath = $AIEngineScriptPath
        if (-not $enginePath) {
            $basePath = $PSScriptRoot
            $enginePath = Join-Path $basePath "../../Python/invoke_ai_engine.py"
            $enginePath = [System.IO.Path]::GetFullPath($enginePath)
        }

        if (-not (Test-Path $enginePath -PathType Leaf)) {
            Write-Log "Remediation telemetry skipped; invoke_ai_engine.py not found at '$enginePath'." -Level "WARNING"
            return $null
        }

        $pythonPath = $PythonExecutable
        if (-not $pythonPath) { $pythonPath = "python" }

        $payloadJson = $null
        try {
            $payloadJson = $Payload | ConvertTo-Json -Depth 8 -Compress
        } catch {
            Write-Log "Failed to serialize remediation payload for telemetry: $($_.Exception.Message)" -Level "WARNING"
            return $null
        }

        $stdOutPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "ai-remediation-out-$([guid]::NewGuid()).json")
        $stdErrPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "ai-remediation-err-$([guid]::NewGuid()).log")

        $arguments = @(
            "`"$enginePath`"",
            "-u",
            "--servername", "`"$ServerNameResolved`"",
            "--analysistype", "`"Full`"",
            "--remediationoutcomejson", "`"$payloadJson`""
        )

        if ($AIModelDirectory) { $arguments += @("--modeldir", "`"$AIModelDirectory`"") }
        if ($AIConfigPath) { $arguments += @("--configpath", "`"$AIConfigPath`"") }
        if ($RetrainExportPath) { $arguments += @("--exportretrainpath", "`"$RetrainExportPath`"") }
        if ($ConsumeRetrainQueue) { $arguments += "--consumeexportqueue" }

        try {
            $process = Start-Process -FilePath $pythonPath -ArgumentList $arguments -Wait -NoNewWindow -PassThru -RedirectStandardOutput $stdOutPath -RedirectStandardError $stdErrPath -ErrorAction Stop
        } catch {
            Write-Log "Remediation telemetry dispatch failed: $($_.Exception.Message)" -Level "WARNING"
            return $null
        }

        $stdOut = -join (Get-Content -Path $stdOutPath -ErrorAction SilentlyContinue)
        $stdErr = -join (Get-Content -Path $stdErrPath -ErrorAction SilentlyContinue)
        Remove-Item -Path $stdOutPath, $stdErrPath -ErrorAction SilentlyContinue

        if ($process.ExitCode -ne 0) {
            Write-Log "AI engine returned non-zero exit while recording remediation outcome. ExitCode: $($process.ExitCode). Stderr: $stdErr" -Level "WARNING"
            return $null
        }

        if ([string]::IsNullOrWhiteSpace($stdOut)) {
            Write-Log "AI engine returned empty output while recording remediation outcome." -Level "WARNING"
            return $null
        }

        try {
            return $stdOut | ConvertFrom-Json -ErrorAction Stop
        } catch {
            Write-Log "Failed to parse AI engine response for remediation telemetry. Output: $stdOut" -Level "WARNING"
            return $null
        }
    }

    $workflowStartTime = Get-Date
    Write-Log "Starting AI Remediation Workflow at $workflowStartTime. Mode: $RemediationMode. InputData count: $($InputData.Count)."

    $serverNameResolved = if (-not [string]::IsNullOrWhiteSpace($ServerName)) {
        $ServerName
    } elseif ($InputData -and $InputData.Count -gt 0 -and $InputData[0].PSObject.Properties['Name']) {
        $InputData[0].Name
    } elseif ($InputData -and $InputData.Count -gt 0 -and $InputData[0].PSObject.Properties['ServerName']) {
        $InputData[0].ServerName
    } else {
        "UnknownServer"
    }

    # --- Define paths to other AI scripts (assumed to be in the same directory) ---
    $resolvedRoot = if (-not [string]::IsNullOrWhiteSpace($ScriptRootOverride)) { $ScriptRootOverride } else { $script:StartAIRemediationWorkflowRoot }
    if (-not $resolvedRoot) { $resolvedRoot = $global:StartAIRemediationWorkflowRoot }
    if (-not $resolvedRoot -and $PSCommandPath) { $resolvedRoot = Split-Path -Parent $PSCommandPath }
    if (-not $resolvedRoot) {
        $callerPath = $MyInvocation.MyCommand.ScriptBlock.File
        if (-not $callerPath) { $callerPath = $MyInvocation.PSCommandPath }
        if (-not $callerPath) { $callerPath = $MyInvocation.MyCommand.Path }
        if (-not $callerPath -and $PSScriptRoot) { $callerPath = $PSScriptRoot }
        if (-not $callerPath) { $callerPath = (Get-Location).Path }
        $resolvedRoot = Split-Path -Parent $callerPath -Resolve
    }
    $PSScriptRoot = $resolvedRoot
    $PathImportAIModel = Join-Path $PSScriptRoot "Import-AIModel.ps1"
    $PathConvertToAIFeatures = if (-not [string]::IsNullOrWhiteSpace($ConvertToAIFeaturesPath)) { $ConvertToAIFeaturesPath } else { Join-Path $PSScriptRoot "ConvertTo-AIFeatures.ps1" }
    $PathGetAIPredictions = Join-Path $PSScriptRoot "Get-AIPredictions.ps1"
    $PathGetAIRecommendations = if (-not [string]::IsNullOrWhiteSpace($GetAIRecommendationsPath)) { $GetAIRecommendationsPath } else { Join-Path $PSScriptRoot "Get-AIRecommendations.ps1" }
    $PathFindIssuePatterns = if (-not [string]::IsNullOrWhiteSpace($FindIssuePatternsPath)) { $FindIssuePatternsPath } else { Join-Path $PSScriptRoot "..\remediation\Find-IssuePatterns.ps1" }
    $PathGetRemediationAction = if (-not [string]::IsNullOrWhiteSpace($GetRemediationActionPath)) { $GetRemediationActionPath } else { Join-Path $PSScriptRoot "..\remediation\Get-RemediationAction.ps1" }
    $PathStartRemediationAction = if (-not [string]::IsNullOrWhiteSpace($StartRemediationActionPath)) { $StartRemediationActionPath } else { Join-Path $PSScriptRoot "..\remediation\Start-RemediationAction.ps1" }
    $PathGetValidationStep = if (-not [string]::IsNullOrWhiteSpace($GetValidationStepPath)) { $GetValidationStepPath } else { Join-Path $PSScriptRoot "..\remediation\Get-ValidationStep.ps1" }
    $PathTestRemediationResult = if (-not [string]::IsNullOrWhiteSpace($TestRemediationResultPath)) { $TestRemediationResultPath } else { Join-Path $PSScriptRoot "..\remediation\Test-RemediationResult.ps1" }

    # Map recommendation IDs to remediation action scaffolding
    $recommendationToActionMap = @{
        "REC_SVC001" = @{ RemediationActionId = "REM_ReviewServiceLogs"; ImplementationType = "Manual"; SuccessCriteria = "Logs reviewed and findings noted." }
        "REC_SVC002" = @{ RemediationActionId = "REM_VerifyServiceDependencies"; ImplementationType = "Manual"; SuccessCriteria = "Dependencies validated and running." }
        "REC_SVC003" = @{ RemediationActionId = "REM_RestartService_Generic"; ImplementationType = "Manual"; SuccessCriteria = "Service should be in 'Running' state after execution." }
        "REC_NET001" = @{ RemediationActionId = "REM_CheckNetAdapter"; ImplementationType = "Manual"; SuccessCriteria = "Network adapters report an Up status." }
        "REC_NET002" = @{ RemediationActionId = "REM_CheckDnsClient"; ImplementationType = "Manual"; SuccessCriteria = "DNS client configuration validated." }
        "REC_NET003" = @{ RemediationActionId = "REM_TestConnectivity"; ImplementationType = "Manual"; SuccessCriteria = "Connectivity to required endpoints confirmed." }
        "REC_APP001" = @{ RemediationActionId = "REM_InvestigateAppLogs"; ImplementationType = "Manual"; SuccessCriteria = "Application errors reduced after remediation." }
    }

    function Convert-RecommendationToAction {
        param(
            [Parameter(Mandatory = $true)]
            [pscustomobject]$Recommendation
        )

        $mapped = $recommendationToActionMap[$Recommendation.RecommendationId]
        $remediationId = if ($mapped) { $mapped.RemediationActionId } elseif (-not [string]::IsNullOrWhiteSpace($Recommendation.RecommendationId)) { "REM_$($Recommendation.RecommendationId)" } else { "REM_UNKNOWN" }
        if (-not $mapped) {
            Write-Log "No remediation mapping for RecommendationId '$($Recommendation.RecommendationId)'. Defaulting to manual action." -Level "WARNING"
        }

        $resolved = [PSCustomObject]@{
            RemediationActionId = $remediationId
            Title = $Recommendation.Title
            Description = $Recommendation.Description
            ImplementationType = if($mapped){$mapped.ImplementationType}else{"Manual"}
            TargetScriptPath = if($mapped){$mapped.TargetScriptPath}else{$null}
            TargetFunction = if($mapped){$mapped.TargetFunction}else{$null}
            ResolvedParameters = if($mapped -and $mapped.ResolvedParameters){$mapped.ResolvedParameters}else{@{}}
            ConfirmationRequired = $true
            Impact = $Recommendation.Severity
            SuccessCriteria = if($mapped){$mapped.SuccessCriteria}else{"Manual verification required for $($Recommendation.RecommendationId)."}
        }
        return $resolved
    }

    # --- Workflow Variables ---
    $loadedModel = $null
    $isModelLoaded = $false
    $features = @()
    $predictions = @() # Array of prediction result objects
    $highConfidencePredictions = @()
    $recommendationsOutput = @() # Array of objects, each with InputItem and Recommendations array
    $patternMatches = @()
    $patternDerivedActions = [System.Collections.ArrayList]::new()
    $remediationsAttempted = [System.Collections.ArrayList]::new()
    $remediationResults = [System.Collections.ArrayList]::new()
    $remediationTelemetry = [System.Collections.ArrayList]::new()
    $validationReports = [System.Collections.ArrayList]::new()
    $overallStatus = "Started"

    try {
        # --- Step 1: Load AI Model (if specified) ---
        if (-not [string]::IsNullOrWhiteSpace($AIModelNameOrPath)) {
            Write-Log "Step 1: Loading AI Model from '$AIModelNameOrPath' with Type '$AIModelType'."
            if (-not (Test-Path $PathImportAIModel -PathType Leaf)) { Write-Log "Import-AIModel.ps1 not found at $PathImportAIModel" -Level "ERROR"; throw "Dependency script missing." }
            try {
                $loadedModel = . $PathImportAIModel -ModelPath $AIModelNameOrPath -ModelType $AIModelType -LogPath $LogPath # Pass LogPath for sub-script
                if ($loadedModel) {
                    $isModelLoaded = $true
                    Write-Log "AI Model loaded successfully."
                } else {
                    Write-Log "Failed to load AI Model or model type not supported. Continuing without model-based predictions." -Level "WARNING"
                }
            } catch {
                Write-Log "Error during Import-AIModel: $($_.Exception.Message). Continuing without model-based predictions." -Level "ERROR"
            }
        } else {
            Write-Log "Step 1: Skipped - No AIModelNameOrPath provided."
        }

        # --- Step 2: Convert Input to Features ---
        Write-Log "Step 2: Converting InputData to AI Features."
        if (-not (Test-Path $PathConvertToAIFeatures -PathType Leaf)) { Write-Log "ConvertTo-AIFeatures.ps1 not found at $PathConvertToAIFeatures" -Level "ERROR"; throw "Dependency script missing." }
        try {
            $convertParams = @{ InputData = $InputData; LogPath = $LogPath }
            if (-not [string]::IsNullOrWhiteSpace($FeatureDefinitionPath)) { $convertParams.FeatureDefinition = $FeatureDefinitionPath }
            $features = . $PathConvertToAIFeatures @convertParams
            Write-Log "Converted $($InputData.Count) input items to $($features.Count) feature sets."
        } catch {
            Write-Log "Error during ConvertTo-AIFeatures: $($_.Exception.Message). Cannot proceed without features." -Level "FATAL"
            throw "Feature conversion failed." # Critical step
        }

        # --- Step 2a: Detect patterns for rule-based remediation ---
        if ($InputData.Count -gt 0 -and (Test-Path $PathFindIssuePatterns -PathType Leaf)) {
            try {
                $patternParams = @{ InputData = $InputData; LogPath = $LogPath }
                if (-not [string]::IsNullOrWhiteSpace($IssuePatternDefinitionsPath)) { $patternParams.IssuePatternDefinitionsPath = $IssuePatternDefinitionsPath }
                $patternMatches = . $PathFindIssuePatterns @patternParams
                Write-Log "Pattern detection produced $($patternMatches.Count) matches." -Level "INFO"
            } catch {
                Write-Log "Pattern detection failed: $($_.Exception.Message)" -Level "WARNING"
            }
        } else {
            Write-Log "Step 2a: Skipped pattern detection (no input or script missing)." -Level "DEBUG"
        }

        # --- Step 3: Get AI Predictions (if model loaded) ---
        if ($isModelLoaded -and $features.Count -gt 0) {
            Write-Log "Step 3: Getting AI Predictions using model type '$AIModelType'."
            if (-not (Test-Path $PathGetAIPredictions -PathType Leaf)) { Write-Log "Get-AIPredictions.ps1 not found at $PathGetAIPredictions" -Level "ERROR"; throw "Dependency script missing." }
            try {
                $predictions = . $PathGetAIPredictions -InputFeatures $features -ModelObject $loadedModel -ModelType $AIModelType -LogPath $LogPath
                Write-Log "Generated $($predictions.Count) predictions."
                if ($predictions) {
                    $highConfidencePredictions = $predictions | Where-Object { $_.Probability -ge $PredictionConfidenceThreshold -or $_.Status -eq 'Success' -and -not $_.Probability }
                    Write-Log "High-confidence predictions (>= $PredictionConfidenceThreshold): $($highConfidencePredictions.Count)." -Level "DEBUG"
                }
            } catch {
                Write-Log "Error during Get-AIPredictions: $($_.Exception.Message). May affect recommendation quality or subsequent steps." -Level "ERROR"
            }
        } else {
             Write-Log "Step 3: Skipped - AI Model not loaded or no features generated."
        }

        # --- Step 4: Get AI Recommendations ---
        # Input for recommendations could be $features, $predictions, or even $InputData if patterns were from Find-DiagnosticPattern
        $inputForRecommendations = if ($features.Count -gt 0) { $features } else { $InputData } # Simplified choice
        
        if ($inputForRecommendations.Count -gt 0) {
            Write-Log "Step 4: Getting AI Recommendations. Using $($inputForRecommendations.Count) items as input for recommendations."
            if (-not (Test-Path $PathGetAIRecommendations -PathType Leaf)) { Write-Log "Get-AIRecommendations.ps1 not found at $PathGetAIRecommendations" -Level "ERROR"; throw "Dependency script missing." }
            try {
                $recoParams = @{ InputFeatures = $inputForRecommendations; LogPath = $LogPath }
                if (-not [string]::IsNullOrWhiteSpace($RecommendationRulesPath)) { $recoParams.RecommendationRulesPath = $RecommendationRulesPath }
                $recommendationsOutput = . $PathGetAIRecommendations @recoParams
                Write-Log "Retrieved recommendations for $($recommendationsOutput.Count) input items."
            } catch {
                Write-Log "Error during Get-AIRecommendations: $($_.Exception.Message)." -Level "ERROR"
            }
        } else {
            Write-Log "Step 4: Skipped - No suitable input for recommendations."
        }

        # --- Step 4a: Resolve remediation actions from pattern matches ---
        if ($patternMatches.Count -gt 0) {
            if (Test-Path $PathGetRemediationAction -PathType Leaf) {
                try {
                    $patternDerivedActions = . $PathGetRemediationAction -InputObject $patternMatches -RemediationRulesPath $RemediationRulesPath -MaxActionsPerInput 1 -LogPath $LogPath
                    Write-Log "Resolved $($patternDerivedActions.Count) remediation action plans from pattern matches." -Level "INFO"
                } catch {
                    Write-Log "Get-RemediationAction failed for pattern matches: $($_.Exception.Message)" -Level "WARNING"
                }
            } else {
                Write-Log "Get-RemediationAction.ps1 not found at $PathGetRemediationAction; using direct pattern-to-action fallback." -Level "WARNING"
                foreach ($pm in $patternMatches) {
                    $fallbackActionId = if ($pm.SuggestedRemediationId) { $pm.SuggestedRemediationId } elseif ($pm.MatchedIssueId) { "REM_$($pm.MatchedIssueId)" } else { "REM_UNKNOWN" }
                    $patternDerivedActions.Add([PSCustomObject]@{
                        InputContext = $pm
                        SuggestedActions = @([PSCustomObject]@{
                            RemediationActionId = $fallbackActionId
                            Title = if($pm.MatchedIssueDescription){$pm.MatchedIssueDescription}else{"Pattern-based remediation"}
                            Description = "Auto-generated remediation for matched issue pattern."
                            ImplementationType = "Manual"
                            TargetScriptPath = $null
                            TargetFunction = $null
                            ResolvedParameters = @{}
                            ConfirmationRequired = $true
                            Impact = $pm.PatternSeverity
                            SuccessCriteria = "Operator confirms resolution."
                        })
                        Timestamp = (Get-Date -Format o)
                    }) | Out-Null
                }
            }
        }
        
        # --- Step 5: Process Recommendations and Attempt Remediation ---
        Write-Log "Step 5: Processing Recommendations and Attempting Remediation (Mode: $RemediationMode)."
        if ($recommendationsOutput.Count -gt 0) {
            foreach ($recoPackage in $recommendationsOutput) { # Each $recoPackage has InputItem and Recommendations array
                Write-Log "Input Item: $($recoPackage.InputItem | Out-String -Width 100)" -Level "DEBUG"
                $recommendationList = @($recoPackage.Recommendations)
                foreach ($recAction in $recommendationList) {
                    if (-not $recAction) { continue }
                    Write-Log "Considering Recommendation: '$($recAction.Title)' (ID: $($recAction.RecommendationId), Severity: $($recAction.Severity), Confidence: $($recAction.Confidence))"
                    
                    $attemptAction = $false
                    if ($RemediationMode -eq 'Automatic') {
                        Write-Log "Automatic mode: Action for '$($recAction.Title)' will be attempted."
                        $attemptAction = $true
                    } elseif ($RemediationMode -eq 'Assisted') {
                        if ($PSCmdlet.ShouldProcess("User for approval of: $($recAction.Title) - $($recAction.Description)", "Apply Remediation")) {
                             # Using Read-Host for actual prompt in non-interactive or test if ShouldProcess isn't enough
                             $choice = Read-Host -Prompt "Apply remediation: '$($recAction.Title)'? (y/n)"
                             if ($choice -eq 'y') {
                                 Write-Log "User approved action for '$($recAction.Title)'."
                                 $attemptAction = $true
                             } else {
                                 Write-Log "User SKIPPED action for '$($recAction.Title)'."
                                 $remediationsAttempted.Add([PSCustomObject]@{ RecommendationTitle = $recAction.Title; RecommendationId = $recAction.RecommendationId; Status = "SkippedByUser" }) | Out-Null
                             }
                        } else {
                             Write-Log "Action for '$($recAction.Title)' SKIPPED due to ShouldProcess (-WhatIf)."
                             $remediationsAttempted.Add([PSCustomObject]@{ RecommendationTitle = $recAction.Title; RecommendationId = $recAction.RecommendationId; Status = "SkippedWhatIf" }) | Out-Null
                        }
                    }

                    if ($attemptAction) {
                        Write-Log "Attempting to execute action for recommendation: '$($recAction.Title)' (ID: $($recAction.RecommendationId))"
                        if (-not (Test-Path $PathStartRemediationAction -PathType Leaf)) { Write-Log "Start-RemediationAction.ps1 not found at $PathStartRemediationAction" -Level "ERROR"; $remediationsAttempted.Add([PSCustomObject]@{ RecommendationTitle = $recAction.Title; RecommendationId = $recAction.RecommendationId; Status = "FailedDependencyMissing" }) | Out-Null; continue }
                        $actionPlan = Convert-RecommendationToAction -Recommendation $recAction
                        if (-not $actionPlan) {
                            $remediationsAttempted.Add([PSCustomObject]@{ RecommendationTitle = $recAction.Title; RecommendationId = $recAction.RecommendationId; Status = "FailedMapping" }) | Out-Null
                            continue
                        }

                        $validationReport = $null

                        try {
                            $actionResult = . $PathStartRemediationAction -ApprovedAction $actionPlan -LogPath $LogPath
                            $remediationResults.Add($actionResult) | Out-Null
                            $remediationsAttempted.Add([PSCustomObject]@{ RecommendationTitle = $recAction.Title; RecommendationId = $recAction.RecommendationId; Status = $actionResult.Status; RemediationActionId = $actionResult.RemediationActionId }) | Out-Null
                        } catch {
                            Write-Log "Failed to execute remediation for '$($recAction.Title)'. Error: $($_.Exception.Message)" -Level "ERROR"
                            $remediationsAttempted.Add([PSCustomObject]@{ RecommendationTitle = $recAction.Title; RecommendationId = $recAction.RecommendationId; Status = "FailedExecution" }) | Out-Null
                            $actionResult = $null
                        }

                        # Attempt validation when an action ran and validation hooks are available
                        if ($actionResult -and $PathGetValidationStep -and $PathTestRemediationResult) {
                            try {
                                $validationSteps = @(. $PathGetValidationStep -RemediationAction $actionPlan -ValidationRulesPath $ValidationRulesPath -LogPath $LogPath)
                                if ($validationSteps.Count -gt 0) {
                                    $validationReport = . $PathTestRemediationResult -ValidationSteps $validationSteps -RemediationActionResult $actionResult -LogPath $LogPath
                                    if ($validationReport) { $validationReports.Add($validationReport) | Out-Null }
                                } else {
                                    Write-Log "No validation steps generated for action '$($actionPlan.RemediationActionId)'" -Level "INFO"
                                }
                            } catch {
                                Write-Log "Validation failed for action '$($actionPlan.RemediationActionId)'. Error: $($_.Exception.Message)" -Level "ERROR"
                            }
                        } else {
                            Write-Log "Validation not attempted; scripts missing or action result unavailable for '$($recAction.RecommendationId)'." -Level "DEBUG"
                        }

                        if ($actionResult) {
                            $telemetryPayload = @{
                                server_name = $serverNameResolved
                                timestamp = (Get-Date).ToString("o")
                                error_type = if ($recAction.RecommendationId) { $recAction.RecommendationId } else { "UnknownError" }
                                action = $actionPlan.RemediationActionId
                                outcome = $actionResult.Status
                                context = @{
                                    recommendation_title = $recAction.Title
                                    severity = $recAction.Severity
                                    confidence = $recAction.Confidence
                                    implementation_type = $actionPlan.ImplementationType
                                    validation_status = if ($validationReport) { $validationReport.OverallValidationStatus } else { $null }
                                    output = $actionResult.Output
                                    errors = $actionResult.Errors
                                }
                            }

                            $telemetryResponse = Invoke-RemediationOutcomeTelemetry -Payload $telemetryPayload -ServerNameResolved $serverNameResolved
                            if ($telemetryResponse) { $remediationTelemetry.Add($telemetryResponse) | Out-Null }
                        }
                    }
                }
            }
        } else {
            Write-Log "No recommendations generated to process."
        }

        # --- Step 5b: Process pattern-derived remediation actions ---
        if ($patternDerivedActions.Count -gt 0) {
            foreach ($plan in $patternDerivedActions) {
                $patternContext = $plan.InputContext
                $sourceId = if ($patternContext.MatchedIssueId) { $patternContext.MatchedIssueId } elseif ($patternContext.IssueId) { $patternContext.IssueId } else { "Pattern" }
                foreach ($actionPlan in $plan.SuggestedActions) {
                    $attemptAction = $false
                    $titleForLog = if ($actionPlan.Title) { $actionPlan.Title } else { $actionPlan.RemediationActionId }

                    if ($RemediationMode -eq 'Automatic') {
                        $attemptAction = $true
                    } elseif ($RemediationMode -eq 'Assisted') {
                        if ($PSCmdlet.ShouldProcess("User for approval of: $titleForLog", "Apply Remediation")) {
                            $choice = Read-Host -Prompt "Apply remediation: '$titleForLog'? (y/n)"
                            if ($choice -eq 'y') { $attemptAction = $true }
                            else { $remediationsAttempted.Add([PSCustomObject]@{ RecommendationTitle = $titleForLog; RecommendationId = $sourceId; Status = "SkippedByUser" }) | Out-Null }
                        } else {
                            $remediationsAttempted.Add([PSCustomObject]@{ RecommendationTitle = $titleForLog; RecommendationId = $sourceId; Status = "SkippedWhatIf" }) | Out-Null
                        }
                    }

                    if (-not $attemptAction) { continue }
                    if (-not (Test-Path $PathStartRemediationAction -PathType Leaf)) { $remediationsAttempted.Add([PSCustomObject]@{ RecommendationTitle = $titleForLog; RecommendationId = $sourceId; Status = "FailedDependencyMissing" }) | Out-Null; continue }

                    $validationReport = $null
                    $actionResult = $null
                    try {
                        $actionResult = . $PathStartRemediationAction -ApprovedAction $actionPlan -LogPath $LogPath
                        $remediationResults.Add($actionResult) | Out-Null
                        $remediationsAttempted.Add([PSCustomObject]@{ RecommendationTitle = $titleForLog; RecommendationId = $sourceId; Status = $actionResult.Status; RemediationActionId = $actionResult.RemediationActionId }) | Out-Null
                    } catch {
                        Write-Log "Failed to execute remediation for pattern '$sourceId'. Error: $($_.Exception.Message)" -Level "ERROR"
                        $remediationsAttempted.Add([PSCustomObject]@{ RecommendationTitle = $titleForLog; RecommendationId = $sourceId; Status = "FailedExecution" }) | Out-Null
                    }

                    if ($actionResult -and $PathGetValidationStep -and $PathTestRemediationResult) {
                        try {
                            $validationSteps = @(. $PathGetValidationStep -RemediationAction $actionPlan -ValidationRulesPath $ValidationRulesPath -LogPath $LogPath)
                            if ($validationSteps.Count -gt 0) {
                                $validationReport = . $PathTestRemediationResult -ValidationSteps $validationSteps -RemediationActionResult $actionResult -LogPath $LogPath
                                if ($validationReport) { $validationReports.Add($validationReport) | Out-Null }
                            }
                        } catch {
                            Write-Log "Validation failed for pattern action '$($actionPlan.RemediationActionId)': $($_.Exception.Message)" -Level "ERROR"
                        }
                    }

                    if ($actionResult) {
                        $telemetryPayload = @{
                            server_name = $serverNameResolved
                            timestamp = (Get-Date).ToString("o")
                            error_type = $sourceId
                            action = $actionPlan.RemediationActionId
                            outcome = $actionResult.Status
                            context = @{
                                recommendation_title = $titleForLog
                                severity = $actionPlan.Impact
                                implementation_type = $actionPlan.ImplementationType
                                validation_status = if ($validationReport) { $validationReport.OverallValidationStatus } else { $null }
                                output = $actionResult.Output
                                errors = $actionResult.Errors
                            }
                        }
                        $telemetryResponse = Invoke-RemediationOutcomeTelemetry -Payload $telemetryPayload -ServerNameResolved $serverNameResolved
                        if ($telemetryResponse) { $remediationTelemetry.Add($telemetryResponse) | Out-Null }
                    }
                }
            }
        }

        # --- Step 6: Verify Remediation (Conceptual) ---
        Write-Log "Step 6: Remediation Verification (Conceptual)."
        if ($remediationsAttempted.Count -gt 0) {
            Write-Log "Validation reports captured: $($validationReports.Count). Remediation results captured: $($remediationResults.Count)."
        } else {
            Write-Log "No remediations were attempted, skipping verification."
        }

        # If validation was requested but produced no reports, surface as a failed validation artifact
        if (-not [string]::IsNullOrWhiteSpace($ValidationRulesPath) -and $remediationResults.Count -gt 0 -and $validationReports.Count -eq 0) {
            $fallbackValidation = [PSCustomObject]@{
                OverallValidationStatus = 'Failed'
                ValidationStepResults   = @()
                Notes                   = 'Validation requested but no validation reports were produced.'
            }
            $validationReports.Add($fallbackValidation) | Out-Null
            Write-Log "Validation rules were supplied but no validation reports were generated; marking validation as failed." -Level "WARNING"
        }

        $overallStatus = "Completed"
        $totalRecommendedActions = 0
        foreach ($pkg in $recommendationsOutput) {
            if ($pkg -and $pkg.Recommendations) { $totalRecommendedActions += @($pkg.Recommendations).Count }
        }

        $failedRemediations = @()
        if ($remediationResults) {
            $failedRemediations = $remediationResults | Where-Object { $_.Status -eq 'Failed' -or $_.Status -eq 'FailedExecution' -or $_.Status -eq 'FailedDependencyMissing' }
        }
        if (-not $failedRemediations -and $remediationsAttempted) {
            $failedRemediations = $remediationsAttempted | Where-Object { $_.Status -eq 'Failed' -or $_.Status -eq 'FailedExecution' -or $_.Status -eq 'FailedDependencyMissing' }
        }

        if ($failedRemediations -and $failedRemediations.Count -gt 0) {
            $overallStatus = "CompletedWithFailures"
        } elseif ($totalRecommendedActions -gt 0 -and ($remediationsAttempted.Count -lt $totalRecommendedActions)) {
            $overallStatus = "CompletedWithFailures"
        } elseif ($validationReports | Where-Object { $_.OverallValidationStatus -eq 'Failed' }) {
            $overallStatus = "CompletedWithValidationFailures"
        } elseif (-not $remediationsAttempted -or $remediationsAttempted.Count -eq 0) {
            $overallStatus = "CompletedNoRemediation"
        }

        $validationFailuresCount = 0
        $validationPassedCount = 0
        if ($validationReports) {
            $validationFailuresCount = ($validationReports | Where-Object { $_.OverallValidationStatus -eq 'Failed' }).Count
            $validationPassedCount = ($validationReports | Where-Object { $_.OverallValidationStatus -eq 'Passed' -or $_.OverallValidationStatus -eq 'Success' }).Count
        }

        $pendingRetrainRequests = @()
        $aiRecommenderResponses = @()
        if ($remediationTelemetry) {
            foreach ($resp in $remediationTelemetry) {
                if ($resp.pending_retrain_requests) { $pendingRetrainRequests += $resp.pending_retrain_requests }
                if ($resp.recommendations -or $resp.ai_recommendations) { $aiRecommenderResponses += $resp }
            }
        }
    }
    catch {
        Write-Log "A critical error occurred in the workflow: $($_.Exception.Message)" -Level "FATAL"
        Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "DEBUG"
        $overallStatus = "FailedWithError"
        # Depending on the error, we might re-throw or just return the summary
        # throw $_ # Uncomment to make the whole workflow script throw on error
    }
    finally {
        $workflowEndTime = Get-Date
        Write-Log "AI Remediation Workflow finished at $workflowEndTime. Overall Status: $overallStatus."
        
        $summary = @{
            WorkflowStartTime      = $workflowStartTime
            WorkflowEndTime        = $workflowEndTime
            TotalDurationSeconds   = ($workflowEndTime - $workflowStartTime).TotalSeconds
            InputItemCount         = $InputData.Count
            AIModelUsedPath        = $AIModelNameOrPath
            AIModelLoaded          = $isModelLoaded
            FeaturesGeneratedCount = if($features){$features.Count}else{0}
            PatternMatchesCount    = if($patternMatches){$patternMatches.Count}else{0}
            PredictionsMadeCount   = if($predictions){$predictions.Count}else{0}
            PredictionsHighConfidenceCount = if($highConfidencePredictions){$highConfidencePredictions.Count}else{0}
            RecommendationsOutputCount = if($recommendationsOutput){$recommendationsOutput.Count}else{0}
            RecommendationsTotalCount = $totalRecommendedActions
            PatternActionPlansCount = if($patternDerivedActions){$patternDerivedActions.Count}else{0}
            ActionsExecutedCount    = if($remediationResults){$remediationResults.Count}else{0}
            RemediationsAttempted  = $remediationsAttempted
            RemediationResults     = $remediationResults
            RemediationTelemetryResponses = $remediationTelemetry
            ValidationReports      = $validationReports
            ValidationPassedCount  = $validationPassedCount
            ValidationFailedCount  = $validationFailuresCount
            PendingRetrainRequestCount = $pendingRetrainRequests.Count
            PendingRetrainRequests = $pendingRetrainRequests
            AIRecommenderResponses = $aiRecommenderResponses
            OverallStatus          = $overallStatus
        }
        Write-Log "Workflow Summary: $($summary | Out-String)" -Level "DEBUG"
    }
    return [PSCustomObject]$summary
}

# VIBE Phase 3: Behavioral & Contract Integrity Report

**Generated:** 2025-01-30  
**Audit Scope:** API contracts, agent behaviors, data models, error semantics, cross-module invariants  
**Previous Phases:** Phase 1 (Structural), Phase 2 (Consistency) findings incorporated

---

## Executive Summary

| Category | Items Audited | Contract Violations |
|----------|---------------|---------------------|
| Public APIs | 12 | 8 |
| Agent Behaviors | 5 | 3 |
| Data Models | 6 | 5 |
| Error/Edge Cases | 15 | 9 |
| Cross-Module Contracts | 4 chains | 6 |

**Critical Violations:** 7  
**High Severity:** 12  
**Medium Severity:** 12

---

## 1. API Contract Violations

### 1.1 API: `Get-PredictiveInsights` (PowerShell → Python Bridge)

- **Location:** [src/Powershell/AI/Get-PredictiveInsights.ps1](src/Powershell/AI/Get-PredictiveInsights.ps1#L1-L199)
- **Declared Contract:**
  - Source: Function signature, ValidateSet, docs/AI-Components.md
  - Expected Behavior: Returns predictive insights JSON for a server
  - Expected Input: `-ServerName` (required), `-AnalysisType` (Full/Health/Failure/Anomaly)
  - Expected Output: PSCustomObject with `health_status`, `failure_risk`, `anomalies`, `recommendations`

- **Observed Implementation:**
  - Actual Behavior: Calls `invoke_ai_engine.py` which internally calls `analyze_deployment_risk()`, NOT model-specific predictions based on `-AnalysisType`
  - Actual Input Handling: `-AnalysisType` is passed to Python but **IGNORED** by `PredictiveAnalyticsEngine.analyze_deployment_risk()`
  - Actual Output: Returns `overall_risk`, `health_status`, `failure_risk`, `anomalies`, `patterns`, `recommendations`

- **Violation(s):**
  - **CRITICAL:** `-AnalysisType` parameter has no effect on Python behavior. User expects `Health` to return only health prediction, but always gets full analysis.
  - **HIGH:** Output shape contains `overall_risk` and `patterns` keys not documented in AI-Components.md PowerShell section.

- **Suggested Fix:**
  ```python
  # Before (invoke_ai_engine.py line 143-144):
  results = engine.analyze_deployment_risk(server_data_input)
  
  # After:
  analysis_type = args.analysistype
  if analysis_type == "Full":
      results = engine.analyze_deployment_risk(server_data_input)
  elif analysis_type == "Health":
      results = {"health_status": engine.predictor.predict_health(server_data_input)}
  elif analysis_type == "Failure":
      results = {"failure_risk": engine.predictor.predict_failures(server_data_input)}
  elif analysis_type == "Anomaly":
      results = {"anomalies": engine.predictor.detect_anomalies(server_data_input)}
  ```

- **Severity:** CRITICAL
- **Notes:** Related to Phase 1 finding about incomplete API dependencies.

---

### 1.2 API: `run_predictor.py` CLI Entry Point

- **Location:** [src/Python/run_predictor.py](src/Python/run_predictor.py#L1-L109)
- **Declared Contract:**
  - Source: argparse help strings, docstring
  - Expected Behavior: "Processes telemetry data from a JSON string and runs specified predictions"
  - Expected Input: `--telemetrydatajson` (required), `--analysis-type` (Full/Health/Failure/Anomaly)
  - Expected Output: JSON with prediction results keyed by analysis type

- **Observed Implementation:**
  - Actual Behavior: Correctly routes to specific prediction methods based on `--analysis-type`
  - Actual Input Handling: Requires `--telemetrydatajson` but doesn't validate feature presence
  - Actual Output: Correct shape when models are loaded

- **Violation(s):**
  - **HIGH:** Returns `{"error": "..."}` dict on model load failure instead of raising/exiting with non-zero code
  - **MEDIUM:** No validation that `--telemetrydatajson` contains expected feature keys before prediction

- **Suggested Fix:**
  ```python
  # Before (line 57-59):
  if not os.path.exists(args.model_dir) or not os.listdir(args.model_dir):
       output_results = {"error": f"Model directory {args.model_dir} is empty..."}
       print(json.dumps(output_results), flush=True)
       return
  
  # After:
  if not os.path.exists(args.model_dir) or not os.listdir(args.model_dir):
       error_output = {"error": "ModelDirectoryNotFound", "message": f"Model directory {args.model_dir} is empty or does not exist."}
       print(json.dumps(error_output), file=sys.stderr, flush=True)
       sys.exit(1)
  ```

- **Severity:** HIGH

---

### 1.3 API: `Start-ArcDiagnostics`

- **Location:** [src/Powershell/core/Start-ArcDiagnostics.ps1](src/Powershell/core/Start-ArcDiagnostics.ps1#L1-L308)
- **Declared Contract:**
  - Source: Parameter block, Phase 1 findings
  - Expected Behavior: Collects comprehensive diagnostic data for Arc-enabled servers
  - Expected Input: `-ServerName` (required), `-WorkspaceId` (optional), `-DetailedScan` (switch)
  - Expected Output: PSCustomObject with `SystemState`, `ArcStatus`, `AMAStatus`, `Connectivity`, `Logs`

- **Observed Implementation:**
  - Actual Behavior: Calls 15+ stub functions that throw `NotImplementedError`
  - Actual Input Handling: Correct parameter validation
  - Actual Output: Only works with `$env:ARC_DIAG_TESTDATA = '1'` (test mode)

- **Violation(s):**
  - **CRITICAL:** Function is unusable in production - all core dependencies are stubs (Phase 1 critical issue)
  - **HIGH:** No fallback behavior when stub functions throw - entire diagnostic fails

- **Suggested Fix:**
  ```powershell
  # Before (line 122):
  $diagnosticResults.SystemState = Get-SystemState -ServerName $ServerName
  
  # After (defensive wrapper):
  try {
      $diagnosticResults.SystemState = Get-SystemState -ServerName $ServerName
  } catch {
      Write-Warning "Get-SystemState not implemented. Using fallback."
      $diagnosticResults.SystemState = @{
          Status = 'NotAvailable'
          Error = $_.Exception.Message
      }
  }
  ```

- **Severity:** CRITICAL
- **Notes:** Cross-reference Phase 1 Section 1.2 - 24 stub functions.

---

### 1.4 API: `PredictiveAnalyticsEngine.analyze_deployment_risk()`

- **Location:** [src/Python/predictive/predictive_analytics_engine.py](src/Python/predictive/predictive_analytics_engine.py#L66-L97)
- **Declared Contract:**
  - Source: Docstring, AI-Components.md Section 9
  - Expected Behavior: "Analyzes deployment risk based on server data and models"
  - Expected Input: `server_data: Dict[str, Any]` - dictionary with telemetry features
  - Expected Output: Dict with `overall_risk`, `health_status`, `failure_risk`, `anomalies`, `patterns`, `recommendations`

- **Observed Implementation:**
  - Actual Behavior: Correctly orchestrates predictor and pattern analyzer
  - Actual Input Handling: **No validation** that `server_data` contains required features
  - Actual Output: Correct when models loaded; raises when models missing

- **Violation(s):**
  - **HIGH:** `_calculate_overall_risk()` assumes prediction dicts have specific keys (`health['prediction']['healthy_probability']`) but predictor can return `{"error": "..."}` dict instead
  - **MEDIUM:** No input schema validation - silently uses 0.0 for missing features

- **Suggested Fix:**
  ```python
  # Before (line 80-86):
  risk_score = (
      (1 - health['prediction']['healthy_probability']) * health_weight +
      failure['prediction']['failure_probability'] * failure_weight +
      (1 if anomaly['is_anomaly'] else 0) * anomaly_weight
  )
  
  # After (defensive access):
  def _safe_get_prediction_value(pred_dict, key_path, default=0.5):
      """Safely extract nested prediction value, handling error dicts."""
      if 'error' in pred_dict:
          return default
      try:
          result = pred_dict
          for key in key_path:
              result = result[key]
          return result
      except (KeyError, TypeError):
          return default
  
  health_prob = self._safe_get_prediction_value(health, ['prediction', 'healthy_probability'], 0.5)
  failure_prob = self._safe_get_prediction_value(failure, ['prediction', 'failure_probability'], 0.5)
  is_anomaly = anomaly.get('is_anomaly', False) if 'error' not in anomaly else False
  ```

- **Severity:** HIGH

---

### 1.5 API: `ArcPredictor.predict_health/failures/anomalies()`

- **Location:** [src/Python/predictive/predictor.py](src/Python/predictive/predictor.py#L135-L260)
- **Declared Contract:**
  - Source: Docstrings, type hints
  - Expected Behavior: Returns prediction dict with `prediction` key containing probabilities
  - Expected Input: `telemetry_data: Dict[str, Any]`
  - Expected Output: Dict with `prediction`, `feature_impacts`, `timestamp`

- **Observed Implementation:**
  - Actual Behavior: Returns error dict `{"error": "..."}` when model not loaded OR raises exception on other failures
  - Actual Output: **Two different error patterns** - sometimes returns error dict, sometimes raises

- **Violation(s):**
  - **HIGH:** Inconsistent error handling - `_ensure_model_loaded()` returns error dict, but other exceptions are raised
  - **MEDIUM:** Docstrings don't document error dict return possibility

- **Suggested Fix:**
  ```python
  # Standardize on returning error dicts (preferred for CLI callers):
  
  # Before (line 176-177):
  except Exception as e:
      self.logger.error(f"Health prediction failed: {str(e)}")
      raise
  
  # After:
  except Exception as e:
      self.logger.error(f"Health prediction failed: {str(e)}")
      return {
          "error": type(e).__name__,
          "message": str(e),
          "model_type": model_type,
          "timestamp": datetime.now().isoformat()
      }
  ```

- **Severity:** HIGH

---

### 1.6 API: `Start-AIRemediationWorkflow`

- **Location:** [src/Powershell/AI/Start-AIRemediationWorkflow.ps1](src/Powershell/AI/Start-AIRemediationWorkflow.ps1#L1-L683)
- **Declared Contract:**
  - Source: Comment block, parameter definitions
  - Expected Behavior: "Orchestrates an AI-driven diagnostic and remediation workflow"
  - Expected Input: `-InputData` (object[]), various optional paths
  - Expected Output: Remediation summary with patterns detected and actions executed

- **Observed Implementation:**
  - Actual Behavior: Chains `Find-IssuePatterns`, `Get-RemediationAction`, `Start-RemediationAction`
  - Actual Input Handling: Accepts flexible input but has **duplicate parameter** `$RemediationRulesPath` (lines 23 and 37)
  - Actual Output: Returns summary object

- **Violation(s):**
  - **MEDIUM:** Duplicate parameter `$RemediationRulesPath` declared twice - PowerShell uses last declaration
  - **MEDIUM:** Internal `Write-Log` function shadows module's `Write-Log` (Phase 2 consistency issue)
  - **LOW:** TODO comments indicate incomplete implementation

- **Suggested Fix:**
  ```powershell
  # Before (lines 22-23 AND 36-37):
  [string]$RecommendationRulesPath,
  ...
  [string]$RemediationRulesPath,
  ...
  [string]$RemediationRulesPath,  # DUPLICATE
  
  # After (remove duplicate):
  [string]$RecommendationRulesPath,
  ...
  [string]$RemediationRulesPath,
  # (second instance removed)
  ```

- **Severity:** MEDIUM

---

### 1.7 API: `TelemetryProcessor.process_telemetry()`

- **Location:** [src/Python/analysis/telemetry_processor.py](src/Python/analysis/telemetry_processor.py#L28-L84)
- **Declared Contract:**
  - Source: Docstring, AI-Components.md Section 2
  - Expected Behavior: "Process raw telemetry data into structured insights"
  - Expected Input: `telemetry_data: Dict[str, Any]`
  - Expected Output: Dict with `processed_data`, `features`, `anomalies`, `trends`, `insights`

- **Observed Implementation:**
  - Actual Behavior: Validates input has metric columns, processes features
  - Actual Input Handling: **Strict validation** - raises if missing expected metric columns
  - Actual Output: Correct shape

- **Violation(s):**
  - **MEDIUM:** Docstring says `Dict[str, Any]` but implementation requires list-of-dicts or DataFrame-compatible structure (line 89: `pd.DataFrame(telemetry_data)`)
  - **LOW:** `flattened_features` key in output not documented

- **Suggested Fix:**
  ```python
  # Before (docstring):
  """Process raw telemetry data into structured insights."""
  
  # After (accurate docstring):
  """Process raw telemetry data into structured insights.
  
  Args:
      telemetry_data: List of telemetry records or dict with column lists.
          Must be convertible to pandas DataFrame with at least one metric
          column (e.g., cpu_usage, memory_usage, error_count).
  
  Returns:
      Dict with keys: processed_data (DataFrame), features, flattened_features,
      anomalies, trends, insights, timestamp.
  
  Raises:
      ValueError: If telemetry_data is None, empty, or lacks metric columns.
  """
  ```

- **Severity:** MEDIUM

---

### 1.8 API: `Initialize-ArcDeployment`

- **Location:** [src/Powershell/core/Initialize-ArcDeployment.ps1](src/Powershell/core/Initialize-ArcDeployment.ps1#L1-L135)
- **Declared Contract:**
  - Source: CmdletBinding attributes, parameter docs
  - Expected Behavior: Prepares Azure environment for Arc deployment
  - Expected Input: `-SubscriptionId`, `-ResourceGroupName`, `-Location` (all mandatory)
  - Expected Output: PSCustomObject with resource group details and Azure context

- **Observed Implementation:**
  - Actual Behavior: Checks Az modules, sets context, creates RG if needed
  - Actual Input Handling: Correct validation
  - Actual Output: Returns correct shape

- **Violation(s):**
  - **LOW:** `-TenantId` parameter documented as used but comment says "Currently informational, actual context switch is complex"

- **Severity:** LOW (documentation accuracy)

---

## 2. Agent Behavior Misalignments

### 2.1 Agent: PredictiveAnalyticsEngine

- **Declared Role (AI-Components.md):** "Orchestrates various AI components to provide higher-level analyses, such as deployment risk assessment."
- **Actual Role (Code):** Orchestrates predictor, pattern analyzer, and remediation learner. Also handles remediation outcome recording.

- **Misalignment:**
  - Engine has accumulated **remediation outcome recording** responsibility (`record_remediation_outcome`, `export_retrain_requests`) which is not documented in AI-Components.md
  - Engine initializes `ArcModelTrainer` but never uses it for training during prediction flow (structural overhead)

- **Impact:**
  - Code has grown beyond documented scope
  - Trainer initialization adds unnecessary overhead for prediction-only flows

- **Recommended Correction:**
  - Short-term: Update AI-Components.md to document remediation integration
  - Longer-term: Consider separating `PredictiveAnalyticsEngine` from `RemediationOrchestrator`

---

### 2.2 Agent: ArcRemediationLearner

- **Declared Role (AI-Components.md Section 8):** "Learns from remediation actions and outcomes. Provides data-driven remediation recommendations."
- **Actual Role (Code):** Learns from remediation, provides recommendations, AND signals retraining needs to trainer

- **Misalignment:**
  - `initialize_ai_components()` method creates its own instances of `ArcModelTrainer` and `ArcPredictor`, duplicating instances that may exist in the parent `PredictiveAnalyticsEngine`
  - Learner directly calls `predictor.predict_failures()` in `get_recommendation()` without ensuring predictor has loaded models

- **Impact:**
  - Potential memory overhead from duplicate component instances
  - Prediction calls in learner may fail if models not loaded

- **Recommended Correction:**
  - Short-term: Accept pre-initialized `predictor` and `trainer` instances in `initialize_ai_components()`
  - Longer-term: Refactor to use dependency injection pattern

---

### 2.3 Agent: PatternAnalyzer

- **Declared Role (AI-Components.md Section 3):** "Identifies various types of patterns in telemetry data, including temporal, behavioral, failure-related, and performance patterns."
- **Actual Role (Code):** Correctly implements pattern analysis. Also generates recommendations.

- **Misalignment:**
  - Pattern analyzer generates `recommendations` list in each pattern type, but this responsibility overlaps with what `PredictiveAnalyticsEngine._generate_recommendations()` does
  - **Documentation gap:** Behavioral pattern analysis uses DBSCAN but doesn't clearly document minimum data requirements

- **Impact:**
  - Recommendations from PatternAnalyzer may be duplicated or conflict with engine-level recommendations
  - Insufficient data for DBSCAN causes silent "no patterns" result

- **Recommended Correction:**
  - Short-term: Document that behavioral patterns require minimum N samples (configurable `dbscan_min_samples`)
  - Longer-term: Consolidate recommendation generation to single point

---

### 2.4 Agent: TelemetryProcessor

- **Declared Role (AI-Components.md Section 2):** "Cleans raw telemetry data, extracts features, detects anomalies and trends."
- **Actual Role (Code):** Matches declared role well.

- **Misalignment:**
  - Minor: `_calculate_derived_features()` creates features like `cpu_to_memory_ratio` but these are not documented in the configuration schema
  - `_flatten_features_for_detection()` is an implementation detail exposed in output but not documented

- **Impact:** Minimal - mostly documentation gaps

- **Recommended Correction:**
  - Update AI-Components.md to list all derived features

---

### 2.5 Agent: Find-IssuePatterns (PowerShell)

- **Declared Role (Comments):** "Finds defined issue patterns in structured input data"
- **Actual Role (Code):** Matches declared role.

- **Misalignment:**
  - **Cross-agent contract issue:** `Find-IssuePatterns` returns `@{IssueId; Severity; SuggestedRemediationId; ...}` but `Start-AIRemediationWorkflow` expects these exact keys without validation
  - Hardcoded patterns (lines 64-175) will be used if no pattern file provided - this fallback behavior is not documented

- **Impact:**
  - If pattern file schema changes, workflow silently fails
  - Users may not realize they're using hardcoded patterns

- **Recommended Correction:**
  - Add explicit output schema documentation
  - Log when using hardcoded fallback patterns

---

## 3. Data Contract Violations

### 3.1 Entity: Telemetry Data

- **Canonical Definition Location:** [src/config/ai_config.json](src/config/ai_config.json#L58-L90) (`model_config.features`)
- **Expected Shape:**
  ```json
  {
    "health_prediction": ["cpu_usage", "memory_usage", "disk_usage", "network_latency", "error_count", "warning_count"],
    "anomaly_detection": ["cpu_usage", "memory_usage", "disk_usage", "network_latency", "request_count", "response_time"],
    "failure_prediction": ["service_restarts", "error_count", "cpu_spikes", "memory_spikes", "connection_drops"]
  }
  ```

- **Observed Variants:**
  - Location: [src/Python/analysis/telemetry_processor.py](src/Python/analysis/telemetry_processor.py#L44-L55)
    - Shape:
      ```python
      expected_metric_cols = {
          'cpu_usage', 'cpu_usage_avg',
          'memory_usage', 'memory_usage_avg',
          'disk_usage', 'disk_io_avg',
          # ... more variants
      }
      ```
    - Issue: TelemetryProcessor accepts `cpu_usage_avg` but predictor requires `cpu_usage`

  - Location: [src/Powershell/core/Start-ArcDiagnostics.ps1](src/Powershell/core/Start-ArcDiagnostics.ps1#L53-L91) (test data)
    - Shape: `@{ CPU = @{ LoadPercentage = 10 }; Memory = @{ AvailableGB = 16 } }`
    - Issue: Nested structure with different key names (`LoadPercentage` vs `cpu_usage`)

- **Risks:**
  - Runtime errors when TelemetryProcessor output fed to Predictor without feature name alignment
  - PowerShell test data incompatible with Python expectation

- **Recommended Normalization:**
  1. Define single source of truth for feature names in `ai_config.json`
  2. Add feature name mapping/aliasing in TelemetryProcessor
  3. Update PowerShell test data to match canonical feature names

---

### 3.2 Entity: Prediction Response

- **Canonical Definition Location:** [src/Python/predictive/predictor.py](src/Python/predictive/predictor.py#L166-L173) (implicit)
- **Expected Shape:**
  ```python
  {
      "prediction": {
          "healthy_probability": float,  # 0.0-1.0
          "unhealthy_probability": float
      },
      "feature_impacts": Dict[str, float],
      "timestamp": str  # ISO format
  }
  ```

- **Observed Variants:**
  - Location: [predictor.py](src/Python/predictive/predictor.py#L126-L132) (error case)
    - Shape:
      ```python
      {
          "error": "ModelNotLoaded",
          "model_type": str,
          "message": str,
          "details": Optional[str],
          "timestamp": str
      }
      ```
    - Issue: Success and error responses have completely different shapes

  - Location: [predictive_analytics_engine.py](src/Python/predictive/predictive_analytics_engine.py#L77-L78)
    - Shape: Assumes `health['prediction']['healthy_probability']` always exists
    - Issue: Crashes on error dict response

- **Risks:**
  - Consumers must check for `"error"` key before accessing prediction fields
  - No TypedDict or schema enforcement

- **Recommended Normalization:**
  ```python
  # Define canonical response types:
  @dataclass
  class PredictionSuccess:
      prediction: Dict[str, float]
      feature_impacts: Dict[str, float]
      timestamp: str
      error: None = None
  
  @dataclass  
  class PredictionError:
      error: str
      message: str
      model_type: str
      timestamp: str
      prediction: None = None
  ```

---

### 3.3 Entity: Diagnostic Results (PowerShell)

- **Canonical Definition Location:** [Start-ArcDiagnostics.ps1](src/Powershell/core/Start-ArcDiagnostics.ps1#L33-L43)
- **Expected Shape:**
  ```powershell
  @{
      Timestamp = [datetime]
      ServerName = [string]
      SystemState = @{}
      ArcStatus = @{}
      AMAStatus = @{}
      Connectivity = @{}
      Logs = @{}
      DetailedAnalysis = @{}
  }
  ```

- **Observed Variants:**
  - Test mode (line 53-96) provides all keys with mock data
  - Production mode calls stub functions that throw, leaving keys empty/undefined

- **Risks:**
  - Downstream consumers may receive incomplete objects in production
  - No schema validation before output

- **Recommended Normalization:**
  - Add `[OutputType([PSCustomObject])]` attribute
  - Initialize all keys to `$null` or empty hashtable before processing
  - Document required vs optional fields

---

### 3.4 Entity: Issue Pattern (PowerShell → Remediation)

- **Canonical Definition Location:** [Find-IssuePatterns.ps1](src/Powershell/remediation/Find-IssuePatterns.ps1#L64-L175) (hardcoded)
- **Expected Shape:**
  ```powershell
  @{
      IssueId = [string]
      Description = [string]
      DataSignatures = @(
          @{ Property = [string]; Operator = [string]; Value = [any] }
      )
      Severity = [string]  # "High", "Medium", "Low"
      SuggestedRemediationId = [string]
  }
  ```

- **Observed Variants:**
  - JSON file format (line 51-58) expects root key `issuePatterns`
  - Hardcoded patterns use exact same shape

- **Risks:**
  - If JSON file missing `issuePatterns` key, warning logged but empty patterns used
  - No validation of `Operator` values against supported set

- **Recommended Normalization:**
  - Document supported operators: `Equals`, `Contains`, `StartsWith`, `EndsWith`, `MatchesRegex`, `LessThan`, `GreaterThan`, `LessThanOrEqual`, `GreaterThanOrEqual`
  - Add JSON schema file for pattern definitions

---

### 3.5 Entity: AI Config (`ai_config.json`)

- **Canonical Definition Location:** [src/config/ai_config.json](src/config/ai_config.json)
- **Expected Shape:**
  ```json
  {
      "aiComponents": {
          "predictionEngine": {...},
          "monitoring": {...},
          "feature_engineering": {...},
          "model_config": {
              "features": {...},
              "models": {...}
          }
      }
  }
  ```

- **Observed Variants:**
  - [invoke_ai_engine.py](src/Python/invoke_ai_engine.py#L81-L83): Requires `aiComponents` key, raises ValueError if missing
  - [PredictiveAnalyticsEngine](src/Python/predictive/predictive_analytics_engine.py#L38-L48): Accepts either `aiComponents` subtree OR direct config with `features`/`models`
  - [ArcRemediationLearner](src/Python/predictive/ArcRemediationLearner.py#L53-L58): Same flexible parsing

- **Risks:**
  - Inconsistent config parsing across components
  - Some components accept partial config, others require full structure

- **Recommended Normalization:**
  - Centralize config parsing in a single utility function
  - Document required vs optional config sections per component

---

### 3.6 Entity: Remediation Outcome Payload

- **Canonical Definition Location:** Not explicitly defined
- **Expected Shape (inferred from ArcRemediationLearner.learn_from_remediation):**
  ```python
  {
      "error_type": str,
      "action": str,
      "outcome": bool | str,  # True or "success"
      "context": Dict[str, Any]  # Optional
  }
  ```

- **Observed Usage:**
  - [invoke_ai_engine.py](src/Python/invoke_ai_engine.py#L119-L127): Accepts `--remediationoutcomejson` argument
  - [Start-AIRemediationWorkflow.ps1](src/Powershell/AI/Start-AIRemediationWorkflow.ps1#L127-L130): Builds payload with same keys

- **Risks:**
  - No schema validation on either side
  - PowerShell may send different key names than Python expects

- **Recommended Normalization:**
  - Define JSON schema for remediation outcome
  - Validate payload before processing in `learn_from_remediation`

---

## 4. Edge Case Handling Issues

### 4.1 Empty Model Directory

- **Location:** [src/Python/run_predictor.py](src/Python/run_predictor.py#L56-L60)
- **Scenario:** Model directory exists but contains no `.pkl` files
- **Expected Behavior:** Clear error with guidance to train models
- **Actual Behavior:** Returns `{"error": "..."}` to stdout and returns normally (exit code 0)
- **Problem:** Caller (PowerShell) may not detect failure if only checking exit code
- **Suggested Fix:**
  ```python
  # Before:
  print(json.dumps(output_results), flush=True)
  return
  
  # After:
  print(json.dumps(output_results), file=sys.stderr, flush=True)
  sys.exit(1)
  ```
- **Severity:** HIGH

---

### 4.2 Missing Required Features in Telemetry

- **Location:** [src/Python/predictive/predictor.py](src/Python/predictive/predictor.py#L275-L285)
- **Scenario:** Telemetry data missing features required by model
- **Expected Behavior:** Clear error or documented default behavior
- **Actual Behavior:** Silently uses 0.0 for missing features with only warning log
- **Problem:** Predictions may be meaningless with many 0.0 values
- **Suggested Fix:**
  ```python
  # After prepare_features:
  missing_count = sum(1 for f in ordered_feature_names if f not in telemetry_data)
  if missing_count > len(ordered_feature_names) * 0.5:
      self.logger.error(f"More than 50% of features missing for {model_type}.")
      return {"error": "InsufficientFeatures", "message": f"{missing_count}/{len(ordered_feature_names)} features missing"}
  ```
- **Severity:** MEDIUM

---

### 4.3 Python Process Crash During PowerShell Call

- **Location:** [src/Powershell/AI/Get-PredictiveInsights.ps1](src/Powershell/AI/Get-PredictiveInsights.ps1#L116-L137)
- **Scenario:** Python process crashes or hangs
- **Expected Behavior:** Timeout and clear error
- **Actual Behavior:** No timeout; `Start-Process -Wait` blocks indefinitely
- **Problem:** PowerShell caller can hang forever
- **Suggested Fix:**
  ```powershell
  # After (add timeout):
  $process = Start-Process -FilePath $PythonExecutable -ArgumentList $arguments -Wait -NoNewWindow -PassThru -RedirectStandardOutput "stdout.txt" -RedirectStandardError "stderr.txt" -ErrorAction Stop
  
  # Better approach with timeout:
  $timeoutSeconds = 120
  $process = Start-Process ... -PassThru
  $completed = $process.WaitForExit($timeoutSeconds * 1000)
  if (-not $completed) {
      $process.Kill()
      throw "AI Engine timed out after $timeoutSeconds seconds"
  }
  ```
- **Severity:** HIGH

---

### 4.4 Invalid JSON in PowerShell-Python Bridge

- **Location:** [src/Python/invoke_ai_engine.py](src/Python/invoke_ai_engine.py#L91-L99)
- **Scenario:** `--serverdatajson` contains invalid JSON
- **Expected Behavior:** Clear error in consistent format
- **Actual Behavior:** Prints error JSON to stderr and exits with code 1 ✓
- **Problem:** None - correctly handled
- **Severity:** N/A (compliant)

---

### 4.5 Concurrent Model Training and Prediction

- **Location:** [src/Python/predictive/model_trainer.py](src/Python/predictive/model_trainer.py) and [predictor.py](src/Python/predictive/predictor.py)
- **Scenario:** Model files being written while predictor attempts to load
- **Expected Behavior:** Either atomic writes or read retry
- **Actual Behavior:** No locking; joblib.load may fail with corrupted file
- **Problem:** Race condition in production deployment
- **Suggested Fix:**
  ```python
  # In ArcModelTrainer.save_models:
  import tempfile
  import shutil
  
  # Write to temp file then atomic rename
  with tempfile.NamedTemporaryFile(delete=False, suffix='.pkl') as tmp:
      joblib.dump(model, tmp.name)
      shutil.move(tmp.name, final_path)
  ```
- **Severity:** MEDIUM (production hardening)

---

### 4.6 Config File Not Found

- **Location:** [src/Python/invoke_ai_engine.py](src/Python/invoke_ai_engine.py#L76-L77)
- **Scenario:** `ai_config.json` missing or unreadable
- **Expected Behavior:** Clear error
- **Actual Behavior:** Raises `FileNotFoundError` with path, caught by outer exception handler
- **Problem:** Error message is clear but exit handling is correct ✓
- **Severity:** N/A (compliant)

---

### 4.7 Empty Pattern Analysis Results

- **Location:** [src/Python/analysis/pattern_analyzer.py](src/Python/analysis/pattern_analyzer.py#L60-L76)
- **Scenario:** Single data point provided for temporal analysis
- **Expected Behavior:** Graceful empty result with explanation
- **Actual Behavior:** Returns empty dicts like `{"peak_hours": {}, "seasonality_strength": {}}`
- **Problem:** No indication to caller why results are empty
- **Suggested Fix:**
  ```python
  # Add data sufficiency check:
  if len(df) < self.config.get('min_samples_for_patterns', 10):
      return {
          "peak_hours": {},
          "seasonality_strength": {},
          "recommendations": [],
          "warning": f"Insufficient data points ({len(df)}). Need at least 10 for pattern analysis."
      }
  ```
- **Severity:** LOW

---

### 4.8 AzureArcFramework Module Import Failure

- **Location:** [src/Powershell/AzureArcFramework.psm1](src/Powershell/AzureArcFramework.psm1#L26-L28)
- **Scenario:** `ai_config.json` missing at module load
- **Expected Behavior:** Module refuses to load with clear error
- **Actual Behavior:** Throws exception with message "Critical configuration file ai_config.json not found"
- **Problem:** Correct behavior ✓
- **Severity:** N/A (compliant)

---

### 4.9 Remediation Learner Without Models

- **Location:** [src/Python/predictive/ArcRemediationLearner.py](src/Python/predictive/ArcRemediationLearner.py#L159-L175)
- **Scenario:** `get_recommendation` called before `initialize_ai_components`
- **Expected Behavior:** Graceful fallback to pattern-based recommendations only
- **Actual Behavior:** If `self.predictor` is None, AI prediction section is skipped ✓
- **Problem:** Minor - could log warning when predictor unavailable
- **Severity:** LOW

---

## 5. Cross-Module Contract Breaks

### 5.1 Chain: PowerShell `Get-PredictiveInsights` → Python `invoke_ai_engine.py` → `PredictiveAnalyticsEngine`

- **Contract Expectations:**
  - At Entry: ServerName string, AnalysisType enum, valid Python environment
  - At Exit: JSON object parseable by PowerShell with prediction fields

- **Observed Behavior:**
  1. PS validates params, finds Python, builds argument list
  2. Python parses args, loads config from `ai_config.json`
  3. Python synthesizes minimal `server_data` if not provided
  4. Engine calls predictor methods, assumes models loaded
  5. Engine calculates risk scores using prediction dict fields
  6. JSON output returned to PS

- **Break Points:**
  - [invoke_ai_engine.py:143](src/Python/invoke_ai_engine.py#L143) – `analyze_deployment_risk` ignores `analysistype` argument
  - [predictive_analytics_engine.py:80-86](src/Python/predictive/predictive_analytics_engine.py#L80-L86) – Assumes `health['prediction']` exists; crashes on error dict
  - [Get-PredictiveInsights.ps1:160](src/Powershell/AI/Get-PredictiveInsights.ps1#L160) – No timeout on `Start-Process -Wait`

- **Consequences:**
  - User-specified analysis type has no effect
  - Model load failures cause engine crash instead of graceful error
  - PS can hang indefinitely

- **Recommended Fix:**
  1. Route `analysistype` to specific predictor methods in invoke_ai_engine.py
  2. Add defensive checks before accessing nested prediction keys
  3. Add timeout to PS process invocation

---

### 5.2 Chain: `Start-ArcDiagnostics` → Stub Functions → Diagnostic Results

- **Contract Expectations:**
  - At Entry: ServerName, optional WorkspaceId
  - At Exit: Complete diagnostic object with all sections populated

- **Observed Behavior:**
  1. PS initializes result hashtable with all expected keys
  2. PS calls `Get-SystemState -ServerName $ServerName`
  3. Stub function throws `NotImplementedError`
  4. Exception propagates, entire diagnostic fails

- **Break Points:**
  - [AzureArcFramework.psm1:130](src/Powershell/AzureArcFramework.psm1#L130) – `Get-SystemState` stub throws
  - All 24 stub functions in same file

- **Consequences:**
  - Function completely unusable without test mode flag
  - No partial results returned

- **Recommended Fix:**
  1. Wrap each stub call in try/catch with graceful fallback
  2. Implement minimum viable stubs that return empty data structures
  3. Add `-Strict` switch to control throw vs warn behavior

---

### 5.3 Chain: `ArcRemediationLearner.learn_from_remediation` → `ArcModelTrainer.update_models_with_remediation` → Retrain Trigger

- **Contract Expectations:**
  - At Entry: Remediation outcome dict with error_type, action, outcome
  - At Exit: Success patterns updated, trainer notified, retrain threshold checked

- **Observed Behavior:**
  1. Learner extracts fields from remediation dict
  2. Learner updates `success_patterns` dictionary
  3. Learner calls `trainer.update_models_with_remediation(remediation_data)`
  4. Trainer logs receipt but **does nothing** with data (placeholder)
  5. Learner checks retrain threshold and logs message

- **Break Points:**
  - [model_trainer.py:319-372](src/Python/predictive/model_trainer.py#L319-L372) – `update_models_with_remediation` is placeholder that returns generic response
  - Learner relies on trainer response but trainer always says "noted"

- **Consequences:**
  - Remediation data never actually used to improve models
  - Retrain threshold triggers log message but no actual retraining

- **Recommended Fix:**
  1. Document that trainer method is placeholder in docstring
  2. Add configuration option to enable actual incremental training
  3. Consider queue-based approach: learner writes to file, separate training job processes

---

### 5.4 Chain: `Find-IssuePatterns` → `Get-RemediationAction` → `Start-RemediationAction`

- **Contract Expectations:**
  - At Entry: InputData array, optional pattern definitions path
  - Intermediate: Patterns with `SuggestedRemediationId` field
  - At Exit: Remediation actions executed with results

- **Observed Behavior:**
  1. `Find-IssuePatterns` matches data against pattern signatures
  2. Returns array of matched patterns with `IssueId` and `SuggestedRemediationId`
  3. `Get-RemediationAction` (implied, not directly visible) looks up action by ID
  4. `Start-RemediationAction` executes the action

- **Break Points:**
  - Pattern output shape implicitly assumed by workflow
  - No validation that `SuggestedRemediationId` maps to valid action
  - `Start-RemediationAction` not fully implemented (per Phase 1)

- **Consequences:**
  - Invalid remediation IDs cause silent failures
  - Action execution may not actually remediate

- **Recommended Fix:**
  1. Add schema validation for pattern output
  2. Validate remediation ID exists before attempting action
  3. Return clear error when action not found

---

## 6. Severity & Prioritization Summary

### Critical (7 violations)
| ID | Description | Location |
|----|-------------|----------|
| API-1.1 | `-AnalysisType` parameter ignored | Get-PredictiveInsights ↔ invoke_ai_engine |
| API-1.3 | Start-ArcDiagnostics calls 24 stubs | Start-ArcDiagnostics.ps1 |
| XM-5.1 | analyze_deployment_risk crashes on model error | predictive_analytics_engine.py:80 |
| XM-5.2 | Diagnostic chain completely broken by stubs | AzureArcFramework.psm1 stubs |
| DM-3.1 | Telemetry feature name mismatch | TelemetryProcessor vs Predictor |
| DM-3.2 | Prediction error/success dict shape inconsistency | predictor.py |
| EC-4.1 | run_predictor returns exit 0 on error | run_predictor.py:56 |

### High (12 violations)
| ID | Description | Location |
|----|-------------|----------|
| API-1.1b | Undocumented output keys | Get-PredictiveInsights |
| API-1.2 | run_predictor error dict instead of exit code | run_predictor.py |
| API-1.3b | No fallback on stub throws | Start-ArcDiagnostics.ps1 |
| API-1.4 | _calculate_overall_risk crashes on error | predictive_analytics_engine.py |
| API-1.5 | Inconsistent raise vs return error | predictor.py |
| AG-2.1 | Engine accumulated undocumented responsibilities | PredictiveAnalyticsEngine |
| AG-2.2 | Learner creates duplicate component instances | ArcRemediationLearner |
| EC-4.2 | Missing features silently defaulted to 0.0 | predictor.py:275 |
| EC-4.3 | No timeout on Python process | Get-PredictiveInsights.ps1:116 |
| EC-4.5 | Race condition on model file access | model_trainer/predictor |
| XM-5.1b | analysistype not routed to methods | invoke_ai_engine.py |
| XM-5.3 | Trainer update method is placeholder | model_trainer.py:319 |

### Medium (12 violations)
| ID | Description | Location |
|----|-------------|----------|
| API-1.2b | No feature validation before prediction | run_predictor.py |
| API-1.4b | No input schema validation | predictive_analytics_engine.py |
| API-1.6a | Duplicate parameter definition | Start-AIRemediationWorkflow.ps1 |
| API-1.6b | Internal Write-Log shadows module function | Start-AIRemediationWorkflow.ps1 |
| API-1.7 | Docstring mismatches input type | telemetry_processor.py |
| AG-2.3 | Recommendation generation overlap | PatternAnalyzer ↔ Engine |
| DM-3.3 | Diagnostic results incomplete in production | Start-ArcDiagnostics.ps1 |
| DM-3.4 | Issue pattern operators not documented | Find-IssuePatterns.ps1 |
| DM-3.5 | Config parsing inconsistent | Multiple components |
| DM-3.6 | Remediation payload schema undefined | learner ↔ engine |
| EC-4.5 | No atomic model writes | model_trainer.py |
| XM-5.4 | No validation of remediation IDs | Remediation chain |

---

## 7. Standardized Contract Decisions

Based on this audit, the following contracts should be formalized:

### API Contract Conventions
1. **Error Responses:** All Python functions should return `{"error": str, "message": str, "timestamp": str}` on failure; CLI entry points should also exit with non-zero code
2. **Success Responses:** Include `timestamp` field for traceability
3. **Parameter Routing:** CLI parameters must demonstrably affect behavior or be removed

### Agent Responsibilities & Boundaries
1. **PredictiveAnalyticsEngine:** Orchestration only; no direct model interaction beyond predictor calls
2. **ArcRemediationLearner:** Learning and recommendation; delegates prediction to injected predictor
3. **Single Responsibility:** Each agent handles one concern; avoid accumulating unrelated methods

### Canonical Data Models
1. **Telemetry Features:** Canonical names defined in `ai_config.json`; all processors must output these names
2. **Prediction Response:** TypedDict/dataclass with union type for success/error
3. **Diagnostic Results:** All keys initialized before processing; missing data marked as `@{Status='NotAvailable'}`

### Error Semantics & Edge-Case Policy
1. **Python CLI:** Exit code 1 on any error; error JSON to stderr
2. **PowerShell Functions:** Use `-ErrorAction Stop` internally; wrap with try/catch at caller's discretion
3. **Timeouts:** All cross-process calls must have configurable timeout (default 120s)
4. **Missing Features:** Log warning, use 0.0, but fail if >50% missing

---

## Appendix: Integration with Phase 1-2 Findings

| Phase 3 Finding | Related Phase 1/2 Issue |
|-----------------|------------------------|
| Stub functions breaking diagnostics | Phase 1 Section 1.2 (24 stubs) |
| Missing common/*.py files | Phase 1 Section 1.1 (broken imports) |
| Inconsistent error handling | Phase 2 Section 2 (error patterns) |
| File naming (RootCauseAnalyzer.py) | Phase 2 Section 1 (NC-1) |
| Empty catch blocks | Phase 2 Section 2 (EH-1) |
| Duplicate Write-Log | Phase 2 Section 6 (LG-1) |

---

*Report generated as part of VIBE Audit Phase 3 - Behavioral & Contract Integrity Analysis*

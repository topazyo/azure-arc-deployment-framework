# CLI Reference - Azure Arc Predictive Toolkit

This document provides formal documentation for all command-line interfaces in the Azure Arc Predictive Toolkit.

## Overview

The toolkit provides two primary Python CLI entry points:

| CLI | Purpose | Primary Caller |
|-----|---------|----------------|
| `invoke_ai_engine.py` | Full predictive analytics (risk scoring, patterns, predictions) | `Get-PredictiveInsights.ps1` |
| `run_predictor.py` | Direct model prediction (inference only) | Direct use or PowerShell scripts |

---

## invoke_ai_engine.py

**Location:** `src/Python/invoke_ai_engine.py`

**Purpose:** Main AI engine interface providing comprehensive predictive analytics including risk scoring, pattern analysis, anomaly detection, and failure prediction.

### Synopsis

```bash
python invoke_ai_engine.py --servername <name> [options]
```

### Required Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `--servername` | string | **REQUIRED.** Name/ID of the server to analyze. Used for identification in results and logging. |

### Optional Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `--analysistype` | choice | `Full` | Type of analysis: `Full`, `Health`, `Failure`, `Anomaly` |
| `--serverdatajson` | JSON string | `{}` | Server telemetry data as JSON string |
| `--remediationoutcomejson` | JSON string | None | Feedback from remediation actions for learning |
| `--configpath` | path | `src/config/ai_config.json` | Path to AI configuration file |
| `--modeldir` | path | `src/Python/models_placeholder` | Directory containing model artifacts |

### Analysis Types

- **Full**: Complete analysis including health, failure prediction, and anomaly detection
- **Health**: Health assessment and risk scoring only
- **Failure**: Failure prediction and failure pattern analysis
- **Anomaly**: Anomaly detection focused analysis

### Input JSON Schema

#### --serverdatajson

```json
{
  "server_name_id": "server-001",
  "timestamp": "2024-01-15T10:30:00.000000",
  "cpu_usage": 0.75,
  "memory_usage": 0.60,
  "disk_usage": 0.45,
  "network_latency": 50,
  "error_count": 2,
  "warning_count": 5,
  "service_restarts": 0,
  "cpu_spikes": 1,
  "memory_spikes": 0,
  "connection_drops": 0,
  "request_count": 1000,
  "response_time": 150
}
```

**Notes:**
- `server_name_id` is strongly recommended but not strictly required
- `timestamp` should be ISO 8601 format
- Metric values should be normalized (0.0-1.0) for percentages
- Extra fields are tolerated for forward compatibility
- Missing numeric fields default to 0.0

#### --remediationoutcomejson

```json
{
  "remediation_id": "REM-001",
  "original_issue": "high_cpu",
  "action_taken": "restart_service",
  "success": true,
  "impact_metrics": {
    "cpu_usage_before": 0.95,
    "cpu_usage_after": 0.45
  }
}
```

### Output JSON Schema

#### Success Response (stdout)

```json
{
  "input_servername": "server-001",
  "input_analysistype": "Full",
  "risk_score": 0.35,
  "risk_level": "medium",
  "timestamp": "2024-01-15T10:30:15.123456",
  "predictions": {
    "failure_probability": 0.15,
    "predicted_failures": [],
    "confidence": 0.85
  },
  "anomalies": {
    "detected": true,
    "anomaly_score": 0.42,
    "anomalous_features": ["cpu_usage", "memory_spikes"]
  },
  "recommendations": [
    {
      "priority": "medium",
      "action": "Monitor CPU usage trends",
      "reason": "Elevated CPU spike count detected"
    }
  ],
  "patterns": {
    "behavior_patterns": [],
    "performance_patterns": [],
    "failure_patterns": []
  }
}
```

#### Error Response (stderr)

```json
{
  "error": "ConfigurationError",
  "message": "Configuration file not found at /path/to/config.json",
  "timestamp": "2024-01-15T10:30:15.123456",
  "details": {
    "config_path": "/path/to/config.json"
  }
}
```

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error (check stderr for JSON error details) |
| 2 | Argument parsing error |

### Examples

```bash
# Basic usage with server name only
python invoke_ai_engine.py --servername "prod-server-01"

# Full analysis with telemetry data
python invoke_ai_engine.py \
  --servername "prod-server-01" \
  --analysistype Full \
  --serverdatajson '{"cpu_usage": 0.75, "memory_usage": 0.60}'

# Custom config and model directory
python invoke_ai_engine.py \
  --servername "prod-server-01" \
  --configpath "/etc/arc/ai_config.json" \
  --modeldir "/var/lib/arc/models"
```

---

## run_predictor.py

**Location:** `src/Python/run_predictor.py`

**Purpose:** Direct interface to ArcPredictor for model inference. Use this for lightweight predictions without the full analytics pipeline.

### Synopsis

```bash
python run_predictor.py --server-name <name> --telemetrydatajson <json> [options]
```

### Required Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `--server-name` | string | **REQUIRED.** Name/ID of the server for prediction |
| `--telemetrydatajson` | JSON string | **REQUIRED.** Telemetry data for prediction |

### Optional Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `--analysis-type` | choice | `Full` | Type: `Full`, `Health`, `Failure`, `Anomaly` |
| `--model-dir` | path | `data/models/latest` | Directory with model artifacts |
| `--config-path` | path | `src/config/ai_config.json` | Path to AI configuration |

### Input JSON Schema

#### --telemetrydatajson

```json
{
  "cpu_usage": 0.75,
  "memory_usage": 0.60,
  "disk_usage": 0.45,
  "network_latency": 50,
  "error_count": 2,
  "warning_count": 5,
  "service_restarts": 0,
  "request_count": 1000,
  "response_time": 150
}
```

**Notes:**
- Features must match those defined in `ai_config.json` for the target model
- Missing features are filled with 0.0 or per-model `missing_strategy`
- Feature order is normalized using saved `feature_info` metadata

### Output JSON Schema

#### Success Response (stdout)

```json
{
  "server_name": "server-001",
  "analysis_type": "Health",
  "timestamp": "2024-01-15T10:30:15.123456",
  "predictions": {
    "health_prediction": 1,
    "confidence": 0.92,
    "probabilities": [0.08, 0.92]
  }
}
```

#### Error Response (stdout)

```json
{
  "error": "Model artifacts not found",
  "model_dir": "/path/to/models",
  "details": "Missing health_prediction_model.pkl"
}
```

### Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success (includes structured error with "error" field) |
| 1 | Fatal error or argument parsing error |

### Examples

```bash
# Basic health prediction
python run_predictor.py \
  --server-name "prod-server-01" \
  --telemetrydatajson '{"cpu_usage": 0.75, "memory_usage": 0.60}'

# Failure prediction with custom model directory
python run_predictor.py \
  --server-name "prod-server-01" \
  --analysis-type Failure \
  --model-dir "/var/lib/arc/models/production" \
  --telemetrydatajson '{"cpu_usage": 0.95, "error_count": 15}'
```

---

## PowerShell Integration

### Get-PredictiveInsights

**Location:** `src/Powershell/Predictive/Get-PredictiveInsights.ps1`

**Purpose:** PowerShell wrapper that calls `invoke_ai_engine.py` and returns structured results.

### Synopsis

```powershell
Get-PredictiveInsights -ServerName <string> [-AnalysisType <string>] [-ServerData <hashtable>]
```

### Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `-ServerName` | string | Yes | Target server name |
| `-AnalysisType` | string | No | Full, Health, Failure, or Anomaly |
| `-ServerData` | hashtable | No | Telemetry data as PowerShell hashtable |

### Example

```powershell
# Get full predictive insights
$insights = Get-PredictiveInsights -ServerName "server-001" -AnalysisType "Full" -ServerData @{
    cpu_usage = 0.75
    memory_usage = 0.60
    error_count = 2
}

# Access results
$insights.risk_score
$insights.recommendations
```

---

## Configuration Reference

See `ai_config.json` for detailed configuration of:
- Feature definitions per model type
- Model hyperparameters
- Analysis thresholds
- Pattern analyzer settings

JSON Schema available at: `src/config/schemas/ai_config.schema.json`

---

## Contract Guarantees

These contracts are enforced by tests in `tests/Python/test_cli_contracts.py`:

1. **JSON Output**: All outputs are valid JSON
2. **Error Structure**: Errors include `error` and `message` fields
3. **Timestamp Format**: All timestamps are ISO 8601
4. **Exit Codes**: Predictable exit codes for PowerShell branching
5. **Parameter Stability**: CLI parameters are backwards-compatible
6. **Forward Compatibility**: Extra input fields are tolerated

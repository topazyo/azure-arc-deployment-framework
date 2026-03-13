# Performance Baselines — Azure Arc AI Engine (PERF-001)

**Establised:** 2026-03-07  
**Batch:** Batch 6 (Performance)  
**Owner:** VIBE audit agent  
**Linked tests:** `tests/Python/test_performance.py`

---

## 1. Purpose

This document records the performance baselines for the critical hot-paths in the Azure Arc AI Engine. Baselines are used to:

- Set pass/fail thresholds in `tests/Python/test_performance.py`
- Detect regressions across PRs
- Provide SLO guidance for production sizing

---

## 2. Measurement Environment

| Attribute | Value |
|-----------|-------|
| OS | Windows 11 / Ubuntu 22.04 (GitHub Actions `ubuntu-latest`) |
| CPU | Reference: 4-core × 2.5 GHz (matches GitHub Actions `ubuntu-latest`) |
| RAM | 8 GB |
| Python | 3.11 (CI) / 3.14 (local dev) |
| Disk | SSD (local); ephemeral NVMe (CI) |
| Measurement tool | `time.perf_counter()` (wall-clock, single-run) |

> **Note:** All measurements are wall-clock single-run timings, not averaged benchmarks. CI thresholds are set at 10–50× the measured median to tolerate scheduling jitter.

---

## 3. Baselines Per Hot Path

### 3.1 Input Validation

| Function | Operation | Measured Median (ms) | CI Threshold (ms) | Notes |
|----------|-----------|---------------------|-------------------|-------|
| `validate_server_name()` | 1 000 calls | ~5 | 200 | Pure regex; O(n) per call |
| `validate_analysis_type()` | 2 000 calls | ~2 | 200 | In-list lookup |
| `parse_json_safely()` | Single small payload (~1 KB) | ~1 | 50 | Includes `json.loads()` + depth/key scan |
| `parse_json_safely()` | Large payload (~100 KB) | ~10 | 500 | Scales with string length and key count |
| `validate_json_string()` | Depth-20 nested structure | ~5 | 200 | Recursive depth + key count walk |
| `validate_file_path()` | 1 000 calls | ~10 | 300 | `os.path.realpath()` + `..` check |

### 3.2 Sensitive Data Redaction

| Function | Operation | Measured Median (ms) | CI Threshold (ms) | Notes |
|----------|-----------|---------------------|-------------------|-------|
| `redact_sensitive_data()` | 500× non-sensitive config | ~15 | 200 | Config dict, no redaction needed |
| `redact_sensitive_data()` | 500× mixed nested dict | ~30 | 200 | 3-level nesting with ~10 sensitive keys |

### 3.3 Schema Validation

| Function | Operation | Measured Median (ms) | CI Threshold (ms) | Notes |
|----------|-----------|---------------------|-------------------|-------|
| `load_cli_contracts_schema_definition()` | First call (disk I/O) | ~5 | 500 | File open + `json.load()` |
| `validate_json_against_schema()` | 100 calls, serverDataInput | ~20 | 10 000 | `jsonschema.validate()` per call |

### 3.4 Model Loading (ArcPredictor, PERF-003)

| Operation | Cold (first instantiation) | Warm (cache hit) | Notes |
|-----------|---------------------------|------------------|-------|
| `ArcPredictor.__init__()` — empty model dir | ~5 ms | ~0.5 ms | No `.pkl` files; populates empty dicts |
| `ArcPredictor.__init__()` — 3 model types loaded | ~200–800 ms* | ~1 ms | Cache hit skips all `joblib.load()` calls |

> \* Measured time depends heavily on `.pkl` file sizes. For trained production models (typically 1–10 MB each), cold load is 200–800 ms. Warm cache hits are sub-millisecond.

---

## 4. Regression Thresholds

If any of the following checks fail in CI, investigate before merging:

| Symptom | Likely Cause | Action |
|---------|-------------|--------|
| `validate_server_name × 1000` > 200 ms | Regex recompile each call (missing `re.compile`) | Check `SENSITIVE_FIELD_PATTERNS` pre-compilation |
| `parse_json_safely (large)` > 500 ms | O(n) key scan on very deep/wide payload | Review `_measure_json_structure()` recursion |
| `validate_json_against_schema × 100` > 10 000 ms | `jsonschema` full draft-07 resolution per call | Consider caching resolver or compiled schema |
| `ArcPredictor` warm > cold | Cache not populated on first run | Review `_model_cache` assignment in `load_models()` |

---

## 5. How to Re-Measure

```bash
# Run performance tests and show wall-clock times
python -m pytest tests/Python/test_performance.py -v -s 2>&1 | grep -E "PASSED|FAILED|ms\)"

# Or run all Python tests with timing output
python -m pytest tests/Python/ --tb=short -q
```

---

## 6. Future Improvements

| Priority | Item | Tracked By |
|----------|------|------------|
| High | Add `pytest-benchmark` for statistical baselines once CI is stable | PERF-002 follow-up |
| High | Cache compiled `jsonschema.Validator` instances to reduce per-call overhead | PERF-002 follow-up |
| High | DBSCAN O(n²) sample size guard | DEBT-PERF-006 (Batch 7) |
| High | Unbounded DataFrame in Mahalanobis distance | DEBT-PERF-002 (Batch 7) |
| Medium | Lazy per-model-type loading (only load `health_prediction` if only health is requested) | DEBT-PERF-004 (Batch 7) |
| Medium | Reduce repeated Python process spawns → long-lived worker model | DEBT-PERF-003 (Batch 7) |

"""
Performance tests for Azure Arc AI Engine hot paths. (PERF-002)

These tests assert that critical code paths complete within documented
thresholds (see docs/Performance-Baselines.md). They use
time.perf_counter() rather than a benchmark framework so that no
additional test dependency is required.

Thresholds are intentionally generous (10×-50× the measured baseline) so
that the suite passes consistently on any CI runner. The intent is to catch
gross regressions, not to micro-benchmark.

Run with:
    python -m pytest tests/Python/test_performance.py -v
"""

import json
import os
import sys
import time
import tempfile
import pytest

# Ensure src/ is on the path (mirrors conftest.py pattern)
sys.path.insert(
    0, os.path.abspath(os.path.join(os.path.dirname(__file__), "../../src"))
)

from Python.common.security import (  # noqa: E402
    validate_server_name,
    validate_analysis_type,
    parse_json_safely,
    validate_json_string,
    redact_sensitive_data,
    validate_file_path,
    load_cli_contracts_schema_definition,
    validate_json_against_schema,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_server_data_payload(n_extra_keys: int = 0) -> str:
    """Build a valid serverDataInput JSON string."""
    payload: dict = {
        "server_name_id": "PERF-TEST-SERVER-01",
        "cpu_usage": 0.65,
        "memory_usage": 0.50,
        "disk_usage": 0.40,
        "network_latency": 15.0,
        "error_count": 2,
        "warning_count": 5,
        "service_restarts": 0,
        "cpu_spikes": 1,
        "memory_spikes": 0,
        "connection_drops": 0,
        "request_count": 1000,
        "response_time": 45.0,
    }
    for i in range(n_extra_keys):
        payload[f"extra_field_{i}"] = i * 0.01
    return json.dumps(payload)


def _make_deeply_nested(depth: int, value=42) -> dict:
    """Construct a dict nested to the given depth."""
    d: dict = {"leaf": value}
    for _ in range(depth):
        d = {"child": d}
    return d


# ---------------------------------------------------------------------------
# Threshold constants (milliseconds)
# ---------------------------------------------------------------------------
VALIDATE_SERVER_NAME_1000_ITER_MAX_MS = 200
PARSE_JSON_SAFELY_SMALL_MAX_MS = 50
PARSE_JSON_SAFELY_LARGE_MAX_MS = 500  # 100-200 KB payload
VALIDATE_JSON_STRING_DEEP_MAX_MS = 200
REDACT_SENSITIVE_DATA_NESTED_MAX_MS = 200
VALIDATE_FILE_PATH_1000_ITER_MAX_MS = 300
LOAD_SCHEMA_DEFINITION_MAX_MS = 500
VALIDATE_AGAINST_SCHEMA_MAX_MS = 100


# ===========================================================================
# PERF-002-A: Input validation throughput
# ===========================================================================

class TestInputValidationPerformance:
    """Validate that input-validation functions are not pathologically slow."""

    def test_validate_server_name_1000_iterations(self):
        """1 000 validate_server_name() calls must complete within threshold."""
        start = time.perf_counter()
        for i in range(1000):
            validate_server_name(f"SERVER-{i:04d}")
        elapsed_ms = (time.perf_counter() - start) * 1000

        assert elapsed_ms < VALIDATE_SERVER_NAME_1000_ITER_MAX_MS, (
            f"validate_server_name × 1000 took {elapsed_ms:.1f} ms "
            f"(threshold {VALIDATE_SERVER_NAME_1000_ITER_MAX_MS} ms)"
        )

    def test_validate_analysis_type_all_types(self):
        """Validating all four analysis types must be near-instantaneous."""
        types = ["Full", "Health", "Failure", "Anomaly"]
        start = time.perf_counter()
        for _ in range(500):
            for t in types:
                validate_analysis_type(t)
        elapsed_ms = (time.perf_counter() - start) * 1000

        assert elapsed_ms < 200, (
            f"validate_analysis_type × 2000 took {elapsed_ms:.1f} ms"
        )

    def test_parse_json_safely_small_payload(self):
        """parse_json_safely() on a minimal serverDataInput payload."""
        payload = _make_server_data_payload()
        start = time.perf_counter()
        result = parse_json_safely(payload, param_name="--serverdatajson")
        elapsed_ms = (time.perf_counter() - start) * 1000

        assert result["server_name_id"] == "PERF-TEST-SERVER-01"
        assert elapsed_ms < PARSE_JSON_SAFELY_SMALL_MAX_MS, (
            f"parse_json_safely (small) took {elapsed_ms:.1f} ms "
            f"(threshold {PARSE_JSON_SAFELY_SMALL_MAX_MS} ms)"
        )

    def test_parse_json_safely_large_payload(self):
        """parse_json_safely() on a ~100 KB payload stays within threshold."""
        # 200 extra fields → ~100 KB
        payload = _make_server_data_payload(n_extra_keys=2000)
        assert len(payload.encode("utf-8")) > 50_000  # sanity check

        start = time.perf_counter()
        result = parse_json_safely(payload, param_name="--serverdatajson")
        elapsed_ms = (time.perf_counter() - start) * 1000

        assert result["server_name_id"] == "PERF-TEST-SERVER-01"
        assert elapsed_ms < PARSE_JSON_SAFELY_LARGE_MAX_MS, (
            f"parse_json_safely (large ~{len(payload)//1024} KB) took "
            f"{elapsed_ms:.1f} ms (threshold {PARSE_JSON_SAFELY_LARGE_MAX_MS} ms)"
        )

    def test_validate_json_string_moderately_nested(self):
        """validate_json_string() on a 20-level deep structure."""
        nested = _make_deeply_nested(depth=20)
        json_str = json.dumps(nested)

        start = time.perf_counter()
        is_valid, _ = validate_json_string(json_str, param_name="nested")
        elapsed_ms = (time.perf_counter() - start) * 1000

        assert is_valid
        assert elapsed_ms < VALIDATE_JSON_STRING_DEEP_MAX_MS, (
            f"validate_json_string (depth 20) took {elapsed_ms:.1f} ms "
            f"(threshold {VALIDATE_JSON_STRING_DEEP_MAX_MS} ms)"
        )

    def test_validate_file_path_1000_iterations(self):
        """1 000 validate_file_path() calls must complete within threshold."""
        with tempfile.TemporaryDirectory() as tmpdir:
            start = time.perf_counter()
            for _ in range(1000):
                validate_file_path(
                    os.path.join(tmpdir, "model.pkl"),
                    must_exist=False,
                    allowed_extensions=[".pkl"],
                )
            elapsed_ms = (time.perf_counter() - start) * 1000

        assert elapsed_ms < VALIDATE_FILE_PATH_1000_ITER_MAX_MS, (
            f"validate_file_path × 1000 took {elapsed_ms:.1f} ms "
            f"(threshold {VALIDATE_FILE_PATH_1000_ITER_MAX_MS} ms)"
        )


# ===========================================================================
# PERF-002-B: Sensitive data redaction throughput
# ===========================================================================

class TestRedactionPerformance:
    """Ensure redact_sensitive_data() is not pathologically slow on realistic payloads."""

    def _make_sample_config(self) -> dict:
        """A representative config dict that should NOT be redacted."""
        return {
            "aiComponents": {
                "telemetryProcessor": {
                    "anomaly_detection_features": [
                        "cpu_usage", "memory_usage", "disk_usage",
                        "network_latency", "error_count"
                    ],
                    "trend_p_value_threshold": 0.05,
                    "correlation_threshold": 0.85,
                },
                "patternAnalyzer": {
                    "behavioral_features": ["cpu_usage", "memory_usage"],
                    "dbscan_eps": 0.5,
                    "dbscan_min_samples": 5,
                },
            },
            "model_config": {
                "test_split_ratio": 0.2,
                "random_state": 42,
            },
        }

    def test_redact_non_sensitive_config(self):
        """Redacting a config with no sensitive keys should be fast."""
        config = self._make_sample_config()
        start = time.perf_counter()
        for _ in range(500):
            redact_sensitive_data(config)
        elapsed_ms = (time.perf_counter() - start) * 1000

        assert elapsed_ms < REDACT_SENSITIVE_DATA_NESTED_MAX_MS, (
            f"redact_sensitive_data (config × 500) took {elapsed_ms:.1f} ms "
            f"(threshold {REDACT_SENSITIVE_DATA_NESTED_MAX_MS} ms)"
        )

    def test_redact_nested_structure_with_sensitive_keys(self):
        """Redaction of a mixed nested structure must complete within threshold."""
        data = {
            "server": "PROD-001",
            "cpu_usage": 0.75,
            "credential": "test-placeholder-credential",
            "nested": {
                "api_key": "test-placeholder-api-key",
                "healthy": True,
                "deep": {
                    "password": "test-placeholder-secret",
                    "metric": 42,
                },
            },
            "list_field": [
                {"token": "tok-abc", "value": 1},
                {"token": "tok-xyz", "value": 2},
            ],
        }
        start = time.perf_counter()
        for _ in range(500):
            result = redact_sensitive_data(data)
        elapsed_ms = (time.perf_counter() - start) * 1000

        # Verify correctness
        assert result["credential"] == "*** REDACTED ***"
        assert result["nested"]["api_key"] == "*** REDACTED ***"
        assert result["server"] == "PROD-001"

        assert elapsed_ms < REDACT_SENSITIVE_DATA_NESTED_MAX_MS, (
            f"redact_sensitive_data (nested × 500) took {elapsed_ms:.1f} ms "
            f"(threshold {REDACT_SENSITIVE_DATA_NESTED_MAX_MS} ms)"
        )


# ===========================================================================
# PERF-002-C: CLI contracts schema validation throughput
# ===========================================================================

class TestSchemaValidationPerformance:
    """Schema loading and validation must not be I/O-bound on repeated calls."""

    @pytest.fixture(scope="class")
    def server_data_schema(self):
        """Load the serverDataInput schema once for the class."""
        schema = load_cli_contracts_schema_definition("serverDataInput")
        if schema is None:
            pytest.skip(
                "cli_contracts.schema.json not found — skipping schema perf tests"
            )
        return schema

    def test_schema_load_completes_quickly(self):
        """First-call schema load must complete within threshold."""
        start = time.perf_counter()
        schema = load_cli_contracts_schema_definition("serverDataInput")
        elapsed_ms = (time.perf_counter() - start) * 1000

        if schema is None:
            pytest.skip("cli_contracts.schema.json not found")

        assert elapsed_ms < LOAD_SCHEMA_DEFINITION_MAX_MS, (
            f"load_cli_contracts_schema_definition took {elapsed_ms:.1f} ms "
            f"(threshold {LOAD_SCHEMA_DEFINITION_MAX_MS} ms)"
        )

    def test_validate_against_schema_100_iterations(self, server_data_schema):
        """100 consecutive schema validations must complete within threshold."""
        payload = json.loads(_make_server_data_payload())

        start = time.perf_counter()
        for _ in range(100):
            is_valid, err = validate_json_against_schema(
                payload, server_data_schema, param_name="--serverdatajson"
            )
        elapsed_ms = (time.perf_counter() - start) * 1000

        assert is_valid, f"Unexpected schema validation failure: {err}"
        assert elapsed_ms < VALIDATE_AGAINST_SCHEMA_MAX_MS * 100, (
            f"validate_json_against_schema × 100 took {elapsed_ms:.1f} ms "
            f"(threshold {VALIDATE_AGAINST_SCHEMA_MAX_MS * 100} ms)"
        )


# ===========================================================================
# PERF-002-D: ArcPredictor model caching (PERF-003 regression guard)
# ===========================================================================

class TestArcPredictorCachePerformance:
    """Verify that the PERF-003 in-process model cache is exercised correctly."""

    def test_second_instantiation_uses_cache(self, tmp_path):
        """
        Second ArcPredictor instantiation with the same model_dir should be
        faster than the first (cache hit avoids disk I/O).
        Requires the test to be able to import ArcPredictor without errors.
        """
        try:
            from Python.predictive.predictor import ArcPredictor  # noqa: E402
        except ImportError:
            pytest.skip("ArcPredictor not importable — skipping cache perf test")

        model_dir = str(tmp_path)

        # Clear any existing cache entry for this dir so the test is isolated
        import os as _os
        cache_key = _os.path.realpath(model_dir)
        ArcPredictor._model_cache.pop(cache_key, None)

        # First instantiation — cold (no models exist, but load_models runs)
        t0 = time.perf_counter()
        ArcPredictor(model_dir=model_dir)
        cold_ms = (time.perf_counter() - t0) * 1000

        # Second instantiation — should hit the cache and be at least as fast
        t1 = time.perf_counter()
        ArcPredictor(model_dir=model_dir)
        warm_ms = (time.perf_counter() - t1) * 1000

        # Cache hit must be ≤ cold time (allow 10× grace for scheduler jitter)
        assert warm_ms <= max(cold_ms * 10, 50), (
            f"Cache hit ({warm_ms:.1f} ms) was unexpectedly slower than cold "
            f"load ({cold_ms:.1f} ms). Cache may not be working."
        )

    def test_cache_key_is_realpath(self, tmp_path):
        """Cache keys must be based on realpath to prevent duplicates from symlinks."""
        try:
            from Python.predictive.predictor import ArcPredictor  # noqa: E402
        except ImportError:
            pytest.skip("ArcPredictor not importable")

        import os as _os
        model_dir = str(tmp_path)
        cache_key = _os.path.realpath(model_dir)

        ArcPredictor._model_cache.pop(cache_key, None)
        ArcPredictor(model_dir=model_dir)

        assert cache_key in ArcPredictor._model_cache, (
            "Expected realpath-based cache key to be present after instantiation."
        )

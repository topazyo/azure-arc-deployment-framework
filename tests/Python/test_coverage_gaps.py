"""Targeted tests to close coverage gaps in partially-covered modules.

Covers:
- predictive/models/__init__.py (0%)
- predictor.py edge cases (70%)
- ArcRemediationLearner.py edge cases (76%)
- predictive_analytics_engine.py edge cases (74%)
- common/resilience.py edge cases (74%)
"""

import json
import os
import sys
import pytest
import numpy as np
from unittest.mock import patch, MagicMock
from datetime import datetime

SRC_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../src"))
if SRC_DIR not in sys.path:
    sys.path.insert(0, SRC_DIR)


# ---------------------------------------------------------------------------
# predictive/models/__init__.py — 0% coverage
# ---------------------------------------------------------------------------

class TestPredictiveModelsInit:
    """Importing the models package covers its __init__.py statements."""

    @pytest.fixture(autouse=True)
    def _mock_missing_model_submodules(self):
        """Mock the sub-module files that don't exist on disk so __init__.py can be imported."""
        import importlib
        mock_health = MagicMock()
        mock_health.HealthPredictionModel = type('HealthPredictionModel', (), {})
        mock_failure = MagicMock()
        mock_failure.FailurePredictionModel = type('FailurePredictionModel', (), {})
        mock_anomaly = MagicMock()
        mock_anomaly.AnomalyDetectionModel = type('AnomalyDetectionModel', (), {})
        extra = {
            'Python.predictive.models.health_model': mock_health,
            'Python.predictive.models.failure_model': mock_failure,
            'Python.predictive.models.anomaly_model': mock_anomaly,
        }
        # Remove any cached (failed) import so the module is freshly loaded
        old = sys.modules.pop('Python.predictive.models', None)
        with patch.dict(sys.modules, extra):
            yield
        # Restore or evict the (now stale) cached entry
        sys.modules.pop('Python.predictive.models', None)
        if old is not None:
            sys.modules['Python.predictive.models'] = old

    def test_models_init_imports_and_registry(self):
        """Importing Python.predictive.models covers all 6 __init__.py stmts."""
        import importlib
        models_pkg = importlib.import_module('Python.predictive.models')
        assert hasattr(models_pkg, 'MODEL_REGISTRY')
        assert 'health_prediction' in models_pkg.MODEL_REGISTRY
        assert 'failure_prediction' in models_pkg.MODEL_REGISTRY
        assert 'anomaly_detection' in models_pkg.MODEL_REGISTRY

    def test_models_init_model_configs_present(self):
        """MODEL_CONFIGS is populated for all three model types."""
        import importlib
        models_pkg = importlib.import_module('Python.predictive.models')
        assert hasattr(models_pkg, 'MODEL_CONFIGS')
        assert 'health_prediction' in models_pkg.MODEL_CONFIGS
        assert 'failure_prediction' in models_pkg.MODEL_CONFIGS

    def test_models_init_all_exports(self):
        """__all__ contains the three model class names."""
        import importlib
        models_pkg = importlib.import_module('Python.predictive.models')
        assert 'HealthPredictionModel' in models_pkg.__all__
        assert 'FailurePredictionModel' in models_pkg.__all__
        assert 'AnomalyDetectionModel' in models_pkg.__all__


# ---------------------------------------------------------------------------
# ArcPredictor edge cases via __new__ (no disk I/O for model loading)
# ---------------------------------------------------------------------------

from Python.predictive.predictor import ArcPredictor  # noqa: E402


def _bare_predictor():
    """Create an ArcPredictor bypassing __init__ and set minimal attributes."""
    p = ArcPredictor.__new__(ArcPredictor)
    p.model_dir = "/tmp/fake_models"
    p.logger = MagicMock()
    p.model_load_errors = {}
    p.models = {}
    p.scalers = {}
    p.feature_info = {}
    return p


class TestArcPredictorEdgeCases:
    """Edge cases in ArcPredictor that bypass normal model-loading paths."""

    def test_ensure_model_not_loaded_returns_error_dict(self):
        """_ensure_model_loaded returns dict with error when model absent."""
        p = _bare_predictor()
        # No model loaded — _ensure_model_loaded should return error dict
        result = p._ensure_model_loaded("health_prediction")
        assert result is not None
        assert result.get("error") == "ModelNotLoaded"

    def test_predict_health_when_model_not_loaded(self):
        """predict_health returns error dict when model not loaded."""
        p = _bare_predictor()
        result = p.predict_health({"cpu_usage": 0.5})
        assert "error" in result

    def test_detect_anomalies_when_model_not_loaded(self):
        """detect_anomalies returns error dict when model not loaded."""
        p = _bare_predictor()
        result = p.detect_anomalies({"cpu_usage": 0.5})
        assert "error" in result

    def test_predict_failures_when_model_not_loaded(self):
        """predict_failures returns error dict when model not loaded."""
        p = _bare_predictor()
        result = p.predict_failures({"cpu_usage": 0.5})
        assert "error" in result

    def test_prepare_features_with_nan_value_defaults_to_zero(self):
        """NaN values in telemetry are replaced by 0.0 in feature array."""
        p = _bare_predictor()
        p.feature_info["health_prediction"] = {
            "ordered_features": ["cpu_usage", "memory_usage"],
        }
        telemetry = {"cpu_usage": float("nan"), "memory_usage": 0.5}
        result = p.prepare_features(telemetry, "health_prediction")
        assert result is not None
        assert result[0, 0] == 0.0  # NaN replaced with 0.0

    def test_prepare_features_with_non_float_value_defaults_to_zero(self):
        """Non-numeric feature values default to 0.0."""
        p = _bare_predictor()
        p.feature_info["health_prediction"] = {
            "ordered_features": ["cpu_usage", "memory_usage"],
        }
        telemetry = {"cpu_usage": "not_a_number", "memory_usage": 0.6}
        result = p.prepare_features(telemetry, "health_prediction")
        assert result is not None
        assert result[0, 0] == 0.0

    def test_prepare_features_missing_feature_defaults_to_zero(self):
        """Missing features default to 0.0 in feature array."""
        p = _bare_predictor()
        p.feature_info["health_prediction"] = {
            "ordered_features": ["cpu_usage", "memory_usage", "disk_usage"],
        }
        # disk_usage is missing from telemetry
        telemetry = {"cpu_usage": 0.5, "memory_usage": 0.4}
        result = p.prepare_features(telemetry, "health_prediction")
        assert result is not None
        assert result[0, 2] == 0.0  # disk_usage defaults to 0.0

    def test_prepare_features_model_type_not_in_feature_info(self):
        """Returns None if model_type not in feature_info."""
        p = _bare_predictor()
        # No feature_info for the model type
        result = p.prepare_features({"cpu_usage": 0.5}, "unknown_model_type")
        assert result is None

    def test_prepare_features_empty_ordered_features(self):
        """Returns None if ordered_features is empty list."""
        p = _bare_predictor()
        p.feature_info["health_prediction"] = {"ordered_features": []}
        result = p.prepare_features({"cpu_usage": 0.5}, "health_prediction")
        assert result is None

    def test_calculate_feature_impacts_empty_importance_dict(self):
        """Empty importance_dict returns empty impacts dict."""
        p = _bare_predictor()
        result = p.calculate_feature_impacts(
            np.array([0.5, 0.3]),
            {},  # Empty importance map
            ["cpu_usage", "memory_usage"],
        )
        assert result == {}

    def test_calculate_feature_impacts_empty_ordered_names(self):
        """Empty ordered names list returns empty impacts dict."""
        p = _bare_predictor()
        result = p.calculate_feature_impacts(
            np.array([0.5, 0.3]),
            {"cpu_usage": 0.8},
            [],  # Empty feature names
        )
        assert result == {}

    def test_calculate_feature_impacts_length_mismatch_returns_empty(self):
        """Length mismatch between array and names returns empty dict."""
        p = _bare_predictor()
        result = p.calculate_feature_impacts(
            np.array([0.5, 0.3]),            # 2 elements
            {"cpu_usage": 0.8, "memory_usage": 0.3},
            ["cpu_usage", "memory_usage", "disk_usage"],  # 3 elements
        )
        assert result == {}

    def test_calculate_feature_impacts_feature_not_in_importance_map(self):
        """Feature in ordered_names but not in importance_dict is skipped."""
        p = _bare_predictor()
        result = p.calculate_feature_impacts(
            np.array([0.5, 0.3]),
            {"cpu_usage": 0.8},            # memory_usage not present
            ["cpu_usage", "memory_usage"],
        )
        assert "cpu_usage" in result
        assert "memory_usage" not in result

    def test_calculate_risk_level_critical(self):
        """Risk score >= 0.75 → Critical."""
        p = _bare_predictor()
        assert p.calculate_risk_level(0.75) == "Critical"
        assert p.calculate_risk_level(0.99) == "Critical"

    def test_calculate_risk_level_high(self):
        """Risk score 0.50-0.74 → High."""
        p = _bare_predictor()
        assert p.calculate_risk_level(0.5) == "High"
        assert p.calculate_risk_level(0.6) == "High"

    def test_calculate_risk_level_medium(self):
        """Risk score 0.25-0.49 → Medium."""
        p = _bare_predictor()
        assert p.calculate_risk_level(0.25) == "Medium"
        assert p.calculate_risk_level(0.4) == "Medium"

    def test_calculate_risk_level_low(self):
        """Risk score < 0.25 → Low."""
        p = _bare_predictor()
        assert p.calculate_risk_level(0.1) == "Low"
        assert p.calculate_risk_level(0.0) == "Low"


# ---------------------------------------------------------------------------
# ArcRemediationLearner edge cases
# ---------------------------------------------------------------------------

from Python.predictive.ArcRemediationLearner import ArcRemediationLearner  # noqa: E402


@pytest.fixture
def basic_learner_config():
    return {
        "success_pattern_threshold": 0.7,
        "success_pattern_min_attempts": 3,
        "retraining_data_threshold": 5,
    }


class TestArcRemediationLearnerEdgeCases:

    def test_has_pending_retrain_requests_false_when_empty(self, basic_learner_config):
        """has_pending_retrain_requests returns False when queue is empty."""
        learner = ArcRemediationLearner(config=basic_learner_config)
        assert learner.has_pending_retrain_requests() is False

    def test_has_pending_retrain_requests_true_when_nonempty(self, basic_learner_config):
        """has_pending_retrain_requests returns True after a request is queued."""
        learner = ArcRemediationLearner(config=basic_learner_config)
        learner.pending_retrain_requests.append({"model": "health_prediction"})
        assert learner.has_pending_retrain_requests() is True

    def test_peek_pending_retrain_requests_does_not_clear(self, basic_learner_config):
        """peek_pending_retrain_requests returns a copy without clearing."""
        learner = ArcRemediationLearner(config=basic_learner_config)
        learner.pending_retrain_requests.append({"model": "test"})
        result = learner.peek_pending_retrain_requests()
        assert len(result) == 1
        assert len(learner.pending_retrain_requests) == 1  # still there

    def test_consume_pending_retrain_requests_clears_queue(self, basic_learner_config):
        """consume_pending_retrain_requests returns requests and clears queue."""
        learner = ArcRemediationLearner(config=basic_learner_config)
        learner.pending_retrain_requests.append({"model": "health_prediction"})
        result = learner.consume_pending_retrain_requests()
        assert len(result) == 1
        assert len(learner.pending_retrain_requests) == 0

    def test_export_pending_retrain_requests_success(self, basic_learner_config, tmp_path):
        """export_pending_retrain_requests writes JSON file on success."""
        learner = ArcRemediationLearner(config=basic_learner_config)
        learner.pending_retrain_requests.append({"model": "health_prediction"})
        output_path = str(tmp_path / "retrain.json")
        result = learner.export_pending_retrain_requests(output_path)
        assert result["status"] == "exported"
        assert result["count"] == 1
        assert os.path.exists(output_path)
        with open(output_path) as f:
            data = json.load(f)
        assert "pending_retrain_requests" in data

    def test_export_pending_retrain_requests_consume_flag_clears_queue(
            self, basic_learner_config, tmp_path):
        """consume=True clears the queue after export."""
        learner = ArcRemediationLearner(config=basic_learner_config)
        learner.pending_retrain_requests.append({"model": "failure_prediction"})
        output_path = str(tmp_path / "retrain2.json")
        learner.export_pending_retrain_requests(output_path, consume=True)
        assert len(learner.pending_retrain_requests) == 0

    def test_export_pending_retrain_requests_empty_path_returns_error(
            self, basic_learner_config):
        """Empty output_path string returns error status dict."""
        learner = ArcRemediationLearner(config=basic_learner_config)
        result = learner.export_pending_retrain_requests("")
        assert result["status"] == "error"

    def test_export_pending_retrain_requests_none_path_returns_error(
            self, basic_learner_config):
        """None output_path returns error status dict."""
        learner = ArcRemediationLearner(config=basic_learner_config)
        result = learner.export_pending_retrain_requests(None)
        assert result["status"] == "error"

    def test_export_pending_retrain_requests_ioerror_returns_error(
            self, basic_learner_config):
        """IOError during file write returns error status dict."""
        learner = ArcRemediationLearner(config=basic_learner_config)
        learner.pending_retrain_requests.append({"model": "test"})
        with patch("builtins.open", side_effect=IOError("disk full")):
            result = learner.export_pending_retrain_requests("/fake/path.json")
        assert result["status"] == "error"
        assert "disk full" in result["reason"]

    def test_learn_from_remediation_non_dict_is_skipped(self, basic_learner_config):
        """learn_from_remediation skips and logs warning for non-dict input."""
        learner = ArcRemediationLearner(config=basic_learner_config)
        # Should not raise; warning is logged internally
        learner.learn_from_remediation("not a dict")
        assert len(learner.success_patterns) == 0

    def test_learn_from_remediation_missing_error_type_uses_default(self, basic_learner_config):
        """learn_from_remediation defaults missing error_type to 'UnknownError' and still records."""
        learner = ArcRemediationLearner(config=basic_learner_config)
        learner.learn_from_remediation({"action": "restart"})
        # error_type defaults to 'UnknownError', which is truthy — pattern is recorded
        assert ('UnknownError', 'restart') in learner.success_patterns

    def test_get_recommendation_with_no_patterns(self, basic_learner_config):
        """get_recommendation with no learned patterns returns a valid recommendation dict."""
        learner = ArcRemediationLearner(config=basic_learner_config)
        rec = learner.get_recommendation({"error_type": "NetworkFailure"})
        assert "recommended_action" in rec
        assert "confidence_score" in rec
        assert "source" in rec
        assert "alternative_actions" in rec


# ---------------------------------------------------------------------------
# PredictiveAnalyticsEngine edge cases
# ---------------------------------------------------------------------------

from Python.predictive.predictive_analytics_engine import (  # noqa: E402
    PredictiveAnalyticsEngine
)


@pytest.fixture
def minimal_pae_config():
    return {
        "model_config": {
            "features": {
                "health_prediction": {
                    "required_features": ["cpu_usage"],
                    "target_column": "is_healthy",
                    "missing_strategy": "mean",
                },
                "failure_prediction": {
                    "required_features": ["cpu_usage"],
                    "target_column": "will_fail",
                    "missing_strategy": "mean",
                },
                "anomaly_detection": {
                    "required_features": ["cpu_usage"],
                    "missing_strategy": "mean",
                },
            },
            "models": {
                "health_prediction": {},
                "failure_prediction": {},
                "anomaly_detection": {},
            },
            "test_split_ratio": 0.2,
            "random_state": 42,
        },
        "pattern_analyzer_config": {},
        "remediation_learner_config": {},
    }


class TestPredictiveAnalyticsEngineEdgeCases:
    """Edge-case tests for PAE methods not covered by existing tests."""

    def _make_pae(self, tmp_path, minimal_pae_config):
        """Create a PAE with mocked PatternAnalyzer and ArcPredictor."""
        (tmp_path / "model.pkl").write_text("dummy")
        with patch("Python.predictive.predictive_analytics_engine.PatternAnalyzer"):
            with patch("Python.predictive.predictive_analytics_engine.ArcPredictor"):
                pae = PredictiveAnalyticsEngine(
                    config=minimal_pae_config, model_dir=str(tmp_path)
                )
        return pae

    def test_record_remediation_outcome_disabled_when_no_learner(
            self, tmp_path, minimal_pae_config):
        """record_remediation_outcome returns 'disabled' if no learner."""
        pae = self._make_pae(tmp_path, minimal_pae_config)
        pae.remediation_learner = None
        result = pae.record_remediation_outcome({"action": "restart"})
        assert result["status"] == "disabled"

    def test_export_retrain_requests_disabled_when_no_learner(
            self, tmp_path, minimal_pae_config):
        """export_retrain_requests returns 'disabled' if no learner."""
        pae = self._make_pae(tmp_path, minimal_pae_config)
        pae.remediation_learner = None
        result = pae.export_retrain_requests("/tmp/retrain.json")
        assert result["status"] == "disabled"

    def test_get_risk_level_critical(self, tmp_path, minimal_pae_config):
        """Risk score >= 0.8 → Critical."""
        pae = self._make_pae(tmp_path, minimal_pae_config)
        assert pae._get_risk_level(0.80) == "Critical"
        assert pae._get_risk_level(1.0) == "Critical"

    def test_get_risk_level_high(self, tmp_path, minimal_pae_config):
        """Risk score 0.6–0.79 → High."""
        pae = self._make_pae(tmp_path, minimal_pae_config)
        assert pae._get_risk_level(0.60) == "High"
        assert pae._get_risk_level(0.75) == "High"

    def test_get_risk_level_medium(self, tmp_path, minimal_pae_config):
        """Risk score 0.4–0.59 → Medium."""
        pae = self._make_pae(tmp_path, minimal_pae_config)
        assert pae._get_risk_level(0.40) == "Medium"
        assert pae._get_risk_level(0.55) == "Medium"

    def test_get_risk_level_low(self, tmp_path, minimal_pae_config):
        """Risk score 0.2–0.39 → Low."""
        pae = self._make_pae(tmp_path, minimal_pae_config)
        assert pae._get_risk_level(0.20) == "Low"
        assert pae._get_risk_level(0.35) == "Low"

    def test_get_risk_level_minimal(self, tmp_path, minimal_pae_config):
        """Risk score < 0.2 → Minimal."""
        pae = self._make_pae(tmp_path, minimal_pae_config)
        assert pae._get_risk_level(0.0) == "Minimal"
        assert pae._get_risk_level(0.19) == "Minimal"

    def test_get_health_recommendations_returns_list(self, tmp_path, minimal_pae_config):
        """_get_health_recommendations returns non-empty list when impact > 0.3."""
        pae = self._make_pae(tmp_path, minimal_pae_config)
        health = {"feature_impacts": {"cpu_usage": 0.8, "memory_usage": 0.1}}
        recs = pae._get_health_recommendations(health)
        assert isinstance(recs, list)
        assert len(recs) > 0
        assert recs[0]["category"] == "Health"

    def test_get_failure_recommendations_returns_list(self, tmp_path, minimal_pae_config):
        """_get_failure_recommendations returns non-empty list when impact > 0.3."""
        pae = self._make_pae(tmp_path, minimal_pae_config)
        failure = {"feature_impacts": {"cpu_usage": 0.9}}
        recs = pae._get_failure_recommendations(failure)
        assert isinstance(recs, list)
        assert len(recs) > 0
        assert recs[0]["category"] == "Failure Prevention"

    def test_get_anomaly_recommendations_returns_list(self, tmp_path, minimal_pae_config):
        """_get_anomaly_recommendations always returns one recommendation."""
        pae = self._make_pae(tmp_path, minimal_pae_config)
        anomaly = {"is_anomaly": True, "anomaly_score": -0.5}
        recs = pae._get_anomaly_recommendations(anomaly)
        assert len(recs) == 1
        assert recs[0]["category"] == "Anomaly"

    def test_record_remediation_with_active_learner(self, tmp_path, minimal_pae_config):
        """record_remediation_outcome calls learner when it IS initialized."""
        pae = self._make_pae(tmp_path, minimal_pae_config)
        mock_learner = MagicMock()
        mock_learner.peek_pending_retrain_requests.return_value = []
        mock_learner.trainer_last_response = None
        pae.remediation_learner = mock_learner
        result = pae.record_remediation_outcome({"action": "restart"})
        assert result["status"] == "processed"
        mock_learner.learn_from_remediation.assert_called_once()


# ---------------------------------------------------------------------------
# resilience.py edge cases
# ---------------------------------------------------------------------------

from Python.common.resilience import (  # noqa: E402
    validate_model_directory,
    safe_json_loads,
    safe_file_read,
    retry_with_backoff,
    TransientException,
)


class TestResilienceEdgeCases:

    # validate_model_directory with exit_on_error=False

    def test_validate_model_directory_nonexistent_no_exit(self):
        """Non-existent directory returns False when exit_on_error=False."""
        result = validate_model_directory(
            "/nonexistent/path/models", exit_on_error=False
        )
        assert result is False

    def test_validate_model_directory_not_a_dir_no_exit(self, tmp_path):
        """Path pointing to file (not dir) returns False when exit_on_error=False."""
        file_path = tmp_path / "model.pkl"
        file_path.write_text("dummy")
        result = validate_model_directory(str(file_path), exit_on_error=False)
        assert result is False

    def test_validate_model_directory_empty_dir_no_exit(self, tmp_path):
        """Empty directory returns False when exit_on_error=False."""
        empty_dir = tmp_path / "empty"
        empty_dir.mkdir()
        result = validate_model_directory(str(empty_dir), exit_on_error=False)
        assert result is False

    def test_validate_model_directory_valid_dir_returns_true(self, tmp_path):
        """Valid, non-empty directory returns True."""
        (tmp_path / "model.pkl").write_text("dummy")
        result = validate_model_directory(str(tmp_path), exit_on_error=False)
        assert result is True

    # safe_json_loads

    def test_safe_json_loads_invalid_json_exits_2(self):
        """safe_json_loads exits with VALIDATION_ERROR on invalid JSON."""
        with pytest.raises(SystemExit) as exc:
            safe_json_loads("{invalid json!", param_name="test_param")
        assert exc.value.code == 2

    def test_safe_json_loads_valid_json_returns_dict(self):
        """safe_json_loads returns parsed dict for valid JSON."""
        result = safe_json_loads('{"key": "value"}', param_name="test")
        assert result == {"key": "value"}

    # safe_file_read

    def test_safe_file_read_nonexistent_file_exits(self):
        """safe_file_read exits when file does not exist."""
        with pytest.raises(SystemExit):
            safe_file_read("/nonexistent/file.json", description="config")

    def test_safe_file_read_existing_file_returns_content(self, tmp_path):
        """safe_file_read returns file content for an existing file."""
        test_file = tmp_path / "test.json"
        test_file.write_text('{"key": "value"}')
        content = safe_file_read(str(test_file), description="test file")
        assert content == '{"key": "value"}'

    def test_safe_file_read_ioerror_exits(self, tmp_path):
        """safe_file_read exits with GENERAL_ERROR on IOError."""
        test_file = tmp_path / "test.json"
        test_file.write_text("content")
        with patch("builtins.open", side_effect=IOError("permission denied")):
            with pytest.raises(SystemExit) as exc:
                safe_file_read(str(test_file))
        assert exc.value.code == 1

    # retry_with_backoff

    def test_retry_succeeds_on_second_attempt(self):
        """retry_with_backoff retries once after TransientException."""
        attempt_counter = {"count": 0}

        @retry_with_backoff(max_retries=1, initial_delay=0.0)
        def flaky():
            attempt_counter["count"] += 1
            if attempt_counter["count"] < 2:
                raise TransientException("transient error")
            return "success"

        result = flaky()
        assert result == "success"
        assert attempt_counter["count"] == 2

    def test_retry_exhaustion_re_raises(self):
        """retry_with_backoff re-raises after all retries are exhausted."""
        @retry_with_backoff(max_retries=1, initial_delay=0.0)
        def always_fails():
            raise TransientException("always fails")

        with pytest.raises(TransientException):
            always_fails()

    def test_retry_no_retry_on_non_transient_exception(self):
        """Non-retryable exceptions propagate immediately without retrying."""
        call_count = {"count": 0}

        @retry_with_backoff(max_retries=3, initial_delay=0.0)
        def fails_with_valueerror():
            call_count["count"] += 1
            raise ValueError("not transient")

        with pytest.raises(ValueError):
            fails_with_valueerror()
        # Should have been called exactly once — no retry for ValueError
        assert call_count["count"] == 1

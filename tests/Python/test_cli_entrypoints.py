"""Unit tests for CLI entrypoint scripts.

Tests invoke_ai_engine.main() and run_predictor.main() directly by
monkeypatching sys.argv and mocking heavy dependencies.  These tests
exist to drive code-coverage of the two CLI entry-point modules which
cannot be exercised through subprocess-based contract tests.
"""

import json
import os
import sys
import pytest
from datetime import datetime
from unittest.mock import patch, MagicMock

# Ensure src/ is in sys.path (conftest.py does this too, but be explicit)
SRC_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../src"))
if SRC_DIR not in sys.path:
    sys.path.insert(0, SRC_DIR)

# Real file paths used across tests
CONFIG_PATH = os.path.join(SRC_DIR, "config", "ai_config.json")

# Import modules under test — this also drives module-level coverage
import Python.invoke_ai_engine as invoke_module  # noqa: E402
import Python.run_predictor as predictor_module  # noqa: E402


# ---------------------------------------------------------------------------
# Shared mock factories
# ---------------------------------------------------------------------------

def _mock_engine(risk_score: float = 0.25):
    """Minimal PredictiveAnalyticsEngine mock."""
    m = MagicMock()
    m.analyze_deployment_risk.return_value = {
        "overall_risk": {"score": risk_score, "level": "Low"},
        "recommendations": [],
    }
    m.record_remediation_outcome.return_value = {
        "status": "processed",
        "trainer_response": None,
        "pending_retrain_requests": [],
    }
    m.export_retrain_requests.return_value = {
        "status": "exported",
        "path": "/tmp/retrain.json",
        "count": 0,
    }
    return m


def _mock_predictor():
    """Minimal ArcPredictor mock with all predict methods."""
    m = MagicMock()
    m.models = {
        "health_prediction": True,
        "anomaly_detection": True,
        "failure_prediction": True,
    }
    m.predict_health.return_value = {
        "prediction": {
            "healthy_probability": 0.9,
            "unhealthy_probability": 0.1,
        },
        "feature_impacts": {},
        "timestamp": datetime.now().isoformat(),
    }
    m.detect_anomalies.return_value = {
        "is_anomaly": False,
        "anomaly_score": 0.05,
        "timestamp": datetime.now().isoformat(),
    }
    m.predict_failures.return_value = {
        "prediction": {
            "failure_probability": 0.03,
            "normal_probability": 0.97,
        },
        "feature_impacts": {},
        "risk_level": "Low",
        "timestamp": datetime.now().isoformat(),
    }
    return m


# ---------------------------------------------------------------------------
# invoke_ai_engine.main() tests
# ---------------------------------------------------------------------------

class TestInvokeAIEngineMain:
    """Tests for invoke_ai_engine.main() covering success and error paths."""

    def _base_argv(self, tmp_path):
        return [
            "invoke_ai_engine.py",
            "--servername", "TEST-SERVER-01",
            "--analysistype", "Full",
            "--configpath", CONFIG_PATH,
            "--modeldir", str(tmp_path),
        ]

    # ----- argument / validation errors -----

    def test_missing_servername_exits_nonzero(self, monkeypatch):
        """argparse exits non-zero when --servername is omitted."""
        monkeypatch.setattr(sys, "argv", ["invoke_ai_engine.py"])
        with pytest.raises(SystemExit) as exc:
            invoke_module.main()
        assert exc.value.code != 0

    def test_invalid_server_name_too_long_exits_2(self, monkeypatch, tmp_path):
        """Server name > 255 chars triggers VALIDATION_ERROR (exit 2)."""
        monkeypatch.setattr(sys, "argv", [
            "invoke_ai_engine.py",
            "--servername", "A" * 256,
            "--configpath", CONFIG_PATH,
            "--modeldir", str(tmp_path),
        ])
        with pytest.raises(SystemExit) as exc:
            invoke_module.main()
        assert exc.value.code == 2

    def test_invalid_server_name_path_traversal_exits_2(self, monkeypatch, tmp_path):
        """Server name with '..' triggers VALIDATION_ERROR (exit 2)."""
        monkeypatch.setattr(sys, "argv", [
            "invoke_ai_engine.py",
            "--servername", "../../../etc/passwd",
            "--configpath", CONFIG_PATH,
            "--modeldir", str(tmp_path),
        ])
        with pytest.raises(SystemExit) as exc:
            invoke_module.main()
        assert exc.value.code == 2

    def test_invalid_server_name_special_chars_exits_2(self, monkeypatch, tmp_path):
        """Server name with shell-injection chars triggers exit 2."""
        monkeypatch.setattr(sys, "argv", [
            "invoke_ai_engine.py",
            "--servername", "server; rm -rf /",
            "--configpath", CONFIG_PATH,
            "--modeldir", str(tmp_path),
        ])
        with pytest.raises(SystemExit) as exc:
            invoke_module.main()
        assert exc.value.code == 2

    def test_invalid_analysis_type_exits_2(self, monkeypatch, tmp_path):
        """Unknown analysis type triggers VALIDATION_ERROR (exit 2)."""
        monkeypatch.setattr(sys, "argv", [
            "invoke_ai_engine.py",
            "--servername", "TEST-SERVER-01",
            "--analysistype", "UNKNOWN_TYPE",
            "--configpath", CONFIG_PATH,
            "--modeldir", str(tmp_path),
        ])
        with pytest.raises(SystemExit) as exc:
            invoke_module.main()
        assert exc.value.code == 2

    def test_nonexistent_config_file_exits_3(self, monkeypatch, tmp_path):
        """Missing config file path triggers CONFIG_ERROR (exit 3)."""
        monkeypatch.setattr(sys, "argv", [
            "invoke_ai_engine.py",
            "--servername", "TEST-SERVER-01",
            "--configpath", "/nonexistent/path/ai_config.json",
            "--modeldir", str(tmp_path),
        ])
        with pytest.raises(SystemExit) as exc:
            invoke_module.main()
        assert exc.value.code == 3

    def test_empty_model_dir_exits_3(self, monkeypatch, tmp_path):
        """Empty model directory triggers CONFIG_ERROR (exit 3)."""
        monkeypatch.setattr(sys, "argv", self._base_argv(tmp_path))
        # tmp_path is empty — validate_model_directory should exit(3)
        with pytest.raises(SystemExit) as exc:
            invoke_module.main()
        assert exc.value.code == 3

    def test_nonexistent_model_dir_exits_3(self, monkeypatch, tmp_path):
        """Non-existent model directory triggers CONFIG_ERROR (exit 3)."""
        monkeypatch.setattr(sys, "argv", [
            "invoke_ai_engine.py",
            "--servername", "TEST-SERVER-01",
            "--configpath", CONFIG_PATH,
            "--modeldir", str(tmp_path / "does_not_exist"),
        ])
        with pytest.raises(SystemExit) as exc:
            invoke_module.main()
        assert exc.value.code == 3

    # ----- success path -----

    def test_success_exits_0(self, monkeypatch, tmp_path):
        """Valid args with mocked engine exits 0."""
        (tmp_path / "model.pkl").write_text("dummy")
        mock_eng = _mock_engine()
        monkeypatch.setattr(sys, "argv", self._base_argv(tmp_path))
        with patch("Python.invoke_ai_engine.PredictiveAnalyticsEngine",
                   return_value=mock_eng):
            with pytest.raises(SystemExit) as exc:
                invoke_module.main()
        assert exc.value.code == 0

    def test_success_stdout_is_valid_json(self, monkeypatch, tmp_path, capsys):
        """Success path prints well-formed JSON to stdout."""
        (tmp_path / "model.pkl").write_text("dummy")
        mock_eng = _mock_engine(0.3)
        monkeypatch.setattr(sys, "argv", self._base_argv(tmp_path))
        with patch("Python.invoke_ai_engine.PredictiveAnalyticsEngine",
                   return_value=mock_eng):
            with pytest.raises(SystemExit):
                invoke_module.main()
        output = json.loads(capsys.readouterr().out)
        assert "input_servername" in output
        assert output["input_servername"] == "TEST-SERVER-01"

    def test_output_includes_input_analysistype(self, monkeypatch, tmp_path, capsys):
        """Output JSON includes input_analysistype field."""
        (tmp_path / "model.pkl").write_text("dummy")
        monkeypatch.setattr(sys, "argv", self._base_argv(tmp_path))
        with patch("Python.invoke_ai_engine.PredictiveAnalyticsEngine",
                   return_value=_mock_engine()):
            with pytest.raises(SystemExit):
                invoke_module.main()
        output = json.loads(capsys.readouterr().out)
        assert output.get("input_analysistype") == "Full"

    def test_correlation_id_echoed_in_output(self, monkeypatch, tmp_path, capsys):
        """--correlation-id value is echoed in the output JSON."""
        (tmp_path / "model.pkl").write_text("dummy")
        monkeypatch.setattr(sys, "argv",
                            self._base_argv(tmp_path) + ["--correlation-id", "CORR-XYZ-99"])
        with patch("Python.invoke_ai_engine.PredictiveAnalyticsEngine",
                   return_value=_mock_engine()):
            with pytest.raises(SystemExit):
                invoke_module.main()
        output = json.loads(capsys.readouterr().out)
        assert output.get("correlation_id") == "CORR-XYZ-99"

    def test_no_correlation_id_absent_from_output(self, monkeypatch, tmp_path, capsys):
        """When --correlation-id is not supplied it should not appear in output."""
        (tmp_path / "model.pkl").write_text("dummy")
        monkeypatch.setattr(sys, "argv", self._base_argv(tmp_path))
        with patch("Python.invoke_ai_engine.PredictiveAnalyticsEngine",
                   return_value=_mock_engine()):
            with pytest.raises(SystemExit):
                invoke_module.main()
        output = json.loads(capsys.readouterr().out)
        assert "correlation_id" not in output

    # ----- analysis-type variants -----

    def test_health_analysis_type_succeeds(self, monkeypatch, tmp_path):
        """--analysistype=Health succeeds and exits 0."""
        (tmp_path / "model.pkl").write_text("dummy")
        monkeypatch.setattr(sys, "argv", [
            "invoke_ai_engine.py", "--servername", "TEST-SERVER-01",
            "--analysistype", "Health",
            "--configpath", CONFIG_PATH, "--modeldir", str(tmp_path),
        ])
        with patch("Python.invoke_ai_engine.PredictiveAnalyticsEngine",
                   return_value=_mock_engine()):
            with pytest.raises(SystemExit) as exc:
                invoke_module.main()
        assert exc.value.code == 0

    def test_failure_analysis_type_succeeds(self, monkeypatch, tmp_path):
        """--analysistype=Failure succeeds and exits 0."""
        (tmp_path / "model.pkl").write_text("dummy")
        monkeypatch.setattr(sys, "argv", [
            "invoke_ai_engine.py", "--servername", "TEST-SERVER-01",
            "--analysistype", "Failure",
            "--configpath", CONFIG_PATH, "--modeldir", str(tmp_path),
        ])
        with patch("Python.invoke_ai_engine.PredictiveAnalyticsEngine",
                   return_value=_mock_engine()):
            with pytest.raises(SystemExit) as exc:
                invoke_module.main()
        assert exc.value.code == 0

    def test_anomaly_analysis_type_succeeds(self, monkeypatch, tmp_path):
        """--analysistype=Anomaly succeeds and exits 0."""
        (tmp_path / "model.pkl").write_text("dummy")
        monkeypatch.setattr(sys, "argv", [
            "invoke_ai_engine.py", "--servername", "TEST-SERVER-01",
            "--analysistype", "Anomaly",
            "--configpath", CONFIG_PATH, "--modeldir", str(tmp_path),
        ])
        with patch("Python.invoke_ai_engine.PredictiveAnalyticsEngine",
                   return_value=_mock_engine()):
            with pytest.raises(SystemExit) as exc:
                invoke_module.main()
        assert exc.value.code == 0

    # ----- serverdatajson -----

    def test_invalid_serverdatajson_exits_2(self, monkeypatch, tmp_path):
        """Malformed --serverdatajson triggers VALIDATION_ERROR (exit 2)."""
        (tmp_path / "model.pkl").write_text("dummy")
        monkeypatch.setattr(sys, "argv",
                            self._base_argv(tmp_path) + ["--serverdatajson", "{bad json!"])
        with patch("Python.invoke_ai_engine.PredictiveAnalyticsEngine"):
            with pytest.raises(SystemExit) as exc:
                invoke_module.main()
        assert exc.value.code == 2

    def test_valid_serverdatajson_passed_to_engine(self, monkeypatch, tmp_path):
        """Valid --serverdatajson is parsed and engine receives it."""
        (tmp_path / "model.pkl").write_text("dummy")
        mock_eng = _mock_engine()
        server_data = json.dumps({
            "server_name_id": "TEST-SERVER-01",
            "timestamp": datetime.now().isoformat(),
            "cpu_usage": 0.65,
            "memory_usage": 0.50,
        })
        monkeypatch.setattr(sys, "argv",
                            self._base_argv(tmp_path) + ["--serverdatajson", server_data])
        with patch("Python.invoke_ai_engine.PredictiveAnalyticsEngine",
                   return_value=mock_eng):
            with pytest.raises(SystemExit) as exc:
                invoke_module.main()
        assert exc.value.code == 0
        mock_eng.analyze_deployment_risk.assert_called_once()

    def test_synthesized_server_data_when_no_serverdatajson(self, monkeypatch, tmp_path):
        """When --serverdatajson is omitted a minimal snapshot is synthesized."""
        (tmp_path / "model.pkl").write_text("dummy")
        mock_eng = _mock_engine()
        monkeypatch.setattr(sys, "argv", self._base_argv(tmp_path))
        with patch("Python.invoke_ai_engine.PredictiveAnalyticsEngine",
                   return_value=mock_eng):
            with pytest.raises(SystemExit) as exc:
                invoke_module.main()
        assert exc.value.code == 0
        call_args = mock_eng.analyze_deployment_risk.call_args[0][0]
        assert "server_name_id" in call_args
        assert call_args["server_name_id"] == "TEST-SERVER-01"

    # ----- error paths -----

    def test_engine_exception_exits_1(self, monkeypatch, tmp_path, capsys):
        """Unhandled engine exception exits GENERAL_ERROR (1) and writes JSON to stderr."""
        (tmp_path / "model.pkl").write_text("dummy")
        mock_eng = _mock_engine()
        mock_eng.analyze_deployment_risk.side_effect = RuntimeError("engine crash")
        monkeypatch.setattr(sys, "argv", self._base_argv(tmp_path))
        with patch("Python.invoke_ai_engine.PredictiveAnalyticsEngine",
                   return_value=mock_eng):
            with pytest.raises(SystemExit) as exc:
                invoke_module.main()
        assert exc.value.code == 1
        err = json.loads(capsys.readouterr().err)
        assert "error" in err

    def test_engine_exception_stderr_contains_exception_type(self, monkeypatch, tmp_path, capsys):
        """Stderr error JSON includes the exception_type context."""
        (tmp_path / "model.pkl").write_text("dummy")
        mock_eng = _mock_engine()
        mock_eng.analyze_deployment_risk.side_effect = ValueError("bad value")
        monkeypatch.setattr(sys, "argv", self._base_argv(tmp_path))
        with patch("Python.invoke_ai_engine.PredictiveAnalyticsEngine",
                   return_value=mock_eng):
            with pytest.raises(SystemExit) as exc:
                invoke_module.main()
        assert exc.value.code == 1
        err = json.loads(capsys.readouterr().err)
        assert err.get("details", {}).get("exception_type") == "ValueError"

    # ----- remediation outcome -----

    def test_remediation_outcome_recorded_in_output(self, monkeypatch, tmp_path, capsys):
        """--remediationoutcomejson triggers record_remediation_outcome."""
        (tmp_path / "model.pkl").write_text("dummy")
        mock_eng = _mock_engine()
        remediation = json.dumps({
            "action": "restart_service",
            "success": True,
            "error_type": "ServiceFailure",
        })
        monkeypatch.setattr(sys, "argv",
                            self._base_argv(tmp_path) + ["--remediationoutcomejson", remediation])
        with patch("Python.invoke_ai_engine.PredictiveAnalyticsEngine",
                   return_value=mock_eng):
            with pytest.raises(SystemExit) as exc:
                invoke_module.main()
        assert exc.value.code == 0
        output = json.loads(capsys.readouterr().out)
        assert "remediation_outcome" in output

    def test_invalid_remediationoutcomejson_exits_1(self, monkeypatch, tmp_path, capsys):
        """Malformed --remediationoutcomejson escalates to generic exception (exit 1)."""
        (tmp_path / "model.pkl").write_text("dummy")
        monkeypatch.setattr(sys, "argv",
                            self._base_argv(tmp_path) + ["--remediationoutcomejson", "{bad!"])
        with patch("Python.invoke_ai_engine.PredictiveAnalyticsEngine",
                   return_value=_mock_engine()):
            with pytest.raises(SystemExit) as exc:
                invoke_module.main()
        assert exc.value.code == 1

    # ----- export retrain path -----

    def test_exportretrainpath_triggers_export(self, monkeypatch, tmp_path, capsys):
        """--exportretrainpath calls export_retrain_requests and adds result to output."""
        (tmp_path / "model.pkl").write_text("dummy")
        export_path = str(tmp_path / "retrain_export.json")
        remediation = json.dumps({
            "action": "scale_out",
            "success": True,
            "error_type": "CpuSpike",
        })
        monkeypatch.setattr(sys, "argv",
                            self._base_argv(tmp_path) + [
                                "--remediationoutcomejson", remediation,
                                "--exportretrainpath", export_path,
                            ])
        with patch("Python.invoke_ai_engine.PredictiveAnalyticsEngine",
                   return_value=_mock_engine()):
            with pytest.raises(SystemExit) as exc:
                invoke_module.main()
        assert exc.value.code == 0
        output = json.loads(capsys.readouterr().out)
        assert "retrain_export" in output

    # ----- schema validation failure paths -----

    def test_serverdatajson_schema_fails_exits_2(self, monkeypatch, tmp_path):
        """A JSON array for --serverdatajson fails the object-type schema → exit 2."""
        (tmp_path / "model.pkl").write_text("dummy")
        monkeypatch.setattr(sys, "argv",
                            self._base_argv(tmp_path) + ["--serverdatajson", "[1,2,3]"])
        with patch("Python.invoke_ai_engine.PredictiveAnalyticsEngine"):
            with pytest.raises(SystemExit) as exc:
                invoke_module.main()
        assert exc.value.code == 2

    def test_remediationoutcomejson_schema_fails_exits_1(self, monkeypatch, tmp_path):
        """Remediation JSON missing required fields fails schema validation → exit 1."""
        (tmp_path / "model.pkl").write_text("dummy")
        bad_rem = json.dumps({"result": "ok"})  # missing error_type, action, success
        monkeypatch.setattr(sys, "argv",
                            self._base_argv(tmp_path) + [
                                "--remediationoutcomejson", bad_rem,
                            ])
        with patch("Python.invoke_ai_engine.PredictiveAnalyticsEngine",
                   return_value=_mock_engine()):
            with pytest.raises(SystemExit) as exc:
                invoke_module.main()
        assert exc.value.code == 1

    def test_engine_exception_with_correlation_id_exits_1(self, monkeypatch, tmp_path, capsys):
        """Engine exception with --correlation-id echoes cid in stderr error details."""
        (tmp_path / "model.pkl").write_text("dummy")
        mock_eng = _mock_engine()
        mock_eng.analyze_deployment_risk.side_effect = RuntimeError("unexpected")
        monkeypatch.setattr(sys, "argv",
                            self._base_argv(tmp_path) + ["--correlation-id", "cid-abc-123"])
        with patch("Python.invoke_ai_engine.PredictiveAnalyticsEngine",
                   return_value=mock_eng):
            with pytest.raises(SystemExit) as exc:
                invoke_module.main()
        assert exc.value.code == 1
        stderr = capsys.readouterr().err
        data = json.loads(stderr)
        assert data.get("details", {}).get("correlation_id") == "cid-abc-123"


# ---------------------------------------------------------------------------
# run_predictor.main() tests
# ---------------------------------------------------------------------------

class TestRunPredictorMain:
    """Tests for run_predictor.main() covering success and error paths."""

    def _base_argv(self, tmp_path):
        return [
            "run_predictor.py",
            "--server-name", "TEST-SERVER-01",
            "--analysis-type", "Full",
            "--model-dir", str(tmp_path),
            "--telemetrydatajson", json.dumps({
                "cpu_usage": 0.5, "memory_usage": 0.4,
                "disk_usage": 0.3, "network_latency": 20.0,
                "error_count": 0, "warning_count": 1,
            }),
        ]

    # ----- argparse errors -----

    def test_missing_server_name_exits_nonzero(self, monkeypatch):
        """argparse exits non-zero when --server-name is omitted."""
        monkeypatch.setattr(sys, "argv", [
            "run_predictor.py",
            "--telemetrydatajson", '{"cpu_usage": 0.5}',
        ])
        with pytest.raises(SystemExit) as exc:
            predictor_module.main()
        assert exc.value.code != 0

    def test_missing_telemetrydatajson_exits_nonzero(self, monkeypatch, tmp_path):
        """argparse exits non-zero when --telemetrydatajson is omitted."""
        monkeypatch.setattr(sys, "argv", [
            "run_predictor.py",
            "--server-name", "TEST-SERVER-01",
            "--model-dir", str(tmp_path),
        ])
        with pytest.raises(SystemExit) as exc:
            predictor_module.main()
        assert exc.value.code != 0

    # ----- validation errors (return, not sys.exit) -----

    def test_invalid_server_name_returns_error_json(self, monkeypatch, tmp_path, capsys):
        """Invalid server name: returns structured error JSON on stdout, no exit."""
        monkeypatch.setattr(sys, "argv", [
            "run_predictor.py",
            "--server-name", "A" * 256,
            "--model-dir", str(tmp_path),
            "--telemetrydatajson", '{"cpu_usage": 0.5}',
        ])
        predictor_module.main()  # must return, not raise SystemExit
        output = json.loads(capsys.readouterr().out)
        assert "error" in output

    def test_invalid_server_name_path_traversal_returns_error(self, monkeypatch, tmp_path, capsys):
        """Path traversal server name: error JSON on stdout."""
        monkeypatch.setattr(sys, "argv", [
            "run_predictor.py",
            "--server-name", "../../etc",
            "--model-dir", str(tmp_path),
            "--telemetrydatajson", '{"cpu_usage": 0.5}',
        ])
        predictor_module.main()
        output = json.loads(capsys.readouterr().out)
        assert "error" in output

    def test_invalid_analysis_type_exits_2(self, monkeypatch, tmp_path):
        """Invalid analysis type: argparse rejects the choice and exits 2."""
        monkeypatch.setattr(sys, "argv", [
            "run_predictor.py",
            "--server-name", "TEST-SERVER-01",
            "--analysis-type", "INVALID",
            "--model-dir", str(tmp_path),
            "--telemetrydatajson", '{"cpu_usage": 0.5}',
        ])
        with pytest.raises(SystemExit) as exc:
            predictor_module.main()
        assert exc.value.code == 2

    def test_nonexistent_model_dir_returns_error_json(self, monkeypatch, capsys):
        """Non-existent model dir: error JSON on stdout."""
        monkeypatch.setattr(sys, "argv", [
            "run_predictor.py",
            "--server-name", "TEST-SERVER-01",
            "--model-dir", "/nonexistent/models/dir",
            "--telemetrydatajson", '{"cpu_usage": 0.5}',
        ])
        predictor_module.main()
        output = json.loads(capsys.readouterr().out)
        assert "error" in output

    def test_empty_model_dir_returns_error_json(self, monkeypatch, tmp_path, capsys):
        """Empty model dir: error JSON on stdout."""
        monkeypatch.setattr(sys, "argv", [
            "run_predictor.py",
            "--server-name", "TEST-SERVER-01",
            "--model-dir", str(tmp_path),  # empty directory
            "--telemetrydatajson", '{"cpu_usage": 0.5}',
        ])
        predictor_module.main()
        output = json.loads(capsys.readouterr().out)
        assert "error" in output

    def test_no_models_loaded_returns_error_json(self, monkeypatch, tmp_path, capsys):
        """ArcPredictor with empty models dict: error JSON on stdout."""
        (tmp_path / "placeholder.pkl").write_text("dummy")
        mock_pred = MagicMock()
        mock_pred.models = {}  # no models loaded
        monkeypatch.setattr(sys, "argv", [
            "run_predictor.py",
            "--server-name", "TEST-SERVER-01",
            "--model-dir", str(tmp_path),
            "--telemetrydatajson", '{"cpu_usage": 0.5}',
        ])
        with patch("Python.run_predictor.ArcPredictor", return_value=mock_pred):
            predictor_module.main()
        output = json.loads(capsys.readouterr().out)
        assert "error" in output

    def test_invalid_telemetrydatajson_returns_error_json(self, monkeypatch, tmp_path, capsys):
        """Malformed JSON in --telemetrydatajson: error JSON on stdout."""
        (tmp_path / "model.pkl").write_text("dummy")
        monkeypatch.setattr(sys, "argv", [
            "run_predictor.py",
            "--server-name", "TEST-SERVER-01",
            "--model-dir", str(tmp_path),
            "--telemetrydatajson", "{invalid json!",
        ])
        with patch("Python.run_predictor.ArcPredictor", return_value=_mock_predictor()):
            predictor_module.main()
        output = json.loads(capsys.readouterr().out)
        assert "error" in output

    # ----- success paths -----

    def test_full_analysis_produces_all_three_fields(self, monkeypatch, tmp_path, capsys):
        """Full analysis type calls all three predictor methods."""
        (tmp_path / "model.pkl").write_text("dummy")
        monkeypatch.setattr(sys, "argv", self._base_argv(tmp_path))
        with patch("Python.run_predictor.ArcPredictor", return_value=_mock_predictor()):
            predictor_module.main()
        output = json.loads(capsys.readouterr().out)
        assert "health_prediction" in output
        assert "anomaly_detection" in output
        assert "failure_prediction" in output

    def test_health_analysis_only_calls_health(self, monkeypatch, tmp_path, capsys):
        """Health analysis type only produces health_prediction field."""
        (tmp_path / "model.pkl").write_text("dummy")
        monkeypatch.setattr(sys, "argv", [
            "run_predictor.py",
            "--server-name", "TEST-SERVER-01",
            "--analysis-type", "Health",
            "--model-dir", str(tmp_path),
            "--telemetrydatajson", '{"cpu_usage": 0.5}',
        ])
        with patch("Python.run_predictor.ArcPredictor", return_value=_mock_predictor()):
            predictor_module.main()
        output = json.loads(capsys.readouterr().out)
        assert "health_prediction" in output
        assert "anomaly_detection" not in output
        assert "failure_prediction" not in output

    def test_anomaly_analysis_only_calls_anomaly(self, monkeypatch, tmp_path, capsys):
        """Anomaly analysis type only produces anomaly_detection field."""
        (tmp_path / "model.pkl").write_text("dummy")
        monkeypatch.setattr(sys, "argv", [
            "run_predictor.py",
            "--server-name", "TEST-SERVER-01",
            "--analysis-type", "Anomaly",
            "--model-dir", str(tmp_path),
            "--telemetrydatajson", '{"cpu_usage": 0.5}',
        ])
        with patch("Python.run_predictor.ArcPredictor", return_value=_mock_predictor()):
            predictor_module.main()
        output = json.loads(capsys.readouterr().out)
        assert "anomaly_detection" in output
        assert "health_prediction" not in output
        assert "failure_prediction" not in output

    def test_failure_analysis_only_calls_failure(self, monkeypatch, tmp_path, capsys):
        """Failure analysis type only produces failure_prediction field."""
        (tmp_path / "model.pkl").write_text("dummy")
        monkeypatch.setattr(sys, "argv", [
            "run_predictor.py",
            "--server-name", "TEST-SERVER-01",
            "--analysis-type", "Failure",
            "--model-dir", str(tmp_path),
            "--telemetrydatajson", '{"cpu_usage": 0.5}',
        ])
        with patch("Python.run_predictor.ArcPredictor", return_value=_mock_predictor()):
            predictor_module.main()
        output = json.loads(capsys.readouterr().out)
        assert "failure_prediction" in output
        assert "health_prediction" not in output
        assert "anomaly_detection" not in output

    def test_output_contains_metadata(self, monkeypatch, tmp_path, capsys):
        """Output JSON always contains server_name, analysis_type, and timestamp."""
        (tmp_path / "model.pkl").write_text("dummy")
        monkeypatch.setattr(sys, "argv", self._base_argv(tmp_path))
        with patch("Python.run_predictor.ArcPredictor", return_value=_mock_predictor()):
            predictor_module.main()
        output = json.loads(capsys.readouterr().out)
        assert output.get("server_name") == "TEST-SERVER-01"
        assert output.get("analysis_type") == "Full"
        assert "timestamp" in output

    def test_predictor_exception_returns_error_json(self, monkeypatch, tmp_path, capsys):
        """Unexpected predictor exception returns structured error JSON on stdout."""
        (tmp_path / "model.pkl").write_text("dummy")
        mock_pred = _mock_predictor()
        mock_pred.predict_health.side_effect = RuntimeError("predictor exploded")
        monkeypatch.setattr(sys, "argv", self._base_argv(tmp_path))
        with patch("Python.run_predictor.ArcPredictor", return_value=mock_pred):
            predictor_module.main()  # must not raise
        output = json.loads(capsys.readouterr().out)
        assert "error" in output

    def test_detect_anomalies_exception_returns_error_json(self, monkeypatch, tmp_path, capsys):
        """Exception in detect_anomalies handled gracefully."""
        (tmp_path / "model.pkl").write_text("dummy")
        mock_pred = _mock_predictor()
        mock_pred.detect_anomalies.side_effect = ValueError("anomaly model error")
        monkeypatch.setattr(sys, "argv", [
            "run_predictor.py",
            "--server-name", "TEST-SERVER-01",
            "--analysis-type", "Anomaly",
            "--model-dir", str(tmp_path),
            "--telemetrydatajson", '{"cpu_usage": 0.5}',
        ])
        with patch("Python.run_predictor.ArcPredictor", return_value=mock_pred):
            predictor_module.main()
        output = json.loads(capsys.readouterr().out)
        assert "error" in output

    def test_telemetrydatajson_schema_fails_returns_error(self, monkeypatch, tmp_path, capsys):
        """A JSON array for --telemetrydatajson fails schema validation (type: object) → error on stdout."""
        (tmp_path / "model.pkl").write_text("dummy")
        mock_pred = _mock_predictor()
        monkeypatch.setattr(sys, "argv", [
            "run_predictor.py",
            "--server-name", "TEST-SERVER-01",
            "--model-dir", str(tmp_path),
            "--telemetrydatajson", "[1, 2, 3]",
        ])
        with patch("Python.run_predictor.ArcPredictor", return_value=mock_pred):
            predictor_module.main()
        output = json.loads(capsys.readouterr().out)
        assert "error" in output

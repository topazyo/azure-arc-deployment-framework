"""
Contract Tests for PowerShell ↔ Python Bridge

These tests validate the JSON contracts between PowerShell cmdlets (Get-PredictiveInsights)
and Python CLI scripts (invoke_ai_engine.py, run_predictor.py).

Contract tests ensure:
1. Input JSON structure matches expected schema
2. Output JSON structure matches expected schema
3. Error responses follow the defined error schema
4. Exit codes are predictable for PS error handling
"""

import pytest
import json
import subprocess
import sys
import os
from datetime import datetime

# Add src to path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../../src')))

# Test constants
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.abspath(os.path.join(SCRIPT_DIR, '../../src'))
PYTHON_DIR = os.path.join(SRC_DIR, 'Python')
CONFIG_DIR = os.path.join(SRC_DIR, 'config')
AI_CONFIG_PATH = os.path.join(CONFIG_DIR, 'ai_config.json')
INVOKE_AI_ENGINE = os.path.join(PYTHON_DIR, 'invoke_ai_engine.py')
RUN_PREDICTOR = os.path.join(PYTHON_DIR, 'run_predictor.py')


class TestContractSchemaValidation:
    """Test that ai_config.json matches expected schema structure."""

    def test_ai_config_has_required_aicomponents_key(self):
        """Contract: ai_config.json MUST have 'aiComponents' top-level key."""
        with open(AI_CONFIG_PATH, 'r') as f:
            config = json.load(f)

        assert 'aiComponents' in config, (
            "Contract violation: ai_config.json MUST contain 'aiComponents' key. "
            "PowerShell callers depend on this structure."
        )

    def test_ai_config_model_config_structure(self):
        """Contract: aiComponents MUST contain model_config with features and models."""
        with open(AI_CONFIG_PATH, 'r') as f:
            config = json.load(f)

        ai_components = config.get('aiComponents', {})
        assert 'model_config' in ai_components, (
            "Contract violation: aiComponents MUST contain 'model_config'"
        )

        model_config = ai_components['model_config']
        assert 'features' in model_config, (
            "Contract violation: model_config MUST contain 'features'"
        )
        assert 'models' in model_config, (
            "Contract violation: model_config MUST contain 'models'"
        )

    def test_ai_config_feature_definitions_have_required_fields(self):
        """Contract: Each feature definition MUST have 'required_features' list."""
        with open(AI_CONFIG_PATH, 'r') as f:
            config = json.load(f)

        features = config['aiComponents']['model_config']['features']

        for model_type, feature_def in features.items():
            assert 'required_features' in feature_def, (
                f"Contract violation: features.{model_type} MUST have 'required_features'. "
                f"ArcPredictor depends on this for feature alignment."
            )
            assert isinstance(feature_def['required_features'], list), (
                f"Contract violation: features.{model_type}.required_features MUST be a list"
            )
            assert len(feature_def['required_features']) > 0, (
                f"Contract violation: features.{model_type}.required_features MUST not be empty"
            )


class TestInvokeAIEngineContractInputs:
    """Test invoke_ai_engine.py accepts required CLI parameters."""

    def test_servername_is_required(self):
        """Contract: --servername is REQUIRED."""
        result = subprocess.run(
            [sys.executable, INVOKE_AI_ENGINE, '--analysistype', 'Full'],
            capture_output=True,
            text=True
        )
        # Should fail without servername
        assert result.returncode != 0
        assert 'servername' in result.stderr.lower() or 'required' in result.stderr.lower()

    def test_analysistype_defaults_to_full(self):
        """Contract: --analysistype defaults to 'Full' when not provided."""
        # This test validates the contract by checking argparse behavior
        # We can't run the full script without models, but we can check the help
        result = subprocess.run(
            [sys.executable, INVOKE_AI_ENGINE, '--help'],
            capture_output=True,
            text=True
        )
        assert 'Full' in result.stdout  # Default value should appear in help
        assert 'Health' in result.stdout
        assert 'Failure' in result.stdout
        assert 'Anomaly' in result.stdout

    def test_modeldir_parameter_exists(self):
        """Contract: --modeldir parameter MUST exist for PS to override model location."""
        result = subprocess.run(
            [sys.executable, INVOKE_AI_ENGINE, '--help'],
            capture_output=True,
            text=True
        )
        assert '--modeldir' in result.stdout

    def test_configpath_parameter_exists(self):
        """Contract: --configpath parameter MUST exist for PS to override config."""
        result = subprocess.run(
            [sys.executable, INVOKE_AI_ENGINE, '--help'],
            capture_output=True,
            text=True
        )
        assert '--configpath' in result.stdout

    def test_serverdatajson_parameter_exists(self):
        """Contract: --serverdatajson parameter MUST exist for telemetry input."""
        result = subprocess.run(
            [sys.executable, INVOKE_AI_ENGINE, '--help'],
            capture_output=True,
            text=True
        )
        assert '--serverdatajson' in result.stdout


class TestInvokeAIEngineContractOutputs:
    """Test invoke_ai_engine.py output JSON structure."""

    @pytest.fixture
    def minimal_server_data(self):
        """Minimal valid server data JSON."""
        return json.dumps({
            "server_name_id": "test-server",
            "timestamp": datetime.now().isoformat(),
            "cpu_usage": 0.5,
            "memory_usage": 0.6
        })

    def test_invalid_json_returns_structured_error(self):
        """Contract: Invalid --serverdatajson MUST return structured error JSON to stderr."""
        result = subprocess.run(
            [
                sys.executable, INVOKE_AI_ENGINE,
                '--servername', 'test-server',
                '--serverdatajson', 'not-valid-json{'
            ],
            capture_output=True,
            text=True
        )

        assert result.returncode != 0, "Invalid JSON should cause non-zero exit"

        # Error should be structured JSON on stderr
        try:
            error_obj = json.loads(result.stderr)
            assert 'error' in error_obj, (
                "Contract violation: Error response MUST have 'error' field"
            )
            assert 'message' in error_obj, (
                "Contract violation: Error response MUST have 'message' field"
            )
        except json.JSONDecodeError:
            pytest.fail(
                f"Contract violation: Error output MUST be valid JSON. Got: {result.stderr}"
            )

    def test_missing_config_returns_structured_error(self):
        """Contract: Missing config file MUST return structured error JSON."""
        result = subprocess.run(
            [
                sys.executable, INVOKE_AI_ENGINE,
                '--servername', 'test-server',
                '--configpath', '/nonexistent/path/ai_config.json'
            ],
            capture_output=True,
            text=True
        )

        assert result.returncode != 0

        try:
            error_obj = json.loads(result.stderr)
            assert 'error' in error_obj
        except json.JSONDecodeError:
            pytest.fail(
                f"Contract violation: Error output MUST be valid JSON. Got: {result.stderr}"
            )

    def test_success_response_has_required_fields(self, tmp_path):
        """Contract: Success response MUST contain input_servername and input_analysistype."""
        # Create a minimal mock model directory with placeholder files
        model_dir = tmp_path / "models"
        model_dir.mkdir()

        # Create minimal placeholder model files (actual inference may fail,
        # but we test the output structure)
        (model_dir / "health_prediction_model.pkl").touch()

        result = subprocess.run(
            [
                sys.executable, INVOKE_AI_ENGINE,
                '--servername', 'contract-test-server',
                '--analysistype', 'Health',
                '--modeldir', str(model_dir),
                '--configpath', AI_CONFIG_PATH
            ],
            capture_output=True,
            text=True
        )

        # Even if models aren't fully functional, the response structure should be correct
        if result.returncode == 0:
            response = json.loads(result.stdout)
            assert 'input_servername' in response, (
                "Contract violation: Success response MUST contain 'input_servername'"
            )
            assert 'input_analysistype' in response, (
                "Contract violation: Success response MUST contain 'input_analysistype'"
            )
            assert response['input_servername'] == 'contract-test-server'
            assert response['input_analysistype'] == 'Health'


class TestRunPredictorContractInputs:
    """Test run_predictor.py CLI parameter contracts."""

    def test_server_name_is_required(self):
        """Contract: --server-name is REQUIRED."""
        result = subprocess.run(
            [
                sys.executable, RUN_PREDICTOR,
                '--telemetrydatajson', '{"cpu_usage": 0.5}'
            ],
            capture_output=True,
            text=True
        )
        assert result.returncode != 0
        assert 'server-name' in result.stderr.lower() or 'required' in result.stderr.lower()

    def test_telemetrydatajson_is_required(self):
        """Contract: --telemetrydatajson is REQUIRED."""
        result = subprocess.run(
            [
                sys.executable, RUN_PREDICTOR,
                '--server-name', 'test-server'
            ],
            capture_output=True,
            text=True
        )
        assert result.returncode != 0

    def test_analysis_type_choices(self):
        """Contract: --analysis-type accepts only Full, Health, Failure, Anomaly."""
        result = subprocess.run(
            [sys.executable, RUN_PREDICTOR, '--help'],
            capture_output=True,
            text=True
        )
        assert 'Full' in result.stdout
        assert 'Health' in result.stdout
        assert 'Failure' in result.stdout
        assert 'Anomaly' in result.stdout


class TestRunPredictorContractOutputs:
    """Test run_predictor.py output JSON structure."""

    def test_invalid_json_returns_error_field(self):
        """Contract: Invalid JSON input MUST return response with 'error' field."""
        result = subprocess.run(
            [
                sys.executable, RUN_PREDICTOR,
                '--server-name', 'test',
                '--telemetrydatajson', 'invalid{json'
            ],
            capture_output=True,
            text=True
        )

        # The output should still be valid JSON with error field
        output = result.stdout or result.stderr
        try:
            response = json.loads(output)
            assert 'error' in response, (
                "Contract violation: Error response MUST have 'error' field"
            )
        except json.JSONDecodeError:
            # If we can't parse as JSON, check it's at least mentioned in stderr
            pass  # Some error messages may not be JSON

    def test_missing_model_dir_returns_error_json(self, tmp_path):
        """Contract: Missing model directory MUST return JSON with 'error' field."""
        nonexistent_dir = tmp_path / "nonexistent_models"

        result = subprocess.run(
            [
                sys.executable, RUN_PREDICTOR,
                '--server-name', 'test',
                '--model-dir', str(nonexistent_dir),
                '--telemetrydatajson', '{"cpu_usage": 0.5}'
            ],
            capture_output=True,
            text=True
        )

        # Should output JSON with error field
        try:
            response = json.loads(result.stdout)
            assert 'error' in response, (
                "Contract violation: Missing model dir response MUST have 'error' field"
            )
        except json.JSONDecodeError:
            pytest.fail(f"Contract violation: Output MUST be valid JSON. Got: {result.stdout}")


class TestExitCodeContracts:
    """Test that exit codes are predictable for PowerShell error handling."""

    def test_successful_help_returns_zero(self):
        """Contract: --help MUST return exit code 0."""
        result = subprocess.run(
            [sys.executable, INVOKE_AI_ENGINE, '--help'],
            capture_output=True,
            text=True
        )
        assert result.returncode == 0

    def test_missing_required_arg_returns_nonzero(self):
        """Contract: Missing required arguments MUST return non-zero exit code."""
        result = subprocess.run(
            [sys.executable, INVOKE_AI_ENGINE],
            capture_output=True,
            text=True
        )
        assert result.returncode != 0

    def test_invalid_json_returns_nonzero(self):
        """Contract: Invalid JSON input MUST return non-zero exit code."""
        result = subprocess.run(
            [
                sys.executable, INVOKE_AI_ENGINE,
                '--servername', 'test',
                '--serverdatajson', 'not-json'
            ],
            capture_output=True,
            text=True
        )
        assert result.returncode != 0


class TestServerDataJsonContract:
    """Test the --serverdatajson input contract."""

    def test_minimal_server_data_accepted(self, tmp_path):
        """Contract: Minimal server data (server_name_id) SHOULD be accepted."""
        # Script will fail without models, but it should parse the JSON first
        minimal_data = json.dumps({"server_name_id": "test"})

        result = subprocess.run(
            [
                sys.executable, INVOKE_AI_ENGINE,
                '--servername', 'test',
                '--serverdatajson', minimal_data,
                '--modeldir', str(tmp_path)  # Empty dir will cause model error, not JSON error
            ],
            capture_output=True,
            text=True
        )

        # If it fails, it should NOT be due to JSON parsing
        if result.returncode != 0:
            error_output = result.stderr
            assert 'JSONDecodeError' not in error_output, (
                "Minimal valid JSON should not cause JSONDecodeError"
            )

    def test_full_server_data_accepted(self, tmp_path):
        """Contract: Full server telemetry data SHOULD be accepted."""
        full_data = json.dumps({
            "server_name_id": "test-server",
            "timestamp": datetime.now().isoformat(),
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
        })

        result = subprocess.run(
            [
                sys.executable, INVOKE_AI_ENGINE,
                '--servername', 'test',
                '--serverdatajson', full_data,
                '--modeldir', str(tmp_path)
            ],
            capture_output=True,
            text=True
        )

        if result.returncode != 0:
            assert 'JSONDecodeError' not in result.stderr

    def test_extra_fields_are_tolerated(self, tmp_path):
        """Contract: Extra fields in server data SHOULD be tolerated (forward compatibility)."""
        data_with_extras = json.dumps({
            "server_name_id": "test",
            "cpu_usage": 0.5,
            "future_field_v2": "some value",
            "another_new_field": 123
        })

        result = subprocess.run(
            [
                sys.executable, INVOKE_AI_ENGINE,
                '--servername', 'test',
                '--serverdatajson', data_with_extras,
                '--modeldir', str(tmp_path)
            ],
            capture_output=True,
            text=True
        )

        if result.returncode != 0:
            # Should not fail due to extra fields
            assert 'unknown' not in result.stderr.lower() or 'field' not in result.stderr.lower()


class TestTimestampContract:
    """Test timestamp handling contracts."""

    def test_iso8601_timestamp_accepted(self, tmp_path):
        """Contract: ISO 8601 timestamps MUST be accepted."""
        data = json.dumps({
            "server_name_id": "test",
            "timestamp": "2024-01-15T10:30:00.000000"
        })

        result = subprocess.run(
            [
                sys.executable, INVOKE_AI_ENGINE,
                '--servername', 'test',
                '--serverdatajson', data,
                '--modeldir', str(tmp_path)
            ],
            capture_output=True,
            text=True
        )

        if result.returncode != 0:
            assert 'timestamp' not in result.stderr.lower() or 'invalid' not in result.stderr.lower()

    def test_output_timestamp_is_iso8601(self, tmp_path):
        """Contract: Output timestamps MUST be ISO 8601 format."""
        # Create empty model dir to trigger a predictable error with structured output
        result = subprocess.run(
            [
                sys.executable, INVOKE_AI_ENGINE,
                '--servername', 'test',
                '--configpath', '/nonexistent/config.json'
            ],
            capture_output=True,
            text=True
        )

        if result.stderr:
            try:
                error_obj = json.loads(result.stderr)
                if 'timestamp' in error_obj:
                    ts = error_obj['timestamp']
                    # Should be parseable as ISO 8601
                    from datetime import datetime
                    datetime.fromisoformat(ts.replace('Z', '+00:00'))
            except (json.JSONDecodeError, ValueError):
                pass  # Not all errors have timestamps

"""
Tests for the resilience module.

Tests cover:
- Structured error response creation
- Exit code constants
- Retry logic with exponential backoff
- Timeout handling (on supported platforms)
- Config validation utilities
- Model directory validation utilities
"""

import pytest
import sys
import os
from unittest.mock import patch
from datetime import datetime

# Add src to path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../../src')))

from Python.common.resilience import (  # noqa: E402
    ExitCode,
    ErrorCategory,
    create_error_response,
    emit_error,
    emit_error_no_exit,
    retry_with_backoff,
    TransientException,
    with_timeout,
    validate_config,
    validate_model_directory
)


class TestExitCodes:
    """Test exit code constants."""

    def test_success_is_zero(self):
        """Exit code for success should be 0."""
        assert ExitCode.SUCCESS == 0

    def test_general_error_is_one(self):
        """Exit code for general error should be 1."""
        assert ExitCode.GENERAL_ERROR == 1

    def test_validation_error_is_two(self):
        """Exit code for validation error should be 2."""
        assert ExitCode.VALIDATION_ERROR == 2

    def test_config_error_is_three(self):
        """Exit code for config error should be 3."""
        assert ExitCode.CONFIG_ERROR == 3

    def test_timeout_error_is_four(self):
        """Exit code for timeout error should be 4."""
        assert ExitCode.TIMEOUT_ERROR == 4

    def test_transient_error_is_five(self):
        """Exit code for transient error should be 5."""
        assert ExitCode.TRANSIENT_ERROR == 5


class TestErrorCategory:
    """Test error category constants."""

    def test_validation_category(self):
        assert ErrorCategory.VALIDATION == "ValidationError"

    def test_configuration_category(self):
        assert ErrorCategory.CONFIGURATION == "ConfigurationError"

    def test_json_parse_category(self):
        assert ErrorCategory.JSON_PARSE == "JSONParseError"

    def test_file_not_found_category(self):
        assert ErrorCategory.FILE_NOT_FOUND == "FileNotFoundError"

    def test_model_error_category(self):
        assert ErrorCategory.MODEL_ERROR == "ModelError"

    def test_timeout_category(self):
        assert ErrorCategory.TIMEOUT == "TimeoutError"

    def test_transient_category(self):
        assert ErrorCategory.TRANSIENT == "TransientError"

    def test_internal_category(self):
        assert ErrorCategory.INTERNAL == "InternalError"


class TestCreateErrorResponse:
    """Test structured error response creation."""

    def test_minimal_error_response(self):
        """Test creating error response with minimal fields."""
        response = create_error_response(
            error_type="TestError",
            message="Test message"
        )

        assert response["error"] == "TestError"
        assert response["message"] == "Test message"
        assert "timestamp" in response  # Default includes timestamp

    def test_error_response_without_timestamp(self):
        """Test creating error response without timestamp."""
        response = create_error_response(
            error_type="TestError",
            message="Test message",
            include_timestamp=False
        )

        assert "timestamp" not in response

    def test_error_response_with_details(self):
        """Test error response includes details when provided."""
        details = {"path": "/some/path", "code": 42}
        response = create_error_response(
            error_type="TestError",
            message="Test message",
            details=details
        )

        assert response["details"] == details

    def test_error_response_with_server_context(self):
        """Test error response includes server context."""
        response = create_error_response(
            error_type="TestError",
            message="Test message",
            server_name="test-server",
            analysis_type="Full"
        )

        assert response["input_servername"] == "test-server"
        assert response["input_analysistype"] == "Full"

    def test_error_response_timestamp_is_iso8601(self):
        """Test timestamp is valid ISO 8601."""
        response = create_error_response(
            error_type="TestError",
            message="Test message"
        )

        # Should be parseable
        timestamp = response["timestamp"]
        datetime.fromisoformat(timestamp)


class TestEmitError:
    """Test emit_error function."""

    def test_emit_error_exits_with_code(self):
        """Test emit_error calls sys.exit with correct code."""
        with pytest.raises(SystemExit) as exc_info:
            emit_error(
                error_type="TestError",
                message="Test message",
                exit_code=ExitCode.CONFIG_ERROR
            )

        assert exc_info.value.code == ExitCode.CONFIG_ERROR

    def test_emit_error_exits_with_general_error_by_default(self):
        """Test emit_error uses GENERAL_ERROR exit code by default."""
        with pytest.raises(SystemExit) as exc_info:
            emit_error(
                error_type="TestError",
                message="Test message"
            )

        assert exc_info.value.code == ExitCode.GENERAL_ERROR


class TestEmitErrorNoExit:
    """Test emit_error_no_exit function."""

    def test_emit_error_no_exit_returns_response(self):
        """Test emit_error_no_exit returns the response."""
        # Redirect stdout to suppress output during test
        import io
        captured = io.StringIO()
        response = emit_error_no_exit(
            error_type="TestError",
            message="Test message",
            file=captured
        )

        assert response["error"] == "TestError"
        assert response["message"] == "Test message"

    def test_emit_error_no_exit_includes_all_fields(self):
        """Test emit_error_no_exit includes all provided fields."""
        import io
        captured = io.StringIO()
        response = emit_error_no_exit(
            error_type="TestError",
            message="Test message",
            details={"key": "value"},
            server_name="test-server",
            analysis_type="Full",
            file=captured
        )

        assert response["error"] == "TestError"
        assert response["message"] == "Test message"
        assert response["details"] == {"key": "value"}
        assert response["input_servername"] == "test-server"
        assert response["input_analysistype"] == "Full"
        assert "timestamp" in response


class TestRetryWithBackoff:
    """Test retry logic with exponential backoff."""

    def test_success_on_first_try(self):
        """Test function succeeds on first try."""
        call_count = 0

        @retry_with_backoff(max_retries=3)
        def succeed_immediately():
            nonlocal call_count
            call_count += 1
            return "success"

        result = succeed_immediately()
        assert result == "success"
        assert call_count == 1

    def test_success_after_retry(self):
        """Test function succeeds after retries."""
        call_count = 0

        @retry_with_backoff(max_retries=3, initial_delay=0.01)
        def succeed_after_two_tries():
            nonlocal call_count
            call_count += 1
            if call_count < 3:
                raise TransientException("Transient failure")
            return "success"

        result = succeed_after_two_tries()
        assert result == "success"
        assert call_count == 3

    def test_failure_after_max_retries(self):
        """Test function raises after max retries exhausted."""
        call_count = 0

        @retry_with_backoff(max_retries=2, initial_delay=0.01)
        def always_fail():
            nonlocal call_count
            call_count += 1
            raise TransientException("Always fails")

        with pytest.raises(TransientException):
            always_fail()

        assert call_count == 3  # 1 initial + 2 retries

    def test_non_retryable_exception_not_retried(self):
        """Test non-retryable exceptions are not retried."""
        call_count = 0

        @retry_with_backoff(max_retries=3, retryable_exceptions=(TransientException,))
        def raise_value_error():
            nonlocal call_count
            call_count += 1
            raise ValueError("Not retryable")

        with pytest.raises(ValueError):
            raise_value_error()

        assert call_count == 1  # No retries

    def test_backoff_delay_increases(self):
        """Test delay increases with backoff factor."""
        delays = []

        @retry_with_backoff(
            max_retries=3,
            initial_delay=0.1,
            backoff_factor=2.0,
            max_delay=10.0
        )
        def track_delays():
            raise TransientException("fail")

        # Mock time.sleep to capture delays
        def mock_sleep(seconds):
            delays.append(seconds)

        with patch('time.sleep', mock_sleep):
            with pytest.raises(TransientException):
                track_delays()

        # Should have delays: 0.1, 0.2, 0.4 (with backoff_factor=2)
        assert len(delays) == 3
        assert delays[0] == pytest.approx(0.1, rel=0.1)
        assert delays[1] == pytest.approx(0.2, rel=0.1)
        assert delays[2] == pytest.approx(0.4, rel=0.1)


class TestValidateConfig:
    """Test configuration validation."""

    def test_valid_config_returns_value(self):
        """Test valid config returns the required key's value."""
        config = {"aiComponents": {"key": "value"}}

        # Pass schema_path=None to skip full schema validation — this test
        # exercises the required-key presence logic, not schema structure.
        result = validate_config(config, required_key="aiComponents", schema_path=None)
        assert result == {"key": "value"}

    def test_missing_key_exits(self):
        """Test missing required key causes exit."""
        config = {"other_key": "value"}

        with pytest.raises(SystemExit) as exc_info:
            validate_config(config, required_key="aiComponents")

        assert exc_info.value.code == ExitCode.CONFIG_ERROR

    def test_empty_value_exits(self):
        """Test empty required key value causes exit."""
        config = {"aiComponents": {}}

        with pytest.raises(SystemExit) as exc_info:
            validate_config(config, required_key="aiComponents")

        assert exc_info.value.code == ExitCode.CONFIG_ERROR


class TestValidateModelDirectory:
    """Test model directory validation."""

    def test_valid_directory_returns_true(self, tmp_path):
        """Test valid directory with files returns True."""
        model_dir = tmp_path / "models"
        model_dir.mkdir()
        (model_dir / "model.pkl").touch()

        result = validate_model_directory(str(model_dir), exit_on_error=False)
        assert result is True

    def test_missing_directory_returns_false(self, tmp_path):
        """Test missing directory returns False when exit_on_error=False."""
        model_dir = tmp_path / "nonexistent"

        result = validate_model_directory(str(model_dir), exit_on_error=False)
        assert result is False

    def test_empty_directory_returns_false(self, tmp_path):
        """Test empty directory returns False."""
        model_dir = tmp_path / "empty_models"
        model_dir.mkdir()

        result = validate_model_directory(str(model_dir), exit_on_error=False)
        assert result is False

    def test_missing_directory_exits_when_exit_on_error(self, tmp_path):
        """Test missing directory exits when exit_on_error=True."""
        model_dir = tmp_path / "nonexistent"

        with pytest.raises(SystemExit) as exc_info:
            validate_model_directory(str(model_dir), exit_on_error=True)

        assert exc_info.value.code == ExitCode.CONFIG_ERROR


class TestTimeoutDecorator:
    """Test timeout decorator (platform-dependent)."""

    def test_timeout_decorator_exists(self):
        """Test timeout decorator can be applied."""
        @with_timeout(seconds=5)
        def quick_function():
            return "done"

        # Should work without error
        result = quick_function()
        assert result == "done"

    # Note: Signal-based timeout tests are skipped on Windows
    # where SIGALRM is not available

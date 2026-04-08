"""
Tests for the security module (SEC-001, SEC-002, SEC-003).

Tests cover:
- Sensitive data detection and redaction
- Input validation (JSON, server names, analysis types, file paths)
- Secure logging filter
"""

import json
import logging
import pytest

from Python.common.security import (
    # SEC-001: Secrets handling
    is_sensitive_key,
    redact_sensitive_data,
    safe_json_for_logging,
    REDACTED_VALUE,
    # SEC-002: Input validation
    validate_json_string,
    parse_json_safely,
    validate_server_name,
    validate_analysis_type,
    validate_file_path,
    InputValidationError,
    # SEC-003: Safe logging
    SensitiveDataFilter,
    configure_secure_logging,
    get_secure_logger,
    safe_truncate,
)


# ===========================================================================
# SEC-001: Secrets Handling Tests
# ===========================================================================

class TestSensitiveKeyDetection:
    """Tests for is_sensitive_key function."""

    @pytest.mark.parametrize("key", [
        "password", "PASSWORD", "Password",
        "secret", "SECRET", "Secret",
        "api_key", "API_KEY", "apiKey", "ApiKey",
        "auth_token", "authToken", "AUTH_TOKEN",
        "access_token", "accessToken",
        "bearer", "Bearer", "BEARER",
        "credential", "credentials", "CREDENTIAL",
        "private_key", "privateKey",
        "connection_string", "connectionString",
        "workspace_key", "workspaceKey",
        "subscription_key",
        "sas_token", "sasToken",
        "shared_key", "sharedKey",
        "client_secret", "clientSecret",
    ])
    def test_sensitive_keys_detected(self, key):
        """Sensitive key names should be detected."""
        assert is_sensitive_key(key) is True

    @pytest.mark.parametrize("key", [
        "username", "email", "server_name",
        "cpu_usage", "memory_usage", "timestamp",
        "analysis_type", "model_dir", "config_path",
        "id", "name", "value", "data",
    ])
    def test_non_sensitive_keys_not_detected(self, key):
        """Non-sensitive key names should not be detected."""
        assert is_sensitive_key(key) is False

    def test_non_string_keys(self):
        """Non-string inputs should return False."""
        assert is_sensitive_key(123) is False
        assert is_sensitive_key(None) is False
        assert is_sensitive_key(['password']) is False


class TestRedactSensitiveData:
    """Tests for redact_sensitive_data function."""

    def test_redact_flat_dict(self):
        """Should redact sensitive values in flat dictionary."""
        data = {
            "username": "admin",
            "password": "secret123",
            "api_key": "abc123xyz",
            "server": "test-server"
        }
        result = redact_sensitive_data(data)

        assert result["username"] == "admin"
        assert result["password"] == REDACTED_VALUE
        assert result["api_key"] == REDACTED_VALUE
        assert result["server"] == "test-server"

    def test_redact_nested_dict(self):
        """Should redact sensitive values in nested dictionaries."""
        data = {
            "config": {
                "auth": {
                    "client_secret": "top-secret",
                    "client_id": "my-app"
                }
            },
            "server_name": "test"
        }
        result = redact_sensitive_data(data)

        assert result["config"]["auth"]["client_secret"] == REDACTED_VALUE
        assert result["config"]["auth"]["client_id"] == "my-app"
        assert result["server_name"] == "test"

    def test_redact_list_of_dicts(self):
        """Should redact in lists containing dictionaries."""
        data = [
            {"name": "server1", "password": "pass1"},
            {"name": "server2", "password": "pass2"}
        ]
        result = redact_sensitive_data(data)

        assert result[0]["name"] == "server1"
        assert result[0]["password"] == REDACTED_VALUE
        assert result[1]["password"] == REDACTED_VALUE

    def test_redact_with_additional_keys(self):
        """Should redact additional custom keys."""
        data = {
            "custom_field": "sensitive-value",
            "normal_field": "ok"
        }
        result = redact_sensitive_data(data, additional_keys={"custom_field"})

        assert result["custom_field"] == REDACTED_VALUE
        assert result["normal_field"] == "ok"

    def test_redact_connection_string_in_value(self):
        """Should redact Azure connection strings in values."""
        data = {
            "connection": "DefaultEndpointsProtocol=https;AccountKey=abc123secret;EndpointSuffix=core.windows.net"
        }
        result = redact_sensitive_data(data)
        assert REDACTED_VALUE in result["connection"]

    def test_max_depth_protection(self):
        """Should handle deeply nested structures with max_depth."""
        # Create deeply nested structure
        data = {"level0": {}}
        current = data["level0"]
        for i in range(1, 30):
            current[f"level{i}"] = {}
            current = current[f"level{i}"]
        current["password"] = "secret"

        # With limited depth, should not crash
        result = redact_sensitive_data(data, max_depth=10)
        assert isinstance(result, dict)

    def test_scalars_pass_through(self):
        """Scalar values should pass through unchanged."""
        assert redact_sensitive_data(123) == 123
        assert redact_sensitive_data(3.14) == pytest.approx(3.14)
        assert redact_sensitive_data(True) is True
        assert redact_sensitive_data(None) is None


class TestSafeJsonForLogging:
    """Tests for safe_json_for_logging function."""

    def test_basic_serialization(self):
        """Should serialize and redact data."""
        data = {"user": "admin", "password": "secret"}
        result = safe_json_for_logging(data)

        parsed = json.loads(result)
        assert parsed["user"] == "admin"
        assert parsed["password"] == REDACTED_VALUE

    def test_truncation(self):
        """Should truncate long output."""
        data = {"data": "x" * 2000}
        result = safe_json_for_logging(data, max_length=100)

        assert len(result) <= 100
        assert "... [truncated]" in result

    def test_custom_truncate_message(self):
        """Should use custom truncate message."""
        data = {"data": "x" * 2000}
        result = safe_json_for_logging(data, max_length=100, truncate_message="<cut>")

        assert "<cut>" in result

    def test_serialization_error_handling(self):
        """Should handle non-serializable objects gracefully."""
        class NonSerializable:
            pass

        data = {"obj": NonSerializable()}
        result = safe_json_for_logging(data)

        # Should return string representation, not crash
        assert isinstance(result, str)


# ===========================================================================
# SEC-002: Input Validation Tests
# ===========================================================================

class TestValidateJsonString:
    """Tests for validate_json_string function."""

    def test_valid_json(self):
        """Valid JSON should pass validation."""
        json_str = '{"cpu_usage": 0.5, "memory_usage": 0.7}'
        is_valid, error = validate_json_string(json_str)

        assert is_valid is True
        assert error is None

    def test_invalid_json_syntax(self):
        """Invalid JSON syntax should fail validation."""
        json_str = '{"cpu_usage": 0.5, memory_usage: 0.7}'  # Missing quotes
        is_valid, error = validate_json_string(json_str)

        assert is_valid is False
        assert error is not None and "Invalid JSON" in error

    def test_size_limit_exceeded(self):
        """JSON exceeding size limit should fail."""
        json_str = json.dumps({"data": "x" * 1000})
        is_valid, error = validate_json_string(json_str, max_size=100)

        assert is_valid is False
        assert error is not None and "size" in error.lower()

    def test_depth_limit_exceeded(self):
        """Deeply nested JSON should fail validation."""
        # Create JSON with depth > 5
        nested = {"level": {"level": {"level": {"level": {"level": {"level": "deep"}}}}}}
        json_str = json.dumps(nested)
        is_valid, error = validate_json_string(json_str, max_depth=3)

        assert is_valid is False
        assert "depth" in error.lower()

    def test_key_count_limit_exceeded(self):
        """JSON with too many keys should fail validation."""
        data = {f"key{i}": i for i in range(100)}
        json_str = json.dumps(data)
        is_valid, error = validate_json_string(json_str, max_keys=50)

        assert is_valid is False
        assert "key count" in error.lower()

    def test_non_string_input(self):
        """Non-string input should fail validation."""
        is_valid, error = validate_json_string(123)  # type: ignore

        assert is_valid is False
        assert "Expected string" in error or "str" in error.lower()

    def test_param_name_in_error(self):
        """Parameter name should appear in error messages."""
        is_valid, error = validate_json_string("invalid", param_name="--telemetrydata")

        assert is_valid is False
        assert "--telemetrydata" in error


class TestParseJsonSafely:
    """Tests for parse_json_safely function."""

    def test_valid_json_parsed(self):
        """Valid JSON should be parsed and returned."""
        json_str = '{"cpu": 0.5, "memory": 0.7}'
        result = parse_json_safely(json_str)

        assert result["cpu"] == pytest.approx(0.5)
        assert result["memory"] == pytest.approx(0.7)

    def test_invalid_json_raises(self):
        """Invalid JSON should raise InputValidationError."""
        with pytest.raises(InputValidationError) as exc_info:
            parse_json_safely("not valid json")

        assert exc_info.value.validation_type == "json_validation"

    def test_oversized_json_raises(self):
        """Oversized JSON should raise InputValidationError."""
        big_json = json.dumps({"data": "x" * 1000})

        with pytest.raises(InputValidationError) as exc_info:
            parse_json_safely(big_json, max_size=100)

        assert "size" in exc_info.value.message.lower()


class TestValidateServerName:
    """Tests for validate_server_name function."""

    @pytest.mark.parametrize("name", [
        "server1",
        "my-server",
        "server_name",
        "server.domain.com",
        "SERVER-01",
        "a",
        "a1",
    ])
    def test_valid_server_names(self, name):
        """Valid server names should pass validation."""
        is_valid, error = validate_server_name(name)
        assert is_valid is True
        assert error is None

    @pytest.mark.parametrize("name,reason", [
        ("", "empty"),
        (None, "None"),
        (".server", "starts with dot"),
        ("server..name", "contains .."),
        ("../etc/passwd", "path traversal"),
        ("-server", "starts with hyphen"),
        ("server-", "ends with hyphen"),
        ("server name", "contains space"),
        ("server;rm -rf", "contains semicolon"),
        ("x" * 300, "too long"),
    ])
    def test_invalid_server_names(self, name, reason):
        """Invalid server names should fail validation."""
        is_valid, error = validate_server_name(name or "")
        assert is_valid is False
        assert error is not None


class TestValidateAnalysisType:
    """Tests for validate_analysis_type function."""

    @pytest.mark.parametrize("analysis_type", [
        "Full", "Health", "Failure", "Anomaly"
    ])
    def test_valid_analysis_types(self, analysis_type):
        """Valid analysis types should pass."""
        is_valid, error = validate_analysis_type(analysis_type)
        assert is_valid is True
        assert error is None

    @pytest.mark.parametrize("analysis_type", [
        "", "full", "FULL", "Invalid", "All"
    ])
    def test_invalid_analysis_types(self, analysis_type):
        """Invalid analysis types should fail."""
        is_valid, error = validate_analysis_type(analysis_type)
        assert is_valid is False

    def test_custom_allowed_types(self):
        """Should accept custom allowed types."""
        is_valid, error = validate_analysis_type("Custom", allowed_types=["Custom", "Other"])
        assert is_valid is True


class TestValidateFilePath:
    """Tests for validate_file_path function."""

    def test_valid_path(self, tmp_path):
        """Valid file path should pass."""
        test_file = tmp_path / "test.json"
        test_file.write_text("{}")

        is_valid, error = validate_file_path(str(test_file), must_exist=True)
        assert is_valid is True

    def test_path_traversal_rejected(self):
        """Path traversal attempts should be rejected."""
        is_valid, error = validate_file_path("../../../etc/passwd")
        assert is_valid is False
        assert "traversal" in error.lower()

    def test_extension_validation(self):
        """Should validate file extensions."""
        is_valid, error = validate_file_path(
            "config.exe",
            allowed_extensions=[".json", ".pkl"]
        )
        assert is_valid is False
        assert "extension" in error.lower()

    def test_valid_extension(self):
        """Should accept valid extensions."""
        is_valid, error = validate_file_path(
            "config.json",
            allowed_extensions=[".json", ".pkl"]
        )
        assert is_valid is True

    def test_must_exist_fails_for_missing(self):
        """Should fail if must_exist=True and file missing."""
        is_valid, error = validate_file_path(
            "/nonexistent/file.json",
            must_exist=True
        )
        assert is_valid is False
        assert "not found" in error.lower()


# ===========================================================================
# SEC-003: Safe Logging Tests
# ===========================================================================

class TestSensitiveDataFilter:
    """Tests for SensitiveDataFilter logging filter."""

    def test_filter_redacts_bearer_token(self):
        """Should redact bearer tokens in log messages."""
        data_filter = SensitiveDataFilter()
        record = logging.LogRecord(
            name="test",
            level=logging.INFO,
            pathname="",
            lineno=0,
            msg="Auth header: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0",
            args=(),
            exc_info=None
        )

        result = data_filter.filter(record)

        assert result is True  # Record should still be logged
        assert "eyJhbGciOiJ" not in record.msg
        assert REDACTED_VALUE in record.msg

    def test_filter_redacts_connection_string(self):
        """Should redact Azure connection strings."""
        data_filter = SensitiveDataFilter()
        record = logging.LogRecord(
            name="test",
            level=logging.INFO,
            pathname="",
            lineno=0,
            msg="Connection: AccountKey=supersecretkey123;",
            args=(),
            exc_info=None
        )

        data_filter.filter(record)

        assert "supersecretkey" not in record.msg

    def test_filter_with_dict_args(self):
        """Should redact sensitive data in dict args."""
        data_filter = SensitiveDataFilter()
        # Use a simpler approach - create record and manually set args
        record = logging.LogRecord(
            name="test",
            level=logging.INFO,
            pathname="",
            lineno=0,
            msg="Config: %s",
            args=("AccountKey=secret123;",),
            exc_info=None
        )
        # Now manually set args to dict for testing the filter behavior
        record.args = {"config": "AccountKey=secret123;"}

        data_filter.filter(record)

        assert "secret123" not in str(record.args)

    def test_filter_with_tuple_args(self):
        """Should redact sensitive data in tuple args."""
        data_filter = SensitiveDataFilter()
        record = logging.LogRecord(
            name="test",
            level=logging.INFO,
            pathname="",
            lineno=0,
            msg="Config: %s",
            args=("AccountKey=secret123;",),
            exc_info=None
        )

        data_filter.filter(record)

        assert "secret123" not in str(record.args)


class TestConfigureSecureLogging:
    """Tests for configure_secure_logging function."""

    def test_adds_filter_to_logger(self):
        """Should add SensitiveDataFilter to logger."""
        logger = logging.getLogger("test_secure_config")
        # Clear existing filters
        logger.filters = []

        configure_secure_logging(logger)

        assert any(isinstance(f, SensitiveDataFilter) for f in logger.filters)

    def test_does_not_duplicate_filter(self):
        """Should not add duplicate filters."""
        logger = logging.getLogger("test_no_dup")
        logger.filters = []

        configure_secure_logging(logger)
        configure_secure_logging(logger)

        filter_count = sum(1 for f in logger.filters if isinstance(f, SensitiveDataFilter))
        assert filter_count == 1


class TestSafeTruncate:
    """Tests for safe_truncate function."""

    def test_short_string_unchanged(self):
        """Short strings should pass through unchanged."""
        result = safe_truncate("hello", max_length=100)
        assert result == "hello"

    def test_long_string_truncated(self):
        """Long strings should be truncated."""
        result = safe_truncate("x" * 200, max_length=50)
        assert len(result) == 50
        assert result.endswith("...")

    def test_custom_suffix(self):
        """Should use custom suffix."""
        result = safe_truncate("x" * 200, max_length=50, suffix="<cut>")
        assert result.endswith("<cut>")

    def test_non_string_converted(self):
        """Non-strings should be converted."""
        result = safe_truncate(12345, max_length=100)
        assert result == "12345"

    def test_error_handling(self):
        """Should handle objects that fail str() gracefully."""
        class BadStr:
            def __str__(self):
                raise ValueError("Cannot convert")

        result = safe_truncate(BadStr())
        assert "BadStr" in result


# ===========================================================================
# Integration Tests
# ===========================================================================

class TestSecurityIntegration:
    """Integration tests for security module."""

    def test_full_redaction_pipeline(self):
        """Test complete redaction pipeline."""
        sensitive_config = {
            "server": "prod-server",
            "auth": {
                "api_key": "test-placeholder-api-key-do-not-use",
                "username": "admin",
                "password": "supersecret"
            },
            "connection_string": "AccountKey=secretkey123;"
        }

        # Redact for logging
        safe_output = safe_json_for_logging(sensitive_config)
        parsed = json.loads(safe_output)

        # Verify sensitive data is redacted
        assert parsed["server"] == "prod-server"
        assert parsed["auth"]["api_key"] == REDACTED_VALUE
        assert parsed["auth"]["username"] == "admin"
        assert parsed["auth"]["password"] == REDACTED_VALUE

    def test_input_validation_pipeline(self):
        """Test complete input validation pipeline."""
        # Valid input
        valid_json = '{"cpu_usage": 0.5, "memory_usage": 0.7}'

        is_valid, _ = validate_server_name("test-server")
        assert is_valid

        is_valid, _ = validate_analysis_type("Health")
        assert is_valid

        data = parse_json_safely(valid_json)
        assert data["cpu_usage"] == pytest.approx(0.5)

    def test_secure_logger_integration(self):
        """Test secure logger filters sensitive data."""
        logger = get_secure_logger("test_integration")

        # This would normally log sensitive data
        # Filter should redact it
        record = logging.LogRecord(
            name="test",
            level=logging.INFO,
            pathname="",
            lineno=0,
            msg="Key: AccountKey=mysecretkey123;",
            args=(),
            exc_info=None
        )

        for f in logger.filters:
            f.filter(record)

        assert "mysecretkey" not in record.msg

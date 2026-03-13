"""
Security Utilities for Azure Arc Predictive Toolkit

This module provides security-related utilities including:
- Sensitive data detection and redaction for logging
- Input validation with size/depth limits
- Safe string operations

Phase 5 (Security Hardening) implementation.
"""

import os
import re
import json
import logging
import jsonschema
from typing import Any, Dict, List, Optional, Set, Tuple


# ===========================================================================
# SEC-001: Secrets Handling - Patterns for detecting sensitive data
# ===========================================================================

# Patterns that indicate sensitive field names (case-insensitive)
SENSITIVE_FIELD_PATTERNS: List[re.Pattern] = [
    re.compile(r'password', re.IGNORECASE),
    re.compile(r'secret', re.IGNORECASE),
    re.compile(r'api[_-]?key', re.IGNORECASE),
    re.compile(r'apikey', re.IGNORECASE),
    re.compile(r'auth[_-]?token', re.IGNORECASE),
    re.compile(r'access[_-]?token', re.IGNORECASE),
    re.compile(r'bearer', re.IGNORECASE),
    re.compile(r'credential', re.IGNORECASE),
    re.compile(r'private[_-]?key', re.IGNORECASE),
    re.compile(r'connection[_-]?string', re.IGNORECASE),
    re.compile(r'connectionstring', re.IGNORECASE),
    re.compile(r'workspace[_-]?key', re.IGNORECASE),
    re.compile(r'subscription[_-]?key', re.IGNORECASE),
    re.compile(r'sas[_-]?token', re.IGNORECASE),
    re.compile(r'shared[_-]?key', re.IGNORECASE),
    re.compile(r'client[_-]?secret', re.IGNORECASE),
]

# Patterns that indicate sensitive values (content patterns)
SENSITIVE_VALUE_PATTERNS: List[re.Pattern] = [
    # Azure connection strings
    re.compile(
        r'(AccountKey|SharedAccessSignature|AccessKey)=[^;]+',
        re.IGNORECASE
    ),
    # Bearer tokens
    re.compile(r'Bearer\s+[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+'),
    # API keys (common patterns: alphanumeric 20+ chars)
    re.compile(r'[A-Za-z0-9]{32,}'),
    # Base64 encoded secrets (might be keys)
    re.compile(r'[A-Za-z0-9+/]{40,}={0,2}'),
]

# Redaction placeholder
REDACTED_VALUE = '*** REDACTED ***'

# ===========================================================================
# SEC-001 Input Payload Validation — CLI contracts schema path
# ===========================================================================
_CLI_CONTRACTS_SCHEMA_DIR = os.path.normpath(
    os.path.join(os.path.dirname(__file__), '..', '..', 'config', 'schemas')
)
_CLI_CONTRACTS_SCHEMA_PATH = os.path.join(
    _CLI_CONTRACTS_SCHEMA_DIR, 'cli_contracts.schema.json'
)


def is_sensitive_key(key: Any) -> bool:
    """
    Check if a key name indicates sensitive data.

    Args:
        key: The key/field name to check

    Returns:
        True if the key matches sensitive patterns
    """
    if not isinstance(key, str):
        return False
    return any(pattern.search(key) for pattern in SENSITIVE_FIELD_PATTERNS)


def redact_value(value: Any) -> str:
    """
    Redact a sensitive value.

    Args:
        value: The value to redact

    Returns:
        Redacted placeholder string
    """
    return REDACTED_VALUE


def redact_sensitive_data(
    data: Any,
    additional_keys: Optional[Set[str]] = None,
    max_depth: int = 20
) -> Any:
    """
    Recursively redact sensitive data from a dictionary or list.

    This function walks through nested structures and redacts values
    associated with sensitive keys (passwords, secrets, tokens, etc.).

    Args:
        data: Input data (dict, list, or scalar)
        additional_keys: Optional set of additional key names to redact
        max_depth: Maximum recursion depth (prevents stack overflow)

    Returns:
        Copy of data with sensitive values redacted
    """
    if max_depth <= 0:
        return REDACTED_VALUE if isinstance(data, (dict, list)) else data

    sensitive_keys = additional_keys or set()

    if isinstance(data, dict):
        result = {}
        for key, value in data.items():
            str_key = str(key)
            if is_sensitive_key(str_key) or str_key.lower() in sensitive_keys:
                result[key] = REDACTED_VALUE
            else:
                result[key] = redact_sensitive_data(
                    value, additional_keys, max_depth - 1
                )
        return result

    elif isinstance(data, list):
        return [
            redact_sensitive_data(item, additional_keys, max_depth - 1)
            for item in data
        ]

    elif isinstance(data, str):
        # Check if the string itself looks like a sensitive value
        # Only redact if it looks like a credential pattern
        for pattern in SENSITIVE_VALUE_PATTERNS[:2]:  # Connection strings, bearer tokens
            if pattern.search(data):
                return REDACTED_VALUE
        return data

    else:
        # Scalars: int, float, bool, None
        return data


def safe_json_for_logging(
    data: Any,
    max_length: int = 1000,
    truncate_message: str = "... [truncated]"
) -> str:
    """
    Convert data to a JSON string safe for logging.

    Redacts sensitive data and truncates if too long.

    Args:
        data: Data to serialize
        max_length: Maximum length of output string
        truncate_message: Message to append when truncated

    Returns:
        JSON string safe for logging
    """
    try:
        redacted = redact_sensitive_data(data)
        json_str = json.dumps(redacted, default=str)

        if len(json_str) > max_length:
            return json_str[: max_length - len(truncate_message)] + truncate_message

        return json_str
    except (TypeError, ValueError) as e:
        return f"<serialization error: {type(e).__name__}>"


# ===========================================================================
# SEC-002: Input Validation - Size and depth limits
# ===========================================================================

# Default limits for JSON parsing
DEFAULT_MAX_JSON_SIZE = 10 * 1024 * 1024  # 10 MB
DEFAULT_MAX_JSON_DEPTH = 50
DEFAULT_MAX_JSON_KEYS = 10000


class InputValidationError(Exception):
    """Exception raised for input validation failures."""

    def __init__(self, message: str, validation_type: str, details: Optional[Dict[str, Any]] = None):
        super().__init__(message)
        self.message = message
        self.validation_type = validation_type
        self.details = details or {}


def validate_json_string(
    json_string: str,
    max_size: int = DEFAULT_MAX_JSON_SIZE,
    max_depth: int = DEFAULT_MAX_JSON_DEPTH,
    max_keys: int = DEFAULT_MAX_JSON_KEYS,
    param_name: str = "input"
) -> Tuple[bool, Optional[str]]:
    """
    Validate a JSON string before parsing.

    Checks size limits before parsing to prevent DoS attacks.

    Args:
        json_string: The JSON string to validate
        max_size: Maximum allowed size in bytes
        max_depth: Maximum allowed nesting depth
        max_keys: Maximum total number of keys allowed
        param_name: Parameter name for error messages

    Returns:
        Tuple of (is_valid, error_message)
    """
    # Check size first (before parsing)
    if not isinstance(json_string, str):
        return False, f"{param_name}: Expected string, got {type(json_string).__name__}"

    size = len(json_string.encode('utf-8'))
    if size > max_size:
        return False, (
            f"{param_name}: JSON size ({size} bytes) exceeds "
            f"maximum ({max_size} bytes)"
        )

    # Parse and validate structure
    try:
        data = json.loads(json_string)
    except json.JSONDecodeError as e:
        return False, f"{param_name}: Invalid JSON - {e.msg} at position {e.pos}"

    # Validate depth and key count
    depth, key_count = _measure_json_structure(data)

    if depth > max_depth:
        return False, (
            f"{param_name}: JSON depth ({depth}) exceeds "
            f"maximum ({max_depth})"
        )

    if key_count > max_keys:
        return False, (
            f"{param_name}: JSON key count ({key_count}) exceeds "
            f"maximum ({max_keys})"
        )

    return True, None


def _measure_json_structure(
    data: Any,
    current_depth: int = 1
) -> Tuple[int, int]:
    """
    Measure the depth and key count of a JSON structure.

    Args:
        data: Parsed JSON data
        current_depth: Current recursion depth

    Returns:
        Tuple of (max_depth, total_key_count)
    """
    if isinstance(data, dict):
        if not data:
            return current_depth, 0

        max_child_depth = current_depth
        total_keys = len(data)

        for value in data.values():
            child_depth, child_keys = _measure_json_structure(
                value, current_depth + 1
            )
            max_child_depth = max(max_child_depth, child_depth)
            total_keys += child_keys

        return max_child_depth, total_keys

    elif isinstance(data, list):
        if not data:
            return current_depth, 0

        max_child_depth = current_depth
        total_keys = 0

        for item in data:
            child_depth, child_keys = _measure_json_structure(
                item, current_depth + 1
            )
            max_child_depth = max(max_child_depth, child_depth)
            total_keys += child_keys

        return max_child_depth, total_keys

    else:
        return current_depth, 0


def parse_json_safely(
    json_string: str,
    max_size: int = DEFAULT_MAX_JSON_SIZE,
    max_depth: int = DEFAULT_MAX_JSON_DEPTH,
    max_keys: int = DEFAULT_MAX_JSON_KEYS,
    param_name: str = "input"
) -> Dict[str, Any]:
    """
    Parse JSON with security validation.

    Validates size, depth, and key count before returning parsed data.

    Args:
        json_string: JSON string to parse
        max_size: Maximum allowed size in bytes
        max_depth: Maximum allowed nesting depth
        max_keys: Maximum total number of keys
        param_name: Parameter name for error messages

    Returns:
        Parsed JSON as dictionary

    Raises:
        InputValidationError: If validation fails
    """
    is_valid, error_msg = validate_json_string(
        json_string, max_size, max_depth, max_keys, param_name
    )

    if not is_valid:
        raise InputValidationError(
            message=error_msg or "JSON validation failed",
            validation_type="json_validation",
            details={
                "param_name": param_name,
                "max_size": max_size,
                "max_depth": max_depth,
                "max_keys": max_keys
            }
        )

    return json.loads(json_string)


def load_cli_contracts_schema_definition(
    definition_name: str
) -> Optional[Dict[str, Any]]:
    """
    Load a named $defs definition from cli_contracts.schema.json.

    Args:
        definition_name: Name of the $defs key (e.g., 'serverDataInput')

    Returns:
        Schema definition dict, or None if the file is unavailable
    """
    try:
        with open(_CLI_CONTRACTS_SCHEMA_PATH, 'r') as f:
            schema = json.load(f)
        defn = schema.get('$defs', {}).get(definition_name)
        # Strip legacy anchor-style $id ("#name") which is not a valid URI
        # and causes jsonschema SchemaError when used as a standalone schema.
        if defn and '$id' in defn:
            defn = {k: v for k, v in defn.items() if k != '$id'}
        return defn
    except (IOError, json.JSONDecodeError):
        return None


def validate_json_against_schema(
    data: Any,
    schema: Dict[str, Any],
    param_name: str = "input"
) -> Tuple[bool, Optional[str]]:
    """
    Validate parsed JSON data against a JSON Schema definition.

    Args:
        data: Parsed JSON data to validate
        schema: JSON Schema definition dict
        param_name: Parameter name for error messages

    Returns:
        Tuple of (is_valid, error_message)
    """
    try:
        jsonschema.validate(instance=data, schema=schema)
        return True, None
    except jsonschema.ValidationError as e:
        return False, f"{param_name}: {e.message}"
    except jsonschema.SchemaError as e:
        return False, f"Internal schema error for {param_name}: {e.message}"


def validate_server_name(server_name: str) -> Tuple[bool, Optional[str]]:
    """
    Validate server name to prevent injection attacks.

    Args:
        server_name: Server name to validate

    Returns:
        Tuple of (is_valid, error_message)
    """
    if not server_name:
        return False, "Server name cannot be empty"

    if not isinstance(server_name, str):
        return False, f"Server name must be string, got {type(server_name).__name__}"

    # Max length check
    if len(server_name) > 255:
        return False, "Server name exceeds maximum length (255 characters)"

    # Character validation - allow alphanumeric, hyphens, underscores, dots
    # This prevents path traversal and command injection
    valid_pattern = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9\-_.]*[a-zA-Z0-9]$|^[a-zA-Z0-9]$')
    if not valid_pattern.match(server_name):
        return False, (
            "Server name contains invalid characters. "
            "Only alphanumeric, hyphens, underscores, and dots allowed."
        )

    # Prevent path traversal patterns
    if '..' in server_name or server_name.startswith('.'):
        return False, "Server name cannot contain path traversal patterns"

    return True, None


def validate_analysis_type(
    analysis_type: str,
    allowed_types: Optional[List[str]] = None
) -> Tuple[bool, Optional[str]]:
    """
    Validate analysis type parameter.

    Args:
        analysis_type: Analysis type to validate
        allowed_types: List of allowed values (default: Full, Health, Failure, Anomaly)

    Returns:
        Tuple of (is_valid, error_message)
    """
    if allowed_types is None:
        allowed_types = ["Full", "Health", "Failure", "Anomaly"]

    if not analysis_type:
        return False, "Analysis type cannot be empty"

    if analysis_type not in allowed_types:
        return False, (
            f"Invalid analysis type '{analysis_type}'. "
            f"Allowed values: {', '.join(allowed_types)}"
        )

    return True, None


def validate_file_path(
    path: str,
    must_exist: bool = False,
    allowed_extensions: Optional[List[str]] = None
) -> Tuple[bool, Optional[str]]:
    """
    Validate file path for security concerns.

    Args:
        path: File path to validate
        must_exist: If True, file must exist
        allowed_extensions: List of allowed file extensions (e.g., ['.json', '.pkl'])

    Returns:
        Tuple of (is_valid, error_message)
    """
    if not path:
        return False, "File path cannot be empty"

    if not isinstance(path, str):
        return False, f"File path must be string, got {type(path).__name__}"

    # Reject traversal sequences in the raw input before canonicalization
    if '..' in path:
        return False, "Path traversal patterns (..) not allowed"

    # Canonicalize: resolve symlinks and eliminate any remaining traversal
    abs_path = os.path.realpath(os.path.abspath(path))

    # Check extension if required (use canonicalized path)
    if allowed_extensions:
        _, ext = os.path.splitext(abs_path)
        if ext.lower() not in [e.lower() for e in allowed_extensions]:
            return False, (
                f"File extension '{ext}' not allowed. "
                f"Allowed: {', '.join(allowed_extensions)}"
            )

    # Check existence if required
    if must_exist and not os.path.exists(abs_path):
        return False, f"File not found: {path}"

    return True, None


# ===========================================================================
# SEC-003: Safe Logging - Filter for redacting sensitive data in logs
# ===========================================================================

class SensitiveDataFilter(logging.Filter):
    """
    Logging filter that redacts sensitive data from log messages.

    This filter scans log messages for patterns that might indicate
    sensitive data (passwords, keys, tokens) and redacts them.

    Usage:
        logger = logging.getLogger(__name__)
        logger.addFilter(SensitiveDataFilter())
    """

    def __init__(
        self,
        name: str = '',
        additional_patterns: Optional[List[re.Pattern]] = None
    ):
        """
        Initialize the sensitive data filter.

        Args:
            name: Filter name
            additional_patterns: Additional regex patterns to redact
        """
        super().__init__(name)
        self.patterns = SENSITIVE_VALUE_PATTERNS.copy()
        if additional_patterns:
            self.patterns.extend(additional_patterns)

    def filter(self, record: logging.LogRecord) -> bool:
        """
        Filter log record, redacting sensitive data.

        Args:
            record: Log record to filter

        Returns:
            True (always allow the record, but with redacted message)
        """
        if record.msg:
            record.msg = self._redact_message(str(record.msg))

        # Also redact args if present
        if record.args:
            if isinstance(record.args, dict):
                record.args = {
                    k: self._redact_message(str(v)) if isinstance(v, str) else v
                    for k, v in record.args.items()
                }
            elif isinstance(record.args, tuple):
                record.args = tuple(
                    self._redact_message(str(a)) if isinstance(a, str) else a
                    for a in record.args
                )

        return True

    def _redact_message(self, message: str) -> str:
        """
        Redact sensitive patterns from a message.

        Args:
            message: Original message

        Returns:
            Message with sensitive data redacted
        """
        result = message
        for pattern in self.patterns:
            result = pattern.sub(REDACTED_VALUE, result)
        return result


def configure_secure_logging(logger: logging.Logger) -> None:
    """
    Add security filter to a logger.

    Args:
        logger: Logger to configure
    """
    # Check if filter already added
    for f in logger.filters:
        if isinstance(f, SensitiveDataFilter):
            return

    logger.addFilter(SensitiveDataFilter())


def get_secure_logger(name: str) -> logging.Logger:
    """
    Get a logger with sensitive data filtering enabled.

    Args:
        name: Logger name

    Returns:
        Configured logger with security filter
    """
    from Python.common.logging_config import get_logger as base_get_logger

    logger = base_get_logger(name)
    configure_secure_logging(logger)
    return logger


# ===========================================================================
# Utility: Safe string truncation for error messages
# ===========================================================================

def safe_truncate(
    value: Any,
    max_length: int = 100,
    suffix: str = "..."
) -> str:
    """
    Safely truncate a value for display in error messages.

    Prevents leaking large amounts of data in error messages.

    Args:
        value: Value to truncate
        max_length: Maximum length
        suffix: Suffix to add when truncated

    Returns:
        Truncated string representation
    """
    try:
        str_value = str(value)
        if len(str_value) > max_length:
            return str_value[:max_length - len(suffix)] + suffix
        return str_value
    except Exception:
        return f"<{type(value).__name__}>"

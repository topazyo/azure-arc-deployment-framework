"""
Resilience utilities for Azure Arc Predictive Toolkit CLI scripts.

This module provides:
- Structured error responses with consistent JSON format
- Configurable timeout handling for long-running operations
- Retry logic with exponential backoff for transient failures
- Exit code constants for PowerShell integration

Contract: All error responses follow the schema defined in
src/config/schemas/cli_contracts.schema.json
"""

import json
import sys
import time
import functools
import signal
from datetime import datetime
from typing import Any, Callable, Dict, Optional, TypeVar, Union
from enum import IntEnum


# Exit codes for PowerShell integration
class ExitCode(IntEnum):
    """Standard exit codes for CLI scripts.

    PowerShell callers can branch on these codes:
    - 0: Success
    - 1: General error (check stderr for JSON details)
    - 2: Argument/validation error
    - 3: Configuration error
    - 4: Timeout error
    - 5: Transient error (retry may help)
    """
    SUCCESS = 0
    GENERAL_ERROR = 1
    VALIDATION_ERROR = 2
    CONFIG_ERROR = 3
    TIMEOUT_ERROR = 4
    TRANSIENT_ERROR = 5


# Error categories for structured responses
class ErrorCategory:
    """Error categories for consistent classification."""
    VALIDATION = "ValidationError"
    CONFIGURATION = "ConfigurationError"
    JSON_PARSE = "JSONParseError"
    FILE_NOT_FOUND = "FileNotFoundError"
    MODEL_ERROR = "ModelError"
    TIMEOUT = "TimeoutError"
    TRANSIENT = "TransientError"
    INTERNAL = "InternalError"


def create_error_response(
    error_type: str,
    message: str,
    details: Optional[Dict[str, Any]] = None,
    server_name: Optional[str] = None,
    analysis_type: Optional[str] = None,
    include_timestamp: bool = True
) -> Dict[str, Any]:
    """Create a structured error response following the CLI contract schema.

    Args:
        error_type: Error category (use ErrorCategory constants)
        message: Human-readable error message
        details: Optional dictionary with additional error context
        server_name: Server name from input (for correlation)
        analysis_type: Analysis type from input (for correlation)
        include_timestamp: Whether to include ISO 8601 timestamp

    Returns:
        Dictionary conforming to errorResponse schema from cli_contracts.schema.json
    """
    response: Dict[str, Any] = {
        "error": error_type,
        "message": message,
    }

    if include_timestamp:
        response["timestamp"] = datetime.now().isoformat()

    if details:
        response["details"] = details

    if server_name:
        response["input_servername"] = server_name

    if analysis_type:
        response["input_analysistype"] = analysis_type

    return response


def emit_error(
    error_type: str,
    message: str,
    exit_code: int = ExitCode.GENERAL_ERROR,
    details: Optional[Dict[str, Any]] = None,
    server_name: Optional[str] = None,
    analysis_type: Optional[str] = None,
    file=sys.stderr
) -> None:
    """Emit a structured error response and exit.

    Args:
        error_type: Error category
        message: Human-readable error message
        exit_code: Exit code for PowerShell branching
        details: Optional additional context
        server_name: Server name from input
        analysis_type: Analysis type from input
        file: Output file (default: stderr)
    """
    response = create_error_response(
        error_type=error_type,
        message=message,
        details=details,
        server_name=server_name,
        analysis_type=analysis_type
    )
    print(json.dumps(response, indent=4), file=file)
    sys.exit(exit_code)


def emit_error_no_exit(
    error_type: str,
    message: str,
    details: Optional[Dict[str, Any]] = None,
    server_name: Optional[str] = None,
    analysis_type: Optional[str] = None,
    file=sys.stdout
) -> Dict[str, Any]:
    """Emit a structured error response without exiting.

    Useful for scripts that return error JSON on stdout (like run_predictor.py).

    Returns:
        The error response dictionary
    """
    response = create_error_response(
        error_type=error_type,
        message=message,
        details=details,
        server_name=server_name,
        analysis_type=analysis_type
    )
    print(json.dumps(response, indent=4), file=file, flush=True)
    return response


# Type variable for generic retry function
T = TypeVar('T')


class TimeoutException(Exception):
    """Raised when an operation times out."""
    pass


class TransientException(Exception):
    """Raised for transient errors that may succeed on retry."""
    pass


def with_timeout(seconds: int, error_message: Optional[str] = None):
    """Decorator to add timeout handling to a function.

    Args:
        seconds: Maximum execution time in seconds
        error_message: Custom error message (default: generic timeout message)

    Note:
        On Windows, signal-based timeout is not available. This decorator
        will skip timeout enforcement on Windows but log a warning.
    """
    def decorator(func: Callable[..., T]) -> Callable[..., T]:
        @functools.wraps(func)
        def wrapper(*args, **kwargs) -> T:
            # Check if we're on Windows (signal.SIGALRM not available)
            if not hasattr(signal, 'SIGALRM'):
                # On Windows, we can't use signal-based timeout
                # Just execute without timeout (log warning in production)
                return func(*args, **kwargs)

            def timeout_handler(signum, frame):
                msg = error_message or f"Operation timed out after {seconds} seconds"
                raise TimeoutException(msg)

            # Set the timeout handler
            old_handler = signal.signal(signal.SIGALRM, timeout_handler)
            signal.alarm(seconds)

            try:
                result = func(*args, **kwargs)
            finally:
                # Cancel the alarm and restore the old handler
                signal.alarm(0)
                signal.signal(signal.SIGALRM, old_handler)

            return result
        return wrapper
    return decorator


def retry_with_backoff(
    max_retries: int = 3,
    initial_delay: float = 1.0,
    max_delay: float = 30.0,
    backoff_factor: float = 2.0,
    retryable_exceptions: tuple = (TransientException, ConnectionError, TimeoutError)
):
    """Decorator to add retry logic with exponential backoff.

    Args:
        max_retries: Maximum number of retry attempts
        initial_delay: Initial delay between retries (seconds)
        max_delay: Maximum delay between retries (seconds)
        backoff_factor: Multiplier for delay after each retry
        retryable_exceptions: Tuple of exception types that trigger retry

    Example:
        @retry_with_backoff(max_retries=3, initial_delay=1.0)
        def load_config(path):
            # May fail transiently
            ...
    """
    def decorator(func: Callable[..., T]) -> Callable[..., T]:
        @functools.wraps(func)
        def wrapper(*args, **kwargs) -> T:
            delay = initial_delay
            last_exception = None

            for attempt in range(max_retries + 1):
                try:
                    return func(*args, **kwargs)
                except retryable_exceptions as e:
                    last_exception = e
                    if attempt < max_retries:
                        # Log retry attempt (would use logger in production)
                        time.sleep(min(delay, max_delay))
                        delay *= backoff_factor
                    else:
                        raise

            # Should not reach here, but raise last exception if we do
            if last_exception:
                raise last_exception
            raise RuntimeError("Retry logic error")

        return wrapper
    return decorator


def safe_json_loads(
    json_string: str,
    param_name: str = "JSON input",
    server_name: Optional[str] = None,
    analysis_type: Optional[str] = None
) -> Union[Dict[str, Any], None]:
    """Safely parse JSON with structured error handling.

    Args:
        json_string: JSON string to parse
        param_name: Name of the parameter (for error messages)
        server_name: Server name for error correlation
        analysis_type: Analysis type for error correlation

    Returns:
        Parsed JSON as dictionary, or None if parsing failed
        (error is emitted to stderr)

    Raises:
        SystemExit: If JSON parsing fails
    """
    try:
        return json.loads(json_string)
    except json.JSONDecodeError as e:
        emit_error(
            error_type=ErrorCategory.JSON_PARSE,
            message=f"Invalid JSON in {param_name}: {str(e)}",
            exit_code=ExitCode.VALIDATION_ERROR,
            details={
                "param_name": param_name,
                "error_position": e.pos,
                "error_line": e.lineno,
                "error_column": e.colno
            },
            server_name=server_name,
            analysis_type=analysis_type
        )
        return None  # Never reached due to sys.exit


def safe_file_read(
    file_path: str,
    description: str = "file",
    server_name: Optional[str] = None,
    analysis_type: Optional[str] = None
) -> Union[str, None]:
    """Safely read a file with structured error handling.

    Args:
        file_path: Path to the file
        description: Description of the file (for error messages)
        server_name: Server name for error correlation
        analysis_type: Analysis type for error correlation

    Returns:
        File contents as string, or None if reading failed

    Raises:
        SystemExit: If file reading fails
    """
    import os

    if not os.path.exists(file_path):
        emit_error(
            error_type=ErrorCategory.FILE_NOT_FOUND,
            message=f"{description} not found at: {file_path}",
            exit_code=ExitCode.CONFIG_ERROR,
            details={"path": file_path},
            server_name=server_name,
            analysis_type=analysis_type
        )
        return None

    try:
        with open(file_path, 'r') as f:
            return f.read()
    except IOError as e:
        emit_error(
            error_type=ErrorCategory.INTERNAL,
            message=f"Failed to read {description}: {str(e)}",
            exit_code=ExitCode.GENERAL_ERROR,
            details={"path": file_path, "io_error": str(e)},
            server_name=server_name,
            analysis_type=analysis_type
        )
        return None


def validate_config(
    config: Dict[str, Any],
    required_key: str = "aiComponents",
    config_path: str = "config",
    server_name: Optional[str] = None,
    analysis_type: Optional[str] = None
) -> Dict[str, Any]:
    """Validate configuration has required structure.

    Args:
        config: Loaded configuration dictionary
        required_key: Required top-level key
        config_path: Path to config file (for error messages)
        server_name: Server name for error correlation
        analysis_type: Analysis type for error correlation

    Returns:
        The value of the required key

    Raises:
        SystemExit: If validation fails
    """
    if required_key not in config:
        emit_error(
            error_type=ErrorCategory.CONFIGURATION,
            message=f"Invalid configuration: missing '{required_key}' key",
            exit_code=ExitCode.CONFIG_ERROR,
            details={
                "config_path": config_path,
                "required_key": required_key,
                "available_keys": list(config.keys())
            },
            server_name=server_name,
            analysis_type=analysis_type
        )

    value = config[required_key]
    if not value:
        emit_error(
            error_type=ErrorCategory.CONFIGURATION,
            message=f"Configuration '{required_key}' is empty",
            exit_code=ExitCode.CONFIG_ERROR,
            details={"config_path": config_path},
            server_name=server_name,
            analysis_type=analysis_type
        )

    return value


def validate_model_directory(
    model_dir: str,
    server_name: Optional[str] = None,
    analysis_type: Optional[str] = None,
    exit_on_error: bool = True
) -> bool:
    """Validate model directory exists and contains files.

    Args:
        model_dir: Path to model directory
        server_name: Server name for error correlation
        analysis_type: Analysis type for error correlation
        exit_on_error: If True, exit on validation failure

    Returns:
        True if valid, False otherwise (only if exit_on_error=False)
    """
    import os

    if not os.path.exists(model_dir):
        if exit_on_error:
            emit_error(
                error_type=ErrorCategory.MODEL_ERROR,
                message=f"Model directory not found: {model_dir}",
                exit_code=ExitCode.CONFIG_ERROR,
                details={"model_dir": model_dir},
                server_name=server_name,
                analysis_type=analysis_type
            )
        return False

    if not os.path.isdir(model_dir):
        if exit_on_error:
            emit_error(
                error_type=ErrorCategory.MODEL_ERROR,
                message=f"Model path is not a directory: {model_dir}",
                exit_code=ExitCode.CONFIG_ERROR,
                details={"model_dir": model_dir},
                server_name=server_name,
                analysis_type=analysis_type
            )
        return False

    if not os.listdir(model_dir):
        if exit_on_error:
            emit_error(
                error_type=ErrorCategory.MODEL_ERROR,
                message=f"Model directory is empty: {model_dir}",
                exit_code=ExitCode.CONFIG_ERROR,
                details={"model_dir": model_dir},
                server_name=server_name,
                analysis_type=analysis_type
            )
        return False

    return True

# src/Python/run_predictor.py
import json
import argparse
import os
import sys  # Ensure sys is imported for sys.path
from datetime import datetime

# Path setup to allow importing sibling modules (config) and parent
# modules (predictive). Assuming this script (run_predictor.py) is in
# project_root/src/Python/
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
# Path to project_root/src/ (same pattern as invoke_ai_engine.py)
SRC_PATH = os.path.abspath(os.path.join(SCRIPT_DIR, os.pardir))
if SRC_PATH not in sys.path:
    sys.path.insert(0, SRC_PATH)

# Use full path from src/ to maintain package context for relative imports
from Python.predictive.predictor import ArcPredictor  # noqa: E402
from Python.common.resilience import (  # noqa: E402
    ErrorCategory,
    create_error_response,
    retry_with_backoff
)
from Python.common.security import (  # noqa: E402
    validate_server_name,
    validate_analysis_type,
    parse_json_safely,
    InputValidationError,
    validate_json_against_schema,
    load_cli_contracts_schema_definition
)

# If script is in src/Python/ and models in data/models/latest at
# project root:
PROJECT_ROOT_ASSUMED = os.path.abspath(
    os.path.join(SCRIPT_DIR, "..", ".."))
DEFAULT_MODEL_DIR = os.path.join(
    PROJECT_ROOT_ASSUMED, "data", "models", "latest")


def main():
    """
    Main entry point for ArcPredictor. Processes telemetry data from a
    JSON string and runs specified predictions.
    """
    # Expected --telemetrydatajson structure:
    # A dictionary representing a single snapshot of telemetry data, e.g.,
    # {
    #   "cpu_usage": 0.75,
    #   "memory_usage": 0.60,
    #   // ... other features as defined in ai_config.json for the
    #   // relevant model ...
    #   // Note: server_name and timestamp might also be part of this
    #   // data if models use them.
    # }
    # This script is designed for direct interaction with ArcPredictor
    # using specific models. For a more holistic analysis (risk scoring,
    # pattern analysis), use invoke_ai_engine.py.
    parser = argparse.ArgumentParser(
        description="ArcPredictor AI Engine Interface")
    parser.add_argument(
        "--server-name", type=str, required=True,
        help="Name of the server for prediction.")
    parser.add_argument(
        "--analysis-type", type=str, default="Full",
        choices=["Full", "Health", "Failure", "Anomaly"],
        help="Type of analysis to perform.")
    parser.add_argument(
        "--model-dir", type=str, default=DEFAULT_MODEL_DIR,
        help="Directory where models are stored.")
    parser.add_argument(
        "--config-path", type=str,
        default=os.path.join(PROJECT_ROOT_ASSUMED, "src", "config", "ai_config.json"),
        help="Path to AI configuration file.")
    parser.add_argument(
        "--telemetrydatajson", type=str, required=True,
        help="JSON string containing the telemetry data for prediction.")

    args = parser.parse_args()
    debug_indent = 4 if os.environ.get('DEBUG_PYTHON_WRAPPER') else None

    # Helper to emit structured errors (this CLI returns errors on stdout)
    def emit_structured_error(
        error_type: str,
        message: str,
        details: dict = None
    ):
        """Emit error JSON to stdout and return."""
        response = create_error_response(
            error_type=error_type,
            message=message,
            details=details,
            server_name=args.server_name,
            analysis_type=args.analysis_type
        )
        print(json.dumps(response, indent=debug_indent), flush=True)

    # SEC-002: Validate CLI inputs before processing
    is_valid, error_msg = validate_server_name(args.server_name)
    if not is_valid:
        emit_structured_error(
            error_type=ErrorCategory.VALIDATION,
            message=error_msg,
            details={"param_name": "--server-name", "value_length": len(args.server_name) if args.server_name else 0}
        )
        return

    is_valid, error_msg = validate_analysis_type(args.analysis_type)
    if not is_valid:
        emit_structured_error(
            error_type=ErrorCategory.VALIDATION,
            message=error_msg,
            details={"param_name": "--analysis-type", "value": args.analysis_type}
        )
        return

    try:
        # Validate model directory
        model_dir = os.path.realpath(os.path.abspath(args.model_dir))
        model_exists = os.path.exists(model_dir)
        model_has_files = model_exists and os.listdir(model_dir)
        if not model_exists or not model_has_files:
            emit_structured_error(
                error_type=ErrorCategory.MODEL_ERROR,
                message="Model directory is empty or does not exist",
                details={"model_dir": model_dir}
            )
            return

        # Load predictor with retry for transient failures
        @retry_with_backoff(max_retries=2, initial_delay=0.5)
        def load_predictor(model_dir: str) -> ArcPredictor:
            return ArcPredictor(model_dir=model_dir)

        predictor = load_predictor(model_dir)

        # Check if models were loaded
        if not predictor.models:
            emit_structured_error(
                error_type=ErrorCategory.MODEL_ERROR,
                message="No models loaded successfully by ArcPredictor",
                details={"model_dir": args.model_dir}
            )
            return

        # Parse telemetry data with security validation
        # SEC-002: Use secure JSON parsing with size/depth limits
        try:
            telemetry_data = parse_json_safely(
                args.telemetrydatajson,
                param_name="--telemetrydatajson"
            )
        except InputValidationError as e:
            emit_structured_error(
                error_type=ErrorCategory.VALIDATION,
                message=e.message,
                details=e.details
            )
            return
        except json.JSONDecodeError as e:
            emit_structured_error(
                error_type=ErrorCategory.JSON_PARSE,
                message=f"Invalid JSON in --telemetrydatajson: {str(e)}",
                details={
                    "param_name": "--telemetrydatajson",
                    "error_position": e.pos,
                    "error_line": e.lineno,
                    "error_column": e.colno
                }
            )
            return

        # SEC-001: Validate telemetry payload against CLI contracts schema
        _telem_schema = load_cli_contracts_schema_definition(
            'telemetryDataInput'
        )
        if _telem_schema is not None:
            _valid, _err = validate_json_against_schema(
                telemetry_data, _telem_schema,
                param_name="--telemetrydatajson"
            )
            if not _valid:
                emit_structured_error(
                    error_type=ErrorCategory.VALIDATION,
                    message=_err,
                    details={"param_name": "--telemetrydatajson"}
                )
                return

        # Build output results
        output_results = {
            "server_name": args.server_name,
            "analysis_type": args.analysis_type,
            "timestamp": datetime.now().isoformat()
        }

        if args.analysis_type in ["Full", "Health"]:
            health_pred = predictor.predict_health(telemetry_data)
            output_results["health_prediction"] = health_pred

        if args.analysis_type in ["Full", "Anomaly"]:
            anomaly_pred = predictor.detect_anomalies(telemetry_data)
            output_results["anomaly_detection"] = anomaly_pred

        if args.analysis_type in ["Full", "Failure"]:
            failure_pred = predictor.predict_failures(telemetry_data)
            output_results["failure_prediction"] = failure_pred

        print(json.dumps(output_results, indent=debug_indent), flush=True)

    except Exception as e:
        # Catch-all for unexpected errors
        emit_structured_error(
            error_type=ErrorCategory.INTERNAL,
            message=str(e),
            details={"exception_type": type(e).__name__}
        )


if __name__ == "__main__":
    main()

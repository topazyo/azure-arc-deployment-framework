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
# noqa: E402
from Python.predictive.predictor import ArcPredictor
# noqa: E402
from Python.common.resilience import (
    ErrorCategory,
    create_error_response,
    retry_with_backoff
)
# noqa: E402
from Python.common.security import (
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


def build_parser():
    """Build the CLI parser for direct predictor execution."""
    parser = argparse.ArgumentParser(
        description="ArcPredictor AI Engine Interface"
    )
    parser.add_argument(
        "--server-name", type=str, required=True,
        help="Name of the server for prediction."
    )
    parser.add_argument(
        "--analysis-type", type=str, default="Full",
        choices=["Full", "Health", "Failure", "Anomaly"],
        help="Type of analysis to perform."
    )
    parser.add_argument(
        "--model-dir", type=str, default=DEFAULT_MODEL_DIR,
        help="Directory where models are stored."
    )
    parser.add_argument(
        "--config-path", type=str,
        default=os.path.join(
            PROJECT_ROOT_ASSUMED, "src", "config", "ai_config.json"
        ),
        help="Path to AI configuration file."
    )
    parser.add_argument(
        "--telemetrydatajson", type=str, required=True,
        help="JSON string containing the telemetry data for prediction."
    )
    return parser


def build_error_emitter(args, debug_indent):
    """Create a stdout-only structured error emitter for this CLI."""
    def emit_structured_error(error_type: str, message: str, details: dict = None):
        response = create_error_response(
            error_type=error_type,
            message=message,
            details=details,
            server_name=args.server_name,
            analysis_type=args.analysis_type
        )
        print(json.dumps(response, indent=debug_indent), flush=True)

    return emit_structured_error


def validate_cli_args(args, emit_structured_error):
    """Validate CLI arguments and emit structured errors on failure."""
    is_valid, error_msg = validate_server_name(args.server_name)
    if not is_valid:
        emit_structured_error(
            error_type=ErrorCategory.VALIDATION,
            message=error_msg,
            details={
                "param_name": "--server-name",
                "value_length": len(args.server_name) if args.server_name else 0,
            }
        )
        return False

    is_valid, error_msg = validate_analysis_type(args.analysis_type)
    if not is_valid:
        emit_structured_error(
            error_type=ErrorCategory.VALIDATION,
            message=error_msg,
            details={
                "param_name": "--analysis-type",
                "value": args.analysis_type,
            }
        )
        return False

    return True


def validate_model_dir(args, emit_structured_error):
    """Canonicalize and validate the model directory."""
    model_dir = os.path.realpath(os.path.abspath(args.model_dir))
    model_exists = os.path.exists(model_dir)
    model_has_files = model_exists and os.listdir(model_dir)
    if not model_exists or not model_has_files:
        emit_structured_error(
            error_type=ErrorCategory.MODEL_ERROR,
            message="Model directory is empty or does not exist",
            details={"model_dir": model_dir}
        )
        return None
    return model_dir


@retry_with_backoff(max_retries=2, initial_delay=0.5)
def load_predictor(model_dir: str) -> ArcPredictor:
    """Load ArcPredictor with retry for transient failures."""
    return ArcPredictor(model_dir=model_dir)


def get_predictor(model_dir, args, emit_structured_error):
    """Create a predictor and verify that models loaded successfully."""
    predictor = load_predictor(model_dir)
    if not predictor.models:
        emit_structured_error(
            error_type=ErrorCategory.MODEL_ERROR,
            message="No models loaded successfully by ArcPredictor",
            details={"model_dir": args.model_dir}
        )
        return None
    return predictor


def parse_telemetry_payload(args, emit_structured_error):
    """Parse and schema-validate the telemetry payload."""
    try:
        telemetry_data = parse_json_safely(
            args.telemetrydatajson,
            param_name="--telemetrydatajson"
        )
    except InputValidationError as error:
        emit_structured_error(
            error_type=ErrorCategory.VALIDATION,
            message=error.message,
            details=error.details
        )
        return None
    except json.JSONDecodeError as error:
        emit_structured_error(
            error_type=ErrorCategory.JSON_PARSE,
            message=f"Invalid JSON in --telemetrydatajson: {str(error)}",
            details={
                "param_name": "--telemetrydatajson",
                "error_position": error.pos,
                "error_line": error.lineno,
                "error_column": error.colno,
            }
        )
        return None

    telemetry_schema = load_cli_contracts_schema_definition(
        'telemetryDataInput'
    )
    if telemetry_schema is not None:
        is_valid, error_message = validate_json_against_schema(
            telemetry_data,
            telemetry_schema,
            param_name="--telemetrydatajson"
        )
        if not is_valid:
            emit_structured_error(
                error_type=ErrorCategory.VALIDATION,
                message=error_message,
                details={"param_name": "--telemetrydatajson"}
            )
            return None

    return telemetry_data


def build_output_results(args):
    """Create the base output payload for predictor results."""
    return {
        "server_name": args.server_name,
        "analysis_type": args.analysis_type,
        "timestamp": datetime.now().isoformat()
    }


def add_prediction_results(output_results, predictor, telemetry_data, analysis_type):
    """Populate the output payload with the requested prediction types."""
    if analysis_type in ["Full", "Health"]:
        output_results["health_prediction"] = predictor.predict_health(
            telemetry_data
        )

    if analysis_type in ["Full", "Anomaly"]:
        output_results["anomaly_detection"] = predictor.detect_anomalies(
            telemetry_data
        )

    if analysis_type in ["Full", "Failure"]:
        output_results["failure_prediction"] = predictor.predict_failures(
            telemetry_data
        )


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
    args = build_parser().parse_args()
    debug_indent = 4 if os.environ.get('DEBUG_PYTHON_WRAPPER') else None
    emit_structured_error = build_error_emitter(args, debug_indent)

    if not validate_cli_args(args, emit_structured_error):
        return

    try:
        model_dir = validate_model_dir(args, emit_structured_error)
        if model_dir is None:
            return

        predictor = get_predictor(model_dir, args, emit_structured_error)
        if predictor is None:
            return

        telemetry_data = parse_telemetry_payload(args, emit_structured_error)
        if telemetry_data is None:
            return

        output_results = build_output_results(args)
        add_prediction_results(
            output_results,
            predictor,
            telemetry_data,
            args.analysis_type,
        )

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

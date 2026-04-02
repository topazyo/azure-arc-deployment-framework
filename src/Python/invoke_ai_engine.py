import json
import argparse
import sys
import os
import math
from datetime import date, datetime

import numpy as np
import pandas as pd

# Add src to path to allow direct import if called from elsewhere
sys.path.insert(
    0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../'))
)

from Python.predictive.predictive_analytics_engine import (  # noqa: E402
    PredictiveAnalyticsEngine
)
from Python.common.resilience import (  # noqa: E402
    ExitCode,
    ErrorCategory,
    create_error_response,
    emit_error,
    validate_config,
    validate_model_directory,
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


def build_parser():
    """Build the CLI argument parser for the AI engine entrypoint."""
    parser = argparse.ArgumentParser(
        description="Azure Arc AI Engine Interface"
    )
    parser.add_argument(
        "--servername",
        required=True,
        help="Name of the server to analyze"
    )
    parser.add_argument(
        "--analysistype",
        default="Full",
        help="Type of analysis (Full, Health, Failure, Anomaly)"
    )
    parser.add_argument(
        "--modeldir",
        default=os.path.join(
            os.path.dirname(__file__), 'models_placeholder'
        ),
        help=(
            "Directory containing trained models. Defaults to a "
            "'models_placeholder' folder relative to this script."
        )
    )
    parser.add_argument(
        "--configpath",
        default=os.path.join(
            os.path.dirname(__file__), '../config/ai_config.json'
        ),
        help=(
            "Path to AI configuration file. Defaults to "
            "'src/config/ai_config.json'."
        )
    )
    parser.add_argument(
        "--serverdatajson",
        required=False,
        default=None,
        help=(
            "JSON string containing the server telemetry data for "
            "analysis. If omitted, a minimal snapshot "
            "(server_name_id, timestamp) is synthesized and missing "
            "features default to 0.0 during inference."
        ),
    )
    parser.add_argument(
        "--remediationoutcomejson",
        required=False,
        default=None,
        help=(
            "Optional remediation outcome payload to record with the "
            "remediation learner. When provided, the engine will queue "
            "or signal retrain requests and surface them in the output."
        ),
    )
    parser.add_argument(
        "--exportretrainpath",
        required=False,
        default=None,
        help=(
            "Optional path to write pending retrain requests as JSON. "
            "If specified, pending requests will be exported (and "
            "consumed when --consumeexportqueue is set)."
        ),
    )
    parser.add_argument(
        "--consumeexportqueue",
        action="store_true",
        help=(
            "When exporting retrain requests, consume/clear the queue "
            "after export instead of peeking."
        )
    )
    parser.add_argument(
        "--correlation-id",
        default=None,
        help=(
            "Opaque correlation ID injected by the PowerShell caller for "
            "cross-process tracing (DEBT-SEC-025). Included verbatim in "
            "all JSON responses on stdout."
        )
    )
    return parser


@retry_with_backoff(max_retries=2, initial_delay=0.5)
def load_config_with_retry(path: str) -> dict:
    """Load configuration with retry for transient failures."""
    with open(path, 'r') as file_handle:
        return json.load(file_handle)


def validate_cli_args(args):
    """Validate CLI arguments and emit structured errors on failure."""
    is_valid, error_msg = validate_server_name(args.servername)
    if not is_valid:
        emit_error(
            error_type=ErrorCategory.VALIDATION,
            message=error_msg,
            exit_code=ExitCode.VALIDATION_ERROR,
            details={
                "param_name": "--servername",
                "value_length": len(args.servername),
            },
            server_name=args.servername,
            analysis_type=args.analysistype,
        )

    is_valid, error_msg = validate_analysis_type(args.analysistype)
    if not is_valid:
        emit_error(
            error_type=ErrorCategory.VALIDATION,
            message=error_msg,
            exit_code=ExitCode.VALIDATION_ERROR,
            details={
                "param_name": "--analysistype",
                "value": args.analysistype,
            },
            server_name=args.servername,
            analysis_type=args.analysistype,
        )


def load_ai_component_config(args):
    """Load and validate the AI component configuration."""
    config_path = os.path.realpath(os.path.abspath(args.configpath))
    if not os.path.exists(config_path):
        emit_error(
            error_type=ErrorCategory.FILE_NOT_FOUND,
            message=f"Configuration file not found at: {config_path}",
            exit_code=ExitCode.CONFIG_ERROR,
            details={"config_path": config_path},
            server_name=args.servername,
            analysis_type=args.analysistype,
        )

    config_data = load_config_with_retry(config_path)
    return validate_config(
        config=config_data,
        required_key="aiComponents",
        config_path=config_path,
        server_name=args.servername,
        analysis_type=args.analysistype,
    )


def build_default_server_data(server_name):
    """Create the fallback server payload when no telemetry JSON is passed."""
    return {
        "server_name_id": server_name,
        "timestamp": datetime.now().isoformat(),
    }


def parse_server_data_payload(args):
    """Parse and schema-validate the optional server data payload."""
    if args.serverdatajson is None or str(args.serverdatajson).strip() == "":
        return build_default_server_data(args.servername)

    try:
        server_data_input = parse_json_safely(
            args.serverdatajson,
            param_name="--serverdatajson"
        )
    except InputValidationError as error:
        emit_error(
            error_type=ErrorCategory.VALIDATION,
            message=error.message,
            exit_code=ExitCode.VALIDATION_ERROR,
            details=error.details,
            server_name=args.servername,
            analysis_type=args.analysistype,
        )
    except json.JSONDecodeError as error:
        emit_error(
            error_type=ErrorCategory.JSON_PARSE,
            message=f"Invalid JSON in --serverdatajson: {str(error)}",
            exit_code=ExitCode.VALIDATION_ERROR,
            details={
                "param_name": "--serverdatajson",
                "error_position": error.pos,
                "error_line": error.lineno,
                "error_column": error.colno,
            },
            server_name=args.servername,
            analysis_type=args.analysistype,
        )

    server_schema = load_cli_contracts_schema_definition('serverDataInput')
    if server_schema is not None:
        is_valid, error_message = validate_json_against_schema(
            server_data_input,
            server_schema,
            param_name="--serverdatajson"
        )
        if not is_valid:
            emit_error(
                error_type=ErrorCategory.VALIDATION,
                message=error_message,
                exit_code=ExitCode.VALIDATION_ERROR,
                details={"param_name": "--serverdatajson"},
                server_name=args.servername,
                analysis_type=args.analysistype,
            )

    return server_data_input


def validate_and_get_model_dir(args):
    """Canonicalize and validate the model directory."""
    model_dir_abs = os.path.realpath(os.path.abspath(args.modeldir))
    validate_model_directory(
        model_dir=model_dir_abs,
        server_name=args.servername,
        analysis_type=args.analysistype,
        exit_on_error=True,
    )
    return model_dir_abs


def parse_remediation_payload(args):
    """Parse and schema-validate the remediation outcome payload."""
    try:
        remediation_payload = parse_json_safely(
            args.remediationoutcomejson,
            param_name="--remediationoutcomejson"
        )
    except InputValidationError as error:
        raise ValueError(
            f"Invalid --remediationoutcomejson payload: {error.message}"
        ) from error
    except json.JSONDecodeError as error:
        raise ValueError(
            f"Invalid JSON provided in --remediationoutcomejson: {error}"
        ) from error

    remediation_schema = load_cli_contracts_schema_definition(
        'remediationOutcomeInput'
    )
    if remediation_schema is not None:
        is_valid, error_message = validate_json_against_schema(
            remediation_payload,
            remediation_schema,
            param_name="--remediationoutcomejson"
        )
        if not is_valid:
            raise ValueError(
                f"Remediation payload schema validation failed: {error_message}"
            )

    return remediation_payload


def apply_remediation_options(engine, args, results):
    """Apply optional remediation learning and export actions."""
    if not args.remediationoutcomejson:
        return

    remediation_payload = parse_remediation_payload(args)
    outcome_response = engine.record_remediation_outcome(
        remediation_payload=remediation_payload,
        consume_retrain_queue=args.consumeexportqueue,
    )
    results["remediation_outcome"] = outcome_response

    if args.exportretrainpath:
        export_response = engine.export_retrain_requests(
            output_path=os.path.realpath(
                os.path.abspath(args.exportretrainpath)
            ),
            consume=args.consumeexportqueue,
        )
        results["retrain_export"] = export_response


def finalize_results(args, results):
    """Attach caller context fields to the result payload."""
    results['input_servername'] = args.servername
    results['input_analysistype'] = args.analysistype
    if args.correlation_id:
        results['correlation_id'] = args.correlation_id
    return results


def normalize_json_payload(value):
    """Convert numpy/pandas values into strict JSON-safe native types."""
    if value is None:
        return None

    if isinstance(value, np.generic):
        return normalize_json_payload(value.item())

    if isinstance(value, np.ndarray):
        return [normalize_json_payload(item) for item in value.tolist()]

    if isinstance(value, pd.Timestamp):
        return value.isoformat()

    if isinstance(value, pd.Timedelta):
        return value.total_seconds()

    if isinstance(value, dict):
        return {
            str(key): normalize_json_payload(item)
            for key, item in value.items()
        }

    if isinstance(value, (list, tuple, set)):
        return [normalize_json_payload(item) for item in value]

    if isinstance(value, (datetime, date)):
        return value.isoformat()

    if isinstance(value, float):
        return value if math.isfinite(value) else None

    if isinstance(value, (str, bool, int)):
        return value

    if pd.isna(value):
        return None

    return str(value)


def emit_json(payload, file=None):
    """Write a normalized JSON payload to stdout or stderr."""
    target = sys.stdout if file is None else file
    print(json.dumps(normalize_json_payload(payload), indent=4), file=target)


def main():
    """
    Main entry point for the Azure Arc AI Engine script.
    Parses command-line arguments, loads configuration, initializes the
    PredictiveAnalyticsEngine, processes input, and prints results.
    """
    # Expected --serverdatajson structure:
    # {
    #   "server_name_id": "actual_server_name",
    #   "timestamp": "YYYY-MM-DDTHH:MM:SS.ffffff",
    #   "cpu_usage": 0.75,
    #   "memory_usage": 0.60,
    #   // ... other features as defined in ai_config.json ...
    # }
    args = build_parser().parse_args()
    validate_cli_args(args)

    try:
        ai_components_config = load_ai_component_config(args)
        server_data_input = parse_server_data_payload(args)
        model_dir_abs = validate_and_get_model_dir(args)

        engine = PredictiveAnalyticsEngine(
            config=ai_components_config,
            model_dir=model_dir_abs
        )
        results = engine.analyze_deployment_risk(server_data_input)
        apply_remediation_options(engine, args, results)
        results = finalize_results(args, results)

        emit_json(results)
        sys.exit(ExitCode.SUCCESS)

    except SystemExit:
        # Re-raise SystemExit (from emit_error) without wrapping
        raise

    except Exception as e:
        # Catch-all for unexpected errors
        servername_for_error = "Unknown"
        analysistype_for_error = "Unknown"
        correlation_id_for_error = None
        if 'args' in locals():
            servername_for_error = getattr(args, 'servername', 'Unknown')
            analysistype_for_error = getattr(args, 'analysistype', 'Unknown')
            correlation_id_for_error = getattr(args, 'correlation_id', None)

        error_details = {
            "exception_type": type(e).__name__,
            "context": "Unexpected error in AI engine"
        }
        if correlation_id_for_error:
            error_details["correlation_id"] = correlation_id_for_error

        error_response = create_error_response(
            error_type=ErrorCategory.INTERNAL,
            message=str(e),
            details=error_details,
            server_name=servername_for_error,
            analysis_type=analysistype_for_error
        )
        emit_json(error_response, file=sys.stderr)
        sys.exit(ExitCode.GENERAL_ERROR)


if __name__ == "__main__":
    main()

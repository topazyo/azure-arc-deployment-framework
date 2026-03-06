import json
import argparse
import sys
import os
from datetime import datetime

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
    InputValidationError
)


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

    args = parser.parse_args()

    # SEC-002: Validate CLI inputs before processing
    is_valid, error_msg = validate_server_name(args.servername)
    if not is_valid:
        emit_error(
            error_type=ErrorCategory.VALIDATION,
            message=error_msg,
            exit_code=ExitCode.VALIDATION_ERROR,
            details={"param_name": "--servername", "value_length": len(args.servername)},
            server_name=args.servername,
            analysis_type=args.analysistype
        )

    is_valid, error_msg = validate_analysis_type(args.analysistype)
    if not is_valid:
        emit_error(
            error_type=ErrorCategory.VALIDATION,
            message=error_msg,
            exit_code=ExitCode.VALIDATION_ERROR,
            details={"param_name": "--analysistype", "value": args.analysistype},
            server_name=args.servername,
            analysis_type=args.analysistype
        )

    # Use resilience utilities for config loading with retry
    @retry_with_backoff(max_retries=2, initial_delay=0.5)
    def load_config_with_retry(path: str) -> dict:
        """Load configuration with retry for transient failures."""
        with open(path, 'r') as f:
            return json.load(f)

    try:
        # Load configuration from JSON file
        config_path = os.path.abspath(args.configpath)
        if not os.path.exists(config_path):
            emit_error(
                error_type=ErrorCategory.FILE_NOT_FOUND,
                message=f"Configuration file not found at: {config_path}",
                exit_code=ExitCode.CONFIG_ERROR,
                details={"config_path": config_path},
                server_name=args.servername,
                analysis_type=args.analysistype
            )

        config_data = load_config_with_retry(config_path)
        ai_components_config = validate_config(
            config=config_data,
            required_key="aiComponents",
            config_path=config_path,
            server_name=args.servername,
            analysis_type=args.analysistype
        )

        # Parse (or synthesize) JSON input for server data.
        if (
            args.serverdatajson is None or
            str(args.serverdatajson).strip() == ""
        ):
            server_data_input = {
                "server_name_id": args.servername,
                "timestamp": datetime.now().isoformat(),
            }
        else:
            # SEC-002: Use secure JSON parsing with size/depth limits
            try:
                server_data_input = parse_json_safely(
                    args.serverdatajson,
                    param_name="--serverdatajson"
                )
            except InputValidationError as e:
                emit_error(
                    error_type=ErrorCategory.VALIDATION,
                    message=e.message,
                    exit_code=ExitCode.VALIDATION_ERROR,
                    details=e.details,
                    server_name=args.servername,
                    analysis_type=args.analysistype
                )
            except json.JSONDecodeError as e:
                emit_error(
                    error_type=ErrorCategory.JSON_PARSE,
                    message=f"Invalid JSON in --serverdatajson: {str(e)}",
                    exit_code=ExitCode.VALIDATION_ERROR,
                    details={
                        "param_name": "--serverdatajson",
                        "error_position": e.pos,
                        "error_line": e.lineno,
                        "error_column": e.colno
                    },
                    server_name=args.servername,
                    analysis_type=args.analysistype
                )

        # Validate model directory exists and has content
        model_dir_abs = os.path.abspath(args.modeldir)
        validate_model_directory(
            model_dir=model_dir_abs,
            server_name=args.servername,
            analysis_type=args.analysistype,
            exit_on_error=True
        )

        # Instantiate the real PredictiveAnalyticsEngine
        engine = PredictiveAnalyticsEngine(
            config=ai_components_config,  # Pass the 'aiComponents' section
            model_dir=model_dir_abs
        )

        # analyze_deployment_risk expects dictionary for server snapshot
        results = engine.analyze_deployment_risk(server_data_input)

        # Optionally record remediation outcome
        if args.remediationoutcomejson:
            try:
                remediation_payload = json.loads(
                    args.remediationoutcomejson
                )
            except json.JSONDecodeError as e:
                raise ValueError(
                    f"Invalid JSON provided in --remediationoutcomejson: "
                    f"{e}"
                )

            outcome_response = engine.record_remediation_outcome(
                remediation_payload=remediation_payload,
                consume_retrain_queue=args.consumeexportqueue,
            )
            results["remediation_outcome"] = outcome_response

            if args.exportretrainpath:
                export_response = engine.export_retrain_requests(
                    output_path=os.path.abspath(args.exportretrainpath),
                    consume=args.consumeexportqueue,
                )
                results["retrain_export"] = export_response

        # Add input servername and analysistype to results
        results['input_servername'] = args.servername
        # analysis_type not directly used but useful for PS confirmation
        results['input_analysistype'] = args.analysistype
        # DEBT-SEC-025: echo correlation ID (may be None if not supplied by PS caller)
        if args.correlation_id:
            results['correlation_id'] = args.correlation_id

        # Added indent for readability if run manually
        print(json.dumps(results, indent=4))
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
        print(json.dumps(error_response, indent=4), file=sys.stderr)
        sys.exit(ExitCode.GENERAL_ERROR)


if __name__ == "__main__":
    main()

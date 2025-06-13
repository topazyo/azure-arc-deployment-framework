# src/Python/run_predictor.py
import json
import argparse
import os
import sys # Ensure sys is imported for sys.path
import pandas as pd # For creating sample data if needed
import numpy as np
import traceback # For detailed error reporting

# Path setup to allow importing sibling modules (config) and parent modules (predictive)
# Assuming this script (run_predictor.py) is in project_root/src/Python/
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
# Path to project_root/src/
SRC_PATH = os.path.abspath(os.path.join(SCRIPT_DIR, os.pardir))
if SRC_PATH not in sys.path:
    sys.path.insert(0, SRC_PATH)

# Path to project_root/ (if you need to import things from project_root, not common for src files)
# PROJECT_ROOT_PATH = os.path.abspath(os.path.join(SRC_PATH, os.pardir))
# if PROJECT_ROOT_PATH not in sys.path:
# sys.path.insert(0, PROJECT_ROOT_PATH)


from predictive.predictor import ArcPredictor
# from config.ai_config import LATEST_MODEL_DIR # This would be ideal
# For now, define model dir relative to this script or project structure
# If script is in src/Python/ and models in data/models/latest at project root:
PROJECT_ROOT_ASSUMED = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))
DEFAULT_MODEL_DIR = os.path.join(PROJECT_ROOT_ASSUMED, "data", "models", "latest")


def main():
    """Main entry point for ArcPredictor. Processes telemetry data from a JSON string and runs specified predictions."""
    # Expected --telemetrydatajson structure:
    # A dictionary representing a single snapshot of telemetry data, e.g.,
    # {
    #   "cpu_usage": 0.75,
    #   "memory_usage": 0.60,
    #   // ... other features as defined in ai_config.json for the relevant model ...
    #   // Note: server_name and timestamp might also be part of this data if models use them.
    # }
    # This script is designed for direct interaction with ArcPredictor using specific models.
    # For a more holistic analysis (risk scoring, pattern analysis), use invoke_ai_engine.py.
    parser = argparse.ArgumentParser(description="ArcPredictor AI Engine Interface")
    parser.add_argument("--server-name", type=str, required=True, help="Name of the server for prediction.")
    parser.add_argument("--analysis-type", type=str, default="Full",
                        choices=["Full", "Health", "Failure", "Anomaly"],
                        help="Type of analysis to perform.")
    parser.add_argument("--model-dir", type=str, default=DEFAULT_MODEL_DIR, help="Directory where models are stored.")
    parser.add_argument("--telemetrydatajson", type=str, required=True, help="JSON string containing the telemetry data for prediction.")

    args = parser.parse_args()

    output_results = {} # Initialize with an empty dict

    try:
        if not os.path.exists(args.model_dir) or not os.listdir(args.model_dir):
             output_results = {"error": f"Model directory {args.model_dir} is empty or does not exist. Ensure models are trained and present."}
             print(json.dumps(output_results), flush=True)
             return

        predictor = ArcPredictor(model_dir=args.model_dir)
        if not predictor.models: # Check if models were loaded (e.g. pkl files were valid)
             output_results = {"error": f"No models loaded successfully by ArcPredictor from {args.model_dir}."}
             print(json.dumps(output_results), flush=True)
             return

        try:
            telemetry_data = json.loads(args.telemetrydatajson)
        except json.JSONDecodeError as e:
            output_results = {
                "error": "JSONDecodeError",
                "message": f"Invalid JSON provided in --telemetrydatajson: {str(e)}",
                "server_name": args.server_name,
                "analysis_type": args.analysis_type,
            }
            print(json.dumps(output_results, indent=4 if os.environ.get('DEBUG_PYTHON_WRAPPER') else None), flush=True)
            return

        output_results = {"server_name": args.server_name, "analysis_type": args.analysis_type}
        # Optionally, add features provided:
        # output_results["input_features_provided"] = list(telemetry_data.keys())

        if args.analysis_type in ["Full", "Health"]:
            health_pred = predictor.predict_health(telemetry_data)
            output_results["health_prediction"] = health_pred

        if args.analysis_type in ["Full", "Anomaly"]:
            anomaly_pred = predictor.detect_anomalies(telemetry_data)
            output_results["anomaly_detection"] = anomaly_pred

        if args.analysis_type in ["Full", "Failure"]:
            failure_pred = predictor.predict_failures(telemetry_data)
            output_results["failure_prediction"] = failure_pred

        print(json.dumps(output_results, indent=4 if os.environ.get('DEBUG_PYTHON_WRAPPER') else None), flush=True)

    except Exception as e:
        # Ensure output_results is defined before trying to add error key
        if not output_results: output_results = {} # Should have been initialized earlier
        output_results["error"] = str(e)
        output_results["trace"] = traceback.format_exc()
        print(json.dumps(output_results, indent=4 if os.environ.get('DEBUG_PYTHON_WRAPPER') else None), flush=True)

if __name__ == "__main__":
    # Need to ensure sys is available in the global scope for the path logic at the top of the file
    # This is implicitly true when script is run, but good to be mindful
    main()

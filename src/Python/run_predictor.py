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


def generate_sample_telemetry(server_name: str, feature_names: list) -> dict:
    """Generates sample telemetry data for a given server based on expected feature names."""
    data = {"server_name": server_name}
    # Based on feature names used in training (from model_metadata['feature_order'])
    for feature in feature_names:
        if "count" in feature or "restarts" in feature or "spikes" in feature or "drops" in feature:
            data[feature] = np.random.randint(0, 5)
        elif "latency" in feature or "response_time" in feature:
            data[feature] = np.random.uniform(10, 200)
        elif "usage" in feature: # cpu_usage, memory_usage, disk_usage
            data[feature] = np.random.uniform(0.05, 0.95)
        # cpu_to_memory_ratio is derived, not a raw input for sample generation here
        else: # Default for unknown features, or features not fitting above patterns
            data[feature] = np.random.rand()
    return data

def main():
    """[TODO: Add method documentation]"""
    parser = argparse.ArgumentParser(description="ArcPredictor AI Engine Interface")
    parser.add_argument("--server-name", type=str, required=True, help="Name of the server for prediction.")
    parser.add_argument("--analysis-type", type=str, default="Full",
                        choices=["Full", "Health", "Failure", "Anomaly"],
                        help="Type of analysis to perform.")
    parser.add_argument("--model-dir", type=str, default=DEFAULT_MODEL_DIR, help="Directory where models are stored.")

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

        sample_telemetry = None
        # Try to get feature order from one of the loaded models to generate relevant sample data
        # This is just for placeholder data generation.
        if predictor.model_metadata:
            # Use feature order from health_prediction model for generating sample data
            # This assumes health_prediction model and its metadata are loaded.
            # The specific model chosen ('health_prediction') is arbitrary for selecting a feature list.
            # Any model's metadata containing 'feature_order' would suffice.
            chosen_model_type_for_features = None
            for mt in ['health_prediction', 'failure_prediction', 'anomaly_detection']:
                if predictor.model_metadata.get(mt) and predictor.model_metadata[mt].get('feature_order'):
                    chosen_model_type_for_features = mt
                    break

            if chosen_model_type_for_features:
                input_feature_names = predictor.model_metadata[chosen_model_type_for_features]['feature_order']
                if not input_feature_names: # If feature_order list is empty
                    output_results = {"error": f"Feature order list for {chosen_model_type_for_features} is empty. Cannot generate sample telemetry."}
                    print(json.dumps(output_results), flush=True)
                    return
                sample_telemetry = generate_sample_telemetry(args.server_name, input_feature_names)
            else: # Fallback if no model/meta found with feature_order
                fallback_features = [
                    "cpu_usage", "memory_usage", "disk_usage", "network_latency",
                    "error_count", "warning_count", "request_count", "response_time",
                    "service_restarts", "cpu_spikes", "memory_spikes", "connection_drops"
                ]
                sample_telemetry = generate_sample_telemetry(args.server_name, fallback_features)
        else:
            output_results = {"error": "Model metadata not loaded by ArcPredictor, cannot determine features for sample telemetry."}
            print(json.dumps(output_results), flush=True)
            return

        output_results = {"server_name": args.server_name, "analysis_type": args.analysis_type, "input_telemetry_sample_features": list(sample_telemetry.keys())}

        if args.analysis_type in ["Full", "Health"]:
            health_pred = predictor.predict_health(sample_telemetry)
            output_results["health_prediction"] = health_pred

        if args.analysis_type in ["Full", "Anomaly"]:
            anomaly_pred = predictor.detect_anomalies(sample_telemetry)
            output_results["anomaly_detection"] = anomaly_pred

        if args.analysis_type in ["Full", "Failure"]:
            failure_pred = predictor.predict_failures(sample_telemetry)
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

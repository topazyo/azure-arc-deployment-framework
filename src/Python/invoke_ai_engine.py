import json
import argparse
import sys
import os
from datetime import datetime

# Add src to path to allow direct import of modules if this script is called from elsewhere
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../')))

# Placeholder for actual AI engine import and usage
from Python.predictive.predictive_analytics_engine import PredictiveAnalyticsEngine
# from Python.common.ai_config_loader import AIConfig # Assuming a config loader for future
# Ensure json is imported if not already by other imports
# import json # Already imported by the script

# PlaceholderPredictiveAnalyticsEngine class removed

def main():
    """
    Main entry point for the Azure Arc AI Engine script.
    Parses command-line arguments, loads configuration, initializes the
    PredictiveAnalyticsEngine, processes the input, and prints results as JSON.
    """
    # Expected --serverdatajson structure:
    # {
    #   "server_name_id": "actual_server_name", // Should match --servername for consistency
    #   "timestamp": "YYYY-MM-DDTHH:MM:SS.ffffff", // ISO format timestamp for the snapshot
    #   "cpu_usage": 0.75,
    #   "memory_usage": 0.60,
    #   // ... other features as defined in ai_config.json model_config features ...
    # }
    parser = argparse.ArgumentParser(description="Azure Arc AI Engine Interface")
    parser.add_argument("--servername", required=True, help="Name of the server to analyze")
    parser.add_argument("--analysistype", default="Full", help="Type of analysis (Full, Health, Failure, Anomaly)")
    parser.add_argument("--modeldir", default=os.path.join(os.path.dirname(__file__), 'models_placeholder'), help="Directory containing trained models. Defaults to a 'models_placeholder' folder relative to this script.")
    parser.add_argument("--configpath", default=os.path.join(os.path.dirname(__file__), '../config/ai_config.json'), help="Path to AI configuration file. Defaults to 'src/config/ai_config.json'.")
    parser.add_argument("--serverdatajson", required=True, help="JSON string containing the server telemetry data for analysis.")

    args = parser.parse_args()
    ai_components_config = {} # Initialize

    try:
        # Load configuration from JSON file
        config_path = os.path.abspath(args.configpath)
        if not os.path.exists(config_path):
            raise FileNotFoundError(f"Configuration file not found at: {config_path}")

        with open(config_path, 'r') as f:
            config_data = json.load(f)
        ai_components_config = config_data.get('aiComponents', {})
        if not ai_components_config:
             raise ValueError(f"Invalid configuration format in {config_path}. Missing 'aiComponents' key.")

        # Parse the JSON input for server data
        try:
            server_data_input = json.loads(args.serverdatajson)
        except json.JSONDecodeError as e:
            # Handle JSON parsing error
            error_output = {
                "error": "JSONDecodeError",
                "message": f"Invalid JSON provided in --serverdatajson: {str(e)}",
                "input_servername": args.servername,
                "input_analysistype": args.analysistype,
                "timestamp": datetime.now().isoformat()
            }
            print(json.dumps(error_output, indent=4), file=sys.stderr)
            sys.exit(1)

        # Ensure model directory exists, or ArcPredictor will fail to load
        model_dir_abs = os.path.abspath(args.modeldir)
        if not os.path.isdir(model_dir_abs):
             # For this script, if models dir doesn't exist, it's a fatal error as Predictor needs it.
             # In a real scenario, PAE might handle this more gracefully or have a 'no-model' mode.
             raise FileNotFoundError(f"Model directory not found at: {model_dir_abs}. Please ensure models are trained and available.")

        # Instantiate the real PredictiveAnalyticsEngine
        engine = PredictiveAnalyticsEngine(
            config=ai_components_config, # Pass the 'aiComponents' section
            model_dir=model_dir_abs
        )

        # analyze_deployment_risk expects a dictionary representing a single server's raw data snapshot
        results = engine.analyze_deployment_risk(server_data_input)

        # Add input servername and analysistype to the results for clarity in PS
        results['input_servername'] = args.servername
        results['input_analysistype'] = args.analysistype # analysis_type is not directly used by PAE.analyze_deployment_risk
                                                         # but can be useful for PS to confirm what it requested.

        print(json.dumps(results, indent=4)) # Added indent for readability if run manually
        sys.exit(0)

    except Exception as e:
        # Ensure args are available for error reporting
        # If error happens before args parsing, they won't be.
        servername_for_error = "Unknown"
        analysistype_for_error = "Unknown"
        if 'args' in locals():
            servername_for_error = args.servername if args.servername else "Unknown"
            analysistype_for_error = args.analysistype if args.analysistype else "Unknown"

        error_output = {
            "error": type(e).__name__, # More specific error type
            "message": str(e),
            "details": "An error occurred in the AI engine.",
            "input_servername": servername_for_error,
            "input_analysistype": analysistype_for_error,
            "timestamp": datetime.now().isoformat()
        }
        print(json.dumps(error_output, indent=4), file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()

import sys
import os
import pandas as pd
import json
from pathlib import Path
import numpy as np # Added for sample data generation

# Add src to path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../../../src')))

from Python.predictive.feature_engineering import FeatureEngineer
from Python.predictive.model_trainer import ArcModelTrainer

def create_dummy_models(model_output_dir: str, config_file_path: str):
    print(f"Python: Starting dummy model setup. Output dir: {model_output_dir}, Config path: {config_file_path}")
    model_output_path = Path(model_output_dir)
    model_output_path.mkdir(parents=True, exist_ok=True)

    config_path = Path(config_file_path)
    if not config_path.exists():
        print(f"Python: Config file not found at {config_file_path}", file=sys.stderr)
        raise FileNotFoundError(f"Config file not found at {config_file_path}")

    with open(config_path, 'r') as f:
        full_config = json.load(f)

    ai_components_config = full_config.get('aiComponents', {})
    fe_config = ai_components_config.get('feature_engineering', {})
    # Use model_config directly for trainer, as it contains 'features' and 'models' keys
    trainer_config_from_json = ai_components_config.get('model_config', {})


    if not fe_config:
        print("Python: feature_engineering config missing.", file=sys.stderr)
        raise ValueError("feature_engineering config missing from config file.")
    if not trainer_config_from_json:
        print("Python: model_config missing.", file=sys.stderr)
        raise ValueError("model_config missing from config file.")
    if not trainer_config_from_json.get('features') or not trainer_config_from_json.get('models'):
        print("Python: model_config is missing 'features' or 'models' sections.", file=sys.stderr)
        raise ValueError("model_config is missing 'features' or 'models' sections.")


    # Create minimal sample data
    # Ensure all columns listed in fe_config.original_numerical_features and original_categorical_features are present
    # Also ensure target columns are present.

    num_samples = 20 # Increased samples for better training stability with small estimators
    base_data_dict = {
        'timestamp': pd.to_datetime(pd.date_range(start='2023-01-01', periods=num_samples, freq='H'))
    }

    # Populate features based on fe_config + model_config target columns
    all_expected_raw_cols = set()
    if fe_config.get('original_numerical_features'):
        all_expected_raw_cols.update(fe_config['original_numerical_features'])
    if fe_config.get('original_categorical_features'):
        all_expected_raw_cols.update(fe_config['original_categorical_features'])

    for model_type_cfg in trainer_config_from_json.get('features', {}).values():
        if model_type_cfg.get('target_column'):
            all_expected_raw_cols.add(model_type_cfg['target_column'])
        # If 'required_features_is_output_of_fe' is False, then these features also need to be in raw data
        if not model_type_cfg.get('required_features_is_output_of_fe', True): # Default to True if key missing
             if model_type_cfg.get('required_features'):
                all_expected_raw_cols.update(model_type_cfg['required_features'])


    print(f"Python: Expected raw columns based on config: {all_expected_raw_cols}")

    for col in all_expected_raw_cols:
        if col == 'timestamp': continue
        if col in ['is_healthy', 'will_fail']: # Binary targets
            base_data_dict[col] = np.random.randint(0, 2, size=num_samples)
        elif col in fe_config.get('original_categorical_features', []): # Categorical
            categories = ['A', 'B', 'C']
            base_data_dict[col] = np.random.choice(categories, size=num_samples)
        else: # Numerical
            base_data_dict[col] = np.random.rand(num_samples) * 100
            if "count" in col or "spike" in col or "restart" in col or "drop" in col: # Integer counts
                 base_data_dict[col] = np.random.randint(0, 5, size=num_samples)


    sample_data = pd.DataFrame(base_data_dict)
    # Ensure any specific columns mentioned in default configs are present if not covered by loops
    default_cols_to_ensure = ['cpu_usage_avg', 'memory_usage_avg', 'disk_io_avg', 'error_count_sum', 'response_time_avg', 'region']
    for dc in default_cols_to_ensure:
        if dc not in sample_data.columns:
            if dc == 'region': sample_data[dc] = 'default_region'
            else: sample_data[dc] = 0.0

    print(f"Python: Generated sample_data with columns: {sample_data.columns.tolist()}")


    fe = FeatureEngineer(config=fe_config)
    trainer_config_updated = trainer_config_from_json.copy() # To update required_features

    # Health model
    health_target = trainer_config_from_json.get('features',{}).get('health_prediction',{}).get('target_column', 'is_healthy')
    if health_target not in sample_data.columns: sample_data[health_target] = np.random.randint(0,2,size=num_samples)
    health_engineered_df, _ = fe.engineer_features(sample_data.copy(), target=health_target)
    if trainer_config_updated.get('features',{}).get('health_prediction',{}).get('required_features_is_output_of_fe', True):
        trainer_config_updated['features']['health_prediction']['required_features'] = [c for c in health_engineered_df.columns if c != health_target]
    health_engineered_df[health_target] = sample_data[health_target] # Ensure target is on the final df for trainer

    # Failure model
    failure_target = trainer_config_from_json.get('features',{}).get('failure_prediction',{}).get('target_column', 'will_fail')
    if failure_target not in sample_data.columns: sample_data[failure_target] = np.random.randint(0,2,size=num_samples)
    fe_fail = FeatureEngineer(config=fe_config) # Fresh FE for different target (if selection differs)
    failure_engineered_df, _ = fe_fail.engineer_features(sample_data.copy(), target=failure_target)
    if trainer_config_updated.get('features',{}).get('failure_prediction',{}).get('required_features_is_output_of_fe', True):
        trainer_config_updated['features']['failure_prediction']['required_features'] = [c for c in failure_engineered_df.columns if c != failure_target]
    failure_engineered_df[failure_target] = sample_data[failure_target]

    # Anomaly model
    fe_anomaly = FeatureEngineer(config=fe_config)
    anomaly_engineered_df, _ = fe_anomaly.engineer_features(sample_data.copy().drop(columns=[health_target, failure_target], errors='ignore'))
    if trainer_config_updated.get('features',{}).get('anomaly_detection',{}).get('required_features_is_output_of_fe', True):
         trainer_config_updated['features']['anomaly_detection']['required_features'] = list(anomaly_engineered_df.columns)

    trainer = ArcModelTrainer(config=trainer_config_updated)

    print(f"Python: Training health model with {len(trainer_config_updated['features']['health_prediction']['required_features'])} features.")
    trainer.train_health_prediction_model(health_engineered_df)

    print(f"Python: Training failure model with {len(trainer_config_updated['features']['failure_prediction']['required_features'])} features.")
    trainer.train_failure_prediction_model(failure_engineered_df)

    print(f"Python: Training anomaly model with {len(trainer_config_updated['features']['anomaly_detection']['required_features'])} features.")
    trainer.train_anomaly_detection_model(anomaly_engineered_df)

    trainer.save_models(str(model_output_path))
    print(f"Python: Dummy models, scalers, and feature info saved to {model_output_path}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python setup_dummy_models_for_ps_integration.py <model_output_directory> <config_file_path>")
        sys.exit(1)

    print(f"Python: Script called with args: {sys.argv}")
    model_dir_arg = sys.argv[1]
    cfg_path_arg = sys.argv[2]

    try:
        create_dummy_models(model_dir_arg, cfg_path_arg)
        print("Python: Dummy model setup completed successfully.")
    except Exception as e:
        print(f"Python: Error during dummy model setup: {str(e)}", file=sys.stderr)
        import traceback
        traceback.print_exc(file=sys.stderr)
        sys.exit(1)

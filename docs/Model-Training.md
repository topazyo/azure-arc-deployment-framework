# Model Training Guide

## Introduction

The Azure Arc Framework's Python AI engine includes the capability to train custom predictive models for assessing server health, predicting failures, and detecting anomalies. This guide outlines the process, key components involved, and prerequisites for training these models.

The primary goal of the training process is to produce reliable models that can be used by the `ArcPredictor` component for generating insights on new data.

## Key Components Involved

1.  **`FeatureEngineer` (`src/Python/predictive/feature_engineering.py`)**:
    *   **Role**: This class is crucial for transforming raw datasets into a rich and suitable feature set for training effective machine learning models. It can generate a wide array of features from temporal data, statistical aggregations (like rolling means and lags), and interactions between existing numerical features.
    *   **Configuration**: Highly configurable via the `feature_engineering` section in `src/config/ai_config.json`. This allows you to specify which original features to use, what types of new features to create, parameters for generation (e.g., window sizes for rolling stats, lag periods), NaN handling strategies, and feature selection parameters.
    *   **Output**: Produces a Pandas DataFrame of engineered features and metadata describing them.

2.  **`ArcModelTrainer` (`src/Python/predictive/model_trainer.py`)**:
    *   **Role**: This class orchestrates the actual model training process for different model types (health prediction, failure prediction, anomaly detection).
    *   **Configuration**: Its behavior is primarily driven by the `model_config` section in `src/config/ai_config.json`.
    *   **Key Steps**:
        *   **Data Preparation (`prepare_data` method)**:
            *   Takes an input DataFrame (which could be raw data or, more typically, data already processed by `FeatureEngineer`).
            *   Selects the final set of features based on `model_config.features[model_type].required_features`.
            *   Handles any remaining missing values based on `model_config.features[model_type].missing_strategy`.
            *   Applies `StandardScaler` to numerical features.
            *   Separates the target variable (e.g., `is_healthy`, `will_fail`) for supervised learning tasks.
        *   **Data Splitting**: For supervised models, splits the data into training and testing sets using `train_test_split` (configurable `test_split_ratio` and `random_state`).
        *   **Model Initialization**: Initializes scikit-learn models (e.g., `RandomForestClassifier`, `IsolationForest`) with hyperparameters specified in `model_config.models[model_type]`.
        *   **Model Fitting**: Trains the model on the prepared training data.
        *   **Evaluation**: For classification models, logs a `classification_report` and `confusion_matrix` based on the test set. For `IsolationForest`, logs score ranges.
        *   **Artifact Saving (`save_models` method)**: Saves the trained model, the fitted `StandardScaler` instance, and feature information (an ordered list of feature names and their importance scores, if applicable) to a specified output directory. These artifacts are essential for the `ArcPredictor` at inference time.

## Prerequisites for Training

1.  **Python Environment**:
    *   A Python 3.x environment.
    *   Necessary libraries installed, including:
        *   `pandas` (for data manipulation)
        *   `numpy` (for numerical operations)
        *   `scikit-learn` (for feature scaling, encoding, selection, and models like RandomForest, IsolationForest)
        *   `joblib` (for saving/loading model artifacts)
        *   `scipy` (for statistical functions like `linregress` if used in feature engineering or analysis)
    *   These can typically be installed via `pip install pandas numpy scikit-learn joblib scipy`.

2.  **Training Data**:
    *   A dataset (e.g., in CSV format or any other format Pandas can read) containing historical telemetry and operational data from your servers.
    *   **Features**: Should include the raw features that `FeatureEngineer` is configured to use, or if `FeatureEngineer` is skipped, the direct features `ArcModelTrainer` expects.
    *   **Target Variables**: For supervised learning:
        *   Health Prediction: A column indicating health status (e.g., `is_healthy` with values 0 for unhealthy, 1 for healthy).
        *   Failure Prediction: A column indicating impending failure (e.g., `will_fail` with values 0 for no impending failure, 1 for impending failure).
    *   Data quality is crucial; ensure data is as clean as possible, though `FeatureEngineer` and `ArcModelTrainer` provide some NaN handling.

3.  **Configuration File (`src/config/ai_config.json`)**:
    *   A well-defined `ai_config.json` is essential.
    *   The `feature_engineering` section must be tailored to your raw data to generate meaningful features.
    *   The `model_config` section must be configured:
        *   `model_config.features[model_type].required_features`: This list should match the output column names from your `FeatureEngineer` process if you run it as a distinct first step.
        *   `model_config.features[model_type].target_column`: Must correctly name your target variable in the dataset.
        *   `model_config.models[model_type]`: Should contain appropriate hyperparameters for the chosen scikit-learn models.

## How to Run Training (Conceptual Workflow)

Currently, the framework does not provide a single, all-encompassing script to run the entire training pipeline for all models. Training is typically performed by a custom Python script that leverages the `FeatureEngineer` and `ArcModelTrainer` classes. Here's a conceptual example of what such a script might do:

```python
import pandas as pd
from Python.common.ai_config_loader import AIConfig # Assuming you have a config loader
from Python.predictive.feature_engineering import FeatureEngineer
from Python.predictive.model_trainer import ArcModelTrainer
import os

# --- Configuration ---
# 1. Load AI Configuration
# (Replace with actual loading mechanism for ai_config.json)
# For example, if AIConfig.load() returns the full dict:
# config_data = AIConfig.load("src/config/ai_config.json")
# Or, load JSON directly:
import json
with open("src/config/ai_config.json", 'r') as f:
    config_data = json.load(f)

ai_components_config = config_data.get("aiComponents", {})
fe_config = ai_components_config.get("feature_engineering", {})
model_trainer_config = ai_components_config.get("model_config", {})
output_model_directory = "trained_models" # Define your output directory

# Create output directory if it doesn't exist
os.makedirs(output_model_directory, exist_ok=True)

# --- Data Loading ---
# 2. Load Raw Training Data
raw_training_data_path = "path/to/your/training_data.csv"
# This CSV should contain all original features and target columns
raw_df = pd.read_csv(raw_training_data_path)

# --- Feature Engineering ---
# 3. Instantiate FeatureEngineer
feature_engineer = FeatureEngineer(config=fe_config)

# 4. Engineer Features
# For supervised models, provide the target column name if it's used by any feature engineering step
# or if you want to ensure it's passed through (though typically target is only used by trainer).
# If FeatureEngineer does not use the target, it can be omitted here.
# Let's assume 'is_healthy' is one of the targets.
# FeatureEngineer might produce a very wide DataFrame with many new features.
# It's important that the 'required_features' in model_config for the trainer
# correctly lists the names of the features *after* this engineering step.

# Example for health prediction model data:
# The target 'is_healthy' needs to be in the df passed to trainer, but not necessarily to FE's engineer_features method unless FE uses it.
# It is safer to ensure the target column is present in the DataFrame passed to FeatureEngineer
# if feature selection (which requires a target) is enabled within FeatureEngineer.
health_engineered_df, health_fe_metadata = feature_engineer.engineer_features(
    raw_df.copy(), # Use a copy to avoid modifying original df
    target='is_healthy' # Provide target if feature selection is done in FE
)
# Ensure the target column is still in the engineered_df for the trainer
if 'is_healthy' not in health_engineered_df.columns and 'is_healthy' in raw_df.columns:
    health_engineered_df['is_healthy'] = raw_df['is_healthy']


# Similarly for failure prediction model data:
# Re-initialize FeatureEngineer if it has state (scalers, encoders fitted) and you want a fresh start for a different target
feature_engineer_fail = FeatureEngineer(config=fe_config)
failure_engineered_df, failure_fe_metadata = feature_engineer_fail.engineer_features(
    raw_df.copy(),
    target='will_fail'
)
if 'will_fail' not in failure_engineered_df.columns and 'will_fail' in raw_df.columns:
    failure_engineered_df['will_fail'] = raw_df['will_fail']


# And for anomaly detection (no target needed for FE if no feature selection)
feature_engineer_anomaly = FeatureEngineer(config=fe_config)
anomaly_engineered_df, anomaly_fe_metadata = feature_engineer_anomaly.engineer_features(
     raw_df.copy().drop(columns=['is_healthy', 'will_fail'], errors='ignore') # No target for anomaly
)


# --- Model Training ---
# 5. Instantiate ArcModelTrainer
# ArcModelTrainer's prepare_data will select columns specified in
# model_config.features[model_type].required_features from the DataFrames passed to it.
# Ensure these required_features lists in ai_config.json match columns present in
# health_engineered_df, failure_engineered_df, and anomaly_engineered_df respectively.
# If 'required_features_is_output_of_fe' is true (as set in test config), this is critical.
# The trainer config should list the *final* feature names that are output by FeatureEngineer.

trainer = ArcModelTrainer(config=model_trainer_config)

# 6. Call Training Methods
print("Training Health Prediction Model...")
trainer.train_health_prediction_model(health_engineered_df)

print("Training Failure Prediction Model...")
trainer.train_failure_prediction_model(failure_engineered_df)

print("Training Anomaly Detection Model...")
trainer.train_anomaly_detection_model(anomaly_engineered_df) # No target column needed

# 7. Save Models
trainer.save_models(output_model_directory)

print(f"Models, scalers, and feature information saved to: {output_model_directory}")
```

**Important Note on Feature Lists:** The `model_config.features[model_type].required_features` list in `ai_config.json` must contain the names of the features as they appear *after* the `FeatureEngineer` has processed the data, if `FeatureEngineer` is used as a preprocessing step before `ArcModelTrainer`.

## Output Artifacts

When `ArcModelTrainer.save_models()` is called, it saves the following for each trained model type (e.g., `health_prediction`):

*   **`[model_type]_model.pkl`**: The trained scikit-learn model object itself (e.g., a RandomForestClassifier).
*   **`[model_type]_scaler.pkl`**: The fitted `StandardScaler` object used for this model's features.
*   **`[model_type]_feature_importance.pkl`**: A Python dictionary containing:
    *   `'names'`: An ordered list of feature names that the model was trained on. This order is crucial for consistent feature preparation at prediction time.
    *   `'importances'`: A list of feature importance scores corresponding to the feature names (if the model type supports feature importances, like RandomForest). For models like IsolationForest, this might be `None`.

## Using Trained Models

Once models are trained and these artifacts are saved, the `ArcPredictor` class can be initialized with the directory containing these artifacts. `ArcPredictor` will load the models, scalers, and feature information to make predictions on new, incoming server telemetry data, ensuring that the same feature preparation (selection, order, scaling) is applied as was done during training.

import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier, IsolationForest
from sklearn.preprocessing import StandardScaler
from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report, confusion_matrix
import joblib
import logging
import os # Added os import
from datetime import datetime
from typing import Dict, List, Tuple, Any, Optional # Added Optional

# Ensure all necessary sklearn imports are present
from sklearn.ensemble import RandomForestClassifier, IsolationForest, GradientBoostingClassifier
from sklearn.preprocessing import StandardScaler
from sklearn.model_selection import train_test_split


class ArcModelTrainer:
    """Manages training of predictive models."""
    def __init__(self, config: Dict[str, Any]):
        """Initializes the model trainer with configuration."""
        self.config = config
        self.models: Dict[str, Any] = {}
        self.scalers: Dict[str, StandardScaler] = {}
        self.feature_importance: Dict[str, Dict[str, Any]] = {} # Stores names and importances
        self.setup_logging()

    def setup_logging(self):
        """Sets up logging for the model trainer."""
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            filename=f'model_training_{datetime.now().strftime("%Y%m%d")}.log'
        )
        self.logger = logging.getLogger('ArcModelTrainer')

    def prepare_data(self, data: pd.DataFrame, model_type: str) -> Tuple[Optional[np.ndarray], Optional[pd.Series], List[str]]:
        """Prepare data for training specific model types.
        Returns scaled features, target, and the list of feature names used, in order.
        Returns (None, None, []) if preparation fails.
        """
        try:
            # Select features based on model type
            feature_config = self.config['features'][model_type]

            # Ensure required_features are present in data's columns
            actual_features_to_use = [f for f in feature_config['required_features'] if f in data.columns]
            if len(actual_features_to_use) != len(feature_config['required_features']):
                self.logger.warning(f"Not all required_features for {model_type} found in input data columns. "
                                    f"Missing: {set(feature_config['required_features']) - set(actual_features_to_use)}")

            if not actual_features_to_use:
                self.logger.error(f"No required features for {model_type} found in data. Cannot prepare data.")
                return None, None, []

            features_df = data[actual_features_to_use].copy() # Use .copy() to avoid SettingWithCopyWarning later
            
            # Handle missing values
            features_df = self.handle_missing_values(features_df, feature_config['missing_strategy'], model_type)
            
            # Create scaler for this model type
            scaler = StandardScaler()
            scaled_features = scaler.fit_transform(features_df)
            self.scalers[model_type] = scaler
            
            # Prepare target variable if not anomaly detection
            if model_type != 'anomaly_detection':
                if feature_config['target_column'] not in data.columns:
                    self.logger.error(f"Target column '{feature_config['target_column']}' for {model_type} not found in data.")
                    return None, None, []
                target = data[feature_config['target_column']]
                return scaled_features, target, actual_features_to_use
            
            return scaled_features, None, actual_features_to_use

        except Exception as e:
            self.logger.error(f"Data preparation failed for {model_type}: {str(e)}")
            self.logger.error(f"Data preparation failed for {model_type}: {str(e)}", exc_info=True)
            return None, None, []


    def handle_missing_values(self, df: pd.DataFrame, strategy: str, model_type: str) -> pd.DataFrame:
        """Handle missing values in features DataFrame."""
        self.logger.info(f"Handling missing values for {model_type} using strategy: {strategy}")
        original_nan_counts = df.isnull().sum().sum()

        if df.empty:
            self.logger.warning(f"DataFrame for {model_type} is empty before handling missing values.")
            return df

        numeric_cols = df.select_dtypes(include=np.number).columns

        if strategy == 'mean':
            for col in numeric_cols: # Iterate explicitly to log per column if needed
                 fill_value = df[col].mean()
                 if pd.isna(fill_value): # If mean is NaN (e.g. all values were NaN)
                     fill_value = 0 # Fallback to 0
                     self.logger.warning(f"Mean for column {col} in {model_type} is NaN. Filling with 0.")
                 df[col].fillna(fill_value, inplace=True)
        elif strategy == 'median':
            for col in numeric_cols:
                 fill_value = df[col].median()
                 if pd.isna(fill_value):
                     fill_value = 0
                     self.logger.warning(f"Median for column {col} in {model_type} is NaN. Filling with 0.")
                 df[col].fillna(fill_value, inplace=True)
        elif strategy == 'zero':
            df.fillna(0, inplace=True)
        elif strategy == 'dropna': # Not generally recommended for feature sets unless handled carefully
            df.dropna(inplace=True)
            self.logger.info(f"Dropped rows with NaNs for {model_type}. Original rows: {original_nan_counts}, After drop: {len(df)}")
        else:
            self.logger.warning(f"Unknown missing value strategy '{strategy}' for {model_type}. Not handling NaNs.")
            return df # Return as is if strategy is unknown

        nan_counts_after = df.isnull().sum().sum()
        self.logger.info(f"Missing values handled for {model_type}. Original NaNs: {original_nan_counts}, Remaining NaNs: {nan_counts_after}")
        return df

    def train_health_prediction_model(self, data: pd.DataFrame) -> None:
        """Trains the health prediction model using configured algorithm."""
        model_type = 'health_prediction'
        self.logger.info(f"Starting training for {model_type} model...")
        try:
            # Configuration for this model type
            model_type_config = self.config.get('models', {}).get(model_type, {})
            if not model_type_config:
                self.logger.error(f"No configuration found for model type: {model_type}. Skipping training.")
                return

            test_split_ratio = self.config.get('test_split_ratio', 0.2)
            random_state = self.config.get('random_state', 42)
            model_algorithm = model_type_config.get('algorithm', 'RandomForestClassifier') # Default to RF

            X_scaled, y, feature_names = self.prepare_data(data, model_type)

            if X_scaled is None or y is None:
                self.logger.error(f"Data preparation failed for {model_type}. Skipping training.")
                return
            if len(np.unique(y)) < 2 :
                 self.logger.error(f"Target variable for {model_type} has less than 2 unique classes. Classification model cannot be trained. Unique values: {np.unique(y)}")
                 return

            X_train, X_test, y_train, y_test = train_test_split(X_scaled, y, test_size=test_split_ratio, random_state=random_state, stratify=y if np.unique(y).size > 1 else None)

            model = None
            self.logger.info(f"Training {model_type} model using algorithm: {model_algorithm}")

            if model_algorithm == 'RandomForestClassifier':
                algo_params = model_type_config.get('random_forest_params', {})
                model = RandomForestClassifier(
                    n_estimators=algo_params.get('n_estimators', 100),
                    max_depth=algo_params.get('max_depth', None),
                    class_weight=algo_params.get('class_weight', None),
                    random_state=random_state # Use global random_state for model
                )
            elif model_algorithm == 'GradientBoostingClassifier':
                algo_params = model_type_config.get('gradient_boosting_params', {})
                model = GradientBoostingClassifier(
                    n_estimators=algo_params.get('n_estimators', 100),
                    learning_rate=algo_params.get('learning_rate', 0.1),
                    max_depth=algo_params.get('max_depth', 3),
                    subsample=algo_params.get('subsample', 1.0),
                    random_state=random_state # Use global random_state for model
                )
            else:
                self.logger.error(f"Unsupported algorithm '{model_algorithm}' specified for {model_type}. Defaulting to RandomForestClassifier.")
                # Default to RandomForest if algorithm specified is unknown
                algo_params = model_type_config.get('random_forest_params', {})
                model = RandomForestClassifier(
                    n_estimators=algo_params.get('n_estimators', 100),
                    max_depth=algo_params.get('max_depth', None),
                    class_weight=algo_params.get('class_weight', None),
                    random_state=random_state
                )
                model_algorithm = 'RandomForestClassifier' # Update to actual used algorithm

            model.fit(X_train, y_train)
            self.models[model_type] = model

            self.feature_importance[model_type] = {
                'names': feature_names,
                'importances': model.feature_importances_.tolist() if hasattr(model, 'feature_importances_') else None,
                'algorithm': model_algorithm # Store the algorithm used
            }

            y_pred = model.predict(X_test)
            self.logger.info(f"{model_type} Model Performance:\n{classification_report(y_test, y_pred)}")
            self.logger.info(f"{model_type} Confusion Matrix:\n{confusion_matrix(y_test, y_pred)}")
            self.logger.info(f"{model_type} model training completed successfully.")

        except Exception as e:
            self.logger.error(f"{model_type} model training failed: {str(e)}", exc_info=True)

    def train_anomaly_detection_model(self, data: pd.DataFrame) -> None:
        """Trains the anomaly detection model."""
        model_type = 'anomaly_detection'
        self.logger.info(f"Starting training for {model_type} model...")
        try:
            model_params = self.config.get('models', {}).get(model_type, {})
            random_state = self.config.get('random_state', 42)

            X_scaled, _, feature_names = self.prepare_data(data, model_type)
            if X_scaled is None:
                self.logger.error(f"Data preparation failed for {model_type}. Skipping training.")
                return
            if X_scaled.shape[0] == 0:
                self.logger.error(f"No data available for training {model_type} after preparation. Skipping.")
                return

            model = IsolationForest(
                n_estimators=model_params.get('n_estimators', 100), # n_estimators added
                contamination=model_params.get('contamination', 'auto'),
                random_state=random_state
            )

            model.fit(X_scaled)
            self.models[model_type] = model

            self.feature_importance[model_type] = {'names': feature_names, 'importances': None} # IF doesn't have direct feature_importances_

            scores = model.score_samples(X_scaled)
            self.logger.info(f"{model_type} Model trained. Anomaly scores range: {scores.min():.2f} to {scores.max():.2f} (lower is more anomalous).")
            self.logger.info(f"{model_type} model training completed successfully.")

        except Exception as e:
            self.logger.error(f"{model_type} model training failed: {str(e)}", exc_info=True)

    def train_failure_prediction_model(self, data: pd.DataFrame) -> None:
        """Trains the failure prediction model."""
        model_type = 'failure_prediction'
        self.logger.info(f"Starting training for {model_type} model...")
        try:
            model_params = self.config.get('models', {}).get(model_type, {})
            test_split_ratio = self.config.get('test_split_ratio', 0.2)
            random_state = self.config.get('random_state', 42)

            X_scaled, y, feature_names = self.prepare_data(data, model_type)
            if X_scaled is None or y is None:
                self.logger.error(f"Data preparation failed for {model_type}. Skipping training.")
                return
            if len(np.unique(y)) < 2 :
                 self.logger.error(f"Target variable for {model_type} has less than 2 unique classes. Classification model cannot be trained. Unique values: {np.unique(y)}")
                 return

            X_train, X_test, y_train, y_test = train_test_split(X_scaled, y, test_size=test_split_ratio, random_state=random_state, stratify=y if np.unique(y).size > 1 else None)

            model = RandomForestClassifier(
                n_estimators=model_params.get('n_estimators', 100),
                max_depth=model_params.get('max_depth', None),
                class_weight=model_params.get('class_weight', 'balanced'), # Default to balanced for failure prediction
                random_state=random_state
            )

            model.fit(X_train, y_train)
            self.models[model_type] = model

            self.feature_importance[model_type] = {
                'names': feature_names,
                'importances': model.feature_importances_.tolist() if hasattr(model, 'feature_importances_') else None
            }

            y_pred = model.predict(X_test)
            self.logger.info(f"{model_type} Model Performance:\n{classification_report(y_test, y_pred)}")
            self.logger.info(f"{model_type} Confusion Matrix:\n{confusion_matrix(y_test, y_pred)}")
            self.logger.info(f"{model_type} model training completed successfully.")

        except Exception as e:
            self.logger.error(f"{model_type} model training failed: {str(e)}", exc_info=True)

    def save_models(self, output_dir: str) -> None:
        """Save trained models, scalers, and feature importance data."""
        try:
            os.makedirs(output_dir, exist_ok=True)
            self.logger.info(f"Saving models to directory: {output_dir}")

            for model_type, model in self.models.items():
                model_path = os.path.join(output_dir, f"{model_type}_model.pkl")
                joblib.dump(model, model_path)
                self.logger.info(f"Saved {model_type} model to {model_path}")

                if model_type in self.scalers:
                    scaler_path = os.path.join(output_dir, f"{model_type}_scaler.pkl")
                    joblib.dump(self.scalers[model_type], scaler_path)
                    self.logger.info(f"Saved {model_type} scaler to {scaler_path}")
                
                if model_type in self.feature_importance and self.feature_importance[model_type] is not None:
                    importance_path = os.path.join(output_dir, f"{model_type}_feature_importance.pkl")
                    joblib.dump(self.feature_importance[model_type], importance_path)
                    self.logger.info(f"Saved {model_type} feature importance to {importance_path}")

            self.logger.info(f"All models, scalers, and feature importance data saved to {output_dir}")

        except Exception as e:
            self.logger.error(f"Failed to save models: {str(e)}", exc_info=True)
            raise # Re-raise to indicate failure in saving

    def update_models_with_remediation(self, remediation_data: Dict[str, Any]) -> None:
        """Placeholder method for updating models with remediation data. Currently logs receipt of data and warns that full retraining logic is not implemented."""
        try:
            self.logger.info(f"Received remediation data for learning: {remediation_data.get('action')}")
            self.logger.warning("Full retraining logic for models with new remediation data is not yet implemented. Models were not updated.")
            # Pseudocode from prompt:
            # model_type_to_update = "failure_prediction" # or determine based on remediation_data
            # if model_type_to_update in self.models:
            #     self.logger.info(f"Attempting to update {model_type_to_update} model with remediation data.")
            #     # 1. Convert remediation_data to feature vector and target
            #     # This is highly dependent on the structure of remediation_data and model features
            #     # X_sample, y_sample = self._preprocess_remediation_for_model(remediation_data, model_type_to_update)
            #
            #     # 2. If valid sample obtained:
            #     # self.logger.info("New sample processed. Retraining model (simulation).")
            #     # This would require access to the original full dataset to append and retrain,
            #     # or a strategy for online learning if the model supports it.
            # else:
            #     self.logger.warning(f"Model type {model_type_to_update} not found for updating.")
        except Exception as e:
            self.logger.error(f"Failed to process remediation data for model update: {str(e)}", exc_info=True)
            # Do not re-raise, as this is a background learning process in the placeholder
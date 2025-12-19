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
        # Buffer for remediation samples awaiting a full retrain cycle
        self.remediation_buffer: Dict[str, List[Dict[str, Any]]] = {}
        self.setup_logging()

    def setup_logging(self):
        """Sets up logging for the model trainer."""
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            filename=f'model_training_{datetime.now().strftime("%Y%m%d")}.log'
        )
        self.logger = logging.getLogger('ArcModelTrainer')

    def prepare_data(self, data: pd.DataFrame, model_type: str) -> Tuple[np.ndarray, Optional[pd.Series], List[str]]:
        """Prepare data for training specific model types.

        Returns:
            (X_scaled, y_or_none, feature_names)

        Raises:
            ValueError for invalid inputs or missing required config/data.
        """
        if data is None:
            raise ValueError("data must not be None")
        if not isinstance(data, pd.DataFrame):
            raise ValueError("data must be a pandas DataFrame")
        if data.empty:
            raise ValueError("data must not be empty")
        if not model_type:
            raise ValueError("model_type must be provided")

        try:
            # Select features based on model type
            feature_config = self.config['features'][model_type]

            # Ensure required_features are present in data's columns
            actual_features_to_use = [f for f in feature_config['required_features'] if f in data.columns]
            if len(actual_features_to_use) != len(feature_config['required_features']):
                self.logger.warning(f"Not all required_features for {model_type} found in input data columns. "
                                    f"Missing: {set(feature_config['required_features']) - set(actual_features_to_use)}")

            if not actual_features_to_use:
                raise ValueError(f"No required features for {model_type} found in data")

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
                    raise ValueError(f"Target column '{feature_config['target_column']}' for {model_type} not found in data")
                target = data[feature_config['target_column']]
                return scaled_features, target, actual_features_to_use
            
            return scaled_features, None, actual_features_to_use

        except Exception as e:
            self.logger.error(f"Data preparation failed for {model_type}: {str(e)}", exc_info=True)
            raise


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
        if data is None:
            raise ValueError("data must not be None")
        if not isinstance(data, pd.DataFrame):
            raise ValueError("data must be a pandas DataFrame")
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
            raise

    def train_anomaly_detection_model(self, data: pd.DataFrame) -> None:
        """Trains the anomaly detection model."""
        model_type = 'anomaly_detection'
        self.logger.info(f"Starting training for {model_type} model...")
        if data is None:
            raise ValueError("data must not be None")
        if not isinstance(data, pd.DataFrame):
            raise ValueError("data must be a pandas DataFrame")
        try:
            model_params = self.config.get('models', {}).get(model_type, {})
            random_state = self.config.get('random_state', 42)

            X_scaled, _, feature_names = self.prepare_data(data, model_type)
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
            raise

    def train_failure_prediction_model(self, data: pd.DataFrame) -> None:
        """Trains the failure prediction model."""
        model_type = 'failure_prediction'
        self.logger.info(f"Starting training for {model_type} model...")
        if data is None:
            raise ValueError("data must not be None")
        if not isinstance(data, pd.DataFrame):
            raise ValueError("data must be a pandas DataFrame")

        try:
            model_params = self.config.get('models', {}).get(model_type, {})
            test_split_ratio = self.config.get('test_split_ratio', 0.2)
            random_state = self.config.get('random_state', 42)

            X_scaled, y, feature_names = self.prepare_data(data, model_type)
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
            raise

    def save_models(self, output_dir: str) -> None:
        """Save trained models, scalers, and feature importance data."""
        try:
            if output_dir is None or not isinstance(output_dir, str) or not output_dir.strip():
                raise ValueError("output_dir must be a non-empty string")
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

    def update_models_with_remediation(self, remediation_data: Dict[str, Any]) -> Dict[str, Any]:
        """Queue remediation samples for future retraining and validate inputs.

        The current models (RandomForest/IsolationForest) do not support online updates.
        This method buffers structured remediation samples and surfaces intent so callers
        can trigger a full retrain pipeline when enough data has accrued.
        """
        response: Dict[str, Any] = {
            "status": "rejected",
            "reason": "unspecified",
            "queued_count": 0,
        }

        try:
            if not isinstance(remediation_data, dict):
                response["reason"] = "remediation_data must be a dict"
                return response

            model_type = str(remediation_data.get("model_type", "failure_prediction"))
            if not model_type:
                response["reason"] = "model_type missing"
                return response

            features_payload = remediation_data.get("features") or remediation_data.get("context")
            if not isinstance(features_payload, dict) or not features_payload:
                response["reason"] = "features missing or not a dict"
                return response

            target_value = remediation_data.get("target")
            # Target is optional; if provided, require it to be int/bool/float
            if target_value is not None and not isinstance(target_value, (int, float, bool)):
                response["reason"] = "target must be numeric/bool if provided"
                return response

            # Determine expected features from trained metadata if available
            required_features: List[str] = self.feature_importance.get(model_type, {}).get("names", [])
            feature_vector: Dict[str, float] = {}
            if required_features:
                for name in required_features:
                    raw_val = features_payload.get(name)
                    try:
                        feature_vector[name] = float(raw_val) if raw_val is not None else 0.0
                    except Exception:
                        self.logger.warning(
                            f"Could not convert remediation feature '{name}' value '{raw_val}' to float; defaulting to 0.0"
                        )
                        feature_vector[name] = 0.0
            else:
                # Fallback: take numeric-like entries from payload
                for key, val in features_payload.items():
                    if isinstance(val, (int, float, bool)):
                        feature_vector[key] = float(val)

            if not feature_vector:
                response["reason"] = "no numeric features extracted"
                return response

            # Buffer the sample for later offline retraining
            if model_type not in self.remediation_buffer:
                self.remediation_buffer[model_type] = []
            self.remediation_buffer[model_type].append({
                "features": feature_vector,
                "target": target_value,
                "received_at": datetime.now().isoformat(),
            })

            threshold = int(self.config.get("remediation_update_batch_size", 10))
            queued_count = len(self.remediation_buffer[model_type])
            response.update({
                "status": "queued",
                "reason": "models require offline retrain; sample buffered",
                "queued_count": queued_count,
                "threshold": threshold,
                "model_type": model_type,
            })

            if queued_count >= threshold:
                # Signal that a full retrain should be initiated by a higher-level orchestrator
                response["status"] = "retrain_required"
                self.logger.info(
                    f"Remediation buffer for {model_type} reached {queued_count} samples (threshold {threshold}). "
                    "Trigger a full retrain with accumulated remediation data."
                )
            else:
                self.logger.info(
                    f"Buffered remediation sample for {model_type}. Count={queued_count}, threshold={threshold}."
                )

            return response

        except Exception as e:
            self.logger.error(f"Failed to process remediation data for model update: {str(e)}", exc_info=True)
            response["status"] = "error"
            response["reason"] = str(e)
            return response
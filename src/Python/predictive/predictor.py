import numpy as np
import pandas as pd
import joblib
import logging
from typing import Dict, List, Any, Optional # Ensure List and Optional are here
from datetime import datetime

class ArcPredictor:
    """[TODO: Add class documentation]"""
    def __init__(self, model_dir: str, config: Dict[str, Any] = None): # Added config
        """[TODO: Add method documentation]"""
        self.model_dir = model_dir
        self.config = config if config else {} # Store config
        self.models: Dict[str, Any] = {}
        self.scalers: Dict[str, StandardScaler] = {} # Type hint for clarity
        self.feature_info: Dict[str, Dict[str, Any]] = {} # Renamed from model_metadata
        self.setup_logging()
        self.load_models()

    def setup_logging(self):
        """[TODO: Add method documentation]"""
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            filename=f'predictor_{datetime.now().strftime("%Y%m%d")}.log'
        )
        self.logger = logging.getLogger('ArcPredictor')

    def load_models(self):
        """Load all trained models and scalers."""
        try:
            model_types = ['health_prediction', 'anomaly_detection', 'failure_prediction']
            
            for model_type in model_types:
                model_path = f"{self.model_dir}/{model_type}_model.pkl"
                scaler_path = f"{self.model_dir}/{model_type}_scaler.pkl"
                # Path for feature info (assuming ArcModelTrainer saves it this way)
                # Step 7 (ArcModelTrainer) saved 'feature_importance' which was a dict: {'names': [...], 'importances': [...]}
                # This is more aligned with 'feature_info.pkl' than 'metadata.pkl' or 'feature_importance.pkl' alone.
                # Let's assume the file is named more generically like 'feature_info.pkl' or use the existing 'feature_importance.pkl'
                # and derive ordered_features and importances from it.
                # Based on prompt: "ArcModelTrainer saves feature_importance as a dictionary where model.feature_importances_ were zipped with an ordered list of feature names."
                # So, list(loaded_feature_importance.keys()) would give the ordered feature names.

                # Let's assume ArcModelTrainer saves a dict like:
                # {'names': ['feat1', 'feat2'], 'importances': [0.5, 0.5]}
                # OR, if it saved dict(zip(ordered_names, importances)), then keys() gives names.
                # The prompt for Step 7 (ArcModelTrainer) saved:
                # self.feature_importance[model_type] = {'names': feature_names, 'importances': model.feature_importances_.tolist()}
                # So we load this dict.
                feature_info_path = f"{self.model_dir}/{model_type}_feature_importance.pkl"


                self.models[model_type] = joblib.load(model_path)
                self.scalers[model_type] = joblib.load(scaler_path)
                
                self.feature_info[model_type] = {} # Initialize for the type
                try:
                    loaded_importance_data = joblib.load(feature_info_path)
                    if isinstance(loaded_importance_data, dict):
                        self.feature_info[model_type]['ordered_features'] = loaded_importance_data.get('names', [])
                        # Store the raw importances list/array if present, or None
                        raw_importances = loaded_importance_data.get('importances')
                        if raw_importances is not None:
                             # Create the name:importance map for calculate_feature_impacts
                            self.feature_info[model_type]['importances_map'] = dict(zip(self.feature_info[model_type]['ordered_features'], raw_importances))
                        else:
                            self.feature_info[model_type]['importances_map'] = None
                        self.logger.info(f"Loaded feature info for {model_type}. Features: {self.feature_info[model_type]['ordered_features']}")
                    else: # Legacy: if it's just a dict of name:importance (order might be an issue)
                        self.logger.warning(f"Legacy feature importance format loaded for {model_type}. Order might not be guaranteed if Python < 3.7 was used for saving.")
                        self.feature_info[model_type]['ordered_features'] = list(loaded_importance_data.keys())
                        self.feature_info[model_type]['importances_map'] = loaded_importance_data

                except FileNotFoundError:
                    self.logger.warning(f"Feature info file not found for {model_type} at {feature_info_path}. Prediction may fail or be unreliable.")
                    self.feature_info[model_type]['ordered_features'] = []
                    self.feature_info[model_type]['importances_map'] = None
                except Exception as e_fi:
                    self.logger.error(f"Error loading feature info for {model_type} from {feature_info_path}: {e_fi}", exc_info=True)
                    self.feature_info[model_type]['ordered_features'] = []
                    self.feature_info[model_type]['importances_map'] = None


            self.logger.info("Models, scalers, and feature info loaded.")

        except Exception as e:
            self.logger.error(f"Failed to load models: {str(e)}")
            raise

    def predict_health(self, telemetry_data: Dict[str, Any]) -> Dict[str, Any]:
        """Predict health status based on telemetry data."""
        model_type = 'health_prediction'
        try:
            raw_features_array = self.prepare_features(telemetry_data, model_type)
            if raw_features_array is None or raw_features_array.size == 0:
                self.logger.error(f"Feature preparation failed or resulted in empty array for {model_type}.")
                return {"error": f"Feature preparation failed or resulted in empty data for {model_type}."}

            scaled_features_array = self.scalers[model_type].transform(raw_features_array)
            prediction = self.models[model_type].predict_proba(scaled_features_array)[0]
            # Use feature_info for impacts
            current_feature_info = self.feature_info.get(model_type, {})
            importances_map = current_feature_info.get('importances_map')
            ordered_feature_names = current_feature_info.get('ordered_features', [])

            feature_impacts = {}
            if importances_map and ordered_feature_names:
                # calculate_feature_impacts expects the 1D scaled feature array
                feature_impacts = self.calculate_feature_impacts(
                    scaled_features_array[0],
                    importances_map, # This is the dict of name:importance
                    ordered_feature_names # This is the ordered list of names
                )
            else:
                self.logger.warning(f"Feature importance map or ordered names not available for {model_type}. Skipping impact calculation.")

            return {
                'prediction': {
                    'healthy_probability': prediction[1],
                    'unhealthy_probability': prediction[0]
                },
                'feature_impacts': feature_impacts,
                'timestamp': datetime.now().isoformat()
            }

        except Exception as e:
            self.logger.error(f"Health prediction failed: {str(e)}")
            raise

    def detect_anomalies(self, telemetry_data: Dict[str, Any]) -> Dict[str, Any]:
        """Detect anomalies in telemetry data."""
        model_type = 'anomaly_detection'
        try:
            raw_features_array = self.prepare_features(telemetry_data, model_type)
            if raw_features_array is None or raw_features_array.size == 0:
                self.logger.error(f"Feature preparation failed or resulted in empty array for {model_type}.")
                return {"error": f"Feature preparation failed or resulted in empty data for {model_type}."}

            scaled_features_array = self.scalers[model_type].transform(raw_features_array)
            anomaly_scores = self.models[model_type].score_samples(scaled_features_array)
            is_anomaly_prediction = self.models[model_type].predict(scaled_features_array)[0]

            # No feature impacts typically for IsolationForest from .feature_importances_

            return {
                'is_anomaly': is_anomaly_prediction == -1,
                'anomaly_score': float(anomaly_scores[0]), # score_samples returns the negative of the anomaly score. Higher is more normal.
                                                          # For consistency, one might invert this or use decision_function.
                                                          # Let's assume this score is directly usable/interpretable as is for now.
                # 'threshold': self.models[model_type].threshold_, # threshold_ is for contamination if using it to predict.
                                                                # The score itself is more of a relative measure.
                'timestamp': datetime.now().isoformat()
            }

        except Exception as e:
            self.logger.error(f"Anomaly detection failed: {str(e)}")
            raise

    def predict_failures(self, telemetry_data: Dict[str, Any]) -> Dict[str, Any]:
        """Predict potential failures based on telemetry data."""
        model_type = 'failure_prediction'
        try:
            raw_features_array = self.prepare_features(telemetry_data, model_type)
            if raw_features_array is None or raw_features_array.size == 0:
                self.logger.error(f"Feature preparation failed or resulted in empty array for {model_type}.")
                return {"error": f"Feature preparation failed or resulted in empty data for {model_type}."}

            scaled_features_array = self.scalers[model_type].transform(raw_features_array)
            prediction = self.models[model_type].predict_proba(scaled_features_array)[0]

            current_feature_info = self.feature_info.get(model_type, {})
            importances_map = current_feature_info.get('importances_map')
            ordered_feature_names = current_feature_info.get('ordered_features', [])

            feature_impacts = {}
            if importances_map and ordered_feature_names:
                feature_impacts = self.calculate_feature_impacts(
                    scaled_features_array[0],
                    importances_map,
                    ordered_feature_names
                )
            else:
                self.logger.warning(f"Feature importance map or ordered names not available for {model_type}. Skipping impact calculation.")

            return {
                'prediction': {
                    'failure_probability': prediction[1],
                    'normal_probability': prediction[0]
                },
                'feature_impacts': feature_impacts,
                'risk_level': self.calculate_risk_level(prediction[1]),
                'timestamp': datetime.now().isoformat()
            }

        except Exception as e:
            self.logger.error(f"Failure prediction failed: {str(e)}")
            raise

    def prepare_features(self, telemetry_data: Dict[str, Any], model_type: str) -> Optional[np.ndarray]:
        """Prepare features for prediction based on the loaded model's required feature order."""
        try:
            if model_type not in self.feature_info or not self.feature_info[model_type].get('ordered_features'):
                self.logger.error(f"Ordered feature list not loaded for model_type: '{model_type}'. Cannot prepare features.")
                return None

            ordered_feature_names = self.feature_info[model_type]['ordered_features']
            if not ordered_feature_names: # Should be caught by above, but defensive check
                 self.logger.error(f"Feature list for model_type: '{model_type}' is empty. Cannot prepare features.")
                 return None

            feature_values = []
            for feature_name in ordered_feature_names:
                if feature_name not in telemetry_data:
                    self.logger.warning(f"Feature '{feature_name}' (required by model '{model_type}') not found in telemetry_data. Using 0.0 as default.")
                    feature_values.append(0.0)
                else:
                    value = telemetry_data[feature_name]
                    if pd.isna(value): # Handle if data source itself has NaN for a feature
                        self.logger.warning(f"Feature '{feature_name}' has NaN value in telemetry_data for '{model_type}'. Using 0.0 as default.")
                        feature_values.append(0.0)
                    else:
                        try:
                            feature_values.append(float(value))
                        except ValueError:
                            self.logger.warning(f"Could not convert feature '{feature_name}' value '{value}' to float. Using 0.0.")
                            feature_values.append(0.0)

            # Convert to numpy array and reshape for a single sample
            features_array = np.array([feature_values], dtype=float)
            return features_array

        except Exception as e:
            self.logger.error(f"Feature preparation failed for {model_type}: {str(e)}", exc_info=True)
            return None
    def calculate_feature_impacts(self,
                                 scaled_features_array_1d: np.ndarray,
                                 feature_importance_dict: Dict[str, float], # This is the map of name:importance
                                 ordered_feature_names: List[str]
                                 ) -> Dict[str, float]:
        """Calculate the impact of each feature on the prediction using a definitive feature order."""
        impacts = {}
        if not feature_importance_dict: # Check if the map itself is None or empty
            self.logger.info("Feature importance map is empty or None. Skipping impact calculation.")
            return impacts
        if not ordered_feature_names:
            self.logger.info("Ordered feature names list is empty. Skipping impact calculation.")
            return impacts

        # Ensure consistency between the length of the feature vector and the ordered names list
        if len(scaled_features_array_1d) != len(ordered_feature_names):
            self.logger.error(f"Mismatch in length between scaled_features_array_1d ({len(scaled_features_array_1d)}) and ordered_feature_names ({len(ordered_feature_names)}). Cannot calculate impacts.")
            return impacts

        for i, feature_name in enumerate(ordered_feature_names):
            if feature_name not in feature_importance_dict:
                self.logger.warning(f"Feature '{feature_name}' from ordered list not found in importance map. Skipping its impact.")
                continue # Skip if importance for this specific feature is not available

            importance = feature_importance_dict[feature_name]
            feature_value = scaled_features_array_1d[i]
            impacts[feature_name] = float(feature_value * importance)

        if len(ordered_feature_names) != scaled_features_array_1d.shape[0]: # Check against the numpy array shape
             self.logger.warning(
                f"Mismatch in length between ordered feature names ({len(ordered_feature_names)}) "
                f"and prepared scaled features array ({scaled_features_array_1d.shape[0]}). "
                "Impact calculation might be incomplete or incorrect."
            )
        return impacts

    def calculate_risk_level(self, failure_probability: float) -> str:
        """[TODO: Add method documentation]"""
        if failure_probability >= 0.75:
            return 'Critical'
        elif failure_probability >= 0.5:
            return 'High'
        elif failure_probability >= 0.25:
            return 'Medium'
        else:
            return 'Low'
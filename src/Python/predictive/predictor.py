import numpy as np
import pandas as pd
import joblib
import logging
from typing import Dict, List, Any, Optional # Ensure List and Optional are here
from datetime import datetime

class ArcPredictor:
    def __init__(self, model_dir: str):
        self.model_dir = model_dir
        self.models = {}
        self.scalers = {}
        self.model_metadata = {} # NEW
        self.setup_logging()
        self.load_models()

    def setup_logging(self):
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
                metadata_path = f"{self.model_dir}/{model_type}_metadata.pkl" # NEW

                self.models[model_type] = joblib.load(model_path)
                self.scalers[model_type] = joblib.load(scaler_path)
                
                try:
                    self.model_metadata[model_type] = joblib.load(metadata_path) # NEW
                except FileNotFoundError:
                    self.logger.warning(f"Metadata file not found for {model_type} at {metadata_path}. Feature names for prediction and impact calculation might be unavailable.")
                    self.model_metadata[model_type] = {'feature_order': [], 'feature_importances': None} # Default

            self.logger.info("Models and metadata loaded successfully")

        except Exception as e:
            self.logger.error(f"Failed to load models: {str(e)}")
            raise

    def predict_health(self, telemetry_data: Dict[str, Any]) -> Dict[str, Any]:
        """Predict health status based on telemetry data."""
        model_type = 'health_prediction'
        try:
            features_array = self.prepare_features(telemetry_data, model_type)
            if features_array is None:
                return {"error": f"Feature preparation failed for {model_type}."}
            
            # Handle cases where features_array might be empty despite passing None check (e.g. if prepare_features changes)
            if features_array.size == 0:
                self.logger.warning(f"Prepared features array is empty for {model_type}. Cannot predict.")
                return {"error": f"Prepared features array is empty for {model_type}."}


            scaled_features = self.scalers[model_type].transform(features_array)
            prediction = self.models[model_type].predict_proba(scaled_features)[0]

            model_meta = self.model_metadata.get(model_type, {})
            feature_importances_map = model_meta.get('feature_importances')
            ordered_feature_names_for_impact = model_meta.get('feature_order')

            if feature_importances_map and ordered_feature_names_for_impact:
                feature_impacts = self.calculate_feature_impacts(
                    scaled_features[0],
                    feature_importances_map,
                    ordered_feature_names_for_impact
                )
            else:
                feature_impacts = {}
                self.logger.warning(f"Feature importances or feature order not available for {model_type} model.")

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
            features_array = self.prepare_features(telemetry_data, model_type)
            if features_array is None:
                 return {"error": f"Feature preparation failed for {model_type}."}
            
            if features_array.size == 0:
                self.logger.warning(f"Prepared features array is empty for {model_type}. Cannot detect anomalies.")
                return {"error": f"Prepared features array is empty for {model_type}."}

            scaled_features = self.scalers[model_type].transform(features_array)

            anomaly_scores = self.models[model_type].score_samples(scaled_features)
            # predict gives -1 for outliers and 1 for inliers.
            is_anomaly_prediction = self.models[model_type].predict(scaled_features)[0]

            # Note: feature impact for IsolationForest is not straightforward like RF.
            # SHAP or other methods would be needed. For now, impacts are not calculated here.

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
            features_array = self.prepare_features(telemetry_data, model_type)
            if features_array is None:
                return {"error": f"Feature preparation failed for {model_type}."}

            if features_array.size == 0:
                self.logger.warning(f"Prepared features array is empty for {model_type}. Cannot predict.")
                return {"error": f"Prepared features array is empty for {model_type}."}

            scaled_features = self.scalers[model_type].transform(features_array)
            prediction = self.models[model_type].predict_proba(scaled_features)[0]

            model_meta = self.model_metadata.get(model_type, {})
            feature_importances_map = model_meta.get('feature_importances')
            ordered_feature_names_for_impact = model_meta.get('feature_order')

            if feature_importances_map and ordered_feature_names_for_impact:
                feature_impacts = self.calculate_feature_impacts(
                    scaled_features[0],
                    feature_importances_map,
                    ordered_feature_names_for_impact
                )
            else:
                feature_impacts = {}
                self.logger.warning(f"Feature importances or feature order not available for {model_type} model.")

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
            if model_type not in self.model_metadata or not self.model_metadata[model_type].get('feature_order'):
                self.logger.error(f"Feature order not loaded for model_type: {model_type}. Cannot prepare features.")
                return None

            ordered_feature_names = self.model_metadata[model_type]['feature_order']

            feature_values = []
            for feature_name in ordered_feature_names:
                if feature_name not in telemetry_data:
                    self.logger.warning(f"Feature '{feature_name}' required by model '{model_type}' not found in telemetry_data. Using NaN.")
                    feature_values.append(np.nan) # Model's scaler should handle this if trained with NaN handling
                else:
                    feature_values.append(telemetry_data[feature_name])

            # Convert to numpy array and reshape for a single sample
            features_array = np.array([feature_values], dtype=float) # Ensure float for NaNs

            if np.isnan(features_array).any():
                self.logger.warning(f"NaNs present in feature array for {model_type} before scaling: {ordered_feature_names} -> {features_array}. Ensure scaler handles NaNs.")

            return features_array

        except Exception as e:
            self.logger.error(f"Feature preparation failed for {model_type}: {str(e)}")
            # raise # Or return None
            return None


    def calculate_feature_impacts(self,
                                 prepared_scaled_feature_vector: np.ndarray,
                                 feature_importance_map: Dict[str, float],
                                 ordered_feature_names: List[str] # New parameter
                                 ) -> Dict[str, float]:
        """Calculate the impact of each feature on the prediction using a definitive feature order."""
        impacts = {}
        if not feature_importance_map:
            self.logger.info("Feature importance map is empty or None. Skipping impact calculation.")
            return impacts
        if not ordered_feature_names:
            self.logger.info("Ordered feature names list is empty. Skipping impact calculation.")
            return impacts

        if len(ordered_feature_names) != len(prepared_scaled_feature_vector):
            self.logger.warning(
                f"Mismatch in length between ordered_feature_names ({len(ordered_feature_names)}) "
                f"and prepared_scaled_feature_vector ({len(prepared_scaled_feature_vector)}). "
                "Impact calculation might be incorrect."
            )
            return impacts

        for i, feature_name in enumerate(ordered_feature_names):
            if feature_name not in feature_importance_map:
                self.logger.warning(f"Feature '{feature_name}' from ordered list not in importance map. Skipping its impact.")
                continue

            importance_value = feature_importance_map[feature_name]
            feature_value = prepared_scaled_feature_vector[i]
            impacts[feature_name] = float(feature_value * importance_value)
        return impacts

    def calculate_risk_level(self, failure_probability: float) -> str:
        """Calculate risk level based on failure probability."""
        if failure_probability >= 0.75:
            return 'Critical'
        elif failure_probability >= 0.5:
            return 'High'
        elif failure_probability >= 0.25:
            return 'Medium'
        else:
            return 'Low'
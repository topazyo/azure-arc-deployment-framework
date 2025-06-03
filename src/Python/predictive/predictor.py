import numpy as np
import pandas as pd
import joblib
import logging
from typing import Dict, List, Any, Optional
from datetime import datetime

class ArcPredictor:
    def __init__(self, model_dir: str):
        self.model_dir = model_dir
        self.models = {}
        self.scalers = {}
        self.feature_importance = {}
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
                importance_path = f"{self.model_dir}/{model_type}_feature_importance.pkl"

                self.models[model_type] = joblib.load(model_path)
                self.scalers[model_type] = joblib.load(scaler_path)
                
                if model_type != 'anomaly_detection':
                    self.feature_importance[model_type] = joblib.load(importance_path)

            self.logger.info("Models loaded successfully")

        except Exception as e:
            self.logger.error(f"Failed to load models: {str(e)}")
            raise

    def predict_health(self, telemetry_data: Dict[str, Any]) -> Dict[str, Any]:
        """Predict health status based on telemetry data."""
        try:
            features = self.prepare_features(telemetry_data, 'health_prediction')
            scaled_features = self.scalers['health_prediction'].transform(features)
            
            prediction = self.models['health_prediction'].predict_proba(scaled_features)[0]
            feature_impacts = self.calculate_feature_impacts(
                scaled_features[0], 
                self.feature_importance['health_prediction']
            )

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
        try:
            features = self.prepare_features(telemetry_data, 'anomaly_detection')
            scaled_features = self.scalers['anomaly_detection'].transform(features)
            
            anomaly_scores = self.models['anomaly_detection'].score_samples(scaled_features)
            predictions = self.models['anomaly_detection'].predict(scaled_features)

            return {
                'is_anomaly': predictions[0] == -1,
                'anomaly_score': float(anomaly_scores[0]),
                'threshold': self.models['anomaly_detection'].threshold_,
                'timestamp': datetime.now().isoformat()
            }

        except Exception as e:
            self.logger.error(f"Anomaly detection failed: {str(e)}")
            raise

    def predict_failures(self, telemetry_data: Dict[str, Any]) -> Dict[str, Any]:
        """Predict potential failures based on telemetry data."""
        try:
            features = self.prepare_features(telemetry_data, 'failure_prediction')
            scaled_features = self.scalers['failure_prediction'].transform(features)
            
            prediction = self.models['failure_prediction'].predict_proba(scaled_features)[0]
            feature_impacts = self.calculate_feature_impacts(
                scaled_features[0], 
                self.feature_importance['failure_prediction']
            )

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

    def prepare_features(self, telemetry_data: Dict[str, Any], model_type: str) -> np.ndarray:
        """Prepare features for prediction."""
        try:
            # Extract and organize features based on model type
            if model_type == 'health_prediction':
                features = np.array([[
                    telemetry_data['cpu_usage'],
                    telemetry_data['memory_usage'],
                    telemetry_data['disk_usage'],
                    telemetry_data['network_latency'],
                    telemetry_data['error_count'],
                    telemetry_data['warning_count']
                ]])
            elif model_type == 'anomaly_detection':
                features = np.array([[
                    telemetry_data['cpu_usage'],
                    telemetry_data['memory_usage'],
                    telemetry_data['disk_usage'],
                    telemetry_data['network_latency'],
                    telemetry_data['request_count'],
                    telemetry_data['response_time']
                ]])
            elif model_type == 'failure_prediction':
                features = np.array([[
                    telemetry_data['service_restarts'],
                    telemetry_data['error_count'],
                    telemetry_data['cpu_spikes'],
                    telemetry_data['memory_spikes'],
                    telemetry_data['connection_drops']
                ]])
            else:
                raise ValueError(f"Unknown model type: {model_type}")

            return features

        except Exception as e:
            self.logger.error(f"Feature preparation failed: {str(e)}")
            raise

    def calculate_feature_impacts(self, prepared_features_array: np.ndarray, feature_importance: Dict[str, float]) -> Dict[str, float]:
        """Calculate the impact of each feature on the prediction.
        Note: This implementation assumes that the order of features in
        `feature_importance.keys()` matches the order of columns in `prepared_features_array`.
        """
        impacts = {}
        # Assuming prepared_features_array is 1D array for a single prediction (e.g., shape (num_features,))
        # or a 2D array for multiple predictions (e.g., shape (num_samples, num_features)).
        # We are typically interested in the impacts for a single sample.

        # If prepared_features_array is 2D (e.g. from self.scalers[...].transform(features))
        # and we are predicting for one sample at a time, it would be features_1d = prepared_features_array[0]
        # However, the input `scaled_features[0]` to this method in `predict_health` and `predict_failures`
        # suggests `prepared_features_array` is already the 1D array for the single sample.

        feature_names_in_order = list(feature_importance.keys()) # Assumed order

        for i, feature_name in enumerate(feature_names_in_order):
            if i < prepared_features_array.shape[0]: # Check if index is within bounds
                importance_value = feature_importance[feature_name]
                feature_value = prepared_features_array[i]
                impacts[feature_name] = float(feature_value * importance_value)
            else:
                self.logger.warning(f"Feature index {i} for feature '{feature_name}' is out of bounds for prepared_features_array.")

        if len(feature_names_in_order) != prepared_features_array.shape[0]:
             self.logger.warning(
                f"Mismatch in length between feature names ({len(feature_names_in_order)}) "
                f"and prepared features array ({prepared_features_array.shape[0]}). "
                "Impact calculation might be incomplete or incorrect."
            )
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
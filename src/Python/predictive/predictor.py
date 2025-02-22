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

    def calculate_feature_impacts(self, features: np.ndarray, feature_importance: Dict[str, float]) -> Dict[str, float]:
        """Calculate the impact of each feature on the prediction."""
        impacts = {}
        for feature_name, importance in feature_importance.items():
            impacts[feature_name] = float(features[feature_name] * importance)
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
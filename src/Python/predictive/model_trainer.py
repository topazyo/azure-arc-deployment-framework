import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier, IsolationForest
from sklearn.preprocessing import StandardScaler
from sklearn.model_selection import train_test_split
from sklearn.metrics import classification_report, confusion_matrix
import joblib
import logging
from datetime import datetime
from typing import Dict, List, Tuple, Any

class ArcModelTrainer:
    def __init__(self, config: Dict[str, Any]):
        self.config = config
        self.models = {}
        self.scalers = {}
        self.feature_importance = {}
        self.setup_logging()

    def setup_logging(self):
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            filename=f'model_training_{datetime.now().strftime("%Y%m%d")}.log'
        )
        self.logger = logging.getLogger('ArcModelTrainer')

    def prepare_data(self, data: pd.DataFrame, model_type: str) -> Tuple[np.ndarray, np.ndarray]:
        """Prepare data for training specific model types."""
        try:
            # Select features based on model type
            feature_config = self.config['features'][model_type]
            features = data[feature_config['required_features']]
            
            # Handle missing values
            features = self.handle_missing_values(features, feature_config['missing_strategy'])
            
            # Create scaler for this model type
            scaler = StandardScaler()
            scaled_features = scaler.fit_transform(features)
            self.scalers[model_type] = scaler
            
            # Prepare target variable if not anomaly detection
            if model_type != 'anomaly_detection':
                target = data[feature_config['target_column']]
                return scaled_features, target
            
            return scaled_features, None

        except Exception as e:
            self.logger.error(f"Data preparation failed for {model_type}: {str(e)}")
            raise

    def train_health_prediction_model(self, data: pd.DataFrame) -> None:
        """Train model for predicting Arc agent health issues."""
        try:
            X, y = self.prepare_data(data, 'health_prediction')
            X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)

            model = RandomForestClassifier(
                n_estimators=self.config['models']['health_prediction']['n_estimators'],
                max_depth=self.config['models']['health_prediction']['max_depth'],
                random_state=42
            )

            model.fit(X_train, y_train)
            self.models['health_prediction'] = model

            # Calculate and store feature importance
            feature_names = self.config['features']['health_prediction']['required_features']
            self.feature_importance['health_prediction'] = dict(zip(feature_names, model.feature_importances_))

            # Evaluate model
            y_pred = model.predict(X_test)
            self.logger.info("Health Prediction Model Performance:")
            self.logger.info("\n" + classification_report(y_test, y_pred))

        except Exception as e:
            self.logger.error(f"Health prediction model training failed: {str(e)}")
            raise

    def train_anomaly_detection_model(self, data: pd.DataFrame) -> None:
        """Train model for detecting anomalous behavior."""
        try:
            X, _ = self.prepare_data(data, 'anomaly_detection')

            model = IsolationForest(
                contamination=self.config['models']['anomaly_detection']['contamination'],
                random_state=42
            )

            model.fit(X)
            self.models['anomaly_detection'] = model

            # Evaluate model
            scores = model.score_samples(X)
            self.logger.info(f"Anomaly Detection Model trained. Score range: {scores.min():.2f} to {scores.max():.2f}")

        except Exception as e:
            self.logger.error(f"Anomaly detection model training failed: {str(e)}")
            raise

    def train_failure_prediction_model(self, data: pd.DataFrame) -> None:
        """Train model for predicting potential failures."""
        try:
            X, y = self.prepare_data(data, 'failure_prediction')
            X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2, random_state=42)

            model = RandomForestClassifier(
                n_estimators=self.config['models']['failure_prediction']['n_estimators'],
                max_depth=self.config['models']['failure_prediction']['max_depth'],
                class_weight='balanced',
                random_state=42
            )

            model.fit(X_train, y_train)
            self.models['failure_prediction'] = model

            # Calculate and store feature importance
            feature_names = self.config['features']['failure_prediction']['required_features']
            self.feature_importance['failure_prediction'] = dict(zip(feature_names, model.feature_importances_))

            # Evaluate model
            y_pred = model.predict(X_test)
            self.logger.info("Failure Prediction Model Performance:")
            self.logger.info("\n" + classification_report(y_test, y_pred))

        except Exception as e:
            self.logger.error(f"Failure prediction model training failed: {str(e)}")
            raise

    def save_models(self, output_dir: str) -> None:
        """Save trained models and scalers."""
        try:
            for model_type, model in self.models.items():
                model_path = f"{output_dir}/{model_type}_model.pkl"
                scaler_path = f"{output_dir}/{model_type}_scaler.pkl"
                
                joblib.dump(model, model_path)
                joblib.dump(self.scalers[model_type], scaler_path)
                
                # Save feature importance if available
                if model_type in self.feature_importance:
                    importance_path = f"{output_dir}/{model_type}_feature_importance.pkl"
                    joblib.dump(self.feature_importance[model_type], importance_path)

            self.logger.info(f"Models and scalers saved to {output_dir}")

        except Exception as e:
            self.logger.error(f"Failed to save models: {str(e)}")
            raise

    def handle_missing_values(self, features: pd.DataFrame, strategy: str) -> pd.DataFrame:
        """Handle missing values in features."""
        if strategy == 'mean':
            return features.fillna(features.mean())
        elif strategy == 'median':
            return features.fillna(features.median())
        elif strategy == 'zero':
            return features.fillna(0)
        else:
            return features.dropna()
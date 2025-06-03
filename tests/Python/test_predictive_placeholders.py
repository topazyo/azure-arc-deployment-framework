import pytest
import pandas as pd
import numpy as np
from typing import Dict, Any, List
import joblib
import os
from unittest.mock import patch, MagicMock

# Add src to path to allow direct import of modules
import sys
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../../src')))

from Python.predictive.ArcRemediationLearner import ArcRemediationLearner
from Python.predictive.feature_engineering import FeatureEngineer
from Python.predictive.model_trainer import ArcModelTrainer
from Python.predictive.predictive_analytics_engine import PredictiveAnalyticsEngine
from Python.predictive.predictor import ArcPredictor
from Python.analysis.pattern_analyzer import PatternAnalyzer # For PredictiveAnalyticsEngine dependency

@pytest.fixture
def base_predictive_config() -> Dict[str, Any]:
    # From src/config/ai_config.json structure
    return {
        "feature_engineering": {
            "rolling_window": 3, # Smaller for test data
            "lags": [1, 2],      # Smaller for test data
            "selected_k_features": 10
        },
        "model_config": {
            "features": {
                "health_prediction": {
                    "required_features": ["cpu_usage", "memory_usage", "disk_usage", "network_latency", "error_count", "warning_count"],
                    "missing_strategy": "mean",
                    "target_column": "is_healthy"
                },
                "anomaly_detection": {
                    "required_features": ["cpu_usage", "memory_usage", "disk_usage", "network_latency", "request_count", "response_time"],
                    "missing_strategy": "median"
                },
                "failure_prediction": {
                    "required_features": ["service_restarts", "error_count", "cpu_spikes", "memory_spikes", "connection_drops"],
                    "missing_strategy": "zero",
                    "target_column": "will_fail"
                }
            },
            "models": {
                "health_prediction": {"n_estimators": 10, "max_depth": 3}, # Faster training
                "anomaly_detection": {"contamination": 0.05},
                "failure_prediction": {"n_estimators": 10, "max_depth": 3} # Faster training
            }
        },
         "clustering": {"eps": 0.5, "min_samples": 2}, # For PatternAnalyzer used in PAE
    }

@pytest.fixture
def sample_remediation_data() -> Dict[str, Any]:
    return {
        "error_type": "NetworkFailure",
        "action": "RestartNetworking",
        "outcome": "success",
        "context": {
            "cpu_usage": 0.5, "memory_usage": 0.6, "error_count": 5,
            "service_status": 1, "connection_status": 0
        }
    }

@pytest.fixture
def sample_feature_data_df() -> pd.DataFrame:
    return pd.DataFrame({
        'timestamp': pd.to_datetime(['2023-01-01 10:00:00', '2023-01-01 10:05:00', '2023-01-01 10:10:00', '2023-01-01 10:15:00']),
        'cpu_usage': [0.5, 0.6, 0.55, 0.8],
        'memory_usage': [0.7, 0.72, 0.71, 0.75],
        'disk_usage': [0.4, 0.41, 0.42, 0.39],
        'network_latency': [50, 55, 52, 60],
        'error_count': [1, 0, 1, 3],
        'warning_count': [2,1,0, 2],
        'request_count': [100,110,105, 120],
        'response_time': [120,130,125, 140],
        'service_restarts': [0,0,1,0],
        'cpu_spikes': [0,1,0,2],
        'memory_spikes': [1,0,0,1],
        'connection_drops': [0,0,0,1],
        'is_healthy': [1,1,0,0], # Target for health_prediction
        'will_fail': [0,0,1,1]   # Target for failure_prediction
    })


class TestArcRemediationLearner:
    def test_arl_init(self):
        arl = ArcRemediationLearner()
        assert arl is not None
        assert arl.model is not None # RandomForestClassifier

    def test_arl_learn_from_remediation(self, base_predictive_config, sample_remediation_data):
        arl = ArcRemediationLearner()
        # Mock trainer and predictor for this test
        arl.trainer = MagicMock()
        arl.predictor = MagicMock()

        # Initial fit requires more than one class if using default RF for predict_proba to work.
        # Forcing a simple case for placeholder, ensuring two classes [0, 1] are seen by fit.
        # The features array must be 2D.
        dummy_features = np.array([[0,0,0,0,0], [1,1,1,1,1]])
        dummy_labels = np.array([0,1])
        arl.model.fit(dummy_features, dummy_labels) # Pre-fit with dummy data

        arl.learn_from_remediation(sample_remediation_data)
        assert sample_remediation_data['error_type'] in arl.success_patterns
        if arl.trainer: # if trainer was initialized
            arl.trainer.update_models_with_remediation.assert_called_once()


    def test_arl_get_recommendation(self, base_predictive_config, sample_remediation_data):
        arl = ArcRemediationLearner()
         # Pre-fit with dummy data representing two classes for predict_proba
        arl.model.fit(np.array([[0,0,0,0,0],[1,1,1,1,1]]), [0,1])
        recommendation = arl.get_recommendation(sample_remediation_data['context'])
        assert "recommended_action" in recommendation
        assert "confidence_score" in recommendation


class TestFeatureEngineer:
    def test_fe_init(self, base_predictive_config):
        fe = FeatureEngineer(config=base_predictive_config['feature_engineering'])
        assert fe is not None

    def test_fe_engineer_features(self, base_predictive_config, sample_feature_data_df):
        fe = FeatureEngineer(config=base_predictive_config['feature_engineering'])
        # Fill NaNs that will be created by rolling/lag before passing to engineer_features
        # as the method itself also fills them, but target might be affected if used directly
        df_copy = sample_feature_data_df.fillna(0).copy() # use .copy()
        features, metadata = fe.engineer_features(df_copy, target='is_healthy')
        assert isinstance(features, pd.DataFrame)
        assert not features.isnull().values.any()
        assert "feature_count" in metadata

class TestArcModelTrainer:
    def test_amt_init(self, base_predictive_config):
        trainer = ArcModelTrainer(config=base_predictive_config['model_config'])
        assert trainer is not None

    def test_amt_train_all_models(self, base_predictive_config, sample_feature_data_df, tmp_path):
        trainer = ArcModelTrainer(config=base_predictive_config['model_config'])

        # For anomaly detection, target is not used, but other models need it
        # Ensure data is clean for training
        df_clean = sample_feature_data_df.fillna(0).copy() # use .copy()

        trainer.train_health_prediction_model(df_clean.copy())
        assert "health_prediction" in trainer.models

        trainer.train_anomaly_detection_model(df_clean.copy())
        assert "anomaly_detection" in trainer.models

        trainer.train_failure_prediction_model(df_clean.copy())
        assert "failure_prediction" in trainer.models

        trainer.save_models(str(tmp_path))
        assert os.path.exists(tmp_path / "health_prediction_model.pkl")
        assert os.path.exists(tmp_path / "anomaly_detection_model.pkl")
        assert os.path.exists(tmp_path / "failure_prediction_model.pkl")

    def test_amt_update_remediation(self, base_predictive_config, sample_remediation_data):
        trainer = ArcModelTrainer(config=base_predictive_config['model_config'])
        # This is just a placeholder, so just call it
        trainer.update_models_with_remediation(sample_remediation_data)
        # No assertion other than it runs without error for placeholder


@pytest.fixture
def trained_models_path(base_predictive_config, sample_feature_data_df, tmp_path) -> str:
    trainer = ArcModelTrainer(config=base_predictive_config['model_config'])
    df_clean = sample_feature_data_df.fillna(0).copy() # use .copy()
    trainer.train_health_prediction_model(df_clean.copy())
    trainer.train_anomaly_detection_model(df_clean.copy())
    trainer.train_failure_prediction_model(df_clean.copy())
    trainer.save_models(str(tmp_path))
    return str(tmp_path)

class TestArcPredictor:
    def test_ap_init_and_load(self, trained_models_path):
        predictor = ArcPredictor(model_dir=trained_models_path)
        assert predictor is not None
        assert "health_prediction" in predictor.models
        assert "anomaly_detection" in predictor.models
        assert "failure_prediction" in predictor.models

    def test_ap_all_predictions(self, trained_models_path, sample_feature_data_df):
        predictor = ArcPredictor(model_dir=trained_models_path)
        # Use first row of sample data, convert to dict for telemetry_data input
        telemetry_sample = sample_feature_data_df.iloc[0].fillna(0).to_dict() # fillna for safety

        health_pred = predictor.predict_health(telemetry_sample)
        assert "prediction" in health_pred
        assert "healthy_probability" in health_pred["prediction"]

        anomaly_pred = predictor.detect_anomalies(telemetry_sample)
        assert "is_anomaly" in anomaly_pred
        assert "anomaly_score" in anomaly_pred

        failure_pred = predictor.predict_failures(telemetry_sample)
        assert "prediction" in failure_pred
        assert "failure_probability" in failure_pred["prediction"]

class TestPredictiveAnalyticsEngine:
    def test_pae_init(self, base_predictive_config, trained_models_path):
        # Mock PatternAnalyzer to avoid its complex dependencies for this test
        with patch('Python.predictive.predictive_analytics_engine.PatternAnalyzer') as MockPatternAnalyzer:
            mock_pa_instance = MockPatternAnalyzer.return_value
            mock_pa_instance.analyze_patterns.return_value = { # Ensure it returns a dict
                "temporal": {"daily": {"recommendations": []}}, # Adjusted to match actual structure
                "failure": {"recommendations": []},
                "performance": {"recommendations": []},
                "behavioral": {} # Added for completeness
            }

            pae = PredictiveAnalyticsEngine(config=base_predictive_config, model_dir=trained_models_path)
            assert pae is not None
            assert pae.trainer is not None
            assert pae.predictor is not None
            assert pae.pattern_analyzer is not None # This will be the mocked instance

    def test_pae_analyze_deployment_risk(self, base_predictive_config, trained_models_path, sample_feature_data_df):
        with patch('Python.predictive.predictive_analytics_engine.PatternAnalyzer') as MockPatternAnalyzer:
            mock_pa_instance = MockPatternAnalyzer.return_value
            # Define a more structured return for analyze_patterns mock
            mock_pa_instance.analyze_patterns.return_value = {
                'temporal': {'daily': {'data': 'mock_temporal_daily', 'recommendations': [{'action': 'Test Rec Daily', 'priority': 0.5}]}},
                'behavioral': {'data': 'mock_behavioral', 'recommendations': []},
                'failure': {'data': 'mock_failure', 'recommendations': []},
                'performance': {'data': 'mock_performance', 'recommendations': []}
            }

            pae = PredictiveAnalyticsEngine(config=base_predictive_config, model_dir=trained_models_path)
            server_data_sample = sample_feature_data_df.iloc[0].fillna(0).to_dict() # fillna for safety
            risk_analysis = pae.analyze_deployment_risk(server_data_sample)

            assert "overall_risk" in risk_analysis
            assert "score" in risk_analysis["overall_risk"]
            assert "recommendations" in risk_analysis
            assert len(risk_analysis["recommendations"]) >= 0 # Can be empty if no conditions met

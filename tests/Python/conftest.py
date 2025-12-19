import pytest
import pandas as pd
import numpy as np
from datetime import datetime, timedelta
import os
import json
from typing import Dict, Any # Added for full_ai_config_dict
import sys

# Ensure tests can import from the repo's src/ directory (e.g., `from Python...`).
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../../src')))

@pytest.fixture
def sample_telemetry_data():
    """Generate sample telemetry data for testing."""
    now = datetime.now()
    data = []
    
    for i in range(100):
        timestamp = now - timedelta(minutes=i)
        data.append({
            'timestamp': timestamp.isoformat(),
            'cpu_usage': np.random.uniform(20, 90),
            'memory_usage': np.random.uniform(30, 85),
            'disk_usage': np.random.uniform(40, 75),
            'network_latency': np.random.uniform(5, 100),
            'error_count': np.random.randint(0, 5),
            'warning_count': np.random.randint(0, 10),
            'connection_status': np.random.choice(['Connected', 'Disconnected']),
            'service_status': np.random.choice(['Running', 'Stopped', 'Degraded'])
        })
    
    return pd.DataFrame(data)

@pytest.fixture
def sample_config(): # This fixture is used by test_model_trainer.py
    """Provide sample configuration for testing ArcModelTrainer."""
    # This config should align with what ArcModelTrainer's __init__ expects for its self.config,
    # which is typically the 'model_config' section of a larger configuration.
    return {
        'test_split_ratio': 0.2, # Added for completeness, used by trainer methods
        'random_state': 42,    # Added for completeness
        'features': {
            'health_prediction': {
                'required_features': ['cpu_usage', 'memory_usage', 'error_count', 'network_latency', 'disk_usage'], # Example features
                'target_column': 'health_status',
                'missing_strategy': 'mean'
            },
            'failure_prediction': {
                'required_features': ['cpu_usage', 'memory_usage', 'error_count', 'service_restarts', 'warning_count'], # Example features
                'target_column': 'failure_status',
                'missing_strategy': 'mean'
            },
            'anomaly_detection': {
                # For anomaly detection, often all available numeric features from FeatureEngineer are used,
                # or a specific subset. Let's list some common ones.
                'required_features': ['cpu_usage', 'memory_usage', 'disk_usage', 'network_latency', 'error_count', 'warning_count', 'request_count', 'response_time'],
                'missing_strategy': 'mean'
                # No target_column for unsupervised anomaly detection
            }
        },
        'models': { # Model hyperparameters
            'health_prediction': {
                'algorithm': 'RandomForestClassifier',
                'random_forest_params': {'n_estimators': 10, 'max_depth': 3, 'random_state': 42, 'class_weight': 'balanced'}
            },
            'anomaly_detection': {
                'contamination': 0.1, # IsolationForest param
                'random_state': 42,   # IsolationForest param
                'n_estimators': 50    # IsolationForest param
            },
            'failure_prediction': {
                'algorithm': 'RandomForestClassifier', # Example
                'random_forest_params': {'n_estimators': 10, 'max_depth': 3, 'random_state': 42, 'class_weight': 'balanced'}
            }
        }
        # 'thresholds' key from original sample_config is not used by ArcModelTrainer directly, so omitted here.
        # 'derived_features' and 'temporal_features' from original 'features' key are part of FeatureEngineer config,
        # not ArcModelTrainer's direct config.
    }

@pytest.fixture
def sample_model_artifacts(tmp_path):
    """Create sample model artifacts for testing."""
    artifacts_dir = tmp_path / "models"
    artifacts_dir.mkdir()
    
    # Create dummy model files
    model_files = [
        'health_prediction_model.pkl',
        'anomaly_detection_model.pkl',
        'failure_prediction_model.pkl'
    ]
    
    for file in model_files:
        with open(artifacts_dir / file, 'w') as f:
            f.write('dummy model data')
    
    return artifacts_dir

@pytest.fixture
def sample_training_data():
    """Generate sample training data for model training."""
    np.random.seed(42)
    n_samples = 1000
    
    data = pd.DataFrame({
        'cpu_usage': np.random.uniform(20, 90, n_samples),
        'memory_usage': np.random.uniform(30, 85, n_samples),
        'disk_usage': np.random.uniform(40, 75, n_samples),
        'error_count': np.random.randint(0, 5, n_samples),
        'warning_count': np.random.randint(0, 10, n_samples),
        'network_latency': np.random.uniform(5, 100, n_samples)
    })
    
    # Generate target variables
    data['health_status'] = (data['cpu_usage'] < 80) & (data['memory_usage'] < 80)
    data['failure_status'] = (data['error_count'] > 3) | (data['cpu_usage'] > 85)
    
    return data

@pytest.fixture
def mock_azure_client():
    """Mock Azure client for testing."""
    class MockAzureClient:
        def __init__(self):
            self.calls = []
        
        def get_metrics(self, *args, **kwargs):
            self.calls.append(('get_metrics', args, kwargs))
            return pd.DataFrame({
                'timestamp': pd.date_range(start='2024-01-01', periods=24, freq='H'),
                'value': np.random.uniform(0, 100, 24)
            })
        
        def update_status(self, *args, **kwargs):
            self.calls.append(('update_status', args, kwargs))
            return True
    
    return MockAzureClient()

# Comprehensive Configuration Fixture (Moved from test_python_ai_engine_integration.py)
@pytest.fixture(scope="module")
def full_ai_config_dict() -> Dict[str, Any]:
    config = {
        "aiComponents": {
            "telemetry_processor": {
                "anomaly_detection_features": ["cpu_usage_avg", "memory_usage_avg", "error_count_sum"],
                "trend_features": ["cpu_usage_avg", "response_time_avg"],
                "fft_features": ["cpu_usage_avg"],
                "correlation_features": ["cpu_usage_avg", "memory_usage_avg", "disk_io_avg"],
                "correlation_threshold": 0.8,
                "trend_p_value_threshold": 0.05,
                "trend_slope_threshold": 0.01, # Adjusted for more sensitivity in tests
                "fft_num_top_frequencies": 1,
                "fft_min_amplitude_threshold": 0.1,
                "multi_metric_anomaly_rules": [{
                    "name": "HighCpuAndError",
                    "conditions": [
                        {"metric": "cpu_usage_avg", "operator": ">", "threshold": 80.0}, # Use float for thresholds
                        {"metric": "error_count_sum", "operator": ">", "threshold": 5.0}
                    ],
                     "description": "High CPU usage concurrent with high error count.",
                     "severity": "high"
                }]
            },
            "pattern_analyzer_config": { # Used by RootCauseAnalyzer and PAE for their PatternAnalyzer
                "behavioral_features": ["cpu_usage_avg", "memory_usage_avg", "error_count_sum"],
                "dbscan_eps": 0.5, "dbscan_min_samples": 2, # Adjusted for small test data
                "performance_metrics": ["cpu_usage_avg", "response_time_avg"],
                "precursor_window": "30T", # Shorter window for test data
                "precursor_significance_threshold_pct": 10,
                "sustained_high_usage_percentile": 0.8, # Adjusted
                "sustained_high_usage_min_points": 2, # Adjusted
                 "bottleneck_rules": [{
                    "name": "CPU_Bottleneck_Test",
                    "conditions": [{"metric": "cpu_usage_avg", "operator": ">", "threshold": 90.0}],
                    "description": "CPU usage exceeds 90%",
                    "severity": "high"
                }]
            },
            "rca_estimator_config": {
                 "rules": { # Simplified rules for testing
                    "cpu": {"cause": "CPU Overload Test", "recommendation": "Test Rec: Scale CPU.", "impact_score": 0.7, "metric_threshold": 0.75}, # Matched against cpu_usage_avg typically
                    "memory": {"cause": "Memory Exhaustion Test", "recommendation": "Test Rec: Add Memory.", "impact_score": 0.8, "metric_threshold": 0.85},
                    "network error": {"cause": "Network Error Test", "recommendation": "Test Rec: Check Network.", "impact_score": 0.9} # Keyword based
                },
                "default_confidence": 0.6
            },
            "rca_explainer_config": {},
            "feature_engineering": {
                "original_numerical_features": ["cpu_usage_avg", "memory_usage_avg", "disk_io_avg", "error_count_sum", "response_time_avg",
                                                "cpu_usage", "memory_usage", "disk_usage", "network_latency", "error_count", "warning_count",
                                                "request_count", "response_time", "service_restarts", "cpu_spikes", "memory_spikes", "connection_drops"], # Expanded
                "original_categorical_features": ["region"],
                "statistical_feature_columns": ["cpu_usage_avg", "memory_usage_avg"],
                "rolling_window_sizes": [2], "lags": [1], # Adjusted for small data
                "interaction_feature_columns": ["cpu_usage_avg", "memory_usage_avg"],
                "numerical_nan_fill_strategy": "mean",
                "categorical_nan_fill_strategy": "unknown",
                "feature_selection_k": 'all',
                "feature_selection_score_func": "f_classif" # Though target might not always be classification type for all models
            },
            "model_config": { # For ArcModelTrainer
                "test_split_ratio": 0.25, "random_state": 42,
                "features": { # ArcModelTrainer will use these to select columns from FeatureEngineer's output
                    "health_prediction": {"required_features_is_output_of_fe": True, "target_column": "is_healthy", "missing_strategy": "mean"},
                    "anomaly_detection": {"required_features_is_output_of_fe": True, "missing_strategy": "mean"}, # No target_column
                    "failure_prediction": {"required_features_is_output_of_fe": True, "target_column": "will_fail", "missing_strategy": "mean"}
                },
                "models": { # Params for scikit-learn models
                    "health_prediction": {"n_estimators": 10, "max_depth": 3, "random_state": 42, "class_weight": "balanced"},
                    "anomaly_detection": {"contamination": 'auto', "random_state": 42, "n_estimators":10}, # Reduced n_estimators
                    "failure_prediction": {"n_estimators": 10, "max_depth": 3, "random_state": 42, "class_weight": "balanced"}
                }
            },
             "remediation_learner_config": {
                 "context_features_to_log": ["cpu_usage_avg", "error_count_sum"],
                 "success_pattern_threshold": 0.7, "success_pattern_min_attempts": 2,
                 "ai_predictor_failure_threshold": 0.6,
                 "retraining_data_threshold": 3
            }
        }
    }
    return config

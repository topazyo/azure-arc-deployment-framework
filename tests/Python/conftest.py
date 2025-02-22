import pytest
import pandas as pd
import numpy as np
from datetime import datetime, timedelta
import os
import json

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
def sample_config():
    """Provide sample configuration for testing."""
    return {
        'features': {
            'required_features': [
                'cpu_usage',
                'memory_usage',
                'error_count'
            ],
            'derived_features': [
                'resource_pressure',
                'error_rate'
            ],
            'temporal_features': True,
            'missing_strategy': 'mean'
        },
        'models': {
            'health_prediction': {
                'n_estimators': 100,
                'max_depth': 10,
                'threshold': 0.7
            },
            'anomaly_detection': {
                'contamination': 0.1,
                'random_state': 42
            },
            'failure_prediction': {
                'n_estimators': 100,
                'max_depth': 10,
                'class_weight': 'balanced'
            }
        },
        'thresholds': {
            'cpu_critical': 90,
            'memory_critical': 85,
            'error_critical': 5
        }
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
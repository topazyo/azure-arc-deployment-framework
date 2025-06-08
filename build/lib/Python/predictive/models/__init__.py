"""
Machine Learning Models
Provides specialized models for Arc deployment scenarios
"""

from .health_model import HealthPredictionModel
from .failure_model import FailurePredictionModel
from .anomaly_model import AnomalyDetectionModel

__all__ = [
    'HealthPredictionModel',
    'FailurePredictionModel',
    'AnomalyDetectionModel'
]

# Model registry
MODEL_REGISTRY = {
    'health_prediction': HealthPredictionModel,
    'failure_prediction': FailurePredictionModel,
    'anomaly_detection': AnomalyDetectionModel
}

# Model configurations
MODEL_CONFIGS = {
    'health_prediction': {
        'type': 'classification',
        'metrics': ['accuracy', 'precision', 'recall', 'f1'],
        'threshold': 0.7
    },
    'failure_prediction': {
        'type': 'classification',
        'metrics': ['accuracy', 'precision', 'recall', 'f1'],
        'threshold': 0.6
    },
    'anomaly_detection': {
        'type': 'detection',
        'contamination': 0.1,
        'metrics': ['precision', 'recall']
    }
}
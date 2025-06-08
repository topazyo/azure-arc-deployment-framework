"""
Predictive Analytics Components
Provides predictive modeling and analysis capabilities
"""

from .model_trainer import ArcModelTrainer
from .predictor import ArcPredictor
from .feature_engineering import FeatureEngineer
from .ArcRemediationLearner import ArcRemediationLearner
from .predictive_analytics_engine import PredictiveAnalyticsEngine

__all__ = [
    'ArcModelTrainer',
    'ArcPredictor',
    'FeatureEngineer',
    'ArcRemediationLearner',
    'PredictiveAnalyticsEngine'
]

# Component configuration
DEFAULT_CONFIG = {
    'model_params': {
        'n_estimators': 100,
        'max_depth': 10,
        'random_state': 42
    },
    'feature_engineering': {
        'rolling_window': 5,
        'lags': [1, 3, 5],
        'enable_interactions': True
    },
    'prediction': {
        'threshold': 0.7,
        'confidence_required': 0.8
    }
}
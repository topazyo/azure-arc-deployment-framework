"""
Predictive Utilities
Provides helper functions for predictive modeling
"""

from .model_evaluation import evaluate_model
from .data_preparation import prepare_training_data
from .feature_selection import select_features
from .model_persistence import save_model, load_model

__all__ = [
    'evaluate_model',
    'prepare_training_data',
    'select_features',
    'save_model',
    'load_model'
]

# Utility configurations
UTIL_CONFIG = {
    'evaluation': {
        'cv_folds': 5,
        'scoring': ['accuracy', 'precision', 'recall', 'f1'],
        'test_size': 0.2
    },
    'data_preparation': {
        'scaling': 'standard',
        'encoding': 'onehot',
        'handle_missing': 'impute'
    },
    'feature_selection': {
        'method': 'selectkbest',
        'k': 'auto',
        'score_func': 'f_classif'
    },
    'model_persistence': {
        'format': 'joblib',
        'compress': 3,
        'include_metadata': True
    }
}
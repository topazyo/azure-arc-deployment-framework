"""
Analysis Utilities
Provides helper functions for data analysis
"""

from .preprocessing import preprocess_telemetry
from .feature_extraction import extract_features
from .pattern_matching import find_patterns
from .statistical_tests import run_statistical_tests

__all__ = [
    'preprocess_telemetry',
    'extract_features',
    'find_patterns',
    'run_statistical_tests'
]

# Utility configurations
UTIL_CONFIG = {
    'preprocessing': {
        'remove_outliers': True,
        'fill_missing': 'interpolate',
        'smoothing_window': 5
    },
    'feature_extraction': {
        'time_features': True,
        'statistical_features': True,
        'frequency_features': False
    },
    'pattern_matching': {
        'algorithm': 'dynamic_time_warping',
        'distance_threshold': 0.1
    },
    'statistical_tests': {
        'significance_level': 0.05,
        'test_normality': True
    }
}
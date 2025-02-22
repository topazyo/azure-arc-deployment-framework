"""
Analysis Components
Provides data analysis and pattern recognition capabilities
"""

from .pattern_analyzer import PatternAnalyzer
from .RootCauseAnalyzer import RootCauseAnalyzer
from .telemetry_processor import TelemetryProcessor

__all__ = [
    'PatternAnalyzer',
    'RootCauseAnalyzer',
    'TelemetryProcessor'
]

# Analysis configuration
ANALYSIS_CONFIG = {
    'pattern_recognition': {
        'min_pattern_length': 3,
        'max_pattern_length': 10,
        'significance_threshold': 0.05
    },
    'root_cause': {
        'max_depth': 5,
        'min_confidence': 0.7,
        'enable_explanation': True
    },
    'telemetry': {
        'sampling_rate': '1min',
        'window_size': '1h',
        'anomaly_threshold': 3
    }
}
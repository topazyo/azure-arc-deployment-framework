"""
Common Utilities
Provides shared functionality across components
"""

from .logging import setup_logging
from .validation import validate_input
from .error_handling import handle_error
from .configuration import load_config, save_config

__all__ = [
    'setup_logging',
    'validate_input',
    'handle_error',
    'load_config',
    'save_config'
]

# Common configurations
COMMON_CONFIG = {
    'logging': {
        'level': 'INFO',
        'format': '%(asctime)s - %(name)s - %(levelname)s - %(message)s',
        'file_rotation': '1 day',
        'max_size': '10MB'
    },
    'validation': {
        'strict_mode': True,
        'raise_exceptions': True
    },
    'error_handling': {
        'max_retries': 3,
        'retry_delay': 5,
        'log_traceback': True
    },
    'configuration': {
        'config_path': './config',
        'environment_aware': True
    }
}
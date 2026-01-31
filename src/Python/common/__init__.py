"""
Common Utilities
Provides shared functionality across components
"""

from .logging_config import configure_logging, get_logger, set_log_level

# Backwards compatibility alias
setup_logging = configure_logging

__all__ = [
    'configure_logging',
    'get_logger',
    'set_log_level',
    'setup_logging',  # backwards compatibility
]

# Common configurations
COMMON_CONFIG = {
    'logging': {
        'level': 'INFO',
        'format': '%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    },
}

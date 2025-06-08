"""
Azure Arc Deployment Framework - Python Components
Provides AI/ML capabilities for Arc deployment and monitoring
"""

from . import predictive
from . import analysis

__version__ = '1.0.0'
__author__ = 'Your Name'
__email__ = 'your.email@example.com'

# Version info
VERSION_INFO = {
    'major': 1,
    'minor': 0,
    'patch': 0,
    'status': 'stable'
}

# Package metadata
PACKAGE_INFO = {
    'name': 'arc_deployment_framework',
    'description': 'AI/ML components for Azure Arc deployment and monitoring',
    'requires': [
        'numpy>=1.19.0',
        'pandas>=1.2.0',
        'scikit-learn>=0.24.0',
        'scipy>=1.6.0'
    ]
}
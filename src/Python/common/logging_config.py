"""
Centralized Logging Configuration for Azure Arc Predictive Toolkit

This module provides a single point of configuration for all logging
across the Python components. Call configure_logging() once at application
startup, or let individual modules use get_logger() which auto-configures.
"""

import logging
import sys
from typing import Optional

# Track if logging has been configured
_logging_configured = False

# Default logging configuration
DEFAULT_FORMAT = '%(asctime)s - %(name)s - %(levelname)s - %(message)s'
DEFAULT_LEVEL = logging.INFO


def configure_logging(
    level: int = DEFAULT_LEVEL,
    format_string: str = DEFAULT_FORMAT,
    log_file: Optional[str] = None,
    force: bool = False
) -> None:
    """
    Configure logging for the entire application.

    Should be called once at application startup. Subsequent calls are
    no-ops unless force=True.

    Args:
        level: Logging level (e.g., logging.INFO, logging.DEBUG)
        format_string: Format string for log messages
        log_file: Optional file path to also write logs to
        force: If True, reconfigure even if already configured
    """
    global _logging_configured

    if _logging_configured and not force:
        return

    handlers = [logging.StreamHandler(sys.stderr)]

    if log_file:
        handlers.append(logging.FileHandler(log_file))

    logging.basicConfig(
        level=level,
        format=format_string,
        handlers=handlers,
        force=force
    )

    _logging_configured = True


def get_logger(name: str) -> logging.Logger:
    """
    Get a named logger, ensuring logging is configured.

    This is the preferred way to get a logger in this codebase.
    It ensures basicConfig has been called before returning a logger.

    Args:
        name: Logger name (typically __name__ or class name)

    Returns:
        Configured logger instance
    """
    # Auto-configure if not already done
    if not _logging_configured:
        configure_logging()

    return logging.getLogger(name)


def set_log_level(level: int, logger_name: Optional[str] = None) -> None:
    """
    Set the log level for a specific logger or the root logger.

    Args:
        level: Logging level to set
        logger_name: Specific logger name, or None for root
    """
    if logger_name:
        logging.getLogger(logger_name).setLevel(level)
    else:
        logging.getLogger().setLevel(level)


# Module-level logger for this module
logger = get_logger(__name__)

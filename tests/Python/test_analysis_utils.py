"""
Tests for the analysis utilities module.
"""
import pytest
import pandas as pd
import numpy as np
from datetime import datetime, timedelta

# Import the utilities to test
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..', '..', 'src'))

from Python.analysis.utils import (
    preprocess_telemetry,
    extract_features,
    find_patterns,
    run_statistical_tests,
    UTIL_CONFIG
)


class TestPreprocessTelemetry:
    """Tests for the preprocess_telemetry function."""

    def test_empty_dataframe(self):
        """Test handling of empty DataFrame."""
        df = pd.DataFrame()
        result = preprocess_telemetry(df)
        assert result.empty

    def test_none_input(self):
        """Test handling of None input."""
        result = preprocess_telemetry(None)
        assert result.empty

    def test_fill_missing_interpolate(self):
        """Test interpolation for missing values."""
        df = pd.DataFrame({
            'cpu': [10.0, np.nan, 30.0, 40.0],
            'memory': [50.0, 60.0, np.nan, 80.0]
        })
        result = preprocess_telemetry(df, fill_missing='interpolate', remove_outliers=False, smoothing_window=1)
        assert not result.isnull().any().any()

    def test_fill_missing_mean(self):
        """Test mean fill for missing values."""
        df = pd.DataFrame({
            'cpu': [10.0, np.nan, 30.0, 40.0]
        })
        result = preprocess_telemetry(df, fill_missing='mean', remove_outliers=False, smoothing_window=1)
        # Mean of [10, 30, 40] = 26.67
        assert not result.isnull().any().any()

    def test_outlier_removal(self):
        """Test outlier removal using IQR method."""
        df = pd.DataFrame({
            'value': [10, 20, 30, 40, 50, 1000]  # 1000 is an outlier
        })
        result = preprocess_telemetry(df, remove_outliers=True, fill_missing='drop', smoothing_window=1)
        # Outlier should be clipped
        assert result['value'].max() < 1000

    def test_smoothing(self):
        """Test rolling window smoothing."""
        df = pd.DataFrame({
            'value': [10.0, 20.0, 30.0, 40.0, 50.0]
        })
        result = preprocess_telemetry(df, smoothing_window=3, remove_outliers=False, fill_missing='drop')
        # With window=3 and center=True, values should be smoothed
        assert len(result) == 5


class TestExtractFeatures:
    """Tests for the extract_features function."""

    def test_empty_dataframe(self):
        """Test handling of empty DataFrame."""
        df = pd.DataFrame()
        result = extract_features(df)
        assert result == {}

    def test_none_input(self):
        """Test handling of None input."""
        result = extract_features(None)
        assert result == {}

    def test_statistical_features(self):
        """Test extraction of statistical features."""
        df = pd.DataFrame({
            'cpu': [10.0, 20.0, 30.0, 40.0, 50.0],
            'memory': [60.0, 70.0, 80.0, 90.0, 100.0]
        })
        result = extract_features(df, include_statistical_features=True, include_time_features=False)
        
        assert 'statistical_features' in result
        assert 'cpu' in result['statistical_features']
        assert 'mean' in result['statistical_features']['cpu']
        assert result['statistical_features']['cpu']['mean'] == 30.0

    def test_time_features(self):
        """Test extraction of time-based features."""
        base_time = datetime(2024, 1, 1, 10, 0, 0)
        df = pd.DataFrame({
            'timestamp': [base_time + timedelta(hours=i) for i in range(24)],
            'value': range(24)
        })
        result = extract_features(df, include_time_features=True, include_statistical_features=False)
        
        assert 'time_features' in result
        assert 'hour_distribution' in result['time_features']


class TestFindPatterns:
    """Tests for the find_patterns function."""

    def test_empty_dataframe(self):
        """Test handling of empty DataFrame."""
        df = pd.DataFrame()
        result = find_patterns(df)
        assert result == []

    def test_none_input(self):
        """Test handling of None input."""
        result = find_patterns(None)
        assert result == []

    def test_correlation_pattern(self):
        """Test detection of correlation patterns."""
        df = pd.DataFrame({
            'cpu': [10.0, 20.0, 30.0, 40.0, 50.0],
            'memory': [15.0, 25.0, 35.0, 45.0, 55.0]  # Highly correlated with cpu
        })
        result = find_patterns(df, algorithm='correlation', distance_threshold=0.1)
        
        # Should detect correlation between cpu and memory
        correlation_patterns = [p for p in result if p['type'] == 'correlation']
        assert len(correlation_patterns) > 0

    def test_change_point_detection(self):
        """Test detection of change points."""
        # Create data with a clear change point
        df = pd.DataFrame({
            'value': [10.0] * 10 + [100.0] * 10  # Big jump at index 10
        })
        result = find_patterns(df, algorithm='clustering')
        
        change_patterns = [p for p in result if p['type'] == 'change_points']
        assert len(change_patterns) > 0


class TestRunStatisticalTests:
    """Tests for the run_statistical_tests function."""

    def test_empty_dataframe(self):
        """Test handling of empty DataFrame."""
        df = pd.DataFrame()
        result = run_statistical_tests(df)
        assert 'normality_tests' in result
        assert result['normality_tests'] == {}

    def test_none_input(self):
        """Test handling of None input."""
        result = run_statistical_tests(None)
        assert 'normality_tests' in result

    def test_normality_test(self):
        """Test normality testing."""
        # Create normally distributed data
        np.random.seed(42)
        df = pd.DataFrame({
            'normal_data': np.random.normal(50, 10, 100)
        })
        result = run_statistical_tests(df, test_normality=True)
        
        assert 'normality_tests' in result
        assert 'normal_data' in result['normality_tests']
        assert 'p_value' in result['normality_tests']['normal_data']

    def test_trend_test(self):
        """Test trend detection."""
        # Create data with a clear upward trend
        df = pd.DataFrame({
            'trending': [float(i) + np.random.normal(0, 0.1) for i in range(50)]
        })
        result = run_statistical_tests(df)
        
        assert 'trend_tests' in result
        assert 'trending' in result['trend_tests']
        assert result['trend_tests']['trending']['has_trend'] == True
        assert result['trend_tests']['trending']['trend_direction'] == 'increasing'


class TestUtilConfig:
    """Tests for the utility configuration constants."""

    def test_config_structure(self):
        """Test that UTIL_CONFIG has expected structure."""
        assert 'preprocessing' in UTIL_CONFIG
        assert 'feature_extraction' in UTIL_CONFIG
        assert 'pattern_matching' in UTIL_CONFIG
        assert 'statistical_tests' in UTIL_CONFIG

    def test_preprocessing_config(self):
        """Test preprocessing configuration values."""
        assert 'remove_outliers' in UTIL_CONFIG['preprocessing']
        assert 'fill_missing' in UTIL_CONFIG['preprocessing']
        assert 'smoothing_window' in UTIL_CONFIG['preprocessing']

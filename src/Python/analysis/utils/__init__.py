"""
Analysis Utilities
Provides helper functions for data analysis
"""

from typing import Dict, List, Any
import pandas as pd
import numpy as np
from scipy import stats


def preprocess_telemetry(
    data: pd.DataFrame,
    remove_outliers: bool = True,
    fill_missing: str = 'interpolate',
    smoothing_window: int = 5
) -> pd.DataFrame:
    """
    Preprocess telemetry data for analysis.

    Args:
        data: Raw telemetry DataFrame
        remove_outliers: Whether to remove outlier values
        fill_missing: Strategy for handling missing values
                      ('interpolate', 'mean', 'median', 'drop')
        smoothing_window: Window size for smoothing operations

    Returns:
        Preprocessed DataFrame
    """
    if data is None or data.empty:
        return pd.DataFrame()

    df = data.copy()

    # Handle missing values
    if fill_missing == 'interpolate':
        df = df.interpolate(method='linear', limit_direction='both')
    elif fill_missing == 'mean':
        df = df.fillna(df.mean(numeric_only=True))
    elif fill_missing == 'median':
        df = df.fillna(df.median(numeric_only=True))
    elif fill_missing == 'drop':
        df = df.dropna()

    # Remove outliers using IQR method
    if remove_outliers:
        numeric_cols = df.select_dtypes(include=[np.number]).columns
        for col in numeric_cols:
            Q1 = df[col].quantile(0.25)
            Q3 = df[col].quantile(0.75)
            IQR = Q3 - Q1
            lower_bound = Q1 - 1.5 * IQR
            upper_bound = Q3 + 1.5 * IQR
            df[col] = df[col].clip(lower=lower_bound, upper=upper_bound)

    # Apply smoothing if window > 1
    if smoothing_window > 1:
        numeric_cols = df.select_dtypes(include=[np.number]).columns
        for col in numeric_cols:
            df[col] = df[col].rolling(
                window=smoothing_window, min_periods=1, center=True
            ).mean()

    return df


def extract_features(
    data: pd.DataFrame,
    include_time_features: bool = True,
    include_statistical_features: bool = True,
    include_frequency_features: bool = False
) -> Dict[str, Any]:
    """
    Extract features from telemetry data.

    Args:
        data: Preprocessed telemetry DataFrame
        include_time_features: Whether to extract time-based features
        include_statistical_features: Whether to extract statistical
                                      features
        include_frequency_features: Whether to extract frequency-domain
                                    features

    Returns:
        Dictionary of extracted features
    """
    features: Dict[str, Any] = {}

    if data is None or data.empty:
        return features

    numeric_cols = data.select_dtypes(include=[np.number]).columns.tolist()

    # Time-based features
    if include_time_features and 'timestamp' in data.columns:
        try:
            timestamps = pd.to_datetime(data['timestamp'])
            features['time_features'] = {
                'hour_distribution': (
                    timestamps.dt.hour.value_counts().to_dict()
                ),
                'day_of_week_distribution': (
                    timestamps.dt.dayofweek.value_counts().to_dict()
                ),
                'time_span_hours': (
                    (timestamps.max() - timestamps.min()).total_seconds()
                    / 3600
                )
            }
        except Exception:
            features['time_features'] = {}

    # Statistical features
    if include_statistical_features:
        stats_features: Dict[str, Dict[str, float]] = {}
        for col in numeric_cols:
            col_data = data[col].dropna()
            if len(col_data) > 0:
                stats_features[col] = {
                    'mean': float(col_data.mean()),
                    'std': float(col_data.std()) if len(col_data) > 1 else 0.0,
                    'min': float(col_data.min()),
                    'max': float(col_data.max()),
                    'median': float(col_data.median()),
                    'skewness': (
                        float(stats.skew(col_data))
                        if len(col_data) > 2 else 0.0
                    ),
                    'kurtosis': (
                        float(stats.kurtosis(col_data))
                        if len(col_data) > 3 else 0.0
                    )
                }
        features['statistical_features'] = stats_features

    # Frequency-domain features (FFT)
    if include_frequency_features:
        freq_features: Dict[str, Dict[str, Any]] = {}
        for col in numeric_cols:
            col_data = np.asarray(data[col].dropna().values)
            if len(col_data) > 10:
                try:
                    fft_vals = np.fft.fft(col_data)
                    freqs = np.fft.fftfreq(len(col_data))
                    magnitudes = np.abs(fft_vals)

                    # Get top 3 dominant frequencies
                    top_indices = (
                        np.argsort(magnitudes[1:len(magnitudes) // 2])[-3:]
                        [::-1] + 1
                    )
                    freq_features[col] = {
                        'dominant_frequencies': (
                            [float(freqs[i]) for i in top_indices]
                        ),
                        'dominant_magnitudes': (
                            [float(magnitudes[i]) for i in top_indices]
                        )
                    }
                except Exception:
                    freq_features[col] = {}
        features['frequency_features'] = freq_features

    return features


def find_patterns(
    data: pd.DataFrame,
    algorithm: str = 'correlation',
    distance_threshold: float = 0.1,
    min_pattern_length: int = 3
) -> List[Dict[str, Any]]:
    """
    Find patterns in telemetry data.

    Args:
        data: Telemetry DataFrame
        algorithm: Pattern detection algorithm
                   ('correlation', 'clustering', 'dtw')
        distance_threshold: Threshold for pattern similarity
        min_pattern_length: Minimum length for a valid pattern

    Returns:
        List of detected patterns with metadata
    """
    patterns: List[Dict[str, Any]] = []

    if data is None or data.empty:
        return patterns

    numeric_cols = data.select_dtypes(include=[np.number]).columns.tolist()

    if algorithm == 'correlation':
        # Find correlated metric pairs
        if len(numeric_cols) >= 2:
            corr_matrix = data[numeric_cols].corr()
            for i, col1 in enumerate(numeric_cols):
                for j, col2 in enumerate(numeric_cols):
                    if i < j:
                        # Extract correlation value
                        corr_val = float(
                            corr_matrix.loc[col1, col2].item()
                        )
                        if abs(corr_val) > (1 - distance_threshold):
                            patterns.append({
                                'type': 'correlation',
                                'metrics': [col1, col2],
                                'correlation': corr_val,
                                'strength': (
                                    'strong'
                                    if abs(corr_val) > 0.8 else 'moderate'
                                )
                            })

    elif algorithm == 'clustering':
        # Simple change-point detection
        for col in numeric_cols:
            col_data = data[col].dropna().values
            if len(col_data) >= min_pattern_length * 2:
                # Detect significant changes
                diff = np.diff(col_data)
                std_diff = np.std(diff) if len(diff) > 1 else 1.0
                if std_diff > 0:
                    change_points = np.where(np.abs(diff) > 2 * std_diff)[0]
                    if len(change_points) > 0:
                        patterns.append({
                            'type': 'change_points',
                            'metric': col,
                            'change_indices': change_points.tolist(),
                            'count': len(change_points)
                        })


def run_statistical_tests(
    data: pd.DataFrame,
    significance_level: float = 0.05,
    test_normality: bool = True
) -> Dict[str, Any]:
    """
    Run statistical tests on telemetry data.

    Args:
        data: Telemetry DataFrame
        significance_level: P-value threshold for significance
        test_normality: Whether to test for normal distribution

    Returns:
        Dictionary of test results
    """
    results: Dict[str, Any] = {
        'normality_tests': {},
        'trend_tests': {},
        'stationarity_tests': {}
    }

    if data is None or data.empty:
        return results

    numeric_cols = data.select_dtypes(include=[np.number]).columns.tolist()

    for col in numeric_cols:
        col_data = data[col].dropna().values

        # Normality test (Shapiro-Wilk for small samples)
        if test_normality and len(col_data) >= 3:
            try:
                # Shapiro-Wilk limit
                sample_size = min(len(col_data), 5000)
                sample = (
                    np.random.choice(
                        col_data, sample_size, replace=False
                    )
                    if len(col_data) > sample_size else col_data
                )
                stat, p_value = stats.shapiro(sample)
                results['normality_tests'][col] = {
                    'statistic': float(stat),
                    'p_value': float(p_value),
                    'is_normal': p_value > significance_level
                }
            except Exception:
                results['normality_tests'][col] = {'error': 'Test failed'}

        # Trend test (Mann-Kendall proxy using linear regression)
        if len(col_data) >= 10:
            try:
                x = np.arange(len(col_data))
                (
                    slope, intercept, r_value, p_value, std_err
                ) = stats.linregress(x, col_data)
                results['trend_tests'][col] = {
                    'slope': float(slope),
                    'r_squared': float(r_value ** 2),
                    'p_value': float(p_value),
                    'has_trend': p_value < significance_level,
                    'trend_direction': (
                        'increasing' if slope > 0 else 'decreasing'
                    )
                }
            except Exception:
                results['trend_tests'][col] = {'error': 'Test failed'}

    return results


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
        'algorithm': 'correlation',
        'distance_threshold': 0.1
    },
    'statistical_tests': {
        'significance_level': 0.05,
        'test_normality': True
    }
}

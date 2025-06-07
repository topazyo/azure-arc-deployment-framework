import pytest
import pandas as pd
import numpy as np
from typing import Dict, Any, List # Added List
from unittest.mock import MagicMock # For mocking PatternAnalyzer in RCA tests

# Add src to path to allow direct import of modules
import sys
import os
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../../src')))

# Updated imports for RootCauseAnalyzer
from Python.analysis.RootCauseAnalyzer import RootCauseAnalyzer, SimpleRCAEstimator, SimpleRCAExplainer
from Python.analysis.pattern_analyzer import PatternAnalyzer
from Python.analysis.telemetry_processor import TelemetryProcessor

@pytest.fixture
def comprehensive_config() -> Dict[str, Any]:
    """A more comprehensive config for testing new features."""
    return {
        # TelemetryProcessor specific
        "anomaly_detection_features": ["cpu_usage_avg", "memory_usage_avg", "error_rate"], # For _prepare_feature_matrix
        "trend_features": ["cpu_usage_avg", "response_time_p95"], # For _calculate_period_trends
        "fft_features": ["cpu_usage_avg"], # For _detect_periodic_patterns
        "correlation_features": ["cpu_usage_avg", "memory_usage_avg", "error_count_sum"], # For _detect_correlations
        "correlation_threshold": 0.8,
        "multi_metric_anomaly_rules": [
            {
                "name": "HighCpuAndErrors",
                "conditions": [
                    {"metric": "cpu_usage_avg", "operator": ">", "threshold": 0.8},
                    {"metric": "error_rate", "operator": ">", "threshold": 0.1}
                ],
                "description": "High CPU usage concurrent with high error rate.",
                "severity": "high"
            }
        ],
        "trend_p_value_threshold": 0.05,
        "trend_slope_threshold": 0.1, # For determining 'increasing'/'decreasing'
        "fft_num_top_frequencies": 1,
        "fft_min_amplitude_threshold": 0.1,


        # PatternAnalyzer specific (can be nested under 'pattern_analyzer_config' if RCA passes it that way)
        "daily_peak_percentile_threshold": 0.75,
        "weekly_peak_percentile_threshold": 0.75,
        "precursor_window": "1H",
        "precursor_significance_threshold_pct": 10,
        "performance_metrics": ["cpu_usage", "memory_usage", "response_time_p95"], # For resource_usage, perf_trends
        "sustained_high_usage_percentile": 0.90,
        "sustained_high_usage_min_points": 3, # Adjusted for smaller test data
        "bottleneck_rules": [
             {
                "name": "HighCpuLowMemory",
                "conditions": [
                    {"metric": "cpu_usage", "operator": ">", "threshold": 0.8}, # Assuming metrics are 0-1 scale
                    {"metric": "memory_usage", "operator": "<", "threshold": 0.2} # Example, actual metrics matter
                ],
                "description": "CPU is high while available memory is low.",
                "severity": "critical"
            }
        ],
        "behavioral_features": ["cpu_usage", "memory_usage", "error_count"], # For DBSCAN
        "dbscan_eps": 0.5,
        "dbscan_min_samples": 2, # Adjusted for potentially small test data

        # RootCauseAnalyzer specific (can be nested)
        "rca_estimator_config": {
            "rules": {
                "cpu": {"cause": "Test CPU Overload", "recommendation": "Test Scale CPU.", "impact_score": 0.7, "metric_threshold": 0.75},
                "network error": {"cause": "Test Network Error", "recommendation": "Test Check network.", "impact_score": 0.9}
            },
            "default_confidence": 0.6
        },
        "rca_explainer_config": {}
    }

@pytest.fixture
def sample_incident_data_for_rca() -> Dict[str, Any]:
    return {
        "description": "Application experiencing high cpu usage and occasional network error reports.",
        "priority": "High",
        "metrics": { # Single point metrics snapshot
            "cpu_usage": 0.85, # Will trigger "cpu" rule
            "memory_usage": 0.5,
            "error_rate": 0.05,
            "disk_io": 0.3
        },
        "metrics_timeseries": [ # For pattern analysis part of RCA
            {'timestamp': '2023-01-01T10:00:00Z', 'cpu_usage': 0.8, 'memory_usage': 0.5, 'error_count': 1},
            {'timestamp': '2023-01-01T10:05:00Z', 'cpu_usage': 0.85, 'memory_usage': 0.52, 'error_count': 0},
            {'timestamp': '2023-01-01T10:10:00Z', 'cpu_usage': 0.9, 'memory_usage': 0.51, 'error_count': 2},
        ],
        "timestamp": "2023-01-01T10:10:00Z"
    }

@pytest.fixture
def telemetry_df_for_processor() -> pd.DataFrame:
    # More comprehensive DataFrame for TelemetryProcessor tests
    data = {
        'timestamp': pd.to_datetime(['2023-01-01 10:00:00', '2023-01-01 10:05:00', '2023-01-01 10:10:00',
                                     '2023-01-01 10:15:00', '2023-01-01 10:20:00']),
        'cpu_usage_avg': [0.5, 0.6, 0.9, 0.85, 0.7], # For anomaly_detection_features, trend_features, fft_features, correlation_features
        'memory_usage_avg': [0.7, 0.72, 0.71, 0.65, 0.8], # For anomaly_detection_features, correlation_features
        'error_rate': [0.01, 0.02, 0.15, 0.12, 0.03], # For anomaly_detection_features
        'error_count_sum': [1, 2, 15, 12, 3], # For correlation_features
        'response_time_p95': [120, 130, 250, 200, 140], # For trend_features
        'disk_usage': [None, 0.5, 0.55, None, 0.6], # Has NaNs
        'categorical_feat': ['A', 'B', None, 'A', 'C'], # Categorical with NaNs
        'bool_feat': [True, False, True, None, True] # Boolean with NaNs
    }
    return pd.DataFrame(data)

@pytest.fixture
def telemetry_df_for_pattern_analyzer() -> pd.DataFrame:
    # Tailored for PatternAnalyzer, e.g. for failure/precursor tests
    data = {
        'timestamp': pd.to_datetime([
            '2023-01-01 09:00:00', '2023-01-01 09:30:00', '2023-01-01 10:00:00', # Pre-failure1
            '2023-01-01 10:05:00', # Failure1
            '2023-01-02 13:00:00', '2023-01-02 13:30:00', '2023-01-02 14:00:00', # Pre-failure2
            '2023-01-02 14:05:00'  # Failure2
        ]),
        'cpu_usage': [0.5, 0.6, 0.85, 0.9,  0.4, 0.5, 0.75, 0.8],
        'memory_usage': [0.7, 0.72, 0.78, 0.8, 0.6, 0.65, 0.7, 0.72],
        'error_count': [1, 0, 2, 5,  0, 1, 1, 6],
        'response_time_p95': [100,110,180,200, 90,95,150,170],
        'failure_occurred': [0,0,0,1, 0,0,0,1],
        'error_type': ['TypeA', 'TypeB', 'TypeA', 'TypeC', 'TypeB', 'TypeA', 'TypeB', 'TypeC'],
        'downtime_minutes': [0,0,0,10, 0,0,0,20],
        'affected_services_count': [0,0,0,2, 0,0,0,3]
    }
    return pd.DataFrame(data)


class TestRootCauseAnalyzer:
    def test_rca_init(self, comprehensive_config):
        rca = RootCauseAnalyzer(config=comprehensive_config)
        assert rca is not None
        assert isinstance(rca.ml_model, SimpleRCAEstimator)
        assert isinstance(rca.explainer, SimpleRCAExplainer)
        assert isinstance(rca.pattern_analyzer, PatternAnalyzer)

    def test_rca_analyze_incident_with_rules(self, comprehensive_config, sample_incident_data_for_rca):
        # Mock PatternAnalyzer's analyze_patterns for this unit test
        # to avoid its full complexity and focus on RCA logic.
        mock_pa_instance = MagicMock(spec=PatternAnalyzer)
        mock_pa_instance.analyze_patterns.return_value = {
            'temporal': {'daily':{}, 'weekly':{}, 'monthly':{}, 'recommendations': []},
            'behavioral': {'clusters':{}, 'recommendations': []},
            'failure': {'common_causes':[], 'precursors':[], 'impact_analysis':{}, 'recommendations': []},
            'performance': {'resource_usage':{}, 'bottlenecks':{}, 'trends':{}, 'recommendations': []}
        }

        rca = RootCauseAnalyzer(config=comprehensive_config)
        rca.pattern_analyzer = mock_pa_instance # Inject the mock

        analysis_result = rca.analyze_incident(sample_incident_data_for_rca)

        assert "predicted_root_causes" in analysis_result
        assert len(analysis_result["predicted_root_causes"]) > 0

        # Check if SimpleRCAEstimator rules were triggered
        # Based on sample_incident_data_for_rca and comprehensive_config rules
        # "cpu" rule due to metrics.cpu_usage (0.85 > 0.75)
        # "network error" rule due to description
        expected_causes_found = {"Test CPU Overload", "Test Network Error"}
        found_causes_types = {cause['type'] for cause in analysis_result["predicted_root_causes"]}
        assert expected_causes_found.issubset(found_causes_types)

        primary_cause = analysis_result.get("primary_suspected_cause", {})
        # Network error has higher impact (0.9) than CPU (0.7)
        assert primary_cause.get("type") == "Test Network Error"

        assert "explanation" in analysis_result
        assert "primary_explanation" in analysis_result["explanation"]
        assert "Test Network Error" in analysis_result["explanation"]["primary_explanation"]
        assert len(analysis_result["explanation"]["factor_explanations"]) == len(found_causes_types)

        assert "actionable_recommendations" in analysis_result
        # Check if recommendations from triggered rules are present
        rca_recs_actions = [rec['action'] for rec in analysis_result["actionable_recommendations"] if rec['source'] == 'RootCauseEstimator']
        assert "Test Scale CPU." in rca_recs_actions
        assert "Test Check network." in rca_recs_actions

        mock_pa_instance.analyze_patterns.assert_called_once()

    def test_rca_no_matching_rules(self, comprehensive_config, sample_incident_data_for_rca):
        rca = RootCauseAnalyzer(config=comprehensive_config)
        rca.pattern_analyzer = MagicMock(spec=PatternAnalyzer) # Mock pattern analyzer
        rca.pattern_analyzer.analyze_patterns.return_value = {} # Empty patterns

        no_match_data = {"description": "A very generic issue.", "metrics": {"cpu_usage": 0.1}}
        analysis_result = rca.analyze_incident(no_match_data)

        assert len(analysis_result["predicted_root_causes"]) == 1
        assert analysis_result["predicted_root_causes"][0]["type"] == "Unknown/Complex Issue"
        assert "Requires further detailed investigation" in analysis_result["explanation"]["primary_explanation"]


class TestPatternAnalyzer:
    def test_pa_init(self, comprehensive_config):
        # Pass only the pattern_analyzer relevant part of the config if it's nested that way in real use
        pa = PatternAnalyzer(config=comprehensive_config)
        assert pa is not None
        assert pa.dbscan_eps == comprehensive_config["dbscan_eps"]

    def test_pa_temporal_patterns(self, comprehensive_config, telemetry_df_for_pattern_analyzer):
        pa = PatternAnalyzer(config=comprehensive_config)
        df = telemetry_df_for_pattern_analyzer.copy()

        daily_patterns = pa.analyze_daily_patterns(df)
        assert "peak_hours" in daily_patterns
        assert "seasonality_strength" in daily_patterns
        assert "recommendations" in daily_patterns

        weekly_patterns = pa.analyze_weekly_patterns(df)
        assert "peak_days" in weekly_patterns
        assert "seasonality_strength" in weekly_patterns
        assert "recommendations" in weekly_patterns

        monthly_patterns = pa.analyze_monthly_patterns(df)
        assert "peak_days_of_month" in monthly_patterns
        assert "recommendations" in monthly_patterns

        # Test main temporal aggregator
        temporal_results = pa.analyze_temporal_patterns(df)
        assert "daily" in temporal_results
        assert "weekly" in temporal_results
        assert "monthly" in temporal_results
        assert "recommendations" in temporal_results


    def test_pa_behavioral_patterns(self, comprehensive_config, telemetry_df_for_pattern_analyzer):
        pa = PatternAnalyzer(config=comprehensive_config)
        # Ensure the configured behavioral_features exist in the test DataFrame
        df = telemetry_df_for_pattern_analyzer[comprehensive_config['behavioral_features']].copy()

        behavioral_results = pa.analyze_behavioral_patterns(df) # Pass the subsetted df
        assert "clusters" in behavioral_results
        assert "recommendations" in behavioral_results
        if behavioral_results["clusters"]: # If clusters were found
            first_cluster_key = list(behavioral_results["clusters"].keys())[0]
            if first_cluster_key != 'noise_points':
                 assert "center_features" in behavioral_results["clusters"][first_cluster_key]
                 # Check if feature names in cluster output match config
                 assert all(f_name in behavioral_results["clusters"][first_cluster_key]["center_features"] for f_name in comprehensive_config['behavioral_features'])


    def test_pa_failure_patterns(self, comprehensive_config, telemetry_df_for_pattern_analyzer):
        pa = PatternAnalyzer(config=comprehensive_config)
        df = telemetry_df_for_pattern_analyzer.copy()

        common_causes = pa.identify_common_failure_causes(df)
        assert "common_causes" in common_causes
        assert "recommendations" in common_causes
        if common_causes['common_causes']: # if any cause found
            assert "cause" in common_causes['common_causes'][0]
            assert "frequency" in common_causes['common_causes'][0]

        precursors = pa.identify_failure_precursors(df)
        assert "precursors" in precursors
        assert "recommendations" in precursors
        # Add more specific precursor content checks if data is designed for it

        impact = pa.analyze_failure_impact(df)
        assert "average_downtime" in impact # Even if 0
        assert "recommendations" in impact

        # Test main failure aggregator
        failure_results = pa.analyze_failure_patterns(df)
        assert "common_causes" in failure_results
        assert "precursors" in failure_results
        assert "impact_analysis" in failure_results
        assert "recommendations" in failure_results


    def test_pa_performance_patterns(self, comprehensive_config, telemetry_df_for_pattern_analyzer):
        pa = PatternAnalyzer(config=comprehensive_config)
        df = telemetry_df_for_pattern_analyzer.copy()

        resource_usage = pa.analyze_resource_usage_patterns(df)
        assert "metric_stats" in resource_usage
        assert "recommendations" in resource_usage

        bottlenecks = pa.identify_bottlenecks(df) # This uses config['bottleneck_rules']
        assert "detected_bottlenecks" in bottlenecks
        assert "recommendations" in bottlenecks

        perf_trends = pa.analyze_performance_trends(df)
        assert "trends" in perf_trends
        assert "recommendations" in perf_trends

        # Test main performance aggregator
        performance_results = pa.analyze_performance_patterns(df)
        assert "resource_usage" in performance_results
        assert "bottlenecks" in performance_results
        assert "trends" in performance_results
        assert "recommendations" in performance_results


class TestTelemetryProcessor:
    def test_tp_init(self, comprehensive_config):
        tp = TelemetryProcessor(config=comprehensive_config)
        assert tp is not None

    def test_tp_process_telemetry(self, comprehensive_config, telemetry_df_for_processor):
        tp = TelemetryProcessor(config=comprehensive_config)
        telemetry_list_of_dicts = telemetry_df_for_processor.to_dict(orient='records')
        processed_output = tp.process_telemetry(telemetry_list_of_dicts) # Renamed from processed_data
        assert "processed_data" in processed_output # This is the extracted_features dict
        assert "anomalies" in processed_output
        assert "trends" in processed_output # This is from _analyze_trends
        assert "insights" in processed_output
        assert isinstance(processed_output["processed_data"], dict) # Check if it's the flat feature dict

    def test_tp_handle_missing_values(self, comprehensive_config, telemetry_df_for_processor):
        tp_mean = TelemetryProcessor(config={"numerical_nan_fill_strategy": "mean", "categorical_nan_fill_strategy": "unknown"})
        df_mean_filled = tp_mean._handle_missing_values(telemetry_df_for_processor.copy())
        assert not df_mean_filled['disk_usage'].isnull().any() # Was NaN, check if filled
        assert df_mean_filled['categorical_feat'].iloc[2] == 'unknown' # Was NaN

        tp_median = TelemetryProcessor(config={"numerical_nan_fill_strategy": "median"})
        df_median_filled = tp_median._handle_missing_values(telemetry_df_for_processor[['disk_usage']].copy()) # Test only numeric
        assert not df_median_filled['disk_usage'].isnull().any()

        tp_zero = TelemetryProcessor(config={"numerical_nan_fill_strategy": "zero"})
        df_zero_filled = tp_zero._handle_missing_values(telemetry_df_for_processor[['disk_usage']].copy())
        assert (df_zero_filled['disk_usage'] == 0).sum() >= telemetry_df_for_processor['disk_usage'].isnull().sum()


    def test_tp_prepare_feature_matrix(self, comprehensive_config, telemetry_df_for_processor):
        tp = TelemetryProcessor(config=comprehensive_config)
        # Simulate a flat dictionary of features as expected by the new _prepare_feature_matrix
        # This flat dict would be the output of _extract_features (which itself is complex)
        flat_features_sample = {
            "cpu_usage_avg": 0.75,
            "memory_usage_avg": 0.65,
            "error_rate": 0.05,
            "some_other_metric": 100 # This one is not in anomaly_detection_features
        }
        matrix, names = tp._prepare_feature_matrix(flat_features_sample)
        assert isinstance(matrix, np.ndarray)
        assert matrix.shape[1] == len(comprehensive_config['anomaly_detection_features'])
        assert names == comprehensive_config['anomaly_detection_features']
        # Check if missing feature (if one was configured but not in flat_features_sample) gets 0.0
        # e.g. if config had "disk_io" but flat_features_sample didn't, matrix would have 0.0 for it.
        # This test assumes all configured features are in flat_features_sample or tests the 0.0 fill.
        # The current flat_features_sample includes all from default config for anomaly_detection_features
        assert matrix[0,0] == 0.75
        assert matrix[0,1] == 0.65
        assert matrix[0,2] == 0.05


    def test_tp_get_anomalous_features(self, comprehensive_config):
        tp = TelemetryProcessor(config=comprehensive_config)
        feature_vec = np.array([0.8, 0.2, 0.5])
        feature_names = ["cpu", "mem", "disk"]
        anom_feats = tp._get_anomalous_features(feature_vec, feature_names)
        assert len(anom_feats) == len(feature_names)
        assert anom_feats["cpu"] == 0.8

    def test_tp_calculate_derived_features(self, comprehensive_config, telemetry_df_for_processor):
        tp = TelemetryProcessor(config=comprehensive_config) # Pass full config
        df = telemetry_df_for_processor.copy()
        derived = tp._calculate_derived_features(df)

        assert "error_rate" in derived
        assert "cpu_to_memory_ratio" in derived
        assert "cpu_usage_volatility" in derived
        assert "memory_usage_trend_slope" in derived
        assert "requests_per_minute" in derived # This might be 0 if request_count not in df_for_processor

        # Test robustness: div by zero in error_rate
        df_no_req = df.copy()
        df_no_req['request_count'] = 0
        derived_no_req = tp._calculate_derived_features(df_no_req)
        assert derived_no_req['error_rate'] == 0.0

        # Test insufficient data for std/slope (should be 0.0 or NaN based on implementation)
        df_short = df.head(1).copy()
        derived_short = tp._calculate_derived_features(df_short)
        assert derived_short['cpu_usage_volatility'] == 0.0 # std of 1 point is 0 or NaN, current impl makes it 0.0
        assert derived_short['memory_usage_trend_slope'] == 0.0 # Slope of 1 point is 0


    def test_tp_calculate_period_trends(self, comprehensive_config, telemetry_df_for_processor):
        tp = TelemetryProcessor(config=comprehensive_config)
        df = telemetry_df_for_processor.copy()
        # Ensure 'trend_features' from config are present in df
        trends = tp._calculate_period_trends(df)
        assert "cpu_usage_avg" in trends
        assert "response_time_p95" in trends
        assert "slope" in trends["cpu_usage_avg"]
        assert "p_value" in trends["cpu_usage_avg"]
        if trends["cpu_usage_avg"]["p_value"] < comprehensive_config.get("trend_p_value_threshold", 0.05):
            assert trends["cpu_usage_avg"]["significant"] == True

        # Test with insufficient data
        trends_short = tp._calculate_period_trends(df.head(2)) # Needs 3 for linregress
        assert trends_short["cpu_usage_avg"]["p_value"] == 1.0 # Default for insufficient
        assert trends_short["cpu_usage_avg"]["significant"] == False

    def test_tp_detect_periodic_patterns(self, comprehensive_config, telemetry_df_for_processor):
        tp = TelemetryProcessor(config=comprehensive_config)
        # Create data with known periodicity for 'cpu_usage_avg'
        N = 100 # Number of samples
        fs = 1 # 1 sample per second
        time = np.arange(N) / fs
        freq1 = 0.1 # Hz -> 10s period
        test_data_periodic = pd.DataFrame({
            'timestamp': pd.to_datetime(time, unit='s'),
            'cpu_usage_avg': 2 * np.sin(2 * np.pi * freq1 * time) + np.random.randn(N) * 0.5
        })

        patterns = tp._detect_periodic_patterns(test_data_periodic)
        assert "cpu_usage_avg" in patterns
        assert len(patterns["cpu_usage_avg"]) > 0
        # Period should be close to 1/freq1 = 10s
        # Allow some tolerance due to FFT resolution and noise
        assert any(abs(p['period_seconds'] - (1/freq1)) < 0.5 for p in patterns["cpu_usage_avg"])

        # Test with no timestamp
        patterns_no_ts = tp._detect_periodic_patterns(test_data_periodic.drop(columns=['timestamp']))
        assert not patterns_no_ts # Should be empty

    def test_tp_detect_correlations(self, comprehensive_config, telemetry_df_for_processor):
        tp = TelemetryProcessor(config=comprehensive_config)
        df = telemetry_df_for_processor.copy()
        # Make two columns highly correlated
        df['memory_usage_avg_corr'] = df['cpu_usage_avg'] * 2 + np.random.randn(len(df)) * 0.01
        config_with_new_col = {**comprehensive_config, "correlation_features": ["cpu_usage_avg", "memory_usage_avg_corr", "error_count_sum"]}
        tp_corr = TelemetryProcessor(config=config_with_new_col)

        correlations = tp_corr._detect_correlations(df)
        assert "significant_pairs" in correlations
        assert len(correlations["significant_pairs"]) > 0
        found_pair = False
        for p_info in correlations["significant_pairs"]:
            if ("cpu_usage_avg", "memory_usage_avg_corr") == p_info["pair"] or \
               ("memory_usage_avg_corr", "cpu_usage_avg") == p_info["pair"]:
                found_pair = True
                assert abs(p_info["correlation_coefficient"]) > config_with_new_col["correlation_threshold"]
                break
        assert found_pair

    def test_tp_detect_anomalous_patterns(self, comprehensive_config, telemetry_df_for_processor):
        tp = TelemetryProcessor(config=comprehensive_config)
        df = telemetry_df_for_processor.copy()
        # Make some data trigger the rule "HighCpuAndErrors"
        df.loc[0, 'cpu_usage_avg'] = 0.9 # Rule: > 0.8
        df.loc[0, 'error_rate'] = 0.15   # Rule: > 0.1

        anom_patterns = tp._detect_anomalous_patterns(df)
        assert "HighCpuAndErrors" in anom_patterns
        assert anom_patterns["HighCpuAndErrors"]["count"] >= 1

    def test_tp_generate_insights(self, comprehensive_config, telemetry_df_for_processor):
        tp = TelemetryProcessor(config=comprehensive_config)
         # Simulate outputs from other methods
        extracted_features_sample = {"cpu_average": 0.9, "error_rate": 0.15, "cpu_usage_volatility": 30} # flat dict
        anomalies_result_sample = {
            'detected': True,
            'details': [{'distance_score': 3.0, 'threshold_value': 2.5, 'anomalous_feature_values': {'cpu_usage_avg': 0.9}}]
        }
        trends_result_sample = {
            'short_term': {'cpu_usage_avg': {'slope': 0.2, 'p_value': 0.01, 'direction': 'increasing', 'significant': True, 'r_value':0.8, 'stderr':0.01}}
        }

        insights = tp._generate_insights(extracted_features_sample, anomalies_result_sample, trends_result_sample)
        assert len(insights) > 0

        has_perf_insight = any(i['type'] == 'performance' and 'High CPU utilization' in i['message'] for i in insights)
        has_anomaly_insight = any(i['type'] == 'anomaly' for i in insights)
        has_trend_insight = any(i['type'] == 'trend' and 'cpu_usage_avg' in i['component'] for i in insights)

        assert has_perf_insight
        assert has_anomaly_insight
        assert has_trend_insight

        # Test with no significant inputs
        extracted_features_empty = {"cpu_average": 0.1}
        anomalies_empty = {'detected': False, 'details': []}
        trends_empty = {'short_term': {'cpu_usage_avg': {'p_value': 0.5, 'direction': 'stable'}}}
        insights_empty = tp._generate_insights(extracted_features_empty, anomalies_empty, trends_empty)
        # Might still have some low-priority perf insights if default thresholds are met, or no insights
        # Based on current config, cpu_average 0.1 is not high. So, should be empty if no anomaly/trend.
        if not any(i['type'] == 'performance' and 'High CPU' in i['message'] for i in insights_empty): # Check if high CPU not triggered
             assert len(insights_empty) == 0 # Or based on other potential performance insights
        else: # If other performance insights are generated by default
             assert len(insights_empty) > 0

# Placeholder for old TestPatternAnalyzer to avoid breaking changes to its structure immediately
# Will be refactored later if needed, or its tests merged/moved.
# For now, just ensuring it can run with the new config structure.
class TestPatternAnalyzer_LegacyPlaceholderTests:
    def test_pa_init(self, comprehensive_config):
        pa = PatternAnalyzer(config=comprehensive_config) # Uses the new comprehensive_config
        assert pa is not None

    def test_pa_analyze_patterns(self, comprehensive_config, telemetry_df_for_pattern_analyzer):
        pa = PatternAnalyzer(config=comprehensive_config)
        patterns = pa.analyze_patterns(telemetry_df_for_pattern_analyzer)
        assert "temporal" in patterns
        assert "behavioral" in patterns
        assert "failure" in patterns
        assert "performance" in patterns
        # Check for recommendations key in sub-patterns
        assert "recommendations" in patterns.get("temporal", {}) # Top level temporal recommendations
        assert "recommendations" in patterns.get("failure", {})
        assert "recommendations" in patterns.get("performance", {})

    def test_pa_individual_pattern_methods(self, comprehensive_config, telemetry_df_for_pattern_analyzer):
        # This test needs significant updates to match new return types and logic
        pa = PatternAnalyzer(config=comprehensive_config)
        df = telemetry_df_for_pattern_analyzer
        assert isinstance(pa.analyze_daily_patterns(df), dict)
        assert isinstance(pa.analyze_weekly_patterns(df), dict)
        assert isinstance(pa.analyze_monthly_patterns(df), dict)

        # These methods now return Dicts with 'causes'/'precursors' as keys to lists
        assert isinstance(pa.identify_common_failure_causes(df), dict)
        assert "common_causes" in pa.identify_common_failure_causes(df)

        assert isinstance(pa.identify_failure_precursors(df), dict)
        assert "precursors" in pa.identify_failure_precursors(df)

        assert isinstance(pa.analyze_failure_impact(df), dict)
        assert "average_downtime" in pa.analyze_failure_impact(df)

        assert isinstance(pa.analyze_resource_usage_patterns(df), dict)
        assert "metric_stats" in pa.analyze_resource_usage_patterns(df)

        assert isinstance(pa.identify_bottlenecks(df), dict)
        assert "detected_bottlenecks" in pa.identify_bottlenecks(df)

        assert isinstance(pa.analyze_performance_trends(df), dict)
        assert "trends" in pa.analyze_performance_trends(df)

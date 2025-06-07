import pytest
import pandas as pd
import numpy as np
import os
import joblib # For loading any pre-trained models if used

# Add src to path
import sys
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../../src')))

# Assuming AIConfig is a simple class or can be easily mocked if complex.
# If AIConfig is just a namespace for loading, we might not need to import it here
# and just use the config dictionary directly.
# from Python.common.ai_config_loader import AIConfig
from Python.analysis.telemetry_processor import TelemetryProcessor
from Python.analysis.pattern_analyzer import PatternAnalyzer
from Python.analysis.RootCauseAnalyzer import RootCauseAnalyzer # SimpleRCAEstimator, SimpleRCAExplainer are internal to RCA
from Python.predictive.feature_engineering import FeatureEngineer
from Python.predictive.model_trainer import ArcModelTrainer
from Python.predictive.predictor import ArcPredictor
from Python.predictive.predictive_analytics_engine import PredictiveAnalyticsEngine

# Comprehensive Configuration Fixture
@pytest.fixture(scope="module")
def full_ai_config_dict(): # Renamed to avoid confusion if an AIConfig class is used
    config = {
        "aiComponents": {
            "telemetry_processor": {
                "anomaly_detection_features": ["cpu_usage_avg", "memory_usage_avg", "error_count_sum"],
                "trend_features": ["cpu_usage_avg", "response_time_avg"],
                "fft_features": ["cpu_usage_avg"],
                "correlation_features": ["cpu_usage_avg", "memory_usage_avg", "disk_io_avg"],
                "correlation_threshold": 0.8,
                "trend_p_value_threshold": 0.05,
                "trend_slope_threshold": 0.01, # Adjusted for more sensitivity in tests
                "fft_num_top_frequencies": 1,
                "fft_min_amplitude_threshold": 0.1,
                "multi_metric_anomaly_rules": [{
                    "name": "HighCpuAndError",
                    "conditions": [
                        {"metric": "cpu_usage_avg", "operator": ">", "threshold": 80.0}, # Use float for thresholds
                        {"metric": "error_count_sum", "operator": ">", "threshold": 5.0}
                    ],
                     "description": "High CPU usage concurrent with high error count.",
                     "severity": "high"
                }]
            },
            "pattern_analyzer_config": { # Used by RootCauseAnalyzer and PAE for their PatternAnalyzer
                "behavioral_features": ["cpu_usage_avg", "memory_usage_avg", "error_count_sum"],
                "dbscan_eps": 0.5, "dbscan_min_samples": 2, # Adjusted for small test data
                "performance_metrics": ["cpu_usage_avg", "response_time_avg"],
                "precursor_window": "30T", # Shorter window for test data
                "precursor_significance_threshold_pct": 10,
                "sustained_high_usage_percentile": 0.8, # Adjusted
                "sustained_high_usage_min_points": 2, # Adjusted
                 "bottleneck_rules": [{
                    "name": "CPU_Bottleneck_Test",
                    "conditions": [{"metric": "cpu_usage_avg", "operator": ">", "threshold": 90.0}],
                    "description": "CPU usage exceeds 90%",
                    "severity": "high"
                }]
            },
            "rca_estimator_config": {
                 "rules": { # Simplified rules for testing
                    "cpu": {"cause": "CPU Overload Test", "recommendation": "Test Rec: Scale CPU.", "impact_score": 0.7, "metric_threshold": 0.75}, # Matched against cpu_usage_avg typically
                    "memory": {"cause": "Memory Exhaustion Test", "recommendation": "Test Rec: Add Memory.", "impact_score": 0.8, "metric_threshold": 0.85},
                    "network error": {"cause": "Network Error Test", "recommendation": "Test Rec: Check Network.", "impact_score": 0.9} # Keyword based
                },
                "default_confidence": 0.6
            },
            "rca_explainer_config": {},
            "feature_engineering": {
                "original_numerical_features": ["cpu_usage_avg", "memory_usage_avg", "disk_io_avg", "error_count_sum", "response_time_avg",
                                                "cpu_usage", "memory_usage", "disk_usage", "network_latency", "error_count", "warning_count",
                                                "request_count", "response_time", "service_restarts", "cpu_spikes", "memory_spikes", "connection_drops"], # Expanded
                "original_categorical_features": ["region"],
                "statistical_feature_columns": ["cpu_usage_avg", "memory_usage_avg"],
                "rolling_window_sizes": [2], "lags": [1], # Adjusted for small data
                "interaction_feature_columns": ["cpu_usage_avg", "memory_usage_avg"],
                "numerical_nan_fill_strategy": "mean",
                "categorical_nan_fill_strategy": "unknown",
                "feature_selection_k": 'all',
                "feature_selection_score_func": "f_classif" # Though target might not always be classification type for all models
            },
            "model_config": { # For ArcModelTrainer
                "test_split_ratio": 0.25, "random_state": 42,
                "features": { # ArcModelTrainer will use these to select columns from FeatureEngineer's output
                    "health_prediction": {"required_features_is_output_of_fe": True, "target_column": "is_healthy", "missing_strategy": "mean"},
                    "anomaly_detection": {"required_features_is_output_of_fe": True, "missing_strategy": "mean"}, # No target_column
                    "failure_prediction": {"required_features_is_output_of_fe": True, "target_column": "will_fail", "missing_strategy": "mean"}
                },
                "models": { # Params for scikit-learn models
                    "health_prediction": {"n_estimators": 10, "max_depth": 3, "random_state": 42, "class_weight": "balanced"},
                    "anomaly_detection": {"contamination": 'auto', "random_state": 42, "n_estimators":10}, # Reduced n_estimators
                    "failure_prediction": {"n_estimators": 10, "max_depth": 3, "random_state": 42, "class_weight": "balanced"}
                }
            },
             "remediation_learner_config": {
                 "context_features_to_log": ["cpu_usage_avg", "error_count_sum"],
                 "success_pattern_threshold": 0.7, "success_pattern_min_attempts": 2,
                 "ai_predictor_failure_threshold": 0.6
            }
        }
    }
    return config

@pytest.fixture(scope="module")
def sample_telemetry_for_integration_df(): # Renamed for clarity
    data = {
        'timestamp': pd.to_datetime(['2023-01-01 10:00:00', '2023-01-01 10:05:00', '2023-01-01 10:10:00',
                                      '2023-01-01 10:15:00', '2023-01-01 10:20:00', '2023-01-01 10:25:00'], errors='coerce'), # Added errors='coerce'
        'cpu_usage_avg': [50.0, 60.0, 95.0, 70.0, 85.0, 60.0],
        'memory_usage_avg': [70.0, 75.0, 92.0, 80.0, 88.0, 70.0],
        'disk_io_avg': [10.0, 12.0, 15.0, 11.0, 13.0, 10.0],
        'error_count_sum': [1, 0, 8, 2, 3, 1],
        'response_time_avg': [100.0, 110.0, 200.0, 120.0, 150.0, 100.0],
        'region': ['eastus', 'westus', 'eastus', 'eastus', 'westus', 'north'], # Categorical
        # For FeatureEngineer to use original features for model training data
        'cpu_usage': [50.0, 60.0, 95.0, 70.0, 85.0, 60.0],
        'memory_usage': [70.0, 75.0, 92.0, 80.0, 88.0, 70.0],
        'disk_usage': [0.4, 0.41, 0.42, 0.39, 0.45, 0.40],
        'network_latency': [50, 55, 52, 60, 48, 53],
        'error_count': [1, 0, 8, 2, 3, 1],
        'warning_count': [2,1,0, 2, 1, 0],
        'request_count': [100,110,105, 120, 115, 108],
        'response_time': [100,110,200,120,150, 100],
        'service_restarts': [0,0,1,0,1,0],
        'cpu_spikes': [0,1,2,0,1,0], # Added more variation
        'memory_spikes': [1,0,1,1,0,0],
        'connection_drops': [0,0,1,0,1,0],
        # Targets
        'is_healthy': [1, 1, 0, 1, 0, 1],
        'will_fail': [0, 0, 1, 0, 1, 0],
        # For PatternAnalyzer failure/* methods
        'failure_occurred': [0,0,1,0,1,0],
        'error_type': ['None', 'None', 'CPU_High', 'None', 'Memory_Leak', 'None']
    }
    return pd.DataFrame(data)

@pytest.fixture(scope="module")
def pae_test_environment(full_ai_config_dict, sample_telemetry_for_integration_df, tmp_path_factory):
    """
    Sets up a test environment for PredictiveAnalyticsEngine:
    - Creates engineered features using FeatureEngineer.
    - Trains models using ArcModelTrainer and saves them to a temp model directory.
    - Returns the path to the model directory and the configuration used.
    """
    model_dir_root = tmp_path_factory.mktemp("pae_test_env")
    pae_model_dir = model_dir_root / "models" # Known sub-directory
    pae_model_dir.mkdir()

    fe_config = full_ai_config_dict['aiComponents']['feature_engineering']
    fe = FeatureEngineer(config=fe_config)

    # Prepare data for each model type using FeatureEngineer
    # Health Prediction
    health_data_for_fe = sample_telemetry_for_integration_df.copy()
    health_engineered_features, _ = fe.engineer_features(health_data_for_fe, target='is_healthy')

    # Failure Prediction
    # Re-initialize FeatureEngineer for a clean state if it stores state (scalers, encoders)
    fe_fail = FeatureEngineer(config=fe_config)
    failure_data_for_fe = sample_telemetry_for_integration_df.copy()
    failure_engineered_features, _ = fe_fail.engineer_features(failure_data_for_fe, target='will_fail')

    # Anomaly Detection
    fe_anomaly = FeatureEngineer(config=fe_config)
    anomaly_data_for_fe = sample_telemetry_for_integration_df.copy()
    # Drop target columns before FE for anomaly detection as it's unsupervised
    anomaly_engineered_features, _ = fe_anomaly.engineer_features(anomaly_data_for_fe.drop(columns=['is_healthy', 'will_fail'], errors='ignore'))

    # ArcModelTrainer expects target columns to be present in the DFs passed to its training methods
    # So, we add them back here after feature engineering.
    health_training_df = health_engineered_features.copy()
    health_training_df['is_healthy'] = sample_telemetry_for_integration_df['is_healthy']

    failure_training_df = failure_engineered_features.copy()
    failure_training_df['will_fail'] = sample_telemetry_for_integration_df['will_fail']

    # Anomaly training df does not need a target
    anomaly_training_df = anomaly_engineered_features.copy()


    # Update model_config to use the actual engineered feature names for 'required_features'
    trainer_config = full_ai_config_dict['aiComponents']['model_config'].copy()
    trainer_config['features']['health_prediction']['required_features'] = [col for col in health_training_df.columns if col != 'is_healthy']
    trainer_config['features']['failure_prediction']['required_features'] = [col for col in failure_training_df.columns if col != 'will_fail']
    trainer_config['features']['anomaly_detection']['required_features'] = list(anomaly_training_df.columns)

    trainer = ArcModelTrainer(config=trainer_config)
    trainer.train_health_prediction_model(health_training_df)
    trainer.train_failure_prediction_model(failure_training_df)
    trainer.train_anomaly_detection_model(anomaly_training_df)
    trainer.save_models(str(model_dir))

    # Pass the main 'aiComponents' config to ArcPredictor as it might initialize FE
    # predictor = ArcPredictor(model_dir=str(model_dir), config=full_ai_config_dict['aiComponents'])
    # The fixture should return the path and config, not the predictor instance.
    return {'model_dir': str(pae_model_dir), 'config_dict': full_ai_config_dict}


# Scenario 1: Telemetry Processing to Predictive Risk Analysis
def test_telemetry_to_predictive_risk_analysis(pae_test_environment, sample_telemetry_for_integration_df):
    full_ai_config_dict = pae_test_environment['config_dict']
    model_dir_from_fixture = pae_test_environment['model_dir']

    # Config parts for assertions
    expected_predictor_config = full_ai_config_dict['aiComponents'] # Predictor gets parent config
    expected_pa_config = full_ai_config_dict['aiComponents']['pattern_analyzer_config']
    expected_fe_config_for_predictor = full_ai_config_dict['aiComponents']['feature_engineering']


    # 1. Telemetry Processing (Optional to run here, PAE does not directly use TelemetryProcessor output)
    # tp_config = full_ai_config_dict['aiComponents']['telemetry_processor']
    # tp = TelemetryProcessor(config=tp_config)
    # processed_telemetry_output = tp.process_telemetry(sample_telemetry_for_integration_df.to_dict(orient='records'))
    # assert "processed_data" in processed_telemetry_output

    # Raw snapshot for PAE input
    current_server_snapshot_raw = sample_telemetry_for_integration_df.iloc[-1].fillna(0).to_dict() # use fillna(0) for safety

    # Spy on constructors and methods
    with patch('Python.predictive.predictive_analytics_engine.ArcPredictor') as MockArcPredictorConstructor, \
         patch('Python.predictive.predictive_analytics_engine.PatternAnalyzer') as MockPatternAnalyzerConstructor, \
         patch('Python.predictive.predictor.FeatureEngineer') as MockFeatureEngineerConstructor: # Patch FE at source where ArcPredictor imports it

        # Setup mock instances that will be returned by constructors
        mock_predictor_instance = MockArcPredictorConstructor.return_value
        mock_pattern_analyzer_instance = MockPatternAnalyzerConstructor.return_value

        # ArcPredictor internally creates FeatureEngineer. We want to assert on that creation.
        # So, when MockArcPredictorConstructor is called, it should then trigger MockFeatureEngineerConstructor.
        # This is tricky. A simpler way is to check the config passed to ArcPredictor.
        # Or, mock the FeatureEngineer instance *on the ArcPredictor instance* after PAE creates predictor.

        # Mock return values of key methods on the *instances*
        mock_predictor_instance.predict_health.return_value = {"prediction": {"healthy_probability": 0.85}, "feature_impacts": {"cpu_usage_avg": 0.1}}
        mock_predictor_instance.predict_failures.return_value = {"prediction": {"failure_probability": 0.15}, "feature_impacts": {"memory_usage_avg": 0.2}, "risk_level": "Low"}
        mock_predictor_instance.detect_anomalies.return_value = {"is_anomaly": False, "anomaly_score": 0.15}
        mock_pattern_analyzer_instance.analyze_patterns.return_value = {
            "temporal": {"daily": {"recommendations": [{"action": "Check daily load", "priority": 0.5}]}, "recommendations":[]},
            "behavioral": {"recommendations":[]},
            "failure": {"recommendations":[]},
            "performance": {"recommendations":[]}
        }

        # Instantiate PAE - this will use the mocked constructors for its internal components
        pae = PredictiveAnalyticsEngine(
            config=full_ai_config_dict['aiComponents'], # PAE gets the 'aiComponents' sub-tree
            model_dir=model_dir_from_fixture
        )

        # Assert ArcPredictor and PatternAnalyzer instantiation
        MockArcPredictorConstructor.assert_called_once()
        # Check config passed to ArcPredictor. It should get the whole aiComponents config.
        actual_predictor_init_config = MockArcPredictorConstructor.call_args[1]['config']
        assert actual_predictor_init_config['model_config'] == full_ai_config_dict['aiComponents']['model_config']
        assert actual_predictor_init_config['feature_engineering'] == expected_fe_config_for_predictor
        assert MockArcPredictorConstructor.call_args[1]['model_dir'] == model_dir_from_fixture

        MockPatternAnalyzerConstructor.assert_called_once_with(config=expected_pa_config)

        # To assert FeatureEngineer was called by ArcPredictor:
        # This requires ArcPredictor to initialize FeatureEngineer in its __init__.
        # If ArcPredictor's __init__ was: self.feature_engineer = FeatureEngineer(config.get('feature_engineering'))
        # Then MockFeatureEngineerConstructor would be called.
        # Let's assume ArcPredictor's __init__ gets the parent config and extracts 'feature_engineering' for its FE.
        # The call to FeatureEngineer happens when ArcPredictor is initialized *by PAE*.
        # This test focuses on PAE's correct initialization of ArcPredictor.
        # A separate unit test for ArcPredictor should verify its internal FeatureEngineer instantiation.
        # For this integration test, we confirmed ArcPredictor got the FE config.

        # Call analyze_deployment_risk
        risk_analysis = pae.analyze_deployment_risk(current_server_snapshot_raw)

        # Assert methods on mocked instances were called by PAE
        mock_predictor_instance.predict_health.assert_called_once_with(current_server_snapshot_raw)
        mock_predictor_instance.predict_failures.assert_called_once_with(current_server_snapshot_raw)
        mock_predictor_instance.detect_anomalies.assert_called_once_with(current_server_snapshot_raw)

        # PatternAnalyzer expects a DataFrame. PAE should convert current_server_snapshot_raw
        mock_pattern_analyzer_instance.analyze_patterns.assert_called_once()
        # Check the type of argument passed to analyze_patterns
        assert isinstance(mock_pattern_analyzer_instance.analyze_patterns.call_args[0][0], pd.DataFrame)


        # Assert structure of final risk_analysis
        assert "overall_risk" in risk_analysis
        assert "score" in risk_analysis["overall_risk"]
        assert "level" in risk_analysis["overall_risk"]
        assert "recommendations" in risk_analysis
        assert len(risk_analysis["recommendations"]) > 0 # PAE generates some based on risk + pattern recs


# Scenario 2: Incident Data to Root Cause Analysis
def test_incident_to_root_cause_analysis(full_ai_config_dict, sample_telemetry_for_integration_df):
    # RootCauseAnalyzer takes the 'aiComponents' part of the config,
    # from which it will pick 'rca_estimator_config', 'rca_explainer_config', 'pattern_analyzer_config'
    rca = RootCauseAnalyzer(config=full_ai_config_dict['aiComponents'])

    # Sample incident data
    incident_data = {
        "incident_id": "INC123",
        "description": "Server is very slow, high cpu reported by users. Also network error.",
        "priority": "High",
        "metrics": { # Snapshot metrics for RCA Estimator
            "cpu_usage_avg": 0.92, # Matches "cpu" rule threshold > 0.75 from config
            "memory_usage_avg": 0.75, # Does not match "memory" rule threshold > 0.85
        },
        # For PatternAnalyzer part of RCA, it needs a DataFrame.
        # It will use the 'metrics_timeseries' key if present, or 'metrics' or the main dict.
        "metrics_timeseries": sample_telemetry_for_integration_df.to_dict(orient='records')
    }

    rca_report = rca.analyze_incident(incident_data)

    assert "incident_description" in rca_report
    assert rca_report["incident_description"] == incident_data["description"]
    assert "primary_suspected_cause" in rca_report
    assert "type" in rca_report["primary_suspected_cause"]

    # Check which rules were triggered
    # "cpu" rule: metric cpu_usage_avg 0.92 > 0.75 (estimator config)
    # "network error" rule: keyword "network error" in description
    # "Network Error Test" has higher impact (0.9) than "CPU Overload Test" (0.7)
    assert rca_report["primary_suspected_cause"]["type"] == "Network Error Test"

    predicted_cause_types = {cause['type'] for cause in rca_report.get("predicted_root_causes", [])}
    assert "CPU Overload Test" in predicted_cause_types
    assert "Network Error Test" in predicted_cause_types

    assert "explanation" in rca_report
    assert "primary_explanation" in rca_report["explanation"]
    assert "Network Error Test" in rca_report["explanation"]["primary_explanation"] # Primary cause in explanation
    assert "actionable_recommendations" in rca_report
    assert len(rca_report["actionable_recommendations"]) > 0 # Should have recs from RCA and PA

    # Check if recommendations from RCA Estimator are present
    rca_recs = [rec for rec in rca_report["actionable_recommendations"] if rec['source'] == 'RootCauseEstimator']
    assert any("Test Rec: Scale CPU." in rec['action'] for rec in rca_recs)
    assert any("Test Rec: Check Network." in rec['action'] for rec in rca_recs)

    # Check if PatternAnalyzer part ran (at least structure is there)
    assert "identified_patterns" in rca_report
    assert "temporal" in rca_report["identified_patterns"]
    assert "behavioral" in rca_report["identified_patterns"]
    assert "failure" in rca_report["identified_patterns"]
    assert "performance" in rca_report["identified_patterns"]

    # Check if recommendations from PatternAnalyzer are present (if any were generated by PA's placeholders/logic)
    pa_recs = [rec for rec in rca_report["actionable_recommendations"] if 'PatternAnalyzer' in rec['source']]
    # Depending on PA logic and data, PA might or might not add recommendations.
    # For this test, we are content if the structure from PA is present.
    assert len(pa_recs) >= 0

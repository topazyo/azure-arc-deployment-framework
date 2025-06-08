import pytest
import pandas as pd
import numpy as np
from typing import Dict, Any, List
import joblib
import os
from unittest.mock import patch, MagicMock

# Add src to path to allow direct import of modules
import sys
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../../src')))

from Python.predictive.ArcRemediationLearner import ArcRemediationLearner
from Python.predictive.feature_engineering import FeatureEngineer
from Python.predictive.model_trainer import ArcModelTrainer
from Python.predictive.predictive_analytics_engine import PredictiveAnalyticsEngine
from Python.predictive.predictor import ArcPredictor
from Python.analysis.pattern_analyzer import PatternAnalyzer # For PredictiveAnalyticsEngine dependency

# More comprehensive config for predictive components
@pytest.fixture
def comprehensive_predictive_config() -> Dict[str, Any]:
    return {
        # Feature Engineering Config
        "feature_engineering": {
            "original_numerical_features": ["cpu_usage", "memory_usage", "disk_usage", "network_latency", "error_count", "warning_count", "request_count", "response_time", "service_restarts", "cpu_spikes", "memory_spikes", "connection_drops"],
            "original_categorical_features": ["categorical_feat1"], # Assuming a categorical feature for testing encoding
            "statistical_feature_columns": ["cpu_usage", "memory_usage", "error_count"],
            "interaction_feature_columns": ["cpu_usage", "memory_usage"],
            "rolling_window_sizes": [3], # Keep small for test data
            "lags": [1, 2],
            "numerical_nan_fill_strategy": "mean",
            "categorical_nan_fill_strategy": "unknown",
            "feature_selection_k": 10, # Select top 10 features
            "feature_selection_score_func": "f_classif" # or 'f_regression' if target is continuous
        },
        # Model Trainer Config (used by ArcModelTrainer and indirectly by ArcPredictor via saved models)
        "model_config": {
            "test_split_ratio": 0.25, # Adjusted from default
            "random_state": 42,
            "features": { # This structure is used by ArcModelTrainer's prepare_data
                "health_prediction": {
                    "required_features": ["cpu_usage", "memory_usage", "disk_usage", "network_latency", "error_count", "warning_count"], # These are original features
                    "missing_strategy": "mean",
                    "target_column": "is_healthy"
                },
                "anomaly_detection": {
                    "required_features": ["cpu_usage", "memory_usage", "disk_usage", "network_latency", "request_count", "response_time"],
                    "missing_strategy": "median"
                    # No target_column for anomaly detection
                },
                "failure_prediction": {
                    "required_features": ["service_restarts", "error_count", "cpu_spikes", "memory_spikes", "connection_drops", "cpu_usage", "memory_usage"],
                    "missing_strategy": "zero",
                    "target_column": "will_fail"
                }
            },
            "models": {
                "health_prediction": {"n_estimators": 10, "max_depth": 3, "class_weight":"balanced"},
                "anomaly_detection": {"contamination": 0.1, "n_estimators": 50}, # Added n_estimators for IF
                "failure_prediction": {"n_estimators": 10, "max_depth": 3, "class_weight":"balanced"}
            }
        },
        # ArcRemediationLearner Config
        "remediation_learner_config": {
             "remediation_learner_features": ['cpu_usage', 'memory_usage', 'error_count'], # For context summary
             "success_pattern_threshold": 0.7,
             "success_pattern_min_attempts": 3,
             "ai_predictor_failure_threshold": 0.6,
             "log_level": "DEBUG",
             "retraining_data_threshold": 3 # Added for testing the trigger
        },
        # PredictiveAnalyticsEngine specific (if any, besides passing sub-configs)
        "pae_config": {
            # Config for PAE itself, e.g., risk score combination logic
        },
        # PatternAnalyzer config (if PAE initializes it with a specific sub-config key)
        "pattern_analyzer_config": {
             "clustering": {"eps": 0.5, "min_samples": 2},
             # other PA configs from comprehensive_config in test_analysis_module could go here
        }
    }

@pytest.fixture
def sample_remediation_data() -> Dict[str, Any]:
    return {
        "error_type": "NetworkFailure",
        "action": "RestartNetworking",
        "outcome": "success", # or "failure"
        "context": { # This should contain features defined in remediation_learner_features
            "cpu_usage": 0.5, "memory_usage": 0.6, "error_count": 5,
            "service_status": 1, "connection_status": 0, # Example other features
            "some_other_metric": 123
        }
    }

@pytest.fixture
def sample_telemetry_df_for_predictive() -> pd.DataFrame:
    # DataFrame with more features, including categorical and NaNs
    # to test FeatureEngineer and ModelTrainer data preparation thoroughly
    data = {
        'timestamp': pd.to_datetime([
            '2023-01-01 10:00:00', '2023-01-01 10:05:00', '2023-01-01 10:10:00',
            '2023-01-01 10:15:00', '2023-01-01 10:20:00', '2023-01-01 10:25:00'
        ]),
        'cpu_usage': [0.5, 0.6, 0.55, 0.8, np.nan, 0.65],
        'memory_usage': [0.7, 0.72, 0.71, 0.75, 0.77, np.nan],
        'disk_usage': [0.4, 0.41, 0.42, 0.39, 0.45, 0.40],
        'network_latency': [50, 55, 52, 60, 48, 53],
        'error_count': [1, 0, 1, 3, 0, 2],
        'warning_count': [2,1,0, 2, 1, 0],
        'request_count': [100,110,105, 120, 115, 108],
        'response_time': [120,130,125, 140, 135, 128],
        'service_restarts': [0,0,1,0,1,0],
        'cpu_spikes': [0,1,0,2,0,1],
        'memory_spikes': [1,0,0,1,1,0],
        'connection_drops': [0,0,0,1,0,0],
        'categorical_feat1': ['A', 'B', 'A', 'C', 'B', 'A'],
        'is_healthy': [1,1,0,0,1,1],
        'will_fail': [0,0,1,1,0,0]
    }
    return pd.DataFrame(data)


class TestArcRemediationLearner:
    def test_arl_init(self, comprehensive_predictive_config):
        arl_config = comprehensive_predictive_config.get("remediation_learner_config", {})
        arl = ArcRemediationLearner(config=arl_config)
        assert arl is not None
        assert arl.config == arl_config
        assert isinstance(arl.success_patterns, dict)

    def test_arl_initialize_ai_components(self, comprehensive_predictive_config, tmp_path):
        arl = ArcRemediationLearner(config=comprehensive_predictive_config.get("remediation_learner_config"))
        # Mock actual trainer and predictor for this unit test
        # Patch where the objects are defined
        with patch('Python.predictive.model_trainer.ArcModelTrainer') as MockTrainer, \
             patch('Python.predictive.predictor.ArcPredictor') as MockPredictor:

            # Need to ensure model_dir exists for ArcPredictor, even if mocked
            os.makedirs(tmp_path / "models", exist_ok=True)
            model_dir_for_test = str(tmp_path / "models")

            arl.initialize_ai_components(global_ai_config=comprehensive_predictive_config, model_dir=model_dir_for_test)
            MockTrainer.assert_called_once_with(comprehensive_predictive_config.get('model_config', {}))
            MockPredictor.assert_called_once_with(model_dir=model_dir_for_test)
            assert arl.trainer is not None
            assert arl.predictor is not None

    def test_arl_learn_from_remediation(self, comprehensive_predictive_config, sample_remediation_data):
        arl_config = comprehensive_predictive_config.get("remediation_learner_config", {})
        arl = ArcRemediationLearner(config=arl_config)
        arl.trainer = MagicMock(spec=ArcModelTrainer) # Mock the trainer

        # First success
        arl.learn_from_remediation(sample_remediation_data)
        pattern_key = (sample_remediation_data['error_type'], sample_remediation_data['action'])
        assert pattern_key in arl.success_patterns
        assert arl.success_patterns[pattern_key]['success_count'] == 1
        assert arl.success_patterns[pattern_key]['total_attempts'] == 1
        assert arl.success_patterns[pattern_key]['success_rate'] == 1.0
        assert len(arl.success_patterns[pattern_key]['contexts']) == 1
        context_summary_check = {k: sample_remediation_data['context'][k] for k in arl_config.get('remediation_learner_features', [])}
        assert arl.success_patterns[pattern_key]['contexts'][0] == context_summary_check
        arl.trainer.update_models_with_remediation.assert_called_once_with(sample_remediation_data)

        # Second failure for same pattern
        failed_data = {**sample_remediation_data, "outcome": "failure"}
        arl.learn_from_remediation(failed_data)
        assert arl.success_patterns[pattern_key]['success_count'] == 1
        assert arl.success_patterns[pattern_key]['total_attempts'] == 2
        assert arl.success_patterns[pattern_key]['success_rate'] == 0.5
        assert len(arl.success_patterns[pattern_key]['contexts']) == 2 # Assuming it appends context for failure too for now
        # The trainer is called for successful outcomes in the current implementation of ArcRemediationLearner
        # If it's meant to be called for all outcomes, this assertion needs adjustment.
        # Based on `if self.trainer and success:` in previous code, it's only for success.
        # The prompt for ARL (Step 8) said `if self.trainer and success:`, which implies `update_models_with_remediation` is only called on success.
        # The current `learn_from_remediation` in Step 8 code calls it regardless of success.
        # For this test, assuming it's called every time:
        assert arl.trainer.update_models_with_remediation.call_count == 2


    def test_arl_get_recommendation(self, comprehensive_predictive_config, sample_remediation_data):
        arl_config = comprehensive_predictive_config.get("remediation_learner_config", {})
        arl = ArcRemediationLearner(config=arl_config)
        arl.predictor = MagicMock(spec=ArcPredictor)

        # Scenario 1: High-success pattern
        pattern_key = ("TestError", "TestAction")
        arl.success_patterns[pattern_key] = {'success_count': 8, 'total_attempts': 10, 'success_rate': 0.8}
        error_ctx1 = {"error_type": "TestError"}
        rec1 = arl.get_recommendation(error_ctx1)
        assert rec1['recommended_action'] == "TestAction"
        assert rec1['source'] == 'SuccessPattern'
        assert rec1['confidence_score'] == 0.8

        # Scenario 2: No high-success pattern, AIPredictor provides recommendation
        arl.success_patterns.clear() # Clear patterns
        arl.predictor.predict_failures.return_value = {
            "prediction": {"failure_probability": 0.7},
            "risk_level": "High",
            "feature_impacts": {"cpu": 0.5}
            # Assuming predictor might add a 'recommended_action' or we derive one
        }
        error_ctx2 = {"error_type": "NewError", "cpu_usage": 0.9} # cpu_usage for predictor
        rec2 = arl.get_recommendation(error_ctx2)
        assert rec2['source'] == 'AIPredictor'
        assert rec2['confidence_score'] == 0.7
        assert "Investigate AI Predicted High Failure Risk" in rec2['recommended_action']


        # Scenario 3: Neither provides strong signal
        arl.success_patterns.clear()
        arl.predictor.predict_failures.return_value = {"prediction": {"failure_probability": 0.1}}
        error_ctx3 = {"error_type": "ObscureError"}
        rec3 = arl.get_recommendation(error_ctx3)
        assert rec3['recommended_action'] == 'ManualInvestigationRequired'
        assert rec3['source'] == 'Default'

    def test_arl_get_all_success_patterns(self, comprehensive_predictive_config):
        arl = ArcRemediationLearner(config=comprehensive_predictive_config.get("remediation_learner_config"))
        arl.success_patterns[("ErrorA", "ActionX")] = {"rate": 0.9}
        assert arl.get_all_success_patterns() == {("ErrorA", "ActionX"): {"rate": 0.9}}

    def test_arl_retraining_trigger(self, full_ai_config_dict, sample_remediation_data):
        # Get the remediation_learner_config, ensuring the threshold is set for the test
        # The full_ai_config_dict fixture should now have retraining_data_threshold: 3
        arl_config = full_ai_config_dict['aiComponents'].get("remediation_learner_config", {})

        arl = ArcRemediationLearner(config=arl_config)
        arl.trainer = MagicMock(spec=ArcModelTrainer) # Mock trainer

        data_category_key = "failure_prediction_data" # As used in ArcRemediationLearner

        with patch.object(arl.logger, 'info') as mock_logger_info:
            # Call 1 and 2: Should not trigger
            arl.learn_from_remediation({**sample_remediation_data, "error_type": "ErrorType1", "outcome": "success"})
            assert arl.new_data_counter.get(data_category_key, 0) == 1
            arl.learn_from_remediation({**sample_remediation_data, "error_type": "ErrorType2", "outcome": "success"})
            assert arl.new_data_counter.get(data_category_key, 0) == 2

            retraining_message_found_early = False
            for call_args in mock_logger_info.call_args_list:
                if "Consider retraining the relevant predictive models" in call_args[0][0]:
                    retraining_message_found_early = True
                    break
            assert not retraining_message_found_early, "Retraining message logged too early"

            # Call 3: Should trigger
            arl.learn_from_remediation({**sample_remediation_data, "error_type": "ErrorType3", "outcome": "success"})
            assert arl.new_data_counter.get(data_category_key, 0) == 0 # Counter reset

            retraining_message_found_on_trigger = False
            # Using the threshold from the config for the log message check
            expected_threshold_for_log = arl_config.get("retraining_data_threshold", 3)
            expected_log_message_part = f"Sufficient new data ({expected_threshold_for_log} points) gathered for '{data_category_key}'. Consider retraining"

            for call_args in mock_logger_info.call_args_list:
                if isinstance(call_args[0], tuple) and len(call_args[0]) > 0 and expected_log_message_part in call_args[0][0]:
                    retraining_message_found_on_trigger = True
                    break
            assert retraining_message_found_on_trigger, f"Retraining message not logged after reaching threshold. Logs: {mock_logger_info.call_args_list}"

            # Call 4 (after reset) - counter should be 1 again, no new log
            mock_logger_info.reset_mock() # Reset mock to check for new calls only
            arl.learn_from_remediation({**sample_remediation_data, "error_type": "ErrorType4", "outcome": "success"})
            assert arl.new_data_counter.get(data_category_key, 0) == 1

            new_retraining_message_after_reset = False
            for call_args in mock_logger_info.call_args_list:
                if expected_log_message_part in call_args[0][0]:
                    new_retraining_message_after_reset = True
                    break
            assert not new_retraining_message_after_reset, "Retraining message logged again before reaching threshold after reset"


class TestFeatureEngineer:
    def test_fe_init_and_config_params(self, comprehensive_predictive_config):
        fe_config = comprehensive_predictive_config['feature_engineering']
        fe = FeatureEngineer(config=fe_config)
        assert fe is not None
        assert fe.rolling_window_sizes == fe_config['rolling_window_sizes']
        assert fe.lags == fe_config['lags']
        assert fe.numerical_nan_fill_strategy == fe_config['numerical_nan_fill_strategy']

    def test_fe_engineer_features_flow(self, comprehensive_predictive_config, sample_telemetry_df_for_predictive):
        fe_config = comprehensive_predictive_config['feature_engineering']
        fe = FeatureEngineer(config=fe_config)
        df = sample_telemetry_df_for_predictive.copy()

        # Test with target for feature selection
        features_df, metadata = fe.engineer_features(df, target='is_healthy')

        assert isinstance(features_df, pd.DataFrame)
        assert not features_df.isnull().values.any(), "NaNs found after feature engineering"
        assert metadata['feature_count'] == fe_config['feature_selection_k'] # or less if not enough features generated
        assert len(metadata['feature_names']) == features_df.shape[1]

        # Check if original selected features are present (if any were numeric and selected)
        # This depends on what SelectKBest picks. More of an integration test.
        # For now, just verify the flow runs and produces roughly expected shape.

        # Test without target (no feature selection)
        fe_no_select = FeatureEngineer(config=fe_config) # Fresh instance for different state
        features_no_select_df, _ = fe_no_select.engineer_features(df.drop(columns=['is_healthy','will_fail']))
        assert features_no_select_df.shape[1] >= len(fe_config['original_numerical_features']) + len(fe_config['original_categorical_features']) # Should be more due to generated
        assert not features_no_select_df.isnull().values.any()


    def test_fe_handle_missing_values(self, sample_telemetry_df_for_predictive):
        # Test with mean strategy
        config_mean = {"numerical_nan_fill_strategy": "mean", "categorical_nan_fill_strategy": "unknown"}
        fe_mean = FeatureEngineer(config_mean)
        df_test_mean = sample_telemetry_df_for_predictive[['cpu_usage', 'categorical_feat1']].copy() # Has NaNs
        df_filled_mean = fe_mean._handle_missing_values(df_test_mean)
        assert not df_filled_mean['cpu_usage'].isnull().any()
        assert df_filled_mean['categorical_feat1'].isnull().sum() == 0 # Assuming 'unknown' fill

        # Test with median strategy
        config_median = {"numerical_nan_fill_strategy": "median"}
        fe_median = FeatureEngineer(config_median)
        df_test_median = sample_telemetry_df_for_predictive[['cpu_usage']].copy()
        df_filled_median = fe_median._handle_missing_values(df_test_median)
        assert not df_filled_median['cpu_usage'].isnull().any()

    def test_fe_align_target_and_features(self, comprehensive_predictive_config):
        fe = FeatureEngineer(comprehensive_predictive_config['feature_engineering'])
        features = pd.DataFrame({'A': [1,2,3,4], 'B': [5,6,7,8]})
        target = pd.Series([10, np.nan, 30, 40])
        aligned_feat, aligned_target = fe._align_target_and_features(features, target)
        assert len(aligned_feat) == 3
        assert len(aligned_target) == 3
        assert aligned_feat.index.tolist() == [0,2,3]
        assert aligned_target.index.tolist() == [0,2,3]
        assert not aligned_target.isnull().any()

    def test_fe_select_features_config(self, comprehensive_predictive_config, sample_telemetry_df_for_predictive):
        # Test with f_regression
        config_regr = {**comprehensive_predictive_config['feature_engineering'],
                       "feature_selection_score_func": "f_regression",
                       "k_best_features": 3}
        fe_regr = FeatureEngineer(config=config_regr)
        df = sample_telemetry_df_for_predictive.copy()
        # Create a simple numeric target for f_regression
        df['numeric_target'] = df['cpu_usage'] * 2 + np.random.rand(len(df)) * 0.1
        # Simulate a processed (filled, scaled, encoded) df for _select_features
        processed_df = df.drop(columns=['timestamp', 'categorical_feat1', 'is_healthy', 'will_fail']).fillna(0)

        aligned_processed_df, aligned_target = fe_regr._align_target_and_features(processed_df, df['numeric_target'])

        selected_df = fe_regr._select_features(aligned_processed_df, aligned_target)
        assert selected_df.shape[1] <= config_regr['k_best_features'] # Can be less if not enough features initially
        assert fe_regr.feature_selection_score_func_name == "f_regression"


class TestArcModelTrainer:
    def test_amt_init(self, comprehensive_predictive_config):
        trainer = ArcModelTrainer(config=comprehensive_predictive_config['model_config'])
        assert trainer is not None
        assert trainer.config == comprehensive_predictive_config['model_config']

    def test_amt_prepare_data(self, comprehensive_predictive_config, sample_telemetry_df_for_predictive):
        trainer = ArcModelTrainer(config=comprehensive_predictive_config['model_config'])
        df = sample_telemetry_df_for_predictive.copy()

        # Test health_prediction prep
        model_type = 'health_prediction'
        X_scaled, y, feature_names = trainer.prepare_data(df, model_type)

        assert X_scaled is not None
        assert y is not None
        assert len(feature_names) == len(comprehensive_predictive_config['model_config']['features'][model_type]['required_features'])
        assert X_scaled.shape[1] == len(feature_names)
        assert not np.isnan(X_scaled).any() # Scaler should handle NaNs if input was mean-filled
        assert y.name == comprehensive_predictive_config['model_config']['features'][model_type]['target_column']
        assert model_type in trainer.scalers

    def test_amt_train_and_save_all_models(self, comprehensive_predictive_config, sample_telemetry_df_for_predictive, tmp_path):
        trainer = ArcModelTrainer(config=comprehensive_predictive_config['model_config'])
        df_clean = sample_telemetry_df_for_predictive.copy()
        # Note: handle_missing_values in prepare_data will take care of NaNs based on strategy

        trainer.train_health_prediction_model(df_clean)
        assert "health_prediction" in trainer.models
        assert "health_prediction" in trainer.scalers
        assert "health_prediction" in trainer.feature_importance
        assert trainer.feature_importance["health_prediction"]['names'] is not None

        trainer.train_anomaly_detection_model(df_clean)
        assert "anomaly_detection" in trainer.models
        assert "anomaly_detection" in trainer.scalers
        # IF doesn't have feature_importances_ in the same way, so 'importances' might be None
        assert trainer.feature_importance["anomaly_detection"]['names'] is not None


        trainer.train_failure_prediction_model(df_clean)
        assert "failure_prediction" in trainer.models
        assert "failure_prediction" in trainer.scalers
        assert "failure_prediction" in trainer.feature_importance
        assert trainer.feature_importance["failure_prediction"]['names'] is not None

        trainer.save_models(str(tmp_path))
        for mt in ["health_prediction", "anomaly_detection", "failure_prediction"]:
            assert os.path.exists(tmp_path / f"{mt}_model.pkl")
            assert os.path.exists(tmp_path / f"{mt}_scaler.pkl")
            assert os.path.exists(tmp_path / f"{mt}_feature_importance.pkl") # Trainer saves this file

            # Verify content of feature_importance file
            loaded_fi = joblib.load(tmp_path / f"{mt}_feature_importance.pkl")
            assert "names" in loaded_fi
            # 'importances' can be None for anomaly_detection if model doesn't provide it
            if mt != "anomaly_detection":
                 assert "importances" in loaded_fi
                 assert loaded_fi["importances"] is not None


@pytest.fixture
def trained_models_for_predictor_path(comprehensive_predictive_config, sample_telemetry_df_for_predictive, tmp_path) -> str:
    # This fixture depends on ArcModelTrainer correctly saving models and feature info
    # Ensure the trainer's config matches what predictor might expect or is self-contained
    trainer = ArcModelTrainer(config=comprehensive_predictive_config['model_config'])
    df_clean = sample_telemetry_df_for_predictive.copy()

    trainer.train_health_prediction_model(df_clean)
    trainer.train_anomaly_detection_model(df_clean)
    trainer.train_failure_prediction_model(df_clean)

    model_save_dir = tmp_path / "models"
    model_save_dir.mkdir()
    trainer.save_models(str(model_save_dir))
    return str(model_save_dir)


class TestArcPredictor:
    def test_ap_init_and_load(self, comprehensive_predictive_config, trained_models_for_predictor_path):
        # Pass the main config to ArcPredictor if it uses it, or None
        predictor = ArcPredictor(model_dir=trained_models_for_predictor_path, config=comprehensive_predictive_config)
        assert predictor is not None
        for model_type in ["health_prediction", "anomaly_detection", "failure_prediction"]:
            assert model_type in predictor.models
            assert model_type in predictor.scalers
            assert model_type in predictor.feature_info
            assert "ordered_features" in predictor.feature_info[model_type]
            assert predictor.feature_info[model_type]["ordered_features"] is not None
            # importances_map can be None if model (like IF) doesn't produce them
            if model_type != "anomaly_detection":
                 assert predictor.feature_info[model_type]["importances_map"] is not None


    def test_ap_prepare_features(self, comprehensive_predictive_config, trained_models_for_predictor_path, sample_telemetry_df_for_predictive):
        predictor = ArcPredictor(model_dir=trained_models_for_predictor_path, config=comprehensive_predictive_config)
        telemetry_sample = sample_telemetry_df_for_predictive.iloc[0].to_dict()

        model_type = "health_prediction"
        ordered_names = predictor.feature_info[model_type]['ordered_features']

        # Test with all features present
        raw_features_array = predictor.prepare_features(telemetry_sample, model_type)
        assert isinstance(raw_features_array, np.ndarray)
        assert raw_features_array.shape == (1, len(ordered_names))

        # Test with a missing feature
        telemetry_missing_feat = telemetry_sample.copy()
        if ordered_names: # Ensure there's at least one feature to remove
            missing_feature_name = ordered_names[0]
            del telemetry_missing_feat[missing_feature_name]

            raw_features_missing_array = predictor.prepare_features(telemetry_missing_feat, model_type)
            assert raw_features_missing_array is not None
            # The value for the missing feature should be 0.0 as per prepare_features logic
            # Find index of missing_feature_name in ordered_names
            idx_missing = ordered_names.index(missing_feature_name)
            assert raw_features_missing_array[0, idx_missing] == 0.0


    def test_ap_all_predictions(self, comprehensive_predictive_config, trained_models_for_predictor_path, sample_telemetry_df_for_predictive):
        predictor = ArcPredictor(model_dir=trained_models_for_predictor_path, config=comprehensive_predictive_config)
        telemetry_sample = sample_telemetry_df_for_predictive.iloc[0].fillna(0).to_dict() # fillna for this specific sample

        health_pred = predictor.predict_health(telemetry_sample)
        assert "prediction" in health_pred
        assert "healthy_probability" in health_pred["prediction"]
        assert "feature_impacts" in health_pred # Should be present even if empty

        anomaly_pred = predictor.detect_anomalies(telemetry_sample)
        assert "is_anomaly" in anomaly_pred
        assert "anomaly_score" in anomaly_pred

        failure_pred = predictor.predict_failures(telemetry_sample)
        assert "prediction" in failure_pred
        assert "failure_probability" in failure_pred["prediction"]
        assert "feature_impacts" in failure_pred


class TestPredictiveAnalyticsEngine: # Basic tests, PAE is mostly an orchestrator
    def test_pae_init(self, comprehensive_predictive_config, trained_models_for_predictor_path):
        # Mock PatternAnalyzer to avoid its complex dependencies for this test
        # PAE expects 'pattern_analyzer_config' key in the config it passes to PatternAnalyzer
        pa_config = comprehensive_predictive_config.get('pattern_analyzer_config', {})

        with patch('Python.predictive.predictive_analytics_engine.PatternAnalyzer') as MockPatternAnalyzer:
            mock_pa_instance = MockPatternAnalyzer.return_value
            # Setup mock return for analyze_patterns
            mock_pa_instance.analyze_patterns.return_value = {
                "temporal": {"daily": {"recommendations": []}, "recommendations":[]},
                "failure": {"recommendations": []},
                "performance": {"recommendations": []},
                "behavioral": {"recommendations":[]}
            }

            # PAE receives the global config, and then passes sub-configs to its components
            pae = PredictiveAnalyticsEngine(config=comprehensive_predictive_config, model_dir=trained_models_for_predictor_path)
            assert pae is not None
            assert isinstance(pae.trainer, ArcModelTrainer)
            assert isinstance(pae.predictor, ArcPredictor)
            assert isinstance(pae.pattern_analyzer, MockPatternAnalyzer) # Check it's the mocked instance
            MockPatternAnalyzer.assert_called_once_with(pa_config)


    def test_pae_analyze_deployment_risk(self, comprehensive_predictive_config, trained_models_for_predictor_path, sample_telemetry_df_for_predictive):
        pa_config = comprehensive_predictive_config.get('pattern_analyzer_config', {})
        with patch('Python.predictive.predictive_analytics_engine.PatternAnalyzer') as MockPatternAnalyzer:
            mock_pa_instance = MockPatternAnalyzer.return_value
            mock_pa_instance.analyze_patterns.return_value = {
                'temporal': {'daily': {'data': 'mock_temporal_daily', 'recommendations': [{'action': 'Test Rec Daily', 'priority': 0.5}]},"recommendations":[]},
                'behavioral': {'data': 'mock_behavioral', 'recommendations': []},
                'failure': {'data': 'mock_failure', 'recommendations': []},
                'performance': {'data': 'mock_performance', 'recommendations': []}
            }

            pae = PredictiveAnalyticsEngine(config=comprehensive_predictive_config, model_dir=trained_models_for_predictor_path)
            server_data_sample = sample_telemetry_df_for_predictive.iloc[0].fillna(0).to_dict()
            risk_analysis = pae.analyze_deployment_risk(server_data_sample)

            assert "overall_risk" in risk_analysis
            assert "score" in risk_analysis["overall_risk"]
            assert "recommendations" in risk_analysis
            assert len(risk_analysis["recommendations"]) >= 0
            # Check if PA's recommendation is included
            assert any("Test Rec Daily" in rec.get("action", "") for rec in risk_analysis["recommendations"])

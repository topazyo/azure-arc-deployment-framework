import pytest
import numpy as np
import pandas as pd
from Python.predictive.model_trainer import ArcModelTrainer
import copy

def test_model_initialization(sample_config):
    trainer = ArcModelTrainer(sample_config)
    assert trainer.config == sample_config
    assert isinstance(trainer.models, dict)
    assert isinstance(trainer.scalers, dict)
    assert isinstance(trainer.feature_importance, dict)

def test_prepare_data(sample_training_data, sample_config):
    trainer = ArcModelTrainer(sample_config)
    features, target, feature_names = trainer.prepare_data(
        sample_training_data,
        'health_prediction'
    )
    
    assert isinstance(features, np.ndarray)
    assert isinstance(target, pd.Series)
    assert features.shape[0] == target.shape[0]
    assert isinstance(feature_names, list)
    assert not np.isnan(features).any()

def test_train_health_prediction_model(sample_training_data, sample_config):
    trainer = ArcModelTrainer(sample_config)
    trainer.train_health_prediction_model(sample_training_data)
    
    assert 'health_prediction' in trainer.models
    assert 'health_prediction' in trainer.scalers
    assert 'health_prediction' in trainer.feature_importance

def test_train_anomaly_detection_model(sample_training_data, sample_config):
    trainer = ArcModelTrainer(sample_config)
    trainer.train_anomaly_detection_model(sample_training_data)
    
    assert 'anomaly_detection' in trainer.models
    assert 'anomaly_detection' in trainer.scalers

def test_train_failure_prediction_model(sample_training_data, sample_config):
    trainer = ArcModelTrainer(sample_config)
    trainer.train_failure_prediction_model(sample_training_data)
    
    assert 'failure_prediction' in trainer.models
    assert 'failure_prediction' in trainer.scalers
    assert 'failure_prediction' in trainer.feature_importance

def test_save_models(sample_training_data, sample_config, tmp_path):
    trainer = ArcModelTrainer(sample_config)
    trainer.train_health_prediction_model(sample_training_data)
    trainer.train_anomaly_detection_model(sample_training_data)
    trainer.train_failure_prediction_model(sample_training_data)
    
    output_dir = tmp_path / "models"
    output_dir.mkdir()
    trainer.save_models(str(output_dir))
    
    assert (output_dir / "health_prediction_model.pkl").exists()
    assert (output_dir / "anomaly_detection_model.pkl").exists()
    assert (output_dir / "failure_prediction_model.pkl").exists()

def test_handle_missing_values(sample_training_data, sample_config):
    trainer = ArcModelTrainer(sample_config)
    
    # Introduce missing values
    sample_training_data.loc[0:10, 'cpu_usage'] = np.nan
    
    # Test different strategies
    mean_result = trainer.handle_missing_values(sample_training_data.copy(), 'mean', 'test_type_mean')
    assert not mean_result.isna().any().any()
    
    median_result = trainer.handle_missing_values(sample_training_data.copy(), 'median', 'test_type_median')
    assert not median_result.isna().any().any()
    
    zero_result = trainer.handle_missing_values(sample_training_data.copy(), 'zero', 'test_type_zero')
    assert not zero_result.isna().any().any()

def test_error_handling(sample_config):
    trainer = ArcModelTrainer(sample_config)
    
    with pytest.raises(Exception):
        trainer.prepare_data(None, 'health_prediction')
    
    with pytest.raises(Exception):
        trainer.train_health_prediction_model(None)
    
    with pytest.raises(Exception):
        trainer.save_models(None)

def test_model_performance(sample_training_data, sample_config):
    trainer = ArcModelTrainer(sample_config)
    
    # Train models
    trainer.train_health_prediction_model(sample_training_data)
    trainer.train_failure_prediction_model(sample_training_data)
    
    # Test predictions
    features, _, _ = trainer.prepare_data(sample_training_data, 'health_prediction')
    health_predictions = trainer.models['health_prediction'].predict(features)
    assert len(health_predictions) == len(sample_training_data)
    
    features, _, _ = trainer.prepare_data(sample_training_data, 'failure_prediction')
    failure_predictions = trainer.models['failure_prediction'].predict(features)
    assert len(failure_predictions) == len(sample_training_data)


def test_update_models_with_remediation_queues_and_signals(sample_config):
    cfg = copy.deepcopy(sample_config)
    cfg["remediation_update_batch_size"] = 2
    trainer = ArcModelTrainer(cfg)

    payload = {
        "model_type": "failure_prediction",
        "features": {"cpu_usage": 80, "memory_usage": 70, "error_count": 3},
        "target": 1,
    }

    first = trainer.update_models_with_remediation(payload)
    assert first["status"] == "queued"
    assert first["queued_count"] == 1

    second = trainer.update_models_with_remediation(payload)
    assert second["status"] == "retrain_required"
    assert second["queued_count"] == 2
    assert trainer.remediation_buffer["failure_prediction"]


def test_update_models_with_remediation_rejects_invalid(sample_config):
    trainer = ArcModelTrainer(sample_config)

    resp = trainer.update_models_with_remediation("not-a-dict")
    assert resp["status"] == "rejected"
    assert "reason" in resp


def test_update_models_with_remediation_requires_numeric_features(sample_config):
    trainer = ArcModelTrainer(sample_config)

    resp = trainer.update_models_with_remediation({
        "model_type": "failure_prediction",
        "features": {"cpu_usage": "high"},
    })

    assert resp["status"] == "rejected"
    assert resp["reason"] == "no numeric features extracted"


# ---------------------------------------------------------------------------
# Coverage gap tests: alternative algorithms and edge-case branches
# ---------------------------------------------------------------------------

def test_train_health_gradient_boosting(sample_training_data, sample_config):
    """GradientBoostingClassifier algorithm path in train_health_prediction_model."""
    import copy
    cfg = copy.deepcopy(sample_config)
    cfg['models']['health_prediction']['algorithm'] = 'GradientBoostingClassifier'
    cfg['models']['health_prediction']['gradient_boosting_params'] = {
        'n_estimators': 10, 'learning_rate': 0.1, 'max_depth': 3, 'subsample': 1.0
    }
    trainer = ArcModelTrainer(cfg)
    trainer.train_health_prediction_model(sample_training_data)
    assert 'health_prediction' in trainer.models


def test_train_health_unsupported_algorithm(sample_training_data, sample_config):
    """Unsupported algorithm defaults to RandomForestClassifier with a log warning."""
    import copy
    cfg = copy.deepcopy(sample_config)
    cfg['models']['health_prediction']['algorithm'] = 'KNeighborsClassifier'
    trainer = ArcModelTrainer(cfg)
    trainer.train_health_prediction_model(sample_training_data)
    # Falls back to RandomForest; model is still trained
    assert 'health_prediction' in trainer.models


def test_prepare_data_non_dataframe_raises(sample_config):
    """prepare_data raises ValueError for non-DataFrame input."""
    trainer = ArcModelTrainer(sample_config)
    with pytest.raises(ValueError):
        trainer.prepare_data("not a dataframe", 'health_prediction')


def test_prepare_data_empty_dataframe_raises(sample_config):
    """prepare_data raises ValueError for empty DataFrame."""
    trainer = ArcModelTrainer(sample_config)
    with pytest.raises(ValueError):
        trainer.prepare_data(pd.DataFrame(), 'health_prediction')


def test_train_health_model_no_model_config(sample_training_data, sample_config):
    """train_health_prediction_model returns early when models config entry is missing."""
    import copy
    cfg = copy.deepcopy(sample_config)
    cfg['models'].pop('health_prediction', None)
    trainer = ArcModelTrainer(cfg)
    trainer.train_health_prediction_model(sample_training_data)  # must not raise
    assert 'health_prediction' not in trainer.models


def test_train_health_single_class_returns_early(sample_training_data, sample_config):
    """Returns early without training if all health_status labels are the same class."""
    data = sample_training_data.copy()
    data['health_status'] = True  # only one unique class
    trainer = ArcModelTrainer(sample_config)
    trainer.train_health_prediction_model(data)
    assert 'health_prediction' not in trainer.models


def test_train_failure_single_class_returns_early(sample_training_data, sample_config):
    """Returns early without training if all failure_status labels are the same class."""
    data = sample_training_data.copy()
    data['failure_status'] = False  # only one unique class
    trainer = ArcModelTrainer(sample_config)
    trainer.train_failure_prediction_model(data)
    assert 'failure_prediction' not in trainer.models


def test_prepare_data_empty_model_type_raises(sample_training_data, sample_config):
    """prepare_data raises ValueError when model_type is empty string."""
    trainer = ArcModelTrainer(sample_config)
    with pytest.raises(ValueError):
        trainer.prepare_data(sample_training_data, "")


def test_prepare_data_no_matching_features_raises(sample_config):
    """prepare_data raises ValueError when no required features are in the data."""
    trainer = ArcModelTrainer(sample_config)
    empty_cols_df = pd.DataFrame({'unrelated_a': [1, 2, 3], 'unrelated_b': [4, 5, 6]})
    with pytest.raises(ValueError):
        trainer.prepare_data(empty_cols_df, 'health_prediction')


def test_train_anomaly_non_dataframe_raises(sample_config):
    """train_anomaly_detection_model raises ValueError for non-DataFrame input."""
    trainer = ArcModelTrainer(sample_config)
    with pytest.raises(ValueError):
        trainer.train_anomaly_detection_model("not a dataframe")


def test_train_failure_non_dataframe_raises(sample_config):
    """train_failure_prediction_model raises ValueError for non-DataFrame input."""
    trainer = ArcModelTrainer(sample_config)
    with pytest.raises(ValueError):
        trainer.train_failure_prediction_model("not a dataframe")


def test_handle_mv_dropna_strategy(sample_config):
    """dropna strategy drops rows with NaN values."""
    trainer = ArcModelTrainer(sample_config)
    data = pd.DataFrame({'col_a': [1.0, np.nan, 3.0], 'col_b': [4.0, 5.0, 6.0]})
    result = trainer.handle_missing_values(data, 'dropna', 'test_type')
    assert result.isnull().sum().sum() == 0
    assert len(result) == 2  # one row dropped


def test_handle_mv_unknown_strategy_returns_unchanged(sample_config):
    """Unknown strategy logs warning and returns data unchanged (NaNs preserved)."""
    trainer = ArcModelTrainer(sample_config)
    data = pd.DataFrame({'col_a': [1.0, np.nan, 3.0], 'col_b': [4.0, 5.0, 6.0]})
    result = trainer.handle_missing_values(data, 'custom_strategy', 'test_type')
    assert result.isnull().sum().sum() > 0  # NaNs are not filled


def test_handle_mv_mean_all_nan_falls_back_to_zero(sample_config):
    """mean strategy: all-NaN column mean is NaN → falls back to 0."""
    trainer = ArcModelTrainer(sample_config)
    data = pd.DataFrame({'col_a': [np.nan, np.nan, np.nan], 'col_b': [1.0, 2.0, 3.0]})
    result = trainer.handle_missing_values(data, 'mean', 'test_type')
    assert result['col_a'].isnull().sum() == 0
    assert (result['col_a'] == 0.0).all()


def test_handle_mv_median_all_nan_falls_back_to_zero(sample_config):
    """median strategy: all-NaN column median is NaN → falls back to 0."""
    trainer = ArcModelTrainer(sample_config)
    data = pd.DataFrame({'col_a': [np.nan, np.nan, np.nan], 'col_b': [1.0, 2.0, 3.0]})
    result = trainer.handle_missing_values(data, 'median', 'test_type')
    assert result['col_a'].isnull().sum() == 0
    assert (result['col_a'] == 0.0).all()
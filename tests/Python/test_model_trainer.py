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
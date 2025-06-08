import pytest
import pandas as pd
import numpy as np
from Python.predictive.feature_engineering import FeatureEngineer

def test_engineer_features(sample_training_data, sample_config):
    engineer = FeatureEngineer(sample_config)
    features, metadata = engineer.engineer_features(
        sample_training_data,
        target='health_status'
    )
    
    assert isinstance(features, pd.DataFrame)
    assert isinstance(metadata, dict)
    assert not features.empty
    assert 'feature_count' in metadata
    assert 'feature_names' in metadata

def test_create_temporal_features(sample_training_data, sample_config):
    engineer = FeatureEngineer(sample_config)
    sample_training_data['timestamp'] = pd.date_range(
        start='2024-01-01',
        periods=len(sample_training_data),
        freq='H'
    )
    
    temporal_features = engineer._create_temporal_features(sample_training_data)
    
    assert isinstance(temporal_features, pd.DataFrame)
    assert 'hour' in temporal_features.columns
    assert 'day_of_week' in temporal_features.columns
    assert 'is_weekend' in temporal_features.columns
    assert 'hour_sin' in temporal_features.columns
    assert 'hour_cos' in temporal_features.columns

def test_create_statistical_features(sample_training_data, sample_config):
    engineer = FeatureEngineer(sample_config)
    statistical_features = engineer._create_statistical_features(sample_training_data)
    
    assert isinstance(statistical_features, pd.DataFrame)
    assert not statistical_features.empty
    assert any('rolling_mean' in col for col in statistical_features.columns)
    assert any('rolling_std' in col for col in statistical_features.columns)

def test_create_interaction_features(sample_training_data, sample_config):
    engineer = FeatureEngineer(sample_config)
    interaction_features = engineer._create_interaction_features(sample_training_data)
    
    assert isinstance(interaction_features, pd.DataFrame)
    assert not interaction_features.empty
    assert any('product' in col for col in interaction_features.columns)
    assert any('ratio' in col for col in interaction_features.columns)

def test_scale_features(sample_training_data, sample_config):
    engineer = FeatureEngineer(sample_config)
    scaled_features = engineer._scale_features(sample_training_data)
    
    assert isinstance(scaled_features, pd.DataFrame)
    assert not scaled_features.empty
    assert scaled_features.shape == sample_training_data.shape
    assert abs(scaled_features.mean()).mean() < 0.1  # Approximately centered

def test_encode_categorical_features(sample_training_data, sample_config):
    # Add categorical column
    sample_training_data['category'] = np.random.choice(['A', 'B', 'C'], size=len(sample_training_data))
    
    engineer = FeatureEngineer(sample_config)
    encoded_features = engineer._encode_categorical_features(sample_training_data)
    
    assert isinstance(encoded_features, pd.DataFrame)
    assert 'category' not in encoded_features.columns
    assert any('category_' in col for col in encoded_features.columns)

def test_select_features(sample_training_data, sample_config):
    engineer = FeatureEngineer(sample_config)
    features = engineer._scale_features(sample_training_data)
    selected_features = engineer._select_features(
        features,
        sample_training_data['health_status']
    )
    
    assert isinstance(selected_features, pd.DataFrame)
    assert not selected_features.empty
    assert selected_features.shape[1] <= features.shape[1]

def test_error_handling(sample_config):
    engineer = FeatureEngineer(sample_config)
    
    with pytest.raises(Exception):
        engineer.engineer_features(None)
    
    with pytest.raises(Exception):
        engineer.engineer_features(pd.DataFrame())
    
    with pytest.raises(Exception):
        engineer.engineer_features(
            pd.DataFrame({'invalid': [1, 2, 3]}),
            target='nonexistent'
        )

def test_feature_metadata(sample_training_data, sample_config):
    engineer = FeatureEngineer(sample_config)
    features, metadata = engineer.engineer_features(
        sample_training_data,
        target='health_status'
    )
    
    assert isinstance(metadata, dict)
    assert 'feature_count' in metadata
    assert 'feature_names' in metadata
    assert 'feature_types' in metadata
    assert 'numerical_features' in metadata
    assert 'categorical_features' in metadata
    assert 'missing_values' in metadata
    assert 'feature_statistics' in metadata

def test_incremental_learning(sample_training_data, sample_config):
    engineer = FeatureEngineer(sample_config)
    
    # First batch
    features1, _ = engineer.engineer_features(
        sample_training_data[:500],
        target='health_status'
    )
    
    # Second batch
    features2, _ = engineer.engineer_features(
        sample_training_data[500:],
        target='health_status'
    )
    
    assert features1.columns.equals(features2.columns)
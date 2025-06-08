import pytest
import pandas as pd
import numpy as np
from datetime import datetime # Added import
from Python.analysis.telemetry_processor import TelemetryProcessor

def test_process_telemetry(sample_telemetry_data, sample_config):
    processor = TelemetryProcessor(sample_config)
    result = processor.process_telemetry(sample_telemetry_data.to_dict('records'))
    
    assert isinstance(result, dict)
    assert 'processed_data' in result
    assert 'anomalies' in result
    assert 'trends' in result
    assert 'insights' in result
    assert 'timestamp' in result

def test_prepare_data(sample_telemetry_data, sample_config):
    processor = TelemetryProcessor(sample_config)
    df = processor._prepare_data(sample_telemetry_data.to_dict('records'))
    
    assert isinstance(df, pd.DataFrame)
    assert not df.empty
    assert 'timestamp' in df.columns
    assert df['timestamp'].dtype == 'datetime64[ns]'
    assert not df.duplicated().any()

def test_extract_features(sample_telemetry_data, sample_config):
    processor = TelemetryProcessor(sample_config)
    df = processor._prepare_data(sample_telemetry_data.to_dict('records'))
    features = processor._extract_features(df)
    
    assert isinstance(features, dict)
    assert 'cpu' in features
    assert 'memory' in features
    assert 'errors' in features
    assert 'network' in features
    assert 'derived' in features

def test_detect_anomalies(sample_telemetry_data, sample_config):
    processor = TelemetryProcessor(sample_config)
    df = processor._prepare_data(sample_telemetry_data.to_dict('records'))
    features = processor._extract_features(df)
    anomalies = processor._detect_anomalies(features)
    
    assert isinstance(anomalies, dict)
    assert 'detected' in anomalies
    assert isinstance(anomalies['detected'], bool)
    assert 'details' in anomalies
    assert isinstance(anomalies['details'], list)

def test_analyze_trends(sample_telemetry_data, sample_config):
    processor = TelemetryProcessor(sample_config)
    df = processor._prepare_data(sample_telemetry_data.to_dict('records'))
    trends = processor._analyze_trends(df)
    
    assert isinstance(trends, dict)
    assert 'short_term' in trends
    assert 'long_term' in trends
    assert 'patterns' in trends

def test_generate_insights(sample_telemetry_data, sample_config):
    processor = TelemetryProcessor(sample_config)
    df = processor._prepare_data(sample_telemetry_data.to_dict('records'))
    features = processor._extract_features(df)
    anomalies = processor._detect_anomalies(features)
    trends = processor._analyze_trends(df)
    insights = processor._generate_insights(features, anomalies, trends)
    
    assert isinstance(insights, list)
    assert all(isinstance(insight, dict) for insight in insights)
    assert all('priority' in insight for insight in insights)

def test_error_handling(sample_config):
    processor = TelemetryProcessor(sample_config)
    
    with pytest.raises(Exception):
        processor.process_telemetry(None)
    
    with pytest.raises(Exception):
        processor.process_telemetry([])
    
    with pytest.raises(Exception):
        processor.process_telemetry([{'invalid': 'data'}])

def test_missing_data_handling(sample_telemetry_data, sample_config):
    # Introduce missing values
    sample_telemetry_data.loc[0:10, 'cpu_usage'] = np.nan
    
    processor = TelemetryProcessor(sample_config)
    result = processor.process_telemetry(sample_telemetry_data.to_dict('records'))
    
    assert isinstance(result, dict)
    assert 'processed_data' in result
    assert not pd.isna(result['processed_data']).any().any()

def test_edge_cases(sample_config):
    processor = TelemetryProcessor(sample_config)
    
    # Test with minimal data
    minimal_data = pd.DataFrame({
        'timestamp': [datetime.now()],
        'cpu_usage': [50],
        'memory_usage': [50]
    })
    result = processor.process_telemetry(minimal_data.to_dict('records'))
    assert isinstance(result, dict)
    
    # Test with large values
    large_data = pd.DataFrame({
        'timestamp': [datetime.now()],
        'cpu_usage': [1e6],
        'memory_usage': [1e6]
    })
    result = processor.process_telemetry(large_data.to_dict('records'))
    assert isinstance(result, dict)
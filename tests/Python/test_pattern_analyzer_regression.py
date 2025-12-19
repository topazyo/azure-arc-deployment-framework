import numpy as np
import pandas as pd
from Python.analysis.pattern_analyzer import PatternAnalyzer


def test_pattern_analyzer_import_and_analyze_clusters():
    pa = PatternAnalyzer(config={"behavioral_features": ["f1", "f2"]})

    features = np.array([[1.0, 2.0], [3.0, 4.0]])
    labels = np.array([0, 0])
    feature_names = ["f1", "f2"]

    summary = pa.analyze_clusters(features, labels, feature_names)

    assert "cluster_0" in summary
    assert summary["cluster_0"]["size"] == 2
    assert "center_features" in summary["cluster_0"]
    assert "variance_features" in summary["cluster_0"]


def test_prepare_behavioral_features_returns_empty_when_missing_config():
    df = pd.DataFrame({"foo": [1, 2]})
    pa = PatternAnalyzer(config={})

    features, names = pa.prepare_behavioral_features(df)

    assert features.shape == (0, 0)
    assert names == []

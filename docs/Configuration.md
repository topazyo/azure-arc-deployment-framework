# Framework AI Configuration Guide

## Introduction

The primary configuration for the Python AI engine within the Azure Arc Framework is managed through the `src/config/ai_config.json` file. This JSON file allows users to customize various aspects of data processing, pattern analysis, feature engineering, and model training without modifying the Python code directly.

Understanding and correctly setting these configurations is crucial for tailoring the AI engine's behavior to specific datasets and operational goals.

## Main Configuration Structure: `ai_config.json`

The `ai_config.json` file is typically structured under a main key, often `"aiComponents"`, which then contains specific configuration objects for each major Python component of the AI engine.

### 1. `telemetry_processor`

This section configures the `TelemetryProcessor` class (`src/Python/analysis/telemetry_processor.py`), which is responsible for initial data cleaning, feature extraction, anomaly detection, and trend analysis from raw telemetry.

*   **`anomaly_detection_features`**: (List of strings) Specifies the exact feature names (after extraction/flattening by `_extract_features`) to be used for building the feature matrix for anomaly detection (e.g., Mahalanobis distance).
    *   Example: `["cpu_usage_avg", "memory_usage_avg", "error_rate"]`
*   **`trend_features`**: (List of strings) A list of numerical feature names for which trends should be calculated using `scipy.stats.linregress`. If empty, the processor may default to all numerical columns.
    *   Example: `["cpu_usage_avg", "response_time_p95"]`
*   **`fft_features`**: (List of strings) Numerical features on which to perform Fast Fourier Transform (FFT) for detecting periodic patterns. Requires a 'timestamp' column in the input data.
    *   Example: `["cpu_usage_avg"]`
*   **`correlation_features`**: (List of strings) Numerical features to be included in a Pearson correlation matrix calculation. If empty, may default to all numerical columns.
    *   Example: `["cpu_usage_avg", "memory_usage_avg", "error_count_sum"]`
*   **`correlation_threshold`**: (Float, e.g., 0.8) Absolute correlation coefficient value above which feature pairs are considered significantly correlated.
*   **`trend_p_value_threshold`**: (Float, e.g., 0.05) The p-value threshold below which a calculated trend is considered statistically significant.
*   **`trend_slope_threshold`**: (Float, e.g., 0.01) The minimum absolute slope magnitude for a trend to be considered 'increasing' or 'decreasing' (otherwise 'stable').
*   **`fft_num_top_frequencies`**: (Integer, e.g., 3) Number of dominant frequencies to report from FFT analysis.
*   **`fft_min_amplitude_threshold`**: (Float, e.g., 0.1) Minimum amplitude for a detected frequency to be considered significant.
*   **`multi_metric_anomaly_rules`**: (List of rule objects) Defines rules for detecting anomalous patterns based on multiple metrics breaching thresholds simultaneously.
    *   Each rule object structure:
        ```json
        {
            "name": "HighCpuAndLowMemory",
            "conditions": [
                {"metric": "cpu_usage_avg", "operator": ">", "threshold": 85.0},
                {"metric": "memory_available_mbytes", "operator": "<", "threshold": 500.0}
            ],
            "description": "CPU usage is critically high while available memory is critically low.",
            "severity": "critical"
        }
        ```

### 2. `pattern_analyzer_config` (or `pattern_analyzer`)

This section configures the `PatternAnalyzer` class (`src/Python/analysis/pattern_analyzer.py`).

*   **`behavioral_features`**: (List of strings) Features to be used for DBSCAN clustering to identify behavioral patterns.
*   **`dbscan_eps`**: (Float, e.g., 0.5) The maximum distance between two samples for one to be considered as in the neighborhood of the other (DBSCAN parameter).
*   **`dbscan_min_samples`**: (Integer, e.g., 5) The number of samples in a neighborhood for a point to be considered as a core point (DBSCAN parameter).
*   **`performance_metrics`**: (List of strings) Key numerical metrics used for `analyze_resource_usage_patterns` and `analyze_performance_trends`.
*   **`precursor_window`**: (String, e.g., "1H", "30T") Time window (Pandas timedelta string format) before a failure event to analyze for precursors.
*   **`precursor_significance_threshold_pct`**: (Float, e.g., 10.0) Percentage change in a metric's average before failure (compared to overall average) to be considered a significant precursor.
*   **`sustained_high_usage_percentile`**: (Float, e.g., 0.90) Percentile used to define "high usage" for detecting sustained periods.
*   **`sustained_high_usage_min_points`**: (Integer, e.g., 5) Minimum number of consecutive data points above the high usage threshold to be considered "sustained."
*   **`bottleneck_rules`**: (List of rule objects) Similar to `multi_metric_anomaly_rules` in `telemetry_processor`, but specifically for defining conditions that constitute performance bottlenecks.

### 3. `rca_estimator_config`

Configures the `SimpleRCAEstimator` within the `RootCauseAnalyzer`.

*   **`rules`**: (Dictionary) Defines the rule-based logic for RCA.
    *   Each key is a keyword (e.g., "cpu", "network error").
    *   Each value is an object: `{"cause": "Cause String", "recommendation": "Recommendation String", "impact_score": float, "metric_threshold": float (optional)}`.
    *   Example:
        ```json
        "cpu": {
            "cause": "CPU Overload",
            "recommendation": "Scale CPU resources or optimize high-CPU processes.",
            "impact_score": 0.7,
            "metric_threshold": 0.9
        }
        ```
*   **`default_cause_confidence`**: (Float, e.g., 0.75) The default confidence score assigned when a rule is triggered.

### 4. `rca_explainer_config`

Configures the `SimpleRCAExplainer`. (Currently minimal as the explainer is template-based, but could hold template strings or logic switches in the future).

### 5. `feature_engineering`

Configures the `FeatureEngineer` class (`src/Python/predictive/feature_engineering.py`).

*   **`original_numerical_features`**: (List of strings) Numerical columns from the raw dataset to be retained and used as base features.
*   **`original_categorical_features`**: (List of strings) Categorical columns from the raw dataset to be retained.
*   **`statistical_feature_columns`**: (List of strings) Numerical columns on which to generate statistical features (rolling means, lags, etc.).
*   **`rolling_window_sizes`**: (List of integers, e.g., `[3, 5, 10]`) Window sizes for rolling statistical features.
*   **`lags`**: (List of integers, e.g., `[1, 2, 3]`) Lag periods for generating lag features.
*   **`interaction_feature_columns`**: (List of strings) Numerical columns to use for creating interaction features (products, ratios, etc.).
*   **`numerical_nan_fill_strategy`**: (String, e.g., 'mean', 'median', 'zero', or a specific number) Strategy for filling NaNs in numerical columns.
*   **`categorical_nan_fill_strategy`**: (String, e.g., 'mode', 'unknown', or a specific string) Strategy for filling NaNs in categorical columns.
*   **`feature_selection_k`**: (Integer or string 'all', e.g., 20) Number of top features to select using `SelectKBest`. If 'all', all features are kept.
*   **`feature_selection_score_func`**: (String, e.g., 'f_classif', 'f_regression') Scoring function for `SelectKBest`.

### 6. `model_config`

Configures the `ArcModelTrainer` class (`src/Python/predictive/model_trainer.py`).

*   **`test_split_ratio`**: (Float, e.g., 0.2) Proportion of the dataset to allocate to the test set during model training.
*   **`random_state`**: (Integer, e.g., 42) Seed for random operations for reproducibility.
*   **`features` (nested object, per model type)**:
    *   Example for `health_prediction`:
        ```json
        "health_prediction": {
            "required_features_is_output_of_fe": true, // If true, trainer expects features listed here to come from FeatureEngineer's output
            "required_features": ["engineered_feat1", "cpu_usage_rolling3_mean", ...], // List of feature names
            "target_column": "is_healthy",
            "missing_strategy": "mean" // For ArcModelTrainer's internal prepare_data, if FE didn't run or left NaNs
        }
        ```
    *   `required_features_is_output_of_fe`: (Boolean) If `true`, `ArcModelTrainer` assumes the features listed in `required_features` are the *output names* from a prior `FeatureEngineer` run. If `false` (or not present), it assumes `required_features` are columns from the *original* dataset passed to `ArcModelTrainer`. This allows flexibility in whether `FeatureEngineer` is run as a separate preceding step or if `ArcModelTrainer` works on a pre-selected raw feature set. **Note**: The current integration tests for `ArcModelTrainer` (Step 13) adapt this list to be the engineered feature names.
    *   `target_column`: Name of the target variable for supervised models.
    *   `missing_strategy`: Fallback NaN handling strategy within `ArcModelTrainer.prepare_data`.
*   **`models` (nested object, per model type)**:
    *   Specifies hyperparameters for scikit-learn models. Example for `health_prediction` (RandomForestClassifier):
        ```json
        "health_prediction": {
            "n_estimators": 100,
            "max_depth": 10,
            "random_state": 42,
            "class_weight": "balanced"
        }
        ```
    *   Example for `anomaly_detection` (IsolationForest):
        ```json
        "anomaly_detection": {
            "n_estimators": 100,
            "contamination": "auto",
            "random_state": 42
        }
        ```

### 7. `remediation_learner_config`

Configures the `ArcRemediationLearner` class (`src/Python/predictive/ArcRemediationLearner.py`).

*   **`context_features_to_log`**: (List of strings) Features from the remediation context to store in `success_patterns`.
*   **`success_pattern_threshold`**: (Float, e.g., 0.7) Minimum success rate for a pattern to be considered highly successful.
*   **`success_pattern_min_attempts`**: (Integer, e.g., 5) Minimum attempts for a pattern before its success rate is trusted.
*   **`ai_predictor_failure_threshold`**: (Float, e.g., 0.6) Failure probability threshold from `ArcPredictor` above which a remediation might be suggested.
*   **`log_level`**: (String, e.g., "INFO", "DEBUG") Logging level for the Remediation Learner.


## General Advice

*   **Caution**: Modifying `ai_config.json` can significantly alter the behavior and performance of the AI engine. Changes should be made cautiously and tested.
*   **Component Details**: For a deeper understanding of how each component uses these configurations, refer to `docs/AI-Components.md`.
*   **Iterative Tuning**: Finding optimal configurations, especially for model hyperparameters, feature lists, and thresholds, is an iterative process that typically involves experimentation and validation against your specific data.

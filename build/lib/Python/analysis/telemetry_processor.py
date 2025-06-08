import pandas as pd
import numpy as np
from typing import Dict, List, Any, Optional, Tuple
from datetime import datetime, timedelta
import logging
from sklearn.preprocessing import StandardScaler
from sklearn.decomposition import PCA
from scipy.fft import rfft, rfftfreq
from scipy.stats import linregress

class TelemetryProcessor:
    def __init__(self, config: Dict[str, Any]):
        self.config = config
        self.scaler = StandardScaler()
        self.pca = PCA(n_components=0.95)  # Preserve 95% of variance
        self.setup_logging()

    def setup_logging(self):
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            filename=f'telemetry_processor_{datetime.now().strftime("%Y%m%d")}.log'
        )
        self.logger = logging.getLogger('TelemetryProcessor')

    def process_telemetry(self, telemetry_data: Dict[str, Any]) -> Dict[str, Any]:
        """Process raw telemetry data into structured insights."""
        try:
            # Convert raw data to DataFrame
            df = self._prepare_data(telemetry_data)

            # Extract features
            features = self._extract_features(df)

            # Detect anomalies
            anomalies = self._detect_anomalies(features)

            # Analyze trends
            trends = self._analyze_trends(df)

            # Generate insights
            insights = self._generate_insights(features, anomalies, trends)

            return {
                'processed_data': features,
                'anomalies': anomalies,
                'trends': trends,
                'insights': insights,
                'timestamp': datetime.now().isoformat()
            }

        except Exception as e:
            self.logger.error(f"Telemetry processing failed: {str(e)}")
            raise

    def _prepare_data(self, telemetry_data: Dict[str, Any]) -> pd.DataFrame:
        """Prepare and clean telemetry data."""
        try:
            # Convert to DataFrame
            df = pd.DataFrame(telemetry_data)

            # Handle missing values
            df = self._handle_missing_values(df)

            # Convert timestamps
            if 'timestamp' in df.columns:
                df['timestamp'] = pd.to_datetime(df['timestamp'])

            # Remove duplicates
            df = df.drop_duplicates()

            # Sort by timestamp if available
            if 'timestamp' in df.columns:
                df = df.sort_values('timestamp')

            return df

        except Exception as e:
            self.logger.error(f"Data preparation failed: {str(e)}")
            raise

    def _handle_missing_values(self, df: pd.DataFrame) -> pd.DataFrame:
        """Handle missing values in telemetry data."""
        try:
            self.logger.info("Handling missing values...")
            for col in df.select_dtypes(include=np.number).columns:
                fill_value = df[col].mean()
                df[col] = df[col].fillna(fill_value)
                self.logger.debug(f"Filled NaNs in numerical column '{col}' with mean: {fill_value}")

            for col in df.select_dtypes(include='object').columns:
                fill_value = 'unknown'
                df[col] = df[col].fillna(fill_value)
                self.logger.debug(f"Filled NaNs in categorical column '{col}' with '{fill_value}'")

            # Also handle potential NaNs in boolean columns if any, fill with False or mode
            for col in df.select_dtypes(include='bool').columns:
                fill_value = False # Or df[col].mode()[0] if prefer mode
                df[col] = df[col].fillna(fill_value)
                self.logger.debug(f"Filled NaNs in boolean column '{col}' with {fill_value}")

            return df
        except Exception as e:
            self.logger.error(f"Missing value handling failed: {str(e)}")
            # In case of error, return dataframe as is, or an empty one if df is compromised
            return df # Or pd.DataFrame() if appropriate

    def _extract_features(self, df: pd.DataFrame) -> Dict[str, Any]:
        """Extract relevant features from telemetry data."""
        features = {}

        try:
            # Performance metrics
            if 'cpu_usage' in df.columns:
                features['cpu'] = {
                    'average': df['cpu_usage'].mean(),
                    'max': df['cpu_usage'].max(),
                    # Trend calculation requires a time axis, pass it if available
                    'trend': self._calculate_trend(df['cpu_usage'], pd.Series(np.arange(len(df)))) # Basic trend if no time
                }

            if 'memory_usage' in df.columns:
                features['memory'] = {
                    'average': df['memory_usage'].mean(),
                    'max': df['memory_usage'].max(),
                    'trend': self._calculate_trend(df['memory_usage'], pd.Series(np.arange(len(df))))
                }

            # Error metrics
            if 'error_count' in df.columns:
                features['errors'] = {
                    'total': df['error_count'].sum(),
                    'trend': self._calculate_trend(df['error_count'], pd.Series(np.arange(len(df))))
                }

            # Network metrics
            if 'network_latency' in df.columns:
                features['network'] = {
                    'average_latency': df['network_latency'].mean(),
                    'max_latency': df['network_latency'].max(),
                    'trend': self._calculate_trend(df['network_latency'], pd.Series(np.arange(len(df))))
                }

            # Calculate derived features
            # The _extract_features method should produce a flat dictionary.
            # Let's assume it does for now, or adjust _extract_features if it's still nested.
            # For this refactoring, we'll assume _extract_features is changed to return a flat dict.
            # Example: features['cpu_average'] = df['cpu_usage'].mean() (This change is not part of this subtask for _extract_features itself)
            # However, _calculate_derived_features is separate and already returns a flat dict.
            # So, the input to _prepare_feature_matrix will be a combination of basic aggregated features and derived ones.

            # Let's create a flattened dictionary for all features to be used by _prepare_feature_matrix
            all_extracted_features = {}
            # Basic aggregations (assuming _extract_features puts them directly into `features` dict or a sub-dict)
            # This part needs alignment with how _extract_features structures its output.
            # For now, let's assume _extract_features is modified to return a flat dict:
            # features['cpu_average'] = df['cpu_usage'].mean()
            # features['cpu_max'] = df['cpu_usage'].max()
            # ... and so on for memory, errors, network.
            # This is a significant change to _extract_features's current structure.
            # I will proceed assuming _extract_features provides a flat dict or I make it flat here.

            # Simplified example of flattening (actual flattening depends on _extract_features's real output)
            if 'cpu' in features and isinstance(features['cpu'], dict): # Current structure
                for k, v in features['cpu'].items():
                    if isinstance(v, (int, float)): all_extracted_features[f'cpu_{k}'] = v
            if 'memory' in features and isinstance(features['memory'], dict):
                for k, v in features['memory'].items():
                    if isinstance(v, (int, float)): all_extracted_features[f'memory_{k}'] = v
            if 'errors' in features and isinstance(features['errors'], dict):
                for k, v in features['errors'].items():
                    if isinstance(v, (int, float)): all_extracted_features[f'errors_{k}'] = v
            if 'network' in features and isinstance(features['network'], dict):
                 for k, v in features['network'].items():
                    if isinstance(v, (int, float)): all_extracted_features[f'network_{k}'] = v

            # Add derived features (which are already flat)
            if 'derived' in features and isinstance(features['derived'], dict):
                all_extracted_features.update(features['derived'])

            return all_extracted_features # Return the flat dictionary

        except Exception as e:
            self.logger.error(f"Feature extraction failed: {str(e)}")
            raise

    def _prepare_feature_matrix(self, flattened_features: Dict[str, float]) -> Tuple[Optional[np.ndarray], List[str]]:
        """Prepare feature matrix for anomaly detection from a flat dictionary of features.
        Features are selected based on self.config['anomaly_detection_features'].
        Returns a 2D numpy array (single row) and a list of feature names used.
        Returns (None, []) if no features can be extracted.
        """
        try:
            self.logger.info("Preparing feature matrix from flattened_features...")
            feature_values = []
            feature_names_used = []

            # Get the list of features to use for anomaly detection from config
            # If not specified, it defaults to an empty list, meaning no features will be selected.
            configured_feature_list = self.config.get('anomaly_detection_features', [])
            if not configured_feature_list:
                self.logger.warning("No features configured in 'anomaly_detection_features'. Feature matrix will be empty.")
                return None, []

            for feature_name in configured_feature_list:
                value = flattened_features.get(feature_name)
                if value is None:
                    self.logger.warning(f"Feature '{feature_name}' not found in flattened_features. Using 0 as default.")
                    feature_values.append(0.0) # Default value for missing configured features
                elif isinstance(value, (int, float)) and not np.isnan(value) and not np.isinf(value):
                    feature_values.append(float(value))
                else:
                    self.logger.warning(f"Invalid value for feature '{feature_name}': {value}. Using 0 as default.")
                    feature_values.append(0.0) # Default for non-numeric or NaN/Inf values
                feature_names_used.append(feature_name)

            if not feature_values:
                self.logger.warning("No numerical features extracted for the feature matrix based on configuration.")
                return None, []

            self.logger.debug(f"Prepared feature matrix with {len(feature_names_used)} features: {feature_names_used}")
            return np.array([feature_values]), feature_names_used # Return 2D array (1 sample, N features)
        except Exception as e:
            self.logger.error(f"Feature matrix preparation failed: {str(e)}")
            return None, []

    def _get_anomalous_features(self,
                                 feature_vector: np.ndarray,
                                 feature_names: List[str]
                                 ) -> Dict[str, Any]:
        """Returns a dictionary of feature_name: value for the anomalous feature vector."""
        try:
            self.logger.info("Extracting feature values for the anomalous sample...")
            if len(feature_vector) != len(feature_names):
                self.logger.error("Mismatch between feature vector length and feature names length.")
                return {"error": "Feature name/value mismatch during anomalous feature extraction."}

            anomalous_feature_values = {}
            for i, name in enumerate(feature_names):
                anomalous_feature_values[name] = feature_vector[i]

            self.logger.debug(f"Anomalous feature values: {anomalous_feature_values}")
            return anomalous_feature_values
        except Exception as e:
            self.logger.error(f"Anomalous feature value extraction failed: {str(e)}")
            return {"error": str(e)}

    def _detect_anomalies(self, extracted_features: Dict[str, Any]) -> Dict[str, Any]:
        """Detect anomalies in telemetry data using the prepared feature matrix."""
        anomalies = {
            'detected': False,
            'details': []
        }

        try:
            # Prepare feature matrix using the new _prepare_feature_matrix
            # Note: extracted_features is assumed to be a flat dictionary here.
            feature_matrix, feature_names_used = self._prepare_feature_matrix(extracted_features)

            if feature_matrix is None or feature_matrix.size == 0:
                self.logger.warning("Skipping anomaly detection due to empty or invalid feature matrix.")
                anomalies['details'].append({"error": "Feature matrix could not be prepared."})
                return anomalies

            # Fit the scaler and PCA only if they haven't been fitted, or if fitting per batch is intended.
            # For now, let's assume fit_transform for simplicity, implying they are refitted each call.
            # In production, scalers/PCA should be fitted on a representative training set and then only transform used.
            scaled_features = self.scaler.fit_transform(feature_matrix)

            if scaled_features.shape[0] == 0:
                 self.logger.warning("Scaled features are empty. Skipping PCA.")
                 pca_features = scaled_features
            elif isinstance(self.pca.n_components, float) and self.pca.n_components < 1.0 and scaled_features.shape[1] < 2:
                 self.logger.warning(f"PCA n_components is {self.pca.n_components} but only {scaled_features.shape[1]} feature(s) available. Skipping PCA.")
                 pca_features = scaled_features
            elif isinstance(self.pca.n_components, int) and self.pca.n_components > scaled_features.shape[1]:
                 self.logger.warning(f"PCA n_components ({self.pca.n_components}) is greater than number of features ({scaled_features.shape[1]}). Adjusting n_components.")
                 self.pca.n_components = scaled_features.shape[1] # Adjust n_components
                 pca_features = self.pca.fit_transform(scaled_features)
            else:
                 pca_features = self.pca.fit_transform(scaled_features)

            if pca_features.size == 0:
                self.logger.warning("PCA features are empty, skipping Mahalanobis distance calculation.")
                anomalies['details'].append({"error": "PCA resulted in empty features."})
                return anomalies

            distances = self._calculate_mahalanobis_distance(pca_features)

            # Use a configured percentile or a default if not specified
            anomaly_threshold_percentile = self.config.get('anomaly_threshold_percentile', 95.0)
            threshold_value = np.percentile(distances, anomaly_threshold_percentile)

            anomaly_indices = np.where(distances > threshold_value)[0]

            if len(anomaly_indices) > 0:
                anomalies['detected'] = True
                # feature_matrix[0] contains the values of the features that were used for this one sample.
                # feature_names_used is the corresponding list of names for these features.
                anomalous_feature_values = self._get_anomalous_features(
                    feature_matrix[0],
                    feature_names_used
                )
                anomalies['details'].append({
                    'distance_score': float(distances[anomaly_indices[0]]), # Assuming one anomaly for now
                    'threshold_value': float(threshold_value),
                    'anomalous_feature_values': anomalous_feature_values
                })
            return anomalies
        except Exception as e:
            self.logger.error(f"Anomaly detection failed: {str(e)}", exc_info=True)
            return { 'detected': False, 'details': [{'error': str(e)}] }


    def _calculate_period_trends(self, df_period: pd.DataFrame) -> Dict[str, Any]:
        """Calculate trends for specified numerical columns in a given DataFrame period."""
        try:
            self.logger.info(f"Calculating period trends for a dataframe with shape {df_period.shape}...")
            trends = {}
            if df_period.empty:
                self.logger.warning("Input DataFrame for period trends is empty.")
                return trends

            if 'timestamp' not in df_period.columns:
                self.logger.warning("Timestamp column not found for period trend calculation. Trends will be calculated against index.")
                # Create a numeric time axis based on index if timestamp is missing
                time_numeric = np.arange(len(df_period))
            else:
                df_period = df_period.sort_values(by='timestamp') # Ensure data is sorted
                time_numeric = (df_period['timestamp'] - df_period['timestamp'].min()).dt.total_seconds()

            # Determine which features to calculate trends for
            trend_feature_list = self.config.get('trend_features', [])
            if not trend_feature_list: # If empty, use all numerical columns
                trend_feature_list = df_period.select_dtypes(include=np.number).columns.tolist()

            for col_name in trend_feature_list:
                if col_name not in df_period.columns:
                    self.logger.warning(f"Trend feature '{col_name}' not found in DataFrame. Skipping.")
                    continue
                if not pd.api.types.is_numeric_dtype(df_period[col_name]):
                    self.logger.warning(f"Trend feature '{col_name}' is not numeric. Skipping.")
                    continue

                series_data = df_period[col_name]

                # Align time_numeric and current column data, removing NaNs from both
                valid_indices = pd.Series(time_numeric).notna() & series_data.notna()

                if valid_indices.sum() < 3: # linregress needs at least 3 points for meaningful p-value
                    trends[col_name] = {'slope': 0.0, 'intercept': 0.0, 'r_value': 0.0, 'p_value': 1.0, 'stderr': 0.0, 'significant': False, 'direction': 'stable'}
                    self.logger.debug(f"Skipping trend for column '{col_name}' due to insufficient data points ({valid_indices.sum()}).")
                    continue

                current_time_numeric = time_numeric[valid_indices]
                current_col_data = series_data[valid_indices]

                try:
                    slope, intercept, r_value, p_value, stderr = linregress(current_time_numeric, current_col_data)

                    direction = 'stable'
                    # Use a threshold for slope magnitude to determine if trend is increasing/decreasing
                    slope_threshold = self.config.get('trend_slope_threshold', 0.05)
                    if slope > slope_threshold: direction = 'increasing'
                    elif slope < -slope_threshold: direction = 'decreasing'

                    p_value_threshold = self.config.get('trend_p_value_threshold', 0.05)
                    significant = p_value < p_value_threshold

                    trends[col_name] = {
                        'slope': float(slope),
                        'intercept': float(intercept),
                        'r_value': float(r_value),
                        'p_value': float(p_value),
                        'stderr': float(stderr),
                        'significant': significant,
                        'direction': direction
                    }
                    self.logger.debug(f"Calculated trend for column '{col_name}': {trends[col_name]}")
                except Exception as e_linregress:
                    self.logger.error(f"Linregress failed for column '{col_name}': {str(e_linregress)}")
                    trends[col_name] = {'slope': 0.0, 'intercept': 0.0, 'r_value': 0.0, 'p_value': 1.0, 'stderr': 0.0, 'significant': False, 'direction': 'stable'}
            return trends
        except Exception as e:
            self.logger.error(f"Period trend calculation failed: {str(e)}", exc_info=True)
            return {}

    def _analyze_trends(self, df: pd.DataFrame) -> Dict[str, Any]:
        """Analyze trends in telemetry data for short and long term."""
        """Analyze trends in telemetry data."""
        trends = {
            'short_term': {},
            'long_term': {},
            'patterns': {}
        }

        try:
        trends = {
            'short_term': {}, # Default empty dict
            'long_term': {}   # Default empty dict
        }
        try:
            if 'timestamp' not in df.columns:
                self.logger.warning("Timestamp column missing, cannot perform time-based trend analysis.")
                return trends # patterns will be empty or based on non-time data if _identify_patterns is adapted

            now = datetime.now() # Use a consistent 'now' for period calculations
            short_term_hours = self.config.get('trend_short_term_hours', 1)
            long_term_days = self.config.get('trend_long_term_days', 1)

            short_term_df = df[df['timestamp'] > now - timedelta(hours=short_term_hours)]
            if not short_term_df.empty:
                trends['short_term'] = self._calculate_period_trends(short_term_df)
            else:
                self.logger.info("No data for short-term trend analysis.")

            long_term_df = df[df['timestamp'] > now - timedelta(days=long_term_days)]
            if not long_term_df.empty:
                trends['long_term'] = self._calculate_period_trends(long_term_df)
            else:
                self.logger.info("No data for long-term trend analysis.")

            # _identify_patterns is called by process_telemetry, which is fine.
            # If _analyze_trends was meant to also return patterns, it would call _identify_patterns(df) here.
            # For now, _analyze_trends only returns 'short_term' and 'long_term' trend calculations.
            # The 'patterns' key in the main output of process_telemetry will be populated by a separate call to _identify_patterns.

            return trends
        except Exception as e:
            self.logger.error(f"Trend analysis failed: {str(e)}", exc_info=True)
            return trends # Return default empty trends on error


    def _generate_anomaly_insights(self, anomalies_data: Dict[str, Any]) -> List[Dict[str, Any]]:
        """Generate insights from detected anomalies."""
        insights = []
        try:
            self.logger.info("Generating anomaly insights...")
            if anomalies_data.get('detected'):
                for detail in anomalies_data.get('details', []):
                    if "error" in detail:
                        insights.append({
                            'type': 'anomaly_error',
                            'priority': 'medium',
                            'message': 'Error during anomaly detection process.',
                            'details': detail["error"]
                        })
                        continue

                    # Using the revised _get_anomalous_features output
                    feature_values = detail.get('anomalous_feature_values', {})
                    feature_summary = ", ".join([f"{name} ({value:.2f})" if isinstance(value, float) else f"{name} ({value})"
                                                 for name, value in feature_values.items()])

                    insights.append({
                        'type': 'anomaly',
                        'priority': 'high',
                        'message': f"Anomaly detected with score {detail.get('distance_score', 0):.2f} (threshold: {detail.get('threshold_value', 0):.2f}).",
                        'details': f"Contributing feature values: {feature_summary if feature_summary else 'N/A'}. Raw data: {feature_values}"
                    })
            return insights
        except Exception as e:
            self.logger.error(f"Anomaly insight generation failed: {str(e)}", exc_info=True)
            return [{'type': 'error', 'priority': 'high', 'message': 'Anomaly insight generation failed', 'details': str(e)}]

    def _generate_trend_insights(self, trends_data: Dict[str, Any]) -> List[Dict[str, Any]]:
        """Generate insights from trend analysis using p-value for significance."""
        insights = []
        try:
            self.logger.info("Generating trend insights...")
            p_value_threshold = self.config.get('trend_p_value_threshold', 0.05)

            for period_type, period_trends in trends_data.items():
                if not isinstance(period_trends, dict): continue
                for feature, trend_info in period_trends.items():
                    if not isinstance(trend_info, dict): continue

                    # Check for significance using p-value
                    if trend_info.get('p_value', 1.0) < p_value_threshold and trend_info.get('direction') != 'stable':
                        insights.append({
                            'type': 'trend',
                            'priority': 'medium',
                            'component': feature,
                            'period': period_type,
                            'message': f"Significant {trend_info['direction']} trend detected for '{feature}' in {period_type.replace('_', ' ')}.",
                            'details': (f"Slope: {trend_info.get('slope'):.3f}, "
                                        f"R-value: {trend_info.get('r_value'):.2f}, "
                                        f"P-value: {trend_info.get('p_value'):.3g}, "
                                        f"Stderr: {trend_info.get('stderr'):.3f}")
                        })
            return insights
        except Exception as e:
            self.logger.error(f"Trend insight generation failed: {str(e)}", exc_info=True)
            return [{'type': 'error', 'priority': 'high', 'message': 'Trend insight generation failed', 'details': str(e)}]


    def _generate_insights(
        self,
        # 'features' here is the flat dictionary from _extract_features
        extracted_features: Dict[str, Any],
        anomalies_result: Dict[str, Any],
        trends_result: Dict[str, Any]
    ) -> List[Dict[str, Any]]:
        """Generate actionable insights from analyzed data."""
        insights = []
        try:
            # Performance insights (can still use parts of extracted_features if needed, e.g., direct averages)
            insights.extend(self._generate_performance_insights(extracted_features))

            # Anomaly insights
            if anomalies_result.get('detected', False):
                insights.extend(self._generate_anomaly_insights(anomalies_result))

            # Trend insights
            insights.extend(self._generate_trend_insights(trends_result))

            # Pattern insights (if _identify_patterns returns insights directly)
            # Or, process output of _identify_patterns to generate insights here.
            # For now, assuming _identify_patterns's output might be directly usable or processed elsewhere.

            # Prioritize insights
            insights = sorted(insights, key=lambda x: x.get('priority_score', 0.5), reverse=True) # Assuming priority_score

            return insights

        except Exception as e:
            self.logger.error(f"Insight generation failed: {str(e)}", exc_info=True)
            return [{'type': 'error', 'priority': 'high', 'message': 'Insight generation failed', 'details': str(e)}]

    def _calculate_trend(self, series: pd.Series, time_numeric: pd.Series) -> Dict[str, Any]:
        """Calculate trend statistics for a time series against a numeric time axis.
        This is a helper and might be deprecated if _calculate_period_trends directly uses linregress.
        For now, keeping it as polyfit based if _calculate_period_trends logic is complex.
        Given the new _calculate_period_trends uses linregress, this specific _calculate_trend
        might become redundant or be refactored to also use linregress if kept.
        Let's assume _calculate_period_trends is the primary method using linregress.
        This method can be removed or updated. For now, let's update it to match linregress for consistency
        if it were to be used by other parts of _extract_features (which it is currently).
        """
        if len(series) < 2 or len(time_numeric) < 2 or len(series) != len(time_numeric) :
             return {'slope': 0.0, 'intercept': 0.0, 'r_value': 0.0, 'p_value': 1.0, 'stderr': 0.0, 'significant': False, 'direction': 'stable'}

        try:
            slope, intercept, r_value, p_value, stderr = linregress(time_numeric, series)
            direction = 'stable'
            slope_threshold = self.config.get('trend_slope_threshold', 0.05)
            if slope > slope_threshold: direction = 'increasing'
            elif slope < -slope_threshold: direction = 'decreasing'

            p_value_threshold = self.config.get('trend_p_value_threshold', 0.05)
            significant = p_value < p_value_threshold

            return {
                'slope': float(slope),
                'intercept': float(intercept),
                'r_value': float(r_value),
                'p_value': float(p_value),
                'stderr': float(stderr),
                'significant': significant,
                'direction': direction
            }
        except Exception as e:
            self.logger.error(f"Error in _calculate_trend for series of length {len(series)}: {e}", exc_info=True)
            return {'slope': 0.0, 'intercept': 0.0, 'r_value': 0.0, 'p_value': 1.0, 'stderr': 0.0, 'significant': False, 'direction': 'stable'}


    def _calculate_mahalanobis_distance(self, features: np.ndarray) -> np.ndarray:
        """Calculate Mahalanobis distance for anomaly detection."""
        if features.ndim == 1: # Handle 1D array case by reshaping
            features = features.reshape(-1, 1)
        if features.shape[0] < 2 : # Not enough samples to calculate covariance robustly
            self.logger.warning("Not enough samples for Mahalanobis distance, returning zero distances.")
            return np.zeros(features.shape[0])

        try:
            covariance = np.cov(features, rowvar=False) # rowvar=False as features are column vectors
            if np.isscalar(covariance): # Handle case where covariance is scalar (e.g. single feature)
                covariance = np.array([[covariance]])

            # Check for singularity before inverting
            if np.linalg.matrix_rank(covariance) < covariance.shape[0]:
                self.logger.warning("Covariance matrix is singular, using pseudo-inverse.")
                inv_covariance = np.linalg.pinv(covariance)
            else:
                inv_covariance = np.linalg.inv(covariance)

            mean = np.mean(features, axis=0)

            distances = []
            for row in features:
                diff = row - mean
                # Ensure diff is 1D for dot product consistency
                diff = diff.flatten()
                distance = np.sqrt(diff.dot(inv_covariance).dot(diff.T)) # Use diff.T for correct dimensions
                distances.append(distance)

            return np.array(distances)
        except np.linalg.LinAlgError as e:
            self.logger.error(f"Linear algebra error in Mahalanobis calculation: {str(e)}. Returning zero distances.")
            return np.zeros(features.shape[0])
        except Exception as e:
            self.logger.error(f"Unexpected error in Mahalanobis calculation: {str(e)}. Returning zero distances.")
            return np.zeros(features.shape[0])


    def _detect_periodic_patterns(self, df: pd.DataFrame) -> Dict[str, Any]:
        """Detect periodic patterns in numerical columns of telemetry data using FFT."""
        try:
            self.logger.info("Detecting periodic patterns...")
            patterns = {}
            if df.empty:
                self.logger.warning("DataFrame is empty for periodic pattern detection.")
                return patterns
            if 'timestamp' not in df.columns:
                self.logger.warning("Timestamp column is missing for periodic pattern detection. Skipping FFT analysis.")
                return patterns

            df_sorted = df.sort_values(by='timestamp').reset_index(drop=True)
            time_diffs = df_sorted['timestamp'].diff().dt.total_seconds()

            if len(time_diffs) < 2 : # Need at least 2 points to get a diff
                 self.logger.warning("Not enough data points to determine sampling rate for FFT.")
                 return patterns

            # Use median diff for more robust sampling rate against outliers, ignore NaNs from first diff
            median_time_diff_seconds = time_diffs.iloc[1:].median()

            if pd.isna(median_time_diff_seconds) or median_time_diff_seconds <= 1e-6: # Avoid zero or too small sampling interval
                 self.logger.warning(f"Invalid or zero median sampling interval ({median_time_diff_seconds}s) for FFT. Skipping.")
                 return patterns

            sampling_rate = 1.0 / median_time_diff_seconds # Hz (samples per second)

            fft_feature_list = self.config.get('fft_features', [])
            if not fft_feature_list: # If empty, use all numerical columns
                fft_feature_list = df_sorted.select_dtypes(include=np.number).columns.tolist()

            for col_name in fft_feature_list:
                if col_name not in df_sorted.columns or not pd.api.types.is_numeric_dtype(df_sorted[col_name]):
                    self.logger.debug(f"Skipping FFT for non-numeric or missing column: {col_name}")
                    continue

                series_data = df_sorted[col_name].fillna(df_sorted[col_name].mean()).values

                if len(series_data) < 3: # Meaningful FFT needs at least a few points
                    self.logger.debug(f"Skipping FFT for column '{col_name}' due to insufficient data points ({len(series_data)}).")
                    continue

                N = len(series_data)
                yf = rfft(series_data - np.mean(series_data)) # Remove DC component
                xf = rfftfreq(N, 1 / sampling_rate) # Frequencies

                idx_start = 1 if (len(xf) > 0 and xf[0] == 0) else 0
                if len(xf) <= idx_start or len(yf) <= idx_start: continue

                magnitudes = np.abs(yf[idx_start:])
                frequencies = xf[idx_start:]

                if len(magnitudes) == 0: continue

                # Configurable number of top frequencies
                num_top_frequencies = self.config.get('fft_num_top_frequencies', 3)
                dominant_indices = np.argsort(magnitudes)[-min(num_top_frequencies, len(magnitudes)):][::-1]

                top_periods_for_col = []
                min_amplitude_threshold = self.config.get('fft_min_amplitude_threshold', 0.1)

                for i in dominant_indices:
                    freq = frequencies[i]
                    amplitude = magnitudes[i] / (N/2) # Normalize amplitude
                    if freq > 1e-9:
                        period_seconds = 1 / freq
                        # Define min/max period based on sampling rate and data length
                        min_meaningful_period = 2 * median_time_diff_seconds
                        max_meaningful_period = (N / 2) * median_time_diff_seconds

                        if period_seconds >= min_meaningful_period and \
                           period_seconds <= max_meaningful_period and \
                           amplitude >= min_amplitude_threshold:
                             top_periods_for_col.append({
                                 "period_seconds": round(period_seconds, 2),
                                 "amplitude": round(amplitude, 2),
                                 "frequency_hz": round(freq, 4)
                             })
                if top_periods_for_col:
                    patterns[col_name] = top_periods_for_col
                    self.logger.debug(f"Detected periodic patterns for column '{col_name}': {top_periods_for_col}")
            return patterns
        except Exception as e:
            self.logger.error(f"Periodic pattern detection failed: {str(e)}", exc_info=True)
            return {}

    def _detect_correlations(self, df: pd.DataFrame) -> Dict[str, Any]:
        """Detect correlations between specified numerical columns in telemetry data."""
        try:
            self.logger.info("Detecting correlations...")
            correlations_output = {"significant_pairs": []} # Initialize with default structure
            if df.empty:
                self.logger.warning("DataFrame is empty for correlation detection.")
                return correlations_output

            correlation_feature_list = self.config.get('correlation_features', [])
            if not correlation_feature_list: # If empty, use all numerical columns
                numerical_df = df.select_dtypes(include=np.number)
            else:
                # Select only specified and existing numeric columns
                valid_cols = [col for col in correlation_feature_list if col in df.columns and pd.api.types.is_numeric_dtype(df[col])]
                if not valid_cols:
                    self.logger.info("No valid numeric columns specified or found for correlation.")
                    return correlations_output
                numerical_df = df[valid_cols]

            if numerical_df.shape[1] < 2:
                self.logger.info(f"Not enough numerical columns ({numerical_df.shape[1]}) to calculate correlations.")
                return correlations_output

            corr_matrix = numerical_df.corr(method='pearson')

            correlation_threshold = self.config.get('correlation_threshold', 0.8)
            significant_corrs = []
            for i in range(len(corr_matrix.columns)):
                for j in range(i + 1, len(corr_matrix.columns)):
                    col1 = corr_matrix.columns[i]
                    col2 = corr_matrix.columns[j]
                    corr_value = corr_matrix.iloc[i, j]

                    if pd.notna(corr_value) and abs(corr_value) >= correlation_threshold:
                        strength = "strong" if abs(corr_value) >= self.config.get('strong_correlation_threshold', 0.9) else "moderate"
                        significant_corrs.append({
                            "pair": (col1, col2),
                            "correlation_coefficient": round(corr_value, 3),
                            "strength": strength
                        })

            if significant_corrs:
                correlations_output["significant_pairs"] = significant_corrs
                self.logger.debug(f"Detected significant correlations: {significant_corrs}")

            return correlations_output
        except Exception as e:
            self.logger.error(f"Correlation detection failed: {str(e)}", exc_info=True)
            return {"significant_pairs": []} # Return default on error

    def _detect_anomalous_patterns(self, df: pd.DataFrame) -> Dict[str, Any]:
        """Detect anomalous patterns based on multi-metric rules defined in config."""
        try:
            self.logger.info("Detecting multi-metric anomalous patterns...")
            detected_patterns = {}
            if df.empty:
                self.logger.warning("DataFrame is empty for anomalous pattern detection.")
                return detected_patterns

            rules = self.config.get('multi_metric_anomaly_rules', [])
            if not rules:
                self.logger.info("No multi-metric anomaly rules defined in config.")
                return detected_patterns

            for rule in rules:
                rule_name = rule.get('name', 'UnnamedRule')
                conditions = rule.get('conditions', [])
                if not conditions:
                    self.logger.warning(f"Rule '{rule_name}' has no conditions. Skipping.")
                    continue

                # Start with a boolean Series of all True, then AND conditions
                combined_condition = pd.Series([True] * len(df), index=df.index)

                for cond in conditions:
                    metric = cond.get('metric')
                    operator = cond.get('operator')
                    threshold = cond.get('threshold')

                    if not all([metric, operator, threshold is not None]): # threshold can be 0
                        self.logger.warning(f"Invalid condition in rule '{rule_name}': {cond}. Skipping condition.")
                        continue
                    if metric not in df.columns:
                         self.logger.warning(f"Metric '{metric}' in rule '{rule_name}' not found in DataFrame. Skipping condition.")
                         combined_condition = pd.Series([False] * len(df), index=df.index) # Rule cannot be met
                         break # No need to check other conditions for this rule

                    series_metric = df[metric]
                    if operator == '>': condition_met = series_metric > threshold
                    elif operator == '<': condition_met = series_metric < threshold
                    elif operator == '>=': condition_met = series_metric >= threshold
                    elif operator == '<=': condition_met = series_metric <= threshold
                    elif operator == '==': condition_met = series_metric == threshold
                    elif operator == '!=': condition_met = series_metric != threshold
                    else:
                        self.logger.warning(f"Unsupported operator '{operator}' in rule '{rule_name}'. Skipping condition.")
                        continue

                    combined_condition &= condition_met

                if combined_condition.any():
                    occurrences = df[combined_condition].copy() # Get rows where pattern occurred
                    if 'timestamp' in occurrences.columns:
                        # Store timestamps or row indices
                        detected_patterns[rule_name] = {
                            "description": rule.get('description', f"Pattern '{rule_name}' detected."),
                            "severity": rule.get('severity', 'medium'),
                            "count": int(combined_condition.sum()),
                            "occurrences_timestamps": occurrences['timestamp'].dt.isoformat().tolist() if 'timestamp' in occurrences else occurrences.index.tolist()
                        }
                        self.logger.info(f"Detected pattern '{rule_name}' at {len(occurrences)} locations.")
                    else: # No timestamp, just count
                         detected_patterns[rule_name] = {
                            "description": rule.get('description', f"Pattern '{rule_name}' detected."),
                            "severity": rule.get('severity', 'medium'),
                            "count": int(combined_condition.sum())
                        }
            return detected_patterns
        except Exception as e:
            self.logger.error(f"Anomalous pattern detection failed: {str(e)}", exc_info=True)
            return {}

    def _identify_patterns(self, df: pd.DataFrame) -> Dict[str, Any]:
        """Identify various types of patterns in telemetry data."""
        """Identify patterns in telemetry data."""
        patterns = {
            'periodic': self._detect_periodic_patterns(df),
            'correlations': self._detect_correlations(df),
            'anomalous': self._detect_anomalous_patterns(df)
        }
        return patterns

    def _calculate_derived_features(self, df: pd.DataFrame) -> Dict[str, Any]:
        """Calculate derived features from the data."""
        try:
            self.logger.info("Calculating derived features...")
            derived = {}

            # Error Rate (ensure request_count is present and non-zero)
            if 'error_count' in df.columns and 'request_count' in df.columns:
                total_requests = df['request_count'].sum()
                if total_requests > 0:
                    derived['error_rate'] = df['error_count'].sum() / total_requests
                else:
                    derived['error_rate'] = 0.0 # Ensure float
                self.logger.debug(f"Calculated error_rate: {derived['error_rate']}")

            # Resource Utilization Ratio (CPU to Memory)
            if 'cpu_usage' in df.columns and 'memory_usage' in df.columns:
                mean_cpu = df['cpu_usage'].mean()
                mean_memory = df['memory_usage'].mean()
                if mean_memory > 1e-6: # Avoid division by zero or near-zero
                    derived['cpu_to_memory_ratio'] = mean_cpu / mean_memory
                else:
                    derived['cpu_to_memory_ratio'] = np.nan # Or a large number if that's more meaningful
                self.logger.debug(f"Calculated cpu_to_memory_ratio: {derived.get('cpu_to_memory_ratio')}")

            # CPU Usage Volatility (Std Dev of CPU Usage)
            if 'cpu_usage' in df.columns and len(df['cpu_usage'].dropna()) >= 2: # std needs at least 2 points
                derived['cpu_usage_volatility'] = df['cpu_usage'].std()
                self.logger.debug(f"Calculated cpu_usage_volatility: {derived['cpu_usage_volatility']}")
            elif 'cpu_usage' in df.columns: # Not enough data for std
                 derived['cpu_usage_volatility'] = 0.0


            # Memory Usage Trend (Slope of memory usage over time, if timestamp available)
            if 'memory_usage' in df.columns and 'timestamp' in df.columns and len(df) > 1:
                # Ensure timestamp is numeric (e.g., seconds since epoch) for polyfit
                df_sorted = df.sort_values(by='timestamp') # Ensure data is sorted for trend calculation
                time_numeric = (df_sorted['timestamp'] - df_sorted['timestamp'].min()).dt.total_seconds()

                # Align data in case of NaNs for memory_usage and time_numeric
                valid_indices = time_numeric.notna() & df_sorted['memory_usage'].notna()

                if valid_indices.sum() > 1: # Need at least 2 valid, aligned data points
                    slope = np.polyfit(time_numeric[valid_indices], df_sorted['memory_usage'][valid_indices], 1)[0]
                    derived['memory_usage_trend_slope'] = slope
                    self.logger.debug(f"Calculated memory_usage_trend_slope: {slope}")
                else:
                    derived['memory_usage_trend_slope'] = 0.0
            else: # Not enough data or missing columns
                derived['memory_usage_trend_slope'] = 0.0


            # Request Throughput (requests per minute, if timestamp available)
            if 'request_count' in df.columns and 'timestamp' in df.columns and len(df) > 0:
                if len(df) > 1:
                    df_sorted = df.sort_values(by='timestamp')
                    duration_seconds = (df_sorted['timestamp'].max() - df_sorted['timestamp'].min()).total_seconds()
                    if duration_seconds > 0:
                        total_requests = df_sorted['request_count'].sum()
                        derived['requests_per_minute'] = (total_requests / duration_seconds) * 60
                        self.logger.debug(f"Calculated requests_per_minute: {derived['requests_per_minute']}")
                    elif df_sorted['request_count'].sum() > 0 : # duration is zero, but requests exist (e.g. all same timestamp)
                        derived['requests_per_minute'] = np.inf # Effectively infinite if time is zero
                        self.logger.debug(f"Calculated requests_per_minute as Inf due to zero duration with requests.")
                    else: # duration is zero, no requests
                        derived['requests_per_minute'] = 0.0
                else: # Single data point
                    # For a single data point, throughput isn't well-defined over time.
                    # Could be total requests if interval is assumed to be 1 minute, or 0, or NaN.
                    # Let's consider it as total requests in an undefined (but implicitly short) interval.
                    # Or, if we assume it represents a rate over a standard interval (e.g. 1 min), it would be just its value.
                    # For now, let's assign 0 if duration can't be calculated.
                    derived['requests_per_minute'] = 0.0
                    self.logger.debug(f"Calculated requests_per_minute as 0 for single data point.")


            return derived
        except Exception as e:
            self.logger.error(f"Derived feature calculation failed: {str(e)}")
            return {} # Return empty dict on error

    def _generate_performance_insights(self, features: Dict[str, Any]) -> List[Dict[str, Any]]:
        """Generate insights related to performance metrics."""
        insights = []

        # CPU insights
        cpu_features = features.get('cpu', {})
        if cpu_features.get('average', 0) > 80:
            insights.append({
                'type': 'performance',
                'component': 'CPU',
                'priority': 'high',
                'message': 'High CPU utilization detected',
                'details': f"Average CPU usage: {cpu_features.get('average', 0):.2f}%"
            })

        # Memory insights
        memory_features = features.get('memory', {})
        if memory_features.get('average', 0) > 90:
            insights.append({
                'type': 'performance',
                'component': 'Memory',
                'priority': 'high',
                'message': 'High memory utilization detected',
                'details': f"Average memory usage: {memory_features.get('average', 0):.2f}%"
            })

        # Derived feature insights (example)
        derived_features = features.get('derived', {})
        if 'error_rate' in derived_features and derived_features['error_rate'] > 0.1: # Example threshold
            insights.append({
                'type': 'performance',
                'component': 'System',
                'priority': 'medium',
                'message': 'High error rate detected',
                'details': f"Overall error rate: {derived_features['error_rate']:.2%}"
            })


        return insights
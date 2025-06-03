import pandas as pd
import numpy as np
from typing import Dict, List, Any, Optional
from datetime import datetime, timedelta
import logging
from sklearn.preprocessing import StandardScaler
from sklearn.decomposition import PCA

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
            # Placeholder: Fill numerical NaNs with mean, categorical with 'unknown'
            for col in df.select_dtypes(include=np.number).columns:
                df[col] = df[col].fillna(df[col].mean())
            for col in df.select_dtypes(include='object').columns:
                df[col] = df[col].fillna('unknown')
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
                    'trend': self._calculate_trend(df['cpu_usage'])
                }

            if 'memory_usage' in df.columns:
                features['memory'] = {
                    'average': df['memory_usage'].mean(),
                    'max': df['memory_usage'].max(),
                    'trend': self._calculate_trend(df['memory_usage'])
                }

            # Error metrics
            if 'error_count' in df.columns:
                features['errors'] = {
                    'total': df['error_count'].sum(),
                    'trend': self._calculate_trend(df['error_count'])
                }

            # Network metrics
            if 'network_latency' in df.columns:
                features['network'] = {
                    'average_latency': df['network_latency'].mean(),
                    'max_latency': df['network_latency'].max(),
                    'trend': self._calculate_trend(df['network_latency'])
                }

            # Calculate derived features
            features['derived'] = self._calculate_derived_features(df)

            return features

        except Exception as e:
            self.logger.error(f"Feature extraction failed: {str(e)}")
            raise

    def _prepare_feature_matrix(self, features: Dict[str, Any]) -> np.ndarray:
        """Prepare feature matrix for anomaly detection."""
        try:
            self.logger.info("Preparing feature matrix...")
            # Placeholder: Combine some numerical features into a matrix
            # This needs to align with what _detect_anomalies expects
            # For example, if features are like {'cpu': {'average': 60, ...}, 'memory': {'average': 70, ...}}
            feature_list = []
            if 'cpu' in features and 'average' in features['cpu']:
                feature_list.append(features['cpu']['average'])
            if 'memory' in features and 'average' in features['memory']:
                feature_list.append(features['memory']['average'])
            if 'errors' in features and 'total' in features['errors']:
                feature_list.append(features['errors']['total'])

            if not feature_list: # Handle case with no expected features
                return np.array([]).reshape(0,0) # Or handle as error

            return np.array([feature_list]) # Return a 2D array
        except Exception as e:
            self.logger.error(f"Feature matrix preparation failed: {str(e)}")
            return np.array([]).reshape(0,0) # Return empty 2D array

    def _get_anomalous_features(self, feature_vector: np.ndarray, threshold: float) -> Dict[str, Any]:
        """Identify which features contributed to an anomaly."""
        try:
            self.logger.info("Identifying anomalous features...")
            # Placeholder: Based on the structure of feature_vector from _prepare_feature_matrix
            # This is highly dependent on the actual features used.
            # Assuming feature_vector corresponds to [cpu_avg, memory_avg, error_total]
            anomalous_f = {}
            # Example: if a feature's value (hypothetically, if it was directly comparable to threshold)
            # This logic is illustrative; real anomaly contribution is more complex.
            if len(feature_vector) > 0 and feature_vector[0] > threshold * 0.8: # Example condition
                anomalous_f['cpu_average'] = feature_vector[0]
            if len(feature_vector) > 1 and feature_vector[1] > threshold * 0.7: # Example condition
                anomalous_f['memory_average'] = feature_vector[1]
            return anomalous_f
        except Exception as e:
            self.logger.error(f"Anomalous feature identification failed: {str(e)}")
            return {}

    def _detect_anomalies(self, features: Dict[str, Any]) -> Dict[str, Any]:
        """Detect anomalies in telemetry data."""
        anomalies = {
            'detected': False,
            'details': []
        }

        try:
            # Prepare feature matrix
            feature_matrix = self._prepare_feature_matrix(features)
            
            if feature_matrix.size == 0: # Check if feature_matrix is empty
                self.logger.warning("Feature matrix is empty, skipping anomaly detection.")
                return anomalies

            # Scale features
            scaled_features = self.scaler.fit_transform(feature_matrix)
            
            # Apply PCA for dimensionality reduction
            # Ensure scaled_features is not empty and has enough samples for PCA
            if scaled_features.shape[0] < self.pca.n_components and self.pca.n_components is not None and isinstance(self.pca.n_components, int) :
                 self.logger.warning(f"Not enough samples ({scaled_features.shape[0]}) for PCA with n_components={self.pca.n_components}. Skipping PCA.")
                 pca_features = scaled_features
            elif scaled_features.shape[0] == 0 :
                 self.logger.warning("Scaled features are empty. Skipping PCA.")
                 pca_features = scaled_features
            else:
                 pca_features = self.pca.fit_transform(scaled_features)

            if pca_features.size == 0: # Check if pca_features is empty
                self.logger.warning("PCA features are empty, skipping Mahalanobis distance calculation.")
                return anomalies
            
            # Calculate Mahalanobis distance for anomaly detection
            distances = self._calculate_mahalanobis_distance(pca_features)
            
            # Identify anomalies
            threshold = np.percentile(distances, 95)  # 95th percentile as threshold
            anomaly_indices = np.where(distances > threshold)[0]

            if len(anomaly_indices) > 0:
                anomalies['detected'] = True
                for idx in anomaly_indices:
                    anomalies['details'].append({
                        'index': int(idx),
                        'distance': float(distances[idx]),
                        'features': self._get_anomalous_features(feature_matrix[idx], threshold)
                    })

            return anomalies

        except Exception as e:
            self.logger.error(f"Anomaly detection failed: {str(e)}")
            # Ensure a default structure is returned in case of error
            return { 'detected': False, 'details': [] }


    def _calculate_period_trends(self, df: pd.DataFrame) -> Dict[str, Any]:
        """Calculate trends for a given period."""
        try:
            self.logger.info("Calculating period trends...")
            trends = {}
            for col in df.select_dtypes(include=np.number).columns:
                if len(df[col].dropna()) > 1: # Need at least 2 points for trend
                    trends[col] = self._calculate_trend(df[col].dropna())
                else:
                    trends[col] = {'slope': 0, 'r_squared': 0} # Default if no trend calculable
            return trends
        except Exception as e:
            self.logger.error(f"Period trend calculation failed: {str(e)}")
            return {}

    def _analyze_trends(self, df: pd.DataFrame) -> Dict[str, Any]:
        """Analyze trends in telemetry data."""
        trends = {
            'short_term': {},
            'long_term': {},
            'patterns': {}
        }

        try:
            # Analyze short-term trends (last hour)
            short_term_df = df[df['timestamp'] > datetime.now() - timedelta(hours=1)]
            trends['short_term'] = self._calculate_period_trends(short_term_df)

            # Analyze long-term trends (last 24 hours)
            long_term_df = df[df['timestamp'] > datetime.now() - timedelta(days=1)]
            trends['long_term'] = self._calculate_period_trends(long_term_df)

            # Identify patterns
            trends['patterns'] = self._identify_patterns(df)

            return trends

        except Exception as e:
            self.logger.error(f"Trend analysis failed: {str(e)}")
            raise

    def _generate_anomaly_insights(self, anomalies: Dict[str, Any]) -> List[Dict[str, Any]]:
        """Generate insights from detected anomalies."""
        insights = []
        try:
            self.logger.info("Generating anomaly insights...")
            if anomalies.get('detected'):
                for detail in anomalies.get('details', []):
                    insights.append({
                        'type': 'anomaly',
                        'priority': 'high', # Placeholder
                        'message': f"Anomaly detected at index {detail.get('index')}",
                        'details': f"Distance: {detail.get('distance', 0):.2f}, Anomalous Features: {detail.get('features', {})}"
                    })
            return insights
        except Exception as e:
            self.logger.error(f"Anomaly insight generation failed: {str(e)}")
            return []

    def _generate_trend_insights(self, trends: Dict[str, Any]) -> List[Dict[str, Any]]:
        """Generate insights from detected trends."""
        insights = []
        try:
            self.logger.info("Generating trend insights...")
            # Example: Insight for a strong trend in CPU usage (short-term)
            if 'short_term' in trends and 'cpu_usage' in trends['short_term']:
                cpu_trend = trends['short_term']['cpu_usage']
                if abs(cpu_trend.get('slope', 0)) > 0.5 and cpu_trend.get('r_squared', 0) > 0.7: # Strong trend
                    insights.append({
                        'type': 'trend',
                        'priority': 'medium', # Placeholder
                        'message': f"Significant short-term trend in CPU usage: slope {cpu_trend['slope']:.2f}",
                        'details': cpu_trend
                    })
            # Example: Insight for a periodic pattern
            if 'patterns' in trends and 'periodic' in trends['patterns']:
                 for pattern_name, detail in trends['patterns']['periodic'].items():
                    insights.append({
                        'type': 'pattern',
                        'priority': 'low', # Placeholder
                        'message': f"Detected periodic pattern: {pattern_name} - {detail}",
                        'details': trends['patterns']['periodic']
                    })
            return insights
        except Exception as e:
            self.logger.error(f"Trend insight generation failed: {str(e)}")
            return []

    def _generate_insights(
        self,
        features: Dict[str, Any],
        anomalies: Dict[str, Any],
        trends: Dict[str, Any]
    ) -> List[Dict[str, Any]]:
        """Generate actionable insights from analyzed data."""
        insights = []

        try:
            # Performance insights
            if 'cpu' in features:
                insights.extend(self._generate_performance_insights(features))

            # Anomaly insights
            if anomalies.get('detected', False): # Ensure key exists
                insights.extend(self._generate_anomaly_insights(anomalies))

            # Trend insights
            insights.extend(self._generate_trend_insights(trends))

            # Prioritize insights
            insights = sorted(insights, key=lambda x: x.get('priority', 'low'), reverse=True) # Add .get for safety

            return insights

        except Exception as e:
            self.logger.error(f"Insight generation failed: {str(e)}")
            return [] # Return empty list on error

    def _calculate_trend(self, series: pd.Series) -> Dict[str, float]:
        """Calculate trend statistics for a time series."""
        if len(series) < 2: # Not enough data points for trend calculation
            return {'slope': 0, 'r_squared': 0}
        # Ensure series is numeric and does not contain NaNs or Infs that polyfit can't handle
        series = series.astype(float).replace([np.inf, -np.inf], np.nan).dropna()
        if len(series) < 2: # Check again after cleaning
            return {'slope': 0, 'r_squared': 0}

        slope = float(np.polyfit(range(len(series)), series, 1)[0])
        # Calculate r_squared carefully, handle cases with zero variance
        if np.var(series) == 0 or len(series) <2 : # If variance is zero, r_squared is undefined or 1 if also constant x
            r_squared = 1.0 if np.all(series == series.iloc[0]) else 0.0
        else:
            # Ensure no NaNs in series for corrcoef
            valid_indices = ~np.isnan(series)
            if sum(valid_indices) < 2: # Need at least two non-NaN values
                 r_squared = 0.0
            else:
                 # Create range based on actual number of valid (non-NaN) points
                 x_values_for_corr = range(sum(valid_indices))
                 series_for_corr = series[valid_indices]
                 # Check if series_for_corr still has enough points
                 if len(series_for_corr) < 2:
                     r_squared = 0.0
                 else:
                     correlation_matrix = np.corrcoef(x_values_for_corr, series_for_corr)
                     # Check if correlation_matrix is as expected (2x2)
                     if correlation_matrix.shape == (2,2):
                         r_squared = float(correlation_matrix[0, 1]**2)
                     else: # Handle unexpected shape, e.g. if all values in series are identical
                         r_squared = 1.0 if np.all(series_for_corr == series_for_corr.iloc[0]) else 0.0


        return {
            'slope': slope,
            'r_squared': r_squared
        }


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
        """Detect periodic patterns in telemetry data."""
        try:
            self.logger.info("Detecting periodic patterns...")
            # Placeholder
            return {"daily_cpu_peak": "14:00", "weekly_memory_increase": "Fridays"}
        except Exception as e:
            self.logger.error(f"Periodic pattern detection failed: {str(e)}")
            return {}

    def _detect_correlations(self, df: pd.DataFrame) -> Dict[str, Any]:
        """Detect correlations between different metrics."""
        try:
            self.logger.info("Detecting correlations...")
            # Placeholder: Calculate correlation matrix for numerical columns
            numeric_df = df.select_dtypes(include=np.number)
            if numeric_df.shape[1] < 2: # Need at least two numeric columns
                return {}
            
            corr_matrix = numeric_df.corr()
            # Find highly correlated pairs (example threshold)
            strong_correlations = {}
            for i in range(len(corr_matrix.columns)):
                for j in range(i + 1, len(corr_matrix.columns)):
                    if abs(corr_matrix.iloc[i, j]) > 0.8:
                        col1 = corr_matrix.columns[i]
                        col2 = corr_matrix.columns[j]
                        strong_correlations[f"{col1}_vs_{col2}"] = corr_matrix.iloc[i, j]
            return strong_correlations
        except Exception as e:
            self.logger.error(f"Correlation detection failed: {str(e)}")
            return {}

    def _detect_anomalous_patterns(self, df: pd.DataFrame) -> Dict[str, Any]:
        """Detect anomalous sequences or patterns."""
        try:
            self.logger.info("Detecting anomalous patterns...")
            # Placeholder: e.g., identify sequences of high error rates
            anomalous_p = {}
            if 'error_count' in df.columns:
                # Example: Find if there are 3 consecutive high error counts
                rolling_sum_errors = df['error_count'].rolling(window=3).sum()
                if (rolling_sum_errors > 10).any(): # Assuming >10 is a high sum for 3 periods
                    anomalous_p['consecutive_high_errors'] = "Detected sequence of high error counts"
            return anomalous_p
        except Exception as e:
            self.logger.error(f"Anomalous pattern detection failed: {str(e)}")
            return {}

    def _identify_patterns(self, df: pd.DataFrame) -> Dict[str, Any]:
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
            if 'error_count' in df.columns and 'request_count' in df.columns:
                # Ensure request_count is not zero to avoid division by zero
                # Create a temporary series for calculation to avoid SettingWithCopyWarning
                request_count_safe = df['request_count'].replace(0, np.nan)
                derived['error_rate'] = (df['error_count'].sum() / request_count_safe.sum()) if request_count_safe.sum() else 0

            if 'cpu_usage' in df.columns and 'memory_usage' in df.columns:
                # Ensure memory_usage mean is not zero for division
                mean_memory_usage = df['memory_usage'].mean()
                derived['resource_utilization_ratio'] = df['cpu_usage'].mean() / (mean_memory_usage + 1e-6) if mean_memory_usage != 0 else 0
            return derived
        except Exception as e:
            self.logger.error(f"Derived feature calculation failed: {str(e)}")
            return {}

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
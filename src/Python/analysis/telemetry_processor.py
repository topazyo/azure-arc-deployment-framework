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

    def _detect_anomalies(self, features: Dict[str, Any]) -> Dict[str, Any]:
        """Detect anomalies in telemetry data."""
        anomalies = {
            'detected': False,
            'details': []
        }

        try:
            # Prepare feature matrix
            feature_matrix = self._prepare_feature_matrix(features)
            
            # Scale features
            scaled_features = self.scaler.fit_transform(feature_matrix)
            
            # Apply PCA for dimensionality reduction
            pca_features = self.pca.fit_transform(scaled_features)
            
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
            raise

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
            if anomalies['detected']:
                insights.extend(self._generate_anomaly_insights(anomalies))

            # Trend insights
            insights.extend(self._generate_trend_insights(trends))

            # Prioritize insights
            insights = sorted(insights, key=lambda x: x['priority'], reverse=True)

            return insights

        except Exception as e:
            self.logger.error(f"Insight generation failed: {str(e)}")
            raise

    def _calculate_trend(self, series: pd.Series) -> Dict[str, float]:
        """Calculate trend statistics for a time series."""
        return {
            'slope': float(np.polyfit(range(len(series)), series, 1)[0]),
            'r_squared': float(np.corrcoef(range(len(series)), series)[0, 1]**2)
        }

    def _calculate_mahalanobis_distance(self, features: np.ndarray) -> np.ndarray:
        """Calculate Mahalanobis distance for anomaly detection."""
        covariance = np.cov(features.T)
        inv_covariance = np.linalg.inv(covariance)
        mean = np.mean(features, axis=0)
        
        distances = []
        for row in features:
            diff = row - mean
            distance = np.sqrt(diff.dot(inv_covariance).dot(diff))
            distances.append(distance)
            
        return np.array(distances)

    def _identify_patterns(self, df: pd.DataFrame) -> Dict[str, Any]:
        """Identify patterns in telemetry data."""
        patterns = {
            'periodic': self._detect_periodic_patterns(df),
            'correlations': self._detect_correlations(df),
            'anomalous': self._detect_anomalous_patterns(df)
        }
        return patterns

    def _generate_performance_insights(self, features: Dict[str, Any]) -> List[Dict[str, Any]]:
        """Generate insights related to performance metrics."""
        insights = []
        
        # CPU insights
        if features.get('cpu', {}).get('average', 0) > 80:
            insights.append({
                'type': 'performance',
                'component': 'CPU',
                'priority': 'high',
                'message': 'High CPU utilization detected',
                'details': f"Average CPU usage: {features['cpu']['average']:.2f}%"
            })

        # Memory insights
        if features.get('memory', {}).get('average', 0) > 90:
            insights.append({
                'type': 'performance',
                'component': 'Memory',
                'priority': 'high',
                'message': 'High memory utilization detected',
                'details': f"Average memory usage: {features['memory']['average']:.2f}%"
            })

        return insights
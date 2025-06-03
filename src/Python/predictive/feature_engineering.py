import numpy as np
import pandas as pd
from typing import Dict, List, Any, Tuple
from sklearn.preprocessing import StandardScaler, OneHotEncoder
from sklearn.feature_selection import SelectKBest, f_classif
import logging
from datetime import datetime

class FeatureEngineer:
    def __init__(self, config: Dict[str, Any]):
        self.config = config
        self.scalers = {}
        self.encoders = {}
        self.feature_selectors = {}
        self.setup_logging()

    def setup_logging(self):
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            filename=f'feature_engineering_{datetime.now().strftime("%Y%m%d")}.log'
        )
        self.logger = logging.getLogger('FeatureEngineer')

    def engineer_features(
        self,
        data: pd.DataFrame,
        target: str = None
    ) -> Tuple[pd.DataFrame, Dict[str, Any]]:
        """Engineer features for model training or prediction."""
        try:
            # Create temporal features
            temporal_features = self._create_temporal_features(data)
            
            # Create statistical features
            statistical_features = self._create_statistical_features(data)
            
            # Create interaction features
            interaction_features = self._create_interaction_features(data)
            
            # Combine all features
            all_features = pd.concat([
                temporal_features,
                statistical_features,
                interaction_features
            ], axis=1)

            # Scale numerical features
            scaled_features = self._scale_features(all_features)
            
            # Encode categorical features
            encoded_features = self._encode_categorical_features(scaled_features)
            
            # Select best features if target is provided
            if target is not None:
                selected_features = self._select_features(encoded_features, data[target])
            else:
                selected_features = encoded_features

            # Create feature metadata
            feature_metadata = self._create_feature_metadata(selected_features)

            return selected_features, feature_metadata

        except Exception as e:
            self.logger.error(f"Feature engineering failed: {str(e)}")
            raise

    def _create_temporal_features(self, data: pd.DataFrame) -> pd.DataFrame:
        """Create temporal features from timestamp data."""
        temporal_features = pd.DataFrame()
        
        try:
            if 'timestamp' in data.columns:
                timestamp = pd.to_datetime(data['timestamp'])
                
                temporal_features['hour'] = timestamp.dt.hour
                temporal_features['day_of_week'] = timestamp.dt.dayofweek
                temporal_features['day_of_month'] = timestamp.dt.day
                temporal_features['month'] = timestamp.dt.month
                temporal_features['is_weekend'] = timestamp.dt.dayofweek.isin([5, 6]).astype(int)
                
                # Create cyclical features for periodic patterns
                temporal_features['hour_sin'] = np.sin(2 * np.pi * timestamp.dt.hour / 24)
                temporal_features['hour_cos'] = np.cos(2 * np.pi * timestamp.dt.hour / 24)
                temporal_features['month_sin'] = np.sin(2 * np.pi * timestamp.dt.month / 12)
                temporal_features['month_cos'] = np.cos(2 * np.pi * timestamp.dt.month / 12)

        except Exception as e:
            self.logger.error(f"Temporal feature creation failed: {str(e)}")
            raise

        return temporal_features

    def _create_statistical_features(self, data: pd.DataFrame) -> pd.DataFrame:
        """Create statistical features from numerical columns."""
        statistical_features = pd.DataFrame()
        
        try:
            numerical_columns = data.select_dtypes(include=[np.number]).columns
            
            for col in numerical_columns:
                # Rolling statistics
                rolling_window = data[col].rolling(window=self.config.get('rolling_window', 5))
                statistical_features[f'{col}_rolling_mean'] = rolling_window.mean().fillna(0)
                statistical_features[f'{col}_rolling_std'] = rolling_window.std().fillna(0)
                statistical_features[f'{col}_rolling_max'] = rolling_window.max().fillna(0)
                statistical_features[f'{col}_rolling_min'] = rolling_window.min().fillna(0)
                
                # Lag features
                for lag in self.config.get('lags', [1, 3, 5]):
                    statistical_features[f'{col}_lag_{lag}'] = data[col].shift(lag).fillna(0)
                
                # Difference features
                statistical_features[f'{col}_diff'] = data[col].diff().fillna(0)
                statistical_features[f'{col}_pct_change'] = data[col].pct_change().fillna(0)

        except Exception as e:
            self.logger.error(f"Statistical feature creation failed: {str(e)}")
            raise

        return statistical_features

    def _create_interaction_features(self, data: pd.DataFrame) -> pd.DataFrame:
        """Create interaction features between numerical columns."""
        interaction_features = pd.DataFrame()
        
        try:
            numerical_columns = data.select_dtypes(include=[np.number]).columns
            
            # Create polynomial features
            for i, col1 in enumerate(numerical_columns):
                for col2 in numerical_columns[i+1:]:
                    interaction_features[f'{col1}_{col2}_product'] = data[col1] * data[col2]
                    interaction_features[f'{col1}_{col2}_ratio'] = data[col1] / (data[col2] + 1e-8)
                    interaction_features[f'{col1}_{col2}_sum'] = data[col1] + data[col2]
                    interaction_features[f'{col1}_{col2}_diff'] = data[col1] - data[col2]

        except Exception as e:
            self.logger.error(f"Interaction feature creation failed: {str(e)}")
            raise

        return interaction_features

    def _scale_features(self, features: pd.DataFrame) -> pd.DataFrame:
        """Scale numerical features."""
        try:
            numerical_columns = features.select_dtypes(include=[np.number]).columns
            
            if not self.scalers.get('standard'):
                self.scalers['standard'] = StandardScaler()
                scaled_values = self.scalers['standard'].fit_transform(features[numerical_columns])
            else:
                scaled_values = self.scalers['standard'].transform(features[numerical_columns])
            
            scaled_features = pd.DataFrame(
                scaled_values,
                columns=numerical_columns,
                index=features.index
            )
            
            # Add back non-numerical columns
            for col in features.columns:
                if col not in numerical_columns:
                    scaled_features[col] = features[col]

            return scaled_features

        except Exception as e:
            self.logger.error(f"Feature scaling failed: {str(e)}")
            raise

    def _encode_categorical_features(self, features: pd.DataFrame) -> pd.DataFrame:
        """Encode categorical features."""
        try:
            categorical_columns = features.select_dtypes(include=['object', 'category']).columns
            
            encoded_features = features.copy()
            
            for col in categorical_columns:
                if col not in self.encoders:
                    self.encoders[col] = OneHotEncoder(sparse_output=False, handle_unknown='ignore')
                    encoded_values = self.encoders[col].fit_transform(features[[col]])
                else:
                    encoded_values = self.encoders[col].transform(features[[col]])
                
                feature_names = [f"{col}_{val}" for val in self.encoders[col].categories_[0]]
                encoded_df = pd.DataFrame(
                    encoded_values,
                    columns=feature_names,
                    index=features.index
                )
                
                # Add encoded columns and drop original
                encoded_features = pd.concat([encoded_features, encoded_df], axis=1)
                encoded_features.drop(columns=[col], inplace=True)

            return encoded_features

        except Exception as e:
            self.logger.error(f"Feature encoding failed: {str(e)}")
            raise

    def _select_features(
        self,
        features: pd.DataFrame,
        target: pd.Series,
        k: int = None
    ) -> pd.DataFrame:
        """Select most important features using statistical tests."""
        try:
            if k is None:
                k = min(features.shape[1], int(features.shape[1] * 0.8))  # Select 80% of features by default

            if 'selector' not in self.feature_selectors:
                self.feature_selectors['selector'] = SelectKBest(score_func=f_classif, k=k)
                selected_features = self.feature_selectors['selector'].fit_transform(features, target)
            else:
                selected_features = self.feature_selectors['selector'].transform(features)

            selected_columns = features.columns[self.feature_selectors['selector'].get_support()]
            
            return pd.DataFrame(
                selected_features,
                columns=selected_columns,
                index=features.index
            )

        except Exception as e:
            self.logger.error(f"Feature selection failed: {str(e)}")
            raise

    def _create_feature_metadata(self, features: pd.DataFrame) -> Dict[str, Any]:
        """Create metadata for engineered features."""
        return {
            'feature_count': len(features.columns),
            'feature_names': list(features.columns),
            'feature_types': features.dtypes.to_dict(),
            'numerical_features': list(features.select_dtypes(include=[np.number]).columns),
            'categorical_features': list(features.select_dtypes(exclude=[np.number]).columns),
            'missing_values': features.isnull().sum().to_dict(),
            'feature_statistics': features.describe().to_dict()
        }
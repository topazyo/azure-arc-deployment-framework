import numpy as np
import pandas as pd
from typing import Dict, List, Any, Tuple, Optional
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
                # Pass k from config to _select_features
                k_val = self.config.get('selected_k_features')
                selected_features = self._select_features(encoded_features, data[target], k=k_val)
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
        interaction_features = pd.DataFrame(index=data.index) # Ensure index is preserved
        
        try:
            self.logger.info("Creating interaction features...")
            numerical_columns = data.select_dtypes(include=[np.number]).columns
            
            # Limit the number of interaction features to avoid explosion
            # For example, only interact first N numerical columns or specific pairs
            # For now, we'll proceed with all pairs but this can be optimized.

            for i, col1_name in enumerate(numerical_columns):
                for col2_name in numerical_columns[i+1:]: # Avoid self-interaction and duplicate pairs
                    col1 = data[col1_name]
                    col2 = data[col2_name]

                    interaction_features[f'{col1_name}_x_{col2_name}_product'] = col1 * col2

                    # Ratio: ensure col2 is not zero, replace inf with large number or NaN then fill
                    ratio_series = col1 / (col2 + 1e-8)
                    interaction_features[f'{col1_name}_div_{col2_name}_ratio'] = ratio_series.replace([np.inf, -np.inf], np.nan).fillna(0)

                    # Sum and Difference are less prone to extreme values
                    interaction_features[f'{col1_name}_plus_{col2_name}_sum'] = col1 + col2
                    interaction_features[f'{col1_name}_minus_{col2_name}_diff'] = col1 - col2

            # Clip extreme values that might have been created
            if not interaction_features.empty:
                num_cols_interactions = interaction_features.select_dtypes(include=np.number).columns
                for col in num_cols_interactions:
                    # Define lower and upper quantiles for clipping
                    lower_quantile = interaction_features[col].quantile(0.01)
                    upper_quantile = interaction_features[col].quantile(0.99)
                    interaction_features[col] = interaction_features[col].clip(lower=lower_quantile, upper=upper_quantile)

                # Final fillna just in case any new NaNs were introduced and not handled (e.g. from quantiles on all-NaN series)
                interaction_features = interaction_features.fillna(0)

        except Exception as e:
            self.logger.error(f"Interaction feature creation failed: {str(e)}")
            # Return empty dataframe with original index if fails
            return pd.DataFrame(index=data.index)

        return interaction_features

    def _scale_features(self, features: pd.DataFrame) -> pd.DataFrame:
        """Scale numerical features."""
        try:
            numerical_columns = features.select_dtypes(include=[np.number]).columns
            if numerical_columns.empty:
                self.logger.info("No numerical features to scale.")
                return features.copy() # Return a copy
            
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
            if categorical_columns.empty:
                self.logger.info("No categorical features to encode.")
                return features.copy() # Return a copy
            
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
        k: Optional[int] = None # k from config can be passed here
    ) -> pd.DataFrame:
        """Select most important features using statistical tests (f_classif for classification)."""
        try:
            self.logger.info(f"Starting feature selection. Initial number of features: {features.shape[1]}")

            if features.empty:
                self.logger.warning("Feature set is empty before selection. Returning empty DataFrame.")
                return pd.DataFrame()

            if target.isnull().all() or len(target.unique()) < 2 :
                self.logger.warning(f"Target variable for feature selection is all NaN or has fewer than 2 unique values. Skipping selection, returning all features.")
                return features

            # Determine k: number of features to select
            num_available_features = features.shape[1]
            if k is None: # k was not passed from config via engineer_features
                # Use config value if available, else default to 80% or max available
                k_from_config = self.config.get('selected_k_features', int(num_available_features * 0.8))
            else: # k was passed (likely from config)
                k_from_config = k

            if k_from_config <= 0:
                self.logger.info(f"k for feature selection is {k_from_config}, selecting all features.")
                k_to_select = num_available_features
            elif k_from_config >= num_available_features:
                self.logger.info(f"Requested k ({k_from_config}) is >= available features ({num_available_features}). Selecting all {num_available_features} features.")
                k_to_select = num_available_features
            else:
                k_to_select = k_from_config

            self.logger.info(f"Attempting to select {k_to_select} best features.")

            # Ensure no NaN values in features or target before passing to SelectKBest
            # Features DataFrame should ideally be cleaned of NaNs by this point by previous steps
            # (e.g. _scale_features would receive already filled data).
            # Target series also needs to be clean.
            valid_target_indices = target.notna()
            if not valid_target_indices.all():
                self.logger.warning(f"Target series contains NaNs. Applying feature selection only on rows with valid targets.")
                # This could lead to data mismatch if not handled carefully.
                # Alternative: require target to be pre-cleaned or raise error.
                # For now, filter both features and target to valid target rows for selector fitting.
                # This is only for fitting the selector. Transform will apply to all original feature rows.
                features_for_fitting = features[valid_target_indices]
                target_for_fitting = target[valid_target_indices]
                if len(target_for_fitting) < 2 or features_for_fitting.empty : # Check length, not .len()
                    self.logger.error("Not enough valid data for fitting feature selector after NaN removal from target. Returning all features.")
                    return features
            else:
                features_for_fitting = features
                target_for_fitting = target


            # Initialize or retrieve the selector
            selector_key = f"selector_k{k_to_select}" # Store different selectors if k changes
            if selector_key not in self.feature_selectors:
                self.feature_selectors[selector_key] = SelectKBest(score_func=f_classif, k=k_to_select)
                try:
                    # Fit on potentially NaN-free data
                    self.feature_selectors[selector_key].fit(features_for_fitting, target_for_fitting)
                except ValueError as ve:
                    self.logger.error(f"Error fitting SelectKBest (likely due to NaNs or Infs despite checks): {ve}. Returning all features.")
                    # As a fallback, if fit fails (e.g. all features are constant, or some other issue)
                    return features


            # Transform the original features DataFrame
            selected_features_array = self.feature_selectors[selector_key].transform(features)
            selected_columns_mask = self.feature_selectors[selector_key].get_support()

            # Check if mask is all False (no features selected), which can happen if k is too low or fit failed weirdly
            if not np.any(selected_columns_mask):
                self.logger.warning("SelectKBest selected no features. This might be due to issues with data or k value. Returning original features.")
                return features

            selected_columns = features.columns[selected_columns_mask]

            self.logger.info(f"Selected {len(selected_columns)} features: {list(selected_columns)}")
            
            return pd.DataFrame(
                selected_features_array,
                columns=selected_columns,
                index=features.index
            )

        except Exception as e:
            self.logger.error(f"Feature selection failed: {str(e)}")
            # Fallback to returning all features if selection fails
            return features

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
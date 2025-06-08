import numpy as np
import pandas as pd
from typing import Dict, List, Any, Tuple, Optional
from sklearn.preprocessing import StandardScaler, OneHotEncoder
from sklearn.feature_selection import SelectKBest, f_classif, f_regression # Added f_regression
from pandas.api.types import is_numeric_dtype, is_categorical_dtype # Added for type checks
import logging
from datetime import datetime
import os # Not strictly needed by this diff, but good practice

class FeatureEngineer:
    def __init__(self, config: Dict[str, Any]):
        self.config = config
        self.scalers: Dict[str, StandardScaler] = {}
        self.encoders: Dict[str, OneHotEncoder] = {}
        self.feature_selectors: Dict[str, SelectKBest] = {}

        # Initialize common config values with defaults
        self.rolling_window_sizes = self.config.get('rolling_window_sizes', [5]) # Allow multiple window sizes
        if not isinstance(self.rolling_window_sizes, list): self.rolling_window_sizes = [self.rolling_window_sizes]
        self.lags = self.config.get('lags', [1, 3, 5])
        self.numerical_nan_fill_strategy = self.config.get('numerical_nan_fill_strategy', 'mean')
        self.categorical_nan_fill_strategy = self.config.get('categorical_nan_fill_strategy', 'unknown')
        self.feature_selection_k = self.config.get('k_best_features', 20) # Default k for feature selection
        self.feature_selection_score_func_name = self.config.get('feature_selection_score_func', 'f_classif')


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
        """Engineer features for model training or prediction following a refined flow."""
        try:
            self.logger.info(f"Starting feature engineering. Initial data shape: {data.shape}")

            # 1. Identify original features to keep based on config
            original_numerical_features = self.config.get('original_numerical_features', [])
            original_categorical_features = self.config.get('original_categorical_features', [])

            # Ensure configured original features exist in data
            original_numerical_to_keep = [f for f in original_numerical_features if f in data.columns and is_numeric_dtype(data[f])]
            original_categorical_to_keep = [f for f in original_categorical_features if f in data.columns] # Type check later

            original_selected_cols = list(set(original_numerical_to_keep + original_categorical_to_keep))
            if not original_selected_cols:
                 self.logger.warning("No original features specified or found in data based on configuration. Proceeding with generated features only.")
                 original_selected_df = pd.DataFrame(index=data.index)
            else:
                original_selected_df = data[original_selected_cols].copy()
            self.logger.debug(f"Selected original features: {original_selected_cols}")


            # 2. Create new features from original data (or a relevant subset)
            #    These methods should use data directly to avoid processing already processed features.
            temporal_features_df = self._create_temporal_features(data)
            statistical_features_df = self._create_statistical_features(data)
            interaction_features_df = self._create_interaction_features(data)
            self.logger.debug(f"Created temporal features: {temporal_features_df.shape[1]}, statistical: {statistical_features_df.shape[1]}, interaction: {interaction_features_df.shape[1]}")

            # 3. Combine: original selected + new features
            # Ensure all parts have the same index as original_selected_df
            dfs_to_concat = [original_selected_df]
            if not temporal_features_df.empty: dfs_to_concat.append(temporal_features_df.reindex(original_selected_df.index))
            if not statistical_features_df.empty: dfs_to_concat.append(statistical_features_df.reindex(original_selected_df.index))
            if not interaction_features_df.empty: dfs_to_concat.append(interaction_features_df.reindex(original_selected_df.index))

            combined_df = pd.concat(dfs_to_concat, axis=1)

            # Handle duplicate column names that might arise (e.g., if a generated feature has same name as an original one)
            combined_df = combined_df.loc[:, ~combined_df.columns.duplicated()]
            self.logger.info(f"Combined features. Shape before NaN handling: {combined_df.shape}")

            # 4. Handle Missing Values for the entire combined_df
            combined_df_filled = self._handle_missing_values(combined_df.copy()) # Pass copy to avoid modifying combined_df inplace if _handle_missing_values does that

            # 5. Scale Numerical Features
            scaled_df = self._scale_features(combined_df_filled)

            # 6. Encode Categorical Features
            encoded_df = self._encode_categorical_features(scaled_df)
            self.logger.info(f"Shape after encoding: {encoded_df.shape}")

            # 7. Feature Selection (if target string is provided)
            selected_features_df = encoded_df # Default to all if no target
            if target is not None and target in data.columns:
                target_series = data[target]
                # Align target with the (potentially row-reduced by earlier NaN handling) encoded_df
                # target_clean, features_aligned = self._align_target_and_features(target_series, encoded_df)
                # _align_target_and_features now returns features_aligned, target_clean (swapped order)
                features_aligned, target_clean = self._align_target_and_features(encoded_df, target_series)


                if not features_aligned.empty and not target_clean.empty:
                    selected_features_df = self._select_features(features_aligned, target_clean)
                else:
                    self.logger.warning("Feature selection skipped due to empty data after alignment or empty target.")
                    selected_features_df = features_aligned # Use aligned features if target was problematic
            elif target is not None and target not in data.columns:
                 self.logger.warning(f"Target column '{target}' not found in input data. Skipping feature selection.")


            # 8. Create Metadata
            feature_metadata = self._create_feature_metadata(selected_features_df)
            self.logger.info(f"Feature engineering complete. Final features shape: {selected_features_df.shape}")
            return selected_features_df, feature_metadata

        except Exception as e:
            self.logger.error(f"Feature engineering failed: {str(e)}", exc_info=True)
            # Return empty DataFrame and metadata on failure to prevent downstream errors
            return pd.DataFrame(), {"error": str(e)}


    def _create_temporal_features(self, data: pd.DataFrame) -> pd.DataFrame:
        """Create temporal features from timestamp data."""
        temporal_features = pd.DataFrame(index=data.index) # Preserve index

        try:
            if 'timestamp' not in data.columns:
                self.logger.info("No 'timestamp' column found for temporal feature creation.")
                return temporal_features

            # Attempt to convert to datetime, handling errors
            timestamp_col = pd.to_datetime(data['timestamp'], errors='coerce')
            if timestamp_col.isnull().all(): # If all are NaT after conversion
                self.logger.warning("'timestamp' column could not be converted to datetime or is all NaNs.")
                return temporal_features


                temporal_features['hour'] = timestamp_col.dt.hour
                temporal_features['day_of_week'] = timestamp_col.dt.dayofweek
                temporal_features['day_of_month'] = timestamp_col.dt.day
                temporal_features['month'] = timestamp_col.dt.month
                temporal_features['is_weekend'] = timestamp_col.dt.dayofweek.isin([5, 6]).astype(int)

                # Create cyclical features for periodic patterns
                temporal_features['hour_sin'] = np.sin(2 * np.pi * timestamp_col.dt.hour / 24)
                temporal_features['hour_cos'] = np.cos(2 * np.pi * timestamp_col.dt.hour / 24)
                temporal_features['month_sin'] = np.sin(2 * np.pi * timestamp_col.dt.month / 12)
                temporal_features['month_cos'] = np.cos(2 * np.pi * timestamp_col.dt.month / 12)

        except Exception as e:
            self.logger.error(f"Temporal feature creation failed: {str(e)}", exc_info=True)
            # Return empty DataFrame with original index on error
            return pd.DataFrame(index=data.index)

        return temporal_features

    def _create_statistical_features(self, data: pd.DataFrame) -> pd.DataFrame:
        """Create statistical features from configured numerical columns."""
        statistical_features = pd.DataFrame(index=data.index)

        cols_to_process = self.config.get('statistical_feature_columns', [])
        if not cols_to_process: # Default to all numeric if not specified
            cols_to_process = data.select_dtypes(include=[np.number]).columns.tolist()

        if not cols_to_process:
            self.logger.info("No columns specified or found for statistical feature creation.")
            return statistical_features

        try:
            self.logger.info(f"Creating statistical features for columns: {cols_to_process}")
            for col_name in cols_to_process:
                if col_name not in data.columns or not is_numeric_dtype(data[col_name]):
                    self.logger.warning(f"Column '{col_name}' for statistical features not found or not numeric. Skipping.")
                    continue

                series = data[col_name]
                # Rolling statistics for multiple window sizes
                for window in self.rolling_window_sizes:
                    if len(series) < window: # Not enough data for this window
                        self.logger.debug(f"Not enough data for rolling window {window} on column {col_name}")
                        continue
                    rolling_obj = series.rolling(window=window, min_periods=1) # min_periods=1 to get value even for smaller windows at start
                    statistical_features[f'{col_name}_rolling{window}_mean'] = rolling_obj.mean() # NaNs will be handled later by _handle_missing_values
                    statistical_features[f'{col_name}_rolling{window}_std'] = rolling_obj.std()
                    statistical_features[f'{col_name}_rolling{window}_max'] = rolling_obj.max()
                    statistical_features[f'{col_name}_rolling{window}_min'] = rolling_obj.min()

                # Lag features
                for lag in self.lags:
                    if len(series) < lag: continue
                    statistical_features[f'{col_name}_lag_{lag}'] = series.shift(lag)

                # Difference features
                statistical_features[f'{col_name}_diff'] = series.diff()
                statistical_features[f'{col_name}_pct_change'] = series.pct_change().replace([np.inf, -np.inf], np.nan) # Handle inf from pct_change

        except Exception as e:
            self.logger.error(f"Statistical feature creation failed: {str(e)}", exc_info=True)
            return pd.DataFrame(index=data.index) # Return empty on error

        return statistical_features

    def _create_interaction_features(self, data: pd.DataFrame) -> pd.DataFrame:
        """Create interaction features between configured numerical columns."""
        interaction_features = pd.DataFrame(index=data.index)

        interaction_cols_config = self.config.get('interaction_feature_columns', [])
        if not interaction_cols_config: # Default to a subset of numeric if not specified or handle as error
            # For safety, let's not default to all numeric pairs to avoid feature explosion.
            # Require explicit configuration or select top N based on some criteria if desired.
            self.logger.info("No columns specified for interaction feature creation ('interaction_feature_columns'). Skipping.")
            return interaction_features

        # Filter to existing and numeric columns from the config list
        numerical_columns_for_interaction = [
            col for col in interaction_cols_config
            if col in data.columns and is_numeric_dtype(data[col])
        ]
        if len(numerical_columns_for_interaction) < 2:
            self.logger.info("Not enough valid numerical columns for interaction feature creation.")
            return interaction_features

        try:
            self.logger.info(f"Creating interaction features for columns: {numerical_columns_for_interaction}")
            for i, col1_name in enumerate(numerical_columns_for_interaction):
                for col2_name in numerical_columns_for_interaction[i+1:]:
                    col1 = data[col1_name]
                    col2 = data[col2_name]

                    interaction_features[f'{col1_name}_x_{col2_name}_product'] = col1 * col2
                    ratio_series = col1 / (col2 + 1e-8) # Add small epsilon to prevent division by zero
                    interaction_features[f'{col1_name}_div_{col2_name}_ratio'] = ratio_series.replace([np.inf, -np.inf], np.nan)
                    interaction_features[f'{col1_name}_plus_{col2_name}_sum'] = col1 + col2
                    interaction_features[f'{col1_name}_minus_{col2_name}_diff'] = col1 - col2

            # Clipping extreme values is generally good, but might be better handled by robust scalers or transformations later.
            # For now, keeping it simple. NaNs from ratios or products will be handled by _handle_missing_values.
        except Exception as e:
            self.logger.error(f"Interaction feature creation failed: {str(e)}", exc_info=True)
            return pd.DataFrame(index=data.index)

        return interaction_features

    def _handle_missing_values(self, df: pd.DataFrame) -> pd.DataFrame:
        """Handle missing values in the DataFrame based on configured strategies."""
        self.logger.info(f"Handling missing values. Initial NaN count: {df.isnull().sum().sum()}")
        df_processed = df.copy()

        # Handle numerical NaNs
        num_cols = df_processed.select_dtypes(include=np.number).columns
        if not num_cols.empty:
            if self.numerical_nan_fill_strategy == 'mean':
                fill_values_num = df_processed[num_cols].mean()
                df_processed[num_cols] = df_processed[num_cols].fillna(fill_values_num)
                self.logger.debug(f"Filled NaNs in numerical columns with mean: {fill_values_num.to_dict()}")
            elif self.numerical_nan_fill_strategy == 'median':
                fill_values_num = df_processed[num_cols].median()
                df_processed[num_cols] = df_processed[num_cols].fillna(fill_values_num)
                self.logger.debug(f"Filled NaNs in numerical columns with median: {fill_values_num.to_dict()}")
            elif self.numerical_nan_fill_strategy == 'zero':
                df_processed[num_cols] = df_processed[num_cols].fillna(0)
                self.logger.debug("Filled NaNs in numerical columns with 0.")
            elif isinstance(self.numerical_nan_fill_strategy, (int, float)): # Fill with a specific constant
                df_processed[num_cols] = df_processed[num_cols].fillna(self.numerical_nan_fill_strategy)
                self.logger.debug(f"Filled NaNs in numerical columns with constant: {self.numerical_nan_fill_strategy}.")
            else:
                 self.logger.warning(f"Unsupported numerical NaN fill strategy: {self.numerical_nan_fill_strategy}. NaNs may remain.")

        # Handle categorical NaNs
        cat_cols = df_processed.select_dtypes(include=['object', 'category']).columns
        if not cat_cols.empty:
            if self.categorical_nan_fill_strategy == 'mode':
                for col in cat_cols: # Mode can be multi-valued, take the first
                    mode_val = df_processed[col].mode()
                    if not mode_val.empty:
                        df_processed[col] = df_processed[col].fillna(mode_val[0])
                        self.logger.debug(f"Filled NaNs in categorical column '{col}' with mode: {mode_val[0]}.")
                    else: # Series might be all NaN
                        df_processed[col] = df_processed[col].fillna('unknown') # Fallback for all-NaN series
                        self.logger.debug(f"Mode not found for categorical column '{col}' (all NaNs?). Filled with 'unknown'.")

            elif self.categorical_nan_fill_strategy == 'unknown' or isinstance(self.categorical_nan_fill_strategy, str):
                fill_val_cat = 'unknown' if self.categorical_nan_fill_strategy == 'unknown' else self.categorical_nan_fill_strategy
                df_processed[cat_cols] = df_processed[cat_cols].fillna(fill_val_cat)
                self.logger.debug(f"Filled NaNs in categorical columns with '{fill_val_cat}'.")
            else:
                self.logger.warning(f"Unsupported categorical NaN fill strategy: {self.categorical_nan_fill_strategy}. NaNs may remain.")

        final_nan_count = df_processed.isnull().sum().sum()
        self.logger.info(f"Missing value handling complete. Final NaN count: {final_nan_count}")
        if final_nan_count > 0:
            self.logger.warning(f"NaNs still present after handling: \n{df_processed.isnull().sum()[df_processed.isnull().sum() > 0]}")
        return df_processed


    def _scale_features(self, features: pd.DataFrame) -> pd.DataFrame:
        """Scale numerical features."""
        try:
            numerical_cols = features.select_dtypes(include=[np.number]).columns
            if numerical_cols.empty:
                self.logger.info("No numerical features to scale.")
                return features.copy()

            # Create a copy to avoid modifying the input DataFrame if it's passed around
            scaled_features_df = features.copy()

            # Use a consistent key for the scaler, e.g., 'standard_scaler'
            scaler_key = 'standard_scaler'
            if scaler_key not in self.scalers:
                self.logger.info(f"Fitting new StandardScaler for features: {list(numerical_cols)}")
                self.scalers[scaler_key] = StandardScaler()
                scaled_values = self.scalers[scaler_key].fit_transform(features[numerical_cols])
            else:
                self.logger.info(f"Using existing StandardScaler to transform features: {list(numerical_cols)}")
                try:
                    scaled_values = self.scalers[scaler_key].transform(features[numerical_cols])
                except Exception as e_transform: # Catch issues if features changed unexpectedly
                    self.logger.error(f"Error transforming features with existing scaler: {e_transform}. Refitting scaler.", exc_info=True)
                    self.scalers[scaler_key] = StandardScaler() # Re-initialize
                    scaled_values = self.scalers[scaler_key].fit_transform(features[numerical_cols])

            scaled_features_df[numerical_cols] = scaled_values
            return scaled_features_df

        except Exception as e:
            self.logger.error(f"Feature scaling failed: {str(e)}", exc_info=True)
            raise # Re-raise to halt processing if scaling is critical

    def _encode_categorical_features(self, features: pd.DataFrame) -> pd.DataFrame:
        """Encode categorical features."""
        try:
            # Operate on a copy to avoid SettingWithCopyWarning on the original DataFrame
            encoded_df = features.copy()
            categorical_cols = encoded_df.select_dtypes(include=['object', 'category']).columns

            if categorical_cols.empty:
                self.logger.info("No categorical features to encode.")
                return encoded_df # Return the copy

            for col in categorical_cols:
                encoder_key = f"encoder_{col}"
                column_data = encoded_df[[col]] # Keep as DataFrame for encoder

                if encoder_key not in self.encoders:
                    self.logger.info(f"Fitting new OneHotEncoder for column: {col}")
                    self.encoders[encoder_key] = OneHotEncoder(sparse_output=False, handle_unknown='ignore')
                    encoded_values = self.encoders[encoder_key].fit_transform(column_data)
                else:
                    self.logger.info(f"Using existing OneHotEncoder for column: {col}")
                    try:
                        encoded_values = self.encoders[encoder_key].transform(column_data)
                    except Exception as e_transform_enc:
                        self.logger.error(f"Error transforming column {col} with existing encoder: {e_transform_enc}. Refitting encoder.", exc_info=True)
                        self.encoders[encoder_key] = OneHotEncoder(sparse_output=False, handle_unknown='ignore') # Re-initialize
                        encoded_values = self.encoders[encoder_key].fit_transform(column_data)

                # Get feature names from encoder; handle cases where categories_ might be empty or not as expected
                try:
                    new_feature_names = self.encoders[encoder_key].get_feature_names_out([col])
                except AttributeError: # older sklearn versions might use categories_
                     new_feature_names = [f"{col}_{val}" for val in self.encoders[encoder_key].categories_[0]]


                encoded_part = pd.DataFrame(encoded_values, columns=new_feature_names, index=encoded_df.index)

                encoded_df = pd.concat([encoded_df.drop(columns=[col]), encoded_part], axis=1)

            self.logger.info(f"Categorical feature encoding complete. Shape after encoding: {encoded_df.shape}")
            return encoded_df

        except Exception as e:
            self.logger.error(f"Feature encoding failed: {str(e)}", exc_info=True)
            raise # Re-raise as this is critical

    def _align_target_and_features(self, features_df: pd.DataFrame, target_series: pd.Series) -> Tuple[pd.DataFrame, pd.Series]:
        """Aligns features and target by dropping rows where target is NaN, and ensures indices match."""
        self.logger.debug(f"Aligning target and features. Initial shapes: Features {features_df.shape}, Target {target_series.shape}")

        # Ensure target is a Series and has a name for potential merging/joining if needed
        if not isinstance(target_series, pd.Series):
            target_series = pd.Series(target_series, name=getattr(target_series, 'name', 'target'))

        # Drop rows where target is NaN
        valid_target_indices = target_series.notna()
        target_clean = target_series[valid_target_indices]

        # Align features_df to the cleaned target's index
        # This ensures that if target had NaNs, corresponding rows in features_df are also dropped.
        features_aligned = features_df.loc[target_clean.index]

        self.logger.debug(f"Aligned shapes: Features {features_aligned.shape}, Target {target_clean.shape}")
        if len(features_aligned) != len(target_clean):
            # This should not happen if reindex/loc works correctly
            self.logger.error("Mismatch in length after aligning target and features. This indicates an issue.")
            # Fallback or raise error
            raise ValueError("Alignment of features and target resulted in mismatched lengths.")

        return features_aligned, target_clean


    def _select_features(
        self,
        features: pd.DataFrame,
        target: pd.Series
    ) -> pd.DataFrame:
        """Select most important features using statistical tests."""
        try:
            self.logger.info(f"Starting feature selection. Initial number of features: {features.shape[1]}")

            if features.empty:
                self.logger.warning("Feature set is empty before selection. Returning empty DataFrame.")
                return pd.DataFrame(index=features.index) # Preserve index if possible

            # Target should be cleaned by _align_target_and_features before this method
            if target.empty or len(target.unique()) < 2 and self.feature_selection_score_func_name == 'f_classif': # f_classif needs >=2 classes
                self.logger.warning(f"Target variable for feature selection is empty or has insufficient unique values for {self.feature_selection_score_func_name}. Skipping selection.")
                return features

            k_to_select = self.feature_selection_k
            num_available_features = features.shape[1]

            if k_to_select <= 0 or k_to_select >= num_available_features:
                self.logger.info(f"k for feature selection ({k_to_select}) implies selecting all {num_available_features} features.")
                k_to_select = 'all' # SelectKBest takes 'all'

            score_func_map = {'f_classif': f_classif, 'f_regression': f_regression}
            score_func = score_func_map.get(self.feature_selection_score_func_name)
            if not score_func:
                self.logger.warning(f"Invalid feature_selection_score_func: {self.feature_selection_score_func_name}. Defaulting to f_classif.")
                score_func = f_classif

            # Ensure features are numeric and finite for SelectKBest
            numeric_features = features.select_dtypes(include=np.number)
            # Replace inf/-inf with NaN, then fill NaNs. This should ideally be done before scaling/encoding.
            # However, SelectKBest is sensitive. Assuming _handle_missing_values took care of NaNs.
            # Checking for Infs which might arise from ratios.
            numeric_features = numeric_features.replace([np.inf, -np.inf], np.nan)
            if numeric_features.isnull().sum().sum() > 0:
                 self.logger.warning("NaNs found in numeric features before SelectKBest. Filling with mean for selection.")
                 numeric_features = numeric_features.fillna(numeric_features.mean())


            if numeric_features.empty:
                self.logger.warning("No numeric features available for SelectKBest. Returning all (original) features.")
                return features

            if k_to_select == 'all': # If k is 'all', it might be more than available numeric features after dtype selection.
                 k_actual_for_selector = min(numeric_features.shape[1], num_available_features) if k_to_select == 'all' else min(k_to_select, numeric_features.shape[1])
            else:
                 k_actual_for_selector = min(k_to_select, numeric_features.shape[1])


            if k_actual_for_selector == 0 and numeric_features.shape[1] > 0: # If k is 0 but features exist
                 self.logger.warning("k_actual_for_selector is 0. SelectKBest might fail. Returning original numeric features.")
                 return numeric_features # Or features, depending on desired fallback

            selector_key = f"selector_k{k_actual_for_selector}_{self.feature_selection_score_func_name}"

            current_selector: SelectKBest
            if selector_key not in self.feature_selectors:
                self.logger.info(f"Fitting new SelectKBest (k={k_actual_for_selector}, score_func={self.feature_selection_score_func_name}).")
                current_selector = SelectKBest(score_func=score_func, k=k_actual_for_selector)
                try:
                    current_selector.fit(numeric_features, target)
                    self.feature_selectors[selector_key] = current_selector
                except Exception as e_fit:
                    self.logger.error(f"Error fitting SelectKBest: {e_fit}. Returning all numeric features.", exc_info=True)
                    return numeric_features # Fallback
            else:
                self.logger.info(f"Using existing SelectKBest: {selector_key}")
                current_selector = self.feature_selectors[selector_key]

            selected_features_mask = current_selector.get_support()

            if not np.any(selected_features_mask):
                self.logger.warning("SelectKBest selected no features. Returning original numeric features.")
                return numeric_features

            selected_numeric_cols = numeric_features.columns[selected_features_mask]

            # Reconstruct DataFrame with selected numeric columns and any non-numeric columns from original `features`
            final_selected_features = features[selected_numeric_cols].copy()
            for col in features.columns:
                if col not in numeric_features.columns: # Add back non-numeric columns that were not part of selection
                    final_selected_features[col] = features[col]

            self.logger.info(f"Selected {len(final_selected_features.columns)} features: {list(final_selected_features.columns)}")
            return final_selected_features

        except Exception as e:
            self.logger.error(f"Feature selection failed: {str(e)}", exc_info=True)
            return features # Fallback to returning all features


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
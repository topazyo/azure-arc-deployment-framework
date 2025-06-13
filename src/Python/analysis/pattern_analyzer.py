import pandas as pd
import numpy as np
from sklearn.cluster import DBSCAN
from sklearn.preprocessing import StandardScaler
from scipy.stats import linregress
from pandas.api.types import is_numeric_dtype
from typing import Dict, List, Any, Optional, Tuple
import logging
from datetime import datetime
import pandas as pd # Ensure pandas is imported if not already
import numpy as np # Ensure numpy is imported

class PatternAnalyzer:
    """Provides methods for pattern analysis."""
    def __init__(self, config: Dict[str, Any]):
        """Initializes the analyzer with configuration."""
        self.config = config
        self.setup_logging()
        # DBSCAN parameters from config, with defaults
        self.dbscan_eps = self.config.get('dbscan_eps', 0.5)
        self.dbscan_min_samples = self.config.get('dbscan_min_samples', 5)
        self.scaler = StandardScaler() # Keep scaler for behavioral patterns

    def setup_logging(self):
        """Configures logging for the analyzer."""
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            filename=f'pattern_analyzer_{datetime.now().strftime("%Y%m%d")}.log'
        )
        self.logger = logging.getLogger('PatternAnalyzer')

    def analyze_patterns(self, data: pd.DataFrame) -> Dict[str, Any]:
        """Main method to analyze all pattern types."""
        try:
            patterns = {
                'temporal': self.analyze_temporal_patterns(data),
                'behavioral': self.analyze_behavioral_patterns(data),
                'failure': self.analyze_failure_patterns(data),
                'performance': self.analyze_performance_patterns(data)
            }

            self.patterns = patterns
            return patterns

        except Exception as e:
            self.logger.error(f"Pattern analysis failed: {str(e)}")
            raise

    def analyze_daily_patterns(self, data: pd.DataFrame) -> Dict[str, Any]:
        """Analyze daily patterns in numerical data."""
        self.logger.info("Analyzing daily patterns...")
        results = {"peak_hours": {}, "seasonality_strength": {}, "recommendations": []}
        if 'timestamp' not in data.columns:
            self.logger.warning("Timestamp column required for daily pattern analysis, not found.")
            return results
        try:
            df = data.copy()
            df['hour'] = pd.to_datetime(df['timestamp']).dt.hour

            numerical_cols = df.select_dtypes(include=np.number).columns
            for col in numerical_cols:
                if col == 'hour': continue
                hourly_mean = df.groupby('hour')[col].mean()
                if hourly_mean.empty: continue

                # Peak hours (e.g., > 75th percentile)
                peak_threshold = hourly_mean.quantile(self.config.get('daily_peak_percentile_threshold', 0.75))
                current_peak_hours = hourly_mean[hourly_mean > peak_threshold].index.tolist()
                if current_peak_hours:
                    results["peak_hours"][col] = current_peak_hours

                # Seasonality strength (autocorrelation at lag 24 if enough data)
                if len(df[col].dropna()) > 48: # Need at least 2 full cycles for lag 24
                    try:
                        autocorr_24 = df[col].autocorr(lag=24)
                        results["seasonality_strength"][col] = round(autocorr_24, 2) if pd.notna(autocorr_24) else 0.0
                    except Exception as e_autocorr:
                        self.logger.debug(f"Could not calculate daily seasonality for {col}: {e_autocorr}")
                        results["seasonality_strength"][col] = 0.0
                else:
                    results["seasonality_strength"][col] = 0.0 # Not enough data

            if results["peak_hours"]:
                 results["recommendations"].append({
                    'action': "Optimize resource allocation during identified peak hours.",
                    'priority': 0.6,
                    'details': f"Peak hours observed for metrics: {list(results['peak_hours'].keys())}. Review specific hours in 'peak_hours' field."
                })
            return results
        except Exception as e:
            self.logger.error(f"Daily pattern analysis failed: {str(e)}", exc_info=True)
            return {"peak_hours": {}, "seasonality_strength": {}, "recommendations": []}


    def analyze_weekly_patterns(self, data: pd.DataFrame) -> Dict[str, Any]:
        """Analyze weekly patterns in numerical data."""
        self.logger.info("Analyzing weekly patterns...")
        results = {"peak_days": {}, "seasonality_strength": {}, "recommendations": []}
        if 'timestamp' not in data.columns:
            self.logger.warning("Timestamp column required for weekly pattern analysis, not found.")
            return results
        try:
            df = data.copy()
            df['day_of_week'] = pd.to_datetime(df['timestamp']).dt.dayofweek # Monday=0, Sunday=6

            numerical_cols = df.select_dtypes(include=np.number).columns
            for col in numerical_cols:
                if col == 'day_of_week': continue
                daily_agg = df.groupby(pd.to_datetime(df['timestamp']).dt.date)[col].mean() # Aggregate to daily first
                if len(daily_agg) < 14: # Need at least 2 weeks of daily data for weekly seasonality
                    results["seasonality_strength"][col] = 0.0
                    continue

                # Create day_of_week from the daily aggregated index
                daily_agg_df = daily_agg.reset_index()
                daily_agg_df.columns = ['date', col] # Rename columns
                daily_agg_df['day_of_week'] = pd.to_datetime(daily_agg_df['date']).dt.dayofweek

                weekly_mean_by_day = daily_agg_df.groupby('day_of_week')[col].mean()
                if weekly_mean_by_day.empty: continue

                peak_threshold = weekly_mean_by_day.quantile(self.config.get('weekly_peak_percentile_threshold', 0.75))
                current_peak_days = weekly_mean_by_day[weekly_mean_by_day > peak_threshold].index.tolist()
                if current_peak_days:
                    results["peak_days"][col] = current_peak_days

                try:
                    autocorr_7 = daily_agg.autocorr(lag=7) # Autocorrelation on daily data for weekly pattern
                    results["seasonality_strength"][col] = round(autocorr_7, 2) if pd.notna(autocorr_7) else 0.0
                except Exception as e_autocorr:
                    self.logger.debug(f"Could not calculate weekly seasonality for {col}: {e_autocorr}")
                    results["seasonality_strength"][col] = 0.0

            if results["peak_days"]:
                results["recommendations"].append({
                    'action': "Plan for weekly peak load on identified days.",
                    'priority': 0.6,
                    'details': f"Peak days observed for metrics: {list(results['peak_days'].keys())}. Review 'peak_days' for specific days (0=Monday)."
                })
            return results
        except Exception as e:
            self.logger.error(f"Weekly pattern analysis failed: {str(e)}", exc_info=True)
            return {"peak_days": {}, "seasonality_strength": {}, "recommendations": []}

    def analyze_monthly_patterns(self, data: pd.DataFrame) -> Dict[str, Any]:
        """Analyze monthly patterns in numerical data."""
        self.logger.info("Analyzing monthly patterns...")
        results = {"peak_days_of_month": {}, "peak_months": {}, "recommendations": []}
        if 'timestamp' not in data.columns:
            self.logger.warning("Timestamp column required for monthly pattern analysis, not found.")
            return results
        try:
            df = data.copy()
            df['timestamp_dt'] = pd.to_datetime(df['timestamp'])
            df['day_of_month'] = df['timestamp_dt'].dt.day
            df['month'] = df['timestamp_dt'].dt.month

            numerical_cols = df.select_dtypes(include=np.number).columns
            for col in numerical_cols:
                if col in ['day_of_month', 'month']: continue

                # Peak Day of Month
                monthly_mean_by_day = df.groupby('day_of_month')[col].mean()
                if not monthly_mean_by_day.empty:
                    peak_threshold_dom = monthly_mean_by_day.quantile(self.config.get('monthly_dom_peak_percentile_threshold', 0.75))
                    current_peak_dom = monthly_mean_by_day[monthly_mean_by_day > peak_threshold_dom].index.tolist()
                    if current_peak_dom:
                        results["peak_days_of_month"][col] = current_peak_dom

                # Peak Month (if data spans multiple months)
                if df['month'].nunique() > 1:
                    monthly_mean_by_month = df.groupby('month')[col].mean()
                    if not monthly_mean_by_month.empty:
                        peak_threshold_month = monthly_mean_by_month.quantile(self.config.get('monthly_month_peak_percentile_threshold', 0.75))
                        current_peak_months = monthly_mean_by_month[monthly_mean_by_month > peak_threshold_month].index.tolist()
                        if current_peak_months:
                           results["peak_months"][col] = current_peak_months

            if results["peak_days_of_month"] or results["peak_months"]:
                results["recommendations"].append({
                    'action': "Consider monthly load variations for resource planning.",
                    'priority': 0.5,
                    'details': "Monthly peaks identified. Review 'peak_days_of_month' and 'peak_months'."
                })
            return results
        except Exception as e:
            self.logger.error(f"Monthly pattern analysis failed: {str(e)}", exc_info=True)
            return {"peak_days_of_month": {}, "peak_months": {}, "recommendations": []}


    def analyze_temporal_patterns(self, data: pd.DataFrame) -> Dict[str, Any]:
        """Analyze temporal patterns in the data."""
        try:
            daily_patterns = self.analyze_daily_patterns(data.copy()) # Pass copy to avoid side effects
            weekly_patterns = self.analyze_weekly_patterns(data.copy())
            monthly_patterns = self.analyze_monthly_patterns(data.copy())

            # Aggregate recommendations
            all_recommendations = []
            all_recommendations.extend(daily_patterns.get("recommendations", []))
            all_recommendations.extend(weekly_patterns.get("recommendations", []))
            all_recommendations.extend(monthly_patterns.get("recommendations", []))

            # Remove duplicates if any, based on 'action' and 'details' for example
            unique_recommendations = []
            seen_recs = set()
            for rec in all_recommendations:
                rec_tuple = (rec.get('action'), rec.get('details'))
                if rec_tuple not in seen_recs:
                    unique_recommendations.append(rec)
                    seen_recs.add(rec_tuple)

            return {
                'daily': daily_patterns,
                'weekly': weekly_patterns,
                'monthly': monthly_patterns,
                'recommendations': unique_recommendations
            }
        except Exception as e:
            self.logger.error(f"Temporal pattern analysis failed: {str(e)}", exc_info=True)
            return {
                'daily': {"recommendations": []},
                'weekly': {"recommendations": []},
                'monthly': {"recommendations": []},
                'recommendations': []
            }

    def analyze_behavioral_patterns(self, data: pd.DataFrame) -> Dict[str, Any]:
        """Analyze behavioral patterns using clustering."""
        self.logger.info("Analyzing behavioral patterns...")
        results = {"clusters": {}, "recommendations": []}
        try:
            features_array, used_feature_names = self.prepare_behavioral_features(data)
            if features_array.size == 0 or features_array.shape[0] < self.dbscan_min_samples : # Ensure enough samples for DBSCAN
                self.logger.warning(f"Not enough samples ({features_array.shape[0]}) or features for behavioral pattern analysis. Min samples: {self.dbscan_min_samples}")
                return results

            scaled_features = self.scaler.fit_transform(features_array)

            clustering = DBSCAN(
                eps=self.dbscan_eps,
                min_samples=self.dbscan_min_samples
            ).fit(scaled_features)

            # Pass actual feature names to analyze_clusters
            results["clusters"] = self.analyze_clusters(features_array, clustering.labels_, used_feature_names)

            # Example recommendation based on cluster analysis
            # This is highly dependent on how clusters are interpreted.
            # For instance, if a cluster has a significantly high average for an 'error_rate' feature.
            # This requires `analyze_clusters` to include such interpretations or return data for it.
            # For now, a generic recommendation:
            if results["clusters"] and len(results["clusters"]) > 0 :
                 results["recommendations"].append({
                    'action': "Review identified behavioral clusters for distinct operational states or anomalies.",
                    'priority': 0.4,
                    'details': f"Found {len(results['clusters'])} distinct behavioral clusters. Examine their characteristics."
                })
            return results
        except Exception as e:
            self.logger.error(f"Behavioral pattern analysis failed: {str(e)}", exc_info=True)
            return {"clusters": {}, "recommendations": []}

    def identify_common_failure_causes(self, data: pd.DataFrame) -> Dict[str, Any]:
        """Identify common failure causes by frequency count if 'error_type' or 'failure_category' column exists."""
        self.logger.info("Identifying common failure causes...")
        results = {'common_causes': [], 'recommendations': []}

        error_col_name = None
        if 'error_type' in data.columns:
            error_col_name = 'error_type'
        elif 'failure_category' in data.columns:
            error_col_name = 'failure_category'

        if not error_col_name:
            self.logger.info("No 'error_type' or 'failure_category' column found for identifying common failure causes.")
            return results
        try:
            if data[error_col_name].isnull().all():
                 self.logger.info(f"Column '{error_col_name}' contains all NaN values.")
                 return results

            counts = data[error_col_name].value_counts(normalize=True) # Get percentages
            total_errors = len(data[data[error_col_name].notna()]) # Count non-NaN errors

            for error_val, percentage in counts.items():
                frequency = int(percentage * total_errors)
                results['common_causes'].append({
                    'cause': str(error_val), # Ensure it's a string
                    'frequency': frequency,
                    'percentage': round(percentage * 100, 2)
                })

            if results['common_causes']:
                top_cause = results['common_causes'][0]['cause']
                results['recommendations'].append({
                    'action': f"Address the most frequently occurring error: {top_cause}.",
                    'priority': 0.7,
                    'details': f"{top_cause} accounts for {results['common_causes'][0]['percentage']}% of recorded errors."
                })
            return results
        except Exception as e:
            self.logger.error(f"Identifying common failure causes failed: {str(e)}", exc_info=True)
            return {'common_causes': [], 'recommendations': []}


    def identify_failure_precursors(self, data: pd.DataFrame) -> Dict[str, Any]:
        """Identify potential failure precursors by analyzing metric averages before failures."""
        self.logger.info("Identifying failure precursors...")
        results = {'precursors': [], 'recommendations': []}

        if 'timestamp' not in data.columns or 'failure_occurred' not in data.columns:
            self.logger.warning("Timestamp and failure_occurred columns required for precursor analysis.")
            return results
        try:
            df = data.sort_values(by='timestamp').copy()
            df['failure_occurred'] = df['failure_occurred'].astype(int) # Ensure numeric

            failure_indices = df[df['failure_occurred'] == 1].index
            if not failure_indices.any():
                self.logger.info("No failure events found in data.")
                return results

            precursor_window_str = self.config.get('precursor_window', '1H') # e.g., 1H, 30T
            precursor_window = pd.to_timedelta(precursor_window_str)

            numerical_cols = df.select_dtypes(include=np.number).columns.tolist()
            # Remove columns that shouldn't be treated as precursors
            cols_to_exclude = ['failure_occurred', 'timestamp'] # timestamp if it was converted to numeric
            metrics_to_analyze = [col for col in numerical_cols if col not in cols_to_exclude and is_numeric_dtype(df[col])]


            for metric in metrics_to_analyze:
                overall_avg_metric = df[metric].mean()
                if pd.isna(overall_avg_metric): continue

                pre_failure_values = []
                for idx in failure_indices:
                    failure_time = df.loc[idx, 'timestamp']
                    window_start_time = failure_time - precursor_window
                    # Ensure the window is within the DataFrame bounds
                    window_data = df[(df['timestamp'] >= window_start_time) & (df['timestamp'] < failure_time)]
                    if not window_data.empty and not window_data[metric].isnull().all():
                        pre_failure_values.append(window_data[metric].mean())

                if pre_failure_values:
                    avg_pre_failure_metric = np.mean(pre_failure_values)
                    if overall_avg_metric != 0: # Avoid division by zero
                        change_pct = ((avg_pre_failure_metric - overall_avg_metric) / overall_avg_metric) * 100
                        if abs(change_pct) > self.config.get('precursor_significance_threshold_pct', 10): # e.g. 10% change
                            results['precursors'].append({
                                'metric': metric,
                                'average_before_failure': round(avg_pre_failure_metric, 2),
                                'overall_average': round(overall_avg_metric, 2),
                                'change_percentage': f"{round(change_pct, 1)}%"
                            })

            if results['precursors']:
                sample_precursor_metric = results['precursors'][0]['metric']
                results['recommendations'].append({
                    'action': f"Monitor metrics like {sample_precursor_metric} as they show significant changes before failures.",
                    'priority': 0.65,
                    'details': "Review 'precursors' list for specific metric changes."
                })
            return results
        except Exception as e:
            self.logger.error(f"Identifying failure precursors failed: {str(e)}", exc_info=True)
            return {'precursors': [], 'recommendations': []}


    def analyze_failure_impact(self, data: pd.DataFrame) -> Dict[str, Any]:
        """Analyze failure impact if relevant columns (downtime_minutes, affected_services_count) exist."""
        self.logger.info("Analyzing failure impact...")
        results = {
            'average_downtime': 0, 'max_downtime': 0,
            'average_affected_services': 0, 'max_affected_services': 0,
            'recommendations': []
        }
        try:
            # Check for relevant columns and filter for rows that might represent failure events
            # This might require 'failure_id' or specific event markers if not all rows are failures
            failure_data = data
            if 'failure_id' in data.columns: # Assuming data might contain non-failure rows too
                failure_data = data[data['failure_id'].notna()]
            elif 'failure_occurred' in data.columns and 1 in data['failure_occurred'].unique():
                 failure_data = data[data['failure_occurred'] == 1]


            if failure_data.empty:
                self.logger.info("No specific failure events found to analyze impact from.")
                return results

            if 'downtime_minutes' in failure_data.columns and failure_data['downtime_minutes'].notna().any():
                results['average_downtime'] = round(failure_data['downtime_minutes'].mean(),1)
                results['max_downtime'] = int(failure_data['downtime_minutes'].max())

            if 'affected_services_count' in failure_data.columns and failure_data['affected_services_count'].notna().any():
                results['average_affected_services'] = round(failure_data['affected_services_count'].mean(),1)
                results['max_affected_services'] = int(failure_data['affected_services_count'].max())

            if results['average_downtime'] > 0 or results['average_affected_services'] > 0:
                rec_detail = []
                if results['average_downtime'] > 0: rec_detail.append(f"Average downtime is {results['average_downtime']} mins.")
                if results['average_affected_services'] > 0: rec_detail.append(f"Average services affected is {results['average_affected_services']}.")
                results['recommendations'].append({
                    'action': "Review failure impact metrics to prioritize critical failure types.",
                    'priority': 0.7,
                    'details': " ".join(rec_detail)
                })
            return results
        except Exception as e:
            self.logger.error(f"Analyzing failure impact failed: {str(e)}", exc_info=True)
            return {'average_downtime': 0, 'max_downtime': 0, 'average_affected_services': 0, 'max_affected_services': 0, 'recommendations': []}


    def analyze_failure_patterns(self, data: pd.DataFrame) -> Dict[str, Any]:
        """Analyze failure patterns in the data."""
        try:
            common_causes_res = self.identify_common_failure_causes(data.copy())
            precursors_res = self.identify_failure_precursors(data.copy())
            impact_res = self.analyze_failure_impact(data.copy())

            all_recommendations = []
            all_recommendations.extend(common_causes_res.get("recommendations", []))
            all_recommendations.extend(precursors_res.get("recommendations", []))
            all_recommendations.extend(impact_res.get("recommendations", []))

            # Basic placeholder recommendation if no specific ones generated
            if not all_recommendations:
                 all_recommendations.append({
                    'action': "Review failure logs and metrics for deeper insights.",
                    'priority': 0.5,
                    'details': "No specific high-level failure patterns automatically generated from provided data subsets."
                })

            return {
                'common_causes': common_causes_res.get('common_causes', []),
                'precursors': precursors_res.get('precursors', []),
                'impact_analysis': impact_res, # impact_res is a dict itself
                'recommendations': all_recommendations
            }
        except Exception as e:
            self.logger.error(f"Failure pattern analysis failed: {str(e)}", exc_info=True)
            return {"common_causes": [], "precursors": [], "impact_analysis": {}, "recommendations": []}


    def analyze_resource_usage_patterns(self, data: pd.DataFrame) -> Dict[str, Any]:
        """Analyze resource usage patterns for key metrics."""
        self.logger.info("Analyzing resource usage patterns...")
        results = {'metric_stats': {}, 'sustained_high_usage': [], 'recommendations': []}

        performance_metrics = self.config.get('performance_metrics', ['cpu_usage', 'memory_usage']) # Default if not in config
        if not performance_metrics:
            self.logger.info("No performance metrics configured for resource usage analysis.")
            return results
        try:
            for metric in performance_metrics:
                if metric not in data.columns or not is_numeric_dtype(data[metric]):
                    self.logger.warning(f"Metric '{metric}' not found or not numeric. Skipping resource usage analysis for it.")
                    continue

                series = data[metric].dropna()
                if series.empty: continue

                results['metric_stats'][metric] = {
                    'mean': round(series.mean(), 2),
                    'median': round(series.median(), 2),
                    'p95': round(series.quantile(0.95), 2),
                    'std_dev': round(series.std(), 2)
                }

                # Sustained high usage (e.g., N consecutive points above X percentile)
                high_usage_threshold = series.quantile(self.config.get('sustained_high_usage_percentile', 0.90))
                min_consecutive_points = self.config.get('sustained_high_usage_min_points', 5)

                high_periods = (series > high_usage_threshold).astype(int).groupby(series.lt(high_usage_threshold).astype(int).cumsum()).cumsum()
                sustained_periods = high_periods[high_periods >= min_consecutive_points]

                if not sustained_periods.empty:
                    # Store start index and length of sustained periods
                    # This part is a bit complex to extract precise start/end timestamps without more context on data frequency
                    # For now, just noting that sustained high usage was found.
                    results['sustained_high_usage'].append({
                        'metric': metric,
                        'threshold_used': round(high_usage_threshold,2),
                        'periods_detected_count': len(sustained_periods[sustained_periods == min_consecutive_points]) # count starts of such periods
                    })

            if results['metric_stats']:
                results['recommendations'].append({
                    'action': "Review resource utilization statistics and investigate any sustained high usage periods.",
                    'priority': 0.5,
                    'details': f"Analyzed metrics: {list(results['metric_stats'].keys())}. Check 'sustained_high_usage' for details."
                })
            return results
        except Exception as e:
            self.logger.error(f"Analyzing resource usage patterns failed: {str(e)}", exc_info=True)
            return {'metric_stats': {}, 'sustained_high_usage': [], 'recommendations': []}


    def identify_bottlenecks(self, data: pd.DataFrame) -> Dict[str, Any]:
        """Identify performance bottlenecks based on configured rules."""
        self.logger.info("Identifying bottlenecks...")
        results = {'detected_bottlenecks': [], 'recommendations': []}

        bottleneck_rules = self.config.get('bottleneck_rules', [])
        if not bottleneck_rules:
            self.logger.info("No bottleneck rules defined in config.")
            return results
        if data.empty:
            self.logger.warning("DataFrame is empty for bottleneck detection.")
            return results
        try:
            for rule in bottleneck_rules:
                rule_name = rule.get('name', 'UnnamedBottleneckRule')
                conditions = rule.get('conditions', [])
                if not conditions: continue

                combined_condition = pd.Series([True] * len(data), index=data.index)
                for cond in conditions:
                    metric, operator, threshold = cond.get('metric'), cond.get('operator'), cond.get('threshold')
                    if not all([metric, operator, threshold is not None]) or metric not in data.columns:
                        self.logger.warning(f"Invalid or incomplete condition for bottleneck rule '{rule_name}': {cond}")
                        combined_condition = pd.Series([False] * len(data), index=data.index) # Rule cannot be met
                        break

                    series_metric = data[metric]
                    if operator == '>': condition_met = series_metric > threshold
                    elif operator == '<': condition_met = series_metric < threshold
                    # Add other operators as needed (>=, <=, ==)
                    else:
                        self.logger.warning(f"Unsupported operator '{operator}' in bottleneck rule '{rule_name}'.")
                        condition_met = pd.Series([False] * len(data), index=data.index)
                    combined_condition &= condition_met

                if combined_condition.any():
                    results['detected_bottlenecks'].append({
                        'type': rule_name,
                        'description': rule.get('description', f"Bottleneck '{rule_name}' conditions met."),
                        'occurrences': int(combined_condition.sum()),
                        # Optionally, add timestamps of occurrences if 'timestamp' column exists
                        'example_timestamp': data.loc[combined_condition.idxmax(), 'timestamp'].isoformat() if 'timestamp' in data and combined_condition.any() else None
                    })

            if results['detected_bottlenecks']:
                results['recommendations'].append({
                    'action': "Investigate detected performance bottlenecks based on rule violations.",
                    'priority': 0.75,
                    'details': f"Detected bottleneck types: {[b['type'] for b in results['detected_bottlenecks']]}."
                })
            return results
        except Exception as e:
            self.logger.error(f"Identifying bottlenecks failed: {str(e)}", exc_info=True)
            return {'detected_bottlenecks': [], 'recommendations': []}


    def analyze_performance_trends(self, data: pd.DataFrame) -> Dict[str, Any]:
        """Analyze performance trends for key metrics using linear regression."""
        self.logger.info("Analyzing performance trends...")
        results = {'trends': [], 'recommendations': []}
        if 'timestamp' not in data.columns:
            self.logger.warning("Timestamp column required for performance trend analysis.")
            return results
        if data.empty:
             self.logger.warning("DataFrame is empty for performance trend analysis.")
             return results
        try:
            df = data.sort_values(by='timestamp').copy()
            time_numeric = (df['timestamp'] - df['timestamp'].min()).dt.total_seconds()

            performance_metrics = self.config.get('performance_metrics', ['cpu_usage', 'memory_usage', 'response_time'])
            p_value_threshold = self.config.get('trend_p_value_threshold', 0.05)
            slope_significance_threshold = self.config.get('trend_slope_magnitude_threshold', 0.01) # Min abs slope to be "interesting"


            for metric in performance_metrics:
                if metric not in df.columns or not is_numeric_dtype(df[metric]):
                    self.logger.warning(f"Metric '{metric}' not found or not numeric for trend analysis.")
                    continue

                series_data = df[metric]
                valid_indices = time_numeric.notna() & series_data.notna()

                if valid_indices.sum() < 3: # linregress needs at least 3 points
                    continue

                current_time_numeric = time_numeric[valid_indices]
                current_metric_data = series_data[valid_indices]

                try:
                    slope, intercept, r_value, p_value, stderr = linregress(current_time_numeric, current_metric_data)
                    direction = 'stable'
                    if slope > slope_significance_threshold: direction = 'increasing'
                    elif slope < -slope_significance_threshold: direction = 'decreasing'

                    if p_value < p_value_threshold and direction != 'stable':
                        results['trends'].append({
                            'metric': metric,
                            'slope': round(slope, 4),
                            'p_value': round(p_value, 4),
                            'r_squared': round(r_value**2, 3),
                            'direction': direction,
                            'stderr': round(stderr, 4)
                        })
                except Exception as e_lin:
                     self.logger.debug(f"Linregress failed for metric '{metric}': {e_lin}")


            if results['trends']:
                results['recommendations'].append({
                    'action': "Review significant performance trends for proactive capacity management or optimization.",
                    'priority': 0.6,
                    'details': f"Significant trends identified for metrics: {[t['metric'] for t in results['trends']]}."
                })
            return results
        except Exception as e:
            self.logger.error(f"Analyzing performance trends failed: {str(e)}", exc_info=True)
            return {'trends': [], 'recommendations': []}


    def analyze_performance_patterns(self, data: pd.DataFrame) -> Dict[str, Any]:
        """Analyze performance patterns in the data."""
        try:
            usage_patterns = self.analyze_resource_usage_patterns(data.copy())
            bottlenecks = self.identify_bottlenecks(data.copy())
            trends = self.analyze_performance_trends(data.copy())

            all_recommendations = []
            all_recommendations.extend(usage_patterns.get("recommendations", []))
            all_recommendations.extend(bottlenecks.get("recommendations", []))
            all_recommendations.extend(trends.get("recommendations", []))

            return {
                'resource_usage': usage_patterns,
                'bottlenecks': bottlenecks,
                'trends': trends,
                'recommendations': all_recommendations
            }
        except Exception as e:
            self.logger.error(f"Performance pattern analysis failed: {str(e)}", exc_info=True)
            return {"resource_usage": {}, "bottlenecks": {}, "trends": {}, "recommendations": []}

    def prepare_behavioral_features(self, data: pd.DataFrame) -> Tuple[np.ndarray, List[str]]:
        """Prepare features for behavioral analysis based on configuration."""
        self.logger.info("Preparing behavioral features...")
        feature_list_config = self.config.get('behavioral_features', [])
        if not feature_list_config:
            self.logger.warning("No features configured in 'behavioral_features'. Returning empty array.")
            return np.array([]).reshape(0,0), []

        valid_features = []
        used_feature_names = []
        for col_name in feature_list_config:
            if col_name in data.columns and is_numeric_dtype(data[col_name]):
                # Fill NaNs with mean for clustering features, or consider other strategies
                valid_features.append(data[col_name].fillna(data[col_name].mean()).values)
                used_feature_names.append(col_name)
            else:
                self.logger.warning(f"Feature '{col_name}' for behavioral analysis not found or not numeric. Skipping.")

        if not valid_features:
            self.logger.warning("No valid behavioral features could be extracted. Returning empty array.")
            return np.array([]).reshape(0,0), []

        return np.column_stack(valid_features), used_feature_names


    def analyze_clusters(self, features_array: np.ndarray, labels: np.ndarray, feature_names: List[str]) -> Dict[str, Any]:
        """Analyze identified clusters, using feature names for context."""
        self.logger.info("Analyzing clusters...")
        n_clusters_ = len(set(labels)) - (1 if -1 in labels else 0)
        n_noise_ = list(labels).count(-1)
        self.logger.info(f"Estimated number of clusters: {n_clusters_}")
        self.logger.info(f"Estimated number of noise points: {n_noise_}")

        clusters_summary = {}
        for i in range(n_clusters_):
            cluster_points = features_array[labels == i]
            if cluster_points.shape[0] == 0: continue # Should not happen if labels are from fit

            # Calculate center (mean for each feature)
            center_values = np.mean(cluster_points, axis=0)
            center_dict = {name: round(center_values[j], 3) for j, name in enumerate(feature_names)}

            # Calculate variance for each feature
            variance_values = np.var(cluster_points, axis=0)
            variance_dict = {name: round(variance_values[j], 3) for j, name in enumerate(feature_names)}

            clusters_summary[f'cluster_{i}'] = {
                'size': len(cluster_points),
                'center_features': center_dict,
                'variance_features': variance_dict,
                # 'characteristics': self.analyze_cluster_characteristics(cluster_points) # Original method might be too generic
                # Add more specific characteristics if needed, e.g. range of key features within cluster
            }

        if n_noise_ > 0:
            clusters_summary['noise_points'] = {
                'size': n_noise_,
                'description': 'Points not assigned to any cluster by DBSCAN.'
            }
        return clusters_summary

    # analyze_cluster_characteristics, calculate_cluster_stability, etc. might be too generic.
    # Specific interpretations are often more useful directly within analyze_clusters or a higher-level method.
    # Keeping them if they are used, but they might need to be adapted or removed if not providing clear value.
    # For now, I'll keep them as they were, assuming they might be used by other parts or future enhancements.

    def analyze_cluster_characteristics(self, cluster_points: np.ndarray) -> Dict[str, Any]:
        """Analyze characteristics of a cluster."""
        # This method might be too generic. If features_array has named columns, this could be more specific.
        # For now, it calculates generic stats.
        if cluster_points.ndim == 1: cluster_points = cluster_points.reshape(-1,1) # Ensure 2D for ptp
        if cluster_points.shape[0] == 0: return {}

        return {
            'stability_std_mean': self.calculate_cluster_stability(cluster_points), # Mean of std devs of features
            'density_crude': self.calculate_cluster_density(cluster_points), # Crude density
            'isolation_mean_dist_center': self.calculate_cluster_isolation(cluster_points) # Mean distance from center
        }

    def calculate_cluster_stability(self, cluster_points: np.ndarray) -> float:
        """Calculate stability metric for a cluster (mean of standard deviations of its features)."""
        if cluster_points.shape[0] < 2: return 0.0 # Std dev not meaningful for single point
        return float(np.std(cluster_points, axis=0).mean())

    def calculate_cluster_density(self, cluster_points: np.ndarray) -> float:
        """Calculate density metric for a cluster. Crude measure."""
        if cluster_points.shape[0] == 0: return 0.0
        if cluster_points.ndim == 1: cluster_points = cluster_points.reshape(-1,1)

        volume = np.prod(np.ptp(cluster_points, axis=0)) if cluster_points.shape[0] > 1 else 1.0
        if volume == 0: # Avoid division by zero if all points are same or in lower dimension
            return float('inf') if len(cluster_points) > 0 else 0.0
        return float(len(cluster_points) / volume)

    def calculate_cluster_isolation(self, cluster_points: np.ndarray) -> float:
        """Calculate isolation metric for a cluster (mean distance from its center)."""
        if cluster_points.shape[0] == 0: return 0.0
        center = np.mean(cluster_points, axis=0)
        distances = np.linalg.norm(cluster_points - center, axis=1)
        return float(np.mean(distances))

    # Ensure all top-level analysis methods are robust and return dicts with 'recommendations'
    # analyze_temporal_patterns - already updated
    # analyze_behavioral_patterns - updated
    # analyze_failure_patterns - updated
    # analyze_performance_patterns - updated
        """Analyze identified clusters."""
        n_clusters = len(set(labels)) - (1 if -1 in labels else 0)
        clusters = {}

        for i in range(n_clusters):
            cluster_points = features[labels == i]
            clusters[f'cluster_{i}'] = {
                'size': len(cluster_points),
                'center': np.mean(cluster_points, axis=0),
                'variance': np.var(cluster_points, axis=0),
                'characteristics': self.analyze_cluster_characteristics(cluster_points)
            }

        return clusters

    def analyze_cluster_characteristics(self, cluster_points: np.ndarray) -> Dict[str, Any]:
        """Analyze characteristics of a cluster."""
        return {
            'stability': self.calculate_cluster_stability(cluster_points),
            'density': self.calculate_cluster_density(cluster_points),
            'isolation': self.calculate_cluster_isolation(cluster_points)
        }

    def calculate_cluster_stability(self, cluster_points: np.ndarray) -> float:
        """Calculate stability metric for a cluster."""
        return float(np.std(cluster_points, axis=0).mean())

    def calculate_cluster_density(self, cluster_points: np.ndarray) -> float:
        """Calculate density metric for a cluster."""
        return float(len(cluster_points) / np.prod(np.ptp(cluster_points, axis=0)))

    def calculate_cluster_isolation(self, cluster_points: np.ndarray) -> float:
        """Calculate isolation metric for a cluster."""
        center = np.mean(cluster_points, axis=0)
        distances = np.linalg.norm(cluster_points - center, axis=1)
        return float(np.mean(distances))
from typing import Dict, List, Any
import pandas as pd
import numpy as np
import logging
from datetime import datetime
from .pattern_analyzer import PatternAnalyzer
import re # For keyword searching

class SimpleRCAEstimator:
    def __init__(self, config: Dict[str, Any] = None):
        self.config = config if config else {}
        self.logger = logging.getLogger('SimpleRCAEstimator')
        self.rules = self.config.get('rules', {
            "cpu": {"cause": "CPU Overload", "recommendation": "Scale CPU resources or optimize high-CPU processes.", "impact_score": 0.7, "metric_threshold": 0.9},
            "memory": {"cause": "Memory Exhaustion", "recommendation": "Increase memory or investigate memory leaks.", "impact_score": 0.8, "metric_threshold": 0.9},
            "network": {"cause": "Network Connectivity Issue", "recommendation": "Check network cables, DNS, and firewall settings.", "impact_score": 0.9}, # No specific metric here, relies on keywords
            "disk": {"cause": "Disk I/O Bottleneck", "recommendation": "Optimize disk usage or upgrade storage.", "impact_score": 0.6, "metric_threshold": 0.85}, # e.g. disk_utilization
            "error": {"cause": "Application Error", "recommendation": "Review application logs for specific error messages.", "impact_score": 0.5} # Relies on keywords
        })
        self.default_confidence = self.config.get('default_confidence', 0.75)

    def predict_root_cause(self, incident_data: Dict[str, Any]) -> List[Dict[str, Any]]:
        self.logger.info(f"Predicting root cause for incident: {incident_data.get('description', 'No description')}")
        potential_causes = []

        description = incident_data.get('description', '').lower()
        metrics = incident_data.get('metrics', {})

        for keyword, rule_details in self.rules.items():
            triggered = False
            trigger_reason = ""

            # Check keywords in description
            if re.search(r'\b' + re.escape(keyword) + r'\b', description):
                triggered = True
                trigger_reason = f"Keyword '{keyword}' found in description."
                self.logger.debug(f"Rule for '{keyword}' triggered by description.")

            # Check related metrics if applicable
            metric_key = f"{keyword}_usage" # e.g. cpu_usage, memory_usage
            if keyword in metrics : # Direct metric name match e.g. incident_data.metrics.cpu > threshold
                 metric_val = metrics.get(keyword)
                 if isinstance(metric_val, (int,float)) and rule_details.get("metric_threshold") and metric_val >= rule_details["metric_threshold"]:
                    triggered = True
                    trigger_reason += f" Metric '{keyword}' ({metric_val}) exceeded threshold ({rule_details['metric_threshold']})."
                    self.logger.debug(f"Rule for '{keyword}' triggered by metric value.")
            elif metric_key in metrics: # Check for e.g. cpu_usage if keyword is 'cpu'
                metric_val = metrics.get(metric_key)
                if isinstance(metric_val, (int,float)) and rule_details.get("metric_threshold") and metric_val >= rule_details["metric_threshold"]:
                    triggered = True
                    trigger_reason += f" Metric '{metric_key}' ({metric_val}) exceeded threshold ({rule_details['metric_threshold']})."
                    self.logger.debug(f"Rule for '{keyword}' (metric: {metric_key}) triggered by metric value.")


            if triggered:
                potential_causes.append({
                    'type': rule_details["cause"],
                    'confidence': self.default_confidence, # Could be adjusted based on strength of match
                    'recommendation': rule_details["recommendation"],
                    'impact': rule_details["impact_score"],
                    'trigger_reason': trigger_reason.strip()
                })

        if not potential_causes:
            self.logger.info("No specific rules matched. Returning default cause.")
            potential_causes.append({
                'type': "Unknown/Complex Issue",
                'confidence': 0.3,
                'recommendation': "Requires further detailed investigation. Review logs and full telemetry.",
                'impact': 0.5, # Default impact
                'trigger_reason': "No specific rule matched the incident data."
            })

        # Sort by impact (descending) then confidence (descending)
        potential_causes.sort(key=lambda x: (x['impact'], x['confidence']), reverse=True)
        return potential_causes

class SimpleRCAExplainer:
    def __init__(self, config: Dict[str, Any] = None):
        self.config = config if config else {}
        self.logger = logging.getLogger('SimpleRCAExplainer')

    def _generate_factor_explanation(self, cause: Dict[str, Any], incident_data: Dict[str, Any]) -> str:
        # Helper to generate explanation for a single cause
        return (f"The factor '{cause['type']}' (Impact: {cause['impact']}, Confidence: {cause['confidence']}) "
                f"is suspected. Trigger: {cause.get('trigger_reason', 'N/A')}. "
                f"Recommended action: {cause['recommendation']}")

    def explain_prediction(self, causes: List[Dict[str, Any]], incident_data: Dict[str, Any]) -> Dict[str, Any]:
        self.logger.info(f"Generating explanation for {len(causes)} potential causes.")
        primary_explanation_str = "No primary cause identified."
        factor_explanations_list = []

        if not causes:
            return {
                'primary_explanation': primary_explanation_str,
                'factor_explanations': factor_explanations_list
            }

        # Assuming causes are sorted by importance (e.g., impact/confidence) by the estimator
        primary_cause = causes[0]
        primary_explanation_str = (
            f"The primary suspected cause is '{primary_cause['type']}' (Impact: {primary_cause['impact']}, Confidence: {primary_cause['confidence']}). "
            f"This is based on: {primary_cause.get('trigger_reason', 'general assessment of incident data')}."
        )

        for cause in causes:
            factor_explanations_list.append(self._generate_factor_explanation(cause, incident_data))

        return {
            'primary_explanation': primary_explanation_str,
            'factor_explanations': factor_explanations_list
        }

class RootCauseAnalyzer:
    """[TODO: Add class documentation]"""
    def __init__(self, config: Dict[str, Any]):
        """[TODO: Add method documentation]"""
        self.config = config
        self.pattern_analyzer = PatternAnalyzer(self.config.get('pattern_analyzer_config', {})) # Pass relevant sub-config
        self.ml_model = SimpleRCAEstimator(self.config.get('rca_estimator_config', {}))
        self.explainer = SimpleRCAExplainer(self.config.get('rca_explainer_config', {}))
        self.setup_logging()

    def setup_logging(self):
        """[TODO: Add method documentation]"""
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            filename=f'root_cause_analyzer_{datetime.now().strftime("%Y%m%d")}.log'
        )
        self.logger = logging.getLogger('RootCauseAnalyzer')

    def analyze_incident(self, incident_data: Dict[str, Any]) -> Dict[str, Any]:
        """Enhanced incident analysis using pattern recognition and simple RCA."""
        try:
            self.logger.info(f"Starting incident analysis for: {incident_data.get('description', 'N/A')}")
            # Convert relevant parts of incident data for pattern analysis if applicable
            # PatternAnalyzer expects a DataFrame. If incident_data contains time-series metrics, use those.
            # For now, if 'metrics_timeseries' is a key in incident_data, assume it's a list of dicts for a DF.
            # Otherwise, pattern analysis might be limited.
            metrics_timeseries = incident_data.get('metrics_timeseries')
            if metrics_timeseries and isinstance(metrics_timeseries, list):
                df_for_patterns = pd.DataFrame(metrics_timeseries)
            elif incident_data.get('metrics'): # If single point metrics, wrap in list for DF
                df_for_patterns = pd.DataFrame([incident_data.get('metrics')])
            else: # Fallback to an empty DataFrame or a DataFrame from the main incident_data structure
                # This might not be ideal for all pattern types but prevents errors.
                # Consider which fields from incident_data are relevant for patterns.
                df_for_patterns = pd.DataFrame([incident_data])
            
            # Ensure 'timestamp' column exists for pattern analyzer if possible
            if 'timestamp' not in df_for_patterns.columns and 'timestamp' in incident_data:
                 # If single incident_data has a timestamp, apply it to all rows in df_for_patterns
                 # This is a simplification; ideally, metrics_timeseries would have timestamps
                try:
                    df_for_patterns['timestamp'] = pd.to_datetime(incident_data['timestamp'])
                except Exception as e_ts:
                    self.logger.warning(f"Could not convert incident_data timestamp for pattern analysis: {e_ts}")


            patterns = self.pattern_analyzer.analyze_patterns(df_for_patterns)
            
            # Predict root causes using the simple rule-based estimator
            # incident_data itself is passed, as it contains description and metrics.
            predicted_causes = self.ml_model.predict_root_cause(incident_data) # List of Cause dicts
            
            # Generate explanation using the simple explainer
            explanation_details = self.explainer.explain_prediction(predicted_causes, incident_data) # Explanation dict
            
            analysis_result = {
                'incident_description': incident_data.get('description', 'N/A'),
                'predicted_root_causes': [], # Will be populated below
                'explanation': explanation_details, # Contains 'primary_explanation' and 'factor_explanations'
                'identified_patterns': patterns, # Output from PatternAnalyzer
                'actionable_recommendations': [] # Will be populated by generate_recommendations
            }

            if predicted_causes:
                analysis_result['predicted_root_causes'] = predicted_causes
                # The first cause in the sorted list is considered the primary one
                primary_cause_details = predicted_causes[0]
                analysis_result['primary_suspected_cause'] = {
                    'type': primary_cause_details['type'],
                    'confidence': primary_cause_details['confidence'],
                    'impact': primary_cause_details['impact'],
                    'recommendation': primary_cause_details['recommendation'],
                    'trigger_reason': primary_cause_details.get('trigger_reason')
                }

            # Generate recommendations based on both predicted causes and identified patterns
            analysis_result['actionable_recommendations'] = self.generate_recommendations(predicted_causes, patterns)

            self.logger.info("Incident analysis complete.")
            return analysis_result

        except Exception as e:
            self.logger.error(f"Incident analysis failed: {str(e)}", exc_info=True)
            # Return a structured error as part of the result if possible, or re-raise
            # For now, re-raising to indicate failure to the caller clearly.
            raise

    def generate_recommendations(
        self,
        causes: List[Dict[str, Any]], # Updated to expect list of dicts
        patterns_analysis: Dict[str, Any]
    ) -> List[Dict[str, Any]]:
        """Generate enhanced recommendations based on causes and patterns."""
        self.logger.info("Generating recommendations...")
        recommendations = []

        # Add cause-based recommendations
        for cause in causes:
            # Ensure cause is a dictionary with expected keys
            if isinstance(cause, dict):
                recommendations.append({
                    'action': cause.get('recommendation', 'Review cause details.'),
                    'priority_score': cause.get('impact', 0.5) * cause.get('confidence', 0.5), # Example priority
                    'source': 'RootCauseEstimator',
                    'details': f"Related to cause: {cause.get('type', 'Unknown')}. Trigger: {cause.get('trigger_reason', 'N/A')}"
                })

        # Add pattern-based recommendations
        # Iterate through different pattern types (temporal, failure, performance)
        for pattern_type_key, pattern_data in patterns_analysis.items():
            if isinstance(pattern_data, dict) and "recommendations" in pattern_data:
                for rec in pattern_data["recommendations"]:
                     if isinstance(rec, dict) and 'action' in rec: # Ensure rec is a dict with 'action'
                        recommendations.append({
                            'action': rec['action'],
                            'priority_score': rec.get('priority', 0.3), # Use priority from pattern if available
                            'source': f'PatternAnalyzer ({pattern_type_key})',
                            'details': rec.get('details', '')
                        })
            # Handle cases where recommendations might be nested further (e.g. patterns_analysis['temporal']['daily']['recommendations'])
            elif isinstance(pattern_data, dict): # Check sub-dictionaries like 'daily', 'weekly' etc.
                for sub_pattern_key, sub_pattern_data in pattern_data.items():
                    if isinstance(sub_pattern_data, dict) and "recommendations" in sub_pattern_data:
                        for rec in sub_pattern_data["recommendations"]:
                            if isinstance(rec, dict) and 'action' in rec:
                                recommendations.append({
                                    'action': rec['action'],
                                    'priority_score': rec.get('priority', 0.3),
                                    'source': f'PatternAnalyzer ({pattern_type_key}.{sub_pattern_key})',
                                    'details': rec.get('details', '')
                                })


        # Prioritize and deduplicate recommendations
        return self._prioritize_recommendations(recommendations)

    # _get_cause_recommendations can be removed if logic is integrated above or kept if more complex per-cause rec generation is needed.
    # For now, the logic is simple enough to be integrated.

    def _get_pattern_recommendations(self, patterns_data: Dict[str, Any]) -> List[Dict[str, Any]]:
        # This method might be redundant if generate_recommendations directly processes pattern_analysis output.
        # Keeping it for now, but it might need to be adapted or removed.
        # The current generate_recommendations already iterates through pattern_analysis.
        """Generate recommendations based on identified patterns"""
        recommendations = []
        for pattern in patterns.get('common_causes', []):
            recommendations.append({
                'action': f"Address recurring pattern: {pattern['name']}",
                'priority': pattern['frequency'],
                'details': pattern['description'],
                'impact': pattern['impact']
            })
        return recommendations

    def _prioritize_recommendations(
        self,
        recommendations: List[Dict[str, Any]]
    ) -> List[Dict[str, Any]]:
        """[TODO: Add method documentation]"""
        # Sort by priority and impact
        sorted_recs = sorted(
            recommendations,
            key=lambda x: (x['priority'], x.get('impact', 0)),
            reverse=True
        )

        # Remove duplicates while preserving order
        seen = set()
        unique_recs = []
        for rec in sorted_recs:
            action_key = rec['action']
            if action_key not in seen:
                seen.add(action_key)
                unique_recs.append(rec)

        return unique_recs
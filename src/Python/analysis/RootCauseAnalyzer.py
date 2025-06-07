from typing import Dict, List, Any
import pandas as pd
import numpy as np
import logging
from datetime import datetime
from .pattern_analyzer import PatternAnalyzer
import re # For keyword searching

class SimpleRCAEstimator:
    """[TODO: Add class documentation]"""
    def __init__(self, config: Dict[str, Any] = None):
        """[TODO: Add method documentation]"""
        self.config = config if config else {}
        self.logger = logging.getLogger('SimpleRCAEstimator')

        default_rules = {
            "cpu_rule": {
                "keywords_any": ["cpu", "processor"],
                "metrics_thresholds": [{"metric": "cpu_usage_avg", "threshold": 0.9, "operator": ">="}],
                "cause": "CPU Overload", "recommendation": "Scale CPU resources or optimize high-CPU processes.",
                "impact_score": 0.7, "base_confidence": 0.7
            },
            "memory_rule": {
                "keywords_any": ["memory", "ram", "exhausted"],
                "metrics_thresholds": [{"metric": "memory_usage_avg", "threshold": 0.9, "operator": ">="}],
                "cause": "Memory Exhaustion", "recommendation": "Increase memory or investigate memory leaks.",
                "impact_score": 0.8, "base_confidence": 0.7
            },
            "network_connectivity_rule": {
                "keywords_any": ["network", "connectivity", "unreachable", "timeout"],
                # No specific metric here, relies on keywords primarily
                "cause": "Network Connectivity Issue", "recommendation": "Check network cables, DNS, firewall settings, and dependent services.",
                "impact_score": 0.9, "base_confidence": 0.65
            },
            "disk_io_rule": {
                "keywords_any": ["disk", "io", "slow storage", "iops"],
                "metrics_thresholds": [{"metric": "disk_queue_length", "threshold": 10, "operator": ">"}, {"metric": "disk_latency_ms", "threshold": 50, "operator": ">"}],
                "cause": "Disk I/O Bottleneck", "recommendation": "Optimize disk usage, check for failing hardware, or upgrade storage.",
                "impact_score": 0.6, "base_confidence": 0.6
            },
            "application_error_rule": {
                "keywords_all": ["application"], # Must contain "application"
                "keywords_any": ["error", "exception", "failed", "stack trace", "log error"],
                "cause": "Application Code Error", "recommendation": "Review application logs for specific error messages and stack traces. Escalate to development team if necessary.",
                "impact_score": 0.75, "base_confidence": 0.7
            },
             "latency_rule": {
                "keywords_any": ["latency", "slow response", "performance degradation"],
                "metrics_thresholds": [{"metric": "response_time_p95", "threshold": 1000, "operator": ">"}], # Example: p95 response time > 1000ms
                "cause": "Performance Bottleneck", "recommendation": "Investigate application and infrastructure components for bottlenecks affecting response times.",
                "impact_score": 0.65, "base_confidence": 0.6
            },
            "security_alert_rule": {
                "keywords_all": ["security"], # Must contain "security"
                "keywords_any": ["alert", "unauthorized access", "breach", "vulnerability"],
                "cause": "Security Incident", "recommendation": "Isolate affected systems immediately. Escalate to security team. Review audit logs and security alerts.",
                "impact_score": 0.95, "base_confidence": 0.8
            }
        }
        self.rules = self.config.get('rules', default_rules)
        self.multi_condition_confidence_boost = self.config.get('multi_condition_confidence_boost', 0.1)


    def predict_root_cause(self, incident_data: Dict[str, Any]) -> List[Dict[str, Any]]:
        """[TODO: Add method documentation]"""
        self.logger.info(f"Predicting root cause for incident: {incident_data.get('description', 'No description')[:100]}...") # Log snippet
        potential_causes = []

        description = incident_data.get('description', '').lower()
        metrics = incident_data.get('metrics', {}) # Assuming metrics is a flat dict now

        for rule_name, rule_details in self.rules.items():
            self.logger.debug(f"Evaluating rule: {rule_name}")
            trigger_reasons_list = []

            # Keyword matching
            keyword_match_all_met = True
            if rule_details.get('keywords_all'):
                all_present = True
                for kw in rule_details['keywords_all']:
                    if not re.search(r'\b' + re.escape(kw.lower()) + r'\b', description):
                        all_present = False
                        break
                if all_present:
                    trigger_reasons_list.append(f"Matched all keywords: {rule_details['keywords_all']}")
                else:
                    keyword_match_all_met = False

            keyword_match_any_met = True # True if no 'keywords_any' defined
            if rule_details.get('keywords_any'):
                any_present = False
                matched_any_kws = []
                for kw in rule_details['keywords_any']:
                    if re.search(r'\b' + re.escape(kw.lower()) + r'\b', description):
                        any_present = True
                        matched_any_kws.append(kw)
                if any_present:
                    trigger_reasons_list.append(f"Matched one or more keywords: {matched_any_kws}")
                else:
                    keyword_match_any_met = False # Only false if keywords_any is defined but none matched

            # Metric threshold matching
            metric_thresholds_met = True # True if no 'metrics_thresholds' defined
            if rule_details.get('metrics_thresholds'):
                all_metrics_match = True
                for cond in rule_details['metrics_thresholds']:
                    metric_name = cond.get('metric')
                    threshold = cond.get('threshold')
                    operator = cond.get('operator', '>') # Default operator

                    metric_val = metrics.get(metric_name)
                    if metric_val is None: # Metric not present in incident data
                        all_metrics_match = False; break
                    if not isinstance(metric_val, (int, float)): # Metric not numeric
                        self.logger.warning(f"Metric {metric_name} for rule {rule_name} is not numeric: {metric_val}")
                        all_metrics_match = False; break

                    condition_met_flag = False
                    if operator == '>': condition_met_flag = metric_val > threshold
                    elif operator == '>=': condition_met_flag = metric_val >= threshold
                    elif operator == '<': condition_met_flag = metric_val < threshold
                    elif operator == '<=': condition_met_flag = metric_val <= threshold
                    elif operator == '==': condition_met_flag = metric_val == threshold
                    else: self.logger.warning(f"Unsupported operator {operator} in rule {rule_name}"); continue

                    if condition_met_flag:
                        trigger_reasons_list.append(f"Metric '{metric_name}' ({metric_val}) met condition ({operator} {threshold})")
                    else:
                        all_metrics_match = False; break
                if not all_metrics_match:
                    metric_thresholds_met = False


            # Determine if rule is triggered based on combined logic
            rule_triggered = False
            has_keyword_conditions = bool(rule_details.get('keywords_all') or rule_details.get('keywords_any'))
            has_metric_conditions = bool(rule_details.get('metrics_thresholds'))

            if has_keyword_conditions and has_metric_conditions:
                rule_triggered = keyword_match_all_met and keyword_match_any_met and metric_thresholds_met
            elif has_keyword_conditions:
                rule_triggered = keyword_match_all_met and keyword_match_any_met
            elif has_metric_conditions:
                rule_triggered = metric_thresholds_met

            if rule_triggered:
                final_confidence = rule_details.get('base_confidence', 0.6)
                # Boost confidence if multiple types of conditions met effectively (e.g. keywords AND metrics)
                num_condition_types_met = 0
                if keyword_match_all_met and rule_details.get('keywords_all'): num_condition_types_met +=1
                if keyword_match_any_met and rule_details.get('keywords_any'): num_condition_types_met +=1 # This logic could be more nuanced
                if metric_thresholds_met and rule_details.get('metrics_thresholds'): num_condition_types_met +=1

                # Simplified: if both keyword group (any or all) and metrics were involved and met
                if ((keyword_match_all_met and rule_details.get('keywords_all')) or \
                    (keyword_match_any_met and rule_details.get('keywords_any'))) and \
                   (metric_thresholds_met and rule_details.get('metrics_thresholds')):
                    final_confidence = min(0.95, final_confidence + self.multi_condition_confidence_boost)

                potential_causes.append({
                    'type': rule_details["cause"],
                    'confidence': round(final_confidence, 2),
                    'recommendation': rule_details["recommendation"],
                    'impact': rule_details["impact_score"],
                    'trigger_reason': "; ".join(trigger_reasons_list)
                })
                self.logger.debug(f"Rule '{rule_name}' triggered. Details: {potential_causes[-1]}")

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
    """[TODO: Add class documentation]"""
    def __init__(self, config: Dict[str, Any] = None):
        """[TODO: Add method documentation]"""
        self.config = config if config else {}
        self.logger = logging.getLogger('SimpleRCAExplainer')

    def _generate_factor_explanation(self, cause: Dict[str, Any], incident_data: Dict[str, Any]) -> str:
        # Helper to generate explanation for a single cause
        return (f"The factor '{cause['type']}' (Impact: {cause['impact']}, Confidence: {cause['confidence']}) "
                f"is suspected. Trigger: {cause.get('trigger_reason', 'N/A')}. "
                f"Recommended action: {cause['recommendation']}")

    def explain_prediction(self, causes: List[Dict[str, Any]], incident_data: Dict[str, Any]) -> Dict[str, Any]:
        """[TODO: Add method documentation]"""
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
        """[TODO: Add method documentation]"""
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
        """[TODO: Add method documentation]"""
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
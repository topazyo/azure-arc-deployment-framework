from typing import Dict, List, Any
import pandas as pd
import numpy as np
import logging
from datetime import datetime
from .pattern_analyzer import PatternAnalyzer
import re # For keyword searching

class SimpleRCAEstimator:
    """
    Estimates the root cause of an incident based on a set of predefined rules.

    The class uses a rule-based approach to match incident data (description, metrics)
    against configured rules. Each rule defines keywords, metric thresholds,
    a potential cause, a recommendation, an impact score, and a base confidence.
    """
    def __init__(self, config: Dict[str, Any] = None):
        """
        Initializes the SimpleRCAEstimator.

        Args:
            config: A dictionary containing configuration for the estimator.
                    This includes rules for matching incidents and confidence boost values.
                    If None, default rules are used.
        """
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
        # Used by the simplified rule schema in tests (rules that don't specify base_confidence)
        self.default_confidence = self.config.get('default_confidence', 0.6)


    def predict_root_cause(self, incident_data: Dict[str, Any]) -> List[Dict[str, Any]]:
        """
        Predicts potential root causes for a given incident.

        The method iterates through the configured rules, checking for matches
        based on keywords in the incident description and metric thresholds.
        Confidence scores are calculated for matched rules.

        Args:
            incident_data: A dictionary containing details of the incident.
                           Expected keys include 'description' (str) and 'metrics' (Dict[str, float]).

        Returns:
            A list of dictionaries, where each dictionary represents a potential root cause.
            Each cause includes 'type', 'confidence', 'recommendation', 'impact', and 'trigger_reason'.
            The list is sorted by impact and then confidence in descending order.
            Returns a default "Unknown/Complex Issue" if no rules match.
        """
        self.logger.info(f"Predicting root cause for incident: {incident_data.get('description', 'No description')[:100]}...") # Log snippet
        potential_causes = []

        description = str(incident_data.get('description', '')).lower()
        metrics = incident_data.get('metrics', {})
        # Some callers/tests provide metrics as top-level keys rather than nested under "metrics".
        if not isinstance(metrics, dict) or not metrics:
            metrics = {k: v for k, v in incident_data.items() if k not in {'description', 'metrics', 'metrics_timeseries', 'timestamp', 'priority', 'incident_id'}}

        def _metric_value_from_contains(substr: str) -> Any:
            """Return the max numeric metric value whose name contains substr (case-insensitive)."""
            if not substr:
                return None
            substr_l = substr.lower()
            candidates: List[float] = []
            for key, value in (metrics or {}).items():
                if substr_l in str(key).lower() and isinstance(value, (int, float)):
                    if not (np.isnan(value) or np.isinf(value)):
                        candidates.append(float(value))
            return max(candidates) if candidates else None

        for rule_name, rule_details in self.rules.items():
            self.logger.debug(f"Evaluating rule: {rule_name}")
            trigger_reasons_list = []

            # Support a simplified rule schema (used in tests) where the rule name itself
            # acts as the keyword (e.g. "network error"), and a single numeric threshold
            # is provided via "metric_threshold".
            if 'keywords_any' not in rule_details and 'keywords_all' not in rule_details:
                rule_details = {
                    **rule_details,
                    'keywords_any': [str(rule_name)]
                }

            if 'metrics_thresholds' not in rule_details and 'metric_threshold' in rule_details:
                rule_details = {
                    **rule_details,
                    'metrics_thresholds': [
                        {
                            'metric_contains': str(rule_name),
                            'threshold': rule_details.get('metric_threshold'),
                            'operator': '>'
                        }
                    ]
                }

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
                    metric_contains = cond.get('metric_contains')
                    threshold = cond.get('threshold')
                    operator = cond.get('operator', '>') # Default operator

                    if metric_name:
                        metric_val = metrics.get(metric_name)
                    elif metric_contains:
                        metric_val = _metric_value_from_contains(str(metric_contains))
                    else:
                        metric_val = None
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
                final_confidence = rule_details.get('base_confidence', self.default_confidence)
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
                    'type': rule_details.get("cause", "Unknown"),
                    'confidence': round(final_confidence, 2),
                    'recommendation': rule_details.get("recommendation", "Review incident details."),
                    'impact': rule_details.get("impact_score", 0.5),
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
    """
    Generates human-readable explanations for predicted root causes.

    This class takes the output from an RCA estimator (like SimpleRCAEstimator)
    and constructs textual explanations for the identified potential causes.
    """
    def __init__(self, config: Dict[str, Any] = None):
        """
        Initializes the SimpleRCAExplainer.

        Args:
            config: A dictionary for potential future configuration. Currently unused.
        """
        self.config = config if config else {}
        self.logger = logging.getLogger('SimpleRCAExplainer')

    def _generate_factor_explanation(self, cause: Dict[str, Any], incident_data: Dict[str, Any]) -> str:
        # Helper to generate explanation for a single cause
        return (f"The factor '{cause['type']}' (Impact: {cause['impact']}, Confidence: {cause['confidence']}) "
                f"is suspected. Trigger: {cause.get('trigger_reason', 'N/A')}. "
                f"Recommended action: {cause['recommendation']}")

    def explain_prediction(self, causes: List[Dict[str, Any]], incident_data: Dict[str, Any]) -> Dict[str, Any]:
        """
        Generates explanations for the predicted root causes.

        It identifies a primary cause (the first in the sorted list) and provides
        a detailed explanation for it. It also lists explanations for all other
        potential factors.

        Args:
            causes: A list of potential root cause dictionaries, typically from an RCA estimator.
                    Each dictionary should contain 'type', 'impact', 'confidence', 'trigger_reason',
                    and 'recommendation'.
            incident_data: The original incident data dictionary, used for context if needed.

        Returns:
            A dictionary containing:
                - 'primary_explanation' (str): A detailed explanation for the most likely cause.
                - 'factor_explanations' (List[str]): A list of strings, each explaining a potential factor.
        """
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
            f"This is based on: {primary_cause.get('trigger_reason', 'general assessment of incident data')}. "
            f"Recommended action: {primary_cause.get('recommendation', 'Review incident details.')}."
        )

        for cause in causes:
            factor_explanations_list.append(self._generate_factor_explanation(cause, incident_data))

        return {
            'primary_explanation': primary_explanation_str,
            'factor_explanations': factor_explanations_list
        }

class RootCauseAnalyzer:
    """
    Orchestrates the root cause analysis process for incidents.

    This class integrates pattern analysis, root cause estimation, and explanation generation
    to provide a comprehensive analysis of an incident. It uses sub-components for
    each step: PatternAnalyzer, SimpleRCAEstimator, and SimpleRCAExplainer.
    """
    def __init__(self, config: Dict[str, Any]):
        """
        Initializes the RootCauseAnalyzer.

        Args:
            config: A dictionary containing configurations for the analyzer and its
                    sub-components (pattern_analyzer_config, rca_estimator_config,
                    rca_explainer_config).
        """
        self.config = config
        self.pattern_analyzer = PatternAnalyzer(self.config.get('pattern_analyzer_config', {})) # Pass relevant sub-config
        self.ml_model = SimpleRCAEstimator(self.config.get('rca_estimator_config', {}))
        self.explainer = SimpleRCAExplainer(self.config.get('rca_explainer_config', {}))
        self.setup_logging()

    def setup_logging(self):
        """
        Sets up logging for the RootCauseAnalyzer.

        Configures basic logging to write to a file named with the current date.
        Initializes a logger instance for the class.
        """
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

            # Legacy/placeholder aliases for older callers/tests
            if 'primary_suspected_cause' in analysis_result:
                analysis_result['primary_cause'] = analysis_result['primary_suspected_cause']
            analysis_result['recommendations'] = analysis_result['actionable_recommendations']

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

    # The _get_pattern_recommendations method has been removed as its functionality
    # is integrated into generate_recommendations.

    def _prioritize_recommendations(
        self,
        recommendations: List[Dict[str, Any]]
    ) -> List[Dict[str, Any]]:
        """
        Prioritizes and deduplicates a list of recommendations.

        Recommendations are sorted first by 'priority_score' (descending).
        Duplicate recommendations (based on the 'action' key) are removed,
        preserving the first occurrence (which will be the highest priority due to sorting).

        Args:
            recommendations: A list of recommendation dictionaries. Each dictionary
                             is expected to have an 'action' key and a 'priority_score' key.

        Returns:
            A list of unique, sorted recommendation dictionaries.
        """
        # Sort by priority_score
        sorted_recs = sorted(
            recommendations,
            key=lambda x: x.get('priority_score', 0.0), # Sort by priority_score
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
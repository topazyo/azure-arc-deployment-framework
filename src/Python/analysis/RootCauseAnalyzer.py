from typing import Dict, List, Any
import pandas as pd
import numpy as np
import logging
from datetime import datetime
from .pattern_analyzer import PatternAnalyzer
import re  # For keyword searching


class SimpleRCAEstimator:
    """
    Estimates the root cause of an incident based on a set of
    predefined rules.

    The class uses a rule-based approach to match incident data
    (description, metrics) against configured rules. Each rule defines
    keywords, metric thresholds, a potential cause, a recommendation, an
    impact score, and a base confidence.
    """
    def __init__(self, config: Dict[str, Any] = None):
        """
        Initializes the SimpleRCAEstimator.

        Args:
            config: A dictionary containing configuration for the
                    estimator. This includes rules for matching incidents
                    and confidence boost values. If None, default rules
                    are used.
        """
        self.config = config if config else {}
        self.logger = logging.getLogger('SimpleRCAEstimator')

        default_rules = {
            "cpu_rule": {
                "keywords_any": ["cpu", "processor"],
                "metrics_thresholds": [
                    {"metric": "cpu_usage_avg", "threshold": 0.9,
                     "operator": ">="}
                ],
                "cause": "CPU Overload",
                "recommendation": (
                    "Scale CPU resources or optimize high-CPU processes."
                ),
                "impact_score": 0.7,
                "base_confidence": 0.7
            },
            "memory_rule": {
                "keywords_any": ["memory", "ram", "exhausted"],
                "metrics_thresholds": [
                    {"metric": "memory_usage_avg", "threshold": 0.9,
                     "operator": ">="}
                ],
                "cause": "Memory Exhaustion",
                "recommendation": (
                    "Increase memory or investigate memory leaks."
                ),
                "impact_score": 0.8,
                "base_confidence": 0.7
            },
            "network_connectivity_rule": {
                "keywords_any": [
                    "network", "connectivity", "unreachable", "timeout"
                ],
                # No specific metric here, relies on keywords primarily
                "cause": "Network Connectivity Issue",
                "recommendation": (
                    "Check network cables, DNS, firewall settings, and "
                    "dependent services."
                ),
                "impact_score": 0.9,
                "base_confidence": 0.65
            },
            "disk_io_rule": {
                "keywords_any": ["disk", "io", "slow storage", "iops"],
                "metrics_thresholds": [
                    {"metric": "disk_queue_length", "threshold": 10,
                     "operator": ">"},
                    {"metric": "disk_latency_ms", "threshold": 50,
                     "operator": ">"}
                ],
                "cause": "Disk I/O Bottleneck",
                "recommendation": (
                    "Optimize disk usage, check for failing hardware, or "
                    "upgrade storage."
                ),
                "impact_score": 0.6,
                "base_confidence": 0.6
            },
            "application_error_rule": {
                # Must contain "application"
                "keywords_all": ["application"],
                "keywords_any": [
                    "error", "exception", "failed", "stack trace",
                    "log error"
                ],
                "cause": "Application Code Error",
                "recommendation": (
                    "Review application logs for specific error messages "
                    "and stack traces. Escalate to development team if "
                    "necessary."
                ),
                "impact_score": 0.75,
                "base_confidence": 0.7
            },
            "latency_rule": {
                "keywords_any": [
                    "latency", "slow response", "performance degradation"
                ],
                # Example: p95 response time > 1000ms
                "metrics_thresholds": [
                    {"metric": "response_time_p95", "threshold": 1000,
                     "operator": ">"}
                ],
                "cause": "Performance Bottleneck",
                "recommendation": (
                    "Investigate application and infrastructure components "
                    "for bottlenecks affecting response times."
                ),
                "impact_score": 0.65,
                "base_confidence": 0.6
            },
            "security_alert_rule": {
                "keywords_all": ["security"],  # Must contain "security"
                "keywords_any": [
                    "alert", "unauthorized access", "breach",
                    "vulnerability"
                ],
                "cause": "Security Incident",
                "recommendation": (
                    "Isolate affected systems immediately. Escalate to "
                    "security team. Review audit logs and security alerts."
                ),
                "impact_score": 0.95,
                "base_confidence": 0.8
            }
        }
        self.rules = self.config.get('rules', default_rules)
        self.multi_condition_confidence_boost = self.config.get(
            'multi_condition_confidence_boost', 0.1)
        # Used by the simplified rule schema in tests
        # (rules that don't specify base_confidence)
        self.default_confidence = self.config.get('default_confidence', 0.6)

    def predict_root_cause(
        self, incident_data: Dict[str, Any]
    ) -> List[Dict[str, Any]]:
        """
        Predicts potential root causes for a given incident.

        The method iterates through the configured rules, checking for
        matches based on keywords in the incident description and metric
        thresholds. Confidence scores are calculated for matched rules.

        Args:
            incident_data: A dictionary containing details of the incident.
                Expected keys include 'description' (str) and 'metrics'
                (Dict[str, float]).

        Returns:
            A list of dictionaries, where each dictionary represents a
            potential root cause. Each cause includes 'type', 'confidence',
            'recommendation', 'impact', and 'trigger_reason'. The list is
            sorted by impact and then confidence in descending order.
            Returns a default "Unknown/Complex Issue" if no rules match.
        """
        desc_snippet = incident_data.get('description', 'No description')[
            :100]
        self.logger.info(
            f"Predicting root cause for incident: {desc_snippet}...")
        description = str(incident_data.get('description', '')).lower()
        metrics = self._extract_incident_metrics(incident_data)
        potential_causes = []

        for rule_name, rule_details in self.rules.items():
            self.logger.debug(f"Evaluating rule: {rule_name}")
            normalized_rule_details = self._normalize_rule_details(
                rule_name,
                rule_details,
            )
            keyword_results, trigger_reasons_list = self._evaluate_keyword_conditions(
                normalized_rule_details,
                description,
            )
            metric_thresholds_met, metric_reasons = self._evaluate_metric_conditions(
                rule_name,
                normalized_rule_details,
                metrics,
            )
            trigger_reasons_list.extend(metric_reasons)

            if self._rule_is_triggered(
                    normalized_rule_details,
                    keyword_results,
                    metric_thresholds_met):
                final_confidence = self._calculate_rule_confidence(
                    normalized_rule_details,
                    keyword_results,
                    metric_thresholds_met,
                )
                potential_causes.append({
                    'type': normalized_rule_details.get("cause", "Unknown"),
                    'confidence': round(final_confidence, 2),
                    'recommendation': normalized_rule_details.get(
                        "recommendation", "Review incident details."),
                    'impact': normalized_rule_details.get("impact_score", 0.5),
                    'trigger_reason': "; ".join(trigger_reasons_list)
                })
                self.logger.debug(
                    f"Rule '{rule_name}' triggered. Details: "
                    f"{potential_causes[-1]}")

        if not potential_causes:
            self.logger.info(
                "No specific rules matched. Returning default cause.")
            potential_causes.append(self._build_default_cause())

        # Sort by impact (descending) then confidence (descending)
        potential_causes.sort(
            key=lambda x: (x['impact'], x['confidence']), reverse=True)
        return potential_causes

    @staticmethod
    def _extract_incident_metrics(incident_data: Dict[str, Any]) -> Dict[str, Any]:
        """Extract metrics from nested or top-level incident payload shapes."""
        metrics = incident_data.get('metrics', {})
        if isinstance(metrics, dict) and metrics:
            return metrics

        exclude_keys = {
            'description', 'metrics', 'metrics_timeseries',
            'timestamp', 'priority', 'incident_id'
        }
        return {
            key: value for key, value in incident_data.items()
            if key not in exclude_keys
        }

    @staticmethod
    def _normalize_rule_details(
            rule_name: str, rule_details: Dict[str, Any]) -> Dict[str, Any]:
        """Normalize simplified rule schema into the canonical RCA shape."""
        normalized = dict(rule_details)
        if 'keywords_any' not in normalized and 'keywords_all' not in normalized:
            normalized['keywords_any'] = [str(rule_name)]

        if 'metrics_thresholds' not in normalized and 'metric_threshold' in normalized:
            normalized['metrics_thresholds'] = [{
                'metric_contains': str(rule_name),
                'threshold': normalized.get('metric_threshold'),
                'operator': '>'
            }]
        return normalized

    def _evaluate_keyword_conditions(
            self,
            rule_details: Dict[str, Any],
            description: str) -> Any:
        """Evaluate keyword conditions and collect trigger reasons."""
        trigger_reasons_list = []
        keyword_match_all_met = self._match_all_keywords(
            rule_details.get('keywords_all', []),
            description,
            trigger_reasons_list,
        )
        keyword_match_any_met = self._match_any_keywords(
            rule_details.get('keywords_any', []),
            description,
            trigger_reasons_list,
        )
        return {
            'all_met': keyword_match_all_met,
            'any_met': keyword_match_any_met,
        }, trigger_reasons_list

    @staticmethod
    def _match_keyword(keyword: str, description: str) -> bool:
        """Return whether a keyword is present as a whole-word match."""
        pattern = r'\b' + re.escape(keyword.lower()) + r'\b'
        return bool(re.search(pattern, description))

    def _match_all_keywords(
            self,
            keywords: List[str],
            description: str,
            trigger_reasons_list: List[str]) -> bool:
        """Evaluate all-keyword matching semantics for a rule."""
        if not keywords:
            return True
        if all(self._match_keyword(keyword, description) for keyword in keywords):
            trigger_reasons_list.append(f"Matched all keywords: {keywords}")
            return True
        return False

    def _match_any_keywords(
            self,
            keywords: List[str],
            description: str,
            trigger_reasons_list: List[str]) -> bool:
        """Evaluate any-keyword matching semantics for a rule."""
        if not keywords:
            return True
        matched_keywords = [
            keyword for keyword in keywords
            if self._match_keyword(keyword, description)
        ]
        if matched_keywords:
            trigger_reasons_list.append(
                f"Matched one or more keywords: {matched_keywords}"
            )
            return True
        return False

    def _evaluate_metric_conditions(
            self,
            rule_name: str,
            rule_details: Dict[str, Any],
            metrics: Dict[str, Any]) -> Any:
        """Evaluate metric thresholds for a rule and collect trigger reasons."""
        metric_conditions = rule_details.get('metrics_thresholds', [])
        if not metric_conditions:
            return True, []

        trigger_reasons = []
        for condition in metric_conditions:
            condition_met, trigger_reason = self._evaluate_metric_condition(
                rule_name,
                condition,
                metrics,
            )
            if not condition_met:
                return False, []
            trigger_reasons.append(trigger_reason)
        return True, trigger_reasons

    def _evaluate_metric_condition(
            self,
            rule_name: str,
            condition: Dict[str, Any],
            metrics: Dict[str, Any]) -> Any:
        """Evaluate one metric condition for an RCA rule."""
        metric_name = condition.get('metric')
        metric_contains = condition.get('metric_contains')
        threshold = condition.get('threshold')
        operator = condition.get('operator', '>')

        metric_value = self._resolve_metric_value(
            metrics,
            metric_name,
            metric_contains,
        )
        if metric_value is None:
            return False, None
        if not isinstance(metric_value, (int, float)):
            self.logger.warning(
                f"Metric {metric_name} for rule {rule_name} is not numeric: {metric_value}")
            return False, None
        if not self._metric_condition_matches(metric_value, threshold, operator, rule_name):
            return False, None

        display_name = metric_name or metric_contains or 'unknown_metric'
        return True, (
            f"Metric '{display_name}' ({metric_value}) met condition "
            f"({operator} {threshold})"
        )

    def _resolve_metric_value(
            self,
            metrics: Dict[str, Any],
            metric_name: str,
            metric_contains: str) -> Any:
        """Resolve a metric by exact name or substring match."""
        if metric_name:
            return metrics.get(metric_name)
        if metric_contains:
            return self._metric_value_from_contains(metrics, str(metric_contains))
        return None

    @staticmethod
    def _metric_value_from_contains(
            metrics: Dict[str, Any], substr: str) -> Any:
        """Return the max numeric metric value whose name contains a substring."""
        if not substr:
            return None
        substr_l = substr.lower()
        candidates: List[float] = []
        for key, value in (metrics or {}).items():
            if (substr_l in str(key).lower() and
                    isinstance(value, (int, float)) and
                    not (np.isnan(value) or np.isinf(value))):
                candidates.append(float(value))
        return max(candidates) if candidates else None

    def _metric_condition_matches(
            self,
            metric_value: float,
            threshold: Any,
            operator: str,
            rule_name: str) -> bool:
        """Check whether a metric value satisfies the configured operator."""
        if operator == '>':
            return metric_value > threshold
        if operator == '>=':
            return metric_value >= threshold
        if operator == '<':
            return metric_value < threshold
        if operator == '<=':
            return metric_value <= threshold
        if operator == '==':
            return metric_value == threshold

        self.logger.warning(
            f"Unsupported operator {operator} in rule {rule_name}")
        return False

    @staticmethod
    def _rule_is_triggered(
            rule_details: Dict[str, Any],
            keyword_results: Dict[str, bool],
            metric_thresholds_met: bool) -> bool:
        """Determine whether a normalized rule is triggered."""
        has_keyword_conditions = bool(
            rule_details.get('keywords_all') or rule_details.get('keywords_any')
        )
        has_metric_conditions = bool(rule_details.get('metrics_thresholds'))

        if has_keyword_conditions and has_metric_conditions:
            return (
                keyword_results['all_met'] and
                keyword_results['any_met'] and
                metric_thresholds_met
            )
        if has_keyword_conditions:
            return keyword_results['all_met'] and keyword_results['any_met']
        if has_metric_conditions:
            return metric_thresholds_met
        return False

    def _calculate_rule_confidence(
            self,
            rule_details: Dict[str, Any],
            keyword_results: Dict[str, bool],
            metric_thresholds_met: bool) -> float:
        """Calculate final confidence for a triggered rule."""
        final_confidence = rule_details.get(
            'base_confidence', self.default_confidence
        )
        keyword_cond = (
            (keyword_results['all_met'] and rule_details.get('keywords_all')) or
            (keyword_results['any_met'] and rule_details.get('keywords_any'))
        )
        metric_cond = metric_thresholds_met and rule_details.get('metrics_thresholds')
        if keyword_cond and metric_cond:
            final_confidence = min(
                0.95,
                final_confidence + self.multi_condition_confidence_boost,
            )
        return final_confidence

    @staticmethod
    def _build_default_cause() -> Dict[str, Any]:
        """Build the fallback RCA cause when no rules match."""
        return {
            'type': "Unknown/Complex Issue",
            'confidence': 0.3,
            'recommendation': (
                "Requires further detailed investigation. Review logs "
                "and full telemetry."
            ),
            'impact': 0.5,
            'trigger_reason': "No specific rule matched the incident data."
        }


class SimpleRCAExplainer:
    """
    Generates human-readable explanations for predicted root causes.

    This class takes the output from an RCA estimator (like
    SimpleRCAEstimator) and constructs textual explanations for the
    identified potential causes.
    """
    def __init__(self, config: Dict[str, Any] = None):
        """
        Initializes the SimpleRCAExplainer.

        Args:
            config: A dictionary for potential future configuration.
                    Currently unused.
        """
        self.config = config if config else {}
        self.logger = logging.getLogger('SimpleRCAExplainer')

    def _generate_factor_explanation(
        self, cause: Dict[str, Any], incident_data: Dict[str, Any]
    ) -> str:
        # Helper to generate explanation for a single cause
        return (
            f"The factor '{cause['type']}' (Impact: {cause['impact']}, "
            f"Confidence: {cause['confidence']}) is suspected. "
            f"Trigger: {cause.get('trigger_reason', 'N/A')}. "
            f"Recommended action: {cause['recommendation']}"
        )

    def explain_prediction(
        self, causes: List[Dict[str, Any]],
        incident_data: Dict[str, Any]
    ) -> Dict[str, Any]:
        """
        Generates explanations for the predicted root causes.

        It identifies a primary cause (the first in the sorted list) and
        provides a detailed explanation for it. It also lists
        explanations for all other potential factors.

        Args:
            causes: A list of potential root cause dictionaries, typically
                    from an RCA estimator. Each dictionary should contain
                    'type', 'impact', 'confidence', 'trigger_reason', and
                    'recommendation'.
            incident_data: The original incident data dictionary, used for
                           context if needed.

        Returns:
            A dictionary containing:
                - 'primary_explanation' (str): A detailed explanation for
                  the most likely cause.
                - 'factor_explanations' (List[str]): A list of strings,
                  each explaining a potential factor.
        """
        self.logger.info(
            f"Generating explanation for {len(causes)} potential causes.")
        primary_explanation_str = "No primary cause identified."
        factor_explanations_list = []

        if not causes:
            return {
                'primary_explanation': primary_explanation_str,
                'factor_explanations': factor_explanations_list
            }

        # Assuming causes are sorted by importance
        # (e.g., impact/confidence) by the estimator
        primary_cause = causes[0]
        default_trigger = 'general assessment of incident data'
        default_rec = 'Review incident details.'
        primary_explanation_str = (
            f"The primary suspected cause is '{primary_cause['type']}' "
            f"(Impact: {primary_cause['impact']}, "
            f"Confidence: {primary_cause['confidence']}). "
            f"This is based on: "
            f"{primary_cause.get('trigger_reason', default_trigger)}. "
            f"Recommended action: "
            f"{primary_cause.get('recommendation', default_rec)}."
        )

        for cause in causes:
            factor_explanations_list.append(
                self._generate_factor_explanation(cause, incident_data))

        return {
            'primary_explanation': primary_explanation_str,
            'factor_explanations': factor_explanations_list
        }


class RootCauseAnalyzer:
    """
    Orchestrates the root cause analysis process for incidents.

    This class integrates pattern analysis, root cause estimation, and
    explanation generation to provide a comprehensive analysis of an
    incident. It uses sub-components for each step: PatternAnalyzer,
    SimpleRCAEstimator, and SimpleRCAExplainer.
    """
    def __init__(self, config: Dict[str, Any]):
        """
        Initializes the RootCauseAnalyzer.

        Args:
            config: A dictionary containing configurations for the
                    analyzer and its sub-components
                    (pattern_analyzer_config, rca_estimator_config,
                    rca_explainer_config).
        """
        self.config = config
        # Pass relevant sub-config
        pattern_config = self.config.get('pattern_analyzer_config', {})
        self.pattern_analyzer = PatternAnalyzer(pattern_config)
        estimator_config = self.config.get('rca_estimator_config', {})
        self.ml_model = SimpleRCAEstimator(estimator_config)
        explainer_config = self.config.get('rca_explainer_config', {})
        self.explainer = SimpleRCAExplainer(explainer_config)
        self.setup_logging()

    def setup_logging(self):
        """
        Sets up logging for the RootCauseAnalyzer.

        Configures basic logging to write to a file named with the
        current date. Initializes a logger instance for the class.
        """
        log_filename = (
            f'root_cause_analyzer_{datetime.now().strftime("%Y%m%d")}.log'
        )
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            filename=log_filename
        )
        self.logger = logging.getLogger('RootCauseAnalyzer')

    def analyze_incident(
        self, incident_data: Dict[str, Any]
    ) -> Dict[str, Any]:
        """
        Enhanced incident analysis using pattern recognition and simple
        RCA.
        """
        try:
            desc = incident_data.get('description', 'N/A')
            self.logger.info(f"Starting incident analysis for: {desc}")
            # Convert relevant parts of incident data for pattern analysis
            # if applicable. PatternAnalyzer expects a DataFrame. If
            # incident_data contains time-series metrics, use those. For
            # now, if 'metrics_timeseries' is a key in incident_data,
            # assume it's a list of dicts for a DF. Otherwise, pattern
            # analysis might be limited.
            metrics_timeseries = incident_data.get('metrics_timeseries')
            if metrics_timeseries and isinstance(metrics_timeseries, list):
                df_for_patterns = pd.DataFrame(metrics_timeseries)
            # If single point metrics, wrap in list for DF
            elif incident_data.get('metrics'):
                df_for_patterns = pd.DataFrame(
                    [incident_data.get('metrics')])
            # Fallback to an empty DataFrame or a DataFrame from the main
            # incident_data structure. This might not be ideal for all
            # pattern types but prevents errors. Consider which fields
            # from incident_data are relevant for patterns.
            else:
                df_for_patterns = pd.DataFrame([incident_data])

            # Ensure 'timestamp' column exists for pattern analyzer if
            # possible
            has_ts_col = 'timestamp' in df_for_patterns.columns
            has_ts_data = 'timestamp' in incident_data
            if not has_ts_col and has_ts_data:
                # If single incident_data has a timestamp, apply it to all
                # rows in df_for_patterns. This is a simplification;
                # ideally, metrics_timeseries would have timestamps
                try:
                    df_for_patterns['timestamp'] = pd.to_datetime(
                        incident_data['timestamp'])
                except Exception as e_ts:
                    self.logger.warning(
                        "Could not convert incident_data timestamp for "
                        f"pattern analysis: {e_ts}")

            patterns = self.pattern_analyzer.analyze_patterns(
                df_for_patterns)

            # Predict root causes using the simple rule-based estimator.
            # incident_data itself is passed, as it contains description
            # and metrics.
            predicted_causes = self.ml_model.predict_root_cause(
                incident_data)  # List of Cause dicts

            # Generate explanation using the simple explainer
            # Explanation dict
            explanation_details = self.explainer.explain_prediction(
                predicted_causes, incident_data)
            analysis_result = {
                'incident_description': incident_data.get(
                    'description', 'N/A'),
                'predicted_root_causes': [],  # Will be populated below
                # Contains 'primary_explanation' and 'factor_explanations'
                'explanation': explanation_details,
                # Output from PatternAnalyzer
                'identified_patterns': patterns,
                # Will be populated by generate_recommendations
                'actionable_recommendations': []
            }

            if predicted_causes:
                analysis_result['predicted_root_causes'] = predicted_causes
                # The first cause in the sorted list is considered the
                # primary one
                primary_cause_details = predicted_causes[0]
                analysis_result['primary_suspected_cause'] = {
                    'type': primary_cause_details['type'],
                    'confidence': primary_cause_details['confidence'],
                    'impact': primary_cause_details['impact'],
                    'recommendation': (
                        primary_cause_details['recommendation']),
                    'trigger_reason': (
                        primary_cause_details.get('trigger_reason'))
                }

            # Generate recommendations based on both predicted causes
            # and identified patterns
            recommendations = self.generate_recommendations(
                predicted_causes, patterns)
            analysis_result['actionable_recommendations'] = recommendations

            # Legacy/placeholder aliases for older callers/tests
            if 'primary_suspected_cause' in analysis_result:
                psc = analysis_result['primary_suspected_cause']
                analysis_result['primary_cause'] = psc
            ar = analysis_result['actionable_recommendations']
            analysis_result['recommendations'] = ar

            self.logger.info("Incident analysis complete.")
            return analysis_result

        except Exception as e:
            self.logger.error(
                f"Incident analysis failed: {str(e)}", exc_info=True)
            # Return a structured error as part of the result if
            # possible, or re-raise. For now, re-raising to indicate
            # failure to the caller clearly.
            raise

    def generate_recommendations(
        self,
        causes: List[Dict[str, Any]],  # Updated to expect list of dicts
        patterns_analysis: Dict[str, Any]
    ) -> List[Dict[str, Any]]:
        """
        Generate enhanced recommendations based on causes and patterns.
        """
        self.logger.info("Generating recommendations...")
        recommendations = []

        # Add cause-based recommendations
        for cause in causes:
            # Ensure cause is a dictionary with expected keys
            if isinstance(cause, dict):
                default_rec = 'Review cause details.'
                # Example priority
                priority_score = (
                    cause.get('impact', 0.5) *
                    cause.get('confidence', 0.5)
                )
                details = (
                    f"Related to cause: {cause.get('type', 'Unknown')}. "
                    f"Trigger: {cause.get('trigger_reason', 'N/A')}"
                )
                recommendations.append({
                    'action': cause.get('recommendation', default_rec),
                    'priority_score': priority_score,
                    'source': 'RootCauseEstimator',
                    'details': details
                })

        # Add pattern-based recommendations
        # Iterate through different pattern types
        # (temporal, failure, performance)
        for pattern_type_key, pattern_data in patterns_analysis.items():
            has_recs = (
                isinstance(pattern_data, dict) and
                "recommendations" in pattern_data
            )
            if has_recs:
                for rec in pattern_data["recommendations"]:
                    # Ensure rec is a dict with 'action'
                    if isinstance(rec, dict) and 'action' in rec:
                        # Use priority from pattern if available
                        priority_score = rec.get('priority', 0.3)
                        recommendations.append({
                            'action': rec['action'],
                            'priority_score': priority_score,
                            'source': (
                                f'PatternAnalyzer ({pattern_type_key})'),
                            'details': rec.get('details', '')
                        })
            # Handle cases where recommendations might be nested further
            # (e.g. patterns_analysis['temporal']['daily']
            # ['recommendations'])
            # Check sub-dictionaries like 'daily', 'weekly' etc.
            elif isinstance(pattern_data, dict):
                for sub_pattern_key, sub_pattern_data in (
                        pattern_data.items()):
                    has_sub_recs = (
                        isinstance(sub_pattern_data, dict) and
                        "recommendations" in sub_pattern_data
                    )
                    if has_sub_recs:
                        for rec in sub_pattern_data["recommendations"]:
                            if isinstance(rec, dict) and 'action' in rec:
                                source = (
                                    f'PatternAnalyzer '
                                    f'({pattern_type_key}.'
                                    f'{sub_pattern_key})'
                                )
                                recommendations.append({
                                    'action': rec['action'],
                                    'priority_score': rec.get(
                                        'priority', 0.3),
                                    'source': source,
                                    'details': rec.get('details', '')
                                })

        # Prioritize and deduplicate recommendations
        return self._prioritize_recommendations(recommendations)

    # _get_cause_recommendations can be removed if logic is integrated
    # above or kept if more complex per-cause rec generation is needed.
    # For now, the logic is simple enough to be integrated.

    # The _get_pattern_recommendations method has been removed as its
    # functionality is integrated into generate_recommendations.

    def _prioritize_recommendations(
        self,
        recommendations: List[Dict[str, Any]]
    ) -> List[Dict[str, Any]]:
        """
        Prioritizes and deduplicates a list of recommendations.

        Recommendations are sorted first by 'priority_score'
        (descending). Duplicate recommendations (based on the 'action'
        key) are removed, preserving the first occurrence (which will be
        the highest priority due to sorting).

        Args:
            recommendations: A list of recommendation dictionaries. Each
                             dictionary is expected to have an 'action'
                             key and a 'priority_score' key.

        Returns:
            A list of unique, sorted recommendation dictionaries.
        """
        # Sort by priority_score
        sorted_recs = sorted(
            recommendations,
            key=lambda x: x.get('priority_score', 0.0),  # Sort by score
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

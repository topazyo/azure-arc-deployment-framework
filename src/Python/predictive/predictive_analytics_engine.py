from typing import Dict, List, Any
import numpy as np
import pandas as pd
import logging
from datetime import datetime
from .model_trainer import ArcModelTrainer
from .predictor import ArcPredictor
from .ArcRemediationLearner import ArcRemediationLearner
from ..analysis.pattern_analyzer import PatternAnalyzer

class PredictiveAnalyticsEngine:
    """Orchestrates predictive analytics, including risk analysis."""
    def __init__(self, config: Dict[str, Any], model_dir: str):
        """Initializes PredictiveAnalyticsEngine with config and components."""
        self.config = config
        self.model_dir = model_dir
        self.trainer = None
        self.predictor = None
        self.pattern_analyzer = None
        self.remediation_learner = None
        self.setup_logging()
        self.initialize_components()

    def setup_logging(self):
        """Sets up logging for the engine."""
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            filename=f'predictive_analytics_{datetime.now().strftime("%Y%m%d")}.log'
        )
        self.logger = logging.getLogger('PredictiveAnalytics')

    def initialize_components(self):
        """Initialize all AI components"""
        try:
            # Config is either:
            # - aiComponents (preferred) with sub-keys like model_config/pattern_analyzer_config, OR
            # - a "comprehensive" config with those sub-keys at top-level, OR
            # - a model_config-like object (contains features/models directly).
            model_config = self.config.get('model_config')
            if model_config is None and 'features' in self.config and 'models' in self.config:
                model_config = self.config
            if model_config is None:
                model_config = {}

            pa_config = self.config.get('pattern_analyzer_config', {})
            remediation_learner_config = self.config.get('remediation_learner_config', {})

            self.trainer = ArcModelTrainer(model_config)
            self.predictor = ArcPredictor(model_dir=self.model_dir, config=self.config)
            self.pattern_analyzer = PatternAnalyzer(config=pa_config)
            self.remediation_learner = ArcRemediationLearner(config=remediation_learner_config)
            try:
                self.remediation_learner.initialize_ai_components(self.config, self.model_dir)
            except Exception as remediation_exc:
                self.logger.warning(
                    "Remediation learner initialization failed: %s. Continuing without learner.",
                    remediation_exc,
                )

            self.logger.info("All components initialized successfully")
        except Exception as e:
            self.logger.error(f"Component initialization failed: {str(e)}")
            raise

    def analyze_deployment_risk(self, server_data: Dict[str, Any]) -> Dict[str, Any]:
        """Analyzes deployment risk based on server data and models."""
        try:
            # Get predictions from multiple models
            health_prediction = self.predictor.predict_health(server_data)
            failure_prediction = self.predictor.predict_failures(server_data)
            anomaly_detection = self.predictor.detect_anomalies(server_data)

            # Analyze patterns
            patterns = self.pattern_analyzer.analyze_patterns(pd.DataFrame([server_data]))

            # Combine all insights
            risk_analysis = {
                'overall_risk': self._calculate_overall_risk(
                    health_prediction,
                    failure_prediction,
                    anomaly_detection
                ),
                'health_status': health_prediction,
                'failure_risk': failure_prediction,
                'anomalies': anomaly_detection,
                'patterns': patterns,
                'recommendations': self._generate_recommendations(
                    health_prediction,
                    failure_prediction,
                    anomaly_detection,
                    patterns
                )
            }

            return risk_analysis

        except Exception as e:
            self.logger.error(f"Risk analysis failed: {str(e)}")
            raise

    def record_remediation_outcome(
        self,
        remediation_payload: Dict[str, Any],
        consume_retrain_queue: bool = False,
    ) -> Dict[str, Any]:
        """Pass remediation outcomes to the learner and surface retrain signals."""
        if not self.remediation_learner:
            return {"status": "disabled", "reason": "remediation_learner not initialized"}

        self.remediation_learner.learn_from_remediation(remediation_payload)
        pending = (
            self.remediation_learner.consume_pending_retrain_requests()
            if consume_retrain_queue
            else self.remediation_learner.peek_pending_retrain_requests()
        )

        return {
            "status": "processed",
            "trainer_response": self.remediation_learner.trainer_last_response,
            "pending_retrain_requests": pending,
        }

    def export_retrain_requests(self, output_path: str, consume: bool = False) -> Dict[str, Any]:
        """Persist pending retrain requests to disk for orchestration workflows."""
        if not self.remediation_learner:
            return {"status": "disabled", "reason": "remediation_learner not initialized"}
        return self.remediation_learner.export_pending_retrain_requests(output_path, consume=consume)

    def _calculate_overall_risk(
        self,
        health: Dict[str, Any],
        failure: Dict[str, Any],
        anomaly: Dict[str, Any]
    ) -> Dict[str, Any]:
        """Calculate overall risk score combining multiple factors"""
        try:
            # Weight factors
            health_weight = 0.4
            failure_weight = 0.4
            anomaly_weight = 0.2

            # Calculate weighted risk score
            risk_score = (
                (1 - health['prediction']['healthy_probability']) * health_weight +
                failure['prediction']['failure_probability'] * failure_weight +
                (1 if anomaly['is_anomaly'] else 0) * anomaly_weight
            )

            return {
                'score': risk_score,
                'level': self._get_risk_level(risk_score),
                'confidence': self._calculate_confidence(health, failure, anomaly),
                'contributing_factors': self._identify_risk_factors(health, failure, anomaly)
            }

        except Exception as e:
            self.logger.error(f"Overall risk calculation failed: {str(e)}")
            raise

    def _get_risk_level(self, risk_score: float) -> str:
        """Determine risk level based on score"""
        if risk_score >= 0.8:
            return 'Critical'
        elif risk_score >= 0.6:
            return 'High'
        elif risk_score >= 0.4:
            return 'Medium'
        elif risk_score >= 0.2:
            return 'Low'
        return 'Minimal'

    def _calculate_confidence(
        self,
        health: Dict[str, Any],
        failure: Dict[str, Any],
        anomaly: Dict[str, Any]
    ) -> float:
        """Calculate confidence level in the risk assessment"""
        confidence_factors = [
            health['prediction']['healthy_probability'],
            failure['prediction']['failure_probability'],
            abs(anomaly['anomaly_score'])
        ]
        return np.mean(confidence_factors)

    def _identify_risk_factors(
        self,
        health: Dict[str, Any],
        failure: Dict[str, Any],
        anomaly: Dict[str, Any]
    ) -> List[Dict[str, Any]]:
        """Identify key factors contributing to risk"""
        risk_factors = []

        # Add health-related factors
        if health['feature_impacts']:
            for feature, impact in health['feature_impacts'].items():
                if impact > 0.3:  # Significant impact threshold
                    risk_factors.append({
                        'factor': feature,
                        'impact': impact,
                        'category': 'Health'
                    })

        # Add failure-related factors
        if failure['feature_impacts']:
            for feature, impact in failure['feature_impacts'].items():
                if impact > 0.3:
                    risk_factors.append({
                        'factor': feature,
                        'impact': impact,
                        'category': 'Failure'
                    })

        # Add anomaly-related factors
        if anomaly['is_anomaly']:
            risk_factors.append({
                'factor': 'Anomalous Behavior',
                'impact': anomaly['anomaly_score'],
                'category': 'Anomaly'
            })

        return sorted(risk_factors, key=lambda x: x['impact'], reverse=True)

    def _generate_recommendations(
        self,
        health: Dict[str, Any],
        failure: Dict[str, Any],
        anomaly: Dict[str, Any],
        patterns: Dict[str, Any]
    ) -> List[Dict[str, Any]]:
        """Generate comprehensive recommendations based on all analyses"""
        recommendations = []

        healthy_prob = health.get('prediction', {}).get('healthy_probability')
        unhealthy_prob = health.get('prediction', {}).get('unhealthy_probability')
        if unhealthy_prob is None and healthy_prob is not None:
            try:
                unhealthy_prob = 1 - float(healthy_prob)
            except Exception:
                unhealthy_prob = None

        # Add health-based recommendations
        if unhealthy_prob is not None and unhealthy_prob > 0.3:
            recommendations.extend(self._get_health_recommendations(health))

        # Add failure prevention recommendations
        if failure['prediction']['failure_probability'] > 0.3:
            recommendations.extend(self._get_failure_recommendations(failure))

        # Add anomaly-based recommendations
        if anomaly['is_anomaly']:
            recommendations.extend(self._get_anomaly_recommendations(anomaly))

        # Add pattern-based recommendations
        if patterns:
            recommendations.extend(self._get_pattern_recommendations(patterns))

        return sorted(recommendations, key=lambda x: x['priority'], reverse=True)

    def _get_health_recommendations(self, health: Dict[str, Any]) -> List[Dict[str, Any]]:
        """Generate health-specific recommendations"""
        recommendations = []
        for feature, impact in health['feature_impacts'].items():
            if impact > 0.3:
                recommendations.append({
                    'category': 'Health',
                    'action': f"Improve {feature}",
                    'priority': impact,
                    'details': f"Address issues with {feature} to improve health score"
                })
        return recommendations

    def _get_failure_recommendations(self, failure: Dict[str, Any]) -> List[Dict[str, Any]]:
        """Generate failure prevention recommendations"""
        recommendations = []
        for feature, impact in failure['feature_impacts'].items():
            if impact > 0.3:
                recommendations.append({
                    'category': 'Failure Prevention',
                    'action': f"Address {feature}",
                    'priority': impact,
                    'details': f"Mitigate potential failure risk related to {feature}"
                })
        return recommendations

    def _get_anomaly_recommendations(self, anomaly: Dict[str, Any]) -> List[Dict[str, Any]]:
        """Generate anomaly-based recommendations"""
        return [{
            'category': 'Anomaly',
            'action': 'Investigate Anomalous Behavior',
            'priority': abs(anomaly['anomaly_score']),
            'details': 'Investigate and address detected anomalous behavior'
        }]

    def _get_pattern_recommendations(self, patterns: Dict[str, Any]) -> List[Dict[str, Any]]:
        """Generate pattern-based recommendations"""
        def iter_recs(obj: Any) -> List[Dict[str, Any]]:
            collected: List[Dict[str, Any]] = []
            if isinstance(obj, dict):
                recs = obj.get('recommendations')
                if isinstance(recs, list):
                    for rec in recs:
                        if isinstance(rec, dict):
                            collected.append(rec)
                for v in obj.values():
                    collected.extend(iter_recs(v))
            elif isinstance(obj, list):
                for item in obj:
                    collected.extend(iter_recs(item))
            return collected

        recommendations: List[Dict[str, Any]] = []
        for rec in iter_recs(patterns):
            recommendations.append(
                {
                    'category': 'Pattern',
                    'action': rec.get('action', ''),
                    'priority': rec.get('priority', 0.5),
                    'details': rec.get('details', ''),
                }
            )

        return recommendations
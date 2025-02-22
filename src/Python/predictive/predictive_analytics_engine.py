from typing import Dict, List, Any
import numpy as np
import pandas as pd
import logging
from datetime import datetime
from .model_trainer import ArcModelTrainer
from .predictor import ArcPredictor
from ..analysis.pattern_analyzer import PatternAnalyzer

class PredictiveAnalyticsEngine:
    def __init__(self, config: Dict[str, Any], model_dir: str):
        self.config = config
        self.model_dir = model_dir
        self.trainer = None
        self.predictor = None
        self.pattern_analyzer = None
        self.setup_logging()
        self.initialize_components()

    def setup_logging(self):
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            filename=f'predictive_analytics_{datetime.now().strftime("%Y%m%d")}.log'
        )
        self.logger = logging.getLogger('PredictiveAnalytics')

    def initialize_components(self):
        """Initialize all AI components"""
        try:
            self.trainer = ArcModelTrainer(self.config)
            self.predictor = ArcPredictor(self.model_dir)
            self.pattern_analyzer = PatternAnalyzer(self.config)
            self.logger.info("All components initialized successfully")
        except Exception as e:
            self.logger.error(f"Component initialization failed: {str(e)}")
            raise

    def analyze_deployment_risk(self, server_data: Dict[str, Any]) -> Dict[str, Any]:
        """Analyze deployment risks using enhanced prediction capabilities"""
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

        # Add health-based recommendations
        if health['prediction']['unhealthy_probability'] > 0.3:
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
        recommendations = []
        for pattern_type, pattern_data in patterns.items():
            if isinstance(pattern_data, dict) and pattern_data.get('recommendations'):
                recommendations.extend([
                    {
                        'category': 'Pattern',
                        'action': rec['action'],
                        'priority': rec.get('priority', 0.5),
                        'details': rec.get('details', '')
                    }
                    for rec in pattern_data['recommendations']
                ])
        return recommendations
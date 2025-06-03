from typing import Dict, List, Any
import numpy as np
import pandas as pd
from sklearn.ensemble import RandomForestClassifier
import joblib
import logging
from datetime import datetime
from .model_trainer import ArcModelTrainer
from .predictor import ArcPredictor

class ArcRemediationLearner:
    def __init__(self):
        self.success_patterns = {}
        self.model = self._initialize_model()
        self.predictor = None
        self.trainer = None
        self.setup_logging()

    def setup_logging(self):
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            filename=f'remediation_learner_{datetime.now().strftime("%Y%m%d")}.log'
        )
        self.logger = logging.getLogger('ArcRemediationLearner')

    def _initialize_model(self) -> RandomForestClassifier:
        return RandomForestClassifier(
            n_estimators=100,
            max_depth=10,
            random_state=42
        )

    def initialize_ai_components(self, config: Dict[str, Any], model_dir: str):
        """Initialize AI components with new implementations"""
        try:
            self.trainer = ArcModelTrainer(config)
            self.predictor = ArcPredictor(model_dir)
            self.logger.info("AI components initialized successfully")
        except Exception as e:
            self.logger.error(f"Failed to initialize AI components: {str(e)}")
            raise

    def learn_from_remediation(self, remediation_data: Dict[str, Any]):
        """Process successful remediation actions to improve future recommendations"""
        try:
            features = self._extract_features(remediation_data)
            success = remediation_data['outcome'] == 'success'
            
            if success:
                self.success_patterns[remediation_data['error_type']] = {
                    'action': remediation_data['action'],
                    'context': remediation_data['context'],
                    'success_rate': self._calculate_success_rate(remediation_data)
                }

            # Update model with new data
            self.model.fit(features, [success])

            # Update AI components with new learning
            if self.trainer and success:
                self.trainer.update_models_with_remediation(remediation_data)

            self.logger.info(f"Learned from remediation: {remediation_data['action']} - Success: {success}")
            
        except Exception as e:
            self.logger.error(f"Failed to learn from remediation: {str(e)}")
            raise

    def get_recommendation(self, error_context: Dict[str, Any]) -> Dict[str, Any]:
        """Generate remediation recommendations based on learned patterns"""
        try:
            features = self._extract_features(error_context)
            
            # Get predictions from both old and new models
            legacy_prediction = self.model.predict_proba(features)
            
            if self.predictor:
                ai_prediction = self.predictor.predict_failures(error_context)
                combined_recommendation = self._combine_predictions(
                    legacy_prediction, 
                    ai_prediction
                )
            else:
                combined_recommendation = self._get_legacy_recommendation(
                    legacy_prediction, 
                    error_context
                )

            return combined_recommendation

        except Exception as e:
            self.logger.error(f"Failed to get recommendation: {str(e)}")
            raise

    def _extract_features(self, context: Dict[str, Any]) -> np.ndarray:
        """Extract features from context for model input"""
        try:
            features = np.array([[
                context.get('cpu_usage', 0),
                context.get('memory_usage', 0),
                context.get('error_count', 0),
                context.get('service_status', 0),
                context.get('connection_status', 0)
            ]])
            return features
        except Exception as e:
            self.logger.error(f"Feature extraction failed: {str(e)}")
            raise

    def _calculate_success_rate(self, remediation_data: Dict[str, Any]) -> float:
        """Calculate success rate for a remediation action"""
        error_type = remediation_data['error_type']
        if error_type in self.success_patterns:
            previous_rate = self.success_patterns[error_type].get('success_rate', 0)
            return (previous_rate + 1) / 2  # Simple moving average
        return 1.0

    def _combine_predictions(self, legacy_prediction: np.ndarray, ai_prediction: Dict[str, Any]) -> Dict[str, Any]:
        """Combine predictions from legacy and new AI models"""
        return {
            'recommended_action': self._get_best_action(legacy_prediction, ai_prediction),
            'confidence_score': self._calculate_combined_confidence(
                legacy_prediction[0][1],
                ai_prediction['prediction']['failure_probability']
            ),
            'alternative_actions': self._get_alternative_actions(ai_prediction),
            'ai_insights': ai_prediction['feature_impacts'],
            'risk_level': ai_prediction['risk_level']
        }

    def _get_legacy_recommendation(self, prediction: np.ndarray, context: Dict[str, Any]) -> Dict[str, Any]:
        """Generate recommendation using legacy model only"""
        return {
            'recommended_action': self._get_best_action(prediction, None),
            'confidence_score': float(prediction[0][1]),
            'alternative_actions': self._get_alternative_actions(None),
            'context': context
        }

    def _calculate_combined_confidence(self, legacy_score: float, ai_score: float) -> float:
        """Calculate combined confidence score"""
        # Weighted average favoring the AI prediction
        return (legacy_score * 0.3) + (ai_score * 0.7)

    def _get_best_action(self, legacy_prediction: np.ndarray, ai_prediction: Dict[str, Any] = None) -> str:
        """Determine the best remediation action"""
        if ai_prediction and ai_prediction['risk_level'] in ['Critical', 'High']:
            return ai_prediction.get('recommended_action', 'default_action')
        return self._get_legacy_action(legacy_prediction)

    def _get_legacy_action(self, prediction: np.ndarray) -> str:
        """Get action based on legacy model prediction"""
        confidence = prediction[0][1]
        if confidence > 0.8:
            return "high_confidence_action"
        elif confidence > 0.5:
            return "medium_confidence_action"
        return "low_confidence_action"

    def _get_alternative_actions(self, ai_prediction: Dict[str, Any] = None) -> List[str]:
        """Get alternative remediation actions"""
        if ai_prediction:
            return ai_prediction.get('alternative_actions', [])
        return ["default_alternative_1", "default_alternative_2"]
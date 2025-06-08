from typing import Dict, List, Any
import numpy as np
import pandas as pd
# Removed RandomForestClassifier and joblib as direct model is removed
import numpy as np
import pandas as pd # Keep for potential context processing
import logging
from datetime import datetime
from typing import Dict, List, Any, Optional # Added Optional

# Assuming these are correctly imported from their respective files
from .model_trainer import ArcModelTrainer
from .predictor import ArcPredictor

class ArcRemediationLearner:
    """[TODO: Add class documentation]"""
    def __init__(self, config: Dict[str, Any] = None): # Added config to __init__
        """[TODO: Add method documentation]"""
        self.config = config if config else {}
        self.success_patterns: Dict[tuple, Dict[str, Any]] = {} # Key: (error_type, action)
        self.predictor: Optional[ArcPredictor] = None
        self.trainer: Optional[ArcModelTrainer] = None

        # Attributes for retraining trigger
        self.new_data_counter: Dict[str, int] = {}
        self.retraining_threshold = self.config.get('retraining_data_threshold', 50) # Default to 50

        self.setup_logging() # Call after all attributes potentially used in setup_logging are set

        # Feature list for context summarization, configurable
        self.context_features_to_log = self.config.get('remediation_learner_context_features',
                                                      ['cpu_usage', 'memory_usage', 'error_count'])

    def setup_logging(self):
        logging.basicConfig(
            level=self.config.get('log_level', logging.INFO), # Configurable log level
            format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
            filename=f'remediation_learner_{datetime.now().strftime("%Y%m%d")}.log'
        )
        self.logger = logging.getLogger('ArcRemediationLearner')
        self.logger.info("ArcRemediationLearner initialized.")

    # _initialize_model method removed as self.model is removed

    def initialize_ai_components(self, global_ai_config: Dict[str, Any], model_dir: str):
        """Initialize AI components (Trainer and Predictor)."""
        try:
            # Pass relevant parts of the global_ai_config to trainer and predictor
            # Assuming model_trainer and predictor can pick their configs from global_ai_config
            self.trainer = ArcModelTrainer(global_ai_config.get('model_config', {}))
            self.predictor = ArcPredictor(model_dir=model_dir) # Predictor needs model_dir
            self.logger.info("AI components (Trainer, Predictor) initialized successfully for RemediationLearner.")
        except Exception as e:
            self.logger.error(f"Failed to initialize AI components: {str(e)}", exc_info=True)
            # Decide if to raise or handle (e.g., operate without AI components if possible)
            raise

    def learn_from_remediation(self, remediation_data: Dict[str, Any]):
        """Process remediation actions to update success patterns and inform model trainer."""
        try:
            error_type = remediation_data.get('error_type', 'UnknownError')
            action_taken = remediation_data.get('action', 'UnknownAction')
            outcome_success = remediation_data.get('outcome') == 'success'
            context = remediation_data.get('context', {})

            if not error_type or not action_taken:
                self.logger.warning("Remediation data missing 'error_type' or 'action'. Cannot learn effectively.")
                return

            pattern_key = (error_type, action_taken)

            # Create a summary of the context based on configured features
            context_summary = {feat: context.get(feat) for feat in self.context_features_to_log if feat in context}

            if pattern_key not in self.success_patterns:
                self.success_patterns[pattern_key] = {
                    'success_count': 0,
                    'total_attempts': 0,
                    'contexts': [] # Store list of context summaries for this pattern
                }

            current_pattern = self.success_patterns[pattern_key]
            current_pattern['total_attempts'] += 1
            if outcome_success:
                current_pattern['success_count'] += 1

            current_pattern['success_rate'] = current_pattern['success_count'] / current_pattern['total_attempts']

            # Add current context summary, maybe limit the size of this list
            max_contexts_to_store = self.config.get('max_contexts_per_pattern', 10)
            current_pattern['contexts'].append(context_summary)
            if len(current_pattern['contexts']) > max_contexts_to_store:
                current_pattern['contexts'] = current_pattern['contexts'][-max_contexts_to_store:]


            self.logger.info(f"Updated success pattern for ({error_type}, {action_taken}): "
                             f"{current_pattern['success_count']}/{current_pattern['total_attempts']} successes. "
                             f"Context: {context_summary}")

            # Call trainer to potentially update models (trainer decides if/how)
            if self.trainer:
                # Pass a structured version of remediation data that trainer might understand
                # This might need standardization later based on trainer's needs
                self.trainer.update_models_with_remediation(remediation_data)
            else:
                self.logger.warning("Trainer not initialized. Cannot pass remediation data for model updates.")

            # Retraining trigger logic
            # For simplicity, categorize any successful remediation for a known error as data for failure_prediction improvement
            if outcome_success and error_type != 'UnknownError':
                data_category_key = "failure_prediction_data" # Example category
                self.new_data_counter[data_category_key] = self.new_data_counter.get(data_category_key, 0) + 1
                self.logger.debug(f"New data point for '{data_category_key}', count: {self.new_data_counter[data_category_key]}")

                if self.new_data_counter[data_category_key] >= self.retraining_threshold:
                    self.logger.info(
                        f"Sufficient new data ({self.new_data_counter[data_category_key]} points) gathered for '{data_category_key}'. "
                        f"Consider retraining the relevant predictive models."
                    )
                    self.new_data_counter[data_category_key] = 0 # Reset counter

        except Exception as e:
            self.logger.error(f"Failed to learn from remediation: {str(e)}", exc_info=True)
            # Do not re-raise, allow learner to continue if one entry fails

    def get_recommendation(self, error_context: Dict[str, Any]) -> Dict[str, Any]:
        """Generate remediation recommendations based on learned success patterns and AI predictions."""
        self.logger.info(f"Getting recommendation for error_context: {error_context.get('error_type', 'Unknown')}")
        recommendations = []

        error_type = error_context.get('error_type')

        # Step 1: Check highly successful patterns
        if error_type:
            for (err_type_pattern, action_pattern), stats in self.success_patterns.items():
                if err_type_pattern == error_type:
                    success_rate_threshold = self.config.get('success_pattern_threshold', 0.8)
                    min_attempts_threshold = self.config.get('success_pattern_min_attempts', 5)
                    if stats['success_rate'] >= success_rate_threshold and stats['total_attempts'] >= min_attempts_threshold:
                        recommendations.append({
                            'recommended_action': action_pattern,
                            'confidence_score': stats['success_rate'],
                            'source': 'SuccessPattern',
                            'details': f"Action '{action_pattern}' has a {stats['success_rate']:.2%} success rate over {stats['total_attempts']} attempts for error '{error_type}'.",
                            'supporting_evidence': {'error_type': error_type, **stats}
                        })

        # Step 2: Use ArcPredictor if available
        ai_recommendations = []
        if self.predictor:
            try:
                # Predictor might provide various types of predictions.
                # For now, assume predict_failures gives some actionable output or can be adapted.
                # The structure of ai_prediction needs to be known to extract recommendations.
                # Let's assume predict_failures returns a dict that might contain 'recommended_action'
                # or data from which one can be derived.
                ai_prediction_output = self.predictor.predict_failures(error_context) # error_context might need feature engineering first for predictor

                # Example: If predictor output contains a direct recommendation or interpretable risk
                if ai_prediction_output and ai_prediction_output.get('prediction', {}).get('failure_probability', 0) > self.config.get('ai_predictor_failure_threshold', 0.5):
                    # This is a simplified interpretation. A real system might have more complex mapping
                    # from prediction output to specific remediation actions.
                    predicted_action = ai_prediction_output.get('recommended_action', "Investigate AI Predicted High Failure Risk") # Placeholder if not direct
                    ai_recommendations.append({
                        'recommended_action': predicted_action,
                        'confidence_score': ai_prediction_output.get('prediction', {}).get('failure_probability'),
                        'source': 'AIPredictor',
                        'details': f"AI Predictor suggests high failure probability ({ai_prediction_output.get('prediction', {}).get('failure_probability', 0):.2%}). Risk Level: {ai_prediction_output.get('risk_level', 'N/A')}",
                        'supporting_evidence': ai_prediction_output.get('feature_impacts', {})
                    })
            except Exception as e_predictor:
                self.logger.error(f"Error calling ArcPredictor: {str(e_predictor)}", exc_info=True)

        recommendations.extend(ai_recommendations)

        # Step 3: Combine and prioritize (simple sort for now)
        recommendations.sort(key=lambda x: x['confidence_score'], reverse=True)

        if not recommendations:
            self.logger.info("No specific recommendations generated. Providing default.")
            return {
                'recommended_action': 'ManualInvestigationRequired',
                'confidence_score': 0.1,
                'source': 'Default',
                'alternative_actions': [],
                'supporting_evidence': {'reason': 'No specific patterns or AI predictions met thresholds.'}
            }

        # Return the top recommendation and others as alternatives
        top_rec = recommendations[0]
        alternatives = [rec['recommended_action'] for rec in recommendations[1:] if rec['recommended_action'] != top_rec['recommended_action']]

        return {
            'recommended_action': top_rec['recommended_action'],
            'confidence_score': top_rec['confidence_score'],
            'source': top_rec['source'],
            'alternative_actions': list(set(alternatives))[:2], # Max 2 unique alternatives
            'supporting_evidence': top_rec.get('supporting_evidence', {})
        }


    def _extract_features(self, remediation_entry_context: Dict[str, Any]) -> Dict[str, Any]:
        """Extracts a summary of features from context for logging in success_patterns."""
        # This is not for ML model input directly anymore, but for summarizing context.
        context_summary = {}
        try:
            for feature_name in self.context_features_to_log:
                if feature_name in remediation_entry_context:
                    context_summary[feature_name] = remediation_entry_context[feature_name]
            return context_summary
        except Exception as e:
            self.logger.error(f"Feature extraction for context summary failed: {str(e)}", exc_info=True)
            return {"error": "context summarization failed"}

    # _calculate_success_rate is now integrated into learn_from_remediation's success_patterns update.
    # Removed _combine_predictions, _get_legacy_recommendation, _calculate_combined_confidence,
    # _get_best_action, _get_legacy_action as they are replaced by the new get_recommendation logic.
    # _get_alternative_actions is also implicitly handled by the new get_recommendation logic.

    def get_all_success_patterns(self) -> Dict[tuple, Dict[str, Any]]:
        """Returns all learned success patterns."""
        return self.success_patterns
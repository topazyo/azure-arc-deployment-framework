class RootCauseAnalyzer:
    def analyze_incident(self, incident_data):
        # Apply machine learning to identify root cause
        causes = self.ml_model.predict_root_cause(incident_data)
        
        # Generate explanation using explainable AI
        explanation = self.explainer.explain_prediction(causes)
        
        return {
            'primary_cause': causes[0],
            'confidence': causes[0].confidence,
            'contributing_factors': causes[1:],
            'explanation': explanation,
            'recommended_actions': self.generate_recommendations(causes)
        }
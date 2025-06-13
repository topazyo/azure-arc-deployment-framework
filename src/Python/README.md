# Python AI/ML Model Handling

The Python scripts in this directory, particularly `invoke_ai_engine.py` and `run_predictor.py`, rely on pre-trained machine learning models to function correctly.

## Model Storage and Configuration

- **`invoke_ai_engine.py`**: By default, this script expects models to be in a `./models_placeholder` directory relative to its own location (`src/Python/models_placeholder/`). This can be overridden using the `--modeldir` command-line argument.
- **`run_predictor.py`**: This script defaults to looking for models in a `data/models/latest` directory relative to the project root. This can also be overridden using the `--modeldir` argument.

It is crucial that the directory specified by `--modeldir` (or the default locations) contains valid model files (typically `.pkl` files) that are compatible with `predictive/predictor.py` (ArcPredictor). These include models for health prediction, failure prediction, and anomaly detection, along with their corresponding scalers and feature importance metadata, if applicable.

## Training Models

The `predictive/model_trainer.py` (ArcModelTrainer) class is provided within this framework to train new models. You will need to:
1.  Prepare your training data (e.g., CSV files or other structured data).
2.  Configure `src/config/ai_config.json` with appropriate feature lists, model parameters, and target column names for your data.
3.  Use `ArcModelTrainer` to train the models and save them to a directory.
4.  Ensure that the `--modeldir` argument of the prediction scripts points to this directory of trained models.

## Placeholder Models

The default `models_placeholder` directory (if it exists, or if created by a user) might initially contain sample or placeholder models. These are likely insufficient for production use and should be replaced with models trained on representative data for your environment.

**If the scripts report errors like "Model directory not found" or "No models loaded successfully," please ensure that:**
1.  You have trained models using `ArcModelTrainer` or another compatible process.
2.  The models are saved in the correct directory structure expected by `ArcPredictor` (e.g., `health_prediction_model.pkl`, `health_prediction_scaler.pkl`, etc.).
3.  The `--modeldir` argument correctly points to this directory.

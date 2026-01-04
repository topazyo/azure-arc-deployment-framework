# Azure Arc Deployment Framework

Enterprise-grade automation framework for Azure Arc agent deployment, management, and monitoring, built from real-world experience with 5000+ server deployments. Features AI-driven insights, advanced troubleshooting, and comprehensive monitoring capabilities.

## Features

### Core Capabilities
- Comprehensive prerequisite validation and remediation
- Automated deployment with intelligent rollback
- Advanced logging and diagnostics
- Multi-stage deployment orchestration
- Wave-based deployment automation

### AI/ML Features
- Predictive failure analysis using PredictiveAnalyticsEngine
- Pattern recognition via PatternAnalyzer (temporal, behavioral, failure patterns)
- Anomaly detection with TelemetryProcessor
- Automated root cause analysis via RootCauseAnalyzer
- Self-learning remediation with ArcRemediationLearner

### Monitoring & Management
- Real-time health monitoring
- Performance analytics
- Security compliance checking
- Configuration drift detection
- Automated maintenance

### Security
- Certificate management
- TLS configuration
- Network security validation
- Compliance enforcement
- Security baseline management

## Quickstart

1. Clone the repo:
   ```bash
   git clone https://github.com/topazyo/azure-arc-deployment-framework.git
   cd azure-arc-deployment-framework
   ```

2. Set up the dev environment (creates venv, installs dependencies, adds PS profile entries):
   ```powershell
   pwsh -File scripts/Initialize-DevEnvironment.ps1 -CreateVirtualEnv -InstallDependencies
   ```

3. Run tests to verify setup:
   ```bash
   python -m pytest tests/Python
   ```
   ```powershell
   pwsh -Command "Invoke-Pester -Path ./tests/PowerShell -CI"
   ```

4. Deploy to a test server:
   ```powershell
   Initialize-ArcDeployment -SubscriptionId "your-subscription-id" -ResourceGroupName "your-arc-rg" -Location "eastus"
   New-ArcDeployment -ServerName "TESTSERVER" -DeployAMA
   ```

## Prerequisites

### System Requirements
- Windows Server 2012 R2 or later
- PowerShell 5.1 or higher
- Python 3.8 or higher
- .NET Framework 4.7.2 or higher

### Azure Requirements
- Azure subscription
- Service Principal with appropriate permissions
- Azure Monitor Log Analytics workspace
- Required resource providers registered

### Network Requirements
- Outbound connectivity to Azure services
- Required endpoints accessible
- Appropriate proxy configuration (if applicable)

## Installation

### Quick Start
```powershell
# Clone the repository
git clone https://github.com/topazyo/azure-arc-deployment-framework.git

# Run installer
.\install.ps1 -InstallPath "C:\Program Files\AzureArcFramework"
```

### Manual Installation
```powershell
# Install PowerShell dependencies
Install-Module -Name Az.Accounts -Force
Install-Module -Name Az.ConnectedMachine -Force
Install-Module -Name Az.Monitor -Force

# Install Python dependencies
pip install -r requirements.txt

# Import the module
Import-Module AzureArcFramework
```

## Configuration

### Required Environment Variables
| Variable | Required | Default | Description | Where Used |
|----------|----------|---------|-------------|------------|
| ARC_WORKSPACE_ID | Yes | N/A | Azure Monitor workspace ID | PowerShell cmdlets for monitoring |
| ARC_WORKSPACE_KEY | Yes | N/A | Azure Monitor workspace key | PowerShell cmdlets for monitoring |

### Optional Environment Variables
| Variable | Required | Default | Description | Where Used |
|----------|----------|---------|-------------|------------|
| ARC_PREREQ_TESTDATA | No | off | Set to '1' for mock data in tests | Test scripts |
| PYTHONPATH | No | N/A | Add src/Python for AI scripts | Python AI components |

### Config Files
- [`src/config/ai_config.json`](src/config/ai_config.json): AI engine settings (e.g., model dirs, telemetry features). Defaults to placeholder models; update for production.
- [`src/config/server_inventory.json`](src/config/server_inventory.json): Server list for bulk ops.
- [`src/config/validation_matrix.json`](src/config/validation_matrix.json): Validation rules.

Do not commit secrets (e.g., workspace keys) to repo; use secure storage or env vars.

## Usage

### Common Commands
- **Build docs**: `pwsh -File scripts/Build-Documentation.ps1`
- **Run Python tests**: `python -m pytest tests/Python`
- **Run PowerShell tests**: `pwsh -Command "Invoke-Pester -Path ./tests/PowerShell -CI"`
- **Lint Python**: `python -m flake8 src/Python`
- **Lint PowerShell**: `pwsh -Command "Invoke-ScriptAnalyzer -Path ./src/PowerShell -Recurse"`

### Typical Workflows
- **Deployment**: Use `Initialize-ArcDeployment` then `New-ArcDeployment` for single/bulk servers.
- **AI Insights**: Run `Get-PredictiveInsights -ServerName "SERVER01"` (requires Python and ai_config.json).
- **Troubleshooting**: `Start-ArcTroubleshooter -ServerName "SERVER01"` for diagnostics.
- **Monitoring**: `Get-ArcHealthStatus -ServerName "SERVER01" -Detailed`.

## Project Layout
```
azure-arc-deployment-framework/
├── src/
│   ├── PowerShell/        # Core cmdlets (e.g., deployment, monitoring)
│   ├── Python/           # AI/ML components (e.g., predictive analytics)
│   └── config/           # Config files (ai_config.json, etc.)
├── docs/                # Documentation (AI-Components.md, Usage.md)
├── tests/              # Test suites (Python via pytest, PowerShell via Pester)
├── scripts/           # Utilities (e.g., Initialize-DevEnvironment.ps1)
├── examples/           # Sample scripts
├── build/              # Build artifacts
├── Diagnostics/        # Diagnostic logs
├── .pytest_cache/      # Python test cache
└── requirements.txt    # Python deps
```

## CI/CD
GitHub Actions workflows handle linting and tests (see .github/workflows/). Pre-commit hooks (added by Initialize-DevEnvironment.ps1) run pytest, Pester, flake8, and ScriptAnalyzer.

## Contributing
See [`CONTRIBUTING.md`](CONTRIBUTING.md "CONTRIBUTING.md") for setup, standards, and PR process.

## Security
Report security issues via [SECURITY.md](SECURITY.md). Do not commit sensitive data.

## License
This project is licensed under the MIT License - see the [`LICENSE`](LICENSE) file for details.
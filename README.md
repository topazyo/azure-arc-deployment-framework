# Azure Arc Deployment Framework
## Overview
Enterprise-grade automation framework for Azure Arc agent deployment and troubleshooting, built from real-world experience with 5000+ server deployments.

## Features
- Comprehensive prerequisite validation
- Automated deployment with rollback capability
- Detailed logging and troubleshooting
- Support for various deployment scenarios
- Wave-based deployment automation

## Prerequisites
- PowerShell 5.1 or higher
- Azure PowerShell Module
- Administrative access to target servers
- Service Principal with appropriate permissions

## Installation
```powershell
# Clone the repository
git clone https://github.com/your-org/azure-arc-deployment-framework.git

# Import the module
Import-Module .\src\core\deployment.ps1
```

## Usage
```powershell
# Single server deployment
Deploy-ArcAgent -ServerName "SERVER01" -Environment "Production"

# Bulk deployment
$servers = Get-Content .\config\deployment-waves.json
Deploy-ArcAgentBulk -Servers $servers -Wave 1
```

## Documentation

- [Installation Guide](docs/Installation.md)
- [Usage Guide](docs/Usage.md)
- [Architecture Overview](docs/Architecture.md)

## Contributing
Please read [CONTRIBUTING.md](CONTRIBUTING.md) for details on our code of conduct and the process for submitting pull requests.

## License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
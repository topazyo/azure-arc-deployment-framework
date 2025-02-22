# Contributing to Azure Arc Deployment Framework

## Table of Contents
- [Getting Started](#getting-started)
- [Development Environment Setup](#development-environment-setup)
- [Development Workflow](#development-workflow)
- [Code Standards](#code-standards)
- [Testing Guidelines](#testing-guidelines)
- [Documentation](#documentation)
- [Pull Request Process](#pull-request-process)
- [Community Guidelines](#community-guidelines)

## Getting Started

### Prerequisites
- PowerShell 5.1 or higher
- Python 3.8 or higher
- Az PowerShell modules
- Git
- Visual Studio Code (recommended)
- Azure Subscription for testing

### Initial Setup
1. Fork the repository
2. Clone your fork:
```bash
git clone https://github.com/yourusername/AzureArcDeploymentFramework.git
cd AzureArcDeploymentFramework
```

3. Add upstream remote:
```bash
git remote add upstream https://github.com/originalowner/AzureArcDeploymentFramework.git
```

4. Create a new branch:
```bash
git checkout -b feature/your-feature-name
```

## Development Environment Setup

### PowerShell Environment
1. Install required PowerShell modules:
```powershell
# Install required modules
Install-Module -Name Az.Accounts -Force
Install-Module -Name Az.ConnectedMachine -Force
Install-Module -Name Az.Monitor -Force
Install-Module -Name Pester -Force
Install-Module -Name PSScriptAnalyzer -Force
```

2. Configure PowerShell environment:
```powershell
# Set execution policy
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Import development module
Import-Module .\src\PowerShell\AzureArcFramework.psd1 -Force
```

### Python Environment
1. Create virtual environment:
```bash
python -m venv .venv
source .venv/bin/activate  # Linux/Mac
.venv\Scripts\activate     # Windows
```

2. Install dependencies:
```bash
pip install -r requirements.txt
pip install -r requirements-dev.txt
```

### IDE Setup
Recommended VS Code extensions:
- PowerShell
- Python
- GitLens
- markdownlint
- YAML

## Development Workflow

### Branch Naming Convention
- `feature/` - New features
- `bugfix/` - Bug fixes
- `hotfix/` - Critical fixes
- `docs/` - Documentation updates
- `test/` - Test additions or modifications

### Commit Message Format
```
<type>(<scope>): <subject>

<body>

<footer>
```

Types:
- feat: New feature
- fix: Bug fix
- docs: Documentation
- style: Formatting
- refactor: Code restructuring
- test: Test addition/modification
- chore: Maintenance

Example:
```
feat(monitoring): add enhanced performance metrics

- Add CPU utilization tracking
- Add memory usage monitoring
- Implement custom metric collection

Closes #123
```

## Code Standards

### PowerShell Standards
1. Follow PowerShell best practices:
```powershell
# Function naming
function Verb-Noun {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$RequiredParam,
        
        [Parameter()]
        [string]$OptionalParam
    )

    begin {
        # Initialize resources
    }

    process {
        try {
            # Main logic
        }
        catch {
            # Error handling
        }
    }

    end {
        # Cleanup
    }
}
```

2. Use proper error handling:
```powershell
try {
    # Operation
}
catch {
    Write-Error "Operation failed: $_"
    throw
}
```

### Python Standards
1. Follow PEP 8 guidelines
2. Use type hints:
```python
from typing import Dict, List, Optional

def process_data(data: Dict[str, Any]) -> Optional[List[str]]:
    """
    Process input data and return results.

    Args:
        data: Input data dictionary

    Returns:
        List of processed strings or None if processing fails
    """
    pass
```

## Testing Guidelines

### PowerShell Tests
1. Use Pester for testing:
```powershell
Describe "Function Tests" {
    BeforeAll {
        # Test setup
    }

    It "Should perform specific action" {
        # Test logic
        $result = Test-Function
        $result | Should -Be $expected
    }

    AfterAll {
        # Test cleanup
    }
}
```

2. Run tests:
```powershell
Invoke-Pester -Path .\tests
```

### Python Tests
1. Use pytest for testing:
```python
import pytest

def test_function():
    # Test logic
    result = function_under_test()
    assert result == expected
```

2. Run tests:
```bash
pytest tests/
```

## Documentation

### Documentation Requirements
1. README.md for each component
2. Function/method documentation
3. Example usage
4. Architecture diagrams (when applicable)
5. Troubleshooting guides

### Documentation Format
```powershell
<#
.SYNOPSIS
    Brief description

.DESCRIPTION
    Detailed description

.PARAMETER Param1
    Parameter description

.EXAMPLE
    Example usage

.NOTES
    Additional information
#>
```

## Pull Request Process

1. Update documentation
2. Run all tests
3. Update CHANGELOG.md
4. Create pull request:
   - Clear description
   - Reference issues
   - Include test results
   - Add screenshots (if applicable)

### PR Template
```markdown
## Description
Brief description of changes

## Type of Change
- [ ] Bug fix
- [ ] New feature
- [ ] Documentation update
- [ ] Other (specify)

## Testing
- [ ] Unit tests added/updated
- [ ] Integration tests added/updated
- [ ] Manual testing performed

## Checklist
- [ ] Code follows style guidelines
- [ ] Documentation updated
- [ ] Tests passing
- [ ] CHANGELOG.md updated
```

## Community Guidelines

### Communication
- Be respectful and inclusive
- Provide constructive feedback
- Stay on topic
- Use clear and concise language

### Support
- Check existing issues before creating new ones
- Provide detailed information when reporting issues
- Help others when possible
- Share knowledge and experiences

### Recognition
Contributors will be recognized in:
- CONTRIBUTORS.md
- Release notes
- Project documentation

## Additional Resources
- [PowerShell Style Guide](https://github.com/PoshCode/PowerShellPracticeAndStyle)
- [Python Style Guide (PEP 8)](https://www.python.org/dev/peps/pep-0008/)
- [Git Commit Messages](https://chris.beams.io/posts/git-commit/)
- [Semantic Versioning](https://semver.org/)
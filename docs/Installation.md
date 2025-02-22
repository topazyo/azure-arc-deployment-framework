# Installation Guide

## Prerequisites

### System Requirements
- Windows Server 2012 R2 or later
- PowerShell 5.1 or higher
- Python 3.8 or higher
- .NET Framework 4.7.2 or higher
- 4GB RAM minimum
- 10GB free disk space

### Network Requirements
- Outbound connectivity to Azure services
- Required endpoints:
  - *.management.azure.com
  - *.login.microsoftonline.com
  - *.servicebus.windows.net
  - *.ods.opinsights.azure.com
  - *.oms.opinsights.azure.com

### Azure Requirements
- Azure subscription
- Contributor rights on target subscription
- Resource provider registration:
  - Microsoft.HybridCompute
  - Microsoft.GuestConfiguration
  - Microsoft.HybridConnectivity

## Installation Options

### 1. Automated Installation

```powershell
# Download and run installer
.\install.ps1 -InstallPath "C:\Program Files\AzureArcFramework" -Dev
```

### 2. Manual Installation

```powershell
# 1. Install PowerShell Dependencies
Install-Module -Name Az.Accounts -Force
Install-Module -Name Az.ConnectedMachine -Force
Install-Module -Name Az.Monitor -Force

# 2. Install Python Dependencies
pip install -r requirements.txt

# 3. Import PowerShell Module
Import-Module .\src\PowerShell\AzureArcFramework.psd1
```

## Configuration

### 1. Basic Configuration
```powershell
# Initialize framework
Initialize-ArcDeployment -WorkspaceId "<workspace-id>" -WorkspaceKey "<workspace-key>"
```

### 2. Advanced Configuration
```powershell
# Custom configuration
$config = @{
    RetryCount = 5
    RetryDelaySeconds = 30
    LogLevel = "Verbose"
    AIEnabled = $true
}

Initialize-ArcDeployment -CustomConfig $config
```

### 3. Environment-Specific Configuration
```powershell
# Load environment configuration
$envConfig = Get-Content .\Config\prod-environment.json | ConvertFrom-Json

# Apply configuration
Set-ArcEnvironmentConfig -Config $envConfig
```

## Validation

### 1. Installation Validation
```powershell
# Validate installation
Test-ArcFrameworkInstallation
```

### 2. Connectivity Validation
```powershell
# Test connectivity
Test-ArcConnectivity -Detailed
```

### 3. Permission Validation
```powershell
# Verify permissions
Test-ArcPermissions
```

## Troubleshooting

### Common Issues

1. Module Import Failures
```powershell
# Clear PowerShell module cache
Clear-ArcModuleCache
```

2. Python Dependencies
```powershell
# Verify Python environment
Test-PythonEnvironment
```

3. Network Issues
```powershell
# Detailed network diagnostics
Start-ArcNetworkDiagnostics
```

### Logging

Logs are stored in:
- PowerShell: `C:\ProgramData\AzureArcFramework\Logs`
- Python: `C:\ProgramData\AzureArcFramework\Python\Logs`

### Support

For support:
1. Check logs
2. Review documentation
3. Submit issues on GitHub
4. Contact support team

## Uninstallation

### Clean Uninstall
```powershell
# Run uninstaller
.\uninstall.ps1 -RemoveData
```

### Manual Cleanup
```powershell
# Remove modules
Remove-Module AzureArcFramework
Uninstall-Module Az.ConnectedMachine

# Remove Python packages
pip uninstall azure-arc-framework

# Clean up data
Remove-Item -Path "C:\ProgramData\AzureArcFramework" -Recurse -Force
```
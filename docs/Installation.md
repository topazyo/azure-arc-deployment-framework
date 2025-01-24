# Installation Guide

## Prerequisites

### System Requirements
- Windows Server 2012 R2 or later
- PowerShell 5.1 or higher
- .NET Framework 4.7.2 or higher
- Minimum 2 GB RAM
- 4 GB available disk space

### Network Requirements
- Outbound connectivity to Azure (443)
- Access to required endpoints:
  - *.management.azure.com
  - *.login.microsoftonline.com
  - *.servicebus.windows.net

## Installation Steps

### 1. Module Installation

```powershell
# Install required PowerShell modules
Install-Module -Name Az.ConnectedMachine -Force
Install-Module -Name Az.Accounts -Force

# Clone the repository
git clone https://github.com/your-org/AzureArcDeploymentFramework
cd AzureArcDeploymentFramework

# Import the module
Import-Module .\src\PowerShell\AzureArcDeployment.psm1
```

### 2. Configuration

1. Create configuration file:
```powershell
Copy-Item .\config\sample.json .\config\production.json
```

2. Update the configuration with your environment details:
```json
{
    "Environment": "Production",
    "TenantId": "your-tenant-id",
    "SubscriptionId": "your-subscription-id",
    "ResourceGroup": "your-resource-group"
}
```

### 3. Verification

Run the validation script:
```powershell
.\scripts\Test-Installation.ps1
```

## Troubleshooting

Common installation issues and solutions:

1. Module Import Failures
   - Verify PowerShell version
   - Check execution policy
   - Clear PowerShell module cache

2. Network Connectivity Issues
   - Validate proxy settings
   - Check firewall rules
   - Verify DNS resolution
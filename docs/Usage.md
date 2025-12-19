# Usage Guide

This guide provides instructions on how to use the Azure Arc Framework PowerShell modules, focusing on core functionalities and AI-enhanced operations.

## General Usage Notes

### Installation and Import
1.  Ensure the Azure Arc Framework module directory is available in your PowerShell module path or use a direct path for import.
2.  Import the module into your PowerShell session:
    ```powershell
    Import-Module AzureArcFramework # Or use path: Import-Module ./path/to/AzureArcFramework.psd1
    ```

### Prerequisites
*   **PowerShell Version**: 5.1 or higher.
*   **Azure Az PowerShell Modules**: Several cmdlets require `Az.Accounts` and `Az.Resources`. Others might require additional Az modules (e.g., `Az.ConnectedMachine` for agent operations not directly covered by these specific cmdlets). Install them via `Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force`.
*   **Azure Login**: For cmdlets interacting with Azure (like `Initialize-ArcDeployment`), ensure you are logged into Azure using `Connect-AzAccount` with appropriate permissions.
*   **Python for AI Features**: For `Get-PredictiveInsights`, Python (3.x recommended) must be installed and accessible. The `invoke_ai_engine.py` script (part of this framework) must also be present.

### Configuration File (`src/config/ai_config.json`)
Advanced configuration for the Python AI engine (e.g., thresholds, feature lists for analysis, model parameters for training) is managed in `src/config/ai_config.json`. For details on customizing AI behavior or retraining models, refer to the `AI-Components.md` document or specific configuration guides.

### Model Training
Predictive models are trained using Python scripts (e.g., `ArcModelTrainer` detailed in `AI-Components.md`). This is a separate process from the PowerShell cmdlet usage. The cmdlets consume the outputs of these trained models via the AI engine.

## Core Framework Cmdlets

### 1. Preparing Azure Environment: `Initialize-ArcDeployment`
*   **Purpose**: Prepares your Azure environment for onboarding Azure Arc-enabled servers. It ensures the specified subscription is active and creates or validates the target resource group where Arc server resources will reside.
*   **Syntax Example**:
    ```powershell
    Initialize-ArcDeployment -SubscriptionId "your-subscription-id" -ResourceGroupName "your-arc-rg" -Location "eastus" -Tags @{Project="ArcProject"; CostCenter="123"} [-TenantId "your-tenant-id"] [-WhatIf]
    ```
*   **Key Parameters**:
    *   `-SubscriptionId`: (Required) The ID of the Azure subscription to use.
    *   `-ResourceGroupName`: (Required) The name of the resource group for Arc-enabled servers.
    *   `-Location`: (Required) The Azure region for the resource group (e.g., "eastus", "westeurope").
    *   `-Tags`: (Optional) A hashtable of tags to apply to the resource group.
    *   `-TenantId`: (Optional) The Azure Active Directory tenant ID. If not provided, the default tenant for the logged-in account is used.
*   **Output**: Returns a PSCustomObject with details of the configured (or created) resource group, including its name, location, provisioning state, and tags.
*   **Prerequisites**:
    *   User must be logged into Azure (`Connect-AzAccount`) with permissions to read subscriptions and resource groups, and potentially create/update resource groups.
    *   Azure Az PowerShell modules `Az.Accounts` and `Az.Resources` must be installed.
*   **Note**: This cmdlet supports `-WhatIf` and `-Confirm` to preview changes before they are made.

### 2. Onboarding Servers to Azure Arc: `New-ArcDeployment`
*   **Purpose**: Generates the `azcmagent connect` command required to onboard the server where the command will be executed to Azure Arc. This function helps ensure all necessary parameters are correctly formatted for the Azure Connected Machine agent.
*   **Syntax Example**:
    ```powershell
    # Basic onboarding command generation
    $onboardingCommand = New-ArcDeployment -ServerName "MyWebServer01" -ResourceGroupName "your-arc-rg" -SubscriptionId "your-subscription-id" -Location "eastus" -TenantId "your-tenant-id"
    Write-Host "Run this command on MyWebServer01:"
    Write-Host $onboardingCommand.OnboardingCommand

    # With optional parameters like tags, correlation ID, and Service Principal
    $securePassword = Read-Host -AsSecureString "Enter SPN Secret"
    New-ArcDeployment -ServerName "MyFileServer02" -ResourceGroupName "your-arc-rg" -SubscriptionId "your-subscription-id" -Location "westeurope" -TenantId "your-tenant-id" `
        -Tags @{OS="Windows"; Role="FileServer"} `
        -CorrelationId (New-Guid).Guid `
        -ServicePrincipalAppId "your-spn-app-id" -ServicePrincipalSecret $securePassword
    ```
*   **Key Parameters**:
    *   `-ServerName`: (Required) Informational name for the server being onboarded. Used in logging.
    *   `-ResourceGroupName`, `-SubscriptionId`, `-Location`, `-TenantId`: (Required) Azure target details for the Arc server resource.
    *   `-Tags`: (Optional) Hashtable of tags for the Azure Arc server resource.
    *   `-CorrelationId`: (Optional) A GUID for tracking the onboarding operation.
    *   `-Cloud`: (Optional) Specifies the Azure cloud (e.g., "AzureCloud", "AzureUSGovernment"). Defaults to "AzureCloud".
    *   `-ProxyUrl`, `-ProxyBypass`: (Optional) For configuring agent proxy settings.
    *   `-ServicePrincipalAppId`, `-ServicePrincipalSecret`: (Optional) For onboarding using a Service Principal. The secret should be a `SecureString`.
    *   `-AgentInstallationScriptPath`, `-AgentInstallationArguments`: (Optional) Path to a custom agent installation script and its arguments. Note: The current version only provides a placeholder for executing this script.
*   **Output**: Returns a PSCustomObject containing the fully constructed `azcmagent connect` command (`OnboardingCommand`) and other details like `ServerName`, `ResourceGroupName`, etc.
*   **Action Required**: The primary output is the `OnboardingCommand`. **The user must copy this command and execute it with appropriate permissions on the target server to complete the Azure Arc onboarding process.**
*   **Agent Installation**: The Azure Connected Machine agent must be installed on the target server *before* running the `azcmagent connect` command. This function can conceptually trigger a custom installation script if `-AgentInstallationScriptPath` is provided, but the execution is currently a placeholder.
*   **Note**: This cmdlet supports `-WhatIf` and `-Confirm` for the conceptual execution of the agent installation script and the onboarding command (though direct execution of `azcmagent connect` is not performed by this script in the current version).

### 3. Troubleshooting Arc-enabled Servers: `Start-ArcTroubleshooter`
*   **Purpose**: Initiates a comprehensive diagnostic and troubleshooting session for an Azure Arc-enabled server. It collects system state, Arc agent and Azure Monitor Agent (AMA) diagnostics, analyzes them, and can suggest or (if configured) apply remediations.
*   **Syntax Example**:
    ```powershell
    # Basic troubleshooting session
    Start-ArcTroubleshooter -ServerName "ProblematicServer01"

    # With AI-enhanced analysis and auto-remediation (if configured in $customConfig)
    $customTroubleshootingConfig = @{
        AnalysisDepth = "Comprehensive";
        AIEnabled = $true;
        AutoRemediation = @{ Enabled = $true; ApprovalRequired = $false }
    }
    Start-ArcTroubleshooter -ServerName "ProblematicServer01" -TroubleshootingConfig $customTroubleshootingConfig -IncludeAMAHealthCheck -RunRemediation
    ```
*   **Key Parameters**: (Refer to the function's help or `AI-Components.md` for a full list, as it's extensive)
    *   `-ServerName`: The name of the server to troubleshoot.
    *   `-TroubleshootingConfig`: A hashtable for advanced configuration (e.g., logging, analysis depth, AI enablement, auto-remediation settings).
    *   `-CollectArcAgentLogs`, `-CollectAMAExtensionLogs`, `-IncludeAMAHealthCheck`: Flags to control specific data collection steps.
    *   `-RunRemediation`: Flag to attempt automated remediations based on findings.
*   **Output**: Typically outputs a detailed report object and logs to a specified path. The nature of output can vary based on parameters.
*   **Note**: This is a powerful script that performs many actions. It's advisable to run with `-WhatIf` first if auto-remediation is enabled.

## AI-Enhanced Operations

### 1. Getting Predictive Insights: `Get-PredictiveInsights`
*   **Purpose**: Retrieves AI-driven predictive insights for a specified server. These insights can include risk assessments, health status predictions, potential failure predictions, and actionable recommendations.
*   **Syntax Example**:
    ```powershell
    # Get full insights for a server
    $insights = Get-PredictiveInsights -ServerName "MyCriticalServer01"
    $insights | Format-List * # Display all properties

    # Get specific health-focused insights
    Get-PredictiveInsights -ServerName "MyWebServer02" -AnalysisType "Health"

    # Using a specific Python executable and script path (if not found automatically)
    Get-PredictiveInsights -ServerName "DevServer03" -PythonExecutable "C:\Python39\python.exe" -ScriptPath "C:\Projects\AzureArcFramework\src\Python\invoke_ai_engine.py"
    ```
*   **Key Parameters**:
    *   `-ServerName`: (Required) The name of the server for which to retrieve insights.
    *   `-AnalysisType`: (Optional) Type of analysis to perform. Options: "Full", "Health", "Failure", "Anomaly". Defaults to "Full".
    *   `-PythonExecutable`: (Optional) Path to the Python executable (e.g., `python.exe`, `python3`). If not provided, the script attempts to find `python` or `python3` in the system PATH.
    *   `-ScriptPath`: (Optional) Full path to the `invoke_ai_engine.py` script. If not provided, the script attempts to find it relative to its own location.
*   **Output**: Returns a PowerShell custom object converted from the JSON output generated by the Python AI engine. The object structure typically includes:
    *   `overall_risk`: Contains `score`, `level`, `confidence`, `contributing_factors`.
    *   `health_status`: Predicted health status and probability.
    *   `failure_risk`: Predicted failure probability and specific predicted failures.
    *   `anomalies`: Information about detected anomalies and scores.
    *   `patterns`: Identified operational patterns.
    *   `recommendations`: A list of actionable recommendations with priority and details.
    *   `server_name`, `analysis_type_processed`, `timestamp`: Metadata about the analysis.
    *   `PSServerName`, `PSAnalysisType`: Parameters passed from PowerShell, added for cross-reference.
*   **Current AI Engine State**: **Important Note:** The underlying Python AI engine (`invoke_ai_engine.py`) currently uses a **placeholder engine**. This means the insights returned are for demonstration and testing the PowerShell-Python pipeline. They are generated based on simple logic (e.g., server name length) and are **not based on actual trained Machine Learning models or deep telemetry analysis yet.**
*   **Prerequisites**:
    *   Python 3.x must be installed and accessible via the system PATH or the `-PythonExecutable` parameter.
    *   The `invoke_ai_engine.py` script must be present at its default relative location (`../../src/Python/`) or the path specified via `-ScriptPath`.

### 2. AI Remediation Workflow: `Start-AIRemediationWorkflow`
*   **Purpose**: Runs the pattern-to-remediation pipeline: detect issues in diagnostics, map them to remediation rules, execute validated actions, and emit a telemetry summary (including pattern/action counts) for downstream AI.
*   **Common syntax**:
    ```powershell
    Start-AIRemediationWorkflow -InputData $telemetry -RemediationMode Automatic `
      -IssuePatternDefinitionsPath 'tests/Powershell/fixtures/issue_patterns_sample.json' `
      -RemediationRulesPath 'tests/Powershell/fixtures/remediation_rules_sample.json' `
      -FindIssuePatternsPath 'src/Powershell/remediation/Find-IssuePatterns.ps1' `
      -GetRemediationActionPath 'src/Powershell/remediation/Get-RemediationAction.ps1' `
      -ValidationRulesPath 'tests/Powershell/fixtures/validation_rules_sample.json' `
      -LogPath '.\Logs\remediation.log'
    ```
*   **Key parameters**:
    *   `-IssuePatternDefinitionsPath`: JSON rule pack for pattern detection. Defaults to the built-in patterns if omitted; accept StartsWith/EndsWith/threshold operators.
    *   `-RemediationRulesPath`: JSON rule pack mapping `IssueId` to `RemediationActionId` and parameters.
    *   `-FindIssuePatternsPath` / `-GetRemediationActionPath`: Override script paths when running outside the module root.
    *   `-ValidationRulesPath`: Optional validation rules merged with derived checks (`Replace` or `AppendDerived`).
    *   `-RemediationMode`: `Automatic` or `ManualApproval`; actions run through `Start-RemediationAction` with validation and optional backups.
*   **Inputs**: Provide either parsed diagnostics/telemetry (hashtable or object) or a path to a diagnostics JSON file; sample fixture: tests/Powershell/fixtures/diagnostics_pattern_sample.json.
*   **Outputs**: Structured object with detected patterns, selected remediation actions, validation results, execution summaries, and telemetry counts (`PatternsDetected`, `ActionsResolved`, `ActionsExecuted`).
*   **Error handling**: Missing rule packs or malformed JSON surface as terminating errors; execution failures bubble the underlying action/validation errors so they can be audited in logs.

## Advanced Features

#### Pattern Analysis
```powershell
# Analyze patterns
Invoke-AIPatternAnalysis -LogPath "C:\Logs\Arc"

# Get recommendations
Get-AIRecommendations -ServerName "SERVER01"
```

### 2. Security Operations

#### Security Validation
```powershell
# Validate security configuration
Test-SecurityCompliance -ServerName "SERVER01"

# Apply security baseline
Set-SecurityBaseline -ServerName "SERVER01"
```

#### Certificate Management
```powershell
# Check certificates
Test-CertificateRequirements -ServerName "SERVER01"

# Renew certificates
Update-ArcCertificates -ServerName "SERVER01"
```

### 3. Maintenance Operations

#### Updates
```powershell
# Check for updates
Get-ArcUpdates -ServerName "SERVER01"

# Apply updates
Update-ArcAgent -ServerName "SERVER01"
```

#### Configuration Management
```powershell
# Export configuration
Export-ArcConfiguration -ServerName "SERVER01"

# Import configuration
Import-ArcConfiguration -ServerName "SERVER01" -Path ".\config.json"
```

## Batch Operations

### 1. Parallel Deployment
```powershell
# Deploy to multiple servers
$deploymentParams = @{
    Servers = Get-Content .\servers.txt
    DeployAMA = $true
    MaxParallel = 10
}
Start-ParallelDeployment @deploymentParams
```

### 2. Bulk Validation
```powershell
# Validate multiple servers
$validationParams = @{
    Servers = Get-Content .\servers.txt
    ValidationLevel = 'Comprehensive'
}
Start-BulkValidation @validationParams
```

### 3. Validation rules and drift baselines (samples)
- Sample validation rules JSON: tests/Powershell/fixtures/validation_rules_sample.json (per-action steps, merge behaviors Replace/AppendDerived).
- Sample drift baseline JSON: tests/Powershell/fixtures/drift_baseline.json (registry, service, firewall, and audit expectations).
- See docs/Validation-Fixtures.md for structure and authoring guidance.

#### Running drift checks with a custom baseline
```powershell
# Run configuration drift using your baseline JSON
Test-ConfigurationDrift -BaselinePath 'C:\baselines\arc-drift.json' -LogPath 'C:\Logs\drift.log'

# Include drift inside Arc Troubleshooter
Start-ArcTroubleshooter -ServerName 'ArcSrv01' -DriftBaselinePath 'C:\baselines\arc-drift.json' -OutputPath '.\Logs'
```

#### Supplying validation rules to AI remediation
```powershell
# Run AI remediation workflow with validation rules
Start-AIRemediationWorkflow -InputData $telemetry -RemediationMode 'Automatic' `
    -ValidationRulesPath 'C:\baselines\validation_rules.json' `
    -LogPath 'C:\Logs\remediation.log'
```

## Monitoring and Reporting

### 1. Custom Reports
```powershell
# Generate custom report
$reportParams = @{
    ReportType = 'Compliance'
    Format = 'HTML'
    Path = '.\Reports'
}
New-ArcReport @reportParams
```

### 2. Alerts
```powershell
# Configure alerts
Set-ArcAlerts -ServerName "SERVER01" -AlertConfig .\alerts.json

# Get alert history
Get-ArcAlerts -ServerName "SERVER01" -Last 24h
```

## Integration

### 1. Azure Monitor
```powershell
# Configure data collection
Set-DataCollectionRules -ServerName "SERVER01" -RuleType Security

# Validate data flow
Test-DataCollection -ServerName "SERVER01"
```

### 2. Azure Security Center
```powershell
# Enable security monitoring
Enable-SecurityMonitoring -ServerName "SERVER01"

# Get security score
Get-SecurityScore -ServerName "SERVER01"
```

## Best Practices

### 1. Deployment
- Always run prerequisite checks
- Use staging environments
- Implement proper error handling
- Maintain deployment logs
- Validate post-deployment

### 2. Monitoring
- Configure appropriate alert thresholds
- Regular health checks
- Monitor resource usage
- Track performance metrics
- Review logs regularly

### 3. Maintenance
- Regular updates
- Configuration backups
- Document changes
- Test in staging
- Maintain audit logs

## Troubleshooting Guide

### 1. Common Issues
- Connectivity problems
- Authentication failures
- Resource constraints
- Configuration drift
- Performance issues

### 2. Diagnostic Tools
```powershell
# Run diagnostics
Start-ArcDiagnostics -ServerName "SERVER01"

# Collect logs
Export-ArcLogs -ServerName "SERVER01"
```

### 3. Recovery Procedures
```powershell
# Reset agent
Reset-ArcAgent -ServerName "SERVER01"

# Restore configuration
Restore-ArcConfiguration -ServerName "SERVER01"
```
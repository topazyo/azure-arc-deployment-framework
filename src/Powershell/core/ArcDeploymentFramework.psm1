#Requires -Version 5.1
#Requires -Modules Az.ConnectedMachine, Az.Accounts, Az.Monitor

# Module Variables
$script:ModuleRoot = $PSScriptRoot
$script:ConfigPath = Join-Path $PSScriptRoot "../../config"

# Import Configuration
$script:Config = @{}
try {
    $configFiles = @(
        "server_inventory.json",
        "ai_config.json",
        "validation_matrix.json",
        "dcr-templates.json"
    )

    foreach ($file in $configFiles) {
        $filePath = Join-Path $script:ConfigPath $file
        if (Test-Path $filePath) {
            $script:Config[$file.Replace('.json','')] = Get-Content $filePath | ConvertFrom-Json
        }
        else {
            if ($file -eq "ai_config.json") {
                Write-Error "Critical configuration file not found: $file at $filePath"
                throw "Critical configuration file ai_config.json not found."
            }
            else {
                Write-Warning "Configuration file not found: $file at $filePath"
            }
        }
    }
}
catch {
    Write-Error "Failed to load configuration: $_"
    # Re-throw the original exception if it's the specific one for ai_config.json,
    # or a general one if something else went wrong.
    if ($_.Exception.Message -eq "Critical configuration file ai_config.json not found.") {
        throw $_.Exception
    }
    throw "Configuration loading failed."
}

# Import Functions
$functionFolders = @(
    'Core',
    'AI',
    'Security',
    'Monitoring',
    'Utils'
)

foreach ($folder in $functionFolders) {
    $folderPath = Join-Path (Split-Path -Path $PSScriptRoot -Parent) $folder
    if (Test-Path $folderPath) {
        $functions = Get-ChildItem -Path $folderPath -Filter "*.ps1"
        foreach ($function in $functions) {
            try {
                $tokens = $null
                $parseErrors = $null
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($function.FullName, [ref]$tokens, [ref]$parseErrors)

                if ($parseErrors.Count -gt 0) {
                    Write-Warning "Skipping function import for $($function.FullName) because the file has parse errors."
                    continue
                }

                $topLevelStatements = @($ast.EndBlock.Statements)
                $containsOnlyFunctions =
                    $topLevelStatements.Count -gt 0 -and
                    @($topLevelStatements | Where-Object { $_ -isnot [System.Management.Automation.Language.FunctionDefinitionAst] }).Count -eq 0 -and
                    -not $ast.ParamBlock

                if (-not $containsOnlyFunctions) {
                    Write-Verbose "Skipping script-style file during module import: $($function.FullName)"
                    continue
                }

                . $function.FullName
            }
            catch {
                Write-Error "Failed to import function $($function.FullName): $_"
            }
        }
    }
}

# Module Configuration
$script:DefaultConfig = @{
    RetryCount = 3
    RetryDelaySeconds = 30
    LogLevel = "Information"
    DefaultWorkspaceId = $null
    DefaultWorkspaceKey = $null
}

<#
.SYNOPSIS
Initializes the Azure Arc deployment module state.

.DESCRIPTION
Validates the current Azure context, applies optional workspace credentials,
merges any caller-provided configuration, and returns the resulting runtime
configuration snapshot used by later deployment and troubleshooting commands.

.PARAMETER WorkspaceId
Optional Log Analytics workspace identifier for AMA-related operations.

.PARAMETER WorkspaceKey
Optional Log Analytics workspace key paired with WorkspaceId.

.PARAMETER CustomConfig
Optional hashtable of configuration overrides merged into the module defaults.

.PARAMETER LogPathOverride
Optional log root override applied during module initialization.

.OUTPUTS
Hashtable
#>
function Initialize-ArcDeployment {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]$WorkspaceId,
        [Parameter()]
        [string]$WorkspaceKey,
        [Parameter()]
        [hashtable]$CustomConfig,
        [Parameter()]
        [string]$LogPathOverride # New parameter
    )

    try {
        # Validate Azure Connection
        $context = Get-AzContext
        if (-not $context) {
            throw "Not connected to Azure. Please run Connect-AzAccount first."
        }

        # Set workspace credentials if provided
        if ($WorkspaceId) {
            $script:DefaultConfig.DefaultWorkspaceId = $WorkspaceId
        }
        if ($WorkspaceKey) {
            $script:DefaultConfig.DefaultWorkspaceKey = $WorkspaceKey
        }

        # Merge custom configuration
        if ($CustomConfig) {
            $script:DefaultConfig = Merge-CommonHashtable $script:DefaultConfig $CustomConfig
        }

        # Store LogPathOverride if provided
        if (-not [string]::IsNullOrEmpty($LogPathOverride)) {
            $script:DefaultConfig.LogPathOverride = $LogPathOverride
        }

        # Initialize logging
        Initialize-Logging

        # Validate required modules
        $requiredModules = @('Az.ConnectedMachine', 'Az.Accounts', 'Az.Monitor')
        foreach ($module in $requiredModules) {
            if (-not (Get-Module -Name $module -ListAvailable)) {
                throw "Required module not found: $module"
            }
        }

        return @{
            Status = "Initialized"
            Context = $context
            Config = $script:DefaultConfig
            Timestamp = Get-Date
        }
    }
    catch {
        Write-Error "Initialization failed: $_"
        throw
    }
}

<#
.SYNOPSIS
Deploys Azure Arc and optional AMA components to a target server.

.DESCRIPTION
Builds the deployment parameter set from module defaults and caller input,
validates AMA prerequisites when requested, and invokes the deployment entry
point under ShouldProcess control.

.PARAMETER ServerName
Target server to onboard to Azure Arc.

.PARAMETER ConfigurationParams
Optional deployment configuration overrides for the target server.

.PARAMETER DeployAMA
Includes Azure Monitor Agent deployment in the Arc onboarding flow.

.PARAMETER Force
Passes force semantics through to the underlying deployment implementation.
#>
function New-ArcDeployment {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [hashtable]$ConfigurationParams,
        [Parameter()]
        [switch]$DeployAMA,
        [Parameter()]
        [switch]$Force
    )

    begin {
        if (-not $script:DefaultConfig) {
            throw "Module not initialized. Please run Initialize-ArcDeployment first."
        }

        $deploymentParams = @{
            ServerName = $ServerName
            ConfigurationParams = $ConfigurationParams
            Force = $Force
        }

        if ($DeployAMA) {
            if (-not $script:DefaultConfig.DefaultWorkspaceId -or -not $script:DefaultConfig.DefaultWorkspaceKey) {
                throw "Workspace credentials required for AMA deployment. Please initialize with workspace details."
            }
            $deploymentParams['WorkspaceId'] = $script:DefaultConfig.DefaultWorkspaceId
            $deploymentParams['WorkspaceKey'] = $script:DefaultConfig.DefaultWorkspaceKey
            $deploymentParams['DeployAMA'] = $true
        }
    }

    process {
        try {
            if ($PSCmdlet.ShouldProcess($ServerName, "Deploy Azure Arc $(if ($DeployAMA) {'and AMA'})")) {
                # Start deployment
                if ($script:DeployArcAgentOverride) {
                    $result = & $script:DeployArcAgentOverride @deploymentParams
                }
                elseif (Test-Path 'Function:global:Deploy-ArcAgent') {
                    $result = & 'global:Deploy-ArcAgent' @deploymentParams
                }
                else {
                    $deployArcAgentCommand = Get-Command -Name 'Deploy-ArcAgent' -ErrorAction SilentlyContinue
                }

                if (-not $result -and $deployArcAgentCommand) {
                    $result = & $deployArcAgentCommand @deploymentParams
                }
                elseif (-not $result) {
                    $result = Deploy-ArcAgent @deploymentParams
                }

                # Validate deployment
                if ($result.Status -eq "Success") {
                    if ($script:TestDeploymentHealthOverride) {
                        $validation = & $script:TestDeploymentHealthOverride -ServerName $ServerName -ValidateAMA:$DeployAMA
                    }
                    elseif (Test-Path 'Function:global:Test-DeploymentHealth') {
                        $validation = & 'global:Test-DeploymentHealth' -ServerName $ServerName -ValidateAMA:$DeployAMA
                    }
                    else {
                        $testDeploymentHealthCommand = Get-Command -Name 'Test-DeploymentHealth' -ErrorAction SilentlyContinue
                    }

                    if (-not $validation -and $testDeploymentHealthCommand) {
                        $validation = & $testDeploymentHealthCommand -ServerName $ServerName -ValidateAMA:$DeployAMA
                    }
                    elseif (-not $validation) {
                        $validation = Test-DeploymentHealth -ServerName $ServerName -ValidateAMA:$DeployAMA
                    }
                    $result.Validation = $validation
                }

                return $result
            }
        }
        catch {
            Write-Error "Deployment failed: $_"
            throw
        }
    }
}

<#
.SYNOPSIS
Starts the framework troubleshooting workflow for a server.

.DESCRIPTION
Builds the troubleshooting request from module defaults and caller switches,
adds AMA workspace context when requested, and dispatches the troubleshooting
workflow for the specified server.

.PARAMETER ServerName
Target server to troubleshoot.

.PARAMETER IncludeAMA
Includes AMA-specific troubleshooting by supplying the configured workspace ID.

.PARAMETER DetailedAnalysis
Requests deeper troubleshooting analysis when supported by the workflow.

.PARAMETER AutoRemediate
Allows the troubleshooting workflow to run automated remediation steps.
#>
function Start-ArcTroubleshooting {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [switch]$IncludeAMA,
        [Parameter()]
        [switch]$DetailedAnalysis,
        [Parameter()]
        [switch]$AutoRemediate
    )

    try {
        $params = @{
            ServerName = $ServerName
            DetailedAnalysis = $DetailedAnalysis
            AutoRemediate = $AutoRemediate
        }

        if ($IncludeAMA) {
            if (-not $script:DefaultConfig.DefaultWorkspaceId) {
                throw "Workspace ID required for AMA troubleshooting"
            }
            $params['WorkspaceId'] = $script:DefaultConfig.DefaultWorkspaceId
        }

        if (-not $PSCmdlet.ShouldProcess($ServerName, "Start Arc troubleshooting workflow")) {
            return $null
        }

        return Start-ArcTroubleshooter @params
    }
    catch {
        Write-Error "Troubleshooting failed: $_"
        throw
    }
}

# Helper Functions
function Initialize-Logging {
    $finalLogBasePath = $null

    # 1. Check LogPathOverride in config
    if (-not [string]::IsNullOrEmpty($script:DefaultConfig.LogPathOverride)) {
        $finalLogBasePath = $script:DefaultConfig.LogPathOverride
        Write-Verbose "Using LogPathOverride: $finalLogBasePath"
    }
    # 2. Check Environment Variable
    elseif ($env:AZUREARC_FRAMEWORK_LOG_PATH) { # Check if variable exists and is not empty
        $finalLogBasePath = $env:AZUREARC_FRAMEWORK_LOG_PATH
        Write-Verbose "Using environment variable AZUREARC_FRAMEWORK_LOG_PATH: $finalLogBasePath"
    }
    # 3. Default to Temp Path
    else {
        $tempDir = [System.IO.Path]::GetTempPath()
        $finalLogBasePath = Join-Path $tempDir "AzureArcFrameworkLogs"
        Write-Verbose "Using default temp log path: $finalLogBasePath"
    }

    # Ensure the base log directory exists
    if (-not (Test-Path $finalLogBasePath)) {
        try {
            New-Item -Path $finalLogBasePath -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Error "Failed to create log directory at $finalLogBasePath. Error: $_"
            # Fallback to a script-relative path as a last resort, or throw
            $fallbackLogPath = Join-Path $PSScriptRoot "../../Logs_Fallback" # Different from original
            Write-Warning "Falling back to log path: $fallbackLogPath"
            $finalLogBasePath = $fallbackLogPath
            if (-not (Test-Path $finalLogBasePath)) {
                 New-Item -Path $finalLogBasePath -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
            }
        }
    }

    # Set global variables for Write-Log to use
    $global:AzureArcFramework_LogPath = Join-Path $finalLogBasePath "ArcDeployment.log"
    $global:AzureArcFramework_LogLevel = $script:DefaultConfig.LogLevel

    # Optional: Confirmation message
    Write-Information "Logging initialized. Path: $($global:AzureArcFramework_LogPath), Level: $($global:AzureArcFramework_LogLevel)" -InformationAction Continue
}

# Export module members
Export-ModuleMember -Function @(
    'Initialize-ArcDeployment',
    'New-ArcDeployment',
    'Start-ArcTroubleshooting',
    'Test-ArcPrerequisites',
    'Deploy-ArcAgent',
    'Start-ArcDiagnostics',
    'Invoke-ArcAnalysis',
    'Start-ArcRemediation',
    'Test-DeploymentHealth',
    'Start-AIEnhancedTroubleshooting',
    'Invoke-AIPatternAnalysis',
    'Get-PredictiveInsights',
    'Write-Log',
    'New-RetryBlock',
    'Convert-ErrorToObject',
    'Test-Connectivity',
    'Merge-CommonHashtable'
)
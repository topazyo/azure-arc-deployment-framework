#Requires -Version 5.1
#Requires -Modules Az.ConnectedMachine, Az.Accounts, Az.Monitor

# Module Variables
$script:ModuleRoot = $PSScriptRoot
$script:ConfigPath = Join-Path $PSScriptRoot "Config"
$script:LogPath = Join-Path $PSScriptRoot "Logs"

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
            Write-Warning "Configuration file not found: $file"
        }
    }
}
catch {
    Write-Error "Failed to load configuration: $_"
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
    $folderPath = Join-Path $PSScriptRoot $folder
    if (Test-Path $folderPath) {
        $functions = Get-ChildItem -Path $folderPath -Filter "*.ps1"
        foreach ($function in $functions) {
            try {
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

# Module Functions
function Initialize-ArcDeployment {
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]$WorkspaceId,
        [Parameter()]
        [string]$WorkspaceKey,
        [Parameter()]
        [hashtable]$CustomConfig
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
            $script:DefaultConfig = Merge-Hashtables $script:DefaultConfig $CustomConfig
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
                $result = Deploy-ArcAgent @deploymentParams

                # Validate deployment
                if ($result.Status -eq "Success") {
                    $validation = Test-DeploymentHealth -ServerName $ServerName -ValidateAMA:$DeployAMA
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

function Start-ArcTroubleshooting {
    [CmdletBinding()]
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

        return Start-ArcTroubleshooter @params
    }
    catch {
        Write-Error "Troubleshooting failed: $_"
        throw
    }
}

# Helper Functions
function Initialize-Logging {
    if (-not (Test-Path $script:LogPath)) {
        New-Item -Path $script:LogPath -ItemType Directory -Force | Out-Null
    }

    # Set up logging configuration
    $logConfig = @{
        Path = Join-Path $script:LogPath "ArcDeployment.log"
        Level = $script:DefaultConfig.LogLevel
        Format = "{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}"
    }

    $script:LogConfig = $logConfig
}

function Merge-Hashtables {
    param (
        [hashtable]$Original,
        [hashtable]$Update
    )

    $result = $Original.Clone()
    foreach ($key in $Update.Keys) {
        $result[$key] = $Update[$key]
    }
    return $result
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
    'Test-DeploymentHealth'
)
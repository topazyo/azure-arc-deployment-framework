# AzureArcFramework.psm1
# Root module for the Azure Arc Deployment Framework.
# Keep module import lightweight: avoid hard dependencies on Az.* at import time.

Set-StrictMode -Version Latest

$script:ModuleRoot = $PSScriptRoot
$script:ConfigPath = Join-Path $PSScriptRoot '..\config'

# Load configuration files (best-effort; only ai_config.json is treated as critical by existing tooling).
$script:Config = @{}
try {
    $configFiles = @(
        'server_inventory.json',
        'ai_config.json',
        'validation_matrix.json',
        'dcr-templates.json'
    )

    foreach ($file in $configFiles) {
        $filePath = Join-Path $script:ConfigPath $file
        if (Test-Path $filePath) {
            $script:Config[$file.Replace('.json','')] = Get-Content $filePath -Raw | ConvertFrom-Json
        }
        elseif ($file -eq 'ai_config.json') {
            Write-Error "Critical configuration file not found: $file at $filePath"
            throw "Critical configuration file ai_config.json not found."
        }
        else {
            Write-Warning "Configuration file not found: $file at $filePath"
        }
    }
}
catch {
    Write-Error "Failed to load configuration: $($_.Exception.Message)"
    throw
}

# Import utilities first (logging, retry helpers, etc.)
$utilsPath = Join-Path $script:ModuleRoot 'utils'
Get-ChildItem -Path $utilsPath -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        . $_.FullName
    }
    catch {
        Write-Error "Failed to import script '$($_.FullName)': $($_.Exception.Message)"
        throw
    }
}

# Import core cmdlets
$corePath = Join-Path $script:ModuleRoot 'core'
Get-ChildItem -Path $corePath -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        . $_.FullName
    }
    catch {
        Write-Error "Failed to import script '$($_.FullName)': $($_.Exception.Message)"
        throw
    }
}

# Import AI cmdlets (if present)
$aiPath = Join-Path $script:ModuleRoot 'AI'
Get-ChildItem -Path $aiPath -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object {
    try {
        . $_.FullName
    }
    catch {
        Write-Error "Failed to import script '$($_.FullName)': $($_.Exception.Message)"
        throw
    }
}

# Import specific monitoring functions used by core cmdlets (avoid dot-sourcing monitoring scripts with param blocks)
foreach ($relative in @('Install-AMAExtension.ps1', 'Set-DataCollectionRules.ps1')) {
    $candidate = Join-Path (Join-Path $script:ModuleRoot 'monitoring') $relative
    if (Test-Path -LiteralPath $candidate) {
        try {
            . $candidate
        }
        catch {
            Write-Error "Failed to import script '$candidate': $($_.Exception.Message)"
            throw
        }
    }
}

# Provide minimal internal helpers so unit tests can Mock them reliably.
if (-not (Get-Command -Name 'Backup-ArcConfiguration' -ErrorAction SilentlyContinue)) {
    function Backup-ArcConfiguration {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName
        )

        throw 'Backup-ArcConfiguration is not implemented.'
    }
}

if (-not (Get-Command -Name 'Restore-ArcConfiguration' -ErrorAction SilentlyContinue)) {
    function Restore-ArcConfiguration {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName,
            [Parameter(Mandatory)]
            [hashtable]$Backup
        )

        throw 'Restore-ArcConfiguration is not implemented.'
    }
}

if (-not (Get-Command -Name 'Install-ArcAgentInternal' -ErrorAction SilentlyContinue)) {
    function Install-ArcAgentInternal {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName,
            [Parameter()]
            [hashtable]$Config
        )

        throw 'Install-ArcAgentInternal is not implemented.'
    }
}

if (-not (Get-Command -Name 'Get-SystemState' -ErrorAction SilentlyContinue)) {
    function Get-SystemState {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName
        )

        throw 'Get-SystemState is not implemented.'
    }
}

if (-not (Get-Command -Name 'Get-ArcAgentConfig' -ErrorAction SilentlyContinue)) {
    function Get-ArcAgentConfig {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName
        )

        throw 'Get-ArcAgentConfig is not implemented.'
    }
}

if (-not (Get-Command -Name 'Get-LastHeartbeat' -ErrorAction SilentlyContinue)) {
    function Get-LastHeartbeat {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName
        )

        throw 'Get-LastHeartbeat is not implemented.'
    }
}

if (-not (Get-Command -Name 'Get-AMAConfig' -ErrorAction SilentlyContinue)) {
    function Get-AMAConfig {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName
        )

        throw 'Get-AMAConfig is not implemented.'
    }
}

if (-not (Get-Command -Name 'Get-DataCollectionStatus' -ErrorAction SilentlyContinue)) {
    function Get-DataCollectionStatus {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName,
            [Parameter(Mandatory)]
            [string]$WorkspaceId
        )

        throw 'Get-DataCollectionStatus is not implemented.'
    }
}

if (-not (Get-Command -Name 'Test-ArcConnectivity' -ErrorAction SilentlyContinue)) {
    function Test-ArcConnectivity {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName
        )

        throw 'Test-ArcConnectivity is not implemented.'
    }
}

if (-not (Get-Command -Name 'Test-NetworkPaths' -ErrorAction SilentlyContinue)) {
    function Test-NetworkPaths {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName
        )

        throw 'Test-NetworkPaths is not implemented.'
    }
}

if (-not (Get-Command -Name 'Test-OSCompatibility' -ErrorAction SilentlyContinue)) {
    function Test-OSCompatibility {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$OSVersion
        )

        throw 'Test-OSCompatibility is not implemented.'
    }
}

if (-not (Get-Command -Name 'Test-TLSConfiguration' -ErrorAction SilentlyContinue)) {
    function Test-TLSConfiguration {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName
        )

        throw 'Test-TLSConfiguration is not implemented.'
    }
}

if (-not (Get-Command -Name 'Test-LAWorkspace' -ErrorAction SilentlyContinue)) {
    function Test-LAWorkspace {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$WorkspaceId
        )

        throw 'Test-LAWorkspace is not implemented.'
    }
}

if (-not (Get-Command -Name 'Test-AMAConnectivity' -ErrorAction SilentlyContinue)) {
    function Test-AMAConnectivity {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName
        )

        throw 'Test-AMAConnectivity is not implemented.'
    }
}

if (-not (Get-Command -Name 'Get-ProxyConfiguration' -ErrorAction SilentlyContinue)) {
    function Get-ProxyConfiguration {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName
        )

        throw 'Get-ProxyConfiguration is not implemented.'
    }
}

if (-not (Get-Command -Name 'Get-ArcAgentLogs' -ErrorAction SilentlyContinue)) {
    function Get-ArcAgentLogs {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName
        )

        throw 'Get-ArcAgentLogs is not implemented.'
    }
}

if (-not (Get-Command -Name 'Get-AMALogs' -ErrorAction SilentlyContinue)) {
    function Get-AMALogs {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName
        )

        throw 'Get-AMALogs is not implemented.'
    }
}

if (-not (Get-Command -Name 'Get-SystemLogs' -ErrorAction SilentlyContinue)) {
    function Get-SystemLogs {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName,
            [Parameter()]
            [int]$LastHours
        )

        throw 'Get-SystemLogs is not implemented.'
    }
}

if (-not (Get-Command -Name 'Get-SecurityLogs' -ErrorAction SilentlyContinue)) {
    function Get-SecurityLogs {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName,
            [Parameter()]
            [int]$LastHours
        )

        throw 'Get-SecurityLogs is not implemented.'
    }
}

if (-not (Get-Command -Name 'Get-DCRAssociationStatus' -ErrorAction SilentlyContinue)) {
    function Get-DCRAssociationStatus {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName
        )

        throw 'Get-DCRAssociationStatus is not implemented.'
    }
}

if (-not (Get-Command -Name 'Test-CertificateTrust' -ErrorAction SilentlyContinue)) {
    function Test-CertificateTrust {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName
        )

        throw 'Test-CertificateTrust is not implemented.'
    }
}

if (-not (Get-Command -Name 'Get-DetailedProxyConfig' -ErrorAction SilentlyContinue)) {
    function Get-DetailedProxyConfig {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName
        )

        throw 'Get-DetailedProxyConfig is not implemented.'
    }
}

if (-not (Get-Command -Name 'Get-FirewallConfiguration' -ErrorAction SilentlyContinue)) {
    function Get-FirewallConfiguration {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName
        )

        throw 'Get-FirewallConfiguration is not implemented.'
    }
}

if (-not (Get-Command -Name 'Get-PerformanceMetrics' -ErrorAction SilentlyContinue)) {
    function Get-PerformanceMetrics {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName
        )

        throw 'Get-PerformanceMetrics is not implemented.'
    }
}

if (-not (Get-Command -Name 'Test-SecurityBaseline' -ErrorAction SilentlyContinue)) {
    function Test-SecurityBaseline {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)]
            [string]$ServerName
        )

        throw 'Test-SecurityBaseline is not implemented.'
    }
}

# Exported members are governed by the module manifest (AzureArcFramework.psd1)

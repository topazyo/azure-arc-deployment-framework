[CmdletBinding()]
param (
    [Parameter()]
    [string]$WorkingDirectory = $PSScriptRoot,
    [Parameter()]
    [switch]$CreateVirtualEnv,
    [Parameter()]
    [switch]$InstallDependencies,
    [Parameter()]
    [switch]$Force
)

function Resolve-RepositoryRoot {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Path
    )

    $candidate = $Path
    try {
        $resolved = Resolve-Path -Path $candidate -ErrorAction Stop
        $candidate = $resolved.Path
    }
    catch {
        $candidate = [System.IO.Path]::GetFullPath($candidate)
    }

    if (Test-Path $candidate -PathType Leaf) {
        $candidate = Split-Path -Path $candidate -Parent
    }

    while (-not [string]::IsNullOrWhiteSpace($candidate)) {
        if (Test-Path (Join-Path $candidate "setup.py") -PathType Leaf) {
            return $candidate
        }

        $parent = Split-Path -Path $candidate -Parent
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $candidate) {
            break
        }

        $candidate = $parent
    }

    throw "Invalid working directory. Could not locate repository root from '$Path'."
}

function Get-VirtualEnvironmentPythonPath {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$VirtualEnvironmentPath
    )

    $candidates = @(
        (Join-Path $VirtualEnvironmentPath "Scripts\python.exe"),
        (Join-Path $VirtualEnvironmentPath "Scripts\python"),
        (Join-Path $VirtualEnvironmentPath "bin\python")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw "Virtual environment Python executable was not found under '$VirtualEnvironmentPath'."
}

function Set-ManagedProfileBlock {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ProfilePath,
        [Parameter(Mandatory)]
        [string]$WorkingDirectory
    )

    $profileDirectory = Split-Path -Path $ProfilePath -Parent
    if (-not (Test-Path $profileDirectory -PathType Container)) {
        New-Item -Path $profileDirectory -ItemType Directory -Force | Out-Null
    }

    if (-not (Test-Path $ProfilePath -PathType Leaf)) {
        New-Item -Path $ProfilePath -ItemType File -Force | Out-Null
    }

    $startMarker = '# >>> Azure Arc Framework Development Profile >>>'
    $endMarker = '# <<< Azure Arc Framework Development Profile <<<'
    $moduleManifestPath = Join-Path $WorkingDirectory 'src\PowerShell\AzureArcFramework.psd1'
    $moduleRootPath = Join-Path $WorkingDirectory 'src\PowerShell'

    $managedBlock = @"
$startMarker
`$env:ArcDevRoot = '$WorkingDirectory'
if (`$env:PSModulePath -notlike '$moduleRootPath*') {
    `$env:PSModulePath = '$moduleRootPath$([System.IO.Path]::PathSeparator)' + `$env:PSModulePath
}
Import-Module '$moduleManifestPath' -Force
$endMarker
"@

    $existingContent = Get-Content -Path $ProfilePath -Raw -ErrorAction SilentlyContinue
    if ($null -eq $existingContent) {
        $existingContent = ''
    }

    $pattern = "(?s)$([regex]::Escape($startMarker)).*?$([regex]::Escape($endMarker))"
    if ($existingContent -match $pattern) {
        $updatedContent = [regex]::Replace($existingContent, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $managedBlock })
    }
    elseif ([string]::IsNullOrWhiteSpace($existingContent)) {
        $updatedContent = $managedBlock
    }
    else {
        $updatedContent = $existingContent.TrimEnd("`r", "`n") + "`r`n`r`n" + $managedBlock
    }

    Set-Content -Path $ProfilePath -Value $updatedContent -Encoding UTF8
}

function Initialize-PythonEnvironment {
    [CmdletBinding()]
    param (
        [string]$WorkingDirectory,
        [switch]$Force
    )

    try {
        Write-Information "Initializing Python environment..."
        
        # Check Python installation
        $pythonVersion = python --version 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Python is not installed or not in PATH"
        }
        Write-Information "Found Python: $pythonVersion"

        # Create virtual environment
        $venvPath = Join-Path $WorkingDirectory "venv"
        if (Test-Path $venvPath) {
            if ($Force) {
                Remove-Item $venvPath -Recurse -Force
                Write-Warning "Removed existing virtual environment"
            }
            else {
                Write-Warning "Virtual environment already exists"
                return
            }
        }

        python -m venv $venvPath
        if ($LASTEXITCODE -ne 0) { throw "python -m venv failed with exit code $LASTEXITCODE" }
        Write-Information "Created virtual environment at: $venvPath"

        $venvPython = Get-VirtualEnvironmentPythonPath -VirtualEnvironmentPath $venvPath
        Write-Information "Using virtual environment interpreter at: $venvPython"

        # Install dependencies
        & $venvPython -m pip install -r (Join-Path $WorkingDirectory "requirements.txt")
        if ($LASTEXITCODE -ne 0) { throw "pip install requirements.txt failed with exit code $LASTEXITCODE" }
        & $venvPython -m pip install -e $WorkingDirectory
        if ($LASTEXITCODE -ne 0) { throw "pip install -e failed with exit code $LASTEXITCODE" }
        Write-Information "Installed Python dependencies"
    }
    catch {
        Write-Error "Failed to initialize Python environment: $_"
        throw
    }
}

function Initialize-PowerShellEnvironment {
    [CmdletBinding()]
    param (
        [string]$WorkingDirectory
    )

    try {
        Write-Information "Initializing PowerShell environment..."

        # Install required PowerShell modules
        $modules = @(
            @{Name = 'Pester'; MinimumVersion = '5.3.0'},
            @{Name = 'PSScriptAnalyzer'; MinimumVersion = '1.20.0'},
            @{Name = 'platyPS'; MinimumVersion = '0.14.2'},
            @{Name = 'Az.Accounts'; MinimumVersion = '2.7.0'},
            @{Name = 'Az.ConnectedMachine'; MinimumVersion = '0.4.0'},
            @{Name = 'Az.Monitor'; MinimumVersion = '3.0.0'}
        )

        foreach ($module in $modules) {
            if (-not (Get-Module -ListAvailable -Name $module.Name -MinimumVersion $module.MinimumVersion)) {
                Write-Information "Installing module: $($module.Name)"
                Install-Module -Name $module.Name -MinimumVersion $module.MinimumVersion -Force -AllowClobber
            }
            else {
                Write-Verbose "Module already installed: $($module.Name)"
            }
        }

        $profilePath = $PROFILE.CurrentUserAllHosts
        Set-ManagedProfileBlock -ProfilePath $profilePath -WorkingDirectory $WorkingDirectory
        Write-Information "Updated PowerShell profile"
    }
    catch {
        Write-Error "Failed to initialize PowerShell environment: $_"
        throw
    }
}

function Initialize-GitHooks {
    [CmdletBinding()]
    param (
        [string]$WorkingDirectory
    )

    try {
        Write-Information "Initializing Git hooks..."
        
        $hooksDir = Join-Path $WorkingDirectory ".git\hooks"
        if (-not (Test-Path $hooksDir)) {
            New-Item -Path $hooksDir -ItemType Directory -Force | Out-Null
        }

        # Create pre-commit hook
        $preCommitPath = Join-Path $hooksDir "pre-commit"
        $preCommitPowerShellPath = Join-Path $hooksDir "pre-commit.ps1"

        @'
param(
    [Parameter(Mandatory)]
    [string]$RepositoryRoot
)

$ErrorActionPreference = 'Stop'
$resolvedRoot = (Resolve-Path -Path $RepositoryRoot).Path
Set-Location $resolvedRoot

Write-Host 'Running PowerShell tests...'
Invoke-Pester -Path './tests/PowerShell' -CI | Out-Null

Write-Host 'Running Python tests...'
python -m pytest tests/Python
if ($LASTEXITCODE -ne 0) {
    throw "Python tests failed with exit code $LASTEXITCODE"
}

Write-Host 'Running PSScriptAnalyzer...'
$findings = Invoke-ScriptAnalyzer -Path './src/PowerShell' -Recurse
if ($findings) {
    $findings | Format-Table Severity, RuleName, ScriptName, Line, Message -AutoSize | Out-String | Write-Host
    throw 'PSScriptAnalyzer found issues'
}

Write-Host 'Running Python linting...'
python -m flake8 src/Python
if ($LASTEXITCODE -ne 0) {
    throw "Python linting failed with exit code $LASTEXITCODE"
}
'@ | Set-Content $preCommitPowerShellPath -Encoding UTF8

        @'
#!/bin/sh
set -eu

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "${repo_root:-}" ]; then
    repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
fi

pwsh -NoProfile -File "$repo_root/.git/hooks/pre-commit.ps1" -RepositoryRoot "$repo_root"
'@ | Set-Content $preCommitPath -Encoding UTF8

        # Make hook executable
        if ($IsLinux -or $IsMacOS) {
            chmod +x $preCommitPath
        }

        Write-Information "Git hooks initialized"
    }
    catch {
        Write-Error "Failed to initialize Git hooks: $_"
        throw
    }
}

try {
    $WorkingDirectory = Resolve-RepositoryRoot -Path $WorkingDirectory

    # Validate working directory
    if (-not (Test-Path (Join-Path $WorkingDirectory "setup.py"))) {
        throw "Invalid working directory. Please run from repository root."
    }

    # Initialize Python environment
    if ($CreateVirtualEnv) {
        Initialize-PythonEnvironment -WorkingDirectory $WorkingDirectory -Force:$Force
    }

    # Initialize PowerShell environment
    if ($InstallDependencies) {
        Initialize-PowerShellEnvironment -WorkingDirectory $WorkingDirectory
    }

    # Initialize Git hooks
    Initialize-GitHooks -WorkingDirectory $WorkingDirectory

    Write-Information "Development environment initialized successfully"
}
catch {
    Write-Error "Failed to initialize development environment: $_"
    exit 1
}
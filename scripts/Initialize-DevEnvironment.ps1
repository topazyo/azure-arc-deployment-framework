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

function Initialize-PythonEnvironment {
    [CmdletBinding()]
    param (
        [string]$WorkingDirectory,
        [switch]$Force
    )

    try {
        Write-Host "Initializing Python environment..." -ForegroundColor Cyan
        
        # Check Python installation
        $pythonVersion = python --version 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "Python is not installed or not in PATH"
        }
        Write-Host "Found Python: $pythonVersion" -ForegroundColor Green

        # Create virtual environment
        $venvPath = Join-Path $WorkingDirectory "venv"
        if (Test-Path $venvPath) {
            if ($Force) {
                Remove-Item $venvPath -Recurse -Force
                Write-Host "Removed existing virtual environment" -ForegroundColor Yellow
            }
            else {
                Write-Host "Virtual environment already exists" -ForegroundColor Yellow
                return
            }
        }

        python -m venv $venvPath
        Write-Host "Created virtual environment at: $venvPath" -ForegroundColor Green

        # Activate virtual environment
        $activateScript = Join-Path $venvPath "Scripts\Activate.ps1"
        . $activateScript
        Write-Host "Activated virtual environment" -ForegroundColor Green

        # Install dependencies
        pip install -r (Join-Path $WorkingDirectory "requirements.txt")
        pip install -e $WorkingDirectory
        Write-Host "Installed Python dependencies" -ForegroundColor Green
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
        Write-Host "Initializing PowerShell environment..." -ForegroundColor Cyan

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
                Write-Host "Installing module: $($module.Name)" -ForegroundColor Yellow
                Install-Module -Name $module.Name -MinimumVersion $module.MinimumVersion -Force -AllowClobber
            }
            else {
                Write-Host "Module already installed: $($module.Name)" -ForegroundColor Green
            }
        }

        # Set up PowerShell profile for development
        $profileContent = @'
# Azure Arc Framework Development Profile
$env:ArcDevRoot = '{0}'
$env:PSModulePath = "{0}\src\PowerShell;$env:PSModulePath"
Import-Module AzureArcFramework -Force
'@ -f $WorkingDirectory

        $profilePath = $PROFILE.CurrentUserAllHosts
        if (-not (Test-Path $profilePath)) {
            New-Item -Path $profilePath -ItemType File -Force | Out-Null
        }
        Add-Content -Path $profilePath -Value $profileContent
        Write-Host "Updated PowerShell profile" -ForegroundColor Green
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
        Write-Host "Initializing Git hooks..." -ForegroundColor Cyan
        
        $hooksDir = Join-Path $WorkingDirectory ".git\hooks"
        if (-not (Test-Path $hooksDir)) {
            New-Item -Path $hooksDir -ItemType Directory -Force | Out-Null
        }

        # Create pre-commit hook
        $preCommitPath = Join-Path $hooksDir "pre-commit"
        @'
#!/bin/sh
# Run PowerShell tests
pwsh -Command "Invoke-Pester -Path ./tests/PowerShell -CI"
if [ $? -ne 0 ]; then
    echo "PowerShell tests failed"
    exit 1
fi

# Run Python tests
python -m pytest tests/Python
if [ $? -ne 0 ]; then
    echo "Python tests failed"
    exit 1
fi

# Run PSScriptAnalyzer
pwsh -Command "Invoke-ScriptAnalyzer -Path ./src/PowerShell -Recurse"
if [ $? -ne 0 ]; then
    echo "PSScriptAnalyzer found issues"
    exit 1
fi

# Run Python linting
python -m flake8 src/Python
if [ $? -ne 0 ]; then
    echo "Python linting failed"
    exit 1
fi
'@ | Set-Content $preCommitPath -Encoding UTF8

        # Make hook executable
        if ($IsLinux -or $IsMacOS) {
            chmod +x $preCommitPath
        }

        Write-Host "Git hooks initialized" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to initialize Git hooks: $_"
        throw
    }
}

try {
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

    Write-Host "Development environment initialized successfully" -ForegroundColor Green
}
catch {
    Write-Error "Failed to initialize development environment: $_"
    exit 1
}
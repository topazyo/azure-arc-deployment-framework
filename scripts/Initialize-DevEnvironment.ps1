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

        # Activate virtual environment
        $activateScript = Join-Path $venvPath "Scripts\Activate.ps1"
        . $activateScript
        Write-Information "Activated virtual environment"

        # Install dependencies
        pip install -r (Join-Path $WorkingDirectory "requirements.txt")
        if ($LASTEXITCODE -ne 0) { throw "pip install requirements.txt failed with exit code $LASTEXITCODE" }
        pip install -e $WorkingDirectory
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

        Write-Information "Git hooks initialized"
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

    Write-Information "Development environment initialized successfully"
}
catch {
    Write-Error "Failed to initialize development environment: $_"
    exit 1
}
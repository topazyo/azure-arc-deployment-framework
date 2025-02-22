[CmdletBinding()]
param (
    [Parameter()]
    [switch]$Dev,
    [Parameter()]
    [switch]$Force,
    [Parameter()]
    [string]$InstallPath = "$env:ProgramFiles\WindowsPowerShell\Modules\AzureArcFramework"
)

function Install-Dependencies {
    param (
        [switch]$Dev
    )

    Write-Host "Installing required PowerShell modules..."
    $modules = @(
        @{Name = 'Az.Accounts'; Version = '2.7.0'},
        @{Name = 'Az.ConnectedMachine'; Version = '0.4.0'},
        @{Name = 'Az.Monitor'; Version = '3.0.0'}
    )

    foreach ($module in $modules) {
        if (-not (Get-Module -ListAvailable -Name $module.Name)) {
            Install-Module -Name $module.Name -RequiredVersion $module.Version -Force
        }
    }

    if ($Dev) {
        Write-Host "Installing development dependencies..."
        $devModules = @(
            'Pester',
            'PSScriptAnalyzer',
            'platyPS'
        )
        foreach ($module in $devModules) {
            if (-not (Get-Module -ListAvailable -Name $module)) {
                Install-Module -Name $module -Force
            }
        }
    }
}

function Install-PythonComponents {
    param (
        [switch]$Dev
    )

    Write-Host "Installing Python components..."
    $pythonCmd = if ($Dev) { "pip install -e .[dev]" } else { "pip install ." }
    
    try {
        Push-Location $PSScriptRoot
        Invoke-Expression $pythonCmd
    }
    finally {
        Pop-Location
    }
}

function Install-PowerShellModule {
    param (
        [string]$InstallPath,
        [switch]$Force
    )

    Write-Host "Installing PowerShell module..."
    
    # Create module directory if it doesn't exist
    if (-not (Test-Path $InstallPath)) {
        New-Item -Path $InstallPath -ItemType Directory -Force | Out-Null
    }
    elseif ($Force) {
        Remove-Item -Path $InstallPath\* -Recurse -Force
    }
    else {
        throw "Module directory already exists. Use -Force to overwrite."
    }

    # Copy module files
    Copy-Item -Path "$PSScriptRoot\src\PowerShell\*" -Destination $InstallPath -Recurse
    
    # Copy configuration files
    Copy-Item -Path "$PSScriptRoot\src\Config" -Destination $InstallPath -Recurse

    # Update PSModulePath if needed
    $modulePath = [Environment]::GetEnvironmentVariable("PSModulePath", "Machine")
    $installPathParent = Split-Path $InstallPath -Parent
    if ($modulePath -notlike "*$installPathParent*") {
        [Environment]::SetEnvironmentVariable(
            "PSModulePath",
            "$modulePath;$installPathParent",
            "Machine"
        )
    }
}

function Test-Installation {
    Write-Host "Testing installation..."
    
    # Test PowerShell module
    if (Get-Module -ListAvailable -Name AzureArcFramework) {
        Write-Host "PowerShell module installed successfully" -ForegroundColor Green
    }
    else {
        Write-Error "PowerShell module installation failed"
    }

    # Test Python package
    try {
        python -c "import azure_arc_framework"
        Write-Host "Python package installed successfully" -ForegroundColor Green
    }
    catch {
        Write-Error "Python package installation failed"
    }
}

try {
    # Install dependencies
    Install-Dependencies -Dev:$Dev

    # Install Python components
    Install-PythonComponents -Dev:$Dev

    # Install PowerShell module
    Install-PowerShellModule -InstallPath $InstallPath -Force:$Force

    # Test installation
    Test-Installation

    Write-Host "Installation completed successfully" -ForegroundColor Green
}
catch {
    Write-Error "Installation failed: $_"
    exit 1
}
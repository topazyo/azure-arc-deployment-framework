[CmdletBinding()]
param (
    [Parameter()]
    [switch]$RemoveData,
    [Parameter()]
    [string]$InstallPath = "$env:ProgramFiles\WindowsPowerShell\Modules\AzureArcFramework"
)

function Remove-PowerShellModule {
    Write-Host "Removing PowerShell module..."
    
    if (Test-Path $InstallPath) {
        Remove-Item -Path $InstallPath -Recurse -Force
        Write-Host "PowerShell module removed successfully" -ForegroundColor Green
    }
    else {
        Write-Warning "PowerShell module not found at $InstallPath"
    }
}

function Remove-PythonPackage {
    Write-Host "Removing Python package..."
    
    try {
        pip uninstall azure-arc-framework -y
        Write-Host "Python package removed successfully" -ForegroundColor Green
    }
    catch {
        Write-Warning "Failed to remove Python package: $_"
    }
}

function Remove-ConfigurationData {
    Write-Host "Removing configuration data..."
    
    $configPaths = @(
        "$env:LOCALAPPDATA\AzureArcFramework",
        "$env:ProgramData\AzureArcFramework"
    )

    foreach ($path in $configPaths) {
        if (Test-Path $path) {
            Remove-Item -Path $path -Recurse -Force
            Write-Host "Removed configuration data from $path" -ForegroundColor Green
        }
    }
}

try {
    # Remove PowerShell module
    Remove-PowerShellModule

    # Remove Python package
    Remove-PythonPackage

    # Remove configuration data if requested
    if ($RemoveData) {
        Remove-ConfigurationData
    }

    Write-Host "Uninstallation completed successfully" -ForegroundColor Green
}
catch {
    Write-Error "Uninstallation failed: $_"
    exit 1
}
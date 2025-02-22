[CmdletBinding()]
param (
    [Parameter()]
    [string]$SourcePath = "$PSScriptRoot\..\src",
    [Parameter()]
    [string]$OutputPath = "$PSScriptRoot\..\docs",
    [Parameter()]
    [switch]$GeneratePDF
)

function Build-PowerShellDocs {
    [CmdletBinding()]
    param (
        [string]$ModulePath,
        [string]$OutputPath
    )

    try {
        Write-Host "Generating PowerShell documentation..." -ForegroundColor Cyan

        # Import module
        Import-Module (Join-Path $ModulePath "PowerShell\AzureArcFramework.psd1") -Force

        # Create markdown help
        $docsPath = Join-Path $OutputPath "PowerShell"
        if (-not (Test-Path $docsPath)) {
            New-Item -Path $docsPath -ItemType Directory -Force | Out-Null
        }

        New-MarkdownHelp -Module AzureArcFramework -OutputFolder $docsPath -Force
        Write-Host "Generated PowerShell markdown documentation" -ForegroundColor Green

        # Create external help
        New-ExternalHelp -Path $docsPath -OutputPath (Join-Path $ModulePath "PowerShell\en-US") -Force
        Write-Host "Generated PowerShell external help" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to build PowerShell documentation: $_"
        throw
    }
}

function Build-PythonDocs {
    [CmdletBinding()]
    param (
        [string]$SourcePath,
        [string]$OutputPath
    )

    try {
        Write-Host "Generating Python documentation..." -ForegroundColor Cyan

        # Ensure Sphinx is installed
        pip install sphinx sphinx-rtd-theme

        # Create Sphinx configuration
        $sphinxPath = Join-Path $OutputPath "Python"
        if (-not (Test-Path $sphinxPath)) {
            sphinx-quickstart -q -p "Azure Arc Framework" -a "Your Name" -v "1.0" -r "1.0" -l "en" --ext-autodoc --ext-viewcode --makefile --batchfile $sphinxPath
        }

        # Generate API documentation
        sphinx-apidoc -f -o $sphinxPath (Join-Path $SourcePath "Python")

        # Build HTML documentation
        Push-Location $sphinxPath
        try {
            sphinx-build -b html . _build/html
            Write-Host "Generated Python HTML documentation" -ForegroundColor Green

            if ($GeneratePDF) {
                sphinx-build -b latex . _build/latex
                Push-Location _build/latex
                try {
                    make.bat all-pdf
                    Write-Host "Generated Python PDF documentation" -ForegroundColor Green
                }
                finally {
                    Pop-Location
                }
            }
        }
        finally {
            Pop-Location
        }
    }
    catch {
        Write-Error "Failed to build Python documentation: $_"
        throw
    }
}

function Build-ReadmeDocs {
    [CmdletBinding()]
    param (
        [string]$SourcePath,
        [string]$OutputPath
    )

    try {
        Write-Host "Generating README documentation..." -ForegroundColor Cyan

        # Copy main README
        Copy-Item -Path "$SourcePath\..\README.md" -Destination $OutputPath -Force

        # Generate component READMEs
        $components = @(
            @{Name = "PowerShell"; Path = "PowerShell"},
            @{Name = "Python"; Path = "Python"},
            @{Name = "Configuration"; Path = "Config"}
        )

        foreach ($component in $components) {
            $componentPath = Join-Path $SourcePath $component.Path
            $readmePath = Join-Path $OutputPath "$($component.Name).md"

            # Generate component documentation
            $content = @"
# $($component.Name) Components

## Overview
Documentation for the $($component.Name) components of the Azure Arc Framework.

## Directory Structure
``````
$(Get-ChildItem $componentPath -Recurse | Where-Object { -not $_.PSIsContainer } | ForEach-Object { $_.FullName.Replace($componentPath, '').TrimStart('\') })
``````

## Components
"@

            $content | Set-Content $readmePath -Force
            Write-Host "Generated $($component.Name) README" -ForegroundColor Green
        }
    }
    catch {
        Write-Error "Failed to build README documentation: $_"
        throw
    }
}

try {
    # Validate paths
    if (-not (Test-Path $SourcePath)) {
        throw "Source path not found: $SourcePath"
    }

    if (-not (Test-Path $OutputPath)) {
        New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
    }

    # Build documentation
    Build-PowerShellDocs -ModulePath $SourcePath -OutputPath $OutputPath
    Build-PythonDocs -SourcePath $SourcePath -OutputPath $OutputPath
    Build-ReadmeDocs -SourcePath $SourcePath -OutputPath $OutputPath

    Write-Host "Documentation built successfully" -ForegroundColor Green
}
catch {
    Write-Error "Failed to build documentation: $_"
    exit 1
}
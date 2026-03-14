# Import-AIModel.ps1
# This script imports a pre-trained AI model for use from a specified file path.
# TODO: Enhance ONNX DLL discovery/loading mechanism. Add support for more model types if needed.

Function Import-AIModel {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]$ModelPath,

        [Parameter(Mandatory=$false)]
        [ValidateSet('ONNX', 'PMML', 'PSWorkflow', 'CustomPSObject', 'Auto')]
        [string]$ModelType = 'Auto',

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\ImportAIModel_Activity.log"
    )

    # --- Logging Function (for script activity) ---
    function Write-ActivityLog {
        param (
            [string]$Message,
            [string]$Level = "INFO", # INFO, WARNING, ERROR
            [string]$Path = $LogPath
        )
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$Level] $Message"

        try {
            if (-not (Test-Path (Split-Path $Path -Parent) -PathType Container)) {
                New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force -ErrorAction Stop | Out-Null
            }
            Add-Content -Path $Path -Value $logEntry -ErrorAction Stop
        }
        catch {
            Write-Warning "ACTIVITY_LOG_FAIL: Failed to write to activity log file $Path. Error: $($_.Exception.Message). Logging to console instead."
            Write-Verbose $logEntry
        }
    }

    Write-ActivityLog "Starting Import-AIModel script."
    Write-ActivityLog "Parameters: ModelPath='$ModelPath', ModelType='$ModelType'"

    # --- File Existence Check ---
    if (-not (Test-Path -Path $ModelPath -PathType Leaf)) {
        Write-ActivityLog "Model file not found at path: $ModelPath" -Level "ERROR"
        return $null
    }
    Write-ActivityLog "Model file found at $ModelPath."

    # --- Determine ModelType ---
    $effectiveModelType = $ModelType
    if ($effectiveModelType -eq 'Auto') {
        $extension = [System.IO.Path]::GetExtension($ModelPath).ToLower()
        switch ($extension) {
            '.onnx'    { $effectiveModelType = 'ONNX' }
            '.pmml'    { $effectiveModelType = 'PMML' }
            '.xml'     { $effectiveModelType = 'CustomPSObject' } # Could also be PSWorkflow
            '.ps1xml'  { $effectiveModelType = 'CustomPSObject' } # More specific for Import-CliXml
            default {
                Write-ActivityLog "Could not automatically determine model type from extension '$extension'. Please specify -ModelType." -Level "ERROR"
                return $null
            }
        }
        Write-ActivityLog "Automatically determined ModelType as '$effectiveModelType' based on file extension '$extension'."
    } else {
        Write-ActivityLog "Using specified ModelType: '$effectiveModelType'."
    }

    # --- Loading based on ModelType ---
    $loadedModel = $null
    switch ($effectiveModelType) {
        'ONNX' {
            Write-ActivityLog "Attempting to load ONNX model."
            # Dependency: Microsoft.ML.OnnxRuntime.dll
            # Assumes the DLL is in a location where Add-Type can find it (e.g., GAC, $env:PSModulePath, or specific path)
            # For a module, this might be bundled: e.g., Join-Path $PSScriptRoot 'lib\Microsoft.ML.OnnxRuntime.dll'
            $onnxRuntimeDllPath = Join-Path $PSScriptRoot 'lib\Microsoft.ML.OnnxRuntime.dll' # Placeholder path

            # Check if assembly is already loaded to avoid errors with Add-Type
            $onnxAssembly = [System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'Microsoft.ML.OnnxRuntime' }

            if (-not $onnxAssembly) {
                Write-ActivityLog "Microsoft.ML.OnnxRuntime assembly not found loaded. Attempting to load from: $onnxRuntimeDllPath"
                if (Test-Path $onnxRuntimeDllPath) {
                    try {
                        Add-Type -Path $onnxRuntimeDllPath -ErrorAction Stop
                        Write-ActivityLog "Successfully loaded Microsoft.ML.OnnxRuntime.dll."
                        $onnxAssembly = $true # Mark as loaded for the next check
                    } catch {
                        Write-ActivityLog "Failed to load Microsoft.ML.OnnxRuntime.dll from '$onnxRuntimeDllPath'. Error: $($_.Exception.Message)" -Level "ERROR"
                        Write-ActivityLog "Please ensure the ONNX Runtime DLL is available in the expected location or GAC." -Level "ERROR"
                    }
                } else {
                     Write-ActivityLog "ONNX Runtime DLL not found at expected path: $onnxRuntimeDllPath. Cannot load ONNX model." -Level "ERROR"
                }
            } else {
                 Write-ActivityLog "Microsoft.ML.OnnxRuntime assembly already loaded."
            }

            if ($onnxAssembly) {
                try {
                    # Create an InferenceSession object
                    # Note: Session options can be specified if needed: New-Object Microsoft.ML.OnnxRuntime.SessionOptions
                    Write-ActivityLog "Creating ONNX InferenceSession for model: $ModelPath"
                    $loadedModel = New-Object Microsoft.ML.OnnxRuntime.InferenceSession($ModelPath)
                    Write-ActivityLog "ONNX InferenceSession created successfully."
                } catch {
                    Write-ActivityLog "Failed to create ONNX InferenceSession. Error: $($_.Exception.Message)" -Level "ERROR"
                    $loadedModel = $null
                }
            } else {
                Write-ActivityLog "Cannot proceed with ONNX model loading as ONNX Runtime is not available." -Level "ERROR"
            }
        }
        'PSWorkflow' { # Typically .xml or .ps1xml
            Write-ActivityLog "Attempting to load PowerShell Workflow / Custom Object (Import-CliXml) model."
            try {
                $loadedModel = Import-CliXml -Path $ModelPath -ErrorAction Stop
                if ($loadedModel) {
                    Write-ActivityLog "Model successfully deserialized using Import-CliXml. Type: $($loadedModel.GetType().FullName)"
                } else {
                    Write-ActivityLog "Import-CliXml returned null or empty for path: $ModelPath" -Level "WARNING"
                }
            } catch {
                Write-ActivityLog "Failed to load model using Import-CliXml from '$ModelPath'. Error: $($_.Exception.Message)" -Level "ERROR"
                $loadedModel = $null
            }
        }
        'CustomPSObject' { # Typically .xml or .ps1xml
            Write-ActivityLog "Attempting to load Custom PowerShell Object (Import-CliXml) model."
            try {
                $loadedModel = Import-CliXml -Path $ModelPath -ErrorAction Stop
                 if ($loadedModel) {
                    Write-ActivityLog "Model successfully deserialized using Import-CliXml. Type: $($loadedModel.GetType().FullName)"
                } else {
                    Write-ActivityLog "Import-CliXml returned null or empty for path: $ModelPath" -Level "WARNING"
                }
            } catch {
                Write-ActivityLog "Failed to load model using Import-CliXml from '$ModelPath'. Error: $($_.Exception.Message)" -Level "ERROR"
                $loadedModel = $null
            }
        }
        'PMML' {
            Write-ActivityLog "PMML model type specified. Direct execution of PMML in PowerShell is not natively supported by this script." -Level "WARNING"
            Write-ActivityLog "Consider converting PMML to ONNX or another supported format, or using a dedicated PMML evaluation library/tool." -Level "WARNING"
            $loadedModel = $null
        }
        default {
            Write-ActivityLog "Unsupported or unknown ModelType: '$effectiveModelType'." -Level "ERROR"
            $loadedModel = $null
        }
    }

    if ($loadedModel) {
        Write-ActivityLog "Import-AIModel completed. Model of type '$effectiveModelType' loaded."
    } else {
        Write-ActivityLog "Import-AIModel completed. Failed to load model or model type not supported." -Level "WARNING"
    }

    return $loadedModel
}

function Install-AMAExtension {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter(Mandatory)]
        [string]$WorkspaceId,
        [Parameter(Mandatory)]
        [string]$WorkspaceKey,
        [Parameter()]
        [hashtable]$CollectionRules
    )

    begin {
        Write-Verbose "Starting AMA installation on $ServerName"
        $installState = @{
            ServerName = $ServerName
            StartTime = Get-Date
            Status = "Starting"
            Steps = @()
        }
    }

    process {
        try {
            # Validate prerequisites
            $prereqs = Test-AMAPrerequisites -ServerName $ServerName
            if (-not $prereqs.Success) {
                throw "Prerequisites check failed: $($prereqs.Error)"
            }
            $installState.Steps += @{ Name = "Prerequisites"; Status = "Success" }

            # Install AMA
            $amaParams = @{
                Name = "AzureMonitorAgent"
                ServerName = $ServerName
                Publisher = "Microsoft.Azure.Monitor"
                ExtensionType = "AzureMonitorAgent"
                Settings = @{
                    workspaceId = $WorkspaceId
                    workspaceKey = $WorkspaceKey
                }
            }

            $installation = Set-AzVMExtension @amaParams
            if ($installation.StatusCode -ne "OK") {
                throw "AMA installation failed: $($installation.Error)"
            }
            $installState.Steps += @{ Name = "Installation"; Status = "Success" }

            # Configure data collection rules
            if ($CollectionRules) {
                $dcrResult = Set-DataCollectionRules -ServerName $ServerName -Rules $CollectionRules
                $installState.Steps += @{ 
                    Name = "DCR Configuration"
                    Status = $dcrResult.Success ? "Success" : "Failed"
                    Details = $dcrResult.Details
                }
            }

            # Validate installation
            $validation = Test-AMAInstallation -ServerName $ServerName
            $installState.Steps += @{
                Name = "Validation"
                Status = $validation.Success ? "Success" : "Failed"
                Details = $validation.Details
            }

            $installState.Status = "Success"
            $installState.EndTime = Get-Date
        }
        catch {
            $installState.Status = "Failed"
            $installState.Error = $_.Exception.Message
            Write-Error $_
        }
    }

    end {
        return [PSCustomObject]$installState
    }
}
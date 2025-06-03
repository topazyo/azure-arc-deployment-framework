function New-ArcDeployment {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param (
        [Parameter(Mandatory = $true)]
        [string]$ServerName, # For logging and potentially for future use if script is run remotely

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$Location, # Azure location for the Arc server resource

        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter()]
        [string]$CorrelationId, # For tracking, passed to azcmagent

        [Parameter()]
        [hashtable]$Tags = @{},

        [Parameter()]
        [string]$Cloud = "AzureCloud", # e.g., AzureCloud, AzureUSGovernment

        [Parameter()]
        [string]$ProxyUrl,

        [Parameter()]
        [string]$ProxyBypass, # Comma-separated list of hosts/CIDRs

        [Parameter()]
        [string]$ServicePrincipalAppId, # For service principal onboarding

        [Parameter()]
        [securestring]$ServicePrincipalSecret, # For service principal onboarding

        [Parameter()] # Path to a script that installs the azcmagent
        [string]$AgentInstallationScriptPath,

        [Parameter()] # Arguments for the agent installation script
        [string]$AgentInstallationArguments,

        [Parameter(Mandatory = $false)] # Specify the path to the azcmagent executable
        [string]$AzcmagentPath = "azcmagent" # Default to being in PATH

    )

    begin {
        Write-Verbose "Starting New Arc Deployment process for server '$ServerName'."

        if (-not (Get-Module -Name Az.Accounts -ListAvailable)) {
            Write-Error "Az.Accounts module is required for some operations (like SP validation, not implemented here yet)."
            # For now, this is a soft check as direct azcmagent doesn't need it from this script's perspective
        }

        # Validate that if SP AppId is provided, Secret is also provided
        if (($null -ne $ServicePrincipalAppId -and $null -eq $ServicePrincipalSecret) -or `
            ($null -eq $ServicePrincipalAppId -and $null -ne $ServicePrincipalSecret)) {
            throw "Both ServicePrincipalAppId and ServicePrincipalSecret must be provided for service principal onboarding."
        }
    }

    process {
        Write-Host "Initiating Azure Arc onboarding for server: $ServerName"
        Write-Host "Target Resource Group: $ResourceGroupName, Subscription: $SubscriptionId, Location: $Location, Tenant: $TenantId"

        # Placeholder for Agent Installation
        if ($AgentInstallationScriptPath) {
            if (Test-Path $AgentInstallationScriptPath) {
                Write-Host "Executing agent installation script: $AgentInstallationScriptPath"
                if ($PSCmdlet.ShouldProcess("Execute Agent Installation Script '$AgentInstallationScriptPath'", "Execute")) {
                    try {
                        # This is a placeholder for executing the script.
                        # In a real scenario, consider Start-Process or Invoke-Command for more control.
                        # & $AgentInstallationScriptPath $AgentInstallationArguments
                        Write-Warning "Agent installation script execution is a placeholder. Please ensure agent is installed."
                    } catch {
                        Write-Error "Error during agent installation script execution: $($_.Exception.Message)"
                        throw "Agent installation failed."
                    }
                } else {
                     Write-Warning "Agent installation skipped due to -WhatIf or user declining confirmation."
                }
            } else {
                Write-Warning "Agent installation script not found at '$AgentInstallationScriptPath'. Skipping installation."
            }
        } else {
            Write-Information "No agent installation script provided. Assuming agent is already installed or will be installed manually."
        }

        # Construct azcmagent connect command
        $connectCommand = "$AzcmagentPath connect --resource-group `"$ResourceGroupName`" --subscription-id `"$SubscriptionId`" --location `"$Location`" --tenant-id `"$TenantId`""

        if ($ServicePrincipalAppId) {
            # Convert SecureString to plain text for command line - this is a sensitive operation.
            # In a real script, ensure this is handled with utmost care, possibly avoiding plain text exposure.
            $plainTextSecret = ConvertFrom-SecureString -SecureString $ServicePrincipalSecret -AsPlainText
            $connectCommand += " --service-principal-id `"$ServicePrincipalAppId`" --service-principal-secret `"$plainTextSecret`""
            # Clear the plain text secret from memory as soon as possible
            Clear-Variable plainTextSecret -ErrorAction SilentlyContinue
        }

        if ($CorrelationId) {
            $connectCommand += " --correlation-id `"$CorrelationId`""
        }

        if ($Cloud -ne "AzureCloud") {
            $connectCommand += " --cloud `"$Cloud`""
        }

        if ($ProxyUrl) {
            $connectCommand += " --proxy-url `"$ProxyUrl`""
            if ($ProxyBypass) {
                $connectCommand += " --proxy-bypass `"$ProxyBypass`""
            }
        }

        if ($Tags.Count -gt 0) {
            $tagString = ""
            foreach ($key in $Tags.Keys) {
                $tagString += "$key=`"$($Tags[$key])`";"
            }
            # Remove trailing semicolon
            $tagString = $tagString.Substring(0, $tagString.Length -1)
            $connectCommand += " --tags `"$tagString`""
        }

        Write-Information "Generated azcmagent connect command:"
        Write-Information $connectCommand

        if ($PSCmdlet.ShouldProcess("Execute the azcmagent connect command on server '$ServerName' (locally)", "Execute Onboarding Command")) {
            Write-Host "Please execute the above command on the server '$ServerName' to complete Arc onboarding."
            Write-Warning "This script will not execute the command directly in this version. Manual execution is required."
            # In a future version, this could use Invoke-Command for remote execution or Start-Process for local.
            # For example (local execution):
            # try {
            #     Invoke-Expression -Command $connectCommand -ErrorAction Stop
            #     Write-Host "azcmagent connect command executed. Check agent status with '$AzcmagentPath show'."
            # } catch {
            #     Write-Error "Error executing azcmagent connect: $($_.Exception.Message)"
            #     throw "azcmagent connect command failed."
            # }
        } else {
            Write-Warning "azcmagent connect command execution skipped due to -WhatIf or user declining confirmation."
        }

        $output = [PSCustomObject]@{
            ServerName          = $ServerName
            ResourceGroupName   = $ResourceGroupName
            SubscriptionId      = $SubscriptionId
            Location            = $Location
            TenantId            = $TenantId
            OnboardingCommand   = $connectCommand
            Status              = "CommandGenerated"
            Timestamp           = Get-Date
        }
        return $output
    }

    end {
        Write-Verbose "Finished New Arc Deployment process for server '$ServerName'."
    }
}

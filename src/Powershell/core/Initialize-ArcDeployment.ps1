<#
.SYNOPSIS
Prepares the Azure-side deployment context for Azure Arc onboarding.

.DESCRIPTION
Validates Azure login state, ensures the requested subscription context is active,
and creates or updates the target resource group before server onboarding begins.
Use -WhatIf before live production changes.

.PARAMETER SubscriptionId
Target Azure subscription identifier.

.PARAMETER ResourceGroupName
Resource group that will contain Arc resources.

.PARAMETER Location
Azure region for the resource group.

.PARAMETER TenantId
Optional tenant identifier used when switching Azure context.

.PARAMETER Tags
Tags to apply when creating or updating the resource group.

.OUTPUTS
PSCustomObject

.EXAMPLE
Initialize-ArcDeployment -SubscriptionId '<subscription-id>' -ResourceGroupName 'arc-rg' -Location 'eastus' -WhatIf
#>
function Initialize-ArcDeployment {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param (
        [Parameter(Mandatory = $true)]
        [string]$SubscriptionId,

        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,

        [Parameter(Mandatory = $true)]
        [string]$Location,

        [Parameter()]
        [string]$TenantId, # Currently informational, actual context switch is complex

        [Parameter()]
        [hashtable]$Tags = @{}
    )

    begin {
        Write-Verbose "Starting Arc Deployment Initialization process."

        # Check for Az.Accounts and Az.Resources modules
        if (-not (Get-Module -Name Az.Accounts -ListAvailable)) {
            Write-Verbose "Az.Accounts module is required. Please install it first."
            throw "Az.Accounts module not found."
        }
        if (-not (Get-Module -Name Az.Resources -ListAvailable)) {
            Write-Verbose "Az.Resources module is required. Please install it first."
            throw "Az.Resources module not found."
        }

        # Check Azure Login Status
        $currentContext = Get-AzContext
        if (-not $currentContext) {
            Write-Verbose "Not logged into Azure. Please run Connect-AzAccount first."
            throw "Azure login required."
        }

        Write-Verbose "Current Azure context: Account '$($currentContext.Account)' Subscription '$($currentContext.Subscription.Name)' Tenant '$($currentContext.Tenant.Id)'"

        if ($currentContext.Subscription.Id -ne $SubscriptionId) {
            Write-Warning "Current Azure context subscription '$($currentContext.Subscription.Id)' does not match the target subscription '$SubscriptionId'. Attempting to set context."
            try {
                Set-AzContext -SubscriptionId $SubscriptionId -TenantId $TenantId -ErrorAction Stop | Out-Null
                $currentContext = Get-AzContext
                Write-Verbose "Successfully set Azure context to subscription '$SubscriptionId'."
            }
            catch {
                Write-Verbose "Failed to set Azure context to subscription '$SubscriptionId'. Please ensure you have access and the subscription ID is correct."
                throw "Failed to set Azure context."
            }
        } else {
            Write-Verbose "Azure context subscription matches the target subscription."
        }
    }

    process {
        Write-Verbose "Initializing Azure environment for Arc deployment..."
        Write-Verbose "Target Subscription ID: $SubscriptionId"
        Write-Verbose "Target Resource Group Name: $ResourceGroupName"
        Write-Verbose "Target Location: $Location"
        if ($TenantId) { Write-Verbose "Target Tenant ID (informational): $TenantId" }

        $rgExists = $false
        try {
            Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue | Out-Null
            if ($?) { # Check if previous command was successful
                 Write-Verbose "Resource group '$ResourceGroupName' already exists."
                 $rgExists = $true
                 $resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName
                 if ($resourceGroup.Location -ne $Location) {
                    Write-Warning "Resource group '$ResourceGroupName' exists but is in location '$($resourceGroup.Location)', not target '$Location'. This might cause issues for some resources."
                 }
            }
        } catch {
            Write-Verbose "Resource group lookup failed for '$ResourceGroupName'; continuing with create-if-missing logic."
        }

        if (-not $rgExists) {
            if ($PSCmdlet.ShouldProcess("Resource Group '$ResourceGroupName' in location '$Location'", "Create")) {
                Write-Verbose "Creating resource group '$ResourceGroupName' in location '$Location'..."
                try {
                    New-AzResourceGroup -Name $ResourceGroupName -Location $Location -Tag $Tags -ErrorAction Stop | Out-Null
                    Write-Verbose "Resource group '$ResourceGroupName' created successfully."
                    $resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName
                }
                catch {
                    Write-Verbose "Failed to create resource group '$ResourceGroupName'. Error: $($_.Exception.Message)"
                    throw "Resource group creation failed."
                }
            } else {
                # Under -WhatIf, ShouldProcess returns $false and emits the WhatIf message for us.
                # Treat this as a successful dry-run (non-throwing) and return placeholder output.
                Write-Warning "Resource group creation skipped due to -WhatIf or user declining confirmation."
                $resourceGroup = [pscustomobject]@{
                    ResourceGroupName  = $ResourceGroupName
                    Location           = $Location
                    ProvisioningState  = 'WhatIf'
                    Tags               = $Tags
                }
            }
        } elseif ($Tags.Count -gt 0) {
             if ($PSCmdlet.ShouldProcess("Resource Group '$ResourceGroupName'", "Update Tags")) {
                Write-Verbose "Updating tags for existing resource group '$ResourceGroupName'."
                try {
                    Set-AzResourceGroup -Name $ResourceGroupName -Tag $Tags -ErrorAction Stop | Out-Null
                    $resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName # Refresh to get updated tags
                    Write-Verbose "Tags updated successfully for resource group '$ResourceGroupName'."
                } catch {
                    Write-Verbose "Failed to update tags for resource group '$ResourceGroupName'. Error: $($_.Exception.Message)"
                    # Non-critical, so just warn
                    Write-Warning "Tag update failed for existing resource group."
                }
            }
        }

        $output = [PSCustomObject]@{
            SubscriptionId    = $currentContext.Subscription.Id
            ResourceGroupName = $resourceGroup.ResourceGroupName
            Location          = $resourceGroup.Location
            ProvisioningState = $resourceGroup.ProvisioningState
            Tags              = $resourceGroup.Tags
            InitializationTime = Get-Date
        }

        Write-Verbose "Arc Deployment Initialization complete for resource group '$($resourceGroup.ResourceGroupName)'."
        return $output
    }

    end {
        Write-Verbose "Finished Arc Deployment Initialization process."
    }
}

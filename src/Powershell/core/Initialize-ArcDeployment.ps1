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
            Write-Error "Az.Accounts module is required. Please install it first."
            throw "Az.Accounts module not found."
        }
        if (-not (Get-Module -Name Az.Resources -ListAvailable)) {
            Write-Error "Az.Resources module is required. Please install it first."
            throw "Az.Resources module not found."
        }

        # Check Azure Login Status
        $currentContext = Get-AzContext
        if (-not $currentContext) {
            Write-Error "Not logged into Azure. Please run Connect-AzAccount first."
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
                Write-Error "Failed to set Azure context to subscription '$SubscriptionId'. Please ensure you have access and the subscription ID is correct."
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
            # Error implies RG doesn't exist or other access issue, handled by $rgExists logic
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
                    Write-Error "Failed to create resource group '$ResourceGroupName'. Error: $($_.Exception.Message)"
                    throw "Resource group creation failed."
                }
            } else {
                Write-Warning "Resource group creation skipped due to -WhatIf or user declining confirmation."
                throw "Resource group creation skipped."
            }
        } elseif ($Tags.Count -gt 0) {
             if ($PSCmdlet.ShouldProcess("Resource Group '$ResourceGroupName'", "Update Tags")) {
                Write-Verbose "Updating tags for existing resource group '$ResourceGroupName'."
                try {
                    Set-AzResourceGroup -Name $ResourceGroupName -Tag $Tags -ErrorAction Stop | Out-Null
                    $resourceGroup = Get-AzResourceGroup -Name $ResourceGroupName # Refresh to get updated tags
                    Write-Verbose "Tags updated successfully for resource group '$ResourceGroupName'."
                } catch {
                    Write-Error "Failed to update tags for resource group '$ResourceGroupName'. Error: $($_.Exception.Message)"
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

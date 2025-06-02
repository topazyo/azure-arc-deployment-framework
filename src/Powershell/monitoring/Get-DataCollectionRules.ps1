# Get-DataCollectionRules.ps1
# This script retrieves Data Collection Rules (DCRs) associated with an Azure Arc-enabled server 
# or configured for a specific Log Analytics Workspace.

param (
    [Parameter(Mandatory = $false)] # Becomes mandatory if auto-discovery fails
    [string]$ServerName = $env:COMPUTERNAME,

    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$WorkspaceId, # Log Analytics Workspace ID (e.g., xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\GetDataCollectionRules_Activity.log"
)

# --- Logging Function (for script activity) ---
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO", # INFO, WARNING, ERROR
        [string]$Path = $LogPath
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    try {
        if (-not (Test-Path (Split-Path $Path -Parent))) {
            New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force -ErrorAction Stop | Out-Null
        }
        Add-Content -Path $Path -Value $logEntry -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to write to activity log file $Path. Error: $($_.Exception.Message). Logging to console instead."
        Write-Host $logEntry
    }
}

# --- Helper Function to Discover Arc Agent Config ---
function Get-ArcAgentConfig {
    Write-Log "Attempting to discover Arc agent configuration from registry..."
    $arcAgentRegPath = "HKLM:\SOFTWARE\Microsoft\Azure Connected Machine Agent\Config"
    $config = @{}
    if (Test-Path $arcAgentRegPath) {
        try {
            $regProperties = Get-ItemProperty -Path $arcAgentRegPath -ErrorAction SilentlyContinue
            if ($regProperties.SubscriptionId) { $config.SubscriptionId = $regProperties.SubscriptionId }
            if ($regProperties.ResourceGroup) { $config.ResourceGroupName = $regProperties.ResourceGroup }
            if ($regProperties.TenantId) { $config.TenantId = $regProperties.TenantId }
            Write-Log "Discovered from registry: $($config | Out-String)"
        } catch {
            Write-Log "Error reading Arc agent registry configuration: $($_.Exception.Message)" -Level "WARNING"
        }
    } else {
        Write-Log "Arc agent registry path not found: $arcAgentRegPath" -Level "WARNING"
    }
    return $config
}


# --- Main Script Logic ---
try {
    Write-Log "Starting Get-DataCollectionRules script."
    Write-Log "Parameters: ServerName='$ServerName', SubscriptionId='$SubscriptionId', ResourceGroupName='$ResourceGroupName', WorkspaceId='$WorkspaceId'"

    # 1. Azure Prerequisites Check
    Write-Log "Checking for required Azure PowerShell modules (Az.Monitor, Az.ConnectedMachine/Az.Resources)..."
    $azMonitor = Get-Module -Name Az.Monitor -ListAvailable
    $azConnectedMachine = Get-Module -Name Az.ConnectedMachine -ListAvailable
    $azResources = Get-Module -Name Az.Resources -ListAvailable # Fallback for Get-AzResource

    if (-not $azMonitor) { throw "Az.Monitor PowerShell module is not installed." }
    if (-not ($azConnectedMachine -or $azResources)) { throw "Either Az.ConnectedMachine or Az.Resources PowerShell module is required and not installed."}
    Write-Log "Required Azure modules found."

    Write-Log "Checking for active Azure context..."
    $azContext = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $azContext) { throw "No active Azure context. Please connect using Connect-AzAccount." }
    Write-Log "Active Azure context found for account: $($azContext.Account) in tenant: $($azContext.Tenant.Id)"

    # 2. Determine Server Details and Resource ID
    $effectiveSubscriptionId = $SubscriptionId
    $effectiveResourceGroupName = $ResourceGroupName

    if ([string]::IsNullOrWhiteSpace($effectiveSubscriptionId) -or [string]::IsNullOrWhiteSpace($effectiveResourceGroupName)) {
        $arcConfig = Get-ArcAgentConfig
        if (-not $effectiveSubscriptionId -and $arcConfig.SubscriptionId) { $effectiveSubscriptionId = $arcConfig.SubscriptionId }
        if (-not $effectiveResourceGroupName -and $arcConfig.ResourceGroupName) { $effectiveResourceGroupName = $arcConfig.ResourceGroupName }
    }

    if ([string]::IsNullOrWhiteSpace($effectiveSubscriptionId)) { throw "SubscriptionId could not be determined. Please provide it or ensure Arc agent is configured."}
    if ([string]::IsNullOrWhiteSpace($effectiveResourceGroupName) -and -not [string]::IsNullOrWhiteSpace($ServerName)) {
         throw "ResourceGroupName could not be determined for server '$ServerName'. Please provide it or ensure Arc agent is configured."
    }
    
    # Set context to the target subscription
    try {
        Write-Log "Setting Az context to subscription: $effectiveSubscriptionId"
        Set-AzContext -SubscriptionId $effectiveSubscriptionId -ErrorAction Stop | Out-Null
        $currentContext = Get-AzContext
        Write-Log "Successfully set Az context to Subscription: $($currentContext.Subscription.Name) ($($currentContext.Subscription.Id))"
    } catch {
        throw "Failed to set Az context to subscription ID '$effectiveSubscriptionId'. Error: $($_.Exception.Message)"
    }

    $serverResourceId = $null
    if (-not [string]::IsNullOrWhiteSpace($ServerName)) {
        Write-Log "Attempting to get Azure Resource ID for server: '$ServerName' in RG '$effectiveResourceGroupName'..."
        try {
            if ($azConnectedMachine) {
                $connectedMachine = Get-AzConnectedMachine -Name $ServerName -ResourceGroupName $effectiveResourceGroupName -ErrorAction Stop
                $serverResourceId = $connectedMachine.Id
            } else { # Fallback to generic Get-AzResource
                $serverResourceId = (Get-AzResource -ResourceType "Microsoft.HybridCompute/machines" -Name $ServerName -ResourceGroupName $effectiveResourceGroupName -ErrorAction Stop).ResourceId
            }
            if ($serverResourceId) {
                Write-Log "Found Azure Resource ID for server '$ServerName': $serverResourceId"
            } else {
                Write-Log "Azure Arc-enabled server '$ServerName' not found in resource group '$effectiveResourceGroupName'." -Level "WARNING"
            }
        } catch {
            Write-Log "Failed to get Azure Resource ID for server '$ServerName'. Error: $($_.Exception.Message)" -Level "ERROR"
            # Continue if WorkspaceId is provided, as we might still be able to find DCRs for the workspace
            if ([string]::IsNullOrWhiteSpace($WorkspaceId)) { throw "Cannot proceed without server Resource ID or WorkspaceId." }
        }
    }
    

    $foundDcrs = [System.Collections.ArrayList]::new()

    # 3a. List DCR Associations for the Server (if serverResourceId is known)
    if ($serverResourceId) {
        Write-Log "Retrieving DCR associations for server resource ID: $serverResourceId"
        try {
            $dcrAssociations = Get-AzDataCollectionRuleAssociation -TargetResourceId $serverResourceId -ErrorAction Stop
            if ($dcrAssociations) {
                Write-Log "Found $($dcrAssociations.Count) DCR associations for server '$ServerName'."
                foreach ($assoc in $dcrAssociations) {
                    try {
                        $dcr = Get-AzDataCollectionRule -ResourceId $assoc.DataCollectionRuleId
                        $streams = $dcr.Stream | ForEach-Object { $_ } # Get actual stream names
                        $dest = $dcr.Destinations.LogAnalytic | ForEach-Object { @{ LogAnalyticsWorkspaceId = $_.WorkspaceResourceId.Split('/')[-1]; Name = $_.Name } }
                        
                        $foundDcrs.Add([PSCustomObject]@{
                            DcrName              = $dcr.Name
                            DcrId                = $dcr.Id
                            Location             = $dcr.Location
                            Description          = $dcr.Description
                            Streams              = $streams
                            Destinations         = $dest
                            AssociationName      = $assoc.Name
                            AssociatedResourceId = $serverResourceId 
                            DiscoveryMethod      = "AssociationToMachine"
                        }) | Out-Null
                    } catch {
                         Write-Log "Error retrieving full DCR details for $($assoc.DataCollectionRuleId) via association: $($_.Exception.Message)" -Level "WARNING"
                    }
                }
            } else {
                Write-Log "No DCR associations found directly for server '$ServerName'."
            }
        } catch {
            Write-Log "Failed to get DCR associations for server '$ServerName'. Error: $($_.Exception.Message)" -Level "ERROR"
        }
    }

    # 3b. List DCRs by WorkspaceId (if provided)
    # This can find DCRs that *target* the workspace, but aren't necessarily associated with *this specific server*
    # unless also caught by the association check above.
    if (-not [string]::IsNullOrWhiteSpace($WorkspaceId)) {
        Write-Log "Retrieving DCRs in subscription '$effectiveSubscriptionId' and filtering for Workspace ID '$WorkspaceId'..."
        try {
            $allDcrsInSubscription = Get-AzDataCollectionRule -SubscriptionId $effectiveSubscriptionId -ErrorAction Stop
            Write-Log "Found $($allDcrsInSubscription.Count) DCRs in the subscription. Filtering for workspace..."
            
            foreach ($dcr in $allDcrsInSubscription) {
                $targetsWorkspace = $false
                if ($dcr.Destinations.LogAnalytic) {
                    foreach($laDest in $dcr.Destinations.LogAnalytic){
                        if ($laDest.WorkspaceResourceId -match "/workspaces/($WorkspaceId)$") {
                            $targetsWorkspace = $true
                            break
                        }
                    }
                }

                if ($targetsWorkspace) {
                    # Avoid duplicates if already found via association
                    if (-not ($foundDcrs | Where-Object {$_.DcrId -eq $dcr.Id})) {
                        $streams = $dcr.Stream | ForEach-Object { $_ }
                        $dest = $dcr.Destinations.LogAnalytic | ForEach-Object { @{ LogAnalyticsWorkspaceId = $_.WorkspaceResourceId.Split('/')[-1]; Name = $_.Name } }
                        
                        $foundDcrs.Add([PSCustomObject]@{
                            DcrName              = $dcr.Name
                            DcrId                = $dcr.Id
                            Location             = $dcr.Location
                            Description          = $dcr.Description
                            Streams              = $streams
                            Destinations         = $dest
                            AssociationName      = $null # Not found via specific association to this server
                            AssociatedResourceId = $null 
                            DiscoveryMethod      = "WorkspaceTargetInSubscription"
                        }) | Out-Null
                        Write-Log "Found DCR '$($dcr.Name)' targeting Workspace '$WorkspaceId'."
                    }
                }
            }
        } catch {
            Write-Log "Failed to list or filter DCRs for Workspace ID '$WorkspaceId'. Error: $($_.Exception.Message)" -Level "ERROR"
        }
    }
    
    Write-Log "Get-DataCollectionRules script finished. Total DCRs found relevant to criteria: $($foundDcrs.Count)."
    return $foundDcrs
}
catch {
    Write-Log "A critical error occurred in Get-DataCollectionRules script: $($_.Exception.Message)" -Level "FATAL"
    if ($_.ScriptStackTrace) {
        Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "FATAL"
    }
    return @()
}

# Test-ResourceProviderStatus.ps1
# This script checks the registration status of required Azure Resource Providers for a given subscription.

param (
    [Parameter(Mandatory = $false)]
    [string]$SubscriptionId,

    [Parameter(Mandatory = $false)]
    [string[]]$RequiredResourceProviders = @(
        'Microsoft.HybridCompute',
        'Microsoft.GuestConfiguration',
        'Microsoft.AzureArcData', # For Arc-enabled Data Services
        'Microsoft.Insights',     # For Azure Monitor
        'Microsoft.Security'      # For Microsoft Defender for Cloud / Security Center
        # Add others as relevant, e.g., Microsoft.OperationalInsights for Log Analytics
    ),

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\ResourceProviderStatus.log"
)

# --- Logging Function ---
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO", # INFO, WARNING, ERROR, DEBUG
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
        Write-Warning "Failed to write to log file $Path. Error: $($_.Exception.Message). Logging to console instead."
        Write-Host $logEntry
    }
}

# --- Helper Function to Add Provider Detail ---
function Add-ProviderDetail {
    param (
        [System.Collections.ArrayList]$DetailsCollection,
        [string]$ProviderNamespace,
        [string]$RegistrationState,
        [string]$Locations # Optional, can be a comma-separated string or array
    )
    $status = if ($RegistrationState -eq "Registered") { "Success" } else { "Failed" }
    $DetailsCollection.Add([PSCustomObject]@{
        ProviderNamespace = $ProviderNamespace
        RegistrationState = $RegistrationState
        RegisteredLocations = $Locations # Could be useful info
        Status            = $status
    }) | Out-Null
    Write-Log "Check: Provider '$ProviderNamespace', Expected State: 'Registered', Current State: '$RegistrationState', Status: $status"
}

# --- Main Script Logic ---
try {
    Write-Log "Starting Azure Resource Provider status check script."

    # 1. Check for Az.Resources module
    Write-Log "Checking for Az.Resources PowerShell module..."
    $azResourcesModule = Get-Module -Name Az.Resources -ListAvailable
    if (-not $azResourcesModule) {
        Write-Log "Az.Resources PowerShell module is not installed. This script cannot continue." -Level "ERROR"
        throw "Az.Resources module not found."
    }
    Write-Log "Az.Resources module found."

    # 2. Check for Azure Authentication Context
    Write-Log "Checking for active Azure context..."
    $azContext = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $azContext) {
        Write-Log "No active Azure context found. Please connect using Connect-AzAccount. This script cannot continue." -Level "ERROR"
        throw "Azure context not found. Please login with Connect-AzAccount."
    }
    Write-Log "Active Azure context found for account: $($azContext.Account) in tenant: $($azContext.Tenant.Id)"

    # 3. Determine Subscription ID
    $effectiveSubscriptionId = $null
    if (-not [string]::IsNullOrWhiteSpace($SubscriptionId)) {
        Write-Log "Using provided Subscription ID: $SubscriptionId"
        $effectiveSubscriptionId = $SubscriptionId
    } else {
        Write-Log "Subscription ID not provided. Attempting to discover from Azure Connected Machine Agent configuration..."
        $arcAgentConfigPath = "HKLM:\SOFTWARE\Microsoft\Azure Connected Machine Agent\Config"
        if (Test-Path $arcAgentConfigPath) {
            try {
                $effectiveSubscriptionId = (Get-ItemProperty -Path $arcAgentConfigPath -Name SubscriptionId -ErrorAction Stop).SubscriptionId
                if ($effectiveSubscriptionId) {
                    Write-Log "Discovered Subscription ID from Arc Agent config: $effectiveSubscriptionId"
                } else {
                    Write-Log "SubscriptionId registry value not found or empty under Arc Agent config." -Level "WARNING"
                }
            } catch {
                Write-Log "Failed to read SubscriptionId from Arc Agent registry: $($_.Exception.Message)" -Level "WARNING"
            }
        } else {
            Write-Log "Azure Connected Machine Agent registry path not found: $arcAgentConfigPath" -Level "WARNING"
        }

        if (-not $effectiveSubscriptionId) {
            Write-Log "Could not determine Subscription ID automatically. It must be provided as a parameter if not discoverable." -Level "ERROR"
            throw "Subscription ID could not be determined."
        }
    }

    # Set context to the target subscription (important if logged into multiple)
    try {
        Write-Log "Setting Az context to subscription: $effectiveSubscriptionId"
        Set-AzContext -SubscriptionId $effectiveSubscriptionId -ErrorAction Stop | Out-Null
        $currentContext = Get-AzContext
        Write-Log "Successfully set Az context to Subscription: $($currentContext.Subscription.Name) ($($currentContext.Subscription.Id))"
    } catch {
        Write-Log "Failed to set Az context to subscription ID '$effectiveSubscriptionId'. Error: $($_.Exception.Message)" -Level "ERROR"
        throw "Failed to set Azure context for subscription."
    }


    $providerDetailsCollection = [System.Collections.ArrayList]::new()
    $overallStatus = "Success" # Assume success until a failure is detected

    Write-Log "--- Checking Resource Provider Registration Status ---"
    foreach ($providerNamespace in $RequiredResourceProviders) {
        Write-Log "Checking status for provider: $providerNamespace"
        try {
            $provider = Get-AzResourceProvider -ProviderNamespace $providerNamespace -ErrorAction Stop
            $locations = ($provider.ResourceTypes.ResourceTypeName -join ", ") # Example of getting some more info
            Add-ProviderDetail $providerDetailsCollection $providerNamespace $provider.RegistrationState $locations
            if ($provider.RegistrationState -ne "Registered") {
                $overallStatus = "Failed"
            }
        }
        catch {
            Write-Log "Failed to get status for provider '$providerNamespace'. Error: $($_.Exception.Message)" -Level "ERROR"
            Add-ProviderDetail $providerDetailsCollection $providerNamespace "ERROR_RETRIEVING_STATUS" ""
            $overallStatus = "Failed"
        }
    }

    $result = @{
        SubscriptionId  = $effectiveSubscriptionId
        Timestamp       = Get-Date
        OverallStatus   = $overallStatus
        ProviderDetails = $providerDetailsCollection
    }

    Write-Log "Resource Provider status check completed. Overall Status: $overallStatus"
    return $result

}
catch {
    Write-Log "An critical error occurred: $($_.Exception.Message)" -Level "FATAL"
    if ($_.ScriptStackTrace) {
        Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "FATAL"
    }
    # Return an error object or rethrow
    return @{
        SubscriptionId  = if ($effectiveSubscriptionId) { $effectiveSubscriptionId } else { "Unknown" }
        Timestamp       = Get-Date
        OverallStatus   = "Failed"
        Error           = "Critical error during script execution: $($_.Exception.Message)"
        ProviderDetails = @()
    }
}

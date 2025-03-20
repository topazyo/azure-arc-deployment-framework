function Test-ArcAgentValidation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [switch]$DetailedOutput,
        [Parameter()]
        [int]$TimeoutSeconds = 60,
        [Parameter()]
        [string]$LogPath = ".\Logs\Validation"
    )

    begin {
        $validationResults = @{
            ServerName = $ServerName
            StartTime = Get-Date
            Status = "Unknown"
            Components = @()
            Issues = @()
            Recommendations = @()
        }

        # Ensure log directory exists
        if (-not (Test-Path $LogPath)) {
            New-Item -Path $LogPath -ItemType Directory -Force | Out-Null
        }

        Write-Log -Message "Starting Arc agent validation for $ServerName" -Level Information
    }

    process {
        try {
            # 1. Service Status Validation
            $serviceValidation = Test-ArcServiceStatus -ServerName $ServerName
            $validationResults.Components += @{
                Name = "Service Status"
                Status = $serviceValidation.Status
                Details = $serviceValidation.Details
                Critical = $true
            }

            if ($serviceValidation.Status -ne "Success") {
                $validationResults.Issues += @{
                    Component = "Service Status"
                    Severity = "Critical"
                    Description = "Arc agent service is not running properly"
                    Details = $serviceValidation.Details
                }
            }

            # 2. Configuration Validation
            $configValidation = Test-ArcConfiguration -ServerName $ServerName
            $validationResults.Components += @{
                Name = "Configuration"
                Status = $configValidation.Status
                Details = $configValidation.Details
                Critical = $true
            }

            if ($configValidation.Status -ne "Success") {
                $validationResults.Issues += @{
                    Component = "Configuration"
                    Severity = "Critical"
                    Description = "Arc agent configuration is invalid or incomplete"
                    Details = $configValidation.Details
                }
            }

            # 3. Connectivity Validation
            $connectivityValidation = Test-ArcConnectivity -ServerName $ServerName -TimeoutSeconds $TimeoutSeconds
            $validationResults.Components += @{
                Name = "Connectivity"
                Status = $connectivityValidation.Status
                Details = $connectivityValidation.Details
                Critical = $true
            }

            if ($connectivityValidation.Status -ne "Success") {
                $validationResults.Issues += @{
                    Component = "Connectivity"
                    Severity = "Critical"
                    Description = "Arc agent cannot connect to required endpoints"
                    Details = $connectivityValidation.Details
                }
            }

            # 4. Registration Status Validation
            $registrationValidation = Test-ArcRegistrationStatus -ServerName $ServerName
            $validationResults.Components += @{
                Name = "Registration"
                Status = $registrationValidation.Status
                Details = $registrationValidation.Details
                Critical = $true
            }

            if ($registrationValidation.Status -ne "Success") {
                $validationResults.Issues += @{
                    Component = "Registration"
                    Severity = "Critical"
                    Description = "Arc agent is not properly registered with Azure"
                    Details = $registrationValidation.Details
                }
            }

            # 5. Authentication Validation
            $authValidation = Test-ArcAuthentication -ServerName $ServerName
            $validationResults.Components += @{
                Name = "Authentication"
                Status = $authValidation.Status
                Details = $authValidation.Details
                Critical = $true
            }

            if ($authValidation.Status -ne "Success") {
                $validationResults.Issues += @{
                    Component = "Authentication"
                    Severity = "Critical"
                    Description = "Arc agent authentication is failing"
                    Details = $authValidation.Details
                }
            }

            # 6. Resource Health Validation
            $resourceValidation = Test-ArcResourceHealth -ServerName $ServerName
            $validationResults.Components += @{
                Name = "Resource Health"
                Status = $resourceValidation.Status
                Details = $resourceValidation.Details
                Critical = $false
            }

            if ($resourceValidation.Status -ne "Success") {
                $validationResults.Issues += @{
                    Component = "Resource Health"
                    Severity = "Warning"
                    Description = "Arc resource health is degraded"
                    Details = $resourceValidation.Details
                }
            }

            # 7. Extension Status Validation
            $extensionValidation = Test-ArcExtensionStatus -ServerName $ServerName
            $validationResults.Components += @{
                Name = "Extension Status"
                Status = $extensionValidation.Status
                Details = $extensionValidation.Details
                Critical = $false
            }

            if ($extensionValidation.Status -ne "Success") {
                $validationResults.Issues += @{
                    Component = "Extension Status"
                    Severity = "Warning"
                    Description = "One or more Arc extensions are in a failed state"
                    Details = $extensionValidation.Details
                }
            }

            # 8. Log Validation
            $logValidation = Test-ArcLogs -ServerName $ServerName
            $validationResults.Components += @{
                Name = "Logs"
                Status = $logValidation.Status
                Details = $logValidation.Details
                Critical = $false
            }

            if ($logValidation.Status -ne "Success") {
                $validationResults.Issues += @{
                    Component = "Logs"
                    Severity = "Warning"
                    Description = "Arc agent logs contain errors or warnings"
                    Details = $logValidation.Details
                }
            }

            # 9. Version Validation
            $versionValidation = Test-ArcVersion -ServerName $ServerName
            $validationResults.Components += @{
                Name = "Version"
                Status = $versionValidation.Status
                Details = $versionValidation.Details
                Critical = $false
            }

            if ($versionValidation.Status -ne "Success") {
                $validationResults.Issues += @{
                    Component = "Version"
                    Severity = "Warning"
                    Description = "Arc agent version is outdated"
                    Details = $versionValidation.Details
                }
            }

            # 10. Detailed Validation (if requested)
            if ($DetailedOutput) {
                # Certificate Validation
                $certValidation = Test-ArcCertificates -ServerName $ServerName
                $validationResults.Components += @{
                    Name = "Certificates"
                    Status = $certValidation.Status
                    Details = $certValidation.Details
                    Critical = $true
                }

                if ($certValidation.Status -ne "Success") {
                    $validationResults.Issues += @{
                        Component = "Certificates"
                        Severity = "Critical"
                        Description = "Arc agent certificates are invalid or expired"
                        Details = $certValidation.Details
                    }
                }

                # Performance Validation
                $perfValidation = Test-ArcPerformance -ServerName $ServerName
                $validationResults.Components += @{
                    Name = "Performance"
                    Status = $perfValidation.Status
                    Details = $perfValidation.Details
                    Critical = $false
                }

                if ($perfValidation.Status -ne "Success") {
                    $validationResults.Issues += @{
                        Component = "Performance"
                        Severity = "Warning"
                        Description = "Arc agent performance is degraded"
                        Details = $perfValidation.Details
                    }
                }

                # Dependency Validation
                $depValidation = Test-ArcDependencies -ServerName $ServerName
                $validationResults.Components += @{
                    Name = "Dependencies"
                    Status = $depValidation.Status
                    Details = $depValidation.Details
                    Critical = $true
                }

                if ($depValidation.Status -ne "Success") {
                    $validationResults.Issues += @{
                        Component = "Dependencies"
                        Severity = "Critical"
                        Description = "Arc agent dependencies are missing or misconfigured"
                        Details = $depValidation.Details
                    }
                }
            }

            # Generate Recommendations
            $validationResults.Recommendations = Get-ArcValidationRecommendations -Issues $validationResults.Issues

            # Determine Overall Status
            $criticalComponents = $validationResults.Components | Where-Object { $_.Critical }
            $validationResults.Status = if (
                ($criticalComponents | Where-Object { $_.Status -ne "Success" }).Count -eq 0
            ) {
                "Success"
            }
            else {
                "Failed"
            }

            Write-Log -Message "Arc agent validation completed with status: $($validationResults.Status)" -Level Information
        }
        catch {
            $validationResults.Status = "Error"
            $validationResults.Error = $_.Exception.Message
            Write-Error "Arc agent validation failed: $_"
            Write-Log -Message "Arc agent validation failed: $_" -Level Error
        }
    }

    end {
        $validationResults.EndTime = Get-Date
        $validationResults.Duration = $validationResults.EndTime - $validationResults.StartTime

        # Export validation results
        $logFile = Join-Path $LogPath "ArcValidation_$($ServerName)_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
        $validationResults | ConvertTo-Json -Depth 10 | Out-File $logFile

        return [PSCustomObject]$validationResults
    }
}

function Test-ArcServiceStatus {
    [CmdletBinding()]
    param ([string]$ServerName)

    $results = @{
        Status = "Unknown"
        Details = @{}
    }

    try {
        # Check himds service
        $himdsService = Get-Service -Name "himds" -ComputerName $ServerName -ErrorAction Stop
        $results.Details.HimdsService = @{
            Status = $himdsService.Status
            StartType = $himdsService.StartType
            DisplayName = $himdsService.DisplayName
        }

        # Check Guest Configuration service
        $guestService = Get-Service -Name "gcad" -ComputerName $ServerName -ErrorAction SilentlyContinue
        if ($guestService) {
            $results.Details.GuestConfigService = @{
                Status = $guestService.Status
                StartType = $guestService.StartType
                DisplayName = $guestService.DisplayName
            }
        }

        # Check service dependencies
        $dependencies = Get-ServiceDependencies -ServerName $ServerName -ServiceName "himds"
        $results.Details.Dependencies = $dependencies

        # Check service account
        $serviceAccount = Get-ServiceAccount -ServerName $ServerName -ServiceName "himds"
        $results.Details.ServiceAccount = $serviceAccount

        # Check service startup history
        $startupHistory = Get-ServiceStartupHistory -ServerName $ServerName -ServiceName "himds"
        $results.Details.StartupHistory = $startupHistory

        # Determine status
        $results.Status = if (
            $himdsService.Status -eq "Running" -and
            ($null -eq $guestService -or $guestService.Status -eq "Running") -and
            $dependencies.Status -eq "Success"
        ) {
            "Success"
        }
        else {
            "Failed"
        }
    }
    catch {
        $results.Status = "Error"
        $results.Error = $_.Exception.Message
    }

    return $results
}

function Test-ArcConfiguration {
    [CmdletBinding()]
    param ([string]$ServerName)

    $results = @{
        Status = "Unknown"
        Details = @{}
    }

    try {
        # Get agent configuration
        $configPath = "\\$ServerName\c$\Program Files\Azure Connected Machine Agent\config"
        
        if (-not (Test-Path $configPath)) {
            $results.Status = "Failed"
            $results.Details.ConfigPath = "Not found: $configPath"
            return $results
        }

        # Check agent config file
        $agentConfigPath = "$configPath\agentconfig.json"
        if (Test-Path $agentConfigPath) {
            $agentConfig = Get-Content $agentConfigPath -Raw | ConvertFrom-Json
            $results.Details.AgentConfig = @{
                Exists = $true
                Valid = $null -ne $agentConfig
                Content = $agentConfig
            }
        }
        else {
            $results.Details.AgentConfig = @{
                Exists = $false
                Valid = $false
                Content = $null
            }
        }

        # Check identity config
        $identityConfigPath = "$configPath\identity.json"
        if (Test-Path $identityConfigPath) {
            $identityConfig = Get-Content $identityConfigPath -Raw | ConvertFrom-Json
            $results.Details.IdentityConfig = @{
                Exists = $true
                Valid = $null -ne $identityConfig
                Content = $identityConfig
            }
        }
        else {
            $results.Details.IdentityConfig = @{
                Exists = $false
                Valid = $false
                Content = $null
            }
        }

        # Check state file
        $stateFilePath = "$configPath\state"
        if (Test-Path $stateFilePath) {
            $stateFile = Get-Content $stateFilePath -Raw
            $results.Details.StateFile = @{
                Exists = $true
                Content = $stateFile
            }
        }
        else {
            $results.Details.StateFile = @{
                Exists = $false
                Content = $null
            }
        }

        # Validate configuration
        $configValid = (
            $results.Details.AgentConfig.Exists -and
            $results.Details.AgentConfig.Valid -and
            $results.Details.IdentityConfig.Exists -and
            $results.Details.IdentityConfig.Valid -and
            $results.Details.StateFile.Exists
        )

        $results.Status = $configValid ? "Success" : "Failed"
    }
    catch {
        $results.Status = "Error"
        $results.Error = $_.Exception.Message
    }

    return $results
}

function Test-ArcConnectivity {
    [CmdletBinding()]
    param (
        [string]$ServerName,
        [int]$TimeoutSeconds = 60
    )

    $results = @{
        Status = "Unknown"
        Details = @{}
    }

    try {
        # Define required endpoints
        $endpoints = @{
            'Azure Resource Manager' = @{
                Url = 'management.azure.com'
                Port = 443
                Required = $true
            }
            'Azure Active Directory' = @{
                Url = 'login.microsoftonline.com'
                Port = 443
                Required = $true
            }
            'Azure Arc Service' = @{
                Url = 'guestconfiguration.azure.com'
                Port = 443
                Required = $true
            }
            'Azure Monitor' = @{
                Url = 'global.handler.control.monitor.azure.com'
                Port = 443
                Required = $false
            }
        }

        # Test connectivity to each endpoint
        $endpointResults = @{}
        $allRequired = $true

        foreach ($endpoint in $endpoints.GetEnumerator()) {
            $test = Test-NetConnection -ComputerName $endpoint.Value.Url -Port $endpoint.Value.Port -WarningAction SilentlyContinue
            
            $endpointResults[$endpoint.Key] = @{
                Url = $endpoint.Value.Url
                Port = $endpoint.Value.Port
                Required = $endpoint.Value.Required
                Success = $test.TcpTestSucceeded
                LatencyMS = $test.PingReplyDetails.RoundtripTime
            }

            if ($endpoint.Value.Required -and -not $test.TcpTestSucceeded) {
                $allRequired = $false
            }
        }

        $results.Details.Endpoints = $endpointResults

        # Check proxy configuration
        $proxyConfig = Get-ProxyConfiguration -ServerName $ServerName
        $results.Details.ProxyConfiguration = $proxyConfig

        # Check DNS resolution
        $dnsResults = @{}
        foreach ($endpoint in $endpoints.GetEnumerator()) {
            $dns = Resolve-DnsName -Name $endpoint.Value.Url -ErrorAction SilentlyContinue
            $dnsResults[$endpoint.Key] = @{
                Resolved = $null -ne $dns
                IPs = $dns.IPAddress
            }
        }
        $results.Details.DNSResolution = $dnsResults

        # Check TLS configuration
        $tlsConfig = Get-TLSConfiguration -ServerName $ServerName
        $results.Details.TLSConfiguration = $tlsConfig

        # Determine status
        $results.Status = $allRequired ? "Success" : "Failed"
    }
    catch {
        $results.Status = "Error"
        $results.Error = $_.Exception.Message
    }

    return $results
}

function Test-ArcRegistrationStatus {
    [CmdletBinding()]
    param ([string]$ServerName)

    $results = @{
        Status = "Unknown"
        Details = @{}
    }

    try {
        # Check local registration status
        $regStatus = Invoke-Command -ComputerName $ServerName -ScriptBlock {
            $agentPath = "C:\Program Files\Azure Connected Machine Agent"
            if (Test-Path $agentPath) {
                $azcmagent = Join-Path $agentPath "azcmagent.exe"
                if (Test-Path $azcmagent) {
                    $status = & $azcmagent show
                    return $status
                }
            }
            return $null
        }

        if ($regStatus) {
            $results.Details.LocalStatus = $regStatus
            
            # Parse status output
            $connected = $regStatus -match "Agent Status: Connected"
            $resourceId = ($regStatus | Select-String -Pattern "Resource Id: (.+)").Matches.Groups[1].Value
            $version = ($regStatus | Select-String -Pattern "Agent Version: (.+)").Matches.Groups[1].Value
            
            $results.Details.ParsedStatus = @{
                Connected = $connected
                ResourceId = $resourceId
                Version = $version
            }
        }
        else {
            $results.Details.LocalStatus = "Unable to retrieve status"
        }

        # Check Azure registration status
        try {
            $azContext = Get-AzContext
            if ($azContext) {
                $arcServer = Get-AzConnectedMachine -Name $ServerName -ErrorAction SilentlyContinue
                if ($arcServer) {
                    $results.Details.AzureStatus = @{
                        Found = $true
                        Status = $arcServer.Status
                        LastStatusChange = $arcServer.LastStatusChange
                        AgentVersion = $arcServer.AgentVersion
                        ResourceId = $arcServer.Id
                    }
                }
                else {
                    $results.Details.AzureStatus = @{
                        Found = $false
                        Status = "Not registered"
                    }
                }
            }
            else {
                $results.Details.AzureStatus = @{
                    Found = $false
                    Status = "Not authenticated to Azure"
                }
            }
        }
        catch {
            $results.Details.AzureStatus = @{
                Found = $false
                Status = "Error checking Azure status"
                Error = $_.Exception.Message
            }
        }

        # Determine status
        $results.Status = if (
            $regStatus -and
            $connected -and
            $results.Details.AzureStatus.Found -and
            $results.Details.AzureStatus.Status -eq "Connected"
        ) {
            "Success"
        }
        else {
            "Failed"
        }
    }
    catch {
        $results.Status = "Error"
        $results.Error = $_.Exception.Message
    }

    return $results
}

function Get-ArcValidationRecommendations {
    [CmdletBinding()]
    param ([array]$Issues)

    $recommendations = @()

    foreach ($issue in $Issues) {
        $recommendation = switch ($issue.Component) {
            "Service Status" {
                @{
                    Component = $issue.Component
                    Priority = "High"
                    Action = "Restart the Arc agent service"
                    Details = "Run 'Restart-Service -Name himds' or use azcmagent to restart the service"
                }
            }
            "Configuration" {
                @{
                    Component = $issue.Component
                    Priority = "High"
                    Action = "Repair Arc agent configuration"
                    Details = "Run 'azcmagent config' to reconfigure the agent or reinstall if necessary"
                }
            }
            "Connectivity" {
                @{
                    Component = $issue.Component
                    Priority = "High"
                    Action = "Resolve network connectivity issues"
                    Details = "Check firewall rules, proxy settings, and DNS resolution for required endpoints"
                }
            }
            "Registration" {
                @{
                    Component = $issue.Component
                    Priority = "High"
                    Action = "Re-register the Arc agent"
                    Details = "Run 'azcmagent disconnect' followed by 'azcmagent connect' with appropriate parameters"
                }
            }
            "Authentication" {
                @{
                    Component = $issue.Component
                    Priority = "High"
                    Action = "Fix authentication issues"
                    Details = "Check service principal credentials or managed identity configuration"
                }
            }
            "Resource Health" {
                @{
                    Component = $issue.Component
                    Priority = "Medium"
                    Action = "Check Azure resource health"
                    Details = "Verify the Arc-enabled server resource in Azure portal"
                }
            }
            "Extension Status" {
                @{
                    Component = $issue.Component
                    Priority = "Medium"
                    Action = "Repair failed extensions"
                    Details = "Reinstall or update problematic extensions"
                }
            }
            "Logs" {
                @{
                    Component = $issue.Component
                    Priority = "Low"
                    Action = "Review and clear error logs"
                    Details = "Check logs at 'C:\Program Files\Azure Connected Machine Agent\logs'"
                }
            }
            "Version" {
                @{
                    Component = $issue.Component
                    Priority = "Medium"
                    Action = "Update Arc agent to latest version"
                    Details = "Run 'azcmagent upgrade' to update the agent"
                }
            }
            "Certificates" {
                @{
                    Component = $issue.Component
                    Priority = "High"
                    Action = "Renew or fix certificates"
                    Details = "Check certificate validity and trust chain"
                }
            }
            "Performance" {
                @{
                    Component = $issue.Component
                    Priority = "Low"
                    Action = "Optimize agent performance"
                    Details = "Check system resources and agent configuration"
                }
            }
            "Dependencies" {
                @{
                    Component = $issue.Component
                    Priority = "High"
                    Action = "Install missing dependencies"
                    Details = "Verify all required dependencies are installed and properly configured"
                }
            }
            default {
                @{
                    Component = $issue.Component
                    Priority = "Medium"
                    Action = "Investigate and resolve issues"
                    Details = "Review detailed error information and logs"
                }
            }
        }

        if ($recommendation) {
            $recommendations += $recommendation
        }
    }

    return $recommendations | Sort-Object -Property Priority
}
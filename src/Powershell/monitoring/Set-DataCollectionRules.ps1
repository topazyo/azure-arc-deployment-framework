function Set-DataCollectionRules {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter(Mandatory)]
        [string]$WorkspaceId,
        [Parameter()]
        [ValidateSet('Security', 'Performance', 'Custom')]
        [string]$RuleType = 'Security',
        [Parameter()]
        [hashtable]$CustomConfig
    )

    begin {
        $dcrState = @{
            ServerName = $ServerName
            RuleType = $RuleType
            Status = "Starting"
            Timestamp = Get-Date
            Changes = @()
        }

        $defaultConfigs = $null
    }

    process {
        try {
            if (-not $defaultConfigs -and $RuleType -ne 'Custom') {
                $defaultConfigs = Get-Content ".\Config\dcr-templates.json" | ConvertFrom-Json
            }

            # Select base configuration
            $baseConfig = switch ($RuleType) {
                'Security' { $defaultConfigs.security }
                'Performance' { $defaultConfigs.performance }
                'Custom' { $CustomConfig }
            }

            # Create DCR
            $dcrParams = @{
                Name = "DCR-$ServerName-$RuleType"
                Location = $baseConfig.location
            }

            $dcrCommand = Get-Command New-AzDataCollectionRule -ErrorAction SilentlyContinue
            $dcrParameterNames = if ($dcrCommand) { @($dcrCommand.Parameters.Keys) } else { @() }

            if ($dcrParameterNames -contains 'ResourceGroupName') {
                $dcrParams.ResourceGroupName = $baseConfig.resourceGroup
            }
            else {
                $dcrParams.ResourceGroup = $baseConfig.resourceGroup
            }

            $dataSources = ConvertTo-HashtableSafe $baseConfig.dataSources
            $destinations = ConvertTo-HashtableSafe $baseConfig.destinations
            $streams = @($baseConfig.streams)

            if ($dcrParameterNames -contains 'DataSources') {
                $dcrParams.DataSources = $dataSources
            }
            else {
                if ($dataSources.ContainsKey('syslog')) {
                    $syslogSources = @(ConvertTo-ArraySafe $dataSources.syslog)
                    if ($syslogSources.Count -gt 0) {
                        $dcrParams.DataSourceSyslog = $syslogSources
                    }
                }

                if ($dataSources.ContainsKey('performanceCounters')) {
                    $performanceCounters = @(ConvertTo-ArraySafe $dataSources.performanceCounters)
                    if ($performanceCounters.Count -gt 0) {
                        $dcrParams.DataSourcePerformanceCounter = $performanceCounters
                    }
                }

                if ($dataSources.ContainsKey('windowsEventLogs')) {
                    $eventLogs = @(ConvertTo-ArraySafe $dataSources.windowsEventLogs)
                    if ($eventLogs.Count -gt 0) {
                        $dcrParams.DataSourceWindowsEventLog = $eventLogs
                    }
                }
            }

            $logAnalyticsDestinations = @(
                [PSCustomObject]@{
                    WorkspaceResourceId = $WorkspaceId
                    Name = 'LA-Destination'
                }
            )

            if ($dcrParameterNames -contains 'Destinations') {
                $dcrParams.Destinations = if ($destinations.Count -gt 0) {
                    $destinations
                }
                else {
                    @{ LogAnalytics = $logAnalyticsDestinations }
                }
            }
            elseif ($dcrParameterNames -contains 'DestinationLogAnalytic') {
                $dcrParams.DestinationLogAnalytic = $logAnalyticsDestinations
            }

            $dataFlows = if ($streams.Count -gt 0) {
                @(
                    [PSCustomObject]@{
                        Streams = $streams
                        Destinations = @('LA-Destination')
                    }
                )
            }
            else {
                @()
            }

            if ($dataFlows.Count -gt 0) {
                if ($dcrParameterNames -contains 'DataFlows') {
                    $dcrParams.DataFlows = $dataFlows
                }
                elseif ($dcrParameterNames -contains 'DataFlow') {
                    $dcrParams.DataFlow = $dataFlows
                }
            }

            if ($PSCmdlet.ShouldProcess($ServerName, "Create Data Collection Rule")) {
                $dcr = New-AzDataCollectionRule @dcrParams
                $dcrState.Changes += @{
                    Action = "Create"
                    RuleId = $dcr.Id
                    Timestamp = Get-Date
                }

                # Associate DCR with server
                $associationParams = @{
                    TargetResourceId = $ServerName
                    AssociationName = "DCR-Association-$RuleType"
                    RuleId = $dcr.Id
                }
                $association = New-AzDataCollectionRuleAssociation @associationParams
                $dcrState.Changes += @{
                    Action = "Associate"
                    AssociationId = $association.Id
                    Timestamp = Get-Date
                }

                # Validate DCR
                $validation = Test-DataCollectionRule -RuleId $dcr.Id
                if (-not $validation.Success) {
                    throw "DCR validation failed: $($validation.Error)"
                }

                $dcrState.Status = "Success"
            }
        }
        catch {
            $dcrState.Status = "Failed"
            $dcrState.Error = $_.Exception.Message
            Write-Warning "Failed to configure data collection rules: $($_.Exception.Message)"
        }
    }

    end {
        return [PSCustomObject]$dcrState
    }
}

function ConvertTo-ArraySafe {
    [CmdletBinding()]
    param([Parameter()][object]$Value)

    if ($null -eq $Value) {
        return @()
    }

    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) {
        return @()
    }

    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string]) -and -not ($Value -is [System.Collections.IDictionary])) {
        return @($Value)
    }

    if ($Value.PSObject.Properties.Count -eq 0) {
        return @()
    }

    return @($Value)
}

function ConvertTo-HashtableSafe {
    [CmdletBinding()]
    param([Parameter()][object]$Value)

    if ($null -eq $Value) {
        return @{}
    }

    if ($Value -is [System.Collections.IDictionary]) {
        return @{} + $Value
    }

    $result = @{}
    foreach ($property in $Value.PSObject.Properties) {
        $result[$property.Name] = $property.Value
    }

    return $result
}
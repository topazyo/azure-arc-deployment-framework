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

        # Load default configurations
        $defaultConfigs = Get-Content ".\Config\dcr-templates.json" | ConvertFrom-Json
    }

    process {
        try {
            # Select base configuration
            $baseConfig = switch ($RuleType) {
                'Security' { $defaultConfigs.security }
                'Performance' { $defaultConfigs.performance }
                'Custom' { $CustomConfig }
            }

            # Create DCR
            $dcrParams = @{
                Name = "DCR-$ServerName-$RuleType"
                ResourceGroup = $baseConfig.resourceGroup
                Location = $baseConfig.location
                DataSources = $baseConfig.dataSources
                Destinations = @{
                    LogAnalytics = @(
                        @{
                            WorkspaceResourceId = $WorkspaceId
                            Name = "LA-Destination"
                        }
                    )
                }
                DataFlows = @(
                    @{
                        Streams = $baseConfig.streams
                        Destinations = @("LA-Destination")
                    }
                )
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
            Write-Error $_
        }
    }

    end {
        return [PSCustomObject]$dcrState
    }
}
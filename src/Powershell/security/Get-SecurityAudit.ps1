function Get-SecurityAudit {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [string]$WorkspaceId,
        [Parameter()]
        [int]$DaysToAudit = 7
    )

    begin {
        $auditResults = @{
            ServerName = $ServerName
            StartTime = Get-Date
            AuditPeriod = $DaysToAudit
            Findings = @()
            Summary = @{
                CriticalIssues = 0
                HighIssues = 0
                MediumIssues = 0
                LowIssues = 0
            }
        }
    }

    process {
        try {
            # Audit Security Events
            $securityEvents = Get-SecurityEvents -ServerName $ServerName -Days $DaysToAudit
            $auditResults.SecurityEvents = Analyze-SecurityEvents -Events $securityEvents

            # Audit Configuration Changes
            $configChanges = Get-ConfigurationChanges -ServerName $ServerName -Days $DaysToAudit
            $auditResults.ConfigurationChanges = Analyze-ConfigurationChanges -Changes $configChanges

            # Audit Access Attempts
            $accessAttempts = Get-AccessAttempts -ServerName $ServerName -Days $DaysToAudit
            $auditResults.AccessAttempts = Analyze-AccessAttempts -Attempts $accessAttempts

            # If workspace provided, audit Log Analytics data
            if ($WorkspaceId) {
                $laAudit = Get-LogAnalyticsAudit -ServerName $ServerName -WorkspaceId $WorkspaceId -Days $DaysToAudit
                $auditResults.LogAnalytics = $laAudit
            }

            # Calculate Risk Score
            $auditResults.RiskScore = Calculate-SecurityRiskScore -Findings $auditResults.Findings

            # Generate Recommendations
            $auditResults.Recommendations = Get-SecurityRecommendations -Findings $auditResults.Findings
        }
        catch {
            Write-Error "Security audit failed: $_"
            $auditResults.Error = $_.Exception.Message
        }
    }

    end {
        return [PSCustomObject]$auditResults
    }
}
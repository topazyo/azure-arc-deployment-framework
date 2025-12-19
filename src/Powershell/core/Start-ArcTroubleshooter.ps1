function Start-ArcTroubleshooter {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [string]$WorkspaceId,
        [Parameter()]
        [switch]$AutoRemediate,
        [Parameter()]
        [switch]$DetailedAnalysis,
        [Parameter()]
        [string]$OutputPath = "./Logs",
        [Parameter()]
        [string]$DriftBaselinePath
    )

    begin {
        $troubleshootingSession = @{
            SessionId = [guid]::NewGuid().ToString()
            ServerName = $ServerName
            StartTime = Get-Date
            Status = "Starting"
            Components = @()
            Remediation = @()
        }

        # Start logging
        $logPath = Join-Path $OutputPath "ArcTroubleshooting_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
        Start-Transcript -Path $logPath
        Write-Verbose "Starting troubleshooting session $($troubleshootingSession.SessionId)"
    }

    process {
        try {
            # 1. Initial System State
            Write-Progress -Activity "Arc Troubleshooter" -Status "Collecting System State" -PercentComplete 10
            $systemState = Get-SystemState -ServerName $ServerName
            $troubleshootingSession.Components += @{
                Phase = "SystemState"
                Data = $systemState
                Timestamp = Get-Date
            }

            # 2. Arc Agent Diagnostics
            Write-Progress -Activity "Arc Troubleshooter" -Status "Arc Agent Diagnostics" -PercentComplete 30
            $arcDiagnostics = Start-ArcDiagnostics -ServerName $ServerName -DetailedScan:$DetailedAnalysis
            $troubleshootingSession.Components += @{
                Phase = "ArcDiagnostics"
                Data = $arcDiagnostics
                Timestamp = Get-Date
            }

            # 2b. Configuration Drift (optional baseline)
            Write-Progress -Activity "Arc Troubleshooter" -Status "Configuration Drift" -PercentComplete 40
            $driftParams = @{ ServerName = $ServerName }
            if (-not [string]::IsNullOrWhiteSpace($DriftBaselinePath)) { $driftParams.BaselinePath = $DriftBaselinePath }
            $driftReport = Test-ConfigurationDrift @driftParams
            $troubleshootingSession.Components += @{
                Phase = "ConfigurationDrift"
                Data = $driftReport
                Timestamp = Get-Date
            }

            # 3. AMA Diagnostics (if workspace provided)
            if ($WorkspaceId) {
                Write-Progress -Activity "Arc Troubleshooter" -Status "AMA Diagnostics" -PercentComplete 50
                $amaDiagnostics = Start-AMADiagnostics -ServerName $ServerName -WorkspaceId $WorkspaceId
                $troubleshootingSession.Components += @{
                    Phase = "AMADiagnostics"
                    Data = $amaDiagnostics
                    Timestamp = Get-Date
                }
            }

            # 4. Analysis
            Write-Progress -Activity "Arc Troubleshooter" -Status "Analyzing Results" -PercentComplete 70
            $analysis = Invoke-TroubleshootingAnalysis -Data $troubleshootingSession.Components
            $troubleshootingSession.Analysis = $analysis

            # 5. Remediation (if enabled)
            if ($AutoRemediate) {
                Write-Progress -Activity "Arc Troubleshooter" -Status "Performing Remediation" -PercentComplete 85
                foreach ($issue in $analysis.Issues) {
                    $remediation = Start-IssueRemediation -Issue $issue -ServerName $ServerName
                    $troubleshootingSession.Remediation += $remediation
                }
            }

            # 6. Final Validation
            Write-Progress -Activity "Arc Troubleshooter" -Status "Final Validation" -PercentComplete 95
            $finalValidation = Test-DeploymentHealth -ServerName $ServerName -ValidateAMA:($null -ne $WorkspaceId)
            $troubleshootingSession.FinalState = $finalValidation

            $troubleshootingSession.Status = "Completed"
        }
        catch {
            $troubleshootingSession.Status = "Failed"
            $troubleshootingSession.Error = @{
                Message = $_.Exception.Message
                Details = $_.Exception.StackTrace
                Timestamp = Get-Date
            }
            Write-Error $_
        }
    }

    end {
        # Generate detailed report
        $report = New-TroubleshootingReport -Session $troubleshootingSession
        $reportPath = Join-Path $OutputPath "TroubleshootingReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
        $report | ConvertTo-Json -Depth 10 | Out-File $reportPath

        Stop-Transcript
        return [PSCustomObject]$troubleshootingSession
    }
}
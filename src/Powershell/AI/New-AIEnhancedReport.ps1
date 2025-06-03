# New-AIEnhancedReport.ps1
# This script generates an AI-enhanced report based on diagnostic, AI analysis, and remediation data.
# TODO: Implement more sophisticated summarization of input data.
# TODO: Add support for other ReportFormat types like HTML, XML.

Function New-AIEnhancedReport {
    [CmdletBinding(SupportsShouldProcess = $true)] # For -WhatIf on Out-File
    param (
        [Parameter(Mandatory=$false)]
        [object]$DiagnosticsData,

        [Parameter(Mandatory=$false)]
        [object]$AIInsights,

        [Parameter(Mandatory=$false)]
        [object]$RemediationResults,

        [Parameter(Mandatory=$false)]
        [string]$ServerName = $env:COMPUTERNAME,

        [Parameter(Mandatory=$false)]
        [ValidateSet("PSCustomObject", "JSON", "HTML", "XML")] # HTML, XML are future
        [string]$ReportFormat = "PSCustomObject",

        [Parameter(Mandatory=$false)]
        [string]$OutputPath, # If provided, report is exported here

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\NewAIEnhancedReport_Activity.log"
    )

    # --- Logging Function (for script activity) ---
    function Write-Log {
        param (
            [string]$Message,
            [string]$Level = "INFO", # INFO, WARNING, ERROR, DEBUG
            [string]$Path = $LogPath
        )
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$Level] $Message"

        try {
            if (-not (Test-Path (Split-Path $Path -Parent) -PathType Container)) {
                New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force -ErrorAction Stop | Out-Null
            }
            Add-Content -Path $Path -Value $logEntry -ErrorAction Stop
        }
        catch {
            Write-Warning "ACTIVITY_LOG_FAIL: Failed to write to activity log file $Path. Error: $($_.Exception.Message). Logging to console instead."
            Write-Host $logEntry
        }
    }

    Write-Log "Starting New-AIEnhancedReport script."
    Write-Log "Parameters: ServerName='$ServerName', ReportFormat='$ReportFormat', OutputPath='$OutputPath'."
    if ($DiagnosticsData) { Write-Log "DiagnosticsData provided." -Level "DEBUG" }
    if ($AIInsights) { Write-Log "AIInsights provided." -Level "DEBUG" }
    if ($RemediationResults) { Write-Log "RemediationResults provided." -Level "DEBUG" }

    # --- Root Report Object ---
    $report = [PSCustomObject]@{
        ReportTimestamp  = (Get-Date -Format o)
        ServerName       = $ServerName
        FrameworkVersion = "1.0.0" # Hardcoded for now
        ExecutiveSummary = "Pending Analysis" # Will be updated
        Sections         = [PSCustomObject]@{}
    }

    # --- Diagnostics Summary Section ---
    if ($DiagnosticsData) {
        Write-Log "Adding Diagnostics Summary section."
        $diagSummary = @{}
        # Basic summarization - V1 embeds or takes top-level known properties
        if ($DiagnosticsData.PSObject.Properties['OverallHealthStatus']) {
            $diagSummary.OverallHealthStatus = $DiagnosticsData.OverallHealthStatus
        }
        if ($DiagnosticsData.PSObject.Properties['TotalErrorsFound']) {
            $diagSummary.TotalErrorsFound = $DiagnosticsData.TotalErrorsFound
        }
        if ($DiagnosticsData.PSObject.Properties['TotalWarningsFound']) {
            $diagSummary.TotalWarningsFound = $DiagnosticsData.TotalWarningsFound
        }
        # For V1, include the raw data if it's not too large, or specific parts.
        # This assumes $DiagnosticsData might be a summary object itself.
        $diagSummary.FullDiagnosticsOutput = $DiagnosticsData # Or specific sub-properties
        $report.Sections.DiagnosticsSummary = [PSCustomObject]$diagSummary
    } else {
        Write-Log "No DiagnosticsData provided, skipping DiagnosticsSummary section."
    }

    # --- AI Insights Summary Section ---
    if ($AIInsights) {
        Write-Log "Adding AI Insights Summary section."
        $aiSummary = @{}
        # Assumes $AIInsights might be a hashtable or PSCustomObject with keys like PatternsFound, PredictionsMade, RecommendationsProvided
        if ($AIInsights.PSObject.Properties['PatternsFound']) {
            $aiSummary.PatternsFound = $AIInsights.PatternsFound
        }
        if ($AIInsights.PSObject.Properties['PredictionsMade']) {
            $aiSummary.PredictionsMade = $AIInsights.PredictionsMade
        }
        if ($AIInsights.PSObject.Properties['RecommendationsProvided']) {
            $aiSummary.RecommendationsProvided = $AIInsights.RecommendationsProvided
        }
        # If $AIInsights is just the direct array from a script, assign it
        if ($AIInsights -is [array] -and $aiSummary.Keys.Count -eq 0) {
             $aiSummary.DirectAIOutput = $AIInsights
        } elseif ($aiSummary.Keys.Count -eq 0) { # If no known properties found, embed the whole object
             $aiSummary.FullAIInsightsData = $AIInsights
        }
        $report.Sections.AISummary = [PSCustomObject]$aiSummary
    } else {
        Write-Log "No AIInsights provided, skipping AISummary section."
    }

    # --- Remediation Summary Section ---
    if ($RemediationResults) {
        Write-Log "Adding Remediation Summary section."
        $remSummary = @{}
        # Assumes $RemediationResults might be the summary object from Start-AIRemediationWorkflow.ps1
        if ($RemediationResults.PSObject.Properties['OverallStatus']) {
            $remSummary.OverallRemediationStatus = $RemediationResults.OverallStatus
        }
        if ($RemediationResults.PSObject.Properties['RemediationsAttempted']) {
            $remSummary.RemediationsAttemptedSummary = $RemediationResults.RemediationsAttempted | ForEach-Object {
                "Action '$($_.RecommendationTitle)' (ID: $($_.RecommendationId)) - Status: $($_.Status)"
            }
            $remSummary.FullRemediationOutput = $RemediationResults
        } elseif ($RemediationResults -is [array]) { # If it's an array of action results
            $remSummary.RemediationActions = $RemediationResults
        } else {
            $remSummary.FullRemediationOutput = $RemediationResults
        }
        $report.Sections.RemediationSummary = [PSCustomObject]$remSummary
    } else {
        Write-Log "No RemediationResults provided, skipping RemediationSummary section."
    }

    # --- Update Executive Summary (Simple Logic for V1) ---
    $summaryParts = @()
    if ($report.Sections.DiagnosticsSummary) { $summaryParts.Add("Diagnostics run") }
    if ($report.Sections.AISummary) { $summaryParts.Add("AI analysis performed") }
    if ($report.Sections.RemediationSummary) { $summaryParts.Add("Remediation steps processed") }

    if ($summaryParts.Count -gt 0) {
        $report.ExecutiveSummary = ($summaryParts -join ", ") + "."
        if ($report.Sections.RemediationSummary.OverallRemediationStatus) {
            $report.ExecutiveSummary += " Remediation Overall Status: $($report.Sections.RemediationSummary.OverallRemediationStatus)."
        }
    } else {
        $report.ExecutiveSummary = "No data provided for reporting."
    }


    # --- Output/Export ---
    if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
        Write-Log "Attempting to export report to '$OutputPath'."
        $exportFormatToUse = $ReportFormat
        if ($ReportFormat -eq "PSCustomObject") {
            $exportFormatToUse = "JSON" # Default export to JSON if object is the format
            Write-Log "ReportFormat is PSCustomObject, defaulting export to JSON."
        }

        if ($PSCmdlet.ShouldProcess($OutputPath, "Export Report (Format: $exportFormatToUse)")) {
            try {
                # Ensure parent directory exists for OutputPath
                $OutputDirectory = Split-Path -Path $OutputPath -Parent
                if (-not (Test-Path -Path $OutputDirectory -PathType Container)) {
                    Write-Log "Creating directory for report output: $OutputDirectory"
                    New-Item -ItemType Directory -Path $OutputDirectory -Force -ErrorAction Stop | Out-Null
                }

                switch ($exportFormatToUse) {
                    "JSON" {
                        $report | ConvertTo-Json -Depth 10 | Out-File -FilePath $OutputPath -Encoding UTF8 -ErrorAction Stop
                        Write-Log "Report successfully exported as JSON to $OutputPath."
                    }
                    "XML" { # Using Export-CliXml for PowerShell-readable XML
                        $report | Export-Clixml -Path $OutputPath -Depth 10 -Encoding UTF8 -ErrorAction Stop
                        Write-Log "Report successfully exported as XML (CliXml) to $OutputPath."
                    }
                    "HTML" {
                        Write-Log "HTML report format is noted but full implementation is for future enhancement. Exporting basic structure." -Level "WARNING"
                        # Simple HTML export for V1 - can be greatly enhanced
                        $htmlHeader = "<!DOCTYPE html><html><head><title>AI Enhanced Report - $ServerName</title></head><body>"
                        $htmlFooter = "</body></html>"
                        $reportJsonForHtml = $report | ConvertTo-Json -Depth 10 # Easiest way to get a string representation
                        $htmlBody = "<h1>AI Enhanced Report for $ServerName</h1><h2>Report Timestamp: $($report.ReportTimestamp)</h2>"
                        $htmlBody += "<h2>Executive Summary</h2><pre>$($report.ExecutiveSummary)</pre>"
                        $htmlBody += "<h2>Full Report Data (JSON)</h2><pre>$($reportJsonForHtml | Out-String)</pre>" # Keep it simple

                        Set-Content -Path $OutputPath -Value ($htmlHeader + $htmlBody + $htmlFooter) -Encoding UTF8 -ErrorAction Stop
                        Write-Log "Report (basic structure) exported as HTML to $OutputPath."
                    }
                    default {
                        Write-Log "Unsupported ReportFormat '$ReportFormat' for export. Defaulting to returning object only." -Level "WARNING"
                    }
                }
            } catch {
                Write-Log "Failed to export report to '$OutputPath'. Error: $($_.Exception.Message)" -Level "ERROR"
            }
        } else {
            Write-Log "Export to '$OutputPath' skipped due to -WhatIf or user choice."
        }
    }

    Write-Log "New-AIEnhancedReport script finished."
    if ($ReportFormat -eq "PSCustomObject") {
        return $report
    } else {
        # If an export format was specified, the main output is the file.
        # Optionally, still return the object, or return status of export.
        # For now, just return the object if not PSCustomObject AND no OutputPath.
        if ([string]::IsNullOrWhiteSpace($OutputPath)) {
            Write-Log "No OutputPath specified, returning object directly (format '$ReportFormat' implies conversion if not PSCustomObject)."
            return $report
        }
        # If OutputPath was given, primary output is the file. Can also return $true or the path.
        Write-Log "Report generation for format '$ReportFormat' to path '$OutputPath' handled. Returning success status."
        return $true # Indicate export attempt was handled
    }
}

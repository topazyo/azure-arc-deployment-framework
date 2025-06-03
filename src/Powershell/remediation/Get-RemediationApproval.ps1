# Get-RemediationApproval.ps1
# This script handles the approval workflow for a single remediation action by prompting the user.
# TODO: Implement more robust timeout for Read-Host if strictly needed (e.g., using jobs or runspaces).
# TODO: Enhance "Details" option to show more specific information or toggle verbosity.

Function Get-RemediationApproval {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [PSCustomObject]$RemediationAction,

        [Parameter(Mandatory=$false)]
        [string]$ApprovalPromptMessage = "Please review the following remediation action and indicate your decision.",

        [Parameter(Mandatory=$false)]
        [int]$TimeoutSeconds = 0, # 0 means no timeout

        [Parameter(Mandatory=$false)]
        [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\GetRemediationApproval_Activity.log"
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

    Write-Log "Starting Get-RemediationApproval script."

    if (-not $RemediationAction -or -not $RemediationAction.PSObject.Properties['RemediationActionId']) {
        Write-Log "Input RemediationAction is null or invalid (missing RemediationActionId). Cannot proceed." -Level "ERROR"
        return [PSCustomObject]@{
            RemediationActionTitle = $RemediationAction.Title # Or "Unknown"
            ApprovalStatus         = "ErrorInvalidInput"
            Timestamp              = Get-Date -Format o
            Approver               = $env:USERNAME
            Comments               = "Invalid input RemediationAction object."
        }
    }
    Write-Log "Seeking approval for RemediationActionId: '$($RemediationAction.RemediationActionId)', Title: '$($RemediationAction.Title)'."

    # --- Display Action Details ---
    Write-Host "`n" # Newline for better readability
    Write-Host $ApprovalPromptMessage -ForegroundColor Yellow
    Write-Host ("-" * $ApprovalPromptMessage.Length) -ForegroundColor Yellow
    Write-Host "Action ID: $($RemediationAction.RemediationActionId)"
    Write-Host "Title: $($RemediationAction.Title)"
    Write-Host "Description: $($RemediationAction.Description)"
    Write-Host "Implementation Type: $($RemediationAction.ImplementationType)"
    if ($RemediationAction.TargetScriptPath) { Write-Host "Target Script: $($RemediationAction.TargetScriptPath)"}
    if ($RemediationAction.TargetFunction) { Write-Host "Target Function: $($RemediationAction.TargetFunction)"}
    if ($RemediationAction.ResolvedParameters -and $RemediationAction.ResolvedParameters.Count -gt 0) {
        Write-Host "Parameters:"
        $RemediationAction.ResolvedParameters.GetEnumerator() | ForEach-Object { Write-Host "  $($_.Name) = $($_.Value)" }
    }
    if ($RemediationAction.Impact) { Write-Host "Potential Impact: $($RemediationAction.Impact)" -ForegroundColor Magenta }
    Write-Host "Success Criteria: $($RemediationAction.SuccessCriteria)"
    Write-Host ("-" * $ApprovalPromptMessage.Length) -ForegroundColor Yellow

    if ($TimeoutSeconds -gt 0) {
        Write-Host "Please respond within $TimeoutSeconds seconds." -ForegroundColor Cyan
        Write-Log "User informed of $TimeoutSeconds second response window (timeout not strictly enforced by Read-Host)."
        # Actual timeout enforcement with Read-Host is complex and not implemented here.
    }

    # --- Prompt Loop ---
    $userResponse = $null
    $approvalStatus = "Pending"

    while ($true) {
        try {
            $prompt = "Approve this action? (Yes/No/Details/Quit) [Y/N/D/Q] (Default: N): "
            $userResponse = Read-Host -Prompt $prompt
            Write-Log "User prompt: '$prompt', User response: '$userResponse'."

            switch -Regex ($userResponse.Trim().ToUpper()) {
                "^(Y|YES)$" { $approvalStatus = "Approved"; break }
                "^(N|NO)$"  { $approvalStatus = "Denied"; break }
                ""          { $approvalStatus = "Denied"; Write-Log "Empty response, defaulted to Denied."; break } # Default on Enter
                "D"         {
                    Write-Log "User requested more details."
                    Write-Host "`n--- Detailed Remediation Action Information ---"
                    Write-Host ($RemediationAction | Format-List * | Out-String)
                    Write-Host "--- End of Details ---`n"
                    # Re-display initial summary too for context before re-prompting
                    Write-Host $ApprovalPromptMessage -ForegroundColor Yellow
                    Write-Host ("-" * $ApprovalPromptMessage.Length) -ForegroundColor Yellow
                    Write-Host "Action ID: $($RemediationAction.RemediationActionId)"; Write-Host "Title: $($RemediationAction.Title)"
                    # (Could re-display all summary info from above)
                    continue # Re-loop to prompt again
                }
                "Q"         { $approvalStatus = "UserQuit"; break }
                default     { Write-Host "Invalid input. Please enter Y, N, D, or Q." -ForegroundColor Red }
            }
        } catch {
             Write-Log "Error during user prompt: $($_.Exception.Message)" -Level "ERROR"
             $approvalStatus = "ErrorPromptFailed" # Or handle as Denied
             break
        }
    }

    $resultTimestamp = Get-Date -Format o
    Write-Log "Approval process completed. Status: '$approvalStatus'."

    $output = [PSCustomObject]@{
        RemediationActionTitle = $RemediationAction.Title
        RemediationActionId    = $RemediationAction.RemediationActionId
        ApprovalStatus         = $approvalStatus
        Timestamp              = $resultTimestamp
        Approver               = $env:USERNAME # Or (Get-CimInstance Win32_ComputerSystem).Username if script runs as system
        Comments               = "" # Placeholder
    }

    Write-Log "Get-RemediationApproval script finished."
    return $output
}

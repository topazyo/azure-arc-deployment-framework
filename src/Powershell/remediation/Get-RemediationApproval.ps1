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
    function Write-ActivityLog {
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
            Write-Verbose $logEntry
        }
    }

    function Write-ApprovalDisplay {
        param(
            [string]$Message = "",
            [System.ConsoleColor]$ForegroundColor
        )

        if (-not $Host -or -not $Host.UI) {
            Write-Information $Message -InformationAction Continue
            return
        }

        if (-not $PSBoundParameters.ContainsKey('ForegroundColor')) {
            $Host.UI.WriteLine($Message)
            return
        }

        $rawUi = $Host.UI.RawUI
        $originalColor = $rawUi.ForegroundColor
        try {
            $rawUi.ForegroundColor = $ForegroundColor
            $Host.UI.WriteLine($Message)
        }
        finally {
            $rawUi.ForegroundColor = $originalColor
        }
    }

    function Show-ApprovalSummary {
        param(
            [Parameter(Mandatory = $true)]
            [PSCustomObject]$Action,

            [Parameter(Mandatory = $true)]
            [string]$PromptMessage
        )

        Write-ApprovalDisplay ""
        Write-ApprovalDisplay $PromptMessage -ForegroundColor Yellow
        Write-ApprovalDisplay ("-" * $PromptMessage.Length) -ForegroundColor Yellow
        Write-ApprovalDisplay "Action ID: $($Action.RemediationActionId)"
        Write-ApprovalDisplay "Title: $($Action.Title)"
        Write-ApprovalDisplay "Description: $($Action.Description)"
        Write-ApprovalDisplay "Implementation Type: $($Action.ImplementationType)"
        if ($Action.TargetScriptPath) { Write-ApprovalDisplay "Target Script: $($Action.TargetScriptPath)" }
        if ($Action.TargetFunction) { Write-ApprovalDisplay "Target Function: $($Action.TargetFunction)" }
        if ($Action.ResolvedParameters -and $Action.ResolvedParameters.Count -gt 0) {
            Write-ApprovalDisplay "Parameters:"
            $Action.ResolvedParameters.GetEnumerator() | ForEach-Object { Write-ApprovalDisplay "  $($_.Name) = $($_.Value)" }
        }
        if ($Action.Impact) { Write-ApprovalDisplay "Potential Impact: $($Action.Impact)" -ForegroundColor Magenta }
        Write-ApprovalDisplay "Success Criteria: $($Action.SuccessCriteria)"
        Write-ApprovalDisplay ("-" * $PromptMessage.Length) -ForegroundColor Yellow
    }

    Write-ActivityLog "Starting Get-RemediationApproval script."

    if (-not $RemediationAction -or -not $RemediationAction.PSObject.Properties['RemediationActionId']) {
        Write-ActivityLog "Input RemediationAction is null or invalid (missing RemediationActionId). Cannot proceed." -Level "ERROR"
        return [PSCustomObject]@{
            RemediationActionTitle = $RemediationAction.Title # Or "Unknown"
            ApprovalStatus         = "ErrorInvalidInput"
            Timestamp              = Get-Date -Format o
            Approver               = $env:USERNAME
            Comments               = "Invalid input RemediationAction object."
        }
    }
    Write-ActivityLog "Seeking approval for RemediationActionId: '$($RemediationAction.RemediationActionId)', Title: '$($RemediationAction.Title)'."

    # --- Display Action Details ---
    Show-ApprovalSummary -Action $RemediationAction -PromptMessage $ApprovalPromptMessage

    if ($TimeoutSeconds -gt 0) {
        Write-ApprovalDisplay "Please respond within $TimeoutSeconds seconds." -ForegroundColor Cyan
        Write-ActivityLog "User informed of $TimeoutSeconds second response window (timeout not strictly enforced by Read-Host)."
        # Actual timeout enforcement with Read-Host is complex and not implemented here.
    }

    # --- Prompt Loop ---
    $userResponse = $null
    $approvalStatus = "Pending"

    while ($true) {
        try {
            $prompt = "Approve this action? (Yes/No/Details/Quit) [Y/N/D/Q] (Default: N): "
            $userResponse = Read-Host -Prompt $prompt
            Write-ActivityLog "User prompt: '$prompt', User response: '$userResponse'."

            switch -Regex ($userResponse.Trim().ToUpper()) {
                "^(Y|YES)$" { $approvalStatus = "Approved"; break }
                "^(N|NO)$"  { $approvalStatus = "Denied"; break }
                ""          { $approvalStatus = "Denied"; Write-ActivityLog "Empty response, defaulted to Denied."; break } # Default on Enter
                "D"         {
                    Write-ActivityLog "User requested more details."
                    Write-ApprovalDisplay ""
                    Write-ApprovalDisplay "--- Detailed Remediation Action Information ---"
                    Write-ApprovalDisplay ($RemediationAction | Format-List * | Out-String)
                    Write-ApprovalDisplay "--- End of Details ---"
                    # Re-display initial summary too for context before re-prompting
                    Show-ApprovalSummary -Action $RemediationAction -PromptMessage $ApprovalPromptMessage
                    continue # Re-loop to prompt again
                }
                "Q"         { $approvalStatus = "UserQuit"; break }
                default     { Write-ApprovalDisplay "Invalid input. Please enter Y, N, D, or Q." -ForegroundColor Red }
            }
            if ($approvalStatus -ne 'Pending') { break }
        } catch {
             Write-ActivityLog "Error during user prompt: $($_.Exception.Message)" -Level "ERROR"
             $approvalStatus = "ErrorPromptFailed" # Or handle as Denied
             break
        }
    }

    $resultTimestamp = Get-Date -Format o
    Write-ActivityLog "Approval process completed. Status: '$approvalStatus'."

    $output = [PSCustomObject]@{
        RemediationActionTitle = $RemediationAction.Title
        RemediationActionId    = $RemediationAction.RemediationActionId
        ApprovalStatus         = $approvalStatus
        Timestamp              = $resultTimestamp
        Approver               = $env:USERNAME # Or (Get-CimInstance Win32_ComputerSystem).Username if script runs as system
        Comments               = "" # Placeholder
    }

    Write-ActivityLog "Get-RemediationApproval script finished."
    return $output
}

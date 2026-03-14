<#
.SYNOPSIS
Executes a script block with retry logic.

.DESCRIPTION
Runs the supplied script block, retries when the thrown error matches one of the
configured retryable patterns, and returns a structured object containing success,
attempt count, last error, result, and duration information.

.PARAMETER ScriptBlock
Script block to execute.

.PARAMETER RetryCount
Maximum number of attempts.

.PARAMETER RetryDelaySeconds
Delay between retry attempts.

.PARAMETER RetryableErrorPatterns
Error-message patterns treated as retryable.

.PARAMETER OnRetry
Optional callback invoked before each retry.

.PARAMETER ExponentialBackoff
Uses exponential backoff instead of a fixed retry delay.

.OUTPUTS
PSCustomObject

.EXAMPLE
New-RetryBlock -ScriptBlock { Test-NetConnection -ComputerName 'management.azure.com' -Port 443 } -RetryCount 3 -ExponentialBackoff
#>
function New-RetryBlock {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [Alias('Action')]
        [scriptblock]$ScriptBlock,
        [Parameter()]
        [int]$RetryCount = 3,
        [Parameter()]
        [int]$RetryDelaySeconds = 30,
        [Parameter()]
        [string[]]$RetryableErrorPatterns = @(
            "timeout",
            "connection refused",
            "network error",
            "temporarily unavailable"
        ),
        [Parameter()]
        [scriptblock]$OnRetry,
        [Parameter()]
        [switch]$ExponentialBackoff
    )

    $attempt = 1
    $result = @{
        Success = $false
        Attempts = 0
        LastError = $null
        Result = $null
        Duration = [TimeSpan]::Zero
    }

    $startTime = Get-Date

    do {
        try {
            Write-Verbose "Attempt $attempt of $RetryCount"
            if (-not $PSCmdlet.ShouldProcess("retryable script block", "Execute retry attempt $attempt")) {
                $result.Attempts = $attempt - 1
                $result.Duration = (Get-Date) - $startTime
                return [PSCustomObject]$result
            }
            $result.Result = & $ScriptBlock
            $result.Success = $true
            break
        }
        catch {
            $caughtError = $_ # Changed from $error to $caughtError
            $result.LastError = $caughtError # Changed from $error to $caughtError
            $result.Attempts = $attempt

            $isRetryable = $false
            foreach ($pattern in $RetryableErrorPatterns) {
                if ($caughtError.Exception.Message -match $pattern) { # Changed from $error to $caughtError
                    $isRetryable = $true
                    break
                }
            }

            if (-not $isRetryable) {
                Write-Warning "Non-retryable error encountered: $caughtError" # Changed from $error to $caughtError
                break
            }

            if ($attempt -lt $RetryCount) {
                $delay = if ($ExponentialBackoff) {
                    [math]::Pow(2, $attempt - 1) * $RetryDelaySeconds
                } else {
                    $RetryDelaySeconds
                }

                Write-Warning "Attempt $attempt failed. Retrying in $delay seconds..."
                Write-Log -Message "Retry attempt $attempt failed: $caughtError" -Level Warning -Component 'RetryBlock' # Changed from $error to $caughtError

                if ($OnRetry) {
                    & $OnRetry $attempt $caughtError # Changed from $error to $caughtError
                }

                Start-Sleep -Seconds $delay
                $attempt++
            }
            else {
                Write-Warning "All retry attempts failed. Last error: $caughtError" # Changed from $error to $caughtError
                break
            }
        }
    } while ($attempt -le $RetryCount)

    $result.Duration = (Get-Date) - $startTime
    return [PSCustomObject]$result
}
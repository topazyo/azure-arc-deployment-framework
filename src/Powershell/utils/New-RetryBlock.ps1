function New-RetryBlock {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
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
                Write-Error "All retry attempts failed. Last error: $caughtError" # Changed from $error to $caughtError
                break
            }
        }
    } while ($attempt -le $RetryCount)

    $result.Duration = (Get-Date) - $startTime
    return [PSCustomObject]$result
}
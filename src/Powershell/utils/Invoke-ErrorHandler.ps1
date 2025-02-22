function Invoke-ErrorHandler {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter()]
        [string]$Context,
        [Parameter()]
        [hashtable]$HandlerConfig = @{},
        [Parameter()]
        [switch]$ThrowException
    )

    begin {
        $handlerResult = @{
            Timestamp = Get-Date
            Context = $Context
            ErrorHandled = $false
            Actions = @()
        }

        Write-Log -Message "Error handler invoked for context: $Context" -Level Information
    }

    process {
        try {
            # Convert error to structured format
            $errorInfo = Convert-ErrorToObject -ErrorRecord $ErrorRecord -IncludeStackTrace -IncludeInnerException

            # Add to handler result
            $handlerResult.ErrorInfo = $errorInfo

            # Check for known error patterns
            $pattern = Find-ErrorPattern -Error $errorInfo -Patterns $HandlerConfig.Patterns
            if ($pattern) {
                $handlerResult.Pattern = $pattern
                
                # Execute pattern-specific handler
                if ($pattern.Handler) {
                    $handlerAction = & $pattern.Handler -Error $errorInfo
                    $handlerResult.Actions += @{
                        Type = "PatternHandler"
                        Pattern = $pattern.Name
                        Result = $handlerAction
                    }
                }
            }

            # Execute general error handling steps
            foreach ($step in $HandlerConfig.GeneralSteps) {
                $stepResult = & $step -Error $errorInfo
                $handlerResult.Actions += @{
                    Type = "GeneralHandler"
                    Step = $step.Name
                    Result = $stepResult
                }
            }

            # Log error details
            Write-Log -Message "Error details: $($errorInfo.Message)" -Level Error
            Write-Log -Message "Stack trace: $($errorInfo.StackTrace)" -Level Debug

            # Determine if error was handled
            $handlerResult.ErrorHandled = $handlerResult.Actions | 
                Where-Object { $_.Result.Success } | 
                Select-Object -First 1

            if (-not $handlerResult.ErrorHandled -and $ThrowException) {
                throw $ErrorRecord
            }
        }
        catch {
            Write-Error "Error handler failed: $_"
            Write-Log -Message "Error handler failed: $_" -Level Error
            if ($ThrowException) {
                throw
            }
        }
    }

    end {
        $handlerResult.EndTime = Get-Date
        return [PSCustomObject]$handlerResult
    }
}

function Find-ErrorPattern {
    param (
        [Parameter(Mandatory)]
        [object]$ErrorObj,
        [Parameter()]
        [array]$Patterns
    )

    foreach ($pattern in $Patterns) {
        if ($ErrorObj.Message -match $pattern.Pattern -or 
            $ErrorObj.Exception.GetType().Name -eq $pattern.ExceptionType) {
            return $pattern
        }
    }

    return $null
}
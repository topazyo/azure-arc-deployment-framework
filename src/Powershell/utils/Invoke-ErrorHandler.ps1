<#
.SYNOPSIS
Runs the framework’s canonical structured error-handling workflow.

.DESCRIPTION
Converts an ErrorRecord into a structured object, optionally matches it against
known patterns, runs configured general handling steps, writes log output, and can
rethrow the original error when the caller requires a terminating failure.

.PARAMETER ErrorRecord
Error record to process.

.PARAMETER Context
Context string identifying the calling function or workflow.

.PARAMETER HandlerConfig
Pattern and general-step configuration used during handling.

.PARAMETER ThrowException
Rethrows the original error after handler execution when set.

.OUTPUTS
PSCustomObject

.EXAMPLE
Invoke-ErrorHandler -ErrorRecord $_ -Context 'Start-ArcTroubleshooter' -ThrowException

.NOTES
Preferred catch-block pattern for ordinary exported functions remains:
`Write-Log -Message "Operation failed: $($_.Exception.Message)" -Level Error -Component 'FunctionName'`
followed by `Write-Error -ErrorRecord $_`.
#>
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
        function Get-ErrorInfoFallback {
            param(
                [Parameter(Mandatory)]
                [System.Management.Automation.ErrorRecord]$SourceError
            )

            [PSCustomObject]@{
                Message = $SourceError.Exception.Message
                ErrorId = $SourceError.FullyQualifiedErrorId
                Category = if ($SourceError.CategoryInfo) { $SourceError.CategoryInfo.Category } else { 'NotSpecified' }
                StackTrace = $SourceError.ScriptStackTrace
            }
        }

        $handlerResult = @{
            Timestamp = Get-Date
            Context = $Context
            ErrorHandled = $false
            Actions = @()
            ErrorInfo = Get-ErrorInfoFallback -SourceError $ErrorRecord
        }

        $patterns = @($HandlerConfig['Patterns'])
        $generalSteps = @($HandlerConfig['GeneralSteps'])

        Write-Log -Message "Error handler invoked for context: $Context" -Level Information
    }

    process {
        try {
            # Convert error to structured format
            $errorInfo = Convert-ErrorToObject -ErrorRecord $ErrorRecord -IncludeStackTrace -IncludeInnerException
            if (-not $errorInfo -or -not $errorInfo.PSObject.Properties['Message'] -or [string]::IsNullOrWhiteSpace([string]$errorInfo.Message)) {
                $errorInfo = Get-ErrorInfoFallback -SourceError $ErrorRecord
            }

            # Add to handler result
            $handlerResult['ErrorInfo'] = if ($errorInfo) { $errorInfo } else { $handlerResult['ErrorInfo'] }

            # Check for known error patterns
            $pattern = Find-ErrorPattern -ErrorObj $handlerResult['ErrorInfo'] -Patterns $patterns
            if ($pattern) {
                $handlerResult['Pattern'] = $pattern

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
            foreach ($step in $generalSteps) {
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
            if (-not $handlerResult['ErrorInfo'] -or -not $handlerResult['ErrorInfo'].PSObject.Properties['Message'] -or [string]::IsNullOrWhiteSpace([string]$handlerResult['ErrorInfo'].Message)) {
                $handlerResult['ErrorInfo'] = Get-ErrorInfoFallback -SourceError $ErrorRecord
            }
            Write-Log -Message "Invoke-ErrorHandler itself failed: $($_.Exception.Message)" -Level Error -Component 'Invoke-ErrorHandler'
            if ($ThrowException) {
                throw
            }
        }
    }

    end {
        if (-not $handlerResult['ErrorInfo'] -or -not $handlerResult['ErrorInfo'].PSObject.Properties['Message'] -or [string]::IsNullOrWhiteSpace([string]$handlerResult['ErrorInfo'].Message)) {
            $handlerResult['ErrorInfo'] = Get-ErrorInfoFallback -SourceError $ErrorRecord
        }
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
        # $ErrorObj is a PSCustomObject from Convert-ErrorToObject (has Message, ErrorId, Category).
        # Use ErrorId (FullyQualifiedErrorId) for exception-type matching — it commonly embeds the type name.
        $messageMatch = $pattern.Pattern -and ($ErrorObj.Message -match $pattern.Pattern)
        $typeMatch = $pattern.ExceptionType -and ($ErrorObj.ErrorId -like "*$($pattern.ExceptionType)*")
        if ($messageMatch -or $typeMatch) {
            return $pattern
        }
    }

    return $null
}
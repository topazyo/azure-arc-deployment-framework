#
# Invoke-ErrorHandler — Canonical error handling utility for the Azure Arc Framework.
#
# STANDARD CATCH BLOCK PATTERN (use in all exported functions):
#
#   catch {
#       Write-Log -Message "Operation failed: $($_.Exception.Message)" -Level Error -Component 'FunctionName'
#       Write-Error -ErrorRecord $_
#   }
#
# Use -ThrowException to re-throw after logging (for functions that must propagate terminating errors):
#
#   catch {
#       Invoke-ErrorHandler -ErrorRecord $_ -Context 'FunctionName' -ThrowException
#   }
#
# NEVER use:
#   Write-Error "$_"             ← stringifies the ErrorRecord, loses category/invocation info
#   Write-Error -Exception $_.Exception  ← loses category, ErrorId, and TargetObject
#   throw "string message"       ← non-structured; use $PSCmdlet.ThrowTerminatingError() instead
#
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
            Write-Log -Message "Invoke-ErrorHandler itself failed: $($_.Exception.Message)" -Level Error -Component 'Invoke-ErrorHandler'
            Write-Error -ErrorRecord $_
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
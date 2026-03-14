<#
.SYNOPSIS
Converts an ErrorRecord into a structured PowerShell object.

.DESCRIPTION
Extracts message, category, error ID, invocation details, and optional stack or
inner-exception information from an ErrorRecord so callers can log or persist a
consistent error shape.

.PARAMETER ErrorRecord
PowerShell error record to convert.

.PARAMETER IncludeStackTrace
Includes the exception stack trace in the output object.

.PARAMETER IncludeInnerException
Includes nested exception information when present.

.OUTPUTS
PSCustomObject

.EXAMPLE
$errorRecord | Convert-ErrorToObject -IncludeStackTrace
#>
function Convert-ErrorToObject {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [Parameter()]
        [switch]$IncludeStackTrace,
        [Parameter()]
        [switch]$IncludeInnerException
    )

    process {
        $errorObject = @{
            Timestamp = Get-Date
            Message = $ErrorRecord.Exception.Message
            Category = $ErrorRecord.CategoryInfo.Category
            ErrorId = $ErrorRecord.FullyQualifiedErrorId
            InvocationInfo = @{
                ScriptName = $ErrorRecord.InvocationInfo.ScriptName
                ScriptLineNumber = $ErrorRecord.InvocationInfo.ScriptLineNumber
                Line = $ErrorRecord.InvocationInfo.Line
                PositionMessage = $ErrorRecord.InvocationInfo.PositionMessage
            }
            TargetObject = $ErrorRecord.TargetObject
        }

        if ($IncludeStackTrace) {
            $errorObject.StackTrace = $ErrorRecord.Exception.StackTrace
        }

        if ($IncludeInnerException -and $ErrorRecord.Exception.InnerException) {
            $errorObject.InnerException = Convert-ErrorToObject `
                -ErrorRecord $ErrorRecord.Exception.InnerException `
                -IncludeStackTrace:$IncludeStackTrace
        }

        return [PSCustomObject]$errorObject
    }
}
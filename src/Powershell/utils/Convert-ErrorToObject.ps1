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
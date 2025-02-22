function Format-Output {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory, ValueFromPipeline)]
        [object]$InputObject,
        [Parameter()]
        [ValidateSet('JSON', 'CSV', 'Table', 'List')]
        [string]$Format = 'JSON',
        [Parameter()]
        [string]$OutputPath,
        [Parameter()]
        [switch]$PassThru,
        [Parameter()]
        [switch]$Pretty
    )

    process {
        try {
            $output = switch ($Format) {
                'JSON' {
                    if ($Pretty) {
                        $InputObject | ConvertTo-Json -Depth 10
                    }
                    else {
                        $InputObject | ConvertTo-Json -Depth 10 -Compress
                    }
                }
                'CSV' {
                    $InputObject | ConvertTo-Csv -NoTypeInformation
                }
                'Table' {
                    $InputObject | Format-Table -AutoSize | Out-String
                }
                'List' {
                    $InputObject | Format-List | Out-String
                }
            }

            if ($OutputPath) {
                $output | Out-File -FilePath $OutputPath -Force
                Write-Verbose "Output written to: $OutputPath"
            }

            if ($PassThru) {
                return $output
            }
        }
        catch {
            Write-Error "Failed to format output: $_"
        }
    }
}
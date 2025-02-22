function Test-SecurityCompliance {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [string]$WorkspaceId,
        [Parameter()]
        [string]$BaselinePath = ".\Config\security-baseline.json",
        [Parameter()]
        [switch]$DetailedOutput
    )

    begin {
        $complianceStatus = @{
            ServerName = $ServerName
            Timestamp = Get-Date
            Checks = @()
            CompliantStatus = $false
            SecurityScore = 0
            Recommendations = @()
            DetailedResults = @{}
        }

        try {
            $baseline = Get-Content $BaselinePath | ConvertFrom-Json
            Write-Verbose "Successfully loaded security baseline from $BaselinePath"
        }
        catch {
            Write-Error "Failed to load security baseline: $_"
            return
        }
    }

    process {
        try {
            # Core Security Checks (Critical)
            $checks = @(
                @{
                    Name = 'TLS'
                    Function = 'Test-TLSCompliance'
                    Severity = 'Critical'
                },
                @{
                    Name = 'Certificates'
                    Function = 'Test-CertificateCompliance'
                    Severity = 'Critical'
                },
                @{
                    Name = 'ServiceAccounts'
                    Function = 'Test-ServiceAccountCompliance'
                    Severity = 'High'
                },
                @{
                    Name = 'Firewall'
                    Function = 'Test-FirewallCompliance'
                    Severity = 'High'
                },
                @{
                    Name = 'NetworkSecurity'
                    Function = 'Test-NetworkSecurityCompliance'
                    Severity = 'High'
                },
                @{
                    Name = 'EndpointProtection'
                    Function = 'Test-EndpointProtectionCompliance'
                    Severity = 'High'
                },
                @{
                    Name = 'Updates'
                    Function = 'Test-UpdateCompliance'
                    Severity = 'Medium'
                }
            )

            foreach ($check in $checks) {
                Write-Verbose "Running $($check.Name) compliance check..."
                $checkResult = & $check.Function -ServerName $ServerName
                
                $complianceStatus.Checks += @{
                    Category = $check.Name
                    Status = $checkResult.Compliant
                    Details = $checkResult.Details
                    Severity = $check.Severity
                    Remediation = $checkResult.Remediation
                    TimeStamp = Get-Date
                }

                if ($DetailedOutput) {
                    $complianceStatus.DetailedResults[$check.Name] = $checkResult
                }
            }

            # Optional Log Collection Check
            if ($WorkspaceId) {
                $logCheck = Test-LogCollectionSecurityCompliance -ServerName $ServerName -WorkspaceId $WorkspaceId
                $complianceStatus.Checks += @{
                    Category = "LogCollection"
                    Status = $logCheck.Compliant
                    Details = $logCheck.Details
                    Severity = "Medium"
                    Remediation = $logCheck.Remediation
                    TimeStamp = Get-Date
                }
            }

            # Calculate Security Score
            $complianceStatus.SecurityScore = Calculate-SecurityScore -Checks $complianceStatus.Checks

            # Generate Prioritized Recommendations
            $complianceStatus.Recommendations = Generate-SecurityRecommendations -Checks $complianceStatus.Checks

            # Set Overall Compliance Status
            $criticalFailures = $complianceStatus.Checks | 
                Where-Object { $_.Severity -in ('Critical', 'High') } | 
                Where-Object { -not $_.Status }
            
            $complianceStatus.CompliantStatus = $criticalFailures.Count -eq 0
        }
        catch {
            Write-Error "Security compliance check failed: $_"
            $complianceStatus.Error = @{
                Message = $_.Exception.Message
                ScriptStackTrace = $_.ScriptStackTrace
                TimeStamp = Get-Date
            }
        }
    }

    end {
        if ($DetailedOutput) {
            return [PSCustomObject]$complianceStatus
        }
        else {
            # Return simplified output
            return [PSCustomObject]@{
                ServerName = $complianceStatus.ServerName
                Timestamp = $complianceStatus.Timestamp
                CompliantStatus = $complianceStatus.CompliantStatus
                SecurityScore = $complianceStatus.SecurityScore
                CriticalIssues = ($complianceStatus.Checks | Where-Object { $_.Severity -eq 'Critical' -and -not $_.Status }).Count
                HighIssues = ($complianceStatus.Checks | Where-Object { $_.Severity -eq 'High' -and -not $_.Status }).Count
                Recommendations = $complianceStatus.Recommendations
            }
        }
    }
}

# Helper Functions
function Calculate-SecurityScore {
    param ([array]$Checks)
    
    $weights = @{
        'Critical' = 40
        'High' = 30
        'Medium' = 20
        'Low' = 10
    }

    $totalWeight = 0
    $earnedPoints = 0

    foreach ($check in $Checks) {
        $weight = $weights[$check.Severity]
        $totalWeight += $weight
        if ($check.Status) {
            $earnedPoints += $weight
        }
    }

    return [math]::Round(($earnedPoints / $totalWeight) * 100, 2)
}

function Generate-SecurityRecommendations {
    param ([array]$Checks)
    
    $failedChecks = $Checks | Where-Object { -not $_.Status } | 
        Sort-Object { 
            switch ($_.Severity) {
                'Critical' { 0 }
                'High' { 1 }
                'Medium' { 2 }
                'Low' { 3 }
                default { 4 }
            }
        }

    return $failedChecks | ForEach-Object {
        @{
            Category = $_.Category
            Severity = $_.Severity
            Remediation = $_.Remediation
        }
    }
}
function Test-SecurityCompliance {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [string]$BaselinePath = ".\Config\security-baseline.json"
    )

    begin {
        $baseline = Get-Content $BaselinePath | ConvertFrom-Json
        $results = @{
            ServerName = $ServerName
            Timestamp = Get-Date
            Checks = @()
            Compliant = $true
        }
    }

    process {
        try {
            # TLS Configuration
            $tlsCheck = Test-TLSConfiguration -ServerName $ServerName
            $results.Checks += @{
                Name = 'TLS'
                Status = $tlsCheck.Success
                Details = $tlsCheck.Details
            }

            # Certificate Validation
            $certCheck = Test-CertificateChain -ServerName $ServerName
            $results.Checks += @{
                Name = 'Certificates'
                Status = $certCheck.Success
                Details = $certCheck.Details
            }

            # Firewall Rules
            $firewallCheck = Test-FirewallRules -ServerName $ServerName
            $results.Checks += @{
                Name = 'Firewall'
                Status = $firewallCheck.Success
                Details = $firewallCheck.Details
            }

            # Service Account Permissions
            $permissionCheck = Test-ServiceAccountPermissions -ServerName $ServerName
            $results.Checks += @{
                Name = 'Permissions'
                Status = $permissionCheck.Success
                Details = $permissionCheck.Details
            }

            # Update Compliance
            $updateCheck = Test-UpdateCompliance -ServerName $ServerName
            $results.Checks += @{
                Name = 'Updates'
                Status = $updateCheck.Success
                Details = $updateCheck.Details
            }

            # Overall compliance status
            $results.Compliant = $results.Checks.Status -notcontains $false
        }
        catch {
            $results.Compliant = $false
            $results.Error = Convert-ErrorToObject $_
            Write-Error -Exception $_.Exception
        }
    }

    end {
        return [PSCustomObject]$results
    }
}
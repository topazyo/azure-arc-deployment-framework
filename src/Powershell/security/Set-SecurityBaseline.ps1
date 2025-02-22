function Set-SecurityBaseline {
    [CmdletBinding(SupportsShouldProcess)]
    param (
        [Parameter(Mandatory)]
        [string]$ServerName,
        [Parameter()]
        [string]$BaselinePath = ".\Config\security-baseline.json",
        [Parameter()]
        [switch]$Force
    )

    begin {
        $baselineStatus = @{
            ServerName = $ServerName
            StartTime = Get-Date
            Changes = @()
            Status = "Starting"
        }

        # Load security baseline
        try {
            $baseline = Get-Content $BaselinePath | ConvertFrom-Json
        }
        catch {
            Write-Error "Failed to load security baseline: $_"
            return
        }
    }

    process {
        try {
            # Take configuration backup
            $backup = Backup-SecurityConfiguration -ServerName $ServerName
            $baselineStatus.BackupPath = $backup.Path

            # Apply TLS Settings
            if ($PSCmdlet.ShouldProcess($ServerName, "Configure TLS Settings")) {
                $tlsResult = Set-TLSConfiguration -ServerName $ServerName -Settings $baseline.TLSSettings
                $baselineStatus.Changes += @{
                    Component = "TLS"
                    Status = $tlsResult.Success
                    Details = $tlsResult.Details
                }
            }

            # Configure Service Account Security
            if ($PSCmdlet.ShouldProcess($ServerName, "Configure Service Account Security")) {
                $serviceResult = Set-ServiceAccountSecurity -ServerName $ServerName -Settings $baseline.ServiceSettings
                $baselineStatus.Changes += @{
                    Component = "ServiceAccount"
                    Status = $serviceResult.Success
                    Details = $serviceResult.Details
                }
            }

            # Configure Firewall Rules
            if ($PSCmdlet.ShouldProcess($ServerName, "Configure Firewall Rules")) {
                $firewallResult = Set-FirewallRules -ServerName $ServerName -Rules $baseline.FirewallRules
                $baselineStatus.Changes += @{
                    Component = "Firewall"
                    Status = $firewallResult.Success
                    Details = $firewallResult.Details
                }
            }

            # Configure Audit Policies
            if ($PSCmdlet.ShouldProcess($ServerName, "Configure Audit Policies")) {
                $auditResult = Set-AuditPolicies -ServerName $ServerName -Policies $baseline.AuditPolicies
                $baselineStatus.Changes += @{
                    Component = "AuditPolicy"
                    Status = $auditResult.Success
                    Details = $auditResult.Details
                }
            }

            # Validate Changes
            $validation = Test-SecurityCompliance -ServerName $ServerName
            if (-not $validation.CompliantStatus) {
                throw "Security baseline validation failed after applying changes"
            }

            $baselineStatus.Status = "Success"
        }
        catch {
            $baselineStatus.Status = "Failed"
            $baselineStatus.Error = $_.Exception.Message

            # Attempt rollback if not forced
            if (-not $Force -and $backup) {
                Write-Warning "Security baseline application failed, attempting rollback..."
                $rollback = Restore-SecurityConfiguration -ServerName $ServerName -BackupPath $backup.Path
                $baselineStatus.Rollback = $rollback
            }
        }
    }

    end {
        $baselineStatus.EndTime = Get-Date
        return [PSCustomObject]$baselineStatus
    }
}
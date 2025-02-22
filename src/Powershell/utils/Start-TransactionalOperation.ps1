function Start-TransactionalOperation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [scriptblock]$Operation,
        [Parameter(Mandatory)]
        [scriptblock]$RollbackOperation,
        [Parameter()]
        [string]$OperationName = "Transactional Operation",
        [Parameter()]
        [hashtable]$Parameters = @{},
        [Parameter()]
        [switch]$Force,
        [Parameter()]
        [string]$BackupPath = ".\Backup"
    )

    begin {
        $transactionState = @{
            OperationName = $OperationName
            StartTime = Get-Date
            Status = "Starting"
            BackupTaken = $false
            Steps = @()
            RollbackSteps = @()
        }

        # Ensure backup directory exists
        if (-not (Test-Path $BackupPath)) {
            New-Item -Path $BackupPath -ItemType Directory -Force | Out-Null
        }

        Write-Log -Message "Starting transactional operation: $OperationName" -Level Information
    }

    process {
        try {
            # Take backup if possible
            try {
                $backup = Backup-OperationState -Path $BackupPath -Operation $OperationName
                $transactionState.BackupTaken = $true
                $transactionState.BackupPath = $backup.Path
                Write-Log -Message "Backup taken successfully at: $($backup.Path)" -Level Information
            }
            catch {
                Write-Log -Message "Failed to take backup: $_" -Level Warning
                if (-not $Force) {
                    throw "Cannot proceed without backup unless -Force is specified"
                }
            }

            # Execute operation
            $result = & $Operation @Parameters
            $transactionState.Steps += @{
                Name = "MainOperation"
                Status = "Success"
                Result = $result
            }

            # Validate result
            $validation = Test-OperationResult -Result $result
            if (-not $validation.Success) {
                throw "Operation validation failed: $($validation.Error)"
            }

            $transactionState.Status = "Success"
            Write-Log -Message "Operation completed successfully" -Level Information
        }
        catch {
            $transactionState.Status = "Failed"
            $transactionState.Error = $_.Exception.Message
            Write-Log -Message "Operation failed: $_" -Level Error

            # Attempt rollback
            if ($transactionState.BackupTaken) {
                Write-Log -Message "Initiating rollback" -Level Warning
                try {
                    & $RollbackOperation -Backup $backup
                    $transactionState.RollbackSteps += @{
                        Name = "Rollback"
                        Status = "Success"
                        Time = Get-Date
                    }
                    Write-Log -Message "Rollback completed successfully" -Level Information
                }
                catch {
                    $transactionState.RollbackSteps += @{
                        Name = "Rollback"
                        Status = "Failed"
                        Error = $_.Exception.Message
                        Time = Get-Date
                    }
                    Write-Log -Message "Rollback failed: $_" -Level Error
                }
            }

            throw
        }
    }

    end {
        $transactionState.EndTime = Get-Date
        $transactionState.Duration = $transactionState.EndTime - $transactionState.StartTime
        
        # Export transaction log
        $logPath = Join-Path $BackupPath "$OperationName`_$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
        $transactionState | ConvertTo-Json -Depth 10 | Out-File $logPath
        
        return [PSCustomObject]$transactionState
    }
}
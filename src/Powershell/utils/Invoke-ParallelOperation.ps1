function Invoke-ParallelOperation {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string[]]$ComputerName,
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        [Parameter()]
        [hashtable]$Parameters = @{},
        [Parameter()]
        [int]$ThrottleLimit = 10,
        [Parameter()]
        [int]$TimeoutSeconds = 300,
        [Parameter()]
        [switch]$ShowProgress
    )

    begin {
        $results = @{
            StartTime = Get-Date
            Successful = @()
            Failed = @()
            Skipped = @()
            Statistics = @{
                TotalServers = $ComputerName.Count
                Completed = 0
                InProgress = 0
                Pending = $ComputerName.Count
            }
        }

        # Initialize progress bar
        if ($ShowProgress) {
            $progressParams = @{
                Activity = "Executing parallel operations"
                Status = "Initializing..."
                PercentComplete = 0
            }
            Write-Progress @progressParams
        }

        Write-Log -Message "Starting parallel operation on $($ComputerName.Count) servers" -Level Information
    }

    process {
        try {
            # Create runspace pool
            $runspacePool = [runspacefactory]::CreateRunspacePool(1, $ThrottleLimit)
            $runspacePool.Open()
            $runspaces = @()

            # Create and start runspaces for each computer
            foreach ($computer in $ComputerName) {
                $powerShell = [powershell]::Create().AddScript($ScriptBlock).AddParameters($Parameters)
                $powerShell.RunspacePool = $runspacePool

                $runspaces += @{
                    PowerShell = $powerShell
                    Handle = $powerShell.BeginInvoke()
                    Computer = $computer
                    StartTime = Get-Date
                }

                $results.Statistics.InProgress++
                $results.Statistics.Pending--
            }

            # Monitor and collect results
            do {
                for ($i = 0; $i -lt $runspaces.Count; $i++) {
                    $runspace = $runspaces[$i]

                    if ($null -ne $runspace) {
                        if ($runspace.Handle.IsCompleted) {
                            try {
                                $result = $runspace.PowerShell.EndInvoke($runspace.Handle)
                                $results.Successful += @{
                                    Computer = $runspace.Computer
                                    Result = $result
                                    Duration = (Get-Date) - $runspace.StartTime
                                }
                            }
                            catch {
                                $results.Failed += @{
                                    Computer = $runspace.Computer
                                    Error = $_.Exception.Message
                                    Duration = (Get-Date) - $runspace.StartTime
                                }
                                Write-Log -Message "Operation failed on $($runspace.Computer): $_" -Level Error
                            }
                            finally {
                                $runspace.PowerShell.Dispose()
                                $runspaces[$i] = $null
                                $results.Statistics.Completed++
                                $results.Statistics.InProgress--
                            }
                        }
                        elseif (((Get-Date) - $runspace.StartTime).TotalSeconds -gt $TimeoutSeconds) { # Added statement block here
                            $results.Failed += @{
                                Computer = $runspace.Computer
                                Error = "Operation timed out"
                                Duration = (Get-Date) - $runspace.StartTime
                            }
                            $runspace.PowerShell.Dispose()
                            $runspaces[$i] = $null
                            $results.Statistics.Completed++
                            $results.Statistics.InProgress--
                            Write-Log -Message "Operation timed out on $($runspace.Computer)" -Level Warning
                        } # Closing brace for elseif statement block
                    }
                }

                $runspaces = $runspaces | Where-Object { $null -ne $_ }

                if ($ShowProgress) {
                    $percentComplete = ($results.Statistics.Completed / $results.Statistics.TotalServers) * 100
                    $progressParams.Status = "Completed: $($results.Statistics.Completed)/$($results.Statistics.TotalServers)"
                    $progressParams.PercentComplete = $percentComplete
                    Write-Progress @progressParams
                }

                Start-Sleep -Milliseconds 100

            } while ($runspaces.Count -gt 0)
        }
        catch {
            Write-Error "Parallel operation failed: $_"
            Write-Log -Message "Parallel operation failed: $_" -Level Error
        }
        finally {
            if ($null -ne $runspacePool) {
                $runspacePool.Close()
                $runspacePool.Dispose()
            }
        }
    }

    end {
        $results.EndTime = Get-Date
        $results.Duration = $results.EndTime - $results.StartTime

        if ($ShowProgress) {
            Write-Progress -Activity "Executing parallel operations" -Completed
        }

        Write-Log -Message "Parallel operation completed. Success: $($results.Successful.Count), Failed: $($results.Failed.Count)" -Level Information
        return [PSCustomObject]$results
    }
}
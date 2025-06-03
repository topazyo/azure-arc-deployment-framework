# Test-DataFlow.ps1
# This script tests the data flow pipeline into a Log Analytics Workspace for custom text logs.
# It assumes a custom log table and a Data Collection Rule (DCR) are already configured.

param (
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceId,

    [Parameter(Mandatory = $false)]
    [string]$TestLogTableName = "ArcFrameworkDataFlowTest_CL",

    # Parameters for DCR/Table creation are omitted in this version as per design.
    # [string]$DcrName,
    # [string]$DcrResourceGroupName,
    # [string]$Location,

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 600, # 10 minutes

    [Parameter(Mandatory = $false)]
    [string]$LocalTestLogDirectory = "C:\ArcFrameworkTestData", # Directory for the test log file
    [Parameter(Mandatory = $false)]
    [string]$LocalTestLogFileName = "dataflow_test.log", # File DCR should be monitoring

    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\ProgramData\AzureArcFramework\Logs\TestDataFlow_Activity.log"
)

# --- Logging Function (for script activity) ---
function Write-Log {
    param (
        [string]$Message,
        [string]$Level = "INFO", # INFO, WARNING, ERROR
        [string]$Path = $LogPath
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "[$timestamp] [$Level] $Message"

    try {
        if (-not (Test-Path (Split-Path $Path -Parent))) {
            New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force -ErrorAction Stop | Out-Null
        }
        Add-Content -Path $Path -Value $logEntry -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to write to activity log file $Path. Error: $($_.Exception.Message). Logging to console instead."
        Write-Host $logEntry
    }
}

# --- Main Script Logic ---
try {
    Write-Log "Starting Test-DataFlow script."
    Write-Log "Parameters: WorkspaceId='$WorkspaceId', TestLogTableName='$TestLogTableName', TimeoutSeconds='$TimeoutSeconds', LocalTestLogDir='$LocalTestLogDirectory', LocalTestLogFile='$LocalTestLogFileName'"
    Write-Log "IMPORTANT ASSUMPTIONS:" -Level "WARNING"
    Write-Log "1. Custom Log Table '$TestLogTableName' is PRE-CONFIGURED in Workspace '$WorkspaceId'." -Level "WARNING"
    Write-Log "2. A Data Collection Rule (DCR) is PRE-CONFIGURED and associated with this machine (or relevant target machines)." -Level "WARNING"
    Write-Log "   This DCR must be set up to collect text logs from '$((Join-Path $LocalTestLogDirectory $LocalTestLogFileName))' and send them to '$TestLogTableName'." -Level "WARNING"

    # 1. Azure Prerequisites Check
    Write-Log "Checking for required Azure PowerShell modules (Az.OperationalInsights, Az.Monitor)..."
    # Az.Monitor might be needed if we were creating DCRs, less so for just querying if table exists.
    $azOperationalInsights = Get-Module -Name Az.OperationalInsights -ListAvailable
    if (-not $azOperationalInsights) { throw "Az.OperationalInsights PowerShell module is not installed." }
    Write-Log "Required Azure modules found."

    Write-Log "Checking for active Azure context..."
    $azContext = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $azContext) { throw "No active Azure context. Please connect using Connect-AzAccount." }
    Write-Log "Active Azure context found."

    # Optional: Set context to the subscription of the workspace if it can be determined,
    # though Invoke-AzOperationalInsightsQuery primarily uses WorkspaceId.

    # 2. Generate Test Log Entry
    $uniqueTestId = [guid]::NewGuid().ToString()
    $testMessage = "Timestamp=$(Get-Date -Format o), TestID=$uniqueTestId, Message=DataFlowTestEntry from $($env:COMPUTERNAME)"
    $fullLocalTestLogPath = Join-Path $LocalTestLogDirectory $LocalTestLogFileName

    Write-Log "Generated TestID: $uniqueTestId"
    Write-Log "Test log file path: $fullLocalTestLogPath"

    try {
        if (-not (Test-Path $LocalTestLogDirectory -PathType Container)) {
            Write-Log "Creating local test log directory: $LocalTestLogDirectory"
            New-Item -ItemType Directory -Path $LocalTestLogDirectory -Force -ErrorAction Stop | Out-Null
        }
        Write-Log "Appending test message to $fullLocalTestLogPath: `"$testMessage`""
        Add-Content -Path $fullLocalTestLogPath -Value $testMessage -ErrorAction Stop
    } catch {
        Write-Log "Failed to write test log entry to '$fullLocalTestLogPath'. Error: $($_.Exception.Message)" -Level "ERROR"
        throw "Failed to write local test log. Check permissions and path."
    }

    # 3. Query Log Analytics
    # Custom log field names often get suffixes like _s (string), _d (real), _b (boolean), _t (datetime), _g (guid)
    # Assuming TestID is ingested as a string field. The actual field name might be 'TestID_s'.
    # We will try to be a bit flexible by checking RawData first, then specific field.
    $kqlQueryBase = "$TestLogTableName | where RawData contains '$uniqueTestId' or TestID_s == '$uniqueTestId'"
    $kqlQuery = "$kqlQueryBase | take 1"

    Write-Log "Will query Log Analytics using base: $kqlQueryBase"

    $startTimeOuter = Get-Date
    $elapsedSeconds = 0
    $logFound = $false
    $ingestionTimeSeconds = -1

    # Initial delay before first query
    $initialDelaySeconds = 120
    Write-Log "Waiting $initialDelaySeconds seconds for initial ingestion lag..."
    Start-Sleep -Seconds $initialDelaySeconds
    $elapsedSeconds = [int](New-TimeSpan -Start $startTimeOuter -End (Get-Date)).TotalSeconds

    Write-Log "Starting polling for log entry in workspace '$WorkspaceId' (Timeout: $($TimeoutSeconds - $elapsedSeconds) more seconds)..."
    while ($elapsedSeconds -lt $TimeoutSeconds) {
        try {
            Write-Log "Executing KQL query: $kqlQuery (Attempt at $elapsedSeconds seconds)"
            $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceId -Query $kqlQuery -ErrorAction Stop

            if ($queryResults.Results.Count -gt 0) {
                Write-Log "SUCCESS: Test log entry with TestID '$uniqueTestId' found in '$TestLogTableName'." -Level "INFO"
                $logFound = $true
                $ingestionTimeSeconds = $elapsedSeconds
                break
            } else {
                Write-Log "Log entry not yet found. Retrying in 30 seconds..."
            }
        }
        catch {
            Write-Log "Error during Invoke-AzOperationalInsightsQuery: $($_.Exception.Message)" -Level "WARNING"
            # Continue retrying unless it's a fatal error (which ErrorAction Stop should handle by exiting script)
        }

        Start-Sleep -Seconds 30
        $elapsedSeconds = [int](New-TimeSpan -Start $startTimeOuter -End (Get-Date)).TotalSeconds
    }

    # 4. Determine Success/Failure
    $finalStatus = "Failed"
    $finalMessage = "Timeout reached. Test log entry with TestID '$uniqueTestId' NOT found in '$TestLogTableName' after $TimeoutSeconds seconds."
    if ($logFound) {
        $finalStatus = "Success"
        $finalMessage = "Test log entry with TestID '$uniqueTestId' successfully found in '$TestLogTableName'. Ingestion time approx $ingestionTimeSeconds seconds."
    }

    Write-Log $finalMessage -Level (if($logFound){"INFO"}else{"ERROR"})

    $result = @{
        TestID                 = $uniqueTestId
        WorkspaceId            = $WorkspaceId
        CustomLogTable         = $TestLogTableName
        LocalLogFile           = $fullLocalTestLogPath
        Status                 = $finalStatus
        Message                = $finalMessage
        QueryUsed              = $kqlQuery
        IngestionTimeSeconds   = $ingestionTimeSeconds
        TotalDurationSeconds   = $elapsedSeconds
        Timestamp              = Get-Date
    }

    Write-Log "Test-DataFlow script finished."
    return $result
}
catch {
    Write-Log "A critical error occurred in Test-DataFlow script: $($_.Exception.Message)" -Level "FATAL"
    if ($_.ScriptStackTrace) {
        Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level "FATAL"
    }
    return @{
        TestID                 = if($uniqueTestId){$uniqueTestId}else{"N/A"}
        WorkspaceId            = $WorkspaceId
        CustomLogTable         = $TestLogTableName
        Status                 = "Error"
        Message                = "Critical script error: $($_.Exception.Message)"
        QueryUsed              = if($kqlQuery){$kqlQuery}else{"N/A"}
        IngestionTimeSeconds   = -1
        Timestamp              = Get-Date
    }
}

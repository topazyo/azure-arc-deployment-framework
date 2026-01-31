# VIBE Phase 5: Security, Trust & Abuse-Resistance Audit

**Generated:** 2026-01-31  
**Audit Scope:** Access control, input validation, data protection, secrets handling, abuse-resistance, security observability  
**Previous Phases:** Structural (1), Consistency (2), Behavioral/Contract (3), Resilience/Observability (4) findings incorporated as constraints

---

## Executive Summary

| Dimension | Rating | Key Concern |
|-----------|--------|-------------|
| **Access Control & Authorization** | Weak | No systematic authorization; admin ops lack privilege checks |
| **Input Validation & Injection Resistance** | Weak | `Invoke-Expression` used with partially-controllable inputs; path traversal risks |
| **Data Protection & Secrets Handling** | Adequate | Service principal secret briefly plaintext; logged command includes secret |
| **Secrets & Configuration** | Adequate | No hardcoded secrets; config files assume trusted environment |
| **Abuse-Resistance** | Weak | No rate limiting; no input size bounds; enumeration possible |
| **Security Observability** | Weak | No security event logging; auth failures not captured |

### Top Security Risks

1. **[Get-RemediationAction.ps1:254](src/Powershell/remediation/Get-RemediationAction.ps1#L254)** – `Invoke-Expression` used to resolve parameters from user-controlled input (`$InputContext.*`)
2. **[New-ArcDeployment.ps1:97-99,135](src/Powershell/core/New-ArcDeployment.ps1#L97-L99)** – Service principal secret converted to plaintext and included in logged command
3. **[Set-TLSConfiguration.ps1:46](src/Powershell/security/Set-TLSConfiguration.ps1#L46)** – `Invoke-Expression` with registry key path interpolation (injection risk)
4. **[Set-AuditPolicies.ps1:195](src/Powershell/security/Set-AuditPolicies.ps1#L195)** – `Invoke-Expression` with `auditpol` command construction
5. **[predictor.py:58-59](src/Python/predictive/predictor.py#L58-L59)** – `joblib.load` unsafe deserialization from model files (arbitrary code execution if model files tampered)

---

## 1. Access Control & Authorization Issues

### Issue AC-1: Security Scripts Lack Caller Authorization

- **Location:** [Set-TLSConfiguration.ps1:1-100](src/Powershell/security/Set-TLSConfiguration.ps1#L1-L100)
- **Sensitivity:** HIGH – Modifies system-wide TLS/registry settings
- **Current Authorization:**
  - None explicit; relies on Windows UAC
  - No check for administrator role before proceeding
- **Issue:**
  - Script modifies critical security settings without verifying caller is authorized
  - No audit trail of who invoked the operation
- **Suggested Mitigation:**
  ```powershell
  # Add at script start:
  if (-not (Test-IsAdministrator)) {
      Write-Log "Administrative privileges required for TLS configuration." -Level Error
      throw "This operation requires administrative privileges."
  }
  Write-Log -Message "Security operation initiated by $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -Level Information
  ```

---

### Issue AC-2: Firewall Rules Script Has Admin Check But No Caller Logging

- **Location:** [Set-FirewallRules.ps1:62-65](src/Powershell/security/Set-FirewallRules.ps1#L62-L65)
- **Sensitivity:** HIGH – Modifies firewall rules
- **Current Authorization:**
  - ✅ Has `Test-IsAdministrator` check
  - ❌ Does not log who initiated the operation
- **Issue:**
  - Security-sensitive operation without audit trail
- **Suggested Mitigation:**
  ```powershell
  Write-Log "Firewall configuration initiated by $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)" -Level Information
  ```

---

### Issue AC-3: Remediation Actions Execute Without Authorization Scope

- **Location:** [Start-RemediationAction.ps1:7-100](src/Powershell/remediation/Start-RemediationAction.ps1#L7-L100)
- **Sensitivity:** HIGH – Executes arbitrary remediation scripts/executables
- **Current Authorization:**
  - Uses `SupportsShouldProcess` for confirmation
  - No role/permission verification
  - No validation that caller is authorized to remediate specific systems
- **Issue:**
  - Any authenticated user can trigger remediation actions
  - No scope limiting which servers a user can remediate
- **Suggested Mitigation:**
  ```powershell
  param (
      # ... existing params ...
      [Parameter()]
      [string[]]$AllowedServers = @()  # Restrict remediation scope
  )
  
  if ($AllowedServers.Count -gt 0 -and $ApprovedAction.ServerName -notin $AllowedServers) {
      throw "Caller not authorized to remediate server '$($ApprovedAction.ServerName)'"
  }
  ```

---

### Issue AC-4: AI Engine Invocation Has No Caller Validation

- **Location:** [Get-PredictiveInsights.ps1:1-50](src/Powershell/AI/Get-PredictiveInsights.ps1#L1-L50)
- **Sensitivity:** MEDIUM – Invokes Python subprocess with server data
- **Current Authorization:**
  - None; anyone who can call the function can analyze any server
- **Issue:**
  - No scoping of which servers a user can request insights for
  - Could be used to enumerate server information
- **Suggested Mitigation:**
  - Add optional `$AllowedServers` parameter
  - Log invocation with caller identity

---

## 2. Input Validation & Injection Risks

### Issue IV-1: CRITICAL – Invoke-Expression with User-Controlled Input

- **Location:** [Get-RemediationAction.ps1:254](src/Powershell/remediation/Get-RemediationAction.ps1#L254)
- **Input Source:** Remediation rule parameters containing `$InputContext.*` expressions
- **Current Handling:**
  ```powershell
  $expression = $paramValueOrPath.Replace('$InputContext', '$inputContextForParameterResolution')
  $resolvedParameters[$paramName] = Invoke-Expression $expression
  ```
- **Risk:**
  - **Potential injection:** If `$paramValueOrPath` contains malicious expressions beyond simple property access
  - Attacker controlling input object properties could inject arbitrary PowerShell
- **Severity:** CRITICAL
- **Suggested Fix:**
  ```powershell
  # Before (UNSAFE):
  $resolvedParameters[$paramName] = Invoke-Expression $expression
  
  # After (SAFE - restrict to property access only):
  if ($paramValueOrPath -match '^\$InputContext\.[\w\.]+$') {
      $propertyPath = $paramValueOrPath -replace '^\$InputContext\.', ''
      $resolvedParameters[$paramName] = $inputContextForParameterResolution
      foreach ($prop in $propertyPath.Split('.')) {
          $resolvedParameters[$paramName] = $resolvedParameters[$paramName].$prop
      }
  } else {
      Write-Log "Invalid parameter expression '$paramValueOrPath' - must be simple property path" -Level Warning
      $resolvedParameters[$paramName] = $paramValueOrPath
  }
  ```

---

### Issue IV-2: HIGH – Registry Path in Invoke-Expression

- **Location:** [Set-TLSConfiguration.ps1:46](src/Powershell/security/Set-TLSConfiguration.ps1#L46)
- **Input Source:** Registry key paths derived from config file iteration
- **Current Handling:**
  ```powershell
  Invoke-Expression "reg export `"$key`" `"$exportPath`" /y"
  ```
- **Risk:**
  - If config file is compromised, attacker could inject shell commands
  - Quote escaping could be bypassed with specially crafted paths
- **Severity:** HIGH
- **Suggested Fix:**
  ```powershell
  # Before (risky):
  Invoke-Expression "reg export `"$key`" `"$exportPath`" /y"
  
  # After (safer - use Start-Process with argument array):
  $regArgs = @('export', $key, $exportPath, '/y')
  $regResult = Start-Process -FilePath 'reg.exe' -ArgumentList $regArgs -Wait -PassThru -NoNewWindow
  if ($regResult.ExitCode -ne 0) {
      Write-Log "Registry export failed for $key" -Level Error
  }
  ```

---

### Issue IV-3: HIGH – Shell Command Injection in Audit Policy

- **Location:** [Set-AuditPolicies.ps1:195](src/Powershell/security/Set-AuditPolicies.ps1#L195)
- **Input Source:** Subcategory names from JSON config
- **Current Handling:**
  ```powershell
  Invoke-Expression "auditpol $auditPolArgs" | Out-Null
  ```
- **Risk:**
  - Malformed subcategory name in config could inject shell commands
- **Severity:** HIGH
- **Suggested Fix:**
  ```powershell
  # Use Start-Process with explicit argument list:
  $argArray = $auditPolArgs -split ' '
  Start-Process -FilePath 'auditpol.exe' -ArgumentList $argArray -Wait -NoNewWindow
  ```

---

### Issue IV-4: HIGH – Firewall Backup Command Injection

- **Location:** [Set-FirewallRules.ps1:49](src/Powershell/security/Set-FirewallRules.ps1#L49)
- **Input Source:** Backup file path (partially user-controlled via timestamp)
- **Current Handling:**
  ```powershell
  Invoke-Expression "netsh advfirewall export `"$BackupFilePath`"" | Out-Null
  ```
- **Risk:**
  - Path with special characters could break out of quotes
- **Severity:** HIGH
- **Suggested Fix:**
  ```powershell
  Start-Process -FilePath 'netsh.exe' -ArgumentList @('advfirewall', 'export', $BackupFilePath) -Wait -NoNewWindow
  ```

---

### Issue IV-5: MEDIUM – JSON Parsing Without Size Limits

- **Location:** [invoke_ai_engine.py:87-93](src/Python/invoke_ai_engine.py#L87-L93), [run_predictor.py:66-75](src/Python/run_predictor.py#L66-L75)
- **Input Source:** `--serverdatajson` CLI argument
- **Current Handling:**
  ```python
  server_data_input = json.loads(args.serverdatajson)
  ```
- **Risk:**
  - No size limit on JSON input; could cause memory exhaustion
  - No depth limit on nested objects
- **Severity:** MEDIUM
- **Suggested Fix:**
  ```python
  MAX_JSON_SIZE = 1024 * 1024  # 1MB limit
  if len(args.serverdatajson) > MAX_JSON_SIZE:
      raise ValueError(f"Input JSON exceeds maximum size of {MAX_JSON_SIZE} bytes")
  server_data_input = json.loads(args.serverdatajson)
  ```

---

### Issue IV-6: MEDIUM – Path Traversal in Model Directory

- **Location:** [predictor.py:36-47](src/Python/predictive/predictor.py#L36-L47)
- **Input Source:** `model_dir` parameter passed from CLI
- **Current Handling:**
  ```python
  model_path = f"{self.model_dir}/{model_type}_model.pkl"
  ```
- **Risk:**
  - If `model_dir` contains `../`, could load models from unintended locations
- **Severity:** MEDIUM
- **Suggested Fix:**
  ```python
  import os
  model_dir_resolved = os.path.abspath(self.model_dir)
  # Verify model_dir is within expected base path
  expected_base = os.path.abspath(os.path.join(os.path.dirname(__file__), '..'))
  if not model_dir_resolved.startswith(expected_base):
      raise ValueError(f"Model directory must be within {expected_base}")
  ```

---

## 3. Data Protection & Privacy Issues

### Issue DP-1: Service Principal Secret Logged in Command

- **Location:** [New-ArcDeployment.ps1:97-99,135](src/Powershell/core/New-ArcDeployment.ps1#L97-L99)
- **Data Type:** Service Principal Secret (Azure credential)
- **Current Handling:**
  ```powershell
  $plainTextSecret = ConvertFrom-SecureString -SecureString $ServicePrincipalSecret -AsPlainText
  $connectCommand += " --service-principal-secret `"$plainTextSecret`""
  # ...
  Write-Information $connectCommand  # SECRET IS LOGGED!
  ```
- **Risk:**
  - Secret appears in plaintext in Information stream
  - Could be captured in transcript logs, CI/CD logs, or terminal history
- **Severity:** CRITICAL
- **Suggested Mitigation:**
  ```powershell
  # Mask secret in any displayed/logged command:
  $displayCommand = $connectCommand -replace '--service-principal-secret "[^"]*"', '--service-principal-secret "***REDACTED***"'
  Write-Information "Generated azcmagent connect command:"
  Write-Information $displayCommand
  
  # Also clear the plaintext secret immediately:
  [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR(
      [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($ServicePrincipalSecret)
  )
  Remove-Variable plainTextSecret -Force -ErrorAction SilentlyContinue
  ```

---

### Issue DP-2: Diagnostic Data May Contain Sensitive Information

- **Location:** [Start-ArcDiagnostics.ps1:190-198](src/Powershell/core/Start-ArcDiagnostics.ps1#L190-L198)
- **Data Type:** System configuration, logs, security events
- **Current Handling:**
  - Diagnostic results exported to JSON file without filtering
  - Security logs collected and stored
- **Risk:**
  - Diagnostic output could contain sensitive data (usernames, paths, config values)
  - No PII filtering before export
- **Severity:** MEDIUM
- **Suggested Mitigation:**
  ```powershell
  # Add sanitization before export:
  function Remove-SensitiveData {
      param([hashtable]$Data)
      # Mask usernames, paths with usernames, etc.
      $jsonString = $Data | ConvertTo-Json -Depth 10
      $jsonString = $jsonString -replace '(?i)(password|secret|key|token)[":]?\s*["\']?[^"\'\s,}]+', '$1: "***REDACTED***"'
      return $jsonString | ConvertFrom-Json
  }
  ```

---

### Issue DP-3: Model Files Could Contain Embedded Data

- **Location:** [model_trainer.py:300-310](src/Python/predictive/model_trainer.py#L300-L310)
- **Data Type:** Trained ML models (may contain training data samples)
- **Current Handling:**
  - Models saved with `joblib.dump` without data sanitization
  - Scalers contain mean/std from training data
- **Risk:**
  - Models could leak information about training data distribution
  - Feature names reveal schema of sensitive telemetry
- **Severity:** LOW
- **Suggested Mitigation:**
  - Document that models should be treated as sensitive artifacts
  - Consider model encryption at rest for production

---

## 4. Secrets & Configuration Issues

### Issue SC-1: Config Files Assume Trusted Environment

- **Location:** [AzureArcFramework.psm1:19-35](src/Powershell/AzureArcFramework.psm1#L19-L35)
- **Item:** Configuration file loading (`ai_config.json`, `security-baseline.json`)
- **Issue:**
  - Config files loaded from relative path without integrity verification
  - Attacker with filesystem access could modify configs
- **Suggested Fix:**
  ```powershell
  # Add optional config signature verification:
  $configSigPath = "$filePath.sig"
  if (Test-Path $configSigPath) {
      $isValid = Test-ConfigSignature -ConfigPath $filePath -SignaturePath $configSigPath
      if (-not $isValid) {
          throw "Configuration file signature invalid: $filePath"
      }
  }
  ```
- **Severity:** MEDIUM

---

### Issue SC-2: No Validation of Critical Security Baseline Values

- **Location:** [security-baseline.json:1-415](src/config/security-baseline.json)
- **Item:** Security baseline configuration values
- **Issue:**
  - No schema validation for security-baseline.json
  - Malformed values could cause unexpected behavior
  - Missing `tlsSettings` silently fails to harden TLS
- **Suggested Fix:**
  ```powershell
  # Add schema validation in Set-SecurityBaseline:
  $requiredSections = @('tlsSettings', 'firewallRules', 'auditPolicies')
  foreach ($section in $requiredSections) {
      if (-not $baseline.PSObject.Properties[$section]) {
          throw "Security baseline missing required section: $section"
      }
  }
  ```
- **Severity:** MEDIUM

---

### Issue SC-3: Environment Variables Control Behavior Without Logging

- **Location:** Multiple locations (`$env:ARC_AI_FORCE_MOCKS`, `$env:ARC_DIAG_TESTDATA`, etc.)
- **Item:** Test/debug environment flags
- **Issue:**
  - Environment variables can change system behavior without audit
  - `ARC_AI_FORCE_MOCKS=1` bypasses actual AI processing
  - No logging when these flags are active
- **Suggested Fix:**
  ```powershell
  # At module load, log active debug flags:
  $debugFlags = @('ARC_AI_FORCE_MOCKS', 'ARC_DIAG_TESTDATA', 'ARC_PREREQ_TESTDATA')
  foreach ($flag in $debugFlags) {
      if ($env:$flag -eq '1') {
          Write-Log "WARNING: Debug flag $flag is active - not for production use" -Level Warning
      }
  }
  ```
- **Severity:** MEDIUM

---

## 5. Abuse-Resistance Gaps

### Issue AR-1: No Rate Limiting on AI Engine Invocations

- **Target:** [Get-PredictiveInsights.ps1](src/Powershell/AI/Get-PredictiveInsights.ps1), [invoke_ai_engine.py](src/Python/invoke_ai_engine.py)
- **Abuse Scenario:**
  - Attacker repeatedly calls `Get-PredictiveInsights` for different server names
  - Causes CPU/memory exhaustion on host running predictions
  - Could be used to enumerate server names by timing responses
- **Current Controls:** None
- **Risk:** Resource exhaustion, information disclosure via timing
- **Suggested Mitigation:**
  ```powershell
  # Add invocation throttling:
  $script:LastInvocationTime = [datetime]::MinValue
  $MinIntervalSeconds = 5
  
  if (((Get-Date) - $script:LastInvocationTime).TotalSeconds -lt $MinIntervalSeconds) {
      throw "Rate limit exceeded. Wait $MinIntervalSeconds seconds between calls."
  }
  $script:LastInvocationTime = Get-Date
  ```
- **Severity:** MEDIUM

---

### Issue AR-2: No Input Size Limits on Telemetry Data

- **Target:** [invoke_ai_engine.py:43-47](src/Python/invoke_ai_engine.py#L43-L47)
- **Abuse Scenario:**
  - Attacker sends extremely large `--serverdatajson` payload
  - Causes memory exhaustion or long processing time
- **Current Controls:** None
- **Risk:** Denial of service
- **Suggested Mitigation:**
  ```python
  MAX_FEATURES = 100
  MAX_STRING_VALUE_LEN = 1000
  
  if len(server_data_input) > MAX_FEATURES:
      raise ValueError(f"Too many features: {len(server_data_input)} > {MAX_FEATURES}")
  for key, value in server_data_input.items():
      if isinstance(value, str) and len(value) > MAX_STRING_VALUE_LEN:
          raise ValueError(f"Feature '{key}' value too long")
  ```
- **Severity:** MEDIUM

---

### Issue AR-3: Predictable Resource Enumeration via Error Messages

- **Target:** [Start-ArcDiagnostics.ps1](src/Powershell/core/Start-ArcDiagnostics.ps1)
- **Abuse Scenario:**
  - Attacker calls diagnostics for non-existent servers
  - Different error messages for "not found" vs "access denied" reveal server existence
- **Current Controls:** None
- **Risk:** Server enumeration, reconnaissance
- **Suggested Mitigation:**
  ```powershell
  # Use generic error message:
  catch {
      Write-Log "Diagnostic collection failed for $ServerName" -Level Error
      throw "Unable to collect diagnostics for the specified server"
      # Don't expose whether server exists vs access denied
  }
  ```
- **Severity:** LOW

---

### Issue AR-4: Unsafe Deserialization in Model Loading

- **Target:** [predictor.py:58-59](src/Python/predictive/predictor.py#L58-L59)
- **Abuse Scenario:**
  - Attacker replaces model `.pkl` file with malicious pickle
  - `joblib.load()` executes arbitrary code during deserialization
- **Current Controls:** None
- **Risk:** Remote code execution if model files are writable
- **Suggested Mitigation:**
  ```python
  # Option 1: Verify model file signatures before loading
  # Option 2: Use safer serialization format (ONNX, safetensors)
  # Option 3: Restrict model directory permissions to read-only for service account
  
  import hashlib
  expected_hashes = load_model_hashes()  # From signed manifest
  actual_hash = hashlib.sha256(open(model_path, 'rb').read()).hexdigest()
  if actual_hash != expected_hashes.get(model_type):
      raise SecurityError(f"Model file {model_path} has been tampered with")
  ```
- **Severity:** HIGH

---

## 6. Security Observability Gaps

### Issue SO-1: No Logging of Authorization Decisions

- **Event Type:** Authorization success/failure
- **Location:** All scripts
- **Current Behavior:** No authorization checks, thus no logging
- **Recommended Logging:**
  ```powershell
  Write-StructuredLog -LogEntry @{
      EventType = 'AuthorizationCheck'
      Principal = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
      Operation = 'Set-SecurityBaseline'
      Target = $ServerName
      Result = 'Allowed'  # or 'Denied'
      Reason = 'User is member of Administrators group'
  }
  ```
- **Impact:** HIGH – Cannot audit who performed security-sensitive operations

---

### Issue SO-2: Failed AI Engine Invocations Not Logged Structurally

- **Event Type:** AI subsystem failures
- **Location:** [Get-PredictiveInsights.ps1:159-170](src/Powershell/AI/Get-PredictiveInsights.ps1#L159-L170)
- **Current Behavior:**
  ```powershell
  Write-Error "AI Engine script execution failed. Exit Code: $($process.ExitCode)"
  ```
- **Recommended Logging:**
  ```powershell
  Write-StructuredLog -LogEntry @{
      EventType = 'AIEngineFailure'
      ServerName = $ServerName
      AnalysisType = $AnalysisType
      ExitCode = $process.ExitCode
      ErrorMessage = $stdErr
      Duration = $stopwatch.Elapsed.TotalSeconds
  }
  ```
- **Impact:** MEDIUM – Difficult to monitor AI subsystem health

---

### Issue SO-3: Security Baseline Changes Not Audit Logged

- **Event Type:** Configuration changes
- **Location:** [Set-TLSConfiguration.ps1](src/Powershell/security/Set-TLSConfiguration.ps1), [Set-FirewallRules.ps1](src/Powershell/security/Set-FirewallRules.ps1), [Set-AuditPolicies.ps1](src/Powershell/security/Set-AuditPolicies.ps1)
- **Current Behavior:** Changes logged to file but not in structured, queryable format
- **Recommended Logging:**
  ```powershell
  Write-StructuredLog -LogEntry @{
      EventType = 'SecurityConfigurationChange'
      Component = 'TLS'
      Setting = $protocolName
      OldValue = $previousValue
      NewValue = $newValue
      ChangedBy = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
      Timestamp = Get-Date -Format 'o'
  }
  ```
- **Impact:** HIGH – Cannot audit security configuration drift

---

### Issue SO-4: Remediation Actions Not Logged for Compliance

- **Event Type:** Remediation execution
- **Location:** [Start-RemediationAction.ps1](src/Powershell/remediation/Start-RemediationAction.ps1)
- **Current Behavior:** Logged to local file only
- **Recommended Logging:**
  ```powershell
  Write-StructuredLog -LogEntry @{
      EventType = 'RemediationExecuted'
      RemediationActionId = $ApprovedAction.RemediationActionId
      TargetServer = $ApprovedAction.ServerName
      ExecutedBy = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
      Status = $actionStatus
      Duration = $executionDuration
      RollbackAvailable = $backupSucceeded
  }
  ```
- **Impact:** HIGH – Cannot demonstrate compliance with change management

---

## Consolidated Security Risk Profile

### Summary Table

| Category | Critical | High | Medium | Low |
|----------|----------|------|--------|-----|
| Access Control | 0 | 2 | 2 | 0 |
| Input Validation | 1 | 3 | 2 | 0 |
| Data Protection | 1 | 0 | 1 | 1 |
| Secrets/Config | 0 | 0 | 3 | 0 |
| Abuse-Resistance | 0 | 1 | 2 | 1 |
| Security Observability | 0 | 2 | 1 | 0 |
| **Total** | **2** | **8** | **11** | **2** |

### Cross-Reference with Prior Phases

| Phase 5 Issue | Related Prior Finding |
|---------------|----------------------|
| DP-1 (secret logging) | Phase 4: Observability gap RE-4.8 |
| AR-4 (unsafe deser.) | Phase 3: EC-4.5 (model file integrity) |
| IV-5 (JSON size) | Phase 4: No input bounds noted |
| SO-3 (audit logging) | Phase 4: Observability gaps OG-1 to OG-7 |

---

## Prioritized Remediation Plan

### P0 – Critical Security Fixes (Immediate)

| # | Issue | Location | Impact | Fix Summary |
|---|-------|----------|--------|-------------|
| 1 | IV-1 | Get-RemediationAction.ps1:254 | Code injection | Replace `Invoke-Expression` with property path parser |
| 2 | DP-1 | New-ArcDeployment.ps1:135 | Credential leakage | Mask secret before logging |

### P1 – High-Impact Security Hardening (1-2 weeks)

| # | Issue | Location | Impact | Fix Summary |
|---|-------|----------|--------|-------------|
| 3 | IV-2 | Set-TLSConfiguration.ps1:46 | Shell injection | Use `Start-Process` with argument array |
| 4 | IV-3 | Set-AuditPolicies.ps1:195 | Shell injection | Use `Start-Process` with argument array |
| 5 | IV-4 | Set-FirewallRules.ps1:49 | Shell injection | Use `Start-Process` with argument array |
| 6 | AR-4 | predictor.py:58 | RCE via pickle | Add model file integrity verification |
| 7 | AC-1 | Set-TLSConfiguration.ps1 | Unauthorized changes | Add admin check and caller logging |
| 8 | SO-1 | All security scripts | No audit trail | Add structured authorization logging |
| 9 | SO-3 | Security scripts | Compliance gap | Add structured change logging |

### P2 – Defense-in-Depth & Long-Term Improvements (1 month+)

| # | Issue | Location | Impact | Fix Summary |
|---|-------|----------|--------|-------------|
| 10 | IV-5 | invoke_ai_engine.py | DoS | Add JSON size limits |
| 11 | IV-6 | predictor.py | Path traversal | Add path validation |
| 12 | AR-1 | Get-PredictiveInsights.ps1 | Resource abuse | Add rate limiting |
| 13 | AR-2 | invoke_ai_engine.py | DoS | Add feature count limits |
| 14 | SC-1 | AzureArcFramework.psm1 | Config tampering | Add config signature verification |
| 15 | SC-2 | security-baseline.json | Misconfiguration | Add schema validation |
| 16 | SC-3 | Module load | Debug bypass | Log active debug flags |
| 17 | DP-2 | Start-ArcDiagnostics.ps1 | Data leakage | Add PII sanitization |
| 18 | AC-3 | Start-RemediationAction.ps1 | Scope creep | Add server allowlist |
| 19 | SO-2 | Get-PredictiveInsights.ps1 | Monitoring gap | Add structured failure logging |
| 20 | SO-4 | Start-RemediationAction.ps1 | Compliance gap | Add remediation audit logging |

---

## Standardization Decisions

### Authorization Model

- **Standard:** All security-sensitive operations MUST:
  1. Check `Test-IsAdministrator` before proceeding
  2. Log caller identity via `[System.Security.Principal.WindowsIdentity]::GetCurrent().Name`
  3. Use `Write-StructuredLog` for authorization decisions
- **Scope:** Security scripts, remediation actions, deployment operations

### Input Validation Standards

- **Standard:** Never use `Invoke-Expression` with user-controllable input
- **Alternative for shell commands:** Use `Start-Process -ArgumentList @(...)` with explicit array
- **Alternative for dynamic property access:** Parse and validate property paths manually
- **JSON limits:** 1MB max size, 100 max features, 1000 char max string values

### Sensitive Data Handling

- **Standard:** Secrets MUST:
  1. Never appear in log output (mask with `***REDACTED***`)
  2. Be cleared from memory after use (`Clear-Variable`, `[Marshal]::ZeroFree*`)
  3. Use `SecureString` until the last possible moment

### Security Event Logging

- **Standard:** Use `Write-StructuredLog` for all security events with schema:
  ```json
  {
    "EventType": "string",
    "Timestamp": "ISO8601",
    "Principal": "string",
    "Operation": "string",
    "Target": "string",
    "Result": "Success|Failure|Denied",
    "Details": {}
  }
  ```

---

## Appendix: Detailed Code Fixes

### Fix for IV-1: Safe Property Path Resolution

```powershell
function Resolve-PropertyPath {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]$InputObject,
        [Parameter(Mandatory)]
        [string]$PropertyPath
    )
    
    # Validate path contains only safe characters
    if ($PropertyPath -notmatch '^[\w\.]+$') {
        throw "Invalid property path: $PropertyPath"
    }
    
    $current = $InputObject
    foreach ($prop in $PropertyPath.Split('.')) {
        if ($null -eq $current) { return $null }
        if ($current.PSObject.Properties[$prop]) {
            $current = $current.$prop
        } else {
            return $null
        }
    }
    return $current
}

# Usage in Get-RemediationAction.ps1:
if ($paramValueOrPath -is [string] -and $paramValueOrPath.StartsWith('$InputContext.')) {
    $propertyPath = $paramValueOrPath.Substring(14)  # Remove '$InputContext.'
    $resolvedParameters[$paramName] = Resolve-PropertyPath -InputObject $inputContextForParameterResolution -PropertyPath $propertyPath
} else {
    $resolvedParameters[$paramName] = $paramValueOrPath
}
```

### Fix for DP-1: Secret Masking

```powershell
function New-MaskedCommand {
    param([string]$Command)
    return $Command -replace '(--service-principal-secret\s+")[^"]*(")', '$1***REDACTED***$2'
}

# In New-ArcDeployment.ps1:
$displayCommand = New-MaskedCommand -Command $connectCommand
Write-Information "Generated azcmagent connect command:"
Write-Information $displayCommand
# Note: The actual $connectCommand with secret is still available for execution
```

---

**Document Version:** 1.0  
**Next Review:** Phase 6 (if planned) or implementation validation

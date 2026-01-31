# VIBE Implementation Work Breakdown Structure

**Project:** Azure Arc Deployment Framework  
**Document:** Detailed Work Breakdown Structure  
**Date:** January 31, 2026  
**Version:** 1.0

---

## Overview

This document provides the detailed work breakdown for the VIBE audit implementation, mapping Phase 9 refactoring batches into sprints, stories, and tasks suitable for import into project management systems (GitHub Issues, Jira, Linear, etc.).

### Summary

| Metric | Value |
|--------|-------|
| **Total Epics** | 11 |
| **Total Stories** | 47 |
| **Total Effort** | 51 person-weeks |
| **Sprint Duration** | 2 weeks |
| **Total Sprints** | 13 (plus 3 optional for BATCH-009) |

---

## Sprint Calendar

| Sprint | Dates | Batches Active | Key Deliverables |
|--------|-------|----------------|------------------|
| Sprint 1 | Weeks 1-2 | BATCH-001, BATCH-002 | Security fixes, subprocess timeout |
| Sprint 2 | Weeks 3-4 | BATCH-001 (complete), BATCH-002 (complete) | Batch 1 & 2 complete |
| Sprint 3 | Weeks 5-6 | BATCH-003, BATCH-008 (start) | Contract alignment begins |
| Sprint 4 | Weeks 7-8 | BATCH-003 (complete), BATCH-008 | Batch 3 complete |
| Sprint 5 | Weeks 9-10 | BATCH-004, BATCH-008 | PowerShell implementation begins |
| Sprint 6 | Weeks 11-12 | BATCH-004, BATCH-008 | Diagnostic stubs implemented |
| Sprint 7 | Weeks 13-14 | BATCH-004, BATCH-008 | AI helpers implemented |
| Sprint 8 | Weeks 15-16 | BATCH-004 (complete), BATCH-008 | Batch 4 complete |
| Sprint 9 | Weeks 17-18 | BATCH-005, BATCH-006, BATCH-010, BATCH-011 | AI pipeline, observability, quality |
| Sprint 10 | Weeks 19-20 | BATCH-005 (complete), BATCH-008 (complete), BATCH-011 | Batch 5, 6, 8, 10 complete |
| Sprint 11 | Weeks 21-22 | BATCH-007, BATCH-011 (complete) | Performance optimization |
| Sprint 12 | Weeks 23-24 | BATCH-007 (complete) | Batch 7, 11 complete |
| Sprint 13+ | Weeks 25-32 | BATCH-009 (optional) | Scalability architecture |

---

## Epic 1: Security Hardening (BATCH-001)

**Epic ID:** BATCH-001  
**Priority:** P0 - CRITICAL  
**Duration:** 4 weeks (Sprints 1-2)  
**Effort:** 4 person-weeks  
**Lead:** TBD (Security-focused engineer)

### Story SEC-001: Remove Invoke-Expression in Get-RemediationAction

**Story ID:** SEC-001  
**Type:** Security Fix  
**Priority:** P0 - CRITICAL  
**Effort:** 3 days (1.5 story points)

**Description:**
Replace `Invoke-Expression` in Get-RemediationAction.ps1:254 with safe parameter resolution using hashtable lookup. This eliminates the command injection vulnerability where attacker-controlled remediation rule properties could execute arbitrary PowerShell.

**Acceptance Criteria:**
- [ ] Parameter placeholders (`$InputContext.*`) resolved via hashtable property access
- [ ] No `Invoke-Expression` used with user-provided data
- [ ] Existing remediation rules continue to work correctly
- [ ] Injection attempt test case passes (malicious input rejected)
- [ ] Unit tests cover happy path and malicious input scenarios

**Technical Notes:**
```powershell
# BEFORE (vulnerable)
$resolvedValue = Invoke-Expression "`$InputContext.$placeholder"

# AFTER (safe)
$resolvedValue = $InputContext[$placeholder]
# OR
$resolvedValue = $InputContext.PSObject.Properties[$placeholder].Value
```

**Definition of Done:**
- [ ] Code change implemented
- [ ] Unit tests added
- [ ] Security test added (injection attempt)
- [ ] Code review by peer + security lead
- [ ] Existing remediation rules tested in dev environment

**Dependencies:** None

**Phase References:**
- Phase 5: SEC-IV-1

---

### Story SEC-002: Protect Service Principal Secrets

**Story ID:** SEC-002  
**Type:** Security Fix  
**Priority:** P0 - CRITICAL  
**Effort:** 2 days (1 story point)

**Description:**
Prevent service principal secrets from being logged in plaintext. The SecureString should never be converted to plaintext for logging, and the azcmagent connect command should be constructed without exposing the secret.

**Acceptance Criteria:**
- [ ] SecureString never converted to plaintext in logs
- [ ] azcmagent connect command constructed without exposing --service-principal-secret value
- [ ] Log output shows "[REDACTED]" or "***" for sensitive values
- [ ] Credential masking test passes

**Technical Notes:**
```powershell
# BEFORE (vulnerable - logs secret)
Write-Verbose "Running: azcmagent connect --service-principal-secret $secret ..."

# AFTER (safe)
Write-Verbose "Running: azcmagent connect --service-principal-secret [REDACTED] ..."
```

**Definition of Done:**
- [ ] Code change implemented
- [ ] Test verifies secrets not in log output
- [ ] Code review by peer + security lead

**Dependencies:** None

**Phase References:**
- Phase 5: SEC-DP-1

---

### Story SEC-003: Fix TLS/Audit/Firewall Invoke-Expression

**Story ID:** SEC-003  
**Type:** Security Fix  
**Priority:** P1 - HIGH  
**Effort:** 3 days (1.5 story points)

**Description:**
Replace `Invoke-Expression` in Set-TLSConfiguration.ps1:46, Set-AuditPolicies.ps1:195, and Set-FirewallRules.ps1:49 with `Start-Process -ArgumentList` to prevent command injection.

**Acceptance Criteria:**
- [ ] Set-TLSConfiguration uses Start-Process for reg.exe operations
- [ ] Set-AuditPolicies uses Start-Process for auditpol operations
- [ ] Set-FirewallRules uses Start-Process for netsh operations
- [ ] All three scripts function correctly with test configurations
- [ ] Injection attempt test cases pass

**Technical Notes:**
```powershell
# BEFORE
Invoke-Expression "reg export `"$regPath`" `"$backupFile`""

# AFTER
$args = @("export", $regPath, $backupFile)
Start-Process -FilePath "reg.exe" -ArgumentList $args -Wait -NoNewWindow
```

**Definition of Done:**
- [ ] All three scripts updated
- [ ] Unit tests for each script
- [ ] Security tests (injection attempts)
- [ ] Integration test with real registry/audit/firewall operations
- [ ] Code review by peer + security lead

**Dependencies:** SEC-001 (pattern established)

**Phase References:**
- Phase 5: SEC-IV-2, SEC-IV-3, SEC-IV-4

---

### Story SEC-004: Add Authorization Checks

**Story ID:** SEC-004  
**Type:** Security Fix  
**Priority:** P1 - HIGH  
**Effort:** 2 days (1 story point)

**Description:**
Add `Test-IsAdministrator` checks to security-sensitive scripts and log caller identity for audit trail.

**Acceptance Criteria:**
- [ ] Test-IsAdministrator function created or verified
- [ ] Security scripts check administrator privilege at start
- [ ] Non-admin execution returns clear error message
- [ ] Caller identity (username, timestamp) logged on execution
- [ ] Unit tests verify privilege check behavior

**Files to Update:**
- Set-TLSConfiguration.ps1
- Set-AuditPolicies.ps1
- Set-FirewallRules.ps1
- Any other scripts modifying security settings

**Definition of Done:**
- [ ] Authorization checks added to all applicable scripts
- [ ] Logging of caller identity implemented
- [ ] Tests verify unauthorized access is denied
- [ ] Code review by peer

**Dependencies:** None

**Phase References:**
- Phase 5: SEC-AC-1 through SEC-AC-4

---

## Epic 2: Resilience & Model Safety (BATCH-002)

**Epic ID:** BATCH-002  
**Priority:** P0 - CRITICAL  
**Duration:** 2 weeks (Sprints 1-2, parallel with BATCH-001)  
**Effort:** 3 person-weeks  
**Lead:** TBD

### Story RES-001: Add Subprocess Timeout

**Story ID:** RES-001  
**Type:** Resilience Fix  
**Priority:** P0 - CRITICAL  
**Effort:** 1 day (0.5 story points)

**Description:**
Add configurable timeout to Python subprocess calls in Get-PredictiveInsights.ps1 to prevent indefinite hangs.

**Acceptance Criteria:**
- [ ] Default 120 second timeout on Python subprocess
- [ ] Timeout configurable via -TimeoutSeconds parameter
- [ ] Timeout returns error object, not exception crash
- [ ] Timeout test passes (verify process killed after timeout)

**Technical Notes:**
```powershell
# Use Start-Process with timeout
$process = Start-Process -FilePath $pythonPath -ArgumentList $args -NoNewWindow -PassThru
$completed = $process.WaitForExit($TimeoutSeconds * 1000)
if (-not $completed) {
    $process.Kill()
    throw "Python subprocess timed out after $TimeoutSeconds seconds"
}
```

**Definition of Done:**
- [ ] Timeout implemented
- [ ] Test verifies timeout behavior
- [ ] Code review by peer

**Dependencies:** None

**Phase References:**
- Phase 4: RES-1.1
- Phase 3: EC-4.3

---

### Story RES-002: Implement Model File Locking

**Story ID:** RES-002  
**Type:** Resilience Fix  
**Priority:** P1 - HIGH  
**Effort:** 3 days (1.5 story points)

**Description:**
Add file locking to joblib.load/dump operations to prevent corruption during concurrent train/predict operations.

**Acceptance Criteria:**
- [ ] File lock acquired before joblib.load()
- [ ] File lock acquired before joblib.dump() (exclusive)
- [ ] Lock released after operation completes
- [ ] Concurrent access test passes (no corruption)
- [ ] Lock timeout configurable (default 30s)

**Technical Notes:**
```python
import filelock

def _load_model_with_lock(self, path: Path) -> Any:
    lock = filelock.FileLock(f"{path}.lock", timeout=30)
    with lock:
        return joblib.load(path)

def _save_model_with_lock(self, model: Any, path: Path) -> None:
    lock = filelock.FileLock(f"{path}.lock", timeout=30)
    with lock:
        joblib.dump(model, path)
```

**Definition of Done:**
- [ ] File locking implemented in predictor.py and model_trainer.py
- [ ] filelock added to dependencies
- [ ] Concurrency test added
- [ ] Code review by peer

**Dependencies:** None

**Phase References:**
- Phase 4: RES-1.2
- Phase 3: EC-4.5

---

### Story RES-003: Add Model Integrity Verification

**Story ID:** RES-003  
**Type:** Security/Resilience Fix  
**Priority:** P1 - HIGH  
**Effort:** 2 days (1 story point)

**Description:**
Add SHA256 checksum verification for model files to detect tampering.

**Acceptance Criteria:**
- [ ] SHA256 checksum computed and saved with model (.sha256 file)
- [ ] Checksum verified on model load
- [ ] Tampered model (checksum mismatch) raises clear error
- [ ] Integrity test passes

**Technical Notes:**
```python
import hashlib

def _compute_checksum(self, path: Path) -> str:
    with open(path, 'rb') as f:
        return hashlib.sha256(f.read()).hexdigest()

def _verify_checksum(self, path: Path) -> bool:
    checksum_path = path.with_suffix(path.suffix + '.sha256')
    if not checksum_path.exists():
        return True  # No checksum = skip verification (legacy models)
    expected = checksum_path.read_text().strip()
    actual = self._compute_checksum(path)
    return expected == actual
```

**Definition of Done:**
- [ ] Checksum generation in model_trainer.py
- [ ] Checksum verification in predictor.py
- [ ] Test for tampered model detection
- [ ] Code review by peer + security lead

**Dependencies:** RES-002 (file locking)

**Phase References:**
- Phase 5: SEC-DS-1

---

### Story RES-004: Implement Degraded Mode

**Story ID:** RES-004  
**Type:** Resilience Fix  
**Priority:** P1 - HIGH  
**Effort:** 2 days (1 story point)

**Description:**
Allow PowerShell module to load and function (for non-AI features) even when ai_config.json is missing.

**Acceptance Criteria:**
- [ ] Module loads without error when ai_config.json missing
- [ ] AI features disabled gracefully (return "AI not configured" message)
- [ ] Non-AI features (deployment, diagnostics) work normally
- [ ] Warning logged about missing AI configuration

**Definition of Done:**
- [ ] Graceful degradation implemented in AzureArcFramework.psm1
- [ ] AI functions return appropriate error when AI unavailable
- [ ] Test for module load without config
- [ ] Code review by peer

**Dependencies:** None

**Phase References:**
- Phase 4: RES-1.3

---

### Story RES-005: Add Retry Logic for External Calls

**Story ID:** RES-005  
**Type:** Resilience Fix  
**Priority:** P2 - MEDIUM  
**Effort:** 2 days (1 story point)

**Description:**
Implement exponential backoff retry logic for ARM API calls and other external service calls.

**Acceptance Criteria:**
- [ ] Retry logic with exponential backoff (3 retries, 1s/2s/4s delays)
- [ ] Jitter added to prevent thundering herd
- [ ] Transient errors (429, 503, network timeout) trigger retry
- [ ] Non-transient errors (400, 401, 404) fail immediately
- [ ] Retry test passes

**Definition of Done:**
- [ ] Retry helper function created
- [ ] Applied to ARM API calls
- [ ] Applied to Log Analytics queries
- [ ] Tests for retry behavior
- [ ] Code review by peer

**Dependencies:** None

**Phase References:**
- Phase 4: RES-2.1 through RES-2.3

---

## Epic 3: Contract Alignment (BATCH-003)

**Epic ID:** BATCH-003  
**Priority:** P0 - CRITICAL  
**Duration:** 2 weeks (Sprints 3-4)  
**Effort:** 4 person-weeks  
**Lead:** TBD

### Story CONT-001: Route -AnalysisType Parameter

**Story ID:** CONT-001  
**Type:** Contract Fix  
**Priority:** P0 - CRITICAL  
**Effort:** 2 days (1 story point)

**Description:**
Make the -AnalysisType parameter (Full/Health/Failure/Anomaly) actually route to specific predictions instead of being ignored.

**Acceptance Criteria:**
- [ ] -AnalysisType Health → only health prediction
- [ ] -AnalysisType Failure → only failure prediction
- [ ] -AnalysisType Anomaly → only anomaly prediction
- [ ] -AnalysisType Full (default) → all predictions
- [ ] Contract tests for each analysis type

**Definition of Done:**
- [ ] Python CLI respects --analysistype parameter
- [ ] PowerShell passes parameter correctly
- [ ] Contract tests added
- [ ] Code review by peer + API owner

**Dependencies:** BATCH-001 complete

**Phase References:**
- Phase 3: CONT-1.1 (API-1.1)

---

### Story CONT-002: Standardize Error Response Format

**Story ID:** CONT-002  
**Type:** Contract Fix  
**Priority:** P0 - CRITICAL  
**Effort:** 2 days (1 story point)

**Description:**
Standardize all error responses to use consistent JSON format.

**Acceptance Criteria:**
- [ ] All errors return: `{"error": "ErrorType", "message": "Description", "timestamp": "ISO8601"}`
- [ ] Success responses include timestamp field
- [ ] No mixed error handling (dict vs exception)
- [ ] CLI scripts exit with code 1 on error

**Definition of Done:**
- [ ] Error format standardized across all Python modules
- [ ] Contract tests for error format
- [ ] Code review by peer + API owner

**Dependencies:** None

**Phase References:**
- Phase 3: CONT-1.2, CONT-2.2

---

### Story CONT-003: Fix _calculate_overall_risk

**Story ID:** CONT-003  
**Type:** Contract Fix  
**Priority:** P0 - CRITICAL  
**Effort:** 1 day (0.5 story points)

**Description:**
Add defensive access to _calculate_overall_risk() to handle error dict from predictor.

**Acceptance Criteria:**
- [ ] Uses .get() for nested key access
- [ ] Returns safe default when predictions unavailable
- [ ] No crash on error dict input
- [ ] Test for error dict handling

**Definition of Done:**
- [ ] Defensive access implemented
- [ ] Unit test added
- [ ] Code review by peer

**Dependencies:** None

**Phase References:**
- Phase 3: CONT-1.3 (XM-5.1)

---

### Story CONT-004: Align Telemetry Feature Names

**Story ID:** CONT-004  
**Type:** Contract Fix  
**Priority:** P1 - HIGH  
**Effort:** 3 days (1.5 story points)

**Description:**
Create canonical feature name mapping and align PowerShell telemetry collection with Python model expectations.

**Acceptance Criteria:**
- [ ] Canonical feature names documented in ai_config.json
- [ ] PowerShell collection outputs canonical names
- [ ] Python models expect canonical names
- [ ] Feature mapping validated end-to-end

**Definition of Done:**
- [ ] Feature mapping in ai_config.json
- [ ] PowerShell telemetry updated
- [ ] Python preprocessor updated
- [ ] Integration test validates feature alignment
- [ ] Code review by peer

**Dependencies:** None

**Phase References:**
- Phase 3: CONT-2.1 (DM-3.1)

---

### Story CONT-005: Fix Exit Codes

**Story ID:** CONT-005  
**Type:** Contract Fix  
**Priority:** P1 - HIGH  
**Effort:** 1 day (0.5 story points)

**Description:**
Ensure Python CLI scripts exit with code 1 on error.

**Acceptance Criteria:**
- [ ] run_predictor.py exits 1 on error (not 0)
- [ ] invoke_ai_engine.py exits 1 on error
- [ ] PowerShell can detect failures via $LASTEXITCODE
- [ ] Test for exit code behavior

**Definition of Done:**
- [ ] Exit codes corrected
- [ ] Tests added
- [ ] Code review by peer

**Dependencies:** None

**Phase References:**
- Phase 3: CONT-2.2 (EC-4.1)

---

### Story CONT-006: Implement Partial Results

**Story ID:** CONT-006  
**Type:** Contract Fix  
**Priority:** P2 - MEDIUM  
**Effort:** 3 days (1.5 story points)

**Description:**
Modify diagnostic chain to return partial results when some components fail.

**Acceptance Criteria:**
- [ ] Failed components logged but don't block others
- [ ] Partial results returned with status per component
- [ ] Clear indication of which components failed
- [ ] Test for partial failure scenario

**Definition of Done:**
- [ ] Partial results pattern implemented
- [ ] Tests for partial failure
- [ ] Code review by peer

**Dependencies:** BATCH-001 complete

**Phase References:**
- Phase 3: CONT-3.1 through CONT-3.4 (XM-5.2)

---

## Epic 4: PowerShell Implementation (BATCH-004)

**Epic ID:** BATCH-004  
**Priority:** P0 - CRITICAL  
**Duration:** 4 weeks (Sprints 5-8)  
**Effort:** 8 person-weeks  
**Lead:** TBD (PowerShell/Azure Arc expert)

### Story PS-001: Implement Diagnostic Stubs (Group 1)

**Story ID:** PS-001  
**Effort:** 3 days  
**Functions:** Get-SystemState, Get-ArcAgentConfig, Get-LastHeartbeat

### Story PS-002: Implement Diagnostic Stubs (Group 2)

**Story ID:** PS-002  
**Effort:** 3 days  
**Functions:** Get-AMAConfig, Get-DataCollectionStatus, Test-ArcConnectivity

### Story PS-003: Implement Network Stubs

**Story ID:** PS-003  
**Effort:** 3 days  
**Functions:** Test-NetworkPaths, Get-ProxyConfiguration, Get-DetailedProxyConfig

### Story PS-004: Implement Compatibility Stubs

**Story ID:** PS-004  
**Effort:** 3 days  
**Functions:** Test-OSCompatibility, Test-TLSConfiguration, Test-LAWorkspace

### Story PS-005: Implement Log Collection Stubs

**Story ID:** PS-005  
**Effort:** 4 days  
**Functions:** Get-ArcAgentLogs, Get-AMALogs, Get-SystemLogs, Get-SecurityLogs

### Story PS-006: Implement Advanced Stubs

**Story ID:** PS-006  
**Effort:** 4 days  
**Functions:** Get-DCRAssociationStatus, Test-CertificateTrust, Get-FirewallConfiguration, Get-PerformanceMetrics

### Story PS-007: Implement AI Helper Functions

**Story ID:** PS-007  
**Effort:** 5 days  
**Functions:** 20 AI helper functions (Normalize-FeatureValue, Calculate-PredictionConfidence, etc.)

### Story PS-008: Implement AI Training Functions

**Story ID:** PS-008  
**Effort:** 5 days  
**Functions:** Import-TrainingData, Update-PatternRecognition, Update-PredictionModels, etc.

### Story PS-009: Convert Monitoring Scripts to Functions

**Story ID:** PS-009  
**Effort:** 2 days  
**Scope:** Wrap 7 monitoring scripts as callable functions

---

## Remaining Epics (Summary)

### Epic 5: AI Pipeline Completion (BATCH-005)
- AI-001: Create Missing Common Modules (2 days)
- AI-002: Create Model Wrapper Classes (2 days)
- AI-003: Train Baseline Models (3 days)
- AI-004: Validate E2E Prediction Flow (2 days)
- AI-005: Create Model Refresh Pipeline (1 day)

### Epic 6: Observability Enhancement (BATCH-006)
- OBS-001: Add Correlation IDs (2 days)
- OBS-002: Structured Logging (2 days)
- OBS-003: Metrics Export (1 day)

### Epic 7: Performance Optimization (BATCH-007)
- PERF-001: Pre-fit Scaler/PCA (2 days)
- PERF-002: Implement Model Caching (3 days)
- PERF-003: Parallelize Predictions (2 days)
- PERF-004: Optimize IPC (1 day)
- PERF-005: Vectorize Correlation Detection (1 day)

### Epic 8: Test Infrastructure (BATCH-008)
- TEST-001: Create Contract Test Suite (5 days)
- TEST-002: Create Security Test Suite (4 days)
- TEST-003: Test Start-ArcDiagnostics (3 days)
- TEST-004: E2E Test Enablement (3 days)
- TEST-005: Performance Benchmark Suite (2 days)

### Epic 9: Scalability Architecture (BATCH-009) - OPTIONAL
- SCALE-001: Design Persistent Service Architecture (2 days)
- SCALE-002: Implement FastAPI Service (5 days)
- SCALE-003: Update PowerShell Integration (3 days)
- SCALE-004: Load Testing & Validation (3 days)
- SCALE-005: Deployment Configuration (2 days)

### Epic 10: Code Quality (BATCH-010)
- QUAL-001: Rename Python Files (1 day)
- QUAL-002: Fix Empty Catch Blocks (1 day)
- QUAL-003: Replace Bare Exceptions (2 days)
- QUAL-004: Standardize PowerShell Keywords (1 day)

### Epic 11: Documentation (BATCH-011)
- DOC-001: Add PowerShell Comment-Based Help (5 days)
- DOC-002: Create ADR Directory & Template (2 days)
- DOC-003: Document Security Architecture (2 days)
- DOC-004: Improve Python Docstrings (3 days)
- DOC-005: Create Operational Runbooks (2 days)

---

## GitHub Issues Import Format

For easy import into GitHub Issues, each story can be created with:

```markdown
## [STORY-ID] Story Title

**Epic:** BATCH-XXX
**Priority:** P0/P1/P2
**Effort:** X days

### Description
[Story description]

### Acceptance Criteria
- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

### Technical Notes
[Implementation guidance]

### Definition of Done
- [ ] Code implemented
- [ ] Tests added
- [ ] Code review complete
- [ ] Documentation updated

### Phase References
- Phase X: Finding-ID

### Dependencies
- Depends on: [list]
- Blocks: [list]
```

---

## Dependency Graph

```
BATCH-001 (Security) ──┬──────────────────────────────────────────────┐
                       │                                               │
BATCH-002 (Resilience) ─┼─┐                                           │
                       │ │                                             │
                       ▼ │                                             │
              BATCH-003 (Contracts) ──┬────────────────────────────┐  │
                       │              │                             │  │
                       │              ▼                             │  │
                       │     BATCH-004 (PowerShell) ────────┐      │  │
                       │              │                      │      │  │
                       │              │                      ▼      │  │
                       │              │             BATCH-005 (AI) ─┼──┤
                       │              │                      │      │  │
                       │              │                      │      │  │
              BATCH-008 (Tests) ◄─────┴──────────────────────┴──────┘  │
                       │                                               │
                       │        BATCH-006 (Observability) ◄────────────┤
                       │              │                                │
                       │        BATCH-010 (Quality) ◄──────────────────┤
                       │              │                                │
                       │        BATCH-011 (Docs) ◄─────────────────────┘
                       │              │
                       ▼              ▼
              BATCH-007 (Performance) ◄─────────────────────────────────
                       │
                       ▼
              BATCH-009 (Scalability) [OPTIONAL]
```

---

*Document Version: 1.0*  
*Last Updated: January 31, 2026*

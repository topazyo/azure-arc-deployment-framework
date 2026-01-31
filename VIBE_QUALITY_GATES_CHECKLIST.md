# VIBE Quality Gates Checklist

**Purpose:** Reusable checklist for every Pull Request and batch completion  
**Version:** 1.0  
**Date:** January 31, 2026

---

## How to Use This Checklist

1. **Copy** the relevant section(s) into your PR description
2. **Check off** each item as you verify it
3. **Request review** only when all required items are checked
4. **Blockers** (✅) must pass before merge; **Warnings** (⚠️) should be addressed but don't block

---

## PR Checklist (All Changes)

### Pre-Submission Verification

**Verify locally before pushing:**

```bash
# Python
python -m flake8 src/Python
python -m black --check src/Python
python -m mypy src/Python
python -m pytest tests/Python -x

# PowerShell
pwsh -Command "Invoke-ScriptAnalyzer -Path ./src/PowerShell -Recurse"
pwsh -Command "Invoke-Pester -Path ./tests/PowerShell -CI"
```

- [ ] All local checks pass

---

### Phase 1: Structural Integrity

- [ ] ✅ No new broken imports or references
- [ ] ✅ All new functions/classes are properly exported (if public)
- [ ] ✅ No new circular dependencies introduced
- [ ] ⚠️ Dead code removed (unused imports, unreachable code)

**If adding new modules:**
- [ ] ✅ `__init__.py` updated with proper exports (Python)
- [ ] ✅ Module manifest updated (PowerShell)

---

### Phase 2: Consistency

**Naming:**
- [ ] ✅ Python files/functions use snake_case
- [ ] ✅ PowerShell functions use Verb-Noun format
- [ ] ✅ Constants are UPPER_SNAKE_CASE
- [ ] ✅ Classes use PascalCase

**Error Handling:**
- [ ] ✅ No empty catch/except blocks
- [ ] ✅ Specific exceptions caught (not bare `except Exception:`)
- [ ] ✅ Errors logged with appropriate level
- [ ] ✅ Error messages are actionable

**Code Organization:**
- [ ] ⚠️ Functions <50 lines (prefer smaller)
- [ ] ⚠️ No deeply nested code (>3 levels)
- [ ] ⚠️ Related code grouped together

---

### Phase 3: Behavioral Contracts

- [ ] ✅ Documented behavior matches implementation
- [ ] ✅ Function signature matches docstring/help
- [ ] ✅ Return types match documentation
- [ ] ✅ Error conditions documented and tested

**If changing API behavior:**
- [ ] ✅ Contract tests updated
- [ ] ✅ Breaking changes documented
- [ ] ⚠️ ADR created for significant changes

---

### Phase 4: Resilience & Observability

**Timeouts:**
- [ ] ✅ I/O operations have timeouts (subprocess, HTTP, file)
- [ ] ✅ Timeout values are configurable or have sensible defaults

**Error Handling:**
- [ ] ✅ External calls wrapped in try/catch
- [ ] ✅ Transient failures have retry logic (where applicable)
- [ ] ✅ Failures return meaningful error objects

**Logging:**
- [ ] ✅ Appropriate log levels used (DEBUG/INFO/WARNING/ERROR)
- [ ] ✅ Log messages include context (what, where, why)
- [ ] ⚠️ Correlation IDs propagated (if cross-process)

**No Single Points of Failure:**
- [ ] ✅ New dependencies have fallback behavior
- [ ] ✅ Missing optional config doesn't crash

---

### Phase 5: Security

**Input Validation:**
- [ ] ✅ User input validated before use
- [ ] ✅ No `Invoke-Expression` with user-controlled data
- [ ] ✅ No SQL/command injection vectors
- [ ] ✅ File paths validated (no path traversal)

**Secrets:**
- [ ] ✅ No secrets hardcoded in code
- [ ] ✅ No secrets logged (including stack traces)
- [ ] ✅ SecureString used for sensitive data (PowerShell)
- [ ] ✅ Credentials loaded from secure sources only

**Authorization:**
- [ ] ✅ Privileged operations check authorization
- [ ] ✅ Admin-only functions verify admin context

**If security-sensitive change:**
- [ ] ✅ Security review requested from security lead

---

### Phase 6: Performance

**Algorithmic Complexity:**
- [ ] ✅ No O(n²) or worse without justification and comment
- [ ] ✅ Large data operations use efficient methods (vectorized, batched)

**Resource Usage:**
- [ ] ✅ Large allocations are bounded
- [ ] ✅ Resources released (connections, file handles)
- [ ] ⚠️ Caching applied where appropriate

**Hot Paths:**
- [ ] ⚠️ No blocking I/O in hot paths
- [ ] ⚠️ Heavy operations deferred or parallelized

---

### Phase 7: Testing

**Coverage:**
- [ ] ✅ Unit tests added for new code
- [ ] ✅ Happy path tested
- [ ] ✅ At least 1 error case tested
- [ ] ⚠️ Edge cases tested (empty input, null, boundary)

**Quality:**
- [ ] ✅ Tests are deterministic (no flaky tests)
- [ ] ✅ Tests are independent (no shared state)
- [ ] ✅ Test names describe what is tested

**If changing contracts:**
- [ ] ✅ Contract tests added/updated

**If security-related:**
- [ ] ✅ Security tests added (injection, auth bypass)

---

### Phase 8: Documentation

**Docstrings/Help:**
- [ ] ✅ Public functions have docstrings (Python) or comment-based help (PowerShell)
- [ ] ✅ Parameters documented
- [ ] ✅ Return values documented
- [ ] ✅ Exceptions/errors documented

**If user-facing change:**
- [ ] ⚠️ README updated
- [ ] ⚠️ Usage examples updated

**If architectural change:**
- [ ] ⚠️ Architecture docs updated
- [ ] ⚠️ ADR created

**If operational change:**
- [ ] ⚠️ Runbook updated

---

## Batch Completion Checklist

Use this when declaring a batch complete.

### Batch: _____________ (e.g., BATCH-001: Security Hardening)

**Stories Completed:**
- [ ] Story 1: _________________ [merged]
- [ ] Story 2: _________________ [merged]
- [ ] Story 3: _________________ [merged]
- [ ] (add more as needed)

**Quality Verification:**

| Criterion | Status | Notes |
|-----------|--------|-------|
| All acceptance criteria met | ☐ | |
| All tests pass | ☐ | |
| No blocking bugs | ☐ | |
| No regressions detected | ☐ | |
| Documentation updated | ☐ | |
| Release notes drafted | ☐ | |

**Metrics:**

| Metric | Before | After | Target | Status |
|--------|--------|-------|--------|--------|
| Test coverage | __% | __% | ≥__% | ☐ |
| Security findings | __ | __ | 0 | ☐ |
| Performance (p95) | __ms | __ms | <__ms | ☐ |

**Sign-off:**
- [ ] Technical Lead: _____________ (date: _______)
- [ ] QA Lead (if applicable): _____________ (date: _______)
- [ ] Security Lead (if applicable): _____________ (date: _______)

**Post-Implementation Review Scheduled:** _____________ (2 weeks post-completion)

---

## Security-Sensitive Change Checklist

Use this **in addition to** the standard checklist for security-related changes.

### Security Review Trigger

**This change is security-sensitive if it:**
- [ ] Handles user authentication or authorization
- [ ] Processes user-provided input
- [ ] Accesses or stores secrets/credentials
- [ ] Modifies system configuration
- [ ] Executes external commands
- [ ] Deserializes data (JSON, pickle, etc.)
- [ ] Handles file paths from external sources

**If any checked, complete the following:**

### Security-Specific Verification

**Injection Prevention:**
- [ ] No string concatenation for commands
- [ ] No `eval()`, `Invoke-Expression` with user data
- [ ] Parameterized queries/commands used
- [ ] Input sanitized/validated

**Authentication/Authorization:**
- [ ] Authentication required for sensitive operations
- [ ] Authorization checked before access
- [ ] Principle of least privilege applied

**Data Protection:**
- [ ] Sensitive data encrypted at rest (if stored)
- [ ] Sensitive data encrypted in transit
- [ ] PII handling compliant with policy

**Logging & Audit:**
- [ ] Security events logged
- [ ] No sensitive data in logs
- [ ] Audit trail for administrative actions

**Security Testing:**
- [ ] Injection tests added
- [ ] Authorization bypass tests added
- [ ] Fuzzing performed (if applicable)

**Security Review:**
- [ ] Requested from: _____________
- [ ] Approved on: _____________

---

## Performance-Critical Change Checklist

Use this **in addition to** the standard checklist for performance-critical changes.

### Performance Review Trigger

**This change is performance-critical if it:**
- [ ] Modifies hot path code (prediction, telemetry processing)
- [ ] Adds new I/O operations
- [ ] Processes large data sets
- [ ] Changes algorithmic approach
- [ ] Adds synchronization (locks, semaphores)

**If any checked, complete the following:**

### Performance-Specific Verification

**Benchmarking:**
- [ ] Baseline performance captured before change
- [ ] Performance tested after change
- [ ] No regression >5% (or justified)

| Metric | Before | After | Threshold | Status |
|--------|--------|-------|-----------|--------|
| P50 latency | __ms | __ms | ±10% | ☐ |
| P95 latency | __ms | __ms | ±10% | ☐ |
| Throughput | __/s | __/s | ±10% | ☐ |
| Memory | __MB | __MB | ±20% | ☐ |

**Code Review:**
- [ ] Algorithm complexity reviewed
- [ ] No unnecessary allocations
- [ ] Efficient data structures used
- [ ] Caching considered

**Load Testing (if applicable):**
- [ ] Tested under expected load
- [ ] Tested under peak load
- [ ] No resource leaks detected

---

## Quick Reference: Severity Levels

| Level | Meaning | Action |
|-------|---------|--------|
| ✅ **Required** | Must be satisfied | Blocks merge if not met |
| ⚠️ **Recommended** | Should be satisfied | Warning, address if possible |
| 💡 **Nice to Have** | Consider if time permits | Optional improvement |

---

## Quick Reference: Review Requirements

| Change Type | Minimum Reviewers | Special Reviewers |
|-------------|-------------------|-------------------|
| Standard code change | 1 peer | - |
| Security-sensitive | 1 peer | Security lead |
| API contract change | 1 peer | API owner |
| Performance-critical | 1 peer | Performance lead |
| Architectural | 1 peer | Tech lead |
| Database schema | 1 peer | DBA (if applicable) |

---

*Checklist Version: 1.0*  
*Based on VIBE Audit Phases 1-9*  
*Last Updated: January 31, 2026*

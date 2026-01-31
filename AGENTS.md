# Azure Arc Predictive Toolkit – Architecture & Governance (Post-Audit: Phases 1–10)

## 🎯 Project Status

**Phases 1–10 Audit: COMPLETE**  
**Phase 10 (Implementation & Continuous Improvement): IN PROGRESS**

This repo contains an Azure Arc deployment/management toolkit with:
- A PowerShell module in `src/Powershell` for deployment, monitoring, remediation, and predictive commands.
- A Python AI/ML stack in `src/Python` for telemetry analysis, anomaly/failure detection, and predictive insights.
- Shared configuration in `src/config` and tests in `tests`.

All future work must respect decisions captured in your audit roadmap (e.g. `VIBE_AUDIT_ROADMAP.md`) and Phase‑specific reports.

---

## 📐 10‑Phase Governance Overview

| Phase | Governance Area | Your Constraint | Status |
|-------|-----------------|-----------------|--------|
| **1. Structural** | Module boundaries, imports, PS⇄Python coupling | No new broken references or circular dependencies; keep clear PS/Python boundaries | ✅ Complete |
| **2. Consistency** | Naming, logging, error‑handling, CLI behaviors | Follow established patterns in PowerShell and Python; no ad‑hoc variations | ✅ Complete |
| **3. Contracts** | CLI args, JSON schemas, config structure | Preserve CLI signatures, JSON shapes, and `aiComponents` contract; breaking changes require escalation | ✅ Complete |
| **4. Resilience** | Timeouts, retries, observability, error JSON | Maintain structured error JSON, avoid unhandled exceptions; keep PS callers robust | ✅ Complete |
| **5. Security** | Secrets, inputs, logging, permissions | No plain‑text secrets; validate input JSON; do not log sensitive data; honor least privilege | ✅ Complete |
| **6. Performance** | Model runtime, pipeline latency, resource usage | No regressions without explicit approval; keep telemetry/analysis within baselines | ✅ Complete |
| **7. Testing** | Coverage, test quality, regression protection | Maintain ≥80% coverage for touched areas; no flaky tests in PS or Python | ✅ Complete |
| **8. Documentation** | Architecture, ADRs, runbooks, onboarding | Keep doc/ADR/runbook updates aligned with behavior changes | ✅ Complete |
| **9. Debt Roadmap** | Prioritization, batching, sequencing | Implement via defined batches; do not re‑prioritize ad‑hoc without updating roadmap | ✅ Complete |
| **10. Implementation** | Weekly execution, metrics, escalation | Track progress weekly; enforce quality gates; escalate blockers within 24h | 🔄 In Progress |

For technical details and examples, see `copilot-instructions.md`.

---

## 🤖 Agent Operating Rules (1‑Line Summary)

Full explanations and examples live in `copilot-instructions.md` (“Agent Operating Mode” section).

1. **Rule 1 – Reference audit findings first**  
   Always start from the audit roadmap and Phase report for the item you are touching.

2. **Rule 2 – Maintain 10‑phase continuity**  
   No change may contradict Phase 1–9 decisions (structure, contracts, security, performance, etc.) without explicit approval.

3. **Rule 3 – Enforce quality gates before merge**  
   Do not consider work “done” until tests, lint, and all relevant phase gates pass.

4. **Rule 4 – Escalate with context, never silently weaken guarantees**  
   If you need to change a contract, relax a security policy, or accept perf regression, escalate with options and impact.

---

## 🏗️ System Architecture Overview

### High-Level Flow

```text
Azure Arc Environment
    ↓ (deployment / management commands)
PowerShell Module [src/Powershell]
    - Initialize / manage Arc deployments
    - Gather telemetry
    - Expose Get-PredictiveInsights and related cmdlets
    ↓ (CLI call with server/telemetry JSON)
Python AI/ML [src/Python]
    - invoke_ai_engine.py (dispatch based on ai_config)
    - predictive_analytics_engine (telemetry + patterns + models)
    - run_predictor.py (direct scoring)
    ↓
Model Artifacts & Config
    - src/config/ai_config.json (aiComponents, model_config)
    - data/models/latest or src/Python/models_placeholder
    ↓
Results
    - JSON back to PowerShell
    - PowerShell converts, displays, or automates remediation
```

### Key Cross-Cutting Concerns

- **Contracts (Phase 3):**
  - PowerShell cmdlets → Python CLI parameters.
  - Python CLIs → JSON output and error schemas.
  - `ai_config.json` → required `aiComponents` key and structure.
- **Resilience (Phase 4):**
  - Structured error JSON for all failures.
  - Stable exit codes for PowerShell to branch on.
- **Security (Phase 5):**
  - No hardcoded secrets in scripts or Python.
  - No logging of telemetry contents that contain sensitive fields without redaction.
- **Testing (Phase 7):**
  - Both PS and Python commands covered by tests.

---

## 📊 Established Patterns (Quick Reference)

Full examples (GOOD/BAD) live in `copilot-instructions.md`.

| Pattern | Area | What “Good” Looks Like |
|--------|------|------------------------|
| PowerShell → Python bridge | `Get-PredictiveInsights.ps1` + `invoke_ai_engine.py` | Stable CLI parameters, JSON in/out, structured error JSON, no raw tracebacks |
| AI config loading | `invoke_ai_engine.py` + `src/config/ai_config.json` | Required `aiComponents` top-level key, clear error JSON when missing/invalid |
| Model discovery | `ArcPredictor`, model dirs | Default model dirs work; `--modeldir` override honored; error JSON when models absent |
| Prediction CLI | `run_predictor.py` | `--analysis-type` and `--telemetrydatajson` stable; returns JSON with `error` on failure |
| Telemetry handling | TelemetryProcessor / ArcPredictor | Feature lists match config; missing fields handled per `missing_strategy`; feature_info respected |
| Testing | `tests/Python`, `tests/PowerShell` | CLIs and cmdlets tested for both success and error JSON paths |
| Dev tooling | init script + hooks | `Initialize-DevEnvironment` sets consistent dev env; pre-commit runs Python+PS tests & lint |

---

## 🧪 Testing Strategy (Post-Audit)

You must maintain and extend tests as you implement Phase 10 work.

### Python

- **Unit tests:**
  - Under `tests/Python`.
  - Cover:
    - `invoke_ai_engine.py` config and error behavior.
    - `run_predictor.py` happy/error paths.
    - Model trainer behavior with minimal configs.
- **Behavior expectations:**
  - CLIs always return valid JSON.
  - Error scenarios use the `error` field, not raw text.
- **Command:**

```
python -m pytest tests/Python
python -m flake8 src/Python
```

### PowerShell

- **Unit/integration tests:**
  - Under `tests/PowerShell`.
  - Cover:
    - Cmdlet availability and parameter binding.
    - `Get-PredictiveInsights` calling Python, parsing JSON, handling error JSON.
- **Static analysis:**

```
pwsh -Command "Invoke-Pester -Path ./tests/PowerShell -CI"
pwsh -Command "Invoke-ScriptAnalyzer -Path ./src/Powershell -Recurse"
```

### Quality Targets

- Coverage for touched areas ≥ 80%.
- Pre‑commit hook (installed via `Initialize-DevEnvironment`) must be green.
- No new flaky tests or intermittent failures.

---

## 📝 Documentation & Audit Alignment

### When You Complete a Debt Item

Update your audit roadmap file (e.g. `VIBE_AUDIT_ROADMAP.md`):

```
### DEBT-ARC-123: [Title]

- Phase: [3 (Contracts) | 4 (Resilience) | 5 (Security) | 6 (Performance) | 7 (Testing) | …]
- Status: OPEN → IN_PROGRESS → FIXED
- Fix PR: [link]
- Metrics Before: [e.g. CLI failures 3%, test coverage 70%]
- Metrics After: [e.g. CLI failures <1%, coverage 85%]
- Validated Against: Phase [X] report
- Implementation Date: [YYYY-MM-DD]
```

### When You Make an Architectural Decision

Create/update an ADR in `docs/adr/`:

- Context: Which Phase’s findings drove this?
- Decision: What changed (e.g. new error JSON schema, new model directory)?
- Rationale: Why this respects audit outcomes?
- Consequences: What gets easier/harder?

### When You Change Operational Behavior

Update runbooks:

- Predictive insights runbook (what cmdlets to run, how to interpret results).
- Telemetry ingestion/feature config runbook.
- Deployment & rollback playbooks for new AI models.

---

## 📅 Phase 10 Weekly Execution Cadence

Use this repo’s structures plus your Phase 9 batch plan (e.g. `VIBE_BATCH_EXECUTION_PLAN.md`).

| Day | Activity | Owner | Notes |
|-----|----------|-------|-------|
| Monday AM | Weekly planning | Human | Choose batch items from current Phase 9 batch; confirm priorities and any dependencies |
| Mon–Thu | Implementation | Agent + Human | Implement code, tests, docs; enforce quality gates; escalate blockers with context |
| Thursday | Code review | Human | Review PRs using QA checklist; request changes or approve and merge |
| Friday AM | Status report | Agent | Generate weekly report (e.g. `VIBE_PROGRESS_REPORTS/week_N.md`) |
| Friday PM | Next‑week prep | Human | Review metrics, update roadmap, confirm next batch items |

---

## 🚀 Getting Started with Phase 10 (This Repo)

### Step 1 – Prep

1. Ensure these exist and are up‑to‑date:
   - Audit roadmap (e.g. `VIBE_AUDIT_ROADMAP.md`).
   - Batch execution plan (e.g. `VIBE_BATCH_EXECUTION_PLAN.md`).
   - Debt inventory (e.g. `VIBE_DEBT_INVENTORY_ACTIVE.md`).
   - QA checklist template (Phase 10 gates).
2. Make sure `copilot-instructions.md` in this repo matches the latest architecture and contracts.

### Step 2 – Initialize Copilot Agent (File-Based, Not Giant Paste)

In VS Code Copilot Chat (or GitHub Copilot web), run:

```
@codebase I'm starting Phase 10 implementation work on the Azure Arc predictive toolkit.

Your key references in this repo are:
- AGENTS.md (governance + architecture overview)
- copilot-instructions.md (detailed playbook: contracts, patterns, workflows)
- VIBE_AUDIT_ROADMAP.md (audit findings and decisions)
- VIBE_BATCH_EXECUTION_PLAN.md (Phase 9 batches and sequencing)
- VIBE_DEBT_INVENTORY_ACTIVE.md (list of debt items with status)

From copilot-instructions.md:
1. Learn the PowerShell↔Python bridge contract.
2. Learn the ai_config.json and aiComponents contract.
3. Learn how error JSON and exit codes must behave.

From AGENTS.md:
1. Learn the 10-phase governance table.
2. Learn the weekly Phase 10 cadence.

Confirm you can read these files and summarize your 4 operating rules in your own words.
```

This avoids “response hit the length limit” by referencing files instead of pasting huge prompts.

### Step 3 – Run Week 1

- Use the current batch in `VIBE_BATCH_EXECUTION_PLAN.md` as the scope.
- Ask Copilot:
  - For each item:
    - Where to change code.
    - Which contracts/phases are in play.
    - What tests to update/add.
- Keep everything tied back to audit items and batches.

---

## 🔗 Cross-References

- `copilot-instructions.md` – Detailed technical playbook for this repo.
- `VIBE_AUDIT_ROADMAP.md` – Full audit findings and decisions.
- `VIBE_BATCH_EXECUTION_PLAN.md` – Batch plan for implementing fixes.
- `VIBE_DEBT_INVENTORY_ACTIVE.md` – Current list of open/closed debt items.
- `docs/Architecture.md`, `docs/AI-Components.md` – High‑level architecture.
- `tests/Python`, `tests/PowerShell` – Where to add and maintain tests.

---

**This file is your governance and orientation layer.**  
**`copilot-instructions.md` is the “how to implement safely” layer.**  
Keep both in sync as the repo evolves.
```

You can now:

- Save the first block as the new `copilot-instructions.md`.
- Save the second block as the new `AGENTS.md`.

If you’d like, I can next help you draft an `VIBE_AUDIT_ROADMAP.md`/`VIBE_BATCH_EXECUTION_PLAN.md` skeleton aligned with how you ran Phases 1–10 on this repo.
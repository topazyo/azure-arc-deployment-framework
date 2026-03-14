# Azure Arc Framework Operations Runbook

**Status:** Expanded working draft
**Created:** 2026-03-13
**Scope:** Batch 8 DOC-003

---

## Purpose

This runbook is the operator-facing entry point for common deployment, validation, troubleshooting, and monitoring workflows in the Azure Arc Framework. It is intentionally anchored to existing source-of-truth documents so it can be expanded without re-inventing procedures.

## Source Mapping

| Runbook Section | Primary Sources |
|-----------------|-----------------|
| Environment prerequisites | `README.md`, `docs/Installation.md`, `docs/Configuration.md` |
| Deployment workflow | `docs/Usage.md`, `README.md` |
| Validation workflow | `README.md`, `docs/Validation-Fixtures.md`, `VIBE/audit/VIBE_QUALITY_GATES_CI.md` |
| Troubleshooting workflow | `docs/Usage.md`, `docs/CLI-Reference.md`, `docs/AI-Components.md` |
| Monitoring and coverage verification | `README.md`, `docs/Performance-Baselines.md`, `VIBE/audit/VIBE_REGRESSION_DETECTION.md`, `/memories/repo/coverage-notes.md` |
| Known caveats | `VIBE/audit/VIBE_PROGRESS_REPORTS/week_of_2026-03-16_kickoff.md`, `VIBE/audit/VIBE_IMPLEMENTATION_BASELINE.md` |

## 1. Environment Prerequisites

### Required platform prerequisites

- Windows Server 2012 R2 or later
- PowerShell 5.1 or higher
- Python 3.8 or higher for AI workflows
- .NET Framework 4.7.2 or higher
- Outbound connectivity to required Azure endpoints

### Required Azure prerequisites

- Azure subscription and target resource group strategy
- Service principal or equivalent credentials with appropriate permissions
- Log Analytics workspace configured through environment variables
- Required Azure resource providers registered before onboarding

### Local operator setup

Use the repository root as the working directory for all local commands in this runbook.

```powershell
Install-Module -Name Az.Accounts -Force
Install-Module -Name Az.Resources -Force
Install-Module -Name Az.ConnectedMachine -Force
Install-Module -Name Az.Monitor -Force
Import-Module src/PowerShell/AzureArcFramework.psd1
Connect-AzAccount
```

```powershell
python -m pip install -r requirements.txt
```

### Local maintainer and workstation variants

Use the automated bootstrap when you need the repository-local PowerShell, Python, and documentation toolchain aligned in one step.

```powershell
pwsh -File .\scripts\Initialize-DevEnvironment.ps1 -CreateVirtualEnv -InstallDependencies
```

Use a manual bootstrap only when profile updates or automated hook changes are not allowed on the workstation.

```powershell
Install-Module -Name Pester -MinimumVersion 5.3.0 -Force -AllowClobber
Install-Module -Name PSScriptAnalyzer -MinimumVersion 1.20.0 -Force -AllowClobber
Install-Module -Name platyPS -MinimumVersion 0.14.2 -Force -AllowClobber
python -m pip install -r requirements.txt
python -m pip install -e .
```

Maintainer notes:

- Prefer `pwsh` for local verification so the same shell family is used as the repo scripts and CI guidance.
- Use the Python interpreter inside the repository virtual environment when one exists, especially for repeatable lint, test, and documentation runs.
- Use `pwsh -NoProfile` for authoritative validation runs when you need to rule out local profile state or leaked mocks.
- Use `pwsh -File .\scripts\Build-Documentation.ps1` when regenerating repository documentation artifacts.

### Preflight checks before touching a server

1. Confirm the active Azure context is the intended subscription and tenant.
2. Confirm the target resource group naming and location strategy.
3. Confirm the Azure Connected Machine agent is installed, or that the installation path is part of the change plan.
4. Confirm any required proxy settings, service principal credentials, and tags before generating the onboarding command.
5. Confirm the configuration files under `src/config/` are the expected versions for the environment.

### Required configuration assets

- `src/config/ai_config.json`
- `src/config/server_inventory.json`
- `src/config/validation_matrix.json`
- Any environment-specific baseline or validation fixtures used by local teams

## 2. Deployment Workflow

### Step 1: Prepare the Azure-side landing zone

Use `Initialize-ArcDeployment` to validate the Azure context and ensure the target resource group exists.

```powershell
Initialize-ArcDeployment \
	-SubscriptionId "<subscription-id>" \
	-ResourceGroupName "<arc-resource-group>" \
	-Location "eastus" \
	-Tags @{ Project = "Arc"; Environment = "Prod" } \
	-WhatIf
```

```powershell
Initialize-ArcDeployment \
	-SubscriptionId "<subscription-id>" \
	-ResourceGroupName "<arc-resource-group>" \
	-Location "eastus" \
	-Tags @{ Project = "Arc"; Environment = "Prod" }
```

Operational notes:

- The cmdlet checks for `Az.Accounts` and `Az.Resources` and requires an authenticated Azure context.
- If the current context is on the wrong subscription, the cmdlet attempts to switch it.
- Use `-WhatIf` first on production changes because the cmdlet supports `SupportsShouldProcess`.

### Step 2: Generate the onboarding command

Use `New-ArcDeployment` to generate the `azcmagent connect` command string for the target server.

```powershell
$deployment = New-ArcDeployment \
	-ServerName "SERVER01" \
	-ResourceGroupName "<arc-resource-group>" \
	-SubscriptionId "<subscription-id>" \
	-Location "eastus" \
	-TenantId "<tenant-id>" \
	-CorrelationId ([guid]::NewGuid().Guid) \
	-Tags @{ Role = "FileServer"; Environment = "Prod" }

$deployment.OnboardingCommand
```

Operational notes:

- `New-ArcDeployment` does not onboard the server directly in the current implementation.
- The cmdlet generates the onboarding command and returns it in `OnboardingCommand`.
- If service principal onboarding is used, both `-ServicePrincipalAppId` and `-ServicePrincipalSecret` must be supplied.
- `-ServicePrincipalSecret` is already typed as `SecureString` and must stay that way.
- Treat the generated command as operational evidence and preserve the correlation ID when one is supplied.

### Step 3: Execute onboarding on the target server

Run the generated `azcmagent connect` command on the target server after the Azure Connected Machine agent is installed.

Execution checklist:

1. Open an elevated PowerShell session on the target server.
2. Confirm the Azure Connected Machine agent is installed and available.
3. Apply any approved proxy settings required by the environment.
4. Execute the generated onboarding command.
5. Record stdout, stderr, and the timestamp of execution.

### Step 4: Record deployment evidence

- Save the generated correlation ID when one is provided
- Capture deployment logs
- Confirm the Arc resource appears in the expected resource group
- Record the exact onboarding command variant that was executed
- Record whether `-WhatIf` was run before the live execution

### Deployment success criteria

Treat deployment as complete only when all of the following are true:

1. The Azure resource group exists in the expected subscription and location.
2. The target server has executed the generated `azcmagent connect` command successfully.
3. The Arc resource appears in Azure in the intended resource group.
4. Post-deployment validation completes without critical health failures.

## 3. Validation Workflow

### Local validation gates

- Python tests: `python -m pytest tests/Python`
- Python lint: `python -m flake8 src/Python`
- PowerShell tests: `pwsh -Command "Invoke-Pester -Path ./tests/PowerShell -CI"`
- PowerShell lint: `pwsh -Command "Invoke-ScriptAnalyzer -Path ./src/PowerShell -Recurse"`

### Configuration and fixture validation

- Validate `ai_config.json` against the schema before runtime use
- Keep fixture identifiers stable in `tests/Powershell/fixtures/`
- Use `docs/Validation-Fixtures.md` when validating remediation rules and drift baselines

Recommended validation order:

1. Run Python lint and tests first because the AI entry points are strict JSON-contract surfaces.
2. Run PowerShell lint and tests next because the orchestration layer depends on stable cmdlet interfaces.
3. Validate remediation and drift fixtures before running workflow-level troubleshooting or remediation.
4. Capture any generated coverage or test artifacts as batch evidence rather than relying on terminal scrollback.

### CI gate expectations

The authoritative merge gates are documented in `VIBE/audit/VIBE_QUALITY_GATES_CI.md`. Local hooks are advisory until the remaining pre-commit debt items are fixed.

### Fresh-shell local verification recipe

Use these commands when you need artifact-backed local verification that is less likely to be contaminated by interactive shell state.

```powershell
pwsh -NoProfile -Command "Import-Module PSScriptAnalyzer; Invoke-ScriptAnalyzer -Path ./src/PowerShell -Recurse"
```

```powershell
pwsh -NoProfile -Command "function global:Read-Host { param([string]`$Prompt) 'n' }; Invoke-Pester -Path ./tests/PowerShell -CI"
```

```powershell
python -m pytest tests/Python
python -m flake8 src/Python
```

Verification notes:

- Use the `Read-Host` stand-in only in the isolated test shell where remediation prompts would otherwise block non-interactive execution.
- Prefer fresh-shell PowerShell runs when validating coverage-sensitive or mock-heavy changes because shared terminals can retain global stand-ins.
- Preserve generated artifacts such as `pester_coverage.xml`, coverage JSON, and stderr JSON instead of relying on terminal scrollback.

### Drift and validation fixtures in operator workflows

For targeted drift validation and remediation testing, prefer the sample fixtures documented in `docs/Validation-Fixtures.md`.

```powershell
Test-ConfigurationDrift -BaselinePath 'C:\baselines\arc-drift.json' -LogPath '.\Logs\drift.log'
```

```powershell
Start-AIRemediationWorkflow \
	-InputData (Get-Content '.\tests\Powershell\fixtures\diagnostics_pattern_sample.json' | ConvertFrom-Json) \
	-RemediationMode Automatic \
	-IssuePatternDefinitionsPath '.\tests\Powershell\fixtures\issue_patterns_sample.json' \
	-RemediationRulesPath '.\tests\Powershell\fixtures\remediation_rules_sample.json' \
	-ValidationRulesPath '.\tests\Powershell\fixtures\validation_rules_sample.json' \
	-LogPath '.\Logs\remediation.log'
```

## 4. Troubleshooting Workflow

### Server diagnostics

- Start with `Start-ArcTroubleshooter` for an end-to-end diagnostic session
- Use `Get-ArcHealthStatus` and related health commands for targeted follow-up

Minimal end-to-end troubleshooting run:

```powershell
Start-ArcTroubleshooter \
	-ServerName 'SERVER01' \
	-WorkspaceId '<log-analytics-workspace-id>' \
	-DetailedAnalysis \
	-OutputPath '.\Logs' \
	-DriftBaselinePath '.\tests\Powershell\fixtures\drift_baseline.json'
```

What the troubleshooter does in order:

1. Collects system state.
2. Runs Arc diagnostics.
3. Optionally runs configuration drift checks.
4. Runs AMA diagnostics if a workspace ID is provided.
5. Invokes troubleshooting analysis.
6. Optionally attempts remediation when `-AutoRemediate` is supplied.
7. Performs final deployment-health validation.
8. Writes a transcript log and a JSON troubleshooting report under the output path.

Artifacts to preserve from each run:

- The session log created by `Start-Transcript`
- The JSON troubleshooting report written at the end of the session
- Any generated diagnostics JSON files under `Diagnostics/`
- The exact baseline path used for drift validation

### Predictive analysis

- Use `Get-PredictiveInsights` for PowerShell-driven AI analysis
- Use `invoke_ai_engine.py` when debugging the full predictive pipeline directly
- Use `run_predictor.py` for inference-only validation against saved model artifacts

Common PowerShell invocation:

```powershell
Get-PredictiveInsights \
	-ServerName 'SERVER01' \
	-AnalysisType Full \
	-AIConfigPath '.\src\config\ai_config.json' \
	-AIModelDirectory '.\src\Python\models_placeholder' \
	-TimeoutSeconds 120 \
	-MaxRetries 2
```

Operational notes:

- `Get-PredictiveInsights` resolves `invoke_ai_engine.py`, validates that Python is callable, and injects a correlation ID if one is not supplied.
- Timeout and retry behavior are part of the current PowerShell wrapper contract.
- Successful responses are parsed from JSON and annotated with `PSServerName`, `PSAnalysisType`, and `PSCorrelationId`.
- Non-zero Python exit codes are treated as failures and should be captured with stderr for incident evidence.

Direct CLI validation example:

```powershell
python .\src\Python\invoke_ai_engine.py --servername SERVER01 --analysistype Full --configpath .\src\config\ai_config.json --modeldir .\src\Python\models_placeholder
```

### Remediation pipeline

- Use `Start-AIRemediationWorkflow` with validated issue-pattern, remediation-rule, and validation-rule packs
- Preserve fixture IDs and remediation action IDs when validating custom rule packs

Recommended workflow sequence:

1. Detect issues from diagnostics input.
2. Resolve remediation actions from the remediation rules pack.
3. Run in `Assisted` mode first for new or modified rule packs.
4. Move to `Automatic` mode only after the action and validation rules are stable.
5. Preserve the action summary object containing `PatternsDetected`, `ActionsResolved`, and `ActionsExecuted`.

Use `Assisted` mode for first-pass validation:

```powershell
Start-AIRemediationWorkflow \
	-InputData $telemetry \
	-RemediationMode Assisted \
	-IssuePatternDefinitionsPath '.\tests\Powershell\fixtures\issue_patterns_sample.json' \
	-RemediationRulesPath '.\tests\Powershell\fixtures\remediation_rules_sample.json' \
	-ValidationRulesPath '.\tests\Powershell\fixtures\validation_rules_sample.json' \
	-LogPath '.\Logs\remediation-assisted.log'
```

Use `Automatic` mode only when the rule pack is already trusted:

```powershell
Start-AIRemediationWorkflow \
	-InputData $telemetry \
	-RemediationMode Automatic \
	-ValidationRulesPath '.\tests\Powershell\fixtures\validation_rules_sample.json' \
	-LogPath '.\Logs\remediation-automatic.log'
```

### Symptom-Based Triage

Use the following table to choose the first diagnostic move instead of jumping straight to full remediation.

| Symptom | Likely first cause area | First action | Preserve as evidence |
|---------|-------------------------|--------------|----------------------|
| Arc resource does not appear after onboarding | Onboarding command execution or wrong Azure target parameters | Re-check the generated `OnboardingCommand`, subscription, tenant, and resource group values; confirm the command was actually run on the target server | Generated onboarding command, command stdout/stderr, correlation ID |
| `New-ArcDeployment` generated a command but onboarding still failed | Target server prerequisites or proxy configuration | Confirm `azcmagent` is installed, run the onboarding command in an elevated session, and verify proxy requirements before retrying | Elevated session transcript, proxy settings used, installation status |
| `Start-ArcTroubleshooter` reports Arc issues before AMA issues | Base Arc connectivity or service health | Review `SystemState` and `ArcDiagnostics` phases first, then rerun with `-DetailedAnalysis` if the failure remains unclear | Troubleshooter transcript, JSON troubleshooting report |
| AMA or workspace-specific failures appear only when `-WorkspaceId` is supplied | Workspace binding, AMA health, or ingestion path | Re-run `Start-ArcTroubleshooter` with the same workspace ID and inspect the AMA diagnostics phase separately from Arc agent health | Troubleshooter report, workspace ID used, AMA-specific logs |
| `Get-PredictiveInsights` throws before returning data | Python runtime, script path, config path, or model path | Validate Python availability, confirm the resolved `invoke_ai_engine.py` path, and confirm `AIConfigPath` and `AIModelDirectory` exist and match the environment | PowerShell stderr, Python stderr JSON, correlation ID |
| Predictive analysis returns output but looks inconsistent with system state | Config drift or placeholder model usage | Compare `ai_config.json`, model directory contents, and recent telemetry inputs before assuming model failure | Config file, model directory path, input payload used |
| Assisted remediation resolves actions but no execution happens | Expected for approval-first flow | Review the summary object and validation rules, then rerun in `Automatic` mode only after confirming the rule pack is trusted | Action summary object, remediation log, validation rules |
| Automatic remediation runs but validation still fails | Rule-pack mismatch or incomplete remediation action | Inspect validation reports, remediation logs, and the canonical fixture IDs before changing implementation code | Validation report, remediation log, exact fixture files |

### Escalation Paths And Ownership

Use role-based escalation paths so incidents are routed by workflow area rather than by whoever noticed the failure first.

| Workflow area | Escalate when | Primary owner role | Evidence package |
|---------------|---------------|--------------------|------------------|
| Azure deployment preparation | Subscription context cannot be set, resource group creation fails, or onboarding targets are wrong | Deployment or platform owner | `Initialize-ArcDeployment` invocation, Azure context details, resource group target |
| Onboarding command generation and execution | `azcmagent connect` cannot be generated, copied, or executed successfully | Arc deployment operator or platform owner | Generated command, proxy or SP variant used, server-side execution transcript |
| Arc and AMA troubleshooting | `Start-ArcTroubleshooter` shows repeated health failures after rerun with evidence | Operations owner for Arc monitoring | Troubleshooter transcript, JSON report, diagnostics artifacts |
| AI predictive analysis | Python runtime, config validation, or model directory issues block `Get-PredictiveInsights` | AI or analytics owner | Correlation ID, stderr JSON, config path, model directory |
| Remediation rule packs and validation packs | Action resolution is wrong, fixture IDs need changes, or validation does not match intended behavior | Remediation workflow owner | Issue-pattern, remediation-rule, and validation-rule files used |
| Coverage or CI measurement disputes | Local rerun disagrees with batch evidence or fresh-shell coverage | Dev workflow or CI owner | Fresh-shell artifacts, Pester output files, coverage summaries |

General support routing:

1. Check logs first.
2. Review the relevant documentation section.
3. Submit a GitHub issue when the failure is reproducible and repo-scoped.
4. Contact the support team when the issue is operationally urgent or environment-specific.

### Onboarding Variants

#### Proxy onboarding example

Use proxy parameters when the target environment requires egress through an approved proxy.

```powershell
$deployment = New-ArcDeployment \
	-ServerName 'SERVER01' \
	-ResourceGroupName '<arc-resource-group>' \
	-SubscriptionId '<subscription-id>' \
	-Location 'eastus' \
	-TenantId '<tenant-id>' \
	-ProxyUrl 'http://proxy.contoso.local:8080' \
	-ProxyBypass 'localhost,127.0.0.1,metadata.azure.com' \
	-CorrelationId ([guid]::NewGuid().Guid)

$deployment.OnboardingCommand
```

Operational notes:

- Apply only approved proxy values for the environment.
- Preserve the exact proxy variant used with the deployment evidence.
- If onboarding still fails, escalate with the generated command and proxy settings rather than paraphrasing them.

#### Service principal onboarding example

Use service principal onboarding only when the deployment plan explicitly requires non-interactive authentication.

```powershell
$securePassword = Read-Host -AsSecureString 'Enter SPN Secret'

$deployment = New-ArcDeployment \
	-ServerName 'SERVER02' \
	-ResourceGroupName '<arc-resource-group>' \
	-SubscriptionId '<subscription-id>' \
	-Location 'westeurope' \
	-TenantId '<tenant-id>' \
	-ServicePrincipalAppId '<spn-app-id>' \
	-ServicePrincipalSecret $securePassword \
	-Tags @{ OS = 'Windows'; Role = 'FileServer' } \
	-CorrelationId ([guid]::NewGuid().Guid)

$deployment.OnboardingCommand
```

Operational notes:

- `-ServicePrincipalSecret` must remain a `SecureString` input.
- Do not store the plain-text value in scripts, notes, or committed config files.
- Preserve the correlation ID and the exact command variant used for incident review.

### Remediation Telemetry And Retrain Export

Use telemetry export only when you need evidence of remediation outcomes or need to hand pending retrain requests to the analytics workflow.

Telemetry-enabled remediation example:

```powershell
Start-AIRemediationWorkflow \
	-InputData $telemetry \
	-ServerName 'SERVER01' \
	-RemediationMode Assisted \
	-EnableRemediationTelemetry \
	-AIConfigPath '.\src\config\ai_config.json' \
	-AIModelDirectory '.\src\Python\models_placeholder' \
	-RetrainExportPath '.\Logs\retrain-requests.json' \
	-LogPath '.\Logs\remediation-telemetry.log'
```

Consume-and-export example for queue-style handoff:

```powershell
Start-AIRemediationWorkflow \
	-InputData $telemetry \
	-ServerName 'SERVER01' \
	-RemediationMode Automatic \
	-EnableRemediationTelemetry \
	-AIConfigPath '.\src\config\ai_config.json' \
	-AIModelDirectory '.\src\Python\models_placeholder' \
	-RetrainExportPath '.\Logs\retrain-requests.json' \
	-ConsumeRetrainQueue \
	-LogPath '.\Logs\remediation-automatic.log'
```

Operational notes:

- Exported retrain requests are operational artifacts and should be preserved with the remediation record.
- If telemetry export fails, preserve the remediation outcome log and escalate with the Python error context rather than rerunning blindly.
- Do not treat retrain export as proof that model retraining has completed; it is only the handoff artifact.

## 5. Monitoring And Coverage Verification Workflow

### Operational monitoring

- Review framework logs for deployment, remediation, and AI execution traces
- Use health and validation commands to confirm expected steady-state behavior
- Cross-check AI outputs against configuration and model artifact locations when behavior looks inconsistent

Primary operator-visible log locations:

- PowerShell framework logs: `C:\ProgramData\AzureArcFramework\Logs`
- Python logs: `C:\ProgramData\AzureArcFramework\Python\Logs`
- Troubleshooter output: the path supplied to `-OutputPath` on `Start-ArcTroubleshooter`
- Batch and validation artifacts in the repository root when running local audit measurements

### Coverage verification

- Python coverage should be captured with `pytest-cov` and stored as JSON when measuring batch changes
- PowerShell coverage must be measured in a fresh shell and treated as authoritative only from fresh-shell artifacts
- Prefer artifact-based coverage review over shared-terminal summaries

Recommended Python coverage command:

```powershell
python -m pytest tests/Python --cov=src/Python --cov-report=json:python_coverage.json
```

PowerShell coverage rules:

1. Run targeted coverage blocks in a fresh shell when validating coverage-sensitive changes.
2. Prefer generated coverage artifacts such as `pester_coverage.xml` over ad hoc terminal summaries.
3. Treat reused shells as non-authoritative because mocks and global stand-ins can leak across runs.

### Incident evidence collection checklist

When capturing evidence for a deployment or troubleshooting incident, preserve:

1. The exact command line or cmdlet invocation.
2. The correlation ID when one exists.
3. The relevant transcript log or stderr JSON.
4. The generated JSON report or diagnostics artifact.
5. The baseline, fixture, or config files used during the run.

## 6. Known Caveats

- Some PowerShell coverage harnesses rely on local execution of remoting scriptblocks.
- Some legacy coverage branches still require temporary global stand-ins instead of ordinary Pester mocks.
- Fresh-shell PowerShell coverage validation remains the authoritative measurement rule.
- Local environment setup can drift from CI, especially when Python or PowerShell tooling is not provisioned yet.
- `New-ArcDeployment` currently generates the onboarding command but does not execute onboarding directly.
- `Get-PredictiveInsights` depends on the PowerShell-to-Python subprocess contract remaining JSON-only.
- Some older documentation examples refer to broader helper commands; prefer the explicitly verified cmdlets and scripts listed in this runbook.

## 7. Condensed Day-2 Operator Checklist

Use this checklist for a normal operating day when you need the shortest safe path.

1. Confirm Azure context, target resource group, and required config files before touching a server.
2. Run `Initialize-ArcDeployment -WhatIf` before live deployment changes.
3. Generate onboarding with `New-ArcDeployment` and preserve the returned `OnboardingCommand` and correlation ID.
4. Execute onboarding only after confirming `azcmagent` installation and any required proxy or service principal inputs.
5. Run validation gates in the recommended order: Python lint and tests, PowerShell lint and tests, then fixture validation.
6. Use `Start-ArcTroubleshooter` first for broad server failures instead of jumping straight to remediation.
7. Use `Get-PredictiveInsights` only after confirming Python, config, and model paths are correct for the environment.
8. Start remediation in `Assisted` mode for new or changed rule packs and move to `Automatic` only when the pack is trusted.
9. Preserve transcripts, JSON reports, stderr JSON, fixture files, and coverage artifacts as the evidence package.
10. Escalate by workflow area with the evidence package instead of summarizing the issue from memory.

## 8. Role-Oriented Operator Examples

Use the same core workflows for all servers, but change the evidence you preserve and the follow-up checks you prioritize based on the role the server plays.

### File server example

Use a role tag and make drift plus storage-related evidence part of the first-pass validation package.

```powershell
$deployment = New-ArcDeployment \
	-ServerName 'FS01' \
	-ResourceGroupName '<arc-resource-group>' \
	-SubscriptionId '<subscription-id>' \
	-Location 'eastus' \
	-TenantId '<tenant-id>' \
	-Tags @{ Role = 'FileServer'; Environment = 'Prod' } \
	-CorrelationId ([guid]::NewGuid().Guid)

$deployment.OnboardingCommand
Test-ConfigurationDrift -BaselinePath '.\tests\Powershell\fixtures\drift_baseline.json' -LogPath '.\Logs\fileserver-drift.log'
Get-ArcHealthStatus -ServerName 'FS01'
```

Operational emphasis:

- Preserve the onboarding command, drift log, and any storage-pressure evidence together.
- If remediation is needed, confirm backup targets are reachable before allowing automatic actions that modify server state.
- Escalate with the exact baseline path and validation output if the file server diverges from the expected hardening baseline.

### Application server example

For application-facing servers, prioritize workspace-linked troubleshooting and predictive analysis evidence after onboarding.

```powershell
$deployment = New-ArcDeployment \
	-ServerName 'APP01' \
	-ResourceGroupName '<arc-resource-group>' \
	-SubscriptionId '<subscription-id>' \
	-Location 'eastus' \
	-TenantId '<tenant-id>' \
	-Tags @{ Role = 'ApplicationServer'; Environment = 'Prod' } \
	-CorrelationId ([guid]::NewGuid().Guid)

$deployment.OnboardingCommand
Start-ArcTroubleshooter -ServerName 'APP01' -WorkspaceId '<workspace-id>' -DetailedAnalysis -OutputPath '.\Logs'
Get-PredictiveInsights -ServerName 'APP01' -AnalysisType Full -AIConfigPath '.\src\config\ai_config.json' -AIModelDirectory '.\src\Python\models_placeholder'
```

Operational emphasis:

- Preserve the troubleshooter report, predictive stderr JSON, and correlation ID as one incident package.
- Re-run with the same workspace ID when AMA-linked failures appear so the evidence stays comparable between attempts.
- If predictive output looks inconsistent, compare the config path and model directory before assuming the app workload itself changed.

## 9. Artifact Reference

Use this appendix when you need to know which command produced an artifact and why it matters.

| Artifact | Produced by | Why it matters |
|----------|-------------|----------------|
| Generated onboarding command | `New-ArcDeployment` | Canonical evidence of the exact Arc onboarding variant used for the target server |
| PowerShell transcript log | `Start-ArcTroubleshooter`, `Start-ArcRemediation` | Timeline of operator-visible actions and command flow during troubleshooting or remediation |
| Troubleshooting JSON report | `Start-ArcTroubleshooter` | Structured output of the full troubleshooting session for escalation and comparison |
| Diagnostics JSON files under `Diagnostics/` | `Start-ArcDiagnostics` and troubleshooting flows that invoke it | Raw diagnostics bundle for Arc and AMA investigation |
| Drift validation log | `Test-ConfigurationDrift` | Record of baseline comparison inputs and detected drift details |
| Remediation activity log | `Start-AIRemediationWorkflow` | Action-resolution, validation, and telemetry-export trace for AI remediation runs |
| Retrain request export JSON | `Start-AIRemediationWorkflow` with `-RetrainExportPath` | Handoff artifact showing pending retrain requests rather than completed retraining |
| Predictive stderr JSON or error output | `Get-PredictiveInsights` / `invoke_ai_engine.py` | Root-cause evidence for Python-side runtime, config, or model failures |
| Python coverage JSON | `pytest --cov --cov-report=json:python_coverage.json` | Artifact-backed Python coverage evidence for audit measurements |
| Pester coverage or validation artifacts | Fresh-shell PowerShell validation runs | Authoritative PowerShell measurement evidence when terminal state is not trustworthy |

## 10. Remaining Gaps

The following items still remain before DOC-003 can be considered review-complete:

1. Tighten wording after a maintainer review of the escalation-role labels.
2. Confirm whether any additional environment-specific examples should be promoted beyond the maintainer-local variants documented here.
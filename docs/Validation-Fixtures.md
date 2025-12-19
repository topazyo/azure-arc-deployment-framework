# Validation and Drift Fixture Examples

This page summarizes the sample JSON fixtures used in tests to illustrate how to author validation rules and drift baselines.

## Issue Patterns (sample)
- Location: tests/Powershell/fixtures/issue_patterns_sample.json
- Purpose: Defines detection rules for `Find-IssuePatterns` (e.g., Arc agent disconnects, service crash loops, extension failures, certificate expiry, policy drift, CPU saturation).
- Shape:
  - Top-level `patterns` array, each entry contains `Id`, `Name`, `Description`, `Category`, and one or more `Rules`.
  - Rule operators support `Equals`, `Contains`, `StartsWith`, `EndsWith`, and numeric comparisons (`GreaterThan`, `LessThanOrEqual`).
- Authoring tips:
  - Use `MatchAll` vs `MatchAny` to combine multiple rules for a pattern.
  - Keep `IssueId` stable; remediation rules reference it to select actions.

## Remediation Rules (sample)
- Location: tests/Powershell/fixtures/remediation_rules_sample.json
- Purpose: Maps `IssueId` to `RemediationActionId` with parameterization for `Get-RemediationAction` and downstream execution.
- Shape:
  - Top-level `remediationRules` array with `IssueId`, `RemediationActionId`, `Description`, and optional `Parameters`.
  - Supports parameter placeholders (e.g., `ServiceName`, `AgentName`, `CertSubject`) that are resolved by the workflow before calling `Start-RemediationAction`.
- Authoring tips:
  - Align `IssueId` values with your pattern pack; add multiple rules per issue when alternates exist.
  - Keep action identifiers consistent with `Start-RemediationAction` implementation so validation rules can target them.

## Validation Rules (sample)
- Location: tests/Powershell/fixtures/validation_rules_sample.json
- Purpose: Demonstrates per-remediation validation rules and merge behaviors.
- Shape:
  - Top-level `validationRules` array.
  - Each entry targets a remediation action via `AppliesToRemediationActionId`.
  - `MergeBehavior` controls how steps combine with generated validation (e.g., `Replace`, `AppendDerived`).
  - `Steps` is an array of validation steps; each includes `ValidationStepId`, `Description`, `ValidationType`, `ValidationTarget`, and `ExpectedResult`. Optional `Parameters` can hold script/function arguments.

Example excerpt:
```json
{
  "validationRules": [
    {
      "AppliesToRemediationActionId": "REM_RULE_ONLY",
      "MergeBehavior": "Replace",
      "Steps": [
        {
          "ValidationStepId": "VR_Simple",
          "Description": "Ensure rule-only validation runs",
          "ValidationType": "ScriptExecutionCheck",
          "ValidationTarget": "C:/temp/rule-only.ps1",
          "ExpectedResult": "Success",
          "Parameters": { "Path": "C:/temp/rule-only.ps1" }
        }
      ]
    },
    {
      "AppliesToRemediationActionId": "REM_APPEND",
      "MergeBehavior": "AppendDerived",
      "Steps": [
        {
          "ValidationStepId": "VR_Base",
          "Description": "Base rule step that should append",
          "ValidationType": "ManualCheck",
          "ValidationTarget": "Operator",
          "ExpectedResult": "Confirmed"
        }
      ]
    }
  ]
}
```

Authoring tips:
- Use `Replace` when rules should override any automatically derived validation steps.
- Use `AppendDerived` to keep derived steps and add your own.
- Match `AppliesToRemediationActionId` with the remediation action id returned by `Start-AIRemediationWorkflow`.

## Drift Baseline (sample)
- Location: tests/Powershell/fixtures/drift_baseline.json
- Purpose: Shows the expected state for configuration drift checks.
- Shape:
  - `registryChecks`: Registry path/name pairs with expected values.
  - `serviceChecks`: Service name with desired startup type and state.
  - `firewallChecks`: Rule expectations (enabled, direction, action).
  - `auditPolicies`: Audit policy names with expected settings.

Example excerpt:
```json
{
  "registryChecks": [
    { "Path": "HKLM:\\SOFTWARE\\Microsoft\\.NETFramework\\v4.0.30319", "Name": "SchUseStrongCrypto", "Expected": 1 },
    { "Path": "HKLM:\\SOFTWARE\\Microsoft\\.NETFramework\\v4.0.30319", "Name": "SystemDefaultTlsVersions", "Expected": 1 }
  ],
  "serviceChecks": [
    { "Name": "himds", "StartupType": "Automatic", "State": "Running" }
  ],
  "firewallChecks": [
    { "Name": "Azure Arc Management", "Enabled": true, "Direction": "Outbound", "Action": "Allow" }
  ],
  "auditPolicies": [
    { "Name": "Process Creation", "Setting": "Success" }
  ]
}
```

Authoring tips:
- Add or remove sections as needed; unused sections can be omitted.
- Keep expected values precise (e.g., service state casing) to avoid false drift alarms.
- Store production baselines outside the repo and supply via parameter or secure storage.

## Diagnostics Sample (pattern detection input)
- Location: tests/Powershell/fixtures/diagnostics_pattern_sample.json
- Purpose: Minimal diagnostics payload used by remediation tests to exercise pattern detection and rule resolution end-to-end.
- Usage: Pass as `-InputData (Get-Content .\tests\Powershell\fixtures\diagnostics_pattern_sample.json | ConvertFrom-Json)` to `Start-AIRemediationWorkflow` when validating custom rule packs.
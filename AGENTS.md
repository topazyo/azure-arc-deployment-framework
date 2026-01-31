# GitHub Copilot Agent Instructions for Vibe Code Audit

## Project Context
This is a vibe-coded project with AI-generated code that may contain:
- Incomplete implementations
- Referenced functions not yet defined
- Inconsistent patterns
- Placeholder logic

## Audit Guidelines
1. **Prioritize by blocking impact**: Critical issues that prevent execution come first
2. **Group by category**: Organize findings by Missing, Broken, Inconsistent, Logic, Security, Quality
3. **Provide working code**: Always supply implementation fixes, not just criticism
4. **Maintain consistency**: Follow existing patterns in the codebase
5. **Update VIBE_AUDIT_ROADMAP.md**: After each significant phase, update the roadmap file

## Implementation Order
Always implement in this sequence:
1. Critical blocking issues (prevents execution)
2. Type/reference errors (breaks compilation)
3. Missing core implementations
4. Consistency improvements
5. Quality/optimization

## Testing Strategy
- Write tests for newly implemented functions
- Run full test suite after each implementation phase
- Document any test gaps or limitations
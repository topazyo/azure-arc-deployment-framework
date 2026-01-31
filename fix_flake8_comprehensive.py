#!/usr/bin/env python
"""Comprehensive flake8 fixer for remaining issues."""

import re
from pathlib import Path


def fix_line_length(line, max_len=79):
    """Attempt to fix long lines by breaking at logical points."""
    if len(line.rstrip()) <= max_len:
        return [line]
    
    # Don't break comments or strings in the middle
    if line.strip().startswith('#'):
        return [line]
    
    # Get indentation
    indent = len(line) - len(line.lstrip())
    indent_str = line[:indent]
    content = line[indent:].rstrip()
    
    # Try to break at commas, operators, etc.
    if ',' in content:
        # Break at commas in function calls or lists
        parts = []
        current = indent_str
        for part in content.split(','):
            if len(current + part) > max_len and current.strip():
                parts.append(current.rstrip() + ',\n')
                current = indent_str + '    ' + part.lstrip()
            else:
                if current.strip() and not current.endswith(' '):
                    current += ','
                current += part if not current.endswith(',') else ' ' + part.lstrip()
        if current.strip():
            parts.append(current + '\n')
        if len(parts) > 1 and all(len(p.rstrip()) <= max_len for p in parts):
            return parts
    
    # If we can't break it cleanly, just return original
    return [line]


def fix_multiple_statements(line):
    """Split multiple statements on one line."""
    # Match simple patterns like: if condition: return value
    match = re.match(r'^(\s*)(if|elif|for|while)\s+([^:]+):\s*(.+)$', line.rstrip())
    if match:
        indent, keyword, condition, statement = match.groups()
        if statement and not statement.strip().startswith('#'):
            # Don't split if it's a one-liner like "if x: y = 1"
            if 'return' in statement or 'break' in statement or 'continue' in statement or 'pass' in statement:
                return [f'{indent}{keyword} {condition}:\n', f'{indent}    {statement}\n']
    return [line]


def fix_indentation(line):
    """Fix indentation to be multiple of 4."""
    if not line.strip():
        return line
    
    indent = len(line) - len(line.lstrip())
    if indent % 4 != 0:
        # Round to nearest multiple of 4
        new_indent = ((indent + 2) // 4) * 4
        return ' ' * new_indent + line.lstrip()
    return line


def fix_file(filepath):
    """Fix remaining flake8 issues in a file."""
    with open(filepath, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    modified = []
    prev_blank = 0
    
    for i, line in enumerate(lines):
        # Track blank lines for E303 (too many blank lines)
        if line.strip() == '':
            prev_blank += 1
            # Limit to 2 blank lines max
            if prev_blank <= 2:
                modified.append('\n')
            continue
        else:
            prev_blank = 0
        
        # Fix indentation (E111, E117)
        line = fix_indentation(line)
        
        # Fix multiple statements (E701) - returns list of lines
        lines_from_split = fix_multiple_statements(line)
        if len(lines_from_split) > 1:
            modified.extend(lines_from_split)
            continue
        
        # Add the line
        modified.append(line)
    
    # Ensure file ends with newline
    if modified and not modified[-1].endswith('\n'):
        modified[-1] += '\n'
    
    # Write back
    with open(filepath, 'w', encoding='utf-8') as f:
        f.writelines(modified)
    
    print(f'Fixed indentation, E701, E303 in {filepath}')


def remove_unused_imports(filepath):
    """Remove obviously unused imports (F401, F811)."""
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()
        lines = content.split('\n')
    
    # Track imports and their usage
    imports = {}
    import_lines = []
    
    for i, line in enumerate(lines):
        if line.strip().startswith('import ') or line.strip().startswith('from '):
            import_lines.append((i, line))
            # Parse simple imports
            if line.strip().startswith('import '):
                parts = line.strip()[7:].split(' as ')
                name = parts[-1].split(',')[0].strip()
                imports[name] = i
            elif ' import ' in line:
                parts = line.split(' import ')[-1].split(' as ')
                for part in parts[-1].split(','):
                    name = part.strip().split()[0]
                    imports[name] = i
    
    # Check if imports are used
    used = set()
    for i, line in enumerate(lines):
        if i not in [il[0] for il in import_lines]:
            for name in imports.keys():
                if name in line:
                    used.add(name)
    
    # Remove unused (be conservative)
    # Don't implement this automatically as it's risky
    
    print(f'Checked imports in {filepath} (manual removal recommended)')


def main():
    files = [
        'src/Python/analysis/telemetry_processor.py',
        'src/Python/predictive/feature_engineering.py',
        'src/Python/predictive/model_trainer.py',
        'src/Python/predictive/ArcRemediationLearner.py',
        'src/Python/predictive/predictor.py',
        'src/Python/predictive/predictive_analytics_engine.py',
    ]
    
    for filepath in files:
        path = Path(filepath)
        if path.exists():
            fix_file(filepath)
            remove_unused_imports(filepath)
        else:
            print(f'File not found: {filepath}')


if __name__ == '__main__':
    main()

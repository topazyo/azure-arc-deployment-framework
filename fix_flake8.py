#!/usr/bin/env python
"""Automated flake8 fixer for common issues."""

import re
import sys
from pathlib import Path


def fix_file(filepath):
    """Fix common flake8 issues in a file."""
    with open(filepath, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    modified = []
    prev_blank_count = 0
    
    for i, line in enumerate(lines):
        original = line
        
        # W293: Remove trailing whitespace on blank lines
        if line.strip() == '':
            line = '\n'
        
        # E701: Multiple statements on one line (colon) - split them
        if ':' in line and not line.strip().startswith('#'):
            # Match patterns like:  if condition: return value
            match = re.match(r'^(\s*)(if|elif|else|for|while|try|except|finally|with|def|class)\s+(.+):\s*(.+)$', line.rstrip())
            if match and not match.group(4).startswith('#'):
                indent, keyword, condition, statement = match.groups()
                # Only split if the statement is actual code (not a comment)
                if statement and not statement.strip().startswith('#'):
                    line = f'{indent}{keyword} {condition}:\n'
                    # Add the statement on the next line with increased indentation
                    next_line = f'{indent}    {statement}\n'
                    modified.append(line)
                    line = next_line
                    continue
        
        # E261: At least two spaces before inline comment
        if '#' in line and not line.strip().startswith('#'):
            # Find the comment
            code_part = line[:line.index('#')]
            comment_part = line[line.index('#'):]
            # Count spaces before comment
            spaces_before = len(code_part) - len(code_part.rstrip())
            if spaces_before < 2 and code_part.strip():
                # Add spaces to make it at least 2
                line = code_part.rstrip() + '  ' + comment_part
        
        # E203: Remove whitespace before ':'
        line = re.sub(r'\s+:', ':', line)
        
        # Track blank lines to handle E303 (too many blank lines)
        if line.strip() == '':
            prev_blank_count += 1
        else:
            prev_blank_count = 0
        
        modified.append(line)
    
    # Write back
    with open(filepath, 'w', encoding='utf-8') as f:
        f.writelines(modified)
    
    print(f'Fixed common issues in {filepath}')


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
        else:
            print(f'File not found: {filepath}')


if __name__ == '__main__':
    main()

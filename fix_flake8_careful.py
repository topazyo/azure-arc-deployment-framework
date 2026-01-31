#!/usr/bin/env python
"""Careful automated flake8 fixer for common issues."""

import re
from pathlib import Path


def fix_file(filepath):
    """Fix common flake8 issues in a file carefully."""
    with open(filepath, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    modified = []
    
    for i, line in enumerate(lines):
        original = line
        
        # W293: Remove trailing whitespace on blank lines
        if line.strip() == '' and line != '\n':
            line = '\n'
        
        # E261: At least two spaces before inline comment (but not breaking code)
        if '#' in line and not line.strip().startswith('#'):
            # Find the comment
            hash_pos = line.index('#')
            code_part = line[:hash_pos]
            comment_part = line[hash_pos:]
            # Count spaces before comment
            if code_part.strip():  # Only if there's actual code before the comment
                # Count trailing spaces in code_part
                code_stripped = code_part.rstrip()
                spaces_before = len(code_part) - len(code_stripped)
                if spaces_before < 2:
                    # Add spaces to make it at least 2
                    line = code_stripped + '  ' + comment_part
        
        # E203: Remove whitespace before ':' (but be careful with slices and type hints)
        # Only remove if it's not part of a slice operation or after 'def' or 'class'
        if ':' in line:
            # Don't fix type hints in function signatures or class definitions
            if not re.match(r'^\s*(def|class)\s+', line):
                # Don't fix dictionary or slice operations
                if '[' not in line or line.index(':') < line.index('['):
                    line = re.sub(r'\s+:(?!:)', ':', line)  # But not for :: (slice with step)
        
        modified.append(line)
    
    # Write back
    with open(filepath, 'w', encoding='utf-8') as f:
        f.writelines(modified)
    
    print(f'Fixed W293, E261, E203 in {filepath}')


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

#!/usr/bin/env python
"""Final pass to fix remaining line length issues."""

import re
from pathlib import Path


def smart_break_line(line, max_len=79):
    """Intelligently break long lines."""
    if len(line.rstrip()) <= max_len:
        return [line]
    
    # Don't break comments in a disruptive way
    if line.strip().startswith('#'):
        return [line]
    
    indent = len(line) - len(line.lstrip())
    indent_str = ' ' * indent
    content = line[indent:].rstrip()
    
    # Strategy 1: Break at logical operators with good precedence
    if ' and ' in content or ' or ' in content:
        parts = []
        for connector in [' and ', ' or ']:
            if connector in content:
                segments = content.split(connector)
                result = []
                current = indent_str + segments[0]
                for i, seg in enumerate(segments[1:], 1):
                    test = current + connector + seg
                    if len(test) > max_len and current.strip():
                        result.append(current.rstrip() + connector + '\n')
                        current = indent_str + '    ' + seg.lstrip()
                    else:
                        current = test
                if current.strip():
                    result.append(current + '\n')
                if len(result) > 1:
                    return result
    
    # Strategy 2: Break at commas in function calls
    if '(' in content and ',' in content:
        paren_pos = content.index('(')
        func_part = content[:paren_pos + 1]
        args_part = content[paren_pos + 1:]
        
        if args_part.count(',') > 0:
            # Break at commas
            result = [indent_str + func_part + '\n']
            args = args_part.split(',')
            for i, arg in enumerate(args):
                if i == len(args) - 1:  # Last argument
                    result.append(indent_str + '    ' + arg.lstrip() + '\n')
                else:
                    result.append(indent_str + '    ' + arg.lstrip() + ',\n')
            if all(len(r.rstrip()) <= max_len for r in result):
                return result
    
    # Strategy 3: Break long strings
    if "'" in content or '"' in content:
        # Find string literals and break them
        quote_char = "'" if "'" in content else '"'
        if content.count(quote_char) >= 2:
            parts = content.split(quote_char)
            if len(parts) >= 3:
                # Try to break the string
                before = quote_char.join(parts[:1])
                string_content = parts[1]
                after = quote_char.join(parts[2:])
                
                if len(string_content) > max_len - indent - 20:
                    # Break the string into chunks
                    chunk_size = max_len - indent - 10
                    chunks = [string_content[i:i+chunk_size] 
                             for i in range(0, len(string_content), chunk_size)]
                    result = []
                    for i, chunk in enumerate(chunks):
                        if i == 0:
                            result.append(indent_str + before + quote_char + chunk + quote_char + '\n')
                        else:
                            result.append(indent_str + quote_char + chunk + quote_char + '\n')
                    if after.strip():
                        result[-1] = result[-1].rstrip('\n') + after + '\n'
                    if all(len(r.rstrip()) <= max_len for r in result):
                        return result
    
    # If we can't break it smartly, return original
    return [line]


def fix_file_final(filepath):
    """Final pass to fix remaining issues."""
    with open(filepath, 'r', encoding='utf-8') as f:
        lines = f.readlines()
    
    modified = []
    
    for line in lines:
        if len(line.rstrip()) > 79:
            broken = smart_break_line(line)
            modified.extend(broken)
        else:
            modified.append(line)
    
    # Write back
    with open(filepath, 'w', encoding='utf-8') as f:
        f.writelines(modified)
    
    print(f'Final pass on {filepath}')


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
            fix_file_final(filepath)
        else:
            print(f'File not found: {filepath}')


if __name__ == '__main__':
    main()

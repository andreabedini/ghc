#!/usr/bin/env python3
"""
Census of CPP conditionals in the compiler and core libraries, grouped into the
categories used by the platform-abstraction plan (see plan.md / Phase 0
classification). Run from the repository root:

    python3 docs/platform-abstraction/census.py

This is a reporting aid for the migration, not a CI gate. The CI guardrail is
testsuite/tests/linters/regex-linters/check-host-cpp.py.
"""

import re
import subprocess
from collections import Counter
from pathlib import Path

COND = re.compile(r'^\s*#\s*(?:if|ifdef|ifndef|elif)\b(.*)$')
IDENT = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
MACHINE_MODEL = {
    'WORDS_BIGENDIAN', 'WORD_SIZE_IN_BITS', 'TABLES_NEXT_TO_CODE',
    'SIZEOF_VOID_P', 'FLOAT_SIZE', 'DOUBLE_SIZE',
}
BUILD_FEATURE = {
    'HAVE_INTERNAL_INTERPRETER', 'CAN_LOAD_DLL', 'HAVE_LIBZSTD', 'HAVE_GHCI',
}


def categorize(tok: str) -> str:
    if tok.endswith('_HOST_OS'):
        return 'host/target-OS'
    if tok.endswith('_HOST_ARCH'):
        return 'host/target-ARCH'
    if tok in MACHINE_MODEL:
        return 'machine-model'
    if tok in BUILD_FEATURE:
        return 'build-feature'
    if tok.startswith('HAVE_'):
        return 'capability(HAVE_*)'
    if tok.startswith('DEBUG'):
        return 'debug'
    if tok.startswith('MIN_VERSION_') or tok == '__GLASGOW_HASKELL__':
        return 'bootstrap-version'
    return 'other'


def tracked(*globs):
    out = subprocess.check_output(['git', 'ls-files', *globs]).decode()
    return [f for f in out.split('\n') if f.endswith(('.hs', '.hsc'))]


def cond_tokens(text):
    for line in text.split('\n'):
        m = COND.match(line)
        if not m:
            continue
        for t in IDENT.findall(m.group(1)):
            if t != 'defined':
                yield t


def main():
    cat_counts = Counter()
    cat_files = {}
    tok_counts = Counter()
    host_files = {'compiler': Counter(), 'libs': Counter()}

    for scope, globs in (('compiler', ['compiler']),
                         ('libs', ['libraries/base', 'libraries/ghc-internal'])):
        for f in tracked(*globs):
            text = Path(f).read_text(errors='ignore')
            for t in cond_tokens(text):
                c = categorize(t)
                cat_counts[c] += 1
                tok_counts[t] += 1
                cat_files.setdefault(c, set()).add(f)
                if c in ('host/target-OS', 'host/target-ARCH'):
                    host_files[scope][f] += 1

    print('=== category counts (compiler + base + ghc-internal) ===')
    for c, n in cat_counts.most_common():
        print(f'{n:5d}  {c:22s}  ({len(cat_files[c])} files)')

    print('\n=== top tokens ===')
    for t, n in tok_counts.most_common(15):
        print(f'{n:5d}  {t}')

    cp = host_files['compiler']
    print(f'\n=== compiler host-OS/ARCH CPP: {len(cp)} files, '
          f'{sum(cp.values())} occurrences (linter baseline) ===')
    for f, n in sorted(cp.items()):
        print(f'  {n:3d}  {f}')

    lp = host_files['libs']
    print(f'\n=== libs host-OS/ARCH CPP (target; out of scope): '
          f'{len(lp)} files, {sum(lp.values())} occurrences ===')


if __name__ == '__main__':
    main()

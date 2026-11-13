#!/usr/bin/env python3
"""Mutation testing for the Lua side: small breaks in one file, run against the specs that should catch them.

Every mutant is made in a temporary copy of the repository (the files git knows, plus new files not yet committed);
the working tree is never touched. A mutant is one change on one line: a flipped comparison (== ~=, >= >, <= <),
and/or swapped, a `not ` dropped, true/false swapped, 0/1 swapped, + and - swapped, or the whole line deleted
(an assignment, a call or a one-line if). Comments and string literals are never mutated. Each mutant is checked with
`luac5.4 -p` first (a mutant that does not parse is skipped), then the specs run one after another and the first one
that fails kills it. A mutant no spec kills SURVIVED: write a test there or explain why it is harmless. The file is
restored in a `finally` after every mutant, and the temporary copy is removed at the end (--keep leaves it).

  python3 tools/mutate.py Crimson-Police/modules/money/cash.lua --specs economy,crash_matrix [--max 40] [--seed 1]
          [--lines 400-620] [--out results.json]
  python3 tools/mutate.py FILE --specs SPEC --only '554:~= => =='      one exact mutant ('LINE:OLD => NEW', the
                                                                         first OLD on the line; NEW 'DEL' deletes
                                                                         the line); --only may repeat
  python3 tools/mutate.py FILE --list [--lines A-B]                     the candidate mutants, nothing is run

The specs run with `lua5.4 tests/run.lua --jobs=N SPEC` (database mode, so MariaDB must be up as for the suite;
--storage=files passes through). Results: one line per mutant (KILLED by <spec> | SURVIVED) and a JSON list with
--out. Exit status: 0 when every mutant was killed, 1 when one survived, 2 on a usage or set-up error.
docs/dev/TESTING.md "Mutation testing".
"""

import argparse
import json
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

OPS = [
    (r'==', '~='),
    (r'~=', '=='),
    (r'(?<![<>=~])>=', '>'),
    (r'(?<![<>=~])<=', '<'),
    (r'(?<![<>=~-])>(?!=)', '>='),
    (r'(?<![<>=~-])<(?!=)', '<='),
    (r'\band\b', 'or'),
    (r'\bor\b', 'and'),
    (r'\bnot ', ''),
    (r'\btrue\b', 'false'),
    (r'\bfalse\b', 'true'),
    (r'(?<![\w.])1(?![\w.])', '0'),
    (r'(?<![\w.])0(?![\w.])', '1'),
    (r' \+ ', ' - '),
    (r' - ', ' + '),
]
DELETABLE = re.compile(r'^\s*(if .* then .*end|[\w.\[\]]+\s*=[^=].*|[\w.:]+\(.*\))\s*$')


def code_mask(lines):
    """Each line with its comments and string literals blanked out (same length), so no mutant lands in them.
    Handles '...', "...", [[...]] / [==[...]==] long strings and comments, and -- line comments."""
    out = []
    long_close = None   # the closing bracket of a long string or comment still open from an earlier line
    for line in lines:
        chars = list(line)
        i, n = 0, len(line)
        while i < n:
            if long_close:
                j = line.find(long_close, i)
                end = n if j < 0 else j + len(long_close)
                for k in range(i, end):
                    chars[k] = ' '
                if j >= 0:
                    long_close = None
                i = end
                continue
            c = line[i]
            if c == '-' and line.startswith('--', i):
                m = re.match(r'--\[(=*)\[', line[i:])
                if m:
                    long_close = ']' + m.group(1) + ']'
                    for k in range(i, i + len(m.group(0))):
                        chars[k] = ' '
                    i += len(m.group(0))
                    continue
                for k in range(i, n):
                    chars[k] = ' '
                break
            m = re.match(r'\[(=*)\[', line[i:])
            if m:
                long_close = ']' + m.group(1) + ']'
                for k in range(i, i + len(m.group(0))):
                    chars[k] = ' '
                i += len(m.group(0))
                continue
            if c in '\'"':
                j = i + 1
                while j < n and line[j] != c:
                    j += 2 if line[j] == '\\' else 1
                for k in range(i, min(j + 1, n)):
                    chars[k] = ' '
                i = j + 1
                continue
            i += 1
        out.append(''.join(chars))
    return out


def candidates(lines, span):
    masked = code_mask(lines)
    found = []
    for i, code in enumerate(masked):
        if span and not (span[0] <= i + 1 <= span[1]):
            continue
        s = code.strip()
        if not s or s.startswith('local function') or s.startswith('function') or s == 'end':
            continue
        for pat, rep in OPS:
            for m in re.finditer(pat, code):
                found.append({'line': i + 1, 'start': m.start(), 'end': m.end(), 'new': rep, 'op': pat + ' -> ' + rep})
        if DELETABLE.match(code) and not s.startswith('local '):
            found.append({'line': i + 1, 'start': None, 'end': None, 'new': 'DEL', 'op': 'delete line'})
    return found


def apply(lines, cand):
    out = list(lines)
    i = cand['line'] - 1
    if cand['new'] == 'DEL':
        out[i] = '-- MUTANT: line deleted'
    else:
        out[i] = out[i][:cand['start']] + cand['new'] + out[i][cand['end']:]
    return out


def parse_only(spec, lines):
    m = re.match(r'^(\d+):(.+?) => (.*)$', spec)
    if not m:
        raise ValueError('--only wants \'LINE:OLD => NEW\', got ' + spec)
    ln, old, new = int(m.group(1)), m.group(2), m.group(3)
    if not 1 <= ln <= len(lines):
        raise ValueError('--only %s: no line %d' % (spec, ln))
    text = lines[ln - 1]
    if new == 'DEL':
        return {'line': ln, 'start': None, 'end': None, 'new': 'DEL', 'op': 'delete line'}
    at = text.find(old)
    if at < 0:
        raise ValueError('--only %s: line %d has no %r: %s' % (spec, ln, old, text.strip()))
    return {'line': ln, 'start': at, 'end': at + len(old), 'new': new, 'op': old + ' -> ' + new}


def copy_repo(dest):
    files = subprocess.run(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT,
                           capture_output=True, check=True).stdout.split(b'\0')
    for f in files:
        if not f:
            continue
        rel = f.decode()
        src = os.path.join(ROOT, rel)
        if not os.path.isfile(src):
            continue   # deleted in the working tree
        dst = os.path.join(dest, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy2(src, dst)


def run_specs(copy, specs, jobs, storage, timeout):
    for sp in specs:
        cmd = ['lua5.4', 'tests/run.lua', '--jobs=%d' % jobs]
        if storage:
            cmd.append('--storage=' + storage)
        cmd.append(sp)
        env = {k: v for k, v in os.environ.items() if k not in ('CP_TEST_DB', 'CP_TEST_SAVES', 'CP_TEST_JOBS')}
        try:
            p = subprocess.run(cmd, cwd=copy, capture_output=True, text=True, timeout=timeout, env=env)
        except subprocess.TimeoutExpired:
            return sp + ' (timeout)'
        if p.returncode != 0 or ' 0 failed, 0 crashed' not in p.stdout:
            return sp
    return None


def main():
    ap = argparse.ArgumentParser(description='Mutation testing on a temporary copy (docs/dev/TESTING.md).')
    ap.add_argument('file', help='the Lua file, relative to the repository root')
    ap.add_argument('--specs', default='', help='comma-separated spec filters for tests/run.lua')
    ap.add_argument('--max', type=int, default=40, help='at most this many random mutants (default 40)')
    ap.add_argument('--seed', type=int, default=1, help='the shuffle seed (default 1)')
    ap.add_argument('--lines', help='only lines A-B')
    ap.add_argument('--only', action='append', default=[], help="one exact mutant 'LINE:OLD => NEW' (repeatable)")
    ap.add_argument('--list', action='store_true', help='print the candidate mutants and stop')
    ap.add_argument('--jobs', type=int, default=4, help='tests/run.lua --jobs (default 4)')
    ap.add_argument('--storage', help='tests/run.lua --storage (default: database)')
    ap.add_argument('--timeout', type=int, default=1200, help='seconds per spec run (default 1200)')
    ap.add_argument('--out', help='write the results as JSON here')
    ap.add_argument('--keep', action='store_true', help='keep the temporary copy (its path is printed)')
    a = ap.parse_args()

    rel = os.path.normpath(a.file)
    path = os.path.join(ROOT, rel)
    if rel.startswith('..') or not os.path.isfile(path) or not rel.endswith('.lua'):
        print('mutate: %s is no Lua file of this repository' % a.file, file=sys.stderr)
        return 2
    lines = open(path, encoding='utf-8').read().split('\n')
    span = None
    if a.lines:
        m = re.match(r'^(\d+)-(\d+)$', a.lines)
        if not m:
            print('mutate: --lines wants A-B', file=sys.stderr)
            return 2
        span = (int(m.group(1)), int(m.group(2)))

    if a.list:
        for c in candidates(lines, span):
            print('%d  %s  | %s' % (c['line'], c['op'], lines[c['line'] - 1].strip()[:120]))
        return 0

    specs = [s for s in a.specs.split(',') if s]
    if not specs:
        print('mutate: --specs is needed (or --list)', file=sys.stderr)
        return 2
    try:
        if a.only:
            muts = [parse_only(s, lines) for s in a.only]
        else:
            muts = candidates(lines, span)
            random.Random(a.seed).shuffle(muts)
            muts = muts[:a.max]
    except ValueError as e:
        print('mutate: %s' % e, file=sys.stderr)
        return 2

    copy = tempfile.mkdtemp(prefix='cp_mutate_')
    results = []
    try:
        copy_repo(copy)
        target = os.path.join(copy, rel)
        original = open(target, encoding='utf-8').read()
        base = run_specs(copy, specs, a.jobs, a.storage, a.timeout)
        if base:
            print('mutate: %s fails on the unchanged code: fix that first' % base, file=sys.stderr)
            return 2
        for c in muts:
            mutated = apply(lines, c)
            try:
                with open(target, 'w', encoding='utf-8') as f:
                    f.write('\n'.join(mutated))
                if subprocess.run(['luac5.4', '-p', target], capture_output=True).returncode != 0:
                    print('SKIPPED   %s:%d  %s  (the mutant does not parse)' % (rel, c['line'], c['op']), flush=True)
                    continue
                killed = run_specs(copy, specs, a.jobs, a.storage, a.timeout)
            finally:
                with open(target, 'w', encoding='utf-8') as f:
                    f.write(original)
            rec = {'line': c['line'], 'op': c['op'], 'orig': lines[c['line'] - 1].strip(),
                   'mutant': mutated[c['line'] - 1].strip(), 'killed': killed}
            results.append(rec)
            print('%s  %s:%d  %s  | %s' % ('KILLED by ' + killed if killed else 'SURVIVED', rel, c['line'], c['op'],
                                           rec['orig'][:120]), flush=True)
    finally:
        if a.keep:
            print('mutate: the copy is kept at ' + copy)
        else:
            shutil.rmtree(copy, ignore_errors=True)
    killed = sum(1 for r in results if r['killed'])
    print('mutate: %d of %d mutants killed' % (killed, len(results)))
    if a.out:
        with open(a.out, 'w', encoding='utf-8') as f:
            json.dump(results, f, indent=1)
    return 0 if killed == len(results) else 1


if __name__ == '__main__':
    sys.exit(main())

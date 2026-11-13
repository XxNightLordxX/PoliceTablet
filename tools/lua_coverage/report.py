#!/usr/bin/env python3
"""tools/lua_coverage/report.py · the report of a measured Lua coverage run (dev tooling, not shipped).

  python3 tools/lua_coverage/report.py DIR...              merge the dumps (cov_*.txt) of DIR..., write
                                                           docs/dev/LUA_COVERAGE.md, exit 1 when a function that never
                                                           ran is not in tools/lua_coverage/allow.txt
  python3 tools/lua_coverage/report.py --write-allow DIR...   also add today's unrun functions to allow.txt as
                                                           'baseline' (only on purpose: a new function should get a
                                                           test or a written reason instead)

Executable lines are the lines luac5.4 -l -l gives an instruction other than RETURN0, VARARGPREP, JMP or CLOSE. A
function is unrun when none of its own lines ran (the lines of the functions inside it are their own). allow.txt:
one line per function, '<file> | <the function's first line, trimmed> | <why it is safe unrun>'; the reason
'baseline' marks one measured unrun on 2026-11-13 that has no written review yet (the list only shrinks). An entry no longer
unrun is reported as stale (not a failure: a run with a different random draw can still reach it). Line level only:
the not-taken side of an if with no else and the operands of a short-circuit are not measured.
"""
import collections, glob, os, re, subprocess, sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..'))
RES = os.path.join(ROOT, 'Crimson-Police')
OUT = os.path.join(ROOT, 'docs', 'dev', 'LUA_COVERAGE.md')
ALLOW = os.path.join(ROOT, 'tools', 'lua_coverage', 'allow.txt')
SKIP_OPS = {'RETURN0', 'VARARGPREP', 'JMP', 'CLOSE'}
# paste-in data, read as data, or never loaded by FXServer as code
EXCLUDE = ('web/', 'missions/builtin/', 'config/examples/')
EXCLUDE_FILES = ('fxmanifest.lua', 'items/ox_inventory_items.lua')
OP_RX = re.compile(r'^\t\d+\t\[(\d+)\]\t(\w+)', re.M)
FN_RX = re.compile(r'(?:main|function) <[^:]+:(\d+),(\d+)>')


def rel(p):
    return os.path.relpath(p, RES).replace(os.sep, '/')


def files():
    out = []
    for p in glob.glob(os.path.join(RES, '**', '*.lua'), recursive=True):
        r = rel(p)
        if r.startswith(EXCLUDE) or '/node_modules/' in r or r in EXCLUDE_FILES:
            continue
        out.append(p)
    return sorted(out, key=rel)


def hits(dirs):
    got, procs = collections.defaultdict(set), 0
    for d in dirs:
        for fn in glob.glob(os.path.join(d, 'cov_*.txt')):
            procs += 1
            with open(fn, encoding='utf-8', errors='replace') as f:
                for line in f:
                    line = line.rstrip('\n')
                    if line.startswith('#') or '\t' not in line:
                        continue
                    src, _, ls = line.partition('\t')
                    i = src.replace(os.sep, '/').find('Crimson-Police/')
                    if i < 0:
                        continue
                    key = os.path.normpath(src.replace(os.sep, '/')[i + len('Crimson-Police/'):]).replace(os.sep, '/')
                    got[key].update(int(x) for x in ls.split(',') if x)
    return got, procs


def analyse(path):
    """(executable lines, [(first, last, own lines)])"""
    listing = subprocess.run(['luac5.4', '-p', '-l', '-l', path], capture_output=True, text=True).stdout
    exe, fns = set(), []
    for blk in re.split(r'\n(?=(?:main|function) <)', listing):
        h = FN_RX.match(blk.lstrip('\n'))
        own = set()
        for m in OP_RX.finditer(blk):
            if m.group(2) not in SKIP_OPS:
                own.add(int(m.group(1)))
        exe |= own
        if h and int(h.group(1)) > 0:
            fns.append((int(h.group(1)), int(h.group(2)), own))
    return exe, fns


def load_allow():
    out = {}
    if os.path.exists(ALLOW):
        with open(ALLOW, encoding='utf-8') as f:
            for line in f:
                if not line.strip() or line.startswith('#'):
                    continue
                parts = [x.strip() for x in line.rstrip('\n').split(' | ')]
                if len(parts) >= 3:
                    out[(parts[0], parts[1])] = ' | '.join(parts[2:])
    return out


def main():
    args = sys.argv[1:]
    write_allow = '--write-allow' in args
    dirs = [a for a in args if a != '--write-allow']
    if not dirs:
        print(__doc__)
        return 2
    got, procs = hits(dirs)
    if procs == 0:
        print('lua-coverage FAIL: no dumps in %s (did cov_init.lua run?)' % ', '.join(dirs))
        return 1
    allow = load_allow()
    rows, unrun = [], []
    for p in files():
        r = rel(p)
        exe, fns = analyse(p)
        h = got.get(r, set())
        rows.append((r, len(exe), len(exe & h)))
        src = open(p, encoding='utf-8', errors='replace').read().split('\n')
        for a, b, own in fns:
            body = own - ({b} if a != b else set())
            if body and not (body & h):
                head = src[a - 1].strip()[:110].replace(' | ', ' / ')
                unrun.append((r, a, head))
    tot = sum(x[1] for x in rows)
    cov = sum(x[2] for x in rows)
    keys = {(r, head) for r, _, head in unrun}
    new = [(r, a, head) for r, a, head in unrun if (r, head) not in allow]
    stale = sorted(k for k in allow if k not in keys)
    if write_allow and new:
        lines = []
        if os.path.exists(ALLOW):
            lines = open(ALLOW, encoding='utf-8').read().rstrip('\n').split('\n')
        for r, _, head in new:
            lines.append('%s | %s | baseline' % (r, head))
            allow[(r, head)] = 'baseline'
        with open(ALLOW, 'w', encoding='utf-8') as f:
            f.write('\n'.join(lines) + '\n')
        new = []
    out = ['# Measured Lua coverage', '',
           'Written by `tools/lua_coverage/report.py` (the opt-in check_all step `lua-coverage`; docs/dev/TESTING.md',
           '"Measured Lua coverage"). Every lua5.4 process of both suites (database and files mode, the fixture',
           'processes the specs start included) ran under a line hook. Line level only: the not-taken side of an `if`',
           'with no `else` and the operands of a short-circuit are not measured. Left out: web/, missions/builtin/',
           '(mission data), config/examples/, fxmanifest.lua and items/ox_inventory_items.lua (paste-in data).', '',
           '## Totals', '',
           '| | |', '|---|---:|',
           '| processes measured | %d |' % procs,
           '| executable lines | %d |' % tot,
           '| lines run | %d (%.1f%%) |' % (cov, 100.0 * cov / max(tot, 1)),
           '| functions never run | %d (%d reviewed, %d baseline, %d not listed) |' % (
               len(unrun), sum(1 for r, _, h in unrun if allow.get((r, h), 'baseline') != 'baseline'),
               sum(1 for r, _, h in unrun if allow.get((r, h)) == 'baseline'), len(new)), '',
           '## Files', '', '| file | lines run | % |', '|---|---:|---:|']
    for r, n, c in rows:
        out.append('| %s | %d / %d | %.1f |' % (r, c, n, 100.0 * c / max(n, 1)))
    out += ['', '## Functions that never ran', '',
            'Each one is in tools/lua_coverage/allow.txt with the reason it is safe unrun, or `baseline`',
            '(measured unrun on 2026-11-13, review pending; give it a test or a reason).', '',
            '| file:line | function | why |', '|---|---|---|']
    for r, a, head in unrun:
        why = allow.get((r, head), '**not listed**').replace('|', '/')
        out.append('| %s:%d | `%s` | %s |' % (r, a, head.replace('`', "'").replace('|', '/'), why))
    out.append('')
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write('\n'.join(out))
    for r, a, head in new:
        print('  - never ran and not in tools/lua_coverage/allow.txt: %s:%d %s' % (r, a, head))
    for r, head in stale:
        print('  - stale allow entry (it ran): %s | %s' % (r, head))
    status = 'PASS' if not new else 'FAIL'
    print('lua-coverage %s: %d processes, %d/%d lines (%.1f%%), %d functions never ran, %d not listed, %d stale' % (
        status, procs, cov, tot, 100.0 * cov / max(tot, 1), len(unrun), len(new), len(stale)))
    return 0 if not new else 1


if __name__ == '__main__':
    sys.exit(main())

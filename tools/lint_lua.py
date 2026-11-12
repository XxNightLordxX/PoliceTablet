#!/usr/bin/env python3
"""General Lua lint for Crimson-Police and its tests (dev tooling, not shipped): luacheck at warning level.

  python3 tools/lint_lua.py                 # every warning, exit 1 on one that is not in the baseline
  python3 tools/lint_lua.py --all           # also print the warnings the baseline accepts
  python3 tools/lint_lua.py --no-baseline   # every warning, baseline ignored
  python3 tools/lint_lua.py --update-baseline
                                            # print a baseline line for every warning (to review and paste)

It runs `luacheck --codes --no-color` (luacheck 1.1.2: `apt-get install lua-check`) over Crimson-Police and
tests with the repository's .luacheckrc: undefined globals read or written, unused locals, values and loop
variables, shadowed locals, unreachable code, empty branches and the rest of luacheck's warnings. What the
.luacheckrc allows (the FiveM natives, the libraries, tests' stubs) is described in the file itself. luacheck
does not look inside global tables: a misspelt field (CP.Moeny) is out of its reach (tools/check_contracts.py
checks the module calls).

Known hits live in tools/lua_lint_baseline.txt, one per line, `<code> <file> <source line> -- <reason>`, in the
format of tools/lint_baseline.txt: the source line is compared without whitespace and with " read as ', so
re-indenting keeps a line valid. A baseline line that no longer matches a hit is reported as stale. A syntax
error (luacheck E011) can never be baselined.
"""
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(ROOT, 'tools', 'lua_lint_baseline.txt')
TARGETS = ['Crimson-Police', 'tests']
HIT = re.compile(r'^(?P<file>[^:]+):(?P<line>\d+):(?P<col>\d+): \((?P<code>[EW]\d+)\) (?P<msg>.*)$')


def norm(code):
    code = re.sub(r'--.*$', '', code)
    return re.sub(r'\s+', '', code).replace('"', "'")


def source_line(path, line, cache={}):
    if path not in cache:
        try:
            with open(os.path.join(ROOT, path), encoding='utf-8', errors='replace') as f:
                cache[path] = f.read().split('\n')
        except OSError:
            cache[path] = []
    lines = cache[path]
    return lines[line - 1] if 0 < line <= len(lines) else ''


def load_baseline():
    entries = []
    if not os.path.exists(BASELINE):
        return entries
    with open(BASELINE, encoding='utf-8') as f:
        for n, raw in enumerate(f, 1):
            s = raw.rstrip('\n')
            if not s.strip() or s.lstrip().startswith('#'):
                continue
            body, _, reason = s.partition(' -- ')
            parts = body.split(' ', 2)
            if len(parts) < 3 or not reason.strip():
                print(f'tools/lua_lint_baseline.txt:{n}: not `<code> <file> <source line> -- <reason>`')
                entries.append(None)
                continue
            entries.append({'code': parts[0], 'file': parts[1], 'key': norm(parts[2]), 'line': n, 'used': 0})
    return entries


def run_luacheck():
    exe = shutil.which('luacheck')
    if not exe:
        print('missing command: luacheck (apt-get install lua-check; tools/setup_test_env.sh --install)')
        sys.exit(1)
    p = subprocess.run([exe, '--codes', '--no-color', '--formatter', 'plain', *TARGETS],
                       cwd=ROOT, capture_output=True, text=True)
    hits, other = [], []
    for raw in p.stdout.splitlines():
        m = HIT.match(raw.strip())
        if m:
            hits.append({'file': m['file'], 'line': int(m['line']), 'col': int(m['col']), 'code': m['code'],
                         'msg': m['msg']})
        elif raw.strip():
            other.append(raw)
    # 0 clean, 1 warnings, 2 errors (syntax), 3+ luacheck itself failed (bad config, unreadable file)
    if p.returncode > 2 or other:
        print('luacheck could not run:')
        for line in other + p.stderr.splitlines():
            print('  ' + line)
        sys.exit(1)
    return hits


def main(argv):
    show_all = '--all' in argv
    no_baseline = '--no-baseline' in argv
    update = '--update-baseline' in argv
    hits = run_luacheck()
    files = len({h['file'] for h in hits})
    if update:
        for h in hits:
            print(f"{h['code']} {h['file']} {source_line(h['file'], h['line']).strip()} -- {h['msg']}")
        return 0
    base = [] if no_baseline else load_baseline()
    bad_lines = sum(1 for e in base if e is None)
    base = [e for e in base if e]
    new, known = [], []
    for h in hits:
        key = norm(source_line(h['file'], h['line']))
        entry = None
        if h['code'] != 'E011':
            for e in base:
                if e['code'] == h['code'] and e['file'] == h['file'] and e['key'] == key:
                    entry = e
                    break
        if entry:
            entry['used'] += 1
            known.append(h)
        else:
            new.append(h)
    for h in new:
        print(f"{h['file']}:{h['line']}:{h['col']}: {h['code']} {h['msg']}")
    if show_all:
        for h in known:
            print(f"{h['file']}:{h['line']}:{h['col']}: {h['code']} {h['msg']} (baseline)")
    stale = [e for e in base if e['used'] == 0]
    for e in stale:
        print(f"tools/lua_lint_baseline.txt:{e['line']}: stale: {e['code']} {e['file']} matches no warning now"
              ' (delete the line)')
    ok = not new and not stale and bad_lines == 0
    print(f'lint-lua: {len(new)} new warnings, {len(known)} in the baseline, {len(stale)} stale baseline lines'
          f' ({len(hits)} luacheck warnings in {files} files)')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

#!/usr/bin/env python3
"""FiveM pitfall lint for Crimson-Police (dev tooling, not shipped).

  python3 tools/lint_fivem.py                 # every rule, exit 1 on a hit that is not in the baseline
  python3 tools/lint_fivem.py --all           # also print the hits the baseline accepts
  python3 tools/lint_fivem.py --no-baseline   # every hit, baseline ignored
  python3 tools/lint_fivem.py --update-natives natives.json natives_cfx.json
                                              # rewrite tools/fivem_natives.txt from runtime.fivem.net's lists

Rules (a hit prints `file:line: RULE message`):
  FX01 native-side      a client-only native called in a server script, or a server-only native in a client
                        script (tools/fivem_natives.txt; the side comes from fxmanifest.lua): nil at run time.
  FX02 source-late      a server RegisterNetEvent handler reads the global `source` after its first statement
                        (a Wait or an await before it resets source).
  FX03 client-os        os.* / io.* in a client or shared script without an `os and` / `io and` guard on the
                        line: the client Lua runtime has neither library.
  FX04 focus-release    SetNuiFocus(false, ...) outside an if: release the focus only while a CP UI holds it
                        (docs/CRIMSON_ARENA.md rule 8).
  FX05 await-raise      lib.callback.await( outside pcall: ox_lib raises on its timeout (300 s) and on an
                        unknown callback. While CP.Net.request itself raises, its direct calls are hits too.
  FX06 orphan-mode      a server script creates networked entities but never calls SetEntityOrphanMode: by
                        default the server deletes them when no player is near.
  FX07 rename-answer    the answer of os.rename is read: FXServer's Linux build returns it inverted (its
                        LocalDevice::RenameFile returns rename() != 0), Windows does not.
  FX08 execute-only     os.execute in a server function with no os.createdir: FXServer refuses every
                        os.execute ("Permission denied"), so the command never runs.
  FX09 arena-natives    SetPlayerTeam, NetworkSetFriendlyFireOption, SetCanAttackFriendly, a routing bucket
                        setter or CancelEvent (docs/CRIMSON_ARENA.md rules 9 to 11).
  FX10 loop-no-yield    a while / repeat loop where one pass can go round with no Wait (no yield, no break, return
                        or error on that path), nothing moves what the condition reads on every pass, and the
                        condition waits on game state: a native (GetGameTimer too: it does not move while the
                        thread runs), a function of the resource that calls one, or a variable the body sets from
                        one. The game (or the server) hangs with no error and no crash log. Also an ipairs loop
                        that appends to the table it walks. The parsing and the flow are in tools/lua_flow.py;
                        `python3 tools/lua_flow.py --all <files>` explains every loop.

Known hits live in tools/lint_baseline.txt, each with its reason: a real bug waiting for its fix (bugs.md of
the fix round) or a deliberate use. A baseline line that no longer matches a hit is reported as stale, so the
fix of a listed bug also removes its line. Lines are matched without whitespace and with " read as ', so
re-indenting or restyling a file keeps its baseline.
"""
import glob, json, os, re, sys
from collections import Counter

import lua_flow

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
RES = os.path.join(ROOT, 'Crimson-Police')
NATIVES = os.path.join(ROOT, 'tools', 'fivem_natives.txt')
BASELINE = os.path.join(ROOT, 'tools', 'lint_baseline.txt')

# Lua scheduler functions that share a name with a game native (SYSTEM::WAIT and friends)
RUNTIME = {'Wait', 'CreateThread', 'SetTimeout', 'Await'}
ARENA = re.compile(r'(?<![\w.:])(SetPlayerTeam|NetworkSetFriendlyFireOption|SetCanAttackFriendly'
                   r'|Set\w*RoutingBucket\w*|CancelEvent)\b')
CREATES = re.compile(r'(?<![\w.:])Create(Ped|Vehicle|VehicleServerSetter|Object|ObjectNoOffset)\s*\(')
CALL = re.compile(r'(?<![\w.:])([A-Z][A-Za-z0-9]+)\s*\(')
DEFS = re.compile(r'\bfunction\s+([A-Z]\w*)\s*\(|\blocal\s+([A-Z]\w*)\s*=|^\s*([A-Z]\w*)\s*=', re.M)
WORDS = re.compile(r'[A-Za-z_]\w*')
OPENERS = {'function', 'do', 'then', 'repeat'}


def read(path):
    with open(path, encoding='utf-8') as f:
        return f.read()


def rel(path):
    return os.path.relpath(path, ROOT).replace(os.sep, '/')


# ── Lua text: per line, the code with strings blanked (analysis) and the code with strings kept (baseline) ──
def lex(src):
    """Two lists of lines: code with every string replaced by '' and comments removed, and code with comments
    removed but strings kept. Line numbers stay those of the source."""
    blank, keep = [], []
    cb, ck = [], []
    i, n = 0, len(src)

    def newline():
        blank.append(''.join(cb))
        keep.append(''.join(ck))
        cb.clear()
        ck.clear()

    def long_close(j):
        m = re.match(r'\[(=*)\[', src[j:])
        return (']' + m.group(1) + ']', len(m.group(0))) if m else (None, 0)

    while i < n:
        c = src[i]
        if c == '\n':
            newline()
            i += 1
        elif src.startswith('--', i):
            close, skip = long_close(i + 2)
            if close:
                end = src.find(close, i + 2 + skip)
                end = n if end < 0 else end + len(close)
                for _ in range(src.count('\n', i, end)):
                    newline()
            else:
                end = src.find('\n', i)
                end = n if end < 0 else end
            i = end
        elif c in '\'"':
            j = i + 1
            while j < n and src[j] != c and src[j] != '\n':
                j += 2 if src[j] == '\\' else 1
            cb.append("''")
            ck.append(src[i:j + 1])
            i = j + 1
        elif c == '[' and long_close(i)[0]:
            close, skip = long_close(i)
            end = src.find(close, i + skip)
            end = n if end < 0 else end + len(close)
            text = src[i:end]
            cb.append("''")
            parts = text.split('\n')
            for k, part in enumerate(parts):
                if k:
                    newline()
                ck.append(part)
            i = end
        else:
            cb.append(c)
            ck.append(c)
            i += 1
    newline()
    return blank, keep


def norm(code):
    return re.sub(r'\s+', '', code).replace('"', "'")


class Blocks:
    """Block structure of a lexed file: every function span (start, end, opened inside `pcall(`), and for
    any (line, column) the kinds of the blocks around it."""

    def __init__(self, lines):
        self.functions = []   # (start line, end line, pcall-wrapped)
        stack = []            # [kind, start line, pcall-wrapped]
        self.stack_at = []    # per line: [(column after a keyword or name, open blocks there)]
        pending_elseif = False
        for ln, code in enumerate(lines, 1):
            marks = []
            for m in WORDS.finditer(code):
                w = m.group(0)
                if w == 'elseif':
                    pending_elseif = True
                elif w == 'then':
                    if pending_elseif:
                        pending_elseif = False
                    else:
                        stack.append(['if', ln, False])
                elif w == 'function':
                    wrapped = re.search(r'\bpcall\s*\(\s*$', code[:m.start()]) is not None
                    stack.append(['function', ln, wrapped])
                elif w in ('do', 'repeat'):
                    stack.append([w, ln, False])
                elif w in ('end', 'until') and stack:
                    kind, start, wrapped = stack.pop()
                    if kind == 'function':
                        self.functions.append((start, ln, wrapped))
                marks.append((m.end(), [s[:] for s in stack]))
            self.stack_at.append(marks)

    def stack(self, ln, col):
        """The open blocks at (line, column), innermost last."""
        best = None
        for end, st in self.stack_at[ln - 1]:
            if end <= col:
                best = st
        if best is not None:
            return best
        for prev in range(ln - 1, 0, -1):
            if self.stack_at[prev - 1]:
                return self.stack_at[prev - 1][-1][1]
        return []

    def innermost_function(self, ln):
        spans = [f for f in self.functions if f[0] <= ln <= f[1]]
        return max(spans, key=lambda f: f[0]) if spans else None


def manifest_sides():
    """path -> 'server' | 'client' | 'shared', from the script lists of fxmanifest.lua."""
    text = read(os.path.join(RES, 'fxmanifest.lua'))
    text = re.sub(r'--\[(=*)\[.*?\]\1\]', '', text, flags=re.S)
    text = re.sub(r'--[^\n]*', '', text)
    sides = {}
    for key, side in (('shared_scripts', 'shared'), ('server_scripts', 'server'), ('client_scripts', 'client')):
        m = re.search(key + r'\s*\{(.*?)\}', text, flags=re.S)
        if not m:
            continue
        for pattern in re.findall(r"'([^']+)'|\"([^\"]+)\"", m.group(1)):
            pattern = pattern[0] or pattern[1]
            if pattern.startswith('@'):
                continue
            for path in glob.glob(os.path.join(RES, pattern), recursive=True):
                sides.setdefault(os.path.normpath(path), side)
    return sides


def load_natives():
    client_only, server_only = set(), set()
    if not os.path.exists(NATIVES):
        return None
    for line in read(NATIVES).splitlines():
        if line.startswith('c '):
            client_only.add(line[2:].strip())
        elif line.startswith('s '):
            server_only.add(line[2:].strip())
    return client_only, server_only


def update_natives(game_json, cfx_json):
    def pascal(name):
        return ''.join(w[:1].upper() + w[1:].lower() for w in name.split('_') if w)

    client, server = set(), set()
    with open(game_json, encoding='utf-8') as f:
        for ns in json.load(f).values():
            for n in ns.values():
                for name in [n.get('name') or ''] + list(n.get('aliases') or []):
                    if name:
                        client.add(pascal(name.lstrip('_')))
    with open(cfx_json, encoding='utf-8') as f:
        for ns in json.load(f).values():
            for n in ns.values():
                if not n.get('name'):
                    continue
                p = pascal(n['name'])
                api = n.get('apiset', 'client')
                if api in ('server', 'shared'):
                    server.add(p)
                if api in ('client', 'shared'):
                    client.add(p)
    keep = lambda s: sorted(x for x in s if re.match(r'^[A-Z][A-Za-z0-9]*$', x))
    client_only, server_only = keep(client - server), keep(server - client)
    with open(NATIVES, 'w', encoding='utf-8') as f:
        f.write('# FiveM natives available on one side only, for tools/lint_fivem.py rule FX01.\n')
        f.write('# From https://runtime.fivem.net/doc/natives.json (game natives: client) and natives_cfx.json\n')
        f.write('# (apiset client / server / shared). Regenerate: python3 tools/lint_fivem.py --update-natives\n')
        f.write('# natives.json natives_cfx.json. "c Name": client only, "s Name": server only.\n')
        for name in client_only:
            f.write('c ' + name + '\n')
        for name in server_only:
            f.write('s ' + name + '\n')
    print(f'{rel(NATIVES)}: {len(client_only)} client-only and {len(server_only)} server-only natives')


def lint():
    sides = manifest_sides()
    natives = load_natives()
    files = sorted(p for p in glob.glob(os.path.join(RES, '**', '*.lua'), recursive=True)
                   if os.path.normpath(p) in sides)
    lexed = {p: lex(read(p)) for p in files}
    global_defs = set()
    for blank, _ in lexed.values():
        for a, b, c in DEFS.findall('\n'.join(blank)):
            global_defs.add(a or b or c)
    hits = []   # (path, line, rule, message, baseline key)

    def add(path, ln, rule, msg):
        keep = lexed[path][1][ln - 1].strip()
        hits.append((rel(path), ln, rule, msg, keep))

    # FX05 first: whether CP.Net.request itself raises decides its call sites
    raising_request = False
    blocks_of = {p: Blocks(lexed[p][0]) for p in files}
    for path in files:
        blank, _ = lexed[path]
        blocks = blocks_of[path]
        for ln, code in enumerate(blank, 1):
            for m in re.finditer(r'lib\.callback\.await\s*\(', code):
                fn = blocks.innermost_function(ln)
                if fn and fn[2]:
                    continue
                add(path, ln, 'FX05', 'lib.callback.await( outside pcall raises on a timeout or an unknown callback')
                if fn and re.search(r'function\s+CP\.Net\.request\b', blank[fn[0] - 1]):
                    raising_request = True

    for path in files:
        side = sides[os.path.normpath(path)]
        blank, keep = lexed[path]
        blocks = blocks_of[path]
        src = '\n'.join(blank)
        local_defs = {a or b or c for a, b, c in DEFS.findall(src)}
        for ln, code in enumerate(blank, 1):
            # FX01
            if natives and side in ('server', 'client'):
                client_only, server_only = natives
                for m in CALL.finditer(code):
                    name = m.group(1)
                    if name in RUNTIME or name in local_defs or name in global_defs:
                        continue
                    if side == 'server' and name in client_only:
                        add(path, ln, 'FX01', f'{name} is a client-only native (this is a server script)')
                    elif side == 'client' and name in server_only:
                        add(path, ln, 'FX01', f'{name} is a server-only native (this is a client script)')
            # FX03
            if side in ('client', 'shared') and re.search(r'(?<![\w.:])(os|io)\.\w+', code) \
                    and not re.search(r'\b(os|io)\s+and\b', code):
                add(path, ln, 'FX03', 'os/io used where the client Lua runtime has neither library')
            # FX04
            for m in re.finditer(r'(?<![\w.:])SetNuiFocus\s*\(\s*false\b', code):
                if not any(b[0] == 'if' for b in blocks.stack(ln, m.start())):
                    add(path, ln, 'FX04', 'SetNuiFocus(false, ...) outside an if (only while a CP UI holds the focus)')
            # FX05, the call sites of a raising CP.Net.request
            if raising_request:
                for m in re.finditer(r'(?<![\w.:])CP\.Net\.request\s*\(', code):
                    if re.search(r'\bfunction\s+$', code[:m.start()]):
                        continue
                    fn = blocks.innermost_function(ln)
                    if fn and fn[2]:
                        continue
                    add(path, ln, 'FX05', 'CP.Net.request( outside pcall while CP.Net.request raises (lib.callback.await)')
            # FX07
            if re.search(r'(?<![\w.:])os\.rename\s*\(|\bpcall\s*\(\s*os\.rename\b', code) \
                    and not re.match(r'^\s*(pcall\s*\(\s*)?os\.rename\s*[(,].*\)\s*;?\s*$', code):
                add(path, ln, 'FX07', "os.rename's answer is read: FXServer on Linux returns it inverted")
            # FX08
            if side == 'server' and re.search(r'(?<![\w.:])os\.execute\s*\(|\bpcall\s*\(\s*os\.execute\b', code):
                fn = blocks.innermost_function(ln)
                span = blank[fn[0] - 1:fn[1]] if fn else blank
                if not any(re.search(r'\bos\.createdir\b', c) for c in span):
                    add(path, ln, 'FX08', 'os.execute with no os.createdir: FXServer refuses every os.execute')
            # FX09
            for m in ARENA.finditer(code):
                add(path, ln, 'FX09', f'{m.group(1)} is forbidden (docs/CRIMSON_ARENA.md rules 9 to 11)')
        # FX02
        if side == 'server':
            for ln, code in enumerate(blank, 1):
                m = re.search(r'\bRegisterNetEvent\s*\(.*?\bfunction\s*\([^)]*\)', code)
                if not m:
                    continue
                starting = [f for f in blocks.functions if f[0] == ln]
                fn = max(starting, key=lambda f: f[1]) if starting else None
                if not fn:
                    continue
                first = ln if code[m.end():].strip() else None
                for j in range(ln, fn[1] + 1):
                    body = blank[j - 1][m.end():] if j == ln else blank[j - 1]
                    if first is None and body.strip():
                        first = j
                    if j != first and re.search(r'(?<![\w.:])source\b', body):
                        add(path, j, 'FX02', 'the global source is read after the first statement of a net handler')
        # FX06
        if side == 'server' and CREATES.search(src) and not re.search(r'\bSetEntityOrphanMode\b', src):
            ln = next(k for k, c in enumerate(blank, 1) if CREATES.search(c))
            add(path, ln, 'FX06', 'networked entities without SetEntityOrphanMode (the default deletes them when'
                                  ' no player is near)')
    # FX10: every file at once (a helper that always waits may live in another file)
    findings, errors = lua_flow.loop_findings({p: read(p) for p in files})
    for path, ln, verdict, kind, cond, where, note in findings:
        if verdict == 'HIT':
            add(path, ln, 'FX10', f'{kind} loop ({cond}) in {where}: {note}')
    for path, err in errors:
        m = re.search(r'line (\d+)', err)
        add(path, int(m.group(1)) if m else 1, 'FX10', f'tools/lua_flow.py cannot parse this file ({err}): its '
                                                      'loops were not checked')
    return hits, len(files), natives is not None


def load_baseline():
    entries = []   # (rule, file, code, reason, line number in the baseline)
    if not os.path.exists(BASELINE):
        return entries
    for i, line in enumerate(read(BASELINE).splitlines(), 1):
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        m = re.match(r'^(FX\d\d)\s+(\S+)\s+(.*?)\s+--\s+(.+)$', line)
        if not m:
            print(f'{rel(BASELINE)}:{i}: not "<rule> <file> <code> -- <reason>"')
            entries.append(('?', '?', '?', '?', i))
            continue
        entries.append((m.group(1), m.group(2), m.group(3), m.group(4), i))
    return entries


def main(argv):
    if argv[:1] == ['--update-natives']:
        if len(argv) != 3:
            print('usage: tools/lint_fivem.py --update-natives natives.json natives_cfx.json')
            return 2
        update_natives(argv[1], argv[2])
        return 0
    show_all = '--all' in argv
    use_baseline = '--no-baseline' not in argv
    unknown = [a for a in argv if a not in ('--all', '--no-baseline')]
    if unknown:
        print(f'unknown option {unknown[0]} (tools/lint_fivem.py --help)' if unknown[0] not in ('-h', '--help')
              else __doc__.strip())
        return 0 if unknown[0] in ('-h', '--help') else 2
    hits, nfiles, have_natives = lint()
    entries = load_baseline() if use_baseline else []
    bad_lines = [e for e in entries if e[0] == '?']
    pool = Counter((e[0], e[1], norm(e[2])) for e in entries if e[0] != '?')
    accepted, new = [], []
    for h in sorted(hits, key=lambda h: (h[0], h[1], h[2])):
        key = (h[2], h[0], norm(h[4]))
        if pool[key] > 0:
            pool[key] -= 1
            accepted.append(h)
        else:
            new.append(h)
    stale = []
    left = Counter(pool)
    for e in entries:
        if e[0] == '?':
            continue
        key = (e[0], e[1], norm(e[2]))
        if left[key] > 0:
            left[key] -= 1
            stale.append(e)
    for h in new:
        print(f'{h[0]}:{h[1]}: {h[2]} {h[3]}')
    if show_all:
        for h in accepted:
            print(f'{h[0]}:{h[1]}: {h[2]} {h[3]} (baseline)')
    for e in stale:
        print(f'{rel(BASELINE)}:{e[4]}: stale: {e[0]} {e[1]} no longer has this hit; delete the line')
    if not have_natives:
        print(f'{rel(NATIVES)} is missing: rule FX01 did not run')
    per_rule = Counter(h[2] for h in hits)
    print('hits by rule: ' + (', '.join(f'{k} {v}' for k, v in sorted(per_rule.items())) or 'none')
          + f' ({nfiles} Lua files)')
    ok = not new and not stale and not bad_lines and have_natives
    print(f'lint_fivem {"PASS" if ok else "FAIL"}: {len(new)} new hits, {len(accepted)} known (baseline), '
          f'{len(stale)} stale baseline lines')
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

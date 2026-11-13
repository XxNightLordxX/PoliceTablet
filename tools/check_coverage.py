#!/usr/bin/env python3
"""The coverage list of Crimson-Police (dev tooling, not shipped). Run by tools/check_all.sh as lint-coverage.

  python3 tools/check_coverage.py            # exit 1 when docs/dev/COVERAGE.md is not the list of today's code,
                                             # or a client entry point has no spec that drives it (and is not a
                                             # known gap in tools/coverage_gaps.txt)
  python3 tools/check_coverage.py --write    # rewrite docs/dev/COVERAGE.md (and drop the stale gaps)
  python3 tools/check_coverage.py --write-gaps   # also list today's undriven client entry points as known gaps
                                                 # (only on purpose: a new entry point should get a spec instead)

docs/dev/COVERAGE.md has one row per function: every Lua function of Crimson-Police (function X.y, local function
Name, X.y = function, a table field name = function) and every exported function of web/src (not the walks and
mocks), and one row per client entry point (a client net event, an NUI callback, a client callback, command, export
and client action). Each row has its file:line, what it must do (the first sentence of the comment above it) and the
spec that runs it:
  <spec>        a spec that loads the file (by its path, or a fixture it loads) and names the function or entry point
  via <spec>    no spec names it, but this spec loads the file and runs it through its callers
  world         only the whole-server or whole-client worlds load the file (tests/workflows_full_spec.lua and the
                specs on its world; loops_spec, resmon_spec and escrow_boot_spec load every client script)
  walk <file>   a web walk (src/**/*.walk.ts) names it or imports its module
  none          nothing runs it
A client entry point counts as driven only when a spec that loads its own client file fires or calls it (comments
and the lines that only look at what the server sent, such as H.findEvents, never count): an event by its full
name ('client:x' or 'crimson-police:client:x', or the bare 'x' on a call line of a spec that builds the name with
'crimson-police:client:' ..); an NUI callback, client action, callback, command or export by a call (.x( :x( ['x'](),
as the first argument of a call (Client('x'), Act('x')), or as name = 'x' (the NUI 'client' endpoint). Events
registered under the literal 'crimson-police:client:x' count as client:x. The server specs that only see the server
send it do not count. The entry points with no such spec are listed in
tools/coverage_gaps.txt (`<kind> <name> <file>`); a new one fails here, and a listed one that a spec now drives is
stale (--write drops it). docs/dev/TESTING.md "Coverage list".
"""
import glob, os, re, sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
RES = os.path.join(ROOT, 'Crimson-Police')
OUT = os.path.join(ROOT, 'docs', 'dev', 'COVERAGE.md')
GAPS = os.path.join(ROOT, 'tools', 'coverage_gaps.txt')

LUA_FN = [
    re.compile(r'^\s*(?:local\s+)?function\s+([A-Za-z_][\w.:]*)\s*\('),
    re.compile(r'^\s*(?:local\s+)?([A-Za-z_][\w.]*)\s*=\s*function\s*\('),
]
TS_FN = [
    re.compile(r'^export\s+(?:default\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)'),
    re.compile(r'^export\s+const\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s+)?(?:\(|function\b|<|[A-Za-z_$][\w$]*\s*=>)'),
]
ENTRY = [
    ('event', re.compile(r"RegisterNetEvent\(\s*CP\.e\(\s*'(client:[^']+)'\s*\)")),
    ('event', re.compile(r"RegisterNetEvent\(\s*'([^']+)'")),
    ('nui', re.compile(r"RegisterNUICallback\(\s*'([^']+)'")),
    ('callback', re.compile(r"lib\.callback\.register\(\s*CP\.e\(\s*'(client:[^']+)'\s*\)")),
    ('command', re.compile(r"RegisterCommand\(\s*'([^']+)'")),
    ('export', re.compile(r"exports\(\s*'([^']+)'")),
    ('action', re.compile(r"registerClientAction\(\s*'([^']+)'")),
]


def rel(p, base=ROOT):
    return os.path.relpath(p, base).replace(os.sep, '/')


def read(p):
    with open(p, encoding='utf-8', errors='replace') as f:
        return f.read()


def first_sentence(lines):
    text = ' '.join(l.strip() for l in lines if l.strip())
    text = re.sub(r'\s+', ' ', text).strip()
    if not text:
        return ''
    m = re.match(r'(.+?[.!?])(\s|$)', text)
    s = m.group(1) if m else text
    # plain text in a table cell: no column break, and CP[a](...) is not a markdown link
    s = s.replace('|', '/').replace('](', '] (')
    return s if len(s) <= 140 else s[:137].rstrip() + '...'


def comment_above(lines, i, lua):
    """The comment block right above line i (0-based)."""
    out = []
    j = i - 1
    while j >= 0:
        t = lines[j].strip()
        if lua and t.startswith('--'):
            out.insert(0, re.sub(r'^-+\s?', '', t))
        elif not lua and (t.startswith('//') or t.startswith('*') or t.startswith('/*')):
            t = re.sub(r'^(/\*\*?|\*/|\*|//)\s?', '', t)
            t = re.sub(r'\*/$', '', t)
            out.insert(0, t)
        else:
            break
        j -= 1
    # a file's head comment is not the function's
    if j < 0:
        return []
    return out


def lua_files():
    out = []
    for p in glob.glob(os.path.join(RES, '**', '*.lua'), recursive=True):
        r = rel(p, RES)
        if r.startswith('web/') or '/node_modules/' in r:
            continue
        out.append(p)
    return sorted(out, key=lambda p: rel(p, RES))


def ts_files():
    out = []
    for p in glob.glob(os.path.join(RES, 'web', 'src', '**', '*.ts*'), recursive=True):
        r = rel(p, RES)
        if r.endswith('.walk.ts') or '/mocks/' in r or r.endswith('.d.ts'):
            continue
        out.append(p)
    return sorted(out, key=lambda p: rel(p, RES))


def specs():
    """{spec name: its text, with the fixtures it loads}."""
    fixtures = {rel(p): read(p) for p in glob.glob(os.path.join(ROOT, 'tests', 'fixtures', '**', '*.lua'), recursive=True)}
    out = {}
    for p in sorted(glob.glob(os.path.join(ROOT, 'tests', '*_spec.lua'))):
        text = read(p)
        for fr, ft in fixtures.items():
            if fr in text or fr.replace('tests/', '', 1) in text:
                text += '\n' + ft
        out[os.path.basename(p)[:-4]] = text
    return out


def world_specs(sp):
    server, client = set(), set()
    for name, text in sp.items():
        if "workflows_full_spec.lua" in text or "manifestScripts('server_scripts')" in text:
            server.add(name)
        if "manifestScripts('client_scripts')" in text or "client_scripts" in text:
            client.add(name)
    return server, client


def loaders(sp, r):
    return sorted(n for n, t in sp.items() if ("'" + r + "'") in t or ('"' + r + '"') in t)


NAME_RX = re.compile(r"[.:]([A-Za-z_]\w*)\s*\(|['\"]([A-Za-z_]\w*)['\"]|\b([A-Za-z_]\w*)\s*=[^=]")
_names = {}


def names_it(text, short):
    """The spec calls .short( / :short(, names 'short' or sets short = (a stub or a table field)."""
    key = id(text)
    got = _names.get(key)
    if got is None:
        got = set()
        for m in NAME_RX.finditer(text):
            got.add(m.group(1) or m.group(2) or m.group(3))
        _names[key] = got
    return short in got


def _code_lines(text):
    """The lines of a spec with their Lua comments cut, minus the lines that only read what the server sent."""
    out = []
    for l in text.split('\n'):
        i = l.find('--')
        while i >= 0:
            if l[:i].count("'") % 2 == 0 and l[:i].count('"') % 2 == 0:
                l = l[:i]
                break
            i = l.find('--', i + 2)
        if not OUTGOING_RX.search(l):
            out.append(l)
    return out


OUTGOING_RX = re.compile(r'findEvents|EventsTo|Events\(|Sent\(|SentTo|lastEvent|Has\(|readFile|:find\(')
CALLISH_RX = re.compile(r'(?i)(fire|call|act|run|nui|trigger|emit|send|invoke|press|click|drive|step)\w*\s*\(')
CONCAT_RX = re.compile(r"""['"](?:crimson-police:)?client:['"]\s*\.\.""")
_lines = {}


def drives(text, kind, name):
    """The spec fires or calls the client entry point (not only names it)."""
    lines = _lines.get(id(text))
    if lines is None:
        lines = _code_lines(text)
        _lines[id(text)] = lines
    key = name.split(':', 1)[1] if name.startswith('client:') else name

    def quoted(x):
        return ("'%s'" % x, '"%s"' % x)

    if kind == 'event':
        full = quoted(name) + quoted('crimson-police:' + name)
        if any(any(p in l for p in full) for l in lines):
            return True
        if CONCAT_RX.search(text):
            return any(any(p in l for p in quoted(key)) and CALLISH_RX.search(l) for l in lines)
        return False
    calls = ('.%s(' % key, ':%s(' % key, "['%s'](" % key, '["%s"](' % key)
    first = re.compile(r"""[A-Za-z_]\w*\(\s*['"]%s['"]""" % re.escape(key))
    named = re.compile(r"""\bname\s*=\s*['"]%s['"]""" % re.escape(key))
    for l in lines:
        if any(c in l for c in calls) or first.search(l) or named.search(l):
            return True
        if any(p in l for p in quoted(key)) and CALLISH_RX.search(l):
            return True
    return False


def is_client(r):
    return '/client/' in r or r.endswith('/client.lua') or r.startswith('client/')


def build():
    sp = specs()
    wserver, wclient = world_specs(sp)
    rows, entries = [], []
    for p in lua_files():
        r = rel(p, RES)
        lines = read(p).split('\n')
        load = loaders(sp, r)
        client = is_client(r)
        world = (wclient if client else wserver)
        for i, line in enumerate(lines):
            for rx in LUA_FN:
                m = rx.match(line)
                if not m:
                    continue
                name = m.group(1)
                short = re.split(r'[.:]', name)[-1]
                local = line.lstrip().startswith('local ') or ('.' not in name and ':' not in name)
                what = first_sentence(comment_above(lines, i, True))
                cover = None
                if not local:
                    for n in load:
                        if names_it(sp[n], short):
                            cover = n
                            break
                if not cover and load:
                    cover = 'via ' + load[0]
                if not cover and world:
                    cover = 'world'
                rows.append((r, i + 1, name, what, cover or 'none'))
                break
            for kind, rx in ENTRY:
                for m in rx.finditer(line):
                    name = m.group(1)
                    if kind == 'event' and not client:
                        continue
                    if kind in ('command', 'export') and not client:
                        continue
                    if kind == 'event' and name.startswith('crimson-police:'):
                        if not name.startswith('crimson-police:client:'):
                            continue
                        name = name[len('crimson-police:'):]
                    cover = None
                    for n in load:
                        if drives(sp[n], kind, name):
                            cover = n
                            break
                    entries.append((kind, name, r, i + 1, cover))
    walks = {rel(p, RES): read(p) for p in glob.glob(os.path.join(RES, 'web', 'src', '**', '*.walk.ts'), recursive=True)}
    for p in ts_files():
        r = rel(p, RES)
        lines = read(p).split('\n')
        mod = os.path.splitext(os.path.basename(p))[0]
        for i, line in enumerate(lines):
            for rx in TS_FN:
                m = rx.match(line)
                if not m:
                    continue
                name = m.group(1)
                what = first_sentence(comment_above(lines, i, False))
                cover = 'none'
                for wr in sorted(walks):
                    wt = walks[wr]
                    if re.search(r'\b' + re.escape(name) + r'\b', wt) or re.search(r"from\s+['\"][^'\"]*/" + re.escape(mod) + r"['\"]", wt):
                        cover = 'walk ' + wr.replace('web/src/', '')
                        break
                rows.append((r, i + 1, name, what, cover))
                break
    return rows, entries


def render(rows, entries):
    out = []
    out.append('# Coverage list')
    out.append('')
    out.append('Generated by `python3 tools/check_coverage.py --write`; `lint-coverage` (tools/check_all.sh) fails when it is')
    out.append('not the list of today\'s code. What each column means: the head of tools/check_coverage.py and')
    out.append('docs/dev/TESTING.md "Coverage list". The **spec** column: a spec that loads the file and names the function,')
    out.append('`via <spec>` (loaded and run through its callers), `world` (only the whole-server or whole-client worlds), a')
    out.append('web walk, or `none`. "What it must do" is the first sentence of the comment above the function (`-` when it')
    out.append('has none: its file\'s head comment in docs/dev/FILE_NOTES.md says what the file does).')
    out.append('')
    counts = {}
    for r in rows:
        k = r[4].split(' ')[0]
        counts[k] = counts.get(k, 0) + 1
    out.append('## Totals')
    out.append('')
    out.append('| | functions |')
    out.append('|---|---:|')
    for k in ('spec', 'via', 'world', 'walk', 'none'):
        n = counts.get(k, 0) if k != 'spec' else sum(v for kk, v in counts.items() if kk not in ('via', 'world', 'walk', 'none'))
        out.append('| %s | %d |' % (k if k != 'spec' else 'named by a spec', n))
    out.append('| all | %d |' % len(rows))
    driven = sum(1 for e in entries if e[4])
    out.append('')
    out.append('Client entry points: %d, %d driven by a spec that loads their file, %d known gaps (tools/coverage_gaps.txt).'
               % (len(entries), driven, len(entries) - driven))
    out.append('')
    out.append('## Client entry points')
    out.append('')
    out.append('| kind | name | file:line | spec |')
    out.append('|---|---|---|---|')
    for kind, name, r, line, cover in sorted(entries, key=lambda e: (e[2], e[3], e[0], e[1])):
        out.append('| %s | `%s` | %s:%d | %s |' % (kind, name, r, line, cover or '**none**'))
    out.append('')
    out.append('## Functions')
    cur = None
    for r, line, name, what, cover in rows:
        if r != cur:
            out.append('')
            out.append('### ' + r)
            out.append('')
            out.append('| line | function | what it must do | spec |')
            out.append('|---:|---|---|---|')
            cur = r
        out.append('| %d | `%s` | %s | %s |' % (line, name, what or '-', cover))
    out.append('')
    return '\n'.join(out)


def gap_key(e):
    return '%s %s %s' % (e[0], e[1], e[2])


def main():
    args = sys.argv[1:]
    gaps = '--write-gaps' in args
    write = '--write' in args or gaps
    for a in args:
        if a not in ('--write', '--write-gaps'):
            print('unknown argument %s (python3 tools/check_coverage.py [--write | --write-gaps])' % a)
            return 2
    rows, entries = build()
    text = render(rows, entries)
    known = []
    if os.path.exists(GAPS):
        known = [l.strip() for l in read(GAPS).split('\n') if l.strip() and not l.startswith('#')]
    now = sorted({gap_key(e) for e in entries if not e[4]})
    new = [g for g in now if g not in known]
    stale = [g for g in known if g not in now]
    if write:
        with open(OUT, 'w', encoding='utf-8') as f:
            f.write(text)
        head = ['# tools/coverage_gaps.txt: client entry points no spec drives yet (tools/check_coverage.py).',
                '# `<kind> <name> <file>`. Shrink it: a spec that loads the file and names the entry point removes a line.']
        with open(GAPS, 'w', encoding='utf-8') as f:
            f.write('\n'.join(head + sorted((set(known) - set(stale)) | (set(new) if gaps else set()))) + '\n')
        print('coverage: wrote %s (%d functions, %d client entry points, %d gaps)' % (rel(OUT), len(rows), len(entries), len(now)))
        if new and not gaps:
            for g in new:
                print('  - no spec drives the client entry point %s (not added to the gaps: give it a spec)' % g)
            return 1
        return 0
    bad = 0
    old = read(OUT) if os.path.exists(OUT) else ''
    if old != text:
        print('stale: docs/dev/COVERAGE.md is not the list of today\'s code: run python3 tools/check_coverage.py --write')
        bad += 1
    for g in new:
        print('  - no spec drives the client entry point %s (a spec that loads its file and names it)' % g)
        bad += 1
    for g in stale:
        print('  - stale gap %s: a spec drives it now (python3 tools/check_coverage.py --write drops it)' % g)
        bad += 1
    status = 'PASS' if bad == 0 else 'FAIL'
    print('coverage %s: %d functions, %d client entry points, %d known gaps, %d new, %d stale' % (
        status, len(rows), len(entries), len(now) - len(new), len(new), len(stale)))
    return 0 if bad == 0 else 1


if __name__ == '__main__':
    sys.exit(main())

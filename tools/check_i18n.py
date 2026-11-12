#!/usr/bin/env python3
"""Translation scanner for Crimson-Police (dev tooling, not shipped). Run by tools/check_all.sh as lint-i18n.

  python3 tools/check_i18n.py                 # scan the resource, exit 1 on a hit that is not in the baseline
  python3 tools/check_i18n.py --write-baseline   # rewrite tools/i18n_baseline.txt from today's hits
  python3 tools/check_i18n.py --files A B ... # scan only these files, no baseline (tests/i18n_scan_spec.lua)

Rules (a translator cannot reorder or pluralise text that the code builds):
  J  English joined to a translated text: t(...) / tn(...) + '<words>' or '<words>' + t(...) in web/src, and
     CP.L(...) .. '<words>' or '<words>' .. CP.L(...) in the Lua. A literal without letters (' · ', ': ') is fine.
  P  A plural built in place: a count compared with 1 choosing between translated texts (n === 1 ? t(...) : ...,
     count > 1 and CP.L(...)). Use tn(key, n) / CP.Ln(key, n) with key_one / key_other in locales/parts.
  S  A locale value with a count before a plural word ('{n} entries') and no key_one / key_other forms.

Known hits are listed in tools/i18n_baseline.txt (`<rule> <file> <code>`, code compared without whitespace), so
only new ones fail; a listed hit that is gone is reported as stale and its line is deleted. docs/dev/TESTING.md.
"""
import glob, json, os, re, sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
RES = os.path.join(ROOT, 'Crimson-Police')
BASELINE = os.path.join(ROOT, 'tools', 'i18n_baseline.txt')

WORDS = r"[^'\"`\n]*[A-Za-z][^'\"`\n]*"
TS_RULES = [
    ('J', re.compile(r"\btn?\([^()\n]*(?:\([^()\n]*\)[^()\n]*)*\)\s*\+\s*(['\"`])" + WORDS + r"\1")),
    ('J', re.compile(r"(['\"`])" + WORDS + r"\1\s*\+\s*tn?\(")),
    ('P', re.compile(r"(?:[=!]==?|[<>]=?)\s*1\s*\?\s*tn?\(")),
    ('P', re.compile(r"\b1\s*(?:[=!]==?|[<>]=?)\s*[\w.?]+\s*\?\s*tn?\(")),
]
LUA_RULES = [
    ('J', re.compile(r"CP\.L[tn]?\([^()\n]*(?:\([^()\n]*\)[^()\n]*)*\)\s*\.\.\s*(['\"])" + WORDS + r"\1")),
    ('J', re.compile(r"(['\"])" + WORDS + r"\1\s*\.\.\s*CP\.L[tn]?\(")),
    ('P', re.compile(r"(?:==|~=|[<>]=?)\s*1\s+and\s+CP\.L[tn]?\(")),
]
COUNT_WORD = re.compile(r"\{(?:n|count)\} \w+s\b")
FORMS = ('_zero', '_one', '_two', '_few', '_many', '_other')


def rel(p):
    return os.path.relpath(p, ROOT).replace(os.sep, '/')


def code_lines(path):
    """(line number, code) with whole-line and trailing comments left out (a rough cut, enough for the rules)."""
    lua = path.endswith('.lua')
    out, block = [], False
    with open(path, encoding='utf-8') as f:
        for i, line in enumerate(f, 1):
            s = line.rstrip('\n')
            if lua:
                if block:
                    if ']]' in s: block = False
                    continue
                if re.match(r'\s*--\[=*\[', s):
                    block = ']]' not in s
                    continue
                s = re.sub(r"\s--[^'\"]*$", '', s)
                if s.strip().startswith('--'): continue
            else:
                if s.strip().startswith(('//', '*', '/*')): continue
                s = re.sub(r"\s//[^'\"`]*$", '', s)
            out.append((i, s))
    return out


def scan_code(path):
    rules = LUA_RULES if path.endswith('.lua') else TS_RULES
    hits = []
    for n, s in code_lines(path):
        for rule, rx in rules:
            if rx.search(s):
                hits.append((rule, rel(path), n, s.strip()))
                break
    return hits


def scan_locale(path):
    data = json.load(open(path, encoding='utf-8'))
    keys = set(data)
    hits = []
    for k, v in data.items():
        if not isinstance(v, str) or not COUNT_WORD.search(v) or k.endswith(FORMS): continue
        if any(k + f in keys for f in FORMS): continue
        hits.append(('S', rel(path), 0, k))
    return hits


def default_files():
    web = [p for p in glob.glob(os.path.join(RES, 'web', 'src', '**', '*.ts*'), recursive=True)
           if '/mocks/' not in p.replace(os.sep, '/') and not p.endswith('.walk.ts') and not p.endswith('.d.ts')]
    lua = [p for p in glob.glob(os.path.join(RES, '**', '*.lua'), recursive=True)
           if '/web/' not in p.replace(os.sep, '/') and '/node_modules/' not in p.replace(os.sep, '/')]
    parts = glob.glob(os.path.join(RES, 'locales', 'parts', '*.json'))
    return sorted(web) + sorted(lua) + sorted(parts)


def scan(files):
    hits = []
    for p in files:
        hits += scan_locale(p) if p.endswith('.json') else scan_code(p)
    return hits


def norm(code):
    return re.sub(r'\s+', '', code).replace('"', "'")


def entry(h):
    return f'{h[0]} {h[1]} {h[3]}'


def main(argv):
    if '--files' in argv:
        files = [os.path.abspath(f) for f in argv[argv.index('--files') + 1:]]
        hits = scan(files)
        for h in hits: print(f'{h[0]} {h[1]}:{h[2]}: {h[3]}')
        print(f'TOTAL hits: {len(hits)}')
        return 1 if hits else 0
    hits = scan(default_files())
    if '--write-baseline' in argv:
        head = []
        if os.path.exists(BASELINE):
            head = [l for l in open(BASELINE, encoding='utf-8').read().splitlines() if l.startswith('#')]
        with open(BASELINE, 'w', encoding='utf-8') as f:
            f.write('\n'.join(head) + ('\n' if head else ''))
            for e in sorted(set(entry(h) for h in hits)): f.write(e + '\n')
        print(f'wrote {len(hits)} hits to {rel(BASELINE)}')
        return 0
    known = {}
    if os.path.exists(BASELINE):
        for l in open(BASELINE, encoding='utf-8').read().splitlines():
            if not l.strip() or l.startswith('#'): continue
            rule, path, code = (l.split(' ', 2) + ['', ''])[:3]
            known[(rule, path, norm(code))] = l
    seen, new = set(), []
    for h in hits:
        k = (h[0], h[1], norm(h[3]))
        if k in known: seen.add(k)
        else: new.append(h)
    stale = [known[k] for k in known if k not in seen]
    for h in new:
        print(f'NEW {h[0]} {h[1]}:{h[2]}: {h[3]}')
    for l in stale:
        print(f'STALE baseline line (the hit is gone, delete it): {l}')
    print(f'{len(hits)} hits, {len(hits) - len(new)} in the baseline, {len(new)} new, {len(stale)} stale')
    print(f'TOTAL problems: {len(new) + len(stale)}')
    return 1 if new or stale else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

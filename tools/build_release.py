#!/usr/bin/env python3
"""Builds the release of Crimson-Police: dist/Crimson-Police/, the owner docs and a zip (dev tooling, not shipped).

  python3 tools/build_release.py              # the sale build: dist/ and dist/Crimson-Police-<version>.zip
  python3 tools/build_release.py --draft      # also builds while the CHANGELOG says "(not released yet)"
  python3 tools/build_release.py --out DIR    # another output folder (the gate's release step, tests/release_spec.lua)
  python3 tools/build_release.py --root DIR   # build another copy of the repository (tests/release_spec.lua)

What ships is an allow-list, never the folder minus deletes:
  - every file the fxmanifest names (shared/server/client scripts, files, ui_page, escrow_ignore; '@res/...' entries
    are other resources). '*' is one folder level, '**' any depth. An entry that matches nothing fails the build.
    From missions/custom/** only the .gitkeep files ship (never a city's missions or test_* folders).
  - EXTRA below: the files the resource reads with LoadResourceFile and the folders it writes into (.gitkeep), each
    glob must match something.
  - the owner docs: the resource README, CHANGELOG and LICENSE, the root README.md and docs/OWNER_GUIDE.md,
    docs/IN_GAME_CHECKLIST.md and docs/IN_GAME_TEST_PLAN.md, at the paths their links expect.

It fails, naming each problem, on: a missing file, the three versions (fxmanifest.lua, web/package.json,
CHANGELOG.md) not equal, the top CHANGELOG heading "(not released yet)" without --draft, a scratch file, a symlink,
a developer path (web/src, node_modules, locales/parts, tests, tools, docs/dev) or anything that looks like a
secret in the shipped files. Exit status: 0 built, 1 a problem, 2 usage error. docs/dev/TESTING.md "Release build".
"""
import argparse, json, os, re, shutil, stat, sys, zipfile

RES = 'Crimson-Police'

# The files read with LoadResourceFile (no manifest entry) and the folders the resource writes into: FXServer
# cannot make a folder on Linux (shared/utils.lua "FOLDERS"), so each ships with its .gitkeep.
EXTRA = [
    'sql/migrations/*.sql',
    'config/banned_words.txt',
    'config/examples/*.lua',
    'missions/builtin/*.lua',
    'items/*',
    'logos/*',
    'saves/README.md',
    'saves/**/.gitkeep',
    'missions/custom/**/.gitkeep',
]
# The owner docs beside the resource, from the root of the repository (their links expect these paths).
DOCS = ['README.md', 'docs/OWNER_GUIDE.md', 'docs/IN_GAME_CHECKLIST.md', 'docs/IN_GAME_TEST_PLAN.md']
RES_DOCS = ['README.md', 'CHANGELOG.md', 'LICENSE']

# Manifest directives that name files, and the ones this tool cannot read (it fails on them rather than guess).
LISTS = {
    'shared_scripts', 'server_scripts', 'client_scripts', 'files', 'escrow_ignore',
    'shared_script', 'server_script', 'client_script', 'file', 'ui_page',
}
UNSUPPORTED = {'data_file', 'loadscreen', 'map', 'this_is_a_map', 'replace_level_meta', 'before_level_meta'}

# Never in a release, whatever matched it.
DEV_PARTS = ['web/src/', 'node_modules/', 'locales/parts/', 'tests/', 'tools/', 'docs/dev/']
SCRATCH = re.compile(r'(\.bak|\.orig|\.rej|\.swp|~|\.log|\.map)$|^(\.cp-write-test|\.DS_Store|\.env.*)$')
# What a secret looks like. The mysql and password rules need a value, so the redaction patterns of shared/init.lua
# (Lua patterns, with %) and prose about passwords pass.
SECRETS = [
    ('Discord webhook', re.compile(r'discord(?:app)?\.com/api/webhooks/\d+/')),
    ('FiveM licence key', re.compile(r'cfxk_[A-Za-z0-9]{10,}')),
    ('database URL with a password', re.compile(r'mysql://[^\s\'"<:/@]+:[^\s\'"@<]+@')),
    ('password value', re.compile(r'(?i)\b(?:password|pwd)\s*=\s*[^;\s\'"<%]{3,}')),
    ('private key', re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY')),
    ('GitHub token', re.compile(r'ghp_[A-Za-z0-9]{20,}|github_pat_')),
    ('API key', re.compile(r'\bsk-[A-Za-z0-9]{20,}')),
]
OUT_OWN = re.compile(r'^(Crimson-Police|README\.md|docs|Crimson-Police-[\w.\-]+\.zip)$')


class Problems(list):
    def add(self, msg):
        self.append(msg)
        print('release: ' + msg)


def strip_comments(src):
    src = re.sub(r'--\[(=*)\[.*?\]\1\]', '', src, flags=re.S)
    return re.sub(r'--[^\n]*', '', src)


def manifest_entries(src, probs):
    """[(directive, path)] of every file entry, '@res/...' left out."""
    src = strip_comments(src)
    out = []
    for m in re.finditer(r'\b([a-z_]+)\s*(\{[^}]*\}|\'[^\']*\'|"[^"]*")', src):
        name, body = m.group(1), m.group(2)
        if name in UNSUPPORTED:
            probs.add('fxmanifest.lua: %s is not supported by this tool; add it to tools/build_release.py' % name)
            continue
        if name not in LISTS:
            continue
        for s in re.findall(r'\'([^\']*)\'|"([^"]*)"', body):
            path = s[0] or s[1]
            if not path.startswith('@'):
                out.append((name, path))
    return out


def glob_re(pattern):
    out = ''
    i = 0
    while i < len(pattern):
        if pattern.startswith('**/', i):
            out += '(?:.*/)?'
            i += 3
        elif pattern.startswith('**', i):
            out += '.*'
            i += 2
        elif pattern[i] == '*':
            out += '[^/]*'
            i += 1
        else:
            out += re.escape(pattern[i])
            i += 1
    return re.compile('^' + out + '$')


def walk_files(base):
    """Every file under base (relative, '/'), node_modules and .git not entered; a symlink is listed as a file."""
    found = []
    for d, dirs, files in os.walk(base):
        dirs[:] = sorted(x for x in dirs if x not in ('node_modules', '.git'))
        for name in sorted(files + [x for x in dirs if os.path.islink(os.path.join(d, x))]):
            found.append(os.path.relpath(os.path.join(d, name), base).replace(os.sep, '/'))
    return found


def versions(root, res, probs):
    got = {}
    try:
        with open(os.path.join(res, 'fxmanifest.lua'), encoding='utf-8') as f:
            m = re.search(r'^\s*version\s+[\'"]([^\'"]+)[\'"]', strip_comments(f.read()), re.M)
        got['Crimson-Police/fxmanifest.lua'] = m and m.group(1)
    except OSError as e:
        probs.add('cannot read fxmanifest.lua: %s' % e)
    try:
        with open(os.path.join(res, 'web', 'package.json'), encoding='utf-8') as f:
            got['Crimson-Police/web/package.json'] = json.load(f).get('version')
    except (OSError, ValueError) as e:
        probs.add('cannot read web/package.json: %s' % e)
    unreleased = False
    try:
        with open(os.path.join(res, 'CHANGELOG.md'), encoding='utf-8') as f:
            m = re.search(r'^## (\S+)(.*)$', f.read(), re.M)
        got['Crimson-Police/CHANGELOG.md'] = m and m.group(1)
        unreleased = bool(m) and '(not released yet)' in m.group(2)
    except OSError as e:
        probs.add('cannot read CHANGELOG.md: %s' % e)
    for k, v in got.items():
        if not v:
            probs.add('%s: no version found' % k)
    vals = set(v for v in got.values() if v)
    if len(vals) > 1:
        probs.add('the versions differ: ' + ', '.join('%s %s' % (k, v) for k, v in sorted(got.items())))
    ok = len(vals) == 1 and len(got) == 3 and all(got.values())
    return (vals.pop() if ok else None), unreleased


def is_text(data):
    return b'\0' not in data[:8192]


def scan(out, probs):
    """Scratch files, developer paths and secrets in what was copied (never the repository: its tests hold fakes)."""
    n = 0
    for d, dirs, files in os.walk(out):
        dirs.sort()
        for name in sorted(files):
            full = os.path.join(d, name)
            rel = os.path.relpath(full, out).replace(os.sep, '/')
            if rel.endswith('.zip') and '/' not in rel:
                continue
            n += 1
            if SCRATCH.search(name):
                probs.add('%s: scratch file, it must not ship (delete it)' % rel)
            inner = rel[len(RES) + 1:] if rel.startswith(RES + '/') else rel
            for part in DEV_PARTS:
                if inner.startswith(part) or ('/' + part) in inner:
                    probs.add('%s: developer file (%s), it must not ship' % (rel, part.rstrip('/')))
            with open(full, 'rb') as f:
                data = f.read()
            if not is_text(data):
                continue
            for ln, line in enumerate(data.decode('utf-8', 'replace').split('\n'), 1):
                for what, rx in SECRETS:
                    if rx.search(line):
                        probs.add('%s:%d: looks like a secret (%s), take it out' % (rel, ln, what))
    return n


def clear_out(out, probs):
    if not os.path.exists(out):
        os.makedirs(out)
        return True
    if not os.path.isdir(out):
        probs.add('--out %s is not a folder' % out)
        return False
    other = [x for x in os.listdir(out) if not OUT_OWN.match(x)]
    if other:
        probs.add('--out %s holds files this tool did not make (%s): pick an empty folder' % (out, ', '.join(other)))
        return False
    for x in os.listdir(out):
        p = os.path.join(out, x)
        if os.path.isdir(p) and not os.path.islink(p):
            shutil.rmtree(p)
        else:
            os.remove(p)
    return True


def copy(src, dst):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)


def write_zip(out, name):
    path = os.path.join(out, name)
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED) as z:
        for d, dirs, files in os.walk(out):
            dirs.sort()
            for f in sorted(files):
                full = os.path.join(d, f)
                rel = os.path.relpath(full, out).replace(os.sep, '/')
                if rel == name:
                    continue
                info = zipfile.ZipInfo(rel, (1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = (stat.S_IFREG | 0o644) << 16
                with open(full, 'rb') as fh:
                    z.writestr(info, fh.read())
    return path


def main(argv):
    ap = argparse.ArgumentParser(description='Build the Crimson-Police release.')
    ap.add_argument('--out', help='output folder (default: dist/ at the root of the repository)')
    ap.add_argument('--draft', action='store_true', help='build although the CHANGELOG says "(not released yet)"')
    ap.add_argument('--root', help='the repository to build (default: the one this tool is in)')
    a = ap.parse_args(argv)
    root = os.path.abspath(a.root or os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
    res = os.path.join(root, RES)
    out = os.path.abspath(a.out or os.path.join(root, 'dist'))
    probs = Problems()

    if os.path.commonpath([out, res]) in (out, res):
        print('release: --out must be a folder of its own, not inside %s or a folder that holds it' % RES)
        return 2

    # an old build goes first, so a failed build never leaves a zip behind that looks good
    if not clear_out(out, probs):
        print('release: FAIL, nothing built')
        return 1
    version, unreleased = versions(root, res, probs)
    if unreleased and not a.draft:
        probs.add('Crimson-Police/CHANGELOG.md: the top heading says "(not released yet)"; drop it for the sale '
                  'build, or pass --draft')

    try:
        with open(os.path.join(res, 'fxmanifest.lua'), encoding='utf-8') as f:
            entries = manifest_entries(f.read(), probs)
    except OSError:
        entries = []
    all_files = walk_files(res) if os.path.isdir(res) else []
    ship = set()
    for directive, pattern in entries:
        rx = glob_re(pattern)
        hit = [f for f in all_files if rx.match(f)]
        if pattern.startswith('missions/custom/'):
            hit = [f for f in hit if f.endswith('/.gitkeep')]
        if not hit:
            probs.add('fxmanifest.lua %s: \'%s\' matches no file' % (directive, pattern))
        ship.update(hit)
    for pattern in EXTRA:
        rx = glob_re(pattern)
        hit = [f for f in all_files if rx.match(f)]
        if not hit:
            probs.add('%s/%s: missing (the resource reads it or writes into its folder)' % (RES, pattern))
        ship.update(hit)
    for f in RES_DOCS:
        if f in all_files:
            ship.add(f)
        else:
            probs.add('%s/%s: missing' % (RES, f))
    ship.add('fxmanifest.lua')
    for f in sorted(ship):
        if os.path.islink(os.path.join(res, f)):
            probs.add('%s/%s is a symlink: a release holds real files only' % (RES, f))
    for f in DOCS:
        if not os.path.isfile(os.path.join(root, f)):
            probs.add('%s: missing' % f)

    if probs:
        print('release: FAIL, %d problems, nothing built' % len(probs))
        return 1

    for f in sorted(ship):
        copy(os.path.join(res, f), os.path.join(out, RES, f))
    for f in DOCS:
        copy(os.path.join(root, f), os.path.join(out, f))
    n = scan(out, probs)
    if probs:
        print('release: FAIL, %d problems in %s (nothing zipped)' % (len(probs), out))
        return 1
    name = 'Crimson-Police-%s%s.zip' % (version, '-draft' if a.draft else '')
    zpath = write_zip(out, name)
    print('release: PASS, version %s, %d files, %s (%d KB) in %s' % (
        version, n, name, os.path.getsize(zpath) // 1024, out))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

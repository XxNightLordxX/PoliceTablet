#!/usr/bin/env python3
"""Static cross-checks for Crimson-Police (dev tooling, not shipped).

  python3 tools/check_contracts.py            # all checks, exit 1 on problems
  python3 tools/check_contracts.py --merge    # also merge locales/parts/*.json into locales/en.json

Checks:
  1. Lua: every CP.<Module>.<fn>( call on a side (server/client) has a definition on that side.
  2. Events: crimson-police:client:* triggered by the server have a client handler, and
     crimson-police:server:* triggered by clients have a server handler (and vice versa).
  3. NUI: every request/action/clientAction name used in web/src exists in Lua.
  4. Locale: every CP.L('key') / t('key') / returned 'err.*' key exists in the merged locale;
     conflicting duplicate keys across parts; locales/en.json (the only file shared/locale.lua loads)
     exists and equals the merge of the parts (regenerate with --merge).
  5. NUI build: web/dist/build-stamp.json (written by `npm run build`) matches the current sources, so the
     shipped web/dist is the reviewed web/src (rebuild with `cd Crimson-Police/web && npm run build`).
"""
import json, os, re, sys, glob
from collections import defaultdict

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
RES = os.path.join(ROOT, 'Crimson-Police')
problems = defaultdict(list)

def read(p):
    with open(p, encoding='utf-8') as f:
        return f.read()

def strip_lua_comments(s):
    s = re.sub(r'--\[(=*)\[.*?\]\1\]', '', s, flags=re.S)
    return re.sub(r'--[^\n]*', '', s)

def lua_files(side):
    shared = glob.glob(os.path.join(RES, 'shared', '*.lua'))
    if side == 'server':
        own = glob.glob(os.path.join(RES, 'modules', '**', 'server.lua'), recursive=True) + \
              glob.glob(os.path.join(RES, 'blocks', '**', 'server.lua'), recursive=True)
    else:
        own = glob.glob(os.path.join(RES, 'modules', '**', 'client.lua'), recursive=True) + \
              glob.glob(os.path.join(RES, 'blocks', '**', 'client.lua'), recursive=True)
    return shared + own

rel = lambda p: os.path.relpath(p, ROOT)

# ── 1. CP function definitions vs calls ──────────────────────────────────────
DEF_PATTERNS = [
    re.compile(r'function\s+CP\.(\w+)\.(\w+)\s*\('),
    re.compile(r'function\s+CP\.(\w+)[:.](\w+)\s*\('),
    re.compile(r'CP\.(\w+)\.(\w+)\s*=\s*function'),
    re.compile(r'CP\.(\w+)\.(\w+)\s*=\s*(?!nil)[\w.]+\s*$', re.M),
]
TABLE_DEF = re.compile(r'CP\.(\w+)\s*=\s*(?:CP\.\1\s+or\s+)?\{')
LOCAL_ALIAS = re.compile(r'local\s+(\w+)\s*=\s*CP\.(\w+)\s*$', re.M)
CALL = re.compile(r'CP\.(\w+)\.(\w+)\s*\(')
GUARD = re.compile(r'CP\.(\w+)\s+and\s+CP\.\1\.(\w+)')

def defs_for(side):
    defs = defaultdict(set)
    for p in lua_files(side):
        s = strip_lua_comments(read(p))
        for pat in DEF_PATTERNS:
            for m in pat.finditer(s):
                defs[m.group(1)].add(m.group(2))
        # local M = CP.X ... function M.fn(
        for m in LOCAL_ALIAS.finditer(s):
            alias, mod = m.group(1), m.group(2)
            for m2 in re.finditer(r'function\s+' + re.escape(alias) + r'[.:](\w+)\s*\(', s):
                defs[mod].add(m2.group(1))
            for m2 in re.finditer(re.escape(alias) + r'\.(\w+)\s*=\s*function', s):
                defs[mod].add(m2.group(1))
            for m2 in re.finditer(r'(?m)^\s*' + re.escape(alias) + r'\.(\w+)\s*=\s*[A-Za-z_][\w.]*\s*$', s):
                defs[mod].add(m2.group(1))
        # CP.X = { fn = function ... }  (table constructor fields)
        for m in re.finditer(r'CP\.(\w+)\s*=\s*\{(.*?)\n\}', s, flags=re.S):
            for m2 in re.finditer(r'\n\s*(\w+)\s*=\s*function', m.group(2)):
                defs[m.group(1)].add(m2.group(1))
    return defs

for side in ('server', 'client'):
    defs = defs_for(side)
    for p in lua_files(side):
        s = strip_lua_comments(read(p))
        guarded = {(m.group(1), m.group(2)) for m in GUARD.finditer(s)}
        for m in CALL.finditer(s):
            mod, fn = m.group(1), m.group(2)
            if mod in ('U', 'Net', 'Blocks', 'Locale') and side:
                pass
            if fn not in defs.get(mod, set()):
                line = s[:m.start()].count('\n') + 1
                tag = 'guarded' if (mod, fn) in guarded else 'UNGUARDED'
                problems['lua-calls'].append(f'[{side}] {tag} CP.{mod}.{fn} called in {rel(p)} (~line {line}) but not defined on this side')

# ── 2. Events ────────────────────────────────────────────────────────────────
def collect(side, pattern):
    out = defaultdict(list)
    for p in lua_files(side):
        s = strip_lua_comments(read(p))
        for m in re.finditer(pattern, s):
            out[m.group(1)].append(rel(p))
    return out

srv_trigger_client = collect('server', r"TriggerClientEvent\(\s*['\"](crimson-police:client:[\w:]+)['\"]")
srv_trigger_client.update({k: v for k, v in collect('server', r"CP\.e\(\s*['\"](client:[\w:]+)['\"]\s*\)").items()})
cli_handlers = collect('client', r"RegisterNetEvent\(\s*['\"](crimson-police:client:[\w:]+)['\"]")
for k, v in collect('client', r"RegisterNetEvent\(\s*CP\.e\(\s*['\"](client:[\w:]+)['\"]").items(): cli_handlers['crimson-police:' + k] += v
for k, v in collect('client', r"RegisterNetEvent\(\s*(?:EVENT|EV|PREFIX|ev|evt)\s*\.\.\s*['\"](client:[\w:]+)['\"]").items(): cli_handlers['crimson-police:' + k] += v
for k, v in collect('client', r"['\"](crimson-police:client:[\w:]+)['\"]").items(): cli_handlers.setdefault(k, v)
for k, v in collect('client', r"['\"](client:[\w:]+)['\"]").items(): cli_handlers.setdefault('crimson-police:' + k, v)
cli_handlers2 = collect('client', r"AddEventHandler\(\s*['\"](crimson-police:client:[\w:]+)['\"]")
for k, v in cli_handlers2.items(): cli_handlers[k] += v
for ev, where in srv_trigger_client.items():
    name = ev if ev.startswith('crimson-police:') else 'crimson-police:' + ev
    if name not in cli_handlers:
        problems['events'].append(f'{name} sent by {sorted(set(where))} has no client handler')

cli_trigger_server = collect('client', r"TriggerServerEvent\(\s*['\"](crimson-police:server:[\w:]+)['\"]")
cli_net_action = collect('client', r"CP\.Net\.action\(\s*['\"](server:[\w:]+)['\"]")
srv_handlers = collect('server', r"RegisterNetEvent\(\s*['\"](crimson-police:server:[\w:]+)['\"]")
for k, v in collect('server', r"RegisterNetEvent\(\s*CP\.e\(\s*['\"](server:[\w:]+)['\"]").items(): srv_handlers['crimson-police:' + k] += v
srv_actions = collect('server', r"CP\.Net\.action\(\s*['\"](server:[\w:]+)['\"]")
for k, v in collect('server', r"CP\.Net\.action\(\s*\(\s*['\"]server:%s:([\w:]+)['\"]\s*\)\s*:\s*format").items():
    for scope in ('sup', 'admin'): srv_actions['server:%s:%s' % (scope, k)] += v
for k, v in collect('server', r"CP\.Net\.callback\(\s*\(\s*['\"]%s:([\w:]+)['\"]\s*\)\s*:\s*format").items():
    pass
srv_all = set(srv_handlers) | {'crimson-police:' + a for a in srv_actions}
for ev, where in list(cli_trigger_server.items()) + [('crimson-police:' + a, w) for a, w in cli_net_action.items()]:
    if ev not in srv_all:
        problems['events'].append(f'{ev} sent by client {sorted(set(where))} has no server handler')

# ── 3. NUI names ─────────────────────────────────────────────────────────────
srv_callbacks = collect('server', r"CP\.Net\.callback\(\s*['\"]([\w:]+)['\"]")
for k, v in collect('server', r"CP\.Net\.callback\(\s*\(\s*['\"]%s:([\w:]+)['\"]\s*\)\s*:\s*format").items():
    for scope in ('sup', 'admin'): srv_callbacks['%s:%s' % (scope, k)] += v
cli_actions = collect('client', r"registerClientAction\(\s*['\"](\w+)['\"]")
web = glob.glob(os.path.join(RES, 'web', 'src', '**', '*.ts*'), recursive=True)
web = [w for w in web if '/mocks/' not in w]
nui_req, nui_act, nui_cli = defaultdict(list), defaultdict(list), defaultdict(list)
for w in web:
    s = read(w)
    for m in re.finditer(r"\b(?:request|useRequest)(?:<[^>]*>)?\(\s*['\"]([\w:]+)['\"]", s): nui_req[m.group(1)].append(rel(w))
    for m in re.finditer(r"\b(?:action|run)(?:<[^>]*>)?\(\s*['\"](server:[\w:]+)['\"]", s): nui_act[m.group(1)].append(rel(w))
    for m in re.finditer(r"\bclientAction(?:<[^>]*>)?\(\s*['\"](\w+)['\"]", s): nui_cli[m.group(1)].append(rel(w))
for n, w in nui_req.items():
    if n not in srv_callbacks: problems['nui'].append(f"request '{n}' used in {sorted(set(w))} has no CP.Net.callback")
for n, w in nui_act.items():
    if n not in srv_actions: problems['nui'].append(f"action '{n}' used in {sorted(set(w))} has no CP.Net.action on the server")
for n, w in nui_cli.items():
    if n not in cli_actions: problems['nui'].append(f"clientAction '{n}' used in {sorted(set(w))} has no registerClientAction")

# ── 4. Locale ────────────────────────────────────────────────────────────────
parts = sorted(glob.glob(os.path.join(RES, 'locales', 'parts', '*.json')))
merged, origin = {}, {}
for p in parts:
    try:
        data = json.load(open(p, encoding='utf-8'))
    except Exception as e:
        problems['locale'].append(f'{rel(p)} is not valid JSON: {e}'); continue
    for k, v in data.items():
        if k in merged and merged[k] != v:
            problems['locale-conflicts'].append(f"'{k}': {origin[k]}={merged[k]!r} vs {os.path.basename(p)}={v!r}")
        else:
            merged[k] = v; origin[k] = os.path.basename(p)
used = defaultdict(set)
for side in ('server', 'client'):
    for p in lua_files(side):
        s = strip_lua_comments(read(p))
        for m in re.finditer(r"CP\.L\(\s*['\"]([\w.\-]+)['\"]", s): used[m.group(1)].add(rel(p))
        for m in re.finditer(r"['\"](err\.[\w.]+)['\"]", s): used[m.group(1)].add(rel(p))
for w in web:
    s = read(w)
    for m in re.finditer(r"\bt\(\s*['\"]([\w.\-]+)['\"]", s): used[m.group(1)].add(rel(w))
missing = sorted(k for k in used if k not in merged and not k.endswith('.') and not k.endswith('_'))
for k in missing:
    problems['locale-missing'].append(f"'{k}' used in {sorted(used[k])[:3]}")

if '--merge' in sys.argv:
    out = os.path.join(RES, 'locales', 'en.json')
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(dict(sorted(merged.items())), f, ensure_ascii=False, indent=2)
        f.write('\n')
    print(f'merged {len(parts)} parts, {len(merged)} keys -> {rel(out)}')

en_path = os.path.join(RES, 'locales', 'en.json')
if not os.path.exists(en_path):
    problems['locale-en'].append('locales/en.json is missing: run python3 tools/check_contracts.py --merge')
else:
    try:
        en = json.load(open(en_path, encoding='utf-8'))
    except Exception as e:
        en = None
        problems['locale-en'].append(f'locales/en.json is not valid JSON: {e}')
    if en is not None and en != merged:
        diff = sorted(set(en) ^ set(merged)) + sorted(k for k in set(en) & set(merged) if en[k] != merged[k])
        problems['locale-en'].append(f'locales/en.json is out of date with locales/parts ({len(diff)} keys differ, e.g. {diff[:3]}): '
                                     'run python3 tools/check_contracts.py --merge')

# ── 5. NUI build stamp (same algorithm as web/build-stamp.mjs) ───────────────
import hashlib
def nui_source_hash():
    web_dir = os.path.join(RES, 'web')
    files = []
    for dp, dns, fns in os.walk(os.path.join(web_dir, 'src')):
        for fn in fns:
            if fn != '.DS_Store': files.append(os.path.join(dp, fn))
    files += [os.path.join(web_dir, f) for f in ('index.html', 'package.json', 'tsconfig.json', 'vite.config.ts')]
    files.append(os.path.join(RES, 'locales', 'parts', 'ui.json'))
    items = sorted((os.path.relpath(p, RES).replace(os.sep, '/'), p) for p in files)
    h = hashlib.sha256()
    for r, p in items:
        h.update(r.encode('utf-8') + b'\0')
        with open(p, 'rb') as f: h.update(f.read())
        h.update(b'\0')
    return h.hexdigest()
stamp_path = os.path.join(RES, 'web', 'dist', 'build-stamp.json')
if not os.path.exists(os.path.join(RES, 'web', 'dist', 'index.html')) or not os.path.exists(stamp_path):
    problems['nui-build'].append('web/dist has no build-stamp.json: run cd Crimson-Police/web && npm run build')
else:
    try:
        stamp = json.load(open(stamp_path, encoding='utf-8')).get('sourceHash')
    except Exception:
        stamp = None
    if stamp != nui_source_hash():
        problems['nui-build'].append('web/dist is stale (web/src or the build config changed since the last build): '
                                     'run cd Crimson-Police/web && npm run build')

total = 0
for cat, items in problems.items():
    print(f'\n## {cat}: {len(items)}')
    for i in sorted(set(items)):
        print('  - ' + i)
    total += len(items)
print(f'\nTOTAL problems: {total}')
sys.exit(1 if total else 0)

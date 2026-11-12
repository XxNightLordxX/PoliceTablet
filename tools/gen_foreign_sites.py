#!/usr/bin/env python3
"""tools/gen_foreign_sites.py - writes tests/fixtures/foreign_sites.lua, the fixed world places of other scripts.

Reads the public Qbox and overextended resources (qbx_garages, qbx_policejob, ox_inventory ...) from a folder of
clones and lists every fixed world coordinate in their Lua files: vec2/vec3/vec4/vector2/3/4(...) and
{ x = , y = , z = } tables. Each place gets its script, file:line, a kind (garage, shop, bank, hospital, police,
job, robbery, property, spawn, prison, door, stash ...), what it is (the table keys around it, or its label) and
the radius the script gives it (radius, distance, useRadius, a box size), if any. Values that are clearly
relative (offsets, rotations, sizes, points within 60 m of the map origin) are skipped.

    python3 tools/gen_foreign_sites.py [folder]        (default: REFS, or a refs folder next to the repository)
    python3 tools/restyle.py tests/fixtures/foreign_sites.lua
    lua5.4 tests/run.lua tests/foreign_sites_spec.lua

tests/foreign_sites_spec.lua reads only the fixture, so the specs never need the other repositories. Add a script by
cloning it into the folder and adding its name and kind to SCRIPTS below, then run the three lines again.
"""
import math
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
REFS = sys.argv[1] if len(sys.argv) > 1 else os.environ.get('REFS', os.path.join(ROOT, '..', 'refs'))
OUT = os.path.join(ROOT, 'tests', 'fixtures', 'foreign_sites.lua')

# script -> the kind of its places (a file or key word below can name a better one)
SCRIPTS = {
    'ox_doorlock': 'door',
    'ox_inventory': 'shop',
    'qbx_ambulancejob': 'hospital',
    'qbx_bankrobbery': 'bank',
    'qbx_busjob': 'job',
    'qbx_cityhall': 'cityhall',
    'qbx_drugs': 'drugs',
    'qbx_garages': 'garage',
    'qbx_garbagejob': 'job',
    'qbx_houserobbery': 'property',
    'qbx_jewelery': 'robbery',
    'qbx_management': 'job',
    'qbx_policejob': 'police',
    'qbx_prison': 'prison',
    'qbx_properties': 'property',
    'qbx_scrapyard': 'job',
    'qbx_spawn': 'spawn',
    'qbx_storerobbery': 'robbery',
    'qbx_taxijob': 'job',
    'qbx_towjob': 'job',
    'qbx_truckerjob': 'job',
    'qbx_vehicleshop': 'shop',
}

# a word in the file name or the keys around a place -> its kind
KIND_WORDS = [
    ('camera', 'camera'), ('stash', 'stash'), ('evidence', 'stash'), ('crafting', 'shop'), ('garage', 'garage'), ('impound', 'garage'),
    ('parking', 'garage'), ('door', 'door'), ('spawn', 'spawn'),
]

NUM = r'\s*(-?\d+(?:\.\d+)?)\s*'
VEC = re.compile(r'\b(vec[234]|vector[234])\(' + NUM + ',' + NUM + r'(?:,' + NUM + r')?(?:,' + NUM + r')?\)')
XYZ = re.compile(r'\{\s*x\s*=' + NUM + r',\s*y\s*=' + NUM + r',\s*z\s*=' + NUM + r'(?:,\s*[wh]\s*=' + NUM + r')?\}')
# a field whose value is never a place
RELATIVE = re.compile(r'\b(size|rotation|rot|offset|r|dimensions|scale|min|max|velocity|dir|direction|camOffset)\s*=\s*$',
                      re.I)
RADIUS = re.compile(r'\b(radius|useRadius|dropUseRadius|interactionsRadius|distance)\s*=' + NUM)
SIZE = re.compile(r'\bsize\s*=\s*vec[23]\(' + NUM + ',' + NUM)
LABEL = re.compile(r'''\b(label|name)\s*=\s*['"]([^'"]{2,60})['"]''')
KEY_BEFORE = re.compile(r'''(?:\[\s*['"]([^'"]+)['"]\s*\]|\b([A-Za-z_]\w*))\s*=\s*$''')


def strip_comment(line, in_block):
    """The code part of a line (no -- comment, no --[[ ]] block) and whether a block comment is still open."""
    out = ''
    i = 0
    while i < len(line):
        if in_block:
            j = line.find(']]', i)
            if j < 0:
                return out, True
            i = j + 2
            in_block = False
            continue
        j = line.find('--', i)
        if j < 0:
            out += line[i:]
            break
        out += line[i:j]
        if line.startswith('--[[', j) or line.startswith('--[=[', j):
            in_block = True
            i = j + 4
            continue
        break
    return out, in_block


def kind_of(script, rel, keys):
    words = (rel + ' ' + ' '.join(keys)).lower()
    for w, k in KIND_WORDS:
        if w in words and not (script == 'qbx_garages' and k != 'garage'):
            return k
    return SCRIPTS[script]


def scan(script, path, rel):
    """The places of one file. A label, radius or size on any line of a table belongs to that table, so a place
    gets the label and radius of the table it sits in (or of a table round it, for the label)."""
    sites = []
    stack = [{'key': None, 'label': None, 'r': None}]     # the open tables, outermost first
    in_block = False
    with open(path, encoding='utf-8', errors='replace') as f:
        lines = f.readlines()
    for n, raw in enumerate(lines, 1):
        code, in_block = strip_comment(raw.rstrip('\n'), in_block)
        if not code.strip():
            continue
        # every event of the line in order: a table opened (with its key) or closed, a place, a label, a radius
        events = []
        for i, ch in enumerate(code):
            if ch == '{':
                km = KEY_BEFORE.search(code[:i])
                events.append((i, 0, 'open', km and (km.group(1) or km.group(2))))
            elif ch == '}':
                events.append((i, 0, 'close', None))
        for m in VEC.finditer(code):
            z = float(m.group(4)) if m.group(4) is not None else None
            events.append((m.start(), 1, 'place', (float(m.group(2)), float(m.group(3)), z)))
        for m in XYZ.finditer(code):
            events.append((m.start(), 1, 'place', (float(m.group(1)), float(m.group(2)), float(m.group(3)))))
        for m in LABEL.finditer(code):
            events.append((m.start(), 1, 'label', m.group(2)))
        for m in RADIUS.finditer(code):
            events.append((m.start(), 1, 'radius', float(m.group(2))))
        for m in SIZE.finditer(code):
            events.append((m.start(), 1, 'radius', max(abs(float(m.group(1))), abs(float(m.group(2)))) / 2))
        events.sort(key=lambda e: (e[0], e[1]))
        for pos, _, ev, val in events:
            top = stack[-1]
            if ev == 'open':
                stack.append({'key': val, 'label': None, 'r': None})
            elif ev == 'close':
                if len(stack) > 1:
                    stack.pop()
            elif ev == 'label':
                top['label'] = top['label'] or val
            elif ev == 'radius':
                top['r'] = max(top['r'] or 0, val)
            else:
                x, y, z = val
                before = code[:pos]
                if RELATIVE.search(before) or math.hypot(x, y) < 60:
                    continue
                keys = [f['key'] for f in stack if f['key']]
                field = re.search(r'([A-Za-z_]\w*)\s*=\s*$', before)
                what = keys[-3:] + ([field.group(1)] if field else [])
                sites.append({
                    'script': script, 'file': '%s:%d' % (rel, n), 'kind': kind_of(script, rel, keys),
                    'x': x, 'y': y, 'z': z, 'frames': list(stack), 'what': '.'.join(what) or 'point',
                })
    for s in sites:
        frames = s.pop('frames')
        s['r'] = frames[-1]['r']
        lab = next((f['label'] for f in reversed(frames) if f['label']), None)
        if lab:
            s['what'] = '%s (%s)' % (lab, s['what'])
    return sites


def lua_str(s):
    return "'" + s.replace('\\', '\\\\').replace("'", "\\'") + "'"


def num(v):
    if v is None:
        return 'false'
    t = ('%.2f' % v).rstrip('0').rstrip('.')
    return t if '.' in t else t + '.0'


def wrap(text, width):
    out, line = [], ''
    for word in text.split(' '):
        if line and len(line) + 1 + len(word) > width:
            out.append(line)
            line = word
        else:
            line = (line + ' ' + word).strip()
    return out + ([line] if line else [])


def main():
    if not os.path.isdir(REFS):
        sys.exit('no reference folder at %s (clone the scripts there or pass the folder)' % REFS)
    sites = []
    counts = {}
    for script in sorted(SCRIPTS):
        root = os.path.join(REFS, script)
        if not os.path.isdir(root):
            print('skip %s: not cloned' % script)
            continue
        for dirpath, dirnames, files in os.walk(root):
            dirnames[:] = sorted(d for d in dirnames if d not in ('.git', 'node_modules', 'web', 'locales'))
            for fn in sorted(files):
                if not fn.endswith('.lua') or fn == 'fxmanifest.lua':
                    continue
                path = os.path.join(dirpath, fn)
                rel = os.path.relpath(path, root).replace(os.sep, '/')
                got = scan(script, path, rel)
                sites.extend(got)
                counts[script] = counts.get(script, 0) + len(got)
    per = ', '.join('%s %d' % (s, counts[s]) for s in sorted(counts))
    lines = [
        '-- The fixed world places of other public scripts (Qbox and overextended), for tests/foreign_sites_spec.lua.',
        '',
        '-- Written by tools/gen_foreign_sites.py from clones of the scripts; do not edit by hand. One place per line:',
        "-- { script, 'file:line', kind, x, y, z, the script's own radius (or false), what it is }",
    ]
    lines += ['-- ' + part for part in wrap('Sites per script: ' + per + '.', 113)]
    lines += ['', 'return {']
    for s in sites:
        head = '    { %s, %s, %s, %s, %s, %s, %s, ' % (
            lua_str(s['script']), lua_str(s['file']), lua_str(s['kind']), num(s['x']), num(s['y']), num(s['z']),
            num(s['r']))
        room = 119 - len(head) - len(' },') - 2
        lines.append(head + lua_str(s['what'][:max(room, 8)]) + ' },')
    lines.append('}')
    with open(OUT, 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')
    print('%d sites from %d scripts -> %s' % (len(sites), len(counts), os.path.relpath(OUT)))
    for s in sorted(counts):
        print('  %-18s %d' % (s, counts[s]))


if __name__ == '__main__':
    main()

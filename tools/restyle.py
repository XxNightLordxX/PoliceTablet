#!/usr/bin/env python3
"""Restyle Crimson-Police to the owner's style (docs/STYLE.md). Dev tooling, not shipped.

  python3 tools/restyle.py                 format and restyle Crimson-Police/ and tests/ in place
  python3 tools/restyle.py --check         change nothing (a scratch copy is restyled); list the files a run
                                           would change, exit 1 if any (the style step of tools/check_all.sh)
  python3 tools/restyle.py --no-format     skip StyLua and Prettier (only the passes below)
  python3 tools/restyle.py PATH ...        only these files or folders
  RESTYLE_JOBS=n                           worker processes for the per-file layout (default: one per core)

Step 1 runs the formatters: StyLua (stylua.toml) on every Lua file and Prettier
(Crimson-Police/web/.prettierrc.json) on web/src and the build files next to it (WEB_TOP). Step 2 does what
a formatter cannot:

  Lua  - file-level local functions in PascalCase (scope-aware, only when provably safe, see rename_plan);
         closures inside a function keep their name
       - file headers cut to a short summary; the long text moves to docs/FILE_NOTES.md
       - section banners in the owner's 3-line '=' format, sub-banners as '-- ---- TITLE ----'
       - table.insert(t, v) -> t[#t + 1] = v, console print prefixes and colour codes
       - after the last StyLua run: ifs, loops and functions written on one line go back on one line, long
         calls, conditions and expressions are packed onto as few lines as fit (not one piece per line),
         a table that does not fit on one line gets one field per line, trailing comments keep the column
         they were written at or are aligned in groups
  web  - file headers, section banners, /** */ and /* */ comments as // comments, a blank line between
         css rules

Never touched: anything inside a string (except the listed print prefixes and test strings that quote a
renamed local function), public names (CP.*, events, NUI names, exports, locale keys, config keys, fields),
missions/ (the spec's Example layout, also written by the Mission Builder), web/dist, node_modules.
Running it twice changes nothing.
"""
import os
import re
from bisect import bisect_right
from concurrent.futures import ProcessPoolExecutor
import shutil
import subprocess
import sys
import tempfile
import textwrap

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
RES = os.path.join(ROOT, 'Crimson-Police')
WEB = os.path.join(RES, 'web')
NOTES = os.path.join(ROOT, 'docs', 'FILE_NOTES.md')

SKIP_DIRS = {'node_modules', 'dist', '.git', 'saves'}
# Mission files are data in the spec's Example file layout, the same layout the Mission Builder writes
# (modules/builder/server.lua); they keep it, so built-in and builder-written missions look alike.
SKIP_PREFIXES = (os.path.join(RES, 'missions') + os.sep,)
WEB_EXT = ('.ts', '.tsx', '.mjs')
# the build's own sources next to web/src: Prettier formats them too (index.html gets no other pass)
WEB_TOP = ('index.html', 'vite.config.ts', 'build-stamp.mjs')

RULE_WIDTH = 76         # '-- ' + 76 '=' = 79 columns, the owner's banner rule
SUB_WIDTH = 79          # a sub-banner is padded with '-' to 79 columns
ALIGN_MIN = 32          # an aligned group of trailing comments starts at column 33 or later, like the owner's
ALIGN_MAX = 140         # never align a trailing comment past this column
PRETTIER = 'prettier@3.9.9'   # pinned: another Prettier version may format differently
HEADER_LINES = 3        # a file header keeps at most this many lines

stats = {}


def bump(key, n=1):
    stats[key] = stats.get(key, 0) + n


# ============================================================================
#                               FILE HANDLING
# ============================================================================

def rel(p):
    return os.path.relpath(p, ROOT)


def read(p):
    with open(p, encoding='utf-8', newline='') as f:
        return f.read()


def write(p, s):
    with open(p, 'w', encoding='utf-8', newline='') as f:
        f.write(s)


def walk(paths, exts):
    out = []
    for base in paths:
        if os.path.isfile(base):
            if base.endswith(exts):
                out.append(os.path.abspath(base))
            continue
        for d, dirs, files in os.walk(base):
            dirs[:] = sorted(x for x in dirs if x not in SKIP_DIRS)
            for f in sorted(files):
                if f.endswith(exts):
                    out.append(os.path.abspath(os.path.join(d, f)))
    return [p for p in out if not p.startswith(SKIP_PREFIXES)]


# ============================================================================
#                               LUA TOKENIZER
# ============================================================================

KEYWORDS = {
    'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function', 'goto', 'if', 'in',
    'local', 'nil', 'not', 'or', 'repeat', 'return', 'then', 'true', 'until', 'while',
}
NUM_RE = re.compile(
    r'0[xX](?:[0-9a-fA-F]*\.?[0-9a-fA-F]*)(?:[pP][+-]?\d+)?|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?')
NAME_RE = re.compile(r'[A-Za-z_][A-Za-z0-9_]*')
LONG_OPEN_RE = re.compile(r'\[(=*)\[')
OPS = ('...', '..', '==', '~=', '<=', '>=', '//', '::', '<<', '>>')


class Tok:
    __slots__ = ('kind', 'text', 'start', 'end')

    def __init__(self, kind, text, start, end):
        self.kind, self.text, self.start, self.end = kind, text, start, end

    def __repr__(self):
        return f'{self.kind}:{self.text!r}'


def lua_tokens(src):
    """Every token except whitespace. kind: name, kw, str, num, op, comment (short), lcomment (long)."""
    toks = []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c in ' \t\r\n\f\v':
            i += 1
            continue
        if src.startswith('--', i):
            m = LONG_OPEN_RE.match(src, i + 2)
            if m:
                close = ']' + m.group(1) + ']'
                j = src.find(close, m.end())
                j = n if j < 0 else j + len(close)
                toks.append(Tok('lcomment', src[i:j], i, j))
            else:
                j = src.find('\n', i)
                j = n if j < 0 else j
                toks.append(Tok('comment', src[i:j], i, j))
            i = j
            continue
        if c == '[':
            m = LONG_OPEN_RE.match(src, i)
            if m:
                close = ']' + m.group(1) + ']'
                j = src.find(close, m.end())
                j = n if j < 0 else j + len(close)
                toks.append(Tok('str', src[i:j], i, j))
                i = j
                continue
        if c in '"\'':
            j = i + 1
            while j < n and src[j] != c:
                if src[j] == '\\':
                    j += 1
                elif src[j] == '\n':
                    break
                j += 1
            j = min(j + 1, n)
            toks.append(Tok('str', src[i:j], i, j))
            i = j
            continue
        if c.isdigit() or (c == '.' and i + 1 < n and src[i + 1].isdigit()):
            m = NUM_RE.match(src, i)
            toks.append(Tok('num', m.group(0), i, m.end()))
            i = m.end()
            continue
        m = NAME_RE.match(src, i)
        if m:
            w = m.group(0)
            toks.append(Tok('kw' if w in KEYWORDS else 'name', w, i, m.end()))
            i = m.end()
            continue
        for op in OPS:
            if src.startswith(op, i):
                toks.append(Tok('op', op, i, i + len(op)))
                i += len(op)
                break
        else:
            toks.append(Tok('op', c, i, i + 1))
            i += 1
    return toks


def code_toks(toks):
    return [t for t in toks if t.kind not in ('comment', 'lcomment')]


def apply_edits(src, edits):
    for start, end, text in sorted(edits, key=lambda e: e[0], reverse=True):
        src = src[:start] + text + src[end:]
    return src


def multiline_mask(src, toks):
    """Set of 0-based line numbers whose start lies inside a string or long comment (never edit those)."""
    masked = set()
    for t in toks:
        if t.kind in ('str', 'lcomment') and '\n' in t.text:
            first = src.count('\n', 0, t.start)
            last = first + t.text.count('\n')
            masked.update(range(first + 1, last + 1))
    return masked


# ============================================================================
#                          LUA: NAMES AND SCOPES
# ============================================================================

def name_roles(ct):
    """Role of every name token in the code token list: field, key, label or ref (bindings: resolve_scopes)."""
    roles = {}
    stack = []
    for i, t in enumerate(ct):
        if t.kind == 'op' and t.text in '({[':
            stack.append(t.text)
        elif t.kind == 'op' and t.text in ')}]':
            if stack:
                stack.pop()
        if t.kind != 'name':
            continue
        prev = ct[i - 1] if i > 0 else None
        nxt = ct[i + 1] if i + 1 < len(ct) else None
        if prev is not None and prev.kind == 'op' and prev.text in ('.', ':'):
            roles[i] = 'field'
        elif prev is not None and prev.kind == 'op' and prev.text == '::':
            roles[i] = 'label'
        elif prev is not None and prev.kind == 'kw' and prev.text == 'goto':
            roles[i] = 'label'
        elif (stack and stack[-1] == '{' and nxt is not None and nxt.kind == 'op' and nxt.text == '='
              and prev is not None and prev.kind == 'op' and prev.text in ('{', ',', ';')):
            roles[i] = 'key'
        else:
            roles[i] = 'ref'
    return roles


BINOPS = {'and', 'or', '+', '-', '*', '/', '//', '%', '^', '..', '==', '~=', '<', '>', '<=', '>=', '&', '|', '~',
          '<<', '>>'}


def ends_operand(t):
    return (t.kind in ('name', 'num', 'str') or t.text in (')', ']', '}', '...')
            or (t.kind == 'kw' and t.text in ('nil', 'true', 'false')))


def continues(t):
    """True when t can continue an expression that has just ended an operand."""
    return t.text in BINOPS or t.text in (',', '.', ':', '(', '[', '{') or t.kind == 'str'


def expr_end(ct, j):
    """Index of the first code token after the expression list that starts at ct[j]."""
    n = len(ct)
    br = bl = 0
    prev_end = False
    k = j
    while k < n:
        t = ct[k]
        if br == 0 and bl == 0 and prev_end and not continues(t):
            return k
        x = t.text
        if t.kind == 'op' and x in ('(', '[', '{'):
            br += 1
            prev_end = False
        elif t.kind == 'op' and x in (')', ']', '}'):
            br -= 1
            if br < 0:
                return k
            prev_end = True
        elif t.kind == 'kw' and x in ('function', 'if', 'do', 'repeat'):
            bl += 1
            prev_end = False
        elif t.kind == 'kw' and x in ('end', 'until'):
            if bl == 0:
                return k
            bl -= 1
            prev_end = x == 'end'
        elif t.kind == 'kw' and x in ('then', 'else', 'elseif') and bl == 0:
            return k
        else:
            prev_end = ends_operand(t)
        k += 1
    return n


class Binding:
    __slots__ = ('name', 'tok', 'kind', 'fdepth', 'init', 'refs', 'fassigned')

    def __init__(self, name, tok, kind, fdepth, init=False):
        self.name, self.tok, self.kind, self.fdepth, self.init = name, tok, kind, fdepth, init
        self.refs = []
        self.fassigned = False


def resolve_scopes(ct, roles):
    """Lua 5.4 scoping over the code tokens: every binding (local, local function, parameter, loop variable)
    and, for every name reference, the binding it means (a reference with no binding is a global).

    A `local` name becomes visible after its statement (the initialiser still sees the outer name), a
    `local function` inside its own body, a parameter inside the function, a loop variable inside the loop,
    and a local declared in a repeat block also in its `until` condition."""
    bindings = []
    bind_of = {}
    scopes = [{}]
    frames = []
    pending = []                 # [activate_at, scope, name, binding index]
    pops = []                    # token index at which a repeat scope ends (after its until condition)
    fdepth = 0
    skip = set()
    n = len(ct)

    def new_binding(idx, kind, init=False):
        bindings.append(Binding(ct[idx].text, idx, kind, fdepth, init))
        bind_of[idx] = len(bindings) - 1
        skip.add(idx)
        return len(bindings) - 1

    def lookup(name):
        for s in reversed(scopes):
            if name in s:
                return s[name]
        return None

    i = 0
    while i < n:
        if pops and pops[-1] <= i:
            pops.pop()
            scopes.pop()
        if pending:
            rest = []
            for p in pending:
                if p[0] <= i:
                    p[1][p[2]] = p[3]
                else:
                    rest.append(p)
            pending = rest
        t = ct[i]
        x = t.text
        if t.kind == 'kw':
            if x == 'local':
                if i + 2 < n and ct[i + 1].kind == 'kw' and ct[i + 1].text == 'function' and ct[i + 2].kind == 'name':
                    bid = new_binding(i + 2, 'localfunc')
                    scopes[-1][ct[i + 2].text] = bid
                    i += 1
                    continue
                j = i + 1
                names = []
                while j < n and ct[j].kind == 'name':
                    names.append(j)
                    j += 1
                    if j + 2 < n and ct[j].text == '<' and ct[j + 2].text == '>':
                        j += 3
                    if j < n and ct[j].text == ',':
                        j += 1
                    else:
                        break
                init = j < n and ct[j].text == '='
                at = expr_end(ct, j + 1) if init else j
                for ni in names:
                    pending.append([at, scopes[-1], ct[ni].text, new_binding(ni, 'local', init)])
                i = j
                continue
            if x == 'function':
                prev = ct[i - 1] if i > 0 else None
                j = i + 1
                if prev is not None and prev.kind == 'kw' and prev.text == 'local':
                    j = i + 2
                elif j < n and ct[j].kind == 'name':
                    bid = lookup(ct[j].text)
                    plain = not (j + 1 < n and ct[j + 1].text in ('.', ':'))
                    if bid is not None:
                        bind_of[j] = bid
                        bindings[bid].refs.append(j)
                        if plain:
                            bindings[bid].fassigned = True
                    skip.add(j)
                    j += 1
                    while j + 1 < n and ct[j].text in ('.', ':') and ct[j + 1].kind == 'name':
                        j += 2
                fdepth += 1
                fscope = {}
                if j < n and ct[j].text == '(':
                    j += 1
                    while j < n and ct[j].text != ')':
                        if ct[j].kind == 'name':
                            fscope[ct[j].text] = new_binding(j, 'param')
                        j += 1
                scopes.append(fscope)
                frames.append(['function'])
                i = j + 1
                continue
            if x == 'for':
                j = i + 1
                names = []
                while j < n and not (ct[j].kind == 'kw' and ct[j].text == 'in') and ct[j].text != '=':
                    if ct[j].kind == 'name':
                        names.append(j)
                        skip.add(j)
                    j += 1
                frames.append(['for-h', names])
                i = j
                continue
            if x == 'while':
                frames.append(['while-h', []])
            elif x == 'do':
                top = frames[-1] if frames else None
                if top is not None and top[0] in ('for-h', 'while-h'):
                    loop = {}
                    for ni in top[1]:
                        loop[ct[ni].text] = new_binding(ni, 'loop')
                    top[0] = 'loop'
                    scopes.append(loop)
                else:
                    frames.append(['do'])
                    scopes.append({})
            elif x == 'if':
                frames.append(['if-h'])
            elif x == 'then':
                if frames and frames[-1][0] in ('if-h', 'elseif-h'):
                    frames[-1][0] = 'then'
                    scopes.append({})
            elif x == 'elseif':
                if frames and frames[-1][0] == 'then':
                    scopes.pop()
                    frames[-1][0] = 'elseif-h'
            elif x == 'else':
                if frames and frames[-1][0] == 'then':
                    scopes.pop()
                    scopes.append({})
            elif x == 'repeat':
                frames.append(['repeat'])
                scopes.append({})
            elif x == 'until':
                if frames and frames[-1][0] == 'repeat':
                    frames.pop()
                    pops.append(expr_end(ct, i + 1))
            elif x == 'end':
                top = frames.pop() if frames else ['?']
                if top[0] == 'function':
                    fdepth -= 1
                    scopes.pop()
                elif top[0] in ('then', 'loop', 'do'):
                    scopes.pop()
            i += 1
            continue
        if t.kind == 'name' and i not in skip and roles.get(i) == 'ref':
            bid = lookup(x)
            if bid is not None:
                bind_of[i] = bid
                bindings[bid].refs.append(i)
                if (i + 2 < n and ct[i + 1].text == '=' and ct[i + 2].kind == 'kw' and ct[i + 2].text == 'function'):
                    bindings[bid].fassigned = True
        i += 1
    return bindings, bind_of


class LuaFile:
    """The tokens of one Lua file with its name roles, bindings and resolved references."""

    def __init__(self, src):
        self.src = src
        self.toks = lua_tokens(src)
        self.ct = code_toks(self.toks)
        self.roles = name_roles(self.ct)
        self.bindings, self.bind_of = resolve_scopes(self.ct, self.roles)
        self.names = {t.text for t in self.ct if t.kind == 'name'}

    def free_names(self):
        return {self.ct[i].text for i, r in self.roles.items() if r == 'ref' and i not in self.bind_of}


def pascal(name):
    return name[0].upper() + name[1:]


def rename_plan(lf, globals_used):
    """File-level local functions to rename: {binding index: new name} plus {old name: reason} for the rest.

    A local function becomes PascalCase when
      - it is declared at file level (`local function x` or a forward `local x` later assigned a function);
        a closure inside another function keeps its name, as in the owner's code,
      - the new name is not used anywhere in the file (no collision, no shadowing) and is not a global used
        by any Lua file (natives, CP, Config, test stubs ...).
    Only the references that resolve to that binding are renamed: a parameter, loop variable or other local
    with the same name keeps its own name, and a use that means a global stays a global."""
    plan, skipped = {}, {}
    for bid, b in enumerate(lf.bindings):
        if b.fdepth != 0:
            continue
        if not (b.kind == 'localfunc' or (b.kind == 'local' and not b.init and b.fassigned)):
            continue
        old = b.name
        if old[0] == '_' or old[0].isupper():
            continue
        new = pascal(old)
        if new in lf.names or new in globals_used or new in KEYWORDS:
            skipped[old] = 'collides with ' + new
            continue
        plan[bid] = new
    return plan, skipped


def rename_edits(lf, plan):
    edits = []
    for bid, new in plan.items():
        b = lf.bindings[bid]
        for i in [b.tok] + b.refs:
            t = lf.ct[i]
            edits.append((t.start, t.end, new))
    return edits


# ---- quoted source in the tests -----------------------------------------------------------------

QUOTE_NAME_RE = re.compile(r'(?<![\w.:])([A-Za-z_]\w*)(?=%?\()')


def literal_body(text):
    """The raw text between the delimiters of a Lua string literal token, and where it starts in the token."""
    m = LONG_OPEN_RE.match(text)
    if m:
        return text[m.end():len(text) - len(m.group(1)) - 2], m.end()
    return text[1:-1], 1


def unescape(body):
    return re.sub(r'\\(.)', lambda m: {'n': '\n', 't': '\t'}.get(m.group(1), m.group(1)), body)


def escape(content, quote):
    return (content.replace('\\', '\\\\').replace(quote, '\\' + quote).replace('\n', '\\n')
            .replace('\t', '\\t'))


def comma_kept(seq):
    """Indices of seq without the commas that stand right before a closing bracket (the tests ignore those)."""
    return [k for k in range(len(seq)) if not (seq[k] == ',' and k + 1 < len(seq) and seq[k + 1] in (')', ']', '}'))]


def quoted_renames(test_files, modules, plans, writable):
    """Test specs read module sources and quote code in strings (`push(m, 'board'`, `local function x(`).

    A quote that matches the tokens of a module source must keep matching after the renames: a quoted name
    whose every matched occurrence is renamed is renamed in the quote too; when only some are, or when the
    quoting spec is not part of this run (not in writable), the rename is dropped. A string that matches no
    module source (a message, a TS snippet) is left alone.
    Returns ({test path: [(start, end, new literal)]}, number of renames dropped)."""
    index = {}
    for p, lf in modules.items():
        texts = [t.text for t in lf.ct]
        keep = comma_kept(texts)
        seq = [texts[k] for k in keep]
        pos = {}
        for k2, w in enumerate(seq):
            pos.setdefault(w, []).append(k2)
        index[p] = (seq, keep, pos)
    quotes = []
    for tp in test_files:
        for t in lua_tokens(read(tp)):
            if t.kind != 'str':
                continue
            body, base = literal_body(t.text)
            if not QUOTE_NAME_RE.search(body):
                continue
            quote = None if t.text.startswith('[') else t.text[0]
            content = body if quote is None else unescape(body)
            rewritable = quote is None or escape(content, quote) == body
            pattern = re.sub(r'%([^\w\s])', r'\1', content)       # a Lua pattern's escapes
            qt = code_toks(lua_tokens(pattern))
            raw = [x for x in code_toks(lua_tokens(content)) if x.kind == 'name']
            names_q = [k for k, x in enumerate(qt) if x.kind == 'name']
            rewritable = rewritable and len(raw) == len(names_q)
            qkeep = comma_kept([x.text for x in qt])
            q = [qt[k].text for k in qkeep]
            if len(q) < 2:
                continue
            occ = {}
            for p, (seq, keep, pos) in index.items():
                anchor = min(q, key=lambda w: len(pos.get(w, ())))
                if anchor not in pos:
                    continue
                a = q.index(anchor)
                for k2 in pos[anchor]:
                    s0 = k2 - a
                    if s0 < 0 or seq[s0:s0 + len(q)] != q:
                        continue
                    for off in range(len(q)):
                        if qt[qkeep[off]].kind == 'name':
                            occ.setdefault(off, []).append((p, keep[s0 + off]))
            if occ:
                quotes.append((tp, t, base, body, content, quote, raw, names_q, qkeep, occ, rewritable))
    renamed_at = {}
    for p, plan in plans.items():
        if p in modules:
            for bid in plan:
                b = modules[p].bindings[bid]
                for i in [b.tok] + b.refs:
                    renamed_at[(p, i)] = bid
    dropped = 0
    for _ in range(20):
        edits, drop = {}, []
        for tp, t, base, body, content, quote, raw, names_q, qkeep, occ, rewritable in quotes:
            repl = []
            for off, keys in occ.items():
                outs = {k in renamed_at for k in keys}
                if outs == {False}:
                    continue
                news = {plans[k[0]][renamed_at[k]] for k in keys if k in renamed_at}
                if outs == {True} and len(news) == 1 and rewritable and tp in writable:
                    rt = raw[names_q.index(qkeep[off])]
                    repl.append((rt.start, rt.end, news.pop()))
                else:
                    drop.extend(k for k in keys if k in renamed_at)
            if repl:
                new = apply_edits(content, repl)
                new = new if quote is None else escape(new, quote)
                edits.setdefault(tp, []).append((t.start, t.end, t.text[:base] + new + t.text[base + len(body):]))
        if not drop:
            return edits, dropped
        for p, ci in drop:
            bid = renamed_at.get((p, ci))
            if bid is not None and bid in plans[p]:
                del plans[p][bid]
                dropped += 1
                b = modules[p].bindings[bid]
                for i in [b.tok] + b.refs:
                    renamed_at.pop((p, i), None)
    sys.exit('restyle: quoted renames did not settle')


# ============================================================================
#                       LUA: STATEMENTS AND STRINGS
# ============================================================================

NOT_BEFORE_STATEMENT = {'=', '(', ',', '{', '[', 'return', 'in', 'not', 'and', 'or', '..', '+', '-', '*',
                        '/', '//', '%', '^', '#', '==', '~=', '<', '>', '<=', '>=', 'until', 'if',
                        'elseif', 'while', 'local', '&', '|', '~', '<<', '>>'}


def simple_target(ct, a, b):
    """True when tokens ct[a:b] form a side-effect-free lvalue: Name { .Name | [Name|str|num] }."""
    if a >= b or ct[a].kind != 'name':
        return False
    j = a + 1
    while j < b:
        t = ct[j]
        if t.text == '.' and j + 1 < b and ct[j + 1].kind == 'name':
            j += 2
        elif t.text == '[' and j + 2 < b and ct[j + 1].kind in ('name', 'str', 'num') and ct[j + 2].text == ']':
            if ct[j + 1].kind == 'str' and '\n' in ct[j + 1].text:
                return False
            j += 3
        else:
            return False
    return True


def table_insert_pass(src):
    toks = lua_tokens(src)
    ct = code_toks(toks)
    edits = []
    for i in range(len(ct) - 5):
        if not (ct[i].text == 'table' and ct[i + 1].text == '.' and ct[i + 2].text == 'insert'
                and ct[i + 3].text == '('):
            continue
        prev = ct[i - 1] if i > 0 else None
        if prev is not None and (prev.text in NOT_BEFORE_STATEMENT or prev.text in ('.', ':')):
            continue
        # split the arguments at top-level commas
        depth, j, commas = 0, i + 4, []
        while j < len(ct):
            t = ct[j]
            if t.text in ('(', '{', '['):
                depth += 1
            elif t.text in (')', '}', ']'):
                if depth == 0:
                    break
                depth -= 1
            elif t.text == ',' and depth == 0:
                commas.append(j)
            j += 1
        if j >= len(ct) or len(commas) != 1:
            continue
        close = j
        nxt = ct[close + 1] if close + 1 < len(ct) else None
        if nxt is not None and nxt.text in ('.', ':', '[', '(') or (nxt is not None and nxt.kind == 'str'):
            continue
        if not simple_target(ct, i + 4, commas[0]):
            continue
        if '\n' in src[ct[i].start:ct[commas[0]].end]:
            continue            # the target spans lines: left for a person (a multi-line value is fine)
        target = src[ct[i + 4].start:ct[commas[0] - 1].end]
        value = src[ct[commas[0] + 1].start:ct[close - 1].end]
        edits.append((ct[i].start, ct[close].end, f'{target}[#{target} + 1] = {value}'))
    bump('lua: table.insert appends rewritten', len(edits))
    return apply_edits(src, edits)


LOG_COLOUR_RE = re.compile(r"^(['\"])\^([0-9])\[crimson-police(:%s)?\] %s\^7\1$")


def print_prefix_pass(src):
    """Console lines in the owner's shape: '[crimson-police] ...', colour on the tag only, reset with ^7."""
    toks = lua_tokens(src)
    edits = []
    for t in toks:
        if t.kind != 'str':
            continue
        new = t.text
        m = LOG_COLOUR_RE.match(new)
        if m:
            q, colour, sub = m.group(1), m.group(2), m.group(3) or ''
            new = f'{q}^{colour}[crimson-police{sub}]^7 %s{q}'
        new = new.replace('[Crimson-Police] ', '[crimson-police] ')
        if new in ("'^0'", '"^0"'):
            new = new.replace('^0', '^7')
        if new != t.text:
            edits.append((t.start, t.end, new))
    bump('lua: console prefix strings', len(edits))
    return apply_edits(src, edits)


# ============================================================================
#                        LUA: LAYOUT AFTER STYLUA
# ============================================================================
# StyLua spreads every if, loop and function over several lines, lays out a long call one argument per
# line, a long condition as `if` / conditions / `then` and a long assignment as `x =` / value. The owner
# keeps a short if, loop or function on one line when it was written that way, packs arguments and
# conditions onto as few lines as fit (the rest at +4, the closing bracket at the end of the last line,
# a function argument hugged as `f(a, function()` / body / `end, b)`), and writes a table that does not
# fit on one line one field per line. These passes run after the last StyLua run. They only move line
# breaks (and add the trailing comma of an exploded table); same_code() checks that.

WIDTH = 120
OPENERS = ('function', 'if', 'do', 'repeat')
CLOSERS = ('end', 'until')


SHAPE_KW = {'for': 'loop', 'while': 'loop', 'function': 'function', 'if': 'if'}


def one_line_shapes(src):
    """The ifs, loops and functions written on one line: {kind: {ordinal: True if it separates its
    statements with `;`}} for the kinds 'if', 'loop' and 'function'."""
    ct = code_toks(lua_tokens(src))
    line_of = line_index(src)
    out = {k: {} for k in SHAPE_KW.values()}
    counts = {k: 0 for k in SHAPE_KW.values()}
    for i, t in enumerate(ct):
        if t.kind != 'kw' or t.text not in SHAPE_KW:
            continue
        kind = SHAPE_KW[t.text]
        k = counts[kind]
        counts[kind] += 1
        close = block_close(ct, i)
        if close is not None and line_of(t.start) == line_of(ct[close].start):
            out[kind][k] = any(ct[x].text == ';' for x in range(i, close))
    return out


def line_index(src):
    starts = [0]
    for m in re.finditer('\n', src):
        starts.append(m.end())
    return lambda off: bisect_right(starts, off) - 1


def first_do(ct, i):
    """Index of the `do` of the for/while header at ct[i] (function literals in the header are skipped)."""
    d = 0
    for j in range(i + 1, len(ct)):
        x = ct[j]
        if x.kind != 'kw':
            continue
        if x.text == 'do' and d == 0:
            return j
        if x.text in OPENERS:
            d += 1
        elif x.text in CLOSERS:
            d -= 1
    return None


def block_close(ct, i):
    """Index of the `end` that closes the if/for/while/function block whose keyword is ct[i]."""
    if ct[i].text in ('function', 'if'):
        start = i + 1
    else:
        j = first_do(ct, i)
        if j is None:
            return None
        start = j + 1
    d = 1
    for k in range(start, len(ct)):
        x = ct[k]
        if x.kind != 'kw':
            continue
        if x.text in OPENERS:
            d += 1
        elif x.text in CLOSERS:
            d -= 1
            if d == 0:
                return k
    return None


class Lines:
    """Per-line facts of a Lua source: code tokens, trailing or full-line comments, lines inside a
    multi-line string or comment, and bracket / block balance."""

    def __init__(self, src):
        self.src = src
        self.lines = src.split('\n')
        toks = lua_tokens(src)
        self.masked = multiline_mask(src, toks)
        line_of = line_index(src)
        self.line_of = line_of
        n = len(self.lines)
        self.code = [[] for _ in range(n)]
        self.comment = [False] * n
        self.multi = [False] * n            # a token that starts on this line continues on the next
        for t in toks:
            ln = line_of(t.start)
            if t.kind in ('comment', 'lcomment'):
                self.comment[ln] = True
                if '\n' in t.text:
                    self.multi[ln] = True
            else:
                self.code[ln].append(t)
                if '\n' in t.text:
                    self.multi[ln] = True

    def plain(self, i):
        """A line whose tokens can be moved: no comment, not inside or starting a multi-line token."""
        return 0 <= i < len(self.lines) and i not in self.masked and not self.comment[i] and not self.multi[i]

    def balanced(self, i):
        br = bl = 0
        for t in self.code[i]:
            if t.kind == 'op' and t.text in '([{':
                br += 1
            elif t.kind == 'op' and t.text in ')]}':
                br -= 1
                if br < 0:
                    return False
            elif t.kind == 'kw' and t.text in OPENERS:
                bl += 1
            elif t.kind == 'kw' and t.text in CLOSERS:
                bl -= 1
                if bl < 0:
                    return False
        return br == 0 and bl == 0


def indent_of(line):
    return len(line) - len(line.lstrip(' '))


def pack(head, items, ind, fresh=True, width=WIDTH):
    """items are the pieces that follow head, each already carrying its separator. Greedy: fill the head
    line, continue at ind + 4. fresh: head ends with an opening bracket, so the first item needs no space.

    A multi-line item is (kind, first line, middle lines, last line). 'str' is a [[ ]] string: its content
    is kept as it is. 'block' is a table, a function or a call over several lines: when it starts on the
    statement's own line its other lines move 4 columns left, as the owner writes
    `f(a, function()` / body / `end, b)`. The next items continue after its last line."""
    out = []
    cur = head
    level = 0                         # 0: the current line is at the statement's indent, 1: a continuation line
    pad = ' ' * (ind + 4)
    for it in items:
        sep = '' if fresh else ' '
        fresh = False
        if isinstance(it, tuple):
            kind, first, mid, last = it
            if len(cur + sep + first) <= width:
                cur = cur + sep + first
            else:
                out.append(cur)
                cur = pad + first
                level = 1
            shift = 4 if kind == 'block' and level == 0 else 0
            out.append(cur)
            out.extend(m[shift:] for m in mid)
            cur = last[shift:]
            continue
        if len(cur + sep + it) <= width:
            cur = cur + sep + it
        else:
            out.append(cur)
            cur = pad + it
            level = 1
    out.append(cur)
    return out


def balance(L, i):
    b = 0
    for t in L.code[i]:
        if t.kind == 'op' and t.text in '([{':
            b += 1
        elif t.kind == 'op' and t.text in ')]}':
            b -= 1
        elif t.kind == 'kw' and t.text in OPENERS:
            b += 1
        elif t.kind == 'kw' and t.text in CLOSERS:
            b -= 1
    return b


def block_arg(L, j, ind):
    """Line j (at ind + 4) opens an argument that ends on a later line: its last line, or None."""
    lines = L.lines
    if j in L.masked or L.multi[j]:
        return None
    bal = balance(L, j)
    if bal <= 0:
        return None
    k = j + 1
    while k < len(lines):
        if k in L.masked or L.multi[k]:
            return None
        if not lines[k].strip():
            k += 1
            continue
        bal += balance(L, k)
        if bal < 0:
            return None
        if bal == 0:
            break
        if indent_of(lines[k]) < ind + 8:
            return None
        k += 1
    if k >= len(lines) or bal != 0 or indent_of(lines[k]) < ind + 4 or L.comment[k]:
        return None
    return k


def closer_ok(L, j):
    """Line j closes a call: `)` plus closing brackets, commas, or a short balanced tail (`) or {}`, `) then`)."""
    s = L.lines[j].strip()
    if not s.startswith(')') or not L.plain(j):
        return False
    rest = s.lstrip(')]},;').strip()
    for kw in ('then', 'do'):
        if rest == kw or rest.endswith(' ' + kw):
            rest = rest[:-len(kw)].strip()
    if not rest:
        return True
    br = 0
    for t in code_toks(lua_tokens(rest)):
        if t.kind == 'kw' and t.text in OPENERS + CLOSERS + ('then', 'do', 'else', 'elseif'):
            return False
        if t.text in '([{':
            br += 1
        elif t.text in ')]}':
            br -= 1
            if br < 0:
                return False
    return br == 0


def long_string_arg(L, j):
    """Line j holds only the start of a multi-line [[ ]] string: (last line of the string, ok)."""
    code = L.code[j]
    if not (L.multi[j] and len(code) == 1 and code[0].kind == 'str' and code[0].text.startswith('[')
            and not L.comment[j] and j not in L.masked):
        return None
    t = code[0]
    e = L.line_of(t.end - 1)
    after = [x for x in L.code[e] if x.start >= t.end]
    if L.comment[e] or not all(x.text == ',' for x in after) or len(after) > 1:
        return None
    return e


def repack_calls(L):
    """StyLua's one-argument-per-line call -> the owner's packed arguments."""
    lines = L.lines
    out, i, n, changed = [], 0, len(lines), 0
    while i < n:
        ln = lines[i]
        code = L.code[i]
        ok = (L.plain(i) and code and code[-1].text == '(' and len(code) >= 2
              and (code[-2].kind == 'name' or code[-2].text in (')', ']')
                   or (code[-2].kind == 'kw' and code[-2].text == 'function')))
        if ok:
            ind = indent_of(ln)
            j = i + 1
            args = []
            while j < n and not (indent_of(lines[j]) == ind and lines[j].strip().startswith(')')):
                if indent_of(lines[j]) != ind + 4 or not lines[j].strip():
                    ok = False
                    break
                e = long_string_arg(L, j)
                if e is not None:
                    args.append(('str', lines[j].strip(), lines[j + 1:e], lines[e].rstrip()))
                    j = e + 1
                    continue
                if L.plain(j) and L.balanced(j):
                    args.append(lines[j].strip())
                    j += 1
                    continue
                e = block_arg(L, j, ind) if not L.comment[j] or L.code[j] else None
                if e is None:
                    ok = False
                    break
                args.append(('block', lines[j].strip(), lines[j + 1:e], lines[e].rstrip()))
                j = e + 1
            if ok and j < n and args and closer_ok(L, j):
                ends = [a[3] if isinstance(a, tuple) else a for a in args]
                if all(x.endswith(',') for x in ends[:-1]) and not ends[-1].endswith(','):
                    last = args[-1]
                    close = lines[j].strip()
                    if isinstance(last, tuple):
                        args[-1] = last[:3] + (last[3] + close,)
                    else:
                        args[-1] = last + close
                    out.extend(pack(ln.rstrip(), args, ind))
                    changed += 1
                    i = j + 1
                    continue
        out.append(ln)
        i += 1
    return '\n'.join(out), changed


def repack_conditions(L):
    """StyLua's `if` / conditions / `then` (and `for x in` / iterator / `do`) -> `if a and b` / `    or c then`."""
    lines = L.lines
    out, i, n, changed = [], 0, len(lines), 0
    while i < n:
        ln = lines[i]
        kw = ln.strip()
        is_for = kw.startswith('for ') and kw.endswith(' in')
        if (kw in ('if', 'elseif', 'while') or is_for) and L.plain(i):
            ind = indent_of(ln)
            j = i + 1
            parts = []
            ok = True
            closer = 'do' if kw == 'while' or is_for else 'then'
            while j < n and not (indent_of(lines[j]) == ind and lines[j].strip() == closer):
                if not (L.plain(j) and indent_of(lines[j]) == ind + 4 and L.balanced(j) and lines[j].strip()):
                    ok = False
                    break
                parts.append(lines[j].strip())
                j += 1
            if ok and j < n and parts and L.plain(j):
                parts[-1] += ' ' + closer
                new = pack(' ' * ind + kw + ' ' + parts[0], parts[1:], ind, fresh=False)
                out.extend(new)
                changed += 1
                i = j + 1
                continue
        out.append(ln)
        i += 1
    return '\n'.join(out), changed


CONT_RE = re.compile(r'^(and|or|\.\.|==|~=|<=|>=|<|>|\+|\*|/|//|%) ')


def repack_binary(L):
    """StyLua's one-operand-per-line expression (`x = a` / `    or b` / `    or c`) -> operands packed onto
    as few continuation lines as fit, each starting with its operator, as in the owner's code."""
    lines = L.lines
    out, i, n, changed = [], 0, len(lines), 0
    while i < n:
        ln = lines[i]
        ind = indent_of(ln)
        if L.plain(i) and L.balanced(i) and ln.strip() and i + 2 < n:
            j = i + 1
            parts = []
            while (j < n and L.plain(j) and indent_of(lines[j]) == ind + 4 and L.balanced(j)
                   and CONT_RE.match(lines[j].strip())):
                parts.append(lines[j].strip())
                j += 1
            if len(parts) >= 2:
                new = pack(ln.rstrip(), parts, ind, fresh=False)
                if new != lines[i:j]:
                    out.extend(new)
                    changed += 1
                    i = j
                    continue
        out.append(ln)
        i += 1
    return '\n'.join(out), changed


def split_top(toks, a, b):
    """Split toks[a:b] at top-level commas: list of (first, last) token index pairs."""
    parts, depth, s = [], 0, a
    for k in range(a, b):
        t = toks[k]
        if t.kind == 'op' and t.text in '([{':
            depth += 1
        elif t.kind == 'op' and t.text in ')]}':
            depth -= 1
        elif t.kind == 'op' and t.text == ',' and depth == 0:
            parts.append((s, k - 1))
            s = k + 1
    if s <= b - 1:
        parts.append((s, b - 1))
    return parts


def matching(toks, k):
    depth = 0
    for j in range(k, len(toks)):
        t = toks[j]
        if t.kind == 'op' and t.text in '([{':
            depth += 1
        elif t.kind == 'op' and t.text in ')]}':
            depth -= 1
            if depth == 0:
                return j
    return None


def repack_assignments(L):
    """StyLua's `x =` / value hang: a table becomes one field per line, a call gets packed arguments, a string
    or a long SQL string moves up next to the `=`."""
    lines = L.lines
    out, i, n, changed = [], 0, len(lines), 0
    while i < n:
        ln = lines[i]
        code = L.code[i]
        if (L.plain(i) and code and code[-1].text == '=' and i + 1 < n and i + 1 not in L.masked
                and not L.comment[i + 1] and indent_of(lines[i + 1]) == indent_of(ln) + 4):
            ind = indent_of(ln)
            rhs = L.code[i + 1]
            nxt = lines[i + 2] if i + 2 < n else ''
            ends_here = not nxt.strip() or indent_of(nxt) <= ind or nxt.lstrip().startswith(('end', 'else', '}', ')'))
            new = None
            if L.multi[i + 1] and rhs and rhs[0].kind == 'str' and len(rhs) == 1 and rhs[0].text.startswith('['):
                new = [ln.rstrip() + ' ' + lines[i + 1].strip()]
            elif L.plain(i + 1) and L.balanced(i + 1) and ends_here and rhs:
                text = lines[i + 1].strip()
                base = rhs[0].start
                last = len(rhs) - 1
                tail = ''
                if rhs[last].text == ',':
                    tail = ','
                    last -= 1
                if rhs[0].text == '{' and matching(rhs, 0) == last:
                    fields = split_top(rhs, 1, last)
                    if fields:
                        new = [ln.rstrip() + ' {']
                        for a, b in fields:
                            new.append(' ' * (ind + 4) + L.src[rhs[a].start:rhs[b].end] + ',')
                        new.append(' ' * ind + '}' + tail)
                elif len(rhs) == 1 + (1 if tail else 0) and rhs[0].kind == 'str':
                    new = [ln.rstrip() + ' ' + text]
                elif rhs[0].kind == 'name' and rhs[last].text == ')':
                    open_k = None
                    for k in range(1, last):
                        if rhs[k].text == '(' and matching(rhs, k) == last and all(
                                x.kind == 'name' or x.text in ('.', ':') for x in rhs[1:k]):
                            open_k = k
                            break
                    if open_k is not None:
                        args = split_top(rhs, open_k + 1, last)
                        if args:
                            head = ln.rstrip() + ' ' + L.src[rhs[0].start:rhs[open_k].end]
                            items = [L.src[rhs[a].start:rhs[b].end] + ',' for a, b in args]
                            items[-1] = items[-1][:-1] + ')' + tail
                            new = pack(head, items, ind)
            if new is not None:
                out.extend(new)
                changed += 1
                i += 2
                continue
        out.append(ln)
        i += 1
    return '\n'.join(out), changed


def collapse_one_liners(src, shapes):
    """Ifs, loops and functions that were written on one line, and that StyLua spread over several, go
    back on one line when the whole fits in 120 columns and none of its lines holds a comment or a
    multi-line string. Joining lines never changes what Lua reads."""
    if not shapes or not any(shapes.values()):
        return src, 0
    L = Lines(src)
    ct = code_toks(lua_tokens(src))
    line_of = L.line_of
    counts = {k: 0 for k in SHAPE_KW.values()}
    spans = []
    for i, t in enumerate(ct):
        if t.kind != 'kw' or t.text not in SHAPE_KW:
            continue
        kind = SHAPE_KW[t.text]
        k = counts[kind]
        counts[kind] += 1
        if k not in shapes.get(kind, ()):
            continue
        close = block_close(ct, i)
        if close is None:
            continue
        h, e = line_of(t.start), line_of(ct[close].start)
        if e > h:
            spans.append((h, e, shapes[kind][k]))
    lines = L.lines
    used = set()
    done = 0
    joined_at = {}
    for h, e, semi in sorted(spans, key=lambda x: (x[0], -x[1])):
        if any(x in used for x in range(h, e + 1)):
            continue
        if not all(L.plain(x) for x in range(h, e + 1)):
            continue
        joined = lines[h].rstrip()
        body = indent_of(lines[h]) + 4
        for x in range(h + 1, e + 1):
            # two statements of the block's own body: `;` between them when the author wrote one there
            sep = ' '
            if (semi and indent_of(lines[x]) == body and indent_of(lines[x - 1]) == body and L.balanced(x)
                    and L.balanced(x - 1) and not re.match(r'(end|else|elseif|until)\b', lines[x].strip())
                    and not joined.endswith(';') and not lines[x].strip().startswith(';')):
                sep = '; '
            joined += sep + lines[x].strip()
        if len(joined) > WIDTH:
            continue
        joined_at[h] = (e, joined)
        used.update(range(h, e + 1))
        done += 1
    out, x = [], 0
    while x < len(lines):
        if x in joined_at:
            e, joined = joined_at[x]
            out.append(joined)
            x = e + 1
            continue
        out.append(lines[x])
        x += 1
    return '\n'.join(out), done


def same_code(a, b):
    """The code tokens and comments of a and b are the same, apart from a trailing comma before `}` and the
    `;` put back between two statements of a one-line block."""
    def norm(src):
        toks = lua_tokens(src)
        seq = [(t.kind, t.text) for t in toks if not (t.kind == 'op' and t.text == ';')]
        return [x for k, x in enumerate(seq) if not (x == ('op', ',') and k + 1 < len(seq) and seq[k + 1] == ('op', '}'))]
    return norm(a) == norm(b)


def layout_pass(path, src, shapes):
    before = src
    src, n1 = collapse_one_liners(src, shapes)
    total = {'calls': 0, 'conditions': 0, 'assignments': 0, 'expressions': 0}
    for _ in range(6):
        moved = 0
        for key, fn in (('assignments', repack_assignments), ('calls', repack_calls),
                        ('conditions', repack_conditions), ('expressions', repack_binary)):
            src, n = fn(Lines(src))
            total[key] += n
            moved += n
        if not moved:
            break
    if not same_code(before, src):
        sys.exit(f'restyle: the layout pass changed the code of {rel(path)} (a bug in tools/restyle.py)')
    bump('lua: one-line loops and functions kept', n1)
    bump('lua: packed call arguments', total['calls'])
    bump('lua: packed conditions', total['conditions'])
    bump('lua: packed operand lines', total['expressions'])
    bump('lua: assignment hangs (tables exploded, calls packed)', total['assignments'])
    return src


# ============================================================================
#                            HEADERS AND BANNERS
# ============================================================================

PATH_PREFIX_RE = re.compile(r'^(?:[\w./-]+\.(?:lua|ts|tsx|css)|Crimson-Police)\s+·\s+')
SEPARATORS = (' (', ': ', ' - ', ' — ', ' · ', '; ', ' -> ', ' → ')
PLAIN_WORD_RE = re.compile(r"^[A-Za-z][a-z]*(?:'s)?$|^[A-Za-z][a-z]*(?:-[A-Za-z][a-z]*)+$|^[A-Z]{2,}[a-z]?s?$")


def caps_title(title):
    """Upper-case the banner label (up to the first separator); code-like words and the rest stay."""
    cut = len(title)
    for sep in SEPARATORS:
        k = title.find(sep)
        if 0 < k < cut:
            cut = k
    head, tail = title[:cut], title[cut:]
    words = [w.upper() if PLAIN_WORD_RE.match(w.rstrip(',.;')) else w for w in head.split(' ')]
    return ' '.join(words) + tail


TITLE_MAX = 56         # a longer banner title keeps its label; the explanation after it moves under the banner


def split_title(title):
    """A long banner title -> (label, explanation): the label is the part before the first ' (', ': ' or
    ' - ', the rest moves to a comment line under the banner (without its brackets when it is one group)."""
    if len(title) <= TITLE_MAX:
        return title, None
    cuts = [(title.find(sep), sep) for sep in (' (', ': ', ' - ', ' — ') if title.find(sep) > 0]
    if not cuts:
        return title, None
    k, sep = min(cuts)
    label, tail = title[:k], title[k + len(sep):].strip()
    if sep == ' (':
        tail = '(' + tail
        if tail.endswith(')') and tail.count('(') == 1 and tail.count(')') == 1:
            tail = tail[1:-1].strip()
    if not tail or len(label) < 3 or len(label) > TITLE_MAX:
        return title, None
    if re.match(r'^[a-z]+(?=[\s,;]|$)', tail):
        tail = tail[0].upper() + tail[1:]
    if tail[-1].isalnum() or tail[-1] in ')"\'':
        tail += '.'
    return label, tail


def banner_block(indent, lead, title):
    title = caps_title(title.strip())
    if indent == '':
        label, tail = split_title(title)
        pad = max(0, (RULE_WIDTH - len(label)) // 2)
        rule = f'{lead} ' + '=' * RULE_WIDTH
        out = [rule, f'{lead} ' + ' ' * pad + label, rule]
        if tail:
            out.append(f'{lead} {tail}')
        return out
    head = f'{indent}{lead} ---- {title} '
    return [head + '-' * max(4, SUB_WIDTH - len(head))]


HEADER_WIDTH = 116     # '-- ' + 116 = 119 columns


DECORATION_RE = re.compile(r'^[\s═─━=\-*#~╔╗╚╝║│┌┐└┘]*$')


def summary_lines(text_lines):
    """The owner's header: the first paragraph if it has at most 3 lines, else up to its first full
    sentence. Box and rule lines are dropped. Lines that were wrapped around a removed path prefix are
    wrapped again to the line width; otherwise the author's line breaks stay."""
    para = []
    for ln in text_lines:
        s = ln.strip().strip('║│').strip()
        if DECORATION_RE.match(s):
            if para:
                break
            continue
        para.append(s)
    if not para:
        return []
    had_prefix = bool(PATH_PREFIX_RE.match(para[0]))
    first = PATH_PREFIX_RE.sub('', para[0])
    if first and first[0].islower() and not re.match(r'^[a-z]+[A-Z.:_(]', first):
        first = first[0].upper() + first[1:]
    para[0] = first
    if len(para) > HEADER_LINES:
        for k in range(HEADER_LINES):
            if para[k].endswith('.'):
                para = para[:k + 1]
                break
        else:
            para = para[:1]
    if had_prefix:
        para = textwrap.wrap(' '.join(para), HEADER_WIDTH, break_long_words=False, break_on_hyphens=False)
    return para


def header_text(block_lines, lead):
    out = []
    for ln in block_lines:
        s = ln.strip()
        if s.startswith(lead):
            s = s[len(lead):]
            if s.startswith(' '):
                s = s[1:]
        out.append(s)
    return out


def split_header(lines, lang):
    """(start, end, text lines, kind) of the leading comment block, or None."""
    if not lines:
        return None
    lead = '--' if lang == 'lua' else '//'
    first = lines[0]
    if lang == 'lua' and first.startswith('--[['):
        for k, ln in enumerate(lines):
            idx = ln.find(']]', 4 if k == 0 else 0)
            if idx < 0:
                continue
            if ln[idx + 2:].strip():
                return None
            body = [first[4:idx]] if k == 0 else [first[4:]] + lines[1:k] + [ln[:idx]]
            return 0, k + 1, [b.rstrip() for b in body], 'long'
        return None
    if not first.startswith(lead) or re.match(r'^\s*(--|//)\s*[=─═-]{8,}', first):
        return None
    k = 0
    while k < len(lines) and lines[k].startswith(lead) and not is_banner_line(lines[k]):
        k += 1
    return 0, k, header_text(lines[:k], lead), 'line'


def is_banner_line(ln):
    return bool(RULE_RE.match(ln) or LUA_THIN_RE.match(ln) or LUA_INLINE_DOUBLE_RE.match(ln) or SUB_RE.match(ln))


def header_pass(path, lines, lang, notes):
    h = split_header(lines, lang)
    if not h:
        return lines
    start, end, text, kind = h
    lead = '--' if lang == 'lua' else '//'
    keep = summary_lines(text)
    new = [f'{lead} {s}' for s in keep]
    if end < len(lines) and lines[end].strip():
        new.append('')          # one blank line between the header and the code
    if new == lines[start:end]:
        return lines
    rest = [t for t in text]
    while rest and not rest[-1].strip():
        rest.pop()
    if len(rest) > len(keep) or kind == 'long':
        notes[rel(path)] = rest
    bump(f'{lang}: file headers shortened')
    bump(f'{lang}: header lines removed', max(0, (end - start) - len(keep)))
    return new + lines[end:]


LUA_THIN_RE = re.compile(r'^(\s*)(--|//)\s*[─━]{2,}\s*(\S.*?)\s*[─━]*\s*$')
LUA_INLINE_DOUBLE_RE = re.compile(r'^(\s*)(--|//)\s*═{3,}\s*(\S.*?)\s*═{3,}\s*$')
RULE_RE = re.compile(r'^(\s*)(--|//)\s*(?:═{10,}|={10,})\s*$')
SUB_RE = re.compile(r'^(\s*)(--|//) ---- (\S.*?) -{4,}$')
TITLE_RE = re.compile(r'^(\s*)(--|//)\s*(\S.*?)\s*$')


def banner_pass(lines, masked, lang):
    out = []
    i, n = 0, len(lines)
    changed = 0
    while i < n:
        ln = lines[i]
        if i in masked:
            out.append(ln)
            i += 1
            continue
        block = None
        m = RULE_RE.match(ln)
        if m and i + 2 < n and (i + 1) not in masked and (i + 2) not in masked:
            t = TITLE_RE.match(lines[i + 1])
            r2 = RULE_RE.match(lines[i + 2])
            if t and r2 and not RULE_RE.match(lines[i + 1]) and t.group(1) == m.group(1) == r2.group(1):
                block = (m.group(1), m.group(2), t.group(3), 3)
        if block is None:
            for rx in (LUA_THIN_RE, LUA_INLINE_DOUBLE_RE, SUB_RE):
                m = rx.match(ln)
                if m:
                    block = (m.group(1), m.group(2), m.group(3), 1)
                    break
        if block is None:
            out.append(ln)
            i += 1
            continue
        indent, lead, title, used = block
        new = banner_block(indent, lead, title)
        if indent == '':
            if out and out[-1].strip():
                out.append('')
            out.extend(new)
            nxt = lines[i + used] if i + used < n else ''
            if nxt.strip() and not nxt.lstrip().startswith(lead):
                out.append('')
        else:
            out.extend(new)
        if new != lines[i:i + used]:
            changed += 1
        i += used
    bump(f'{lang}: section banners rewritten', changed)
    return out


# ============================================================================
#                        TRAILING COMMENT ALIGNMENT
# ============================================================================

def trailing_comments(src):
    """lines, {line: column of its trailing short comment}, masked lines, lines with code."""
    toks = lua_tokens(src)
    masked = multiline_mask(src, toks)
    lines = src.split('\n')
    starts = [0]
    for ln in lines[:-1]:
        starts.append(starts[-1] + len(ln) + 1)
    trailing = {}
    code_on = set()
    for t in toks:
        if t.kind == 'comment':
            ln = bisect_right(starts, t.start) - 1
            if ln in code_on and ln not in masked:
                trailing[ln] = t.start - starts[ln]
        else:
            first = bisect_right(starts, t.start) - 1
            last = bisect_right(starts, t.end - 1 if t.end > t.start else t.start) - 1
            code_on.update(range(first, last + 1))
            for x in range(first + 1, last + 1):
                trailing.pop(x, None)
    return lines, trailing, masked, code_on


def comment_key(line, col):
    return re.sub(r'\s+', '', line[:col]), line[col:]


def comment_columns(src):
    """The column of every trailing comment as the author wrote it, keyed by its code (without whitespace)
    and its text (a key found at two different columns is dropped), and the comment lines that continue a
    trailing comment at its column, keyed ('cont', text)."""
    lines, trailing, masked, code_on = trailing_comments(src)
    cols = {}
    for ln, col in trailing.items():
        key = comment_key(lines[ln], col)
        cols[key] = col if cols.get(key, col) == col else None
    prev = None
    for x, ln in enumerate(lines):
        s = ln.strip()
        if x in trailing:
            prev = trailing[x]
        elif prev is not None and s.startswith('--') and x not in masked and x not in code_on \
                and len(ln) - len(ln.lstrip()) == prev:
            cols[('cont', s)] = prev
        else:
            prev = None
    return {k: v for k, v in cols.items() if v is not None}


def align_pass(src, kept=None):
    """Trailing comments: a comment whose line kept its code keeps the column it was written at (StyLua
    removes that padding); a group of consecutive commented lines is aligned at one column, the one its
    author used when the lines agree, else at column 33 or 2 past the longest line."""
    kept = kept or {}
    lines, trailing, masked, code_on = trailing_comments(src)

    def bridge(a, b, indent):
        # the lines between two commented lines are code at the same indent, with no comment of their own
        for x in range(a + 1, b):
            s = lines[x]
            if not s.strip() or x in masked or x not in code_on or s.lstrip().startswith('--'):
                return False
            if len(s) - len(s.lstrip()) != indent:
                return False
        return True

    def groups_of(bridged):
        groups, cur = [], []
        for ln in sorted(trailing):
            indent = len(lines[ln]) - len(lines[ln].lstrip())
            if cur and indent == cur[-1][1] and (ln == cur[-1][0] + 1 or (bridged and bridge(cur[-1][0], ln, indent))):
                cur.append((ln, indent))
            else:
                groups.append(cur)
                cur = [(ln, indent)]
        groups.append(cur)
        return [g for g in groups if g]

    def column(g):
        codes = {ln: lines[ln][:trailing[ln]].rstrip() for ln, _ in g}
        longest = max(len(c) for c in codes.values())
        known = {kept.get(comment_key(lines[ln], trailing[ln])) for ln, _ in g} - {None}
        if len(known) == 1:
            col = known.pop()
            if col >= longest + 1:
                return codes, col
        if len(g) == 1:
            return None
        col = max(longest + 2, ALIGN_MIN)
        if any(col + len(lines[ln]) - trailing[ln] > ALIGN_MAX for ln, _ in g):
            return None
        return codes, col

    changed = 0
    done = set()
    newcol = {}
    for bridged in (True, False):
        # a group that spans comment-less lines is aligned as a whole (a table's comments share one
        # column, like the owner's config); if it cannot be, its unbridged parts are tried
        for g in groups_of(bridged):
            if any(ln in done for ln, _ in g) or (bridged and len(g) == 1):
                continue
            r = column(g)
            if r is None:
                continue
            codes, col = r
            for ln, _ in g:
                done.add(ln)
                newcol[ln] = col
                new = codes[ln].ljust(col) + lines[ln][trailing[ln]:]
                if new != lines[ln]:
                    lines[ln] = new
                    changed += 1
    # a comment line that continued a trailing comment at its column stays under it
    prev = None
    for x, ln in enumerate(lines):
        s = ln.strip()
        if x in trailing:
            prev = newcol.get(x, trailing[x])
        elif prev is not None and s.startswith('--') and x not in masked and x not in code_on \
                and ('cont', s) in kept:
            new = ' ' * prev + s
            if new != ln:
                lines[x] = new
                changed += 1
        else:
            prev = None
    bump('lua: trailing comments aligned', changed)
    return '\n'.join(lines)


# ============================================================================
#                                WEB PASSES
# ============================================================================

JSDOC_ONE_RE = re.compile(r'^(\s*)/\*\*\s?(.*?)\s*\*/\s*$')


JSDOC_LEAD_RE = re.compile(r'^(\s*)/\*\*\s*(.*?)\s*\*/\s+(\S.*)$')


def jsdoc_pass(lines):
    out, i, changed = [], 0, 0
    while i < len(lines):
        ln = lines[i]
        m = JSDOC_LEAD_RE.match(ln)
        if m and m.group(2) and '*/' not in m.group(2) and '//' not in m.group(3) and '/*' not in m.group(3):
            # `/** metres */ length: number;` -> `length: number; // metres`
            out.append(f'{m.group(1)}{m.group(3)} // {m.group(2)}')
            changed += 1
            i += 1
            continue
        m = JSDOC_ONE_RE.match(ln)
        if m and m.group(2):
            out.append(f'{m.group(1)}// {m.group(2)}')
            changed += 1
            i += 1
            continue
        s = ln.strip()
        if s.startswith('/**') and '*/' not in s:
            indent = ln[:len(ln) - len(ln.lstrip())]
            body, j = [], i + 1
            first = s[3:].strip()
            if first:
                body.append(first)
            while j < len(lines) and '*/' not in lines[j]:
                body.append(re.sub(r'^\s*\*\s{0,3}', '', lines[j]).rstrip())
                j += 1
            if j < len(lines) and lines[j].rstrip().endswith('*/') and lines[j].count('*/') == 1:
                last = re.sub(r'^\s*\*?\s{0,3}', '', lines[j].rstrip()[:-2]).rstrip()
                if last:
                    body.append(last)
                out.extend(f'{indent}// {b}'.rstrip() for b in body)
                changed += 1
                i = j + 1
                continue
        out.append(ln)
        i += 1
    bump('web: /** */ comments as //', changed)
    return out


BLOCK_LINE_RE = re.compile(r'^(\s*)/\*(?!\*)\s*(.*?)\s*\*/\s*$')


def block_comment_pass(lines):
    """A /* ... */ comment alone on a line of TS/TSX code becomes a // comment (JSX keeps {/* */})."""
    out, changed = [], 0
    for ln in lines:
        m = BLOCK_LINE_RE.match(ln)
        if m and m.group(2) and '*/' not in m.group(2):
            out.append(f'{m.group(1)}// {m.group(2)}')
            changed += 1
        else:
            out.append(ln)
    bump('web: /* */ line comments as //', changed)
    return out


CSS_BANNER_RE = re.compile(r'^(\s*)/\*\s*[─━]{2,}\s*(\S.*?)\s*[─━]*\s*\*/\s*$')


def css_spacing_pass(lines):
    """One blank line after every top-level rule, as in the owner's multi-line stylesheets (the steps of a
    @keyframes and the rules inside @media stay together)."""
    out, changed = [], 0
    for k, ln in enumerate(lines):
        out.append(ln)
        nxt = lines[k + 1] if k + 1 < len(lines) else ''
        if ln.rstrip() == '}' and nxt.strip() and not nxt.startswith((' ', '}')):
            out.append('')
            changed += 1
    bump('web: blank lines between css rules', changed)
    return out


def css_banner_pass(lines):
    out, changed = [], 0
    for ln in lines:
        m = CSS_BANNER_RE.match(ln)
        if m:
            title = m.group(2)
            new = f'{m.group(1)}/* {title[0].upper() + title[1:]} */'
            changed += new != ln
            out.append(new)
        else:
            out.append(ln)
    bump('web: css banners rewritten', changed)
    return out


# ============================================================================
#                                  NOTES
# ============================================================================

NOTES_INTRO = """# File notes

The long headers that used to open each file, kept word for word. The owner's style (docs/STYLE.md)
keeps a file header to a short summary; tools/restyle.py moved the rest here. Section names are file
paths. Anything here that is also in docs/ARCHITECTURE.md is owned by ARCHITECTURE.md.
"""


def load_notes():
    notes = {}
    if not os.path.exists(NOTES):
        return notes
    cur, inside = None, False
    for ln in read(NOTES).split('\n'):
        m = re.match(r'^## (\S+)$', ln)
        if m and not inside:
            cur = m.group(1)
            notes[cur] = []
        elif cur is not None and not inside and ln == '```text':
            inside = True  # the note is only what sits between its fences
        elif cur is not None and inside and ln == '```':
            inside = False
        elif cur is not None and inside:
            notes[cur].append(ln)
    for k in notes:
        while notes[k] and not notes[k][-1]:
            notes[k].pop()
    return notes


def save_notes(notes):
    parts = [NOTES_INTRO]
    for path in sorted(notes):
        parts.append(f'## {path}\n\n```text\n' + '\n'.join(notes[path]) + '\n```\n')
    write(NOTES, '\n'.join(parts))


# ============================================================================
#                                 PIPELINE
# ============================================================================

def run_formatters(lua_files, web_files, check_only):
    stylua = shutil.which('stylua') or os.path.expanduser('~/.cargo/bin/stylua')
    if lua_files:
        if not os.path.exists(stylua):
            sys.exit('stylua not found: cargo install stylua --features lua54 (or --no-format)')
        # StyLua can need a second pass to settle (a call it wrapped one way may fit another way next time):
        # repeat until nothing changes, so one restyle run is final.
        for _ in range(5):
            snapshot = [read(p) for p in lua_files]
            for k in range(0, len(lua_files), 200):
                subprocess.run([stylua, '--config-path', os.path.join(ROOT, 'stylua.toml'), *lua_files[k:k + 200]],
                               check=True)
            if [read(p) for p in lua_files] == snapshot:
                break
    if web_files:
        prettier = os.path.join(WEB, 'node_modules', '.bin', 'prettier')
        cmd = [prettier] if os.path.exists(prettier) else ['npx', '--yes', PRETTIER]
        for k in range(0, len(web_files), 200):
            subprocess.run([*cmd, '--config', os.path.join(WEB, '.prettierrc.json'), '--log-level', 'warn',
                            '--write', *web_files[k:k + 200]], check=True, cwd=WEB)


def lua_passes(path, lf, plan, quote_edits, notes):
    src = apply_edits(lf.src, rename_edits(lf, plan) + (quote_edits or []))
    bump('lua: identifier occurrences renamed', sum(1 + len(lf.bindings[b].refs) for b in plan))
    bump('lua: local functions renamed', len(plan))
    bump('lua: test strings following a rename', len(quote_edits or []))
    src = table_insert_pass(src)
    src = print_prefix_pass(src)
    lines = src.split('\n')
    lines = header_pass(path, lines, 'lua', notes)
    src = '\n'.join(lines)
    toks = lua_tokens(src)
    lines = banner_pass(src.split('\n'), multiline_mask(src, toks), 'lua')
    src = '\n'.join(lines)
    return src.rstrip('\n') + '\n'


def web_passes(path, src, notes):
    lines = src.split('\n')
    if path.endswith(WEB_EXT):
        lines = header_pass(path, lines, 'web', notes)
        lines = banner_pass(lines, set(), 'web')
        lines = jsdoc_pass(lines)
        lines = block_comment_pass(lines)
    elif path.endswith('.css'):
        lines = css_banner_pass(lines)
        lines = css_spacing_pass(lines)
    src = '\n'.join(lines)
    return src.rstrip('\n') + '\n'


def finish_lua(job):
    """The last steps of one Lua file (run in a worker): (path, new source, stats of this file, error)."""
    path, shapes, columns = job
    saved = dict(stats)
    stats.clear()
    try:
        src, err = align_pass(layout_pass(path, read(path), shapes), columns), None
    except SystemExit as e:
        src, err = None, str(e)
    mine = dict(stats)
    stats.clear()
    stats.update(saved)
    return path, src, mine, err


def run_jobs(fn, jobs):
    """fn over jobs in RESTYLE_JOBS worker processes (default: one per core, at most 8), in order."""
    n = int(os.environ.get('RESTYLE_JOBS') or min(8, os.cpu_count() or 1))
    if n <= 1 or len(jobs) < 2:
        return [fn(j) for j in jobs]
    with ProcessPoolExecutor(max_workers=n) as ex:
        return list(ex.map(fn, jobs, chunksize=1))


def web_targets(paths):
    """web/src (ts, tsx, css) and the build sources next to it (WEB_TOP) that the paths cover."""
    src = os.path.join(WEB, 'src') + os.sep
    files = [p for p in walk(paths, ('.ts', '.tsx', '.css')) if p.startswith(src)]
    for name in WEB_TOP:
        p = os.path.join(WEB, name)
        if os.path.isfile(p) and any(p == a or p.startswith(a.rstrip(os.sep) + os.sep) for a in paths):
            files.append(p)
    return files


def restyle(paths, fmt=True, check_only=False):
    lua_files = walk(paths, ('.lua',))
    web_files = web_targets(paths)
    before = {p: read(p) for p in lua_files + web_files}
    # what StyLua undoes and the author chose: the ifs, loops and functions written on one line, and the
    # columns of the trailing comments
    shapes = {p: one_line_shapes(before[p]) for p in lua_files}
    columns = {p: comment_columns(before[p]) for p in lua_files}
    if fmt:
        run_formatters(lua_files, web_files, check_only)
    tests_dir = os.path.join(ROOT, 'tests') + os.sep
    all_lua = walk([RES, os.path.join(ROOT, 'tests')], ('.lua',))
    files = {p: LuaFile(read(p)) for p in all_lua}
    for p in lua_files:
        if p not in files:
            files[p] = LuaFile(read(p))
    globals_used = set()
    for lf in files.values():
        globals_used |= lf.free_names()
    plans = {}
    for p in lua_files:
        plan, skipped = rename_plan(files[p], globals_used)
        plans[p] = plan
        for why in skipped.values():
            bump(f'lua: local function renames skipped ({why.split(" ")[0]})')
    # Test specs read module sources and quote code: a quote follows the renames it matches, and a rename
    # that would leave a quote half-matching is dropped.
    modules = {p: lf for p, lf in files.items() if not p.startswith(tests_dir)}
    tests = [p for p in all_lua if p.startswith(tests_dir)]
    quote_edits, dropped = quoted_renames(tests, modules, plans, set(lua_files))
    bump('lua: local function renames skipped (a test quotes them)', dropped)
    notes = load_notes()
    notes_before = dict(notes)
    for p in lua_files:
        write(p, lua_passes(p, files[p], plans[p], quote_edits.get(p), notes))
    for p in web_files:
        write(p, web_passes(p, read(p), notes))
    # the passes change code (renames, appends): format once more, then lay out what StyLua cannot and
    # align the trailing comments, which StyLua would undo (the last steps on purpose)
    if fmt:
        run_formatters(lua_files, [], check_only)
    # the biggest files first, so the workers finish together
    order = sorted(lua_files, key=lambda p: -len(read(p)))
    for p, src, file_stats, err in run_jobs(finish_lua, [(p, shapes[p], columns[p]) for p in order]):
        if err:
            sys.exit(err)
        for k, v in file_stats.items():
            bump(k, v)
        write(p, src)
    changed = [p for p in lua_files + web_files if read(p) != before[p]]
    if notes != notes_before:
        save_notes(notes)
    return changed


def main(argv):
    args = [a for a in argv if not a.startswith('--')]
    fmt = '--no-format' not in argv
    check_only = '--check' in argv
    paths = [os.path.abspath(a) for a in args] or [RES, os.path.join(ROOT, 'tests')]
    if check_only:
        tmp = tempfile.mkdtemp(prefix='restyle-check-')
        try:
            copy = os.path.join(tmp, 'tree')
            shutil.copytree(ROOT, copy, symlinks=True,
                            ignore=shutil.ignore_patterns('.git', 'node_modules', 'dist', 'saves'))
            nm = os.path.join(WEB, 'node_modules')
            if os.path.isdir(nm):
                os.symlink(nm, os.path.join(copy, 'Crimson-Police', 'web', 'node_modules'))
            # only the flags go along: a path is passed as its copy (as given, it would name the real tree)
            r = subprocess.run([sys.executable, os.path.join(copy, 'tools', 'restyle.py'),
                                *[a for a in argv if a.startswith('--') and a != '--check'],
                                *[os.path.join(copy, os.path.relpath(p, ROOT)) for p in paths if args]],
                               capture_output=True, text=True, cwd=copy)
            if r.returncode != 0:
                print(r.stdout + r.stderr)
                return 2
            diff = subprocess.run(['diff', '-rq', '-x', 'node_modules', '-x', 'dist', '-x', '.git', '-x', 'saves',
                                   ROOT, copy], capture_output=True, text=True).stdout
            lines = [ln for ln in diff.splitlines() if ln.startswith('Files ')]
            for ln in lines:
                print(ln.split(' ')[1].replace(ROOT + os.sep, '') + ' would change')
            return 1 if lines else 0
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    changed = restyle(paths, fmt=fmt)
    for k in sorted(stats):
        print(f'  {k}: {stats[k]}')
    print(f'restyle: {len(changed)} files changed')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

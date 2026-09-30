#!/usr/bin/env python3
"""Control flow of Lua loops, for tools/lint_fivem.py rule FX10 (dev tooling, not shipped).

Parses Lua 5.4 (plus CfxLua backtick hashes and compound assignments, so other resources can be checked too) with a
small recursive-descent parser. For every while / repeat loop it works out whether one pass through the body has a
path that neither yields nor leaves the loop:

  yields  Wait, Citizen.Wait, coroutine.yield, lib.callback.await, Citizen.Await, or a function of the checked files
          that yields on every path (a fixed point over their definitions; a yield inside pcall(function() ... end)
          counts). ox_lib's progressBar / skillCheck / request* do NOT count: they return at once when one is
          already running or the asset is loaded.
  leaves  break, return, error(), a goto counts as going round (it usually jumps to a `::continue::` label).

  python3 tools/lua_flow.py [--all] file.lua ...     # HIT / bounded / pure lines (--all: every loop)

Verdicts: HIT = such a path exists, nothing on it moves what the condition reads, and the condition reads game
state: a native (a CamelCase global the files do not define; GetGameTimer too, it does not move inside a frame), a
function of the files that calls one, or a variable the body sets from one (`while true`: a native anywhere in the
body). The game or the server then hangs with nothing logged. bounded = the body always moves a value the
condition reads (v = v + 1, t[#t] = nil, table.remove(t)); pure = the condition reads no game state (pure Lua, its
progress is in a callee); ok = every path yields or leaves. An ipairs loop that appends to its own table is a HIT.
"""
import re, sys

KEYWORDS = {'and', 'break', 'do', 'else', 'elseif', 'end', 'false', 'for', 'function', 'goto', 'if', 'in',
            'local', 'nil', 'not', 'or', 'repeat', 'return', 'then', 'true', 'until', 'while'}

# calls that yield the running thread every time they are made
SEED_YIELDERS = {'Wait', 'Citizen.Wait', 'Citizen.Await', 'coroutine.yield', 'lib.callback.await'}
EXITS = {'error'}                     # calls that never return
INLINE_FN = {'pcall', 'xpcall'}       # a function literal passed here runs inline


# ───────────────────────────── tokenizer ─────────────────────────────
TOKEN_RE = re.compile(r'''
    (?P<ws>[ \t\r\f\v]+) |
    (?P<nl>\n) |
    (?P<longcomment>--\[(?P<lceq>=*)\[) |
    (?P<comment>--[^\n]*) |
    (?P<longstr>\[(?P<lseq>=*)\[) |
    (?P<str>"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`[^`\n]*`) |
    (?P<num>0[xX][0-9a-fA-F.]+(?:[pP][+-]?\d+)?|\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?) |
    (?P<name>[A-Za-z_]\w*) |
    (?P<op>\.\.\.|\.\.|==|~=|<=|>=|<<|>>|//|::|[-+*/]=|[-+*/%^\#&~|<>=(){}\[\];:,.])
''', re.X)


def tokenize(src):
    toks, i, line, n = [], 0, 1, len(src)
    while i < n:
        m = TOKEN_RE.match(src, i)
        if not m:
            raise SyntaxError(f'line {line}: cannot tokenize {src[i:i+20]!r}')
        kind = m.lastgroup
        if kind in ('lceq', 'lseq'):
            kind = 'longcomment' if m.group('longcomment') else 'longstr'
        text = m.group(0)
        if kind == 'nl':
            line += 1
            i = m.end()
            continue
        if kind == 'ws' or kind == 'comment':
            i = m.end()
            continue
        if kind in ('longcomment', 'longstr'):
            eq = m.group('lceq') if kind == 'longcomment' else m.group('lseq')
            close = ']' + (eq or '') + ']'
            end = src.find(close, m.end())
            end = n if end < 0 else end + len(close)
            body = src[i:end]
            if kind == 'longstr':
                toks.append(('str', body, line))
            line += body.count('\n')
            i = end
            continue
        if kind == 'name' and text in KEYWORDS:
            toks.append(('kw', text, line))
        else:
            toks.append((kind, text, line))
        i = m.end()
    toks.append(('eof', '', line))
    return toks


# ───────────────────────────── parser ─────────────────────────────
# Expression nodes: ('call', callee_str|None, prefix_node, [args], line, method)
#                   ('func', body, line, params) ('bin', op, l, r) ('un', op, e) ('table', [nodes])
#                   ('name', n) ('index', obj, key) ('const',) ('paren', e) ('vararg',)
# Statement nodes:  ('expr', [nodes], line, targets) ('if', [(cond, block)], else_block, line)
#                   ('while', cond, block, line) ('repeat', block, cond, line) ('fornum', [nodes], block, line, var)
#                   ('forin', [nodes], block, line, names) ('do', block) ('return', [nodes], line) ('break', line)
#                   ('funcdef', name, fnode, line, is_local)

BINPRI = {
    'or': (1, 1), 'and': (2, 2),
    '<': (3, 3), '>': (3, 3), '<=': (3, 3), '>=': (3, 3), '~=': (3, 3), '==': (3, 3),
    '|': (4, 4), '~': (5, 5), '&': (6, 6), '<<': (7, 7), '>>': (7, 7),
    '..': (9, 8), '+': (10, 10), '-': (10, 10),
    '*': (11, 11), '/': (11, 11), '//': (11, 11), '%': (11, 11),
    '^': (14, 13),
}
UNARY_PRI = 12


class Parser:
    def __init__(self, toks):
        self.t = toks
        self.i = 0

    def peek(self, k=0):
        return self.t[self.i + k]

    def next(self):
        tok = self.t[self.i]
        self.i += 1
        return tok

    def check(self, text):
        tok = self.peek()
        return tok[0] in ('kw', 'op') and tok[1] == text

    def accept(self, text):
        if self.check(text):
            return self.next()
        return None

    def expect(self, text):
        tok = self.next()
        if tok[1] != text or tok[0] not in ('kw', 'op'):
            raise SyntaxError(f'line {tok[2]}: expected {text!r}, got {tok[1]!r}')
        return tok

    def block_end(self):
        tok = self.peek()
        return tok[0] == 'eof' or (tok[0] == 'kw' and tok[1] in ('end', 'else', 'elseif', 'until'))

    def block(self):
        stmts = []
        while not self.block_end():
            if self.check('return'):
                line = self.next()[2]
                exprs = []
                if not self.block_end() and not self.check(';'):
                    exprs = self.exprlist()
                self.accept(';')
                stmts.append(('return', exprs, line))
                break
            s = self.statement()
            if s is not None:
                stmts.append(s)
        return stmts

    def statement(self):
        tok = self.peek()
        line = tok[2]
        if self.accept(';'):
            return None
        if self.check('::'):
            self.next(); self.next(); self.expect('::')
            return None
        if self.accept('break'):
            return ('break', line)
        if self.accept('goto'):
            name = self.next()[1]
            return ('goto', name, line)
        if self.accept('do'):
            b = self.block()
            self.expect('end')
            return ('do', b, line)
        if self.accept('while'):
            cond = self.expr()
            self.expect('do')
            b = self.block()
            end_line = self.expect('end')[2]
            return ('while', cond, b, line, end_line)
        if self.accept('repeat'):
            b = self.block()
            self.expect('until')
            cond = self.expr()
            return ('repeat', b, cond, line)
        if self.accept('if'):
            arms = []
            cond = self.expr()
            self.expect('then')
            arms.append((cond, self.block()))
            els = None
            while True:
                if self.accept('elseif'):
                    c = self.expr()
                    self.expect('then')
                    arms.append((c, self.block()))
                elif self.accept('else'):
                    els = self.block()
                    self.expect('end')
                    break
                else:
                    self.expect('end')
                    break
            return ('if', arms, els, line)
        if self.accept('for'):
            n1 = self.next()[1]
            if self.accept('='):
                exprs = [self.expr()]
                self.expect(',')
                exprs.append(self.expr())
                if self.accept(','):
                    exprs.append(self.expr())
                self.expect('do')
                b = self.block()
                self.expect('end')
                return ('fornum', exprs, b, line, n1)
            names = [n1]
            while self.accept(','):
                names.append(self.next()[1])
            self.expect('in')
            exprs = self.exprlist()
            self.expect('do')
            b = self.block()
            self.expect('end')
            return ('forin', exprs, b, line, names)
        if self.accept('function'):
            name = self.funcname()
            f = self.funcbody(line)
            return ('funcdef', name, f, line, False)
        if self.accept('local'):
            if self.accept('function'):
                name = self.next()[1]
                f = self.funcbody(line)
                return ('funcdef', name, f, line, True)
            names = [self.next()[1]]
            self.attrib()
            while self.accept(','):
                names.append(self.next()[1])
                self.attrib()
            exprs = []
            if self.accept('='):
                exprs = self.exprlist()
            return ('expr', exprs, line, [('name', n) for n in names], True)
        # expression statement or assignment
        e = self.suffixedexp()
        tok = self.peek()
        if tok[0] == 'op' and tok[1] in ('+=', '-=', '*=', '/='):
            self.next()
            rhs = self.expr()
            return ('expr', [('bin', tok[1][0], e, rhs)], line, [e], False)
        if self.check('=') or self.check(','):
            targets = [e]
            while self.accept(','):
                targets.append(self.suffixedexp())
            self.expect('=')
            exprs = self.exprlist()
            return ('expr', exprs + [t for t in targets if t[0] == 'index'], line, targets, False)
        return ('expr', [e], line, [], False)

    def attrib(self):
        if self.check('<'):
            self.next(); self.next(); self.expect('>')

    def funcname(self):
        parts = [self.next()[1]]
        while self.check('.') or self.check(':'):
            sep = self.next()[1]
            parts.append(sep + self.next()[1])
        return ''.join(parts[:1] + parts[1:])

    def funcbody(self, line):
        self.expect('(')
        params = []
        while not self.check(')'):
            tok = self.next()
            if tok[1] != ',':
                params.append(tok[1])
        self.expect(')')
        b = self.block()
        end_line = self.expect('end')[2]
        return ('func', b, line, params, end_line)

    def exprlist(self):
        out = [self.expr()]
        while self.accept(','):
            out.append(self.expr())
        return out

    def primaryexp(self):
        tok = self.peek()
        if tok[0] == 'name':
            self.next()
            return ('name', tok[1])
        if self.accept('('):
            e = self.expr()
            self.expect(')')
            return ('paren', e)
        raise SyntaxError(f'line {tok[2]}: unexpected {tok[1]!r}')

    def suffixedexp(self):
        e = self.primaryexp()
        while True:
            tok = self.peek()
            if self.accept('.'):
                key = self.next()[1]
                e = ('index', e, ('const', key))
            elif self.check('['):
                self.next()
                k = self.expr()
                self.expect(']')
                e = ('index', e, k)
            elif self.check(':'):
                self.next()
                meth = self.next()[1]
                args = self.callargs()
                e = ('call', dotted(e), e, args, tok[2], meth)
            elif self.check('(') or self.check('{') or tok[0] == 'str':
                args = self.callargs()
                e = ('call', dotted(e), e, args, tok[2], None)
            else:
                return e

    def callargs(self):
        tok = self.peek()
        if tok[0] == 'str':
            self.next()
            return [('const', tok[1])]
        if self.check('{'):
            return [self.table()]
        self.expect('(')
        if self.accept(')'):
            return []
        args = self.exprlist()
        self.expect(')')
        return args

    def table(self):
        self.expect('{')
        items = []
        while not self.check('}'):
            if self.check('['):
                self.next()
                k = self.expr()
                self.expect(']')
                self.expect('=')
                items.append(k)
                items.append(self.expr())
            elif self.peek()[0] == 'name' and self.peek(1)[1] == '=' and self.peek(1)[0] == 'op':
                self.next(); self.next()
                items.append(self.expr())
            else:
                items.append(self.expr())
            if not (self.accept(',') or self.accept(';')):
                break
        self.expect('}')
        return ('table', items)

    def simpleexp(self):
        tok = self.peek()
        if tok[0] in ('num', 'str'):
            self.next()
            return ('const', tok[1])
        if tok[0] == 'kw' and tok[1] in ('nil', 'true', 'false'):
            self.next()
            return ('const', tok[1])
        if self.accept('...'):
            return ('vararg',)
        if self.check('{'):
            return self.table()
        if self.accept('function'):
            return self.funcbody(tok[2])
        return self.suffixedexp()

    def expr(self, limit=0):
        tok = self.peek()
        if (tok[0] == 'kw' and tok[1] == 'not') or (tok[0] == 'op' and tok[1] in ('-', '#', '~')):
            self.next()
            e = ('un', tok[1], self.expr(UNARY_PRI))
        else:
            e = self.simpleexp()
        while True:
            tok = self.peek()
            op = tok[1] if tok[0] in ('op', 'kw') else None
            if op in BINPRI and BINPRI[op][0] > limit:
                self.next()
                r = self.expr(BINPRI[op][1])
                e = ('bin', op, e, r)
            else:
                return e


def dotted(e):
    """'a.b.c' for a name/index chain with constant keys, else None."""
    if e[0] == 'name':
        return e[1]
    if e[0] == 'index' and e[2][0] == 'const':
        base = dotted(e[1])
        return base and base + '.' + str(e[2][1]).strip('\'"')
    return None


def src_text(e):
    """Short readable form of an expression (for the report)."""
    k = e[0]
    if k == 'name':
        return e[1]
    if k == 'const':
        return str(e[1])
    if k == 'index':
        return src_text(e[1]) + ('.' + str(e[2][1]) if e[2][0] == 'const' else '[' + src_text(e[2]) + ']')
    if k == 'call':
        name = e[1] or src_text(e[2])
        if e[5]:
            name = src_text(e[2]) + ':' + e[5]
        return name + '(' + ', '.join(src_text(a) for a in e[3]) + ')'
    if k == 'bin':
        return f'{src_text(e[2])} {e[1]} {src_text(e[3])}'
    if k == 'un':
        return f'{e[1]}{" " if e[1] == "not" else ""}{src_text(e[2])}'
    if k == 'paren':
        return '(' + src_text(e[1]) + ')'
    if k == 'func':
        return 'function() ... end'
    if k == 'table':
        return '{...}'
    return '...'


# ───────────────────────────── analysis ─────────────────────────────
# A flow is (fall, brk, ret, cont): some path with no yield reaches the end of the block / a break / a return or
# error() / a goto.

NONE = (False, False, False, False)
FALL = (True, False, False, False)


def short_name(name):
    return name.split('.')[-1].split(':')[-1]


def call_name(call):
    """The dotted name of a call (obj:meth for a method call), or None."""
    if call[5]:
        return (call[1] or '?') + ':' + call[5]
    return call[1]


class Analyzer:
    def __init__(self, yielders):
        self.yielders = yielders      # names of calls that always yield ('*.x': any a.x / a:x)

    def is_yielder_name(self, name):
        if not name:
            return False
        return name in self.yielders or ('*.' + short_name(name)) in self.yielders and ('.' in name or ':' in name)

    def expr_yields(self, e):
        """True when evaluating e yields on every path."""
        k = e[0]
        if k == 'call':
            if self.expr_yields(e[2]) or any(self.expr_yields(a) for a in e[3]):
                return True
            if self.is_yielder_name(call_name(e)):
                return True
            args = e[3]
            if e[1] in INLINE_FN and args:
                if args[0][0] == 'func':
                    fall, _, ret, cont = self.block_flow(args[0][1])
                    return not fall and not ret and not cont
                if args[0][0] in ('name', 'index') and self.is_yielder_name(dotted(args[0])):
                    return True
            return False
        if k == 'bin':
            if e[1] in ('and', 'or'):
                return self.expr_yields(e[2])          # the right side may not run
            return self.expr_yields(e[2]) or self.expr_yields(e[3])
        if k == 'un':
            return self.expr_yields(e[2])
        if k == 'paren':
            return self.expr_yields(e[1])
        if k == 'index':
            return self.expr_yields(e[1]) or self.expr_yields(e[2])
        if k == 'table':
            return any(self.expr_yields(x) for x in e[1])
        return False

    def block_flow(self, stmts):
        fall, brk, ret, cont = True, False, False, False
        for s in stmts:
            if not fall:
                break
            f, b, r, c = self.stmt_flow(s)
            brk, ret, cont, fall = brk or b, ret or r, cont or c, f
        return fall, brk, ret, cont

    def stmt_flow(self, s):
        k = s[0]
        if k == 'expr':
            for e in s[1]:
                if self.expr_yields(e):
                    return NONE
                if e[0] == 'call' and e[1] in EXITS:
                    return (False, False, True, False)
            return FALL
        if k == 'return':
            if any(self.expr_yields(e) for e in s[1]):
                return NONE
            return (False, False, True, False)
        if k == 'break':
            return (False, True, False, False)
        if k == 'goto':
            return (False, False, False, True)
        if k == 'do':
            return self.block_flow(s[1])
        if k == 'funcdef':
            return FALL
        if k == 'if':
            if self.expr_yields(s[1][0][0]):
                return NONE
            fall, brk, ret, cont = s[2] is None, False, False, False
            for _, blk in s[1]:
                f, b, r, c = self.block_flow(blk)
                fall, brk, ret, cont = fall or f, brk or b, ret or r, cont or c
            if s[2] is not None:
                f, b, r, c = self.block_flow(s[2])
                fall, brk, ret, cont = fall or f, brk or b, ret or r, cont or c
            return fall, brk, ret, cont
        if k == 'while':
            if self.expr_yields(s[1]):
                return NONE
            f, b, r, c = self.block_flow(s[2])
            forever = s[1][0] == 'const' and s[1][1] == 'true'
            # it may run zero times; a break leaves it with no yield so far
            return (b or not forever), False, r, c
        if k == 'repeat':
            f, b, r, c = self.block_flow(s[1])
            round_trip = (f or c) and not self.expr_yields(s[2])
            return (b or round_trip), False, r, False
        if k in ('fornum', 'forin'):
            if any(self.expr_yields(e) for e in s[1]):
                return NONE
            f, b, r, c = self.block_flow(s[2])
            return True, False, r, c
        return FALL


def walk_exprs(e, fn):
    """Visit every expression node (function literals included, not their bodies)."""
    fn(e)
    k = e[0]
    if k == 'call':
        walk_exprs(e[2], fn)
        for a in e[3]:
            walk_exprs(a, fn)
    elif k == 'bin':
        walk_exprs(e[2], fn)
        walk_exprs(e[3], fn)
    elif k == 'un':
        walk_exprs(e[2], fn)
    elif k == 'paren':
        walk_exprs(e[1], fn)
    elif k == 'index':
        walk_exprs(e[1], fn)
        walk_exprs(e[2], fn)
    elif k == 'table':
        for x in e[1]:
            walk_exprs(x, fn)


def stmt_exprs(s):
    k = s[0]
    if k in ('expr', 'return'):
        return list(s[1])
    if k == 'if':
        return [c for c, _ in s[1]]
    if k == 'while':
        return [s[1]]
    if k == 'repeat':
        return [s[2]]
    if k in ('fornum', 'forin'):
        return list(s[1])
    return []


def walk_stmts(stmts, visit_stmt, visit_func, fn_stack=None, into_functions=True):
    """Visit every statement (and, with into_functions, every function literal / definition), recursively."""
    fn_stack = fn_stack or []
    for s in stmts:
        visit_stmt(s, fn_stack)
        k = s[0]
        if k == 'if':
            for _, blk in s[1]:
                walk_stmts(blk, visit_stmt, visit_func, fn_stack, into_functions)
            if s[2]:
                walk_stmts(s[2], visit_stmt, visit_func, fn_stack, into_functions)
        elif k == 'while':
            walk_stmts(s[2], visit_stmt, visit_func, fn_stack, into_functions)
        elif k == 'repeat':
            walk_stmts(s[1], visit_stmt, visit_func, fn_stack, into_functions)
        elif k in ('fornum', 'forin'):
            walk_stmts(s[2], visit_stmt, visit_func, fn_stack, into_functions)
        elif k == 'do':
            walk_stmts(s[1], visit_stmt, visit_func, fn_stack, into_functions)
        elif k == 'funcdef' and into_functions:
            visit_func(s[1], s[2], fn_stack)
            walk_stmts(s[2][1], visit_stmt, visit_func, fn_stack + [s[1]], into_functions)
        if not into_functions:
            continue
        for e in stmt_exprs(s):
            funcs = []
            walk_exprs(e, lambda x: funcs.append(x) if x[0] == 'func' else None)
            for f in funcs:
                visit_func(None, f, fn_stack)
                walk_stmts(f[1], visit_stmt, visit_func, fn_stack + ['<anon@%d>' % f[2]], into_functions)


def calls_in(stmts, into_functions=True):
    out = []

    def vs(s, _):
        for e in stmt_exprs(s):
            walk_exprs(e, lambda x: out.append(x) if x[0] == 'call' else None)
    walk_stmts(stmts, vs, lambda n, f, st: None, into_functions=into_functions)
    return out


def calls_of(exprs):
    out = []
    for e in exprs:
        walk_exprs(e, lambda x: out.append(x) if x[0] == 'call' else None)
    return out


def names_in(e):
    out = set()
    walk_exprs(e, lambda x: out.add(x[1]) if x[0] == 'name' else None)
    walk_exprs(e, lambda x: out.add(dotted(x)) if x[0] == 'index' and dotted(x) else None)
    return out


def assignments(stmts, unconditional=False):
    """(target dotted name, rhs or None, statement) for the assignments of a block: every one in it (nested
    blocks too, not function bodies), or with unconditional only those that run on every pass."""
    out = []

    def add(s):
        if s[0] == 'expr' and s[3]:
            rhs = s[1][:len(s[3])] if not s[4] else s[1]
            for i, t in enumerate(s[3]):
                out.append((t, rhs[i] if i < len(rhs) else None, s))

    if unconditional:
        def top(block):
            for s in block:
                add(s)
                if s[0] == 'do':
                    top(s[1])
                if s[0] in ('return', 'break', 'goto'):
                    break
        top(stmts)
    else:
        walk_stmts(stmts, lambda s, _: add(s), lambda n, f, st: None, into_functions=False)
    return out


def progress_in(stmts):
    """Names the body moves on every pass: v = <expr reading v>, X[...] = nil, table.remove(X, ...)."""
    out = set()
    for t, e, _ in assignments(stmts, unconditional=True):
        d = dotted(t)
        if d and e is not None and d in names_in(e):
            out.add(d)
        if t[0] == 'index' and e is not None and e[0] == 'const' and e[1] == 'nil':
            b = dotted(t[1])
            if b:
                out.add(b)

    def top(block):
        for s in block:
            if s[0] == 'expr':
                for c in calls_of(s[1]):
                    if c[1] == 'table.remove' and c[3] and dotted(c[3][0]):
                        out.add(dotted(c[3][0]))
            if s[0] == 'do':
                top(s[1])
            if s[0] in ('return', 'break', 'goto'):
                break
    top(stmts)
    return out


def cond_names(e):
    out = names_in(e)
    walk_exprs(e, lambda x: out.add(dotted(x[2])) if x[0] == 'un' and x[1] == '#' and dotted(x[2]) else None)
    return out


def parse_source(src):
    return Parser(tokenize(src)).block()


def parse_file(path):
    with open(path, encoding='utf-8') as f:
        return parse_source(f.read())


def collect_functions(files_ast):
    """name -> [func nodes] for every named function definition (and `X = function` assignments)."""
    defs = {}
    for ast in files_ast.values():
        def vf(name, f, _):
            if name:
                defs.setdefault(name, []).append(f)

        def vs(s, _):
            if s[0] == 'expr' and s[3]:
                for t, e in zip(s[3], s[1]):
                    if e[0] == 'func' and dotted(t):
                        defs.setdefault(dotted(t), []).append(e)
        walk_stmts(ast, vs, vf)
    return defs


def add_name(names, name):
    names.add(name)
    if '.' in name or ':' in name:
        names.add('*.' + short_name(name))    # reached through aliases too (ctx.getEntity, CP.X.y, self:y)


def compute_yielders(defs):
    yielders = set(SEED_YIELDERS)
    changed = True
    while changed:
        changed = False
        an = Analyzer(yielders)
        for name, fns in defs.items():
            if name in yielders:
                continue
            if all(not any(an.block_flow(f[1])[i] for i in (0, 2, 3)) for f in fns):
                add_name(yielders, name)
                changed = True
    return yielders


NATIVE_NAME = re.compile(r'^[A-Z][A-Za-z0-9]*$')
RUNTIME = {'Wait', 'CreateThread', 'SetTimeout', 'Await', 'Citizen'}


class GameState:
    """Which calls read game state: natives, and (in a loop condition only) functions of the files that call a
    native themselves (one level: a callee's own progress is not followed)."""

    def __init__(self, defs):
        self.defined = set()
        for name in defs:
            self.defined.add(name)
            self.defined.add(short_name(name))
        self.readers = set()
        for name, fns in defs.items():
            if any(self.natives(calls_in(f[1], into_functions=False)) for f in fns):
                self.readers.add(name)

    def is_native(self, name):
        return bool(name) and NATIVE_NAME.match(name) is not None and name not in self.defined \
            and name not in RUNTIME

    def natives(self, calls):
        return sorted({call_name(c) for c in calls if self.is_native(call_name(c))})

    def in_condition(self, calls):
        return sorted({call_name(c) for c in calls
                       if self.is_native(call_name(c)) or call_name(c) in self.readers})


def loop_findings(sources):
    """sources: {path: Lua text}. Returns (findings, errors): findings are
    (path, line, verdict, kind, condition text, where, note) with verdict HIT / bounded / pure / ok; errors are
    (path, message) for the files that did not parse (they are skipped)."""
    files_ast, errors = {}, []
    for p, text in sources.items():
        try:
            files_ast[p] = parse_source(text)
        except (SyntaxError, IndexError) as err:
            errors.append((p, str(err)))
    return scan_ast(files_ast), errors


def scan_ast(files_ast):
    defs = collect_functions(files_ast)
    an = Analyzer(compute_yielders(defs))
    gs = GameState(defs)
    results = []

    def state_of(cond, body):
        """The game state the loop waits on (names of the calls), or [] for a pure-Lua loop."""
        if cond[0] == 'const' and cond[1] == 'true':
            return gs.natives(calls_in(body, into_functions=False))
        found = gs.in_condition(calls_of([cond]))
        # a variable of the condition that the body sets from a native: obj = GetClosestObjectOfType(...)
        read = cond_names(cond)
        for t, e, _ in assignments(body):
            if e is not None and dotted(t) in read:
                found += gs.natives(calls_of([e]))
        return sorted(set(found))

    def judge(path, line, kind, cond, body, where, round_trip):
        text = src_text(cond)
        if not round_trip:
            results.append((path, line, 'ok', kind, text, where, 'every path yields or leaves the loop'))
            return
        moved = cond_names(cond) & progress_in(body)
        if moved:
            results.append((path, line, 'bounded', kind, text, where,
                            'no yield, but every pass moves ' + ', '.join(sorted(moved))))
            return
        state = state_of(cond, body)
        if state:
            results.append((path, line, 'HIT', kind, text, where,
                            'a pass can go round with no Wait while the condition waits on game state ('
                            + ', '.join(state) + ')'))
        else:
            results.append((path, line, 'pure', kind, text, where,
                            'no yield and no visible progress, but the condition reads no game state'))

    for path, ast in files_ast.items():
        def vs(s, st):
            k = s[0]
            where = st[-1] if st else '<main chunk>'
            if k == 'while':
                if an.expr_yields(s[1]):
                    results.append((path, s[3], 'ok', 'while', src_text(s[1]), where, 'the condition yields'))
                    return
                f, _, _, c = an.block_flow(s[2])
                judge(path, s[3], 'while', s[1], s[2], where, f or c)
            elif k == 'repeat':
                f, _, _, c = an.block_flow(s[1])
                judge(path, s[3], 'repeat', s[2], s[1], where, (f or c) and not an.expr_yields(s[2]))
            elif k == 'forin':
                ex = s[1]
                if not (ex and ex[0][0] == 'call' and ex[0][1] == 'ipairs' and ex[0][3]):
                    return
                t = dotted(ex[0][3][0])
                if not t:
                    return
                grows = any(c[1] == 'table.insert' and c[3] and dotted(c[3][0]) == t
                            for c in calls_in(s[2], into_functions=False))
                for tg, _, _ in assignments(s[2]):
                    if tg[0] == 'index' and dotted(tg[1]) == t and tg[2][0] == 'bin':
                        grows = True
                if grows:
                    results.append((path, s[3], 'HIT', 'ipairs', t, where,
                                    'the body appends to the table it walks, so the loop never ends'))
        walk_stmts(ast, vs, lambda n, f, st: None)
    return results


def scan(paths):
    files_ast = {}
    for p in paths:
        try:
            files_ast[p] = parse_file(p)
        except (SyntaxError, IndexError) as err:
            print(f'{p}: parse error: {err}')
    return scan_ast(files_ast)


def recursion(paths):
    """Functions that call themselves by name (direct recursion), for a manual review."""
    out = []
    for p in paths:
        try:
            ast = parse_file(p)
        except (SyntaxError, IndexError):
            continue

        def vf(name, f, _):
            if not name:
                return
            for c in calls_in(f[1], into_functions=False):
                if c[1] == name:
                    out.append((p, c[4], name))
        walk_stmts(ast, lambda s, st: None, vf)
    return out


def main(argv):
    show_all = '--all' in argv
    paths = [a for a in argv if not a.startswith('--')]
    if not paths:
        print(__doc__.strip())
        return 2
    hits = 0
    for path, line, verdict, kind, cond, where, note in sorted(scan(paths)):
        hits += verdict == 'HIT'
        if verdict != 'ok' or show_all:
            print(f'{path}:{line}: {verdict} {kind} ({cond}) in {where}: {note}')
    if show_all:
        for p, ln, name in recursion(paths):
            print(f'{p}:{ln}: RECURSION {name} calls itself')
    return 1 if hits else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))

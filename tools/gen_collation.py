#!/usr/bin/env python3
"""tools/gen_collation.py - prints the utf8mb4_general_ci tables of modules/storage/memsql.lua.

The saves folder engine compares text like MariaDB's utf8mb4_general_ci: every character of the Basic
Multilingual Plane has one weight, and LOWER() maps every character to one character. Both tables are
read from a running MariaDB (10.11) with WEIGHT_STRING and LOWER over every BMP code point, so they are
MariaDB's own tables, not a hand-written list:

    python3 tools/gen_collation.py            (uses `mysql -uroot`; set MYSQL to change the command)

and printed as runs "first,count,stride,value,step" (hex): code point first + i*stride has the value
value + i*step. Paste the two strings over GENERAL_CI_RUNS and LOWER_RUNS in memsql.lua.
tests/memsql_spec.lua checks every BMP code point against MariaDB again.
"""
import os
import subprocess
import sys

MYSQL = os.environ.get('MYSQL', 'mysql -uroot')
DB = 'cp_gen_collation_%d' % os.getpid()

QUERY = (
    "SELECT seq, HEX(WEIGHT_STRING(CONVERT(CHAR(seq USING utf32) USING utf8mb4) COLLATE utf8mb4_general_ci)), "
    "HEX(CONVERT(LOWER(CONVERT(CHAR(seq USING utf32) USING utf8mb4) COLLATE utf8mb4_general_ci) USING utf32)) "
    "FROM seq_0_to_65535 WHERE seq < 55296 OR seq > 57343"
)


def dump():
    subprocess.run('%s -e "CREATE DATABASE %s"' % (MYSQL, DB), shell=True, check=True)
    try:
        out = subprocess.run('%s -N %s -e "%s"' % (MYSQL, DB, QUERY), shell=True, check=True,
                             capture_output=True, text=True).stdout
    finally:
        subprocess.run('%s -e "DROP DATABASE %s"' % (MYSQL, DB), shell=True, check=True)
    weight, lower = {}, {}
    for line in out.splitlines():
        cp, w, lo = line.split('\t')
        weight[int(cp)] = int(w, 16)
        lower[int(cp)] = int(lo, 16)
    return weight, lower


def runs(pairs):
    out, i, n = [], 0, len(pairs)
    while i < n:
        cp, v = pairs[i]
        best = (1, 1, 0)
        for stride in (1, 2):
            for step in (0, 1, stride):
                j, k = i + 1, 1
                while j < n and pairs[j][0] == cp + k * stride and pairs[j][1] == v + k * step:
                    j += 1
                    k += 1
                if k > best[0]:
                    best = (k, stride, step)
        k, stride, step = best
        out.append('%x,%x,%x,%x,%x' % (cp, k, stride, v, step))
        i += k
    return out


def lua_string(items, per_line=8):
    lines = []
    for i in range(0, len(items), per_line):
        lines.append(' '.join(items[i:i + per_line]))
    return '[[\n' + '\n'.join(lines) + '\n]]'


def main():
    weight, lower = dump()
    if len(weight) != 63488:
        sys.exit('unexpected number of code points: %d' % len(weight))
    # ASCII is handled by the engine's own fast path (a-z -> A-Z); only U+0080 and above go in the tables
    w = sorted((c, v) for c, v in weight.items() if c >= 0x80 and v != c)
    lo = sorted((c, v) for c, v in lower.items() if c >= 0x80 and v != c)
    print('local GENERAL_CI_RUNS = ' + lua_string(runs(w)))
    print('local LOWER_RUNS = ' + lua_string(runs(lo)))


if __name__ == '__main__':
    main()

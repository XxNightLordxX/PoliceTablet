#!/usr/bin/env bash
# tools/lua_coverage/run.sh · measured Lua line coverage of the whole suite (dev tooling, not shipped). The check_all
# step lua-coverage runs it (opt-in: tools/check_all.sh lua-coverage, or CP_LUA_COVERAGE=1).
#
#   bash tools/lua_coverage/run.sh [OUTDIR]          both suites (database and files mode) under the line hook, then
#                                                    report.py: docs/dev/LUA_COVERAGE.md and the unrun-function check
#   bash tools/lua_coverage/run.sh OUTDIR --report   only the report, from the dumps already in OUTDIR/{db,files}
#
# It builds ccov.so into OUTDIR, sets LUA_INIT_5_4=@cov_init.lua (every lua5.4 process of the run, the fixture
# processes the specs start included, dumps the lines it ran into OUTDIR/<mode>) and CP_TEST_COVERAGE=1 (the
# 'under N ms' time budgets are not checked: the hook slows every line). Exit 0 only when both suites and the report
# pass. docs/dev/TESTING.md "Measured Lua coverage".
set -u -o pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT" || exit 2
OUT=${1:-}
[ -n "$OUT" ] || OUT=$(mktemp -d "${TMPDIR:-/tmp}/cp-luacov.XXXXXX")
mkdir -p "$OUT/db" "$OUT/files" || exit 2
OUT=$(cd "$OUT" && pwd)
echo "lua-coverage: dumps in $OUT"
status=0
if [ "${2:-}" != "--report" ]; then
    for c in cc lua5.4 luac5.4 python3; do
        command -v "$c" >/dev/null 2>&1 || { echo "missing command: $c"; exit 1; }
    done
    cc -O2 -shared -fPIC -o "$OUT/ccov.so" tools/lua_coverage/ccov.c ||
        { echo "lua-coverage: ccov.c did not build"; exit 1; }
    rm -f "$OUT"/db/cov_*.txt "$OUT"/files/cov_*.txt
    export CP_SPEC_TIMEOUT="${CP_SPEC_TIMEOUT:-2700}"
    export CP_COV_SO="$OUT/ccov.so" LUA_INIT_5_4="@$ROOT/tools/lua_coverage/cov_init.lua" CP_TEST_COVERAGE=1
    CP_COV_DIR="$OUT/db" lua5.4 tests/run.lua || { echo "lua-coverage: suite-db failed under the hook"; status=1; }
    CP_COV_DIR="$OUT/files" lua5.4 tests/run.lua --storage=files ||
        { echo "lua-coverage: suite-files failed under the hook"; status=1; }
    unset LUA_INIT_5_4 CP_COV_SO CP_TEST_COVERAGE
fi
python3 tools/lua_coverage/report.py "$OUT/db" "$OUT/files" || status=1
exit $status

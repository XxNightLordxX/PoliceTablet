#!/usr/bin/env bash
# tools/check_all.sh · every check of the repository in one command, in order, with a PASS/FAIL summary.
# What each step needs and how to read a failure: docs/TESTING.md.
#
#   tools/check_all.sh                    every step, in the order below
#   tools/check_all.sh suite-db tsc       only the named steps (still in the order below)
#   tools/check_all.sh --fail-fast        stop at the first failing step
#   tools/check_all.sh -v                 stream every step's output (the default on GitHub Actions)
#   tools/check_all.sh --list             list the steps
#
# Steps:
#   syntax        luac5.4 -p on every Lua file
#   contracts     python3 tools/check_contracts.py
#   lint-<name>   python3 tools/lint_<name>.py or tools/check_<name>.py (every one but check_contracts.py);
#                 today lint-fivem: tools/lint_fivem.py, the FiveM pitfall rules (known hits: tools/lint_baseline.txt)
#   style         python3 tools/restyle.py --check: fails on any file the formatter would change (docs/STYLE.md)
#   suite-db      lua5.4 tests/run.lua                    (MariaDB)
#   suite-files   lua5.4 tests/run.lua --storage=files    (database off, the saves folder engine)
#   suite-shadow  lua5.4 tests/run.lua --storage=shadow   (all three answers compared, 0 differences)
#   tsc           cd Crimson-Police/web && npx tsc --noEmit
#   build         npm run build in a scratch copy of the web sources; web/dist must equal its output
#
# The suites run 2 specs at a time (CP_TEST_JOBS=N changes it for all three, 1 = one after another).
#
# Each step's output is kept in $CHECK_LOGS/<step>.log (default: a new folder under ${TMPDIR:-/tmp}).
# Exit status: 0 every step passed, 1 a step failed, 2 usage error.

set -u -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

# the static checks first (seconds), then the suites and the web build (minutes)
ALL_STEPS=(syntax contracts)
declare -A LINT_SCRIPT=()
for f in tools/lint_*.py tools/check_*.py; do
    [ -e "$f" ] || continue
    name=${f#tools/}
    name=${name#lint_}
    name=${name#check_}
    name=${name%.py}
    [ "$f" = tools/check_contracts.py ] && continue
    [ -n "${LINT_SCRIPT[$name]:-}" ] && continue
    LINT_SCRIPT[$name]=$f
    ALL_STEPS+=("lint-$name")
done
ALL_STEPS+=(style suite-db suite-files suite-shadow tsc build)

usage() {
    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
}

VERBOSE=0
[ "${GITHUB_ACTIONS:-}" = true ] && VERBOSE=1
FAIL_FAST=0
STEPS=()
for a in "$@"; do
    case "$a" in
        -h|--help) usage; exit 0 ;;
        --list) printf '%s\n' "${ALL_STEPS[@]}"; exit 0 ;;
        -v|--verbose) VERBOSE=1 ;;
        --fail-fast) FAIL_FAST=1 ;;
        -*) echo "unknown option $a (tools/check_all.sh --help)"; exit 2 ;;
        *)
            ok=0
            for s in "${ALL_STEPS[@]}"; do [ "$s" = "$a" ] && ok=1; done
            [ "$ok" = 1 ] || { echo "unknown step '$a'; steps: ${ALL_STEPS[*]}"; exit 2; }
            STEPS+=("$a")
            ;;
    esac
done
if [ "${#STEPS[@]}" -gt 0 ]; then
    # the named steps, in the usual order
    picked=" ${STEPS[*]} "
    STEPS=()
    for s in "${ALL_STEPS[@]}"; do [[ "$picked" == *" $s "* ]] && STEPS+=("$s"); done
else
    STEPS=("${ALL_STEPS[@]}")
fi

LOGS=${CHECK_LOGS:-}
if [ -z "$LOGS" ]; then
    LOGS=$(mktemp -d "${TMPDIR:-/tmp}/cp_check.XXXXXX") || exit 2
else
    mkdir -p "$LOGS" || exit 2
fi

now() { local t=${EPOCHREALTIME:-$(date +%s)}; echo "${t/,/.}"; }
since() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }'; }
clock() {
    awk -v s="$1" 'BEGIN { s = int(s + 0.5); if (s >= 60) printf "%dm %02ds", s / 60, s % 60; else printf "%ds", s }'
}

# A missing command: say which, and where the fix is.
need() {
    local c missing=0
    for c in "$@"; do
        if ! command -v "$c" > /dev/null 2>&1; then
            echo "missing command: $c (tools/setup_test_env.sh says how to install it)"
            missing=1
        fi
    done
    return "$missing"
}

# ---- the steps: run_<step> prints its output, detail_<step> <log> sums it up in one line ----

run_syntax() {
    need luac5.4 || return 1
    local f n=0 bad=0
    while IFS= read -r -d '' f; do
        n=$((n + 1))
        luac5.4 -p "$f" || bad=$((bad + 1))
    done < <(find Crimson-Police tests tools -name '*.lua' -not -path '*/node_modules/*' -print0 | LC_ALL=C sort -z)
    echo "luac5.4 -p: $n files, $bad with a syntax error"
    [ "$n" -gt 0 ] && [ "$bad" -eq 0 ]
}
detail_syntax() {
    sed -n -e 's/^luac5.4 -p: \([0-9]*\) files, 0 with.*/\1 Lua files/p' \
        -e 's/^luac5.4 -p: \([0-9]*\) files, \([0-9]*\) with.*/\2 of \1 files do not parse/p' "$1" | tail -1
}

run_contracts() {
    need python3 || return 1
    python3 tools/check_contracts.py
}
detail_contracts() {
    sed -n 's/^TOTAL problems: \(.*\)/\1 problems/p' "$1" | tail -1
}

# The formatter in check mode: it restyles a scratch copy (never the tree) and names each file that differs.
# It needs StyLua 2.5.2 and Prettier 3.9.9 (npx), docs/STYLE.md "Keeping the style".
run_style() {
    need python3 || return 1
    python3 tools/restyle.py --check && echo "style: every file is formatted"
}
detail_style() {
    local n
    n=$(grep -c ' would change$' "$1")
    if [ "$n" -gt 0 ]; then
        echo "$n files not formatted: run python3 tools/restyle.py"
    else
        grep -m1 -E '^style: every file|not found|^restyle: |missing' "$1"
    fi
}

run_suite() {
    need lua5.4 || return 1
    lua5.4 tests/run.lua "$@"
}
run_suite-db() { run_suite; }
run_suite-files() { run_suite --storage=files; }
run_suite-shadow() { run_suite --storage=shadow; }
detail_suite() {
    local sum diffs
    sum=$(sed -nE 's/^([0-9]+) specs, ([0-9]+) assertions passed, (.*) \(storage: .*/\1 specs, \2 passed, \3/p' "$1")
    sum=$(echo "$sum" | tail -1)
    diffs=$(sed -n 's/^shadow: .* \([0-9]*\) differences.*/\1 differences/p' "$1" | tail -1)
    if [ -z "$sum" ]; then
        sum=$(grep -m1 -E 'cannot start|could not build|no spec' "$1")
    fi
    echo "$sum${diffs:+, $diffs}"
}
detail_suite-db() { detail_suite "$1"; }
detail_suite-files() { detail_suite "$1"; }
detail_suite-shadow() { detail_suite "$1"; }

web_ready() {
    need node npm npx || return 1
    local t
    for t in tsc vite; do
        if [ ! -e "Crimson-Police/web/node_modules/.bin/$t" ]; then
            echo "Crimson-Police/web/node_modules has no $t: run (cd Crimson-Police/web && npm ci)"
            return 1
        fi
    done
}

run_tsc() {
    web_ready || return 1
    # --no-install: without node_modules, plain npx runs any global tsc or fetches the unrelated 'tsc' package.
    (cd Crimson-Police/web && npx --no-install tsc --noEmit) && echo "tsc: no errors"
}
detail_tsc() {
    local n
    n=$(grep -c 'error TS' "$1")
    if [ "$n" -gt 0 ]; then echo "$n type errors"; else grep -m1 -E '^tsc: no errors|missing|no tsc' "$1"; fi
}

# npm run build (tsc, vite build, build-stamp.mjs) in a scratch copy of web/ and locales/parts (everything the
# bundle reads), with its own copy of node_modules (vite writes node_modules/.vite-temp), so the working tree
# is never written. A fresh build is byte-identical for the same sources, so any difference means web/dist
# was not rebuilt (or was edited by hand) after a change to what it is built from.
run_build() {
    web_ready || return 1
    need tar diff || return 1
    local tmp="$LOGS/build" web
    rm -rf "$tmp"
    web="$tmp/Crimson-Police/web"
    mkdir -p "$web/node_modules" "$tmp/Crimson-Police/locales" || return 1
    tar -C Crimson-Police/web --exclude=./node_modules --exclude=./dist -cf - . | tar -C "$web" -xf - || return 1
    cp -a Crimson-Police/locales/parts "$tmp/Crimson-Police/locales/" || return 1
    cp -a "$(readlink -f Crimson-Police/web/node_modules)/." "$web/node_modules/" || return 1
    (cd "$web" && npm run build) || { echo "npm run build failed"; return 1; }
    if diff -r -q "$web/dist" Crimson-Police/web/dist; then
        echo "web/dist is up to date: identical to a fresh build"
        rm -rf "$tmp"
        return 0
    fi
    rm -rf "$web/node_modules"
    echo "web/dist is not the build of the current sources: run (cd Crimson-Police/web && npm run build) and commit"
    echo "Crimson-Police/web/dist (the fresh build is kept in $web/dist)"
    return 1
}
detail_build() {
    local n
    n=$(grep -c -E '^(Only in|Files) ' "$1")
    if grep -q '^web/dist is up to date' "$1"; then
        echo "web/dist is up to date"
    elif [ "$n" -gt 0 ]; then
        echo "web/dist is stale: $n files differ from a fresh build"
    else
        grep -m1 -E 'npm run build failed|missing|no (tsc|vite)' "$1"
    fi
}

run_lint() {
    need python3 || return 1
    python3 "${LINT_SCRIPT[$1]}"
}
detail_lint() {
    tail -1 "$1" | cut -c1-80
}

# ---- run them ----

T0=$(now)
RESULTS=()
FAILED=0
i=0
for step in "${STEPS[@]}"; do
    i=$((i + 1))
    log="$LOGS/$step.log"
    case "$step" in
        lint-*) runner=(run_lint "${step#lint-}"); detailer=detail_lint ;;
        *) runner=("run_$step"); detailer="detail_$step" ;;
    esac
    printf '[%d/%d] %-13s ' "$i" "${#STEPS[@]}" "$step"
    t=$(now)
    if [ "$VERBOSE" = 1 ]; then
        echo
        [ "${GITHUB_ACTIONS:-}" = true ] && echo "::group::$step"
        "${runner[@]}" 2>&1 | tee "$log"
        rc=${PIPESTATUS[0]}
        [ "${GITHUB_ACTIONS:-}" = true ] && echo "::endgroup::"
    else
        "${runner[@]}" > "$log" 2>&1
        rc=$?
    fi
    secs=$(since "$t")
    detail=$("$detailer" "$log" 2>/dev/null)
    if [ "$rc" -eq 0 ]; then status=PASS; else status=FAIL; FAILED=$((FAILED + 1)); fi
    [ "$VERBOSE" = 1 ] && printf '[%d/%d] %-13s ' "$i" "${#STEPS[@]}" "$step"
    printf '%s  %7ss  %s\n' "$status" "$secs" "$detail"
    RESULTS+=("$status|$step|$secs|$detail")
    if [ "$rc" -ne 0 ]; then
        if [ "$VERBOSE" = 0 ]; then
            # the lines that say what failed (or the end of the log), the whole log is in $log
            echo "      ---- $log"
            hits=$(grep -E '^✗|  FAIL |^ERROR|cannot start|could not|missing|^  - |^luac5.4: |error TS|: FX[0-9]+ |: stale: | would change$|^restyle: |not found: ' "$log"
                grep -E '^Only in|^Files ' "$log")
            if [ -n "$hits" ]; then echo "$hits" | head -40; else tail -20 "$log"; fi | sed 's/^/      /'
        fi
        [ "${GITHUB_ACTIONS:-}" = true ] && echo "::error title=check_all $step::${detail:-failed} (log: $log)"
        [ "$FAIL_FAST" = 1 ] && break
    fi
done

TOTAL=$(since "$T0")
echo
echo "SUMMARY"
for r in "${RESULTS[@]}"; do
    IFS='|' read -r status step secs detail <<< "$r"
    printf '  %s  %-13s %7ss  %s\n' "$status" "$step" "$secs" "$detail"
done
skipped=$(( ${#STEPS[@]} - ${#RESULTS[@]} ))
[ "$skipped" -gt 0 ] && echo "  (--fail-fast: $skipped step(s) not run)"
passed=$(( ${#RESULTS[@]} - FAILED ))
if [ "$FAILED" -eq 0 ]; then verdict=PASS; else verdict=FAIL; fi
echo "$verdict: $passed passed, $FAILED failed in $(clock "$TOTAL") (logs: $LOGS)"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo "### tools/check_all.sh: $verdict in $(clock "$TOTAL")"
        echo
        echo "| | step | time | result |"
        echo "|---|---|---:|---|"
        for r in "${RESULTS[@]}"; do
            IFS='|' read -r status step secs detail <<< "$r"
            echo "| $status | $step | ${secs} s | $detail |"
        done
    } >> "$GITHUB_STEP_SUMMARY"
fi

[ "$FAILED" -eq 0 ]

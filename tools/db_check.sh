#!/usr/bin/env bash
# tools/db_check.sh · the real database check: Crimson-Police's migrations and SQL on a throwaway MariaDB server.
# docs/dev/TESTING.md "Real database check" says what each line checks and how to read a failure.
#
#   tools/db_check.sh                 every check, with the statements a set of specs send (about 10 minutes)
#   tools/db_check.sh --quick         without the specs: the statements written in the code only (about 1 minute)
#   tools/db_check.sh --out FILE      also write the report to FILE (tools/db_check_result.txt is the last run kept
#                                     in the repository)
#
# It makes its own server: mariadb-install-db on a new temporary data folder, mariadbd on its own socket with no
# TCP port, stopped and deleted on exit. It never reaches the local server, cp_test or cp_boot.
# The checks (tools/db_check.lua): every migration through the real runner on a utf8mb4, a latin1, a utf8mb3 and
# a MyISAM-default database, each file twice; InnoDB and utf8mb4 everywhere; every "insert once" target has a unique
# key; every query PREPAREs (with and without ONLY_FULL_GROUP_BY); no column name needs quoting; sample writes
# round-trip. Exit status: 0 every check passed, 1 a check failed, 2 the server could not be set up.

set -u -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

QUICK=0
OUT=
while [ $# -gt 0 ]; do
    case "$1" in
        --quick) QUICK=1 ;;
        --out) OUT=${2:-}; [ -n "$OUT" ] || { echo "--out needs a file"; exit 2; }; shift ;;
        -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option $1 (tools/db_check.sh --help)"; exit 2 ;;
    esac
    shift
done

# The specs whose statements are captured (CP_SQL_LOG): together they send every kind of query the resource has.
SPECS=(workflows_full workflows_admin workflows_supervisor workflows_officer admin_control_e2e /e2e_spec admin_lists
    admin_economy workflows_system_db storage_copy realsuspects_e2e)

for c in mariadb-install-db mariadbd mariadb mariadb-admin lua5.4; do
    command -v "$c" > /dev/null 2>&1 || { echo "missing command: $c (apt-get install mariadb-server lua5.4)"; exit 2; }
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/cp_dbcheck.XXXXXX") || exit 2
# a socket path holds at most 107 bytes: a short folder of its own, whatever TMPDIR is
SOCKDIR=$(mktemp -d /tmp/cpdb.XXXXXX) || exit 2
SOCK=$SOCKDIR/s
PID=
cleanup() {
    if [ -n "$PID" ]; then
        mariadb-admin --no-defaults -S "$SOCK" -uroot shutdown > /dev/null 2>&1 || kill "$PID" 2> /dev/null
        for _ in $(seq 1 60); do kill -0 "$PID" 2> /dev/null || break; sleep 0.5; done
        kill -9 "$PID" 2> /dev/null
    fi
    rm -rf "$WORK" "$SOCKDIR"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

USER_NAME=$(id -un)
if ! mariadb-install-db --no-defaults --datadir="$WORK/data" --user="$USER_NAME" \
    --auth-root-authentication-method=normal --skip-test-db > "$WORK/install.log" 2>&1; then
    echo "mariadb-install-db failed:"; tail -20 "$WORK/install.log"; exit 2
fi
# UTC, as the specs run; mariadbd refuses to run as root unless told to
TZ=UTC mariadbd --no-defaults --datadir="$WORK/data" --socket="$SOCK" --skip-networking --user="$USER_NAME" \
    --pid-file="$WORK/mariadbd.pid" --log-error="$WORK/err.log" --innodb-buffer-pool-size=64M \
    --max-allowed-packet=16M > /dev/null 2>&1 &
PID=$!
up=0
for _ in $(seq 1 120); do
    if mariadb-admin --no-defaults -S "$SOCK" -uroot ping > /dev/null 2>&1; then up=1; break; fi
    kill -0 "$PID" 2> /dev/null || break
    sleep 0.5
done
if [ "$up" != 1 ]; then echo "the throwaway MariaDB server did not start:"; tail -20 "$WORK/err.log"; exit 2; fi

report() { if [ -n "$OUT" ]; then tee -a "$OUT"; else cat; fi; }
[ -n "$OUT" ] && : > "$OUT"
{
    echo "tools/db_check.sh on $(mariadb --no-defaults -S "$SOCK" -uroot -N -e 'SELECT VERSION()')" \
        "(at $(git -C "$ROOT" describe --always --dirty 2> /dev/null || echo "no git"))"
} | report

RUNTIME=
if [ "$QUICK" = 0 ]; then
    RUNTIME=$WORK/sqllog
    mkdir -p "$RUNTIME"
    for s in "${SPECS[@]}"; do
        log="$WORK/spec_${s//\//}.log"
        # the harness's mysql CLI reaches this server through MYSQL_UNIX_PORT, never the local one
        if env -u MYSQL_HOST -u MYSQL_TCP_PORT -u MYSQL_PWD -u CP_TEST_DB -u CP_TEST_STORAGE \
            MYSQL_UNIX_PORT="$SOCK" CP_SQL_LOG="$RUNTIME/" CP_TEST_JOBS=1 \
            timeout 1200 lua5.4 tests/run.lua "$s" > "$log" 2>&1; then
            echo "PASS  spec ${s#/} ($(grep -m1 -oE '[0-9]+ assertions passed' "$log"), statements captured)" | report
        else
            echo "FAIL  spec ${s#/}: $(tail -3 "$log" | tr '\n' ' ' | cut -c1-200)" | report
            echo "spec failed" > "$WORK/spec_failed"
        fi
    done
fi

lua5.4 tools/db_check.lua "$SOCK" ${RUNTIME:+"$RUNTIME"} 2>&1 | report
rc=${PIPESTATUS[0]}
[ -e "$WORK/spec_failed" ] && [ "$rc" = 0 ] && rc=1
if [ "$rc" = 0 ]; then
    echo "db_check: PASS" | report
elif [ -e "$WORK/spec_failed" ]; then
    echo "db_check: FAIL (a spec whose statements are captured failed: its own log says why)" | report
else
    echo "db_check: FAIL" | report
fi
exit "$rc"

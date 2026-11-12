#!/usr/bin/env bash
# tools/boot_smoke.sh · boots a real FXServer headless with Crimson-Police for a while and says PASS or FAIL.
# How to run it on your own machine: docs/dev/TESTING.md, "Real server boot test".
#
#   tools/boot_smoke.sh --data DIR [options]     boot the server-data folder DIR (its server.cfg as it is)
#   tools/boot_smoke.sh --resources DIR [opts]   boot a scratch server-data whose resources folder is DIR, with the
#                                                server.cfg of --write-cfg (TCP only, the deps it finds in DIR)
#   tools/boot_smoke.sh --check LOG              only read a console log of an earlier boot and say PASS or FAIL
#   tools/boot_smoke.sh --write-cfg FILE         write the minimal server.cfg of the test (no key, no password)
#   tools/boot_smoke.sh --mask                   copy stdin to stdout with license keys masked
#
# Options of a boot:
#   --fx DIR           the FXServer artifact folder (run.sh on Linux, FXServer.exe on Windows). Default: $CP_FX_DIR
#   --cfg NAME         the server.cfg to exec, relative to the server-data folder (default server.cfg)
#   --seconds N        how long the server runs (default 120); the console commands get extra time when needed
#   --admin-check      type `CrimsonPoliceAdmin check` in the console once the start-up check has printed
#   --restart          type `restart Crimson-Police` after that, and check the second start the same way
#   --cmd 'TEXT'       type any other console command after those (can be given more than once)
#   --crimson DIR      copy this Crimson-Police folder into the test folder of tools/boot_smoke_setup.sh first
#                      (its saves folder is kept; refused on any other server-data)
#   --log FILE         where the console log goes (default: a new file in ${TMPDIR:-/tmp})
#
# The license key is read from $CP_FX_LICENSE_KEY and handed over with +set on the command line, never written to
# a file. $CP_FX_MYSQL, when set, is handed over the same way as mysql_connection_string. The log masks both.
#
# FAIL when: a SCRIPT ERROR, Error parsing, Failed to load or Couldn't start line names Crimson-Police; a
# "server thread hitch" line shows up while Crimson-Police starts (from its script environment to the first line
# of another resource after its start-up check); a start of Crimson-Police has no "at version" (migrations) or
# "missions loaded" line; Crimson-Police starts fewer times than asked; `CrimsonPoliceAdmin check` printed no
# "Check:" answer; the server refused its license key.
# Exit status: 0 PASS, 1 FAIL, 2 usage error or the server could not be started.

set -u -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MARK=.cp_boot_smoke

usage() {
    sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
}

die() {
    echo "boot_smoke: $*" >&2
    exit 2
}

# stdin to stdout, line by line (the log is read while the server writes it), with the key and every cfxk_ value
# masked; the mysql connection string of $CP_FX_MYSQL too.
mask() {
    awk '
        function cut(s, k,    i) {
            if (k == "") return s
            while ((i = index(s, k)) > 0) s = substr(s, 1, i - 1) "[masked]" substr(s, i + length(k))
            return s
        }
        {
            line = cut($0, ENVIRON["CP_FX_LICENSE_KEY"])
            line = cut(line, ENVIRON["CP_FX_MYSQL"])
            gsub(/cfxk_[A-Za-z0-9_-]+/, "cfxk_[masked]", line)
            print line
            fflush()
        }
    '
}

# The minimal server.cfg: TCP only (some containers cannot bind UDP), no key and no password in it.
write_cfg() {
    local out=$1 res=${2:-} dep
    {
        echo '# The Crimson-Police boot test (tools/boot_smoke.sh). The license key and the mysql connection string'
        echo '# are handed over on the command line from CP_FX_LICENSE_KEY and CP_FX_MYSQL, never written here.'
        echo 'set inventory:framework "qbx"'
        echo 'setr inventory:framework "qbx"'
        echo 'set qbx:acknowledge true'
        echo 'sv_lan 1'
        echo 'sv_master1 ""'
        echo 'endpoint_add_tcp "0.0.0.0:30125"'
        echo 'sv_hostname "Crimson-Police boot test"'
        echo 'sv_maxclients 8'
        echo 'set onesync on'
        echo 'set ox:locale en'
        echo 'setr ox:locale en'
        for dep in oxmysql require ox_lib qbx_core ox_target qbx_vehicles ox_inventory; do
            if [ -z "$res" ] || [ -n "$(find_resource "$res" "$dep")" ]; then echo "ensure $dep"; fi
        done
        echo 'ensure Crimson-Police'
    } > "$out"
}

# The folder of resource $2 anywhere under $1 (the [category] folders included), or nothing.
find_resource() {
    find -L "$1" -maxdepth 3 -type f -name fxmanifest.lua -path "*/$2/fxmanifest.lua" 2> /dev/null | head -1
}

# ---- the log check ----

# Reads a console log (ANSI colours and all) and prints one line per problem, then PASS or FAIL.
check_log() {
    [ -r "$1" ] || die "cannot read $1"
    awk '
        function fail(why, line) {
            problems++
            if (length(line) > 220) line = substr(line, 1, 220) "..."
            print "  FAIL  " why (line != "" ? ": " line : "")
        }
        function close_start() {
            if (!open) return
            if (!mig) fail("start " starts " of Crimson-Police has no migrations line (\"... at version N\")", "")
            if (!mis) fail("start " starts " of Crimson-Police has no \"missions loaded\" line", "")
            open = 0
        }
        {
            line = $0
            gsub(/\r/, "", line)
            gsub(/\033\[[0-9;]*m/, "", line)
            cp = index(line, "Crimson-Polic") > 0
            hitch = index(line, "server thread hitch warning") > 0

            if (line ~ /^\[boot_smoke\] sent: /) {
                cmd = substr(line, 20)
                if (cmd ~ /^CrimsonPoliceAdmin check/) want_check++
                if (cmd ~ /^(restart|ensure) Crimson-Police$/) want_starts++
                print "  info  " line
                next
            }
            if (line ~ /does not have a license key|license key authentication failed|Invalid license key/) {
                fail("the server did not accept its license key (CP_FX_LICENSE_KEY)", line)
            }
            if (cp && line ~ /SCRIPT ERROR|Error parsing|Failed to load|Couldn.t (start|load) resource/) {
                fail("Crimson-Police error", line)
            }
            if (line ~ /Stopping resource Crimson-Police$/) {
                close_start()
                window = 0
            }
            if (line ~ /Creating script environments for Crimson-Police$/ || line ~ /Started resource Crimson-Police$/) {
                if (!window) { window = 1; closing = 0 }
            }
            if (line ~ /Started resource Crimson-Police$/) {
                close_start()
                starts++
                open = 1; mig = 0; mis = 0
            }
            if (open && cp && line ~ /Crimson-Police (database|saves folder) at version [0-9]+/) mig = 1
            if (open && cp && line ~ /missions loaded: [0-9]+ built-in/) mis = 1
            if (want_check && line ~ /Check: [0-9]+ OK, [0-9]+ warnings, [0-9]+ errors/) got_check++

            # the hitch window: from the script environment to the first line of another resource after the start-up
            # check (Crimson-Police still prints its integration lines then), at most 12 lines after it
            if (window && hitch) fail("server thread hitch while Crimson-Police starts", line)
            if (window && closing && !hitch && line !~ /^[ \t]*$/ && (!cp || ++closing > 13)) window = 0
            if (window && cp && index(line, "Start-up check: ") > 0) {
                closing = 1
                sub(/^.*Start-up check: /, "Start-up check: ", line)
                print "  info  " line
            }
        }
        END {
            close_start()
            if (starts == 0) fail("Crimson-Police never started (no \"Started resource Crimson-Police\" line)", "")
            else if (starts < 1 + want_starts)
                fail("Crimson-Police started " starts " time(s), " (1 + want_starts) " asked", "")
            if (got_check < want_check) fail("CrimsonPoliceAdmin check printed no \"Check:\" answer", "")
            print "  info  Crimson-Police started " (starts + 0) " time(s)"
            if (problems) { print "FAIL: " problems " problem(s)"; exit 1 }
            print "PASS"
        }
    ' "$1"
}

# ---- the boot ----

FX=${CP_FX_DIR:-}
DATA=
RES=
CFG=server.cfg
SECONDS_RUN=120
ADMIN_CHECK=0
RESTART=0
CMDS=()
CRIMSON=
LOG=

[ $# -gt 0 ] || { usage; exit 2; }
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --check) [ $# -ge 2 ] || die "--check needs a log file"; check_log "$2"; exit $? ;;
        --write-cfg) [ $# -ge 2 ] || die "--write-cfg needs a file"; write_cfg "$2" "${3:-}"; exit $? ;;
        --mask) mask; exit 0 ;;
        --fx) FX=${2:-}; shift ;;
        --data) DATA=${2:-}; shift ;;
        --resources) RES=${2:-}; shift ;;
        --cfg) CFG=${2:-}; shift ;;
        --seconds) SECONDS_RUN=${2:-}; shift ;;
        --admin-check) ADMIN_CHECK=1 ;;
        --restart) RESTART=1 ;;
        --cmd) CMDS+=("${2:-}"); shift ;;
        --crimson) CRIMSON=${2:-}; shift ;;
        --log) LOG=${2:-}; shift ;;
        *) die "unknown option $1 (tools/boot_smoke.sh --help)" ;;
    esac
    shift
done

[ -n "${CP_FX_LICENSE_KEY:-}" ] || die "set CP_FX_LICENSE_KEY to your key from portal.cfx.re (export CP_FX_LICENSE_KEY=...)"
[[ "$SECONDS_RUN" =~ ^[0-9]+$ ]] || die "--seconds needs a number"
[ -n "$FX" ] || die "--fx DIR (or CP_FX_DIR) names the FXServer artifact folder"
if [ -x "$FX/run.sh" ]; then
    RUN=("$FX/run.sh")
elif [ -f "$FX/FXServer.exe" ]; then
    RUN=("$FX/FXServer.exe")
else
    die "$FX has no run.sh or FXServer.exe (tools/boot_smoke_setup.sh fetches the recommended build)"
fi

SCRATCH=
if [ -n "$RES" ]; then
    [ -z "$DATA" ] || die "give --data or --resources, not both"
    [ -d "$RES" ] || die "no folder $RES"
    [ -n "$(find_resource "$RES" Crimson-Police)" ] || die "$RES has no Crimson-Police folder"
    SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/cp_boot.XXXXXX") || exit 2
    ln -s "$(cd "$RES" && pwd)" "$SCRATCH/resources"
    write_cfg "$SCRATCH/server.cfg" "$RES"
    DATA=$SCRATCH
    CFG=server.cfg
fi
[ -n "$DATA" ] || die "--data DIR (a server-data folder) or --resources DIR is needed"
[ -d "$DATA" ] || die "no folder $DATA"
DATA=$(cd "$DATA" && pwd)
[ -f "$DATA/$CFG" ] || die "$DATA has no $CFG"

if [ -n "$CRIMSON" ]; then
    [ -f "$DATA/$MARK" ] || die "--crimson only copies into a test folder of tools/boot_smoke_setup.sh ($DATA/$MARK)"
    [ -f "$CRIMSON/fxmanifest.lua" ] || die "$CRIMSON is not the Crimson-Police folder"
    dest="$DATA/resources/[crimson]/Crimson-Police"
    mkdir -p "$dest"
    find "$dest" -mindepth 1 -maxdepth 1 ! -name saves -exec rm -rf {} +
    tar -C "$CRIMSON" --exclude=./web/node_modules --exclude=./saves -cf - . | tar -C "$dest" -xf - || exit 2
    # FXServer cannot create folders on Linux: the saves folder and its two subfolders must exist
    mkdir -p "$dest/saves/_backups" "$dest/saves/exports"
    echo "boot_smoke: copied $CRIMSON into $dest (its saves folder kept)"
fi

if [ -z "$LOG" ]; then
    LOG=$(mktemp "${TMPDIR:-/tmp}/cp_boot.XXXXXX.log") || exit 2
fi
: > "$LOG" || die "cannot write $LOG"

ARGS=(+set sv_licenseKey "$CP_FX_LICENSE_KEY")
[ -n "${CP_FX_MYSQL:-}" ] && ARGS+=(+set mysql_connection_string "$CP_FX_MYSQL")
ARGS+=(+exec "$CFG")

FIFO=$(mktemp -u "${TMPDIR:-/tmp}/cp_boot_in.XXXXXX")
mkfifo "$FIFO" || die "cannot make $FIFO"
PID=

stop_server() {
    if [ -n "$PID" ] && kill -0 "$PID" 2> /dev/null; then
        kill -TERM "$PID" 2> /dev/null
        for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$PID" 2> /dev/null || break; sleep 1; done
        kill -KILL "$PID" 2> /dev/null
    fi
    exec 3>&- 2> /dev/null
    rm -f "$FIFO"
    [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
    PID=
}
trap 'stop_server; exit 130' INT TERM
trap '' PIPE
trap stop_server EXIT

(cd "$DATA" && exec "${RUN[@]}" "${ARGS[@]}" < "$FIFO" > >(mask >> "$LOG") 2>&1) &
PID=$!
exec 3> "$FIFO"
echo "boot_smoke: FXServer started in $DATA for ${SECONDS_RUN}s, console log $LOG"

T0=$(date +%s)
elapsed() { echo $(($(date +%s) - T0)); }
alive() { kill -0 "$PID" 2> /dev/null; }

# Waits until the log has a line matching $1 after line $2, the server stopped, or $3 seconds went by.
wait_for() {
    local pattern=$1 from=$2 limit=$3 t
    t=$(date +%s)
    while alive && [ $(($(date +%s) - t)) -lt "$limit" ]; do
        if tail -n +"$((from + 1))" "$LOG" | sed 's/\x1b\[[0-9;]*m//g' | grep -q -E "$pattern"; then return 0; fi
        sleep 1
    done
    return 1
}

send() {
    alive || return 1
    echo "[boot_smoke] sent: $1" >> "$LOG"
    printf '%s\n' "$1" >&3
}

QUEUE=()
[ "$ADMIN_CHECK" = 1 ] && QUEUE+=("CrimsonPoliceAdmin check")
[ "$RESTART" = 1 ] && QUEUE+=("restart Crimson-Police")
QUEUE+=("${CMDS[@]}")

if [ "${#QUEUE[@]}" -gt 0 ]; then
    # the commands wait for the first start-up check (or half the run)
    wait_for 'Start-up check: ' 0 "$((SECONDS_RUN / 2 + 1))" && sleep 3
    for c in "${QUEUE[@]}"; do
        n=$(wc -l < "$LOG")
        send "$c" || break
        case "$c" in
            "CrimsonPoliceAdmin check"*) wait_for 'Check: [0-9]+ OK' "$n" 20 ;;
            "restart Crimson-Police"|"ensure Crimson-Police") wait_for 'Start-up check: ' "$n" 60 && sleep 3 ;;
            *) sleep 5 ;;
        esac
    done
fi
while alive && [ "$(elapsed)" -lt "$SECONDS_RUN" ]; do sleep 1; done

if alive; then
    send quit
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do alive || break; sleep 1; done
else
    echo "boot_smoke: the server stopped by itself after $(elapsed)s"
fi
stop_server
wait 2> /dev/null
sleep 1 # the masking reader writes the last lines

echo "boot_smoke: $(wc -l < "$LOG") console lines in $LOG"
check_log "$LOG"
exit $?

#!/usr/bin/env bash
# tools/setup_test_env.sh · checks what tools/check_all.sh needs on Debian/Ubuntu, and installs it on request.
# Safe to run again and again: it only changes what is missing. docs/TESTING.md explains every line.
#
#   tools/setup_test_env.sh                   check only: one line per requirement, the fix for each problem
#   tools/setup_test_env.sh --install         also install what is missing: apt packages, Node.js 22 from
#                                             NodeSource, npm ci in Crimson-Police/web and tests/shadow, StyLua
#                                             (release binary), and start the local MariaDB server
#   tools/setup_test_env.sh --root-no-password
#                                             (with --install) let every local user in as MariaDB root without
#                                             a password, which the harness needs (a test machine only)
#   tools/setup_test_env.sh --clean           drop leftover cp_test_* databases and /tmp files of test runs
#
# The MariaDB server is found the way the mysql CLI finds it: the local socket, or MYSQL_HOST, MYSQL_TCP_PORT,
# MYSQL_UNIX_PORT and MYSQL_PWD (tests/shadow/twin.cjs reads the same variables).
# Exit status: 0 everything needed is there, 1 something is missing, 2 usage error.

set -u -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT" || exit 2

INSTALL=0
ROOT_NO_PASSWORD=0
CLEAN=0
for a in "$@"; do
    case "$a" in
        --install) INSTALL=1 ;;
        --root-no-password) ROOT_NO_PASSWORD=1 ;;
        --clean) CLEAN=1 ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option $a (tools/setup_test_env.sh --help)"; exit 2 ;;
    esac
done

# The versions the suite is known to pass with (docs/TESTING.md) and CI pins.
MARIADB_SERIES=10.11
NODE_MAJOR=22
NODE_FLOOR=18   # vite 6: ^18 || ^20 || >=22
NODESOURCE=https://deb.nodesource.com
NODE_FIX="install Node.js $NODE_MAJOR (--install uses NodeSource; or nvm install $NODE_MAJOR)"
# the formatters of the style step (docs/STYLE.md pins them: another version may lay the code out differently)
STYLUA_VERSION=2.5.2
PRETTIER_VERSION=3.9.9

PROBLEMS=0
WARNINGS=0
ok() { printf '  ok    %-22s %s\n' "$1" "$2"; }
warn() { printf '  warn  %-22s %s\n' "$1" "$2"; WARNINGS=$((WARNINGS + 1)); }
bad() { printf '  FAIL  %-22s %s\n' "$1" "$2"; PROBLEMS=$((PROBLEMS + 1)); }
fix() { printf '        %-22s fix: %s\n' '' "$1"; }
has() { command -v "$1" > /dev/null 2>&1; }

SUDO=()
if [ "$(id -u)" -ne 0 ]; then
    if has sudo; then SUDO=(sudo); fi
fi
as_root() {
    if [ "$(id -u)" -ne 0 ] && [ "${#SUDO[@]}" -eq 0 ]; then
        echo "  cannot run as root (no sudo): $*"
        return 1
    fi
    "${SUDO[@]}" "$@"
}

APT_UPDATED=0
apt_install() {
    has apt-get || { echo "  no apt-get: install $* with your package manager"; return 1; }
    if [ "$APT_UPDATED" = 0 ]; then
        as_root apt-get update -q || return 1
        APT_UPDATED=1
    fi
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends "$@"
}

# version_ge 10.11.14 10.11 -> true when $1 >= $2 (dotted numbers)
version_ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1)" = "$2" ]
}

mysql_root() { mysql -uroot -N -B "$@" 2>&1; }

# ---- --clean: leftovers of interrupted runs ----
if [ "$CLEAN" = 1 ]; then
    if pgrep -f 'tests/run\.lua' > /dev/null 2>&1; then
        echo "a tests/run.lua is running: --clean would drop its databases; try again when it has finished"
        exit 1
    fi
    dbs=$(mysql_root -e "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 'cp\\_test%'") || {
        echo "cannot reach MariaDB: $dbs"; exit 1; }
    n=0
    for db in $dbs; do mysql -uroot -e "DROP DATABASE IF EXISTS \`$db\`" && n=$((n + 1)); done
    echo "dropped $n cp_test* databases"
    # /tmp/lua_* folders that hold a saves folder of a test run (os.tmpname() of tests/run.lua and the harness)
    m=0
    for d in /tmp/lua_*; do
        [ -d "$d" ] || continue
        # a run's own folder holds cp_test_* saves folders or one numbered folder per spec (database mode); the
        # --jobs folder of tests/run.lua holds <n>.sql, <n>.sh and <n>.out
        ours=0
        [ -z "$(ls -A "$d")" ] && ours=1
        for f in "$d"/*; do
            [[ ${f##*/} =~ ^(cp_test|[0-9]+(\.(sql|sh|out))?$) ]] && ours=1
        done
        if [ "$ours" = 1 ]; then rm -rf "$d" && m=$((m + 1)); fi
    done
    echo "removed $m /tmp/lua_* folders of test runs"
    rm -f /tmp/cp_shadow_*.jsonl /tmp/cp_shadow_*.jsonl.stats
    echo "removed the shadow reports /tmp/cp_shadow_*.jsonl"
    exit 0
fi

echo "Crimson-Police test environment ($ROOT)"

# ---- system ----
os="unknown"
if [ -r /etc/os-release ]; then
    os=$(. /etc/os-release; echo "${PRETTY_NAME:-$ID}")
    like=$(. /etc/os-release; echo "${ID:-} ${ID_LIKE:-}")
    case " $like " in
        *" debian "*|*" ubuntu "*) ok system "$os" ;;
        *) warn system "$os: not Debian/Ubuntu, --install cannot use apt (the checks still apply)" ;;
    esac
else
    warn system "no /etc/os-release"
fi

# ---- apt packages first, so every check below sees them ----
if [ "$INSTALL" = 1 ]; then
    missing=()
    has lua5.4 || missing+=(lua5.4)
    has luac5.4 || missing+=(lua5.4)
    has lua5.4 && lua5.4 -e "require('cjson')" > /dev/null 2>&1 || missing+=(lua-cjson)
    has python3 || missing+=(python3)
    has mysql || missing+=(mariadb-client)
    # a server only when none is configured elsewhere (MYSQL_HOST) and none is installed here
    if [ -z "${MYSQL_HOST:-}" ] || [ "${MYSQL_HOST:-}" = localhost ]; then
        has mariadbd || [ -x /usr/sbin/mariadbd ] || [ -x /usr/sbin/mysqld ] || missing+=(mariadb-server)
    fi
    for t in find xargs tar diff mkfifo; do has "$t" || missing+=(coreutils findutils tar diffutils); done
    if [ "${#missing[@]}" -gt 0 ]; then
        mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u)
        echo "installing: ${missing[*]}"
        apt_install "${missing[@]}" || echo "  apt-get failed: install ${missing[*]} by hand"
    fi
fi

# ---- Lua ----
if has lua5.4; then
    v=$(lua5.4 -v 2>&1 | awk '{print $2}')
    case "$v" in
        5.4.*) ok lua5.4 "$v" ;;
        *) bad lua5.4 "$v is not Lua 5.4"; fix "apt install lua5.4" ;;
    esac
else
    bad lua5.4 "not found (tests/run.lua and every spec child run lua5.4)"; fix "apt install lua5.4"
fi
if has luac5.4; then
    ok luac5.4 "$(command -v luac5.4)"
else
    bad luac5.4 "not found"; fix "apt install lua5.4 (luac5.4 is in the same package)"
fi
if has lua5.4 && out=$(lua5.4 -e "local c = require('cjson'); print(c._VERSION or 'cjson')" 2>&1); then
    ok lua-cjson "$out"
else
    bad lua-cjson "require('cjson') fails in Lua 5.4"
    fix "apt install lua-cjson (or: luarocks --lua-version 5.4 install lua-cjson)"
fi

# ---- Python ----
if has python3; then
    v=$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')
    if version_ge "$v" 3.8; then ok python3 "$v"; else bad python3 "$v is older than 3.8"; fix "apt install python3"; fi
else
    bad python3 "not found (tools/check_contracts.py)"; fix "apt install python3"
fi

# ---- small tools the scripts use (mkfifo: the harness's mysql client; xargs: tests/run.lua --jobs) ----
for t in find xargs tar diff mkfifo awk sed grep sort mktemp; do
    has "$t" || { bad "$t" "not found"; fix "apt install coreutils findutils diffutils tar gawk sed grep"; }
done

# ---- MariaDB ----
if has mysql; then
    cv=$(mysql --version 2>&1)
    case "$cv" in
        *MariaDB*) ok "mysql CLI" "$(echo "$cv" | sed 's/^.*Distrib \([^,]*\),.*$/\1/')" ;;
        *) warn "mysql CLI" "not the MariaDB client ($cv); the harness reads its output: apt install mariadb-client" ;;
    esac
else
    bad "mysql CLI" "not found (the harness runs every MySQL call through mysql -uroot)"
    fix "apt install mariadb-client"
fi

server_up() { mysql -uroot -N -B -e "SELECT 1" > /dev/null 2>&1; }
local_server=0
if [ -z "${MYSQL_HOST:-}" ] || [ "${MYSQL_HOST:-}" = localhost ]; then local_server=1; fi
if has mysql && ! server_up && [ "$INSTALL" = 1 ] && [ "$local_server" = 1 ]; then
    if out=$(mysql -uroot -N -B -e "SELECT 1" 2>&1); [[ "$out" == *"2002"* ]]; then
        echo "starting the local MariaDB server"
        if has systemctl && [ -d /run/systemd/system ]; then
            as_root systemctl start mariadb || as_root systemctl start mysql
        elif [ -x /etc/init.d/mariadb ]; then
            as_root /etc/init.d/mariadb start
        elif [ -x /etc/init.d/mysql ]; then
            as_root /etc/init.d/mysql start
        else
            echo "  no service script: start mariadbd yourself"
        fi
        for _ in 1 2 3 4 5 6 7 8 9 10; do server_up && break; sleep 1; done
    fi
    if ! server_up && [ "$ROOT_NO_PASSWORD" = 1 ]; then
        out=$(mysql -uroot -N -B -e "SELECT 1" 2>&1)
        if [[ "$out" == *"1698"* ]] || [[ "$out" == *"1045"* ]]; then
            echo "letting local users in as MariaDB root without a password (--root-no-password)"
            as_root mysql -uroot -e "ALTER USER root@localhost IDENTIFIED VIA unix_socket
                OR mysql_native_password USING PASSWORD(''); FLUSH PRIVILEGES;"
        fi
    fi
fi

where="socket ${MYSQL_UNIX_PORT:-/run/mysqld/mysqld.sock}"
if [ -n "${MYSQL_HOST:-}" ] && [ "${MYSQL_HOST}" != localhost ]; then where="${MYSQL_HOST}:${MYSQL_TCP_PORT:-3306}"; fi
if has mysql; then
    if out=$(mysql_root -e "SELECT VERSION()"); then
        sv=$out
        series=$(echo "$sv" | sed -n 's/^\([0-9]*\.[0-9]*\).*/\1/p')
        if [[ "$sv" != *MariaDB* ]]; then
            bad "MariaDB server" "$sv at $where is not MariaDB"
            fix "use MariaDB $MARIADB_SERIES, for example in a container:"
            fix "docker run -d -p 3306:3306 -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 mariadb:$MARIADB_SERIES"
        elif [ "$series" = "$MARIADB_SERIES" ]; then
            ok "MariaDB server" "$sv at $where"
        else
            warn "MariaDB server" "$sv at $where: the suite is written and run in CI against $MARIADB_SERIES"
        fi
        mode=$(mysql_root -e "SELECT @@GLOBAL.sql_mode")
        want='STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION'
        if [ "$mode" = "$want" ]; then
            ok "sql_mode" "the $MARIADB_SERIES default"
        else
            warn "sql_mode" "$mode; the specs expect the default $want (errors and warnings are compared)"
        fi
        cs=$(mysql_root -e "SELECT CONCAT(@@character_set_server, ' / ', @@collation_server,
            ', time_zone ', @@time_zone, ' (', @@system_time_zone, ')')")
        ok "server settings" "$cs"
        off=$(mysql_root -e "SELECT TIMESTAMPDIFF(SECOND, UTC_TIMESTAMP(), NOW())")
        if [ "$off" = 0 ]; then
            ok "time zone" "UTC (the specs' dates are UTC; tests/run.lua runs them with TZ=UTC)"
        else
            bad "time zone" "NOW() is ${off} s off UTC: shadow mode stops, dates would not compare"
            fix "default-time-zone = '+00:00' under [mysqld], or run the server (container) with TZ=UTC"
        fi
        probe="cp_test_setup_probe_$$"
        sql="CREATE DATABASE \`$probe\` CHARACTER SET utf8mb4; SELECT COUNT(*) FROM mysql.seq_1_to_3;"
        if out=$(mysql_root -e "$sql DROP DATABASE \`$probe\`"); then
            ok "root privileges" "create/drop database, sequence engine"
        else
            bad "root privileges" "$out"
            fix "the harness needs root: CREATE/DROP DATABASE and mysql.seq_* (the Sequence engine)"
        fi
    else
        case "$out" in
            *2002*|*2003*|*"Can't connect"*)
                bad "MariaDB server" "none answers at $where: $out"
                fix "apt install mariadb-server and start it (--install does both),"
                fix "or point MYSQL_HOST and MYSQL_TCP_PORT at a server"
                ;;
            *1698*|*1045*|*"Access denied"*)
                bad "MariaDB server" "root is refused: $out"
                fix "run as the Linux root user, or --install --root-no-password, or export MYSQL_PWD=<root password>"
                ;;
            *)
                bad "MariaDB server" "$out"
                ;;
        esac
    fi
fi

# ---- Node.js ----
if [ "$INSTALL" = 1 ]; then
    nv=$(node -v 2>/dev/null | sed 's/^v//')
    if [ -z "$nv" ] || ! version_ge "$nv" "$NODE_MAJOR"; then
        if has apt-get; then
            echo "installing Node.js $NODE_MAJOR from NodeSource (deb.nodesource.com)"
            apt_install ca-certificates curl gnupg &&
                as_root mkdir -p /etc/apt/keyrings &&
                curl -fsSL "$NODESOURCE/gpgkey/nodesource-repo.gpg.key" |
                as_root gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg &&
                echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] $NODESOURCE/node_$NODE_MAJOR.x nodistro main" |
                as_root tee /etc/apt/sources.list.d/nodesource.list > /dev/null &&
                APT_UPDATED=0 && apt_install nodejs ||
                echo "  NodeSource install failed: install Node.js $NODE_MAJOR yourself (nvm install $NODE_MAJOR)"
            hash -r
        fi
    fi
fi
if has node; then
    nv=$(node -v | sed 's/^v//')
    if ! version_ge "$nv" "$NODE_FLOOR"; then
        bad node "$nv is older than $NODE_FLOOR (vite 6)"; fix "$NODE_FIX"
    elif ! version_ge "$nv" "$NODE_MAJOR"; then
        warn node "$nv works, but CI and the committed web/dist use Node.js $NODE_MAJOR"
    else
        ok node "$nv"
    fi
else
    bad node "not found (web checks and shadow mode)"; fix "$NODE_FIX"
fi
if has npm; then
    npv=$(npm -v 2>/dev/null)
    if version_ge "$npv" 7; then
        ok npm "$npv"
    else
        bad npm "$npv is older than 7 (package-lock.json v3)"; fix "npm install -g npm@10"
    fi
else
    bad npm "not found"; fix "it comes with Node.js $NODE_MAJOR"
fi

# ---- node_modules (npm ci only where they are missing or do not match package-lock.json) ----
# $1 folder, $2 a module that must load
lock_matches() {
    (cd "$1" && node -e '
        const fs = require("fs");
        const lock = JSON.parse(fs.readFileSync("package-lock.json", "utf8")).packages || {};
        let bad = 0;
        for (const [k, v] of Object.entries(lock)) {
            if (!k || v.optional || v.link) continue;
            try {
                const got = JSON.parse(fs.readFileSync(k + "/package.json", "utf8")).version;
                if (got !== v.version) { bad++; console.log(k + " " + got + " (lock: " + v.version + ")"); }
            } catch (e) { bad++; console.log(k + " missing"); }
        }
        process.exit(bad ? 1 : 0);
    ' 2>&1 | head -3)
}
modules() {
    local dir=$1 label=$2 out
    if [ ! -e "$dir/node_modules" ]; then
        out="no node_modules"
    elif ! out=$(lock_matches "$dir"); then
        out="differs from package-lock.json: $(echo "$out" | tr '\n' ';' | cut -c1-100)"
    else
        ok "$label" "matches package-lock.json"
        return
    fi
    if [ "$INSTALL" = 1 ] && has npm; then
        if [ -L "$dir/node_modules" ]; then
            bad "$label" "$out; node_modules is a symlink ($(readlink "$dir/node_modules")), not touching it"
            return
        fi
        echo "npm ci in $dir"
        if (cd "$dir" && npm ci --no-audit --no-fund); then ok "$label" "installed (npm ci)"; return; fi
    fi
    bad "$label" "$out"; fix "(cd $dir && npm ci)"
}
if has node; then
    modules Crimson-Police/web "web/node_modules"
    modules tests/shadow "shadow/node_modules"
fi

# ---- the formatters of the style step (tools/restyle.py --check) ----
stylua_cmd() { command -v stylua 2>/dev/null || { [ -x "$HOME/.cargo/bin/stylua" ] && echo "$HOME/.cargo/bin/stylua"; }; }
if [ "$INSTALL" = 1 ] && ! "$(stylua_cmd || echo false)" --version 2>/dev/null | grep -qx "stylua $STYLUA_VERSION"; then
    case "$(uname -m)" in
        x86_64) asset=stylua-linux-x86_64.zip ;;
        aarch64) asset=stylua-linux-aarch64.zip ;;
        *) asset= ;;
    esac
    if [ -n "$asset" ] && has curl && has python3; then
        if [ "$(id -u)" -eq 0 ]; then bin=/usr/local/bin; else bin=$HOME/.local/bin; fi
        echo "installing StyLua $STYLUA_VERSION ($asset) into $bin"
        tmpzip=$(mktemp)
        curl -fsSL -o "$tmpzip" "https://github.com/JohnnyMorganz/StyLua/releases/download/v$STYLUA_VERSION/$asset" &&
            mkdir -p "$bin" &&
            python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$tmpzip" "$bin" &&
            chmod +x "$bin/stylua" || echo "  StyLua download failed"
        rm -f "$tmpzip"
        hash -r
    fi
fi
sty=$(stylua_cmd)
if [ -z "$sty" ]; then
    bad stylua "not found (the style step)"
    fix "--install downloads the release binary; or cargo install stylua --version $STYLUA_VERSION --features lua54"
elif ! "$sty" --version 2>/dev/null | grep -qx "stylua $STYLUA_VERSION"; then
    bad stylua "$("$sty" --version 2>&1 | head -1) at $sty: the style is pinned to $STYLUA_VERSION"
    fix "cargo install stylua --version $STYLUA_VERSION --features lua54 (or the $STYLUA_VERSION release binary)"
elif ! printf 'local x <const> = 1\n' | "$sty" --syntax Lua54 - > /dev/null 2>&1; then
    bad stylua "$sty cannot read Lua 5.4 (built without the lua54 feature)"
    fix "cargo install stylua --version $STYLUA_VERSION --features lua54"
else
    ok stylua "$STYLUA_VERSION ($sty)"
fi
if [ -x Crimson-Police/web/node_modules/.bin/prettier ]; then
    ok prettier "$(Crimson-Police/web/node_modules/.bin/prettier --version) (web/node_modules)"
elif has npx; then
    if pv=$(npx --no-install "prettier@$PRETTIER_VERSION" --version 2>/dev/null); then
        ok prettier "$pv (npx cache)"
    else
        warn prettier "not in the npx cache: the style step fetches prettier@$PRETTIER_VERSION from npm on first use"
    fi
fi

# ---- leftovers of earlier runs (not a problem, only disk space) ----
left=$(ls -d /tmp/lua_* 2>/dev/null | wc -l)
if [ "$left" -gt 50 ]; then
    size=$(du -sch /tmp/lua_* 2>/dev/null | tail -1 | cut -f1)
    warn "leftovers" "$left /tmp/lua_* entries ($size) from earlier runs; tools/setup_test_env.sh --clean removes them"
fi

echo
if [ "$PROBLEMS" -eq 0 ]; then
    echo "ready: $WARNINGS warning(s). Run tools/check_all.sh (docs/TESTING.md)."
else
    echo "$PROBLEMS problem(s), $WARNINGS warning(s)."
    [ "$INSTALL" = 0 ] && echo "tools/setup_test_env.sh --install fixes what apt, NodeSource and npm ci can."
    exit 1
fi

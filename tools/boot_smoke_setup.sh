#!/usr/bin/env bash
# tools/boot_smoke_setup.sh · makes (or brings up to date) a clean FXServer test folder for tools/boot_smoke.sh.
# Safe to run again and again: it only fetches what is missing. docs/dev/TESTING.md, "Real server boot test".
#
#   tools/boot_smoke_setup.sh DIR              the folder to fill (made when missing):
#                                                DIR/artifact   the FXServer build the changelogs API recommends
#                                                DIR/data       server-data: server.cfg, resources/[deps] (the tagged
#                                                               releases below) and resources/[crimson]/Crimson-Police
#   --build N          a given FXServer build instead of the recommended one (e.g. 38435)
#   --crimson DIR      the Crimson-Police folder to copy in (default: the one of this repository)
#   --no-sql           do not import qbx_core.sql and qbx_vehicles/vehicles.sql
#
# The SQL goes into the database of $CP_FX_MYSQL (mysql://user:password@host[:port]/database), with the mysql (or
# mariadb) client; the database is made when missing. Without CP_FX_MYSQL the SQL step is skipped (say so).
# Nothing secret is written: the license key and the connection string stay in the environment.
# Exit status: 0 the folder is ready, 1 a step failed, 2 usage error.

set -u -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MARK=.cp_boot_smoke

# The releases Crimson-Police was booted with (Qbox v1.24.1 and the ox resources it wants).
OXMYSQL=v2.14.3
OX_LIB=v3.42.2
OX_INVENTORY=v2.48.1
OX_TARGET=v1.18.1
QBX_CORE=v1.24.1
QBX_VEHICLES=v1.4.2
REQUIRE=v1.0.2
CHANGELOGS=https://changelogs-live.fivem.net/api/changelog/versions/linux/server

DIR=
BUILD=
CRIMSON=$ROOT/Crimson-Police
SQL=1
while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --build) BUILD=${2:-}; shift ;;
        --crimson) CRIMSON=${2:-}; shift ;;
        --no-sql) SQL=0 ;;
        -*) echo "unknown option $1 (tools/boot_smoke_setup.sh --help)"; exit 2 ;;
        *) [ -z "$DIR" ] || { echo "one folder only"; exit 2; }; DIR=$1 ;;
    esac
    shift
done
[ -n "$DIR" ] || { echo "usage: tools/boot_smoke_setup.sh DIR (--help)"; exit 2; }
for c in curl tar unzip git; do
    command -v "$c" > /dev/null 2>&1 || { echo "missing command: $c"; exit 1; }
done
[ -f "$CRIMSON/fxmanifest.lua" ] || { echo "$CRIMSON is not the Crimson-Police folder"; exit 2; }

mkdir -p "$DIR/artifact" "$DIR/data/resources/[deps]" "$DIR/data/resources/[crimson]" || exit 1
DIR=$(cd "$DIR" && pwd)
DEPS="$DIR/data/resources/[deps]"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cp_boot_setup.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
step() { printf '  %-14s %s\n' "$1" "$2"; }

# ---- the FXServer artifact ----
if [ -x "$DIR/artifact/run.sh" ]; then
    step artifact "already there ($DIR/artifact)"
else
    json=$(curl -fsSL "$CHANGELOGS") || { echo "cannot read $CHANGELOGS"; exit 1; }
    url=$(printf '%s' "$json" | sed -n 's/.*"recommended_download":"\([^"]*\)".*/\1/p')
    if [ -n "$BUILD" ]; then
        # the folder of a build is <build>-<commit>; the download page lists the builds with their links
        base=${url%/*/fx.tar.xz}
        name=$(curl -fsSL "$base/" | grep -o "/master/$BUILD-[0-9a-f]*/fx.tar.xz" | head -1 | cut -d/ -f3)
        [ -n "$name" ] || { echo "no FXServer build $BUILD on the download page of $base"; exit 1; }
        url="$base/$name/fx.tar.xz"
    fi
    [ -n "$url" ] || { echo "no recommended build in $CHANGELOGS"; exit 1; }
    step artifact "$url"
    curl -fsSL -o "$TMP/fx.tar.xz" "$url" || exit 1
    tar -C "$DIR/artifact" -xJf "$TMP/fx.tar.xz" || exit 1
fi

# ---- the dependency resources, from their release zips (the built UIs included) ----
fetch_zip() {
    local name=$1 repo=$2 tag=$3 zip=$4 top
    if [ -f "$DEPS/$name/fxmanifest.lua" ]; then step "$name" "already there"; return 0; fi
    step "$name" "$repo $tag"
    rm -rf "$TMP/z" && mkdir -p "$TMP/z"
    curl -fsSL -o "$TMP/z.zip" "https://github.com/$repo/releases/download/$tag/$zip" || return 1
    unzip -q "$TMP/z.zip" -d "$TMP/z" || return 1
    top=$(find "$TMP/z" -mindepth 2 -maxdepth 2 -name fxmanifest.lua -path "*/$name/*" | head -1)
    [ -n "$top" ] || top=$(find "$TMP/z" -mindepth 1 -maxdepth 1 -name fxmanifest.lua | head -1)
    [ -n "$top" ] || { echo "    $zip has no $name/fxmanifest.lua"; return 1; }
    mv "$(dirname "$top")" "$DEPS/$name"
}
# A tagged source checkout, for a resource without a release zip.
fetch_git() {
    local name=$1 repo=$2 tag=$3
    if [ -f "$DEPS/$name/fxmanifest.lua" ]; then step "$name" "already there"; return 0; fi
    step "$name" "$repo $tag (source)"
    git clone -q --depth 1 -b "$tag" "https://github.com/$repo.git" "$DEPS/$name" 2> /dev/null || return 1
    rm -rf "$DEPS/$name/.git"
}
# A server-only boot needs a UI page to exist, not to work: an empty one when a source checkout has no build.
stub_ui() {
    local name=$1
    [ -f "$DEPS/$name/web/build/index.html" ] && return 0
    mkdir -p "$DEPS/$name/web/build/assets"
    echo '<!doctype html><title>stub</title>' > "$DEPS/$name/web/build/index.html"
    step "$name" "UI stub web/build/index.html (no release build)"
}

FAILED=0
fetch_zip oxmysql overextended/oxmysql "$OXMYSQL" oxmysql.zip || FAILED=1
# ox_lib v3.42 and later needs the require resource
fetch_git require overextended/cfxlua-require "$REQUIRE" || FAILED=1
fetch_zip ox_lib overextended/ox_lib "$OX_LIB" ox_lib.zip || fetch_git ox_lib overextended/ox_lib "$OX_LIB" || FAILED=1
fetch_zip qbx_core Qbox-project/qbx_core "$QBX_CORE" qbx_core.zip || FAILED=1
fetch_zip ox_target overextended/ox_target "$OX_TARGET" ox_target.zip || FAILED=1
# ox_inventory needs qbx_vehicles on a Qbox server
fetch_zip qbx_vehicles Qbox-project/qbx_vehicles "$QBX_VEHICLES" qbx_vehicles.zip || FAILED=1
fetch_zip ox_inventory overextended/ox_inventory "$OX_INVENTORY" ox_inventory.zip \
    || fetch_git ox_inventory overextended/ox_inventory "$OX_INVENTORY" || FAILED=1
[ -d "$DEPS/ox_lib" ] && stub_ui ox_lib
[ -d "$DEPS/ox_inventory" ] && stub_ui ox_inventory
[ "$FAILED" = 0 ] || { echo "a dependency could not be fetched (above)"; exit 1; }

# ---- Crimson-Police and server.cfg ----
touch "$DIR/data/$MARK"
if [ ! -f "$DIR/data/server.cfg" ]; then
    bash "$ROOT/tools/boot_smoke.sh" --write-cfg "$DIR/data/server.cfg" || exit 1
    step server.cfg "written (TCP only, no key or password in it)"
else
    step server.cfg "already there (kept)"
fi
dest="$DIR/data/resources/[crimson]/Crimson-Police"
mkdir -p "$dest"
find "$dest" -mindepth 1 -maxdepth 1 ! -name saves -exec rm -rf {} +
tar -C "$CRIMSON" --exclude=./web/node_modules --exclude=./saves -cf - . | tar -C "$dest" -xf - || exit 1
# FXServer cannot create folders on Linux: the saves folder and its two subfolders must exist
mkdir -p "$dest/saves/_backups" "$dest/saves/exports"
step Crimson-Police "copied from $CRIMSON (its saves folder kept)"

# ---- the SQL qbx_core and qbx_vehicles need ----
if [ "$SQL" = 0 ]; then
    step sql "skipped (--no-sql)"
elif [ -z "${CP_FX_MYSQL:-}" ]; then
    step sql "skipped: set CP_FX_MYSQL=mysql://user:password@host/database to import qbx_core.sql and vehicles.sql"
else
    client=$(command -v mariadb || command -v mysql) || { echo "missing command: mysql (or mariadb)"; exit 1; }
    rest=${CP_FX_MYSQL#mysql://}
    rest=${rest%%\?*}
    cred=${rest%%@*}
    hostdb=${rest#*@}
    user=${cred%%:*}
    pass=
    [ "$cred" != "$user" ] && pass=${cred#*:}
    hostport=${hostdb%%/*}
    db=${hostdb#*/}
    host=${hostport%%:*}
    port=3306
    [ "$hostport" != "$host" ] && port=${hostport#*:}
    [ -n "$db" ] && [ "$db" != "$hostdb" ] || { echo "CP_FX_MYSQL has no database name"; exit 1; }
    # the password goes in the environment of the client, never on its command line
    sqlc() { MYSQL_PWD=$pass "$client" -h "$host" -P "$port" -u "$user" "$@"; }
    sqlc -e "CREATE DATABASE IF NOT EXISTS \`$db\` CHARACTER SET utf8mb4" || exit 1
    # both files are CREATE TABLE IF NOT EXISTS / ADD COLUMN IF NOT EXISTS: safe to import again
    sqlc "$db" < "$DEPS/qbx_core/qbx_core.sql" || exit 1
    sqlc "$db" < "$DEPS/qbx_vehicles/vehicles.sql" || exit 1
    step sql "qbx_core.sql and vehicles.sql imported into $db on $host"
fi

echo "ready: export CP_FX_LICENSE_KEY=... then"
echo "  tools/boot_smoke.sh --fx '$DIR/artifact' --data '$DIR/data' --admin-check --restart"

# Crimson-Police · testing

How to set up a machine for the checks, run all of them or one spec, and read what fails. The same
checks run on GitHub Actions (`.github/workflows/ci.yml`); a change is done when `tools/check_all.sh`
passes (docs/ARCHITECTURE.md §11). How work flows around the checks is in docs/PROCESS.md.

## The checks

`tools/check_all.sh` runs these steps in this order and ends with a PASS/FAIL summary and the total time.

| Step | What it runs | Time (4 cores) |
|---|---|---:|
| `syntax` | `luac5.4 -p` on every `.lua` file in `Crimson-Police/`, `tests/` and `tools/` | 0.3 s |
| `contracts` | `python3 tools/check_contracts.py` (module calls, events, NUI names, locale keys, build stamp) | 0.4 s |
| `lint-fivem` | `python3 tools/lint_fivem.py`: FiveM pitfall rules FX01-FX10 (FX10, loops that can go round with no Wait, parses the Lua with `tools/lua_flow.py`), known hits in `tools/lint_baseline.txt` | 4.5 s |
| `style` | `python3 tools/restyle.py --check`: restyles a scratch copy of the tree and fails on any file that differs (docs/STYLE.md) | 26 s |
| `suite-db` | `lua5.4 tests/run.lua`: 30 specs on MariaDB | 16–17 s |
| `suite-files` | `lua5.4 tests/run.lua --storage=files`: the same specs with the database off (saves folder) | 16–18 s |
| `suite-shadow` | `lua5.4 tests/run.lua --storage=shadow`: MariaDB, the oxmysql twin and the engine compared, 0 differences | 23 s |
| `tsc` | `cd Crimson-Police/web && npx --no-install tsc --noEmit` | 7–8 s |
| `build` | `npm run build` in a scratch copy of the web sources; `web/dist` must be byte-identical to its output | 10–11 s |

A whole run takes about 1 min 40 s. Every `tools/lint_<name>.py` and `tools/check_<name>.py` (other than
`check_contracts.py`) is a `lint-<name>` step, run right after `contracts`: a new lint joins by checking the
repository with no arguments and exiting non-zero on a problem.

The suites run two specs at a time (`--jobs`, below). Measured on the same machine, the three suites took
64 + 35 + 79 s before, 31 + 29 + 41 s with one spec at a time, and 17 + 16 + 23 s two at a time. Most of the
old time was a new `mysql` process for every SQL statement (about 8 ms each, 744 of them in `e2e_spec`
alone): the harness now keeps one client open per spec. `tests/storage_spec.lua` (about 14 s of Lua work in
the saves folder engine) is the floor of a suite, whatever `--jobs` is.

## What the checks need

| Needed for | Version used (local, CI) | Debian/Ubuntu package | Without it |
|---|---|---|---|
| Lua 5.4: `lua5.4` runs `tests/run.lua` and every spec in its own `lua5.4` child | 5.4.6 | `lua5.4` | `tests/run.lua cannot start` names it |
| `luac5.4` for the `syntax` step | 5.4.6 | `lua5.4` (same package) | `missing command: luac5.4` |
| lua-cjson for Lua 5.4 (the harness and the shadow report) | 2.1.0 | `lua-cjson` | `tests/run.lua cannot start` names it |
| The MariaDB client `mysql`: the harness sends every MySQL call through `mysql -uroot` | 10.11.14 | `mariadb-client` | `tests/run.lua cannot start` names it |
| A MariaDB server with root and no password | 10.11 (10.11.14 local, `mariadb:10.11` = 10.11.19 in CI) | `mariadb-server` | `tests/run.lua cannot start` with the client's error |
| `mkfifo` (the harness's `mysql` client) and `xargs` (`--jobs`) | coreutils, findutils | `coreutils`, `findutils` | `tests/run.lua cannot start` names it |
| Python 3.8 or newer (`check_contracts.py`, `lint_fivem.py`, `restyle.py`) | 3.11 / 3.12 | `python3` | `missing command: python3` |
| StyLua 2.5.2 that reads Lua 5.4 (`style`) | 2.5.2 (cargo build local, release binary in CI) | none: `--install` downloads the release binary, or `cargo install stylua --version 2.5.2 --features lua54` | `stylua not found: ...` |
| Prettier 3.9.9 (`style`) | 3.9.9 | none: `npx --yes prettier@3.9.9` fetches it into the npm cache on first use | the `style` step fails if npm cannot reach the registry that first time |
| Node.js and npm (web steps, shadow mode) | Node 22, npm 10 | NodeSource `nodejs` | `missing command: node` / `tests/run.lua cannot start` in shadow mode |
| `Crimson-Police/web/node_modules` (react 18.3.1, vite 6.4.3, typescript 5.9.3) | from `package-lock.json` | `npm ci` | `Crimson-Police/web/node_modules has no tsc` |
| `tests/shadow/node_modules` (mysql2 3.22.4) | from `package-lock.json` | `npm ci` | `node and the mysql2 package ... Cannot find module 'mysql2/promise'` |

The server needs more than a login:

- root may `CREATE DATABASE` and `DROP DATABASE`: every run builds its own `cp_test_<time>_<n>` database from
  `sql/migrations`, copies it for every spec (`<run>_p<n>`, plus the `_ox` twin databases in shadow mode) and
  drops them all at the end;
- the Sequence engine (`mysql.seq_0_to_65535`, built into MariaDB), which `tests/memsql_spec.lua` reads;
- the default `sql_mode` of 10.11 (`STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,
  NO_ENGINE_SUBSTITUTION`): shadow mode compares errors and warnings, so strict mode must be on;
- `utf8mb4` databases (every test database is created `CHARACTER SET utf8mb4`);
- the session time zone at UTC (`NOW()` = `UTC_TIMESTAMP()`), as on a default container or CI: the saves folder
  engine reads dates in the specs' zone, so shadow mode refuses to start on a server in another zone (it
  reported 156 differences on a New York server). Set `default-time-zone = '+00:00'` under `[mysqld]`, or
  run the container with `TZ=UTC`.

The server's clock does not matter: every statement the harness sends starts with `SET timestamp = <the spec's
clock>`, so `NOW()` is the spec's fake clock (`H.time`) in every storage mode.

Other MariaDB series: the suite is written and run in CI against 10.11, the version Ubuntu 24.04 and
Debian 12 ship. The official images of two other series passed with the tree before the speed-up (all
three modes; times from then, one `mysql` process per statement):

| Server | Result | Time (db / files / shadow) | Why |
|---|---|---|---|
| 10.11.14 (local), 10.11.19 (`mariadb:10.11`) | pass, 0 differences | 64 / 33 / 79 s | |
| 10.6.28 (`mariadb:10.6`) | pass, 0 differences | 65 / 34 / 78 s | |
| 11.4.13 (`mariadb:11.4`) | pass, 0 differences | 224 / 61 / 235 s | 11.4 turns TLS on by default, so each new `mysql` connection paid a handshake: 43 ms instead of 8 ms |

11.4 also defaults to the `utf8mb4_uca1400_ai_ci` collation; nothing in the suite depends on it today.
`setup_test_env.sh` warns on any series other than 10.11. The harness still reconnects for every call
(`connect <db>`, a fresh session each time), so a TLS server still costs one handshake per statement.

Node.js 18 is the lowest vite 6 accepts; CI uses 22, and `setup_test_env.sh` warns below 22. npm must be 7
or newer to read the version-3 lockfiles.

Files mode still needs MariaDB: the run database is built on it, and other resources' tables
(`mdt_dispatch` fixtures) stay on MariaDB, as the real oxmysql would serve them.

## Set up

### Debian or Ubuntu

```sh
tools/setup_test_env.sh            # check only: one line per requirement, and the fix for each problem
tools/setup_test_env.sh --install  # install what is missing, then check again
```

`--install` changes only what is missing, so running it again does nothing:

- apt: `lua5.4 lua-cjson python3 mariadb-client`, and `mariadb-server` when no server is configured with
  `MYSQL_HOST`;
- starts the local MariaDB server when none answers (systemd, or the init script where there is no systemd,
  as in a container);
- Node.js 22 from NodeSource's apt repository when `node` is missing or older than 22;
- `npm ci` in `Crimson-Police/web` and `tests/shadow` when `node_modules` is missing or does not match
  `package-lock.json` (never when `node_modules` is a symlink).

It uses `sudo` when you are not root. As the Linux root user, MariaDB's root login works through the
socket without a password. As any other user, MariaDB refuses root (`ERROR 1698`); either run the checks as
root, set `MYSQL_PWD`, or let local users in as root without a password on a test machine:

```sh
tools/setup_test_env.sh --install --root-no-password
```

On a fresh Ubuntu 24.04 container, `--install` took 35 s and the next `tools/check_all.sh` passed.

### MariaDB in a container instead

```sh
docker run -d --name cp-mariadb -p 3306:3306 -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 mariadb:10.11
export MYSQL_HOST=127.0.0.1 MYSQL_TCP_PORT=3306
```

That is what CI does. You still need the MariaDB client (`mariadb-client`) on the machine.

### Where the server is

The harness never names a server: `mysql -uroot` finds it the usual way, and `tests/shadow/twin.cjs`
reads the same variables.

| Variable | Meaning | Default |
|---|---|---|
| `MYSQL_HOST` | a host name or address; `localhost` or unset means the socket | the socket |
| `MYSQL_TCP_PORT` | the TCP port when `MYSQL_HOST` is set | 3306 |
| `MYSQL_UNIX_PORT` | the socket path | `/run/mysqld/mysqld.sock` |
| `MYSQL_PWD` | root's password | none |
| `CP_SHADOW_HOST`, `CP_SHADOW_PORT`, `CP_SHADOW_SOCKET`, `CP_SHADOW_USER`, `CP_SHADOW_PASSWORD` | the twin only, when it must differ | the values above, user root |

The user is always root: the harness creates and drops databases. `~/.my.cnf` works for the `mysql` CLI,
but the twin does not read it, so a password in `~/.my.cnf` alone breaks shadow mode; use `MYSQL_PWD`.

### Leftovers

A run removes its databases and temporary folders when it ends. A run that was killed leaves them behind:
`tools/setup_test_env.sh --clean` drops every `cp_test*` database and removes the `/tmp/lua_*` folders of
test runs and the shadow reports. It refuses while any `tests/run.lua` is running on the machine, and it
does not know whose leftovers they are, so on a shared machine run it only when no other job tests.

## Run everything

```sh
tools/check_all.sh                   # every step
tools/check_all.sh suite-db tsc      # only these steps (tools/check_all.sh --list)
tools/check_all.sh --fail-fast       # stop at the first failing step
tools/check_all.sh -v                # stream each step's output as it runs
CP_TEST_JOBS=1 tools/check_all.sh    # the suites one spec at a time
```

Each step prints one line while the run goes on, and a summary at the end:

```
SUMMARY
  PASS  syntax            0.3s  125 Lua files
  PASS  contracts         0.4s  0 problems
  PASS  lint-fivem        1.6s  lint_fivem PASS: 0 new hits, 2 known (baseline), 0 stale baseline lines
  PASS  style            26.0s  style: every file is formatted
  PASS  suite-db         16.9s  30 specs, 31407 passed, 0 failed, 0 crashed
  PASS  suite-files      15.9s  30 specs, 31407 passed, 0 failed, 0 crashed
  PASS  suite-shadow     24.2s  30 specs, 31401 passed, 0 failed, 0 crashed, 0 differences
  PASS  tsc               7.3s  tsc: no errors
  PASS  build            10.0s  web/dist is up to date
PASS: 9 passed, 0 failed in 1m 39s (logs: /tmp/cp_check.Xy12ab)
```

The full output of every step is in the logs folder (`CHECK_LOGS=<dir>` picks it). Exit status: 0 all
passed, 1 a step failed, 2 a usage error. The assertion counts are the same in every run and in every
storage mode (30955 today): a total that moves between two runs of the same tree is a finding.

## Run one spec

```sh
lua5.4 tests/run.lua boards                    # every spec whose path contains "boards"
lua5.4 tests/run.lua /core_spec                # exactly tests/core_spec.lua ("core" also matches int_core_spec)
lua5.4 tests/run.lua --storage=files storage   # a filter and a storage mode together
lua5.4 tests/run.lua --storage=shadow e2e
lua5.4 tests/run.lua --jobs=4                  # four specs at a time (default 2; --jobs=1 one after another)
lua5.4 tests/run.lua --fuzz=5                  # tests/shadow/fuzz_*.lua in shadow mode, seeds 1..5
```

Always go through `tests/run.lua`: it checks the environment, builds the run database, runs each spec in
a fresh `lua5.4` child with `LC_ALL=C` and `TZ=UTC`, and cleans up. With more than one job each spec gets
a copy of the run database (`<run>_p<n>`, with its twin and saves folder), the specs that ran slowest last
time start first (`$TMPDIR/cp_test_times_<mode>.txt`), and the results still print in file order. A
filter that matches no spec is an error (exit 2). New or changed SQL must pass in all three storage modes.

Variables for one run:

| Variable | Effect |
|---|---|
| `CP_TEST_DB=name` | use this run database and keep it at the end (rebuilt from `sql/migrations` at the start) |
| `CP_TEST_SAVES=dir` | keep the saves folders in `dir` instead of a temporary folder |
| `CP_TEST_JOBS=n` | specs at a time, as `--jobs=n` |
| `CP_TEST_ORDER=reverse` or `shuffle[:seed]` | another spec order (the specs must not depend on it); with `--jobs=1` also the order they run in |
| `CP_TEST_NOW=<unix time>` | the harness' default fake clock `H.time` (1790000000, a Monday, otherwise) |
| `CP_TEST_CLOCK=<unix time>` | the wall clock itself: `os.time()` before `H.boot` and MariaDB's `NOW()` start at that moment |
| `CP_TEST_TZ=<zone>` | the specs' `TZ` (UTC otherwise); shadow mode always runs UTC |
| `CP_TEST_MYSQL=spawn` | one `mysql` process per statement, as before the speed-up (to compare) |
| `CP_SQL_LOG=file` or `dir/` | log every MySQL call as JSON lines (harness header, "optional SQL log") |
| `CP_SHADOW_REPORT=file` | where shadow mode writes differences (default `/tmp/cp_shadow_<run database>.jsonl`) |
| `CP_SHADOW_TRACE=1` | shadow mode: print every compared pair to stderr |
| `E2E_KEEP_DB=1` | keep `tests/e2e_spec.lua`'s own database |
| `E2E_VERBOSE=1` | print the resource's console output in `e2e`, `storage` and `storage_copy` specs |
| `CP_STORAGE_RUNS=n`, `CP_COPY_RUNS=n` | size of the storage timing specs (default 50000 and 1203 runs) |
| `FUZZ_SEED=n`, `FUZZ_N=n` | the fuzz scripts' seed and statement count |

The specs pass at any wall-clock time and in any time zone: this was checked with `CP_TEST_CLOCK` on a
Monday 00:10, a Tuesday 20:10 and 23:00 and a New Year's Eve, and with `CP_TEST_TZ` set to
`America/Los_Angeles` and `Pacific/Auckland`, in database and files mode. Outside UTC,
`tests/memsql_spec.lua` leaves out its 8 UTC-only time zone checks, so its count is lower there.
`tests/challenge_tz_spec.lua` runs its season-week checks again in child runs under three other zones
(`America/New_York`, `Europe/Berlin`, `Asia/Kolkata`), except in shadow mode, which compares with MariaDB's UTC dates.

## Read a failure

### tools/check_all.sh

A failing step prints `FAIL`, its one-line result, the log path and the lines that say what failed (or
the end of the log). On GitHub Actions each step's output is a folded group, a failed step is an error
annotation, and the summary table is on the run page.

### tests/run.lua

A failed check (here `tests/boards_spec.lua:169` expecting the wrong citizen):

```
storage mode: database (MariaDB)
MariaDB 10.11.14-MariaDB-0ubuntu0.24.04.1
1 spec, 1 at a time
✗ tests/boards_spec.lua  352 passed, 1 failed
  FAIL tie: fewer failed: expected B, got C

stack traceback:
	tests/boards_spec.lua:169: in main chunk
	[C]: in function 'dofile'
	...
1 specs, 352 assertions passed, 1 failed, 0 crashed (storage: database)
```

A spec that stopped (a statement MariaDB refused):

```
✗ tests/zz_demo_spec.lua crashed:
ERROR tests/zz_demo_spec.lua:3: SQL error: --------------
SELECT nope FROM cp_officers
--------------

ERROR 1054 (42S22) at line 1: Unknown column 'nope' in 'SELECT'
```

- `✗ ... N failed` then the spec's output: each `FAIL <message>: expected <x>, got <y>` (or `FAIL <message>`
  for `H.ok`) is followed by a traceback whose first `tests/` line is the failing check.
- `✗ <spec> crashed:` then `ERROR <file>:<line>: <error>`: the spec stopped there. After `SQL error:` comes
  MariaDB's answer and the statement as sent (placeholders filled in); `at line N` counts the lines of that
  statement. `SQL error: mysql -uroot exited with <code>` means the client itself failed (not found, or the
  server went away).
- `tests/run.lua cannot start, missing or not working:` lists what is missing (lua5.4, lua-cjson, the
  `mysql` client or the server with its own error text, mkfifo, xargs, node and mysql2 in shadow mode). Exit 2.
- `could not build the run database:` the migrations failed; the `mysql` message is above it. Exit 2.
- `SKIP <spec> (<mode> mode): <reason>`: a check that means something only on MariaDB; every skip is listed
  at the end. `REPORT` lines under a spec are timings and sizes (`storage`, `storage_copy`), not checks.
- The last line: `30 specs, N assertions passed, F failed, C crashed (storage: <mode>)`. Exit 0 only with
  0 failed, 0 crashed and, in shadow mode, 0 differences.
- A check that fails only when specs run side by side (`tests/storage_spec.lua` holds every query under
  250 ms): rerun with `--jobs=1` before calling it a regression.

### Shadow mode

```
shadow: 3907 statements compared, 0 differences, 1 skipped
  skipped core_spec: text is not valid UTF-8 (oxmysql cannot send it): INSERT INTO cp_officers (citizenid, display_name) VALUES ('UTFCTRL1', ?)
```

With differences the line ends in `; report /tmp/cp_shadow_<run database>.jsonl` (the report is kept only
then), `by category:` and `by spec:` count lines follow, and the run fails. Each difference is
one JSON line in the report: `spec`, `category` (`error`, `error-text`, `rowcount`, `value`, `type`, `order`,
`result`, `affectedRows`, `insertId`, `changedRows`, `warnings`, `info`, `state`, `state-autoinc`), `sql`,
`params`, the answers of `mariadb` (the twin, read like oxmysql) and `engine` (the saves folder engine),
`detail`, the resource frames `at` and the spec line `from`. `jq -c '{category, sql, detail, from}' <report>`
gives a quick list. What the engine deliberately does not copy is in the header of
`modules/storage/memsql.lua`.

### lint-fivem

```
Crimson-Police/modules/tablet/client.lua:745: FX04 SetNuiFocus(false, ...) outside an if (only while a CP UI holds the focus)
tools/lint_baseline.txt:11: stale: FX06 Crimson-Police/modules/runs/server.lua no longer has this hit; delete the line
hits by rule: FX04 1, FX05 3, FX07 2, FX08 2 (71 Lua files)
lint_fivem FAIL: 1 new hits, 7 known (baseline), 1 stale baseline lines
```

- `<file>:<line>: FXnn <message>`: a new hit. The rules are listed in the header of `tools/lint_fivem.py`.
  Fix the code; if the use is deliberate, add a line to `tools/lint_baseline.txt`
  (`<rule> <file> <code> -- <reason>`, `<code>` being the source line) and say why in the reason.
- `stale:` a baseline line whose hit is gone (the bug it names was fixed): delete the line in the same commit.
- An FX10 hit names the loop and the game state its condition waits on. `python3 tools/lua_flow.py --all <file>`
  gives every loop of a file its verdict (HIT, bounded, pure, ok) and why; tests/freeze_spec.lua checks the rule
  on the planted loops of `tests/fixtures/lint/fx10_loops.lua`.
- `python3 tools/lint_fivem.py --all` also prints the hits the baseline accepts. Rule FX01 reads
  `tools/fivem_natives.txt`; `--update-natives natives.json natives_cfx.json` rebuilds it from
  runtime.fivem.net's lists.

### The other steps

- `syntax`: `luac5.4: <file>:<line>: <message>` for each file that does not parse.
- `style`: `<file> would change` for each file the formatter would lay out differently. Run
  `python3 tools/restyle.py` (or `python3 tools/restyle.py <those files>`) and commit the result; never fix the
  layout by hand, the next run would undo it. `stylua not found` or a StyLua version message: see "What the
  checks need". The check writes only into a temporary copy (`$TMPDIR/restyle-check-*`, removed at the end).
- `contracts`: `## <check>: <count>` and one line per problem, then `TOTAL problems: N`. `nui-build` means
  `web/dist` was not rebuilt after a change to `web/src`, the build config or `locales/parts`.
- `tsc`: `src/<file>(<line>,<col>): error TS<code>: <message>`.
- `build`: `web/dist is stale: N files differ from a fresh build`, then the files (`Only in ...`, `Files ...
  differ`). Run `cd Crimson-Police/web && npm run build` and commit `web/dist`. The fresh build is kept in the
  logs folder. A build of the same sources is byte-identical, so a difference is never noise.

## CI

`.github/workflows/ci.yml` runs on every push and pull request, on `ubuntu-24.04` (pinned, because the apt
package names are that release's):

1. a `mariadb:10.11` service container, root without a password (`MARIADB_ALLOW_EMPTY_ROOT_PASSWORD`),
   healthy before the job starts, on a host port the runner picks (the runner image carries its own MySQL,
   which could want 3306);
2. `MYSQL_HOST=127.0.0.1` and `MYSQL_TCP_PORT=<that port>` go to `$GITHUB_ENV`, so every later step's `mysql`
   CLI and the twin use the service over TCP (`localhost` would mean a socket, and there is none);
3. apt: `lua5.4 lua-cjson mariadb-client`. This replaces the runner's MySQL 8.0 client (apt removes those
   packages); the step links `mysql` to `mariadb` where a newer package leaves the old name out, and fails
   unless `mysql --version` says MariaDB;
4. Node.js 22 with the npm cache (both lockfiles), `npm ci` in `Crimson-Police/web` and `tests/shadow`;
5. StyLua 2.5.2, the release binary (`stylua-linux-x86_64.zip`, checked for its version and for Lua 5.4
   syntax), and Prettier 3.9.9 through `npx`, for the `style` step;
6. `bash tools/setup_test_env.sh` (prints the environment, fails early when something is missing);
7. `bash tools/check_all.sh` from the repository root (the scripts run through `bash`, so they do not rely on
   the executable bit); on failure the logs and shadow reports are uploaded as the `check-logs` artifact.

What differs from a local machine and is handled: no socket (TCP only), root reached over TCP with an empty
password, `LANG=C.UTF-8` (the specs run with `LC_ALL=C` anyway), the runner's MySQL client and server
packages, and the runner's own clock and zone (the specs do not read either). The workflow passes
`actionlint` (with shellcheck). The same run was tried locally against the `mariadb:10.11` image over TCP
(no socket, `LANG=C.UTF-8`) before the speed-up: every step passed.

## Things that bit while setting this up

- **The `mysql` client's charset follows the locale**: latin1 under `C`/POSIX, utf8mb3 under `C.UTF-8`
  (the GitHub runner's default). The specs that need real UTF-8 force `--default-character-set=utf8mb4`;
  for the rest, `tests/run.lua` runs every child with `LC_ALL=C`, so all machines behave the same.
- **Specs that read the wall clock**: `tests/e2e_spec.lua` took its clock from MariaDB's `NOW()` and failed
  every evening from 20:00 and on Mondays before 20:00 (its "yesterday" rows landed on today or in last
  week); `tests/storage_spec.lua` failed on Mondays 00:00 to 00:30; `tests/oversight_spec.lua` depended on
  MariaDB's real `NOW()` being within 30 days of the fake `H.time`. Both specs now pin a Wednesday, and the
  harness sends `SET timestamp` with every statement, so `NOW()` is the spec's clock in every mode.
- **Local times written as UTC numbers**: `tests/engine_a_spec.lua` used UTC epoch numbers as local wall-clock
  times and failed in New York, Los Angeles and Auckland. It now builds them from date tables, and
  `tests/run.lua` still runs every child with `TZ=UTC` unless `CP_TEST_TZ` says otherwise.
- **A random check**: `tests/int_engine_spec.lua` checked the Time Crunch cut only when the run's random seed
  rolled that modifier (one run in three), so the totals moved by one. It now forces one Time Crunch roll.
- **Leftover files**: a spec child exits with `os.exit`, which skips the harness's cleanup, so each
  database-mode run used to leave about 42 MB of saves folders in `/tmp/lua_*` (4.4 GB in 458 folders here
  after a day of runs). `tests/run.lua` now gives every spec a folder inside the run's own temporary folder and
  removes it at the end. A killed `builder_server_spec` leaves `missions/custom/test_builder_<n>/`: git
  ignores those folders, and the next run removes the ones older than an hour.
- **The build stamp missed files**: `src/mocks/samples.ts` bundles every `locales/parts/*.json`, but the stamp
  hashed only `ui.json`, so `web/dist` went stale after a locale change without `check_contracts.py` noticing.
  The stamp now covers every part, and the `build` step compares a fresh build file by file.
- **`npx tsc` without `node_modules`** runs whatever `tsc` it finds (a global TypeScript 6.0.2 here, not the
  locked 5.9.3), or fetches the unrelated `tsc` package from npm. `check_all.sh` uses `npx --no-install` and
  requires `node_modules/.bin/tsc`.
- **`vite build` writes into `node_modules/.vite-temp`** (the compiled `vite.config.ts`). The `build` step
  works on a copy, so a check never writes into the tree or a shared `node_modules`.
- **A missing `mysql` client looked like wrong data**: its `not found` message was read as an empty result
  (21 failed checks and 14 crashes in database mode). The harness now fails when `mysql` exits non-zero, and
  `tests/run.lua` checks the client before the first spec.
- **Shadow mode used the socket only**: the twin ignored `MYSQL_HOST`, so with a TCP server the CLI and the
  twin could talk to different servers. The twin now reads the same variables as the CLI.

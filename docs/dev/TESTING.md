# Crimson-Police · testing

How to set up a machine for the checks, run all of them or one spec, and read what fails. The same
checks run on GitHub Actions (`.github/workflows/ci.yml`); a change is done when `tools/check_all.sh`
passes (docs/dev/ARCHITECTURE.md §11). What to check in game after a change is `docs/IN_GAME_CHECKLIST.md`.
What to update with each change is at the end, in "Working on the code".

## The checks

`tools/check_all.sh` runs these steps in this order and ends with a PASS/FAIL summary and the total time.

| Step | What it runs | Time (4 cores, 2026-11-02) |
|---|---|---:|
| `syntax` | `luac5.4 -p` on every `.lua` file in `Crimson-Police/`, `tests/` and `tools/` | 0.9 s |
| `contracts` | `python3 tools/check_contracts.py` (module calls, events, NUI names, locale keys, build stamp) | 1.5 s |
| `lint-fivem` | `python3 tools/lint_fivem.py`: FiveM pitfall rules FX01-FX12 (FX10, loops that can go round with no Wait, parses the Lua with `tools/lua_flow.py`; FX11, a `debug` function FXServer does not have; FX12, a server yes/no answer compared with `true`), known hits in `tools/lint_baseline.txt` | 7 s |
| `lint-lua` | `python3 tools/lint_lua.py`: luacheck at warning level over `Crimson-Police/` and `tests/` (undefined globals, unused and shadowed locals, dead stores, unreachable code), the rules in `.luacheckrc`, known hits in `tools/lua_lint_baseline.txt` ("lint-lua" below) | 20 s |
| `lint-i18n` | `python3 tools/check_i18n.py`: the translation scanner, English joined to a translated text (J), a plural built in place (P), a count string with no `_one` / `_other` forms (S), known hits in `tools/i18n_baseline.txt` ("Translation scanner" below) | 1 s |
| `style` | `python3 tools/restyle.py --check`: restyles a scratch copy of the tree and fails on any file that differs (docs/dev/STYLE.md) | 75 s |
| `suite-db` | `lua5.4 tests/run.lua`: every `tests/*_spec.lua` on MariaDB | 112 s |
| `suite-files` | `lua5.4 tests/run.lua --storage=files`: the same specs with the database off (saves folder) | 94 s |
| `suite-shadow` | `lua5.4 tests/run.lua --storage=shadow`: MariaDB, the oxmysql twin and the engine compared, 0 differences | 172 s |
| `tsc` | `cd Crimson-Police/web && npx --no-install tsc --noEmit` | 14 s |
| `walk` | `cd Crimson-Police/web && node walk.mjs`: every `src/**/*.walk.ts` walked through against the browser mocks (vite's module loader), e.g. the New mission wizard: create from a template, Use my position, Fill the points for me, Check, Publish, and every screen of every tablet rendered (`everyScreen.walk.ts`); `node walk.mjs <text>` runs only the walks whose path holds that text | 15 s |
| `build` | `npm run build` in a scratch copy of the web sources; `web/dist` must be byte-identical to its output | 20 s |
| `clickthrough` | opt-in: `node tools/clickthrough.mjs`, below | 15 min |
| `race-all` | opt-in: `CP_RACE_CUTS=all lua5.4 tests/run.lua --jobs=1 race`, `tests/race_spec.lua` cut after every query of every case instead of 5 spread over it | 6 min |
| `db-check` | opt-in: `tools/db_check.sh`, "Real database check" below | 10 min |

**Opt-in steps.** `clickthrough`, `race-all` and `db-check` print `SKIP` (and count as skipped) unless they are
named (`tools/check_all.sh clickthrough race-all db-check`) or turned on (`CP_CLICKTHROUGH=1`, `CP_RACE_ALL=1`,
`CP_DB_CHECK=1`).
`.github/workflows/nightly.yml` runs `clickthrough` and `race-all` every night and on request (`db-check` runs only when
named). `clickthrough` serves the built web UI in its
browser mock mode and runs `tools/clickthrough.mjs` in Chromium (Playwright, pinned in `Crimson-Police/web`'s
devDependencies; `npx playwright install chromium` once): the Officer, Supervisor, Admin and criminal tablets, every
screen, every tab, every button of each screen and each dialog a button opens, then the in-world screens (each
sample HUD and result card on a 1280x720 screen, the HUD column inside it, each card button clicked). It fails on a
console error, a crashed screen, a blank screen, a button covered by something else or overlapping another, or text
that is a locale key. Screenshots go to the folder given as its first argument (in the gate: the logs folder, never
the repo); `node tools/clickthrough.mjs <dir> admin` runs one part (`officer`, `supervisor`, `admin`, `crimtab`,
`world`); `npm run clickthrough` in `Crimson-Police/web` builds first. Run it after a change to a screen or the
layout.

**Time limits.** Every step runs under `timeout`: `CP_STEP_TIMEOUT=<seconds>` (default 1800, the opt-in steps
3600) stops a step that hangs and the summary says `TIMEOUT after N s`. Inside a suite each spec has its own limit,
`CP_SPEC_TIMEOUT=<seconds>` (default 900, 0 = none): `tests/run.lua` stops it, prints `✗ TIMEOUT <spec>` and counts
it as crashed. Ctrl-C stops the running step and its specs. tests/check_tools_spec.lua checks both limits.

**Not a gate step (needs an FXServer license key):** `tools/boot_smoke.sh` boots a real FXServer with
Crimson-Police and says PASS or FAIL, "Real server boot test" below.

A whole run takes about 8.5 minutes (the times above are from one run of every step on the full suite). Every
`tools/lint_<name>.py` and `tools/check_<name>.py` (other than `check_contracts.py`) is a `lint-<name>` step, run right after `contracts`: a new lint joins by checking the
repository with no arguments and exiting non-zero on a problem.

The suites run two specs at a time (`--jobs`, below); the harness keeps one MariaDB client open per spec.
`tests/storage_spec.lua` (about 14 s of Lua work in the saves folder engine) is the floor of a suite, whatever
`--jobs` is.

Full admin control has its own specs, each run in all three storage modes: `adminkit_spec` (the guard wrapper,
jobs, the maintenance lock), `admin_officers_spec` and `admin_boards_spec` (officers, points, boards, seasons),
`builtin_override_spec` and `admin_missions_spec` (edited built-ins, the Mission Builder admin tools),
`admin_live_spec` and `admin_runctl_spec` (live runs, units, anti-farm), `admin_economy_spec` and
`admin_rewards_spec` (payments, payouts, item rewards, department funds), `admin_system_spec` and
`admin_backup_spec` (departments, storage, backups, settings follow-ups), and `admin_control_e2e_spec`: the packages
together on the real server side (retire and unretire with money that waits, an untested built-in override played
under the same id and reset, a department added in game and turned off with its pay still paid, and a backup, a
payment and a restore that pays nothing twice).

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
| luacheck (`lint-lua`; `.luacheckrc` is written for it) | 1.1.2 | `lua-check` | `missing command: luacheck` |
| `timeout` (the step and spec time limits) | coreutils | `coreutils` | `missing command: timeout` |
| Chromium for Playwright (the opt-in `clickthrough` step only; Playwright 1.63.0 itself is in `Crimson-Police/web/node_modules`) | chromium-1243 | none: `cd Crimson-Police/web && npx playwright install chromium` (`setup_test_env.sh --install` does it) | `setup_test_env.sh` warns; the step fails at launch |
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
Debian 12 ship. Other series checked in all three modes:

| Server | Result | Why it matters |
|---|---|---|
| 10.11.14 (local), 10.11.19 (`mariadb:10.11`) | pass, 0 differences | |
| 10.6.28 (`mariadb:10.6`) | pass, 0 differences | |
| 11.4.13 (`mariadb:11.4`) | pass, 0 differences | 11.4 turns TLS on by default, so each new `mysql` connection pays a handshake (about 43 ms instead of 8 ms) |
| 12.3.3 (`mariadb-server` 12.3.3 deb) | database mode: pass | Qbox's recommended server. `FROM_UNIXTIME(0)` is NULL from 11.8, so an "all time" correction would match no row; the harness plays that on 10.11 |

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

Each step prints one line while the run goes on, and a summary at the end (a real run of 2026-11-02; the counts
grow with the specs):

```
SUMMARY
  PASS  syntax            0.9s  335 Lua files
  PASS  contracts         1.5s  0 problems
  PASS  lint-fivem        6.8s  lint_fivem PASS: 0 new hits, 3 known (baseline), 0 stale baseline lines
  PASS  style            74.7s  style: every file is formatted
  PASS  suite-db        111.6s  159 specs, 66354 passed, 0 failed, 0 crashed
  PASS  suite-files      93.8s  159 specs, 66336 passed, 0 failed, 0 crashed
  PASS  suite-shadow    171.8s  159 specs, 66329 passed, 0 failed, 0 crashed, 0 differences
  PASS  tsc              14.2s  tsc: no errors
  PASS  walk             15.2s  26 walks, 0 failed
  PASS  build            20.2s  web/dist is up to date
PASS: 10 passed, 0 failed in 8m 31s (logs: /tmp/cp_check.Xy12ab)
```

The full output of every step is in the logs folder (`CHECK_LOGS=<dir>` picks it). Exit status: 0 all
passed, 1 a step failed, 2 a usage error. The assertion counts of one storage mode are the same
in every run (the modes differ a little, as above): a total that moves between two runs of the same tree is a finding.

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
| `CP_TEST_MYSQL=spawn` | one `mysql` process per statement instead of one client per spec (to compare) |
| `CP_SQL_LOG=file` or `dir/` | log every MySQL call as JSON lines (harness header, "optional SQL log") |
| `CP_SHADOW_REPORT=file` | where shadow mode writes differences (default `/tmp/cp_shadow_<run database>.jsonl`) |
| `CP_SHADOW_TRACE=1` | shadow mode: print every compared pair to stderr |
| `E2E_KEEP_DB=1` | keep `tests/e2e_spec.lua`'s own database |
| `E2E_VERBOSE=1` | print the resource's console output in `e2e`, `storage` and `storage_copy` specs |
| `CP_STORAGE_RUNS=n`, `CP_COPY_RUNS=n` | size of the storage timing specs (default 50000 and 1203 runs) |
| `FUZZ_SEED=n`, `FUZZ_N=n` | the fuzz scripts' seed and statement count |
| `CP_SOAK=1` with `CP_SOAK_SEED=n` or `CP_SOAK_SEEDS=a-b`, `CP_SOAK_HOURS=h`, `CP_SOAK_STORAGE=database` | `tests/soak_spec.lua`'s long random soak (default: one seed, 2 simulated hours); `CP_SOAK_NOSHRINK=1` skips the shrinking of a failure, `CP_SOAK_TRACE=1` prints every action, `CP_SOAK_VERBOSE=1` the counts (docs/dev/WORKFLOWS.md) |
| `CP_WF_STORAGE=database` | the workflow and end-to-end specs that run on the saves folder (`tests/workflows_*_spec.lua`, `workflows_e2e`, `live_fto_e2e`, `realsuspects_e2e`) run on MariaDB with the database on instead, with `lua5.4 tests/run.lua`'s default database mode (docs/dev/WORKFLOWS.md) |
| `CP_LOAD_TRACE=1` | `tests/load_spec.lua` prints each harness step over 30 ms as a REPORT line |
| `CP_RACE_ONLY=<text>`, `CP_RACE_CUTS=n` or `all`, `CP_RACE_DEBUG=1` | `tests/race_spec.lua`: only the cases whose name holds the text; the restart cuts per case (default 5; `all`: after every query, a case's own `maxCuts` too); print both replies of each at-once pair |
| `CP_CRASH_SAMPLE=n`, `CP_CRASH_ALL=1` | `tests/crash_matrix_spec.lua`: the cut points of a journey with more awaits than n (default 40) are spread over it; `CP_CRASH_ALL=1` cuts after every await |
| `CP_SPEC_TIMEOUT=<s>`, `CP_STEP_TIMEOUT=<s>` | the time limit of one spec (default 900) and of one `check_all.sh` step (default 1800), "Time limits" above |

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
- The last line: `S specs, N assertions passed, F failed, C crashed (storage: <mode>)`. Exit 0 only with
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
`modules/system/memsql.lua`.

### lint-fivem

```
Crimson-Police/modules/access/client/tablet.lua:745: FX04 SetNuiFocus(false, ...) outside an if (only while a CP UI holds the focus)
tools/lint_baseline.txt:11: stale: FX06 Crimson-Police/modules/runs/runs.lua no longer has this hit; delete the line
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
- An FX12 hit is a server yes/no native (`b` lines of `tools/fivem_natives.txt`) whose answer is compared with
  `== true` or `~= true`: FXServer answers 1, so read it as a condition or accept `true or 1`.
  `python3 tools/lint_fivem.py --files server <file>` runs the per-file rules on any file (tests/foundation_spec.lua
  does so on `tests/fixtures/lint/fx12_bool.lua`).
- `python3 tools/lint_fivem.py --all` also prints the hits the baseline accepts. Rule FX01 reads
  `tools/fivem_natives.txt`; `--update-natives natives.json natives_cfx.json` rebuilds it from
  runtime.fivem.net's lists.

### lint-lua

```
Crimson-Police/shared/locale.lua:208:28: W113 accessing undefined variable 'GetGameTimr'
lint-lua: 1 new warnings, 44 in the baseline, 0 stale baseline lines (45 luacheck warnings in 27 files)
```

- `<file>:<line>:<col>: <code> <message>`: a new warning (`luacheck --codes`). W1xx is a global: a misspelt
  native or helper, a global written by mistake (only `CP`, `Config`, `RegisterMission` and `MySQL` may be). A
  shared native (apiset `shared`, which `tools/fivem_natives.txt` leaves out) used for the first time goes into the
  `shared` list of `.luacheckrc`. W2xx unused, W3xx a value never read, W4xx shadowing, W5xx unreachable code or an
  empty branch. Fix the code; a deliberate one goes into `tools/lua_lint_baseline.txt` (`<code> <file> <source
  line> -- <reason>`, the format of `tools/lint_baseline.txt`).
- Unused arguments are not reported (block hooks, callbacks and methods share a signature); in `tests/` only the
  globals, unreachable code and the like are, not unused or shadowed locals. luacheck does not look inside global
  tables: `CP.Moeny` is `check_contracts.py`'s (module calls) or a spec's to catch.
- `stale:` a baseline line no warning matches any more: delete it. `--all` prints the accepted warnings too,
  `--update-baseline` prints a line for every warning.

### Translation scanner

```
NEW J Crimson-Police/modules/foo/client/foo.lua:12: local s = CP.L('foo.title') .. ' minutes left'
120 hits, 119 in the baseline, 1 new, 0 stale
```

- `J`: English joined to `t()` / `CP.L()` with `+` or `..` (a literal with letters; `' · '` and `' '` between two
  whole sentences pass): make it one key with a placeholder. `P`: a count compared with 1 picking between translated
  texts: use `tn(key, n)` / `CP.Ln(key, n)` with `key_one` / `key_other` in `locales/parts`. `S`: a value like
  `{n} entries` with no forms: add `_one` / `_other` and read it with `tn` / `CP.Ln`.
- `tools/i18n_baseline.txt` holds the hits of 2026-11-12 (`<rule> <file> <code>`, compared without whitespace), so
  only new ones fail; a fixed hit leaves a `STALE` line to delete. `--write-baseline` rewrites it (keep the header).
  `--files A B` scans only those files without the baseline (`tests/i18n_scan_spec.lua` proves each rule on
  samples).
- `check_contracts.py` also checks that every `tn('key')` / `CP.Ln('key')` has `key_other` or `key`.

### Capability inventory

`tests/capability_inventory_spec.lua` builds the inventory with `tools/capability_inventory.lua` (every command,
net and local event, lib callback, NUI callback, export, admin action with its permission key, Admin UI setting,
feature switch and shipped Config key, each `<kind> <side> <name>`) and compares it with
`tests/capability_baseline.txt`:

- `nothing of the baseline is gone (N of M lines missing)` and the lines: something the resource could do is gone.
  Put it back, or, when it is removed on purpose, delete those lines from the baseline in the same commit and say
  so in its message.
- A REPORT line `N capabilities are not in the baseline yet`: new ones. Once they are meant to stay, run
  `lua5.4 tools/capability_inventory.lua --write` and commit the baseline.

The server list comes from tests/workflows_full_spec.lua's world on the shipped config, so a command or event that
registers only while its feature is on is listed only while it ships on.

### Crash matrix

`tests/race_spec.lua` cuts each client action by a restart after its queries ("cut after query n"), and
`tests/crash_matrix_spec.lua` does the same to what the server does by itself: a Beat Patrol's end and payout, and
the pay of a pending payment at login. After each cut the server starts again, the catch-ups run and the officer
logs in again; a failure names the cut (`patrol cut after await 6 of 25: paid at most once (2 payments)`). It also cuts a
feature reward, Pay again, a clawback and Pay the rest with the society source on, each checked for the money
invariants: the department's debits minus refunds equal what reached the officer (or the row says the department
paid and is listed for an admin), what a clawback took equals what the row holds and what the department got back or
is owed, never two deposits, and no admin claim left that no step marker explains. The other admin money tools
(manual cash, Add funds, Pay now, Retry pending, Cancel payment) are cut in `tests/race_spec.lua`.

In `tests/race_spec.lua` a cut that leaves no effect while the second copy is refused fails (`a cut leaves nothing
that blocks a new try`) unless the case lists that refusal in `cutRefusals` (right by design: a request id sent
again, a mission call a restart closed) or in `cutKnown` (a finding not fixed yet, printed as `REPORT KNOWN` on every
run: delete the entry with its fix). An effect a cut may leave behind (an audit row written after the change, XP
added after the award row, money a 'paying' row waits on) is in the case's `lag`.

### The other steps

- `syntax`: `luac5.4: <file>:<line>: <message>` for each file that does not parse.
- `style`: `<file> would change` for each file the formatter would lay out differently. Run
  `python3 tools/restyle.py` (or `python3 tools/restyle.py <those files>`) and commit the result; never fix the
  layout by hand, the next run would undo it. `stylua not found` or a StyLua version message: see "What the
  checks need". The check writes only into a temporary copy (`$TMPDIR/restyle-check-*`, removed at the end).
- `contracts`: `## <check>: <count>` and one line per problem, then `TOTAL problems: N`. `nui-build` means
  `web/dist` was not rebuilt after a change to `web/src`, the build config or `locales/parts`.
- `tsc`: `src/<file>(<line>,<col>): error TS<code>: <message>`.
- `walk`: `ok   <walk>: N passed, 0 failed` per walk, or `FAIL <walk>` and one `FAIL <what>` line per step that did
  not hold (`stopped: <action>: <err key>` when a mock refused). A new walk is a `src/**/<name>.walk.ts` exporting
  `walk(): Promise<{ passed, failures }>`.
- `build`: `web/dist is stale: N files differ from a fresh build`, then the files (`Only in ...`, `Files ...
  differ`). Run `cd Crimson-Police/web && npm run build` and commit `web/dist`. The fresh build is kept in the
  logs folder. A build of the same sources is byte-identical, so a difference is never noise.

## Real database check

`suite-db` runs every spec on one utf8mb4 database that `H.resetDatabase` makes, each migration applied once.
`tools/db_check.sh` checks what that cannot: the migrations and the SQL on the kinds of database owners really have.
It makes a throwaway MariaDB server of its own (`mariadb-install-db` on a new temporary data folder, `mariadbd`
with a socket under `/tmp/cpdb.*` and no TCP port, stopped and deleted on exit), so it never touches the local
server, `cp_test_*` or `cp_boot`. It needs `mariadb-server`, `lua5.4` and `lua-cjson`; as root it runs `mariadbd
--user=root`. A socket path holds at most 107 bytes, which is why the socket does not live under `TMPDIR`.

```
tools/db_check.sh                                 # every check (about 10 minutes, most of it the specs)
tools/db_check.sh --quick                         # without the specs (about 15 s)
tools/db_check.sh --out tools/db_check_result.txt # the report kept in the repository; commit it with the change
```

`tools/db_check.lua` does the checks and prints one `PASS`, `FAIL` or `INFO` line each, then `SUMMARY`:

- **The migrations, four times.** A utf8mb4 database, a latin1 one (MariaDB's own default), a utf8mb3 one
  (txAdmin's recipe deployer) and a latin1 one on a server whose `default_storage_engine` is MyISAM. Each runs the
  real `modules/system/migrations.lua` through a mysql-client stand-in for oxmysql: a first start, then
  `cp_schema_migrations` emptied and every file applied again (only the runner's own "already there" errors
  allowed), then a start that must change nothing. Then, from `information_schema`: every cp_ table InnoDB and
  utf8mb4, every text column utf8mb4, every JSON column `utf8mb4_bin` with its `json_valid` check, an emoji saved and
  read back, `cp_mission_runs_archive` with the same columns as `cp_mission_runs`, and the same tables and
  collations as the utf8mb4 database.
- **Every query PREPAREs**, with the default `sql_mode` and with `ONLY_FULL_GROUP_BY` added: each complete SQL
  string literal in `Crimson-Police/**/*.lua` (not `memsql.lua`), and, without `--quick`, each distinct statement
  the resource sent in eleven specs (`CP_SQL_LOG`, run against this server through `MYSQL_UNIX_PORT`). A statement on
  another resource's table (`players`, `player_vehicles`, Renewed-Banking's) is counted, not failed.
- **Every "insert once" target has a unique key** the insert fills: each `INSERT IGNORE`, `ON DUPLICATE KEY
  UPDATE` and `REPLACE INTO` on a cp_ table.
- **No column name needs quoting**: each cp_ column used unquoted in a prepared `SELECT ... WHERE ... ORDER BY`.
- **Writes round-trip**: INT at its limit and its sum, a value past INT and DECIMAL(4,2) refused (strict mode,
  nothing cut), NULLs and a JSON null read as SQL NULL, a DATETIME at 2147483647, a 280-emoji bio, a 255-emoji audit
  reason, a 5 MB JSON with emoji, text that is not JSON refused.
- **INFO lines**: the warnings each start printed, how many literals are built from parts (only the spec capture
  sees those), and the server's time zone as the start-up probe reads it.

Run it after a change to `sql/migrations/`, the migrations runner or any SQL, and keep its report:
`tools/db_check_result.txt` is the last full run. A FAIL line names the database kind or the `file:line` and
MariaDB's message.

## Real server boot test

The specs run the resource in plain Lua. `tools/boot_smoke.sh` starts a real FXServer headless with Crimson-Police
for two minutes (`--seconds N`), optionally types console commands, stops it and reads the console. It is not in
`check_all.sh` or CI, because FXServer needs a license key. Run it after a change to the start-up (migrations,
settings, the start-up check, `fxmanifest.lua`) and before a release.

It says **FAIL** when:

- a `SCRIPT ERROR`, `Error parsing`, `Failed to load` or `Couldn't start` line names Crimson-Police;
- a `server thread hitch warning` line shows up while Crimson-Police starts (from its script environment to the
  first line of another resource after its start-up check);
- a start of Crimson-Police has no `Crimson-Police database at version N` (or `saves folder at version N`) line
  or no `missions loaded:` line (each restart is checked the same way);
- Crimson-Police starts fewer times than asked, or `CrimsonPoliceAdmin check` gets no `Check:` answer;
- the server refuses its license key.

**The key is never written to a file.** The tool reads it from `CP_FX_LICENSE_KEY` and hands it to FXServer with
`+set sv_licenseKey` on the command line; `CP_FX_MYSQL` (the mysql connection string) goes the same way. The log
masks both and every `cfxk_` value. Do not put the key in `server.cfg`, a script or a commit.

### On your machine

Linux (or WSL), with bash, curl, unzip, git and a MariaDB or MySQL server for qbx_core. Get a key at
portal.cfx.re (Server registration keys). Then, from the repository folder:

```bash
export CP_FX_LICENSE_KEY=cfxk_...                              # your key, for this shell only
export CP_FX_MYSQL='mysql://fx:password@127.0.0.1/cp_boot'     # a test database, made when missing

# once (run it again any time: it fetches only what is missing, and copies Crimson-Police in again)
tools/boot_smoke_setup.sh ~/cp-boot

tools/boot_smoke.sh --fx ~/cp-boot/artifact --data ~/cp-boot/data --admin-check --restart \
    --crimson Crimson-Police
```

`tools/boot_smoke_setup.sh DIR` fills a clean test folder: `DIR/artifact` is the FXServer build the changelogs API
recommends (`--build N` for another), `DIR/data` is the server-data: oxmysql v2.14.3, ox_lib v3.42.2 with the
`require` resource it needs (cfxlua-require v1.0.2), qbx_core v1.24.1, ox_target v1.18.1, qbx_vehicles v1.4.2
(ox_inventory needs it) and ox_inventory v2.48.1 in `resources/[deps]` (release zips, so the UIs are built; a
source checkout gets an empty `web/build/index.html`, which is enough for a server-only boot), this repository's
Crimson-Police in `resources/[crimson]` with its `saves` folder (FXServer cannot make folders on Linux), and a
minimal `server.cfg` (TCP only, `inventory:framework "qbx"`, the resources in order, no key or password in it).
With `CP_FX_MYSQL` set it makes the database and imports `qbx_core.sql` and `qbx_vehicles/vehicles.sql` (both are
safe to import again).

Options of `tools/boot_smoke.sh` (`--help` has them all):

| Option | What it does |
| --- | --- |
| `--fx DIR` | the FXServer artifact folder (`run.sh`; `FXServer.exe` on Windows, untested) |
| `--data DIR` | a server-data folder, booted with its own `server.cfg` (`--cfg NAME` for another file) |
| `--resources DIR` | instead of `--data`: a scratch server-data whose `resources` folder is DIR, with the test `server.cfg` |
| `--admin-check` | types `CrimsonPoliceAdmin check` once the start-up check has printed |
| `--restart` | types `restart Crimson-Police` after that and checks the second start too |
| `--cmd 'TEXT'` | any other console command (more than once is fine) |
| `--crimson DIR` | copies this Crimson-Police folder into the test folder first (its saves are kept; only a folder made by the setup) |
| `--seconds N` | how long the server runs (default 120) |
| `--log FILE` | where the console log goes (default: a new file in the temp folder) |
| `--check LOG` | only reads a console log of an earlier boot and says PASS or FAIL (your own server's log works too) |

The test folder boots with the database off (the shipped `Config.Database.enabled = false`). To boot database
mode, set it to `true` in `DIR/data/resources/[crimson]/Crimson-Police/config/config.lua` and run without
`--crimson` (that copy would put the shipped value back). Your own server-data works with `--data` too: stop the
live server first (the ports), and leave `--crimson` out. The run stops the server itself (`quit`, then a kill
after 15 s) and leaves nothing running. `tests/boot_smoke_spec.lua` checks the log reading against real consoles
in `tests/fixtures/boot`.

## CI

`.github/workflows/ci.yml` runs on every push and pull request, on `ubuntu-24.04` (pinned, because the apt
package names are that release's):

1. a `mariadb:10.11` service container, root without a password (`MARIADB_ALLOW_EMPTY_ROOT_PASSWORD`),
   healthy before the job starts, on a host port the runner picks (the runner image carries its own MySQL,
   which could want 3306);
2. `MYSQL_HOST=127.0.0.1` and `MYSQL_TCP_PORT=<that port>` go to `$GITHUB_ENV`, so every later step's `mysql`
   CLI and the twin use the service over TCP (`localhost` would mean a socket, and there is none); then
   `sysctl net.ipv4.tcp_tw_reuse=1` and a wider `ip_local_port_range` (see "Things that bit" below: the suites
   open about 29,000 connections a run);
3. apt: `lua5.4 lua-cjson lua-check mariadb-client`. This replaces the runner's MySQL 8.0 client (apt removes those
   packages); the step links `mysql` to `mariadb` where a newer package leaves the old name out, and fails
   unless `mysql --version` says MariaDB;
4. Node.js 22 with the npm cache (both lockfiles), `npm ci` in `Crimson-Police/web` and `tests/shadow`;
5. StyLua 2.5.2, the release binary (`stylua-linux-x86_64.zip`, checked for its version and for Lua 5.4
   syntax), and Prettier 3.9.9 through `npx`, for the `style` step;
6. `bash tools/setup_test_env.sh` (prints the environment, fails early when something is missing);
7. `bash tools/check_all.sh` from the repository root (the scripts run through `bash`, so they do not rely on
   the executable bit); on failure the logs and shadow reports are uploaded as the `check-logs` artifact.

`.github/workflows/nightly.yml` runs the opt-in steps (`clickthrough`, `race-all`) every night at 03:17 UTC and on
request (workflow_dispatch), with the same service and setup plus `npx playwright install --with-deps chromium`; its
logs and screenshots are the `nightly-logs` artifact.

What differs from a local machine and is handled: no socket (TCP only), root reached over TCP with an empty
password, `LANG=C.UTF-8` (the specs run with `LC_ALL=C` anyway), the runner's MySQL client and server
packages, and the runner's own clock and zone (the specs do not read either). The workflow passes
`actionlint` (with shellcheck). The same run passes locally against the `mariadb:10.11` image over TCP
(no socket, `LANG=C.UTF-8`).

## Things that bit while setting this up

- **The runner ran out of TCP ports**: every harness call reconnects (`connect <db>`, a fresh session per
  call), so one `suite-db` run opens about 29,000 connections (`SHOW GLOBAL STATUS LIKE 'Connections'` before
  and after). On a socket that costs nothing; over TCP each closed connection holds a port for 60 s, and Linux
  keeps 28,232 of them. Once the suite passed about 87 specs, CI's `suite-db` (under a minute there) used them
  all up: the last specs crashed with `Lost connection to server at 'handshake: reading initial communication
  packet', system error: 11`, then `suite-files` and `suite-shadow` could not reach MariaDB at all, while the
  server's own log showed nothing wrong. The workflow now sets `tcp_tw_reuse=1` and the range 16384-65535. A
  local run over TCP (`MYSQL_HOST=127.0.0.1`, for example the container above) can hit the same wall: run the
  same `sysctl` there, or use the socket.

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
- **Mocks that said true where FXServer says 1**: on a real server a native that answers yes or no gives Lua the
  integer 1 (false for no), never true. The spec mocks answered true, so `DoesEntityExist(e) == true` in
  modules/npc and modules/npc/custody passed every spec while, on a real server, every mission NPC was declared dead
  a second after it spawned and every police action on a contact was refused. The harness now gives every server
  mock of such a native FXServer's answer (tests/harness.lua, "SERVER NATIVES THAT ANSWER YES OR NO"; checked by
  section 23 of tests/foundation_spec.lua). It owns the metatable of `_G` for that: a spec that wants undefined
  globals to be errors calls `H.strictGlobals(true)` instead of `setmetatable(_G, ...)`.
- **A debug library FXServer does not have**: the mission file sandbox stopped a running file with
  `debug.sethook`, which plain lua5.4 has and FXServer does not (its Lua is built with `LUA_SANDBOX`: debug holds
  only getinfo, getmetatable, setmetatable, getupvalue and traceback). Every spec passed while on a real server no
  mission file loaded at all (0 of 19 built-ins, every Builder publish and import refused). Mission files are now
  read as data and never run (`CP.U.parseMissionFile`), and the harness gives the resource exactly FXServer's five
  debug functions (`H.FX_DEBUG`; `H.debug` is the full library for the specs' own tools), and `lint-fivem` rule
  FX11 flags any other `debug.<name>` in the resource. With only that harness change the old code fails 116 checks
  and crashes 9 specs. tests/mission_reader_spec.lua checks the reader:
  every shipped file and both Builder layouts read exactly as Lua reads them, hostile text and CfxLua's own syntax
  are refused at once with the line, and the caps hold.
- **A database older than the one Qbox recommends**: the suite runs on MariaDB 10.11, while Qbox recommends 12.3.
  From 11.8 MariaDB answers `FROM_UNIXTIME(0)` with NULL (before the TIMESTAMP range), so every "all time" correction
  (Reset progression, Retire, voiding a whole operation, the forfeiture job) matched no row on the recommended server and
  every spec passed. The harness now sends a value below 1 in `FROM_UNIXTIME(?)` as NULL, as 11.8 and newer read it
  (tests/harness.lua `InFromUnixtime`; MariaDB's FROM_UNIXTIME page, and runs on 11.8.2, 11.8.9 and 12.3.3): with only
  that change the old code fails 10 checks in tests/admin_officers_spec.lua and tests/admin_control_e2e_spec.lua, the
  same 10 the suite failed on a real 12.3.3. The suite builds its databases utf8mb4, while txAdmin's recipe deployer
  makes a Qbox database `CHARACTER SET utf8` (utf8mb3), where an emoji in a name or reason is refused (error 1366):
  tests/foundation_spec.lua builds one like txAdmin, through the real runner, and checks the switch to utf8mb4. The
  runner's server check is played with the answers real servers gave (tests/failed_start_spec.lua 1.5: MySQL 8.0.20,
  MariaDB 10.2, MySQL 8.0.46, MariaDB 12.3). Shadow mode runs the runner's server statements on MariaDB alone, listed
  as skips: the runner never sends them to the saves folder.
- **Combat natives that took anything**: the specs recorded `SetPedAccuracy`, `TaskDriveBy` and friends without
  their argument types and never kept what they set, and nothing emulated `CancelEvent`, so none of the NPC combat
  settings the owner asked for (no automatic weapons, lower accuracy, slower fire, less damage, no headshot
  one-shots) could be checked. `H.combatNatives(onCall)` installs the combat and damage natives with natives.json's
  argument types (a float where the game reads a float: the native wrappers hand the raw Lua number to the game, so
  pass `x + 0.0`; an int, ped, player or hash as an integer; a BOOL as a boolean) and keeps what each one set: per ped
  the accuracy, shoot rate, firing pattern, ability, attributes and weapon; per game the AI damage modifiers, the
  config flags and the defense modifier (`world.forget(ped)` drops a ped's settings, like a ped back from another
  game). `H.fire` gives each dispatch one cancelled flag, as FXServer's TriggerEvent2 does (`CancelEvent`,
  `WasEventCanceled`, and its return value). tests/npc_combat_spec.lua, the npc client checks (the combat governor
  of every participant), tests/blocks_c_spec.lua (the drive-by) and tests/npc_spec.lua (the willKill cancel) use
  them; with the new config but the old code, more than 80 checks fail and the npccombat client checks crash.
- **An inventory mock that matched keys**: `H.mockInventory`'s Search compared metadata keys and its RemoveItem
  ignored metadata, while the real ox_inventory Search matches metadata VALUES and ignores the keys (ox_lib
  `table.contains`), RemoveItem needs exactly the same table (`table.matches`), and AddItem adds `durability` and
  `degrade` (food), `durability = 100` or `container` and `size` (bags) to what it is given. So every spec passed
  while, on a real server, Take back refused every food item or bag reward still in the inventory, an officer's own
  burger (`degrade = 60`) "was" reward 60, and the login sweep removed a player's own item of a mission item's name
  whose metadata held any `true`. `H.mockInventory` now ports those functions line by line (tests/admin_rewards_spec.lua
  section 2b, tests/engine_b_spec.lua's sweep). `GetPlayerIdentifierByType` is now in the harness too, with FXServer's
  first-identifier-that-starts-with-the-text rule (`H.players[src].identifiers`): `'license'` alone finds a
  `license2:` listed first (tests/identity_spec.lua, tests/oversight_spec.lua).
- **Movement natives that took anything, and lasted forever**: the npc client checks recorded
  `TaskFollowNavMeshToCoord` without its argument types (the module passed `false` for its int flags and could pass a
  whole number as the speed), and nothing knew that a move blend ratio cap or a move rate override lasts one frame
  (natives.json SET_PED_MOVE_RATE_OVERRIDE: "Needs to be looped!"), so a pace set once would have passed.
  `H.gaitNatives(onCall)` installs the movement natives a runner's game uses (TaskFollowNavMeshToCoord,
  TaskSmartFleePed, SetPedMaxMoveBlendRatio, SetPedMoveRateOverride, the clip set natives, GetSafeCoordForPed) with
  natives.json's argument types and keeps each ped's task, cap, move rate and clip set: `capNow(ped)` /
  `rateNow(ped)` answer only what was set during the current frame (one `H.step`), a clip set loads `loadMs` after
  `RequestClipSet` and only when natives.json lists it (`RemoveClipSet` unloads it and counts in `released`), and
  `safeCoord` is the spec's GetSafeCoordForPed. The npc client checks (tired runners) use it; with the old
  module 87 checks fail (30 of them the `false` flags).
- **Ground probe natives on a small map**: `H.groundNatives(onCall)` installs the natives of the ground probe
  (CP.Spawn.probe: RequestCollisionAtCoord, HasCollisionLoadedAroundEntity, the interior pin and ready
  natives, GetGroundZAndNormalFor_3dCoord, the water natives, StartShapeTestCapsule with GetShapeTestResult, the model
  natives) with natives.json's argument types, over a map the spec builds: the ground is found only once the
  collision has loaded (`collisionMs` after the first request, or never), an interior's floor only while it is
  ready (`readyMs` after a pin, or never), water heights, capsules that hit, take frames, never finish or do not
  start, and model sizes known only once the model is loaded. tests/spawn_ground_spec.lua uses it.
- **Placer natives on a small game**: `H.placerNatives(onCall)` installs the natives of the placer (the
  player natives, NetworkDoesNetworkIdExist / NetworkGetEntityFromNetworkId, control and its owner, IsPedInAnyVehicle,
  IsEntityAttached, FreezeEntityPosition, SetEntityLoadCollisionFlag, SetEntityCoordsNoOffset,
  SetVehicleOnGroundProperly, PlaceObjectOnGroundProperly) with natives.json's argument types, over the players and
  networked entities a spec sets up. As in the game, what this game sets on an entity it does not control is not kept
  (counted in `ignored`); control comes `grantMs` after the first request (or never) and another game can take it
  over at `loseAt`. tests/spawn_placer_spec.lua uses it with H.groundNatives, and tests/spawn_placer_npc_spec.lua
  too, with modules/npc/client/npc.lua loaded in the same game (its other natives recorded) so CP.Npc tasks a person while
  the placer checks his ground.
- **The server's side of the placer**: tests/spawn_place_spec.lua runs modules/runs/spawn.lua on the real
  engine (tests/fixtures/custody/world.lua) with FXServer's routing of the server RPC `FreezeEntityPosition`: sent to
  the game that simulates the entity (`NetworkGetEntityOwner`, a player's server id or -1), kept for the first game
  that takes an entity nobody simulates yet (ServerRPC.cpp), so a spec sees which game an entity is frozen on.
- **Player peds without health**: tests/npc_spec.lua answered 0 for a player ped's health, and the willKill cases
  modelled willKill as a headshot only, so a cancel that dropped EVERY killing hit (the shot that finishes off a hurt
  officer too) passed. FXServer reads a ped's health from its synced health node (`GET_ENTITY_HEALTH`,
  `GET_ENTITY_MAX_HEALTH` in ServerGameState_Scripting.cpp: 200 for a healthy freemode ped); the spec's player peds
  now answer `H.players[src].health` / `.maxHealth` (200 when not set), and the cases check that a killing hit on a
  hurt officer goes through.
- **Shadow mode used the socket only**: the twin ignored `MYSQL_HOST`, so with a TCP server the CLI and the
  twin could talk to different servers. The twin now reads the same variables as the CLI.

## Working on the code

Two things always outrank this section: the Hard rules in `docs/dev/SPEC.md`, and the contracts in
`docs/dev/ARCHITECTURE.md` and the Crimson-Arena rules in `docs/dev/INTEGRATIONS.md`.

### The gate before every commit

Run `tools/check_all.sh` once, right before the commit (its steps are listed at the top of this file).

- **Commit only on PASS.** Paste the gate's SUMMARY lines into the commit body. Do not type test counts
  by hand. The counts are deterministic (the same in every run and every storage mode), so a count that
  changes without a spec change is a finding.
- **While you work, use a filter**: `lua5.4 tests/run.lua <name>`, then again with `--storage=files`. Run
  the full gate once, before you commit.
- **Files mode is not optional.** In database mode the harness hands modules the mysql CLI's values: 0/1
  for TINYINT(1), numbers for SUM and DECIMAL. Only files mode gives modules the types oxmysql gives in
  production (booleans, and strings for DECIMAL sums). A module that passes database mode alone can still
  break on a live server.
- **CI runs the same script on every push** (`.github/workflows/ci.yml`). When CI is red, fixing it comes
  before any other merge.

### What to run and what to update, by change

| You changed | Run while you work | Update in the same commit |
| --- | --- | --- |
| A module or block (Lua) | its spec, in database and files mode | ARCHITECTURE §5 when a `CP.X.fn` is added or changes shape |
| SQL | its spec in all three modes; shadow must show 0 differences | the construct list in `modules/system/memsql.lua` for a new SQL construct |
| An event, callback, action or NUI message | `check_contracts.py`, `lint_fivem.py` | ARCHITECTURE §8 or §9. The §8 list is complete, so every name goes in it. |
| Natives, net handlers, NUI focus, callbacks, entities or files (`os.*`) | `lint_fivem.py` | `tools/lint_baseline.txt`: delete the line of a bug you fixed (the lint calls it stale); add one only for a deliberate use, with its reason |
| A locale key | `check_contracts.py --merge` | the key in `locales/parts/<part>.json`; `--merge` rebuilds `locales/en.json` |
| `web/src` or `locales/parts` | `tsc --noEmit` | `web/dist`: `cd Crimson-Police/web && npm run build` (the `build` step checks it) |
| Any Lua or web source | `python3 tools/restyle.py <your files>` before the gate | nothing: the `style` step checks it |
| A Config key | the specs that read it | `config/config.lua`, with its comment (the Settings description) |
| Behaviour the SPEC describes | - | SPEC (owner-approved changes only) |
| What an owner does or sees (install, a setting, a command, a console message) | - | the root README.md (install, admins, what ships off, commands, troubleshooting) or docs/OWNER_GUIDE.md (the details), and the folder README that covers it |
| The harness or the runner | the full gate twice, and once with `CP_TEST_JOBS=1`: the per-spec counts must be identical | ARCHITECTURE §11, the runner's header and this file |

### Keeping the docs true

- **Contract docs change in the same commit as the code**: ARCHITECTURE §5, §8, §9 and §10, the Crimson-Arena
  rules. The SPEC copies no config: it links to `config/config.lua`, and `tests/docs_spec.lua` checks that every
  Config key the SPEC names exists there.
  A protocol name without its §8 or §9 entry is a finding, and `tests/docs_spec.lua` fails on one: every event,
  callback, action and NUI callback of the capability inventory is named in ARCHITECTURE (or INTEGRATIONS for another
  resource's event; a grouped row may name the rest of its actions without their prefix), every other resource's
  client-sendable event in §8.2 and every key mapping in §8.3.
- **The map keeps up with the code** (`tests/docs_spec.lua`): FILE_NOTES has a line for every tracked source file
  (`.lua`, `.ts`, `.tsx`, `.py`, `.sh`, `.mjs`, `.cjs`, `.sql`; not missions/builtin, sql/migrations or web/dist, which
  its intro names), ARCHITECTURE names every `CP.X = CP.X or` table, §1 lists every shared and config file and owner
  document and the full shared load order, and every file LOOPS names exists, with the anticheat interval of the code.
- **What an owner sees or sets** (install, a setting, a command, a console line) goes in the root `README.md` when
  it is install, admins, what ships off, commands or troubleshooting, else in `docs/OWNER_GUIDE.md`, and in the folder
  README that covers it. The README stays under 60 KB (`tests/docs_spec.lua`).
- **Links, references and order** (`tests/docs_spec.lua`): in every tracked `.md` (outside ``` fences) each relative
  link lands on a tracked file or folder, and a `#anchor` into a `.md` on one of its headings; each `path:line` or
  `path:first-last` into this repository names a line the file has (a reference into another resource needs that
  resource on its line or in its section's heading); the README keeps its nine parts in order, each `n.m` under part n
  and counted up from 1. The console lines the docs quote (the mission load line, the department job warning) are
  checked against the code that prints them, and the in-game checklist opens with its first hour (12 to 18 checks,
  each with `->`).
- **No build history in the docs**: they describe what the code does now, not which step changed it. Step and plan
  ids stay out of every document but `Crimson-Police/CHANGELOG.md`; `tests/docs_spec.lua` checks it.
- **One place per fact**: SPEC states each rule once and points at ARCHITECTURE, the migrations and the config
  copy instead of restating them; the SPEC stays under 250000 bytes (`tests/docs_spec.lua`).
- **Commit messages** say what changed and why. The only numbers in them come from the gate.

### Keeping the style applied

- The style is `docs/dev/STYLE.md`, and its only sources are the owner's sc-* scripts. Crimson-Arena and
  Renewed-Banking show what not to write: no CAPS-led `--[[ ]]` header essays, no `---` doc comments, no
  PascalCase module tables, no heavy commenting.
- **The tree is formatted, and the gate keeps it so.** The `style` step runs `tools/restyle.py --check` and
  fails on any file the formatter would change. Run `python3 tools/restyle.py <your files>` before the gate,
  and commit what it changes. Do not hand-edit the layout it produces, and do not run StyLua or Prettier on
  their own (docs/dev/STYLE.md, "Keeping the style").
- **A change to the formatter restyles the whole tree:** `tools/restyle.py`, `stylua.toml`,
  `web/.prettierrc.json`, or another StyLua or Prettier version. Make it one commit of its own: it touches nearly every file.
- Style never renames a contract name: events, `CP.X.fn`, NUI names, locale and config keys, and columns.

### What the gate does not catch yet

Until these gaps are closed, look for them in review.

- **Randomness in specs.** Run seeds are still random (`U.uuid`); a spec may only branch on them in its
  setup, never around a check. `int_engine_spec` did (172 or 173 assertions) and now forces its Time Crunch
  roll. If a spec fails once and then passes, treat the failure as a real finding. `CP_TEST_ORDER`,
  `CP_TEST_CLOCK`, `CP_TEST_NOW` and `CP_TEST_TZ` (docs/dev/TESTING.md) help to reproduce it.
- **FiveM pitfalls the lint cannot see.** `lint-fivem` catches wrong-side natives, `source` read late,
  `os`/`io` on the client, unguarded focus release, raising callback awaits, entities without an orphan mode,
  `os.rename` answers, `os.execute` on the server and the Crimson-Arena natives. Review still has to catch
  `%d` on a value that can be fractional, code acting on a state bag another client can write (an entity's
  owner writes its bag), and hidden server rolls (seeds) sent to clients. A new `tools/lint_<name>.py` or `tools/check_<name>.py` joins the
  gate automatically.
- **Server journeys the crash matrix does not cut yet.** tests/crash_matrix_spec.lua cuts a run's end and pay and
  the login pay. A flagged run then its approve, the daily and weekly resets, the other start-up catch-ups and the
  bulk jobs are cut only at the hand-picked points of workflows_system_spec and adminkit_spec; `Restore a backup` is
  not cut by race_spec (workflows_system_spec (3) cuts it once).
- **Protocol names missing from ARCHITECTURE §8.** `check_contracts.py` compares code with code, not with
  the doc.
- **Timing budgets in `storage_spec`.** On a busy machine, or next to other specs, they can fail. Rerun
  the spec alone (`lua5.4 tests/run.lua storage_spec --jobs=1`) before you call it a regression.
- **FXServer file behaviour.** The harness runs plain Lua, where `os.rename` answers the right way round; FXServer
  inverts it on Linux. Like FXServer, the harness refuses `os.execute` for resource code and ends the spec (exit
  139) when resource code calls `os.createdir`, which crashes a Linux server. `lint-fivem` guards the known uses
  (FX07, FX08); anything else that touches files needs a test on a real server.
- **Yes/no natives answer 1 on the server.** FXServer gives Lua the integer 1 for a BOOL native's yes (false for
  no), never true, so `DoesEntityExist(e) == true` is false for every entity. Read the answer as a condition or
  accept `true or 1` (ARCHITECTURE §6.1). The harness gives every server mock that answer, whatever the spec's
  function returns; a spec never sets the metatable of `_G` (`H.strictGlobals`, `H.onUndefinedGlobal`).
  `lint-fivem` rule FX12 flags `== true` / `~= true` on such an answer (directly or through the local it went in).
- **A file listed twice in fxmanifest runs twice.** FXServer runs every entry (a file named by itself and matched
  again by a glob loads twice). fxmanifest lists every file once; only storage keeps a load guard, because
  the harness boots it before the manifest's list;
  tests/module_layout_spec.lua checks the list (every listed script exists and runs once, and `H.boot` loads
  `shared/*.lua` from `H.manifestScripts` in the manifest's order) and tests/adminkit_spec.lua expands the manifest
  the way FXServer does (`H.manifestScripts`) and fails on a repeated file.
- **Escrow seals every .lua file `escrow_ignore` does not list.** FXServer still runs those scripts, but
  `LoadResourceFile` of one gives ciphertext on an escrowed build, while the harness serves the plain file from
  disk. So never read a script's own source (or any other escrowed `.lua`) as data; read config, locales, missions
  and `.sql` / `.txt` / `.json` files only. tests/escrow_boot_spec.lua boots the server and client lists with every
  escrowed `.lua` sealed (`H.escrowIgnored` reads `escrow_ignore`) and fails on any read of one.
- **FXServer's debug library is five functions.** getinfo, getmetatable, setmetatable, getupvalue and traceback
  only: no `debug.sethook`, so text cannot be run under a step or memory budget. Never run text that comes from a
  file an admin can edit or from the Admin UI; read it as data (mission files: `CP.U.parseMissionFile`). The
  harness gives the resource the same five functions (a spec that needs more copies it from `H.debug`), and
  `lint-fivem` rule FX11 flags any other `debug.<name>` in the resource.

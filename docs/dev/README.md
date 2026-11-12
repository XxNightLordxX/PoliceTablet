# Crimson-Police for developers

**Server owners need nothing here.** The resource ships ready to run; the owner's guide is the root
[README.md](../../README.md).

- **The web UI** lives in `Crimson-Police/web/` (React 18, TypeScript and Vite). The built files in `web/dist/` are
  committed, and FiveM loads only those. After a change to `web/src/` or `locales/parts/`, rebuild and commit
  `web/dist/`:
  ```
  cd Crimson-Police/web
  npm install
  npm run build     # type check, build and build stamp: writes web/dist
  npm run dev       # the UI in a browser at http://localhost:5173, with sample data
  ```
  The full UI developer guide (source layout, adding a screen, the NUI bridge, hooks, theme variables and
  components) is §12 of `docs/dev/ARCHITECTURE.md`.
- **Every check in one command**: `bash tools/check_all.sh` (syntax, contracts, lint, style, the test suites in all
  three storage modes, tsc and the web build). `tools/setup_test_env.sh` checks and installs what it needs.
  `tools/boot_smoke.sh` boots a real FXServer with Crimson-Police and says PASS or FAIL (needs your license key in
  `CP_FX_LICENSE_KEY`; docs/dev/TESTING.md, "Real server boot test").
  `tools/db_check.sh` runs the migrations and every query on a throwaway MariaDB server of its own (docs/dev/TESTING.md,
  "Real database check").
  `.github/workflows/ci.yml` runs the same on GitHub.
- **The release**: `python3 tools/build_release.py` writes `dist/Crimson-Police/`, the owner docs and
  `dist/Crimson-Police-<version>.zip`, only what a city needs, and fails on a missing file, a version mismatch, a
  scratch file or a secret (docs/dev/TESTING.md, "Release build").
- **Text** lives in `Crimson-Police/locales/parts/<part>.json`. `python3 tools/check_contracts.py --merge` builds
  `locales/en.json` from them.
- **Custom missions** published from the Mission Builder are `Crimson-Police/missions/custom/<id>.lua`. Edit one and
  run `/CrimsonPoliceAdmin reload` to load the change as a new version. Every mission file is read as data
  (`CP.U.parseMissionFile` in `shared/utils.lua`) and never run, so it keeps to the Builder's layout: one
  `RegisterMission({ ... })` of plain values and `vec3`/`vec4` of numbers.

**Files in this repository:**

| Path | What it is |
|---|---|
| `README.md` | The owner's guide: install, admins, what ships off, commands, the Admin UI tour, troubleshooting |
| `docs/OWNER_GUIDE.md` | Every other owner detail: settings, extras, how it plays, real suspects, go-live, backups |
| `docs/dev/README.md` | This document |
| `Crimson-Police/` | The FiveM resource. Its `README.md` is a short install note |
| `Crimson-Police/items/README.md`, `logos/README.md`, `saves/README.md`, `web/README.md` | Short notes for each folder, pointing to the owner's guide |
| `docs/dev/SPEC.md` | The product spec: every rule and feature (its Hard rules win over everything); it links to `config/config.lua` and `config/blocks.lua` for every setting |
| `docs/dev/ARCHITECTURE.md` | Code structure: module APIs, the run model, the block interface, events, storage, the NUI protocol, the web UI developer guide (§12) |
| `docs/dev/INTEGRATIONS.md` | Checked facts about the other resources (qbx_core, sc-*, Renewed-Banking ...) and the rules for running alongside Crimson-Arena |
| `docs/dev/TESTING.md` | How to set up a machine, run the checks and read a failure, CI, and what to update with each change |
| `docs/IN_GAME_TEST_PLAN.md` | The short in-game test plan: a 60-minute smoke test, then the riskiest changes |
| `docs/IN_GAME_CHECKLIST.md` | What to check in game, one section per feature |
| `docs/dev/LOOPS.md` | Every loop and timer: when it runs, its interval and why, and the loop census |
| `docs/dev/WORKFLOWS.md` | Every workflow by group (Officer, Supervisor, Field training, Criminal, Admin, System) and the end-to-end spec that drives it |
| `docs/dev/STYLE.md` | The code style. `python3 tools/restyle.py` formats the tree, `--check` lists what isn't |
| `docs/dev/FILE_NOTES.md` | One line per source file saying what it is for (written by `tools/restyle.py` from the file headers) |
| `tests/` | Lua unit, SQL and end-to-end tests (`lua5.4 tests/run.lua`; needs a local MariaDB) |
| `tools/check_all.sh` | Every check in one command |
| `tools/check_contracts.py` | Cross-checks of module calls, events, NUI names and locale keys |
| `tools/build_release.py` | Builds the release folder and zip in `dist/` (ignored by git) |
| `tools/lint_fivem.py` | FiveM pitfall rules; known hits in `tools/lint_baseline.txt` |
| `tools/lua_flow.py` | The Lua parser and loop flow behind rule FX10 (`python3 tools/lua_flow.py --all <files>`) |

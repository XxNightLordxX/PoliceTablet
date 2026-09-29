# PoliceTablet

**Crimson-Police**: a Qbox police tablet with random NPC missions, cash payouts, leaderboards, a
department challenge and a Mission Builder.

- `Crimson-Police/`: the FiveM resource. Install instructions are in `Crimson-Police/README.md`.
- Database off: `Config.Database.enabled = false` saves all data as JSON files in `Crimson-Police/saves/` instead of MySQL/MariaDB.
- `docs/SPEC.md`: the product spec.
- `docs/ARCHITECTURE.md`: module APIs, run model, block interface, events and NUI protocol.
- `docs/INTEGRATIONS.md`: verified facts about the dependency resources.
- `docs/CRIMSON_ARENA.md`: rules for running alongside Crimson-Arena.
- `tests/`: Lua unit, SQL and end-to-end tests (`lua5.4 tests/run.lua`; needs a local MariaDB).
- `tools/check_contracts.py`: static cross-checks of module calls, events, NUI names and locale keys.
- `tools/lint_fivem.py`: FiveM pitfall rules (natives on the wrong side, late `source`, raising callbacks, orphan
  mode, FXServer's `os.rename` / `os.execute`, ...); known hits in `tools/lint_baseline.txt`.
- `docs/STYLE.md`: the code style (the owner's sc-* scripts). `python3 tools/restyle.py` formats the tree
  (StyLua, Prettier and its own passes); `python3 tools/restyle.py --check` lists what is not formatted.
- `tools/check_all.sh`: every check in one command (syntax, contracts, lint, style, the suite in all three storage
  modes, tsc, the web build); `tools/setup_test_env.sh` checks and installs what it needs. `docs/TESTING.md` explains
  both, and `.github/workflows/ci.yml` runs the same on GitHub Actions. `docs/PROCESS.md`: how work gets done.

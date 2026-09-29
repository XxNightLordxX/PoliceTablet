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

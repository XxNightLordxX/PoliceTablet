# Crimson-Police saves

When the database is off (`Config.Database.enabled = false` in `config/config.lua`), Crimson-Police saves all of its data here as small JSON documents, one per table, named after the table (`officers.json`, `seasons.json` ...). A table that grows past 500 rows is split into numbered documents (`mission_runs_1.json` holds ids 1-500, `mission_runs_2.json` 501-1000 ...). `_tables.json` describes every table and how it is split.

Keep this folder when you update the resource and back it up like you would a database. Do not edit these files while the server is running, and do not delete any: a missing document is reported on start and its rows are gone until you put it back. You can open and read them; if you edit one with the server stopped, it must stay valid JSON (any editor or formatter is fine).

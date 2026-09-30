# Crimson-Police saves

Full guide: section [6.5 Database off: the saves folder](../../README.md#65-database-off-the-saves-folder) of the
`README.md` in the repository root. This note says the same in short.

When the database is off (`Config.Database.enabled = false` in `config/config.lua`), Crimson-Police saves all of its data here as small JSON files, one per table, named after the table (`officers.json`, `seasons.json` ...). A table with more than 500 rows is split into numbered files (`mission_runs_1.json` holds ids 1-500, `mission_runs_2.json` 501-1000 ...). `_tables.json` describes every table and how it is split.

- Keep this folder when you update Crimson-Police, and back it up like a database (copy it while the server is stopped).
- Do not edit these files while the server is running. You can open and read them; if you edit one with the server stopped, it must stay valid JSON.
- Do not delete any file: a missing one is reported on start, and its rows are gone until you put it back from a backup.
- To move your data between the database and this folder, use `CrimsonPoliceAdmin storage copy database-to-files` or `CrimsonPoliceAdmin storage copy files-to-database` in the server console, then switch `Config.Database.enabled` and restart Crimson-Police.

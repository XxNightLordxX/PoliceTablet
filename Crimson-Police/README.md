# Crimson-Police

The full guide is the `README.md` one folder up, in the repository root (the front page on GitHub): start at
[3. Install in 5 minutes](../README.md#3-install-in-5-minutes). This note is the short version, for when you only
have this folder.

Crimson-Police is a police tablet for **Qbox** servers: on-duty officers pick a mission type, the server draws a
random NPC mission, and finished missions pay cash and earn leaderboard points.

## Install

1. Put this folder in your server's `resources` folder (a category folder like `resources/[police]/` is fine),
   named exactly `Crimson-Police`. The file `resources/Crimson-Police/fxmanifest.lua` must exist.
2. Add to the bottom of `server.cfg`:
   ```cfg
   ensure Crimson-Police
   add_ace group.admin crimsonpolice.admin allow
   ```
   The first line starts it. The second lets your server admins open the Admin UI (Qbox admins already can while
   `Config.QboxAdmins = true` in `config/config.lua`). To add more admins, or a Crimson-Police-only admin, see
   [4. Admins, supervisors and permissions](../README.md#4-admins-supervisors-and-permissions). Optional Discord
   webhooks are `set cp_webhook_<name> "..."` lines: see
   [6.6 Discord webhooks](../README.md#66-discord-webhooks).
3. Check that your Qbox jobs match `jobs` in `Config.Departments` (`config/config.lua`). The shipped departments
   use the jobs `sast` and `fib`, which a stock Qbox server does not have: add them to Qbox, or put your own job
   name in `jobs`. Set `supervisorGrade` to the Qbox grade number where supervisors start.
4. Start the server. About 5 seconds after Crimson-Police starts, the console prints its start-up check. Fix any
   yellow or red line it prints (each one says how), then restart Crimson-Police. Type `CrimsonPoliceAdmin check`
   in the server console to see every line again.
5. In game: officers on duty type `/CrimsonPolice`; admins type `/CrimsonPoliceAdmin`. **Esc** closes either one.

You never have to edit `config/config.lua`: an admin can change every setting in game in `/CrimsonPoliceAdmin` →
**Settings**, and switch missions and their locations on or off in **Missions** (see
[5.7](../README.md#57-change-any-setting-in-game-the-settings-screen)). Testing missions is optional.

Required resources (they start before Crimson-Police by themselves): `oxmysql`, `ox_lib`, `qbx_core`, `ox_target`,
`ox_inventory`, `sc-dispatch`, `sc-ambulance` and `Renewed-Banking`. There is no SQL to import.

Two switches at the top of `config/config.lua`, as shipped:

- `Config.Debug = true`: debug is on for testing, so the console shows many extra lines. Before go-live, set it
  to `false` and restart Crimson-Police.
- `Config.Database.enabled = false`: the database is off, so all data is saved as files in the `saves/` folder.
  Nothing to set up. To use your MySQL/MariaDB database instead, set it to `true` and restart Crimson-Police: it
  makes its own tables through oxmysql (the same `set mysql_connection_string` line Qbox already uses). If the
  server already has data, copy it first: see
  [5.5 The two switches at the top](../README.md#55-the-two-switches-at-the-top-debug-and-storage).

## What is in this folder

| Folder or file | What it is | Keep it when you update? |
|---|---|---|
| `config/` | Every setting: `config.lua`, `blocks.lua` (Mission Builder ranges), `banned_words.txt` | **Yes** (take the new `blocks.lua` unless you changed it) |
| `logos/` | One logo per department (see `logos/README.md`) | **Yes** |
| `missions/custom/` | Missions made with the Mission Builder | **Yes** |
| `saves/` | Your data while the database is off (see `saves/README.md`) | **Yes** |
| `items/` | The optional tablet item to copy into ox_inventory (see `items/README.md`) | Replace |
| `missions/builtin/` | The built-in missions | Replace |
| `web/` | The tablet's screens, ready-built in `web/dist` (see `web/README.md`) | Replace |
| `fxmanifest.lua`, `shared/`, `modules/`, `blocks/`, `locales/`, `sql/` | The resource itself | Replace |

Back up your database (or the `saves` folder with the database off) before every update. The steps are in
[10.2 Updating](../README.md#102-updating).

# Crimson-Police · code style

This is the owner's style, taken from the owner's own scripts: sc-multijob and sc-npcpolice (the owner's
Qbox-era scripts), sc-dispatch, and the owner's own lines in the sc-police and sc-ambulance forks.
Upstream code in those forks does not count. Crimson-Arena and Renewed-Banking are not style sources:
nothing here comes from them.

Every rule has a short example from the owner's code. Tags: **MJ** sc-multijob, **NP** sc-npcpolice,
**SCD** sc-dispatch, **SCP** sc-police, **SCA** sc-ambulance.

## What style never changes

Style is only about how code looks. These always win over it:

- The spec's Hard rules (`docs/SPEC.md`): Qbox only (no QBCore object), no ox_lib menus, dialogs or
  notifications, never edit a dependency resource.
- The contracts in `docs/ARCHITECTURE.md` and `docs/CRIMSON_ARENA.md`, and Lua 5.4 standard syntax.
- **Names other code or saved data depend on are never renamed for style.** That covers event and
  callback names, NUI messages and callbacks, exports, commands, key mappings, the `CP` namespace and
  every `CP.X.fn`, `Config` keys, locale keys, database tables and columns, state bag keys, and the
  fields of any table that crosses a module, the network or the database.
- Owner habits that break those rules are not followed: the QBCore object, `lib.notify`, context menus,
  `QBCore:Notify`, backtick hashes, per-file `DebugPrint`, bare global functions, config copied into
  file-top locals, `CREATE TABLE` at runtime, trusting client values.
- The tablet UI stays React 18 + TypeScript + Vite. It follows the owner's JS and CSS habits where they
  apply (indentation, quotes, semicolons, comments, naming of plain functions and CSS tokens).

## Tools

| File | What it does |
| --- | --- |
| `stylua.toml` | StyLua 2.5.2 settings (`cargo install stylua --features lua54`). |
| `.styluaignore` | Keeps `Crimson-Police/missions/` out of StyLua (see Exceptions). |
| `Crimson-Police/web/.prettierrc.json` | Prettier 3.9.9 settings for `web/src` and the build files next to it. |
| `.editorconfig` | Spaces, LF, final newline, no trailing spaces. |
| `tools/restyle.py` | Runs both formatters, then does what they cannot (below). |

## Keeping the style

The whole tree is formatted. `tools/restyle.py` is the formatter: it runs StyLua and Prettier, then its own
passes. Run it on what you changed before the gate:

```sh
python3 tools/restyle.py                                        # the whole tree, in place
python3 tools/restyle.py Crimson-Police/modules/runs tests/run_ui_spec.lua   # only these files or folders
python3 tools/restyle.py --check                                # change nothing; list each file a run would change
tools/check_all.sh style                                        # the same check, as the gate runs it
```

Name the specs too when you restyle a module on its own: a spec that quotes the module's code in a string
(`'local function ParticipantsList(run)'`) follows a rename only when it is part of the same run. When it is
not, the tool leaves that function's name alone rather than break the spec.

- **The gate fails on an unformatted file.** `tools/check_all.sh` has a `style` step that runs
  `python3 tools/restyle.py --check`. The check restyles a scratch copy of the tree, never the tree itself,
  prints `<file> would change` for each file that differs, and exits 1 when there is one. CI runs the same
  step on every push and pull request. To fix it, run `python3 tools/restyle.py` and commit the result.
- **Never run StyLua or Prettier on their own.** StyLua alone spreads every one-line `if`, loop and function
  and stacks long calls one argument per line, and `restyle.py` then undoes that, so `stylua --check`
  reports nearly every file. Prettier alone leaves out the header and comment passes.
- **Running it twice changes nothing.** A second run that changes a file is a bug in `tools/restyle.py`: fix
  the tool, not the file.
- **What it formats:** every `.lua` file in `Crimson-Police/` and `tests/` except `missions/`, and `web/src`
  (`.ts`, `.tsx`, `.css`) with `web/index.html`, `web/vite.config.ts` and `web/build-stamp.mjs`. It never
  touches `web/dist`, `node_modules`, the locale JSON, `docs/`, `tools/` or `tests/shadow/twin.cjs`.
- **After a web change, rebuild `web/dist`** (`cd Crimson-Police/web && npm run build`). The `build` step
  fails until you do. Restyling never changes what the UI shows: the built CSS stays byte-identical, and the
  built JS differs only where Prettier splits JSX text around a space (`{' '}`).
- **What it needs:** Python 3.8 or newer; StyLua 2.5.2 with Lua 5.4 syntax (`cargo install stylua
  --version 2.5.2 --features lua54`, or the release binary `stylua-linux-x86_64.zip`, which CI uses);
  Node.js with Prettier 3.9.9 (`npx --yes prettier@3.9.9`, from the npm cache after the first run). Both
  versions are pinned, because another version may lay the code out differently.
- **Speed:** the per-file layout runs in one worker process per core (`RESTYLE_JOBS=n` changes it; `1` keeps
  everything in one process, with the same result). The whole tree takes about 30 s on 4 cores.

### What `tools/restyle.py` does

These are the jobs it does around the formatters:

- It renames file-level local functions to PascalCase, and only when that is safe (see Naming).
- It cuts file headers to a short summary. The full text moves to `docs/FILE_NOTES.md`.
- It writes section banners in the owner's format.
- It rewrites `table.insert(t, v)` as `t[#t + 1] = v`, and fixes console prefixes and colour codes.
- After the last StyLua run, it gives back the layout StyLua takes away (see Layout): an `if`, loop or
  function written on one line goes back on one line, long calls, conditions and expressions are packed
  instead of one piece per line, and trailing comments get their columns back.
- It checks that these layout steps only moved line breaks (and added the trailing comma of a table it
  spread out, or a `;` that was there before): if the code changed, it stops with an error.
- In web files, it rewrites file headers and banners, turns `/** */` and `/* */` comments into `//`
  comments, and puts a blank line between CSS rules.

## Layout

- **Indent with 4 spaces, never tabs**, in Lua, TS/TSX, CSS and HTML.
- **Keep lines to about 120 characters.** The tools wrap a longer call, condition or expression. A
  long string is never split, so a line with one may run over.
- **Wrap the owner's way: pack, do not stack.** Fill the first line, continue at +4, and put the closing
  bracket at the end of the last line. A condition or an expression continues with its operator
  (`or`, `and`, `..`) at the start of the line, and `then` goes at the end.
  > NP cl_utils.lua: `SetVehicleNumberPlateText(veh, ('%s%s%06d'):format(` / `    string.char(64 + math.random(26)), string.char(64 + math.random(26)), math.random(0, 999999)))`
  > SCP server/fibstation.lua: `exports.ox_inventory:RegisterStash(stashName, cfg.GTFEvidence.Label or 'GTF Evidence Locker',` / `    cfg.GTFEvidence.Slots or 500, cfg.GTFEvidence.MaxWeight or 4000000)`
  > NP cl_scenarios.lua: `elseif call.scenario == 'speeding' or call.scenario == 'drunkdriver'` / `    or call.scenario == 'stolenvehicle' or call.scenario == 'pursuit' then`
  > NP cl_scenarios.lua: `local disabled = not IsVehicleDriveable(veh, false)` / `    or GetVehicleEngineHealth(veh) < 150.0`
- **A function argument hugs its call**, and the arguments after it follow its `end`. Multi-line SQL
  opens `[[` on the call's line and closes `]]` before the parameters.
  > SCD client/main.lua: `QBCore.Functions.TriggerCallback('sc-mdt:server:GetPlayerDNA', function(result)` / `    cb(result)` / `end, citizenId)`
  > SCD server/main.lua: `local examined = MySQL.query.await([[` / *(SQL)* / `]], { citizenId }) or {}`
- **A short `if`, loop or function may stay on one line** when it fits in 120 columns. Write it the way
  that reads best: the tools keep a one-line block on one line and leave a multi-line block as it is.
  Two statements on one line keep the `;` between them if they had one.
  > NP cl_utils.lua: `for _, j in ipairs(Config.PoliceJobs) do PoliceJobsSet[j] = true end`
  > NP cl_scenarios.lua: `local function RandomFrom(t) return t[math.random(#t)] end`
  > MJ client.lua: `if dutyOverride ~= nil and data.currentJob then` / `    data.currentJob.onduty = dutyOverride` / `end`
- **Never leave two blank lines in a row.** Leave one blank line between functions and handlers, and
  one around a banner. Inside a function, a single blank line may separate steps: guards, lookup,
  action, reply. Do not put a blank line right after the function line or right before `end`.
  > MJ client.lua: `if isOpen then return end` / *(blank)* / `local playerData = getPlayerData()`
- **No trailing spaces, no whitespace on blank lines.** Use LF line endings, no BOM, and one final
  newline.

## Lua

### Strings

- **Use single quotes, always.** Escape an apostrophe instead of switching to double quotes. Put
  multi-line SQL in `[[ ]]`.
  > MJ server.lua: `description = 'You don\'t have that job.',` · NP config.lua: `label = 'Rob\'s Liquor Morningwood'`
- **Build strings with `('fmt'):format(...)`** for logs and generated ids, and with `..` (spaced) for
  short joins. Never call `string.format(...)` directly; passing it as a value
  (`pcall(string.format, fmt, ...)` inside `CP.log`) is fine. Wrap values that may be nil in `tostring()`.
  > NP sv_main.lua: `dispatchUid = ('npccall-%d-%d'):format(nextCallId, os.time()),`
  > SCD server/main.lua: `local author = ('%s %s'):format(ci.firstname, ci.lastname)`

### Naming

- **File-level local functions are PascalCase** and usually start with a verb: Get, Is, Has, Set,
  Build, Spawn, Pick, Clear, Find, Start, Stop, Make. A helper that returns a value may be a noun.
  > NP sv_main.lua: `local function IsCop(src)` · SCP server/fibstation.lua: `local function CleanLabel(s, maxLen)`
  > NP: `local function PublicCall(call)`, `local function ClosestPlayerDist(coords)`
- **A function declared inside another function keeps camelCase.** The owner writes these closures
  in lower case.
  > SCD server/main.lua: `local function collect(tbl, kind)` · SCP server/main.lua: `local function finalize(imageUrl, note, noteType)`
- **Public module functions keep their names.** `CP.Cash.pay`, `Units._sweep` and the rest are
  contracts (ARCHITECTURE §5), so they stay as they are.
- **Locals and file-level state are camelCase.** Constants are `UPPER_SNAKE`, with the unit in the name
  or a trailing comment. Use `_` for values you ignore.
  > NP sv_main.lua: `local activeCalls = {}          -- [callId] = call table`
  > SCP client/evidence.lua: `local CASING_COOLDOWN = 500 -- ms between casings`
- **One global table per module**, `CP.<Name>`, as ARCHITECTURE §0.4 requires. This is the owner's
  namespace pattern (NP `NPC = NPC or {}`). Everything else is `local`.
  > NP cl_utils.lua: `NPC = NPC or {}`
- New event, NUI and command names follow ARCHITECTURE §2 and §8. Events are
  `crimson-police:<side>:camelName`, the same shape as the owner's `<resource>:<side>:camelName`.
  > MJ client.lua: `TriggerServerEvent('sc-multijob:server:toggleDuty')`

`tools/restyle.py` renames a local function only when all of these hold. It skips the name otherwise.

- It is declared at file level: `local function x`, or a forward `local x` that is later given a
  function. A `do` block at file level counts as file level; a function body does not.
- Only the uses that mean that function are renamed. It follows Lua's scopes, so a parameter, loop
  variable or other local with the same name keeps its own name, and a use that means a global stays
  a global.
- The new name is used nowhere in the file and is not a global anywhere in the code, so it does not
  shadow a native, `CP` or a test stub.
- Tests read module sources and quote code in strings (`push(m, 'board'`, `local function x(`). A
  quote that matches a module's code is renamed along with it. If a rename would leave a quote only
  half matching, the rename is dropped.

### Comments, headers and banners

- **A file header is a short plain summary of at most 3 lines.** Do not open a file with an essay,
  an author line, a version or a licence. Describe the API in `docs/ARCHITECTURE.md`.
  > NP cl_main.lua: `-- Tracks active calls client-side; the first on-duty cop to get close claims` /
  > `-- the spawn from the server and becomes the scene "host" (runs the NPC AI).`
- **Section banner: a rule of 76 `=`, the title in CAPS centered under it, and the rule again.** This
  is 79 columns. Only the label before a `(`, `:` or ` - ` is in capitals. Code names inside it keep
  their case. Keep the title short. When it runs past about 56 characters, the label stays in the
  banner and the explanation goes on a comment line under it.
  > SCD client/main.lua:
  > `-- ============================================================================`
  > `--                              HELPER FUNCTIONS`
  > `-- ============================================================================`
- **Inside a function or a `do` block, use a one-line sub-banner:** `-- ---- TITLE ----`, padded with
  `-` to 79 columns.
  > SCD server/main.lua: `-- ---- CERT HELPERS ----------------------------------------------------------`
- **Write comments with `-- ` and a space.** Keep them short and explain *why*, at most about 6 lines.
  Do not use `---` doc comments or `@param`. Do not use NOTE:, IMPORTANT: or TODO lead-ins. Use
  `--[[ ]]` only to switch off data.
  > MJ client.lua: `-- Small delay to let PlayerData.jobs sync first`
- **Trailing comments explain units, magic numbers and table shapes.** A group of consecutive commented
  lines shares one column. Lines without a comment may sit in between if they have the same indent,
  as in a config table. Use column 33, or 2 spaces past the longest line in the group. A comment that
  continues on the next line stays under the one it continues. The tools keep the column a comment was
  written at as long as its line keeps its code.
  > NP config.lua: `IntervalMin = 7,            -- minutes: minimum time between generated calls`
  > NP config.lua: `engageDistance = 90.0,      -- until a cop is THIS close the rival gangs are kept` / `                            -- from wiping each other out, so the scene is still`

### Functions and control flow

- **Put guard clauses first, one line each:** `if not x then return end`. Stack authority checks. A
  guard that must tell the player something becomes a short block ending in `return`.
  > MJ server.lua: `if not player then return end`
  > NP sv_main.lua: `if not call or call.state ~= 'pending' then return end` / `if not IsCop(src) then return end`
- **Report failures as values**, not with `error()`: return `nil`, `false`, or `false, 'err.key'`. The
  error key is a locale key (ARCHITECTURE §0.8).
  > NP sv_main.lua: `if #cops < (sc.minCops or 1) then return false, 'not enough cops' end`
- **Keep nesting shallow.** Guards keep handler bodies at depth 1-2. When a tree of `if`s grows deep,
  pull out a helper.
- **Loops:** use `ipairs` for arrays and `pairs` for maps, with `_` for the part you ignore. Use a
  numeric `for` for counts. Write threads as `while ... do ... Wait(n) end` with a sleep that adapts
  to what is happening. Do not use `goto`.
  > NP cl_interact.lua: `for _, s in ipairs({ 1, 2, 0 }) do -- rear right, rear left, front passenger`
- **Handlers:** a raw server handler starts with `local src = source`. Register net events with
  `RegisterNetEvent(name, function ... end)`. Use `CreateThread`, `Wait` and `SetTimeout`, never
  `Citizen.CreateThread` or `Citizen.Wait`. `Citizen.Await` and `Citizen.CreateThreadNow` have no
  short name and stay. A NUI callback always answers. `onResourceStop` comes last in the file, guarded
  by the resource name.
  > MJ server.lua: `RegisterNetEvent('sc-multijob:server:toggleDuty', function()` / `local src = source`
- **Only calls into other resources go inside `pcall`.** Check `GetResourceState` first, then read the
  result as `ok and res`.
  > SCD client/main.lua: `local ok, result = pcall(function()` / `return exports['pug-paintball']:IsInPaintball()` / `end)` / `return ok and result == true`
- **Validate client input on the server**: `type()` checks, `tonumber`, length caps, then ownership
  and distance.
  > MJ server.lua: `if type(jobName) ~= 'string' or jobName == '' then return end` / `jobName = jobName:lower()`

### Tables and operators

- **A table that does not fit on one line has one field per line and a trailing comma.** An inline
  table has spaces inside its braces. An empty table is `{}`. Do not line up the `=` signs.
  > MJ client.lua: `jobsList[#jobsList + 1] = {` / `name = jobName,` / … / `gradeLabel = gradeLabel,` / `}`
- **Append with `t[#t + 1] = v`**, never `table.insert(t, v)`. `table.insert(t, 1, v)` to insert at a
  position is fine.
- **Put spaces around every binary operator and after every comma.** Write ternaries as `a and b or c`.
  Put defaults with `or` where the value is used. Write `.0` on floats passed to natives.
  > NP cl_scenarios.lua: `if dist < (opts.catchDistance or 6.0) then`

### Logging

- **Use `CP.log(TAG, fmt, ...)`** for debug lines, which print only with `Config.Debug`. Use
  `CP.warn` and `CP.err` for problems (ARCHITECTURE §0.9). These play the role of the owner's
  `DebugPrint`. Write messages in lowercase after the tag.
- **Console lines look like `[crimson-police:<tag>] message`.** Put the colour code on the tag only,
  and reset it with `^7`.
  > NP sv_main.lua: `print(('^3[sc-npcpolice]^7 dispatch alert failed for %s (call still created): %s'):format(...))`

### Config files

- `Config = {}` comes first and `Config.Debug = false` is the first key. Each section gets a banner.
  Scalars carry aligned trailing comments that give the unit or the options. Comment out an unwanted
  entry rather than deleting it.
  > NP config.lua: `MaxActiveCalls = 3,         -- max NPC calls active at once`
- Existing keys keep their names, because code and server owners' configs read them. New top-level
  sections are PascalCase, and a new key follows the case of the table it joins.

## Web (React + TypeScript)

- **Use 4 spaces, semicolons, and single quotes.** JSX attributes take double quotes. Use template
  literals, not `+`. Use `const`/`let`, never `var`, and `===` only. Put a trailing comma on
  multi-line literals.
  > MJ script.js: `$.post('https://sc-multijob/toggleDuty', JSON.stringify({}));`
- **Plain functions are camelCase function declarations.** Components stay PascalCase, because React
  needs it. Constants are `UPPER_SNAKE`. Leave out the parentheses on a single arrow parameter.
  > SCD html/police/script.js: `async function nuiCallback(event, data = {}) {` · `const DEBUG = false;`
- **Comments use `//` only**, with no `/** */` doc blocks and no `/* */` (JSX needs `{/* */}`, which
  stays). Banners use the Lua format with `//`.
  > SCD html/police/script.js: `// ============================================================================`
- **CSS:** write one declaration per line with 4 spaces, and one blank line between rules. New classes
  are kebab-case; the existing `cp-` names with `--modifier` and `__part` keep their spelling, because
  the components use them. Colours come from `:root` tokens (`--cp-*`). A section label is a plain
  `/* Title */`.
  > MJ style.css: `:root {` / `    --primary: #af0505;` · SCD html/police/style.css: `/* Header */`

## Exceptions

- **Mission files** (`missions/builtin`, `missions/custom`) keep the spec's Example file layout: 2
  spaces, aligned `=`, and a `--[[ ]]` header. The Mission Builder writes that layout, and the tests
  check field order against it. Built-in and builder-written missions should look alike.
- **The two CSS class prefixes with an underscore** (`builder_client-`, `run_ui-`) stay, because tests
  check them. New prefixes are kebab-case.
- **`modules/storage/memsql.lua` keeps its stdlib aliases** (`local sformat = string.format`, ...).
  They are a speed measure in the SQL engine's hot paths, not a style choice.
- **10 file-level local functions keep camelCase** because their PascalCase name is already taken: it is
  a native (`removeBlip` in two files, `deleteEntity`, `registerCommand`) or another name in the same
  file (`adminTheme`, `missionTypes`, `limits`, `rescale`, `alerts`, and `admin` in
  `tests/storage_copy_spec.lua`, next to `CP.Admin`). Rename one by hand with a new name.

## Where your scripts disagree

Rule used: the majority of your own work decides, with MJ, NP and SCD counted first and SCP/SCA
second. MJ and NP break ties. Where your own scripts are split and neither form breaks a rule, the
tools keep what the author wrote. Each line below is a choice you can overrule.

| Question | Your scripts | Chosen |
| --- | --- | --- |
| Local function case | PascalCase in NP, SCD, SCP, SCA; camelCase in MJ | PascalCase at file level |
| Function inside a function | lower/camelCase in SCD (7 of 7); split in SCP, SCA (6 of 12) | camelCase (13 of your 19) |
| File-level state | camelCase in MJ, NP; PascalCase in SCD | camelCase (tie, so MJ/NP) |
| Banner shape | 3-line `=` in SCD, SCP, SCA; 3-line `═` in MJ; inline `═` in NP | 3-line `=` (most of your code, your cross-resource fingerprint) |
| Banner title position | centered in SCD; 26-space indent in SCP | centered (SCD first) |
| Sub-banners | `-- ---- NAME ----` in SCD; `-- ----` rule plus Title line in SCP | SCD form |
| Apostrophe in a string | escaped in MJ, NP, SCP; double quotes in SCD | escaped |
| File header | none in MJ; 2-3 lines in NP; boxed header in SCD; design paragraphs in SCP/SCA Era 2 | at most 3 plain lines (NP) |
| Aligned `=` | unaligned in MJ, NP; aligned in SCD config and SCP Era 2 | unaligned |
| Trailing comment column | NP column 25-36; SCD 32/36/40 | as written; a group shares one column (33, or 2 past the longest line, when its lines disagree) |
| Blank line after guards | yes in MJ, SCP, SCD; no in NP | allowed, not enforced |
| Short `if`, loop or function | multi-line in MJ; one line in NP, SCD Era 4 | as written (one line only when it fits in 120) |
| Two statements in a one-line guard | `then cb({}) return end` in SCD; a block in MJ, SCP Era 2 | as written; new guards that answer or notify are blocks (MJ) |
| Wrapped arguments and conditions | packed at +4 in NP, SCP Era 2; operator first | packed (StyLua's one piece per line is undone) |
| Append | `t[#t + 1]` in MJ, NP, SCD Era 4, SCP Era 2; `table.insert` in older SCD/SCP | `t[#t + 1]` |
| Formatting call | `:format` in NP, SCD Era 4, SCP Era 2; `string.format` in older code | `:format` |
| Trailing commas | always in MJ, NP, Era 2; mixed in older code | always |
| Colour codes | tag only in NP, SCD; whole line in CP | tag only |
| Line length | NP up to 134; SCD up to 271; soft ~120 | 120 |
| CSS rules | multi-line with a blank line between in MJ, SCD index/bill; one-line in SCD police | multi-line, blank line between |
| Arrow parameter | `x =>` in SCD, SCA; `(x) =>` rare | `x =>` |
| NUI message key | `action` in MJ, SCA; `type` in SCD, SCP | `type` (a protocol already, ARCHITECTURE §9) |
| Event name case | camel in MJ, NP; Pascal in SCD, SCP | camel (the protocol already uses it) |
| Comment lead-ins | NOTE:, CRITICAL: in SCP; rare elsewhere | none |

## What the formatter cannot match

These numbers come from running the formatter (StyLua with `stylua.toml`, then the layout and comment
steps of `tools/restyle.py`) on your own files. They leave out the deliberate changes (renames, headers,
banners). Before the layout steps, the formatter changed MJ by +4 / −12 lines, NP by +237 / −150,
SCD by +6,286 / −2,818, SCP by +922 / −655 and SCA by +226 / −170.

| Script | Lines | Changed | Ignoring whitespace |
| --- | --- | --- | --- |
| MJ (4 files) | 332 | none | none |
| NP (7 files) | 1,917 | +113 / −68 | +82 / −37 |
| SCD (8 files) | 15,158 | +2,865 / −1,550 | +2,021 / −702 |
| SCP (5 owner files) | 3,598 | +583 / −491 | +211 / −118 |
| SCA (6 owner files) | 2,215 | +76 / −64 | +67 / −55 |

What is left:

- A line longer than 120 is wrapped (NP has 8, SCD's older code many).
- A continuation you balanced by hand is packed again from the left: the first line is filled.
- Several fields on one line of a multi-line table are split, one per line (NP config
  `priority = 1, flash = 1,`), and a long inline table is spread one field per line.
- Two statements on one line inside a block that spans lines (`if t then name = t` / `elseif ...`)
  are split.
- Older code loses its trailing spaces and whitespace-only blank lines, and gets trailing commas and
  `t[#t + 1]` (most of SCD's and SCP's numbers).
- StyLua's own layout stays where a condition or a `for` iterator itself spans several lines
  (`for _, r in` / `ipairs(` / ... / `do`): 14 conditions and 10 loops in Crimson-Police.
- Files with backtick hashes (SCP client/registration.lua, client/evidence.lua) are not Lua 5.4, so
  StyLua cannot read them. The hard rules forbid backticks anyway.

Prettier changes MJ's `script.js` by +43 / −49 lines (+21 / −27 ignoring whitespace) and `style.css`
by +41 / −13: it spreads one-line `@keyframes` steps and multi-value `transition`s over several lines.

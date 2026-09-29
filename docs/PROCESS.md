# Crimson-Police · how work gets done

Crimson-Police is built by many AI agents: builders, reviewers, fixers and one integrator. This page is the
process every agent follows. Two things always outrank it: the Hard rules in `docs/SPEC.md`, and the
contracts in `docs/ARCHITECTURE.md` and `docs/CRIMSON_ARENA.md`.

## 1. One job, one tree

- **Every job gets its own worktree and branch**, made from the latest pushed commit:
  `git worktree add ../PoliceTablet-<job> -b <job> origin/<branch>`. No other agent writes in it. When a
  job runs agents in parallel, each agent gets its own worktree (`<job>-fix1`, `<job>-fix2`, ...).
- **Check the tree before you start.** `git status --short` shows only your job's files, and no other
  process is working in the tree (`ps -eo pid,args | grep <tree>`). If a tree is dirty with someone else's
  changes, stop and report it. Do not build on top of those changes.
- **Leave nothing running.** When a job ends (done, timed out or cancelled), its background runs are
  stopped before the tree is handed to the next job.
- **Scratch folders are per agent**: `scratchpad/<job>-<agent>/`. Never write into a folder that another
  agent uses. After `cp -a` of a worktree, run `rm <copy>/.git` straight away. The copied `.git` file
  points at the original worktree, so a git command in the copy would change the original's index.
- **Test runs stay out of each other's way.** `tests/run.lua` makes its own database for each run, so never
  set `CP_TEST_DB` to a shared name. Export `TMPDIR=<your scratch>/tmp` so temp files land in your folder.
  Clean up only your own leftovers.

## 2. The gate: one command before every commit

```
tools/check_all.sh
```

The steps are syntax, contracts, every `tools/lint_*.py` and other `tools/check_*.py` (today
`lint-fivem`), style, the three suites (database, files, shadow), tsc and build. `docs/TESTING.md` lists each
step, says how to set up a machine and explains how to read a failure. The whole gate takes about 1 min 40 s
on 4 cores; the three suites take about one minute of it (two specs at a time), the style check about 26 s.

- **Commit only on PASS.** Paste the gate's SUMMARY lines into the commit body. Do not type test counts
  by hand. The counts are deterministic (the same in every run and every storage mode), so a count that
  changes without a spec change is a finding.
- **No WIP commits on a shared branch.** Checkpoints stay on your job's branch and are squashed before
  the merge, and the squashed commit must pass the gate.
- **While you work, use a filter**: `lua5.4 tests/run.lua <name>`, then again with `--storage=files`. Run
  the full gate once, before you commit.
- **Files mode is not optional.** In database mode the harness hands modules the mysql CLI's values: 0/1
  for TINYINT(1), numbers for SUM and DECIMAL. Only files mode gives modules the types oxmysql gives in
  production (booleans, and strings for DECIMAL sums). A module that passes database mode alone can still
  break on a live server.
- **CI runs the same script on every push** (`.github/workflows/ci.yml`). When CI is red, fixing it comes
  before any other merge.

## 3. What to run and what to update, by change

| You changed | Run while you work | Update in the same commit |
| --- | --- | --- |
| A module or block (Lua) | its spec, in database and files mode | ARCHITECTURE §5 when a `CP.X.fn` is added or changes shape |
| SQL | its spec in all three modes; shadow must show 0 differences | the construct list in `modules/storage/memsql.lua` for a new SQL construct |
| An event, callback, action or NUI message | `check_contracts.py`, `lint_fivem.py` | ARCHITECTURE §8 or §9. The §8 list is complete, so every name goes in it. |
| Natives, net handlers, NUI focus, callbacks, entities or files (`os.*`) | `lint_fivem.py` | `tools/lint_baseline.txt`: delete the line of a bug you fixed (the lint calls it stale); add one only for a deliberate use, with its reason |
| A locale key | `check_contracts.py --merge` | your own `locales/parts/<slice>.json` only |
| `web/src` or `locales/parts` | `tsc --noEmit` | nothing: the integrator rebuilds `web/dist` (§4) |
| Any Lua or web source | `python3 tools/restyle.py <your files>` before the gate | nothing: the `style` step checks it |
| A Config key | the specs that read it | the SPEC config listing and `config/config.lua` |
| Behaviour the SPEC describes | - | SPEC (owner-approved only) and "Spec revisions" in the README |
| The harness or the runner | the full gate twice, and once with `CP_TEST_JOBS=1`: the per-spec counts must be identical | ARCHITECTURE §11, the runner's header and docs/TESTING.md |

## 4. Working in parallel without conflicts

- **Split the work by file before anyone starts.** The coordinator gives each fixer or builder a set of
  files, usually module folders, and each file has exactly one owner. If a fix needs someone else's
  file, send that owner a request (file, line, what and why). Do not edit their file yourself.
- **Generated files belong to the integrator:** `web/dist/**` with `build-stamp.json`, and
  `locales/en.json`. Fixers do not commit them. After the last merge, the integrator runs
  `npm run build` and `check_contracts.py --merge` once, then runs the gate. Every rebuild changes the
  hashed asset names in `web/dist`, so two fixers who both rebuild will always conflict.
- **Merge one branch at a time, and run the gate after each merge.** If a merge fails the gate, back it
  out and return it to its owner. Nobody fixes it on top.
- **A review covers one branch**: its diff plus its gate SUMMARY. Each finding gives the file and line,
  the failing scenario, and the rule or contract it breaks. Each fix lands with a test that fails without
  the fix.
- **A fix round ends with one gate run on the merged tree.** Each fixer's own green run is not enough.
- **Never run the gate on a tree that someone else is editing.** Its results show a mix of two states
  and prove nothing.

## 5. Keeping the docs true

- **Contract docs change in the same commit as the code.** That means ARCHITECTURE §5, §8, §9 and §10,
  CRIMSON_ARENA, and the SPEC config listing. A reviewer rejects a commit that adds a protocol name
  without its §8 or §9 entry.
- **`docs/notes/*.md` are history.** Each slice wrote its note at build time, and nobody keeps the notes
  up to date. When a note disagrees with ARCHITECTURE, ARCHITECTURE wins. Fix ARCHITECTURE, not the note.
- **Commit messages** say what changed and why. The only numbers in them come from the gate.

## 6. Keeping the style applied

- The style is `docs/STYLE.md`, and its only sources are the owner's sc-* scripts. Crimson-Arena and
  Renewed-Banking show what not to write: no CAPS-led `--[[ ]]` header essays, no `---` doc comments, no
  PascalCase module tables, no heavy commenting.
- **The tree is formatted, and the gate keeps it so.** The `style` step runs `tools/restyle.py --check` and
  fails on any file the formatter would change. Run `python3 tools/restyle.py <your files>` before the gate,
  and commit what it changes. Do not hand-edit the layout it produces, and do not run StyLua or Prettier on
  their own (docs/STYLE.md, "Keeping the style").
- **A change to the formatter restyles the whole tree:** `tools/restyle.py`, `stylua.toml`,
  `web/.prettierrc.json`, or another StyLua or Prettier version. Make it one commit, by one job, while no
  other job runs, because it touches nearly every file and conflicts with every other branch.
- Style never renames a contract name: events, `CP.X.fn`, NUI names, locale and config keys, and columns.

## 7. What the gate does not catch yet

Until these gaps are closed, look for them in review.

- **Randomness in specs.** Run seeds are still random (`U.uuid`); a spec may only branch on them in its
  setup, never around a check. `int_engine_spec` did (172 or 173 assertions) and now forces its Time Crunch
  roll. If a spec fails once and then passes, treat the failure as a real finding. `CP_TEST_ORDER`,
  `CP_TEST_CLOCK`, `CP_TEST_NOW` and `CP_TEST_TZ` (docs/TESTING.md) help to reproduce it.
- **FiveM pitfalls the lint cannot see.** `lint-fivem` catches wrong-side natives, `source` read late,
  `os`/`io` on the client, unguarded focus release, raising callback awaits, entities without an orphan mode,
  `os.rename` answers, `os.execute` on the server and the Crimson-Arena natives. Review still has to catch
  `%d` on a value that can be fractional, code acting on a state bag another client can write (an entity's
  owner writes its bag), and hidden server rolls (seeds) sent to clients. A new `tools/lint_<name>.py` or `tools/check_<name>.py` joins the
  gate automatically.
- **Protocol names missing from ARCHITECTURE §8.** `check_contracts.py` compares code with code, not with
  the doc.
- **Timing budgets in `storage_spec`.** On a busy machine, or next to other specs, they can fail. Rerun
  the spec alone (`lua5.4 tests/run.lua storage_spec --jobs=1`) before you call it a regression.
- **FXServer file behaviour.** The harness runs plain Lua, where `os.execute` works and `os.rename` answers
  the right way round; FXServer refuses the first and inverts the second on Linux. `lint-fivem` guards the
  known uses (FX07, FX08); anything else that touches files needs a test on a real server.

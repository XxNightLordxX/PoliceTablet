# Changelog

Every version of Crimson-Police, newest first. The owner's guide is the `README.md` of the repository; what to
check in game after an update is in `docs/IN_GAME_CHECKLIST.md`.

## 1.0.0 (not released yet)

The first version for sale.

- **Works on any Qbox city.** Dispatch, ambulance, banking and police scripts are optional and found by themselves
  (`Config.Integrations`: sc-dispatch or ps-dispatch, sc-ambulance or qbx_ambulancejob, Renewed-Banking, sc-police or
  qbx_policejob); a feature that needs a missing script turns itself off and says why.
- **Generic starting config** in `config/examples/generic.lua`: qbx_core's own police jobs (`police`, `bcso`,
  `sasp`), every script on `auto`. Copy it over `config/config.lua` for a fresh city.
- **First-start setup** on Admin UI -> Home (`Config.AdminUi.setupScreen`): departments and their Qbox jobs,
  supervisor grades, desks, storage, the scripts found and a preset. Every answer is a normal setting. Skippable.
- **Guided tours** (`Config.Training`): each tablet shows a new character around on first open (Officer, Supervisor,
  Admin UI, criminal tablet), saved per character; the **?** in every header, the Tours lists and `/crimsonhelp`
  replay them. Admin UI -> Home's **Setup checklist** ticks off what a new city still has to do. The first mission
  run shows short tips beside the HUD (the HUD, objectives, the GPS line, the result card) with no clicks needed.
- **Escrow-friendly layout:** `config/`, `locales/` and `missions/builtin/` stay readable and editable
  (`escrow_ignore` in `fxmanifest.lua`); custom missions are files written in game; `web/dist` ships built.
- NPC missions (18 plus a Weekly Boss), mission calls, police actions and custody, the Mission Builder, units and
  Cross-Department Missions, recognition, leaderboards and seasons, real suspects, cash and item rewards, and an
  Admin UI where every setting can be changed in game.

# Freeze fix · the downed follow-up's end, the screen safety net, the tablet while down, FX10

What the freeze investigation added (the owner's report: "after my latest call my screen froze with no F8 errors or
crash log", after a down on the way to a Suspicious Activity start that someone else revived before the 15 s
pick-up). Crimson-Police left nothing on in that sequence (no fade, no overlay, no focus, no loop without a Wait);
these changes close the gaps the investigation found on the way, so no Crimson-Police state can outlive a run or a
downed follow-up, and give the owner a command that says what holds the screen.

## Downed (modules/downed)

- Server: every way an entry leaves the pending stages sends `client:downedEnded` (runId, reason) once: `Finish`
  (`client done`, `client gave up`, `timeout`), `CancelEntry` (every reason: `recovered`, `in_arena`, `no_position`,
  `revive_refused`, `client_abort`, `error`, `unload`, …) and the EMS hand-over (`ems`). Before, a cancel before
  `client:pickup` (stage `pickup_wait`, the owner's case) told the client nothing.
- Client: `faded` / `overlaid` say what of the pick-up may still be on screen (set before the call that shows it,
  cleared after the one that removes it). `client:downedEnded` stops a pick-up still running for that run (as
  `client:pickupCancel`) or undoes what is left; `CP.Downed.restore(why)` is the same safety net for other callers
  (a no-op while a pick-up runs), and `modules/runs` calls it at every run cleanup.
- The pick-up thread can no longer die with `active` set: the abort in the error path runs in pcall, the thread then
  clears `active` and restores the screen whatever happened. `server:pickupDone` goes first and only once.

## Tablet (modules/tablet, web)

- Down (metadata `isdead` / `inlaststand`, or a dead ped): the Officer and Supervisor UIs refuse to open (`err.downed`)
  and close within 0.5 s when the officer goes down. The owner's own rule in sc-dispatch's bill UI: never hold the
  NUI focus while the death or last stand screen is up.
- `open` carries `seq`; the NUI confirms with `opened { seq }` once the UI rendered. With `ready { acks = true }` an
  unconfirmed open closes after 6 s and releases the focus (a crashed page must not hold the cursor). An older web
  build (no `acks`) is never closed for it.
- web: `QuietBoundary` (renders nothing for the broken part) around the HUD column, HUD, result card, debug overlay,
  overlays, toasts and each layout; a crashed layout calls `close`; an `open` that cannot be shown calls `close`; the
  root boundary calls `close` and mounts the app again after 2 s (then sends `ready` again, at most 3 times).

## Diagnostics (modules/diag, client)

`CrimsonPoliceState` (F8) prints the screen, focus, camera, control, frozen, down and vehicle state and what of it
is Crimson-Police's; `CrimsonPoliceState unstick` releases only Crimson-Police's own.

## Lint FX10 (tools/lint_fivem.py, tools/lua_flow.py)

A while / repeat loop where one pass can go round with no Wait, nothing moves the condition on every pass, and the
condition waits on game state (a native, a function of the resource that calls one, or a variable the body sets from
one); an ipairs loop that appends to its own table. `tools/lua_flow.py` is a Lua 5.4 parser with the flow analysis
(yields: Wait, Citizen.Wait, Citizen.Await, coroutine.yield, lib.callback.await and every function of the resource
that yields on all paths; ox_lib's progressBar / skillCheck / request* do not count, they return at once when busy).
0 hits in the resource (83 files, 43 bounded and 63 pure-Lua loops, all fine); on sc-dispatch it finds the one real
hang, `StopTabletAnimation`'s `while obj and DoesEntityExist(obj)` loop. tests/freeze_spec.lua checks it on
`tests/fixtures/lint/fx10_loops.lua`.

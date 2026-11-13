# Measured Lua coverage

Written by `tools/lua_coverage/report.py` (the opt-in check_all step `lua-coverage`; docs/dev/TESTING.md
"Measured Lua coverage"). Every lua5.4 process of both suites (database and files mode, the fixture
processes the specs start included) ran under a line hook. Line level only: the not-taken side of an `if`
with no `else` and the operands of a short-circuit are not measured. Left out: web/, missions/builtin/
(mission data), config/examples/, fxmanifest.lua and items/ox_inventory_items.lua (paste-in data).

## Totals

| | |
|---|---:|
| processes measured | 448 |
| executable lines | 91428 |
| lines run | 87194 (95.4%) |
| functions never run | 199 (8 reviewed, 191 baseline, 0 not listed) |

## Files

| file | lines run | % |
|---|---:|---:|
| blocks/_kit/client.lua | 117 / 118 | 99.2 |
| blocks/checkpoint_route/client.lua | 286 / 296 | 96.6 |
| blocks/checkpoint_route/server.lua | 486 / 501 | 97.0 |
| blocks/escort/client.lua | 255 / 277 | 92.1 |
| blocks/escort/server.lua | 1002 / 1055 | 95.0 |
| blocks/field_contact/client.lua | 100 / 117 | 85.5 |
| blocks/field_contact/server.lua | 1179 / 1231 | 95.8 |
| blocks/flee_arrest/client.lua | 269 / 288 | 93.4 |
| blocks/flee_arrest/server.lua | 1267 / 1316 | 96.3 |
| blocks/hostile_waves/client.lua | 200 / 214 | 93.5 |
| blocks/hostile_waves/server.lua | 929 / 944 | 98.4 |
| blocks/interact_points/client.lua | 300 / 323 | 92.9 |
| blocks/interact_points/server.lua | 777 / 821 | 94.6 |
| blocks/live_response/client.lua | 61 / 69 | 88.4 |
| blocks/live_response/server.lua | 269 / 269 | 100.0 |
| blocks/process_scene/client.lua | 126 / 163 | 77.3 |
| blocks/process_scene/server.lua | 326 / 335 | 97.3 |
| blocks/protect_rescue/client.lua | 185 / 200 | 92.5 |
| blocks/protect_rescue/server.lua | 566 / 589 | 96.1 |
| blocks/pursuit/client.lua | 417 / 528 | 79.0 |
| blocks/pursuit/server.lua | 1907 / 1989 | 95.9 |
| blocks/search_area/client.lua | 295 / 319 | 92.5 |
| blocks/search_area/server.lua | 905 / 940 | 96.3 |
| blocks/skill_check/client.lua | 306 / 329 | 93.0 |
| blocks/skill_check/server.lua | 469 / 487 | 96.3 |
| config/blocks.lua | 165 / 165 | 100.0 |
| config/config.lua | 1409 / 1409 | 100.0 |
| modules/access/access.lua | 546 / 575 | 95.0 |
| modules/access/client/access.lua | 85 / 87 | 97.7 |
| modules/access/client/options.lua | 166 / 167 | 99.4 |
| modules/access/client/tablet.lua | 860 / 899 | 95.7 |
| modules/access/client/training.lua | 17 / 17 | 100.0 |
| modules/access/options.lua | 111 / 115 | 96.5 |
| modules/access/permissions.lua | 222 / 224 | 99.1 |
| modules/access/tablet.lua | 730 / 751 | 97.2 |
| modules/access/training.lua | 173 / 177 | 97.7 |
| modules/admin/admin.lua | 2199 / 2321 | 94.7 |
| modules/admin/adminhome.lua | 127 / 127 | 100.0 |
| modules/admin/adminkit.lua | 706 / 753 | 93.8 |
| modules/admin/client/diag.lua | 88 / 93 | 94.6 |
| modules/admin/client/settings.lua | 44 / 45 | 97.8 |
| modules/admin/confighealth.lua | 311 / 315 | 98.7 |
| modules/admin/settings.lua | 3696 / 3810 | 97.0 |
| modules/admin/setup.lua | 288 / 294 | 98.0 |
| modules/admin/sysadmin.lua | 1798 / 1855 | 96.9 |
| modules/dispatch/alerts.lua | 422 / 455 | 92.7 |
| modules/dispatch/calls.lua | 307 / 320 | 95.9 |
| modules/dispatch/client/missioncalls.lua | 43 / 45 | 95.6 |
| modules/dispatch/missioncalls.lua | 1853 / 1890 | 98.0 |
| modules/map/client/markers.lua | 715 / 724 | 98.8 |
| modules/map/markers.lua | 300 / 300 | 100.0 |
| modules/missions/builder.lua | 3734 / 3925 | 95.1 |
| modules/missions/client/builder.lua | 1805 / 1906 | 94.7 |
| modules/missions/client/missions.lua | 51 / 51 | 100.0 |
| modules/missions/client/testing.lua | 647 / 698 | 92.7 |
| modules/missions/missions.lua | 1251 / 1360 | 92.0 |
| modules/missions/testing.lua | 1715 / 1823 | 94.1 |
| modules/money/cash.lua | 1094 / 1196 | 91.5 |
| modules/money/engine.lua | 116 / 121 | 95.9 |
| modules/money/featurerewards.lua | 309 / 317 | 97.5 |
| modules/money/payments.lua | 876 / 903 | 97.0 |
| modules/money/payouts.lua | 567 / 605 | 93.7 |
| modules/money/rewards.lua | 1069 / 1109 | 96.4 |
| modules/npc/client/custody.lua | 112 / 195 | 57.4 |
| modules/npc/client/npc.lua | 1614 / 1741 | 92.7 |
| modules/npc/client/npccombat.lua | 113 / 119 | 95.0 |
| modules/npc/custody.lua | 1663 / 1688 | 98.5 |
| modules/npc/npc.lua | 967 / 998 | 96.9 |
| modules/npc/npccombat.lua | 104 / 106 | 98.1 |
| modules/progression/challenge.lua | 1665 / 1727 | 96.4 |
| modules/progression/events.lua | 555 / 582 | 95.4 |
| modules/progression/goals.lua | 266 / 276 | 96.4 |
| modules/progression/leaderboard.lua | 1320 / 1375 | 96.0 |
| modules/progression/profile.lua | 1041 / 1090 | 95.5 |
| modules/progression/scoring.lua | 1079 / 1142 | 94.5 |
| modules/realplayers/client/crimtab.lua | 94 / 141 | 66.7 |
| modules/realplayers/client/livecrime.lua | 68 / 68 | 100.0 |
| modules/realplayers/client/volunteers.lua | 185 / 205 | 90.2 |
| modules/realplayers/conduct.lua | 282 / 286 | 98.6 |
| modules/realplayers/crimtab.lua | 200 / 201 | 99.5 |
| modules/realplayers/livecrime.lua | 701 / 720 | 97.4 |
| modules/realplayers/match.lua | 582 / 597 | 97.5 |
| modules/realplayers/opponents.lua | 803 / 819 | 98.0 |
| modules/realplayers/pairs.lua | 686 / 706 | 97.2 |
| modules/realplayers/proof.lua | 372 / 380 | 97.9 |
| modules/realplayers/saved.lua | 231 / 240 | 96.2 |
| modules/realplayers/staff.lua | 517 / 533 | 97.0 |
| modules/realplayers/surrender.lua | 218 / 224 | 97.3 |
| modules/realplayers/volunteers.lua | 628 / 635 | 98.9 |
| modules/review/anticheat.lua | 440 / 454 | 96.9 |
| modules/review/corrections.lua | 1257 / 1333 | 94.3 |
| modules/review/disputes.lua | 459 / 484 | 94.8 |
| modules/review/flagged.lua | 187 / 191 | 97.9 |
| modules/review/history.lua | 103 / 105 | 98.1 |
| modules/review/queue.lua | 190 / 193 | 98.4 |
| modules/review/reviewrules.lua | 125 / 130 | 96.2 |
| modules/runs/client/downed.lua | 123 / 137 | 89.8 |
| modules/runs/client/route.lua | 343 / 366 | 93.7 |
| modules/runs/client/runs.lua | 487 / 510 | 95.5 |
| modules/runs/client/spawn.lua | 501 / 507 | 98.8 |
| modules/runs/downed.lua | 313 / 326 | 96.0 |
| modules/runs/draw.lua | 1351 / 1385 | 97.5 |
| modules/runs/route.lua | 393 / 410 | 95.9 |
| modules/runs/runs.lua | 4020 / 4108 | 97.9 |
| modules/runs/scaling.lua | 149 / 154 | 96.8 |
| modules/runs/spawn.lua | 323 / 338 | 95.6 |
| modules/supervisor/deptcontrols.lua | 686 / 735 | 93.3 |
| modules/supervisor/fieldtraining.lua | 382 / 400 | 95.5 |
| modules/supervisor/happyhour.lua | 201 / 204 | 98.5 |
| modules/supervisor/livectl.lua | 735 / 748 | 98.3 |
| modules/supervisor/missionban.lua | 241 / 245 | 98.4 |
| modules/supervisor/notices.lua | 309 / 316 | 97.8 |
| modules/supervisor/restrictions.lua | 208 / 212 | 98.1 |
| modules/supervisor/supawards.lua | 112 / 112 | 100.0 |
| modules/supervisor/today.lua | 45 / 45 | 100.0 |
| modules/system/client/ambulance.lua | 47 / 56 | 83.9 |
| modules/system/client/qbx.lua | 55 / 58 | 94.8 |
| modules/system/integrations/crimson_contracts.lua | 117 / 117 | 100.0 |
| modules/system/integrations/integrations.lua | 344 / 350 | 98.3 |
| modules/system/integrations/ps_dispatch.lua | 75 / 80 | 93.8 |
| modules/system/integrations/qbx.lua | 470 / 486 | 96.7 |
| modules/system/integrations/qbx_ambulancejob.lua | 24 / 24 | 100.0 |
| modules/system/integrations/qbx_policejob.lua | 29 / 29 | 100.0 |
| modules/system/integrations/renewed_banking.lua | 125 / 128 | 97.7 |
| modules/system/integrations/sc_ambulance.lua | 48 / 48 | 100.0 |
| modules/system/integrations/sc_dispatch.lua | 158 / 159 | 99.4 |
| modules/system/integrations/sc_police.lua | 56 / 56 | 100.0 |
| modules/system/memsql.lua | 6553 / 7309 | 89.7 |
| modules/system/migrations.lua | 245 / 279 | 87.8 |
| modules/system/schedule.lua | 346 / 349 | 99.1 |
| modules/system/storage.lua | 166 / 189 | 87.8 |
| modules/teams/client/teams.lua | 80 / 95 | 84.2 |
| modules/teams/common.lua | 28 / 34 | 82.4 |
| modules/teams/operations.lua | 1241 / 1304 | 95.2 |
| modules/teams/units.lua | 1169 / 1180 | 99.1 |
| shared/init.lua | 288 / 294 | 98.0 |
| shared/lib.lua | 428 / 432 | 99.1 |
| shared/locale.lua | 162 / 166 | 97.6 |
| shared/net.lua | 193 / 199 | 97.0 |
| shared/npccombat.lua | 218 / 218 | 100.0 |
| shared/options.lua | 178 / 180 | 98.9 |
| shared/options_board.lua | 31 / 31 | 100.0 |
| shared/options_dispatch.lua | 45 / 45 | 100.0 |
| shared/options_hud.lua | 6 / 6 | 100.0 |
| shared/options_look.lua | 4 / 4 | 100.0 |
| shared/options_map.lua | 5 / 5 | 100.0 |
| shared/options_popups.lua | 19 / 19 | 100.0 |
| shared/options_run.lua | 5 / 5 | 100.0 |
| shared/options_sounds.lua | 4 / 4 | 100.0 |
| shared/options_unit.lua | 2 / 2 | 100.0 |
| shared/twists.lua | 77 / 77 | 100.0 |
| shared/utils.lua | 668 / 682 | 97.9 |
| shared/weapons.lua | 122 / 122 | 100.0 |

## Functions that never ran

Each one is in tools/lua_coverage/allow.txt with the reason it is safe unrun, or `baseline`
(measured unrun on 2026-11-13, review pending; give it a test or a reason).

| file:line | function | why |
|---|---|---|
| blocks/checkpoint_route/client.lua:77 | `local function Fmt(seconds)` | baseline |
| blocks/checkpoint_route/server.lua:683 | `onEntityDead = function(ctx, netId, killerSrc)` | baseline |
| blocks/escort/client.lua:404 | `hostChanged = function(ctx, isHost)` | baseline |
| blocks/field_contact/client.lua:69 | `local function ReportOnce(S, kind, netId)` | baseline |
| blocks/field_contact/client.lua:170 | `release = function(ctx, netId)` | baseline |
| blocks/field_contact/client.lua:175 | `hostChanged = function(ctx, isHost)` | baseline |
| blocks/flee_arrest/client.lua:423 | `hostChanged = function(ctx, isHost)` | baseline |
| blocks/hostile_waves/client.lua:343 | `hostChanged = function(ctx, isHost)` | baseline |
| blocks/interact_points/client.lua:53 | `local states = Kit.states(function(ctx) return type(ctx.state) == 'table' and ctx.state or {} end, function(st` | baseline |
| blocks/interact_points/server.lua:1065 | `onEntityDead = function(ctx, netId, killerSrc)` | baseline |
| blocks/live_response/client.lua:42 | `onSelect = function() TriggerServerEvent(CP.e('server:liveTalkDown')) end,` | baseline |
| blocks/process_scene/client.lua:24 | `local states = Kit.states(function() return { bodies = {}, targets = {}, alive = true } end, function(S)` | baseline |
| blocks/process_scene/client.lua:52 | `local function Info(S, netId)` | baseline |
| blocks/process_scene/client.lua:59 | `pcall(function() exports.ox_target:removeLocalEntity(ent, names) end)` | baseline |
| blocks/process_scene/client.lua:69 | `local function AddBodyOptions(S, b)` | baseline |
| blocks/process_scene/client.lua:73 | `local ok = Kit.target(BLOCK, function()` | baseline |
| blocks/process_scene/client.lua:80 | `canInteract = function()` | baseline |
| blocks/process_scene/client.lua:84 | `onSelect = function() CreateThread(function() Step(S, 'tag', b.netId) end) end,` | baseline |
| blocks/process_scene/client.lua:84 | `onSelect = function() CreateThread(function() Step(S, 'tag', b.netId) end) end,` | baseline |
| blocks/process_scene/client.lua:91 | `canInteract = function()` | baseline |
| blocks/process_scene/client.lua:95 | `onSelect = function() CreateThread(function() Step(S, 'bag', b.netId) end) end,` | baseline |
| blocks/process_scene/client.lua:95 | `onSelect = function() CreateThread(function() Step(S, 'bag', b.netId) end) end,` | baseline |
| blocks/process_scene/client.lua:124 | `local ok = Kit.target(BLOCK, function() exports.ox_target:addLocalEntity(ent, { ReleaseOption(S) }) end)` | baseline |
| blocks/process_scene/server.lua:446 | `onParticipantLeft = function(ctx, src)` | baseline |
| blocks/protect_rescue/client.lua:305 | `hostChanged = function(ctx, isHost)` | baseline |
| blocks/pursuit/client.lua:189 | `local function ReportOnce(S, kind, netId, extra)` | baseline |
| blocks/pursuit/client.lua:297 | `local function TaskCruise(S, v, veh, driver, force)` | baseline |
| blocks/pursuit/client.lua:324 | `local function PullOver(S, v, veh, driver)` | baseline |
| blocks/pursuit/client.lua:342 | `local function Ram(S, v, veh, driver)` | baseline |
| blocks/pursuit/server.lua:352 | `local function WeaponsAllowed(list, allowed)` | baseline |
| blocks/pursuit/server.lua:437 | `local function HealthRatio(p)` | baseline |
| blocks/search_area/client.lua:317 | `local function ReportOnce(S, kind, netId)` | baseline |
| blocks/search_area/client.lua:481 | `hostChanged = function(ctx, isHost)` | baseline |
| blocks/skill_check/client.lua:46 | `local states = Kit.states(function(ctx) return type(ctx.state) == 'table' and ctx.state or {} end, function(st` | baseline |
| blocks/skill_check/client.lua:286 | `canInteract = function()` | baseline |
| blocks/skill_check/client.lua:414 | `local function SetbackEffect(ctx, st, data)` | baseline |
| blocks/skill_check/server.lua:617 | `onEntityDead = function(ctx, netId, killerSrc)` | baseline |
| modules/access/client/tablet.lua:325 | `function T.openUi()` | baseline |
| modules/access/client/tablet.lua:1342 | `CreateThread(function()` | baseline |
| modules/admin/admin.lua:356 | `local function FlagLabel(reason)` | baseline |
| modules/admin/admin.lua:2499 | `local function OnlineCitizenids()` | baseline |
| modules/admin/adminkit.lua:322 | `function Kit.weekStart(ts)` | baseline |
| modules/admin/adminkit.lua:488 | `function Kit.jobs(opts)` | baseline |
| modules/admin/client/diag.lua:116 | `RegisterNetEvent(CP.e('client:diagUnstick'), function()` | baseline |
| modules/admin/client/diag.lua:121 | `RegisterNetEvent(CP.e('client:diagState'), function(token)` | baseline |
| modules/admin/settings.lua:1266 | `local function skipTo(e)` | baseline |
| modules/admin/settings.lua:2126 | `known = function(id)` | baseline |
| modules/admin/settings.lua:2134 | `known = function(id)` | baseline |
| modules/admin/settings.lua:2141 | `known = function(id)` | baseline |
| modules/admin/sysadmin.lua:89 | `local function Now()` | baseline |
| modules/admin/sysadmin.lua:162 | `local function WriteJson(path, v)` | baseline |
| modules/admin/sysadmin.lua:2459 | `Kit.callback('admin:getClientState', 'playerSupport', function(ctx)` | baseline |
| modules/dispatch/alerts.lua:255 | `function A.onInArena(fn)` | baseline |
| modules/dispatch/client/missioncalls.lua:20 | `local function Foreign(v)` | baseline |
| modules/map/client/markers.lua:1045 | `function M.partCount()` | baseline |
| modules/missions/builder.lua:1778 | `local function ShippedLocationValue(base, key, v)` | baseline |
| modules/missions/builder.lua:5191 | `b[listKey] = U.filter(b[listKey] or {}, function(e)` | baseline |
| modules/missions/client/testing.lua:466 | `local function ToggleDebug(enabled)` | baseline |
| modules/missions/client/testing.lua:918 | `RegisterNetEvent(CP.e('client:inProgress'), function(runId)` | baseline |
| modules/missions/client/testing.lua:922 | `RegisterNetEvent(CP.e('client:runEnded'), function(runId)` | baseline |
| modules/missions/client/testing.lua:955 | `CP.Tablet.registerClientAction('toggleDebug', function(payload)` | baseline |
| modules/missions/missions.lua:1921 | `table.sort(out, function(a, b)` | baseline |
| modules/missions/testing.lua:125 | `local function WarnOnce(key, fmt, ...)` | baseline |
| modules/missions/testing.lua:499 | `local function ForgetInvite(id)` | baseline |
| modules/missions/testing.lua:800 | `local function KnownError(errKey, fallback)` | baseline |
| modules/missions/testing.lua:2192 | `table.sort(out, function(a, b)` | baseline |
| modules/money/cash.lua:1210 | `return RunLocked(row.citizenid, function() return CapRestLocked(row, bd, rowId, rest) end, function()` | baseline |
| modules/money/cash.lua:1393 | `return RunLocked(row.citizenid, function() return ClawbackLocked(row, rowId, n) end, function()` | baseline |
| modules/npc/client/custody.lua:56 | `local function EntityFromNet(netId, ms)` | baseline |
| modules/npc/client/custody.lua:68 | `local function Control(ent, ms)` | baseline |
| modules/npc/client/custody.lua:125 | `function Custody.cancel()` | baseline |
| modules/npc/client/custody.lua:134 | `RegisterNetEvent('crimson-police:client:contactConfirm', function(data)` | baseline |
| modules/npc/client/custody.lua:136 | `CreateThread(function()` | baseline |
| modules/npc/client/custody.lua:171 | `CP.Tablet.registerClientAction('contactAction', function(payload)` | baseline |
| modules/npc/client/custody.lua:185 | `local function RoadPoint(args)` | baseline |
| modules/npc/client/custody.lua:207 | `lib.callback.register(ROAD_CALLBACK, function(args)` | baseline |
| modules/npc/client/custody.lua:221 | `local function DriveTo(driver, veh, p)` | baseline |
| modules/npc/client/custody.lua:225 | `local function LoadCar(veh, car)` | baseline |
| modules/npc/client/custody.lua:233 | `RegisterNetEvent('crimson-police:client:serviceVehicle', function(data)` | baseline |
| modules/npc/client/custody.lua:239 | `CreateThread(function()` | baseline |
| modules/npc/client/custody.lua:275 | `AddEventHandler('onResourceStop', function(res)` | baseline |
| modules/npc/client/npc.lua:1087 | `function ACTIONS.followPed(ped, a)` | baseline |
| modules/npc/client/npc.lua:1104 | `function ACTIONS.stand(ped, a)` | baseline |
| modules/npc/client/npc.lua:1113 | `function ACTIONS.leave(ped, a)` | baseline |
| modules/npc/client/npc.lua:2098 | `onSelect = function(data)` | baseline |
| modules/npc/client/npc.lua:2234 | `local chain = RunBags(function(b)` | baseline |
| modules/progression/profile.lua:648 | `local function IssuerRole(src)` | baseline |
| modules/realplayers/client/crimtab.lua:112 | `function C.refresh(screen)` | baseline |
| modules/realplayers/client/crimtab.lua:119 | `CreateThread(function()` | baseline |
| modules/realplayers/client/crimtab.lua:137 | `RegisterNUICallback('crimtabClose', function(_, cb)` | baseline |
| modules/realplayers/client/crimtab.lua:143 | `RegisterNUICallback('crimtabAnswered', function(body, cb)` | baseline |
| modules/realplayers/client/crimtab.lua:157 | `RegisterNetEvent(CP.e('client:crimtabClose'), function()` | baseline |
| modules/realplayers/client/crimtab.lua:165 | `RegisterNetEvent(CP.e('client:volunteerCase'), function(s)` | baseline |
| modules/realplayers/client/crimtab.lua:173 | `exports('useCriminalTablet', function(data)` | baseline |
| modules/realplayers/client/crimtab.lua:178 | `CreateThread(function() C.open() end)` | baseline |
| modules/realplayers/client/crimtab.lua:188 | `RegisterCommand(cmd, function()` | baseline |
| modules/realplayers/client/crimtab.lua:189 | `CreateThread(function()` | baseline |
| modules/realplayers/client/crimtab.lua:202 | `AddEventHandler('onResourceStop', function(res)` | baseline |
| modules/realplayers/client/volunteers.lua:87 | `onSelect = function()` | baseline |
| modules/realplayers/client/volunteers.lua:207 | `RegisterNetEvent(CP.e('client:volunteerAskClose'), function(token)` | baseline |
| modules/realplayers/client/volunteers.lua:244 | `RegisterNetEvent(CP.e('client:volunteerArea'), function(a)` | baseline |
| modules/realplayers/client/volunteers.lua:267 | `AddEventHandler('onResourceStop', function(res)` | baseline |
| modules/realplayers/livecrime.lua:805 | `exports('GetAvailablePolice', function()` | baseline |
| modules/realplayers/opponents.lua:793 | `table.sort(out, function(a, b)` | baseline |
| modules/realplayers/pairs.lua:304 | `CreateThread(function()` | baseline |
| modules/review/anticheat.lua:469 | `ctx.combat = function(acc, armour)` | baseline |
| modules/review/corrections.lua:1124 | `local function LiftSuspension(ctx, citizenid)` | baseline |
| modules/runs/client/downed.lua:215 | `AddEventHandler('onResourceStop', function(res)` | baseline |
| modules/runs/client/route.lua:492 | `RegisterNetEvent(CP.e('client:participants'), function(runId, list)` | baseline |
| modules/runs/client/route.lua:529 | `AddEventHandler('onResourceStop', function(res)` | baseline |
| modules/runs/client/runs.lua:69 | `function Runs.adoptedBy(netId)` | baseline |
| modules/runs/runs.lua:447 | `function Runs.host(run)` | baseline |
| modules/runs/runs.lua:1782 | `local ok = pcall(function() Entity(entity).state:set('cp', bag, true) end)` | baseline |
| modules/runs/runs.lua:5598 | `exports('IsOnMission', function(src)` | baseline |
| modules/runs/runs.lua:5871 | `AddEventHandler('onResourceStart', function(resource)` | baseline |
| modules/runs/scaling.lua:237 | `relaxes = function(v, c)` | baseline |
| modules/runs/spawn.lua:115 | `local ok = pcall(function() Entity(a.entity).state:set('cp', nb, true) end)` | baseline |
| modules/supervisor/deptcontrols.lua:70 | `local function Same(a, b)` | baseline |
| modules/supervisor/livectl.lua:119 | `local function DeptShort(key)` | baseline |
| modules/system/client/ambulance.lua:82 | `RegisterNetEvent(CP.e('client:revive'), function()` | baseline |
| modules/system/integrations/ps_dispatch.lua:116 | `AddEventHandler('onResourceStart', function(res)` | baseline |
| modules/system/integrations/qbx.lua:447 | `function Q.characterExists(citizenid)` | baseline |
| modules/system/memsql.lua:209 | `local function DtoaSig(x, n)` | baseline |
| modules/system/memsql.lua:215 | `local function DtoaFix(x, n)` | baseline |
| modules/system/memsql.lua:252 | `Gcvt = function(x, width)` | baseline |
| modules/system/memsql.lua:513 | `NumTime = function(nr, hasFrac)` | baseline |
| modules/system/memsql.lua:755 | `BinOrderKey = function(v)` | baseline |
| modules/system/memsql.lua:1348 | `local function SyntaxError(sql, p)` | baseline |
| modules/system/memsql.lua:2377 | `return function(v) return v and Rescale(v, fs, ts) end` | baseline |
| modules/system/memsql.lua:2385 | `if ft == 'str' then return function(v) return v and ParseDT(v) end end` | baseline |
| modules/system/memsql.lua:2387 | `if ft == 'dt' then return function(v) return v and Midnight(v) end end` | baseline |
| modules/system/memsql.lua:2397 | `local function StrNumOf(ty)` | baseline |
| modules/system/memsql.lua:2399 | `if e then return function(v) return (e[v] or 0) + 0.0 end end` | baseline |
| modules/system/memsql.lua:2407 | `return function(v) if v == nil then return nil end return num(v) ~= 0 end` | baseline |
| modules/system/memsql.lua:2442 | `local function JsonContent(v)` | baseline |
| modules/system/memsql.lua:2509 | `local na = ta.jfun and function(v) return key(JsonContent(v)) end or key` | baseline |
| modules/system/memsql.lua:2510 | `local nb = (not ta.jfun) and function(v) return key(JsonContent(v)) end or key` | baseline |
| modules/system/memsql.lua:2511 | `return function(f)` | baseline |
| modules/system/memsql.lua:2684 | `return function(f) local r = f.up.up[si] if r then return r[ci] end return nil end` | baseline |
| modules/system/memsql.lua:2686 | `return function(f)` | baseline |
| modules/system/memsql.lua:2864 | `return function(f)` | baseline |
| modules/system/memsql.lua:2874 | `return function(f)` | baseline |
| modules/system/memsql.lua:3040 | `fn = function(f)` | baseline |
| modules/system/memsql.lua:3064 | `fn = function(f)` | baseline |
| modules/system/memsql.lua:3104 | `return function(f)` | baseline |
| modules/system/memsql.lua:3117 | `return function(f)` | baseline |
| modules/system/memsql.lua:3161 | `return function(f)` | baseline |
| modules/system/memsql.lua:3226 | `conds[i] = function(f) return tf(cf(f)) == true end` | baseline |
| modules/system/memsql.lua:3250 | `vals[i] = function(f) return cv(vf(f)) end` | baseline |
| modules/system/memsql.lua:3259 | `ef = function(f) return cv(e0(f)) end` | baseline |
| modules/system/memsql.lua:3295 | `return function(f)` | baseline |
| modules/system/memsql.lua:3302 | `return function(f)` | baseline |
| modules/system/memsql.lua:3565 | `FUNCS.IFNULL = function(node, sc)` | baseline |
| modules/system/memsql.lua:3708 | `return function(f)` | baseline |
| modules/system/memsql.lua:4299 | `return function(f) local v = fa(f) if v == nil then return nil end return -num(v) end,` | baseline |
| modules/system/memsql.lua:4305 | `return function(f) local v = fa(f) if v == nil then return nil end return -v end,` | baseline |
| modules/system/memsql.lua:4430 | `return function(f) local v = fn(f); return v ~= nil and num(v) ~= 0 end` | baseline |
| modules/system/memsql.lua:5156 | `return function(f)` | baseline |
| modules/system/memsql.lua:5164 | `return function(f)` | baseline |
| modules/system/memsql.lua:5283 | `fn = function(_, out)` | baseline |
| modules/system/memsql.lua:5422 | `updaters[s] = function(acc, fr)` | baseline |
| modules/system/memsql.lua:5445 | `updaters[s] = function(acc, fr)` | baseline |
| modules/system/memsql.lua:5472 | `updaters[s] = function(acc, fr)` | baseline |
| modules/system/memsql.lua:5480 | `updaters[s] = function(acc, fr)` | baseline |
| modules/system/memsql.lua:6381 | `STORE.reset = function(col)` | baseline |
| modules/system/memsql.lua:6389 | `local function TimeNumber(v, vt)` | baseline |
| modules/system/memsql.lua:6497 | `return function(v, rn, ign)` | baseline |
| modules/system/memsql.lua:6556 | `return function(v, rn, ign)` | baseline |
| modules/system/memsql.lua:6564 | `return function(v, rn, ign)` | baseline |
| modules/system/memsql.lua:6632 | `return function(v, rn, ign) if v == nil then return nil end return byIndex(v, rn, ign) end` | baseline |
| modules/system/memsql.lua:6641 | `return function(v, rn, ign)` | baseline |
| modules/system/memsql.lua:6831 | `__index = function(_, name)` | baseline |
| modules/system/memsql.lua:6833 | `return function() Unsupported('a column of the row in INSERT ... VALUES') end` | baseline |
| modules/system/memsql.lua:7188 | `local function LessLo(a, ai, b, bi) -- is lower bound a (inclusive ai) below b?` | baseline |
| modules/system/memsql.lua:7249 | `return function(v)` | baseline |
| modules/system/memsql.lua:7256 | `return function(v) return v end` | baseline |
| modules/system/memsql.lua:7258 | `if ty.t == 'dt' and cty.t == 'str' then return function(v) return ParseDT(v) or false end end` | baseline |
| modules/system/memsql.lua:7281 | `and function() return nil end` | baseline |
| modules/system/memsql.lua:7300 | `and function() return nil end` | baseline |
| modules/system/memsql.lua:7343 | `function()` | baseline |
| modules/system/migrations.lua:314 | `local function Warn(name, err)` | reviewed: a boot-failure path (a migration that fails); tools/db_check.sh covers the migrations on real servers |
| modules/system/storage.lua:115 | `local function UseResourceFiles(dir)` | reviewed: the resource-files fallback runs only when the io library is missing, which FXServer never does (storage.lua UseResourceFiles) |
| modules/system/storage.lua:118 | `local function rel(path)` | reviewed: the resource-files fallback runs only when the io library is missing, which FXServer never does (storage.lua UseResourceFiles) |
| modules/system/storage.lua:123 | `fs.read = function(path)` | reviewed: the resource-files fallback runs only when the io library is missing, which FXServer never does (storage.lua UseResourceFiles) |
| modules/system/storage.lua:128 | `fs.write = function(path, data)` | reviewed: the resource-files fallback runs only when the io library is missing, which FXServer never does (storage.lua UseResourceFiles) |
| modules/system/storage.lua:132 | `fs.exists = function(path) return fs.read(path) ~= nil end` | reviewed: the resource-files fallback runs only when the io library is missing, which FXServer never does (storage.lua UseResourceFiles) |
| modules/system/storage.lua:133 | `fs.remove = function(path) SaveResourceFile(res, rel(path), '', 0); return true end` | reviewed: the resource-files fallback runs only when the io library is missing, which FXServer never does (storage.lua UseResourceFiles) |
| modules/system/storage.lua:134 | `fs.rename = function(a, b)` | reviewed: the resource-files fallback runs only when the io library is missing, which FXServer never does (storage.lua UseResourceFiles) |
| modules/teams/client/teams.lua:45 | `function Units.lastInviteAt()` | baseline |
| modules/teams/client/teams.lua:115 | `RegisterCommand(READY_KEY, function()` | baseline |
| modules/teams/client/teams.lua:154 | `function Ops.last()` | baseline |
| modules/teams/client/teams.lua:158 | `RegisterNetEvent(CP.e('client:operation'), function(state, missionLabel, extra)` | baseline |
| modules/teams/operations.lua:901 | `function Ops.startNow(src)` | baseline |
| modules/teams/operations.lua:907 | `function Ops.relaunch(src)` | baseline |
| modules/teams/operations.lua:1089 | `function Ops.removeJoiner(src, target, reason)` | baseline |
| shared/init.lua:318 | `function CP.Blocks.all()` | baseline |
| shared/init.lua:433 | `function RegisterMission(def)` | baseline |
| shared/utils.lua:25 | `function U.inRange(x, lo, hi)` | baseline |
| shared/utils.lua:78 | `function U.map(list, fn)` | baseline |

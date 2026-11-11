-- The module layout: the 14 owner-approved modules, each a folder of named sub-files.

-- Each part is modules/<module>/<part>.lua (client parts in modules/<module>/client/<part>.lua). fxmanifest.lua
-- lists every file once, in the order the files have always loaded in, and the moved files use the shared library
-- (CP.Call, CP.Num) instead of their own copies.

local H = dofile('tests/harness.lua')

local function Read(path)
    local fh = io.open(H.root .. path, 'r')
    if not fh then return nil end
    local s = fh:read('a')
    fh:close()
    return s
end

local function Lines(cmd)
    local out = {}
    local p = io.popen('cd ' .. H.root .. ' && ' .. cmd)
    for line in p:lines() do out[#out + 1] = line end
    p:close()
    return out
end

-- ============================================================================
--                                THE 14 MODULES
-- ============================================================================

local MODULES = {
    'access',
    'admin',
    'dispatch',
    'map',
    'missions',
    'money',
    'npc',
    'progression',
    'realplayers',
    'review',
    'runs',
    'supervisor',
    'system',
    'teams',
}
local approved = {}
for _, m in ipairs(MODULES) do approved[m] = true end
local found = Lines('ls -1 modules')
H.eq(#found, #MODULES, 'modules/ holds 14 module folders (' .. table.concat(found, ' ') .. ')')
for _, m in ipairs(found) do H.ok(approved[m], 'modules/' .. m .. ' is an approved module') end

local OLD = {
    'permissions',
    'tablet',
    'options',
    'adminhome',
    'adminkit',
    'sysadmin',
    'settings',
    'confighealth',
    'diag',
    'route',
    'scaling',
    'spawn',
    'draw',
    'downed',
    'builder',
    'testing',
    'npccombat',
    'custody',
    'markers',
    'integrations',
    'deptcontrols',
    'livectl',
    'supawards',
    'suptoday',
}
for _, old in ipairs(OLD) do
    H.eq(#Lines('ls -d modules/' .. old .. ' 2>/dev/null'), 0, 'the old modules/' .. old .. ' folder is gone')
end
H.eq(#Lines('find modules -name server.lua -o -name client.lua'), 0, 'every module part is a named sub-file')

-- ============================================================================
--                      THE MANIFEST LISTS EVERY FILE ONCE
-- ============================================================================

local server, client = H.manifestScripts('server_scripts'), H.manifestScripts('client_scripts')
local seen = {}
for _, list in ipairs({ server, client }) do
    for _, f in ipairs(list) do seen[f] = (seen[f] or 0) + 1 end
end
for _, f in ipairs(Lines('find modules -name "*.lua" | sort')) do
    H.eq(seen[f], 1, 'fxmanifest lists ' .. f .. ' once')
end
for _, f in ipairs(client) do
    if f:sub(1, 8) == 'modules/' then H.ok(f:find('/client/', 1, true), 'a client file sits in client/: ' .. f) end
end
for _, f in ipairs(server) do
    if f:sub(1, 8) == 'modules/' then
        H.ok(not f:find('/client/', 1, true), 'a server file is not in client/: ' .. f)
    end
end

-- the order every file has always loaded in (storage first, CP.AdminKit before every module)
local ORDER = {
    'modules/system/memsql.lua',
    'modules/system/storage.lua',
    'modules/admin/adminkit.lua',
    'modules/system/migrations.lua',
    'modules/system/schedule.lua',
    'modules/access/access.lua',
    'modules/admin/admin.lua',
    'modules/admin/adminhome.lua',
    'modules/missions/builder.lua',
    'modules/admin/confighealth.lua',
    'modules/npc/custody.lua',
    'modules/supervisor/deptcontrols.lua',
    'modules/runs/downed.lua',
    'modules/runs/draw.lua',
    'modules/system/integrations/integrations.lua',
    'modules/system/integrations/crimson_contracts.lua',
    'modules/system/integrations/ps_dispatch.lua',
    'modules/system/integrations/qbx.lua',
    'modules/system/integrations/qbx_ambulancejob.lua',
    'modules/system/integrations/qbx_policejob.lua',
    'modules/system/integrations/renewed_banking.lua',
    'modules/system/integrations/sc_ambulance.lua',
    'modules/system/integrations/sc_dispatch.lua',
    'modules/system/integrations/sc_police.lua',
    'modules/supervisor/livectl.lua',
    'modules/map/markers.lua',
    'modules/missions/missions.lua',
    'modules/npc/npc.lua',
    'modules/npc/npccombat.lua',
    'modules/access/options.lua',
    'modules/access/permissions.lua',
    'modules/runs/route.lua',
    'modules/runs/runs.lua',
    'modules/runs/scaling.lua',
    'modules/admin/settings.lua',
    'modules/runs/spawn.lua',
    'modules/supervisor/supawards.lua',
    'modules/supervisor/today.lua',
    'modules/admin/sysadmin.lua',
    'modules/access/tablet.lua',
    'modules/missions/testing.lua',
    'modules/progression/challenge.lua',
    'modules/supervisor/fieldtraining.lua',
    'modules/review/anticheat.lua',
    'modules/realplayers/conduct.lua',
    'modules/dispatch/alerts.lua',
    'modules/teams/common.lua',
    'modules/money/engine.lua',
    'modules/money/rewards.lua',
}
local CLIENT_ORDER = {
    'modules/access/client/access.lua',
    'modules/missions/client/builder.lua',
    'modules/npc/client/custody.lua',
    'modules/admin/client/diag.lua',
    'modules/runs/client/downed.lua',
    'modules/system/client/qbx.lua',
    'modules/system/client/ambulance.lua',
    'modules/map/client/markers.lua',
    'modules/missions/client/missions.lua',
    'modules/npc/client/npc.lua',
    'modules/npc/client/npccombat.lua',
    'modules/access/client/options.lua',
    'modules/runs/client/route.lua',
    'modules/runs/client/runs.lua',
    'modules/admin/client/settings.lua',
    'modules/runs/client/spawn.lua',
    'modules/access/client/tablet.lua',
    'modules/missions/client/testing.lua',
    'modules/realplayers/client/crimtab.lua',
    'modules/dispatch/client/missioncalls.lua',
    'modules/teams/client/teams.lua',
}
for _, case in ipairs({ { 'server', server, ORDER }, { 'client', client, CLIENT_ORDER } }) do
    local at = {}
    for i, f in ipairs(case[2]) do at[f] = at[f] or i end
    local last = 0
    for _, f in ipairs(case[3]) do
        H.ok(at[f] and at[f] > last, case[1] .. ' load order keeps ' .. f .. ' in its place')
        last = at[f] or last
    end
end

-- ============================================================================
--                    THE SHARED LIBRARY, NOT PRIVATE COPIES
-- ============================================================================

local CALLS = {
    'access/tablet',
    'admin/adminkit',
    'admin/sysadmin',
    'admin/admin',
    'admin/adminhome',
    'runs/runs',
    'missions/testing',
    'npc/custody',
    'supervisor/fieldtraining',
    'supervisor/supawards',
    'supervisor/missionban',
    'supervisor/today',
    'supervisor/livectl',
    'supervisor/notices',
    'progression/profile',
    'progression/challenge',
    'progression/leaderboard',
    'review/anticheat',
    'review/disputes',
    'review/corrections',
    'review/queue',
    'dispatch/missioncalls',
    'map/markers',
}
for _, f in ipairs(CALLS) do
    local src = Read('modules/' .. f .. '.lua') or ''
    local body = src:match('local function Call%(modName, fnName, %.%.%.%)([^\n]*)')
    H.eq(body, ' return CP.Call(TAG, modName, fnName, ...) end', f .. ': Call is CP.Call')
end

-- FIN2: no module keeps its own copy of a library helper: the module check (CP.Has), the once-a-minute error line
-- (CP.errEvery), another resource's export in pcall (CP.Ext.call), the online source of a citizenid (CP.srcOf) or a
-- permission check with its missing-module guard (CP.can)
local COPIES = {
    { 'local function Has%(modName, fnName%)', 'Has is CP.Has' },
    { 'local function Has%(mod, fn%)', 'Has is CP.Has' },
    { 'errorLoggedAt%[', 'its error lines go through CP.errEvery' },
    { 'now %- errorAt', 'its error lines go through CP.errEvery' },
    { 'pcall%(function%(%) return exports', 'exports go through CP.Ext.call' },
    { 'pcall%(function%(%)\n%s*return exports', 'exports go through CP.Ext.call' },
    { 'CP%.Permissions and CP%.Permissions%.can', 'permissions go through CP.can' },
    { 'CP%.Qbx and CP%.Qbx%.getByCitizenId and', 'the online source is CP.srcOf' },
    { 'CP%.Tablet and CP%.Tablet%.push', 'client pushes go through CP.push', client = true },
}
local scanned = 0
for _, f in ipairs(Lines('find modules -name "*.lua" | sort')) do
    local src = Read(f) or ''
    scanned = scanned + 1
    for _, c in ipairs(COPIES) do
        if not c.client or f:find('/client/', 1, true) then H.ok(not src:find(c[1]), f .. ': ' .. c[2]) end
    end
end
H.ok(scanned > 100, 'every module file is scanned')

local NUMS = {
    'admin/admin',
    'runs/runs',
    'runs/spawn',
    'missions/testing',
    'npc/custody',
    'map/markers',
    'supervisor/supawards',
    'supervisor/livectl',
}
for _, f in ipairs(NUMS) do
    local src = Read('modules/' .. f .. '.lua') or ''
    H.ok(not src:find('local function Num(', 1, true) and src:find('local Num = CP.Num', 1, true),
        f .. ': Num is CP.Num')
end

-- FIN3: the progression and supervisor modules keep no copy of a library helper either (number and setting reads,
-- the citizenid checks, the warn-once line, the officer's department), and the goals and the department challenge
-- count runs through the one progress engine (CP.Progress) instead of their own counted-run SQL.
local FIN3_COPIES = {
    { 'local function Num%(v', 'numbers are CP.Num / CP.Num0' },
    { 'local function Int%(v%)\n%s*return math%.floor', 'whole numbers are CP.Int' },
    { 'local function Int%(v%) return math%.floor', 'whole numbers are CP.Int' },
    { 'local function Cfg%(section, key, default%)', 'setting reads are CP.Cfg' },
    { 'local function ValidCitizenId%(', 'citizenid checks are CP.ValidCid' },
    { 'local function NonEmpty%(', 'trimmed text is CP.NonEmpty' },
    { 'CITIZENID_MAX', 'payload citizenids are CP.cidOf' },
    { 'warned%[key%] = true', 'warn-once lines are CP.warnOnce' },
    { 'SELECT department FROM cp_officers WHERE citizenid = %? LIMIT 1', 'the department is CP.deptOfCitizen' },
}
for _, f in ipairs(Lines('find modules/progression modules/supervisor -name "*.lua" | sort')) do
    local src = Read(f) or ''
    for _, c in ipairs(FIN3_COPIES) do H.ok(not src:find(c[1]), f .. ': ' .. c[2]) end
end
for _, f in ipairs({ 'modules/progression/goals.lua', 'modules/progression/challenge.lua' }) do
    local src = Read(f) or ''
    H.ok(src:find('CP.Progress.', 1, true) ~= nil, f .. ': counts through CP.Progress')
end
H.ok(not (Read('modules/progression/goals.lua') or ''):find('NOT IN (\'manual_award\', \'goal\')', 1, true),
    'goals: no counted-run SQL of its own')

-- FIN4: the review module keeps no copy of a library helper (numbers, whole numbers in a range), nor do the files
-- that had the same range check (admin, payments, notices)
for _, f in ipairs(Lines('find modules/review -name "*.lua" | sort')) do
    local src = Read(f) or ''
    H.ok(not src:find('local function Num%(v'), f .. ': numbers are CP.Num')
    H.ok(not src:find('local function Int%(v'), f .. ': whole numbers in a range are CP.IntIn')
end
for _, f in ipairs({ 'modules/admin/admin.lua', 'modules/money/payments.lua', 'modules/supervisor/notices.lua' }) do
    H.ok((Read(f) or ''):find('local Int = CP.IntIn', 1, true) ~= nil, f .. ': Int is CP.IntIn')
end

-- the shared ones answer as the private copies did
H.boot({ side = 'server' })
CP.Probe = {
    twice = function(n) return n * 2 end,
    boom = function() error('boom') end,
}
local realErr = CP.err
CP.err = function() end
local ok, v = CP.Call('layout', 'Probe', 'twice', 21)
H.ok(ok and v == 42, 'CP.Call: true and the answer')
H.eq(CP.Call('layout', 'Probe', 'boom'), false, 'CP.Call: false when it raised')
H.eq(CP.Call('layout', 'Probe', 'missing'), false, 'CP.Call: false when it is missing')
CP.err = realErr
CP.Probe = nil
H.eq(CP.Num('12', 0), 12, 'CP.Num: a numeric string')
H.eq(CP.Num('x', 5), 5, 'CP.Num: the default for text')
H.eq(CP.Num(0 / 0, 5), 5, 'CP.Num: the default for NaN')
H.eq(CP.IntIn('12', 1, 20), 12, 'CP.IntIn: a whole number in the range')
H.eq(CP.IntIn(1.5, 1, 20), nil, 'CP.IntIn: never rounded')
H.eq(CP.IntIn(21, 1, 20), nil, 'CP.IntIn: nil past the range')
H.eq(CP.IntIn(-3), -3, 'CP.IntIn: no range given')

return H

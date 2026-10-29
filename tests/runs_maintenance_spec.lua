-- The run engine's once-a-minute maintenance (Runs._maintenance): who is online comes from the map that the Qbox load,
-- unload and drop events keep, so no GetPlayerByCitizenId export runs per cached citizen. Cooldowns stay as before.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', stopped = { ox_inventory = true } })   -- no inventory: the login sweep returns at once

H.sql('DELETE FROM cp_mission_runs')
H.time = tonumber(H.sql('SELECT UNIX_TIMESTAMP(NOW()) AS t')[1].t)   -- align os.time() with NOW()

-- ============================================================================
--                             QBOX THROUGH CP.Qbx
-- ============================================================================
-- chars[src] is the character Qbox has loaded on src now. As in qbx_core, an unload or a drop removes the Player
-- before the listener runs (getInfo answers nil there), so the listener cannot ask Qbox who left.

local chars = {}
local exports = 0           -- GetPlayerByCitizenId calls (a whole Player copy across the export each)
local listeners = {}
CP.Qbx = {
    getInfo = function(src)
        local cid = chars[tonumber(src)]
        if not cid then return nil end
        return { src = tonumber(src), citizenid = cid, job = { name = 'police', onduty = true } }
    end,
    getByCitizenId = function(cid)
        exports = exports + 1
        for src, c in pairs(chars) do if c == cid then return src end end
        return nil
    end,
    getOnlinePlayers = function()
        local list = {}
        for src in pairs(chars) do list[#list + 1] = src end
        table.sort(list)
        return list
    end,
    onPlayerUnload = function(fn) listeners.unload = fn end,
    onPlayerLoaded = function(fn) listeners.loaded = fn end,
}
CP.Access = {
    onLost = function(fn) listeners.lost = fn end,
}
CP.Alerts = {
    foreignClearedAt = {},
    foreignFlag = function() return false end,
    inArena = function() return false end,
}
local mission = { id = 'cq_mission', type = 'tactical', cooldown = 1200 }
CP.Missions = {
    get = function(id) if id == 'cq_mission' then return mission end end,
    all = function() return { cq_mission = mission } end,
}

local function Cid(src) return ('CQ%04d'):format(src) end
local function Entry(cid) return CP.Runs._cooldownEntry(cid) end
local function AddRow(cid, reason)
    MySQL.insert.await(
        'INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason, points_base) VALUES (?, \'tactical\', \'cq_mission\', ?, \'sast\', \'abandoned\', ?, 200)',
        { 'cq-' .. cid .. '-' .. reason, cid, reason })
end
-- two cooldown answers hold the same keys and values
local function Same(a, b)
    for _, part in ipairs({ 'types', 'missions' }) do
        for k, v in pairs(a[part]) do if b[part][k] ~= v then return false end end
        for k, v in pairs(b[part]) do if a[part][k] ~= v then return false end end
    end
    return true
end
local NONE = { types = {}, missions = {} }
local function Kept(from, to)
    local n = 0
    for src = from, to do if Entry(Cid(src)) then n = n + 1 end end
    return n
end

-- a player who loaded before this resource started: only the startup sweep can put him in the map
chars[901] = 'CQPRE901'

H.load('modules/runs/server.lua')
local Runs = CP.Runs
local cids = Runs._cids
H.step(0)   -- the hook registration thread
H.ok(listeners.unload ~= nil and listeners.loaded ~= nil, 'load and unload hooks registered')
H.eq(cids.trusted, true, 'the map is trusted once the unload hook is in')
H.advance(16000)
H.eq(cids.online.CQPRE901, 901, 'startup sweep: a player online before the start is in the map')
H.eq(cids.of[901], 'CQPRE901', 'startup sweep: both ways')

-- ============================================================================
--                         200 PLAYERS LOAD, NO EXPORT
-- ============================================================================

AddRow(Cid(1), 'quit')       -- type and mission cooldown
AddRow(Cid(3), 'quit')
AddRow(Cid(151), 'quit')
local created = H.time
for src = 1, 200 do
    chars[src] = Cid(src)
    listeners.loaded(src)
end
H.eq(cids.online[Cid(200)], 200, 'the map fills as each player loads')
H.advance(5100)   -- the login preload, 5 s after the load
H.eq(Kept(1, 200), 200, '200 cooldown entries preloaded')
H.eq(Entry(Cid(7)).loaded, true, 'an entry is loaded')

-- what Runs.cooldowns answered before this change, rebuilt from the rows
local abandon = Config.Limits.abandonCooldown or 300
local function Expected()
    return { types = { tactical = created + abandon }, missions = { cq_mission = created + 1200 } }
end
H.ok(Same(Runs.cooldowns(Cid(1)), Expected()), 'cooldowns from the rows')
H.ok(Same(Runs.cooldowns(Cid(2)), NONE), 'no rows: no cooldowns')

exports = 0
Runs._maintenance()
H.eq(exports, 0, 'maintenance with 200 players online: no GetPlayerByCitizenId export (it was one per player)')
H.eq(Kept(1, 200), 200, 'every online player\'s entry is kept')
H.ok(Same(Runs.cooldowns(Cid(1)), Expected()), 'cooldowns unchanged after maintenance')

-- ============================================================================
--                               50 PLAYERS LEAVE
-- ============================================================================

for src = 151, 200 do
    chars[src] = nil
    H.fire('playerDropped', src)
end
H.eq(Kept(152, 200), 0, 'drop: the empty entries of the 49 leavers are gone at once')
H.ok(Entry(Cid(151)) ~= nil, 'drop: an entry with a live cooldown is kept')
H.eq(cids.online[Cid(151)], nil, 'drop: out of the map')
H.eq(cids.of[151], nil, 'drop: out of the map both ways')
H.eq(Kept(1, 150), 150, 'the other 150 are kept')

exports = 0
Runs._maintenance()
H.eq(exports, 0, 'maintenance after the drops: no export')
H.ok(Entry(Cid(151)) ~= nil, 'a live cooldown of a leaver is still kept')
H.eq(Kept(1, 150), 150, 'still 150 kept')

-- the cooldown runs out: the leaver's entry goes with no export, the online ones stay
H.time = H.time + 1300
exports = 0
Runs._maintenance()
H.eq(exports, 0, 'spent cooldowns: no export')
H.eq(Entry(Cid(151)), nil, 'a leaver\'s entry goes once its cooldowns are spent')
H.eq(Kept(1, 150), 150, 'online players keep their entries when their cooldowns are spent')
H.eq(Entry(Cid(1)).types.tactical, nil, 'spent values are pruned')
H.ok(Same(Runs.cooldowns(Cid(1)), NONE), 'spent cooldowns answer nothing, as before')
H.eq(cids.seen[Cid(151)], nil, 'nothing kept of a leaver once nothing of his is cached')

-- ============================================================================
--                        A RELOG STILL BLOCKS A MISSION
-- ============================================================================

AddRow(Cid(5), 'off_route')
Runs._forgetOfficer(Cid(5))   -- an admin change: read again from the rows
local before = Runs.cooldowns(Cid(5))
H.ok((before.types.tactical or 0) > os.time(), 'a live type cooldown')
chars[5] = nil
listeners.unload(5)
chars[5] = Cid(5)
listeners.loaded(5)
H.advance(5100)
H.ok(Same(Runs.cooldowns(Cid(5)), before), 'after a relog: the same cooldowns')
H.eq(Runs.onCooldown(Cid(5), 'tactical', 'cq_mission'), true, 'after a relog: still on cooldown')

-- the same after a drop and a reconnect
chars[5] = nil
H.fire('playerDropped', 5)
H.ok(Entry(Cid(5)) ~= nil, 'a live cooldown is kept over a disconnect')
chars[5] = Cid(5)
listeners.loaded(5)
H.advance(5100)
H.ok(Same(Runs.cooldowns(Cid(5)), before), 'after a reconnect: the same cooldowns')

-- ============================================================================
--                  CHARACTER SWITCH: AN UNLOAD WITHOUT A DROP
-- ============================================================================

chars[2] = nil
listeners.unload(2)
H.eq(cids.of[2], nil, 'unload: the src forgets its character')
H.eq(cids.online[Cid(2)], nil, 'unload: the character is offline')
H.eq(Entry(Cid(2)), nil, 'unload: an empty entry goes')
chars[2] = 'CQ9002'
listeners.loaded(2)
H.eq(cids.of[2], 'CQ9002', 'the new character is in the map')
H.eq(cids.online.CQ9002, 2, 'the new character is online on the same src')

-- a switch with a live cooldown: the old character's entry stays until it is spent, then goes with no export
AddRow(Cid(3), 'off_route')
Runs._forgetOfficer(Cid(3))
H.ok((Runs.cooldowns(Cid(3)).types.tactical or 0) > os.time(), 'the old character has a live cooldown')
chars[3] = nil
listeners.unload(3)
chars[3] = 'CQ9003'
listeners.loaded(3)
H.advance(5100)
H.ok(Entry(Cid(3)) ~= nil, 'switch: a live cooldown is kept')
H.time = H.time + 1300
exports = 0
Runs._maintenance()
H.eq(exports, 0, 'switch: no export')
H.eq(Entry(Cid(3)), nil, 'switch: the old character\'s entry goes once spent')
H.ok(Entry('CQ9003') ~= nil, 'switch: the new character\'s entry is kept')

-- a load on a src whose unload never came: the old character leaves the map
chars[4] = 'CQ9004'
listeners.loaded(4)
H.eq(cids.online[Cid(4)], nil, 'a load replaces the character the src had')
H.eq(cids.online.CQ9004, 4, 'the replacing character is online')

-- an entry that was never loaded and holds nothing is the same as none
Runs.clearCooldowns(Cid(10), 'all')
H.eq(Entry(Cid(10)).loaded, false, 'a cleared entry is read again on its next use')
exports = 0
Runs._maintenance()
H.eq(exports, 0, 'an empty unloaded entry: no export')
H.eq(Entry(Cid(10)), nil, 'an empty unloaded entry goes')
H.ok(Same(Runs.cooldowns(Cid(10)), NONE), 'and is read again on its next use')

-- ============================================================================
--                A CITIZEN THE MAP NEVER SAW: THE EXPORT, ONCE
-- ============================================================================

-- offline (an admin looked at an officer who is not on the server)
Runs.cooldowns('LAZY0001')
H.ok(Entry('LAZY0001') ~= nil, 'a lazy entry for a citizen the map never saw')
exports = 0
Runs._maintenance()
H.eq(exports, 1, 'never seen: checked with the export, as before')
H.eq(Entry('LAZY0001'), nil, 'offline: the entry goes')
Runs._maintenance()
H.eq(exports, 1, 'and not checked again')

-- online although no load event told the map (one missed): kept, and from then on the map knows him
chars[777] = 'LAZY0777'
Runs.cooldowns('LAZY0777')
exports = 0
Runs._maintenance()
H.eq(exports, 1, 'online, never seen: one export')
H.ok(Entry('LAZY0777') ~= nil, 'online: the entry is kept')
H.eq(cids.online.LAZY0777, 777, 'the export\'s answer is kept in the map')
Runs._maintenance()
H.eq(exports, 1, 'the next maintenance asks nothing')
chars[777] = nil
H.fire('playerDropped', 777)
H.eq(Entry('LAZY0777'), nil, 'the drop then removes the entry')

-- A4: a start the engine refuses (here the maintenance lock) is kept for admins, unless the caller keeps it itself
do
    local savedM = CP.Maintenance
    CP.Maintenance = {
        active = function() return true end,
    }
    local def = {
        id = 'cq_mission',
        type = 'tactical',
        objectives = { { block = 'checkpoint_route' } },
        locations = { { start = { coords = vec3(1.0, 2.0, 3.0) } } },
    }
    local member = { src = 5, citizenid = 'CQ0005', name = 'Quinn Q' }
    local before = CP.Refusals.total()
    local run, errKey = CP.Runs.create({ mission = def, locationIndex = 1, members = { member }, leaderSrc = 5 })
    H.ok(run == nil and errKey == 'err.maintenance', 'maintenance refuses the start')
    local kept = CP.Refusals.list(1)[1]
    H.ok(
        kept.reason == 'err.maintenance' and kept.citizenid == 'CQ0005' and kept.missionId == 'cq_mission'
            and kept.type == 'tactical',
        'the refused start is kept with who, which mission and why'
    )
    CP.Runs.create({ mission = def, locationIndex = 1, members = { member }, leaderSrc = 5, noteRefusal = false })
    H.eq(CP.Refusals.total(), before + 1, 'noteRefusal = false: the caller keeps it')
    CP.Maintenance = savedM
end

H.sql('DELETE FROM cp_mission_runs')
return H

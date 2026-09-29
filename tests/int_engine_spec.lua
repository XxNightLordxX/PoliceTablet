-- tests/int_engine_spec.lua · integration of the engine group: the REAL modules missions, draw, scaling,
-- schedule, events, runs and npc with every REAL block, on the REAL built-in mission files, with stubs only for
-- the modules outside the group (access, qbx, alerts, route, payouts, scoring, cash, anticheat, tablet ...).
-- It checks the cross-module paths the slice notes and the integration list asked for:
--   * the real loader (CP.Missions.loadAll at start, LoadResourceFile of every missions/builtin file) loads all 14
--     built-in missions: the loader sets def.source before the blocks' validate, so a built-in file is exempt from
--     the Mission Builder's model lists (Prison Break's inmates and the Kingpin's boss model are in those lists
--     now, so copies of them can be published; a model outside the lists passes only in a built-in file)
--   * CP.Runs.create reserves the location through the real CP.Draw (test runs too, CP.Runs.get returns them),
--     rolls the modifier through the real CP.Events after the seed / type / boss / test / operation are set,
--     and releases the reservation when the run ends
--   * server:acceptType -> draw -> create -> server:abandon: the cooldowns() shape the board and the accept read
--   * Bomb Disposal: the device prop found by interact_points (objective 1) is kept by the engine when that
--     objective completes and defused by skill_check (objective 2) without being re-created; every hook of an
--     objective gets the same ctx.state; everything goes at the run end
--   * Warrant Service, every location: the suspect waiting on the door step surrenders 1 m in front of the door
--     (never behind the facade), through the real engine, CP.Npc and flee_arrest; a kill goes CP.Npc ->
--     CP.Runs.entityDied -> the block, once
local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local U = CP.U

-- ── console: keep the module log lines out of the test output ───────────────
local realPrint = print
_G.print = function(...)
    local line = table.concat((function(...) local t = {} for i = 1, select('#', ...) do t[i] = tostring((select(i, ...))) end return t end)(...), ' ')
    if line:find('crimson%-police') then return end
    realPrint(line)
end

H.sql('DELETE FROM cp_mission_runs')
H.time = tonumber(H.sql('SELECT UNIX_TIMESTAMP(NOW()) AS t')[1].t)

-- ── OneSync natives ─────────────────────────────────────────────────────────
local ents, nextHandle, nextNet = {}, 9000, 20000
local netToEnt, deleted = {}, {}
local created = { ped = 0, vehicle = 0, object = 0 }
local function newEnt(kind, model, x, y, z, h)
    nextHandle, nextNet = nextHandle + 1, nextNet + 1
    ents[nextHandle] = {
        kind = kind, model = model, coords = vec3(x + 0.0, y + 0.0, z + 0.0), heading = h or 0.0, exists = true,
        health = kind == 'ped' and 200 or 1000, maxHealth = kind == 'ped' and 200 or 1000, armour = 0,
        engine = 1000.0, body = 1000.0, net = nextNet, type = kind == 'ped' and 1 or (kind == 'vehicle' and 2 or 3),
    }
    netToEnt[nextNet] = nextHandle
    created[kind] = created[kind] + 1
    return nextHandle
end
_G.CreatePed = function(_, model, x, y, z, h) return newEnt('ped', model, x, y, z, h) end
_G.CreateVehicleServerSetter = function(model, _, x, y, z, h) return newEnt('vehicle', model, x, y, z, h) end
_G.CreateObjectNoOffset = function(model, x, y, z) return newEnt('object', model, x, y, z) end
_G.DoesEntityExist = function(e)
    if ents[e] then return ents[e].exists end
    return (tonumber(e) or 0) > 0
end
_G.DeleteEntity = function(e) deleted[e] = true; if ents[e] then ents[e].exists = false end end
_G.NetworkGetNetworkIdFromEntity = function(e) return ents[e] and ents[e].net or 0 end
_G.NetworkGetEntityFromNetworkId = function(n) return netToEnt[n] or 0 end
_G.NetworkGetEntityOwner = function() return 0 end
_G.GiveWeaponToPed = function(e, w) if ents[e] then ents[e].weapon = w end end
_G.SetPedArmour = function(e, a) if ents[e] then ents[e].armour = a end end
_G.GetPedArmour = function(e) return ents[e] and ents[e].armour or 0 end
_G.GetEntityHealth = function(e) return ents[e] and ents[e].health or 200 end
_G.GetEntityMaxHealth = function(e) return ents[e] and ents[e].maxHealth or 200 end
_G.GetEntityModel = function(e) return ents[e] and joaat(ents[e].model) or 0 end
_G.GetVehicleEngineHealth = function(e) return ents[e] and ents[e].engine or 1000.0 end
_G.GetVehicleBodyHealth = function(e) return ents[e] and ents[e].body or 1000.0 end
_G.GetVehiclePetrolTankHealth = function() return 1000.0 end
_G.GetEntityType = function(e)
    if ents[e] then return ents[e].type end
    local n = tonumber(e) or 0
    if n > 0 and n % 100 == 0 and H.players[n // 100] then return 1 end   -- a player's ped (src * 100)
    return 0
end
_G.IsPedAPlayer = function(e) return ents[e] == nil end
_G.GetPedSourceOfDeath = function(e) return ents[e] and ents[e].killer or 0 end
_G.GetPedSourceOfDamage = function() return 0 end
_G.GetPedCauseOfDeath = function() return 0 end
_G.GetVehiclePedIsIn = function(ped) local p = H.players[math.floor(ped / 100)]; return p and p.vehicle or 0 end
_G.GetPedInVehicleSeat = function() return 0 end
_G.SetEntityHeading = function(e, h) if ents[e] then ents[e].heading = h end end
_G.GetEntityHeading = function(e) return ents[e] and ents[e].heading or 0.0 end
_G.SetEntityCoords = function(e, x, y, z) if ents[e] then ents[e].coords = vec3(x, y, z) end end
_G.FreezeEntityPosition = function() end
_G.SetVehicleNumberPlateText = function() end
_G.SetVehicleDoorsLocked = function() end
_G.SetPedIntoVehicle = function() end
_G.GetEntitySpeed = function() return 0.0 end
_G.WasEventCanceled = function() return false end
local playerCoords = _G.GetEntityCoords
_G.GetEntityCoords = function(e)
    if ents[e] then return ents[e].coords end
    return playerCoords(e)
end
local bags = {}
_G.Entity = function(e)
    local b = bags[e]
    if not b then b = {}; bags[e] = b end
    return { state = setmetatable({ set = function(_, k, v) b[k] = v end }, { __index = b }) }
end
_G.GetPlayerRoutingBucket = function() return 0 end

-- ── stubs of the modules outside the engine group ───────────────────────────
local O = {
    [1] = { src = 1, citizenid = 'ENG1', name = 'Ada Engine', department = 'sast', departmentShort = 'SAST', job = 'sast', rank = 'Sergeant', callsign = 'E-1' },
    [2] = { src = 2, citizenid = 'ENG2', name = 'Ben Engine', department = 'fib', departmentShort = 'FIB', job = 'fib', rank = 'Agent', callsign = 'E-2' },
}
local log = {}
local function rec(k, v) log[k] = log[k] or {}; table.insert(log[k], v) end
local function count(k) return log[k] and #log[k] or 0 end
CP.Access = {
    getOfficer = function(src) return O[src] end,
    recheck = function() return true end,
    onLost = function() end,
    departmentForJob = function(job) return job end,
}
CP.Qbx = {
    getInfo = function(src) local o = O[src]; return o and { src = src, citizenid = o.citizenid, job = { name = o.job } } or nil end,
    onPlayerUnload = function() end, onPlayerLoaded = function() end,
    getByCitizenId = function() return nil end, getOnlinePlayers = function() return { 1, 2 } end,
}
CP.Alerts = { set = function() end, clear = function() end, inArena = function() return false end, foreignClearedAt = {} }
CP.Route = { begin = function() end, stop = function() end, status = function() return { status = 'arrived', recalcsLeft = 2, distance = 0 } end }
CP.Payouts = { baseFor = function(m) return m.isBoss and 2500 or 800 end }
CP.Scoring = {
    P = function(m) return m.isBoss and 500 or 200 end,
    isFirstRunSinceDuty = function() return false end,
    compute = function(run, p, result) return { P = run.pointsBase, bonuses = {}, penalties = {}, subtotal = 0, mTeam = 1, mCross = 1, mStreak = 1, capped = false, tod = false, final = result == 'completed' and 200 or 0 } end,
    onRowCounted = function() end,
}
CP.Cash = { compute = function() return 0, { B = 800, mTier = 1, mMod = 1, amount = 0 } end, pay = function() end }
CP.Goals = { onRunCompleted = function() end }
CP.Leaderboard = { invalidate = function() end }
CP.Challenge = { currentSeason = function() return nil end }
CP.AntiCheat = {
    checkEvent = function() return true end,
    flag = function(run, src, reason) rec('flag', reason) end,
    presenceOk = function() return true end,
    onNpcKilled = function(run, src) rec('outside', src) end,
}
CP.Units = { unitOf = function() return nil end, unlock = function() end, members = function(src) return { src } end }
CP.Operations = { onRunEnded = function() end, isLocked = function() return false end }
CP.Testing = { onRunEnded = function() end }
CP.Tablet = { notify = function() end, push = function() end }
CP.Permissions = { can = function() return false, 'err.no_permission' end }

-- ── the REAL engine group ───────────────────────────────────────────────────
local BLOCKS = { 'checkpoint_route', 'escort', 'flee_arrest', 'hostile_waves', 'interact_points',
    'protect_rescue', 'pursuit', 'search_area', 'skill_check' }
for _, b in ipairs(BLOCKS) do H.load('blocks/' .. b .. '/server.lua') end
H.load('modules/scaling/server.lua')
H.load('modules/schedule/server.lua')
H.load('modules/events/server.lua')
H.load('modules/missions/server.lua')
H.load('modules/draw/server.lua')
H.load('modules/npc/server.lua')
H.load('modules/runs/server.lua')
local Runs, Missions, Draw = CP.Runs, CP.Missions, CP.Draw
H.step(0)   -- the start threads: CP.Missions.loadAll (after Wait(0)) and the engine's hook registration

local function place(src, c) H.players[src] = H.players[src] or {}; H.players[src].coords = vec3(c.x + 0.0, c.y + 0.0, c.z + 0.0) end
local function objEvent(src, run, index, ev) H.fire('crimson-police:server:objective', src, run.id, index, ev) end

-- ═══ 1. The real loader: every missions/builtin file, 14 valid missions ═══════
do
    local ids = assert(load(LoadResourceFile('Crimson-Police', 'missions/builtin/index.lua'), '@index', 't', {}))()
    H.eq(#ids, 14, 'missions/builtin/index.lua lists 13 missions and the Weekly Boss')
    H.eq(U.count(Missions.all()), 14, 'the loader run at start loaded all 14 built-in missions')
    local summary = Missions.loadAll()
    H.eq(summary.builtin, 14, 'CP.Missions.loadAll: 14 built-in missions')
    H.eq(#summary.failed, 0, 'CP.Missions.loadAll: nothing rejected' .. (summary.failed[1] and (' (' .. tostring(summary.failed[1].id) .. ': ' .. tostring(summary.failed[1].error) .. ')') or ''))
    for _, id in ipairs(ids) do
        local def = Missions.get(id)
        H.ok(def ~= nil and def.source == 'builtin' and def.filePath == 'missions/builtin/' .. id .. '.lua', 'loaded as built-in: ' .. id)
        H.ok(def ~= nil and Missions.isEnabled(id), 'enabled: ' .. id)
    end
    local pb = Missions.get('prison_break')
    local inmates = pb and pb.objectives[1].models or {}
    H.ok(U.contains(inmates, 's_m_y_prisoner_01'), 'Prison Break keeps its prison-clothes inmates')
    local kp = Missions.get('weekly_boss_kingpin')
    H.ok(kp ~= nil and kp.isBoss == true, 'the Kingpin is the boss')
    local bossBlock
    for _, o in ipairs(kp and kp.objectives or {}) do if type(o.boss) == 'table' then bossBlock = o.boss end end
    H.ok(bossBlock ~= nil and type(bossBlock.model) == 'string', 'the Kingpin keeps its boss model')
    local tactical = Missions.byType('tactical')
    local hasBoss = false
    for _, d in ipairs(tactical) do if d.isBoss then hasBoss = true end end
    H.eq(#tactical, 5, 'five Tactical missions in the pool')
    H.eq(hasBoss, false, 'the boss is not in the Tactical pool')
    -- their models are base-game peds of the Mission Builder's list (copies of them can be published) ...
    H.ok(U.contains(Config.Builder.allowed.peds, 's_m_y_prisoner_01') and U.contains(Config.Builder.allowed.peds, 's_m_y_prismuscl_01'),
        "Prison Break's inmates are in Config.Builder.allowed.peds")
    H.ok(bossBlock ~= nil and U.contains(Config.Builder.allowed.peds, bossBlock.model), "the Kingpin's model is in Config.Builder.allowed.peds")
    -- ... and the source is still what exempts a built-in file: a model outside the lists passes only there
    for _, id in ipairs({ 'prison_break', 'weekly_boss_kingpin' }) do
        local path = 'missions/builtin/' .. id .. '.lua'
        local raw = Missions.parse(LoadResourceFile('Crimson-Police', path), path)
        for _, o in ipairs(raw.objectives) do
            if type(o.models) == 'table' then o.models = { 'u_m_y_zombie_01' } end
            if type(o.boss) == 'table' then o.boss.model = 'u_m_y_zombie_01' end
        end
        local asCustom, why = Missions.normalize(U.deepcopy(raw), { source = 'custom', version = 1 })
        H.eq(asCustom, nil, id .. ' with a model outside the lists, as a custom mission, is refused (' .. tostring(why) .. ')')
        H.ok(Missions.normalize(U.deepcopy(raw), { source = 'builtin', filePath = path }) ~= nil, id .. ' with that model as a built-in mission loads')
    end
end

-- ═══ 2. create: reservation and modifier through the real CP.Draw / CP.Events ═
local function expectedModifier(run)
    local r = U.rng(U.hash(tostring(run.seed) .. ':modifier'))
    if not r:chance(Config.Events.modifierChance) then return nil end
    local list = {}
    for _, k in ipairs({ 'armored_hostiles', 'time_crunch', 'radio_silence' }) do
        if k ~= 'armored_hostiles' or run.missionType == 'tactical' then list[#list + 1] = k end
    end
    return r:pick(list)
end
do
    local chance = Config.Events.modifierChance
    Config.Events.modifierChance = 1.0
    place(1, vec3(0, 0, 0)); place(2, vec3(0, 0, 0))
    local bd = Missions.get('bomb_disposal')
    local run = Runs.create({ mission = bd, locationIndex = 2, missionType = 'tactical', members = { O[1] }, leaderSrc = 1 })
    H.ok(type(run) == 'table', 'a Bomb Disposal run')
    H.ok(Draw.isReserved('bomb_disposal', 2), 'location reserved in CP.Draw under the run')
    H.ok(run.modifier ~= nil, 'modifier rolled (chance 1)')
    H.eq(run.modifier, expectedModifier(run), 'the modifier comes from the run seed (rolled after the seed and type were set)')
    if run.modifier == 'time_crunch' then H.eq(run.timeLimit, U.round(bd.timeLimit * 0.75), 'Time Crunch cut') end
    Runs.removeParticipant(run, 1, 'cancelled')
    H.eq(Draw.isReserved('bomb_disposal', 2), false, 'reservation released when the run ends')

    local patrol = Missions.get('beat_patrol')
    for i = 1, 6 do
        local r = Runs.create({ mission = patrol, locationIndex = 1, missionType = 'patrol', members = { O[1] }, leaderSrc = 1 })
        H.ok(r.modifier ~= 'armored_hostiles', 'Armored Hostiles is Tactical only (' .. tostring(r.modifier) .. ')')
        H.eq(r.modifier, expectedModifier(r), 'patrol modifier from the seed #' .. i)
        Runs.removeParticipant(r, 1, 'cancelled')
    end
    local tr = Runs.create({ mission = bd, locationIndex = 3, missionType = 'tactical', members = { O[1] }, leaderSrc = 1,
        test = { adminSrc = 1, useStartRoute = false, forcedTier = 'heavy' } })
    H.eq(tr.modifier, nil, 'no modifier on a test run')
    H.ok(Draw.isReserved('bomb_disposal', 3), 'a test run reserves its location too')
    H.eq(Runs.get(tr.id), tr, 'CP.Runs.get returns test runs (the reservation sweep relies on it)')
    Runs.removeParticipant(tr, 1, 'cancelled')
    H.eq(Draw.isReserved('bomb_disposal', 3), false, 'test reservation released')
    local op = Runs.create({ mission = bd, locationIndex = 4, missionType = 'tactical', members = { O[1], O[2] }, leaderSrc = 1, operationId = 3 })
    H.eq(op.modifier, nil, 'no modifier on an operation run')
    Runs.removeParticipant(op, 1, 'cancelled'); Runs.removeParticipant(op, 2, 'cancelled')
    local kp = Missions.get('weekly_boss_kingpin')
    local boss = Runs.create({ mission = kp, locationIndex = 1, missionType = 'weekly_boss', members = { O[1] }, leaderSrc = 1, isBoss = true })
    H.eq(boss.modifier, nil, 'no modifier on the Weekly Boss')
    H.eq(boss.missionType, 'tactical', 'the boss runs as Tactical')
    Runs.removeParticipant(boss, 1, 'cancelled')
    Config.Events.modifierChance = chance
end

-- ═══ 2b. accept -> draw -> create -> abandon -> cooldown, through the real CP.Draw and CP.Runs ═══
do
    local reqN = 0
    local function act(name, src, payload)
        reqN = reqN + 1
        local id = 'int' .. reqN
        H.clockMs = H.clockMs + 2000
        H.fire('crimson-police:' .. name, src, payload, id)
        for i = #H.events, 1, -1 do
            local e = H.events[i]
            if e.name == 'crimson-police:client:actionResult' and e.args[1] == id then return e.args[2], e.args[3] end
        end
        return nil, 'no reply'
    end
    local chance = Config.Events.modifierChance
    Config.Events.modifierChance = 0
    H.sql("DELETE FROM cp_mission_runs WHERE citizenid = 'ENG1'")
    place(1, vec3(0, 0, 0))
    local ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(ok, true, 'accept patrol through the real draw and engine')
    local run = Runs.getBySrc(1)
    H.ok(run ~= nil and run.id == (data and data.runId), 'the run the accept created')
    H.eq(run and run.missionType, 'patrol', 'a Patrol mission was drawn')
    H.ok(run and Draw.isReserved(run.missionId, run.locationIndex), 'its location is reserved under the run')
    local board = Draw.boardCards(1)
    H.eq(board.activeRunId, run and run.id, 'the board knows the active run')
    H.ok(type(board.serverTime) == 'number' and type(board.todMultiplier) == 'number', 'board extras')
    local missionId, locIndex = run.missionId, run.locationIndex
    ok = act('server:abandon', 1, run.id)
    H.eq(ok, true, 'abandon')
    H.eq(Draw.isReserved(missionId, locIndex), false, 'reservation released')
    local cd = Runs.cooldowns('ENG1')
    H.ok((cd.types.patrol or 0) > os.time(), 'cooldowns().types: the abandon put Patrol on cooldown')
    H.ok((cd.missions[missionId] or 0) > os.time(), 'cooldowns().missions: and that mission')
    board = Draw.boardCards(1)
    local card
    for _, c in ipairs(board.cards) do if c.key == 'patrol' then card = c end end
    H.ok(card and card.locked and card.locked['until'] == cd.types.patrol, 'the Patrol card is locked until the type cooldown ends')
    ok, data = act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.type_cooldown', 'a second accept is refused while the type is on cooldown')
    Config.Events.modifierChance = chance
end

-- ═══ 3. Bomb Disposal: the found device survives objective 1 and is defused by objective 2 ═══
do
    local chance = Config.Events.modifierChance
    Config.Events.modifierChance = 0
    local bd = Missions.get('bomb_disposal')
    local loc = bd.locations[1]
    place(1, loc.start.coords)
    local run = Runs.create({ mission = bd, locationIndex = 1, missionType = 'tactical', members = { O[1] }, leaderSrc = 1 })
    Runs.markArrived(run, 1)
    H.eq(run.state, 'in_progress', 'bomb run in progress')
    local st1 = run.objectives[1].state
    local n
    for i, p in ipairs(st1.points or {}) do if p.device then n = i end end
    H.ok(n ~= nil, 'one hiding spot holds the device')
    place(1, st1.points[n].coords)
    H.advance(3000)
    local objectsBefore = created.object
    objEvent(1, run, 1, { type = 'interact', point = n, seq = 1 })
    H.eq(created.object, objectsBefore + 1, 'the found device prop is spawned')
    local dev = run.shared.devices and run.shared.devices[1]
    H.ok(dev ~= nil and run.entities[dev.netId] ~= nil, 'the device is in run.shared.devices and tracked by the engine')
    local devEnt = dev and run.entities[dev.netId].entity
    H.advance(2000)
    H.eq(run.objectiveIndex, 2, 'objective 1 completed (every device found, minSeconds passed): skill_check is current')
    H.eq(run.objectives[1].status, 'done', 'objective 1 done')
    H.ok(run.entities[dev.netId] ~= nil and ents[devEnt].exists and not deleted[devEnt], 'the engine kept the device of the completed objective')
    H.advance(3000)
    H.eq(created.object, objectsBefore + 1, 'skill_check defuses that same prop: nothing re-created')
    H.eq(Runs.ctx(run, 1).state, run.objectives[1].state, 'objective 1 ctx.state is still the persistent table')
    H.eq(Runs.ctx(run, 2).state, run.objectives[2].state, 'objective 2 ctx.state is the persistent table')
    H.ok(run.objectives[2].state.targets ~= nil or next(run.objectives[2].state) ~= nil, 'skill_check built its state in that table')
    Runs.failRun(run, 'test.ended_by_admin')
    H.eq(run.state, 'ended', 'bomb run ended')
    H.ok(deleted[devEnt], 'the device is deleted when the run ends')
    Config.Events.modifierChance = chance
end

-- ═══ 4. Warrant Service, every location: the suspect surrenders outside the door ═══
do
    local chance = Config.Events.modifierChance
    Config.Events.modifierChance = 0
    local ws = Missions.get('warrant_service')
    H.eq(#ws.locations, 6, 'six Warrant Service houses')
    for li, loc in ipairs(ws.locations) do
        local m = U.deepcopy(ws)
        m.objectives[1].responses = { surrender = 1, flee = 0, fight = 0 }
        place(1, loc.start.coords); place(2, loc.start.coords)
        local run = Runs.create({ mission = m, locationIndex = li, missionType = 'investigation', members = { O[1], O[2] }, leaderSrc = 1 })
        Runs.markArrived(run, 1)
        H.advance(1000)
        local st = run.objectives[1].state
        local suspect, associate
        for _, p in pairs(st.peds or {}) do
            if p.role == 'suspect' then suspect = p elseif p.role == 'associate' then associate = p end
        end
        H.ok(suspect ~= nil and associate ~= nil, loc.label .. ': suspect and associate spawned')
        local door = loc.door
        place(1, door)
        objEvent(1, run, 1, { type = 'knock_start' })
        H.advance(3000)
        objEvent(1, run, 1, { type = 'knock' })
        H.eq(CP.Npc.getState(suspect.netId), 'surrendered', loc.label .. ': the suspect surrendered at the knock')
        local c = ents[suspect.entity].coords
        local r = math.rad(door.w)
        local fx, fy = -math.sin(r), math.cos(r)
        local ox, oy = c.x - door.x, c.y - door.y
        H.near(ox * fx + oy * fy, 1.0, 0.01, loc.label .. ': 1 m in front of the door (out = the door heading)')
        H.near(ox * fy - oy * fx, 0.0, 0.01, loc.label .. ': in line with the door')
        local sx, sy = loc.start.coords.x - door.x, loc.start.coords.y - door.y
        H.ok(ox * sx + oy * sy > 0, loc.label .. ': on the side of the street (the start)')
        -- a kill: CP.Npc reports it to the engine, which runs the block once
        local killsBefore = run.stats.npcDeaths or 0
        ents[associate.entity].killer = 100    -- player 1's ped
        ents[associate.entity].health = 0
        H.advance(2000)
        H.eq(run.entities[associate.netId] and run.entities[associate.netId].dead, true, loc.label .. ': the associate death reached CP.Runs.entityDied')
        H.eq((run.stats.npcDeaths or 0) - killsBefore, 1, loc.label .. ': counted once')
        H.eq(run.stats.kills and run.stats.kills[1], 1, loc.label .. ': killer attributed')
        H.eq(run.state, 'in_progress', loc.label .. ': killing an armed associate does not fail the run')
        Runs.removeParticipant(run, 2, 'cancelled')
        Runs.removeParticipant(run, 1, 'cancelled')
        H.ok(deleted[suspect.entity] and deleted[associate.entity], loc.label .. ': everything deleted at the end')
    end
    Config.Events.modifierChance = chance
end

-- ═══ 6. The cp bag is never read back; server-side gunfire; CP.Downed.handle at endRun (real downed) ═══
do
    local chance = Config.Events.modifierChance
    Config.Events.modifierChance = 0
    local ws = Missions.get('warrant_service')
    local m = U.deepcopy(ws)
    m.objectives[1].responses = { surrender = 1, flee = 0, fight = 0 }
    local loc = ws.locations[1]
    place(1, loc.start.coords); place(2, loc.start.coords)
    local run = Runs.create({ mission = m, locationIndex = 1, missionType = 'investigation', members = { O[1], O[2] }, leaderSrc = 1 })
    Runs.markArrived(run, 1)
    Runs.markArrived(run, 2)
    H.advance(1000)
    local suspect, associate
    for _, p in pairs(run.objectives[1].state.peds or {}) do
        if p.role == 'suspect' then suspect = p elseif p.role == 'associate' then associate = p end
    end
    H.ok(suspect ~= nil and associate ~= nil, 'bag trust: peds spawned')
    local info = run.entities[suspect.netId]
    H.eq(info and info.bag and info.bag.run, run.id, "the engine keeps its own copy of the ped's bag")
    -- a client rewrites the suspect's bag: the server (CP.Npc, the blocks' cuff checks, the armed cap) ignores it
    local before = CP.Npc.getState(suspect.netId)
    bags[suspect.entity].cp = { run = run.id, state = 'cuffed', cuff = { label = 'x', duration = 500, maxDistance = 10.0 } }
    H.advance(1000)
    H.eq(CP.Npc.getState(suspect.netId), before, 'a client-written "cuffed" bag leaves the server state as it was')
    H.eq(CP.Npc.isNeutralised(suspect.netId), false, 'and the suspect is not neutralised')
    CP.Npc.setState(run, suspect.netId, 'surrendered')
    H.eq(bags[suspect.entity].cp.state, 'surrendered', 'the next server write replaces the client bag')
    H.eq(bags[suspect.entity].cp.cuff, nil, 'the client cuff table is gone')
    H.eq(run.entities[suspect.netId].bag.state, 'surrendered', "the engine's copy follows")
    -- gunfire proven on the server: a gun hit on a mission ped by participant 1 (no client telemetry)
    H.eq(run.participants[1].firedWeapon, nil, 'no weapon fired yet')
    H.fire('weaponDamageEvent', 1, 1, { hitGlobalIds = { associate.netId }, weaponType = joaat('WEAPON_COMBATPISTOL') })
    H.eq(run.participants[1].firedWeapon, true, 'weaponDamageEvent: CP.Npc -> CP.Runs.noteWeaponFired')
    H.eq(run.stats.weaponsFired, 1, 'weaponsFired counted once')
    -- the real CP.Downed: participant 2 is down when the run ends -> handle removes them with keepFlag
    local downedSet = {}
    CP.Qbx.isDowned = function(src) return downedSet[src] == true end
    CP.Ambulance = { doctorCount = function() return 0 end, revive = function() return true end }
    local clears, toasts = {}, {}
    local realClear, realNotify = CP.Alerts.clear, CP.Tablet.notify
    CP.Alerts.clear = function(src) clears[#clears + 1] = src end
    CP.Tablet.notify = function(src, kind, key) toasts[#toasts + 1] = { src = src, key = key } end
    H.load('modules/downed/server.lua')
    H.step(0)
    downedSet[2] = true
    Runs.endRun(run, 'completed', 'completed')
    H.eq(run.state, 'ended', 'downed at the end: run ended')
    H.eq(run.participants[2].endReason, 'downed', "downed at the end: end_reason 'downed' (through CP.Downed.handle)")
    H.eq(run.participants[2].result, 'failed', 'downed at the end: Failed')
    H.eq(run.participants[1].result, 'completed', 'downed at the end: the other participant completed')
    local c2 = 0
    for _, s in ipairs(clears) do if s == 2 then c2 = c2 + 1 end end
    H.eq(c2, 0, 'downed at the end: the flag is kept (keepFlag) for the pick-up')
    H.eq(CP.Downed.isPending(2), true, 'downed at the end: the pick-up is pending')
    local soon = 0
    for _, t in ipairs(toasts) do if t.src == 2 and t.key == 'downed.pickup_soon' then soon = soon + 1 end end
    H.eq(soon, 1, 'downed at the end: the pick-up flow started')
    local row = H.sql("SELECT state, end_reason FROM cp_mission_runs WHERE run_uuid = ? AND citizenid = 'ENG2'", { run.id })[1]
    H.eq(row and row.state, 'failed', 'downed at the end: row failed')
    H.eq(row and row.end_reason, 'downed', 'downed at the end: row end_reason downed')
    CP.Downed.cancel(2, 'test')
    downedSet[2] = nil
    CP.Alerts.clear, CP.Tablet.notify = realClear, realNotify
    Config.Events.modifierChance = chance
end

return H

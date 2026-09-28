-- tests/engine_b_spec.lua · the run engine (modules/runs/server.lua) against stubs of the other modules,
-- with every SQL statement of the engine run on the MariaDB test database.
local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

H.sql('DELETE FROM cp_mission_runs')
H.time = tonumber(H.sql('SELECT UNIX_TIMESTAMP(NOW()) AS t')[1].t)   -- align os.time() with NOW()

-- ── OneSync natives ─────────────────────────────────────────────────────────
local ents, nextHandle, nextNet = {}, 5000, 7000
local netToEnt = {}
local deleted = {}
local frozen = {}
local dropped = {}
local function newEnt(kind, model, x, y, z)
    nextHandle, nextNet = nextHandle + 1, nextNet + 1
    ents[nextHandle] = { kind = kind, model = model, coords = vec3(x, y, z), exists = true, health = 200,
        engine = 1000.0, body = 1000.0, net = nextNet, type = kind == 'ped' and 1 or (kind == 'vehicle' and 2 or 3) }
    netToEnt[nextNet] = nextHandle
    return nextHandle
end
_G.CreatePed = function(_, model, x, y, z) return newEnt('ped', model, x, y, z) end
_G.CreateVehicleServerSetter = function(model, _, x, y, z) return newEnt('vehicle', model, x, y, z) end
_G.CreateObjectNoOffset = function(model, x, y, z) return newEnt('object', model, x, y, z) end
_G.DoesEntityExist = function(e)
    if ents[e] then return ents[e].exists end
    return (tonumber(e) or 0) > 0
end
_G.DeleteEntity = function(e) deleted[e] = true; if ents[e] then ents[e].exists = false end end
_G.NetworkGetNetworkIdFromEntity = function(e) return ents[e] and ents[e].net or 0 end
_G.NetworkGetEntityFromNetworkId = function(n) return netToEnt[n] or 0 end
_G.GiveWeaponToPed = function(e, w) ents[e].weapon = w end
_G.SetPedArmour = function(e, a) ents[e].armour = a end
_G.GetEntityHealth = function(e) return ents[e] and ents[e].health or 200 end
_G.GetEntityModel = function(e) return ents[e] and ents[e].model or 0 end
_G.GetVehicleEngineHealth = function(e) return ents[e] and ents[e].engine or 1000.0 end
_G.GetVehicleBodyHealth = function(e) return ents[e] and ents[e].body or 1000.0 end
_G.GetEntityType = function(e) return ents[e] and ents[e].type or 0 end
_G.IsPedAPlayer = function(e) return ents[e] == nil end
_G.GetVehiclePedIsIn = function(ped) local p = H.players[math.floor(ped / 100)]; return p and p.vehicle or 0 end
_G.GetPedInVehicleSeat = function(veh) return ents[veh] and ents[veh].driver or 0 end
_G.SetEntityHeading = function(e, h) ents[e].heading = h end
_G.FreezeEntityPosition = function(e, f) frozen[e] = f end
_G.SetVehicleNumberPlateText = function(e, p) ents[e].plate = p end
local baseCoords = _G.GetEntityCoords
_G.GetEntityCoords = function(e)
    if ents[e] then return ents[e].coords end
    return baseCoords(e)
end
_G.GetPlayerName = function(src) if dropped[tonumber(src)] then return nil end return 'Player' .. tostring(src) end
local bags = {}
_G.Entity = function(e)
    local b = bags[e]
    if not b then b = {}; bags[e] = b end
    return { state = setmetatable({ set = function(_, k, v) b[k] = v end }, { __index = b }) }
end

-- ── ox_inventory ────────────────────────────────────────────────────────────
local inv = { added = {}, removed = {}, searches = {}, slots = {} }
H.exportsMock.ox_inventory = {
    AddItem = function(src, name, count, meta)
        inv.added[#inv.added + 1] = { src = src, name = name, count = count, meta = meta }
        inv.slots[src] = inv.slots[src] or {}
        table.insert(inv.slots[src], { slot = #inv.slots[src] + 1, name = name, count = count, metadata = meta })
        return true, 'ok'
    end,
    Search = function(src, kind, name, meta)
        inv.searches[#inv.searches + 1] = { src = src, kind = kind, name = name, meta = meta }
        if inv.hidden and inv.hidden[src] then return {} end
        local out = {}
        for _, s in ipairs(inv.slots[src] or {}) do
            local ok = s.name == name and s.count > 0
            for k, v in pairs(meta or {}) do if not s.metadata or s.metadata[k] ~= v then ok = false end end
            if ok then out[#out + 1] = s end
        end
        return out
    end,
    RemoveItem = function(src, name, count, _, slot)
        inv.removed[#inv.removed + 1] = { src = src, name = name, count = count, slot = slot }
        for _, s in ipairs(inv.slots[src] or {}) do if s.slot == slot then s.count = s.count - count end end
        return true
    end,
}

-- ── stubs of the other modules ──────────────────────────────────────────────
local log = {}
local function rec(k, v) log[k] = log[k] or {}; table.insert(log[k], v) end
local function count(k) return log[k] and #log[k] or 0 end
local function last(k) return log[k] and log[k][#log[k]] end

local arena, recheck, modifierNext, flagNext = {}, {}, nil, nil
local listeners = {}
CP.Alerts = {
    set = function(src) rec('alerts.set', src) end,
    clear = function(src) rec('alerts.clear', src) end,
    inArena = function(src) return arena[src] == true end,
    foreignClearedAt = {},
}
CP.Route = {
    begin = function(run, src) rec('route.begin', src) end,
    stop = function(run, src) rec('route.stop', src) end,
    status = function(run, src) return { status = 'arrived', secondsLeft = nil, recalcsLeft = 1, distance = 0 } end,
}
CP.Draw = {
    reserve = function(runId, missionId, index) rec('draw.reserve', { runId, missionId, index }) return true end,
    release = function(runId) rec('draw.release', runId) return true end,
    recordLast = function(cid, t, m) rec('draw.recordLast', { cid, t, m }) end,
}
CP.Events = {
    rollModifier = function(run) rec('events.roll', run.id) local m = modifierNext; modifierNext = nil; return m end,
    typeOfTheDay = function() return nil end,
}
CP.Payouts = { baseFor = function(m) return m.isBoss and 2500 or 800 end }
CP.Scoring = {
    P = function(m) return m.isBoss and 500 or 200 end,
    isFirstRunSinceDuty = function(src) return src == 1 end,
    compute = function(run, p, result, opts)
        rec('scoring.compute', { src = p.src, result = result, opts = opts })
        local P = run.pointsBase
        local final = 0
        if result == 'completed' then final = P elseif result == 'failed' then final = math.floor(P * 0.25 * (opts.failedShare or 0)) end
        return { P = P, bonuses = { { id = 'fast', label = 'Fast', points = 20 } }, penalties = { { id = 'hard_ram', label = 'Ram', points = -10 } },
            subtotal = P + 10, mTeam = run.payTier and run.payTier.points or 1, mCross = 1, mStreak = 1, capped = false, tod = false,
            failedShare = opts.failedShare, final = final }
    end,
    onRowCounted = function(cid, row) rec('scoring.counted', { cid, row }) end,
}
CP.Cash = {
    compute = function(run, p)
        local tier = run.payTier or CP.Scaling.tierByName(run.expectedTier)
        local mMod = run.modifier and 1.25 or 1.0
        local amount = p.result == 'completed' and CP.U.round(run.cashBase * tier.cash * mMod) or 0
        return amount, { B = run.cashBase, mTier = tier.cash, mMod = mMod, amount = amount }
    end,
    pay = function(rowId)
        rec('cash.pay', rowId)
        local n = MySQL.update.await("UPDATE cp_mission_runs SET cash_status = 'paying' WHERE id = ? AND cash_status IN ('none','held','pending')", { rowId })
        if n == 1 then
            MySQL.update.await("UPDATE cp_mission_runs SET cash_status = 'paid', cash_paid = ROUND(cash_base * cash_multiplier) WHERE id = ?", { rowId })
        end
    end,
}
CP.Goals = { onRunCompleted = function(cid) rec('goals', cid) end }
CP.Leaderboard = { invalidate = function() rec('lb.invalidate', true) end }
CP.Challenge = { currentSeason = function() return { id = 3 } end }
CP.AntiCheat = {
    checkEvent = function(run, src, index, ev) if ev.type == 'forged' then return false, 'forged' end return true end,
    flag = function(run, src, reason, detail)
        rec('ac.flag', { reason = reason, detail = detail, src = src })
        if src then run.participants[src].flagged = { reason = reason } else run.flagged = { reason = reason } end
    end,
    presenceOk = function(run, p) return p.src ~= 99 end,
    presenceShare = function(p) return 0.4 end,
}
local unitA = { id = 11, leader = 1, members = { 1, 3 }, locked = true }
CP.Units = {
    unitOf = function(src) if src == 1 then return unitA end return nil end,
    unlock = function(unit) rec('units.unlock', unit.id) end,
}
CP.Operations = { onRunEnded = function(run, state) rec('ops.ended', { run.operationId, state }) end }
CP.Testing = { onRunEnded = function(run, state, reason) rec('testing.ended', { state, reason }) end }
CP.Tablet = {
    notify = function(src, kind, key, vars) rec('notify', { src = src, kind = kind, key = key }) end,
    push = function(src, topic, data) rec('push', { src = src, topic = topic, data = data }) end,
}
CP.Access = {
    recheck = function(src, job) local r = recheck[src]; if r then return false, r end return true end,
    onLost = function(fn) listeners.lost = fn end,
    departmentForJob = function(job) return ({ sast = 'sast', fib = 'fib' })[job] end,
}
CP.Qbx = {
    getInfo = function(src)
        local o = ({ [1] = { 'CIT1', 'sast' }, [2] = { 'CIT2', 'sast' }, [3] = { 'CIT3', 'fib' } })[src]
        if not o or dropped[src] then return nil end
        return { src = src, citizenid = o[1], job = { name = o[2] } }
    end,
    onPlayerUnload = function(fn) listeners.unload = fn end,
    onPlayerLoaded = function(fn) listeners.loaded = fn end,
    getByCitizenId = function(cid) return ({ CIT1 = 1, CIT2 = 2, CIT3 = 3 })[cid] end,
    getOnlinePlayers = function() return { 1, 2, 3 } end,
}

-- ── a recording block ───────────────────────────────────────────────────────
local calls = {}
local timeoutResult = nil
local function brec(name, ctx, a, b) calls[#calls + 1] = { name = name, index = ctx.index, a = a, b = b, obj = ctx.obj, ctx = ctx } end
local function callsOf(name, index)
    local out = {}
    for _, c in ipairs(calls) do if c.name == name and (index == nil or c.index == index) then out[#out + 1] = c end end
    return out
end
CP.Blocks.register('test_block', {
    prepare = function(ctx) brec('prepare', ctx) end,
    start = function(ctx) brec('start', ctx) end,
    tick = function(ctx, dt) brec('tick', ctx, dt) end,
    onEvent = function(ctx, src, ev) brec('onEvent', ctx, src, ev); if ev.type == 'reject' then return false, 'nope' end return true end,
    onEntityDead = function(ctx, netId, killer) brec('onEntityDead', ctx, netId, killer) end,
    onParticipantLeft = function(ctx, src) brec('onParticipantLeft', ctx, src) end,
    rescale = function(ctx) brec('rescale', ctx, ctx.obj.count) end,
    onTimeout = function(ctx) brec('onTimeout', ctx); return timeoutResult end,
    checklist = function(ctx) return { { label = 'Things', done = false, value = 1, max = ctx.obj.count or 1 }, { label = 'Boss', value = 0, max = 1 } } end,
    restart = function(ctx) brec('restart', ctx) end,
    stop = function(ctx) brec('stop', ctx) end,
})

H.load('modules/scaling/server.lua')

local mission = {
    id = 'test_mission', label = 'Test Mission', description = 'A test.', type = 'tactical', departments = {},
    minOfficers = 1, maxOfficers = 4, difficulty = 3, timeLimit = 600, startTimeout = 600, cooldown = 1200,
    locations = { { label = 'Loc A', start = { coords = vec3(100.0, 100.0, 30.0), radius = 50.0 }, spawns = { vec4(110.0, 110.0, 30.0, 90.0) } } },
    objectives = {
        { block = 'test_block', label = 'Obj one', minSeconds = 5, count = 4 },
        { block = 'test_block', label = 'Obj two', minSeconds = 0, count = 2, points = 'spawns' },
    },
    scaling = { 'objectives.1.count' },
    items = { { name = 'radio', count = 1 } },
    bonuses = {}, penalties = {}, source = 'builtin',
}
local boss = CP.U.deepcopy(mission)
boss.id, boss.label, boss.isBoss, boss.cooldown, boss.items = 'weekly_boss_kingpin', 'Kingpin', true, 600, {}
CP.Missions = {
    get = function(id) if id == 'test_mission' then return mission elseif id == 'weekly_boss_kingpin' then return boss end end,
    all = function() return { test_mission = mission, weekly_boss_kingpin = boss } end,
}

for src = 1, 6 do H.players[src] = { coords = vec3(0.0, 0.0, 0.0) } end
local O = {
    [1] = { src = 1, citizenid = 'CIT1', name = 'Alice Able', department = 'sast', departmentShort = 'SAST', job = 'sast', rank = 'Sergeant', callsign = '2L-1' },
    [2] = { src = 2, citizenid = 'CIT2', name = 'Bob Baker', department = 'sast', departmentShort = 'SAST', job = 'sast', rank = 'Trooper' },
    [3] = { src = 3, citizenid = 'CIT3', name = 'Cara Cole', department = 'fib', departmentShort = 'FIB', job = 'fib', rank = 'Agent', callsign = 'F-3' },
    [4] = { src = 4, citizenid = 'ADM4', name = 'Admin Four' },
    [5] = { src = 5, citizenid = 'CIT5', name = 'Eve Evans', department = 'sast', departmentShort = 'SAST', job = 'sast', rank = 'Trooper' },
    [6] = { src = 6, citizenid = 'CIT6', name = 'Finn Ford', department = 'fib', departmentShort = 'FIB', job = 'fib', rank = 'Agent' },
}

H.load('modules/runs/server.lua')
local Runs = CP.Runs
H.step(0)   -- the hook registration thread
H.ok(listeners.lost ~= nil and listeners.unload ~= nil and listeners.loaded ~= nil, 'hooks registered on CP.Access / CP.Qbx')

local function rowsOf(runId)
    return H.sql('SELECT * FROM cp_mission_runs WHERE run_uuid = ? ORDER BY id', { runId })
end
local function eventsTo(name, target)
    local out = {}
    for _, e in ipairs(H.findEvents(name)) do if target == nil or e.target == target then out[#out + 1] = e end end
    return out
end
local function lastEvent(name, target)
    local l = eventsTo(name, target)
    return l[#l]
end

-- ── create: validation ──────────────────────────────────────────────────────
H.eq(select(2, Runs.create({ mission = mission, locationIndex = 1, members = {} })), 'err.no_members', 'no members')
H.eq(select(2, Runs.create({ mission = mission, locationIndex = 9, members = { O[1] } })), 'err.invalid_location', 'bad location')
H.eq(select(2, Runs.create({ mission = {}, locationIndex = 1, members = { O[1] } })), 'err.invalid_mission', 'bad mission')
arena[1] = true
H.eq(select(2, Runs.create({ mission = mission, locationIndex = 1, members = { O[1] }, leaderSrc = 1 })), 'err.in_arena', 'in-arena member refused')
arena[1] = nil

-- ── Scenario A: a two-department unit, Time Crunch, completed ───────────────
H.reset()
modifierNext = 'time_crunch'
local A = Runs.create({ mission = mission, locationIndex = 1, missionType = 'tactical', members = { O[1], O[3] }, leaderSrc = 1 })
H.ok(type(A) == 'table', 'run A created')
H.eq(A.state, 'accepted', 'accepted')
H.eq(A.expectedTier, 'reinforced', 'expected tier for 2')
H.eq(A.modifier, 'time_crunch', 'modifier rolled')
H.eq(A.timeLimit, 450, 'Time Crunch cuts 25%')
H.eq(A.cashBase, 800, 'B locked from CP.Payouts.baseFor')
H.eq(A.pointsBase, 200, 'P from CP.Scoring.P')
H.eq(A.host, 1, 'host = leader')
H.eq(A.participants[1].firstRunSinceDuty, true, 'first run since duty captured')
H.eq(#eventsTo('crimson-police:client:start'), 2, 'client:start to each participant')
local startData = lastEvent('crimson-police:client:start', 3).args[2]
H.eq(startData.startRoute, true, 'start route on')
H.eq(startData.expectedTier, 'reinforced', 'client:start expected tier')
H.eq(startData.mission.locations, nil, 'mission sent without the location list')
H.eq(#startData.participants, 2, 'participants list')
H.eq(count('route.begin'), 2, 'CP.Route.begin per participant')
H.eq(last('draw.reserve')[1], A.id, 'location reserved under the run id')
H.eq(#inv.added, 2, 'mission items given')
H.eq(inv.added[1].meta.cpRun, A.id, 'items tagged with the run')
H.eq(inv.added[1].meta.cpItem, true, 'items tagged cpItem')
H.ok(Runs.isOnMission(1) and Runs.isOnMission(3), 'isOnMission')
H.eq(Runs.getBySrc(3), A, 'getBySrc')
H.eq(select(2, Runs.getBySrc(3)).citizenid, 'CIT3', 'getBySrc participant')
H.eq(select(2, Runs.create({ mission = mission, locationIndex = 1, members = { O[1] }, leaderSrc = 1 })), 'err.already_on_run', 'one run at a time')
H.eq(select(2, Runs.create({ mission = mission, locationIndex = 1, members = { O[2], O[3] }, leaderSrc = 2 })), 'err.member_on_run', 'member on a run')
H.ok(Runs.capsOk('tactical'), 'caps ok with one run')
Config.Limits.maxConcurrentTactical = 1
H.eq(select(2, Runs.capsOk('tactical')), 'err.server_busy', 'tactical cap')
H.ok(Runs.capsOk('patrol'), 'patrol not blocked by the tactical cap')
Config.Limits.maxConcurrentTactical = 4
Config.Limits.maxConcurrentRuns = 1
H.ok(not Runs.capsOk('patrol'), 'server cap')
Config.Limits.maxConcurrentRuns = 12
local v0 = Runs.view(A, 1)
H.eq(v0.state, 'accepted', 'view accepted')
H.eq(v0.tierExpected, true, 'tier expected before the start')
H.eq(#v0.objectives, 2, 'objective labels before the start')
H.eq(v0.remaining, nil, 'no timer before the start')
H.ok(count('push') >= 2, 'run pushed at create')

-- ── arrival -> in progress ──────────────────────────────────────────────────
H.reset()
Runs.markArrived(A, 1)
H.eq(last('alerts.set'), 1, 'alert flag on arrival')
H.eq(A.state, 'in_progress', 'first arrival -> in progress')
H.eq(A.tier.tier, 'reinforced', 'tier from the active participants')
H.eq(A.payTier.tier, 'reinforced', 'pay tier')
local ip = lastEvent('crimson-police:client:inProgress', 3)
H.ok(ip ~= nil, 'client:inProgress to a participant still driving')
H.eq(ip.args[2].objectives[1].count, 5, 'scaled objectives (4 x 1.25)')
H.eq(ip.args[2].remaining, 450, 'timer in client:inProgress')
local order = {}
for _, c in ipairs(calls) do order[#order + 1] = c.name .. c.index end
H.eq(table.concat(order, ','), 'prepare1,prepare2,start1', 'every block prepare then objective 1 start')
H.eq(callsOf('prepare', 1)[1].ctx.obj.count, 5, 'ctx.obj is the scaled copy')
H.eq(callsOf('prepare', 1)[1].ctx.base.count, 4, 'ctx.base is the unscaled objective')
H.eq(callsOf('prepare', 1)[1].ctx.state, A.objectives[1].state, 'ctx.state is the persistent objective state')
H.near(Runs.remaining(A), 450, 0.01, 'timer running')
Runs.markArrived(A, 3)
H.eq(count('alerts.set'), 2, 'second arrival flagged')
H.eq(#callsOf('start', 1), 1, 'no second start')

-- tick
H.advance(1000)
H.ok(#callsOf('tick', 1) >= 1, 'block tick of the current objective')
H.near(Runs.remaining(A), 449, 0.2, 'timer counts down')
local hudEv = lastEvent('crimson-police:client:hud', 1)
H.ok(hudEv ~= nil, 'HUD sent')

-- award / penalize
Runs.award(A, 'hostile_arrested', { count = 2 })
Runs.penalize(A, 'hard_ram', { src = 1 })
Runs.penalize(A, 'hostage_hit', { points = 50 })
H.eq(A.score.shared.hostile_arrested, 2, 'shared award count')
H.eq(A.participants[1].score.hard_ram, 1, 'personal penalty count')
H.eq(A.score.values.hostage_hit, -50, 'penalty value hint is negative')
H.eq(A.score.kinds.hostile_arrested, 'bonus', 'kind recorded')

-- timers
Runs.adjustTimer(A, -30)
H.near(Runs.remaining(A), 419, 0.2, 'adjustTimer')
Runs.pauseTimer(A, true)
H.advance(2000)
H.near(Runs.remaining(A), 419, 0.2, 'paused timer does not run')
Runs.pauseTimer(A, false)
local th = lastEvent('crimson-police:client:hud', 1).args[2]
H.eq(th.timer.paused, false, 'timer HUD patch')

-- entities
local ped, pedNet = Runs.spawnPed(A, { obj = 1, model = 'g_m_y_ballaeast_01', coords = vec4(110.0, 110.0, 30.0, 90.0), role = 'hostile', armed = true, weapon = 'WEAPON_PISTOL', accuracy = 30, armour = 10 })
H.ok(ped ~= nil and pedNet ~= nil, 'spawnPed')
H.eq(bags[ped].cp.run, A.id, 'cp state bag run')
H.eq(bags[ped].cp.obj, 1, 'cp state bag objective')
H.eq(bags[ped].cp.cfg.accuracy, 30, 'cp cfg accuracy')
H.eq(ents[ped].armour, 10, 'armour set')
H.ok(ents[ped].weapon ~= nil, 'weapon given')
H.eq(A.entities[pedNet].armed, true, 'tracked as armed')
Config.Limits.maxArmedAlive = 1
H.ok(not Runs.canSpawn(A, 1, true), 'armed cap')
H.ok(Runs.canSpawn(A, 1, false), 'unarmed still fits')
H.eq(Runs.spawnPed(A, { obj = 1, model = 'x', coords = vec4(0, 0, 0, 0), armed = true }), nil, 'spawn refused over the cap')
Runs.entityDied(A, pedNet, 1)
H.ok(A.entities[pedNet].dead, 'marked dead')
H.eq(callsOf('onEntityDead', 1)[1].a, pedNet, 'block onEntityDead')
H.eq(callsOf('onEntityDead', 1)[1].b, 1, 'killer passed')
H.eq(A.stats.kills[1], 1, 'kill stats')
H.ok(Runs.canSpawn(A, 1, true), 'a dead NPC frees the armed cap')
Config.Limits.maxArmedAlive = 25
Config.Limits.maxEntities = 1
H.ok(not Runs.canSpawn(A, 1, false), 'entity cap counts corpses')
Config.Limits.maxEntities = 80
H.eq(#Runs.entitiesFor(A, { kind = 'ped', dead = true }), 1, 'entitiesFor filter')
H.time = H.time + 31
H.advance(1000)
H.eq(A.entities[pedNet], nil, 'corpse deleted after corpseCleanup')
H.ok(deleted[ped], 'DeleteEntity called')
local veh, vehNet = Runs.spawnVehicle(A, { obj = 1, model = 'sultan', coords = vec4(1, 2, 3, 4), role = 'car', plate = 'CP123' })
H.eq(ents[veh].plate, 'CP123', 'plate set')
ents[veh].engine = -4000.0
H.advance(1000)
H.ok(A.entities[vehNet].dead, 'wrecked vehicle detected')
H.eq(A.stats.vehiclesWrecked, 1, 'wrecked stats')
local obj, objNet = Runs.spawnObject(A, { obj = 1, model = 'prop_ld_bomb', coords = vec4(5, 5, 5, 45) })
H.eq(frozen[obj], true, 'object frozen')
H.eq(ents[obj].heading, 45.0, 'object heading')
local ped2, ped2Net = Runs.spawnPed(A, { obj = 1, model = 'a_m_m_business_01', coords = vec4(0, 0, 0, 0), role = 'hostage' })
ents[ped2].exists = false
H.advance(2000)
H.eq(A.entities[ped2Net], nil, 'vanished entity forgotten')
H.ok(#callsOf('onEntityDead', 1) >= 3, 'vanished entity went through the death path')
H.ok(Runs.deleteEntity(A, objNet), 'deleteEntity')

-- telemetry
local car = newEnt('vehicle', 'police', 0, 0, 0)
ents[car].driver, ents[car].engine, ents[car].body = 100, 800.0, 700.0
H.players[1].vehicle = car
H.fire('crimson-police:server:telemetry', 1, A.id, 'vehicle', { netId = ents[car].net })
H.eq(A.participants[1].vehicle.body, 700.0, 'lowest body health stored')
H.eq(A.participants[1].vehicle.seen, true, 'vehicle seen')
local walker = newEnt('ped', 'a_m_y_hipster_01', 5, 0, 0)
H.fire('crimson-police:server:telemetry', 1, A.id, 'ped_hit', { netId = ents[walker].net })
H.fire('crimson-police:server:telemetry', 1, A.id, 'ped_hit', { netId = ents[walker].net })
H.eq(A.participants[1].score.pedestrian_hit, 1, 'pedestrian hit counted once')
local far = newEnt('ped', 'a_m_y_hipster_01', 500, 0, 0)
H.fire('crimson-police:server:telemetry', 1, A.id, 'ped_hit', { netId = ents[far].net })
H.eq(A.participants[1].score.pedestrian_hit, 1, 'a far ped is not a hit')
H.fire('crimson-police:server:telemetry', 1, A.id, 'lights_siren', {})
H.eq(A.participants[1].score.lights_siren, nil, 'lights only on Beat Patrol / Business Check')
A.missionId = 'beat_patrol'
H.fire('crimson-police:server:telemetry', 1, A.id, 'lights_siren', {})
A.missionId = 'test_mission'
H.eq(A.participants[1].score.lights_siren, 1, 'lights and siren penalty')
H.fire('crimson-police:server:telemetry', 3, A.id, 'weapon_fired', {})
H.fire('crimson-police:server:telemetry', 3, A.id, 'weapon_fired', {})
H.eq(A.stats.weaponsFired, 1, 'weapon fired once per participant')
H.fire('crimson-police:server:telemetry', 2, A.id, 'weapon_fired', {})
H.eq(A.stats.weaponsFired, 1, 'non-participant telemetry ignored')
H.fire('crimson-police:server:telemetry', 1, A.id, 'nonsense', {})
arena[3] = true
H.fire('crimson-police:server:telemetry', 3, A.id, 'ped_hit', { netId = ents[walker].net })
arena[3] = nil

-- objective evidence
local before = #callsOf('onEvent', 1)
H.fire('crimson-police:server:objective', 1, A.id, 1, { type = 'hit', value = 3 })
H.eq(#callsOf('onEvent', 1), before + 1, 'evidence reaches the block')
H.eq(callsOf('onEvent', 1)[before + 1].a, 1, 'onEvent src')
H.fire('crimson-police:server:objective', 1, A.id, 2, { type = 'hit' })
H.fire('crimson-police:server:objective', 2, A.id, 1, { type = 'hit' })
H.fire('crimson-police:server:objective', 1, A.id, 1, { type = 'forged' })
H.fire('crimson-police:server:objective', 1, A.id, 1, { type = 'hit', deep = { a = { b = { c = { d = 1 } } } } })
H.fire('crimson-police:server:objective', 1, 'no-such-run', 1, { type = 'hit' })
H.fire('crimson-police:server:objective', 1, A.id, 1, 'not a table')
H.eq(#callsOf('onEvent', 1), before + 1, 'wrong index, non-participant, forged, deep or malformed evidence rejected')
H.ok(Runs.dispatch(A, 1, nil, { type = 'cuffed', netId = 5 }), 'dispatch a server event')
H.eq(callsOf('onEvent', 1)[#callsOf('onEvent', 1)].b.type, 'cuffed', 'dispatch reaches onEvent')
H.eq(select(2, Runs.dispatch(A, 1, 1, { type = 'reject' })), 'nope', 'dispatch returns the block reason')

-- view / summary / getRun
A.objectives[1].state.log = { point = 2, choices = { { id = 'secure', label = 'Secure' } } }
local v = Runs.view(A, 1)
H.eq(v.runId, A.id, 'view runId')
H.eq(v.state, 'in_progress', 'view state')
H.eq(v.tier, 'reinforced', 'view tier')
H.eq(v.tierExpected, false, 'tier no longer expected')
H.eq(v.objectives[1].current, true, 'current objective')
H.eq(v.objectives[1].max, 5, 'checklist max')
H.eq(v.objectives[1].detail, 'Boss 0/1', 'extra checklist lines as detail')
H.eq(v.objectives[2].current, false, 'next objective not current')
H.eq(#v.partners, 2, 'partners')
H.eq(v.modifier.key, 'time_crunch', 'modifier view')
H.eq(v.route.status, 'arrived', 'route from CP.Route.status')
H.eq(v.recalcsLeft, 1, 'recalcs left')
H.eq(v.log.point, 2, 'log from the current objective state')
H.eq(v.expected.cash, 1150, 'expected cash = B x tier x modifier')
H.eq(v.expected.points, 302, 'expected points')
H.eq(v.radioSilence, false, 'radio silence flag')
H.eq(v.test, false, 'not a test')
local s = Runs.summary(A)
H.eq(#s.participants, 2, 'summary participants')
H.eq(s.tier, 'reinforced', 'summary tier')
H.ok(type(s.remaining) == 'number', 'summary remaining')
local cb = H.callback('crimson-police:getRun', 1)
H.eq(cb.ok, true, 'getRun ok')
H.eq(cb.data.runId, A.id, 'getRun returns the view')
H.eq(H.callback('crimson-police:getRun', 2).data, nil, 'getRun without a run')
A.objectives[1].state.log = nil

-- objective 1 done after minSeconds
H.advance(3000)
H.ok(Runs.objectiveComplete(A, 1, { ok = true }), 'objective 1 completes after minSeconds')
H.eq(A.objectiveIndex, 2, 'objective 2 current')
H.eq(#callsOf('stop', 1), 1, 'objective 1 stopped')
H.eq(#callsOf('start', 2), 1, 'objective 2 started')
H.eq(count('ac.flag'), 0, 'no too_fast flag')
H.eq(Runs.objectiveComplete(A, 1), false, 'objective accepted once')

-- a partner leaves for a real call: tier drops, pay tier stays
H.reset()
local rowC = Runs.removeParticipant(A, 3, 'real_call')
H.ok(rowC ~= nil, 'row id for the leaver')
local r3 = rowsOf(A.id)[1]
H.eq(r3.citizenid, 'CIT3', 'leaver row')
H.eq(r3.state, 'abandoned', 'real_call is abandoned')
H.eq(r3.end_reason, 'real_call', 'end reason stored')
H.eq(r3.participants, 2, 'participants = still active + self')
H.eq(r3.departments_n, 2, 'departments on the run')
H.eq(r3.tier, 'reinforced', 'pay tier stored')
H.eq(r3.final_points, 0, 'abandoned earns 0')
H.eq(r3.cash_status, 'none', 'no cash for abandoned')
H.eq(r3.season_id, 3, 'season id')
H.eq(r3.department, 'fib', 'department at the end')
H.eq(r3.modifier, 'time_crunch', 'modifier stored')
H.eq(CP.U.jsonField(r3.breakdown).result, 'abandoned', 'breakdown JSON')
H.eq(A.tier.tier, 'standard', 'tier follows the team down')
H.eq(A.payTier.tier, 'reinforced', 'real_call keeps the pay tier')
local tc = lastEvent('crimson-police:client:tierChanged', 1)
H.eq(tc.args[2], 'standard', 'client:tierChanged tier')
H.eq(tc.args[3], 'reinforced', 'client:tierChanged pay tier')
H.eq(callsOf('rescale', 2)[1].a, 2, 'rescale with the re-scaled ctx.obj')
H.eq(#callsOf('rescale', 1), 0, 'done objectives are not rescaled')
H.eq(callsOf('onParticipantLeft', 2)[1].a, 3, 'onParticipantLeft for the current objective')
H.ok(log['alerts.clear'] and log['alerts.clear'][1] == 3, 'flag cleared')
H.eq(last('route.stop'), 3, 'route stopped')
H.eq(inv.removed[#inv.removed].src, 3, 'items removed by slot')
local ended3 = lastEvent('crimson-police:client:runEnded', 3)
H.eq(ended3.args[2], 'abandoned', 'client:runEnded result')
H.eq(ended3.args[4].endReason, 'real_call', 'RunResult end reason')
H.eq(Runs.isOnMission(3), false, 'leaver is off the mission')
H.eq(Runs.cooldowns('CIT3').types.tactical, nil, 'real_call: no type cooldown')
H.eq(Runs.cooldowns('CIT3').missions.test_mission, nil, 'real_call: no mission cooldown')
H.eq(lastEvent('crimson-police:client:participants', 1).args[2][2].status, 'left', 'participants update')
H.ok(Runs.isOnMission(1), 'run continues for the rest')

-- the real call is un-marked within the window
H.ok(Runs.reclassify('CIT3', A.id, 'real_call_cancelled'), 'reclassify')
local r3b = rowsOf(A.id)[1]
H.eq(r3b.end_reason, 'real_call_cancelled', 'row reclassified')
H.eq(CP.U.jsonField(r3b.breakdown).endReason, 'real_call_cancelled', 'breakdown reclassified')
H.ok((Runs.cooldowns('CIT3').types.tactical or 0) > os.time(), 'type cooldown after reclassify')
H.ok((Runs.cooldowns('CIT3').missions.test_mission or 0) > os.time(), 'mission cooldown after reclassify')
H.eq(A.payTier.tier, 'standard', 'pay tier drops after reclassify')
H.eq(Runs.reclassify('CIT3', A.id, 'real_call_cancelled'), true, 'reclassify is idempotent')

-- last objective -> completed
H.reset()
local invBefore = #inv.removed
H.ok(Runs.objectiveComplete(A, 2), 'objective 2 done')
H.eq(A.state, 'ended', 'run ended')
H.eq(Runs.get(A.id), nil, 'run forgotten')
H.eq(Runs.isOnMission(1), false, 'isOnMission false after the end')
local rows = rowsOf(A.id)
H.eq(#rows, 2, 'one row per participant')
local r1 = rows[2]
H.eq(r1.citizenid, 'CIT1', 'row of the finisher')
H.eq(r1.state, 'completed', 'completed')
H.eq(r1.end_reason, 'completed', 'end reason completed')
H.eq(r1.participants, 1, 'participants at the end')
H.eq(r1.departments_n, 1, 'departments at the end')
H.eq(r1.tier, 'standard', 'pay tier used')
H.eq(r1.points_base, 200, 'points_base')
H.eq(r1.bonus_points, 20, 'bonus_points')
H.eq(r1.penalty_points, 10, 'penalty_points (positive)')
H.eq(r1.final_points, 200, 'final_points')
H.eq(r1.cash_base, 800, 'cash_base')
H.near(tonumber(r1.cash_multiplier), 1.25, 1e-9, 'cash_multiplier = tier x modifier')
H.eq(r1.cash_status, 'paid', 'paid through CP.Cash.pay')
H.eq(r1.cash_paid, 1000, 'cash paid')
H.eq(r1.flagged, 0, 'not flagged')
H.eq(r1.location_label, 'Loc A', 'location label')
H.ok(r1.duration_s >= 0, 'duration')
local bd = CP.U.jsonField(r1.breakdown)
H.eq(bd.cash.status, 'paid', 'breakdown carries the final cash status')
H.eq(bd.points.final, 200, 'breakdown points')
H.eq(bd.participants, 1, 'breakdown participants')
H.eq(last('cash.pay'), r1.id, 'CP.Cash.pay for the completed row')
H.eq(last('scoring.counted')[1], 'CIT1', 'onRowCounted')
H.eq(last('scoring.counted')[2].id, r1.id, 'onRowCounted row')
H.eq(last('goals'), 'CIT1', 'goals hook')
H.eq(last('draw.recordLast')[3], 'test_mission', 'recordLast')
H.eq(last('units.unlock'), 11, 'unit unlocked')
H.ok(count('lb.invalidate') >= 1, 'leaderboard invalidated')
H.eq(last('draw.release'), A.id, 'reservation released')
H.eq(next(A.entities), nil, 'every entity deleted')
H.ok(#inv.removed > invBefore, 'items removed at the end')
local ended1 = lastEvent('crimson-police:client:runEnded', 1)
H.eq(ended1.args[2], 'completed', 'client:runEnded completed')
H.eq(ended1.args[4].cash.amount, 1000, 'RunResult cash')
H.eq(ended1.args[4].cash.status, 'paid', 'RunResult cash status')
H.eq(ended1.args[4].payTier, 'standard', 'RunResult pay tier')
H.eq(last('push').data, nil, 'run push cleared')
H.ok(Runs.onCooldown('CIT1', 'tactical', 'test_mission'), 'mission cooldown after completing')
H.eq(Runs.cooldowns('CIT1').types.tactical, nil, 'no type cooldown after completing')
H.eq(#callsOf('stop', 2), 1, 'last objective stopped once')

-- completions in the last hour (manual awards and goals excluded)
H.eq(Runs.completionsLastHour('CIT1'), 1, 'completions last hour')
MySQL.insert.await("INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason, points_base) VALUES (?, 'manual_award', 'manual_award', 'CIT1', 'sast', 'completed', 'completed', 0)", { 'manual-1' })
H.time = H.time + 11
H.eq(Runs.completionsLastHour('CIT1'), 1, 'manual awards do not count')

-- cooldowns rebuilt from rows after a restart
MySQL.insert.await("INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason, points_base) VALUES (?, 'tactical', 'test_mission', 'CIT9', 'sast', 'abandoned', 'quit', 200)", { 'old-1' })
MySQL.insert.await("INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason, points_base) VALUES (?, 'tactical', 'weekly_boss_kingpin', 'CIT8', 'sast', 'abandoned', 'quit', 500)", { 'old-2' })
local cd9 = Runs.cooldowns('CIT9')
H.ok((cd9.types.tactical or 0) > os.time(), 'type cooldown rebuilt')
H.ok((cd9.missions.test_mission or 0) > os.time(), 'mission cooldown rebuilt')
local on, untilTs = Runs.onCooldown('CIT9', 'tactical', 'other')
H.ok(on and untilTs == cd9.types.tactical, 'onCooldown by type')
local cd8 = Runs.cooldowns('CIT8')
H.eq(cd8.types.tactical, nil, 'a boss abandon starts no type cooldown')
H.ok((cd8.missions.weekly_boss_kingpin or 0) > os.time(), 'boss mission cooldown rebuilt')

-- reclassify of a run that is no longer in memory
MySQL.insert.await("INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason, points_base, breakdown) VALUES (?, 'tactical', 'test_mission', 'CIT7', 'sast', 'abandoned', 'real_call', 200, ?)", { 'ext-run', '{"endReason":"real_call"}' })
H.ok(Runs.reclassify('CIT7', 'ext-run', 'real_call_cancelled'), 'reclassify from the row')
H.eq(rowsOf('ext-run')[1].end_reason, 'real_call_cancelled', 'external row updated')
H.ok((Runs.cooldowns('CIT7').types.tactical or 0) > os.time(), 'cooldown for the external row')
H.eq(Runs.reclassify('CIT7', 'no-row', 'real_call_cancelled'), false, 'no row -> false')

-- ── Scenario B: solo, completed too fast -> flagged, cash held ──────────────
H.reset()
local B = Runs.create({ mission = mission, locationIndex = 1, missionType = 'tactical', members = { O[2] }, leaderSrc = 2 })
Runs.markArrived(B, 2)
H.eq(B.tier.tier, 'standard', 'solo tier')
H.advance(1000)
H.eq(Runs.objectiveComplete(B, 1), false, 'early completion refused')
H.eq(Runs.objectiveComplete(B, 1), false, 'still refused')
H.eq(count('ac.flag'), 1, 'too_fast flagged once')
H.eq(last('ac.flag').reason, 'too_fast', 'flag reason')
H.advance(5000)
local paysBefore, countedBefore = count('cash.pay'), count('scoring.counted')
H.ok(Runs.objectiveComplete(B, 1), 'completes after minSeconds')
H.ok(Runs.objectiveComplete(B, 2), 'last objective')
local rb = rowsOf(B.id)[1]
H.eq(rb.flagged, 1, 'flagged row')
H.eq(rb.flag_reason, 'too_fast', 'flag reason stored')
H.eq(rb.cash_status, 'held', 'flagged rows hold their cash')
H.eq(count('cash.pay'), paysBefore, 'no payment for a flagged row')
H.eq(count('scoring.counted'), countedBefore, 'flagged rows do not count yet')
H.eq(lastEvent('crimson-police:client:runEnded', 2).args[4].flagged.reason, 'too_fast', 'RunResult flagged')

-- ── Scenario C: time limit, then a block that completes on timeout ──────────
H.reset()
local C = Runs.create({ mission = mission, locationIndex = 1, missionType = 'tactical', members = { O[1] }, leaderSrc = 1 })
Runs.markArrived(C, 1)
Runs.adjustTimer(C, -598)
H.advance(3000)
H.eq(C.state, 'ended', 'time limit ends the run')
H.eq(#callsOf('onTimeout', 1), 1, 'block onTimeout asked')
local rc = rowsOf(C.id)[1]
H.eq(rc.state, 'failed', 'time_limit is failed')
H.eq(rc.end_reason, 'time_limit', 'end reason time_limit')
H.eq(last('scoring.compute').opts.failedShare, 0, 'failed share of objectives done')
H.eq(Runs.cooldowns('CIT1').types.tactical, nil, 'time_limit: no type cooldown')

H.reset()
timeoutResult = 'completed'
local C2 = Runs.create({ mission = mission, locationIndex = 1, missionType = 'tactical', members = { O[1] }, leaderSrc = 1 })
Runs.markArrived(C2, 1)
Runs.adjustTimer(C2, -599)
H.advance(2000)
timeoutResult = nil
H.eq(rowsOf(C2.id)[1].state, 'completed', 'onTimeout completed -> completed')

-- ── Scenario D: an operation run; disconnect and unload ─────────────────────
H.reset()
local rollsD = count('events.roll')
local D = Runs.create({ mission = mission, locationIndex = 1, missionType = 'tactical', members = { O[1], O[2] }, leaderSrc = 1, operationId = 7 })
H.eq(D.modifier, nil, 'no modifier on operations')
H.eq(count('events.roll'), rollsD, 'rollModifier not asked for operations')
Config.Limits.maxConcurrentRuns = 1
H.ok(Runs.capsOk('tactical'), 'operations do not count toward the caps')
Config.Limits.maxConcurrentRuns = 12
Runs.markArrived(D, 1)
dropped[2] = true
H.fire('playerDropped', 2)
dropped[2] = nil
local rd = rowsOf(D.id)[1]
H.eq(rd.end_reason, 'disconnected', 'disconnected')
H.eq(rd.state, 'failed', 'disconnect is failed')
H.eq(rd.operation_id, 7, 'operation id stored')
H.eq(rd.department, 'sast', 'department fallback for a dropped player')
H.ok((Runs.cooldowns('CIT2').types.tactical or 0) > os.time(), 'disconnect: type cooldown')
H.eq(D.payTier.tier, 'standard', 'disconnect drops the pay tier')
listeners.unload(1)
H.eq(D.state, 'ended', 'last participant gone -> run ended')
H.eq(D.endState, 'failed', 'a run whose last participant failed ends failed')
H.eq(rowsOf(D.id)[2].end_reason, 'disconnected', 'unload -> disconnected')
H.eq(last('ops.ended')[1], 7, 'CP.Operations.onRunEnded')
H.eq(last('ops.ended')[2], 'failed', 'operation told the run failed')

-- ── Scenario E: a test run writes nothing ───────────────────────────────────
H.reset()
local rollsBefore = count('events.roll')
local E = Runs.create({ mission = mission, locationIndex = 1, missionType = 'tactical', members = { O[4], O[6] }, leaderSrc = 4,
    test = { adminSrc = 4, useStartRoute = false, forcedTier = 'heavy' } })
H.eq(E.expectedTier, 'heavy', 'forced tier expected')
H.eq(count('events.roll'), rollsBefore, 'no modifier roll on tests')
H.eq(lastEvent('crimson-police:client:start', 4).args[2].startRoute, false, 'start route off')
Runs.markArrived(E, 4)
H.eq(E.tier.tier, 'heavy', 'forced tier used')
H.eq(E.objectives[1].obj.count, 6, 'scaled at the forced tier')
recheck[4] = 'job_change'
Runs._jobRecheck()
recheck[4] = nil
H.ok(Runs.isParticipant(E, 4), 'non-officer testers are not rechecked')
H.ok(Runs.testSkip(E), 'testSkip')
H.eq(E.objectiveIndex, 2, 'skip starts the next objective')
H.eq(count('ac.flag'), 1, 'skip is not flagged')
H.ok(Runs.testRestart(E), 'testRestart')
H.eq(#callsOf('restart', 2), 1, 'block restart')
local anc = Runs.anchor(E)
H.eq(anc.x, 110.0, 'anchor at the current objective point')
H.eq(Runs.cooldowns('CIT6').types.tactical, nil, 'no cooldown history for CIT6')
Runs.removeParticipant(E, 6, 'quit')
H.eq(Runs.cooldowns('CIT6').types.tactical, nil, 'test runs start no type cooldown')
H.eq(Runs.cooldowns('CIT6').missions.test_mission, nil, 'test runs start no mission cooldown')
Runs.endRun(E, 'completed', 'completed')
H.eq(#rowsOf(E.id), 0, 'test runs write no rows')
local re = lastEvent('crimson-police:client:runEnded', 4).args[4]
H.eq(re.test, true, 'RunResult test flag')
H.eq(re.points.final, 200, 'would-have points shown')
H.eq(re.cash.amount, 1040, 'would-have cash shown (800 x 1.30)')
H.eq(re.cash.status, 'none', 'nothing paid')
H.eq(last('testing.ended')[1], 'completed', 'CP.Testing.onRunEnded')

-- ── Scenario F: Weekly Boss, host succession, downed, abandon action ────────
H.reset()
local F = Runs.create({ mission = boss, locationIndex = 1, missionType = 'weekly_boss', members = { O[5], O[6] }, leaderSrc = 5, isBoss = true })
H.eq(F.missionType, 'tactical', 'boss runs are tactical')
H.eq(F.cashBase, 2500, 'boss payout')
H.eq(F.host, 5, 'host = leader')
Runs.markArrived(F, 6)
dropped[5] = true
H.advance(1000)
dropped[5] = nil
H.eq(F.host, 6, 'next participant takes over the AI')
H.eq(lastEvent('crimson-police:client:hostChanged', 6).args[2], 6, 'client:hostChanged')
local clearsBefore = count('alerts.clear')
Runs.removeParticipant(F, 5, 'downed', { keepFlag = true })
H.eq(count('alerts.clear'), clearsBefore, 'downed keeps the flag')
H.eq(F.stats.downs, 1, 'downs counted')
H.eq(F.payTier.tier, 'reinforced', 'downed keeps the pay tier')
H.eq(rowsOf(F.id)[1].state, 'failed', 'downed is failed')
H.eq(Runs.cooldowns('CIT5').missions.weekly_boss_kingpin ~= nil, true, 'boss mission cooldown')
H.eq(Runs.cooldowns('CIT5').types.tactical, nil, 'boss downed: no type cooldown')
H.fire('crimson-police:server:abandon', 6, F.id, 'req-1')
local ar = lastEvent('crimson-police:client:actionResult', 6)
H.eq(ar.args[1], 'req-1', 'abandon replies')
H.eq(ar.args[2], true, 'abandon ok')
H.eq(F.state, 'ended', 'abandon of the last participant ends the run')
local rf = rowsOf(F.id)[2]
H.eq(rf.end_reason, 'quit', 'abandon = quit')
H.eq(rf.mission_type, 'tactical', 'boss row stored as tactical')
H.eq(Runs.cooldowns('CIT6').types.tactical, nil, 'boss abandon: no type cooldown')
H.ok((Runs.cooldowns('CIT6').missions.weekly_boss_kingpin or 0) > os.time(), 'boss abandon: mission cooldown')
H.fire('crimson-police:server:abandon', 6, F.id, 'req-2')
H.eq(lastEvent('crimson-police:client:actionResult', 6).args[3], 'err.invalid_run', 'abandon of an ended run')

-- ── Scenario G: start timeout, arena, job recheck, onLost ───────────────────
H.reset()
local G = Runs.create({ mission = mission, locationIndex = 1, missionType = 'tactical', members = { O[1] }, leaderSrc = 1 })
G.participants[1].deadline = os.time() - 1
H.advance(1000)
H.eq(rowsOf(G.id)[1].end_reason, 'start_timeout', 'start timeout')
H.ok((Runs.cooldowns('CIT1').types.tactical or 0) > os.time(), 'start timeout: type cooldown')

H.reset()
local G2 = Runs.create({ mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[3] }, leaderSrc = 3 })
arena[3] = true
H.advance(1000)
arena[3] = nil
H.eq(rowsOf(G2.id)[1].end_reason, 'quit', 'arena -> quit')
H.eq(last('notify').key, 'run.left_for_arena', 'arena notification')

H.reset()
local G3 = Runs.create({ mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[3] }, leaderSrc = 3 })
recheck[3] = 'off_duty'
Runs._jobRecheck()
recheck[3] = nil
H.eq(rowsOf(G3.id)[1].end_reason, 'off_duty', 'job recheck -> off_duty')

H.reset()
local G4 = Runs.create({ mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[3] }, leaderSrc = 3 })
listeners.lost(3, 'suspended')
H.eq(rowsOf(G4.id)[1].end_reason, 'suspended', 'onLost -> suspended')

-- ── Scenario K: failRun ─────────────────────────────────────────────────────
H.reset()
local K = Runs.create({ mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[3] }, leaderSrc = 3 })
Runs.markArrived(K, 3)
local ctx = callsOf('start', 1)[#callsOf('start', 1)].ctx
H.eq(ctx.run, K, 'ctx.run')
H.eq(ctx.host(), 3, 'ctx.host')
H.ok(ctx.isHost(3), 'ctx.isHost')
H.eq(ctx.participants()[1], 3, 'ctx.participants')
H.ok(ctx.coords(3) ~= nil, 'ctx.coords')
local acc, arm = ctx.combat(25, 0)
H.eq(acc, 25, 'ctx.combat accuracy (standard)')
ctx.hud({ detail = 'Wave 1 of 3', value = 2, max = 7, message = { text = 'Hi', kind = 'info' } })
H.eq(K.objectives[1].hud.detail, 'Wave 1 of 3', 'ctx.hud objective detail')
H.eq(Runs.view(K, 3).objectives[1].value, 2, 'ctx.hud value wins over the checklist')
H.eq(lastEvent('crimson-police:client:hud', 3).args[2].message.text, 'Hi', 'ctx.hud message is top level')
ctx.fail('run.fail_killed_unarmed')
H.eq(K.state, 'ended', 'fail ends the run')
local rk = rowsOf(K.id)[1]
H.eq(rk.end_reason, 'mission_failed', 'mission_failed')
H.eq(lastEvent('crimson-police:client:runEnded', 3).args[4].failReason, 'run.fail_killed_unarmed', 'fail reason in the result')

-- ── orphaned items and the sweep ────────────────────────────────────────────
H.reset()
local L = Runs.create({ mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[3] }, leaderSrc = 3 })
inv.hidden = { [3] = true }
Runs.removeParticipant(L, 3, 'quit')
inv.hidden = nil
local removedBefore = #inv.removed
listeners.loaded(3)
H.advance(5000)
H.ok(#inv.removed > removedBefore, 'orphaned items swept when the player loads')
H.eq(inv.searches[#inv.searches].meta.cpItem, true, 'sweep searches cpItem metadata')

-- ── review: create re-checks after its lookups (they may yield) ─────────────
H.reset()
local origBase = CP.Payouts.baseFor
local nested
CP.Payouts.baseFor = function(m)
    CP.Payouts.baseFor = origBase
    nested = Runs.create({ mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[5] }, leaderSrc = 5 })
    return 800
end
local raced, racedErr = Runs.create({ mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[5] }, leaderSrc = 5 })
CP.Payouts.baseFor = origBase
H.eq(raced, nil, 'an accept that raced another one for the same officer is refused')
H.eq(racedErr, 'err.already_on_run', 'race refusal reason')
H.ok(type(nested) == 'table' and Runs.getBySrc(5) == nested, 'the run that won the race stays')
Runs.removeParticipant(nested, 5, 'cancelled')

local winner
Config.Limits.maxConcurrentRuns = #Runs.all() + 1
CP.Payouts.baseFor = function(m)
    CP.Payouts.baseFor = origBase
    winner = Runs.create({ mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[6] }, leaderSrc = 6 })
    return 800
end
local capped, cappedErr = Runs.create({ mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[5] }, leaderSrc = 5 })
CP.Payouts.baseFor = origBase
Config.Limits.maxConcurrentRuns = 12
H.eq(capped, nil, 'two racing accepts never pass the server cap together')
H.eq(cappedErr, 'err.server_busy', 'cap refusal reason')
H.eq(Runs.isOnMission(5), false, 'the refused officer is on no run')
H.ok(type(winner) == 'table', 'the accept that got the last slot runs')
Runs.removeParticipant(winner, 6, 'cancelled')

-- ── review: entity health before the first sync, late spawns, pending spawns ─
H.reset()
local N = Runs.create({ mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[2] }, leaderSrc = 2 })
Runs.markArrived(N, 2)
local nv, nvNet = Runs.spawnVehicle(N, { obj = 1, model = 'sultan', coords = vec4(1, 2, 3, 4), role = 'car' })
ents[nv].health = 0          -- server-created, no client has synced it yet
H.advance(1000)
H.eq(N.entities[nvNet].dead, false, 'a vehicle that reads health 0 before its first sync is not a wreck')
ents[nv].health = 1000
H.advance(1000)
ents[nv].health = 0
H.advance(1000)
H.eq(N.entities[nvNet].dead, true, 'health 0 after a synced value is a wreck')

local lateHandle
local realCreatePed = _G.CreatePed
_G.CreatePed = function(_, model, x, y, z)
    local e = newEnt('ped', model, x, y, z)
    ents[e].exists = false   -- the entity only appears after the spawn wait
    lateHandle = e
    return e
end
local tracked = 0
for _ in pairs(N.entities) do tracked = tracked + 1 end
Config.Limits.maxEntities = tracked + 1
local lateResult = 'pending'
CreateThread(function() lateResult = Runs.spawnPed(N, { obj = 1, model = 'g_m_y_lost_01', coords = vec4(0, 0, 0, 0) }) end)
_G.CreatePed = realCreatePed
H.eq(Runs.canSpawn(N, 1, false), false, 'a spawn still waiting for its entity counts toward the caps')
H.advance(3500)
H.eq(lateResult, nil, 'a spawn whose entity never appeared in time returns nil')
H.ok(Runs.canSpawn(N, 1, false), 'the failed spawn no longer counts toward the caps')
Config.Limits.maxEntities = 80
H.ok(not deleted[lateHandle], 'nothing to delete while the entity does not exist')
ents[lateHandle].exists = true
H.advance(1000)
H.ok(deleted[lateHandle], 'an entity that appears late is still deleted')

-- ── review: objective events past the last objective reach CP.AntiCheat ─────
local checked = {}
local origCheck = CP.AntiCheat.checkEvent
CP.AntiCheat.checkEvent = function(run, src, index, ev)
    checked[#checked + 1] = index
    if index > run.objectiveIndex then return false, 'err.unexpected_event' end
    return true
end
local evBefore = #callsOf('onEvent')
H.fire('crimson-police:server:objective', 2, N.id, 99, { type = 'hit' })
CP.AntiCheat.checkEvent = origCheck
H.eq(checked[#checked], 99, 'an event for an objective past the last one is checked (and flagged) by CP.AntiCheat')
H.eq(#callsOf('onEvent'), evBefore, 'and never reaches a block')

-- ── review: a stale off-duty signal does not remove an officer ─────────────
listeners.lost(2, 'off_duty')      -- recheck[2] is nil: the live check says they are on duty again
H.ok(Runs.isParticipant(N, 2), 'an off-duty signal the live check no longer confirms is ignored')
recheck[2] = 'off_duty'
listeners.lost(2, 'off_duty')
recheck[2] = nil
H.eq(Runs.isParticipant(N, 2), false, 'a confirmed off-duty signal removes the officer')
H.eq(rowsOf(N.id)[1].end_reason, 'off_duty', 'end reason off_duty')

-- ── review: reclassify only turns real_call into real_call_cancelled ────────
MySQL.insert.await("INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason, points_base) VALUES (?, 'tactical', 'test_mission', 'CIT7', 'sast', 'abandoned', 'force_recall', 200)", { 'fr-run' })
H.eq(Runs.reclassify('CIT7', 'fr-run', 'real_call_cancelled'), false, 'a stored force recall never becomes real_call_cancelled')
H.eq(rowsOf('fr-run')[1].end_reason, 'force_recall', 'the force recall row is unchanged')
H.reset()
local R = Runs.create({ mission = mission, locationIndex = 1, missionType = 'tactical', members = { O[1], O[3] }, leaderSrc = 1 })
Runs.markArrived(R, 1)
Runs.removeParticipant(R, 3, 'force_recall')
H.eq(Runs.reclassify('CIT3', R.id, 'real_call_cancelled'), false, 'an in-memory force recall is not reclassified')
H.eq(R.payTier.tier, 'reinforced', 'the pay tier stays after a refused reclassify')
local vR = Runs.view(R, 1)
H.eq(vR.me, 1, 'view.me is the viewer')
H.eq(vR.isBoss, false, 'view.isBoss')
Runs.removeParticipant(R, 1, 'cancelled')

-- ── review: presence flags go through CP.AntiCheat.flag ─────────────────────
H.reset()
local origPresence = CP.AntiCheat.presenceOk
CP.AntiCheat.presenceOk = function(run, p) return p.src ~= 6 end
local P2 = Runs.create({ mission = mission, locationIndex = 1, missionType = 'tactical', members = { O[5], O[6] }, leaderSrc = 5 })
H.eq(Runs.view(P2, 6).startIn, 600, 'view.startIn before the start')
Runs.markArrived(P2, 5)
H.eq(Runs.view(P2, 5).startIn, nil, 'no startIn once in progress')
H.advance(6000)
H.ok(Runs.objectiveComplete(P2, 1), 'presence run: objective 1')
H.ok(Runs.objectiveComplete(P2, 2), 'presence run: objective 2')
CP.AntiCheat.presenceOk = origPresence
local pf = last('ac.flag')
H.eq(pf.reason, 'presence', 'presence flag raised through CP.AntiCheat.flag')
H.eq(pf.src, 6, 'on the absent participant')
H.ok(type(pf.detail) == 'string' and pf.detail:find('40%', 1, true) ~= nil, 'with the presence share in the detail')
local prow = H.sql('SELECT citizenid, flagged, flag_reason FROM cp_mission_runs WHERE run_uuid = ? ORDER BY citizenid', { P2.id })
H.eq(prow[1].flagged, 0, 'the present participant is not flagged')
H.eq(prow[2].flagged, 1, 'the absent participant is flagged')
H.eq(prow[2].flag_reason, 'presence', 'flag reason presence')

-- ── review: every run ticks on its own ──────────────────────────────────────
H.reset()
local slowTicks = 0
CP.Blocks.register('slow_block', {
    tick = function() slowTicks = slowTicks + 1; if slowTicks == 1 then Wait(3500) end end,
})
local slowMission = CP.U.deepcopy(mission)
slowMission.id, slowMission.items, slowMission.scaling = 'slow_mission', {}, {}
slowMission.objectives = { { block = 'slow_block', label = 'Slow', minSeconds = 0 } }
local S1 = Runs.create({ mission = slowMission, locationIndex = 1, missionType = 'patrol', members = { O[2] }, leaderSrc = 2 })
local S2 = Runs.create({ mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[3] }, leaderSrc = 3 })
Runs.markArrived(S1, 2)
Runs.markArrived(S2, 3)
local function ticksOf(run)
    local n = 0
    for _, c in ipairs(calls) do if c.name == 'tick' and c.ctx.run == run then n = n + 1 end end
    return n
end
local s2Before = ticksOf(S2)
local s2Remaining = Runs.remaining(S2)
H.advance(3000)
H.eq(slowTicks, 1, 'a busy tick is not re-entered')
H.ok(ticksOf(S2) - s2Before >= 2, 'another run keeps ticking while one tick waits')
H.ok(Runs.remaining(S2) < s2Remaining - 2, 'and its timer keeps running')
H.advance(2000)
H.ok(slowTicks >= 2, 'the slow run ticks again once its tick finished')
Runs.removeParticipant(S1, 2, 'cancelled')
Runs.removeParticipant(S2, 3, 'cancelled')

-- ── review: a cuffed NPC frees the armed cap (bag state cached briefly) ─────
H.reset()
local Q = Runs.create({ mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[2] }, leaderSrc = 2 })
Runs.markArrived(Q, 2)
local qp = Runs.spawnPed(Q, { obj = 1, model = 'g_m_y_lost_01', coords = vec4(0, 0, 0, 0), armed = true, weapon = 'WEAPON_PISTOL' })
Config.Limits.maxArmedAlive = 1
H.eq(Runs.canSpawn(Q, 1, true), false, 'the armed cap counts the armed NPC')
bags[qp].cp = { run = Q.id, obj = 1, state = 'cuffed', armed = true }
H.advance(600)
H.ok(Runs.canSpawn(Q, 1, true), 'a cuffed NPC no longer counts as armed and alive')
Config.Limits.maxArmedAlive = 25
Runs.removeParticipant(Q, 2, 'cancelled')

-- ── resource stop: entities deleted, nothing written ────────────────────────
H.reset()
local M = Runs.create({ mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[3] }, leaderSrc = 3 })
Runs.markArrived(M, 3)
local mp = Runs.spawnPed(M, { obj = 1, model = 'x', coords = vec4(0, 0, 0, 0) })
TriggerEvent('onResourceStop', 'Crimson-Police')
H.ok(deleted[mp], 'entities deleted on resource stop')
H.eq(#rowsOf(M.id), 0, 'no rows on resource stop')
H.eq(Runs.get(M.id), nil, 'runs dropped')
H.eq(Runs.isOnMission(3), false, 'nobody on a mission after stop')

-- ── the client half (its own process: the harness boots one side per process) ─
do
    local h = io.popen([[lua5.4 -e "package.path=package.path..';tests/?.lua'" tests/fixtures/engine_b/client_spec.lua 2>&1]])
    local out = h:read('a')
    h:close()
    local pass, fail = out:match('RESULT (%d+) (%d+)%s*$')
    if H.ok(pass ~= nil, 'client spec ran') then
        H.passes = H.passes + tonumber(pass)
        H.failures = H.failures + tonumber(fail)
        if tonumber(fail) > 0 then print(out) end
    else
        print(out)
    end
end

return H

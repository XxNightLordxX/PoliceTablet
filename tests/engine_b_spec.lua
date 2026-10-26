-- The run engine (modules/runs/server.lua) against stubs of the other modules, with every SQL statement of the engine
-- run on the MariaDB test database.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

H.sql('DELETE FROM cp_mission_runs')
H.time = tonumber(H.sql('SELECT UNIX_TIMESTAMP(NOW()) AS t')[1].t)   -- align os.time() with NOW()

-- ============================================================================
--                               OneSync NATIVES
-- ============================================================================

local ents, nextHandle, nextNet = {}, 5000, 7000
local netToEnt = {}
local deleted = {}
local frozen = {}
local dropped = {}
local function NewEnt(kind, model, x, y, z)
    nextHandle, nextNet = nextHandle + 1, nextNet + 1
    ents[nextHandle] = {
        kind = kind,
        model = model,
        coords = vec3(x, y, z),
        exists = true,
        health = 200,
        engine = 1000.0,
        body = 1000.0,
        net = nextNet,
        type = kind == 'ped' and 1 or (kind == 'vehicle' and 2 or 3),
    }
    netToEnt[nextNet] = nextHandle
    return nextHandle
end
_G.CreatePed = function(_, model, x, y, z) return NewEnt('ped', model, x, y, z) end
_G.CreateVehicleServerSetter = function(model, _, x, y, z) return NewEnt('vehicle', model, x, y, z) end
_G.CreateObjectNoOffset = function(model, x, y, z) return NewEnt('object', model, x, y, z) end
_G.DoesEntityExist = function(e)
    if ents[e] then return ents[e].exists end
    return (tonumber(e) or 0) > 0
end
_G.DeleteEntity = function(e) deleted[e] = true if ents[e] then ents[e].exists = false end end
_G.NetworkGetNetworkIdFromEntity = function(e) return ents[e] and ents[e].net or 0 end
_G.NetworkGetEntityFromNetworkId = function(n) return netToEnt[n] or 0 end
_G.GiveWeaponToPed = function(e, w, ammo) ents[e].weapon, ents[e].ammo = w, ammo end
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
    return {
        state = setmetatable({
            set = function(_, k, v) b[k] = v end,
        }, { __index = b }),
    }
end

-- ============================================================================
--                                 ox_inventory
-- ============================================================================

-- the real ox_inventory matching (tests/harness.lua H.mockInventory: Search by metadata values, RemoveItem by the exact
-- table); every Search recorded, a player's inventory can be hidden (inv.hidden[src]: Search finds nothing), hooks kept
local inv = H.mockInventory({ radio = { label = 'Radio', stack = false } })
inv.searches = {}
local oxInventory = H.exportsMock.ox_inventory
local RealSearch = oxInventory.Search
oxInventory.Search = function(src, kind, name, meta)
    inv.searches[#inv.searches + 1] = { src = src, kind = kind, name = name, meta = meta }
    if inv.hidden and inv.hidden[src] then return {} end
    return RealSearch(src, kind, name, meta)
end
oxInventory.registerHook = function(event, fn, opts)
    inv.hooks = inv.hooks or {}
    inv.hooks[#inv.hooks + 1] = { event = event, fn = fn, opts = opts }
    return #inv.hooks
end

-- ============================================================================
--                          STUBS OF THE OTHER MODULES
-- ============================================================================

local log = {}
local function Rec(k, v) log[k] = log[k] or {}; log[k][#log[k] + 1] = v end
local function Count(k) return log[k] and #log[k] or 0 end
local function Last(k) return log[k] and log[k][#log[k]] end

-- arena[src]: a foreign crimsonArena value on the player's bag (Crimson-Arena's, or one his own client wrote);
-- bucket[src]: his routing bucket (a real match fighter is in 4210+). inArena is the real CP.Alerts.inArena test.
local arena, bucket, recheck, modifierNext, flagNext = {}, {}, {}, nil, nil
local listeners = {}
CP.Alerts = {
    set = function(src) Rec('alerts.set', src) end,
    clear = function(src) Rec('alerts.clear', src) end,
    forget = function(src) Rec('alerts.forget', src) end,
    inArena = function(src) return arena[src] == true or (bucket[src] or 0) ~= 0 end,
    foreignFlag = function(src) return arena[src] == true end,
    foreignClearedAt = {},
}
-- FiveM server native the harness does not provide.
GetPlayerRoutingBucket = function(src) return bucket[tonumber(src)] or 0 end
CP.Route = {
    begin = function(run, src) Rec('route.begin', src) end,
    stop = function(run, src) Rec('route.stop', src) end,
    status = function(run, src) return { status = 'arrived', secondsLeft = nil, recalcsLeft = 1, distance = 0 } end,
}
CP.Draw = {
    reserve = function(runId, missionId, index) Rec('draw.reserve', { runId, missionId, index }) return true end,
    release = function(runId) Rec('draw.release', runId) return true end,
    recordLast = function(cid, t, m) Rec('draw.recordLast', { cid, t, m }) end,
}
CP.Events = {
    rollModifier = function(run) Rec('events.roll', run.id); local m = modifierNext; modifierNext = nil; return m end,
    typeOfTheDay = function() return nil end,
}
CP.Payouts = {
    baseFor = function(m) return m.isBoss and 2500 or 800 end,
}
CP.Scoring = {
    P = function(m) return m.isBoss and 500 or 200 end,
    isFirstRunSinceDuty = function(src) return src == 1 end,
    compute = function(run, p, result, opts)
        Rec('scoring.compute', { src = p.src, result = result, opts = opts })
        local P = run.pointsBase
        local final = 0
        if result == 'completed' then
            final = P
        elseif result == 'failed' then
            final = math.floor(P * 0.25 * (opts.failedShare or 0))
        end
        return {
            P = P,
            bonuses = { { id = 'fast', label = 'Fast', points = 20 } },
            penalties = { { id = 'hard_ram', label = 'Ram', points = -10 } },
            subtotal = P + 10,
            mTeam = run.payTier and run.payTier.points or 1,
            mCross = 1,
            mStreak = 1,
            capped = false,
            tod = false,
            failedShare = opts.failedShare,
            final = final,
        }
    end,
    onRowCounted = function(cid, row) Rec('scoring.counted', { cid, row }) end,
}
CP.Cash = {
    compute = function(run, p)
        local tier = run.payTier or CP.Scaling.tierByName(run.expectedTier)
        local mMod = run.modifier and 1.25 or 1.0
        local amount = p.result == 'completed' and CP.U.round(run.cashBase * tier.cash * mMod) or 0
        return amount, { B = run.cashBase, mTier = tier.cash, mMod = mMod, amount = amount }
    end,
    pay = function(rowId)
        Rec('cash.pay', rowId)
        local n = MySQL.update.await(
            'UPDATE cp_mission_runs SET cash_status = \'paying\' WHERE id = ? AND cash_status IN (\'none\',\'held\',\'pending\')',
            { rowId })
        if n == 1 then
            MySQL.update.await(
                'UPDATE cp_mission_runs SET cash_status = \'paid\', cash_paid = ROUND(cash_base * cash_multiplier) WHERE id = ?',
                { rowId })
        end
    end,
}
CP.Goals = {
    onRunCompleted = function(cid) Rec('goals', cid) end,
}
CP.Leaderboard = {
    invalidate = function() Rec('lb.invalidate', true) end,
}
CP.Challenge = {
    currentSeason = function() return { id = 3 } end,
}
CP.AntiCheat = {
    checkEvent = function(run, src, index, ev) if ev.type == 'forged' then return false, 'forged' end return true end,
    flag = function(run, src, reason, detail)
        Rec('ac.flag', { reason = reason, detail = detail, src = src })
        if src then run.participants[src].flagged = { reason = reason } else run.flagged = { reason = reason } end
    end,
    presenceOk = function(run, p) return p.src ~= 99 end,
    presenceShare = function(p) return 0.4 end,
}
local unitA = { id = 11, leader = 1, members = { 1, 3 }, locked = true }
CP.Units = {
    unitOf = function(src) if src == 1 then return unitA end return nil end,
    unlock = function(unit) Rec('units.unlock', unit.id) end,
}
CP.Operations = {
    onRunEnded = function(run, state) Rec('ops.ended', { run.operationId, state }) end,
}
CP.Testing = {
    onRunEnded = function(run, state, reason) Rec('testing.ended', { state, reason }) end,
}
CP.Tablet = {
    notify = function(src, kind, key, vars) Rec('notify', { src = src, kind = kind, key = key }) end,
    push = function(src, topic, data) Rec('push', { src = src, topic = topic, data = data }) end,
}
CP.Access = {
    recheck = function(src, job) local r = recheck[src] if r then return false, r end return true end,
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

-- ============================================================================
--                              A RECORDING BLOCK
-- ============================================================================

local calls = {}
local timeoutResult = nil
local function Brec(name, ctx, a, b)
    calls[#calls + 1] = { name = name, index = ctx.index, a = a, b = b, obj = ctx.obj, ctx = ctx }
end
local function CallsOf(name, index)
    local out = {}
    for _, c in ipairs(calls) do if c.name == name and (index == nil or c.index == index) then out[#out + 1] = c end end
    return out
end
CP.Blocks.register('test_block', {
    prepare = function(ctx) Brec('prepare', ctx) end,
    start = function(ctx) Brec('start', ctx) end,
    tick = function(ctx, dt) Brec('tick', ctx, dt) end,
    onEvent = function(ctx, src, ev)
        Brec('onEvent', ctx, src, ev)
        if ev.type == 'reject' then return false, 'nope' end
        return true
    end,
    onEntityDead = function(ctx, netId, killer) Brec('onEntityDead', ctx, netId, killer) end,
    onParticipantLeft = function(ctx, src) Brec('onParticipantLeft', ctx, src) end,
    rescale = function(ctx) Brec('rescale', ctx, ctx.obj.count) end,
    onTimeout = function(ctx) Brec('onTimeout', ctx); return timeoutResult end,
    checklist = function(ctx)
        return {
            { label = 'Things', done = false, value = 1, max = ctx.obj.count or 1 },
            { label = 'Boss', value = 0, max = 1 },
        }
    end,
    restart = function(ctx) Brec('restart', ctx) end,
    stop = function(ctx) Brec('stop', ctx) end,
})

H.load('modules/scaling/server.lua')

local mission = {
    id = 'test_mission',
    label = 'Test Mission',
    description = 'A test.',
    type = 'tactical',
    departments = {},
    minOfficers = 1,
    maxOfficers = 4,
    difficulty = 3,
    timeLimit = 600,
    startTimeout = 600,
    cooldown = 1200,
    locations = {
        {
            label = 'Loc A',
            start = { coords = vec3(100.0, 100.0, 30.0), radius = 50.0 },
            spawns = { vec4(110.0, 110.0, 30.0, 90.0) },
        },
    },
    objectives = {
        { block = 'test_block', label = 'Obj one', minSeconds = 5, count = 4 },
        { block = 'test_block', label = 'Obj two', minSeconds = 0, count = 2, points = 'spawns' },
    },
    scaling = { 'objectives.1.count' },
    items = { { name = 'radio', count = 1 } },
    bonuses = {},
    penalties = {},
    source = 'builtin',
}
local boss = CP.U.deepcopy(mission)
boss.id, boss.label, boss.isBoss, boss.cooldown, boss.items = 'weekly_boss_kingpin', 'Kingpin', true, 600, {}
CP.Missions = {
    get = function(id)
        if id == 'test_mission' then return mission elseif id == 'weekly_boss_kingpin' then return boss end
    end,
    all = function() return { test_mission = mission, weekly_boss_kingpin = boss } end,
}

for src = 1, 6 do H.players[src] = { coords = vec3(0.0, 0.0, 0.0) } end
local O = {
    [1] = {
        src = 1,
        citizenid = 'CIT1',
        name = 'Alice Able',
        department = 'sast',
        departmentShort = 'SAST',
        job = 'sast',
        rank = 'Sergeant',
        callsign = '2L-1',
    },
    [2] = {
        src = 2,
        citizenid = 'CIT2',
        name = 'Bob Baker',
        department = 'sast',
        departmentShort = 'SAST',
        job = 'sast',
        rank = 'Trooper',
    },
    [3] = {
        src = 3,
        citizenid = 'CIT3',
        name = 'Cara Cole',
        department = 'fib',
        departmentShort = 'FIB',
        job = 'fib',
        rank = 'Agent',
        callsign = 'F-3',
    },
    [4] = { src = 4, citizenid = 'ADM4', name = 'Admin Four' },
    [5] = {
        src = 5,
        citizenid = 'CIT5',
        name = 'Eve Evans',
        department = 'sast',
        departmentShort = 'SAST',
        job = 'sast',
        rank = 'Trooper',
    },
    [6] = {
        src = 6,
        citizenid = 'CIT6',
        name = 'Finn Ford',
        department = 'fib',
        departmentShort = 'FIB',
        job = 'fib',
        rank = 'Agent',
    },
}

H.load('modules/runs/server.lua')
local Runs = CP.Runs
H.step(0)   -- the hook registration thread
H.ok(listeners.lost ~= nil and listeners.unload ~= nil and listeners.loaded ~= nil,
    'hooks registered on CP.Access / CP.Qbx')

local function RowsOf(runId)
    return H.sql('SELECT * FROM cp_mission_runs WHERE run_uuid = ? ORDER BY id', { runId })
end
local function EventsTo(name, target)
    local out = {}
    for _, e in ipairs(H.findEvents(name)) do if target == nil or e.target == target then out[#out + 1] = e end end
    return out
end
local function LastEvent(name, target)
    local l = EventsTo(name, target)
    return l[#l]
end

-- ============================================================================
--                              CREATE: validation
-- ============================================================================

H.eq(select(2, Runs.create({ mission = mission, locationIndex = 1, members = {} })), 'err.no_members', 'no members')
H.eq(select(2, Runs.create({ mission = mission, locationIndex = 9, members = { O[1] } })), 'err.invalid_location',
    'bad location')
H.eq(select(2, Runs.create({ mission = {}, locationIndex = 1, members = { O[1] } })), 'err.invalid_mission',
    'bad mission')
arena[1] = true
H.eq(select(2, Runs.create({ mission = mission, locationIndex = 1, members = { O[1] }, leaderSrc = 1 })),
    'err.in_arena', 'in-arena member refused')
arena[1] = nil

-- ============================================================================
--                                  SCENARIO A
-- ============================================================================
-- A two-department unit, Time Crunch, completed.

H.reset()
modifierNext = 'time_crunch'
local A = Runs.create({
    mission = mission,
    locationIndex = 1,
    missionType = 'tactical',
    members = { O[1], O[3] },
    leaderSrc = 1,
})
H.ok(type(A) == 'table', 'run A created')
H.eq(A.state, 'accepted', 'accepted')
H.eq(A.expectedTier, 'reinforced', 'expected tier for 2')
H.eq(A.modifier, 'time_crunch', 'modifier rolled')
H.eq(A.timeLimit, 450, 'Time Crunch cuts 25%')
H.eq(A.cashBase, 800, 'B locked from CP.Payouts.baseFor')
H.eq(A.pointsBase, 200, 'P from CP.Scoring.P')
H.eq(A.host, 1, 'host = leader')
H.eq(A.participants[1].firstRunSinceDuty, true, 'first run since duty captured')
H.eq(#EventsTo('crimson-police:client:start'), 2, 'client:start to each participant')
local startData = LastEvent('crimson-police:client:start', 3).args[2]
H.eq(startData.startRoute, true, 'start route on')
H.eq(A.routeRequired, true, 'the start route rule locked at accept (Config.Route.required, shipped on)')
H.eq(startData.routeRequired, true, 'client:start says the route is required')
H.eq(startData.expectedTier, 'reinforced', 'client:start expected tier')
H.eq(startData.mission.locations, nil, 'mission sent without the location list')
H.eq(#startData.participants, 2, 'participants list')
-- the run seed drives the hidden server rolls (ctx.rng = rng(seed + i)): the clients get another shared seed
H.ok(type(startData.seed) == 'number' and startData.seed > 0, 'client:start has a shared client seed')
H.ok(startData.seed ~= A.seed, 'client:start does not carry the run seed')
H.eq(LastEvent('crimson-police:client:start', 1).args[2].seed, startData.seed, 'the same client seed for everyone')
H.eq(Count('route.begin'), 2, 'CP.Route.begin per participant')
H.eq(Last('draw.reserve')[1], A.id, 'location reserved under the run id')
H.eq(#inv.added, 2, 'mission items given')
H.eq(inv.added[1].meta.cpRun, A.id, 'items tagged with the run')
H.eq(inv.added[1].meta.cpItem, true, 'items tagged cpItem')
H.ok(Runs.isOnMission(1) and Runs.isOnMission(3), 'isOnMission')
H.eq(Runs.getBySrc(3), A, 'getBySrc')
H.eq(select(2, Runs.getBySrc(3)).citizenid, 'CIT3', 'getBySrc participant')
H.eq(select(2, Runs.create({ mission = mission, locationIndex = 1, members = { O[1] }, leaderSrc = 1 })),
    'err.already_on_run', 'one run at a time')
H.eq(select(2, Runs.create({ mission = mission, locationIndex = 1, members = { O[2], O[3] }, leaderSrc = 2 })),
    'err.member_on_run', 'member on a run')
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
H.ok(Count('push') >= 2, 'run pushed at create')

-- ============================================================================
--                            ARRIVAL -> in progress
-- ============================================================================

H.reset()
Runs.markArrived(A, 1)
H.eq(Last('alerts.set'), 1, 'alert flag on arrival')
H.eq(A.state, 'in_progress', 'first arrival -> in progress')
H.eq(A.tier.tier, 'reinforced', 'tier from the active participants')
H.eq(A.payTier.tier, 'reinforced', 'pay tier')
local ip = LastEvent('crimson-police:client:inProgress', 3)
H.ok(ip ~= nil, 'client:inProgress to a participant still driving')
H.eq(ip.args[2].objectives[1].count, 5, 'scaled objectives (4 x 1.25)')
H.eq(ip.args[2].remaining, 450, 'timer in client:inProgress')
local order = {}
for _, c in ipairs(calls) do order[#order + 1] = c.name .. c.index end
H.eq(table.concat(order, ','), 'prepare1,prepare2,start1', 'every block prepare then objective 1 start')
H.eq(CallsOf('prepare', 1)[1].ctx.obj.count, 5, 'ctx.obj is the scaled copy')
H.eq(CallsOf('prepare', 1)[1].ctx.base.count, 4, 'ctx.base is the unscaled objective')
H.eq(CallsOf('prepare', 1)[1].ctx.state, A.objectives[1].state, 'ctx.state is the persistent objective state')
H.near(Runs.remaining(A), 450, 0.01, 'timer running')
Runs.markArrived(A, 3)
H.eq(Count('alerts.set'), 2, 'second arrival flagged')
H.eq(#CallsOf('start', 1), 1, 'no second start')

-- tick
H.advance(1000)
H.ok(#CallsOf('tick', 1) >= 1, 'block tick of the current objective')
H.near(Runs.remaining(A), 449, 0.2, 'timer counts down')
local hudEv = LastEvent('crimson-police:client:hud', 1)
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
local th = LastEvent('crimson-police:client:hud', 1).args[2]
H.eq(th.timer.paused, false, 'timer HUD patch')

-- entities
local ped, pedNet = Runs.spawnPed(A, {
    obj = 1,
    model = 'g_m_y_ballaeast_01',
    coords = vec4(110.0, 110.0, 30.0, 90.0),
    role = 'hostile',
    armed = true,
    weapon = 'WEAPON_PISTOL',
    accuracy = 30,
    armour = 10,
})
H.ok(ped ~= nil and pedNet ~= nil, 'spawnPed')
H.eq(bags[ped].cp.run, A.id, 'cp state bag run')
H.eq(bags[ped].cp.obj, 1, 'cp state bag objective')
H.eq(bags[ped].cp.cfg.accuracy, 18, 'cp cfg accuracy: at most Config.NpcCombat.accuracyMax')
H.eq(ents[ped].armour, 10, 'armour set')
H.ok(ents[ped].weapon ~= nil, 'weapon given')
H.eq(A.entities[pedNet].armed, true, 'tracked as armed')
H.eq(ents[ped].ammo, 60, 'Config.NpcCombat.ammo rounds (not 250)')
-- Config.NpcCombat: an automatic weapon a mission names is never given; the bag names the weapon the ped carries
local smgPed, smgNet = Runs.spawnPed(A, {
    obj = 1,
    model = 'g_m_y_ballaeast_01',
    coords = vec4(111.0, 110.0, 30.0, 90.0),
    role = 'hostile',
    armed = true,
    weapon = 'WEAPON_SMG',
    accuracy = 55,
})
H.eq(ents[smgPed].weapon, joaat('WEAPON_COMBATPISTOL'), 'an SMG is swapped for its Config.NpcCombat.replace weapon')
H.eq(bags[smgPed].cp.cfg.weapon, 'WEAPON_COMBATPISTOL', 'and the bag says so (a new host gives the same weapon)')
H.eq(bags[smgPed].cp.cfg.accuracy, 18, 'a raw accuracy is capped in the bag too')
Runs.deleteEntity(A, smgNet)
Config.Limits.maxArmedAlive = 1
H.ok(not Runs.canSpawn(A, 1, true), 'armed cap')
H.ok(Runs.canSpawn(A, 1, false), 'unarmed still fits')
H.eq(Runs.spawnPed(A, { obj = 1, model = 'x', coords = vec4(0, 0, 0, 0), armed = true }), nil,
    'spawn refused over the cap')
Runs.entityDied(A, pedNet, 1)
H.ok(A.entities[pedNet].dead, 'marked dead')
H.eq(CallsOf('onEntityDead', 1)[1].a, pedNet, 'block onEntityDead')
H.eq(CallsOf('onEntityDead', 1)[1].b, 1, 'killer passed')
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
local veh, vehNet = Runs.spawnVehicle(A,
    { obj = 1, model = 'sultan', coords = vec4(1, 2, 3, 4), role = 'car', plate = 'CP123' })
H.ok(Runs.isMissionPlate(ents[veh].plate) and ents[veh].plate ~= 'CP123',
    'a plate outside the reserved pattern is replaced')
H.eq(A.entities[vehNet].plate, ents[veh].plate, 'the engine remembers the plate')
ents[veh].engine = -4000.0
H.advance(1000)
H.ok(A.entities[vehNet].dead, 'wrecked vehicle detected')
H.eq(A.stats.vehiclesWrecked, 1, 'wrecked stats')
local obj, objNet = Runs.spawnObject(A, { obj = 1, model = 'prop_ld_bomb', coords = vec4(5, 5, 5, 45) })
H.eq(frozen[obj], true, 'object frozen')
H.eq(ents[obj].heading, 45.0, 'object heading')
local ped2, ped2Net = Runs.spawnPed(A,
    { obj = 1, model = 'a_m_m_business_01', coords = vec4(0, 0, 0, 0), role = 'hostage' })
ents[ped2].exists = false
H.advance(2000)
H.eq(A.entities[ped2Net], nil, 'vanished entity forgotten')
H.ok(#CallsOf('onEntityDead', 1) >= 3, 'vanished entity went through the death path')
H.ok(Runs.deleteEntity(A, objNet), 'deleteEntity')

-- telemetry
local car = NewEnt('vehicle', 'police', 0, 0, 0)
ents[car].driver, ents[car].engine, ents[car].body = 100, 800.0, 700.0
H.players[1].vehicle = car
H.fire('crimson-police:server:telemetry', 1, A.id, 'vehicle', { netId = ents[car].net })
H.eq(A.participants[1].vehicle.body, 700.0, 'lowest body health stored')
H.eq(A.participants[1].vehicle.seen, true, 'vehicle seen')
local walker = NewEnt('ped', 'a_m_y_hipster_01', 5, 0, 0)
H.fire('crimson-police:server:telemetry', 1, A.id, 'ped_hit', { netId = ents[walker].net })
H.fire('crimson-police:server:telemetry', 1, A.id, 'ped_hit', { netId = ents[walker].net })
H.eq(A.participants[1].score.pedestrian_hit, 1, 'pedestrian hit counted once')
local far = NewEnt('ped', 'a_m_y_hipster_01', 500, 0, 0)
H.fire('crimson-police:server:telemetry', 1, A.id, 'ped_hit', { netId = ents[far].net })
H.eq(A.participants[1].score.pedestrian_hit, 1, 'a far ped is not a hit')
-- "is this a run entity" comes from the engine's registry, never from a (client-writable) cp bag
local forged = NewEnt('ped', 'a_m_y_hipster_01', 6, 0, 0)
bags[forged] = { cp = { run = A.id, state = 'idle' } }
H.fire('crimson-police:server:telemetry', 1, A.id, 'ped_hit', { netId = ents[forged].net })
H.eq(A.participants[1].score.pedestrian_hit, 2,
    'a pedestrian carrying a client-written cp bag is still a pedestrian hit')
local _, missionPedNet = Runs.spawnPed(A,
    { obj = 1, model = 'a_m_m_business_01', coords = vec4(5, 1, 0, 0), role = 'hostage' })
H.fire('crimson-police:server:telemetry', 1, A.id, 'ped_hit', { netId = missionPedNet })
H.eq(A.participants[1].score.pedestrian_hit, 2, 'a run\'s own ped is not a pedestrian hit')
H.fire('crimson-police:server:telemetry', 1, A.id, 'lights_siren', {})
H.eq(A.participants[1].score.lights_siren, nil, 'lights only on quietPatrol missions')
A.quietPatrol = true
H.fire('crimson-police:server:telemetry', 1, A.id, 'lights_siren', {})
A.quietPatrol = false
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
local before = #CallsOf('onEvent', 1)
H.fire('crimson-police:server:objective', 1, A.id, 1, { type = 'hit', value = 3 })
H.eq(#CallsOf('onEvent', 1), before + 1, 'evidence reaches the block')
H.eq(CallsOf('onEvent', 1)[before + 1].a, 1, 'onEvent src')
H.fire('crimson-police:server:objective', 1, A.id, 2, { type = 'hit' })
H.fire('crimson-police:server:objective', 2, A.id, 1, { type = 'hit' })
H.fire('crimson-police:server:objective', 1, A.id, 1, { type = 'forged' })
H.fire('crimson-police:server:objective', 1, A.id, 1, { type = 'hit', deep = { a = { b = { c = { d = 1 } } } } })
H.fire('crimson-police:server:objective', 1, 'no-such-run', 1, { type = 'hit' })
H.fire('crimson-police:server:objective', 1, A.id, 1, 'not a table')
H.eq(#CallsOf('onEvent', 1), before + 1, 'wrong index, non-participant, forged, deep or malformed evidence rejected')
H.ok(Runs.dispatch(A, 1, nil, { type = 'cuffed', netId = 5 }), 'dispatch a server event')
H.eq(CallsOf('onEvent', 1)[#CallsOf('onEvent', 1)].b.type, 'cuffed', 'dispatch reaches onEvent')
-- K1: the same server-only event sent by a client never reaches the block and flags the sender (a scoped flag
-- stub: later sections count ac.flag and read this run's rows)
do
    local acFlag, got = CP.AntiCheat.flag, {}
    CP.AntiCheat.flag = function(run, src, reason, detail)
        got[#got + 1] = { run = run, src = src, reason = reason, detail = detail }
    end
    local n = #CallsOf('onEvent', 1)
    H.advance(1000)   -- the 12-per-second limit of server:objective
    for _, t in ipairs({ 'cuffed', 'decide', 'action', 'removed', 'handed_over', 'impounded', 'shot', 'damaged' }) do
        H.fire('crimson-police:server:objective', 1, A.id, 1, { type = t, netId = 5, time = n + #got })
    end
    local k1Flags = #got
    -- V4: CP.Opponents' facts about real suspects are server-only too (12 a second: two batches)
    local OPP = {
        'opp_contact',
        'opp_cuffed',
        'opp_released',
        'opp_detained',
        'opp_booked',
        'opp_down',
        'opp_up',
        'opp_lost',
        'opp_left',
        'opp_void',
        'opp_in_place',
        'opp_left_spot',
        'opp_out_of_bounds',
        'opp_cuff_attempt',
    }
    for i, t in ipairs(OPP) do
        if i == 1 or i == 8 then H.advance(1000) end
        H.fire('crimson-police:server:objective', 1, A.id, 1, { type = t, cid = 'X1', share = 1, time = n + #got })
    end
    CP.AntiCheat.flag = acFlag
    H.eq(#CallsOf('onEvent', 1), n, 'k1: a client cuffed, decide, removed... never reaches onEvent')
    H.eq(k1Flags, 8, 'k1: each one flags')
    H.ok(got[1] and got[1].run == A, 'k1: the run')
    H.eq(got[1] and got[1].src, 1, 'k1: the sender')
    H.eq(got[1] and got[1].reason, 'unexpected_event', 'k1: unexpected_event')
    H.eq(got[1] and got[1].detail, 'client sent cuffed', 'k1: naming the type')
    H.eq(#CallsOf('onEvent', 1), n, 'v4: a client opp_detained, opp_booked... never reaches onEvent')
    H.eq(#got, 8 + #OPP, 'v4: each one flags')
    local detained = nil
    for _, g in ipairs(got) do if g.detail == 'client sent opp_detained' then detained = g end end
    H.ok(detained ~= nil and detained.reason == 'unexpected_event' and detained.src == 1,
        'v4: opp_detained from a client: unexpected_event on the sender')
    H.advance(1000)
    H.fire('crimson-police:server:objective', 1, A.id, 1, { type = 'hit', value = 4 })
    H.eq(#CallsOf('onEvent', 1), n + 1, 'k1: client evidence still reaches the block')
end
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
H.eq(v.expected.cash, 1104, 'expected cash = B x tier x twist ($800 x 1.15 x 1.20 Time Crunch)')
H.eq(v.expected.points, 290, 'expected points ((200 + 20% Time Crunch) x tier x cross-department)')
do
    -- a true half-dollar rounds up, as CP.Cash pays: $200 x 1.15 x 1.25 = $287.50 (287.4999... in floating point)
    local realBase, realMods = A.cashBase, A.modifiers
    A.cashBase, A.modifiers = 200, { 'radio_silence' }
    H.ok(200 * 1.15 * 1.25 < 287.5, 'precondition: the float product is below the half')
    H.eq(Runs.view(A, 1).expected.cash, 288, 'expected cash: a true half-dollar rounds up ($288, not $287)')
    A.cashBase, A.modifiers = realBase, realMods
end
H.eq(v.radioSilence, false, 'radio silence flag')
H.eq(v.silenceMode, nil, 'no Radio Silence: no silence mode')
do
    -- PLAN M8: the Active Mission notice says what Config.Markers.radioSilence hides
    -- Radio Silence stacked on the rolled Time Crunch: the flag reads the run's twist list (PLAN M8b)
    local realMods, realMode = A.modifiers, Config.Markers.radioSilence
    A.modifiers = { 'time_crunch', 'radio_silence' }
    H.eq(Runs.view(A, 1).radioSilence, true, 'Radio Silence from the twist list')
    H.eq(Runs.view(A, 1).silenceMode, 'area', 'Radio Silence: the shipped mode (area)')
    Config.Markers.radioSilence = 'full'
    H.eq(Runs.view(A, 1).silenceMode, 'full', 'Radio Silence: the owner\'s mode')
    Config.Markers.radioSilence = 'bogus'
    H.eq(Runs.view(A, 1).silenceMode, 'area', 'Radio Silence: an unknown mode counts as area')
    A.modifiers, Config.Markers.radioSilence = realMods, realMode
end
do
    -- PLAN M10: the Objective GPS button follows Config.Markers.objectiveGps (and enabled)
    H.eq(v.objectiveGps, true, 'm10: Objective GPS on as shipped')
    Config.Markers.objectiveGps = false
    H.eq(Runs.view(A, 1).objectiveGps, false, 'm10: objectiveGps = false: no button')
    Config.Markers.objectiveGps, Config.Markers.enabled = true, false
    H.eq(Runs.view(A, 1).objectiveGps, false, 'm10: Config.Markers.enabled = false: no button')
    Config.Markers.enabled = true
end
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
H.eq(#CallsOf('stop', 1), 1, 'objective 1 stopped')
H.eq(#CallsOf('start', 2), 1, 'objective 2 started')
H.eq(Count('ac.flag'), 0, 'no too_fast flag')
H.eq(Runs.objectiveComplete(A, 1), false, 'objective accepted once')

-- a partner leaves for a real call: tier drops, pay tier stays
H.reset()
local rowC = Runs.removeParticipant(A, 3, 'real_call')
H.ok(rowC ~= nil, 'row id for the leaver')
local r3 = RowsOf(A.id)[1]
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
local tc = LastEvent('crimson-police:client:tierChanged', 1)
H.eq(tc.args[2], 'standard', 'client:tierChanged tier')
H.eq(tc.args[3], 'reinforced', 'client:tierChanged pay tier')
H.eq(CallsOf('rescale', 2)[1].a, 2, 'rescale with the re-scaled ctx.obj')
H.eq(#CallsOf('rescale', 1), 0, 'done objectives are not rescaled')
H.eq(CallsOf('onParticipantLeft', 2)[1].a, 3, 'onParticipantLeft for the current objective')
H.ok(log['alerts.clear'] and log['alerts.clear'][1] == 3, 'flag cleared')
H.eq(Last('route.stop'), 3, 'route stopped')
H.eq(inv.removed[#inv.removed].src, 3, 'items removed by slot')
local ended3 = LastEvent('crimson-police:client:runEnded', 3)
H.eq(ended3.args[2], 'abandoned', 'client:runEnded result')
H.eq(ended3.args[4].endReason, 'real_call', 'RunResult end reason')
H.eq(Runs.isOnMission(3), false, 'leaver is off the mission')
H.eq(Runs.cooldowns('CIT3').types.tactical, nil, 'real_call: no type cooldown')
H.eq(Runs.cooldowns('CIT3').missions.test_mission, nil, 'real_call: no mission cooldown')
H.eq(LastEvent('crimson-police:client:participants', 1).args[2][2].status, 'left', 'participants update')
H.ok(Runs.isOnMission(1), 'run continues for the rest')

-- the real call is un-marked within the window
H.ok(Runs.reclassify('CIT3', A.id, 'real_call_cancelled'), 'reclassify')
local r3b = RowsOf(A.id)[1]
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
local rows = RowsOf(A.id)
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
H.eq(H.bit(r1.flagged), 0, 'not flagged')
H.eq(r1.location_label, 'Loc A', 'location label')
H.ok(r1.duration_s >= 0, 'duration')
local bd = CP.U.jsonField(r1.breakdown)
H.eq(bd.cash.status, 'paid', 'breakdown carries the final cash status')
H.eq(bd.points.final, 200, 'breakdown points')
H.eq(bd.participants, 1, 'breakdown participants')
H.eq(Last('cash.pay'), r1.id, 'CP.Cash.pay for the completed row')
H.eq(Last('scoring.counted')[1], 'CIT1', 'onRowCounted')
H.eq(Last('scoring.counted')[2].id, r1.id, 'onRowCounted row')
H.eq(Last('goals'), 'CIT1', 'goals hook')
H.eq(Last('draw.recordLast')[3], 'test_mission', 'recordLast')
H.eq(Last('units.unlock'), 11, 'unit unlocked')
H.ok(Count('lb.invalidate') >= 1, 'leaderboard invalidated')
H.eq(Last('draw.release'), A.id, 'reservation released')
H.eq(next(A.entities), nil, 'every entity deleted')
H.ok(#inv.removed > invBefore, 'items removed at the end')
local ended1 = LastEvent('crimson-police:client:runEnded', 1)
H.eq(ended1.args[2], 'completed', 'client:runEnded completed')
H.eq(ended1.args[4].cash.amount, 1000, 'RunResult cash')
H.eq(ended1.args[4].cash.status, 'paid', 'RunResult cash status')
H.eq(ended1.args[4].payTier, 'standard', 'RunResult pay tier')
H.eq(Last('push').data, nil, 'run push cleared')
H.ok(Runs.onCooldown('CIT1', 'tactical', 'test_mission'), 'mission cooldown after completing')
H.eq(Runs.cooldowns('CIT1').types.tactical, nil, 'no type cooldown after completing')
H.eq(#CallsOf('stop', 2), 1, 'last objective stopped once')

-- completions in the last hour (manual awards and goals excluded)
H.eq(Runs.completionsLastHour('CIT1'), 1, 'completions last hour')
MySQL.insert.await(
    'INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason, points_base) VALUES (?, \'manual_award\', \'manual_award\', \'CIT1\', \'sast\', \'completed\', \'completed\', 0)',
    { 'manual-1' })
H.time = H.time + 11
H.eq(Runs.completionsLastHour('CIT1'), 1, 'manual awards do not count')

-- cooldowns rebuilt from rows after a restart
MySQL.insert.await(
    'INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason, points_base) VALUES (?, \'tactical\', \'test_mission\', \'CIT9\', \'sast\', \'abandoned\', \'quit\', 200)',
    { 'old-1' })
MySQL.insert.await(
    'INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason, points_base) VALUES (?, \'tactical\', \'weekly_boss_kingpin\', \'CIT8\', \'sast\', \'abandoned\', \'quit\', 500)',
    { 'old-2' })
local cd9 = Runs.cooldowns('CIT9')
H.ok((cd9.types.tactical or 0) > os.time(), 'type cooldown rebuilt')
H.ok((cd9.missions.test_mission or 0) > os.time(), 'mission cooldown rebuilt')
local on, untilTs = Runs.onCooldown('CIT9', 'tactical', 'other')
H.ok(on and untilTs == cd9.types.tactical, 'onCooldown by type')
local cd8 = Runs.cooldowns('CIT8')
H.eq(cd8.types.tactical, nil, 'a boss abandon starts no type cooldown')
H.ok((cd8.missions.weekly_boss_kingpin or 0) > os.time(), 'boss mission cooldown rebuilt')

-- reclassify of a run that is no longer in memory
MySQL.insert.await(
    'INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason, points_base, breakdown) VALUES (?, \'tactical\', \'test_mission\', \'CIT7\', \'sast\', \'abandoned\', \'real_call\', 200, ?)',
    { 'ext-run', '{"endReason":"real_call"}' })
H.ok(Runs.reclassify('CIT7', 'ext-run', 'real_call_cancelled'), 'reclassify from the row')
H.eq(RowsOf('ext-run')[1].end_reason, 'real_call_cancelled', 'external row updated')
H.ok((Runs.cooldowns('CIT7').types.tactical or 0) > os.time(), 'cooldown for the external row')
H.eq(Runs.reclassify('CIT7', 'no-row', 'real_call_cancelled'), false, 'no row -> false')

-- ============================================================================
--                                  SCENARIO B
-- ============================================================================
-- Solo, completed too fast -> flagged, cash held.

H.reset()
local B = Runs.create(
    { mission = mission, locationIndex = 1, missionType = 'tactical', members = { O[2] }, leaderSrc = 2 })
Runs.markArrived(B, 2)
H.eq(B.tier.tier, 'standard', 'solo tier')
H.advance(1000)
H.eq(Runs.objectiveComplete(B, 1), false, 'early completion refused')
H.eq(Runs.objectiveComplete(B, 1), false, 'still refused')
H.eq(Count('ac.flag'), 1, 'too_fast flagged once')
H.eq(Last('ac.flag').reason, 'too_fast', 'flag reason')
H.advance(5000)
local paysBefore, countedBefore = Count('cash.pay'), Count('scoring.counted')
H.ok(Runs.objectiveComplete(B, 1), 'completes after minSeconds')
H.ok(Runs.objectiveComplete(B, 2), 'last objective')
local rb = RowsOf(B.id)[1]
H.eq(H.bit(rb.flagged), 1, 'flagged row')
H.eq(rb.flag_reason, 'too_fast', 'flag reason stored')
H.eq(rb.cash_status, 'held', 'flagged rows hold their cash')
H.eq(Count('cash.pay'), paysBefore, 'no payment for a flagged row')
H.eq(Count('scoring.counted'), countedBefore, 'flagged rows do not count yet')
H.eq(LastEvent('crimson-police:client:runEnded', 2).args[4].flagged.reason, 'too_fast', 'RunResult flagged')

-- ============================================================================
--                                  SCENARIO C
-- ============================================================================
-- Time limit, then a block that completes on timeout.

H.reset()
local C = Runs.create(
    { mission = mission, locationIndex = 1, missionType = 'tactical', members = { O[1] }, leaderSrc = 1 })
Runs.markArrived(C, 1)
Runs.adjustTimer(C, -598)
H.advance(3000)
H.eq(C.state, 'ended', 'time limit ends the run')
H.eq(#CallsOf('onTimeout', 1), 1, 'block onTimeout asked')
local rc = RowsOf(C.id)[1]
H.eq(rc.state, 'failed', 'time_limit is failed')
H.eq(rc.end_reason, 'time_limit', 'end reason time_limit')
H.eq(Last('scoring.compute').opts.failedShare, 0, 'failed share of objectives done')
H.eq(Runs.cooldowns('CIT1').types.tactical, nil, 'time_limit: no type cooldown')

H.reset()
timeoutResult = 'completed'
local C2 = Runs.create(
    { mission = mission, locationIndex = 1, missionType = 'tactical', members = { O[1] }, leaderSrc = 1 })
Runs.markArrived(C2, 1)
Runs.adjustTimer(C2, -599)
H.advance(2000)
timeoutResult = nil
H.eq(RowsOf(C2.id)[1].state, 'completed', 'onTimeout completed -> completed')

-- ============================================================================
--             SCENARIO D: an operation run; disconnect and unload
-- ============================================================================

H.reset()
local rollsD = Count('events.roll')
local D = Runs.create({
    mission = mission,
    locationIndex = 1,
    missionType = 'tactical',
    members = { O[1], O[2] },
    leaderSrc = 1,
    operationId = 7,
})
H.eq(D.modifier, nil, 'no modifier on operations')
H.eq(Count('events.roll'), rollsD, 'rollModifier not asked for operations')
Config.Limits.maxConcurrentRuns = 1
H.ok(Runs.capsOk('tactical'), 'operations do not count toward the caps')
Config.Limits.maxConcurrentRuns = 12
Runs.markArrived(D, 1)
dropped[2] = true
H.fire('playerDropped', 2)
dropped[2] = nil
local rd = RowsOf(D.id)[1]
H.eq(rd.end_reason, 'disconnected', 'disconnected')
H.eq(rd.state, 'failed', 'disconnect is failed')
H.eq(rd.operation_id, 7, 'operation id stored')
H.eq(rd.department, 'sast', 'department fallback for a dropped player')
H.ok((Runs.cooldowns('CIT2').types.tactical or 0) > os.time(), 'disconnect: type cooldown')
H.eq(D.payTier.tier, 'standard', 'disconnect drops the pay tier')
listeners.unload(1)
H.eq(D.state, 'ended', 'last participant gone -> run ended')
H.eq(D.endState, 'failed', 'a run whose last participant failed ends failed')
H.eq(RowsOf(D.id)[2].end_reason, 'disconnected', 'unload -> disconnected')
H.eq(Last('ops.ended')[1], 7, 'CP.Operations.onRunEnded')
H.eq(Last('ops.ended')[2], 'failed', 'operation told the run failed')

-- ============================================================================
--                    SCENARIO E: a test run writes nothing
-- ============================================================================

H.reset()
local rollsBefore = Count('events.roll')
local requiredBefore = Config.Route.required
Config.Route.required = false   -- a test run follows its own Start route switch, never Config.Route.required
local E = Runs.create({
    mission = mission,
    locationIndex = 1,
    missionType = 'tactical',
    members = { O[4], O[6] },
    leaderSrc = 4,
    test = { adminSrc = 4, useStartRoute = false, forcedTier = 'heavy' },
})
H.eq(E.expectedTier, 'heavy', 'forced tier expected')
H.eq(Count('events.roll'), rollsBefore, 'no modifier roll on tests')
H.eq(LastEvent('crimson-police:client:start', 4).args[2].startRoute, false, 'start route off')
H.eq(E.routeRequired, true, 'a test run keeps the route rules whatever Config.Route.required says')
Config.Route.required = requiredBefore
Runs.markArrived(E, 4)
H.eq(E.tier.tier, 'heavy', 'forced tier used')
H.eq(E.objectives[1].obj.count, 6, 'scaled at the forced tier')
recheck[4] = 'job_change'
Runs._jobRecheck()
recheck[4] = nil
H.ok(Runs.isParticipant(E, 4), 'non-officer testers are not rechecked')
H.ok(Runs.testSkip(E), 'testSkip')
H.eq(E.objectiveIndex, 2, 'skip starts the next objective')
H.eq(Count('ac.flag'), 1, 'skip is not flagged')
H.ok(Runs.testRestart(E), 'testRestart')
H.eq(#CallsOf('restart', 2), 1, 'block restart')
local anc = Runs.anchor(E)
H.eq(anc.x, 110.0, 'anchor at the current objective point')
H.eq(Runs.cooldowns('CIT6').types.tactical, nil, 'no cooldown history for CIT6')
Runs.removeParticipant(E, 6, 'quit')
H.eq(Runs.cooldowns('CIT6').types.tactical, nil, 'test runs start no type cooldown')
H.eq(Runs.cooldowns('CIT6').missions.test_mission, nil, 'test runs start no mission cooldown')
Runs.endRun(E, 'completed', 'completed')
H.eq(#RowsOf(E.id), 0, 'test runs write no rows')
local re = LastEvent('crimson-police:client:runEnded', 4).args[4]
H.eq(re.test, true, 'RunResult test flag')
H.eq(re.points.final, 200, 'would-have points shown')
H.eq(re.cash.amount, 1040, 'would-have cash shown (800 x 1.30)')
H.eq(re.cash.status, 'none', 'nothing paid')
H.eq(Last('testing.ended')[1], 'completed', 'CP.Testing.onRunEnded')

-- ============================================================================
--                                  SCENARIO F
-- ============================================================================
-- Weekly Boss, host succession, downed, abandon action.

H.reset()
local F = Runs.create({
    mission = boss,
    locationIndex = 1,
    missionType = 'weekly_boss',
    members = { O[5], O[6] },
    leaderSrc = 5,
    isBoss = true,
})
H.eq(F.missionType, 'tactical', 'boss runs are tactical')
H.eq(F.cashBase, 2500, 'boss payout')
H.eq(F.host, 5, 'host = leader')
Runs.markArrived(F, 6)
dropped[5] = true
H.advance(1000)
dropped[5] = nil
H.eq(F.host, 6, 'next participant takes over the AI')
H.eq(LastEvent('crimson-police:client:hostChanged', 6).args[2], 6, 'client:hostChanged')
local clearsBefore = Count('alerts.clear')
Runs.removeParticipant(F, 5, 'downed', { keepFlag = true })
H.eq(Count('alerts.clear'), clearsBefore, 'downed keeps the flag')
H.eq(F.stats.downs, 1, 'downs counted')
H.eq(F.payTier.tier, 'reinforced', 'downed keeps the pay tier')
H.eq(RowsOf(F.id)[1].state, 'failed', 'downed is failed')
H.eq(Runs.cooldowns('CIT5').missions.weekly_boss_kingpin ~= nil, true, 'boss mission cooldown')
H.eq(Runs.cooldowns('CIT5').types.tactical, nil, 'boss downed: no type cooldown')
H.fire('crimson-police:server:abandon', 6, F.id, 'req-1')
local ar = LastEvent('crimson-police:client:actionResult', 6)
H.eq(ar.args[1], 'req-1', 'abandon replies')
H.eq(ar.args[2], true, 'abandon ok')
H.eq(F.state, 'ended', 'abandon of the last participant ends the run')
local rf = RowsOf(F.id)[2]
H.eq(rf.end_reason, 'quit', 'abandon = quit')
H.eq(rf.mission_type, 'tactical', 'boss row stored as tactical')
H.eq(Runs.cooldowns('CIT6').types.tactical, nil, 'boss abandon: no type cooldown')
H.ok((Runs.cooldowns('CIT6').missions.weekly_boss_kingpin or 0) > os.time(), 'boss abandon: mission cooldown')
H.fire('crimson-police:server:abandon', 6, F.id, 'req-2')
H.eq(LastEvent('crimson-police:client:actionResult', 6).args[3], 'err.invalid_run', 'abandon of an ended run')

-- ============================================================================
--            SCENARIO G: start timeout, arena, job recheck, onLost
-- ============================================================================

H.reset()
local G = Runs.create(
    { mission = mission, locationIndex = 1, missionType = 'tactical', members = { O[1] }, leaderSrc = 1 })
G.participants[1].deadline = os.time() - 1
H.advance(1000)
H.eq(RowsOf(G.id)[1].end_reason, 'start_timeout', 'start timeout')
H.ok((Runs.cooldowns('CIT1').types.tactical or 0) > os.time(), 'start timeout: type cooldown')

-- R6: a late partner who follows the action (CP.Route) gets Config.Route.followActionSeconds from then on, never less
-- time than he had; the start timeout removes him only at that deadline
H.reset()
local G1 = Runs.create(
    { mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[1] }, leaderSrc = 1 })
G1.participants[1].deadline = os.time() + 500
H.eq(Runs.extendStart(G1, 1, 300), os.time() + 500, 'extendStart: never less time than he had')
G1.participants[1].deadline = os.time() + 2
H.eq(Runs.extendStart(G1, 1, 300), os.time() + 300, 'extendStart: 300 s from now')
H.eq(Runs.extendStart(G1, 1, 0), os.time() + 300, 'extendStart: 0 s changes nothing')
H.advance(5000)
H.eq(G1.participants[1].status, 'active', 'extendStart: past the deadline he had, still on the run')
G1.participants[1].deadline = os.time() - 1
H.advance(1000)
H.eq(RowsOf(G1.id)[1] and RowsOf(G1.id)[1].end_reason, 'start_timeout', 'extendStart: removed at his new deadline')
H.eq(Runs.extendStart(G1, 1, 300), nil, 'extendStart: nothing for a run that ended')

H.reset()
local G2 = Runs.create(
    { mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[3] }, leaderSrc = 3 })
arena[3] = true
H.advance(1000)
arena[3] = nil
H.eq(RowsOf(G2.id)[1].end_reason, 'quit', 'arena -> quit')
H.eq(Last('notify').key, 'run.left_for_arena', 'arena notification')

H.reset()
local G3 = Runs.create(
    { mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[3] }, leaderSrc = 3 })
recheck[3] = 'off_duty'
Runs._jobRecheck()
recheck[3] = nil
H.eq(RowsOf(G3.id)[1].end_reason, 'off_duty', 'job recheck -> off_duty')

H.reset()
local G4 = Runs.create(
    { mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[3] }, leaderSrc = 3 })
listeners.lost(3, 'suspended')
H.eq(RowsOf(G4.id)[1].end_reason, 'suspended', 'onLost -> suspended')

-- ============================================================================
--                                 SCENARIO G5
-- ============================================================================
-- A custom mission hands out items only when an admin published it (Config.Builder.supervisorItems).

do
    local function Custom(id, itemsBy)
        local m = CP.U.deepcopy(mission)
        m.id, m.source, m.version, m.itemsBy = id, 'custom', 2, itemsBy
        return m
    end
    local function Given(m)
        H.reset()
        local before = #inv.added
        local r = Runs.create(
            { mission = m, locationIndex = 1, missionType = 'patrol', members = { O[3] }, leaderSrc = 3 })
        local n = #inv.added - before
        if r then listeners.lost(3, 'suspended') end
        return n, r
    end
    local function Skipped(id)
        local n = 0
        for _, l in ipairs(CP.Problems.list({ tag = 'runs', limit = 200 })) do
            if l.text:find('custom mission ' .. id .. ' ', 1, true)
                and l.text:find('items skipped: saved by a supervisor', 1, true) then
                n = n + 1
            end
        end
        return n
    end
    Config.Builder = Config.Builder or {}
    local shipped = Config.Builder.supervisorItems
    Config.Builder.supervisorItems = false
    H.eq((Given(Custom('custom_by_admin', 'admin'))), 1, 'a custom mission an admin published hands out its items')
    H.eq((Given(Custom('custom_by_console', 'console'))), 1, 'one published from the console (or edited in code) too')
    local nSup, rSup = Given(Custom('custom_by_sup', 'supervisor'))
    H.ok(rSup ~= nil, 'the run of a supervisor\'s mission still starts')
    H.eq(nSup, 0, 'a custom mission a supervisor published hands out no item')
    H.eq(#rSup.participants[3].items, 0, 'and nothing is waiting to be taken back')
    H.eq(Skipped('custom_by_sup'), 1, 'System -> Problems: "items skipped: saved by a supervisor"')
    H.eq((Given(Custom('custom_by_sup', 'supervisor'))), 0, 'the next run of it hands out none either')
    H.eq(Skipped('custom_by_sup'), 1, 'one line per mission, not per run')
    H.eq((Given(Custom('custom_old', nil))), 0, 'an old mission with no record of who published it hands out none')
    H.eq(Skipped('custom_old'), 1, 'and is reported once')
    H.eq((Given(CP.U.deepcopy(mission))), 1, 'a built-in mission is not affected')
    Config.Builder.supervisorItems = true
    H.eq((Given(Custom('custom_by_sup2', 'supervisor'))), 1,
        'supervisorItems = true: a supervisor\'s items are handed out')
    H.eq(Skipped('custom_by_sup2'), 0, 'and nothing is reported')
    Config.Builder.supervisorItems = shipped
end

-- ============================================================================
--                             SCENARIO K: failRun
-- ============================================================================

H.reset()
local K = Runs.create(
    { mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[3] }, leaderSrc = 3 })
Runs.markArrived(K, 3)
local ctx = CallsOf('start', 1)[#CallsOf('start', 1)].ctx
H.eq(ctx.run, K, 'ctx.run')
H.eq(ctx.host(), 3, 'ctx.host')
H.ok(ctx.isHost(3), 'ctx.isHost')
H.eq(ctx.participants()[1], 3, 'ctx.participants')
H.ok(ctx.coords(3) ~= nil, 'ctx.coords')
local acc, arm = ctx.combat(25, 0)
H.eq(acc, 18, 'ctx.combat accuracy (standard): 25 x 0.7 = 17.5 -> 18, at most 18')
ctx.hud({ detail = 'Wave 1 of 3', value = 2, max = 7, message = { text = 'Hi', kind = 'info' } })
H.eq(K.objectives[1].hud.detail, 'Wave 1 of 3', 'ctx.hud objective detail')
H.eq(Runs.view(K, 3).objectives[1].value, 2, 'ctx.hud value wins over the checklist')
H.eq(LastEvent('crimson-police:client:hud', 3).args[2].message.text, 'Hi', 'ctx.hud message is top level')
ctx.fail('run.fail_killed_unarmed')
H.eq(K.state, 'ended', 'fail ends the run')
local rk = RowsOf(K.id)[1]
H.eq(rk.end_reason, 'mission_failed', 'mission_failed')
H.eq(LastEvent('crimson-police:client:runEnded', 3).args[4].failReason, 'run.fail_killed_unarmed',
    'fail reason in the result')

-- ============================================================================
--                         ORPHANED ITEMS AND THE SWEEP
-- ============================================================================

H.reset()
local L = Runs.create(
    { mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[3] }, leaderSrc = 3 })
inv.hidden = { [3] = true }
Runs.removeParticipant(L, 3, 'quit')
inv.hidden = nil
-- the player's own radio: another script's flag { encrypted = true } (Search matches it: its value is true too)
oxInventory.AddItem(3, 'radio', 1, { encrypted = true })
local function OwnRadios(src)
    local n = 0
    for _, s in ipairs(inv.slots[src] or {}) do
        if s.count > 0 and s.metadata and s.metadata.encrypted == true then n = n + s.count end
    end
    return n
end
local removedBefore = #inv.removed
listeners.loaded(3)
H.advance(5000)
H.ok(#inv.removed > removedBefore, 'orphaned items swept when the player loads')
H.eq(inv.searches[#inv.searches].meta.cpItem, true, 'sweep searches cpItem metadata')
H.eq(OwnRadios(3), 1, 'the sweep takes only items whose own cpItem is true: the player\'s own radio stays')

-- A leaver whose old run is still live loses its items on the sweep, and the orphan is kept until then.
H.reset()
local L2 = Runs.create({
    mission = mission,
    locationIndex = 1,
    missionType = 'patrol',
    members = { O[2], O[3] },
    leaderSrc = 2,
})
inv.hidden = { [3] = true }
Runs.removeParticipant(L2, 3, 'disconnected')
inv.hidden = nil
H.eq(L2.state ~= 'ended', true, 'partner carries on')
local function HeldBy(src, runId)
    local n = 0
    for _, s in ipairs(inv.slots[src] or {}) do
        if s.count > 0 and s.metadata and s.metadata.cpRun == runId then n = n + s.count end
    end
    return n
end
H.ok(HeldBy(3, L2.id) > 0, 'leaver still holds the item before the sweep')
listeners.loaded(3)
H.advance(5000)
H.eq(HeldBy(3, L2.id), 0, 'sweep removes items of a live run the player has left')
H.ok(HeldBy(2, L2.id) > 0, 'active partner keeps the item')
Runs.endRun(L2, 'failed', 'quit')

-- CRIMSON_ARENA rule 4 against a flag the player wrote himself (SKILL_CHECK V5): a client can set its own bag with
-- LocalPlayer.state:set('crimsonArena', { active = true }, true). He still leaves the run (rule 1), but only a player
-- in Crimson-Arena's bucket (inventory stashed) keeps his mission items; in bucket 0 the run takes them back.
do
    local realLog = CP.log
    local orphaned = {}
    CP.log = function(tag, m, ...)
        local line = tostring(m):format(...)
        local cid = line:match('not found on ([^;]+); kept for a later sweep')
        if cid then orphaned[cid] = (orphaned[cid] or 0) + 1 end
        return realLog(tag, m, ...)
    end
    local function SearchedRun(src, runId, from)
        for i = from + 1, #inv.searches do
            local q = inv.searches[i]
            if q.src == src and type(q.meta) == 'table' and q.meta.cpRun == runId then return true end
        end
        return false
    end
    local function SweepSearches(src, from)
        local n = 0
        for i = from + 1, #inv.searches do
            local q = inv.searches[i]
            if q.src == src and type(q.meta) == 'table' and q.meta.cpItem == true then n = n + 1 end
        end
        return n
    end

    -- (a) the flag in bucket 0: items taken back, no orphan
    H.reset()
    local VA = Runs.create(
        { mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[3] }, leaderSrc = 3 })
    H.ok(HeldBy(3, VA.id) > 0, 'V5: the officer holds the mission item')
    local from = #inv.searches
    arena[3] = true
    H.advance(1000)
    H.eq(VA.participants[3].endReason, 'quit', 'V5 bucket 0: the flag still takes him out of the run')
    H.ok(SearchedRun(3, VA.id, from), 'V5 bucket 0: RemoveSlots searches his inventory for the run\'s items')
    H.eq(HeldBy(3, VA.id), 0, 'V5 bucket 0: the run takes its item back')
    H.eq(orphaned.CIT3, nil, 'V5 bucket 0: no orphan is recorded for him')
    arena[3] = nil

    -- (b) a real match (bucket 4210): items kept, an orphan recorded
    H.reset()
    local VB = Runs.create(
        { mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[3] }, leaderSrc = 3 })
    from = #inv.searches
    arena[3], bucket[3] = true, 4210
    H.advance(1000)
    H.eq(VB.participants[3].endReason, 'quit', 'V5 bucket 4210: he leaves the run')
    H.eq(SearchedRun(3, VB.id, from), false, 'V5 bucket 4210: his (stashed) inventory is not searched')
    H.ok(HeldBy(3, VB.id) > 0, 'V5 bucket 4210: the item is kept')
    H.eq(orphaned.CIT3, 1, 'V5 bucket 4210: an orphan is recorded for a later sweep')

    -- (c) the sweep: none while he is in the match; flagged in bucket 0 it sweeps
    from = #inv.searches
    listeners.loaded(3)
    H.advance(5000)
    H.eq(SweepSearches(3, from), 0, 'V5 sweep in bucket 4210: SweepPlayer returns before any search')
    H.ok(HeldBy(3, VB.id) > 0, 'V5 sweep in bucket 4210: the item stays')
    bucket[3] = nil
    from = #inv.searches
    listeners.loaded(3)
    H.advance(5000)
    H.ok(SweepSearches(3, from) > 0, 'V5 sweep with the flag in bucket 0: SweepPlayer searches his cpItem slots')
    H.eq(HeldBy(3, VB.id), 0, 'V5 sweep with the flag in bucket 0: the orphaned item is taken back')
    arena[3] = nil

    -- (d) an Arena exit in progress (SKILL_CHECK K3b): back in bucket 0 while the flag is still set and the inventory
    -- is still in Crimson-Arena's stash. The sweep then finds nothing but keeps the orphan record, so the sweep 10 s
    -- after the flag clears takes the item back once the stash has returned it.
    H.reset()
    local VD = Runs.create(
        { mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[3] }, leaderSrc = 3 })
    arena[3], bucket[3] = true, 4210
    H.advance(1000)
    H.ok(HeldBy(3, VD.id) > 0, 'K3b: the fighter keeps the item while in the match')
    bucket[3], inv.hidden = nil, { [3] = true }
    from = #inv.searches
    listeners.loaded(3)
    H.advance(5000)
    H.ok(SweepSearches(3, from) > 0, 'K3b exit gap: the sweep runs with the flag set in bucket 0')
    inv.hidden, arena[3] = nil, nil
    CP.Alerts.foreignClearedAt[3] = os.time()
    H.time = H.time + 10
    H.advance(5000)
    H.eq(HeldBy(3, VD.id), 0, 'K3b exit gap: the sweep 10 s after the flag cleared takes the item back')
    CP.Alerts.foreignClearedAt[3] = nil
    CP.log = realLog
end

-- The evidence bag (Config.Custody.evidenceItem) is swept like a mission item (SKILL_CHECK K3b). The orphan list is in
-- memory only: after a restart, a bag a player kept from a run before it (he dropped while holding it) is on no list,
-- so the sweep must look for the evidence item by name. A bag without cpItem is his own and stays.
do
    Config.Custody = Config.Custody or {}
    local shipped = Config.Custody.evidenceItem
    inv.items.evidence_bag = { label = 'Evidence bag', stack = false }
    local function Bags(src, tagged)
        local n = 0
        for _, s in ipairs(inv.slots[src] or {}) do
            if s.count > 0 and s.name == 'evidence_bag' and ((s.metadata and s.metadata.cpItem == true) == tagged) then
                n = n + s.count
            end
        end
        return n
    end
    local function BagSearches(from)
        local n = 0
        for i = from + 1, #inv.searches do
            if inv.searches[i].name == 'evidence_bag' then n = n + 1 end
        end
        return n
    end
    H.reset()
    oxInventory.AddItem(3, 'evidence_bag', 1, { cpRun = 'CP-before-restart', cpItem = true })
    oxInventory.AddItem(3, 'evidence_bag', 1, { note = 'his own' })
    Config.Custody.evidenceItem = false
    local from = #inv.searches
    listeners.loaded(3)
    H.advance(5000)
    H.eq(BagSearches(from), 0, 'evidence item off (shipped): the sweep does not look for it')
    Config.Custody.evidenceItem = 'evidence_bag'
    listeners.loaded(3)
    H.advance(5000)
    H.eq(Bags(3, true), 0, 'evidence bag from before a restart: the load sweep takes it back')
    H.eq(Bags(3, false), 1, 'evidence bag without cpItem: the player\'s own, it stays')
    Config.Custody.evidenceItem = shipped
end

-- ============================================================================
--                                    REVIEW
-- ============================================================================
-- Create re-checks after its lookups (they may yield).

H.reset()
local origBase = CP.Payouts.baseFor
local nested
CP.Payouts.baseFor = function(m)
    CP.Payouts.baseFor = origBase
    nested = Runs.create(
        { mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[5] }, leaderSrc = 5 })
    return 800
end
local raced, racedErr = Runs.create(
    { mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[5] }, leaderSrc = 5 })
CP.Payouts.baseFor = origBase
H.eq(raced, nil, 'an accept that raced another one for the same officer is refused')
H.eq(racedErr, 'err.already_on_run', 'race refusal reason')
H.ok(type(nested) == 'table' and Runs.getBySrc(5) == nested, 'the run that won the race stays')
Runs.removeParticipant(nested, 5, 'cancelled')

local winner
Config.Limits.maxConcurrentRuns = #Runs.all() + 1
CP.Payouts.baseFor = function(m)
    CP.Payouts.baseFor = origBase
    winner = Runs.create(
        { mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[6] }, leaderSrc = 6 })
    return 800
end
local capped, cappedErr = Runs.create(
    { mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[5] }, leaderSrc = 5 })
CP.Payouts.baseFor = origBase
Config.Limits.maxConcurrentRuns = 12
H.eq(capped, nil, 'two racing accepts never pass the server cap together')
H.eq(cappedErr, 'err.server_busy', 'cap refusal reason')
H.eq(Runs.isOnMission(5), false, 'the refused officer is on no run')
H.ok(type(winner) == 'table', 'the accept that got the last slot runs')
Runs.removeParticipant(winner, 6, 'cancelled')

-- ============================================================================
--                                    REVIEW
-- ============================================================================
-- Entity health before the first sync, late spawns, pending spawns.

H.reset()
local N = Runs.create(
    { mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[2] }, leaderSrc = 2 })
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
    local e = NewEnt('ped', model, x, y, z)
    ents[e].exists = false   -- the entity only appears after the spawn wait
    lateHandle = e
    return e
end
local tracked = 0
for _ in pairs(N.entities) do tracked = tracked + 1 end
Config.Limits.maxEntities = tracked + 1
local lateResult = 'pending'
CreateThread(function()
    lateResult = Runs.spawnPed(N, { obj = 1, model = 'g_m_y_lost_01', coords = vec4(0, 0, 0, 0) })
end)
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

-- ============================================================================
--                                    REVIEW
-- ============================================================================
-- Objective events past the last objective reach CP.AntiCheat.

local checked = {}
local origCheck = CP.AntiCheat.checkEvent
CP.AntiCheat.checkEvent = function(run, src, index, ev)
    checked[#checked + 1] = index
    if index > run.objectiveIndex then return false, 'err.unexpected_event' end
    return true
end
local evBefore = #CallsOf('onEvent')
H.fire('crimson-police:server:objective', 2, N.id, 99, { type = 'hit' })
CP.AntiCheat.checkEvent = origCheck
H.eq(checked[#checked], 99, 'an event for an objective past the last one is checked (and flagged) by CP.AntiCheat')
H.eq(#CallsOf('onEvent'), evBefore, 'and never reaches a block')
-- A checkEvent that throws drops the event: an unchecked event never skips the speed and duplicate checks.
CP.AntiCheat.checkEvent = function() error('checkEvent broke') end
H.fire('crimson-police:server:objective', 2, N.id, N.objectiveIndex, { type = 'hit' })
CP.AntiCheat.checkEvent = origCheck
H.eq(#CallsOf('onEvent'), evBefore, 'an event CP.AntiCheat failed to check never reaches a block')
H.fire('crimson-police:server:objective', 2, N.id, N.objectiveIndex, { type = 'hit' })
H.eq(#CallsOf('onEvent'), evBefore + 1, 'the same event, once checked, does')

-- ============================================================================
--                                    REVIEW
-- ============================================================================
-- A stale off-duty signal does not remove an officer.

listeners.lost(2, 'off_duty')      -- recheck[2] is nil: the live check says they are on duty again
H.ok(Runs.isParticipant(N, 2), 'an off-duty signal the live check no longer confirms is ignored')
recheck[2] = 'off_duty'
listeners.lost(2, 'off_duty')
recheck[2] = nil
H.eq(Runs.isParticipant(N, 2), false, 'a confirmed off-duty signal removes the officer')
H.eq(RowsOf(N.id)[1].end_reason, 'off_duty', 'end reason off_duty')

-- ============================================================================
--                                    REVIEW
-- ============================================================================
-- Reclassify only turns real_call into real_call_cancelled.

MySQL.insert.await(
    'INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason, points_base) VALUES (?, \'tactical\', \'test_mission\', \'CIT7\', \'sast\', \'abandoned\', \'force_recall\', 200)',
    { 'fr-run' })
H.eq(Runs.reclassify('CIT7', 'fr-run', 'real_call_cancelled'), false,
    'a stored force recall never becomes real_call_cancelled')
H.eq(RowsOf('fr-run')[1].end_reason, 'force_recall', 'the force recall row is unchanged')
H.reset()
local R = Runs.create({
    mission = mission,
    locationIndex = 1,
    missionType = 'tactical',
    members = { O[1], O[3] },
    leaderSrc = 1,
})
Runs.markArrived(R, 1)
Runs.removeParticipant(R, 3, 'force_recall')
H.eq(Runs.reclassify('CIT3', R.id, 'real_call_cancelled'), false, 'an in-memory force recall is not reclassified')
H.eq(R.payTier.tier, 'reinforced', 'the pay tier stays after a refused reclassify')
local vR = Runs.view(R, 1)
H.eq(vR.me, 1, 'view.me is the viewer')
H.eq(vR.isBoss, false, 'view.isBoss')
Runs.removeParticipant(R, 1, 'cancelled')

-- ============================================================================
--             REVIEW: presence flags go through CP.AntiCheat.flag
-- ============================================================================

H.reset()
local origPresence = CP.AntiCheat.presenceOk
CP.AntiCheat.presenceOk = function(run, p) return p.src ~= 6 end
local P2 = Runs.create({
    mission = mission,
    locationIndex = 1,
    missionType = 'tactical',
    members = { O[5], O[6] },
    leaderSrc = 5,
})
H.eq(Runs.view(P2, 6).startIn, 600, 'view.startIn before the start')
Runs.markArrived(P2, 5)
H.eq(Runs.view(P2, 5).startIn, nil, 'no startIn once in progress')
H.advance(6000)
H.ok(Runs.objectiveComplete(P2, 1), 'presence run: objective 1')
H.ok(Runs.objectiveComplete(P2, 2), 'presence run: objective 2')
CP.AntiCheat.presenceOk = origPresence
local pf = Last('ac.flag')
H.eq(pf.reason, 'presence', 'presence flag raised through CP.AntiCheat.flag')
H.eq(pf.src, 6, 'on the absent participant')
H.ok(type(pf.detail) == 'string' and pf.detail:find('40%', 1, true) ~= nil, 'with the presence share in the detail')
local prow = H.sql('SELECT citizenid, flagged, flag_reason FROM cp_mission_runs WHERE run_uuid = ? ORDER BY citizenid',
    { P2.id })
H.eq(H.bit(prow[1].flagged), 0, 'the present participant is not flagged')
H.eq(H.bit(prow[2].flagged), 1, 'the absent participant is flagged')
H.eq(prow[2].flag_reason, 'presence', 'flag reason presence')

-- ============================================================================
--                      REVIEW: every run ticks on its own
-- ============================================================================

H.reset()
local slowTicks = 0
CP.Blocks.register('slow_block', {
    tick = function() slowTicks = slowTicks + 1 if slowTicks == 1 then Wait(3500) end end,
})
local slowMission = CP.U.deepcopy(mission)
slowMission.id, slowMission.items, slowMission.scaling = 'slow_mission', {}, {}
slowMission.objectives = { { block = 'slow_block', label = 'Slow', minSeconds = 0 } }
local S1 = Runs.create(
    { mission = slowMission, locationIndex = 1, missionType = 'patrol', members = { O[2] }, leaderSrc = 2 })
local S2 = Runs.create(
    { mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[3] }, leaderSrc = 3 })
Runs.markArrived(S1, 2)
Runs.markArrived(S2, 3)
local function TicksOf(run)
    local n = 0
    for _, c in ipairs(calls) do if c.name == 'tick' and c.ctx.run == run then n = n + 1 end end
    return n
end
local s2Before = TicksOf(S2)
local s2Remaining = Runs.remaining(S2)
H.advance(3000)
H.eq(slowTicks, 1, 'a busy tick is not re-entered')
H.ok(TicksOf(S2) - s2Before >= 2, 'another run keeps ticking while one tick waits')
H.ok(Runs.remaining(S2) < s2Remaining - 2, 'and its timer keeps running')
H.advance(2000)
H.ok(slowTicks >= 2, 'the slow run ticks again once its tick finished')
Runs.removeParticipant(S1, 2, 'cancelled')
Runs.removeParticipant(S2, 3, 'cancelled')

-- ============================================================================
--                                    REVIEW
-- ============================================================================
-- A cuffed NPC frees the armed cap; the state comes from the server (CP.Npc), never the bag.

H.reset()
local Q = Runs.create(
    { mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[2] }, leaderSrc = 2 })
Runs.markArrived(Q, 2)
local qp, qpNet = Runs.spawnPed(Q,
    { obj = 1, model = 'g_m_y_lost_01', coords = vec4(0, 0, 0, 0), armed = true, weapon = 'WEAPON_PISTOL' })
Config.Limits.maxArmedAlive = 1
H.eq(Runs.canSpawn(Q, 1, true), false, 'the armed cap counts the armed NPC')
H.eq(Q.entities[qpNet].bag and Q.entities[qpNet].bag.state, 'idle', 'the engine keeps its own copy of the bag it wrote')
H.eq(Q.entities[qpNet].bag and Q.entities[qpNet].bag.armed, true, 'the copy has the bag fields')
bags[qp].cp = { run = Q.id, obj = 1, state = 'cuffed', armed = true }      -- a client writes its own bag
H.advance(600)
H.eq(Runs.canSpawn(Q, 1, true), false, 'a client-written "cuffed" bag does not free the armed cap')
local npcStates = { [qpNet] = 'cuffed' }
CP.Npc = {
    getState = function(netId) return npcStates[netId] end,
}
H.ok(Runs.canSpawn(Q, 1, true), 'a cuffed NPC (CP.Npc, the server record) no longer counts as armed and alive')
npcStates[qpNet] = 'hostile'
H.eq(Runs.canSpawn(Q, 1, true), false, 'hostile again: counted again')
CP.Npc = nil
Config.Limits.maxArmedAlive = 25
Runs.removeParticipant(Q, 2, 'cancelled')

-- ============================================================================
--                                 INTEGRATION
-- ============================================================================
-- A unit is kept and unlocked only for normal runs (docs/notes/teams.md).

H.reset()
local unlocksBefore = Count('units.unlock')
local OpRun = Runs.create({
    mission = mission,
    locationIndex = 1,
    missionType = 'tactical',
    members = { O[1] },
    leaderSrc = 1,
    operationId = 9,
})
H.eq(OpRun.unit, nil, 'an operation run keeps no unit (its first joiner may lead a unit locked elsewhere)')
Runs.removeParticipant(OpRun, 1, 'cancelled')
H.eq(Count('units.unlock'), unlocksBefore, 'an operation run never unlocks a unit')
local TestRun = Runs.create({
    mission = mission,
    locationIndex = 1,
    missionType = 'tactical',
    members = { O[1] },
    leaderSrc = 1,
    test = { adminSrc = 1, useStartRoute = false },
})
H.eq(TestRun.unit, nil, 'a test run keeps no unit')
Runs.removeParticipant(TestRun, 1, 'cancelled')
H.eq(Count('units.unlock'), unlocksBefore, 'a test run never unlocks a unit')
local NormRun = Runs.create(
    { mission = mission, locationIndex = 1, missionType = 'tactical', members = { O[1] }, leaderSrc = 1 })
H.eq(NormRun.unit, unitA, 'a normal run keeps the leader unit')
Runs.removeParticipant(NormRun, 1, 'cancelled')
H.eq(Count('units.unlock'), unlocksBefore + 1, 'and unlocks it at the end')

-- ============================================================================
--                                 INTEGRATION
-- ============================================================================
-- ctx.state is one table across hooks; entities stay until the run ends.

H.reset()
local seenState = {}
local function Seen(hook, ctx) seenState[#seenState + 1] = { hook = hook, index = ctx.index, state = ctx.state } end
CP.Blocks.register('keep_block', {
    prepare = function(ctx) Seen('prepare', ctx); ctx.state.mark = 'obj' .. ctx.index end,
    start = function(ctx)
        Seen('start', ctx)
        if ctx.index == 1 then
            ctx.state.device = select(2,
                ctx.spawnObject({ model = 'prop_ld_bomb', coords = vec4(120.0, 120.0, 30.0, 0.0), role = 'device' }))
        end
    end,
    tick = function(ctx) Seen('tick', ctx) end,
    onEvent = function(ctx, src, ev) Seen('onEvent', ctx); return true end,
    checklist = function(ctx) return { { label = 'x', done = false, value = 0, max = 1 } } end,
    stop = function(ctx) Seen('stop', ctx) end,
})
local keepMission = CP.U.deepcopy(mission)
keepMission.id, keepMission.items, keepMission.scaling = 'keep_mission', {}, {}
keepMission.objectives = {
    { block = 'keep_block', label = 'Find', minSeconds = 0 },
    { block = 'keep_block', label = 'Defuse', minSeconds = 0 },
}
local KP = Runs.create({
    mission = keepMission,
    locationIndex = 1,
    missionType = 'tactical',
    members = { O[2] },
    leaderSrc = 2,
})
Runs.markArrived(KP, 2)
H.advance(1000)
H.fire('crimson-police:server:objective', 2, KP.id, 1, { type = 'look' })
local deviceNet = KP.objectives[1].state.device
H.ok(deviceNet ~= nil and KP.entities[deviceNet] ~= nil, 'objective 1 spawned its device')
H.ok(Runs.objectiveComplete(KP, 1), 'objective 1 done')
H.ok(KP.entities[deviceNet] ~= nil, 'the device of a completed objective is still tracked')
H.ok(not deleted[KP.entities[deviceNet].entity], 'and not deleted (the next objective defuses it)')
local deviceEnt = KP.entities[deviceNet].entity
H.advance(2000)
H.fire('crimson-police:server:objective', 2, KP.id, 2, { type = 'look' })
local allSame, hooks = true, {}
for _, s in ipairs(seenState) do
    hooks[s.hook .. s.index] = true
    if s.state ~= KP.objectives[s.index].state or s.state.mark ~= 'obj' .. s.index then allSame = false end
end
H.ok(allSame, 'every hook of an objective got the same persistent ctx.state (run.objectives[i].state)')
H.ok(
    hooks.prepare1 and hooks.start1 and hooks.tick1 and hooks.onEvent1 and hooks.stop1 and hooks.prepare2
        and hooks.start2 and hooks.tick2 and hooks.onEvent2,
    'prepare, start, tick, onEvent and stop were all seen'
)
H.eq(Runs.ctx(KP, 2), Runs.ctx(KP, 2), 'CP.Runs.ctx returns the one ctx of an objective')
H.eq(Runs.ctx(KP, 2).state, KP.objectives[2].state, 'CP.Runs.ctx carries the persistent state')
H.eq(Runs.ctx(KP, 9), nil, 'CP.Runs.ctx of an unknown objective')
H.ok(Runs.objectiveComplete(KP, 2), 'objective 2 done: the run ends')
H.ok(deleted[deviceEnt], 'the device goes when the run ends')
H.eq(Runs.ctx(KP, 1), nil, 'CP.Runs.ctx of an ended run')

-- ============================================================================
--                                 INTEGRATION
-- ============================================================================
-- The tablet log point is pushed at once; the area of the Active Mission view.

H.reset()
local LG = Runs.create(
    { mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[2] }, leaderSrc = 2 })
local startMsg
Runs.markArrived(LG, 2)
for _, e in ipairs(EventsTo('crimson-police:client:objective', 2)) do
    if e.args[2] == 1 and e.args[3].action == 'start' then startMsg = e.args[3] end
end
H.ok(startMsg ~= nil and startMsg.area ~= nil and startMsg.area.x == 100.0,
    'client:objective \'start\' carries the objective\'s reference point')
local pushesBefore = Count('push')
LG.objectives[1].state.log = { point = 1, choices = { { id = 'secure', label = 'Secure' } } }
H.fire('crimson-police:server:objective', 2, LG.id, 1, { type = 'hit' })
H.eq(Count('push'), pushesBefore + 1, 'a new log point is pushed at once (inside the progress-push throttle)')
H.eq(Last('push').data.log.point, 1, 'the pushed view carries the log')
LG.objectives[1].state.log = nil
Runs.dispatch(LG, 1, nil, { type = 'cuffed', netId = 1 })
H.eq(Count('push'), pushesBefore + 2, 'a closed log is pushed at once')
H.eq(Last('push').data.log, nil, 'the view has no log any more')
LG.objectives[1].state.log = { point = 2, choices = { { id = 'secure', label = 'Secure' } } }
H.advance(1000)
H.eq(Last('push').data.log.point, 2, 'a log point set by a block tick is pushed on that tick')
LG.objectives[1].state.log = nil
H.fire('crimson-police:server:telemetry', 2, LG.id, 'area', { index = 0, text = 'Route 68 · Harmony' })
H.eq(Last('push').src, 2, 'the area is pushed to that participant')
H.eq(Runs.view(LG, 2).area, 'Route 68 · Harmony', 'view.area falls back to the start')
H.fire('crimson-police:server:telemetry', 2, LG.id, 'area',
    { index = 1, text = '  Joshua Rd\n · Grand Senora Desert ' })
H.eq(Runs.view(LG, 2).area, 'Joshua Rd · Grand Senora Desert',
    'view.area of the current objective, control characters removed')
H.fire('crimson-police:server:telemetry', 2, LG.id, 'area', { index = 1, text = 'Somewhere else' })
H.eq(Runs.view(LG, 2).area, 'Joshua Rd · Grand Senora Desert', 'the first text per point is kept')
H.fire('crimson-police:server:telemetry', 2, LG.id, 'area', { index = 2, text = 'Not current' })
H.eq(LG.participants[2].area[2], nil, 'an area for an objective that is not current is ignored')
H.fire('crimson-police:server:telemetry', 2, LG.id, 'area', { index = 0, text = string.rep('x', 200) })
H.fire('crimson-police:server:telemetry', 3, LG.id, 'area', { index = 1, text = 'Forged' })
H.eq(Runs.view(LG, 3).area, nil, 'a non-participant\'s text goes nowhere')
H.eq(Runs.view(LG, 2).area, 'Joshua Rd · Grand Senora Desert',
    'each participant\'s view shows only their own client\'s text')
Runs.removeParticipant(LG, 2, 'cancelled')

-- ============================================================================
--                                 INTEGRATION
-- ============================================================================
-- endRun leaves a downed (keepFlag) participant's flag alone; 'cancelled' starts no.
-- cooldown; cash_multiplier is rounded to 2 decimals while the breakdown keeps the exact amount ──
H.reset()
H.players[7] = { coords = vec3(0.0, 0.0, 0.0) }
H.players[8] = { coords = vec3(0.0, 0.0, 0.0) }
local O7 = {
    src = 7,
    citizenid = 'CIT77',
    name = 'Gil Grant',
    department = 'sast',
    departmentShort = 'SAST',
    job = 'sast',
    rank = 'Trooper',
}
local O8 = {
    src = 8,
    citizenid = 'CIT88',
    name = 'Hal Hart',
    department = 'sast',
    departmentShort = 'SAST',
    job = 'sast',
    rank = 'Trooper',
}
local realCompute = CP.Cash.compute
CP.Cash.compute = function(run, p)
    local amount = p.result == 'completed' and CP.U.round(run.cashBase * 1.15 * 1.25) or 0
    return amount, { B = run.cashBase, mTier = 1.15, mMod = 1.25, amount = amount }
end
local KF = Runs.create(
    { mission = mission, locationIndex = 1, missionType = 'tactical', members = { O7, O8 }, leaderSrc = 7 })
Runs.markArrived(KF, 7)
Runs.removeParticipant(KF, 8, 'downed', { keepFlag = true })
local clearsKF = {}
for _, s in ipairs(log['alerts.clear'] or {}) do clearsKF[s] = true end
H.eq(clearsKF[8], nil, 'the downed participant keeps the flag at the leave (CP.Downed owns it)')
H.advance(6000)
H.ok(Runs.objectiveComplete(KF, 1), 'keepFlag run: objective 1')
H.ok(Runs.objectiveComplete(KF, 2), 'keepFlag run: objective 2 ends the run')
local clears8 = 0
for _, s in ipairs(log['alerts.clear'] or {}) do if s == 8 then clears8 = clears8 + 1 end end
H.eq(clears8, 0, 'endRun never clears the flag of a participant who left with keepFlag')
H.ok(log['alerts.clear'][#log['alerts.clear']] == 7, 'endRun clears the flags of the participants still in the run')
local kfRow = H.sql(
    'SELECT cash_multiplier, breakdown FROM cp_mission_runs WHERE run_uuid = ? AND citizenid = \'CIT77\'', { KF.id })[1]
H.near(tonumber(kfRow.cash_multiplier), 1.44, 1e-9, 'cash_multiplier 1.15 x 1.25 = 1.4375 is stored as 1.44')
H.eq(CP.U.jsonField(kfRow.breakdown).cash.amount, 1150,
    'the breakdown keeps the exact amount (800 x 1.4375), which CP.Cash pays')
CP.Cash.compute = realCompute
local CN = Runs.create(
    { mission = mission, locationIndex = 1, missionType = 'tactical', members = { O7 }, leaderSrc = 7 })
local cdBefore = Runs.cooldowns('CIT77')
local typeBefore, missionBefore = cdBefore.types.tactical, cdBefore.missions.test_mission
Runs.markArrived(CN, 7)
Runs.removeParticipant(CN, 7, 'cancelled')
H.eq(Runs.cooldowns('CIT77').types.tactical, typeBefore, '\'cancelled\' starts no type cooldown')
H.eq(Runs.cooldowns('CIT77').missions.test_mission, missionBefore, '\'cancelled\' starts no new mission cooldown')
H.eq(H.sql('SELECT state FROM cp_mission_runs WHERE run_uuid = ?', { CN.id })[1].state, 'abandoned',
    '\'cancelled\' is abandoned')

-- ============================================================================
--                                    FIXES
-- ============================================================================
-- Downed at the end, operation lock / real call at create, in-arena bag, items hook,
-- server-side vehicle samples, server-side weapon proof ──────────────────────
do
    H.reset()
    H.players[7].vehicle, H.players[8].vehicle = nil, nil
    -- a participant already down when the run completes has Failed (Hard rule 18), through CP.Downed
    local downed = {}
    CP.Qbx.isDowned = function(src) return downed[src] == true end
    local handled = {}
    CP.Downed = {
        handle = function(run, src)
            handled[#handled + 1] = src
            Runs.removeParticipant(run, src, 'downed', { keepFlag = true })
        end,
        isPending = function(src) return false end,
    }
    local DN = Runs.create({
        mission = mission,
        locationIndex = 1,
        missionType = 'tactical',
        members = { O7, O8 },
        leaderSrc = 7,
    })
    Runs.markArrived(DN, 7)
    Runs.markArrived(DN, 8)
    H.advance(6000)
    downed[8] = true
    H.ok(Runs.objectiveComplete(DN, 1), 'downed-at-end: objective 1')
    local clearsB = Count('alerts.clear')
    H.ok(Runs.objectiveComplete(DN, 2), 'downed-at-end: objective 2 ends the run')
    H.eq(DN.state, 'ended', 'downed-at-end: run ended')
    H.eq(handled[1], 8, 'downed-at-end: CP.Downed.handle gets the downed participant (pick-up / EMS flow)')
    local r8 = H.sql(
        'SELECT state, end_reason, cash_base FROM cp_mission_runs WHERE run_uuid = ? AND citizenid = \'CIT88\'',
        { DN.id })[1]
    H.eq(r8.state, 'failed', 'downed-at-end: the downed participant has Failed')
    H.eq(r8.end_reason, 'downed', 'downed-at-end: end_reason \'downed\'')
    H.eq(DN.participants[8].result, 'failed', 'downed-at-end: result failed')
    local r7 = H.sql('SELECT state FROM cp_mission_runs WHERE run_uuid = ? AND citizenid = \'CIT77\'', { DN.id })[1]
    H.eq(r7.state, 'completed', 'downed-at-end: the others keep the completed result')
    local c8 = 0
    for i = clearsB + 1, Count('alerts.clear') do if log['alerts.clear'][i] == 8 then c8 = c8 + 1 end end
    H.eq(c8, 0, 'downed-at-end: the downed participant keeps the flag (CP.Downed owns it)')
    H.eq(DN.stats.downs, 1, 'downed-at-end: down counted')

    -- without CP.Downed.handle: still Failed (flag cleared, since nothing is pending)
    CP.Downed = nil
    local DN2 = Runs.create({
        mission = mission,
        locationIndex = 1,
        missionType = 'tactical',
        members = { O7, O8 },
        leaderSrc = 7,
    })
    Runs.markArrived(DN2, 7)
    Runs.markArrived(DN2, 8)
    Runs.endRun(DN2, 'completed', 'completed')
    H.eq(DN2.participants[8].result, 'failed', 'downed-at-end without CP.Downed: Failed')
    H.eq(DN2.participants[7].result, 'completed', 'downed-at-end without CP.Downed: others completed')
    -- everyone down: the run ends failed
    downed[7] = true
    local DN3 = Runs.create({
        mission = mission,
        locationIndex = 1,
        missionType = 'tactical',
        members = { O7, O8 },
        leaderSrc = 7,
    })
    Runs.markArrived(DN3, 7)
    Runs.markArrived(DN3, 8)
    Runs.endRun(DN3, 'completed', 'completed')
    H.eq(DN3.state, 'ended', 'all downed at the end: run ended')
    H.eq(DN3.endState, 'failed', 'all downed at the end: the run failed')
    H.eq(DN3.participants[7].endReason, 'downed', 'all downed at the end: downed reason')
    CP.Qbx.isDowned = nil
    downed = {}

    -- Runs.create re-checks the Cross-Department lock and real calls right before registering the run
    CP.Operations.isLocked = function() return true end
    local nr, why = Runs.create(
        { mission = mission, locationIndex = 1, missionType = 'tactical', members = { O7 }, leaderSrc = 7 })
    H.eq(nr, nil, 'operation locked: no normal run')
    H.eq(why, 'err.operation_locked', 'operation locked: err.operation_locked')
    H.eq(Runs.isOnMission(7), false, 'operation locked: nobody registered')
    nr, why = Runs.create({
        mission = boss,
        locationIndex = 1,
        missionType = 'weekly_boss',
        members = { O7 },
        leaderSrc = 7,
        isBoss = true,
    })
    H.eq(why, 'err.operation_locked', 'operation locked: no Weekly Boss either')
    local opRun = Runs.create({
        mission = mission,
        locationIndex = 1,
        missionType = 'tactical',
        members = { O7 },
        leaderSrc = 7,
        operationId = 99,
    })
    H.ok(opRun ~= nil, 'operation locked: the operation run itself is created')
    Runs.removeParticipant(opRun, 7, 'cancelled')
    CP.Operations.isLocked = nil
    CP.Calls = {
        isOnCall = function(src) return src == 8 end,
    }
    nr, why = Runs.create({
        mission = mission,
        locationIndex = 1,
        missionType = 'tactical',
        members = { O7, O8 },
        leaderSrc = 7,
    })
    H.eq(why, 'err.member_on_call', 'a member on a real call: refused')
    nr, why = Runs.create(
        { mission = mission, locationIndex = 1, missionType = 'tactical', members = { O8 }, leaderSrc = 8 })
    H.eq(why, 'err.on_call', 'the leader on a real call: refused')
    CP.Calls = nil

    -- a member who disconnects while Runs.create waits on a lookup is never registered: the playerDropped
    -- handler ran before the run existed, so nothing else would remove them
    local function DropDuring(src)
        dropped[src] = true
        H.fire('playerDropped', src)
    end
    local function Discard(run)
        if type(run) ~= 'table' then return end
        for _, s in ipairs(Runs.activeSrcs(run)) do Runs.removeParticipant(run, s, 'cancelled') end
    end
    CP.Calls = {
        isOnCall = function(src)
            if src == 8 then DropDuring(8) end
            return false
        end,
    }
    nr, why = Runs.create({
        mission = mission,
        locationIndex = 1,
        missionType = 'tactical',
        members = { O7, O8 },
        leaderSrc = 7,
    })
    CP.Calls = nil
    dropped[8] = nil
    Discard(nr)
    H.eq(nr, nil, 'dropped during the accept: no run')
    H.eq(why, 'err.member_unavailable', 'dropped during the accept: err.member_unavailable')
    H.eq(Runs.isOnMission(7), false, 'dropped during the accept: the leader is not registered')
    H.eq(Runs.isOnMission(8), false, 'dropped during the accept: the dropped member is not registered')
    local realFirst = CP.Scoring.isFirstRunSinceDuty
    CP.Scoring.isFirstRunSinceDuty = function(src)
        if src == 8 then DropDuring(8) end
        return false
    end
    nr, why = Runs.create({
        mission = mission,
        locationIndex = 1,
        missionType = 'tactical',
        members = { O7, O8 },
        leaderSrc = 7,
        operationId = 98,
    })
    CP.Scoring.isFirstRunSinceDuty = realFirst
    dropped[8] = nil
    Discard(nr)
    H.eq(why, 'err.member_unavailable', 'dropped during the first-run lookup of an operation run: refused')
    H.eq(Runs.isOnMission(8), false, 'dropped during the first-run lookup: not registered')
    local realInfo = CP.Qbx.getInfo
    CP.Calls = {
        isOnCall = function(src)
            if src == 2 then
                CP.Qbx.getInfo = function(s)
                    if s == 2 then return { src = 2, citizenid = 'CIT9', job = { name = 'sast' } } end
                    return realInfo(s)
                end
            end
            return false
        end,
    }
    nr, why = Runs.create({
        mission = mission,
        locationIndex = 1,
        missionType = 'tactical',
        members = { O[1], O[2] },
        leaderSrc = 1,
    })
    CP.Calls = nil
    CP.Qbx.getInfo = realInfo
    Discard(nr)
    H.eq(why, 'err.member_unavailable', 'another character on the member\'s server id during the accept: refused')
    H.eq(Runs.isOnMission(2), false, 'another character during the accept: not registered')

    -- a fractional minSeconds (a hand-edited mission file) still raises the too_fast flag
    local halfMission = CP.U.deepcopy(mission)
    halfMission.objectives[1].minSeconds = 7.5
    local flagsHalf = Count('ac.flag')
    local HS = Runs.create({
        mission = halfMission,
        locationIndex = 1,
        missionType = 'patrol',
        members = { O7 },
        leaderSrc = 7,
    })
    Runs.markArrived(HS, 7)
    H.advance(2000)
    local okHalf, doneHalf = pcall(Runs.objectiveComplete, HS, 1)
    H.ok(okHalf, 'fractional minSeconds: the too_fast check does not throw')
    H.eq(doneHalf, false, 'fractional minSeconds: early completion refused')
    H.eq(Count('ac.flag'), flagsHalf + 1, 'fractional minSeconds: too_fast flagged')
    H.eq(Last('ac.flag').reason, 'too_fast', 'fractional minSeconds: flag reason')
    H.ok(tostring(Last('ac.flag').detail):find('min 7.5 s', 1, true) ~= nil,
        'fractional minSeconds: the detail keeps the fraction')
    Runs.removeParticipant(HS, 7, 'cancelled')

    -- in-arena leave: the bag is not touched (only the intent is forgotten)
    local AR = Runs.create(
        { mission = mission, locationIndex = 1, missionType = 'patrol', members = { O7 }, leaderSrc = 7 })
    local clearsA, forgetsA = Count('alerts.clear'), Count('alerts.forget')
    arena[7] = true
    H.advance(1000)
    arena[7] = nil
    H.eq(AR.participants[7].endReason, 'quit', 'in-arena: left as quit')
    H.eq(Count('alerts.clear'), clearsA, 'in-arena: CP.Alerts.clear is not called (the bag is left alone)')
    H.eq(Count('alerts.forget'), forgetsA + 1, 'in-arena: the intent is forgotten')

    -- mission items: the swapItems hook keeps them in the holder's own inventory
    H.ok(inv.hooks and inv.hooks[1] and inv.hooks[1].event == 'swapItems', 'swapItems hook registered on ox_inventory')
    local hook = inv.hooks[1].fn
    local cpSlot = { name = 'radio', metadata = { cpRun = 'x', cpItem = true } }
    local other = { name = 'water', metadata = {} }
    H.eq(hook({
        action = 'move',
        fromInventory = 7,
        toInventory = 7,
        fromType = 'player',
        toType = 'player',
        fromSlot = cpSlot,
    }), true, 'items hook: moving inside the own inventory is allowed')
    H.eq(hook({
        action = 'give',
        fromInventory = 7,
        toInventory = 8,
        fromType = 'player',
        toType = 'player',
        fromSlot = cpSlot,
    }), false, 'items hook: giving to another player is refused')
    H.eq(hook({
        action = 'move',
        fromInventory = 7,
        toInventory = 'newdrop',
        fromType = 'player',
        toType = 'drop',
        fromSlot = cpSlot,
    }), false, 'items hook: dropping is refused')
    H.eq(hook({
        action = 'move',
        fromInventory = 7,
        toInventory = 'police_stash',
        fromType = 'player',
        toType = 'stash',
        fromSlot = cpSlot,
    }), false, 'items hook: a stash is refused')
    H.eq(hook({
        action = 'swap',
        fromInventory = 'police_stash',
        toInventory = 7,
        fromType = 'stash',
        toType = 'player',
        fromSlot = other,
        toSlot = cpSlot,
    }), false, 'items hook: a swap sending the item out is refused')
    H.eq(hook({
        action = 'move',
        fromInventory = 7,
        toInventory = 'newdrop',
        fromType = 'player',
        toType = 'drop',
        fromSlot = other,
    }), true, 'items hook: other items are untouched')

    -- vehicle damage sampled by the server, with no client telemetry
    local VS = Runs.create(
        { mission = mission, locationIndex = 1, missionType = 'patrol', members = { O7 }, leaderSrc = 7 })
    Runs.markArrived(VS, 7)
    local wreck = NewEnt('vehicle', 'police', 0, 0, 0)
    ents[wreck].driver, ents[wreck].engine, ents[wreck].body = 700, 1000.0, 1000.0
    H.players[7].vehicle = wreck
    H.advance(1000)
    H.eq(VS.participants[7].vehicle.seen, true, 'server vehicle sample: seen without telemetry')
    ents[wreck].body, ents[wreck].engine = 300.0, 400.0
    H.advance(4000)
    H.eq(VS.participants[7].vehicle.body, 300.0, 'server vehicle sample: lowest body health')
    H.eq(VS.participants[7].vehicle.engine, 400.0, 'server vehicle sample: lowest engine health')
    H.players[7].vehicle = nil

    -- server-side proof of gunfire costs no_weapons_fired even without the client telemetry
    H.eq(VS.stats.weaponsFired, 0, 'no weapon fired yet')
    H.eq(Runs.noteWeaponFired(VS, 7), true, 'noteWeaponFired')
    Runs.noteWeaponFired(VS, 7)
    H.eq(VS.stats.weaponsFired, 1, 'noteWeaponFired counts once per participant')
    H.eq(VS.participants[7].firedWeapon, true, 'noteWeaponFired marks the participant')
    H.eq(Runs.noteWeaponFired(VS, 2), false, 'noteWeaponFired ignores non-participants')
    Runs.removeParticipant(VS, 7, 'cancelled')
end

-- ============================================================================
--            THE OBJECTIVE POINTER (Config.Markers, PLAN M2, §5.44)
-- ============================================================================
-- Every objective's start carries its pointer: the block's marker(ctx) hook, else a pin at the objective's anchor;
-- the 1 s tick sends client:marker only when it changed (positions of something moving: every trackEvery s).

do
    local hookCalls, hookOut, hookErr = 0, nil, false
    CP.Blocks.register('marker_block', {
        start = function(ctx) end,
        marker = function(ctx)
            hookCalls = hookCalls + 1
            if hookErr then error('broken hook') end
            return hookOut
        end,
    })
    local mm = CP.U.deepcopy(mission)
    mm.id = 'marker_mission'
    mm.items = {}
    mm.locations[1].doors = { vec4(140.0, 150.0, 31.0, 0.0), vec4(160.0, 150.0, 31.0, 0.0) }
    mm.objectives = {
        { block = 'test_block', label = 'Walk the block', minSeconds = 0, count = 1 },
        { block = 'test_block', minSeconds = 0, count = 1, points = 'doors' },
        { block = 'marker_block', label = 'Hooked', minSeconds = 0 },
    }
    mm.scaling = {}
    local function Starts(src)
        local out = {}
        for _, e in ipairs(EventsTo('crimson-police:client:objective', src)) do
            if e.args[3] and e.args[3].action == 'start' then out[#out + 1] = e.args end
        end
        return out
    end
    local function Markers(src) return EventsTo('crimson-police:client:marker', src) end

    H.ok(not Runs.isOnMission(2), 'marker run: officer 2 is free')
    H.reset()
    local R = Runs.create(
        { mission = mm, locationIndex = 1, missionType = 'patrol', members = { O[2] }, leaderSrc = 2 })
    H.ok(type(R) == 'table', 'marker run created')
    Runs.markArrived(R, 2)
    local st = Starts(2)
    H.eq(#st, 1, 'objective 1 started')
    local m1 = st[1][3].marker
    -- fallback: no hook, no anchor key, no entity yet -> a pin at the start, the objective's own name
    H.ok(type(m1) == 'table' and m1.kind == 'point' and m1.look == 'objective', 'fallback: a pin of kind objective')
    H.ok(m1 and m1.coords.x == 100.0 and m1.coords.y == 100.0, 'fallback: at the anchor (the start, nothing else yet)')
    H.eq(m1 and m1.label, 'Walk the block', 'fallback: named after the objective')
    H.eq(m1 and m1.key, nil, 'fallback at a fixed point: no net id to name')

    -- unchanged: nothing sent again, however many ticks
    H.reset()
    H.advance(5000)
    H.eq(#Markers(2), 0, 'an unchanged pointer is not sent again')

    -- the objective's own entity appears: the anchor moves onto it and names it (a new shape: sent at once)
    local ped, pedNet = Runs.spawnPed(R,
        { obj = 1, model = 'a_m_y_business_01', coords = vec4(300.0, 300.0, 30.0, 0.0) })
    H.ok(ped ~= nil, 'an entity of objective 1')
    H.advance(1000)
    local sent = Markers(2)
    H.eq(#sent, 1, 'the new anchor is sent at the next tick')
    local m2 = sent[1] and sent[1].args[3]
    local t2 = m2 and m2.kind == 'targets' and m2.targets[1]
    H.ok(t2 and #m2.targets == 1 and t2.netId == pedNet and t2.key == tostring(pedNet) and t2.x == 300.0,
        'the pointer names the live entity it sits on (one target: followed in each game, hidden by Radio Silence)')
    H.ok(t2 and t2.look == 'objective' and t2.label == 'Walk the block', 'the entity target: kind objective, named')
    H.eq(sent[1] and sent[1].args[2], 1, 'client:marker carries the objective index')

    -- it moves: new positions at most every trackEvery seconds (2)
    H.reset()
    ents[ped].coords = vec3(340.0, 300.0, 30.0)
    H.advance(1000)
    H.eq(#Markers(2), 0, 'a move inside trackEvery waits')
    H.advance(1000)
    sent = Markers(2)
    H.eq(#sent, 1, 'the move is sent once trackEvery passed')
    H.eq(sent[1] and sent[1].args[3].targets[1].x, 340.0, 'at the new server position')
    H.reset()
    for _ = 1, 6 do
        ents[ped].coords = vec3(ents[ped].coords.x + 10.0, 300.0, 30.0)
        H.advance(1000)
    end
    H.ok(#Markers(2) <= 3, ('a target moving every second is sent at most every 2 s (%d in 6 s)'):format(#Markers(2)))
    Config.Markers.trackEvery = 5
    H.reset()
    for _ = 1, 10 do
        ents[ped].coords = vec3(ents[ped].coords.x + 10.0, 300.0, 30.0)
        H.advance(1000)
    end
    H.ok(#Markers(2) <= 2, ('trackEvery = 5: at most every 5 s (%d in 10 s)'):format(#Markers(2)))
    Config.Markers.trackEvery = 2

    -- more of objective 1 appears, with lower net ids (FiveM reuses them): custody's prisoner van and its driver
    -- (registered with the objective, roles service / service_driver) and another person of the objective. The
    -- pointer stays on the entity it is on, and never names the van or its driver. (A function of its own: this
    -- file's main chunk is at Lua's 200 locals.)
    local function ExtraEntities()
        H.reset()
        local keepNet = nextNet
        nextNet = 100
        local _, vanNet = Runs.spawnVehicle(R,
            { obj = 1, model = 'policet', coords = vec4(900.0, 900.0, 30.0, 0.0), role = 'service', tag = 'transport' })
        local _, copNet = Runs.spawnPed(R, {
            obj = 1,
            model = 's_m_y_cop_01',
            coords = vec4(900.0, 900.0, 30.0, 0.0),
            role = 'service_driver',
            tag = 'transport',
        })
        nextNet = 200
        local _, otherNet = Runs.spawnPed(R,
            { obj = 1, model = 'a_m_y_business_01', coords = vec4(500.0, 500.0, 30.0, 0.0), role = 'returning_driver' })
        nextNet = keepNet
        H.ok(vanNet and copNet and otherNet and vanNet < pedNet and otherNet < pedNet,
            'later entities with lower net ids')
        H.advance(3000)
        H.eq(#Markers(2), 0, 'new entities of the objective do not move the pointer (nothing sent)')
        local mk = Runs.marker(R)
        H.eq(mk and mk.targets and mk.targets[1].netId, pedNet, 'the pointer keeps the entity it is on')
        -- that entity goes: the objective's next one by net id, never the van or its driver
        ents[ped].exists = false
        H.advance(1000)
        sent = Markers(2)
        local tk = sent[1] and sent[1].args[3].targets and sent[1].args[3].targets[1]
        H.eq(#sent, 1, 'the pointer moves when its entity goes')
        H.eq(tk and tk.netId, otherNet,
            'onto the objective\'s own person (lowest net id), not custody\'s van or driver')
        H.ok(tk and tk.x == 500.0, 'at that person')
    end
    ExtraEntities()

    -- objective 2: the first point of its anchor list, unnamed objective -> "Objective"
    H.reset()
    H.ok(Runs.objectiveComplete(R, 1, {}), 'objective 1 done')
    st = Starts(2)
    local m3 = st[1] and st[1][3].marker
    H.ok(m3 and m3.coords.x == 140.0 and m3.coords.y == 150.0, 'objective 2: the first door (its anchor)')
    H.ok(m3 and type(m3.label) == 'string' and m3.label:find('markers.objective', 1, true) ~= nil,
        'an objective without a name: the markers.objective text (a token each client resolves)')

    -- objective 3: the block's hook gives the pointer, normalised (keys as strings, coords as tables, at most 32)
    hookOut = {
        kind = 'targets',
        targets = {
            { key = 2, coords = vec3(1.0, 2.0, 3.0), look = 'point', number = 2, label = 'Door two', beyond = 100.04 },
            { netId = 4411, x = 5.0, y = 6.0, z = 7.0, look = 'fleeing', beyond = -5 },
            { label = 'no position, no net id' },
        },
    }
    H.reset()
    H.ok(Runs.objectiveComplete(R, 2, {}), 'objective 2 done')
    st = Starts(2)
    local m4 = st[1] and st[1][3].marker
    H.ok(m4 and m4.kind == 'targets' and #m4.targets == 2, 'hook: its targets (one without a place dropped)')
    H.ok(m4 and m4.targets[1].key == '2' and m4.targets[1].x == 1.0 and m4.targets[1].number == 2,
        'hook: the point keyed by its number, at its coords')
    H.ok(m4 and m4.targets[2].key == '4411' and m4.targets[2].netId == 4411, 'hook: a net id is its own key')
    -- beyond (PLAN M3, escort's truck): kept to the decimetre for each game's own line; none when not above 0
    H.ok(m4 and m4.targets[1].beyond == 100.0 and m4.targets[2].beyond == nil, 'hook: beyond kept, a bad one dropped')
    H.reset()
    H.advance(3000)
    H.eq(#Markers(2), 0, 'hook: the same marker is not sent again')
    -- a new shape (a target gone) at once
    hookOut = { kind = 'targets', targets = { hookOut.targets[2] } }
    H.advance(1000)
    sent = Markers(2)
    H.ok(#sent == 1 and #sent[1].args[3].targets == 1, 'hook: a target gone is sent at the next tick')
    -- false: the block shows it itself -> nil sent once
    hookOut = false
    H.reset()
    H.advance(1000)
    sent = Markers(2)
    H.ok(#sent == 1 and sent[1].args[3] == nil, 'hook false: the pointer goes (nil sent once)')
    H.advance(2000)
    H.eq(#Markers(2), 1, 'hook false: nothing more')
    -- not a marker: the anchor, one warning
    local warns = {}
    local realWarn = CP.warn
    CP.warn = function(tag, fmt, ...) warns[#warns + 1] = (fmt or ''):format(...) end
    hookOut = { kind = 'blob' }
    H.reset()
    H.advance(2000)
    CP.warn = realWarn
    sent = Markers(2)
    H.ok(#sent == 1 and sent[1].args[3].kind == 'point' and sent[1].args[3].look == 'objective',
        'hook gave no marker: the anchor pin instead')
    local warned = 0
    for _, w in ipairs(warns) do if w:find('marker_block', 1, true) then warned = warned + 1 end end
    H.eq(warned, 1, 'one warning for a hook that gave no marker')
    -- an error: the anchor for the rest of the objective, the hook is not called again
    hookErr = true
    H.advance(1000)
    local n = hookCalls
    H.advance(3000)
    H.eq(hookCalls, n, 'a hook that failed is not called again for this objective')
    H.ok(R.objectives[3].markerOff == true, 'the anchor from then on')
    hookErr = false

    -- Config.Markers.enabled = false: nil in the start message and nothing from the tick
    Config.Markers.enabled = false
    hookOut = { kind = 'point', coords = vec3(9.0, 9.0, 9.0) }
    H.reset()
    H.ok(Runs.testRestart ~= nil, 'restart helper')
    H.eq(Runs.marker(R), nil, 'enabled = false: no pointer')
    H.advance(1000)
    sent = Markers(2)
    H.ok(#sent <= 1 and (sent[1] == nil or sent[1].args[3] == nil), 'enabled = false: at most one nil (clear)')
    H.reset()
    H.advance(3000)
    H.eq(#Markers(2), 0, 'enabled = false: nothing sent')
    Config.Markers.enabled = true
    Runs.removeParticipant(R, 2, 'cancelled')

    -- a new run with the pointer off from the start: the start message carries none
    Config.Markers.enabled = false
    H.reset()
    local Q = Runs.create(
        { mission = mm, locationIndex = 1, missionType = 'patrol', members = { O[2] }, leaderSrc = 2 })
    Runs.markArrived(Q, 2)
    st = Starts(2)
    H.ok(#st == 1 and st[1][3].marker == nil, 'enabled = false: no marker in the start message')
    H.advance(3000)
    H.eq(#Markers(2), 0, 'enabled = false: no client:marker')
    Config.Markers.enabled = true
    Runs.removeParticipant(Q, 2, 'cancelled')
end

-- ============================================================================
--                             WHERE THE ACTION IS
-- ============================================================================
-- CP.Runs.actionPoints, Config.Route.lateArriveRange, PLAN M11.
-- What CP.Route measures a late partner against once the run is In progress: the objective's anchor and what its
-- pointer shows (the last one sent: no block hook runs for it).

do
    local out, calls = nil, 0
    CP.Blocks.register('action_block', {
        start = function() end,
        marker = function()
            calls = calls + 1
            return out
        end,
    })
    local am = CP.U.deepcopy(mission)
    am.id = 'action_mission'
    am.items = {}
    am.objectives = { { block = 'action_block', label = 'Act', minSeconds = 0 } }
    am.scaling = {}
    H.reset()
    local R = Runs.create(
        { mission = am, locationIndex = 1, missionType = 'patrol', members = { O[2] }, leaderSrc = 2 })
    H.ok(type(R) == 'table', 'action run created')
    H.eq(#Runs.actionPoints(R), 0, 'accepted: no action yet')
    out = { kind = 'area', coords = vec3(600.0, 0.0, 30.0), radius = 250.0 }
    Runs.markArrived(R, 2)
    local pts = Runs.actionPoints(R)
    H.eq(#pts, 2, 'in progress: the anchor and the pointer circle')
    H.ok(pts[1] and pts[1].coords.x == 100.0 and pts[1].coords.y == 100.0 and pts[1].radius == nil,
        'the objective anchor (here the start: nothing else yet)')
    H.ok(pts[2] and pts[2].coords.x == 600.0 and pts[2].radius == 250.0, 'the pointer circle with its radius')
    local n = calls
    Runs.actionPoints(R)
    H.eq(calls, n, 'no block hook runs for it (the pointer last sent)')
    -- targets: one with a server position, one known only by its net id (the run's entity, where the server has it)
    local _, net = Runs.spawnPed(R, { obj = 1, model = 'a_m_y_business_01', coords = vec4(800.0, 50.0, 30.0, 0.0) })
    out = { kind = 'targets', targets = { { key = 7, coords = vec3(700.0, 0.0, 30.0) }, { netId = net } } }
    H.advance(1000)
    pts = Runs.actionPoints(R)
    H.eq(#pts, 3, 'the anchor and both targets')
    H.ok(pts[1] and pts[1].coords.x == 800.0, 'the anchor moved onto the objective\'s person')
    H.ok(pts[2] and pts[2].coords.x == 700.0 and pts[2].radius == nil, 'a target at its server position')
    H.ok(pts[3] and pts[3].coords.x == 800.0 and pts[3].coords.y == 50.0, 'a net id only: where the server has it')
    Runs.removeParticipant(R, 2, 'cancelled')
    H.eq(#Runs.actionPoints(R), 0, 'ended: none')
end

-- ============================================================================
--             THE crimsonPoliceRun BAG FOR CRIMSON-CONTRACTS (V8)
-- ============================================================================
-- modules/npccombat/server.lua: exactly true (replicated) from client:start of a run whose games run the NPC damage
-- settings until he leaves or the run ends; written only on a change; never for start data with npcCombat = false.

H.load('modules/npccombat/server.lua')
local bagWrites = {}
do
    local basePlayer = _G.Player
    _G.Player = function(src)
        local real = basePlayer(src).state
        return {
            state = setmetatable({
                set = function(_, k, v, replicated)
                    if k == 'crimsonPoliceRun' then
                        bagWrites[#bagWrites + 1] = { src = src, value = v, replicated = replicated }
                    end
                    real:set(k, v, replicated)
                end,
            }, { __index = real }),
        }
    end
end
local function Bag(src) return Player(src).state.crimsonPoliceRun end
local function BagWrites(src)
    local n = 0
    for _, w in ipairs(bagWrites) do if w.src == src then n = n + 1 end end
    return n
end

H.reset()
local NB = Runs.create({
    mission = mission,
    locationIndex = 1,
    missionType = 'patrol',
    members = { O[1], O[3] },
    leaderSrc = 1,
})
H.ok(type(NB) == 'table', 'an NPC run for the bag')
H.eq(LastEvent('crimson-police:client:start', 1).args[2].npcCombat, nil,
    'an NPC run: the start data has no npcCombat field (the settings start, as before)')
H.eq(Bag(1), true, 'client:start of an NPC run: crimsonPoliceRun is exactly true')
H.eq(Bag(3), true, 'on every participant')
H.ok(bagWrites[1] and bagWrites[1].replicated == true, 'replicated (Crimson-Contracts reads LocalPlayer.state)')
Runs.removeParticipant(NB, 3, 'quit')
H.eq(Bag(3), nil, 'he left the run: cleared')
H.eq(Bag(1), true, 'his partner keeps it')
Runs.endRun(NB, 'completed', 'completed')
H.eq(Bag(1), nil, 'the run ended: cleared')
H.eq(BagWrites(1), 2, 'written only on a change: set once, cleared once')
H.eq(BagWrites(3), 2, 'the same for the one who left')

H.reset()
local LV = Runs.create({
    mission = mission,
    locationIndex = 1,
    missionType = 'patrol',
    members = { O[5] },
    leaderSrc = 5,
    npcCombat = false,
})
H.ok(type(LV) == 'table', 'a run with opts.npcCombat = false (V14\'s live runs)')
H.eq(LastEvent('crimson-police:client:start', 5).args[2].npcCombat, false, 'its start data says npcCombat = false')
H.eq(Bag(5), nil, 'npcCombat = false: the bag is never set')
Runs.removeParticipant(LV, 5, 'cancelled')
H.eq(BagWrites(5), 0, 'and never written')

-- ============================================================================
-- V9: CP.Route.requiredFor locks the route rule; the downed reasons of cases with a real suspect
-- ============================================================================

H.reset()
local lockedWith
CP.Route.requiredFor = function(r)
    lockedWith = r
    return false
end
local DC = Runs.create({
    mission = mission,
    locationIndex = 1,
    missionType = 'investigation',
    members = { O[5], O[6] },
    leaderSrc = 5,
})
CP.Route.requiredFor = nil
H.ok(type(DC) == 'table' and lockedWith == DC, 'create asks CP.Route.requiredFor with the run')
H.eq(DC.routeRequired, false, 'and locks what it answers')
H.eq(LastEvent('crimson-police:client:start', 5).args[2].routeRequired, false, 'client:start carries it')
local cd6 = Runs.cooldowns('CIT6').types.investigation
H.eq(Runs.cooldowns('CIT5').types.investigation, nil, 'no investigation cooldown before')
Runs.removeParticipant(DC, 5, 'downed_case', { keepFlag = true })
H.eq(DC.participants[5].result, 'completed', 'downed_case: result completed (a live officer keeps his lines)')
H.eq(DC.stats.downs, 1, 'downed_case counts as a down')
H.eq(Runs.cooldowns('CIT5').types.investigation, nil, 'downed_case: no type cooldown')
H.ok((Runs.cooldowns('CIT5').missions.test_mission or 0) > os.time(), 'downed_case: the mission cooldown as downed')
H.eq(RowsOf(DC.id)[1] and RowsOf(DC.id)[1].end_reason, 'downed_case', 'the row keeps downed_case')
Runs.removeParticipant(DC, 6, 'downed_kept', { keepFlag = true })
H.eq(DC.participants[6].result, 'failed', 'downed_kept: result failed (today\'s failed credit)')
H.eq(Runs.cooldowns('CIT6').types.investigation, cd6, 'downed_kept: no type cooldown')
H.eq(DC.stats.downs, 2, 'downed_kept counts as a down')

-- ============================================================================
--               RESOURCE STOP: entities deleted, nothing written
-- ============================================================================

H.reset()
local M = Runs.create(
    { mission = mission, locationIndex = 1, missionType = 'patrol', members = { O[3] }, leaderSrc = 3 })
Runs.markArrived(M, 3)
local mp = Runs.spawnPed(M, { obj = 1, model = 'x', coords = vec4(0, 0, 0, 0) })
H.eq(Bag(3), true, 'on a run before the resource stops')
TriggerEvent('onResourceStop', 'Crimson-Police')
H.eq(Bag(3), nil, 'resource stop: the crimsonPoliceRun bag is cleared')
H.ok(deleted[mp], 'entities deleted on resource stop')
H.eq(#RowsOf(M.id), 0, 'no rows on resource stop')
H.eq(Runs.get(M.id), nil, 'runs dropped')
H.eq(Runs.isOnMission(3), false, 'nobody on a mission after stop')

-- ============================================================================
--                               THE CLIENT HALF
-- ============================================================================
-- Its own process: the harness boots one side per process.

do
    local h = io.popen(
        [[lua5.4 -e "package.path=package.path..';tests/?.lua'" tests/fixtures/engine_b/client_spec.lua 2>&1]])
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

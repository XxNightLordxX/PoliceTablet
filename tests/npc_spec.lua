-- Slice npc: modules/npc/server.lua driven through a fake entity world, stubbed

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local U = CP.U
local cjson = require('cjson')

-- A real joaat (Jenkins one-at-a-time, lower case): the harness one collides for names of equal
-- length (WEAPON_PISTOL / WEAPON_HAMMER), which would make a pistol look like a melee weapon.
local function JoaatReal(s)
    s = tostring(s):lower()
    local h = 0
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = h ~ (h >> 6)
    end
    h = (h + (h << 3)) & 0xFFFFFFFF
    h = h ~ (h >> 11)
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h
end
_G.joaat, _G.GetHashKey = JoaatReal, JoaatReal

-- ============================================================================
--                                  FAKE WORLD
-- ============================================================================

local W = { ents = {}, byNet = {}, bags = {}, writes = {}, nextNet = 700, nextEnt = 50001, canceled = false }

local function IsPlayerPed(e) return type(e) == 'number' and e % 100 == 0 and H.players[e // 100] ~= nil end

_G.Entity = function(e)
    W.bags[e] = W.bags[e] or {}
    local st = W.bags[e]
    return {
        state = setmetatable({
            set = function(_, k, v, rep)
                st[k] = U.deepcopy(v)
                W.writes[#W.writes + 1] = { e = e, k = k, v = U.deepcopy(v), rep = rep }
            end,
        }, {
            __index = function(_, k) return U.deepcopy(st[k]) end,
        }),
    }
end
_G.DoesEntityExist = function(e)
    if IsPlayerPed(e) then return true end
    local x = W.ents[e]
    return x ~= nil and x.exists == true
end
_G.GetEntityCoords = function(e)
    local x = W.ents[e]
    if x then return x.coords end
    if IsPlayerPed(e) then return H.players[e // 100].coords or vec3(0.0, 0.0, 0.0) end
    return vec3(0.0, 0.0, 0.0)
end
_G.GetEntityHealth = function(e) local x = W.ents[e]; return x and x.health or 0 end
_G.GetPedArmour = function(e) local x = W.ents[e]; return x and x.armour or 0 end
_G.GetEntityType = function(e)
    if IsPlayerPed(e) then return 1 end
    local x = W.ents[e]
    return x and x.type or 0
end
_G.GetPedInVehicleSeat = function(veh, seat) local x = W.ents[veh]; return (x and seat == -1 and x.driver) or 0 end
_G.GetPedSourceOfDeath = function(e) local x = W.ents[e]; return x and x.killer or 0 end
_G.GetPedSourceOfDamage = function(e) local x = W.ents[e]; return x and x.damager or 0 end
_G.NetworkGetEntityFromNetworkId = function(n) return W.byNet[n] or 0 end
_G.WasEventCanceled = function() return W.canceled end
W.owner = {}   -- [entity] = src of the client that owns it (default: nobody, -1)
_G.NetworkGetEntityOwner = function(e) return W.owner[e] or -1 end

-- ============================================================================
--                          STUBS OF THE OTHER MODULES
-- ============================================================================

local R = {
    runs = {},
    dispatched = {},
    died = {},
    penal = {},
    outside = {},
    notes = {},
    arena = {},
    offduty = {},
    order = {},
}
local function Reset()
    R.dispatched, R.died, R.penal, R.outside, R.notes, R.order = {}, {}, {}, {}, {}, {}
    R.onDied = nil
end
CP.Runs = {
    get = function(id) return R.runs[id] end,
    all = function()
        local l = {}
        for _, r in pairs(R.runs) do l[#l + 1] = r end
        return l
    end,
    dispatch = function(run, index, src, ev)
        R.dispatched[#R.dispatched + 1] = { run = run.id, index = index, src = src, ev = ev }
        return true
    end,
    entityDied = function(run, netId, killer)
        R.died[#R.died + 1] = { run = run.id, netId = netId, killer = killer }
        R.order[#R.order + 1] = 'entityDied'
        if run.entities[netId] then run.entities[netId].dead = true end
        if R.onDied then R.onDied(run, netId, killer) end
    end,
    penalize = function(run, id, opts)
        R.penal[#R.penal + 1] = { run = run.id, id = id, src = opts and opts.src, count = opts and opts.count }
    end,
}
-- like the real one, onNpcKilled ignores a run that has already ended
CP.AntiCheat = {
    onNpcKilled = function(run, src)
        R.order[#R.order + 1] = 'onNpcKilled'
        if run.state == 'ended' then return end
        R.outside[#R.outside + 1] = { run = run.id, src = src }
    end,
}
CP.Tablet = {
    notify = function(src, kind, key, vars)
        R.notes[#R.notes + 1] = { src = src, kind = kind, key = key, vars = vars }
    end,
}
CP.Alerts = {
    inArena = function(src) return R.arena[src] == true end,
}
CP.Access = {
    getOfficer = function(src)
        if R.offduty[src] then return nil, 'err.not_on_duty' end
        return { src = src }
    end,
}

H.load('modules/npc/server.lua')
local Npc = CP.Npc
H.ok(
    type(Npc.setState) == 'function' and type(Npc.getState) == 'function' and type(Npc.isNeutralised) == 'function'
        and type(Npc.rollSurrender) == 'function' and type(Npc.enableCuff) == 'function'
        and type(Npc.onDeath) == 'function' and type(Npc.onDamaged) == 'function',
    'server API present'
)
H.ok(H.handlers['crimson-police:server:npcCuff'] ~= nil, 'npcCuff net event registered')
H.ok(H.handlers['weaponDamageEvent'] ~= nil, 'weaponDamageEvent handler registered')

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Place(src, x, y, z)
    H.players[src] = H.players[src] or {}
    H.players[src].coords = vec3(x + 0.0, y + 0.0, (z or 0.0) + 0.0)
end

local function NewRun(id, srcs, o)
    o = o or {}
    local run = { id = id, seed = o.seed or 4242, state = o.state or 'in_progress', participants = {}, entities = {} }
    for _, s in ipairs(srcs) do run.participants[s] = { src = s, status = 'active', arrived = true } end
    R.runs[id] = run
    return run
end

local function SpawnPed(run, o)
    o = o or {}
    W.nextNet, W.nextEnt = W.nextNet + 1, W.nextEnt + 1
    local netId, e = W.nextNet, W.nextEnt
    W.ents[e] = {
        exists = true,
        type = 1,
        coords = o.coords or vec3(0.0, 0.0, 0.0),
        health = o.health or 200,
        armour = o.armour or 0,
    }
    W.byNet[netId] = e
    -- like CP.Runs track(): the bag is written once and the server keeps its own copy (info.bag)
    local b = {
        run = run.id,
        obj = o.obj or 1,
        role = o.role or 'hostile',
        state = 'idle',
        armed = o.armed ~= false,
        cfg = o.cfg or { behaviour = 'balanced' },
        tag = o.tag or 'x',
    }
    run.entities[netId] = {
        entity = e,
        kind = 'ped',
        obj = o.obj or 1,
        role = o.role or 'hostile',
        armed = o.armed ~= false,
        tag = o.tag or 'x',
        bag = o.noServerCopy and nil or b,
    }
    Entity(e).state:set('cp', b, true)
    return netId, e
end

local function SpawnVehicle(driverPed)
    W.nextEnt = W.nextEnt + 1
    local e = W.nextEnt
    W.ents[e] = { exists = true, type = 2, coords = vec3(0.0, 0.0, 0.0), health = 1000, driver = driverPed }
    return e
end

local function Bag(e) return Entity(e).state.cp end
local function Tick(n) H.advance(1000 * (n or 1)) end
local function Bump(ms) H.clockMs = H.clockMs + ms end
local function Count(list, fn)
    local n = 0
    for _, x in ipairs(list) do if fn(x) then n = n + 1 end end
    return n
end
local function LastNote() return R.notes[#R.notes] end

local function Cuff(src, runId, netId)
    Bump(700) -- stays under the 3 per 2 s rate limit
    H.fire('crimson-police:server:npcCuff', src, runId, netId)
end

local function Wde(sender, data)
    H.fire('weaponDamageEvent', sender, sender, data)
end

local PISTOL = joaat('WEAPON_PISTOL')
local UNARMED = joaat('WEAPON_UNARMED')

Place(1, 0.0, 0.0, 0.0)
Place(2, 0.0, 0.0, 0.0)
Place(9, 500.0, 500.0, 0.0)

-- ============================================================================
--                     setState / getState / isNeutralised
-- ============================================================================

local run = NewRun('run-a', { 1, 2 })
local n1, e1 = SpawnPed(run, { coords = vec3(1.0, 0.0, 0.0), obj = 2 })
H.eq(Npc.getState(n1), 'idle', 'initial bag state')
H.eq(Npc.setState(run, n1, 'hostile'), true, 'setState hostile')
H.eq(Bag(e1).state, 'hostile', 'bag state written')
H.eq(Bag(e1).obj, 2, 'bag keeps obj')
H.eq(W.writes[#W.writes].rep, true, 'bag write is replicated')
H.eq(Npc.getState(n1), 'hostile', 'getState reads the bag')
H.eq(Npc.isNeutralised(n1), false, 'hostile is not neutralised')
local writes = #W.writes
H.eq(Npc.setState(run, n1, 'hostile'), true, 'same state again')
H.eq(#W.writes, writes, 'same state without extra writes nothing')
H.eq(Npc.setState(run, n1, 'bogus'), false, 'unknown state refused')
H.eq(Npc.setState(run, 99999, 'hostile'), false, 'unknown net id refused')
H.eq(Npc.setState(run, 1.5, 'hostile'), false, 'fractional net id refused')
H.eq(Npc.setState({ id = 'x', state = 'ended', entities = {} }, n1, 'hostile'), false, 'ended run refused')
local seq = Bag(e1).seq
H.eq(Npc.setState(run, n1, 'fleeing', {
    cfg = { fleePoints = { vec3(1.0, 2.0, 3.0), vec3(4.0, 5.0, 6.0) } },
    task = { action = 'flee', args = { speed = 3 } },
    run = 'hijack',
    state = 'cuffed',
    note = 'x',
}), true, 'setState with extra')
local b = Bag(e1)
H.eq(b.state, 'fleeing', 'extra cannot override state')
H.eq(b.run, 'run-a', 'extra cannot override run')
H.eq(b.cfg.behaviour, 'balanced', 'cfg merged, not replaced')
H.eq(type(b.cfg.fleePoints[1]), 'table', 'flee points serialized')
H.eq(b.cfg.fleePoints[2].z, 6.0, 'flee point values kept')
H.eq(b.task.action, 'flee', 'task stored')
H.eq(b.note, 'x', 'free extra key copied')
H.ok(b.seq > seq, 'seq incremented')
Npc.setState(run, n1, 'surrendered')
H.eq(Bag(e1).task, nil, 'state change drops the task')
Npc.setState(run, n1, 'cuffed')
H.eq(Npc.isNeutralised(n1), true, 'cuffed is neutralised')
-- a one-off task keeps its id (taskSeq) through later writes, so the host runs it once
local nt, nte = SpawnPed(run, { coords = vec3(19.0, 0.0, 0.0) })
Npc.setState(run, nt, 'surrendered', { task = { action = 'handsUp', args = {} } })
local tb = Bag(nte)
H.eq(tb.taskSeq, tb.seq, 'a task carries the seq it was written with')
Npc.enableCuff(run, nt, {})
H.eq(Bag(nte).taskSeq, tb.taskSeq, 'enableCuff keeps the task id')
H.ok(Bag(nte).seq > tb.seq, 'enableCuff still bumps seq')
Npc.setState(run, nt, 'surrendered', { cfg = { note = 1 } })
H.eq(Bag(nte).taskSeq, tb.taskSeq, 'a cfg merge keeps the task id')
H.eq(Bag(nte).task and Bag(nte).task.action, 'handsUp', 'and the task')
Npc.setState(run, nt, 'surrendered', { taskSeq = 99 })
H.eq(Bag(nte).taskSeq, tb.taskSeq, 'taskSeq cannot be set through extra')
Npc.setState(run, nt, 'cuffed')
H.eq(Bag(nte).task, nil, 'a state change drops the task')
H.eq(Bag(nte).taskSeq, nil, 'and its id')
-- a ped of another run cannot be changed through this run
local runB = NewRun('run-b', { 5 })
local nb, _ = SpawnPed(runB, {})
run.entities[nb] = nil
H.eq(Npc.setState(run, nb, 'hostile'), false, 'foreign bag refused')
R.runs['run-b'] = nil

-- ============================================================================
--                                rollSurrender
-- ============================================================================

local rA, rB = NewRun('roll-a', { 1 }, { seed = 777 }), NewRun('roll-b', { 1 }, { seed = 777 })
local same = true
for i = 1, 20 do
    if Npc.rollSurrender(rA, 1000 + i, 0.5) ~= Npc.rollSurrender(rB, 1000 + i, 0.5) then same = false end
end
H.ok(same, 'same seed, same rolls')
local first = Npc.rollSurrender(rA, 1001, 0.5)
H.eq(Npc.rollSurrender(rA, 1001, 1.0), first, 'a ped is rolled once (cached)')
H.eq(Npc.rollSurrender(rA, 2001, 0), false, 'chance 0 never surrenders')
H.eq(Npc.rollSurrender(rA, 2002, 1), true, 'chance 1 always surrenders')
H.eq(Npc.rollSurrender(rA, 2003, -3), false, 'negative chance clamps to 0')
H.eq(Npc.rollSurrender(rA, 2004, 100), true, '100 is read as 100 percent')
local yes = 0
for i = 1, 400 do if Npc.rollSurrender(rA, 3000 + i, 0.30) then yes = yes + 1 end end
H.ok(yes > 80 and yes < 160, ('0.30 surrenders roughly 30%% of peds (%d / 400)'):format(yes))
local pct = 0
for i = 1, 400 do if Npc.rollSurrender(rB, 5000 + i, 30) then pct = pct + 1 end end
H.ok(pct > 80 and pct < 160, ('30 is read as 30%% (%d / 400)'):format(pct))
H.eq(Npc.rollSurrender(nil, 1, 0.5), false, 'no run: false')
R.runs['roll-a'], R.runs['roll-b'] = nil, nil

-- ============================================================================
--                                  enableCuff
-- ============================================================================

local n2, e2 = SpawnPed(run, { coords = vec3(2.0, 0.0, 0.0), obj = 1 })
Npc.setState(run, n2, 'surrendered')
H.eq(Npc.enableCuff(run, n2, {}), true, 'enableCuff with defaults')
H.eq(Bag(e2).cuff.label, CP.L('npc.cuff'), 'default label is npc.cuff')
H.eq(Bag(e2).cuff.duration, 5000, 'default duration')
H.eq(Bag(e2).cuff.maxDistance, 3.0, 'default distance')
H.eq(Bag(e2).state, 'surrendered', 'enableCuff keeps the state')
Npc.enableCuff(run, n2, { label = '  Detain driver  ', duration = 100, maxDistance = 50 })
H.eq(Bag(e2).cuff.label, 'Detain driver', 'label trimmed')
H.eq(Bag(e2).cuff.duration, 500, 'duration clamped up')
H.eq(Bag(e2).cuff.maxDistance, 10.0, 'distance clamped down')
Npc.enableCuff(run, n2, { label = string.rep('a', 90), duration = 999999, maxDistance = 0.1 })
H.eq(#Bag(e2).cuff.label, 64, 'label clipped to 64')
H.eq(Bag(e2).cuff.duration, 60000, 'duration clamped down')
H.eq(Bag(e2).cuff.maxDistance, 1.0, 'distance clamped up')
H.eq(Npc.enableCuff(run, 424242, {}), false, 'unknown ped not cuffable')
Npc.enableCuff(run, n2, { label = 'Cuff suspect', duration = 5000, maxDistance = 3.0 })

-- ============================================================================
--                           "Cuff suspect" NET EVENT
-- ============================================================================

Reset()
local CUFF = 'crimson-police:server:npcCuff'
Cuff(1, 12345, n2)
H.eq(LastNote().key, 'err.npc_invalid', 'numeric run id refused')
Cuff(1, 'run-a', 1.5)
H.eq(LastNote().key, 'err.npc_invalid', 'fractional net id refused')
Cuff(1, 'run-a', 'abc')
H.eq(LastNote().key, 'err.npc_invalid', 'string net id refused')
Cuff(1, string.rep('r', 80), n2)
H.eq(LastNote().key, 'err.npc_invalid', 'overlong run id refused')
Cuff(1, 'no-such-run', n2)
H.eq(LastNote().key, 'err.npc_not_on_run', 'unknown run refused')
Cuff(9, 'run-a', n2)
H.eq(LastNote().key, 'err.npc_not_on_run', 'non-participant refused')
H.eq(LastNote().src, 9, 'refusal goes to the sender')
run.state = 'accepted'
Cuff(1, 'run-a', n2)
H.eq(LastNote().key, 'err.npc_run_not_active', 'run not in progress')
run.state = 'in_progress'
run.participants[1].arrived = false
Cuff(1, 'run-a', n2)
H.eq(LastNote().key, 'err.npc_not_arrived', 'not arrived')
run.participants[1].arrived = true
R.arena[1] = true
Cuff(1, 'run-a', n2)
H.eq(LastNote().key, 'err.npc_in_arena', 'in arena')
R.arena[1] = nil
R.offduty[1] = true
Cuff(1, 'run-a', n2)
H.eq(LastNote().key, 'err.npc_not_officer', 'off duty')
R.offduty[1] = nil
Cuff(1, 'run-a', n1)
H.eq(LastNote().key, 'err.npc_not_surrendered', 'cuffed ped is not surrendered')
Cuff(1, 'run-a', 31337)
H.eq(LastNote().key, 'err.npc_unknown', 'ped of no run')
Place(1, 10.0, 0.0, 0.0)
Cuff(1, 'run-a', n2)
H.eq(LastNote().key, 'err.npc_too_far', 'too far (8 m > 3.5 m)')
Place(1, 5.6, 0.0, 0.0)
Cuff(1, 'run-a', n2)
H.eq(LastNote().key, 'err.npc_too_far', 'just outside maxDistance + 0.5 (3.6 m)')
Place(1, 4.9, 0.0, 0.0)
Cuff(1, 'run-a', n2)
H.eq(LastNote().key, 'err.npc_too_fast', 'in range, but no time in reach yet')
H.eq(Bag(e2).state, 'surrendered', 'refusals change nothing')
H.eq(#R.dispatched, 0, 'refusals dispatch nothing')
Tick(2)
Cuff(1, 'run-a', n2)
H.eq(LastNote().key, 'err.npc_too_fast', 'two seconds in reach are not enough for a 5 s cuff')
Tick(2)
local notes = #R.notes
Cuff(1, 'run-a', n2)
H.eq(#R.notes, notes, 'a valid cuff sends no error')
H.eq(Bag(e2).state, 'cuffed', 'valid cuff sets cuffed')
H.eq(Npc.getState(n2), 'cuffed', 'getState cuffed')
H.eq(#R.dispatched, 1, 'one dispatch')
local d = R.dispatched[1]
H.eq(d.index, 1, 'dispatched to the owning objective (cp.obj)')
H.eq(d.src, 1, 'dispatched as the cuffing participant')
H.eq(d.ev.type, 'cuffed', 'event type cuffed')
H.eq(d.ev.netId, n2, 'event netId')
Cuff(1, 'run-a', n2)
H.eq(LastNote().key, 'err.npc_not_surrendered', 'second cuff refused')
-- rate limit: a burst of 5 in the same instant is cut at 3
Reset()
Bump(2500)
for _ = 1, 5 do H.fire(CUFF, 2, 'run-a', 'bad') end
H.eq(#R.notes, 3, 'rate limited to 3 per 2 s')
-- a partner out of reach never becomes eligible, one in reach does
local n3, e3 = SpawnPed(run, { coords = vec3(0.0, 30.0, 0.0), obj = 3 })
Npc.setState(run, n3, 'surrendered')
Npc.enableCuff(run, n3, { duration = 3000 })
Place(2, 0.0, 28.0, 0.0)
Tick(1)
Reset()
Bump(2100)
Cuff(2, 'run-a', n3)
H.eq(Bag(e3).state, 'cuffed', '3 s cuff: 1 s in reach is enough (duration - 2 s slack)')
H.eq(R.dispatched[1] and R.dispatched[1].index, 3, 'dispatched to objective 3')

-- ============================================================================
--                                DEATH WATCHER
-- ============================================================================

local deaths = {}
Npc.onDeath(function(r, netId, killer, isPart)
    deaths[#deaths + 1] = { run = r.id, netId = netId, killer = killer, isPart = isPart }
end)
Npc.onDeath('not a function')
Reset()
local k1, ke1 = SpawnPed(run, { coords = vec3(3.0, 0.0, 0.0) })
Npc.setState(run, k1, 'hostile')
Tick(1)
H.eq(#R.died, 0, 'alive ped: no death')
W.ents[ke1].health = 0
W.ents[ke1].killer = 100          -- player 1's ped
Tick(1)
H.eq(#R.died, 1, 'death reported')
H.eq(R.died[1].netId, k1, 'death net id')
H.eq(R.died[1].killer, 1, 'killer = the player whose ped did it')
H.eq(#R.outside, 0, 'participant kill is not outside help')
H.eq(#deaths, 1, 'onDeath listener called')
H.eq(deaths[1].isPart, true, 'killer is a participant')
H.eq(Bag(ke1).state, 'dead', 'bag state dead')
H.eq(Npc.getState(k1), 'dead', 'getState dead')
H.eq(Npc.isNeutralised(k1), true, 'dead is neutralised')
Tick(3)
H.eq(#R.died, 1, 'a death is reported exactly once')
H.eq(#deaths, 1, 'listeners once')
-- server-side health is sync data: a server-made ped reads 0 until a client synced it. With the health
-- natives there, a 0 is only a death after a positive read or while the server has health data (max health).
do
    _G.GetEntityMaxHealth = function(e) local x = W.ents[e]; return x and x.maxHealth or 0 end
    Reset()
    local ku, keu = SpawnPed(run, { coords = vec3(3.5, 0.0, 0.0), health = 0 })
    W.ents[keu].maxHealth = 0
    Tick(2)
    H.eq(Count(R.died, function(x) return x.netId == ku end), 0, 'unsynced ped (health 0, no max health): not a death')
    W.ents[keu].health, W.ents[keu].maxHealth = 200, 200
    Tick(1)
    H.eq(Count(R.died, function(x) return x.netId == ku end), 0, 'synced ped alive')
    W.ents[keu].health = 0
    Tick(1)
    H.eq(Count(R.died, function(x) return x.netId == ku end), 1, 'health 0 after a positive read: a death')
    Reset()
    local ks, kes = SpawnPed(run, { coords = vec3(3.6, 0.0, 0.0), health = 0 })
    W.ents[kes].maxHealth = 200
    Tick(1)
    H.eq(Count(R.died, function(x) return x.netId == ks end), 1,
        'health 0 with health data (max health): a death at first sight')
    _G.GetEntityMaxHealth = nil
end
-- run over by a non-participant's vehicle
Place(7, 900.0, 0.0, 0.0)
Reset()
local k2, ke2 = SpawnPed(run, { coords = vec3(4.0, 0.0, 0.0) })
Tick(1)
W.ents[ke2].health = 0
W.ents[ke2].killer = SpawnVehicle(700) -- driven by player 7
Tick(1)
H.eq(R.died[1] and R.died[1].killer, 7, 'vehicle kill: the driver')
H.eq(#R.outside, 1, 'outside kill reported to anti-cheat')
H.eq(R.outside[1] and R.outside[1].src, 7, 'outside killer src')
H.eq(deaths[#deaths].isPart, false, 'onDeath: not a participant')
-- killed by an NPC
Reset()
local k3, ke3 = SpawnPed(run, { coords = vec3(5.0, 0.0, 0.0), role = 'hostage', armed = false })
local _, npcEnt = SpawnPed(run, { coords = vec3(6.0, 0.0, 0.0) })
Tick(1)
W.ents[ke3].health = 0
W.ents[ke3].killer = npcEnt
Tick(1)
H.eq(#R.died, 1, 'NPC kill reported')
H.eq(R.died[1].killer, nil, 'NPC kill: no killer src')
H.eq(#R.outside, 0, 'NPC kill is not outside help')
-- no source of death: the last player hit within 5 s
Reset()
local k4, ke4 = SpawnPed(run, { coords = vec3(7.0, 0.0, 0.0) })
Tick(1)
Wde(2, { hitGlobalIds = { k4 }, weaponType = PISTOL, weaponDamage = 30 })
W.ents[ke4].health = 0
Tick(1)
H.eq(R.died[1] and R.died[1].killer, 2, 'fallback killer: last weapon hit')
-- an in-arena killer is ignored
Reset()
local k5, ke5 = SpawnPed(run, { coords = vec3(8.0, 0.0, 0.0) })
Tick(1)
R.arena[7] = true
W.ents[ke5].health = 0
W.ents[ke5].killer = 700
Tick(1)
H.eq(R.died[1] and R.died[1].killer, nil, 'in-arena killer dropped')
H.eq(#R.outside, 0, 'in-arena killer not flagged')
R.arena[7] = nil
-- an entity that vanished (still listed by the engine): dead at the next check, no killer
Reset()
local k6, ke6 = SpawnPed(run, { coords = vec3(9.0, 0.0, 0.0) })
Tick(1)
W.ents[ke6].exists = false
W.byNet[k6] = nil
local nDeaths = #deaths
Tick(1)
H.eq(#R.died, 1, 'gone: dead')
H.eq(R.died[1].killer, nil, 'gone: no killer')
H.eq(#deaths, nDeaths + 1, 'gone: onDeath listeners told')
Tick(1)
H.eq(#R.died, 1, 'gone: once')
-- deleted on purpose (removed from run.entities with the entity): not a death
Reset()
local k6b, ke6b = SpawnPed(run, { coords = vec3(9.5, 0.0, 0.0) })
Tick(1)
run.entities[k6b] = nil
W.ents[ke6b].exists = false
Tick(2)
H.eq(#R.died, 0, 'deleteEntity is not a death')
-- a ped the engine already marked dead is never reported again
Reset()
local k7, ke7 = SpawnPed(run, { coords = vec3(10.0, 0.0, 0.0) })
run.entities[k7].dead = true
W.ents[ke7].health = 0
Tick(2)
H.eq(#R.died, 0, 'engine-marked dead: not reported')
-- vehicles are not peds
Reset()
W.nextNet = W.nextNet + 1
local vnet = W.nextNet
local vEnt = SpawnVehicle(0)
W.byNet[vnet] = vEnt
run.entities[vnet] = { entity = vEnt, kind = 'vehicle', obj = 1 }
W.ents[vEnt].health = 0
Tick(2)
H.eq(#R.died, 0, 'wrecked vehicles are the engine\'s')
-- ended runs are not watched
Reset()
local runE = NewRun('run-e', { 1 })
local ne, ee = SpawnPed(runE, {})
Tick(1)
runE.state = 'ended'
W.ents[ee].health = 0
Tick(2)
H.eq(#R.died, 0, 'ended run: no deaths')
R.runs['run-e'] = nil

-- an outside kill that ends the run inside entityDied (the block completes the last objective)
-- is still flagged: anti-cheat hears about it first
Reset()
local runO = NewRun('run-o', { 1 })
local ko, keo = SpawnPed(runO, { coords = vec3(0.0, 0.0, 0.0) })
Tick(1)
R.onDied = function(r) r.state = 'ended' end
W.ents[keo].health = 0
W.ents[keo].killer = 700          -- player 7, not on the run
Tick(1)
H.eq(R.died[1] and R.died[1].netId, ko, 'outside kill reported')
H.eq(#R.outside, 1, 'an outside kill that ends the run is still flagged')
H.eq(R.order[1], 'onNpcKilled', 'anti-cheat before entityDied')
H.eq(R.order[2], 'entityDied', 'then entityDied')
R.runs['run-o'] = nil
-- deaths that change run.entities while the watcher walks it
Reset()
local runM = NewRun('run-m', { 1 })
local ma, mae = SpawnPed(runM, { coords = vec3(0.0, 0.0, 0.0) })
local mb, mbe = SpawnPed(runM, { coords = vec3(1.0, 0.0, 0.0) })
Tick(1)
local errs, oldErr = 0, CP.err
CP.err = function(...) errs = errs + 1; return oldErr(...) end
R.onDied = function(r)
    R.onDied = nil     -- the next objective starts: many new records mid-walk
    for i = 1, 40 do SpawnPed(r, { coords = vec3(50.0 + i, 0.0, 0.0) }) end
end
W.ents[mae].health = 0
W.ents[mbe].health = 0
Tick(1)
H.eq(errs, 0, 'records added during a death: no watcher error')
H.eq(Count(R.died, function(x) return x.netId == ma or x.netId == mb end), 2, 'both deaths of that tick reported')
Tick(1)
H.eq(Count(R.died, function(x) return x.netId == ma or x.netId == mb end), 2, 'still once each')
Reset()
local mc, mce = SpawnPed(runM, { coords = vec3(2.0, 0.0, 0.0) })
local md, mde = SpawnPed(runM, { coords = vec3(3.0, 0.0, 0.0) })
Tick(1)
R.onDied = function(r)   -- the death ends the run: endRun removes every record
    r.state = 'ended'
    for k in pairs(r.entities) do r.entities[k] = nil end
end
W.ents[mce].health = 0
W.ents[mde].health = 0
Tick(1)
CP.err = oldErr
H.eq(errs, 0, 'records removed during a death: no watcher error')
H.eq(Count(R.died, function(x) return x.netId == mc or x.netId == md end), 1,
    'a run ended by a death: nothing more reported for it')
R.runs['run-m'] = nil

-- ============================================================================
--                                  BAG TRUST
-- ============================================================================
-- A client can write the cp bag of an entity it owns; the server never reads it back.

Reset()
local runF = NewRun('run-f', { 1 })
local saved1 = H.players[1].coords
Place(1, 1.0, 0.0, 0.0)
do
    -- a client writes "surrendered" and a cuff on a ped the server never surrendered: nothing changes
    local nf, nfe = SpawnPed(runF, { coords = vec3(0.0, 0.0, 0.0), obj = 1 })
    local bf = Bag(nfe)
    bf.state = 'surrendered'
    bf.cuff = { label = CP.L('npc.cuff'), duration = 3000, maxDistance = 3.0 }
    Entity(nfe).state:set('cp', bf, true)       -- the client's write
    Tick(2)
    H.eq(Npc.getState(nf), 'idle', 'client-written surrendered: getState keeps the server state')
    Cuff(1, 'run-f', nf)
    H.eq(LastNote() and LastNote().key, 'err.npc_not_surrendered',
        'client-written surrendered + cuff: the cuff is refused')
    H.eq(Count(R.dispatched, function(x) return x.ev.type == 'cuffed' end), 0,
        'no cuffed event from a client-written bag')
    -- the server surrenders it for real and makes it cuffable: the cuff goes through
    Npc.setState(runF, nf, 'surrendered')
    Npc.enableCuff(runF, nf, { duration = 3000 })
    H.eq(runF.entities[nf].bag and runF.entities[nf].bag.state, 'surrendered',
        'the engine\'s copy follows the server\'s writes')
    H.eq(type(runF.entities[nf].bag.cuff), 'table', 'the engine\'s copy has the cuff')
    Tick(2)
    Cuff(1, 'run-f', nf)
    H.eq(Npc.getState(nf), 'cuffed', 'server surrender + server cuff: accepted')
    H.eq(Count(R.dispatched, function(x) return x.ev.type == 'cuffed' and x.ev.netId == nf end), 1,
        'cuffed dispatched once')

    -- a client writes "cuffed" (or "dead") on a hostile: blocks (bagCuffed -> getState) never see it
    local nh, nhe = SpawnPed(runF, { coords = vec3(2.0, 0.0, 0.0) })
    Npc.setState(runF, nh, 'hostile')
    local bh = Bag(nhe)
    bh.state = 'cuffed'
    Entity(nhe).state:set('cp', bh, true)
    Tick(1)
    H.eq(Npc.getState(nh), 'hostile', 'client-written cuffed: still hostile on the server')
    H.eq(Npc.isNeutralised(nh), false, 'client-written cuffed: not neutralised')
    bh.state = 'dead'
    Entity(nhe).state:set('cp', bh, true)
    H.eq(Npc.isNeutralised(nh), false, 'client-written dead: not neutralised')
    -- ... and a client-written run id or extra keys never survive the next server write
    Entity(nhe).state:set('cp', { run = 'other-run', state = 'safe', cfg = { forged = true }, obj = 9, junk = 1 }, true)
    H.eq(Npc.setState(runF, nh, 'fleeing'), true, 'a client-written foreign run id does not block the server')
    local after = Bag(nhe)
    H.eq(after.run, 'run-f', 'server write restores the run id')
    H.eq(after.obj, 1, 'server write restores obj')
    H.eq(after.cfg.behaviour, 'balanced', 'server write restores the engine\'s cfg')
    H.eq(after.cfg.forged, nil, 'client cfg dropped')
    H.eq(after.junk, nil, 'client keys dropped')
    H.eq(after.state, 'fleeing', 'server state written')
    -- a shot on a client-"surrendered" hostile is not shot_surrendered
    local ns, nse = SpawnPed(runF, { coords = vec3(3.0, 0.0, 0.0) })
    Npc.setState(runF, ns, 'hostile')
    Tick(1)
    local bs = Bag(nse)
    bs.state = 'surrendered'
    Entity(nse).state:set('cp', bs, true)
    Bump(3500)
    Wde(1, { hitGlobalIds = { ns }, weaponType = PISTOL })
    H.eq(Count(R.penal, function(x) return x.id == 'shot_surrendered' end), 0,
        'client-written surrendered: no shot_surrendered')

    -- the server record is seeded from the engine's copy even before any setState or tick
    local nq, nqe = SpawnPed(runF, { coords = vec3(4.0, 0.0, 0.0) })
    local bq = Bag(nqe)
    bq.state = 'cuffed'
    Entity(nqe).state:set('cp', bq, true)
    H.eq(Npc.getState(nq), 'idle', 'first getState: the engine copy, not the client-written bag')
    -- an engine without that copy: rebuilt from the engine record, never read from the bag
    local nz, nze = SpawnPed(runF, { coords = vec3(5.0, 0.0, 0.0), noServerCopy = true })
    local bz = Bag(nze)
    bz.state = 'cuffed'
    Entity(nze).state:set('cp', bz, true)
    H.eq(Npc.getState(nz), 'idle', 'no engine copy: idle, never the bag')
    H.eq(Npc.setState(runF, nz, 'hostile'), true, 'no engine copy: setState works')
    H.eq(Bag(nze).run, 'run-f', 'no engine copy: run id from the server')
    H.eq(Bag(nze).role, 'hostile', 'no engine copy: role from the engine record')

    -- a death is written from the server record
    local nd9, nde9 = SpawnPed(runF, { coords = vec3(6.0, 0.0, 0.0) })
    Npc.setState(runF, nd9, 'hostile')
    Tick(1)
    Entity(nde9).state:set('cp', { run = 'x', state = 'safe', cfg = { forged = true } }, true)
    W.ents[nde9].health = 0
    Tick(1)
    H.eq(Bag(nde9).state, 'dead', 'death written')
    H.eq(Bag(nde9).run, 'run-f', 'death written from the server record (run)')
    H.eq(Bag(nde9).cfg.forged, nil, 'death written from the server record (cfg)')
    H.eq(Npc.getState(nd9), 'dead', 'getState dead')
end
H.players[1].coords = saved1
R.runs['run-f'] = nil

-- the server code never reads the cp bag (only clients do); comments are stripped first
do
    local function Code(file)
        local f = assert(io.open(H.root .. file, 'r'))
        local text = f:read('a')
        f:close()
        text = text:gsub('%-%-%[(=*)%[.-%]%1%]', ''):gsub('%-%-[^\n]*', '')
        return text
    end
    for _, file in ipairs({ 'modules/npc/server.lua', 'modules/runs/server.lua' }) do
        local text = Code(file)
        H.eq(text:find('state%.cp'), nil, file .. ' never reads Entity(e).state.cp')
        H.eq(text:find('state%[%s*\'cp\'%s*%]'), nil, file .. ' never reads Entity(e).state[\'cp\']')
    end
end

-- ============================================================================
--                              weaponDamageEvent
-- ============================================================================

local damages = {}
Npc.onDamaged(function(r, netId, attacker)
    damages[#damages + 1] = { run = r.id, netId = netId, attacker = attacker }
end)
Reset()
local s1, se1 = SpawnPed(run, { coords = vec3(11.0, 0.0, 0.0), obj = 1 })
Npc.setState(run, s1, 'surrendered')
Tick(1)
Wde(1, { hitGlobalIds = { s1 }, weaponType = PISTOL })
H.eq(#R.penal, 0, 'a shot within the surrender grace is not penalised')
Bump(3500)
W.canceled = true
Wde(1, { hitGlobalIds = { s1 }, weaponType = PISTOL })
H.eq(#R.penal, 0, 'cancelled event ignored')
W.canceled = false
Wde(1, { hitGlobalIds = { s1 }, weaponType = PISTOL })
H.eq(#R.penal, 1, 'shooting a surrendered ped is penalised')
H.eq(R.penal[1].id, 'shot_surrendered', 'penalty id')
H.eq(R.penal[1].src, 1, 'personal penalty')
H.eq(Count(R.dispatched, function(x) return x.ev.type == 'shot' end), 1, 'shot event dispatched')
local sd = R.dispatched[#R.dispatched]
H.eq(sd.ev.netId, s1, 'shot netId')
H.eq(sd.ev.src, 1, 'shot src')
H.eq(sd.index, 1, 'shot to the owning objective')
H.eq(LastNote().key, 'npc.shot_surrendered', 'shooter warned')
H.eq(LastNote().vars.points, 20, 'warning shows the penalty')
Wde(1, { hitGlobalIds = { s1, s1, s1 }, weaponType = PISTOL })
H.eq(#R.penal, 1, 'a burst within 2 s counts once')
Bump(2100)
Wde(1, { hitGlobalId = s1, weaponType = PISTOL })
H.eq(#R.penal, 2, 'single hitGlobalId form; a later shot counts again')
Bump(2100)
Wde(9, { hitGlobalIds = { s1 }, weaponType = PISTOL })
H.eq(#R.penal, 2, 'a non-participant is not penalised')
Wde(2, { hitGlobalIds = { s1 }, weaponType = UNARMED })
H.eq(#R.penal, 2, 'melee is not a shot')
Wde(2, { hitGlobalIds = { s1 }, weaponType = PISTOL, parentGlobalId = 64999 })
H.eq(#R.penal, 3, 'a parent that does not resolve falls back to the sender')
Bump(2100)
W.byNet[64998] = 200   -- player 2's own ped as the parent entity
Wde(2, { hitGlobalIds = { s1 }, weaponType = PISTOL, parentGlobalId = 64998 })
H.eq(#R.penal, 4, 'the parent is the sender\'s own ped')
H.eq(R.penal[4].src, 2, 'penalty for the parent player')
Bump(2100)
local ownNpc, ownNpcEnt = SpawnPed(run, { coords = vec3(12.0, 0.0, 0.0) })
W.owner[ownNpcEnt] = 2
Wde(2, { hitGlobalIds = { s1 }, weaponType = PISTOL, parentGlobalId = ownNpc })
H.eq(#R.penal, 4, 'an NPC owned by the sender is not the sender')
-- forged parents: a packet can never blame another player, nor hide behind an NPC it does not own
Bump(2100)
W.byNet[64997] = 100             -- player 1's ped, named by player 2's packet
local p1Before = Count(R.penal, function(x) return x.src == 1 end)
Wde(2, { hitGlobalIds = { s1 }, weaponType = PISTOL, parentGlobalId = 64997 })
H.eq(#R.penal, 5, 'a parent naming another player: still a shot')
H.eq(R.penal[5] and R.penal[5].src, 2, 'forged parent: the sender pays, never the named player')
H.eq(Count(R.penal, function(x) return x.src == 1 end), p1Before, 'the named player is not penalised')
Bump(2100)
local strayNpc, strayNpcEnt = SpawnPed(run, { coords = vec3(12.5, 0.0, 0.0) })
W.owner[strayNpcEnt] = 1
Wde(2, { hitGlobalIds = { s1 }, weaponType = PISTOL, parentGlobalId = strayNpc })
H.eq(#R.penal, 6, 'an NPC the sender does not own does not hide the sender')
H.eq(R.penal[6] and R.penal[6].src, 2, 'NPC parent owned by someone else: the sender')
Bump(2100)
local p2veh = SpawnVehicle(100)  -- a vehicle driven by player 1, named by player 2's packet
W.nextNet = W.nextNet + 1
local p2vehNet = W.nextNet
W.byNet[p2vehNet] = p2veh
Wde(2, { hitGlobalIds = { s1 }, weaponType = PISTOL, parentGlobalId = p2vehNet })
H.eq(#R.penal, 6, 'a vehicle parent is not a shot')
Reset()
Bump(2100)
R.arena[2] = true
Wde(2, { hitGlobalIds = { s1 }, weaponType = PISTOL })
H.eq(#R.penal, 0, 'in-arena sender ignored')
R.arena[2] = nil
local hostileN = SpawnPed(run, { coords = vec3(13.0, 0.0, 0.0) })
Npc.setState(run, hostileN, 'hostile')
Tick(1)
Wde(1, { hitGlobalIds = { hostileN }, weaponType = PISTOL })
H.eq(#R.penal, 0, 'shooting a hostile is fine')
Wde(1, { hitGlobalIds = { 'x', -4, 1e12 }, weaponType = PISTOL })
Wde(1, 'not a table')
H.ok(true, 'malformed packets do not raise')
-- restrained hostage
Reset()
local h1, he1 = SpawnPed(run, { coords = vec3(14.0, 0.0, 0.0), role = 'hostage', armed = false, obj = 2 })
Npc.setState(run, h1, 'restrained')
Tick(1)
Wde(1, { hitGlobalIds = { h1 }, weaponType = PISTOL })
H.eq(#R.penal, 1, 'shooting a restrained hostage is penalised')
H.eq(Count(R.dispatched, function(x) return x.ev.type == 'shot' end), 1, 'hostage shot dispatched')
H.eq(Count(R.dispatched, function(x) return x.ev.type == 'damaged' and x.ev.attacker == 1 and x.index == 2 end), 1,
    'hostage damaged dispatched')
H.eq(damages[#damages].attacker, 1, 'onDamaged with the attacker')
H.eq(damages[#damages].netId, h1, 'onDamaged netId')
local nd = #damages
Wde(1, { hitGlobalIds = { h1 }, weaponType = PISTOL })
H.eq(#damages, nd, 'damage from one attacker counted once per second')
Bump(1100)
Wde(2, { hitGlobalIds = { h1 }, weaponType = PISTOL, parentGlobalId = ownNpc })
H.eq(#damages, nd + 1, 'NPC damage to a hostage reaches onDamaged')
H.eq(damages[#damages].attacker, nil, 'NPC attacker is nil')
H.eq(Count(R.dispatched, function(x) return x.ev.type == 'damaged' end), 1, 'NPC damage: no damaged dispatch')
Wde(9, { hitGlobalIds = { h1 }, weaponType = PISTOL })
H.eq(damages[#damages].attacker, 9, 'outside attacker reaches onDamaged')
H.eq(Count(R.dispatched, function(x) return x.ev.type == 'damaged' end), 1, 'outside attacker: no damaged dispatch')
Bump(2100)
Wde(2, { hitGlobalIds = { h1 }, weaponType = UNARMED })
H.eq(Count(R.dispatched, function(x) return x.ev.type == 'damaged' and x.ev.attacker == 2 end), 1,
    'melee on a hostage is damage')
H.eq(Count(R.penal, function(x) return x.src == 2 end), 0, 'melee on a hostage is not a shot')

-- ============================================================================
--                                 HEALTH POLL
-- ============================================================================
-- The shooter owns the ped: no weaponDamageEvent.

Reset()
local p1, pe1 = SpawnPed(run, { coords = vec3(15.0, 0.0, 0.0) })
W.owner[pe1] = 1   -- the run host simulates it: its own shots raise no weaponDamageEvent
Npc.setState(run, p1, 'surrendered')
Tick(4)
W.ents[pe1].health = 150
W.ents[pe1].damager = 100
Tick(1)
H.eq(#R.penal, 1, 'host shooting its own surrendered ped is penalised')
H.eq(R.penal[1] and R.penal[1].src, 1, 'attributed with GetPedSourceOfDamage')
Bump(2100)
W.ents[pe1].health = 140
W.ents[pe1].damager = 0
Tick(1)
H.eq(#R.penal, 1, 'a drop with no damager is ignored')
W.ents[pe1].damager = 100
Bump(2100)
Wde(1, { hitGlobalIds = { p1 }, weaponType = PISTOL })
local afterWde = #R.penal
W.ents[pe1].health = 120
Tick(1)
H.eq(#R.penal, afterWde, 'a drop right after a weapon event is that event')
Bump(3000)
W.ents[pe1].armour = 0
W.ents[pe1].health = 100
local veh = SpawnVehicle(100)
W.ents[pe1].damager = veh
Tick(1)
H.eq(#R.penal, afterWde, 'run over by a participant is not a shot')
Reset()
local h2, he2 = SpawnPed(run, { coords = vec3(16.0, 0.0, 0.0), role = 'hostage', armed = false })
Npc.setState(run, h2, 'freed')
Tick(1)
local nd2 = #damages
W.ents[he2].health = 170
W.ents[he2].damager = ownNpcEnt
Tick(1)
H.eq(#damages, nd2 + 1, 'hostage hurt by an NPC (health poll)')
H.eq(damages[#damages].attacker, nil, 'NPC damage: attacker nil')
H.eq(#R.penal, 0, 'freed hostage hurt by an NPC: no penalty')

-- A stale damage source: player 2 (not the owner) hit the ped through weaponDamageEvent while it
-- was hostile; later damage with no source of its own must not be pinned on them.
Reset()
local st1, ste1 = SpawnPed(run, { coords = vec3(17.0, 0.0, 0.0) })
W.owner[ste1] = 1
Npc.setState(run, st1, 'hostile')
Tick(1)
Wde(2, { hitGlobalIds = { st1 }, weaponType = PISTOL })
W.ents[ste1].health = 120
W.ents[ste1].damager = 200          -- GetPedSourceOfDamage still names player 2
Npc.setState(run, st1, 'surrendered')
Tick(4)
W.ents[ste1].health = 100           -- e.g. a fall: no weapon event, the old source stays
Tick(1)
H.eq(#R.penal, 0, 'stale non-owner damage source: no shot_surrendered')
local sh, she = SpawnPed(run, { coords = vec3(18.0, 0.0, 0.0), role = 'hostage', armed = false, obj = 2 })
W.owner[she] = 1
Npc.setState(run, sh, 'restrained')
Tick(1)
local nd3 = #damages
W.ents[she].health = 150
W.ents[she].damager = 200
Tick(1)
H.eq(#damages, nd3 + 1, 'hostage hurt with a stale source: still reported as hurt')
H.eq(damages[#damages].attacker, nil, 'stale non-owner source: attacker unknown')
H.eq(#R.penal, 0, 'stale non-owner source on a hostage: no shot penalty')
H.eq(Count(R.dispatched, function(x) return x.ev.type == 'damaged' end), 0, 'stale source: no damaged dispatch')
W.ents[she].damager = 100           -- the owner itself
Bump(2100)
W.ents[she].health = 130
Tick(1)
H.eq(Count(R.penal, function(x) return x.src == 1 end), 1, 'the owner shooting its own restrained hostage is penalised')
H.eq(damages[#damages].attacker, 1, 'owner damage attributed')

-- ============================================================================
--                         SERVER-SIDE PROOF OF GUNFIRE
-- ============================================================================
-- (no_weapons_fired): gun hits and gun kills by participants.

do
    local fired = {}
    CP.Runs.noteWeaponFired = function(r, src)
        fired[#fired + 1] = { run = r.id, src = src, state = r.state }
        return true
    end
    local function FiredBy(src) return Count(fired, function(x) return x.src == src end) end
    Reset()
    local runW = NewRun('run-w', { 1, 2 })
    local w1 = SpawnPed(runW, { coords = vec3(0.0, 0.0, 0.0) })
    local w2 = SpawnPed(runW, { coords = vec3(1.0, 0.0, 0.0) })
    Npc.setState(runW, w1, 'hostile')
    Tick(1)
    Wde(1, { hitGlobalIds = { w1, w2 }, weaponType = PISTOL })
    H.eq(FiredBy(1), 1, 'a gun hit on mission peds notes the shooter once per event')
    H.eq(fired[1] and fired[1].run, 'run-w', 'noted on the ped\'s run')
    Wde(2, { hitGlobalIds = { w1 }, weaponType = UNARMED })
    H.eq(FiredBy(2), 0, 'melee is not gunfire')
    Wde(9, { hitGlobalIds = { w1 }, weaponType = PISTOL })
    H.eq(FiredBy(9), 0, 'a non-participant is not noted')
    local ownW, ownWe = SpawnPed(runW, { coords = vec3(2.0, 0.0, 0.0) })
    W.owner[ownWe] = 2
    Tick(1)
    Wde(2, { hitGlobalIds = { w1 }, weaponType = PISTOL, parentGlobalId = ownW })
    H.eq(FiredBy(2), 0, 'an NPC the sender owns firing is not the sender firing')
    local vW = SpawnVehicle(200)
    W.nextNet = W.nextNet + 1
    W.byNet[W.nextNet] = vW
    Wde(2, { hitGlobalIds = { w1 }, weaponType = PISTOL, parentGlobalId = W.nextNet })
    H.eq(FiredBy(2), 0, 'a vehicle hit is not gunfire')
    R.arena[2] = true
    Wde(2, { hitGlobalIds = { w1 }, weaponType = PISTOL })
    H.eq(FiredBy(2), 0, 'in the arena: not noted')
    R.arena[2] = nil
    -- a gun kill by a participant (GetPedSourceOfDeath = their ped, cause = a gun), noted before entityDied
    _G.GetPedCauseOfDeath = function(e) local x = W.ents[e]; return x and x.cause or 0 end
    local k9, k9e = SpawnPed(runW, { coords = vec3(3.0, 0.0, 0.0) })
    Tick(1)
    R.onDied = function(r)
        r.state = 'ended'
    end -- the kill ends the run
    W.ents[k9e].health, W.ents[k9e].killer, W.ents[k9e].cause = 0, 200, PISTOL
    Tick(1)
    H.eq(FiredBy(2), 1, 'a participant\'s gun kill notes gunfire')
    H.eq(fired[#fired].state, 'in_progress', 'noted before entityDied could end the run')
    R.onDied = nil
    runW.state = 'in_progress'
    local k10, k10e = SpawnPed(runW, { coords = vec3(4.0, 0.0, 0.0) })
    Tick(1)
    local before = #fired
    W.ents[k10e].health, W.ents[k10e].killer, W.ents[k10e].cause = 0, 100, UNARMED
    Tick(1)
    H.eq(#fired, before, 'a melee kill notes nothing')
    local k11, k11e = SpawnPed(runW, { coords = vec3(5.0, 0.0, 0.0) })
    Tick(1)
    W.ents[k11e].health, W.ents[k11e].killer, W.ents[k11e].cause = 0, SpawnVehicle(100), PISTOL
    Tick(1)
    H.eq(#fired, before, 'a kill from a vehicle notes nothing')
    local k12, k12e = SpawnPed(runW, { coords = vec3(6.0, 0.0, 0.0) })
    Tick(1)
    W.ents[k12e].health, W.ents[k12e].killer, W.ents[k12e].cause = 0, 900, PISTOL
    Tick(1)
    H.eq(#fired, before, 'a non-participant\'s gun kill notes nothing')
    _G.GetPedCauseOfDeath = nil
    CP.Runs.noteWeaponFired = nil
    R.runs['run-w'] = nil
end

-- ============================================================================
--                               REGISTRY PRUNING
-- ============================================================================

Reset()
R.runs['run-a'] = nil
Tick(1)
H.eq(Npc.getState(p1), nil, 'the server record goes with the run (the bag in the pool is never read)')
W.byNet[p1] = nil
H.eq(Npc.getState(p1), nil, 'pruned after the run is gone')
Wde(1, { hitGlobalIds = { p1 }, weaponType = PISTOL })
H.eq(#R.penal, 0, 'no live run: nothing recorded')

-- ============================================================================
--             LOCALE PART: every key the npc Lua files use exists
-- ============================================================================

local function ReadFile(p)
    local f = assert(io.open(p, 'r'))
    local s = f:read('a')
    f:close()
    return s
end
local part = cjson.decode(ReadFile(H.root .. 'locales/parts/npc.json'))
local flat = true
for k, v in pairs(part) do
    if type(k) ~= 'string' or type(v) ~= 'string' then flat = false end
end
H.ok(flat, 'npc.json is a flat map of strings')
local used = {}
for _, file in ipairs({ 'modules/npc/server.lua', 'modules/npc/client.lua' }) do
    local src = ReadFile(H.root .. file)
    for key in src:gmatch('CP%.L%(\'([%w%._]+)\'') do used[key] = true end
    for key in src:gmatch('\'(err%.[%w_]+)\'') do used[key] = true end
    for key in src:gmatch('\'(npc%.[%w_]+)\'') do used[key] = true end
end
local nUsed = 0
for key in pairs(used) do
    nUsed = nUsed + 1
    H.ok(part[key] ~= nil, 'locale key in npc.json: ' .. key)
end
H.ok(nUsed >= 12, 'found the keys the module uses')
for key in pairs(part) do H.ok(used[key], 'locale key is used: ' .. key) end
H.ok(part['npc.shot_surrendered']:find('{points}', 1, true) ~= nil, 'shot warning has the {points} placeholder')

-- ============================================================================
--                       CLIENT HALF (separate Lua state)
-- ============================================================================

local p = io.popen('lua5.4 tests/fixtures/npc/client_check.lua 2>&1')
local out = p:read('a')
p:close()
local cp, cf = out:match('RESULT (%d+) (%d+)')
cp, cf = tonumber(cp), tonumber(cf)
if not cp then
    print((out:gsub('RESULT (%d+) (%d+)', 'client checks: %1 passed, %2 failed')))
    H.ok(false, 'client checks crashed')
else
    H.passes = H.passes + cp
    H.failures = H.failures + cf
    if cf > 0 then print((out:gsub('RESULT (%d+) (%d+)', 'client checks: %1 passed, %2 failed'))) end
    H.ok(cp > 50, 'client checks ran')
end

return H

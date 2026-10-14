-- The shared world of tests/custody_spec.lua, field_contact_spec.lua and process_scene_spec.lua: the real engine
-- (runs, npc, scoring, scaling), CP.Custody, the two blocks and the sc-police listener on H.entity, with spies.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })

local W = { H = H, bagWrites = {}, weapons = {}, pushes = {}, notes = {}, audits = {}, flags = {} }

-- ============================================================================
--                                   NATIVES
-- ============================================================================

local nextNet = 20000
local bags = {}
W.bags = bags
local function Ent(handle) return H.entityModel.byHandle[handle] end
W.ent = Ent

local function NewEntity(kind, model, x, y, z, h)
    nextNet = nextNet + 1
    local e = H.entity(nextNet, { kind = kind, model = model, coords = vec3(x, y, z), heading = h or 0.0 })
    if kind == 'ped' then e.health = 200 end
    return e.handle
end
_G.CreatePed = function(_, model, x, y, z, h) return NewEntity('ped', model, x, y, z, h) end
_G.CreateVehicleServerSetter = function(model, _, x, y, z, h) return NewEntity('vehicle', model, x, y, z, h) end
_G.CreateObjectNoOffset = function(model, x, y, z) return NewEntity('object', model, x, y, z) end
_G.DeleteEntity = function(h)
    local e = Ent(h)
    if e then e.exists = false end
end
_G.GiveWeaponToPed = function(h, w)
    W.weapons[#W.weapons + 1] = { h = h, w = w, at = H.clockMs }
    local e = Ent(h)
    if e then e.weapon = w end
end
_G.SetPedArmour = function(h, a) local e = Ent(h) if e then e.armour = a end end
_G.GetPedArmour = function(h) local e = Ent(h); return e and e.armour or 0 end
_G.SetVehicleNumberPlateText = function(h, p) local e = Ent(h) if e then e.plate = p end end
_G.SetEntityHeading = function(h, v) local e = Ent(h) if e then e.heading = v end end
_G.SetEntityCoords = function(h, x, y, z) local e = Ent(h) if e then e.coords = vec3(x, y, z) end end
_G.FreezeEntityPosition = function() end
_G.SetVehicleDoorsLocked = function(h, s) local e = Ent(h) if e then e.locked = s end end
_G.ClearPedTasksImmediately = function() end
_G.GetEntityHealth = function(h)
    local e = Ent(h)
    if e then return e.health or 200 end
    return 200
end
_G.GetEntityMaxHealth = function(h) local e = Ent(h); return e and 200 or 200 end
_G.GetEntityModel = function(h) local e = Ent(h); return e and joaat(e.model) or 0 end
_G.GetEntityType = function(h)
    local e = Ent(h)
    if not e then return 1 end
    return ({ ped = 1, vehicle = 2, object = 3 })[e.kind] or 0
end
_G.IsPedAPlayer = function(h) return Ent(h) == nil end
_G.GetPedSourceOfDeath = function(h) local e = Ent(h); return e and e.killer or 0 end
_G.GetPedSourceOfDamage = function(h) local e = Ent(h); return e and e.damager or 0 end
_G.GetPedCauseOfDeath = function(h) local e = Ent(h); return e and e.cause or 0 end
_G.IsPedRagdoll = function(h) local e = Ent(h); return e ~= nil and e.ragdoll == true end
_G.NetworkGetEntityOwner = function() return -1 end
_G.GetPlayerRoutingBucket = function(src) local p = H.players[tonumber(src)]; return p and p.bucket or 0 end
_G.GetSelectedPedWeapon = function(ped)
    local p = H.players[math.floor((ped or 0) / 100)]
    return p and p.weapon or joaat('WEAPON_PISTOL')
end
_G.WasEventCanceled = function() return false end
-- a player's ped sits in its vehicle (H.players[src].vehicle = a vehicle handle)
local playerVehicle = _G.GetVehiclePedIsIn
_G.GetVehiclePedIsIn = function(ped, last)
    local p = H.players[math.floor((ped or 0) / 100)]
    if not Ent(ped) and p then return p.vehicle or 0 end
    return playerVehicle(ped, last)
end
_G.SetPedIntoVehicle = function(ped, veh, seat)
    local pe, ve = Ent(ped), Ent(veh)
    if not pe or not ve then return end
    if pe.vehicle then
        local old = Ent(pe.vehicle)
        if old then for s, occ in pairs(old.seats) do if occ == ped then old.seats[s] = nil end end end
    end
    pe.vehicle = veh
    ve.seats[seat] = ped
    pe.coords = ve.coords
end
-- the cp state bag, every write recorded (the leak spec reads them)
_G.Entity = function(h)
    local b = bags[h]
    if not b then b = {}; bags[h] = b end
    return {
        state = setmetatable({
            set = function(_, k, v)
                b[k] = v
                W.bagWrites[#W.bagWrites + 1] = { h = h, k = k, v = CP.U.deepcopy(v), at = H.clockMs }
            end,
        }, { __index = b }),
    }
end

-- Take a seated person out of the car (what the host does after exit_and_stand).
function W.leaveCar(pedHandle)
    local pe = Ent(pedHandle)
    if not pe or not pe.vehicle then return end
    local ve = Ent(pe.vehicle)
    if ve then for s, occ in pairs(ve.seats) do if occ == pedHandle then ve.seats[s] = nil end end end
    pe.vehicle = nil
end

-- ============================================================================
--                            OTHER MODULES (stubs)
-- ============================================================================

W.cids = { [1] = 'CUS1', [2] = 'CUS2', [3] = 'CUS3', [4] = 'CUS4' }
W.offDuty = {}
W.arena = {}
W.downed = {}
W.owned = {}

CP.Alerts = {
    set = function() end,
    clear = function() end,
    forget = function() end,
    inArena = function(src) return W.arena[tonumber(src)] == true end,
    foreignClearedAt = {},
}
CP.Route = {
    begin = function() end,
    stop = function() end,
    status = function() return { status = 'arrived', distance = 0 } end,
}
CP.Draw = {
    reserve = function() return true end,
    release = function() return true end,
    recordLast = function() end,
}
CP.Events = {
    rollModifier = function() return nil end,
    typeOfTheDay = function() return nil end,
}
CP.Payouts = {
    baseFor = function() return 250 end,
}
CP.Cash = {
    compute = function() return 0, { B = 0, mTier = 1.0, mMod = 1.0, amount = 0 } end,
    earnedThisWeek = function() return 0 end,
}
CP.Leaderboard = { invalidate = function() end }
CP.Challenge = {
    currentSeason = function() return nil end,
}
CP.AntiCheat = {
    checkEvent = function() return true end,
    flag = function(run, src, reason, detail)
        W.flags[#W.flags + 1] = { src = src, reason = reason, detail = detail }
        run.flagged = { reason = reason, detail = detail }
    end,
    presenceOk = function() return true end,
    presenceShare = function() return 1.0 end,
    onNpcKilled = function() end,
}
CP.Units = {
    unitOf = function() return nil end,
    unlock = function() end,
}
CP.Tablet = {
    notify = function(src, kind, key, vars)
        W.notes[#W.notes + 1] = { src = src, kind = kind, key = key, vars = vars }
    end,
    push = function(src, topic, data)
        W.pushes[#W.pushes + 1] = { src = src, topic = topic, data = data, at = H.clockMs }
    end,
}
CP.Access = {
    recheck = function() return true end,
    onLost = function() end,
    departmentForJob = function(job) return job end,
    getOfficer = function(src)
        if W.offDuty[tonumber(src)] then return nil, 'err.not_on_duty' end
        return { src = src }
    end,
}
CP.Admin = {
    audit = function(...) W.audits[#W.audits + 1] = { ... } end,
}
CP.Qbx = {
    getInfo = function(src)
        local cid = W.cids[src]
        if not cid then return nil end
        return { src = src, citizenid = cid, name = 'Officer ' .. src, job = { name = 'sast', onduty = true } }
    end,
    getByCitizenId = function(cid)
        for src, c in pairs(W.cids) do if c == cid then return src end end
        return nil
    end,
    isDowned = function(src) return W.downed[tonumber(src)] == true end,
    plateOwned = function(plate) return W.owned[plate] == true end,
    onPlayerUnload = function() end,
    onPlayerLoaded = function() end,
    onDutyChange = function() end,
    onJobChange = function() end,
    getOnlinePlayers = function() return { 1, 2, 3, 4 } end,
}
CP.Schedule = {
    now = function() return os.time() end,
    dayStart = function(ts)
        local t = os.date('*t', ts or os.time())
        return os.time({ year = t.year, month = t.month, day = t.day, hour = 0 })
    end,
}
CP.Missions = {
    get = function() return nil end,
    all = function() return {} end,
}

-- The road point a driving client answers (lib.callback.await on the server): W.roadPoint(src, args) or nil.
W.roadAsks = {}
lib.callback.await = function(name, src, args)
    W.roadAsks[#W.roadAsks + 1] = { name = name, src = src, args = args }
    if W.roadPoint then return W.roadPoint(src, args) end
    return nil
end

H.sql('DELETE FROM cp_mission_runs')
H.sql('DELETE FROM cp_officers')
H.time = tonumber(H.sql('SELECT UNIX_TIMESTAMP(NOW()) AS t')[1].t)

H.load('modules/scaling/server.lua')
H.load('modules/scoring/server.lua')
H.load('modules/npc/server.lua')
H.load('modules/runs/server.lua')
H.load('modules/custody/server.lua')
H.load('modules/integrations/sc_police/server.lua')
H.load('blocks/field_contact/server.lua')
H.load('blocks/process_scene/server.lua')
W.Runs, W.Custody, W.Npc = CP.Runs, CP.Custody, CP.Npc
H.step(0)

-- ============================================================================
--                       A STUB PURSUIT (stop mode input)
-- ============================================================================
-- Objective 'stub_pursuit' spawns one car with occupants, writes run.shared.contacts, adopts everything to the
-- next objective and completes: what pursuit with handoff = 'contact' does.

W.stub = {}
CP.Blocks.register('stub_pursuit', {
    start = function(ctx)
        local o = ctx.obj
        local _, car = ctx.spawnVehicle(
            { model = 'sultan', coords = o.at or vec4(200.0, 200.0, 30.0, 0.0), role = 'suspect_car' })
        local occ = {}
        for i = 1, (o.occupants or 1) do
            local _, ped = ctx.spawnPed({
                model = 'a_m_y_stbla_01',
                coords = o.at or vec4(200.0, 200.0, 30.0, 0.0),
                role = 'suspect',
                hidden = true,
                armed = false,
            })
            local seat = i == 1 and -1 or (i - 2)
            SetPedIntoVehicle(ctx.run.entities[ped].entity, ctx.run.entities[car].entity, seat)
            occ[#occ + 1] = { netId = ped, seat = seat, truth = o.truths and o.truths[i] or nil }
        end
        ctx.run.shared.contacts = ctx.run.shared.contacts or {}
        ctx.run.shared.contacts[#ctx.run.shared.contacts + 1] = {
            vehicle = car,
            occupants = occ,
            observed = o.observed,
            forced = o.forced == true,
            truth = o.carTruth,
        }
        W.stub[#W.stub + 1] = { car = car, occupants = occ }
        local ids = { car }
        for _, x in ipairs(occ) do ids[#ids + 1] = x.netId end
        CP.Runs.adoptMany(ctx.run, ids, ctx.index + 1)
        ctx.complete()
    end,
})

-- An objective that holds the run open (a later objective, so field_contact's end does not end the run).
CP.Blocks.register('stub_hold', {
    start = function(ctx) W.held = ctx end,
    onEntityDead = function() end,
})

-- Spawns hostiles the test kills (process_scene input).
CP.Blocks.register('stub_hostiles', {
    start = function(ctx)
        W.hostiles = {}
        for i = 1, (ctx.obj.count or 2) do
            local _, n = ctx.spawnPed({
                model = 'g_m_y_lost_01',
                coords = vec4(300.0 + i, 300.0, 30.0, 0.0),
                role = ctx.obj.role or 'hostile',
                armed = true,
                weapon = 'WEAPON_PISTOL',
            })
            W.hostiles[#W.hostiles + 1] = n
        end
        W.hostileCtx = ctx
    end,
    onEntityDead = function() end,
})

-- ============================================================================
--                                   HELPERS
-- ============================================================================

function W.officer(src)
    return {
        src = src,
        citizenid = W.cids[src],
        name = 'Officer ' .. src,
        department = 'sast',
        departmentShort = 'SAST',
        job = 'sast',
        rank = 'Trooper',
    }
end

function W.place(src, x, y, z)
    H.players[src] = H.players[src] or {}
    H.players[src].coords = vec3(x + 0.0, y + 0.0, (z or 30.0) + 0.0)
end

function W.mission(objectives, location, extra)
    local loc = location or {}
    loc.label = loc.label or 'L1'
    loc.start = loc.start or { coords = vec3(100.0, 100.0, 30.0), radius = 30.0 }
    local m = {
        id = 'cus_mission',
        label = 'Custody Mission',
        description = '',
        type = 'patrol',
        departments = {},
        minOfficers = 1,
        maxOfficers = 4,
        difficulty = 1,
        timeLimit = 900,
        startTimeout = 600,
        cooldown = 600,
        locations = { loc },
        objectives = objectives,
        bonuses = {},
        penalties = {},
        scaling = {},
        items = {},
        source = 'builtin',
    }
    for k, v in pairs(extra or {}) do m[k] = v end
    return m
end

-- opts.seed fixes the hidden rolls (default 424242: specs never depend on a random seed); opts.test = a test
-- run ({ forcedTier = 'heavy' }).
function W.start(members, mission, opts)
    opts = opts or {}
    local list = {}
    for _, src in ipairs(members) do list[#list + 1] = W.officer(src) end
    local run, err = CP.Runs.create({
        mission = mission,
        locationIndex = 1,
        missionType = mission.type,
        members = list,
        leaderSrc = members[1],
        test = opts.test,
    })
    assert(run, tostring(err))
    run.seed = opts.seed or 424242
    for _, src in ipairs(members) do CP.Runs.markArrived(run, src) end
    H.step(0)
    return run
end

function W.ended(run) return run.state == 'ended' end

-- Coordinates of a run entity.
function W.at(run, netId)
    local e = run.entities[netId]
    local m = e and Ent(e.entity)
    return m and m.coords or nil
end

function W.model(run, netId)
    local e = run.entities[netId]
    return e and Ent(e.entity)
end

-- Stand src next to the entity (offset metres along x).
function W.near(src, run, netId, off)
    local c = W.at(run, netId)
    W.place(src, c.x + (off or 1.0), c.y, c.z)
end

local reqN = 0
local lastEventAt = {}

-- The 4-per-2-s limit of the custody event: keep calls of one player apart.
local function Space(src)
    local t = lastEventAt[src]
    if t and H.clockMs - t < 600 then H.advance(600 - (H.clockMs - t)) end
end

function W.begin(src, run, netId, action, extra)
    Space(src)
    H.fire('crimson-police:server:custody', src, run.id, netId, action, 'begin', extra)
    lastEventAt[src] = H.clockMs
end

function W.finish(src, run, netId, action, extra)
    Space(src)
    H.fire('crimson-police:server:custody', src, run.id, netId, action, 'finish', extra)
    lastEventAt[src] = H.clockMs
end

-- A full action: begin, the progress bar's time (seconds), finish.
function W.act(src, run, netId, action, extra, seconds)
    local t = seconds
    if t == nil then
        local key = action == 'runPlateFromVehicle' and 'runPlate' or action
        t = tonumber(Config.Custody.times[key]) or 0
    end
    W.begin(src, run, netId, action, extra)
    H.advance(math.floor(t * 1000) + 100, 100)
    W.finish(src, run, netId, action, extra)
end

-- server:contactDecide from the tablet: returns ok, data.
function W.decide(src, run, netId, choice, opts)
    opts = opts or {}
    reqN = reqN + 1
    local id = 'cq' .. reqN
    H.advance(400)
    H.fire('crimson-police:server:contactDecide', src,
        { runId = run.id, netId = netId, choice = choice, offence = opts.offence, confirmed = opts.confirmed }, id)
    for _, e in ipairs(H.findEvents('crimson-police:client:actionResult')) do
        if e.args[1] == id then return e.args[2], e.args[3] end
    end
    return nil
end

function W.lastNote(src)
    for i = #W.notes, 1, -1 do if W.notes[i].src == src then return W.notes[i] end end
    return nil
end

function W.rows(runId)
    return H.sql('SELECT * FROM cp_mission_runs WHERE run_uuid = ? ORDER BY citizenid', { runId })
end

function W.row(runId, cid)
    for _, r in ipairs(W.rows(runId)) do if r.citizenid == cid then return r end end
    return nil
end

function W.count(list, pred)
    local n = 0
    for _, v in ipairs(list) do if pred(v) then n = n + 1 end end
    return n
end

function W.contains(s, needle) return type(s) == 'string' and s:find(needle, 1, true) ~= nil end

-- Contacts of the run's current objective, by label.
function W.byLabel(run, label)
    for _, c in ipairs(CP.Custody.contactsOf(run)) do if c.label == label then return c end end
    return nil
end

function W.people(run, obj)
    local out = {}
    for _, c in ipairs(CP.Custody.contactsOf(run, obj)) do if c.kind == 'person' then out[#out + 1] = c end end
    return out
end

function W.cars(run, obj)
    local out = {}
    for _, c in ipairs(CP.Custody.contactsOf(run, obj)) do if c.kind == 'vehicle' then out[#out + 1] = c end end
    return out
end

-- Seconds of ticks (the engine, CP.Npc and CP.Custody loops run each second).
function W.tick(seconds) H.advance(math.floor((seconds or 1) * 1000), 250) end

return W

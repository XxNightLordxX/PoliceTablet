-- Full workflow testing, (the owner: "do a full workflow testing of everything"): every workflow the other

-- Full workflow testing (the owner: "do a full workflow testing of everything"): every workflow the other
-- end-to-end specs leave out, driven start to finish on the REAL server side of Crimson-Police (every server file
-- loaded as in game, database off: the saves folder, as shipped), every switch on through the Admin UI's own Settings,
-- and a `restart Crimson-Police` and a player drop and reconnect in the middle. docs/dev/WORKFLOWS.md lists every workflow
-- with the spec that drives it. Only the other resources and the natives are stubs.

local H = dofile('tests/harness.lua')
H.useFiles()
H.db = (os.getenv('CP_TEST_DB') or 'cp_test') .. '_wf_full'
H.resetSaves()
local cjson = require('cjson')
local U, Runs

-- ============================================================================
--                                   CONSOLE
-- ============================================================================

local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    if os.getenv('E2E_VERBOSE') then realPrint(line) return end
    if line:find('crimson%-police') or line:find('Crimson%-Police') then return end
    realPrint(line)
end

-- ============================================================================
--                     NATIVES (OneSync entities, players)
-- ============================================================================
-- H.boot puts its own natives back on every start, so Natives() runs after each boot.

local ents, nextHandle, nextNet = {}, 9000, 20000
local offline = {}        -- src -> true while that player is disconnected
local netToEnt = {}
local bags = {}
local invoking = nil      -- the resource that calls an export or sends an event (Crimson-Contracts)
local function NewEnt(kind, model, x, y, z, h)
    nextHandle, nextNet = nextHandle + 1, nextNet + 1
    ents[nextHandle] = {
        kind = kind,
        model = model,
        coords = vec3(x + 0.0, y + 0.0, z + 0.0),
        heading = h or 0.0,
        exists = true,
        health = kind == 'ped' and 200 or 1000,
        net = nextNet,
        type = kind == 'ped' and 1 or (kind == 'vehicle' and 2 or 3),
    }
    netToEnt[nextNet] = nextHandle
    return nextHandle
end

-- The Mission Builder's files go to this spec's own resource folder (H.resourcePath(), where GetResourcePath points),
-- never into the repository's missions/custom/.
local function OwnFile(path) return type(path) == 'string' and path:find('^missions/custom/') ~= nil end
local function Natives()
    local realSave, realLoad = _G.SaveResourceFile, _G.LoadResourceFile
    _G.SaveResourceFile = function(res, path, data, n)
        if not OwnFile(path) then return realSave(res, path, data, n) end
        local f = io.open(H.resourcePath() .. '/' .. path, 'w')
        if not f then return false end
        f:write(data)
        f:close()
        return true
    end
    _G.LoadResourceFile = function(res, path)
        if not OwnFile(path) then return realLoad(res, path) end
        local f = io.open(H.resourcePath() .. '/' .. path, 'r')
        if not f then return nil end
        local s = f:read('a')
        f:close()
        return s
    end
    _G.CreatePed = function(_, model, x, y, z, h) return NewEnt('ped', model, x, y, z, h) end
    _G.CreateVehicleServerSetter = function(model, _, x, y, z, h) return NewEnt('vehicle', model, x, y, z, h) end
    _G.CreateVehicle = function(model, x, y, z, h) return NewEnt('vehicle', model, x, y, z, h) end
    _G.CreateObjectNoOffset = function(model, x, y, z) return NewEnt('object', model, x, y, z) end
    _G.DoesEntityExist = function(e)
        if ents[e] then return ents[e].exists end
        return (tonumber(e) or 0) > 0
    end
    _G.DeleteEntity = function(e) if ents[e] then ents[e].exists = false end end
    _G.NetworkGetNetworkIdFromEntity = function(e) return ents[e] and ents[e].net or 0 end
    _G.NetworkGetEntityFromNetworkId = function(n) return netToEnt[n] or 0 end
    _G.NetworkGetEntityOwner = function() return 0 end
    _G.GiveWeaponToPed = function() end
    _G.SetPedArmour = function() end
    _G.GetPedArmour = function() return 0 end
    _G.GetEntityHealth = function(e) return ents[e] and ents[e].health or 200 end
    _G.GetEntityMaxHealth = function() return 200 end
    _G.GetPedMaxHealth = _G.GetEntityMaxHealth
    _G.GetEntityModel = function(e)
        local m = ents[e] and ents[e].model
        if type(m) == 'number' then return m end
        return m and joaat(m) or 0
    end
    _G.GetVehicleEngineHealth = function() return 1000.0 end
    _G.GetVehicleBodyHealth = function() return 1000.0 end
    _G.GetVehiclePetrolTankHealth = function() return 1000.0 end
    _G.GetEntityType = function(e)
        if ents[e] then return ents[e].type end
        local n = tonumber(e) or 0
        if n > 0 and n % 100 == 0 and H.players[n // 100] then return 1 end
        return 0
    end
    _G.IsPedAPlayer = function(e) return ents[e] == nil end
    _G.GetPedSourceOfDeath = function(e) return ents[e] and ents[e].killer or 0 end
    _G.GetPedSourceOfDamage = function() return 0 end
    _G.GetPedCauseOfDeath = function() return 0 end
    _G.GetSelectedPedWeapon = function() return 0 end
    _G.GetVehiclePedIsIn = function(ped)
        local p = H.players[math.floor((tonumber(ped) or 0) / 100)]
        return p and p.vehicle or 0
    end
    _G.GetPedInVehicleSeat = function(veh, seat)
        local e = ents[veh]
        if seat == -1 and e and e.driver then return e.driver * 100 end
        return 0
    end
    _G.SetEntityHeading = function(e, h) if ents[e] then ents[e].heading = h end end
    _G.GetEntityHeading = function(e) return ents[e] and ents[e].heading or 0.0 end
    _G.SetEntityCoords = function(e, x, y, z) if ents[e] then ents[e].coords = vec3(x, y, z) end end
    _G.FreezeEntityPosition = function() end
    _G.SetVehicleNumberPlateText = function() end
    _G.SetVehicleDoorsLocked = function() end
    _G.SetPedIntoVehicle = function() end
    _G.GetEntitySpeed = function() return 0.0 end
    _G.GetPlayerRoutingBucket = function() return 0 end
    _G.GetPlayerLastMsg = function() return 0 end
    _G.GetConvar = function(_, default) return default end
    _G.PerformHttpRequest = function() end
    _G.TriggerLatentClientEvent = function(name, target, _, ...) TriggerClientEvent(name, target, ...) end
    _G.AddStateBagChangeHandler = function() end
    local playerCoords = _G.GetEntityCoords
    _G.GetEntityCoords = function(e)
        if ents[e] then return ents[e].coords end
        return playerCoords(e)
    end
    _G.Entity = function(e)
        local b = bags[e]
        if not b then b = {}; bags[e] = b end
        return {
            state = setmetatable({
                set = function(_, k, v) b[k] = v end,
            }, { __index = b }),
        }
    end
    _G.GetPlayers = function()
        local out = {}
        for src in pairs(H.players) do if not offline[src] then out[#out + 1] = tostring(src) end end
        table.sort(out)
        return out
    end
    _G.GetInvokingResource = function() return invoking end
    _G.GetPlayerIdentifiers = function(src) return { 'license:' .. tostring(src) } end
    _G.GetPlayerTokens = function() return {} end
    _G.GetPlayerEndpoint = function(src) return '10.0.0.' .. tostring(src) end
    local realState = _G.GetResourceState
    _G.GetResourceState = function(name)
        if name == 'ox_inventory' then return 'started' end
        return realState and realState(name) or 'missing'
    end
end

-- ============================================================================
--                       EXPORTS OF THE OUTSIDE RESOURCES
-- ============================================================================
-- H.exportsMock outlives a restart, as the other resources do.

local PD = {}           -- src -> Qbox PlayerData
local addMoney = {}     -- { citizenid, account, amount, reason }
local addItem = {}      -- { src, item, count }
local function AddPlayer(src, cid, first, last, job, grade, admin)
    PD[src] = {
        source = src,
        citizenid = cid,
        license = 'license:' .. cid:lower(),
        charinfo = { firstname = first, lastname = last },
        job = {
            name = job,
            label = job,
            type = (job == 'sast' or job == 'fib') and 'leo' or 'none',
            onduty = job ~= 'unemployed',
            grade = { level = grade, name = grade >= 3 and 'Sergeant' or 'Trooper' },
        },
        metadata = { callsign = 'C-' .. src, isdead = false, inlaststand = false, ishandcuffed = false, injail = 0 },
    }
    H.players[src] = {
        coords = nil,                -- the boot puts a vec3 here (vec3 comes with H.boot)
        ace = {},
        state = {},
        identifiers = { 'license:' .. cid:lower(), 'discord:' .. src },
    }
    if admin then H.players[src].admin = true end
end
local function QbxPlayer(src)
    local pd = PD[tonumber(src)]
    if not pd or offline[tonumber(src)] then return nil end
    return {
        PlayerData = pd,
        Functions = {
            AddMoney = function(account, amount, reason)
                addMoney[#addMoney + 1] = {
                    citizenid = pd.citizenid,
                    account = account,
                    amount = amount,
                    reason = reason,
                }
                return true
            end,
        },
    }
end
H.exportsMock.qbx_core = {
    GetPlayer = function(src) return QbxPlayer(src) end,
    GetPlayerByCitizenId = function(cid)
        for src, pd in pairs(PD) do if pd.citizenid == cid and not offline[src] then return QbxPlayer(src) end end
        return nil
    end,
    GetQBPlayers = function()
        local out = {}
        for src in pairs(PD) do if not offline[src] then out[src] = QbxPlayer(src) end end
        return out
    end,
    GetJobs = function()
        local grades = { [0] = { name = 'Cadet' }, [1] = { name = 'Trooper' }, [3] = { name = 'Sergeant' } }
        return {
            sast = { label = 'SAST', type = 'leo', grades = grades },
            fib = { label = 'FIB', type = 'leo', grades = grades },
            unemployed = { label = 'Civilian', grades = { [0] = { name = 'Freelancer' } } },
        }
    end,
}
H.exportsMock['sc-dispatch'] = {
    IsPlayerSuspended = function() return false end,
    ClearNotification = function() return true end,
}
H.exportsMock['sc-ambulance'] = {
    GetDoctorCount = function() return 0 end,
}
H.exportsMock['Renewed-Banking'] = {
    handleTransaction = function() return {} end,
    removeAccountMoney = function() return true end,
    getAccountMoney = function() return 100000 end,
    addAccountMoney = function() return true end,
}
local ITEMS = { water = { name = 'water', label = 'Water', weight = 500 } }
H.exportsMock.ox_inventory = {
    Items = function(name)
        if name == nil then return ITEMS end
        return ITEMS[name]
    end,
    CanCarryItem = function() return true end,
    AddItem = function(src, item, count)
        addItem[#addItem + 1] = { src = src, item = item, count = count }
        return true
    end,
    Search = function() return {} end,
    RemoveItem = function() return true end,
}
H.exportsMock.ox_target = {}

-- ============================================================================
--                                   PLAYERS
-- ============================================================================

AddPlayer(1, 'WFFULOF1', 'Ada', 'Trooper', 'sast', 1)     -- the solo officer
AddPlayer(2, 'WFFULOF2', 'Ben', 'Agent', 'fib', 1)        -- a FIB agent
AddPlayer(3, 'WFFULSU3', 'Sam', 'Sarge', 'sast', 3)       -- the SAST supervisor
AddPlayer(4, 'WFFULSU4', 'Fay', 'Chief', 'fib', 3)        -- the FIB supervisor
AddPlayer(5, 'WFFULAD5', 'Ann', 'Admin', 'unemployed', 0, true)
AddPlayer(6, 'WFFULOF6', 'Cleo', 'Trooper', 'sast', 1)    -- a unit partner
AddPlayer(7, 'WFFULOF7', 'Dan', 'Trooper', 'sast', 1)     -- the officer given an extra grant
local CID = {}
for src, pd in pairs(PD) do CID[src] = pd.citizenid end

-- ============================================================================
--               TIME: GetGameTimer and os.time advance together
-- ============================================================================

local function Adv(ms, stepMs)
    stepMs = stepMs or 250
    local target = H.clockMs + ms
    while H.clockMs < target do
        local before = H.clockMs
        H.step(stepMs)
        if (before // 1000) ~= (H.clockMs // 1000) then H.time = H.time + 1 end
    end
end
local function Secs(n) Adv(n * 1000, 500) end

-- ============================================================================
--                    START (AND RESTART) THE REAL RESOURCE
-- ============================================================================

local loadedFiles = {}
do
    local p = io.popen(
        'cd ' .. H.root .. ' && find modules -name server.lua | sort'
            .. ' && ls modules/progression/*.lua modules/supervisor/*.lua modules/review/*.lua modules/realplayers/*.lua'
            .. ' && find blocks -name server.lua | sort'
    )
    for file in p:lines() do loadedFiles[#loadedFiles + 1] = file end
    p:close()
end

local autoReady = true        -- every unit member answers Ready at once (false: the spec answers for them)
local function Boot()
    H.boot({ side = 'server', realLocale = true })
    Natives()
    for _, p in pairs(H.players) do
        if p.admin then p.ace[Config.AdminAce] = true end
        p.coords = p.coords or vec3(0.0, 0.0, 0.0)
    end
    local realCreate = _G.CreateThread
    local deferred = {}
    _G.CreateThread = function(fn) deferred[#deferred + 1] = fn end
    _G.Citizen.CreateThread = _G.CreateThread
    for _, file in ipairs(loadedFiles) do H.load(file) end
    _G.CreateThread = realCreate
    _G.Citizen.CreateThread = realCreate
    for _, fn in ipairs(deferred) do realCreate(fn) end
    H.step(0)
    for _ = 1, 3 do H.step(1000) end
    U, Runs = CP.U, CP.Runs
    Config.Events.modifierChance = 0     -- no random twist: every pay below is exact
    local realCheck = CP.Units.readyCheck
    CP.Units.readyCheck = function(unit, typeKey, onReady, onCancel)
        local started = realCheck(unit, typeKey, onReady, onCancel)
        if started and autoReady then
            for _, m in ipairs(U.copy(unit.members)) do
                if m ~= unit.leader then H.fire('crimson-police:server:unitReady', m, { accepted = true }) end
            end
        end
        return started
    end
end

-- `restart Crimson-Police`: its onResourceStop handlers run, then every handler, thread and module table is gone and
-- the resource starts again from the same saves folder. The players stay online, the other resources keep running.
local function Restart()
    Secs(2)                                  -- the writes in their threads finish first
    TriggerEvent('onResourceStop', 'Crimson-Police')
    H.restart()
    Boot()
    Secs(5)
end

-- A player quits (FXServer's playerDropped) and later joins again with the same character (Qbox's player loaded).
local function Drop(src)
    offline[src] = true
    H.fire('playerDropped', src, 'Exiting')
    Secs(2)
end
local function Reconnect(src)
    offline[src] = nil
    TriggerEvent('QBCore:Server:PlayerLoaded', QbxPlayer(src))
    Secs(2)
end

Boot()
H.time = os.time({ year = 2026, month = 9, day = 25, hour = 14, min = 0, sec = 0 })   -- a Friday: Weekly Boss day
H.ok(#loadedFiles >= 40, 'every server file loaded (' .. #loadedFiles .. ')')
-- ============================================================================

local function Place(src, c) H.players[src].coords = vec3(c.x + 0.0, c.y + 0.0, c.z + 0.0) end
local reqN = 0
local function Act(name, src, payload, tries)
    reqN = reqN + 1
    local id = 'wffull' .. reqN
    Adv(1600)
    local mark = #H.events
    H.fire('crimson-police:' .. name, src, payload, id)
    for _ = 1, tries or 40 do
        for i = #H.events, mark + 1, -1 do
            local e = H.events[i]
            if e.name == 'crimson-police:client:actionResult' and e.args[1] == id then return e.args[2], e.args[3] end
        end
        Adv(250)
    end
    return nil, 'no reply'
end
local function Cb(name, src, args)
    Adv(1100)
    local res = H.callback('crimson-police:' .. name, src, args)
    if type(res) ~= 'table' then return nil, 'no reply' end
    if not res.ok then return nil, res.error end
    return res.data
end
local function ClientEvents(name, target, since)
    local out = {}
    for i = (since or 0) + 1, #H.events do
        local e = H.events[i]
        if e.kind == 'client' and e.name == name and (target == nil or e.target == target) then out[#out + 1] = e end
    end
    return out
end
local function LocalEvents(name, since)
    local out = {}
    for i = (since or 0) + 1, #H.events do
        local e = H.events[i]
        if e.kind == 'local' and e.name == name then out[#out + 1] = e.args[1] end
    end
    return out
end
-- The tablet toasts (CP.Tablet.notify) src got since mark, by locale key.
local function Toasts(src, since)
    local out = {}
    for i = (since or 0) + 1, #H.events do
        local e = H.events[i]
        if e.kind == 'client' and e.target == src then
            for _, a in ipairs(e.args) do
                if type(a) == 'string' and a:find('^[%a_]+%.[%w_.]+$') then out[a] = true end
                if type(a) == 'table' and type(a.key) == 'string' then out[a.key] = true end
            end
        end
    end
    return out
end
local function Rows(where, params)
    return H.sql(
        'SELECT id, run_uuid, citizenid, mission_type, mission_id, state, final_points, cash_paid, cash_status, '
            .. 'flagged, voided, live_catches, breakdown FROM cp_mission_runs WHERE ' .. where .. ' ORDER BY id',
        params
    )
end
local function Paid(cid)
    local n, amount = 0, 0
    for _, m in ipairs(addMoney) do
        if m.citizenid == cid then n, amount = n + 1, amount + m.amount end
    end
    return n, amount
end
local function ItemsGiven(src, item)
    local n = 0
    for _, a in ipairs(addItem) do if a.src == src and a.item == item then n = n + a.count end end
    return n
end
local function Setting(path, value)
    return Act('server:admin:setSetting', 5, { path = path, json = cjson.encode(value), reason = 'WF1' })
end
local function Bit(v) return v == true or tonumber(v) == 1 end

local function Xp(cid)
    return tonumber((H.sql('SELECT xp FROM cp_officers WHERE citizenid = ?', { cid })[1] or {}).xp) or 0
end
local function Count(sql, params) return tonumber((H.sql(sql, params)[1] or {}).n) or 0 end
-- The Supervisor UI's request id of a screen action that must never run twice (opts.requestId).
local function RequestId() return ('%08x-0000-4000-8000-%012x'):format(reqN + 1, 91) end

local function FormUnit(leader, member)
    local ok, data = Act('server:unitInvite', leader, member)
    H.eq(ok, true, ('unit: %s invites %s: %s'):format(CID[leader], CID[member], tostring(data)))
    ok, data = Act('server:unitRespond', member, { accepted = true, unitId = data and data.unitId })
    H.eq(ok, true, ('unit: %s accepts: %s'):format(CID[member], tostring(data)))
end

local PATROL_OTHERS = { 'business_check', 'street_race_bust', 'parking_patrol', 'traffic_enforcement' }
local TRAINING_OTHERS = { 'pursuit_sim', 'stolen_vehicle_takedown' }
local TACTICAL_OTHERS = {
    'hostage_rescue',
    'bomb_disposal',
    'armored_truck_escort',
    'prison_break',
    'drug_lab_raid',
    'gang_hideout_raid',
}

local function VehicleFor(src, model)
    local c = H.players[src].coords
    local v = NewEnt('vehicle', model or 'police3', c.x, c.y, c.z, 0.0)
    ents[v].driver = src
    H.players[src].vehicle = v
    return v
end
local function Arrive(run, src)
    Place(src, run.location.start.coords)
    Secs(2)
end
local function Objective(src, run, index, ev) H.fire('crimson-police:server:objective', src, run.id, index, ev) end
local function CheckpointEv(k, veh) return { type = 'checkpoint', index = k, netId = ents[veh].net } end
-- A checkpoint run (Beat Patrol, EVOC): arrive, take the wheel; the checkpoints are driven after.
local function TakeWheel(src, run)
    Arrive(run, src)
    local veh = VehicleFor(src)
    H.fire('crimson-police:server:telemetry', src, run.id, 'vehicle', { netId = ents[veh].net })
    return veh
end
local function DriveCheckpoints(src, run, veh, from, to, between)
    local st = run.objectives[1].state
    for k = from or 1, to or #st.points do
        Secs(between or 15)
        Place(src, st.points[k])
        ents[veh].coords = H.players[src].coords
        Secs(10)
        Objective(src, run, 1, CheckpointEv(k, veh))
    end
    Secs(2)
end
local function Accept(src, typeKey, disabled)
    Config.DisabledMissions = disabled or {}
    local ok, data = Act('server:acceptType', src, typeKey)
    H.eq(ok, true, ('%s accepts %s: %s'):format(CID[src], typeKey, tostring(data)))
    return Runs.getBySrc(src)
end
local function ClearHostiles(run, killer)
    local o = run.objectives[1]
    local minS = (o.obj and o.obj.minSeconds or 60) + 2
    local waited = (H.clockMs - (o.startedAtMs or H.clockMs)) / 1000
    if waited < minS then Secs(math.ceil(minS - waited)) end
    local t = 0
    while run.state == 'in_progress' and run.objectiveIndex == 1 and t < 400 do
        for _, e in ipairs(Runs.entitiesFor(run, { obj = 1, kind = 'ped', alive = true })) do
            local x = ents[e.entity]
            if x and x.exists and x.health > 0 then
                x.killer = killer * 100
                x.health = 0
            end
        end
        Secs(3)
        t = t + 3
    end
end
local function WalkTo(src, c)
    local at = H.players[src].coords
    local dx, dy, dz = c.x - at.x, c.y - at.y, c.z - at.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    if dist > 40.0 then Secs(math.ceil(dist / 40.0)) end
    Place(src, c)
end
-- Gang Shootout's objectives 2 and 3 (tests/e2e_spec.lua has the long story of each step).
local function SecureScene(run, src)
    Place(src, run.location.scene)
    Secs(10)
    Objective(src, run, 2, { type = 'interact', point = 1 })
    Secs(2)
    if run.state ~= 'in_progress' or run.objectiveIndex ~= 3 then return end
    for _, b in ipairs(Runs.heldBodies(run)) do
        WalkTo(src, b.coords)
        for _, step in ipairs({ 'tag', 'bag' }) do
            Objective(src, run, 3, { type = step .. '_begin', netId = b.netId })
            Secs(step == 'tag' and 6 or 7)
            Objective(src, run, 3, { type = step, netId = b.netId })
            Secs(1)
        end
    end
    if run.state ~= 'in_progress' or run.objectiveIndex ~= 3 then return end
    WalkTo(src, run.location.scene)
    Objective(src, run, 3, { type = 'release_begin' })
    Secs(9)
    Objective(src, run, 3, { type = 'release' })
    Secs(2)
end
local function RunEnded(src, since)
    local e = ClientEvents('crimson-police:client:runEnded', src, since)[1]
    return e and e.args[4]
end

-- ============================================================================
--                                   1. ADMIN
-- ============================================================================
-- A SETTING, A FEATURE, AN EXTRA GRANT, THE REWARDS, A RESTART.

do
    H.eq(Config.Database.enabled, false, 'shipped: database off (the saves folder)')
    H.eq(Config.Rewards.enabled, false, 'shipped: item rewards off')
    H.eq(Config.Debug, true, 'shipped: Debug on')

    -- Settings → Features lists every switch with the setting it writes; a toggle saves that setting
    local view, why = Cb('admin:getSettings', 5)
    H.ok(type(view) == 'table', 'settings: the admin opens Settings: ' .. tostring(why))
    local feature
    for _, f in ipairs(view and view.features or {}) do if f.path == 'Rewards.enabled' then feature = f end end
    H.ok(feature ~= nil, 'features: item rewards are on the Features tab')
    H.eq(feature and feature.play, 'economy', 'features: ...under Money')
    local ok, err = Act('server:admin:setSetting', 3,
        { path = 'Rewards.enabled', json = 'true', reason = 'not an admin' })
    H.eq(ok, false, 'settings: a supervisor cannot change a setting (' .. tostring(err) .. ')')

    local pool = { chance = 1.0, rolls = 1, pool = { { item = 'water', count = 2, weight = 1, value = 20 } } }
    for _, c in ipairs({
        { 'Rewards.enabled', true },                                               -- a feature toggle
        { 'Rewards.byType', { training = pool, tactical = pool } },                -- the Rewards edit
        { 'Permissions.supervisor.missionControls', true },
        { 'Permissions.grants', { missionCalls = { citizenids = { CID[7] } } } },  -- an extra grant
        { 'Limits.maxCompletionsHour', 12 },                                       -- a plain setting
        { 'Objectives.dailyGoal.goals', { { id = 'any_3', label = 'Complete 3 missions of any type', count = 3 } } },
        { 'Objectives.weeklyGoal.goals', { { id = 'any_15', label = 'Complete 15 missions', count = 15 } } },
    }) do
        ok, err = Setting(c[1], c[2])
        H.eq(ok, true, ('settings: %s saved: %s'):format(c[1], tostring(err)))
    end
    H.eq(Config.Rewards.enabled, true, 'features: item rewards on at once')
    H.eq(Config.Limits.maxCompletionsHour, 12, 'settings: the hourly cap at once')
    ok, err = Act('server:admin:startSeason', 5, { name = 'Season One' })
    H.eq(ok, true, 'season: the admin starts the season the department challenge counts in: ' .. tostring(err))

    -- the extra grant: an officer who is not a supervisor may now create mission calls
    ok, err = Act('server:sup:mcCreate', 6, { type = 'patrol', area = 'south_ls' })
    H.eq(ok, false, 'grant: an officer without the grant cannot create a call (' .. tostring(err) .. ')')
    H.eq(CP.Permissions.can(7, 'missionCalls'), true, 'grant: the granted officer has the power')

    for _, src in ipairs({ 1, 2, 3, 4, 6, 7 }) do
        local session
        session, why = Cb('getSession', src, { ui = 'officer' })
        H.ok(session ~= nil, ('tablet: %s opens the Officer UI: %s'):format(CID[src], tostring(why)))
    end

    -- a restart keeps every change made in game (docs: "A change made in game wins over config.lua")
    Restart()
    H.eq(Config.Rewards.enabled, true, 'restart: item rewards still on')
    H.eq(Config.Rewards.byType.training and Config.Rewards.byType.training.chance, 1.0,
        'restart: the rewards edit kept')
    H.eq(Config.Limits.maxCompletionsHour, 12, 'restart: the hourly cap kept')
    H.eq(CP.Permissions.can(7, 'missionCalls'), true, 'restart: the extra grant kept')
    H.eq(Config.Database.enabled, false, 'restart: still the saves folder')
end

-- ============================================================================
--                                 2. TRAINING
-- ============================================================================
-- (EVOC): A RESTART MID-RUN, THEN THE RUN DONE TO THE PAY.
-- Docs (SPEC, Mission lifecycle): "If the resource stops mid-run, every mission entity and alert flag is removed,
-- and active runs are dropped with no row, no points, no cash and no cooldown."

do
    local src, cid = 1, CID[1]
    Place(src, vec3(-1100.0, -2900.0, 13.9))
    local run = Accept(src, 'training', TRAINING_OTHERS)
    H.eq(run and run.missionId, 'evoc_course', 'training: EVOC drawn')
    H.eq(run and run.cashBase, 350, 'training: the Training pay is locked at accept')
    local veh = TakeWheel(src, run)
    H.eq(run.state, 'in_progress', 'training: in progress')
    DriveCheckpoints(src, run, veh, 1, 2, 2)
    local rows0, money0, xp0 = Count('SELECT COUNT(*) AS n FROM cp_mission_runs'), #addMoney, Xp(cid)
    Restart()
    H.eq(Runs.getBySrc(src), nil, 'restart: the run is dropped')
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_mission_runs'), rows0, 'restart: no row written')
    H.eq(#addMoney, money0, 'restart: nothing paid')
    H.eq(Xp(cid), xp0, 'restart: no points')
    local cd = Runs.cooldowns(cid)
    H.eq(cd.types.training, nil, 'restart: no type cooldown')
    H.eq(cd.missions.evoc_course, nil, 'restart: no mission cooldown')

    -- the same officer takes it again at once and drives it through
    run = Accept(src, 'training', TRAINING_OTHERS)
    H.eq(run and run.missionId, 'evoc_course', 'training: EVOC again after the restart')
    veh = TakeWheel(src, run)
    local mark = #H.events
    DriveCheckpoints(src, run, veh, 1, nil, 2)
    H.eq(run.state, 'ended', 'training: every checkpoint: ended')
    local result = RunEnded(src, mark)
    H.ok(type(result) == 'table', 'training: the result card is sent')
    H.eq(result and result.cash and result.cash.amount, 350, 'training: ...with the $350 pay')
    H.eq(result and result.items and result.items[1] and result.items[1].name, 'water', 'training: ...and the item')
    local r = Rows('run_uuid = ?', { run.id })[1] or {}
    H.eq(r.state, 'completed', 'training: completed row')
    H.eq(r.cash_status, 'paid', 'training: paid')
    H.eq(select(2, Paid(cid)), 350, 'training: one Qbox AddMoney of $350')
    H.eq(Xp(cid), tonumber(r.final_points), 'training: XP = the row points')
    Secs(5)
    H.eq(ItemsGiven(src, 'water'), 2, 'training: ox_inventory got the 2 water')
    Config.DisabledMissions = {}
end

-- ============================================================================
--                       3. A UNIT TAKES THE WEEKLY BOSS
-- ============================================================================
-- READY CHECK, A DROP AND RECONNECT MID-RUN.
-- Docs (SPEC, Mission lifecycle): "Disconnected | disconnected | Failed (partial points, no cash) | Yes [cooldown]";
-- "In a unit, one member leaving does not end the run for the others; it rescales for the team that's left".

do
    local lead, mate = 6, 7
    Place(lead, vec3(1200.0, 1000.0, 100.0))
    Place(mate, vec3(1204.0, 1000.0, 100.0))
    FormUnit(lead, mate)
    local unit = CP.Units.unitOf(lead)
    H.ok(unit ~= nil and #unit.members == 2, 'unit: two members')
    local board = Cb('getMissionTypes', lead)
    H.ok(board and board.boss ~= nil, 'boss: the Weekly Boss card shows on a Friday')

    -- the ready check: the partner answers it himself this time
    autoReady = false
    local mark = #H.events
    local ok, data = Act('server:acceptType', lead, 'weekly_boss')
    H.eq(ok, true, 'boss: the leader accepts the Weekly Boss: ' .. tostring(data))
    H.eq(Runs.getBySrc(lead), nil, 'ready: no run before the partner is Ready')
    H.ok(#ClientEvents('crimson-police:client:readyCheck', mate, mark) > 0, 'ready: the partner is asked')
    H.fire('crimson-police:server:unitReady', mate, { accepted = true })
    Secs(2)
    autoReady = true
    local run = Runs.getBySrc(lead)
    H.eq(run and run.missionId, 'weekly_boss_kingpin', 'boss: the Kingpin is drawn')
    H.eq(Runs.getBySrc(mate), run, 'boss: the partner is on the same run')
    Arrive(run, lead)
    Arrive(run, mate)
    H.eq(run.state, 'in_progress', 'boss: in progress')

    -- the partner's game crashes in the fight
    Drop(mate)
    H.eq(Runs.getBySrc(mate), nil, 'drop: the partner is off the run')
    H.eq(run.state, 'in_progress', 'drop: the run goes on for the leader')
    local rm = Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[mate] })[1] or {}
    H.eq(rm.state, 'failed', 'drop: his row is Failed')
    H.eq(tonumber(rm.cash_paid) or 0, 0, 'drop: ...with no cash')
    Reconnect(mate)
    H.eq(Runs.getBySrc(mate), nil, 'reconnect: he is not put back on the run')
    H.eq(CP.Units.unitOf(mate), nil, 'reconnect: he is no longer in the unit')
    H.ok(Runs.cooldowns(CID[mate]).missions.weekly_boss_kingpin ~= nil, 'reconnect: he has the boss\'s cooldown')
    H.eq(select(2, CP.Events.bossAvailable(mate)), 'err.boss_used', 'reconnect: ...and his weekly attempt is spent')

    Place(lead, run.location.start.coords)
    ClearHostiles(run, lead)
    H.eq(run.objectiveIndex, 2, 'boss: the crew and the Kingpin are down')
    Place(lead, run.location.scene)
    Secs(10)
    mark = #H.events
    Objective(lead, run, 2, { type = 'interact', point = 1 })
    Secs(12)
    H.eq(run.state, 'ended', 'boss: the scene is secured: ended')
    local r = Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[lead] })[1] or {}
    H.eq(r.state, 'completed', 'boss: the leader\'s row is completed')
    H.eq(r.mission_type, 'tactical', 'boss: counted as Tactical')
    H.eq(tonumber(r.cash_paid), Config.Events.weeklyBoss.payout, 'boss: paid the Weekly Boss payout ($2,500)')
    local bd = U.jsonField(r.breakdown) or {}
    H.eq(bd.points and bd.points.P, Config.Events.weeklyBoss.points, 'boss: P = the Weekly Boss points (500)')
    H.eq(bd.payTier, 'standard', 'boss: the pay tier dropped to the one officer left (a disconnect)')
    local result = RunEnded(lead, mark)
    H.eq(result and result.cash and result.cash.amount, 2500, 'boss: the result card shows $2,500')
    H.eq(Xp(CID[lead]), tonumber(r.final_points), 'boss: XP = the row points')

    -- a restart keeps the spent attempts (they are read from the saved rows)
    Restart()
    H.eq(select(2, CP.Events.bossAvailable(lead)), 'err.boss_used', 'restart: the leader\'s attempt stays spent')
    H.eq(select(2, CP.Events.bossAvailable(mate)), 'err.boss_used', 'restart: ...and the partner\'s')
    H.eq(select(1, Act('server:acceptType', lead, 'weekly_boss')), false, 'restart: no second boss this week')
end

-- ============================================================================
--                                  4. A UNIT
-- ============================================================================
-- INVITE, A DECLINED READY CHECK, PROMOTE, KICK, LEAVE, RESTART.
-- Units live in memory: after a restart the officers form their unit again (docs/dev/WORKFLOWS.md).

do
    Place(1, vec3(300.0, -1000.0, 29.0))
    Place(2, vec3(303.0, -1000.0, 29.0))
    Place(6, vec3(306.0, -1000.0, 29.0))
    local ok, data = Act('server:unitInvite', 1, 2)
    H.eq(ok, true, 'unit: SAST invites FIB: ' .. tostring(data))
    ok, data = Act('server:unitRespond', 2, { accepted = false, unitId = data and data.unitId })
    H.eq(ok, true, 'unit: the FIB agent declines: ' .. tostring(data))
    H.eq(CP.Units.unitOf(2), nil, 'unit: ...and is in no unit')
    FormUnit(1, 2)
    FormUnit(1, 6)
    H.eq(#(CP.Units.unitOf(1) or { members = {} }).members, 3, 'unit: three members')

    -- a ready check one member declines: no run, nobody gets a cooldown
    autoReady = false
    ok, data = Act('server:acceptType', 1, 'patrol')
    H.eq(ok, true, 'ready: the leader accepts Patrol: ' .. tostring(data))
    H.fire('crimson-police:server:unitReady', 2, { accepted = true })
    H.fire('crimson-police:server:unitReady', 6, { accepted = false })
    Secs(2)
    autoReady = true
    H.eq(Runs.getBySrc(1), nil, 'ready: one Not ready: no run')
    H.eq(Runs.cooldowns(CID[1]).types.patrol, nil, 'ready: ...and no cooldown')

    ok, data = Act('server:unitPromote', 1, 2)
    H.eq(ok, true, 'unit: the leader hands the lead to the FIB agent: ' .. tostring(data))
    H.eq((CP.Units.unitOf(1) or {}).leader, 2, 'unit: ...who leads now')
    ok, data = Act('server:unitKick', 1, 6)
    H.eq(ok, false, 'unit: a member who no longer leads cannot kick (' .. tostring(data) .. ')')
    ok, data = Act('server:unitKick', 2, 6)
    H.eq(ok, true, 'unit: the new leader removes Cleo: ' .. tostring(data))
    H.eq(CP.Units.unitOf(6), nil, 'unit: ...who is in no unit')

    Restart()
    H.eq(CP.Units.unitOf(1), nil, 'restart: the unit is gone')
    H.eq(CP.Units.unitOf(2), nil, 'restart: ...for both')
    FormUnit(1, 2)
    ok, data = Act('server:unitLeave', 2)
    H.eq(ok, true, 'unit: the FIB agent leaves: ' .. tostring(data))
    H.eq(CP.Units.unitOf(2), nil, 'unit: ...and is in no unit')
    H.eq(CP.Units.unitOf(1), nil, 'unit: a unit of one is no unit')
end

-- ============================================================================
--             5. A CROSS-DEPARTMENT MISSION A SUPERVISOR LAUNCHES
-- ============================================================================
-- WITH A RESTART FIRST.
-- Docs (docs/dev/WORKFLOWS.md): a restart cancels an operation still joining; the launch wait is read back from the saved rows.

do
    local function OpRow(id)
        return H.sql('SELECT status, mission_id FROM cp_operations WHERE id = ?', { id })[1] or {}
    end
    local ok, data = Act('server:sup:opLaunch', 1, { missionId = 'gang_shootout' })
    H.eq(ok, false, 'op: an officer cannot launch (' .. tostring(data) .. ')')
    ok, data = Act('server:sup:opLaunch', 3, { missionId = 'gang_shootout' })
    H.eq(ok, true, 'op: the SAST supervisor launches Gang Shootout: ' .. tostring(data))
    local first = data and data.id
    ok, data = Act('server:joinOperation', 1, first)
    H.eq(ok, true, 'op: a SAST officer joins: ' .. tostring(data))

    Restart()
    H.eq(OpRow(first).status, 'cancelled', 'restart: the joining operation is cancelled')
    H.eq(CP.Operations.active(), nil, 'restart: no operation runs')
    ok, data = Act('server:sup:opLaunch', 3, { missionId = 'gang_shootout' })
    H.eq(data, 'err.op_cooldown', 'restart: the launch wait still counts')
    ok, data = Act('server:admin:opLaunch', 5, { missionId = 'gang_shootout', skipCooldown = true, reason = 'restart' })
    H.eq(ok, true, 'op: an admin launches again inside the wait, with a reason: ' .. tostring(data))
    local opId = data and data.id

    -- a joiner whose game crashes leaves the join list; back online he is not on it
    ok, data = Act('server:joinOperation', 6, opId)
    H.eq(ok, true, 'op: Cleo joins: ' .. tostring(data))
    Drop(6)
    H.eq((CP.Operations.boardCard(1) or {}).joined, 0, 'drop: she left the join list')
    Reconnect(6)
    H.eq((CP.Operations.boardCard(6) or {}).joinedByMe, false, 'reconnect: ...and is not on it again by herself')
    Place(1, vec3(0.0, 0.0, 0.0))
    Place(2, vec3(5.0, 0.0, 0.0))
    for _, src in ipairs({ 1, 2 }) do
        ok, data = Act('server:joinOperation', src, opId)
        H.eq(ok, true, ('op: %s joins: %s'):format(CID[src], tostring(data)))
    end
    ok, data = Act('server:sup:opStart', 3)
    H.eq(ok, false, 'op: only the one who launched it starts it (' .. tostring(data) .. ')')
    ok, data = Act('server:admin:opStart', 5)
    H.eq(ok, true, 'op: the admin taps Start now: ' .. tostring(data))
    local run = Runs.getBySrc(1)
    H.eq(run and run.missionId, 'gang_shootout', 'op: the run is Gang Shootout')
    H.eq(Runs.getBySrc(2), run, 'op: the FIB agent is on it')
    H.eq(OpRow(opId).status, 'running', 'op: running')
    Arrive(run, 1)
    Arrive(run, 2)
    H.eq(run.state, 'in_progress', 'op: in progress')
    Place(1, run.location.start.coords)
    Place(2, run.location.start.coords)
    ClearHostiles(run, 1)
    Place(2, run.location.scene)
    SecureScene(run, 1)
    H.eq(run.state, 'ended', 'op: completed')
    Secs(3)
    local rows = Rows('run_uuid = ?', { run.id })
    H.eq(#rows, 2, 'op: one row per officer')
    for _, r in ipairs(rows) do
        H.eq(r.state, 'completed', r.citizenid .. ': completed')
        local bd = U.jsonField(r.breakdown) or {}
        H.eq(bd.points and bd.points.mCross, Config.CrossDepartmentPoints, r.citizenid .. ': cross-department bonus')
        H.eq(r.cash_status, 'paid', r.citizenid .. ': paid')
    end
    H.eq(OpRow(opId).status, 'completed', 'op: the operation is completed')
end

-- ============================================================================
--                               6. MISSION CALLS
-- ============================================================================
-- THE GRANTED OFFICER CREATES ONE, A CLAIM, A RESTART.

do
    local area
    for _, a in ipairs(Config.MissionCalls.areas) do if a.key == 'south_ls' then area = a end end
    local function CallRow(id)
        return H.sql('SELECT code, status, outcome, claimed_by, run_uuid FROM cp_mission_calls WHERE id = ?', { id })[1]
            or {}
    end
    local function Listed(src, id)
        for _, c in ipairs((CP.MissionCalls.list(src) or {}).calls or {}) do if c.id == id then return true end end
        return false
    end
    Place(7, vec3(area.center.x - 300.0, area.center.y, area.center.z))
    Place(6, vec3(area.center.x + 300.0, area.center.y, area.center.z))
    Place(1, vec3(area.center.x + 310.0, area.center.y, area.center.z))
    Secs(12)
    local ok, data = Act('server:sup:mcCreate', 7, { type = 'patrol', area = 'south_ls' })
    H.eq(ok, true, 'call: the officer with the extra grant creates a Patrol call: ' .. tostring(data))
    local callA = data and data.id
    H.eq(CallRow(callA).status, 'open', 'call: open')
    H.eq(Listed(6, callA), true, 'call: Cleo sees it on Dispatch')

    -- a restart with the call still open
    Restart()
    H.eq(Listed(6, callA), false, 'restart: the open call is gone from Dispatch')
    H.eq(CallRow(callA).status, 'lapsed', 'restart: ...and its row is lapsed, not open for ever')

    Secs(65)
    ok, data = Act('server:sup:mcCreate', 7, { type = 'patrol', area = 'south_ls' })
    H.eq(ok, true, 'call: a new call after the restart: ' .. tostring(data))
    local callB = data and data.id
    Config.DisabledMissions = PATROL_OTHERS
    ok, data = Act('server:claimMissionCall', 6, { callId = callB })
    H.eq(ok, true, 'call: Cleo claims it: ' .. tostring(data))
    local run = Runs.getBySrc(6)
    H.ok(run ~= nil and run.missionCall ~= nil, 'call: the run carries the call')
    H.eq(CallRow(callB).status, 'claimed', 'call: claimed')
    Restart()
    H.eq(Runs.getBySrc(6), nil, 'restart: the call\'s run is dropped')
    H.eq(Listed(1, callB), false, 'restart: the claimed call is gone')
    H.eq(CallRow(callB).status, 'closed', 'restart: its row is closed, not claimed for ever')
    H.eq(CallRow(callB).outcome, 'restart', 'restart: ...ended by the restart')
    H.eq(#Rows('run_uuid = ?', { CallRow(callB).run_uuid }), 0, 'restart: no run row (docs)')
    local hist = CP.MissionCalls.history({ from = os.time() - 3600, to = os.time() + 60 }) or {}
    local open = 0
    for _, c in ipairs(hist.rows or hist.calls or hist) do if c.status == 'open' then open = open + 1 end end
    H.eq(open, 0, 'restart: Dispatch history shows no call open')
    Config.DisabledMissions = {}
end

-- ============================================================================
--    7. HAPPY HOUR, GOALS, THE DEPARTMENT CHALLENGE AND THE TYPE OF THE DAY
-- ============================================================================
-- Docs (SPEC 11.1): happy hour "is a timed row (expires_at), so a restart keeps it"; the Type of the Day pick "is
-- read back from yesterday's last audit row of the control, so a restart keeps it".

local function Evoc(src)
    Place(src, vec3(-1100.0, -2900.0, 13.9))
    local run = Accept(src, 'training', TRAINING_OTHERS)
    if not run then return nil end
    local veh = TakeWheel(src, run)
    DriveCheckpoints(src, run, veh, 1, nil, 2)
    H.eq(run.state, 'ended', ('%s: EVOC driven through'):format(CID[src]))
    Secs(3)
    return Rows('run_uuid = ?', { run.id })[1] or {}
end

do
    local src, cid = 1, CID[1]
    H.time = H.time + 601                          -- EVOC's 10 minute cooldown from section 2 is over
    local goals0 = (Cb('getHome', src) or {}).goals or {}
    local r = Evoc(src)
    H.eq(r.state, 'completed', 'goals: a completed EVOC')
    local goals1 = (Cb('getHome', src) or {}).goals or {}
    H.eq((goals1.daily or {}).progress, ((goals0.daily or {}).progress or 0) + 1, 'goals: the daily goal counts it')
    H.eq((goals1.weekly or {}).progress, ((goals0.weekly or {}).progress or 0) + 1, 'goals: ...and the weekly goal')
    Secs(61)                                       -- the boards' cache (Config.Leaderboard.cacheSeconds)
    local sast
    for _, d in ipairs((Cb('getChallenge', src) or {}).departments or {}) do if d.key == 'sast' then sast = d end end
    H.ok(sast ~= nil and (sast.points or 0) > 0, 'challenge: SAST has points in the season')
    H.ok(sast ~= nil and (sast.completed or 0) > 0, 'challenge: ...from its completed runs')

    -- EVOC is on its 10 minute cooldown now
    Config.DisabledMissions = TRAINING_OTHERS
    local ok, data = Act('server:acceptType', src, 'training')
    H.eq(ok, false, 'happy hour: before it, EVOC is on cooldown (' .. tostring(data) .. ')')
    ok, data = Act('server:sup:setMissionControl', 1,
        { key = 'happyHour', value = { minutes = 10, noRepeat = true }, reason = 'officer', requestId = RequestId() })
    H.eq(ok, false, 'happy hour: an officer cannot start one (' .. tostring(data) .. ')')
    ok, data = Act('server:sup:setMissionControl', 3, {
        key = 'happyHour',
        value = { minutes = 10, noRepeat = true },
        reason = 'Quiet night',
        requestId = RequestId(),
    })
    H.eq(ok, true, 'happy hour: the supervisor starts 10 minutes: ' .. tostring(data))
    H.ok(CP.HappyHour.state(nil) ~= nil, 'happy hour: running')
    Restart()
    local hh = CP.HappyHour.state(nil)
    H.ok(hh ~= nil and hh.minutes == 10, 'restart: the happy hour still runs')
    r = Evoc(src)
    H.eq(r.state, 'completed', 'happy hour: EVOC again at once, no cooldown')
    H.eq(r.cash_status, 'paid', 'happy hour: ...and paid')
    H.time = H.time + 10 * 60
    Secs(35)
    H.eq(CP.HappyHour.state(nil), nil, 'happy hour: over after its 10 minutes')

    -- the Type of the Day: the supervisor picks Training for SAST tomorrow
    local controls = U.copy(Config.MissionControls.controls)
    controls.typeOfTheDay.on = true
    ok, data = Setting('MissionControls.controls', controls)
    H.eq(ok, true, 'tod: the admin switches the Type of the Day control on: ' .. tostring(data))
    ok, data = Act('server:sup:setMissionControl', 3,
        { key = 'typeOfTheDay', value = 'training', reason = 'EVOC week', requestId = RequestId() })
    H.eq(ok, true, 'tod: the SAST supervisor picks Training for tomorrow: ' .. tostring(data))
    local today = CP.Events.typeOfTheDay(nil, 'sast', { citizenid = cid })
    Restart()
    H.eq(CP.Events.typeOfTheDay(nil, 'sast', { citizenid = cid }), today, 'tod: a pick never moves today\'s type')
    H.time = H.time + 24 * 3600
    Secs(5)
    H.eq(CP.Events.typeOfTheDay(nil, 'sast', { citizenid = cid }), 'training', 'tod: the next day SAST has Training')
    H.eq(CP.Events.typeOfTheDay(nil, 'sast', { citizenid = CID[3] }), CP.Events.typeOfTheDay(nil, 'fib', {
        citizenid = CID[2],
    }), 'tod: the supervisor who picked it keeps the server\'s type, as FIB does')
    r = Evoc(src)
    local bd = U.jsonField(r.breakdown) or {}
    H.eq(bd.points and bd.points.tod, true, 'tod: the EVOC row has the Type of the Day multiplier')
    Config.DisabledMissions = {}
end

-- ============================================================================
--                     8. EVERY SUPERVISOR MISSION CONTROL
-- ============================================================================
-- SET, A RESTART, RESET; AN AWARD.
-- Docs (SPEC 11.1): saved controls are read back after a restart; Reset brings back config.lua's value.

do
    local controls = U.copy(Config.MissionControls.controls)
    for _, c in pairs(controls) do c.on = true end
    local ok, data = Setting('MissionControls.controls', controls)
    H.eq(ok, true, 'controls: the admin switches every Mission control on: ' .. tostring(data))
    local view, why = Cb('sup:getMissionControls', 3)
    H.ok(view ~= nil, 'controls: the supervisor opens Mission controls: ' .. tostring(why))
    local sast
    for _, d in ipairs(view and view.departments or {}) do if d.key == 'sast' then sast = d end end
    local set = {}
    for _, c in ipairs(sast and sast.controls or {}) do
        local value
        if c.kind == 'number' and c.bounded then
            value = c.min
            if c.key == 'readyCheck' and value == 0 then value = c.max end
        elseif c.kind == 'choice' and c.key ~= 'typeOfTheDay' then
            value = (c.offered or c.choices or {})[1]
        end
        if value ~= nil and c.serverWide ~= true and (c.waitLeft or 0) == 0 then
            ok, data = Act('server:sup:setMissionControl', 3,
                { key = c.key, value = value, reason = 'WF1 sweep', requestId = RequestId() })
            H.eq(ok, true, ('controls: %s set to %s: %s'):format(c.key, tostring(value), tostring(data)))
            if ok then set[c.key] = value end
        end
    end
    H.ok(next(set) ~= nil, 'controls: the sweep set some controls')
    Restart()
    local seen = {}
    for _, d in ipairs((Cb('sup:getMissionControls', 3) or {}).departments or {}) do
        if d.key == 'sast' then for _, c in ipairs(d.controls or {}) do seen[c.key] = c.saved end end
    end
    for key, value in pairs(set) do
        H.eq(seen[key], value, ('restart: %s keeps %s'):format(key, tostring(value)))
    end
    for key in pairs(set) do
        ok, data = Act('server:sup:resetMissionControl', 3,
            { key = key, reason = 'WF1 sweep done', requestId = RequestId() })
        H.eq(ok, true, ('controls: %s reset: %s'):format(key, tostring(data)))
    end
    local left = 0
    for _, d in ipairs((Cb('sup:getMissionControls', 3) or {}).departments or {}) do
        if d.key == 'sast' then
            for _, c in ipairs(d.controls or {}) do
                if set[c.key] and c.saved ~= nil then
                    left = left + 1
                end
            end
        end
    end
    H.eq(left, 0, 'controls: every reset control is back on config.lua')

    -- the action controls: a mission ban kept by a restart and lifted, a department notice
    ok, data = Act('server:sup:missionBan', 3, { citizenid = CID[1], hours = 1, reason = 'Ignored an order' })
    H.eq(ok, true, 'ban: the supervisor bars the officer from missions for an hour: ' .. tostring(data))
    Config.DisabledMissions = PATROL_OTHERS
    ok, data = Act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.mission_banned', 'ban: the officer cannot take a mission')
    Restart()
    ok, data = Act('server:acceptType', 1, 'patrol')
    H.eq(data, 'err.mission_banned', 'restart: the ban is kept (cp_officers.mission_ban)')
    ok, data = Act('server:sup:liftMissionBan', 3, { citizenid = CID[1], reason = 'Talked it through' })
    H.eq(ok, true, 'ban: the supervisor lifts it: ' .. tostring(data))
    ok, data = Act('server:acceptType', 1, 'patrol')
    H.eq(ok, true, 'ban: the officer takes Patrol again: ' .. tostring(data))
    local run = Runs.getBySrc(1)
    if run then
        ok, data = Act('server:abandon', 1, run.id)
        H.eq(ok, true, 'abandon: the officer abandons it: ' .. tostring(data))
        Secs(2)
        H.ok(Runs.cooldowns(CID[1]).types.patrol ~= nil, 'abandon: ...with the Patrol type cooldown (docs)')
    end
    Config.DisabledMissions = {}
    ok, data = Act('server:notice:post', 3,
        { kind = 'department', text = 'Briefing at 20:00 at Mission Row.', days = 1 })
    H.eq(ok, true, 'notice: the supervisor posts a SAST notice: ' .. tostring(data))
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_staff_notices'), 1, 'notice: saved')
end

-- ============================================================================
--           8B. A SUPERVISOR PUSHES A MISSION, THEN ADDS TIME TO IT
-- ============================================================================
-- Step FX1. THE PAGE WITH A MISSION, THE ACCEPT, "+ MINUTES", EACH REPLY WITH ITS SCREEN'S VIEW; A RESTART.
-- Docs (SPEC Hard rules, Mission choice): a pushed mission is offered only to that unit, which may accept it; README
-- Mission controls: "+ minutes" adds the admin's min to max minutes to a running mission of his department.

do
    for _, src in ipairs({ 1, 6 }) do
        local ok, err = Act('server:admin:clearCooldowns', 5,
            { citizenid = CID[src], scope = 'all', reason = 'FX1 push', requestId = RequestId() })
        H.eq(ok, true, ('push: the admin clears the cooldowns of %s: %s'):format(CID[src], tostring(err)))
    end
    Place(1, vec3(400.0, -980.0, 30.0))
    Place(6, vec3(402.0, -980.0, 30.0))
    FormUnit(1, 6)

    -- the Page dialog offers the missions; the push names one, its reply carries the panel (step FX1)
    local view = Cb('sup:getMissionCalls', 3)
    H.ok(view and view.push and #(view.push.missions or {}) > 0, 'push: the Page dialog lists the missions to push')
    local ok, data = Act('server:sup:mcPage', 3, { type = 'patrol', leaderSrc = 1, missionId = 'traffic_enforcement' })
    H.eq(ok, true, 'push: the supervisor pushes Traffic Enforcement to the unit: ' .. tostring(data))
    local panel = type(data) == 'table' and data.view or nil
    H.ok(type(panel) == 'table' and type(panel.open) == 'table', 'push: the reply carries the panel view (FX1)')
    local listed = false
    for _, c in ipairs(panel and panel.open or {}) do if c.id == data.id then listed = c.pushed == true end end
    H.ok(listed, 'push: ...the pushed call in it')
    local card
    for _, c in ipairs((CP.MissionCalls.list(1) or {}).calls or {}) do if c.id == data.id then card = c end end
    H.ok(card and card.pushed and card.missionLabel ~= nil, 'push: the paged leader sees the mission on Dispatch')
    local other
    for _, c in ipairs((CP.MissionCalls.list(7) or {}).calls or {}) do if c.id == data.id then other = c end end
    H.eq(other, nil, 'push: another officer never sees it')
    ok, data = Act('server:claimMissionCall', 1, { callId = card and card.id })
    H.eq(ok, true, 'push: the unit accepts it: ' .. tostring(data))
    Secs(2)
    local run = Runs.getBySrc(1)
    H.eq(run and run.missionId, 'traffic_enforcement', 'push: the pushed mission, no draw')
    H.eq(Runs.getBySrc(6), run, 'push: the partner is on it')
    H.eq(Count([[SELECT COUNT(*) AS n FROM cp_audit WHERE action = 'mcPush']]), 1, 'push: audited once')

    -- "+ minutes" on the running mission: the run gets the time, the reply carries Live Missions (step FX1)
    if run then
        Arrive(run, 1)
        Arrive(run, 6)
        local live = Cb('sup:getLiveRuns', 3)
        local add = live and live.addTime
        H.ok(add ~= nil and add.min >= 1, 'live: the supervisor is offered "+ minutes"')
        local before = tonumber(run.timeAdded) or 0
        local mark = #H.events
        ok, data = Act('server:sup:addRunTime', 3,
            { runId = run.id, minutes = add and add.min or 1, reason = 'Long drive', requestId = RequestId() })
        H.eq(ok, true, 'live: the supervisor adds minutes: ' .. tostring(data))
        local added = (add and add.min or 1) * 60
        H.eq((tonumber(run.timeAdded) or 0) - before, added, 'live: the run has the minutes')
        local lv = type(data) == 'table' and data.view or nil
        local shown
        for _, r in ipairs(lv and lv.runs or {}) do if r.runId == run.id then shown = r end end
        H.eq(shown and shown.timeAdded, before + added, 'live: the reply carries Live Missions with the time (FX1)')
        H.eq(lv and lv.addTime and lv.addTime.usedToday, (add and add.usedToday or 0) + 1,
            'live: ...and today\'s use counted')
        H.ok(Toasts(1, mark)['sup.notice.time_added'], 'live: the unit is told')
        H.eq(Count([[SELECT COUNT(*) AS n FROM cp_audit WHERE action = 'runTimeAdd']]), 1, 'live: audited once')
        ok, data = Act('server:sup:addRunTime', 7,
            { runId = run.id, minutes = 1, reason = 'Not a supervisor', requestId = RequestId() })
        H.eq(ok, false, 'live: an officer cannot add time (' .. tostring(data) .. ')')

        -- a restart ends the run (no row); the push is not offered again
        Restart()
        H.eq(Runs.getBySrc(1), nil, 'restart: the pushed run is gone')
        local again
        for _, c in ipairs((CP.MissionCalls.list(1) or {}).calls or {}) do if c.pushed then again = c end end
        H.eq(again, nil, 'restart: no pushed call is left on Dispatch')
    end
    CP.Units.remove(1, { reason = 'left', silent = true })
    CP.Units.remove(6, { reason = 'left', silent = true })
end

-- ============================================================================
--                                9. CORRECTIONS
-- ============================================================================
-- GIVE POINTS, VOID A RUN, A RESTART, RESTORE IT.

do
    local cid = CID[1]
    local ok, data = Act('server:admin:adjustPoints', 5,
        { citizenid = cid, points = 25, reason = 'Court appearance', requestId = RequestId() })
    H.eq(ok, true, 'correction: the admin gives 25 points: ' .. tostring(data))
    Secs(3)
    local xp0 = Xp(cid)
    local row = Rows('citizenid = ? AND mission_id = ? AND state = ?', { cid, 'evoc_course', 'completed' })[1] or {}
    H.ok(row.id ~= nil, 'correction: the officer has a completed EVOC row')
    ok, data = Act('server:admin:voidRun', 5, { rowId = row.id, reason = 'Bugged course', kind = 'correction' })
    H.eq(ok, true, 'correction: the admin voids it: ' .. tostring(data))
    Secs(3)
    H.eq(Xp(cid), xp0 - tonumber(row.final_points), 'correction: its points leave the XP')
    Restart()
    H.eq(Bit((Rows('id = ?', { row.id })[1] or {}).voided), true, 'restart: the row stays voided')
    H.eq(Xp(cid), xp0 - tonumber(row.final_points), 'restart: ...and the XP stays down')
    ok, data = Act('server:admin:restoreRun', 5, { rowId = row.id, reason = 'Course was fine' })
    H.eq(ok, true, 'correction: the admin restores it: ' .. tostring(data))
    Secs(3)
    H.eq(Bit((Rows('id = ?', { row.id })[1] or {}).voided), false, 'correction: restored')
    H.eq(Xp(cid), xp0, 'correction: the XP is back')
    H.eq((Rows('id = ?', { row.id })[1] or {}).cash_status, 'paid', 'correction: the paid cash was never taken back')
end

-- ============================================================================
--        10. BACKUP, A PAYMENT, RESTORE; THE LOCK HOLDS UNTIL A RESTART
-- ============================================================================
-- Docs (README System → Backups): a restore needs the typed word RESTORE, then a restart; it never takes money back.

local backupName
do
    local ok, res = Act('server:admin:backupNow', 5, {})
    H.ok(ok == true and type(res) == 'table' and res.name ~= nil, 'backup: the admin makes a backup')
    backupName = res and res.name
    local money0 = #addMoney
    local r = Evoc(6)
    H.eq(r.cash_status, 'paid', 'backup: a run after the backup is paid')
    H.eq(#addMoney, money0 + 1, 'backup: ...once')
    local pv = Cb('admin:previewRestore', 5, { name = backupName })
    H.ok(pv and pv.previewToken, 'restore: the preview')
    ok, res = Act('server:admin:restoreBackup', 5, {
        name = backupName,
        previewToken = pv and pv.previewToken,
        reason = 'WF1',
        confirm = 'RESTORE',
        requestId = RequestId(),
    }, 400)
    H.ok(ok == true and type(res) == 'table' and res.restart == true,
        'restore: done, a restart asked: ' .. tostring(type(res) == 'table' and cjson.encode(res) or res))
    Config.DisabledMissions = PATROL_OTHERS
    H.time = H.time + 301                          -- the officer's Patrol abandon cooldown of section 8 is over
    local okA, why = Act('server:acceptType', 1, 'patrol')
    H.eq(okA, false, 'restore: no new run until the restart (' .. tostring(why) .. ')')
    Restart()
    local after = Rows('run_uuid = ?', { r.run_uuid })[1] or {}
    H.eq(after.cash_status, 'paid', 'restart: the run paid after the backup stays paid (money moves forward only)')
    H.eq(#addMoney, money0 + 1, 'restart: nothing is paid twice')
    okA, why = Act('server:acceptType', 1, 'patrol')
    H.eq(okA, true, 'restart: runs start again: ' .. tostring(why))
    local run = Runs.getBySrc(1)
    if run then Act('server:abandon', 1, run.id) end
    Config.DisabledMissions = {}
end

-- ============================================================================
--                             11. MISSION BUILDER
-- ============================================================================
-- CREATE, A RESTART, TEST, PUBLISH, PLAYED AND PAID.

do
    local sup = 3
    local ok, d = Act('server:builder:duplicate', sup, { id = 'evoc_course', label = 'Night EVOC' })
    H.eq(ok, true, 'builder: the supervisor creates a mission from EVOC: ' .. tostring(d))
    local id = type(d) == 'table' and d.id or nil
    local got = Cb('builder:get', sup, { id = id })
    H.ok(got ~= nil, 'builder: he opens it')
    local def = cjson.decode(cjson.encode(U.serialize(got and got.definition or {})))
    def.description = 'The EVOC course after dark.'
    local okS, s = Act('server:builder:save', sup, { id = id, definition = def })
    H.eq(okS, true, 'builder: the draft is saved: ' .. tostring(s))
    Restart()
    got = Cb('builder:get', sup, { id = id })
    local draft = got and got.definition or {}
    H.eq(draft.description, 'The EVOC course after dark.', 'restart: the saved draft is kept')
    H.eq(CP.Missions.get(id), nil, 'restart: ...and not playable before it is published')

    Place(sup, vec3(-1100.0, -2900.0, 13.9))
    local okT, t = Act('server:builder:test', sup, { id = id, location = 1, useStartRoute = false })
    H.eq(okT, true, 'builder: he starts a test run: ' .. tostring(t))
    local run = Runs.getBySrc(sup)
    H.ok(run ~= nil and run.test ~= nil, 'builder: a test run')
    if run then
        local veh = TakeWheel(sup, run)
        local money0 = #addMoney
        DriveCheckpoints(sup, run, veh, 1, nil, 2)
        H.eq(run.state, 'ended', 'builder: the test run is driven through')
        H.eq(#addMoney, money0, 'builder: a test run pays nothing')
    end
    local okP, p = Act('server:builder:publish', sup, { id = id })
    H.eq(okP, true, 'builder: published: ' .. tostring(p))
    local live = CP.Missions.get(id)
    H.ok(live ~= nil and live.source == 'custom' and live.type == 'training', 'builder: it plays as a Training mission')
    Restart()
    H.ok(CP.Missions.get(id) ~= nil, 'restart: the published mission still plays')

    -- an officer draws it from the board (every other Training mission off) and is paid the Training payout
    local disabled = U.copy(TRAINING_OTHERS)
    disabled[#disabled + 1] = 'evoc_course'
    H.time = H.time + 601
    Place(2, vec3(-1100.0, -2900.0, 13.9))
    local orun = Accept(2, 'training', disabled)
    H.eq(orun and orun.missionId, id, 'builder: the FIB agent draws Night EVOC')
    if orun then
        local veh = TakeWheel(2, orun)
        DriveCheckpoints(2, orun, veh, 1, nil, 2)
        H.eq(orun.state, 'ended', 'builder: driven through')
        Secs(3)
        local r = Rows('run_uuid = ?', { orun.id })[1] or {}
        H.eq(r.state, 'completed', 'builder: completed')
        H.eq(tonumber(r.cash_paid), 350, 'builder: the Training payout ($350)')
    end
    Config.DisabledMissions = {}
end

-- ============================================================================
--                               12. STORAGE COPY
-- ============================================================================
-- THE SAVES FOLDER INTO THE DATABASE (MariaDB).
-- Docs (docs/OWNER_GUIDE.md 3.5, Moving between the database and the saves folder): copy, then switch and restart; the copy
-- leaves the saves folder in use untouched and needs no restart while it is not the store in use.

local function Maria(sql)
    local h = io.popen(('mysql -uroot -N -B %s -e "%s" 2>&1'):format(H.db, sql))
    local out = h:read('a')
    h:close()
    return (out:gsub('%s+$', ''))
end
do
    -- the server's MariaDB database, empty (oxmysql's connection string names it)
    os.execute(
        ('mysql -uroot -e "DROP DATABASE IF EXISTS %s; CREATE DATABASE %s CHARACTER SET utf8mb4;"'):format(H.db, H.db))
    local before = Count('SELECT COUNT(*) AS n FROM cp_mission_runs')
    local ok, res = Act('server:admin:storageCopy', 5,
        { direction = 'files-to-database', reason = 'WF1 move', requestId = RequestId() }, 400)
    H.eq(ok, true, 'copy: the admin copies the saves folder into the database: ' .. tostring(res))
    H.eq(type(res) == 'table' and res.restart, false, 'copy: no restart needed (the saves folder stays in use)')
    H.eq(tonumber(Maria('SELECT COUNT(*) FROM cp_mission_runs')), before, 'copy: every run row is in MariaDB')
    H.eq(tonumber(Maria(('SELECT xp FROM cp_officers WHERE citizenid = \\"%s\\"'):format(CID[1]))), Xp(CID[1]),
        'copy: ...and the officer\'s XP')
    H.eq(tonumber(Maria('SELECT COUNT(*) FROM cp_custom_missions')),
        Count('SELECT COUNT(*) AS n FROM cp_custom_missions'), 'copy: ...and the Mission Builder missions')
    H.eq(Count('SELECT COUNT(*) AS n FROM cp_mission_runs'), before, 'copy: the saves folder in use is unchanged')
    Config.DisabledMissions = PATROL_OTHERS
    H.time = H.time + 601
    local okA, why = Act('server:acceptType', 6, 'patrol')
    H.eq(okA, true, 'copy: runs start at once after the copy: ' .. tostring(why))
    local run = Runs.getBySrc(6)
    if run then Act('server:abandon', 6, run.id) end
    Config.DisabledMissions = {}
    os.execute(('mysql -uroot -e "DROP DATABASE IF EXISTS %s;"'):format(H.db))
end

_G.print = realPrint

return H

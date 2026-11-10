-- End-to-end workflows, part 3: live crime, surrender and field training on the REAL server side of

-- End-to-end workflows, part 3: live crime, surrender and field training on the REAL server side of
-- Crimson-Police, every server file loaded as in game, database off (the saves folder, as shipped), every switch these
-- workflows touch turned on by the admin through the Admin UI's own Settings action. Each workflow also meets a
-- resource restart in its middle (H.restart, then every server file loaded again from the same saves folder), and
-- what survives is what docs/OWNER_GUIDE.md 6.4 and 3.11 say. Only the other resources and the natives are stubs.

local H = dofile('tests/harness.lua')
H.useFiles()
H.db = (os.getenv('CP_TEST_DB') or 'cp_test') .. '_lf_e2e'
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
local offline = {}        -- src -> true while that player is disconnected (section 5)
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

local function Natives()
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
    _G.GetVehiclePedIsIn = function() return 0 end
    _G.GetPedInVehicleSeat = function() return 0 end
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
            type = job == 'sast' and 'leo' or 'none',
            onduty = job ~= 'unemployed',
            grade = { level = grade, name = grade >= 3 and 'Sergeant' or (grade == 0 and 'Cadet' or 'Trooper') },
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

AddPlayer(1, 'LFE2EOF1', 'Ada', 'Trooper', 'sast', 1)      -- the unit leader of the live cases
AddPlayer(2, 'LFE2EOF2', 'Ben', 'Trooper', 'sast', 1)      -- his partner
AddPlayer(3, 'LFE2ETR3', 'Sam', 'Sarge', 'sast', 3)        -- the field trainer
AddPlayer(4, 'LFE2ESU4', 'Fay', 'Chief', 'sast', 3)        -- the supervisor who pairs them
AddPlayer(5, 'LFE2EAD5', 'Ann', 'Admin', 'unemployed', 0, true)
AddPlayer(6, 'LFE2EOF6', 'Cleo', 'Trooper', 'sast', 1)     -- the backup who joins and talks a suspect down
AddPlayer(7, 'LFE2ERK7', 'Rex', 'Rookie', 'sast', 0)       -- the rookie
AddPlayer(8, 'LFE2ERK8', 'Ivy', 'Rookie', 'sast', 0)       -- the second rookie (section 5)
AddPlayer(9, 'LFE2ECR9', 'Cal', 'Crook', 'unemployed', 0)  -- crew member A of the first crime
AddPlayer(10, 'LFE2EC10', 'Dee', 'Crook', 'unemployed', 0) -- crew member B of the first crime
AddPlayer(11, 'LFE2EC11', 'Eve', 'Crook', 'unemployed', 0) -- crew of the crime the restart ends
AddPlayer(12, 'LFE2EC12', 'Gus', 'Crook', 'unemployed', 0)
AddPlayer(13, 'LFE2EC13', 'Hal', 'Crook', 'unemployed', 0) -- the crew of section 5 (a quit and rejoin)
AddPlayer(14, 'LFE2EC14', 'Joy', 'Crook', 'unemployed', 0)
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
    -- every unit member answers Ready at once, as each officer tapping Ready on the tablet would
    local realCheck = CP.Units.readyCheck
    CP.Units.readyCheck = function(unit, typeKey, onReady, onCancel)
        local started = realCheck(unit, typeKey, onReady, onCancel)
        if started then
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

Boot()
H.time = os.time({ year = 2026, month = 9, day = 23, hour = 14, min = 0, sec = 0 })
H.ok(#loadedFiles >= 40, 'every server file loaded (' .. #loadedFiles .. ')')

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Place(src, c) H.players[src].coords = vec3(c.x + 0.0, c.y + 0.0, c.z + 0.0) end
local reqN = 0
local function Act(name, src, payload)
    reqN = reqN + 1
    local id = 'lfe2e' .. reqN
    Adv(1600)
    local mark = #H.events
    H.fire('crimson-police:' .. name, src, payload, id)
    for _ = 1, 40 do
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
            .. 'flagged, live_catches, breakdown FROM cp_mission_runs WHERE ' .. where .. ' ORDER BY id',
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
    return Act('server:admin:setSetting', 5, { path = path, json = cjson.encode(value), reason = 'H8 e2e' })
end
local function Bit(v) return v == true or tonumber(v) == 1 end

-- Crimson-Contracts' server-only lifecycle event, sent from its own resource.
local function Contracts(name, payload)
    invoking = 'crimson-contracts'
    TriggerEvent('crimson-contracts:server:' .. name, payload)
    invoking = nil
end
-- qbx_core's SetMetaData event for one player (the suspect's cuffs, downs and jail).
local function Meta(src, key, value)
    local old = PD[src].metadata[key]
    PD[src].metadata[key] = value
    TriggerEvent('qbx_core:server:onSetMetaData', key, old, value, src)
end

local function FormUnit(leader, member)
    local ok, data = Act('server:unitInvite', leader, member)
    H.eq(ok, true, ('unit invite %d -> %d: %s'):format(leader, member, tostring(data)))
    ok, data = Act('server:unitRespond', member, { accepted = true, unitId = data and data.unitId })
    H.eq(ok, true, ('invite accepted by %d: %s'):format(member, tostring(data)))
end

local CRIME_AT = vec3(1200.0, -1300.0, 35.0)       -- the reported place (El Burro Heights, no no-start zone)
local STATION = vec3(470.63, -974.11, 30.18)       -- Mission Row PD, a booking zone
local function Report(n, members)
    local list = {}
    for _, src in ipairs(members) do list[CID[src]] = src end
    for i, src in ipairs(members) do Place(src, vec3(CRIME_AT.x + 10.0 * i, CRIME_AT.y, CRIME_AT.z)) end
    Contracts('contractStarted', {
        id = n,
        uid = n .. '_1',
        key = 'warehouse_burglary',
        label = 'Warehouse Burglary',
        locationLabel = 'El Burro Heights',
        coords = { x = CRIME_AT.x, y = CRIME_AT.y, z = CRIME_AT.z },
        members = list,
        leaderCitizenId = CID[members[1]],
        startedAt = os.time(),
    })
    Contracts('dispatchSent', {
        id = n,
        uid = n .. '_1',
        dispatchId = 'cc_' .. n,
        title = 'Burglary in progress',
        street = 'El Burro Blvd',
        coords = { x = CRIME_AT.x, y = CRIME_AT.y, z = CRIME_AT.z },
    })
end
local function LiveCards(src)
    local out = {}
    for _, c in ipairs((CP.MissionCalls.list(src) or {}).calls or {}) do
        if c.live then out[#out + 1] = c end
    end
    return out
end
-- The unit claims the only LIVE card, then holds the reported place for secureSeconds (Respond, Secure the scene).
local function ClaimAndSecure(leader, partner)
    local card = LiveCards(leader)[1] or {}
    local ok, data = Act('server:claimMissionCall', leader, { callId = card.id })
    H.eq(ok, true, 'live: the leader claims the LIVE call: ' .. tostring(data))
    local run = Runs.getBySrc(leader)
    H.ok(run ~= nil and run.realSuspect == 'live', 'live: the case opened as a live run')
    H.ok(Runs.getBySrc(partner) == run, 'live: the partner is on the case')
    Place(leader, vec3(CRIME_AT.x + 5.0, CRIME_AT.y + 3.0, CRIME_AT.z))
    Place(partner, vec3(CRIME_AT.x + 7.0, CRIME_AT.y + 3.0, CRIME_AT.z))
    Secs(75)
    local st = run and Runs.ctx(run, 1).state
    H.eq(st and st.phase, 'detain', 'live: the scene is secured after secureSeconds on scene')
    return run, st
end
-- sc-police's cuff by an officer within reach, held custodyHoldSeconds.
local function Cuff(officer, suspect)
    local at = H.players[suspect].coords
    Place(officer, vec3(at.x + 1.5, at.y, at.z))
    H.fire('police:server:CuffPlayer', officer, suspect, false)
    Meta(suspect, 'ishandcuffed', true)
    Secs(Config.RealPlayers.custodyHoldSeconds + 3)
end
local function Timeline(runId)
    local case = CP.Opponents.findCase(runId)
    local whats = {}
    for _, e in ipairs(case and case.timeline or {}) do whats[e.what] = (whats[e.what] or 0) + 1 end
    return whats, case
end

-- Gang Shootout (tests/e2e_spec.lua has the long story of each step).
local TACTICAL_OTHERS = {
    'hostage_rescue',
    'bomb_disposal',
    'armored_truck_escort',
    'prison_break',
    'drug_lab_raid',
    'gang_hideout_raid',
}
local function Arrive(run, src)
    Place(src, run.location.start.coords)
    Secs(2)
end
local function Objective(src, run, index, ev) H.fire('crimson-police:server:objective', src, run.id, index, ev) end
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
-- The trainer's unit accepts Tactical (Gang Shootout only) and both reach the start.
local function StartShootout(leader, member)
    Config.DisabledMissions = TACTICAL_OTHERS
    Place(leader, vec3(0.0, 0.0, 0.0))
    Place(member, vec3(5.0, 0.0, 0.0))
    local ok, data = Act('server:acceptType', leader, 'tactical')
    H.eq(ok, true, 'fto: the trainer accepts Tactical: ' .. tostring(data))
    local run = Runs.getBySrc(leader)
    H.eq(run and run.missionId, 'gang_shootout', 'fto: Gang Shootout drawn')
    H.eq(Runs.getBySrc(member), run, 'fto: the rookie is on the same run')
    if run then
        Arrive(run, leader)
        Arrive(run, member)
        H.eq(run.state, 'in_progress', 'fto: in progress')
    end
    return run
end
local function Training(src)
    local mine = Cb('fto:getMine', src)
    return type(mine) == 'table' and mine or nil
end
local function TaskOf(view, key)
    for _, t in ipairs(view and view.tasks or {}) do if t.type == key then return t end end
    return nil
end

-- ============================================================================
--                      1. THE ADMIN TURNS EVERY SWITCH ON
-- ============================================================================

do
    H.eq(Config.Database.enabled, false, 'shipped: database off (the saves folder)')
    H.eq(Config.RealPlayers.liveCrime.enabled, false, 'shipped: live crimes off')
    H.eq(Config.RealPlayers.liveCrime.cash, false, 'shipped: live cases pay points only')
    H.eq(Config.Recognition.fieldTraining.enabled, false, 'shipped: field training off')
    H.eq(Config.FeatureRewards.surrender.enabled, false, 'shipped: talk-downs pay nothing')
    H.eq(Config.FeatureRewards.ftoSignOff.enabled, false, 'shipped: sign-offs pay nothing')
    H.eq(Config.FeatureRewards.ftoComplete.enabled, false, 'shipped: a finished training pays nothing')

    local ok, err = Act('server:admin:setSetting', 4,
        { path = 'RealPlayers.liveCrime.enabled', json = 'true', reason = 'not an admin' })
    H.eq(ok, false, 'admin: a supervisor cannot change a setting (' .. tostring(err) .. ')')

    local water = { { item = 'water', count = 1, chance = 1.0, value = 20 } }
    for _, c in ipairs({
        { 'RealPlayers.liveCrime.enabled', true },
        { 'RealPlayers.liveCrime.cash', true },
        { 'RealPlayers.liveCrime.lastReportedEvery', 60 },
        { 'Rewards.enabled', true },
        { 'FeatureRewards.surrender.enabled', true },
        { 'FeatureRewards.surrender.items', water },
        { 'Recognition.fieldTraining.enabled', true },
        { 'Recognition.fieldTraining.tasks', { tactical = 1 } },
        { 'Recognition.fieldTraining.trainerBonus', 10 },
        { 'FeatureRewards.ftoSignOff.enabled', true },
        { 'FeatureRewards.ftoComplete.enabled', true },
    }) do
        ok, err = Setting(c[1], c[2])
        H.eq(ok, true, ('admin: %s saved: %s'):format(c[1], tostring(err)))
    end
    H.eq(Config.RealPlayers.liveCrime.enabled, true, 'admin: live crimes on at once')
    H.eq(Config.Recognition.fieldTraining.enabled, true, 'admin: field training on at once')

    -- every officer opens the tablet once (the session also saves his officer row: department, callsign)
    for _, src in ipairs({ 1, 2, 3, 4, 6, 7 }) do
        local session, why = Cb('getSession', src, { ui = 'officer' })
        H.ok(session ~= nil, ('tablet: %s opens the Officer UI: %s'):format(CID[src], tostring(why)))
    end
    Place(1, vec3(400.0, -980.0, 30.0))
    Place(2, vec3(402.0, -980.0, 30.0))
    Place(6, vec3(404.0, -980.0, 30.0))
    FormUnit(1, 2)
    Secs(2)
end

-- ============================================================================
--                               2. A LIVE CRIME
-- ============================================================================
-- CALL, CLAIM, JOIN, DETAIN, BOOK, TALK DOWN, END, PAY.

local case1
do
    local mark = #H.events
    Report(2, { 9, 10 })
    H.eq(CP.MissionCalls.liveCount(), 1, 'live: the reported crime posts one LIVE call')
    local card = LiveCards(1)[1] or {}
    H.eq(card.suspects, 2, 'live: the card counts two suspects')
    H.eq(#ClientEvents('crimson-police:client:missionCall', 1, mark), 1, 'live: the idle leader gets the red toast')

    local run, st = ClaimAndSecure(1, 2)
    case1 = run

    -- backup: Cleo, on no mission, reaches the scene and gets the join pop-up; Yes joins her
    mark = #H.events
    Place(6, vec3(CRIME_AT.x - 20.0, CRIME_AT.y, CRIME_AT.z))
    Secs(8)
    local offer = ClientEvents('crimson-police:client:liveJoinOffer', 6, mark)[1]
    H.ok(offer ~= nil, 'join: the backup at the scene gets "Join the live case?"')
    if offer then H.fire('crimson-police:server:liveJoin', 6, offer.args[1].runId, offer.args[1].token, true) end
    Secs(2)
    H.ok(Runs.getBySrc(6) == run, 'join: the backup is on the case')

    -- A: cuffed by the leader, held: detained; then booked at Mission Row for 10 months
    local case = CP.Opponents.caseOf(run)
    local recA, recB = case.suspects[CID[9]], case.suspects[CID[10]]
    Cuff(1, 9)
    H.eq(recA.state, 'detained', 'detain: A is detained once the cuffs held custodyHoldSeconds')
    H.eq(st.lines.live_detain[CID[9]], 1, 'detain: a full detain line (he was not down)')
    Place(9, vec3(STATION.x + 2.0, STATION.y, STATION.z))
    Place(1, vec3(STATION.x + 3.0, STATION.y, STATION.z))
    Secs(30)
    H.fire('police:server:JailPlayer', 1, 9, 10)
    Meta(9, 'injail', 10)
    Secs(2)
    H.eq(recA.state, 'booked', 'book: A is booked at Mission Row')

    -- B: Cleo walks up to him: "close enough to talk down", Talk them down, his Yes; cuffed, held: Peaceful arrest
    Place(10, vec3(CRIME_AT.x + 60.0, CRIME_AT.y, CRIME_AT.z))
    mark = #H.events
    Place(6, vec3(CRIME_AT.x + 52.0, CRIME_AT.y, CRIME_AT.z))
    Secs(6)
    H.ok(Toasts(6, mark)['livecrime.talk.hint'], 'talk: the backup is told she can talk B down')
    mark = #H.events
    H.fire('crimson-police:server:liveTalkDown', 6)
    local ask = ClientEvents('crimson-police:client:liveSurrenderAsk', 10, mark)[1]
    H.ok(ask ~= nil and ask.args[1].talk == true, 'talk: B is asked "An officer is talking you down"')
    if ask then H.fire('crimson-police:server:liveSurrender', 10, ask.args[1].token, true) end
    Secs(1)
    H.ok(type(recB.surrender) == 'table' and recB.surrender.by == 6, 'talk: B surrendered to the backup')
    Cuff(6, 10)
    H.eq(recB.state, 'detained', 'talk: B is detained')
    H.eq(st.lines.peaceful_arrest[CID[10]], 1, 'talk: the Peaceful arrest line counts')
    Secs(3)
    H.eq((Paid(CID[6])), 0, 'talk: Z8B: nothing is paid at the detain (the talk-down pays when the case ends)')

    -- the leader ends the case from the radial menu
    mark = #H.events
    Place(1, vec3(CRIME_AT.x + 5.0, CRIME_AT.y, CRIME_AT.z))
    Objective(1, run, 1, { type = 'end_case' })
    Secs(3)
    H.eq(run.state, 'ended', 'end: End case ends the case')
    local ended = LocalEvents('crimson-police:server:liveCrimeEnded', mark)[1] or {}
    H.eq(ended.suspects and ended.suspects[CID[9]], 'booked', 'end: liveCrimeEnded says A booked')
    H.eq(ended.suspects and ended.suspects[CID[10]], 'detained', 'end: ...and B detained')
    H.eq(ended.officers, 3, 'end: ...by three officers')
    H.eq(CP.MissionCalls.liveCount(), 0, 'end: no LIVE call left')
    Secs(3)
    local talkN = #Rows('mission_id = ? AND citizenid = ?', { 'reward_surrender', CID[6] })
    H.eq(talkN, 1, 'talk: the backup is paid for the talk-down once, at the end')
    H.eq(ItemsGiven(6, 'water'), 1, 'talk: ...and gets the water')

    -- payouts: Config.RealPlayers.liveCrime.cash on, so each row pays the Investigation payout once
    Secs(3)
    local rows = Rows('run_uuid = ?', { run.id })
    H.eq(#rows, 3, 'pay: one row per officer, the backup included')
    for _, r in ipairs(rows) do
        H.eq(r.state, 'completed', 'pay: ' .. r.citizenid .. ' completed')
        H.ok((tonumber(r.final_points) or 0) > 0, 'pay: ' .. r.citizenid .. ' earned the live lines')
        H.eq(r.cash_status, 'paid', 'pay: ' .. r.citizenid .. ' cash paid')
        H.ok((tonumber(r.cash_paid) or 0) > 0, 'pay: ' .. r.citizenid .. ' paid ' .. tostring(r.cash_paid))
        local src = r.citizenid == CID[1] and 1 or (r.citizenid == CID[2] and 2 or 6)
        local talk = src == 6 and Config.FeatureRewards.surrender.money or 0
        local _, got = Paid(r.citizenid)
        H.eq(got, (tonumber(r.cash_paid) or 0) + talk, 'pay: ' .. r.citizenid .. ' got the row amount once')
    end
    local talkRows = Rows('mission_id = ?', { 'reward_surrender' })
    H.eq(#talkRows, 1, 'pay: one talk-down payment row')
    H.eq(talkRows[1] and talkRows[1].citizenid, CID[6], 'pay: ...for the backup')

    -- the staff screen: Admin UI -> Real suspects lists the closed case, its timeline names every step
    local list, why = Cb('admin:getRsCases', 5)
    H.ok(list ~= nil, 'staff: the admin opens Real suspects: ' .. tostring(why))
    local listed = false
    for _, c in ipairs(list and list.cases or {}) do if c.runId == run.id then listed = true end end
    H.ok(listed, 'staff: the case is listed')
    local denied = Cb('admin:getRsCases', 4)
    H.eq(denied, nil, 'staff: a supervisor without the key gets no Real suspects screen')
    local whats = Timeline(run.id)
    for _, w in ipairs({
        'responded',
        'scene_secured',
        'officer_joined',
        'talk_down',
        'surrendered',
        'peaceful_arrest',
        'end_case',
    }) do
        H.ok((whats[w] or 0) > 0, 'staff: the timeline has ' .. w)
    end
end

-- ============================================================================
--                  3. A RESTART IN THE MIDDLE OF A LIVE CASE
-- ============================================================================
-- AND OF A SURRENDER.
-- docs/OWNER_GUIDE.md 6.4: a restart ends every open case and its run with no row, no pay and no cooldown; the closed cases,
-- the payments and the settings stay.

do
    -- the jail and cuffs of the first crime are over
    for _, src in ipairs({ 9, 10 }) do
        Meta(src, 'injail', 0)
        Meta(src, 'ishandcuffed', false)
    end
    Place(6, vec3(404.0, -980.0, 30.0))
    Secs(2)
    Report(3, { 11, 12 })
    H.eq(CP.MissionCalls.liveCount(), 1, 'restart: a second crime posts a LIVE call')
    local run = ClaimAndSecure(1, 2)
    local runId = run and run.id
    -- Gus gives himself up to the leader's talk-down (Eve ran off); nobody cuffs him before the restart
    Place(11, vec3(CRIME_AT.x + 200.0, CRIME_AT.y, CRIME_AT.z))
    Place(12, vec3(CRIME_AT.x + 12.0, CRIME_AT.y + 3.0, CRIME_AT.z))
    local mark = #H.events
    H.fire('crimson-police:server:liveTalkDown', 1)
    local ask = ClientEvents('crimson-police:client:liveSurrenderAsk', 12, mark)[1]
    if ask then H.fire('crimson-police:server:liveSurrender', 12, ask.args[1].token, true) end
    Secs(1)
    local rec = CP.Opponents.caseOf(run).suspects[CID[12]]
    H.ok(type(rec.surrender) == 'table', 'restart: Gus surrendered before the restart')
    local paidBefore = #addMoney
    local itemsBefore = #addItem

    Restart()

    H.eq(Config.RealPlayers.liveCrime.enabled, true, 'restart: the Settings changes are kept')
    H.eq(Config.Recognition.fieldTraining.enabled, true, 'restart: ...field training too')
    H.eq(Runs.getBySrc(1), nil, 'restart: the leader is on no case')
    H.eq(Runs.getBySrc(2), nil, 'restart: nor is his partner')
    H.eq(CP.Opponents.active(), false, 'restart: no case is open')
    H.eq(#Rows('run_uuid = ?', { runId }), 0, 'restart: the case the restart ended wrote no row')
    H.eq(#addMoney, paidBefore, 'restart: nothing was paid for it')
    H.eq(#addItem, itemsBefore, 'restart: no item either')
    H.eq(CP.MissionCalls.liveCount(), 0, 'restart: no LIVE call is left over')
    local cd = Runs.cooldowns(CID[1]) or {}
    H.eq(next(cd.types or {}), nil, 'restart: the leader has no type cooldown from it')

    -- the closed case of section 2 is still on the staff screen with its timeline
    local list = Cb('admin:getRsCases', 5)
    local found, open = false, false
    for _, c in ipairs(list and list.cases or {}) do
        if c.runId == case1.id then found = true end
        if c.runId == runId then open = true end
    end
    H.ok(found, 'restart: the closed case is still listed')
    H.ok(not open, 'restart: the case the restart ended is not')
    local whats = Timeline(case1.id)
    H.ok((whats.peaceful_arrest or 0) > 0, 'restart: its timeline still has the Peaceful arrest')

    -- Gus' surrender went with the case: /surrender tells him he is not wanted, Talk them down finds no case
    mark = #H.events
    local cmd = H.commands[Config.RealPlayers.surrender.command or 'surrender']
    H.ok(cmd ~= nil, 'restart: /surrender is registered again (live crimes on from the saved settings)')
    if cmd then cmd.fn(12, {}, '') end
    H.ok(Toasts(12, mark)['livecrime.surrender.not_wanted'], 'restart: /surrender says he is not wanted')

    -- Crimson-Contracts' crime ends after the restart: ignored quietly, no liveCrimeEnded
    mark = #H.events
    Contracts('contractEnded', { id = 3, uid = '3_1', outcome = 'success', reason = 'delivered' })
    Secs(1)
    H.eq(#LocalEvents('crimson-police:server:liveCrimeEnded', mark), 0, 'restart: the old crime\'s end is ignored')

    -- the unit is gone with the restart; formed again it claims the next crime, and that one pays as usual
    H.eq(CP.Units.unitOf(1), nil, 'restart: the unit is gone')
    FormUnit(1, 2)
    Meta(12, 'ishandcuffed', false)
    Report(4, { 11, 12 })
    H.eq(CP.MissionCalls.liveCount(), 1, 'restart: a new crime posts a LIVE call')
    run = ClaimAndSecure(1, 2)
    Cuff(1, 11)
    Objective(1, run, 1, { type = 'end_case' })
    Secs(5)
    H.eq(run.state, 'ended', 'restart: the new case ends')
    local rows = Rows('run_uuid = ?', { run.id })
    H.eq(#rows, 2, 'restart: one row per officer')
    for _, r in ipairs(rows) do
        H.eq(r.cash_status, 'paid', 'restart: ' .. r.citizenid .. ' paid')
    end
    H.eq(#Rows('mission_id = ?', { 'reward_surrender' }), 1, 'restart: the talk-down was never paid twice')
    CP.Units.remove(1, { reason = 'left', silent = true })
    CP.Units.remove(2, { reason = 'left', silent = true })
end

-- ============================================================================
--                              4. FIELD TRAINING
-- ============================================================================
-- PAIR, A RESTART MID-RUN, THE TASK, A RESTART, SIGN-OFF, BADGE, REWARDS.
-- docs/OWNER_GUIDE.md 3.11: nothing is lost on a restart (the training is saved with the officer).

do
    -- an officer cannot pair; the supervisor pairs the rookie with the trainer
    local ok, data = Act('server:sup:ftoPair', 6, { rookie = CID[7], trainer = CID[3] })
    H.eq(ok, false, 'fto: an officer cannot pair (' .. tostring(data) .. ')')
    ok, data = Act('server:sup:ftoPair', 4, { rookie = CID[7], trainer = CID[3] })
    H.eq(ok, true, 'fto: the supervisor pairs the rookie with the trainer: ' .. tostring(data))
    local mine = Training(7)
    H.eq(mine and mine.training and mine.training.trainer.citizenid, CID[3], 'fto: the rookie sees his trainer')
    H.eq(TaskOf(mine and mine.training, 'tactical').runs, 0, 'fto: Tactical 0 of 1')

    -- a run the restart ends counts nothing and starts no cooldown
    FormUnit(3, 7)
    local run = StartShootout(3, 7)
    Restart()
    H.eq(Runs.getBySrc(3), nil, 'fto: the restart ended the run')
    mine = Training(7)
    H.ok(mine and mine.training ~= nil, 'fto: the pairing survives the restart')
    H.eq(TaskOf(mine and mine.training, 'tactical').runs, 0, 'fto: the ended run did not count')
    H.eq(#Rows('run_uuid = ?', { run and run.id or '' }), 0, 'fto: ...and wrote no row')

    -- the unit, formed again, plays Gang Shootout to the end: the task is ready, the trainer gets the toast
    FormUnit(3, 7)
    local mark = #H.events
    run = StartShootout(3, 7)
    Place(3, run.location.start.coords)
    Place(7, run.location.start.coords)
    ClearHostiles(run, 3)
    Place(7, run.location.scene)
    SecureScene(run, 3)
    H.eq(run.state, 'ended', 'fto: Gang Shootout completed')
    Secs(3)
    local rows = Rows('run_uuid = ?', { run.id })
    H.eq(#rows, 2, 'fto: one row each')
    for _, r in ipairs(rows) do
        H.eq(r.state, 'completed', 'fto: ' .. r.citizenid .. ' completed')
        H.eq(Bit(r.flagged), false, 'fto: ' .. r.citizenid .. ' not flagged')
    end
    H.ok(Toasts(3, mark)['fto.toast.ready'], 'fto: the trainer is told the task is ready')
    mine = Training(7)
    local task = TaskOf(mine and mine.training, 'tactical') or {}
    H.eq(task.runs, 1, 'fto: Tactical 1 of 1')
    H.eq(task.ready, true, 'fto: ready to sign off')
    CP.Units.remove(3, { reason = 'left', silent = true })
    CP.Units.remove(7, { reason = 'left', silent = true })

    -- a restart before the sign-off loses nothing
    Restart()
    local trainer = Training(3)
    local rookie = trainer and trainer.rookies and trainer.rookies[1]
    H.eq(rookie and rookie.rookie.citizenid, CID[7], 'fto: after the restart the trainer still sees his rookie')
    H.eq(TaskOf(rookie, 'tactical') and TaskOf(rookie, 'tactical').ready, true, 'fto: ...the task still ready')

    -- only his own trainer signs off; the sign-off finishes the training: badge, bonus, both payments
    local paidT, paidR = select(2, Paid(CID[3])), select(2, Paid(CID[7]))
    ok, data = Act('server:fto:signOff', 4, { rookie = CID[7], task = 'tactical' })
    H.eq(ok, false, 'fto: another supervisor cannot sign off (' .. tostring(data) .. ')')
    mark = #H.events
    ok, data = Act('server:fto:signOff', 3, { rookie = CID[7], task = 'tactical', note = 'Calm under fire' })
    H.eq(ok, true, 'fto: the trainer signs Tactical off: ' .. tostring(data))
    Secs(3)
    H.ok(Toasts(7, mark)['fto.toast.done'], 'fto: the rookie is told his training is done')
    local badge = H.sql('SELECT badge_id FROM cp_badges WHERE citizenid = ?', { CID[7] })
    H.eq(badge[1] and badge[1].badge_id, Config.Recognition.fieldTraining.badge,
        'fto: the rookie has the Field Training badge')
    H.eq(select(2, Paid(CID[3])) - paidT, Config.FeatureRewards.ftoSignOff.money, 'fto: the trainer is paid $250')
    H.eq(select(2, Paid(CID[7])) - paidR, Config.FeatureRewards.ftoComplete.money, 'fto: the rookie is paid $1000')
    local bonus = Rows('citizenid = ? AND mission_id = ?', { CID[3], 'fto_bonus' })
    H.eq(#bonus, 1, 'fto: the trainer bonus row')
    H.eq(tonumber(bonus[1] and bonus[1].final_points), 10, 'fto: ...of 10 points')
    ok = Act('server:fto:signOff', 3, { rookie = CID[7], task = 'tactical' })
    H.eq(ok, false, 'fto: a second sign-off is refused')

    -- and after one more restart: the badge, the finished training and the payments stay; nothing pays twice
    Restart()
    mine = Training(7)
    H.ok(mine and mine.training and (mine.training.doneAt or 0) > 0, 'fto: the training reads done after a restart')
    H.eq(#H.sql('SELECT badge_id FROM cp_badges WHERE citizenid = ?', { CID[7] }), 1, 'fto: one badge')
    H.eq(#Rows('mission_id = ?', { 'reward_ftoSignOff' }), 1, 'fto: one sign-off payment row')
    H.eq(#Rows('mission_id = ?', { 'reward_ftoComplete' }), 1, 'fto: one finished-training payment row')
end

-- ============================================================================
--             5. A PLAYER QUITS AND COMES BACK IN THE MIDDLE OF IT
-- ============================================================================
-- Step FX1. A LIVE CRIME: A SUSPECT AND AN OFFICER DROP; FIELD TRAINING: THE ROOKIE MID-RUN, THE TRAINER BEFORE THE
-- SIGN-OFF. docs/OWNER_GUIDE.md 6 and 3.11: a suspect who comes back within Config.RealPlayers.disconnectGrace stays in
-- the case; an officer who quits leaves the run with his own result while it goes on for the rest; the training is
-- saved.

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
-- Staff clear all of an officer's cooldowns (Admin UI -> Live -> anti-farm, one of his clears a day), so he may play
-- Gang Shootout again.
local function ClearCooldowns(cid)
    local ok, err = CP.LiveCtl.clearCooldowns(cid, 'all')
    H.eq(ok, true, 'staff clear the cooldowns of ' .. cid .. ': ' .. tostring(err))
end

do
    FormUnit(1, 2)
    Secs(2)
    Report(5, { 13, 14 })
    H.eq(CP.MissionCalls.liveCount(), 1, 'drop: a crime posts a LIVE call')
    local run = ClaimAndSecure(1, 2)
    local case = CP.Opponents.caseOf(run)
    local hal = case and case.suspects[CID[13]]

    -- Hal quits and joins again within disconnectGrace: he is still a suspect of the case, and can be detained
    Drop(13)
    H.ok(run.state ~= 'ended', 'drop: the case goes on while a suspect is away')
    H.ok(hal and hal.state ~= 'left', 'drop: Hal is not out of the case within the grace')
    Secs(30)
    Reconnect(13)
    Place(13, vec3(CRIME_AT.x + 12.0, CRIME_AT.y + 3.0, CRIME_AT.z))
    Secs(3)
    H.ok(hal and hal.src == 13, 'drop: Hal is back in the case under her id')
    Cuff(1, 13)
    H.eq(hal and hal.state, 'detained', 'drop: Hal, back, is detained')

    -- Ben (the partner) quits mid-case: he leaves with his own result, the case goes on for Ada
    Drop(2)
    H.eq(Runs.getBySrc(2), nil, 'drop: the partner is off the case')
    H.eq(Runs.getBySrc(1), run, 'drop: the leader is still on it')
    H.ok(run.state ~= 'ended', 'drop: the case goes on')
    local benRows = Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[2] })
    H.eq(#benRows, 1, 'drop: the partner has his own row at once')
    H.ok(benRows[1] and benRows[1].cash_status ~= 'paid', 'drop: ...no cash for quitting')

    -- he joins again: he can open the tablet, is on no run, and is not put back on the case
    Reconnect(2)
    local session, why = Cb('getSession', 2, { ui = 'officer' })
    H.ok(session ~= nil, 'drop: the partner opens the tablet again: ' .. tostring(why))
    H.eq(Runs.getBySrc(2), nil, 'drop: ...and is on no run')

    -- Ada ends the case: one row each, Ben's never written twice, Ada paid once
    Place(1, vec3(CRIME_AT.x + 5.0, CRIME_AT.y, CRIME_AT.z))
    Objective(1, run, 1, { type = 'end_case' })
    Secs(5)
    H.eq(run.state, 'ended', 'drop: End case ends it')
    H.eq(#Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[2] }), 1,
        'drop: the partner\'s row is not written again')
    local ada = Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[1] })
    H.eq(ada[1] and ada[1].state, 'completed', 'drop: the leader completed the case')
    H.eq(ada[1] and ada[1].cash_status, 'paid', 'drop: ...and is paid')
    H.eq(CP.Opponents.active(), false, 'drop: no case is left open')
    CP.Units.remove(1, { reason = 'left', silent = true })
    CP.Units.remove(2, { reason = 'left', silent = true })
end

do
    -- a second rookie opens the tablet once, then is paired with the same trainer
    local session, why = Cb('getSession', 8, { ui = 'officer' })
    H.ok(session ~= nil, 'fto drop: the second rookie opens the Officer UI: ' .. tostring(why))
    local ok, data = Act('server:sup:ftoPair', 4, { rookie = CID[8], trainer = CID[3] })
    H.eq(ok, true, 'fto drop: the supervisor pairs the second rookie: ' .. tostring(data))
    ClearCooldowns(CID[3])

    -- the rookie quits mid-run: the run goes on for the trainer, the run does not count for the rookie
    FormUnit(3, 8)
    local run = StartShootout(3, 8)
    Drop(8)
    H.eq(Runs.getBySrc(8), nil, 'fto drop: the rookie is off the run')
    H.eq(Runs.getBySrc(3), run, 'fto drop: the trainer is still on it')
    Reconnect(8)
    local mine = Training(8)
    H.ok(mine and mine.training ~= nil, 'fto drop: back, the rookie is still in field training')
    H.eq((TaskOf(mine and mine.training, 'tactical') or {}).runs, 0, 'fto drop: the run he left did not count')
    if run then
        Place(3, run.location.start.coords)
        ClearHostiles(run, 3)
        SecureScene(run, 3)
        H.eq(run.state, 'ended', 'fto drop: the trainer finishes the run alone')
    end
    Secs(3)
    mine = Training(8)
    H.eq((TaskOf(mine and mine.training, 'tactical') or {}).runs, 0, 'fto drop: still 0 of 1')
    CP.Units.remove(3, { reason = 'left', silent = true })

    -- together again to the end: ready; the trainer quits and joins again before the sign-off, nothing is lost
    for _, src in ipairs({ 3, 8 }) do ClearCooldowns(CID[src]) end
    FormUnit(3, 8)
    run = StartShootout(3, 8)
    if run then
        Place(3, run.location.start.coords)
        Place(8, run.location.start.coords)
        ClearHostiles(run, 3)
        Place(8, run.location.scene)
        SecureScene(run, 3)
        H.eq(run.state, 'ended', 'fto drop: the second run completed')
    end
    Secs(3)
    CP.Units.remove(3, { reason = 'left', silent = true })
    CP.Units.remove(8, { reason = 'left', silent = true })
    mine = Training(8)
    H.eq((TaskOf(mine and mine.training, 'tactical') or {}).ready, true, 'fto drop: ready to sign off')
    Drop(3)
    Reconnect(3)
    local trainer = Training(3)
    local found = nil
    for _, r in ipairs(trainer and trainer.rookies or {}) do
        if r.rookie and r.rookie.citizenid == CID[8] then found = r end
    end
    H.ok(found ~= nil and (TaskOf(found, 'tactical') or {}).ready == true,
        'fto drop: back, the trainer still sees it ready')
    local mark = #H.events
    ok, data = Act('server:fto:signOff', 3, { rookie = CID[8], task = 'tactical' })
    H.eq(ok, true, 'fto drop: the trainer signs it off after his reconnect: ' .. tostring(data))
    Secs(3)
    H.ok(Toasts(8, mark)['fto.toast.done'], 'fto drop: the rookie is told his training is done')
    mine = Training(8)
    H.ok(mine and mine.training and (mine.training.doneAt or 0) > 0, 'fto drop: the training reads done')
end

return H

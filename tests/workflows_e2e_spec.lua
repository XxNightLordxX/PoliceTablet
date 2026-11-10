-- End-to-end workflows, part 2: officers and supervisors on the REAL server side of Crimson-Police, every
-- server file loaded as in game, database off (the saves folder, as shipped), every switch these workflows touch
-- turned on by the admin through the Admin UI's own Settings action. Only the other resources and natives are stubs.

-- End-to-end workflows, part 2: officers and supervisors on the REAL server side of Crimson-Police, every
-- server file loaded as in game, database off (the saves folder, as shipped), every switch these workflows touch
-- turned on by the admin through the Admin UI's own Settings action. Only the other resources and natives are stubs.
-- 1. The admin turns it on. 2. An officer's NPC mission: accept, run, result, payout with money and items.
-- 3. A SAST + FIB unit (cross-department) run. 4. A mission call: created by a supervisor, claimed, run, paid.
-- 5. Supervisor controls and awards (a control, a cooldown clear, Give points with its default money and items).
-- 6. Review, void and dispute.

local H = dofile('tests/harness.lua')
H.useFiles()
H.db = (os.getenv('CP_TEST_DB') or 'cp_test') .. '_wf_e2e'
H.resetSaves()
H.boot({ side = 'server', realLocale = true })
H.time = os.time({ year = 2026, month = 9, day = 23, hour = 14, min = 0, sec = 0 })
local U = CP.U
local cjson = require('cjson')

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

local ents, nextHandle, nextNet = {}, 9000, 20000
local netToEnt = {}
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
local offline = {}
local realGetPlayerName = _G.GetPlayerName
_G.GetPlayerName = function(src)
    src = tonumber(src)
    if not src or offline[src] or not H.players[src] then return nil end
    return realGetPlayerName(src)
end
_G.GetPlayers = function()
    local out = {}
    for src in pairs(H.players) do if not offline[src] then out[#out + 1] = tostring(src) end end
    table.sort(out)
    return out
end

-- ============================================================================
--                       EXPORTS OF THE OUTSIDE RESOURCES
-- ============================================================================

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
    H.players[src] = { coords = vec3(0.0, 0.0, 0.0), ace = {}, state = {} }
    if admin then H.players[src].ace[Config.AdminAce] = true end
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
local realState = _G.GetResourceState
_G.GetResourceState = function(name)
    if name == 'ox_inventory' then return 'started' end
    return realState and realState(name) or 'missing'
end

-- ============================================================================
--                                   PLAYERS
-- ============================================================================

AddPlayer(1, 'WFE2EOF1', 'Ada', 'Trooper', 'sast', 1)     -- the solo officer
AddPlayer(2, 'WFE2EOF2', 'Ben', 'Agent', 'fib', 1)        -- the FIB partner of the unit
AddPlayer(3, 'WFE2ESU3', 'Sam', 'Sarge', 'sast', 3)       -- the SAST supervisor
AddPlayer(4, 'WFE2ESU4', 'Fay', 'Chief', 'fib', 3)        -- the FIB supervisor
AddPlayer(5, 'WFE2EAD5', 'Ann', 'Admin', 'unemployed', 0, true)
AddPlayer(6, 'WFE2EOF6', 'Cleo', 'Trooper', 'sast', 1)    -- the officer who claims the mission call
AddPlayer(7, 'WFE2EOF7', 'Dan', 'Agent', 'fib', 1)        -- the officer whose runs are flagged
local CID = {}
for src, pd in pairs(PD) do CID[src] = pd.citizenid end

-- ============================================================================
--                            LOAD THE REAL RESOURCE
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
    local realCreate = _G.CreateThread
    local deferred = {}
    _G.CreateThread = function(fn) deferred[#deferred + 1] = fn end
    _G.Citizen.CreateThread = _G.CreateThread
    for _, file in ipairs(loadedFiles) do H.load(file) end
    _G.CreateThread = realCreate
    _G.Citizen.CreateThread = realCreate
    for _, fn in ipairs(deferred) do realCreate(fn) end
end
H.ok(#loadedFiles >= 40, 'every server file loaded (' .. #loadedFiles .. ')')
H.step(0)
for _ = 1, 3 do H.step(1000) end

-- every unit member answers Ready at once, as each officer tapping Ready on the tablet would
do
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
local function Secs(n) Adv(n * 1000) end

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Place(src, c) H.players[src].coords = vec3(c.x + 0.0, c.y + 0.0, c.z + 0.0) end
local reqN = 0
local function Act(name, src, payload)
    reqN = reqN + 1
    local id = 'wfe2e' .. reqN
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
local function Rows(where, params)
    return H.sql(
        'SELECT id, run_uuid, citizenid, department, mission_type, mission_id, state, tier, departments_n, '
            .. 'final_points, cash_base, cash_paid, cash_status, flagged, flag_reason, voided, breakdown '
            .. 'FROM cp_mission_runs WHERE ' .. where .. ' ORDER BY id',
        params
    )
end
-- The Supervisor UI's request id of a screen action that must never run twice (opts.requestId).
local function RequestId() return ('%08x-0000-4000-8000-%012x'):format(reqN + 1, 77) end
local function Bit(v) return v == true or tonumber(v) == 1 end
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
local function ItemRows(cid)
    return H.sql('SELECT row_id, item, count, status FROM cp_item_rewards WHERE citizenid = ? ORDER BY id', { cid })
end
local function Xp(cid)
    return tonumber((H.sql('SELECT xp FROM cp_officers WHERE citizenid = ?', { cid })[1] or {}).xp) or 0
end
local function Setting(path, value)
    return Act('server:admin:setSetting', 5, { path = path, json = cjson.encode(value), reason = 'H7 e2e' })
end

local Runs = CP.Runs
local PATROL_OTHERS = { 'business_check', 'street_race_bust', 'parking_patrol', 'traffic_enforcement' }
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

-- Beat Patrol (the Patrol pool is Beat Patrol only): arrive, take the wheel; the checkpoints are driven after.
local function StartPatrolRun(src, run)
    Arrive(run, src)
    H.eq(run.state, 'in_progress', ('%s: Beat Patrol in progress'):format(CID[src]))
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
local function AcceptPatrol(src)
    Config.DisabledMissions = PATROL_OTHERS
    Place(src, vec3(150.0, -1200.0, 29.0))
    local ok, data = Act('server:acceptType', src, 'patrol')
    H.eq(ok, true, ('%s accepts Patrol: %s'):format(CID[src], tostring(data)))
    return Runs.getBySrc(src)
end
-- A flagged Beat Patrol: one checkpoint, then a 3 km jump in a second (CP.AntiCheat's speed check), then the rest.
local function FlaggedPatrol(src, far)
    local run = AcceptPatrol(src)
    local veh = StartPatrolRun(src, run)
    DriveCheckpoints(src, run, veh, 1, 1)
    Place(src, far)
    Secs(1)
    Objective(src, run, 1, CheckpointEv(2, veh))
    H.eq(run.flagged and run.flagged.reason, 'speed', ('%s: the jump flags the run'):format(CID[src]))
    DriveCheckpoints(src, run, veh, 2, 5, 20)
    H.eq(run.state, 'ended', ('%s: the flagged run still completes'):format(CID[src]))
    return Rows('run_uuid = ?', { run.id })[1] or {}, run
end

-- Gang Shootout helpers (tests/e2e_spec.lua has the long story of each).
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

Config.Events.modifierChance = 0     -- no random twist: every pay below is exact

-- ============================================================================
--                      1. THE ADMIN TURNS EVERY SWITCH ON
-- ============================================================================

do
    H.eq(Config.Database.enabled, false, 'shipped: database off (the saves folder)')
    H.eq(Config.Rewards.enabled, false, 'shipped: item rewards off')
    H.eq(Config.FeatureRewards.supAward.enabled, false, 'shipped: Give points pays no money')
    H.eq(Config.MissionControls.controls.awardPoints.on, false, 'shipped: Give points is off')

    local ok, err = Act('server:admin:setSetting', 3,
        { path = 'Rewards.enabled', json = 'true', reason = 'not an admin' })
    H.eq(ok, false, 'admin: a supervisor cannot change a setting (' .. tostring(err) .. ')')
    H.eq(Config.Rewards.enabled, false, 'admin: ...and items stay off')

    local controls = U.copy(Config.MissionControls.controls)
    controls.awardPoints.on = true
    local pool = { chance = 1.0, rolls = 1, pool = { { item = 'water', count = 2, weight = 1, value = 20 } } }
    for _, c in ipairs({
        { 'Rewards.enabled', true },
        { 'Rewards.byType', { patrol = pool, tactical = pool } },
        { 'Permissions.supervisor.missionControls', true },
        { 'MissionControls.controls', controls },
        { 'FeatureRewards.supAward.enabled', true },
        { 'FeatureRewards.supAward.items', { { item = 'water', count = 1, chance = 1.0, value = 20 } } },
    }) do
        ok, err = Setting(c[1], c[2])
        H.eq(ok, true, ('admin: %s saved: %s'):format(c[1], tostring(err)))
    end
    H.eq(Config.Rewards.enabled, true, 'admin: item rewards on at once')
    H.eq(Config.FeatureRewards.supAward.enabled, true, 'admin: Give points pays money')
    H.eq(Config.FeatureRewards.supAward.money, 5, 'admin: ...with its default $5 a point ready')
    H.eq(Config.MissionControls.controls.awardPoints.on, true, 'admin: Give points is on')

    -- every officer opens the tablet once (the session also saves his officer row: department, callsign)
    for _, src in ipairs({ 1, 2, 3, 4, 6, 7 }) do
        local session, why = Cb('getSession', src, { ui = 'officer' })
        H.ok(session ~= nil, ('tablet: %s opens the Officer UI: %s'):format(CID[src], tostring(why)))
    end
    Secs(2)
end

-- ============================================================================
--           2. AN OFFICER'S NPC MISSION: ACCEPT, RUN, RESULT, PAYOUT
-- ============================================================================

local soloRun
do
    local src, cid = 1, CID[1]
    local run = AcceptPatrol(src)
    soloRun = run
    H.eq(run and run.missionId, 'beat_patrol', 'officer: Beat Patrol drawn')
    H.eq(run and run.cashBase, 250, 'officer: the Patrol pay is locked at accept')
    local view = Cb('getRun', src)
    H.eq(view and view.missionLabel, 'Beat Patrol', 'officer: Active Mission shows the drawn mission')
    local veh = StartPatrolRun(src, run)
    local mark = #H.events
    DriveCheckpoints(src, run, veh)
    H.eq(run.state, 'ended', 'officer: every checkpoint done: the run ended')
    H.eq(Runs.getBySrc(src), nil, 'officer: no longer on a run')
    local ended = ClientEvents('crimson-police:client:runEnded', src, mark)[1]
    local result = ended and ended.args[4]
    H.ok(type(result) == 'table', 'officer: the result screen is sent')
    H.eq(result and result.cash and result.cash.amount, 250, 'officer: ...with the $250 pay')
    local shown = result and result.items or {}
    H.eq(#shown, 1, 'officer: ...and the item he earned: ' .. cjson.encode(shown))
    H.eq(shown[1] and shown[1].name, 'water', 'officer: ...water')
    local r = Rows('run_uuid = ?', { run.id })[1] or {}
    H.eq(r.state, 'completed', 'officer: the row is completed')
    H.eq(r.cash_status, 'paid', 'officer: cash paid')
    H.eq(tonumber(r.cash_paid), 250, 'officer: $250')
    local n, amount = Paid(cid)
    H.eq(n, 1, 'officer: one Qbox AddMoney')
    H.eq(amount, 250, 'officer: ...of the row amount')
    H.eq(Xp(cid), tonumber(r.final_points), 'officer: XP = the row points')
    Secs(5)
    local items = ItemRows(cid)
    H.eq(#items, 1, 'officer: one item reward for the run (item rewards on, chance 1)')
    H.eq(items[1] and items[1].item, 'water', 'officer: ...water')
    H.eq(items[1] and tonumber(items[1].row_id), tonumber(r.id), 'officer: ...tied to the run row')
    H.eq(items[1] and items[1].status, 'given', 'officer: ...and given')
    H.eq(ItemsGiven(src, 'water'), 2, 'officer: ox_inventory got 2 water')
    H.eq(select(1, CP.Cash.pay(r.id)), 'paid', 'officer: a second pay only reports paid')
    H.eq(Paid(cid), 1, 'officer: still one AddMoney')
    Config.DisabledMissions = {}
end

-- ============================================================================
--                 3. A SAST + FIB UNIT: A CROSS-DEPARTMENT RUN
-- ============================================================================

do
    Config.DisabledMissions = TACTICAL_OTHERS
    local ok, data = Act('server:unitInvite', 6, 2)
    H.eq(ok, true, 'unit: SAST invites FIB: ' .. tostring(data))
    ok, data = Act('server:unitRespond', 2, { accepted = true, unitId = data and data.unitId })
    H.eq(ok, true, 'unit: the FIB agent accepts: ' .. tostring(data))
    Place(6, vec3(0.0, 0.0, 0.0))
    Place(2, vec3(5.0, 0.0, 0.0))
    ok, data = Act('server:acceptType', 6, 'tactical')
    H.eq(ok, true, 'unit: the leader accepts Tactical: ' .. tostring(data))
    local run = Runs.getBySrc(6)
    H.eq(run and run.missionId, 'gang_shootout', 'unit: Gang Shootout drawn')
    H.eq(Runs.getBySrc(2), run, 'unit: the partner is on the same run')
    Arrive(run, 6)
    Arrive(run, 2)
    H.eq(run.state, 'in_progress', 'unit: in progress')
    H.eq(run.payTier and run.payTier.tier, 'reinforced', 'unit: two officers: Reinforced')
    Place(6, run.location.start.coords)
    Place(2, run.location.start.coords)
    ClearHostiles(run, 6)
    H.eq(run.objectiveIndex, 2, 'unit: every hostile neutralised')
    Place(2, run.location.scene)
    SecureScene(run, 6)
    H.eq(run.state, 'ended', 'unit: Gang Shootout completed')
    local rows = Rows('run_uuid = ?', { run.id })
    H.eq(#rows, 2, 'unit: one row per member')
    for _, r in ipairs(rows) do
        H.eq(r.state, 'completed', r.citizenid .. ': completed')
        H.eq(tonumber(r.departments_n), 2, r.citizenid .. ': two departments')
        H.eq(tonumber(r.cash_paid), 920, r.citizenid .. ': round($800 x 1.15) = $920')
        local bd = U.jsonField(r.breakdown) or {}
        H.eq(bd.points and bd.points.mCross, 1.10, r.citizenid .. ': cross-department x1.10')
        H.eq(bd.points and bd.points.mTeam, 1.10, r.citizenid .. ': unit x1.10')
    end
    Secs(5)
    for _, src in ipairs({ 6, 2 }) do
        H.eq(ItemsGiven(src, 'water'), 2, ('unit: %s got the tactical item'):format(CID[src]))
    end
    CP.Units.remove(6, { reason = 'left', silent = true })
    CP.Units.remove(2, { reason = 'left', silent = true })
    Config.DisabledMissions = {}
end

-- ============================================================================
--                              4. A MISSION CALL
-- ============================================================================
-- A SUPERVISOR CREATES IT, AN OFFICER CLAIMS IT.

do
    Config.DisabledMissions = PATROL_OTHERS
    local area
    for _, a in ipairs(Config.MissionCalls.areas) do if a.key == 'south_ls' then area = a end end
    Place(6, vec3(area.center.x + 300.0, area.center.y, area.center.z))
    Place(3, vec3(area.center.x - 300.0, area.center.y, area.center.z))
    Secs(12)
    local ok, data = Act('server:sup:mcCreate', 6, { type = 'patrol', area = 'south_ls' })
    H.eq(ok, false, 'call: an officer cannot create a call (' .. tostring(data) .. ')')
    ok, data = Act('server:sup:mcCreate', 3, { type = 'patrol', area = 'south_ls' })
    H.eq(ok, true, 'call: the SAST supervisor creates a Patrol call in South Los Santos: ' .. tostring(data))
    local callId = data and data.id
    local function CallRow()
        return H.sql('SELECT code, status, claimed_by, run_uuid FROM cp_mission_calls WHERE id = ?', { callId })[1]
            or {}
    end
    H.eq(CallRow().status, 'open', 'call: open')
    local listed = false
    for _, c in ipairs((CP.MissionCalls.list(6) or {}).calls or {}) do if c.id == callId then listed = true end end
    H.eq(listed, true, 'call: the officer sees it on Dispatch')
    ok, data = Act('server:claimMissionCall', 6, { callId = callId })
    H.eq(ok, true, 'call: the officer claims it: ' .. tostring(data))
    local run = Runs.getBySrc(6)
    H.ok(run ~= nil and run.missionCall ~= nil, 'call: the run carries the call')
    H.eq(run and run.missionCall and run.missionCall.code, CallRow().code, 'call: ...this call')
    H.eq(run and run.missionId, 'beat_patrol', 'call: a Patrol mission is drawn')
    H.eq(CallRow().status, 'claimed', 'call: claimed')
    ok = Act('server:claimMissionCall', 1, { callId = callId })
    H.eq(ok, false, 'call: a second claim is refused')
    local veh = StartPatrolRun(6, run)
    DriveCheckpoints(6, run, veh)
    H.eq(run.state, 'ended', 'call: the call\'s run completed')
    local r = Rows('run_uuid = ?', { run.id })[1] or {}
    H.eq(r.state, 'completed', 'call: the row is completed')
    H.eq(r.cash_status, 'paid', 'call: paid')
    H.eq(tonumber(r.cash_paid), 250, 'call: $250')
    H.eq(CallRow().run_uuid, run.id, 'call: the call names its run')
    Config.DisabledMissions = {}
end

-- ============================================================================
--                      5. SUPERVISOR CONTROLS AND AWARDS
-- ============================================================================
-- A Mission control, a cooldown clear, Give points with its default money and items.

do
    -- Beat Patrol is on cooldown for the solo officer after section 2: the Patrol pool is empty for him
    Config.DisabledMissions = PATROL_OTHERS
    Place(1, vec3(150.0, -1200.0, 29.0))
    local ok, data = Act('server:acceptType', 1, 'patrol')
    H.eq(ok, false, 'controls: Beat Patrol is on cooldown for the officer (' .. tostring(data) .. ')')
    ok, data = Act('server:sup:clearCooldowns', 1,
        { citizenid = CID[6], scope = 'mission', key = 'beat_patrol', reason = 'H7 e2e' })
    H.eq(ok, false, 'controls: an officer cannot clear cooldowns (' .. tostring(data) .. ')')
    ok, data = Act('server:sup:clearCooldowns', 3,
        { citizenid = CID[1], scope = 'mission', key = 'beat_patrol', reason = 'Training ride' })
    H.eq(ok, true, 'controls: the SAST supervisor clears it: ' .. tostring(data))
    H.eq(Runs.cooldowns(CID[1]).missions.beat_patrol, nil, 'controls: the mission cooldown is gone')
    ok, data = Act('server:acceptType', 1, 'patrol')
    H.eq(ok, true, 'controls: the officer may take Beat Patrol again: ' .. tostring(data))
    local run = Runs.getBySrc(1)
    if run then Act('server:abandon', 1, run.id) end
    Secs(2)
    Config.DisabledMissions = {}

    -- a Mission control: the hourly cap, inside the admin's bounds, with a reason
    ok, data = Act('server:sup:setMissionControl', 1,
        { key = 'hourlyCap', value = 6, reason = 'officer', requestId = RequestId() })
    H.eq(ok, false, 'controls: an officer cannot change a control (' .. tostring(data) .. ')')
    ok, data = Act('server:sup:setMissionControl', 3,
        { key = 'hourlyCap', value = 99, reason = 'too many', requestId = RequestId() })
    H.eq(ok, false, 'controls: a value out of the admin\'s bounds is refused (' .. tostring(data) .. ')')
    ok, data = Act('server:sup:setMissionControl', 3,
        { key = 'hourlyCap', value = 6, reason = 'Busy night', requestId = RequestId() })
    H.eq(ok, true, 'controls: the supervisor sets the hourly cap to 6: ' .. tostring(data))
    local mine, why = Cb('sup:getMyControls', 3)
    H.ok(mine ~= nil, 'controls: Your controls today answers: ' .. tostring(why))
    local cap
    for _, c in ipairs(mine and mine.controls or {}) do if c.key == 'hourlyCap' then cap = c end end
    H.eq(cap and cap.value, 6, 'controls: ...and shows the hourly cap at 6')
    H.eq(cap and cap.changed, true, 'controls: ...changed from config.lua')

    -- Give points: corrections row, the default $5 a point and the award's items, once
    ok, data = Act('server:sup:awardPoints', 4, { citizenid = CID[1], points = 20, reason = 'Great scene work' })
    H.eq(ok, false, 'award: a FIB supervisor cannot give points to SAST (' .. tostring(data) .. ')')
    ok, data = Act('server:sup:awardPoints', 3, { citizenid = CID[3], points = 20, reason = 'Myself' })
    H.eq(ok, false, 'award: never to himself (' .. tostring(data) .. ')')
    Secs(11)                                 -- one award per officer per 10 s
    local xp0 = Xp(CID[1])
    local n0, amount0 = Paid(CID[1])
    local water0 = ItemsGiven(1, 'water')
    ok, data = Act('server:sup:awardPoints', 3, { citizenid = CID[1], points = 20, reason = 'Great scene work' })
    H.eq(ok, true, 'award: the SAST supervisor gives 20 points: ' .. tostring(data))
    Secs(5)
    H.eq(Xp(CID[1]) - xp0, 20, 'award: +20 XP')
    local n1, amount1 = Paid(CID[1])
    H.eq(n1 - n0, 1, 'award: one payment')
    H.eq(amount1 - amount0, 100, 'award: 20 points x $5 = $100 (the default money)')
    H.eq(ItemsGiven(1, 'water') - water0, 1, 'award: ...and the award\'s item')
    local rows = H.sql([[SELECT mission_id, cash_base FROM cp_mission_runs WHERE citizenid = ?
        AND mission_id = 'reward_supAward']], { CID[1] })
    H.eq(#rows, 1, 'award: one feature reward row')
    H.eq(tonumber(rows[1] and rows[1].cash_base), 100, 'award: ...of $100')

    -- Commend: on as shipped
    H.eq((H.sql('SELECT department FROM cp_officers WHERE citizenid = ?', { CID[1] })[1] or {}).department, 'sast',
        'commend: the officer\'s saved department')
    ok, data = Act('server:sup:commend', 3,
        { citizenid = CID[1], kind = 'valor', citation = 'Held the line at the shootout without backup.' })
    H.eq(ok, true, 'commend: the supervisor commends the officer: ' .. tostring(data))
    local list = CP.Profile.commendations(CID[1]) or {}
    H.eq(#list, 1, 'commend: his profile lists one commendation')
end

-- ============================================================================
--                         6. REVIEW, VOID AND DISPUTE
-- ============================================================================

do
    -- approve: the held cash and the held items are given once
    local cid = CID[7]
    local r = FlaggedPatrol(7, vec3(3000.0, 3000.0, 30.0))
    H.eq(Bit(r.flagged), true, 'review: the row is flagged')
    H.eq(r.cash_status, 'held', 'review: cash held')
    Secs(5)
    H.eq(Paid(cid), 0, 'review: nothing paid while flagged')
    local items = ItemRows(cid)
    H.eq(items[1] and items[1].status, 'held', 'review: the run\'s items are held too')
    H.eq(ItemsGiven(7, 'water'), 0, 'review: ...and not given')
    local queue = Cb('review:getQueue', 4)
    local seen = false
    for _, f in ipairs(H.reviewItems(queue, 'flag')) do if f.id == r.id or f.rowId == r.id then seen = true end end
    H.eq(seen, true, 'review: the run is in the FIB supervisor\'s Review Queue')
    local ok, data = Act('server:review:decide', 3, { type = 'flag', id = r.id, decision = 'approve', reason = 'SAST' })
    H.eq(ok, false, 'review: a SAST supervisor cannot review a FIB run (' .. tostring(data) .. ')')
    ok, data = Act('server:review:decide', 4, { type = 'flag', id = r.id, decision = 'approve', reason = 'GPS glitch' })
    H.eq(ok, true, 'review: the FIB supervisor approves: ' .. tostring(data))
    Secs(5)
    r = Rows('id = ?', { r.id })[1] or {}
    H.eq(Bit(r.flagged), false, 'review: no longer flagged')
    H.eq(r.cash_status, 'paid', 'review: the held cash is paid')
    H.eq(select(2, Paid(cid)), 250, 'review: $250')
    H.eq(ItemsGiven(7, 'water'), 2, 'review: the held items are given')
    ok = Act('server:review:decide', 4, { type = 'flag', id = r.id, decision = 'approve', reason = 'again' })
    H.eq(ok, false, 'review: a second approval is refused')
    H.eq(Paid(cid), 1, 'review: ...and pays nothing more')

    -- void, then the officer's dispute is approved: the run is restored, its cash and items released
    Act('server:sup:clearCooldowns', 4, { citizenid = cid, scope = 'mission', key = 'beat_patrol', reason = 'again' })
    local v = FlaggedPatrol(7, vec3(-3000.0, 3000.0, 30.0))
    local xpFlagged = Xp(cid)
    ok, data = Act('server:review:decide', 4, { type = 'flag', id = v.id, decision = 'void', reason = 'teleport' })
    H.eq(ok, true, 'void: the FIB supervisor voids it: ' .. tostring(data))
    v = Rows('id = ?', { v.id })[1] or {}
    H.eq(Bit(v.voided), true, 'void: voided')
    H.eq(v.cash_status, 'held', 'void: the cash stays held during the dispute window')
    H.eq(Xp(cid), xpFlagged, 'void: no XP was ever counted')
    ok, data = Act('server:dispute', 1, { rowId = v.id, reason = 'not mine' })
    H.eq(ok, false, 'dispute: nobody disputes someone else\'s run (' .. tostring(data) .. ')')
    ok, data = Act('server:dispute', 7, { rowId = v.id, reason = 'My game crashed and respawned me, check the log' })
    H.eq(ok, true, 'dispute: the officer disputes the void: ' .. tostring(data))
    local disputeId = data and (data.id or data.disputeId)
    for _, d in ipairs(CP.Disputes.forSupervisor(4) or {}) do
        if d.rowId == v.id then disputeId = disputeId or d.id end
    end
    H.ok(disputeId ~= nil, 'dispute: in the FIB supervisor\'s Review Queue')
    ok, data = Act('server:review:decide', 4,
        { type = 'dispute', id = disputeId, decision = 'approve', reason = 'crash' })
    H.eq(ok, true, 'dispute: approved: ' .. tostring(data))
    Secs(5)
    v = Rows('id = ?', { v.id })[1] or {}
    H.eq(Bit(v.voided), false, 'dispute: the run is restored')
    H.eq(v.cash_status, 'paid', 'dispute: its held cash is paid')
    H.eq(select(2, Paid(cid)), 500, 'dispute: $250 more')
    H.eq(Xp(cid) - xpFlagged, tonumber(v.final_points), 'dispute: XP given')
    H.eq(ItemsGiven(7, 'water'), 4, 'dispute: the run\'s items are given too')
end

return H

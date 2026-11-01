-- End-to-end scenarios for real suspects (step V27) on the REAL server side of Crimson-Police: every server file
-- loaded as in game, database off (the saves folder, as shipped), only the other resources and the natives stubbed.

local H = dofile('tests/harness.lua')
H.useFiles()
H.db = (os.getenv('CP_TEST_DB') or 'cp_test') .. '_rs_e2e'
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
_G.GetPedSourceOfDeath = function() return 0 end
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
-- Crimson-Contracts is the only script allowed to report a crime (Config.LiveCrime.sources).
local invoking = nil
_G.GetInvokingResource = function() return invoking end
local identifiers = {}  -- [src] = { 'license:...', ... }
_G.GetPlayerIdentifiers = function(src) return identifiers[tonumber(src)] or {} end
_G.GetNumPlayerIdentifiers = function(src) return #(identifiers[tonumber(src)] or {}) end
_G.GetPlayerIdentifier = function(src, i) return (identifiers[tonumber(src)] or {})[(i or 0) + 1] end
_G.GetPlayerIdentifierByType = function(src, kind)
    for _, id in ipairs(identifiers[tonumber(src)] or {}) do
        if id:sub(1, #kind + 1) == kind .. ':' then return id end
    end
    return nil
end
_G.GetPlayerTokens = function() return {} end
_G.GetNumPlayerTokens = function() return 0 end
_G.GetPlayerToken = function() return nil end
_G.GetPlayerEndpoint = function(src) return '10.0.0.' .. tostring(src) end
_G.GetPlayers = function()
    local out = {}
    for src in pairs(H.players) do out[#out + 1] = tostring(src) end
    table.sort(out)
    return out
end

-- ============================================================================
--                       EXPORTS OF THE OUTSIDE RESOURCES
-- ============================================================================

local PD = {}           -- src -> Qbox PlayerData
local function AddPlayer(src, cid, first, last, job, grade)
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
        metadata = {
            callsign = 'C-' .. src,
            isdead = false,
            inlaststand = false,
            ishandcuffed = false,
            injail = 0,
        },
    }
    identifiers[src] = { 'license:' .. cid:lower(), 'discord:' .. src }
    H.players[src] = { coords = vec3(0.0, 0.0, 0.0), ace = {}, state = {} }
end
local function QbxPlayer(src)
    local pd = PD[tonumber(src)]
    if not pd then return nil end
    return { PlayerData = pd, Functions = {
        AddMoney = function() return true end,
    } }
end
H.exportsMock.qbx_core = {
    GetPlayer = function(src) return QbxPlayer(src) end,
    GetPlayerByCitizenId = function(cid)
        for src, pd in pairs(PD) do if pd.citizenid == cid then return QbxPlayer(src) end end
        return nil
    end,
    GetQBPlayers = function()
        local out = {}
        for src in pairs(PD) do out[src] = QbxPlayer(src) end
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
H.exportsMock.ox_inventory = {
    AddItem = function() return true end,
    Search = function() return {} end,
    RemoveItem = function() return true end,
}
H.exportsMock.ox_target = {}

-- ============================================================================
--                                   PLAYERS
-- ============================================================================

AddPlayer(1, 'RSE2EOF1', 'Ada', 'Trooper', 'sast', 1)        -- the unit leader
AddPlayer(2, 'RSE2EOF2', 'Ben', 'Agent', 'fib', 1)           -- his partner
AddPlayer(9, 'RSE2ECR9', 'Cal', 'Crook', 'unemployed', 0)    -- crew member A of the reported crime
AddPlayer(10, 'RSE2EC10', 'Dee', 'Crook', 'unemployed', 0)   -- crew member B
AddPlayer(11, 'RSE2EV11', 'Eli', 'Runner', 'unemployed', 0)  -- the volunteer
local CID = {}
for src, pd in pairs(PD) do CID[src] = pd.citizenid end

-- ============================================================================
--                            LOAD THE REAL RESOURCE
-- ============================================================================

local loadedFiles = {}
do
    local p = io.popen(
        'cd ' .. H.root .. ' && find modules -name server.lua | sort && find blocks -name server.lua | sort')
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
--                                   HELPERS
-- ============================================================================

local function Place(src, c) H.players[src].coords = vec3(c.x + 0.0, c.y + 0.0, c.z + 0.0) end
local reqN = 0
local function Act(name, src, payload)
    reqN = reqN + 1
    local id = 'rse2e' .. reqN
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
-- Crimson-Contracts' server-only lifecycle event (its step VC3), sent from its own resource.
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
-- Every vec3 in a value (client event arguments), as 'x,y' strings.
local function Points(v, out, seen)
    out, seen = out or {}, seen or {}
    if type(v) == 'table' then
        if seen[v] then return out end
        seen[v] = true
        if type(v.x) == 'number' and type(v.y) == 'number' then
            out[#out + 1] = ('%.0f,%.0f'):format(v.x, v.y)
        end
        for _, x in pairs(v) do Points(x, out, seen) end
    end
    return out
end
-- Whether any client event to the officers since mark carries the point c (to the metre).
local function OfficersSaw(c, since, officers)
    local want = ('%.0f,%.0f'):format(c.x, c.y)
    for i = (since or 0) + 1, #H.events do
        local e = H.events[i]
        if e.kind == 'client' then
            local to = officers[e.target] or e.target == -1
            if to then
                for _, p in ipairs(Points(e.args)) do if p == want then return true end end
            end
        end
    end
    return false
end

local Runs = CP.Runs
local OFFICERS = { [1] = true, [2] = true }

local function FormUnit(leader, member)
    local ok, data = Act('server:unitInvite', leader, member)
    H.eq(ok, true, ('unit invite %d -> %d: %s'):format(leader, member, tostring(data)))
    ok, data = Act('server:unitRespond', member, { accepted = true, unitId = data and data.unitId })
    H.eq(ok, true, ('invite accepted by %d: %s'):format(member, tostring(data)))
end

local CRIME_AT = vec3(1200.0, -1300.0, 35.0)    -- the reported place (Elysian Island, no no-start zone)
local function Report(n, members)
    local list = {}
    for _, src in ipairs(members) do list[CID[src]] = src end
    Contracts('contractStarted', {
        id = n,
        uid = n .. '_1',
        key = 'warehouse_burglary',
        label = 'Warehouse Burglary',
        locationLabel = 'Elysian Island',
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
        street = 'Elysian Fields Fwy',
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

-- ============================================================================
--           1. AS SHIPPED: LIVE CRIMES AND VOLUNTEERS CHANGE NOTHING
-- ============================================================================

do
    H.eq(Config.LiveCrime.enabled, false, 'shipped: live crimes off')
    H.eq(Config.Volunteers.enabled, false, 'shipped: volunteers off')
    for key, mode in pairs(Config.Volunteers.modes) do H.eq(mode, 'npc', 'shipped: ' .. key .. ' plays the NPC') end
    for src = 9, 10 do Place(src, vec3(CRIME_AT.x + src, CRIME_AT.y, CRIME_AT.z)) end
    Place(1, vec3(400.0, -980.0, 30.0))
    Place(2, vec3(402.0, -980.0, 30.0))
    local mark = #H.events
    Report(1, { 9, 10 })
    H.eq(CP.MissionCalls.liveCount(), 0, 'shipped: a reported crime posts no LIVE call')
    H.eq(#LiveCards(1), 0, 'shipped: Dispatch shows no LIVE card')
    H.eq(#ClientEvents('crimson-police:client:missionCall', nil, mark), 0, 'shipped: no LIVE toast')
    H.eq(CP.LiveCrime.availablePolice(), nil, 'shipped: GetAvailablePolice answers nil')

    mark = #H.events
    Place(11, vec3(-500.0, -200.0, 35.0))
    H.fire('crimson-police:server:volunteer', 11, 'join', { roles = { runner = true } })
    local notes = ClientEvents('crimson-police:client:volunteerNote', 11, mark)
    H.eq(notes[1] and notes[1].args[2], 'volunteer.refused.off', 'shipped: /crimsonheat is refused (off)')
    H.eq(#CP.Volunteers.list(), 0, 'shipped: nobody is on the volunteer list')

    local board = Cb('getMissionTypes', 1)
    for _, card in ipairs(board and board.cards or {}) do
        H.eq(card.realSuspect, nil, 'shipped: no Real suspect badge on ' .. tostring(card.key))
    end
    H.eq(CP.Opponents.active(), false, 'shipped: no case is open')
end

FormUnit(1, 2)

-- ============================================================================
--                               2. A LIVE CRIME
-- ============================================================================
-- REPORT, CLAIM, SECURE, CUFF, GET AWAY, END CASE.

local liveRun
do
    Config.LiveCrime.enabled = true
    Config.LiveCrime.lastReportedEvery = 60
    -- the crime's second report: crew A and B stand at the place, both suspects
    for src = 9, 10 do Place(src, vec3(CRIME_AT.x + src, CRIME_AT.y, CRIME_AT.z)) end
    Secs(20)
    local mark = #H.events
    Report(2, { 9, 10 })
    H.eq(CP.MissionCalls.liveCount(), 1, 'live: the reported crime posts one LIVE call')
    local cards = LiveCards(1)
    H.eq(#cards, 1, 'live: Dispatch shows the LIVE card')
    local card = cards[1] or {}
    H.eq(card.suspects, 2, 'live: the card counts two suspects')
    H.eq(#ClientEvents('crimson-police:client:missionCall', 1, mark), 1, 'live: the idle leader gets the red toast')
    H.ok(not OfficersSaw(H.players[9].coords, mark, OFFICERS), 'live: no suspect position reaches officers')
    H.eq(CP.LiveCrime.availablePolice(), 2, 'live: GetAvailablePolice counts the two idle officers')

    local ok, data = Act('server:claimMissionCall', 1, { callId = card.id })
    H.eq(ok, true, 'live: the leader claims the LIVE call: ' .. tostring(data))
    liveRun = Runs.getBySrc(1)
    H.ok(liveRun ~= nil and liveRun.realSuspect == 'live', 'live: the case opened as a live run')
    H.eq(liveRun and liveRun.missionType, 'investigation', 'live: points of the crime\'s mission type')
    H.ok(Runs.getBySrc(2) == liveRun, 'live: the partner is on the case')
    H.eq(CP.Opponents.active(), true, 'live: the suspects\' case is open')
end

local liveEnded
do
    local run = liveRun
    local case = CP.Opponents.caseOf(run)
    local recA = case and case.suspects[CID[9]]
    local recB = case and case.suspects[CID[10]]
    H.ok(recA ~= nil and recB ~= nil, 'live: both crew members are suspects of the case')
    -- B drives off and keeps moving: one new place every second, 900 m and more from the scene
    local bSeen, bPlaces = 0, 0
    local function MoveB(i)
        Place(10, vec3(CRIME_AT.x + 900.0 + i * 7.0, CRIME_AT.y + 400.0, CRIME_AT.z))
    end
    -- the officers reach the scene (Respond), next to A, and hold it for secureSeconds (Secure the scene)
    Place(1, vec3(CRIME_AT.x + 5.0, CRIME_AT.y, CRIME_AT.z))
    Place(2, vec3(CRIME_AT.x + 7.0, CRIME_AT.y, CRIME_AT.z))
    local places, start = {}, #H.events
    for i = 1, 75 do
        MoveB(i)
        bPlaces = bPlaces + 1
        places[('%.0f,%.0f'):format(H.players[10].coords.x, H.players[10].coords.y)] = true
        Secs(1)
    end
    local seen = {}
    for i = start + 1, #H.events do
        local e = H.events[i]
        if e.kind == 'client' and (OFFICERS[e.target] or e.target == -1) then
            for _, pt in ipairs(Points(e.args)) do if places[pt] then seen[pt] = true end end
        end
    end
    bSeen = U.count(seen)
    local st = Runs.ctx(run, 1).state
    H.eq(st and st.phase, 'detain', 'live: the scene is secured after secureSeconds on scene')
    H.ok(bSeen <= 2, (
        'live: B moved %d times, officers got %d of his places (only the last reported, '
        .. 'every lastReportedEvery)'
    ):format(bPlaces, bSeen))
    H.ok(bSeen >= 1, 'live: the last reported point of B does reach the officers')
    local view = CP.LiveCrime.caseView(run, 1) or {}
    H.eq(view.reportsOn, true, 'live: the case card has last reported points')
    H.ok(type(view.reportedAgoS) == 'number' and view.reportedAgoS < 60, 'live: ...says how old they are')
    H.ok(type(view.nextReportS) == 'number' and view.nextReportS <= 60, 'live: ...and when the next comes')
    H.eq(#Points(view), 0, 'live: the case card itself carries no position')

    -- A is downed (by anyone) next to the officers, then cuffed by the leader: he counts neutralisedShare only
    Meta(9, 'isdead', true)
    Secs(1)
    Place(1, vec3(H.players[9].coords.x + 1.5, CRIME_AT.y, CRIME_AT.z))   -- sc-police's reach (cuffRange)
    H.fire('police:server:CuffPlayer', 1, 9, false)
    Meta(9, 'ishandcuffed', true)
    Secs(Config.RealSuspects.custodyHoldSeconds + 3)
    H.eq(recA.state, 'detained', 'live: A is detained once the cuffs held custodyHoldSeconds')
    H.eq(recA.share, Config.RealSuspects.neutralisedShare, 'live: A was down, so his detain counts neutralisedShare')
    H.eq(st.lines.live_detain[CID[9]], Config.RealSuspects.neutralisedShare, 'live: the detain line is weighted')

    -- the leader ends the case from the radial menu (End case); B is still free and far away
    local mark = #H.events
    H.fire('crimson-police:server:objective', 1, run.id, 1, { type = 'end_case' })
    Secs(3)
    H.eq(run.state, 'ended', 'live: End case ends the case')
    liveEnded = LocalEvents('crimson-police:server:liveCrimeEnded', mark)[1]
end

do
    local p = liveEnded or {}
    H.ok(liveEnded ~= nil, 'live: liveCrimeEnded is sent once the case ends')
    H.eq(p.resource, 'crimson-contracts', 'live: ...naming the reporting script')
    H.eq(p.uid, '2_1', 'live: ...and its crime')
    H.eq(p.suspects and p.suspects[CID[9]], 'detained', 'live: A detained')
    H.eq(p.suspects and p.suspects[CID[10]], 'got_away', 'live: B got away')
    H.eq(p.caught, 1, 'live: one caught')
    H.eq(p.officers, 2, 'live: two officers')
    H.eq(p.coords, nil, 'live: no position in the payload')

    local rows = H.sql(
        'SELECT citizenid, state, end_reason, final_points, cash_paid, live_catches FROM '
            .. 'cp_mission_runs WHERE run_uuid = ? ORDER BY citizenid',
        { liveRun.id }
    )
    H.eq(#rows, 2, 'live: one run row per officer')
    for _, r in ipairs(rows) do
        H.eq(r.state, 'completed', 'live: ' .. r.citizenid .. ' completed')
        H.ok((tonumber(r.final_points) or 0) > 0, 'live: ' .. r.citizenid .. ' earned the live lines')
        H.eq(tonumber(r.cash_paid) or 0, 0, 'live: points only (Config.LiveCrime.cash = false)')
        H.eq(tonumber(r.live_catches), 1, 'live: one live catch')
    end

    -- staff read the closed case: its timeline names the steps
    local case = CP.Opponents.findCase(liveRun.id)
    local whats = {}
    for _, e in ipairs(case and case.timeline or {}) do whats[e.what] = true end
    H.ok(case ~= nil, 'live: staff can still read the closed case')
    for _, w in ipairs({ 'responded', 'scene_secured', 'end_case' }) do
        H.ok(whats[w] == true, 'live: the timeline has ' .. w)
    end
    H.eq(CP.Opponents.active(), false, 'live: no case open any more')
end

-- ============================================================================
--                            3. A VOLUNTEER SUSPECT
-- ============================================================================
-- OPT IN, ASKED, YES, TRAVEL, REACHED, CUFFED.

local volRun, VolMatch
do
    Config.LiveCrime.enabled = false
    Config.Volunteers.enabled = true
    Config.Volunteers.modes.investigation = 'players_when_available'
    -- Investigation's pool is Warrant Service only, at one location
    Config.DisabledMissions = { 'manhunt', 'suspicious_activity' }
    local def = CP.Missions.get('warrant_service')
    local savedLocations = def.locations
    def.locations = { def.locations[1] }

    -- he volunteers (/crimsonheat: the rules alert and the roles are his game's; the server gets the roles)
    Place(11, vec3(-300.0, 6100.0, 31.0))
    local mark = #H.events
    H.fire('crimson-police:server:volunteer', 11, 'join', { roles = { runner = true } })
    local notes = ClientEvents('crimson-police:client:volunteerNote', 11, mark)
    H.eq(notes[1] and notes[1].args[2], 'volunteer.started', 'volunteer: /crimsonheat puts him on the list')
    H.eq(CP.Volunteers.isListed(CID[11]), true, 'volunteer: he is listed')

    -- the unit accepts Investigation with Real suspect OK ticked
    Place(1, vec3(-200.0, 6000.0, 31.0))
    Place(2, vec3(-202.0, 6000.0, 31.0))
    mark = #H.events
    local ok, data = Act('server:acceptType', 1, { missionType = 'investigation', realSuspect = true })
    H.eq(ok, true, 'volunteer: the unit accepts Investigation with Real suspect OK: ' .. tostring(data))
    H.fire('crimson-police:server:unitReady', 2, { accepted = true })
    Secs(3)
    volRun = Runs.getBySrc(1)
    H.eq(volRun and volRun.missionId, 'warrant_service', 'volunteer: Warrant Service drawn')
    local asks = ClientEvents('crimson-police:client:volunteerAsk', 11, mark)
    H.eq(#asks, 1, 'volunteer: he is asked first (a yes/no pop-up)')
    H.eq(volRun and volRun.realSuspect, nil, 'volunteer: no real suspect before his yes')
    local token = asks[1] and asks[1].args[1]
    H.eq(asks[1] and asks[1].args[2] and asks[1].args[2].role, 'runner', 'volunteer: ...naming the suspect he plays')

    -- yes: his case opens and he travels to the door
    mark = #H.events
    H.fire('crimson-police:server:volunteer', 11, 'answer', { token = token, yes = true })
    Secs(2)
    H.eq(volRun.realSuspect, 'volunteer', 'volunteer: his yes makes it a case with a real suspect')
    local travel = ClientEvents('crimson-police:client:volunteerCase', 11, mark)
    local meet = travel[1] and travel[1].args[1] and travel[1].args[1].meet
    H.ok(meet ~= nil, 'volunteer: he gets the starting point as his waypoint')
    for src in pairs(OFFICERS) do
        local told = false
        for _, e in ipairs(ClientEvents('crimson-police:client:notify', src, mark)) do
            if e.args[1].key == 'volunteer.officer.yes' then told = true end
        end
        H.ok(told, ('volunteer: officer %d is told a volunteer plays the suspect'):format(src))
    end
    VolMatch = function() return CP.Volunteers.matchOf(CID[11]) or {} end
    if meet then Place(11, vec3(meet.x + 1.0, meet.y, meet.z)) end
    Secs(3)
    H.eq(VolMatch().phase, 'in_position', 'volunteer: in position at the door')

    -- the officers drive to the start and reach him (contactRange): the case is engaged
    local start = volRun.location.start.coords
    Place(1, start)
    Place(2, vec3(start.x + 2.0, start.y, start.z))
    Secs(3)
    if meet then
        Place(1, vec3(meet.x + 3.0, meet.y, meet.z))
        Place(2, vec3(meet.x + 5.0, meet.y, meet.z))
    end
    Secs(3)
    H.eq(VolMatch().phase, 'engaged', 'volunteer: officers reached him: engaged')

    -- the leader knocks and announces at the door: the knock says the wanted person is a real player
    local door = volRun.location.door
    H.ok(door ~= nil and door.x ~= nil, 'volunteer: the location has its door')
    if door and door.x then Place(1, vec3(door.x + 0.5, door.y, door.z)) end
    mark = #H.events
    H.fire('crimson-police:server:objective', 1, volRun.id, 1, { type = 'knock_start' })
    Secs(4)
    H.fire('crimson-police:server:objective', 1, volRun.id, 1, { type = 'knock' })
    Secs(2)
    local said = false
    for i = mark + 1, #H.events do
        local e = H.events[i]
        if e.kind == 'client' and e.target == 1
            and cjson.encode(e.args):find('the wanted person is a real player', 1, true) then
            said = true
        end
    end
    H.ok(said, 'volunteer: the knock tells the officers a real player is the wanted person')

    -- he is cuffed at the door and the cuffs hold
    if meet then Place(1, vec3(meet.x + 2.0, meet.y, meet.z)) end
    Secs(1)
    H.fire('police:server:CuffPlayer', 1, 11, false)
    Meta(11, 'ishandcuffed', true)
    Secs(Config.RealSuspects.custodyHoldSeconds + 3)
    local _, rec = CP.Opponents.byCid(CID[11])
    H.eq(rec and rec.state, 'detained', 'volunteer: detained once the cuffs held')
    H.eq(rec and rec.share, 1, 'volunteer: up and not AFK: a full catch')
    H.eq(volRun.objectives[1].status, 'done', 'volunteer: cuffing him completes Serve the arrest warrant')

    -- the unit leaves the rest of the mission: the run ends
    mark = #H.events
    Act('server:abandon', 1, volRun.id)
    Act('server:abandon', 2, volRun.id)
    Secs(2)
    H.eq(volRun.state, 'ended', 'volunteer: the mission ends')
    local ended = LocalEvents('crimson-police:server:volunteerEnded', mark)[1] or {}
    H.eq(ended.citizenid, CID[11], 'volunteer: volunteerEnded names him by citizenid')
    H.eq(ended.role, 'runner', 'volunteer: ...the suspect he played')
    H.eq(ended.outcome, 'detained', 'volunteer: ...his outcome')
    H.eq(ended.engaged, true, 'volunteer: ...officers reached him')
    H.eq(ended.coords, nil, 'volunteer: ...and no position')
    local free = ClientEvents('crimson-police:client:volunteerCase', 11, mark)
    H.eq(free[#free] and free[#free].args[1] and free[#free].args[1].phase, 'over', 'volunteer: he is told he is free')

    local case = CP.Opponents.findCase(volRun.id)
    local whats = {}
    for _, e in ipairs(case and case.timeline or {}) do whats[e.what] = true end
    for _, w in ipairs({ 'volunteer_yes', 'in_position', 'engaged' }) do
        H.ok(whats[w] == true, 'volunteer: staff read ' .. w .. ' on the case timeline')
    end

    -- opt-out: Stop on his /crimsonheat menu takes him off the list at once
    Secs(3)
    H.fire('crimson-police:server:volunteer', 11, 'stop')
    Secs(1)
    H.eq(CP.Volunteers.isListed(CID[11]), false, 'volunteer: Stop takes him off the list')

    def.locations = savedLocations
    Config.DisabledMissions = {}
end

return H

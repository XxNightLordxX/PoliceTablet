-- End-to-end scenarios for real suspects on the REAL server side of Crimson-Police: every server file
-- loaded as in game, database off (the saves folder, as shipped), only the other resources and the natives stubbed.
-- Sections 4 to 6: the admin turns it all on in the Admin UI, a volunteer by the criminal tablet, a strike.

-- End-to-end scenarios for real suspects on the REAL server side of Crimson-Police: every server file
-- loaded as in game, database off (the saves folder, as shipped), only the other resources and the natives stubbed.
-- 1. As shipped (Config.RealPlayers.liveCrime.enabled and Config.RealPlayers.volunteer.enabled false): a reported
-- crime, /crimsonheat and
--    the Mission Board change nothing.
-- 2. A live crime: Crimson-Contracts reports it, a unit claims the LIVE call, secures the scene, cuffs one suspect
--    and books nobody, the other gets away; the points, the case timeline, the end event and the pair rows.
-- 3. A volunteer suspect: a civilian volunteers with /crimsonheat, a unit accepts Investigation with Real suspect
--    OK, he says yes, travels, officers reach him and cuff him at Warrant Service's door; the end event.
-- The fairness rules docs/OWNER_GUIDE.md's "Rules for cases with real suspects" promise are checked on the way: officers never
-- get a suspect's live position, a suspect cuffed while down counts only Config.RealPlayers.neutralisedShare, the
-- volunteer is asked first and can say no, and staff read each case's timeline.

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
-- Crimson-Contracts is the only script allowed to report a crime (Config.RealPlayers.liveCrime.sources).
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
local offline = {}      -- src -> true while that player is disconnected (section 7)
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
    if not pd or offline[tonumber(src)] then return nil end
    return { PlayerData = pd, Functions = {
        AddMoney = function() return true end,
    } }
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
        'cd ' .. H.root .. ' && ls modules/system/storage.lua modules/adminkit/server.lua'
            .. ' modules/system/migrations.lua modules/system/schedule.lua'
            .. ' && find modules -name server.lua | sort'
            .. ' && ls modules/progression/*.lua modules/supervisor/*.lua modules/review/*.lua modules/realplayers/*.lua modules/dispatch/*.lua modules/teams/*.lua modules/money/*.lua'
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
    H.eq(Config.RealPlayers.liveCrime.enabled, false, 'shipped: live crimes off')
    H.eq(Config.RealPlayers.volunteer.enabled, false, 'shipped: volunteers off')
    for key, mode in pairs(Config.RealPlayers.volunteer.modes) do
        H.eq(mode, 'npc', 'shipped: ' .. key .. ' plays the NPC')
    end
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
    Config.RealPlayers.liveCrime.enabled = true
    Config.RealPlayers.liveCrime.lastReportedEvery = 60
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

    local ok, data = Act('server:answerMissionCall', 1, { callId = card.id })
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
    Secs(Config.RealPlayers.custodyHoldSeconds + 3)
    H.eq(recA.state, 'detained', 'live: A is detained once the cuffs held custodyHoldSeconds')
    H.eq(recA.share, Config.RealPlayers.neutralisedShare, 'live: A was down, so his detain counts neutralisedShare')
    H.eq(st.lines.live_detain[CID[9]], Config.RealPlayers.neutralisedShare, 'live: the detain line is weighted')

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
        H.eq(tonumber(r.cash_paid) or 0, 0, 'live: points only (Config.RealPlayers.liveCrime.cash = false)')
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
    Config.RealPlayers.liveCrime.enabled = false
    Config.RealPlayers.volunteer.enabled = true
    Config.RealPlayers.volunteer.modes.investigation = 'players_when_available'
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
    Secs(Config.RealPlayers.custodyHoldSeconds + 3)
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

-- ============================================================================
--                           4. THE ADMIN TURNS IT ON
-- ============================================================================
-- SETTINGS, A FEATURE SWITCH, A PERMISSION GRANT.
-- Step G7: every change goes through the Admin UI's own actions (Settings, the Features switches, Permissions ->
-- Extra grants), as the admin taps them.

AddPlayer(8, 'RSE2EAD8', 'Ann', 'Admin', 'unemployed', 0)    -- a Crimson-Police admin (Config.AdminAce)
H.players[8].ace[Config.AdminAce] = true
AddPlayer(12, 'RSE2EG12', 'Gus', 'Ballas', 'unemployed', 0)  -- a Ballas member who plays volunteer suspects
PD[12].gang = { name = 'ballas', label = 'Ballas', grade = { level = 1, name = 'Runner' } }
CID[8], CID[12] = PD[8].citizenid, PD[12].citizenid
H.exportsMock.qbx_core.GetGangs = function()
    return { ballas = { label = 'Ballas', grades = { [0] = { name = 'Recruit' }, [1] = { name = 'Runner' } } } }
end

-- Live control -> anti-farm: the admin clears both officers' cooldowns (they just played Investigation).
local function ClearCooldowns()
    for _, src in ipairs({ 1, 2 }) do
        local ok, err = Act('server:admin:clearCooldowns', 8,
            { citizenid = CID[src], scope = 'all', reason = 'G7 e2e' })
        H.eq(ok, true, ('admin: cooldowns of officer %d cleared: %s'):format(src, tostring(err)))
    end
end

-- One Settings change as the admin taps it -> ok, data | errKey.
local function Setting(src, path, value)
    return Act('server:admin:setSetting', src, { path = path, json = cjson.encode(value), reason = 'G7 e2e' })
end

do
    -- an officer and a player are never admins: the setting is refused and nothing changes
    local ok, err = Setting(1, 'RealPlayers.criminalTablet.enabled', true)
    H.eq(ok, false, 'admin: an officer cannot change a setting')
    H.ok(err ~= nil, 'admin: ...he is told why: ' .. tostring(err))
    H.eq(Config.RealPlayers.criminalTablet.enabled, false, 'admin: ...and the tablet stays off')
    local view, why = Cb('crimtab:get', 12)
    H.eq(view, nil, 'admin: shipped, the criminal tablet is off')
    H.eq(why, 'err.crimtab_off', 'admin: ...and says so')

    -- the admin switches on volunteers, the criminal tablet (the Features switch) and the volunteer's pay
    for _, c in ipairs({
        { 'RealPlayers.volunteer.enabled', true },
        {
            'RealPlayers.volunteer.modes',
            { patrol = 'npc', training = 'npc', investigation = 'players_when_available', tactical = 'npc' },
        },
        { 'RealPlayers.criminalTablet.enabled', true },
        { 'RealPlayers.criminalTablet.access', 'granted' },
        { 'FeatureRewards.suspect.enabled', true },
    }) do
        ok, err = Setting(8, c[1], c[2])
        H.eq(ok, true, ('admin: %s saved: %s'):format(c[1], tostring(err)))
    end
    H.eq(Config.RealPlayers.criminalTablet.enabled, true, 'admin: the Features switch turns the tablet on at once')
    H.eq(Config.FeatureRewards.suspect.enabled, true, 'admin: Pay volunteer suspects is on')
    H.eq(Config.FeatureRewards.suspect.money.got_away, 1500, 'admin: ...with its default money ready')

    -- access 'granted': nobody yet, until Permissions -> Extra grants names the Ballas from grade 1
    view, why = Cb('crimtab:get', 12)
    H.eq(why, 'err.crimtab_no_access', 'admin: granted access and no grant: the Ballas member is refused')
    ok, err = Setting(8, 'Permissions.grants', { criminalTablet = { gangs = { ballas = { minGrade = 1 } } } })
    H.eq(ok, true, 'admin: the criminalTablet grant for Ballas grade 1+ is saved: ' .. tostring(err))
    view, why = Cb('crimtab:get', 12)
    H.ok(view ~= nil, 'admin: the grant counts at once: the tablet opens: ' .. tostring(why))
    H.eq(view and view.volunteersOn, true, 'admin: ...and volunteers are on')
    H.eq(view and view.status and view.status.canJoin, true, 'admin: ...he may get on the list')
    view, why = Cb('crimtab:get', 11)
    H.eq(why, 'err.crimtab_no_access', 'admin: a player the grant does not name is still refused')
    view, why = Cb('crimtab:get', 1)
    H.eq(why, 'err.crimtab_on_duty', 'admin: an officer on duty is refused')
end

-- ============================================================================
--                    5. A VOLUNTEER BY THE CRIMINAL TABLET
-- ============================================================================
-- LIST, JOB, ACCEPT, ESCAPE, PAID.

local tabRun
do
    Config.DisabledMissions = { 'manhunt', 'suspicious_activity' }
    local def = CP.Missions.get('warrant_service')
    local savedLocations = def.locations
    def.locations = { def.locations[1] }

    -- Home: he gets on the list as a runner from the tablet
    Place(12, vec3(-300.0, 6100.0, 31.0))
    local ok, view = Act('server:crimtab:act', 12, { what = 'join', roles = { 'runner' } })
    H.eq(ok, true, 'crimtab: Get on the list: ' .. tostring(view))
    H.eq(view and view.status and view.status.listed, true, 'crimtab: Home shows him on the list')
    H.eq(CP.Volunteers.isListed(CID[12]), true, 'crimtab: the volunteer list has him')

    -- the unit accepts Investigation with Real suspect OK: the job reaches his Jobs screen, with its reward
    ClearCooldowns()
    Place(1, vec3(-200.0, 6000.0, 31.0))
    Place(2, vec3(-202.0, 6000.0, 31.0))
    ok, view = Act('server:acceptType', 1, { missionType = 'investigation', realSuspect = true })
    H.eq(ok, true, 'crimtab: the unit accepts Investigation with Real suspect OK: ' .. tostring(view))
    H.fire('crimson-police:server:unitReady', 2, { accepted = true })
    Secs(3)
    tabRun = Runs.getBySrc(1)
    H.eq(tabRun and tabRun.missionId, 'warrant_service', 'crimtab: Warrant Service drawn')
    view = Cb('crimtab:get', 12) or {}
    local job = view.jobs and view.jobs[1]
    H.ok(job ~= nil and type(job.token) == 'string', 'crimtab: Jobs shows the question')
    H.eq(job and job.role, 'runner', 'crimtab: ...naming the suspect he plays')
    local reward = job and job.reward or ''
    H.ok(type(reward) == 'string' and reward:find('1,500', 1, true) ~= nil and reward:find('500', 1, true) ~= nil,
        'crimtab: ...and the reward Pay volunteer suspects pays: ' .. tostring(reward))
    H.eq(#Points(job or {}), 0, 'crimtab: the job carries no position')

    -- Accept is his yes: Active shows the meet point; he travels there and officers reach him
    ok, view = Act('server:crimtab:act', 12, { what = 'answer', token = job and job.token, yes = true })
    H.eq(ok, true, 'crimtab: Accept: ' .. tostring(view))
    Secs(2)
    H.eq(tabRun.realSuspect, 'volunteer', 'crimtab: his yes makes it a real-suspect case')
    view = Cb('crimtab:get', 12) or {}
    local meet = view.active and view.active.meet
    H.ok(meet ~= nil, 'crimtab: Active shows his meet point')
    H.eq(view.active and view.active.phase, 'travel', 'crimtab: ...while he travels')
    H.eq(#view.jobs, 0, 'crimtab: Jobs is empty once he accepted')
    if meet then Place(12, vec3(meet.x + 1.0, meet.y, meet.z)) end
    Secs(3)
    local start = tabRun.location.start.coords
    Place(1, start)
    Place(2, vec3(start.x + 2.0, start.y, start.z))
    Secs(3)
    if meet then
        Place(1, vec3(meet.x + 3.0, meet.y, meet.z))
        Place(2, vec3(meet.x + 5.0, meet.y, meet.z))
    end
    Secs(3)
    local m = CP.Volunteers.matchOf(CID[12]) or {}
    H.eq(m.phase, 'engaged', 'crimtab: officers reached him: engaged')
    view = Cb('crimtab:get', 12) or {}
    H.eq(view.active and view.active.freeCancel, false, 'crimtab: once engaged, giving up is no longer free')

    -- he runs and gets away: the unit gives the mission up
    Place(12, vec3(meet and meet.x + 900.0 or 600.0, meet and meet.y or 6100.0, 31.0))
    Secs(2)
    Act('server:abandon', 1, tabRun.id)
    Act('server:abandon', 2, tabRun.id)
    Secs(3)
    H.eq(tabRun.state, 'ended', 'crimtab: the mission ends')

    -- step Z2: the unit gave the mission up, so the run ended abandoned: the volunteer is not paid for it
    local rows = H.sql([[SELECT mission_id, cash_base, run_uuid FROM cp_mission_runs WHERE citizenid = ?
        AND mission_type = 'manual_award']], { CID[12] })
    H.eq(#rows, 0, 'crimtab: an abandoned run pays the volunteer nothing (Z2)')
    -- a case that ends fairly pays once: one feature reward row of $1,500 cash for his escape, never twice
    local first = CP.FeatureRewards.pay('suspect', CID[12], { key = tostring(tabRun.id), outcome = 'got_away' })
    H.ok(first ~= nil and first.amount == 1500, 'crimtab: ...$1,500 for getting away')
    rows = H.sql([[SELECT mission_id, cash_base, run_uuid FROM cp_mission_runs WHERE citizenid = ?
        AND mission_type = 'manual_award']], { CID[12] })
    H.eq(#rows, 1, 'crimtab: one payment row for the volunteer')
    H.eq(rows[1] and rows[1].mission_id, 'reward_suspect', 'crimtab: ...the volunteer suspect reward')
    local again = CP.FeatureRewards.pay('suspect', CID[12], { key = tostring(tabRun.id), outcome = 'got_away' })
    H.eq(again, nil, 'crimtab: the same case never pays twice')

    -- History: the case, its outcome, no strike
    view = Cb('crimtab:get', 12) or {}
    local h = view.history and view.history[1]
    H.eq(h and h.outcome, 'got_away', 'crimtab: History shows the escape')
    H.eq(h and h.dropout, nil, 'crimtab: ...no dropout')
    H.eq(#(view.strikes or {}), 0, 'crimtab: no strike')
    H.eq(view.active, nil, 'crimtab: Active is empty again')

    def.locations = savedLocations
    Config.DisabledMissions = {}
end

-- ============================================================================
--                     6. GIVING UP AFTER THE FREE SECONDS
-- ============================================================================
-- A STRIKE, NOTHING PAID.

do
    Config.DisabledMissions = { 'manhunt', 'suspicious_activity' }
    local def = CP.Missions.get('warrant_service')
    local savedLocations = def.locations
    def.locations = { def.locations[1] }
    -- the same officers and volunteer again: the admin lifts the repeat limits in Settings (shipped 30 min, 30 min)
    for _, c in ipairs({ { 'RealPlayers.jobHopMinutes', 0 }, { 'RealPlayers.suspectCooldownMinutes', 0 } }) do
        local ok, err = Setting(8, c[1], c[2])
        H.eq(ok, true, ('strike: the admin sets %s to %d: %s'):format(c[1], c[2], tostring(err)))
    end
    Place(12, vec3(-300.0, 6100.0, 31.0))
    Place(1, vec3(-200.0, 6000.0, 31.0))
    Place(2, vec3(-202.0, 6000.0, 31.0))
    local view = Cb('crimtab:get', 12) or {}
    if not (view.status and view.status.listed) then
        Act('server:crimtab:act', 12, { what = 'join', roles = { 'runner' } })
    end
    ClearCooldowns()
    local ok, data = Act('server:acceptType', 1, { missionType = 'investigation', realSuspect = true })
    H.eq(ok, true, 'strike: the unit takes another Investigation: ' .. tostring(data))
    H.fire('crimson-police:server:unitReady', 2, { accepted = true })
    Secs(3)
    local run = Runs.getBySrc(1)
    view = Cb('crimtab:get', 12) or {}
    local job = view.jobs and view.jobs[1]
    H.ok(job ~= nil, 'strike: a second job reaches his tablet')
    Act('server:crimtab:act', 12, { what = 'answer', token = job and job.token, yes = true })
    -- the officers reach the start (not him): he waits past the free seconds, then gives up
    local start = run and run.location.start.coords or vec3(0.0, 0.0, 0.0)
    Place(1, start)
    Place(2, vec3(start.x + 2.0, start.y, start.z))
    Secs((Config.RealPlayers.volunteer.cancelGraceSeconds or 60) + 2)
    view = Cb('crimtab:get', 12) or {}
    H.eq(view.active and view.active.freeCancel, false, 'strike: past the free seconds, Give up warns of a strike')
    ok = Act('server:crimtab:act', 12, { what = 'cancel' })
    H.eq(ok, true, 'strike: Give up')
    Secs(2)
    view = Cb('crimtab:get', 12) or {}
    H.eq(#(view.strikes or {}), 1, 'strike: History shows one strike')
    H.eq(view.active, nil, 'strike: Active is empty')
    if run and run.state ~= 'ended' then
        Act('server:abandon', 1, run.id)
        Act('server:abandon', 2, run.id)
        Secs(3)
    end
    local rows = H.sql([[SELECT id FROM cp_mission_runs WHERE citizenid = ? AND mission_type = 'manual_award']],
        { CID[12] })
    H.eq(#rows, 1, 'strike: giving up pays nothing (still the one escape payment)')
    def.locations = savedLocations
    Config.DisabledMissions = {}
end

-- ============================================================================
--                7. THE VOLUNTEER QUITS AND COMES BACK MID-CASE
-- ============================================================================
-- Step FX1. A CASE BY THE CRIMINAL TABLET, A DROP AND A RECONNECT WITHIN THE GRACE, AN OFFICER DROP.
-- docs/OWNER_GUIDE.md 6: a suspect who comes back within Config.RealPlayers.disconnectGrace stays in the case.

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

do
    Config.DisabledMissions = { 'manhunt', 'suspicious_activity' }
    local def = CP.Missions.get('warrant_service')
    local savedLocations = def.locations
    def.locations = { def.locations[1] }
    Place(12, vec3(-300.0, 6100.0, 31.0))
    Place(1, vec3(-200.0, 6000.0, 31.0))
    Place(2, vec3(-202.0, 6000.0, 31.0))
    local view = Cb('crimtab:get', 12) or {}
    if not (view.status and view.status.listed) then
        Act('server:crimtab:act', 12, { what = 'join', roles = { 'runner' } })
    end
    ClearCooldowns()
    local ok, data = Act('server:acceptType', 1, { missionType = 'investigation', realSuspect = true })
    H.eq(ok, true, 'drop: the unit takes an Investigation: ' .. tostring(data))
    H.fire('crimson-police:server:unitReady', 2, { accepted = true })
    Secs(3)
    local run = Runs.getBySrc(1)
    view = Cb('crimtab:get', 12) or {}
    local job = view.jobs and view.jobs[1]
    H.ok(job ~= nil, 'drop: the job reaches his tablet')
    Act('server:crimtab:act', 12, { what = 'answer', token = job and job.token, yes = true })
    Secs(2)
    view = Cb('crimtab:get', 12) or {}
    local meet = view.active and view.active.meet
    if meet then Place(12, vec3(meet.x + 1.0, meet.y, meet.z)) end
    Secs(3)
    local start = run and run.location.start.coords or vec3(0.0, 0.0, 0.0)
    Place(1, start)
    Place(2, vec3(start.x + 2.0, start.y, start.z))
    Secs(3)
    if meet then
        Place(1, vec3(meet.x + 3.0, meet.y, meet.z))
        Place(2, vec3(meet.x + 5.0, meet.y, meet.z))
    end
    Secs(3)
    H.eq((CP.Volunteers.matchOf(CID[12]) or {}).phase, 'engaged', 'drop: officers reached him: engaged')
    local strikes = #(view.strikes or {})

    -- he quits mid-case and joins again 30 s later: still the suspect of the case, no new strike
    Drop(12)
    H.eq(run and run.state, 'in_progress', 'drop: the case goes on while he is away')
    H.eq((CP.Volunteers.matchOf(CID[12]) or {}).phase, 'engaged', 'drop: ...his match is kept within the grace')
    Secs(30)
    Reconnect(12)
    if meet then Place(12, vec3(meet.x + 1.0, meet.y, meet.z)) end
    Secs(3)
    view = Cb('crimtab:get', 12) or {}
    H.eq(view.active and view.active.phase, 'engaged', 'drop: back, his criminal tablet shows the case on Active')
    H.eq(#(view.strikes or {}), strikes, 'drop: ...and no strike for the reconnect')
    local _, rec = CP.Opponents.byCid(CID[12])
    H.eq(rec and rec.src, 12, 'drop: the case has him again under his id')

    -- Ben (the partner) quits: the case goes on for Ada, who cuffs the volunteer
    Drop(2)
    H.eq(Runs.getBySrc(2), nil, 'drop: the partner is off the case')
    H.eq(Runs.getBySrc(1), run, 'drop: the leader is still on it')
    if meet then Place(1, vec3(meet.x + 2.0, meet.y, meet.z)) end
    Secs(1)
    H.fire('police:server:CuffPlayer', 1, 12, false)
    Meta(12, 'ishandcuffed', true)
    Secs(Config.RealPlayers.custodyHoldSeconds + 3)
    _, rec = CP.Opponents.byCid(CID[12])
    H.eq(rec and rec.state, 'detained', 'drop: the volunteer, back, is detained by the leader')
    Reconnect(2)
    H.eq(Runs.getBySrc(2), nil, 'drop: the partner, back, is on no run')
    if run and run.state ~= 'ended' then Act('server:abandon', 1, run.id) end
    Secs(3)
    H.eq(run and run.state, 'ended', 'drop: the mission ends')
    view = Cb('crimtab:get', 12) or {}
    H.eq(view.history and view.history[1] and view.history[1].outcome, 'detained',
        'drop: his History shows the case detained')
    H.eq(view.active, nil, 'drop: Active is empty again')
    Meta(12, 'ishandcuffed', false)
    def.locations = savedLocations
    Config.DisabledMissions = {}
end

return H

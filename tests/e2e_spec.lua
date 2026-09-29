-- End-to-end scenarios on the REAL server side of Crimson-Police.

local H = dofile('tests/harness.lua')
H.db = (os.getenv('CP_TEST_DB') or 'cp_test') .. '_e2e'

-- oxmysql talks utf8mb4; the harness' mysql CLI would default to latin1.
do
    local realPopen = io.popen
    io.popen = function(cmd, mode)
        if type(cmd) == 'string' and cmd:match('^mysql %-uroot ') and not cmd:find('default%-character%-set', 1) then
            cmd = cmd:gsub('^mysql %-uroot ', 'mysql --default-character-set=utf8mb4 -uroot ', 1)
        end
        return realPopen(cmd, mode)
    end
end
H.resetDatabase()
do
    local f = assert(io.open('tests/fixtures/core/mdt_dispatch.sql', 'r'))
    local sql = f:read('a')
    f:close()
    H.sql(sql)
    H.sql('DELETE FROM mdt_dispatch')
end

H.boot({ side = 'server' })
-- A fixed Wednesday afternoon in the machine's time zone, whatever the wall clock says: the fixture rows of
-- "yesterday" (NOW() - 20 h) must be in this week and not today. NOW() follows H.time in every storage mode.
H.time = os.time({ year = 2026, month = 9, day = 23, hour = 14, min = 0, sec = 0 })
local U = CP.U
local cjson = require('cjson')

-- ============================================================================
--                                   CONSOLE
-- ============================================================================
-- Keep the module log lines out of the test output, keep errors visible.

local realPrint = print
local logLines = {}
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    logLines[#logLines + 1] = line
    if os.getenv('E2E_VERBOSE') then realPrint(line) return end
    if line:find('crimson%-police') or line:find('Crimson%-Police') then return end
    realPrint(line)
end
local function Logged(pattern)
    for _, l in ipairs(logLines) do if l:find(pattern) then return true end end
    return false
end

-- ============================================================================
--           LOCALE: every part merged, like locales/en.json in game
-- ============================================================================

do
    local merged = {}
    local p = io.popen('ls ' .. H.root .. 'locales/parts/*.json')
    for file in p:lines() do
        local f = io.open(file, 'r')
        local ok, data = pcall(cjson.decode, f:read('a'))
        f:close()
        if ok and type(data) == 'table' then for k, v in pairs(data) do merged[k] = v end end
    end
    p:close()
    local text = cjson.encode(merged)
    local realLoad = LoadResourceFile
    -- shared/locale.lua loads locales/<Config.Locale>.json; fxmanifest ships locales/*.json (not the parts).
    local shipped = io.open(H.root .. 'locales/en.json', 'r')
    if shipped then shipped:close() end
    H.ok(shipped ~= nil,
        'locales/en.json ships with the resource (shared/locale.lua reads it; every CP.L text comes from it)')
    LoadResourceFile = function(res, path)
        if path == 'locales/en.json' then return text end
        return realLoad(res, path)
    end
    H.load('shared/locale.lua')   -- the rest of the spec runs with the merged parts, as after tools/check_contracts.py --merge
end

-- ============================================================================
--                     NATIVES (OneSync entities, players)
-- ============================================================================

local ents, nextHandle, nextNet = {}, 9000, 20000
local netToEnt, deleted = {}, {}
local function NewEnt(kind, model, x, y, z, h)
    nextHandle, nextNet = nextHandle + 1, nextNet + 1
    ents[nextHandle] = {
        kind = kind,
        model = model,
        coords = vec3(x + 0.0, y + 0.0, z + 0.0),
        heading = h or 0.0,
        exists = true,
        health = kind == 'ped' and 200 or 1000,
        maxHealth = kind == 'ped' and 200 or 1000,
        armour = 0,
        engine = 1000.0,
        body = 1000.0,
        net = nextNet,
        type = kind == 'ped' and 1 or (kind == 'vehicle' and 2 or 3),
    }
    netToEnt[nextNet] = nextHandle
    return nextHandle
end
local function ModelHash(m) if type(m) == 'number' then return m end return joaat(m) end
_G.CreatePed = function(_, model, x, y, z, h) return NewEnt('ped', model, x, y, z, h) end
_G.CreateVehicleServerSetter = function(model, _, x, y, z, h) return NewEnt('vehicle', model, x, y, z, h) end
_G.CreateVehicle = function(model, x, y, z, h) return NewEnt('vehicle', model, x, y, z, h) end
_G.CreateObjectNoOffset = function(model, x, y, z) return NewEnt('object', model, x, y, z) end
_G.DoesEntityExist = function(e)
    if ents[e] then return ents[e].exists end
    return (tonumber(e) or 0) > 0
end
_G.DeleteEntity = function(e) deleted[e] = true if ents[e] then ents[e].exists = false end end
_G.NetworkGetNetworkIdFromEntity = function(e) return ents[e] and ents[e].net or 0 end
_G.NetworkGetEntityFromNetworkId = function(n) return netToEnt[n] or 0 end
_G.NetworkGetEntityOwner = function() return 0 end
_G.GiveWeaponToPed = function(e, w) if ents[e] then ents[e].weapon = w end end
_G.SetPedArmour = function(e, a) if ents[e] then ents[e].armour = a end end
_G.GetPedArmour = function(e) return ents[e] and ents[e].armour or 0 end
_G.GetEntityHealth = function(e) return ents[e] and ents[e].health or 200 end
_G.GetEntityMaxHealth = function(e) return ents[e] and ents[e].maxHealth or 200 end
_G.GetPedMaxHealth = _G.GetEntityMaxHealth
_G.GetEntityModel = function(e) return ents[e] and ModelHash(ents[e].model) or 0 end
_G.GetVehicleEngineHealth = function(e) return ents[e] and ents[e].engine or 1000.0 end
_G.GetVehicleBodyHealth = function(e) return ents[e] and ents[e].body or 1000.0 end
_G.GetVehiclePetrolTankHealth = function() return 1000.0 end
_G.GetEntityType = function(e)
    if ents[e] then return ents[e].type end
    local n = tonumber(e) or 0
    if n > 0 and n % 100 == 0 and H.players[n // 100] then
        return 1
    end -- a player's ped (src * 100)
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
_G.WasEventCanceled = function() return false end
_G.GetPlayerRoutingBucket = function() return 0 end
_G.GetPlayerLastMsg = function() return 0 end
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end
_G.TriggerLatentClientEvent = function(name, target, _, ...) TriggerClientEvent(name, target, ...) end
_G.AddStateBagChangeHandler = function() end
local stopResourceCalls = 0
_G.StopResource = function() stopResourceCalls = stopResourceCalls + 1 end
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
-- qbx_core, sc-dispatch, sc-ambulance, Renewed-Banking, ox_inventory.

local PD = {}           -- src -> Qbox PlayerData
local addMoney = {}     -- { src, account, amount, reason }
local function AddPlayer(src, cid, first, last, job, grade, opts)
    opts = opts or {}
    PD[src] = {
        source = src,
        citizenid = cid,
        charinfo = { firstname = first, lastname = last },
        job = {
            name = job,
            label = job,
            type = (job == 'sast' or job == 'fib') and 'leo' or 'none',
            onduty = job ~= 'unemployed',
            grade = { level = grade, name = grade >= 3 and 'Sergeant' or 'Trooper' },
        },
        metadata = { callsign = opts.callsign or ('C-' .. src), isdead = false, inlaststand = false },
    }
    H.players[src] = {
        coords = vec3(0.0, 0.0, 0.0),
        ace = opts.admin and { ['crimsonpolice.admin'] = true } or {},
        state = {},
    }
end
local function QbxPlayer(src)
    local pd = PD[tonumber(src)]
    if not pd or offline[tonumber(src)] then return nil end
    return {
        PlayerData = pd,
        Functions = {
            AddMoney = function(account, amount, reason)
                addMoney[#addMoney + 1] = {
                    src = pd.source,
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
        local grades = {
            [0] = { name = 'Cadet' },
            [1] = { name = 'Trooper' },
            [2] = { name = 'Corporal' },
            [3] = { name = 'Sergeant' },
            [4] = { name = 'Lieutenant' },
        }
        return {
            sast = { label = 'SAST', type = 'leo', grades = grades },
            fib = { label = 'FIB', type = 'leo', grades = grades },
            ambulance = { label = 'EMS', type = 'ems', grades = grades },
            unemployed = { label = 'Civilian', grades = { [0] = { name = 'Freelancer' } } },
        }
    end,
}
local cleared = {}      -- sc-dispatch ClearNotification calls
H.exportsMock['sc-dispatch'] = {
    IsPlayerSuspended = function() return false end,
    ClearNotification = function(id, jobs) cleared[#cleared + 1] = { id = id, jobs = jobs } return true end,
}
local doctors = 0
H.exportsMock['sc-ambulance'] = {
    GetDoctorCount = function() return doctors end,
}
local bank = { tx = {}, society = { sast = 100000, fib = 100000 } }
H.exportsMock['Renewed-Banking'] = {
    handleTransaction = function(account, title, amount, message, issuer, receiver, transType, transId)
        local t = {
            account = account,
            title = title,
            amount = amount,
            message = message,
            issuer = issuer,
            receiver = receiver,
            type = transType,
            id = transId,
        }
        bank.tx[#bank.tx + 1] = t
        return t
    end,
    removeAccountMoney = function(account, amount)
        if (bank.society[account] or 0) < amount then return false end
        bank.society[account] = bank.society[account] - amount
        return true
    end,
    getAccountMoney = function(account) return bank.society[account] end,
    addAccountMoney = function(account, amount)
        bank.society[account] = (bank.society[account] or 0) + amount
        return true
    end,
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

AddPlayer(1, 'E2ESAST1', 'Ada', 'Trooper', 'sast', 1)
AddPlayer(2, 'E2EFIB02', 'Ben', 'Agent', 'fib', 1)
AddPlayer(3, 'E2ESUP03', 'Sam', 'Sarge', 'sast', 3)
AddPlayer(4, 'E2EFSUP4', 'Fay', 'Chief', 'fib', 3)
AddPlayer(5, 'E2EADM05', 'Adam', 'Admin', 'unemployed', 0, { admin = true })
AddPlayer(6, 'E2ESAST6', 'Cleo', 'Trooper', 'sast', 1)
AddPlayer(7, 'E2EFIB07', 'Dan', 'Agent', 'fib', 1)
AddPlayer(8, 'E2EFSUP8', 'Gus', 'Boss', 'fib', 3)
AddPlayer(10, 'E2ESAS10', 'Hal', 'Trooper', 'sast', 1)
AddPlayer(11, 'E2EFIB11', 'Ivy', 'Agent', 'fib', 1)
AddPlayer(12, 'E2EEMS12', 'Joe', 'Medic', 'ambulance', 1)
AddPlayer(13, 'E2ESAS13', 'Kim', 'Trooper', 'sast', 1)
AddPlayer(14, 'E2EFIB14', 'Lou', 'Agent', 'fib', 1)
AddPlayer(9, 'E2ECIV09', 'Ed', 'Civilian', 'unemployed', 0)
local CID = {}
for src, pd in pairs(PD) do CID[src] = pd.citizenid end

-- ============================================================================
--                            LOAD THE REAL RESOURCE
-- ============================================================================
-- Fxmanifest order: modules/**/server.lua, then blocks/**/server.lua.

local loadedFiles = {}
do
    local p = io.popen(
        'cd ' .. H.root .. ' && find modules -name server.lua | sort && find blocks -name server.lua | sort')
    for file in p:lines() do loadedFiles[#loadedFiles + 1] = file end
    p:close()
    -- FiveM's CreateThread runs the new thread on the next scheduler tick, after every file of the resource
    -- has loaded (the harness runs it at once): defer the threads created at load time to match.
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
H.eq(stopResourceCalls, 0, 'the real migrations ran on the e2e database without stopping the resource')
H.step(0)
for _ = 1, 3 do
    H.step(1000)
end -- start threads (mission loader, hooks, payouts cache)

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

local function Place(src, c)
    H.players[src].coords = vec3(c.x + 0.0, c.y + 0.0, c.z + 0.0)
end
local reqN = 0
-- A NUI action (CP.Net.action) as src; returns ok, data|errKey from client:actionResult.
local function Act(name, src, payload)
    reqN = reqN + 1
    local id = 'e2e' .. reqN
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
local function Rows(where, params)
    return H.sql(
        'SELECT id, run_uuid, citizenid, department, mission_type, mission_id, state, end_reason, tier, participants, departments_n, '
            .. 'points_base, bonus_points, penalty_points, final_points, cash_base, cash_multiplier, cash_paid, cash_status, flagged, flag_reason, voided, breakdown '
            .. 'FROM cp_mission_runs WHERE ' .. where .. ' ORDER BY id',
        params
    )
end
local function ClientEvents(name, target, since)
    local out = {}
    for i = (since or 0) + 1, #H.events do
        local e = H.events[i]
        if e.kind == 'client' and e.name == name and (target == nil or e.target == target) then out[#out + 1] = e end
    end
    return out
end
local function Flag(src) return H.players[src].state.crimsonArena end
local function VehicleFor(src, model)
    local c = H.players[src].coords
    local v = NewEnt('vehicle', model or 'police', c.x, c.y, c.z, 0.0)
    ents[v].driver = src
    H.players[src].vehicle = v
    return v
end
-- Arrive at the start of a run (the real CP.Route arrival check, server-side coords).
local function Arrive(run, src)
    Place(src, run.location.start.coords)
    Secs(2)
end
local function Objective(src, run, index, ev)
    H.fire('crimson-police:server:objective', src, run.id, index, ev)
end
local function Telemetry(src, run, kind, data)
    H.fire('crimson-police:server:telemetry', src, run.id, kind, data)
end
local Runs = CP.Runs
local POLICE_MODEL = 'police3'
-- The checkpoint report carries no vehicle class or model: the server checks the driver seat itself.
local function CheckpointEv(k, veh)
    return { type = 'checkpoint', index = k, netId = ents[veh].net }
end

do
    local ids = assert(load(LoadResourceFile('Crimson-Police', 'missions/builtin/index.lua'), '@index', 't', {}))()
    H.eq(U.count(CP.Missions.all()), #ids, 'the real loader loaded every built-in mission file at start')
end

-- ============================================================================
--                    1. SOLO BEAT PATROL, START TO PAID ROW
-- ============================================================================

do
    local src, cid = 1, CID[1]
    Config.DisabledMissions = { 'business_check', 'street_race_bust' }   -- the Patrol pool is Beat Patrol only
    local chance = Config.Events.modifierChance
    Config.Events.modifierChance = 0
    -- two earlier completed runs this week (yesterday) so this run is the third one the board needs
    for _ = 1, 2 do
        H.sql(
            [[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason,
            points_base, final_points, created_at) VALUES (UUID(), 'patrol', 'business_check', ?, 'sast', 'completed', 'completed',
            60, 50, NOW() - INTERVAL 20 HOUR)]], { cid })
    end
    local board0 = Cb('getBoard', src, { period = 'weekly', filter = 'overall' })
    local function BoardRow(b)
        for _, r in ipairs(b and b.rows or {}) do if r.citizenid == cid then return r end end
        return nil
    end
    H.eq(BoardRow(board0), nil, 'board: two runs are not enough to be ranked (cached now)')

    Place(src, vec3(200.0, -1000.0, 29.0))
    Config.Events.modifierChance = chance
    local board1 = Cb('getMissionTypes', src)
    Config.Events.modifierChance = 0
    local card
    for _, c in ipairs(board1 and board1.cards or {}) do if c.key == 'patrol' then card = c end end
    H.eq(board1 and #board1.cards, 4, 'Mission Board: one card per mission type')
    H.eq(card and card.points, 60, 'Patrol card: 60 points')
    H.eq(card and card.pool, 1, 'Patrol card: one mission in the pool')
    H.eq(card and card.mode, 'solo', 'solo')
    H.eq(card and card.cash and (card.cash[1] .. '-' .. card.cash[2]), '250-313',
        'cash per officer $250-$313 (a modifier pays x1.25)')
    H.eq(card and card.locked, nil, 'not locked')
    local mark = #H.events
    local ok, data = Act('server:acceptType', src, 'patrol')
    H.eq(ok, true, 'acceptType patrol: ' .. tostring(data))
    local run = Runs.getBySrc(src)
    H.ok(run ~= nil and run.id == (data and data.runId), 'the run of the accept')
    H.eq(run and run.missionId, 'beat_patrol', 'Beat Patrol drawn')
    H.eq(run and run.state, 'accepted', 'accepted until the start is reached')
    H.eq(#ClientEvents('crimson-police:client:start', src, mark), 1, 'client:start sent once')
    H.eq(run and run.cashBase, 250, 'B locked at accept: the Patrol type payout')
    local view = Cb('getRun', src)
    H.eq(view and view.state, 'accepted', 'Active Mission: accepted')
    H.eq(view and view.missionLabel, 'Beat Patrol', 'the drawn mission is revealed after the accept')
    H.eq(view and view.tierExpected, true, 'the tier is shown as expected until In progress')
    H.eq(view and view.route and view.route.status, 'on', 'start route on')
    H.eq(view and view.expected and view.expected.cash, 250, 'expected cash $250')

    local veh = VehicleFor(src, POLICE_MODEL)
    -- drive to the start while reporting the route (the start route is on for real runs)
    for i = 1, 3 do
        H.fire('crimson-police:server:routeStatus', src, run.id, 5.0, H.players[src].coords)
        Secs(2)
    end
    H.eq(run.state, 'accepted', 'still accepted while on route')
    Arrive(run, src)
    H.eq(run.state, 'in_progress', 'the real route arrival check moved the run to In progress')
    H.eq(run.tier and run.tier.tier, 'standard', 'solo: Standard tier')
    H.eq(type(Flag(src)) == 'table' and Flag(src).source, 'crimson-police', 'alert suppression flag set on arrival')

    Telemetry(src, run, 'vehicle', { netId = ents[veh].net })
    local st = run.objectives[1].state
    H.eq(st.points and #st.points, 5, 'five checkpoints of the district')
    for k = 1, #(st.points or {}) do
        Secs(15)                -- driving there
        Place(src, st.points[k])
        ents[veh].coords = H.players[src].coords
        Secs(10)                -- held 10 s inside the marker (server-side samples)
        Objective(src, run, 1, CheckpointEv(k, veh))
        if k < #st.points then H.eq(st.done, k, 'checkpoint ' .. k .. ' counted') end
    end
    Secs(2)
    H.eq(run.state, 'ended', 'every checkpoint done: the run ended')
    H.eq(Runs.getBySrc(src), nil, 'no longer on a run')
    H.eq(Flag(src), nil, 'the flag is removed at the end')

    local r = Rows('run_uuid = ?', { run.id })
    H.eq(#r, 1, 'one row for the solo run')
    r = r[1] or {}
    H.eq(r.state, 'completed', 'row completed')
    H.eq(r.end_reason, 'completed', 'end_reason completed')
    H.eq(r.tier, 'standard', 'row tier')
    -- points = max(0, min(2P, (P + bonuses - penalties) * Mteam * Mcross * Mstreak)), ToD doubles after the cap
    local bd = U.jsonField(r.breakdown) or {}
    local pts = bd.points or {}
    local sum = 0
    local ids = {}
    for _, b in ipairs(pts.bonuses or {}) do sum = sum + b.points; ids[b.id] = b.points end
    for _, b in ipairs(pts.penalties or {}) do sum = sum + b.points; ids[b.id] = b.points end
    H.eq(pts.P, 60, 'P = Patrol points x star multiplier')
    H.eq(ids.fast_finish, 12, 'finished within 75% of the time limit: +20% of P')
    H.eq(ids.first_run, 15, 'first completed run since going on duty: +15')
    H.eq(ids.no_vehicle_damage, 10, 'no vehicle damage: +10')
    H.eq(pts.mTeam, 1.0, 'M_team solo')
    H.eq(pts.mCross, 1.0, 'M_cross one department')
    local streak = CP.Scoring.streak(cid)
    H.eq(pts.mStreak, 1 + math.min(0.25, 0.05 * streak.days), 'M_streak from the streak days')
    local expected = math.floor(math.max(0, math.min(2 * 60, (60 + sum) * 1.0 * 1.0 * pts.mStreak)) + 1e-9)
    if CP.Events.typeOfTheDay() == 'patrol' then expected = expected * 2 end
    H.eq(r.final_points, expected, 'final points = the spec formula')
    H.eq(r.cash_base, 250, 'cash_base = B')
    H.eq(r.cash_status, 'paid', 'cash paid')
    H.eq(r.cash_paid, 250, 'cash = round(B x 1.00 x 1.00)')
    local off = H.sql('SELECT xp, streak_days FROM cp_officers WHERE citizenid = ?', { cid })[1] or {}
    H.eq(tonumber(off.xp), r.final_points, 'XP = lifetime points (the counted row)')
    H.eq(tonumber(off.streak_days), 1, 'a one-day streak')

    local mine = {}
    for _, m in ipairs(addMoney) do if m.citizenid == cid then mine[#mine + 1] = m end end
    H.eq(#mine, 1, 'one Qbox AddMoney')
    H.eq(mine[1] and mine[1].account, 'bank', 'to the bank account')
    H.eq(mine[1] and mine[1].amount, 250, 'the row amount')
    H.eq(mine[1] and mine[1].reason, 'crimson-police-mission', 'AddMoney reason')
    local tx = {}
    for _, t in ipairs(bank.tx) do if t.account == cid then tx[#tx + 1] = t end end
    H.eq(#tx, 1, 'one Renewed-Banking history entry')
    H.eq(tx[1] and tx[1].type, 'deposit', 'a deposit')
    H.eq(tx[1] and tx[1].id, ('CP-%s-%s'):format(run.id, cid), 'transaction id CP-<run_uuid>-<citizenid>')
    H.eq(tx[1] and tx[1].amount, 250, 'entry amount')
    H.eq(tx[1] and tx[1].message, 'Mission payout: Beat Patrol', 'entry message')
    H.eq(tx[1] and tx[1].issuer, 'San Andreas State Troopers', 'entry issuer = department label')
    H.eq(tx[1] and tx[1].receiver, 'Ada Trooper', 'entry receiver = character name')
    H.eq(tx[1] and tx[1].title, 'Crimson-Police', 'entry title')
    -- paid once: the claim refuses every later attempt
    local again = CP.Cash.pay(r.id)
    H.eq(again, 'paid', 'a second pay() only reports the final status')
    CP.Cash.payPending(src)
    local n = 0
    for _, m in ipairs(addMoney) do if m.citizenid == cid then n = n + 1 end end
    H.eq(n, 1, 'still one AddMoney after pay() and payPending()')

    local cd = Runs.cooldowns(cid)
    H.ok((cd.missions.beat_patrol or 0) > os.time(), 'the mission cooldown started')
    H.eq(cd.types.patrol, nil, 'no type cooldown for a completed run')

    local board = Cb('getBoard', src, { period = 'weekly', filter = 'overall' })
    local row = BoardRow(board)
    H.ok(row ~= nil, 'board: the officer is ranked right after the run (invalidated)')
    H.eq(row and row.points, 100 + r.final_points, 'board points include the new row')
    H.eq(row and row.runs, 3, 'three completed runs')
    Config.Events.modifierChance = chance
    Config.DisabledMissions = {}
end

-- ============================================================================
--                            GANG SHOOTOUT HELPERS
-- ============================================================================

local TACTICAL_OTHERS = { 'hostage_rescue', 'bomb_disposal', 'armored_truck_escort', 'prison_break' }
local function FormUnit(leader, member)
    local ok, data = Act('server:unitInvite', leader, member)
    H.eq(ok, true, ('unit invite %d -> %d: %s'):format(leader, member, tostring(data)))
    local unitId = data and data.unitId
    ok, data = Act('server:unitRespond', member, { accepted = true, unitId = unitId })
    H.eq(ok, true, ('invite accepted by %d: %s'):format(member, tostring(data)))
    return unitId
end
-- Kill every living hostile of objective 1 (killer = that player's ped) until the objective is done.
local function ClearHostiles(run, killer, maxSeconds)
    local killed = 0
    local t = 0
    -- a believable pace: the objective's minSeconds (60 s) pass before the last hostile falls
    local o = run.objectives[1]
    local minS = (o.obj and o.obj.minSeconds or 60) + 2
    local waited = (H.clockMs - (o.startedAtMs or H.clockMs)) / 1000
    if waited < minS then Secs(math.ceil(minS - waited)) end
    while run.state == 'in_progress' and run.objectiveIndex == 1 and t < (maxSeconds or 400) do
        for _, e in ipairs(Runs.entitiesFor(run, { obj = 1, kind = 'ped', alive = true })) do
            local x = ents[e.entity]
            if x and x.exists and x.health > 0 then
                x.killer = killer * 100
                x.health = 0
                killed = killed + 1
            end
        end
        Secs(3)
        t = t + 3
    end
    return killed
end
local function SecureScene(run, src)
    Place(src, run.location.scene)
    Secs(10)
    Objective(src, run, 2, { type = 'interact', point = 1 })
    Secs(2)
end
local function WaveTotal(list)
    local n = 0
    for _, v in ipairs(list or {}) do n = n + v end
    return n
end

-- ============================================================================
--                2. SAST + FIB UNIT GANG SHOOTOUT AT REINFORCED
-- ============================================================================
-- Quit vs real_call.

do
    Config.DisabledMissions = TACTICAL_OTHERS
    local chance = Config.Events.modifierChance
    Config.Events.modifierChance = 0

    -- 2a: the FIB partner quits mid-run -> the pay tier drops to Standard
    FormUnit(1, 2)
    H.eq(#CP.Units.members(1), 2, 'unit of two (SAST + FIB)')
    Place(1, vec3(0.0, 0.0, 0.0))
    Place(2, vec3(5.0, 0.0, 0.0))
    local ok, data = Act('server:acceptType', 1, 'tactical')
    H.eq(ok, true, 'the leader accepts Tactical: ' .. tostring(data))
    local run = Runs.getBySrc(1)
    H.eq(run and run.missionId, 'gang_shootout', 'Gang Shootout drawn')
    H.eq(Runs.getBySrc(2), run, 'the partner is on the same run')
    H.eq(run and run.expectedTier, 'reinforced', 'expected tier Reinforced')
    H.eq(CP.Units.unitOf(1) and CP.Units.unitOf(1).locked, true, 'invites closed at accept')
    Arrive(run, 1)
    Arrive(run, 2)
    H.eq(run.state, 'in_progress', 'in progress')
    H.eq(run.tier and run.tier.tier, 'reinforced', 'tier Reinforced for two')
    H.eq(run.payTier and run.payTier.tier, 'reinforced', 'pay tier Reinforced')
    local view = Cb('getRun', 1)
    H.eq(view and view.tier, 'reinforced', 'Active Mission: Reinforced')
    H.eq(view and view.tierExpected, false, 'no longer expected')
    H.eq(view and view.expected and view.expected.cash, 920, 'expected cash round($800 x 1.15)')
    H.eq(view and view.expected and view.expected.points,
        math.floor(200 * 1.10 * 1.10) * (CP.Events.typeOfTheDay() == 'tactical' and 2 or 1),
        'expected points P x M_team x M_cross (x2 on Type of the Day)')
    local scaledWaves = run.objectives[1].obj.waves
    H.eq(table.concat(scaledWaves or {}, '/'), '9/9/8', 'waves scaled x1.25 (7/7/6 -> 9/9/8, halves up)')
    Secs(3)
    ok, data = Act('server:abandon', 2, run.id)
    H.eq(ok, true, 'the FIB partner abandons (quit): ' .. tostring(data))
    H.eq(run.payTier and run.payTier.tier, 'standard', 'quit: the points and cash tier drops to Standard')
    H.eq(run.tier and run.tier.tier, 'standard', 'quit: the NPC tier drops too')
    H.eq(table.concat(run.objectives[1].obj.waves or {}, '/'), '7/7/6', 'NPCs not yet spawned shrink to Standard')
    local r2 = Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[2] })[1] or {}
    H.eq(r2.state, 'abandoned', 'partner row abandoned')
    H.eq(r2.end_reason, 'quit', 'partner end_reason quit')
    H.eq(r2.final_points, 0, 'abandoned: 0 points')
    H.eq(r2.cash_paid, 0, 'abandoned: $0')
    local cd2 = Runs.cooldowns(CID[2])
    H.ok((cd2.types.tactical or 0) > os.time(), 'quit: the whole Tactical type is on cooldown for the partner')

    Place(1, run.location.start.coords)
    local killed = ClearHostiles(run, 1)
    H.eq(run.objectiveIndex, 2, 'every hostile neutralised: Secure the scene is current')
    H.ok(killed >= 20, 'at least the 20 Standard hostiles spawned and died (' .. killed .. ')')
    SecureScene(run, 1)
    H.eq(run.state, 'ended', 'Gang Shootout completed')
    local r1 = Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[1] })[1] or {}
    H.eq(r1.state, 'completed', 'leader row completed')
    H.eq(r1.tier, 'standard', 'leader row: the dropped pay tier')
    H.eq(r1.cash_paid, 800, 'cash = $800 x 1.00 (Standard) after the quit')
    H.eq(r1.cash_status, 'paid', 'leader paid')
    local bd1 = U.jsonField(r1.breakdown) or {}
    H.eq(bd1.points and bd1.points.mTeam, 1.0, 'points use the dropped tier too (M_team x1.00)')
    H.eq(CP.Units.unitOf(1) and CP.Units.unitOf(1).locked, false, 'the unit is unlocked when the run ends')
    CP.Units.remove(1, { reason = 'left', silent = true })
    CP.Units.remove(2, { reason = 'left', silent = true })

    -- 2b: the FIB partner takes a real call -> the pay tier stays Reinforced, no cooldown for them
    H.sql(
        [[INSERT INTO mdt_dispatch (id, type, message, active, unique_id) VALUES (501, '10-71 - Shots Fired', 'real call 2b', 1, 'call_2b')]])
    FormUnit(6, 7)
    Place(6, vec3(0.0, 0.0, 0.0))
    Place(7, vec3(5.0, 0.0, 0.0))
    ok, data = Act('server:acceptType', 6, 'tactical')
    H.eq(ok, true, 'second unit accepts Tactical: ' .. tostring(data))
    run = Runs.getBySrc(6)
    H.eq(run and run.missionId, 'gang_shootout', 'Gang Shootout drawn again')
    Arrive(run, 6)
    Arrive(run, 7)
    H.eq(run.payTier and run.payTier.tier, 'reinforced', 'Reinforced')
    Secs(3)
    local mark = #H.events
    H.fire('sc-dispatch:server:ToggleResponding', 7, 'call_2b', true)
    Secs(2)
    H.eq(Runs.getBySrc(7), nil, 'real call: the partner left the run')
    H.eq(Runs.getBySrc(6), run, 'the leader carries on')
    local ended7 = ClientEvents('crimson-police:client:runEnded', 7, mark)[1]
    H.eq(ended7 and ended7.args[3], 'real_call', 'the partner is told the run ended for a real call')
    H.eq(run.payTier and run.payTier.tier, 'reinforced', 'real_call: the points and cash tier stays Reinforced')
    H.eq(run.tier and run.tier.tier, 'standard', 'real_call: NPCs not yet spawned shrink to the team that is left')
    local r7 = Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[7] })[1] or {}
    H.eq(r7.state, 'abandoned', 'real_call row abandoned')
    H.eq(r7.end_reason, 'real_call', 'end_reason real_call')
    H.eq(r7.final_points, 0, 'real_call: no points')
    local cd7 = Runs.cooldowns(CID[7])
    H.eq(cd7.types.tactical, nil, 'real_call: no type cooldown')
    H.eq(cd7.missions.gang_shootout, nil, 'real_call: no mission cooldown')
    H.eq(CP.Calls.isOnCall(7), true, 'the partner is On a call')

    Place(6, run.location.start.coords)
    ClearHostiles(run, 6)
    H.eq(run.objectiveIndex, 2, 'hostiles cleared by the leader')
    SecureScene(run, 6)
    H.eq(run.state, 'ended', 'completed')
    local r6 = Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[6] })[1] or {}
    H.eq(r6.state, 'completed', 'leader row completed')
    H.eq(r6.tier, 'reinforced', 'leader row keeps the Reinforced pay tier')
    H.eq(r6.cash_paid, 920, 'cash = round($800 x 1.15) = $920')
    local bd6 = U.jsonField(r6.breakdown) or {}
    H.eq(bd6.points and bd6.points.mTeam, 1.10, 'M_team of the kept Reinforced tier')
    CP.Units.remove(7, { reason = 'left', silent = true })
    ok, data = Act('server:acceptType', 7, 'patrol')
    H.eq(data, 'err.on_call', 'accepts are refused while responding to a real call')
    local board7 = Cb('getMissionTypes', 7)
    H.eq(board7 and board7.cards and board7.cards[1] and board7.cards[1].onCall, true, 'the board shows On a call')
    TriggerEvent('sc-dispatch:server:callClearedByOfficer', 'call_2b')
    Secs(1)
    H.eq(CP.Calls.isOnCall(7), false, 'the call was cleared')
    CP.Units.remove(6, { reason = 'left', silent = true })
    Config.Events.modifierChance = chance
    Config.DisabledMissions = {}
end

-- ============================================================================
--                                 2c. PRESENCE
-- ============================================================================
-- A partner who rides along from 1 km away keeps the result with 0 points and $0, flagged.

do
    Config.DisabledMissions = TACTICAL_OTHERS
    local chance = Config.Events.modifierChance
    Config.Events.modifierChance = 0
    FormUnit(13, 14)
    Place(13, vec3(0.0, 0.0, 0.0))
    Place(14, vec3(4.0, 0.0, 0.0))
    local ok, data = Act('server:acceptType', 13, 'tactical')
    H.eq(ok, true, 'accept: ' .. tostring(data))
    local run = Runs.getBySrc(13)
    Arrive(run, 13)
    Arrive(run, 14)
    local far = run.location.start.coords
    Place(14, vec3(far.x + 1000.0, far.y, far.z))  -- parks 1 km away for the whole run
    ClearHostiles(run, 13)
    Place(14, run.location.scene)                  -- turns up for the last few seconds
    SecureScene(run, 13)
    H.eq(run.state, 'ended', 'completed')
    local r14 = Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[14] })[1] or {}
    H.eq(r14.state, 'completed', 'the absent partner keeps the run result')
    H.eq(r14.final_points, 0, 'but gets 0 points')
    H.eq(r14.cash_paid, 0, 'and $0')
    H.eq(H.bit(r14.flagged), 1, 'and the row is flagged for review')
    H.eq(r14.flag_reason, 'presence', 'flag_reason \'presence\'')
    local r13 = Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[13] })[1] or {}
    H.eq(H.bit(r13.flagged), 0, 'the partner who was there is not flagged')
    H.eq(r13.cash_paid, 920, 'and is paid at the Reinforced tier')
    H.ok(r13.final_points > 0, 'with points')
    CP.Units.remove(13, { reason = 'left', silent = true })
    CP.Units.remove(14, { reason = 'left', silent = true })
    Config.Events.modifierChance = chance
    Config.DisabledMissions = {}
end

-- ═══ 3. Real calls: NPC call, own-run call, real call, un-mark within 60 s ══
do
    Config.DisabledMissions = TACTICAL_OTHERS
    local chance = Config.Events.modifierChance
    Config.Events.modifierChance = 0
    H.sql([[INSERT INTO mdt_dispatch (id, type, message, active, unique_id) VALUES
        (601, '10-71 - Shots Fired', 'sc-npcpolice call', 1, 'npccall-601-1790000000'),
        (602, '10-99 - Officer Down', 'partner down', 1, 'playerdown_3_1790000000'),
        (603, '10-16 - Stolen Vehicle', 'real call 3', 1, 'call_3')]])
    FormUnit(3, 4)
    Place(3, vec3(0.0, 0.0, 0.0))
    Place(4, vec3(5.0, 0.0, 0.0))
    local ok, data = Act('server:acceptType', 3, 'tactical')
    H.eq(ok, true, 'supervisor unit accepts Tactical (supervisors get the same missions): ' .. tostring(data))
    local run = Runs.getBySrc(3)
    Arrive(run, 3)
    Arrive(run, 4)
    H.eq(run.state, 'in_progress', 'in progress')
    H.eq(run.payTier and run.payTier.tier, 'reinforced', 'Reinforced')

    H.fire('sc-dispatch:server:ToggleResponding', 4, 'npccall-601-1790000000', true)
    Secs(2)
    H.eq(Runs.getBySrc(4), run, 'an SC-NPCPolice call (npccall-) never ends the run')
    H.eq(CP.Calls.isOnCall(4), false, 'and does not count as On a call')
    H.fire('sc-dispatch:server:ToggleResponding', 4, 601, true)
    Secs(2)
    H.eq(Runs.getBySrc(4), run, 'the same NPC call by its row id does not end the run either')
    H.fire('sc-dispatch:server:ToggleResponding', 4, 'playerdown_3_1790000000', true)
    Secs(2)
    H.eq(Runs.getBySrc(4), run, 'a partner\'s own person-down call is not a real call for them')
    H.fire('sc-dispatch:server:ToggleResponding', 4, 'call_404_not_in_mdt', true)
    Secs(2)
    H.eq(Runs.getBySrc(4), run, 'a faked call id (not active in mdt_dispatch) does nothing')

    H.fire('sc-dispatch:server:ToggleResponding', 4, 'call_3', true)
    Secs(2)
    H.eq(Runs.getBySrc(4), nil, 'a real call ends that participant')
    H.eq(Runs.getBySrc(3), run, 'and only that participant')
    local r4 = Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[4] })[1] or {}
    H.eq(r4.end_reason, 'real_call', 'end_reason real_call')
    H.eq(Runs.cooldowns(CID[4]).types.tactical, nil, 'no cooldown yet')
    H.eq(run.payTier and run.payTier.tier, 'reinforced', 'pay tier kept for the real call')

    Secs(20)
    H.fire('sc-dispatch:server:ToggleResponding', 4, 'call_3', false)
    Secs(2)
    r4 = Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[4] })[1] or {}
    H.eq(r4.end_reason, 'real_call_cancelled', 'un-marked within 60 s: real_call_cancelled')
    H.eq(r4.state, 'abandoned', 'still abandoned')
    local bd4 = U.jsonField(r4.breakdown) or {}
    H.eq(bd4.endReason, 'real_call_cancelled', 'the stored breakdown follows')
    local cd4 = Runs.cooldowns(CID[4])
    H.ok((cd4.types.tactical or 0) > os.time(), 'real_call_cancelled: the Tactical type cooldown applies')
    H.ok((cd4.missions.gang_shootout or 0) > os.time(), 'and the mission cooldown')
    H.eq(run.payTier and run.payTier.tier, 'standard',
        'the kept pay tier drops once the leave became real_call_cancelled')
    H.eq(CP.Calls.isOnCall(4), false, 'no longer On a call after the un-mark')

    ok = Act('server:abandon', 3, run.id)
    H.eq(ok, true, 'the other supervisor abandons')
    H.eq(run.state, 'ended', 'run over')
    CP.Units.remove(3, { reason = 'left', silent = true })
    CP.Units.remove(4, { reason = 'left', silent = true })
    Config.Events.modifierChance = chance
    Config.DisabledMissions = {}
end

-- ============================================================================
--                        4. DOWNED WITH NO EMS ON DUTY
-- ============================================================================
-- Failed, NPC pick-up, flag cleared.

do
    Config.DisabledMissions = { 'business_check', 'street_race_bust' }
    doctors = 0
    local src = 6
    Place(src, vec3(100.0, -1300.0, 29.0))
    local ok, data = Act('server:acceptType', src, 'patrol')
    H.eq(ok, true, 'accept Patrol: ' .. tostring(data))
    local run = Runs.getBySrc(src)
    Arrive(run, src)
    H.eq(run.state, 'in_progress', 'in progress')
    H.eq(type(Flag(src)) == 'table' and Flag(src).source, 'crimson-police', 'flag on')
    local mark = #H.events
    PD[src].metadata.isdead = true
    Secs(3)
    H.eq(Runs.getBySrc(src), nil, 'downed: removed from the run')
    H.eq(run.state, 'ended', 'every participant downed: the run ended')
    H.eq(run.endState, 'failed', 'as Failed')
    local r = Rows('run_uuid = ?', { run.id })[1] or {}
    H.eq(r.state, 'failed', 'row failed')
    H.eq(r.end_reason, 'downed', 'end_reason downed')
    H.eq(r.final_points, 0, 'failed with no objective done: 25% of P x 0 = 0')
    H.eq(r.cash_paid, 0, 'failed: $0')
    H.ok((Runs.cooldowns(CID[src]).types.patrol or 0) > os.time(), 'downed: type cooldown (no reroll by going down)')
    H.eq(type(Flag(src)) == 'table' and Flag(src).source, 'crimson-police', 'the flag stays until the pick-up is done')
    Secs(14)
    H.eq(#ClientEvents('crimson-police:client:pickup', src, mark), 1, 'client:pickup after the 15 s delay')
    local pick = ClientEvents('crimson-police:client:pickup', src, mark)[1]
    local drop = pick and pick.args[2]
    local nearest, best
    for _, d in ipairs(Config.Downed.dropOffs) do
        local dd = U.dist(H.players[src].coords, d)
        if not best or dd < best then nearest, best = d, dd end
    end
    H.ok(drop ~= nil and U.dist(drop, nearest) < 1.0, 'moved to the nearest drop-off')
    Secs(2)
    H.eq(#ClientEvents('hospital:client:Revive', src, mark), 1, 'revived with SC-Ambulance\'s own revive client event')
    PD[src].metadata.isdead = false
    H.fire('crimson-police:server:pickupDone', src, run.id, true)
    Secs(1)
    H.eq(Flag(src), nil, 'the flag is cleared once the pick-up is complete')
    local banned = 0
    for _, e in ipairs(H.events) do
        if e.name == 'hospital:server:RevivePlayer' or e.name == 'hospital:client:RevivePlayer'
            or e.name == 'hospital:client:HelpPerson' or e.name == 'sc-ambulance:client:TargetRevive' then
            banned = banned + 1
        end
    end
    H.eq(banned, 0, 'never hospital:server:RevivePlayer (or the events that send it)')
    H.eq(#ClientEvents('crimson-police:client:requestEMS', src, mark), 0, 'no EMS request while no EMS is on duty')
    Secs(4)
    H.eq(#ClientEvents('crimson-police:client:pickup', src, mark), 1, 'the pick-up happens once')
    Config.DisabledMissions = {}
end

-- ============================================================================
--                    4b. DOWNED IN A UNIT WITH EMS ON DUTY
-- ============================================================================
-- Pay tier kept, EMS request, no downed bonus.

do
    Config.DisabledMissions = TACTICAL_OTHERS
    local chance = Config.Events.modifierChance
    Config.Events.modifierChance = 0
    doctors = 1                                   -- sc-ambulance says 1, and one ambulance player is on duty
    FormUnit(10, 11)
    Place(10, vec3(0.0, 0.0, 0.0))
    Place(11, vec3(4.0, 0.0, 0.0))
    local ok, data = Act('server:acceptType', 10, 'tactical')
    H.eq(ok, true, 'unit accepts Tactical: ' .. tostring(data))
    local run = Runs.getBySrc(10)
    Arrive(run, 10)
    Arrive(run, 11)
    H.eq(run.payTier and run.payTier.tier, 'reinforced', 'Reinforced')
    Place(10, run.location.start.coords)
    Place(11, run.location.start.coords)
    ClearHostiles(run, 10)
    H.eq(run.objectiveIndex, 2, 'objective 1 of 2 done together')
    local mark = #H.events
    PD[11].metadata.inlaststand = true
    Secs(3)
    H.eq(Runs.getBySrc(11), nil, 'last stand counts as downed: removed')
    H.eq(Runs.getBySrc(10), run, 'the partner carries on')
    H.eq(run.payTier and run.payTier.tier, 'reinforced', 'downed keeps the points and cash tier')
    local r11 = Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[11] })[1] or {}
    H.eq(r11.state, 'failed', 'downed row failed')
    H.eq(r11.end_reason, 'downed', 'end_reason downed')
    H.eq(r11.final_points, math.floor(0.25 * 200 * (1 / 2)), 'Failed: 25% of P x the share of objectives done (1 of 2)')
    H.eq(Flag(11), nil, 'EMS on duty: the flag is removed before the EMS request')
    H.eq(#ClientEvents('crimson-police:client:requestEMS', 11, mark), 1, 'the EMS request is sent from their client')
    H.eq(#ClientEvents('crimson-police:client:pickup', 11, mark), 0, 'no NPC pick-up while EMS is on duty')
    H.eq(#ClientEvents('hospital:client:Revive', 11, mark), 0, 'and no revive')
    SecureScene(run, 10)
    H.eq(run.state, 'ended', 'the partner completes')
    local r10 = Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[10] })[1] or {}
    H.eq(r10.tier, 'reinforced', 'row keeps Reinforced')
    H.eq(r10.cash_paid, 920, '$800 x 1.15')
    local bd = U.jsonField(r10.breakdown) or {}
    local got = false
    for _, b in ipairs(bd.points and bd.points.bonuses or {}) do
        if b.id == 'no_participant_downed' then got = true end
    end
    H.eq(got, false, 'a participant went down: no "no participant downed" bonus')
    PD[11].metadata.inlaststand = false
    doctors = 0
    CP.Units.remove(10, { reason = 'left', silent = true })
    CP.Units.remove(11, { reason = 'left', silent = true })
    Config.Events.modifierChance = chance
    Config.DisabledMissions = {}
end

-- ============================================================================
--      5 + 6. CROSS-DEPARTMENT MISSION; an admin test run during its lock
-- ============================================================================

do
    local chance = Config.Events.modifierChance
    Config.Events.modifierChance = 1.0          -- operations never roll a modifier, whatever the chance
    local mark = #H.events
    local ok, data = Act('server:sup:opLaunch', 3, { missionId = 'gang_shootout' })
    H.eq(ok, true, 'a SAST supervisor launches Gang Shootout as a Cross-Department Mission: ' .. tostring(data))
    local opId = data and data.id
    H.eq(CP.Operations.isLocked(), true, 'the boards are locked')
    local launched = 0
    for _, e in ipairs(ClientEvents('crimson-police:client:operation', nil, mark)) do
        if e.args[1] == 'launched' then launched = launched + 1 end
    end
    H.ok(launched >= 6, 'every on-duty officer of every department is told (' .. launched .. ')')
    for _, s in ipairs({ 1, 2, 7 }) do
        local b = Cb('getMissionTypes', s)
        H.eq(b and #b.cards, 0, ('board of %s: no type cards'):format(CID[s]))
        H.eq(b and b.boss, nil, ('board of %s: no Weekly Boss card'):format(CID[s]))
        H.eq(b and b.operation and b.operation.missionLabel, 'Gang Shootout',
            ('board of %s: only the operation card'):format(CID[s]))
    end
    ok, data = Act('server:acceptType', 7, 'patrol')
    H.eq(data, 'err.operation_locked', 'every other new mission is refused')
    ok, data = Act('server:acceptType', 7, 'weekly_boss')
    H.eq(ok, false, 'the Weekly Boss too (' .. tostring(data) .. ')')

    -- 6. the admin test run (the only exception to the lock): nothing saved, no cooldown
    do
        local rowsBefore = tonumber(H.sql('SELECT COUNT(*) AS n FROM cp_mission_runs')[1].n)
        local moneyBefore = #addMoney
        Place(5, vec3(-500.0, 500.0, 50.0))
        local okT, test = Act('server:admin:startTest', 5,
            { missionId = 'beat_patrol', location = 1, tier = 'heavy', useStartRoute = false })
        H.eq(okT, true, 'admin test run starts during the operation lock: ' .. tostring(test))
        local trun = Runs.getBySrc(5)
        H.ok(trun ~= nil and trun.test ~= nil, 'a test run')
        H.eq(trun and trun.expectedTier, 'heavy', 'the chosen tier, whatever the number of testers')
        H.eq(trun and trun.modifier, nil, 'no modifier on a test run')
        H.eq(CP.Draw.isReserved('beat_patrol', 1), true, 'a test run still reserves its location')
        local auditT =
            H.sql('SELECT COUNT(*) AS n FROM cp_audit WHERE actor = ? AND action LIKE \'%est%\'', { CID[5] })[1]
        H.ok(tonumber(auditT.n) >= 1, 'the test start is audited')
        Arrive(trun, 5)
        H.eq(trun.state, 'in_progress', 'test run in progress')
        H.eq(trun.tier and trun.tier.tier, 'heavy', 'forced tier Heavy')
        local tmark = #H.events
        local okC, cd = Act('server:test:control', 5, { control = 'complete' })
        H.eq(okC, true, 'force complete: ' .. tostring(cd))
        Secs(1)
        H.eq(trun.state, 'ended', 'test run ended')
        local ended = ClientEvents('crimson-police:client:runEnded', 5, tmark)[1]
        local rr = ended and ended.args[4]
        H.eq(rr and rr.test, true, 'the result screen says TEST RUN')
        H.ok(rr and rr.cash and rr.cash.amount == U.round(250 * 1.30),
            'it still shows the cash the run would have earned')
        H.eq(tonumber(H.sql('SELECT COUNT(*) AS n FROM cp_mission_runs')[1].n), rowsBefore, 'a test run writes no row')
        H.eq(#Rows('run_uuid = ?', { trun.id }), 0, 'no row for the test run id')
        local cd5 = Runs.cooldowns(CID[5])
        H.eq(next(cd5.types), nil, 'no type cooldown from a test run')
        H.eq(next(cd5.missions), nil, 'no mission cooldown from a test run')
        H.eq(#addMoney, moneyBefore, 'nothing paid')
        H.eq(Flag(5), nil, 'test run flag removed')
    end

    for _, s in ipairs({ 1, 2, 7 }) do
        ok, data = Act('server:joinOperation', s, opId)
        H.eq(ok, true, ('%s joins: %s'):format(CID[s], tostring(data)))
    end
    ok, data = Act('server:joinOperation', 1, opId)
    H.eq(data, 'err.op_already_joined', 'joining twice is refused')
    Place(1, vec3(0.0, 0.0, 0.0))
    Place(2, vec3(3.0, 0.0, 0.0))
    Place(7, vec3(6.0, 0.0, 0.0))
    ok, data = Act('server:sup:opStart', 3)
    H.eq(ok, true, 'the launcher taps Start now: ' .. tostring(data))
    local run = Runs.getBySrc(1)
    H.ok(run ~= nil and run.operationId == opId, 'the operation run (cooldowns of the joiners are ignored)')
    H.eq(run and run.modifier, nil, 'no modifier on a Cross-Department Mission')
    ok, data = Act('server:joinOperation', 6, opId)
    H.eq(ok, false, 'nobody can join after the start (' .. tostring(data) .. ')')
    for _, s in ipairs({ 1, 2, 7 }) do Arrive(run, s) end
    H.eq(run.state, 'in_progress', 'in progress')
    H.eq(run.tier and run.tier.tier, 'heavy', 'three participants: Heavy')
    H.eq(CP.Operations.isLocked(), true, 'still locked while the run is on')
    Place(1, run.location.start.coords)
    Place(2, run.location.start.coords)
    Place(7, run.location.start.coords)
    ClearHostiles(run, 1)
    H.eq(run.objectiveIndex, 2, 'hostiles neutralised')
    Place(2, run.location.scene)
    Place(7, run.location.scene)
    SecureScene(run, 1)
    H.eq(run.state, 'ended', 'the operation run is completed')
    H.eq(CP.Operations.isLocked(), false, 'Completed: the lock lifts')
    local opRow = H.sql('SELECT status FROM cp_operations WHERE id = ?', { opId })[1] or {}
    H.eq(opRow.status, 'completed', 'cp_operations row completed')
    local r = Rows('run_uuid = ?', { run.id })
    H.eq(#r, 3, 'one row per participant')
    for _, row in ipairs(r) do
        H.eq(row.state, 'completed', row.citizenid .. ': completed')
        H.eq(tonumber(row.departments_n), 2, row.citizenid .. ': two departments')
        H.eq(row.tier, 'heavy', row.citizenid .. ': Heavy')
        H.eq(row.cash_paid, 1040, row.citizenid .. ': $800 x 1.30 = $1,040')
        H.eq(row.cash_status, 'paid', row.citizenid .. ': paid')
        local bd = U.jsonField(row.breakdown) or {}
        H.eq(bd.points and bd.points.mCross, 1.10, row.citizenid .. ': cross-department bonus x1.10')
    end
    local opIds =
        H.sql('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE run_uuid = ? AND operation_id = ?', { run.id, opId })[1]
    H.eq(tonumber(opIds.n), 3, 'rows carry the operation id')
    local b = Cb('getMissionTypes', 6)
    H.eq(b and #b.cards, 4, 'the board shows the four type cards again')
    H.eq(b and b.operation, nil, 'and no operation card')
    Config.Events.modifierChance = chance
end

-- ============================================================================
--          5b. OPERATION WITH AN IDLE JOINER, THEN CANCELLED MID-RUN
-- ============================================================================

do
    local ok, data = Act('server:sup:opLaunch', 8, { missionId = 'gang_shootout' })
    H.eq(data, 'err.op_cooldown', 'at most one launch every 30 minutes')
    ok, data = Act('server:sup:opLaunch', 8, { missionId = 'weekly_boss_kingpin' })
    H.eq(ok, false, 'the Weekly Boss can never be launched (' .. tostring(data) .. ')')
    ok, data = Act('server:sup:opLaunch', 8, { missionId = 'beat_patrol' })
    H.eq(ok, false, 'a one-officer mission cannot be launched (' .. tostring(data) .. ')')
    H.time = H.time + (Config.CrossDept.cooldown or 1800) + 5     -- the next launch is allowed
    ok, data = Act('server:sup:opLaunch', 1, { missionId = 'gang_shootout' })
    H.eq(data, 'err.no_permission', 'officers cannot launch')
    ok, data = Act('server:sup:opLaunch', 8, { missionId = 'gang_shootout' })
    H.eq(ok, true, 'a FIB supervisor launches again after the launch cooldown: ' .. tostring(data))
    local opId = data and data.id
    ok, data = Act('server:sup:opStart', 8)
    H.eq(ok, false, 'Start now needs at least 2 participants (' .. tostring(data) .. ')')
    for _, s in ipairs({ 1, 2, 6 }) do
        ok, data = Act('server:joinOperation', s, opId)
        H.eq(ok, true, ('%s joins: %s'):format(CID[s], tostring(data)))
    end
    Place(1, vec3(0.0, 0.0, 0.0))
    Place(2, vec3(3.0, 0.0, 0.0))
    Place(6, vec3(-2500.0, 3000.0, 30.0))
    ok, data = Act('server:sup:opStart', 8)
    H.eq(ok, true, 'started: ' .. tostring(data))
    local run = Runs.getBySrc(1)
    H.eq(run and run.expectedTier, 'heavy', 'expected Heavy for three')
    Arrive(run, 1)
    Arrive(run, 2)
    H.eq(run.state, 'in_progress', 'in progress with the first arrival')
    H.eq(run.tier and run.tier.tier, 'heavy', 'the tier counts everyone still on the run (Heavy)')
    -- the third joiner keeps driving on the start route but never gets there
    local started = run.startedAt
    while run.participants[6].status == 'active' and os.time() - started < 200 do
        H.fire('crimson-police:server:routeStatus', 6, run.id, 10.0, H.players[6].coords)
        Secs(2)
    end
    H.eq(run.participants[6].endReason, 'idle',
        '3 minutes after In progress the joiner who never arrived is removed (idle)')
    H.eq(run.tier and run.tier.tier, 'reinforced', 'the tier is recalculated down to Reinforced')
    H.eq(run.payTier and run.payTier.tier, 'reinforced', 'and the pay tier with it')
    local r6 = Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[6] })[1] or {}
    H.eq(r6.state, 'abandoned', 'idle: Abandoned')
    local cdBefore = { [1] = U.deepcopy(Runs.cooldowns(CID[1])), [2] = U.deepcopy(Runs.cooldowns(CID[2])) }
    ok, data = Act('server:sup:opCancel', 4, { reason = 'real incident downtown' })
    H.eq(ok, true, 'another supervisor cancels the running operation: ' .. tostring(data))
    H.eq(CP.Operations.isLocked(), false, 'the lock lifts on cancel')
    H.eq(run.state, 'ended', 'the run ends for everyone still on it')
    for _, s in ipairs({ 1, 2 }) do
        local r = Rows('run_uuid = ? AND citizenid = ?', { run.id, CID[s] })[1] or {}
        H.eq(r.end_reason, 'cancelled', CID[s] .. ': end_reason cancelled')
        H.eq(r.state, 'abandoned', CID[s] .. ': Abandoned')
    end
    for _, s2 in ipairs({ 1, 2 }) do
        local cd = Runs.cooldowns(CID[s2])
        H.eq(cd.types.tactical, cdBefore[s2].types.tactical, CID[s2] .. ': cancelled starts no type cooldown')
        H.eq(cd.missions.gang_shootout, cdBefore[s2].missions.gang_shootout, CID[s2] .. ': and no mission cooldown')
    end
    local opRow = H.sql('SELECT status FROM cp_operations WHERE id = ?', { opId })[1] or {}
    H.eq(opRow.status, 'cancelled', 'cp_operations row cancelled')
end

-- ============================================================================
--                         5c. EVERY PARTICIPANT LEAVES
-- ============================================================================
-- The operation waits (still locked), relaunch, cancel.

do
    H.time = H.time + (Config.CrossDept.cooldown or 1800) + 5
    local ok, data = Act('server:admin:opLaunch', 5, { missionId = 'gang_shootout' })
    H.eq(ok, true, 'an admin launches: ' .. tostring(data))
    local opId = data and data.id
    for _, s2 in ipairs({ 1, 2 }) do
        ok, data = Act('server:joinOperation', s2, opId)
        H.eq(ok, true, ('%s joins: %s'):format(CID[s2], tostring(data)))
    end
    Place(1, vec3(0.0, 0.0, 0.0))
    Place(2, vec3(3.0, 0.0, 0.0))
    ok, data = Act('server:admin:opStart', 5)
    H.eq(ok, true, 'the admin starts it: ' .. tostring(data))
    local run = Runs.getBySrc(1)
    Arrive(run, 1)
    Arrive(run, 2)
    Secs(3)
    local live = Runs.entitiesFor(run, {})
    H.ok(#live >= 7, 'hostiles are out (' .. #live .. ')')
    Act('server:abandon', 1, run.id)
    H.eq(Flag(1), nil, 'the one who left loses the flag at once')
    H.eq(type(Flag(2)) == 'table', true, 'the one still on the run keeps it')
    Act('server:abandon', 2, run.id)
    H.eq(run.state, 'ended', 'every participant left')
    local left = 0
    for _, e in ipairs(live) do if ents[e.entity].exists then left = left + 1 end end
    H.eq(left, 0, 'the server deletes everything once no participant is left')
    H.eq(Flag(2), nil, 'flag removed')
    local active = CP.Operations.active()
    H.eq(active and active.status, 'waiting', 'the operation stays active (waiting)')
    H.eq(CP.Operations.isLocked(), true, 'the boards stay locked')
    ok, data = Act('server:acceptType', 6, 'patrol')
    H.eq(data, 'err.operation_locked', 'other missions are still refused')
    ok, data = Act('server:sup:opRelaunch', 4, {})
    H.eq(ok, true, 'any supervisor can relaunch it: ' .. tostring(data))
    H.eq(CP.Operations.active() and CP.Operations.active().status, 'joining', 'a new join window')
    -- nobody joins the new window; 30 minutes with no run in progress -> auto-cancel
    H.time = H.time + (Config.CrossDept.idleCancel or 1800) + 5
    Secs(12)
    H.eq(CP.Operations.isLocked(), false, 'auto-cancelled after 30 minutes with no run in progress')
    if CP.Operations.isLocked() then Act('server:sup:opCancel', 3, { reason = 'cleanup' }) end
    ok, data = Act('server:sup:opCancel', 3, { reason = 'not enough people' })
    H.eq(data, 'err.op_none', 'nothing left to cancel')
    local opRow = H.sql('SELECT status FROM cp_operations WHERE id = ?', { opId })[1] or {}
    H.eq(opRow.status, 'cancelled', 'cp_operations row cancelled')
end

-- ============================================================================
--             BEAT PATROL DRIVER: accept, arrive, five checkpoints
-- ============================================================================

local function StartPatrol(src)
    Config.DisabledMissions = { 'business_check', 'street_race_bust' }
    Place(src, vec3(150.0, -1200.0, 29.0))
    local ok, data = Act('server:acceptType', src, 'patrol')
    H.eq(ok, true, ('%s accepts Patrol: %s'):format(CID[src], tostring(data)))
    local run = Runs.getBySrc(src)
    Arrive(run, src)
    H.eq(run and run.state, 'in_progress', ('%s: Beat Patrol in progress'):format(CID[src]))
    local veh = VehicleFor(src, 'sultan') -- any vehicle: the checkpoints only need the officer at the wheel
    Telemetry(src, run, 'vehicle', { netId = ents[veh].net })
    return run, veh
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

-- ============================================================================
--                                7. FLAGGED RUN
-- ============================================================================
-- Cash held, supervisor approval pays, own run refused.

do
    local chance = Config.Events.modifierChance
    Config.Events.modifierChance = 0
    local src, cid = 4, CID[4]          -- a FIB supervisor playing a mission like any officer
    local run, veh = StartPatrol(src)
    DriveCheckpoints(src, run, veh, 1, 1)
    -- a teleport between two objective events: 3 km in about a second
    Place(src, vec3(3000.0, 3000.0, 30.0))
    Secs(1)
    Objective(src, run, 1, CheckpointEv(2, veh))
    H.eq(run.flagged and run.flagged.reason, 'speed', 'impossible speed between objective events flags the run')
    DriveCheckpoints(src, run, veh, 2, 5, 20)
    H.eq(run.state, 'ended', 'the flagged run still completes')
    local r = Rows('run_uuid = ?', { run.id })[1] or {}
    H.eq(r.state, 'completed', 'completed')
    H.eq(H.bit(r.flagged), 1, 'row flagged')
    H.eq(r.flag_reason, 'speed', 'flag_reason speed')
    H.eq(r.cash_status, 'held', 'cash held')
    H.eq(r.cash_paid, 0, 'nothing paid yet')
    local paidTo = function()
        local n, amount = 0, 0
        for _, m in ipairs(addMoney) do if m.citizenid == cid then n = n + 1 amount = amount + m.amount end end
        return n, amount
    end
    H.eq(paidTo(), 0, 'no AddMoney for a held row')
    local xpBefore = tonumber((H.sql('SELECT xp FROM cp_officers WHERE citizenid = ?', { cid })[1] or {}).xp) or 0
    local board = Cb('getBoard', 8, { period = 'weekly', filter = 'overall' })
    for _, row in ipairs(board and board.rows or {}) do
        H.ok(row.citizenid ~= cid, 'a flagged run is held off the board')
    end

    local queue = Cb('sup:getReviewQueue', src)
    local own = false
    for _, f in ipairs(queue and queue.flagged or {}) do if f.id == r.id or f.rowId == r.id then own = true end end
    H.eq(own, false, 'their own run never appears in their Review Queue')
    local ok, data = Act('server:sup:reviewFlagged', src,
        { rowId = r.id, decision = 'approve', reason = 'looks fine to me' })
    H.eq(data, 'err.own_run', 'approving your own run is refused')
    ok, data = Act('server:sup:reviewFlagged', src, { rowId = r.id, decision = 'void', reason = 'nope' })
    H.eq(data, 'err.own_run', 'voiding your own run is refused')
    ok, data = Act('server:sup:reviewFlagged', 3, { rowId = r.id, decision = 'approve', reason = 'not my department' })
    H.eq(ok, false, 'a SAST supervisor cannot review a FIB-only run (' .. tostring(data) .. ')')
    ok, data = Act('server:sup:reviewFlagged', 1, { rowId = r.id, decision = 'approve', reason = 'officer' })
    H.eq(data, 'err.no_permission', 'an officer cannot review')
    ok, data = Act('server:sup:reviewFlagged', 8, { rowId = r.id, decision = 'approve', reason = '' })
    H.eq(data, 'err.reason_required', 'a reason is required')
    local queue8 = Cb('sup:getReviewQueue', 8)
    local seen = false
    for _, f in ipairs(queue8 and queue8.flagged or {}) do if f.id == r.id or f.rowId == r.id then seen = true end end
    H.eq(seen, true, 'the run is in the other FIB supervisor\'s Review Queue')
    ok, data = Act('server:sup:reviewFlagged', 8,
        { rowId = r.id, decision = 'approve', reason = 'GPS glitch, route checked' })
    H.eq(ok, true, 'another FIB supervisor approves: ' .. tostring(data))
    r = Rows('id = ?', { r.id })[1] or {}
    H.eq(H.bit(r.flagged), 0, 'no longer flagged')
    H.eq(r.cash_status, 'paid', 'the held cash is paid on approval')
    H.eq(r.cash_paid, 250, '$250')
    local n, amount = paidTo()
    H.eq(n, 1, 'one AddMoney')
    H.eq(amount, 250, 'of the row amount')
    local tx = 0
    for _, t in ipairs(bank.tx) do if t.id == ('CP-%s-%s'):format(run.id, cid) then tx = tx + 1 end end
    H.eq(tx, 1, 'one Renewed-Banking entry for the approved row')
    local xpAfter = tonumber((H.sql('SELECT xp FROM cp_officers WHERE citizenid = ?', { cid })[1] or {}).xp) or 0
    H.eq(xpAfter - xpBefore, r.final_points, 'XP added once the flagged run is approved')
    ok, data = Act('server:sup:reviewFlagged', 8, { rowId = r.id, decision = 'approve', reason = 'again' })
    H.eq(ok, false, 'a second approval is refused (' .. tostring(data) .. ')')
    H.eq(paidTo(), 1, 'and pays nothing more')
    local audit = H.sql('SELECT COUNT(*) AS n FROM cp_audit WHERE action = \'approveFlagged\' AND target LIKE ?',
        { '#' .. r.id .. ' %' })[1]
    H.eq(tonumber(audit.n), 1, 'the approval is audited')
    Config.Events.modifierChance = chance
    Config.DisabledMissions = {}
end

-- ============================================================================
--                  7b. APPROVED WHILE THE OFFICER IS OFFLINE
-- ============================================================================
-- Pending, paid at the next login.

do
    local chance = Config.Events.modifierChance
    Config.Events.modifierChance = 0
    local src, cid = 7, CID[7]
    local run, veh = StartPatrol(src)
    DriveCheckpoints(src, run, veh, 1, 1)
    Place(src, vec3(-3000.0, 6000.0, 30.0))
    Secs(1)
    Objective(src, run, 1, CheckpointEv(2, veh))
    H.eq(run.flagged and run.flagged.reason, 'speed', 'flagged for speed')
    DriveCheckpoints(src, run, veh, 2, 5, 20)
    local r = Rows('run_uuid = ?', { run.id })[1] or {}
    H.eq(r.cash_status, 'held', 'held')
    offline[src] = true
    H.fire('playerDropped', src, 'quit')
    Secs(1)
    local ok, data = Act('server:sup:reviewFlagged', 8,
        { rowId = r.id, decision = 'approve', reason = 'verified on CCTV' })
    H.eq(ok, true, 'approved while the officer is offline: ' .. tostring(data))
    r = Rows('id = ?', { r.id })[1] or {}
    H.eq(r.cash_status, 'pending', 'the payment waits (pending)')
    local base = 0
    for _, m in ipairs(addMoney) do if m.citizenid == cid then base = base + 1 end end
    local function Paid()
        local n = 0
        for _, m in ipairs(addMoney) do if m.citizenid == cid then n = n + 1 end end
        return n - base
    end
    H.eq(Paid(), 0, 'nothing paid while offline')
    offline[src] = nil
    TriggerEvent('QBCore:Server:PlayerLoaded', QbxPlayer(src))
    Secs(7)
    r = Rows('id = ?', { r.id })[1] or {}
    H.eq(r.cash_status, 'paid', 'paid the next time they load in')
    H.eq(Paid(), 1, 'one AddMoney')
    local tx = 0
    for _, t in ipairs(bank.tx) do if t.id == ('CP-%s-%s'):format(run.id, cid) then tx = tx + 1 end end
    H.eq(tx, 1, 'with its Renewed-Banking entry')
    Config.Events.modifierChance = chance
    Config.DisabledMissions = {}
end

-- ============================================================================
--                            7c. VOIDED FLAGGED RUN
-- ============================================================================
-- Cash stays held; the officer's dispute is approved and releases it.

do
    local chance = Config.Events.modifierChance
    Config.Events.modifierChance = 0
    local src, cid = 10, CID[10]
    local run, veh = StartPatrol(src)
    DriveCheckpoints(src, run, veh, 1, 1)
    Place(src, vec3(3000.0, -3000.0, 30.0))
    Secs(1)
    Objective(src, run, 1, CheckpointEv(2, veh))
    DriveCheckpoints(src, run, veh, 2, 5, 20)
    local r = Rows('run_uuid = ?', { run.id })[1] or {}
    H.eq(r.cash_status, 'held', 'flagged: held')
    local xpFlagged = tonumber((H.sql('SELECT xp FROM cp_officers WHERE citizenid = ?', { cid })[1] or {}).xp) or 0
    local ok, data = Act('server:sup:reviewFlagged', 3, { rowId = r.id, decision = 'void', reason = 'teleport' })
    H.eq(ok, true, 'a SAST supervisor voids it: ' .. tostring(data))
    r = Rows('id = ?', { r.id })[1] or {}
    H.eq(H.bit(r.voided), 1, 'voided')
    H.eq(r.cash_status, 'held', 'the held cash stays held during the dispute window')
    H.eq(CP.Cash._forfeitureJob(), 0, 'not forfeited inside the 48 h window')
    local xp0 = tonumber((H.sql('SELECT xp FROM cp_officers WHERE citizenid = ?', { cid })[1] or {}).xp) or 0
    H.eq(xp0, xpFlagged, 'voiding a run whose points never counted takes no XP away')
    ok, data = Act('server:dispute', 1, { rowId = r.id, reason = 'not mine' })
    H.eq(ok, false, 'nobody can dispute someone else\'s run (' .. tostring(data) .. ')')
    ok, data = Act('server:dispute', src,
        { rowId = r.id, reason = 'My game crashed and respawned me, check the route log' })
    H.eq(ok, true, 'the officer disputes the voided run: ' .. tostring(data))
    local disputeId = data and (data.id or data.disputeId)
    local list = CP.Disputes.forSupervisor(3)
    local found = false
    for _, d in ipairs(list or {}) do if d.rowId == r.id then found = true disputeId = disputeId or d.id end end
    H.eq(found, true, 'in the SAST supervisor\'s Review Queue')
    ok, data = Act('server:sup:handleDispute', 3,
        { disputeId = disputeId, decision = 'approve', reason = 'crash confirmed' })
    H.eq(ok, true, 'dispute approved: ' .. tostring(data))
    r = Rows('id = ?', { r.id })[1] or {}
    H.eq(H.bit(r.voided), 0, 'the run is restored')
    H.eq(r.cash_status, 'paid', 'and its held cash released')
    H.eq(r.cash_paid, 250, '$250')
    local xp1 = tonumber((H.sql('SELECT xp FROM cp_officers WHERE citizenid = ?', { cid })[1] or {}).xp) or 0
    H.eq(xp1 - xp0, r.final_points, 'XP given back')
    Config.Events.modifierChance = chance
    Config.DisabledMissions = {}
end

-- ============================================================================
--                                  8. PAYOUTS
-- ============================================================================
-- Supervisor limits, the admin lock, B locked at accept.

do
    local function Sup(src, amount, reason)
        return Act('server:sup:setTypePayout', src, { type = 'patrol', amount = amount, reason = reason })
    end
    local ok, data = Sup(1, 300, 'officer')
    H.eq(data, 'err.no_permission', 'an officer cannot change payouts')
    ok, data = Sup(3, 124, 'too low')
    H.eq(data, 'err.payout_out_of_range', 'below 50% of the config payout ($125) is refused')
    ok, data = Sup(3, 501, 'too high')
    H.eq(data, 'err.payout_out_of_range', 'above 200% of the config payout ($500) is refused')
    ok, data = Sup(3, 300, '')
    H.eq(data, 'err.reason_required', 'a reason is required')
    ok, data = Sup(3, 300, 'more patrols wanted')
    H.eq(ok, true, 'a supervisor sets Patrol to $300 within range: ' .. tostring(data))
    H.eq(CP.Payouts.typePayout('patrol'), 300, 'type payout $300')
    ok, data = Sup(4, 320, 'FIB wants more')
    H.eq(data, 'err.payout_cooldown', 'once per 30 minutes per type, for any supervisor')
    local audit = H.sql(
        'SELECT old_value, new_value, reason FROM cp_audit WHERE action = \'setTypePayout\' AND target = \'patrol\' ORDER BY id DESC LIMIT 1')[1] or {}
    H.eq(tostring(audit.old_value) .. '->' .. tostring(audit.new_value), '250->300',
        'audited with the old and the new value')

    -- B is locked at accept: an admin change mid-run does not touch it
    local run, veh = StartPatrol(2)
    H.eq(run.cashBase, 300, 'B = the supervisor payout at accept')
    ok, data = Act('server:admin:setMissionPayout', 3,
        { missionId = 'beat_patrol', amount = 900, reason = 'sup tries' })
    H.eq(ok, false, 'only admins set a single mission payout (' .. tostring(data) .. ')')
    ok, data = Act('server:admin:setMissionPayout', 5,
        { missionId = 'beat_patrol', amount = 900, reason = 'event week' })
    H.eq(ok, true, 'admin sets the Beat Patrol payout: ' .. tostring(data))
    H.eq(CP.Payouts.baseFor(CP.Missions.get('beat_patrol')), 900, 'the mission payout overrides the type payout')
    DriveCheckpoints(2, run, veh)
    local r = Rows('run_uuid = ?', { run.id })[1] or {}
    H.eq(r.cash_base, 300, 'the run already underway keeps B = $300')
    local rm = H.sql('SELECT modifier FROM cp_mission_runs WHERE id = ?', { r.id })[1] or {}
    H.eq(r.cash_paid, U.round(300 * (rm.modifier and Config.Events.modifierCash or 1.0)),
        'and pays round($300 x M_mod)')

    ok, data = Act('server:admin:setTypePayout', 5, { type = 'patrol', amount = 450, reason = 'admin decides' })
    H.eq(ok, true, 'admin sets the Patrol type payout (permanent): ' .. tostring(data))
    local _, locked = CP.Payouts.typePayout('patrol')
    H.eq(locked, true, 'the type is admin-locked')
    H.time = H.time + 1900                   -- past the supervisor cooldown
    ok, data = Sup(3, 400, 'after the cooldown')
    H.eq(data, 'err.payout_locked', 'supervisors cannot change an admin-set type ("Set by admin")')
    local view = Cb('sup:getPayouts', 3)
    local entry
    for _, t in ipairs(view and view.types or {}) do if t.key == 'patrol' then entry = t end end
    H.ok(entry ~= nil and entry.adminLocked == true, 'the Supervisor Payouts screen shows it as set by admin')
    H.eq(CP.Payouts.baseFor(CP.Missions.get('beat_patrol')), 900, 'the admin mission payout ignores the type change')
    ok, data = Act('server:admin:setTypePayout', 3, { type = 'patrol', reason = 'sup clears' })
    H.eq(ok, false, 'a supervisor cannot clear (' .. tostring(data) .. ')')
    ok, data = Act('server:admin:setTypePayout', 5, { type = 'patrol', clear = true, reason = 'back to config' })
    H.eq(ok, true, 'admin clears the type payout: ' .. tostring(data))
    H.eq(CP.Payouts.typePayout('patrol'), 250, 'back to the config payout')
    ok, data = Sup(3, 260, 'unlocked again')
    H.eq(ok, true, 'cleared: unlocked for supervisors again (' .. tostring(data) .. ')')
    ok, data = Act('server:admin:setMissionPayout', 5,
        { missionId = 'beat_patrol', clear = true, reason = 'event over' })
    H.eq(ok, true, 'admin clears the mission payout')
    H.eq(CP.Payouts.baseFor(CP.Missions.get('beat_patrol')), 260, 'the mission follows its type payout again')
    ok, data = Act('server:admin:setTypePayout', 5, { type = 'patrol', amount = 25001, reason = 'too much' })
    H.eq(data, 'err.payout_out_of_range', 'admins are bound by the overall $0-$25,000 range')
    Config.DisabledMissions = {}
end

-- ============================================================================
--                          10. LOSING ACCESS MID-RUN
-- ============================================================================
-- Off duty (Abandoned) and disconnect (Failed), both with the type cooldown.

do
    local chance = Config.Events.modifierChance
    Config.Events.modifierChance = 0
    local run10 = StartPatrol(10)
    PD[10].job.onduty = false
    TriggerEvent('QBCore:Server:SetDuty', 10, false)
    Secs(2)
    H.eq(Runs.getBySrc(10), nil, 'going off duty removes the officer from the run')
    local r = Rows('run_uuid = ?', { run10.id })[1] or {}
    H.eq(r.state, 'abandoned', 'off duty: Abandoned')
    H.eq(r.end_reason, 'off_duty', 'end_reason off_duty')
    H.ok((Runs.cooldowns(CID[10]).types.patrol or 0) > os.time(), 'off duty: type cooldown')
    PD[10].job.onduty = true

    local run11 = StartPatrol(11)
    offline[11] = true
    H.fire('playerDropped', 11, 'quit')
    Secs(2)
    H.eq(Runs.getBySrc(11), nil, 'a disconnect removes the participant')
    r = Rows('run_uuid = ?', { run11.id })[1] or {}
    H.eq(r.state, 'failed', 'disconnected: Failed (never a free reroll)')
    H.eq(r.end_reason, 'disconnected', 'end_reason disconnected')
    H.eq(r.cash_paid, 0, 'no cash')
    H.ok((Runs.cooldowns(CID[11]).types.patrol or 0) > os.time(), 'disconnected: type cooldown')
    H.eq(Flag(11), nil, 'no flag left behind')
    offline[11] = nil

    -- off the start route: warning after 10 s, Abandoned (off_route) after 30 s in one stretch
    Place(8, vec3(150.0, -1200.0, 29.0))
    local ok, data = Act('server:acceptType', 8, 'patrol')
    H.eq(ok, true, 'accept: ' .. tostring(data))
    local run8 = Runs.getBySrc(8)
    local mark = #H.events
    for _ = 1, 3 do
        H.fire('crimson-police:server:routeStatus', 8, run8.id, 20.0, H.players[8].coords)
        Secs(2)
    end
    ok, data = Act('server:recalcRoute', 8, run8.id)
    local recalc = ClientEvents('crimson-police:client:routeRecalc', 8, mark)
    H.ok(#recalc >= 1 or ok == true, 'Recalculate route is answered')
    local t0 = os.time()
    local warned = nil
    while Runs.getBySrc(8) and os.time() - t0 < 45 do
        H.fire('crimson-police:server:routeStatus', 8, run8.id, 200.0, H.players[8].coords)
        Secs(2)
        if not warned then
            for _, e in ipairs(ClientEvents('crimson-police:client:routeWarning', 8, mark)) do
                if e.args[2] ~= nil then warned = os.time() - t0 break end
            end
        end
    end
    H.ok(warned ~= nil and warned >= 9 and warned <= 13,
        'the off-route warning after about 10 s (' .. tostring(warned) .. ')')
    H.eq(Runs.getBySrc(8), nil, 'still off route 30 s after leaving it: removed')
    local left = os.time() - t0
    H.ok(left >= 29 and left <= 34, 'after about 30 s (' .. left .. ')')
    local r8 = Rows('run_uuid = ?', { run8.id })[1] or {}
    H.eq(r8.end_reason, 'off_route', 'end_reason off_route')
    H.eq(r8.state, 'abandoned', 'Abandoned')
    H.ok((Runs.cooldowns(CID[8]).types.patrol or 0) > os.time(), 'off_route: type cooldown')
    Config.Events.modifierChance = chance
    Config.DisabledMissions = {}
end

-- ============================================================================
-- 3b. REAL CALL BEFORE THE START IS REACHED; un-marks after and within the 60 s window on solo runs
-- ============================================================================

do
    local chance = Config.Events.modifierChance
    Config.Events.modifierChance = 0
    Config.DisabledMissions = { 'business_check', 'street_race_bust' }
    H.sql([[INSERT INTO mdt_dispatch (id, type, message, active, unique_id) VALUES
        (701, '10-50 - Vehicle Crash', 'real call 3b', 1, 'call_3b'), (702, '911', 'real call 3c', 1, 'call_3c')]])
    Place(2, vec3(150.0, -1200.0, 29.0))
    local ok, data = Act('server:acceptType', 2, 'patrol')
    H.eq(ok, true, 'accept: ' .. tostring(data))
    local run = Runs.getBySrc(2)
    H.eq(run and run.state, 'accepted', 'still driving to the start')
    H.fire('sc-dispatch:server:ToggleResponding', 2, 'call_3b', true)
    Secs(2)
    H.eq(Runs.getBySrc(2), nil, 'a real call ends the run before the start too')
    local r = Rows('run_uuid = ?', { run.id })[1] or {}
    H.eq(r.end_reason, 'real_call', 'real_call')
    Secs(62)
    H.fire('sc-dispatch:server:ToggleResponding', 2, 'call_3b', false)
    Secs(2)
    r = Rows('run_uuid = ?', { run.id })[1] or {}
    H.eq(r.end_reason, 'real_call', 'un-marked after 60 s: the abandon stays free')
    H.eq(Runs.cooldowns(CID[2]).types.patrol, nil, 'no type cooldown')

    run = StartPatrol(7)
    H.fire('sc-dispatch:server:ToggleResponding', 7, 702, true)
    Secs(2)
    H.eq(Runs.getBySrc(7), nil, 'solo officer: the run ends on the real call (by its row id)')
    H.eq(run.state, 'ended', 'nobody left: the run is over')
    Secs(30)
    H.fire('sc-dispatch:server:ToggleResponding', 7, 'call_3c', false)
    Secs(2)
    r = Rows('run_uuid = ?', { run.id })[1] or {}
    H.eq(r.end_reason, 'real_call_cancelled',
        'un-marked within 60 s (other id form) after the run ended: real_call_cancelled')
    H.ok((Runs.cooldowns(CID[7]).types.patrol or 0) > os.time(), 'the type cooldown applies')
    Config.Events.modifierChance = chance
    Config.DisabledMissions = {}
end

-- ============================================================================
--                           9. RESOURCE STOP MID-RUN
-- ============================================================================
-- Everything deleted, nothing written.

do
    Config.DisabledMissions = TACTICAL_OTHERS
    local src = 8
    Place(src, vec3(0.0, 0.0, 0.0))
    local ok, data = Act('server:acceptType', src, 'tactical')
    H.eq(ok, true, 'accept Tactical: ' .. tostring(data))
    local run = Runs.getBySrc(src)
    Arrive(run, src)
    Secs(3)
    local spawned = Runs.entitiesFor(run, {})
    H.ok(#spawned >= 7, 'the first wave is out (' .. #spawned .. ' entities)')
    H.eq(type(Flag(src)) == 'table' and Flag(src).source, 'crimson-police', 'flag on')
    -- the backstop: mission gunfire that still reached SC-Dispatch is cleared (never for bystanders)
    local c0 = #cleared
    local t = os.time()
    H.fire('sc-dispatch:server:ShotsFired', src, { coords = H.players[src].coords, street = 'Yard', zone = 'TERMINA' })
    Place(9, H.players[src].coords)
    H.fire('sc-dispatch:server:ShotsFired', 9, { coords = H.players[9].coords, street = 'Yard', zone = 'TERMINA' })
    Secs(2)
    local ids, jobsOk = {}, true
    for i = c0 + 1, #cleared do
        ids[cleared[i].id] = true
        if cleared[i].jobs[1] ~= 'police' then jobsOk = false end
    end
    H.ok(ids[('shots_%d_%d'):format(src, t)] == true, 'shots_<src>_<time> of the participant is cleared')
    H.ok(ids[('shots_%d_%d'):format(src, t - 1)] == true, 'and the previous second')
    H.eq(jobsOk, true, 'cleared for { \'police\' }')
    local bystander = false
    for id in pairs(ids) do if id:find('^shots_9_') then bystander = true end end
    H.eq(bystander, false, 'a bystander\'s shots-fired call is never cleared')
    c0 = #cleared
    t = os.time()
    H.fire('sc-dispatch:server:PlayerDown', src, { coords = H.players[src].coords })
    Secs(2)
    local down = false
    for i = c0 + 1, #cleared do
        if cleared[i].id == ('playerdown_%d_%d'):format(src, t) and cleared[i].jobs[2] == 'ambulance' then
            down = true
        end
    end
    H.eq(down, true, 'a flagged participant\'s person-down call is cleared for police and ambulance')
    -- a kill by a player who is not on the run flags it (outside help)
    local victim = Runs.entitiesFor(run, { obj = 1, kind = 'ped', alive = true })[1]
    ents[victim.entity].killer = 900
    ents[victim.entity].health = 0
    Secs(2)
    H.eq(run.flagged and run.flagged.reason, 'outside_help',
        'a mission NPC killed by a bystander flags the run (outside_help)')
    local helper = H.sql(
        'SELECT reason FROM cp_audit WHERE action = \'runFlagged\' AND target = ? AND new_value = \'outside_help\'',
        { run.id })[1]
    H.ok(helper ~= nil and tostring(helper.reason):find('Ed Civilian', 1, true) ~= nil,
        'the flag names who helped (' .. tostring(helper and helper.reason) .. ')')
    -- objective events from an executor: a non-participant is ignored, a jump ahead is flagged
    local ev = { type = 'interact', point = 1 }
    Objective(9, run, 2, ev)
    Secs(1)
    H.eq(run.objectiveIndex, 1, 'a non-participant\'s objective event changes nothing')
    Objective(src, run, 2, ev)
    Secs(1)
    H.eq(run.objectiveIndex, 1, 'an event for a later objective is not accepted')
    local unexpected = H.sql(
        'SELECT COUNT(*) AS n FROM cp_audit WHERE action = \'runFlagged\' AND target = ? AND new_value = \'unexpected_event\'',
        { run.id })[1]
    H.eq(tonumber(unexpected.n), 1, 'and flags the run (unexpected_event, audited)')
    Place(9, vec3(0.0, 0.0, 0.0))
    -- a second run at the same time: an admin test run
    local okT = Act('server:admin:startTest', 5, {
        missionId = 'gang_shootout',
        location = (run.locationIndex % 5) + 1,
        tier = 'standard',
        useStartRoute = false,
    })
    H.eq(okT, true, 'a test run is active too')
    local trun = Runs.getBySrc(5)
    Arrive(trun, 5)
    Secs(3)
    local testEnts = Runs.entitiesFor(trun, {})
    H.ok(#testEnts >= 7, 'the test run spawned its wave')
    local rowsBefore = tonumber(H.sql('SELECT COUNT(*) AS n FROM cp_mission_runs')[1].n)
    local auditBefore = tonumber(H.sql('SELECT COUNT(*) AS n FROM cp_audit')[1].n)
    local moneyBefore = #addMoney
    local cdBefore = Runs.cooldowns(CID[src])

    H.fire('onResourceStop', 0, 'Crimson-Police')
    Secs(2)
    local alive = 0
    for _, e in ipairs(spawned) do if ents[e.entity].exists then alive = alive + 1 end end
    for _, e in ipairs(testEnts) do if ents[e.entity].exists then alive = alive + 1 end end
    H.eq(alive, 0, 'every mission entity is deleted on resource stop')
    H.eq(Flag(src), nil, 'the alert flag is removed on resource stop')
    H.eq(Flag(5), nil, 'from the tester too')
    H.eq(Runs.getBySrc(src), nil, 'the run is dropped')
    H.eq(tonumber(H.sql('SELECT COUNT(*) AS n FROM cp_mission_runs')[1].n), rowsBefore, 'no row written')
    H.eq(#addMoney, moneyBefore, 'nothing paid')
    H.eq(tonumber(H.sql('SELECT COUNT(*) AS n FROM cp_audit')[1].n), auditBefore, 'nothing audited either')
    local cdAfter = Runs.cooldowns(CID[src])
    H.eq(cdAfter.types.tactical, cdBefore.types.tactical, 'no type cooldown')
    H.eq(cdAfter.missions.gang_shootout, cdBefore.missions.gang_shootout, 'no mission cooldown')
    Config.DisabledMissions = {}
end

if not os.getenv('E2E_KEEP_DB') then os.execute(('mysql -uroot -e "DROP DATABASE IF EXISTS %s;"'):format(H.db)) end
_G.print = realPrint
return H

-- Database off (Config.Database.enabled = false) from end to end: the saves folder holds every feature's data,
-- survives a restart, and stays fast and small at 50,000 runs.

local H = dofile('tests/harness.lua')
H.useFiles()
H.db = (os.getenv('CP_TEST_DB') or 'cp_test') .. '_storage'
H.resetDatabase()
do
    local f = assert(io.open('tests/fixtures/core/mdt_dispatch.sql', 'r'))
    local sql = f:read('a')
    f:close()
    H.sql(sql)
    H.sql('DELETE FROM mdt_dispatch')
end
-- A fixed Wednesday afternoon (machine time zone): the rows of "30 minutes ago" and the load's current week
-- never straddle the weekly reset, whatever the wall clock says.
local REAL_NOW = os.time({ year = 2026, month = 9, day = 23, hour = 14, min = 0, sec = 0 })
local cjson = require('cjson')
local clock = os.clock
local LOAD_RUNS = tonumber(os.getenv('CP_STORAGE_RUNS')) or 50000

-- ============================================================================
--                                   CONSOLE
-- ============================================================================
-- Module log lines stay out of the output, the spec's own lines and errors stay visible.

local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    if os.getenv('E2E_VERBOSE') then realPrint(line) return end
    if line:find('crimson%-police') or line:find('Crimson%-Police') then return end
    realPrint(line)
end
-- REPORT lines are shown by tests/run.lua even when every assertion passes
local function Say(fmt, ...) realPrint(('REPORT storage: ' .. fmt):format(...)) end

-- ============================================================================
--                                      ═
-- ============================================================================
-- Natives and the outside resources (as in e2e_spec; their state lives outside Crimson-Police, so it survives
-- the restart)

-- ============================================================================
--                                      ═
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
local stopResourceCalls = 0
local kvpCalls = {}   -- FiveM resource KVP: never used, in any mode
local offline = {}
local bags = {}

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
    _G.WasEventCanceled = function() return false end
    _G.GetPlayerRoutingBucket = function() return 0 end
    _G.GetPlayerLastMsg = function() return 0 end
    _G.GetConvar = function(_, default) return default end
    _G.PerformHttpRequest = function() end
    _G.TriggerLatentClientEvent = function(name, target, _, ...) TriggerClientEvent(name, target, ...) end
    _G.AddStateBagChangeHandler = function() end
    _G.StopResource = function() stopResourceCalls = stopResourceCalls + 1 end
    for _, name in ipairs({
        'SetResourceKvp',
        'SetResourceKvpInt',
        'SetResourceKvpFloat',
        'SetResourceKvpNoSync',
        'SetResourceKvpIntNoSync',
        'SetResourceKvpFloatNoSync',
        'GetResourceKvpString',
        'GetResourceKvpInt',
        'GetResourceKvpFloat',
        'DeleteResourceKvp',
        'DeleteResourceKvpNoSync',
        'StartFindKvp',
        'FindKvp',
        'EndFindKvp',
        'FlushResourceKvp',
    }) do
        _G[name] = function() kvpCalls[#kvpCalls + 1] = name end
    end
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
end

local PD = {}
local addMoney = {}
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
H.exportsMock['sc-dispatch'] = {
    IsPlayerSuspended = function() return false end,
    ClearNotification = function() return true end,
}
H.exportsMock['sc-ambulance'] = {
    GetDoctorCount = function() return 0 end,
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

local CID = {}
local function AddPlayers()
    AddPlayer(1, 'STO00001', 'Ada', 'Trooper', 'sast', 1)
    AddPlayer(3, 'STO00003', 'Sam', 'Sarge', 'sast', 3)
    AddPlayer(5, 'STO00005', 'Adam', 'Admin', 'unemployed', 0, { admin = true })
    AddPlayer(6, 'STO00006', 'Cleo', 'Trooper', 'sast', 1)
    AddPlayer(7, 'STO00007', 'Dan', 'Agent', 'fib', 1)
    AddPlayer(8, 'STO00008', 'Eve', 'Trooper', 'sast', 1)
    for src, pd in pairs(PD) do CID[src] = pd.citizenid end
end

-- ============================================================================
--                                 THE RESOURCE
-- ============================================================================
-- H.boot (Config, shared, storage), then every server file (fxmanifest order).

local function BootBase()
    H.boot({ side = 'server' })
    Natives()
end
local function LoadModules()
    local files = {}
    local p = io.popen(
        'cd ' .. H.root .. ' && find modules -name server.lua | sort && find blocks -name server.lua | sort')
    for file in p:lines() do files[#files + 1] = file end
    p:close()
    -- FiveM's CreateThread runs a new thread on the next tick, after every file has loaded
    local realCreate = _G.CreateThread
    local deferred = {}
    _G.CreateThread = function(fn) deferred[#deferred + 1] = fn end
    _G.Citizen.CreateThread = _G.CreateThread
    for _, file in ipairs(files) do H.load(file) end
    _G.CreateThread = realCreate
    _G.Citizen.CreateThread = realCreate
    for _, fn in ipairs(deferred) do realCreate(fn) end
    H.step(0)
    for _ = 1, 3 do H.step(1000) end
    return #files
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
--                           HELPERS (as in e2e_spec)
-- ============================================================================

local function Place(src, c) H.players[src].coords = vec3(c.x + 0.0, c.y + 0.0, c.z + 0.0) end
local reqN = 0
local function Act(name, src, payload)
    reqN = reqN + 1
    local id = 'sto' .. reqN
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
-- A callback right now (no time advance: measured calls record only their own statements).
local function CbNow(name, src, args)
    local res = H.callback('crimson-police:' .. name, src, args)
    if type(res) ~= 'table' or not res.ok then return nil end
    return res.data
end
local function VehicleFor(src, model)
    local c = H.players[src].coords
    local v = NewEnt('vehicle', model or 'police3', c.x, c.y, c.z, 0.0)
    ents[v].driver = src
    H.players[src].vehicle = v
    return v
end
local function BoardRow(b, cid)
    for _, r in ipairs(b and b.rows or {}) do if r.citizenid == cid then return r end end
    return nil
end
local function RunRow(runUuid)
    return (H.sql(
        'SELECT id, run_uuid, citizenid, state, end_reason, season_id, final_points, cash_base, cash_paid, cash_status, '
            .. 'flagged, voided, breakdown FROM cp_mission_runs WHERE run_uuid = ?',
        { runUuid }
    ))[1]
end

-- A solo Beat Patrol from the Mission Board to the end (the real accept, route arrival and checkpoint checks).
-- onEnd(true) is called before the last checkpoint is reported and onEnd(false) once the run has ended.
local function BeatPatrol(src, onEnd)
    Config.DisabledMissions = { 'business_check', 'street_race_bust', 'parking_patrol', 'traffic_enforcement' } -- the Patrol pool is Beat Patrol only
    local chance = Config.Events.modifierChance
    Config.Events.modifierChance = 0
    Place(src, vec3(200.0, -1000.0, 29.0))
    local ok, data = Act('server:acceptType', src, 'patrol')
    H.eq(ok, true, 'acceptType patrol: ' .. tostring(data))
    local run = CP.Runs.getBySrc(src)
    H.eq(run and run.missionId, 'beat_patrol', 'Beat Patrol drawn')
    if not run then Config.Events.modifierChance = chance; return nil end
    local veh = VehicleFor(src)
    for _ = 1, 3 do
        H.fire('crimson-police:server:routeStatus', src, run.id, 5.0, H.players[src].coords)
        Secs(2)
    end
    Place(src, run.location.start.coords)
    Secs(2)
    H.eq(run.state, 'in_progress', 'arrived: In progress')
    H.fire('crimson-police:server:telemetry', src, run.id, 'vehicle', { netId = ents[veh].net })
    local st = run.objectives[1].state
    local n = #(st.points or {})
    H.ok(n > 0, 'checkpoints of the district')
    for k = 1, n do
        Secs(15)
        Place(src, st.points[k])
        ents[veh].coords = H.players[src].coords
        Secs(10)
        if k == n and onEnd then onEnd(true) end
        H.fire('crimson-police:server:objective', src, run.id, 1,
            { type = 'checkpoint', index = k, netId = ents[veh].net })
    end
    Secs(2)
    if onEnd then onEnd(false) end
    H.eq(run.state, 'ended', 'every checkpoint done: the run ended')
    Config.Events.modifierChance = chance
    Config.DisabledMissions = {}
    return run
end

-- Every cp_ table as sorted JSON lines (typed as the modules see it).
local function DumpTables()
    local out = {}
    for _, name in ipairs(CP.Storage.db:tableNames()) do
        local lines = {}
        for _, row in ipairs(H.sql('SELECT * FROM ' .. name)) do
            local keys = {}
            for k in pairs(row) do keys[#keys + 1] = k end
            table.sort(keys)
            local parts = {}
            for i, k in ipairs(keys) do
                local v = row[k]
                parts[i] = cjson.encode(k) .. ':'
                    .. (math.type(v) == 'float' and ('%.17g'):format(v) or cjson.encode(v))
            end
            lines[#lines + 1] = '{' .. table.concat(parts, ',') .. '}'
        end
        table.sort(lines)
        out[name] = { n = #lines, text = table.concat(lines, '\n') }
    end
    return out
end
local function NextIds()
    local out = {}
    for _, t in ipairs(CP.Storage.db.order) do if t.autoCol then out[t.name] = t.nextId end end
    return out
end
local function ReadFile(p)
    local f = io.open(p, 'rb')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end
local function ListDir(d)
    local out = {}
    local p = io.popen(('ls -A \'%s\' 2>/dev/null'):format(d))
    for line in p:lines() do out[#out + 1] = line end
    p:close()
    table.sort(out)
    return out
end

-- ============================================================================
--                          1. FILES MODE, END TO END
-- ============================================================================

BootBase()
AddPlayers()
H.time = REAL_NOW
H.eq(CP.Storage.mode(), 'files', 'Config.Database.enabled = false: files mode')
H.eq(CP.Storage.folder(), H.savesDir(), 'the saves folder is Crimson-Police/saves')
H.eq(CP.Storage.loadError(), nil, 'the saves folder loaded')
local engine1 = CP.Storage.db
local nFiles = LoadModules()
H.ok(nFiles >= 40, 'every server file loaded (' .. nFiles .. ')')
H.eq(stopResourceCalls, 0, 'the real migrations ran on the saves folder without stopping the resource')
H.ok(CP.Migrations.isReady(), 'migrations ready')

local ADMIN, OFFICER = 5, 1
local cid = CID[OFFICER]
local ok, data = Act('server:admin:startSeason', ADMIN, { name = 'Files Season' })
H.eq(ok, true, 'an admin starts a season: ' .. tostring(data))
local season = CP.Challenge.currentSeason(true)
H.eq(season and season.name, 'Files Season', 'the season is current')
local bounty0 = H.sql('SELECT objective, winner FROM cp_dept_bounties WHERE season_id = ? AND week = 1',
    { season and season.id })[1]
H.ok(bounty0 ~= nil and bounty0.objective ~= nil, 'week 1 has a bounty')
local newObjective = (bounty0 and bounty0.objective == 'most_unit') and 'most_tactical' or 'most_unit'
ok, data = Act('server:admin:overrideBounty', ADMIN, { objective = newObjective })
H.eq(ok, true, 'the admin overrides the bounty: ' .. tostring(data))
ok, data = Act('server:admin:setTypePayout', ADMIN, { type = 'patrol', amount = 260, reason = 'files test' })
H.eq(ok, true, 'the admin sets the Patrol payout: ' .. tostring(data))
H.eq(CP.Payouts.typePayout('patrol'), 260, 'Patrol pays $260')
ok, data = Act('server:builder:create', ADMIN, { type = 'patrol', label = 'Files Patrol' })
H.eq(ok, true, 'the admin creates a custom mission: ' .. tostring(data))
local customId = data and data.id
H.ok(type(customId) == 'string' and customId ~= '', 'custom mission id ' .. tostring(customId))

-- two earlier completed runs this week, so this run is the third one the board needs
for _ = 1, 2 do
    H.sql(
        [[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, season_id, state, end_reason,
        points_base, final_points, created_at) VALUES (UUID(), 'patrol', 'business_check', ?, 'sast', ?, 'completed', 'completed',
        60, 50, NOW() - INTERVAL 30 MINUTE)]], { cid, season and season.id })
end
local run = BeatPatrol(OFFICER)
local row = run and RunRow(run.id) or {}
H.eq(row.state, 'completed', 'the row is completed')
H.eq(row.season_id, season and season.id, 'tagged with the season')
H.eq(row.cash_base, 260, 'B = the admin payout')
H.eq(row.cash_status, 'paid', 'cash paid')
H.eq(row.cash_paid, 260, '$260 paid')
H.ok((row.final_points or 0) > 0, 'points scored: ' .. tostring(row.final_points))
H.eq(#addMoney, 1, 'one Qbox AddMoney')
local off = H.sql('SELECT xp, streak_days FROM cp_officers WHERE citizenid = ?', { cid })[1] or {}
H.ok((off.xp or 0) >= (row.final_points or 0) and (off.xp or 0) > 0,
    'XP counts the run (and any goal reached): ' .. tostring(off.xp))
local counted = tonumber(H.sql(
    'SELECT SUM(final_points) AS p FROM cp_mission_runs WHERE citizenid = ? AND voided = 0 AND flagged = 0',
    { cid }
)[1].p)
local board = Cb('getBoard', OFFICER, { period = 'weekly', filter = 'overall' })
local brow = BoardRow(board, cid)
H.ok(brow ~= nil, 'the weekly board ranks the officer')
H.eq(brow and brow.points, counted, 'board points = every counted row of the week')
H.eq(brow and brow.runs, 3, 'three completed runs')
H.ok((CP.Runs.cooldowns(cid).missions.beat_patrol or 0) > os.time(), 'the Beat Patrol cooldown started')

-- the saves folder: one compact document per table, written through, nothing left over
local dir = CP.Storage.folder()
local names = ListDir(dir)
local has = {}
for _, n in ipairs(names) do has[n] = true end
for _, n in ipairs({
    '_tables.json',
    'officers.json',
    'mission_runs.json',
    'seasons.json',
    'dept_bounties.json',
    'custom_missions.json',
    'audit.json',
    'type_payouts.json',
}) do
    H.ok(has[n], 'saves/' .. n .. ' written')
end
for _, n in ipairs(names) do
    H.ok(not n:match('%.tmp$') and not n:match('%.bak$'), 'no leftover ' .. n)
    if n:match('%.json$') then H.ok(pcall(cjson.decode, ReadFile(dir .. '/' .. n)), n .. ' is valid JSON') end
end
local runsDoc = ReadFile(dir .. '/mission_runs.json') or ''
H.ok(runsDoc:find(run and run.id or '?', 1, true) ~= nil, 'the run is a line of saves/mission_runs.json')
H.eq(#kvpCalls, 0, 'no resource KVP call')

-- what the modules show before the restart
local auditBefore = Cb('admin:getAudit', ADMIN, {})
local officerBefore = Cb('admin:getOfficer', ADMIN, { citizenid = cid })
local seasonsBefore = Cb('admin:getSeasons', ADMIN)
local builderBefore = Cb('builder:list', ADMIN)
local function CustomEntry(list)
    for _, m in ipairs(list and list.missions or {}) do if m.id == customId then return m end end
    return nil
end
H.ok(CustomEntry(builderBefore) ~= nil, 'the custom mission is listed')
H.ok(auditBefore and auditBefore.total >= 4, 'audit rows: ' .. tostring(auditBefore and auditBefore.total))

-- ============================================================================
--                             2. A SERVER RESTART
-- ============================================================================

local tablesBefore = DumpTables()
local idsBefore = NextIds()
local moneyBefore = #addMoney
H.restart()
BootBase()
H.ok(CP.Storage.db ~= engine1, 'a new engine')
H.eq(CP.Storage.mode(), 'files', 'files mode again')
H.eq(CP.Storage.loadError(), nil, 'the saves folder loaded again')
local tablesAfter = DumpTables()
local tablesCompared = 0
for name, t in pairs(tablesBefore) do
    local a = tablesAfter[name]
    tablesCompared = tablesCompared + 1
    H.eq(a and a.n, t.n, name .. ': same number of rows after the restart')
    H.ok(a and a.text == t.text, name .. ': identical rows after the restart')
end
H.eq(tablesCompared, 26, 'every table compared')
local idsAfter = NextIds()
for name, n in pairs(idsBefore) do H.eq(idsAfter[name], n, name .. ': AUTO_INCREMENT continues where it was') end

LoadModules()
H.eq(stopResourceCalls, 0, 'the migrations found everything applied')
local seasonAfter = CP.Challenge.currentSeason(true)
H.eq(seasonAfter and seasonAfter.id, season and season.id, 'the season is still current')
H.eq(seasonAfter and seasonAfter.name, 'Files Season', 'with its name')
local bounty1 =
    H.sql('SELECT objective FROM cp_dept_bounties WHERE season_id = ? AND week = 1', { season and season.id })[1]
H.eq(bounty1 and bounty1.objective, newObjective, 'the overridden bounty')
local seasonsAfter = Cb('admin:getSeasons', ADMIN)
H.eq(cjson.encode(seasonsAfter and seasonsAfter.seasons or {}),
    cjson.encode(seasonsBefore and seasonsBefore.seasons or {}), 'the Seasons screen lists the same seasons')
H.eq(CP.Payouts.typePayout('patrol'), 260, 'the admin payout survived')
local builderAfter = Cb('builder:list', ADMIN)
local ce = CustomEntry(builderAfter)
H.ok(ce ~= nil, 'the custom mission is still listed')
H.eq(ce and ce.label, CustomEntry(builderBefore).label, 'with its label')
H.eq(ce and ce.status, CustomEntry(builderBefore).status, 'and status')
local auditAfter = Cb('admin:getAudit', ADMIN, {})
H.eq(auditAfter and auditAfter.total, auditBefore and auditBefore.total, 'every audit row is there')
H.eq(cjson.encode(auditAfter and auditAfter.rows or {}), cjson.encode(auditBefore and auditBefore.rows or {}),
    'the audit log reads the same')
local officerAfter = Cb('admin:getOfficer', ADMIN, { citizenid = cid })
H.eq(officerAfter and officerAfter.xp, officerBefore and officerBefore.xp, 'officer XP')
H.eq(cjson.encode(officerAfter and officerAfter.stats or {}), cjson.encode(officerBefore and officerBefore.stats or {}),
    'officer run stats')
H.eq(officerAfter and officerAfter.cash and officerAfter.cash.total, 260, 'cash total')
H.eq(#(officerAfter and officerAfter.runs or {}), #(officerBefore and officerBefore.runs or {}),
    'the same runs on the profile')
H.eq(cjson.encode(officerAfter and officerAfter.runs or {}), cjson.encode(officerBefore and officerBefore.runs or {}),
    'with the same content')
local boardAfter = Cb('getBoard', OFFICER, { period = 'weekly', filter = 'overall' })
local browAfter = BoardRow(boardAfter, cid)
H.eq(browAfter and browAfter.points, brow and brow.points, 'the weekly board: same points')
H.eq(browAfter and browAfter.rank, brow and brow.rank, 'same rank')
local seasonBoard = Cb('getBoard', OFFICER, { period = 'season', filter = 'overall' })
H.eq(BoardRow(seasonBoard, cid) and BoardRow(seasonBoard, cid).points, brow and brow.points,
    'the season board counts the season rows')
local rowAfter = RunRow(run and run.id or '')
H.eq(rowAfter and rowAfter.cash_status, 'paid', 'the run is still paid')
H.eq(CP.Cash.pay(rowAfter and rowAfter.id), 'paid', 'a pay() after the restart only reports paid')
CP.Cash.payPending(OFFICER)
H.eq(#addMoney, moneyBefore, 'and pays nothing twice')
H.ok((CP.Runs.cooldowns(cid).missions.beat_patrol or 0) > os.time(),
    'the Beat Patrol cooldown is rebuilt from the saves folder')
Config.DisabledMissions = { 'business_check', 'street_race_bust', 'parking_patrol', 'traffic_enforcement' } -- Beat Patrol is the whole Patrol pool
local refused, why = Act('server:acceptType', OFFICER, 'patrol')
Config.DisabledMissions = {}
H.eq(refused, false, 'the officer cannot take Patrol again during the cooldown (' .. tostring(why) .. ')')
H.eq(CP.Runs.getBySrc(OFFICER), nil, 'no run started')

-- the next run after the restart is saved too, with the next id
local run2 = BeatPatrol(6)
local row2 = run2 and RunRow(run2.id) or {}
H.ok((row2.id or 0) >= idsBefore.cp_mission_runs,
    ('the next run gets a new id (%s, the counter was %d before the restart)'):format(tostring(row2.id),
        idsBefore.cp_mission_runs))
H.eq(row2.cash_status, 'paid', 'and is paid')
H.eq(row2.cash_paid, 260, 'at the saved payout')
H.eq(#addMoney, moneyBefore + 1, 'one more AddMoney')

-- ============================================================================
--                                3. 50,000 RUNS
-- ============================================================================

local db = CP.Storage.db
local M = CP.Storage.MemSQL
local OFFICERS, DEPTS = {}, { 'sast', 'fib' }
for i = 1, 500 do OFFICERS[i] = ('LD%06d'):format(i) end
local TYPES = {
    { 'patrol', 'beat_patrol', 60, 260 },
    { 'patrol', 'business_check', 60, 260 },
    { 'tactical', 'gang_shootout', 200, 1000 },
    { 'investigation', 'warrant_service', 150, 800 },
    { 'pursuit', 'street_race_bust', 100, 500 },
}
local BD = '{"cash":{"B":%d,"status":"%s","amount":%d,"mTier":1,"mMod":1},"runId":"%s","endReason":"%s","missionLabel":"Beat Patrol",'
    .. '"departments":%d,"result":"%s","missionType":"%s","durationS":%d,"participants":%d,"test":false,"points":{"tod":false,'
    .. '"subtotal":%d,"penalties":[],"bonuses":[{"label":"Finished within 75%% of the time limit","id":"fast_finish","points":12},'
    .. '{"label":"No damage to your vehicle","id":"no_vehicle_damage","points":10}],"mCross":1,"mStreak":1.05,"P":%d,"capped":false,'
    .. '"mTeam":1,"final":%d},"payTier":"standard","tier":"standard","xpCounted":1}'
local INS = [[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, location_label, citizenid, department, season_id,
    participants, departments_n, tier, state, end_reason, points_base, bonus_points, penalty_points, final_points, cash_base,
    cash_multiplier, cash_paid, cash_status, duration_s, breakdown, flagged, voided, created_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, FROM_UNIXTIME(?))]]
-- a fifth of the runs fall in the current week (a busy weekly board), the rest over the 120 days before it
local SPAN = 120 * 86400
local WEEK_FROM = CP.Schedule.weekStart(REAL_NOW)
local NOW_LOAD = os.time()
local function RunTime(i)
    local recent = LOAD_RUNS // 5
    if i <= recent then return WEEK_FROM + ((i - 1) * (NOW_LOAD - 120 - WEEK_FROM)) // recent end
    return WEEK_FROM - SPAN + ((i - recent) * SPAN) // (LOAD_RUNS - recent + 1)
end
local rng = CP.U.rng(20260929)
local function Hex(n) local t = {} for i = 1, n do t[i] = ('%x'):format(rng:int(0, 15)) end return table.concat(t) end
local rawBytes = 0
local c0 = clock()
db:bulk(function()
    for i = 1, LOAD_RUNS do
        local ty = TYPES[i % #TYPES + 1]
        local ocid = OFFICERS[(i * 7919) % #OFFICERS + 1]
        local u = ('%s-%s-4%s-8%s-%s'):format(Hex(8), Hex(4), Hex(3), Hex(3), Hex(12))
        local roll = rng:int(1, 100)
        local state = roll <= 90 and 'completed' or (roll <= 98 and 'failed' or 'abandoned')
        local participants = rng:int(1, 100) <= 30 and 2 or 1
        local deptN = participants == 2 and rng:int(1, 100) <= 40 and 2 or 1
        local dur = 100 + (i % 500)
        local pts = state == 'completed' and ty[3] + (i % 40) or 0
        local cash = state == 'completed' and ty[4] or 0
        local status = state == 'completed' and 'paid' or 'none'
        local bd = BD:format(ty[4], status, cash, u, state, deptN, state, ty[1], dur, participants, pts, ty[3], pts)
        local flagged = rng:int(1, 1000) <= 5 and 1 or 0
        local params = {
            u,
            ty[1],
            ty[2],
            'Sandy Shores',
            ocid,
            DEPTS[((i * 7919) % #OFFICERS + 1) % 2 + 1],
            season.id,
            participants,
            deptN,
            'standard',
            state,
            state,
            ty[3],
            state == 'completed' and 22 or 0,
            0,
            pts,
            ty[4],
            1.0,
            cash,
            status,
            dur,
            bd,
            flagged,
            0,
            RunTime(i),
        }
        db:exec(INS, params)
        for _, v in ipairs(params) do rawBytes = rawBytes + #tostring(v) end
    end
    for i, ocid in ipairs(OFFICERS) do
        db:exec([[INSERT INTO cp_officers (citizenid, callsign, rank_label, display_name, department, xp, streak_days)
            VALUES (?, ?, 'Trooper', ?, ?, ?, ?)]],
            { ocid, tostring(100 + i), 'Officer ' .. i, DEPTS[i % 2 + 1], i * 10, i % 7 })
    end
end)
local tFill = clock() - c0
local nRuns = #db.tables.cp_mission_runs.rows
H.ok(nRuns >= LOAD_RUNS, ('%d runs in cp_mission_runs'):format(nRuns))
Say('filled %d runs and %d officers in %.2f s (one save of every document at the end)', LOAD_RUNS, #OFFICERS, tFill)

-- every statement's CPU time through the MySQL drop-in
local recording = nil
for _, kind in ipairs({ 'query', 'single', 'scalar', 'insert', 'update' }) do
    local f = MySQL[kind].await
    MySQL[kind].await = function(sql, params)
        local t0 = clock()
        local res = table.pack(pcall(f, sql, params))
        local dt = clock() - t0
        if recording then recording[#recording + 1] = { kind = kind, sql = sql, dt = dt } end
        if not res[1] then error(res[2], 0) end
        return table.unpack(res, 2, res.n)
    end
end
local function OneLine(sql) return (sql:gsub('%s+', ' '):sub(1, 70)) end
local function Measure(label, fn)
    collectgarbage()
    recording = {}
    local t0 = clock()
    local okM, res = pcall(fn)
    local total = clock() - t0
    local rec = recording
    recording = nil
    H.ok(okM, label .. ' ran: ' .. tostring(okM or res))
    local slowest, slowSql, sum = 0, '', 0
    for _, r in ipairs(rec) do
        sum = sum + r.dt
        if r.dt > slowest then slowest, slowSql = r.dt, r.sql end
    end
    Say('%-44s %2d statements, slowest %6.1f ms, all SQL %6.1f ms, whole call %6.1f ms  (%s)', label, #rec,
        slowest * 1000, sum * 1000, total * 1000, OneLine(slowSql))
    H.ok(#rec > 0, label .. ' queried the saves folder engine')
    H.ok(slowest < 0.25,
        ('%s: every query under 250 ms (slowest %.1f ms: %s)'):format(label, slowest * 1000, OneLine(slowSql)))
    return res
end

local LB, C = CP.Leaderboard, CP.Challenge
local ranked = Measure('leaderboard: weekly board', function()
    return LB.ranking({ period = 'weekly', fresh = true })
end)
H.ok(#ranked > 100, 'the weekly board ranks many officers (' .. #ranked .. ')')
Measure('leaderboard: monthly board', function() return LB.ranking({ period = 'monthly', fresh = true }) end)
local seasonRanked = Measure('leaderboard: season board (all runs)', function()
    return LB.ranking({ period = 'season', fresh = true })
end)
H.ok(#seasonRanked >= 500, 'the season board ranks every officer (' .. #seasonRanked .. ')')
Measure('leaderboard: all-time board', function() return LB.ranking({ period = 'alltime', fresh = true }) end)
Measure('leaderboard: department board (season)', function()
    return LB.ranking({ period = 'season', filter = 'department', department = 'fib', fresh = true })
end)
Measure('leaderboard: tactical board (weekly)', function()
    return LB.ranking({ period = 'weekly', filter = 'tactical', fresh = true })
end)
local collected = Measure('challenge: season aggregates', function() return C._collect(season.id, true) end)
H.ok(collected and collected.officers and collected.officers.sast ~= nil, 'challenge data per department')
Measure('challenge: standings', function() C._collect(season.id, true); return C.standings(season.id) end)
Measure('challenge: tablet view', function() C.invalidate(); return C.view(CP.Access.getOfficer(OFFICER)) end)
-- on a server these run in a thread, and a long SELECT gives the server its turn every 4 ms (DB:exec slicing; the
-- harness turns it off for the other specs): how long each call holds the server thread at most
do
    local turns, longest, t0 = 0, 0, 0
    db.slice = {
        ms = 4,
        wait = function()
            local dt = clock() - t0
            if dt > longest then longest = dt end
            turns = turns + 1
            coroutine.yield()
            t0 = clock()
        end,
    }
    for _, job in ipairs({
        {
            'season board',
            function() return LB.ranking({ period = 'season', fresh = true }) end,
        },
        {
            'challenge season aggregates',
            function() return C._collect(season.id, true) end,
        },
        {
            'challenge tablet view',
            function() C.invalidate(); return C.view(CP.Access.getOfficer(OFFICER)) end,
        },
    }) do
        turns, longest = 0, 0
        local co = coroutine.create(job[2])
        t0 = clock()
        local ok, res = coroutine.resume(co)
        while ok and coroutine.status(co) == 'suspended' do ok, res = coroutine.resume(co) end
        local dt = clock() - t0
        if dt > longest then longest = dt end
        H.ok(ok and res ~= nil, job[1] .. ' in a thread: ' .. tostring(ok and 'ok' or res))
        Say('%-44s in a server thread: gave the server %d turns, held it at most %.1f ms at a time', job[1], turns,
            longest * 1000)
        H.ok(turns > 5 and longest < 0.050,
            ('%s: held the server thread at most %.1f ms at a time (%d turns)'):format(job[1], longest * 1000, turns))
    end
    db.slice = nil
end
Adv(1100)
local stats = Measure('admin stats: officer profile', function()
    return CbNow('admin:getOfficer', ADMIN, { citizenid = OFFICERS[17] })
end)
H.ok(stats and stats.stats and stats.stats.runs >= 90,
    'the officer profile counts the runs (' .. tostring(stats and stats.stats and stats.stats.runs) .. ')')
Adv(1100)
Measure('admin stats: departments', function() return CbNow('admin:getDepartments', ADMIN) end)
Adv(1100)
Measure('admin stats: seasons screen', function() C.invalidate(); return CbNow('admin:getSeasons', ADMIN) end)
Adv(1100)
Measure('admin stats: audit log', function() return CbNow('admin:getAudit', ADMIN, {}) end)

-- one finished run on the full folder: its write statements and the documents they rewrite
local store = db.store
local writes, statsAt = nil, nil
local written = {}   -- the documents this run's saves wrote (for the fsync measurement below)
local realWrite = M.fs.write
M.fs.write = function(path, data)
    if recording then written[#written + 1] = { path = (path:gsub('%.tmp$', '')), bytes = #data } end
    return realWrite(path, data)
end
local run3 = BeatPatrol(8, function(starting)
    if starting then
        recording = {}
        statsAt = { writes = store.stats.writes, bytes = store.stats.bytes }
    else
        writes = recording
        recording = nil
    end
end)
local row3 = run3 and RunRow(run3.id) or {}
H.eq(row3.state, 'completed', 'the run on the full folder completed')
H.eq(row3.cash_status, 'paid', 'and was paid')
local wN, wT, rN, rT, slowW, slowSql = 0, 0, 0, 0, 0, ''
for _, r in ipairs(writes or {}) do
    local verb = r.sql:match('^%s*(%a+)'):upper()
    if verb == 'INSERT' or verb == 'UPDATE' or verb == 'DELETE' then
        wN, wT = wN + 1, wT + r.dt
        if r.dt > slowW then slowW, slowSql = r.dt, r.sql end
    else
        rN, rT = rN + 1, rT + r.dt
    end
end
for _, r in ipairs(writes or {}) do
    local verb = r.sql:match('^%s*(%a+)'):upper()
    if verb == 'INSERT' or verb == 'UPDATE' or verb == 'DELETE' then
        Say('  write %5.2f ms  %s', r.dt * 1000, OneLine(r.sql))
    end
end
local docWrites = store.stats.writes - (statsAt and statsAt.writes or 0)
local docBytes = store.stats.bytes - (statsAt and statsAt.bytes or 0)
Say(
    'one finished run: %d write statements %.1f ms (slowest %.1f ms: %s), %d documents rewritten (%d bytes); %d reads %.1f ms',
    wN, wT * 1000, slowW * 1000, OneLine(slowSql), docWrites, docBytes, rN, rT * 1000)
H.ok(wN >= 3, 'the finished run wrote its row, cash and officer (' .. wN .. ' statements)')
H.ok(wT < 0.020, ('saving one finished run takes about 20 ms or less (%.1f ms)'):format(wT * 1000))
M.fs.write = realWrite
-- FXServer's file:flush() is an fsync (LocalDevice::Flush), plain Lua's only empties its buffer: the same
-- documents written again with an fsync each, on this machine's disk, by a helper (the wall time of each write)
do
    local list = {}
    for _, w in ipairs(written) do list[#list + 1] = w.path end
    local listFile = os.tmpname()
    local f = io.open(listFile, 'w')
    f:write(table.concat(list, '\n'))
    f:close()
    local py = [[
import os, sys, time
paths = [p for p in open(sys.argv[1]).read().split('\n') if p]
total = 0.0
for p in paths:
    data = open(p, 'rb').read() if os.path.exists(p) else b'x' * 60000
    tmp = sys.argv[1] + '.w'
    t0 = time.perf_counter()
    with open(tmp, 'wb') as fh:
        fh.write(data); fh.flush(); os.fsync(fh.fileno())
    total += time.perf_counter() - t0
    os.remove(tmp)
print('%d %.3f' % (len(paths), total * 1000))
]]
    local pyFile = listFile .. '.py'
    f = io.open(pyFile, 'w')
    f:write(py)
    f:close()
    local p = io.popen(('python3 \'%s\' \'%s\' 2>/dev/null'):format(pyFile, listFile))
    local out = p and p:read('a') or ''
    if p then p:close() end
    os.remove(listFile)
    os.remove(pyFile)
    local n, ms = out:match('^(%d+) ([%d%.]+)')
    if n then
        Say(
            'one finished run with an fsync per document (as FXServer flushes): %d documents written, fsync writes %.1f ms on this disk, so about %.1f ms in all; at 5 ms per fsync (a slow VPS disk) about %.0f ms',
            tonumber(n), tonumber(ms), wT * 1000 + tonumber(ms), wT * 1000 + 5 * tonumber(n))
    else
        Say('one finished run with an fsync per document: python3 is not available, not measured')
    end
    H.ok(#written <= 8, ('one finished run writes %d documents'):format(#written))
end

-- start-up: a new engine loads the whole saves folder
collectgarbage()
collectgarbage()
local memBefore = collectgarbage('count')
local l0 = clock()
local db2 = M.new({ store = M.folderStore(dir) }):load()
local tLoad = clock() - l0
collectgarbage()
local memAfter = collectgarbage('count')
Say('start-up load: %.2f s for %d runs (%.0f MB of Lua memory for the loaded engine)', tLoad,
    #db2.tables.cp_mission_runs.rows, (memAfter - memBefore) / 1024)
H.eq(#db2.tables.cp_mission_runs.rows, #db.tables.cp_mission_runs.rows, 'every run loaded')
H.eq(#db2.tables.cp_officers.rows, #db.tables.cp_officers.rows, 'every officer loaded')
H.ok(tLoad < 3, ('start-up load under 3 s (%.2f s)'):format(tLoad))
db2 = nil

-- size on disk
local total, runsBytes, runsDocs, docs = 0, 0, 0, 0
for _, n in ipairs(ListDir(dir)) do
    local s = #(ReadFile(dir .. '/' .. n) or '')
    total = total + s
    docs = docs + 1
    if n:match('^mission_runs[_%d]*%.json$') then runsBytes, runsDocs = runsBytes + s, runsDocs + 1 end
end
local perRow = runsBytes / nRuns
Say(
    'saves folder: %d files, %.1f MB; mission_runs: %d documents, %.1f MB, %.0f bytes per run row (%.2fx the raw values)',
    docs, total / 1e6, runsDocs, runsBytes / 1e6, perRow, runsBytes / rawBytes)
H.ok(runsDocs >= nRuns // 500, 'mission_runs is split into documents of 500 rows')
H.ok(perRow < 1.5 * rawBytes / LOAD_RUNS, 'a run row takes less than 1.5x its raw values on disk')

return H

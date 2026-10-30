-- Live crimes, step V10: the Crimson-Contracts adapter and the intake (CP.LiveCrime). Crimson-Contracts' five
-- server-only events (as built in its step VC3) are fired with TriggerEvent and GetInvokingResource() answering the
-- sender, against the real qbx, access, opponents and anticheat modules (qbx_core's exports and events mocked).

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end

local function Copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = Copy(x) end
    return setmetatable(out, getmetatable(v))
end

-- ============================================================================
--                   qbx_core, NATIVES, THE SENDING RESOURCE
-- ============================================================================

local players = {}   -- [src] = a loaded character's Player
local byCidCalls = 0
H.exportsMock.qbx_core = {
    GetPlayer = function(src) return Copy(players[tonumber(src)]) end,
    GetPlayerByCitizenId = function(cid)
        byCidCalls = byCidCalls + 1
        for _, p in pairs(players) do
            if p.PlayerData.citizenid == cid then return Copy(p) end
        end
        return nil
    end,
    GetQBPlayers = function() return Copy(players) end,
    GetJobs = function() return {} end,
}

-- FXServer: GetInvokingResource() in a handler of a server TriggerEvent is the sender's resource name
local invoker, invokerCalls = 'crimson-contracts', 0
_G.GetInvokingResource = function()
    invokerCalls = invokerCalls + 1
    return invoker
end

local camReads = 0
local bucket = {}
_G.GetPlayerRoutingBucket = function(src) return bucket[tonumber(src)] or 0 end
_G.GetPlayerCameraRotation = function()
    camReads = camReads + 1
    return vec3(0.0, 0.0, 0.0)
end

local threads = 0
local realThread = _G.CreateThread
_G.CreateThread = function(fn)
    threads = threads + 1
    return realThread(fn)
end
_G.Citizen.CreateThread = _G.CreateThread

-- the event names the adapter registers as net events (it must register none of Crimson-Contracts')
local netNames = {}
local realNet = _G.RegisterNetEvent
_G.RegisterNetEvent = function(name, fn)
    netNames[name] = true
    return realNet(name, fn)
end

local function Load(src, cid, coords, opts)
    opts = opts or {}
    H.players[src] = H.players[src] or {}
    H.players[src].coords = coords or vec3(0.0, 0.0, 0.0)
    H.players[src].ace = opts.ace or {}
    players[src] = {
        PlayerData = {
            source = src,
            citizenid = cid,
            license = 'license:' .. cid:lower(),
            charinfo = { firstname = 'First' .. src, lastname = 'Last' },
            job = {
                name = opts.job or 'unemployed',
                label = opts.job or 'Civilian',
                onduty = opts.onduty == true,
                grade = { level = 1 },
            },
            metadata = { ishandcuffed = opts.cuffed == true, isdead = false, inlaststand = false, injail = 0 },
        },
    }
    TriggerEvent('QBCore:Server:PlayerLoaded', Copy(players[src]))
end
local function Move(src, coords) H.players[src].coords = coords end
local function Tick(seconds) H.advance((seconds or 1) * 1000, 1000) end

-- ============================================================================
--                                   MODULES
-- ============================================================================

local function Quiet(path)
    local thread = _G.CreateThread
    _G.CreateThread = function() end
    local ok, err = pcall(H.load, path)
    _G.CreateThread = thread
    if not ok then error(err, 2) end
end

local audits, warns = {}, {}
CP.Admin = {
    audit = function(...) audits[#audits + 1] = { ... } end,
}
CP.Tablet = {
    notify = function() return true end,
    notifyMany = function(srcs) return #srcs end,
}
local liveRuns = {}
CP.Runs = {
    dispatch = function() return true end,
    get = function(id) return liveRuns[id] end,
}
CP.Alerts = {
    foreignFlag = function() return false end,
}
CP.AntiCheat = H.realAntiCheat()
CP.Payouts = {
    baseFor = function() return 500 end,
    sourceFor = function() return 'type' end,
}
Quiet('modules/cash/server.lua')
CP.Qbx = {
    onDutyChange = function() end,
    onGroupUpdate = function() end,
    onJobChange = function() end,
    onPlayerLoaded = function() end,
    onPlayerUnload = function() end,
    getOnlinePlayers = function() return {} end,
}
H.load('modules/access/server.lua')
CP.Qbx = nil
H.load('modules/integrations/qbx/server.lua')
H.load('modules/opponents/server.lua')
H.load('modules/integrations/crimson_contracts/server.lua')
H.load('modules/livecrime/server.lua')
H.step(0)
local LC, Opp, LIVE, RS = CP.LiveCrime, CP.Opponents, Config.LiveCrime, Config.RealSuspects
local realWarn = CP.warn
CP.warn = function(tag, fmt, ...)
    warns[#warns + 1] = { tag = tag, text = fmt:format(...) }
    return realWarn(tag, fmt, ...)
end
local posted = {}
LC.post = function(crime) posted[#posted + 1] = crime end

local EVENT = 'crimson-contracts:server:'
local function Fire(name, payload) TriggerEvent(EVENT .. name, payload) end

-- Crimson-Contracts' payloads (crimson-contracts/server.lua e20316f)
local seq = 0
local WAREHOUSE = { x = 830.61, y = -1961.95, z = 28.06 }
local function Contract(members, extra)
    seq = seq + 1
    local p = {
        id = seq,
        uid = ('%d_%d'):format(seq, os.time()),
        key = 'warehouse_burglary',
        label = 'Warehouse Burglary',
        locationLabel = 'La Mesa warehouse',
        coords = Copy(WAREHOUSE),
        members = members,
        leaderCitizenId = next(members),
        startedAt = os.time(),
        test = false,
    }
    for k, v in pairs(extra or {}) do p[k] = v end
    return p
end
local function Alert(c)
    return {
        id = c.id,
        uid = c.uid,
        dispatchId = ('crimson_contract_%d_%d'):format(c.id, os.time()),
        title = '10-90 - Warehouse Alarm',
        street = c.locationLabel,
        coords = Copy(c.coords),
    }
end
local function KeyOf(c) return 'crimson-contracts:' .. c.uid end
local function Audited(action, c)
    local out = {}
    for _, a in ipairs(audits) do
        if a[4] == action and (c == nil or a[5] == KeyOf(c)) then out[#out + 1] = a end
    end
    return out
end
local function Warned(needle)
    local n = 0
    for _, w in ipairs(warns) do if w.text:find(needle, 1, true) then n = n + 1 end end
    return n
end
local function Near(dx) return vec3(WAREHOUSE.x + dx, WAREHOUSE.y, WAREHOUSE.z) end

-- ============================================================================
--                            (a) THE SHIPPED CONFIG
-- ============================================================================

do
    H.eq(LIVE.enabled, false, 'live crimes ship off')
    H.eq(#LIVE.sources, 1, 'one source')
    H.eq(LIVE.sources[1], 'crimson-contracts', 'Crimson-Contracts\' folder name')
    H.eq(LIVE.suspectRadius, 300.0, 'suspectRadius ships 300 m (C24)')
    local want = {
        warehouse_burglary = 'investigation',
        container_heist = 'investigation',
        hostile_drug_pickup = 'tactical',
        drug_lab_raid = 'tactical',
        weapon_shipment = 'tactical',
        prisoner_ambush = 'tactical',
        atm_robbery = false,
    }
    for key, v in pairs(want) do H.eq(LIVE.types[key], v, 'types.' .. key) end
    for name in pairs(CP.CrimsonContracts.EVENTS) do
        H.eq(#(H.handlers[EVENT .. name] or {}), 1, name .. ': one handler, registered at start')
        H.eq(netNames[EVENT .. name], nil, name .. ': never a net event')
    end
end

-- ============================================================================
--                                   (b) OFF
-- ============================================================================
-- NOTHING HAPPENS; (c) ON IN SETTINGS: NO RESTART (C29).

Load(11, 'CREWA011', Near(10.0))
Load(12, 'CREWB012', Near(-20.0))

do
    threads, camReads, invokerCalls = 0, 0, 0
    local c = Contract({ CREWA011 = 11, CREWB012 = 12 })
    Fire('contractStarted', c)
    Fire('dispatchSent', Alert(c))
    Fire('crewShot', { id = c.id, uid = c.uid, citizenid = 'CREWA011', suppressed = false, trigger = 'shot' })
    Fire('contractEnded', { id = c.id, uid = c.uid, outcome = 'completed' })
    Tick(30)
    H.eq(LC.get(KeyOf(c)), nil, '(b) off: no record')
    H.eq(#audits + #posted + #warns, 0, '(b) off: no audit, no post, no warning')
    H.eq(invokerCalls, 0, '(b) off: the handlers return before reading anything')
    H.eq(threads + camReads, 0, '(b) off: no thread and no AFK sample')
    H.eq(LC.inCrew('CREWA011'), false, '(b) off: nobody is in a crew')

    -- the owner turns it on in Admin UI → Settings: the same handlers work at once
    LIVE.enabled = true
    c = Contract({ CREWA011 = 11, CREWB012 = 12 })
    Fire('contractStarted', c)
    local crime = LC.get(KeyOf(c))
    H.ok(crime ~= nil, '(c) on: the record is kept')
    H.ok(crime.members.CREWA011 and crime.members.CREWB012, '(c) the crew by citizenid')
    H.eq(crime.test, false, '(c) a real contract')
    H.eq(crime.id, c.id, '(c) Crimson-Contracts\' contract number')
    H.eq(crime.key, 'warehouse_burglary', '(c) its key')
    H.eq(crime.leader, c.leaderCitizenId, '(c) its leader')
    H.eq(threads, 1, '(c) the crew\'s AFK samples start the watch')
    H.ok(LC.inCrew('CREWA011'), '(c) inCrew while the crime is on')
    H.eq(LC.inCrew('NOBODY01'), false, '(c) inCrew: not a member')
    Tick(1)
    H.eq(camReads, 2, '(c) one AFK sample per crew member from the contract start (C17)')
    Fire('dispatchSent', Alert(c))
    H.eq(#posted, 1, '(c) the alert: one LIVE call to post')
    H.eq(posted[1], crime, '(c) for this crime')
    H.ok(crime.suspects.CREWA011 and crime.suspects.CREWB012, '(c) both are suspects')
    H.eq(crime.missionType, 'investigation', '(c) Warehouse Burglary uses Investigation')
    H.eq(crime.dispatchId, ('crimson_contract_%d_%d'):format(c.id, os.time()), '(c) the sc-dispatch call id')
    H.eq(crime.title, '10-90 - Warehouse Alarm', '(c) the call title')
    H.eq(crime.street, 'La Mesa warehouse', '(c) the street')
    H.eq(crime.alertedAt, os.time(), '(c) alertedAt')
    local rep = Audited('liveCrimeReported', c)
    H.eq(#rep, 1, '(c) audited liveCrimeReported')
    H.eq(rep[1][3], 'audit', '(c) category audit (Admin UI → Audit)')
    H.eq(rep[1][7], '2/2', '(c) 2 of 2 crew members are suspects')
    H.ok(not rep[1][8]:find('CREW', 1, true), '(c) the audit line names no citizenid')
    Fire('dispatchSent', Alert(c))
    H.eq(#posted, 1, '(c) a second alert of the same crime posts nothing')

    -- the end: the samples stop, inCrew is false, the record is pruned an hour later
    Fire('contractEnded', { id = c.id, uid = c.uid, outcome = 'failed', reason = 'The crew abandoned the contract.' })
    H.eq(crime.ended, true, '(c) ended')
    H.eq(crime.outcome, 'failed', '(c) the outcome')
    H.eq(crime.endReason, 'The crew abandoned the contract.', '(c) the reason')
    H.eq(LC.inCrew('CREWA011'), false, '(c) inCrew: false once it ended')
    Tick(2)
    camReads = 0
    Tick(60)
    H.eq(camReads, 0, '(c) no more samples after the end')
    H.ok(LC.get(KeyOf(c)) ~= nil, '(c) the record stays for an hour')
    H.time = H.time + 3601
    Fire('contractStarted', Contract({ OTHER001 = 1 }, { key = 'atm_robbery' }))
    H.eq(LC.get(KeyOf(c)), nil, '(c) pruned 1 h after the end')
    LIVE.enabled = false
    local before = #audits
    Fire('contractStarted', Contract({ CREWA011 = 11 }))
    H.eq(#audits, before, '(c) off again: nothing more')
    LIVE.enabled = true
end

-- ============================================================================
--                       (d) ONLY THE SCRIPTS IN SOURCES
-- ============================================================================

do
    local c = Contract({ CREWA011 = 11 })
    invoker = 'my-heists'
    Fire('contractStarted', c)
    Fire('dispatchSent', Alert(c))
    H.eq(LC.get('my-heists:' .. c.uid), nil, '(d) a script not in sources is dropped')
    H.eq(Warned('not in Config.LiveCrime.sources'), 1, '(d) one warning naming the setting, not one per event')
    invoker = nil
    Fire('contractStarted', c)
    H.eq(LC.get('crimson-contracts:' .. c.uid), nil, '(d) no invoking resource: dropped')
    H.eq(Warned('an unknown script'), 1, '(d) and warned')
    invoker = 'my-heists'
    H.time = H.time + 61
    Fire('contractStarted', c)
    H.eq(Warned('my-heists ignored'), 2, '(d) a minute later: one more warning')
    -- sources is read on each event (a Settings change needs no restart)
    LIVE.sources = { 'crimson-contracts', 'my-heists' }
    Fire('contractStarted', c)
    H.ok(LC.get('my-heists:' .. c.uid) ~= nil, '(d) added to sources: heard, keyed by its own name')
    Fire('contractEnded', { id = c.id, uid = c.uid, outcome = 'completed' })
    H.eq(LC.get('my-heists:' .. c.uid).ended, true, '(d) and its end too')
    LIVE.sources = { 'crimson-contracts' }
    invoker = 'crimson-contracts'
end

-- ============================================================================
--                            (e) MALFORMED PAYLOADS
-- ============================================================================

do
    local function Bad(extra, what)
        local c = Contract({ CREWA011 = 11 }, extra)
        Fire('contractStarted', c)
        H.eq(LC.get(KeyOf(c)), nil, '(e) dropped: ' .. what)
    end
    local before = #warns
    TriggerEvent(EVENT .. 'contractStarted', 'not a table')
    TriggerEvent(EVENT .. 'contractStarted', nil)
    Bad({ id = 'seven' }, 'id is not a number')
    Bad({ id = 1.5 }, 'id is not a whole number')
    Bad({ uid = ('9'):rep(33) }, 'uid longer than 32')
    Bad({ uid = 'a b;c' }, 'uid with other characters')
    Bad({ key = ('k'):rep(65) }, 'key longer than 64')
    Bad({ label = 42 }, 'label is not text')
    Bad({ coords = { x = 1.0, y = 'two', z = 3.0 } }, 'coords with text')
    Bad({ coords = { x = 0 / 0, y = 1.0, z = 1.0 } }, 'coords with NaN')
    Bad({ coords = 'here' }, 'coords is not a table')
    Bad({ test = 'yes' }, 'test is not a boolean')
    local many = {}
    for i = 1, 17 do many[('MANY%04d'):format(i)] = i end
    Bad({ members = many }, '17 members')
    Bad({ members = { [('C'):rep(51)] = 1 } }, 'a citizenid longer than 50')
    Bad({ members = { [7] = 1 } }, 'a citizenid that is not text')
    Bad({ members = {} }, 'no member')
    H.eq(Warned('its data is not what Crimson-Contracts sends'), 1, '(e) one warning a minute per script and event')
    H.ok(#warns - before == 1, '(e) and nothing else warned')
    -- long text is cut, not dropped (sc-dispatch keeps titles to 50 characters)
    local c = Contract({ TEXT0001 = 1 }, { label = '  Warehouse\nBurglary  ' })
    Fire('contractStarted', c)
    local crime = LC.get(KeyOf(c))
    H.eq(crime and crime.label, 'Warehouse Burglary', '(e) text is trimmed and freed of control characters')
    local a = Alert(c)
    a.title = ('T'):rep(120)
    a.dispatchId = 'bad id!'
    Fire('dispatchSent', a)
    H.eq(crime.alertedAt, nil, '(e) a bad dispatchId drops the alert')
    a.dispatchId = nil
    a.coords = nil
    Fire('dispatchSent', a)
    H.eq(crime.title, ('T'):rep(50), '(e) a long title is cut to 50')
    Fire('crewShot', { id = c.id, uid = c.uid, citizenid = 'TEXT0001', suppressed = 'no', trigger = 'shot' })
    H.eq(crime.armed.TEXT0001, nil, '(e) crewShot with a bad suppressed flag is dropped')
    Fire('contractEnded', { id = c.id, uid = c.uid, outcome = { 'completed' } })
    H.eq(crime.ended, false, '(e) contractEnded with a bad outcome is dropped')
    Fire('contractEnded', { id = c.id, uid = c.uid, outcome = 'completed' })
end

-- ============================================================================
--                  (f) SERVER IDS IN THE PAYLOAD ARE IGNORED
-- ============================================================================
-- (C9); (g) TEST CRIMES (C16).

do
    -- the payload's server ids are wrong (one of them is another player's); CREWC013 is offline
    Load(99, 'STRANGER', Near(5.0))
    byCidCalls = 0
    local c = Contract({ CREWA011 = 99, CREWB012 = 98, CREWC013 = 11 })
    Fire('contractStarted', c)
    Fire('dispatchSent', Alert(c))
    local crime = LC.get(KeyOf(c))
    H.ok(crime.suspects.CREWA011 and crime.suspects.CREWB012, '(f) members are found by citizenid')
    H.eq(crime.suspects.STRANGER, nil, '(f) the player at a payload server id is never a suspect')
    H.eq(crime.suspects.CREWC013, nil, '(f) an offline member is not a suspect')
    H.ok(byCidCalls >= 3, '(f) one citizenid lookup per member')
    local rep = Audited('liveCrimeReported', c)[1]
    H.eq(rep and rep[7], '2/3', '(f) 2 of 3')
    H.ok(rep and rep[8]:find('offline 1', 1, true), '(f) the audit says why: offline 1')
    Fire('contractEnded', { id = c.id, uid = c.uid, outcome = 'completed' })

    -- an admin's /testcriminalcontract
    camReads = 0
    local n = #posted
    c = Contract({ CREWA011 = 11 }, { test = true })
    Fire('contractStarted', c)
    Tick(20)
    H.eq(#Audited('liveCrimeIgnored', c), 1, '(g) a test contract is audited liveCrimeIgnored')
    H.eq(Audited('liveCrimeIgnored', c)[1][7], 'test', '(g) as a test')
    H.eq(camReads, 0, '(g) and never sampled')
    Fire('dispatchSent', Alert(c))
    H.eq(#posted, n, '(g) its alert posts nothing')
    H.eq(LC.inCrew('CREWA011'), false, '(g) a test crew is not "in a crime"')
end

-- ============================================================================
--           (h) THE SUSPECT RADIUS (C24); (i) WHO CAN'T BE A SUSPECT
-- ============================================================================

do
    Load(21, 'FAR00021', Near(350.0))
    Load(22, 'NEAR0022', Near(290.0))
    local c = Contract({ FAR00021 = 21, NEAR0022 = 22 })
    Fire('contractStarted', c)
    Fire('dispatchSent', Alert(c))
    local crime = LC.get(KeyOf(c))
    H.eq(crime.suspects.FAR00021, nil, '(h) a member 350 m away is not a suspect')
    H.eq(crime.suspects.NEAR0022, true, '(h) one 290 m away is')
    H.ok(Audited('liveCrimeReported', c)[1][8]:find('too far from the crime 1', 1, true), '(h) the audit says why')
    Fire('contractEnded', { id = c.id, uid = c.uid, outcome = 'completed' })

    Load(31, 'SAST0031', Near(5.0), { job = 'sast', onduty = true })
    Load(32, 'CUFF0032', Near(5.0), { cuffed = true })
    Load(33, 'INST0033', Near(5.0))
    bucket[33] = 4210
    Load(34, 'ACE00034', Near(5.0), { ace = { [RS.excludeAce] = true } })
    local n = #posted
    c = Contract({ SAST0031 = 31, CUFF0032 = 32, INST0033 = 33, ACE00034 = 34 })
    Fire('contractStarted', c)
    Fire('dispatchSent', Alert(c))
    crime = LC.get(KeyOf(c))
    H.eq(crime.suspects, nil, '(i) on-duty SAST, cuffed, bucket 4210 and the exclude ace: no suspect')
    H.eq(#posted, n, '(i) all excluded: nothing posted')
    local ign = Audited('liveCrimeIgnored', c)
    H.eq(ign[1] and ign[1][7], 'no_suspect', '(i) audited liveCrimeIgnored: no suspect')
    for _, part in ipairs({ 'on police duty 1', 'cuffed 1', 'in an instance 1', 'excluded by the server.cfg ace 1' }) do
        H.ok(ign[1] and ign[1][8]:find(part, 1, true), '(i) the audit says ' .. part)
    end
    camReads = 0
    Tick(30)
    H.eq(camReads, 0, '(i) the crew\'s samples stopped')
    bucket[33] = nil

    -- Pillbox (Config.RealSuspects.noStartZones) next to a crime there
    Load(41, 'PILL0041', vec3(310.0, -590.0, 43.0))
    Load(42, 'OUTS0042', vec3(500.0, -600.0, 43.0))
    c = Contract({ PILL0041 = 41, OUTS0042 = 42 }, { coords = { x = 400.0, y = -600.0, z = 43.0 } })
    Fire('contractStarted', c)
    Fire('dispatchSent', Alert(c))
    crime = LC.get(KeyOf(c))
    H.eq(crime.suspects.PILL0041, nil, '(i) a member at Pillbox is not a suspect')
    H.eq(crime.suspects.OUTS0042, true, '(i) the one outside the zone is')
    Fire('contractEnded', { id = c.id, uid = c.uid, outcome = 'completed' })

    -- AFK since the contract started (C17): B stands still with the same camera, A walks
    Load(51, 'WALK0051', Near(1.0))
    Load(52, 'IDLE0052', Near(2.0))
    c = Contract({ WALK0051 = 51, IDLE0052 = 52 })
    Fire('contractStarted', c)
    for i = 1, math.ceil((RS.afkSeconds + RS.afkSampleEvery) / 10) + 1 do
        Move(51, Near(1.0 + (i % 2) * 5.0))
        Tick(10)
    end
    Fire('dispatchSent', Alert(c))
    crime = LC.get(KeyOf(c))
    H.eq(crime.suspects.IDLE0052, nil, '(i) a member AFK since contractStarted is not a suspect')
    H.eq(crime.suspects.WALK0051, true, '(i) the one who moved is')
    H.ok(Audited('liveCrimeReported', c)[1][8]:find('AFK 1', 1, true), '(i) the audit says AFK')
    Fire('contractEnded', { id = c.id, uid = c.uid, outcome = 'completed' })
end

-- ============================================================================
--                     (j) A CRIME TYPE THAT IS OFF (types)
-- ============================================================================

do
    local n = #posted
    LIVE.types.warehouse_burglary = false
    threads, camReads = 0, 0
    local c = Contract({ CREWA011 = 11 })
    Fire('contractStarted', c)
    Tick(5)
    H.eq(camReads, 0, '(j) a crime that is off is not sampled')
    Fire('dispatchSent', Alert(c))
    H.eq(#posted, n, '(j) types false: nothing posted')
    H.eq(Audited('liveCrimeIgnored', c)[1][7], 'type_off', '(j) audited liveCrimeIgnored: type off')
    H.ok(LC.inCrew('CREWA011'), '(j) still a crew doing a crime (inCrew)')
    Fire('contractEnded', { id = c.id, uid = c.uid, outcome = 'completed' })
    -- a value that is not a mission type is off too, with a warning
    LIVE.types.warehouse_burglary = 'heist'
    c = Contract({ CREWA011 = 11 })
    Fire('contractStarted', c)
    Fire('dispatchSent', Alert(c))
    H.eq(#posted, n, '(j) an unknown mission type: nothing posted')
    H.ok(Warned('is not in Config.MissionTypes') >= 1, '(j) and a warning')
    Fire('contractEnded', { id = c.id, uid = c.uid, outcome = 'completed' })
    LIVE.types.warehouse_burglary = 'investigation'
    c = Contract({ CREWA011 = 11 }, { key = 'drug_lab_raid' })
    Fire('contractStarted', c)
    Fire('dispatchSent', Alert(c))
    H.eq(LC.get(KeyOf(c)).missionType, 'tactical', '(j) Drug Lab Raid uses Tactical')
    Fire('contractEnded', { id = c.id, uid = c.uid, outcome = 'completed' })
end

-- ============================================================================
--            (k) crewShot MARKS ARMED (C6); A RUNNING CASE; THE END
-- ============================================================================

do
    Load(61, 'GUNA0061', Near(3.0))
    Load(62, 'GUNB0062', Near(6.0))
    local c = Contract({ GUNA0061 = 61, GUNB0062 = 62 })
    Fire('contractStarted', c)
    local crime = LC.get(KeyOf(c))
    Fire('crewShot', { id = c.id, uid = c.uid, citizenid = 'GUNA0061', suppressed = true, trigger = 'shot' })
    H.eq(crime.armed.GUNA0061, os.time(), '(k) before any case: kept on the crime')
    Fire('crewShot', { id = c.id, uid = c.uid, citizenid = 'STRANGER', suppressed = false, trigger = 'gun_kill' })
    H.eq(crime.armed.STRANGER, nil, '(k) a citizenid that is not in the crew is ignored')
    Fire('dispatchSent', Alert(c))

    -- the case a claim opens (V14 sets crime.runId and run.live.crimeKey)
    Load(1, 'OFF00001', Near(500.0), { job = 'sast', onduty = true })
    local run = {
        id = 'run-live-0001',
        missionId = 'live_crime',
        seed = 7,
        state = 'in_progress',
        order = { 1 },
        participants = { [1] = { src = 1, citizenid = 'OFF00001', status = 'active', score = {} } },
        live = { crimeKey = crime.crimeKey },
        score = { shared = {} },
    }
    liveRuns[run.id] = run
    crime.runId = run.id
    local case = Opp.open(run, { kind = 'live', members = crime.suspects })
    H.ok(case ~= nil, '(k) the case opens')
    H.eq(LC.crimeOf(run), crime, '(k) crimeOf(run)')
    H.eq(case.suspects.GUNB0062.everArmed, false, '(k) B not armed yet')
    Fire('crewShot', { id = c.id, uid = c.uid, citizenid = 'GUNB0062', suppressed = false, trigger = 'gun_kill' })
    H.eq(case.suspects.GUNB0062.everArmed, true, '(k) a suspect of the running case is marked armed')

    Fire('memberRejoined', { id = c.id, uid = c.uid, citizenid = 'GUNA0061', src = 999 })
    local line = nil
    for _, e in ipairs(case.timeline) do if e.what == 'crew_rejoined' then line = e end end
    H.ok(line ~= nil and line.label == case.suspects.GUNA0061.label, '(k) memberRejoined: a timeline line')
    H.eq(case.suspects.GUNA0061.src, 61, '(k) its server id is never taken from the payload')

    Fire('contractEnded', { id = c.id, uid = c.uid, outcome = 'completed' })
    H.ok(case.crimeEndedAt ~= nil, '(k) the end reaches the running case (its lost rule runs without contact)')
    Opp.close(run)

    -- a reporting script that stops ends its open crimes
    c = Contract({ GUNA0061 = 61 })
    Fire('contractStarted', c)
    H.fire('onResourceStop', nil, 'crimson-contracts')
    H.eq(LC.get(KeyOf(c)).outcome, 'stopped', '(k) Crimson-Contracts stopped: its crime ended')
    H.eq(LC.inCrew('GUNA0061'), false, '(k) and nobody is in its crew any more')
end

-- ============================================================================
--              (l) NOTHING IS LEFT RUNNING; NOTHING HOLDS POINTS
-- ============================================================================

do
    Tick(2)
    camReads = 0
    local before = threads
    Tick(30)
    H.eq(camReads, 0, '(l) every crime ended: no sample')
    H.eq(threads, before, '(l) and no thread')
    for _, a in ipairs(audits) do
        H.ok(a[4] == 'liveCrimeReported' or a[4] == 'liveCrimeIgnored' or a[4] == 'runNoted',
            '(l) only intake audits (' .. tostring(a[4]) .. ')')
    end
end

return H

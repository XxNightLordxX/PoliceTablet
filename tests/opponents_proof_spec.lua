-- CP.Opponents proof (step V5): the sc-police cuff pair and custody hold, getting free during the hold (release,

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
--                        qbx_core, NATIVES AND COUNTERS
-- ============================================================================

local players = {}   -- [src] = a loaded character's Player ({ PlayerData = ... })
H.exportsMock.qbx_core = {
    GetPlayer = function(src) return Copy(players[tonumber(src)]) end,
    GetPlayerByCitizenId = function(cid)
        for _, p in pairs(players) do
            if p.PlayerData.citizenid == cid then return Copy(p) end
        end
        return nil
    end,
    GetQBPlayers = function() return Copy(players) end,
    GetJobs = function() return {} end,
}

local bucket = {}
local pedReads = {}  -- [src] = GetPlayerPed calls
local realPed = _G.GetPlayerPed
_G.GetPlayerPed = function(src)
    local n = tonumber(src)
    if n then pedReads[n] = (pedReads[n] or 0) + 1 end
    return realPed(src)
end
_G.GetPlayerRoutingBucket = function(src) return bucket[tonumber(src)] or 0 end
_G.GetPlayerCameraRotation = function() return vec3(0.0, 0.0, 0.0) end

local function Character(src, cid, coords, job, onduty)
    H.players[src] = H.players[src] or {}
    H.players[src].coords = coords or vec3(0.0, 0.0, 30.0)
    H.players[src].ace = H.players[src].ace or {}
    return {
        PlayerData = {
            source = src,
            citizenid = cid,
            license = 'license:' .. cid:lower(),
            charinfo = { firstname = 'First' .. src, lastname = 'Last' },
            job = {
                name = job or 'unemployed',
                label = job or 'Civilian',
                onduty = onduty == true,
                grade = { level = 1 },
            },
            metadata = { ishandcuffed = false, isdead = false, inlaststand = false, injail = 0 },
        },
    }
end
local function Load(src, cid, coords, job, onduty)
    players[src] = Character(src, cid, coords, job, onduty)
    TriggerEvent('QBCore:Server:PlayerLoaded', Copy(players[src]))
end
local function Move(src, coords) H.players[src].coords = coords end

-- qbx_core's SetMetaData: the value is written, then onSetMetaData(key, old, new, src) fires at once (a TriggerEvent).
local function SetMeta(src, key, value)
    local md = players[src].PlayerData.metadata
    local old = md[key]
    md[key] = value
    TriggerEvent('qbx_core:server:onSetMetaData', key, old, value, src)
end

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

local audits, flags, sent, hints = {}, {}, {}, {}
local runsBySrc = {}
CP.Admin = {
    audit = function(...) audits[#audits + 1] = { ... } end,
}
CP.Tablet = {
    notify = function() return true end,
    notifyMany = function(srcs) return #srcs end,
}
-- CP.Runs' participant API as modules/runs has it (active participants only)
CP.Runs = {
    dispatch = function(run, index, src, ev)
        sent[#sent + 1] = { run = run, index = index, src = src, ev = ev }
        return true
    end,
    isParticipant = function(run, src)
        local p = type(run) == 'table' and run.participants and run.participants[tonumber(src)]
        return p ~= nil and p.status == 'active'
    end,
    getBySrc = function(src)
        local run = runsBySrc[tonumber(src)]
        local p = run and run.participants[tonumber(src)]
        if not p or p.status ~= 'active' or run.state == 'ended' then return nil end
        return run, p
    end,
}
CP.Alerts = {
    foreignFlag = function() return false end,
    inArena = function(src) return (bucket[tonumber(src)] or 0) ~= 0 end,
}
CP.LiveCrime = {
    cuffHint = function(run, src) hints[#hints + 1] = { run = run, src = src } end,
}
CP.AntiCheat = H.realAntiCheat()
do
    local realFlag = CP.AntiCheat.flag
    CP.AntiCheat.flag = function(...)
        flags[#flags + 1] = { ... }
        return realFlag(...)
    end
end
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

-- sc-police's own JailPlayer handler, registered before Crimson-Police's (sc-police starts first): it writes injail
-- inside the handler, so CP sees the injail change before its own jail handler runs (critic 2 #5)
local scpWritesInjail = false
RegisterNetEvent('police:server:JailPlayer', function(targetId, jailTime)
    if scpWritesInjail then SetMeta(tonumber(targetId), 'injail', jailTime) end
end)
H.load('modules/integrations/sc_police/server.lua')
H.load('modules/integrations/sc_ambulance/server.lua')
H.load('modules/opponents/server.lua')
H.load('modules/opponents/proof/server.lua')
H.step(0)
local Opp = CP.Opponents
local RS = Config.RealSuspects

-- the online list the rescue pass reads, counted (CP.Qbx.getOnlinePlayers: the event-kept list)
local onlineReads = 0
do
    local real = CP.Qbx.getOnlinePlayers
    CP.Qbx.getOnlinePlayers = function()
        onlineReads = onlineReads + 1
        return real()
    end
end

-- ============================================================================
--                                    SCENES
-- ============================================================================

local MR = vec3(470.63, -974.11, 30.18)   -- Mission Row PD, a booking zone
local FAR = vec3(-1500.0, 3000.0, 30.0)   -- outside every booking zone

-- officers 1 and 2 (SAST, on duty) are the case's participants; 3 is on duty but not in the case; 4 is a
-- participant off duty; 20 is the suspect's friend, 21 a bystander
Load(1, 'OFF00001', vec3(0.0, 0.0, 30.0), 'sast', true)
Load(2, 'OFF00002', vec3(2.0, 0.0, 30.0), 'sast', true)
Load(3, 'OFF00003', vec3(0.0, 2.0, 30.0), 'sast', true)
Load(4, 'OFF00004', vec3(0.0, -2.0, 30.0), 'sast', false)
Load(20, 'FRND0020', vec3(300.0, 300.0, 30.0))
Load(21, 'BYST0021', vec3(-300.0, 300.0, 30.0))

local runSeq, runs = 0, {}
local function NewRun(officers, live)
    runSeq = runSeq + 1
    local run = {
        id = ('run-%04d'):format(runSeq),
        missionId = 'live_crime',
        seed = 77 + runSeq,
        state = 'in_progress',
        order = {},
        participants = {},
        live = live and { key = 'crime-' .. runSeq } or nil,
    }
    for _, src in ipairs(officers) do
        run.order[#run.order + 1] = src
        run.participants[src] = { src = src, citizenid = ('OFF%05d'):format(src), status = 'active', score = {} }
        runsBySrc[src] = run
    end
    runs[#runs + 1] = run
    return run
end

local nextSrc = 40
-- A fresh case with one suspect at `at`; officers 1 and 2 (and 4 when asked) next to him.
local function Scene(cid, opts)
    opts = opts or {}
    nextSrc = nextSrc + 1
    local src = nextSrc
    local at = opts.at or vec3(0.0, 0.0, 30.0)
    H.resetNetLimits()
    local officers = opts.officers or { 1, 2 }
    local run = NewRun(officers, opts.live)
    Load(src, cid, vec3(at.x + 1.0, at.y + 1.0, at.z))
    Move(1, at)
    Move(2, vec3(at.x + 2.0, at.y, at.z))
    Move(3, vec3(at.x, at.y + 2.0, at.z))
    Move(4, vec3(at.x, at.y - 2.0, at.z))
    Move(20, vec3(at.x + 300.0, at.y + 300.0, at.z))
    local case = Opp.open(run, { kind = 'live', members = { cid } })
    H.step(0)
    return run, case, case.suspects[cid], src
end

local function Tick(seconds) H.advance((seconds or 1) * 1000, 1000) end
local function Fire(event, src, ...) H.fire(event, src, ...) end
local function Cuff(officer, target) Fire('police:server:CuffPlayer', officer, target, false) end

local function Sent(run, kind)
    local out = {}
    for _, s in ipairs(sent) do
        if s.run == run and s.ev.type == kind then out[#out + 1] = s end
    end
    return out
end
local function NotesOf(case, reason)
    local out = {}
    for _, n in ipairs(case.notes) do if n.what == reason then out[#out + 1] = n end end
    return out
end
local function Lines(case, what)
    local out = {}
    for _, e in ipairs(case.timeline) do if e.what == what then out[#out + 1] = e end end
    return out
end
local function Noted(run, reason)
    for _, a in ipairs(audits) do
        if a[4] == 'runNoted' and a[5] == run.id and a[7] == reason then return true end
    end
    return false
end

-- cuffed through the pair, then the cuffs hold for custodyHoldSeconds: detained
local function CuffAndHold(src, officer)
    Cuff(officer or 1, src)
    SetMeta(src, 'ishandcuffed', true)
    Tick(RS.custodyHoldSeconds + 1)
end

-- ============================================================================
--                         SHIPPED VALUES (config.lua)
-- ============================================================================

do
    for key, value in pairs({
        cuffPairWindow = 10,
        cuffRange = 3.5,
        custodyHoldSeconds = 30,
        breakFreeSeconds = 20,
        rescueRange = 4.0,
        neutralisedShare = 0.5,
        jailRange = 6.0,
        minJailTime = 5,
        jailTimeMax = 120,
        spawnProtectSeconds = 600,
        earlyRespawnSeconds = 400,
    }) do
        H.eq(RS[key], value, 'Config.RealSuspects.' .. key .. ' ships ' .. tostring(value))
    end
    H.eq(#RS.bookingZones, 4, 'four booking zones')
    H.eq(RS.bookingZones[1].label, 'Mission Row PD', 'the first is Mission Row PD')
    H.eq(RS.bookingZones[4].radius, 180.0, 'Bolingbroke has a 180 m zone')
end

-- ============================================================================
--                    (a) THE CUFF PAIR AND THE CUSTODY HOLD
-- ============================================================================

do
    local run, case, rec, src = Scene('PAIR0001')
    Cuff(1, src)
    H.eq(rec.cuff and rec.cuff.officerSrc, 1, '(a) a participant\'s cuff attempt is kept')
    H.eq(#Sent(run, 'opp_cuff_attempt'), 1, '(a) opp_cuff_attempt dispatched')
    H.eq(Sent(run, 'opp_cuff_attempt')[1].src, nil, '(a) a server event (no src)')
    H.eq(rec.state, 'free', '(a) still free until the cuffed state comes')
    Tick(3)
    SetMeta(src, 'ishandcuffed', true)
    H.eq(rec.state, 'cuffed', '(a) the cuff and the cuffed state within 10 s: cuffed')
    H.eq(rec.share, 1, '(a) share 1')
    H.eq(rec.caughtBy and rec.caughtBy[1], 1, '(a) caught by the officer who cuffed')
    H.ok(rec.cuffedAt ~= nil, '(a) cuffedAt')
    -- sc-police registers SetHandcuffStatus twice: a second true is no change
    SetMeta(src, 'ishandcuffed', true)
    H.eq(#Sent(run, 'opp_cuffed'), 1, '(a) metadata true twice (old == new): one transition')
    Tick(RS.custodyHoldSeconds - 2)
    H.eq(rec.state, 'cuffed', '(a) not detained before custodyHoldSeconds')
    Tick(2)
    H.eq(rec.state, 'detained', '(a) the cuffs held 30 s: detained')
    H.ok(rec.detainedAt ~= nil, '(a) detainedAt')
    H.eq(#Sent(run, 'opp_detained'), 1, '(a) opp_detained dispatched')
    H.eq(Sent(run, 'opp_detained')[1].ev.share, 1, '(a) with the share')
    H.eq(Sent(run, 'opp_detained')[1].ev.by, 1, '(a) and the officer')
    -- a later cuff changes nothing
    SetMeta(src, 'ishandcuffed', false)
    Tick(3)
    Cuff(2, src)
    SetMeta(src, 'ishandcuffed', true)
    Tick(RS.custodyHoldSeconds + 2)
    H.eq(rec.state, 'detained', '(a) a later cuff changes nothing')
    H.eq(#Sent(run, 'opp_detained'), 1, '(a) detained once per suspect per case')
    H.eq(#Sent(run, 'opp_cuffed'), 1, '(a) and no second cuffed')
    H.eq(#NotesOf(case, 'rs_self_uncuff'), 0, '(a) an uncuff after the detain is no self-uncuff')
    Opp.close(run)
end

-- ============================================================================
--                 (a2) THE LISTENERS NEVER YIELD (section 5.1)
-- ============================================================================
-- FXServer runs every event handler in its own thread (H.fire: a coroutine each). With oxmysql every await yields,
-- and getOfficer's suspension and retired lookups read the database on a cache miss: a listener that yielded there
-- would keep the cuff attempt only after sc-police's GetCuffed round trip may already have brought the suspect's
-- SetHandcuffStatus(true), and a real arrest would read as cuffed_unproven.

do
    local A = CP.Access
    local realOfficer, realSuspended, realRetired = A.getOfficer, A.isSuspended, A.isRetired
    local yields = 0
    local function Yielding(fn)
        return function(...)
            yields = yields + 1
            Wait(50)
            return fn(...)
        end
    end
    A.getOfficer, A.isSuspended, A.isRetired = Yielding(realOfficer), Yielding(realSuspended), Yielding(realRetired)

    local run, case, rec, src = Scene('YLDC0001', { at = MR })
    Cuff(1, src)
    SetMeta(src, 'ishandcuffed', true)  -- arrives before any waiting thread runs again
    H.eq(rec.state, 'cuffed', '(a2) SetHandcuffStatus(true) right after the cuff: cuffed')
    H.eq(#Lines(case, 'cuffed_unproven'), 0, '(a2) not cuffed_unproven')
    Tick(RS.custodyHoldSeconds + 1)
    H.eq(rec.state, 'detained', '(a2) detained by the hold')
    scpWritesInjail = true
    Fire('police:server:JailPlayer', 1, src, 30)
    scpWritesInjail = false
    H.eq(rec.state, 'booked', '(a2) the jail listener books at once (no yield before rec.jail)')
    Opp.close(run)

    run, case, rec, src = Scene('YLDE0001')
    SetMeta(src, 'isdead', true)
    Fire('police:server:EscortPlayer', 1, src)
    H.eq(rec.state, 'detained', '(a2) the escort listener detains at once')
    Opp.close(run)

    H.eq(yields, 0, '(a2) no listener called getOfficer, isSuspended or isRetired')
    H.step(100)
    A.getOfficer, A.isSuspended, A.isRetired = realOfficer, realSuspended, realRetired
end

-- ============================================================================
--                    (b) CUFFS THAT DO NOT PAIR: NOT CUFFED
-- ============================================================================

do
    local function NotCuffed(label, prepare, officer, line)
        local run, case, rec, src = Scene(('NOPR%04d'):format(nextSrc + 1))
        prepare(src)
        Cuff(officer or 1, src)
        SetMeta(src, 'ishandcuffed', true)
        H.eq(rec.state, 'free', '(b) ' .. label .. ': not cuffed')
        H.eq(#Sent(run, 'opp_cuffed'), 0, '(b) ' .. label .. ': no opp_cuffed')
        if line then H.eq(#Lines(case, line), 1, '(b) ' .. label .. ': the timeline says ' .. line) end
        Tick(RS.custodyHoldSeconds + 2)
        H.eq(rec.state, 'free', '(b) ' .. label .. ': never detained')
        Opp.close(run)
        return run, case
    end
    local run, case = NotCuffed('a cuff by an on-duty officer outside the case', function() end, 3,
        'cuffed_by_outsider')
    H.eq(#Sent(run, 'opp_cuff_attempt'), 0, '(b) no cuff attempt event for an outsider')
    H.eq(case.suspects[case.order[1]].outsideCuffed, true, '(b) the outside cuff is kept for V15')
    -- 4 is a participant who is off duty
    run = NewRun({ 1, 4 })
    do
        nextSrc = nextSrc + 1
        local src = nextSrc
        Load(src, 'NOPR0OFF', vec3(1.0, 1.0, 30.0))
        Move(1, vec3(0.0, 0.0, 30.0))
        Move(4, vec3(0.0, -1.0, 30.0))
        case = Opp.open(run, { kind = 'live', members = { 'NOPR0OFF' } })
        Cuff(4, src)
        SetMeta(src, 'ishandcuffed', true)
        H.eq(case.suspects.NOPR0OFF.state, 'free', '(b) a cuff by an off-duty participant: not cuffed')
        H.eq(#Lines(case, 'cuff_refused'), 1, '(b) the refusal is on the timeline')
        Opp.close(run)
    end
    NotCuffed('a cuff from 5 m', function(src)
        Move(1, vec3(5.0, 1.0, 30.0))
        Move(src, vec3(0.0, 1.0, 30.0))
    end, 1, 'cuffed_unproven')
    NotCuffed('the officer in bucket 4210', function() bucket[1] = 4210 end, 1, 'cuffed_unproven')
    bucket[1] = nil
    -- the cuffed state comes after cuffPairWindow
    do
        local run2, case2, rec, src = Scene('NOPR0GAP')
        Cuff(1, src)
        Tick(RS.cuffPairWindow + 1)
        SetMeta(src, 'ishandcuffed', true)
        H.eq(rec.state, 'free', '(b) the cuffed state 11 s after the cuff: not cuffed')
        H.eq(#Lines(case2, 'cuffed_unproven'), 1, '(b) cuffed_unproven')
        Opp.close(run2)
    end
    -- metadata true with no attempt (a criminal cuffed him)
    do
        local run3, case3, rec, src = Scene('NOPR0NOA')
        SetMeta(src, 'ishandcuffed', true)
        H.eq(rec.state, 'free', '(b) metadata true with no attempt: not cuffed')
        H.eq(#Lines(case3, 'cuffed_unproven'), 1, '(b) the timeline says cuffed_unproven')
        Opp.close(run3)
    end
    -- the suspect in an instance: his cuffed state is ignored (Crimson-Arena rewrites it; the core handles the leave)
    do
        local run4, case4, rec, src = Scene('NOPR0INS')
        Cuff(1, src)
        bucket[src] = 4210
        SetMeta(src, 'ishandcuffed', true)
        H.eq(#Sent(run4, 'opp_cuffed'), 0, '(b) the cuffed state in bucket 4210 is ignored')
        bucket[src] = nil
        Opp.close(run4)
    end
end

-- ============================================================================
--               (c) GETTING FREE DURING THE HOLD, IN THIS ORDER
-- ============================================================================

local function Cuffed(cid, opts)
    local run, case, rec, src = Scene(cid, opts)
    Cuff(1, src)
    SetMeta(src, 'ishandcuffed', true)
    H.eq(rec.state, 'cuffed', cid .. ': cuffed')
    return run, case, rec, src
end

do
    -- a participant's uncuff: released
    local run, case, rec, src = Cuffed('FREE0001')
    Tick(5)
    Fire('police:server:UncuffPlayer', 2, src)
    SetMeta(src, 'ishandcuffed', false)
    H.eq(rec.state, 'free', '(c) participant uncuff -> free')
    H.eq(Sent(run, 'opp_released')[1] and Sent(run, 'opp_released')[1].ev.why, 'released', '(c) why released')
    Tick(RS.custodyHoldSeconds)
    H.eq(rec.state, 'free', '(c) and he stays free')
    H.eq(#case.notes, 0, '(c) no note')
    Opp.close(run)

    -- an uncuff by someone outside the case is no release: detained at once, and the note names him instead of
    -- saying that no officer uncuffed the suspect
    run, case, rec, src = Cuffed('FREE0002')
    Tick(5)
    Fire('police:server:UncuffPlayer', 3, src)
    H.eq(#Lines(case, 'uncuffed_by_outsider'), 1, '(c) the outsider\'s uncuff is on the timeline')
    H.eq(Lines(case, 'uncuffed_by_outsider')[1] and Lines(case, 'uncuffed_by_outsider')[1].by, 3, '(c) with who')
    SetMeta(src, 'ishandcuffed', false)
    Tick(3)
    H.eq(rec.state, 'detained', '(c) an outsider\'s uncuff -> detained')
    H.eq(Sent(run, 'opp_detained')[1] and Sent(run, 'opp_detained')[1].ev.why, 'outside_uncuff',
        '(c) why outside_uncuff')
    H.eq(#NotesOf(case, 'rs_self_uncuff'), 0, '(c) no self-uncuff note')
    H.eq(#NotesOf(case, 'rs_outside_uncuff'), 1, '(c) the rs_outside_uncuff note')
    local detail = NotesOf(case, 'rs_outside_uncuff')[1] and NotesOf(case, 'rs_outside_uncuff')[1].detail or ''
    H.ok(detail:find('First3 Last (server id 3)', 1, true) ~= nil, '(c) it names the outsider: ' .. detail)
    H.ok(detail:find('no officer uncuff', 1, true) == nil, '(c) and never says no officer uncuffed him')
    H.ok(Noted(run, 'rs_outside_uncuff'), '(c) audited as a note')
    Opp.close(run)

    -- an outsider's uncuff more than 5 s before the cuffs come off explains nothing: a self-uncuff
    run, case, rec, src = Cuffed('FREE0003')
    Fire('police:server:UncuffPlayer', 3, src)
    Tick(6)
    SetMeta(src, 'ishandcuffed', false)
    Tick(3)
    H.eq(rec.state, 'detained', '(c) an outsider\'s uncuff 6 s earlier -> self-uncuff -> detained')
    H.eq(#NotesOf(case, 'rs_self_uncuff'), 1, '(c) the rs_self_uncuff note')
    H.eq(#NotesOf(case, 'rs_outside_uncuff'), 0, '(c) no rs_outside_uncuff note')
    Opp.close(run)

    -- an outsider's uncuff from 6 m is refused (sc-police allows 2.5 m): the timeline says so, a self-uncuff
    run, case, rec, src = Cuffed('FREE0004')
    Move(3, vec3(7.0, 1.0, 30.0))
    Fire('police:server:UncuffPlayer', 3, src)
    H.eq(Lines(case, 'uncuff_refused')[1] and Lines(case, 'uncuff_refused')[1].why, 'distance',
        '(c) an outsider\'s uncuff from 6 m: uncuff_refused (distance)')
    SetMeta(src, 'ishandcuffed', false)
    Tick(3)
    H.eq(#NotesOf(case, 'rs_self_uncuff'), 1, '(c) then the cuffs coming off is a self-uncuff')
    Opp.close(run)
end

do
    -- a friend 3 m away for 3 watch passes picks the cuffs: rescued, no note
    local run, case, rec, src = Cuffed('PIN00001')
    Move(20, vec3(1.0, 4.0, 30.0))
    Tick(3)
    H.eq(rec.near[20], 3, '(c) the friend stood within rescueRange for 3 passes')
    H.eq(rec.near[1], nil, '(c) participants are never rescue candidates')
    Fire('police:server:BobbyPinResult', 20, true)
    SetMeta(src, 'ishandcuffed', false)
    H.eq(rec.state, 'free', '(c) bobby pin from a friend who stood near -> free')
    H.eq(Sent(run, 'opp_released')[1] and Sent(run, 'opp_released')[1].ev.why, 'rescued', '(c) why rescued')
    H.eq(#case.notes, 0, '(c) a rescue is no note')
    Tick(3)
    H.eq(rec.state, 'free', '(c) still free after the settle')
    -- cuffed again in the same case: a second rescue is a self-uncuff
    Cuff(1, src)
    SetMeta(src, 'ishandcuffed', true)
    H.eq(rec.state, 'cuffed', '(c) cuffed again')
    Tick(3)
    Fire('police:server:BobbyPinResult', 20, true)
    SetMeta(src, 'ishandcuffed', false)
    Tick(3)
    H.eq(rec.state, 'detained', '(c) a second rescue in the same case -> self-uncuff -> detained')
    H.eq(#NotesOf(case, 'rs_self_uncuff'), 1, '(c) with the rs_self_uncuff note')
    Move(20, vec3(300.0, 300.0, 30.0))
    Opp.close(run)

    -- the same friend arriving on the last pass before the result: a self-uncuff
    run, case, rec, src = Cuffed('PIN00002')
    Tick(3)
    Move(20, vec3(1.0, 4.0, 30.0))
    Tick(1)
    H.eq(rec.near[20], 1, '(c) the friend arrived on the last pass')
    Fire('police:server:BobbyPinResult', 20, true)
    SetMeta(src, 'ishandcuffed', false)
    H.eq(rec.state, 'cuffed', '(c) no rescue: waiting for a cuff-break alert')
    Tick(3)
    H.eq(rec.state, 'detained', '(c) the friend arriving on the last tick -> self-uncuff -> detained')
    H.eq(#NotesOf(case, 'rs_self_uncuff'), 1, '(c) with the note')
    H.ok(Noted(run, 'rs_self_uncuff'), '(c) audited as a note')
    Move(20, vec3(300.0, 300.0, 30.0))
    Opp.close(run)

    -- the suspect sends the pin result himself, then /fixcuffs: detained and a note (critic 2 #6)
    run, case, rec, src = Cuffed('PIN00003')
    Tick(4)
    Fire('police:server:BobbyPinResult', src, true)
    SetMeta(src, 'ishandcuffed', false)
    Tick(3)
    H.eq(rec.state, 'detained', '(c) a pin result from the suspect himself, then the metadata false -> detained')
    H.eq(#NotesOf(case, 'rs_self_uncuff'), 1, '(c) + rs_self_uncuff')
    H.ok((NotesOf(case, 'rs_self_uncuff')[1].detail or ''):find('self-uncuff or admin reset', 1, true) ~= nil,
        '(c) the note says "self-uncuff or admin reset"')
    H.eq(Sent(run, 'opp_detained')[1] and Sent(run, 'opp_detained')[1].ev.why, 'self_uncuff', '(c) why self_uncuff')
    Opp.close(run)

    -- a friend who is cuffed himself, or down, rescues nobody
    run, case, rec, src = Cuffed('PIN00004')
    Move(20, vec3(1.0, 4.0, 30.0))
    players[20].PlayerData.metadata.inlaststand = true
    Tick(3)
    Fire('police:server:BobbyPinResult', 20, true)
    SetMeta(src, 'ishandcuffed', false)
    Tick(3)
    H.eq(rec.state, 'detained', '(c) a downed friend\'s pin rescues nobody')
    players[20].PlayerData.metadata.inlaststand = false
    Move(20, vec3(300.0, 300.0, 30.0))
    Opp.close(run)
end

do
    -- sc-police's cuff-break game: the uncuffed state, then the alert from the suspect (its order)
    local run, case, rec, src = Cuffed('BRK00001')
    Tick(10)
    SetMeta(src, 'ishandcuffed', false)
    Fire('police:server:CuffBreakAlert', src, 1)
    H.eq(rec.state, 'free', '(c) cuff-break at 10 s -> free')
    H.eq(Sent(run, 'opp_released')[1] and Sent(run, 'opp_released')[1].ev.why, 'broke_free', '(c) why broke_free')
    H.eq(#case.notes, 0, '(c) a fair break-free is no note')
    -- his second break-free in the case: a self-uncuff
    Cuff(1, src)
    SetMeta(src, 'ishandcuffed', true)
    Tick(10)
    SetMeta(src, 'ishandcuffed', false)
    Fire('police:server:CuffBreakAlert', src, 1)
    H.eq(rec.state, 'detained', '(c) a second cuff-break in the case -> self-uncuff -> detained')
    H.eq(#NotesOf(case, 'rs_self_uncuff'), 1, '(c) + note')
    Opp.close(run)

    -- the alert before the uncuffed state (either order)
    run, case, rec, src = Cuffed('BRK00002')
    Tick(10)
    Fire('police:server:CuffBreakAlert', src, 1)
    SetMeta(src, 'ishandcuffed', false)
    H.eq(rec.state, 'free', '(c) the alert first, then the uncuffed state -> free')
    Opp.close(run)

    for _, t in ipairs({ { at = 1, cid = 'BRK00003' }, { at = 25, cid = 'BRK00004' } }) do
        run, case, rec, src = Cuffed(t.cid)
        Tick(t.at)
        SetMeta(src, 'ishandcuffed', false)
        Fire('police:server:CuffBreakAlert', src, 1)
        H.eq(rec.state, 'detained', ('(c) a cuff-break at %d s -> self-uncuff -> detained'):format(t.at))
        H.eq(#NotesOf(case, 'rs_self_uncuff'), 1, ('(c) a cuff-break at %d s: the note'):format(t.at))
        Opp.close(run)
    end

    -- /fixcuffs (or an admin /resetcuffs): no event at all; decided after the wait for an alert
    run, case, rec, src = Cuffed('FIX00001')
    Tick(8)
    SetMeta(src, 'ishandcuffed', false)
    Tick(1)
    H.eq(rec.state, 'cuffed', '(c) /fixcuffs: still cuffed while a cuff-break alert may come')
    Tick(2)
    H.eq(rec.state, 'detained', '(c) /fixcuffs -> detained')
    H.eq(rec.share, 1, '(c) at the cuff\'s share')
    H.eq(#NotesOf(case, 'rs_self_uncuff'), 1, '(c) + note')
    Opp.close(run)

    -- the case ends inside that wait: the self-uncuff is decided at the close
    run, case, rec, src = Cuffed('FIX00002')
    Tick(8)
    SetMeta(src, 'ishandcuffed', false)
    local outcomes = Opp.close(run)
    H.eq(outcomes.FIX00002, 'detained', '(c) a self-uncuff just before the close: detained, not got_away')
    H.eq(#NotesOf(case, 'rs_self_uncuff'), 1, '(c) + note')
end

-- ============================================================================
--             (d) AFK AT THE CUFF, DOWN AND THE NEUTRALISED SHARE
-- ============================================================================

do
    -- AFK by his samples (no move, no camera turn for afkSeconds) when cuffed: share 0 and a note (critic 2 #15)
    local run, case, rec, src = Scene('AFK00001')
    Tick(RS.afkSeconds + RS.afkSampleEvery + 2)
    H.eq(rec.afk, true, '(d) AFK by his samples')
    Cuff(1, src)
    SetMeta(src, 'ishandcuffed', true)
    H.eq(rec.share, 0, '(d) AFK at the cuff -> share 0')
    H.eq(#NotesOf(case, 'rs_afk_catch'), 1, '(d) + rs_afk_catch')
    H.ok(Noted(run, 'rs_afk_catch'), '(d) audited as a note')
    Tick(RS.custodyHoldSeconds + 1)
    H.eq(rec.state, 'detained', '(d) detained')
    H.eq(Sent(run, 'opp_detained')[1] and Sent(run, 'opp_detained')[1].ev.share, 0, '(d) at share 0')
    Opp.close(run)

    -- down (whoever downed him), then cuffed: neutralisedShare (C28)
    run, case, rec, src = Scene('DOWN0001')
    SetMeta(src, 'isdead', true)
    H.eq(rec.down, true, '(d) isdead -> down')
    H.ok(rec.downAt ~= nil, '(d) downAt')
    H.eq(#Sent(run, 'opp_down'), 1, '(d) opp_down dispatched')
    Cuff(1, src)
    SetMeta(src, 'ishandcuffed', true)
    H.eq(rec.share, 0.5, '(d) down then cuffed -> share 0.5')
    Tick(RS.custodyHoldSeconds + 1)
    H.eq(Sent(run, 'opp_detained')[1] and Sent(run, 'opp_detained')[1].ev.share, 0.5, '(d) detained at 0.5')
    SetMeta(src, 'isdead', false)
    H.eq(rec.down, false, '(d) both false -> up')
    H.eq(#Sent(run, 'opp_up'), 1, '(d) opp_up dispatched')
    Opp.close(run)

    -- lying down longer than afkSeconds is not AFK: the samples pause while he is down
    run, case, rec, src = Scene('DOWN0003')
    SetMeta(src, 'isdead', true)
    Tick(RS.afkSeconds + RS.afkSampleEvery * 2)
    H.eq(rec.afk, false, '(d) down for longer than afkSeconds: not AFK')
    Cuff(1, src)
    SetMeta(src, 'ishandcuffed', true)
    H.eq(rec.share, 0.5, '(d) cuffed after a long down: still 0.5')
    H.eq(#NotesOf(case, 'rs_afk_catch'), 0, '(d) and no AFK note')
    Opp.close(run)

    -- last stand, then dead, then revived: one down, one up
    run, case, rec, src = Scene('DOWN0002')
    SetMeta(src, 'inlaststand', true)
    SetMeta(src, 'isdead', true)
    SetMeta(src, 'inlaststand', false)
    H.eq(#Sent(run, 'opp_down'), 1, '(d) last stand then dead: one opp_down')
    H.eq(#Sent(run, 'opp_up'), 0, '(d) and no opp_up between them')
    SetMeta(src, 'isdead', false)
    H.eq(#Sent(run, 'opp_up'), 1, '(d) revived: opp_up')
    Opp.close(run)

    -- an escort of a downed suspect who is not cuffed: detained at 0.5
    run, case, rec, src = Scene('ESC00001')
    Fire('police:server:EscortPlayer', 1, src)
    H.eq(rec.state, 'free', '(d) an escort of a suspect who is not down: nothing')
    SetMeta(src, 'inlaststand', true)
    Fire('police:server:EscortPlayer', 3, src)
    H.eq(rec.state, 'free', '(d) an escort by an officer outside the case: nothing')
    Fire('police:server:EscortPlayer', 1, src)
    H.eq(rec.state, 'detained', '(d) escort while down -> detained')
    H.eq(rec.share, 0.5, '(d) at neutralisedShare')
    H.eq(Sent(run, 'opp_detained')[1] and Sent(run, 'opp_detained')[1].ev.why, 'escort_down', '(d) why escort_down')
    Opp.close(run)
end

-- ============================================================================
--                 (e) BOOKINGS IN EITHER ORDER, BOOKING ZONES
-- ============================================================================

local function Detained(cid, at)
    local run, case, rec, src = Scene(cid, { at = at or MR })
    CuffAndHold(src)
    H.eq(rec.state, 'detained', cid .. ': detained')
    return run, case, rec, src
end

do
    -- the jail event, then injail 3 s later
    local run, case, rec, src = Detained('BOOK0001')
    Fire('police:server:JailPlayer', 1, src, 30)
    H.eq(rec.state, 'detained', '(e) the jail event alone books nothing')
    Tick(3)
    SetMeta(src, 'injail', 30)
    H.eq(rec.state, 'booked', '(e) the jail event and injail 3 s later -> booked')
    H.eq(rec.jailTime, 30, '(e) 30 months recorded')
    H.eq(#Sent(run, 'opp_booked'), 1, '(e) opp_booked dispatched')
    H.eq(Sent(run, 'opp_booked')[1].ev.by, 1, '(e) by the officer who jailed him')
    Opp.close(run)

    -- sc-police's order: its handler writes injail before Crimson-Police's jail handler runs (critic 2 #5)
    run, case, rec, src = Detained('BOOK0002')
    scpWritesInjail = true
    Fire('police:server:JailPlayer', 1, src, 20)
    scpWritesInjail = false
    H.eq(rec.state, 'booked', '(e) injail first and the jail event in the same tick -> booked')
    Opp.close(run)

    -- 15 s apart
    run, case, rec, src = Detained('BOOK0003')
    Fire('police:server:JailPlayer', 1, src, 30)
    Tick(15)
    SetMeta(src, 'injail', 30)
    H.eq(rec.state, 'detained', '(e) 15 s apart -> not booked')
    Opp.close(run)

    -- a jail time sent as a string, inside Mission Row (C19)
    run, case, rec, src = Detained('BOOK0004')
    Fire('police:server:JailPlayer', 1, src, '12')
    SetMeta(src, 'injail', '12')
    H.eq(rec.state, 'booked', '(e) jail time \'12\' (a string) inside the Mission Row zone -> booked')
    H.eq(rec.jailTime, 12, '(e) booked 12')
    Opp.close(run)

    -- under minJailTime
    run, case, rec, src = Detained('BOOK0005')
    Fire('police:server:JailPlayer', 1, src, '3')
    SetMeta(src, 'injail', '3')
    H.eq(rec.state, 'detained', '(e) \'3\' -> not booked')
    H.eq(#Lines(case, 'booking_too_short'), 1, '(e) the timeline says why')
    Opp.close(run)

    -- longer than jailTimeMax
    run, case, rec, src = Detained('BOOK0006')
    Fire('police:server:JailPlayer', 1, src, 500)
    SetMeta(src, 'injail', 500)
    H.eq(rec.jailTime, 120, '(e) 500 months are recorded as jailTimeMax')
    Opp.close(run)

    -- outside every zone
    run, case, rec, src = Detained('BOOK0007', FAR)
    Fire('police:server:JailPlayer', 1, src, 30)
    SetMeta(src, 'injail', 30)
    H.eq(rec.state, 'detained', '(e) outside every zone -> not booked')
    H.eq(#Lines(case, 'booked_outside_station'), 1, '(e) the timeline says booked_outside_station')
    Opp.close(run)

    -- bookingZones = {}: anywhere
    local zones = RS.bookingZones
    RS.bookingZones = {}
    run, case, rec, src = Detained('BOOK0008', FAR)
    Fire('police:server:JailPlayer', 1, src, 30)
    SetMeta(src, 'injail', 30)
    H.eq(rec.state, 'booked', '(e) bookingZones {} -> booked anywhere')
    RS.bookingZones = zones
    Opp.close(run)

    -- a jail before the detain counts for nothing, from 10 m for nothing
    run, case, rec, src = Scene('BOOK0009', { at = MR })
    Cuff(1, src)
    SetMeta(src, 'ishandcuffed', true)
    Fire('police:server:JailPlayer', 1, src, 30)
    SetMeta(src, 'injail', 30)
    local refused = Lines(case, 'jail_refused')[1] or {}
    H.eq(refused.why, 'not_detained', '(e) a jail during the hold: the timeline says jail_refused (not_detained)')
    H.eq(refused.months, 30, '(e) with the months')
    H.eq(refused.by, 1, '(e) and the officer')
    Tick(RS.custodyHoldSeconds + 1)
    H.eq(rec.state, 'detained', '(e) a jail during the hold books nothing (he is detained by the hold)')
    Opp.close(run)
    run, case, rec, src = Detained('BOOK0010')
    Move(1, vec3(MR.x + 10.0, MR.y + 1.0, MR.z))
    Fire('police:server:JailPlayer', 1, src, 30)
    SetMeta(src, 'injail', 30)
    H.eq(rec.state, 'detained', '(e) a jail from 10 m (jailRange 6) -> not booked')
    H.eq(Lines(case, 'jail_refused')[1] and Lines(case, 'jail_refused')[1].why, 'distance',
        '(e) the timeline says jail_refused (distance)')
    Opp.close(run)
    -- 4 is a participant who is off duty
    run, case, rec, src = Scene('BOOK0013', { at = MR, officers = { 1, 4 } })
    CuffAndHold(src)
    H.eq(rec.state, 'detained', 'BOOK0013: detained')
    Fire('police:server:JailPlayer', 4, src, 30)
    SetMeta(src, 'injail', 30)
    H.eq(rec.state, 'detained', '(e) a jail by an off-duty participant -> not booked')
    H.eq(Lines(case, 'jail_refused')[1] and Lines(case, 'jail_refused')[1].why, 'not_on_duty',
        '(e) the timeline says jail_refused (not_on_duty)')
    Opp.close(run)

    -- a jail by someone outside the case: stopped and a note
    run, case, rec, src = Scene('BOOK0011', { at = MR })
    Fire('police:server:JailPlayer', 3, src, 30)
    H.eq(rec.state, 'free', '(e) an outsider\'s jail event alone changes nothing')
    SetMeta(src, 'injail', 30)
    H.eq(rec.outcome, 'stopped', '(e) jail by an outsider -> stopped')
    H.eq(rec.state, 'void', '(e) he counts for nobody')
    H.eq(#NotesOf(case, 'rs_outside_jail'), 1, '(e) + rs_outside_jail')
    H.ok(Noted(run, 'rs_outside_jail'), '(e) audited as a note')
    local outcomes = Opp.close(run)
    H.eq(outcomes.BOOK0011, 'stopped', '(e) the case outcome is stopped')

    -- an outsider's jail event that sc-police refused (no injail) never spoils the case's own booking after it
    run, case, rec, src = Scene('BOOK0012', { at = MR })
    Cuff(1, src)
    SetMeta(src, 'ishandcuffed', true)
    Tick(RS.custodyHoldSeconds - 5)
    Fire('police:server:JailPlayer', 3, src, 30)
    Tick(6)
    H.eq(rec.state, 'detained', '(e) detained after an outsider\'s refused jail event')
    Fire('police:server:JailPlayer', 1, src, 30)
    SetMeta(src, 'injail', 30)
    H.eq(rec.state, 'booked', '(e) the participant\'s booking still counts')
    H.eq(rec.outcome, nil, '(e) not stopped')
    Opp.close(run)
end

-- ============================================================================
--                              (f) HOSPITAL RULES
-- ============================================================================

do
    -- down 100 s, then a hospital respawn: void and a note
    local run, case, rec, src = Scene('HOSP0001')
    SetMeta(src, 'isdead', true)
    Tick(100)
    Fire('hospital:server:RespawnAtHospital', src, 1)
    H.eq(rec.state, 'void', '(f) respawn after 100 s down -> void')
    H.eq(#NotesOf(case, 'rs_early_respawn'), 1, '(f) + rs_early_respawn')
    H.ok(Noted(run, 'rs_early_respawn'), '(f) audited as a note')
    Opp.close(run)

    -- a respawn while not down
    run, case, rec, src = Scene('HOSP0002')
    Fire('hospital:server:RespawnAtHospital', src, 1)
    H.eq(rec.state, 'void', '(f) a respawn while not down -> void')
    H.eq(#NotesOf(case, 'rs_early_respawn'), 1, '(f) + note')
    Opp.close(run)

    -- down 500 s with no officer near: spawn protection, a cuff then does not detain
    run, case, rec, src = Scene('HOSP0003')
    Move(src, vec3(2000.0, 2000.0, 30.0))
    SetMeta(src, 'isdead', true)
    Tick(500)
    Fire('hospital:server:RespawnAtHospital', src, 1)
    H.eq(rec.state, 'free', '(f) after 500 s: not void')
    H.ok(rec.protectUntil ~= nil, '(f) spawn protection')
    SetMeta(src, 'isdead', false)
    Move(src, vec3(1.0, 1.0, 30.0))
    Tick(2)
    Cuff(1, src)
    SetMeta(src, 'ishandcuffed', true)
    Tick(RS.custodyHoldSeconds + 1)
    H.eq(rec.state, 'free', '(f) protected: a cuff then does not detain')
    H.eq(#Sent(run, 'opp_detained'), 0, '(f) no opp_detained')
    H.eq(#Lines(case, 'spawn_protected'), 1, '(f) the timeline says spawn_protected')
    Opp.close(run)

    -- C26: officers in contact at the down and at the respawn: no protection, a cuff scores neutralisedShare
    run, case, rec, src = Scene('HOSP0004')
    Move(src, vec3(40.0, 0.0, 30.0))
    SetMeta(src, 'isdead', true)
    H.eq(rec.downNear, true, '(f) an officer within contactRange at the down')
    Tick(500)
    Fire('hospital:server:RespawnAtHospital', src, 1)
    H.eq(rec.protectUntil, nil, '(f) C26: no spawn protection')
    SetMeta(src, 'isdead', false)
    Move(src, vec3(1.0, 1.0, 30.0))
    Cuff(1, src)
    SetMeta(src, 'ishandcuffed', true)
    H.eq(rec.share, 0.5, '(f) C26: his next cuff scores at neutralisedShare')
    Tick(RS.custodyHoldSeconds + 1)
    H.eq(rec.state, 'detained', '(f) C26: detained')
    Opp.close(run)

    -- in contact at the down but nobody near at the respawn: protected
    run, case, rec, src = Scene('HOSP0005')
    SetMeta(src, 'isdead', true)
    Tick(450)
    Move(src, vec3(3000.0, 3000.0, 30.0))
    Fire('hospital:server:RespawnAtHospital', src, 1)
    H.ok(rec.protectUntil ~= nil, '(f) officers gone at the respawn: protected')
    Opp.close(run)
end

-- ============================================================================
--        (g) RESCUE CANDIDATES ARE READ ONLY WHILE A SUSPECT IS CUFFED
-- ============================================================================

do
    local run, case, rec, src = Scene('CAND0001')
    onlineReads, pedReads = 0, {}
    Tick(10)
    H.eq(onlineReads, 0, '(g) no suspect cuffed: the online list is never read')
    H.eq(pedReads[21] or 0, 0, '(g) and no bystander\'s coords are read (count = 0)')
    Cuff(1, src)
    SetMeta(src, 'ishandcuffed', true)
    Tick(5)
    H.eq(onlineReads, 5, '(g) during the hold: once per pass')
    H.ok((pedReads[21] or 0) >= 5, '(g) the bystander\'s coords once per pass')
    Tick(RS.custodyHoldSeconds)
    H.eq(rec.state, 'detained', '(g) detained')
    onlineReads, pedReads = 0, {}
    Tick(10)
    H.eq(onlineReads, 0, '(g) after the hold nothing is read again')
    H.eq(pedReads[21] or 0, 0, '(g) count = 0')
    Opp.close(run)
end

-- ============================================================================
--                                 (h) THE HINT
-- ============================================================================
-- EVERY CUFF ATTEMPT BY A LIVE PARTICIPANT (C5).

do
    local run, case, rec, src = Scene('HINT0001', { live = true })
    hints = {}
    Cuff(1, 21)
    H.eq(#hints, 1, '(h) a cuff attempt on a bystander: the hint')
    Cuff(1, src)
    H.eq(#hints, 2, '(h) on a suspect: the same hint')
    H.ok(hints[1].run == run and hints[1].src == 1 and hints[2].run == run and hints[2].src == 1,
        '(h) the same arguments either way')
    Opp.close(run)
    run, case, rec, src = Scene('HINT0002')
    hints = {}
    Cuff(1, src)
    H.eq(#hints, 0, '(h) not a live run: no hint')
    Opp.close(run)
end

-- ============================================================================
--            (i) NOTES ONLY: NOTHING HERE HOLDS AN OFFICER'S POINTS
-- ============================================================================

do
    H.eq(#flags, 0, '(i) CP.AntiCheat.flag was never called')
    local flagged = 0
    for _, run in ipairs(runs) do
        if run.flagged then flagged = flagged + 1 end
        for _, p in pairs(run.participants) do if p.flagged then flagged = flagged + 1 end end
    end
    H.eq(flagged, 0, '(i) no run.flagged and no p.flagged')
    local f = io.open(H.root .. 'modules/opponents/proof/server.lua', 'r')
    local text = f and f:read('a') or ''
    if f then f:close() end
    H.ok(#text > 0, '(i) the proof file is readable')
    H.eq(text:find('AntiCheat.flag', 1, true), nil, '(i) the proof file never calls CP.AntiCheat.flag')
    H.eq(text:find('flagged%s*='), nil, '(i) and never sets a flagged field')
    H.eq(Opp.active(), false, '(i) every case is closed')
end

return H

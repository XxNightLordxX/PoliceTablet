-- CP.Opponents core (step V4): cases keyed by citizenid, the 1 s watch, leaving, instances, rejoins, AFK samples and
-- staff notes, against the real qbx, access, anticheat and cash modules (qbx_core's exports and events mocked).

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
--                        qbx_core, NATIVES AND THREADS
-- ============================================================================
-- Like FXServer, every export answer and event argument is a copy. Every qbx_core export call is counted, and so
-- are the natives the watch may read.

local players = {}   -- [src] = a loaded character's Player ({ PlayerData = ... })
local exportCalls = 0
H.exportsMock.qbx_core = {
    GetPlayer = function(src)
        exportCalls = exportCalls + 1
        return Copy(players[tonumber(src)])
    end,
    GetPlayerByCitizenId = function(cid)
        exportCalls = exportCalls + 1
        for _, p in pairs(players) do
            if p.PlayerData.citizenid == cid then return Copy(p) end
        end
        return nil
    end,
    GetQBPlayers = function()
        exportCalls = exportCalls + 1
        return Copy(players)
    end,
    GetJobs = function()
        exportCalls = exportCalls + 1
        return {}
    end,
}

local counts, bySrc = {}, {}
local bucket, cam = {}, {}
local function Counted(name, fn)
    return function(...)
        counts[name] = (counts[name] or 0) + 1
        local key = name .. ':' .. tostring((...))
        bySrc[key] = (bySrc[key] or 0) + 1
        return fn(...)
    end
end
local function ResetCounts() counts, bySrc = {}, {} end
local function N(name) return counts[name] or 0 end
_G.GetPlayerPed = Counted('GetPlayerPed', _G.GetPlayerPed)
_G.GetEntityCoords = Counted('GetEntityCoords', _G.GetEntityCoords)
_G.GetPlayerRoutingBucket = Counted('GetPlayerRoutingBucket', function(src) return bucket[tonumber(src)] or 0 end)
_G.GetPlayerCameraRotation = Counted('GetPlayerCameraRotation', function(src)
    return cam[tonumber(src)] or vec3(0.0, 0.0, 0.0)
end)
_G.GetStateBagValue = Counted('GetStateBagValue', _G.GetStateBagValue)

local threads = 0
local realThread = _G.CreateThread
_G.CreateThread = function(fn)
    threads = threads + 1
    return realThread(fn)
end
_G.Citizen.CreateThread = _G.CreateThread

-- Crimson-Arena's flag: a state bag change handler (the module's) and the value on the player's bag.
local bagHandlers = {}
_G.AddStateBagChangeHandler = function(key, _, fn) bagHandlers[#bagHandlers + 1] = { key = key, fn = fn } end
_G.GetPlayerFromStateBagName = function(name) return tonumber(tostring(name):match('^player:(%d+)$')) or 0 end
local function SetArenaBag(src, value)
    for _, h in ipairs(bagHandlers) do
        if h.key == 'crimsonArena' then h.fn(('player:%d'):format(src), 'crimsonArena', value) end
    end
    H.players[src].state = H.players[src].state or {}
    H.players[src].state.crimsonArena = value
    H.step(0)
end

-- A character: loaded (players[src]) or not, at coords, with a job.
local function Character(src, cid, coords, job, onduty)
    H.players[src] = H.players[src] or {}
    H.players[src].coords = coords or vec3(0.0, 0.0, 0.0)
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
local function Drop(src)
    players[src] = nil
    H.fire('playerDropped', src)
end
local function Unload(src)
    TriggerEvent('QBCore:Server:OnPlayerUnload', src)
    players[src] = nil
end
local function Move(src, coords) H.players[src].coords = coords end

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

local audits, flags, toasts, sent = {}, {}, {}, {}
CP.Admin = {
    audit = function(...) audits[#audits + 1] = { ... } end,
}
CP.Tablet = {
    notify = function() return true end,
    notifyMany = function(srcs, kind, key)
        toasts[#toasts + 1] = { srcs = srcs, kind = kind, key = key }
        return #srcs
    end,
}
CP.Runs = {
    dispatch = function(run, index, src, ev)
        sent[#sent + 1] = { run = run, index = index, src = src, ev = ev }
        return true
    end,
}
CP.Alerts = {
    foreignFlag = function(src)
        local st = H.players[src] and H.players[src].state
        local v = st and st.crimsonArena
        return type(v) == 'table' and v.active == true and v.source ~= 'crimson-police'
    end,
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
-- the real access module without its qbx listeners (they write officer rows on every load)
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
H.step(0)
local Opp = CP.Opponents
local RS = Config.RealSuspects

local runSeq = 0
local runs = {}
local function NewRun(officers)
    runSeq = runSeq + 1
    local run = {
        id = ('run-%04d'):format(runSeq),
        missionId = 'live_crime',
        seed = 4242 + runSeq,
        state = 'in_progress',
        order = {},
        participants = {},
        objectiveIndex = 1,
        payTier = { cash = 1.0 },
        cashBase = 500,
        score = { shared = {} },
    }
    for _, src in ipairs(officers) do
        run.order[#run.order + 1] = src
        run.participants[src] = {
            src = src,
            citizenid = ('OFF%05d'):format(src),
            status = 'active',
            result = 'completed',
            score = {},
        }
    end
    runs[#runs + 1] = run
    return run
end

local function Sent(run, kind, cid)
    local out = {}
    for _, s in ipairs(sent) do
        if s.run == run and s.ev.type == kind and (cid == nil or s.ev.cid == cid) then out[#out + 1] = s end
    end
    return out
end
local function NotesOf(case, reason)
    local out = {}
    for _, n in ipairs(case.notes) do if n.what == reason then out[#out + 1] = n end end
    return out
end
local function Noted(run, reason)
    for _, a in ipairs(audits) do
        if a[4] == 'runNoted' and a[5] == run.id and a[7] == reason then return a end
    end
    return nil
end
local function Tick(seconds) H.advance((seconds or 1) * 1000, 1000) end

-- the two officers of every run, on SAST duty at the origin
Load(1, 'OFF00001', vec3(0.0, 0.0, 30.0), 'sast', true)
Load(2, 'OFF00002', vec3(5.0, 0.0, 30.0), 'sast', true)

-- ============================================================================
--                      (a) NOTHING TRACKED: NOTHING RUNS
-- ============================================================================

do
    H.eq(type(RS), 'table', 'Config.RealSuspects exists')
    H.eq(RS.onLeave, 'void', 'onLeave ships void')
    H.eq(RS.excludeAdmins, true, 'admins are never suspects (shipped)')
    H.eq(Opp.active(), false, 'no case: not active')
    ResetCounts()
    threads, exportCalls = 0, 0
    Tick(10)
    H.eq(N('GetPlayerPed') + N('GetEntityCoords') + N('GetPlayerRoutingBucket') + N('GetPlayerCameraRotation'), 0,
        '(a) 10 s with nothing tracked read no native')
    H.eq(threads, 0, '(a) and start no thread')
    H.eq(exportCalls, 0, '(a) and call no qbx export')
    -- a character loading and a player leaving while nothing is tracked cost this module nothing
    Load(30, 'IDLE0030', vec3(0.0, 0.0, 0.0))
    Drop(30)
    Tick(2)
    H.eq(N('GetPlayerRoutingBucket'), 0, '(a) a load and a drop start nothing')
end

-- ============================================================================
--               (b) A CASE: THE TICK, CONTACT, LOST, AFK SAMPLES
-- ============================================================================

local R1 = NewRun({ 1, 2 })
local C1
do
    Load(11, 'SUSA0001', vec3(500.0, 0.0, 30.0))
    Load(12, 'SUSB0002', vec3(-500.0, 0.0, 30.0))
    threads = 0
    -- Crimson-Contracts' members map ({ [cid] = src }): the server ids in it are never used (C9)
    C1 = Opp.open(R1, {
        kind = 'live',
        index = 1,
        members = { SUSA0001 = 99, SUSB0002 = 98 },
        lostRule = { range = 400.0, seconds = 90 },
    })
    H.ok(C1 ~= nil, 'open: a case')
    H.eq(threads, 1, 'open starts the watch (one thread)')
    H.eq(Opp.active(), true, 'a case is open: active')
    H.eq(Opp.caseOf(R1), C1, 'caseOf')
    local a, b = C1.suspects.SUSA0001, C1.suspects.SUSB0002
    H.eq(a.src, 11, 'the src is resolved from the citizenid, not from the payload')
    H.eq(b.src, 12, 'the second suspect')
    H.eq(a.license, 'license:susa0001', 'the license read once at open')
    H.ok((a.label == 'A' and b.label == 'B') or (a.label == 'B' and b.label == 'A'), 'labels A and B')
    H.eq(a.state, 'free', 'suspects start free')
    local again = Opp.open(R1, { members = { 'SUSA0001' } })
    H.eq(again, C1, 'a second open of the run returns the same case')
    local c, r = Opp.bySrc(11)
    H.ok(c == C1 and r == a, 'bySrc')
    c, r = Opp.byCid('SUSB0002')
    H.ok(c == C1 and r == b, 'byCid')

    -- one tick: no qbx export, only the three natives (and the camera of the first AFK sample)
    ResetCounts()
    exportCalls = 0
    Tick(1)
    H.eq(exportCalls, 0, '(b) a tick calls no qbx export')
    H.eq(N('GetPlayerRoutingBucket'), 2, '(b) the bucket of each suspect')
    H.eq(N('GetPlayerPed'), 4, '(b) the peds of 2 officers and 2 suspects')
    H.eq(N('GetEntityCoords'), 4, '(b) their server coords')
    H.eq(N('GetPlayerCameraRotation'), 2, '(b) the first AFK sample of each suspect')
    H.eq(N('GetStateBagValue'), 0, '(b) no state bag read per tick')
    ResetCounts()
    exportCalls = 0
    Tick(5)
    H.eq(exportCalls, 0, '(b) five more ticks: still no qbx export')
    H.eq(N('GetPlayerCameraRotation'), 0, '(b) no camera between samples')
    H.eq(N('GetPlayerRoutingBucket'), 10, '(b) one bucket per suspect per tick')

    -- contact: an officer within contactRange
    H.eq(a.contactAt, nil, 'no contact while far')
    Move(11, vec3(60.0, 0.0, 30.0))
    Tick(1)
    H.ok(a.contactAt ~= nil, '(b) contact within contactRange')
    H.eq(#NotesOf(C1, 'rs_teleport'), 1, '(b) 440 m in one second: an rs_teleport note (Config.AntiCheat.maxSpeed)')
    H.eq(#Sent(R1, 'opp_contact', 'SUSA0001'), 1, '(b) opp_contact dispatched')
    H.eq(Sent(R1, 'opp_contact')[1].src, nil, 'a server event (no src)')
    H.eq(Sent(R1, 'opp_contact')[1].index, 1, 'to the case\'s objective')
    Tick(3)
    H.eq(#Sent(R1, 'opp_contact', 'SUSA0001'), 1, '(b) once')
    H.ok(Opp.nearAny(R1, vec3(60.0, 5.0, 30.0), 20.0), 'nearAny: a suspect within range')
    H.eq(Opp.nearAny(R1, vec3(3000.0, 0.0, 30.0), 20.0), false, 'nearAny: none')

    -- lost with the case's lostRule: no officer within 400 m for 90 s after the contact
    Move(11, vec3(2000.0, 0.0, 30.0))
    Tick(89)
    H.eq(a.state, 'free', '(b) not lost before lostRule.seconds')
    Tick(2)
    H.eq(a.state, 'lost', '(b) lost after 90 s with no officer near')
    H.eq(#Sent(R1, 'opp_lost', 'SUSA0001'), 1, '(b) opp_lost dispatched')
    H.eq(Sent(R1, 'opp_lost')[1].ev.prev, 'free', 'with the previous state')
    H.eq(b.state, 'free', '(b) no contact and the crime still on: never lost')
    -- the trail: a point every trail.every s
    local trail = Opp.trailOf(R1, 'SUSB0002')
    H.ok(#trail >= 20 and #trail <= 22, ('(b) trail: one point every 5 s (%d)'):format(#trail))

    -- AFK: suspect B stood still with the same camera since his first sample (second 1): AFK after afkSeconds
    H.eq(b.afk, false, 'not AFK yet')
    Tick(RS.afkSeconds - 106)
    H.eq(b.afk, false, '(b) still for 295 s: not AFK yet')
    H.eq(a.afk, false, '(b) a suspect who moved is not AFK')
    Tick(RS.afkSampleEvery + 5)
    H.eq(b.afk, true, '(b) AFK after afkSeconds of no movement and no camera turn')
    -- he is cuffed (V5 sets it): the samples stop and rec.afk keeps its value
    H.ok(Opp.setState(R1, 'SUSB0002', 'cuffed', { why = 'test' }), 'setState cuffed')
    H.eq(#Sent(R1, 'opp_cuffed', 'SUSB0002'), 1, 'opp_cuffed dispatched')
    Move(12, vec3(-480.0, 30.0, 30.0))
    cam[12] = vec3(10.0, 0.0, 90.0)
    ResetCounts()
    Tick(60)
    H.eq(N('GetPlayerCameraRotation'), 0, '(b) no AFK sample while cuffed (C17)')
    H.eq(b.afk, true, '(b) rec.afk keeps the value it had at the cuff')
end

-- ============================================================================
--               (c) C9: A STALE SERVER ID NEVER MAKES A SUSPECT
-- ============================================================================

local R2 = NewRun({ 1, 2 })
local C2
do
    Load(13, 'SUSC0003', vec3(800.0, 0.0, 30.0))
    C2 = Opp.open(R2, { kind = 'live', members = { SUSC0003 = true } })
    local rec = C2.suspects.SUSC0003
    Tick(1)
    Drop(13)
    H.eq(rec.src, nil, '(c) the drop clears the server id')
    -- another player gets server id 13 and loads his own character
    Load(13, 'BYST0099', vec3(800.0, 0.0, 30.0))
    H.eq(Opp.bySrc(13), nil, '(c) the new player on id 13 is not a suspect')
    H.eq(rec.src, nil, '(c) the record waits for its own citizenid')
    ResetCounts()
    Tick(5)
    H.eq(bySrc['GetPlayerRoutingBucket:13'], nil, '(c) the watch never reads id 13')
    H.eq(rec.state, 'free', 'within the grace he is still free')
    -- the real suspect comes back on another id within disconnectGrace
    Load(14, 'SUSC0003', vec3(4000.0, 0.0, 30.0))
    H.eq(rec.src, 14, '(c) rejoin: the same record with the new server id')
    Tick(1)
    H.eq(#NotesOf(C2, 'rs_teleport'), 0, '(c) the first pass after a rejoin is no teleport')
    local c = Opp.bySrc(14)
    H.eq(c, C2, '(c) bySrc follows the new id')
    H.eq(rec.dropAt, nil, 'the grace ended with the rejoin')
    Tick(RS.disconnectGrace + 5)
    H.eq(rec.state, 'free', 'a rejoin within the grace keeps him in the case')
    H.eq(#NotesOf(C2, 'rs_combat_log'), 0, 'a rejoin within the grace is no leave')
end

-- ============================================================================
--               (d) C8: ANOTHER SCRIPT'S ARENA FLAG IN BUCKET 0
-- ============================================================================

do
    local rec = C2.suspects.SUSC0003
    SetArenaBag(14, { active = true })
    H.eq(#NotesOf(C2, 'rs_fake_arena_flag'), 1, '(d) a foreign flag in bucket 0: a note')
    H.ok(Noted(R2, 'rs_fake_arena_flag') ~= nil, '(d) audited as runNoted')
    SetArenaBag(14, { active = true, match = 2 })
    H.eq(#NotesOf(C2, 'rs_fake_arena_flag'), 1, '(d) once')
    Tick(3)
    H.eq(rec.state, 'free', '(d) still tracked and free')
    H.eq(rec.src, 14, '(d) still his server id')
    SetArenaBag(14, nil)
end

-- ============================================================================
--               (e) INSTANCES: A BUCKET OTHER THAN 0 IS LEAVING
-- ============================================================================

local nextSrc = 40
local function OneSuspect(cid, opts)
    opts = opts or {}
    nextSrc = nextSrc + 1
    local src = nextSrc
    local run = NewRun({ 1, 2 })
    Load(src, cid, opts.coords or vec3(900.0, 0.0, 30.0))
    local case = Opp.open(run, { kind = 'live', members = { cid } })
    return run, case, case.suspects[cid], src
end

do
    for _, t in ipairs({
        { mode = 'void', from = 'free', want = 'left' },
        { mode = 'caught', from = 'free', want = 'detained', byLeave = true },
        { mode = 'escaped', from = 'free', want = 'lost' },
        { mode = 'void', from = 'cuffed', want = 'detained' },
        { mode = 'void', from = 'detained', want = 'detained' },
        { mode = 'escaped', from = 'detained', want = 'detained' },
    }) do
        RS.onLeave = t.mode
        local cid = ('INST%04d'):format(nextSrc + 1)
        local run, case, rec, src = OneSuspect(cid)
        Tick(1)
        if t.from ~= 'free' then Opp.setState(run, cid, t.from, { why = 'test' }) end
        local label = ('(e) %s, onLeave %s'):format(t.from, t.mode)
        bucket[src] = 4210
        Tick(1)
        H.eq(rec.state, t.want, label .. ' -> ' .. t.want)
        H.eq(rec.byLeave == true, t.byLeave == true, label .. ': byLeave')
        H.eq(#NotesOf(case, 'rs_evade_instance'), 1, label .. ': the rs_evade_instance note')
        H.ok(Noted(run, 'rs_evade_instance') ~= nil, label .. ': audited')
        H.eq(NotesOf(case, 'rs_evade_instance')[1] and NotesOf(case, 'rs_evade_instance')[1].detail,
            ('Suspect %s: no contact'):format(rec.label), label .. ': "no contact"')
        if t.from == 'free' then
            local kind = ({ left = 'opp_left', detained = 'opp_detained', lost = 'opp_lost' })[t.want]
            H.eq(#Sent(run, kind, cid), 1, label .. ': ' .. kind)
        end
        Tick(3)
        H.eq(#NotesOf(case, 'rs_evade_instance'), 1, label .. ': one note while he stays inside')
        bucket[src] = nil
        Opp.close(run)
    end
    RS.onLeave = 'void'
end

-- ============================================================================
--            (f) LEAVING: DROP, REJOIN, THE GRACE, THE onLeave RULE
-- ============================================================================

do
    -- within the grace: the same record with the new id
    local run, case, rec, src = OneSuspect('DROP0001')
    Tick(1)
    Drop(src)
    Tick(RS.disconnectGrace - 10)
    H.eq(rec.state, 'free', '(f) free within the grace')
    Load(src + 100, 'DROP0001', vec3(900.0, 0.0, 30.0))
    H.eq(rec.src, src + 100, '(f) rejoin within the grace: the same record, the new src')
    Tick(20)
    H.eq(rec.state, 'free', '(f) and he stays in the case')
    Opp.close(run)

    -- past the grace: the onLeave rule, with and without contact, every time a note
    for _, t in ipairs({
        { mode = 'void', want = 'left' },
        { mode = 'caught', want = 'detained' },
        { mode = 'escaped', want = 'lost' },
    }) do
        for _, contact in ipairs({ false, true }) do
            RS.onLeave = t.mode
            local cid = ('LEAV%04d'):format(nextSrc + 1)
            run, case, rec, src = OneSuspect(cid, { coords = contact and vec3(50.0, 0.0, 30.0) or nil })
            Tick(1)
            local label = ('(f) onLeave %s, %s'):format(t.mode, contact and 'after contact' or 'no contact')
            H.eq(rec.contactAt ~= nil, contact, label .. ': contact as set up')
            Tick(9)
            Drop(src)
            Tick(RS.disconnectGrace - 1)
            H.eq(rec.state, 'free', label .. ': free until the grace ends')
            H.eq(#NotesOf(case, 'rs_combat_log'), 0, label .. ': no note within the grace')
            Tick(2)
            H.eq(rec.state, t.want, label .. ' -> ' .. t.want)
            H.eq(rec.byLeave == true, t.mode == 'caught', label .. ': byLeave')
            local notes = NotesOf(case, 'rs_combat_log')
            H.eq(#notes, 1, label .. ': the rs_combat_log note')
            H.ok(Noted(run, 'rs_combat_log') ~= nil, label .. ': audited as runNoted')
            local detail = notes[1] and notes[1].detail or ''
            if contact then
                H.ok(detail:find('left within 120 s of contact', 1, true) ~= nil, label .. ': ' .. detail)
            else
                H.eq(detail, ('Suspect %s: no contact'):format(rec.label), label .. ': "no contact"')
            end
            Opp.close(run)
        end
    end
    RS.onLeave = 'void'

    -- a character switch is leaving at once; a drop in cuffs is detained at the drop (C18)
    run, case, rec, src = OneSuspect('UNLD0001')
    Tick(1)
    Unload(src)
    H.step(0)
    H.eq(rec.state, 'left', '(f) character switch: the onLeave rule at once')
    H.eq(#NotesOf(case, 'rs_combat_log'), 1, '(f) with the note')
    Opp.close(run)

    run, case, rec, src = OneSuspect('CUFF0001', { coords = vec3(20.0, 0.0, 30.0) })
    Tick(1)
    Opp.setState(run, 'CUFF0001', 'cuffed', { why = 'test' })
    Drop(src)
    H.eq(rec.state, 'detained', '(f) a drop in cuffs is detained at the drop (C18)')
    H.eq(#NotesOf(case, 'rs_combat_log'), 1, '(f) with the note')
    H.eq(rec.byLeave, false, '(f) a detain in cuffs, not by the leave rule')
    -- he comes back within reconnectNoticeMinutes: the officers are told, no name
    toasts = {}
    Load(src + 100, 'CUFF0001', vec3(20.0, 0.0, 30.0))
    H.eq(#toasts, 1, '(f) back in the city: one toast')
    H.eq(toasts[1] and toasts[1].key, 'opp.back_in_city', '(f) the toast text')
    H.eq(toasts[1] and table.concat(toasts[1].srcs, ','), '1,2', '(f) to the case\'s active participants')
    H.eq(rec.state, 'detained', '(f) detained stays detained (C25)')
    Opp.close(run)
end

-- ============================================================================
--                     (f2) THE CASE ENDS INSIDE THE GRACE
-- ============================================================================
-- The leave is final at the close. End case, the time limit or the last officer leaving: modules/runs sets
-- run.state = 'ended' and then fires run:ended. A suspect who logged off just before is never 'got_away' by the
-- leave, and his note is written.

local function Audited(run, reason)
    local n = 0
    for _, a in ipairs(audits) do
        if a[4] == 'runNoted' and a[5] == run.id and a[7] == reason then n = n + 1 end
    end
    return n
end
local function EndRun(run)
    run.state = 'ended'
    CP.Hooks.fire('run:ended', run, 'completed', 'completed')
    H.step(0)
end

do
    for _, t in ipairs({
        { mode = 'void', want = 'left' },
        { mode = 'caught', want = 'detained', byLeave = true },
        { mode = 'escaped', want = 'got_away' },
        { mode = 'void', from = 'detained', want = 'detained' },
    }) do
        RS.onLeave = t.mode
        local cid = ('ENDG%04d'):format(nextSrc + 1)
        local run, case, rec, src = OneSuspect(cid, { coords = vec3(50.0, 0.0, 30.0) })
        Tick(1)
        if t.from then Opp.setState(run, cid, t.from, { why = 'test' }) end
        local label = ('(f2) %s, onLeave %s, the case ends 30 s after the drop'):format(t.from or 'free', t.mode)
        H.ok(rec.contactAt ~= nil, label .. ': contact first')
        Drop(src)
        Tick(30)
        H.eq(rec.state, t.from or 'free', label .. ': still inside the grace')
        local before = #sent
        EndRun(run)
        H.eq(Opp.caseOf(run), nil, label .. ': run:ended closed the case')
        local outcomes = Opp.close(run)
        H.eq(outcomes[cid], t.want, label .. ' -> ' .. t.want)
        H.eq(rec.byLeave == true, t.byLeave == true, label .. ': byLeave')
        local notes = NotesOf(case, 'rs_combat_log')
        H.eq(#notes, 1, label .. ': exactly one rs_combat_log note')
        H.ok(notes[1] ~= nil and notes[1].detail:find('left within 120 s of contact', 1, true) ~= nil,
            label .. ': left soon after contact')
        H.eq(Audited(run, 'rs_combat_log'), 1, label .. ': audited once')
        H.eq(#sent, before, label .. ': no objective event while closing')
        H.eq(Opp.bySrc(src), nil, label .. ': no longer tracked')
    end
    RS.onLeave = 'void'

    -- offline when the case opened and the case ends before he comes: the onLeave rule and the note at the close
    local run = NewRun({ 1, 2 })
    local case = Opp.open(run, { kind = 'live', members = { OFFL0009 = true } })
    Tick(10)
    EndRun(run)
    local outcomes = Opp.close(run)
    H.eq(outcomes.OFFL0009, 'left', '(f2) offline at open, never came: left (void), not got away')
    local notes = NotesOf(case, 'rs_combat_log')
    H.eq(#notes, 1, '(f2) with one rs_combat_log note')
    H.eq(notes[1] and notes[1].detail,
        ('Suspect %s: offline when the case opened and not back in time'):format(case.suspects.OFFL0009.label),
        '(f2) "offline when the case opened"')

    -- a crew: every suspect's leave reaches the audit, not only the first one's
    local a, b = nextSrc + 1, nextSrc + 2
    nextSrc = nextSrc + 2
    Load(a, 'CREW0001', vec3(900.0, 0.0, 30.0))
    Load(b, 'CREW0002', vec3(950.0, 0.0, 30.0))
    run = NewRun({ 1, 2 })
    case = Opp.open(run, { kind = 'live', members = { 'CREW0001', 'CREW0002' } })
    Tick(1)
    Unload(a)
    Unload(b)
    H.step(0)
    H.eq(#NotesOf(case, 'rs_combat_log'), 2, '(f2) a crew of two logs off: two notes in the case')
    H.eq(Audited(run, 'rs_combat_log'), 2, '(f2) and both are audited (one per suspect)')
    local details = {}
    for _, x in ipairs(audits) do
        if x[4] == 'runNoted' and x[5] == run.id and x[7] == 'rs_combat_log' then details[#details + 1] = x[8] end
    end
    table.sort(details)
    H.eq(table.concat(details, ' | '), 'Suspect A: no contact | Suspect B: no contact', '(f2) one for each label')
    Opp.close(run)
end

-- ============================================================================
--                       (h) OFFLINE WHEN THE CASE OPENS
-- ============================================================================

do
    local run = NewRun({ 1, 2 })
    local case = Opp.open(run, { kind = 'live', members = { OFFL0001 = true, OFFL0002 = true } })
    local r1, r2 = case.suspects.OFFL0001, case.suspects.OFFL0002
    H.eq(r1.src, nil, '(h) offline at open: no server id')
    H.ok(r1.dropAt ~= nil, '(h) he starts in the grace path')
    Tick(30)
    Load(60, 'OFFL0001', vec3(700.0, 0.0, 30.0))
    H.eq(r1.src, 60, '(h) he loads within the grace: tracked')
    H.eq(r1.dropAt, nil, '(h) restored')
    Tick(RS.disconnectGrace)
    H.eq(r1.state, 'free', '(h) and still free')
    H.eq(r2.state, 'left', '(h) the other one never came: the onLeave rule')
    local notes = NotesOf(case, 'rs_combat_log')
    H.eq(#notes, 1, '(h) one note, for the one who never came')
    H.eq(notes[1] and notes[1].label, r2.label, '(h) about him')
    Opp.close(run)
end

-- ============================================================================
--                         (i) DEPARTMENT DUTY MID-CASE
-- ============================================================================

do
    local run, case, rec, src = OneSuspect('DUTY0001')
    Tick(1)
    players[src].PlayerData.job = { name = 'sast', label = 'SAST', onduty = true, grade = { level = 1 } }
    TriggerEvent('QBCore:Server:SetDuty', src, true)
    H.eq(rec.state, 'void', '(i) a suspect on SAST duty mid-case: void')
    H.eq(#NotesOf(case, 'rs_went_on_duty'), 1, '(i) with the rs_went_on_duty note')
    H.eq(#Sent(run, 'opp_void', 'DUTY0001'), 1, '(i) opp_void dispatched')
    Opp.close(run)

    run, case, rec, src = OneSuspect('DUTY0002')
    players[src].PlayerData.job = { name = 'fib', label = 'FIB', onduty = true, grade = { level = 0 } }
    TriggerEvent('QBCore:Server:OnJobUpdate', src, Copy(players[src].PlayerData.job))
    H.eq(rec.state, 'void', '(i) a job change onto FIB duty: void')
    Opp.close(run)

    run, case, rec, src = OneSuspect('DUTY0003')
    players[src].PlayerData.job = { name = 'mechanic', label = 'Mechanic', onduty = true, grade = { level = 0 } }
    TriggerEvent('QBCore:Server:OnJobUpdate', src, Copy(players[src].PlayerData.job))
    H.eq(rec.state, 'free', '(i) a job outside Config.Departments changes nothing')
    Opp.close(run)
end

-- ============================================================================
--                           (j) WHO CAN BE A SUSPECT
-- ============================================================================

do
    Load(70, 'ELIG0070', vec3(1200.0, 0.0, 30.0))
    H.eq(Opp.eligible(70), true, '(j) a loaded civilian in bucket 0 is eligible')
    H.players[70].ace = { ['crimsonpolice.admin'] = true }
    local ok, why = Opp.eligible(70)
    H.ok(ok == false and why == 'admin', '(j) a Crimson-Police admin (Config.AdminAce) is not')
    RS.excludeAdmins = false
    H.eq(Opp.eligible(70), true, '(j) with excludeAdmins = false he is')
    RS.excludeAdmins = true
    H.players[70].ace = { ['crimsonpolice.realsuspect.exclude'] = true }
    ok, why = Opp.eligible(70)
    H.ok(ok == false and why == 'excluded', '(j) the excludeAce ace (a server BOOL native: 1)')
    H.players[70].ace = {}
    bucket[70] = 3
    ok, why = Opp.eligible(70)
    H.ok(ok == false and why == 'instance', '(j) not in an instance')
    bucket[70] = nil
    Move(70, vec3(310.0, -590.0, 43.0))
    ok, why = Opp.eligible(70, { intake = true })
    H.ok(ok == false and why == 'no_start_zone', '(j) intake: not at Pillbox')
    H.eq(Opp.eligible(70), true, '(j) the zones are for the intake only')
    Move(70, vec3(1200.0, 0.0, 30.0))
    players[70].PlayerData.metadata.ishandcuffed = true
    TriggerEvent('qbx_core:server:onSetMetaData', 'ishandcuffed', false, true, 70)
    ok, why = Opp.eligible(70, { intake = true })
    H.ok(ok == false and why == 'cuffed', '(j) intake: not cuffed')
    players[70].PlayerData.metadata.ishandcuffed = false
    TriggerEvent('qbx_core:server:onSetMetaData', 'ishandcuffed', true, false, 70)
    ok, why = Opp.eligible(1)
    H.ok(ok == false and why == 'on_duty', '(j) not on police duty')
    ok, why = Opp.eligible(14)
    H.ok(ok == false and why == 'in_case', '(j) not a suspect of another case')
    H.eq(Opp.eligible(999), false, '(j) a server id with no character')
    -- Opp.lastPoliceAt (V7) is read when it exists
    Opp.lastPoliceAt = function(cid) return cid == 'ELIG0070' and os.time() - 600 or nil end
    ok, why = Opp.eligible(70)
    H.ok(ok == false and why == 'job_hop', '(j) not within jobHopMinutes of police duty')
    Opp.lastPoliceAt = nil

    -- AFK samples of a reported crew before any case (C17), carried into the case
    threads = 0
    H.ok(Opp.sampleCrew('crimson-contracts:7', { 'ELIG0070' }), 'sampleCrew')
    Tick(RS.afkSeconds + RS.afkSampleEvery + 1)
    ok, why = Opp.eligible(70)
    H.ok(ok == false and why == 'afk', '(j) AFK by the crew samples')
    local run = NewRun({ 1, 2 })
    local case = Opp.open(run, { kind = 'live', members = { ELIG0070 = 70 } })
    H.eq(case.suspects.ELIG0070.afk, true, 'the samples carry into the case')
    Opp.close(run)
    Opp.unsampleCrew('crimson-contracts:7')
end

-- ============================================================================
--       (g) NO SUSPECT FACT HOLDS ANY POINTS; THE RUN:ENDED HOOK CLOSES
-- ============================================================================

do
    H.eq(#flags, 0, '(g) no suspect fact ever called CP.AntiCheat.flag')
    local held, anyFlag = 0, false
    for _, run in ipairs(runs) do
        if run.flagged then anyFlag = true end
        for _, p in pairs(run.participants) do
            if p.flagged then anyFlag = true end
            local _, cash = CP.Cash.compute(run, p)
            if cash.status == 'held' then held = held + 1 end
        end
    end
    H.eq(anyFlag, false, '(g) no run.flagged and no p.flagged')
    H.eq(held, 0, '(g) Cash.compute: no row held')
    local noted = 0
    for _, a in ipairs(audits) do if a[4] == 'runNoted' then noted = noted + 1 end end
    H.ok(noted >= 10, ('(g) the facts were notes (%d runNoted)'):format(noted))

    CP.Hooks.fire('run:ended', R1, 'completed', 'completed')
    H.eq(Opp.caseOf(R1), nil, 'run:ended closes the case')
    local outcomes = Opp.close(R1)
    H.eq(outcomes.SUSA0001, 'got_away', 'a second close answers the outcomes: lost = got away')
    H.eq(outcomes.SUSB0002, 'got_away', 'cuffed with no detain = got away')
    H.eq(Opp.bySrc(12), nil, 'a closed case\'s suspect is no longer tracked')
end

-- ============================================================================
--                    (l) THE THREAD ENDS WITH THE LAST CASE
-- ============================================================================

do
    Opp.close(R2)
    H.eq(Opp.active(), false, 'every case closed')
    Tick(2)
    ResetCounts()
    threads = 0
    Tick(10)
    H.eq(N('GetPlayerRoutingBucket') + N('GetPlayerPed') + N('GetEntityCoords'), 0, '(l) the watch ended')
    H.eq(threads, 0, '(l) and nothing started again')
    -- the next case starts exactly one thread again, a second case none
    local a = Opp.open(NewRun({ 1 }), { members = { 'SUSC0003' } })
    local b = Opp.open(NewRun({ 2 }), { members = { 'LAST0001' } })
    H.ok(a ~= nil and b ~= nil, 'two cases')
    H.eq(threads, 2, '(l) one watch thread and the license read of the offline suspect')
    ResetCounts()
    Tick(1)
    H.eq(N('GetPlayerRoutingBucket'), 1, '(l) one pass a second, not two')
    -- onResourceStop clears everything
    H.fire('onResourceStop', nil, 'Crimson-Police')
    H.eq(Opp.active(), false, 'resource stop: no case')
    ResetCounts()
    Tick(3)
    H.eq(N('GetPlayerRoutingBucket'), 0, 'resource stop: the watch ended')
end

return H

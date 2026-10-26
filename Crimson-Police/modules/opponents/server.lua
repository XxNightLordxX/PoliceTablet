-- CP.Opponents (server): the real-player suspects of a case (live crimes, volunteers), keyed by citizenid, and one 1 s
-- watch on event-kept maps that runs only while something is tracked. Everything a suspect does himself is a staff
-- note (CP.AntiCheat.note), never a flag, so a criminal can never hold the officers' points.

CP.Opponents = CP.Opponents or {}
local Opp = CP.Opponents
local TAG = 'opponents'

local TICK_MS = 1000              -- the watch's pass
local STILL_METRES = 1.0          -- an AFK sample that moved less than this...
local STILL_DEGREES = 2.0         -- ...and turned the camera less than this is "still"
local TELEPORT_GAP_MS = 30000     -- at most one rs_teleport note per suspect this often
local CLOSED_KEPT = 16            -- closed cases whose outcomes close() still answers (a second run:ended listener)
local ARENA_BAG = 'crimsonArena'
local LABELS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'

local STATES = { free = true, cuffed = true, detained = true, booked = true, lost = true, left = true, void = true }
local DONE = { lost = true, left = true, void = true }       -- nothing changes them again; the watch skips them
local EVENT_OF = {                                           -- the server-only objective event of each state change
    free = 'opp_released',
    cuffed = 'opp_cuffed',
    detained = 'opp_detained',
    booked = 'opp_booked',
    lost = 'opp_lost',
    left = 'opp_left',
    void = 'opp_void',
}
local OUTCOME_OF = {              -- a suspect's outcome at the close (a later step may have set rec.outcome itself)
    free = 'got_away',
    cuffed = 'got_away',          -- the cuffs never held long enough: no detain
    lost = 'got_away',
    detained = 'detained',
    booked = 'booked',
    left = 'left',
    void = 'void',
}
local MD_KEYS = { 'ishandcuffed', 'isdead', 'inlaststand', 'injail' }

local cases = {}                  -- [runId] = case
local recOf = {}                  -- [citizenid] = { case, rec }: every suspect of an open case
local crewOf = {}                 -- [crewKey] = { [citizenid] = true }: AFK samples before a case exists
local srcOf = {}                  -- [citizenid] = server id, tracked citizenids only (load, unload and drop keep it)
local cidOf = {}                  -- [server id] = citizenid, the same pairs: cleared at the drop (C9)
local afkOf = {}                  -- [citizenid] = { coords, cam, stillSince, nextAt, afk } (GetGameTimer ms)
local closed = {}                 -- { runId, outcomes, case }, the last CLOSED_KEPT
local tickHooks = {}
local watch = { on = false, token = 0 }
local errorAt = {}

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Cfg() return Config.RealSuspects or {} end

local function Num(v, default)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return default end
    return v
end

local function ToSrc(src)
    local n = tonumber(src)
    n = n and math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

local function ValidCid(cid)
    return type(cid) == 'string' and cid ~= '' and #cid <= 50 and cid:match('^[%w_%-]+$') ~= nil
end

local function LogError(key, fmt, ...)
    local now = os.time()
    if errorAt[key] and now - errorAt[key] < 60 then return end
    errorAt[key] = now
    CP.err(TAG, fmt, ...)
end

-- Citizenids from a list ({ 'A1', 'B2' }) or a map ({ [cid] = true }, Crimson-Contracts' { [cid] = src }: the value
-- is never read, C9), sorted, valid and unique.
local function CidsOf(t)
    local out, seen = {}, {}
    if type(t) ~= 'table' then return out end
    for k, v in pairs(t) do
        local cid = nil
        if type(k) == 'string' and v then
            cid = k
        elseif math.type(k) == 'integer' and type(v) == 'string' then
            cid = v
        end
        if ValidCid(cid) and not seen[cid] then
            seen[cid] = true
            out[#out + 1] = cid
        end
    end
    table.sort(out)
    return out
end

-- The active participants of a run (CP.Runs.activeSrcs without the module: run.order and run.participants).
local function ActiveSrcs(run)
    local out = {}
    if type(run) ~= 'table' or type(run.order) ~= 'table' or type(run.participants) ~= 'table' then return out end
    for _, src in ipairs(run.order) do
        local p = run.participants[src]
        if type(p) == 'table' and p.status == 'active' then out[#out + 1] = src end
    end
    return out
end

local function Bucket(src)
    if type(GetPlayerRoutingBucket) ~= 'function' then return 0 end
    local ok, b = pcall(GetPlayerRoutingBucket, src)
    if not ok then return 0 end
    return tonumber(b) or 0
end

local function ServerCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

local function CameraOf(src)
    if type(GetPlayerCameraRotation) ~= 'function' then return nil end
    local ok, rot = pcall(GetPlayerCameraRotation, src)
    if ok then return rot end
    return nil
end

-- The largest turn between two camera rotations, in degrees (pitch and heading, wrapped at 360).
local function Turned(a, b)
    if a == nil or b == nil then return 0 end
    local most = 0
    for _, k in ipairs({ 'x', 'z' }) do
        local d = math.abs((tonumber(a[k]) or 0) - (tonumber(b[k]) or 0)) % 360
        if d > 180 then d = 360 - d end
        if d > most then most = d end
    end
    return most
end

-- The four qbx metadata values the watch keeps for a suspect (the mirror is updated by onSetMetaData only).
local function Mirror(md)
    md = type(md) == 'table' and md or {}
    return {
        ishandcuffed = md.ishandcuffed == true,
        isdead = md.isdead == true,
        inlaststand = md.inlaststand == true,
        injail = math.max(0, math.floor(Num(md.injail, 0))),
    }
end

local function MdValue(key, v)
    if key == 'injail' then return math.max(0, math.floor(Num(v, 0))) end
    return v == true
end

-- A Qbox job in any Config.Departments entry (a turned-off department counts too: it is still police).
local function IsDeptJob(name)
    if type(name) ~= 'string' or not CP.Access then return false end
    local A = CP.Access
    if A.departmentForJob and A.departmentForJob(name) then return true end
    return A.offDepartmentForJob ~= nil and A.offDepartmentForJob(name) ~= nil
end

local function OnDeptDuty(job)
    return type(job) == 'table' and job.onduty == true and IsDeptJob(job.name)
end

-- ============================================================================
--                           TRACKED CITIZENIDS (C9)
-- ============================================================================

local function InCrew(cid)
    for _, set in pairs(crewOf) do
        if set[cid] then return true end
    end
    return false
end

local function Tracked(cid) return recOf[cid] ~= nil or InCrew(cid) end

local function HasWork() return next(cases) ~= nil or next(crewOf) ~= nil end

local function Bind(cid, src)
    local old = srcOf[cid]
    if old and cidOf[old] == cid then cidOf[old] = nil end
    local prior = cidOf[src]
    if prior and prior ~= cid then
        if srcOf[prior] == src then srcOf[prior] = nil end
        local hit = recOf[prior]
        if hit and hit.rec.src == src then hit.rec.src = nil end
    end
    srcOf[cid], cidOf[src] = src, cid
    local hit = recOf[cid]
    if hit then hit.rec.src = src end
end

-- The citizenid src stood for, or nil; src matches nothing afterwards, so whoever gets this server id next is a
-- stranger until his own citizenid loads.
local function Unbind(src)
    local cid = cidOf[src]
    if not cid then return nil end
    cidOf[src] = nil
    if srcOf[cid] == src then srcOf[cid] = nil end
    local hit = recOf[cid]
    if hit and hit.rec.src == src then hit.rec.src = nil end
    return cid
end

local function Untrack(cid)
    if Tracked(cid) then return end
    local src = srcOf[cid]
    srcOf[cid] = nil
    if src and cidOf[src] == cid then cidOf[src] = nil end
    afkOf[cid] = nil
end

-- ============================================================================
--                           TIMELINE, NOTES, EVENTS
-- ============================================================================

local function Timeline(case, entry)
    entry.t = os.time()
    local list = case.timeline
    list[#list + 1] = entry
    local max = math.max(1, math.floor(Num(Cfg().timelineMax, 300)))
    while #list > max do table.remove(list, 1) end
end

-- "contact N s ago" / "no contact" for a note; leaving within evadeWindow of the contact says so.
local function ContactDetail(rec, now, leaving)
    if not rec.lastContactAt then return CP.L('opp.detail.no_contact', { label = rec.label }) end
    local seconds = math.max(0, math.floor((now - rec.lastContactAt) / 1000))
    local window = math.floor(Num(Cfg().evadeWindow, 120))
    if leaving and seconds <= window then
        return CP.L('opp.detail.evade', { label = rec.label, seconds = seconds, window = window })
    end
    return CP.L('opp.detail.contact', { label = rec.label, seconds = seconds })
end

-- A staff note about a case (a suspect's own act): the case timeline, the suspect's notes and CP.AntiCheat.note,
-- which is audited and shown in the Review run detail and never sets run.flagged or p.flagged.
function Opp.note(run, reason, detail, cid)
    if type(run) ~= 'table' or type(reason) ~= 'string' or reason == '' then return false end
    if detail ~= nil then detail = CP.U.clip(tostring(detail), 255) end
    local case = cases[run.id]
    local rec = case and type(cid) == 'string' and case.suspects[cid] or nil
    if case then
        local entry = { t = os.time(), what = reason, label = rec and rec.label or nil, detail = detail }
        case.notes[#case.notes + 1] = entry
        if rec then rec.notes[#rec.notes + 1] = entry end
        Timeline(case,
            { what = reason, label = entry.label, src = rec and rec.src or nil, detail = detail, note = true })
    end
    CP.log(TAG, 'run %s note %s: %s', tostring(run.id), reason, tostring(detail or ''))
    if CP.AntiCheat and CP.AntiCheat.note then
        -- keyed by the suspect: in a crew every suspect's leave or instance reaches the audit, once each
        local ok, err = pcall(CP.AntiCheat.note, run, nil, reason, detail, rec and rec.cid or nil)
        if not ok then LogError('note', 'CP.AntiCheat.note failed: %s', tostring(err)) end
    end
    return true
end

-- A server-only objective event (K1: server:objective refuses every opp_* type from a client). Before In progress
-- the state is only kept: the block reads Opp.view(run) when it starts.
local function Send(case, rec, kind, extra)
    local run = case.run
    if not kind or case.closing or type(run) ~= 'table' or run.state ~= 'in_progress' then return end
    if not (CP.Runs and CP.Runs.dispatch) then return end
    local ev = { type = kind, cid = rec.cid, label = rec.label }
    if extra then for k, v in pairs(extra) do ev[k] = v end end
    local ok, err = pcall(CP.Runs.dispatch, run, case.index, nil, ev)
    if not ok then
        LogError('dispatch', 'dispatch of %s to run %s failed: %s', kind, tostring(run.id), tostring(err))
    end
end

local function SetState(case, rec, state, why, opts)
    local prev = rec.state
    if prev == state or not STATES[state] then return false end
    opts = opts or {}
    local now = GetGameTimer()
    rec.state, rec.since = state, now
    if state == 'detained' then rec.detainedAt = rec.detainedAt or now end
    if state == 'booked' then rec.bookedAt = rec.bookedAt or now end
    if state == 'cuffed' then rec.cuffedAt = now end
    Timeline(case, { what = 'state', label = rec.label, src = rec.src, state = state, prev = prev, why = why })
    CP.log(TAG, 'run %s suspect %s: %s -> %s (%s)', tostring(case.runId), rec.label, prev, state, tostring(why))
    Send(case, rec, opts.event or EVENT_OF[state], { prev = prev, by = opts.by, share = rec.share, why = why })
    return true
end

-- ============================================================================
--                   LEAVING, INSTANCES AND THE onLeave RULE
-- ============================================================================

-- A free suspect who left (logged off past the grace, switched character, entered an instance): Config.RealSuspects.
-- onLeave. 'caught' counts as a detain (by leave; an AFK suspect's share is 0, as for a cuff while AFK).
local function ApplyOnLeave(case, rec, why)
    local mode = Cfg().onLeave
    if mode == 'caught' then
        rec.byLeave = true
        if rec.share == nil then rec.share = rec.afk and 0 or 1 end
        SetState(case, rec, 'detained', why)
    elseif mode == 'escaped' then
        SetState(case, rec, 'lost', why)
    else
        SetState(case, rec, 'left', why)
    end
end

-- The leave is final (character switch at once, a disconnect after the grace): cuffed -> detained (C18), free -> the
-- onLeave rule, detained and booked keep their state (C25). Every leave writes the note, with or without contact.
local function FinishLeave(case, rec, how)
    local now = GetGameTimer()
    rec.dropAt = nil
    if rec.state == 'cuffed' then
        if rec.share == nil then rec.share = rec.afk and 0 or 1 end
        SetState(case, rec, 'detained', 'left_in_cuffs')
    elseif rec.state == 'free' then
        ApplyOnLeave(case, rec, how)
    end
    local detail = ContactDetail(rec, rec.leftAt or now, true)
    if rec.offlineAtOpen then detail = CP.L('opp.detail.offline_at_open', { label = rec.label }) end
    rec.offlineAtOpen = nil
    Opp.note(case.run, 'rs_combat_log', detail, rec.cid)
end

-- A disconnect ('drop') or a logout / character switch ('unload') of a tracked server id.
local function OnLeft(src, how)
    local cid = Unbind(src)
    if not cid then return end
    afkOf[cid] = nil
    local hit = recOf[cid]
    if not hit then return end
    local case, rec = hit.case, hit.rec
    if DONE[rec.state] then return end
    local now = GetGameTimer()
    rec.leftAt = now
    rec.leftInCustody = rec.state == 'cuffed' or rec.state == 'detained'
    rec.lastCoords, rec.inInstance = nil, nil
    Timeline(case, { what = how == 'unload' and 'unloaded' or 'dropped', label = rec.label, src = src })
    if how == 'unload' or rec.state == 'cuffed' then
        FinishLeave(case, rec, how)
    else
        rec.dropAt = now
    end
end

-- A routing bucket other than 0 (an apartment, another instance, Crimson-Arena) is leaving the server (critic 2 #14).
local function EnterInstance(case, rec, now)
    Timeline(case, { what = 'instance', label = rec.label, src = rec.src })
    if rec.state == 'cuffed' then
        if rec.share == nil then rec.share = rec.afk and 0 or 1 end
        SetState(case, rec, 'detained', 'instance_in_cuffs')
    elseif rec.state == 'free' then
        ApplyOnLeave(case, rec, 'instance')
    end
    Opp.note(case.run, 'rs_evade_instance', ContactDetail(rec, now, false), rec.cid)
end

-- Another script's crimsonArena flag in bucket 0 (C8): a note once, and he stays tracked (only a bucket voids).
local function CheckArenaFlag(src)
    local cid = cidOf[src]
    local hit = cid and recOf[cid]
    if not hit then return end
    local case, rec = hit.case, hit.rec
    if DONE[rec.state] or rec.fakeArenaNoted or Bucket(src) ~= 0 then return end
    if not (CP.Alerts and CP.Alerts.foreignFlag) then return end
    local ok, foreign = pcall(CP.Alerts.foreignFlag, src)
    if not ok or not foreign then return end
    rec.fakeArenaNoted = true
    Opp.note(case.run, 'rs_fake_arena_flag', CP.L('opp.detail.fake_arena', { label = rec.label }), cid)
end

local function WentOnDuty(case, rec, jobName)
    if DONE[rec.state] then return end
    if rec.state == 'free' or rec.state == 'cuffed' then SetState(case, rec, 'void', 'on_duty') end
    Opp.note(case.run, 'rs_went_on_duty', CP.L('opp.detail.on_duty', { label = rec.label, job = tostring(jobName) }),
        rec.cid)
end

-- ============================================================================
--                                 AFK SAMPLES
-- ============================================================================

-- One sample every afkSampleEvery s (coords + camera): still = moved under 1 m and turned under 2 degrees since the
-- stillness began; AFK after afkSeconds of it. Between samples the last answer is returned and nothing is read.
local function Sample(cid, src, coords, now)
    local cfg = Cfg()
    local s = afkOf[cid]
    if s and now < s.nextAt then return s.afk end
    local every = math.max(1, Num(cfg.afkSampleEvery, 15)) * 1000
    local cam = CameraOf(src)
    if not s then
        afkOf[cid] = { coords = coords, cam = cam, stillSince = now, nextAt = now + every, afk = false }
        return false
    end
    s.nextAt = now + every
    if CP.U.dist(coords, s.coords) < STILL_METRES and Turned(cam, s.cam) < STILL_DEGREES then
        s.afk = now - s.stillSince >= math.max(0, Num(cfg.afkSeconds, 300)) * 1000
    else
        s.coords, s.cam, s.stillSince, s.afk = coords, cam, now, false
    end
    return s.afk
end

-- ============================================================================
--                                  THE WATCH
-- ============================================================================

local function Trail(case, rec, coords)
    local trail = Cfg().trail or {}
    local max = math.max(1, math.floor(Num(trail.max, 360)))
    local ring = case.trail[rec.cid]
    if not ring then
        ring = { n = 0, pts = {} }
        case.trail[rec.cid] = ring
    end
    ring.n = ring.n + 1
    ring.pts[((ring.n - 1) % max) + 1] = { t = os.time(), x = coords.x, y = coords.y, z = coords.z }
    for i = max + 1, #ring.pts do
        ring.pts[i] = nil
    end -- trail.max lowered in game
end

local function Nearest(parts, coords)
    local best = math.huge
    for i = 1, #parts do
        local d = CP.U.dist(parts[i], coords)
        if d < best then best = d end
    end
    return best
end

-- One suspect with a server id: only GetPlayerRoutingBucket, GetPlayerPed and GetEntityCoords (and the camera on an
-- AFK sample); his cuffs, downs and jail come from the metadata mirror, his citizenid from the event-kept maps.
local function TickSuspect(case, rec, parts, now, cfg)
    local src = rec.src
    if Bucket(src) ~= 0 then
        if not rec.inInstance then
            rec.inInstance = true
            EnterInstance(case, rec, now)
        end
        return
    end
    local coords = ServerCoords(src)
    if not coords then return end
    if rec.inInstance then
        rec.inInstance, rec.lastCoords = nil, nil
        CheckArenaFlag(src)
        if DONE[rec.state] then return end
    end
    if rec.lastCoords and rec.lastAt and now > rec.lastAt then
        local metres = CP.U.dist(coords, rec.lastCoords)
        local seconds = (now - rec.lastAt) / 1000
        local maxSpeed = Num(Config.AntiCheat and Config.AntiCheat.maxSpeed, 80.0)
        if metres / seconds > maxSpeed and (not rec.teleportAt or now - rec.teleportAt >= TELEPORT_GAP_MS) then
            rec.teleportAt = now
            Opp.note(case.run, 'rs_teleport', CP.L('opp.detail.teleport', {
                label = rec.label,
                metres = math.floor(metres + 0.5),
                seconds = ('%.1f'):format(seconds),
            }), rec.cid)
        end
    end
    rec.lastCoords, rec.lastAt = coords, now
    local nearest = Nearest(parts, coords)
    if nearest <= Num(cfg.contactRange, 100.0) then
        rec.lastContactAt = now
        if not rec.contactAt then
            rec.contactAt = now
            Timeline(case, { what = 'contact', label = rec.label, src = src })
            Send(case, rec, 'opp_contact')
            if cases[case.runId] ~= case then return end
        end
    end
    local rule = case.lostRule
    if rule and rec.state == 'free' and (rec.contactAt or case.crimeEndedAt) then
        if nearest <= rule.range then
            rec.farSince = nil
        else
            rec.farSince = rec.farSince or now
            if now - rec.farSince >= rule.seconds * 1000 then
                SetState(case, rec, 'lost', 'no_officer_near')
                return
            end
        end
    end
    local trail = cfg.trail or {}
    if now >= (rec.trailAt or 0) then
        rec.trailAt = now + math.max(1, Num(trail.every, 5)) * 1000
        Trail(case, rec, coords)
    end
    if rec.state == 'free' and not rec.down then
        if rec.afkPaused then
            rec.afkPaused, afkOf[rec.cid] = nil, nil
        end
        rec.afk = Sample(rec.cid, src, coords, now)
    else
        -- cuffed, detained or booked: sitting still in a cruiser is not AFK (C17); nor is lying down (rec.down, kept
        -- by the proof step) waiting for EMS or the respawn timer. rec.afk keeps its value
        rec.afkPaused = true
    end
end

local function TickCase(case, now)
    local run = case.run
    if type(run) ~= 'table' or run.state == 'ended' then return end
    local cfg = Cfg()
    local parts = {}
    for _, src in ipairs(ActiveSrcs(run)) do
        local c = ServerCoords(src)
        if c then parts[#parts + 1] = c end
    end
    local grace = math.max(0, Num(cfg.disconnectGrace, 120)) * 1000
    for _, cid in ipairs(case.order) do
        if cases[case.runId] ~= case then
            return
        end -- a block that got an event ended the run
        local rec = case.suspects[cid]
        if not DONE[rec.state] then
            if rec.src then
                TickSuspect(case, rec, parts, now, cfg)
            elseif rec.dropAt and now - rec.dropAt >= grace then
                FinishLeave(case, rec, rec.offlineAtOpen and 'offline' or 'drop')
            end
        end
    end
    for i = 1, #tickHooks do
        if cases[case.runId] ~= case then return end
        local ok, err = pcall(tickHooks[i], case, now)
        if not ok then LogError('tickHook', 'a tick listener failed: %s', tostring(err)) end
    end
end

-- Reported crews and volunteers with no case yet: coords and camera only on their AFK sample ticks.
local function TickCrews(now)
    for _, set in pairs(crewOf) do
        for cid in pairs(set) do
            local src = not recOf[cid] and srcOf[cid] or nil
            local s = src and afkOf[cid]
            if src and (not s or now >= s.nextAt) then
                local coords = ServerCoords(src)
                if coords then Sample(cid, src, coords, now) end
            end
        end
    end
end

local function Tick()
    local now = GetGameTimer()
    local list = {}
    for _, case in pairs(cases) do list[#list + 1] = case end
    for i = 1, #list do
        if cases[list[i].runId] == list[i] then
            local ok, err = pcall(TickCase, list[i], now)
            if not ok then LogError('tick', 'watch of run %s failed: %s', tostring(list[i].runId), tostring(err)) end
        end
    end
    if next(crewOf) then
        local ok, err = pcall(TickCrews, now)
        if not ok then LogError('crews', 'crew samples failed: %s', tostring(err)) end
    end
end

-- One thread, started by the first case or crew and ended when nothing is tracked; the token keeps it single.
local function StartWatch()
    if watch.on then return end
    watch.on = true
    watch.token = watch.token + 1
    local token = watch.token
    CreateThread(function()
        while true do
            Wait(TICK_MS)
            if token ~= watch.token or not HasWork() then break end
            Tick()
        end
        if token == watch.token then watch.on = false end
    end)
end

-- ============================================================================
--                                    CASES
-- ============================================================================

local function Labels(n, seed)
    local rng = CP.U.rng(seed or 1)
    local out = {}
    for i = 1, n do out[i] = i <= #LABELS and LABELS:sub(i, i) or ('S%d'):format(i) end
    for i = n, 2, -1 do
        local j = rng:int(1, i)
        out[i], out[j] = out[j], out[i]
    end
    return out
end

local function LostRule(rule)
    if type(rule) ~= 'table' then return nil end
    local range, seconds = Num(rule.range, 0), Num(rule.seconds, 0)
    if range <= 0 or seconds <= 0 then return nil end
    return { range = range, seconds = seconds }
end

local function NewRec(cid, label, now)
    return {
        cid = cid,
        label = label,
        state = 'free',
        since = now,
        md = Mirror(nil),
        down = false,
        caughtBy = {},
        everArmed = false,
        afk = false,
        near = {},
        byLeave = false,
        notes = {},
    }
end

-- spec = { kind = 'live'|'volunteer', index, members = { [cid] = true } (or a list), scene, lostRule = { range,
-- seconds }, meet }. Every src is resolved from the citizenid now (an event path); a suspect who is offline starts in
-- the disconnect-grace path (critic 2 #19). A citizenid that is a suspect of another case is left out.
function Opp.open(run, spec)
    if type(run) ~= 'table' or type(run.id) ~= 'string' then return nil end
    if cases[run.id] then return cases[run.id] end
    spec = type(spec) == 'table' and spec or {}
    local cids = {}
    for _, cid in ipairs(CidsOf(spec.members)) do
        if recOf[cid] then
            CP.warn(TAG, 'run %s: %s is a suspect of run %s already and is left out', run.id, cid,
                recOf[cid].case.runId)
        else
            cids[#cids + 1] = cid
        end
    end
    if #cids == 0 then return nil end
    local now = GetGameTimer()
    local case = {
        runId = run.id,
        run = run,
        kind = spec.kind == 'volunteer' and 'volunteer' or 'live',
        index = math.tointeger(tonumber(spec.index) or 1) or 1,
        openedAt = os.time(),
        scene = spec.scene,
        lostRule = LostRule(spec.lostRule),
        meet = type(spec.meet) == 'table' and spec.meet or nil,
        suspects = {},
        order = cids,
        timeline = {},
        ledger = {},
        trail = {},
        notes = {},
    }
    local labels = Labels(#cids, run.seed)
    cases[run.id] = case
    for i, cid in ipairs(cids) do
        local rec = NewRec(cid, labels[i], now)
        case.suspects[cid] = rec
        recOf[cid] = { case = case, rec = rec }
    end
    local offline = {}
    for _, cid in ipairs(cids) do
        local rec = case.suspects[cid]
        local src = CP.Qbx and CP.Qbx.getByCitizenId and CP.Qbx.getByCitizenId(cid) or nil
        local info = src and CP.Qbx.getInfo(src) or nil
        if info and info.citizenid == cid then
            Bind(cid, src)
            rec.license = info.license
            rec.md = Mirror(info.metadata)
            rec.afk = afkOf[cid] ~= nil and afkOf[cid].afk == true
            Timeline(case, { what = 'suspect', label = rec.label, src = src })
        else
            rec.dropAt, rec.leftAt, rec.offlineAtOpen = now, now, true
            offline[#offline + 1] = cid
            Timeline(case, { what = 'offline_at_open', label = rec.label })
        end
    end
    CP.log(TAG, 'run %s: %s case opened with %d suspect(s), %d offline', run.id, case.kind, #cids, #offline)
    for _, cid in ipairs(cids) do
        local src = case.suspects[cid].src
        if src then CheckArenaFlag(src) end
    end
    if #offline > 0 and CP.Qbx and CP.Qbx.licenseOf then
        CreateThread(function()
            for _, cid in ipairs(offline) do
                local ok, lic = pcall(CP.Qbx.licenseOf, cid)
                local rec = case.suspects[cid]
                if ok and lic and rec.license == nil then rec.license = lic end
            end
        end)
    end
    StartWatch()
    return case
end

-- { [cid] = outcome } ('detained', 'booked', 'got_away', 'left', 'void', or what a later step set), and the case.
-- Called by the run:ended hook below; a second call for the same run answers the same outcomes.
function Opp.close(run)
    local runId = type(run) == 'table' and run.id or run
    if type(runId) ~= 'string' then return {} end
    local case = cases[runId]
    local function copy(t)
        local out = {}
        for k, v in pairs(t) do out[k] = v end
        return out
    end
    if not case then
        for _, c in ipairs(closed) do
            if c.runId == runId then return copy(c.outcomes), c.case end
        end
        return {}
    end
    -- A leave still waiting for its grace (a drop, or offline since the open) is final now: the onLeave rule (or
    -- cuffed -> detained) and the rs_combat_log note come before the outcome, so a suspect who logged off just before
    -- the case ended never reads as 'got_away' by the leave. No event goes out while closing.
    case.closing = true
    -- Opp.onClose (V5's proof): a cuff release still waiting for its explanation is decided first
    if type(Opp.onClose) == 'function' then
        local ok, err = pcall(Opp.onClose, case)
        if not ok then LogError('onClose', 'CP.Opponents.onClose failed: %s', tostring(err)) end
    end
    for _, cid in ipairs(case.order) do
        local rec = case.suspects[cid]
        if rec.src == nil and rec.dropAt and not DONE[rec.state] then
            FinishLeave(case, rec, rec.offlineAtOpen and 'offline' or 'drop')
        end
    end
    cases[runId] = nil
    local outcomes = {}
    for _, cid in ipairs(case.order) do
        local rec = case.suspects[cid]
        rec.outcome = rec.outcome or OUTCOME_OF[rec.state] or 'got_away'
        outcomes[cid] = rec.outcome
        if recOf[cid] and recOf[cid].case == case then recOf[cid] = nil end
        Untrack(cid)
    end
    case.closedAt = os.time()
    Timeline(case, { what = 'closed' })
    closed[#closed + 1] = { runId = runId, outcomes = outcomes, case = case }
    while #closed > CLOSED_KEPT do table.remove(closed, 1) end
    CP.log(TAG, 'run %s: case closed', runId)
    return copy(outcomes), case
end

-- true while at least one case is open (CP.ScPolice / CP.Ambulance pass facts only then).
function Opp.active() return next(cases) ~= nil end

function Opp.caseOf(run)
    local runId = type(run) == 'table' and run.id or run
    if type(runId) ~= 'string' then return nil end
    return cases[runId]
end

function Opp.bySrc(src)
    local n = ToSrc(src)
    local cid = n and cidOf[n]
    local hit = cid and recOf[cid]
    if not hit then return nil end
    return hit.case, hit.rec
end

function Opp.byCid(cid)
    local hit = type(cid) == 'string' and recOf[cid] or nil
    if not hit then return nil end
    return hit.case, hit.rec
end

-- A copy of the case for blocks (never a server id: blocks must not tell officers who a suspect is).
function Opp.view(run)
    local case = Opp.caseOf(run)
    if not case then return nil end
    local out = {
        runId = case.runId,
        kind = case.kind,
        index = case.index,
        openedAt = case.openedAt,
        scene = case.scene,
        crimeEnded = case.crimeEndedAt ~= nil,
        order = {},
        suspects = {},
    }
    for i, cid in ipairs(case.order) do
        local r = case.suspects[cid]
        out.order[i] = cid
        out.suspects[cid] = {
            cid = cid,
            label = r.label,
            state = r.state,
            online = r.src ~= nil,
            contact = r.contactAt ~= nil,
            contactAt = r.contactAt,
            lastContactAt = r.lastContactAt,
            down = r.down,
            afk = r.afk,
            share = r.share,
            byLeave = r.byLeave,
            everArmed = r.everArmed,
            outcome = r.outcome,
            md = Mirror(r.md),
        }
    end
    return out
end

-- Whether a suspect who is still free or cuffed was within range of coords at the last watch pass (no native read).
function Opp.nearAny(run, coords, range)
    local case = Opp.caseOf(run)
    if not case or coords == nil then return false end
    range = Num(range, Num(Cfg().contactRange, 100.0))
    for _, cid in ipairs(case.order) do
        local r = case.suspects[cid]
        if r.src and r.lastCoords and not r.inInstance and (r.state == 'free' or r.state == 'cuffed') then
            local d = CP.U.dist(coords, r.lastCoords)
            if d <= range then return true, cid, d end
        end
    end
    return false
end

-- The crime is over (Crimson-Contracts ended the contract): the lost rule now runs without a contact.
function Opp.crimeEnded(run)
    local case = Opp.caseOf(run)
    if not case then return false end
    if not case.crimeEndedAt then
        case.crimeEndedAt = GetGameTimer()
        Timeline(case, { what = 'crime_ended' })
    end
    return true
end

function Opp.noteArmed(cid)
    local _, rec = Opp.byCid(cid)
    if not rec then return false end
    rec.everArmed = true
    return true
end

-- A state change by a later step (proof, V5): the timeline and the server-only event. opts = { event, why, by }.
function Opp.setState(run, cid, state, opts)
    local case = Opp.caseOf(run)
    local rec = case and type(cid) == 'string' and case.suspects[cid] or nil
    if not rec then return false end
    opts = type(opts) == 'table' and opts or {}
    return SetState(case, rec, state, opts.why, opts)
end

-- A server-only objective event about a suspect that is not a state change (opp_down, opp_up, opp_cuff_attempt):
-- sent only while the run is In progress, like every state event.
function Opp.send(run, cid, kind, extra)
    local case = Opp.caseOf(run)
    local rec = case and type(cid) == 'string' and case.suspects[cid] or nil
    if not rec or type(kind) ~= 'string' then return false end
    Send(case, rec, kind, type(extra) == 'table' and extra or nil)
    return true
end

-- A line in the case timeline (staff only): entry = { what, label, src, ... }; `t` is set here.
function Opp.timeline(run, entry)
    local case = Opp.caseOf(run)
    if not case or type(entry) ~= 'table' or type(entry.what) ~= 'string' then return false end
    Timeline(case, entry)
    return true
end

-- fn(case, now) once per open case on every watch pass, after the suspects (proof and conduct steps).
function Opp.onTick(fn)
    if type(fn) ~= 'function' then return false end
    tickHooks[#tickHooks + 1] = fn
    return true
end

-- A suspect's trail, oldest point first: { { t, x, y, z } }.
function Opp.trailOf(run, cid)
    local case = Opp.caseOf(run)
    local ring = case and case.trail[cid]
    if not ring then return {} end
    local out, n = {}, #ring.pts
    local start = ring.n > n and ((ring.n % n) + 1) or 1
    for i = 0, n - 1 do out[#out + 1] = ring.pts[((start - 1 + i) % n) + 1] end
    return out
end

-- ============================================================================
--                           CREWS (AFK SAMPLES ONLY)
-- ============================================================================

-- AFK samples for citizenids that may become suspects (a crew whose contract started, a volunteer), before a case
-- exists (C17). The same key again adds to its list.
function Opp.sampleCrew(key, cids)
    if (type(key) ~= 'string' and type(key) ~= 'number') or key == '' then return false end
    local list = CidsOf(cids)
    if #list == 0 then return false end
    local set = crewOf[key] or {}
    crewOf[key] = set
    for _, cid in ipairs(list) do
        set[cid] = true
        if not srcOf[cid] and CP.Qbx and CP.Qbx.getByCitizenId then
            local src = CP.Qbx.getByCitizenId(cid)
            if src then Bind(cid, src) end
        end
    end
    StartWatch()
    return true
end

-- Stops the samples of those citizenids under key (all of them with cids nil).
function Opp.unsampleCrew(key, cids)
    local set = crewOf[key]
    if not set then return false end
    local list = cids == nil and CidsOf(set) or CidsOf(cids)
    for _, cid in ipairs(list) do set[cid] = nil end
    if next(set) == nil then crewOf[key] = nil end
    for _, cid in ipairs(list) do Untrack(cid) end
    return true
end

-- ============================================================================
--                                 ELIGIBILITY
-- ============================================================================

-- Whether src may become a suspect -> ok, reason. On events and claims only, never per tick. opts.intake: also not in
-- Config.RealSuspects.noStartZones and not down, cuffed or in jail. Reasons, in this order: not_loaded, in_case,
-- instance, arena_flag, on_duty, job_hop, afk, no_position, no_start_zone, down, cuffed, jailed, excluded, admin.
function Opp.eligible(src, opts)
    local n = ToSrc(src)
    opts = type(opts) == 'table' and opts or {}
    local info = n and CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(n) or nil
    if not info or not ValidCid(info.citizenid) then return false, 'not_loaded' end
    local cid = info.citizenid
    local cfg = Cfg()
    if recOf[cid] then return false, 'in_case' end
    if Bucket(n) ~= 0 then return false, 'instance' end
    if CP.Alerts and CP.Alerts.foreignFlag and CP.Alerts.foreignFlag(n) then return false, 'arena_flag' end
    if OnDeptDuty(info.job) then return false, 'on_duty' end
    -- Opp.lastPoliceAt (V7): os.time() of his last police duty, nil until that step
    local last = Opp.lastPoliceAt
    local at = type(last) == 'function' and last(cid) or (type(last) == 'table' and last[cid]) or nil
    if tonumber(at) and os.time() - tonumber(at) < Num(cfg.jobHopMinutes, 30) * 60 then return false, 'job_hop' end
    if afkOf[cid] and afkOf[cid].afk then return false, 'afk' end
    if opts.intake then
        local coords = ServerCoords(n)
        if not coords then return false, 'no_position' end
        for _, z in ipairs(type(cfg.noStartZones) == 'table' and cfg.noStartZones or {}) do
            if type(z) == 'table' and z.coords and CP.U.dist(coords, z.coords) <= Num(z.radius, 0) then
                return false, 'no_start_zone'
            end
        end
        local md = Mirror(info.metadata)
        if md.isdead or md.inlaststand then return false, 'down' end
        if md.ishandcuffed then return false, 'cuffed' end
        if md.injail > 0 then return false, 'jailed' end
    end
    -- a server BOOL native answers 1 or false: truthiness, never == true
    if type(cfg.excludeAce) == 'string' and cfg.excludeAce ~= '' and IsPlayerAceAllowed(n, cfg.excludeAce) then
        return false, 'excluded'
    end
    if cfg.excludeAdmins ~= false and CP.Access and CP.Access.isAdmin and CP.Access.isAdmin(n) then
        return false, 'admin'
    end
    return true
end

-- ============================================================================
--                               EVENT-KEPT MAPS
-- ============================================================================

-- A character loaded: a tracked citizenid gets his server id back (a rejoin), anyone else matches nothing (C9).
local function OnLoaded(src)
    src = ToSrc(src)
    if not src or not HasWork() then return end
    local info = CP.Qbx.getInfo(src)
    local cid = info and info.citizenid
    if not ValidCid(cid) or not Tracked(cid) then
        if cidOf[src] then Unbind(src) end
        return
    end
    Bind(cid, src)
    afkOf[cid] = nil
    local hit = recOf[cid]
    if not hit then return end
    local case, rec = hit.case, hit.rec
    rec.license = info.license or rec.license
    rec.md = Mirror(info.metadata)
    rec.lastCoords, rec.inInstance = nil, nil
    if DONE[rec.state] then return end
    local now = GetGameTimer()
    local away = rec.leftAt and math.floor((now - rec.leftAt) / 1000) or nil
    rec.dropAt, rec.offlineAtOpen = nil, nil
    Timeline(case, { what = 'rejoined', label = rec.label, src = src, seconds = away })
    local notice = Num(Cfg().reconnectNoticeMinutes, 30) * 60000
    if rec.leftInCustody and rec.leftAt and now - rec.leftAt <= notice and CP.Tablet and CP.Tablet.notifyMany then
        CP.Tablet.notifyMany(ActiveSrcs(case.run), 'info', 'opp.back_in_city')
    end
    rec.leftInCustody = nil
    if OnDeptDuty(info.job) then WentOnDuty(case, rec, info.job.name) end
    CheckArenaFlag(src)
end

local function OnMeta(src, key, old, new)
    if old == new then return end
    local cid = cidOf[src]
    local hit = cid and recOf[cid]
    if not hit then return end
    hit.rec.md[key] = MdValue(key, new)
    if type(Opp.onMeta) == 'function' then
        local ok, err = pcall(Opp.onMeta, hit.rec, key, old, new, hit.case)
        if not ok then LogError('onMeta', 'CP.Opponents.onMeta failed: %s', tostring(err)) end
    end
end

-- Department duty mid-case (critic 2 #19): void from free or cuffed, and a note.
local function OnDuty(src, job)
    local cid = cidOf[src]
    local hit = cid and recOf[cid]
    if not hit or DONE[hit.rec.state] then return end
    if job == nil then
        local info = CP.Qbx.getInfo(src)
        job = info and info.job
    end
    if OnDeptDuty(job) then WentOnDuty(hit.case, hit.rec, job.name) end
end

AddEventHandler('playerDropped', function()
    local src = source
    src = ToSrc(src)
    if not src or not cidOf[src] then return end
    OnLeft(src, 'drop')
end)

-- The handler runs before the value is set: read it on the next tick.
if type(AddStateBagChangeHandler) == 'function' then
    AddStateBagChangeHandler(ARENA_BAG, nil, function(bagName)
        if next(cidOf) == nil then return end
        local ok, src = pcall(GetPlayerFromStateBagName, bagName)
        src = ok and ToSrc(src) or nil
        if not src or not cidOf[src] then return end
        SetTimeout(0, function() CheckArenaFlag(src) end)
    end)
end

CP.Hooks.on('run:ended', function(run)
    if type(run) == 'table' and cases[run.id] then Opp.close(run) end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    cases, recOf, crewOf, srcOf, cidOf, afkOf, closed = {}, {}, {}, {}, {}, {}, {}
    watch.token = watch.token + 1
    watch.on = false
end)

CreateThread(function()
    Wait(0)
    local Q = CP.Qbx
    if not (Q and Q.onPlayerLoaded and Q.onMetaDataChange) then
        CP.err(TAG, 'modules/integrations/qbx is missing: real suspects cannot be followed')
        return
    end
    Q.onPlayerLoaded(OnLoaded)
    Q.onPlayerUnload(function(src)
        src = ToSrc(src)
        if src and cidOf[src] then OnLeft(src, 'unload') end
    end)
    Q.onMetaDataChange(function(src, key, old, new)
        src = ToSrc(src)
        if src and cidOf[src] then OnMeta(src, key, old, new) end
    end, MD_KEYS)
    Q.onDutyChange(function(src, onDuty)
        src = ToSrc(src)
        if src and onDuty and cidOf[src] then OnDuty(src, nil) end
    end)
    Q.onJobChange(function(src, job)
        src = ToSrc(src)
        if src and cidOf[src] then OnDuty(src, job) end
    end)
end)

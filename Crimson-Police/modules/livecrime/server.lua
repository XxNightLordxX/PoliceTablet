-- CP.LiveCrime (server): live crimes (option A, Config.LiveCrime). The intake keeps a record of each crime a script
-- in Config.LiveCrime.sources reports (memory only) and decides its suspects when its police alert goes out; the
-- LIVE call itself is LiveCrime.post. Its events arrive through modules/integrations/crimson_contracts.

CP.LiveCrime = CP.LiveCrime or {}
local LC = CP.LiveCrime
local TAG = 'livecrime'

local KEEP_ENDED = 3600           -- seconds a crime's record is kept after it ended
local KEEP_OPEN = 7200            -- seconds a crime that never reported its end is kept (a contract lasts 30 min)
local MAX_CRIMES = 200            -- records kept at once; a new crime past this is refused with a warning
local WARN_EVERY = 60             -- seconds between two warnings about the same thing

local crimes = {}                 -- [resource .. ':' .. uid] = crime
local count = 0
local warnedAt = {}

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Cfg() return type(Config.LiveCrime) == 'table' and Config.LiveCrime or {} end

local function Num(v, default)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return default end
    return v
end

local function WarnOnce(what, fmt, ...)
    local now = os.time()
    if warnedAt[what] and now - warnedAt[what] < WARN_EVERY then return end
    warnedAt[what] = now
    CP.warn(TAG, fmt, ...)
end

-- The keys of a set, sorted (the same order every time).
local function Sorted(set)
    local out = {}
    for k in pairs(set or {}) do out[#out + 1] = k end
    table.sort(out)
    return out
end

-- CP.Opponents' function, called inside pcall: its answers, or nil after an error (logged once a minute).
local function Opp(name, ...)
    local O = CP.Opponents
    local fn = O and O[name]
    if type(fn) ~= 'function' then return nil end
    local res = table.pack(pcall(fn, ...))
    if not res[1] then
        WarnOnce('opp:' .. name, 'CP.Opponents.%s failed: %s', name, tostring(res[2]))
        return nil
    end
    return table.unpack(res, 2, res.n)
end

-- The mission type a crime uses (Config.LiveCrime.types, read now), or nil while that crime is off.
local function MissionTypeOf(key)
    local types = Cfg().types
    local v = type(types) == 'table' and types[key] or nil
    if type(v) ~= 'string' then return nil end
    if type(Config.MissionTypes) ~= 'table' or type(Config.MissionTypes[v]) ~= 'table' then
        WarnOnce('type:' .. tostring(key),
            'Config.LiveCrime.types.%s = \'%s\' is not in Config.MissionTypes: that ' .. 'crime is never a LIVE call',
            tostring(key), v)
        return nil
    end
    return v
end

-- The open run of this crime's case (V14 sets crime.runId when a unit claims it), or nil.
local function RunOf(crime)
    local run = crime.runId and CP.Runs and CP.Runs.get and CP.Runs.get(crime.runId) or nil
    if type(run) ~= 'table' or run.state == 'ended' then return nil end
    if type(run.live) ~= 'table' or run.live.crimeKey ~= crime.crimeKey then return nil end
    return run
end

-- Stops the AFK samples of those crew members (all of them with cids nil).
local function Unsample(crime, cids)
    if crime.sampled then Opp('unsampleCrew', crime.crimeKey, cids) end
end

local function ServerCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

-- "offline 1, too far from the crime 2": why crew members were left out, for the audit line.
local function WhyText(why)
    local parts = {}
    for _, reason in ipairs(Sorted(why)) do
        local key = 'livecrime.why.' .. reason
        local text = CP.Locale and CP.Locale.has and CP.Locale.has(key) and CP.L(key) or reason
        parts[#parts + 1] = ('%s %d'):format(text, why[reason])
    end
    return table.concat(parts, ', ')
end

local function Params(crime, extra)
    local p = {
        label = crime.label,
        key = crime.key,
        place = crime.locationLabel,
        street = crime.street or '-',
        crew = CP.U.count(crime.members),
    }
    for k, v in pairs(extra or {}) do p[k] = v end
    return p
end

-- One line in Admin UI → Audit (category audit), written in its own thread (the row is a storage write).
local function Audit(action, crime, value, reason)
    local A = CP.Admin
    if not (A and A.audit) then return end
    local target, key = crime.crimeKey, crime.key
    CreateThread(function()
        local ok, err = pcall(A.audit, 'console', 'console', 'audit', action, target, key, value, reason)
        if not ok then WarnOnce('audit', 'the %s audit line failed: %s', action, tostring(err)) end
    end)
end

-- The crime's LIVE call lapses if nobody has it yet (step V11).
local function EndCall(crime)
    local M = CP.MissionCalls
    if not (crime.callId and M and M.endLive) then return end
    local ok, err = pcall(M.endLive, crime.crimeKey)
    if not ok then WarnOnce('endLive', 'the LIVE call of %s could not lapse: %s', crime.crimeKey, tostring(err)) end
end

-- Ended records an hour after the end, and records that never got an end after KEEP_OPEN.
local function Prune(now)
    for k, crime in pairs(crimes) do
        local old
        if crime.ended then
            old = now - (crime.endedAt or now) > KEEP_ENDED
        else
            old = now - crime.receivedAt > KEEP_OPEN
        end
        if old then
            if not crime.ended then Unsample(crime) end
            crimes[k] = nil
            count = count - 1
        end
    end
end

local function Find(res, data) return crimes[res .. ':' .. data.uid] end

-- ============================================================================
--                       SUSPECTS (decided at the alert)
-- ============================================================================

-- { [citizenid] = true } of the crew members who may be suspects now, and { [reason] = count } of the others. Each
-- one is found by his citizenid (an event path, so the qbx export is allowed here; C9), must pass
-- CP.Opponents.eligible with intake = true and stand within Config.LiveCrime.suspectRadius of the crime (C24).
local function Suspects(crime)
    local radius = Num(Cfg().suspectRadius, 300.0)
    local suspects, why = {}, {}
    for _, cid in ipairs(Sorted(crime.members)) do
        local Q = CP.Qbx
        local src = Q and Q.getByCitizenId and Q.getByCitizenId(cid) or nil
        local info = src and Q.getInfo(src) or nil
        local ok, reason = false, nil
        if not src then
            reason = 'offline'
        elseif not info or info.citizenid ~= cid then
            reason = 'not_loaded'
        else
            ok, reason = Opp('eligible', src, { intake = true })
            if ok then
                local at = ServerCoords(src)
                if not at or CP.U.dist(at, crime.coords) > radius then ok, reason = false, 'too_far' end
            end
        end
        if ok then
            suspects[cid] = true
        else
            reason = reason or 'not_eligible'
            why[reason] = (why[reason] or 0) + 1
        end
    end
    return suspects, why
end

-- ============================================================================
--                       INTAKE (the adapter calls these)
-- ============================================================================
-- res is the reporting resource, data a payload the adapter checked. Each answers true, or false and why.

function LC.onStarted(res, data)
    local now = os.time()
    Prune(now)
    local crimeKey = res .. ':' .. data.uid
    if crimes[crimeKey] then return false, 'known' end
    if count >= MAX_CRIMES then
        WarnOnce('full', 'more than %d crimes reported at once: %s is not kept', MAX_CRIMES, crimeKey)
        return false, 'full'
    end
    local crime = {
        crimeKey = crimeKey,
        res = res,
        uid = data.uid,
        id = data.id,
        key = data.key,
        label = data.label,
        locationLabel = data.locationLabel,
        coords = data.coords,
        members = data.members,
        leader = data.leader,
        startedAt = data.startedAt or now,
        receivedAt = now,
        test = data.test == true,
        alertedAt = nil,
        dispatchId = nil,
        title = nil,
        street = nil,
        suspects = nil,
        armed = {},             -- [citizenid] = os.time() of Crimson-Contracts' crewShot (C6; V14 copies it into the case)
        ended = false,
        outcome = nil,
    }
    crimes[crimeKey] = crime
    count = count + 1
    -- an admin's /testcriminalcontract run: never a live crime (C16)
    if crime.test then
        Audit('liveCrimeIgnored', crime, 'test', CP.L('livecrime.audit.ignored_test', Params(crime)))
        CP.log(TAG, 'crime %s (%s) is an admin test contract: ignored', crimeKey, crime.key)
        return false, 'test'
    end
    -- AFK samples from the start of the contract (C17), only for a crime that can become a LIVE call
    if MissionTypeOf(crime.key) then crime.sampled = Opp('sampleCrew', crimeKey, Sorted(crime.members)) == true end
    CP.log(TAG, 'crime %s (%s) started with %d crew member(s)', crimeKey, crime.key, CP.U.count(crime.members))
    return true
end

function LC.onAlert(res, data)
    local now = os.time()
    Prune(now)
    local crime = Find(res, data)
    if not crime or crime.test or crime.id ~= data.id then
        CP.log(TAG, 'police alert of %s:%s: %s', res, data.uid, crime and 'not a live crime' or 'unknown crime')
        return false, crime and 'test' or 'unknown'
    end
    if crime.ended or crime.alertedAt or crime.ignored then return false, 'done' end
    crime.dispatchId, crime.title, crime.street = data.dispatchId, data.title, data.street
    crime.coords = data.coords or crime.coords
    local missionType = MissionTypeOf(crime.key)
    if not missionType then
        crime.ignored = 'type_off'
        Unsample(crime)
        Audit('liveCrimeIgnored', crime, 'type_off', CP.L('livecrime.audit.ignored_type', Params(crime)))
        return false, 'type_off'
    end
    local suspects, why = Suspects(crime)
    local n = CP.U.count(suspects)
    if n == 0 then
        crime.ignored = 'no_suspect'
        Unsample(crime)
        Audit('liveCrimeIgnored', crime, 'no_suspect',
            CP.L('livecrime.audit.ignored_none', Params(crime, { why = WhyText(why) })))
        return false, 'no_suspect'
    end
    crime.missionType, crime.suspects, crime.alertedAt = missionType, suspects, now
    local others = {}
    for _, cid in ipairs(Sorted(crime.members)) do
        if not suspects[cid] then others[#others + 1] = cid end
    end
    if not crime.sampled then
        -- the type was off at the start and is on now: the suspects' samples start here
        crime.sampled = Opp('sampleCrew', crime.crimeKey, Sorted(suspects)) == true
    elseif #others > 0 then
        Unsample(crime, others)
    end
    local left = next(why) and CP.L('livecrime.audit.left_out', { why = WhyText(why) }) or ''
    Audit('liveCrimeReported', crime, ('%d/%d'):format(n, CP.U.count(crime.members)),
        CP.L('livecrime.audit.reported', Params(crime, { suspects = n, type = missionType, left = left })))
    local ok, err = pcall(LC.post, crime)
    if not ok then WarnOnce('post', 'CP.LiveCrime.post failed for %s: %s', crime.crimeKey, tostring(err)) end
    return true
end

function LC.onEnded(res, data)
    local now = os.time()
    local crime = Find(res, data)
    if not crime or crime.ended then
        Prune(now)
        return false, crime and 'done' or 'unknown'
    end
    crime.ended, crime.endedAt, crime.outcome, crime.endReason = true, now, data.outcome, data.reason
    -- a running case goes on, and its lost rule now runs without a contact
    local run = RunOf(crime)
    if run then Opp('crimeEnded', run) end
    Unsample(crime)
    EndCall(crime)
    CP.log(TAG, 'crime %s (%s) ended: %s', crime.crimeKey, crime.key, data.outcome)
    Prune(now)
    return true
end

-- CP.Opponents finds him again itself when his character loads (V4); the case only gets a timeline line.
function LC.onRejoined(res, data)
    local crime = Find(res, data)
    local cid = data.citizenid
    if not crime or crime.test or not crime.members[cid] then return false, 'unknown' end
    local run = RunOf(crime)
    local case, rec = nil, nil
    if run then case, rec = Opp('byCid', cid) end
    if case and rec and case.runId == run.id then
        Opp('timeline', run, { what = 'crew_rejoined', label = rec.label })
    end
    CP.log(TAG, 'crime %s: a crew member rejoined', crime.crimeKey)
    return true
end

-- Crimson-Contracts' proof that a crew member was armed (C6): on the suspect of a running case, or kept on the crime
-- until its case opens. Crimson-Contracts sends one 'shot' per contract and one 'gun_kill' per guard a crew member
-- shot dead; CP.Opponents' own weapon checks cover every other shot in the case.
function LC.onCrewShot(res, data)
    local crime = Find(res, data)
    local cid = data.citizenid
    if not crime or crime.test or not crime.members[cid] then return false, 'unknown' end
    crime.armed[cid] = os.time()
    local run = RunOf(crime)
    local case = run and Opp('caseOf', run) or nil
    if case and case.suspects and case.suspects[cid] then Opp('noteArmed', cid) end
    return true
end

-- ============================================================================
--                                     API
-- ============================================================================

-- The red LIVE call on the Dispatch screen for a crime with suspects (step V11, CP.MissionCalls.postLive). A crime
-- that cannot be posted (Config.LiveCrime.maxLiveRuns reached, mission calls off) gets the audit line
-- liveCrimeIgnored with the reason; true when the call is up.
function LC.post(crime)
    local M = CP.MissionCalls
    if not (M and M.postLive) then return false end
    local call, why = M.postLive(crime)
    if call then
        crime.callId = call.id
        return true
    end
    why = why or 'invalid'
    if why ~= 'posted' then
        local key = 'livecrime.why.' .. why
        local text = CP.Locale and CP.Locale.has and CP.Locale.has(key) and CP.L(key) or why
        Audit('liveCrimeIgnored', crime, why, CP.L('livecrime.audit.not_posted', Params(crime, { why = text })))
    end
    return false
end

-- The record of a crime ('<resource>:<uid>'), or nil.
function LC.get(crimeKey) return type(crimeKey) == 'string' and crimes[crimeKey] or nil end

-- The crime of a live run (run.live.crimeKey, V14), or nil.
function LC.crimeOf(run)
    local live = type(run) == 'table' and run.live or nil
    return type(live) == 'table' and LC.get(live.crimeKey) or nil
end

-- Whether a citizenid is in the crew of a crime that has not ended (and that crime); false while live crimes are off
-- (nothing is heard then) and for admin test contracts.
function LC.inCrew(cid)
    if Cfg().enabled ~= true or type(cid) ~= 'string' then return false end
    local now = os.time()
    for _, crime in pairs(crimes) do
        if not crime.ended and not crime.test and crime.members[cid] and now - crime.receivedAt <= KEEP_OPEN then
            return true, crime
        end
    end
    return false
end

-- ============================================================================
--                       SCORING (V13, ARCHITECTURE 5.46)
-- ============================================================================
-- The rules CP.Scoring, CP.Cash, CP.Rewards, CP.Goals and CP.Challenge ask about a live run. They read the run
-- itself (never Config.LiveCrime.enabled), so a case that is running when the owner turns live crimes off still
-- ends by the rules it started with.

LC.MISSION_ID = 'live_crime'      -- the engine mission of a live case (V14), its rows' mission_id

-- Whether a run is a live case (run.live from V14, or run.realSuspect = 'live').
function LC.isLive(run)
    if type(run) ~= 'table' then return false end
    return type(run.live) == 'table' or run.realSuspect == 'live'
end

-- true = only the live lines score (no base points, no end-of-run lines); Config.LiveCrime.linesOnly, shipped true.
function LC.linesOnly(run) return LC.isLive(run) and Cfg().linesOnly ~= false end

-- Whether a live run takes part in something a mission gets: 'typeOfTheDay', 'goals', 'challenge', 'cash' or
-- 'items' (the Config.LiveCrime switch of that name, each shipped false). Any other run: true.
local COUNTS = { typeOfTheDay = true, goals = true, challenge = true, cash = true, items = true }
function LC.counts(run, what)
    if not LC.isLive(run) then return true end
    return COUNTS[what] == true and Cfg()[what] == true
end

-- The suspects of a live run: the crime's, else the case's, else run.live.suspects (a count); at least 1.
function LC.crewSize(run)
    local n = 0
    local crime = LC.crimeOf(run)
    if crime and type(crime.suspects) == 'table' then
        for _ in pairs(crime.suspects) do n = n + 1 end
    end
    if n == 0 and CP.Opponents and CP.Opponents.view then
        local ok, view = pcall(CP.Opponents.view, run)
        if ok and type(view) == 'table' and type(view.order) == 'table' then n = #view.order end
    end
    if n == 0 and type(run) == 'table' and type(run.live) == 'table' then
        n = math.floor(Num(run.live.suspects, 0))
    end
    return math.max(1, n)
end

-- The Config.Scaling row of a live run whose tier comes from its crew (Config.LiveCrime.tier = 'crew', shipped),
-- or nil (not live, 'officers', or no scaling rows): the caller then uses the run's own pay tier.
function LC.tierRow(run)
    if not LC.isLive(run) or Cfg().tier == 'officers' then return nil end
    if not (CP.Scaling and CP.Scaling.tierFor) then return nil end
    local ok, row = pcall(CP.Scaling.tierFor, LC.crewSize(run))
    if ok and type(row) == 'table' then return row end
    return nil
end

-- SQL to add to a WHERE that sums run rows for goals or the challenge: leaves out live-case rows while that
-- switch is off ('' when it is on). alias: the table alias with its dot ('r.') or ''.
function LC.rowFilter(what, alias)
    if Cfg()[what] == true then return '' end
    return (' AND COALESCE(%smission_id, \'\') <> \'%s\''):format(alias or '', LC.MISSION_ID)
end

-- ============================================================================
--               THE CLAIM AND THE CASE (V14, ARCHITECTURE 5.46)
-- ============================================================================
-- A unit that claims a LIVE call gets no draw: CP.Draw's live path runs LC.claimCheck, builds the run from
-- LC.missionFor(crime) (the engine-only live_crime mission at the crime's reported place) and CP.Runs.create opts.live;
-- the run:created hook below opens the CP.Opponents case for the crime's suspects, and run:ended writes the pair rows.

local function RS() return type(Config.RealSuspects) == 'table' and Config.RealSuspects or {} end

local function SceneRadius() return math.max(1.0, Num(Cfg().sceneRadius, 75.0)) end

-- Seconds a live case lasts at most (Config.LiveCrime.caseTime, 60-3600; the mission loader's time limit range).
local function CaseTime() return math.floor(CP.U.clamp(Num(Cfg().caseTime, 1800), 60, 3600)) end

-- The mission type the engine mission is registered with (each case uses its crime's own type).
local function AnyType()
    local types = type(Config.MissionTypes) == 'table' and Config.MissionTypes or {}
    if type(types.investigation) == 'table' then return 'investigation' end
    return Sorted(types)[1]
end

local engine = nil

-- The live_crime engine mission (CP.Missions.registerEngine: a registry of its own, never drawn, listed or sent to
-- clients), registered on first use. Its one location is a placeholder: every case gets its crime's place.
function LC.engineMission()
    if engine then return engine end
    local M = CP.Missions
    if not (M and M.registerEngine) then return nil end
    local existing = M.engine and M.engine(LC.MISSION_ID)
    if existing then
        engine = existing
        return engine
    end
    local typeKey = AnyType()
    if not typeKey then return nil end
    local d = M.registerEngine({
        id = LC.MISSION_ID,
        label = CP.L('livecrime.mission.label'),
        description = CP.L('livecrime.mission.description'),
        type = typeKey,
        minOfficers = 1,
        maxOfficers = math.max(1, math.floor(Num(Config.Limits and Config.Limits.maxUnitSize, 4))),
        timeLimit = CaseTime(),
        cooldown = 0,
        vehiclePenalties = false,
        locations = {
            { label = CP.L('livecrime.mission.place'), start = { coords = vec3(0.0, 0.0, 0.0), radius = 75.0 } },
        },
        objectives = { { block = 'live_response', label = CP.L('livecrime.mission.objective') } },
    })
    engine = d
    return engine
end

-- The mission of this crime's case: a copy of the engine mission with the crime's mission type, Config.LiveCrime's
-- caseTime and one location, the crime's reported place (sceneRadius). -> def, 1 | nil.
function LC.missionFor(crime)
    if type(crime) ~= 'table' or type(crime.missionType) ~= 'string' then return nil end
    local x, y, z = CP.U.xyz(crime.coords)
    if not x then return nil end
    local base = LC.engineMission()
    if not base then return nil end
    local d = CP.U.deepcopy(base)
    d.type = crime.missionType
    d.label = CP.L('livecrime.mission.label_of', { crime = crime.title or crime.label or crime.key or '?' })
    d.timeLimit = CaseTime()
    d.locations = {
        {
            label = crime.locationLabel or crime.street or base.locations[1].label,
            start = { coords = vec3(x + 0.0, y + 0.0, z + 0.0), radius = SceneRadius() },
        },
    }
    return d, 1
end

-- Whether these officers may take this crime's case -> true | false, err (checked at the claim and again at the
-- accept; memory only: CP.Opponents' caps never query the database). officers = { { src, citizenid } }.
function LC.claimCheck(crime, officers)
    if Cfg().enabled ~= true then return false, 'err.live_case_off' end
    if type(crime) ~= 'table' or crime.ended or crime.test or type(crime.suspects) ~= 'table' then
        return false, 'err.live_case_gone'
    end
    if RunOf(crime) then return false, 'err.mc_taken_by' end
    local suspects = Sorted(crime.suspects)
    local open, worth = 0, 0
    local perDay = math.floor(Num(RS().maxCatchesPerSuspectDay, 2))
    for _, cid in ipairs(suspects) do
        if not Opp('byCid', cid) then
            open = open + 1
            if Num(Opp('suspectDayCount', cid), 0) < perDay then worth = worth + 1 end
        end
    end
    if open == 0 then return false, 'err.live_case_gone' end
    if worth == 0 then return false, 'err.live_case_suspect_used' end
    local hopS = Num(RS().jobHopMinutes, 30) * 60
    local now = os.time()
    for _, o in ipairs(type(officers) == 'table' and officers or {}) do
        local cid = type(o) == 'table' and o.citizenid or nil
        if type(cid) ~= 'string' then return false, 'err.member_unavailable' end
        if crime.members[cid] then return false, 'err.live_case_own_suspect' end
        if Opp('suspended', cid) == true then return false, 'err.live_case_suspended' end
        local was = tonumber(Opp('lastSuspectAt', cid))
        if was and now - was < hopS then return false, 'err.live_case_recent_suspect' end
        if Opp('selfBlock', o.src, crime.suspects) == true then return false, 'err.live_case_own_suspect' end
        for _, sCid in ipairs(suspects) do
            local ok, why = Opp('pairOk', cid, sCid)
            if ok == false and why == 'blocked' then return false, 'err.live_case_pair_blocked' end
            if ok == false and (why == 'pair_cooldown' or why == 'suspect_cooldown') then
                return false, 'err.live_case_pair_cooldown'
            end
        end
    end
    return true
end

-- What CP.Runs.create keeps in run.live for this crime (opts.live): no server id, no citizenid.
function LC.liveOf(crime)
    return {
        crimeKey = crime.crimeKey,
        dispatchId = crime.dispatchId,
        title = crime.title,
        street = crime.street,
        suspects = CP.U.count(crime.suspects),
    }
end

-- run:created of a live run: the crime remembers it, the case opens for its suspects (the crime's coords are the
-- scene), Crimson-Contracts' crew shots mark those suspects armed (C6), and an officer who shares a connection or PC
-- with a suspect gets the officer-conduct flag rs_linked_accounts (his own points only). A case that cannot open
-- (every suspect in another case meanwhile) ends the run as cancelled: no cooldown, no penalty.
local function Opened(run)
    local crime = LC.crimeOf(run)
    local case = nil
    if crime and not crime.ended then
        crime.runId = run.id
        case = Opp('open', run, { kind = 'live', index = 1, members = crime.suspects, scene = crime.coords })
    end
    if type(case) ~= 'table' then
        CP.warn(TAG, 'run %s: the live case could not open (%s): the run is cancelled', run.id,
            crime and 'no suspect left' or 'the crime is gone')
        SetTimeout(0, function()
            if run.state ~= 'ended' and CP.Runs and CP.Runs.endRun then
                CP.Runs.endRun(run, 'abandoned', 'cancelled')
            end
        end)
        return
    end
    for cid in pairs(crime.armed or {}) do
        if case.suspects and case.suspects[cid] then Opp('noteArmed', cid) end
    end
    for src, p in pairs(run.participants or {}) do
        local blocked, _, flags, match = Opp('selfBlock', src, crime.suspects)
        if blocked ~= true and type(flags) == 'table' then
            for _, reason in ipairs(flags) do
                local kinds = type(match) == 'table' and type(match.kinds) == 'table' and match.kinds or {}
                local rec = type(match) == 'table' and case.suspects[match.cid] or nil
                local detail = ('suspect %s, shared %s'):format(rec and rec.label or '?', table.concat(kinds, ', '))
                if CP.AntiCheat and CP.AntiCheat.flag then pcall(CP.AntiCheat.flag, run, src, reason, detail) end
            end
        end
        if p.citizenid then Opp('timeline', run, { what = 'officer', label = p.callsign or p.name }) end
    end
    CP.log(TAG, 'crime %s: case opened on run %s', crime.crimeKey, run.id)
end

-- run:ended of a live run: one pair row per officer and suspect (CP.Opponents.recordPairs; scored = the case
-- completed and the suspect was detained or booked for a share above 0; outcome 'gone' when no officer reached the
-- scene), then the pair-repeat check.
local function Closed(run, state)
    local outcomes, case = Opp('close', run)
    if type(case) ~= 'table' or type(outcomes) ~= 'table' then return end
    local arrived = false
    for _, p in pairs(run.participants or {}) do
        if p.arrived then arrived = true end
    end
    local rows = {}
    for _, p in pairs(run.participants or {}) do
        if type(p.citizenid) == 'string' then
            for _, cid in ipairs(case.order or {}) do
                local rec = case.suspects[cid] or {}
                local out = outcomes[cid]
                local caught = (out == 'detained' or out == 'booked') and Num(rec.share, 1) > 0
                rows[#rows + 1] = {
                    officer = p.citizenid,
                    suspect = cid,
                    scored = state == 'completed' and caught,
                    outcome = arrived and out or 'gone',
                }
            end
        end
    end
    Opp('recordPairs', run, rows)
    Opp('checkPairFlags', run)
end

if CP.Hooks and CP.Hooks.on then
    CP.Hooks.on('run:created', function(run)
        if type(run) == 'table' and type(run.live) == 'table' then Opened(run) end
    end)
    CP.Hooks.on('run:ended', function(run, state)
        if type(run) == 'table' and type(run.live) == 'table' then Closed(run, state) end
    end)
end

-- A reporting script stopped without ending its crimes: they end now.
AddEventHandler('onResourceStop', function(res)
    if count == 0 then return end
    local now = os.time()
    for _, crime in pairs(crimes) do
        if crime.res == res and not crime.ended then
            crime.ended, crime.endedAt, crime.outcome = true, now, 'stopped'
            local run = RunOf(crime)
            if run then Opp('crimeEnded', run) end
            Unsample(crime)
            EndCall(crime)
        end
    end
end)

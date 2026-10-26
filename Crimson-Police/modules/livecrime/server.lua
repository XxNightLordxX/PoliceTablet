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

-- The LIVE call for a crime with suspects (step V11). Until then it is only logged.
function LC.post(crime)
    CP.log(TAG, 'crime %s (%s): would post a LIVE call (%s, %d suspect(s))', crime.crimeKey, crime.key,
        tostring(crime.missionType), CP.U.count(crime.suspects))
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
        end
    end
end)

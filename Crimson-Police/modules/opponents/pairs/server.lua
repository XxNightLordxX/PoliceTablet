-- CP.Opponents identity and pairs (server, step V7; critic C27, critic 2 #21-#23, #30): the self rule (nobody takes a

CP.Opponents = CP.Opponents or {}
local Opp = CP.Opponents
local TAG = 'opponents'

local DAY_S = 86400
local SHORT_CASE_S = 180          -- a case shorter than this is a pair-repeat warning sign
local STILL_METRES = 30.0         -- a never-armed suspect who never got this far from where contact was made...
local MAX_ADMIN_DAYS = 3650       -- an admin block, exclusion or suspension lasts at most this many days
local MAX_ROWS_PER_INSERT = 100   -- rows of one INSERT statement
local LICENSES_KEPT = 2000        -- offline suspects' licenses kept (a character's license never changes)

local CASE_KINDS = { live = true, volunteer = true }
local START = os.time()           -- "on duty since the resource started"

local selfCache = {}                           -- [officer src] = { cid, own = { [cid] = true }, lics = { [license] = true } }
local licOf, licCount = {}, 0                  -- [citizenid] = license of an offline suspect (Qbox's players table)
local dutyOf = {}                              -- [src] = citizenid while on duty in a department job
local deptOf = {}                              -- [src] = citizenid while in a department job (on duty or not)
local dutySince = {}                           -- [citizenid] = os.time() his department duty began
local lastPolice = {}                          -- [citizenid] = os.time() he last left department duty or a department job
local lastSuspect = {}                         -- [citizenid] = os.time() a case with him as a suspect closed
local ledger = { rows = {}, byOfficer = {}, bySuspect = {}, byRun = {}, keys = {}, from = nil }
local blocks, excludes, suspends = {}, {}, {}  -- [officer|suspect] / [citizenid] = until (os.time())
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

local function Lic(v)
    if type(v) ~= 'string' or v == '' or #v > 64 then return nil end
    return v
end

local function LogError(key, fmt, ...)
    local now = os.time()
    if errorAt[key] and now - errorAt[key] < 60 then return end
    errorAt[key] = now
    CP.err(TAG, fmt, ...)
end

-- Either feature on: only then is a duty change written to the ledger (the memory maps are always kept).
local function FeatureOn()
    return (type(Config.LiveCrime) == 'table' and Config.LiveCrime.enabled == true)
        or (type(Config.Volunteers) == 'table' and Config.Volunteers.enabled == true)
end

local function DbReady()
    if not (CP.Migrations and CP.Migrations.ready) then return true end
    local ok = pcall(CP.Migrations.ready)
    return ok
end

-- A Qbox job in any Config.Departments entry (a turned-off department counts too: it is still police).
local function IsDeptJob(name)
    if type(name) ~= 'string' or not CP.Access then return false end
    local A = CP.Access
    if A.departmentForJob and A.departmentForJob(name) then return true end
    return A.offDepartmentForJob ~= nil and A.offDepartmentForJob(name) ~= nil
end

local function Info(src)
    if not (CP.Qbx and CP.Qbx.getInfo) then return nil end
    local info = CP.Qbx.getInfo(src)
    if type(info) ~= 'table' or not ValidCid(info.citizenid) then return nil end
    return info
end

-- The start of today (Config.Time.resetHour), as CP.Runs and CP.Scoring count the day.
local function DayStart(now)
    if CP.Schedule and CP.Schedule.dayStart then
        local ok, ts = pcall(CP.Schedule.dayStart, now)
        if ok and tonumber(ts) then return math.floor(tonumber(ts)) end
    end
    local t = os.date('*t', now)
    local h = math.floor(Num(Config.Time and Config.Time.resetHour, 0))
    local start = os.time({ year = t.year, month = t.month, day = t.day, hour = h })
    if start > now then start = os.time({ year = t.year, month = t.month, day = t.day - 1, hour = h }) end
    return start
end

-- The seconds of history every cap and the pair flag read: max(pairCooldownHours, 24 h, pairFlag.days,
-- jobHopMinutes, suspectCooldownMinutes).
local function Window()
    local cfg = Cfg()
    local flag = type(cfg.pairFlag) == 'table' and cfg.pairFlag or {}
    return math.floor(math.max(DAY_S, Num(cfg.pairCooldownHours, 24) * 3600, Num(flag.days, 7) * DAY_S,
        Num(cfg.jobHopMinutes, 30) * 60, Num(cfg.suspectCooldownMinutes, 30) * 60))
end

-- The case of a run, open or just closed (Opp.close answers a closed case again; never called for an open one).
local function CaseOf(run)
    if type(run) ~= 'table' or type(run.id) ~= 'string' or not Opp.caseOf then return nil end
    local case = Opp.caseOf(run)
    if case then return case end
    if not Opp.close then return nil end
    local _, closed = Opp.close(run)
    return closed
end

-- ============================================================================
--                             THE LEDGER (MEMORY)
-- ============================================================================
-- row = { kind = 'live'|'volunteer', run, officer, officerLicense, suspect, suspectLicense, outcome, scored, at }

local function Push(map, key, row)
    local list = map[key]
    if not list then
        list = {}
        map[key] = list
    end
    list[#list + 1] = row
end

-- false when the same row (kind, run, officer, suspect) is in memory already.
local function AddRow(row)
    local key = row.kind .. '|' .. tostring(row.run or '') .. '|' .. row.officer .. '|' .. row.suspect
    if ledger.keys[key] then return false end
    ledger.keys[key] = true
    ledger.rows[#ledger.rows + 1] = row
    Push(ledger.byOfficer, row.officer, row)
    Push(ledger.bySuspect, row.suspect, row)
    if row.run then Push(ledger.byRun, row.run, row) end
    if row.at > (lastSuspect[row.suspect] or 0) then lastSuspect[row.suspect] = row.at end
    return true
end

local function Later(map, key, t)
    if t > (map[key] or 0) then map[key] = t end
end

-- Rows older than the window and admin rows that ran out leave memory (the daily pass and a shorter window).
local function Trim(now)
    local cutoff = now - Window()
    local rows = ledger.rows
    ledger.rows, ledger.byOfficer, ledger.bySuspect, ledger.byRun, ledger.keys = {}, {}, {}, {}, {}
    for _, r in ipairs(rows) do
        if r.at >= cutoff then AddRow(r) end
    end
    ledger.from = math.max(ledger.from or cutoff, cutoff)
    for _, map in ipairs({ blocks, excludes, suspends }) do
        for k, t in pairs(map) do
            if t <= now then map[k] = nil end
        end
    end
    for _, map in ipairs({ lastPolice, lastSuspect }) do
        for k, t in pairs(map) do
            if t < cutoff then map[k] = nil end
        end
    end
end

-- ============================================================================
--                            THE LEDGER (DATABASE)
-- ============================================================================

local INSERT = 'INSERT INTO cp_pvp_pairs (kind, run_uuid, officer_citizenid, officer_license, suspect_citizenid, '
    .. 'suspect_license, outcome, scored, until_at, created_at) VALUES '

-- One statement per MAX_ROWS_PER_INSERT rows, in a thread (never in a tick). A missing value is written as NULL in
-- the statement: a parameter list never has holes.
local function Insert(rows)
    if #rows == 0 then return end
    CreateThread(function()
        if not DbReady() then return end
        for first = 1, #rows, MAX_ROWS_PER_INSERT do
            local tuples, params = {}, {}
            for i = first, math.min(#rows, first + MAX_ROWS_PER_INSERT - 1) do
                local r = rows[i]
                local marks = {}
                local function put(v, mark)
                    if v == nil then
                        marks[#marks + 1] = 'NULL'
                    else
                        marks[#marks + 1] = mark or '?'
                        params[#params + 1] = v
                    end
                end
                put(r.kind)
                put(r.run)
                put(r.officer or '')
                put(r.officerLicense)
                put(r.suspect or '')
                put(r.suspectLicense)
                put(r.outcome)
                put(r.scored and 1 or 0)
                put(r.untilAt, 'FROM_UNIXTIME(?)')
                put(r.at, 'FROM_UNIXTIME(?)')
                tuples[#tuples + 1] = '(' .. table.concat(marks, ', ') .. ')'
            end
            local ok, err = pcall(MySQL.insert.await, INSERT .. table.concat(tuples, ', '), params)
            if not ok then LogError('insert', 'writing %d pair ledger row(s) failed: %s', #tuples, tostring(err)) end
        end
    end)
end

local function Scored(v) return v == true or v == 1 or v == '1' end

-- Case and duty_off rows created in [fromTs, toTs) (toTs nil: up to now) into memory.
local function LoadRows(fromTs, toTs)
    local sql = [[SELECT kind, run_uuid, officer_citizenid, officer_license, suspect_citizenid, suspect_license,
        outcome, scored, UNIX_TIMESTAMP(created_at) AS created_ts FROM cp_pvp_pairs
        WHERE kind IN ('live', 'volunteer', 'duty_off') AND created_at >= FROM_UNIXTIME(?)]]
    local params = { math.max(1, math.floor(fromTs)) }
    if toTs then
        sql = sql .. ' AND created_at < FROM_UNIXTIME(?)'
        params[2] = math.floor(toTs)
    end
    local ok, rows = pcall(MySQL.query.await, sql, params)
    if not ok then
        LogError('load', 'reading the pair ledger failed: %s', tostring(rows))
        return false
    end
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        local at = math.floor(Num(r.created_ts, 0))
        local officer, suspect = r.officer_citizenid, r.suspect_citizenid
        if r.kind == 'duty_off' then
            if ValidCid(officer) then Later(lastPolice, officer, at) end
        elseif CASE_KINDS[r.kind] and ValidCid(officer) and ValidCid(suspect) then
            AddRow({
                kind = r.kind,
                run = type(r.run_uuid) == 'string' and r.run_uuid or nil,
                officer = officer,
                officerLicense = Lic(r.officer_license),
                suspect = suspect,
                suspectLicense = Lic(r.suspect_license),
                outcome = type(r.outcome) == 'string' and r.outcome or nil,
                scored = Scored(r.scored),
                at = at,
            })
        end
    end
    return true
end

-- Every admin block, exclusion and suspension that has not run out.
local function LoadAdmin(now)
    local ok, rows = pcall(MySQL.query.await, [[SELECT kind, officer_citizenid, suspect_citizenid,
        UNIX_TIMESTAMP(until_at) AS until_ts FROM cp_pvp_pairs
        WHERE kind IN ('block', 'exclude', 'suspend') AND until_at > FROM_UNIXTIME(?)]], { now })
    if not ok then
        LogError('load', 'reading the pair ledger\'s admin rows failed: %s', tostring(rows))
        return false
    end
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        local untilAt = math.floor(Num(r.until_ts, 0))
        if r.kind == 'block' and ValidCid(r.officer_citizenid) and ValidCid(r.suspect_citizenid) then
            Later(blocks, r.officer_citizenid .. '|' .. r.suspect_citizenid, untilAt)
        elseif r.kind == 'exclude' and ValidCid(r.suspect_citizenid) then
            Later(excludes, r.suspect_citizenid, untilAt)
        elseif r.kind == 'suspend' and ValidCid(r.officer_citizenid) then
            Later(suspends, r.officer_citizenid, untilAt)
        end
    end
    return true
end

-- Retention (critic 2 #23, LOOP_RULES 11): case and duty_off rows older than pairLedgerDays, one statement per kind,
-- and admin rows whose until_at has passed. Once at start and once a day, in a thread.
local function Prune(now)
    if not DbReady() then return end
    local cutoff = now - math.floor(math.max(1, Num(Cfg().pairLedgerDays, 30)) * DAY_S)
    local removed = 0
    for _, kind in ipairs({ 'live', 'volunteer', 'duty_off' }) do
        local ok, n = pcall(MySQL.update.await,
            'DELETE FROM cp_pvp_pairs WHERE kind = ? AND created_at < FROM_UNIXTIME(?)', { kind, cutoff })
        if ok then
            removed = removed + math.floor(Num(n, 0))
        else
            LogError('prune', 'the pair ledger clean-up failed: %s', tostring(n))
        end
    end
    local ok, n = pcall(MySQL.update.await,
        'DELETE FROM cp_pvp_pairs WHERE kind IN (\'block\', \'exclude\', \'suspend\') AND until_at <= FROM_UNIXTIME(?)',
        { now })
    if ok then
        removed = removed + math.floor(Num(n, 0))
    else
        LogError('prune', 'the pair ledger clean-up failed: %s', tostring(n))
    end
    Trim(now)
    if removed > 0 then CP.log(TAG, 'pair ledger clean-up removed %d row(s)', removed) end
end

-- A longer window after a settings change: the older rows are read once (LOOP_RULES 11: in a thread).
local function Widen()
    local now = os.time()
    local from = now - Window()
    if not ledger.from or from >= ledger.from then return end
    local to = ledger.from
    ledger.from = from
    CreateThread(function()
        if DbReady() then LoadRows(from, to) end
    end)
end

-- ============================================================================
--                                THE SELF RULE
-- ============================================================================

-- Two licenses of one player, strictly (critic 2 #22): an unknown (nil or '') license refuses. `known` is the set of
-- every license of a's player, read once per officer session (selfBlock's cache): then nothing is asked again.
local function SameUserStrict(a, b, known)
    if type(a) ~= 'string' or a == '' or type(b) ~= 'string' or b == '' then return true end
    if known then return known[b] == true end
    if not (CP.Access and CP.Access.sameUser) then return a == b end
    return CP.Access.sameUser(a, b) == true
end
Opp.sameUserStrict = function(a, b) return SameUserStrict(a, b) end

-- Every character and every license of the officer's player, read once per session (critic 2 #21:
-- CP.Access.selfCitizenids runs a query per license); cleared at unload, character switch and drop.
local function SelfOf(src, info)
    local hit = selfCache[src]
    if hit and hit.cid == (info and info.citizenid) then return hit end
    local own, lics = {}, {}
    if CP.Access and CP.Access.selfCitizenids then
        for _, cid in ipairs(CP.Access.selfCitizenids(src) or {}) do own[cid] = true end
    end
    local mine = CP.Access and CP.Access.licensesOfSrc and CP.Access.licensesOfSrc(src) or {}
    for _, l in ipairs(mine) do
        lics[l] = true
        if CP.Qbx and CP.Qbx.userLicenses then
            for _, other in ipairs(CP.Qbx.userLicenses(l) or {}) do lics[other] = true end
        end
    end
    hit = { cid = info and info.citizenid, own = own, lics = lics }
    selfCache[src] = hit
    return hit
end

-- A suspect's online server id and license: the event-kept getInfo for an online one, Qbox's players table (kept
-- here once known) for an offline one.
local function SuspectOf(cid, hint)
    local src = ToSrc(hint)
    local info = src and Info(src)
    if not info or info.citizenid ~= cid then
        src = CP.Qbx and CP.Qbx.getByCitizenId and ToSrc(CP.Qbx.getByCitizenId(cid)) or nil
        info = src and Info(src)
        if not info or info.citizenid ~= cid then src, info = nil, nil end
    end
    if info then return src, Lic(info.license) end
    if licOf[cid] then return nil, licOf[cid] end
    local lic = CP.Qbx and CP.Qbx.licenseOf and Lic(CP.Qbx.licenseOf(cid)) or nil
    if lic then
        if licCount >= LICENSES_KEPT then licOf, licCount = {}, 0 end
        licOf[cid], licCount = lic, licCount + 1
    end
    return nil, lic
end

-- { [kind] = { [identifier] = true } } of an online player, read live (GetPlayerIdentifierByType matches by prefix,
-- 'license' also finds 'license2:...': every identifier is read and grouped by the text before ':' instead).
-- 'token' = every GetPlayerToken value. Never kept.
local function IdentitiesOf(src)
    local out = {}
    local function add(kind, id)
        local set = out[kind]
        if not set then
            set = {}
            out[kind] = set
        end
        set[id] = true
    end
    local okN, n = pcall(GetNumPlayerIdentifiers, src)
    for i = 0, (okN and math.floor(Num(n, 0)) or 0) - 1 do
        local ok, id = pcall(GetPlayerIdentifier, src, i)
        local kind = ok and type(id) == 'string' and id:match('^([^:]+):.') or nil
        if kind then add(kind, id) end
    end
    local okT, t = pcall(GetNumPlayerTokens, src)
    for i = 0, (okT and math.floor(Num(t, 0)) or 0) - 1 do
        local ok, token = pcall(GetPlayerToken, src, i)
        if ok and type(token) == 'string' and token ~= '' then add('token', token) end
    end
    return out
end

local function Shares(a, b, kind)
    local x, y = a[kind], b[kind]
    if not x or not y then return false end
    for id in pairs(x) do
        if y[id] then return true end
    end
    return false
end

local function KindList(list)
    local out = {}
    for _, k in ipairs(type(list) == 'table' and list or {}) do
        if type(k) == 'string' and k ~= '' then out[#out + 1] = k end
    end
    return out
end

-- Citizenids from a list ({ 'A1' }) or a map ({ [cid] = true } or { [cid] = src }), with the server id hint of a map.
local function SuspectList(suspects)
    local out = {}
    if type(suspects) == 'string' then suspects = { suspects } end
    if type(suspects) ~= 'table' then return out end
    for k, v in pairs(suspects) do
        if math.type(k) == 'integer' and ValidCid(v) then
            out[#out + 1] = { cid = v }
        elseif ValidCid(k) and v then
            out[#out + 1] = { cid = k, hint = v }
        end
    end
    table.sort(out, function(a, b) return a.cid < b.cid end)
    return out
end

-- Whether officerSrc may take a case against these suspects (citizenids, online or offline) -> blocked, kind, flags,
-- match. kind: 'own_character' (one of his player's characters), 'own_license' (the same player by license, or a
-- license that is not known), 'linked_account' (the same identifier of a kind in identityMatch.block, both online).
-- flags = { 'rs_linked_accounts' } when they share a kind in identityMatch.flag (an officer-conduct flag the caller
-- raises with CP.AntiCheat.flag on this officer). match = { cid, kinds } names the suspect and the kinds only (never
-- an identifier). On a cache hit nothing is queried (the availability check calls it per candidate and member).
function Opp.selfBlock(officerSrc, suspects)
    local src = ToSrc(officerSrc)
    local list = SuspectList(suspects)
    local flags = {}
    if #list == 0 then return false, nil, flags end
    local info = src and Info(src) or nil
    local mine = src and SelfOf(src, info) or { own = {}, lics = {} }
    local license = info and Lic(info.license) or nil
    local cfg = type(Cfg().identityMatch) == 'table' and Cfg().identityMatch or {}
    local blockKinds, flagKinds = KindList(cfg.block), KindList(cfg.flag)
    local officerIds = nil
    local flagged = nil
    local function refuse(kind, cid, kinds)
        CP.log(TAG, 'self rule: officer %s refused (%s)', tostring(info and info.citizenid or src), kind)
        return true, kind, {}, { cid = cid, kinds = kinds }
    end
    for _, s in ipairs(list) do
        if mine.own[s.cid] or (info and info.citizenid == s.cid) then return refuse('own_character', s.cid) end
        local sSrc, sLicense = SuspectOf(s.cid, s.hint)
        if SameUserStrict(license, sLicense, next(mine.lics) and mine.lics or nil) then
            return refuse('own_license', s.cid)
        end
        if src and sSrc and sSrc ~= src then
            officerIds = officerIds or IdentitiesOf(src)
            local theirs = IdentitiesOf(sSrc)
            for _, kind in ipairs(blockKinds) do
                if Shares(officerIds, theirs, kind) then return refuse('linked_account', s.cid, { kind }) end
            end
            for _, kind in ipairs(flagKinds) do
                if Shares(officerIds, theirs, kind) then
                    flagged = flagged or { cid = s.cid, kinds = {} }
                    if flagged.cid == s.cid then flagged.kinds[#flagged.kinds + 1] = kind end
                end
            end
        end
    end
    if flagged then
        flags[1] = 'rs_linked_accounts'
        CP.log(TAG, 'self rule: officer %s shares %s with a suspect (flagged)',
            tostring(info and info.citizenid or src), table.concat(flagged.kinds, ', '))
    end
    return false, nil, flags, flagged
end

-- ============================================================================
--                                THE DUTY MAPS
-- ============================================================================

-- He left department duty (or a department job): lastPoliceAt, and a duty_off ledger row so a restart keeps it
-- (critic 2 #30; written only while a feature is on).
local function LeftPolice(src, cid)
    dutyOf[src] = nil
    dutySince[cid] = nil
    local now = os.time()
    lastPolice[cid] = now
    if FeatureOn() then Insert({ { kind = 'duty_off', officer = cid, suspect = '', scored = false, at = now } }) end
end

-- The maps for one player from his getInfo: on duty in a department job (dutySince from now, or START when he was
-- on duty when the resource started), off duty, or out of every department job.
local function Sync(src, info, atStart)
    local cid = info.citizenid
    local job = type(info.job) == 'table' and info.job or {}
    local dept = IsDeptJob(job.name)
    if dept and job.onduty == true then
        if dutyOf[src] ~= cid then
            if dutyOf[src] then LeftPolice(src, dutyOf[src]) end
            dutyOf[src] = cid
            dutySince[cid] = dutySince[cid] or (atStart and START or os.time())
        end
    elseif dutyOf[src] then
        LeftPolice(src, dutyOf[src])
    elseif deptOf[src] and (not dept or deptOf[src] ~= cid) then
        LeftPolice(src, deptOf[src])
    end
    deptOf[src] = dept and cid or nil
end

-- QBCore:Server:SetDuty (a false is the event's own word; PlayerData is set before it).
local function DutyChanged(src, onDuty)
    src = ToSrc(src)
    local info = src and Info(src)
    if not info then return end
    if onDuty ~= true and type(info.job) == 'table' then info.job.onduty = false end
    Sync(src, info, false)
end

local function JobChanged(src, job)
    src = ToSrc(src)
    local info = src and Info(src)
    if not info then return end
    if type(job) == 'table' and type(job.name) == 'string' then info.job = job end
    Sync(src, info, false)
end

-- A logout, character switch or drop: on duty until now; his cached characters are forgotten.
local function Gone(src)
    selfCache[src] = nil
    if dutyOf[src] then LeftPolice(src, dutyOf[src]) end
    deptOf[src] = nil
end

-- os.time() his department duty began; START (the resource start) for one on duty since before it, or never seen
-- going on duty (critic: "anyone first seen on duty counts as since resource start").
function Opp.dutySince(cid)
    if not ValidCid(cid) then return nil end
    return dutySince[cid] or START
end

-- os.time() he last left department duty or a department job (a restart reads the duty_off rows), or nil.
function Opp.lastPoliceAt(cid)
    if not ValidCid(cid) then return nil end
    return lastPolice[cid]
end

-- os.time() a case with him as a suspect last closed (a restart reads the ledger), or nil.
function Opp.lastSuspectAt(cid)
    if not ValidCid(cid) then return nil end
    return lastSuspect[cid]
end

-- ============================================================================
--                                PAIRS AND CAPS
-- ============================================================================

-- The license of a participant of the run (cid): his participant row, else his cached getInfo (an event path).
local function OfficerLicense(run, cid)
    for src, p in pairs(type(run.participants) == 'table' and run.participants or {}) do
        if type(p) == 'table' and p.citizenid == cid then
            if Lic(p.license) then return p.license end
            local info = Info(src)
            if info and info.citizenid == cid then return Lic(info.license) end
            return nil
        end
    end
    return nil
end

local function Outcome(v)
    if type(v) ~= 'string' or v == '' then return nil end
    v = v:sub(1, 16)
    if not v:match('^[%w_]+$') then return nil end
    return v
end

-- At a case's close: one row per officer and suspect, rows = { { officer = cid, suspect = cid, scored = bool,
-- outcome?, kind? ('live'|'volunteer', default the case's), officerLicense?, suspectLicense? } }. Kept in memory at once
-- (the caps and checkPairFlags read it) and written in a thread. The same row twice is kept once. -> rows kept.
function Opp.recordPairs(run, rows)
    if type(run) ~= 'table' or type(run.id) ~= 'string' or type(rows) ~= 'table' then return 0 end
    local case = CaseOf(run)
    local now = os.time()
    local out = {}
    for _, r in ipairs(rows) do
        if type(r) == 'table' and ValidCid(r.officer) and ValidCid(r.suspect) and r.officer ~= r.suspect then
            local kind = r.kind or (case and case.kind) or run.realSuspect
            if CASE_KINDS[kind] then
                local rec = case and case.suspects[r.suspect] or nil
                local row = {
                    kind = kind,
                    run = run.id:sub(1, 36),
                    officer = r.officer,
                    officerLicense = Lic(r.officerLicense) or OfficerLicense(run, r.officer),
                    suspect = r.suspect,
                    suspectLicense = Lic(r.suspectLicense) or (rec and Lic(rec.license)) or nil,
                    outcome = Outcome(r.outcome) or (rec and Outcome(rec.outcome)) or nil,
                    scored = r.scored == true,
                    at = now,
                }
                if AddRow(row) then out[#out + 1] = row end
            end
        end
    end
    Insert(out)
    return #out
end

-- Whether this officer may still score on this suspect -> ok, reason ('blocked' an admin pair block,
-- 'pair_cooldown' a scored case of the pair within pairCooldownHours, 'suspect_cooldown' any case of the pair within
-- suspectCooldownMinutes), until (os.time()). Memory only.
function Opp.pairOk(officerCid, suspectCid)
    if not ValidCid(officerCid) or not ValidCid(suspectCid) then return false, 'invalid' end
    local now = os.time()
    local blocked = blocks[officerCid .. '|' .. suspectCid]
    if blocked and blocked > now then return false, 'blocked', blocked end
    local cfg = Cfg()
    local pairS = math.floor(Num(cfg.pairCooldownHours, 24) * 3600)
    local caseS = math.floor(Num(cfg.suspectCooldownMinutes, 30) * 60)
    local pairUntil, caseUntil = nil, nil
    for _, r in ipairs(ledger.byOfficer[officerCid] or {}) do
        if r.suspect == suspectCid and r.outcome ~= 'gone' then
            if r.scored and now - r.at < pairS then pairUntil = math.max(pairUntil or 0, r.at + pairS) end
            if now - r.at < caseS then caseUntil = math.max(caseUntil or 0, r.at + caseS) end
        end
    end
    if pairUntil then return false, 'pair_cooldown', pairUntil end
    if caseUntil then return false, 'suspect_cooldown', caseUntil end
    return true
end

local function Count(set)
    local n = 0
    for _ in pairs(set) do n = n + 1 end
    return n
end

-- Cases today (Config.Time.resetHour) in which this suspect scored for someone (maxCatchesPerSuspectDay).
function Opp.suspectDayCount(cid)
    if not ValidCid(cid) then return 0 end
    local start = DayStart(os.time())
    local runs = {}
    for _, r in ipairs(ledger.bySuspect[cid] or {}) do
        if r.scored and r.at >= start then runs[r.run or r] = true end
    end
    return Count(runs)
end

-- Cases today of this officer, of one kind ('live' | 'volunteer') or both (nil). Rows with outcome 'gone' (every
-- suspect gone before anyone arrived) are not counted.
function Opp.officerDayCount(cid, kind)
    if not ValidCid(cid) then return 0 end
    local start = DayStart(os.time())
    local runs = {}
    for _, r in ipairs(ledger.byOfficer[cid] or {}) do
        if (kind == nil or r.kind == kind) and r.outcome ~= 'gone' and r.at >= start then runs[r.run or r] = true end
    end
    return Count(runs)
end

-- Whether an admin excluded this player from being a suspect -> excluded, until.
function Opp.excluded(cid)
    local t = ValidCid(cid) and excludes[cid] or nil
    if t and t > os.time() then return true, t end
    return false
end

-- Whether an admin suspended this officer from real-suspect cases -> suspended, until.
function Opp.suspended(officerCid)
    local t = ValidCid(officerCid) and suspends[officerCid] or nil
    if t and t > os.time() then return true, t end
    return false
end

local function Days(days)
    days = tonumber(days)
    if not days or days ~= days or days <= 0 or days > MAX_ADMIN_DAYS then return nil end
    return math.max(60, math.floor(days * DAY_S))
end

local function AdminRow(kind, officer, suspect, seconds)
    local now = os.time()
    local untilAt = now + seconds
    Insert({ { kind = kind, officer = officer, suspect = suspect, scored = false, untilAt = untilAt, at = now } })
    return untilAt
end

-- Admin writers (V17): until os.time() + days. -> true, until | false, 'invalid_citizenid' | 'invalid_days'.
function Opp.block(officerCid, suspectCid, days)
    if not ValidCid(officerCid) or not ValidCid(suspectCid) or officerCid == suspectCid then
        return false, 'invalid_citizenid'
    end
    local seconds = Days(days)
    if not seconds then return false, 'invalid_days' end
    local untilAt = AdminRow('block', officerCid, suspectCid, seconds)
    Later(blocks, officerCid .. '|' .. suspectCid, untilAt)
    return true, untilAt
end

function Opp.exclude(cid, days)
    if not ValidCid(cid) then return false, 'invalid_citizenid' end
    local seconds = Days(days)
    if not seconds then return false, 'invalid_days' end
    local untilAt = AdminRow('exclude', '', cid, seconds)
    Later(excludes, cid, untilAt)
    return true, untilAt
end

function Opp.suspend(officerCid, days)
    if not ValidCid(officerCid) then return false, 'invalid_citizenid' end
    local seconds = Days(days)
    if not seconds then return false, 'invalid_days' end
    local untilAt = AdminRow('suspend', officerCid, '', seconds)
    Later(suspends, officerCid, untilAt)
    return true, untilAt
end

-- ============================================================================
--                             THE PAIR-REPEAT FLAG
-- ============================================================================

local function SamePerson(cidA, licA, cidB, licB) return cidA == cidB or (licA ~= nil and licA == licB) end

-- Cases (distinct runs) of this officer and suspect, by license (or citizenid), since `since`.
local function PairCases(row, since)
    local runs = {}
    for _, r in ipairs(ledger.rows) do
        if r.at >= since and r.outcome ~= 'gone'
            and SamePerson(r.officer, r.officerLicense, row.officer, row.officerLicense)
            and SamePerson(r.suspect, r.suspectLicense, row.suspect, row.suspectLicense) then
            runs[r.run or r] = true
        end
    end
    return Count(runs)
end

-- The second warning sign of a pair repeat (C27), or nil: a detain within fastCatchSeconds of the case start, a
-- suspect never armed who moved less than 30 m after contact, or a case shorter than 3 minutes.
local function SecondSign(case, rec)
    local fast = math.max(0, Num(Cfg().fastCatchSeconds, 60))
    if rec.detainedAt and case.openedMs and rec.detainedAt - case.openedMs <= fast * 1000 then
        return CP.L('opp.sign.fast_catch', { seconds = math.floor((rec.detainedAt - case.openedMs) / 1000) })
    end
    if not rec.everArmed and rec.contactAt and (rec.movedAfterContact or 0) < STILL_METRES then
        return CP.L('opp.sign.no_resistance', { metres = math.floor((rec.movedAfterContact or 0) + 0.5) })
    end
    local seconds = (case.closedAt or os.time()) - (case.openedAt or os.time())
    if seconds < SHORT_CASE_S then return CP.L('opp.sign.short_case', { seconds = math.max(0, seconds) }) end
    return nil
end

-- At a case's close, after recordPairs: each pair of this run that met pairFlag.count times in pairFlag.days (by
-- license) and shows a second sign flags 'rs_pair_repeat' on that officer (CP.AntiCheat.flag: his points only).
-- -> the flagged officers' citizenids.
function Opp.checkPairFlags(run)
    local case = CaseOf(run)
    if not case then return {} end
    local flag = type(Cfg().pairFlag) == 'table' and Cfg().pairFlag or {}
    local need = math.max(1, math.floor(Num(flag.count, 2)))
    local days = math.max(1, Num(flag.days, 7))
    local since = os.time() - math.floor(days * DAY_S)
    local out, done = {}, {}
    for _, row in ipairs(ledger.byRun[run.id] or {}) do
        local rec = case.suspects[row.suspect]
        if rec and not done[row.officer] then
            local n = PairCases(row, since)
            local sign = n >= need and SecondSign(case, rec) or nil
            if sign then
                done[row.officer] = true
                local officerSrc = nil
                for src, p in pairs(type(run.participants) == 'table' and run.participants or {}) do
                    if type(p) == 'table' and p.citizenid == row.officer then officerSrc = src end
                end
                local detail = CP.L('opp.detail.pair_repeat',
                    { label = rec.label, count = n, days = days, sign = sign })
                local ok, res = false, nil
                if officerSrc and CP.AntiCheat and CP.AntiCheat.flag then
                    ok, res = pcall(CP.AntiCheat.flag, run, officerSrc, 'rs_pair_repeat', detail)
                    if not ok then LogError('flag', 'CP.AntiCheat.flag failed: %s', tostring(res)) end
                end
                if ok and res then out[#out + 1] = row.officer end
                if type(case.timeline) == 'table' then
                    case.timeline[#case.timeline + 1] = {
                        t = os.time(),
                        what = 'pair_repeat',
                        label = rec.label,
                        src = officerSrc,
                        count = n,
                    }
                end
            end
        end
    end
    return out
end

-- The watch pass (Opp.onTick, only while a case is open): how far a free suspect got from where contact was made.
local function TrackContact(case)
    for _, cid in ipairs(case.order) do
        local rec = case.suspects[cid]
        if rec.state == 'free' and rec.contactAt and rec.src and rec.lastCoords and not rec.inInstance then
            if not rec.contactCoords then
                rec.contactCoords, rec.movedAfterContact = rec.lastCoords, 0
            else
                local d = CP.U.dist(rec.lastCoords, rec.contactCoords)
                if d > (rec.movedAfterContact or 0) then rec.movedAfterContact = d end
            end
        end
    end
end

-- ============================================================================
--                                  LIFECYCLE
-- ============================================================================

AddEventHandler('playerDropped', function()
    local src = source
    src = ToSrc(src)
    if src and (selfCache[src] or dutyOf[src] or deptOf[src]) then Gone(src) end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    selfCache, licOf, licCount, dutyOf, deptOf = {}, {}, 0, {}, {}
end)

CP.Hooks.on('run:ended', function(run)
    local case = CaseOf(run)
    if not case then return end
    local now = os.time()
    for _, cid in ipairs(case.order) do lastSuspect[cid] = now end
end)

CP.Hooks.on('settings:changed', function() Widen() end)

-- The other modules load in any order (fxmanifest globs): register once they are all loaded, then read the ledger.
CreateThread(function()
    Wait(0)
    local Q = CP.Qbx
    if Q and Q.onDutyChange then
        Q.onDutyChange(DutyChanged)
        Q.onJobChange(JobChanged)
        Q.onPlayerLoaded(function(src)
            src = ToSrc(src)
            if not src then return end
            selfCache[src] = nil   -- a character switch: the cached characters are read again
            local info = Info(src)
            local old = dutyOf[src] or deptOf[src]
            if old and (not info or info.citizenid ~= old) then Gone(src) end
            if info then Sync(src, info, false) end
        end)
        Q.onPlayerUnload(function(src)
            src = ToSrc(src)
            if src then Gone(src) end
        end)
    else
        CP.err(TAG, 'modules/integrations/qbx is missing: duty changes are not seen for real suspects')
    end
    if Opp.onTick then Opp.onTick(TrackContact) end
    if CP.Schedule and CP.Schedule.onDaily then
        CP.Schedule.onDaily(function() CreateThread(function() Prune(os.time()) end) end)
    end
    for _, src in ipairs(Q and Q.getOnlinePlayers and Q.getOnlinePlayers() or {}) do
        local info = Info(src)
        if info then Sync(src, info, true) end
    end
    if not DbReady() then return end
    local now = os.time()
    Prune(now)
    ledger.from = now - Window()
    LoadRows(ledger.from, nil)
    LoadAdmin(now)
end)

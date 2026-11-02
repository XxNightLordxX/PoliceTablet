-- CP.Opponents saved cases (server, step F1): each closed real-suspect case is saved in cp_pvp_cases while

CP.Opponents = CP.Opponents or {}
local Opp = CP.Opponents
local TAG = 'opponents'

local DAY_S = 86400
local CLOSED_KEPT = 16            -- the casesKept default (modules/opponents/server.lua)
local CLOSED_MAX = 200            -- casesKept is clamped to this
local TRIM_BATCH = 100            -- rows past casesKept removed per statement
local VERSION = 1                 -- the layout of case_json

local state = { loaded = false, loading = false }
local errorAt = {}

-- The suspect fields the staff views read (Opp.staffCase); the rest (positions, server ids, timers) stays out.
local REC_FIELDS = {
    'name',
    'label',
    'state',
    'outcome',
    'share',
    'everArmed',
    'afk',
    'down',
    'byLeave',
    'contactAt',
    'cuffedAt',
    'detainedAt',
    'bookedAt',
    'jailTime',
}

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Cfg() return Config.RealSuspects or {} end

local function Num(v, default)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return default end
    return v
end

local function ValidCid(cid)
    return type(cid) == 'string' and cid ~= '' and #cid <= 50 and cid:match('^[%w_%-]+$') ~= nil
end

local function ValidRunId(v)
    return type(v) == 'string' and #v > 0 and #v <= 36 and v:match('^[%w%-]+$') ~= nil
end

local function LogError(key, fmt, ...)
    local now = os.time()
    if errorAt[key] and now - errorAt[key] < 60 then return end
    errorAt[key] = now
    CP.err(TAG, fmt, ...)
end

local function FeatureOn()
    return (type(Config.LiveCrime) == 'table' and Config.LiveCrime.enabled == true)
        or (type(Config.Volunteers) == 'table' and Config.Volunteers.enabled == true)
end

-- Saved only while either feature is on and Config.RealSuspects.saveCases is not false.
local function On() return Cfg().saveCases ~= false and FeatureOn() end

local function Kept() return math.min(CLOSED_MAX, math.max(1, math.floor(Num(Cfg().casesKept, CLOSED_KEPT)))) end

local function DbReady()
    if not (CP.Migrations and CP.Migrations.ready) then return true end
    local ok = pcall(CP.Migrations.ready)
    return ok
end

local function Scalar(v)
    local t = type(v)
    if t == 'string' or t == 'boolean' then return v end
    if t == 'number' and v == v and v ~= math.huge and v ~= -math.huge then return v end
    return nil
end

local function Who(w)
    if type(w) ~= 'table' or not ValidCid(w.cid) then return nil end
    return { cid = w.cid, name = type(w.name) == 'string' and w.name or nil }
end

-- A timeline, note or ledger entry with its plain values only (who and byWho as { cid, name }, rules as a list).
local function Plain(e)
    local out = {}
    if type(e) ~= 'table' then return out end
    for k, v in pairs(e) do
        if type(k) == 'string' then
            if k == 'who' or k == 'byWho' then
                out[k] = Who(v)
            elseif k == 'rules' and type(v) == 'table' then
                local rules = {}
                for _, r in ipairs(v) do if type(r) == 'string' then rules[#rules + 1] = r end end
                out[k] = rules
            else
                out[k] = Scalar(v)
            end
        end
    end
    return out
end

local function PlainList(list)
    local out = {}
    for _, e in ipairs(type(list) == 'table' and list or {}) do out[#out + 1] = Plain(e) end
    return out
end

-- ============================================================================
--                           A CASE <-> ITS SAVED ROW
-- ============================================================================

-- The saved form of a closed case (case_json).
function Opp.savedForm(case)
    local run = type(case.run) == 'table' and case.run or {}
    local parts = {}
    for src, p in pairs(type(run.participants) == 'table' and run.participants or {}) do
        if type(p) == 'table' and ValidCid(p.citizenid) and math.tointeger(tonumber(src)) then
            parts[#parts + 1] = {
                src = math.tointeger(tonumber(src)),
                citizenid = p.citizenid,
                name = Scalar(p.name),
                callsign = Scalar(p.callsign),
                status = Scalar(p.status),
            }
        end
    end
    table.sort(parts, function(a, b) return a.src < b.src end)
    local suspects, order = {}, {}
    for _, cid in ipairs(case.order or {}) do
        local r = case.suspects[cid]
        if ValidCid(cid) and type(r) == 'table' then
            local rec = { notes = PlainList(r.notes) }
            for _, k in ipairs(REC_FIELDS) do rec[k] = Scalar(r[k]) end
            suspects[cid] = rec
            order[#order + 1] = cid
        end
    end
    local v = type(case.volunteer) == 'table' and case.volunteer or nil
    return {
        v = VERSION,
        runId = case.runId,
        kind = case.kind == 'volunteer' and 'volunteer' or 'live',
        index = Scalar(case.index),
        openedAt = Scalar(case.openedAt),
        closedAt = Scalar(case.closedAt),
        openedMs = Scalar(case.openedMs),
        crimeEnded = case.crimeEndedAt ~= nil,
        missionId = Scalar(run.missionId),
        participants = parts,
        order = order,
        suspects = suspects,
        timeline = PlainList(case.timeline),
        ledger = PlainList(case.ledger),
        volunteer = v and {
            role = Scalar(v.role),
            mode = Scalar(v.mode),
            phase = Scalar(v.phase),
            why = Scalar(v.why),
            engaged = v.engaged == true,
        } or nil,
    }
end

-- A saved case back as a closed case the staff views read -> { case, outcomes } | nil.
function Opp.fromSaved(d)
    if type(d) ~= 'table' or not ValidRunId(d.runId) then return nil end
    local participants = {}
    for _, p in ipairs(type(d.participants) == 'table' and d.participants or {}) do
        local src = type(p) == 'table' and math.tointeger(tonumber(p.src)) or nil
        if src and ValidCid(p.citizenid) then
            participants[src] = {
                src = src,
                citizenid = p.citizenid,
                name = type(p.name) == 'string' and p.name or nil,
                callsign = p.callsign,
                status = p.status,
            }
        end
    end
    local suspects, order, outcomes = {}, {}, {}
    local saved = type(d.suspects) == 'table' and d.suspects or {}
    for _, cid in ipairs(type(d.order) == 'table' and d.order or {}) do
        local r = saved[cid]
        if ValidCid(cid) and type(r) == 'table' and not suspects[cid] then
            local rec = { cid = cid, notes = type(r.notes) == 'table' and r.notes or {}, caughtBy = {}, near = {} }
            for _, k in ipairs(REC_FIELDS) do rec[k] = Scalar(r[k]) end
            suspects[cid] = rec
            order[#order + 1] = cid
            outcomes[cid] = rec.outcome
        end
    end
    if #order == 0 then return nil end
    local case = {
        runId = d.runId,
        kind = d.kind == 'volunteer' and 'volunteer' or 'live',
        index = math.tointeger(tonumber(d.index)) or 1,
        openedAt = math.floor(Num(d.openedAt, 0)),
        closedAt = math.floor(Num(d.closedAt, 0)),
        openedMs = Num(d.openedMs, 0),
        crimeEndedAt = d.crimeEnded == true and 0 or nil,
        run = { id = d.runId, missionId = d.missionId, state = 'ended', participants = participants, order = {} },
        suspects = suspects,
        order = order,
        timeline = type(d.timeline) == 'table' and d.timeline or {},
        ledger = type(d.ledger) == 'table' and d.ledger or {},
        trail = {},
        notes = {},
        volunteer = type(d.volunteer) == 'table' and d.volunteer or nil,
        restored = true,
    }
    return { case = case, outcomes = outcomes }
end

-- ============================================================================
--                                  THE TABLE
-- ============================================================================

-- Rows past the newest casesKept are removed (a smaller casesKept, or a case closed after the list was full).
local function TrimKept()
    local ok, rows = pcall(MySQL.query.await,
        ('SELECT run_uuid FROM cp_pvp_cases ORDER BY closed_at DESC, run_uuid DESC LIMIT %d OFFSET %d'):format(
            TRIM_BATCH, Kept()))
    if not ok then
        LogError('trim', 'reading the saved cases failed: %s', tostring(rows))
        return
    end
    local ids, marks = {}, {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        if type(r.run_uuid) == 'string' then
            ids[#ids + 1] = r.run_uuid
            marks[#marks + 1] = '?'
        end
    end
    if #ids == 0 then return end
    local okDel, err = pcall(MySQL.update.await,
        'DELETE FROM cp_pvp_cases WHERE run_uuid IN (' .. table.concat(marks, ', ') .. ')', ids)
    if not okDel then LogError('trim', 'removing old saved cases failed: %s', tostring(err)) end
end

local function Save(case)
    if not DbReady() then return end
    local okForm, form = pcall(Opp.savedForm, case)
    local okText, text = false, nil
    if okForm then okText, text = pcall(json.encode, form) end
    if not okText or type(text) ~= 'string' then
        LogError('save', 'run %s: the case could not be saved: %s', tostring(case.runId), tostring(text or form))
        return
    end
    local ok, err = pcall(MySQL.update.await, [[INSERT INTO cp_pvp_cases (run_uuid, kind, closed_at, case_json)
        VALUES (?, ?, FROM_UNIXTIME(?), ?) ON DUPLICATE KEY UPDATE kind = VALUES(kind), closed_at = VALUES(closed_at),
        case_json = VALUES(case_json)]], { case.runId, form.kind, math.floor(Num(case.closedAt, os.time())), text })
    if not ok then
        LogError('save', 'run %s: saving the case failed: %s', tostring(case.runId), tostring(err))
        return
    end
    TrimKept()
end

-- The newest casesKept saved cases into the closed list (oldest first).
local function Load()
    local ok, rows = pcall(MySQL.query.await,
        ('SELECT run_uuid, case_json FROM cp_pvp_cases ORDER BY closed_at DESC, run_uuid DESC LIMIT %d'):format(Kept()))
    if not ok then
        LogError('load', 'reading the saved cases failed: %s', tostring(rows))
        return false
    end
    local list = {}
    rows = type(rows) == 'table' and rows or {}
    for i = #rows, 1, -1 do
        local raw = rows[i].case_json
        local okJson, d = true, raw
        if type(raw) == 'string' then okJson, d = pcall(json.decode, raw) end
        local entry = okJson and Opp.fromSaved(d) or nil
        if entry and entry.case.runId == rows[i].run_uuid then
            list[#list + 1] = entry
        else
            LogError('decode', 'the saved case of run %s could not be read; it is left out', tostring(rows[i].run_uuid))
        end
    end
    if Opp.restoreClosed then Opp.restoreClosed(list) end
    if #list > 0 then CP.log(TAG, '%d saved case(s) read back', #list) end
    return true
end

-- Retention: rows older than Config.RealSuspects.pairLedgerDays (the case rows of cp_pvp_pairs keep as long) and
-- rows past casesKept. At the start and once a day, in a thread.
local function Prune(now)
    if not DbReady() then return end
    local cutoff = now - math.floor(math.max(1, Num(Cfg().pairLedgerDays, 30)) * DAY_S)
    local ok, err = pcall(MySQL.update.await, 'DELETE FROM cp_pvp_cases WHERE closed_at < FROM_UNIXTIME(?)', { cutoff })
    if not ok then LogError('prune', 'the saved cases clean-up failed: %s', tostring(err)) end
    TrimKept()
end

-- Once, the first time saving is on (the start, or an admin turning a feature on in Settings).
local function Start()
    if state.loaded or state.loading or not On() then return end
    state.loading = true
    CreateThread(function()
        if DbReady() then
            Prune(os.time())
            state.loaded = Load()
        end
        state.loading = false
    end)
end

-- A case just closed (Opp.close): saved one frame later, after every run:ended hook wrote its last line on it.
function Opp.onClosed(case)
    if type(case) ~= 'table' or case.restored or not ValidRunId(case.runId) or not On() then return end
    CreateThread(function()
        Wait(0)
        Save(case)
    end)
end

-- ============================================================================
--                                  LIFECYCLE
-- ============================================================================

CP.Hooks.on('settings:changed', function() Start() end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    state.loaded, state.loading = false, false
end)

CreateThread(function()
    Wait(0)
    if CP.Schedule and CP.Schedule.onDaily then
        CP.Schedule.onDaily(function()
            if On() then CreateThread(function() Prune(os.time()) end) end
        end)
    end
    Start()
end)

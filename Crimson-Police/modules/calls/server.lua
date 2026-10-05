-- CP.Calls (server): Hard rule 15, real calls first (docs/ARCHITECTURE.md §5.13, SPEC "Real calls end missions; NPC
-- calls never do", INTEGRATIONS sc-dispatch and sc-npcpolice).

CP.Calls = CP.Calls or {}
local C = CP.Calls
local TAG = 'calls'
local RECHECK_S = 10              -- isOnCall re-checks an entry in mdt_dispatch at most this often
local PRUNE_EVERY_MS = 60000

local responding = {}             -- responding[src][callKey] = { since, lastUpdate, checkedAt }
local aliases = {}                -- aliases[src][rawKey] = callKey (the id form sc-dispatch sent)
local seen = {}                   -- seen[src][rawKey] = os.time() of every non-NPC mark (real or not)
local freeAbandons = {}           -- freeAbandons[src] = { runId, citizenid, at, key, raw, missionId }
local abandonLog = {}             -- abandonLog[citizenid] = { ts, ... } free abandons in the last 24 h
local pendingMarks = {}           -- pendingMarks[src] = { { raw, unmarkedAt }, ... } marks still being looked up

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function ToSrc(src)
    local n = tonumber(src)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

local function Normalize(id)
    if CP.Dispatch and CP.Dispatch.normalizeCallId then
        local ok, key = pcall(CP.Dispatch.normalizeCallId, id)
        if ok and type(key) == 'string' then return key end
    end
    if id == nil then return '' end
    return tostring(id)
end

local function IsNpc(key)
    local prefix = Config.Calls.npcCallPrefix
    if type(prefix) ~= 'string' or prefix == '' then return false end
    return type(key) == 'string' and key:find(prefix, 1, true) == 1
end

local function Lookup(id)
    if not (CP.Dispatch and CP.Dispatch.lookupActiveCall) then return nil end
    local ok, uid = pcall(CP.Dispatch.lookupActiveCall, id)
    if not ok then
        CP.err(TAG, 'lookupActiveCall(%s) failed: %s', tostring(id), tostring(uid))
        return nil
    end
    if uid == nil then return nil end
    return uid
end

local function RunsCall(name, ...)
    if not (CP.Runs and type(CP.Runs[name]) == 'function') then return false, nil end
    local ok, a, b = pcall(CP.Runs[name], ...)
    if not ok then
        CP.err(TAG, 'CP.Runs.%s failed: %s', name, tostring(a))
        return false, nil
    end
    return true, a, b
end

local function Notify(src, kind, key, vars)
    if CP.Tablet and CP.Tablet.notify then pcall(CP.Tablet.notify, src, kind, key, vars) end
end

local function Audit(citizenid, action, runId, detail, reason)
    if not (CP.Admin and CP.Admin.audit) then
        CP.log(TAG, 'audit %s %s run %s: %s (%s)', tostring(citizenid), action, tostring(runId), tostring(detail),
            tostring(reason))
        return
    end
    CreateThread(function()
        local ok, err = pcall(CP.Admin.audit, citizenid, 'officer', 'flags', action, runId, nil, detail, reason)
        if not ok then CP.err(TAG, 'audit failed: %s', tostring(err)) end
    end)
end

-- A call about a participant of the same run (their person-down, dead, EMS or panic call).
local function AboutOwnRun(run, ...)
    local prefixes = Config.Calls.ownRunCallPrefixes
    if type(prefixes) ~= 'table' or type(run) ~= 'table' or type(run.participants) ~= 'table' then return false end
    local ids = { ... }
    for pSrc in pairs(run.participants) do
        local n = ToSrc(pSrc)
        if n then
            local tail = ('%d_'):format(n)
            for i = 1, #prefixes do
                local needle = tostring(prefixes[i]) .. tail
                for j = 1, #ids do
                    if type(ids[j]) == 'string' and ids[j]:find(needle, 1, true) == 1 then return true end
                end
            end
        end
    end
    return false
end

local function Record(src, key, raw, now)
    local bySrc = responding[src]
    if not bySrc then bySrc = {}; responding[src] = bySrc end
    local e = bySrc[key]
    if e then
        e.lastUpdate = now
        e.checkedAt = now
    else
        bySrc[key] = { since = now, lastUpdate = now, checkedAt = now }
    end
    if raw ~= key then
        local al = aliases[src]
        if not al then al = {}; aliases[src] = al end
        al[raw] = key
    end
end

local function RemoveEntry(src, key)
    local bySrc = responding[src]
    if bySrc then
        bySrc[key] = nil
        if next(bySrc) == nil then responding[src] = nil end
    end
end

local function CountFreeAbandons(citizenid, now)
    local list = abandonLog[citizenid]
    if not list then list = {}; abandonLog[citizenid] = list end
    local kept = {}
    for i = 1, #list do
        if now - list[i] < 86400 then kept[#kept + 1] = list[i] end
    end
    kept[#kept + 1] = now
    abandonLog[citizenid] = kept
    return #kept
end

-- ============================================================================
--                                  RESPONDING
-- ============================================================================
-- The free abandon becomes a normal one (the un-mark came within Config.Calls.dodgeWindow s).
local function Dodge(src, fa, at)
    CP.log(TAG, '%d un-marked %s within the dodge window: run %s becomes real_call_cancelled', src, tostring(fa.key),
        tostring(fa.runId))
    RunsCall('reclassify', fa.citizenid, fa.runId, 'real_call_cancelled')
    Notify(src, 'warning', 'calls.reclassified', { seconds = tonumber(Config.Calls.dodgeWindow) or 60 })
    Audit(fa.citizenid or src, 'real_call_cancelled', fa.runId, fa.key,
        ('un-marked real call %s after %d s'):format(fa.key, math.max(0, at - fa.at)))
end

-- unmarkedAt: the un-mark already arrived while the mark was being looked up.
local function EndForRealCall(run, src, p, key, raw, now, unmarkedAt)
    local citizenid = p.citizenid
    -- busy while CP.Runs.removeParticipant writes the row (it yields): an un-mark that arrives meanwhile is
    -- applied right after it, because CP.Runs.reclassify needs the written row.
    local fa = {
        runId = run.id,
        citizenid = citizenid,
        at = now,
        key = key,
        raw = raw,
        missionId = run.missionId,
        busy = true,
        cancelAt = unmarkedAt,
    }
    freeAbandons[src] = fa
    CP.log(TAG, '%d responds to real call %s: leaving run %s (real_call)', src, key, tostring(run.id))
    RunsCall('removeParticipant', run, src, 'real_call')
    fa.busy = false
    Notify(src, 'info', 'calls.run_ended')
    local n = citizenid and CountFreeAbandons(citizenid, now) or 1
    Audit(citizenid or src, 'free_abandon', run.id, key,
        ('free abandon on real call %s (mission %s; %d in the last 24 h)'):format(key, tostring(run.missionId), n))
    if fa.cancelAt then
        if freeAbandons[src] == fa then freeAbandons[src] = nil end
        Dodge(src, fa, fa.cancelAt)
    end
end

local function OnMarked(src, callId, raw, now)
    local s = seen[src]
    if not s then s = {}; seen[src] = s end
    s[raw] = now
    -- The lookup yields (database): an un-mark handled meanwhile is recorded on this pending mark.
    local mark = { raw = raw, unmarkedAt = nil }
    local list = pendingMarks[src]
    if not list then list = {}; pendingMarks[src] = list end
    list[#list + 1] = mark
    local uid = Lookup(callId)
    list = pendingMarks[src]
    if list then
        for i = #list, 1, -1 do if list[i] == mark then table.remove(list, i) end end
        if #list == 0 then pendingMarks[src] = nil end
    end
    if not uid then
        CP.log(TAG, 'responding %d -> %s ignored: not an active mdt_dispatch call', src, raw)
        return
    end
    local key = Normalize(uid)
    if key == '' or IsNpc(key) then return end
    local _, run, p = RunsCall('getBySrc', src)
    if type(run) == 'table' and AboutOwnRun(run, key, raw) then
        CP.log(TAG, 'responding %d -> %s: a call about their own run, not a real call for them', src, key)
        return
    end
    if not mark.unmarkedAt then
        Record(src, key, raw, now)
    end -- already un-marked: no responding entry
    if type(run) == 'table' and type(p) == 'table' and p.status == 'active' and run.state ~= 'ended' then
        EndForRealCall(run, src, p, key, raw, now, mark.unmarkedAt)
    end
end

local function OnUnmarked(src, raw, now)
    local al = aliases[src]
    local key = (al and al[raw]) or raw
    local known = (responding[src] and responding[src][key] ~= nil) or (seen[src] and seen[src][raw] ~= nil) or false
    -- A mark whose lookup is still running: this un-mark applies to it when it is the same id (or an id we
    -- cannot match, as below), so a quick on/off toggle cannot slip past the dodge rule.
    local pending = pendingMarks[src]
    if pending then
        for _, mark in ipairs(pending) do
            if (mark.raw == raw or not known) and not mark.unmarkedAt then mark.unmarkedAt = now end
        end
    end
    RemoveEntry(src, key)
    if al then al[raw] = nil end
    local fa = freeAbandons[src]
    if not fa then return end
    if now - fa.at > (tonumber(Config.Calls.dodgeWindow) or 60) then
        freeAbandons[src] = nil
        return
    end
    local same = fa.key == key or fa.key == raw or fa.raw == raw
    if not same and known then
        return
    end                                            -- un-marked a different call they had marked
    if fa.busy then                                -- the free abandon is still being written
        if not fa.cancelAt then fa.cancelAt = now end
        return
    end
    freeAbandons[src] = nil
    Dodge(src, fa, now)
end

local function OnResponding(src, callId, isResponding)
    local now = os.time()                           -- the listener thread starts when the event arrives
    src = ToSrc(src)
    if not src then return end
    local raw = Normalize(callId)
    if raw == '' or IsNpc(raw) then return end
    if isResponding then
        OnMarked(src, callId, raw, now)
    else
        OnUnmarked(src, raw, now)
    end
end

local function OnCallCleared(callId)
    local raw = Normalize(callId)
    if raw == '' then return end
    for src in pairs(aliases) do
        local al = aliases[src]
        local key = al[raw]
        if key then
            RemoveEntry(src, key)
            al[raw] = nil
        end
        for r, k in pairs(al) do
            if k == raw then al[r] = nil end
        end
        if next(al) == nil then aliases[src] = nil end
    end
    for src in pairs(responding) do RemoveEntry(src, raw) end
end

local function WipeAll()
    for k in pairs(responding) do responding[k] = nil end
    for k in pairs(aliases) do aliases[k] = nil end
    for k in pairs(seen) do seen[k] = nil end
end

-- ============================================================================
--                                  PUBLIC API
-- ============================================================================

function C.isOnCall(src)
    src = ToSrc(src)
    if not src then return false end
    local bySrc = responding[src]
    if not bySrc then return false end
    local expiry = tonumber(Config.Calls.respondingExpiry) or 1200
    local keys = {}
    for key in pairs(bySrc) do keys[#keys + 1] = key end
    local live = false
    for _, key in ipairs(keys) do
        local cur = responding[src]
        local e = cur and cur[key]
        if e then
            local now = os.time()
            if now - e.lastUpdate >= expiry then
                RemoveEntry(src, key)
            elseif now - (e.checkedAt or 0) >= RECHECK_S then
                local uid = Lookup(key)
                local after = responding[src]
                if after and after[key] == e then
                    if uid then
                        e.checkedAt = os.time()
                        live = true
                    else
                        CP.log(TAG, 'call %s of %d is no longer active', key, src)
                        RemoveEntry(src, key)
                    end
                end
            else
                live = true
            end
        end
    end
    return live
end

-- ============================================================================
--                                 HOUSEKEEPING
-- ============================================================================

local function Prune()
    local now = os.time()
    local expiry = tonumber(Config.Calls.respondingExpiry) or 1200
    for src, bySrc in pairs(responding) do
        for key, e in pairs(bySrc) do
            if now - e.lastUpdate >= expiry then bySrc[key] = nil end
        end
        if next(bySrc) == nil then responding[src] = nil end
    end
    for src, s in pairs(seen) do
        for raw, at in pairs(s) do
            if now - at >= expiry then s[raw] = nil end
        end
        if next(s) == nil then seen[src] = nil end
    end
    local window = tonumber(Config.Calls.dodgeWindow) or 60
    for src, fa in pairs(freeAbandons) do
        if now - fa.at > window then freeAbandons[src] = nil end
    end
    for cid, list in pairs(abandonLog) do
        if #list == 0 or now - list[#list] >= 86400 then abandonLog[cid] = nil end
    end
end

AddEventHandler('playerDropped', function()
    local src = ToSrc(source)
    if not src then return end
    responding[src] = nil
    aliases[src] = nil
    seen[src] = nil
    freeAbandons[src] = nil
    pendingMarks[src] = nil
end)

CreateThread(function()
    Wait(0)
    if not CP.Dispatch then
        CP.err(TAG, 'modules/integrations/sc_dispatch is missing: real calls cannot end runs')
        return
    end
    CP.Dispatch.onResponding(OnResponding)
    CP.Dispatch.onCallCleared(OnCallCleared)
    CP.Dispatch.onDispatchRestart(function()
        CP.log(TAG, 'sc-dispatch restarted: every responding entry is dropped')
        WipeAll()
    end)
    while true do
        Wait(PRUNE_EVERY_MS)
        local ok, err = pcall(Prune)
        if not ok then CP.err(TAG, 'prune failed: %s', tostring(err)) end
    end
end)

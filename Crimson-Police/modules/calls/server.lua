-- modules/calls/server.lua · CP.Calls (server): Hard rule 15, real calls first
-- (docs/ARCHITECTURE.md §5.13, SPEC "Real calls end missions; NPC calls never do", INTEGRATIONS sc-dispatch
-- and sc-npcpolice).
--
-- Owns: the responding map (who is responding to which real call), the free abandon on a real call, the
-- 60-second dodge rule and the "On a call" answer the Mission Board and accept checks use. Everything comes
-- through CP.Dispatch listeners (onResponding / onCallCleared / onDispatchRestart); this file never talks to
-- sc-dispatch itself and never creates, clears or blocks a dispatch call.
--
-- Public API
--   CP.Calls.isOnCall(src) -> boolean
--       A live real-call responding entry: updated less than Config.Calls.respondingExpiry s ago and still
--       active in mdt_dispatch (entries are re-checked with CP.Dispatch.lookupActiveCall at most every 10 s
--       and dropped when inactive: sc-dispatch's 5-minute auto-clear fires no event). May yield (database).
--
-- Classification of a ToggleResponding (src, callId, isResponding), in this order:
--   1. The id is normalised with CP.Dispatch.normalizeCallId. An id starting with Config.Calls.npcCallPrefix
--      (plain find at position 1, never a pattern) is an SC-NPCPolice call: nothing happens at all (no run
--      end, no entry, no free abandon, no dodge rule).
--   2. Marking: only a hit from CP.Dispatch.lookupActiveCall counts (an unknown, inactive or faked id does
--      nothing); the canonical id it returns is checked against the NPC prefix again.
--   3. If the sender is on a run, an id that is one of Config.Calls.ownRunCallPrefixes followed by the server
--      id of ANY participant of that same run (partners who already left included) and '_' (plain find at
--      position 1) is a call about their own run and does not count for them.
--   4. Otherwise it is a real call: responding[src][id] = { since, lastUpdate }. An active participant is
--      removed with CP.Runs.removeParticipant(run, src, 'real_call') (the rest of the unit carries on; no
--      penalty, no cooldown), gets the toast calls.run_ended, and the free abandon is remembered
--      { runId, citizenid, at } and written to the audit log (category 'flags', action 'free_abandon').
--   Un-marking: the entry goes; within Config.Calls.dodgeWindow s of that free abandon, an un-mark of the
--   same call (or of an id the sender never marked, so a different id form cannot slip through) turns it into
--   a normal abandon: CP.Runs.reclassify(citizenid, runId, 'real_call_cancelled') (audited, toast
--   calls.reclassified). Listeners run in their own threads and the mark yields twice (the mdt_dispatch
--   lookup, then the row write in removeParticipant): an un-mark that arrives during either wait is kept and
--   applied once the free abandon is written, so a quick on/off toggle cannot keep it free.
-- callClearedByOfficer removes that call for everyone; playerDropped removes the player's entries; an
-- sc-dispatch restart wipes every entry (sc-dispatch deactivates every call when it starts or stops).

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

-- ── helpers ─────────────────────────────────────────────────────────────────
local function toSrc(src)
    local n = tonumber(src)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

local function normalize(id)
    if CP.Dispatch and CP.Dispatch.normalizeCallId then
        local ok, key = pcall(CP.Dispatch.normalizeCallId, id)
        if ok and type(key) == 'string' then return key end
    end
    if id == nil then return '' end
    return tostring(id)
end

local function isNpc(key)
    local prefix = Config.Calls.npcCallPrefix
    if type(prefix) ~= 'string' or prefix == '' then return false end
    return type(key) == 'string' and key:find(prefix, 1, true) == 1
end

local function lookup(id)
    if not (CP.Dispatch and CP.Dispatch.lookupActiveCall) then return nil end
    local ok, uid = pcall(CP.Dispatch.lookupActiveCall, id)
    if not ok then
        CP.err(TAG, 'lookupActiveCall(%s) failed: %s', tostring(id), tostring(uid))
        return nil
    end
    if uid == nil then return nil end
    return uid
end

local function runsCall(name, ...)
    if not (CP.Runs and type(CP.Runs[name]) == 'function') then return false, nil end
    local ok, a, b = pcall(CP.Runs[name], ...)
    if not ok then
        CP.err(TAG, 'CP.Runs.%s failed: %s', name, tostring(a))
        return false, nil
    end
    return true, a, b
end

local function notify(src, kind, key, vars)
    if CP.Tablet and CP.Tablet.notify then pcall(CP.Tablet.notify, src, kind, key, vars) end
end

local function audit(citizenid, action, runId, detail, reason)
    if not (CP.Admin and CP.Admin.audit) then
        CP.log(TAG, 'audit %s %s run %s: %s (%s)', tostring(citizenid), action, tostring(runId), tostring(detail), tostring(reason))
        return
    end
    CreateThread(function()
        local ok, err = pcall(CP.Admin.audit, citizenid, 'officer', 'flags', action, runId, nil, detail, reason)
        if not ok then CP.err(TAG, 'audit failed: %s', tostring(err)) end
    end)
end

-- A call about a participant of the same run (their person-down, dead, EMS or panic call).
local function aboutOwnRun(run, ...)
    local prefixes = Config.Calls.ownRunCallPrefixes
    if type(prefixes) ~= 'table' or type(run) ~= 'table' or type(run.participants) ~= 'table' then return false end
    local ids = { ... }
    for pSrc in pairs(run.participants) do
        local n = toSrc(pSrc)
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

local function record(src, key, raw, now)
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

local function removeEntry(src, key)
    local bySrc = responding[src]
    if bySrc then
        bySrc[key] = nil
        if next(bySrc) == nil then responding[src] = nil end
    end
end

local function countFreeAbandons(citizenid, now)
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

-- ── responding ──────────────────────────────────────────────────────────────
-- The free abandon becomes a normal one (the un-mark came within Config.Calls.dodgeWindow s).
local function dodge(src, fa, at)
    CP.log(TAG, '%d un-marked %s within the dodge window: run %s becomes real_call_cancelled', src, tostring(fa.key), tostring(fa.runId))
    runsCall('reclassify', fa.citizenid, fa.runId, 'real_call_cancelled')
    notify(src, 'warning', 'calls.reclassified', { seconds = tonumber(Config.Calls.dodgeWindow) or 60 })
    audit(fa.citizenid or src, 'real_call_cancelled', fa.runId, fa.key,
        ('un-marked real call %s after %d s'):format(fa.key, math.max(0, at - fa.at)))
end

-- unmarkedAt: the un-mark already arrived while the mark was being looked up.
local function endForRealCall(run, src, p, key, raw, now, unmarkedAt)
    local citizenid = p.citizenid
    -- busy while CP.Runs.removeParticipant writes the row (it yields): an un-mark that arrives meanwhile is
    -- applied right after it, because CP.Runs.reclassify needs the written row.
    local fa = { runId = run.id, citizenid = citizenid, at = now, key = key, raw = raw, missionId = run.missionId,
        busy = true, cancelAt = unmarkedAt }
    freeAbandons[src] = fa
    CP.log(TAG, '%d responds to real call %s: leaving run %s (real_call)', src, key, tostring(run.id))
    runsCall('removeParticipant', run, src, 'real_call')
    fa.busy = false
    notify(src, 'info', 'calls.run_ended')
    local n = citizenid and countFreeAbandons(citizenid, now) or 1
    audit(citizenid or src, 'free_abandon', run.id, key,
        ('free abandon on real call %s (mission %s; %d in the last 24 h)'):format(key, tostring(run.missionId), n))
    if fa.cancelAt then
        if freeAbandons[src] == fa then freeAbandons[src] = nil end
        dodge(src, fa, fa.cancelAt)
    end
end

local function onMarked(src, callId, raw, now)
    local s = seen[src]
    if not s then s = {}; seen[src] = s end
    s[raw] = now
    -- The lookup yields (database): an un-mark handled meanwhile is recorded on this pending mark.
    local mark = { raw = raw, unmarkedAt = nil }
    local list = pendingMarks[src]
    if not list then list = {}; pendingMarks[src] = list end
    list[#list + 1] = mark
    local uid = lookup(callId)
    list = pendingMarks[src]
    if list then
        for i = #list, 1, -1 do if list[i] == mark then table.remove(list, i) end end
        if #list == 0 then pendingMarks[src] = nil end
    end
    if not uid then
        CP.log(TAG, 'responding %d -> %s ignored: not an active mdt_dispatch call', src, raw)
        return
    end
    local key = normalize(uid)
    if key == '' or isNpc(key) then return end
    local _, run, p = runsCall('getBySrc', src)
    if type(run) == 'table' and aboutOwnRun(run, key, raw) then
        CP.log(TAG, 'responding %d -> %s: a call about their own run, not a real call for them', src, key)
        return
    end
    if not mark.unmarkedAt then record(src, key, raw, now) end   -- already un-marked: no responding entry
    if type(run) == 'table' and type(p) == 'table' and p.status == 'active' and run.state ~= 'ended' then
        endForRealCall(run, src, p, key, raw, now, mark.unmarkedAt)
    end
end

local function onUnmarked(src, raw, now)
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
    removeEntry(src, key)
    if al then al[raw] = nil end
    local fa = freeAbandons[src]
    if not fa then return end
    if now - fa.at > (tonumber(Config.Calls.dodgeWindow) or 60) then
        freeAbandons[src] = nil
        return
    end
    local same = fa.key == key or fa.key == raw or fa.raw == raw
    if not same and known then return end          -- un-marked a different call they had marked
    if fa.busy then                                -- the free abandon is still being written
        if not fa.cancelAt then fa.cancelAt = now end
        return
    end
    freeAbandons[src] = nil
    dodge(src, fa, now)
end

local function onResponding(src, callId, isResponding)
    local now = os.time()                           -- the listener thread starts when the event arrives
    src = toSrc(src)
    if not src then return end
    local raw = normalize(callId)
    if raw == '' or isNpc(raw) then return end
    if isResponding then
        onMarked(src, callId, raw, now)
    else
        onUnmarked(src, raw, now)
    end
end

local function onCallCleared(callId)
    local raw = normalize(callId)
    if raw == '' then return end
    for src in pairs(aliases) do
        local al = aliases[src]
        local key = al[raw]
        if key then
            removeEntry(src, key)
            al[raw] = nil
        end
        for r, k in pairs(al) do
            if k == raw then al[r] = nil end
        end
        if next(al) == nil then aliases[src] = nil end
    end
    for src in pairs(responding) do removeEntry(src, raw) end
end

local function wipeAll()
    for k in pairs(responding) do responding[k] = nil end
    for k in pairs(aliases) do aliases[k] = nil end
    for k in pairs(seen) do seen[k] = nil end
end

-- ── public API ──────────────────────────────────────────────────────────────
function C.isOnCall(src)
    src = toSrc(src)
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
                removeEntry(src, key)
            elseif now - (e.checkedAt or 0) >= RECHECK_S then
                local uid = lookup(key)
                local after = responding[src]
                if after and after[key] == e then
                    if uid then
                        e.checkedAt = os.time()
                        live = true
                    else
                        CP.log(TAG, 'call %s of %d is no longer active', key, src)
                        removeEntry(src, key)
                    end
                end
            else
                live = true
            end
        end
    end
    return live
end

-- ── housekeeping ────────────────────────────────────────────────────────────
local function prune()
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
    local src = toSrc(source)
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
    CP.Dispatch.onResponding(onResponding)
    CP.Dispatch.onCallCleared(onCallCleared)
    CP.Dispatch.onDispatchRestart(function()
        CP.log(TAG, 'sc-dispatch restarted: every responding entry is dropped')
        wipeAll()
    end)
    while true do
        Wait(PRUNE_EVERY_MS)
        local ok, err = pcall(prune)
        if not ok then CP.err(TAG, 'prune failed: %s', tostring(err)) end
    end
end)

-- CP.Alerts (server): Hard rule 16 (no mission alerts) and the only writer of the crimsonArena state bag
-- (docs/ARCHITECTURE.md §5.14, docs/CRIMSON_ARENA.md rules 1, 2, 3, 9, 11).

CP.Alerts = CP.Alerts or {}
local A = CP.Alerts
local TAG = 'alerts'
local BAG_KEY = 'crimsonArena'
local OURS = 'crimson-police'
local REASSERT_GAP_MS = 250       -- at most one re-assert per src per 250 ms
local ORPHAN_GRACE_MS = 3000      -- an intent whose run no longer wants it is dropped after this long
local RECENT_CLEAR_S = 15         -- a backstop id is cleared once within this window

local wanted = {}                 -- wanted[src] = { runId, setAt, logged }
local holds = {}                  -- holds[src] = true while CP.Downed keeps a downed participant's flag
local lastKind = {}               -- last observed kind of the live value: 'ours' | 'foreign' | 'other'
local foreignCleared = {}         -- foreignCleared[src] = os.time()
local lastReassertAt = {}         -- GetGameTimer() of the last re-assert per src
local reassertQueued = {}
local orphanSince = {}
local arenaHandled = {}           -- arenaHandled[src] = runId already handled
local arenaListeners = {}
local recentClears = {}           -- recentClears[uniqueId] = os.time()
local stale = {}                  -- stale[src] = true: our value outlived a forgotten intent (SweepStale)

A.wanted = wanted
A.foreignClearedAt = foreignCleared

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

local function Connected(src)
    local ok, name = pcall(GetPlayerName, src)
    return ok and type(name) == 'string' and name ~= ''
end

local function BagValue(src)
    local ok, v = pcall(function() return Player(src).state[BAG_KEY] end)
    if ok then return v end
    return nil
end

-- 'none' | 'ours' | 'foreign' | 'other'
local function Classify(v)
    if v == nil then return 'none' end
    if type(v) == 'table' then
        if v.source == OURS then return 'ours' end
        if v.active == true then return 'foreign' end
    end
    return 'other'
end

local function BucketOf(src)
    if type(GetPlayerRoutingBucket) ~= 'function' then return 0 end
    local ok, b = pcall(GetPlayerRoutingBucket, src)
    if not ok then return 0 end
    return tonumber(b) or 0
end

local function WriteOurs(src)
    local ok, err = pcall(function()
        Player(src).state:set(BAG_KEY, { active = true, source = OURS }, true)
    end)
    if not ok then
        CP.err(TAG, 'could not set the crimsonArena flag for %d: %s', src, tostring(err))
        return false
    end
    lastKind[src] = 'ours'
    return true
end

local function RemoveOurs(src)
    local ok, err = pcall(function()
        Player(src).state:set(BAG_KEY, nil, true)
    end)
    if not ok then
        CP.err(TAG, 'could not remove the crimsonArena flag of %d: %s', src, tostring(err))
        return false
    end
    lastKind[src] = nil
    return true
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

local function ResolveRunId(src, runRef)
    if type(runRef) == 'table' and runRef.id ~= nil then return runRef.id end
    if type(runRef) == 'string' and runRef ~= '' then return runRef end
    local _, run = RunsCall('getBySrc', src)
    if type(run) == 'table' then return run.id end
    return nil
end

local function ActiveSrcs(run)
    local out = {}
    if type(run) ~= 'table' then return out end
    if CP.Runs and type(CP.Runs.activeSrcs) == 'function' then
        local ok, list = pcall(CP.Runs.activeSrcs, run)
        if ok and type(list) == 'table' then return list end
    end
    for src, p in pairs(run.participants or {}) do
        if type(p) == 'table' and p.status == 'active' then out[#out + 1] = src end
    end
    table.sort(out)
    return out
end

local function IsDownedPending(src)
    if not (CP.Downed and CP.Downed.isPending) then return false end
    local ok, pending = pcall(CP.Downed.isPending, src)
    if ok and pending then return true end
    return false
end

local function ServerCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local ok, c = pcall(GetEntityCoords, ped)
    if ok then return c end
    return nil
end

-- Remember kind transitions; a foreign value that turned into nil is Crimson-Arena letting go.
-- prevKind is the value the change handler saw before the change (FiveM calls the handler before the
-- value is set), so an exit is recorded even when this module never saw the foreign value itself
-- (e.g. Crimson-Police restarted while the player was in a match).
local function Observe(src, kind, prevKind)
    local prev = lastKind[src]
    if (prev == 'foreign' or prevKind == 'foreign') and kind == 'none' then
        foreignCleared[src] = os.time()
        CP.log(TAG, 'foreign crimsonArena value of %d was removed', src)
    end
    if kind == 'none' then lastKind[src] = nil else lastKind[src] = kind end
end

-- ============================================================================
--                                  PUBLIC API
-- ============================================================================

function A.foreignFlag(src)
    src = ToSrc(src)
    if not src then return false end
    return Classify(BagValue(src)) == 'foreign'
end

function A.inArena(src)
    src = ToSrc(src)
    if not src then return false end
    if Classify(BagValue(src)) == 'foreign' then return true end
    return BucketOf(src) ~= 0
end

function A.has(src)
    src = ToSrc(src)
    return src ~= nil and wanted[src] ~= nil
end

function A.hold(src, on)
    src = ToSrc(src)
    if not src then return end
    holds[src] = on and true or nil
end

function A.onInArena(fn)
    if type(fn) ~= 'function' then
        CP.warn(TAG, 'onInArena needs a function (got %s)', type(fn))
        return
    end
    arenaListeners[#arenaListeners + 1] = fn
end

function A.set(src, runRef)
    src = ToSrc(src)
    if not src then return false end
    if BucketOf(src) ~= 0 then
        CP.log(TAG, 'set %d refused: routing bucket %d', src, BucketOf(src))
        return false
    end
    local kind = Classify(BagValue(src))
    if kind == 'foreign' or kind == 'other' then
        CP.log(TAG, 'set %d refused: the crimsonArena value belongs to another resource', src)
        return false
    end
    local runId = ResolveRunId(src, runRef)
    local w = wanted[src]
    if not w or w.runId ~= runId then
        w = { runId = runId, setAt = os.time(), logged = false }
        wanted[src] = w
    end
    orphanSince[src] = nil
    stale[src] = nil
    if kind ~= 'ours' then
        if not WriteOurs(src) then return false end
        CP.log(TAG, 'flag set for %d (run %s)', src, tostring(runId))
    end
    return true
end

function A.clear(src, opts)
    src = ToSrc(src)
    if not src then return false end
    local force = type(opts) == 'table' and opts.force == true
    if holds[src] and not force then
        CP.log(TAG, 'clear %d ignored: the flag is held for a downed participant', src)
        return false
    end
    if force then holds[src] = nil end
    wanted[src] = nil
    orphanSince[src] = nil
    reassertQueued[src] = nil
    stale[src] = nil
    if Classify(BagValue(src)) == 'ours' then
        local removed = RemoveOurs(src)
        if removed then CP.log(TAG, 'flag cleared for %d', src) end
        return removed
    end
    return false
end

-- ============================================================================
--                       RE-ASSERT (CRIMSON_ARENA rule 2)
-- ============================================================================

local function Reassert(src)
    reassertQueued[src] = nil
    local w = wanted[src]
    if not w then return end
    if not Connected(src) then return end
    if BucketOf(src) ~= 0 then
        return
    end -- in an arena bucket: the in-arena handling takes over
    local kind = Classify(BagValue(src))
    if kind ~= 'none' then
        return
    end -- ours already, or someone else's: never overwrite
    lastReassertAt[src] = GetGameTimer()
    if WriteOurs(src) and not w.logged then
        w.logged = true
        CP.warn(TAG, 'the crimsonArena flag of %d (run %s) was removed by another resource; re-asserted', src,
            tostring(w.runId))
    end
end

-- Called from queued work (never from inside the change handler): re-assert now, or once the 250 ms
-- since the last re-assert of this src have passed.
local function QueueReassert(src)
    if reassertQueued[src] then return end
    local delay = 0
    local last = lastReassertAt[src]
    if last then
        local since = GetGameTimer() - last
        if since < REASSERT_GAP_MS then delay = REASSERT_GAP_MS - since end
    end
    if delay <= 0 then
        Reassert(src)
        return
    end
    reassertQueued[src] = true
    SetTimeout(delay, function() Reassert(src) end)
end

-- ============================================================================
--           PARTICIPANTS WHO BECOME IN-ARENA (CRIMSON_ARENA rule 1)
-- ============================================================================

local function ForgetIntent(src)
    wanted[src] = nil
    holds[src] = nil
    orphanSince[src] = nil
    reassertQueued[src] = nil
    -- the bag stays; SweepStale removes our value later
    if Classify(BagValue(src)) == 'ours' then stale[src] = true end
end

function A.forget(src)
    src = ToSrc(src)
    if not src then return false end
    local had = wanted[src] ~= nil or holds[src] ~= nil
    ForgetIntent(src)
    if had then CP.log(TAG, 'intent of %d forgotten (the crimsonArena value is left alone)', src) end
    return had
end

local function HandleInArena(run, src)
    if type(run) ~= 'table' or run.id == nil then return end
    if arenaHandled[src] == run.id then return end
    local p = run.participants and run.participants[src]
    if not p or p.status ~= 'active' or run.state == 'ended' then return end
    arenaHandled[src] = run.id
    CP.log(TAG, '%d is in the arena: leaving run %s', src, tostring(run.id))
    ForgetIntent(src) -- the bag itself is left alone (it is not ours now)
    if CP.Route and CP.Route.stop then pcall(CP.Route.stop, run, src) end
    if CP.Downed and CP.Downed.cancel then pcall(CP.Downed.cancel, src, 'in_arena') end
    CreateThread(function()
        local cur = run.participants and run.participants[src]
        if cur and cur.status == 'active' and run.state ~= 'ended' then
            RunsCall('removeParticipant', run, src, 'quit', { notify = 'run.left_for_arena' })
        end
        for i = 1, #arenaListeners do
            local ok, err = pcall(arenaListeners[i], src, run)
            if not ok then CP.err(TAG, 'onInArena listener failed: %s', tostring(err)) end
        end
    end)
end

-- A foreign value appeared: an active participant leaves; a downed one loses the pending pick-up/EMS.
local function CheckArena(src)
    local _, run = RunsCall('getBySrc', src)
    if type(run) == 'table' then
        HandleInArena(run, src)
        return
    end
    if wanted[src] then
        ForgetIntent(src)
        if CP.Downed and CP.Downed.cancel then pcall(CP.Downed.cancel, src, 'in_arena') end
    end
end

-- ============================================================================
--                  STATE BAG CHANGE HANDLER: queue work only
-- ============================================================================

local function OnBagChange(src, kind, prevKind)
    Observe(src, kind, prevKind)
    if kind == 'none' then
        if wanted[src] then QueueReassert(src) end
    elseif kind == 'foreign' then
        CheckArena(src)
    end
end

if type(AddStateBagChangeHandler) == 'function' then
    AddStateBagChangeHandler(BAG_KEY, nil, function(bagName, _, value)
        local ok, src = pcall(GetPlayerFromStateBagName, bagName)
        src = ok and ToSrc(src) or nil
        if not src then return end
        local kind = Classify(value)
        local prevKind = Classify(BagValue(src)) -- read only: the old value (not set yet)
        SetTimeout(0, function() OnBagChange(src, kind, prevKind) end)
    end)
else
    CP.err(TAG, 'AddStateBagChangeHandler is not available: only the 1 s reconcile watches the crimsonArena flag')
end

-- ============================================================================
--                                1 S RECONCILE
-- ============================================================================

local function StillWanted(src, w)
    if holds[src] or IsDownedPending(src) then return true end
    if not (CP.Runs and CP.Runs.get) then return true end
    local run
    if w.runId ~= nil then
        local _, r = RunsCall('get', w.runId)
        run = r
    end
    if type(run) ~= 'table' then
        local _, r = RunsCall('getBySrc', src)
        if type(r) == 'table' then
            w.runId = r.id
            return true
        end
        return false
    end
    if run.state == 'ended' then return false end
    local p = run.participants and run.participants[src]
    return type(p) == 'table' and p.status == 'active'
end

-- Rule 1 leaves our value on a participant who left only because the routing bucket moved (an interior, another
-- instancing script). Back in bucket 0 with no intent, hold or downed follow-up it goes, or sc-ambulance and
-- sc-dispatch would stay muted for them (SPEC: removed when the run ends for any reason). Never a foreign value.
local function SweepStale()
    local srcs = {}
    for src in pairs(stale) do srcs[#srcs + 1] = src end
    for _, src in ipairs(srcs) do
        if wanted[src] or not Connected(src) or Classify(BagValue(src)) ~= 'ours' then
            stale[src] = nil
        elseif BucketOf(src) == 0 and not holds[src] and not IsDownedPending(src) then
            stale[src] = nil
            if RemoveOurs(src) then CP.log(TAG, 'flag of %d removed: it outlived its run in another bucket', src) end
        end
    end
end

-- arena:exited (CP.Hooks): once when a player's A.inArena turns from true to false, whether the foreign flag
-- cleared or the routing bucket went back to 0, and never while either still holds.
local wasInArena = {}

local function ArenaExits()
    local seen = {}
    for _, s in ipairs(GetPlayers() or {}) do
        local src = ToSrc(s)
        if src then
            seen[src] = true
            local now = A.inArena(src)
            if wasInArena[src] and not now then
                CP.log(TAG, '%d left the arena', src)
                if CP.Hooks and CP.Hooks.fire then CP.Hooks.fire('arena:exited', src) end
            end
            wasInArena[src] = now or nil
        end
    end
    for src in pairs(wasInArena) do
        if not seen[src] then wasInArena[src] = nil end
    end
end
A._arenaExits = ArenaExits

local function Reconcile()
    ArenaExits()
    local nowMs = GetGameTimer()
    local srcs = {}
    for src in pairs(wanted) do srcs[#srcs + 1] = src end
    for _, src in ipairs(srcs) do
        local w = wanted[src]
        if w then
            if not Connected(src) then
                ForgetIntent(src)
            else
                local kind = Classify(BagValue(src))
                Observe(src, kind)
                if kind == 'none' then
                    QueueReassert(src)
                elseif kind == 'foreign' then
                    CheckArena(src)
                end
                if wanted[src] then
                    if StillWanted(src, w) then
                        orphanSince[src] = nil
                    elseif not orphanSince[src] then
                        orphanSince[src] = nowMs
                    elseif nowMs - orphanSince[src] >= ORPHAN_GRACE_MS then
                        CP.warn(TAG, 'flag of %d outlived run %s; removed', src, tostring(w.runId))
                        A.clear(src)
                    end
                end
            end
        end
    end
    -- every active participant of every run: in the arena -> leave the run
    local _, runs = RunsCall('all')
    if type(runs) == 'table' then
        for _, run in ipairs(runs) do
            if type(run) == 'table' and run.state ~= 'ended' then
                for _, src in ipairs(ActiveSrcs(run)) do
                    if A.inArena(src) then HandleInArena(run, src) end
                end
            end
        end
    end
    SweepStale()
    local now = os.time()
    for id, at in pairs(recentClears) do
        if now - at > RECENT_CLEAR_S then recentClears[id] = nil end
    end
end

-- ============================================================================
--                       BACKSTOP (CRIMSON_ARENA rule 9)
-- ============================================================================

local function DelayMs()
    local s = tonumber(Config.Alerts and Config.Alerts.backstopDelay) or 1
    if s < 0 then s = 0 end
    return math.floor(s * 1000)
end

-- An id of second s can only be created during second s (plus a few ms for sc-dispatch's unawaited
-- unique_id update), so an earlier clear of it only counts once it ran at s + 2 or later. A clear that ran
-- sooner (e.g. the t + 1 id of the previous second's event) may have come before the call existed.
local function ClearIds(fmt, src, t, jobs)
    if not (CP.Dispatch and CP.Dispatch.clearNotification) then return end
    local now = os.time()
    for dt = -1, 1 do
        local s = t + dt
        local id = fmt:format(src, s)
        local doneAt = recentClears[id]
        if not (doneAt and doneAt >= s + 2) then
            recentClears[id] = now
            local ok, err = pcall(CP.Dispatch.clearNotification, id, jobs)
            if not ok then CP.err(TAG, 'clearNotification(%s) failed: %s', id, tostring(err)) end
        end
    end
end

local function NearMission(run, coords)
    local radius = tonumber(Config.Alerts and Config.Alerts.backstopRadius) or 0
    local start = type(run.location) == 'table' and run.location.start or nil
    if type(start) == 'table' and start.coords and CP.U.dist(coords, start.coords) <= radius then return true end
    if CP.Runs and CP.Runs.anchor then
        local ok, anchor = pcall(CP.Runs.anchor, run)
        if ok and anchor ~= nil and CP.U.dist(coords, anchor) <= radius then return true end
    end
    return false
end

local function OnShotsFired(src, _, receivedAt)
    local t = math.tointeger(tonumber(receivedAt) or os.time()) or os.time()
    src = ToSrc(src)
    if not src then return end
    if A.foreignFlag(src) then return end
    local run
    local _, r, p = RunsCall('getBySrc', src)
    if type(r) == 'table' and type(p) == 'table' and r.state == 'in_progress' and p.arrived then
        run = r
    elseif wanted[src] and wanted[src].runId ~= nil then
        local _, r2 = RunsCall('get', wanted[src].runId)
        if type(r2) == 'table' then run = r2 end
    end
    if not run then return end
    local coords = ServerCoords(src)
    if not coords or not NearMission(run, coords) then return end
    Wait(DelayMs())
    ClearIds('shots_%d_%d', src, t, { 'police' })
end

local function DownListener(prefix)
    local fmt = prefix .. '%d_%d'
    return function(src, _, receivedAt)
        local t = math.tointeger(tonumber(receivedAt) or os.time()) or os.time()
        src = ToSrc(src)
        if not src then return end
        if A.foreignFlag(src) then return end
        if not wanted[src] then
            return
        end -- intent, not the live bag
        Wait(DelayMs())
        ClearIds(fmt, src, t, { 'police', 'ambulance' })
    end
end

-- ============================================================================
--                                  LIFECYCLE
-- ============================================================================

local function RemoveLeftovers()
    local ok, players = pcall(GetPlayers)
    if not ok or type(players) ~= 'table' then return 0 end
    local n = 0
    for _, s in ipairs(players) do
        local src = ToSrc(s)
        if src and Classify(BagValue(src)) == 'ours' and not wanted[src] then
            if RemoveOurs(src) then n = n + 1 end
        end
    end
    return n
end

AddEventHandler('playerDropped', function()
    local src = ToSrc(source)
    if not src then return end
    ForgetIntent(src)
    stale[src] = nil
    lastKind[src] = nil
    foreignCleared[src] = nil
    lastReassertAt[src] = nil
    arenaHandled[src] = nil
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= CP.resource then return end
    for src in pairs(wanted) do
        if Classify(BagValue(src)) == 'ours' then RemoveOurs(src) end
    end
    RemoveLeftovers()
    for src in pairs(wanted) do wanted[src] = nil end
end)

CreateThread(function()
    local n = RemoveLeftovers()
    if n > 0 then CP.warn(TAG, 'removed %d crimsonArena flag(s) left over from a previous start', n) end
    Wait(0)
    if CP.Dispatch then
        CP.Dispatch.onShotsFired(OnShotsFired)
        CP.Dispatch.onPlayerDown(DownListener('playerdown_'))
        CP.Dispatch.onPlayerDead(DownListener('playerdead_'))
    else
        CP.err(TAG, 'modules/integrations/sc_dispatch is missing: the alert backstop is off')
    end
    while true do
        Wait(1000)
        local ok, err = pcall(Reconcile)
        if not ok then CP.err(TAG, 'reconcile failed: %s', tostring(err)) end
    end
end)

-- CP.Downed (server): Hard rule 18, downed participants (docs/dev/ARCHITECTURE.md §5.15, SPEC "Downed participants",
-- Crimson-Arena rules 1 and 3).

-- Owns: the downed poll, the Failed result for a participant who goes down (end_reason 'downed'), the free
-- NPC pick-up when no EMS is on duty, the EMS request when EMS is on duty, the server -> client events
-- client:pickup (runId, dropOff vector3), client:pickupCancel (runId) (a pick-up already sent was cancelled
-- on the server: in the arena, recovered, unload) and client:requestEMS (runId), and the plain net event
-- server:pickupDone (runId, ok) the client sends when the pick-up has finished (ok = false: it gave up).
--
-- Public API
--   CP.Downed.isPending(src) -> boolean     a pick-up or EMS request for src is still to come (CP.Alerts keeps
--                                           the flag of such a participant)
--   CP.Downed.cancel(src, reason) -> boolean   stops a pending pick-up / EMS request and removes our flag
--                                           (CP.Alerts.clear leaves a foreign value alone). The run result
--                                           stays 'downed'. Used for in-arena, disconnect and unload.
--   CP.Downed.handle(run, src) -> boolean   CP.Runs.endRun: src is down (the caller checked CP.Qbx.isDowned)
--                                           and still active in a run that is ending. Holds the flag and
--                                           calls CP.Runs.removeParticipant(run, src, 'downed',
--                                           { keepFlag = true }) at once, before anything here yields (the
--                                           engine gives only the others the run's end state), then starts
--                                           the pick-up / EMS flow below in its own thread. A down the poll
--                                           or the metadata listener already recorded for this run, whose
--                                           thread has not run yet (CreateThread starts on the next tick),
--                                           only leaves now; that thread then does the follow-up alone.
--                                           false (nothing done): not an active participant, in the arena,
--                                           the run ended, or that down's follow-up is already past the leave
--                                           - the engine then removes them itself.
--
-- Flow (every Config.Downed.checkEvery s, active participants of every run that has not ended; in-arena
-- srcs are skipped; also at once when qbx_core sets metadata isdead / inlaststand to true, through
-- CP.Qbx.onMetaDataChange, and from CP.Downed.handle when a run ends):
--   CP.Qbx.isDowned(src) (metadata isdead / inlaststand; sc-ambulance resurrects the ped, so ped death is not
--   used) -> once per participant per run: CP.Alerts.hold(src) (the flag stays), CP.Runs.removeParticipant
--   (run, src, 'downed', { keepFlag = true }), run.stats.downs + 1 (only when the engine did not already
--   count it inside removeParticipant), then:
--   * no EMS (CP.Ambulance.doctorCount() == 0): toast downed.pickup_soon; after Config.Downed.pickupDelay s
--     re-check (still downed, not in the arena, still no EMS) -> client:pickup (runId, the nearest
--     Config.Downed.dropOffs point to the server-side ped) -> ~1.5 s for the fade -> re-check -> CP.Ambulance
--     .revive(src) -> server:pickupDone from the client (or 30 s) -> CP.Alerts.clear(src). No pick-up bill
--     (hospital:client:Revive never bills). A revive CP.Ambulance refuses or cannot send (false: in the
--     arena, disconnected, sc-ambulance stopped) cancels the pick-up at once (client:pickupCancel).
--   * EMS on duty: CP.Alerts.clear(src) at once, then wait until 11 s after the last arena exit
--     (CP.Alerts.foreignClearedAt[src]; sc-ambulance drops EMS requests for 10 s after one), re-check, then
--     client:requestEMS (runId) exactly once. The only exception: our flag was off when they went down AND
--     they were in last stand (CP.Qbx.getInfo(src).inLastStand) - sc-ambulance's client has then sent its
--     own automatic EMSDownAlert on entering last stand, so no second request is sent. A participant who
--     went straight to 'dead' unflagged gets our request (sc-ambulance sends no death alert).
--   A failed re-check cancels the pick-up / request and clears our flag. Each downed participant has one
--   entry per run, so nothing fires twice (also when the 2 s poll still sees metadata "down" right after the
--   revive). A disconnect (playerDropped) or character unload (CP.Qbx.onPlayerUnload) cancels it.
-- Every participant downed: CP.Runs ends a run that has no active participant left; when a down removed the
-- last one and the run is still open 5 s later, this module ends it as failed (see docs/dev/ARCHITECTURE.md §5.12).

CP.Downed = CP.Downed or {}
local D = CP.Downed
local TAG = 'downed'
local FADE_WAIT_MS = 1500             -- time for the client's fade-out before the revive
local DONE_TIMEOUT_MS = 30000         -- revive sent, no pickupDone: clear the flag anyway
local EMS_GAP_S = 11                  -- sc-ambulance ignores EMS requests 10 s after an arena exit
local RUN_END_GRACE_MS = 5000

local entries = {}                    -- entries[src] = { runId, citizenid, since, stage, flagged, lastStand, seq }
local seq = 0

local PENDING = { down = true, pickup_wait = true, pickup = true, revived = true, ems_wait = true }

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function RunsCall(name, ...)
    if not (CP.Runs and type(CP.Runs[name]) == 'function') then return false, nil end
    local ok, a, b = pcall(CP.Runs[name], ...)
    if not ok then
        CP.err(TAG, 'CP.Runs.%s failed: %s', name, tostring(a))
        return false, nil
    end
    return true, a, b
end

local function InArena(src)
    if not (CP.Alerts and CP.Alerts.inArena) then return false end
    local ok, v = pcall(CP.Alerts.inArena, src)
    return ok and v == true
end

local function IsDowned(src)
    if not (CP.Qbx and CP.Qbx.isDowned) then return false end
    local ok, v = pcall(CP.Qbx.isDowned, src)
    return ok and v == true
end

local function DoctorCount()
    if not (CP.Ambulance and CP.Ambulance.doctorCount) then return 0 end
    local ok, n = pcall(CP.Ambulance.doctorCount)
    if not ok then
        CP.err(TAG, 'CP.Ambulance.doctorCount failed: %s', tostring(n))
        return 0
    end
    return tonumber(n) or 0
end

local function alerts(name, ...)
    if CP.Alerts and type(CP.Alerts[name]) == 'function' then
        local ok, res = pcall(CP.Alerts[name], ...)
        if ok then return res end
        CP.err(TAG, 'CP.Alerts.%s failed: %s', name, tostring(res))
    end
    return nil
end

local function ServerCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local ok, c = pcall(GetEntityCoords, ped)
    if ok then return c end
    return nil
end

local function ActiveSrcs(run)
    if CP.Runs and type(CP.Runs.activeSrcs) == 'function' then
        local ok, list = pcall(CP.Runs.activeSrcs, run)
        if ok and type(list) == 'table' then return list end
    end
    local out = {}
    for src, p in pairs(run.participants or {}) do
        if type(p) == 'table' and p.status == 'active' then out[#out + 1] = src end
    end
    table.sort(out)
    return out
end

local function NearestDropOff(src)
    local here = ServerCoords(src)
    local best, bestD
    for _, point in ipairs(Config.Downed.dropOffs or {}) do
        local x, y, z = CP.U.xyz(point)
        if type(x) == 'number' and type(y) == 'number' and type(z) == 'number' then
            local v = vector3(x + 0.0, y + 0.0, z + 0.0)
            local d = here and CP.U.dist(here, v) or 0
            if not bestD or d < bestD then best, bestD = v, d end
        end
    end
    if not best then
        CP.err(TAG, 'Config.Downed.dropOffs has no valid point: %d is revived where they are', src)
        if here then best = vector3(here.x + 0.0, here.y + 0.0, here.z + 0.0) end
    end
    return best
end

-- A case with a real suspect (run.realSuspect: 'live' or 'volunteer') and Config.RealPlayers.downed ~= 'failed'
-- (shipped 'keep_earned'): a live officer leaves with 'downed_case' (result completed, the lines he earned so far), a
-- volunteer-suspect officer with 'downed_kept' (result failed, today's failed credit); neither starts a type cooldown.
-- 'failed' and every NPC run: 'downed' (Hard rule 18).
function D.reasonFor(run)
    if type(run) ~= 'table' or not run.realSuspect then return 'downed' end
    local rs = CP.RealPlayers()
    if type(rs) == 'table' and rs.downed == 'failed' then return 'downed' end
    if run.realSuspect == 'live' then return 'downed_case' end
    if run.realSuspect == 'volunteer' then return 'downed_kept' end
    return 'downed'
end

-- Seconds down, with no EMS on duty, before the pick-up: Config.RealPlayers.downedPickupDelay in a case with a real
-- suspect (keep it equal to sc-ambulance's Config.DeathTime), Config.Downed.pickupDelay otherwise.
local function PickupDelay(e)
    if e.realSuspect then
        local n = tonumber((CP.RealPlayers()).downedPickupDelay)
        if n and n >= 0 then return n end
    end
    return tonumber(Config.Downed.pickupDelay) or 15
end

local function Current(src, e)
    return entries[src] == e and PENDING[e.stage] == true
end

-- The flag may go: release the hold and remove our value (a foreign value is left alone).
local function ReleaseFlag(src)
    alerts('hold', src, false)
    alerts('clear', src)
end

-- The follow-up is over, however it ended: the client undoes whatever it still shows of it (the pick-up fade and
-- overlay, docs/dev/ARCHITECTURE.md §5.15). Once per entry.
local function Ended(src, e, why)
    if e.endSent then return end
    e.endSent = true
    TriggerClientEvent(CP.e('client:downedEnded'), src, e.runId, tostring(why))
end

local function Finish(src, e, why)
    if entries[src] ~= e or not PENDING[e.stage] then return end
    e.stage = 'done'
    CP.log(TAG, 'pick-up of %d finished (%s)', src, tostring(why))
    ReleaseFlag(src)
    Ended(src, e, why)
end

local function CancelEntry(src, e, reason)
    if not PENDING[e.stage] then return false end
    local clientBusy = e.stage == 'pickup' or e.stage == 'revived'
    e.stage = 'cancelled'
    e.cancelReason = reason
    CP.log(TAG, 'downed follow-up of %d cancelled (%s)', src, tostring(reason))
    ReleaseFlag(src)
    -- client:pickup was already sent: tell the client to stop (it fades back in and never teleports),
    -- unless it is the client itself that gave up.
    if clientBusy and reason ~= 'client_abort' then
        TriggerClientEvent(CP.e('client:pickupCancel'), src, e.runId)
    end
    Ended(src, e, reason)
    return true
end

-- Crimson-Arena rule 3: right before every step, still downed and not in the arena.
local function Recheck(src, e)
    if InArena(src) then
        CancelEntry(src, e, 'in_arena')
        return false
    end
    if not IsDowned(src) then
        CancelEntry(src, e, 'recovered')
        return false
    end
    return true
end

-- ============================================================================
--                                 EMS ON DUTY
-- ============================================================================

local function EmsPath(src, e)
    e.stage = 'ems_wait'
    ReleaseFlag(src)
    -- The one case sc-ambulance has certainly alerted EMS itself: no flag of ours when they went down AND
    -- they entered last stand (its client sends EMSDownAlert on entering last stand unless suppressed; a
    -- foreign arena value is skipped by the recheck anyway). Every other down (our flag suppressed the
    -- automatic alert, or they went straight to 'dead', which sends no alert with DisableDefaultAlerts)
    -- gets exactly one client:requestEMS.
    if not e.flagged and e.lastStand then
        e.stage = 'done'
        CP.log(TAG, '%d entered last stand without our flag: sc-ambulance already alerted EMS itself', src)
        CP.notify(src, 'info', 'downed.ems_on_duty')
        Ended(src, e, 'ems')
        return
    end
    local cleared = CP.Alerts and type(CP.Alerts.foreignClearedAt) == 'table' and CP.Alerts.foreignClearedAt[src] or nil
    if type(cleared) == 'number' then
        local waitS = cleared + EMS_GAP_S - os.time()
        if waitS > 0 then Wait(waitS * 1000) end
    end
    if not Current(src, e) then return end
    if not Recheck(src, e) then return end
    e.stage = 'ems_sent'
    TriggerClientEvent(CP.e('client:requestEMS'), src, e.runId)
    CP.log(TAG, 'EMS request sent for %d (run %s)', src, tostring(e.runId))
    Ended(src, e, 'ems')
end

-- ============================================================================
--                             NO EMS: NPC pick-up
-- ============================================================================

local function PickupPath(src, e)
    e.stage = 'pickup_wait'
    local delayS = PickupDelay(e)
    CP.notify(src, 'info', 'downed.pickup_soon', { seconds = delayS })
    Wait(math.floor(delayS * 1000))
    if not Current(src, e) then return end
    if not Recheck(src, e) then return end
    if DoctorCount() > 0 then return EmsPath(src, e) end
    local dropOff = NearestDropOff(src)
    if not dropOff then
        CancelEntry(src, e, 'no_position')
        return
    end
    e.stage = 'pickup'
    TriggerClientEvent(CP.e('client:pickup'), src, e.runId, dropOff)
    Wait(FADE_WAIT_MS)
    if not Current(src, e) or e.stage ~= 'pickup' then return end
    if not Recheck(src, e) then return end
    -- CP.Ambulance.revive returns false when it refuses (in the arena, not connected) or cannot revive
    -- (sc-ambulance stopped: its revive event has no handler). Nobody would revive the player then, so the
    -- pick-up is cancelled at once (the client fades back in, never teleports) instead of leaving them
    -- behind a black screen until the client's own revive timeout.
    local revived = false
    if not (CP.Ambulance and CP.Ambulance.revive) then
        CP.err(TAG, 'CP.Ambulance.revive is missing: %d cannot be revived', src)
    else
        local ok, res = pcall(CP.Ambulance.revive, src)
        if not ok then
            CP.err(TAG, 'revive of %d failed: %s', src, tostring(res))
        else
            revived = res == true
        end
    end
    if not revived then
        CancelEntry(src, e, 'revive_refused')
        return
    end
    e.stage = 'revived'
    local deadline = GetGameTimer() + DONE_TIMEOUT_MS
    while Current(src, e) and e.stage == 'revived' and GetGameTimer() < deadline do Wait(500) end
    if Current(src, e) and e.stage == 'revived' then Finish(src, e, 'timeout') end
end

-- A down removed the last active participant: the run must end as failed.
local function EnsureRunEnds(run)
    if run.state == 'ended' or #ActiveSrcs(run) > 0 then return end
    CreateThread(function()
        Wait(RUN_END_GRACE_MS)
        if run.state == 'ended' or #ActiveSrcs(run) > 0 then return end
        CP.warn(TAG, 'run %s has no active participant left after a down and is still open: ending it as failed',
            tostring(run.id))
        RunsCall('endRun', run, 'failed', 'mission_failed')
    end)
end

-- The downed participant leaves the run with end_reason 'downed' (D.reasonFor: 'downed_case' / 'downed_kept' in a
-- case with a real suspect; keepFlag: the hold keeps the flag), once per entry. Nothing here yields before
-- CP.Runs.removeParticipant has run its synchronous part.
local function RemoveNow(run, src, e)
    if e.removed then return end
    e.removed = true
    run.stats = run.stats or {}
    local downsBefore = tonumber(run.stats.downs) or 0
    local reason = D.reasonFor(run)
    RunsCall('removeParticipant', run, src, reason, { keepFlag = true })
    -- run.stats.downs + 1 for this down, unless the engine already counted it inside removeParticipant
    -- (only when they really left as downed: a participant who had already left is not a down).
    local p = run.participants and run.participants[src]
    if (tonumber(run.stats.downs) or 0) <= downsBefore and type(p) == 'table' and p.endReason == reason then
        run.stats.downs = downsBefore + 1
    end
end

local function FollowUp(src, e)
    if not Current(src, e) then return end
    if DoctorCount() > 0 then
        EmsPath(src, e)
    else
        PickupPath(src, e)
    end
end

local function Process(run, src, e)
    RemoveNow(run, src, e)
    EnsureRunEnds(run)
    FollowUp(src, e)
end

local function SpawnFlow(run, src, e, fn)
    CreateThread(function()
        local ok, err = pcall(fn, run, src, e)
        if not ok then
            CP.err(TAG, 'downed flow for %d failed: %s', src, tostring(err))
            if entries[src] == e then CancelEntry(src, e, 'error') end
        end
    end)
end

-- metadata.inlaststand at detection (CP.Qbx.getInfo): sc-ambulance's own automatic alert went out then
local function InLastStand(src)
    if not (CP.Qbx and CP.Qbx.getInfo) then return false end
    local ok, info = pcall(CP.Qbx.getInfo, src)
    return ok and type(info) == 'table' and info.inLastStand == true
end

-- Records the down (no yield: CP.Alerts.has / hold and CP.Qbx.getInfo never yield) and returns the entry.
local function NewEntry(run, src)
    local p = run.participants and run.participants[src]
    if type(p) ~= 'table' or p.status ~= 'active' then return nil end
    seq = seq + 1
    local e = {
        runId = run.id,
        citizenid = p.citizenid,
        since = os.time(),
        stage = 'down',
        flagged = alerts('has', src) == true,
        lastStand = InLastStand(src),
        realSuspect = run.realSuspect or nil,       -- the pick-up waits Config.RealPlayers.downedPickupDelay
        seq = seq,
    }
    entries[src] = e
    D._arm()
    alerts('hold', src, true)                      -- keepFlag: the flag stays until the pick-up / EMS request
    CP.log(TAG, '%d went down on run %s (flag %s)', src, tostring(run.id), tostring(e.flagged))
    return e
end

-- The poll and the metadata listener: the leave and the follow-up run in their own thread.
local function OnDowned(run, src)
    local e = NewEntry(run, src)
    if e then SpawnFlow(run, src, e, Process) end
end

-- A down not yet handled for this run: active, not in the arena, downed.
local function Detect(run, src)
    local e = entries[src]
    if e and e.runId == run.id then return end
    if InArena(src) or not IsDowned(src) then return end
    OnDowned(run, src)
end

local function Prune()
    local now = os.time()
    for src, e in pairs(entries) do
        if not PENDING[e.stage] then
            local gone = GetPlayerName(src) == nil
            if gone or not IsDowned(src) or now - e.since > 3600 then entries[src] = nil end
        end
    end
end

local function Tick()
    if not (CP.Runs and CP.Runs.all) then return next(entries) == nil end
    local _, runs = RunsCall('all')
    if type(runs) ~= 'table' then return next(entries) == nil end
    local work = {}
    for _, run in ipairs(runs) do
        if type(run) == 'table' and run.id ~= nil and run.state ~= 'ended' then
            for _, src in ipairs(ActiveSrcs(run)) do work[#work + 1] = { run = run, src = src } end
        end
    end
    for _, w in ipairs(work) do
        local src = CP.U.toSrc(w.src)
        if src then Detect(w.run, src) end
    end
    Prune()
    -- no live run and nothing kept: the check sleeps until the next run
    return #work == 0 and next(entries) == nil and next(runs) == nil
end

-- The check runs only while a run is live or an entry is kept (it woke every checkEvery seconds all day):
-- armed at start, by a run created and by a new entry; the pass that finds neither ends it.
D._arm, D._ticking = CP.Perf.armed(TAG, function()
    local every = tonumber(Config.Downed.checkEvery) or 2
    if every < 0.5 then every = 0.5 end
    return math.floor(every * 1000)
end, Tick)
if CP.Hooks and CP.Hooks.on then CP.Hooks.on('run:created', function() D._arm() end) end

-- ============================================================================
--                                  PUBLIC API
-- ============================================================================

function D.isPending(src)
    src = CP.U.toSrc(src)
    local e = src and entries[src]
    return e ~= nil and e ~= false and PENDING[e.stage] == true
end

function D.cancel(src, reason)
    src = CP.U.toSrc(src)
    local e = src and entries[src]
    if not e then return false end
    return CancelEntry(src, e, reason or 'cancelled')
end

function D.handle(run, src)
    src = CP.U.toSrc(src)
    if not src or type(run) ~= 'table' or run.id == nil or run.state == 'ended' then return false end
    local p = run.participants and run.participants[src]
    if type(p) ~= 'table' or p.status ~= 'active' then return false end
    local e = entries[src]
    if e and e.runId == run.id then
        -- The poll (or the metadata listener) caught this down and its thread has not removed them yet:
        -- they leave now; that thread skips the leave and carries on with the follow-up.
        if not PENDING[e.stage] or e.removed then return false end
        RemoveNow(run, src, e)
        return true
    end
    if InArena(src) then return false end
    e = NewEntry(run, src)
    if not e then return false end
    RemoveNow(run, src, e) -- before our first yield
    CP.log(TAG, '%d was down when run %s ended: follow-up started', src, tostring(run.id))
    SpawnFlow(run, src, e, function(r, s, en)
        EnsureRunEnds(r)
        FollowUp(s, en)
    end)
    return true
end

-- ============================================================================
--                              METADATA LISTENER
-- ============================================================================
-- React at once instead of on the next poll.

local function OnMetaData(src, key, _, new)
    if new ~= true or (key ~= 'isdead' and key ~= 'inlaststand') then return end
    src = CP.U.toSrc(src)
    if not src then return end
    local _, run = RunsCall('getBySrc', src)
    if type(run) ~= 'table' or run.id == nil or run.state == 'ended' then return end
    local p = run.participants and run.participants[src]
    if type(p) ~= 'table' or p.status ~= 'active' then return end
    Detect(run, src)
end

-- ============================================================================
--                                  NET EVENT
-- ============================================================================
-- The client finished (or gave up on) the pick-up.

RegisterNetEvent(CP.e('server:pickupDone'), function(runId, ok)
    local src = source
    local n = CP.U.toSrc(src)
    if not n then return end
    if type(runId) ~= 'string' or runId == '' or #runId > 64 then return end
    if ok ~= nil and type(ok) ~= 'boolean' then return end
    if not CP.Net.rateOk(n, 'downed:pickupDone', 2, 5000) then return end
    local e = entries[n]
    if not e or e.runId ~= runId then return end
    if e.stage == 'revived' then
        Finish(n, e, ok == false and 'client gave up' or 'client done')
    elseif e.stage == 'pickup' then
        -- The client gave up before the revive (arena flag, fade problem): no revive follows.
        CancelEntry(n, e, 'client_abort')
    end
end)

AddEventHandler('playerDropped', function()
    local n = CP.U.toSrc(source)
    if not n then return end
    local e = entries[n]
    if e then
        if PENDING[e.stage] then
            e.stage = 'cancelled'
            e.cancelReason = 'dropped'
        end
        entries[n] = nil
    end
    alerts('hold', n, false)
end)

CreateThread(function()
    Wait(0)
    if CP.Qbx and CP.Qbx.onMetaDataChange then
        CP.Qbx.onMetaDataChange(OnMetaData, { 'isdead', 'inlaststand' })
    end
    if CP.Qbx and CP.Qbx.onPlayerUnload then
        CP.Qbx.onPlayerUnload(function(src) D.cancel(src, 'unload') end)
    else
        CP.err(TAG, 'modules/system/integrations/qbx is missing: downed participants cannot be detected')
    end
    D._arm()
end)

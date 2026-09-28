-- modules/downed/server.lua · CP.Downed (server): Hard rule 18, downed participants
-- (docs/ARCHITECTURE.md §5.15, SPEC "Downed participants", CRIMSON_ARENA rules 1 and 3).
--
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
--
-- Flow (every Config.Downed.checkEvery s, active participants of every run that has not ended; in-arena
-- srcs are skipped):
--   CP.Qbx.isDowned(src) (metadata isdead / inlaststand; sc-ambulance resurrects the ped, so ped death is not
--   used) -> once per participant per run: CP.Alerts.hold(src) (the flag stays), CP.Runs.removeParticipant
--   (run, src, 'downed', { keepFlag = true }), run.stats.downs + 1 (only when the engine did not already
--   count it inside removeParticipant), then:
--   * no EMS (CP.Ambulance.doctorCount() == 0): toast downed.pickup_soon; after Config.Downed.pickupDelay s
--     re-check (still downed, not in the arena, still no EMS) -> client:pickup (runId, the nearest
--     Config.Downed.dropOffs point to the server-side ped) -> ~1.5 s for the fade -> re-check -> CP.Ambulance
--     .revive(src) -> server:pickupDone from the client (or 30 s) -> CP.Alerts.clear(src). No pick-up bill
--     (hospital:client:Revive never bills).
--   * EMS on duty: CP.Alerts.clear(src) at once. If our flag was on when they went down (so sc-ambulance
--     suppressed its own automatic EMS alert): wait until 11 s after the last arena exit
--     (CP.Alerts.foreignClearedAt[src]; sc-ambulance drops EMS requests for 10 s after one), re-check, then
--     client:requestEMS (runId) exactly once. Without our flag sc-ambulance's own automatic alert has
--     already gone out, so no second request is sent.
--   A failed re-check cancels the pick-up / request and clears our flag. Each downed participant has one
--   entry per run, so nothing fires twice (also when the 2 s poll still sees metadata "down" right after the
--   revive). A disconnect (playerDropped) or character unload (CP.Qbx.onPlayerUnload) cancels it.
-- Every participant downed: CP.Runs ends a run that has no active participant left; when a down removed the
-- last one and the run is still open 5 s later, this module ends it as failed (see docs/notes/safety.md).

CP.Downed = CP.Downed or {}
local D = CP.Downed
local TAG = 'downed'
local FADE_WAIT_MS = 1500             -- time for the client's fade-out before the revive
local DONE_TIMEOUT_MS = 30000         -- revive sent, no pickupDone: clear the flag anyway
local EMS_GAP_S = 11                  -- sc-ambulance ignores EMS requests 10 s after an arena exit
local RUN_END_GRACE_MS = 5000

local entries = {}                    -- entries[src] = { runId, citizenid, since, stage, flagged, seq }
local seq = 0

local PENDING = { down = true, pickup_wait = true, pickup = true, revived = true, ems_wait = true }

-- ── helpers ─────────────────────────────────────────────────────────────────
local function toSrc(src)
    local n = tonumber(src)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
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

local function inArena(src)
    if not (CP.Alerts and CP.Alerts.inArena) then return false end
    local ok, v = pcall(CP.Alerts.inArena, src)
    return ok and v == true
end

local function isDowned(src)
    if not (CP.Qbx and CP.Qbx.isDowned) then return false end
    local ok, v = pcall(CP.Qbx.isDowned, src)
    return ok and v == true
end

local function doctorCount()
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

local function notify(src, kind, key, vars)
    if CP.Tablet and CP.Tablet.notify then pcall(CP.Tablet.notify, src, kind, key, vars) end
end

local function serverCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local ok, c = pcall(GetEntityCoords, ped)
    if ok then return c end
    return nil
end

local function activeSrcs(run)
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

local function nearestDropOff(src)
    local here = serverCoords(src)
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

local function current(src, e)
    return entries[src] == e and PENDING[e.stage] == true
end

-- The flag may go: release the hold and remove our value (a foreign value is left alone).
local function releaseFlag(src)
    alerts('hold', src, false)
    alerts('clear', src)
end

local function finish(src, e, why)
    if entries[src] ~= e or not PENDING[e.stage] then return end
    e.stage = 'done'
    CP.log(TAG, 'pick-up of %d finished (%s)', src, tostring(why))
    releaseFlag(src)
end

local function cancelEntry(src, e, reason)
    if not PENDING[e.stage] then return false end
    local clientBusy = e.stage == 'pickup' or e.stage == 'revived'
    e.stage = 'cancelled'
    e.cancelReason = reason
    CP.log(TAG, 'downed follow-up of %d cancelled (%s)', src, tostring(reason))
    releaseFlag(src)
    -- client:pickup was already sent: tell the client to stop (it fades back in and never teleports),
    -- unless it is the client itself that gave up.
    if clientBusy and reason ~= 'client_abort' then
        TriggerClientEvent(CP.e('client:pickupCancel'), src, e.runId)
    end
    return true
end

-- CRIMSON_ARENA rule 3: right before every step, still downed and not in the arena.
local function recheck(src, e)
    if inArena(src) then
        cancelEntry(src, e, 'in_arena')
        return false
    end
    if not isDowned(src) then
        cancelEntry(src, e, 'recovered')
        return false
    end
    return true
end

-- ── EMS on duty ─────────────────────────────────────────────────────────────
local function emsPath(src, e)
    e.stage = 'ems_wait'
    releaseFlag(src)
    if not e.flagged then
        e.stage = 'done'
        CP.log(TAG, '%d went down without our flag: sc-ambulance already alerted EMS itself', src)
        notify(src, 'info', 'downed.ems_on_duty')
        return
    end
    local cleared = CP.Alerts and type(CP.Alerts.foreignClearedAt) == 'table' and CP.Alerts.foreignClearedAt[src] or nil
    if type(cleared) == 'number' then
        local waitS = cleared + EMS_GAP_S - os.time()
        if waitS > 0 then Wait(waitS * 1000) end
    end
    if not current(src, e) then return end
    if not recheck(src, e) then return end
    e.stage = 'ems_sent'
    TriggerClientEvent(CP.e('client:requestEMS'), src, e.runId)
    CP.log(TAG, 'EMS request sent for %d (run %s)', src, tostring(e.runId))
end

-- ── no EMS: NPC pick-up ─────────────────────────────────────────────────────
local function pickupPath(src, e)
    e.stage = 'pickup_wait'
    local delayS = tonumber(Config.Downed.pickupDelay) or 15
    notify(src, 'info', 'downed.pickup_soon', { seconds = delayS })
    Wait(math.floor(delayS * 1000))
    if not current(src, e) then return end
    if not recheck(src, e) then return end
    if doctorCount() > 0 then return emsPath(src, e) end
    local dropOff = nearestDropOff(src)
    if not dropOff then
        cancelEntry(src, e, 'no_position')
        return
    end
    e.stage = 'pickup'
    TriggerClientEvent(CP.e('client:pickup'), src, e.runId, dropOff)
    Wait(FADE_WAIT_MS)
    if not current(src, e) or e.stage ~= 'pickup' then return end
    if not recheck(src, e) then return end
    if not (CP.Ambulance and CP.Ambulance.revive) then
        CP.err(TAG, 'CP.Ambulance.revive is missing: %d cannot be revived', src)
    else
        local ok, err = pcall(CP.Ambulance.revive, src)
        if not ok then CP.err(TAG, 'revive of %d failed: %s', src, tostring(err)) end
    end
    e.stage = 'revived'
    local deadline = GetGameTimer() + DONE_TIMEOUT_MS
    while current(src, e) and e.stage == 'revived' and GetGameTimer() < deadline do Wait(500) end
    if current(src, e) and e.stage == 'revived' then finish(src, e, 'timeout') end
end

-- A down removed the last active participant: the run must end as failed.
local function ensureRunEnds(run)
    if run.state == 'ended' or #activeSrcs(run) > 0 then return end
    CreateThread(function()
        Wait(RUN_END_GRACE_MS)
        if run.state == 'ended' or #activeSrcs(run) > 0 then return end
        CP.warn(TAG, 'run %s has no active participant left after a down and is still open: ending it as failed', tostring(run.id))
        runsCall('endRun', run, 'failed', 'mission_failed')
    end)
end

local function process(run, src, e)
    run.stats = run.stats or {}
    local downsBefore = tonumber(run.stats.downs) or 0
    runsCall('removeParticipant', run, src, 'downed', { keepFlag = true })
    -- run.stats.downs + 1 for this down, unless the engine already counted it inside removeParticipant.
    if (tonumber(run.stats.downs) or 0) <= downsBefore then run.stats.downs = downsBefore + 1 end
    ensureRunEnds(run)
    if not current(src, e) then return end
    if doctorCount() > 0 then
        emsPath(src, e)
    else
        pickupPath(src, e)
    end
end

local function onDowned(run, src)
    local p = run.participants and run.participants[src]
    if type(p) ~= 'table' or p.status ~= 'active' then return end
    seq = seq + 1
    local e = {
        runId = run.id, citizenid = p.citizenid, since = os.time(), stage = 'down',
        flagged = alerts('has', src) == true, seq = seq,
    }
    entries[src] = e
    alerts('hold', src, true)                      -- keepFlag: the flag stays until the pick-up / EMS request
    CP.log(TAG, '%d went down on run %s (flag %s)', src, tostring(run.id), tostring(e.flagged))
    CreateThread(function()
        local ok, err = pcall(process, run, src, e)
        if not ok then
            CP.err(TAG, 'downed flow for %d failed: %s', src, tostring(err))
            if entries[src] == e then cancelEntry(src, e, 'error') end
        end
    end)
end

local function prune()
    local now = os.time()
    for src, e in pairs(entries) do
        if not PENDING[e.stage] then
            local gone = GetPlayerName(src) == nil
            if gone or not isDowned(src) or now - e.since > 3600 then entries[src] = nil end
        end
    end
end

local function tick()
    if not (CP.Runs and CP.Runs.all) then return end
    local _, runs = runsCall('all')
    if type(runs) ~= 'table' then return end
    local work = {}
    for _, run in ipairs(runs) do
        if type(run) == 'table' and run.id ~= nil and run.state ~= 'ended' then
            for _, src in ipairs(activeSrcs(run)) do work[#work + 1] = { run = run, src = src } end
        end
    end
    for _, w in ipairs(work) do
        local src = toSrc(w.src)
        local e = src and entries[src]
        if src and not (e and e.runId == w.run.id) and not inArena(src) and isDowned(src) then
            onDowned(w.run, src)
        end
    end
    prune()
end

-- ── public API ──────────────────────────────────────────────────────────────
function D.isPending(src)
    src = toSrc(src)
    local e = src and entries[src]
    return e ~= nil and e ~= false and PENDING[e.stage] == true
end

function D.cancel(src, reason)
    src = toSrc(src)
    local e = src and entries[src]
    if not e then return false end
    return cancelEntry(src, e, reason or 'cancelled')
end

-- ── net event: the client finished (or gave up on) the pick-up ─────────────
RegisterNetEvent(CP.e('server:pickupDone'), function(runId, ok)
    local src = source
    local n = toSrc(src)
    if not n then return end
    if type(runId) ~= 'string' or runId == '' or #runId > 64 then return end
    if ok ~= nil and type(ok) ~= 'boolean' then return end
    if not CP.Net.rateOk(n, 'downed:pickupDone', 2, 5000) then return end
    local e = entries[n]
    if not e or e.runId ~= runId then return end
    if e.stage == 'revived' then
        finish(n, e, ok == false and 'client gave up' or 'client done')
    elseif e.stage == 'pickup' then
        -- The client gave up before the revive (arena flag, fade problem): no revive follows.
        cancelEntry(n, e, 'client_abort')
    end
end)

AddEventHandler('playerDropped', function()
    local n = toSrc(source)
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
    if CP.Qbx and CP.Qbx.onPlayerUnload then
        CP.Qbx.onPlayerUnload(function(src) D.cancel(src, 'unload') end)
    else
        CP.err(TAG, 'modules/integrations/qbx is missing: downed participants cannot be detected')
    end
    while true do
        local every = tonumber(Config.Downed.checkEvery) or 2
        if every < 0.5 then every = 0.5 end
        Wait(math.floor(every * 1000))
        local ok, err = pcall(tick)
        if not ok then CP.err(TAG, 'tick failed: %s', tostring(err)) end
    end
end)

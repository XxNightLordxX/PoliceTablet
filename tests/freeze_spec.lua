-- The freeze after a down on the way to a mission start (recovered before the pick-up): the downed follow-up's end
-- signal, the client's screen safety net, the tablet while down, the NUI open check, the web error boundaries and
-- lint rule FX10 (loops that can go round with no Wait).

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
Config.Debug = false

-- ============================================================================
--                              SERVER: THE STUBS
-- ============================================================================

local runs, rlog = {}, { removed = {} }
local downed = {}                    -- downed[src] = 'laststand' | 'dead' (qbx metadata)
local flags, arena = {}, {}          -- our crimsonArena flag / a foreign arena, per src
local ems = { doctors = 0, revives = {}, refuse = false }
local notes = {}

local function ActiveOf(r)
    local out = {}
    for s, p in pairs(r.participants) do if p.status == 'active' then out[#out + 1] = s end end
    table.sort(out)
    return out
end

CP.Runs = {
    all = function()
        local out = {}
        for _, r in pairs(runs) do if r.state ~= 'ended' then out[#out + 1] = r end end
        table.sort(out, function(a, b) return a.id < b.id end)
        return out
    end,
    getBySrc = function(src)
        for _, r in pairs(runs) do
            local p = r.state ~= 'ended' and r.participants[src]
            if p and p.status == 'active' then return r, p end
        end
        return nil
    end,
    activeSrcs = ActiveOf,
    removeParticipant = function(r, src, reason)
        rlog.removed[#rlog.removed + 1] = { run = r.id, src = src, reason = reason, at = H.clockMs }
        local p = r.participants[src]
        if p.status ~= 'active' then return nil end
        p.status, p.endReason = 'left', reason
        if reason == 'downed' then r.stats.downs = r.stats.downs + 1 end
        if #ActiveOf(r) == 0 then r.state = 'ended' end
    end,
    endRun = function(r) r.state = 'ended' end,
}
CP.Qbx = {
    isDowned = function(src) return downed[src] ~= nil end,
    getInfo = function(src)
        return { src = src, isDead = downed[src] == 'dead', inLastStand = downed[src] == 'laststand' }
    end,
    onPlayerUnload = function() end,
    onMetaDataChange = function() end,
}
CP.Ambulance = {
    doctorCount = function() return ems.doctors end,
    revive = function(src)
        if ems.refuse then return false end
        ems.revives[#ems.revives + 1] = src
        return true
    end,
}
CP.Alerts = {
    has = function(src) return flags[src] == true end,
    hold = function() end,
    clear = function(src) flags[src] = nil end,
    inArena = function(src) return arena[src] == true end,
    foreignClearedAt = {},
}
CP.Tablet = {
    notify = function(src, kind, key, vars) notes[#notes + 1] = { src = src, kind = kind, key = key, vars = vars } end,
}

local function NewRun(id, srcs)
    local r = { id = id, state = 'accepted', participants = {}, stats = { downs = 0 } }
    for _, s in ipairs(srcs) do r.participants[s] = { src = s, citizenid = 'CID' .. s, status = 'active' } end
    runs[id] = r
    return r
end

local function ClientEvents(name, target)
    local out = {}
    for _, e in ipairs(H.events) do
        if e.kind == 'client' and e.name == CP.e(name) and (target == nil or e.target == target) then
            out[#out + 1] = e
        end
    end
    return out
end

local function RemovedAt(src)
    for _, e in ipairs(rlog.removed) do if e.src == src then return e.at, e.reason end end
    return nil
end

local function RunFor(ms)
    local target = H.clockMs + ms
    while H.clockMs < target do H.step(100) end
end

H.load('modules/downed/server.lua')
H.step(0)
local D = CP.Downed

-- ============================================================================
--             SERVER: EVERY END OF THE FOLLOW-UP TELLS THE CLIENT
-- ============================================================================

-- The owner's case: down on the way to the start (no flag of ours), no EMS, revived by someone else 13 s later.
-- The follow-up is cancelled at the first recheck, before the pick-up: the client still hears that it is over.
do
    NewRun('run-owner', { 1 })
    downed[1] = 'laststand'
    RunFor(2000)
    local at, reason = RemovedAt(1)
    H.eq(reason, 'downed', 'owner: left the run as downed')
    RunFor(13000)
    downed[1] = nil
    H.eq(#ClientEvents('client:downedEnded', 1), 0, 'owner: nothing ended before the recheck')
    RunFor(3000)
    local ended = ClientEvents('client:downedEnded', 1)
    H.eq(#ended, 1, 'owner: the recovery at the recheck is sent to the client once')
    H.eq(ended[1] and ended[1].args[1], 'run-owner', 'owner: for that run')
    H.eq(ended[1] and ended[1].args[2], 'recovered', 'owner: with the reason')
    H.ok(at and ended[1] and H.clockMs - at >= 15000, 'owner: at the 15 s recheck, not earlier')
    H.eq(#ClientEvents('client:pickup', 1), 0, 'owner: no pick-up was sent')
    H.eq(#ClientEvents('client:pickupCancel', 1), 0, 'owner: and no pick-up cancel')
    H.eq(D.isPending(1), false, 'owner: nothing pending')
end

-- A pick-up the client finished.
do
    NewRun('run-done', { 2 })
    downed[2] = 'laststand'
    RunFor(2000)
    RunFor(15000)
    H.eq(#ClientEvents('client:pickup', 2), 1, 'done: pick-up sent')
    RunFor(2000)
    H.eq(ems.revives[#ems.revives], 2, 'done: revived')
    H.eq(#ClientEvents('client:downedEnded', 2), 0, 'done: not over while the client works')
    downed[2] = nil
    H.fire(CP.e('server:pickupDone'), 2, 'run-done', true)
    local ended = ClientEvents('client:downedEnded', 2)
    H.eq(#ended, 1, 'done: the end is sent once')
    H.eq(ended[1] and ended[1].args[2], 'client done', 'done: reason')
    H.eq(D.cancel(2, 'late'), false, 'done: a later cancel does nothing')
    H.eq(#ClientEvents('client:downedEnded', 2), 1, 'done: and sends nothing more')
end

-- Placed in an arena before the pick-up.
do
    NewRun('run-arena', { 3 })
    downed[3] = 'laststand'
    RunFor(2000)
    arena[3] = true
    RunFor(16000)
    local ended = ClientEvents('client:downedEnded', 3)
    H.eq(#ended, 1, 'arena: the end is sent')
    H.eq(ended[1] and ended[1].args[2], 'in_arena', 'arena: reason')
    arena[3] = nil
end

-- EMS on duty: our flag goes, EMS is requested, and the follow-up is over.
do
    ems.doctors = 1
    NewRun('run-ems', { 4 })
    flags[4] = true
    downed[4] = 'dead'
    RunFor(2000)
    H.eq(#ClientEvents('client:requestEMS', 4), 1, 'ems: EMS requested')
    local ended = ClientEvents('client:downedEnded', 4)
    H.eq(#ended, 1, 'ems: the end is sent')
    H.eq(ended[1] and ended[1].args[2], 'ems', 'ems: reason')
    -- in last stand without our flag, sc-ambulance alerted EMS itself: over at once
    NewRun('run-ems2', { 5 })
    downed[5] = 'laststand'
    RunFor(2000)
    H.eq(#ClientEvents('client:requestEMS', 5), 0, 'ems: no second request')
    H.eq(#ClientEvents('client:downedEnded', 5), 1, 'ems: over at once')
    ems.doctors = 0
end

-- sc-ambulance refuses the revive: the client is told to cancel the pick-up and that the follow-up is over.
do
    ems.refuse = true
    NewRun('run-refused', { 6 })
    downed[6] = 'laststand'
    RunFor(2000)
    RunFor(17000)
    H.eq(#ClientEvents('client:pickupCancel', 6), 1, 'refused: pick-up cancelled on the client')
    local ended = ClientEvents('client:downedEnded', 6)
    H.eq(#ended, 1, 'refused: the end is sent')
    H.eq(ended[1] and ended[1].args[2], 'revive_refused', 'refused: reason')
    ems.refuse = false
end

-- A character unload while it waits for the pick-up.
do
    NewRun('run-unload', { 7 })
    downed[7] = 'laststand'
    RunFor(4000)
    H.eq(D.cancel(7, 'unload'), true, 'unload: cancelled')
    local ended = ClientEvents('client:downedEnded', 7)
    H.eq(#ended, 1, 'unload: the end is sent')
    H.eq(ended[1] and ended[1].args[2], 'unload', 'unload: reason')
end

-- ============================================================================
--                  CLIENT: STUBS, AND A GUARD ON EVERY THREAD
-- ============================================================================
-- Every client thread gets a count hook: a thread that runs SPIN_LIMIT x 10000 VM instructions without a Wait is
-- where the game would hang; the harness records it and stops that thread instead of hanging too.

H.handlers, H.callbacks, H.commands, H.events = {}, {}, {}, {}
CP, Config = nil, nil
H.boot({ side = 'client' })
Config.Debug = false

local realPrint = print
local logs = {}
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    if line:find('[crimson-police', 1, true) or line:find('crimson-police:', 1, true) then
        logs[#logs + 1] = line
        return
    end
    realPrint(line)
end
local function Logged(text)
    for _, l in ipairs(logs) do if l:find(text, 1, true) then return true end end
    return false
end

local SPIN_LIMIT = 200
local spins = {}
local budget = setmetatable({}, { __mode = 'k' })
local function SpinHook()
    local co = coroutine.running()
    local n = (budget[co] or 0) + 1
    budget[co] = n
    if n > SPIN_LIMIT then
        budget[co] = 0
        spins[#spins + 1] = debug.traceback('a client thread ran without a Wait', 2)
        error('a client thread ran without a Wait', 0)
    end
end
local realCreateThread, realWait = _G.CreateThread, _G.Wait
_G.CreateThread = function(fn)
    realCreateThread(function(...)
        debug.sethook(SpinHook, '', 10000)
        return fn(...)
    end)
end
_G.Wait = function(ms)
    local co = coroutine.running()
    if co then budget[co] = 0 end
    return realWait(ms)
end
_G.Citizen.CreateThread, _G.Citizen.Wait = _G.CreateThread, _G.Wait

local PED, VEH = 100, 5550
local cs = {
    fade = 'in',
    focus = false,
    focusCalls = 0,
    dead = false,
    inVeh = false,
    pos = vec3(0.0, 0.0, 0.0),
    coordsSet = nil,
    waypoint = nil,
    blips = {},
    nextBlip = 1,
    objects = {},
    nextObj = 7000,
    playing = false,
}
local nui, nuiCb = {}, {}
local clientPD = { job = { name = 'sast', onduty = true, grade = { level = 3 } }, metadata = {} }
H.exportsMock.qbx_core = {
    GetPlayerData = function() return clientPD end,
}
_G.LocalPlayer = { state = { isLoggedIn = true } }
_G.GetResourceState = function(name) return name == 'ox_target' and 'stopped' or 'started' end

_G.PlayerPedId = function() return PED end
_G.PlayerId = function() return 0 end
_G.GetPlayerServerId = function() return 1 end
_G.GetEntityCoords = function() return cs.pos end
_G.IsEntityDead = function() return cs.dead end
_G.DoScreenFadeOut = function() cs.fade = 'out' end
_G.DoScreenFadeIn = function() cs.fade = 'in' end
_G.IsScreenFadedOut = function() return cs.fade == 'out' end
_G.IsScreenFadedIn = function() return cs.fade == 'in' end
_G.SetNuiFocus = function(a)
    cs.focus = a == true
    cs.focusCalls = cs.focusCalls + 1
end
_G.IsNuiFocused = function() return cs.focus or cs.otherFocus == true end
_G.IsNuiFocusKeepingInput = function() return false end
_G.IsScreenFadingOut = function() return false end
_G.IsScreenFadingIn = function() return false end
_G.GetRenderingCam = function() return -1 end
_G.IsPlayerControlOn = function() return true end
_G.IsEntityPositionFrozen = function() return false end
_G.IsPauseMenuActive = function() return false end
_G.SendNUIMessage = function(m) nui[#nui + 1] = m end
_G.RegisterNUICallback = function(name, fn) nuiCb[name] = fn end
_G.RegisterKeyMapping = function() end
_G.AddStateBagChangeHandler = function() end
_G.IsModelInCdimage = function() return true end
_G.RequestModel = function() end
_G.HasModelLoaded = function() return true end
_G.SetModelAsNoLongerNeeded = function() end
_G.CreateObject = function()
    cs.nextObj = cs.nextObj + 1
    cs.objects[cs.nextObj] = true
    return cs.nextObj
end
_G.DoesEntityExist = function(e) return e == PED or e == VEH or cs.objects[e] == true end
_G.DeleteEntity = function(e) cs.objects[e] = nil end
_G.DetachEntity = function() end
_G.SetEntityAsMissionEntity = function() end
_G.SetEntityCollision = function() end
_G.AttachEntityToEntity = function() end
_G.GetPedBoneIndex = function(_, b) return b end
_G.RequestAnimDict = function() end
_G.HasAnimDictLoaded = function() return true end
_G.RemoveAnimDict = function() end
_G.TaskPlayAnim = function() cs.playing = true end
_G.IsEntityPlayingAnim = function() return cs.playing end
_G.StopAnimTask = function() cs.playing = false end
_G.IsEntityAttached = function() return false end
_G.IsPedInAnyVehicle = function() return cs.inVeh end
_G.GetVehiclePedIsIn = function() return cs.inVeh and VEH or 0 end
_G.GetPedInVehicleSeat = function() return cs.inVeh and PED or 0 end
_G.NetworkGetEntityIsNetworked = function() return true end
_G.NetworkGetNetworkIdFromEntity = function(e) return e end
_G.IsVehicleSirenOn = function() return false end
_G.IsPedArmed = function() return false end
_G.IsPedShooting = function() return false end
_G.ClearPedTasksImmediately = function() cs.playing = false end
_G.RequestCollisionAtCoord = function() end
_G.SetEntityCoords = function(_, x, y, z) cs.coordsSet = vec3(x, y, z) end
_G.HasCollisionLoadedAroundEntity = function() return true end
_G.GetStreetNameAtCoord = function() return 777, 0 end
_G.GetStreetNameFromHashKey = function() return 'Grapeseed Main St' end
_G.GetNameOfZone = function() return 'GRAPES' end
_G.GetLabelText = function() return 'Grapeseed' end
_G.SetNewWaypoint = function(x, y) cs.waypoint = vec3(x, y, 0.0) end
_G.IsWaypointActive = function() return cs.waypoint ~= nil end
_G.GetFirstBlipInfoId = function() return cs.waypoint and 900 or 0 end
_G.GetBlipInfoIdCoord = function() return cs.waypoint end
_G.SetWaypointOff = function() cs.waypoint = nil end
_G.AddBlipForCoord = function()
    local b = cs.nextBlip
    cs.nextBlip = b + 1
    cs.blips[b] = true
    return b
end
_G.AddBlipForRadius = _G.AddBlipForCoord
_G.DoesBlipExist = function(b) return cs.blips[b] == true or b == 900 end
_G.RemoveBlip = function(b) cs.blips[b] = nil end
_G.SetBlipSprite = function() end
_G.SetBlipColour = function() end
_G.SetBlipAlpha = function() end
_G.SetBlipScale = function() end
_G.SetBlipRouteColour = function() end
_G.SetBlipRoute = function() end
_G.BeginTextCommandSetBlipName = function() end
_G.AddTextComponentSubstringPlayerName = function() end
_G.EndTextCommandSetBlipName = function() end
-- the GPS route of the owner's run: 5963 m, a straight road north
_G.GetGpsBlipRouteFound = function() return true end
_G.GetGpsBlipRouteLength = function() return 5963 end
_G.GetPosAlongGpsTypeRoute = function(_, d) return true, vec3(0.0, d, 0.0) end

local session = {
    ui = 'officer',
    roles = { officer = true, supervisor = true, admin = false },
    officer = { citizenid = 'CID1', name = 'John Doe', department = 'sast', departmentShort = 'SAST' },
    theme = { primary = '#1f4e8c', accent = '#f2c230', background = '#0d1522', surface = '#152235', text = '#fff' },
}
lib.callback.await = function(name)
    if name == 'crimson-police:getSession' then return { ok = true, data = session } end
    return { ok = true, data = {} }
end

H.load('modules/integrations/qbx/client.lua')
H.load('modules/access/client.lua')
H.load('modules/tablet/client.lua')
H.load('modules/route/client.lua')
H.load('modules/runs/client.lua')
H.load('modules/downed/client.lua')
H.load('modules/diag/client.lua')
RunFor(3000)
local T, CD, CR = CP.Tablet, CP.Downed, CP.Runs
H.ok(T and CD and CR and CP.Route, 'client modules loaded')

local function Nui(cbName, body)
    local reply
    local fn = nuiCb[cbName]
    H.ok(fn ~= nil, 'the NUI callback ' .. cbName .. ' exists')
    if fn then fn(body or {}, function(r) reply = r end) end
    return reply
end
local function LastNui(kind)
    for i = #nui, 1, -1 do if nui[i].type == kind then return nui[i] end end
    return nil
end
local function Sent(name)
    local out = {}
    for _, e in ipairs(H.events) do if e.kind == 'server' and e.name == CP.e(name) then out[#out + 1] = e end end
    return out
end
local function OverlayOn()
    local m = LastNui('overlay')
    return m ~= nil and m.overlay ~= nil
end
local function GoDown(inVehicle)
    cs.inVeh = inVehicle == true
    cs.dead = true
    clientPD.metadata = { isdead = false, inlaststand = true }
end
local function Revive()
    cs.dead = false
    clientPD.metadata = { isdead = false, inlaststand = false }
end

-- the NUI of this build: it confirms every open
Nui('ready', { acks = true })

-- ============================================================================
--                   CLIENT: THE PICK-UP ENDS FOR ANY REASON
-- ============================================================================

-- The server's follow-up ended while the pick-up fade was up (here: recovered, the client missed any cancel): the
-- screen comes back at once, no teleport.
do
    GoDown(false)
    H.fire(CP.e('client:pickup'), nil, 'run-a', vec3(308.19, -595.35, 43.29))
    RunFor(1000)
    H.eq(cs.fade, 'out', 'pick-up: faded out')
    H.ok(OverlayOn(), 'pick-up: the fade overlay is on')
    Revive()
    H.fire(CP.e('client:downedEnded'), nil, 'run-a', 'recovered')
    RunFor(500)
    H.eq(cs.fade, 'in', 'downedEnded: faded back in')
    H.eq(OverlayOn(), false, 'downedEnded: overlay cleared')
    H.eq(cs.coordsSet, nil, 'downedEnded: no teleport')
    H.eq(CD.busy(), false, 'downedEnded: the pick-up stopped')
    local done = Sent('server:pickupDone')
    H.eq(done[#done] and done[#done].args[2], false, 'downedEnded: the server hears the pick-up gave up')
    -- an end for another run does not touch a running pick-up
    GoDown(false)
    H.fire(CP.e('client:pickup'), nil, 'run-b', vec3(308.19, -595.35, 43.29))
    RunFor(1000)
    H.fire(CP.e('client:downedEnded'), nil, 'run-other', 'recovered')
    RunFor(500)
    H.eq(CD.busy(), true, 'downedEnded of another run: the pick-up goes on')
    H.fire(CP.e('client:pickupCancel'), nil, 'run-b')
    RunFor(500)
    H.eq(CD.busy(), false, 'cancelled')
    Revive()
end

-- The overlay cannot be cleared twice in a row (the NUI call fails, in the abort and again in the error path): the
-- pick-up still ends, the server hears it once, the safety net at its end clears the overlay, and the next pick-up
-- is not refused as "one is running".
do
    local realOverlay = T.overlay
    local failures = 2
    T.overlay = function(o)
        if o == nil and failures > 0 then
            failures = failures - 1
            error('SendNUIMessage failed')
        end
        return realOverlay(o)
    end
    GoDown(false)
    H.fire(CP.e('client:pickup'), nil, 'run-c', vec3(308.19, -595.35, 43.29))
    RunFor(1000)
    H.fire(CP.e('client:pickupCancel'), nil, 'run-c')
    RunFor(500)
    T.overlay = realOverlay
    H.eq(CD.busy(), false, 'a failed abort: the pick-up is not left running')
    H.eq(cs.fade, 'in', 'a failed abort: faded back in')
    H.eq(OverlayOn(), false, 'a failed abort: the overlay is cleared by the safety net')
    H.ok(Logged('the pick-up fade or overlay was still on'), 'a failed abort: the safety net says what it undid')
    local reports = 0
    for _, e in ipairs(Sent('server:pickupDone')) do if e.args[1] == 'run-c' then reports = reports + 1 end end
    H.eq(reports, 1, 'a failed abort: pickupDone sent once')
    H.fire(CP.e('client:pickup'), nil, 'run-d', vec3(308.19, -595.35, 43.29))
    RunFor(1000)
    H.eq(cs.fade, 'out', 'the next pick-up runs')
    H.fire(CP.e('client:downedEnded'), nil, 'run-d', 'cancelled')
    RunFor(500)
    H.eq(cs.fade, 'in', 'and ends')
    Revive()
end

-- Every run end runs the safety net (nothing of the pick-up may outlive a run).
do
    local realRestore, calls = CD.restore, {}
    CD.restore = function(why)
        calls[#calls + 1] = why
        return realRestore(why)
    end
    H.fire(CP.e('client:start'), nil, 'run-e', {
        missionId = 'beat_patrol',
        mission = { id = 'beat_patrol', label = 'Beat Patrol', objectives = {} },
        start = { coords = vec3(0.0, 300.0, 0.0), radius = 40.0 },
        participants = {},
        startRoute = true,
    })
    RunFor(1000)
    H.fire(CP.e('client:runEnded'), nil, 'run-e', 'failed', 'quit', nil)
    CD.restore = realRestore
    H.eq(calls[1], 'run end', 'run end: CP.Downed.restore is called')
end

-- ============================================================================
--                        CLIENT: THE TABLET WHILE DOWN
-- ============================================================================

-- Open, then the officer goes down: the tablet closes and the NUI focus goes.
do
    H.clockMs = H.clockMs + 1000
    H.commands.CrimsonPolice.fn()
    RunFor(200)
    H.eq(T.isOpen(), true, 'down: tablet open')
    H.eq(cs.focus, true, 'down: NUI focus taken')
    local open = LastNui('open')
    Nui('opened', { seq = open and open.seq })
    GoDown(true)
    RunFor(1000)
    H.eq(T.isOpen(), false, 'down: the tablet closed when the officer went down')
    H.eq(cs.focus, false, 'down: the NUI focus is released')
    H.eq(LastNui('close') ~= nil, true, 'down: the NUI was told to close')
    -- opening while down is refused, and the focus is never taken
    local calls = cs.focusCalls
    H.clockMs = H.clockMs + 1000
    H.commands.CrimsonPolice.fn()
    RunFor(200)
    H.eq(T.isOpen(), false, 'down: no tablet while down')
    H.eq(cs.focusCalls, calls, 'down: the focus is not touched')
    local ok, err = T.open('officer')
    H.eq(ok, false, 'down: open refused')
    H.eq(err, 'err.downed', 'down: with err.downed')
    Revive()
    RunFor(200)
    H.eq(T.open('officer'), true, 'revived: it opens again')
    Nui('opened', { seq = LastNui('open').seq })
    T.close()
    H.eq(cs.focus, false, 'closed')
end

-- ============================================================================
--               CLIENT: THE NUI MUST SHOW WHAT IT WAS OPENED ON
-- ============================================================================

do
    -- no confirmation (the page crashed or never loaded): the focus is not kept on an empty page
    H.eq(T.open('officer'), true, 'ack: opened')
    H.eq(cs.focus, true, 'ack: focus taken')
    RunFor(5000)
    H.eq(T.isOpen(), true, 'ack: still open while the NUI may be slow')
    RunFor(1500)
    H.eq(T.isOpen(), false, 'ack: no confirmation in 6 s: closed')
    H.eq(cs.focus, false, 'ack: the NUI focus is released')
    H.ok(Logged('the NUI did not show the officer UI'), 'ack: the F8 console says why')
    -- confirmed: stays open
    H.eq(T.open('officer'), true, 'ack: opened again')
    Nui('opened', { seq = LastNui('open').seq })
    RunFor(10000)
    H.eq(T.isOpen(), true, 'ack: confirmed: stays open')
    -- a stale confirmation does not count for a newer open
    T.close()
    local oldSeq = LastNui('open').seq
    H.eq(T.open('officer'), true, 'ack: a third open')
    Nui('opened', { seq = oldSeq })
    RunFor(6500)
    H.eq(T.isOpen(), false, 'ack: an old seq does not confirm the new open')
    -- an NUI that does not confirm (an older web build) is never closed for it
    Nui('ready', {})
    H.eq(T.open('officer'), true, 'ack: open with an NUI that does not confirm')
    RunFor(10000)
    H.eq(T.isOpen(), true, 'ack: no check without the acks flag')
    T.close()
    Nui('ready', { acks = true })
end

-- ============================================================================
--                                    CLIENT
-- ============================================================================
-- THE OWNER'S SEQUENCE (02:20:49 - 02:22:40), CLIENT SIDE.
-- Suspicious Activity 5963 m away, down in the car on the way (no flag), the run ends as failed, a pick-up is
-- announced, someone else revives him 13 s later, the server ends the follow-up at the 15 s recheck. With the
-- tablet open when he goes down (it cannot stay open: variant B of the investigation) and closed (variant A).

local function OwnerSequence(tabletOpen)
    local runId = tabletOpen and 'bcb3-b' or 'bcb3-a'
    H.fire(CP.e('client:start'), nil, runId, {
        missionId = 'suspicious_activity',
        mission = { id = 'suspicious_activity', label = 'Suspicious Activity', objectives = {} },
        start = { coords = vec3(0.0, 5963.0, 0.0), radius = 40.0 },
        participants = { { src = 1, status = 'active' } },
        startRoute = true,
        expectedTier = 'standard',
    })
    cs.inVeh = true
    for _ = 1, 26 do
        RunFor(2000)
        cs.pos = vec3(0.0, cs.pos.y + 30.0, 0.0)
    end
    H.ok(cs.waypoint ~= nil, 'owner: the waypoint is set on the way')
    if tabletOpen then
        -- stopped at the roadside and opened the tablet
        H.clockMs = H.clockMs + 1000
        H.commands.CrimsonPolice.fn()
        RunFor(200)
        Nui('opened', { seq = LastNui('open').seq })
        H.eq(cs.focus, true, 'owner B: the tablet is open')
    end
    GoDown(true)
    RunFor(1000)
    cs.dead = false                   -- sc-ambulance resurrects him in last stand, in his seat
    H.fire(CP.e('client:runEnded'), nil, runId, 'failed', 'downed', {
        result = 'failed',
        endReason = 'downed',
        points = { total = 0 },
        cash = { amount = 0 },
    })
    H.fire(CP.e('client:notify'), nil, { kind = 'info', key = 'downed.pickup_soon', vars = { seconds = 15 } })
    H.fire(CP.e('client:push'), nil, 'run', nil)
    RunFor(13000)
    Revive()
    RunFor(2000)
    H.fire(CP.e('client:downedEnded'), nil, runId, 'recovered')
    RunFor(60000)
    H.eq(cs.fade, 'in', 'owner: the screen is faded in')
    H.eq(cs.focus, false, 'owner: no NUI focus is held')
    H.eq(OverlayOn(), false, 'owner: no Crimson-Police overlay')
    H.eq(cs.waypoint, nil, 'owner: our waypoint is gone')
    H.eq(CR.current(), nil, 'owner: no run on the client')
    H.eq(CP.Route.current(), nil, 'owner: no route')
    H.eq(CD.busy(), false, 'owner: no pick-up running')
    H.eq(T.isOpen(), false, 'owner: the tablet is closed')
    H.eq(LastNui('hud') and LastNui('hud').hud, nil, 'owner: the ended HUD hid itself')
    H.eq(#spins, 0, 'owner: no client thread ran without a Wait')
    cs.inVeh = false
    cs.pos = vec3(0.0, 0.0, 0.0)
end

OwnerSequence(false)
OwnerSequence(true)

-- ============================================================================
--                       CLIENT: CrimsonPoliceState (F8)
-- ============================================================================

do
    local function StateText(args)
        local first = #logs + 1
        H.commands.CrimsonPoliceState.fn(0, args or {})
        local out = {}
        for i = first, #logs do out[#out + 1] = logs[i] end
        return table.concat(out, '\n')
    end
    local text = StateText()
    H.ok(text:find('screen faded in, NUI focus no', 1, true) ~= nil, 'state: the screen and the focus')
    H.ok(text:find('Crimson-Police: tablet closed, panel focus none, pick-up idle, run none', 1, true) ~= nil,
        'state: what Crimson-Police holds')
    H.ok(text:find('nothing stuck', 1, true) ~= nil, 'state: nothing stuck')
    -- another resource holds the NUI focus (a page that froze): named as not ours
    cs.otherFocus = true
    text = StateText()
    H.ok(text:find('the NUI focus belongs to another resource', 1, true) ~= nil, 'state: another resource\'s focus')
    cs.otherFocus = false
    -- sc-ambulance still counts the player as down
    clientPD.metadata = { isdead = false, inlaststand = true }
    text = StateText()
    H.ok(text:find('sc-ambulance still counts the player as down', 1, true) ~= nil, 'state: still down')
    Revive()
    -- unstick: only ours
    H.eq(T.open('officer'), true, 'unstick: tablet open')
    Nui('opened', { seq = LastNui('open').seq })
    text = StateText({ 'unstick' })
    H.eq(T.isOpen(), false, 'unstick: our tablet closed')
    H.eq(cs.focus, false, 'unstick: our focus released')
    H.ok(text:find('nothing stuck', 1, true) ~= nil, 'unstick: then nothing stuck')
end

-- ============================================================================
--                    WEB: A CRASH NEVER KEEPS THE NUI FOCUS
-- ============================================================================
-- The React side of the same rule (the build itself is checked by tools/check_all.sh: tsc and build).

do
    local function Read(rel)
        local f = io.open(H.root .. rel, 'r')
        if not f then return '' end
        local s = f:read('a')
        f:close()
        return (s:gsub('%s+', ' '))
    end
    local app, main = Read('web/src/App.tsx'), Read('web/src/main.tsx')
    local qb = Read('web/src/shared/components/QuietBoundary.tsx')
    H.ok(app:find('fetchNui(\'ready\', { acks: true })', 1, true) ~= nil, 'web: ready says the NUI confirms opens')
    H.ok(app:find('fetchNui(\'opened\', { seq: openSeq })', 1, true) ~= nil, 'web: every open is confirmed')
    H.ok(app:find('onError={close}', 1, true) ~= nil, 'web: a crashed layout closes the tablet')
    H.ok(app:find('setUi(null); void fetchNui(\'close\', {});', 1, true) ~= nil,
        'web: an open that cannot be shown hands the focus back')
    for _, part in ipairs({ 'hud column', 'result card', 'overlay', 'toasts', 'debug overlay' }) do
        H.ok(app:find('<QuietBoundary name="' .. part .. '"', 1, true) ~= nil, 'web: boundary around the ' .. part)
    end
    H.ok(
        main:find('<QuietBoundary name="app"', 1, true) ~= nil and main:find('fetchNui(\'close\', {})', 1, true) ~= nil,
        'web: the root boundary hands the focus back')
    H.ok(qb:find('return this.state.error ? null : this.props.children;', 1, true) ~= nil,
        'web: a quiet boundary renders nothing for the broken part')
end

-- ============================================================================
--                    LINT FX10: LOOPS THAT CAN SKIP A WAIT
-- ============================================================================
-- tests/fixtures/lint/fx10_loops.lua: every loop line says the verdict tools/lua_flow.py must give it.

do
    local fixture = 'tests/fixtures/lint/fx10_loops.lua'
    local expected = {}
    local n = 0
    local fh = assert(io.open(fixture, 'r'))
    local ln = 0
    for line in fh:lines() do
        ln = ln + 1
        local v = line:match('%-%- expect (%a+)%s*$')
        if v then
            expected[ln] = v
            n = n + 1
        end
    end
    fh:close()
    H.ok(n >= 20, 'fx10: the fixture has its cases')
    local p = io.popen('python3 ' .. H.root .. '../tools/lua_flow.py --all ' .. fixture .. ' 2>&1')
    local got = {}
    for line in p:lines() do
        local at, verdict = line:match(':(%d+): (%a+) ')
        if at and verdict ~= 'RECURSION' then got[tonumber(at)] = verdict end
    end
    p:close()
    local lines = {}
    for at in pairs(expected) do lines[#lines + 1] = at end
    table.sort(lines)
    for _, at in ipairs(lines) do H.eq(got[at], expected[at], ('fx10: %s:%d'):format(fixture, at)) end
    local help = io.popen('python3 ' .. H.root .. '../tools/lint_fivem.py --help 2>&1')
    local text = help:read('a')
    help:close()
    H.ok(text:find('FX10 loop-no-yield', 1, true) ~= nil, 'fx10: lint_fivem.py runs the rule')
end

print = realPrint
return H

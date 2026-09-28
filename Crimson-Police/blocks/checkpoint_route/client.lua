--[[ blocks/checkpoint_route/client.lua · objective block "checkpoint_route" (client half)

  What it does
    Shows the current checkpoint (marker within 150 m, blip with GPS route; the next one dimmer),
    runs the local stop timer ("Hold still: 6 s") and reports the checkpoint when it counts; during a
    course it watches the driven vehicle for wall/vehicle contacts and for becoming undriveable.
    Everything the server decides arrives as a full snapshot through update(); the HUD line is
    composed here with ctx.hudDetail. Radio Silence: no blips, the HUD names the next street instead.
    No networked entities are created here; this block has no NPCs (hostChanged only records the flag).

  Objective fields read: radius [10], stopFor [10], policeVehicle [true], contactPenalty [2]
    (the server sends the checkpoint list, course state and which checks to run)
  Evidence sent (ctx.report)
    { type = 'checkpoint', index, netId?, vehClass?, model?, try }   inside the current checkpoint
        (police vehicle when required; stopped for stopFor seconds, or at once for drive-through)
    { type = 'contact', netId }       collision flag with a speed drop, a hard speed drop, or body damage
    { type = 'undriveable', netId }   the vehicle used on the course is no longer driveable
  Bonuses / penalties: none recorded on the client (the server records medal_* and no_contact).
]]

local BLOCK = 'checkpoint_route'

local VIEW_DISTANCE    = 150.0   -- markers are drawn only this close to the current checkpoint
local STOP_SPEED       = 1.5     -- m/s: slower than this counts as stopped
local RETRY_MS         = 2500    -- re-report a checkpoint the server has not confirmed yet
local SAMPLE_MS        = 100     -- contact sampling interval while the course runs
local CONTACT_GAP_MS   = 1500    -- at most one contact report per window
local SPEED_DROP_HIT   = 2.0     -- m/s lost in one sample together with the collision flag
local SPEED_DROP_CRASH = 6.0     -- m/s lost in one sample on its own
local BODY_DROP_HIT    = 5.0     -- body health lost in one sample on its own
local UNDRIVE_RETRY_MS = 3000
local UNDRIVE_TRIES    = 3       -- reports per course vehicle (the server verifies each one)
local STATUS_MS        = 700     -- lifetime of status lines refreshed every frame
local EVENT_MS         = 4000    -- lifetime of one-off lines

local live = {}   -- [state] = ctx, for resource-stop cleanup

local function v3(t)
    return vector3((t.x or 0.0) + 0.0, (t.y or 0.0) + 0.0, (t.z or 0.0) + 0.0)
end

local function h32(v)
    local n = math.tointeger(tonumber(v) or 0) or 0
    return n & 0xFFFFFFFF
end

local function isPoliceVehicle(veh)
    if not veh or veh == 0 or not DoesEntityExist(veh) then return false end
    local pv = Config.PoliceVehicles or {}
    local model = h32(GetEntityModel(veh))
    for _, name in ipairs(pv.models or {}) do
        if h32(joaat(name)) == model then return true end
    end
    local class = GetVehicleClass(veh)
    for _, c in ipairs(pv.classes or {}) do
        if c == class then return true end
    end
    return false
end

local function netIdOf(veh)
    if veh and veh ~= 0 and DoesEntityExist(veh) and NetworkGetEntityIsNetworked(veh) then
        return NetworkGetNetworkIdFromEntity(veh)
    end
    return nil
end

local function fmt(seconds)
    return ('%.1f'):format(tonumber(seconds) or 0)
end

-- ── HUD line ────────────────────────────────────────────────────────────────
local function say(st, text, ms)
    st.transient = text
    st.transientUntil = GetGameTimer() + (ms or EVENT_MS)
end

local function streetLine(p)
    local s1 = GetStreetNameAtCoord(p.x, p.y, p.z)
    local street = GetStreetNameFromHashKey(s1)
    local zone = GetLabelText(GetNameOfZone(p.x, p.y, p.z))
    return CP.L('block.checkpoint_route.hud.next_street', { street = street, zone = zone })
end

local function baseLine(ctx, st, t)
    local d = st.data
    if not d then return nil end
    if d.finished then
        if d.medals and d.course and d.course.time then
            local key = d.course.medal and ('block.checkpoint_route.hud.medal_' .. d.course.medal) or 'block.checkpoint_route.hud.no_medal'
            return CP.L('block.checkpoint_route.hud.finished_time', { time = fmt(d.course.time) }) .. ' · ' .. CP.L(key)
        end
        return CP.L('block.checkpoint_route.hud.finished')
    end
    if not d.current then return nil end
    local text = CP.L('block.checkpoint_route.hud.progress', { n = d.current, total = d.total })
    if st.courseRunning and d.medals then
        local elapsed = (t - (st.courseStartLocal or t)) / 1000
        text = text .. ' · ' .. CP.L('block.checkpoint_route.hud.course_time', { time = fmt(elapsed), penalty = (d.course and d.course.penalty) or 0 })
    end
    if ctx.radioSilence then
        if not st.street then st.street = streetLine(st.points[d.current]) end
        text = text .. ' · ' .. st.street
    end
    return text
end

local function refreshLine(ctx, st, t)
    local text
    if st.transient and t < (st.transientUntil or 0) then
        text = st.transient
    else
        st.transient = nil
        text = baseLine(ctx, st, t)
    end
    if text ~= st.line then
        st.line = text
        ctx.hudDetail(text)
    end
end

-- ── Blips ───────────────────────────────────────────────────────────────────
local function clearBlips(st)
    for _, b in ipairs(st.blips or {}) do
        if DoesBlipExist(b) then
            SetBlipRoute(b, false)
            RemoveBlip(b)
        end
    end
    st.blips = {}
end

local function addBlip(st, p, text, colour, scale, route)
    local b = AddBlipForCoord(p.x, p.y, p.z)
    SetBlipSprite(b, 1)
    SetBlipColour(b, colour)
    SetBlipScale(b, scale)
    SetBlipAsShortRange(b, false)
    if route then
        SetBlipRoute(b, true)
        SetBlipRouteColour(b, colour)
    end
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandSetBlipName(b)
    st.blips[#st.blips + 1] = b
end

local function refreshBlips(ctx, st)
    clearBlips(st)
    local d = st.data
    if ctx.radioSilence or not d or d.finished or not d.current then return end
    local cur = st.points[d.current]
    if cur then addBlip(st, cur, CP.L('block.checkpoint_route.blip', { n = d.current }), 1, 0.9, true) end
    local nxt = st.points[d.current + 1]
    if nxt then addBlip(st, nxt, CP.L('block.checkpoint_route.blip', { n = d.current + 1 }), 5, 0.6, false) end
end

-- ── Checks ──────────────────────────────────────────────────────────────────
local function drawMarkers(ctx, st, d, pos)
    local r = tonumber(ctx.obj.radius) or 10.0
    local cur = st.points[d.current]
    DrawMarker(1, cur.x, cur.y, cur.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, r * 2.0, r * 2.0, 2.0,
        220, 40, 50, 110, false, false, 2, false, nil, nil, false)
    local nxt = st.points[d.current + 1]
    if nxt and #(pos - nxt) < VIEW_DISTANCE then
        DrawMarker(1, nxt.x, nxt.y, nxt.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, r * 2.0, r * 2.0, 1.0,
            240, 200, 60, 60, false, false, 2, false, nil, nil, false)
    end
end

local function report(ctx, st, k, veh, t)
    if st.reported == k and t - (st.reportedAt or 0) < RETRY_MS then return end
    st.reported, st.reportedAt = k, t
    st.tries = (st.tries or 0) + 1
    local ev = { type = 'checkpoint', index = k, try = st.tries }
    if veh ~= 0 then
        ev.netId = netIdOf(veh)
        ev.vehClass = GetVehicleClass(veh)
        ev.model = GetEntityModel(veh)
        st.courseVeh = veh
    end
    ctx.report(ev)
end

local function inside2d(pos, p, r)
    local dx, dy = pos.x - p.x, pos.y - p.y
    return dx * dx + dy * dy <= r * r and math.abs(pos.z - p.z) < 8.0
end

local function checkInside(ctx, st, d, pos, veh, t)
    local r = tonumber(ctx.obj.radius) or 10.0
    local cur = st.points[d.current]
    if not inside2d(pos, cur, r) then
        st.holdStart = nil
        for j = d.current + 1, math.min(d.current + 3, d.total or 0) do
            local p = st.points[j]
            if p and inside2d(pos, p, r) and st.missedHint ~= j then
                st.missedHint = j
                say(st, CP.L('block.checkpoint_route.hud.missed', { n = d.current }))
            end
        end
        return
    end
    if ctx.obj.policeVehicle ~= false and not isPoliceVehicle(veh) then
        st.holdStart = nil
        say(st, CP.L('block.checkpoint_route.hud.need_police'), STATUS_MS)
        return
    end
    local stopFor = tonumber(ctx.obj.stopFor) or 0
    if stopFor <= 0 then
        report(ctx, st, d.current, veh, t)
        return
    end
    local ent = veh ~= 0 and veh or PlayerPedId()
    if GetEntitySpeed(ent) > STOP_SPEED then
        st.holdStart = nil
        say(st, CP.L('block.checkpoint_route.hud.stop_here'), STATUS_MS)
        return
    end
    st.holdStart = st.holdStart or t
    local left = math.ceil(stopFor - (t - st.holdStart) / 1000)
    if left > 0 then
        if st.holdShown ~= left or not st.transient then
            st.holdShown = left
            say(st, CP.L('block.checkpoint_route.hud.hold', { seconds = left }), 1100)
        end
    else
        report(ctx, st, d.current, veh, t)
        say(st, CP.L('block.checkpoint_route.hud.hold_done'), STATUS_MS)
    end
end

local function checkContact(ctx, st, veh, t)
    if veh == 0 or GetPedInVehicleSeat(veh, -1) ~= PlayerPedId() then
        st.lastSpeed, st.lastBody, st.collided = nil, nil, false
        return
    end
    if HasEntityCollidedWithAnything(veh) then st.collided = true end
    if t - (st.sampleAt or 0) < SAMPLE_MS then return end
    st.sampleAt = t
    local speed = GetEntitySpeed(veh)
    local body = GetVehicleBodyHealth(veh)
    local drop = st.lastSpeed and (st.lastSpeed - speed) or 0.0
    local bodyDrop = st.lastBody and (st.lastBody - body) or 0.0
    st.lastSpeed, st.lastBody = speed, body
    local hit = (st.collided and (drop >= SPEED_DROP_HIT or bodyDrop > 0.5)) or drop >= SPEED_DROP_CRASH or bodyDrop >= BODY_DROP_HIT
    st.collided = false
    if hit and t - (st.lastContact or 0) >= CONTACT_GAP_MS then
        st.lastContact = t
        ctx.report({ type = 'contact', netId = netIdOf(veh) })
        local pen = tonumber(ctx.obj.contactPenalty) or 0
        if pen > 0 then say(st, CP.L('block.checkpoint_route.hud.contact', { seconds = pen }), 2500) end
    end
end

local function checkUndriveable(ctx, st, t)
    local veh = st.courseVeh
    if not veh or veh == 0 or not DoesEntityExist(veh) then return end
    if IsVehicleDriveable(veh, false) and GetVehicleEngineHealth(veh) > 0.0 then return end
    if t - (st.undriveableAt or 0) < UNDRIVE_RETRY_MS then return end
    if st.undriveableVeh ~= veh then st.undriveableVeh, st.undriveableTries = veh, 0 end
    if st.undriveableTries >= UNDRIVE_TRIES then return end
    st.undriveableTries = st.undriveableTries + 1
    st.undriveableAt = t
    local netId = netIdOf(veh)
    if netId then ctx.report({ type = 'undriveable', netId = netId }) end
end

local function loop(ctx, st)
    local token = st.token
    CreateThread(function()
        while st.alive and st.token == token do
            local sleep = 500
            local t = GetGameTimer()
            local d = st.data
            if d and not d.finished and d.current and st.points[d.current] then
                local ped = PlayerPedId()
                local pos = GetEntityCoords(ped)
                local veh = GetVehiclePedIsIn(ped, false)
                if #(pos - st.points[d.current]) < VIEW_DISTANCE then
                    sleep = 0
                    drawMarkers(ctx, st, d, pos)
                    checkInside(ctx, st, d, pos, veh, t)
                end
                if st.courseRunning then
                    if sleep > SAMPLE_MS then sleep = SAMPLE_MS end
                    if st.track.contacts then checkContact(ctx, st, veh, t) end
                    if st.track.undriveable then checkUndriveable(ctx, st, t) end
                end
            end
            refreshLine(ctx, st, t)
            Wait(sleep)
        end
    end)
end

-- ── Snapshot from the server ────────────────────────────────────────────────
local function apply(ctx, st, data)
    st.data = data
    st.points = {}
    for i, p in ipairs(data.points or {}) do st.points[i] = v3(p) end
    st.track = data.track or {}
    local running = data.course and data.course.running == true
    if running and not st.courseRunning then
        st.courseStartLocal = GetGameTimer() - ((data.course and data.course.elapsedMs) or 0)
    end
    st.courseRunning = running
    if st.lastCurrent ~= data.current then
        if st.lastCurrent ~= nil and data.current ~= nil then
            PlaySoundFrontend(-1, 'CHECKPOINT_NORMAL', 'HUD_MINI_GAME_SOUNDSET', false)
        end
        st.lastCurrent = data.current
        st.holdStart, st.reported, st.missedHint, st.street, st.transient = nil, nil, nil, nil, nil
        refreshBlips(ctx, st)
    end
    if data.finished and not st.finishedShown then
        st.finishedShown = true
        clearBlips(st)
        PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', false)
    end
end

local function cleanup(ctx, st)
    st.alive = false
    st.token = (st.token or 0) + 1
    clearBlips(st)
    if st.line ~= nil then
        st.line = nil
        ctx.hudDetail(nil)
    end
    live[st] = nil
end

CP.Blocks.register(BLOCK, {
    prepare = function(ctx)
        local st = ctx.state
        st.blips = st.blips or {}
        st.track = st.track or {}
    end,

    start = function(ctx)
        local st = ctx.state
        st.blips = st.blips or {}
        st.track = st.track or {}
        st.points = st.points or {}
        st.alive = true
        st.token = (st.token or 0) + 1
        live[st] = ctx
        if st.pending then
            local data = st.pending
            st.pending = nil
            apply(ctx, st, data)
        end
        loop(ctx, st)
    end,

    update = function(ctx, data)
        if type(data) ~= 'table' or data.kind ~= 'state' then return end
        local st = ctx.state
        if st.alive then apply(ctx, st, data) else st.pending = data end
    end,

    -- No NPCs in this block: nothing to re-task when the host changes.
    hostChanged = function(ctx, isHost)
        ctx.state.isHost = isHost == true
    end,

    stop = function(ctx)
        cleanup(ctx, ctx.state)
    end,
})

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for st, ctx in pairs(live) do cleanup(ctx, st) end
end)

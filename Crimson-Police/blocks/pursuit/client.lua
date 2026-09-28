--[[ blocks/pursuit/client.lua · objective block "pursuit" (client half)

  What it does (while the objective is current on this participant's client)
    - every participant: reports rams of suspect vehicles by the car they drive (IsEntityTouchingEntity
      rising edge, polled every RAM_POLL_MS only while a suspect vehicle is within RAM_WATCH; speed =
      the pre-impact speed) when ramSpeed is 0 or the speed is above it; 'lights_near' when their lights
      or siren are on within trigger.distance of a waiting car; 'aim' after aiming at an unarmed
      suspect on foot for AIM_HOLD_MS (AIM_STOPPED by the car, flee_arrest.aimDistance when running);
      'stunned' when IsPedBeingStunned; follow mode: 'undriveable' when the car they drive is no
      longer driveable. The server re-checks every report with its own coordinates.
    - blips for suspect vehicles and suspects on foot (none with Radio Silence) and a HUD line
      (ctx.hudDetail): follow progress / lost countdown, escape countdown, lights hint, stop and
      detain progress, aim hint.
    - on the run host only: CP.Npc.apply once it has control of each suspect, seats them, locks the
      car, then drives: CP.Npc.task(driver, 'driveRoute', { vehicle, points, loop, speed (m/s),
      drivingStyle, style, stopRange }) from the next waypoint of the route (a loop is re-tasked lap by
      lap, an open route ends in a free flee), or CP.Npc.task(driver, 'flee', { vehicle, speed,
      drivingStyle, style }) for a free flee; a stuck car is re-tasked every RETASK_MS. After a stop the
      occupants leave the car (TaskLeaveVehicle); fleeing -> CP.Npc 'flee', hostile -> 'combat', and on
      first sight (new host) surrendered -> 'kneel', cuffed -> 'cuffed'. The arrest target ("Detain
      driver" / "Cuff suspect") is CP.Npc's (enableCuff). Everything is re-applied after hostChanged.

  Objective fields read: mode, route, speed, style, trigger, surrenderOnAim, ramSpeed, failIfUndriveable,
    neverShoots (ctx.obj); location[route].
  Evidence sent: { type = 'ram', netId, speed }, { type = 'lights_near', netId }, { type = 'aim', netId },
    { type = 'stunned', netId }, { type = 'undriveable', netId }
  Server data (update): { kind = 'state', mode, fled, trigger, lights, vehicles = { { netId, index, state,
    occupants } }, suspects = { { netId, vehicle, seat, state, armed } }, detained, neutralised, total,
    stopped, vtotal, escaping, follow = { inRange, duration, hold, lost, average } }
]]

local BLOCK = 'pursuit'
local U = CP.U

local FAST_MS       = 250
local SLOW_MS       = 1000
local RAM_POLL_MS   = 50
local RAM_IDLE_MS   = 500
local RAM_WATCH     = 25.0
local RAM_REPORT_MS = 2500
local REPORT_MS     = 1500
local AIM_HOLD_MS   = 800
local AIM_STOPPED   = 25.0
local WATCH_RANGE   = 60.0
local CONTROL_MS    = 250
local RETASK_MS     = 10000
local STUCK_MPS     = 2.0
local ROUTE_END     = 30.0
local STOP_RANGE    = 8.0

-- TaskVehicleDriveToCoordLongrange driving styles. Both keep to the road network.
local STYLES = {
    cautious = 786603,       -- stops for vehicles, peds and lights
    reckless = 1074528293,   -- rushed: swerves around traffic, ignores lights
}

local active = {}

local function keyOf(ctx) return tostring(ctx.runId) .. ':' .. tostring(ctx.index) end

local function S_of(ctx)
    local k = keyOf(ctx)
    local S = active[k]
    if not S then
        S = {
            key = k, vehicles = {}, suspects = {}, byNet = {}, blips = {}, applied = {}, tasked = {},
            drive = {}, left = {}, lastReport = {}, aimSince = {}, touching = {}, alive = true, data = {},
        }
        active[k] = S
    end
    S.ctx = ctx
    return S
end

local function isHost(S)
    if S.isHost ~= nil then return S.isHost end
    return S.ctx.isHost == true
end

local function entityFor(netId)
    if not netId or not NetworkDoesNetworkIdExist(netId) then return nil end
    local e = NetworkGetEntityFromNetworkId(netId)
    if e and e ~= 0 and DoesEntityExist(e) then return e end
    return nil
end

local function bagOf(ent)
    local st = Entity(ent).state
    return st and st.cp or nil
end

local function toVec3(v)
    local x, y, z = U.xyz(v)
    if not x then return nil end
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

local function routeInfo(S)
    if S.route ~= nil then return S.route or nil end
    local ctx = S.ctx
    local ref = ctx.obj and ctx.obj.route
    local v = type(ref) == 'string' and ctx.location and ctx.location[ref] or ref
    S.route = false
    if type(v) == 'table' then
        local list = type(v.points) == 'table' and v.points or v
        local pts = {}
        for i = 1, #list do
            local p = toVec3(list[i])
            if p then pts[#pts + 1] = p end
        end
        if #pts >= 2 then S.route = { points = pts, loop = v.loop == true } end
    end
    return S.route or nil
end

-- Waypoints still ahead of pos: the rest of an open route, or one full lap of a loop.
local function remaining(route, pos)
    local pts = route.points
    local n = #pts
    local bi, best = 1, math.huge
    for i = 1, n do
        local d = #(pts[i].xy - pos.xy)
        if d < best then best, bi = d, i end
    end
    local nextI = bi
    local b = pts[bi]
    local a = pts[bi + 1] or (route.loop and pts[1]) or nil
    if a then
        local dir = a - b
        local rel = pos - b
        if dir.x * rel.x + dir.y * rel.y > 0 or best < STOP_RANGE then nextI = bi + 1 end
    elseif best < ROUTE_END then
        nextI = n + 1
    end
    local out = {}
    if route.loop then
        for k = 0, n - 1 do out[#out + 1] = pts[((nextI - 1 + k) % n) + 1] end
    else
        for i = math.min(nextI, n + 1), n do out[#out + 1] = pts[i] end
    end
    return out
end

-- ── Blips ───────────────────────────────────────────────────────────────────
local function dropBlip(S, k)
    local b = S.blips[k]
    if not b then return end
    if DoesBlipExist(b.id) then RemoveBlip(b.id) end
    S.blips[k] = nil
end

local function ensureBlip(S, k, ent, sprite, label, scale)
    local b = S.blips[k]
    if b and b.ent == ent and DoesBlipExist(b.id) then return end
    dropBlip(S, k)
    local id = AddBlipForEntity(ent)
    SetBlipSprite(id, sprite)
    SetBlipColour(id, 1)
    SetBlipScale(id, scale)
    SetBlipAsShortRange(id, false)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(id)
    S.blips[k] = { id = id, ent = ent }
end

-- ── Reports ─────────────────────────────────────────────────────────────────
local function reportOnce(S, kind, netId, extra)
    local k = kind .. ':' .. tostring(netId)
    local t = GetGameTimer()
    local last = S.lastReport[k]
    if last and t - last < ((kind == 'ram') and RAM_REPORT_MS or REPORT_MS) then return end
    S.lastReport[k] = t
    local ev = { type = kind, netId = netId }
    if extra then for key, v in pairs(extra) do ev[key] = v end end
    S.ctx.report(ev)
end

local function setHint(S, text)
    if S.hint == text then return end
    S.hint = text
    S.ctx.hudDetail(text)
end

-- ── Host AI ─────────────────────────────────────────────────────────────────
local function driverSetup(ped, reckless)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedKeepTask(ped, true)
    SetPedCanBeDraggedOut(ped, false)
    SetPedConfigFlag(ped, 32, false)            -- no flying through the windscreen
    SetDriverAbility(ped, 1.0)
    SetDriverAggressiveness(ped, reckless and 1.0 or 0.4)
end

local function taskDrive(S, v, veh, driver)
    local obj = S.ctx.obj
    local speed = (tonumber(obj.speed) or 120) / 3.6
    local style = STYLES[obj.style] or STYLES.reckless
    local route = routeInfo(S)
    local d = S.drive[v.netId] or {}
    S.drive[v.netId] = d
    d.at = GetGameTimer()
    if route and not d.free then
        local pts = remaining(route, GetEntityCoords(veh))
        if #pts > 0 then
            d.mode, d.last = 'route', pts[#pts]
            CP.Npc.task(driver, 'driveRoute', {
                vehicle = veh, points = pts, loop = route.loop, speed = speed, drivingStyle = style,
                style = obj.style, stopRange = STOP_RANGE,
            })
            return
        end
        d.free = true
    end
    d.mode, d.last = 'flee', nil
    CP.Npc.task(driver, 'flee', { vehicle = veh, speed = speed, drivingStyle = style, style = obj.style })
end

local function monitorDrive(S, v, veh, driver)
    local d = S.drive[v.netId]
    if not d then
        taskDrive(S, v, veh, driver)
        return
    end
    local pos = GetEntityCoords(veh)
    if d.mode == 'route' and d.last and #(pos - d.last) <= ROUTE_END then
        local route = routeInfo(S)
        if not (route and route.loop) then d.free = true end
        taskDrive(S, v, veh, driver)
        return
    end
    if GetEntitySpeed(veh) < STUCK_MPS and GetGameTimer() - (d.at or 0) >= RETASK_MS then
        taskDrive(S, v, veh, driver)
    end
end

-- Control + CP.Npc.apply once per entity handle (a new handle after streaming or a new host re-applies).
local function applyPed(S, net, ped)
    if S.applied[net] == ped then return true end
    if not S.ctx.control(ped, CONTROL_MS) then return false end
    local bag = bagOf(ped)
    CP.Npc.apply(ped, (bag and bag.cfg) or {})
    driverSetup(ped, S.ctx.obj.style ~= 'cautious')
    S.applied[net] = ped
    S.tasked[net] = nil
    S.left[net] = nil
    return true
end

local function hostVehicle(S, v)
    local veh = entityFor(v.netId)
    if not veh then return end
    local fresh = false
    if S.applied[v.netId] ~= veh then
        if not S.ctx.control(veh, CONTROL_MS) then return end
        SetVehicleDoorsLocked(veh, 2)
        SetVehicleEngineOn(veh, true, true, false)
        S.applied[v.netId] = veh
        S.drive[v.netId] = nil
        fresh = true
    end
    local driver
    for _, net in ipairs(v.occupants or {}) do
        local info = S.byNet[net]
        local ped = entityFor(net)
        if info and ped then
            if applyPed(S, net, ped) then
                local state = (bagOf(ped) or {}).state or info.state
                if state == 'driving' then
                    if not IsPedInVehicle(ped, veh, false) then SetPedIntoVehicle(ped, veh, info.seat or -1) end
                    if (info.seat or -1) == -1 then driver = ped end
                elseif IsPedInVehicle(ped, veh, false) and not S.left[net] then
                    S.left[net] = true
                    TaskLeaveVehicle(ped, veh, 256)
                end
            end
        end
    end
    if v.state == 'fleeing' and driver then
        if fresh then S.drive[v.netId] = nil end
        monitorDrive(S, v, veh, driver)
    elseif v.state == 'stopped' or v.state == 'wrecked' then
        if not S.drive[v.netId] or S.drive[v.netId].mode ~= 'off' then
            S.drive[v.netId] = { mode = 'off' }
            SetVehicleEngineOn(veh, false, true, true)
        end
    end
end

local function hostSuspect(S, info, ped)
    if not applyPed(S, info.netId, ped) then return end
    local state = (bagOf(ped) or {}).state or info.state
    if IsPedInAnyVehicle(ped, false) then return end
    if S.tasked[info.netId] == state then return end
    if state == 'fleeing' then
        CP.Npc.task(ped, 'flee', {})
    elseif state == 'hostile' then
        CP.Npc.task(ped, 'combat', {})
    elseif state == 'surrendered' then
        CP.Npc.task(ped, 'kneel', {})
    elseif state == 'cuffed' then
        CP.Npc.task(ped, 'cuffed', {})
    end
    S.tasked[info.netId] = state
end

-- ── Loops ───────────────────────────────────────────────────────────────────
local function myVehicle()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then return veh end
    return nil
end

local function ramLoop(S)
    if S.ramming then return end
    S.ramming = true
    CreateThread(function()
        local lastSpeed = 0.0
        while S.alive do
            local wait = RAM_IDLE_MS
            local veh = S.current and myVehicle() or nil
            if veh then
                local limit = tonumber(S.ctx.obj.ramSpeed) or 0
                local pos = GetEntityCoords(veh)
                local speed = GetEntitySpeed(veh) * 3.6
                local pre = math.max(lastSpeed, speed)
                for _, v in ipairs(S.vehicles) do
                    local sv = entityFor(v.netId)
                    if sv and #(GetEntityCoords(sv) - pos) <= RAM_WATCH then
                        wait = RAM_POLL_MS
                        local touching = IsEntityTouchingEntity(veh, sv)
                        if touching and not S.touching[v.netId] and (limit <= 0 or pre > limit) then
                            reportOnce(S, 'ram', v.netId, { speed = math.floor(pre + 0.5) })
                        end
                        S.touching[v.netId] = touching
                    else
                        S.touching[v.netId] = nil
                    end
                end
                lastSpeed = speed
            else
                lastSpeed = 0.0
            end
            Wait(wait)
        end
        S.ramming = false
    end)
end

local function hudText(S, myPos)
    local d = S.data
    local obj = S.ctx.obj
    if d.mode == 'follow' then
        local f = d.follow or {}
        if f.lost then return CP.L('block.pursuit.hud_lost', { seconds = f.lost }) end
        if not d.fled then return CP.L('block.pursuit.hud_wait') end
        local dist
        for _, v in ipairs(S.vehicles) do
            local e = entityFor(v.netId)
            if e and v.state ~= 'wrecked' then dist = #(GetEntityCoords(e) - myPos) break end
        end
        return CP.L('block.pursuit.hud_follow', {
            held = math.min(f.inRange or 0, f.duration or 0), duration = f.duration or 0,
            distance = dist and math.floor(dist + 0.5) or '-', hold = f.hold or obj.hold,
        })
    end
    if d.escaping then return CP.L('block.pursuit.hud_escaping', { seconds = d.escaping }) end
    if not d.fled and d.trigger == 'distance' then
        return d.lights and CP.L('block.pursuit.hud_lights') or CP.L('block.pursuit.hud_approach')
    end
    if obj.surrenderOnAim then
        for _, s in ipairs(S.suspects) do
            if s.state == 'stopped' and not s.armed then
                local e = entityFor(s.netId)
                if e and #(GetEntityCoords(e) - myPos) <= AIM_STOPPED then return CP.L('block.pursuit.hint_aim') end
            end
        end
    end
    if (d.stopped or 0) < (d.vtotal or 0) then
        return CP.L('block.pursuit.hud_stop', { stopped = d.stopped or 0, total = d.vtotal or 0 })
    end
    return CP.L('block.pursuit.hud_detain', { detained = d.detained or 0, total = d.total or 0 })
end

local function loop(S)
    if S.looping then return end
    S.looping = true
    CreateThread(function()
        while S.alive do
            local fast = false
            if S.current then
                local ctx = S.ctx
                local obj = ctx.obj
                local d = S.data
                local me = PlayerPedId()
                local myPos = GetEntityCoords(me)
                local host = isHost(S)
                local showBlips = not ctx.radioSilence
                local aimRun = Config.Blocks.flee_arrest.aimDistance[3]
                local myVeh = GetVehiclePedIsIn(me, false)
                for _, v in ipairs(S.vehicles) do
                    if host then hostVehicle(S, v) end
                    local veh = entityFor(v.netId)
                    local k = 'v' .. tostring(v.netId)
                    if veh and showBlips and (v.state == 'fleeing' or v.state == 'waiting') then
                        ensureBlip(S, k, veh, 225, CP.L('block.pursuit.blip_vehicle'), 0.9)
                    else
                        dropBlip(S, k)
                    end
                    if veh and v.state == 'waiting' and d.trigger == 'distance' and d.lights and myVeh ~= 0
                        and IsVehicleSirenOn(myVeh) and #(GetEntityCoords(veh) - myPos) <= (tonumber(obj.trigger and obj.trigger.distance) or 60.0) then
                        reportOnce(S, 'lights_near', v.netId)
                    end
                    if veh and #(GetEntityCoords(veh) - myPos) <= WATCH_RANGE then fast = true end
                end
                for _, s in ipairs(S.suspects) do
                    local ped = entityFor(s.netId)
                    local k = 's' .. tostring(s.netId)
                    if ped then
                        local state = (bagOf(ped) or {}).state or s.state
                        if host and state ~= 'dead' then hostSuspect(S, s, ped) end
                        local onFoot = (state == 'stopped' or state == 'fleeing' or state == 'hostile') and not IsPedInAnyVehicle(ped, false)
                        if showBlips and onFoot then
                            ensureBlip(S, k, ped, 1, CP.L('block.pursuit.blip_suspect'), 0.7)
                        elseif showBlips and state == 'surrendered' then
                            ensureBlip(S, k, ped, 1, CP.L('block.pursuit.blip_suspect'), 0.6)
                        else
                            dropBlip(S, k)
                        end
                        if onFoot then
                            local dist = #(GetEntityCoords(ped) - myPos)
                            if dist <= WATCH_RANGE then
                                fast = true
                                if IsPedBeingStunned(ped, 0) then reportOnce(S, 'stunned', s.netId) end
                                local range = state == 'stopped' and AIM_STOPPED or aimRun
                                local aimOk = not s.armed and state ~= 'hostile' and (obj.surrenderOnAim or state == 'fleeing')
                                if aimOk and dist <= range and IsPlayerFreeAimingAtEntity(PlayerId(), ped) then
                                    local since = S.aimSince[s.netId] or GetGameTimer()
                                    S.aimSince[s.netId] = since
                                    if GetGameTimer() - since >= AIM_HOLD_MS then reportOnce(S, 'aim', s.netId) end
                                else
                                    S.aimSince[s.netId] = nil
                                end
                            end
                        end
                    else
                        dropBlip(S, k)
                    end
                end
                if d.mode == 'follow' and obj.failIfUndriveable and myVeh ~= 0 and GetPedInVehicleSeat(myVeh, -1) == me
                    and not IsVehicleDriveable(myVeh, false) then
                    local net = NetworkGetNetworkIdFromEntity(myVeh)
                    if net and net ~= 0 then reportOnce(S, 'undriveable', net) end
                end
                setHint(S, hudText(S, myPos))
            end
            Wait(fast and FAST_MS or SLOW_MS)
        end
        S.looping = false
    end)
end

local function cleanup(S)
    S.alive = false
    S.current = false
    for k in pairs(S.blips) do dropBlip(S, k) end
    if S.hint then
        S.hint = nil
        S.ctx.hudDetail(nil)
    end
    active[S.key] = nil
end

CP.Blocks.register(BLOCK, {
    prepare = function(ctx)
        S_of(ctx)
    end,

    start = function(ctx)
        local S = S_of(ctx)
        S.alive = true
        S.current = true
        loop(S)
        ramLoop(S)
    end,

    update = function(ctx, data)
        local S = S_of(ctx)
        if type(data) ~= 'table' or data.kind ~= 'state' then return end
        S.data = data
        S.vehicles = data.vehicles or {}
        S.suspects = data.suspects or {}
        local byNet, keep = {}, {}
        for _, s in ipairs(S.suspects) do byNet[s.netId] = s; keep['s' .. tostring(s.netId)] = true end
        for _, v in ipairs(S.vehicles) do keep['v' .. tostring(v.netId)] = true end
        S.byNet = byNet
        for k in pairs(S.blips) do
            if not keep[k] then dropBlip(S, k) end
        end
    end,

    hostChanged = function(ctx, isHost)
        local S = S_of(ctx)
        S.isHost = isHost == true
        S.applied, S.tasked, S.drive, S.left = {}, {}, {}, {}
    end,

    stop = function(ctx)
        local S = active[keyOf(ctx)]
        if S then cleanup(S) end
    end,
})

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, S in pairs(active) do cleanup(S) end
end)

--[[ blocks/escort/client.lua · objective block "escort" (client half)

  What it does (while the objective is current on this participant's client)
    - blips for the escorted truck, the destination and living attackers (none with Radio Silence);
      the arrival marker at the destination (DrawMarker only within MARKER_RANGE, otherwise Wait(750));
    - a HUD line (ctx.hudDetail): truck health, stop wait, stopped countdown, attackers alive, and at the
      destination how many attackers are still within clearRadius;
    - on the run host only: control of the truck, its driver and the attackers before anything is done
      to them (re-applied and re-tasked when control comes back from another client), CP.Npc.apply on
      the driver, the driver seated and kept in the truck, doors locked, the toughness (cp bag
      cfg.toughness, else ctx.obj.toughness) applied once
      (SetEntityMaxHealth / SetEntityHealth / SetVehicleEngineHealth / SetVehicleBodyHealth /
      SetVehiclePetrolTankHealth = 1000 × toughness, SetVehicleStrong) and reported ('toughened');
      then the route, segment by segment: CP.Npc.task(driver, 'driveRoute', { vehicle, points = the
      waypoints from the server's next one to the next stop (or the destination), loop = false,
      speed (m/s), style (CP.Npc's lane-following flags), stopRange, force }). At a stop, and at the
      destination, the truck brakes (TaskVehicleTempAction); the next segment is tasked when the server
      ends the stop (truck.gen changes), after a host change, or when the truck is stuck for RETASK_MS.
      Attackers are CP.Npc's (state 'hostile' -> combat); the host applies them once it has control.

  Objective fields read: route, speed, style, toughness, arrival, clearRadius (ctx.obj); location[route].
  Evidence sent: { type = 'toughened', netId }
  Server data (update): { kind = 'state', truck = { netId, driver, wp, gen, stop = { at, left } | nil,
    arrived, toughened, health, stoppedFor, stoppedFail }, waves = { { k, triggered, done, alive } },
    attackers = { netId }, completed }
]]

local BLOCK = 'escort'
local U = CP.U

local LOOP_MS      = 500
local CONTROL_MS   = 250
local RETASK_MS    = 12000
local STUCK_MPS    = 1.0
local STOP_RANGE   = 4.0
local MARKER_RANGE = 150.0

local active = {}

local function keyOf(ctx) return tostring(ctx.runId) .. ':' .. tostring(ctx.index) end

local function S_of(ctx)
    local k = keyOf(ctx)
    local S = active[k]
    if not S then
        S = { key = k, blips = {}, applied = {}, lost = {}, data = {}, alive = true }
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

-- The route of this location: points (vector3) and sorted stop waypoints.
local function routeOf(S)
    if S.route then return S.route end
    local ctx = S.ctx
    local ref = ctx.obj and ctx.obj.route
    local v = type(ref) == 'string' and ctx.location and ctx.location[ref] or ref
    local pts, stops = {}, {}
    if type(v) == 'table' then
        local list = type(v.points) == 'table' and v.points or v
        for i = 1, #list do
            local p = toVec3(list[i])
            if p then pts[#pts + 1] = p end
        end
        for _, s in ipairs(type(v.stops) == 'table' and v.stops or {}) do
            local at = type(s) == 'table' and tonumber(s.at)
            if at then stops[#stops + 1] = math.floor(at) end
        end
    end
    table.sort(stops)
    S.route = { points = pts, stops = stops }
    return S.route
end

local function segment(S, wp)
    local r = routeOf(S)
    local n = #r.points
    if n == 0 then return {} end
    wp = math.max(1, math.min(tonumber(wp) or 2, n + 1))
    local last = n
    for _, s in ipairs(r.stops) do
        if s >= wp and s < n then last = s break end
    end
    local out = {}
    for i = wp, last do out[#out + 1] = r.points[i] end
    return out
end

-- ── Blips ───────────────────────────────────────────────────────────────────
local function dropBlip(S, k)
    local b = S.blips[k]
    if not b then return end
    if DoesBlipExist(b.id) then RemoveBlip(b.id) end
    S.blips[k] = nil
end

local function nameBlip(id, label)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(id)
end

local function ensureEntityBlip(S, k, ent, sprite, colour, scale, label)
    local b = S.blips[k]
    if b and b.ent == ent and DoesBlipExist(b.id) then return end
    dropBlip(S, k)
    local id = AddBlipForEntity(ent)
    SetBlipSprite(id, sprite)
    SetBlipColour(id, colour)
    SetBlipScale(id, scale)
    nameBlip(id, label)
    S.blips[k] = { id = id, ent = ent }
end

local function ensureDestBlip(S)
    if S.blips.dest then return end
    local r = routeOf(S)
    local p = r.points[#r.points]
    if not p then return end
    local id = AddBlipForCoord(p.x, p.y, p.z)
    SetBlipSprite(id, 38)
    SetBlipColour(id, 5)
    SetBlipScale(id, 0.9)
    SetBlipRoute(id, false)
    nameBlip(id, CP.L('block.escort.blip_destination'))
    S.blips.dest = { id = id }
end

-- ── Host AI ─────────────────────────────────────────────────────────────────
-- Control of a run entity before anything is done to it (ctx.control returns at once when this client
-- already owns it). regained = another client owned it since the last check: re-apply and re-task.
local function own(S, key, ent)
    if NetworkHasControlOfEntity(ent) then
        local regained = S.lost[key] == true
        S.lost[key] = nil
        return true, regained
    end
    if not S.ctx.control(ent, CONTROL_MS) then
        S.lost[key] = true
        return false, false
    end
    S.lost[key] = nil
    return true, true
end

-- The truck's toughness from its cp bag cfg (the server passes cfg = { toughness }), else the objective's.
local function toughnessOf(S, truck)
    local bag = bagOf(truck)
    local t = type(bag) == 'table' and type(bag.cfg) == 'table' and tonumber(bag.cfg.toughness) or nil
    return t or tonumber(S.ctx.obj.toughness) or 1.0
end

local function toughen(veh, t)
    local hp = math.floor(1000 * t + 0.5)
    SetEntityMaxHealth(veh, hp)
    SetEntityHealth(veh, hp)
    SetVehicleEngineHealth(veh, hp + 0.0)
    SetVehicleBodyHealth(veh, hp + 0.0)
    SetVehiclePetrolTankHealth(veh, hp + 0.0)
    SetVehicleStrong(veh, t > 1.0)
    SetVehicleExplodesOnHighExplosionDamage(veh, t < 1.0)
end

local function setupDriver(ped)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedKeepTask(ped, true)
    SetPedCanBeDraggedOut(ped, false)
    SetPedConfigFlag(ped, 32, false)            -- no flying through the windscreen
    SetDriverAbility(ped, 1.0)
    SetDriverAggressiveness(ped, 0.0)
end

local function hostTruck(S)
    local ctx = S.ctx
    local d = S.data.truck
    if not d or not d.netId then return end
    local truck = entityFor(d.netId)
    if not truck then return end
    local fresh = false
    local ownTruck, regainedTruck = own(S, 'truck', truck)
    if not ownTruck then return end
    if S.applied.truck ~= truck or regainedTruck then
        SetVehicleDoorsLocked(truck, 2)
        SetVehicleEngineOn(truck, true, true, false)
        if not d.toughened and not S.toughSent then
            toughen(truck, toughnessOf(S, truck))
            S.toughSent = true
            ctx.report({ type = 'toughened', netId = d.netId })
        end
        S.applied.truck = truck
        fresh = true
    end
    local driver = d.driver and entityFor(d.driver) or nil
    if not driver or IsPedDeadOrDying(driver, true) then return end
    local ownDriver, regainedDriver = own(S, 'driver', driver)
    if not ownDriver then return end
    if S.applied.driver ~= driver or regainedDriver then
        local bag = bagOf(driver)
        CP.Npc.apply(driver, (bag and bag.cfg) or {})
        setupDriver(driver)
        S.applied.driver = driver
        fresh = true
    end
    if not IsPedInVehicle(driver, truck, false) then
        SetPedIntoVehicle(driver, truck, -1)
        fresh = true
    end
    local want
    if d.arrived then
        want = 'arrived'
    elseif d.stop then
        want = 'stop:' .. tostring(d.stop.at)
    else
        want = 'go:' .. tostring(d.gen)
    end
    local stuck = want:sub(1, 3) == 'go:' and GetEntitySpeed(truck) < STUCK_MPS
        and GetGameTimer() - (S.taskedAt or 0) >= RETASK_MS
    if not fresh and S.drive == want and not stuck then return end
    S.drive = want
    S.taskedAt = GetGameTimer()
    if want == 'arrived' then
        TaskVehicleTempAction(driver, truck, 27, 600000)
    elseif d.stop then
        TaskVehicleTempAction(driver, truck, 27, (math.max(1, tonumber(d.stop.left) or 1) + 2) * 1000)
    else
        local pts = segment(S, d.wp)
        if #pts == 0 then return end
        -- CP.Npc maps 'careful' | 'normal' | 'fast' to lane-following driving flags
        CP.Npc.task(driver, 'driveRoute', {
            vehicle = truck, points = pts, loop = false, speed = (tonumber(ctx.obj.speed) or 60) / 3.6,
            style = ctx.obj.style or 'normal', stopRange = STOP_RANGE, force = true,
        })
    end
end

local function hostAttackers(S)
    for _, net in ipairs(S.data.attackers or {}) do
        local ped = entityFor(net)
        if ped and not IsPedDeadOrDying(ped, true) then
            local owned, regained = own(S, 'a' .. tostring(net), ped)
            if owned and (S.applied[net] ~= ped or regained) then
                local bag = bagOf(ped)
                CP.Npc.apply(ped, (bag and bag.cfg) or {})
                CP.Npc.task(ped, 'combat', {})
                S.applied[net] = ped
            end
        end
    end
end

-- ── HUD, markers, loop ──────────────────────────────────────────────────────
local function setHint(S, text)
    if S.hint == text then return end
    S.hint = text
    S.ctx.hudDetail(text)
end

local function hudText(S, truck)
    local d = S.data
    local tr = d.truck
    if not tr or d.completed then return nil end
    local near, alive = 0, 0
    local tc = truck and GetEntityCoords(truck) or nil
    local radius = tonumber(S.ctx.obj.clearRadius) or 100.0
    for _, net in ipairs(d.attackers or {}) do
        alive = alive + 1
        local e = entityFor(net)
        if tc and e and not IsPedDeadOrDying(e, true) and #(GetEntityCoords(e) - tc) <= radius then near = near + 1 end
    end
    if tr.arrived then return CP.L('block.escort.hud_clear', { count = near, radius = radius }) end
    if tr.stop then return CP.L('block.escort.hud_stop', { seconds = tr.stop.left or 0 }) end
    if (tr.stoppedFor or 0) > 0 then
        return CP.L('block.escort.hud_stopped', { seconds = math.max(0, (tr.stoppedFail or 60) - tr.stoppedFor) })
    end
    if alive > 0 then return CP.L('block.escort.hud_attackers', { count = alive, health = tr.health or 100 }) end
    return CP.L('block.escort.hud_escort', { health = tr.health or 100 })
end

local function markerLoop(S)
    if S.drawing then return end
    S.drawing = true
    CreateThread(function()
        while S.alive and S.current do
            local r = routeOf(S)
            local p = r.points[#r.points]
            local arrival = tonumber(S.ctx.obj.arrival) or 20.0
            if p and #(GetEntityCoords(PlayerPedId()) - p) <= MARKER_RANGE then
                DrawMarker(1, p.x, p.y, p.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                    arrival * 2.0, arrival * 2.0, 1.5, 60, 140, 240, 70, false, false, 2, false, nil, nil, false)
                Wait(0)
            else
                Wait(750)
            end
        end
        S.drawing = false
    end)
end

local function loop(S)
    if S.looping then return end
    S.looping = true
    CreateThread(function()
        while S.alive do
            if S.current then
                local ctx = S.ctx
                local d = S.data
                if isHost(S) then
                    hostTruck(S)
                    hostAttackers(S)
                end
                local truck = d.truck and entityFor(d.truck.netId) or nil
                if ctx.radioSilence then
                    for k in pairs(S.blips) do dropBlip(S, k) end
                else
                    if truck then
                        ensureEntityBlip(S, 'truck', truck, 67, 3, 1.0, CP.L('block.escort.blip_truck'))
                    else
                        dropBlip(S, 'truck')
                    end
                    ensureDestBlip(S)
                    local keep = {}
                    for _, net in ipairs(d.attackers or {}) do
                        local e = entityFor(net)
                        local k = 'a' .. tostring(net)
                        keep[k] = true
                        if e and not IsPedDeadOrDying(e, true) then
                            ensureEntityBlip(S, k, e, 1, 1, 0.7, CP.L('block.escort.blip_attacker'))
                        else
                            dropBlip(S, k)
                        end
                    end
                    for k in pairs(S.blips) do
                        if k:sub(1, 1) == 'a' and not keep[k] then dropBlip(S, k) end
                    end
                end
                setHint(S, hudText(S, truck))
            end
            Wait(LOOP_MS)
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
        markerLoop(S)
    end,

    update = function(ctx, data)
        local S = S_of(ctx)
        if type(data) ~= 'table' or data.kind ~= 'state' then return end
        local net = data.truck and data.truck.netId or nil
        if net ~= S.truckNet then
            -- a new truck (test restart): toughen, apply and task it from scratch
            S.truckNet = net
            S.toughSent = false
            S.applied, S.lost = {}, {}
            S.drive = nil
        end
        S.data = data
        if data.truck and data.truck.toughened then S.toughSent = true end
    end,

    hostChanged = function(ctx, isHost)
        local S = S_of(ctx)
        S.isHost = isHost == true
        S.applied, S.lost = {}, {}
        S.drive = nil
        S.toughSent = S.data.truck and S.data.truck.toughened or false
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

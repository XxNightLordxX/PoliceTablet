-- Objective block "escort" (client half)

local BLOCK = 'escort'
local U = CP.U

local LOOP_MS = 500
local CONTROL_MS = 250
local RETASK_MS = 12000
local STUCK_MPS = 1.0
local STOP_RANGE = 4.0
local MARKER_RANGE = 150.0

local active = {}

local function KeyOf(ctx) return tostring(ctx.runId) .. ':' .. tostring(ctx.index) end

local function S_of(ctx)
    local k = KeyOf(ctx)
    local S = active[k]
    if not S then
        S = { key = k, blips = {}, applied = {}, lost = {}, data = {}, alive = true }
        active[k] = S
    end
    S.ctx = ctx
    return S
end

local function IsHost(S)
    if S.isHost ~= nil then return S.isHost end
    return S.ctx.isHost == true
end

local function EntityFor(netId)
    if not netId or not NetworkDoesNetworkIdExist(netId) then return nil end
    local e = NetworkGetEntityFromNetworkId(netId)
    if e and e ~= 0 and DoesEntityExist(e) then return e end
    return nil
end

local function BagOf(ent)
    local st = Entity(ent).state
    return st and st.cp or nil
end

local function ToVec3(v)
    local x, y, z = U.xyz(v)
    if not x then return nil end
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

-- The route of this location: points (vector3) and sorted stop waypoints.
local function RouteOf(S)
    if S.route then return S.route end
    local ctx = S.ctx
    local ref = ctx.obj and ctx.obj.route
    local v = type(ref) == 'string' and ctx.location and ctx.location[ref] or ref
    local pts, stops = {}, {}
    if type(v) == 'table' then
        local list = type(v.points) == 'table' and v.points or v
        for i = 1, #list do
            local p = ToVec3(list[i])
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

local function Segment(S, wp)
    local r = RouteOf(S)
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

-- ============================================================================
--                                    BLIPS
-- ============================================================================

local function DropBlip(S, k)
    local b = S.blips[k]
    if not b then return end
    if DoesBlipExist(b.id) then RemoveBlip(b.id) end
    S.blips[k] = nil
end

local function NameBlip(id, label)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(label)
    EndTextCommandSetBlipName(id)
end

local function EnsureEntityBlip(S, k, ent, sprite, colour, scale, label)
    local b = S.blips[k]
    if b and b.ent == ent and DoesBlipExist(b.id) then return end
    DropBlip(S, k)
    local id = AddBlipForEntity(ent)
    SetBlipSprite(id, sprite)
    SetBlipColour(id, colour)
    SetBlipScale(id, scale)
    NameBlip(id, label)
    S.blips[k] = { id = id, ent = ent }
end

local function EnsureDestBlip(S)
    if S.blips.dest then return end
    local r = RouteOf(S)
    local p = r.points[#r.points]
    if not p then return end
    local id = AddBlipForCoord(p.x, p.y, p.z)
    SetBlipSprite(id, 38)
    SetBlipColour(id, 5)
    SetBlipScale(id, 0.9)
    SetBlipRoute(id, false)
    NameBlip(id, CP.L('block.escort.blip_destination'))
    S.blips.dest = { id = id }
end

-- ============================================================================
--                                   HOST AI
-- ============================================================================
-- Control of a run entity before anything is done to it (ctx.control returns at once when this client
-- already owns it). regained = another client owned it since the last check: re-apply and re-task.
local function Own(S, key, ent)
    if not (S.alive and S.current) then return false, false end
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
    -- ctx.control waits for the hand-over: the objective may have stopped meanwhile
    if not (S.alive and S.current) then return false, false end
    return true, true
end

-- The truck's toughness from its cp bag cfg (the server passes cfg = { toughness }), else the objective's.
local function ToughnessOf(S, truck)
    local bag = BagOf(truck)
    local t = type(bag) == 'table' and type(bag.cfg) == 'table' and tonumber(bag.cfg.toughness) or nil
    return t or tonumber(S.ctx.obj.toughness) or 1.0
end

local function Toughen(veh, t)
    local hp = math.floor(1000 * t + 0.5)
    SetEntityMaxHealth(veh, hp)
    SetEntityHealth(veh, hp)
    SetVehicleEngineHealth(veh, hp + 0.0)
    SetVehicleBodyHealth(veh, hp + 0.0)
    SetVehiclePetrolTankHealth(veh, hp + 0.0)
    SetVehicleStrong(veh, t > 1.0)
    SetVehicleExplodesOnHighExplosionDamage(veh, t < 1.0)
end

local function SetupDriver(ped)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedKeepTask(ped, true)
    SetPedCanBeDraggedOut(ped, false)
    SetPedConfigFlag(ped, 32, false)            -- no flying through the windscreen
    SetDriverAbility(ped, 1.0)
    SetDriverAggressiveness(ped, 0.0)
end

local function HostTruck(S)
    local ctx = S.ctx
    local d = S.data.truck
    if not d or not d.netId then return end
    local truck = EntityFor(d.netId)
    if not truck then return end
    local fresh = false
    local ownTruck, regainedTruck = Own(S, 'truck', truck)
    if not ownTruck then return end
    if S.applied.truck ~= truck or regainedTruck then
        SetVehicleDoorsLocked(truck, 2)
        SetVehicleEngineOn(truck, true, true, false)
        if not d.toughened and not S.toughSent then
            Toughen(truck, ToughnessOf(S, truck))
            S.toughSent = true
            ctx.report({ type = 'toughened', netId = d.netId })
        end
        S.applied.truck = truck
        fresh = true
    end
    local driver = d.driver and EntityFor(d.driver) or nil
    if not driver or IsPedDeadOrDying(driver, true) then return end
    local ownDriver, regainedDriver = Own(S, 'driver', driver)
    if not ownDriver then return end
    if S.applied.driver ~= driver or regainedDriver then
        local bag = BagOf(driver)
        CP.Npc.apply(driver, (bag and bag.cfg) or {})
        SetupDriver(driver)
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
        local pts = Segment(S, d.wp)
        if #pts == 0 then return end
        -- CP.Npc maps 'careful' | 'normal' | 'fast' to lane-following driving flags
        CP.Npc.task(driver, 'driveRoute', {
            vehicle = truck,
            points = pts,
            loop = false,
            speed = (tonumber(ctx.obj.speed) or 60) / 3.6,
            style = ctx.obj.style or 'normal',
            stopRange = STOP_RANGE,
            force = true,
        })
    end
end

local function HostAttackers(S)
    for _, net in ipairs(S.data.attackers or {}) do
        local ped = EntityFor(net)
        if ped and not IsPedDeadOrDying(ped, true) then
            local owned, regained = Own(S, 'a' .. tostring(net), ped)
            if owned and (S.applied[net] ~= ped or regained) then
                local bag = BagOf(ped)
                CP.Npc.apply(ped, (bag and bag.cfg) or {})
                CP.Npc.task(ped, 'combat', {})
                S.applied[net] = ped
            end
        end
    end
end

-- ============================================================================
--                              HUD, MARKERS, LOOP
-- ============================================================================

local function SetHint(S, text)
    if S.hint == text then return end
    S.hint = text
    S.ctx.hudDetail(text)
end

local function HudText(S, truck)
    local d = S.data
    local tr = d.truck
    if not tr or d.completed then return nil end
    local near, alive = 0, 0
    local tc = truck and GetEntityCoords(truck) or nil
    local radius = tonumber(S.ctx.obj.clearRadius) or 100.0
    for _, net in ipairs(d.attackers or {}) do
        alive = alive + 1
        local e = EntityFor(net)
        if tc and e and not IsPedDeadOrDying(e, true) and #(GetEntityCoords(e) - tc) <= radius then near = near + 1 end
    end
    if tr.arrived then
        -- every attacker of a triggered wave keeps the objective open, however far behind it was left
        if near == 0 and alive > 0 then return CP.L('block.escort.hud_remaining', { count = alive }) end
        return CP.L('block.escort.hud_clear', { count = near, radius = math.floor(radius + 0.5) })
    end
    if tr.stop then return CP.L('block.escort.hud_stop', { seconds = tr.stop.left or 0 }) end
    if (tr.stoppedFor or 0) > 0 then
        return CP.L('block.escort.hud_stopped', { seconds = math.max(0, (tr.stoppedFail or 60) - tr.stoppedFor) })
    end
    if alive > 0 then return CP.L('block.escort.hud_attackers', { count = alive, health = tr.health or 100 }) end
    return CP.L('block.escort.hud_escort', { health = tr.health or 100 })
end

local function MarkerLoop(S)
    if S.drawing then return end
    S.drawing = true
    CreateThread(function()
        while S.alive and S.current do
            local r = RouteOf(S)
            local p = r.points[#r.points]
            local arrival = tonumber(S.ctx.obj.arrival) or 20.0
            if p and #(GetEntityCoords(PlayerPedId()) - p) <= MARKER_RANGE then
                DrawMarker(1, p.x, p.y, p.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, arrival * 2.0, arrival * 2.0, 1.5, 60,
                    140, 240, 70, false, false, 2, false, nil, nil, false)
                Wait(0)
            else
                Wait(750)
            end
        end
        S.drawing = false
    end)
end

local function Loop(S)
    if S.looping then return end
    S.looping = true
    CreateThread(function()
        while S.alive do
            if S.current and IsHost(S) then
                HostTruck(S)
                HostAttackers(S)
            end
            -- the host AI waits for control (ctx.control yields): a stop meanwhile has already cleaned up
            if S.alive and S.current then
                local ctx = S.ctx
                local d = S.data
                local truck = d.truck and EntityFor(d.truck.netId) or nil
                if ctx.radioSilence then
                    for k in pairs(S.blips) do DropBlip(S, k) end
                else
                    if truck then
                        EnsureEntityBlip(S, 'truck', truck, 67, 3, 1.0, CP.L('block.escort.blip_truck'))
                    else
                        DropBlip(S, 'truck')
                    end
                    EnsureDestBlip(S)
                    local keep = {}
                    for _, net in ipairs(d.attackers or {}) do
                        local e = EntityFor(net)
                        local k = 'a' .. tostring(net)
                        keep[k] = true
                        if e and not IsPedDeadOrDying(e, true) then
                            EnsureEntityBlip(S, k, e, 1, 1, 0.7, CP.L('block.escort.blip_attacker'))
                        else
                            DropBlip(S, k)
                        end
                    end
                    for k in pairs(S.blips) do
                        if k:sub(1, 1) == 'a' and not keep[k] then DropBlip(S, k) end
                    end
                end
                SetHint(S, HudText(S, truck))
            end
            Wait(LOOP_MS)
        end
        S.looping = false
    end)
end

local function Cleanup(S)
    S.alive = false
    S.current = false
    for k in pairs(S.blips) do DropBlip(S, k) end
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
        Loop(S)
        MarkerLoop(S)
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
        local S = active[KeyOf(ctx)]
        if S then Cleanup(S) end
    end,
})

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, S in pairs(active) do Cleanup(S) end
end)

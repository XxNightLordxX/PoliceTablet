-- Objective block "pursuit" (client half)

local BLOCK = 'pursuit'
local U = CP.U

local FAST_MS = 250
local SLOW_MS = 1000
local RAM_POLL_MS = 50
local RAM_IDLE_MS = 500
local RAM_WATCH = 50.0         -- fast ram polling within this range (at 500 ms a closing car covers 25 m)
local RAM_REPORT_MS = 2500
local REPORT_MS = 1500
local AIM_HOLD_MS = 800
local AIM_STOPPED = 25.0
local WATCH_RANGE = 60.0
local CONTROL_MS = 250
local RETASK_MS = 10000
local STUCK_MPS = 2.0
local ROUTE_END = 30.0
local STOP_RANGE = 8.0
local EXIT_RETRY_MS = 2500     -- a stopped suspect still in the car is told to get out again this often...
local EXIT_WARP_TRY = 3        -- ...and warped out (TaskLeaveVehicle flag 16) from this attempt on
local PULL_AHEAD = 14.0        -- metres ahead and...
local PULL_SIDE = 3.5          -- ...to the right where a yielding car pulls over
local PULL_MPS = 7.0           -- speed while pulling over
local DRIVEBY_RANGE = 40.0     -- metres: armed passengers of a fighting car shoot at the named participant
local NEAR_STEP = 10           -- metres: the HUD gives the nearest car's distance in these steps (whole metres)

local active = {}

local function KeyOf(ctx) return tostring(ctx.runId) .. ':' .. tostring(ctx.index) end

local function S_of(ctx)
    local k = KeyOf(ctx)
    local S = active[k]
    if not S then
        S = {
            key = k,
            vehicles = {},
            suspects = {},
            byNet = {},
            blips = {},
            applied = {},
            tasked = {},
            drive = {},
            routeDone = {},
            left = {},
            lost = {},
            lastReport = {},
            aimSince = {},
            touching = {},
            seen = {},
            alive = true,
            data = {},
        }
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

local function RouteInfo(S)
    if S.route ~= nil then return S.route or nil end
    local ctx = S.ctx
    local ref = ctx.obj and ctx.obj.route
    local v = type(ref) == 'string' and ctx.location and ctx.location[ref] or ref
    S.route = false
    if type(v) == 'table' then
        local list = type(v.points) == 'table' and v.points or v
        local pts = {}
        for i = 1, #list do
            local p = ToVec3(list[i])
            if p then pts[#pts + 1] = p end
        end
        if #pts >= 2 then S.route = { points = pts, loop = v.loop == true } end
    end
    return S.route or nil
end

-- A race: stop mode on a looped route (Street Race Bust). Its cars are racers on the map.
local function IsRace(S) return (S.data.mode or 'stop') == 'stop' and (RouteInfo(S) or {}).loop == true end

-- Waypoints still ahead of pos: the rest of an open route, or one full lap of a loop.
local function Remaining(route, pos)
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

-- ============================================================================
--                                    BLIPS
-- ============================================================================

local function DropBlip(S, k)
    local b = S.blips[k]
    if not b then return end
    if DoesBlipExist(b.id) then RemoveBlip(b.id) end
    S.blips[k] = nil
end

local function EnsureBlip(S, k, ent, sprite, label, scale)
    -- a loop pass resumed after the cleanup (it waited in ctx.control) draws nothing
    if not S.alive then return end
    local b = S.blips[k]
    if b and b.ent == ent and DoesBlipExist(b.id) then return end
    DropBlip(S, k)
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

-- ============================================================================
--                                   REPORTS
-- ============================================================================

local function ReportOnce(S, kind, netId, extra)
    local k = kind .. ':' .. tostring(netId)
    local t = GetGameTimer()
    local last = S.lastReport[k]
    if last and t - last < ((kind == 'ram') and RAM_REPORT_MS or REPORT_MS) then return end
    S.lastReport[k] = t
    local ev = { type = kind, netId = netId }
    if extra then for key, v in pairs(extra) do ev[key] = v end end
    S.ctx.report(ev)
end

local function SetHint(S, text)
    -- never a line written after the cleanup
    if not S.alive or S.hint == text then return end
    S.hint = text
    S.ctx.hudDetail(text)
end

-- ============================================================================
--                                   HOST AI
-- ============================================================================
-- Control of a run entity before anything is done to it (ctx.control returns at once when this client
-- already owns it). regained = another client owned it since the last check: its config and tasks may
-- not have migrated, so the caller re-applies and re-tasks.
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

local function DriverSetup(ped, reckless)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedKeepTask(ped, true)
    SetPedCanBeDraggedOut(ped, false)
    SetPedConfigFlag(ped, 32, false)            -- no flying through the windscreen
    SetDriverAbility(ped, 1.0)
    SetDriverAggressiveness(ped, reckless and 1.0 or 0.4)
end

-- force: a lap or stuck re-task repeats the same arguments, which CP.Npc.task ignores without it.
local function TaskDrive(S, v, veh, driver, force)
    local obj = S.ctx.obj
    local speed = (tonumber(obj.speed) or 120) / 3.6
    local style = obj.style or 'reckless'
    local route = RouteInfo(S)
    local d = S.drive[v.netId] or {}
    S.drive[v.netId] = d
    d.at = GetGameTimer()
    d.armed = false                  -- the new end point only counts once the car has left it behind
    -- an open route, once done, stays done: kept outside S.drive (reset on every regain) and sent by the
    -- server for a new host, so the fleeing car is never sent back to the route
    if v.routeDone then S.routeDone[v.netId] = true end
    if route and not S.routeDone[v.netId] then
        local pts = Remaining(route, GetEntityCoords(veh))
        if #pts > 0 then
            d.mode, d.last = 'route', pts[#pts]
            CP.Npc.task(driver, 'driveRoute', {
                vehicle = veh,
                points = pts,
                loop = route.loop,
                speed = speed,
                style = style,
                stopRange = STOP_RANGE,
                force = force,
            })
            return
        end
        S.routeDone[v.netId] = true
    end
    d.mode, d.last = 'flee', nil
    CP.Npc.task(driver, 'flee', { vehicle = veh, speed = speed, style = style, force = force })
end

local function MonitorDrive(S, v, veh, driver)
    local d = S.drive[v.netId]
    if not d then
        TaskDrive(S, v, veh, driver)
        return
    end
    local pos = GetEntityCoords(veh)
    if d.mode == 'route' and d.last then
        -- d.last is the final tasked waypoint; on a loop it is the waypoint just behind the car when it was
        -- tasked, so it only counts as reached after the car first got ROUTE_END away from it (otherwise
        -- every loop pass would re-task with force until the car left it behind).
        if #(pos - d.last) > ROUTE_END then
            d.armed = true
        elseif d.armed then
            local route = RouteInfo(S)
            if not (route and route.loop) then S.routeDone[v.netId] = true end
            TaskDrive(S, v, veh, driver, true)
            return
        end
    end
    if GetEntitySpeed(veh) < STUCK_MPS and GetGameTimer() - (d.at or 0) >= RETASK_MS then
        TaskDrive(S, v, veh, driver, true)
    end
end

-- A violator (observe missions): drives its route at the rolled speed, weaving for a reckless driver.
local function TaskCruise(S, v, veh, driver, force)
    local route = RouteInfo(S)
    local cruise = v.cruise or {}
    local speed = (tonumber(cruise.speed) or tonumber(S.ctx.obj.speed) or 100) / 3.6
    local d = S.drive[v.netId] or {}
    S.drive[v.netId] = d
    d.at, d.mode = GetGameTimer(), 'cruise'
    SetDriverAggressiveness(driver, cruise.weave and 1.0 or 0.6)
    if route then
        local pts = Remaining(route, GetEntityCoords(veh))
        if #pts > 0 then
            CP.Npc.task(driver, 'driveRoute', {
                vehicle = veh,
                points = pts,
                loop = route.loop,
                speed = speed,
                style = cruise.weave and 'reckless' or 'normal',
                stopRange = STOP_RANGE,
                force = force,
            })
            return
        end
    end
    TaskVehicleDriveWander(driver, veh, speed, cruise.weave and 786988 or 786603)
end

-- A yielding car: pulls to the kerb, hazards on, then brakes and turns the engine off.
local function PullOver(S, v, veh, driver)
    local d = S.drive[v.netId]
    if not d or d.mode ~= 'pull' then
        local target = GetOffsetFromEntityInWorldCoords(veh, PULL_SIDE, PULL_AHEAD, 0.0)
        SetVehicleIndicatorLights(veh, 0, true)
        SetVehicleIndicatorLights(veh, 1, true)
        TaskVehicleDriveToCoord(driver, veh, target.x, target.y, target.z, PULL_MPS, 0, GetEntityModel(veh), 786603,
            2.0, true)
        S.drive[v.netId] = { mode = 'pull', at = GetGameTimer(), target = target }
        return
    end
    if not d.braked and (#(GetEntityCoords(veh) - d.target) < 4.0 or GetGameTimer() - d.at > 8000) then
        d.braked = true
        TaskVehicleTempAction(driver, veh, 27, 600000)
    end
end

-- A boxed-in fighting car rams the participant vehicle the server named, once, for a few seconds.
local function Ram(S, v, veh, driver)
    local d = S.drive[v.netId]
    if d and d.mode == 'ram' and d.target == v.ram then return end
    local player = GetPlayerFromServerId(v.ram)
    local ped = player ~= -1 and GetPlayerPed(player) or 0
    local target = ped ~= 0 and GetVehiclePedIsIn(ped, false) or 0
    if target == 0 then return end
    S.drive[v.netId] = { mode = 'ram', target = v.ram, at = GetGameTimer() }
    TaskVehicleChase(driver, ped)
    SetTaskVehicleChaseBehaviorFlag(driver, 1, true)
end

-- Control every time (tasks need it), CP.Npc.apply once per entity handle: a new handle after streaming,
-- a new host, or control regained from another client re-applies.
local function ApplyPed(S, net, ped)
    local ok, regained = Own(S, 'p' .. tostring(net), ped)
    if not ok then return false, false end
    if S.applied[net] == ped and not regained then return true, false end
    local bag = BagOf(ped)
    CP.Npc.apply(ped, (bag and bag.cfg) or {})
    DriverSetup(ped, S.ctx.obj.style ~= 'cautious')
    SetEntityLoadCollisionFlag(ped, true)         -- far from this player it would otherwise sit dormant
    S.applied[net] = ped
    S.tasked[net] = nil
    S.left[net] = nil
    S.freshAt = S.freshAt or {}
    S.freshAt[net] = true
    return true, true
end

-- Config.Debug (F8): what this host's game has of each car, once per change. A car it does not have is out of
-- its OneSync range: nobody drives it and nobody sees it on the map.
local function NoteHost(S, netId, veh, owned)
    if not Config.Debug then return end
    local what
    if not veh then
        what = 'is not streamed to this game (out of range): it cannot be driven or blipped here'
    elseif not owned then
        local idx = NetworkGetEntityOwner(veh)
        what = ('is streamed, but the game of player %s keeps control'):format(
            idx and idx >= 0 and tostring(GetPlayerServerId(idx)) or 'none')
    elseif IsEntityWaitingForWorldCollision(veh) then
        what = 'is controlled by this game, but waits for world collision'
    else
        what = 'is controlled by this game'
    end
    if S.seen[netId] == what then return end
    S.seen[netId] = what
    CP.log(BLOCK, 'host: vehicle %d %s', netId, what)
end

local function HostVehicle(S, v)
    local veh = EntityFor(v.netId)
    if not veh then
        NoteHost(S, v.netId, nil, false)
        return
    end
    local fresh = false
    local owned, regained = Own(S, 'v' .. tostring(v.netId), veh)
    NoteHost(S, v.netId, veh, owned)
    if not owned then return end
    if S.applied[v.netId] ~= veh or regained then
        -- a new car under this net id (test restart) has its route ahead; a regain keeps a finished one
        if S.applied[v.netId] ~= veh then S.routeDone[v.netId] = nil end
        SetEntityLoadCollisionFlag(veh, true)     -- far from this player it would otherwise sit dormant
        SetVehicleDoorsLocked(veh, 2)
        SetVehicleEngineOn(veh, true, true, false)
        S.applied[v.netId] = veh
        S.drive[v.netId] = nil
        fresh = true
    end
    local driver
    for _, net in ipairs(v.occupants or {}) do
        local info = S.byNet[net]
        local ped = EntityFor(net)
        if info and ped then
            local okPed, freshPed = ApplyPed(S, net, ped)
            if okPed then
                local state = (BagOf(ped) or {}).state or info.state
                if state == 'driving' then
                    if not IsPedInVehicle(ped, veh, false) then SetPedIntoVehicle(ped, veh, info.seat or -1) end
                    if (info.seat or -1) == -1 then
                        driver = ped
                        if freshPed then
                            fresh = true
                        end -- a driver (re)applied here needs its drive task again
                    end
                elseif IsPedInVehicle(ped, veh, false) then
                    -- out of the stopped car: the server switches the suspect on only once it is out
                    local l = S.left[net]
                    local t = GetGameTimer()
                    if not l or t - l.at >= EXIT_RETRY_MS then
                        local tries = (l and l.tries or 0) + 1
                        S.left[net] = { at = t, tries = tries }
                        TaskLeaveVehicle(ped, veh, tries >= EXIT_WARP_TRY and 16 or 256)
                    end
                end
            end
        end
    end
    if v.state == 'cruising' and driver then
        local d = S.drive[v.netId]
        if fresh or not d or d.mode ~= 'cruise' then
            TaskCruise(S, v, veh, driver, true)
        elseif GetEntitySpeed(veh) < STUCK_MPS and GetGameTimer() - (d.at or 0) >= RETASK_MS then
            TaskCruise(S, v, veh, driver, true)
        end
    elseif v.state == 'yielding' and driver then
        PullOver(S, v, veh, driver)
    elseif v.state == 'fleeing' and driver and v.ram then
        Ram(S, v, veh, driver)
    elseif v.state == 'fleeing' and driver then
        if fresh or (S.drive[v.netId] and S.drive[v.netId].mode == 'ram') then S.drive[v.netId] = nil end
        MonitorDrive(S, v, veh, driver)
    elseif v.state == 'stopped' or v.state == 'wrecked' then
        if not S.drive[v.netId] or S.drive[v.netId].mode ~= 'off' then
            S.drive[v.netId] = { mode = 'off' }
            SetVehicleEngineOn(veh, false, true, true)
        end
    end
end

-- An armed passenger of a fighting car shoots from the car at the participant the server named (never a
-- bystander); nobody else is ever targeted.
local function DriveBy(S, info, ped)
    if not ApplyPed(S, info.netId, ped) then return end
    local k = 'db:' .. tostring(info.driveBy)
    if S.tasked[info.netId] == k then return end
    local player = GetPlayerFromServerId(info.driveBy)
    local target = player ~= -1 and GetPlayerPed(player) or 0
    if target == 0 or #(GetEntityCoords(target) - GetEntityCoords(ped)) > DRIVEBY_RANGE then return end
    S.tasked[info.netId] = k
    TaskDriveBy(ped, target, 0, 0.0, 0.0, 0.0, 300.0, 60, false, 0xC6EE6B4C)
end

-- Live surrenders and cuffs are animated by CP.Npc's state bag handler; a new host re-issues them.
local function HostSuspect(S, info, ped)
    if not ApplyPed(S, info.netId, ped) then return end
    local state = (BagOf(ped) or {}).state or info.state
    if IsPedInAnyVehicle(ped, false) then return end
    if S.tasked[info.netId] == state then return end
    local first = S.freshAt and S.freshAt[info.netId]
    if state == 'fleeing' then
        CP.Npc.task(ped, 'flee', {})
    elseif state == 'hostile' then
        CP.Npc.task(ped, 'combat', {})
    elseif first and state == 'surrendered' then
        CP.Npc.task(ped, 'kneel', {})
    elseif first and state == 'cuffed' then
        CP.Npc.task(ped, 'cuffed', {})
    end
    if S.freshAt then S.freshAt[info.netId] = nil end
    S.tasked[info.netId] = state
end

-- ============================================================================
--                                    LOOPS
-- ============================================================================

local function MyVehicle()
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then return veh end
    return nil
end

local function RamLoop(S)
    if S.ramming then return end
    S.ramming = true
    CreateThread(function()
        local lastSpeed = 0.0
        while S.alive do
            local wait = RAM_IDLE_MS
            local veh = S.current and MyVehicle() or nil
            if veh then
                local limit = tonumber(S.ctx.obj.ramSpeed) or 0
                local pos = GetEntityCoords(veh)
                local speed = GetEntitySpeed(veh) * 3.6
                local pre = math.max(lastSpeed, speed)
                for _, v in ipairs(S.vehicles) do
                    local sv = EntityFor(v.netId)
                    if sv and #(GetEntityCoords(sv) - pos) <= RAM_WATCH then
                        wait = RAM_POLL_MS
                        local touching = IsEntityTouchingEntity(veh, sv)
                        if touching and not S.touching[v.netId] and (limit <= 0 or pre > limit) then
                            ReportOnce(S, 'ram', v.netId, { speed = math.floor(pre + 0.5) })
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

local function HudText(S, myPos)
    local d = S.data
    local obj = S.ctx.obj
    if d.mode == 'follow' then
        local f = d.follow or {}
        if f.lost then return CP.L('block.pursuit.hud_lost', { seconds = f.lost }) end
        if not d.fled then return CP.L('block.pursuit.hud_wait') end
        local dist
        for _, v in ipairs(S.vehicles) do
            local e = EntityFor(v.netId)
            if e and v.state ~= 'wrecked' then dist = #(GetEntityCoords(e) - myPos) break end
        end
        return CP.L('block.pursuit.hud_follow', {
            held = math.min(f.inRange or 0, f.duration or 0),
            duration = f.duration or 0,
            distance = dist and math.floor(dist + 0.5) or '-',
            hold = f.hold or obj.hold,
        })
    end
    if d.escaping then return CP.L('block.pursuit.hud_escaping', { seconds = d.escaping }) end
    if not d.fled and type(obj.observe) == 'table' then
        -- the violator's own violation and window (rolled per violator on the server)
        local kind, watch = obj.observe.kind, nil
        for _, v in ipairs(S.vehicles) do
            if v.observed then return CP.L('block.pursuit.hud_lights') end
            if v.observe then kind, watch = v.observe, v.watch end
        end
        watch = watch
            or { behind = math.floor((tonumber(obj.observe.behind) or 80) + 0.5), seconds = obj.observe.seconds or 5 }
        return CP.L(kind == 'follow' and 'block.pursuit.hud_observe_follow' or 'block.pursuit.hud_observe_pace',
            { behind = watch.behind, seconds = watch.seconds })
    end
    if not d.fled and d.trigger == 'distance' then
        return d.lights and CP.L('block.pursuit.hud_lights') or CP.L('block.pursuit.hud_approach')
    end
    if obj.surrenderOnAim then
        for _, s in ipairs(S.suspects) do
            if s.state == 'stopped' and not s.armed then
                local e = EntityFor(s.netId)
                if e and #(GetEntityCoords(e) - myPos) <= AIM_STOPPED then return CP.L('block.pursuit.hint_aim') end
            end
        end
    end
    if (d.stopped or 0) < (d.vtotal or 0) then
        -- a driver already waiting to be detained close by comes before the cars still racing
        for _, s in ipairs(S.suspects) do
            local e = s.state == 'surrendered' and EntityFor(s.netId) or nil
            if e and #(GetEntityCoords(e) - myPos) <= WATCH_RANGE then
                return CP.L('block.pursuit.hud_detain', { detained = d.detained or 0, total = d.total or 0 })
            end
        end
        local near
        for _, v in ipairs(S.vehicles) do
            local e = (v.state == 'fleeing' or v.state == 'waiting' or v.state == 'yielding') and EntityFor(v.netId)
                or nil
            local dist = e and #(GetEntityCoords(e) - myPos) or nil
            if dist and (not near or dist < near) then near = dist end
        end
        if near then
            return CP.L('block.pursuit.hud_stop_near', {
                stopped = d.stopped or 0,
                total = d.vtotal or 0,
                distance = math.floor(near / NEAR_STEP + 0.5) * NEAR_STEP,
            })
        end
        return CP.L('block.pursuit.hud_stop', { stopped = d.stopped or 0, total = d.vtotal or 0 })
    end
    return CP.L('block.pursuit.hud_detain', { detained = d.detained or 0, total = d.total or 0 })
end

local function Loop(S)
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
                local host = IsHost(S)
                local showBlips = not ctx.radioSilence
                local aimRun = Config.Blocks.flee_arrest.aimDistance[3]
                local myVeh = GetVehiclePedIsIn(me, false)
                for _, v in ipairs(S.vehicles) do
                    if host then HostVehicle(S, v) end
                    local veh = EntityFor(v.netId)
                    local k = 'v' .. tostring(v.netId)
                    local live = v.state == 'fleeing' or v.state == 'waiting' or v.state == 'cruising'
                        or v.state == 'yielding'
                    if veh and showBlips and live and v.blip ~= false then
                        local label = (v.cruise and 'block.pursuit.blip_violator')
                            or (IsRace(S) and 'block.pursuit.blip_racer') or 'block.pursuit.blip_vehicle'
                        EnsureBlip(S, k, veh, 225, CP.L(label), 0.9)
                    else
                        DropBlip(S, k)
                    end
                    if
                        veh
                        and (v.state == 'waiting' or v.state == 'cruising')
                        and d.trigger == 'distance'
                        and d.lights
                        and myVeh ~= 0
                        and IsVehicleSirenOn(myVeh)
                        and #(GetEntityCoords(veh) - myPos)
                            <= (tonumber(obj.trigger and obj.trigger.distance) or 60.0)
                    then
                        ReportOnce(S, 'lights_near', v.netId)
                    end
                    if veh and #(GetEntityCoords(veh) - myPos) <= WATCH_RANGE then fast = true end
                end
                for _, s in ipairs(S.suspects) do
                    local ped = EntityFor(s.netId)
                    local k = 's' .. tostring(s.netId)
                    if ped then
                        local state = (BagOf(ped) or {}).state or s.state
                        if host and s.driveBy and IsPedInAnyVehicle(ped, false) then
                            DriveBy(S, s, ped)
                        elseif host and state ~= 'dead' then
                            HostSuspect(S, s, ped)
                        end
                        local onFoot = (state == 'stopped' or state == 'fleeing' or state == 'hostile')
                            and not IsPedInAnyVehicle(ped, false)
                        if showBlips and onFoot then
                            EnsureBlip(S, k, ped, 1, CP.L('block.pursuit.blip_suspect'), 0.7)
                        elseif showBlips and state == 'surrendered' then
                            EnsureBlip(S, k, ped, 1, CP.L('block.pursuit.blip_suspect'), 0.6)
                        else
                            DropBlip(S, k)
                        end
                        if onFoot then
                            local dist = #(GetEntityCoords(ped) - myPos)
                            if dist <= WATCH_RANGE then
                                fast = true
                                if IsPedBeingStunned(ped, 0) then ReportOnce(S, 'stunned', s.netId) end
                                local range = state == 'stopped' and AIM_STOPPED or aimRun
                                local aimOk = not s.armed and state ~= 'hostile'
                                    and (obj.surrenderOnAim or state == 'fleeing')
                                if aimOk and dist <= range and IsPlayerFreeAimingAtEntity(PlayerId(), ped) then
                                    local since = S.aimSince[s.netId] or GetGameTimer()
                                    S.aimSince[s.netId] = since
                                    if GetGameTimer() - since >= AIM_HOLD_MS then ReportOnce(S, 'aim', s.netId) end
                                else
                                    S.aimSince[s.netId] = nil
                                end
                            end
                        end
                    else
                        DropBlip(S, k)
                    end
                end
                if d.mode == 'follow' and obj.failIfUndriveable and myVeh ~= 0 and GetPedInVehicleSeat(myVeh, -1) == me
                    and NetworkGetEntityIsNetworked(myVeh) and not IsVehicleDriveable(myVeh, false) then
                    local net = NetworkGetNetworkIdFromEntity(myVeh)
                    if net and net ~= 0 then ReportOnce(S, 'undriveable', net) end
                end
                SetHint(S, HudText(S, myPos))
            end
            Wait(fast and FAST_MS or SLOW_MS)
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
        RamLoop(S)
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
            if not keep[k] then DropBlip(S, k) end
        end
    end,

    hostChanged = function(ctx, isHost)
        local S = S_of(ctx)
        S.isHost = isHost == true
        S.applied, S.tasked, S.drive, S.routeDone, S.left, S.lost = {}, {}, {}, {}, {}, {}
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

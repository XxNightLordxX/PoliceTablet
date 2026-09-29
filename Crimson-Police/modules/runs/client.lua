--[[ modules/runs/client.lua · CP.Runs (client): this player's side of the run engine.

  Owns
    The local copy of the player's run (from client:start / client:inProgress), the client halves of the
    objective blocks (ARCHITECTURE §7.2: prepare, start, update, stop, hostChanged) with a persistent ctx
    per objective, objective evidence (report, which adds coords and time), telemetry while on a run
    (vehicle netId every 5 s while driving, pedestrian hits by the player's vehicle, lights and siren on
    Beat Patrol / Business Check, weapon fired; each once where the spec says once), the mission HUD
    state through CP.Tablet.hud (phase route/objectives/ended, tier, timer, objectives, TEST RUN banner,
    test controls for the admin who started the test, end messages) and the result screen through
    CP.Tablet.result. Everything is removed when the run ends and on resource stop.

  Public API (client, ARCHITECTURE §5.10)
    CP.Runs.current() -> clientRun|nil
        { id, mission, location, locationIndex, seed, isHost, test, state, tier, payTier, modifier,
          objectiveIndex, host, participants, objectives, startRoute, startTimeout, isBoss }
    CP.Runs.report(index, evidence) -> boolean     server:objective (runId, index, evidence + coords + time)
    CP.Runs.telemetry(kind, data) -> boolean       server:telemetry (runId, kind, data)
    CP.Runs.getEntity(netId, timeoutMs) -> entity|nil
    CP.Runs.control(entity, timeoutMs) -> boolean  network control loop (run host only)
    CP.Runs.hudDetail(text|nil)                    the client-side HUD line for the current objective
  Client action (NUI 'client' endpoint): logResult { point, choice } -> report(current objective,
    { type = 'log', point, choice }) (Business Check tablet log)
  Events handled: client:start, client:inProgress, client:objective, client:hud, client:tierChanged,
    client:hostChanged, client:participants, client:runEnded (docs/ARCHITECTURE.md §8.1)

  Contract interpretations (docs/notes/engine_b.md)
    * client:start begins the start route with CP.Route.begin(runId, startCoords, { startRoute, radius })
      (a test run with the route off gets a waypoint only); CP.Route.stop() runs when this player arrives
      and at the end.
    * client:tierChanged may carry the rescaled objectives as a 4th argument (ctx.obj is updated).
    * client:runEnded's breakdown may carry failReason (a locale key) for mission_failed; a nil breakdown
      (silent removal) cleans up without the result screen.
    * The street · zone names of the start (client:start) and of each objective's reference point
      (client:objective 'start' carries `area`) are resolved here once each and sent as telemetry 'area'
      { index = 0 | objective, text }: the server shows them in this player's own Active Mission view.
    * A start whose radius is at least 200 m is a search circle (Manhunt: "the 600 m search circle, shown on
      the map when the type is accepted"): a local radius blip from client:start until this officer is
      inside it or the first objective starts (the block then draws its own circle), removed at cleanup.
]]

CP.Runs = CP.Runs or {}
local Runs = CP.Runs
local TAG = 'runs'

local LIGHTS_MISSIONS = { beat_patrol = true, business_check = true }
local END_HUD_MS = 12000          -- the ended HUD stays this long before it hides
local MESSAGE_MS = 8000           -- HUD messages clear after this long
local VEHICLE_EVERY = 5           -- seconds between vehicle telemetry samples while driving
local ACTIONS = { prepare = true, start = true, update = true, stop = true }
local RUN_OVER = joaat('WEAPON_RUN_OVER_BY_CAR')
local RAMMED = joaat('WEAPON_RAMMED_BY_CAR')
local START_CIRCLE_MIN = 200.0    -- a start this wide is a search circle (Manhunt): shown on the map at accept
local START_CIRCLE_COLOUR = 1
local START_CIRCLE_ALPHA = 90

local current = nil
local token = 0
local hudToken = 0
local messageToken = 0

local function myId() return GetPlayerServerId(PlayerId()) end

function Runs.current()
    return current
end

local function hud(patch)
    if CP.Tablet and CP.Tablet.hud then
        local ok, err = pcall(CP.Tablet.hud, patch)
        if not ok then CP.err(TAG, 'HUD update failed: %s', tostring(err)) end
    end
end

-- A HUD message clears itself after MESSAGE_MS unless a newer one replaced it.
local function hudPatch(patch)
    if type(patch) ~= 'table' then return end
    if type(patch.message) == 'table' and patch.message.text then
        messageToken = messageToken + 1
        local t, runToken = messageToken, token
        SetTimeout(MESSAGE_MS, function()
            if messageToken == t and current and token == runToken then hud({ message = false }) end
        end)
    end
    hud(patch)
end

local function activeSrcs(list)
    local out = {}
    for _, p in ipairs(type(list) == 'table' and list or {}) do
        if type(p) == 'table' and p.status == 'active' and tonumber(p.src) then out[#out + 1] = tonumber(p.src) end
    end
    return out
end

local function modifierHud(key)
    if type(key) ~= 'string' then return false end
    return { key = key, label = CP.L('modifier.' .. key) }
end

-- ── evidence, telemetry, entities ───────────────────────────────────────────
function Runs.report(index, evidence)
    if not current or current.state ~= 'in_progress' then return false end
    index = math.tointeger(tonumber(index) or -1)
    if not index or index < 1 then return false end
    local ev = {}
    if type(evidence) == 'table' then
        for k, v in pairs(evidence) do ev[k] = v end
    end
    ev.coords = GetEntityCoords(PlayerPedId())
    ev.time = GetGameTimer()
    TriggerServerEvent(CP.e('server:objective'), current.id, index, ev)
    return true
end

function Runs.telemetry(kind, data)
    if not current or type(kind) ~= 'string' then return false end
    TriggerServerEvent(CP.e('server:telemetry'), current.id, kind, type(data) == 'table' and data or {})
    return true
end

function Runs.getEntity(netId, timeoutMs)
    netId = math.tointeger(tonumber(netId) or -1)
    if not netId or netId <= 0 then return nil end
    local deadline = GetGameTimer() + (tonumber(timeoutMs) or 2000)
    while true do
        if NetworkDoesNetworkIdExist(netId) then
            local e = NetworkGetEntityFromNetworkId(netId)
            if e and e ~= 0 and DoesEntityExist(e) then return e end
        end
        if GetGameTimer() >= deadline then return nil end
        Wait(50)
    end
end

function Runs.control(entity, timeoutMs)
    if not current or not current.isHost then return false end
    if not entity or entity == 0 or not DoesEntityExist(entity) then return false end
    if NetworkHasControlOfEntity(entity) then return true end
    local deadline = GetGameTimer() + (tonumber(timeoutMs) or 1000)
    NetworkRequestControlOfEntity(entity)
    while not NetworkHasControlOfEntity(entity) do
        if GetGameTimer() >= deadline or not DoesEntityExist(entity) then return false end
        Wait(0)
        NetworkRequestControlOfEntity(entity)
    end
    return true
end

function Runs.hudDetail(text)
    if not current then return end
    if type(text) == 'string' and text ~= '' then
        hud({ detail = text })
    else
        hud({ detail = false })
    end
end

-- ── block halves (ARCHITECTURE §7.2) ────────────────────────────────────────
local function blockEntry(i)
    if not current then return nil end
    local b = current.blocks[i]
    if b then return b end
    local obj = current.objectives[i] or (current.mission and current.mission.objectives or {})[i]
    if type(obj) ~= 'table' then return nil end
    local ctx = {
        runId = current.id, index = i, obj = obj,
        base = (current.mission and current.mission.objectives or {})[i],
        mission = current.mission, location = current.location,
        isHost = current.isHost, test = current.test, radioSilence = current.modifier == 'radio_silence',
        state = {}, participants = activeSrcs(current.participants),
        getEntity = Runs.getEntity, control = Runs.control, seed = current.seed,
    }
    ctx.report = function(evidence) return Runs.report(i, evidence) end
    ctx.hudDetail = function(text) return Runs.hudDetail(text) end
    b = { ctx = ctx, prepared = false, started = false, stopped = false }
    current.blocks[i] = b
    return b
end

local function callBlock(i, hook, ...)
    local b = blockEntry(i)
    if not b then return false end
    local impl = CP.Blocks.get(b.ctx.obj.block)
    if not impl or type(impl[hook]) ~= 'function' then return false end
    local ok, err = pcall(impl[hook], b.ctx, ...)
    if not ok then
        CP.err(TAG, 'block %s.%s (objective %d) failed: %s', tostring(b.ctx.obj.block), hook, i, tostring(err))
        return false
    end
    return true
end

local function stopAllBlocks(run)
    if not run or not run.blocks then return end
    for i, b in pairs(run.blocks) do
        if (b.prepared or b.started) and not b.stopped then
            b.stopped = true
            local impl = CP.Blocks.get(b.ctx.obj.block)
            if impl and type(impl.stop) == 'function' then
                local ok, err = pcall(impl.stop, b.ctx)
                if not ok then CP.err(TAG, 'block %s.stop (objective %d) failed: %s', tostring(b.ctx.obj.block), i, tostring(err)) end
            end
        end
    end
end

-- ── the start circle (Manhunt: "the 600 m search circle, shown on the map when the type is accepted") ──
-- Shown from client:start until this player is inside it or the first objective starts (the block then
-- draws its own search circle); a local radius blip, removed at every cleanup.
local function showStartCircle(run, start)
    if type(start) ~= 'table' then return end
    local radius = tonumber(start.radius)
    if not radius or radius < START_CIRCLE_MIN then return end
    local x, y, z = CP.U.xyz(start.coords)
    if not x then return end
    local blip = AddBlipForRadius(x + 0.0, y + 0.0, (z or 0.0) + 0.0, radius + 0.0)
    if not blip or blip == 0 then return end
    SetBlipColour(blip, START_CIRCLE_COLOUR)
    SetBlipAlpha(blip, START_CIRCLE_ALPHA)
    run.startCircle = blip
end

local function hideStartCircle(run)
    if not run or not run.startCircle then return end
    if DoesBlipExist(run.startCircle) then RemoveBlip(run.startCircle) end
    run.startCircle = nil
end

local function routeStop()
    if CP.Route and CP.Route.stop then
        local ok, err = pcall(CP.Route.stop)
        if not ok then CP.err(TAG, 'CP.Route.stop failed: %s', tostring(err)) end
    end
end

-- End the local run: stop every block half, the route and the telemetry loops.
local function cleanup()
    local run = current
    if not run then return end
    current = nil
    token = token + 1
    hideStartCircle(run)
    stopAllBlocks(run)
    routeStop()
    CP.log(TAG, 'run %s cleaned up', tostring(run.id))
end

-- ── telemetry loops (only while on a run) ───────────────────────────────────
local function startTelemetry(run)
    local myToken = token
    CreateThread(function()
        local tick = 0
        local sirenCheck = LIGHTS_MISSIONS[run.missionId] == true
        while current == run and token == myToken do
            Wait(1000)
            if current ~= run or token ~= myToken then break end
            tick = tick + 1
            local ped = PlayerPedId()
            local veh = GetVehiclePedIsIn(ped, false)
            if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
                if tick % VEHICLE_EVERY == 0 and NetworkGetEntityIsNetworked(veh) then
                    Runs.telemetry('vehicle', { netId = NetworkGetNetworkIdFromEntity(veh) })
                end
                if sirenCheck and not run.sentSiren and IsVehicleSirenOn(veh) then
                    run.sentSiren = true
                    Runs.telemetry('lights_siren', {})
                end
            end
        end
    end)
    CreateThread(function()
        while current == run and token == myToken and not run.sentWeapon do
            local ped = PlayerPedId()
            if IsPedArmed(ped, 6) then
                Wait(0)
                if IsPedShooting(ped) then
                    run.sentWeapon = true
                    Runs.telemetry('weapon_fired', {})
                end
            else
                Wait(500)
            end
        end
    end)
end

-- ── area (street · zone) for this player's own Active Mission view ──────────
-- The server has no street-name natives: it sends the start / objective reference point and this client
-- answers once per point with the names (Radio Silence: "the Active Mission screen shows only street and
-- zone names").
local function areaText(coords)
    local x, y, z = CP.U.xyz(coords)
    if not x then return nil end
    local ok, text = pcall(function()
        x, y, z = x + 0.0, y + 0.0, (z or 0.0) + 0.0
        local street = ''
        local hash = GetStreetNameAtCoord(x, y, z)
        if hash and hash ~= 0 then street = GetStreetNameFromHashKey(hash) or '' end
        local zone = GetNameOfZone(x, y, z) or ''
        local zoneLabel = zone ~= '' and (GetLabelText(zone) or '') or ''
        if zoneLabel == '' or zoneLabel == 'NULL' then zoneLabel = zone end
        local parts = {}
        if street ~= '' then parts[#parts + 1] = street end
        if zoneLabel ~= '' and zoneLabel ~= street then parts[#parts + 1] = zoneLabel end
        return table.concat(parts, ' · ')
    end)
    if not ok or type(text) ~= 'string' or text == '' then return nil end
    return text
end

local function reportArea(run, index, coords)
    if not run or run ~= current or coords == nil then return end
    run.areaSent = run.areaSent or {}
    if run.areaSent[index] then return end
    local text = areaText(coords)
    if not text then return end
    run.areaSent[index] = true
    Runs.telemetry('area', { index = index, text = text })
end

-- Pedestrians hit by this player's vehicle (non-mission, non-player peds; the server re-checks).
AddEventHandler('gameEventTriggered', function(name, args)
    if name ~= 'CEventNetworkEntityDamage' or not current or type(args) ~= 'table' then return end
    local victim, attacker, weapon = args[1], args[2], args[7]
    if not victim or victim == 0 or not DoesEntityExist(victim) or not IsEntityAPed(victim) or IsPedAPlayer(victim) then return end
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then return end
    if not (attacker == veh or (attacker == ped and (weapon == RUN_OVER or weapon == RAMMED))) then return end
    -- Networked first: Entity(e).state and NetworkGetNetworkIdFromEntity warn for local-only peds.
    if not NetworkGetEntityIsNetworked(victim) then return end
    local st = Entity(victim).state
    if st and st.cp ~= nil then return end
    local netId = NetworkGetNetworkIdFromEntity(victim)
    current.pedHits = current.pedHits or {}
    if current.pedHits[netId] then return end
    current.pedHits[netId] = true
    Runs.telemetry('ped_hit', { netId = netId })
end)

-- ── server events ───────────────────────────────────────────────────────────
local function matches(runId)
    return current ~= nil and type(runId) == 'string' and current.id == runId
end

local function isTestAdmin(test)
    return type(test) == 'table' and tonumber(test.adminSrc) == myId()
end

RegisterNetEvent(CP.e('client:start'), function(runId, data)
    if type(runId) ~= 'string' or type(data) ~= 'table' then return end
    if current and current.id == runId then return end
    if current then cleanup() end
    token = token + 1
    hudToken = hudToken + 1
    local mission = type(data.mission) == 'table' and data.mission or (CP.Missions and CP.Missions.get and CP.Missions.get(data.missionId)) or { id = data.missionId, objectives = {} }
    current = {
        id = runId, token = token,
        missionId = data.missionId, mission = mission, location = data.location, locationIndex = data.locationIndex,
        seed = data.seed, host = tonumber(data.host), isHost = tonumber(data.host) == myId(),
        test = data.test, state = 'accepted', tier = data.expectedTier, payTier = data.expectedTier,
        modifier = data.modifier, objectiveIndex = 1, participants = data.participants or {},
        objectives = {}, blocks = {}, startRoute = data.startRoute ~= false, startTimeout = data.startTimeout,
        isBoss = data.isBoss == true, timeLimit = data.timeLimit, arrived = false,
    }
    hud(nil)
    hud({
        runId = runId, test = data.test ~= nil, missionLabel = mission.label or data.missionId or '',
        phase = 'route', tier = data.expectedTier, payTier = data.expectedTier,
        modifier = modifierHud(data.modifier), timer = false,
        route = { status = current.startRoute and 'on' or 'disabled' },
        objectives = {}, detail = false, message = false, testControls = isTestAdmin(data.test),
    })
    showStartCircle(current, data.start)
    startTelemetry(current)
    reportArea(current, 0, type(data.start) == 'table' and data.start.coords or nil)
    local start = type(data.start) == 'table' and data.start.coords or nil
    if start then
        if CP.Route and CP.Route.begin then
            -- CP.Route handles both cases: the checked start route, or (test run, route off) a waypoint only.
            local ok, err = pcall(CP.Route.begin, runId, start, { startRoute = current.startRoute, radius = data.start.radius })
            if not ok then CP.err(TAG, 'CP.Route.begin failed: %s', tostring(err)) end
        else
            local x, y = CP.U.xyz(start)
            if x then SetNewWaypoint(x + 0.0, y + 0.0) end
        end
    end
    CP.log(TAG, 'run %s started (%s, host %s)', runId, tostring(data.missionId), tostring(data.host))
end)

RegisterNetEvent(CP.e('client:inProgress'), function(runId, data)
    if not matches(runId) or type(data) ~= 'table' then return end
    current.state = 'in_progress'
    current.tier = data.tier or current.tier
    current.payTier = data.payTier or current.payTier
    current.objectives = type(data.objectives) == 'table' and data.objectives or {}
    current.timeLimit = data.timeLimit or current.timeLimit
    for i = 1, #current.objectives do
        local b = blockEntry(i)
        if b then b.ctx.obj = current.objectives[i] end
    end
    hudPatch({
        phase = 'objectives', tier = current.tier, payTier = current.payTier,
        timer = { remaining = tonumber(data.remaining) or tonumber(data.timeLimit) or 0, paused = false },
        message = { text = CP.L('run.in_progress', { mission = current.mission.label or current.missionId or '' }), kind = 'info' },
    })
end)

RegisterNetEvent(CP.e('client:objective'), function(runId, index, msg)
    if not matches(runId) or type(msg) ~= 'table' or not ACTIONS[msg.action] then return end
    index = math.tointeger(tonumber(index) or -1)
    if not index or index < 1 then return end
    local b = blockEntry(index)
    if not b then return end
    local action = msg.action
    if action == 'prepare' then
        if b.stopped then
            -- Test restart: the same persistent ctx.state, emptied.
            for k in pairs(b.ctx.state) do b.ctx.state[k] = nil end
            b.stopped, b.started = false, false
        end
        b.prepared = true
        callBlock(index, 'prepare')
    elseif action == 'start' then
        if b.stopped then
            b.stopped = false
        end
        current.objectiveIndex = index
        hideStartCircle(current)
        b.prepared = true
        b.started = true
        hud({ detail = false })
        callBlock(index, 'start')
        reportArea(current, index, msg.area)
    elseif action == 'update' then
        if not b.stopped then callBlock(index, 'update', msg.data) end
    elseif action == 'stop' then
        if not b.stopped then
            b.stopped = true
            callBlock(index, 'stop')
            if index == current.objectiveIndex then hud({ detail = false }) end
        end
    end
end)

RegisterNetEvent(CP.e('client:hud'), function(runId, patch)
    if not matches(runId) or type(patch) ~= 'table' then return end
    hudPatch(patch)
end)

RegisterNetEvent(CP.e('client:tierChanged'), function(runId, tierName, payTierName, objectives)
    if not matches(runId) then return end
    if type(tierName) == 'string' then current.tier = tierName end
    if type(payTierName) == 'string' then current.payTier = payTierName end
    if type(objectives) == 'table' then
        for i, obj in pairs(objectives) do
            if type(obj) == 'table' then
                current.objectives[i] = obj
                local b = current.blocks[i]
                if b and not b.stopped then b.ctx.obj = obj end
            end
        end
    end
    hudPatch({
        tier = current.tier, payTier = current.payTier,
        message = { text = CP.L('run.tier_changed', { tier = CP.L('tier.' .. tostring(current.tier)) }), kind = 'warning' },
    })
end)

RegisterNetEvent(CP.e('client:hostChanged'), function(runId, hostSrc)
    if not matches(runId) then return end
    current.host = tonumber(hostSrc)
    local isHost = current.host == myId()
    current.isHost = isHost
    for i, b in pairs(current.blocks) do
        b.ctx.isHost = isHost
        if b.prepared and not b.stopped then callBlock(i, 'hostChanged', isHost) end
    end
    CP.log(TAG, 'run %s host is now %s%s', runId, tostring(hostSrc), isHost and ' (me)' or '')
end)

RegisterNetEvent(CP.e('client:participants'), function(runId, list)
    if not matches(runId) or type(list) ~= 'table' then return end
    current.participants = list
    local srcs = activeSrcs(list)
    for _, b in pairs(current.blocks) do b.ctx.participants = srcs end
    local me = myId()
    for _, p in ipairs(list) do
        if type(p) == 'table' and tonumber(p.src) == me and p.arrived and not current.arrived then
            current.arrived = true
            hideStartCircle(current)
            routeStop()
        end
    end
end)

local function endKind(result, endReason)
    if endReason == 'real_call' or endReason == 'force_recall' or endReason == 'cancelled' then return 'info' end
    if result == 'completed' then return 'success' end
    if result == 'failed' then return 'error' end
    return 'warning'
end

RegisterNetEvent(CP.e('client:runEnded'), function(runId, result, endReason, breakdown)
    if type(runId) ~= 'string' then return end
    local mine = matches(runId)
    if mine then cleanup() end
    if not mine and current then
        -- Stale end of an earlier run: only the result screen, the HUD belongs to the current run.
        if type(breakdown) == 'table' and CP.Tablet and CP.Tablet.result then CP.Tablet.result(breakdown) end
        return
    end
    local reason = type(endReason) == 'string' and endReason or 'quit'
    local text
    if reason == 'mission_failed' and type(breakdown) == 'table' and type(breakdown.failReason) == 'string' then
        text = CP.L(breakdown.failReason)
    else
        text = CP.L('run.ended_' .. reason)
    end
    if mine then
        hudToken = hudToken + 1
        local t = hudToken
        hud({
            phase = 'ended', timer = false, detail = false, route = false, testControls = false,
            message = { text = text, kind = endKind(result, reason) },
        })
        SetTimeout(END_HUD_MS, function()
            if hudToken == t and current == nil then hud(nil) end
        end)
    end
    if type(breakdown) == 'table' and CP.Tablet and CP.Tablet.result then CP.Tablet.result(breakdown) end
end)

-- ── client action: the Business Check tablet log ────────────────────────────
CreateThread(function()
    for _ = 1, 60 do
        if CP.Tablet and CP.Tablet.registerClientAction then break end
        Wait(500)
    end
    if not (CP.Tablet and CP.Tablet.registerClientAction) then
        CP.warn(TAG, 'CP.Tablet.registerClientAction is not available: the tablet log action is not registered')
        return
    end
    CP.Tablet.registerClientAction('logResult', function(payload)
        if not current or current.state ~= 'in_progress' then return false, 'err.not_on_run' end
        if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
        local point = math.tointeger(tonumber(payload.point) or -1)
        local choice = payload.choice
        if not point or point < 1 or type(choice) ~= 'string' or choice == '' or #choice > 32 then
            return false, 'err.invalid_payload'
        end
        Runs.report(current.objectiveIndex, { type = 'log', point = point, choice = choice })
        return true
    end)
end)

-- ── resource stop ───────────────────────────────────────────────────────────
AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    if current then
        cleanup()
        hud(nil)
    end
end)

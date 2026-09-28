--[[ blocks/flee_arrest/client.lua · objective block "flee_arrest" (client half)

  What it does (while the objective is current on this participant's client)
    - door mode: ox_target sphere zone "Knock and announce" on the door (option crimson-police:knock),
      selecting it reports 'knock_start', runs lib.progressBar(knock.duration) and reports 'knock';
      a marker over the door (DrawMarker only within MARKER_RANGE, otherwise Wait(750)) and a door
      blip until the knock (no blip with Radio Silence);
    - every participant checks the suspects near them: 'aim' when IsPlayerFreeAimingAtEntity (or
      lock-on IsPlayerTargettingEntity) on an unarmed fleeing suspect within givesUp.aim, 'stunned'
      when IsPedBeingStunned (throttled per
      suspect); the server re-checks both with server-side distances;
    - suspect blips (after the knock in door mode; none with Radio Silence);
    - HUD lines (ctx.hudDetail): the escape countdown from the server, or "stay close" while this
      player is within givesUp.close.distance of an unarmed fleeing suspect;
    - on the run host only: CP.Npc.apply once it has control of each suspect, then the task for its
      cp state: fleeing -> flee along the route (scatter: location[obj.routes][route]; door:
      location[obj.fleeTo]), hostile -> combat, and (on first sight / after hostChanged)
      surrendered -> kneel, cuffed -> cuffed. Control is requested before every task and a refused
      task is retried on the next loop. The "Cuff suspect" target is CP.Npc's (enableCuff).

  Objective fields read: mode, door, knock.label / duration, fleeTo, routes, givesUp.aim / stun /
    close (ctx.obj); location points.
  Evidence sent: { type = 'knock_start' }, { type = 'knock' }, { type = 'aim', netId }, { type = 'stunned', netId }
  Server data (update): { peds = { { netId, role, state, armed, route } }, mode, knocked, escaping, response }
]]

local BLOCK = 'flee_arrest'
local U = CP.U

local OPTION        = 'crimson-police:knock'
local FAST_MS       = 250        -- loop while a suspect is within WATCH_RANGE
local SLOW_MS       = 1000
local WATCH_RANGE   = 40.0
local REPORT_MS     = 1500       -- the same report for the same suspect at most this often
local CONTROL_MS    = 250
local MARKER_RANGE  = 150.0
local KNOCK_RANGE   = 2.5
local KNOCK_ANIM    = { dict = 'timetable@jimmy@doorknock@', clip = 'knockdoor_idle' }

local active = {}

local function keyOf(ctx) return tostring(ctx.runId) .. ':' .. tostring(ctx.index) end

local function S_of(ctx)
    local k = keyOf(ctx)
    local S = active[k]
    if not S then
        S = { key = k, peds = {}, blips = {}, applied = {}, tasked = {}, lastReport = {}, alive = true }
        active[k] = S
    end
    S.ctx = ctx
    return S
end

local function isHost(S)
    if S.isHost ~= nil then return S.isHost end
    return S.ctx.isHost == true
end

local function pedFor(netId)
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

local function points(location, ref)
    local v = ref
    if type(v) == 'string' then v = location and location[v] end
    if type(v) ~= 'table' and type(v) ~= 'vector3' and type(v) ~= 'vector4' then return {} end
    if type(v) == 'table' and type(v.points) == 'table' then v = v.points end
    if type(v) ~= 'table' or v.x ~= nil or type(v[1]) == 'number' then
        local p = toVec3(v)
        return p and { p } or {}
    end
    local out = {}
    for i = 1, #v do
        local p = v[i]
        if type(p) == 'table' and p.coords then p = p.coords end
        local q = toVec3(p)
        if q then out[#out + 1] = q end
    end
    return out
end

local function routePoints(S, info)
    local ctx = S.ctx
    local obj = ctx.obj
    if obj.mode == 'scatter' then
        local v = type(obj.routes) == 'string' and ctx.location[obj.routes] or obj.routes
        if type(v) ~= 'table' then return {} end
        local first = v[1]
        local single = type(v.points) == 'table' or type(first) == 'vector3' or type(first) == 'vector4'
            or (type(first) == 'table' and (first.x ~= nil or type(first[1]) == 'number'))
        if single then return points(nil, v) end
        if info.route and v[info.route] then return points(nil, v[info.route]) end
        return {}
    end
    return points(ctx.location, obj.fleeTo)
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

local function ensureBlip(S, netId, ent)
    local b = S.blips[netId]
    if b and b.ent == ent and DoesBlipExist(b.id) then return end
    dropBlip(S, netId)
    local id = AddBlipForEntity(ent)
    SetBlipSprite(id, 1)
    SetBlipColour(id, 17)
    SetBlipScale(id, 0.7)
    SetBlipAsShortRange(id, true)
    nameBlip(id, CP.L('block.flee_arrest.blip_suspect'))
    S.blips[netId] = { id = id, ent = ent }
end

-- ── Door ────────────────────────────────────────────────────────────────────
local function knock(S)
    if S.busy or S.knocked then return end
    S.busy = true
    local ctx = S.ctx
    local k = ctx.obj.knock or {}
    ctx.report({ type = 'knock_start' })
    local done = lib.progressBar({
        duration = tonumber(k.duration) or 3000,
        label = k.label or CP.L('block.flee_arrest.knock'),
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = KNOCK_ANIM,
    })
    if done and S.alive and S.current and not S.knocked then
        ctx.report({ type = 'knock' })
    end
    S.busy = false
end

local function dropDoor(S)
    if S.zone then
        local id = S.zone
        S.zone = nil
        pcall(function() exports.ox_target:removeZone(id) end)
    end
    dropBlip(S, 'door')
end

local function addDoor(S)
    local ctx = S.ctx
    if ctx.obj.mode ~= 'door' or S.zone or S.knocked then return end
    local door = points(ctx.location, ctx.obj.door)[1]
    if not door then return end
    S.door = door
    local k = ctx.obj.knock or {}
    S.zone = exports.ox_target:addSphereZone({
        coords = door,
        radius = 1.2,
        debug = false,
        name = 'crimson-police:knock:' .. S.key,
        options = { {
            name = OPTION,
            label = k.label or CP.L('block.flee_arrest.knock'),
            icon = 'fas fa-door-closed',
            distance = KNOCK_RANGE,
            canInteract = function() return S.alive and S.current and not S.knocked and not S.busy end,
            onSelect = function() CreateThread(function() knock(S) end) end,
        } },
    })
    if not ctx.radioSilence then
        local id = AddBlipForCoord(door.x, door.y, door.z)
        SetBlipSprite(id, 40)
        SetBlipColour(id, 5)
        SetBlipScale(id, 0.8)
        nameBlip(id, CP.L('block.flee_arrest.blip_door'))
        S.blips.door = { id = id }
    end
end

local function markerLoop(S)
    if S.drawing or not S.door then return end
    S.drawing = true
    CreateThread(function()
        while S.alive and S.current and not S.knocked do
            local d = S.door
            if U.dist(GetEntityCoords(PlayerPedId()), d) <= MARKER_RANGE then
                DrawMarker(0, d.x, d.y, d.z + 1.2, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                    0.35, 0.35, 0.35, 240, 200, 40, 180, true, true, 2, false, nil, nil, false)
                Wait(0)
            else
                Wait(750)
            end
        end
        S.drawing = false
    end)
end

-- ── Host AI and reports ─────────────────────────────────────────────────────
-- The host must own the ped before CP.Npc.apply / CP.Npc.task do anything (OneSync hands ownership
-- to the closest player, often the officer chasing the suspect): control is requested for every
-- task, and a task only counts as done when CP.Npc.task took it (otherwise the next loop retries).
local function hasControl(ctx, ent)
    if NetworkHasControlOfEntity(ent) then return true end
    return ctx.control(ent, CONTROL_MS) == true
end

local function hostAi(S, info, ent, state)
    local ctx = S.ctx
    if S.applied[info.netId] ~= ent then
        if not hasControl(ctx, ent) then return end
        local bag = bagOf(ent)
        if CP.Npc.apply(ent, (bag and bag.cfg) or {}) == false then return end
        S.applied[info.netId] = ent
        S.tasked[info.netId] = nil
    end
    local prev = S.tasked[info.netId]
    if prev == state then return end
    -- first = nothing tasked since (re)applying: poses for peds that were already surrendered/cuffed
    local first = prev == nil
    local action, args
    if state == 'fleeing' then
        local pts = routePoints(S, info)
        action, args = 'flee', { points = #pts > 0 and pts or nil }
    elseif state == 'hostile' then
        action, args = 'combat', {}
    elseif first and state == 'surrendered' then
        action, args = 'kneel', {}
    elseif first and state == 'cuffed' then
        action, args = 'cuffed', {}
    end
    if action then
        if not hasControl(ctx, ent) then return end
        if CP.Npc.task(ent, action, args) == false then return end
    end
    S.tasked[info.netId] = state
end

local function reportOnce(S, kind, netId)
    local k = kind .. ':' .. tostring(netId)
    local t = GetGameTimer()
    local last = S.lastReport[k]
    if last and t - last < REPORT_MS then return end
    S.lastReport[k] = t
    S.ctx.report({ type = kind, netId = netId })
end

local function setHint(S, text)
    if S.hint == text then return end
    S.hint = text
    S.ctx.hudDetail(text)
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
                local gu = obj.givesUp or {}
                local me = PlayerPedId()
                local myPos = GetEntityCoords(me)
                local showBlips = not ctx.radioSilence and (obj.mode ~= 'door' or S.knocked)
                local close = false
                for _, info in ipairs(S.peds) do
                    local ent = pedFor(info.netId)
                    if ent then
                        local bag = bagOf(ent)
                        local state = (bag and bag.state) or info.state
                        if isHost(S) and state ~= 'dead' then hostAi(S, info, ent, state) end
                        if state == 'fleeing' or state == 'hostile' then
                            local d = U.dist(myPos, GetEntityCoords(ent))
                            if d <= WATCH_RANGE then
                                fast = true
                                if IsPedBeingStunned(ent, 0) then reportOnce(S, 'stunned', info.netId) end
                            end
                            if state == 'fleeing' and not info.armed then
                                -- free aim or lock-on (controller) aim both count as aiming at them
                                if gu.aim and d <= gu.aim and (IsPlayerFreeAimingAtEntity(PlayerId(), ent)
                                    or IsPlayerTargettingEntity(PlayerId(), ent)) then
                                    reportOnce(S, 'aim', info.netId)
                                end
                                if type(gu.close) == 'table' and d <= (tonumber(gu.close.distance) or 0) then close = true end
                            end
                        end
                        if showBlips and state ~= 'dead' and state ~= 'cuffed' then
                            ensureBlip(S, info.netId, ent)
                        else
                            dropBlip(S, info.netId)
                        end
                    else
                        dropBlip(S, info.netId)
                    end
                end
                if S.escaping then
                    setHint(S, CP.L('block.flee_arrest.escaping', { seconds = S.escaping }))
                elseif close then
                    setHint(S, CP.L('block.flee_arrest.hint_close'))
                else
                    setHint(S, nil)
                end
            end
            Wait(fast and FAST_MS or SLOW_MS)
        end
        S.looping = false
    end)
end

local function cleanup(S)
    S.alive = false
    S.current = false
    -- a "Knock and announce" progress bar still running when the objective or run ends is cancelled
    if S.busy and lib.progressActive and lib.progressActive() then lib.cancelProgress() end
    dropDoor(S)
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
        addDoor(S)
        markerLoop(S)
        loop(S)
    end,

    update = function(ctx, data)
        local S = S_of(ctx)
        if type(data) ~= 'table' then return end
        if type(data.peds) == 'table' then
            local keep = {}
            for _, info in ipairs(data.peds) do keep[info.netId] = true end
            for k in pairs(S.blips) do
                if k ~= 'door' and not keep[k] then dropBlip(S, k) end
            end
            S.peds = data.peds
        end
        S.escaping = data.escaping
        if data.knocked and not S.knocked then
            S.knocked = true
            dropDoor(S)
        end
    end,

    hostChanged = function(ctx, isHost)
        local S = S_of(ctx)
        S.isHost = isHost == true
        S.applied = {}
        S.tasked = {}
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

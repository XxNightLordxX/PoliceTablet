--[[ blocks/protect_rescue/client.lua · objective block "protect_rescue" (client half)

  What it does
    From prepare (the hostages spawn then) on the run host only: CP.Npc.apply once it has control of
    each hostage, then the task for its cp state (restrained -> kneel, idle/safe -> cower,
    freed -> follow to the safe marker, re-issued every RETASK_MS while walking); again after
    hostChanged.
    While the objective is current on this participant's client:
    - ox_target "Cut restraints" (exports.ox_target:addLocalEntity, option crimson-police:cut_restraints)
      on every restrained hostage, re-attached when the entity handle changes, removed in stop;
      selecting it reports 'free_start', runs lib.progressBar(freeTime) and reports 'freed';
    - the safe marker (DrawMarker only within MARKER_RANGE, otherwise Wait(750)) and blips for the
      hostages and the safe point (none with Radio Silence);
    - a HUD line (ctx.hudDetail) while freed hostages are walking to the safe point.

  Objective fields read: freeTime, target.label / icon / distance, safe, safeRadius (ctx.obj);
    location[obj.safe].
  Evidence sent: { type = 'free_start', netId }, { type = 'freed', netId }
  Server data (update): { peds = { { netId, state, index } } }
]]

local BLOCK = 'protect_rescue'
local U = CP.U

local OPTION       = 'crimson-police:cut_restraints'
local LOOP_MS      = 500
local RETASK_MS    = 8000       -- re-issue "follow" to a walking hostage this often
local CONTROL_MS   = 250
local MARKER_RANGE = 150.0
local FREE_ANIM    = { dict = 'mp_arresting', clip = 'a_uncuff' }

local active = {}

local function keyOf(ctx) return tostring(ctx.runId) .. ':' .. tostring(ctx.index) end

local function S_of(ctx)
    local k = keyOf(ctx)
    local S = active[k]
    if not S then
        S = { key = k, peds = {}, byNet = {}, blips = {}, targets = {}, applied = {}, tasked = {}, alive = true }
        active[k] = S
    end
    S.ctx = ctx
    if not S.safe then
        local obj, loc = ctx.obj or {}, ctx.location or {}
        local ref = obj.safe
        local v = type(ref) == 'string' and loc[ref] or ref
        if type(v) == 'table' and v.x == nil and v[1] ~= nil and type(v[1]) ~= 'number' then v = v[1] end
        if v ~= nil then
            local x, y, z = U.xyz(v)
            if x then S.safe = vector3(x + 0.0, y + 0.0, z + 0.0) end
        end
    end
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

local function stateOf(S, netId, ent)
    local bag = ent and bagOf(ent)
    if bag and bag.state then return bag.state end
    local info = S.byNet[netId]
    return info and info.state or nil
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

local function ensureEntityBlip(S, netId, ent)
    local b = S.blips[netId]
    if b and b.ent == ent and DoesBlipExist(b.id) then return end
    dropBlip(S, netId)
    local id = AddBlipForEntity(ent)
    SetBlipSprite(id, 1)
    SetBlipColour(id, 3)
    SetBlipScale(id, 0.6)
    SetBlipAsShortRange(id, true)
    nameBlip(id, CP.L('block.protect_rescue.blip'))
    S.blips[netId] = { id = id, ent = ent }
end

local function ensureSafeBlip(S)
    if S.blips.safe or not S.safe then return end
    local id = AddBlipForCoord(S.safe.x, S.safe.y, S.safe.z)
    SetBlipSprite(id, 1)
    SetBlipColour(id, 2)
    SetBlipScale(id, 0.8)
    nameBlip(id, CP.L('block.protect_rescue.blip_safe'))
    S.blips.safe = { id = id }
end

-- ── ox_target ───────────────────────────────────────────────────────────────
local function dropTarget(S, netId)
    local ent = S.targets[netId]
    if not ent then return end
    S.targets[netId] = nil
    pcall(function() exports.ox_target:removeLocalEntity(ent, OPTION) end)
end

local function free(S, netId)
    if S.busy then return end
    S.busy = true
    local ctx = S.ctx
    local obj = ctx.obj
    ctx.report({ type = 'free_start', netId = netId })
    local done = lib.progressBar({
        duration = tonumber(obj.freeTime) or 6000,
        label = (obj.target and obj.target.label) or CP.L('block.protect_rescue.cut_restraints'),
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = FREE_ANIM,
    })
    if done and S.alive and S.current then
        ctx.report({ type = 'freed', netId = netId })
    end
    S.busy = false
end

local function ensureTarget(S, netId, ent)
    if S.targets[netId] == ent then return end
    dropTarget(S, netId)
    local t = S.ctx.obj.target or {}
    exports.ox_target:addLocalEntity(ent, { {
        name = OPTION,
        label = t.label or CP.L('block.protect_rescue.cut_restraints'),
        icon = t.icon or 'fas fa-scissors',
        distance = tonumber(t.distance) or 2.0,
        canInteract = function(entity)
            return S.alive and S.current and not S.busy and stateOf(S, netId, entity) == 'restrained'
        end,
        onSelect = function()
            CreateThread(function() free(S, netId) end)
        end,
    } })
    S.targets[netId] = ent
end

-- ── Host AI ─────────────────────────────────────────────────────────────────
local function hostAi(S, info, ent, state)
    local ctx = S.ctx
    if S.applied[info.netId] ~= ent then
        if not ctx.control(ent, CONTROL_MS) then return end
        local bag = bagOf(ent)
        CP.Npc.apply(ent, (bag and bag.cfg) or {})
        S.applied[info.netId] = ent
        S.tasked[info.netId] = nil
    end
    local t = S.tasked[info.netId]
    local at = GetGameTimer()
    if t and t.state == state and not (state == 'freed' and at - t.at >= RETASK_MS) then return end
    if state == 'restrained' then
        CP.Npc.task(ent, 'kneel', {})
    elseif state == 'freed' and S.safe then
        CP.Npc.task(ent, 'follow', { coords = S.safe })
    elseif state == 'idle' or state == 'safe' then
        CP.Npc.task(ent, 'cower', {})
    end
    S.tasked[info.netId] = { state = state, at = at }
end

-- ── Loops ───────────────────────────────────────────────────────────────────
local function markerLoop(S)
    if S.drawing or not S.safe then return end
    S.drawing = true
    CreateThread(function()
        local d = (tonumber(S.ctx.obj.safeRadius) or 6.0) * 2.0
        while S.alive and S.current do
            local safe = S.safe
            if U.dist(GetEntityCoords(PlayerPedId()), safe) <= MARKER_RANGE then
                DrawMarker(1, safe.x, safe.y, safe.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                    d, d, 1.0, 60, 200, 90, 110, false, false, 2, false, nil, nil, false)
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
            local ctx = S.ctx
            local walking = false
            for _, info in ipairs(S.peds) do
                local ent = pedFor(info.netId)
                if ent then
                    local state = stateOf(S, info.netId, ent)
                    if isHost(S) and state ~= 'dead' then hostAi(S, info, ent, state) end
                    if S.current and state == 'restrained' then ensureTarget(S, info.netId, ent) else dropTarget(S, info.netId) end
                    if S.current and not ctx.radioSilence and state ~= 'dead' then ensureEntityBlip(S, info.netId, ent) else dropBlip(S, info.netId) end
                    if state == 'freed' then walking = true end
                else
                    dropTarget(S, info.netId)
                    dropBlip(S, info.netId)
                end
            end
            if S.current then
                local text = walking and CP.L('block.protect_rescue.hint_lead') or nil
                if S.hint ~= text then
                    S.hint = text
                    ctx.hudDetail(text)
                end
            end
            Wait(LOOP_MS)
        end
        S.looping = false
    end)
end

local function cleanup(S)
    S.alive = false
    S.current = false
    for netId in pairs(S.targets) do dropTarget(S, netId) end
    for k in pairs(S.blips) do dropBlip(S, k) end
    if S.hint then
        S.hint = nil
        S.ctx.hudDetail(nil)
    end
    active[S.key] = nil
end

CP.Blocks.register(BLOCK, {
    prepare = function(ctx)
        local S = S_of(ctx)
        S.alive = true
        loop(S)
    end,

    start = function(ctx)
        local S = S_of(ctx)
        S.alive = true
        S.current = true
        if not ctx.radioSilence then ensureSafeBlip(S) end
        loop(S)
        markerLoop(S)
    end,

    update = function(ctx, data)
        local S = S_of(ctx)
        if type(data) ~= 'table' or type(data.peds) ~= 'table' then return end
        S.peds = data.peds
        S.byNet = {}
        for _, info in ipairs(data.peds) do S.byNet[info.netId] = info end
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

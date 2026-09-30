-- Objective block "protect_rescue" (client half)

local BLOCK = 'protect_rescue'
local U = CP.U

local OPTION = 'crimson-police:cut_restraints'
local LOOP_MS = 500
local RETASK_MS = 8000          -- re-issue "follow" to a walking hostage this often
local CONTROL_MS = 250
local MARKER_RANGE = 150.0
local FREE_ANIM = { dict = 'mp_arresting', clip = 'a_uncuff' }

local active = {}

local function KeyOf(ctx) return tostring(ctx.runId) .. ':' .. tostring(ctx.index) end

local function S_of(ctx)
    local k = KeyOf(ctx)
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

local function IsHost(S)
    if S.isHost ~= nil then return S.isHost end
    return S.ctx.isHost == true
end

local function PedFor(netId)
    if not netId or not NetworkDoesNetworkIdExist(netId) then return nil end
    local e = NetworkGetEntityFromNetworkId(netId)
    if e and e ~= 0 and DoesEntityExist(e) then return e end
    return nil
end

local function BagOf(ent)
    local st = Entity(ent).state
    return st and st.cp or nil
end

local function StateOf(S, netId, ent)
    local bag = ent and BagOf(ent)
    if bag and bag.state then return bag.state end
    local info = S.byNet[netId]
    return info and info.state or nil
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

local function EnsureEntityBlip(S, netId, ent)
    local b = S.blips[netId]
    if b and b.ent == ent and DoesBlipExist(b.id) then return end
    DropBlip(S, netId)
    local id = AddBlipForEntity(ent)
    SetBlipSprite(id, 1)
    SetBlipColour(id, 3)
    SetBlipScale(id, 0.6)
    SetBlipAsShortRange(id, true)
    NameBlip(id, CP.L('block.protect_rescue.blip'))
    S.blips[netId] = { id = id, ent = ent }
end

local function EnsureSafeBlip(S)
    if S.blips.safe or not S.safe then return end
    local id = AddBlipForCoord(S.safe.x, S.safe.y, S.safe.z)
    SetBlipSprite(id, 1)
    SetBlipColour(id, 2)
    SetBlipScale(id, 0.8)
    NameBlip(id, CP.L('block.protect_rescue.blip_safe'))
    S.blips.safe = { id = id }
end

-- ============================================================================
--                                  ox_target
-- ============================================================================

local function DropTarget(S, netId)
    local ent = S.targets[netId]
    if not ent then return end
    S.targets[netId] = nil
    pcall(function() exports.ox_target:removeLocalEntity(ent, OPTION) end)
end

local function Free(S, netId)
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

local function EnsureTarget(S, netId, ent)
    if S.targets[netId] == ent then return end
    DropTarget(S, netId)
    local t = S.ctx.obj.target or {}
    exports.ox_target:addLocalEntity(ent, {
        {
            name = OPTION,
            label = t.label or CP.L('block.protect_rescue.cut_restraints'),
            icon = t.icon or 'fas fa-scissors',
            distance = tonumber(t.distance) or 2.0,
            canInteract = function(entity)
                return S.alive and S.current and not S.busy and StateOf(S, netId, entity) == 'restrained'
            end,
            onSelect = function()
                CreateThread(function() Free(S, netId) end)
            end,
        },
    })
    S.targets[netId] = ent
end

-- ============================================================================
--                                   HOST AI
-- ============================================================================
-- The host must own the hostage before CP.Npc.apply / CP.Npc.task do anything. OneSync hands
-- ownership to the closest player, which is usually the officer who just cut the restraints, so
-- control is requested for every task, and a task only counts as done when CP.Npc.task took it.
local function HasControl(ctx, ent)
    if NetworkHasControlOfEntity(ent) then return true end
    return ctx.control(ent, CONTROL_MS) == true
end

local function HostAi(S, info, ent, state)
    local ctx = S.ctx
    if S.applied[info.netId] ~= ent then
        if not HasControl(ctx, ent) then return end
        local bag = BagOf(ent)
        if CP.Npc.apply(ent, (bag and bag.cfg) or {}) == false then return end
        S.applied[info.netId] = ent
        S.tasked[info.netId] = nil
    end
    local t = S.tasked[info.netId]
    local at = GetGameTimer()
    if t and t.state == state and not (state == 'freed' and at - t.at >= RETASK_MS) then return end
    local action, args
    if state == 'restrained' then
        action, args = 'kneel', {}
    elseif state == 'freed' and S.safe then
        action, args = 'follow', { coords = S.safe }
    elseif state == 'idle' or state == 'safe' then
        action, args = 'cower', {}
    end
    if action then
        if not HasControl(ctx, ent) then return end
        if CP.Npc.task(ent, action, args) == false then return end
    end
    S.tasked[info.netId] = { state = state, at = at }
end

-- ============================================================================
--                                    LOOPS
-- ============================================================================

local function MarkerLoop(S)
    if S.drawing or not S.safe then return end
    S.drawing = true
    CreateThread(function()
        local d = (tonumber(S.ctx.obj.safeRadius) or 6.0) * 2.0
        while S.alive and S.current do
            local safe = S.safe
            if U.dist(GetEntityCoords(PlayerPedId()), safe) <= MARKER_RANGE then
                DrawMarker(1, safe.x, safe.y, safe.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, d, d, 1.0, 60, 200, 90, 110,
                    false, false, 2, false, nil, nil, false)
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
            local ctx = S.ctx
            local walking = false
            for _, info in ipairs(S.peds) do
                local ent = PedFor(info.netId)
                if ent then
                    local state = StateOf(S, info.netId, ent)
                    if IsHost(S) and state ~= 'dead' then HostAi(S, info, ent, state) end
                    if S.current and state == 'restrained' then
                        EnsureTarget(S, info.netId, ent)
                    else
                        DropTarget(S, info.netId)
                    end
                    if S.current and not ctx.radioSilence and state ~= 'dead' then
                        EnsureEntityBlip(S, info.netId, ent)
                    else
                        DropBlip(S, info.netId)
                    end
                    if state == 'freed' then walking = true end
                else
                    DropTarget(S, info.netId)
                    DropBlip(S, info.netId)
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

local function Cleanup(S)
    S.alive = false
    S.current = false
    -- a "Cut restraints" progress bar still running when the objective or run ends is cancelled
    if S.busy and lib.progressActive and lib.progressActive() then lib.cancelProgress() end
    for netId in pairs(S.targets) do DropTarget(S, netId) end
    for k in pairs(S.blips) do DropBlip(S, k) end
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
        Loop(S)
    end,

    start = function(ctx)
        local S = S_of(ctx)
        S.alive = true
        S.current = true
        if not ctx.radioSilence then EnsureSafeBlip(S) end
        Loop(S)
        MarkerLoop(S)
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
        local S = active[KeyOf(ctx)]
        if S then Cleanup(S) end
    end,
})

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, S in pairs(active) do Cleanup(S) end
end)

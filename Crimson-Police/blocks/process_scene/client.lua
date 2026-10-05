-- Objective block "process_scene" (client half): Photograph & tag and Bag body on each kept body, Release to
-- coroner at the van or the scene marker; each step reports its start and its end, the server checks both.

local BLOCK = 'process_scene'
local U = CP.U

local TAG_OPTION = 'crimson-police:body_tag'
local BAG_OPTION = 'crimson-police:body_bag'
local CORONER_OPTION = 'crimson-police:coroner'
local REACH = 2.5
local VAN_REACH = 6.0
local MARKER_RANGE = 120.0
local ANIMS = {
    tag = { scenario = 'WORLD_HUMAN_PAPARAZZI' },
    bag = { scenario = 'CODE_HUMAN_MEDIC_TEND_TO_DEAD' },
    release = { dict = 'missheistdockssetup1clipboard@base', clip = 'base', flag = 49 },
}

local active = {}

local function KeyOf(ctx) return tostring(ctx.runId) .. ':' .. tostring(ctx.index) end

local function S_of(ctx)
    local k = KeyOf(ctx)
    local S = active[k]
    if not S then
        S = { key = k, bodies = {}, targets = {}, alive = true }
        active[k] = S
    end
    S.ctx = ctx
    return S
end

local function EntityFor(netId)
    if not netId or not NetworkDoesNetworkIdExist(netId) then return nil end
    local e = NetworkGetEntityFromNetworkId(netId)
    if e and e ~= 0 and DoesEntityExist(e) then return e end
    return nil
end

local function ToVec3(v)
    local x, y, z = U.xyz(v)
    if not x then return nil end
    return vector3(x + 0.0, y + 0.0, z + 0.0)
end

-- ============================================================================
--                                  THE STEPS
-- ============================================================================

local function Step(S, kind, netId)
    if S.busy then return end
    S.busy = true
    local ctx = S.ctx
    local step = ctx.obj[kind] or {}
    ctx.report({ type = kind .. '_begin', netId = netId })
    local ok = lib.progressBar({
        duration = tonumber(step.duration) or 5000,
        label = step.label or CP.L('block.process_scene.' .. kind),
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = ANIMS[kind],
    }) == true
    if ok and S.alive and S.current then ctx.report({ type = kind, netId = netId }) end
    S.busy = false
end

local function Info(S, netId)
    for _, b in ipairs(S.bodies) do if b.netId == netId then return b end end
    return nil
end

local function DropTargets(S)
    for ent, names in pairs(S.targets) do
        pcall(function() exports.ox_target:removeLocalEntity(ent, names) end)
    end
    S.targets = {}
    if S.zone then
        local id = S.zone
        S.zone = nil
        pcall(function() exports.ox_target:removeZone(id) end)
    end
end

local function AddBodyOptions(S, b)
    local ent = EntityFor(b.netId)
    if not ent or S.targets[ent] then return end
    local ctx = S.ctx
    S.targets[ent] = { TAG_OPTION, BAG_OPTION }
    exports.ox_target:addLocalEntity(ent, {
        {
            name = TAG_OPTION,
            label = (ctx.obj.tag or {}).label or CP.L('block.process_scene.tag'),
            icon = 'fas fa-camera',
            distance = REACH,
            canInteract = function()
                local i = Info(S, b.netId)
                return S.alive and S.current and not S.busy and i ~= nil and not i.tagged
            end,
            onSelect = function() CreateThread(function() Step(S, 'tag', b.netId) end) end,
        },
        {
            name = BAG_OPTION,
            label = (ctx.obj.bag or {}).label or CP.L('block.process_scene.bag'),
            icon = 'fas fa-bag-shopping',
            distance = REACH,
            canInteract = function()
                local i = Info(S, b.netId)
                return S.alive and S.current and not S.busy and i ~= nil and i.tagged and not i.bagged
            end,
            onSelect = function() CreateThread(function() Step(S, 'bag', b.netId) end) end,
        },
    })
end

local function ReleaseOption(S)
    local ctx = S.ctx
    return {
        name = CORONER_OPTION,
        label = (ctx.obj.release or {}).label or CP.L('block.process_scene.release'),
        icon = 'fas fa-truck-medical',
        distance = VAN_REACH,
        canInteract = function()
            if not (S.alive and S.current) or S.busy or S.released or #S.bodies == 0 then return false end
            for _, b in ipairs(S.bodies) do if not b.bagged then return false end end
            return true
        end,
        onSelect = function() CreateThread(function() Step(S, 'release', nil) end) end,
    }
end

local function AddRelease(S)
    if S.released then return end
    if S.van and S.van.netId and S.van.status == 'parked' then
        local ent = EntityFor(S.van.netId)
        if ent and not S.targets[ent] then
            S.targets[ent] = { CORONER_OPTION }
            exports.ox_target:addLocalEntity(ent, { ReleaseOption(S) })
        end
    elseif not S.coroner and S.scene and not S.zone then
        S.zone = exports.ox_target:addSphereZone({
            coords = S.scene,
            radius = 2.0,
            debug = false,
            name = 'crimson-police:coroner:' .. S.key,
            options = { ReleaseOption(S) },
        })
    end
end

local function MarkerLoop(S)
    if S.drawing then return end
    S.drawing = true
    CreateThread(function()
        while S.alive and S.current and not S.released do
            local p = S.scene
            if p and U.dist(GetEntityCoords(PlayerPedId()), p) <= MARKER_RANGE then
                DrawMarker(1, p.x, p.y, p.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 2.0, 2.0, 0.6, 200, 200, 200, 90,
                    false, false, 2, false, nil, nil, false)
                Wait(0)
            else
                Wait(750)
            end
        end
        S.drawing = false
    end)
end

local function Cleanup(S)
    S.alive = false
    S.current = false
    if S.busy and lib.progressActive and lib.progressActive() then lib.cancelProgress() end
    DropTargets(S)
    if S.blip and DoesBlipExist(S.blip) then RemoveBlip(S.blip) end
    active[S.key] = nil
end

CP.Blocks.register(BLOCK, {
    prepare = function(ctx) S_of(ctx) end,

    start = function(ctx)
        local S = S_of(ctx)
        S.alive = true
        S.current = true
        MarkerLoop(S)
    end,

    update = function(ctx, data)
        local S = S_of(ctx)
        if type(data) ~= 'table' then return end
        S.bodies = type(data.bodies) == 'table' and data.bodies or {}
        S.released = data.released == true
        S.van = data.van
        S.coroner = data.coroner == true
        S.scene = ToVec3(data.scene)
        if S.scene and not S.blip and not ctx.radioSilence then
            S.blip = AddBlipForCoord(S.scene.x, S.scene.y, S.scene.z)
            SetBlipSprite(S.blip, 310)
            SetBlipColour(S.blip, 0)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(CP.L('block.process_scene.blip'))
            EndTextCommandSetBlipName(S.blip)
        end
        if not S.current then return end
        for _, b in ipairs(S.bodies) do
            if not b.bagged then AddBodyOptions(S, b) end
        end
        AddRelease(S)
    end,

    hostChanged = function() end,

    stop = function(ctx)
        local S = active[KeyOf(ctx)]
        if S then Cleanup(S) end
    end,
})

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    for _, S in pairs(active) do Cleanup(S) end
end)

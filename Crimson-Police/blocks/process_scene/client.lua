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
local MARKER_FAR_MS = 1500       -- the marker loop's pace while too far away to draw (per frame in range)
local SCENE_KEY = 'scene'        -- the scene blip's key in the objective pointer (the server's marker)
local ANIMS = {
    tag = { scenario = 'WORLD_HUMAN_PAPARAZZI' },
    bag = { scenario = 'CODE_HUMAN_MEDIC_TEND_TO_DEAD' },
    release = { dict = 'missheistdockssetup1clipboard@base', clip = 'base', flag = 49 },
}

local Kit = CP.BlockKit
local EntityFor, ToVec3 = Kit.entity, Kit.vec3
local Cleanup
local states = Kit.states(function() return { bodies = {}, targets = {}, alive = true } end, function(S)
    Cleanup(S)
end)
local S_of = states.of

-- ============================================================================
--                                  THE STEPS
-- ============================================================================

local function Step(S, kind, netId)
    if S.busy then return end
    S.busy = true
    local ctx = S.ctx
    local step = ctx.obj[kind] or {}
    ctx.report({ type = kind .. '_begin', netId = netId })
    -- the release animation can fail to load: the step then counts as cancelled and busy is still cleared
    local ok = Kit.progress({
        duration = tonumber(step.duration) or 5000,
        label = step.label or CP.L('block.process_scene.' .. kind),
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = ANIMS[kind],
    }, 'process_scene ' .. kind)
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
    elseif (not S.coroner or (S.van and S.van.status == 'gone')) and S.scene and not S.zone then
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
    Kit.markers(S.ctx, S, {
        range = MARKER_RANGE,
        far = MARKER_FAR_MS,
        keep = function() return S.current and not S.released end,
        draw = function(_, pos, rangeSq)
            local p = S.scene
            if not p or U.distSq(pos, p) > rangeSq then return false end
            DrawMarker(1, p.x, p.y, p.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 2.0, 2.0, 0.6, 200, 200, 200, 90, false,
                false, 2, false, nil, nil, false)
            return true
        end,
    })
end

function Cleanup(S)
    S.alive = false
    S.current = false
    if S.busy then Kit.cancelProgress() end
    DropTargets(S)
    -- the objective pointer takes the scene blip back first, so its GPS line goes off before it goes
    if S.handed then
        CP.Markers.release(SCENE_KEY, S.handed)
        S.handed = nil
    end
    if S.blip and DoesBlipExist(S.blip) then RemoveBlip(S.blip) end
    states.drop(S)
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
        if S.scene and not S.blip and not CP.Markers.hidden(ctx, 'scene') then
            -- Config.Markers.kinds.scene (a yellow map pin, never 310: the skull and crossbones), never short range;
            -- handed to the objective pointer as 'scene' (the server's marker): CP.Markers puts the GPS line on it
            -- and draws no second icon
            S.blip = AddBlipForCoord(S.scene.x, S.scene.y, S.scene.z)
            CP.Markers.style(S.blip, 'scene', CP.L('block.process_scene.blip'))
            if CP.Markers.adopt(SCENE_KEY, S.blip) then S.handed = S.blip end
        end
        if not S.current then return end
        for _, b in ipairs(S.bodies) do
            if not b.bagged then AddBodyOptions(S, b) end
        end
        AddRelease(S)
    end,

    hostChanged = function() end,

    stop = function(ctx)
        local S = states.find(ctx)
        if S then Cleanup(S) end
    end,
})

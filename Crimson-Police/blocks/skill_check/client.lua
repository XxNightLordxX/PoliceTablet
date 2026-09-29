-- Objective block "skill_check" (client half)

local BLOCK = 'skill_check'

local MARKER_DISTANCE = 30.0
local TARGET_RADIUS = 1.0
local TARGET_DISTANCE = 2.5
local EVENT_MS = 4000
local KEYS = { 'w', 'a', 's', 'd' }
local EXPLOSION_TYPE = 2       -- sticky bomb
local ANIM_DICT = 'amb@medic@standing@kneel@base'
local ANIM_CLIP = 'base'

local live = {}     -- [state] = ctx, for resource-stop cleanup
local states = {}   -- ['<runId>:<index>'] = state, one per objective across every hook call

local function KeyOf(ctx)
    return tostring(ctx.runId) .. ':' .. tostring(ctx.index)
end

local function StateOf(ctx)
    local key = KeyOf(ctx)
    local st = states[key]
    if not st then
        st = type(ctx.state) == 'table' and ctx.state or {}
        st.runKey = tostring(ctx.runId)
        states[key] = st
    end
    return st
end

-- Drop the states of other runs that are no longer running (late snapshots after a stop).
local function Purge(ctx)
    local run = tostring(ctx.runId)
    for key, st in pairs(states) do
        if st.runKey ~= run and not st.alive then states[key] = nil end
    end
end

local function V3(t)
    return vector3((t.x or 0.0) + 0.0, (t.y or 0.0) + 0.0, (t.z or 0.0) + 0.0)
end

local function Txt(s)
    if type(s) ~= 'string' or s == '' then return nil end
    if CP.Locale.has(s) then return CP.L(s) end
    return s
end

local function Me()
    return GetPlayerServerId(PlayerId())
end

local function Say(st, text, ms)
    st.transient = text
    st.transientUntil = GetGameTimer() + (ms or EVENT_MS)
end

local function TargetOf(st, i)
    return st.data and st.data.targets and st.data.targets[i]
end

local function ChecksOf(ctx)
    return type(ctx.obj.checks) == 'table' and ctx.obj.checks or Config.Blocks[BLOCK].difficulty.default
end

-- ============================================================================
--                                   HUD LINE
-- ============================================================================

local function BaseLine(ctx, st)
    local d = st.data
    if not d then return nil end
    if st.round then
        return CP.L('block.skill_check.hud.round', { n = st.round, total = #ChecksOf(ctx) })
    end
    local done, total = 0, 0
    for _, t in ipairs(d.targets or {}) do
        total = total + 1
        if t.status == 'defused' then done = done + 1 end
    end
    return CP.L('block.skill_check.hud.progress', { done = done, total = total })
end

local function RefreshLine(ctx, st)
    local text
    if st.transient and GetGameTimer() < (st.transientUntil or 0) then
        text = st.transient
    else
        st.transient = nil
        text = BaseLine(ctx, st)
    end
    if text ~= st.line then
        st.line = text
        ctx.hudDetail(text)
    end
end

-- ============================================================================
--                                    BLIPS
-- ============================================================================

local function ClearBlips(st)
    for _, b in ipairs(st.blips or {}) do
        if DoesBlipExist(b) then RemoveBlip(b) end
    end
    st.blips = {}
end

local function RefreshBlips(ctx, st)
    ClearBlips(st)
    if ctx.radioSilence or not st.data then return end
    for i, t in ipairs(st.data.targets or {}) do
        if t.status == 'armed' then
            local b = AddBlipForCoord(t.coords.x, t.coords.y, t.coords.z)
            SetBlipSprite(b, 1)
            SetBlipColour(b, 1)
            SetBlipScale(b, 0.8)
            SetBlipAsShortRange(b, false)
            BeginTextCommandSetBlipName('STRING')
            AddTextComponentSubstringPlayerName(CP.L('block.skill_check.blip', { n = i }))
            EndTextCommandSetBlipName(b)
            st.blips[#st.blips + 1] = b
        end
    end
end

-- ============================================================================
--                                   DEFUSING
-- ============================================================================

local function PlayAnim(st)
    local ped = PlayerPedId()
    if lib.requestAnimDict then lib.requestAnimDict(ANIM_DICT) end
    TaskPlayAnim(ped, ANIM_DICT, ANIM_CLIP, 8.0, -8.0, -1, 1, 0.0, false, false, false)
    st.animating = true
end

local function StopAnim(st)
    if st.animating then
        st.animating = false
        StopAnimTask(PlayerPedId(), ANIM_DICT, ANIM_CLIP, 1.0)
        RemoveAnimDict(ANIM_DICT)   -- lib.requestAnimDict loaded it for this defuse
    end
end

local function Defuse(ctx, st, i)
    if st.busy or not st.alive then return end
    local t = TargetOf(st, i)
    if not t or t.status ~= 'armed' then return end
    if t.worker and t.worker ~= Me() then return end
    local rounds = ChecksOf(ctx)
    st.busy, st.working, st.cancelled = true, i, false
    PlayAnim(st)
    local k = t.next or 1
    while st.alive and not st.cancelled and k <= #rounds do
        st.round = k
        local ok = lib.skillCheck(rounds[k], KEYS)
        if not st.alive or st.cancelled then break end
        st.seq = (st.seq or 0) + 1
        ctx.report({ type = 'check', target = i, index = k, success = ok == true, seq = st.seq })
        if not ok then
            Say(st, CP.L('block.skill_check.hud.miss', { seconds = tonumber(ctx.obj.missPenalty) or 0 }))
            break
        end
        k = k + 1
        Wait(150)
    end
    st.round = nil
    StopAnim(st)
    st.busy, st.working = false, nil
end

-- ============================================================================
--                               ox_target ZONES
-- ============================================================================

local function RemoveZone(st, i)
    local z = st.zones[i]
    if z then
        pcall(function() exports.ox_target:removeZone(z) end)
        st.zones[i] = nil
    end
end

local function ClearZones(st)
    for i in pairs(st.zones or {}) do RemoveZone(st, i) end
    st.zones = {}
end

local function AddZone(ctx, st, i, t)
    local target = type(ctx.obj.target) == 'table' and ctx.obj.target or {}
    local name = ('crimson-police:%s:%s:%s:%d'):format(BLOCK, tostring(ctx.runId), tostring(ctx.index), i)
    st.zones[i] = exports.ox_target:addSphereZone({
        coords = V3(t.coords),
        radius = TARGET_RADIUS,
        debug = false,
        drawSprite = true,
        name = name,
        options = {
            {
                name = name,
                label = Txt(target.label) or CP.L('block.skill_check.target_default'),
                icon = target.icon,
                distance = TARGET_DISTANCE,
                canInteract = function()
                    local cur = TargetOf(st, i)
                    return st.alive == true and not st.busy and cur ~= nil and cur.status == 'armed'
                        and (cur.worker == nil or cur.worker == Me())
                end,
                onSelect = function()
                    CreateThread(function() Defuse(ctx, st, i) end)
                end,
            },
        },
    })
end

local function SyncZones(ctx, st)
    local list = (st.data and st.data.targets) or {}
    for i, t in ipairs(list) do
        if t.status == 'armed' then
            if not st.zones[i] then AddZone(ctx, st, i, t) end
        else
            RemoveZone(st, i)
        end
    end
    for i in pairs(st.zones) do
        if not list[i] then RemoveZone(st, i) end
    end
end

-- ============================================================================
--                                   MARKERS
-- ============================================================================

local function Loop(ctx, st)
    local token = st.token
    CreateThread(function()
        while st.alive and st.token == token do
            local sleep = 500
            local pos = GetEntityCoords(PlayerPedId())
            for _, t in ipairs((st.data and st.data.targets) or {}) do
                if t.status == 'armed' then
                    local c = t.coords
                    local dx, dy, dz = pos.x - c.x, pos.y - c.y, pos.z - c.z
                    if dx * dx + dy * dy + dz * dz < MARKER_DISTANCE * MARKER_DISTANCE then
                        sleep = 0
                        DrawMarker(2, c.x, c.y, c.z + 0.8, 0.0, 0.0, 0.0, 180.0, 0.0, 0.0, 0.25, 0.25, 0.25, 220, 40,
                            50, 170, true, true, 2, false, nil, nil, false)
                    end
                end
            end
            RefreshLine(ctx, st)
            Wait(sleep)
        end
    end)
end

-- ============================================================================
--                               SERVER MESSAGES
-- ============================================================================

local function Explode(ctx, st, data)
    Say(st, CP.L('block.skill_check.hud.exploded'))
    if st.working == data.target then
        st.cancelled = true
        if lib.skillCheckActive and lib.skillCheckActive() then lib.cancelSkillCheck() end
    end
    if data.effect ~= false and data.by == Me() and type(data.coords) == 'table' then
        -- Effect only: damage scale 0, audible, visible, camera shake.
        AddExplosion(data.coords.x + 0.0, data.coords.y + 0.0, data.coords.z + 0.0, EXPLOSION_TYPE, 0.0, true, false,
            1.0)
    end
end

local function Apply(ctx, st, data)
    local prev = st.data
    st.data = data
    local old = prev and prev.targets or {}
    for i, t in ipairs(data.targets or {}) do
        local o = old[i]
        if o and o.status == 'armed' and t.status == 'defused' then
            Say(st, CP.L('block.skill_check.hud.defused'))
            PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', false)
        end
    end
    SyncZones(ctx, st)
    RefreshBlips(ctx, st)
end

local function Cleanup(ctx, st)
    st.alive = false
    st.cancelled = true
    st.token = (st.token or 0) + 1
    if st.busy and lib.skillCheckActive and lib.skillCheckActive() then lib.cancelSkillCheck() end
    StopAnim(st)
    st.busy, st.working, st.round = false, nil, nil
    ClearZones(st)
    ClearBlips(st)
    if st.line ~= nil then
        st.line = nil
        ctx.hudDetail(nil)
    end
    live[st] = nil
    if states[KeyOf(ctx)] == st then states[KeyOf(ctx)] = nil end
end

CP.Blocks.register(BLOCK, {
    prepare = function(ctx)
        Purge(ctx)
        local st = StateOf(ctx)
        st.zones = st.zones or {}
        st.blips = st.blips or {}
    end,

    start = function(ctx)
        Purge(ctx)
        local st = StateOf(ctx)
        st.zones = st.zones or {}
        st.blips = st.blips or {}
        st.alive = true
        st.token = (st.token or 0) + 1
        live[st] = ctx
        if st.pending then
            local data = st.pending
            st.pending = nil
            Apply(ctx, st, data)
        end
        Loop(ctx, st)
    end,

    update = function(ctx, data)
        if type(data) ~= 'table' then return end
        local st = StateOf(ctx)
        st.zones = st.zones or {}
        st.blips = st.blips or {}
        if data.kind == 'explode' then
            -- Plays even when it arrives together with the run's end.
            Explode(ctx, st, data)
            return
        end
        if data.kind ~= 'state' then return end
        if st.alive then Apply(ctx, st, data) else st.pending = data end
    end,

    -- No NPCs in this block: nothing to re-task when the host changes.
    hostChanged = function(ctx, isHost)
        StateOf(ctx).isHost = isHost == true
    end,

    stop = function(ctx)
        Cleanup(ctx, StateOf(ctx))
    end,
})

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for st, ctx in pairs(live) do Cleanup(ctx, st) end
end)

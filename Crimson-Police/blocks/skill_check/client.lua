--[[ blocks/skill_check/client.lua · objective block "skill_check" (client half)

  What it does
    Registers an ox_target sphere zone on every armed target of the server's snapshot (option names
    "crimson-police:skill_check:<runId>:<objective>:<target>"). Selecting it plays a kneeling animation
    and runs the target's remaining lib.skillCheck rounds one at a time, reporting each round at once;
    a miss stops the sequence (select the target again to retry the same round). When the server
    says a target went off, the client of the participant it names plays the explosion effect
    (AddExplosion with damage scale 0: effect only, hurts nobody). Blips per armed target (none under
    Radio Silence), a small marker within 30 m, and the HUD line via ctx.hudDetail. No networked
    entities are created here and there are no NPCs (hostChanged only records the flag).
    The block's client state is kept per run and objective in this file (stateOf), so it also works
    when the engine hands every hook a fresh ctx.state table.

  Objective fields read: checks [easy, medium, medium, hard], missPenalty [30], target { label, icon },
    explosion [true]
  Evidence sent (ctx.report)
    { type = 'check', target, index, success, seq }   one skill-check round (seq counts this client's
        reports: two misses in a row on the same round are never identical reports)
  Bonuses / penalties: none on the client (the server records no_missed_checks).
]]

local BLOCK = 'skill_check'

local MARKER_DISTANCE = 30.0
local TARGET_RADIUS   = 1.0
local TARGET_DISTANCE = 2.5
local EVENT_MS        = 4000
local KEYS            = { 'w', 'a', 's', 'd' }
local EXPLOSION_TYPE  = 2      -- sticky bomb
local ANIM_DICT       = 'amb@medic@standing@kneel@base'
local ANIM_CLIP       = 'base'

local live = {}     -- [state] = ctx, for resource-stop cleanup
local states = {}   -- ['<runId>:<index>'] = state, one per objective across every hook call

local function keyOf(ctx)
    return tostring(ctx.runId) .. ':' .. tostring(ctx.index)
end

local function stateOf(ctx)
    local key = keyOf(ctx)
    local st = states[key]
    if not st then
        st = type(ctx.state) == 'table' and ctx.state or {}
        st.runKey = tostring(ctx.runId)
        states[key] = st
    end
    return st
end

-- Drop the states of other runs that are no longer running (late snapshots after a stop).
local function purge(ctx)
    local run = tostring(ctx.runId)
    for key, st in pairs(states) do
        if st.runKey ~= run and not st.alive then states[key] = nil end
    end
end

local function v3(t)
    return vector3((t.x or 0.0) + 0.0, (t.y or 0.0) + 0.0, (t.z or 0.0) + 0.0)
end

local function txt(s)
    if type(s) ~= 'string' or s == '' then return nil end
    if CP.Locale.has(s) then return CP.L(s) end
    return s
end

local function me()
    return GetPlayerServerId(PlayerId())
end

local function say(st, text, ms)
    st.transient = text
    st.transientUntil = GetGameTimer() + (ms or EVENT_MS)
end

local function targetOf(st, i)
    return st.data and st.data.targets and st.data.targets[i]
end

local function checksOf(ctx)
    return type(ctx.obj.checks) == 'table' and ctx.obj.checks or Config.Blocks[BLOCK].difficulty.default
end

-- ── HUD line ────────────────────────────────────────────────────────────────
local function baseLine(ctx, st)
    local d = st.data
    if not d then return nil end
    if st.round then
        return CP.L('block.skill_check.hud.round', { n = st.round, total = #checksOf(ctx) })
    end
    local done, total = 0, 0
    for _, t in ipairs(d.targets or {}) do
        total = total + 1
        if t.status == 'defused' then done = done + 1 end
    end
    return CP.L('block.skill_check.hud.progress', { done = done, total = total })
end

local function refreshLine(ctx, st)
    local text
    if st.transient and GetGameTimer() < (st.transientUntil or 0) then
        text = st.transient
    else
        st.transient = nil
        text = baseLine(ctx, st)
    end
    if text ~= st.line then
        st.line = text
        ctx.hudDetail(text)
    end
end

-- ── Blips ───────────────────────────────────────────────────────────────────
local function clearBlips(st)
    for _, b in ipairs(st.blips or {}) do
        if DoesBlipExist(b) then RemoveBlip(b) end
    end
    st.blips = {}
end

local function refreshBlips(ctx, st)
    clearBlips(st)
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

-- ── Defusing ────────────────────────────────────────────────────────────────
local function playAnim(st)
    local ped = PlayerPedId()
    if lib.requestAnimDict then lib.requestAnimDict(ANIM_DICT) end
    TaskPlayAnim(ped, ANIM_DICT, ANIM_CLIP, 8.0, -8.0, -1, 1, 0.0, false, false, false)
    st.animating = true
end

local function stopAnim(st)
    if st.animating then
        st.animating = false
        StopAnimTask(PlayerPedId(), ANIM_DICT, ANIM_CLIP, 1.0)
        RemoveAnimDict(ANIM_DICT)   -- lib.requestAnimDict loaded it for this defuse
    end
end

local function defuse(ctx, st, i)
    if st.busy or not st.alive then return end
    local t = targetOf(st, i)
    if not t or t.status ~= 'armed' then return end
    if t.worker and t.worker ~= me() then return end
    local rounds = checksOf(ctx)
    st.busy, st.working, st.cancelled = true, i, false
    playAnim(st)
    local k = t.next or 1
    while st.alive and not st.cancelled and k <= #rounds do
        st.round = k
        local ok = lib.skillCheck(rounds[k], KEYS)
        if not st.alive or st.cancelled then break end
        st.seq = (st.seq or 0) + 1
        ctx.report({ type = 'check', target = i, index = k, success = ok == true, seq = st.seq })
        if not ok then
            say(st, CP.L('block.skill_check.hud.miss', { seconds = tonumber(ctx.obj.missPenalty) or 0 }))
            break
        end
        k = k + 1
        Wait(150)
    end
    st.round = nil
    stopAnim(st)
    st.busy, st.working = false, nil
end

-- ── ox_target zones ─────────────────────────────────────────────────────────
local function removeZone(st, i)
    local z = st.zones[i]
    if z then
        pcall(function() exports.ox_target:removeZone(z) end)
        st.zones[i] = nil
    end
end

local function clearZones(st)
    for i in pairs(st.zones or {}) do removeZone(st, i) end
    st.zones = {}
end

local function addZone(ctx, st, i, t)
    local target = type(ctx.obj.target) == 'table' and ctx.obj.target or {}
    local name = ('crimson-police:%s:%s:%s:%d'):format(BLOCK, tostring(ctx.runId), tostring(ctx.index), i)
    st.zones[i] = exports.ox_target:addSphereZone({
        coords = v3(t.coords),
        radius = TARGET_RADIUS,
        debug = false,
        drawSprite = true,
        name = name,
        options = {
            {
                name = name,
                label = txt(target.label) or CP.L('block.skill_check.target_default'),
                icon = target.icon,
                distance = TARGET_DISTANCE,
                canInteract = function()
                    local cur = targetOf(st, i)
                    return st.alive == true and not st.busy and cur ~= nil and cur.status == 'armed'
                        and (cur.worker == nil or cur.worker == me())
                end,
                onSelect = function()
                    CreateThread(function() defuse(ctx, st, i) end)
                end,
            },
        },
    })
end

local function syncZones(ctx, st)
    local list = (st.data and st.data.targets) or {}
    for i, t in ipairs(list) do
        if t.status == 'armed' then
            if not st.zones[i] then addZone(ctx, st, i, t) end
        else
            removeZone(st, i)
        end
    end
    for i in pairs(st.zones) do
        if not list[i] then removeZone(st, i) end
    end
end

-- ── Markers ─────────────────────────────────────────────────────────────────
local function loop(ctx, st)
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
                        DrawMarker(2, c.x, c.y, c.z + 0.8, 0.0, 0.0, 0.0, 180.0, 0.0, 0.0, 0.25, 0.25, 0.25,
                            220, 40, 50, 170, true, true, 2, false, nil, nil, false)
                    end
                end
            end
            refreshLine(ctx, st)
            Wait(sleep)
        end
    end)
end

-- ── Server messages ─────────────────────────────────────────────────────────
local function explode(ctx, st, data)
    say(st, CP.L('block.skill_check.hud.exploded'))
    if st.working == data.target then
        st.cancelled = true
        if lib.skillCheckActive and lib.skillCheckActive() then lib.cancelSkillCheck() end
    end
    if data.effect ~= false and data.by == me() and type(data.coords) == 'table' then
        -- Effect only: damage scale 0, audible, visible, camera shake.
        AddExplosion(data.coords.x + 0.0, data.coords.y + 0.0, data.coords.z + 0.0, EXPLOSION_TYPE, 0.0, true, false, 1.0)
    end
end

local function apply(ctx, st, data)
    local prev = st.data
    st.data = data
    local old = prev and prev.targets or {}
    for i, t in ipairs(data.targets or {}) do
        local o = old[i]
        if o and o.status == 'armed' and t.status == 'defused' then
            say(st, CP.L('block.skill_check.hud.defused'))
            PlaySoundFrontend(-1, 'CHECKPOINT_PERFECT', 'HUD_MINI_GAME_SOUNDSET', false)
        end
    end
    syncZones(ctx, st)
    refreshBlips(ctx, st)
end

local function cleanup(ctx, st)
    st.alive = false
    st.cancelled = true
    st.token = (st.token or 0) + 1
    if st.busy and lib.skillCheckActive and lib.skillCheckActive() then lib.cancelSkillCheck() end
    stopAnim(st)
    st.busy, st.working, st.round = false, nil, nil
    clearZones(st)
    clearBlips(st)
    if st.line ~= nil then
        st.line = nil
        ctx.hudDetail(nil)
    end
    live[st] = nil
    if states[keyOf(ctx)] == st then states[keyOf(ctx)] = nil end
end

CP.Blocks.register(BLOCK, {
    prepare = function(ctx)
        purge(ctx)
        local st = stateOf(ctx)
        st.zones = st.zones or {}
        st.blips = st.blips or {}
    end,

    start = function(ctx)
        purge(ctx)
        local st = stateOf(ctx)
        st.zones = st.zones or {}
        st.blips = st.blips or {}
        st.alive = true
        st.token = (st.token or 0) + 1
        live[st] = ctx
        if st.pending then
            local data = st.pending
            st.pending = nil
            apply(ctx, st, data)
        end
        loop(ctx, st)
    end,

    update = function(ctx, data)
        if type(data) ~= 'table' then return end
        local st = stateOf(ctx)
        st.zones = st.zones or {}
        st.blips = st.blips or {}
        if data.kind == 'explode' then
            -- Plays even when it arrives together with the run's end.
            explode(ctx, st, data)
            return
        end
        if data.kind ~= 'state' then return end
        if st.alive then apply(ctx, st, data) else st.pending = data end
    end,

    -- No NPCs in this block: nothing to re-task when the host changes.
    hostChanged = function(ctx, isHost)
        stateOf(ctx).isHost = isHost == true
    end,

    stop = function(ctx)
        cleanup(ctx, stateOf(ctx))
    end,
})

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for st, ctx in pairs(live) do cleanup(ctx, st) end
end)

--[[ blocks/interact_points/client.lua · objective block "interact_points" (client half)

  What it does
    For every open point of the server's snapshot it registers an ox_target sphere zone (option names
    "crimson-police:interact_points:<runId>:<objective>:<point>:<main|follow>") that runs
    lib.progressBar (cancellable, movement/car/combat disabled, animation from progress.anim) and
    reports the result. Shows the rolled outcome ("Door is secure" / "Door found open") and the
    follow-up hint, the tablet-log hint, and hidden-device search results on the HUD line
    (ctx.hudDetail). Small markers within 40 m; blips per point (hidden search: one area blip);
    no blips under Radio Silence. Only participants' clients register targets. No networked entities
    are created here and there are no NPCs (hostChanged only records the flag).

  Objective fields read
    target { label, icon, radius [1.5] } · progress { label, duration (ms), anim } · hidden { label }
    · label (blip text fallback). Outcomes, follow-ups and the log come from the server snapshot.
  Evidence sent (ctx.report)
    { type = 'interact', point }   the main action's progress bar finished at that point
    { type = 'followup', point }   the follow-up action's progress bar finished
    ('log' is sent by the tablet's Active Mission screen, not by this file)
  Bonuses / penalties: none on the client (the server records correct_log, wrong_log, fastBonus.id).
]]

local BLOCK = 'interact_points'

local MARKER_DISTANCE = 40.0
local TARGET_DISTANCE = 2.5
local EVENT_MS        = 5000

-- Config.Builder.allowed.animations -> ox_lib progress animations.
local ANIMS = {
    clipboard = { scenario = 'WORLD_HUMAN_CLIPBOARD' },
    search    = { dict = 'amb@prop_human_bum_bin@base', clip = 'base', flag = 1 },
    kneel     = { dict = 'amb@medic@standing@kneel@base', clip = 'base', flag = 1 },
    mechanic  = { dict = 'mini@repair', clip = 'fixing_a_ped', flag = 1 },
}

local live = {}   -- [state] = ctx, for resource-stop cleanup

local function v3(t)
    return vector3((t.x or 0.0) + 0.0, (t.y or 0.0) + 0.0, (t.z or 0.0) + 0.0)
end

local function txt(s)
    if type(s) ~= 'string' or s == '' then return nil end
    if CP.Locale.has(s) then return CP.L(s) end
    return s
end

local function animFor(a)
    if type(a) == 'table' then return a end
    return ANIMS[a] or ANIMS[Config.Blocks[BLOCK].animation] or ANIMS.clipboard
end

local function zoneName(ctx, n, kind)
    return ('crimson-police:%s:%s:%s:%d:%s'):format(BLOCK, tostring(ctx.runId), tostring(ctx.index), n, kind)
end

local function say(st, text, ms)
    st.transient = text
    st.transientUntil = GetGameTimer() + (ms or EVENT_MS)
end

local function pointOf(st, n)
    return st.data and st.data.points and st.data.points[n]
end

-- ── HUD line ────────────────────────────────────────────────────────────────
local function baseLine(ctx, st)
    local d = st.data
    if not d then return nil end
    if d.hidden then
        return CP.L('block.interact_points.hud.devices', { found = d.found or 0, total = d.total or 0 })
    end
    local text = CP.L('block.interact_points.hud.points', { done = d.done or 0, total = d.total or 0 })
    if d.log then text = text .. ' · ' .. CP.L('block.interact_points.hud.log') end
    return text
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

local function nameBlip(b, text)
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandSetBlipName(b)
end

local function refreshBlips(ctx, st)
    clearBlips(st)
    local d = st.data
    if ctx.radioSilence or not d then return end
    local pts = d.points or {}
    if d.hidden then
        if (d.found or 0) >= (d.total or 0) or #pts == 0 then return end
        local cx, cy, cz = 0.0, 0.0, 0.0
        for _, p in ipairs(pts) do cx, cy, cz = cx + p.coords.x, cy + p.coords.y, cz + p.coords.z end
        cx, cy, cz = cx / #pts, cy / #pts, cz / #pts
        local r = 10.0
        for _, p in ipairs(pts) do
            local dx, dy = p.coords.x - cx, p.coords.y - cy
            r = math.max(r, math.sqrt(dx * dx + dy * dy) + 10.0)
        end
        local area = AddBlipForRadius(cx, cy, cz, r)
        SetBlipColour(area, 1)
        SetBlipAlpha(area, 90)
        st.blips[#st.blips + 1] = area
        local centre = AddBlipForCoord(cx, cy, cz)
        SetBlipSprite(centre, 1)
        SetBlipColour(centre, 1)
        SetBlipScale(centre, 0.7)
        nameBlip(centre, CP.L('block.interact_points.blip_search'))
        st.blips[#st.blips + 1] = centre
        return
    end
    for n, p in ipairs(pts) do
        if p.status == 'pending' or p.status == 'followup' then
            local b = AddBlipForCoord(p.coords.x, p.coords.y, p.coords.z)
            SetBlipSprite(b, 1)
            SetBlipColour(b, p.status == 'followup' and 17 or 5)
            SetBlipScale(b, 0.75)
            SetBlipAsShortRange(b, false)
            nameBlip(b, txt(p.label) or txt(ctx.obj.label) or CP.L('block.interact_points.blip', { n = n }))
            st.blips[#st.blips + 1] = b
        end
    end
end

-- ── ox_target zones ─────────────────────────────────────────────────────────
local function removeZone(st, n)
    local z = st.zones[n]
    if z then
        pcall(function() exports.ox_target:removeZone(z.id) end)
        st.zones[n] = nil
    end
end

local function clearZones(st)
    for n in pairs(st.zones or {}) do removeZone(st, n) end
    st.zones = {}
end

local function interact(ctx, st, n, kind, duration, label)
    if st.busy or not st.alive then return end
    if lib.progressActive and lib.progressActive() then return end
    st.busy = true
    local ok = lib.progressBar({
        duration = duration,
        label = label,
        useWhileDead = false,
        canCancel = true,
        disable = { move = true, car = true, combat = true },
        anim = animFor(ctx.obj.progress and ctx.obj.progress.anim),
    })
    st.busy = false
    if ok and st.alive then
        ctx.report({ type = (kind == 'main') and 'interact' or 'followup', point = n })
    end
end

local function addZone(ctx, st, n, kind, p)
    local obj = ctx.obj
    local target = type(obj.target) == 'table' and obj.target or {}
    local progress = type(obj.progress) == 'table' and obj.progress or {}
    local label, duration, barLabel
    if kind == 'main' then
        label = txt(target.label) or CP.L(st.hidden and 'block.interact_points.target_search' or 'block.interact_points.target_default')
        duration = tonumber(progress.duration) or (Config.Blocks[BLOCK].progress[3] * 1000)
        barLabel = txt(progress.label) or CP.L('block.interact_points.progress_default')
    else
        local f = p.followUp or {}
        label = txt(f.label) or CP.L('block.interact_points.followup_default')
        duration = tonumber(f.duration) or tonumber(progress.duration) or (Config.Blocks[BLOCK].progress[3] * 1000)
        barLabel = label
    end
    local wantStatus = (kind == 'main') and 'pending' or 'followup'
    local name = zoneName(ctx, n, kind)
    local id = exports.ox_target:addSphereZone({
        coords = v3(p.coords),
        radius = tonumber(target.radius) or 1.5,
        debug = false,
        drawSprite = true,
        name = name,
        options = {
            {
                name = name,
                label = label,
                icon = target.icon,
                distance = TARGET_DISTANCE,
                canInteract = function()
                    local cur = pointOf(st, n)
                    return st.alive == true and not st.busy and cur ~= nil and cur.status == wantStatus
                end,
                onSelect = function()
                    CreateThread(function() interact(ctx, st, n, kind, duration, barLabel) end)
                end,
            },
        },
    })
    st.zones[n] = { id = id, kind = kind }
end

local function syncZones(ctx, st)
    local pts = (st.data and st.data.points) or {}
    for n, p in ipairs(pts) do
        local want = (p.status == 'pending' and 'main') or (p.status == 'followup' and 'follow') or nil
        local z = st.zones[n]
        if z and z.kind ~= want then
            removeZone(st, n)
            z = nil
        end
        if want and not z then addZone(ctx, st, n, want, p) end
    end
    for n in pairs(st.zones) do
        if not pts[n] then removeZone(st, n) end
    end
end

-- ── Markers ─────────────────────────────────────────────────────────────────
local function loop(ctx, st)
    local token = st.token
    CreateThread(function()
        while st.alive and st.token == token do
            local sleep = 500
            local pts = (st.data and st.data.points) or {}
            local pos = GetEntityCoords(PlayerPedId())
            for _, p in ipairs(pts) do
                if p.status == 'pending' or p.status == 'followup' then
                    local c = p.coords
                    local dx, dy, dz = pos.x - c.x, pos.y - c.y, pos.z - c.z
                    if dx * dx + dy * dy + dz * dz < MARKER_DISTANCE * MARKER_DISTANCE then
                        sleep = 0
                        local r, g, b = 240, 200, 60
                        if p.status == 'followup' then r, g, b = 220, 60, 60 end
                        DrawMarker(2, c.x, c.y, c.z + 0.9, 0.0, 0.0, 0.0, 180.0, 0.0, 0.0, 0.25, 0.25, 0.25,
                            r, g, b, 160, true, true, 2, false, nil, nil, false)
                    end
                end
            end
            refreshLine(ctx, st)
            Wait(sleep)
        end
    end)
end

-- ── Snapshot from the server ────────────────────────────────────────────────
local function announce(ctx, st, prev, data)
    local oldPts = prev and prev.points or {}
    for n, p in ipairs(data.points or {}) do
        local old = oldPts[n]
        if old and old.status ~= p.status then
            if data.hidden and p.status == 'done' then
                if p.found then
                    local what = txt(ctx.obj.hidden and ctx.obj.hidden.label) or CP.L('block.interact_points.device_default')
                    say(st, CP.L('block.interact_points.hud.found', { label = what }))
                    PlaySoundFrontend(-1, 'CHECKPOINT_NORMAL', 'HUD_MINI_GAME_SOUNDSET', false)
                else
                    say(st, CP.L('block.interact_points.hud.nothing'))
                end
            elseif p.status == 'followup' then
                local f = p.followUp or {}
                say(st, CP.L('block.interact_points.hud.followup', {
                    outcome = p.outcomeLabel or '',
                    action = txt(f.label) or CP.L('block.interact_points.followup_default'),
                }))
            elseif old.status == 'pending' and p.outcomeLabel then
                say(st, p.outcomeLabel)
            elseif p.status == 'done' and old.status == 'log' then
                say(st, CP.L('block.interact_points.hud.logged'))
            end
        end
    end
end

local function apply(ctx, st, data)
    local prev = st.data
    st.data = data
    st.hidden = data.hidden == true
    announce(ctx, st, prev, data)
    syncZones(ctx, st)
    refreshBlips(ctx, st)
end

local function cleanup(ctx, st)
    st.alive = false
    st.token = (st.token or 0) + 1
    if st.busy and lib.progressActive and lib.progressActive() then lib.cancelProgress() end
    st.busy = false
    clearZones(st)
    clearBlips(st)
    if st.line ~= nil then
        st.line = nil
        ctx.hudDetail(nil)
    end
    live[st] = nil
end

CP.Blocks.register(BLOCK, {
    prepare = function(ctx)
        local st = ctx.state
        st.zones = st.zones or {}
        st.blips = st.blips or {}
    end,

    start = function(ctx)
        local st = ctx.state
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
        if type(data) ~= 'table' or data.kind ~= 'state' then return end
        local st = ctx.state
        if st.alive then apply(ctx, st, data) else st.pending = data end
    end,

    -- No NPCs in this block: nothing to re-task when the host changes.
    hostChanged = function(ctx, isHost)
        ctx.state.isHost = isHost == true
    end,

    stop = function(ctx)
        cleanup(ctx, ctx.state)
    end,
})

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for st, ctx in pairs(live) do cleanup(ctx, st) end
end)

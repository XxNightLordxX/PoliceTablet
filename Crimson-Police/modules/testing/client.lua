--[[ modules/testing/client.lua · CP.Testing (client): the test-control panel, the debug overlay drawing
  and the test invitation prompt.

  Owns
    * the key mapping +crimsonpolice_testpanel (default F9, rebindable in GTA settings). For the admin who
      started the active test it gives NUI focus to the HUD test-control panel (hud/TestControls.tsx); with
      no controls it opens the test invitation prompt (hud/DebugOverlay.tsx) when invitations are waiting.
      NUI focus is taken only while the panel/prompt is open and only when no Crimson-Police UI is open, and
      it is released on close, Escape/F9 (the NUI calls the client action testPanel), when the test ends,
      on a foreign crimsonArena value and on resource stop. It is never released unconditionally.
    * the HUD flag testControls (CP.Tablet.hud({ testControls = true })) re-asserted for the admin's run
      (CP.Runs client sets it at client:start; this module only patches a HUD that belongs to that run)
    * the in-world debug overlay while it is on: DrawMarker for the start radius, spawn points, zones and
      route waypoints (with lines between waypoints), drawn every frame only within DRAW_RANGE of the player
      and only while the player is near the test area; otherwise the loop sleeps 500 ms
    * live counts pushed to the NUI: CP.Tablet.push('test', { controls, focused, key, debugOn, runId,
      debug = DebugData|false, prompt = { invites }|false }) (App passes `debug` to DebugOverlay; the
      geometry stays in Lua)
    * the invitation toast (client:testInvite)

  Client actions (CP.Tablet.registerClientAction, NUI 'client' endpoint)
    testControl { control, target?, enabled? } -> forwards to server:test:control (teleport and debug are
                                                 handled locally as below)
    teleport    { target = 'start'|'objective' } -> server returns coords; re-checks crimsonArena, then
                                                 SetEntityCoords (the vehicle when driving) with ground z
    toggleDebug { enabled? }                  -> server:test:control { control = 'debug' }
    testPanel   { open = bool }               -> take / release the panel focus
  Events handled: client:test { controls, runId, debug }, client:testInvite { inviteId, missionLabel, from,
    expiresIn }, client:inProgress / client:runEnded (HUD flag, focus), crimsonArena state bag (local player).
]]

CP.Testing = CP.Testing or {}
local Testing = CP.Testing
local TAG = 'testing'

local KEY_COMMAND = '+crimsonpolice_testpanel'
local KEY_RELEASE = '-crimsonpolice_testpanel'
local DEFAULT_KEY = 'F9'
local DRAW_RANGE = 250.0          -- markers further than this are not drawn
local ACTIVE_RANGE = 600.0        -- draw every frame only while this close to the test area
local LABEL_RANGE = 25.0          -- 3D labels for points this close
local INVITE_TOAST_MS = 12000
local CONTROLS = { skip = true, restart = true, pause = true, resume = true, complete = true, fail = true, ['end'] = true, teleport = true, debug = true }
local COLOURS = {
    start = { 229, 56, 59 }, point = { 245, 165, 36 }, route = { 78, 161, 255 }, zone = { 52, 196, 124 },
    presence = { 170, 120, 255 },
}

local state = {
    controls = false,     -- this player started the active test (server said so)
    runId = nil,
    inRun = false,        -- still a participant of that run (HUD visible)
    focused = false,
    focusKind = nil,      -- 'controls' | 'invites'
    prompt = false,       -- invitation prompt open
    debugOn = false,
    debug = nil,          -- last debug payload (without geometry)
    geometry = nil,
    drawToken = 0,
    watchToken = 0,
    hudToken = 0,
}

-- ── helpers ─────────────────────────────────────────────────────────────────
local function tabletOpen()
    return CP.Tablet and CP.Tablet.isOpen and CP.Tablet.isOpen() == true
end

local function arenaForeign()
    local st = LocalPlayer and LocalPlayer.state
    local v = st and st.crimsonArena
    return type(v) == 'table' and v.active == true and v.source ~= 'crimson-police'
end

local function notify(kind, key, vars, opts)
    if CP.Tablet and CP.Tablet.notify then CP.Tablet.notify(kind, CP.L(key, vars), opts) end
end

local function keyLabel()
    local ok, label = pcall(function()
        local hash = (joaat(KEY_COMMAND) & 0xFFFFFFFF) | 0x80000000
        return GetControlInstructionalButton(0, hash, true)
    end)
    if ok and type(label) == 'string' and label:sub(1, 2) == 't_' and #label > 2 then return label:sub(3) end
    return DEFAULT_KEY
end

local function pushNui(extra)
    if not (CP.Tablet and CP.Tablet.push) then return end
    local data = {
        controls = state.controls and state.inRun, focused = state.focused, key = keyLabel(),
        debugOn = state.debugOn, runId = state.runId or false,
    }
    if type(extra) == 'table' then
        for k, v in pairs(extra) do data[k] = v end
    end
    CP.Tablet.push('test', data)
end

local function currentRun()
    if CP.Runs and CP.Runs.current then
        local ok, run = pcall(CP.Runs.current)
        if ok then return run end
    end
    return nil
end

-- Patch the HUD flag only while the HUD belongs to the admin's run (never creates a HUD of its own).
local function applyHudFlag(runId)
    state.hudToken = state.hudToken + 1
    local t = state.hudToken
    CreateThread(function()
        for _ = 1, 30 do
            if t ~= state.hudToken or not state.controls or state.runId ~= runId then return end
            local run = currentRun()
            if run and run.id == runId then
                if CP.Tablet and CP.Tablet.hud then CP.Tablet.hud({ testControls = true }) end
                return
            end
            Wait(500)
        end
    end)
end

-- ── focus ───────────────────────────────────────────────────────────────────
local function releaseFocus()
    if not state.focused then return end
    state.focused = false
    state.focusKind = nil
    state.watchToken = state.watchToken + 1
    if not tabletOpen() then SetNuiFocus(false, false) end
    local extra = nil
    if state.prompt then
        state.prompt = false
        extra = { prompt = false }
    end
    pushNui(extra)
end

local function watchFocus()
    state.watchToken = state.watchToken + 1
    local t = state.watchToken
    CreateThread(function()
        while state.focused and t == state.watchToken do
            Wait(250)
            if t ~= state.watchToken or not state.focused then return end
            if tabletOpen() then
                -- The tablet took over the focus: forget ours without touching it.
                state.focused, state.focusKind = false, nil
                if state.prompt then state.prompt = false; pushNui({ prompt = false }) else pushNui() end
                return
            end
            if arenaForeign() or (state.focusKind == 'controls' and not (state.controls and state.inRun)) then
                releaseFocus()
                return
            end
        end
    end)
end

local function takeFocus(kind)
    if state.focused then return true end
    if tabletOpen() or arenaForeign() then return false end
    state.focused = true
    state.focusKind = kind
    SetNuiFocus(true, true)
    watchFocus()
    return true
end

-- ── debug overlay (in world) ────────────────────────────────────────────────
local function drawText3D(x, y, z, text)
    SetTextScale(0.3, 0.3)
    SetTextFont(4)
    SetTextProportional(true)
    SetTextColour(255, 255, 255, 215)
    SetTextOutline()
    SetTextCentre(true)
    SetDrawOrigin(x, y, z, 0)
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayText(0.0, 0.0)
    ClearDrawOrigin()
end

local function dist(ax, ay, az, bx, by, bz)
    local dx, dy, dz = ax - bx, ay - by, az - bz
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Distance from the player to the closest element of the test area (start, points, zones, waypoints).
local function nearestDistance(g, px, py, pz)
    local best = math.huge
    if g.start then best = math.min(best, dist(px, py, pz, g.start.x, g.start.y, g.start.z) - (g.start.r or 0)) end
    for _, p in ipairs(g.points or {}) do best = math.min(best, dist(px, py, pz, p.x, p.y, p.z)) end
    for _, z in ipairs(g.zones or {}) do best = math.min(best, dist(px, py, pz, z.x, z.y, z.z) - z.r) end
    for _, r in ipairs(g.routes or {}) do
        for _, p in ipairs(r.points) do best = math.min(best, dist(px, py, pz, p.x, p.y, p.z)) end
    end
    return best
end

local function drawCylinder(x, y, z, radius, height, c, alpha)
    DrawMarker(1, x, y, z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, radius * 2.0, radius * 2.0, height,
        c[1], c[2], c[3], alpha, false, false, 2, false, nil, nil, false)
end

local function drawFrame(g, px, py, pz)
    if g.start then
        local s = g.start
        if dist(px, py, pz, s.x, s.y, s.z) <= DRAW_RANGE + (s.r or 0) then
            drawCylinder(s.x, s.y, s.z, math.max(1.0, s.r or 1.0), 1.2, COLOURS.start, 70)
            if dist(px, py, pz, s.x, s.y, s.z) <= LABEL_RANGE + (s.r or 0) then
                drawText3D(s.x, s.y, s.z + 1.5, CP.L('test.debug_start', { r = math.floor(s.r or 0) }))
            end
        end
    end
    for _, z in ipairs(g.zones or {}) do
        if dist(px, py, pz, z.x, z.y, z.z) <= DRAW_RANGE + z.r then
            drawCylinder(z.x, z.y, z.z, z.r, 0.6, z.label == 'presence' and COLOURS.presence or COLOURS.zone, 45)
        end
    end
    for _, p in ipairs(g.points or {}) do
        local d = dist(px, py, pz, p.x, p.y, p.z)
        if d <= DRAW_RANGE then
            local c = COLOURS.point
            DrawMarker(2, p.x, p.y, p.z + 1.1, 0.0, 0.0, 0.0, 180.0, 0.0, 0.0, 0.45, 0.45, 0.45,
                c[1], c[2], c[3], 210, true, true, 2, false, nil, nil, false)
            if p.r then drawCylinder(p.x, p.y, p.z, p.r, 0.5, COLOURS.route, 40) end
            if d <= LABEL_RANGE then drawText3D(p.x, p.y, p.z + 1.7, ('%s #%d'):format(tostring(p.key), p.i or 1)) end
        end
    end
    for _, r in ipairs(g.routes or {}) do
        local c = COLOURS.route
        local pts = r.points
        for i, p in ipairs(pts) do
            if dist(px, py, pz, p.x, p.y, p.z) <= DRAW_RANGE then
                DrawMarker(1, p.x, p.y, p.z - 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.4, 1.4, 0.5,
                    c[1], c[2], c[3], 150, false, false, 2, false, nil, nil, false)
                local n = pts[i + 1] or (r.loop and pts[1]) or nil
                if n then DrawLine(p.x, p.y, p.z + 0.4, n.x, n.y, n.z + 0.4, c[1], c[2], c[3], 200) end
                if i == 1 and dist(px, py, pz, p.x, p.y, p.z) <= LABEL_RANGE then
                    drawText3D(p.x, p.y, p.z + 1.2, ('%s (%d)'):format(tostring(r.key), #pts))
                end
            end
        end
    end
end

local function stopDrawing()
    state.drawToken = state.drawToken + 1
end

local function startDrawing()
    state.drawToken = state.drawToken + 1
    local t = state.drawToken
    CreateThread(function()
        local near, checkAt = false, 0
        while t == state.drawToken and state.debugOn do
            local g = state.geometry
            if not g then
                Wait(500)
            else
                local pc = GetEntityCoords(PlayerPedId())
                local now = GetGameTimer()
                if now >= checkAt then
                    near = nearestDistance(g, pc.x, pc.y, pc.z) <= ACTIVE_RANGE
                    checkAt = now + 500
                end
                if near then
                    drawFrame(g, pc.x, pc.y, pc.z)
                    Wait(0)
                else
                    Wait(500)
                end
            end
        end
    end)
end

local function debugOff()
    state.debugOn = false
    state.debug = nil
    state.geometry = nil
    stopDrawing()
end

local function applyDebug(payload)
    if type(payload) ~= 'table' then
        debugOff()
        return false
    end
    if type(payload.geometry) == 'table' then state.geometry = payload.geometry end
    local copy = {}
    for k, v in pairs(payload) do
        if k ~= 'geometry' then copy[k] = v end
    end
    state.debug = copy
    if not state.debugOn then
        state.debugOn = true
        startDrawing()
    end
    return copy
end

-- ── teleport ────────────────────────────────────────────────────────────────
local function groundZ(x, y, z)
    for _, probe in ipairs({ 2.0, 25.0, 100.0 }) do
        for _ = 1, 10 do
            RequestCollisionAtCoord(x, y, z)
            local found, gz = GetGroundZFor_3dCoord(x, y, z + probe, false)
            if found and type(gz) == 'number' then return gz end
            Wait(50)
        end
    end
    return z
end

local function teleportTo(x, y, z)
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    local ent = ped
    if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then ent = veh end
    DoScreenFadeOut(300)
    local deadline = GetGameTimer() + 1500
    while not IsScreenFadedOut() and GetGameTimer() < deadline do Wait(0) end
    local ok, err = pcall(function()
        FreezeEntityPosition(ent, true)
        SetEntityCoords(ent, x, y, z + 1.0, false, false, false, false)
        local gz = groundZ(x, y, z)
        if arenaForeign() then error('in_arena', 0) end
        SetEntityCoords(ent, x, y, gz, false, false, false, false)
    end)
    FreezeEntityPosition(ent, false)
    DoScreenFadeIn(300)
    if not ok then
        if err == 'in_arena' then return false, 'err.in_arena' end
        CP.err(TAG, 'teleport failed: %s', tostring(err))
        return false, 'err.test_control_failed'
    end
    return true
end

local function doTeleport(target)
    if target ~= nil and target ~= 'start' and target ~= 'objective' then return false, 'err.invalid_payload' end
    if arenaForeign() then return false, 'err.in_arena' end
    local res = CP.Net.action('server:test:control', { control = 'teleport', target = target, runId = state.runId })
    if type(res) ~= 'table' or not res.ok then return false, type(res) == 'table' and res.error or 'err.no_response' end
    local c = type(res.data) == 'table' and res.data.coords or nil
    local x, y, z = CP.U.xyz(c)
    if not (tonumber(x) and tonumber(y) and tonumber(z)) then return false, 'err.test_control_failed' end
    -- Crimson-Arena rule 13: re-check the local flag right before moving the player.
    if arenaForeign() then return false, 'err.in_arena' end
    local ok, errKey = teleportTo(x + 0.0, y + 0.0, z + 0.0)
    if not ok then return false, errKey end
    return true, { target = res.data.target }
end

local function toggleDebug(enabled)
    if enabled ~= nil and type(enabled) ~= 'boolean' then return false, 'err.invalid_payload' end
    local res = CP.Net.action('server:test:control', { control = 'debug', enabled = enabled, runId = state.runId })
    if type(res) ~= 'table' or not res.ok then return false, type(res) == 'table' and res.error or 'err.no_response' end
    local on = type(res.data) == 'table' and res.data.debug == true
    if not on then
        debugOff()
        pushNui({ debug = false })
    end
    return true, { debug = on }
end

-- ── the panel key ───────────────────────────────────────────────────────────
local function openPrompt()
    CreateThread(function()
        local res = CP.Net.request('test:pendingInvites', {})
        local list = (type(res) == 'table' and res.ok and type(res.data) == 'table') and res.data or {}
        if #list == 0 then
            notify('info', 'test.no_invites')
            return
        end
        if tabletOpen() or arenaForeign() then return end
        if takeFocus('invites') then
            state.prompt = true
            pushNui({ prompt = { invites = list } })
        end
    end)
end

local function onPanelKey()
    if state.focused then
        releaseFocus()
        return
    end
    if tabletOpen() then return end
    if arenaForeign() then
        notify('error', 'err.in_arena')
        return
    end
    if state.controls and state.inRun then
        if takeFocus('controls') then pushNui() end
        return
    end
    openPrompt()
end

-- ── server events ───────────────────────────────────────────────────────────
RegisterNetEvent(CP.e('client:test'), function(data)
    if type(data) ~= 'table' then return end
    local extra = nil
    if data.controls == true and type(data.runId) == 'string' then
        local isNew = state.runId ~= data.runId
        state.controls = true
        state.runId = data.runId
        if isNew then
            state.inRun = true
            debugOff()
            applyHudFlag(data.runId)
        end
    elseif data.controls == false then
        if data.runId == nil or data.runId == state.runId then
            state.controls = false
            state.inRun = false
            state.runId = nil
            state.hudToken = state.hudToken + 1
            debugOff()
            if state.focusKind == 'controls' then releaseFocus() end
            extra = { debug = false }
        end
    end
    if data.debug ~= nil and state.controls then
        local nuiDebug = applyDebug(data.debug)
        extra = extra or {}
        extra.debug = nuiDebug or false
    end
    pushNui(extra)
end)

RegisterNetEvent(CP.e('client:testInvite'), function(inv)
    if type(inv) ~= 'table' or type(inv.inviteId) ~= 'string' then return end
    local from = type(inv.from) == 'string' and inv.from or '?'
    local mission = type(inv.missionLabel) == 'string' and inv.missionLabel or '?'
    notify('info', 'test.invite_toast', { from = from, mission = mission, key = keyLabel() },
        { title = CP.L('test.invite_title'), duration = INVITE_TOAST_MS })
end)

RegisterNetEvent(CP.e('client:inProgress'), function(runId)
    if state.controls and runId == state.runId then applyHudFlag(runId) end
end)

RegisterNetEvent(CP.e('client:runEnded'), function(runId)
    if type(runId) ~= 'string' or runId ~= state.runId then return end
    -- This player left the run (the test may go on without them): the HUD panel is gone.
    state.inRun = false
    state.hudToken = state.hudToken + 1
    if state.focusKind == 'controls' then releaseFocus() end
    pushNui()
end)

-- ── registration (runtime) ──────────────────────────────────────────────────
local function registerActions()
    if not (CP.Tablet and CP.Tablet.registerClientAction) then return false end
    CP.Tablet.registerClientAction('testControl', function(payload)
        if type(payload) ~= 'table' or type(payload.control) ~= 'string' or not CONTROLS[payload.control] then
            return false, 'err.invalid_payload'
        end
        if not state.controls then return false, 'err.test_no_active' end
        if payload.control == 'teleport' then return doTeleport(payload.target) end
        if payload.control == 'debug' then return toggleDebug(payload.enabled) end
        local res = CP.Net.action('server:test:control', { control = payload.control, runId = state.runId })
        if type(res) ~= 'table' then return false, 'err.no_response' end
        if res.ok then return true, res.data end
        return false, res.error
    end)
    CP.Tablet.registerClientAction('teleport', function(payload)
        if not state.controls then return false, 'err.test_no_active' end
        local target = type(payload) == 'table' and payload.target or nil
        return doTeleport(target)
    end)
    CP.Tablet.registerClientAction('toggleDebug', function(payload)
        if not state.controls then return false, 'err.test_no_active' end
        local enabled = type(payload) == 'table' and payload.enabled or nil
        return toggleDebug(enabled)
    end)
    CP.Tablet.registerClientAction('testPanel', function(payload)
        local open = type(payload) == 'table' and payload.open == true
        if not open then
            releaseFocus()
            return true, { focused = false }
        end
        if not (state.controls and state.inRun) then return false, 'err.test_no_active' end
        if takeFocus('controls') then pushNui() end
        return true, { focused = state.focused }
    end)
    return true
end

CreateThread(function()
    RegisterCommand(KEY_COMMAND, function() onPanelKey() end, false)
    RegisterCommand(KEY_RELEASE, function() end, false)
    RegisterKeyMapping(KEY_COMMAND, CP.L('test.keybind_label'), 'keyboard', DEFAULT_KEY)
    for _ = 1, 60 do
        if registerActions() then return end
        Wait(500)
    end
    CP.warn(TAG, 'CP.Tablet.registerClientAction is not available: the test controls are not registered')
end)

-- Crimson-Arena rule 8: a foreign crimsonArena value closes our panel and stops the overlay.
CreateThread(function()
    local bag = ('player:%d'):format(GetPlayerServerId(PlayerId()))
    AddStateBagChangeHandler('crimsonArena', bag, function(_, _, value)
        if type(value) == 'table' and value.active == true and value.source ~= 'crimson-police' then
            SetTimeout(0, function()
                releaseFocus()
                debugOff()
                pushNui({ debug = false })
            end)
        end
    end)
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    stopDrawing()
    if state.focused and not tabletOpen() then SetNuiFocus(false, false) end
    state.focused = false
end)

-- Test hooks (tests/testing_spec.lua only).
Testing._state = function() return state end
Testing._onPanelKey = onPanelKey
Testing._nearest = nearestDistance

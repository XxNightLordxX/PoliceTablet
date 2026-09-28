-- modules/tablet/client.lua · CP.Tablet (client): the NUI. The only file that calls SendNUIMessage.
--
-- Owns: /CrimsonPolice (Config.Tablet.command), the key mapping crimsonpolice_tablet (default key
-- Config.Tablet.keybind; '' = unbound, players can bind it in GTA settings), the optional ox_inventory
-- tablet item, the client export OpenTablet, opening/closing the Officer, Supervisor and Admin UIs with
-- NUI focus, the tablet prop and animation (Officer/Supervisor UI only), toasts, the mission HUD state,
-- the result screen, overlays, live pushes, the department theme sent at login, and every NUI callback.
-- Every open goes through the server callback getSession, so the server decides who may open what.
--
-- Public API (docs/ARCHITECTURE.md §5.4)
--   CP.Tablet.open(ui) -> ok, errKey        ui 'officer'|'supervisor'|'admin'; asks getSession, shows the
--                                           UI and takes focus; on refusal shows the error as a toast.
--                                           Yields (call it from a thread).
--   CP.Tablet.close() -> boolean            hides the UI (the HUD stays), releases focus, removes the prop
--   CP.Tablet.isOpen() -> boolean
--   CP.Tablet.send(msg)                     SendNUIMessage (vectors serialised)
--   CP.Tablet.notify(kind, text, opts)      a toast with already translated text; opts = { title, duration }
--   CP.Tablet.hud(patch)                    shallow-merges patch into the HUD state (§9.3) and sends
--                                           { type = 'hud', hud = state }; hud(nil) hides it. A nullable
--                                           field (modifier, timer, route, message, detail) set to false
--                                           is cleared (Lua tables cannot hold nil).
--   CP.Tablet.result(result)                { type = 'result', result } (RunResult §9.6; nil hides it)
--   CP.Tablet.overlay(o)                    { type = 'overlay', overlay = o } (nil hides it)
--   CP.Tablet.push(topic, data)             { type = 'push', topic, data } for local live updates
--   CP.Tablet.registerClientAction(name, fn(payload) -> ok, data|errKey)
--                                           handlers for the NUI 'client' endpoint (built in: logoFailed,
--                                           forwarded to the server action server:logoFailed)
-- Events handled: crimson-police:client:notify ({ kind, key, vars, title, duration }, translated with
-- CP.L), client:push (topic, data), client:openAdmin (session). The run engine (CP.Runs) forwards
-- client:hud and client:runEnded to CP.Tablet.hud / CP.Tablet.result.
-- NUI callbacks (§9.1): ready, close, request { name, args } -> CP.Net.request, action { name, payload }
-- -> CP.Net.action (names must start with 'server:'), client { name, payload } -> registered client
-- actions, switchUi { ui } -> getSession for that UI; replies { ok = true, data = Session } and re-opens.
-- The UI closes on duty loss, on a switch away from the job it was opened with (or out of every
-- department) and on character unload (the Admin UI only on unload).
-- Crimson-Arena (docs/CRIMSON_ARENA.md rule 8): while the local player carries a foreign crimsonArena
-- value (Crimson-Arena's, not { source = 'crimson-police' }) the command, key mapping, tablet item,
-- OpenTablet, switchUi and client:openAdmin refuse with the toast err.in_arena; when such a value
-- arrives, every Crimson-Police UI closes (prop deleted, animation stopped), the HUD and overlays are
-- hidden and a progress bar of the player's current run is cancelled. NUI focus is only released when
-- a Crimson-Police UI was open, never unconditionally. The tablet prop is a local (non-networked) object.
-- Exports: OpenTablet() (the same checks as /CrimsonPolice), useTablet(data, slot) for ox_inventory.
--
-- ox_inventory item (optional): set Config.Tablet.item = 'crimson_police_tablet' and add to
-- ox_inventory/data/items.lua:
--     ['crimson_police_tablet'] = {
--         label = 'Police Tablet', weight = 500, stack = false, close = true,
--         client = { export = 'Crimson-Police.useTablet' },
--     },
-- Using the item opens the Officer UI with the same server checks as the command.

CP.Tablet = CP.Tablet or {}
local T = CP.Tablet
local TAG = 'tablet'

local UIS = { officer = true, supervisor = true, admin = true }
local KINDS = { info = true, success = true, warning = true, error = true }
local DEFAULT_DURATION = { info = 5000, success = 5000, warning = 7000, error = 7000 }
local DEFAULT_THEME = { primary = '#a4161a', accent = '#e5383b', background = '#0b090a', surface = '#161a1d', text = '#f5f3f4' }
local NULLABLE_HUD = { modifier = true, timer = true, route = true, message = true, detail = true }
local KEY_MAPPING = 'crimsonpolice_tablet'

-- Tablet prop and animation (held in the hand the animation uses; offsets tuned for this clip).
local ANIM_DICT = 'amb@code_human_in_bus_passenger_idles@female@tablet@base'
local ANIM_CLIP = 'base'
local ANIM_FLAG = 49                 -- loop + upper body only + keep player control
local PROP_BONE = 60309
local PROP_POS = { 0.03, 0.002, -0.0 }
local PROP_ROT = { 10.0, 160.0, 0.0 }

local state = {
    open = false,
    ui = nil,
    session = nil,
    jobName = nil,
    opening = false,
    lastToggleAt = -1,
    hud = nil,
    overlay = nil,
    theme = nil,
    prop = nil,
    propToken = 0,
    animLoaded = false,
    notifySeq = 0,
    themeToken = 0,
    commandRegistered = false,
}
local clientActions = {}

-- ── Crimson-Arena ───────────────────────────────────────────────────────────
-- Crimson-Arena writes { active = true, matchId } (no source); ours is { active = true, source = 'crimson-police' }.
local function isForeignArena(v)
    return type(v) == 'table' and v.active == true and v.source ~= 'crimson-police'
end

local function inForeignArena()
    local st = LocalPlayer and LocalPlayer.state
    return isForeignArena(st and st.crimsonArena)
end

-- ── NUI transport ───────────────────────────────────────────────────────────
function T.send(msg)
    if type(msg) ~= 'table' then return end
    SendNUIMessage(CP.U.serialize(msg))
end

function T.notify(kind, text, opts)
    if text == nil then return end
    if not KINDS[kind] then kind = 'info' end
    if type(opts) ~= 'table' then opts = {} end
    state.notifySeq = state.notifySeq + 1
    T.send({
        type = 'notify',
        notification = {
            id = ('lua-%d'):format(state.notifySeq),
            kind = kind,
            title = type(opts.title) == 'string' and opts.title or nil,
            text = tostring(text),
            duration = tonumber(opts.duration) or DEFAULT_DURATION[kind],
        },
    })
end

function T.hud(patch)
    if patch == nil then
        state.hud = nil
        T.send({ type = 'hud' })
        return
    end
    if type(patch) ~= 'table' then return end
    local hud = state.hud or {}
    for k, v in pairs(patch) do
        if v == false and NULLABLE_HUD[k] then hud[k] = nil else hud[k] = v end
    end
    state.hud = hud
    T.send({ type = 'hud', hud = hud })
end

function T.result(result)
    T.send({ type = 'result', result = type(result) == 'table' and result or nil })
end

function T.overlay(o)
    if type(o) ~= 'table' then o = nil end
    state.overlay = o
    T.send({ type = 'overlay', overlay = o })
end

function T.push(topic, data)
    if type(topic) ~= 'string' or topic == '' then return end
    T.send({ type = 'push', topic = topic, data = data })
end

function T.registerClientAction(name, fn)
    if type(name) ~= 'string' or name == '' or type(fn) ~= 'function' then
        CP.warn(TAG, 'registerClientAction needs a name and a function (got %s)', tostring(name))
        return
    end
    if clientActions[name] then CP.warn(TAG, 'client action %s registered twice; the last one wins', name) end
    clientActions[name] = fn
end

function T.isOpen()
    return state.open
end

-- ── prop and animation ──────────────────────────────────────────────────────
local function loadModel(model, timeoutMs)
    if not IsModelInCdimage(model) then return false end
    RequestModel(model)
    local deadline = GetGameTimer() + timeoutMs
    while not HasModelLoaded(model) do
        if GetGameTimer() > deadline then return false end
        Wait(10)
    end
    return true
end

local function loadDict(dict, timeoutMs)
    RequestAnimDict(dict)
    local deadline = GetGameTimer() + timeoutMs
    while not HasAnimDictLoaded(dict) do
        if GetGameTimer() > deadline then return false end
        Wait(10)
    end
    return true
end

local function wantsProp()
    return state.open and state.ui ~= 'admin'
end

local function deleteObject(obj)
    if obj and DoesEntityExist(obj) then
        DetachEntity(obj, true, false)
        SetEntityAsMissionEntity(obj, true, true)
        DeleteEntity(obj)
    end
end

local function deleteProp()
    local obj = state.prop
    state.prop = nil
    deleteObject(obj)
end

local function stopProp()
    state.propToken = state.propToken + 1
    local ped = PlayerPedId()
    if IsEntityPlayingAnim(ped, ANIM_DICT, ANIM_CLIP, 3) then StopAnimTask(ped, ANIM_DICT, ANIM_CLIP, 1.0) end
    deleteProp()
    if state.animLoaded then
        RemoveAnimDict(ANIM_DICT)
        state.animLoaded = false
    end
end

local function createProp(ped)
    local name = Config.Tablet and Config.Tablet.prop
    if type(name) ~= 'string' or name == '' then return nil end
    local model = joaat(name)
    if not loadModel(model, 5000) then
        CP.warn(TAG, 'tablet prop %s could not be loaded', name)
        return nil
    end
    local c = GetEntityCoords(ped)
    -- A local object only (docs/CRIMSON_ARENA.md rule 8): nothing networked is created by this client.
    local obj = CreateObject(model, c.x, c.y, c.z + 0.2, false, false, false)
    SetModelAsNoLongerNeeded(model)
    if not obj or obj == 0 or not DoesEntityExist(obj) then return nil end
    SetEntityCollision(obj, false, false)
    AttachEntityToEntity(obj, ped, GetPedBoneIndex(ped, PROP_BONE),
        PROP_POS[1], PROP_POS[2], PROP_POS[3], PROP_ROT[1], PROP_ROT[2], PROP_ROT[3],
        true, true, false, true, 1, true)
    return obj
end

local function playAnim(ped)
    TaskPlayAnim(ped, ANIM_DICT, ANIM_CLIP, 3.0, 3.0, -1, ANIM_FLAG, 0, false, false, false)
end

local function startProp()
    state.propToken = state.propToken + 1
    local token = state.propToken
    CreateThread(function()
        local ped = PlayerPedId()
        if IsEntityDead(ped) then return end
        if not state.prop then
            local obj = createProp(ped)
            if obj then
                if token ~= state.propToken or not wantsProp() then
                    -- Closed (or reopened by a newer thread) while the model loaded: drop only this
                    -- object, never state.prop, which may already be the newer thread's prop.
                    deleteObject(obj)
                    return
                end
                state.prop = obj
            end
        end
        if loadDict(ANIM_DICT, 5000) then
            state.animLoaded = true
            if token ~= state.propToken or not wantsProp() then return end
            playAnim(ped)
        end
        -- Vehicles, ragdolls and other scripts clear tasks: keep the animation while the UI is open.
        while token == state.propToken and wantsProp() do
            Wait(1000)
            if token ~= state.propToken or not wantsProp() then break end
            local p = PlayerPedId()
            if state.animLoaded and not IsEntityDead(p) and not IsEntityPlayingAnim(p, ANIM_DICT, ANIM_CLIP, 3) then
                playAnim(p)
            end
            if state.prop and not DoesEntityExist(state.prop) then state.prop = nil end
        end
    end)
end

-- ── open / close ────────────────────────────────────────────────────────────
local function showUi(ui, session)
    local wasProp = wantsProp()
    state.ui = ui
    state.session = session
    state.open = true
    local pd = CP.Qbx and CP.Qbx.getPlayerData and CP.Qbx.getPlayerData() or {}
    state.jobName = type(pd.job) == 'table' and pd.job.name or nil
    if CP.Access and CP.Access.setSession then CP.Access.setSession(session) end
    if ui ~= 'admin' and type(session.theme) == 'table' then state.theme = session.theme end
    T.send({ type = 'open', ui = ui, session = session })
    SetNuiFocus(true, true)
    if ui == 'admin' then
        stopProp()
    elseif not wasProp then
        startProp()
    end
    CP.log(TAG, '%s UI opened', ui)
end

local function refuseInArena()
    T.notify('error', CP.L('err.in_arena'))
    return false, 'err.in_arena'
end

function T.open(ui)
    if ui == nil then ui = 'officer' end
    if not UIS[ui] then return false, 'err.invalid_ui' end
    if inForeignArena() then return refuseInArena() end
    if state.opening then return false, 'err.busy' end
    state.opening = true
    local ok, res = pcall(CP.Net.request, 'getSession', { ui = ui })
    state.opening = false
    if not ok then
        CP.err(TAG, 'getSession failed: %s', tostring(res))
        res = { ok = false, error = 'err.internal' }
    end
    if not res.ok or type(res.data) ~= 'table' then
        local errKey = type(res.error) == 'string' and res.error or 'err.no_response'
        T.notify('error', CP.L(errKey))
        return false, errKey
    end
    -- Crimson-Arena may have placed the player while the session was on its way.
    if inForeignArena() then return refuseInArena() end
    showUi(ui, res.data)
    return true
end

function T.close()
    local wasOpen = state.open
    state.open = false
    state.ui = nil
    -- Only our own focus: releasing it unconditionally would take it from another resource's UI
    -- (docs/CRIMSON_ARENA.md rule 8).
    if wasOpen then SetNuiFocus(false, false) end
    stopProp()
    T.send({ type = 'close' })
    if wasOpen then CP.log(TAG, 'UI closed') end
    return wasOpen
end

-- /CrimsonPolice, the key mapping, the item and the export all land here.
local function toggleOfficer()
    local now = GetGameTimer()
    if state.lastToggleAt >= 0 and now - state.lastToggleAt < 500 then return end
    state.lastToggleAt = now
    if state.open then
        T.close()
        return
    end
    T.open('officer')
end

local function requestOpen()
    CreateThread(function()
        if state.open then return end
        T.open('officer')
    end)
end

local function isDepartmentJob(jobName)
    if type(jobName) ~= 'string' or type(Config.Departments) ~= 'table' then return false end
    for _, dept in pairs(Config.Departments) do
        if type(dept) == 'table' then
            local jobs = dept.jobs
            if type(jobs) == 'string' then jobs = { jobs } end
            if type(jobs) == 'table' then
                for _, j in ipairs(jobs) do
                    if j == jobName then return true end
                end
            end
        end
    end
    return false
end

-- ── theme at login ──────────────────────────────────────────────────────────
local function sendTheme()
    T.send({ type = 'theme', theme = state.theme or DEFAULT_THEME, locale = CP.Locale.all() })
end

local function refreshTheme()
    local pd = CP.Qbx and CP.Qbx.getPlayerData() or {}
    if type(pd.job) ~= 'table' or not isDepartmentJob(pd.job.name) then
        state.theme = nil
        if CP.Access and CP.Access.clear then CP.Access.clear() end
        sendTheme()
        return
    end
    local ok, res = pcall(CP.Net.request, 'getSession', { ui = 'officer', silent = true })
    if ok and type(res) == 'table' and res.ok and type(res.data) == 'table' then
        state.theme = type(res.data.theme) == 'table' and res.data.theme or nil
        if CP.Access and CP.Access.setSession then CP.Access.setSession(res.data) end
    else
        state.theme = nil
        if CP.Access and CP.Access.clear then CP.Access.clear() end
    end
    sendTheme()
end

-- Debounced: login, duty and job events come in bursts.
local function scheduleThemeRefresh(delayMs)
    state.themeToken = state.themeToken + 1
    local token = state.themeToken
    CreateThread(function()
        Wait(delayMs or 1500)
        if token ~= state.themeToken then return end
        refreshTheme()
    end)
end

-- ── server events ───────────────────────────────────────────────────────────
RegisterNetEvent(CP.e('client:notify'), function(n)
    if type(n) ~= 'table' or type(n.key) ~= 'string' then return end
    local vars = type(n.vars) == 'table' and n.vars or nil
    local title = type(n.title) == 'string' and n.title ~= '' and CP.L(n.title, vars) or nil
    T.notify(n.kind, CP.L(n.key, vars), { title = title, duration = tonumber(n.duration) })
end)

RegisterNetEvent(CP.e('client:push'), function(topic, data)
    if type(topic) ~= 'string' then return end
    T.push(topic, data)
end)

RegisterNetEvent(CP.e('client:openAdmin'), function(session)
    if type(session) ~= 'table' or session.ui ~= 'admin' then return end
    if inForeignArena() then
        refuseInArena()
        return
    end
    showUi('admin', session)
end)

-- ── NUI callbacks ───────────────────────────────────────────────────────────
local function validName(name)
    return type(name) == 'string' and #name <= 64 and name:match('^[%w_:%-%.]+$') ~= nil
end

local function reply(cb, res)
    if type(res) ~= 'table' then res = { ok = false, error = 'err.no_response' } end
    cb(res)
end

RegisterNUICallback('ready', function(_, cb)
    cb({ ok = true })
    sendTheme()
    if state.hud then T.send({ type = 'hud', hud = state.hud }) end
    if state.overlay then T.send({ type = 'overlay', overlay = state.overlay }) end
    if state.open and state.session then T.send({ type = 'open', ui = state.ui, session = state.session }) end
end)

RegisterNUICallback('close', function(_, cb)
    T.close()
    cb({ ok = true })
end)

RegisterNUICallback('request', function(body, cb)
    if type(body) ~= 'table' or not validName(body.name) then
        return cb({ ok = false, error = 'err.invalid_payload' })
    end
    CreateThread(function()
        local ok, res = pcall(CP.Net.request, body.name, body.args)
        if not ok then
            CP.err(TAG, 'request %s failed: %s', body.name, tostring(res))
            res = { ok = false, error = 'err.internal' }
        end
        reply(cb, res)
    end)
end)

RegisterNUICallback('action', function(body, cb)
    if type(body) ~= 'table' or not validName(body.name) or body.name:sub(1, 7) ~= 'server:' then
        return cb({ ok = false, error = 'err.invalid_payload' })
    end
    CreateThread(function()
        local ok, res = pcall(CP.Net.action, body.name, body.payload)
        if not ok then
            CP.err(TAG, 'action %s failed: %s', body.name, tostring(res))
            res = { ok = false, error = 'err.internal' }
        end
        reply(cb, res)
    end)
end)

RegisterNUICallback('client', function(body, cb)
    if type(body) ~= 'table' or not validName(body.name) then
        return cb({ ok = false, error = 'err.invalid_payload' })
    end
    local fn = clientActions[body.name]
    if not fn then return cb({ ok = false, error = 'err.unknown_action' }) end
    CreateThread(function()
        local okCall, ok, data = pcall(fn, body.payload)
        if not okCall then
            CP.err(TAG, 'client action %s failed: %s', body.name, tostring(ok))
            return cb({ ok = false, error = 'err.internal' })
        end
        if ok then
            cb({ ok = true, data = CP.U.serialize(data) })
        else
            cb({ ok = false, error = type(data) == 'string' and data or 'err.refused' })
        end
    end)
end)

RegisterNUICallback('switchUi', function(body, cb)
    local ui = type(body) == 'table' and body.ui or nil
    if type(ui) ~= 'string' or not UIS[ui] then return cb({ ok = false, error = 'err.invalid_ui' }) end
    if inForeignArena() then return cb({ ok = false, error = 'err.in_arena' }) end
    CreateThread(function()
        local ok, res = pcall(CP.Net.request, 'getSession', { ui = ui })
        if not ok or type(res) ~= 'table' then res = { ok = false, error = 'err.internal' } end
        if not res.ok or type(res.data) ~= 'table' then
            return cb({ ok = false, error = res.error or 'err.no_response' })
        end
        if inForeignArena() then return cb({ ok = false, error = 'err.in_arena' }) end
        if state.open then showUi(ui, res.data) end
        cb({ ok = true, data = res.data })
    end)
end)

-- Built-in client action: the NUI could not load a department logo.
T.registerClientAction('logoFailed', function(payload)
    if payload ~= nil and type(payload) ~= 'table' and type(payload) ~= 'string' then return false, 'err.invalid_payload' end
    local res = CP.Net.action('server:logoFailed', payload)
    if type(res) ~= 'table' then return false, 'err.no_response' end
    if res.ok then return true, res.data end
    return false, res.error
end)

-- ── exports ─────────────────────────────────────────────────────────────────
exports('OpenTablet', function()
    requestOpen()
    return true
end)

exports('useTablet', function(data, slot)
    local item = Config.Tablet and Config.Tablet.item
    if not item then return end
    if type(data) == 'table' and type(data.name) == 'string' and data.name ~= item then return end
    requestOpen()
end)

-- ── wiring (at runtime, once every module is loaded) ───────────────────────
local function registerCommand()
    if state.commandRegistered then return end
    state.commandRegistered = true
    local cmd = Config.Tablet and Config.Tablet.command
    if type(cmd) ~= 'string' or cmd == '' then cmd = 'CrimsonPolice' end
    RegisterCommand(cmd, function() CreateThread(toggleOfficer) end, false)
    RegisterCommand(KEY_MAPPING, function() CreateThread(toggleOfficer) end, false)
    local key = Config.Tablet and Config.Tablet.keybind
    if type(key) ~= 'string' then key = '' end
    RegisterKeyMapping(KEY_MAPPING, CP.L('tablet.keybind_label'), 'keyboard', key)
end

-- Crimson-Arena placed the local player (fighter or spectator): nothing of Crimson-Police stays on
-- screen or holds focus (docs/CRIMSON_ARENA.md rule 8).
local function onArenaPlaced()
    CP.log(TAG, 'Crimson-Arena placed the player: Crimson-Police UI, HUD and overlays hidden')
    if state.open then T.close() else stopProp() end
    if state.hud then T.hud(nil) end
    if state.overlay then T.overlay(nil) end
    -- A progress bar during a Crimson-Police run is a mission step (lib.cancelProgress raises when none runs).
    local run = CP.Runs and CP.Runs.current and CP.Runs.current()
    if run and lib and lib.progressActive and lib.cancelProgress then
        local ok, active = pcall(lib.progressActive)
        if ok and active then pcall(lib.cancelProgress) end
    end
end

local function watchArena()
    local bag = ('player:%d'):format(GetPlayerServerId(PlayerId()))
    AddStateBagChangeHandler('crimsonArena', bag, function(_, _, value)
        -- The handler only queues work: the bag still holds the old value while it runs.
        if isForeignArena(value) then SetTimeout(0, onArenaPlaced) end
    end)
end

CreateThread(function()
    registerCommand()
    watchArena()
    if not CP.Qbx then
        CP.err(TAG, 'modules/integrations/qbx is missing: the tablet cannot follow duty or job changes')
        return
    end
    CP.Qbx.onLoaded(function() scheduleThemeRefresh(1500) end)
    CP.Qbx.onUnload(function()
        T.close()
        T.hud(nil)
        T.overlay(nil)
        state.theme = nil
        if CP.Access and CP.Access.clear then CP.Access.clear() end
        sendTheme()
    end)
    CP.Qbx.onDutyChange(function(onDuty)
        if not onDuty and state.open and state.ui ~= 'admin' then T.close() end
        scheduleThemeRefresh(1500)
    end)
    CP.Qbx.onJobUpdate(function(job)
        if state.open and state.ui ~= 'admin' then
            local name = type(job) == 'table' and job.name or nil
            if name ~= state.jobName or not isDepartmentJob(name) or (type(job) == 'table' and job.onduty == false) then
                T.close()
            end
        end
        scheduleThemeRefresh(1500)
    end)
    -- Resource (re)started while a character is already loaded.
    local pd = CP.Qbx.getPlayerData()
    if type(pd.job) == 'table' then scheduleThemeRefresh(2000) end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= CP.resource then return end
    if state.open then SetNuiFocus(false, false) end
    stopProp()
end)

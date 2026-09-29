-- CP.Tablet (client): the NUI. The only file that calls SendNUIMessage.

CP.Tablet = CP.Tablet or {}
local T = CP.Tablet
local TAG = 'tablet'

local UIS = { officer = true, supervisor = true, admin = true }
local KINDS = { info = true, success = true, warning = true, error = true }
local DEFAULT_DURATION = { info = 5000, success = 5000, warning = 7000, error = 7000 }
local DEFAULT_THEME = {
    primary = '#a4161a',
    accent = '#e5383b',
    background = '#0b090a',
    surface = '#161a1d',
    text = '#f5f3f4',
}
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
    panelOwner = nil,     -- CP.Tablet.panelFocus owner holding the NUI focus while no tablet UI is open
    arenaHidden = false,  -- a HUD/overlay was kept off screen while the crimsonArena value was foreign
}
local clientActions = {}

-- ============================================================================
--                                CRIMSON-ARENA
-- ============================================================================
-- Crimson-Arena writes { active = true, matchId } (no source); ours is { active = true, source = 'crimson-police' }.
local function IsForeignArena(v)
    return type(v) == 'table' and v.active == true and v.source ~= 'crimson-police'
end

local function InForeignArena()
    local st = LocalPlayer and LocalPlayer.state
    return IsForeignArena(st and st.crimsonArena)
end

-- ============================================================================
--                         CRIMSON-POLICE PROGRESS BARS
-- ============================================================================
-- ox_lib's `lib` table is private to this resource's Lua state, so every lib.progressBar /
-- lib.progressCircle call that goes through it is one of ours (blocks, npc cuff). They are wrapped once
-- to count the bars in flight; lib.progressActive() alone is resource-wide and also true for another
-- resource's bar, which Crimson-Police must never cancel (CRIMSON_ARENA rule 8).
local cpProgress = 0
local wrappedProgress = setmetatable({}, { __mode = 'k' })

local function WrapProgress(name)
    if type(lib) ~= 'table' then return end
    local ok, orig = pcall(function() return lib[name] end)
    if not ok or type(orig) ~= 'function' or wrappedProgress[orig] then return end
    local function wrapper(...)
        cpProgress = cpProgress + 1
        local res = table.pack(pcall(orig, ...))
        cpProgress = math.max(0, cpProgress - 1)
        if not res[1] then error(res[2], 0) end
        return table.unpack(res, 2, res.n)
    end
    wrappedProgress[wrapper] = true
    lib[name] = wrapper
end

function T.wrapProgress()
    WrapProgress('progressBar')
    WrapProgress('progressCircle')
end

-- true while a progress bar started by Crimson-Police runs
function T.cpProgressActive()
    return cpProgress > 0
end

T.wrapProgress()

-- ============================================================================
--                                NUI TRANSPORT
-- ============================================================================

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
    -- CRIMSON_ARENA rule 8: nothing of Crimson-Police on screen while Crimson-Arena owns the player.
    if InForeignArena() then
        state.arenaHidden = true
        return
    end
    T.send({ type = 'hud', hud = hud })
end

function T.result(result)
    T.send({ type = 'result', result = type(result) == 'table' and result or nil })
end

function T.overlay(o)
    if type(o) ~= 'table' then o = nil end
    state.overlay = o
    if o and InForeignArena() then
        state.arenaHidden = true
        return
    end
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

-- ============================================================================
--                                 PANEL FOCUS
-- ============================================================================
-- A HUD panel that is not the tablet, e.g. the test controls.

function T.panelFocus(owner, on)
    if type(owner) ~= 'string' or owner == '' then return false end
    if on then
        if state.panelOwner == owner then return true end
        if state.panelOwner ~= nil or state.open or state.opening or InForeignArena() then return false end
        state.panelOwner = owner
        SetNuiFocus(true, true)
        CP.log(TAG, 'NUI focus taken for the %s panel', owner)
        return true
    end
    if state.panelOwner ~= owner then return false end
    state.panelOwner = nil
    -- An open tablet UI owns the focus now: never take it from it.
    if not state.open then SetNuiFocus(false, false) end
    CP.log(TAG, 'NUI focus of the %s panel released', owner)
    return true
end

function T.panelFocusOwner()
    return state.panelOwner
end

-- Drops the panel focus whoever holds it (arena placement, unload, resource stop).
local function ReleasePanelFocus()
    local owner = state.panelOwner
    if owner == nil then return false end
    return T.panelFocus(owner, false)
end

-- ============================================================================
--                              PROP AND ANIMATION
-- ============================================================================

local function LoadModel(model, timeoutMs)
    if not IsModelInCdimage(model) then return false end
    RequestModel(model)
    local deadline = GetGameTimer() + timeoutMs
    while not HasModelLoaded(model) do
        if GetGameTimer() > deadline then return false end
        Wait(10)
    end
    return true
end

local function LoadDict(dict, timeoutMs)
    RequestAnimDict(dict)
    local deadline = GetGameTimer() + timeoutMs
    while not HasAnimDictLoaded(dict) do
        if GetGameTimer() > deadline then return false end
        Wait(10)
    end
    return true
end

local function WantsProp()
    return state.open and state.ui ~= 'admin'
end

local function DeleteObject(obj)
    if obj and DoesEntityExist(obj) then
        DetachEntity(obj, true, false)
        SetEntityAsMissionEntity(obj, true, true)
        DeleteEntity(obj)
    end
end

local function DeleteProp()
    local obj = state.prop
    state.prop = nil
    DeleteObject(obj)
end

local function StopProp()
    state.propToken = state.propToken + 1
    local ped = PlayerPedId()
    if IsEntityPlayingAnim(ped, ANIM_DICT, ANIM_CLIP, 3) then StopAnimTask(ped, ANIM_DICT, ANIM_CLIP, 1.0) end
    DeleteProp()
    if state.animLoaded then
        RemoveAnimDict(ANIM_DICT)
        state.animLoaded = false
    end
end

local function CreateProp(ped)
    local name = Config.Tablet and Config.Tablet.prop
    if type(name) ~= 'string' or name == '' then return nil end
    local model = joaat(name)
    if not LoadModel(model, 5000) then
        CP.warn(TAG, 'tablet prop %s could not be loaded', name)
        return nil
    end
    local c = GetEntityCoords(ped)
    -- A local object only (docs/CRIMSON_ARENA.md rule 8): nothing networked is created by this client.
    local obj = CreateObject(model, c.x, c.y, c.z + 0.2, false, false, false)
    SetModelAsNoLongerNeeded(model)
    if not obj or obj == 0 or not DoesEntityExist(obj) then return nil end
    SetEntityCollision(obj, false, false)
    AttachEntityToEntity(obj, ped, GetPedBoneIndex(ped, PROP_BONE), PROP_POS[1], PROP_POS[2], PROP_POS[3], PROP_ROT[1],
        PROP_ROT[2], PROP_ROT[3], true, true, false, true, 1, true)
    return obj
end

local function PlayAnim(ped)
    TaskPlayAnim(ped, ANIM_DICT, ANIM_CLIP, 3.0, 3.0, -1, ANIM_FLAG, 0, false, false, false)
end

local function StartProp()
    state.propToken = state.propToken + 1
    local token = state.propToken
    CreateThread(function()
        local ped = PlayerPedId()
        if IsEntityDead(ped) then return end
        if not state.prop then
            local obj = CreateProp(ped)
            if obj then
                if token ~= state.propToken or not WantsProp() then
                    -- Closed (or reopened by a newer thread) while the model loaded: drop only this
                    -- object, never state.prop, which may already be the newer thread's prop.
                    DeleteObject(obj)
                    return
                end
                state.prop = obj
            end
        end
        if LoadDict(ANIM_DICT, 5000) then
            state.animLoaded = true
            if token ~= state.propToken or not WantsProp() then return end
            PlayAnim(ped)
        end
        -- Vehicles, ragdolls and other scripts clear tasks: keep the animation while the UI is open.
        while token == state.propToken and WantsProp() do
            Wait(1000)
            if token ~= state.propToken or not WantsProp() then break end
            local p = PlayerPedId()
            if state.animLoaded and not IsEntityDead(p) and not IsEntityPlayingAnim(p, ANIM_DICT, ANIM_CLIP, 3) then
                PlayAnim(p)
            end
            if state.prop and not DoesEntityExist(state.prop) then state.prop = nil end
        end
    end)
end

-- ============================================================================
--                                 OPEN / CLOSE
-- ============================================================================

local function ShowUi(ui, session)
    local wasProp = WantsProp()
    state.ui = ui
    state.session = session
    state.open = true
    local pd = CP.Qbx and CP.Qbx.getPlayerData and CP.Qbx.getPlayerData() or {}
    state.jobName = type(pd.job) == 'table' and pd.job.name or nil
    if CP.Access and CP.Access.setSession then CP.Access.setSession(session) end
    if ui ~= 'admin' and type(session.theme) == 'table' then state.theme = session.theme end
    T.send({ type = 'open', ui = ui, session = session })
    -- The tablet takes the NUI focus over from a panel (CP.Tablet.panelFocus); closing it releases it.
    state.panelOwner = nil
    SetNuiFocus(true, true)
    if ui == 'admin' then
        StopProp()
    elseif not wasProp then
        StartProp()
    end
    CP.log(TAG, '%s UI opened', ui)
end

local function RefuseInArena()
    T.notify('error', CP.L('err.in_arena'))
    return false, 'err.in_arena'
end

function T.open(ui)
    if ui == nil then ui = 'officer' end
    if not UIS[ui] then return false, 'err.invalid_ui' end
    if InForeignArena() then return RefuseInArena() end
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
    if InForeignArena() then return RefuseInArena() end
    ShowUi(ui, res.data)
    return true
end

function T.close()
    local wasOpen = state.open
    state.open = false
    state.ui = nil
    -- Only our own focus: releasing it unconditionally would take it from another resource's UI
    -- (docs/CRIMSON_ARENA.md rule 8).
    if wasOpen then SetNuiFocus(false, false) end
    StopProp()
    T.send({ type = 'close' })
    if wasOpen then CP.log(TAG, 'UI closed') end
    return wasOpen
end

-- /CrimsonPolice, the key mapping, the item and the export all land here.
local function ToggleOfficer()
    local now = GetGameTimer()
    if state.lastToggleAt >= 0 and now - state.lastToggleAt < 500 then return end
    state.lastToggleAt = now
    if state.open then
        T.close()
        return
    end
    T.open('officer')
end

local function RequestOpen()
    CreateThread(function()
        if state.open then return end
        T.open('officer')
    end)
end

local function IsDepartmentJob(jobName)
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

-- ============================================================================
--                                THEME AT LOGIN
-- ============================================================================

local function SendTheme()
    T.send({ type = 'theme', theme = state.theme or DEFAULT_THEME, locale = CP.Locale.all() })
end

local function RefreshTheme()
    local pd = CP.Qbx and CP.Qbx.getPlayerData() or {}
    if type(pd.job) ~= 'table' or not IsDepartmentJob(pd.job.name) then
        state.theme = nil
        if CP.Access and CP.Access.clear then CP.Access.clear() end
        SendTheme()
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
    SendTheme()
end

-- Debounced: login, duty and job events come in bursts.
local function ScheduleThemeRefresh(delayMs)
    state.themeToken = state.themeToken + 1
    local token = state.themeToken
    CreateThread(function()
        Wait(delayMs or 1500)
        if token ~= state.themeToken then return end
        RefreshTheme()
    end)
end

-- ============================================================================
--                                SERVER EVENTS
-- ============================================================================

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
    if InForeignArena() then
        RefuseInArena()
        return
    end
    ShowUi('admin', session)
end)

-- ============================================================================
--                                NUI CALLBACKS
-- ============================================================================

local function ValidName(name)
    return type(name) == 'string' and #name <= 64 and name:match('^[%w_:%-%.]+$') ~= nil
end

local function Reply(cb, res)
    if type(res) ~= 'table' then res = { ok = false, error = 'err.no_response' } end
    cb(res)
end

RegisterNUICallback('ready', function(_, cb)
    cb({ ok = true })
    SendTheme()
    if (state.hud or state.overlay) and InForeignArena() then
        state.arenaHidden = true
    else
        if state.hud then T.send({ type = 'hud', hud = state.hud }) end
        if state.overlay then T.send({ type = 'overlay', overlay = state.overlay }) end
    end
    if state.open and state.session then T.send({ type = 'open', ui = state.ui, session = state.session }) end
end)

RegisterNUICallback('close', function(_, cb)
    T.close()
    cb({ ok = true })
end)

RegisterNUICallback('request', function(body, cb)
    if type(body) ~= 'table' or not ValidName(body.name) then
        return cb({ ok = false, error = 'err.invalid_payload' })
    end
    CreateThread(function()
        local ok, res = pcall(CP.Net.request, body.name, body.args)
        if not ok then
            CP.err(TAG, 'request %s failed: %s', body.name, tostring(res))
            res = { ok = false, error = 'err.internal' }
        end
        Reply(cb, res)
    end)
end)

RegisterNUICallback('action', function(body, cb)
    if type(body) ~= 'table' or not ValidName(body.name) or body.name:sub(1, 7) ~= 'server:' then
        return cb({ ok = false, error = 'err.invalid_payload' })
    end
    CreateThread(function()
        local ok, res = pcall(CP.Net.action, body.name, body.payload)
        if not ok then
            CP.err(TAG, 'action %s failed: %s', body.name, tostring(res))
            res = { ok = false, error = 'err.internal' }
        end
        Reply(cb, res)
    end)
end)

RegisterNUICallback('client', function(body, cb)
    if type(body) ~= 'table' or not ValidName(body.name) then
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
    if InForeignArena() then return cb({ ok = false, error = 'err.in_arena' }) end
    CreateThread(function()
        local ok, res = pcall(CP.Net.request, 'getSession', { ui = ui })
        if not ok or type(res) ~= 'table' then res = { ok = false, error = 'err.internal' } end
        if not res.ok or type(res.data) ~= 'table' then
            return cb({ ok = false, error = res.error or 'err.no_response' })
        end
        if InForeignArena() then return cb({ ok = false, error = 'err.in_arena' }) end
        if state.open then ShowUi(ui, res.data) end
        cb({ ok = true, data = res.data })
    end)
end)

-- Built-in client action: the NUI could not load a department logo.
T.registerClientAction('logoFailed', function(payload)
    if payload ~= nil and type(payload) ~= 'table' and type(payload) ~= 'string' then
        return false, 'err.invalid_payload'
    end
    local res = CP.Net.action('server:logoFailed', payload)
    if type(res) ~= 'table' then return false, 'err.no_response' end
    if res.ok then return true, res.data end
    return false, res.error
end)

-- ============================================================================
--                                   EXPORTS
-- ============================================================================

exports('OpenTablet', function()
    RequestOpen()
    return true
end)

exports('useTablet', function(data, slot)
    local item = Config.Tablet and Config.Tablet.item
    if not item then return end
    if type(data) == 'table' and type(data.name) == 'string' and data.name ~= item then return end
    RequestOpen()
end)

-- ============================================================================
--               WIRING (at runtime, once every module is loaded)
-- ============================================================================

local function registerCommand()
    if state.commandRegistered then return end
    state.commandRegistered = true
    local cmd = Config.Tablet and Config.Tablet.command
    if type(cmd) ~= 'string' or cmd == '' then cmd = 'CrimsonPolice' end
    RegisterCommand(cmd, function() CreateThread(ToggleOfficer) end, false)
    RegisterCommand(KEY_MAPPING, function() CreateThread(ToggleOfficer) end, false)
    local key = Config.Tablet and Config.Tablet.keybind
    if type(key) ~= 'string' then key = '' end
    RegisterKeyMapping(KEY_MAPPING, CP.L('tablet.keybind_label'), 'keyboard', key)
end

-- Crimson-Arena placed the local player (fighter or spectator): nothing of Crimson-Police stays on
-- screen or holds focus (docs/CRIMSON_ARENA.md rule 8).
local function OnArenaPlaced()
    CP.log(TAG, 'Crimson-Arena placed the player: Crimson-Police UI, HUD and overlays hidden')
    ReleasePanelFocus()
    if state.open then T.close() else StopProp() end
    -- Hidden on the NUI, the state is kept: the run engine keeps patching it (e.g. its ended HUD after the
    -- arena removal), and what is still set when Crimson-Arena lets the player go is shown again.
    if state.hud then
        state.arenaHidden = true
        T.send({ type = 'hud' })
    end
    if state.overlay then
        state.arenaHidden = true
        T.send({ type = 'overlay' })
    end
    -- Only a Crimson-Police progress bar is cancelled, never another resource's (lib.cancelProgress raises
    -- when none runs).
    if T.cpProgressActive() and lib and lib.progressActive and lib.cancelProgress then
        local ok, active = pcall(lib.progressActive)
        if ok and active then pcall(lib.cancelProgress) end
    end
end

-- Crimson-Arena let the player go: show what was kept off screen meanwhile (a HUD or overlay that is
-- still set; the run engine hides its ended HUD itself after a few seconds).
local function OnArenaLeft()
    if not state.arenaHidden or InForeignArena() then return end
    state.arenaHidden = false
    if state.hud then T.send({ type = 'hud', hud = state.hud }) end
    if state.overlay then T.send({ type = 'overlay', overlay = state.overlay }) end
end

local function WatchArena()
    local bag = ('player:%d'):format(GetPlayerServerId(PlayerId()))
    AddStateBagChangeHandler('crimsonArena', bag, function(_, _, value)
        -- The handler only queues work: the bag still holds the old value while it runs.
        if IsForeignArena(value) then
            SetTimeout(0, OnArenaPlaced)
        elseif state.arenaHidden then
            SetTimeout(0, OnArenaLeft)
        end
    end)
end

CreateThread(function()
    T.wrapProgress()   -- again at runtime, in case ox_lib resolved lib.progressBar only now
    registerCommand()
    WatchArena()
    if not CP.Qbx then
        CP.err(TAG, 'modules/integrations/qbx is missing: the tablet cannot follow duty or job changes')
        return
    end
    CP.Qbx.onLoaded(function() ScheduleThemeRefresh(1500) end)
    CP.Qbx.onUnload(function()
        T.close()
        ReleasePanelFocus()
        T.hud(nil)
        T.overlay(nil)
        state.theme = nil
        if CP.Access and CP.Access.clear then CP.Access.clear() end
        SendTheme()
    end)
    CP.Qbx.onDutyChange(function(onDuty)
        if not onDuty and state.open and state.ui ~= 'admin' then T.close() end
        ScheduleThemeRefresh(1500)
    end)
    CP.Qbx.onJobUpdate(function(job)
        if state.open and state.ui ~= 'admin' then
            local name = type(job) == 'table' and job.name or nil
            if name ~= state.jobName or not IsDepartmentJob(name) or (type(job) == 'table' and job.onduty == false) then
                T.close()
            end
        end
        ScheduleThemeRefresh(1500)
    end)
    -- Resource (re)started while a character is already loaded.
    local pd = CP.Qbx.getPlayerData()
    if type(pd.job) == 'table' then ScheduleThemeRefresh(2000) end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= CP.resource then return end
    if state.open or state.panelOwner then SetNuiFocus(false, false) end
    state.panelOwner = nil
    StopProp()
end)

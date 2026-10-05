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
local DISPATCH_MAPPING = 'crimsonpolice_dispatch'
local DESK_OPTION = 'crimson-police:desk'
local DESK_TARGET_DISTANCE = 2.0     -- metres: how close ox_target offers "Open Crimson-Police" at a desk
local DESK_WATCH_MS = 500            -- how often the desk distance is checked while the tablet is open there
local ITEM_WATCH_MS = 1000           -- how often the tablet item is looked for while requireItem is on
local DOWN_WATCH_MS = 500            -- how often a downed officer is looked for while the tablet is open
local OPEN_ACK_MS = 6000             -- the NUI confirms it shows the UI within this, or the focus is released
local SETTINGS_WAIT_MS = 10000       -- the start waits this long at most for the settings changed in game

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
    via = nil,            -- how the open tablet was opened (command, keybind, item, export, desk, dispatch)
    desk = nil,           -- the desk index while it was opened at a desk
    openToken = 0,        -- bumped on every open and close: the desk and item watchers stop with it
    deskZones = nil,      -- ox_target zone ids of the mission desks, while they exist
    deskProps = {},       -- local laptop objects of the desks
    openSeq = 0,          -- bumped on every 'open' sent to the NUI
    ackSeq = 0,           -- the last 'open' the NUI confirmed it shows ('opened')
    nuiAcks = false,      -- the NUI said at 'ready' that it confirms every 'open'
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

-- Dead or in last stand (qbx metadata, or a dead ped). The owner's own rule for sc-dispatch's bill: never hold the
-- NUI focus while the death or last stand screen is up, or the player is left stuck.
local function PlayerDown()
    local pd = CP.Qbx and CP.Qbx.getPlayerData and CP.Qbx.getPlayerData() or {}
    local md = type(pd) == 'table' and pd.metadata or nil
    if type(md) == 'table' and (md.isdead == true or md.inlaststand == true) then return true end
    return IsEntityDead(PlayerPedId()) == true
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
    -- CRIMSON_ARENA rule 8: dropped, not kept for later: the card is a 25 s notice, the run stays in the history.
    if InForeignArena() then return end
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
    return state.open and state.ui ~= 'admin' and state.via ~= 'desk'
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

local StartWatchers, StopDeskPose, WatchAck

-- opts (optional): { via, desk, screen } how it was opened and the screen to show first.
local function ShowUi(ui, session, opts)
    local wasProp = WantsProp()
    local wasOpen = state.open
    opts = type(opts) == 'table' and opts or {}
    state.ui = ui
    state.session = session
    state.open = true
    if not wasOpen or opts.via then
        local access = type(session.access) == 'table' and session.access or {}
        state.via = opts.via or access.via
        state.desk = state.via == 'desk' and (opts.desk or access.desk) or nil
        if state.desk and T._deskOpened then T._deskOpened(state.desk) end
    end
    local pd = CP.Qbx and CP.Qbx.getPlayerData and CP.Qbx.getPlayerData() or {}
    state.jobName = type(pd.job) == 'table' and pd.job.name or nil
    if CP.Access and CP.Access.setSession then CP.Access.setSession(session) end
    if ui ~= 'admin' and type(session.theme) == 'table' then state.theme = session.theme end
    state.openSeq = state.openSeq + 1
    T.send({ type = 'open', ui = ui, session = session, screen = opts.screen, seq = state.openSeq })
    -- The tablet takes the NUI focus over from a panel (CP.Tablet.panelFocus); closing it releases it.
    state.panelOwner = nil
    SetNuiFocus(true, true)
    WatchAck(state.openSeq)
    if ui == 'admin' or state.via == 'desk' then
        StopProp()
    elseif not wasProp then
        StartProp()
    end
    if not wasOpen then StartWatchers() end
    CP.log(TAG, '%s UI opened (%s)', ui, tostring(state.via))
end

local function RefuseInArena()
    T.notify('error', CP.L('err.in_arena'))
    return false, 'err.in_arena'
end

local function RefuseDown()
    T.notify('error', CP.L('err.downed'))
    return false, 'err.downed'
end

-- opts (optional): { via, desk, screen }; via defaults to 'export' (another module or resource opening it).
function T.open(ui, opts)
    if ui == nil then ui = 'officer' end
    if not UIS[ui] then return false, 'err.invalid_ui' end
    opts = type(opts) == 'table' and opts or {}
    local via = type(opts.via) == 'string' and opts.via or 'export'
    if InForeignArena() then return RefuseInArena() end
    if ui ~= 'admin' and PlayerDown() then return RefuseDown() end
    if state.opening then return false, 'err.busy' end
    state.opening = true
    local ok, res = pcall(CP.Net.request, 'getSession', { ui = ui, via = via, desk = opts.desk })
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
    -- Crimson-Arena may have placed the player (or they went down) while the session was on its way.
    if InForeignArena() then return RefuseInArena() end
    if ui ~= 'admin' and PlayerDown() then return RefuseDown() end
    ShowUi(ui, res.data, { via = via, desk = opts.desk, screen = opts.screen })
    return true
end

function T.close()
    local wasOpen = state.open
    state.open = false
    state.ui = nil
    state.openToken = state.openToken + 1
    if wasOpen and state.via == 'desk' then StopDeskPose() end
    state.via, state.desk = nil, nil
    -- Only our own focus: releasing it unconditionally would take it from another resource's UI
    -- (docs/CRIMSON_ARENA.md rule 8).
    if wasOpen then SetNuiFocus(false, false) end
    StopProp()
    T.send({ type = 'close' })
    if wasOpen then CP.log(TAG, 'UI closed') end
    return wasOpen
end

-- /CrimsonPolice and the key mapping land here (via = 'command' or 'keybind').
local function ToggleOfficer(via)
    local now = GetGameTimer()
    if state.lastToggleAt >= 0 and now - state.lastToggleAt < 500 then return end
    state.lastToggleAt = now
    if state.open then
        T.close()
        return
    end
    T.open('officer', { via = via })
end

-- The item, the export and a desk (via = 'item', 'export' or 'desk').
local function RequestOpen(via, desk)
    CreateThread(function()
        if state.open then return end
        T.open('officer', { via = via, desk = desk })
    end)
end

-- The crimsonpolice_dispatch key mapping: the Officer UI on Dispatch (an open Officer UI just switches to it).
local function OpenDispatch()
    if state.open then
        if state.ui == 'officer' and state.session then
            T.send({ type = 'open', ui = 'officer', session = state.session, screen = 'dispatch' })
        end
        return
    end
    T.open('officer', { via = 'dispatch', screen = 'dispatch' })
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

-- Names an admin gave in Settings → Names (Config.Labels) are part of the text: when they change, the NUI gets the
-- whole locale again so an open tablet shows them at once.
local function LabelsSignature()
    local labels = type(Config.Labels) == 'table' and Config.Labels or {}
    local keys = {}
    for k, v in pairs(labels) do
        if type(k) == 'string' and type(v) == 'string' then keys[#keys + 1] = k .. '=' .. v end
    end
    table.sort(keys)
    return table.concat(keys, '\n')
end
local labelsSeen = LabelsSignature()

CP.Hooks.on('settings:changed', function()
    local sig = LabelsSignature()
    if sig == labelsSeen then return end
    labelsSeen = sig
    T.send({ type = 'locale', locale = CP.Locale.all() })
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

RegisterNUICallback('ready', function(body, cb)
    cb({ ok = true })
    state.nuiAcks = type(body) == 'table' and body.acks == true
    SendTheme()
    if (state.hud or state.overlay) and InForeignArena() then
        state.arenaHidden = true
    else
        if state.hud then T.send({ type = 'hud', hud = state.hud }) end
        if state.overlay then T.send({ type = 'overlay', overlay = state.overlay }) end
    end
    if state.open and state.session then
        state.openSeq = state.openSeq + 1
        T.send({ type = 'open', ui = state.ui, session = state.session, seq = state.openSeq })
        WatchAck(state.openSeq)
    end
end)

-- The NUI shows the UI of that 'open' (it rendered without an error).
RegisterNUICallback('opened', function(body, cb)
    cb({ ok = true })
    local seq = type(body) == 'table' and math.tointeger(tonumber(body.seq) or -1) or nil
    if seq and seq > state.ackSeq and seq <= state.openSeq then state.ackSeq = seq end
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
        -- Closed meanwhile (Escape, duty or job): an ok reply would make the NUI draw the UI without focus.
        if not state.open then return cb({ ok = false, error = 'err.tablet_closed' }) end
        ShowUi(ui, res.data)
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
    RequestOpen('export')
    return true
end)

exports('useTablet', function(data, slot)
    local item = Config.Tablet and Config.Tablet.item
    if not item then return end
    if type(data) == 'table' and type(data.name) == 'string' and data.name ~= item then return end
    RequestOpen('item')
end)

-- ============================================================================
--               WIRING (at runtime, once every module is loaded)
-- ============================================================================

local function registerCommand()
    if state.commandRegistered then return end
    state.commandRegistered = true
    local cmd = Config.Tablet and Config.Tablet.command
    if type(cmd) ~= 'string' or cmd == '' then cmd = 'CrimsonPolice' end
    RegisterCommand(cmd, function() CreateThread(function() ToggleOfficer('command') end) end, false)
    RegisterCommand(KEY_MAPPING, function() CreateThread(function() ToggleOfficer('keybind') end) end, false)
    local key = Config.Tablet and Config.Tablet.keybind
    if type(key) ~= 'string' then key = '' end
    RegisterKeyMapping(KEY_MAPPING, CP.L('tablet.keybind_label'), 'keyboard', key)
    RegisterCommand(DISPATCH_MAPPING, function() CreateThread(OpenDispatch) end, false)
    local dispatchKey = Config.Tablet and Config.Tablet.dispatchKey
    if type(dispatchKey) ~= 'string' then dispatchKey = '' end
    RegisterKeyMapping(DISPATCH_MAPPING, CP.L('tablet.dispatch_key_label'), 'keyboard', dispatchKey)
end

-- Crimson-Arena placed the local player (fighter or spectator): nothing of Crimson-Police stays on
-- screen or holds focus (docs/CRIMSON_ARENA.md rule 8).
local RemoveDeskZones, CreateDeskZones

local function OnArenaPlaced()
    CP.log(TAG, 'Crimson-Arena placed the player: Crimson-Police UI, HUD and overlays hidden')
    RemoveDeskZones()
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
    -- A result card of a run that just ended may still be on screen (the NUI hides it after 25 s).
    T.send({ type = 'result' })
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
    if InForeignArena() then return end
    CreateDeskZones()
    if not state.arenaHidden then return end
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
        elseif state.arenaHidden or not state.deskZones then
            SetTimeout(0, OnArenaLeft)
        end
    end)
end

-- ============================================================================
--                                MISSION DESKS
-- ============================================================================
-- SPEC Tablet access: ox_target boxes from Config.Tablet.desks. canInteract only decides what is shown; the
-- server checks the box (server coordinates), the department and the arena again when the session is asked for.

local function DeskDepartment()
    local pd = CP.Qbx and CP.Qbx.getPlayerData and CP.Qbx.getPlayerData() or {}
    local job = type(pd.job) == 'table' and pd.job or nil
    if not job or job.onduty == false or type(Config.Departments) ~= 'table' then return nil end
    for key, dept in pairs(Config.Departments) do
        local jobs = type(dept) == 'table' and dept.jobs or nil
        if type(jobs) == 'string' then jobs = { jobs } end
        for _, j in ipairs(type(jobs) == 'table' and jobs or {}) do
            if j == job.name then return key end
        end
    end
    return nil
end

local function DeskAllows(desk, deptKey)
    if not deptKey then return false end
    if type(desk.departments) ~= 'table' or next(desk.departments) == nil then return true end
    for _, k in ipairs(desk.departments) do
        if k == deptKey then return true end
    end
    return false
end

local function DeskList()
    local t = Config.Tablet or {}
    if type(t.access) == 'table' and t.access.desk == false then return {} end
    return type(t.desks) == 'table' and t.desks or {}
end

local function TargetUp()
    return GetResourceState('ox_target') == 'started'
end

local function SpawnDeskProp(desk)
    if type(desk.prop) ~= 'string' or desk.prop == '' then return nil end
    local model = joaat(desk.prop)
    if not LoadModel(model, 5000) then
        CP.warn(TAG, 'desk prop %s could not be loaded', desk.prop)
        return nil
    end
    local c = desk.coords
    -- a local object: only this client sees it (docs/CRIMSON_ARENA.md rule 8)
    local obj = CreateObject(model, c.x, c.y, c.z, false, false, false)
    SetModelAsNoLongerNeeded(model)
    if not obj or obj == 0 then return nil end
    SetEntityHeading(obj, (tonumber(desk.rotation) or 0.0) + 0.0)
    FreezeEntityPosition(obj, true)
    return obj
end

-- Created once; again only after RemoveDeskZones (resource stop, a foreign arena flag).
CreateDeskZones = function()
    if state.deskZones or InForeignArena() or not TargetUp() then return false end
    local desks = DeskList()
    if #desks == 0 then return false end
    local ids = {}
    for i, desk in ipairs(desks) do
        if type(desk) == 'table' and desk.coords then
            local index = i
            local ok, id = pcall(function()
                return exports.ox_target:addBoxZone({
                    coords = desk.coords,
                    size = desk.size or vec3(1.0, 1.0, 1.0),
                    rotation = tonumber(desk.rotation) or 0.0,
                    debug = Config.Debug == true,
                    options = {
                        {
                            name = DESK_OPTION,
                            label = CP.L('tablet.desk.open'),
                            icon = 'fa-solid fa-laptop',
                            distance = DESK_TARGET_DISTANCE,
                            canInteract = function()
                                return not state.open and not InForeignArena() and DeskAllows(desk, DeskDepartment())
                            end,
                            onSelect = function() RequestOpen('desk', index) end,
                        },
                    },
                })
            end)
            if ok and id then
                ids[#ids + 1] = id
                local obj = SpawnDeskProp(desk)
                if obj then state.deskProps[#state.deskProps + 1] = obj end
            else
                CP.warn(TAG, 'desk %d (%s): ox_target addBoxZone failed: %s', i, tostring(desk.label), tostring(id))
            end
        end
    end
    state.deskZones = ids
    CP.log(TAG, '%d mission desk zones created', #ids)
    return true
end

RemoveDeskZones = function()
    local ids = state.deskZones
    state.deskZones = nil
    if ids and TargetUp() then
        for _, id in ipairs(ids) do pcall(function() exports.ox_target:removeZone(id) end) end
    end
    for _, obj in ipairs(state.deskProps) do DeleteObject(obj) end
    state.deskProps = {}
    if ids then CP.log(TAG, 'mission desk zones removed') end
end

function T.deskZones()
    return state.deskZones
end

-- Desks changed in Admin UI → Departments → Desks: the zones are made again at once, and a tablet opened at a desk
-- that moved or went away closes.
local function DeskSignature(desk)
    if type(desk) ~= 'table' then return '' end
    local c, s = desk.coords or {}, desk.size or {}
    return ('%s|%.2f,%.2f,%.2f|%.2f,%.2f,%.2f|%.1f|%s|%s'):format(tostring(desk.label), tonumber(c.x) or 0,
        tonumber(c.y) or 0, tonumber(c.z) or 0, tonumber(s.x) or 0, tonumber(s.y) or 0, tonumber(s.z) or 0,
        tonumber(desk.rotation) or 0, type(desk.departments) == 'table' and table.concat(desk.departments, ',') or '',
        tostring(desk.prop))
end

local function DesksSignature()
    local parts = {}
    local t = Config.Tablet or {}
    parts[1] = type(t.access) == 'table' and tostring(t.access.desk) or ''
    for i, d in ipairs(type(t.desks) == 'table' and t.desks or {}) do parts[i + 1] = DeskSignature(d) end
    return table.concat(parts, '\n')
end
local desksSeen = nil
local deskAtOpen = nil   -- the signature of the desk the open tablet was opened at

CP.Hooks.on('settings:changed', function()
    local sig = DesksSignature()
    if desksSeen == nil then desksSeen = sig end
    if sig == desksSeen then return end
    desksSeen = sig
    if state.open and state.via == 'desk' then
        local desks = type(Config.Tablet) == 'table' and Config.Tablet.desks or {}
        if DeskSignature(type(desks) == 'table' and desks[state.desk] or nil) ~= deskAtOpen then T.close() end
    end
    if RemoveDeskZones and CreateDeskZones then
        RemoveDeskZones()
        CreateDeskZones()
    end
end)

function T._deskOpened(index)
    local desks = type(Config.Tablet) == 'table' and Config.Tablet.desks or {}
    deskAtOpen = DeskSignature(type(desks) == 'table' and desks[index] or nil)
end

-- ============================================================================
--                    AT THE DESK: THE POSE AND THE WATCHERS
-- ============================================================================

local function DeskScenario()
    local s = Config.Tablet and Config.Tablet.deskScenario
    return type(s) == 'string' and s ~= '' and s or nil
end

local function StartDeskPose()
    local scenario = DeskScenario()
    if not scenario then return end
    local ped = PlayerPedId()
    if IsEntityDead(ped) or IsPedInAnyVehicle(ped, false) then return end
    TaskStartScenarioInPlace(ped, scenario, 0, true)
end

StopDeskPose = function()
    if not DeskScenario() then return end
    local ped = PlayerPedId()
    if IsPedUsingScenario(ped, DeskScenario()) then ClearPedTasks(ped) end
end

local function DeskDistance()
    local d = tonumber(Config.Tablet and Config.Tablet.deskDistance)
    return d and d > 0 and d or 3.0
end

-- Metres from c to the desk's box, 0 inside it (rotation = the box heading in degrees, as the server reads it).
local function DeskGap(desk, c)
    local centre, size = desk.coords, desk.size or { x = 1.0, y = 1.0, z = 1.0 }
    local dx, dy, dz = c.x - centre.x, c.y - centre.y, (c.z or 0.0) - (centre.z or 0.0)
    local r = math.rad(tonumber(desk.rotation) or 0.0)
    local gx = math.max(0.0, math.abs(dx * math.cos(r) + dy * math.sin(r)) - (size.x or 1.0) / 2)
    local gy = math.max(0.0, math.abs(-dx * math.sin(r) + dy * math.cos(r)) - (size.y or 1.0) / 2)
    local gz = math.max(0.0, math.abs(dz) - (size.z or 1.0) / 2)
    return math.sqrt(gx * gx + gy * gy + gz * gz)
end

local function WatchDesk(token)
    local t = Config.Tablet or {}
    local desk = type(t.desks) == 'table' and t.desks[state.desk or -1] or nil
    if type(desk) ~= 'table' or not desk.coords then return end
    StartDeskPose()
    local limit = DeskDistance()
    while token == state.openToken and state.open do
        if DeskGap(desk, GetEntityCoords(PlayerPedId())) > limit then
            CP.log(TAG, 'walked away from desk %s: closing the tablet', tostring(state.desk))
            T.close()
            return
        end
        Wait(DESK_WATCH_MS)
    end
end

local function ClientItemCount(item)
    if GetResourceState('ox_inventory') ~= 'started' then return nil end
    local ok, res = pcall(function() return exports.ox_inventory:Search('count', item) end)
    return ok and tonumber(res) or nil
end

-- requireItem: the item left the inventory while the tablet is open. The server checks again and closes it.
local function WatchItem(token)
    local t = Config.Tablet or {}
    local item = type(t.item) == 'string' and t.item ~= '' and t.item or nil
    if not item or type(t.access) ~= 'table' or t.access.requireItem ~= true then return end
    local reported = false
    while token == state.openToken and state.open do
        Wait(ITEM_WATCH_MS)
        if token ~= state.openToken or not state.open or state.via == 'desk' then return end
        local n = ClientItemCount(item)
        if n ~= nil and n <= 0 then
            if not reported then
                reported = true
                TriggerServerEvent(CP.e('server:tabletItemGone'))
            end
        else
            reported = false
        end
    end
end

-- The officer went down with the Officer or Supervisor UI open: it closes (they open it again once revived).
local function WatchDown(token)
    while token == state.openToken and state.open do
        Wait(DOWN_WATCH_MS)
        if token ~= state.openToken or not state.open then return end
        if state.ui ~= 'admin' and PlayerDown() then
            CP.log(TAG, 'the officer went down: closing the tablet')
            T.close()
            return
        end
    end
end

StartWatchers = function()
    state.openToken = state.openToken + 1
    local token = state.openToken
    if state.via == 'desk' then
        CreateThread(function() WatchDesk(token) end)
    elseif state.ui ~= 'admin' then
        CreateThread(function() WatchItem(token) end)
    end
    CreateThread(function() WatchDown(token) end)
end

-- A NUI that never shows the UI (its page crashed or never loaded) must not keep the focus: with the cursor on an
-- empty page the player has no input and no Escape. Only once the NUI said at 'ready' that it confirms.
WatchAck = function(seq)
    if not state.nuiAcks then return end
    CreateThread(function()
        Wait(OPEN_ACK_MS)
        -- closed, opened again (a newer seq) or confirmed meanwhile
        if not state.open or seq ~= state.openSeq or state.ackSeq >= seq then return end
        CP.warn(TAG, 'the NUI did not show the %s UI within %d s: closed, NUI focus released', tostring(state.ui),
            OPEN_ACK_MS // 1000)
        T.close()
    end)
end

RegisterNetEvent(CP.e('client:closeTablet'), function(errKey)
    if not state.open or state.ui == 'admin' then return end
    T.close()
    if type(errKey) == 'string' and errKey ~= '' then T.notify('error', CP.L(errKey)) end
end)

CreateThread(function()
    T.wrapProgress()   -- again at runtime, in case ox_lib resolved lib.progressBar only now
    -- the command, keys and desks changed in game (Admin UI → Settings) come from the server first
    if CP.Settings and CP.Settings.ready then CP.Settings.ready(SETTINGS_WAIT_MS) end
    registerCommand()
    WatchArena()
    CreateDeskZones()
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
    if state.open and state.via == 'desk' then StopDeskPose() end
    state.panelOwner = nil
    StopProp()
    RemoveDeskZones()
end)

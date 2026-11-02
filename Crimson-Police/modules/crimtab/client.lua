-- CP.CrimTab (client, step G2): opens and closes the criminal tablet (Config.CriminalTablet) and keeps it fresh. The

CP.CrimTab = CP.CrimTab or {}
local C = CP.CrimTab
local TAG = 'crimtab'
local OWNER = 'crimtab'
local PAUSE_CONTROL = 200       -- INPUT_FRONTEND_PAUSE_ALTERNATE (Escape)
local DOWN_WATCH_MS = 1000      -- how often a downed user is looked for while it is open

local state = { open = false, opening = false, registered = nil, refreshing = false, again = false, token = 0 }

local function Send(msg) SendNUIMessage(CP.U.serialize(msg)) end

local function Toast(kind, key)
    if CP.Tablet and CP.Tablet.notify then CP.Tablet.notify(kind, CP.L(key)) end
end

local function PlayerDown()
    return CP.Tablet ~= nil and CP.Tablet.playerDown ~= nil and CP.Tablet.playerDown() == true
end

function C.isOpen() return state.open end

-- The view from the server -> view | nil, errKey.
local function Fetch()
    local ok, res = pcall(CP.Net.request, 'crimtab:get', {})
    if not ok or type(res) ~= 'table' then return nil, 'err.internal' end
    if not res.ok or type(res.data) ~= 'table' then return nil, res.error or 'err.no_response' end
    return res.data
end

-- ============================================================================
--                                 OPEN / CLOSE
-- ============================================================================

-- The Escape that closed it must not also open the pause menu (Config.Tablet.pauseGuardMs). One thread at a time: a
-- second close only extends it.
local pauseGuard = { untilMs = 0, running = false }

local function GuardPause()
    local ms = math.min(1000, tonumber(Config.Tablet and Config.Tablet.pauseGuardMs) or 300)
    if ms <= 0 then return end
    pauseGuard.untilMs = math.max(pauseGuard.untilMs, GetGameTimer() + ms)
    if pauseGuard.running then return end
    pauseGuard.running = true
    CreateThread(function()
        while GetGameTimer() < pauseGuard.untilMs do
            DisableControlAction(0, PAUSE_CONTROL, true)
            Wait(0)
        end
        pauseGuard.running = false
    end)
end

function C.close()
    if not state.open then return false end
    state.open = false
    Send({ type = 'crimtab', open = false })
    if CP.Tablet and CP.Tablet.panelFocus then CP.Tablet.panelFocus(OWNER, false) end
    if CP.Volunteers and CP.Volunteers.tabletClosed then pcall(CP.Volunteers.tabletClosed) end
    CP.log(TAG, 'criminal tablet closed')
    return true
end

-- screen (optional): 'home' | 'jobs' | 'active' | 'history' | 'rules'
function C.open(screen)
    if state.open then
        if screen then Send({ type = 'crimtab', open = true, screen = screen }) end
        return true
    end
    if state.opening then return false end
    if CP.Tablet and CP.Tablet.isOpen and CP.Tablet.isOpen() then return false end
    if PlayerDown() then
        Toast('error', 'err.downed')
        return false
    end
    state.opening = true
    local view, err = Fetch()
    state.opening = false
    if not view then
        Toast('error', err)
        return false
    end
    if not (CP.Tablet and CP.Tablet.panelFocus and CP.Tablet.panelFocus(OWNER, true)) then
        Toast('error', 'err.crimtab_busy')
        return false
    end
    state.open = true
    if not screen then screen = view.active and 'active' or (view.jobs and view.jobs[1]) and 'jobs' or nil end
    Send({ type = 'crimtab', open = true, view = view, screen = screen })
    CP.log(TAG, 'criminal tablet opened')
    -- the user went down with it open: it closes, as the officer tablet does (its focus is never left over the
    -- death or last stand screen)
    state.token = state.token + 1
    local token = state.token
    CreateThread(function()
        while state.open and state.token == token do
            Wait(CP.Perf.ms(DOWN_WATCH_MS))
            if not state.open or state.token ~= token then return end
            if PlayerDown() then
                CP.log(TAG, 'the user went down: closing the criminal tablet')
                C.close()
                return
            end
        end
    end)
    return true
end

-- A fresh view while it is open (one request at a time; a change during one asks again once it is back).
function C.refresh(screen)
    if not state.open then return end
    if state.refreshing then
        state.again = true
        return
    end
    state.refreshing = true
    CreateThread(function()
        repeat
            state.again = false
            local view, err = Fetch()
            if not state.open then break end
            if view then
                Send({ type = 'crimtab', open = true, view = view, screen = screen })
            else
                C.close()
                Toast('error', err)
                break
            end
            screen = nil
        until not state.again
        state.refreshing = false
    end)
end

RegisterNUICallback('crimtabClose', function(_, cb)
    cb({ ok = true })
    if C.close() then GuardPause() end
end)

-- After an answer from the tablet the question's pop-up (if one is open) closes too.
RegisterNUICallback('crimtabAnswered', function(body, cb)
    cb({ ok = true })
    local token = type(body) == 'table' and body.token or nil
    if type(token) == 'string' and CP.Volunteers and CP.Volunteers.askAnswered then
        CP.Volunteers.askAnswered(token)
    end
end)

-- ============================================================================
--                                    EVENTS
-- ============================================================================

RegisterNetEvent(CP.e('client:crimtabOpen'), function() CreateThread(function() C.open() end) end)

RegisterNetEvent(CP.e('client:crimtabClose'), function()
    if C.close() then Toast('warning', 'err.crimtab_closed') end
end)

-- Whatever the volunteer side hears changes what the tablet shows.
RegisterNetEvent(CP.e('client:volunteerNote'), function() C.refresh() end)
RegisterNetEvent(CP.e('client:volunteerAskClose'), function() C.refresh() end)
RegisterNetEvent(CP.e('client:volunteerAsk'), function() C.refresh('jobs') end)
RegisterNetEvent(CP.e('client:volunteerCase'), function(s)
    C.refresh(type(s) == 'table' and s.phase == 'travel' and 'active' or nil)
end)

-- ============================================================================
--                            COMMAND, ITEM, CLEANUP
-- ============================================================================

exports('useCriminalTablet', function(data)
    local cfg = Config.CriminalTablet or {}
    local item = type(cfg.item) == 'string' and cfg.item ~= '' and cfg.item or nil
    if not item or cfg.enabled ~= true then return end
    if type(data) == 'table' and type(data.name) == 'string' and data.name ~= item then return end
    CreateThread(function() C.open() end)
end)

-- The command exists once Config.CriminalTablet.enabled is on (RegisterCommand cannot be undone: restart to change).
local function Register()
    local cfg = Config.CriminalTablet
    if state.registered or type(cfg) ~= 'table' or cfg.enabled ~= true then return end
    local cmd = type(cfg.command) == 'string' and cfg.command:match('^%a[%w_%-]*$') or 'crimtab'
    state.registered = cmd
    RegisterCommand(cmd, function()
        CreateThread(function()
            if state.open then C.close() else C.open() end
        end)
    end, false)
end
C.register = Register

Register()
CP.Hooks.on('settings:changed', function()
    Register()
    if state.open and (Config.CriminalTablet or {}).enabled ~= true then C.close() end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    if state.open then
        state.open = false
        if CP.Tablet and CP.Tablet.panelFocus then CP.Tablet.panelFocus(OWNER, false) end
    end
end)

-- Test hooks (not part of the contract).
C._guardPause = GuardPause

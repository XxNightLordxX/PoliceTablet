-- CP.Volunteers (client, step V20): the volunteer command (Config.Volunteers.command, default /crimsonheat).
-- Volunteers have no tablet: ox_lib's alert and input dialogs, a context menu and notifications only. The server
-- decides everything; this side asks it what to show and sends the player's choices.

local MENU_ID = 'crimson_police_volunteer'
local registered = nil   -- the command name once registered (RegisterCommand cannot be undone: restart to change)
local busy = false       -- a dialog is open

local function Send(action, data) TriggerServerEvent(CP.e('server:volunteer'), action, data) end

local function RoleLabel(role) return CP.L('volunteer.role.' .. tostring(role)) end

-- The suspects to play, all ticked or the current picks -> { [role] = true } or nil (closed, or none ticked).
local function PickRoles(all, current)
    local on = {}
    for _, role in ipairs(current or all) do on[role] = true end
    local rows = {}
    for i, role in ipairs(all) do
        rows[i] = { type = 'checkbox', label = RoleLabel(role), checked = on[role] == true }
    end
    local answer = lib.inputDialog(CP.L('volunteer.roles.title'), rows)
    if type(answer) ~= 'table' then return nil end
    local out, any = {}, false
    for i, role in ipairs(all) do
        if answer[i] == true then out[role], any = true, true end
    end
    if not any then
        lib.notify({ title = CP.L('volunteer.title'), description = CP.L('volunteer.refused.no_role'), type = 'error' })
        return nil
    end
    return out
end

local function Start(state)
    local answer = lib.alertDialog({
        header = CP.L('volunteer.consent.title'),
        content = CP.L('volunteer.consent.content',
            { minutes = tonumber(state.minutes) or 60, strikes = tonumber(state.maxStrikes) or 3 }),
        centered = true,
        cancel = true,
        labels = { confirm = CP.L('volunteer.consent.agree') },
    })
    if answer ~= 'confirm' then return end
    local roles = PickRoles(type(state.roles) == 'table' and state.roles or {})
    if roles then Send('join', { roles = roles }) end
end

local function Menu(state)
    local names = {}
    for _, role in ipairs(type(state.roles) == 'table' and state.roles or {}) do names[#names + 1] = RoleLabel(role) end
    lib.registerContext({
        id = MENU_ID,
        title = CP.L('volunteer.title'),
        options = {
            {
                title = CP.L('volunteer.menu.status', { minutes = tonumber(state.minutesLeft) or 0 }),
                description = CP.L('volunteer.menu.status_detail', {
                    roles = table.concat(names, ', '),
                    strikes = tonumber(state.strikes) or 0,
                    max = tonumber(state.maxStrikes) or 0,
                }),
                readOnly = true,
            },
            {
                title = CP.L('volunteer.menu.renew'),
                onSelect = function() Send('renew') end,
            },
            {
                title = CP.L('volunteer.menu.roles'),
                onSelect = function()
                    local roles = PickRoles(CP.Volunteers.allRoles, state.roles)
                    if roles then Send('roles', { roles = roles }) end
                end,
            },
            {
                title = CP.L('volunteer.menu.stop'),
                onSelect = function()
                    local answer = lib.alertDialog({
                        header = CP.L('volunteer.menu.stop'),
                        content = CP.L('volunteer.stop.content'),
                        centered = true,
                        cancel = true,
                    })
                    if answer == 'confirm' then Send('stop') end
                end,
            },
        },
    })
    lib.showContext(MENU_ID)
end

CP.Volunteers = CP.Volunteers or {}
CP.Volunteers.allRoles = { 'runner', 'driver', 'fugitive' }

RegisterNetEvent(CP.e('client:volunteerMenu'), function(state)
    if type(state) ~= 'table' or busy then return end
    busy = true
    CreateThread(function()
        local ok, err = pcall(state.active == true and Menu or Start, state)
        busy = false
        if not ok then CP.err('volunteers', 'the volunteer menu failed: ' .. tostring(err)) end
    end)
end)

RegisterNetEvent(CP.e('client:volunteerNote'), function(kind, key, vars)
    if type(key) ~= 'string' then return end
    lib.notify({
        title = CP.L('volunteer.title'),
        description = CP.L(key, type(vars) == 'table' and vars or nil),
        type = (kind == 'success' or kind == 'error' or kind == 'warning') and kind or 'inform',
        duration = 8000,
    })
end)

-- The command exists only once Config.Volunteers.enabled is on (at the start, or when an admin turns it on).
local function Register()
    local cfg = Config.Volunteers
    if registered or type(cfg) ~= 'table' or cfg.enabled ~= true then return end
    local cmd = type(cfg.command) == 'string' and cfg.command:match('^%a[%w_%-]*$') or 'crimsonheat'
    registered = cmd
    RegisterCommand(cmd, function() Send('open') end, false)
end
CP.Volunteers.register = Register

Register()
CP.Hooks.on('settings:changed', Register)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() or not busy then return end
    pcall(lib.closeAlertDialog)
    pcall(lib.closeInputDialog)
end)

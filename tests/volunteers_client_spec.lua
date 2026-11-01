-- Volunteer opt-in (step V20), the client: the command exists only once Config.Volunteers.enabled is on, and the
-- server's menu becomes ox_lib's consent alert, the roles input, the context menu and notifications. Plain Lua stubs.

local H = dofile('tests/harness.lua')
H.boot({ side = 'client', realLocale = true })

local answers = { alert = {}, input = {} }
local shown = { alerts = {}, inputs = {}, contexts = {}, notes = {} }
lib.alertDialog = function(d)
    shown.alerts[#shown.alerts + 1] = d
    return table.remove(answers.alert, 1)
end
lib.inputDialog = function(title, rows)
    shown.inputs[#shown.inputs + 1] = { title = title, rows = rows }
    return table.remove(answers.input, 1)
end
lib.registerContext = function(ctx) shown.contexts[#shown.contexts + 1] = ctx end
lib.showContext = function() end
lib.notify = function(n) shown.notes[#shown.notes + 1] = n end
lib.closeAlertDialog = function() end
lib.closeInputDialog = function() end

H.load('modules/volunteers/client.lua')
H.step(0)

local function Sent(action)
    local out = {}
    for _, e in ipairs(H.events) do
        if e.kind == 'server' and e.name == CP.e('server:volunteer') and (action == nil or e.args[1] == action) then
            out[#out + 1] = e
        end
    end
    return out
end
local function Menu(state)
    H.fire(CP.e('client:volunteerMenu'), nil, state)
    H.step(0)
end

do
    H.eq(H.commands.crimsonheat, nil, 'shipped off: no /crimsonheat command')
    Config.Volunteers.enabled = true
    CP.Hooks.fire('settings:changed')
    H.ok(H.commands.crimsonheat ~= nil, 'turned on: /crimsonheat exists')
    H.commands.crimsonheat.fn(0, {}, '')
    H.eq(#Sent('open'), 1, 'the command asks the server what to show')
end

do
    -- the start: consent, then the roles (runner left unticked)
    answers.alert = { 'confirm' }
    answers.input = { { false, true, true } }
    Menu({ active = false, minutes = 60, roles = { 'runner', 'driver', 'fugitive' }, strikes = 0, maxStrikes = 3 })
    H.eq(#shown.alerts, 1, 'the consent alert')
    H.ok(shown.alerts[1].content:find('60 minutes', 1, true) ~= nil, 'it names the window')
    H.eq(#shown.inputs[1].rows, 3, 'one checkbox per role')
    local join = Sent('join')[1]
    H.ok(join ~= nil, 'join sent')
    local roles = join and join.args[2].roles or {}
    H.ok(roles.runner == nil and roles.driver == true and roles.fugitive == true, 'the ticked roles')

    -- consent declined: nothing is sent
    answers.alert = { 'cancel' }
    Menu({ active = false, minutes = 60, roles = { 'runner' } })
    H.eq(#Sent('join'), 1, 'no join without the agreement')

    -- nothing ticked: a notification, no join
    answers.alert = { 'confirm' }
    answers.input = { { false } }
    Menu({ active = false, minutes = 60, roles = { 'runner' } })
    H.eq(#Sent('join'), 1, 'no join without a role')
    H.eq(shown.notes[#shown.notes].type, 'error', 'told to pick one')
end

do
    -- listed: the context menu (status, renew, roles, stop)
    Menu({ active = true, minutesLeft = 42, roles = { 'driver' }, strikes = 1, maxStrikes = 3 })
    local ctx = shown.contexts[#shown.contexts]
    H.eq(#ctx.options, 4, 'status, renew, roles and stop')
    H.ok(ctx.options[1].title:find('42', 1, true) ~= nil, 'minutes left')
    H.eq(ctx.options[1].readOnly, true, 'the status line is not a button')
    ctx.options[2].onSelect()
    H.eq(#Sent('renew'), 1, 'renew sent')
    answers.alert = { 'confirm' }
    ctx.options[4].onSelect()
    H.eq(#Sent('stop'), 1, 'stop after the confirm')
end

do
    H.fire(CP.e('client:volunteerNote'), nil, 'success', 'volunteer.started', { minutes = 60 })
    local n = shown.notes[#shown.notes]
    H.eq(n.type, 'success', 'the server note becomes an ox_lib notification')
    H.ok(n.description:find('60 minutes', 1, true) ~= nil, 'in English, with the minutes')
end

return H

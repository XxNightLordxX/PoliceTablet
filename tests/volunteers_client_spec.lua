-- Volunteer opt-in, the client: the command exists only once Config.RealPlayers.volunteer.enabled is on, and the
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
local closed = { alert = 0 }
lib.closeAlertDialog = function() closed.alert = closed.alert + 1 end
lib.closeInputDialog = function() end
lib.hideContext = function() end
local waypoints = {}
_G.SetNewWaypoint = function(x, y) waypoints[#waypoints + 1] = { x = x, y = y } end
_G.SetWaypointOff = function() waypoints[#waypoints + 1] = 'off' end

H.load('modules/realplayers/client/volunteers.lua')
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
    Config.RealPlayers.volunteer.enabled = true
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

    -- (Z14) suspect pay on: the consent says a fair case is paid
    answers.alert = { 'cancel' }
    Menu({ active = false, minutes = 60, roles = { 'runner' }, paid = true })
    local paidText = shown.alerts[#shown.alerts].content
    H.ok(
        paidText:find('pays a suspect for a fair case', 1, true) ~= nil
            and paidText:find('gives suspects nothing', 1, true) == nil,
        '(Z14) the paid consent text'
    )
    H.ok(shown.alerts[1].content:find('gives suspects nothing', 1, true) ~= nil, '(Z14) shipped: suspects get nothing')

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
    -- V22: while he plays a suspect the menu offers Cancel this case (second, with a confirm)
    Menu({
        active = true,
        minutesLeft = 30,
        roles = { 'runner' },
        strikes = 0,
        maxStrikes = 3,
        case = { phase = 'travel', role = 'runner' },
    })
    local ctx = shown.contexts[#shown.contexts]
    H.eq(#ctx.options, 5, 'status, cancel this case, renew, roles and stop')
    H.eq(ctx.options[2].title, 'Cancel this case', 'Cancel this case comes second')
    answers.alert = { 'cancel' }
    ctx.options[2].onSelect()
    H.eq(#Sent('cancel'), 0, 'not without the confirm')
    answers.alert = { 'confirm' }
    ctx.options[2].onSelect()
    H.eq(#Sent('cancel'), 1, 'cancel sent after the confirm')
end

do
    -- V22: the yes/no question; only a click answers, with the server's token
    answers.alert = { 'confirm' }
    H.fire(CP.e('client:volunteerAsk'), nil, 'va1_000001',
        { role = 'runner', seconds = 30, km = 1.5, travelMinutes = 5 })
    H.step(0)
    local alert = shown.alerts[#shown.alerts]
    H.eq(alert.header, 'Play a suspect now?', 'the question')
    H.ok(alert.content:find('1.5 km', 1, true) ~= nil, 'it says how far')
    H.ok(alert.content:find('Saying no costs nothing', 1, true) ~= nil, 'and that no costs nothing')
    local a = Sent('answer')[1]
    H.eq(a and a.args[2].token, 'va1_000001', 'the answer carries the token')
    H.eq(a and a.args[2].yes, true, 'yes')
    answers.alert = { 'cancel' }
    H.fire(CP.e('client:volunteerAsk'), nil, 'va2_000002', { role = 'runner', seconds = 30, travelMinutes = 5 })
    H.step(0)
    a = Sent('answer')[2]
    H.eq(a and a.args[2].yes, false, 'no')

    -- no click in time: the pop-up closes itself and nothing is sent
    local real = lib.alertDialog
    lib.alertDialog = function()
        Wait(31000)
        return nil
    end
    H.fire(CP.e('client:volunteerAsk'), nil, 'va3_000003', { role = 'runner', seconds = 30, travelMinutes = 5 })
    H.advance(32000, 1000)
    H.eq(closed.alert > 0, true, 'the pop-up closes after its seconds')
    H.eq(#Sent('answer'), 2, 'no answer is sent')
    lib.alertDialog = real

    -- his case: the meet point becomes his waypoint, removed in position
    H.fire(CP.e('client:volunteerCase'), nil,
        { phase = 'travel', meet = { x = 10.0, y = 20.0, z = 30.0 }, seconds = 300 })
    H.eq(waypoints[1] and waypoints[1].x, 10.0, 'the meet point is his map waypoint')
    H.fire(CP.e('client:volunteerCase'), nil, { phase = 'in_position' })
    H.eq(waypoints[2], 'off', 'removed once in position')
    H.fire(CP.e('client:volunteerCase'), nil, { phase = 'over' })
    H.eq(#waypoints, 2, 'never twice')
end

do
    H.fire(CP.e('client:volunteerNote'), nil, 'success', 'volunteer.started', { minutes = 60 })
    local n = shown.notes[#shown.notes]
    H.eq(n.type, 'success', 'the server note becomes an ox_lib notification')
    H.ok(n.description:find('60 minutes', 1, true) ~= nil, 'in English, with the minutes')
end

do
    -- G2: while the criminal tablet is open its Jobs screen asks instead of the pop-up; closing it shows the pop-up
    -- for the seconds left; an answer from the tablet closes a pop-up without answering twice
    local tabletOpen = true
    CP.CrimTab = {
        isOpen = function() return tabletOpen end,
    }
    local before, sentBefore = #shown.alerts, #Sent('answer')
    H.fire(CP.e('client:volunteerAsk'), nil, 'va4_000004', { role = 'runner', seconds = 30, travelMinutes = 5 })
    H.step(0)
    H.eq(#shown.alerts, before, 'tablet open: no pop-up')
    H.advance(10000, 1000)
    tabletOpen = false
    answers.alert = { 'confirm' }
    CP.Volunteers.tabletClosed()
    H.step(0)
    H.eq(#shown.alerts, before + 1, 'the tablet closed: the pop-up comes up')
    H.ok(shown.alerts[#shown.alerts].content:find('20 seconds', 1, true) ~= nil, 'for the seconds left')
    H.eq(#Sent('answer'), sentBefore + 1, 'and its click answers')

    tabletOpen = true
    H.fire(CP.e('client:volunteerAsk'), nil, 'va5_000005', { role = 'runner', seconds = 30, travelMinutes = 5 })
    H.step(0)
    local closes = closed.alert
    CP.Volunteers.askAnswered('va5_000005')
    H.ok(closed.alert > closes, 'answered in the tablet: any pop-up closes')
    tabletOpen = false
    CP.Volunteers.tabletClosed()
    H.step(0)
    H.eq(#shown.alerts, before + 1, 'and it never comes up again')
    H.eq(#Sent('answer'), sentBefore + 1, 'nor answers twice')
    CP.CrimTab = nil
end

return H

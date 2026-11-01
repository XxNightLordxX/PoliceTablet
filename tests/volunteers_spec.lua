-- Volunteer opt-in (step V20): CP.Volunteers on the server, the command's event (open, join, renew, roles, stop),
-- the window, the ends (expired, on duty, excluded, disabled, left) and strikes. Plain Lua with stubs.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end

-- ============================================================================
--                                    STUBS
-- ============================================================================

local infos = {}          -- [src] = CP.Qbx.getInfo answer
local eligibleWhy = {}    -- [src] = the CP.Opponents.eligible refusal
local excluded = {}       -- [citizenid] = true
local sampled = {}        -- [citizenid] = true while AFK samples run
local qbx = { unload = {}, duty = {}, job = {} }
CP.Qbx = {
    getInfo = function(src) return infos[src] end,
    onPlayerUnload = function(fn) qbx.unload[#qbx.unload + 1] = fn end,
    onDutyChange = function(fn) qbx.duty[#qbx.duty + 1] = fn end,
    onJobChange = function(fn) qbx.job[#qbx.job + 1] = fn end,
}
CP.Access = {
    departmentForJob = function(name) return name == 'police' and { key = 'lspd' } or nil end,
    offDepartmentForJob = function() return nil end,
    isAdmin = function() return false end,
}
CP.Opponents = {
    eligible = function(src)
        if eligibleWhy[src] then return false, eligibleWhy[src] end
        return true
    end,
    excluded = function(cid) return excluded[cid] == true end,
    sampleCrew = function(key, cids)
        H.eq(key, 'volunteers', 'AFK samples under the volunteers key')
        for _, c in ipairs(cids) do sampled[c] = true end
        return true
    end,
    unsampleCrew = function(_, cids)
        for _, c in ipairs(cids) do sampled[c] = nil end
        return true
    end,
}

local function Player(src, cid, license, job, onduty)
    infos[src] = {
        citizenid = cid,
        license = license,
        name = 'Name ' .. src,
        job = { name = job or 'unemployed', onduty = onduty == true },
    }
end

H.load('modules/volunteers/server.lua')
H.step(0)
local V = CP.Volunteers

local function ClientEvents(name, target)
    local out = {}
    for _, e in ipairs(H.events) do
        if e.kind == 'client' and e.name == CP.e(name) and (target == nil or e.target == target) then
            out[#out + 1] = e
        end
    end
    return out
end
local function LastNote(src)
    local list = ClientEvents('client:volunteerNote', src)
    local e = list[#list]
    return e and e.args[2], e and e.args[3]
end
local function LastMenu(src)
    local list = ClientEvents('client:volunteerMenu', src)
    return list[#list] and list[#list].args[1]
end
local function Fire(src, action, data)
    H.clockMs = H.clockMs + 2000   -- past the 4-in-2-s rate limit (no thread wakes)
    H.fire(CP.e('server:volunteer'), src, action, data)
end
local ALL = { runner = true, driver = true, fugitive = true }

-- ============================================================================
--                         SHIPPED OFF: NOTHING HAPPENS
-- ============================================================================

do
    H.eq(Config.Volunteers.enabled, false, 'volunteers ship off')
    H.eq(Config.Volunteers.command, 'crimsonheat', 'the shipped command is /crimsonheat')
    H.eq(Config.Volunteers.windowMinutes, 60, 'an hour window')
    Player(1, 'VOL00001', 'license:aaa')
    Fire(1, 'open')
    H.eq(LastNote(1), 'volunteer.refused.off', 'off: the command only says it is not available')
    H.eq(#ClientEvents('client:volunteerMenu', 1), 0, 'off: no menu')
    local ok, why = V.join(1, ALL)
    H.eq(ok, false, 'off: nobody joins')
    H.eq(why, 'off', 'off: the reason')
    H.eq(#V.list(), 0, 'the list stays empty')
end

Config.Volunteers.enabled = true

-- ============================================================================
--                                   JOINING
-- ============================================================================

do
    Fire(1, 'open')
    local menu = LastMenu(1)
    H.ok(menu ~= nil and menu.active == false, 'open: the start (consent) menu')
    H.eq(menu and menu.minutes, 60, 'the window in minutes')
    H.eq(menu and #menu.roles, 3, 'every role offered')

    Fire(1, 'join', { roles = { runner = true, driver = 'yes' } })
    H.eq(LastNote(1), 'volunteer.started', 'joined')
    H.ok(V.isListed('VOL00001'), 'on the list')
    H.ok(sampled.VOL00001 == true, 'his AFK samples start')
    local list = V.list()
    H.eq(#list, 1, 'one volunteer')
    H.eq(table.concat(list[1].roles, ','), 'runner', 'only true picks count')
    H.eq(list[1].untilAt - list[1].since, 3600, 'an hour from now')

    Fire(1, 'join', { roles = ALL })
    H.eq(LastNote(1), 'volunteer.refused.already', 'a second join is refused')

    Fire(1, 'open')
    menu = LastMenu(1)
    H.ok(menu and menu.active == true, 'open while listed: the volunteer menu')
    H.eq(menu and menu.minutesLeft, 60, 'minutes left')

    Fire(1, 'roles', { roles = { fugitive = true } })
    H.eq(LastNote(1), 'volunteer.roles_saved', 'roles changed')
    H.eq(table.concat(V.list()[1].roles, ','), 'fugitive', 'the new picks')
    Fire(1, 'roles', { roles = {} })
    H.eq(LastNote(1), 'volunteer.refused.no_role', 'at least one role')

    Player(2, 'VOL00002', 'license:bbb')
    Fire(2, 'join', { roles = { nobody = true } })
    H.eq(LastNote(2), 'volunteer.refused.no_role', 'no valid role: refused')
    H.ok(not V.isListed('VOL00002'), 'not listed')
end

do
    -- refusals: CP.Opponents.eligible, an admin's exclusion
    Player(3, 'VOL00003', 'license:ccc', 'police', true)
    eligibleWhy[3] = 'on_duty'
    Fire(3, 'open')
    H.eq(LastNote(3), 'volunteer.refused.on_duty', 'police on duty are refused')
    eligibleWhy[3] = 'job_hop'
    Fire(3, 'join', { roles = ALL })
    H.eq(LastNote(3), 'volunteer.refused.job_hop', 'recent police duty is refused')
    eligibleWhy[3] = 'something_new'
    Fire(3, 'open')
    H.eq(LastNote(3), 'volunteer.refused.other', 'an unknown reason has a plain message')
    eligibleWhy[3] = nil
    infos[3].job.onduty = false
    excluded.VOL00003 = true
    Fire(3, 'open')
    H.eq(LastNote(3), 'volunteer.refused.excluded', 'an admin exclusion is refused')
    excluded.VOL00003 = nil
    Fire(4, 'open')
    H.eq(LastNote(4), 'volunteer.refused.not_loaded', 'no character: refused')
    Fire(1, 'nonsense')
    Fire(1, 42)
    H.ok(V.isListed('VOL00001'), 'an unknown action changes nothing')
end

-- ============================================================================
--                             THE WINDOW AND ENDS
-- ============================================================================

do
    local before = V.list()[1].untilAt
    H.time = H.time + 1800
    Fire(1, 'renew')
    H.eq(LastNote(1), 'volunteer.renewed', 'renewed')
    H.eq(V.list()[1].untilAt, before + 1800, 'a fresh hour from now')

    H.time = H.time + 3599
    V._sweep()
    H.ok(V.isListed('VOL00001'), 'still listed a second before the end')
    H.time = H.time + 1
    H.step(15000)
    H.ok(not V.isListed('VOL00001'), 'the window ran out (the sweep)')
    H.eq(LastNote(1), 'volunteer.ended.expired', 'told it is over')
    H.ok(sampled.VOL00001 == nil, 'his AFK samples stop')

    Fire(1, 'renew')
    H.eq(LastNote(1), 'volunteer.refused.not_listed', 'renew after the end is refused')

    -- he stops himself
    Fire(1, 'join', { roles = ALL })
    Fire(1, 'stop')
    H.eq(LastNote(1), 'volunteer.ended.stopped', 'stopped')
    H.ok(not V.isListed('VOL00001'), 'off the list')

    -- police duty (the qbx duty listener)
    Fire(1, 'join', { roles = ALL })
    infos[1].job = { name = 'police', onduty = true }
    for _, fn in ipairs(qbx.duty) do fn(1, true) end
    H.eq(LastNote(1), 'volunteer.ended.on_duty', 'police duty ends it')
    H.ok(not V.isListed('VOL00001'), 'off the list')
    infos[1].job = { name = 'unemployed', onduty = false }

    -- a police job with duty on (the job listener)
    Fire(1, 'join', { roles = ALL })
    for _, fn in ipairs(qbx.job) do fn(1, { name = 'police', onduty = true }) end
    H.ok(not V.isListed('VOL00001'), 'a police job on duty ends it')

    -- an admin excludes him
    Fire(1, 'join', { roles = ALL })
    excluded.VOL00001 = true
    V._sweep()
    H.eq(LastNote(1), 'volunteer.ended.excluded', 'an exclusion ends it')
    excluded.VOL00001 = nil

    -- he leaves (drop, unload)
    Fire(1, 'join', { roles = ALL })
    local notes = #ClientEvents('client:volunteerNote', 1)
    H.fire('playerDropped', 1)
    H.ok(not V.isListed('VOL00001'), 'a drop ends it')
    H.eq(#ClientEvents('client:volunteerNote', 1), notes, 'nobody is told about a drop')
    Fire(1, 'join', { roles = ALL })
    for _, fn in ipairs(qbx.unload) do fn(1) end
    H.ok(not V.isListed('VOL00001'), 'a character unload ends it')

    -- the owner turns volunteers off
    Fire(1, 'join', { roles = ALL })
    Config.Volunteers.enabled = false
    CP.Hooks.fire('settings:changed', { 'Volunteers.enabled' })
    H.eq(LastNote(1), 'volunteer.ended.disabled', 'turning it off ends every listing')
    H.eq(#V.list(), 0, 'the list is empty')
    Config.Volunteers.enabled = true
end

-- ============================================================================
--                                   STRIKES
-- ============================================================================

do
    Fire(1, 'join', { roles = ALL })
    H.eq(V.strike('VOL00001', 'no_show'), 1, 'strike 1')
    H.eq(LastNote(1), 'volunteer.strike', 'told about the strike')
    H.ok(V.isListed('VOL00001'), 'still listed after one strike')
    H.time = H.time + 25 * 3600
    H.eq(V.strikes('VOL00001'), 0, 'a strike older than strikeHours no longer counts')
    V.strike('VOL00001', 'no_show')
    V.strike('VOL00001', 'walked_away')
    local count, untilAt = V.strike('VOL00001', 'no_show')
    H.eq(count, 3, 'the third strike')
    H.eq(untilAt, H.time + 24 * 3600, 'blocked for blockHours')
    H.ok(not V.isListed('VOL00001'), 'the block ends the listing')
    H.eq(LastNote(1), 'volunteer.ended.strikes', 'told why')

    -- the block is per player (license): another character of the same player is refused too
    Player(1, 'VOL00009', 'license:aaa')
    Fire(1, 'open')
    local key, vars = LastNote(1)
    H.eq(key, 'volunteer.refused.blocked', 'another character of the player is blocked')
    H.eq(vars and vars.hours, 24, 'the hours left')
    H.time = H.time + 24 * 3600
    Fire(1, 'open')
    H.eq(LastMenu(1) and LastMenu(1).active, false, 'after blockHours he may volunteer again')
end

return H

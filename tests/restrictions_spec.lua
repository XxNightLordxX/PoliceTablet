-- The one restrictions list (modules/supervisor/restrictions.lua): every kind registers with CP.Restriction from

-- The one restrictions list (modules/supervisor/restrictions.lua): every kind registers with CP.Restriction from
-- the module that owns it, the engine reads each kind's own rules (permission per step, longest, self rule, its own
-- switches), and the old separate lift routes are gone. Each kind's behaviour through the engine is in its own spec:
-- mission bans and tablet suspensions in mission_ban_spec, the Real suspects kinds and volunteer strikes in
-- opponents_staff_spec, the strikes block itself in volunteers_spec. Plain Lua with stubs.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false

local function Read(rel)
    local f = io.open(rel, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

-- ============================================================================
--                          THE ENGINE WITH STUB KINDS
-- ============================================================================

local acts, cbs, audits = {}, {}, {}
local selfCids, perms = {}, { lift = true, extend = true }
CP.AdminKit = {
    callback = function(name, key, fn) cbs[name] = { key = key, fn = fn } end,
    action = function(name, key, fn, opts) acts[name] = { key = key, fn = fn, opts = opts } end,
    isSelf = function(_, cid) return selfCids[cid] == true end,
}
CP.Permissions = {
    can = function(_, key) return perms[key] == true end,
}
CP.RestrictionKinds = { order = {}, byKey = {} }

local calls = {}
local switchOn = true
CP.Restriction('first', {
    perm = { lift = 'lift', extend = 'extend' },
    maxHours = 48,
    self = true,
    liftOn = function() return switchOn end,
    list = function()
        return {
            { citizenid = 'AAA00001', untilAt = os.time() + 100, by = 'BOSS0001', byName = 'Boss', reason = 'Why' },
            { citizenid = 'AAA00002', untilAt = os.time() - 1 },
        }
    end,
    lift = function(_, p)
        calls[#calls + 1] = { 'lift', p.citizenid }
        return true, { citizenid = p.citizenid }
    end,
    extend = function(_, p, hours)
        calls[#calls + 1] = { 'extend', p.citizenid, hours }
        return true, {}
    end,
})
CP.Restriction('hidden', {
    perm = { lift = 'nobody' },
    on = function() return false end,
    list = function() return { { citizenid = 'BBB00001', untilAt = os.time() + 50 } } end,
    lift = function() return true end,
})
H.eq(table.concat(CP.RestrictionKinds.order, ','), 'first,hidden', 'kinds keep the order they register in')
H.load('modules/supervisor/restrictions.lua')
H.ok(cbs['admin:getRestrictions'] and cbs['admin:getRestrictions'].key == 'openAdmin', 'one list callback')
local RA = acts['server:admin:restriction']
H.ok(RA and RA.opts.reason == true, 'one action, with a reason')

local view = cbs['admin:getRestrictions'].fn({ src = 9, args = {} })
H.eq(#view.kinds, 1, 'a kind that is off, or the admin may neither lift nor extend, is not shown')
H.eq(#view.rows, 1, 'a row that ended is left out')
local row = view.rows[1]
H.ok(row.kind == 'first' and row.by == 'BOSS0001' and row.byName == 'Boss' and row.reason == 'Why',
    'a row carries its kind, setter and reason')
H.ok(view.kinds[1].canLift and view.kinds[1].canExtend and view.kinds[1].maxHours == 48, 'and what the admin may do')
switchOn = false
H.eq(cbs['admin:getRestrictions'].fn({ src = 9, args = {} }).kinds[1].canLift, false,
    'the kind\'s own lift switch hides Lift')
switchOn = true

local function Act(p)
    p.reason = p.reason or 'r'
    return RA.fn({
        src = 9,
        payload = p,
        reason = p.reason,
        audit = function(...) audits[#audits + 1] = { ... } end,
    })
end
local ok, e = Act({ op = 'extend', kind = 'first', citizenid = 'AAA00001', hours = 6 })
H.ok(ok == true and calls[1][1] == 'extend' and calls[1][3] == 6, 'extend reaches the kind with the hours')
ok, e = Act({ op = 'extend', kind = 'first', citizenid = 'AAA00001', hours = 49 })
H.eq(e, 'err.restriction_hours', 'never past the kind\'s longest')
ok, e = Act({ op = 'extend', kind = 'first', citizenid = 'AAA00001', hours = 1.5 })
H.eq(e, 'err.restriction_hours', 'whole hours only')
ok = Act({ op = 'lift', kind = 'first', citizenid = 'AAA00001' })
H.ok(ok == true and calls[2][1] == 'lift', 'lift reaches the kind')
selfCids.AAA00001 = true
ok, e = Act({ op = 'lift', kind = 'first', citizenid = 'AAA00001' })
H.eq(e, 'err.self_target', 'the kind\'s self rule')
selfCids.AAA00001 = nil
perms.extend = false
ok, e = Act({ op = 'extend', kind = 'first', citizenid = 'AAA00001', hours = 1 })
H.eq(e, 'err.no_permission', 'each step has its own permission')
perms.extend = true
ok, e = Act({ op = 'lift', kind = 'hidden', citizenid = 'BBB00001' })
H.eq(e, 'err.no_permission', 'a kind the admin has no permission for')

-- ============================================================================
--                     THE MODULE LAYOUT AND THE OLD ROUTES
-- ============================================================================

H.eq(Read('Crimson-Police/modules/missionban/server.lua'), nil, 'modules/missionban is gone')
H.ok(Read('Crimson-Police/modules/supervisor/missionban.lua') ~= nil, 'the mission ban is a sub-file of supervisor')
local kinds = {
    { 'Crimson-Police/modules/admin/server.lua', 'CP.Restriction(\'suspension\'' },
    { 'Crimson-Police/modules/supervisor/missionban.lua', 'CP.Restriction(\'missionBan\'' },
    { 'Crimson-Police/modules/realplayers/staff.lua', '{ \'pairBlock\', \'block\' }' },
    { 'Crimson-Police/modules/realplayers/staff.lua', '{ \'exclusion\', \'exclude\' }' },
    { 'Crimson-Police/modules/realplayers/staff.lua', '{ \'rsSuspension\', \'suspend\' }' },
    { 'Crimson-Police/modules/realplayers/staff.lua', 'CP.Restriction(\'volunteerBlock\'' },
}
for _, k in ipairs(kinds) do
    H.ok((Read(k[1]) or ''):find(k[2], 1, true) ~= nil, 'the kind registers: ' .. k[2])
end
for _, gone in ipairs({ 'server:admin:liftMissionBan', 'server:admin:rsLift', 'server:admin:rsClearStrikes' }) do
    local found = false
    for _, f in ipairs({ 'modules/supervisor/missionban.lua', 'modules/realplayers/staff.lua' }) do
        if (Read('Crimson-Police/' .. f) or ''):find(gone, 1, true) then found = true end
    end
    H.ok(not found, gone .. ' is gone (one restrictions action)')
end
local web = Read('Crimson-Police/web/src/admin/components/restrictions.ts') or ''
H.ok(web:find('\'server:admin:restriction\'', 1, true) ~= nil, 'the web sends the one action')
H.ok((Read('Crimson-Police/web/src/layouts/screens.ts') or ''):find('key: \'admin_restrictions\'', 1, true) ~= nil,
    'the Admin UI has the Restrictions screen')
local cfg = Read('Crimson-Police/config/config.lua') or ''
H.ok(cfg:find('restrictionsExtend = true', 1, true) ~= nil, 'Config.AdminUi.restrictionsExtend ships true')

return H

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
    supAction = function(name, key, fn, opts) acts[name] = { key = key, fn = fn, opts = opts, sup = true } end,
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
local RA = acts['server:restriction']
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
--                                     FIN4
-- ============================================================================
-- THE SUPERVISOR'S DEPARTMENT (Department -> Restrictions).

CP.Restriction('deptKind', {
    perm = { lift = 'nobody' },
    maxHours = 24,
    self = true,
    list = function()
        local t = os.time() + 60
        return {
            { citizenid = 'CCC00001', untilAt = t, dept = 'sast', by = 'SUP00001' },
            { citizenid = 'CCC00002', untilAt = t, dept = 'sast', by = 'SUP00002' },
            { citizenid = 'CCC00003', untilAt = t, dept = 'lspd', by = 'SUP00001' },
        }
    end,
    lift = function() return true end,
    sup = {
        permission = function(_, p)
            if p.citizenid == 'CCC00009' then return false, 'err.other_department' end
            return true
        end,
        canLift = function(_, row, actor) return row.by == actor end,
        lift = function(_, p)
            calls[#calls + 1] = { 'supLift', p.citizenid }
            return true, { citizenid = p.citizenid }
        end,
    },
})
local realAccess, realQbx = CP.Access, CP.Qbx
CP.Access = {
    getOfficer = function() return { department = 'sast' } end,
    isAdmin = function(src) return src == 9 end,
}
CP.Qbx = {
    getInfo = function() return { citizenid = 'SUP00001' } end,
}
perms.viewMissionList = true
local sv = CP.Restrictions.forSupervisor(5)
H.eq(#sv.kinds, 1, 'a supervisor sees only the kinds that open to supervisors (def.sup)')
H.eq(#sv.rows, 2, 'and only the rows of his department')
H.ok(sv.dept == 'sast' and sv.kinds[1].canExtend == false, 'his department, never Extend')
local mine, other = sv.rows[1], sv.rows[2]
if mine.citizenid ~= 'CCC00001' then mine, other = other, mine end
H.ok(mine.canLift == true and other.canLift == false, 'Lift only on the row he set himself')
perms.viewMissionList = false
H.eq(select(2, CP.Restrictions.forSupervisor(5)), 'err.no_permission', 'a player who is no supervisor sees nothing')
perms.viewMissionList = true
Config.MissionControls = Config.MissionControls or {}
Config.MissionControls.restrictionsTab = false
H.eq(select(2, CP.Restrictions.forSupervisor(5)), 'err.restrictions_tab_off', 'restrictionsTab = false: no tab')
Config.MissionControls.restrictionsTab = true

local function SupAct(p)
    p.reason = p.reason or 'r'
    return RA.fn({ src = 5, role = 'supervisor', payload = p, reason = p.reason })
end
ok = SupAct({ op = 'lift', kind = 'deptKind', citizenid = 'CCC00001' })
H.ok(ok == true and calls[#calls][1] == 'supLift', 'a supervisor\'s Lift goes to the kind\'s supervisor lift')
ok, e = SupAct({ op = 'extend', kind = 'deptKind', citizenid = 'CCC00001', hours = 1 })
H.eq(e, 'err.no_permission', 'a supervisor never extends')
ok, e = SupAct({ op = 'lift', kind = 'first', citizenid = 'AAA00001' })
H.eq(e, 'err.no_permission', 'nor lifts a kind that is not open to supervisors')
selfCids.CCC00001 = true
ok, e = SupAct({ op = 'lift', kind = 'deptKind', citizenid = 'CCC00001' })
H.eq(e, 'err.self_target', 'the self rule holds for supervisors too')
selfCids.CCC00001 = nil
H.ok(RA.sup == true, 'server:restriction takes supervisors and admins (AdminKit.supAction)')
local okP, eP = RA.opts.permission(5, { kind = 'deptKind', citizenid = 'CCC00009' })
H.ok(okP == false and eP == 'err.other_department', 'a supervisor passes the kind\'s own permission')
H.eq(RA.opts.permission(5, { kind = 'first', citizenid = 'AAA00001' }), false, 'no def.sup: no supervisor')
perms.openAdmin = true
H.eq(RA.opts.permission(9, { kind = 'first' }), true, 'an admin needs openAdmin')
perms.openAdmin = nil
H.eq(RA.opts.permission(9, { kind = 'first' }), false, 'and without it is refused')
CP.Access, CP.Qbx = realAccess, realQbx

-- ============================================================================
--                     THE MODULE LAYOUT AND THE OLD ROUTES
-- ============================================================================

H.eq(Read('Crimson-Police/modules/missionban/server.lua'), nil, 'modules/missionban is gone')
H.ok(Read('Crimson-Police/modules/supervisor/missionban.lua') ~= nil, 'the mission ban is a sub-file of supervisor')
local kinds = {
    { 'Crimson-Police/modules/admin/admin.lua', 'CP.Restriction(\'suspension\'' },
    { 'Crimson-Police/modules/supervisor/missionban.lua', 'CP.Restriction(\'missionBan\'' },
    { 'Crimson-Police/modules/realplayers/staff.lua', '{ \'pairBlock\', \'block\' }' },
    { 'Crimson-Police/modules/realplayers/staff.lua', '{ \'exclusion\', \'exclude\' }' },
    { 'Crimson-Police/modules/realplayers/staff.lua', '{ \'rsSuspension\', \'suspend\' }' },
    { 'Crimson-Police/modules/realplayers/staff.lua', 'CP.Restriction(\'volunteerBlock\'' },
}
for _, k in ipairs(kinds) do
    H.ok((Read(k[1]) or ''):find(k[2], 1, true) ~= nil, 'the kind registers: ' .. k[2])
end
for _, gone in ipairs({
    'server:admin:liftMissionBan',
    'server:sup:liftMissionBan',
    'server:admin:restriction',
    'server:admin:rsLift',
    'server:admin:rsClearStrikes',
}) do
    local found = false
    for _, f in ipairs({
        'modules/supervisor/missionban.lua',
        'modules/supervisor/restrictions.lua',
        'modules/realplayers/staff.lua',
    }) do
        if (Read('Crimson-Police/' .. f) or ''):find(gone, 1, true) then found = true end
    end
    H.ok(not found, gone .. ' is gone (one restrictions action)')
end
local web = Read('Crimson-Police/web/src/admin/components/restrictions.ts') or ''
H.ok(web:find('\'server:restriction\'', 1, true) ~= nil, 'the web sends the one action')
H.ok((Read('Crimson-Police/web/src/layouts/screens.ts') or ''):find('key: \'admin_restrictions\'', 1, true) ~= nil,
    'the Admin UI has the Restrictions screen')
local cfg = Read('Crimson-Police/config/config.lua') or ''
H.ok(cfg:find('restrictionsExtend = true', 1, true) ~= nil, 'Config.AdminUi.restrictionsExtend ships true')

return H

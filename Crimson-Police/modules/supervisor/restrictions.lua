-- CP.Restrictions (server): the one restrictions list. Every kind of restriction an officer or a player can be under

-- CP.Restrictions (server): the one restrictions list. Every kind of restriction an officer or a player can be under
-- (a tablet suspension, a mission ban, a real-suspect pair block, exclusion or suspension, a volunteer's strikes
-- block) is one row with its kind, who it names, until when, who set it and why, on one Admin UI screen
-- (Restrictions), where an admin extends or lifts it, and on the Supervisor UI's Department -> Restrictions tab
-- (Config.MissionControls.restrictionsTab), where a supervisor sees the kinds of his department (def.sup) and lifts
-- what that kind lets him (his own mission bans). Each kind registers itself with CP.Restriction (shared/lib.lua)
-- from the module that owns it and keeps its own rules there: the permission of each step, the longest it may run,
-- the self rule, its own switches (Config.RealPlayers.staff.lift, .volunteer.staffClearStrikes) and its audit rows.
--   admin:getRestrictions               -> { kinds = { { key, maxHours, canLift, canExtend } }, rows, serverTime }
--   sup:getRestrictions                 -> { kinds, rows (each with canLift), dept, serverTime }   his department
--   server:restriction                  { op = 'lift' | 'extend', kind, citizenid, other?, hours?, reason }
--                                       admins: openAdmin, then the kind's key per step; supervisors: lift only,
--                                       the kind's def.sup.permission (a mission ban: missionControls, his own ban)

CP.Restrictions = CP.Restrictions or {}
local R = CP.Restrictions
local Kit = CP.AdminKit
local TAG = 'restrictions'

local AUDIT_ROWS = 500 -- the newest audit rows read for "set by" and "reason" of the kinds that keep neither

local function Kinds() return CP.RestrictionKinds end

local Cid = CP.cidOf
R.cid = Cid

local function Can(src, key)
    if type(key) ~= 'string' then return false end
    return CP.can(src, key, nil, { admin = true }) == true
end

-- Config.AdminUi.restrictionsExtend: the Restrictions screen offers Extend.
local function ExtendOn()
    local ui = type(Config.AdminUi) == 'table' and Config.AdminUi or {}
    return ui.restrictionsExtend ~= false
end
R.extendOn = ExtendOn

local function On(def)
    if type(def.on) ~= 'function' then return true end
    local ok, on = pcall(def.on)
    return ok and on == true
end

-- What this admin's permissions let him do with one kind: canLift, canExtend. forList: also the kind's own switch
-- of lifting (def.liftOn), so the screen offers no Lift its rules would refuse.
local function Rights(src, def, forList)
    local perm = type(def.perm) == 'table' and def.perm or {}
    local lift = type(def.lift) == 'function' and Can(src, perm.lift)
    if lift and forList and type(def.liftOn) == 'function' then lift = def.liftOn() == true end
    local extend = ExtendOn() and type(def.extend) == 'function' and Can(src, perm.extend)
    return lift == true, extend == true
end

-- ============================================================================
--                                   THE LIST
-- ============================================================================

-- "Set by" and "reason" from the audit for the rows whose kind keeps neither (def.audit = { actions, match(row, a) }),
-- one query for the whole list.
local function FillFromAudit(rows)
    local wanted, actions, seen = {}, {}, {}
    for _, row in ipairs(rows) do
        local def = Kinds().byKey[row.kind]
        if def and type(def.audit) == 'table' and (row.by == nil or row.reason == nil) then
            wanted[#wanted + 1] = row
            for _, a in ipairs(def.audit.actions or {}) do
                if not seen[a] then
                    seen[a] = true
                    actions[#actions + 1] = a
                end
            end
        end
    end
    if #wanted == 0 or #actions == 0 then return end
    local marks = {}
    for i = 1, #actions do marks[i] = '?' end
    local ok, list = pcall(
        MySQL.query.await,
        ([[SELECT action, target, actor, new_value, reason FROM cp_audit
        WHERE action IN (%s) ORDER BY id DESC LIMIT %d]]):format(table.concat(marks, ', '), AUDIT_ROWS),
        actions
    )
    if not ok then
        CP.err(TAG, 'reading who set the restrictions failed: %s', tostring(list))
        return
    end
    for _, row in ipairs(wanted) do
        local def = Kinds().byKey[row.kind]
        for _, a in ipairs(type(list) == 'table' and list or {}) do
            local actionOk = false
            for _, name in ipairs(def.audit.actions) do
                if name == a.action then actionOk = true end
            end
            if actionOk and a.target == row.citizenid and (not def.audit.match or def.audit.match(row, a)) then
                row.by = row.by or a.actor
                row.reason = row.reason or a.reason
                break
            end
        end
    end
end

-- A kind whose rows name real-suspect players (def.staffNames): with Config.RealPlayers.staff.names = false they show
-- citizen IDs only, as the real-suspect staff screens do. The admin who set it keeps his name.
local function NamesHidden(row)
    local def = Kinds().byKey[row.kind]
    return def ~= nil and def.staffNames == true and CP.RealPlayers('staff').names == false
end

-- A name for every citizenid the rows name: online from Qbox, else cp_officers, in one query.
local function FillNames(rows)
    local names, missing, seen = {}, {}, {}
    local function want(cid)
        if type(cid) ~= 'string' or cid == '' or seen[cid] then return end
        seen[cid] = true
        local src = CP.srcOf(cid)
        local info = src and CP.Qbx.getInfo and CP.Qbx.getInfo(src)
        if type(info) == 'table' and type(info.name) == 'string' and info.name ~= '' then
            names[cid] = info.name
        else
            missing[#missing + 1] = cid
        end
    end
    for _, row in ipairs(rows) do
        row.hideNames = NamesHidden(row)
        if not row.hideNames then
            want(row.citizenid)
            want(row.other)
        end
        if row.byName == nil then want(row.by) end
    end
    if #missing > 0 then
        local marks = {}
        for i = 1, #missing do marks[i] = '?' end
        local ok, list = pcall(MySQL.query.await,
            ('SELECT citizenid, display_name FROM cp_officers WHERE citizenid IN (%s)'):format(
                table.concat(marks, ', ')
            ), missing)
        for _, r in ipairs(ok and type(list) == 'table' and list or {}) do
            if type(r.display_name) == 'string' and r.display_name ~= '' then names[r.citizenid] = r.display_name end
        end
    end
    for _, row in ipairs(rows) do
        if row.hideNames then
            row.name, row.otherName = nil, nil
        else
            row.name = row.name or names[row.citizenid]
            row.otherName = row.other and (row.otherName or names[row.other]) or nil
        end
        row.hideNames = nil
        if row.byName == nil and row.by then row.byName = names[row.by] end
    end
end

-- Every restriction running now that this admin may see (a kind he may lift or extend), newest end first.
function R.list(src)
    local kinds, rows = {}, {}
    local now = os.time()
    for _, key in ipairs(Kinds().order) do
        local def = Kinds().byKey[key]
        local canLift, canExtend = Rights(src, def, true)
        local canSee = select(1, Rights(src, def)) or canExtend
        if On(def) and canSee then
            kinds[#kinds + 1] = { key = key, maxHours = def.maxHours, canLift = canLift, canExtend = canExtend }
            local ok, list = pcall(def.list)
            if not ok then CP.err(TAG, 'listing the %s rows failed: %s', key, tostring(list)) end
            for _, row in ipairs(ok and type(list) == 'table' and list or {}) do
                local t = tonumber(row.untilAt)
                if type(row) == 'table' and Cid(row.citizenid) and t and t > now then
                    row.kind = key
                    row.untilAt = math.floor(t)
                    rows[#rows + 1] = row
                end
            end
        end
    end
    FillFromAudit(rows)
    FillNames(rows)
    table.sort(rows, function(a, b)
        if a.untilAt ~= b.untilAt then return a.untilAt < b.untilAt end
        return (a.kind .. a.citizenid .. (a.other or '')) < (b.kind .. b.citizenid .. (b.other or ''))
    end)
    return { kinds = kinds, rows = rows, serverTime = now }
end

-- ============================================================================
--                               LIFT AND EXTEND
-- ============================================================================

-- The self rule of a kind (def.self): never one of the admin's own characters. ok | false, errKey.
local function SelfOk(src, def, p)
    if def.self ~= true or src == 0 then return true end
    for _, cid in ipairs({ p.citizenid or false, p.other or false }) do
        if cid then
            local self, err = Kit.isSelf(src, cid)
            if self == nil and err then return false, err end
            if self then return false, 'err.self_target' end
        end
    end
    return true
end

-- One step on one row: the kind's permission for that step, the self rule, the hours within the kind's longest,
-- then the kind's own lift or extend (its own checks, audit row and notices).
function R.run(ctx)
    local p = ctx.payload
    local def = type(p.kind) == 'string' and Kinds().byKey[p.kind] or nil
    if not def then return false, 'err.restriction_kind' end
    local op = p.op
    if op ~= 'lift' and op ~= 'extend' then return false, 'err.restriction_op' end
    local canLift, canExtend = Rights(ctx.src, def)
    if op == 'extend' and not ExtendOn() then return false, 'err.restriction_extend_off' end
    if (op == 'lift' and not canLift) or (op == 'extend' and not canExtend) then return false, 'err.no_permission' end
    local okS, errS = SelfOk(ctx.src, def, p)
    if not okS then return false, errS end
    if op == 'lift' then return def.lift(ctx, p) end
    local hours = math.tointeger(tonumber(p.hours) or 0)
    if not hours or hours < 1 or hours > math.floor(CP.Num(def.maxHours, 24, 1)) then
        return false, 'err.restriction_hours'
    end
    return def.extend(ctx, p, hours)
end

-- ============================================================================
--                         THE SUPERVISOR'S DEPARTMENT
-- ============================================================================

local function IsAdmin(src)
    return tonumber(src) == 0 or (CP.Access and CP.Access.isAdmin and CP.Access.isAdmin(src) == true) == true
end

-- Config.MissionControls.restrictionsTab: the Supervisor UI shows Department -> Restrictions.
local function TabOn()
    local mc = type(Config.MissionControls) == 'table' and Config.MissionControls or {}
    return mc.restrictionsTab ~= false
end
R.tabOn = TabOn

-- The restrictions running now in the viewer's department, of the kinds a supervisor sees (def.sup): each row says
-- whether he may lift it (def.sup.canLift(src, row, actor)). nil, errKey without a department or the switch.
function R.forSupervisor(src)
    if not TabOn() then return nil, 'err.restrictions_tab_off' end
    local okV = CP.can(src, 'viewMissionList')
    if not okV then return nil, 'err.no_permission' end
    local _, officer = CP.Call(TAG, 'Access', 'getOfficer', src)
    local dept = type(officer) == 'table' and officer.department or nil
    if type(dept) ~= 'string' or dept == '' then return nil, 'err.no_permission' end
    local _, info = CP.Call(TAG, 'Qbx', 'getInfo', src)
    local actor = type(info) == 'table' and info.citizenid or nil
    local kinds, rows, now = {}, {}, os.time()
    for _, key in ipairs(Kinds().order) do
        local def = Kinds().byKey[key]
        local sup = type(def.sup) == 'table' and def.sup or nil
        if sup and On(def) then
            kinds[#kinds + 1] = {
                key = key,
                maxHours = def.maxHours,
                canLift = type(sup.lift) == 'function',
                canExtend = false,
            }
            local ok, list = pcall(def.list)
            if not ok then CP.err(TAG, 'listing the %s rows failed: %s', key, tostring(list)) end
            for _, row in ipairs(ok and type(list) == 'table' and list or {}) do
                local t = tonumber(row.untilAt)
                if type(row) == 'table' and Cid(row.citizenid) and t and t > now and row.dept == dept then
                    row.kind = key
                    row.untilAt = math.floor(t)
                    local okL, can = false, false
                    if type(sup.canLift) == 'function' then okL, can = pcall(sup.canLift, src, row, actor) end
                    row.canLift = okL and can == true
                    rows[#rows + 1] = row
                end
            end
        end
    end
    FillFromAudit(rows)
    FillNames(rows)
    table.sort(rows, function(a, b)
        if a.untilAt ~= b.untilAt then return a.untilAt < b.untilAt end
        return (a.kind .. a.citizenid) < (b.kind .. b.citizenid)
    end)
    return { kinds = kinds, rows = rows, dept = dept, serverTime = now }
end

-- A supervisor's step on one row: lift only, and only a kind that lets him (def.sup.lift).
local function RunSupervisor(ctx)
    local p = ctx.payload
    local def = type(p.kind) == 'string' and Kinds().byKey[p.kind] or nil
    if not def then return false, 'err.restriction_kind' end
    if p.op ~= 'lift' and p.op ~= 'extend' then return false, 'err.restriction_op' end
    local sup = type(def.sup) == 'table' and def.sup or nil
    if p.op ~= 'lift' or not sup or type(sup.lift) ~= 'function' then return false, 'err.no_permission' end
    local okS, errS = SelfOk(ctx.src, def, p)
    if not okS then return false, errS end
    return sup.lift(ctx, p)
end

-- Who may send server:restriction: an admin with openAdmin (each step then needs the kind's own key), or a
-- supervisor the kind's def.sup.permission lets lift that row.
local function Permission(src, payload)
    if IsAdmin(src) then return CP.can(src, 'openAdmin', nil, { admin = true }) end
    local def = type(payload.kind) == 'string' and Kinds().byKey[payload.kind] or nil
    local sup = def and type(def.sup) == 'table' and def.sup or nil
    if not sup or type(sup.permission) ~= 'function' then return false, 'err.no_permission' end
    return sup.permission(src, payload)
end

local function RunAny(ctx)
    if ctx.role == 'supervisor' then return RunSupervisor(ctx) end
    return R.run(ctx)
end

if Kit and Kit.callback then
    Kit.callback('admin:getRestrictions', 'openAdmin', function(ctx) return R.list(ctx.src) end)
    Kit.supAction('server:restriction', 'openAdmin', RunAny, {
        reason = true,
        targetRate = { 1, 3000 },
        permission = Permission,
    })
    CP.Net.callback('sup:getRestrictions', function(src) return R.forSupervisor(src) end, { rate = 3 })
end

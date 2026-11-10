-- CP.Restrictions (server): the one restrictions list. Every kind of restriction an officer or a player can be under

-- CP.Restrictions (server): the one restrictions list. Every kind of restriction an officer or a player can be under
-- (a tablet suspension, a mission ban, a real-suspect pair block, exclusion or suspension, a volunteer's strikes
-- block) is one row with its kind, who it names, until when, who set it and why, on one Admin UI screen
-- (Restrictions), where an admin extends or lifts it. Each kind registers itself with CP.Restriction (shared/lib.lua)
-- from the module that owns it and keeps its own rules there: the permission of each step, the longest it may run,
-- the self rule, its own switches (Config.RealPlayers.staffLift, .volunteer.staffClearStrikes) and its audit rows.
--   admin:getRestrictions               -> { kinds = { { key, maxHours, canLift, canExtend } }, rows, serverTime }
--   server:admin:restriction            { op = 'lift' | 'extend', kind, citizenid, other?, hours?, reason }

CP.Restrictions = CP.Restrictions or {}
local R = CP.Restrictions
local Kit = CP.AdminKit
local U = CP.U
local TAG = 'restrictions'

local CITIZENID_MAX = 50
local AUDIT_ROWS = 500 -- the newest audit rows read for "set by" and "reason" of the kinds that keep neither

local function Kinds() return CP.RestrictionKinds end

local function Cid(v)
    if type(v) ~= 'string' then return nil end
    local s = U.trim(v)
    if s == '' or #s > CITIZENID_MAX or not s:match('^[%w_%-]+$') then return nil end
    return s
end
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
        want(row.citizenid)
        want(row.other)
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
        row.name = row.name or names[row.citizenid]
        row.otherName = row.other and (row.otherName or names[row.other]) or nil
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

if Kit and Kit.callback then
    Kit.callback('admin:getRestrictions', 'openAdmin', function(ctx) return R.list(ctx.src) end)
    Kit.action('server:admin:restriction', 'openAdmin', R.run, { reason = true, targetRate = { 1, 3000 } })
end

-- CP.Notices (server): the one notice system. Every short notice officers read on Home -> Announcements is one row
-- of cp_staff_notices with its kind, and goes through one post, one end and one view with a history of ended notices.

-- CP.Notices (server): the one notice system. Every short notice officers read on Home -> Announcements is one row
-- of cp_staff_notices with its kind, and goes through one post, one end and one view with a history of ended notices.
-- Each kind keeps its own audience, limits, alert (toast and sound) and switch (Config.Notices.<kind>):
--   staff       an admin with the officerRecords permission (Leaderboards -> Recognition): every department or the
--               ones he picks; Config.Notices.staff.on; a reason on every post and end (audit noticePost, noticeRemove)
--   department  a supervisor (Supervisor UI -> Department -> Calls & notices): his own department only; the notices
--               Mission control (its switch and grants, CP.DeptControls); perDay a supervisor a day (admins any);
--               audit deptNoticePost, deptNoticeEnd. Saved with by_actor 'sup:<citizenid>'.
-- The banned-word list applies to both; one player posts one notice per Config.Notices.postWait seconds. An admin with
-- officerRecords may end any running notice, a supervisor the running notices of his own department.
--   notices:get           { kind }                            -> the view of that kind (N.view)
--   server:notice:post    { kind, text, days, departments?, reason? } -> { id, kind, department? }
--   server:notice:end     { id, reason? }                     -> { id }

CP.Notices = CP.Notices or {}
local N = CP.Notices
local Kit = CP.AdminKit
local U = CP.U
local TAG = 'notices'

local DEPT_PREFIX = 'sup:'   -- by_actor of a department notice
local CONTROL = 'notices'    -- the Mission control that switches department notices on
local TEXT_CAP = 280         -- characters cp_staff_notices.text is made for
local HISTORY_READ = 200     -- newest ended rows read for one history (then filtered to the viewer's kind)
local ALERTS = { off = true, toast = true, sound = true }

local function Cfg() return type(Config.Notices) == 'table' and Config.Notices or {} end
local function KindCfg(kind)
    local c = Cfg()[kind]
    return type(c) == 'table' and c or {}
end
local function Whole(v, default, lo, hi) return math.floor(CP.Num(v, default, lo, hi)) end

local function Int(v, lo, hi)
    local n = math.tointeger(tonumber(v) or 0.5)
    if not n or n < lo or n > hi then return nil end
    return n
end

local function Call(modName, fnName, ...)
    local m = CP[modName]
    if type(m) ~= 'table' or type(m[fnName]) ~= 'function' then return false, nil end
    local res = table.pack(pcall(m[fnName], ...))
    if not res[1] then
        CP.err(TAG, 'CP.%s.%s failed: %s', modName, fnName, tostring(res[2]))
        return false, nil
    end
    return true, table.unpack(res, 2, res.n)
end

-- The limits of one kind, inside what the table holds.
function N.limits(kind)
    local c = KindCfg(kind)
    return {
        maxLength = Whole(c.maxLength, TEXT_CAP, 1, TEXT_CAP),
        maxDays = Whole(c.maxDays, 30, 1, 90),
        maxRunning = Whole(c.maxRunning, 5, 1, 20),
        perDay = kind == 'department' and Whole(c.perDay, 5, 0) or nil,
        alert = ALERTS[c.alert] and c.alert or 'off',
    }
end

-- 'department' for a supervisor's department notice, else 'staff'.
local function KindOf(byActor)
    return type(byActor) == 'string' and byActor:sub(1, #DEPT_PREFIX) == DEPT_PREFIX and 'department' or 'staff'
end
N.kindOf = KindOf

-- A notice's text: control characters as spaces, trimmed, 1 to maxLen characters, no < or >, no banned word.
-- Returns text | nil, errKey.
function N.text(raw, maxLen)
    if type(raw) ~= 'string' then return nil, 'err.notice_text' end
    local text = U.trim(raw:gsub('[%c]', ' '))
    local n = utf8.len(text)
    if text == '' or not n or n > (maxLen or TEXT_CAP) or text:find('[<>]') then return nil, 'err.notice_text' end
    local okB, banned = Call('Profile', 'hasBannedWord', text)
    if okB and banned then return nil, 'err.notice_banned' end
    return text
end

-- ============================================================================
--                                   THE ROWS
-- ============================================================================

local COLUMNS = [[id, text, departments, by_actor, UNIX_TIMESTAMP(created_at) AS created_ts,
    UNIX_TIMESTAMP(expires_at) AS expires_ts, UNIX_TIMESTAMP(removed_at) AS removed_ts]]

local function Row(r, now)
    local depts = U.jsonField(r.departments)
    local removed = tonumber(r.removed_ts)
    local expires = math.floor(CP.Num(r.expires_ts, 0))
    local ended = nil
    if removed then
        ended = 'removed'
    elseif expires <= now then
        ended = 'expired'
    end
    return {
        id = math.floor(CP.Num(r.id, 0)),
        kind = KindOf(r.by_actor),
        text = tostring(r.text),
        departments = type(depts) == 'table' and #depts > 0 and depts or nil,
        by = tostring(r.by_actor),
        createdAt = math.floor(CP.Num(r.created_ts, 0)),
        expiresAt = expires,
        endedAt = ended and math.floor(removed or expires) or nil,
        ended = ended,
    }
end

local function Read(sql, params, now)
    CP.Db()
    local ok, rows = pcall(MySQL.query.await, sql, params)
    if not ok or type(rows) ~= 'table' then
        CP.err(TAG, 'reading the notices failed: %s', tostring(rows))
        return nil
    end
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = Row(r, now) end
    return out
end

-- Every notice still running, newest first | nil (database error).
function N.running(now)
    now = now or os.time()
    return Read((
        'SELECT %s FROM cp_staff_notices WHERE removed_at IS NULL AND expires_at > FROM_UNIXTIME(?) '
        .. 'ORDER BY id DESC'
    ):format(COLUMNS), { now }, now)
end

-- The newest ended notices (ended early or run out), newest first | nil (database error).
local function Ended(now)
    return Read((
        'SELECT %s FROM cp_staff_notices WHERE removed_at IS NOT NULL OR expires_at <= FROM_UNIXTIME(?) '
        .. 'ORDER BY id DESC LIMIT ?'
    ):format(COLUMNS), { now, HISTORY_READ }, now)
end

-- A department notice of that department (posted by one of its supervisors for it alone).
local function OfDept(n, dept)
    return n.kind == 'department' and type(n.departments) == 'table' and #n.departments == 1
        and n.departments[1] == dept
end

local function Insert(text, depts, expires, byActor, now)
    CP.Db()
    local okI, id = pcall(MySQL.insert.await, [[INSERT INTO cp_staff_notices (text, departments, expires_at, by_actor,
        created_at) VALUES (?, ?, FROM_UNIXTIME(?), ?, FROM_UNIXTIME(?))]],
        { text, depts and json.encode(depts) or nil, expires, byActor, now })
    if not okI or not id then
        CP.err(TAG, 'saving a notice failed: %s', tostring(id))
        return nil
    end
    return math.floor(CP.Num(id, 0))
end

-- ============================================================================
--                                  THE KINDS
-- ============================================================================

local function DC() return CP.DeptControls end

local function ActorOf(src)
    local _, info = Call('Qbx', 'getInfo', src)
    return type(info) == 'table' and info.citizenid or ('player:%d'):format(src)
end

-- Each kind: use(src) -> ok, errKey, role, department; on() (its own switch); audience(payload, dept) -> departments
-- | nil (every department), errKey; mine(notice, dept): a notice this kind's view lists and this kind may end.
local KINDS = {}

KINDS.staff = {
    reason = true,
    audit = { post = 'noticePost', ['end'] = 'noticeRemove' },
    tooMany = 'err.notice_too_many',
    on = function() return KindCfg('staff').on ~= false end,
    use = function(src)
        if not (CP.Access and CP.Access.isAdmin and CP.Access.isAdmin(src)) then return false, 'err.no_permission' end
        if not (CP.Permissions and CP.Permissions.can) then return false, 'err.no_permission' end
        local ok, err = CP.Permissions.can(src, 'officerRecords', nil, { admin = true })
        if not ok then return false, err or 'err.no_permission' end
        return true, nil, src == 0 and 'console' or 'admin', nil
    end,
    audience = function(p)
        if type(p.departments) ~= 'table' or #p.departments == 0 then return nil end
        local out = {}
        for _, d in ipairs(p.departments) do
            if type(d) ~= 'string' or not (type(Config.Departments) == 'table' and Config.Departments[d]) then
                return nil, 'err.unknown_department'
            end
            out[#out + 1] = d
        end
        return out
    end,
    counts = function(n) return n.kind == 'staff' end,
    mine = function() return true end,
}

KINDS.department = {
    reason = false,
    audit = { post = 'deptNoticePost', ['end'] = 'deptNoticeEnd' },
    tooMany = 'err.dept_notice_too_many',
    -- its switch is the notices Mission control, which use checks
    on = function() return true end,
    use = function(src)
        local dc = DC()
        if not (dc and dc.canChange) then return false, 'err.module_unavailable' end
        return dc.canChange(src, CONTROL, nil)
    end,
    audience = function(_, dept) return { dept } end,
    counts = function(n, dept) return OfDept(n, dept) end,
    mine = function(n, dept) return OfDept(n, dept) end,
}
N.KINDS = KINDS

-- Notices that player posted today (the department kind's per day; the Your controls today card).
function N.usedToday(src) return Kit.dailyCount(KINDS.department.audit.post, { actor = ActorOf(src) }) end

local function Register()
    local dc = DC()
    if not (dc and dc.register) then return false end
    dc.register(CONTROL, {
        kind = 'action',
        bounded = false,
        viewExtra = function()
            local l = N.limits('department')
            return { maxLength = l.maxLength, perDay = l.perDay }
        end,
        usedToday = function(src) return N.usedToday(src) end,
    })
    return true
end
Register()
N.register = Register

-- ============================================================================
--                                   THE VIEW
-- ============================================================================

local function Short(dept)
    local d = type(Config.Departments) == 'table' and Config.Departments[dept] or nil
    return type(d) == 'table' and d.short or dept
end

-- What a notices card shows for one kind: nil, errKey when that player may not use it, else { kind, canPost,
-- department?, short?, reason, maxLength, maxDays, maxRunning, perDay?, usedToday?, alert, running, history }.
-- staff lists every running notice (an admin may end any); department only his department's own.
function N.view(src, kind)
    local n = math.tointeger(tonumber(src) or -1)
    if not n or n < 0 then return nil, 'err.no_permission' end
    local def = KINDS[kind]
    if not def then return nil, 'err.notice_kind' end
    local ok, err, role, dept = def.use(n)
    if not ok then return nil, err end
    local now = os.time()
    local running, ended = N.running(now), Ended(now)
    if not running or not ended then return nil, 'err.internal' end
    local l = N.limits(kind)
    local view = {
        kind = kind,
        canPost = def.on(),
        department = dept,
        short = dept and Short(dept) or nil,
        reason = def.reason,
        maxLength = l.maxLength,
        maxDays = l.maxDays,
        maxRunning = l.maxRunning,
        alert = l.alert,
        running = {},
        history = {},
        counted = 0,
    }
    if kind == 'department' and role == 'supervisor' then
        view.perDay = l.perDay
        view.usedToday = Kit.dailyCount(def.audit.post, { actor = ActorOf(n) }) or 0
    end
    for _, r in ipairs(running) do
        if def.mine(r, dept) then view.running[#view.running + 1] = r end
        if def.counts(r, dept) then view.counted = view.counted + 1 end
    end
    local shown = Whole(Cfg().historyShown, 20, 0, 100)
    for _, r in ipairs(ended) do
        if #view.history >= shown then break end
        if def.mine(r, dept) then view.history[#view.history + 1] = r end
    end
    return view
end

-- ============================================================================
--                                 POST AND END
-- ============================================================================

-- The alert of a kind: a toast (and with 'sound' the notice tone) to every on-duty officer of its departments
-- (nil = every department) but the one who posted it. Returns how many got it.
local function Alert(kind, text, depts, poster)
    local alert = N.limits(kind).alert
    if alert == 'off' or not (CP.Access and CP.Access.getOfficer) then return 0 end
    local want = nil
    if depts then
        want = {}
        for _, d in ipairs(depts) do want[d] = true end
    end
    local sent = 0
    for _, s in ipairs(GetPlayers and GetPlayers() or {}) do
        local src = U.toSrc(s)
        if src and src ~= poster and (not CP.Access.maybeOfficer or CP.Access.maybeOfficer(src)) then
            local o = CP.Access.getOfficer(src)
            if o and (not want or want[o.department]) then
                CP.notify(src, 'info', 'notices.alert', { text = text }, {
                    title = 'notices.alert_title.' .. kind,
                    sound = alert == 'sound' or nil,
                })
                sent = sent + 1
            end
        end
    end
    return sent
end
N._alert = Alert

local function Post(ctx)
    local p = ctx.payload
    local def = KINDS[p.kind]
    if not def then return false, 'err.notice_kind' end
    local _, _, role, dept = def.use(ctx.src)
    if not def.on() then return false, 'err.notice_kind_off' end
    if p.kind == 'department' and type(dept) ~= 'string' then return false, 'err.no_permission' end
    local l = N.limits(p.kind)
    local text, errT = N.text(p.text, l.maxLength)
    if not text then return false, errT end
    local days = Int(p.days, 1, l.maxDays)
    if not days then return false, 'err.notice_expiry' end
    if def.reason and not ctx.reason then
        local _, errR = Kit.reason(p.reason, false)
        return false, errR or 'err.reason_required'
    end
    local depts, errA = def.audience(p, dept)
    if errA then return false, errA end
    local wait = Whole(Cfg().postWait, 60, 0, 3600)
    if wait > 0 and not CP.Net.rateOk(ctx.src, 'notice:post', 1, wait * 1000) then return false, 'err.rate_limited' end
    if l.perDay and role == 'supervisor' then
        local used = Kit.dailyCount(def.audit.post, { actor = ctx.actor })
        if used == nil then return false, 'err.internal' end
        if used >= l.perDay then return false, 'err.notice_per_day' end
    end
    local now = os.time()
    local running = N.running(now)
    if not running then return false, 'err.internal' end
    local count = 0
    for _, r in ipairs(running) do
        if def.counts(r, dept) then count = count + 1 end
    end
    if count >= l.maxRunning then return false, def.tooMany end
    local by = p.kind == 'department' and (DEPT_PREFIX .. tostring(ctx.actor)) or tostring(ctx.actor)
    local id = Insert(text, depts, now + days * 86400, U.clip(by, 50), now)
    if not id then return false, 'err.internal' end
    ctx.audit(def.audit.post, ('notice:%d'):format(id), nil, U.clip(text, 64), { category = 'board' })
    Call('Leaderboard', 'invalidate')
    Alert(p.kind, text, depts, ctx.src)
    return true, { id = id, kind = p.kind, department = p.kind == 'department' and dept or nil }
end

-- Ends a running notice: an admin with officerRecords any (a reason), a supervisor his own department's.
local function End(ctx)
    local p = ctx.payload
    local id = Int(p.id, 1, 2147483647)
    if not id then return false, 'err.invalid_payload' end
    local now = os.time()
    local running = N.running(now)
    if not running then return false, 'err.internal' end
    local row = nil
    for _, r in ipairs(running) do
        if r.id == id then row = r end
    end
    local path = nil
    if KINDS.staff.use(ctx.src) then
        path = 'staff'
    elseif row and row.kind == 'department' then
        local okD, _, _, dept = KINDS.department.use(ctx.src)
        if okD and OfDept(row, dept) then path = 'department' end
    end
    if not path then return false, 'err.dept_notice_unknown' end
    if not row then return false, 'err.notice_unknown' end
    if KINDS[path].reason and not ctx.reason then
        local _, errR = Kit.reason(p.reason, false)
        return false, errR or 'err.reason_required'
    end
    local okK, errK = Kit.cas(
        'UPDATE cp_staff_notices SET removed_at = FROM_UNIXTIME(?) WHERE id = ? AND removed_at IS NULL', { now, id })
    if not okK then return false, errK end
    ctx.audit(KINDS[path].audit['end'], ('notice:%d'):format(id), nil, 'removed', { category = 'board' })
    Call('Leaderboard', 'invalidate')
    return true, { id = id }
end

-- Either kind's own permission lets the request in; Post and End then hold it to that kind's rules.
local function AnyUse(src, payload)
    local def = type(payload) == 'table' and KINDS[payload.kind] or nil
    if def then return def.use(src) end
    if KINDS.staff.use(src) then return true end
    return KINDS.department.use(src)
end

if Kit and Kit.supAction then
    Kit.supAction('server:notice:post', 'missionControls', Post, {
        reason = 'optional',
        category = 'board',
        permission = function(src, payload)
            if not (type(payload) == 'table' and KINDS[payload.kind]) then return false, 'err.notice_kind' end
            return AnyUse(src, payload)
        end,
    })
    Kit.supAction('server:notice:end', 'missionControls', End, {
        reason = 'optional',
        category = 'board',
        permission = function(src) return AnyUse(src, nil) end,
    })
end

CP.Net.callback('notices:get', function(src, args)
    return N.view(src, type(args) == 'table' and args.kind or nil)
end, { rate = 3 })

-- CP.Corrections (server): an admin's corrections to officers' records (adjustments, bulk void and restore, retire,
-- reset progression, record move, XP check, restore run, void kinds, flag by hand, badges, streaks, goals, staff
-- notices) and the run history an admin reads. Every action goes through CP.AdminKit.

CP.Corrections = CP.Corrections or {}
local Corr = CP.Corrections
local U = CP.U
local TAG = 'corrections'

local ADJUST_MAX = 10000         -- points per adjustment, either way (the column holds 32767)
local RUNS_PAGE_MAX = 50         -- rows per page of an officer's run history
local PREVIEW_ROWS = 50          -- rows and officers a preview lists (the totals cover every row)
local GOAL_LINK_S = 120          -- a goal reward written this soon after a run was completed by that run
local NOTICE_MAX = 280           -- characters of a staff notice
local NOTICE_DAYS = 30           -- a staff notice runs 30 days at most
local NOTICES_ACTIVE = 5         -- staff notices running at once
local NOTICE_EVERY_MS = 60000    -- one notice per admin per minute
local TABLES = { L = 'cp_mission_runs', A = 'cp_mission_runs_archive' }
local VOID_KINDS = { strike = true, correction = true }
local VOID_JOBS = { bulkVoid = true, retire = true }
local JOB_KINDS = {
    'bulkVoid',
    'retire',
    'restoreBatch',
    'recordMove',
    'recordMoveUndo',
    'seasonReopen',
    'reopenUndo',
    'recheckBadges',
}

local Kit = CP.AdminKit

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function Db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

local function Num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n then return default end
    return n
end

-- A whole number in [lo, hi], or nil.
local function Int(v, lo, hi)
    local n = tonumber(v)
    if not n or n ~= n or n % 1 ~= 0 then return nil end
    n = math.tointeger(n)
    if not n or n < (lo or math.mininteger) or n > (hi or math.maxinteger) then return nil end
    return n
end

local function Has(modName, fnName)
    local m = CP[modName]
    return type(m) == 'table' and type(m[fnName]) == 'function'
end

local function Call(modName, fnName, ...)
    if not Has(modName, fnName) then return false end
    local res = table.pack(pcall(CP[modName][fnName], ...))
    if not res[1] then
        CP.err(TAG, 'CP.%s.%s failed: %s', modName, fnName, tostring(res[2]))
        return false
    end
    return true, table.unpack(res, 2, res.n)
end

local function Query(sql, params)
    Db()
    local ok, res = pcall(MySQL.query.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'query failed: %s', tostring(res))
        return nil
    end
    return type(res) == 'table' and res or {}
end

local function Single(sql, params)
    Db()
    local ok, res = pcall(MySQL.single.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'query failed: %s', tostring(res))
        return nil
    end
    return type(res) == 'table' and res or nil
end

local function Update(sql, params)
    Db()
    local ok, res = pcall(MySQL.update.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'update failed: %s', tostring(res))
        return nil
    end
    return math.floor(Num(res, 0))
end

local function Scalar(sql, params)
    Db()
    local ok, res = pcall(MySQL.scalar.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'query failed: %s', tostring(res))
        return nil
    end
    return res
end

local function Marks(n)
    local t = {}
    for i = 1, n do t[i] = '?' end
    return table.concat(t, ', ')
end

local function ValidCid(v)
    return type(v) == 'string' and #v >= 1 and #v <= 50 and v:match('^[%w_%-]+$') ~= nil
end

local function ToSrc(v)
    local n = math.tointeger(tonumber(v) or -1)
    if not n or n < 0 then return nil end
    return n
end

-- Who acted, as cp_audit names them: the citizenid, 'console' or 'player:<src>'.
local function ActorId(src)
    local n = ToSrc(src) or 0
    if n == 0 then return 'console' end
    local ok, info = Call('Qbx', 'getInfo', n)
    if ok and type(info) == 'table' and type(info.citizenid) == 'string' then return info.citizenid end
    return ('player:%d'):format(n)
end

local function OnlineSrc(citizenid)
    if not ValidCid(citizenid) then return nil end
    local ok, s = Call('Qbx', 'getByCitizenId', citizenid)
    local n = ok and ToSrc(s) or nil
    if n and n > 0 then return n end
    return nil
end

local function Clip(s, n)
    if s == nil then return nil end
    s = tostring(s)
    if (utf8.len(s) or #s) <= n then return s end
    local cut = utf8.offset(s, n + 1)
    return cut and s:sub(1, cut - 1) or s:sub(1, n)
end

local function Officer(citizenid)
    if not ValidCid(citizenid) then return nil end
    return Single([[SELECT citizenid, display_name, callsign, department, xp, UNIX_TIMESTAMP(retired_at) AS retired_ts,
        retire_batch, board_excluded, license FROM cp_officers WHERE citizenid = ?]], { citizenid })
end

local function Invalidate(citizenid, kind, missionId)
    Call('Leaderboard', 'invalidate')
    if Kit then Kit.changed(kind or 'correction', citizenid, missionId) end
end

local function Cfg(key, default)
    local c = Config.AdminControl
    -- not `and c[key] or nil`: a switch set to false must read as false
    local v = nil
    if type(c) == 'table' then v = c[key] end
    if v == nil then return default end
    return v
end

-- 'YYYY-MM-DD' (server time, the start of that day) or a unix time; plusDay: the start of the next day.
local function DateArg(v, plusDay)
    if type(v) == 'number' then return Int(v, 0, 2147483647) end
    if type(v) ~= 'string' then return nil end
    local y, m, d = v:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)$')
    if not y then return Int(v, 0, 2147483647) end
    return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d) + (plusDay and 1 or 0), hour = 0 })
end

-- 'L12' (cp_mission_runs) / 'A12' (the archive) -> live ids, archive ids.
local function SplitIds(ids)
    local out = { L = {}, A = {} }
    for _, key in ipairs(ids) do
        local t, id = tostring(key):match('^([LA])(%d+)$')
        if t then out[t][#out[t] + 1] = math.tointeger(tonumber(id)) end
    end
    return out
end

-- The officer is busy with something an admin must not pull the rows from under: a run, a unit's ready check or a
-- Cross-Department Mission. errKey | nil.
local function OfficerBusy(citizenid)
    local s = OnlineSrc(citizenid)
    if not s then return nil end
    local okR, run = Call('Runs', 'getBySrc', s)
    if okR and run then return 'err.officer_on_run' end
    local okU, unit = Call('Units', 'unitOf', s)
    if okU and type(unit) == 'table' and unit.locked then return 'err.officer_in_ready_check' end
    local okO, op = Call('Operations', 'active')
    if okO and type(op) == 'table' and type(op.participants) == 'table' then
        for _, p in ipairs(op.participants) do
            if type(p) == 'table' and p.src == s then return 'err.officer_on_operation' end
        end
    end
    return nil
end
Corr._officerBusy = OfficerBusy

-- ============================================================================
--                               BADGE OVERRIDES
-- ============================================================================
-- cp_badge_overrides: a grant is kept whatever the rows say, a block is never given. CheckBadges (scoring) and the
-- weekly recognition job (leaderboard) both respect them.

local function SetOverride(citizenid, badgeId, mode, actor, reason)
    return Update([[INSERT INTO cp_badge_overrides (citizenid, badge_id, mode, by_actor, reason, created_at)
        VALUES (?, ?, ?, ?, ?, FROM_UNIXTIME(?)) ON DUPLICATE KEY UPDATE mode = VALUES(mode),
        by_actor = VALUES(by_actor), reason = VALUES(reason), created_at = VALUES(created_at)]],
        { citizenid, badgeId, mode, Clip(actor, 50), Clip(reason, 255), os.time() }) ~= nil
end

-- Gives a badge and keeps it (opts.earnedAt: the badge's date, e.g. the end of a recounted week).
function Corr.grantBadge(src, citizenid, badgeId, reason, opts)
    opts = type(opts) == 'table' and opts or {}
    if not ValidCid(citizenid) or type(badgeId) ~= 'string' or badgeId == '' then return false end
    Update('INSERT IGNORE INTO cp_badges (citizenid, badge_id, earned_at) VALUES (?, ?, FROM_UNIXTIME(?))',
        { citizenid, U.clip(badgeId, 40), Int(opts.earnedAt) or os.time() })
    return SetOverride(citizenid, badgeId, 'grant', ActorId(src), reason)
end

-- Takes a badge away and keeps it away.
function Corr.revokeBadge(src, citizenid, badgeId, reason)
    if not ValidCid(citizenid) or type(badgeId) ~= 'string' or badgeId == '' then return false end
    Update('DELETE FROM cp_badges WHERE citizenid = ? AND badge_id = ?', { citizenid, badgeId })
    return SetOverride(citizenid, badgeId, 'block', ActorId(src), reason)
end

-- ============================================================================
--                             THE BULK VOID ENGINE
-- ============================================================================
-- Rows are chosen by a filter in both run tables, voided as one batch (void_batch = the job id, kind 'correction' by
-- default: never a strike) and restored as one batch. The officers' XP, badges and boards are worked out again from
-- the rows at the end of every job and of a job a restart resumed.

-- A filter from the NUI: { citizenid?, department?, missionType?, missionId?, operationId?, from, to, allTime?,
-- includeAwards? } -> the clean filter | nil, errKey. from and to: dates (YYYY-MM-DD) or unix times, both days
-- included; allTime: every row.
local function NormFilter(f)
    if type(f) ~= 'table' then return nil, 'err.invalid_payload' end
    local out = { includeAwards = f.includeAwards == true }
    if f.citizenid ~= nil and f.citizenid ~= '' then
        if not ValidCid(f.citizenid) then return nil, 'err.invalid_citizenid' end
        out.citizenid = f.citizenid
    end
    if f.department ~= nil and f.department ~= '' then
        if type(f.department) ~= 'string'
            or not (type(Config.Departments) == 'table' and Config.Departments[f.department]) then
            return nil, 'err.unknown_department'
        end
        out.department = f.department
    end
    if f.missionType ~= nil and f.missionType ~= '' then
        local t = f.missionType
        if type(t) ~= 'string' or not ((Config.MissionTypes or {})[t] or t == 'manual_award' or t == 'goal') then
            return nil, 'err.invalid_type'
        end
        out.missionType = t
    end
    if f.missionId ~= nil and f.missionId ~= '' then
        if type(f.missionId) ~= 'string' or #f.missionId > 40 or not f.missionId:match('^[%w_%-]+$') then
            return nil, 'err.invalid_mission'
        end
        out.missionId = f.missionId
    end
    if f.operationId ~= nil and f.operationId ~= '' then
        out.operationId = Int(f.operationId, 1, 2147483647)
        if not out.operationId then return nil, 'err.invalid_payload' end
    end
    if f.allTime == true then
        out.from, out.to = 0, os.time() + 86400
    else
        out.from, out.to = DateArg(f.from, false), DateArg(f.to, type(f.to) == 'string')
        if not out.from or not out.to or out.to <= out.from then return nil, 'err.invalid_window' end
    end
    return out
end
Corr._normFilter = NormFilter

local CANDIDATE_COLS = [[id, run_uuid, citizenid, mission_type, mission_id, state, flagged, final_points, cash_status,
    department, UNIX_TIMESTAMP(created_at) AS created_ts, JSON_VALUE(breakdown, '$.cash.amount') AS cash_amount]]

-- Every row the filter picks (not voided), both tables, oldest first: { key = 'L12', ... }.
local function Candidates(f)
    local where, params =
        { 'voided = 0', 'created_at >= FROM_UNIXTIME(?)', 'created_at < FROM_UNIXTIME(?)' }, { f.from, f.to }
    for col, key in pairs({
        citizenid = 'citizenid',
        department = 'department',
        mission_type = 'missionType',
        mission_id = 'missionId',
        operation_id = 'operationId',
    }) do
        if f[key] ~= nil then
            where[#where + 1] = col .. ' = ?'
            params[#params + 1] = f[key]
        end
    end
    if not f.includeAwards then where[#where + 1] = 'mission_type NOT IN (\'manual_award\', \'goal\')' end
    local out = {}
    for _, t in ipairs({ 'L', 'A' }) do
        local rows = Query(
            ('SELECT %s FROM %s WHERE %s ORDER BY id'):format(CANDIDATE_COLS, TABLES[t], table.concat(where, ' AND ')),
            params)
        if not rows then return nil end
        for _, r in ipairs(rows) do
            r.key = t .. tostring(math.floor(Num(r.id, 0)))
            r.archived = t == 'A'
            out[#out + 1] = r
        end
    end
    return out
end

-- The run ids any of src's characters took part in (live and archived) and the run src is on now.
local function OwnRuns(src)
    local n = ToSrc(src) or 0
    local out = {}
    if n == 0 then return out end
    local okC, cids = Call('Access', 'selfCitizenids', n)
    cids = okC and type(cids) == 'table' and cids or {}
    local own = ActorId(n)
    local have = false
    for _, c in ipairs(cids) do if c == own then have = true end end
    if not have and ValidCid(own) then cids[#cids + 1] = own end
    if #cids > 0 then
        for _, t in ipairs({ 'cp_mission_runs', 'cp_mission_runs_archive' }) do
            for _, r in
                ipairs(
                    Query(('SELECT DISTINCT run_uuid FROM %s WHERE citizenid IN (%s)'):format(t, Marks(#cids)), cids)
                        or {}
                )
            do
                out[r.run_uuid] = true
            end
        end
    end
    local okR, run = Call('Runs', 'getBySrc', n)
    if okR and type(run) == 'table' and run.id then out[run.id] = true end
    return out
end

-- The rows a filter picks, without the admin's own: rows, ids (keys), the number left out.
local function Pick(src, f)
    local rows = Candidates(f)
    if not rows then return nil end
    local own = OwnRuns(src)
    local out, ids, excluded = {}, {}, 0
    for _, r in ipairs(rows) do
        if own[r.run_uuid] then
            excluded = excluded + 1
        else
            out[#out + 1] = r
            ids[#ids + 1] = r.key
        end
    end
    return out, ids, excluded
end

local function Counted(r)
    return not U.truthy(r.flagged) and (r.state == 'completed' or r.state == 'failed')
end

-- What a void of these rows does: rows, officers (XP before and after), points and the cash still held or pending.
local function VoidEffect(rows)
    local byCid, order = {}, {}
    local points, held, archived = 0, 0, 0
    for _, r in ipairs(rows) do
        local cid = tostring(r.citizenid)
        local o = byCid[cid]
        if not o then
            o = { citizenid = cid, rows = 0, points = 0, held = 0 }
            byCid[cid] = o
            order[#order + 1] = cid
        end
        o.rows = o.rows + 1
        if Counted(r) then
            local pts = math.floor(Num(r.final_points, 0))
            o.points = o.points + pts
            points = points + pts
        end
        if r.cash_status == 'held' or r.cash_status == 'pending' then
            local c = math.floor(Num(r.cash_amount, 0))
            o.held = o.held + c
            held = held + c
        end
        if r.archived then archived = archived + 1 end
    end
    local officers = {}
    for i, cid in ipairs(order) do
        local o = byCid[cid]
        if i <= PREVIEW_ROWS then
            local okX, derived, _, sum = Call('Scoring', 'derivedXp', cid)
            if okX and derived then
                o.xpBefore = derived
                o.xpAfter = math.max(0, (sum or derived) - o.points)
            end
            local row = Officer(cid)
            o.name = row and row.display_name or cid
        end
        officers[#officers + 1] = o
    end
    local list = {}
    for i = 1, math.min(PREVIEW_ROWS, #rows) do
        local r = rows[i]
        list[i] = {
            key = r.key,
            id = math.floor(Num(r.id, 0)),
            citizenid = r.citizenid,
            missionLabel = Has('Admin', 'missionLabel') and CP.Admin.missionLabel(r.mission_id) or r.mission_id,
            missionType = r.mission_type,
            state = r.state,
            points = math.floor(Num(r.final_points, 0)),
            cashStatus = r.cash_status,
            archived = r.archived,
            createdAt = math.floor(Num(r.created_ts, 0)),
        }
    end
    return {
        total = #rows,
        points = points,
        held = held,
        archived = archived,
        officers = officers,
        rows = list,
    }
end

-- Writes one cp_audit line per row of a batch in one statement (no webhook: the job's summary line posts).
local function BatchAudit(job, action, rows, new)
    if #rows == 0 then return end
    local actor = tostring(job.actor or 'console')
    local role = actor == 'console' and 'console' or 'admin'
    local reason = Clip(job.detail and job.detail.reason or job.reason, 255)
    local ident = job.detail and job.detail.ident or nil
    local values, params = {}, {}
    for _, r in ipairs(rows) do
        local cols = {
            Clip(actor, 50),
            role,
            'flags',
            action,
            Clip(('#%s %s'):format(tostring(r.id), tostring(r.citizenid)), 64),
            Clip(r.old or r.state, 64),
            Clip(new, 64),
            reason,
            ident,
        }
        local marks = {}
        for i = 1, 9 do
            -- a missing value is written as NULL in the statement (a parameter list never has holes)
            if cols[i] == nil then
                marks[i] = 'NULL'
            else
                marks[i] = '?'
                params[#params + 1] = cols[i]
            end
        end
        values[#values + 1] = '(' .. table.concat(marks, ', ') .. ')'
    end
    Update(
        ([[INSERT INTO cp_audit (actor, role, category, action, target, old_value, new_value, reason, actor_ident)
        VALUES %s]]):format(table.concat(values, ', ')),
        params
    )
end

local function FireRows(hook, ids)
    if not (CP.Hooks and CP.Hooks.fire) then return end
    for _, id in ipairs(ids) do CP.Hooks.fire(hook, id) end
end

-- J batch: void up to 50 rows (keys) as kind with this job's id as the batch.
local function VoidBatch(job, keys)
    local split = SplitIds(keys)
    local kind = VOID_KINDS[job.detail.kind] and job.detail.kind or 'correction'
    for _, t in ipairs({ 'L', 'A' }) do
        local ids = split[t]
        if #ids > 0 then
            local rows = Query(
                ('SELECT id, citizenid, state, cash_status FROM %s WHERE id IN (%s) AND voided = 0'):format(
                    TABLES[t],
                    Marks(#ids)
                ), ids)
            if not rows then return false, 'select failed' end
            if #rows > 0 then
                local live = {}
                for i, r in ipairs(rows) do live[i] = math.floor(Num(r.id, 0)) end
                local params = { kind, job.id }
                for _, id in ipairs(live) do params[#params + 1] = id end
                -- the cash status at void time is kept, so a restore can undo a forfeit this batch caused
                local n = Update(
                    ([[UPDATE %s SET voided = 1, void_kind = ?, void_batch = ?,
                    breakdown = IF(JSON_VALID(breakdown), JSON_REMOVE(JSON_SET(breakdown, '$.cash.beforeVoid',
                    cash_status), '$.xpCounted'), breakdown)
                    WHERE id IN (%s) AND voided = 0]]):format(TABLES[t], Marks(#live)),
                    params
                )
                if n == nil then return false, 'update failed' end
                BatchAudit(job, 'voidRun', rows, kind == 'correction' and 'voided:correction' or 'voided')
                if t == 'L' then FireRows('row:voided', live) end
            end
        end
    end
    return true
end

-- The officers a job's rows belong to (saved in the job so a resumed job knows them).
local function JobOfficers(job)
    local list = type(job.detail.cids) == 'table' and job.detail.cids or {}
    return list
end

local function Recompute(citizenid, strike)
    Call('Scoring', 'syncXp', citizenid)
    Call('Scoring', 'recheckBadges', citizenid)
    if strike then Call('AntiCheat', 'onVoided', citizenid) end
    if Kit then Kit.changed('correction', citizenid) end
end

local function VoidFinish(job)
    for _, cid in ipairs(JobOfficers(job)) do Recompute(cid, job.detail.kind == 'strike') end
    Call('Leaderboard', 'invalidate')
end

-- J batch: restore up to 50 rows of a batch. Rows the forfeiture job forfeited because of this batch (no money had
-- moved: forfeited, nothing paid, held or pending at void time) are pending again, so they pay exactly once.
local function RestoreBatch(job, keys)
    local split = SplitIds(keys)
    local batch = job.detail.batchId
    for _, t in ipairs({ 'L', 'A' }) do
        local ids = split[t]
        if #ids > 0 then
            local params = { batch }
            for _, id in ipairs(ids) do params[#params + 1] = id end
            local rows = Query(
                ([[SELECT id, citizenid, state, flagged, cash_status, cash_paid,
                JSON_VALUE(breakdown, '$.cash.beforeVoid') AS before_void FROM %s
                WHERE void_batch = ? AND voided = 1 AND id IN (%s)]]):format(TABLES[t], Marks(#ids)),
                params
            )
            if not rows then return false, 'select failed' end
            if #rows > 0 then
                local restore, unforfeit, release = {}, {}, {}
                for _, r in ipairs(rows) do
                    local id = math.floor(Num(r.id, 0))
                    restore[#restore + 1] = id
                    if t == 'L' and r.cash_status == 'forfeited' and math.floor(Num(r.cash_paid, 0)) == 0
                        and (r.before_void == 'held' or r.before_void == 'pending') then
                        unforfeit[#unforfeit + 1] = id
                    end
                    if t == 'L' and not U.truthy(r.flagged)
                        and (r.cash_status == 'held' or r.cash_status == 'pending') then
                        release[#release + 1] = id
                    end
                end
                if #unforfeit > 0 then
                    local n = Update(
                        ([[UPDATE cp_mission_runs SET cash_status = 'pending',
                        breakdown = IF(JSON_VALID(breakdown), JSON_SET(breakdown, '$.cash.status', 'pending'), breakdown)
                        WHERE id IN (%s) AND cash_status = 'forfeited' AND cash_paid = 0]]):format(
                            Marks(#unforfeit)
                        ),
                        unforfeit
                    )
                    if n == nil then return false, 'unforfeit failed' end
                end
                local p2 = { batch }
                for _, id in ipairs(restore) do p2[#p2 + 1] = id end
                local n = Update(
                    ([[UPDATE %s SET voided = 0, void_kind = NULL, void_batch = NULL,
                    breakdown = IF(JSON_VALID(breakdown), IF(flagged = 0, JSON_SET(JSON_REMOVE(breakdown,
                    '$.cash.beforeVoid'), '$.xpCounted', 1), JSON_REMOVE(breakdown, '$.cash.beforeVoid')), breakdown)
                    WHERE void_batch = ? AND voided = 1 AND id IN (%s)]]):format(
                        TABLES[t],
                        Marks(#restore)
                    ),
                    p2
                )
                if n == nil then return false, 'update failed' end
                BatchAudit(job, 'restoreRow', rows, 'restored')
                if t == 'L' then
                    FireRows('row:restored', restore)
                    -- held item rewards of the rows are given again (CP.Rewards listens to row:approved)
                    FireRows('row:approved', restore)
                    FireRows('row:forfeitUndone', unforfeit)
                    for _, id in ipairs(unforfeit) do release[#release + 1] = id end
                    for _, id in ipairs(release) do Call('Cash', 'release', id) end
                end
            end
        end
    end
    return true
end

local function RestoreFinish(job)
    for _, cid in ipairs(JobOfficers(job)) do Recompute(cid, false) end
    Call('Leaderboard', 'invalidate')
end

-- The rows still voided by a batch (both tables), and their officers.
local function BatchRows(batchId)
    local keys, cids, seen = {}, {}, {}
    for _, t in ipairs({ 'L', 'A' }) do
        for _, r in
            ipairs(Query(
                ('SELECT id, citizenid FROM %s WHERE void_batch = ? AND voided = 1 ORDER BY id'):format(TABLES[t]),
                { batchId }
            ) or {})
        do
            keys[#keys + 1] = t .. tostring(math.floor(Num(r.id, 0)))
            local cid = tostring(r.citizenid)
            if not seen[cid] then
                seen[cid] = true
                cids[#cids + 1] = cid
            end
        end
    end
    return keys, cids
end

local function OfficersOf(rows)
    local out, seen = {}, {}
    for _, r in ipairs(rows) do
        local cid = tostring(r.citizenid)
        if not seen[cid] then
            seen[cid] = true
            out[#out + 1] = cid
        end
    end
    return out
end

local function Ident(src)
    local n = ToSrc(src) or 0
    if n == 0 then return nil end
    local ok, lic = Call('Access', 'licenseOfSrc', n)
    return ok and type(lic) == 'string' and lic or nil
end

-- Starts a void job over the rows (keys) of a filter: ok, jobId | false, errKey.
local function StartVoid(ctx, jobKind, rows, ids, filter, kind, extra)
    local detail = { kind = kind, cids = OfficersOf(rows), reason = ctx.reason, ident = Ident(ctx.src) }
    for k, v in pairs(extra or {}) do detail[k] = v end
    return Kit.startJob({
        id = extra and extra.jobId or nil,
        kind = jobKind,
        src = ctx.src,
        reason = ctx.reason,
        ids = ids,
        filter = filter,
        detail = detail,
    })
end

local function FilterText(f)
    local parts = {}
    for _, k in ipairs({ 'citizenid', 'department', 'missionType', 'missionId', 'operationId' }) do
        if f[k] ~= nil then parts[#parts + 1] = tostring(f[k]) end
    end
    parts[#parts + 1] = f.from and f.from > 0 and os.date('%Y-%m-%d', f.from) or 'all'
    return Clip(table.concat(parts, ' '), 64)
end

-- ============================================================================
--                              RECORD MOVE (C14)
-- ============================================================================
-- A re-created character's history moves to the player's new citizenid as one batch: run rows (live and archived),
-- the officer record, badges and overrides, commendations, disputes and unfinished item rewards. Rows keep their
-- department. Undo moves exactly the same rows back while the new character has no rows of its own since.

local MOVE_TABLES = {
    { table = 'cp_badges', key = 'badges', id = 'badge_id' },
    { table = 'cp_badge_overrides', key = 'overrides', id = 'badge_id' },
    { table = 'cp_commendations', key = 'commendations', id = 'id' },
    { table = 'cp_disputes', key = 'disputes', id = 'id' },
}

local function RowCount(citizenid)
    local n = 0
    for _, t in ipairs({ 'cp_mission_runs', 'cp_mission_runs_archive' }) do
        n = n
            + math.floor(Num(Scalar(('SELECT COUNT(*) AS n FROM %s WHERE citizenid = ?'):format(t), { citizenid }), 0))
    end
    return n
end

-- Everything a move would carry (ids per table) and the checks: plan | nil, errKey.
local function MovePlan(src, from, to)
    if Cfg('recordMove', true) == false then return nil, 'err.record_move_off' end
    if not ValidCid(from) or not ValidCid(to) or from == to then return nil, 'err.invalid_citizenid' end
    if not Officer(from) then return nil, 'err.unknown_officer' end
    if OnlineSrc(from) or OnlineSrc(to) then return nil, 'err.record_move_online' end
    if src ~= 0 and Kit and (Kit.isSelf(src, from) or Kit.isSelf(src, to)) then return nil, 'err.self_target' end
    local okE, exists = Call('Qbx', 'characterExists', to)
    if not okE or exists ~= true then return nil, 'err.record_move_target' end
    if RowCount(to) > 0 then return nil, 'err.record_move_has_rows' end
    for _, mt in ipairs({ 'cp_badges', 'cp_commendations', 'cp_disputes' }) do
        if math.floor(Num(Scalar(('SELECT COUNT(*) AS n FROM %s WHERE citizenid = ?'):format(mt), { to }), 0)) > 0 then
            return nil, 'err.record_move_has_rows'
        end
    end
    local paying = 0
    for _, t in ipairs({ 'cp_mission_runs', 'cp_mission_runs_archive' }) do
        paying = paying
            + math.floor(Num(Scalar(
                ('SELECT COUNT(*) AS n FROM %s WHERE citizenid = ? AND cash_status = \'paying\''):format(t),
                { from }
            ), 0))
    end
    if paying > 0 then return nil, 'err.record_move_paying' end
    local giving = math.floor(Num(
        Scalar('SELECT COUNT(*) AS n FROM cp_item_rewards WHERE citizenid = ? AND status = \'giving\'', { from }), 0))
    if giving > 0 then return nil, 'err.record_move_giving' end
    local okA, licFrom = Call('Access', 'licenseOf', from)
    local okB, licTo = Call('Access', 'licenseOf', to)
    licFrom = okA and type(licFrom) == 'string' and licFrom or nil
    licTo = okB and type(licTo) == 'string' and licTo or nil
    if licFrom and licTo and licFrom ~= licTo then return nil, 'err.record_move_license' end
    local plan = { from = from, to = to, verified = licFrom ~= nil and licTo ~= nil, ids = {}, moved = {} }
    local points, held, live, archived = 0, 0, 0, 0
    for _, t in ipairs({ 'L', 'A' }) do
        for _, r in
            ipairs(
                Query(
                    ([[SELECT id, state, flagged, voided, final_points, cash_status,
            JSON_VALUE(breakdown, '$.cash.amount') AS cash_amount FROM %s WHERE citizenid = ? ORDER BY id]]):format(
                        TABLES[t]
                    ),
                    { from }
                ) or {}
            )
        do
            plan.ids[#plan.ids + 1] = t .. tostring(math.floor(Num(r.id, 0)))
            if t == 'L' then live = live + 1 else archived = archived + 1 end
            if not U.truthy(r.voided) and Counted(r) then points = points + math.floor(Num(r.final_points, 0)) end
            if r.cash_status == 'held' or r.cash_status == 'pending' then
                held = held + math.floor(Num(r.cash_amount, 0))
            end
        end
    end
    for _, mt in ipairs(MOVE_TABLES) do
        local list = {}
        for _, r in ipairs(Query(('SELECT %s AS k FROM %s WHERE citizenid = ?'):format(mt.id, mt.table), { from }) or {}) do
            list[#list + 1] = r.k
        end
        plan.moved[mt.key] = list
    end
    local rewards = {}
    for _, r in
        ipairs(
            Query([[SELECT id FROM cp_item_rewards WHERE citizenid = ? AND status IN ('held', 'pending')]], { from })
                or {}
        )
    do
        rewards[#rewards + 1] = math.floor(Num(r.id, 0))
    end
    plan.moved.rewards = rewards
    plan.effect = {
        rows = #plan.ids,
        live = live,
        archived = archived,
        points = points,
        held = held,
        badges = #plan.moved.badges,
        commendations = #plan.moved.commendations,
        disputes = #plan.moved.disputes,
        rewards = #rewards,
    }
    plan.confirmWord = plan.verified and to or ('UNVERIFIED %s'):format(to)
    return plan
end
Corr._movePlan = MovePlan

local function MoveRows(job, keys, from, to)
    local split = SplitIds(keys)
    for _, t in ipairs({ 'L', 'A' }) do
        local ids = split[t]
        if #ids > 0 then
            local params = { to }
            for _, id in ipairs(ids) do params[#params + 1] = id end
            params[#params + 1] = from
            if
                Update(
                    ('UPDATE %s SET citizenid = ? WHERE id IN (%s) AND citizenid = ?'):format(TABLES[t], Marks(#ids)),
                    params) == nil
            then
                return false, 'update failed'
            end
        end
    end
    return true
end

-- Moves the officer record and the other tables from -> to (by the ids saved in the job).
local function MoveRest(moved, from, to)
    local bare = Officer(to)
    if bare then Update('DELETE FROM cp_officers WHERE citizenid = ?', { to }) end
    Update('UPDATE cp_officers SET citizenid = ? WHERE citizenid = ?', { to, from })
    for _, mt in ipairs(MOVE_TABLES) do
        local list = type(moved[mt.key]) == 'table' and moved[mt.key] or {}
        if #list > 0 then
            local params = { to, from }
            for _, v in ipairs(list) do params[#params + 1] = v end
            Update(
                ('UPDATE %s SET citizenid = ? WHERE citizenid = ? AND %s IN (%s)'):format(mt.table, mt.id, Marks(#list)),
                params)
        end
    end
    local rewards = type(moved.rewards) == 'table' and moved.rewards or {}
    if #rewards > 0 then
        local params = { to, from }
        for _, v in ipairs(rewards) do params[#params + 1] = v end
        Update(('UPDATE cp_item_rewards SET citizenid = ? WHERE citizenid = ? AND id IN (%s)'):format(Marks(#rewards)),
            params)
    end
    Call('Scoring', 'syncXp', to)
    Call('Leaderboard', 'invalidate')
    if Kit then
        Kit.changed('recordMove', from)
        Kit.changed('recordMove', to)
    end
end

-- ============================================================================
--                                     JOBS
-- ============================================================================

if Kit and Kit.registerJob then
    Kit.registerJob('bulkVoid', { batch = VoidBatch, finish = VoidFinish })
    Kit.registerJob('retire', { batch = VoidBatch, finish = VoidFinish })
    Kit.registerJob('restoreBatch', { batch = RestoreBatch, finish = RestoreFinish })
    Kit.registerJob('recordMove', {
        batch = function(job, keys) return MoveRows(job, keys, job.detail.from, job.detail.to) end,
        finish = function(job) MoveRest(job.detail.moved or {}, job.detail.from, job.detail.to) end,
    })
    Kit.registerJob('recordMoveUndo', {
        batch = function(job, keys) return MoveRows(job, keys, job.detail.from, job.detail.to) end,
        finish = function(job) MoveRest(job.detail.moved or {}, job.detail.from, job.detail.to) end,
    })
    Kit.registerJob('recheckBadges', {
        batch = function(_, cids)
            for _, cid in ipairs(cids) do Call('Scoring', 'recheckBadges', cid) end
            return true
        end,
        finish = function() Call('Leaderboard', 'invalidate') end,
    })
end

-- ============================================================================
--                                  READ VIEWS
-- ============================================================================

local RUN_COLS = [[id, run_uuid, operation_id, mission_type, mission_id, location_label, state, end_reason, tier,
    participants, departments_n, department, final_points, cash_paid, cash_status, flagged, flag_reason, voided,
    void_kind, void_batch, duration_s, UNIX_TIMESTAMP(created_at) AS created_ts,
    JSON_VALUE(breakdown, '$.cash.amount') AS cash_amount, JSON_VALUE(breakdown, '$.by') AS award_by,
    JSON_VALUE(breakdown, '$.reason') AS award_reason]]

local function TypeLabel(t)
    local mt = Config.MissionTypes and Config.MissionTypes[t]
    return mt and mt.label or tostring(t or '')
end

local function RunView(r, citizenid, archived)
    local paid = math.floor(Num(r.cash_paid, 0))
    local manual = r.mission_type == 'manual_award' or r.mission_type == 'goal'
    return {
        id = math.floor(Num(r.id, 0)),
        runUuid = r.run_uuid,
        archived = archived == true,
        missionId = r.mission_id,
        missionLabel = Has('Admin', 'missionLabel') and CP.Admin.missionLabel(r.mission_id) or r.mission_id,
        missionType = r.mission_type,
        missionTypeLabel = TypeLabel(r.mission_type),
        location = r.location_label,
        state = r.state,
        endReason = r.end_reason,
        tier = r.tier,
        participants = math.floor(Num(r.participants, 1)),
        departments = math.floor(Num(r.departments_n, 1)),
        department = r.department,
        operationId = r.operation_id and math.floor(Num(r.operation_id, 0)) or nil,
        points = math.floor(Num(r.final_points, 0)),
        cashPaid = paid,
        cash = math.floor(Num(r.cash_amount, paid)),
        cashStatus = r.cash_status,
        flagged = U.truthy(r.flagged),
        flagReason = r.flag_reason,
        voided = U.truthy(r.voided),
        voidKind = U.truthy(r.voided) and (r.void_kind or 'strike') or nil,
        voidBatch = r.void_batch,
        durationS = math.floor(Num(r.duration_s, 0)),
        createdAt = math.floor(Num(r.created_ts, 0)),
        txnId = (paid > 0 or r.cash_status == 'paying') and ('CP-%s-%s'):format(r.run_uuid, citizenid) or nil,
        -- a manual award or adjustment says who gave it and why ("Manual award by X: reason")
        awardBy = manual and r.award_by or nil,
        awardReason = manual and r.award_reason or nil,
    }
end

-- Run history filters -> WHERE (both tables use the same one).
local function RunsWhere(cid, a)
    local where, params = { 'citizenid = ?' }, { cid }
    local from, to = DateArg(a.from, false), DateArg(a.to, type(a.to) == 'string')
    if from then
        where[#where + 1] = 'created_at >= FROM_UNIXTIME(?)'
        params[#params + 1] = from
    end
    if to then
        where[#where + 1] = 'created_at < FROM_UNIXTIME(?)'
        params[#params + 1] = to
    end
    if type(a.type) == 'string' and a.type ~= '' then
        where[#where + 1] = 'mission_type = ?'
        params[#params + 1] = a.type
    end
    if a.state == 'completed' or a.state == 'failed' or a.state == 'abandoned' then
        where[#where + 1] = 'state = ?'
        params[#params + 1] = a.state
    end
    if a.flagged == true then where[#where + 1] = 'flagged = 1' end
    if a.voided == true then where[#where + 1] = 'voided = 1' end
    if a.voided == false then where[#where + 1] = 'voided = 0' end
    if a.kind == 'strike' then where[#where + 1] = 'voided = 1 AND (void_kind IS NULL OR void_kind = \'strike\')' end
    if a.kind == 'correction' then where[#where + 1] = 'voided = 1 AND void_kind = \'correction\'' end
    return table.concat(where, ' AND '), params
end

function Corr.officerRuns(citizenid, a)
    a = type(a) == 'table' and a or {}
    local size = Int(a.size, 1, RUNS_PAGE_MAX) or 25
    local where, params = RunsWhere(citizenid, a)
    local archive = a.includeArchive ~= false
    local total = math.floor(Num(Scalar('SELECT COUNT(*) AS n FROM cp_mission_runs WHERE ' .. where, params), 0))
    if archive then
        total = total
            + math.floor(Num(Scalar('SELECT COUNT(*) AS n FROM cp_mission_runs_archive WHERE ' .. where, params), 0))
    end
    local pages = math.max(1, math.ceil(total / size))
    local page = math.min(pages, Int(a.page, 1, 100000) or 1)
    local sql, all = ('SELECT %s, 0 AS archived FROM cp_mission_runs WHERE %s'):format(RUN_COLS, where), {}
    for _, p in ipairs(params) do all[#all + 1] = p end
    if archive then
        sql = sql
            .. (' UNION ALL SELECT %s, 1 AS archived FROM cp_mission_runs_archive WHERE %s'):format(RUN_COLS, where)
        for _, p in ipairs(params) do all[#all + 1] = p end
    end
    -- ORDER BY and LIMIT go on a derived table around the union (the saves folder engine refuses them on a union)
    local rows = Query(('SELECT * FROM (%s) u ORDER BY u.created_ts DESC, u.id DESC LIMIT %d OFFSET %d'):format(
        sql,
        size,
        (page - 1) * size
    ), all) or {}
    local out = {}
    for _, r in ipairs(rows) do out[#out + 1] = RunView(r, citizenid, U.truthy(r.archived)) end
    return { runs = out, total = total, page = page, pages = pages, size = size }
end

-- One run row with its debrief, participants (live and archived), dispute and the goal rewards it completed.
function Corr.runDetail(src, rowId, archived)
    local id = Int(rowId, 1, 2147483647)
    if not id then return nil, 'err.invalid_row' end
    local t = archived and 'A' or 'L'
    local r = Single(('SELECT %s, citizenid, breakdown FROM %s WHERE id = ?'):format(RUN_COLS, TABLES[t]), { id })
    if not r then return nil, 'err.row_not_found' end
    local cid = tostring(r.citizenid)
    local view = RunView(r, cid, archived)
    view.citizenid = cid
    local bd = U.jsonField(r.breakdown)
    view.breakdown = type(bd) == 'table' and bd or nil
    local people = {}
    for _, tk in ipairs({ 'L', 'A' }) do
        for _, p in
            ipairs(Query(
                ([[SELECT r.id, r.citizenid, r.department, r.state, r.final_points, r.voided, r.flagged,
            o.display_name, o.callsign FROM %s r LEFT JOIN cp_officers o ON o.citizenid = r.citizenid
            WHERE r.run_uuid = ? ORDER BY r.id]]):format(TABLES[tk]),
                { r.run_uuid }
            ) or {})
        do
            people[#people + 1] = {
                rowId = math.floor(Num(p.id, 0)),
                archived = tk == 'A',
                citizenid = p.citizenid,
                name = p.display_name or p.citizenid,
                callsign = p.callsign,
                department = p.department,
                state = p.state,
                points = math.floor(Num(p.final_points, 0)),
                voided = U.truthy(p.voided),
                flagged = U.truthy(p.flagged),
            }
        end
    end
    view.participantsList = people
    local d = Single([[SELECT id, status, reason, goes_to FROM cp_disputes WHERE run_id = ? ORDER BY id DESC LIMIT 1]],
        { id })
    view.dispute = d and { id = math.floor(Num(d.id, 0)), status = d.status, reason = d.reason, goesTo = d.goes_to }
        or nil
    local goals = {}
    if not archived and r.mission_type ~= 'goal' and r.mission_type ~= 'manual_award' then
        for _, g in
            ipairs(
                Query([[SELECT id, mission_id, final_points FROM cp_mission_runs WHERE citizenid = ?
            AND mission_type = 'goal' AND voided = 0 AND created_at >= FROM_UNIXTIME(?)
            AND created_at < FROM_UNIXTIME(?) ORDER BY id]],
                    { cid, view.createdAt, view.createdAt + GOAL_LINK_S }) or {}
            )
        do
            goals[#goals + 1] = {
                rowId = math.floor(Num(g.id, 0)),
                goalId = g.mission_id,
                label = Has('Leaderboard', 'missionLabel') and CP.Leaderboard.missionLabel('goal', g.mission_id)
                    or g.mission_id,
                points = math.floor(Num(g.final_points, 0)),
            }
        end
    end
    view.goalRewards = goals
    view.own = Kit ~= nil and src ~= 0 and Kit.selfRun(src, r.run_uuid) == true
    return view
end

-- The officer's points per window with the rank, the department's season points, and what an adjustment allows.
function Corr.officerPoints(citizenid)
    local o = Officer(citizenid)
    if not o then return nil, 'err.unknown_officer' end
    local windows = {}
    for _, period in ipairs({ 'weekly', 'monthly', 'season', 'alltime' }) do
        local ok, ranked, all = Call('Leaderboard', 'ranking', { period = period, filter = 'overall' })
        local e = ok and type(all) == 'table' and all[citizenid] or nil
        windows[period] = {
            points = e and e.points or 0,
            rank = e and e.rank or 0,
            ranked = ok and type(ranked) == 'table' and #ranked or 0,
        }
    end
    local okS, seasonPts = Call('Leaderboard', 'seasonPoints', citizenid)
    seasonPts = okS and math.floor(Num(seasonPts, 0)) or 0
    local okC, season = Call('Challenge', 'currentSeason')
    local xp = math.floor(Num(o.xp, 0))
    local maxDeduction = xp
    if okC and type(season) == 'table' then maxDeduction = math.min(xp, seasonPts) end
    local okL, level = Call('Scoring', 'xpLevel', xp)
    return {
        citizenid = citizenid,
        windows = windows,
        seasonPoints = seasonPts,
        season = okC and type(season) == 'table' and { id = season.id, name = season.name } or nil,
        xp = xp,
        level = okL and level or nil,
        adjust = {
            enabled = Cfg('pointAdjust', true) ~= false,
            max = ADJUST_MAX,
            maxDeduction = math.max(0, maxDeduction),
            confirmAbove = math.floor(Num(Cfg('adjustConfirmAbove', 500), 500)),
            dailyLimit = math.floor(Num(Cfg('adjustDailyLimit', 0), 0)),
        },
    }
end

-- ============================================================================
--                                ADMIN ACTIONS
-- ============================================================================

local function SelfCid(p) return { citizenid = p.citizenid } end
local function SelfCidStrict(p) return { citizenid = p.citizenid, strict = true } end

local function RowById(rowId, archived)
    local id = Int(rowId, 1, 2147483647)
    if not id then return nil end
    return Single((
        'SELECT id, run_uuid, citizenid, mission_type, mission_id, state, flagged, voided, void_kind, '
        .. 'final_points, cash_status FROM %s WHERE id = ?'
    ):format(archived and TABLES.A or TABLES.L), { id })
end

local function SelfRow(p)
    local r = RowById(p.rowId, p.archived == true)
    if not r then return nil end
    return { runUuid = r.run_uuid, citizenid = r.citizenid }
end

local function LiftSuspension(ctx, citizenid)
    local okS, suspended = Call('Access', 'isSuspended', citizenid)
    if not okS or not suspended then return false end
    local ok, done = Call('Access', 'suspend', citizenid, 0, ctx.src, ctx.reason)
    if ok and done then
        ctx.audit('unsuspend', citizenid, nil, 'lifted')
        return true
    end
    return false
end

if Kit and Kit.action then
    -- ---- READS -------------------------------------------------------------

    Kit.callback('admin:getOfficerRuns', 'officerRecords', function(ctx)
        local cid = ctx.args.citizenid
        if not ValidCid(cid) then return nil, 'err.invalid_citizenid' end
        return Corr.officerRuns(cid, ctx.args)
    end, { rate = 1 })

    Kit.callback('admin:getRun', 'officerRecords', function(ctx)
        return Corr.runDetail(ctx.src, ctx.args.rowId, ctx.args.archived == true)
    end)

    Kit.callback('admin:getOfficerPoints', 'officerRecords', function(ctx)
        if not ValidCid(ctx.args.citizenid) then return nil, 'err.invalid_citizenid' end
        return Corr.officerPoints(ctx.args.citizenid)
    end)

    Kit.callback('admin:checkXp', 'progression', function(ctx)
        local cid = ctx.args.citizenid
        local o = Officer(cid)
        if not o then return nil, 'err.unknown_officer' end
        local ok, derived, rows = Call('Scoring', 'derivedXp', cid)
        if not ok or not derived then return nil, 'err.internal' end
        local stored = math.floor(Num(o.xp, 0))
        return { citizenid = cid, stored = stored, derived = derived, rows = rows, diff = derived - stored }
    end)

    Kit.callback('admin:getOfficerGoals', 'progression', function(ctx)
        local cid = ctx.args.citizenid
        if not ValidCid(cid) then return nil, 'err.invalid_citizenid' end
        local ok, g = Call('Goals', 'forOfficer', cid)
        return ok and type(g) == 'table' and g or { daily = nil, weekly = nil }
    end)

    Kit.callback('admin:getCorrections', 'bulkVoid', function(ctx)
        local cid = ctx.args.citizenid
        local rows = Query(
            ([[SELECT id, kind, state, filter, done, total, actor, reason,
            UNIX_TIMESTAMP(created_at) AS created_ts FROM cp_admin_jobs WHERE kind IN (%s)
            ORDER BY created_at DESC, id DESC LIMIT 100]]):format(Marks(#JOB_KINDS)),
            JOB_KINDS
        ) or {}
        local restored, undone = {}, {}
        local out = {}
        for _, r in ipairs(rows) do
            local f = U.jsonField(r.filter)
            f = type(f) == 'table' and f or {}
            if r.kind == 'restoreBatch' and f.batchId then restored[f.batchId] = true end
            if (r.kind == 'recordMoveUndo' or r.kind == 'reopenUndo') and f.jobId then undone[f.jobId] = true end
            r.filterT = f
        end
        for _, r in ipairs(rows) do
            local f = r.filterT
            if not cid or cid == '' or f.citizenid == cid or f.from == cid or f.to == cid then
                out[#out + 1] = {
                    id = r.id,
                    kind = r.kind,
                    state = r.state,
                    filter = f,
                    done = math.floor(Num(r.done, 0)),
                    total = math.floor(Num(r.total, 0)),
                    actor = r.actor,
                    reason = r.reason,
                    createdAt = math.floor(Num(r.created_ts, 0)),
                    restored = restored[r.id] == true,
                    undone = undone[r.id] == true,
                    -- what the Undo button does for this kind of batch
                    undo = (r.kind == 'bulkVoid' and 'restoreBatch') or (r.kind == 'retire' and 'unretire')
                        or (r.kind == 'recordMove' and 'undoRecordMove') or (r.kind == 'seasonReopen' and 'undoReopen')
                        or nil,
                }
            end
        end
        return { batches = out }
    end)

    -- ---- POINTS ------------------------------------------------------------

    -- Add or take away points: a new logged row, never an edit of old rows. Undo = void that row.
    Kit.action('server:admin:adjustPoints', 'pointsAdjust', function(ctx)
        local p = ctx.payload
        local cid = p.citizenid
        local o = Officer(cid)
        if not o then return false, 'err.unknown_officer' end
        local n = Int(p.points, -ADJUST_MAX, ADJUST_MAX)
        if not n or n == 0 then return false, 'err.invalid_points' end
        if n < 0 and Cfg('pointAdjust', true) == false then return false, 'err.adjust_off' end
        if n < 0 then
            local info = Corr.officerPoints(cid)
            if not info or -n > info.adjust.maxDeduction then return false, 'err.adjust_too_low' end
        end
        local limit = math.floor(Num(Cfg('adjustDailyLimit', 0), 0))
        if limit > 0 then
            local used = Kit.dailySum({
                missionIds = { 'manual_award', 'manual_adjust' },
                actor = ctx.actor,
                src = ctx.src,
            })
            if not used then return false, 'err.internal' end
            if used + math.abs(n) > limit then return false, 'err.adjust_daily_limit' end
        end
        local ok, rowId, err = Call('Scoring', 'adjust', ctx.src, cid, n, ctx.reason)
        if not ok or not rowId then return false, err or 'err.internal' end
        if n > 0 then
            ctx.audit('manualAward', cid, nil, ('%d'):format(n))
        else
            ctx.audit('pointsAdjust', cid, nil, ('%d'):format(n), { category = 'flags' })
        end
        Invalidate(cid, 'points')
        return true, { rowId = rowId, citizenid = cid, points = n }
    end, {
        reason = true,
        requestId = true,
        targetRate = { 1, 10000 },
        self = SelfCidStrict,
        confirm = function(p)
            local n = math.abs(tonumber(p.points) or 0)
            if n >= math.floor(Num(Cfg('adjustConfirmAbove', 500), 500)) then return p.citizenid end
            return nil
        end,
    })

    -- ---- BULK VOID AND RESTORE ---------------------------------------------

    Kit.callback('admin:previewBulkVoid', 'bulkVoid', function(ctx)
        local f, err = NormFilter(ctx.args.filter or ctx.args)
        if not f then return nil, err end
        local rows, ids, excluded = Pick(ctx.src, f)
        if not rows then return nil, 'err.internal' end
        local effect = VoidEffect(rows)
        effect.excluded = excluded
        effect.max = math.floor(Num(Cfg('bulkMaxRows', 5000), 5000))
        effect.tooMany = #ids > effect.max
        effect.confirmWord = ('VOID %d'):format(#ids)
        if #ids > 0 and not effect.tooMany then effect.previewToken = ctx.preview('bulkVoid', ids, {}) end
        return effect
    end)

    local function BulkVoid(ctx, f, jobKind, extra)
        local p = ctx.payload
        local kind = p.kind == nil and 'correction' or p.kind
        if not VOID_KINDS[kind] then return false, 'err.invalid_void_kind' end
        local rows, ids = Pick(ctx.src, f)
        if not rows then return false, 'err.internal' end
        if #ids == 0 then return false, 'err.nothing_to_void' end
        if #ids > math.floor(Num(Cfg('bulkMaxRows', 5000), 5000)) then return false, 'err.bulk_too_many' end
        if not (extra and extra.word) and not Kit.confirmOk(p.confirm, ('VOID %d'):format(#ids)) then
            return false, 'err.confirm_mismatch'
        end
        local okT, errT = ctx.consume(p.previewToken, 'bulkVoid', ids)
        if not okT then return false, errT end
        local ok, jobId = StartVoid(ctx, jobKind or 'bulkVoid', rows, ids, f, kind, extra)
        if not ok then return false, jobId end
        ctx.audit(extra and extra.action or 'bulkVoid', FilterText(f), nil, ('%d'):format(#ids), { category = 'flags' })
        return true, { jobId = jobId, rows = #ids }
    end

    -- Void every row of an officer, a department, a type, a mission or an operation between two dates.
    Kit.action('server:admin:bulkVoid', 'bulkVoid', function(ctx)
        local f, err = NormFilter(ctx.payload.filter)
        if not f then return false, err end
        if f.citizenid then
            local busy = OfficerBusy(f.citizenid)
            if busy then return false, busy end
        end
        return BulkVoid(ctx, f)
    end, { reason = true, requestId = true })

    -- Reset progression: every row of the officer, all time, as one correction batch (Undo restores it).
    Kit.action('server:admin:resetProgression', 'bulkVoid', function(ctx)
        local cid = ctx.payload.citizenid
        if not Officer(cid) then return false, 'err.unknown_officer' end
        local busy = OfficerBusy(cid)
        if busy then return false, busy end
        local f = NormFilter({ citizenid = cid, allTime = true, includeAwards = true })
        ctx.payload.kind = 'correction'
        return BulkVoid(ctx, f, 'bulkVoid', { word = true, action = 'resetProgression', reset = true })
    end, {
        reason = true,
        requestId = true,
        confirm = function(p) return p.citizenid end,
        self = SelfCid,
    })

    Kit.action('server:admin:restoreBatch', 'bulkVoid', function(ctx)
        local batchId = ctx.payload.batchId
        local job = type(batchId) == 'string' and Kit.job(batchId) or nil
        if not job or not VOID_JOBS[job.kind] then return false, 'err.batch_unknown' end
        if job.kind == 'retire' then return false, 'err.batch_retire' end
        if job.state == 'running' then return false, 'err.admin_busy' end
        local keys, cids = BatchRows(batchId)
        if #keys == 0 then return false, 'err.batch_restored' end
        local ok, jobId = Kit.startJob({
            kind = 'restoreBatch',
            src = ctx.src,
            reason = ctx.reason,
            ids = keys,
            filter = { batchId = batchId, citizenid = job.filter and job.filter.citizenid or nil },
            detail = { batchId = batchId, cids = cids, reason = ctx.reason, ident = Ident(ctx.src) },
        })
        if not ok then return false, jobId end
        ctx.audit('restoreBatch', batchId:sub(1, 64), nil, ('%d'):format(#keys), { category = 'flags' })
        return true, { jobId = jobId, rows = #keys }
    end, { reason = true, requestId = true })

    -- ---- RETIRE ------------------------------------------------------------

    Kit.callback('admin:previewRetire', 'officerRecords', function(ctx)
        local cid = ctx.args.citizenid
        local o = Officer(cid)
        if not o then return nil, 'err.unknown_officer' end
        if o.retired_ts ~= nil then return nil, 'err.officer_retired' end
        local f = NormFilter({ citizenid = cid, allTime = true, includeAwards = true })
        local rows, ids = Pick(ctx.src, f)
        if not rows then return nil, 'err.internal' end
        local effect = VoidEffect(rows)
        effect.busy = OfficerBusy(cid)
        effect.online = OnlineSrc(cid) ~= nil
        effect.confirmWord = cid
        effect.previewToken = ctx.preview('retire', ids, {})
        return effect
    end)

    -- Retire: every row voided as a correction (no strike), the tablet refused, picture and bio hidden (not
    -- cleared), optionally suspended and kept off the boards. Unretire undoes all of it.
    Kit.action('server:admin:retireOfficer', 'officerRecords', function(ctx)
        local p = ctx.payload
        local cid = p.citizenid
        local o = Officer(cid)
        if not o then return false, 'err.unknown_officer' end
        if o.retired_ts ~= nil then return false, 'err.officer_retired' end
        local busy = OfficerBusy(cid)
        if busy then return false, busy end
        local suspendDays = p.suspendDays ~= nil and Int(p.suspendDays, 1, 3650) or nil
        if p.suspendDays ~= nil and p.suspendDays ~= 0 and not suspendDays then return false, 'err.invalid_days' end
        local f = NormFilter({ citizenid = cid, allTime = true, includeAwards = true })
        local rows, ids = Pick(ctx.src, f)
        if not rows then return false, 'err.internal' end
        local okT, errT = ctx.consume(p.previewToken, 'retire', ids)
        if not okT then return false, errT end
        if Kit.busy() then return false, 'err.admin_busy' end
        local jobId = Kit.uuid()
        local exclude = p.excludeFromBoards == true and not U.truthy(o.board_excluded)
        local okK, errK = Kit.cas([[UPDATE cp_officers SET retired_at = FROM_UNIXTIME(?), retire_batch = ?,
            board_excluded = ? WHERE citizenid = ? AND retired_at IS NULL]],
            { os.time(), jobId, (exclude or U.truthy(o.board_excluded)) and 1 or 0, cid })
        if not okK then return false, errK end
        local suspended = false
        if suspendDays then
            local okS, done = Call('Access', 'suspend', cid, suspendDays, ctx.src, ctx.reason)
            suspended = okS and done == true
        end
        Kit.changed('retire', cid)
        local ok, res = StartVoid(ctx, 'retire', rows, ids, f, 'correction',
            { jobId = jobId, excluded = exclude, suspended = suspended })
        if not ok then return false, res end
        ctx.audit('retireOfficer', cid, nil, ('%d'):format(#ids), { category = 'flags' })
        return true, { jobId = jobId, rows = #ids }
    end, {
        reason = true,
        requestId = true,
        confirm = function(p) return p.citizenid end,
        self = SelfCid,
    })

    Kit.action('server:admin:unretireOfficer', 'officerRecords', function(ctx)
        local cid = ctx.payload.citizenid
        local o = Officer(cid)
        if not o then return false, 'err.unknown_officer' end
        if o.retired_ts == nil then return false, 'err.officer_not_retired' end
        local batch = o.retire_batch
        local job = batch and Kit.job(batch) or nil
        if job and job.state == 'running' then return false, 'err.admin_busy' end
        local d = job and job.detail or {}
        local okK, errK = Kit.cas([[UPDATE cp_officers SET retired_at = NULL, retire_batch = NULL
            WHERE citizenid = ? AND retired_at IS NOT NULL]], { cid })
        if not okK then return false, errK end
        if d.excluded then Update('UPDATE cp_officers SET board_excluded = 0 WHERE citizenid = ?', { cid }) end
        if d.suspended then LiftSuspension(ctx, cid) end
        Kit.changed('retire', cid)
        local keys, cids = {}, { cid }
        if batch then keys, cids = BatchRows(batch) end
        local jobId = nil
        if #keys > 0 then
            local ok, res = Kit.startJob({
                kind = 'restoreBatch',
                src = ctx.src,
                reason = ctx.reason,
                ids = keys,
                filter = { batchId = batch, citizenid = cid },
                detail = { batchId = batch, cids = cids, reason = ctx.reason, ident = Ident(ctx.src) },
            })
            if not ok then return false, res end
            jobId = res
        end
        ctx.audit('unretireOfficer', cid, nil, ('%d'):format(#keys), { category = 'flags' })
        Kit.notify(cid, 'success', 'admin.notice.unretired', {})
        return true, { jobId = jobId, rows = #keys }
    end, { reason = true, requestId = true })

    -- ---- XP, RESTORE, VOID KIND, FLAG --------------------------------------

    Kit.action('server:admin:fixXp', 'progression', function(ctx)
        local cid = ctx.payload.citizenid
        if not Officer(cid) then return false, 'err.unknown_officer' end
        if Kit.busy() == 'job' then return false, 'err.admin_busy' end
        local ok, old, new = Call('Scoring', 'syncXp', cid)
        if not ok or not new then return false, 'err.internal' end
        ctx.audit('xpFix', cid, ('%d'):format(old), ('%d'):format(new))
        Invalidate(cid, 'xp')
        return true, { citizenid = cid, old = old, new = new }
    end, { reason = true })

    -- Restore a voided run at any time (outside a dispute): the approved-dispute path. Forfeited cash stays
    -- forfeited (Payments → Pay it after all, when that switch is on).
    Kit.action('server:admin:restoreRun', 'restoreRun', function(ctx)
        local p = ctx.payload
        local archived = p.archived == true
        local row = RowById(p.rowId, archived)
        if not row then return false, 'err.row_not_found' end
        if not U.truthy(row.voided) then return false, 'err.not_voided' end
        local info
        if archived then
            local okK, errK = Kit.cas([[UPDATE cp_mission_runs_archive SET voided = 0, flagged = 0, void_kind = NULL,
                void_batch = NULL, breakdown = IF(JSON_VALID(breakdown), JSON_SET(breakdown, '$.xpCounted', 1), breakdown)
                WHERE id = ? AND voided = 1]], { math.floor(Num(row.id, 0)) })
            if not okK then return false, errK end
            Call('Scoring', 'syncXp', row.citizenid)
            Call('Scoring', 'recheckBadges', row.citizenid)
            info = { rowId = math.floor(Num(row.id, 0)), citizenid = row.citizenid }
        else
            local ok, done, res = Call('Disputes', 'restoreRow', ctx.src, row.id, ctx.reason)
            if not ok then return false, 'err.internal' end
            if not done then return false, res end
            info = res
        end
        if p.liftSuspension == true then info.liftedSuspension = LiftSuspension(ctx, row.citizenid) end
        ctx.audit('restoreRun', ('#%s %s'):format(tostring(row.id), tostring(row.citizenid)), 'voided', 'restored',
            { category = 'flags' })
        Invalidate(row.citizenid, 'restoreRun', row.mission_id)
        return true, info
    end, { reason = true, self = SelfRow })

    Kit.action('server:admin:setVoidKind', 'restoreRun', function(ctx)
        local p = ctx.payload
        if not VOID_KINDS[p.kind] then return false, 'err.invalid_void_kind' end
        local row = RowById(p.rowId, false)
        if not row then return false, 'err.row_not_found' end
        if not U.truthy(row.voided) then return false, 'err.not_voided' end
        local old = row.void_kind or 'strike'
        if old == p.kind then return true, { rowId = math.floor(Num(row.id, 0)), kind = old } end
        local okK, errK = Kit.cas([[UPDATE cp_mission_runs SET void_kind = ? WHERE id = ? AND voided = 1
            AND COALESCE(void_kind, 'strike') = ?]], { p.kind, math.floor(Num(row.id, 0)), old })
        if not okK then return false, errK end
        local nonRun = row.mission_type == 'manual_award' or row.mission_type == 'goal'
        if p.kind == 'strike' and not nonRun then Call('AntiCheat', 'onVoided', row.citizenid) end
        local lifted = false
        if p.kind == 'correction' and p.liftSuspension == true then lifted = LiftSuspension(ctx, row.citizenid) end
        ctx.audit('voidKindSet', ('#%s %s'):format(tostring(row.id), tostring(row.citizenid)), old, p.kind,
            { category = 'flags' })
        Invalidate(row.citizenid, 'voidKind')
        return true, { rowId = math.floor(Num(row.id, 0)), kind = p.kind, liftedSuspension = lifted }
    end, { reason = true, self = SelfRow })

    -- Flag a run by hand: its XP is held until a review approves it; paid cash stays paid.
    Kit.action('server:admin:flagRow', 'restoreRun', function(ctx)
        local row = RowById(ctx.payload.rowId, false)
        if not row then return false, 'err.row_not_found' end
        if row.mission_type == 'manual_award' or row.mission_type == 'goal' then return false, 'err.not_reviewable' end
        local okK, errK = Kit.cas([[UPDATE cp_mission_runs SET flagged = 1, flag_reason = 'manual'
            WHERE id = ? AND flagged = 0 AND voided = 0 AND mission_type NOT IN ('manual_award', 'goal')]],
            { math.floor(Num(row.id, 0)) })
        if not okK then return false, errK end
        Call('Scoring', 'onRowFlagged', row.id)
        ctx.audit('flagManual', ('#%s %s'):format(tostring(row.id), tostring(row.citizenid)), row.state, 'flagged',
            { category = 'flags' })
        Kit.notify(row.citizenid, 'warning', 'admin.notice.run_flagged',
            { mission = Has('Admin', 'missionLabel') and CP.Admin.missionLabel(row.mission_id) or row.mission_id })
        Invalidate(row.citizenid, 'flag')
        return true, { rowId = math.floor(Num(row.id, 0)) }
    end, { reason = true, self = SelfRow })

    -- ---- BADGES ------------------------------------------------------------

    Kit.callback('admin:getBadgeCatalog', 'progression', function()
        local ok, cat = Call('Scoring', 'badgeCatalog')
        return ok and cat or { achievements = {}, recognition = {} }
    end)

    Kit.action('server:admin:grantBadge', 'progression', function(ctx)
        local p = ctx.payload
        if not Officer(p.citizenid) then return false, 'err.unknown_officer' end
        local ok, valid, errB = Call('Scoring', 'validBadgeId', p.badgeId)
        if not ok or not valid then return false, errB or 'err.badge_unknown' end
        if not Corr.grantBadge(ctx.src, p.citizenid, p.badgeId, ctx.reason) then return false, 'err.internal' end
        ctx.audit('badgeGrant', p.citizenid, nil, p.badgeId, { category = 'board' })
        Invalidate(p.citizenid, 'badge')
        return true, { citizenid = p.citizenid, badgeId = p.badgeId }
    end, { reason = true, self = SelfCid })

    Kit.action('server:admin:revokeBadge', 'progression', function(ctx)
        local p = ctx.payload
        if not Officer(p.citizenid) then return false, 'err.unknown_officer' end
        local ok, valid, errB = Call('Scoring', 'validBadgeId', p.badgeId)
        if not ok or not valid then return false, errB or 'err.badge_unknown' end
        if not Corr.revokeBadge(ctx.src, p.citizenid, p.badgeId, ctx.reason) then return false, 'err.internal' end
        ctx.audit('badgeRevoke', p.citizenid, p.badgeId, nil, { category = 'board' })
        Invalidate(p.citizenid, 'badge')
        return true, { citizenid = p.citizenid, badgeId = p.badgeId }
    end, { reason = true, self = SelfCid })

    -- Back to automatic: the admin's grant or block goes; the rows decide again.
    Kit.action('server:admin:clearBadgeOverride', 'progression', function(ctx)
        local p = ctx.payload
        if not ValidCid(p.citizenid) or type(p.badgeId) ~= 'string' then return false, 'err.invalid_payload' end
        local okK, errK = Kit.cas('DELETE FROM cp_badge_overrides WHERE citizenid = ? AND badge_id = ?',
            { p.citizenid, p.badgeId })
        if not okK then return false, errK end
        Call('Scoring', 'recheckBadges', p.citizenid)
        ctx.audit('badgeOverrideClear', p.citizenid, p.badgeId, 'automatic', { category = 'board' })
        Invalidate(p.citizenid, 'badge')
        return true, { citizenid = p.citizenid, badgeId = p.badgeId }
    end, { reason = true, self = SelfCid })

    Kit.action('server:admin:recheckBadges', 'progression', function(ctx)
        local cid = ctx.payload.citizenid
        if not Officer(cid) then return false, 'err.unknown_officer' end
        local ok, added, removed = Call('Scoring', 'recheckBadges', cid)
        if not ok then return false, 'err.internal' end
        added, removed = added or {}, removed or {}
        if #added + #removed > 0 then
            local text = {}
            for _, id in ipairs(added) do text[#text + 1] = '+' .. id end
            for _, id in ipairs(removed) do text[#text + 1] = '-' .. id end
            ctx.audit('badgesRecheck', cid, nil, Clip(table.concat(text, ' '), 64))
            Invalidate(cid, 'badge')
        end
        return true, { citizenid = cid, added = added, removed = removed }
    end, { rate = 1 })

    Kit.action('server:admin:recheckAllBadges', 'progression', function(ctx)
        local cids = {}
        for _, r in ipairs(Query('SELECT citizenid FROM cp_officers ORDER BY citizenid') or {}) do
            cids[#cids + 1] = tostring(r.citizenid)
        end
        local ok, jobId = Kit.startJob({
            kind = 'recheckBadges',
            src = ctx.src,
            reason = 'recheck',
            ids = cids,
            filter = {},
            detail = {},
        })
        if not ok then return false, jobId end
        ctx.audit('badgesRecheck', 'everyone', nil, ('%d'):format(#cids))
        return true, { jobId = jobId, officers = #cids }
    end, { requestId = true, rate = 1 })

    -- ---- STREAK, FIRST RUN, GOALS ------------------------------------------

    Kit.action('server:admin:recalcStreak', 'progression', function(ctx)
        local cid = ctx.payload.citizenid
        local ok, res, err = Call('Scoring', 'recalcStreak', cid)
        if not ok or not res then return false, err or 'err.internal' end
        ctx.audit('streakRecalc', cid, ('%d'):format(res.old.days or 0), ('%d'):format(res.new.days or 0),
            { category = 'flags' })
        Invalidate(cid, 'streak')
        return true, res
    end, { reason = true })

    Kit.action('server:admin:forgiveStreakDays', 'progression', function(ctx)
        local cid = ctx.payload.citizenid
        local days = Int(ctx.payload.days, 1, math.floor(Num(Cfg('streakForgiveMax', 7), 7)))
        if not days then return false, 'err.invalid_days' end
        local n = Kit.dailyCount('streakForgive', { target = cid })
        if n == nil then return false, 'err.internal' end
        if n > 0 then return false, 'err.once_a_day' end
        local ok, res, err = Call('Scoring', 'forgiveStreakDays', cid, days)
        if not ok or not res then return false, err or 'err.internal' end
        ctx.audit('streakForgive', cid, ('%d'):format(res.old.days or 0), ('%d (+%d)'):format(res.new.days or 0, days),
            { category = 'flags' })
        Invalidate(cid, 'streak')
        return true, res
    end, { reason = true, self = SelfCid })

    Kit.action('server:admin:resetFirstRun', 'progression', function(ctx)
        local cid = ctx.payload.citizenid
        if not OnlineSrc(cid) then return false, 'err.officer_offline' end
        local n = Kit.dailyCount('firstRunReset', { target = cid })
        if n == nil then return false, 'err.internal' end
        if n > 0 then return false, 'err.once_a_day' end
        local ok = Call('Scoring', 'resetFirstRun', cid)
        if not ok then return false, 'err.internal' end
        ctx.audit('firstRunReset', cid, nil, 'available', { category = 'flags' })
        Kit.notify(cid, 'info', 'admin.notice.first_run_again', {})
        Invalidate(cid, 'firstRun')
        return true, { citizenid = cid }
    end, { reason = true, self = SelfCid })

    Kit.action('server:admin:completeGoal', 'progression', function(ctx)
        local p = ctx.payload
        if not Officer(p.citizenid) then return false, 'err.unknown_officer' end
        local ok, done, err = Call('Goals', 'complete', p.kind, p.citizenid, p.goalId,
            { by = ctx.actor, reason = ctx.reason })
        if not ok then return false, 'err.internal' end
        if not done then return false, err end
        ctx.audit('goalComplete', p.citizenid, nil, ('%s:%s'):format(tostring(p.kind), tostring(p.goalId)))
        Invalidate(p.citizenid, 'goal')
        return true, { citizenid = p.citizenid, goalId = p.goalId }
    end, { reason = true, self = SelfCid })

    -- ---- BOARDS AND THE OFFICER RECORD -------------------------------------

    -- Keep an officer off the public boards (a staff test character, a banned cheater). Self is allowed.
    Kit.action('server:admin:setBoardExcluded', 'officerRecords', function(ctx)
        local p = ctx.payload
        local o = Officer(p.citizenid)
        if not o then return false, 'err.unknown_officer' end
        local want = p.excluded == true and 1 or 0
        local was = U.truthy(o.board_excluded) and 1 or 0
        if want == was then return true, { citizenid = p.citizenid, excluded = want == 1 } end
        local okK, errK = Kit.cas(
            'UPDATE cp_officers SET board_excluded = ? WHERE citizenid = ? AND board_excluded = ?',
            { want, p.citizenid, was })
        if not okK then return false, errK end
        ctx.audit('boardExclude', p.citizenid, was == 1 and 'off' or 'on', want == 1 and 'off' or 'on',
            { category = 'flags' })
        Invalidate(p.citizenid, 'boards')
        return true, { citizenid = p.citizenid, excluded = want == 1 }
    end, { reason = true })

    -- Refresh from Qbox: the callsign, rank and name Qbox owns (never edited here), for an online officer.
    Kit.action('server:admin:refreshOfficer', 'officerRecords', function(ctx)
        local cid = ctx.payload.citizenid
        local s = OnlineSrc(cid)
        if not s then return false, 'err.officer_offline' end
        local ok, done = Call('Access', 'refreshOfficerRow', s)
        if not ok or not done then return false, 'err.not_police' end
        ctx.audit('officerRefresh', cid, nil, 'qbox')
        Invalidate(cid, 'refresh')
        return true, { citizenid = cid }
    end, { targetRate = { 1, 10000 } })

    -- ---- RECORD MOVE -------------------------------------------------------

    Kit.callback('admin:previewRecordMove', 'recordMove', function(ctx)
        local plan, err = MovePlan(ctx.src, ctx.args.from, ctx.args.to)
        if not plan then return nil, err end
        return {
            from = plan.from,
            to = plan.to,
            verified = plan.verified,
            confirmWord = plan.confirmWord,
            effect = plan.effect,
            previewToken = ctx.preview('recordMove', plan.ids, {}),
        }
    end)

    Kit.action('server:admin:moveRecord', 'recordMove', function(ctx)
        local p = ctx.payload
        local plan, err = MovePlan(ctx.src, p.from, p.to)
        if not plan then return false, err end
        if not Kit.confirmOk(p.confirm, plan.confirmWord) then return false, 'err.confirm_mismatch' end
        local okT, errT = ctx.consume(p.previewToken, 'recordMove', plan.ids)
        if not okT then return false, errT end
        local ok, jobId = Kit.startJob({
            kind = 'recordMove',
            src = ctx.src,
            reason = ctx.reason,
            ids = plan.ids,
            filter = { from = plan.from, to = plan.to },
            detail = { from = plan.from, to = plan.to, moved = plan.moved, verified = plan.verified },
            wait = true,
        })
        if not ok then return false, jobId end
        ctx.audit('recordMove', plan.from, plan.from, plan.to, { category = 'flags' })
        return true, { jobId = jobId, rows = #plan.ids }
    end, { reason = true, requestId = true })

    Kit.action('server:admin:undoRecordMove', 'recordMove', function(ctx)
        local job = Kit.job(ctx.payload.jobId)
        if not job or job.kind ~= 'recordMove' or job.state ~= 'done' then return false, 'err.batch_unknown' end
        local d = job.detail
        if OnlineSrc(d.from) or OnlineSrc(d.to) then return false, 'err.record_move_online' end
        if Officer(d.from) then return false, 'err.batch_restored' end
        -- the new character's rows must all be the moved ones (no rows of its own since)
        local moved = {}
        for _, k in ipairs(type(d.ids) == 'table' and d.ids or {}) do moved[k] = true end
        local ids = {}
        for _, t in ipairs({ 'L', 'A' }) do
            for _, r in ipairs(Query(('SELECT id FROM %s WHERE citizenid = ?'):format(TABLES[t]), { d.to }) or {}) do
                local key = t .. tostring(math.floor(Num(r.id, 0)))
                if not moved[key] then return false, 'err.record_move_new_rows' end
                ids[#ids + 1] = key
            end
        end
        local ok, jobId = Kit.startJob({
            kind = 'recordMoveUndo',
            src = ctx.src,
            reason = ctx.reason,
            ids = ids,
            filter = { from = d.to, to = d.from, jobId = job.id },
            detail = { from = d.to, to = d.from, moved = d.moved },
            wait = true,
        })
        if not ok then return false, jobId end
        ctx.audit('recordMoveUndo', d.to, d.to, d.from, { category = 'flags' })
        return true, { jobId = jobId, rows = #ids }
    end, { reason = true })

    -- ---- STAFF NOTICES -----------------------------------------------------

    Kit.action('server:admin:postNotice', 'officerRecords', function(ctx)
        local p = ctx.payload
        if type(p.text) ~= 'string' then return false, 'err.notice_text' end
        local text = U.trim(p.text:gsub('[%c]', ' '))
        local n = utf8.len(text)
        if text == '' or not n or n > NOTICE_MAX or text:find('[<>]') then return false, 'err.notice_text' end
        if Has('Profile', 'hasBannedWord') and CP.Profile.hasBannedWord(text) then return false, 'err.notice_banned' end
        local now = os.time()
        local expires = Int(p.expiresAt, 1, 2147483647)
        if not expires or expires <= now or expires > now + NOTICE_DAYS * 86400 then
            return false, 'err.notice_expiry'
        end
        local depts = nil
        if type(p.departments) == 'table' and #p.departments > 0 then
            depts = {}
            for _, d in ipairs(p.departments) do
                if type(d) ~= 'string' or not (type(Config.Departments) == 'table' and Config.Departments[d]) then
                    return false, 'err.unknown_department'
                end
                depts[#depts + 1] = d
            end
        end
        if not CP.Net.rateOk(ctx.src, 'notice:post', 1, NOTICE_EVERY_MS) then return false, 'err.rate_limited' end
        local active = math.floor(Num(
            Scalar([[SELECT COUNT(*) AS n FROM cp_staff_notices WHERE removed_at IS NULL
            AND expires_at > FROM_UNIXTIME(?)]], { now }),
            0
        ))
        if active >= NOTICES_ACTIVE then return false, 'err.notice_too_many' end
        Db()
        local okI, id = pcall(MySQL.insert.await,
            [[INSERT INTO cp_staff_notices (text, departments, expires_at, by_actor,
            created_at) VALUES (?, ?, FROM_UNIXTIME(?), ?, FROM_UNIXTIME(?))]],
            { text, depts and json.encode(depts) or nil, expires, Clip(ctx.actor, 50), now })
        if not okI or not id then return false, 'err.internal' end
        ctx.audit('noticePost', ('notice:%s'):format(tostring(id)), nil, Clip(text, 64), { category = 'board' })
        Call('Leaderboard', 'invalidate')
        return true, { id = math.floor(Num(id, 0)) }
    end, { reason = true })

    Kit.action('server:admin:removeNotice', 'officerRecords', function(ctx)
        local id = Int(ctx.payload.id, 1, 2147483647)
        if not id then return false, 'err.invalid_payload' end
        local okK, errK = Kit.cas(
            'UPDATE cp_staff_notices SET removed_at = FROM_UNIXTIME(?) WHERE id = ? AND removed_at IS NULL',
            { os.time(), id })
        if not okK then return false, errK end
        ctx.audit('noticeRemove', ('notice:%d'):format(id), nil, 'removed', { category = 'board' })
        Call('Leaderboard', 'invalidate')
        return true, { id = id }
    end, { reason = true })
end

-- Test hooks (not part of the contract).
Corr._candidates = Candidates
Corr._voidEffect = VoidEffect

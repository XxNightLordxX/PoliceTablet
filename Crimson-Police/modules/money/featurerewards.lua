-- CP.FeatureRewards (server): the money and items of the features outside a mission's own pay

-- CP.FeatureRewards (server): the money and items of the features outside a mission's own pay
-- (Config.FeatureRewards): the volunteer suspect, the officer who talked a suspect down, field training sign-offs and
-- completion, and supervisor point awards. Each payment is one row of the payments ledger (cp_mission_runs, mission
-- type manual_award, mission id reward_<feature>) written and paid by the money engine (CP.Money, then CP.Cash:
-- audited, pending until login, the daily cap), and
-- its items are run rewards of that row (CP.Rewards, under Config.Rewards.enabled and its daily caps). The row's
-- run_uuid is made from the feature and the case key, so one case pays once whatever calls it twice.

CP.FeatureRewards = CP.FeatureRewards or {}
local FR = CP.FeatureRewards
local U = CP.U
local TAG = 'featurerewards'

local MAX_ITEMS = 10               -- items entries one feature may list
local MAX_COUNT = 100              -- of one item per payment
local MAX_MONEY = 1000000          -- dollars one payment may be
local ACCOUNTS = { bank = true, cash = true, item = true }
local CODES = { suspect = 'sus', surrender = 'sur', ftoSignOff = 'fts', ftoComplete = 'ftc', supAward = 'sup' }
FR.FEATURES = { 'suspect', 'surrender', 'ftoSignOff', 'ftoComplete', 'supAward' }

local busy = CP.Lock.new()         -- a run_uuid while that payment is being written

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local Num = CP.Num

local ValidCid = CP.ValidCid

local function All() return type(Config.FeatureRewards) == 'table' and Config.FeatureRewards or {} end

-- The config block of one feature, or nil for an unknown one.
function FR.cfg(feature)
    if not CODES[feature] then return nil end
    local c = All()[feature]
    return type(c) == 'table' and c or {}
end

function FR.enabled(feature)
    local c = FR.cfg(feature)
    return c ~= nil and c.enabled == true
end

-- The suspect's money for one outcome key ('got_away' | 'caught'): his mission type's own amount in byType
-- when it is set, else the per-outcome default.
local function SuspectMoney(c, key, missionType)
    local by = type(c.byType) == 'table' and type(missionType) == 'string' and c.byType[missionType] or nil
    if type(by) == 'table' and tonumber(by[key]) then return Num(by[key], 0) end
    local m = type(c.money) == 'table' and c.money or {}
    return Num(m[key], 0)
end

-- The dollars a feature pays: suspect by outcome (got_away, or caught for detained and booked) and by his mission
-- type (opts.missionType), supAward per point (up to maxMoney), every other feature its money.
function FR.money(feature, opts)
    local c = FR.cfg(feature)
    if not c then return 0 end
    opts = type(opts) == 'table' and opts or {}
    local n = 0
    if feature == 'suspect' then
        local o = opts.outcome
        if o == 'got_away' then
            n = SuspectMoney(c, 'got_away', opts.missionType)
        elseif o == 'detained' or o == 'booked' then
            n = SuspectMoney(c, 'caught', opts.missionType)
        end
    elseif feature == 'supAward' then
        n = Num(c.money, 0) * math.max(0, math.floor(Num(opts.points, 0)))
        local cap = Num(c.maxMoney, 0)
        if cap > 0 then n = math.min(n, cap) end
    else
        n = Num(c.money, 0)
    end
    return math.max(0, math.min(MAX_MONEY, math.floor(n + 0.5)))
end

-- 'bank' | 'cash' | 'item' and the money item (nil unless 'item').
function FR.account(feature)
    local c = FR.cfg(feature) or {}
    local a = ACCOUNTS[c.account] and c.account or 'bank'
    if a == 'item' then
        local item = type(c.moneyItem) == 'string' and c.moneyItem ~= '' and c.moneyItem or nil
        if not item then return 'bank', nil end
        return a, item
    end
    return a, nil
end

-- The row's run_uuid (36 characters at most): the same feature and key give the same id.
function FR.uuidOf(feature, key, cid)
    local s = tostring(key)
    return ('fr-%s-%08x%08x-%08x'):format(CODES[feature] or 'xxx', U.hash(s) & 0xFFFFFFFF,
        U.hash(s:reverse()) & 0xFFFFFFFF, U.hash(tostring(cid)) & 0xFFFFFFFF)
end

-- The items of one payment: each entry once, by its chance, the same for the same key and player.
function FR.rollItems(feature, key, cid)
    local c = FR.cfg(feature)
    local list = c and type(c.items) == 'table' and c.items or {}
    local out = {}
    local seed = U.hash(('%s:%s:%s:feature-items'):format(feature, tostring(key), tostring(cid))) & 0x7FFFFFFF
    local rng = U.rng(seed == 0 and 1 or seed)
    for i, e in ipairs(list) do
        if i > MAX_ITEMS then break end
        if type(e) == 'table' and type(e.item) == 'string' then
            local usable = CP.Rewards and CP.Rewards.usable and CP.Rewards.usable(e.item)
            local chance = math.max(0, math.min(1, Num(e.chance, 1)))
            local hit = rng:next() < chance
            local lo, hi
            if type(e.count) == 'table' then
                lo, hi = math.floor(Num(e.count[1], 1)), math.floor(Num(e.count[2], Num(e.count[1], 1)))
            else
                lo = math.floor(Num(e.count, 1))
                hi = lo
            end
            lo = math.max(1, math.min(MAX_COUNT, lo))
            hi = math.max(lo, math.min(MAX_COUNT, hi))
            local count = lo + math.floor(rng:next() * (hi - lo + 1))
            if count > hi then count = hi end
            if hit and usable then
                out[#out + 1] = {
                    item = e.item,
                    count = count,
                    value = count * math.max(0, math.floor(Num(e.value, 0))),
                }
            end
        end
    end
    return out
end

-- The ledger row of one payment (CP.Money.writeRow): its feature, case and account.
local function InsertRow(feature, cid, runUuid, amount, opts)
    local account, moneyItem = FR.account(feature)
    return CP.Money.writeRow({
        runUuid = runUuid,
        missionId = 'reward_' .. feature,
        citizenid = cid,
        department = feature == 'suspect' and 'none' or (CP.deptOfCitizen(cid) or 'unknown'),
        amount = amount,
        label = CP.L('admin.mission.reward_' .. feature),
        kind = 'feature_reward',
        by = feature,
        reason = opts.reason,
        -- a suspect has no department account: his pay is always new money
        cash = { account = account, moneyItem = moneyItem, source = feature == 'suspect' and 'server' or nil },
        extra = { feature = feature, caseKey = U.clip(opts.key, 80), outcome = opts.outcome },
    })
end

local function Audit(feature, rowId, cid, amount, items, key)
    if not (CP.Admin and CP.Admin.audit) then return end
    local what = tostring(amount)
    if #items > 0 then
        local parts = {}
        for _, r in ipairs(items) do parts[#parts + 1] = ('%dx %s'):format(r.count, r.item) end
        what = what .. ' + ' .. table.concat(parts, ', ')
    end
    local ok, err = pcall(CP.Admin.audit, 'console', 'console', 'audit', 'featureReward',
        U.clip(('#%d %s'):format(rowId, cid), 64), nil, U.clip(what, 255),
        U.clip(('%s %s'):format(feature, tostring(key)), 255))
    if not ok then CP.err(TAG, 'the audit of payment %d failed: %s', rowId, tostring(err)) end
end

-- ============================================================================
--                                 THE PAYMENT
-- ============================================================================

-- Pays one feature reward: feature (FR.FEATURES), citizenid, opts = { key (the case: required), outcome (suspect),
-- points (supAward), reason, uuidCid (the row id is keyed by this citizenid instead of the paid one, so the key pays
-- once whoever is paid: ftoSignOff passes the rookie) }. Must run in a thread (database calls).
-- -> { rowId, status, amount, items } | nil, why ('off', 'invalid', 'nothing', 'duplicate', 'busy', 'error').
function FR.pay(feature, cid, opts)
    opts = type(opts) == 'table' and opts or {}
    if not FR.enabled(feature) then return nil, 'off' end
    if not ValidCid(cid) or opts.key == nil or tostring(opts.key) == '' then return nil, 'invalid' end
    local key = tostring(opts.key)
    local amount = FR.money(feature, opts)
    local items = FR.rollItems(feature, key, cid)
    if amount <= 0 and #items == 0 then return nil, 'nothing' end
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
    local uuidCid = ValidCid(opts.uuidCid) and opts.uuidCid or nil
    local runUuid = FR.uuidOf(feature, key, uuidCid or cid)
    local state, res, why = busy:run(runUuid, 0, function()
        local had = CP.Money.rowOf(runUuid, not uuidCid and cid or nil)
        if had == false then return nil, 'error' end
        if had then return nil, 'duplicate' end
        local rowId = InsertRow(feature, cid, runUuid, amount, {
            key = key,
            outcome = opts.outcome,
            reason = type(opts.reason) == 'string' and U.clip(opts.reason, 120) or nil,
        })
        if not rowId then return nil, 'error' end
        Audit(feature, rowId, cid, amount, items, key)
        local status = 'none'
        if amount > 0 then status = CP.Money.settle(rowId) end
        local given = 0
        if #items > 0 and CP.Rewards and CP.Rewards._grant then
            local list = {}
            for _, r in ipairs(items) do
                list[#list + 1] = { source = 'run', key = runUuid, item = r.item, count = r.count, value = r.value }
            end
            given = CP.Rewards._grant(cid, rowId, 'pending', list) or 0
        end
        CP.log(TAG, '%s: row %d for %s (%s), %d dollars %s, %d item rows', feature, rowId, cid, key, amount,
            tostring(status), given)
        return { rowId = rowId, status = status, amount = amount, items = items }
    end)
    if state == 'busy' then return nil, 'busy' end
    if state == 'error' then
        CP.err(TAG, 'the %s payment for %s failed: %s', feature, cid, tostring(res))
        return nil, 'error'
    end
    return res, why
end

-- FR.pay in its own thread (for hooks that may not yield).
function FR.payLater(feature, cid, opts)
    if not FR.enabled(feature) then return false end
    CreateThread(function() FR.pay(feature, cid, opts) end)
    return true
end

-- ============================================================================
--                              THE FEATURE HOOKS
-- ============================================================================

-- A volunteer case ended (payload: CP.Volunteers' end payload; afk: his catch was while AFK). Fair = officers
-- reached him, he did not drop out, was not AFK, the run was played to its end (completed or failed: an abandoned run
-- - officer quit, real call, admin cancel - pays nothing) and his outcome was got_away, detained or booked.
function FR.fairSuspect(payload, afk)
    if type(payload) ~= 'table' or not ValidCid(payload.citizenid) then return false end
    if payload.dropout ~= nil or afk == true or payload.engaged ~= true then return false end
    if payload.result ~= 'completed' and payload.result ~= 'failed' then return false end
    local o = payload.outcome
    return o == 'got_away' or o == 'detained' or o == 'booked'
end

function FR.suspectEnded(runId, payload, afk)
    if not FR.enabled('suspect') or not FR.fairSuspect(payload, afk) then return false end
    return FR.payLater('suspect', payload.citizenid, {
        key = tostring(runId),
        outcome = payload.outcome,
        missionType = payload.missionType,
    })
end

-- ============================================================================
--                                   SETTINGS
-- ============================================================================

local function CheckItems(v)
    if type(v) ~= 'table' then return 'err.feature_reward_items' end
    local n = 0
    for _, e in pairs(v) do
        n = n + 1
        if n > MAX_ITEMS or type(e) ~= 'table' then return 'err.feature_reward_items' end
        if type(e.item) ~= 'string' or e.item == '' or #e.item > 64 then return 'err.feature_reward_items' end
        if CP.Rewards and CP.Rewards.forbidden and CP.Rewards.forbidden(e.item) then
            return 'err.reward_item_forbidden'
        end
        -- checked against ox_inventory while it runs (a name it does not know is refused)
        if CP.Rewards and CP.Rewards.itemKnown and CP.Rewards.itemKnown(e.item) == false then
            return 'err.feature_reward_unknown_item'
        end
        local c = e.count == nil and 1 or e.count
        if type(c) == 'table' then
            local lo, hi = tonumber(c[1]), tonumber(c[2])
            if not lo or not hi or lo < 1 or hi < lo or hi > MAX_COUNT then return 'err.reward_count' end
        elseif type(c) ~= 'number' or c < 1 or c > MAX_COUNT then
            return 'err.reward_count'
        end
        if e.chance ~= nil and (type(e.chance) ~= 'number' or e.chance < 0 or e.chance > 1) then
            return 'err.reward_chance'
        end
        if e.value ~= nil and (type(e.value) ~= 'number' or e.value < 0) then return 'err.reward_value' end
    end
    return nil
end

local BY_TYPE_KEYS = { got_away = true, caught = true }

-- suspect.byType: { [mission type] = { got_away = dollars, caught = dollars } }, known types only.
local function CheckByType(v)
    if type(v) ~= 'table' then return 'err.feature_reward_by_type' end
    local types = type(Config.MissionTypes) == 'table' and Config.MissionTypes or {}
    for k, e in pairs(v) do
        if type(k) ~= 'string' or type(types[k]) ~= 'table' or type(e) ~= 'table' then
            return 'err.feature_reward_by_type'
        end
        for field, n in pairs(e) do
            if not BY_TYPE_KEYS[field] or type(n) ~= 'number' or n ~= n or n < 0 or n > MAX_MONEY then
                return 'err.feature_reward_by_type'
            end
        end
    end
    return nil
end

-- errKey | nil for one FeatureRewards.* path and its new value.
function FR.checkSetting(path, value)
    local seg = {}
    for part in tostring(path):gmatch('[^%.]+') do seg[#seg + 1] = part end
    if seg[1] ~= 'FeatureRewards' then return nil end
    if seg[3] == 'items' then return CheckItems(value) end
    if seg[2] == 'suspect' and seg[3] == 'byType' then return CheckByType(value) end
    if seg[3] == 'moneyItem' and type(value) == 'string' and value ~= '' then
        if CP.Rewards and CP.Rewards.itemKnown and CP.Rewards.itemKnown(value) == false then
            return 'err.feature_reward_unknown_item'
        end
    end
    return nil
end

-- the validator is registered once every file has loaded
CreateThread(function()
    if CP.Settings and CP.Settings.registerValidator then
        CP.Settings.registerValidator('FeatureRewards', function(path, clean) return FR.checkSetting(path, clean) end)
    end
end)

-- ============================================================================
--                       A VOIDED OR RESTORED SOURCE ROW
-- ============================================================================
-- A reward follows the row it pays for: a supervisor award's points row (supAward, key 'sup:<rowId>') and the
-- officer's own row of a live run (surrender, key '<run_uuid>:<suspect>'). Voiding that row voids the reward row as a
-- correction (no strike), so its cash is never paid at login and the forfeiture jobs forfeit its cash and items after
-- the dispute window; restoring the row (a dispute, a batch restore) brings the reward back.
-- With Config.FeatureRewards.suspect.voidWithRun on, the volunteer suspect's pay of a case follows the officers' rows
-- of that case the same way (SuspectRewards).

local function Rows(sql, params) return CP.query(TAG, sql, params) end

local function Breakdown(r)
    local t = U.jsonField(r.breakdown)
    return type(t) == 'table' and t or {}
end

-- Config.FeatureRewards.suspect.voidWithRun: the volunteer suspect's pay of the case of officer row src (its
-- run_uuid is the case key), voided (true) or not (false). It is voided only once every officer row of that case is
-- voided, and it comes back with any of them; a suspect row an admin voided himself (no voidedWith) stays voided.
local function SuspectRewards(src, voided)
    if (FR.cfg('suspect') or {}).voidWithRun ~= true then return {} end
    if type(src.run_uuid) ~= 'string' or src.run_uuid == '' or src.mission_id == 'manual_award' then return {} end
    if not voided then
        for _, r in
            ipairs(
                Rows('SELECT mission_id FROM cp_mission_runs WHERE run_uuid = ? AND voided = 0', { src.run_uuid }) or {})
        do
            if type(r.mission_id) ~= 'string' or r.mission_id:sub(1, 7) ~= 'reward_' then return {} end
        end
    end
    local out = {}
    for _, r in
        ipairs(Rows(
            [[SELECT id, breakdown FROM cp_mission_runs WHERE mission_id = 'reward_suspect' AND voided = ?
        ORDER BY id]],
            { voided and 1 or 0 }
        ) or {})
    do
        local b = Breakdown(r)
        if b.caseKey == src.run_uuid and (not voided or b.voidedWith ~= nil) then out[#out + 1] = r end
    end
    return out
end

-- The reward rows paid for row rowId, voided (true) or not (false) -> { id... }.
local function LinkedRewards(rowId, voided)
    local src = (Rows('SELECT id, run_uuid, citizenid, mission_id FROM cp_mission_runs WHERE id = ?', { rowId }) or {})[1]
    if not src or type(src.mission_id) ~= 'string' or src.mission_id:sub(1, 7) == 'reward_' then return {} end
    local flag = voided and 1 or 0
    local out = {}
    if src.mission_id == 'manual_award' then
        local uuid = FR.uuidOf('supAward', ('sup:%s'):format(tostring(rowId)), src.citizenid)
        for _, r in
            ipairs(Rows(
                [[SELECT id, breakdown FROM cp_mission_runs WHERE run_uuid = ? AND citizenid = ?
            AND mission_id = 'reward_supAward' AND voided = ?]],
                { uuid, src.citizenid, flag }
            ) or {})
        do
            out[#out + 1] = r
        end
    elseif type(src.run_uuid) == 'string' and src.run_uuid ~= '' then
        local prefix = src.run_uuid .. ':'
        for _, r in
            ipairs(
                Rows([[SELECT id, breakdown FROM cp_mission_runs WHERE citizenid = ?
            AND mission_id = 'reward_surrender' AND voided = ? ORDER BY id]], { src.citizenid, flag }) or {}
            )
        do
            local key = Breakdown(r).caseKey
            if type(key) == 'string' and key:sub(1, #prefix) == prefix then out[#out + 1] = r end
        end
    end
    if voided then
        local mine = {}
        for _, r in ipairs(out) do
            if math.tointeger(tonumber(Breakdown(r).voidedWith)) == math.tointeger(tonumber(rowId)) then
                mine[#mine + 1] = r
            end
        end
        out = mine
    end
    for _, r in ipairs(SuspectRewards(src, voided)) do out[#out + 1] = r end
    return out
end

local function Fire(hook, id)
    if CP.Hooks and CP.Hooks.fire then CP.Hooks.fire(hook, id) end
end

function FR.onSourceVoided(rowId)
    rowId = math.tointeger(tonumber(rowId))
    if not rowId then return 0 end
    local n = 0
    for _, r in ipairs(LinkedRewards(rowId, false)) do
        local ok, c = pcall(MySQL.update.await, [[UPDATE cp_mission_runs SET voided = 1, void_kind = 'correction',
            breakdown = IF(JSON_VALID(breakdown), JSON_SET(JSON_SET(breakdown, '$.cash.beforeVoid', cash_status),
            '$.voidedWith', ?), breakdown)
            WHERE id = ? AND voided = 0]], { rowId, r.id })
        if ok and (tonumber(c) or 0) > 0 then
            n = n + 1
            CP.log(TAG, 'reward row %s voided with row %d', tostring(r.id), rowId)
            if CP.Scoring and CP.Scoring.onRowVoided then
                pcall(CP.Scoring.onRowVoided, r.id)
            else
                Fire('row:voided', r.id)
            end
        elseif not ok then
            CP.err(TAG, 'reward row %s could not be voided with row %d: %s', tostring(r.id), rowId, tostring(c))
        end
    end
    return n
end

function FR.onSourceRestored(rowId)
    rowId = math.tointeger(tonumber(rowId))
    if not rowId then return 0 end
    local n = 0
    for _, r in ipairs(LinkedRewards(rowId, true)) do
        local cash = Breakdown(r).cash or {}
        local before = cash.beforeVoid
        -- Z13: a payment an admin cancelled (Cancel payment) stays cancelled
        local cancelled = cash.cancelled ~= nil and cash.cancelled ~= ''
        -- cash the forfeiture job forfeited because of this void (no money had moved) is pending again
        if not cancelled and (before == 'held' or before == 'pending') then
            pcall(MySQL.update.await, [[UPDATE cp_mission_runs SET cash_status = 'pending',
                breakdown = IF(JSON_VALID(breakdown), JSON_SET(breakdown, '$.cash.status', 'pending'), breakdown)
                WHERE id = ? AND voided = 1 AND cash_status = 'forfeited' AND cash_paid = 0]], { r.id })
        end
        local ok, c = pcall(MySQL.update.await, [[UPDATE cp_mission_runs SET voided = 0, void_kind = NULL,
            breakdown = IF(JSON_VALID(breakdown), JSON_REMOVE(breakdown, '$.cash.beforeVoid', '$.voidedWith'), breakdown)
            WHERE id = ? AND voided = 1]], { r.id })
        if ok and (tonumber(c) or 0) > 0 then
            n = n + 1
            CP.log(TAG, 'reward row %s restored with row %d', tostring(r.id), rowId)
            Fire('row:restored', r.id)
            Fire('row:approved', r.id)
            Fire('row:forfeitUndone', r.id)
            if not cancelled and CP.Cash and CP.Cash.release then pcall(CP.Cash.release, r.id) end
        end
    end
    return n
end

if CP.Hooks and CP.Hooks.on then
    CP.Hooks.on('row:voided', function(rowId) FR.onSourceVoided(rowId) end)
    CP.Hooks.on('row:restored', function(rowId) FR.onSourceRestored(rowId) end)
end

-- Test hooks (not part of the contract).
FR._reset = function() busy:clear() end

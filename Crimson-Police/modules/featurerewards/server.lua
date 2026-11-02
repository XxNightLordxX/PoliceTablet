-- CP.FeatureRewards (server, step G3): the money and items of the features outside a mission's own pay

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

local busy = {}                    -- [run_uuid] = true while that payment is being written

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Num(v, d)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return d end
    return n
end

local function Now()
    if CP.Schedule and CP.Schedule.now then return CP.Schedule.now() end
    return os.time()
end

local function ValidCid(v)
    return type(v) == 'string' and #v >= 1 and #v <= 50 and v:match('^[%w_%-]+$') ~= nil
end

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

-- The suspect's money for one outcome key ('got_away' | 'caught'): his mission type's own amount in byType (step H1)
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

local function DeptOf(cid)
    local ok, d = pcall(MySQL.scalar.await, 'SELECT department FROM cp_officers WHERE citizenid = ? LIMIT 1', { cid })
    if ok and type(d) == 'string' and d ~= '' then return d end
    return nil
end

local function SeasonId()
    if CP.Challenge and CP.Challenge.currentSeason then
        local ok, s = pcall(CP.Challenge.currentSeason)
        if ok and type(s) == 'table' and tonumber(s.id) then return math.floor(tonumber(s.id)) end
    end
    return 0
end

-- cid nil: any player's row of that id (a payment keyed by someone else, opts.uuidCid).
local function ExistingRow(runUuid, cid)
    local ok, id
    if cid then
        ok, id = pcall(MySQL.scalar.await,
            'SELECT id FROM cp_mission_runs WHERE run_uuid = ? AND citizenid = ? LIMIT 1', { runUuid, cid })
    else
        ok, id = pcall(MySQL.scalar.await, 'SELECT id FROM cp_mission_runs WHERE run_uuid = ? LIMIT 1', { runUuid })
    end
    if not ok then
        CP.err(TAG, 'looking up payment %s failed: %s', runUuid, tostring(id))
        return false
    end
    return tonumber(id)
end

local function InsertRow(feature, cid, runUuid, amount, opts)
    local account, moneyItem = FR.account(feature)
    local dept = feature == 'suspect' and 'none' or (DeptOf(cid) or 'unknown')
    local label = CP.L('admin.mission.reward_' .. feature)
    local bd = {
        runId = runUuid,
        missionLabel = label,
        missionType = 'manual_award',
        result = 'completed',
        endReason = 'completed',
        test = false,
        tier = 'standard',
        payTier = 'standard',
        participants = 1,
        departments = 1,
        durationS = 0,
        points = { P = 0, bonuses = {}, penalties = {}, subtotal = 0, final = 0 },
        cash = {
            B = amount,
            mTier = 1.0,
            mMod = 1.0,
            amount = amount,
            status = 'none',
            account = account,
            moneyItem = moneyItem,
            -- a suspect has no department account: his pay is always new money
            source = feature == 'suspect' and 'server' or nil,
        },
        kind = 'feature_reward',
        feature = feature,
        caseKey = U.clip(opts.key, 80),
        outcome = opts.outcome,
        by = feature,
        reason = opts.reason,
    }
    local okJ, js = pcall(json.encode, U.serialize(bd))
    local ok, id = pcall(MySQL.insert.await, [[
        INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, season_id, participants,
            departments_n, tier, state, end_reason, points_base, bonus_points, penalty_points, final_points, cash_base,
            cash_multiplier, cash_paid, cash_status, duration_s, breakdown, flagged, voided, created_at)
        VALUES (?, 'manual_award', ?, ?, ?, NULLIF(?, 0), 1, 1, 'standard', 'completed', 'completed', 0, 0, 0, 0, ?,
            1.00, 0, 'none', 0, ?, 0, 0, FROM_UNIXTIME(?))
    ]], { runUuid, 'reward_' .. feature, cid, U.clip(dept, 32), SeasonId(), amount, okJ and js or '{}', Now() })
    if not ok or not tonumber(id) then
        CP.err(TAG, 'inserting the %s payment for %s failed: %s', feature, cid, tostring(id))
        return nil
    end
    return math.floor(tonumber(id))
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
    if busy[runUuid] then return nil, 'busy' end
    busy[runUuid] = true
    local ok, res, why = pcall(function()
        local had = ExistingRow(runUuid, not uuidCid and cid or nil)
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
        if amount > 0 and CP.Cash and CP.Cash.pay then
            status = CP.Cash.pay(rowId)
            if not status then
                -- not paid now (maintenance lock, left-behind store, in flight): 'pending' so the login, start and
                -- end-of-maintenance sweeps pay it; they skip manual award rows still 'none'
                status = 'pending'
                local okP, errP = pcall(MySQL.update.await,
                    [[UPDATE cp_mission_runs SET cash_status = 'pending' WHERE id = ? AND cash_status = 'none']],
                    { rowId })
                if not okP then CP.err(TAG, 'marking row %d pending failed: %s', rowId, tostring(errP)) end
            end
        end
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
    busy[runUuid] = nil
    if not ok then
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
-- reached him, he did not drop out, was not AFK and his outcome was got_away, detained or booked.
function FR.fairSuspect(payload, afk)
    if type(payload) ~= 'table' or not ValidCid(payload.citizenid) then return false end
    if payload.dropout ~= nil or afk == true or payload.engaged ~= true then return false end
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
--                       MONEY PAID AS AN ITEM (CP.Cash)
-- ============================================================================

-- Gives amount of a money item (account = 'item'). -> true | false (no room or no ox_inventory: nothing added) |
-- false, 'error' (it raised: the inventory may have changed).
function FR.giveMoneyItem(src, item, amount)
    if type(item) ~= 'string' or item == '' then return false end
    amount = math.floor(Num(amount, 0))
    if amount <= 0 then return true end
    if GetResourceState('ox_inventory') ~= 'started' then return false end
    local okC, can = pcall(function() return exports.ox_inventory:CanCarryItem(src, item, amount) end)
    if not okC or can ~= true then return false end
    local ok, res = pcall(function() return exports.ox_inventory:AddItem(src, item, amount) end)
    if not ok then
        CP.err(TAG, 'ox_inventory AddItem(%s, %d) raised for %s: %s', item, amount, tostring(src), tostring(res))
        return false, 'error'
    end
    return res == true or (res ~= false and res ~= nil)
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

-- suspect.byType (step H1): { [mission type] = { got_away = dollars, caught = dollars } }, known types only.
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

-- modules/settings loads after this file: the validator is registered once every file has loaded
CreateThread(function()
    if CP.Settings and CP.Settings.registerValidator then
        CP.Settings.registerValidator('FeatureRewards', function(path, clean) return FR.checkSetting(path, clean) end)
    end
end)

-- Test hooks (not part of the contract).
FR._reset = function() busy = {} end

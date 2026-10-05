-- CP.Rewards (server): optional ox_inventory item rewards (Config.Rewards, off by default). Rolls, caps, delivery,
-- the Rewards locker and the admin view; rewards are held and forfeited with their run, like held cash.

CP.Rewards = CP.Rewards or {}
local Rewards = CP.Rewards
local U = CP.U
local TAG = 'rewards'

local ARENA_RETRY_MS = 10000             -- a reward waiting because of Crimson-Arena is retried this long after exit
local START_CHECK_MS = 3000              -- the item check runs this long after the resource starts
local LOCK_WAIT_MS = 15000
local FORFEIT_EVERY_MS = 10 * 60 * 1000  -- the held rewards of voided rows are checked this often
local COUNT_CACHE_S = 30                 -- lockerCount is read again at most this often per officer
local ADMIN_PAGE = 25                    -- recent rows per admin page
local MAX_ROLLS = 10                     -- rolls per run entry
local MAX_COUNT = 100                    -- items per reward row
local IDLE_WAIT_MS = 60000               -- the forfeiture job waits this long at most for an admin's bulk job
local MEDALS = { [1] = 'gold', [2] = 'silver', [3] = 'bronze' }
local TIERS = { 'standard', 'reinforced', 'heavy', 'major', 'critical' }
-- docs/CRIMSON_ARENA.md rule 4 (the loader's item-name rules): Crimson-Arena takes these from players it believes
-- owe them, weapons are never handed out, and money items would stand in for a payout.
local ARENA_ITEMS = { 'armour', 'bandage', 'ammo-*', 'weapon_*', 'money', 'black_money', 'cash' }

local bad = {}          -- bad[lower-case item] = { item, why = 'forbidden' | 'missing' }
local labels = {}       -- labels[item] = ox_inventory label
local checked = false   -- the item check ran
local inventoryUp = nil -- ox_inventory was started when the check ran
local locks = {}        -- locks[citizenid] = true while rewards are rolled or given for them
local counts = {}       -- counts[citizenid] = { n, at } (lockerCount cache; home:extras reads it)
local arenaWait = {}    -- arenaWait[src] = true while a reward waits for the player to leave Crimson-Arena

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Cfg() return type(Config.Rewards) == 'table' and Config.Rewards or {} end

local function Enabled() return Cfg().enabled == true end

local function Num(v, d)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then return d end
    return n
end

local function ToId(v)
    local n = math.tointeger(tonumber(v) or -1)
    if not n or n <= 0 then return nil end
    return n
end

local function Now()
    if CP.Schedule and CP.Schedule.now then return CP.Schedule.now() end
    return os.time()
end

local function DayStart(ts)
    ts = ts or Now()
    if CP.Schedule and CP.Schedule.dayStart then return CP.Schedule.dayStart(ts) end
    return ts - ts % 86400
end

local function WeekStart()
    if CP.Schedule and CP.Schedule.weekStart then return CP.Schedule.weekStart() end
    return Now() - 7 * 86400
end

local function WeekKey()
    if CP.Schedule and CP.Schedule.weekKey then return tostring(CP.Schedule.weekKey()) end
    return tostring(WeekStart())
end

local function Db()
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
end

local function ValidCitizenId(v)
    return type(v) == 'string' and #v >= 1 and #v <= 50 and v:match('^[%w_%-]+$') ~= nil
end

local function Query(sql, params)
    local ok, rows = pcall(MySQL.query.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'query failed: %s', tostring(rows))
        return nil
    end
    return rows or {}
end

local function Update(sql, params)
    local ok, n = pcall(MySQL.update.await, sql, params or {})
    if not ok then
        CP.err(TAG, 'update failed: %s', tostring(n))
        return nil
    end
    return tonumber(n) or 0
end

local function SrcOf(citizenid)
    if not (CP.Qbx and CP.Qbx.getByCitizenId) then return nil end
    local ok, src = pcall(CP.Qbx.getByCitizenId, citizenid)
    return ok and src or nil
end

local function CitizenOf(src)
    if not (CP.Qbx and CP.Qbx.getInfo) then return nil end
    local ok, info = pcall(CP.Qbx.getInfo, src)
    local cid = ok and type(info) == 'table' and info.citizenid or nil
    return ValidCitizenId(cid) and cid or nil
end

local function InArena(src)
    if not (CP.Alerts and CP.Alerts.inArena) then return false end
    local ok, v = pcall(CP.Alerts.inArena, src)
    return ok and v == true
end

local function Notify(src, kind, key, vars)
    if src and CP.Tablet and CP.Tablet.notify then CP.Tablet.notify(src, kind, key, vars) end
end

local function Push(citizenid)
    counts[citizenid] = nil
    local src = SrcOf(citizenid)
    if src and CP.Tablet and CP.Tablet.push then CP.Tablet.push(src, 'rewards', { changed = true }) end
end

local function WithLock(key, fn)
    local waited = 0
    while locks[key] do
        if waited >= LOCK_WAIT_MS then
            CP.warn(TAG, 'reward lock for %s is still held after %d ms; skipping this attempt', key, waited)
            return nil
        end
        Wait(50)
        waited = waited + 50
    end
    locks[key] = true
    local ok, res = pcall(fn)
    locks[key] = nil
    if not ok then
        CP.err(TAG, 'rewards for %s failed: %s', key, tostring(res))
        return nil
    end
    return res
end

local function Label(item) return labels[item] or item end

-- A maintenance lock holds reward delivery back (the rows wait in the locker); a store left behind never gives.
local function DeliveryHeld()
    if not (CP.Maintenance and CP.Maintenance.active) then return nil end
    local ok, kind = pcall(CP.Maintenance.active)
    return ok and kind or nil
end

-- ============================================================================
--                                  INVENTORY
-- ============================================================================
-- Every call into ox_inventory is guarded: GetResourceState first, then pcall, read as ok and res.

local function InventoryStarted() return GetResourceState('ox_inventory') == 'started' end

local function ItemDef(name)
    if not InventoryStarted() then return nil end
    local ok, def = pcall(function() return exports.ox_inventory:Items(name) end)
    return ok and type(def) == 'table' and def or nil
end

local function CanCarry(src, item, count)
    if not InventoryStarted() then return false end
    local ok, res = pcall(function() return exports.ox_inventory:CanCarryItem(src, item, count) end)
    return ok and res == true
end

-- true, false (refused: nothing was added) or nil (it raised: the inventory may have changed)
local function AddItem(src, item, count, id)
    if not InventoryStarted() then return false end
    local ok, res = pcall(function() return exports.ox_inventory:AddItem(src, item, count, { cpReward = id }) end)
    if not ok then
        CP.err(TAG, 'ox_inventory AddItem(%s, %d) raised for reward %d: %s', item, count, id, tostring(res))
        return nil
    end
    return res == true or (res ~= false and res ~= nil)
end

-- ============================================================================
--                                  VALIDATION
-- ============================================================================

-- 'ammo-*' -> '^ammo%-.*$': a config pattern, matched on lower case
local function PatternOf(p)
    local s = tostring(p):lower():gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0'):gsub('%*', '.*')
    return '^' .. s .. '$'
end

function Rewards.forbidden(name)
    if type(name) ~= 'string' or name == '' then return true end
    local lower = name:lower()
    for _, p in ipairs(ARENA_ITEMS) do
        if lower:match(PatternOf(p)) then return true end
    end
    for _, p in ipairs(Cfg().forbidden or {}) do
        if type(p) == 'string' and p ~= '' and lower:match(PatternOf(p)) then return true end
    end
    return false
end

-- A guaranteed reward is one spec { item, count, value } or a list of them.
local function SpecList(v)
    if type(v) ~= 'table' then return {} end
    if v.item ~= nil then return { v } end
    local out = {}
    for _, s in ipairs(v) do if type(s) == 'table' then out[#out + 1] = s end end
    return out
end

local function PoolList(entry)
    if type(entry) ~= 'table' or type(entry.pool) ~= 'table' then return {} end
    local out = {}
    for _, s in ipairs(entry.pool) do if type(s) == 'table' then out[#out + 1] = s end end
    return out
end

local function SortedKeys(t)
    local out = {}
    for k in pairs(type(t) == 'table' and t or {}) do out[#out + 1] = k end
    table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
    return out
end

-- Every configured pool: { key, specs, example }, in a stable order.
local function Pools()
    local cfg, out = Cfg(), {}
    for _, t in ipairs(SortedKeys(cfg.byType)) do
        out[#out + 1] = { key = 'byType.' .. tostring(t), specs = PoolList(cfg.byType[t]) }
    end
    for _, id in ipairs(SortedKeys(cfg.byMission)) do
        out[#out + 1] = { key = 'byMission.' .. tostring(id), specs = PoolList(cfg.byMission[id]) }
    end
    for _, m in ipairs(SortedKeys(cfg.medals)) do
        out[#out + 1] = { key = 'medals.' .. tostring(m), specs = SpecList(cfg.medals[m]) }
    end
    for _, g in ipairs(SortedKeys(cfg.goals)) do
        out[#out + 1] = { key = 'goals.' .. tostring(g), specs = SpecList(cfg.goals[g]) }
    end
    for _, l in ipairs(SortedKeys(cfg.levels)) do
        out[#out + 1] = { key = 'levels.' .. tostring(l), specs = SpecList(cfg.levels[l]) }
    end
    if cfg.weeklyBoss then out[#out + 1] = { key = 'weeklyBoss', specs = SpecList(cfg.weeklyBoss) } end
    for _, s in ipairs(SortedKeys(cfg.season)) do
        out[#out + 1] = { key = 'season.' .. tostring(s), specs = SpecList(cfg.season[s]) }
    end
    for _, t in ipairs(SortedKeys(cfg.examplePools)) do
        out[#out + 1] = { key = 'examplePools.' .. tostring(t), specs = PoolList(cfg.examplePools[t]), example = true }
    end
    return out
end

-- The start check: forbidden names and items ox_inventory does not know are turned off, with a warning when the
-- owner uses that pool (the example pools only warn when useExamplePools is on; Config health lists them anyway).
function Rewards.validate()
    bad, labels = {}, {}
    inventoryUp = InventoryStarted()
    local cfg = Cfg()
    local warned = {}
    for _, pool in ipairs(Pools()) do
        local loud = Enabled() and (not pool.example or cfg.useExamplePools == true)
        for _, spec in ipairs(pool.specs) do
            local name = spec.item
            local lower = type(name) == 'string' and name:lower() or ''
            if not bad[lower] then
                if Rewards.forbidden(name) then
                    bad[lower] = { item = tostring(name), why = 'forbidden' }
                elseif inventoryUp then
                    local def = ItemDef(name)
                    if def then
                        labels[name] = type(def.label) == 'string' and def.label or name
                    else
                        bad[lower] = { item = name, why = 'missing' }
                    end
                end
            end
            if bad[lower] and loud and not warned[lower] then
                warned[lower] = true
                if bad[lower].why == 'forbidden' then
                    CP.warn(TAG, 'Config.Rewards %s: "%s" can never be an item reward; it is turned off', pool.key,
                        tostring(name))
                else
                    CP.warn(TAG, 'Config.Rewards %s: "%s" does not exist in ox_inventory; it is turned off', pool.key,
                        tostring(name))
                end
            end
        end
    end
    checked = true
    return bad
end

-- The check runs again once ox_inventory is up when it was not at the last check (it started late).
local function EnsureChecked()
    if not checked or (inventoryUp == false and InventoryStarted()) then Rewards.validate() end
end

-- Checked twice: the forbidden names right here (an item added in game before the next check is never given), and
-- the last check's list (forbidden or unknown to ox_inventory).
local function Usable(name)
    if type(name) ~= 'string' or name == '' then return false end
    if Rewards.forbidden(name) then return false end
    EnsureChecked()
    return bad[name:lower()] == nil
end

-- Config health lines ({ level, text }), for CP.ConfigHealth (WP8) and the admin view.
function Rewards.health()
    EnsureChecked()
    local cfg, out = Cfg(), {}
    local hasExample = next(type(cfg.examplePools) == 'table' and cfg.examplePools or {}) ~= nil
    if not Enabled() then
        out[#out + 1] = {
            level = 'ok',
            text = hasExample and CP.L('rewards.health.off_example') or CP.L('rewards.health.off'),
        }
    else
        out[#out + 1] = { level = 'ok', text = CP.L('rewards.health.on') }
        if not inventoryUp then out[#out + 1] = { level = 'error', text = CP.L('rewards.health.no_inventory') } end
    end
    local seen = {}
    for _, pool in ipairs(Pools()) do
        for _, spec in ipairs(pool.specs) do
            local lower = type(spec.item) == 'string' and spec.item:lower() or ''
            local b = bad[lower]
            if b and not seen[pool.key .. '|' .. lower] then
                seen[pool.key .. '|' .. lower] = true
                local key = b.why == 'forbidden' and 'rewards.health.forbidden' or 'rewards.health.missing'
                if pool.example and b.why == 'missing' then key = 'rewards.health.example_missing' end
                out[#out + 1] = { level = 'warn', text = CP.L(key, { item = b.item, pool = pool.key }) }
            end
        end
    end
    return out
end

-- ============================================================================
--                                    ROLLS
-- ============================================================================

-- The run entry for a mission: byMission replaces the type's entry; the example pool only with useExamplePools.
function Rewards.entryFor(missionId, missionType)
    local cfg = Cfg()
    if type(cfg.byMission) == 'table' and type(cfg.byMission[missionId]) == 'table' then
        return cfg.byMission[missionId]
    end
    if type(cfg.byType) == 'table' and type(cfg.byType[missionType]) == 'table' then return cfg.byType[missionType] end
    if cfg.useExamplePools == true and type(cfg.examplePools) == 'table' then return cfg.examplePools[missionType] end
    return nil
end

-- entry.chance + the tier's tierChance + findBonus per lawful evidence find (up to findBonusMax), in [0, 1].
function Rewards.chanceFor(entry, tier, evidence)
    local cfg = Cfg()
    local base = Num(type(entry) == 'table' and entry.chance, 0)
    local tierAdd = Num(type(cfg.tierChance) == 'table' and cfg.tierChance[tier], 0)
    local finds = math.max(0, math.floor(Num(evidence, 0)))
    local find = math.min(finds * Num(cfg.findBonus, 0), math.max(0, Num(cfg.findBonusMax, 0)))
    return U.clamp(base + tierAdd + find, 0, 1)
end

local function CountOf(rng, c)
    if type(c) == 'table' then
        local lo = math.max(1, math.floor(Num(c[1], 1)))
        local hi = math.max(lo, math.floor(Num(c[2], lo)))
        return math.min(MAX_COUNT, rng:int(lo, hi))
    end
    rng:next()   -- the same number of draws whatever the shape, so one edit never shifts the other rolls
    return math.min(MAX_COUNT, math.max(1, math.floor(Num(c, 1))))
end

local function Seed(key)
    local s = U.hash(key) & 0x7FFFFFFF
    return s == 0 and 1 or s
end

-- The rolls of one run entry for one officer: the same for the same run id and citizenid, always. Returns
-- { { item, count, value } } with one entry per item (the unique key holds one row per item and source).
function Rewards.roll(runId, citizenid, entry, chance)
    local out, byItem = {}, {}
    local pool = {}
    for _, s in ipairs(PoolList(entry)) do
        if Usable(s.item) and Num(s.weight, 1) > 0 then pool[#pool + 1] = s end
    end
    if #pool == 0 then return out end
    local total = 0
    for _, s in ipairs(pool) do total = total + Num(s.weight, 1) end
    local rng = U.rng(Seed(('%s:%s:item-rewards'):format(tostring(runId), tostring(citizenid))))
    local rolls = math.min(MAX_ROLLS, math.max(0, math.floor(Num(entry.rolls, 1))))
    for _ = 1, rolls do
        local hit = rng:next() < chance
        local at, pick = rng:next() * total, pool[#pool]
        for _, s in ipairs(pool) do
            at = at - Num(s.weight, 1)
            if at < 0 then pick = s; break end
        end
        local count = CountOf(rng, pick.count)
        if hit then
            local r = byItem[pick.item]
            if not r then
                r = { item = pick.item, count = 0, value = 0 }
                byItem[pick.item] = r
                out[#out + 1] = r
            end
            r.count = math.min(MAX_COUNT, r.count + count)
            r.value = r.value + count * math.max(0, math.floor(Num(pick.value, 0)))
        end
    end
    return out
end

-- A guaranteed spec as a reward, or nil when its item is turned off.
local function Guaranteed(spec)
    if type(spec) ~= 'table' or not Usable(spec.item) then return nil end
    local count = math.min(MAX_COUNT,
        math.max(1, math.floor(Num(type(spec.count) == 'table' and spec.count[1] or spec.count, 1))))
    return { item = spec.item, count = count, value = count * math.max(0, math.floor(Num(spec.value, 0))) }
end

-- ============================================================================
--                                ROWS AND CAPS
-- ============================================================================

-- Items and value this officer got today, from every source (forfeited rows do not count).
local function UsedToday(citizenid)
    local rows = Query([[
        SELECT COALESCE(SUM(count), 0) AS n, COALESCE(SUM(value), 0) AS v FROM cp_item_rewards
        WHERE citizenid = ? AND status IN ('held', 'pending', 'giving', 'given') AND created_at >= FROM_UNIXTIME(?)
    ]], { citizenid, DayStart() })
    if not rows then return nil end
    local r = rows[1] or {}
    return math.floor(U.num(r.n)), math.floor(U.num(r.v))
end

-- Inserts the rewards (list of { source, key, item, count, value }) under the daily caps; a reward past a cap
-- gives nothing. The unique key makes a second call for the same source and key insert nothing. Runs under the
-- citizenid lock. Returns the number of new rows.
local function Store(citizenid, rowId, status, list)
    if #list == 0 then return 0 end
    local usedN, usedV = UsedToday(citizenid)
    if not usedN then return 0 end
    local cfg = Cfg()
    local capN = math.floor(Num(cfg.dailyItemCap, 0))
    local capV = math.floor(Num(cfg.dailyValueCap, 0))
    local added = 0
    for _, r in ipairs(list) do
        local key = U.clip(r.key, 64)
        local dup = Query([[
            SELECT id FROM cp_item_rewards WHERE citizenid = ? AND source = ? AND source_key = ? AND item = ?
        ]], { citizenid, r.source, key, r.item })
        if dup and #dup == 0 then
            if (capN > 0 and usedN + r.count > capN) or (capV > 0 and usedV + r.value > capV) then
                CP.log(TAG, '%s: %d x %s (%s %s) is past the daily cap; nothing given', citizenid, r.count, r.item,
                    r.source, key)
            else
                local n = Update([[
                    INSERT IGNORE INTO cp_item_rewards (row_id, source, source_key, citizenid, item, count, value, status,
                        created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, FROM_UNIXTIME(?))
                ]], { rowId, r.source, key, citizenid, U.clip(r.item, 64), r.count, r.value, status, Now() })
                if n and n > 0 then
                    added = added + 1
                    usedN, usedV = usedN + r.count, usedV + r.value
                end
            end
        end
    end
    return added
end

local function RewardRow(r)
    local ts = tonumber(r.given_ts) or tonumber(r.created_ts) or 0
    return {
        id = math.floor(U.num(r.id)),
        item = r.item,
        label = Label(r.item),
        count = math.floor(U.num(r.count, 1)),
        source = r.source,
        status = r.status,
        at = math.floor(ts),
        citizenid = r.citizenid,
        name = type(r.display_name) == 'string' and r.display_name or nil,
    }
end

local ROW_COLS = [[r.id, r.row_id, r.source, r.source_key, r.citizenid, r.item, r.count, r.value, r.status,
    UNIX_TIMESTAMP(r.created_at) AS created_ts, UNIX_TIMESTAMP(r.given_at) AS given_ts]]

function Rewards.forRow(rowId)
    rowId = ToId(rowId)
    if not rowId then return {} end
    Db()
    local rows = Query('SELECT ' .. ROW_COLS .. ' FROM cp_item_rewards r WHERE r.row_id = ? ORDER BY r.id', { rowId })
    local out = {}
    for _, r in ipairs(rows or {}) do out[#out + 1] = RewardRow(r) end
    return out
end

function Rewards.lockerCount(citizenid)
    if not ValidCitizenId(citizenid) then return 0 end
    local c = counts[citizenid]
    if c and Now() - c.at < COUNT_CACHE_S then return c.n end
    Db()
    local ok, n = pcall(MySQL.scalar.await, [[
        SELECT COUNT(*) AS n FROM cp_item_rewards WHERE citizenid = ? AND status = 'pending'
    ]], { citizenid })
    if not ok then
        CP.err(TAG, 'locker count of %s failed: %s', citizenid, tostring(n))
        return c and c.n or 0
    end
    n = math.floor(U.num(n))
    counts[citizenid] = { n = n, at = Now() }
    return n
end

-- RunResult.items (the result screen: given, pending or held) and breakdown.items (the history, forfeited too).
local function ItemsView(rowId, withForfeited)
    local out = {}
    for _, r in ipairs(Rewards.forRow(rowId)) do
        if withForfeited or r.status ~= 'forfeited' then
            local status = r.status
            if status == 'giving' then status = 'pending' end
            out[#out + 1] = { name = r.item, label = r.label, count = r.count, status = status }
        end
    end
    return out
end

-- The history breakdown (cp_mission_runs.breakdown.items) follows the rewards of its row. One JSON_SET on that
-- path, so the fields other modules write into the breakdown are never overwritten.
local function SyncBreakdown(rowId)
    rowId = ToId(rowId)
    if not rowId then return end
    local items = ItemsView(rowId, true)
    if #items == 0 then return end
    local ok, text = pcall(json.encode, items)
    if not ok or type(text) ~= 'string' then return end
    Update([[
        UPDATE cp_mission_runs SET breakdown = JSON_SET(breakdown, '$.items', JSON_EXTRACT(?, '$'))
        WHERE id = ? AND JSON_VALID(breakdown)
    ]], { text, rowId })
end

-- ============================================================================
--                                   DELIVERY
-- ============================================================================

local function BackToPending(id)
    return Update('UPDATE cp_item_rewards SET status = \'pending\' WHERE id = ? AND status = \'giving\'', { id })
end

-- Gives one pending row to src. Claim before give: the row goes to giving in one UPDATE with the old status in the
-- WHERE clause, so a second give of the same row does nothing. A raise inside AddItem leaves it giving (listed for
-- admins, never retried automatically).
local function GiveRow(r, src)
    local id = math.floor(U.num(r.id))
    local item, count = r.item, math.floor(U.num(r.count, 1))
    local claimed = Update([[
        UPDATE cp_item_rewards SET status = 'giving' WHERE id = ? AND status = 'pending'
    ]], { id })
    if not claimed or claimed < 1 then return false, 'err.reward_not_claimable' end
    if not CanCarry(src, item, count) then
        BackToPending(id)
        return false, 'err.reward_no_room'
    end
    local added = AddItem(src, item, count, id)
    if added == nil then return false, 'err.internal' end
    if not added then
        BackToPending(id)
        return false, 'err.reward_no_room'
    end
    local done = Update([[
        UPDATE cp_item_rewards SET status = 'given', given_at = FROM_UNIXTIME(?) WHERE id = ? AND status = 'giving'
    ]], { Now(), id })
    if not done or done < 1 then
        CP.err(TAG, 'reward %d was given but its status could not be written; it stays giving', id)
    end
    CP.log(TAG, 'reward %d: %d x %s given to %s', id, count, item, tostring(r.citizenid))
    if r.row_id then SyncBreakdown(r.row_id) end
    Notify(src, 'success', 'rewards.given', { count = count, item = Label(item) })
    return true
end

-- Every pending row of an online officer: given now, or left in the locker (arena, no room, no ox_inventory).
local function DeliverAll(citizenid)
    if not Enabled() or not ValidCitizenId(citizenid) then return 0 end
    if DeliveryHeld() then return 0 end
    local src = SrcOf(citizenid)
    if not src then return 0 end
    if InArena(src) then
        arenaWait[src] = true
        return 0
    end
    if not InventoryStarted() then return 0 end
    Db()
    local rows = Query([[
        SELECT id, row_id, citizenid, item, count FROM cp_item_rewards
        WHERE citizenid = ? AND status = 'pending' ORDER BY id
    ]], { citizenid })
    local given, full = 0, nil
    for _, r in ipairs(rows or {}) do
        local ok, errKey = GiveRow(r, src)
        if ok then
            given = given + 1
        elseif errKey == 'err.reward_no_room' and not full then
            full = r
        end
    end
    if full then
        Notify(src, 'warning', 'rewards.locker_full',
            { count = math.floor(U.num(full.count, 1)), item = Label(full.item) })
    end
    if rows and #rows > 0 then Push(citizenid) end
    return given
end

function Rewards.deliver(citizenid)
    if not ValidCitizenId(citizenid) then return 0 end
    return WithLock(citizenid, function() return DeliverAll(citizenid) end) or 0
end

-- Stores rewards for one officer and delivers what is pending.
local function Grant(citizenid, rowId, status, list)
    if not Enabled() or not ValidCitizenId(citizenid) or #list == 0 then return 0 end
    Db()
    local added = WithLock(citizenid, function()
        local n = Store(citizenid, rowId, status, list)
        if n > 0 and status == 'pending' then DeliverAll(citizenid) end
        return n
    end) or 0
    if added > 0 then Push(citizenid) end
    return added
end

Rewards._grant = Grant

-- ============================================================================
--                                 RUN REWARDS
-- ============================================================================

local function PresenceFailed(run, p)
    if type(p.flagged) == 'table' and p.flagged.reason == 'presence' then return true end
    if type(run.order) ~= 'table' or #run.order < 2 then return false end
    local share = nil
    if CP.AntiCheat and CP.AntiCheat.presenceShare then
        local ok, v = pcall(CP.AntiCheat.presenceShare, p)
        share = ok and tonumber(v) or nil
    elseif type(p.presence) == 'table' and Num(p.presence.total, 0) > 0 then
        share = Num(p.presence.inRange, 0) / Num(p.presence.total, 1)
    end
    if share == nil then return false end
    return share < Num(Config.AntiCheat and Config.AntiCheat.presenceShare, 0.70)
end

-- The run's lawful evidence finds, from every participant (the bonus is the run's, not the finder's).
local function RunFinds(run, row)
    local n = 0
    for _, q in pairs(type(run.participants) == 'table' and run.participants or {}) do
        n = n + Num(type(q) == 'table' and type(q.stats) == 'table' and q.stats.evidence, 0)
    end
    return math.max(n, Num(row.evidence, 0))
end

-- row:settled: each participant of a Completed, non-test run who met the presence share rolls the run entry,
-- and gets the medal and Weekly Boss items. Flagged: held until a supervisor approves the run.
local function OnRowSettled(run, p, rowId, row, result)
    if not Enabled() then return end
    if type(run) ~= 'table' or type(p) ~= 'table' or type(row) ~= 'table' then return end
    rowId = ToId(rowId)
    if not rowId or run.test or row.state ~= 'completed' then return end
    local cid = row.citizenid
    if not ValidCitizenId(cid) or PresenceFailed(run, p) then return end
    local cfg = Cfg()
    local list = {}
    local entry = Rewards.entryFor(row.mission_id, row.mission_type)
    if entry then
        local chance = Rewards.chanceFor(entry, row.tier, RunFinds(run, row))
        for _, r in ipairs(Rewards.roll(run.id, cid, entry, chance)) do
            list[#list + 1] = { source = 'run', key = run.id, item = r.item, count = r.count, value = r.value }
        end
    end
    local medal = MEDALS[tonumber(row.medal) or 0]
    if medal and type(cfg.medals) == 'table' then
        for _, spec in ipairs(SpecList(cfg.medals[medal])) do
            local g = Guaranteed(spec)
            if g then
                list[#list + 1] = { source = 'medal', key = run.id, item = g.item, count = g.count, value = g.value }
            end
        end
    end
    if run.isBoss and cfg.weeklyBoss then
        for _, spec in ipairs(SpecList(cfg.weeklyBoss)) do
            local g = Guaranteed(spec)
            if g then
                list[#list + 1] = {
                    source = 'boss',
                    key = 'week:' .. WeekKey(),
                    item = g.item,
                    count = g.count,
                    value = g.value,
                }
            end
        end
    end
    local held = p.flagged ~= nil or run.flagged ~= nil or CP.U.truthy(row.flagged)
    if Grant(cid, rowId, held and 'held' or 'pending', list) > 0 then SyncBreakdown(rowId) end
    if type(result) == 'table' then result.items = ItemsView(rowId, false) end
end

-- row:approved: held rewards of the row become pending and are given.
local function OnRowApproved(rowId)
    rowId = ToId(rowId)
    if not rowId or not Enabled() then return end
    Db()
    local rows = Query('SELECT DISTINCT citizenid FROM cp_item_rewards WHERE row_id = ? AND status = \'held\'',
        { rowId })
    local n = Update('UPDATE cp_item_rewards SET status = \'pending\' WHERE row_id = ? AND status = \'held\'',
        { rowId })
    if not n or n < 1 then return end
    for _, r in ipairs(rows or {}) do
        Rewards.deliver(r.citizenid)
        Push(r.citizenid)
    end
    SyncBreakdown(rowId)
end

-- row:voided: rewards not given yet wait (held) for the dispute window, like held cash.
local function OnRowVoided(rowId)
    rowId = ToId(rowId)
    if not rowId then return end
    Db()
    local rows = Query('SELECT DISTINCT citizenid FROM cp_item_rewards WHERE row_id = ? AND status = \'pending\'',
        { rowId })
    local n = Update('UPDATE cp_item_rewards SET status = \'held\' WHERE row_id = ? AND status = \'pending\'',
        { rowId })
    if n and n > 0 then
        for _, r in ipairs(rows or {}) do Push(r.citizenid) end
        SyncBreakdown(rowId)
    end
end

-- row:forfeited: the dispute window closed on a voided row.
local function OnRowForfeited(rowId)
    rowId = ToId(rowId)
    if not rowId then return end
    Db()
    local rows = Query([[
        SELECT DISTINCT citizenid FROM cp_item_rewards WHERE row_id = ? AND status IN ('held', 'pending')
    ]], { rowId })
    local n = Update([[
        UPDATE cp_item_rewards SET status = 'forfeited' WHERE row_id = ? AND status IN ('held', 'pending')
    ]], { rowId })
    if n and n > 0 then
        CP.log(TAG, 'row %d: %d item reward(s) forfeited', rowId, n)
        for _, r in ipairs(rows or {}) do Push(r.citizenid) end
        SyncBreakdown(rowId)
    end
    return n and n > 0 or false
end

-- CP.Cash fires row:forfeited only for a voided row whose cash was still held or pending. A row voided after its
-- cash was paid (or one that carried none) is forfeited here, on the same rule: its dispute window closed and no
-- dispute is open. Each row is claimed by its own UPDATE, which checks the rule again.
local function ForfeitRows()
    local hours = Num(Config.Disputes and Config.Disputes.windowHours, 48)
    local cutoff = Now() - math.floor(hours * 3600)
    local rows = Query([[
        SELECT DISTINCT i.row_id FROM cp_item_rewards i
        JOIN cp_mission_runs r ON r.id = i.row_id
        WHERE i.status IN ('held', 'pending') AND r.voided = 1 AND r.created_at < FROM_UNIXTIME(?)
          AND NOT EXISTS (SELECT 1 FROM cp_disputes d WHERE d.run_id = r.id AND d.status = 'open')
        ORDER BY i.row_id
    ]], { cutoff })
    local function forfeitRow(rowId)
        local cids = Query([[
            SELECT DISTINCT citizenid FROM cp_item_rewards WHERE row_id = ? AND status IN ('held', 'pending')
        ]], { rowId })
        local changed = Update([[
            UPDATE cp_item_rewards SET status = 'forfeited'
            WHERE row_id = ? AND status IN ('held', 'pending')
              AND EXISTS (SELECT 1 FROM cp_mission_runs r WHERE r.id = ? AND r.voided = 1)
              AND NOT EXISTS (SELECT 1 FROM cp_disputes d WHERE d.run_id = ? AND d.status = 'open')
        ]], { rowId, rowId, rowId })
        if not changed or changed < 1 then return false end
        CP.log(TAG, 'row %d: %d item reward(s) of a voided run forfeited', rowId, changed)
        for _, c in ipairs(cids or {}) do Push(c.citizenid) end
        SyncBreakdown(rowId)
        return true
    end
    local n = 0
    for _, r in ipairs(rows or {}) do
        local rowId = ToId(r.row_id)
        if rowId and forfeitRow(rowId) then n = n + 1 end
    end
    return n
end

-- Waits while a maintenance lock holds rewards back, and for an admin's bulk job; holds the busy lock meanwhile.
local function ForfeitureJob()
    if DeliveryHeld() then return 0 end
    Db()
    local Kit = CP.AdminKit
    if not (Kit and Kit.waitIdle and Kit.lock and Kit.unlock) then return ForfeitRows() end
    if not Kit.waitIdle(IDLE_WAIT_MS) or not Kit.lock('rewardForfeiture') then return 0 end
    local ok, n = pcall(ForfeitRows)
    Kit.unlock('rewardForfeiture')
    if not ok then
        CP.err(TAG, 'reward forfeiture job failed: %s', tostring(n))
        return 0
    end
    return n
end

-- ============================================================================
--                            GOALS, LEVELS, SEASONS
-- ============================================================================

local function SpecRewards(specs, source, key)
    local list = {}
    for _, spec in ipairs(specs) do
        local g = Guaranteed(spec)
        if g then list[#list + 1] = { source = source, key = key, item = g.item, count = g.count, value = g.value } end
    end
    return list
end

-- goal:completed: Config.Rewards.goals[goalId], else goals.daily or goals.weekly; once per goal and period.
local function OnGoalCompleted(citizenid, goalId, period)
    if not Enabled() or not ValidCitizenId(citizenid) or type(goalId) ~= 'string' then return end
    local goals = Cfg().goals
    if type(goals) ~= 'table' then return end
    local kind = tostring(period or ''):match('^(%a+):')
    local spec = goals[goalId] or (kind and goals[kind])
    if not spec then return end
    Grant(citizenid, nil, 'pending', SpecRewards(SpecList(spec), 'goal', ('%s@%s'):format(goalId, tostring(period))))
end

-- xp:levelUp (may not yield): every level passed that has an item, once per level.
local function OnLevelUp(citizenid, _, oldLevel, newLevel)
    if not Enabled() or not ValidCitizenId(citizenid) then return end
    local levels = Cfg().levels
    if type(levels) ~= 'table' then return end
    local from, to = math.floor(Num(oldLevel, 0)) + 1, math.floor(Num(newLevel, 0))
    if to < from then return end
    local list = {}
    for n = from, math.min(to, from + 200) do
        for _, r in ipairs(SpecRewards(SpecList(levels[n]), 'level', tostring(n))) do list[#list + 1] = r end
    end
    if #list == 0 then return end
    CreateThread(function() Grant(citizenid, nil, 'pending', list) end)
end

-- season:ended: season.champion for the champion department's officers with a completed row in the season,
-- season.top10 for the season's top 10.
local function OnSeasonEnded(seasonId, results)
    if not Enabled() or type(results) ~= 'table' then return end
    local season = Cfg().season
    if type(season) ~= 'table' then return end
    local id = tostring(seasonId)
    if season.champion and type(results.champion) == 'string' and results.champion ~= '' then
        Db()
        local rows = Query([[
            SELECT citizenid FROM cp_mission_runs
            WHERE season_id = ? AND department = ? AND state = 'completed' AND flagged = 0 AND voided = 0
              AND mission_type NOT IN ('manual_award', 'goal')
            GROUP BY citizenid ORDER BY citizenid
        ]], { tonumber(seasonId), results.champion })
        for _, r in ipairs(rows or {}) do
            Grant(r.citizenid, nil, 'pending', SpecRewards(SpecList(season.champion), 'season', 'champion:' .. id))
        end
    end
    if season.top10 and type(results.top10) == 'table' then
        for i, cid in ipairs(results.top10) do
            if i > 10 then break end
            Grant(cid, nil, 'pending', SpecRewards(SpecList(season.top10), 'season', 'top10:' .. id))
        end
    end
end

-- ============================================================================
--                               LOCKER AND ADMIN
-- ============================================================================

function Rewards.locker(src)
    local cid = CitizenOf(src)
    if not cid then return nil, 'err.not_police' end
    Db()
    local rows = Query([[
        SELECT ]] .. ROW_COLS .. [[ FROM cp_item_rewards r
        WHERE r.citizenid = ? AND r.status IN ('pending', 'held', 'giving') ORDER BY r.id
    ]], { cid })
    local out = {}
    for _, r in ipairs(rows or {}) do
        local row = RewardRow(r)
        row.citizenid, row.name = nil, nil
        out[#out + 1] = row
    end
    local reason = nil
    if not Enabled() then
        reason = 'rewards.reason.off'
    elseif InArena(src) then
        reason = 'rewards.reason.arena'
    elseif not InventoryStarted() then
        reason = 'rewards.reason.inventory'
    end
    return { rows = out, canClaim = reason == nil, reason = reason }
end

-- server:rewards:claim: everything is checked again here (own row, pending, not in the arena, room).
function Rewards.claim(src, id)
    id = ToId(id)
    if not id then return false, 'err.invalid_payload' end
    if not Enabled() then return false, 'err.rewards_off' end
    local cid = CitizenOf(src)
    if not cid then return false, 'err.not_police' end
    if InArena(src) then return false, 'err.reward_in_arena' end
    if not InventoryStarted() then return false, 'err.reward_no_inventory' end
    Db()
    local rows = Query('SELECT id, row_id, citizenid, item, count, status FROM cp_item_rewards WHERE id = ?', { id })
    local r = rows and rows[1]
    if not r or r.citizenid ~= cid then return false, 'err.reward_not_found' end
    if r.status ~= 'pending' then return false, 'err.reward_not_claimable' end
    local res = WithLock(cid, function() return table.pack(GiveRow(r, src)) end)
    Push(cid)
    if not res then return false, 'err.internal' end
    if not res[1] then return false, res[2] end
    return true, { id = id }
end

local function AdminRows(sql, params)
    local out = {}
    for _, r in ipairs(Query(sql, params) or {}) do
        local row = RewardRow(r)
        row.rowId = ToId(r.row_id)
        out[#out + 1] = row
    end
    return out
end

local STATUS_SET = { held = true, pending = true, giving = true, given = true, forfeited = true }
local SOURCE_SET = { run = true, medal = true, goal = true, level = true, boss = true, season = true }

-- WHERE for the admin filters: sql, params | nil, errKey. args: { citizenid, status, source, from, to }.
local function AdminWhere(args)
    local parts, params = {}, {}
    if type(args) ~= 'table' then return '1 = 1', params end
    if args.citizenid ~= nil and args.citizenid ~= '' then
        if not ValidCitizenId(args.citizenid) then return nil, 'err.invalid_filter' end
        parts[#parts + 1] = 'r.citizenid = ?'
        params[#params + 1] = args.citizenid
    end
    if args.status ~= nil and args.status ~= '' then
        if not STATUS_SET[args.status] then return nil, 'err.invalid_filter' end
        parts[#parts + 1] = 'r.status = ?'
        params[#params + 1] = args.status
    end
    if args.source ~= nil and args.source ~= '' then
        if not SOURCE_SET[args.source] then return nil, 'err.invalid_filter' end
        parts[#parts + 1] = 'r.source = ?'
        params[#params + 1] = args.source
    end
    local from, to = tonumber(args.from), tonumber(args.to)
    if (args.from ~= nil and not from) or (args.to ~= nil and not to) then return nil, 'err.invalid_filter' end
    if from then
        parts[#parts + 1] = 'r.created_at >= FROM_UNIXTIME(?)'
        params[#params + 1] = math.floor(from)
    end
    if to then
        parts[#parts + 1] = 'r.created_at < FROM_UNIXTIME(?)'
        params[#params + 1] = math.floor(to)
    end
    if #parts == 0 then return '1 = 1', params end
    return table.concat(parts, ' AND '), params
end

-- args: a page number (old callers) or { page, citizenid, status, source, from, to }.
function Rewards.adminView(args)
    if type(args) ~= 'table' then args = { page = args } end
    local page = math.max(1, math.floor(Num(args.page, 1)))
    local where, params = AdminWhere(args)
    if not where then return nil, params end
    EnsureChecked()
    Db()
    local pools = {}
    for _, pool in ipairs(Pools()) do
        local items = {}
        for _, spec in ipairs(pool.specs) do
            items[#items + 1] = { item = tostring(spec.item), ok = Usable(spec.item) }
        end
        pools[#pools + 1] = { key = pool.key, items = items }
    end
    local week = { given = 0, held = 0, forfeited = 0 }
    local sums = Query([[
        SELECT status, COALESCE(SUM(count), 0) AS n FROM cp_item_rewards WHERE created_at >= FROM_UNIXTIME(?)
        GROUP BY status
    ]], { WeekStart() })
    for _, r in ipairs(sums or {}) do
        if week[r.status] ~= nil then week[r.status] = math.floor(U.num(r.n)) end
    end
    local from = 'SELECT '
        .. ROW_COLS
        .. [[, o.display_name FROM cp_item_rewards r
        LEFT JOIN cp_officers o ON o.citizenid = r.citizenid]]
    local stuck = AdminRows(from .. ' WHERE r.status = \'giving\' ORDER BY r.id', {})
    local q = CP.U.copy(params)
    q[#q + 1] = ADMIN_PAGE
    q[#q + 1] = (page - 1) * ADMIN_PAGE
    local recent = AdminRows(from .. ' WHERE ' .. where .. ' ORDER BY r.id DESC LIMIT ? OFFSET ?', q)
    for _, list in ipairs({ stuck, recent }) do
        for _, r in ipairs(list) do r.online = SrcOf(r.citizenid) ~= nil end
    end
    return {
        enabled = Enabled(),
        allowTakeBack = Cfg().allowTakeBack == true,
        page = page,
        pageSize = ADMIN_PAGE,
        pools = pools,
        week = week,
        stuck = stuck,
        recent = recent,
        health = Rewards.health(),
    }
end

-- ============================================================================
--                                 NET HANDLERS
-- ============================================================================

CP.Net.callback('getRewardsLocker', function(src)
    return Rewards.locker(src)
end)

CP.Net.action('server:rewards:claim', function(src, payload)
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    return Rewards.claim(src, payload.id)
end, { rate = 2 })

CP.Net.callback('admin:getRewards', function(src, args)
    local ok, errKey = CP.Permissions.can(src, 'openAdmin')
    if not ok then return nil, errKey or 'err.no_permission' end
    if args ~= nil and type(args) ~= 'table' then return nil, 'err.invalid_payload' end
    return Rewards.adminView(args or {})
end)

-- ============================================================================
--                  ADMIN TOOLS (LEADERBOARDS → ITEM REWARDS)
-- ============================================================================
-- Resolve a reward stuck in 'giving', deliver now, cancel, and take an item back (ships off). The inventory of an
-- offline officer can't be read, so every inventory step needs the officer online. "Not found" means given (the
-- item may have been used, dropped or moved): a reward is never given twice by a guess.

local function RewardById(id)
    id = ToId(id)
    if not id then return nil end
    Db()
    local rows = Query('SELECT ' .. ROW_COLS .. ' FROM cp_item_rewards r WHERE r.id = ?', { id })
    return rows and rows[1] or nil
end

local function RewardTarget(id) return ('reward #%d'):format(id) end

-- The officer's slots holding the item tagged with this reward (metadata cpReward = id): count, slots.
local function TaggedSlots(src, item, id)
    if not InventoryStarted() then return nil end
    local ok, res = pcall(function() return exports.ox_inventory:Search(src, 'slots', item, { cpReward = id }) end)
    if not ok then
        CP.err(TAG, 'ox_inventory Search failed for reward %d: %s', id, tostring(res))
        return nil
    end
    local count, slots = 0, {}
    for _, sl in pairs(type(res) == 'table' and res or {}) do
        if type(sl) == 'table' and math.floor(Num(sl.count, 0)) > 0 then
            count = count + math.floor(Num(sl.count, 0))
            slots[#slots + 1] = sl
        end
    end
    return count, slots
end

-- What the inventory says about one reward: { id, status, online, found, count, needed }.
function Rewards.checkInventory(id)
    local r = RewardById(id)
    if not r then return nil, 'err.reward_not_found' end
    id = math.floor(U.num(r.id))
    local src = SrcOf(r.citizenid)
    local out = {
        id = id,
        status = r.status,
        item = r.item,
        label = Label(r.item),
        needed = math.floor(U.num(r.count, 1)),
        online = src ~= nil,
        found = nil,
        count = nil,
    }
    if not src then return out end
    local count = TaggedSlots(src, r.item, id)
    if count == nil then return nil, 'err.reward_no_inventory' end
    out.count, out.found = count, count > 0
    return out
end

-- outcome 'given' (found, or not found: the default) or 'locker' (not found, typed LOCKER): back to pending and
-- delivered again. audit(info) -> id|false is called once the row is claimed.
function Rewards.resolve(id, outcome, audit)
    local r = RewardById(id)
    if not r then return false, 'err.reward_not_found' end
    id = math.floor(U.num(r.id))
    if r.status ~= 'giving' then return false, 'err.state_changed' end
    local cid = r.citizenid
    if locks[cid] then return false, 'err.reward_busy' end
    local src = SrcOf(cid)
    if not src then return false, 'err.officer_offline' end
    local count = TaggedSlots(src, r.item, id)
    if count == nil then return false, 'err.reward_no_inventory' end
    if outcome == 'locker' and count > 0 then return false, 'err.reward_found' end
    if outcome ~= 'given' and outcome ~= 'locker' then return false, 'err.invalid_payload' end
    local n
    if outcome == 'given' then
        n = Update([[UPDATE cp_item_rewards SET status = 'given', given_at = FROM_UNIXTIME(?)
            WHERE id = ? AND status = 'giving']], { Now(), id })
    else
        n = Update('UPDATE cp_item_rewards SET status = \'pending\' WHERE id = ? AND status = \'giving\'', { id })
    end
    if not n or n < 1 then return false, 'err.state_changed' end
    if type(audit) == 'function' then pcall(audit, { found = count > 0, outcome = outcome }) end
    if r.row_id then SyncBreakdown(r.row_id) end
    Push(cid)
    if outcome == 'locker' then Rewards.deliver(cid) end
    return true, { id = id, status = outcome == 'given' and 'given' or 'pending', found = count > 0 }
end

-- Cancel: a pending or held reward is forfeited (the run keeps its points and its cash).
function Rewards.cancel(id)
    local r = RewardById(id)
    if not r then return false, 'err.reward_not_found' end
    id = math.floor(U.num(r.id))
    local n = Update([[UPDATE cp_item_rewards SET status = 'forfeited' WHERE id = ? AND status IN ('pending', 'held')]],
        { id })
    if not n or n < 1 then return false, 'err.state_changed' end
    if r.row_id then SyncBreakdown(r.row_id) end
    Push(r.citizenid)
    return true, { id = id, status = 'forfeited', citizenid = r.citizenid, from = r.status }
end

-- Take back: exactly the tagged item, from an online officer, under the officer's reward lock. The claim is the
-- status change given -> forfeited; a refused removal puts it back.
function Rewards.takeBack(id, audit)
    local r = RewardById(id)
    if not r then return false, 'err.reward_not_found' end
    id = math.floor(U.num(r.id))
    if r.status ~= 'given' then return false, 'err.state_changed' end
    local cid = r.citizenid
    local src = SrcOf(cid)
    if not src then return false, 'err.officer_offline' end
    local need = math.floor(U.num(r.count, 1))
    local res = WithLock(cid, function()
        local count, slots = TaggedSlots(src, r.item, id)
        if count == nil then return { false, 'err.reward_no_inventory' } end
        if count < need then return { false, 'err.reward_not_in_inventory' } end
        local n = Update('UPDATE cp_item_rewards SET status = \'forfeited\' WHERE id = ? AND status = \'given\'',
            { id })
        if not n or n < 1 then return { false, 'err.state_changed' } end
        if type(audit) == 'function' then
            local okA, aid = pcall(audit, { count = need })
            if not okA or not aid then
                Update('UPDATE cp_item_rewards SET status = \'given\' WHERE id = ? AND status = \'forfeited\'', { id })
                return { false, 'err.audit_failed' }
            end
        end
        local left = need
        for _, sl in ipairs(slots) do
            if left <= 0 then break end
            local take = math.min(left, math.floor(Num(sl.count, 0)))
            local okR, removed = pcall(function()
                return exports.ox_inventory:RemoveItem(src, r.item, take, { cpReward = id }, sl.slot)
            end)
            if okR and removed then left = left - take end
        end
        if left > 0 then
            CP.warn(TAG, 'reward %d: %d of %d x %s could not be taken back', id, left, need, r.item)
            if left == need then
                Update('UPDATE cp_item_rewards SET status = \'given\' WHERE id = ? AND status = \'forfeited\'', { id })
                return { false, 'err.reward_not_in_inventory' }
            end
        end
        return { true, { id = id, status = 'forfeited', taken = need - left } }
    end)
    if not res then return false, 'err.internal' end
    if res[1] then
        if r.row_id then SyncBreakdown(r.row_id) end
        Push(cid)
        Notify(src, 'warning', 'rewards.taken_back', { count = res[2].taken, item = Label(r.item) })
    end
    return res[1], res[2]
end

-- row:forfeitUndone (an admin undid the forfeiture of a row: Unretire, a batch Undo, forfeited cash paid after all):
-- the row's forfeited rewards come back once, pending (held while the row is still voided). Rewards an admin
-- cancelled or took back stay forfeited.
function Rewards.undoForfeit(rowId)
    rowId = ToId(rowId)
    if not rowId then return 0 end
    Db()
    local run = Query('SELECT voided FROM cp_mission_runs WHERE id = ?', { rowId })
    if not run or not run[1] then return 0 end
    local status = U.truthy(run[1].voided) and 'held' or 'pending'
    local rows = Query([[SELECT id, citizenid FROM cp_item_rewards WHERE row_id = ? AND status = 'forfeited'
        ORDER BY id]], { rowId }) or {}
    local n, cids = 0, {}
    for _, r in ipairs(rows) do
        local id = math.floor(U.num(r.id))
        local byAdmin = Query([[SELECT COUNT(*) AS n FROM cp_audit WHERE target = ?
            AND action IN ('rewardCancel', 'rewardTakeBack')]], { RewardTarget(id) })
        if byAdmin and math.floor(U.num(byAdmin[1] and byAdmin[1].n)) == 0 then
            local c = Update('UPDATE cp_item_rewards SET status = ? WHERE id = ? AND status = \'forfeited\'',
                { status, id })
            if c and c > 0 then
                n = n + 1
                cids[r.citizenid] = true
            end
        end
    end
    if n > 0 then
        SyncBreakdown(rowId)
        for cid in pairs(cids) do
            Push(cid)
            if status == 'pending' then Rewards.deliver(cid) end
        end
    end
    return n
end

-- ============================================================================
--                   THE POOL CHECK (SETTINGS → ITEM REWARDS)
-- ============================================================================
-- Every Rewards.* change goes through this validator (the structured pool editor and the raw editor alike), and
-- the item check runs again after the change.

local function CheckSpec(spec, pooled)
    if type(spec) ~= 'table' then return 'err.reward_pool_shape' end
    if type(spec.item) ~= 'string' or spec.item == '' or #spec.item > 64 then return 'err.reward_pool_shape' end
    if Rewards.forbidden(spec.item) then return 'err.reward_item_forbidden' end
    local c = spec.count
    if c == nil then c = 1 end
    if type(c) == 'table' then
        local lo, hi = tonumber(c[1]), tonumber(c[2])
        if not lo or not hi or lo ~= math.floor(lo) or hi ~= math.floor(hi) or lo < 1 or hi < lo or hi > MAX_COUNT then
            return 'err.reward_count'
        end
    elseif type(c) ~= 'number' or c ~= math.floor(c) or c < 1 or c > MAX_COUNT then
        return 'err.reward_count'
    end
    if pooled and spec.weight ~= nil and (type(spec.weight) ~= 'number' or not (spec.weight > 0)) then
        return 'err.reward_weight'
    end
    if spec.value ~= nil and (type(spec.value) ~= 'number' or spec.value < 0) then return 'err.reward_value' end
    return nil
end

local function CheckSpecs(v)
    if type(v) ~= 'table' then return 'err.reward_pool_shape' end
    if v.item ~= nil then return CheckSpec(v, false) end
    for _, spec in pairs(v) do
        local err = CheckSpec(spec, false)
        if err then return err end
    end
    return nil
end

local function CheckEntry(e)
    if type(e) ~= 'table' or type(e.pool) ~= 'table' then return 'err.reward_pool_shape' end
    if e.chance ~= nil and (type(e.chance) ~= 'number' or e.chance < 0 or e.chance > 1) then
        return 'err.reward_chance'
    end
    if e.rolls ~= nil
        and (type(e.rolls) ~= 'number' or e.rolls ~= math.floor(e.rolls) or e.rolls < 0 or e.rolls > MAX_ROLLS) then
        return 'err.reward_rolls'
    end
    for _, spec in pairs(e.pool) do
        local err = CheckSpec(spec, true)
        if err then return err end
    end
    return nil
end

local function CheckMap(v, each)
    if type(v) ~= 'table' then return 'err.reward_pool_shape' end
    for _, e in pairs(v) do
        local err = each(e)
        if err then return err end
    end
    return nil
end

-- errKey | nil for one Rewards.* path and its new value.
function Rewards.checkSetting(path, value)
    local seg = {}
    for part in tostring(path):gmatch('[^%.]+') do seg[#seg + 1] = part end
    if seg[1] ~= 'Rewards' then return nil end
    local key = seg[2]
    if #seg == 2 then
        if key == 'byType' or key == 'byMission' or key == 'examplePools' then return CheckMap(value, CheckEntry) end
        if key == 'medals' or key == 'goals' or key == 'levels' or key == 'season' then
            return CheckMap(value, CheckSpecs)
        end
        if key == 'weeklyBoss' then
            if value == nil then return nil end
            return CheckSpecs(value)
        end
        return nil
    end
    if key == 'byType' or key == 'byMission' or key == 'examplePools' then
        if #seg == 3 then return CheckEntry(value) end
        if seg[4] == 'pool' and #seg == 4 then return CheckEntry({ pool = value }) end
        if seg[4] == 'chance' then return CheckEntry({ pool = {}, chance = value }) end
        if seg[4] == 'rolls' then return CheckEntry({ pool = {}, rolls = value }) end
    end
    if (key == 'medals' or key == 'goals' or key == 'levels' or key == 'season') and #seg == 3 then
        return CheckSpecs(value)
    end
    return nil
end

local function CountMean(c)
    if type(c) == 'table' then
        local lo = math.max(1, math.floor(Num(c[1], 1)))
        local hi = math.max(lo, math.floor(Num(c[2], lo)))
        return (math.min(lo, MAX_COUNT) + math.min(hi, MAX_COUNT)) / 2
    end
    return math.min(MAX_COUNT, math.max(1, math.floor(Num(c, 1))))
end

-- The expected items and value per run of one run entry at each scaling tier (no evidence finds), in Lua.
function Rewards.expected(entry)
    local out = {}
    local pool = {}
    for _, s in ipairs(PoolList(entry)) do
        if Usable(s.item) and Num(s.weight, 1) > 0 then pool[#pool + 1] = s end
    end
    local total = 0
    for _, s in ipairs(pool) do total = total + Num(s.weight, 1) end
    local items, value = 0, 0
    for _, s in ipairs(pool) do
        local share = Num(s.weight, 1) / total
        local mean = CountMean(s.count)
        items = items + share * mean
        value = value + share * mean * math.max(0, math.floor(Num(s.value, 0)))
    end
    local rolls = math.min(MAX_ROLLS, math.max(0, math.floor(Num(type(entry) == 'table' and entry.rolls, 1))))
    for _, tier in ipairs(TIERS) do
        local chance = Rewards.chanceFor(entry, tier, 0)
        out[#out + 1] = {
            tier = tier,
            chance = chance,
            items = math.floor(rolls * chance * items * 100 + 0.5) / 100,
            value = math.floor(rolls * chance * value * 100 + 0.5) / 100,
        }
    end
    return out
end

-- The item picker: every ox_inventory item a reward may be (forbidden names left out), by name.
function Rewards.itemChoices()
    if not InventoryStarted() then return { items = {}, inventory = false } end
    local ok, all = pcall(function() return exports.ox_inventory:Items() end)
    if not ok or type(all) ~= 'table' then return { items = {}, inventory = false } end
    local out = {}
    for name, def in pairs(all) do
        if type(name) == 'string' and not Rewards.forbidden(name) then
            out[#out + 1] = {
                name = name,
                label = type(def) == 'table' and type(def.label) == 'string' and def.label or name,
            }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    while #out > 2000 do out[#out] = nil end
    return { items = out, inventory = true }
end

-- ============================================================================
--                                     NET
-- ============================================================================

local function SelfOfReward(p, strict)
    local r = RewardById(p.id)
    if not r then return nil end
    return { citizenid = r.citizenid, strict = strict }
end

if CP.AdminKit and CP.AdminKit.action then
    local Kit = CP.AdminKit

    Kit.callback('admin:checkRewardInventory', 'rewardsAdmin', function(ctx)
        return Rewards.checkInventory(ctx.args.id)
    end, { rate = 2 })

    Kit.callback('admin:rewardItems', 'rewardsAdmin', function() return Rewards.itemChoices() end, { rate = 1 })

    -- The pool editor's preview: the server's verdict on a value and the expected items and value per tier.
    Kit.callback('admin:rewardPoolPreview', 'rewardsAdmin', function(ctx)
        local path = ctx.args.path
        if type(path) ~= 'string' or path:sub(1, 8) ~= 'Rewards.' then return nil, 'err.invalid_payload' end
        local err = Rewards.checkSetting(path, ctx.args.value)
        local expected = {}
        local key = path:match('^Rewards%.(%a+)$')
        if not err and (key == 'byType' or key == 'byMission' or key == 'examplePools')
            and type(ctx.args.value) == 'table' then
            for k, e in pairs(ctx.args.value) do
                expected[#expected + 1] = { key = tostring(k), tiers = Rewards.expected(e) }
            end
            table.sort(expected, function(a, b) return a.key < b.key end)
        end
        return { error = err, expected = expected }
    end, { rate = 4 })

    Kit.action('server:admin:resolveReward', 'rewardsAdmin', function(ctx)
        local p = ctx.payload
        local outcome = p.outcome == 'locker' and 'locker' or 'given'
        local ok, data = Rewards.resolve(p.id, outcome, function(info)
            return ctx.audit('rewardResolve', RewardTarget(ToId(p.id) or 0), 'giving',
                ('%s%s'):format(info.outcome, info.found and ':found' or ':not_found'))
        end)
        return ok, data
    end, {
        reason = true,
        confirm = function(p) return p.outcome == 'locker' and 'LOCKER' or nil end,
        self = function(p) return SelfOfReward(p, false) end,
    })

    Kit.action('server:admin:deliverRewards', 'rewardsAdmin', function(ctx)
        local cid = ctx.payload.citizenid
        if not ValidCitizenId(cid) then return false, 'err.invalid_citizenid' end
        if not Enabled() then return false, 'err.rewards_off' end
        if not SrcOf(cid) then return false, 'err.officer_offline' end
        local n = Rewards.deliver(cid)
        ctx.audit('rewardDeliver', cid, nil, tostring(n))
        return true, { given = n }
    end, {
        self = function(p) return { citizenid = p.citizenid } end,
    })

    Kit.action('server:admin:cancelReward', 'rewardsAdmin', function(ctx)
        local id = ToId(ctx.payload.id)
        if not id then return false, 'err.invalid_payload' end
        local ok, data = Rewards.cancel(id)
        if not ok then return false, data end
        ctx.audit('rewardCancel', RewardTarget(id), data.from, 'forfeited')
        ctx.notify(data.citizenid, 'warning', 'rewards.cancelled', {})
        return true, { id = id, status = 'forfeited' }
    end, {
        reason = true,
        self = function(p) return SelfOfReward(p, false) end,
    })

    Kit.action('server:admin:takeBackReward', 'rewardsAdmin', function(ctx)
        if Cfg().allowTakeBack ~= true then return false, 'err.money_tool_off' end
        local id = ToId(ctx.payload.id)
        if not id then return false, 'err.invalid_payload' end
        return Rewards.takeBack(id, function(info)
            return ctx.audit('rewardTakeBack', RewardTarget(id), 'given', ('-%d'):format(info.count or 0))
        end)
    end, {
        requestId = true,
        reason = true,
        confirm = function(p)
            local r = RewardById(p.id)
            return r and tostring(r.item) or '-'
        end,
        self = function(p) return SelfOfReward(p, true) end,
    })
end

-- ============================================================================
--                                    HOOKS
-- ============================================================================

-- Home: "rewards waiting", read from the cache only (the hook may not yield); a miss is read for the next refresh.
local function HomeExtras(citizenid, _, extras)
    if type(extras) ~= 'table' or not ValidCitizenId(citizenid) then return end
    local c = counts[citizenid]
    if not c or Now() - c.at >= COUNT_CACHE_S then CreateThread(function() Rewards.lockerCount(citizenid) end) end
    if c and c.n > 0 then extras.rewardsWaiting = c.n end
end

local function OnLoaded(src)
    arenaWait[src] = nil
    local cid = CitizenOf(src)
    if cid then Rewards.deliver(cid) end
end

-- arena:exited (may not yield): retried 10 s later, when Crimson-Arena has handed the inventory back.
local function OnArenaExited(src)
    if not Enabled() then return end
    arenaWait[src] = nil
    SetTimeout(ARENA_RETRY_MS, function()
        if InArena(src) then return end
        local cid = CitizenOf(src)
        if cid then Rewards.deliver(cid) end
    end)
end

if CP.Hooks and CP.Hooks.on then
    CP.Hooks.on('row:settled', OnRowSettled)
    CP.Hooks.on('row:approved', OnRowApproved)
    CP.Hooks.on('row:voided', OnRowVoided)
    CP.Hooks.on('row:forfeited', OnRowForfeited)
    CP.Hooks.on('goal:completed', OnGoalCompleted)
    CP.Hooks.on('xp:levelUp', OnLevelUp)
    CP.Hooks.on('season:ended', OnSeasonEnded)
    CP.Hooks.on('officer:loaded', OnLoaded)
    CP.Hooks.on('arena:exited', OnArenaExited)
    CP.Hooks.on('home:extras', HomeExtras)
    CP.Hooks.on('row:forfeitUndone', function(rowId) Rewards.undoForfeit(rowId) end)
    -- a Rewards.* setting changed in game: the item check runs again at once
    CP.Hooks.on('settings:changed', function(paths)
        for _, path in ipairs(type(paths) == 'table' and paths or {}) do
            if tostring(path):sub(1, 8) == 'Rewards.' then
                Rewards.validate()
                return
            end
        end
    end)
end

-- modules/settings loads after this file: the validator is registered once every file has loaded
CreateThread(function()
    if CP.Settings and CP.Settings.registerValidator then
        CP.Settings.registerValidator('Rewards', function(path, clean) return Rewards.checkSetting(path, clean) end)
    end
end)

-- The item check after the start (ox_inventory has registered its items by then), and the Config health lines.
CreateThread(function()
    Wait(START_CHECK_MS)
    Rewards.validate()
    -- CP.ConfigHealth comes with the access and UI shell package; until then admin:getRewards shows these lines
    local health = CP.ConfigHealth
    if type(health) == 'table' and type(health.register) == 'function' then
        health.register('rewards', Rewards.health)
    end
end)

CreateThread(function()
    Wait(START_CHECK_MS)
    while true do
        ForfeitureJob()
        Wait(FORFEIT_EVERY_MS)
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    arenaWait[src] = nil
end)

-- Test hooks (not part of the contract).
Rewards._reset = function()
    bad, labels, checked, inventoryUp, locks, counts, arenaWait = {}, {}, false, nil, {}, {}, {}
end
Rewards._arenaWait = function(src) return arenaWait[src] == true end
Rewards._giveRow = GiveRow
Rewards._forfeitureJob = ForfeitureJob

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    locks, counts, arenaWait = {}, {}, {}
end)

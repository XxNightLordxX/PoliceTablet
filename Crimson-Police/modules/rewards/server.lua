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
local MEDALS = { [1] = 'gold', [2] = 'silver', [3] = 'bronze' }
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

local function Usable(name)
    if type(name) ~= 'string' or name == '' then return false end
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
local function ForfeitureJob()
    Db()
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
    for _, r in ipairs(Query(sql, params) or {}) do out[#out + 1] = RewardRow(r) end
    return out
end

function Rewards.adminView(page)
    page = math.max(1, math.floor(Num(page, 1)))
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
    local recent = AdminRows(from .. ' ORDER BY r.id DESC LIMIT ? OFFSET ?', { ADMIN_PAGE, (page - 1) * ADMIN_PAGE })
    return {
        enabled = Enabled(),
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
    return Rewards.adminView(args and args.page)
end)

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
end

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

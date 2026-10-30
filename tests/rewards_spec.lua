-- CP.Rewards (modules/rewards): optional item rewards. Off by default, deterministic rolls, held and forfeited
-- with the run, daily caps, delivery (room, Crimson-Arena, offline), the locker, validation and example pools.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = true   -- run every CP.log format string too

local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    if line:find('[crimson-police', 1, true) then return end
    realPrint(line)
end

-- Wednesday 2026-09-23 12:00.
local NOW = os.time({ year = 2026, month = 9, day = 23, hour = 12, min = 0, sec = 0 })
H.time = NOW
local DAY = 86400

-- ============================================================================
--                                    STUBS
-- ============================================================================

local online = {}     -- online[src] = citizenid
local arena = {}      -- arena[src] = true while in Crimson-Arena
local notes, pushes, warns = {}, {}, {}
CP.Qbx = {
    getInfo = function(src)
        local cid = online[tonumber(src)]
        return cid and { citizenid = cid, name = cid } or nil
    end,
    getByCitizenId = function(cid)
        for src, c in pairs(online) do if c == cid then return src end end
        return nil
    end,
    onPlayerLoaded = function() end,
    onDutyChange = function() end,
}
CP.Alerts = {
    inArena = function(src) return arena[tonumber(src)] == true end,
}
CP.Tablet = {
    notify = function(src, kind, key, vars) notes[#notes + 1] = { src = src, kind = kind, key = key, vars = vars } end,
    push = function(src, topic) pushes[#pushes + 1] = { src = src, topic = topic } end,
}
CP.Permissions = {
    can = function(src) if tonumber(src) == 1 then return true end return false, 'err.no_permission' end,
}
local realWarn = CP.warn
CP.warn = function(tag, fmt, ...)
    if tag == 'rewards' then warns[#warns + 1] = tostring(fmt):format(...) end
    return realWarn(tag, fmt, ...)
end

-- ox_inventory with every call counted
local inv = H.mockInventory(
    { water = { label = 'Water' }, burger = { label = 'Burger' }, sprunk = { label = 'Sprunk' } })
local invCalls = 0
for name, fn in pairs(H.exportsMock.ox_inventory) do
    H.exportsMock.ox_inventory[name] = function(...)
        invCalls = invCalls + 1
        return fn(...)
    end
end

H.load('modules/schedule/server.lua')
H.load('modules/rewards/server.lua')
local R = CP.Rewards
H.advance(5000)   -- the start check

local function Tick() H.clockMs = H.clockMs + 1001 end
local function Cb(name, src, args)
    Tick()
    return H.callback('crimson-police:' .. name, src, args)
end
local function Act(name, src, payload)
    Tick()
    H.reset()
    H.fire('crimson-police:' .. name, src, payload, 'rq')
    local ev = H.findEvents('crimson-police:client:actionResult')[1]
    if not ev then return nil, 'no reply' end
    return ev.args[2], ev.args[3]
end
local function Rows(cid)
    return H.sql(
        'SELECT id, row_id, source, source_key, item, count, value, status FROM cp_item_rewards WHERE citizenid = ? ORDER BY id',
        { cid })
end
local function AllRows() return H.sql('SELECT id, citizenid, status FROM cp_item_rewards ORDER BY id') end
local function Contains(s, needle) return type(s) == 'string' and s:find(needle, 1, true) ~= nil end
local function Added(name)
    local n = 0
    for _, a in ipairs(inv.added) do if name == nil or a.name == name then n = n + 1 end end
    return n
end

local function BaseConfig()
    Config.Rewards.enabled = true
    Config.Rewards.dailyItemCap = 10
    Config.Rewards.dailyValueCap = 2000
    Config.Rewards.byType = {
        tactical = { chance = 1.0, rolls = 2, pool = { { item = 'water', count = 1, weight = 1, value = 20 } } },
    }
    Config.Rewards.byMission = {}
    Config.Rewards.medals = {}
    Config.Rewards.goals = {}
    Config.Rewards.levels = {}
    Config.Rewards.weeklyBoss = nil
    Config.Rewards.season = {}
    Config.Rewards.useExamplePools = false
    R._reset()
    R.validate()
end

local nextRow = 100
local function Run(id, opts)
    opts = opts or {}
    return {
        id = id,
        test = opts.test,
        flagged = opts.runFlagged,
        isBoss = opts.isBoss,
        order = opts.order or { 11 },
    }
end
local function Settle(runId, cid, opts)
    opts = opts or {}
    nextRow = nextRow + 1
    local rowId = opts.rowId or nextRow
    local run = Run(runId, opts)
    local p = { src = opts.src, citizenid = cid, flagged = opts.flagged, presence = opts.presence }
    local row = {
        citizenid = cid,
        state = opts.state or 'completed',
        mission_id = opts.missionId or 'some_raid',
        mission_type = opts.missionType or 'tactical',
        tier = opts.tier or 'standard',
        evidence = opts.evidence or 0,
        medal = opts.medal,
        flagged = (opts.flagged or opts.runFlagged) and 1 or 0,
    }
    local rr = { items = {} }
    CP.Hooks.fire('row:settled', run, p, rowId, row, rr)
    return rowId, rr
end

H.sql('DELETE FROM cp_item_rewards')
H.sql('DELETE FROM cp_mission_runs')
online[11], online[12], online[13] = 'CID1', 'CID2', 'CID3'

-- ============================================================================
--                                    1. OFF
-- ============================================================================

do
    H.eq(Config.Rewards.enabled, false, 'item rewards ship off')
    invCalls = 0
    local _, rr = Settle('OFF-1', 'CID1', { src = 11 })
    CP.Hooks.fire('goal:completed', 'CID1', 'daily_3', 'daily:2026-09-23')
    CP.Hooks.fire('officer:loaded', 11)
    CP.Hooks.fire('arena:exited', 11)
    H.advance(11000)
    H.eq(#AllRows(), 0, 'off: no rows')
    H.eq(invCalls, 0, 'off: no inventory calls')
    H.eq(#rr.items, 0, 'off: no items on the result')
    local health = R.health()
    H.eq(health[1].text, 'Item rewards: off (example pool available)', 'off: Config health line')
    local locker = Cb('getRewardsLocker', 11).data
    H.eq(#locker.rows, 0, 'off: an empty locker')
    H.eq(locker.canClaim, false, 'off: nothing can be claimed')
    H.eq(locker.reason, 'rewards.reason.off', 'off: the reason')
end

-- ============================================================================
--                                2. VALIDATION
-- ============================================================================

do
    BaseConfig()
    Config.Rewards.byType = {
        patrol = {
            chance = 1.0,
            rolls = 1,
            pool = {
                { item = 'WEAPON_PISTOL', weight = 1 },
                { item = 'Weapon_Pistol', weight = 1 },
                { item = 'weapon_pistol', weight = 1 },
                { item = 'ammo-9', weight = 1 },
                { item = 'Armour', weight = 1 },
                { item = 'BANDAGE', weight = 1 },
                { item = 'money', weight = 1 },
                { item = 'Black_Money', weight = 1 },
                { item = 'cash', weight = 1 },
                { item = 'radio', weight = 1 },
                { item = 'water', count = 1, weight = 1, value = 20 },
            },
        },
    }
    Config.Rewards.forbidden = {
        'weapon_*',
        'ammo-*',
        'armour',
        'bandage',
        'money',
        'black_money',
        'cash',
        'lockpick*',
    }
    Config.Rewards.medals = { gold = { item = 'LockPick_Advanced', count = 1, value = 50 } }
    warns = {}
    R._reset()
    local bad = R.validate()
    for _, name in ipairs({ 'weapon_pistol', 'ammo-9', 'armour', 'bandage', 'money', 'black_money', 'cash' }) do
        H.eq(bad[name] and bad[name].why, 'forbidden', name .. ' is refused, any case')
    end
    H.eq(bad.radio and bad.radio.why, 'missing', 'an item ox_inventory does not know is refused')
    H.eq(bad.lockpick_advanced and bad.lockpick_advanced.why, 'forbidden', 'a config pattern, case-insensitively')
    H.eq(bad.water, nil, 'water is fine')
    H.ok(R.forbidden('WEAPON_PISTOL') and R.forbidden('Weapon_Pistol') and R.forbidden('weapon_pistol'),
        'forbidden() for every case of a weapon')
    H.ok(R.forbidden('ammo-rifle') and not R.forbidden('ammobox') and not R.forbidden('burger'),
        'patterns are anchored: ammo-* but not ammobox')
    local sawWeapon, sawRadio = false, false
    for _, w in ipairs(warns) do
        if Contains(w, 'WEAPON_PISTOL') then sawWeapon = true end
        if Contains(w, '"radio" does not exist') then sawRadio = true end
    end
    H.ok(sawWeapon, 'a console warning for the forbidden item')
    H.ok(sawRadio, 'a console warning for the missing item')
    local lines, forbiddenLine, missingLine = R.health(), false, false
    for _, l in ipairs(lines) do
        if l.level == 'warn' and Contains(l.text, 'weapon_pistol') or Contains(l.text, 'WEAPON_PISTOL') then
            forbiddenLine = true
        end
        if l.level == 'warn' and Contains(l.text, '"radio"') and Contains(l.text, 'does not exist') then
            missingLine = true
        end
    end
    H.ok(forbiddenLine, 'a Config health entry for the forbidden item')
    H.ok(missingLine, 'a Config health entry for the missing item')
    -- only water can ever be rolled from that pool
    local seen = {}
    for i = 1, 40 do
        for _, r in ipairs(R.roll('VAL-' .. i, 'CID1', Config.Rewards.byType.patrol, 1.0)) do seen[r.item] = true end
    end
    H.eq(next(seen, next(seen)), nil, 'a pool with turned-off items rolls only the others')
    H.ok(seen.water, 'water is rolled')
    Settle('VAL-RUN', 'CID1', { src = 11, missionType = 'patrol', medal = 1 })
    for _, r in ipairs(Rows('CID1')) do H.eq(r.item, 'water', 'no forbidden or missing item is ever stored') end
    for _, a in ipairs(inv.added) do
        H.eq(a.meta and a.meta.cpItem, nil, 'rewards never carry cpItem')
        H.ok(a.meta and tonumber(a.meta.cpReward) ~= nil, 'rewards always carry cpReward = <id>')
    end
    H.ok(Added('water') >= 1, 'the valid item was given')
    Config.Rewards.forbidden = { 'weapon_*', 'ammo-*', 'armour', 'bandage', 'money', 'black_money', 'cash' }
    H.sql('DELETE FROM cp_item_rewards')
end

-- ============================================================================
--                                   3. ROLLS
-- ============================================================================

do
    BaseConfig()
    local entry = { chance = 0.25, rolls = 1, pool = { { item = 'water', count = 1 } } }
    H.near(R.chanceFor(entry, 'standard', 0), 0.25, 1e-9, 'chance: the entry alone')
    H.near(R.chanceFor(entry, 'heavy', 0), 0.35, 1e-9, 'chance: + tierChance heavy')
    H.near(R.chanceFor(entry, 'heavy', 2), 0.55, 1e-9, 'chance: + 10 points per lawful find')
    H.near(R.chanceFor(entry, 'heavy', 3), 0.65, 1e-9, 'chance: three finds = +30')
    H.near(R.chanceFor(entry, 'heavy', 7), 0.65, 1e-9, 'chance: the find bonus is capped at 30')
    H.near(R.chanceFor({ chance = 0.9 }, 'critical', 3), 1.0, 1e-9, 'chance: never above 1')

    local pool = {
        chance = 0.5,
        rolls = 3,
        pool = {
            { item = 'water', count = { 1, 3 }, weight = 3, value = 20 },
            { item = 'burger', weight = 1, value = 40 },
        },
    }
    local function Same(a, b)
        if #a ~= #b then return false end
        for i = 1, #a do
            if a[i].item ~= b[i].item or a[i].count ~= b[i].count or a[i].value ~= b[i].value then return false end
        end
        return true
    end
    local hits, differ = 0, 0
    for i = 1, 200 do
        local a = R.roll('RUN-' .. i, 'CID1', pool, 0.5)
        H.ok(Same(a, R.roll('RUN-' .. i, 'CID1', pool, 0.5)), 'the same run and officer roll the same (' .. i .. ')')
        if not Same(a, R.roll('RUN-' .. i, 'CID2', pool, 0.5)) then differ = differ + 1 end
        for _, r in ipairs(a) do
            hits = hits + 1
            if r.item == 'water' then
                H.ok(r.count >= 1 and r.count <= 9, 'water counts within 1-3 per roll')
                H.eq(r.value, r.count * 20, 'value = count x configured value')
            end
        end
    end
    H.ok(differ > 50, 'another officer rolls differently')
    H.ok(hits > 150 and hits < 450, 'about half of 600 rolls hit (' .. hits .. ')')
    H.eq(#R.roll('RUN-1', 'CID1', pool, 0), 0, 'chance 0 never hits')

    -- a settle and a second settle (a reconnect never rerolls)
    local rowId, rr = Settle('ROLL-1', 'CID1', { src = 11 })
    local rows = Rows('CID1')
    H.eq(#rows, 1, 'two water rolls make one row (one row per item and source)')
    H.eq(rows[1].count, 2, 'with the counts added')
    H.eq(rows[1].status, 'given', 'online: given at once')
    H.eq(rows[1].row_id, rowId, 'the row points at the run row')
    H.eq(rows[1].source_key, 'ROLL-1', 'source_key = run_uuid')
    H.eq(#rr.items, 1, 'the result screen lists the item')
    H.eq(rr.items[1].name, 'water', 'result item name')
    H.eq(rr.items[1].label, 'Water', 'result item label from ox_inventory')
    H.eq(rr.items[1].status, 'given', 'result item status')
    local added = #inv.added
    Settle('ROLL-1', 'CID1', { src = 11, rowId = rowId })
    H.eq(#Rows('CID1'), 1, 'a second settle adds no row')
    H.eq(#inv.added, added, 'and gives nothing again')

    -- presence, test runs and other results give nothing
    Settle('ROLL-2', 'CID2', { src = 12, flagged = { reason = 'presence' } })
    Settle('ROLL-3', 'CID2', { src = 12, order = { 11, 12 }, presence = { total = 100, inRange = 40 } })
    Settle('ROLL-4', 'CID2', { src = 12, test = { by = 'admin' } })
    Settle('ROLL-5', 'CID2', { src = 12, state = 'failed' })
    H.eq(#Rows('CID2'), 0, 'presence failure, test runs and failed runs give nothing')
    H.sql('DELETE FROM cp_item_rewards')
end

-- ============================================================================
--                                4. STATUS FLOW
-- ============================================================================

do
    BaseConfig()
    -- flagged -> held -> approved -> given
    local rowA = Settle('FLOW-A', 'CID1', { src = 11, flagged = { reason = 'idle' } })
    H.eq(Rows('CID1')[1].status, 'held', 'a flagged run holds its rewards')
    local before = #inv.added
    CP.Hooks.fire('row:approved', rowA)
    H.eq(Rows('CID1')[1].status, 'given', 'approved: given (online)')
    H.eq(#inv.added, before + 1, 'one AddItem')

    -- flagged, approved while offline -> pending, then officer:loaded
    local rowB = Settle('FLOW-B', 'CID2', { src = 12, runFlagged = { reason = 'fast' } })
    online[12] = nil
    CP.Hooks.fire('row:approved', rowB)
    H.eq(Rows('CID2')[1].status, 'pending', 'approved while offline: pending')
    online[12] = 'CID2'
    CP.Hooks.fire('officer:loaded', 12)
    H.eq(Rows('CID2')[1].status, 'given', 'given on officer:loaded')

    -- flagged -> voided -> forfeited
    local rowC = Settle('FLOW-C', 'CID3', { src = 13, flagged = { reason = 'idle' } })
    CP.Hooks.fire('row:voided', rowC)
    H.eq(Rows('CID3')[1].status, 'held', 'voided: still held for the dispute window')
    CP.Hooks.fire('row:forfeited', rowC)
    H.eq(Rows('CID3')[1].status, 'forfeited', 'forfeited when row:forfeited fires')
    CP.Hooks.fire('row:approved', rowC)
    H.eq(Rows('CID3')[1].status, 'forfeited', 'forfeited is final')

    -- an unflagged row with a pending (offline) reward, voided then forfeited
    online[13] = nil
    local rowD = Settle('FLOW-D', 'CID3', { src = nil })
    local d = Rows('CID3')[2]
    H.eq(d.status, 'pending', 'offline: pending in the locker')
    CP.Hooks.fire('row:voided', rowD)
    H.eq(Rows('CID3')[2].status, 'held', 'voided: a pending reward is held')
    CP.Hooks.fire('row:forfeited', rowD)
    H.eq(Rows('CID3')[2].status, 'forfeited', 'and forfeited with the run')
    online[13] = 'CID3'

    -- claim before give: a row already giving is never given twice
    online[13] = nil
    Settle('FLOW-E', 'CID3', { src = nil })
    local e = Rows('CID3')[3]
    H.sql('UPDATE cp_item_rewards SET status = \'giving\' WHERE id = ?', { e.id })
    online[13] = 'CID3'
    local n = #inv.added
    R.deliver('CID3')
    H.eq(#inv.added, n, 'a giving row is not given again')
    H.eq(Rows('CID3')[3].status, 'giving', 'and stays giving for an admin check')
    local ok, err = Act('server:rewards:claim', 13, { id = e.id })
    H.eq(ok, false, 'claiming a giving row is refused')
    H.eq(err, 'err.reward_not_claimable', 'not claimable')
    local view = Cb('admin:getRewards', 1, { page = 1 }).data
    H.eq(#view.stuck, 1, 'admin: the giving row is listed as stuck')
    H.eq(view.stuck[1].id, e.id, 'the stuck row')
    H.eq(Cb('admin:getRewards', 13, {}).error, 'err.no_permission', 'admin:getRewards needs openAdmin')
    H.sql('DELETE FROM cp_item_rewards')
end

-- ============================================================================
--                                 5. DELIVERY
-- ============================================================================

do
    BaseConfig()
    -- no room: the locker, then Claim
    inv.full[11] = true
    notes = {}
    Settle('DEL-A', 'CID1', { src = 11 })
    local a = Rows('CID1')[1]
    H.eq(a.status, 'pending', 'CanCarryItem false: the reward waits in the locker')
    local warned = false
    for _, nt in ipairs(notes) do if nt.key == 'rewards.locker_full' and nt.src == 11 then warned = true end end
    H.ok(warned, 'the officer is told it waits in the locker')
    local locker = Cb('getRewardsLocker', 11).data
    H.eq(#locker.rows, 1, 'the locker lists it')
    H.eq(locker.canClaim, true, 'and it can be claimed')
    H.eq(R.lockerCount('CID1'), 1, 'lockerCount')
    local ok, err = Act('server:rewards:claim', 11, { id = a.id })
    H.eq(ok, false, 'a claim with a full inventory is refused')
    H.eq(err, 'err.reward_no_room', 'no room')
    H.eq(Rows('CID1')[1].status, 'pending', 'and the reward stays pending')
    inv.full[11] = nil
    ok, err = Act('server:rewards:claim', 12, { id = a.id })
    H.eq(ok, false, 'another officer cannot claim it')
    H.eq(err, 'err.reward_not_found', 'not their row')
    ok = Act('server:rewards:claim', 11, { id = a.id })
    H.eq(ok, true, 'claimed')
    H.eq(Rows('CID1')[1].status, 'given', 'given')
    H.eq(R.lockerCount('CID1'), 0, 'the locker is empty')
    ok, err = Act('server:rewards:claim', 11, { id = a.id })
    H.eq(err, 'err.reward_not_claimable', 'a second claim does nothing')
    H.eq(select(2, Act('server:rewards:claim', 11, { id = 'x' })), 'err.invalid_payload', 'a bad id')
    local pushed = false
    for _, pu in ipairs(pushes) do if pu.src == 11 and pu.topic == 'rewards' then pushed = true end end
    H.ok(pushed, 'the locker is pushed to the officer (topic rewards)')

    -- Crimson-Arena: the locker, retried 10 s after arena:exited
    arena[12] = true
    local calls = invCalls
    Settle('DEL-B', 'CID2', { src = 12 })
    local b = Rows('CID2')[1]
    H.eq(b.status, 'pending', 'in the arena: the locker')
    H.eq(invCalls, calls, 'no inventory call for an in-arena player')
    H.ok(R._arenaWait(12), 'remembered for the arena exit')
    locker = Cb('getRewardsLocker', 12).data
    H.eq(locker.canClaim, false, 'no claim from inside the arena')
    H.eq(locker.reason, 'rewards.reason.arena', 'the reason')
    ok, err = Act('server:rewards:claim', 12, { id = b.id })
    H.eq(err, 'err.reward_in_arena', 'the server refuses the claim in the arena')
    arena[12] = nil
    CP.Hooks.fire('arena:exited', 12)
    H.advance(9000)
    H.eq(Rows('CID2')[1].status, 'pending', 'not before 10 s')
    H.advance(1500)
    H.eq(Rows('CID2')[1].status, 'given', 'given 10 s after arena:exited')

    -- offline: retried on officer:loaded
    online[13] = nil
    Settle('DEL-C', 'CID3', { src = nil })
    H.eq(Rows('CID3')[1].status, 'pending', 'offline: pending')
    online[13] = 'CID3'
    arena[13] = true
    CP.Hooks.fire('officer:loaded', 13)
    H.eq(Rows('CID3')[1].status, 'pending', 'loaded in the arena: still waiting')
    arena[13] = nil
    CP.Hooks.fire('officer:loaded', 13)
    H.eq(Rows('CID3')[1].status, 'given', 'given on officer:loaded')

    -- home extras from the cache
    online[13] = nil
    Settle('DEL-D', 'CID3', { src = nil })
    online[13] = 'CID3'
    H.eq(R.lockerCount('CID3'), 1, 'one waiting')
    local extras = {}
    CP.Hooks.fire('home:extras', 'CID3', 13, extras)
    H.eq(extras.rewardsWaiting, 1, 'Home: rewards waiting')
    H.sql('DELETE FROM cp_item_rewards')
end

-- ============================================================================
--                               6. EXAMPLE POOLS
-- ============================================================================

do
    BaseConfig()
    Config.Rewards.byType = {}
    Config.Rewards.useExamplePools = true
    R._reset()
    R.validate()
    H.eq(R.entryFor('beat_patrol', 'patrol'), Config.Rewards.examplePools.patrol,
        'a type with no byType entry: its example pool')
    Config.Rewards.byMission = { beat_patrol = { chance = 1.0, rolls = 1, pool = { { item = 'sprunk', value = 25 } } } }
    H.eq(R.entryFor('beat_patrol', 'patrol'), Config.Rewards.byMission.beat_patrol, 'byMission replaces the type')
    Config.Rewards.byMission = {}
    for i = 1, 40 do Settle('EX-' .. i, 'CID1', { src = 11, missionType = 'patrol', missionId = 'beat_patrol' }) end
    local n = #Rows('CID1')
    H.ok(n > 0 and n < 40, 'the example patrol pool rolls (15%: ' .. n .. ' of 40)')
    for _, r in ipairs(Rows('CID1')) do H.eq(r.item, 'water', 'patrol example: water only') end
    H.sql('DELETE FROM cp_item_rewards')

    Config.Rewards.useExamplePools = false
    H.eq(R.entryFor('beat_patrol', 'patrol'), nil, 'useExamplePools = false: no entry')
    for i = 1, 40 do Settle('EX-' .. i, 'CID1', { src = 11, missionType = 'patrol', missionId = 'beat_patrol' }) end
    H.eq(#Rows('CID1'), 0, 'useExamplePools = false: nothing rolls')

    -- a missing example item: Config health warns
    Config.Rewards.examplePools.patrol.pool[2] = { item = 'coffee', weight = 1, value = 10 }
    R._reset()
    local warnedHealth = false
    for _, l in ipairs(R.health()) do
        if l.level == 'warn' and Contains(l.text, 'example item "coffee"') then warnedHealth = true end
    end
    H.ok(warnedHealth, 'Config health warns about a missing example item')
    Config.Rewards.examplePools.patrol.pool[2] = nil
    Config.Rewards.enabled = false
    R._reset()
    H.eq(R.health()[1].text, 'Item rewards: off (example pool available)', 'off with example pools')
end

-- ============================================================================
--                        7. CAPS AND ONCE-ONLY SOURCES
-- ============================================================================

do
    BaseConfig()
    Config.Rewards.dailyItemCap = 3
    Config.Rewards.goals = {
        daily = { item = 'water', count = 2, value = 20 },
        weekly = { item = 'burger', count = 1, value = 40 },
    }
    Config.Rewards.levels = {
        [5] = { item = 'sprunk', count = 1, value = 25 },
        [6] = { item = 'burger', count = 1, value = 40 },
    }
    R._reset()
    R.validate()
    -- goals give once per goal and period
    CP.Hooks.fire('goal:completed', 'CID1', 'daily_3', 'daily:2026-09-23')
    CP.Hooks.fire('goal:completed', 'CID1', 'daily_3', 'daily:2026-09-23')
    local rows = Rows('CID1')
    H.eq(#rows, 1, 'a goal gives once')
    H.eq(rows[1].source, 'goal', 'source goal')
    H.eq(rows[1].count, 2, 'goals.daily count')
    -- the item cap counts every source: 2 + 1 (level 5) = 3, level 6 would be the 4th item
    CP.Hooks.fire('xp:levelUp', 'CID1', 11, 4, 6)
    rows = Rows('CID1')
    H.eq(#rows, 2, 'level 5 fits the cap, level 6 is past it and gives nothing')
    H.eq(tostring(rows[2].source_key), '5', 'level source_key = the level')
    CP.Hooks.fire('xp:levelUp', 'CID1', 11, 4, 6)
    H.eq(#Rows('CID1'), 2, 'levels give once')
    -- the next day the cap starts again, the old level still never gives twice
    H.time = NOW + DAY
    CP.Hooks.fire('xp:levelUp', 'CID1', 11, 4, 6)
    rows = Rows('CID1')
    H.eq(#rows, 3, 'the next day: level 6 (never given) fits, level 5 is not given again')
    H.eq(tostring(rows[3].source_key), '6', 'level 6')
    CP.Hooks.fire('goal:completed', 'CID1', 'weekly_run', 'weekly:2026-W39')
    H.eq(Rows('CID1')[4].item, 'burger', 'goals.weekly')

    -- the value cap
    Config.Rewards.dailyItemCap = 0
    Config.Rewards.dailyValueCap = 50
    CP.Hooks.fire('goal:completed', 'CID2', 'daily_3', 'daily:2026-09-24')
    CP.Hooks.fire('goal:completed', 'CID2', 'weekly_run', 'weekly:2026-W39')
    rows = Rows('CID2')
    H.eq(#rows, 1, 'value cap: 40 + 40 is past 50, the second gives nothing')

    -- boss: once per week
    Config.Rewards.dailyValueCap = 2000
    Config.Rewards.weeklyBoss = { item = 'burger', count = 1, value = 40 }
    Config.Rewards.byType = {}
    R._reset()
    R.validate()
    Settle('BOSS-1', 'CID3', { src = 13, isBoss = true })
    Settle('BOSS-2', 'CID3', { src = 13, isBoss = true })
    rows = Rows('CID3')
    H.eq(#rows, 1, 'the Weekly Boss item gives once per week')
    H.eq(rows[1].source, 'boss', 'source boss')

    -- season: champion department and top 10, once
    Config.Rewards.season = {
        champion = { item = 'sprunk', count = 1, value = 25 },
        top10 = { item = 'water', count = 1, value = 20 },
    }
    R._reset()
    R.validate()
    local ins = [[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, season_id, state,
        end_reason, points_base) VALUES (?, 'patrol', 'beat_patrol', ?, ?, 7, 'completed', 'completed', 60)]]
    H.sql(ins, { 'S-1', 'CID4', 'sast' })
    H.sql(ins, { 'S-2', 'CID4', 'sast' })
    H.sql(ins, { 'S-3', 'CID5', 'fib' })
    CP.Hooks.fire('season:ended', 7, { champion = 'sast', top10 = { 'CID4', 'CID6' } })
    CP.Hooks.fire('season:ended', 7, { champion = 'sast', top10 = { 'CID4', 'CID6' } })
    H.eq(#Rows('CID4'), 2, 'the champion department officer: champion and top 10, once each')
    H.eq(#Rows('CID5'), 0, 'another department: nothing')
    H.eq(#Rows('CID6'), 1, 'top 10 only')
    H.eq(Rows('CID6')[1].status, 'pending', 'offline: pending in the locker')
    H.time = NOW
end

-- ============================================================================
--                                   8. ADMIN
-- ============================================================================

do
    BaseConfig()
    local view = Cb('admin:getRewards', 1, { page = 1 }).data
    H.eq(view.enabled, true, 'admin view: on')
    H.ok(#view.pools > 0, 'admin view: pools')
    local tactical = nil
    for _, p in ipairs(view.pools) do if p.key == 'byType.tactical' then tactical = p end end
    H.ok(tactical and tactical.items[1].item == 'water' and tactical.items[1].ok == true, 'pool items with ok')
    H.ok(#view.recent > 0 and #view.recent <= view.pageSize, 'recent rows, one page')
    H.eq(type(view.week.given), 'number', 'week totals')
    local page9 = Cb('admin:getRewards', 1, { page = 9 }).data
    H.eq(#page9.recent, 0, 'a page past the end is empty')
    H.eq(Cb('admin:getRewards', 1, 'x').error, 'err.invalid_payload', 'bad args')
end

-- ============================================================================
--                     9. REVIEW: DELIVERY, FORFEITS, FINDS
-- ============================================================================

-- a cp_mission_runs row to hang rewards on (voided / cash_status / created_at as given)
local function RunRow(uuid, cid, opts)
    opts = opts or {}
    H.sql([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, season_id, state,
        end_reason, points_base, voided, cash_status, breakdown, created_at)
        VALUES (?, ?, 'some_raid', ?, 'sast', 8, 'completed', 'completed', 60, ?, ?, ?, FROM_UNIXTIME(?))]], {
        uuid,
        opts.missionType or 'tactical',
        cid,
        opts.voided or 0,
        opts.cash or 'paid',
        opts.breakdown or '{"runId":"x"}',
        opts.at or H.time,
    })
    return math.floor(H.sql('SELECT id FROM cp_mission_runs WHERE run_uuid = ?', { uuid })[1].id)
end
local function Breakdown(rowId)
    local r = H.sql('SELECT breakdown FROM cp_mission_runs WHERE id = ?', { rowId })[1]
    return r and type(r.breakdown) == 'string' and json.decode(r.breakdown) or nil
end

do
    BaseConfig()
    H.sql('DELETE FROM cp_item_rewards')
    H.sql('DELETE FROM cp_mission_runs')

    -- CanCarryItem is asked first: when it says no, AddItem is never called, even if it would have taken it
    local realCarry = H.exportsMock.ox_inventory.CanCarryItem
    H.exportsMock.ox_inventory.CanCarryItem = function() return false end
    local added = #inv.added
    Settle('REV-CARRY', 'CID1', { src = 11 })
    H.eq(#inv.added, added, 'CanCarryItem false: AddItem is never called')
    H.eq(Rows('CID1')[1].status, 'pending', 'and the reward waits in the locker')
    H.exportsMock.ox_inventory.CanCarryItem = realCarry

    -- a stale pending snapshot: the row was given meanwhile; the claim UPDATE stops the give
    local r = Rows('CID1')[1]
    H.sql('UPDATE cp_item_rewards SET status = \'given\' WHERE id = ?', { r.id })
    local ok, err = R._giveRow({ id = r.id, citizenid = 'CID1', item = 'water', count = 1 }, 11)
    H.eq(ok, false, 'a give of a row someone else claimed does nothing')
    H.eq(err, 'err.reward_not_claimable', 'not claimable')
    H.eq(#inv.added, added, 'no AddItem')
    H.sql('UPDATE cp_item_rewards SET status = \'pending\' WHERE id = ?', { r.id })

    -- AddItem raises: the row stays giving, is never retried and is listed for admins
    local realAdd = H.exportsMock.ox_inventory.AddItem
    H.exportsMock.ox_inventory.AddItem = function() error('inventory exploded') end
    R.deliver('CID1')
    H.eq(Rows('CID1')[1].status, 'giving', 'AddItem raised: the reward stays giving')
    H.exportsMock.ox_inventory.AddItem = realAdd
    R.deliver('CID1')
    H.eq(Rows('CID1')[1].status, 'giving', 'and is never retried automatically')
    local view = Cb('admin:getRewards', 1, { page = 1 }).data
    H.eq(#view.stuck, 1, 'admin: listed as stuck')
    H.sql('DELETE FROM cp_item_rewards')

    -- lawful evidence finds count for the run: an officer who found nothing still gets the run's bonus
    Config.Rewards.findBonus = 0.5
    Config.Rewards.findBonusMax = 1.0
    Config.Rewards.byType = {
        tactical = { chance = 0, rolls = 1, pool = { { item = 'water', count = 1, weight = 1, value = 20 } } },
    }
    local run = Run('REV-FINDS', { order = { 11, 12 } })
    run.participants = {
        [11] = { src = 11, citizenid = 'CID1', stats = { evidence = 0 } },
        [12] = { src = 12, citizenid = 'CID2', stats = { evidence = 2 } },
    }
    local row = { citizenid = 'CID1', state = 'completed', mission_id = 'x', mission_type = 'tactical', evidence = 0 }
    CP.Hooks.fire('row:settled', run, run.participants[11], 901, row, { items = {} })
    H.eq(#Rows('CID1'), 1, 'the run\'s finds raise the chance of every participant')
    Config.Rewards.findBonus = 0.10
    Config.Rewards.findBonusMax = 0.30
    H.sql('DELETE FROM cp_item_rewards')
    Config.Rewards.byType = {
        tactical = { chance = 1.0, rolls = 1, pool = { { item = 'water', count = 1, weight = 1, value = 20 } } },
    }

    -- a row voided after its cash was paid: CP.Cash never fires row:forfeited, the rewards module's own job does
    online[13] = nil
    local rowPaid = RunRow('REV-PAID', 'CID3', { voided = 1, cash = 'paid', at = H.time - 3 * DAY })
    local rowOpen = RunRow('REV-OPEN', 'CID3', { voided = 1, cash = 'paid', at = H.time - 3 * DAY })
    local rowNew = RunRow('REV-NEW', 'CID3', { voided = 1, cash = 'none', at = H.time - 3600 })
    Settle('REV-PAID', 'CID3', { rowId = rowPaid })
    Settle('REV-OPEN', 'CID3', { rowId = rowOpen })
    Settle('REV-NEW', 'CID3', { rowId = rowNew })
    for _, id in ipairs({ rowPaid, rowOpen, rowNew }) do CP.Hooks.fire('row:voided', id) end
    H.sql('INSERT INTO cp_disputes (run_id, citizenid, reason, goes_to) VALUES (?, \'CID3\', \'x\', \'supervisor\')',
        { rowOpen })
    H.eq(Rows('CID3')[1].status, 'held', 'voided: held')
    H.advance(10 * 60 * 1000 + 1000)   -- the job runs every 10 minutes
    local st = {}
    for _, x in ipairs(Rows('CID3')) do st[x.row_id] = x.status end
    H.eq(st[rowPaid], 'forfeited', 'voided after its cash was paid: forfeited when the dispute window closed')
    H.eq(st[rowOpen], 'held', 'an open dispute keeps it held')
    H.eq(st[rowNew], 'held', 'inside the dispute window: still held')
    H.eq(R._forfeitureJob(), 0, 'a second run changes nothing')
    H.sql('UPDATE cp_disputes SET status = \'rejected\'')
    H.eq(R._forfeitureJob(), 1, 'the dispute closed: that row is forfeited too')
    online[13] = 'CID3'

    -- the history breakdown lists the row's items and follows their status
    local rowB = RunRow('REV-BD', 'CID1')
    Settle('REV-BD', 'CID1', { src = 11, rowId = rowB })
    local bd = Breakdown(rowB)
    H.eq(bd and bd.runId, 'x', 'the breakdown keeps its other fields')
    H.eq(bd and bd.items and #bd.items, 1, 'the history breakdown lists the item')
    H.eq(bd and bd.items and bd.items[1].status, 'given', 'with its status')
    H.eq(bd and bd.items and bd.items[1].label, 'Water', 'and its label')
    local rowF = RunRow('REV-BDF', 'CID2', { voided = 1 })
    Settle('REV-BDF', 'CID2', { src = 12, rowId = rowF, flagged = { reason = 'idle' } })
    H.eq(Breakdown(rowF).items[1].status, 'held', 'held in the breakdown')
    CP.Hooks.fire('row:forfeited', rowF)
    H.eq(Breakdown(rowF).items[1].status, 'forfeited', 'forfeited in the breakdown')

    -- season champion: manual awards and goal rows are not runs
    H.sql('DELETE FROM cp_item_rewards')
    Config.Rewards.season = { champion = { item = 'sprunk', count = 1, value = 25 } }
    H.sql([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, season_id, state,
        end_reason, points_base) VALUES ('S-M', 'manual_award', 'manual_award', 'CID7', 'lspd', 9, 'completed',
        'completed', 60)]])
    CP.Hooks.fire('season:ended', 9, { champion = 'lspd', top10 = {} })
    H.eq(#Rows('CID7'), 0, 'a manual award alone does not make a season champion officer')
    Config.Rewards.season = {}

    -- ox_inventory started after the start check: the item check runs again when it is up
    local realState = GetResourceState
    _G.GetResourceState = function(name)
        if name == 'ox_inventory' then return 'stopped' end
        return realState(name)
    end
    Config.Rewards.byType = {
        tactical = { chance = 1.0, rolls = 1, pool = { { item = 'radio', count = 1, weight = 1, value = 20 } } },
    }
    R._reset()
    R.validate()
    _G.GetResourceState = realState
    local lines = R.health()
    local missing = false
    for _, l in ipairs(lines) do if Contains(l.text, '"radio"') then missing = true end end
    H.ok(missing, 'the late check finds the missing item')
    H.eq(R.health()[1].text, 'Item rewards: on', 'and ox_inventory counts as up')
    H.sql('DELETE FROM cp_item_rewards')
    H.sql('DELETE FROM cp_mission_runs')
    H.sql('DELETE FROM cp_disputes')
end

return H

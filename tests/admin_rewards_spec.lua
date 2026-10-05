-- Full admin control, item rewards (P4): resolve a stuck reward, deliver now, cancel, take back (ships off),
-- rewards back on row:forfeitUndone, the admin filters, the pool check of every Rewards.* change, forbidden items
-- refused live, and delivery waiting under the maintenance lock.

local H = dofile('tests/harness.lua')
local cjson = require('cjson')

local realPrint = print
_G.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = table.concat(parts, ' ')
    if not line:find('crimson%-police') then realPrint(line) end
end

H.boot({ side = 'server', realLocale = true })
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end

-- ============================================================================
--                                  THE SERVER
-- ============================================================================

local people = {
    [1] = {
        cid = 'ADM00001',
        license = 'license:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1',
        job = 'sast',
        grade = 4,
        ace = true,
    },
    [2] = { cid = 'SUP00002', license = 'license:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb2', job = 'sast', grade = 4 },
    [7] = { cid = 'OFF00007', license = 'license:7777777777777777777777777777777777777777', job = 'sast', grade = 0 },
}
for src, p in pairs(people) do
    H.players[src] = { ace = p.ace and { ['crimsonpolice.admin'] = true } or {}, coords = vec3(0.0, 0.0, 0.0) }
end

local function Online(cid)
    for src, p in pairs(people) do
        if p.cid == cid and not p.offline then return src end
    end
    return nil
end

local notes = {}
CP.Qbx = {
    getInfo = function(src)
        local p = people[src]
        if not p or p.offline then return nil end
        return {
            src = src,
            citizenid = p.cid,
            license = p.license,
            name = 'Player ' .. src,
            job = { name = p.job, onduty = true, gradeLevel = p.grade, gradeName = 'Rank' },
        }
    end,
    getByCitizenId = Online,
    getOnlinePlayers = function()
        local out = {}
        for src, p in pairs(people) do if not p.offline then out[#out + 1] = src end end
        table.sort(out)
        return out
    end,
    licenseOf = function(cid)
        for _, p in pairs(people) do if p.cid == cid then return p.license end end
        return nil
    end,
    citizenidsOfLicense = function() return {} end,
    characterExists = function() return false end,
    onDutyChange = function() end,
    onGroupUpdate = function() end,
    onJobChange = function() end,
    onPlayerLoaded = function() end,
    onPlayerUnload = function() end,
}
CP.Missions = {
    reload = function() end,
    get = function() return nil end,
}

local inv = H.mockInventory({
    water = { label = 'Water' },
    burger = { label = 'Burger' },
    weapon_pistol = { label = 'Pistol' },
})

for _, t in ipairs({
    'cp_audit',
    'cp_settings',
    'cp_settings_history',
    'cp_officers',
    'cp_mission_runs',
    'cp_item_rewards',
    'cp_admin_requests',
}) do
    H.sql('DELETE FROM ' .. t)
end

Config.Rewards.enabled = true
Config.Rewards.byType = {
    tactical = { chance = 1.0, rolls = 1, pool = { { item = 'water', count = 1, weight = 1, value = 20 } } },
}

for _, m in ipairs({
    'modules/permissions/server.lua',
    'modules/access/server.lua',
    'modules/admin/server.lua',
    'modules/adminkit/server.lua',
    'modules/confighealth/server.lua',
    'modules/settings/server.lua',
    'modules/tablet/server.lua',
    'modules/rewards/server.lua',
}) do
    H.load(m)
end
H.advance(5000)

local R, S, Maint = CP.Rewards, CP.Settings, CP.Maintenance
CP.Tablet.notify = function(src, kind, key, vars)
    notes[#notes + 1] = { src = src, kind = kind, key = key, vars = vars }
    return true
end
for _, src in ipairs({ 1, 2, 7 }) do CP.Access.refreshOfficerRow(src) end

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local reqSeq = 0
local function Act(name, src, payload)
    H.clockMs = H.clockMs + 1100
    reqSeq = reqSeq + 1
    local reqId = 'r' .. reqSeq
    H.fire('crimson-police:' .. name, src, payload, reqId)
    for i = #H.events, 1, -1 do
        local e = H.events[i]
        if e.name == 'crimson-police:client:actionResult' and e.args[1] == reqId then return e.args[2], e.args[3] end
    end
    return nil, 'no reply'
end

local function Cb(name, src, args)
    H.clockMs = H.clockMs + 1100
    local res = H.callback('crimson-police:' .. name, src, args or {})
    if type(res) ~= 'table' then return nil, 'no reply' end
    if res.ok then return res.data end
    return nil, res.error
end

local ridSeq = 500
local function Rid()
    ridSeq = ridSeq + 1
    return ('%08x-0000-4000-8000-%012x'):format(ridSeq, 7)
end

local keySeq = 0
local function Reward(o)
    keySeq = keySeq + 1
    H.sql([[INSERT INTO cp_item_rewards (row_id, source, source_key, citizenid, item, count, value, status)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)]], {
        o.rowId,
        o.source or 'run',
        'k' .. keySeq,
        o.cid or 'OFF00007',
        o.item or 'water',
        o.count or 1,
        o.value or 20,
        o.status or 'pending',
    })
    local r = H.sql('SELECT MAX(id) AS id FROM cp_item_rewards')[1]
    return math.floor(tonumber(r.id))
end

local function StatusOf(id) return H.sql('SELECT status FROM cp_item_rewards WHERE id = ?', { id })[1].status end

-- the item a reward gave, tagged with its id, in the officer's inventory
local function Holding(src, item, count, id)
    inv.slots[src] = inv.slots[src] or {}
    local list = inv.slots[src]
    list[#list + 1] = { slot = #list + 1, name = item, count = count, metadata = { cpReward = id } }
end

local function RunRow(voided)
    H.sql([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason,
        points_base, final_points, cash_status, breakdown, voided) VALUES (?, 'tactical', 'bank_job', 'OFF00007', 'sast',
        'completed', 'completed', 60, 60, 'none', ?, ?)]], {
        ('%08x-2222-4000-8000-000000000000'):format(keySeq),
        cjson.encode({ cash = { amount = 0 } }),
        voided and 1 or 0,
    })
    local r = H.sql('SELECT MAX(id) AS id FROM cp_mission_runs')[1]
    return math.floor(tonumber(r.id))
end

-- ============================================================================
--                          1. RESOLVE A STUCK REWARD
-- ============================================================================

do
    local id = Reward({ status = 'giving' })
    local ok, e = Act('server:admin:resolveReward', 2, { id = id, outcome = 'given', reason = 'x' })
    H.ok(not ok and e == 'err.no_permission', 'a supervisor can\'t resolve')
    people[7].offline = true
    local chk = Cb('admin:checkRewardInventory', 1, { id = id })
    H.ok(chk and chk.online == false and chk.found == nil, 'an offline officer\'s inventory can\'t be read')
    ok, e = Act('server:admin:resolveReward', 1, { id = id, outcome = 'given', reason = 'x' })
    H.ok(not ok and e == 'err.officer_offline' and StatusOf(id) == 'giving', 'resolve is refused while offline')
    people[7].offline = nil

    -- found: given
    Holding(7, 'water', 1, id)
    chk = Cb('admin:checkRewardInventory', 1, { id = id })
    H.ok(chk.found == true and chk.count == 1, 'the tagged item is found')
    ok, e = Act('server:admin:resolveReward', 1, { id = id, outcome = 'locker', reason = 'x', confirm = 'LOCKER' })
    H.ok(not ok and e == 'err.reward_found', 'found: never back to the locker')
    ok = Act('server:admin:resolveReward', 1, { id = id, outcome = 'given', reason = 'found it' })
    H.ok(ok and StatusOf(id) == 'given', 'found -> given')

    -- not found: given unless LOCKER is typed
    local id2 = Reward({ status = 'giving' })
    ok, e = Act('server:admin:resolveReward', 1, { id = id2, outcome = 'locker', reason = 'x' })
    H.eq(e, 'err.confirm_mismatch', 'back to the locker needs the typed word LOCKER')
    local before = #inv.added
    ok = Act('server:admin:resolveReward', 1, { id = id2, outcome = 'locker', reason = 'x', confirm = 'locker' })
    H.ok(ok and StatusOf(id2) == 'given' and #inv.added == before + 1, 'LOCKER: back to pending and given again')
    local id3 = Reward({ status = 'giving' })
    ok = Act('server:admin:resolveReward', 1, { id = id3, reason = 'not found' })
    H.ok(ok and StatusOf(id3) == 'given', 'not found and no choice: given (never given twice by a guess)')
    H.ok(H.sql('SELECT COUNT(*) AS n FROM cp_audit WHERE action = \'rewardResolve\'')[1].n + 0 == 3, 'each one audited')
end

-- ============================================================================
--                      2. DELIVER NOW, CANCEL, TAKE BACK
-- ============================================================================

do
    local id = Reward({ status = 'pending', item = 'burger' })
    local ok, d = Act('server:admin:deliverRewards', 1, { citizenid = 'OFF00007' })
    H.ok(ok and d.given >= 1 and StatusOf(id) == 'given', 'Deliver now gives the pending rewards')
    local c = Reward({ status = 'held' })
    ok = Act('server:admin:cancelReward', 1, { id = c, reason = 'mistake' })
    H.ok(ok and StatusOf(c) == 'forfeited', 'Cancel: held -> forfeited')
    local _, e = Act('server:admin:cancelReward', 1, { id = id, reason = 'x' })
    H.eq(e, 'err.state_changed', 'a given reward can\'t be cancelled')

    -- take back ships off
    local g = Reward({ status = 'given', item = 'water', count = 2 })
    Holding(7, 'water', 2, g)
    ok, e = Act('server:admin:takeBackReward', 1, { id = g, reason = 'x', confirm = 'water', requestId = Rid() })
    H.eq(e, 'err.money_tool_off', 'Take back is refused while its switch is off')
    Config.Rewards.allowTakeBack = true
    ok, e = Act('server:admin:takeBackReward', 1, { id = g, reason = 'x', confirm = 'burger', requestId = Rid() })
    H.eq(e, 'err.confirm_mismatch', 'the typed word is the item')
    local removed = #inv.removed
    ok, e = Act('server:admin:takeBackReward', 1, { id = g, reason = 'x', confirm = 'water', requestId = Rid() })
    H.ok(ok and e.taken == 2 and StatusOf(g) == 'forfeited' and #inv.removed == removed + 1,
        'exactly the tagged item is taken back')
    local g2 = Reward({ status = 'given', item = 'water' })
    ok, e = Act('server:admin:takeBackReward', 1, { id = g2, reason = 'x', confirm = 'water', requestId = Rid() })
    H.ok(not ok and e == 'err.reward_not_in_inventory' and StatusOf(g2) == 'given', 'no tagged item: nothing taken')
    people[7].offline = true
    ok, e = Act('server:admin:takeBackReward', 1, { id = g2, reason = 'x', confirm = 'water', requestId = Rid() })
    H.eq(e, 'err.officer_offline', 'the officer must be online')
    people[7].offline = nil
    Config.Rewards.allowTakeBack = false
end

-- ============================================================================
--                  3. ROW:FORFEITUNDONE BRINGS THEM BACK ONCE
-- ============================================================================

do
    local row = RunRow(false)
    local a = Reward({ rowId = row, status = 'forfeited' })
    local b = Reward({ rowId = row, status = 'forfeited' })
    Act('server:admin:cancelReward', 1, { id = b, reason = 'admin cancel' }) -- b is forfeited already: refused
    H.sql(
        'INSERT INTO cp_audit (actor, role, category, action, target, reason) VALUES (\'x\', \'admin\', \'audit\', '
            .. '\'rewardCancel\', ?, \'r\')',
        { ('reward #%d'):format(b) }
    )
    local before = #inv.added
    CP.Hooks.fire('row:forfeitUndone', row)
    H.ok(StatusOf(a) == 'given' and #inv.added == before + 1, 'the row\'s forfeited reward comes back and is delivered')
    H.eq(StatusOf(b), 'forfeited', 'one an admin cancelled stays forfeited')
    CP.Hooks.fire('row:forfeitUndone', row)
    H.eq(#inv.added, before + 1, 'a second fire brings nothing back twice')
    local row2 = RunRow(true)
    local c = Reward({ rowId = row2, status = 'forfeited' })
    R.undoForfeit(row2)
    H.eq(StatusOf(c), 'held', 'a row still voided: back as held')
end

-- ============================================================================
--                                  4. FILTERS
-- ============================================================================

do
    Reward({ status = 'pending', source = 'goal', item = 'burger' })
    local v = Cb('admin:getRewards', 1, { status = 'forfeited' })
    local ok = #v.recent > 0
    for _, r in ipairs(v.recent) do if r.status ~= 'forfeited' then ok = false end end
    H.ok(ok, 'filter by status')
    v = Cb('admin:getRewards', 1, { source = 'goal' })
    H.ok(#v.recent == 1 and v.recent[1].source == 'goal' and v.recent[1].online == true,
        'filter by source; online flag')
    v = Cb('admin:getRewards', 1, { citizenid = 'NOBODY' })
    H.eq(#v.recent, 0, 'filter by officer')
    local _, e = Cb('admin:getRewards', 1, { status = 'lost' })
    H.eq(e, 'err.invalid_filter', 'an unknown status is refused')
    H.eq(v.allowTakeBack, false, 'Take back ships off')
end

-- ============================================================================
--                  5. THE POOL CHECK AND FORBIDDEN ITEMS LIVE
-- ============================================================================

do
    -- an item added live, before the next item check, is never given
    Config.Rewards.byType = {
        tactical = { chance = 1.0, rolls = 3, pool = { { item = 'weapon_pistol', count = 1, weight = 1 } } },
    }
    local got = R.roll('run-x', 'OFF00007', Config.Rewards.byType.tactical, 1.0)
    H.eq(#got, 0, 'Usable() refuses weapon_pistol even before validate() runs')
    Config.Rewards.byType = {
        tactical = { chance = 1.0, rolls = 1, pool = { { item = 'water', count = 1, weight = 1, value = 20 } } },
    }

    local function Set(path, value)
        local ok, e = S.set(1, path, value)
        return ok, e
    end
    local ok, e = Set('Rewards.byType', { patrol = { chance = 0.5, rolls = 1, pool = { { item = 'weapon_pistol' } } } })
    H.ok(not ok and e == 'err.reward_item_forbidden',
        'the raw Settings editor refuses a forbidden item: ' .. tostring(e))
    ok, e = Set('Rewards.byType', { patrol = { chance = 2, rolls = 1, pool = { { item = 'water' } } } })
    H.eq(e, 'err.reward_chance', 'chance 0-1')
    ok, e = Set('Rewards.byType', { patrol = { chance = 0.5, rolls = 11, pool = { { item = 'water' } } } })
    H.eq(e, 'err.reward_rolls', 'rolls 0-10')
    ok, e = Set('Rewards.byType', { patrol = { chance = 0.5, rolls = 1, pool = { { item = 'water', count = 0 } } } })
    H.eq(e, 'err.reward_count', 'count 1-100')
    ok, e = Set('Rewards.byType',
        { patrol = { chance = 0.5, rolls = 1, pool = { { item = 'water', count = { 5, 1 } } } } })
    H.eq(e, 'err.reward_count', 'a low count above the high count')
    ok, e = Set('Rewards.byType', { patrol = { chance = 0.5, rolls = 1, pool = { { item = 'water', weight = 0 } } } })
    H.eq(e, 'err.reward_weight', 'weight above 0')
    ok, e = Set('Rewards.byType', { patrol = { chance = 0.5, rolls = 1, pool = { { item = 'water', value = -1 } } } })
    H.eq(e, 'err.reward_value', 'value 0 or more')
    ok, e = Set('Rewards.medals', { gold = { item = 'black_money', count = 1 } })
    H.eq(e, 'err.reward_item_forbidden', 'medal items too')
    ok = Set('Rewards.byType', {
        patrol = {
            chance = 0.5,
            rolls = 2,
            pool = { { item = 'water', count = { 1, 3 }, weight = 2, value = 10 } },
        },
    })
    H.eq(ok, true, 'a good pool is saved')
    H.ok(Config.Rewards.byType.patrol ~= nil, 'and applied live')

    local pv = Cb('admin:rewardPoolPreview', 1, {
        path = 'Rewards.byType',
        value = {
            patrol = {
                chance = 0.5,
                rolls = 2,
                pool = { { item = 'water', count = { 1, 3 }, weight = 1, value = 10 } },
            },
        },
    })
    H.ok(pv and pv.error == nil and #pv.expected == 1 and #pv.expected[1].tiers == 5, 'the preview: expected per tier')
    local std = pv.expected[1].tiers[1]
    H.ok(std.tier == 'standard' and math.abs(std.items - 2) < 0.001 and math.abs(std.value - 20) < 0.001,
        'expected items and value per run, computed in Lua (2 rolls x 0.5 x 2 items x $10)')
    pv = Cb('admin:rewardPoolPreview', 1,
        { path = 'Rewards.byType', value = { x = { pool = { { item = 'ammo-9' } } } } })
    H.eq(pv.error, 'err.reward_item_forbidden', 'the preview gives the server\'s verdict')
    local items = Cb('admin:rewardItems', 1, {})
    local names = {}
    for _, i in ipairs(items.items) do names[i.name] = true end
    H.ok(names.water and not names.weapon_pistol, 'the item picker leaves forbidden items out')
    local _, eS = Cb('admin:rewardItems', 2, {})
    H.eq(eS, 'err.no_permission', 'admins only')
end

-- ============================================================================
--                 6. DELIVERY WAITS UNDER THE MAINTENANCE LOCK
-- ============================================================================

do
    local id = Reward({ status = 'pending', item = 'burger' })
    Maint.begin('restore', { by = 'test' })
    H.eq(R.deliver('OFF00007'), 0, 'reward delivery waits while locked')
    H.eq(StatusOf(id), 'pending', 'the reward stays in the locker')
    local n = R._forfeitureJob()
    H.eq(n, 0, 'the reward forfeiture job waits too')
    Maint.finish('restore')
    H.ok(R.deliver('OFF00007') >= 1 and StatusOf(id) == 'given', 'delivered once the lock ends')
end

_G.print = realPrint
return H

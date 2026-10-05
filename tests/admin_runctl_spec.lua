-- Full admin control, an officer's run state and the anti-farm overrides (P3): Today & cooldowns (cooldowns, counts,
-- cash today, free abandons, the board as the officer sees it), Clear cooldowns, Allow more today, Another boss
-- attempt and Treat as a normal abandon, with the limits counted from saved rows and the caches they clear.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false
H.time = tonumber(H.sql('SELECT UNIX_TIMESTAMP(NOW()) AS t')[1].t)
Config.Events.modifierChance = 0
local W = dofile('tests/fixtures/admin_live_world.lua')(H)
local Runs, Events, LiveCtl = CP.Runs, CP.Events, CP.LiveCtl
local cjson = require('cjson')

local function Marker(cid, column)
    local r = H.sql(('SELECT %s AS v FROM cp_officers WHERE citizenid = ?'):format(column), { cid })[1]
    local v = r and r.v
    if v == nil or v == '' or v == 'NULL' then return nil, nil end
    if type(v) == 'table' then return v, cjson.encode(v) end
    return cjson.decode(v), v
end

-- ============================================================================
--                              TODAY & COOLDOWNS
-- ============================================================================

local now = os.time()
W.row({ cid = 'OFF00007', reason = 'quit', state = 'abandoned', ts = now - 60 })
W.row({
    cid = 'OFF00007',
    type = 'training',
    id = 'other_mission',
    reason = 'off_route',
    state = 'abandoned',
    ts = now - 30,
})
W.row({ cid = 'OFF00007', reason = 'completed', ts = now - 4000 })
local freeUuid = W.row({ cid = 'OFF00007', reason = 'real_call', state = 'abandoned', ts = now - 600 })
W.row({ cid = 'OFF00007', reason = 'real_call', state = 'abandoned', ts = now - 90000 })   -- older than 24 h
W.cashToday.OFF00007 = 1250
W.board = {
    cards = {
        {
            key = 'patrol',
            label = 'Patrol',
            pool = 3,
            locked = { reason = 'Patrol is on cooldown', ['until'] = now + 240 },
            missions = { 'live_test_mission' },
            nextMission = 'Live Test Mission',
        },
        { key = 'training', label = 'Training', pool = 1, busy = true, typeOfTheDay = true },
    },
    boss = { key = 'weekly_boss', label = 'The Kingpin', available = false, locked = { reason = 'Used this week' } },
    operation = nil,
    unit = { size = 1 },
}

H.ok(Runs.onCooldown('OFF00007', 'patrol', W.DEF.id), 'the quit put the type and mission on cooldown')
local res = W.cb('admin:getOfficerRunState', 1, { citizenid = 'OFF00007' })
H.ok(res.ok, 'an admin reads an officer\'s run state')
local st = res.data
H.eq(st.online, true, 'online')
H.eq(st.onRun, false, 'not on a run')
local types = {}
for _, t in ipairs(st.cooldowns.types) do types[t.key] = t end
H.ok(types.patrol and types.training, 'both type cooldowns shown')
H.ok(#st.cooldowns.missions >= 1, 'the mission cooldown shown')
H.eq(st.cooldowns.missions[1].label, 'Live Test Mission', 'with the mission name (admins see names)')
H.eq(st.counts.today, 1, 'completions today')
H.eq(st.counts.hour, 0, 'none in the last hour')
H.eq(st.cashToday, 1250, 'cash paid today (CP.Cash.paidToday)')
H.eq(#st.freeAbandons, 1, 'free abandons of the last 24 h, from the rows')
H.eq(st.freeAbandons[1].runUuid, freeUuid, 'the right row')
H.eq(st.clears.used, 0, 'no clear yet')
H.eq(st.clears.max, 3, 'the per-day limit')
H.eq(st.extra.max, 10, 'the extra runs limit')
H.ok(st.board ~= nil, 'the board as the officer sees it (online)')
H.eq(#st.board.cards, 2, 'their type cards')
H.eq(st.board.cards[1].locked.reason, 'Patrol is on cooldown', 'with the lock reason')
local boardJson = cjson.encode(st.board)
H.eq(boardJson:find('live_test_mission', 1, true), nil, 'no mission id in the board view')
H.eq(boardJson:find('Live Test Mission', 1, true), nil, 'no mission name')
H.eq(boardJson:find('Kingpin', 1, true), nil, 'not even the boss mission\'s name')
H.eq(W.cb('admin:getOfficerRunState', 2, { citizenid = 'OFF00007' }).ok, false, 'a supervisor never reads it')
H.eq(W.cb('admin:getOfficerRunState', 1, { citizenid = 'NOBODY1' }).error, 'err.unknown_officer', 'unknown officer')

W.people[7].offline = true
res = W.cb('admin:getOfficerRunState', 1, { citizenid = 'OFF00007' })
H.eq(res.data.online, false, 'offline officer')
H.eq(res.data.board, nil, 'no board for an offline officer')
W.people[7].offline = nil

-- ============================================================================
--                               CLEAR COOLDOWNS
-- ============================================================================

local ok, err = W.act('server:admin:clearCooldowns', 1, { citizenid = 'OFF00007', scope = 'type', key = 'patrol' })
H.eq(err, 'err.reason_required', 'a reason is needed')
ok, err = W.act('server:admin:clearCooldowns', 1, { citizenid = 'ADM00001', scope = 'all', reason = 'me' })
H.eq(err, 'err.self_target', 'never the admin\'s own character')
ok, err = W.act('server:admin:clearCooldowns', 1, { citizenid = 'ALT00001', scope = 'all', reason = 'me' })
H.eq(err, 'err.self_target', 'nor another character of the same player')
ok, err = W.act('server:admin:clearCooldowns', 1,
    { citizenid = 'OFF00007', scope = 'type', key = 'nope', reason = 'x' })
H.eq(err, 'err.unknown_type', 'a type must exist')
ok, err = W.act('server:admin:clearCooldowns', 2, { citizenid = 'OFF00007', scope = 'all', reason = 'x' })
H.eq(ok, false, 'a supervisor never clears cooldowns')

ok, err = W.act('server:admin:clearCooldowns', 1,
    { citizenid = 'OFF00007', scope = 'type', key = 'patrol', reason = 'bugged call' })
H.ok(ok, 'the patrol type cooldown is cleared')
H.eq(err.used, 1, 'one clear used today')
local cd = Runs.cooldowns('OFF00007')
H.eq(cd.types.patrol, nil, 'patrol is free at once (the in-memory table)')
H.ok(cd.types.training ~= nil, 'training keeps its cooldown')
H.ok(cd.missions[W.DEF.id] ~= nil, 'the mission cooldown stays (another scope)')
local m = Marker('OFF00007', 'cooldown_clears')
H.eq(m.n, 1, 'the per-day count is held in the saved JSON')
H.eq(m.day, CP.Schedule.dayKey(), 'for today')
H.eq(W.toasts(7, 'admin.live.notice.cooldowns_cleared'), 1, 'the officer is told')
H.eq(W.audits('cooldownClear')[1].category, 'flags', 'audited to the flags webhook')

-- a restart: the table is rebuilt from the rows and still respects the clear
Runs._forgetOfficer('OFF00007')
cd = Runs.cooldowns('OFF00007')
H.eq(cd.types.patrol, nil, 'the clear survives a rebuild from the rows (a restart)')
H.ok(cd.types.training ~= nil, 'the other type is still rebuilt')

ok = W.act('server:admin:clearCooldowns', 3,
    { citizenid = 'OFF00007', scope = 'mission', key = W.DEF.id, reason = 'x' })
H.ok(ok, 'the mission cooldown is cleared')
H.eq(Runs.cooldowns('OFF00007').missions[W.DEF.id], nil, 'mission free')
ok = W.act('server:admin:clearCooldowns', 3, { citizenid = 'OFF00007', scope = 'all', reason = 'x' })
H.ok(ok, 'every cooldown is cleared')
cd = Runs.cooldowns('OFF00007')
H.eq(next(cd.types), nil, 'no type cooldown')
H.eq(next(cd.missions), nil, 'no mission cooldown')
ok, err = W.act('server:admin:clearCooldowns', 3, { citizenid = 'OFF00007', scope = 'all', reason = 'x' })
H.eq(err, 'err.live_clear_limit', 'the fourth clear of the day is refused')

-- a new quit after the clear counts again
W.row({ cid = 'OFF00007', reason = 'quit', state = 'abandoned', ts = os.time() + 5 })
Runs._forgetOfficer('OFF00007')
H.ok(Runs.onCooldown('OFF00007', 'patrol', W.DEF.id), 'a run after the clear starts a cooldown again')

-- the compare-and-set: a change since the read loses
local _, oldText = Marker('OFF00009', 'cooldown_clears')
H.eq(oldText, nil, 'officer 9 has no marker yet')
local okW = LiveCtl._writeMarker('OFF00009', 'cooldown_clears', nil, { day = 'x', n = 1 })
H.ok(okW, 'the first write wins')
local okW2, errW2 = LiveCtl._writeMarker('OFF00009', 'cooldown_clears', nil, { day = 'y', n = 1 })
H.eq(okW2, false, 'a write that read the old (empty) state loses')
H.eq(errW2, 'err.state_changed', 'with err.state_changed')
local _, text9 = Marker('OFF00009', 'cooldown_clears')
okW2 = LiveCtl._writeMarker('OFF00009', 'cooldown_clears', text9, { day = 'z', n = 2 })
H.ok(okW2, 'a write with the current text goes through')

-- refused while on a run
local run = assert(W.newRun({ 8 }))
ok, err = W.act('server:admin:clearCooldowns', 1, { citizenid = 'OFF00008', scope = 'all', reason = 'x' })
H.eq(err, 'err.live_officer_on_run', 'not while the officer is on a run')
Runs.removeParticipant(run, 8, 'quit')

Config.AdminControl.cooldownClearsPerDay = 0
ok, err = W.act('server:admin:clearCooldowns', 1, { citizenid = 'OFF00008', scope = 'all', reason = 'x' })
H.eq(err, 'err.live_limit_off', 'a limit of 0 turns the tool off')
Config.AdminControl.cooldownClearsPerDay = 3

-- ============================================================================
--                               ALLOW MORE TODAY
-- ============================================================================

Config.Limits.maxCompletionsDay = 2
W.row({ cid = 'OFF00009', reason = 'completed', ts = os.time() - 100 })
W.row({ cid = 'OFF00009', reason = 'completed', ts = os.time() - 50 })
Runs._forgetOfficer('OFF00009')
H.eq(Runs.completionsToday('OFF00009'), 2, 'at the daily cap')
ok, err = W.act('server:admin:allowExtraRuns', 1, { citizenid = 'OFF00009', count = 11, reason = 'event' })
H.eq(err, 'err.live_count_range', 'at most extraRunsMax')
ok, err = W.act('server:admin:allowExtraRuns', 1, { citizenid = 'OFF00009', count = 0, reason = 'event' })
H.eq(err, 'err.live_count_range', 'at least one')
ok = W.act('server:admin:allowExtraRuns', 1, { citizenid = 'OFF00009', count = 3, reason = 'event night' })
H.ok(ok, 'three more completions allowed today')
H.eq(Runs.completionsToday('OFF00009'), 0, 'the daily count makes room for three')
H.eq(Runs.completionsToday('OFF00009', nil, true), 2, 'the rows themselves are unchanged')
H.eq(Runs.completionsToday('OFF00009', 'patrol'), 2, 'a type\'s own daily limit is not raised')
H.eq(Runs.completionsLastHour('OFF00009'), 2, 'never the hourly cap')
H.eq(Marker('OFF00009', 'cap_extra').n, 3, 'saved in cap_extra')
H.eq(W.toasts(9, 'admin.live.notice.extra_runs'), 1, 'the officer is told')
ok, err = W.act('server:admin:allowExtraRuns', 3, { citizenid = 'OFF00009', count = 1, reason = 'again' })
H.eq(err, 'err.live_extra_used', 'once per officer per day')
H.eq(#W.audits('extraRunsAllow'), 1, 'audited')
-- the next day the extra runs are gone
local savedTime = H.time
H.time = H.time + 86400 + 3600
Runs._forgetOfficer('OFF00009')
H.eq(Runs.extraRunsToday('OFF00009'), 0, 'extra runs end at the daily reset')
H.time = savedTime
Runs._forgetOfficer('OFF00009')
Config.Limits.maxCompletionsDay = 0

-- ============================================================================
--                             ANOTHER BOSS ATTEMPT
-- ============================================================================

Config.Events.weeklyBoss.enabled = true
Config.Events.weeklyBoss.days = { 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday' }
local officer8 = CP.Access.getOfficer(8)
H.ok(Events.bossAvailable(8, officer8), 'officer 8 has this week\'s attempt')
W.row({
    cid = 'OFF00008',
    type = 'tactical',
    id = 'weekly_boss_kingpin',
    reason = 'mission_failed',
    state = 'failed',
    ts = os.time() - 10,
})
local avail, why = Events.bossAvailable(8, officer8)
H.eq(avail, false, 'a failed boss run used the attempt')
H.eq(why, 'err.boss_used', 'boss used')
ok = W.act('server:admin:grantBossAttempt', 1, { citizenid = 'OFF00008', reason = 'the boss bugged out' })
H.ok(ok, 'an admin gives another attempt')
H.ok(Events.bossAvailable(8, officer8), 'it takes effect at once (the weekly cache was cleared)')
H.eq(Events.bossUsage('OFF00008').left, 1, 'one attempt left')
H.eq(W.toasts(8, 'admin.live.notice.boss_attempt'), 1, 'the officer is told')
ok, err = W.act('server:admin:grantBossAttempt', 3, { citizenid = 'OFF00008', reason = 'again' })
H.eq(err, 'err.live_boss_granted', 'once per officer per week')
W.row({ cid = 'OFF00008', type = 'tactical', id = 'weekly_boss_kingpin', reason = 'completed', ts = os.time() - 5 })
H.eq(Events.bossAvailable(8, officer8), false, 'the second attempt is used too')

-- a voided boss row gives its attempt back (and the cache is cleared on the void)
local officer9 = CP.Access.getOfficer(9)
local bossUuid = W.row(
    { cid = 'OFF00009', type = 'tactical', id = 'weekly_boss_kingpin', reason = 'completed', ts = os.time() - 5 })
H.eq(Events.bossAvailable(9, officer9), false, 'officer 9 used theirs (now cached)')
H.sql('UPDATE cp_mission_runs SET voided = 1 WHERE run_uuid = ?', { bossUuid })
CP.Hooks.fire('row:voided', { runUuid = bossUuid, citizenid = 'OFF00009' })
H.ok(Events.bossAvailable(9, officer9), 'a voided boss run returns the attempt')

-- ============================================================================
--                          TREAT AS A NORMAL ABANDON
-- ============================================================================

Runs._forgetOfficer('OFF00007')
local quitUuid = W.row({ cid = 'OFF00007', reason = 'quit', state = 'abandoned', ts = os.time() - 20 })
ok, err = W.act('server:admin:reclassifyAbandon', 1, { citizenid = 'OFF00007', runUuid = quitUuid, reason = 'x' })
H.eq(err, 'err.live_not_free_abandon', 'only a free abandon (real_call)')
local oldUuid = H.sql(
    'SELECT run_uuid FROM cp_mission_runs WHERE citizenid = \'OFF00007\' AND end_reason = \'real_call\' AND created_at < FROM_UNIXTIME(?)',
    { os.time() - 86400 })[1].run_uuid
ok, err = W.act('server:admin:reclassifyAbandon', 1, { citizenid = 'OFF00007', runUuid = oldUuid, reason = 'x' })
H.eq(err, 'err.live_not_free_abandon', 'only the last 24 h')

-- officer 9: no cooldown yet, one free abandon
local free9 = W.row({ cid = 'OFF00009', reason = 'real_call', state = 'abandoned', ts = os.time() - 300 })
Runs._forgetOfficer('OFF00009')
H.eq(Runs.onCooldown('OFF00009', 'patrol'), false, 'a free abandon gave no type cooldown')
ok = W.act('server:admin:reclassifyAbandon', 1,
    { citizenid = 'OFF00009', runUuid = free9, reason = 'dodging a boring mission' })
H.ok(ok, 'the free abandon becomes a normal one')
local row = H.sql('SELECT end_reason, state FROM cp_mission_runs WHERE run_uuid = ?', { free9 })[1]
H.eq(row.end_reason, 'real_call_cancelled', 'the row says so')
H.ok(Runs.onCooldown('OFF00009', 'patrol'), 'the type cooldown starts now')
H.eq(W.toasts(9, 'admin.live.notice.abandon_reclassified'), 1, 'the officer is told')
ok, err = W.act('server:admin:reclassifyAbandon', 3, { citizenid = 'OFF00009', runUuid = free9, reason = 'again' })
H.eq(err, 'err.live_not_free_abandon', 'only once: the cooldowns are set once')
H.eq(#W.audits('abandonReclassify'), 1, 'audited once')

-- counted from the rows: a restart keeps the list
Runs._forgetOfficer('OFF00007')
res = W.cb('admin:getOfficerRunState', 1, { citizenid = 'OFF00007' })
H.eq(#res.data.freeAbandons, 1, 'free abandons are read from the rows after a restart')

-- the admin's own run is refused
local ownUuid = W.row({ cid = 'ADM00001', reason = 'real_call', state = 'abandoned', ts = os.time() - 30 })
W.row({ cid = 'OFF00008', reason = 'real_call', state = 'abandoned', ts = os.time() - 30, uuid = ownUuid })
ok, err = W.act('server:admin:reclassifyAbandon', 1, { citizenid = 'OFF00008', runUuid = ownUuid, reason = 'x' })
H.eq(err, 'err.own_run', 'never a run the admin took part in')

_G.print = W.realPrint
return H

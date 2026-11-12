-- Live scoring: a live case scores only its weighted live_* lines (Config.RealPlayers.liveCrime.linesOnly), its tier

-- Live scoring: a live case scores only its weighted live_* lines (Config.RealPlayers.liveCrime.linesOnly), its tier
-- comes from the crew (Config.RealPlayers.liveCrime.tier), and the Type of the Day, goals, challenge, cash and item
-- switches keep it out of each of those until the owner turns them on. Every live-case detain is a live catch on the
-- row and a Rank by tab. Plain Lua with stubs (no SQL); the 014 column is checked by foundation_spec.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end

-- ============================================================================
--                                    STUBS
-- ============================================================================

local view = nil    -- CP.Opponents' view of the run's case (only the order is read)
CP.Opponents = {
    view = function() return view end,
    caseOf = function() return nil end,
    timeline = function() return true end,
}
local tod = 'investigation'
CP.Events = {
    typeOfTheDay = function() return tod end,
}

H.load('modules/realplayers/livecrime.lua')
H.load('modules/runs/scaling.lua')
H.load('modules/progression/scoring.lua')
H.load('modules/system/schedule.lua')
H.load('modules/money/engine.lua')
H.load('modules/money/cash.lua')
local LC = CP.LiveCrime

local function Run(live)
    local p = {
        src = 1,
        department = 'sast',
        status = 'active',
        score = {},
        vehicle = { seen = false },
        result = 'completed',
        firstRunSinceDuty = true,
    }
    local run = {
        id = 'V13',
        missionType = 'investigation',
        missionId = live and 'live_crime' or 'house_search',
        mission = { type = 'investigation', points = 100 },
        pointsBase = 100,
        cashBase = 1000,
        timeLimit = 3600,
        payTier = { tier = 'standard', points = 1.0, cash = 1.0 },
        participants = { [1] = p },
        order = { 1 },
        score = {
            shared = { live_scene = 1, live_detain = 1.5 },
            values = {},
            kinds = { live_scene = 'bonus', live_detain = 'bonus' },
        },
        startedAt = os.time() - 60,
        live = live and { crimeKey = 'crimson-contracts:none' } or nil,
    }
    return run, p
end

local function Has(list, id)
    for _, l in ipairs(list or {}) do if l.id == id then return true end end
    return false
end

-- ============================================================================
--                              THE SHIPPED CONFIG
-- ============================================================================

do
    local lc = Config.RealPlayers.liveCrime
    H.eq(lc.enabled, false, 'live crimes ship off')
    H.eq(lc.linesOnly, true, 'linesOnly ships true')
    H.eq(lc.tier, 'crew', 'the tier ships from the crew')
    for _, k in ipairs({ 'typeOfTheDay', 'goals', 'challenge', 'cash', 'items' }) do
        H.eq(lc[k], false, k .. ' ships false')
    end
    local metrics = table.concat(Config.Leaderboard.metrics, ',')
    H.ok(not metrics:find('live_catches', 1, true), 'the live_catches tab ships off the board')
end

-- ============================================================================
--                         CP.LiveCrime's SCORING RULES
-- ============================================================================

do
    local run = Run(true)
    H.eq(LC.isLive(run), true, 'run.live: a live case')
    H.eq(LC.isLive({ realSuspect = 'live' }), true, 'run.realSuspect = live: a live case')
    H.eq(LC.isLive(Run(false)), false, 'a mission is not')
    H.eq(LC.linesOnly(run), true, 'a live case scores its lines only')
    H.eq(LC.linesOnly(Run(false)), false, 'a mission never')
    for _, k in ipairs({ 'typeOfTheDay', 'goals', 'challenge', 'cash', 'items' }) do
        H.eq(CP.RealPlayersTakePart(run, k), false, 'a live case: no ' .. k .. ' while its switch is off')
        H.eq(CP.RealPlayersTakePart(Run(false), k), true, 'a mission: ' .. k .. ' as before')
        Config.RealPlayers.liveCrime[k] = true
        H.eq(CP.RealPlayersTakePart(run, k), true, k .. ' on: the live case takes part')
        Config.RealPlayers.liveCrime[k] = false
    end
    H.eq(CP.RealPlayersTakePart(run, 'bogus'), false, 'an unknown switch is off')

    H.eq(LC.crewSize(run), 1, 'no case and no count: a crew of 1')
    run.live.suspects = 2
    H.eq(LC.crewSize(run), 2, 'run.live.suspects counts')
    view = { order = { 'A', 'B', 'C' } }
    H.eq(LC.crewSize(run), 3, 'the case\'s suspects come first')
    H.eq(LC.tierRow(run).tier, 'heavy', 'a crew of 3: the heavy tier')
    H.eq(LC.tierRow(Run(false)), nil, 'a mission keeps its own tier')
    Config.RealPlayers.liveCrime.tier = 'officers'
    H.eq(LC.tierRow(run), nil, 'tier = officers: the officers\' tier, like a mission')
    Config.RealPlayers.liveCrime.tier = 'crew'
    view = nil

    Config.RealPlayers.volunteer.goals = true
    H.eq(CP.RealPlayersRowFilter('goals', 'r.'), ' AND COALESCE(r.mission_id, \'\') <> \'live_crime\'',
        'goals off: live rows left out')
    Config.RealPlayers.liveCrime.goals = true
    H.eq(CP.RealPlayersRowFilter('goals', 'r.'), '', 'goals on: nothing left out')
    Config.RealPlayers.liveCrime.goals = false
    Config.RealPlayers.volunteer.goals = false
end

-- ============================================================================
--                              CP.Scoring.compute
-- ============================================================================
-- Lines only, crew tier, Type of the Day.

do
    local run, p = Run(true)
    local b = CP.Scoring.compute(run, p, 'completed', { durationS = 60, departments = 1 })
    -- 0.25 x 100 (scene) + 0.5 x 100 x 1.5 (detain)
    H.eq(b.subtotal, 100, 'lines only: the subtotal is the lines (25 + 75), no base points')
    H.eq(b.linesOnly, true, 'the breakdown says so (the result card hides the base line)')
    H.ok(not Has(b.bonuses, 'fast_finish') and not Has(b.bonuses, 'first_run'), 'no end-of-run lines')
    H.eq(b.tod, false, 'Type of the Day off for live cases')
    H.eq(b.final, 100, 'a crew of 1: x1.0')

    -- a late joiner (V15, CP.Runs.addParticipant): the shared lines recorded before he joined are not his
    p.sharedBefore = { live_scene = 1, live_detain = 0.5 }
    b = CP.Scoring.compute(run, p, 'completed', { durationS = 60, departments = 1 })
    H.eq(b.subtotal, 50, 'a late joiner: only the detain line after he joined (0.5 x 100 x 1.0)')
    H.ok(not Has(b.bonuses, 'live_scene'), 'a late joiner: no scene line secured before he came')
    p.sharedBefore = nil

    view = { order = { 'A', 'B', 'C' } }
    b = CP.Scoring.compute(run, p, 'completed', { durationS = 60, departments = 1 })
    H.eq(b.mTeam, 1.15, 'a crew of 3: the heavy tier\'s points')
    H.eq(b.final, 115, 'x1.15')
    view = nil

    Config.RealPlayers.liveCrime.typeOfTheDay = true
    b = CP.Scoring.compute(run, p, 'completed', { durationS = 60, departments = 1 })
    H.eq(b.tod, true, 'typeOfTheDay on: today\'s type doubles a live case too')
    Config.RealPlayers.liveCrime.typeOfTheDay = false

    Config.RealPlayers.liveCrime.linesOnly = false
    b = CP.Scoring.compute(run, p, 'completed', { durationS = 60, departments = 1 })
    H.ok(b.subtotal > 200 and not b.linesOnly, 'linesOnly = false: P plus the lines and the end-of-run lines')
    -- Z14: an officer who went down in the case (downed_case) leaves with what he earned so far: lines only, no
    -- end-of-run lines, no mission cash
    p.endReason = 'downed_case'
    b = CP.Scoring.compute(run, p, 'completed', { durationS = 60, departments = 1 })
    H.ok(b.linesOnly == true and b.subtotal == 100 and not Has(b.bonuses, 'fast_finish'),
        '(Z14) linesOnly = false: a downed_case officer still scores the lines only')
    Config.RealPlayers.liveCrime.cash = true
    H.eq((CP.Cash.compute(run, p)), 0, '(Z14) and gets no mission cash')
    Config.RealPlayers.liveCrime.cash = false
    p.endReason = nil
    Config.RealPlayers.liveCrime.linesOnly = true

    local m, mp = Run(false)
    b = CP.Scoring.compute(m, mp, 'completed', { durationS = 60, departments = 1 })
    H.eq(b.tod, true, 'a mission keeps the Type of the Day')
    H.ok(b.subtotal >= 200 and b.linesOnly == nil, 'a mission keeps its base points')

    -- step Z2: a volunteer case ended early by Config.RealPlayers.volunteer.voidRun = 'keep_earned' (run.keepEarned)
    -- scores what was earned so far: the lines only, no base points, no end-of-run lines, no mission cash
    H.ok((CP.Cash.compute(m, mp)) > 0, 'Z2: a completed mission pays its cash')
    m.keepEarned = true
    b = CP.Scoring.compute(m, mp, 'completed', { durationS = 60, departments = 1 })
    H.eq(b.linesOnly, true, 'Z2: keep_earned scores the lines only')
    H.ok(b.subtotal < 200, 'Z2: no base points')
    H.ok(not Has(b.bonuses, 'fast_finish'), 'Z2: no fast_finish for a run that ended early')
    H.eq((CP.Cash.compute(m, mp)), 0, 'Z2: no mission cash')

    -- step Z5: the card's end-of-run bonuses (no_participant_downed, no_weapons_fired) never score lines-only
    local card, cp = Run(false)
    card.mission.bonuses = { { id = 'no_participant_downed', value = 25 }, { id = 'no_weapons_fired', value = 25 } }
    card.stats = { downs = 0, weaponsFired = 0 }
    b = CP.Scoring.compute(card, cp, 'completed', { durationS = 60, departments = 1 })
    H.ok(Has(b.bonuses, 'no_participant_downed') and Has(b.bonuses, 'no_weapons_fired'),
        'Z5: a full run scores the end-of-run bonuses its card lists')
    card.keepEarned = true
    b = CP.Scoring.compute(card, cp, 'completed', { durationS = 60, departments = 1 })
    H.ok(not Has(b.bonuses, 'no_participant_downed'), 'Z5: keep_earned: no no_participant_downed')
    H.ok(not Has(b.bonuses, 'no_weapons_fired'), 'Z5: keep_earned: no no_weapons_fired')
end

-- ============================================================================
--                               CP.Cash.compute
-- ============================================================================

do
    local run, p = Run(true)
    local amount, cb = CP.Cash.compute(run, p)
    H.eq(amount, 0, 'cash off: a live case pays nothing')
    H.eq(cb.B, 0, 'and its base is 0 (nothing to pay again later)')
    Config.RealPlayers.liveCrime.cash = true
    view = { order = { 'A', 'B' } }
    amount, cb = CP.Cash.compute(run, p)
    H.eq(cb.mTier, 1.15, 'cash on: a crew of 2, the reinforced tier\'s cash')
    H.eq(amount, 1150, 'pays like a mission of its type')
    view = nil
    Config.RealPlayers.liveCrime.cash = false
    H.eq((CP.Cash.compute(Run(false))), 1000, 'a mission pays as before')
end

-- ============================================================================
--                 THE LIVE CATCH (live_response) AND THE BOARD
-- ============================================================================

do
    local noted = {}
    CP.Runs = {
        noteStat = function(_, src, key, n) noted[#noted + 1] = { src = src, key = key, n = n } return true end,
    }
    H.load('blocks/live_response/server.lua')
    local B = CP.Blocks.get('live_response')
    local ctx = {
        run = { id = 'LC1' },
        state = {},
        award = function() return true end,
        hud = function() end,
    }
    B.prepare(ctx)
    B.onEvent(ctx, nil, { type = 'opp_detained', cid = 'CA', share = 0.5 })
    B.onEvent(ctx, nil, { type = 'opp_detained', cid = 'CA', share = 1 })
    B.onEvent(ctx, nil, { type = 'opp_detained', cid = 'CB', share = 0 })
    B.onEvent(ctx, nil, { type = 'opp_booked', cid = 'CA', share = 0.5 })
    H.eq(#noted, 1, 'one live catch per suspect detained (an AFK catch and a booking are none)')
    H.ok(noted[1] and noted[1].key == 'live_catches' and noted[1].src == nil and noted[1].n == 1,
        'for every active participant')

    H.load('modules/runs/runs.lua')
    local run = {
        id = 'LC2',
        state = 'in_progress',
        participants = { [1] = { status = 'active', score = {} } },
        order = { 1 },
    }
    H.ok(CP.Runs.noteStat(run, 1, 'live_catches', 1), 'CP.Runs takes the live_catches count')
    H.eq(run.participants[1].stats.live_catches, 1, 'on the participant (written to the row)')

    H.load('modules/progression/leaderboard.lua')
    H.eq(CP.Leaderboard._metricValue({ stats = { live_catches = 4 } }, 'live_catches'), 4, 'Rank by live catches')
    H.eq(CP.Leaderboard.badgeLabel('top_live_catches_2026-11-02'), 'Top Live catches of the Week · 2026-11-02',
        'its weekly badge has a name')
end

-- ============================================================================
--                                   SETTINGS
-- ============================================================================

do
    H.load('modules/admin/settings.lua')
    local S = CP.Settings
    -- step G3: plain switches (they ship off; no typed ENABLE)
    H.eq((S.entry('RealPlayers.liveCrime.cash') or {}).money, nil, 'RealPlayers.liveCrime.cash needs no typed ENABLE')
    H.eq((S.entry('RealPlayers.liveCrime.items') or {}).money, nil, 'RealPlayers.liveCrime.items needs no typed ENABLE')
    H.ok(((S.entry('RealPlayers.liveCrime.cash') or {}).desc or ''):find(
        'true = a live case pays the officers cash like a mission',
        1,
        true
    ) ~= nil, 'RealPlayers.liveCrime.cash: its comment is the description')
    H.eq((S.entry('RealPlayers.liveCrime.items') or {}).desc,
        'true = a live case rolls the item rewards of its type too (Config.Rewards)',
        'RealPlayers.liveCrime.items: its comment')
    H.eq((S.entry('RealPlayers.liveCrime.tier') or {}).kind, 'enum', 'RealPlayers.liveCrime.tier is a pick')
    H.eq((S.check('RealPlayers.liveCrime.tier', 'suspects')), false, 'crew or officers only')
    H.ok((S.check('Leaderboard.metrics', { 'points', 'live_catches' })), 'live_catches can be put on the board')
end

-- ============================================================================
--            VOLUNTEER CASES (V22b): POINTS ONLY UNLESS SWITCHED ON
-- ============================================================================

do
    H.load('modules/realplayers/match.lua')
    local V = CP.Volunteers
    local vc = Config.RealPlayers.volunteer
    local same = { 'typeOfTheDay', 'goals', 'challenge', 'cash', 'items' }
    for _, k in ipairs(same) do
        H.eq(vc[k], false, 'RealPlayers.volunteer.' .. k .. ' ships false')
    end
    local run, p = Run(false)
    H.eq(CP.RealPlayersTakePart(run, 'cash'), true, 'an NPC run (no yes) is a plain mission')
    run.realSuspect = 'volunteer'
    for _, k in ipairs(same) do
        H.eq(CP.RealPlayersTakePart(run, k), false, 'a volunteer case: no ' .. k .. ' while its switch is off')
        Config.RealPlayers.liveCrime[k] = true
        H.eq(CP.RealPlayersTakePart(run, k), false, 'the live switch of ' .. k .. ' does not count for volunteers')
        Config.RealPlayers.liveCrime[k] = false
        vc[k] = true
        H.eq(CP.RealPlayersTakePart(run, k), true, k .. ' on: it takes part')
        vc[k] = false
    end
    Config.RealPlayers.liveCrime.goals = true
    H.ok(CP.RealPlayersRowFilter('goals', 'r.'):find('r.breakdown', 1, true) ~= nil,
        'goals off: volunteer rows left out')
    vc.goals = true
    H.eq(CP.RealPlayersRowFilter('goals', ''), '', 'goals on: nothing left out')
    vc.goals = false
    Config.RealPlayers.liveCrime.goals = false
    H.eq(V.counts, nil, 'the volunteer module keeps no take-part copy of its own')

    local amount, cb = CP.Cash.compute(run, p)
    H.eq(amount, 0, 'cash off: a volunteer case pays nothing (cash 0)')
    H.eq(cb.B, 0, 'its base is 0')
    vc.cash = true
    H.eq((CP.Cash.compute(run, p)), 1000, 'cash on: pays like a mission of its type')
    vc.cash = false
    local b = CP.Scoring.compute(run, p, 'completed', { durationS = 60, departments = 1 })
    H.eq(b.tod, false, 'no Type of the Day while typeOfTheDay is off')
    vc.typeOfTheDay = true
    b = CP.Scoring.compute(run, p, 'completed', { durationS = 60, departments = 1 })
    H.eq(b.tod, true, 'typeOfTheDay on: today\'s type doubles it')
    vc.typeOfTheDay = false

    local S = CP.Settings
    H.eq((S.entry('RealPlayers.volunteer.cash') or {}).money, nil, 'RealPlayers.volunteer.cash needs no typed ENABLE')
    H.eq((S.entry('RealPlayers.volunteer.items') or {}).money, nil, 'RealPlayers.volunteer.items needs no typed ENABLE')
    H.eq((S.entry('RealPlayers.volunteer.items') or {}).desc,
        'true = it rolls the item rewards of its type too (Config.Rewards)', 'RealPlayers.volunteer.items: its comment')
end

return H

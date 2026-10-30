-- Twists the officers choose at accept (PLAN M8b): CP.Twists and CP.Events' fit, offer, check and roll.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
local T = CP.Twists

-- ============================================================================
--                               SHIPPED SETTINGS
-- ============================================================================

local ev = Config.Events
H.eq(ev.modifierChance, 0, 'random twists ship off (owner decision): officers choose their own')
H.eq(ev.modifierPoints, nil, 'the single modifier reward is gone: each twist has its own')
H.eq(ev.modifiers, nil, 'and so is the old roll switch list')
H.eq(ev.twists.armored_hostiles.points, 0.25, 'Armored Hostiles +25% of P')
H.eq(ev.twists.armored_hostiles.cash, 1.25, 'Armored Hostiles x1.25 cash')
H.eq(ev.twists.time_crunch.points, 0.20, 'Time Crunch +20% of P')
H.eq(ev.twists.time_crunch.cash, 1.20, 'Time Crunch x1.20 cash')
H.eq(ev.twists.radio_silence.points, 0.25, 'Radio Silence +25% of P')
H.eq(ev.twists.radio_silence.cash, 1.25, 'Radio Silence x1.25 cash')
for _, key in ipairs(T.ORDER) do H.eq(ev.twists[key].enabled, true, key .. ' ships on') end
H.eq(ev.twistMaxPoints, 0.70, 'stacked points cap: +70%')
H.eq(ev.twistMaxCash, 1.95, 'stacked cash cap: x1.95')

-- ============================================================================
--                           CP.Twists (shared, pure)
-- ============================================================================

H.eq(table.concat(T.ORDER, ','), 'armored_hostiles,time_crunch,radio_silence', 'the three twists, in order')
H.eq(table.concat(T.sorted({ 'radio_silence', 'bogus', 'time_crunch', 'radio_silence' }), ','),
    'time_crunch,radio_silence', 'sorted: known keys, each once, in order')
H.eq(table.concat(T.of({ modifiers = { 'radio_silence', 'armored_hostiles' }, modifier = 'armored_hostiles' }), ','),
    'armored_hostiles,radio_silence', 'a run\'s twists: its modifiers list')
H.eq(table.concat(T.of({ modifier = 'time_crunch' }), ','), 'time_crunch', 'a run with one modifier only (before M8b)')
H.eq(#T.of({ modifiers = {} }), 0, 'no twist')
H.eq(#T.of(nil), 0, 'nil')
H.eq(T.has({ modifier = 'time_crunch', modifiers = { 'time_crunch', 'radio_silence' } }, 'radio_silence'), true,
    'Radio Silence chosen next to another twist is found (the list, not the first key)')
H.eq(T.has({ modifier = 'time_crunch', modifiers = { 'time_crunch' } }, 'radio_silence'), false, 'and only then')

local b = T.bonus({})
H.eq(b.points, 0, 'no twist: no points')
H.eq(b.cash, 1.0, 'no twist: x1.00 cash')
b = T.bonus({ 'radio_silence', 'time_crunch' })
H.near(b.points, 0.45, 1e-9, 'two twists: their points shares add up (+25% + +20%)')
H.near(b.cash, 1.5, 1e-9, 'and their cash multipliers multiply (x1.25 x x1.20 = x1.50)')
H.eq(b.lines[1].key, 'time_crunch', 'one line per twist, in order')
H.near(b.lines[2].points, 0.25, 1e-9, 'each line its own share')
b = T.bonus(T.ORDER)
H.near(b.points, 0.70, 1e-9, 'all three: +70% points')
H.near(b.cash, 1.875, 1e-9, 'all three: x1.875 cash (under the x1.95 cap)')

-- the caps keep stacking sane
ev.twistMaxPoints, ev.twistMaxCash = 0.5, 1.4
b = T.bonus(T.ORDER)
H.near(b.points, 0.5, 1e-9, 'points stop at twistMaxPoints')
H.near(b.lines[3].points, 0.05, 1e-9, 'the last line gets only what is left under the cap')
H.near(b.cash, 1.4, 1e-9, 'cash stops at twistMaxCash')
ev.twistMaxPoints, ev.twistMaxCash = 0.70, 1.95

-- a reward an owner sets out of range never takes points or cash away
ev.twists.time_crunch.points, ev.twists.time_crunch.cash = -1, 0.5
local c = T.cfg('time_crunch')
H.eq(c.points, 0, 'a negative points share counts as 0')
H.eq(c.cash, 1.0, 'a cash multiplier below 1.0 counts as 1.0')
ev.twists.time_crunch.points, ev.twists.time_crunch.cash = 0.20, 1.20
H.eq(T.cfg('bogus'), nil, 'unknown twist')

-- ============================================================================
--                  CP.Events: FITS, OFFER, CHECK, KEEP, ROLL
-- ============================================================================

H.load('modules/events/server.lua')
local E = CP.Events

-- a block that spawns armed NPCs (its armedCount, the Mission Builder's armed budget) and one that does not
CP.Blocks.register('twist_armed', {
    armedCount = function(o) return o.armed or 0 end,
})
CP.Blocks.register('twist_quiet', {
    armedCount = function() return 0 end,
})
local function Def(id, block, opts)
    opts = opts or {}
    return {
        id = id,
        type = 'tactical',
        timeLimit = opts.timeLimit,
        isBoss = opts.isBoss,
        objectives = { { block = block, armed = opts.armed } },
    }
end
local armed = Def('armed', 'twist_armed', { armed = 4 })
local quiet = Def('quiet', 'twist_quiet')
local unarmedArmedBlock = Def('none_armed', 'twist_armed', { armed = 0 })
local boss = Def('boss', 'twist_armed', { armed = 9, isBoss = true })

H.eq(E.twistFits('armored_hostiles', armed), true, 'Armored Hostiles fits a mission with armed NPCs')
H.eq(E.twistFits('armored_hostiles', quiet), false, 'never one without')
H.eq(E.twistFits('armored_hostiles', unarmedArmedBlock), false, 'the block\'s count decides, not its name')
H.eq(E.twistFits('armored_hostiles', nil), false, 'nor a run that names no mission')
H.eq(E.twistFits('time_crunch', quiet), true, 'Time Crunch fits a mission with a time limit (600 s by default)')
H.eq(E.twistFits('time_crunch', Def('t0', 'twist_quiet', { timeLimit = 0 })), false, 'not one without a time limit')
H.eq(E.twistFits('radio_silence', quiet), true, 'Radio Silence fits every mission')
H.eq(E.twistFits('radio_silence', boss), false, 'no twist on the Weekly Boss')
H.eq(E.twistFits('bogus', quiet), false, 'unknown twist')
-- a mission whose block is not registered yet is not remembered as unarmed: asked again once it is
local late = Def('late', 'twist_late', { armed = 2 })
H.eq(E.twistFits('armored_hostiles', late), false, 'a block not registered yet: not armed for now')
CP.Blocks.register('twist_late', {
    armedCount = function(o) return o.armed or 0 end,
})
H.eq(E.twistFits('armored_hostiles', late), true, 'asked again once the block is there')

local offer = E.twistOffer('tactical', { quiet })
local keys = {}
for i, o in ipairs(offer) do keys[i] = o.key end
H.eq(table.concat(keys, ','), 'time_crunch,radio_silence', 'no armed NPCs in the pool: no Armored Hostiles offered')
H.eq(offer[1].label, 'Time Crunch', 'the offer carries the label')
H.eq(offer[1].desc, 'The time limit is 25% shorter.', 'what it does (Config.Events.timeCrunchCut)')
H.eq(offer[2].desc:find('only each objective\'s area', 1, true) ~= nil, true,
    'Radio Silence says what Config.Markers.radioSilence hides (area, shipped)')
H.ok(offer[1].points == 0.20 and offer[1].cash == 1.20, 'and its bonus')
offer = E.twistOffer('tactical', { quiet, armed })
H.eq(offer[1].key, 'armored_hostiles', 'one mission with armed NPCs in the pool: Armored Hostiles is offered')
H.eq(offer[1].some, true, '...marked: it fits only some of the type\'s missions (the mission is drawn after)')
H.eq(offer[1].desc, 'Armed NPCs wear 50 extra armour.', 'with Config.Events.armoredArmour')
H.eq(offer[2].some, nil, 'Time Crunch fits every one')
H.eq(#E.twistOffer('weekly_boss', { boss }), 0, 'nothing for the Weekly Boss')
H.eq(#E.twistOffer('tactical', {}), 0, 'nothing for an empty pool')
ev.twists.radio_silence.enabled = false
offer = E.twistOffer('tactical', { quiet })
H.eq(#offer, 1, 'a switched-off twist is never offered')
ev.twists.radio_silence.enabled = true

-- the list the tablet sends at accept
local clean, err = E.checkTwists(nil, 'tactical', { quiet })
H.eq(#clean, 0, 'no twists sent: none')
clean = E.checkTwists({}, 'tactical', { quiet })
H.eq(#clean, 0, 'an empty list: none')
clean = E.checkTwists({ 'radio_silence', 'time_crunch', 'radio_silence' }, 'tactical', { quiet })
H.eq(table.concat(clean, ','), 'time_crunch,radio_silence', 'a valid choice, each once, in order')
clean, err = E.checkTwists({ 'bogus' }, 'tactical', { quiet })
H.eq(clean, nil, 'an unknown key is refused')
H.eq(err, 'err.invalid_payload', '...as a bad payload')
clean, err = E.checkTwists('radio_silence', 'tactical', { quiet })
H.eq(err, 'err.invalid_payload', 'not a list: refused')
clean, err = E.checkTwists({ a = 'radio_silence' }, 'tactical', { quiet })
H.eq(err, 'err.invalid_payload', 'a map is not a list')
clean, err = E.checkTwists({ 'time_crunch', 'time_crunch', 'time_crunch', 'time_crunch' }, 'tactical', { quiet })
H.eq(err, 'err.invalid_payload', 'more entries than there are twists: refused')
clean, err = E.checkTwists({ 'armored_hostiles' }, 'tactical', { quiet })
H.eq(clean, nil, 'Armored Hostiles for a pool without armed NPCs is refused')
H.eq(err, 'err.twist_unavailable', '...as not available')
clean, err = E.checkTwists({ 'time_crunch' }, 'weekly_boss', { boss })
H.eq(err, 'err.twist_unavailable', 'no twist for the Weekly Boss')
ev.twists.time_crunch.enabled = false
clean, err = E.checkTwists({ 'time_crunch' }, 'tactical', { quiet })
H.eq(err, 'err.twist_unavailable', 'a switched-off twist is refused')
ev.twists.time_crunch.enabled = true

-- after the draw: what fits the drawn mission stays, the rest is dropped (no bonus for a twist that does nothing)
local kept, dropped = E.fitTwists({ mission = quiet }, { 'radio_silence', 'armored_hostiles' })
H.eq(table.concat(kept, ','), 'radio_silence', 'kept: what the drawn mission has use for')
H.eq(table.concat(dropped, ','), 'armored_hostiles', 'dropped: Armored Hostiles on a mission without armed NPCs')
kept = E.fitTwists({ mission = armed }, { 'armored_hostiles', 'time_crunch' })
H.eq(table.concat(kept, ','), 'armored_hostiles,time_crunch', 'both kept on a mission with armed NPCs')
for _, run in ipairs({
    { mission = quiet, test = { adminSrc = 1 } },
    { mission = quiet, operationId = 3 },
    { mission = boss, isBoss = true },
}) do
    kept, dropped = E.fitTwists(run, { 'radio_silence' })
    H.eq(#kept, 0, 'never a twist on a test run, an operation or the Weekly Boss')
    H.eq(#dropped, 1, '...the sent one is dropped')
end

-- the random roll: off as shipped; when the owner turns it on, it only adds a twist the run does not have yet
for s = 1, 50 do
    H.eq(E.rollModifier({ seed = s, mission = quiet, modifiers = {} }), nil, 'no random twist as shipped #' .. s)
end
ev.modifierChance = 1
for s = 1, 30 do
    local key = E.rollModifier({ seed = s * 7919, mission = quiet, modifiers = { 'time_crunch' } })
    H.eq(key, 'radio_silence', 'a random twist adds to the chosen ones, never one already there #' .. s)
end
H.eq(E.rollModifier({ seed = 5, mission = quiet, modifiers = { 'time_crunch', 'radio_silence' } }), nil,
    'nothing left that fits: no roll')
H.eq(E.rollModifier({ seed = 5, mission = armed, modifiers = { 'time_crunch', 'radio_silence' } }), 'armored_hostiles',
    'Armored Hostiles is rolled only where armed NPCs spawn')
ev.modifierChance = 0

-- the Today screen's list: each twist with its switch and bonus
local mods = E.modifiers()
H.eq(mods.time_crunch.enabled, true, 'switch')
H.ok(mods.time_crunch.points == 0.20 and mods.time_crunch.cash == 1.20, 'bonus')
H.eq(mods.armored_hostiles.armedOnly, true, 'Armored Hostiles: only where armed NPCs spawn')

return H

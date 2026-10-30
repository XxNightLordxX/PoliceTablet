-- Cash bonuses inside admin bounds (step P16): happyHourCash (x the cash of a run a department leads that was

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false

-- ============================================================================
--                                    STUBS
-- ============================================================================

local defs, values, rows, held = {}, {}, {}, false
CP.DeptControls = {
    register = function(key, def)
        defs[key] = def
        return true
    end,
    def = function(key) return defs[key] end,
    get = function(dept, key)
        local v = values[dept or '*'] and values[dept or '*'][key]
        if v ~= nil then return v, rows[key] end
        return defs[key] and defs[key].configValue() or nil
    end,
    heldBy = function() return held end,
}

H.load('modules/happyhour/server.lua')
H.load('modules/events/server.lua')
H.load('modules/cash/server.lua')
local HH, E, Cash = CP.HappyHour, CP.Events, CP.Cash
local MC = Config.MissionControls.controls
local SAST = { { citizenid = 'SAST1' } }

-- A run of 1000 base cash, one officer, the standard tier (x1.0).
local function Run(extra)
    local run = { id = 1, cashBase = 1000, payTier = { tier = 'standard', cash = 1.0, points = 1.0 }, order = { 1 } }
    for k, v in pairs(extra or {}) do run[k] = v end
    return run
end
local DONE = { result = 'completed' }

-- ============================================================================
--                            SHIPPED: NOTHING MOVES
-- ============================================================================

for _, key in ipairs({ 'happyHourCash', 'twistCash' }) do
    H.eq(MC[key].on, false, key .. ' ships off')
    H.ok(MC[key].min == 1.0 and MC[key].max == 1.0, key .. ' ships with min = max = 1.0 (moves nothing)')
    H.eq(defs[key].scope, 'run', key .. ' is read at the accept')
end
H.eq(defs.happyHourCash.kind, 'number', 'happyHourCash: one multiplier')
H.eq(defs.twistCash.kind, 'map', 'twistCash: a multiplier per twist')
H.eq(defs.happyHourCash.configValue(), 1.0, 'happyHourCash config value x1.0')
H.eq(defs.twistCash.configValue().armored_hostiles, 1.0, 'twistCash config value x1.0 per enabled twist')
H.eq((Cash.compute(Run(), DONE)), 1000, 'a plain run pays its base')
local plain = { modifiers = { 'armored_hostiles' } }
H.eq((Cash.compute(Run(plain), DONE)), 1250, 'a twist pays its config cash')
H.eq(
    (Cash.compute(Run({ modifiers = plain.modifiers, controls = { twistCash = defs.twistCash.configValue() } }), DONE)),
    1250, 'the config twist cash value changes nothing')

-- ============================================================================
--                          SAST HAPPY HOUR CASH x1.2
-- ============================================================================

values.sast = { happyHourCash = 1.2 }
H.eq(HH.cashBonusFor(1.2, SAST), nil, 'no happy hour running: no bonus at the accept')
values['*'] = { happyHour = { minutes = 15, noRepeat = 0 } }
rows.happyHour = { expiresAt = os.time() + 600, setBy = 'SUP1' }
local bonus = HH.cashBonusFor(1.2, SAST)
H.eq(bonus, 1.2, 'a SAST-led run accepted in the window carries x1.2')
H.eq(HH.cashBonusFor(1.0, SAST), nil, 'x1.0 (the shipped bounds) is no bonus')
H.eq(HH.cashBonusFor(9, SAST), nil, 'never above the control range')
held = true
H.eq(HH.cashBonusFor(1.2, SAST), nil, 'the one who started the happy hour (and his unit) gets none')
held = false

local during = Run({ controls = { cashBonus = bonus } })
local amount, cb = Cash.compute(during, DONE)
H.eq(amount, 1200, 'accepted in the window: pays x1.2')
H.eq(cb.mBonus, 1.2, 'the breakdown names the bonus (the result card shows it)')
H.eq(cb.amount, 1200, 'the breakdown amount carries it (Config.Cash.dailyCap cuts that amount when it pays)')

rows.happyHour = { expiresAt = os.time() - 1, setBy = 'SUP1' }
H.eq(HH.cashBonusFor(1.2, SAST), nil, 'accepted after the hour: no bonus')
local after, cbAfter = Cash.compute(Run(), DONE)
H.ok(after == 1000 and cbAfter.mBonus == nil, 'accepted after the hour: pays x1')
H.eq((Cash.compute(during, DONE)), 1200, 'the hour ending never cuts a run accepted in it')

H.eq((Cash.compute(during, { result = 'failed' })), 0, 'no bonus on a failed run')
H.eq((Cash.compute(Run({ test = {}, controls = { cashBonus = 1.2 } }), DONE)), 1000, 'none on a test run')
H.eq((Cash.compute(Run({ isBoss = true, controls = { cashBonus = 1.2 } }), DONE)), 1000, 'none on the Weekly Boss')
H.eq((Cash.compute(Run({ operationId = 4, controls = { cashBonus = 1.2 } }), DONE)), 1000,
    'none on a Cross-Department run')

-- ============================================================================
--                                  TWIST CASH
-- ============================================================================

local open = { min = 1.0, max = 1.25 }
H.eq(defs.twistCash.check({ armored_hostiles = 1.25 }, open).armored_hostiles, 1.25, 'inside the bounds: kept')
H.eq(defs.twistCash.check({ armored_hostiles = 1.3 }, open), nil, 'above the admin max: refused')
H.eq(defs.twistCash.check({ armored_hostiles = 1.1 }, MC.twistCash), nil, 'the shipped bounds refuse any raise')
H.eq(defs.twistCash.check({ nope = 1.1 }, open), nil, 'an unknown twist: refused')
H.eq(defs.twistCash.clamp({ armored_hostiles = 2 }, open).armored_hostiles, 1.25,
    'a saved value moves into narrowed bounds')
H.ok(defs.twistCash.relaxes({ time_crunch = 1.1 }) and not defs.twistCash.relaxes({ time_crunch = 1.0 }),
    'a raise relaxes (the self rule applies)')

local scale = { armored_hostiles = 1.2 }
H.eq((Cash.compute(Run({ modifiers = { 'armored_hostiles' }, controls = { twistCash = scale } }), DONE)), 1500,
    'Armored Hostiles x1.25 x the department 1.2 = x1.5')
local two = {
    modifiers = { 'armored_hostiles', 'time_crunch' },
    controls = { twistCash = { armored_hostiles = 1.25, time_crunch = 1.25 } },
}
local capped, cbTwo = Cash.compute(Run(two), DONE)
H.eq(capped, 1950, 'two raised twists never above Config.Events.twistMaxCash (x1.95)')
H.eq(cbTwo.mMod, 1.95, '...the breakdown shows the capped multiplier')
H.eq(CP.Twists.bonus({ 'armored_hostiles' }, scale).points, CP.Twists.bonus({ 'armored_hostiles' }).points,
    'points never change')
local function Raised(extra)
    local run = Run({ modifiers = { 'armored_hostiles' }, controls = { twistCash = scale } })
    for k, v in pairs(extra) do run[k] = v end
    return (Cash.compute(run, DONE))
end
H.eq(Raised({ test = {} }), 1250, 'twist cash: none on a test run')
H.eq(Raised({ operationId = 2 }), 1250, 'twist cash: none on a Cross-Department run')
H.eq(
    (Cash.compute(Run({ modifiers = { 'armored_hostiles' }, controls = { twistCash = scale } }), { result = 'failed' })),
    0, 'twist cash: nothing on a failed run')

values.sast.twistCash = scale
local offer = E.twistOffer('tactical', { { id = 'x', type = 'tactical', objectives = {} } }, 'sast')
local function CashOf(list, key)
    for _, o in ipairs(list) do
        if o.key == key then return o.cash end
    end
end
H.eq(CashOf(offer, 'radio_silence'), 1.25, 'the accept step: a twist without a raise shows its config cash')
values.sast.twistCash = { radio_silence = 1.2 }
offer = E.twistOffer('tactical', { { id = 'x', type = 'tactical', objectives = {} } }, 'sast')
H.eq(CashOf(offer, 'radio_silence'), 1.5, 'the accept step shows the department\'s raised twist cash')

return H

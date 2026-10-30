-- The twists a department offers and pre-ticks (step P15): the twists Mission control narrows the accept step's
-- offer (Mission Board, mission call claims) to the twists the leader's department offers, marks the ones it
-- pre-ticks and refuses a chosen twist the department does not offer. Plain Lua: stubbed controls, no database.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false

Config.Departments = {
    sast = { label = 'San Andreas State Troopers', short = 'SAST', jobs = { 'sast' }, supervisorGrade = 3 },
    fib = { label = 'Federal Investigation Bureau', short = 'FIB', jobs = { 'fib' }, supervisorGrade = 3 },
}

-- ============================================================================
--                                    STUBS
-- ============================================================================

local defs, values = {}, {}
CP.DeptControls = {
    register = function(key, def)
        defs[key] = def
        return true
    end,
    def = function(key) return defs[key] end,
    get = function(dept, key)
        local v = values[dept] and values[dept][key]
        if v ~= nil then return v end
        return defs[key] and defs[key].configValue() or nil
    end,
}

H.load('modules/events/server.lua')
local E = CP.Events

CP.Blocks.register('dt_armed', {
    armedCount = function(o) return o.armed or 0 end,
})
CP.Blocks.register('dt_quiet', {
    armedCount = function() return 0 end,
})
local armed = { id = 'dt_a', type = 'tactical', objectives = { { block = 'dt_armed', armed = 3 } } }
local quiet = { id = 'dt_q', type = 'tactical', objectives = { { block = 'dt_quiet' } } }
local pool = { armed, quiet }

local function Keys(offer)
    local out = {}
    for i, o in ipairs(offer) do out[i] = o.key end
    return table.concat(out, ',')
end

local function Ticked(offer)
    local out = {}
    for _, o in ipairs(offer) do
        if o.ticked then out[#out + 1] = o.key end
    end
    return table.concat(out, ',')
end

-- ============================================================================
--                      SHIPPED: THE ACCEPT STEP AS BEFORE
-- ============================================================================

H.eq(Config.MissionControls.controls.twists.on, false, 'the twists control ships off')
local def = defs.twists
H.ok(def ~= nil and def.kind == 'map' and def.scope == 'run' and def.bounded == false,
    'registered: a map control read at the accept (scope run), no min or max')
H.eq(table.concat(def.configValue().offered, ','), 'armored_hostiles,time_crunch,radio_silence',
    'its config value offers every enabled twist')
H.eq(#def.configValue().ticked, 0, '...and ticks none')
H.eq(Keys(E.twistOffer('tactical', pool, 'sast')), Keys(E.twistOffer('tactical', pool)),
    'with the config value a department gets the same offer as before')
H.eq(Ticked(E.twistOffer('tactical', pool, 'sast')), '', '...nothing pre-ticked')

-- ============================================================================
--                         SAST OFFERS ONLY TIME CRUNCH
-- ============================================================================

values.sast = { twists = { offered = { 'time_crunch' }, ticked = { 'time_crunch' } } }
local offer = E.twistOffer('tactical', pool, 'sast')
H.eq(Keys(offer), 'time_crunch', 'a SAST leader is offered Time Crunch only')
H.eq(Ticked(offer), 'time_crunch', '...pre-ticked')
H.eq(Keys(E.twistOffer('tactical', pool, 'fib')), 'armored_hostiles,time_crunch,radio_silence', 'FIB unchanged')
H.eq(Ticked(E.twistOffer('tactical', pool, 'fib')), '', 'FIB: nothing pre-ticked')

local clean, err = E.checkTwists({ 'armored_hostiles' }, 'tactical', pool, 'sast')
H.eq(clean, nil, 'a SAST leader\'s accept with Armored Hostiles is refused')
H.eq(err, 'err.twist_department', '...because his department does not offer it')
clean = E.checkTwists({ 'time_crunch' }, 'tactical', pool, 'sast')
H.eq(table.concat(clean or {}, ','), 'time_crunch', 'Time Crunch is accepted for SAST')
clean = E.checkTwists({ 'armored_hostiles', 'radio_silence' }, 'tactical', pool, 'fib')
H.eq(table.concat(clean or {}, ','), 'armored_hostiles,radio_silence', 'an FIB leader keeps every twist')
clean, err = E.checkTwists({ 'armored_hostiles' }, 'tactical', { quiet }, 'fib')
H.eq(err, 'err.twist_unavailable', 'the type\'s own fit still comes first')

-- the twists a switched-off twist leaves: never offered, even when the department's saved value names it
Config.Events.twists.time_crunch.enabled = false
H.eq(Keys(E.twistOffer('tactical', pool, 'sast')), '', 'a twist the admin switched off is gone for SAST too')
Config.Events.twists.time_crunch.enabled = true

-- ============================================================================
--                               THE VALUE CHECK
-- ============================================================================

local function Check(v)
    local ok, why = def.check(v)
    return ok, why
end
H.ok(Check({ offered = { 'time_crunch', 'radio_silence' }, ticked = { 'radio_silence' } }) ~= nil, 'a valid value')
H.ok(Check({ offered = {}, ticked = {} }) ~= nil, 'a department may offer no twist at all')
H.eq(select(2, Check({ offered = { 'bogus' }, ticked = {} })), 'err.control_value', 'an unknown twist is refused')
H.eq(Check({ offered = { 'time_crunch' }, ticked = { 'radio_silence' } }), nil, 'a ticked twist must be offered')
H.eq(Check({ offered = { 'time_crunch' }, extra = true }), nil, 'no other fields')
Config.Events.twists.radio_silence.enabled = false
H.eq(Check({ offered = { 'radio_silence' }, ticked = {} }), nil, 'only twists the admin enabled')
local clamped = def.clamp({ offered = { 'time_crunch', 'radio_silence' }, ticked = { 'radio_silence' } })
H.eq(table.concat(clamped.offered, ',') .. '|' .. table.concat(clamped.ticked, ','), 'time_crunch|',
    'a saved value loses a twist the admin switched off since')
Config.Events.twists.radio_silence.enabled = true
H.eq(def.relaxes(), false, 'it never relaxes a rule: it applies to the supervisor who set it too')

-- ============================================================================
--                       THE MISSION BOARD AND THE ACCEPT
-- ============================================================================

H.load('modules/draw/server.lua')
local D = CP.Draw
D.pool = function() return pool end
H.eq(Keys(D.twistOffer('tactical', pool, 'sast')), 'time_crunch', 'the board card offers SAST Time Crunch only')
clean, err = D.checkTwists('tactical', { { src = 2, department = 'sast' } }, { 'armored_hostiles' }, 'sast')
H.eq(err, 'err.twist_department', 'the accept check refuses Armored Hostiles for a SAST leader')
clean = D.checkTwists('tactical', { { src = 3, department = 'fib' } }, { 'armored_hostiles' }, 'fib')
H.eq(table.concat(clean or {}, ','), 'armored_hostiles', 'and accepts it for an FIB leader')

return H

-- Config.RealPlayers (FM4): real players as suspects are one config section with two modes, liveCrime and volunteer

-- Config.RealPlayers (FM4): real players as suspects are one config section with two modes, liveCrime and volunteer
-- (each with its own switch and every option it had), the rules both share at its top (who can be a suspect, proof,
-- conduct, then the staff, antiFarm and surrender blocks) and the criminal tablet. One block per old feature,
-- driven through the new section and the shared helpers (CP.RealPlayers, CP.RealPlayersTakePart,
-- CP.RealPlayersRowFilter); the module files live in modules/realplayers. Plain stubs, no database.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
Config.Debug = false

local RP = Config.RealPlayers
local ROOT = 'Crimson-Police/'

local function Read(path)
    local f = io.open(path, 'r')
    if not f then return nil end
    local s = f:read('a')
    f:close()
    return s
end

-- ============================================================================
--                               THE ONE SECTION
-- ============================================================================

for _, old in ipairs({ 'RealSuspects', 'LiveCrime', 'Volunteers', 'CriminalTablet' }) do
    H.eq(Config[old], nil, 'no Config.' .. old .. ': it is part of Config.RealPlayers (no alias)')
end
H.ok(type(RP) == 'table', 'Config.RealPlayers is one section')
for mode, value in pairs({ liveCrime = RP.liveCrime, volunteer = RP.volunteer, criminalTablet = RP.criminalTablet }) do
    local cfg, on = CP.RealPlayers(mode)
    H.eq(cfg, value, mode .. ': CP.RealPlayers answers the config table')
    H.eq(on, false, mode .. ': ships off, as before')
end
local all, anyOn = CP.RealPlayers()
H.eq(all, RP, 'no mode: the whole section')
H.eq(anyOn, false, 'and both modes are off')
H.eq(next((CP.RealPlayers('nosuch'))), nil, 'an unknown mode: an empty table')
H.eq(select(2, CP.RealPlayers('nosuch')), false, 'and off')

-- ============================================================================
--                               THE SHARED RULES
-- ============================================================================
-- (OLD CONFIG.REALSUSPECTS), SHIPPED VALUES.

H.eq(RP.officerAlerts, 'normal', 'officer alerts go out like any officer\'s')
H.eq(RP.routeEnds, 'first_contact', 'the route ends at the first contact')
H.eq(RP.onLeave, 'void', 'a suspect who leaves counts for nobody')
H.eq(RP.antiFarm.pairCooldownHours, 24, 'one scored case of a pair a day (both modes together)')
H.eq(RP.antiFarm.maxCatchesPerSuspectDay, 2, 'a suspect is worth points twice a day')
H.eq(RP.antiFarm.pairLedgerDays, 30, 'the pair ledger keeps 30 days')
H.eq(RP.antiFarm.pairFlag.count, 2, 'the pair flag: 2 cases')
H.eq(RP.surrender.enabled, true, 'surrender ships on (behind live crimes)')
H.eq(RP.surrender.command, 'surrender', 'the surrender command')
H.eq(RP.staff.screen, true, 'the Real suspects screen')
H.eq(RP.staff.lift, true, 'staff can lift a block early')
for _, mode in ipairs({ 'liveCrime', 'volunteer', 'criminalTablet' }) do
    H.eq(RP[mode].antiFarm, nil, mode .. ' keeps no copy of the shared caps')
end

-- FIN5: the shared rules are three blocks, staff (the Real suspects screen), antiFarm (the caps and the pair ledger)
-- and surrender, each read through CP.RealPlayers; the flat keys they replace are gone (no alias)
local FLAT = {
    adminScreen = 'staff.screen',
    staffLift = 'staff.lift',
    staffNames = 'staff.names',
    weaponNames = 'staff.weaponNames',
    casesKept = 'staff.casesKept',
    saveCases = 'staff.saveCases',
    identityMatch = 'antiFarm.identityMatch',
    pairCooldownHours = 'antiFarm.pairCooldownHours',
    maxCatchesPerSuspectDay = 'antiFarm.maxCatchesPerSuspectDay',
    suspectCooldownMinutes = 'antiFarm.suspectCooldownMinutes',
    pairFlag = 'antiFarm.pairFlag',
    fastCatchSeconds = 'antiFarm.fastCatchSeconds',
    pairLedgerDays = 'antiFarm.pairLedgerDays',
}
for old, new in pairs(FLAT) do
    H.eq(RP[old], nil, 'no flat RealPlayers.' .. old .. ': it is RealPlayers.' .. new)
    local block, key = new:match('^(%w+)%.(%w+)$')
    H.ok(RP[block][key] ~= nil, 'RealPlayers.' .. new .. ' ships a value')
end
H.eq(RP.staff.casesKept, 16, 'staff.casesKept ships 16, as before')
H.eq(RP.staff.saveCases, true, 'staff.saveCases ships true, as before')
H.eq(RP.staff.names, true, 'staff.names ships true, as before')
H.eq(RP.staff.weaponNames, true, 'staff.weaponNames ships true, as before')
H.eq(RP.antiFarm.suspectCooldownMinutes, 30, 'antiFarm.suspectCooldownMinutes ships 30, as before')
H.eq(RP.antiFarm.fastCatchSeconds, 60, 'antiFarm.fastCatchSeconds ships 60, as before')
H.eq(table.concat(RP.antiFarm.identityMatch.flag, ','), 'ip,token', 'antiFarm.identityMatch.flag as before')
for _, part in ipairs({ 'staff', 'antiFarm', 'surrender' }) do
    local cfg, on = CP.RealPlayers(part)
    H.eq(cfg, RP[part], part .. ': CP.RealPlayers answers its block')
    H.eq(on, false, part .. ': on only while live crimes or volunteers are on')
end
RP.volunteer.enabled = true
H.eq(select(2, CP.RealPlayers('antiFarm')), true, 'a volunteer mode on: the shared blocks are on')
H.eq(CP.RealPlayersOn('staff'), true, 'CP.RealPlayersOn: the same answer')
H.eq(CP.RealPlayersOn('volunteer'), true, 'CP.RealPlayersOn(mode): its switch')
H.eq(CP.RealPlayersOn('liveCrime'), false, 'and the other mode stays off')
H.eq(CP.RealPlayersOn(), true, 'CP.RealPlayersOn(): either mode on')
RP.volunteer.enabled = false
H.eq(CP.RealPlayersOn('staff'), false, 'both modes off: off')
H.eq(CP.RealPlayersOn('nosuch'), false, 'an unknown part: off')

-- ============================================================================
--              LIVE CRIMES (OLD CONFIG.LIVECRIME), SHIPPED VALUES
-- ============================================================================

local lc = RP.liveCrime
H.eq(lc.enabled, false, 'live crimes ship off')
H.eq(lc.caseTime, 1800, 'a live case lasts 30 minutes at most')
H.eq(lc.maxLiveRuns, 2, 'two LIVE calls and live cases at once')
H.eq(lc.types.atm_robbery, false, 'an ATM robbery is never a LIVE call')
H.eq(lc.tier, 'crew', 'the crew sets the tier')
H.eq(lc.availablePolice, 'idle', 'GetAvailablePolice counts idle officers')

-- ============================================================================
--                              VOLUNTEER SUSPECTS
-- ============================================================================
-- (OLD CONFIG.VOLUNTEERS), SHIPPED VALUES.

local vo = RP.volunteer
H.eq(vo.enabled, false, 'volunteers ship off')
H.eq(vo.command, 'crimsonheat', '/crimsonheat stays as it is')
H.eq(vo.windowMinutes, 60, 'an hour on the list')
H.eq(vo.strikes, 3, 'three strikes')
H.eq(vo.modes.tactical, 'npc', 'every type plays the NPC')
H.eq(vo.payCash, nil, 'payCash is gone: the money switch is cash, as in liveCrime')
H.eq(vo.payRewards, nil, 'payRewards is gone: the item switch is items, as in liveCrime')

local ct = RP.criminalTablet
H.eq(ct.enabled, false, 'the criminal tablet ships off')
H.eq(ct.command, 'crimtab', 'its command')
H.eq(ct.access, 'everyone', 'every non-police player may use it')

-- ============================================================================
--                        EACH MODE KEEPS ITS OWN SWITCH
-- ============================================================================

vo.enabled = true
H.eq(select(2, CP.RealPlayers('volunteer')), true, 'volunteers on')
H.eq(select(2, CP.RealPlayers('liveCrime')), false, 'live crimes stay off')
H.eq(select(2, CP.RealPlayers()), true, 'either mode on: the real-player tools are on')
vo.enabled = false
lc.enabled = true
H.eq(select(2, CP.RealPlayers('volunteer')), false, 'volunteers off')
H.eq(select(2, CP.RealPlayers()), true, 'live crimes alone also turn them on')
lc.enabled = false
H.eq(select(2, CP.RealPlayers()), false, 'both off: off')
ct.enabled = true
H.eq(select(2, CP.RealPlayers('criminalTablet')), true, 'the criminal tablet has its own switch')
H.eq(select(2, CP.RealPlayers()), false, 'which alone turns no mode on')
ct.enabled = false

-- ============================================================================
--                          WHAT A CASE TAKES PART IN
-- ============================================================================
-- OLD LC.counts / V.counts, ONE ENGINE.

local KINDS = { 'typeOfTheDay', 'goals', 'challenge', 'cash', 'items' }
local mission = { missionType = 'patrol' }
local live = { live = {}, missionType = 'tactical' }
local volunteer = { realSuspect = 'volunteer', missionType = 'patrol' }
H.eq(CP.RealPlayersMode(live), 'liveCrime', 'run.live: a live case')
H.eq(CP.RealPlayersMode({ realSuspect = 'live' }), 'liveCrime', 'realSuspect live: a live case')
H.eq(CP.RealPlayersMode(volunteer), 'volunteer', 'realSuspect volunteer: a volunteer case')
H.eq(CP.RealPlayersMode(mission), nil, 'a mission is neither')
for _, k in ipairs(KINDS) do
    H.eq(lc[k], false, 'liveCrime.' .. k .. ' ships false')
    H.eq(vo[k], false, 'volunteer.' .. k .. ' ships false')
    H.eq(CP.RealPlayersTakePart(mission, k), true, 'a mission: ' .. k .. ' as before')
    H.eq(CP.RealPlayersTakePart(live, k), false, 'a live case: no ' .. k .. ' while its switch is off')
    H.eq(CP.RealPlayersTakePart(volunteer, k), false, 'a volunteer case: no ' .. k .. ' while its switch is off')
    lc[k] = true
    H.eq(CP.RealPlayersTakePart(live, k), true, 'liveCrime.' .. k .. ' on: the live case takes part')
    H.eq(CP.RealPlayersTakePart(volunteer, k), false, 'the volunteer case still follows its own switch')
    lc[k], vo[k] = false, true
    H.eq(CP.RealPlayersTakePart(volunteer, k), true, 'volunteer.' .. k .. ' on: the volunteer case takes part')
    H.eq(CP.RealPlayersTakePart(live, k), false, 'the live case still follows its own switch')
    vo[k] = false
end
H.eq(CP.RealPlayersTakePart(live, 'bogus'), false, 'an unknown kind is off for a case')

-- the goal and challenge sums (old LC.rowFilter / V.rowFilter): one filter, each mode's part by its own switch
local both = CP.RealPlayersRowFilter('goals', 'r.')
H.ok(both:find('r.mission_id', 1, true) ~= nil, 'goals off: live rows left out')
H.ok(both:find('r.breakdown', 1, true) ~= nil, 'goals off: volunteer rows left out')
lc.goals = true
H.ok(CP.RealPlayersRowFilter('goals', 'r.'):find('mission_id', 1, true) == nil, 'liveCrime.goals on: live rows count')
H.ok(CP.RealPlayersRowFilter('goals', 'r.'):find('breakdown', 1, true) ~= nil, 'volunteer rows still left out')
vo.goals = true
H.eq(CP.RealPlayersRowFilter('goals', ''), '', 'both on: nothing left out')
lc.goals, vo.goals = false, false
H.eq(
    CP.RealPlayersRowFilter('challenge', ''),
    ' AND COALESCE(mission_id, \'\') <> \'live_crime\''
        .. ' AND COALESCE(JSON_UNQUOTE(JSON_EXTRACT(breakdown, \'$.realSuspect\')), \'\') <> \'volunteer\'',
    'the challenge filter with no alias'
)

-- ============================================================================
--                       THE MODULE: modules/realplayers
-- ============================================================================

local manifest = Read(ROOT .. 'fxmanifest.lua') or ''
H.ok(manifest:find('\'modules/realplayers/*.lua\'', 1, true) ~= nil, 'the manifest loads the server sub-files')
H.ok(manifest:find('\'modules/realplayers/client/*.lua\'', 1, true) ~= nil, 'and the client sub-files')
local parts = {
    'livecrime',
    'opponents',
    'pairs',
    'proof',
    'conduct',
    'surrender',
    'staff',
    'saved',
    'volunteers',
    'match',
    'crimtab',
}
local code = {}
for _, part in ipairs(parts) do
    code[part] = Read(ROOT .. 'modules/realplayers/' .. part .. '.lua')
    H.ok(code[part] ~= nil, 'modules/realplayers/' .. part .. '.lua')
end
for _, part in ipairs({ 'livecrime', 'volunteers', 'crimtab' }) do
    H.ok(Read(ROOT .. 'modules/realplayers/client/' .. part .. '.lua') ~= nil, 'modules/realplayers/client/' .. part)
end
for _, old in ipairs({ 'livecrime', 'opponents', 'volunteers', 'crimtab' }) do
    H.eq(Read(ROOT .. 'modules/' .. old .. '/server.lua'), nil, 'modules/' .. old .. '/server.lua is gone')
end
H.ok(not (code.livecrime or ''):find('function LC.counts', 1, true), 'the live module keeps no take-part copy')
H.ok(not (code.livecrime or ''):find('function LC.rowFilter', 1, true), 'nor a row filter')
H.ok(not (code.match or ''):find('function V.counts', 1, true), 'the volunteer module keeps no take-part copy')
H.ok(not (code.match or ''):find('function V.rowFilter', 1, true), 'nor a row filter')
local p = io.popen(
    'grep -rlE "Config\\.(RealSuspects|LiveCrime|Volunteers|CriminalTablet)\\b" ' .. ROOT .. 'modules ' .. ROOT
        .. 'blocks ' .. ROOT .. 'shared ' .. ROOT .. 'config 2>/dev/null'
)
local stale = p and p:read('a') or ''
if p then p:close() end
H.eq(stale, '', 'no Lua file reads an old section name')

-- FIN5: no module keeps its own thin reader of Config.RealPlayers (a Cfg() / On() / FeatureOn() one-liner over
-- CP.RealPlayers): every reader calls CP.RealPlayers or CP.RealPlayersOn directly
p = io.popen(
    'grep -rnE "local function [A-Za-z]+\\(\\) return \\(?(select\\(2, )?CP\\.RealPlayers\\([^)]*\\)\\)?\\)? end$" '
        .. ROOT .. 'modules ' .. ROOT .. 'blocks 2>/dev/null'
)
local thin = p and p:read('a') or ''
if p then p:close() end
H.eq(thin, '', 'no thin CP.RealPlayers reader copies')
for _, part in ipairs(parts) do
    H.ok(not (code[part] or ''):find('local function Cfg()', 1, true), 'modules/realplayers/' .. part .. ': no Cfg()')
    H.ok(not (code[part] or ''):find('local function FeatureOn()', 1, true), part .. ': no FeatureOn()')
end

return H

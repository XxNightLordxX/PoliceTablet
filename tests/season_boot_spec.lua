-- A planned season end that fell due while the server was down: the season start-up catches it up, the way the
-- weekly bounty weeks are caught up, so a server that restarts across the daily reset still ends the season.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local DAY = 86400
H.sql('DELETE FROM cp_seasons')
-- a running season whose planned end (two days ago) passed while the server was down, with a named next season
H.sql([[INSERT INTO cp_seasons (name, starts_at, active, planned_end, next_name)
    VALUES ('Old', FROM_UNIXTIME(?), 1, FROM_UNIXTIME(?), 'Next')]], { H.time - 30 * DAY, H.time - 2 * DAY })
local W = dofile('tests/fixtures/adminctl/p1_world.lua')(H)
local C = CP.Challenge
for _ = 1, 5 do H.step(1000) end

local s = C.currentSeason(true)
H.ok(s ~= nil and s.name == 'Next', 'the overdue planned end is applied at start: the next season runs')
local old = H.sql('SELECT active, planned_end FROM cp_seasons WHERE name = ?', { 'Old' })[1]
H.ok(old ~= nil and not (old.active == 1 or old.active == true or old.active == '1') and old.planned_end == nil,
    'the old season is ended')
H.eq(#H.sql('SELECT id FROM cp_seasons WHERE active = 1'), 1, 'one active season')

-- the catch-up keeps the rule "at the first daily reset on or after the date": a planned end that passed after the
-- last reset waits for the next reset
local nowTs = os.time()
local lastReset = CP.Schedule.dayStart(nowTs)
local ok, e = W.act('server:admin:scheduleSeasonEnd', 1, { id = s.id, at = nowTs + 3600, reason = 'x' })
H.ok(ok == true, 'planned: ' .. tostring(e))
H.eq(W.async(function() return C._plannedEndCatchUp(nowTs) end), false, 'a planned end still ahead is left alone')
H.sql('UPDATE cp_seasons SET planned_end = FROM_UNIXTIME(?) WHERE id = ?', { lastReset + 1, s.id })
H.eq(W.async(function() return C._plannedEndCatchUp(lastReset + 2) end), false,
    'a planned end after the last reset waits for the next reset')
H.eq(C.currentSeason(true).id, s.id, 'the season still runs')
H.ok(W.async(function() return C._plannedEndCatchUp(lastReset + DAY + 1) end), 'the next reset has passed: it ends')
H.ok(C.currentSeason(true) == nil or C.currentSeason(true).id ~= s.id, 'and the season is over')

return H

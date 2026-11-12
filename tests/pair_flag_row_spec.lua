-- A flag raised after a participant's row was stored (rs_pair_repeat comes from the run:ended hook, after every
-- row settled) flags the stored row too: it reaches the Review Queue, cash not paid yet is held, paid cash stays
-- paid, the counted XP and the pending item rewards wait for the review.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local W = dofile('tests/fixtures/adminctl/p1_world.lua')(H)
local One = W.one

H.sql('DELETE FROM cp_mission_runs')
H.sql('DELETE FROM cp_item_rewards')
Config.Rewards.enabled = true
H.mockInventory({ water = { label = 'Water' } })
H.load('modules/system/schedule.lua')
H.load('modules/money/engine.lua')
H.load('modules/money/rewards.lua')
H.advance(5000)

W.officer('OFF00091', 'sast', 60)
W.officer('OFF00092', 'sast', 60)
local owed = W.row({ citizenid = 'OFF00091', points = 60, cash = 100, cashStatus = 'pending', at = H.time - 600 })
local paid = W.row({
    citizenid = 'OFF00092',
    points = 60,
    cash = 100,
    cashPaid = 100,
    cashStatus = 'paid',
    at = H.time - 600,
})
H.sql([[INSERT INTO cp_item_rewards (row_id, source, source_key, citizenid, item, count, value, status)
    VALUES (?, 'run', 'z9-pair', 'OFF00091', 'water', 1, 5, 'pending')]], { owed })

local run = {
    id = 'z9-pair-run',
    missionId = 'beat_patrol',
    participants = {
        [5] = { src = 5, citizenid = 'OFF00091', status = 'left', rowId = owed },
        [6] = { src = 6, citizenid = 'OFF00092', status = 'left', rowId = paid },
    },
}
local ok1 = W.async(function() return CP.AntiCheat.flag(run, 5, 'rs_pair_repeat', 'same pair') end)
local ok2 = W.async(function() return CP.AntiCheat.flag(run, 6, 'rs_pair_repeat', 'same pair') end)
H.ok(ok1 and ok2, 'both flags are raised')

local a = One('SELECT flagged, flag_reason, cash_status FROM cp_mission_runs WHERE id = ?', { owed })
H.eq(tonumber(H.bit(a.flagged)), 1, 'the stored row of the owed officer is flagged')
H.eq(a.flag_reason, 'rs_pair_repeat', 'with the pair-repeat reason (the Review Queue lists it)')
H.eq(a.cash_status, 'held', 'its cash not paid yet is held for the review')
H.eq(W.xp('OFF00091'), 0, 'its counted XP waits for the review')
H.eq((One('SELECT status FROM cp_item_rewards WHERE row_id = ?', { owed }) or {}).status, 'held',
    'its pending item reward is held')
local b = One('SELECT flagged, cash_status FROM cp_mission_runs WHERE id = ?', { paid })
H.eq(tonumber(H.bit(b.flagged)), 1, 'the paid officer\'s row is flagged too')
H.eq(b.cash_status, 'paid', 'paid cash stays paid')

return H

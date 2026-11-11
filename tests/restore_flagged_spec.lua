-- Restoring a bulk-void batch keeps the held item rewards of a row that is still flagged (it waits for the Review
-- Queue), and undoing a batch-caused forfeit of a flagged row puts its items back to held, not pending.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
local W = dofile('tests/fixtures/adminctl/p1_world.lua')(H)
local Act, Data, Rid, One = W.act, W.data, W.rid, W.one

H.sql('DELETE FROM cp_mission_runs')
H.sql('DELETE FROM cp_item_rewards')
H.sql('DELETE FROM cp_audit')
Config.Rewards.enabled = true
H.mockInventory({ water = { label = 'Water' } })
H.load('modules/system/schedule.lua')
H.load('modules/money/engine.lua')
H.load('modules/money/rewards.lua')
H.advance(5000)

local function Item(rowId, status)
    H.sql([[INSERT INTO cp_item_rewards (row_id, source, source_key, citizenid, item, count, value, status)
        VALUES (?, 'run', ?, 'OFF00071', 'water', 1, 5, ?)]], { rowId, 'z7-' .. rowId, status })
    return W.count('SELECT MAX(id) AS n FROM cp_item_rewards')
end

local function Status(id) return (One('SELECT status FROM cp_item_rewards WHERE id = ?', { id }) or {}).status end

do
    W.officer('OFF00071', 'sast', 0)
    local flagged = W.row({ citizenid = 'OFF00071', points = 60, flagged = true, at = H.time - 3600 })
    local clean = W.row({ citizenid = 'OFF00071', points = 60, at = H.time - 3500 })
    local heldFlagged, heldClean = Item(flagged, 'held'), Item(clean, 'held')

    local filter = { citizenid = 'OFF00071', allTime = true }
    local pv = Data('admin:previewBulkVoid', 1, { filter = filter })
    H.eq(pv and pv.total, 2, 'both rows are in the batch')
    local ok, e = Act('server:admin:bulkVoid', 1, {
        filter = filter,
        reason = 'Bugged',
        confirm = pv and pv.confirmWord,
        previewToken = pv and pv.previewToken,
        requestId = Rid(),
    })
    H.ok(ok == true, 'the bulk void starts: ' .. tostring(e))
    H.ok(W.drain(), 'the void job finishes')
    local batchId = e and e.jobId

    ok, e = Act('server:admin:restoreBatch', 1, { batchId = batchId, reason = 'Undo', requestId = Rid() })
    H.ok(ok == true, 'the batch is restored: ' .. tostring(e))
    H.ok(W.drain(), 'the restore job finishes')
    H.eq(Status(heldFlagged), 'held', 'the flagged row keeps its item reward held for the Review Queue')
    H.ok(Status(heldClean) ~= 'held', 'the clean row gets its item reward: ' .. tostring(Status(heldClean)))
end

do
    -- the forfeit undo of a row that is still flagged (voided already cleared) keeps the items held
    local row = W.row({ citizenid = 'OFF00071', points = 60, flagged = true, at = H.time - 3000 })
    local item = Item(row, 'forfeited')
    W.async(function() return CP.Rewards.undoForfeit(row) end)
    H.eq(Status(item), 'held', 'a flagged row\'s forfeited items come back held, not pending')
end

do
    -- Z8B: a paid row voided by a batch whose items ForfeitRows forfeited gets them back on the batch Undo
    local paid = W.row({
        citizenid = 'OFF00071',
        points = 60,
        cash = 100,
        cashPaid = 100,
        cashStatus = 'paid',
        at = H.time - 2500,
    })
    local filter = { citizenid = 'OFF00071', allTime = true }
    local pv = Data('admin:previewBulkVoid', 1, { filter = filter })
    local ok, e = Act('server:admin:bulkVoid', 1, {
        filter = filter,
        reason = 'Bugged',
        confirm = pv and pv.confirmWord,
        previewToken = pv and pv.previewToken,
        requestId = Rid(),
    })
    H.ok(ok == true and W.drain(), 'Z8B: the second bulk void runs: ' .. tostring(e))
    local item = Item(paid, 'forfeited')
    ok, e = Act('server:admin:restoreBatch', 1, { batchId = e and e.jobId, reason = 'Undo', requestId = Rid() })
    H.ok(ok == true and W.drain(), 'Z8B: the second batch is restored: ' .. tostring(e))
    H.ok(Status(item) == 'pending' or Status(item) == 'given',
        'Z8B: the paid row\'s forfeited items come back: ' .. tostring(Status(item)))
end

do
    -- Z8B: an admin's Flag for review holds the row's pending item rewards until the Review Queue decides
    local row = W.row({ citizenid = 'OFF00071', points = 60, at = H.time - 2000 })
    local item = Item(row, 'pending')
    local ok, e = Act('server:admin:flagRow', 1, { rowId = row, reason = 'look again', requestId = Rid() })
    H.ok(ok == true, 'Z8B: the row is flagged by hand: ' .. tostring(e))
    H.eq(Status(item), 'held', 'Z8B: its pending item reward is held')
end

return H

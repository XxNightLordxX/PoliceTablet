-- The crash matrix of the server's own money journeys: each journey cut by a `restart Crimson-Police`

-- The crash matrix of the server's own money journeys: each journey cut by a `restart Crimson-Police`
-- after every database await of it, then the server starts again, its start-up catch-ups run, the officer logs in
-- again, and the journey must have recovered: paid at most once (or left 'paying' for an admin's Resolve in
-- Payments), the run ended at most once, nothing pending that her login does not pay, no payment lock held, and the
-- officer can take a mission again. tests/race_spec.lua cuts the client actions the same way; this spec cuts what
-- the server does by itself. docs/dev/TESTING.md "Crash matrix".
--   1. A Beat Patrol ends and pays: the last checkpoint, the run's end, its row, the payout (CP.Money, banking).
--   2. Her login pays a pending payment (CP.Cash.payPending after Qbox's player loaded).
-- A journey with more than CP_CRASH_SAMPLE cut points (default 40) is cut at that many spread over it;
-- CP_CRASH_ALL=1 cuts it after every await. Runs on the world of tests/workflows_full_spec.lua (the saves folder, as
-- shipped; in the database suite the same as there).

_G.CP_WF_WORLD = 'crash'
local W = dofile('tests/workflows_full_spec.lua')
_G.CP_WF_WORLD = nil
local H, CID = W.H, W.CID
local Secs, Act = W.Secs, W.Act

local SAMPLE = os.getenv('CP_CRASH_ALL') == '1' and math.huge
    or math.max(2, tonumber(os.getenv('CP_CRASH_SAMPLE') or '') or 40)
local OFFICER = 1
local PATROL_OTHERS = { 'business_check', 'street_race_bust', 'parking_patrol', 'traffic_enforcement' }

local function Later() H.time = H.time + 3700 end
local function Leave(src)
    local run = CP.Runs.getBySrc(src)
    if run then Act('server:abandon', src, run.id) end
end
local function Draw(src)
    Later()
    Leave(src)
    local saved = Config.DisabledMissions
    local list = {}
    for _, id in ipairs(saved or {}) do list[#list + 1] = id end
    for _, id in ipairs(PATROL_OTHERS) do list[#list + 1] = id end
    Config.DisabledMissions = list
    local ok, data = Act('server:acceptType', src, 'patrol')
    Config.DisabledMissions = saved
    return ok, data, CP.Runs.getBySrc(src)
end

-- every Wait(0): with H.interleave(true) each database await of the resource is one
local yields = 0
local function CountingWait()
    local inner = _G.Wait
    _G.Wait = function(ms)
        if ms == 0 then yields = yields + 1 end
        return inner(ms)
    end
    return function() _G.Wait = inner end
end

-- Steps with no game time passing, one await a step, until nothing yields any more: the step after which the last
-- await of the journey ran.
local STEP_MAX = 600
local function StepOut()
    local last, n = 0, 0
    for i = 1, STEP_MAX do
        local before = yields
        H.step(0)
        if yields > before then last = i end
        n = i
        if i - last > 20 then break end
    end
    return last, n
end

-- `restart Crimson-Police` right now: the copy waiting for its query never resumes, what it wrote stays
local function CutRestart()
    H.interleave(false)
    TriggerEvent('onResourceStop', 'Crimson-Police')
    H.restart()
    W.Boot()
    Secs(5)
end

-- The cut points: every step up to SAMPLE of them, else SAMPLE spread from the first to the last.
local function Points(steps)
    local out, seen = {}, {}
    local n = math.min(steps, SAMPLE)
    for i = 1, n do
        local at = steps <= SAMPLE and i or math.max(1, math.floor((i - 1) * (steps - 1) / (n - 1) + 1.5))
        if not seen[at] then
            seen[at] = true
            out[#out + 1] = at
        end
    end
    return out
end

local function Rows(sql, params) return W.Rows(sql, params) end
local function PaidN(cid) return (W.Paid(cid)) end

-- What every cut must leave: rows of the run (at most one), payments to her (at most one), and a state that is either
-- settled or visible to an admin.
local function Recovered(label, cid, rowOf, paid0)
    -- the start-up catch-ups, then her login (payPending) and its delay
    Secs(130)
    W.Drop(OFFICER)
    W.Reconnect(OFFICER)
    Secs(15)
    local rows = rowOf()
    local paid = PaidN(cid) - paid0
    H.ok(#rows <= 1, ('%s: the run ended at most once (%d rows)'):format(label, #rows))
    H.ok(paid <= 1, ('%s: paid at most once (%d payments)'):format(label, paid))
    local row = rows[1]
    if row then
        local st = row.cash_status
        local okState = (st == 'paid' and paid == 1) or (st == 'paying' and paid <= 1) or (st == 'capped' and paid <= 1)
            or (st == 'none' and paid == 0)
        H.ok(okState,
            ('%s: the payment is settled or waits for an admin (status %s, %d paid)'):format(label, tostring(st), paid))
        if CP.Cash and CP.Cash.rowBusy then
            H.eq(CP.Cash.rowBusy(math.floor(tonumber(row.id) or 0), cid), false, label .. ': no payment lock held')
        end
    else
        H.eq(paid, 0, label .. ': no row, nothing paid')
    end
    -- she can take a mission again
    local ok, why = Draw(OFFICER)
    H.eq(ok, true, label .. ': she can take a mission again: ' .. tostring(why))
    Leave(OFFICER)
    Secs(5)
end

local results = {}

-- ============================================================================
--                        1. A BEAT PATROL ENDS AND PAYS
-- ============================================================================
-- Driven to its last checkpoint; the cut comes after the n-th await that the last checkpoint sets off (the run's
-- end, the row, the payout).

local function ToLastCheckpoint()
    local ok, why, run = Draw(OFFICER)
    H.eq(ok, true, 'patrol: she accepts Beat Patrol: ' .. tostring(why))
    if not ok or not run then return nil end
    local veh = W.TakeWheel(OFFICER, run)
    local n = #run.objectives[1].state.points
    W.DriveCheckpoints(OFFICER, run, veh, 1, n - 1)
    Secs(15)
    W.Place(OFFICER, run.objectives[1].state.points[n])
    W.ents[veh].coords = H.players[OFFICER].coords
    Secs(10)
    return run, veh, n
end

do
    local cid = CID[OFFICER]
    -- alone: the journey's awaits
    local run, veh, n = ToLastCheckpoint()
    local steps = 0
    if run then
        local paid0 = PaidN(cid)
        H.interleave(true)
        yields = 0
        local undo = CountingWait()
        W.Objective(OFFICER, run, 1, W.CheckpointEv(n, veh))
        steps = StepOut()
        undo()
        H.interleave(false)
        Secs(10)
        local rows = Rows('run_uuid = ?', { run.id })
        H.eq(#rows, 1, 'patrol alone: the run ended with its row')
        H.eq(rows[1] and rows[1].cash_status, 'paid', 'patrol alone: paid')
        H.eq(PaidN(cid) - paid0, 1, 'patrol alone: once')
        H.ok(steps > 3, ('patrol alone: the end runs through the database (%d awaits)'):format(steps))
        Leave(OFFICER)
    end
    local cuts = 0
    for _, at in ipairs(Points(steps)) do
        local r, v, k = ToLastCheckpoint()
        if not r then break end
        local paid0 = PaidN(cid)
        local uuid = r.id
        H.interleave(true)
        W.Objective(OFFICER, r, 1, W.CheckpointEv(k, v))
        for _ = 2, at do H.step(0) end
        CutRestart()
        Recovered(('patrol cut after await %d of %d'):format(at, steps), cid, function()
            return Rows('run_uuid = ?', { uuid })
        end, paid0)
        cuts = cuts + 1
    end
    results[#results + 1] = ('a Beat Patrol ends and pays: %d awaits, %d cuts'):format(steps, cuts)
end

-- ============================================================================
--                     2. HER LOGIN PAYS A PENDING PAYMENT
-- ============================================================================
-- A pending payment row (Qbox refused it earlier); she logs in; the cut comes after the n-th await of the pay.

local function PendingRow(cid)
    local owed = 240
    local uuid = ('%08x-0000-4000-8000-%012x'):format(math.random(0, 0x7fffffff), 77)
    local bd = {
        missionLabel = 'Beat Patrol',
        cash = { B = owed, mTier = 1.0, mMod = 1.0, amount = owed, status = 'pending' },
    }
    H.sql([[INSERT INTO cp_mission_runs (run_uuid, mission_type, mission_id, citizenid, department, state, end_reason,
        points_base, final_points, cash_base, cash_multiplier, cash_paid, cash_reclaimed, cash_status, breakdown,
        flagged, voided, created_at) VALUES (?, 'patrol', 'beat_patrol', ?, 'sast', 'completed', 'completed', 60, 60, ?,
        1.00, 0, 0, 'pending', ?, 0, 0, FROM_UNIXTIME(?))]],
        { uuid, cid, owed, require('cjson').encode(bd), H.time - 60 })
    return uuid
end

-- Her login (Qbox's player loaded); the pay waits PENDING_DELAY_MS (5 s) first: game time goes on in 100 ms steps
-- until its first await, so the awaits after it are stepped one at a time.
local function Login()
    W.Reconnect(OFFICER)
    local before = yields
    for _ = 1, 100 do
        H.step(100)
        if yields > before then return true end
    end
    return false
end

do
    local cid = CID[OFFICER]
    W.Drop(OFFICER)
    local uuid = PendingRow(cid)
    local paid0 = PaidN(cid)
    H.interleave(true)
    yields = 0
    local undo = CountingWait()
    local started = Login()
    local steps = started and (StepOut() + 1) or 0
    undo()
    H.interleave(false)
    Secs(5)
    local row = Rows('run_uuid = ?', { uuid })[1]
    H.eq(row and row.cash_status, 'paid', 'login alone: her pending payment is paid')
    H.eq(PaidN(cid) - paid0, 1, 'login alone: once')
    H.ok(steps > 3, ('login alone: the pay runs through the database (%d awaits)'):format(steps))
    local cuts = 0
    for _, at in ipairs(Points(steps)) do
        Later()
        W.Drop(OFFICER)
        local u = PendingRow(cid)
        local p0 = PaidN(cid)
        H.interleave(true)
        local undoC = CountingWait()
        Login()
        undoC()
        for _ = 2, at do H.step(0) end
        CutRestart()
        Recovered(('login pay cut after await %d of %d'):format(at, steps), cid, function()
            return Rows('run_uuid = ?', { u })
        end, p0)
        cuts = cuts + 1
    end
    results[#results + 1] = ('her login pays a pending payment: %d awaits, %d cuts'):format(steps, cuts)
end

for _, line in ipairs(results) do print('REPORT crash ' .. line) end

return H

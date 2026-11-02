-- Step F1: real-suspect data survives a restart. A closed case (its suspects, officers, timeline and damage ledger)

local H = dofile('tests/harness.lua')

local RUN1, RUN2, RUN3 = 'f1-run-0001', 'f1-run-0002', 'f1-run-0003'

local function Boot()
    H.boot({ side = 'server', realLocale = true })
    Config.Debug = false
    _G.GetConvar = function(_, default) return default end
    _G.PerformHttpRequest = function() end
    Config.LiveCrime.enabled = true
    CP.Runs = {
        dispatch = function() return true end,
    }
    CP.AntiCheat = {
        note = function() return true end,
        flag = function() return true end,
    }
    H.load('modules/opponents/server.lua')
    H.load('modules/opponents/saved/server.lua')
    H.load('modules/opponents/staff/server.lua')
    H.step(0)
    H.advance(100)   -- the start reads the saved cases in its thread
    return CP.Opponents
end

local function Restart()
    H.advance(1000)  -- the writes in their threads finish first
    H.restart()
    return Boot()
end

local function NewRun(id)
    return {
        id = id,
        missionId = 'live_crime',
        seed = 3,
        state = 'in_progress',
        order = { 1 },
        participants = {
            [1] = { src = 1, citizenid = 'OFF00001', name = 'Ada Test', callsign = '1-A-1', status = 'active' },
        },
    }
end

local function Saved() return H.sql('SELECT run_uuid FROM cp_pvp_cases ORDER BY run_uuid') end

H.boot({ side = 'server' })
H.sql('DELETE FROM cp_pvp_cases')
H.sql('DELETE FROM cp_pvp_pairs WHERE kind IN (\'vol_strike\', \'vol_block\')')
H.restart()

-- ============================================================================
--                1. A CLOSED CASE IS READ BACK AFTER A RESTART
-- ============================================================================

local Opp = Boot()
do
    H.eq(Config.RealSuspects.saveCases, true, 'saveCases ships true')
    local run = NewRun(RUN1)
    local case = Opp.open(run, { kind = 'live', members = { 'CRIM0001' } })
    local rec = case.suspects.CRIM0001
    rec.name, rec.lastCoords = 'Bo Test', vec3(1.0, 2.0, 3.0)
    Opp.timeline(run, { what = 'cuff_attempt', label = rec.label, by = 1 })
    case.ledger[#case.ledger + 1] = {
        t = os.time(),
        dir = 'officer',
        from = 1,
        to = 2,
        label = rec.label,
        weapon = 453432689,
        n = 2,
        state = 'free',
        rules = { 'rs_unarmed_shot' },
    }
    local form = Opp.savedForm(case)
    H.eq(form.suspects.CRIM0001.lastCoords, nil, 'no position is saved')
    Opp.close(run)
    H.advance(100)
    H.eq(#Saved(), 1, 'the closed case is saved once')
end

Opp = Restart()
do
    local view = Opp.staffCase(RUN1)
    H.ok(view ~= nil and view.open == false, 'after a restart staff still read the closed case')
    H.eq(view and view.suspects[1].citizenid, 'CRIM0001', 'its suspect')
    H.eq(view and view.suspects[1].name, 'Bo Test', 'by name')
    H.eq(view and view.officers[1].name, 'Ada Test', 'its officers by name')
    H.eq(view and view.ledger[1].officer and view.ledger[1].officer.citizenid, 'OFF00001',
        'the damage ledger names the officer')
    local cuff = nil
    for _, l in ipairs(view and view.lines or {}) do
        if l.what == 'cuff_attempt' then cuff = l end
    end
    H.ok(cuff ~= nil and cuff.by and cuff.by.citizenid == 'OFF00001', 'the timeline line keeps who did it')
    H.eq(Opp.wasSuspect('CRIM0001', RUN1), true, 'and he still counts as its suspect')
    H.eq(#Opp.staffCases(), 1, 'the case list has it')
end

-- ============================================================================
--          2. casesKept STILL HOLDS; saveCases = false SAVES NOTHING
-- ============================================================================

do
    Config.RealSuspects.casesKept = 1
    local run = NewRun(RUN2)
    Opp.open(run, { kind = 'live', members = { 'CRIM0002' } })
    Opp.close(run)
    H.advance(100)
    local rows = Saved()
    H.ok(#rows == 1 and rows[1].run_uuid == RUN2, 'casesKept = 1: only the newest saved case is kept')
    Config.RealSuspects.casesKept = 16
    Config.RealSuspects.saveCases = false
    run = NewRun(RUN3)
    Opp.open(run, { kind = 'live', members = { 'CRIM0003' } })
    Opp.close(run)
    H.advance(100)
    H.eq(#Saved(), 1, 'saveCases = false: the case stays in memory only')
    H.ok(Opp.staffCase(RUN3) ~= nil, 'staff still read it until a restart')
end

-- ============================================================================
--              3. VOLUNTEER STRIKES AND BLOCKS SURVIVE A RESTART
-- ============================================================================

local function BootVolunteers()
    H.boot({ side = 'server', realLocale = true })
    Config.Debug = false
    _G.GetConvar = function(_, default) return default end
    Config.Volunteers.enabled = true
    CP.Qbx = {
        getInfo = function(src)
            return { citizenid = 'VOL0000' .. src, license = 'license:v' .. src, name = 'Vol ' .. src, job = {} }
        end,
    }
    H.load('modules/volunteers/server.lua')
    H.step(0)
    H.advance(100)
    return CP.Volunteers
end

H.advance(1000)
H.restart()
local V = BootVolunteers()
do
    H.eq(Config.Volunteers.saveStrikes, true, 'saveStrikes ships true')
    V.strike('VOL00001', 'no_show')
    V.strike('VOL00002', 'no_show')
    V.strike('VOL00002', 'no_show')
    V.strike('VOL00002', 'walked_away')
    H.advance(1000)
    H.restart()
    V = BootVolunteers()
    H.eq(V.strikes('VOL00001'), 1, 'a strike is read back after a restart')
    local ok, why = V.check(2)
    H.ok(ok == false and why == 'blocked', 'a strikes block holds after a restart')
    H.eq(V.strikes('VOL00002'), 0, 'the strikes that led to the block are gone')

    -- F2: staff clear a player's strikes and strike block; the saved rows go too, so a restart keeps them cleared
    local okC, res = V.clearStrikes('VOL00002')
    H.ok(okC == true and res.blockedUntil ~= nil, 'clearStrikes lifts the strikes block')
    H.eq((V.check(2)), true, 'he can volunteer again at once')
    okC, res = V.clearStrikes('VOL00001')
    H.ok(okC == true and res.strikes == 1, 'clearStrikes clears a strike')
    H.eq(V.strikes('VOL00001'), 0, 'his strikes read 0')
    local none, why2 = V.clearStrikes('VOL00009')
    H.ok(none == false and why2 == 'no_row', 'nothing to clear is refused')
    H.advance(1000)
    H.restart()
    V = BootVolunteers()
    H.eq((V.check(2)), true, 'the cleared block does not come back after a restart')
    H.eq(V.strikes('VOL00001'), 0, 'nor the cleared strike')
end

H.sql('DELETE FROM cp_pvp_cases')
H.sql('DELETE FROM cp_pvp_pairs WHERE kind IN (\'vol_strike\', \'vol_block\')')

return H

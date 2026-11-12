-- The live claim and the case: the live_crime engine mission in its own registry
-- (CP.Missions.registerEngine), CP.LiveCrime.missionFor / claimCheck, the run:created hook that opens the
-- CP.Opponents case, the run:ended hook that writes the pair rows, and CP.Runs.create opts.live. Plain Lua with stubs.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end

-- ============================================================================
--                                    STUBS
-- ============================================================================

local opp = {}            -- what the stub CP.Opponents answers and records
local function ResetOpp()
    opp = {
        inCase = {},          -- [cid] = true: a suspect of another case
        dayCount = {},        -- [cid] = cases today in which he scored
        suspended = {},       -- [officer cid] = true
        lastSuspect = {},     -- [officer cid] = os.time()
        selfBlocked = {},     -- [officer src] = true
        selfFlags = {},       -- [officer src] = { flags, match }
        pair = {},            -- [officer|suspect] = reason
        opened = nil,
        openFails = false,
        armed = {},
        rows = nil,
        pairFlags = 0,
        closeOutcomes = {},
        closeCase = nil,
    }
end
ResetOpp()
CP.Opponents = {
    byCid = function(cid) if opp.inCase[cid] then return {}, {} end return nil end,
    suspectDayCount = function(cid) return opp.dayCount[cid] or 0 end,
    suspended = function(cid) return opp.suspended[cid] == true end,
    lastSuspectAt = function(cid) return opp.lastSuspect[cid] end,
    selfBlock = function(src)
        if opp.selfBlocked[src] then return true, 'own_license', {}, { cid = 'A' } end
        local f = opp.selfFlags[src]
        if f then return false, nil, f.flags, f.match end
        return false, nil, {}
    end,
    pairOk = function(officer, suspect)
        local why = opp.pair[officer .. '|' .. suspect]
        if why then return false, why end
        return true
    end,
    open = function(run, spec)
        if opp.openFails then return nil end
        local case = { runId = run.id, suspects = {}, order = {} }
        for cid in pairs(spec.members) do
            case.suspects[cid] = { cid = cid, label = cid == 'A' and 'A' or 'B', share = 1 }
            case.order[#case.order + 1] = cid
        end
        table.sort(case.order)
        opp.opened = { run = run, spec = spec, case = case }
        opp.closeCase = case
        return case
    end,
    noteArmed = function(cid) opp.armed[#opp.armed + 1] = cid return true end,
    timeline = function() return true end,
    close = function() return opp.closeOutcomes, opp.closeCase end,
    recordPairs = function(_, rows) opp.rows = rows return #rows end,
    checkPairFlags = function() opp.pairFlags = opp.pairFlags + 1 return {} end,
}
local flags = {}
CP.AntiCheat = {
    flag = function(run, src, reason, detail)
        flags[#flags + 1] = { run = run.id, src = src, reason = reason, detail = detail }
        return true
    end,
}
local ended = {}
CP.Runs = {
    get = function() return nil end,
    endRun = function(run, state, reason)
        -- as Runs.endRun: any state but completed or failed is stored failed
        if state ~= 'completed' and state ~= 'failed' then state = 'failed' end
        ended[#ended + 1] = { run = run.id, state = state, reason = reason }
        run.state = 'ended'
    end,
    cancelRun = function(run, reason)
        ended[#ended + 1] = { run = run.id, state = 'abandoned', reason = reason or 'cancelled' }
        run.state = 'ended'
        return true
    end,
}

H.load('blocks/live_response/server.lua')
H.load('modules/missions/missions.lua')
H.load('modules/realplayers/livecrime.lua')
local LC = CP.LiveCrime
local M = CP.Missions

local function Crime()
    return {
        crimeKey = 'crimson-contracts:7_1',
        key = 'drug_lab_raid',
        label = 'Drug Lab Raid',
        locationLabel = 'Grapeseed',
        title = 'Shots at the lab',
        street = 'Seaview Rd',
        dispatchId = 'crimson_contract_7_1',
        coords = vec3(2400.0, 4900.0, 40.0),
        members = { A = true, B = true, C = true },
        suspects = { A = true, B = true },
        armed = { B = 100 },
        missionType = 'tactical',
    }
end
local OFFICERS = { { src = 1, citizenid = 'OF1' }, { src = 2, citizenid = 'OF2' } }

-- ============================================================================
--                              THE SHIPPED CONFIG
-- ============================================================================

do
    local lc = Config.RealPlayers.liveCrime
    H.eq(lc.enabled, false, 'live crimes ship off: nobody can claim a LIVE call')
    H.eq(lc.caseTime, 1800, 'caseTime ships 30 minutes')
    H.eq(lc.readyCheck, false, 'readyCheck ships false: a live case opens at once')
    H.eq(lc.typeCooldown, false, 'typeCooldown ships false: live cases ignore type cooldowns')
    H.eq(lc.duringOperation, true, 'duringOperation ships true: the Cross-Department lock leaves LIVE calls')
end

-- ============================================================================
--                    THE ENGINE MISSION IN ITS OWN REGISTRY
-- ============================================================================

do
    local def = LC.engineMission()
    H.ok(def ~= nil and def.id == 'live_crime', 'the live_crime engine mission is registered')
    H.eq(def.engine, true, '...as an engine mission')
    H.eq(def.objectives[1].block, 'live_response', '...with the engine-only live_response block')
    H.eq(M.engine('live_crime'), def, 'Missions.engine answers it')
    H.eq(M.get('live_crime'), nil, 'Missions.get never does (never drawn, listed or edited)')
    local listed = false
    for _, d in ipairs(M.list()) do if d.id == 'live_crime' then listed = true end end
    H.eq(listed, false, 'not in Missions.list')
    H.eq(#M.byType(def.type), 0, 'not in any type\'s pool')
    H.eq(LC.engineMission(), def, 'registered once')

    local crime = Crime()
    local m, index = LC.missionFor(crime)
    H.eq(index, 1, 'a case has one location')
    H.eq(m.type, 'tactical', 'the crime\'s mission type')
    H.eq(m.locations[1].start.coords.x, 2400.0, 'at the crime\'s reported place')
    H.eq(m.locations[1].start.radius, Config.RealPlayers.liveCrime.sceneRadius, 'its start circle is the scene radius')
    H.eq(m.locations[1].label, 'Grapeseed', 'named after the crime\'s place')
    H.eq(m.timeLimit, Config.RealPlayers.liveCrime.caseTime, 'the time limit is caseTime')
    H.eq(m.label, 'Live case: Shots at the lab', 'the label names the alert')
    H.eq(def.locations[1].start.coords.x, 0.0, 'the registered mission is not changed')
    local keep = Config.RealPlayers.liveCrime.caseTime
    Config.RealPlayers.liveCrime.caseTime = 10
    H.eq(LC.missionFor(crime).timeLimit, 60, 'caseTime is kept within 60-3600')
    Config.RealPlayers.liveCrime.caseTime = keep
    crime.missionType = nil
    H.eq(LC.missionFor(crime), nil, 'no mission type: no mission')
end

-- ============================================================================
--                               THE CLAIM CHECKS
-- ============================================================================

do
    local keep = Config.RealPlayers.liveCrime
    Config.RealPlayers.liveCrime = setmetatable({ enabled = false }, { __index = keep })
    local crime = Crime()
    local function Check(officers) return select(2, LC.claimCheck(crime, officers or OFFICERS)) end
    H.eq(Check(), 'err.live_case_off', 'live crimes off')
    Config.RealPlayers.liveCrime.enabled = true
    H.eq(LC.claimCheck(crime, OFFICERS), true, 'on: the unit may take the case')

    crime.ended = true
    H.eq(Check(), 'err.live_case_gone', 'the crime ended')
    crime.ended = nil
    opp.inCase = { A = true, B = true }
    H.eq(Check(), 'err.live_case_gone', 'every suspect is in another case')
    opp.inCase = { A = true }
    H.eq(LC.claimCheck(crime, OFFICERS), true, 'one suspect left is a case')
    opp.inCase = {}
    opp.dayCount = { A = 2, B = 2 }
    H.eq(Check(), 'err.live_case_suspect_used', 'both suspects scored maxCatchesPerSuspectDay times today')
    opp.dayCount = { A = 2 }
    H.eq(LC.claimCheck(crime, OFFICERS), true, 'one is still worth points')
    opp.dayCount = {}

    H.eq(Check({ { src = 1, citizenid = 'C' } }), 'err.live_case_own_suspect', 'a crew member of the crime')
    opp.suspended.OF2 = true
    H.eq(Check(), 'err.live_case_suspended', 'a member suspended from real-suspect cases')
    opp.suspended = {}
    opp.lastSuspect.OF1 = os.time() - 60
    H.eq(Check(), 'err.live_case_recent_suspect', 'a suspect a minute ago (jobHopMinutes)')
    opp.lastSuspect.OF1 = os.time() - 31 * 60
    H.eq(LC.claimCheck(crime, OFFICERS), true, 'longer ago is fine')
    opp.lastSuspect = {}
    opp.inCase.OF1 = true
    H.eq(Check(), 'err.live_case_recent_suspect', '(Z14) a suspect of a case that is still open')
    opp.inCase.OF1 = nil
    opp.selfBlocked[2] = true
    H.eq(Check(), 'err.live_case_own_suspect', 'the self rule (own character, license or linked account)')
    opp.selfBlocked = {}
    opp.pair['OF2|B'] = 'blocked'
    H.eq(Check(), 'err.live_case_pair_blocked', 'an admin pair block')
    opp.pair['OF2|B'] = 'pair_cooldown'
    H.eq(Check(), 'err.live_case_pair_cooldown', 'a scored case of the pair within pairCooldownHours')
    opp.pair['OF2|B'] = 'suspect_cooldown'
    H.eq(Check(), 'err.live_case_pair_cooldown', 'any case of the pair within suspectCooldownMinutes')
    opp.pair = {}

    local live = LC.liveOf(crime)
    H.eq(live.crimeKey, crime.crimeKey, 'run.live names the crime')
    H.eq(live.dispatchId, crime.dispatchId, '...its SC-Dispatch call')
    H.eq(live.suspects, 2, '...the number of suspects')
    H.eq(live.members, nil, 'no crew list in the run')
    Config.RealPlayers.liveCrime = keep
end

-- ============================================================================
--                   THE CASE OPENS (run:created) AND CLOSES
-- ============================================================================

do
    ResetOpp()
    local crime = Crime()
    local realGet = LC.get
    LC.get = function(key) if key == crime.crimeKey then return crime end return realGet(key) end
    local function Run(id)
        return {
            id = id,
            state = 'accepted',
            live = LC.liveOf(crime),
            participants = {
                [1] = { src = 1, citizenid = 'OF1', callsign = '2L-01', arrived = true },
                [2] = { src = 2, citizenid = 'OF2', callsign = '2L-02', arrived = false },
            },
        }
    end
    opp.selfFlags[2] = { flags = { 'rs_linked_accounts' }, match = { cid = 'B', kinds = { 'ip' } } }
    local run = Run('V14-1')
    CP.Hooks.fire('run:created', run)
    H.ok(opp.opened ~= nil and opp.opened.run == run, 'run:created of a live run opens its case')
    H.eq(opp.opened.spec.kind, 'live', 'a live case')
    H.eq(opp.opened.spec.members, crime.suspects, 'for the crime\'s suspects')
    H.eq(opp.opened.spec.scene.x, 2400.0, 'the crime\'s place is the scene')
    H.eq(crime.runId, 'V14-1', 'the crime remembers its run')
    H.eq(table.concat(opp.armed, ','), 'B', 'Crimson-Contracts\' crew shot marks that suspect armed')
    H.eq(#flags, 1, 'a shared connection with a suspect: one flag')
    H.eq(flags[1].src, 2, '...on that officer only')
    H.eq(flags[1].reason, 'rs_linked_accounts', '...rs_linked_accounts')
    H.eq(flags[1].detail, 'suspect B, shared ip', '...naming the suspect\'s label and the kind only')

    opp.closeOutcomes = { A = 'booked', B = 'got_away' }
    CP.Hooks.fire('run:ended', run, 'completed', 'completed')
    H.eq(#opp.rows, 4, 'one pair row per officer and suspect')
    local scored, gone = 0, 0
    for _, r in ipairs(opp.rows) do
        if r.scored then scored = scored + 1 end
        if r.outcome == 'gone' then gone = gone + 1 end
    end
    H.eq(scored, 2, 'scored: the booked suspect, for each officer')
    H.eq(gone, 0, 'an officer reached the scene: no row is gone')
    H.eq(opp.pairFlags, 1, 'then the pair-repeat check')

    -- Z8B: a suspect already at maxCatchesPerSuspectDay in a mixed crew: noted at the open, never a scored pair
    opp.dayCount = { A = 2 }
    local runC = Run('V14-C')
    CP.Hooks.fire('run:created', runC)
    H.ok(runC.liveCapped and runC.liveCapped.A == true and not runC.liveCapped.B, 'Z8B: the capped suspect is noted')
    opp.closeOutcomes = { A = 'booked', B = 'booked' }
    CP.Hooks.fire('run:ended', runC, 'completed', 'completed')
    local scoredA, scoredB = 0, 0
    for _, r in ipairs(opp.rows) do
        if r.scored and r.suspect == 'A' then scoredA = scoredA + 1 end
        if r.scored and r.suspect == 'B' then scoredB = scoredB + 1 end
    end
    H.ok(scoredA == 0 and scoredB == 2, 'Z8B: the capped suspect scores no pair, the other does')
    opp.dayCount = {}

    -- nobody arrived: every row is gone (never counted by the caps)
    local run2 = Run('V14-2')
    run2.participants[1].arrived = false
    CP.Hooks.fire('run:created', run2)
    CP.Hooks.fire('run:ended', run2, 'abandoned', 'quit')
    local allGone = true
    for _, r in ipairs(opp.rows) do if r.outcome ~= 'gone' or r.scored then allGone = false end end
    H.ok(allGone, 'nobody reached the scene: every row is gone and unscored')

    -- a case that cannot open: the run is cancelled (no cooldown, no penalty)
    opp.openFails = true
    local run3 = Run('V14-3')
    CP.Hooks.fire('run:created', run3)
    H.advance(10)
    H.eq(#ended, 1, 'no case: the run ends')
    H.eq(ended[1].reason, 'cancelled', '...as cancelled')
    H.eq(ended[1].state, 'abandoned', '...Z8: stored Abandoned (cancelRun), never Failed')

    -- not a live run: nothing
    opp.opened = nil
    CP.Hooks.fire('run:created', { id = 'NPC', participants = {} })
    H.eq(opp.opened, nil, 'an NPC mission opens no case')
    LC.get = realGet
end

-- ============================================================================
--                           CP.Runs.create opts.live
-- ============================================================================

do
    ResetOpp()
    CP.Opponents.open = function()
        return nil
    end -- this part checks the run only
    local runsStub = CP.Runs
    CP.Access = {
        getOfficer = function(src)
            return { src = src, citizenid = 'OF' .. src, name = 'Officer ' .. src, department = 'sast', job = 'police' }
        end,
    }
    H.players[1] = { coords = vec3(0.0, 0.0, 30.0) }
    H.load('modules/runs/runs.lua')
    local caps = 0
    CP.Runs.capsOk = function() caps = caps + 1 return false, 'err.server_busy' end
    local crime = Crime()
    local mission = LC.missionFor(crime)
    local run, err = CP.Runs._create({
        mission = mission,
        locationIndex = 1,
        missionType = 'tactical',
        members = { 1 },
        leaderSrc = 1,
        live = LC.liveOf(crime),
        npcCombat = false,
    })
    H.ok(run ~= nil, 'a live run starts: ' .. tostring(err))
    H.eq(caps, 0, 'the server run caps are never asked for a live case')
    H.eq(run and run.live and run.live.crimeKey, crime.crimeKey, 'run.live is kept')
    H.eq(run and run.realSuspect, 'live', 'a real suspect of kind live')
    H.eq(run and run.npcCombat, false, 'no NPC-combat settings')
    H.eq(run and run.routeRequired, false,
        'Config.RealPlayers.liveCrime.requireRoute = false: officers may leave the route')
    H.eq(run and run.timeLimit, Config.RealPlayers.liveCrime.caseTime, 'the case lasts caseTime')
    H.players[2] = { coords = vec3(0.0, 0.0, 30.0) }
    local plain, perr = CP.Runs._create({
        mission = mission,
        locationIndex = 1,
        missionType = 'tactical',
        members = { 2 },
        leaderSrc = 2,
    })
    H.eq(plain, nil, 'without opts.live the caps apply')
    H.eq(perr, 'err.server_busy', '...as before')
    CP.Runs = runsStub
end

return H

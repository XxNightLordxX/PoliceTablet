-- The officers' tablet for a live case: the LIVE line of the ready check (CP.LiveCrime.readyLine), the

-- The officers' tablet for a live case: the LIVE line of the ready check (CP.LiveCrime.readyLine), the
-- Active Mission case card (CP.LiveCrime.caseView through CP.Runs.view, the live_response block's caseView) and the
-- outcomes on the result card (CP.LiveCrime.resultView in the RunResult). Labels and counts only: never a citizenid,
-- a server id, a position or one suspect's state while the case runs. Plain Lua with stubs.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
Config.Debug = false
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end

-- ============================================================================
--                                    STUBS
-- ============================================================================

local SCENE = vec3(2400.0, 4900.0, 40.0)
local lines = {}          -- CP.Opponents' timeline lines
local tickFns = {}        -- CP.Opponents.onTick hooks
local caseOfRun = {}
local selfFlags = {}      -- [officer src] = { flags, match }
local closes = 0          -- CP.Opponents.close calls
CP.Opponents = {
    eligible = function() return true end,
    sampleCrew = function() return true end,
    unsampleCrew = function() return true end,
    byCid = function() return nil end,
    suspectDayCount = function() return 0 end,
    suspended = function() return false end,
    lastSuspectAt = function() return nil end,
    selfBlock = function(src)
        local f = selfFlags[src]
        if f then return false, nil, f.flags, f.match end
        return false, nil, {}
    end,
    pairOk = function() return true end,
    open = function(run, spec)
        local case = { run = run, runId = run.id, kind = spec.kind, scene = spec.scene, suspects = {}, order = {} }
        local labels = { SUS1 = 'B', SUS2 = 'A' }
        for cid in pairs(spec.members) do
            case.suspects[cid] = { cid = cid, label = labels[cid] or 'C' }
            case.order[#case.order + 1] = cid
        end
        table.sort(case.order)
        caseOfRun[run.id] = case
        return case
    end,
    caseOf = function(run) return run and caseOfRun[run.id] or nil end,
    noteArmed = function() return true end,
    timeline = function(run, entry)
        lines[#lines + 1] = { run = run.id, what = entry.what, src = entry.src, why = entry.why }
        return true
    end,
    onTick = function(fn) tickFns[#tickFns + 1] = fn return true end,
    close = function(run)
        closes = closes + 1
        local case = caseOfRun[run.id]
        if not case then return {}, nil end
        return { SUS1 = 'booked', SUS2 = 'got_away' }, case
    end,
}
local flags = {}
CP.AntiCheat = {
    flag = function(run, src, reason, detail)
        flags[#flags + 1] = { run = run.id, src = src, reason = reason, detail = detail }
        return true
    end,
}
local duty = {}           -- [src] = false: off duty
local cidOf = { [50] = 'SUS1', [51] = 'SUS2' }
CP.Qbx = {
    getInfo = function(src)
        src = tonumber(src)
        if not src or not H.players[src] then return nil end
        return {
            citizenid = cidOf[src] or ('OF' .. src),
            name = 'Officer ' .. src,
            job = { name = 'police', onduty = duty[src] ~= false, gradeName = 'Officer', gradeLevel = 1 },
            metadata = {},
        }
    end,
    getByCitizenId = function(cid)
        for src, c in pairs(cidOf) do if c == cid then return src end end
        return nil
    end,
    getOnlinePlayers = function()
        local out = {}
        for src in pairs(H.players) do out[#out + 1] = src end
        table.sort(out)
        return out
    end,
}
CP.Access = {
    getOfficer = function(src)
        if duty[src] == false then return nil, 'err.not_on_duty' end
        return {
            src = src,
            citizenid = cidOf[src] or ('OF' .. src),
            name = 'Officer ' .. src,
            callsign = '2L-0' .. src,
            department = 'sast',
            departmentShort = 'SAST',
            job = 'police',
        }
    end,
    departmentForJob = function(job) return job == 'police' and 'sast' or nil end,
    maybeOfficer = function() return true end,
}
local responding = nil
CP.Dispatch = {
    normalizeCallId = function(id) return tostring(id) end,
    onResponding = function(fn) responding = fn end,
}

H.load('blocks/live_response/server.lua')
H.load('modules/missions/missions.lua')
H.load('modules/realplayers/livecrime.lua')
H.load('modules/runs/runs.lua')
H.step(0)
local LC, Runs = CP.LiveCrime, CP.Runs

local function Place(src, coords) H.players[src] = { coords = coords or vec3(0.0, 0.0, 30.0) } end

-- the keys of a table, sorted and joined (what a view carries)
local function Keys(t)
    local out = {}
    for k in pairs(t or {}) do out[#out + 1] = tostring(k) end
    table.sort(out)
    return table.concat(out, ',')
end

-- ============================================================================
--                              THE SHIPPED CONFIG
-- ============================================================================

do
    local lc = Config.RealPlayers.liveCrime
    H.eq(lc.enabled, false, 'live crimes ship off: no live case, no card, no LIVE line')
    H.eq(lc.caseCard, true, 'caseCard ships true (behind enabled)')
    H.eq(lc.resultOutcomes, true, 'resultOutcomes ships true (behind enabled)')
    H.eq(LC.caseView({ id = 'npc', state = 'in_progress' }, 1), nil, 'an NPC mission has no case card')
    H.eq(LC.resultView({ id = 'npc', state = 'ended' }), nil, '...and no outcomes on its result card')
end

-- ============================================================================
--                          THE BLOCK'S caseView (V16)
-- ============================================================================

do
    local B = CP.Blocks.get('live_response')
    H.ok(B and type(B.caseView) == 'function', 'live_response gives the officers\' case card its steps')
    local ctx = {
        run = { id = 'none' },
        obj = { block = 'live_response' },
        location = { start = { coords = SCENE } },
        state = {},
        hud = function() end,
        award = function() return true end,
        complete = function() return true end,
        participants = function() return {} end,
        coords = function() return nil end,
    }
    B.prepare(ctx)
    local v = B.caseView(ctx)
    H.eq(v.phase, 'respond', 'phase 1: Respond')
    H.eq(v.reportedAgoS, nil, 'no last-reported points while responding')
    H.eq(v.nextReportS, nil, '...and none coming yet')
    H.eq(v.secureNeed, 60, 'secureSeconds to hold the scene')
    H.eq(v.reportsOn, true, 'lastReportedEvery 60: points come later')
    H.eq(Keys(v), 'phase,reported,reportsOn,secureNeed,secureS', 'only the step and the report times: no suspect')
end

-- ============================================================================
--                   A CRIME, ITS LIVE CALL CLAIMED, THE CASE
-- ============================================================================

local keep = Config.RealPlayers.liveCrime
Config.RealPlayers.liveCrime = setmetatable({ enabled = true }, { __index = keep })

Place(50, vec3(2410.0, 4900.0, 40.0))   -- suspect SUS1, near the crime
Place(51, vec3(2420.0, 4900.0, 40.0))   -- suspect SUS2
Place(1, vec3(0.0, 0.0, 30.0))          -- the officer who claimed the LIVE call (the host)
Place(2, vec3(0.0, 5.0, 30.0))          -- his partner
LC.onStarted('crimson-contracts', {
    id = 9,
    uid = '9_1',
    key = 'drug_lab_raid',
    label = 'Drug Lab Raid',
    locationLabel = 'Grapeseed',
    coords = SCENE,
    members = { SUS1 = true, SUS2 = true },
    startedAt = os.time(),
})
LC.onAlert('crimson-contracts', {
    id = 9,
    uid = '9_1',
    dispatchId = 'crimson_contract_9_1',
    title = 'Shots at the lab',
    street = 'Seaview Rd',
    coords = SCENE,
})
local crime = LC.get('crimson-contracts:9_1')
H.ok(crime ~= nil and crime.suspects.SUS1 and crime.suspects.SUS2, 'the crime has its two suspects')

-- ============================================================================
--                         THE READY CHECK'S LIVE LINE
-- ============================================================================

do
    local line = LC.readyLine({ crimeKey = crime.crimeKey })
    H.eq(line and line.title, 'Shots at the lab', 'the LIVE line names the alert')
    H.eq(line and line.street, 'Seaview Rd', '...the street')
    H.eq(line and line.suspects, 2, '...and the suspect count')
    H.eq(Keys(line), 'street,suspects,title', 'and nothing else (no citizenid, no server id)')
    H.eq(LC.readyLine({ crimeKey = 'crimson-contracts:none' }), nil, 'a crime that is gone: no line')
    Config.RealPlayers.liveCrime.caseCard = false
    H.eq(LC.readyLine({ crimeKey = crime.crimeKey }), nil, 'caseCard = false: the check reads like a mission\'s')
    Config.RealPlayers.liveCrime.caseCard = nil
end

local run, err = Runs._create({
    mission = LC.missionFor(crime),
    locationIndex = 1,
    missionType = 'tactical',
    members = { 1, 2 },
    leaderSrc = 1,
    live = LC.liveOf(crime),
    npcCombat = false,
})
H.ok(run ~= nil, 'the live case runs: ' .. tostring(err))

-- ============================================================================
--                         THE ACTIVE MISSION CASE CARD
-- ============================================================================

do
    local v = Runs.view(run, 1)
    local live = v and v.live
    H.ok(live ~= nil, 'Active Mission gets the case card')
    H.eq(live and live.title, 'Shots at the lab', 'the alert title')
    H.eq(live and live.suspects, 2, 'the suspect count')
    H.eq(live and live.host, true, 'the host: End case is his')
    H.eq(live and live.phase, 'respond', 'before the start: Respond')
    H.eq(Runs.view(run, 2).live.host, false, 'his partner is not the host')

    run.state = 'in_progress'
    run.scaled = run.mission.objectives
    run.objectives[1].prepared = true
    run.objectives[1].status = 'active'
    local ctx = Runs.ctx(run, 1)
    local B = CP.Blocks.get('live_response')
    B.prepare(ctx)
    ctx.state.phase = 'secure'
    ctx.state.secureS = 12.6
    live = Runs.view(run, 2).live
    H.eq(live.phase, 'secure', 'the step the HUD shows')
    H.eq(live.secureS, 12, 'the seconds held at the scene')
    H.eq(live.secureNeed, 60, 'of secureSeconds')
    H.eq(live.reportedAgoS, nil, 'no report yet')

    -- the last report: labels and how long ago, never where
    ctx.state.reported = { { label = 'A', coords = vec3(1.0, 2.0, 3.0) } }
    ctx.state.reportedAt = os.time() - 20
    ctx.state.reportAt = GetGameTimer() + 40000
    live = Runs.view(run, 2).live
    H.eq(table.concat(live.reported, ','), 'A', 'the last-reported points by label')
    H.eq(live.reportedAgoS, 20, 'taken 20 s ago')
    H.eq(live.nextReportS, 40, 'the next one in 40 s')
    H.eq(Keys(live), 'host,nextReportS,phase,reported,reportedAgoS,reportsOn,secureNeed,secureS,street,suspects,title',
        'the card carries no suspect state, citizenid, server id or position')

    -- one suspect's state never changes the card
    local case = caseOfRun[run.id]
    local before = Keys(Runs.view(run, 2).live) .. Runs.view(run, 2).live.phase
    case.suspects.SUS1.state = 'cuffed'
    H.eq(Keys(Runs.view(run, 2).live) .. Runs.view(run, 2).live.phase, before, 'a cuffed suspect: the same card')

    Config.RealPlayers.liveCrime.lastReportedEvery = 0
    H.eq(Runs.view(run, 2).live.reportsOn, false, 'lastReportedEvery = 0: the card says the points are off')
    Config.RealPlayers.liveCrime.lastReportedEvery = nil
    Config.RealPlayers.liveCrime.caseCard = false
    H.eq(Runs.view(run, 2).live, nil, 'caseCard = false: no card')
    Config.RealPlayers.liveCrime.caseCard = nil
end

-- ============================================================================
--                          THE RESULT CARD'S OUTCOMES
-- ============================================================================

local function LastResult(src)
    local last = nil
    for _, e in ipairs(H.events) do
        if e.kind == 'client' and e.name == CP.e('client:runEnded') and e.target == src then last = e end
    end
    return last and last.args[4] or nil
end

do
    -- officer 2 leaves while the case runs: no outcome is his to see yet
    Runs.removeParticipant(run, 2, 'quit')
    local rr = LastResult(2)
    H.ok(rr ~= nil and rr.live ~= nil, 'a live case\'s result card has its live part')
    H.eq(rr and rr.live and rr.live.open, true, 'he left while it ran: open, no outcome')
    H.eq(rr and rr.live and rr.live.outcomes, nil, '...no outcome listed')
    H.eq(closes, 0, 'his leave closes no case')

    -- the case ends: each suspect's outcome by label, sorted
    Runs.endRun(run, 'completed', 'completed')
    rr = LastResult(1)
    local list = rr and rr.live and rr.live.outcomes or {}
    H.eq(#list, 2, 'two suspects on the card')
    H.eq(list[1] and list[1].label, 'A', 'by label, A first')
    H.eq(list[1] and list[1].outcome, 'got_away', 'Suspect A got away')
    H.eq(list[2] and list[2].outcome, 'booked', 'Suspect B was booked')
    H.eq(Keys(list[1]), 'label,outcome', 'a label and an outcome only (no citizenid)')
    H.eq(rr.live.title, 'Shots at the lab', 'the alert title')
end

do
    local ended = { id = run.id, state = 'ended', live = { title = 'T' } }
    Config.RealPlayers.liveCrime.resultOutcomes = false
    local v = LC.resultView(ended)
    H.eq(v and v.outcomes, nil, 'resultOutcomes = false: no outcomes on the result card')
    Config.RealPlayers.liveCrime.resultOutcomes = nil
    caseOfRun[run.id].suspects.SUS2.label = 'A'
    v = LC.resultView(ended)
    H.eq(v and v.outcomes and #v.outcomes, 2, 'the closed case answers again (CP.Opponents keeps it)')
end

Config.RealPlayers.liveCrime = keep
return H

-- Backup joins a live case: CP.LiveCrime.joinCheck / offer / answer, the join pop-up for an officer who
-- responds to the crime's own SC-Dispatch call or reaches the scene, and CP.Runs.addParticipant for a live run that
-- already runs. Plain Lua with stubs.

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
        for cid in pairs(spec.members) do
            case.suspects[cid] = { cid = cid, label = 'A' }
            case.order[#case.order + 1] = cid
        end
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
    close = function() return {}, nil end,
}
local flags = {}
CP.AntiCheat = {
    flag = function(run, src, reason, detail)
        flags[#flags + 1] = { run = run.id, src = src, reason = reason, detail = detail }
        return true
    end,
}
local duty = {}           -- [src] = false: off duty
local cidOf = { [50] = 'SUS1' }
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

local function ClientEvents(name, target)
    local out = {}
    for _, e in ipairs(H.events) do
        if e.kind == 'client' and e.name == CP.e(name) and (target == nil or e.target == target) then
            out[#out + 1] = e
        end
    end
    return out
end
local function LinesOf(what)
    local out = {}
    for _, l in ipairs(lines) do if l.what == what then out[#out + 1] = l end end
    return out
end
local function Place(src, coords) H.players[src] = { coords = coords or vec3(0.0, 0.0, 30.0) } end

-- ============================================================================
--                              THE SHIPPED CONFIG
-- ============================================================================

do
    local lc = Config.RealPlayers.liveCrime
    H.eq(lc.enabled, false, 'live crimes ship off: nobody is ever asked to join')
    H.eq(lc.backup, true, 'backup ships true (behind enabled)')
    H.eq(lc.maxOfficers, 6, 'maxOfficers ships 6')
    H.eq(lc.joinOfferSeconds, 30, 'joinOfferSeconds ships 30')
    H.eq(Config.RealPlayers.outsideCuff, 'assist', 'outsideCuff ships assist')
end

-- ============================================================================
--                   A CRIME, ITS LIVE CALL CLAIMED, THE CASE
-- ============================================================================

local keep = Config.RealPlayers.liveCrime
Config.RealPlayers.liveCrime = setmetatable({ enabled = true }, { __index = keep })

Place(50, vec3(2410.0, 4900.0, 40.0))   -- the suspect, near the crime
Place(1, vec3(0.0, 0.0, 30.0))          -- the officer who claimed the LIVE call
LC.onStarted('crimson-contracts', {
    id = 7,
    uid = '7_1',
    key = 'drug_lab_raid',
    label = 'Drug Lab Raid',
    locationLabel = 'Grapeseed',
    coords = SCENE,
    members = { SUS1 = true },
    startedAt = os.time(),
})
LC.onAlert('crimson-contracts', {
    id = 7,
    uid = '7_1',
    dispatchId = 'crimson_contract_7_1',
    title = 'Shots at the lab',
    street = 'Seaview Rd',
    coords = SCENE,
})
local crime = LC.get('crimson-contracts:7_1')
H.ok(crime ~= nil and crime.suspects and crime.suspects.SUS1, 'the crime has its suspect')
local run, err = Runs._create({
    mission = LC.missionFor(crime),
    locationIndex = 1,
    missionType = 'tactical',
    members = { 1 },
    leaderSrc = 1,
    live = LC.liveOf(crime),
    npcCombat = false,
})
H.ok(run ~= nil, 'the live case runs: ' .. tostring(err))
H.eq(crime.runId, run and run.id, 'the crime knows its run')
H.ok(run.clientStart ~= nil, 'a live run keeps what its clients got at the start')

-- ============================================================================
--                                 LC.joinCheck
-- ============================================================================

do
    Place(3, vec3(0.0, 10.0, 30.0))
    H.eq(LC.joinCheck(run, 3), true, 'an on-duty officer on no mission may join')
    Config.RealPlayers.liveCrime.enabled = false
    H.eq(select(2, LC.joinCheck(run, 3)), 'err.live_join_off', 'live crimes off: nobody joins')
    Config.RealPlayers.liveCrime.enabled = true
    Config.RealPlayers.liveCrime.backup = false
    H.eq(select(2, LC.joinCheck(run, 3)), 'err.live_join_off', 'backup = false: only the claiming unit')
    Config.RealPlayers.liveCrime.backup = nil
    H.eq(select(2, LC.joinCheck(run, 1)), 'err.live_join_already', 'a participant is already on it')
    Config.RealPlayers.liveCrime.maxOfficers = 1
    H.eq(select(2, LC.joinCheck(run, 3)), 'err.live_join_full', 'maxOfficers reached')
    Config.RealPlayers.liveCrime.maxOfficers = nil
    cidOf[3] = 'SUS1'
    H.eq(select(2, LC.joinCheck(run, 3)), 'err.live_case_own_suspect', 'a crew member of the crime')
    cidOf[3] = nil
    H.eq(select(2, LC.joinCheck({ id = 'npc', state = 'in_progress', participants = {} }, 3)), 'err.live_case_gone',
        'an NPC mission takes nobody')
end

-- ============================================================================
--                                  THE POP-UP
-- ============================================================================
-- A RESPONSE TO THE CRIME'S OWN CALL, THE SCENE.

local function OfferTo(src)
    local list = ClientEvents('client:liveJoinOffer', src)
    local e = list[#list]
    return e and e.args[1] or nil, #list
end

do
    H.ok(type(responding) == 'function', 'CP.LiveCrime listens to SC-Dispatch\'s responding toggle')
    responding(3, 'some_other_call', true)
    H.eq(select(2, OfferTo(3)), 0, 'a response to another call: no pop-up')
    responding(3, 'crimson_contract_7_1', false)
    H.eq(select(2, OfferTo(3)), 0, 'un-marking: no pop-up')
    responding(3, 'crimson_contract_7_1', true)
    local offer, n = OfferTo(3)
    H.eq(n, 1, 'responding to the crime\'s own call: the join pop-up')
    H.eq(offer and offer.runId, run.id, '...for its case')
    H.eq(offer and offer.title, 'Shots at the lab', '...with the alert title')
    H.eq(offer and offer.seconds, 30, '...and joinOfferSeconds')
    H.eq(offer and offer.citizenid, nil, 'the pop-up names no suspect')
    H.eq(#LinesOf('join_offered'), 1, 'the case timeline says so')
    responding(3, 'crimson_contract_7_1', true)
    H.eq(select(2, OfferTo(3)), 1, 'one pop-up at a time')

    H.eq((LC.answer(3, run.id, 'not-the-token', true)), false, 'a wrong token joins nobody')
    H.eq(run.participants[3], nil, '...officer 3 is not in the run')
    run.score.shared.live_scene = 1
    H.fire(CP.e('server:liveJoin'), 3, run.id, offer.token, true)
    local p = run.participants[3]
    H.ok(p ~= nil and p.status == 'active', 'yes: officer 3 is on the live case')
    H.eq(Runs.getBySrc(3), run, '...and on no other run')
    H.eq(p and p.joinedLate, true, '...as a late joiner')
    H.eq(p and p.sharedBefore and p.sharedBefore.live_scene, 1, 'the lines before he joined are kept apart')
    H.eq(#ClientEvents('client:start', 3), 1, 'his client gets the start of the run')
    H.eq(#LinesOf('officer_joined'), 1, 'the case timeline names the join')
    H.eq((LC.answer(3, run.id, offer.token, true)), false, 'the same answer twice does nothing')
    H.eq(select(2, Runs.addParticipant(run, 3)), 'err.live_join_already', 'he cannot join twice')
end

do -- the scene: an officer within sceneRadius gets asked once; a no is on the timeline
    H.eq(#tickFns, 1, 'the scene scan runs on CP.Opponents\' watch pass')
    local case = caseOfRun[run.id]
    Place(5, vec3(SCENE.x + 20.0, SCENE.y, SCENE.z))
    Place(6, vec3(SCENE.x + 400.0, SCENE.y, SCENE.z))
    tickFns[1](case)
    local offer, n = OfferTo(5)
    H.eq(n, 1, 'an on-duty officer at the scene: the join pop-up')
    H.eq(select(2, OfferTo(6)), 0, 'an officer 400 m away: none')
    H.eq(select(2, OfferTo(50)), 0, 'the suspect himself: none (he is in the crew)')
    H.fire(CP.e('server:liveJoin'), 5, run.id, offer.token, false)
    H.eq(run.participants[5], nil, 'no: he stays out')
    H.eq(#LinesOf('join_declined'), 1, 'the no is on the case timeline')
    H.advance(6000)
    tickFns[1](case)
    H.eq(select(2, OfferTo(5)), 1, 'the scene asks once per case')
    duty[6] = false
    Place(6, vec3(SCENE.x + 5.0, SCENE.y, SCENE.z))
    H.advance(6000)
    tickFns[1](case)
    H.eq(select(2, OfferTo(6)), 0, 'an officer off duty is never asked')
    duty[6] = nil
end

do -- an answer after the offer ran out joins nobody
    Place(7, vec3(0.0, 20.0, 30.0))
    responding(7, 'crimson_contract_7_1', true)
    local offer = OfferTo(7)
    H.advance(31000)
    H.fire(CP.e('server:liveJoin'), 7, run.id, offer.token, true)
    H.eq(run.participants[7], nil, 'a yes after joinOfferSeconds joins nobody')
end

-- ============================================================================
--             CP.Runs.addParticipant: IN PROGRESS, LEFT, NOT LIVE
-- ============================================================================

do
    run.state = 'in_progress'
    run.scaled = run.mission.objectives
    run.objectives[1].prepared = true
    run.objectives[1].status = 'active'
    run.objectives[1].hud = { detail = 'Secure the scene' }
    Place(8, vec3(0.0, 30.0, 30.0))
    local p = Runs.addParticipant(run, 8, { via = 'scene' })
    H.ok(p ~= nil, 'a run in progress takes a late joiner')
    local hudText = nil
    for _, e in ipairs(ClientEvents('client:hud', 8)) do
        local list = type(e.args[2]) == 'table' and e.args[2].objectives or nil
        if list and list[1] and list[1].current then hudText = list[1].detail end
    end
    H.eq(hudText, 'Secure the scene', 'F3: the late joiner sees the active objective\'s HUD text at once')
    H.eq(#ClientEvents('client:inProgress', 8), 1, 'his client gets the In progress state')
    local starts = 0
    for _, e in ipairs(ClientEvents('client:objective', 8)) do
        if e.args[3] and e.args[3].action == 'start' then starts = starts + 1 end
    end
    H.eq(starts, 1, '...and the active objective')

    Runs.removeParticipant(run, 8, 'quit')
    H.eq(select(2, Runs.addParticipant(run, 8)), 'err.live_join_left', 'a leave is final: no second join')
    -- step Z1: he reconnects with a new server id; the leave is still final for his character
    cidOf[18] = 'OF8'
    Place(18, vec3(0.0, 31.0, 30.0))
    H.eq(select(2, LC.joinCheck(run, 18)), 'err.live_join_left', 'a reconnect after a leave: no join offer')
    H.eq(select(2, Runs.addParticipant(run, 18)), 'err.live_join_left', 'a reconnect after a leave: no second join')
    H.eq(run.participants[18], nil, '...no second entry for his character')
    H.players[18] = nil
    cidOf[18] = nil

    selfFlags[9] = { flags = { 'rs_linked_accounts' }, match = { cid = 'SUS1', kinds = { 'ip' } } }
    Place(9, vec3(0.0, 40.0, 30.0))
    H.ok(Runs.addParticipant(run, 9) ~= nil, 'officer 9 joins')
    H.eq(flags[#flags] and flags[#flags].reason, 'rs_linked_accounts', 'a shared connection with a suspect flags him')
    H.eq(flags[#flags] and flags[#flags].src, 9, '...him only')

    local npc = { id = 'npc-run', state = 'in_progress', participants = {}, order = {}, score = { shared = {} } }
    H.eq(select(2, Runs.addParticipant(npc, 10)), 'err.run_not_active', 'a run CP.Runs does not hold')
end

-- ============================================================================
--                                   STEP F3
-- ============================================================================
-- THE RIDE-ALONG RULE FOR A BACKUP, THE CUFF HINT LINE.

do
    local asked = nil
    CP.FieldTraining = {
        joinCheck = function(cid, unit, missionType)
            asked = { cid = cid, unit = unit, missionType = missionType }
            if cid == 'OF11' then return false, 'err.fto_trainer_needed' end
            return true
        end,
    }
    Place(11, vec3(0.0, 50.0, 30.0))
    H.eq(select(2, Runs.addParticipant(run, 11)), 'err.fto_trainer_needed',
        'F3: a rookie without his trainer on the case cannot join as backup')
    H.eq(run.participants[11], nil, '...he is not in the run')
    H.ok(asked and asked.missionType == 'tactical' and asked.cid == 'OF11', '...asked for the case\'s mission type')
    local inUnit = {}
    for _, c in ipairs(asked and asked.unit or {}) do inUnit[c] = true end
    H.ok(inUnit.OF1 and inUnit.OF3 and not inUnit.OF8, '...with the active officers of the case as his unit')
    -- (Z12) the completion caps a claim is held to (CP.Draw.joinCaps) refuse a backup join too
    local savedDraw, capAsked = CP.Draw, nil
    CP.Draw = setmetatable({
        joinCaps = function(o, missionType, live)
            capAsked = { cid = o.citizenid, missionType = missionType, live = live }
            if o.citizenid == 'OF13' then return false, 'err.hourly_cap' end
            return true
        end,
    }, { __index = savedDraw or {} })
    Place(13, vec3(0.0, 55.0, 30.0))
    H.eq(select(2, Runs.addParticipant(run, 13)), 'err.hourly_cap', '(Z12) a backup at his hourly cap cannot join')
    H.eq(run.participants[13], nil, '(Z12) ...he is not in the run')
    H.ok(capAsked and capAsked.missionType == 'tactical' and capAsked.live == true,
        '(Z12) ...asked for the case\'s mission type, as a live join')
    Place(12, vec3(0.0, 60.0, 30.0))
    H.ok(Runs.addParticipant(run, 12) ~= nil, 'F3: anyone else joins as before')
    CP.FieldTraining = nil
    CP.Draw = savedDraw

    local before = #LinesOf('participant_cuff')
    H.eq(LC.cuffHint(run, 3), true, 'F3: CP.LiveCrime.cuffHint exists for the proof\'s cuff pair')
    H.eq(#LinesOf('participant_cuff'), before + 1, '...a staff line in the case timeline')
    H.eq(LinesOf('participant_cuff')[before + 1].src, 3, '...naming the officer')
    H.eq(LC.cuffHint(run, 3), false, '...at most one per officer every 10 s')
    H.advance(10001)
    H.eq(LC.cuffHint(run, 3), true, '...and again after that')
    H.eq(LC.cuffHint({ id = 'npc', state = 'in_progress' }, 3), false, 'not a live case: no line')
end

Config.RealPlayers.liveCrime = keep
return H

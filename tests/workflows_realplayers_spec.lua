-- WF5D: real players and the criminal tablet, extensively (the owner: "do extensive workflow testing on everything").

-- WF5D: real players and the criminal tablet, extensively (the owner: "do extensive workflow testing on everything").
-- Every workflow and action of a live crime and of a volunteer suspect, driven start to finish on the REAL server side
-- of Crimson-Police: the world of tests/workflows_full_spec.lua (every server file of fxmanifest loaded as in game, the
-- owner's scripts running with sc-police for the cuffs and the jail, database off: the saves folder, as shipped),
-- booted on the shipped config with no section of that spec run (CP_WF_WORLD). Each part runs on the shipped config
-- first, then with the switches on through the Admin UI's own Settings action, with a `restart Crimson-Police` and a
-- player drop and reconnect in the middle, and every refusal a player meets (no permission, wrong department, caps
-- reached, a feature off, the maintenance lock). docs/dev/WORKFLOWS.md lists each workflow with its section here.
--   1. As shipped: a reported crime, the volunteer command, the criminal tablet, /surrender and the staff screen
--      change nothing.
--   2. Live crime: the LIVE call, the claim and its refusals, backup join, detain, book, talk-down, End case, the pay,
--      the staff screen, the fairness rules (no live position, neutralisedShare, pair cooldown).
--   3. Live crime: /surrender, the caps (maxLiveRuns, maxOfficers, backup off), the maintenance lock, a restart and
--      a drop in the middle.
--   4. The criminal tablet: open (and its refusals), opt in, roles, renew, Jobs, consent no and yes, travel, engage,
--      every outcome, Give up free and with a strike, strikes to a block, the block on Restrictions, History, a
--      restart and a drop in the middle.
--   5. The volunteer's pay: a fair case paid once, voidWithRun off (his pay stands) and on (voided and restored).
--   6. police 'none': live crimes and volunteers stay off with a clear line, the criminal tablet says so.

_G.CP_WF_WORLD = 'realplayers'
local W = dofile('tests/workflows_full_spec.lua')
_G.CP_WF_WORLD = nil
local H, CID, PD = W.H, W.CID, W.PD
local Cb, Act, Secs, Place, Setting = W.Cb, W.Act, W.Secs, W.Place, W.Setting
local ClientEvents, LocalEvents, Toasts = W.ClientEvents, W.LocalEvents, W.Toasts

-- Two crew members of a reported crime, two volunteers (civilians).
W.AddPlayer(9, 'WFRPLCR9', 'Cal', 'Crook', 'unemployed', 0)
W.AddPlayer(10, 'WFRPLC10', 'Dee', 'Crook', 'unemployed', 0)
W.AddPlayer(11, 'WFRPLV11', 'Eli', 'Runner', 'unemployed', 0)
W.AddPlayer(12, 'WFRPLV12', 'Gus', 'Driver', 'unemployed', 0)
for _, src in ipairs({ 9, 10, 11, 12 }) do
    CID[src] = PD[src].citizenid
    H.players[src].coords = vec3(0.0, 0.0, 0.0)
    W.Reconnect(src)
end

local function Later() H.time = H.time + 3700 end
local function Open(src, ui) return Cb('getSession', src, { ui = ui or 'officer', via = 'command' }) end

-- Crimson-Contracts' server-only lifecycle events, sent from its own resource.
local function Contracts(name, payload)
    W.SetInvoking('crimson-contracts')
    TriggerEvent('crimson-contracts:server:' .. name, payload)
    W.SetInvoking(nil)
end
-- qbx_core's SetMetaData event for one player (the suspect's cuffs, downs and jail).
local function Meta(src, key, value)
    local old = PD[src].metadata[key]
    PD[src].metadata[key] = value
    TriggerEvent('qbx_core:server:onSetMetaData', key, old, value, src)
end
-- Every vec3 in a value (client event arguments), as 'x,y' strings.
local function Points(v, out, seen)
    out, seen = out or {}, seen or {}
    if type(v) == 'table' then
        if seen[v] then return out end
        seen[v] = true
        if type(v.x) == 'number' and type(v.y) == 'number' then out[#out + 1] = ('%.0f,%.0f'):format(v.x, v.y) end
        for _, x in pairs(v) do Points(x, out, seen) end
    end
    return out
end
-- Whether any client event to an officer of `officers` since mark carries the point c (to the metre).
local function OfficersSaw(c, since, officers)
    local want = ('%.0f,%.0f'):format(c.x, c.y)
    for i = (since or 0) + 1, #H.events do
        local e = H.events[i]
        if e.kind == 'client' and (officers[e.target] or e.target == -1) then
            for _, p in ipairs(Points(e.args)) do if p == want then return true end end
        end
    end
    return false
end

local CRIME_AT = vec3(1200.0, -1300.0, 35.0)    -- the reported place (no no-start zone)
local STATION = vec3(470.63, -974.11, 30.18)    -- Mission Row PD, a booking zone
local OFFICE = vec3(400.0, -980.0, 30.0)        -- where the officers wait
local crimeN = 0
-- Crimson-Contracts reports a crime of these crew members at CRIME_AT -> its uid.
local function Report(members, key)
    crimeN = crimeN + 1
    local n = crimeN
    local list = {}
    for i, src in ipairs(members) do
        list[CID[src]] = src
        Place(src, vec3(CRIME_AT.x + 10.0 * i, CRIME_AT.y, CRIME_AT.z))
    end
    local at = { x = CRIME_AT.x, y = CRIME_AT.y, z = CRIME_AT.z }
    Contracts('contractStarted', {
        id = n,
        uid = n .. '_1',
        key = key or 'warehouse_burglary',
        label = 'Warehouse Burglary',
        locationLabel = 'Elysian Island',
        coords = at,
        members = list,
        leaderCitizenId = CID[members[1]],
        startedAt = os.time(),
    })
    Contracts('dispatchSent', {
        id = n,
        uid = n .. '_1',
        dispatchId = 'cc_' .. n,
        title = 'Burglary in progress',
        street = 'Elysian Fields Fwy',
        coords = at,
    })
    return n .. '_1'
end
-- The LIVE cards src's Dispatch screen shows that he can still claim (a lapsed card stays shown for a while).
local function LiveCards(src)
    local out = {}
    for _, c in ipairs((CP.MissionCalls.list(src) or {}).calls or {}) do
        if c.live and c.status ~= 'lapsed' then out[#out + 1] = c end
    end
    return out
end
-- The unit of leader claims the only LIVE card and holds the scene for secureSeconds -> run, state.
local function ClaimAndSecure(leader, partner, label)
    local card = LiveCards(leader)[1] or {}
    local ok, data = Act('server:answerMissionCall', leader, { callId = card.id })
    H.eq(ok, true, label .. ': the leader claims the LIVE call: ' .. tostring(data))
    local run = CP.Runs.getBySrc(leader)
    H.ok(run ~= nil and run.realSuspect == 'live', label .. ': the case opened as a live run')
    if partner then H.ok(CP.Runs.getBySrc(partner) == run, label .. ': the partner is on the case') end
    Place(leader, vec3(CRIME_AT.x + 5.0, CRIME_AT.y + 3.0, CRIME_AT.z))
    if partner then Place(partner, vec3(CRIME_AT.x + 7.0, CRIME_AT.y + 3.0, CRIME_AT.z)) end
    Secs(75)
    local st = run and CP.Runs.ctx(run, 1).state
    H.eq(st and st.phase, 'detain', label .. ': the scene is secured after secureSeconds on scene')
    return run, st
end
-- sc-police's cuff by an officer within reach, held custodyHoldSeconds.
local function Cuff(officer, suspect)
    local at = H.players[suspect].coords
    Place(officer, vec3(at.x + 1.5, at.y, at.z))
    H.fire('police:server:CuffPlayer', officer, suspect, false)
    Meta(suspect, 'ishandcuffed', true)
    Secs(Config.RealPlayers.custodyHoldSeconds + 3)
end
local function Uncuff(src)
    Meta(src, 'ishandcuffed', false)
    Meta(src, 'injail', 0)
    Meta(src, 'isdead', false)
end
local function Timeline(runId)
    local case = CP.Opponents.findCase(runId)
    local whats = {}
    for _, e in ipairs(case and case.timeline or {}) do whats[e.what] = (whats[e.what] or 0) + 1 end
    return whats, case
end
local function EndCase(leader, run)
    Place(leader, vec3(CRIME_AT.x + 5.0, CRIME_AT.y, CRIME_AT.z))
    W.Objective(leader, run, 1, { type = 'end_case' })
    Secs(3)
end
local function RowsOf(runId)
    return H.sql([[SELECT citizenid, state, end_reason, final_points, cash_paid, live_catches, voided, mission_id
        FROM cp_mission_runs WHERE run_uuid = ? ORDER BY citizenid]], { runId })
end

-- ============================================================================
--                                1. AS SHIPPED
-- ============================================================================
-- LIVE CRIMES, VOLUNTEERS, THE TABLET CHANGE NOTHING.

do
    H.eq(Config.Database.enabled, false, 'shipped: database off (the saves folder)')
    H.eq(Config.Debug, true, 'shipped: Debug on')
    H.eq(Config.RealPlayers.liveCrime.enabled, false, 'shipped: live crimes off')
    H.eq(Config.RealPlayers.volunteer.enabled, false, 'shipped: volunteers off')
    H.eq(Config.RealPlayers.criminalTablet.enabled, false, 'shipped: the criminal tablet off')
    H.eq(Config.FeatureRewards.suspect.enabled, false, 'shipped: volunteer suspects are paid nothing')
    H.eq(Config.FeatureRewards.suspect.voidWithRun, false, 'shipped: voidWithRun off')
    for _, src in ipairs({ 1, 2, 3, 4, 6, 7 }) do
        H.ok(Open(src) ~= nil, ('tablet: %s opens the Officer UI'):format(CID[src]))
    end
    for src = 1, 7 do Place(src, vec3(OFFICE.x + src * 2.0, OFFICE.y, OFFICE.z)) end

    local mark = #H.events
    Report({ 9, 10 })
    H.eq(CP.MissionCalls.liveCount(), 0, 'shipped: a reported crime posts no LIVE call')
    H.eq(#LiveCards(1), 0, 'shipped: Dispatch shows no LIVE card')
    H.eq(#ClientEvents('crimson-police:client:missionCall', nil, mark), 0, 'shipped: no LIVE toast')
    H.eq(CP.LiveCrime.availablePolice(), nil, 'shipped: GetAvailablePolice answers nil')

    mark = #H.events
    H.fire('crimson-police:server:volunteer', 11, 'open')
    H.fire('crimson-police:server:volunteer', 12, 'join', { roles = { runner = true } })
    local notes = ClientEvents('crimson-police:client:volunteerNote', 12, mark)
    H.eq(notes[1] and notes[1].args[2], 'volunteer.refused.off', 'shipped: /crimsonheat is refused (off)')
    notes = ClientEvents('crimson-police:client:volunteerNote', 11, mark)
    H.eq(notes[1] and notes[1].args[2], 'volunteer.refused.off', 'shipped: the menu is refused too')
    H.eq(#CP.Volunteers.list(), 0, 'shipped: nobody is on the volunteer list')

    local view, why = Cb('crimtab:get', 11)
    H.eq(view, nil, 'shipped: the criminal tablet does not open')
    H.eq(why, 'err.crimtab_off', 'shipped: ...and says it is off')
    local ok, err = Act('server:crimtab:act', 11, { what = 'join', roles = { 'runner' } })
    H.eq(err, 'err.crimtab_off', 'shipped: a tablet action is refused (off)')

    local board = Cb('getMissionTypes', 1)
    for _, card in ipairs(board and board.cards or {}) do
        H.eq(card.realSuspect, nil, 'shipped: no Real suspect badge on ' .. tostring(card.key))
    end
    H.eq(CP.Opponents.active(), false, 'shipped: no case is open')

    -- the staff screen: off; its actions refused
    local cases = Cb('admin:getRsCases', 5, {})
    H.eq(cases and cases.enabled, false, 'shipped: the Real suspects screen says both modes are off')
    ok, err = Act('server:admin:rsExclude', 5, { citizenid = CID[9], days = 1, reason = 'WF5D' })
    H.eq(err, 'err.rs_off', 'shipped: Exclude is refused while both modes are off')
end

-- ============================================================================
--                      2. THE ADMIN TURNS EVERY SWITCH ON
-- ============================================================================

do
    local ok, err = Act('server:admin:setSetting', 3,
        { path = 'RealPlayers.liveCrime.enabled', json = 'true', reason = 'not an admin' })
    H.eq(ok, false, 'admin: a supervisor cannot turn live crimes on (' .. tostring(err) .. ')')
    ok, err = Act('server:admin:setSetting', 11,
        { path = 'RealPlayers.criminalTablet.enabled', json = 'true', reason = 'not an admin' })
    H.eq(ok, false, 'admin: a civilian cannot turn the tablet on (' .. tostring(err) .. ')')
    H.eq(Config.RealPlayers.liveCrime.enabled, false, 'admin: ...nothing changed')

    for _, c in ipairs({
        { 'RealPlayers.liveCrime.enabled', true },
        { 'RealPlayers.liveCrime.cash', true },
        { 'RealPlayers.liveCrime.lastReportedEvery', 60 },
        { 'RealPlayers.volunteer.enabled', true },
        {
            'RealPlayers.volunteer.modes',
            { patrol = 'npc', training = 'npc', investigation = 'players_when_available', tactical = 'npc' },
        },
        { 'RealPlayers.criminalTablet.enabled', true },
        { 'FeatureRewards.suspect.enabled', true },
        { 'FeatureRewards.surrender.enabled', true },
    }) do
        ok, err = Setting(c[1], c[2])
        H.eq(ok, true, ('admin: %s saved: %s'):format(c[1], tostring(err)))
    end
    H.eq(Config.RealPlayers.liveCrime.enabled, true, 'admin: live crimes on at once')
    H.eq(Config.RealPlayers.criminalTablet.enabled, true, 'admin: the criminal tablet on at once')
    local cases = Cb('admin:getRsCases', 5, {})
    H.eq(cases and cases.enabled, true, 'admin: the Real suspects screen is on')
    H.eq(cases and cases.liveCrime, true, 'admin: ...live crimes on')
    H.eq(cases and cases.volunteers, true, 'admin: ...volunteers on')
    local _, why = Cb('admin:getRsCases', 3, {})
    H.ok(why ~= nil, 'admin: a supervisor cannot read the Real suspects screen (' .. tostring(why) .. ')')
    _, why = Cb('admin:getRsCases', 1, {})
    H.ok(why ~= nil, 'admin: an officer cannot either (' .. tostring(why) .. ')')
end

-- ============================================================================
--                               3. A LIVE CRIME
-- ============================================================================
-- CALL, CLAIM, BACKUP, DETAIN, BOOK, TALK DOWN, END, PAY.

W.FormUnit(1, 6)
local case1
do
    local OFFICERS = { [1] = true, [6] = true, [7] = true, [2] = true }
    local mark = #H.events
    local uid = Report({ 9, 10 })
    H.eq(CP.MissionCalls.liveCount(), 1, 'live: the reported crime posts one LIVE call')
    local card = LiveCards(1)[1] or {}
    H.eq(card.suspects, 2, 'live: the card counts two suspects')
    H.eq(#ClientEvents('crimson-police:client:missionCall', 1, mark), 1, 'live: the idle leader gets the red toast')
    H.ok(not OfficersSaw(H.players[9].coords, mark, OFFICERS), 'fair: no suspect position reaches the officers')
    H.eq(CP.LiveCrime.availablePolice(), 6, 'live: GetAvailablePolice counts the six idle officers')

    -- refusals of the claim: a civilian, a bad call id, a suspect of the crime
    local ok, err = Act('server:answerMissionCall', 11, { callId = card.id })
    H.eq(ok, false, 'claim: a civilian cannot claim it (' .. tostring(err) .. ')')
    ok, err = Act('server:answerMissionCall', 1, { callId = 'nope' })
    H.eq(ok, false, 'claim: an unknown call is refused (' .. tostring(err) .. ')')
    -- the maintenance lock: no claim until it is over
    CP.Maintenance.begin('restore', { by = 'WF5D' })
    ok, err = Act('server:answerMissionCall', 1, { callId = card.id })
    H.eq(err, 'err.maintenance', 'claim: refused while the maintenance lock holds')
    CP.Maintenance.finish('restore')

    local run, st = ClaimAndSecure(1, 6, 'live')
    case1 = run
    H.eq(CP.MissionCalls.liveCount(), 1, 'live: the claimed call still counts against maxLiveRuns')
    ok, err = Act('server:answerMissionCall', 2, { callId = card.id })
    H.eq(ok, false, 'claim: a second claim of the same call is refused (' .. tostring(err) .. ')')

    -- backup: Dan, on no mission, reaches the scene and gets the join pop-up; No first, then a cuff pop-up again
    mark = #H.events
    Place(7, vec3(CRIME_AT.x - 20.0, CRIME_AT.y, CRIME_AT.z))
    Secs(8)
    local offer = ClientEvents('crimson-police:client:liveJoinOffer', 7, mark)[1]
    H.ok(offer ~= nil, 'join: the backup at the scene gets "Join the live case?"')
    H.eq(offer and #Points(offer.args), 0, 'fair: the pop-up carries no position')
    if offer then H.fire('crimson-police:server:liveJoin', 7, offer.args[1].runId, offer.args[1].token, false) end
    Secs(2)
    H.eq(CP.Runs.getBySrc(7), nil, 'join: No keeps him off the case')
    H.eq(select(2, CP.LiveCrime.offer(run, 7, 'responding')), 'offered', 'join: no second pop-up while one runs')
    Secs(Config.RealPlayers.liveCrime.joinOfferSeconds + 1)
    H.ok(CP.LiveCrime.offer(run, 7, 'responding') == true, 'join: answering the crime\'s dispatch call offers again')
    offer = ClientEvents('crimson-police:client:liveJoinOffer', 7, mark)
    offer = offer[#offer]
    -- a forged token is refused, then his Yes
    H.fire('crimson-police:server:liveJoin', 7, run.id, 'forged', true)
    Secs(1)
    H.eq(CP.Runs.getBySrc(7), nil, 'join: a forged token joins nobody')
    if offer then H.fire('crimson-police:server:liveJoin', 7, offer.args[1].runId, offer.args[1].token, true) end
    Secs(2)
    H.ok(CP.Runs.getBySrc(7) == run, 'join: Yes puts the backup on the case')
    H.eq(select(2, CP.LiveCrime.joinCheck(run, 7)), 'err.live_join_already', 'join: a second join is refused')

    -- A: cuffed by the leader, held: detained; then booked at Mission Row for 10 months
    local case = CP.Opponents.caseOf(run)
    local recA, recB = case.suspects[CID[9]], case.suspects[CID[10]]
    H.ok(recA ~= nil and recB ~= nil, 'live: both crew members are suspects')
    Cuff(1, 9)
    H.eq(recA.state, 'detained', 'detain: A is detained once the cuffs held custodyHoldSeconds')
    H.eq(st.lines.live_detain[CID[9]], 1, 'detain: a full detain line (he was not down)')
    Place(9, vec3(STATION.x + 2.0, STATION.y, STATION.z))
    Place(1, vec3(STATION.x + 3.0, STATION.y, STATION.z))
    Secs(30)
    H.fire('police:server:JailPlayer', 1, 9, 10)
    Meta(9, 'injail', 10)
    Secs(2)
    H.eq(recA.state, 'booked', 'book: A is booked at Mission Row')

    -- B: Dan walks up to him, Talk them down, his Yes; cuffed, held: Peaceful arrest
    Place(10, vec3(CRIME_AT.x + 60.0, CRIME_AT.y, CRIME_AT.z))
    mark = #H.events
    Place(7, vec3(CRIME_AT.x + 52.0, CRIME_AT.y, CRIME_AT.z))
    Secs(6)
    H.ok(Toasts(7, mark)['livecrime.talk.hint'], 'talk: the backup is told he can talk B down')
    mark = #H.events
    H.fire('crimson-police:server:liveTalkDown', 7)
    local ask = ClientEvents('crimson-police:client:liveSurrenderAsk', 10, mark)[1]
    H.ok(ask ~= nil and ask.args[1].talk == true, 'talk: B is asked "An officer is talking you down"')
    if ask then H.fire('crimson-police:server:liveSurrender', 10, ask.args[1].token, true) end
    Secs(1)
    H.ok(type(recB.surrender) == 'table' and recB.surrender.by == 7, 'talk: B surrendered to the backup')
    Cuff(7, 10)
    H.eq(recB.state, 'detained', 'talk: B is detained')
    H.eq(st.lines.peaceful_arrest[CID[10]], 1, 'talk: the Peaceful arrest line counts')

    -- the staff screen while it runs: the case, with names; a supervisor cannot open it
    local cases = Cb('admin:getRsCases', 5, {}) or {}
    local listed
    for _, c in ipairs(cases.cases or {}) do if c.runId == run.id then listed = c end end
    H.ok(listed ~= nil, 'staff: the running case is on the Real suspects screen')
    local view, why = Cb('admin:getRsCase', 5, { runUuid = run.id })
    H.ok(type(view) == 'table', 'staff: the admin opens the case: ' .. tostring(why))
    _, why = Cb('admin:getRsCase', 3, { runUuid = run.id })
    H.ok(why ~= nil, 'staff: a supervisor cannot (' .. tostring(why) .. ')')
    _, why = Cb('admin:getRsCase', 5, { runUuid = 'not a run!' })
    H.eq(why, 'err.invalid_run', 'staff: a bad run id')

    -- End case: only an officer of the case
    W.Objective(2, run, 1, { type = 'end_case' })
    Secs(2)
    H.eq(run.state, 'in_progress', 'end: an officer not on the case cannot end it')
    mark = #H.events
    EndCase(1, run)
    H.eq(run.state, 'ended', 'end: End case ends the case')
    local ended = LocalEvents('crimson-police:server:liveCrimeEnded', mark)[1] or {}
    H.eq(ended.uid, uid, 'end: liveCrimeEnded names the crime')
    H.eq(ended.suspects and ended.suspects[CID[9]], 'booked', 'end: ...A booked')
    H.eq(ended.suspects and ended.suspects[CID[10]], 'detained', 'end: ...B detained')
    H.eq(ended.officers, 3, 'end: ...three officers')
    H.eq(ended.coords, nil, 'fair: ...and no position')
    H.eq(CP.MissionCalls.liveCount(), 0, 'end: the LIVE call is gone')

    -- the rows and the pay: one per officer, completed, cash (liveCrime.cash on), the talk-down reward to Dan
    local rows = RowsOf(run.id)
    H.eq(#rows, 3, 'pay: one run row per officer')
    for _, r in ipairs(rows) do
        H.eq(r.state, 'completed', 'pay: ' .. r.citizenid .. ' completed')
        H.ok((tonumber(r.final_points) or 0) > 0, 'pay: ' .. r.citizenid .. ' earned the live lines')
        H.ok((tonumber(r.cash_paid) or 0) > 0, 'pay: ' .. r.citizenid .. ' is paid cash (liveCrime.cash on)')
    end
    Secs(3)
    local talk = H.sql([[SELECT id FROM cp_mission_runs WHERE citizenid = ? AND mission_id = 'reward_surrender']],
        { CID[7] })
    H.eq(#talk, 1, 'pay: the talk-down pays Dan once')
    talk = H.sql([[SELECT id FROM cp_mission_runs WHERE citizenid = ? AND mission_id = 'reward_surrender']], { CID[1] })
    H.eq(#talk, 0, 'pay: ...and nobody else')
    local whats = Timeline(run.id)
    for _, w in ipairs({ 'responded', 'scene_secured', 'officer_joined', 'join_declined', 'end_case' }) do
        H.ok((whats[w] or 0) > 0, 'staff: the timeline has ' .. w)
    end
    view = Cb('admin:getRsCase', 5, { runUuid = run.id })
    H.ok(type(view) == 'table', 'staff: the closed case still opens')
    for _, src in ipairs({ 9, 10 }) do Uncuff(src) end
end

-- ============================================================================
--     4. THE SAME PAIR AGAIN, A DOWNED SUSPECT, A SECOND REPORT, THE CAPS
-- ============================================================================

do
    -- the same crew, the same unit: the pair cooldown (antiFarm.pairCooldownHours) keeps the second catch unscored
    Later()
    Place(1, OFFICE)
    Place(6, vec3(OFFICE.x + 2.0, OFFICE.y, OFFICE.z))
    Place(7, vec3(OFFICE.x + 4.0, OFFICE.y, OFFICE.z))
    Report({ 9, 10 })
    local card = LiveCards(1)[1] or {}
    local ok, err = Act('server:answerMissionCall', 1, { callId = card.id })
    H.eq(err, 'err.live_case_pair_cooldown', 'fair: the same unit and crew inside pairCooldownHours cannot claim')
    H.eq(CP.Runs.getBySrc(1), nil, 'fair: ...and is on no case')
    Place(2, vec3(OFFICE.x + 6.0, OFFICE.y, OFFICE.z))
    local run, st = ClaimAndSecure(2, nil, 'pair')
    -- A is downed (by anyone) and cuffed: neutralisedShare; the pair played an hour ago, so it scores nothing
    Meta(9, 'isdead', true)
    Secs(1)
    Cuff(2, 9)
    local case = CP.Opponents.caseOf(run)
    local recA = case and case.suspects[CID[9]]
    H.eq(recA and recA.state, 'detained', 'pair: A is detained')
    H.eq(recA and recA.share, Config.RealPlayers.neutralisedShare, 'fair: a downed suspect counts neutralisedShare')
    H.eq(st.lines.live_detain[CID[9]], Config.RealPlayers.neutralisedShare, 'fair: the detain line is weighted')
    -- caps: maxLiveRuns 2 (one case going, one more call fits, a third does not)
    Report({ 11 })
    H.eq(CP.MissionCalls.liveCount(), 2, 'caps: a second crime gets its LIVE call (maxLiveRuns 2)')
    Report({ 12 })
    H.eq(CP.MissionCalls.liveCount(), 2, 'caps: a third crime gets none')
    -- maxOfficers 1: the case is full, the backup is refused the pop-up
    ok, err = Setting('RealPlayers.liveCrime.maxOfficers', 1)
    H.eq(ok, true, 'caps: maxOfficers 1 saved: ' .. tostring(err))
    H.eq(select(2, CP.LiveCrime.joinCheck(run, 7)), 'err.live_join_full', 'caps: the backup is refused (full)')
    Setting('RealPlayers.liveCrime.maxOfficers', 6)
    -- backup off: no pop-up at all
    ok, err = Setting('RealPlayers.liveCrime.backup', false)
    H.eq(ok, true, 'feature: backup off saved: ' .. tostring(err))
    H.eq(select(2, CP.LiveCrime.joinCheck(run, 7)), 'err.live_join_off', 'feature: backup off refuses the join')
    Setting('RealPlayers.liveCrime.backup', true)
    -- a SAST trooper may join the FIB agent's case (live cases are for every department)
    H.eq(select(2, CP.LiveCrime.joinCheck(run, 3)), nil, 'join: an officer of another department may join')
    H.eq(select(2, CP.LiveCrime.joinCheck(run, 7)), 'err.live_case_pair_cooldown',
        'fair: the backup who caught this crew an hour ago may not (pair cooldown)')
    EndCase(2, run)
    H.eq(run.state, 'ended', 'pair: the case ends')
    Uncuff(9)
end

-- ============================================================================
--       5. /SURRENDER, A SUSPECT AND AN OFFICER DROP, A RESTART MID-CASE
-- ============================================================================

do
    -- the two calls left open by the caps check end with their crimes; the admin lifts the repeat limits
    Contracts('contractEnded', { id = 4, uid = '4_1', outcome = 'failed', reason = 'gave up' })
    Contracts('contractEnded', { id = 5, uid = '5_1', outcome = 'failed', reason = 'gave up' })
    Secs(2)
    H.eq(CP.MissionCalls.liveCount(), 0, 'surrender: the crimes that ended took their LIVE calls along')
    for _, c in ipairs({
        { 'RealPlayers.antiFarm.pairCooldownHours', 0 },
        { 'RealPlayers.antiFarm.suspectCooldownMinutes', 0 },
        { 'RealPlayers.antiFarm.maxCatchesPerSuspectDay', 100 },
        { 'RealPlayers.jobHopMinutes', 0 },
        { 'AdminControl.cooldownClearsPerDay', 50 },
    }) do
        local ok, err = Setting(c[1], c[2])
        H.eq(ok, true, ('surrender: %s saved: %s'):format(c[1], tostring(err)))
    end
    Later()
    for _, src in ipairs({ 1, 6 }) do Place(src, vec3(OFFICE.x + src, OFFICE.y, OFFICE.z)) end

    -- /surrender before any case: he is not wanted
    local cmd = H.commands[Config.RealPlayers.surrender.command]
    H.ok(cmd ~= nil, 'surrender: /surrender is registered')
    local mark = #H.events
    if cmd then cmd.fn(10, {}, '') end
    H.ok(Toasts(10, mark)['livecrime.surrender.not_wanted'], 'surrender: before a case he is told he is not wanted')

    Report({ 9, 10 })
    local run, st = ClaimAndSecure(1, 6, 'surrender')
    local case = CP.Opponents.caseOf(run)
    local recA, recB = case.suspects[CID[9]], case.suspects[CID[10]]
    -- B, with the officers close, types /surrender: they are told, he is cuffed: Peaceful arrest
    Place(10, vec3(CRIME_AT.x + 20.0, CRIME_AT.y, CRIME_AT.z))
    mark = #H.events
    if cmd then cmd.fn(10, {}, '') end
    local ask = ClientEvents('crimson-police:client:liveSurrenderAsk', 10, mark)[1]
    H.ok(ask ~= nil and ask.args[1].talk == false, 'surrender: /surrender asks him to confirm')
    if ask then H.fire('crimson-police:server:liveSurrender', 10, 'forged', true) end
    Secs(1)
    H.eq(recB.surrender, nil, 'surrender: a forged answer gives nobody up')
    if ask then H.fire('crimson-police:server:liveSurrender', 10, ask.args[1].token, true) end
    Secs(1)
    H.ok(type(recB.surrender) == 'table', 'surrender: his Yes, with an officer close, gives him up')
    Cuff(6, 10)
    H.eq(recB.state, 'detained', 'surrender: B is detained')
    H.eq(st.lines.peaceful_arrest[CID[10]], 1, 'surrender: the Peaceful arrest line counts')

    -- A quits mid-case and is back within disconnectGrace: still a suspect of the case
    W.Drop(9)
    Secs(30)
    W.Reconnect(9)
    Secs(3)
    H.eq(recA.state ~= 'got_away' and recA.state ~= 'left', true, 'drop: A, back within the grace, is still wanted')
    local _, rec = CP.Opponents.byCid(CID[9])
    H.eq(rec and rec.src, 9, 'drop: the case has him again under his id')

    -- Cleo quits: her own row at once, no cash; the case goes on for Ada, who cuffs A
    W.Drop(6)
    H.eq(CP.Runs.getBySrc(1), run, 'drop: the leader is still on the case')
    local mine = H.sql('SELECT state, cash_paid FROM cp_mission_runs WHERE run_uuid = ? AND citizenid = ?',
        { run.id, CID[6] })
    H.eq(#mine, 1, 'drop: the partner who left has her own row at once')
    H.eq(tonumber(mine[1] and mine[1].cash_paid) or 0, 0, 'drop: ...with no cash')
    Cuff(1, 9)
    H.eq(recA.state, 'detained', 'drop: A, back, is detained by the leader')
    W.Reconnect(6)
    H.eq(CP.Runs.getBySrc(6), nil, 'drop: the partner, back, is on no case')
    H.eq(select(2, CP.LiveCrime.joinCheck(run, 6)), 'err.live_join_left', 'drop: ...and may not join it again')
    EndCase(1, run)
    H.eq(run.state, 'ended', 'drop: the case ends')
    local row = H.sql('SELECT state, cash_paid FROM cp_mission_runs WHERE run_uuid = ? AND citizenid = ?',
        { run.id, CID[1] })[1]
    H.eq(row and row.state, 'completed', 'drop: the leader\'s row is completed')
    for _, src in ipairs({ 9, 10 }) do Uncuff(src) end

    -- a restart mid-case: the case ends with no row, pay or cooldown; no LIVE call left; the closed cases kept
    Later()
    W.FormUnit(1, 6)
    for _, src in ipairs({ 1, 6 }) do Place(src, vec3(OFFICE.x + src, OFFICE.y, OFFICE.z)) end
    Report({ 9, 10 })
    local run2 = ClaimAndSecure(1, 6, 'restart')
    local paidBefore = #W.addMoney
    W.Restart()
    H.eq(Config.RealPlayers.liveCrime.enabled, true, 'restart: live crimes stay on (the saved settings)')
    H.eq(CP.Runs.getBySrc(1), nil, 'restart: the leader is on no case')
    H.eq(CP.Opponents.active(), false, 'restart: no case is open')
    H.eq(#RowsOf(run2.id), 0, 'restart: the case the restart ended wrote no row')
    H.eq(#W.addMoney, paidBefore, 'restart: nothing was paid for it')
    H.eq(CP.MissionCalls.liveCount(), 0, 'restart: no LIVE call is left over')
    local found = false
    for _, c in ipairs((Cb('admin:getRsCases', 5, {}) or {}).cases or {}) do
        if c.runId == case1.id then found = true end
    end
    H.ok(found, 'restart: the first case is still on the staff screen (saveCases)')
    mark = #H.events
    cmd = H.commands[Config.RealPlayers.surrender.command]
    if cmd then cmd.fn(10, {}, '') end
    H.ok(Toasts(10, mark)['livecrime.surrender.not_wanted'], 'restart: /surrender says he is not wanted')
    mark = #H.events
    Contracts('contractEnded', { id = crimeN, uid = crimeN .. '_1', outcome = 'success', reason = 'delivered' })
    Secs(1)
    H.eq(#LocalEvents('crimson-police:server:liveCrimeEnded', mark), 0, 'restart: the old crime\'s end is ignored')
    -- the next crime after the restart: claimed and paid as usual
    W.FormUnit(1, 6)
    Report({ 9, 10 })
    local run3 = ClaimAndSecure(1, 6, 'restart')
    Cuff(1, 9)
    EndCase(1, run3)
    H.eq(run3.state, 'ended', 'restart: the next case ends')
    local rows = RowsOf(run3.id)
    H.eq(#rows, 2, 'restart: one row per officer')
    for _, r in ipairs(rows) do H.eq(r.state, 'completed', 'restart: ' .. r.citizenid .. ' completed') end
    Uncuff(9)
    CP.Units.remove(1, { reason = 'left', silent = true })
    CP.Units.remove(6, { reason = 'left', silent = true })
end

-- ============================================================================
--                            6. THE CRIMINAL TABLET
-- ============================================================================
-- OPEN, OPT IN, ROLES, RENEW, STOP, REFUSALS.

local function Tab(src) return Cb('crimtab:get', src) end
local function TabAct(src, payload) return Act('server:crimtab:act', src, payload) end

do
    -- who opens it: a civilian; never an officer on duty, nor (access 'everyone') a police job off duty
    local view, why = Tab(11)
    H.ok(type(view) == 'table', 'crimtab: a civilian opens the criminal tablet: ' .. tostring(why))
    H.eq(view and view.volunteersOn, true, 'crimtab: ...volunteers are on')
    H.eq(view and view.status.canJoin, true, 'crimtab: ...he may get on the list')
    H.eq(view and view.rules.strikes, 3, 'crimtab: Rules show the three strikes')
    _, why = Tab(1)
    H.eq(why, 'err.crimtab_on_duty', 'crimtab: an officer on duty is refused')
    PD[7].job.onduty = false
    TriggerEvent('QBCore:Server:SetDuty', 7, false)
    _, why = Tab(7)
    H.eq(why, 'err.crimtab_police', 'crimtab: a police job off duty is refused (access everyone)')
    PD[7].job.onduty = true
    TriggerEvent('QBCore:Server:SetDuty', 7, true)
    -- access 'granted': nobody until Permissions -> Extra grants names him
    local ok, err = Setting('RealPlayers.criminalTablet.access', 'granted')
    H.eq(ok, true, 'crimtab: access granted saved: ' .. tostring(err))
    _, why = Tab(11)
    H.eq(why, 'err.crimtab_no_access', 'crimtab: granted and no grant: refused')
    Setting('RealPlayers.criminalTablet.access', 'everyone')
    H.ok(Tab(11) ~= nil, 'crimtab: everyone again: he opens it')
    -- an unknown action, a bad payload
    ok, err = TabAct(11, { what = 'fly' })
    H.eq(err, 'err.invalid_payload', 'crimtab: an unknown action is refused')
    ok, err = TabAct(11, 'join')
    H.eq(err, 'err.invalid_payload', 'crimtab: a bad payload is refused')

    -- opt in: no role refused; runner; twice refused; roles; renew; stop; stop again refused
    ok, err = TabAct(11, { what = 'join', roles = {} })
    H.eq(err, 'volunteer.refused.no_role', 'crimtab: Get on the list with no role ticked is refused')
    ok, view = TabAct(11, { what = 'join', roles = { 'runner' } })
    H.eq(ok, true, 'crimtab: Get on the list: ' .. tostring(view))
    H.eq(view and view.status.listed, true, 'crimtab: Home shows him on the list')
    H.ok(view and view.status.untilAt and view.status.untilAt > os.time(), 'crimtab: ...with its end time')
    ok, err = TabAct(11, { what = 'join', roles = { 'runner' } })
    H.eq(err, 'volunteer.refused.already', 'crimtab: a second Get on the list is refused')
    ok, view = TabAct(11, { what = 'roles', roles = { 'runner', 'driver' } })
    H.eq(ok, true, 'crimtab: the roles are saved: ' .. tostring(view))
    local picked = {}
    for k, v in pairs(view and view.status.roles or {}) do picked[type(k) == 'number' and v or k] = true end
    H.ok(picked.driver and picked.runner, 'crimtab: ...runner and driver ticked')
    local untilAt = view and view.status.untilAt or 0
    H.time = H.time + 600
    ok, view = TabAct(11, { what = 'renew' })
    H.eq(ok, true, 'crimtab: Renew: ' .. tostring(view))
    H.ok(view and view.status.untilAt > untilAt, 'crimtab: ...the window starts again')
    ok, view = TabAct(11, { what = 'stop' })
    H.eq(ok, true, 'crimtab: Stop: ' .. tostring(view))
    H.eq(CP.Volunteers.isListed(CID[11]), false, 'crimtab: ...he is off the list')
    ok, err = TabAct(11, { what = 'stop' })
    H.eq(err, 'volunteer.refused.not_listed', 'crimtab: Stop again is refused')
    ok, err = TabAct(11, { what = 'renew' })
    H.eq(err, 'volunteer.refused.not_listed', 'crimtab: Renew off the list is refused')
    ok, err = TabAct(11, { what = 'cancel' })
    H.eq(err, 'volunteer.refused.no_case', 'crimtab: Give up with no case is refused')
    ok, err = TabAct(11, { what = 'answer', token = 'nope', yes = true })
    H.eq(err, 'err.crimtab_job_gone', 'crimtab: an answer to no question is refused')

    -- the window runs out on its own
    TabAct(11, { what = 'join', roles = { 'runner' } })
    H.time = H.time + Config.RealPlayers.volunteer.windowMinutes * 60 + 5
    Secs(20)
    H.eq(CP.Volunteers.isListed(CID[11]), false, 'crimtab: the window ran out: off the list')

    -- a drop takes him off the list; a restart too (the list is memory only), the strikes stay
    TabAct(11, { what = 'join', roles = { 'runner' } })
    W.Drop(11)
    W.Reconnect(11)
    H.eq(CP.Volunteers.isListed(CID[11]), false, 'drop: a volunteer who quit is off the list')
    TabAct(11, { what = 'join', roles = { 'runner' } })
    W.Restart()
    H.eq(CP.Volunteers.isListed(CID[11]), false, 'restart: the list starts empty')
    H.eq(Config.RealPlayers.criminalTablet.enabled, true, 'restart: the tablet stays on (saved settings)')
    H.ok(Tab(11) ~= nil, 'restart: he opens the tablet again')

    -- the maintenance lock: the tablet still reads, its actions wait for the restart
    CP.Maintenance.begin('restore', { by = 'WF5D' })
    ok, err = TabAct(11, { what = 'join', roles = { 'runner' } })
    H.eq(err, 'err.maintenance', 'maintenance: Get on the list is refused while the lock holds')
    H.ok(Tab(11) ~= nil, 'maintenance: the tablet still opens')
    CP.Maintenance.finish('restore')
end

-- ============================================================================
--                             7. A VOLUNTEER CASE
-- ============================================================================
-- JOBS, CONSENT, TRAVEL, ENGAGE, EVERY OUTCOME, PAY.

local WS = CP.Missions.get('warrant_service')
local WS_AT = vec3(150.0, -1900.0, 21.0)          -- near Grove Street, where the volunteers wait
-- Investigation's pool is Warrant Service alone, at Grove Street; both officers' cooldowns cleared by the admin.
local function VolAccept(label)
    WS = CP.Missions.get('warrant_service')
    WS.locations = { WS.locations[1] }
    for _, src in ipairs({ 1, 6 }) do
        local ok, err = Act('server:admin:clearCooldowns', 5, { citizenid = CID[src], scope = 'all', reason = 'WF5D' })
        H.eq(ok, true, label .. ': the admin clears the cooldowns of ' .. CID[src] .. ': ' .. tostring(err))
    end
    Place(1, OFFICE)
    Place(6, vec3(OFFICE.x + 2.0, OFFICE.y, OFFICE.z))
    Config.DisabledMissions = { 'manhunt', 'suspicious_activity' }
    local mark = #H.events
    local ok, err = Act('server:acceptType', 1, { missionType = 'investigation', realSuspect = true })
    Config.DisabledMissions = {}
    H.eq(ok, true, label .. ': the unit accepts Investigation with Real suspect OK: ' .. tostring(err))
    Secs(3)
    local run = CP.Runs.getBySrc(1)
    H.eq(run and run.missionId, 'warrant_service', label .. ': Warrant Service drawn')
    return run, mark
end
-- The volunteer src asked since mark (his Jobs card) -> job.
local function JobOf(src)
    local view = Tab(src) or {}
    return view.jobs and view.jobs[1], view
end
-- He accepts the job, travels to the meet point, the officers reach the start and then him: engaged -> meet.
local function Engage(src, run, label)
    local job = JobOf(src)
    local ok, err = TabAct(src, { what = 'answer', token = job and job.token, yes = true })
    H.eq(ok, true, label .. ': Accept: ' .. tostring(err))
    Secs(2)
    local view = Tab(src) or {}
    local meet = view.active and view.active.meet
    H.ok(meet ~= nil, label .. ': Active shows his meet point')
    if meet then Place(src, vec3(meet.x + 1.0, meet.y, meet.z)) end
    Secs(6)
    H.eq((CP.Volunteers.matchOf(CID[src]) or {}).phase, 'in_position', label .. ': in position at the meet point')
    local start = run.location.start.coords
    Place(1, start)
    Place(6, vec3(start.x + 2.0, start.y, start.z))
    Secs(3)
    if meet then
        Place(1, vec3(meet.x + 3.0, meet.y, meet.z))
        Place(6, vec3(meet.x + 5.0, meet.y, meet.z))
    end
    Secs(3)
    H.eq((CP.Volunteers.matchOf(CID[src]) or {}).phase, 'engaged', label .. ': officers reached him: engaged')
    return meet
end
-- The run's time limit runs out (Failed): a fair end for the volunteer.
local function RunOut(run, mover)
    local t = 0
    while run.state ~= 'ended' and t < 1200 do
        Secs(10)
        t = t + 10
        -- a suspect who keeps moving (one standing still the whole time counts as AFK)
        if mover then
            local c = H.players[mover].coords
            Place(mover, vec3(c.x + (t % 20 == 0 and 3.0 or -3.0), c.y, c.z))
        end
    end
    Secs(3)
end
local function SuspectPay(cid)
    return H.sql([[SELECT id, voided, cash_base, breakdown FROM cp_mission_runs WHERE citizenid = ?
        AND mission_id = 'reward_suspect' ORDER BY id]], { cid })
end

W.FormUnit(1, 6)
local paidCase
do
    -- both on the list; a mission that plays the NPC (Patrol, mode npc) asks nobody
    Later()
    Place(11, WS_AT)
    Place(12, vec3(WS_AT.x + 4.0, WS_AT.y, WS_AT.z))
    for _, src in ipairs({ 11, 12 }) do
        local ok, err = TabAct(src, { what = 'join', roles = { 'runner' } })
        H.eq(ok, true, ('jobs: %s gets on the list: %s'):format(CID[src], tostring(err)))
    end
    local board = Cb('getMissionTypes', 1) or {}
    local badge
    for _, card in ipairs(board.cards or {}) do if card.key == 'investigation' then badge = card.realSuspect end end
    H.ok(badge ~= nil, 'jobs: the board shows the Real suspect badge on Investigation')

    -- consent: the first asked says No, the next is asked and says Yes
    local run, mark = VolAccept('consent')
    local asked = {}
    for _, src in ipairs({ 11, 12 }) do
        if #ClientEvents('crimson-police:client:volunteerAsk', src, mark) > 0 then asked[#asked + 1] = src end
    end
    H.eq(#asked, 1, 'consent: one volunteer is asked first')
    H.eq(run.realSuspect, nil, 'consent: no real suspect before a yes')
    local first = asked[1] or 11
    local other = first == 11 and 12 or 11
    local job, view = JobOf(first)
    H.ok(job ~= nil, 'consent: his Jobs screen shows the question')
    H.eq(job and #Points(job), 0, 'fair: the job carries no position')
    H.ok(job and type(job.reward) == 'string', 'consent: ...with the reward line (Pay volunteer suspects on)')
    H.eq(#((Tab(other) or {}).jobs or {}), 0, 'consent: the other volunteer has no job yet')
    local ok, err = TabAct(first, { what = 'answer', token = job and job.token, yes = false })
    H.eq(ok, true, 'consent: No: ' .. tostring(err))
    Secs(3)
    H.ok(JobOf(other) ~= nil, 'consent: the next volunteer is asked')
    H.eq(#((Tab(first) or {}).strikes or {}), 0, 'consent: saying No is never a strike')
    -- the next one says Yes: the case is his
    local meet = Engage(other, run, 'consent')
    H.eq(run.realSuspect, 'volunteer', 'consent: his yes makes it a real-suspect case')
    view = Tab(other) or {}
    H.eq(view.active and view.active.freeCancel, false, 'engage: once engaged, Give up is no longer free')
    local OFFICERS = { [1] = true, [6] = true }
    mark = #H.events
    -- he runs, then is cuffed and booked at Mission Row: booked; the officers never get his live position
    Place(other, vec3(meet.x + 60.0, meet.y + 10.0, meet.z))
    Secs(10)
    H.ok(not OfficersSaw(H.players[other].coords, mark, OFFICERS), 'fair: his live position never reaches officers')
    Place(1, vec3(meet.x + 59.0, meet.y + 10.0, meet.z))
    Cuff(1, other)
    local _, rec = CP.Opponents.byCid(CID[other])
    H.eq(rec and rec.state, 'detained', 'outcome: detained once the cuffs held')
    H.eq(rec and rec.share, 1, 'outcome: up and not AFK: a full catch')
    Place(other, vec3(STATION.x + 2.0, STATION.y, STATION.z))
    Place(1, vec3(STATION.x + 3.0, STATION.y, STATION.z))
    Secs(30)
    H.fire('police:server:JailPlayer', 1, other, 10)
    Meta(other, 'injail', 10)
    Secs(2)
    _, rec = CP.Opponents.byCid(CID[other])
    H.eq(rec and rec.state, 'booked', 'outcome: booked at Mission Row')
    ok, err = TabAct(other, { what = 'cancel' })
    H.eq(err, 'volunteer.refused.no_case', 'outcome: once booked there is nothing to give up')
    -- the time limit runs out: Failed for the officers, a fair end for him: paid once ('caught', $500)
    mark = #H.events
    RunOut(run)
    H.eq(run.state, 'ended', 'outcome: the run ends at its time limit')
    local ended = LocalEvents('crimson-police:server:volunteerEnded', mark)[1] or {}
    H.eq(ended.citizenid, CID[other], 'outcome: volunteerEnded names him')
    H.eq(ended.outcome, 'booked', 'outcome: ...booked')
    H.eq(ended.engaged, true, 'outcome: ...officers reached him')
    H.eq(ended.coords, nil, 'fair: ...and no position')
    Secs(3)
    local pay = SuspectPay(CID[other])
    H.eq(#pay, 1, 'pay: one volunteer suspect payment')
    H.eq(tonumber(pay[1] and pay[1].cash_base) or 0, 500, 'pay: ...$500 for playing it to the cuffs')
    H.eq(#SuspectPay(CID[first]), 0, 'pay: the one who said No is paid nothing')
    view = Tab(other) or {}
    H.eq(view.history and view.history[1] and view.history[1].outcome, 'booked', 'history: History shows booked')
    H.eq(view.active, nil, 'history: Active is empty again')
    H.eq(#(view.strikes or {}), 0, 'history: no strike')
    local whats = Timeline(run.id)
    for _, w in ipairs({ 'volunteer_yes', 'in_position', 'engaged' }) do
        H.ok((whats[w] or 0) > 0, 'staff: the case timeline has ' .. w)
    end
    local staff = Cb('admin:getRsCase', 5, { runUuid = run.id })
    H.ok(type(staff) == 'table', 'staff: the admin opens the volunteer case')
    paidCase = { run = run, cid = CID[other], src = other }
    Uncuff(other)
end

-- ============================================================================
--                          8. voidWithRun OFF AND ON
-- ============================================================================
-- THE VOLUNTEER'S PAY AND THE ROWS.

do
    local rows = H.sql('SELECT id, citizenid FROM cp_mission_runs WHERE run_uuid = ? ORDER BY id', { paidCase.run.id })
    H.eq(#rows, 2, 'void: the case has the two officer rows')
    local function Void(id, why)
        return Act('server:admin:voidRun', 5, { rowId = id, reason = why, kind = 'correction' })
    end
    local function Restore(id, why) return Act('server:admin:restoreRun', 5, { rowId = id, reason = why }) end
    local function PayVoided()
        local p = SuspectPay(paidCase.cid)
        local v = p[1] and p[1].voided
        return v == true or tonumber(v) == 1
    end
    -- off (shipped): voiding every officer row leaves his pay as it is
    for _, r in ipairs(rows) do
        local ok, err = Void(r.id, 'Bugged case')
        H.eq(ok, true, 'void: officer row voided: ' .. tostring(err))
    end
    Secs(3)
    H.eq(PayVoided(), false, 'voidWithRun off: his pay stands')
    for _, r in ipairs(rows) do Restore(r.id, 'Case was fine') end
    Secs(3)
    -- on: his pay is voided once every officer row is, and comes back with one of them
    local ok, err = Setting('FeatureRewards.suspect.voidWithRun', true)
    H.eq(ok, true, 'voidWithRun on saved: ' .. tostring(err))
    Void(rows[1].id, 'Bugged case')
    Secs(3)
    H.eq(PayVoided(), false, 'voidWithRun on: one officer row voided: his pay stands')
    Void(rows[2].id, 'Bugged case')
    Secs(3)
    H.eq(PayVoided(), true, 'voidWithRun on: every officer row voided: his pay is voided')
    W.Restart()
    H.eq(PayVoided(), true, 'restart: his pay stays voided')
    Restore(rows[1].id, 'Case was fine')
    Secs(3)
    H.eq(PayVoided(), false, 'voidWithRun on: an officer row restored brings his pay back')
    Restore(rows[2].id, 'Case was fine')
    Setting('FeatureRewards.suspect.voidWithRun', false)
    W.FormUnit(1, 6)
end

-- ============================================================================
--    9. GIVE UP FREE AND WITH A STRIKE, GOT AWAY, STRIKES TO A BLOCK, LIFT
-- ============================================================================

-- He says yes and waits far from the meet point while the officers wait at the start, past the free seconds.
local function YesAndWait(src, run, job)
    Place(src, vec3(WS_AT.x + 600.0, WS_AT.y, WS_AT.z))
    TabAct(src, { what = 'answer', token = job and job.token, yes = true })
    local start = run.location.start.coords
    Place(1, start)
    Place(6, vec3(start.x + 2.0, start.y, start.z))
    Secs(Config.RealPlayers.volunteer.cancelGraceSeconds + 2)
end
-- Only src on the list (the other volunteer stops), a fresh hour; the unit accepts and he is asked -> run, job.
local function Solo(src, label)
    Later()
    for _, v in ipairs({ 11, 12 }) do
        local listed = CP.Volunteers.isListed(CID[v])
        if v ~= src and listed then TabAct(v, { what = 'stop' }) end
        if v == src then TabAct(v, listed and { what = 'renew' } or { what = 'join', roles = { 'runner' } }) end
    end
    Place(src, WS_AT)
    local run = VolAccept(label)
    local job = JobOf(src)
    H.ok(job ~= nil, label .. ': the job reaches his tablet')
    return run, job
end
local function EndRun(run)
    if run and run.state ~= 'ended' then
        for _, src in ipairs({ 1, 6 }) do
            if CP.Runs.getBySrc(src) == run then Act('server:abandon', src, run.id) end
        end
        Secs(3)
    end
end
local function Strikes(src) return #((Tab(src) or {}).strikes or {}) end

do
    local ok, err = Setting('RealPlayers.volunteer.strikes', 2)
    H.eq(ok, true, 'strikes: the admin sets two strikes to a block: ' .. tostring(err))

    -- Give up within cancelGraceSeconds of his yes, before officers reach him: free, "Called off"
    local run, job = Solo(11, 'free')
    TabAct(11, { what = 'answer', token = job and job.token, yes = true })
    Secs(5)
    local view = Tab(11) or {}
    H.eq(view.active and view.active.freeCancel, true, 'free: within the free seconds Give up is free')
    ok, err = TabAct(11, { what = 'cancel' })
    H.eq(ok, true, 'free: Give up: ' .. tostring(err))
    Secs(3)
    H.eq(Strikes(11), 0, 'free: no strike')
    view = Tab(11) or {}
    H.eq(view.active, nil, 'free: Active is empty')
    EndRun(run)
    view = Tab(11) or {}
    H.eq(view.history[1] and view.history[1].outcome, 'void', 'free: History shows the case Called off')
    H.eq(view.history[1] and view.history[1].dropout, nil, 'free: ...not as a dropout')
    H.eq(#SuspectPay(CID[11]), 0, 'free: nothing paid')

    -- got away: he runs off once engaged, the time limit runs out: $1,500
    run = Solo(11, 'away')
    local meet = Engage(11, run, 'away')
    Place(11, vec3(meet.x + 900.0, meet.y, meet.z))
    RunOut(run, 11)
    local pay = SuspectPay(CID[11])
    H.eq(#pay, 1, 'away: one payment')
    H.eq(tonumber(pay[1] and pay[1].cash_base) or 0, 1500, 'away: ...$1,500 for getting away')
    view = Tab(11) or {}
    H.eq(view.history[1] and view.history[1].outcome, 'got_away', 'away: History shows the escape')

    -- Give up past the free seconds: a strike, nothing paid
    run, job = Solo(11, 'strike')
    YesAndWait(11, run, job)
    view = Tab(11) or {}
    H.eq(view.active and view.active.freeCancel, false, 'strike: past the free seconds Give up warns of a strike')
    TabAct(11, { what = 'cancel' })
    Secs(3)
    H.eq(Strikes(11), 1, 'strike: History shows one strike')
    EndRun(run)
    H.eq(#SuspectPay(CID[11]), 1, 'strike: nothing more paid')

    -- the strike outlives a restart (saveStrikes)
    W.Restart()
    H.eq(Strikes(11), 1, 'restart: History still shows his strike (WF5D-1)')
    W.FormUnit(1, 6)

    -- a second strike: blocked for blockHours, off the list, the block on Restrictions
    run, job = Solo(11, 'block')
    YesAndWait(11, run, job)
    TabAct(11, { what = 'cancel' })
    Secs(3)
    EndRun(run)
    H.eq(CP.Volunteers.isListed(CID[11]), false, 'block: the second strike takes him off the list')
    view = Tab(11) or {}
    H.ok((view.status and view.status.blockedUntil or 0) > os.time(), 'block: Home shows when the block ends')
    ok, err = TabAct(11, { what = 'join', roles = { 'runner' } })
    H.eq(err, 'err.crimtab_blocked', 'block: Get on the list is refused')
    local rs = Cb('admin:getRestrictions', 5, {}) or {}
    local row
    for _, r in ipairs(rs.rows or {}) do
        if r.kind == 'volunteerBlock' and r.citizenid == CID[11] then row = r end
    end
    H.ok(row ~= nil, 'block: Restrictions lists his strikes block')
    W.Restart()
    view = Tab(11) or {}
    H.ok((view.status and view.status.blockedUntil or 0) > os.time(), 'restart: the block is kept')
    W.FormUnit(1, 6)
    -- a supervisor cannot lift it; the admin can (Clear strikes)
    ok, err = Act('server:restriction', 3, { op = 'lift', kind = 'volunteerBlock', citizenid = CID[11], reason = 'x' })
    H.eq(ok, false, 'lift: a supervisor cannot lift a strikes block (' .. tostring(err) .. ')')
    ok, err = Act('server:restriction', 5,
        { op = 'extend', kind = 'volunteerBlock', citizenid = CID[11], hours = 24, reason = 'Repeat no-show' })
    H.eq(ok, true, 'extend: the admin extends the block a day: ' .. tostring(err))
    Secs(3)
    ok, err = Act('server:restriction', 5,
        { op = 'lift', kind = 'volunteerBlock', citizenid = CID[11], reason = 'Talked to him' })
    H.eq(ok, true, 'lift: the admin clears his strikes: ' .. tostring(err))
    view = Tab(11) or {}
    H.eq(#(view.strikes or {}), 0, 'lift: no strike left')
    H.eq(view.status and view.status.canJoin, true, 'lift: he may get on the list again')
    Secs(3)
    ok, err = Act('server:restriction', 5,
        { op = 'lift', kind = 'volunteerBlock', citizenid = CID[11], reason = 'Again' })
    H.eq(ok, false, 'lift: nothing left to clear (' .. tostring(err) .. ')')
    Setting('RealPlayers.volunteer.strikes', 3)
end

-- ============================================================================
--          10. A DROP AND A RESTART IN THE MIDDLE OF A VOLUNTEER CASE
-- ============================================================================

do
    -- back within the grace: still his case, no strike
    local run = Solo(11, 'drop')
    local meet = Engage(11, run, 'drop')
    W.Drop(11)
    H.eq(run.state, 'in_progress', 'drop: the case goes on while he is away')
    Secs(30)
    W.Reconnect(11)
    Place(11, vec3(meet.x + 1.0, meet.y, meet.z))
    Secs(3)
    local view = Tab(11) or {}
    H.eq(view.active and view.active.phase, 'engaged', 'drop: back, Active shows the case')
    H.eq(#(view.strikes or {}), 0, 'drop: ...and no strike')
    -- gone past the grace: a strike, History says he left, no pay
    local paid = #SuspectPay(CID[11])
    W.Drop(11)
    Secs(Config.RealPlayers.disconnectGrace + 10)
    W.Reconnect(11)
    Secs(3)
    EndRun(run)
    view = Tab(11) or {}
    H.eq(#(view.strikes or {}), 1, 'drop: past the grace: one strike')
    H.eq(view.history[1] and view.history[1].dropout ~= nil, true, 'drop: History shows he left')
    H.eq(#SuspectPay(CID[11]), paid, 'drop: nothing paid')
    Act('server:restriction', 5, { op = 'lift', kind = 'volunteerBlock', citizenid = CID[11], reason = 'WF5D' })

    -- a restart mid-case: the case ends, no row, no pay, no strike; he may volunteer again
    run = Solo(11, 'restart')
    Engage(11, run, 'restart')
    local runId = run.id
    W.Restart()
    H.eq(CP.Volunteers.matchOf(CID[11]), nil, 'restart: no volunteer case left')
    H.eq(#RowsOf(runId), 0, 'restart: the case wrote no row')
    view = Tab(11) or {}
    H.eq(view.active, nil, 'restart: Active is empty')
    H.eq(#(view.strikes or {}), 0, 'restart: no strike for it')
    H.eq(#SuspectPay(CID[11]), paid, 'restart: nothing paid')
    H.eq(view.status and view.status.canJoin, true, 'restart: he may get on the list again')
end

-- ============================================================================
--                             10B. THE STAFF TOOLS
-- ============================================================================
-- EXCLUDE, SUSPEND, BLOCK A PAIR, ON RESTRICTIONS.

do
    local function Rs(kind, cid)
        for _, r in ipairs((Cb('admin:getRestrictions', 5, {}) or {}).rows or {}) do
            if r.kind == kind and r.citizenid == cid then return r end
        end
        return nil
    end
    -- refusals: a supervisor, a bad citizenid, bad days
    local ok, err = Act('server:admin:rsExclude', 3, { citizenid = CID[12], days = 1, reason = 'WF5D' })
    H.eq(ok, false, 'staff: a supervisor cannot exclude (' .. tostring(err) .. ')')
    ok, err = Act('server:admin:rsExclude', 5, { citizenid = 'bad cid!', days = 1, reason = 'WF5D' })
    H.eq(err, 'err.invalid_citizenid', 'staff: a bad citizenid is refused')
    ok, err = Act('server:admin:rsExclude', 5, { citizenid = CID[12], days = 0, reason = 'WF5D' })
    H.eq(err, 'err.rs_invalid_days', 'staff: zero days is refused')
    -- Exclude a volunteer: refused on the list; Suspend an officer: refused a live case; a pair block
    Secs(11)
    ok, err = Act('server:admin:rsExclude', 5, { citizenid = CID[12], days = 1, reason = 'Farming with a friend' })
    H.eq(ok, true, 'staff: the admin excludes Gus a day: ' .. tostring(err))
    Secs(3)
    ok, err = TabAct(12, { what = 'join', roles = { 'runner' } })
    H.eq(err, 'volunteer.refused.excluded', 'staff: an excluded player cannot get on the list')
    ok, err = Act('server:admin:rsSuspend', 5, { citizenid = CID[7], days = 1, reason = 'Rough arrest' })
    H.eq(ok, true, 'staff: the admin suspends Dan from real-suspect cases: ' .. tostring(err))
    ok, err = Act('server:admin:rsBlockPair', 5, { officer = CID[2], suspect = CID[9], days = 1, reason = 'Friends' })
    H.eq(ok, true, 'staff: the admin blocks the pair Ben / Cal: ' .. tostring(err))
    Later()
    for _, src in ipairs({ 2, 7 }) do Place(src, vec3(OFFICE.x + src, OFFICE.y, OFFICE.z)) end
    Report({ 9, 10 })
    local card = LiveCards(7)[1] or {}
    ok, err = Act('server:answerMissionCall', 7, { callId = card.id })
    H.eq(err, 'err.live_case_suspended', 'staff: the suspended officer cannot claim a LIVE call')
    ok, err = Act('server:answerMissionCall', 2, { callId = card.id })
    H.eq(err, 'err.live_case_pair_blocked', 'staff: the blocked pair cannot meet in a case')
    -- all three on the one Restrictions list; they outlive a restart
    H.ok(Rs('exclusion', CID[12]) ~= nil, 'restrictions: the exclusion is listed')
    H.ok(Rs('rsSuspension', CID[7]) ~= nil, 'restrictions: the suspension is listed')
    H.ok(Rs('pairBlock', CID[2]) ~= nil, 'restrictions: the pair block is listed')
    W.Restart()
    H.ok(Rs('exclusion', CID[12]) ~= nil, 'restart: the exclusion is kept')
    H.ok(Rs('rsSuspension', CID[7]) ~= nil, 'restart: the suspension is kept')
    H.ok(Rs('pairBlock', CID[2]) ~= nil, 'restart: the pair block is kept')
    -- lifted early by the admin, never by a supervisor
    ok, err = Act('server:restriction', 3, { op = 'lift', kind = 'exclusion', citizenid = CID[12], reason = 'x' })
    H.eq(ok, false, 'lift: a supervisor cannot lift an exclusion (' .. tostring(err) .. ')')
    ok, err = Act('server:restriction', 5, { op = 'lift', kind = 'exclusion', citizenid = CID[12], reason = 'OK' })
    H.eq(ok, true, 'lift: the exclusion is lifted: ' .. tostring(err))
    ok, err = Act('server:restriction', 5, { op = 'lift', kind = 'rsSuspension', citizenid = CID[7], reason = 'OK' })
    H.eq(ok, true, 'lift: the suspension is lifted: ' .. tostring(err))
    ok, err = Act('server:restriction', 5,
        { op = 'lift', kind = 'pairBlock', citizenid = CID[2], other = CID[9], reason = 'OK' })
    H.eq(ok, true, 'lift: the pair block is lifted: ' .. tostring(err))
    ok, err = TabAct(12, { what = 'join', roles = { 'runner' } })
    H.eq(ok, true, 'lift: Gus gets on the list again: ' .. tostring(err))
    TabAct(12, { what = 'stop' })
    W.FormUnit(1, 6)
end

-- ============================================================================
--                              11. POLICE 'NONE'
-- ============================================================================
-- LIVE CRIMES AND VOLUNTEERS STAY OFF WITH A CLEAR LINE.

do
    TabAct(11, { what = 'join', roles = { 'runner' } })
    local ok, err = Setting('Integrations.police', 'none')
    H.eq(ok, true, 'none: the admin sets the police script to none: ' .. tostring(err))
    H.eq(CP.Integrations.realSuspectsBlocked(), true, 'none: no cuff and jail facts')
    H.eq(Config.RealPlayers.liveCrime.enabled, true, 'none: the live crimes switch itself stays on')
    -- Settings -> Features: both switches say why they are off
    local view = Cb('admin:getSettings', 5) or {}
    local off = {}
    for _, f in ipairs(view.features or {}) do off[f.key] = f.off end
    for _, key in ipairs({ 'live_crimes', 'volunteers' }) do
        H.ok(type(off[key]) == 'string' and off[key]:find('police script', 1, true) ~= nil,
            ('none: Features says why %s is off: %s'):format(key, tostring(off[key])))
    end
    -- a reported crime posts no LIVE call; /surrender is not wanted
    local mark = #H.events
    Report({ 9, 10 })
    H.eq(CP.MissionCalls.liveCount(), 0, 'none: a reported crime posts no LIVE call')
    H.eq(CP.LiveCrime.availablePolice(), nil, 'none: GetAvailablePolice answers nil (WF5D-3)')
    -- volunteers: the list empties, the command and the tablet's actions are refused, the board has no badge
    Secs(35)
    H.eq(CP.Volunteers.isListed(CID[11]), false, 'none: the volunteer list empties')
    H.fire('crimson-police:server:volunteer', 12, 'join', { roles = { runner = true } })
    local notes = ClientEvents('crimson-police:client:volunteerNote', 12, mark)
    H.eq(notes[#notes] and notes[#notes].args[2], 'volunteer.refused.off', 'none: /crimsonheat is refused (off)')
    local tab, why = Tab(11)
    H.ok(type(tab) == 'table', 'none: the criminal tablet still opens (it needs no police script): ' .. tostring(why))
    H.eq(tab and tab.volunteersOn, false, 'none: ...and says volunteers are off (WF5D-2)')
    ok, err = TabAct(11, { what = 'join', roles = { 'runner' } })
    H.eq(err, 'volunteer.refused.off', 'none: Get on the list is refused (off)')
    local board = Cb('getMissionTypes', 1) or {}
    for _, card in ipairs(board.cards or {}) do
        H.eq(card.realSuspect, nil, 'none: no Real suspect badge on ' .. tostring(card.key))
    end
    local cases = Cb('admin:getRsCases', 5, {}) or {}
    H.eq(cases.enabled, false, 'none: the Real suspects screen says both modes are off')
    -- the owner's script again: everything is back
    ok, err = Setting('Integrations.police', 'sc-police')
    H.eq(ok, true, 'none: back to sc-police: ' .. tostring(err))
    H.eq(CP.Integrations.realSuspectsBlocked(), false, 'none: the cuff and jail facts are back')
    tab = Tab(11) or {}
    H.eq(tab.volunteersOn, true, 'none: the tablet says volunteers are on again')
    ok, err = TabAct(11, { what = 'join', roles = { 'runner' } })
    H.eq(ok, true, 'none: he gets on the list again: ' .. tostring(err))
end

return H

-- Surrender and Talk them down in a live case (modules/realplayers/surrender): the suspect's own command, an

-- Surrender and Talk them down in a live case (modules/realplayers/surrender): the suspect's own command, an
-- officer's Talk them down within talkRange, the suspect's yes or no, the server's distance, case and state checks,
-- the lapse rules, the officers' prompt, Opp.peaceful and the staff timeline lines. All off while
-- Config.RealPlayers.liveCrime.enabled is false.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end

local function Copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = Copy(x) end
    return setmetatable(out, getmetatable(v))
end

-- ============================================================================
--                              qbx_core AND STUBS
-- ============================================================================

local players = {}
H.exportsMock.qbx_core = {
    GetPlayer = function(src) return Copy(players[tonumber(src)]) end,
    GetPlayerByCitizenId = function(cid)
        for _, p in pairs(players) do
            if p.PlayerData.citizenid == cid then return Copy(p) end
        end
        return nil
    end,
    GetQBPlayers = function() return Copy(players) end,
    GetJobs = function() return {} end,
}
local bucket = {}
_G.GetPlayerRoutingBucket = function(src) return bucket[tonumber(src)] or 0 end
_G.GetPlayerCameraRotation = function() return vec3(0.0, 0.0, 0.0) end

local function Load(src, cid, coords, job, onduty)
    H.players[src] = H.players[src] or {}
    H.players[src].coords = coords
    H.players[src].ace = H.players[src].ace or {}
    players[src] = {
        PlayerData = {
            source = src,
            citizenid = cid,
            license = 'license:' .. cid:lower(),
            charinfo = { firstname = 'First' .. src, lastname = 'Last' },
            job = {
                name = job or 'unemployed',
                label = job or 'Civilian',
                onduty = onduty == true,
                grade = { level = 1 },
            },
            metadata = { ishandcuffed = false, isdead = false, inlaststand = false, injail = 0 },
        },
    }
    TriggerEvent('QBCore:Server:PlayerLoaded', Copy(players[src]))
end
local function Move(src, coords) H.players[src].coords = coords end

local notes = {}     -- { src, kind, key, vars }
CP.Tablet = {
    notify = function(src, kind, key, vars)
        notes[#notes + 1] = { src = src, kind = kind, key = key, vars = vars }
        return true
    end,
    notifyMany = function(srcs) return #srcs end,
}
CP.Runs = {
    dispatch = function() return true end,
}
CP.Alerts = {
    foreignFlag = function() return false end,
}
CP.Qbx = {
    onDutyChange = function() end,
    onGroupUpdate = function() end,
    onJobChange = function() end,
    onPlayerLoaded = function() end,
    onPlayerUnload = function() end,
    getOnlinePlayers = function() return {} end,
}
H.load('modules/access/access.lua')
CP.Qbx = nil
H.load('modules/system/integrations/qbx.lua')
H.load('modules/realplayers/opponents.lua')
H.load('modules/realplayers/surrender.lua')
H.step(0)
local Opp = CP.Opponents
local S = Config.RealPlayers.surrender

Load(1, 'OFF00001', vec3(0.0, 0.0, 30.0), 'sast', true)
Load(2, 'OFF00002', vec3(2.0, 0.0, 30.0), 'sast', true)
Load(3, 'OFF00003', vec3(0.0, 2.0, 30.0), 'sast', true)

local runSeq = 0
local function NewRun(officers)
    runSeq = runSeq + 1
    local run = {
        id = ('rp1-%04d'):format(runSeq),
        seed = 7 + runSeq,
        state = 'in_progress',
        order = {},
        participants = {},
    }
    for _, src in ipairs(officers) do
        run.order[#run.order + 1] = src
        run.participants[src] = {
            src = src,
            citizenid = ('OFF%05d'):format(src),
            name = 'Officer ' .. src,
            status = 'active',
        }
    end
    return run
end

local nextSrc = 40
-- A case with one suspect 5 m from officers 1 and 2 (officer 3 is on duty but not in the case).
local function Scene(cid, kind)
    nextSrc = nextSrc + 1
    local src = nextSrc
    H.resetNetLimits()
    Move(1, vec3(0.0, 0.0, 30.0))
    Move(2, vec3(2.0, 0.0, 30.0))
    Move(3, vec3(0.0, 2.0, 30.0))
    Load(src, cid, vec3(5.0, 0.0, 30.0))
    local run = NewRun({ 1, 2 })
    local case = Opp.open(run, { kind = kind or 'live', members = { cid } })
    H.step(0)
    return run, case, case.suspects[cid], src
end

local function Tick(seconds) H.advance((seconds or 1) * 1000, 1000) end

local function Asks(src)
    local out = {}
    for _, e in ipairs(H.events) do
        if e.kind == 'client' and e.name == CP.e('client:liveSurrenderAsk') and e.target == src then
            out[#out + 1] = e.args[1]
        end
    end
    return out
end
local function LastAsk(src) local a = Asks(src) return a[#a] end
local function Lines(case, what)
    local out = {}
    for _, e in ipairs(case.timeline) do if e.what == what then out[#out + 1] = e end end
    return out
end
local function NotesTo(src, key)
    local out = {}
    for _, n in ipairs(notes) do if n.src == src and n.key == key then out[#out + 1] = n end end
    return out
end
local function Answer(src, token, yes) H.fire(CP.e('server:liveSurrender'), src, token, yes) end
local function Talk(src) H.fire(CP.e('server:liveTalkDown'), src) end

-- ============================================================================
--                    SHIPPED: ON, BUT ONLY WITH LIVE CRIMES
-- ============================================================================

do
    H.eq(Config.RealPlayers.liveCrime.enabled, false, 'live crimes ship off')
    H.eq(S.enabled, true, 'surrender ships on (it works only while live crimes are on)')
    H.eq(S.command, 'surrender', 'the command is /surrender')
    H.eq(S.talkRange, 15.0, 'talkRange ships 15 m')
    H.eq(S.surrenderRange, 50.0, 'surrenderRange ships 50 m')
    H.eq(S.askSeconds, 20, 'askSeconds ships 20 s')
    H.eq(S.talkCooldown, 30, 'talkCooldown ships 30 s')
    H.eq(S.holdSeconds, 120, 'holdSeconds ships 120 s')
    H.eq(S.breakRange, 10.0, 'breakRange ships 10 m')
    local b = Config.Bonuses.peaceful_arrest or {}
    H.eq(b.kind, 'pct', 'peaceful_arrest is a share of P')
    H.eq(b.value, 0.15, 'peaceful_arrest ships 15%')
    H.eq(b.each, true, 'once per suspect')
    H.eq(b.engineOnly, true, 'engine-only (never in a mission file or the builder)')
    H.ok(CP.Locale.has('bonus.peaceful_arrest'), 'the line has its label')
    H.eq(H.commands.surrender, nil, 'live crimes off: no /surrender command is registered')

    local run, case, rec, src = Scene('OFFL0001')
    local ok, err = Opp.talkDown(1)
    H.ok(not ok and err == 'livecrime.surrender.off', 'live crimes off: Talk them down does nothing')
    ok, err = Opp.surrenderCommand(src)
    H.ok(not ok and err == 'livecrime.surrender.off', 'live crimes off: the surrender command does nothing')
    Talk(1)
    H.eq(#Asks(src), 0, 'and the suspect is never asked')
    Tick(2)
    H.eq(#NotesTo(1, 'livecrime.talk.hint'), 0, 'and officers get no prompt')
    H.eq(rec.surrender, nil, 'nothing is marked')
    Opp.close(run)
    H.ok(case ~= nil, 'the case itself still opened')
end

Config.RealPlayers.liveCrime.enabled = true
Opp.registerSurrender()
H.ok(H.commands.surrender ~= nil, 'live crimes on: /surrender is registered (the server checks every use)')

-- ============================================================================
--                    TALK THEM DOWN, YES: A PEACEFUL ARREST
-- ============================================================================

do
    local run, case, rec, src = Scene('TALK0001')
    notes = {}
    Tick(1)
    H.eq(#NotesTo(1, 'livecrime.talk.hint'), 1, 'an officer within talkRange gets the Talk them down prompt')
    H.eq(NotesTo(1, 'livecrime.talk.hint')[1].vars.label, rec.label, 'by the suspect\'s label only')
    Tick(3)
    H.eq(#NotesTo(1, 'livecrime.talk.hint'), 1, 'once per officer and suspect')

    Talk(3)
    H.eq(#NotesTo(3, 'livecrime.talk.no_case'), 1, 'an officer outside the case can not talk him down')
    Move(1, vec3(40.0, 40.0, 30.0))
    Talk(1)
    H.eq(#NotesTo(1, 'livecrime.talk.none'), 1, 'beyond talkRange: no suspect to talk down')
    H.eq(#Asks(src), 0, 'and nobody is asked')
    Move(1, vec3(0.0, 0.0, 30.0))
    H.resetNetLimits()
    Talk(1)
    H.eq(#Asks(src), 1, 'within talkRange: the suspect gets the question')
    H.eq(LastAsk(src).talk, true, 'marked as a talk-down')
    H.eq(#NotesTo(1, 'livecrime.talk.asked'), 1, 'the officer is told he asked')
    local talk = Lines(case, 'talk_down')[1]
    H.ok(talk and talk.byWho and talk.byWho.cid == 'OFF00001', 'the timeline names the officer who chose to talk')
    H.resetNetLimits()
    Talk(2)
    H.eq(#NotesTo(2, 'livecrime.talk.busy'), 1, 'one open question at a time')

    Answer(src, 'not-the-token', true)
    H.eq(rec.surrender, nil, 'a wrong token changes nothing')
    Answer(src, LastAsk(src).token, true)
    H.ok(rec.surrender ~= nil and rec.surrender.by == 1, 'yes: he surrendered, talked down by officer 1')
    H.eq(rec.state, 'free', 'a surrender is a mark, never a state: the cuff still decides')
    local line = Lines(case, 'surrendered')[1]
    H.ok(line and line.byWho and line.byWho.cid == 'OFF00001', 'the surrendered line names who talked him down')
    H.eq(#NotesTo(1, 'livecrime.surrender.officers'), 1, 'the case\'s officers are told to cuff him')
    H.eq(#NotesTo(src, 'livecrime.surrender.done'), 1, 'and he is told to stay put')
    H.eq(H.commands.surrender and select(2, Opp.surrenderCommand(src)), 'livecrime.surrender.already',
        'a second surrender is refused')
    H.eq((Opp.peaceful(run, rec.cid)), false, 'not cuffed yet: no peaceful arrest')

    Tick(2)
    Opp.setState(run, rec.cid, 'cuffed', { why = 'test' })
    Tick(2)
    H.eq(rec.surrender.ended, nil, 'cuffed: the surrender holds')
    Opp.setState(run, rec.cid, 'detained', { why = 'test' })
    local ok, by = Opp.peaceful(run, rec.cid)
    H.ok(ok and by == 1, 'cuffed after the surrender with no officer hit: a peaceful arrest by officer 1')
    rec.lastHitAt = GetGameTimer()
    H.eq((Opp.peaceful(run, rec.cid)), false, 'an officer hit after the surrender: no peaceful arrest')
    Opp.close(run)
end

-- ============================================================================
--                     NO, OUT OF RANGE AND THE OWN COMMAND
-- ============================================================================

do
    local run, case, rec, src = Scene('TALK0002')
    Talk(1)
    Answer(src, LastAsk(src).token, false)
    H.eq(rec.surrender, nil, 'no: he did not surrender')
    H.eq(#Lines(case, 'talk_refused'), 1, 'the timeline keeps the no')
    H.eq(#NotesTo(1, 'livecrime.talk.refused'), 1, 'the officer is told')
    H.resetNetLimits()
    Talk(1)
    H.eq(#NotesTo(1, 'livecrime.talk.cooldown'), 1, 'the same officer waits talkCooldown before asking again')

    -- his own command: the question, then the officers must still be within surrenderRange at the yes
    H.commands.surrender.fn(src)
    local q = LastAsk(src)
    H.eq(q.talk, false, '/surrender asks him to confirm (not a talk-down)')
    Move(1, vec3(500.0, 0.0, 30.0))
    Move(2, vec3(500.0, 0.0, 30.0))
    Answer(src, q.token, true)
    H.eq(rec.surrender, nil, 'no officer within surrenderRange: no surrender')
    H.eq(#NotesTo(src, 'livecrime.surrender.no_officer'), 1, 'and he is told why')
    Move(1, vec3(30.0, 0.0, 30.0))
    H.resetNetLimits()
    H.commands.surrender.fn(src)
    Answer(src, LastAsk(src).token, true)
    H.ok(rec.surrender ~= nil and rec.surrender.by == nil, 'an officer within 50 m: his own surrender (nobody talked)')

    -- an expired question
    Opp.close(run)
    run, case, rec, src = Scene('TALK0003')
    H.commands.surrender.fn(src)
    q = LastAsk(src)
    Tick(S.askSeconds + 1)
    Answer(src, q.token, true)
    H.eq(rec.surrender, nil, 'a yes after askSeconds counts for nothing')
    Opp.close(run)

    -- a stranger (no case) and a volunteer case
    Load(60, 'STRA0060', vec3(1.0, 1.0, 30.0))
    local ok, err = Opp.surrenderCommand(60)
    H.ok(not ok and err == 'livecrime.surrender.not_wanted', 'a player in no case has nothing to surrender to')
    run, case, rec, src = Scene('VOLU0001', 'volunteer')
    ok, err = Opp.surrenderCommand(src)
    H.ok(not ok and err == 'livecrime.surrender.not_wanted', 'a volunteer case has no surrender (live cases only)')
    Opp.close(run)
end

-- ============================================================================
--                              THE SURRENDER ENDS
-- ============================================================================

do
    local function Surrendered(cid)
        local run, case, rec, src = Scene(cid)
        H.commands.surrender.fn(src)
        Answer(src, LastAsk(src).token, true)
        H.ok(rec.surrender ~= nil, cid .. ': surrendered')
        return run, case, rec, src
    end

    local run, case, rec, src = Surrendered('ENDS0001')
    Move(src, vec3(5.0 + S.breakRange + 5.0, 0.0, 30.0))
    Tick(2)
    H.eq(rec.surrender.ended, 'moved', 'he moved past breakRange: the surrender ends')
    H.eq(#Lines(case, 'surrender_ended'), 1, 'the timeline keeps it')
    H.eq(#NotesTo(src, 'livecrime.surrender.ended_moved'), 1, 'he is told')
    H.eq((Opp.peaceful(run, rec.cid)), false, 'a later detain is no peaceful arrest')
    Opp.close(run)

    run, case, rec, src = Surrendered('ENDS0002')
    Tick(S.holdSeconds + 2)
    H.eq(rec.surrender.ended, 'lapsed', 'nobody cuffed him within holdSeconds: it lapses')
    Opp.close(run)

    run, case, rec, src = Surrendered('ENDS0003')
    Tick(2)
    rec.armedUntil = GetGameTimer() + Config.RealPlayers.armedMemory * 1000
    Tick(1)
    H.eq(rec.surrender.ended, 'armed', 'a weapon seen after he gave up ends it')
    Opp.close(run)

    run, case, rec, src = Surrendered('ENDS0004')
    Tick(1)
    Opp.setState(run, rec.cid, 'cuffed', { why = 'test' })
    Tick(1)
    Opp.setState(run, rec.cid, 'free', { why = 'test' })
    Tick(1)
    H.eq(rec.surrender.ended, 'released', 'out of the cuffs again: the surrender is over')
    Opp.close(run)
end

-- ============================================================================
--                            STAFF LINES AND LOCALE
-- ============================================================================

do
    for _, what in ipairs({ 'talk_down', 'talk_refused', 'surrendered', 'surrender_ended', 'peaceful_arrest' }) do
        H.ok(CP.Locale.has('opp.line.' .. what), 'staff read the ' .. what .. ' line')
    end
    for _, why in ipairs({ 'released', 'armed', 'moved', 'lapsed' }) do
        H.ok(CP.Locale.has('livecrime.surrender.ended_' .. why), 'the suspect reads why it ended: ' .. why)
    end
end

return H

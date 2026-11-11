-- CP.Volunteers matching (server): a run whose suspect a volunteer may play (run.volunteer, set at the draw) asks
-- the volunteers who fit, one at a time, with a yes/no pop-up; a yes opens his CP.Opponents case (kind 'volunteer'),
-- makes the run a case with a real suspect (run.realSuspect = 'volunteer') and sends him to the slot's meet point.

-- CP.Volunteers matching (server): a run whose suspect a volunteer may play (run.volunteer, set at the draw) asks
-- the volunteers who fit, one at a time, with a yes/no pop-up; a yes opens his CP.Opponents case (kind 'volunteer'),
-- makes the run a case with a real suspect (run.realSuspect = 'volunteer') and sends him to the slot's meet point.
-- The server then follows him: in position, engaged (an officer within Config.RealPlayers.contactRange: the officers
-- lose the NPC-combat protection), a no-show, his own Cancel this case, and the release when the run ends. Nobody who
-- says yes, or a volunteer who drops out, gives the NPC back (players_when_available) or ends the run
-- (Config.RealPlayers.volunteer.onVoid / voidRun; 'players_only' always ends). Blocks read it with ctx.volunteer().
-- A block may also tell the volunteer who plays: V.caseNote (a notification), V.caseArea (his own map circle,
-- client:volunteerArea) and V.outOfBounds (he broke its play-area rule: a void and a strike).
-- Results: the server-only event crimson-police:server:volunteerEnded when a run he said yes to ends
-- (Config.RealPlayers.volunteer.endEvent), and V.staffView / V.staffList for the Real suspects screen.
-- Memory only; nothing runs while Config.RealPlayers.volunteer.enabled is off or every mode is 'npc'.

CP.Volunteers = CP.Volunteers or {}
local V = CP.Volunteers
local TAG = 'volunteers'

local TICK_MS = 2000                                   -- the asking, travel and engagement check, only while a run has a match
local LATE_MS = 2000                                   -- an answer this late after the pop-up closed still counts (lag)
local CANCEL_PHASES = { travel = true, in_position = true, engaged = true }
local STRIKE_WHY = {
    no_show = true,
    cancelled = true,
    left = true,
    afk = true,
    out_of_bounds = true,
    on_duty = true,
    early_respawn = true,
}
-- a dropout whose staff note CP.Opponents already wrote (rs_afk_catch, rs_early_respawn): only the timeline line
local LINE_WHY = { afk = 'volunteer_afk', early_respawn = 'volunteer_early_respawn' }
-- a leave already has CP.Opponents' rs_combat_log note; each other dropout writes rs_volunteer_dropout and this line
local NOTE_WHY = {
    no_show = 'no_show',
    cancelled = 'volunteer_cancel',
    out_of_bounds = 'volunteer_out_of_bounds',
    on_duty = 'volunteer_on_duty',
}
local matches = {}           -- [runId] = match (below)
local byCid = {}             -- [citizenid] = runId while he is asked or plays that run's suspect
local tick = { on = false, token = 0 }
local counter = 0

-- match = { run, runId, mode, role, obj, meet, radius, phase = 'asking'|'travel'|'in_position'|'engaged'|'npc'|
--   'void'|'over', cid, src, token, deadline (ms), asked = { [cid] = true }, tries, yesAt (ms), travelUntil (ms),
--   engagedAt (ms), why, case (his CP.Opponents case, from the yes on) }

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local Num = CP.Num

local function Note(src, kind, key, vars)
    if src then TriggerClientEvent(CP.e('client:volunteerNote'), src, kind, key, vars) end
end

local function Opp(fn, ...)
    local O = CP.Opponents
    if not (O and type(O[fn]) == 'function') then return nil end
    local r = table.pack(pcall(O[fn], ...))
    if not r[1] then
        CP.err(TAG, 'CP.Opponents.%s failed: %s', fn, tostring(r[2]))
        return nil
    end
    return table.unpack(r, 2, r.n)
end

local function ActiveSrcs(run)
    if CP.Runs and CP.Runs.activeSrcs then return CP.Runs.activeSrcs(run) end
    return {}
end

-- A toast on every active officer's tablet.
local function TellOfficers(run, kind, key)
    if not (CP.Tablet and CP.Tablet.notifyMany) then return end
    pcall(CP.Tablet.notifyMany, ActiveSrcs(run), kind, key)
end

local function Coords(src)
    local ped = src and GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

local function Line(m, what, extra)
    local _, rec = Opp('byCid', m.cid)
    local entry = { what = what, label = rec and rec.label or nil, src = m.src }
    if extra then for k, v in pairs(extra) do entry[k] = v end end
    Opp('timeline', m.run, entry)
end

-- The slot's meet point, else the location's start.
local function MeetOf(run, slot)
    local meet = type(slot) == 'table' and slot.meet or nil
    if type(meet) == 'table' or type(meet) == 'vector3' then return meet end
    local start = type(run.location) == 'table' and type(run.location.start) == 'table' and run.location.start or {}
    return start.coords
end

local function Plain(v)
    if v == nil then return nil end
    return { x = tonumber(v.x) or 0.0, y = tonumber(v.y) or 0.0, z = tonumber(v.z) or 0.0 }
end

-- ============================================================================
--                                 THE ENDINGS
-- ============================================================================

local StartTick

local function Forget(m)
    if m.cid and byCid[m.cid] == m.runId then byCid[m.cid] = nil end
    if V.release then V.release(m.runId) end
end

-- The run ends because nobody plays its suspect: Config.RealPlayers.volunteer.voidRun 'keep_earned' = completed with
-- what was earned so far (run.keepEarned: CP.Scoring scores the lines only, no base points or end-of-run lines such as
-- fast_finish, and CP.Cash pays no mission cash); 'cancelled' (shipped) = Abandoned with no cooldown, penalty or pay.
-- keep_earned needs a yes and a run In progress: a run that never started (nobody, or a no before any yes) is always
-- cancelled, so no Completed row, goal, cooldown or item comes of it. In a thread: never from inside a run hook.
local function EndRun(m)
    local run = m.run
    local how = (CP.RealPlayers('volunteer').voidRun == 'keep_earned' and m.yesAt and run.state == 'in_progress')
            and 'keep_earned'
        or 'cancelled'
    TellOfficers(run, 'warning', 'volunteer.officer.void_end')
    CP.log(TAG, 'run %s: no volunteer plays the suspect (%s): the run ends (%s)', m.runId, tostring(m.why), how)
    SetTimeout(0, function()
        if run.state == 'ended' or not CP.Runs then return end
        if how == 'keep_earned' and run.state == 'in_progress' and CP.Runs.endRun then
            run.keepEarned = true
            CP.Runs.endRun(run, 'completed', 'completed')
        elseif CP.Runs.cancelRun then
            CP.Runs.cancelRun(run, 'cancelled')
        end
    end)
end

-- Nobody (else) plays the suspect. players_only always ends the run; players_when_available gives the NPC back, but
-- after a yes only while Config.RealPlayers.volunteer.onVoid is 'npc' (shipped) and no officer engaged him yet (an AFK
-- catch counts as engaged).
local function NoVolunteer(m, afterYes)
    local npc = m.mode ~= 'players_only'
    if afterYes and (CP.RealPlayers('volunteer').onVoid == 'end' or m.engagedAt) then npc = false end
    Forget(m)
    if npc then
        m.phase = 'npc'
        TellOfficers(m.run, 'info', 'volunteer.officer.npc')
        if afterYes then Line(m, 'volunteer_npc') end
        CP.log(TAG, 'run %s: the NPC plays the suspect (%s)', m.runId, tostring(m.why))
        return
    end
    m.phase = 'void'
    EndRun(m)
end

-- The volunteer who said yes drops out (why: no_show, cancelled, left, void, afk: caught while AFK; out_of_bounds:
-- a fugitive who stayed outside the search circle). A no-show, a cancel after cancelGraceSeconds, a leave, an AFK
-- catch and out_of_bounds are strikes. His suspect counts for nobody.
local function Voided(m, why, strike)
    if m.phase == 'void' or m.phase == 'npc' or m.phase == 'over' then return end
    m.why = why
    m.struck = strike == true and STRIKE_WHY[why] == true  -- a free cancel is no strike: History never says so
    local _, rec = Opp('byCid', m.cid)
    if rec and rec.state ~= 'void' and rec.state ~= 'left' then
        Opp('setState', m.run, m.cid, 'void', { why = 'volunteer_' .. why })
    end
    if NOTE_WHY[why] then
        Line(m, NOTE_WHY[why])
        Opp('note', m.run, 'rs_volunteer_dropout', ('%s: %s'):format(rec and rec.label or '?', why), m.cid)
    elseif LINE_WHY[why] then
        Line(m, LINE_WHY[why])
    end
    if strike and STRIKE_WHY[why] and V.strike then V.strike(m.cid, why) end
    Note(m.src, 'warning', 'volunteer.case.' .. why)
    TriggerClientEvent(CP.e('client:volunteerCase'), m.src, { phase = 'over' })
    NoVolunteer(m, true)
end

-- ============================================================================
--                                    ASKING
-- ============================================================================

-- Whether the volunteer cid at src may play this run's suspect now -> ok, reason: still listed and free (V.check),
-- not down, cuffed, jailed or in a no-start zone (CP.Opponents.eligible with intake), and none of the officers is his
-- player (CP.Opponents.selfBlock). May yield (selfBlock reads the database on a cache miss): threads only.
local function Fits(m, cid, src)
    if not V.isListed or not V.isListed(cid) then return false, 'gone' end
    local ok, why = V.check(src)
    if not ok then return false, why end
    local okI, whyI = Opp('eligible', src, { intake = true })
    if okI == false then return false, whyI end
    local okC, whyC = V.capsOk(m.run, cid)
    if not okC then return false, whyC end
    for _, officer in ipairs(ActiveSrcs(m.run)) do
        if Opp('selfBlock', officer, { cid }) == true then return false, 'own_officer' end
    end
    return true
end

-- An officer who shares only a connection or PC with the volunteer (CP.Opponents.selfBlock's flags) gets the
-- officer-conduct flag rs_linked_accounts (his own points wait for review): at the yes, and at a late join. May yield.
local function FlagLinked(m, officer)
    local blocked, _, flags, match = Opp('selfBlock', officer, { m.cid })
    if blocked == true or type(flags) ~= 'table' then return end
    local _, rec = Opp('byCid', m.cid)
    local kinds = type(match) == 'table' and type(match.kinds) == 'table' and match.kinds or {}
    local detail = ('suspect %s, shared %s'):format(rec and rec.label or '?', table.concat(kinds, ', '))
    for _, reason in ipairs(flags) do
        if CP.AntiCheat and CP.AntiCheat.flag then pcall(CP.AntiCheat.flag, m.run, officer, reason, detail) end
    end
end

-- True when the run carries the officer-conduct flag rs_linked_accounts (an officer and the volunteer share a
-- connection or PC): the volunteer's own feature pay is never paid for it.
local function FlaggedWith(run, reason)
    local AC = CP.AntiCheat
    if not (AC and AC.flaggedWith) then return false end
    local ok, v = pcall(AC.flaggedWith, run, reason)
    return ok and v == true
end

local function Linked(run) return FlaggedWith(run, 'rs_linked_accounts') end

local function Candidates(m)
    local out, seen = {}, {}
    local held = V.reservedFor and V.reservedFor(m.runId) or nil
    if held then
        out[1], seen[held] = held, true
    end
    for _, cid in ipairs(V.available and V.available({ [m.role] = true }) or {}) do
        if not seen[cid] then
            out[#out + 1], seen[cid] = cid, true
        end
    end
    return out
end

local function SrcOf(cid)
    for _, v in ipairs(V.list and V.list() or {}) do
        if v.cid == cid then return v.src end
    end
    return nil
end

-- He is no longer this match's volunteer: forgotten only while byCid still names this run (another match may hold him).
local function Free(m, cid)
    if cid and byCid[cid] == m.runId then byCid[cid] = nil end
end

-- The next volunteer who fits gets the pop-up; none left (or askTries asked) = NoVolunteer.
local function AskNext(m)
    m.phase, m.cid, m.src, m.token, m.deadline = 'asking', nil, nil, nil, nil
    if V.release then V.release(m.runId) end
    local tries = math.floor(Num(CP.RealPlayers('volunteer').askTries, 3, 1, 10))
    if not CP.RealPlayersOn('volunteer') or m.run.state == 'ended' then
        m.why = 'off'
        return NoVolunteer(m, false)
    end
    for _, cid in ipairs(Candidates(m)) do
        if m.tries >= tries then break end
        if not m.asked[cid] and not byCid[cid] then
            local src = SrcOf(cid)
            -- Fits may yield (selfBlock's database read): another match may have asked him meanwhile
            if src and Fits(m, cid, src) and not byCid[cid] then
                -- ...and the run may have ended meanwhile
                if m.run.state == 'ended' or matches[m.runId] ~= m then return end
                m.asked[cid] = true
                m.tries = m.tries + 1
                counter = counter + 1
                local seconds = math.floor(Num(CP.RealPlayers('volunteer').askSeconds, 30, 10, 120))
                m.cid, m.src = cid, src
                m.token = ('va%d_%06d'):format(counter, math.random(0, 999999))
                m.deadline = GetGameTimer() + seconds * 1000
                byCid[cid] = m.runId
                if V.hold then V.hold(m.runId, cid) end
                local here, meet = Coords(src), m.meet
                local km = (here and meet) and math.floor(CP.U.dist(here, meet) / 100 + 0.5) / 10 or nil
                TriggerClientEvent(CP.e('client:volunteerAsk'), src, m.token, {
                    role = m.role,
                    seconds = seconds,
                    km = km,
                    travelMinutes = math.ceil(Num(CP.RealPlayers('volunteer').travelSeconds, 300, 60, 1800) / 60),
                })
                CP.log(TAG, 'run %s: %s is asked to play the %s (%d)', m.runId, cid, m.role, m.tries)
                return
            end
        end
    end
    m.why = 'nobody'
    NoVolunteer(m, false)
end

-- He said yes: the checks again, then his case opens and he travels to the meet point.
local function Accept(m)
    local cid, src = m.cid, m.src
    local ok, why = Fits(m, cid, src)
    -- Fits may yield: the match may have moved past him meanwhile (it asks the next volunteer itself then)
    if m.cid ~= cid or m.phase ~= 'asking' then
        Note(src, 'error', 'volunteer.ask.not_now')
        CP.log(TAG, 'run %s: %s said yes after the match moved on', m.runId, cid)
        return
    end
    if not ok or m.run.state == 'ended' or matches[m.runId] ~= m then
        Note(src, 'error', 'volunteer.ask.not_now')
        CP.log(TAG, 'run %s: %s said yes but can no longer play it (%s)', m.runId, cid, tostring(why))
        Free(m, cid)
        return AskNext(m)
    end
    local case = Opp('open', m.run, { kind = 'volunteer', index = m.obj, members = { cid }, meet = m.meet })
    if type(case) ~= 'table' then
        Note(src, 'error', 'volunteer.ask.not_now')
        Free(m, cid)
        return AskNext(m)
    end
    local now = GetGameTimer()
    m.case = case
    case.volunteer = { role = m.role, mode = m.mode }  -- what staff read once the match is gone
    m.phase, m.token, m.yesAt = 'travel', nil, now
    m.travelUntil = now + math.floor(Num(CP.RealPlayers('volunteer').travelSeconds, 300, 60, 1800)) * 1000
    m.run.realSuspect = 'volunteer'
    if CP.Alerts and CP.Alerts.releaseRun then pcall(CP.Alerts.releaseRun, m.run) end
    Line(m, 'volunteer_yes', { count = m.tries })
    for _, officer in ipairs(ActiveSrcs(m.run)) do FlagLinked(m, officer) end
    Note(src, 'success', 'volunteer.ask.accepted')
    TriggerClientEvent(CP.e('client:volunteerCase'), src, {
        phase = 'travel',
        role = m.role,
        meet = Plain(m.meet),
        seconds = math.floor((m.travelUntil - now) / 1000),
        radius = m.radius,
    })
    TellOfficers(m.run, 'warning', 'volunteer.officer.yes')
    CP.log(TAG, 'run %s: %s plays the %s', m.runId, cid, m.role)
end

-- ============================================================================
--                       TRAVEL, POSITION AND ENGAGEMENT
-- ============================================================================

-- An officer reached him (the case's first contact): the officers lose the NPC-combat headshot protection and
-- defense (CP.NpcCombat.dropFor) unless Config.RealPlayers.npcCombat is true.
local function Engage(m)
    m.phase, m.engagedAt = 'engaged', GetGameTimer()
    local rs = CP.RealPlayers()
    if rs.npcCombat ~= true and CP.NpcCombat and CP.NpcCombat.dropFor then
        for _, src in ipairs(ActiveSrcs(m.run)) do pcall(CP.NpcCombat.dropFor, m.run, src, 'volunteer') end
    end
    Line(m, 'engaged')
    Note(m.src, 'inform', 'volunteer.case.engaged')
    TriggerClientEvent(CP.e('client:volunteerCase'), m.src, { phase = 'engaged' })
end

local function Watch(m, now)
    if m.phase == 'asking' then
        if not m.cid or m.token == nil then
            return
        end -- token nil: his yes is being checked (Accept)
        if now > m.deadline + LATE_MS or not (V.isListed and V.isListed(m.cid)) then
            TriggerClientEvent(CP.e('client:volunteerAskClose'), m.src, m.token)
            Free(m, m.cid)
            AskNext(m)
        end
        return
    end
    if not CANCEL_PHASES[m.phase] then return end
    local _, rec = Opp('byCid', m.cid)
    if not rec or rec.state == 'void' or rec.state == 'left' then
        -- he went on police duty mid-case (CP.Opponents voided him): a dropout with a strike, like a cancel
        if rec and rec.state == 'void' and rec.voidWhy == 'on_duty' then return Voided(m, 'on_duty', true) end
        -- he respawned at a hospital before the death timer ran out (CP.Opponents' proof voided him): a strike too
        if rec and rec.state == 'void' and rec.voidWhy == 'early_respawn' then
            return Voided(m, 'early_respawn', true)
        end
        local why = rec and rec.state == 'left' and 'left' or 'void'
        return Voided(m, why, why == 'left')
    end
    if m.leftByRule then return end
    if rec.src then m.src = rec.src end
    -- Config.RealPlayers.onLeave 'caught' or 'escaped' decided a free volunteer's leave (logged off past
    -- the grace, switched character, entered an instance; CP.Opponents' rec.leaveRule): his case keeps that outcome
    -- for the officers, but for him it is a dropout with a strike and no pay, as a leave under 'left' is. A leave in
    -- cuffs (left_in_cuffs) never reaches the rule: it stays a catch.
    if rec.leaveRule and (rec.state == 'lost' or rec.state == 'detained') then
        m.leftByRule, m.why, m.struck = true, 'left', true
        if V.strike then V.strike(m.cid, 'left') end
        Note(m.src, 'warning', 'volunteer.case.left')
        TriggerClientEvent(CP.e('client:volunteerCase'), m.src, { phase = 'over' })
        CP.log(TAG, 'run %s: %s left the case (onLeave %s)', m.runId, m.cid, tostring(rec.leaveRule))
        return
    end
    -- an AFK catch (share 0) is a void (Config.RealPlayers.volunteer.afkCatchVoids, shipped true): never a catch that
    -- counts
    local caught = rec.state == 'detained' or rec.state == 'booked'
    if caught and tonumber(rec.share) == 0 and CP.RealPlayers('volunteer').afkCatchVoids ~= false then
        m.engagedAt = m.engagedAt or GetGameTimer()  -- officers had him in cuffs: the NPC never takes over now
        return Voided(m, 'afk', true)
    end
    if m.phase ~= 'engaged' and rec.contactAt then return Engage(m) end
    if m.phase == 'travel' then
        local here = rec.src and Coords(rec.src)
        if here and m.meet and CP.U.dist(here, m.meet) <= m.radius then
            m.phase = 'in_position'
            Line(m, 'in_position')
            Note(m.src, 'success', 'volunteer.case.in_position')
            TriggerClientEvent(CP.e('client:volunteerCase'), m.src, { phase = 'in_position' })
        elseif now > m.travelUntil then
            Voided(m, 'no_show', true)
        end
    end
end

local function Tick()
    local now = GetGameTimer()
    for _, m in pairs(matches) do
        if m.run.state ~= 'ended' then
            local ok, err = pcall(Watch, m, now)
            if not ok then CP.err(TAG, 'the volunteer match of run %s failed: %s', m.runId, tostring(err)) end
        end
    end
end

local function Busy()
    for _, m in pairs(matches) do
        if m.phase == 'asking' or CANCEL_PHASES[m.phase] then return true end
    end
    return false
end

StartTick = function()
    if tick.on then return end
    tick.on = true
    tick.token = tick.token + 1
    local token = tick.token
    CreateThread(function()
        while tick.token == token and Busy() do
            Wait(TICK_MS)
            if tick.token ~= token then return end
            Tick()
        end
        if tick.token == token then tick.on = false end
    end)
end

-- ============================================================================
--                        THE GATES (ARCHITECTURE 5.47)
-- ============================================================================
-- A run whose suspect a volunteer plays (run.realSuspect = 'volunteer', from his yes on) takes part in the Type of
-- the Day, goals, the challenge, cash and item rewards only with Config.RealPlayers.volunteer' switch of that name
-- (shipped false: points only). They read the run (never Config.RealPlayers.volunteer.enabled), so a case running when
-- the owner turns volunteers off still ends by its rules.

-- Whether a run is a volunteer case (a volunteer said yes).
function V.isCase(run) return type(run) == 'table' and run.realSuspect == 'volunteer' end

-- The caps of Config.RealPlayers (live crimes and volunteers together) between this volunteer and the run's active
-- officers -> true | false, reason: the volunteer already scored maxCatchesPerSuspectDay times today
-- ('suspect_used'); an officer suspended from these cases ('officer_suspended'), a suspect within jobHopMinutes
-- ('officer_recent_suspect'), with an admin pair block ('pair_blocked') or a recent case with him ('pair_cooldown').
-- Memory only: CP.Opponents' caps never query the database.
function V.capsOk(run, cid)
    if type(run) ~= 'table' or type(cid) ~= 'string' then return false, 'gone' end
    local perDay = math.floor(Num(CP.RealPlayers('antiFarm').maxCatchesPerSuspectDay, 2, 0))
    if Num(Opp('suspectDayCount', cid), 0) >= perDay then return false, 'suspect_used' end
    local hop = Num(CP.RealPlayers().jobHopMinutes, 30, 0) * 60
    for _, src in ipairs(ActiveSrcs(run)) do
        local p = type(run.participants) == 'table' and run.participants[src] or nil
        local oCid = type(p) == 'table' and p.citizenid or nil
        if type(oCid) == 'string' then
            if Opp('suspended', oCid) == true then return false, 'officer_suspended' end
            local was = tonumber(Opp('lastSuspectAt', oCid))
            if was and os.time() - was < hop then return false, 'officer_recent_suspect' end
            local ok, why = Opp('pairOk', oCid, cid)
            if ok == false then return false, why == 'blocked' and 'pair_blocked' or 'pair_cooldown' end
        end
    end
    return true
end

-- The pair rows of a volunteer case at the run's end (CP.Opponents.recordPairs, kind 'volunteer'): one per officer
-- who took part and the volunteer; scored = the run completed and he was detained or booked for a share above 0;
-- outcome 'gone' when no officer reached him (it never counts for the caps). Then the pair-repeat check.
local function RecordPairs(m, run, state)
    local outcomes, case = Opp('close', run)
    if type(case) ~= 'table' or type(outcomes) ~= 'table' or case.kind ~= 'volunteer' then return 0 end
    local rows = {}
    for _, p in pairs(run.participants or {}) do
        if type(p) == 'table' and type(p.citizenid) == 'string' then
            for _, cid in ipairs(case.order or {}) do
                local rec = case.suspects and case.suspects[cid] or {}
                local out = outcomes[cid]
                local caught = (out == 'detained' or out == 'booked') and Num(rec.share, 1) > 0
                rows[#rows + 1] = {
                    officer = p.citizenid,
                    suspect = cid,
                    kind = 'volunteer',
                    scored = state == 'completed' and caught,
                    outcome = (m.engagedAt or rec.contactAt) and out or 'gone',
                    suspectLicense = rec.license,
                }
            end
        end
    end
    local n = Opp('recordPairs', run, rows) or 0
    Opp('checkPairFlags', run)
    return n
end

-- ============================================================================
--                                   THE API
-- ============================================================================

-- Starts the matching of a run with run.volunteer (from the run:created hook, one frame later so a 'players_only'
-- hold is already under the run id). -> true when asking began.
function V.match(run)
    if type(run) ~= 'table' or type(run.volunteer) ~= 'table' or run.state == 'ended' or matches[run.id] then
        return false
    end
    if not CP.RealPlayersOn('volunteer') or run.test or run.live then return false end
    local slot = V.slotOf and V.slotOf(run.mission, run.locationIndex) or nil
    if not slot then return false end
    local m = {
        run = run,
        runId = run.id,
        mode = run.volunteer.mode,
        role = slot.role,
        obj = run.volunteer.obj or slot.obj,
        meet = MeetOf(run, slot),
        radius = Num(CP.RealPlayers('volunteer').meetRadius, 25.0, 5.0, 200.0),
        asked = {},
        tries = 0,
    }
    matches[run.id] = m
    CreateThread(function()
        AskNext(m)
        StartTick()
    end)
    return true
end

-- What a block may know (ctx.volunteer()): nil unless objective index is the volunteer slot of a run being matched,
-- else { role, mode, phase, meet, label, real, engaged }. phase: 'asking' (wait), 'travel', 'in_position',
-- 'engaged' (a real player plays him: real = true), 'npc' (the NPC plays him), 'void' (the run is ending). Never a
-- citizenid, server id or live position.
function V.matchView(run, index)
    local m = type(run) == 'table' and matches[run.id] or nil
    if not m or (index ~= nil and index ~= m.obj) then return nil end
    local _, rec = nil, nil
    if m.cid and CANCEL_PHASES[m.phase] then _, rec = Opp('byCid', m.cid) end
    return {
        role = m.role,
        mode = m.mode,
        phase = m.phase,
        meet = m.meet,
        label = rec and rec.label or nil,
        real = CANCEL_PHASES[m.phase] == true,
        engaged = m.phase == 'engaged',
    }
end

-- The match a volunteer is part of (asked or playing) -> { phase, role } or nil.
function V.matchOf(cid)
    local m = cid and byCid[cid] and matches[byCid[cid]] or nil
    if not m or m.cid ~= cid then return nil end
    return { phase = m.phase, role = m.role }
end

-- The question he has open now, for the criminal tablet's Jobs -> nil or { token, role, missionType, area, km,
-- seconds (left to answer), travelMinutes }. area: the location's label; never the run, an officer or a position.
function V.askOf(cid)
    local m = cid and byCid[cid] and matches[byCid[cid]] or nil
    if not m or m.phase ~= 'asking' or m.cid ~= cid or not m.token or not m.deadline then return nil end
    local run = m.run
    local def = type(run.mission) == 'table' and run.mission or {}
    local here = Coords(m.src)
    local loc = type(run.location) == 'table' and run.location or {}
    return {
        token = m.token,
        role = m.role,
        missionType = run.missionType or def.type,
        area = type(loc.label) == 'string' and CP.U.clip(loc.label, 64) or nil,
        km = (here and m.meet) and math.floor(CP.U.dist(here, m.meet) / 100 + 0.5) / 10 or nil,
        seconds = math.max(0, math.ceil((m.deadline - GetGameTimer()) / 1000)),
        travelMinutes = math.ceil(Num(CP.RealPlayers('volunteer').travelSeconds, 300, 60, 1800) / 60),
    }
end

-- The suspect he plays now, for the criminal tablet's Active -> nil or { phase, role, meet = { x, y, z } (his
-- own meet point, already his waypoint), seconds (left to reach it while travelling), freeCancel (a cancel now is no
-- strike), graceSeconds }.
function V.caseOf(cid)
    local m = cid and byCid[cid] and matches[byCid[cid]] or nil
    if not m or m.cid ~= cid or not CANCEL_PHASES[m.phase] or m.leftByRule then return nil end
    local now = GetGameTimer()
    local grace = math.floor(Num(CP.RealPlayers('volunteer').cancelGraceSeconds, 60, 0, 600))
    local free = not m.engagedAt and now - (m.yesAt or 0) <= grace * 1000
    return {
        phase = m.phase,
        role = m.role,
        meet = Plain(m.meet),
        seconds = m.phase == 'travel' and math.max(0, math.ceil(((m.travelUntil or now) - now) / 1000)) or nil,
        freeCancel = free,
        graceSeconds = grace,
        -- seconds of the free Give up still left (the tablet counts it down, it is not refetched at 0)
        graceLeft = free and math.max(0, math.floor(((m.yesAt or 0) + grace * 1000 - now) / 1000)) or 0,
    }
end

-- His answer to the pop-up. Checked: the token of his open question, not later than askSeconds (plus lag), the run
-- still running, and (for a yes) every check of the ask again. A no or no answer is never a strike.
function V.answer(src, data)
    src = CP.U.toSrc(src)
    local cid = src and V.cidBySrc and V.cidBySrc(src)
    local m = cid and byCid[cid] and matches[byCid[cid]] or nil
    if type(data) ~= 'table' or type(data.token) ~= 'string' then return false, 'bad' end
    if not m or m.phase ~= 'asking' or m.cid ~= cid or m.src ~= src or m.token ~= data.token then
        return false, 'stale'
    end
    if GetGameTimer() > m.deadline + LATE_MS then return false, 'late' end
    if data.yes ~= true then
        Note(src, 'inform', 'volunteer.ask.declined')
        byCid[cid] = nil
        CreateThread(function() AskNext(m) end)
        return true
    end
    m.token = nil
    CreateThread(function() Accept(m) end)
    return true
end

-- His own Cancel this case (the volunteer menu, or Stop volunteering while he plays one). A strike unless it comes
-- within Config.RealPlayers.volunteer.cancelGraceSeconds of his yes and before any officer reached him.
function V.cancelCase(src)
    src = CP.U.toSrc(src)
    local cid = src and V.cidBySrc and V.cidBySrc(src)
    if src and not cid then
        -- off the list (volunteers turned off, excluded) while his case goes on: his own character still cancels it
        local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(src) or nil
        cid = type(info) == 'table' and info.citizenid or nil
    end
    local m = cid and byCid[cid] and matches[byCid[cid]] or nil
    if not m or m.cid ~= cid or m.src ~= src or not CANCEL_PHASES[m.phase] or m.leftByRule then
        return false, 'no_case'
    end
    local _, rec = Opp('byCid', m.cid)
    -- a detain or booking is final (as for a leave): nothing left to cancel, the arrest stands. In cuffs
    -- he follows the leave rule: cuffed -> detained ('left_in_cuffs'), and the case goes on.
    if type(rec) == 'table' and (rec.state == 'detained' or rec.state == 'booked') then return false, 'no_case' end
    if type(rec) == 'table' and rec.state == 'cuffed' then
        if rec.share == nil then rec.share = rec.afk and 0 or 1 end
        Opp('setState', m.run, m.cid, 'detained', { why = 'left_in_cuffs' })
        return false, 'no_case'
    end
    local grace = math.floor(Num(CP.RealPlayers('volunteer').cancelGraceSeconds, 60, 0, 600)) * 1000
    -- officers within contactRange count at once (CP.Opponents' contactAt), not only on the next match tick
    local reached = m.engagedAt or (type(rec) == 'table' and rec.contactAt)
    local free = not reached and GetGameTimer() - (m.yesAt or 0) <= grace
    Voided(m, 'cancelled', not free)
    return true
end

-- ============================================================================
--                     WHAT A BLOCK MAY TELL ITS VOLUNTEER
-- ============================================================================
-- Only while he plays (travel, in_position, engaged): a block never learns who he is, it names the run.

local function Playing(run)
    local m = type(run) == 'table' and matches[run.id] or nil
    if not m or not CANCEL_PHASES[m.phase] or not m.src then return nil end
    return m
end

-- A notification to the run's volunteer (a volunteer.* locale key).
function V.caseNote(run, kind, key, vars)
    local m = Playing(run)
    if not m or type(key) ~= 'string' then return false end
    Note(m.src, kind, key, vars)
    return true
end

-- His own map circle (search_area's fugitive): area = { x, y, z, r }, or nil to remove it.
function V.caseArea(run, area)
    local m = Playing(run)
    if not m then return false end
    TriggerClientEvent(CP.e('client:volunteerArea'), m.src, type(area) == 'table' and area or nil)
    return true
end

-- He broke the block's play-area rule (a fugitive outside the search circle too long): his part is void, a strike.
function V.outOfBounds(run)
    local m = Playing(run)
    if not m then return false end
    Voided(m, 'out_of_bounds', true)
    return true
end

-- ============================================================================
--                     RESULTS FOR OTHER SCRIPTS AND STAFF
-- ============================================================================
-- ARCHITECTURE 5.47.
-- The server-only event crimson-police:server:volunteerEnded when a run a volunteer said yes to ends
-- (Config.RealPlayers.volunteer.endEvent, shipped true; volunteer cases exist only while enabled), and what the staff
-- callbacks read of a volunteer case. Neither requires another resource, and nothing another script sends back is read.

V.END_EVENT = 'server:volunteerEnded'
local OUTCOMES = { detained = true, booked = true, got_away = true, left = true, void = true, stopped = true }

-- A volunteer case for staff (CP.Opponents staff): { role, mode, phase, why, engaged } while the run is matched,
-- else what the run's end left on the case (case.volunteer), else nil. Never a server id or a position.
function V.staffView(runId, case)
    local m = type(runId) == 'string' and matches[runId] or nil
    if m and m.yesAt then
        return { role = m.role, mode = m.mode, phase = m.phase, why = m.why, engaged = m.engagedAt ~= nil }
    end
    local v = type(case) == 'table' and type(case.volunteer) == 'table' and case.volunteer or nil
    if not v then return nil end
    return { role = v.role, mode = v.mode, phase = v.phase, why = v.why, engaged = v.engaged == true }
end

-- The volunteers on the list for staff, oldest first: { citizenid, name, roles, since, untilAt, strikes, playing
-- (the phase of the run he is asked for or plays, or nil) }. No server id, no position.
function V.staffList()
    local out = {}
    for _, v in ipairs(V.list and V.list() or {}) do
        local mo = V.matchOf(v.cid)
        out[#out + 1] = {
            citizenid = v.cid,
            name = v.name,
            roles = v.roles,
            since = v.since,
            untilAt = v.untilAt,
            strikes = V.strikes and V.strikes(v.cid) or 0,
            playing = mo and mo.phase or nil,
        }
    end
    return out
end

-- The end event's payload: the mission, the suspect he played, how the run ended, his outcome and why he dropped
-- out (if he did). The volunteer's citizenid is the only player data; no server id, no position.
function V.endPayload(m, run, state, reason)
    if type(m) ~= 'table' or type(m.cid) ~= 'string' or type(run) ~= 'table' then return nil end
    local outcomes, case = Opp('close', run)
    local o = type(outcomes) == 'table' and outcomes[m.cid] or nil
    if o == nil and type(case) == 'table' and type(case.suspects) == 'table' and case.suspects[m.cid] then
        o = case.suspects[m.cid].outcome
    end
    local officers = 0
    for _, p in pairs(run.participants or {}) do
        if type(p) == 'table' and type(p.citizenid) == 'string' then officers = officers + 1 end
    end
    local def = type(run.mission) == 'table' and run.mission or {}
    return {
        missionId = run.missionId or def.id,
        missionType = run.missionType or def.type,
        role = m.role,
        mode = m.mode,
        citizenid = m.cid,
        outcome = OUTCOMES[o] and o or 'got_away',
        dropout = (STRIKE_WHY[m.why] and m.struck) and m.why or nil,  -- a free cancel is no dropout
        engaged = m.engagedAt ~= nil,
        result = type(state) == 'string' and state or 'ended',
        reason = type(reason) == 'string' and reason or nil,
        officers = officers,
        endedAt = os.time(),
    }
end

-- Sends the end event once for a run a volunteer said yes to (never for a test run). -> true when it was sent.
function V.sendEnded(m, run, state, reason)
    if CP.RealPlayers('volunteer').endEvent == false or type(m) ~= 'table' or not m.yesAt or m.endSent then
        return false
    end
    if type(run) ~= 'table' or run.test then return false end
    local payload = V.endPayload(m, run, state, reason)
    if not payload then return false end
    m.endSent = true
    local ok, err = pcall(TriggerEvent, CP.e(V.END_EVENT), payload)
    if not ok then CP.err(TAG, 'the volunteerEnded event of run %s failed: %s', tostring(m.runId), tostring(err)) end
    return ok
end

-- The criminal tablet's History line (CP.CrimTab.record) for a run a volunteer said yes to, whatever
-- Config.RealPlayers.volunteer.endEvent says (that switch is only the event for other scripts); never a test run.
function V.recordHistory(m, run, state, reason)
    local C = CP.CrimTab
    if not (C and C.record) or type(m) ~= 'table' or not m.yesAt or type(run) ~= 'table' or run.test then
        return false
    end
    local payload = V.endPayload(m, run, state, reason)
    if not payload then return false end
    local ok, res = pcall(C.record, payload)
    if not ok then CP.err(TAG, 'the History line of run %s failed: %s', tostring(m.runId), tostring(res)) end
    return ok and res == true
end

-- The volunteer's own pay (Config.FeatureRewards.suspect): only for a case the server saw end fairly
-- (CP.FeatureRewards.fairSuspect: officers reached him, no dropout, not AFK, a real outcome), never a test run.
function V.payVolunteer(m, run, state, reason)
    local FR = CP.FeatureRewards
    if not (FR and FR.enabled and FR.enabled('suspect')) then return false end
    if type(m) ~= 'table' or not m.yesAt or type(run) ~= 'table' or run.test then return false end
    local payload = V.endPayload(m, run, state, reason)
    if not payload then return false end
    -- an officer of the run shares a connection or PC with him (rs_linked_accounts, held for review): no pay
    if Linked(run) then return false end
    -- the same pair again with a second sign (rs_pair_repeat, raised by RecordPairs just before): no pay either
    if FlaggedWith(run, 'rs_pair_repeat') then return false end
    local _, case = Opp('close', run)
    local rec = type(case) == 'table' and type(case.suspects) == 'table' and case.suspects[m.cid] or nil
    local afk = type(rec) == 'table' and (rec.afk == true or tonumber(rec.share) == 0) or false
    return FR.suspectEnded(run.id, payload, afk) == true
end

V.matchActions = {
    answer = function(src, data)
        local ok, why = V.answer(src, data)
        if not ok and why == 'late' then Note(src, 'error', 'volunteer.ask.too_late') end
    end,
    cancel = function(src)
        local ok = V.cancelCase(src)
        if not ok then Note(src, 'error', 'volunteer.refused.no_case') end
    end,
}

-- ============================================================================
--                                    HOOKS
-- ============================================================================

CP.Hooks.on('run:created', function(run)
    if type(run) ~= 'table' or type(run.volunteer) ~= 'table' then return end
    SetTimeout(0, function() V.match(run) end)
end)

-- An officer who joins while a volunteer plays the suspect is checked for a linked account (rs_linked_accounts);
-- one who joins after the engagement loses the protection too.
CP.Hooks.on('participant:joined', function(run, src)
    local m = type(run) == 'table' and matches[run.id] or nil
    if not m or not CANCEL_PHASES[m.phase] then return end
    CreateThread(function() FlagLinked(m, src) end)
    if m.phase ~= 'engaged' or (CP.RealPlayers()).npcCombat == true then return end
    if CP.NpcCombat and CP.NpcCombat.dropFor then pcall(CP.NpcCombat.dropFor, run, src, 'volunteer') end
end)

-- A free volunteer whose leave was settled in the same call that ended the run (an onLeave 'escaped' leave that
-- failed the objective, or a drop within the grace that Opp.close made final): Watch never saw it, so the dropout
-- with a strike and no pay is applied here, before the pair rows, History and pay read m.why.
local function LateLeave(m, run)
    if m.why ~= nil or m.leftByRule or not CANCEL_PHASES[m.phase] then return end
    local _, case = Opp('close', run)
    local rec = type(case) == 'table' and type(case.suspects) == 'table' and case.suspects[m.cid] or nil
    if not (type(rec) == 'table' and rec.leaveRule) then return end
    if rec.state ~= 'lost' and rec.state ~= 'detained' and rec.state ~= 'left' then return end
    m.leftByRule, m.why, m.struck = true, 'left', true
    if V.strike then V.strike(m.cid, 'left') end
    CP.log(TAG, 'run %s: %s left the case as it ended (onLeave %s)', m.runId, m.cid, tostring(rec.leaveRule))
end

-- The release: a pop-up still open closes, a volunteer who played the suspect is told he is free to go; a case
-- that opened (a yes came) writes its pair rows, keeps its last phase for staff and sends volunteerEnded.
CP.Hooks.on('run:ended', function(run, state, reason)
    local m = type(run) == 'table' and matches[run.id] or nil
    if not m then return end
    matches[run.id] = nil
    if m.yesAt then
        local okL, errL = pcall(LateLeave, m, run)
        if not okL then CP.err(TAG, 'the leave check of run %s failed: %s', m.runId, tostring(errL)) end
        local ok, err = pcall(RecordPairs, m, run, state)
        if not ok then CP.err(TAG, 'the pair rows of run %s failed: %s', m.runId, tostring(err)) end
        if type(m.case) == 'table' and type(m.case.volunteer) == 'table' then
            local v = m.case.volunteer
            v.phase, v.why, v.engaged = m.phase, m.why, m.engagedAt ~= nil
        end
        V.sendEnded(m, run, state, reason)
        V.recordHistory(m, run, state, reason)
        V.payVolunteer(m, run, state, reason)
    end
    if m.phase == 'asking' and m.token then
        TriggerClientEvent(CP.e('client:volunteerAskClose'), m.src, m.token)
    elseif CANCEL_PHASES[m.phase] and not m.leftByRule then
        Note(m.src, 'success', 'volunteer.case.released')
        TriggerClientEvent(CP.e('client:volunteerCase'), m.src, { phase = 'over' })
    end
    m.phase = 'over'
    Forget(m)
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    matches, byCid = {}, {}
    tick.token = tick.token + 1
    tick.on = false
end)

V._matchTick = Tick
V._recordPairs = RecordPairs

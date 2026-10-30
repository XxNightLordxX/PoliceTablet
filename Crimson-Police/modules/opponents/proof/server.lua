-- CP.Opponents proof (server, step V5): the server facts that decide every detain and booking of a real suspect. The
-- sc-police cuff pair and the custody hold, getting free during the hold (an officer's uncuff, a friend's bobby pin,
-- sc-police's cuff-break game, or a self-uncuff), downs, bookings matched in either order, and the hospital rules.

CP.Opponents = CP.Opponents or {}
local Opp = CP.Opponents
local TAG = 'opponents'

local EVIDENCE_MS = 5000          -- an officer uncuff, a bobby pin or a cuff-break this close to the cuffs coming off
local SETTLE_MS = 2000            -- sc-police sends its cuff-break alert just after the uncuffed state: wait this long
local BREAK_MIN_MS = 2000         -- a break-free this soon after the cuff is not sc-police's minigame (critic 2 #30)
local BOOK_PAIR_MS = 10000        -- the jail event and the injail change pair within this, in either order
local RESCUE_TICKS = 2            -- watch passes a friend must stand within rescueRange before his bobby pin result
local UP_GRACE_MS = 5000          -- a respawn this soon after getting up still counts the time he was down

local DONE = { lost = true, left = true, void = true }

local held = {}                        -- [citizenid] = true while the suspect is 'cuffed' (pruned when he is not)
local pass = { at = -1, coords = {} }  -- the online players' server coords, read once per watch pass during a hold
local errorAt = {}

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Cfg() return Config.RealSuspects or {} end

local function Num(v, default)
    v = tonumber(v)
    if not v or v ~= v or v == math.huge or v == -math.huge then return default end
    return v
end

-- A Config.RealSuspects number of seconds in milliseconds (never below 0).
local function Ms(key, default) return math.max(0, Num(Cfg()[key], default)) * 1000 end

local function Share() return math.max(0, math.min(1, Num(Cfg().neutralisedShare, 0.5))) end

local function LogError(key, fmt, ...)
    local now = os.time()
    if errorAt[key] and now - errorAt[key] < 60 then return end
    errorAt[key] = now
    CP.err(TAG, fmt, ...)
end

local function Bucket(src)
    if type(GetPlayerRoutingBucket) ~= 'function' then return 0 end
    local ok, b = pcall(GetPlayerRoutingBucket, src)
    if not ok then return 0 end
    return tonumber(b) or 0
end

local function ServerCoords(src)
    if not src then return nil end
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return GetEntityCoords(ped)
end

local function ActiveSrcs(run)
    local out = {}
    if type(run) ~= 'table' or type(run.order) ~= 'table' or type(run.participants) ~= 'table' then return out end
    for _, src in ipairs(run.order) do
        local p = run.participants[src]
        if type(p) == 'table' and p.status == 'active' then out[#out + 1] = src end
    end
    return out
end

local function IsParticipant(run, src)
    return CP.Runs ~= nil and CP.Runs.isParticipant ~= nil and CP.Runs.isParticipant(run, src) == true
end

-- On duty in a turned-on Config.Departments job (sc-police checks neither the job nor the duty). getInfo and the
-- department map only, never getOfficer: a listener must not yield (section 5.1), and getOfficer's suspension and
-- retired lookups read the database on a cache miss (with oxmysql every await yields), so the suspect's cuffed state
-- could arrive before the attempt is kept. A participant passed getOfficer when he joined, and a suspension ends his
-- part in the run (CP.Access.onLost).
local function OnDuty(src)
    local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(src) or nil
    local job = info and info.job
    if type(job) ~= 'table' or job.onduty ~= true then return false end
    return CP.Access ~= nil and CP.Access.departmentForJob ~= nil and CP.Access.departmentForJob(job.name) ~= nil
end

-- Both in bucket 0, the officer not in Crimson-Arena, the server distance within range -> true, metres | false, why.
local function Plausible(officerSrc, targetSrc, range)
    if Bucket(officerSrc) ~= 0 or Bucket(targetSrc) ~= 0 then return false, 'instance' end
    if CP.Alerts and CP.Alerts.inArena and CP.Alerts.inArena(officerSrc) then return false, 'arena' end
    local a, b = ServerCoords(officerSrc), ServerCoords(targetSrc)
    local d = a and b and CP.U.dist(a, b) or nil
    if not d or d > range then return false, 'distance' end
    return true, d
end

-- An active participant of the case within contactRange of the suspect now (server coords; an event path).
local function ParticipantNear(case, rec)
    local coords = ServerCoords(rec.src)
    if not coords then return false end
    local range = Num(Cfg().contactRange, 100.0)
    for _, src in ipairs(ActiveSrcs(case.run)) do
        local c = ServerCoords(src)
        if c and CP.U.dist(c, coords) <= range then return true end
    end
    return false
end

-- The booking zone at coords: a zone, or true when Config.RealSuspects.bookingZones is {} (anywhere), else nil.
local function ZoneAt(coords)
    local zones = Cfg().bookingZones
    if type(zones) ~= 'table' or #zones == 0 then return true end
    if not coords then return nil end
    for _, z in ipairs(zones) do
        if type(z) == 'table' and z.coords and CP.U.dist(coords, z.coords) <= Num(z.radius, 0) then return z end
    end
    return nil
end

local function JailValue(v) return math.max(0, math.floor(Num(v, 0))) end

local function Line(case, rec, what, extra)
    local entry = { what = what, label = rec.label, src = rec.src }
    for k, v in pairs(extra or {}) do entry[k] = v end
    Opp.timeline(case.run, entry)
end

-- ============================================================================
--                          FREE, DETAIN, SELF-UNCUFF
-- ============================================================================

-- Back to free (an officer's release, a rescue, a cuff-break, or a refused detain): the hold's facts are dropped.
local function Free(case, rec, why, by)
    rec.freedAt, rec.uncuff, rec.outsideUncuff, rec.pin, rec.cuffBreak = nil, nil, nil, nil, nil
    rec.share, rec.near = nil, {}
    held[rec.cid] = nil
    Opp.setState(case.run, rec.cid, 'free', { why = why, by = by })
end

-- Detained with rec.share as set at the cuff; refused while spawn protection lasts (he goes back to free).
local function Detain(case, rec, why, by, now)
    if rec.protectUntil and now < rec.protectUntil then
        Line(case, rec, 'spawn_protected', { why = why, seconds = math.ceil((rec.protectUntil - now) / 1000) })
        Free(case, rec, 'spawn_protected', by)
        return false
    end
    rec.freedAt, rec.uncuff, rec.outsideUncuff, rec.pin, rec.cuffBreak = nil, nil, nil, nil, nil
    held[rec.cid] = nil
    Opp.setState(case.run, rec.cid, 'detained', { why = why, by = by })
    return true
end

local function Fresh(ev, at) return ev ~= nil and math.abs(at - ev.at) <= EVIDENCE_MS end

-- The cuffs came off with no participant's uncuff, rescue or fair cuff-break: detained at once, and a note. With an
-- uncuff by someone outside the case within 5 s the note names him (rs_outside_uncuff); else it is sc-police's
-- /fixcuffs or an admin's /resetcuffs (both a server SetMetaData with no event: they cannot be told apart).
local function SelfUncuff(case, rec, now)
    local run, cid, label, by = case.run, rec.cid, rec.label, rec.caughtBy and rec.caughtBy[1] or nil
    local seconds = math.max(0, math.floor(((rec.freedAt or now) - (rec.cuffedAt or now)) / 1000))
    local outsider = Fresh(rec.outsideUncuff, rec.freedAt or now) and rec.outsideUncuff or nil
    if outsider then
        Detain(case, rec, 'outside_uncuff', by, now)
        Opp.note(run, 'rs_outside_uncuff', CP.L('opp.detail.outside_uncuff', {
            label = label,
            seconds = seconds,
            name = outsider.name,
            by = outsider.src,
        }), cid)
        return
    end
    Detain(case, rec, 'self_uncuff', by, now)
    Opp.note(run, 'rs_self_uncuff', CP.L('opp.detail.self_uncuff', { label = label, seconds = seconds }), cid)
end

-- Why the cuffs came off during the hold, in this order: a participant's uncuff, a friend's bobby pin (once per
-- suspect per case), his first fair cuff-break; final (SETTLE_MS later, or at the close) = a self-uncuff.
local function Explain(case, rec, now, final)
    local at = rec.freedAt
    if rec.state ~= 'cuffed' or not at then return end
    if Fresh(rec.uncuff, at) then return Free(case, rec, 'released', rec.uncuff.src) end
    if Fresh(rec.pin, at) and not rec.rescued then
        rec.rescued = true
        return Free(case, rec, 'rescued', nil)
    end
    if Fresh(rec.cuffBreak, at) then
        local since = at - (rec.cuffedAt or at)
        if not rec.brokeFree and since >= BREAK_MIN_MS and since <= Ms('breakFreeSeconds', 20) then
            rec.brokeFree = true
            return Free(case, rec, 'broke_free', nil)
        end
        return SelfUncuff(case, rec, now)
    end
    if final then SelfUncuff(case, rec, now) end
end

-- ============================================================================
--                           THE CUFF PAIR (METADATA)
-- ============================================================================

-- ishandcuffed false -> true: cuffed when an officer of the case cuffed him within cuffPairWindow. The share is 0
-- when he was AFK by his samples (and a note: critic 2 #15), neutralisedShare when he was down (whoever downed him:
-- C28) or after a hospital respawn with officers in contact (C26), else 1.
local function CuffsOn(case, rec, now)
    if rec.state ~= 'free' then return end
    local window = Ms('cuffPairWindow', 10)
    local c, o = rec.cuff, rec.outsideCuff
    rec.cuff = nil
    if c and now - c.at <= window then
        rec.outsideCuff = nil
        rec.caughtBy = { c.officerSrc }
        rec.near, rec.freedAt, rec.uncuff, rec.outsideUncuff, rec.pin, rec.cuffBreak = {}, nil, nil, nil, nil, nil
        if rec.afk then
            rec.share = 0
        elseif rec.down or rec.hospitalCatch then
            rec.share = Share()
        else
            rec.share = 1
        end
        rec.hospitalCatch = nil
        held[rec.cid] = true
        Opp.setState(case.run, rec.cid, 'cuffed', { why = 'cuff_pair', by = c.officerSrc })
        if rec.afk then
            Opp.note(case.run, 'rs_afk_catch', CP.L('opp.detail.afk_catch', { label = rec.label }), rec.cid)
        end
    elseif o and now - o.at <= window then
        -- an on-duty officer outside the case cuffed him: V15 decides assist or stopped
        o.pairedAt = now
        rec.outsideCuffed = true
        Line(case, rec, 'cuffed_by_outsider', { by = o.src })
    else
        Line(case, rec, 'cuffed_unproven')
    end
end

local function CuffsOff(case, rec, now)
    if rec.state ~= 'cuffed' or rec.freedAt then return end
    rec.freedAt = now
    Explain(case, rec, now, false)
end

-- isdead / inlaststand: down while either is true.
local function DownChange(case, rec, now)
    local down = rec.md.isdead == true or rec.md.inlaststand == true
    if down == (rec.down == true) then return end
    rec.down = down
    if down then
        rec.downAt, rec.upAt = now, nil
        rec.downNear = ParticipantNear(case, rec)
        Line(case, rec, 'down', { officersNear = rec.downNear })
        Opp.send(case.run, rec.cid, 'opp_down')
    else
        rec.upAt = now
        Line(case, rec, 'up')
        Opp.send(case.run, rec.cid, 'opp_up')
    end
end

-- ============================================================================
--                         BOOKINGS (EITHER ORDER, C19)
-- ============================================================================

-- The jail event and the last injail 0 -> above 0 change within BOOK_PAIR_MS, whichever came second (critic 2 #5:
-- sc-police writes injail inside its own JailPlayer handler and qbx fires onSetMetaData at once).
local function TryBook(case, rec, now)
    local run, cfg = case.run, Cfg()
    local o = rec.outsideJail
    local open = rec.state == 'free' or rec.state == 'cuffed'
    if open and o and not o.paired and rec.injailAt and math.abs(rec.injailAt - o.at) <= BOOK_PAIR_MS then
        -- jailed by someone outside the case: no detain or booking for anyone
        o.paired, rec.injailAt = true, nil
        rec.outcome, rec.stoppedBy = 'stopped', o.src
        held[rec.cid] = nil
        Opp.setState(run, rec.cid, 'void', { why = 'stopped', by = o.src })
        Opp.note(run, 'rs_outside_jail', CP.L('opp.detail.outside_jail', { label = rec.label, months = o.t }), rec.cid)
        return
    end
    local j = rec.jail
    if not j or j.paired or not rec.injailAt or math.abs(rec.injailAt - j.at) > BOOK_PAIR_MS then return end
    if rec.state ~= 'detained' then return end
    j.paired, rec.injailAt = true, nil
    if j.t < Num(cfg.minJailTime, 5) then
        Line(case, rec, 'booking_too_short', { by = j.officerSrc, months = j.t })
        return
    end
    if not j.inZone then
        Line(case, rec, 'booked_outside_station', { by = j.officerSrc, months = j.t })
        return
    end
    rec.jailTime = math.min(j.t, math.max(0, math.floor(Num(cfg.jailTimeMax, 120))))
    Opp.setState(run, rec.cid, 'booked', { why = 'jailed', by = j.officerSrc })
end

-- ============================================================================
--                            THE METADATA HOOK (V4)
-- ============================================================================

-- CP.Opponents' mirror changed (old ~= new). Ignored in a bucket other than 0, whose cuffs and downs Crimson-Arena
-- rewrites (the core handles the instance itself).
function Opp.onMeta(rec, key, old, new, case)
    if type(rec) ~= 'table' or type(case) ~= 'table' or not rec.src or DONE[rec.state] then return end
    if Bucket(rec.src) ~= 0 then return end
    local now = GetGameTimer()
    if key == 'ishandcuffed' then
        -- sc-police registers SetHandcuffStatus twice: a second true is no change
        if (old == true) == (new == true) then return end
        if new == true then CuffsOn(case, rec, now) else CuffsOff(case, rec, now) end
    elseif key == 'isdead' or key == 'inlaststand' then
        DownChange(case, rec, now)
    elseif key == 'injail' then
        if JailValue(old) == 0 and JailValue(new) > 0 then
            rec.injailAt = now
            TryBook(case, rec, now)
        end
    end
end

-- The case closes: a release still waiting for its explanation is decided now (a self-uncuff without one).
function Opp.onClose(case)
    local now = GetGameTimer()
    for _, cid in ipairs(case.order) do
        local rec = case.suspects[cid]
        if rec.state == 'cuffed' and rec.freedAt then Explain(case, rec, now, true) end
        held[cid] = nil
    end
end

-- ============================================================================
--                    SC-POLICE AND SC-AMBULANCE FACTS (V3)
-- ============================================================================

-- A cuff attempt on a suspect, kept only when it can be true. Nothing here may yield: sc-police has already sent
-- the cuff to the suspect, and his cuffed state must find the attempt stored.
local function CuffSuspect(officerSrc, targetSrc)
    local case, rec = Opp.bySrc(targetSrc)
    if not rec or rec.state ~= 'free' or officerSrc == targetSrc then return end
    local inCase = IsParticipant(case.run, officerSrc)
    if not OnDuty(officerSrc) then
        if inCase then Line(case, rec, 'cuff_refused', { by = officerSrc, why = 'not_on_duty' }) end
        return
    end
    local ok, why = Plausible(officerSrc, targetSrc, Num(Cfg().cuffRange, 3.5))
    if not ok then
        Line(case, rec, 'cuff_refused', { by = officerSrc, why = why, inCase = inCase })
        return
    end
    local now = GetGameTimer()
    if inCase then
        rec.cuff = { officerSrc = officerSrc, at = now }
        Line(case, rec, 'cuff_attempt', { by = officerSrc })
        Opp.send(case.run, rec.cid, 'opp_cuff_attempt', { by = officerSrc })
    else
        rec.outsideCuff = { src = officerSrc, at = now }
        Line(case, rec, 'outside_cuff_attempt', { by = officerSrc })
    end
end

-- 'cuff' (officerSrc, targetSrc): the attempt on a suspect first, then every attempt by a participant of a live run,
-- on anyone, gets the same hint (C5).
local function OnCuff(officerSrc, targetSrc)
    CuffSuspect(officerSrc, targetSrc)
    local own = CP.Runs and CP.Runs.getBySrc and CP.Runs.getBySrc(officerSrc) or nil
    if type(own) == 'table' and own.live and CP.LiveCrime and type(CP.LiveCrime.cuffHint) == 'function' then
        local ok, err = pcall(CP.LiveCrime.cuffHint, own, officerSrc)
        if not ok then LogError('cuffHint', 'CP.LiveCrime.cuffHint failed: %s', tostring(err)) end
    end
end

-- 'uncuff' (officerSrc, targetSrc): a participant's release explains the cuffs coming off. An uncuff by someone
-- outside the case (sc-police asks only for the handcuffs item) explains nothing, but it is kept so that the note
-- names him instead of saying nobody uncuffed the suspect. His own uncuff stays a self-uncuff.
local function OnUncuff(officerSrc, targetSrc)
    local case, rec = Opp.bySrc(targetSrc)
    if not rec or rec.state ~= 'cuffed' or officerSrc == targetSrc then return end
    local now = GetGameTimer()
    if IsParticipant(case.run, officerSrc) then
        rec.uncuff = { src = officerSrc, at = now }
        if rec.freedAt then Explain(case, rec, now, false) end
        return
    end
    local ok, why = Plausible(officerSrc, targetSrc, Num(Cfg().cuffRange, 3.5))
    if not ok then
        Line(case, rec, 'uncuff_refused', { by = officerSrc, why = why, inCase = false })
        return
    end
    local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(officerSrc) or nil
    local name = info and info.name or GetPlayerName(officerSrc) or tostring(officerSrc)
    rec.outsideUncuff = { src = officerSrc, name = name, at = now }
    Line(case, rec, 'uncuffed_by_outsider', { by = officerSrc })
end

-- 'cuffBreak' (suspectSrc, officerSrc): sent by the suspect himself after sc-police's minigame.
local function OnCuffBreak(suspectSrc)
    local case, rec = Opp.bySrc(suspectSrc)
    if not rec or rec.state ~= 'cuffed' then return end
    local now = GetGameTimer()
    rec.cuffBreak = { at = now }
    if rec.freedAt then Explain(case, rec, now, false) end
end

-- 'bobbyPin' (pickerSrc, success). sc-police drops a result with no pending attempt, but this handler still sees the
-- raw success, so the checks are CP's own (critic 2 #6): not the suspect, not cuffed or down himself, and near him
-- on RESCUE_TICKS watch passes before the result. The nearest such cuffed suspect is the one he picked.
local function OnBobbyPin(pickerSrc, success)
    if success ~= true then return end
    local now = GetGameTimer()
    local best, bestCase, bestD, coords = nil, nil, math.huge, nil
    for cid in pairs(held) do
        local case, rec = Opp.byCid(cid)
        if not rec or rec.state ~= 'cuffed' then
            held[cid] = nil
        elseif rec.src ~= pickerSrc and not rec.rescued and (rec.near[pickerSrc] or 0) >= RESCUE_TICKS then
            coords = coords or ServerCoords(pickerSrc)
            local d = coords and rec.lastCoords and CP.U.dist(coords, rec.lastCoords) or math.huge
            if not best or d < bestD then best, bestCase, bestD = rec, case, d end
        end
    end
    if not best or Bucket(pickerSrc) ~= 0 then return end
    local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(pickerSrc) or nil
    local md = info and info.metadata
    if type(md) ~= 'table' or md.ishandcuffed == true or md.isdead == true or md.inlaststand == true then return end
    best.pin = { src = pickerSrc, at = now }
    Line(bestCase, best, 'bobby_pin', { by = pickerSrc })
    if best.freedAt then Explain(bestCase, best, now, false) end
end

-- 'escort' (officerSrc, targetSrc): a participant escorting a downed suspect who is not cuffed detains him at
-- neutralisedShare (0 when he was AFK).
local function OnEscort(officerSrc, targetSrc)
    local case, rec = Opp.bySrc(targetSrc)
    if not rec or rec.state ~= 'free' or not rec.down then return end
    if not IsParticipant(case.run, officerSrc) or not OnDuty(officerSrc) then return end
    if not Plausible(officerSrc, targetSrc, Num(Cfg().cuffRange, 3.5)) then return end
    local now = GetGameTimer()
    local run, cid, label, afk = case.run, rec.cid, rec.label, rec.afk
    rec.caughtBy = { officerSrc }
    rec.share = afk and 0 or Share()
    if Detain(case, rec, 'escort_down', officerSrc, now) and afk then
        Opp.note(run, 'rs_afk_catch', CP.L('opp.detail.afk_catch', { label = label }), cid)
    end
end

-- Why a participant's jail cannot be his booking (nil = it can): not detained yet (a jail during the hold), off
-- duty, or not plausible (instance, arena, distance beyond jailRange).
local function JailRefused(rec, officerSrc, targetSrc)
    if rec.state ~= 'detained' then return 'not_detained' end
    if not OnDuty(officerSrc) then return 'not_on_duty' end
    local ok, why = Plausible(officerSrc, targetSrc, Num(Cfg().jailRange, 6.0))
    if not ok then return why end
    return nil
end

-- 'jail' (officerSrc, targetSrc, jailTimeRaw): a participant's jail of a detained suspect (kept for the pair), or a
-- jail by someone outside the case of a free or cuffed one.
local function OnJail(officerSrc, targetSrc, jailTimeRaw)
    local case, rec = Opp.bySrc(targetSrc)
    if not rec or DONE[rec.state] then return end
    local now = GetGameTimer()
    local t = math.floor(Num(jailTimeRaw, 0))
    if IsParticipant(case.run, officerSrc) then
        local why = JailRefused(rec, officerSrc, targetSrc)
        if why then
            -- sc-police jails him all the same, and that injail rise can never pair later: the timeline says why
            Line(case, rec, 'jail_refused', { by = officerSrc, why = why, months = t, state = rec.state })
            return
        end
        local zone = ZoneAt(ServerCoords(officerSrc))
        rec.jail = { officerSrc = officerSrc, t = t, at = now, inZone = zone ~= nil }
        Line(case, rec, 'jail', {
            by = officerSrc,
            months = t,
            zone = type(zone) == 'table' and zone.label or nil,
        })
        TryBook(case, rec, now)
    elseif rec.state == 'free' or rec.state == 'cuffed' then
        rec.outsideJail = { src = officerSrc, t = t, at = now }
        Line(case, rec, 'outside_jail', { by = officerSrc, months = t })
        TryBook(case, rec, now)
    end
end

-- 'respawn' (src, hospitalIndex): not down, or down for less than earlyRespawnSeconds -> void (free or cuffed) and
-- a note; else spawn protection, unless officers were in contact at the down and are again now (C26).
local function OnRespawn(src)
    local case, rec = Opp.bySrc(src)
    if not rec or DONE[rec.state] then return end
    local run, now = case.run, GetGameTimer()
    local downFor = nil
    if rec.down and rec.downAt then
        downFor = now - rec.downAt
    elseif rec.downAt and rec.upAt and now - rec.upAt <= UP_GRACE_MS then
        downFor = rec.upAt - rec.downAt
    end
    local early = Ms('earlyRespawnSeconds', 400)
    if not downFor or downFor < early then
        local detail = downFor
                and CP.L('opp.detail.early_respawn', {
                    label = rec.label,
                    seconds = math.floor(downFor / 1000),
                    limit = math.floor(early / 1000),
                })
            or CP.L('opp.detail.respawn_not_down', { label = rec.label })
        if rec.state == 'free' or rec.state == 'cuffed' then
            held[rec.cid] = nil
            Opp.setState(run, rec.cid, 'void', { why = 'early_respawn' })
        end
        Opp.note(run, 'rs_early_respawn', detail, rec.cid)
        return
    end
    if rec.downNear and ParticipantNear(case, rec) then
        rec.protectUntil, rec.hospitalCatch = nil, true
        Line(case, rec, 'respawn_in_contact')
    else
        rec.protectUntil, rec.hospitalCatch = now + Ms('spawnProtectSeconds', 600), nil
        Line(case, rec, 'spawn_protect', { seconds = math.floor(Ms('spawnProtectSeconds', 600) / 1000) })
    end
end

-- ============================================================================
--                         THE WATCH PASS (V4's onTick)
-- ============================================================================

-- The online players' server coords, once per pass and only when a suspect is cuffed (CP.Qbx's event-kept list:
-- no Qbox export per tick).
local function OnlineCoords(now)
    if pass.at == now then return pass.coords end
    pass.at, pass.coords = now, {}
    local list = CP.Qbx and CP.Qbx.getOnlinePlayers and CP.Qbx.getOnlinePlayers() or {}
    for _, src in ipairs(list) do
        local c = ServerCoords(src)
        if c then pass.coords[src] = c end
    end
    return pass.coords
end

-- Rescue candidates: consecutive passes within rescueRange of a cuffed suspect, for players who are neither he nor a
-- participant of the case (reset when out of range).
local function CountNear(case, rec, now)
    if not rec.src or not rec.lastCoords then return end
    local range = Num(Cfg().rescueRange, 4.0)
    local near = {}
    for src, c in pairs(OnlineCoords(now)) do
        if src ~= rec.src and CP.U.dist(c, rec.lastCoords) <= range and not IsParticipant(case.run, src) then
            near[src] = (rec.near[src] or 0) + 1
        end
    end
    rec.near = near
end

-- Once per case on every watch pass: the custody hold, the wait for a cuff-break alert, the rescue candidates. With
-- no suspect cuffed this reads nothing.
local function Tick(case, now)
    local holdMs = Ms('custodyHoldSeconds', 30)
    for _, cid in ipairs(case.order) do
        if Opp.caseOf(case.runId) ~= case then return end
        local rec = case.suspects[cid]
        if rec.state == 'cuffed' then
            held[cid] = true
            if rec.freedAt then
                if now - rec.freedAt >= SETTLE_MS then Explain(case, rec, now, true) end
            elseif rec.md.ishandcuffed == true and now - (rec.cuffedAt or now) >= holdMs then
                Detain(case, rec, 'custody_hold', rec.caughtBy and rec.caughtBy[1] or nil, now)
            else
                CountNear(case, rec, now)
            end
        end
    end
end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    held, pass = {}, { at = -1, coords = {} }
end)

-- The other modules load in any order (fxmanifest globs): register once they are all loaded.
CreateThread(function()
    Wait(0)
    local P, A = CP.ScPolice, CP.Ambulance
    if P and P.on then
        P.on('cuff', OnCuff)
        P.on('uncuff', OnUncuff)
        P.on('cuffBreak', OnCuffBreak)
        P.on('bobbyPin', OnBobbyPin)
        P.on('escort', OnEscort)
        P.on('jail', OnJail)
    else
        CP.err(TAG, 'modules/integrations/sc_police is missing: real suspects can never be detained or booked')
    end
    if A and A.on then
        A.on('respawn', OnRespawn)
    else
        CP.err(TAG, 'modules/integrations/sc_ambulance is missing: hospital respawns of real suspects are not seen')
    end
    if Opp.onTick then
        Opp.onTick(Tick)
    else
        CP.err(TAG, 'modules/opponents is missing: the custody hold cannot run')
    end
end)

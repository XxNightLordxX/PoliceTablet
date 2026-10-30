-- CP.Opponents conduct (server, step V6): how officers treat a real suspect, from server facts only. The armed

CP.Opponents = CP.Opponents or {}
local Opp = CP.Opponents
local TAG = 'opponents'

local MAX_HITS = 32               -- victims read from one weaponDamageEvent (as CP.Npc)
local MAX_NETID = 0xFFFFFF
local MERGE_MS = 2000             -- the same shooter, victim and weapon again this soon adds to the last ledger line
local SEIZE_RANGE = 3.0           -- metres: a cash seizure from further away is not an arrest search (sc-police: 2.5)

local DONE = { lost = true, left = true, void = true }
local CUSTODY = { cuffed = true, detained = true }                  -- CP's own proven states (C7); see Restrained()
-- A cash seizure asks whether he was arrested (CP's proven states), not whether he is still cuffed: on purpose
local SEIZE_OK = { cuffed = true, detained = true, booked = true }
local STATE_KEY = {
    free = 'opp.state.free',
    cuffed = 'opp.state.cuffed',
    detained = 'opp.state.detained',
    booked = 'opp.state.booked',
    lost = 'opp.state.lost',
    left = 'opp.state.left',
    void = 'opp.state.void',
}

local function U32(h) return (math.tointeger(tonumber(h) or 0) or 0) & 0xFFFFFFFF end

local UNARMED = U32(joaat('WEAPON_UNARMED'))
local RUN_OVER = U32(joaat('WEAPON_RUN_OVER_BY_CAR'))
local RAMMED = U32(joaat('WEAPON_RAMMED_BY_CAR'))
local FALL = U32(joaat('WEAPON_FALL'))

local lessCache = { list = false, set = {} }   -- Config.RealSuspects.lessLethal hashed once (again after a change)
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

local function Ms(key, default) return math.max(0, Num(Cfg()[key], default)) * 1000 end

local function LogError(key, fmt, ...)
    local now = os.time()
    if errorAt[key] and now - errorAt[key] < 60 then return end
    errorAt[key] = now
    CP.err(TAG, fmt, ...)
end

local function ToInt(v, lo, hi)
    if type(v) ~= 'number' or v ~= v then return nil end
    local n = math.tointeger(v)
    if not n or n < lo or n > hi then return nil end
    return n
end

-- FXServer's BOOL natives answer 1 for yes (false for no), never true: truthiness only.
local function Exists(e)
    if type(e) ~= 'number' or e == 0 then return false end
    local found = DoesEntityExist(e)
    return found == true or found == 1
end

local function IsPlayerPed(e) return Exists(e) and IsPedAPlayer(e) and true or false end

local function OwnerOf(e)
    local ok, o = pcall(NetworkGetEntityOwner, e)
    o = ok and tonumber(o) or nil
    o = o and math.tointeger(o)
    if o and o > 0 then return o end
    return nil
end

local function Bucket(src)
    if type(GetPlayerRoutingBucket) ~= 'function' then return 0 end
    local ok, b = pcall(GetPlayerRoutingBucket, src)
    if not ok then return 0 end
    return tonumber(b) or 0
end

local function PedOf(src)
    local ped = src and GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    return ped
end

local function IsParticipant(run, src)
    return CP.Runs ~= nil and CP.Runs.isParticipant ~= nil and CP.Runs.isParticipant(run, src) == true
end

-- The run of an active participant, and its case (nil, nil when he has no run or it has no case).
local function OfficerCase(src)
    if not (CP.Runs and CP.Runs.getBySrc) then return nil end
    local run = CP.Runs.getBySrc(src)
    if type(run) ~= 'table' then return nil end
    local case = Opp.caseOf(run)
    if not case then return nil end
    return run, case
end

local function StateText(state) return CP.L(STATE_KEY[state] or 'opp.state.free') end

-- Still restrained: CP's own proven 'cuffed' or 'detained' state AND the event-kept cuffs mirror (C7 forbids raw
-- metadata on its own, not both together). 'detained' never goes back to 'free' (a self-uncuff, an escort of a downed
-- suspect, a bobby pin after the hold), and a 'cuffed' rec whose cuffs came off (rec.freedAt) waits for its
-- explanation: neither is restrained.
local function Restrained(rec)
    if not CUSTODY[rec.state] or (rec.state == 'cuffed' and rec.freedAt) then return false end
    return type(rec.md) == 'table' and rec.md.ishandcuffed == true
end

-- In custody for excessive force: restrained, or detained and down for more than downGrace (sc-ambulance disables
-- every control while he is down). A suspect who freed himself, was revived or was rescued is not: what he does then
-- can never hold an officer's points (critic 2 #12).
local function InCustody(rec, now)
    if Restrained(rec) then return true end
    return rec.state == 'detained' and rec.down == true and rec.downAt ~= nil and now - rec.downAt > Ms('downGrace', 3)
end

-- Config.RealSuspects.lessLethal as a set of weapon hashes: hashed once, again when the list or a setting changes.
local function LessLethal()
    local list = Cfg().lessLethal
    if list ~= lessCache.list then
        local set = {}
        for _, name in ipairs(type(list) == 'table' and list or {}) do
            if type(name) == 'string' and name ~= '' then set[U32(joaat(name))] = true end
        end
        lessCache.list, lessCache.set = list, set
    end
    return lessCache.set
end

-- A gun (or any weapon that is not a fist or less-lethal) in the hand: counts as armed.
local function IsArmedWeapon(w) return w ~= 0 and w ~= UNARMED and not LessLethal()[w] end

-- A hit that is a "shot": not less-lethal, not a fist, not a vehicle (the ran-over rule) and not a fall. Ramming a
-- fleeing car is never penalised.
local function IsShot(w) return w ~= UNARMED and w ~= RUN_OVER and w ~= RAMMED and w ~= FALL and not LessLethal()[w] end

local function WeaponOf(src)
    local ped = PedOf(src)
    if not ped or type(GetSelectedPedWeapon) ~= 'function' then return 0 end
    local ok, w = pcall(GetSelectedPedWeapon, ped)
    if not ok then return 0 end
    return U32(w)
end

local function Line(case, rec, what, extra)
    local entry = { what = what, label = rec.label, src = rec.src }
    for k, v in pairs(extra or {}) do entry[k] = v end
    Opp.timeline(case.run, entry)
end

-- ============================================================================
--                                  ARMED (C6)
-- ============================================================================

-- Armed: the server saw a weapon in his hand (kept armedMemory s), he hit someone of the case, or Crimson-Contracts
-- reported a crew shot by him (Opp.noteArmed). The first time is a timeline line.
local function MarkArmed(case, rec, why, now)
    if why == 'weapon' then rec.armedUntil = now + Ms('armedMemory', 15) end
    if not rec.everArmed then
        rec.everArmed = true
        Line(case, rec, 'armed', { why = why })
    end
end

local function SeeWeapon(case, rec, now)
    if IsArmedWeapon(WeaponOf(rec.src)) then MarkArmed(case, rec, 'weapon', now) end
end

-- armedNow (a weapon seen within armedMemory), everArmed (any of the three in this case), for later steps.
function Opp.armedState(cid)
    local _, rec = Opp.byCid(cid)
    if not rec then return false, false end
    return (rec.armedUntil or 0) > GetGameTimer(), rec.everArmed == true
end

-- ============================================================================
--                                  THE LEDGER
-- ============================================================================

-- One line per hit between a case's officer and its suspect, capped at damageLogMax (the oldest goes first); the same
-- shooter, victim and weapon again within MERGE_MS adds to the last line ({ n }) so a burst stays one line.
local function Ledger(case, entry, now)
    local list = case.ledger
    local last = list[#list]
    if last and last.from == entry.from and last.to == entry.to and last.weapon == entry.weapon
        and now - last.lastAt <= MERGE_MS then
        last.n, last.lastAt = last.n + 1, now
        last.willKill = last.willKill or entry.willKill
        return last
    end
    entry.t, entry.at, entry.lastAt, entry.n = os.time(), now, now, 1
    list[#list + 1] = entry
    local max = math.max(1, math.floor(Num(Cfg().damageLogMax, 200)))
    while #list > max do table.remove(list, 1) end
    return entry
end

local function Mark(entry, reason)
    entry.rules = entry.rules or {}
    for _, r in ipairs(entry.rules) do if r == reason then return end end
    entry.rules[#entry.rules + 1] = reason
end

-- An officer-conduct flag on the officer who fired or drove (his points are held; never his partner's), once per
-- officer and suspect for each reason. CP.AntiCheat.flag refuses anyone who is not a participant of the run.
local function Flag(case, rec, officerSrc, reason, detail, entry)
    rec.conduct = rec.conduct or {}
    local seen = rec.conduct[reason] or {}
    rec.conduct[reason] = seen
    if seen[officerSrc] then return false end
    seen[officerSrc] = true
    Mark(entry, reason)
    Line(case, rec, reason, { by = officerSrc, detail = detail })
    if CP.AntiCheat and CP.AntiCheat.flag then
        local ok, err = pcall(CP.AntiCheat.flag, case.run, officerSrc, reason, detail)
        if not ok then LogError('flag', 'CP.AntiCheat.flag failed: %s', tostring(err)) end
    end
    return true
end

-- The personal penalty (CP.Runs.penalize with opts.src: only that officer's row), once per officer and suspect.
local function Penalize(case, rec, officerSrc, id)
    rec.penalized = rec.penalized or {}
    local seen = rec.penalized[id] or {}
    rec.penalized[id] = seen
    if seen[officerSrc] then return false end
    seen[officerSrc] = true
    if not (CP.Runs and CP.Runs.penalize) then return false end
    local ok, res = pcall(CP.Runs.penalize, case.run, id, { src = officerSrc })
    if not ok then LogError('penalize', 'CP.Runs.penalize failed: %s', tostring(res)) end
    return ok and res ~= false
end

-- ============================================================================
--                           HITS (weaponDamageEvent)
-- ============================================================================

-- An officer of the case hit his suspect: excessive force (in custody, or down for more than downGrace after earlier
-- hits), the unarmed-shot penalty, the ran-over penalty. Nothing here ends or fails the run.
local function OfficerHit(case, rec, officerSrc, weapon, entry, now)
    local label = rec.label
    -- he may have drawn since the last watch pass: the server looks at his hand now too
    SeeWeapon(case, rec, now)
    if InCustody(rec, now) then
        Flag(case, rec, officerSrc, 'rs_excessive_force',
            CP.L('opp.detail.force_custody', { label = label, state = StateText(rec.state) }), entry)
    elseif rec.down and rec.downAt and now - rec.downAt > Ms('downGrace', 3) and rec.firstHitAt
        and rec.firstHitAt < rec.downAt then
        Flag(case, rec, officerSrc, 'rs_excessive_force', CP.L('opp.detail.force_down', {
            label = label,
            seconds = math.floor((now - rec.downAt) / 1000),
        }), entry)
    end
    if IsShot(weapon) and not rec.everArmed and (rec.armedUntil or 0) < now then
        Penalize(case, rec, officerSrc, 'rs_unarmed_shot')
        Flag(case, rec, officerSrc, 'rs_unarmed_shot', CP.L('opp.detail.unarmed_shot', { label = label }), entry)
    end
    if weapon == RUN_OVER or weapon == RAMMED then
        -- on foot only: ramming the car he flees in is never penalised
        local ped = PedOf(rec.src)
        local veh = ped and GetVehiclePedIsIn(ped, false) or 0
        if ped and (not veh or veh == 0) then
            Penalize(case, rec, officerSrc, 'rs_ran_over')
            Flag(case, rec, officerSrc, 'rs_vdm', CP.L('opp.detail.ran_over', { label = label }), entry)
        end
    end
    rec.firstHitAt = rec.firstHitAt or now
    rec.lastHitAt = now
end

-- The player a weapon damage packet is blamed on: always its sender (a forged packet never costs a third party),
-- except when the damage came from an NPC the sender simulates (a ped, or a car an NPC drives), which is nobody, as
-- CP.Npc's ShooterOf reads it.
local function Blame(src, data)
    local parent = ToInt(tonumber(data.parentGlobalId), 1, MAX_NETID)
    if not parent then return src end
    local pe = NetworkGetEntityFromNetworkId(parent)
    if not Exists(pe) then return src end
    local t = GetEntityType(pe)
    local ped = t == 2 and GetPedInVehicleSeat(pe, -1) or (t == 1 and pe or 0)
    if Exists(ped) and not IsPedAPlayer(ped) and OwnerOf(pe) == src then return nil end
    return src
end

-- The player behind a hit net id, or nil (not a player's ped). A player's ped is always simulated by his own game.
local function VictimOf(netId)
    local ent = NetworkGetEntityFromNetworkId(netId)
    if not IsPlayerPed(ent) then return nil end
    return OwnerOf(ent)
end

local function OnDamage(src, data)
    -- who sent it: a suspect of a case, or an active participant of a run with a case; anyone else reads nothing
    local sCase, sRec = Opp.bySrc(src)
    local _, oCase = OfficerCase(src)
    if not sRec and not oCase then return end
    local hits = data.hitGlobalIds
    if type(hits) ~= 'table' then
        local one = tonumber(data.hitGlobalId)
        if not one then return end
        hits = { one }
    end
    if #hits == 0 or Bucket(src) ~= 0 then return end
    if Blame(src, data) ~= src then return end
    local weapon = U32(data.weaponType)
    local willKill = data.willKill == true
    local now = GetGameTimer()
    local done = {}
    for i = 1, math.min(#hits, MAX_HITS) do
        local netId = ToInt(tonumber(hits[i]), 1, MAX_NETID)
        local victim = netId and not done[netId] and VictimOf(netId) or nil
        if netId then done[netId] = true end
        if victim and victim ~= src and Bucket(victim) == 0 then
            local vCase, vRec = Opp.bySrc(victim)
            if oCase and vCase == oCase and not DONE[vRec.state] then
                local entry = Ledger(oCase, {
                    dir = 'officer',
                    from = src,
                    to = victim,
                    cid = vRec.cid,
                    label = vRec.label,
                    weapon = weapon,
                    willKill = willKill,
                    state = vRec.state,
                    down = vRec.down == true,
                }, now)
                OfficerHit(oCase, vRec, src, weapon, entry, now)
            elseif sRec and not DONE[sRec.state] and IsParticipant(sCase.run, victim) then
                Ledger(sCase, {
                    dir = 'suspect',
                    from = src,
                    to = victim,
                    cid = sRec.cid,
                    label = sRec.label,
                    weapon = weapon,
                    willKill = willKill,
                }, now)
                MarkArmed(sCase, sRec, 'damage', now)
            end
        end
    end
end

-- A third read-only listener of the game event (CP.Npc has two): it never cancels it and reads nothing while no case
-- with a real suspect is open.
AddEventHandler('weaponDamageEvent', function(sender, data)
    local src = tonumber(sender) or tonumber(source)
    if not (Opp.active and Opp.active()) then return end
    src = src and math.tointeger(src)
    if not src or src <= 0 or type(data) ~= 'table' or WasEventCanceled() then return end
    local ok, err = pcall(OnDamage, src, data)
    if not ok then LogError('damage', 'weaponDamageEvent from %s failed: %s', tostring(src), tostring(err)) end
end)

-- ============================================================================
--                          CASH SEIZURES (sc-police)
-- ============================================================================

-- 'seizeCash' (officerSrc, targetSrc), only while a case is open (V3). sc-police acts only for an on-duty 'leo' job
-- (anyone else's event is ignored here too), and it moves nothing when the target has no cash; whether this handler
-- runs before or after its own is not known, so every record says "used Seize Cash" (an attempt). An attempt by an
-- officer on a case, or any attempt on a suspect, is audited (the officer, whether the target is a suspect of his
-- case, the server distance, CP-cuffed). One on a suspect who is not under arrest (SEIZE_OK), or from more than
-- SEIZE_RANGE away, flags the officer when he is a participant of that case (his own conduct, with or without cash);
-- anyone else cannot be flagged on its run, so it is a staff note.
local function SeizingOfficer(src)
    local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(src) or nil
    local job = info and info.job
    return type(job) == 'table' and job.type == 'leo' and job.onduty == true, info
end

local function OnSeize(officerSrc, targetSrc)
    if officerSrc == targetSrc then return end
    local _, ownCase = OfficerCase(officerSrc)
    local tCase, rec = Opp.bySrc(targetSrc)
    if not ownCase and not rec then return end
    local leo, info = SeizingOfficer(officerSrc)
    if not leo then return end
    local a, b = PedOf(officerSrc), PedOf(targetSrc)
    local metres = a and b and CP.U.dist(GetEntityCoords(a), GetEntityCoords(b)) or nil
    local shown = metres and ('%.1f'):format(metres) or '?'
    local which = not rec and 'not_suspect' or (tCase == ownCase and 'own_suspect' or 'other_case')
    local case = tCase or ownCase
    local cuffed = rec ~= nil and Restrained(rec)
    local target = rec
            and CP.L(which == 'own_suspect' and 'opp.seize.own_suspect' or 'opp.seize.other_case',
                { label = rec.label })
        or CP.L('opp.seize.not_suspect')
    local reason = CP.L('opp.audit.seize_cash', {
        target = target,
        metres = shown,
        cuffed = CP.L(cuffed and 'common.yes' or 'common.no'),
    })
    if CP.Admin and CP.Admin.audit then
        -- a listener must not yield (the audit row is a database write): its own thread
        local runId, state = case.runId, rec and rec.state or '-'
        CreateThread(function()
            local ok, err = pcall(CP.Admin.audit, officerSrc, nil, 'flags', 'seizeCash', runId, which, state, reason)
            if not ok then LogError('audit', 'the seizeCash audit failed: %s', tostring(err)) end
        end)
    end
    if not rec or rec.state == 'void' then return end
    if SEIZE_OK[rec.state] and metres and metres <= SEIZE_RANGE then return end
    local params = { label = rec.label, state = StateText(rec.state), metres = shown }
    if IsParticipant(tCase.run, officerSrc) then
        local detail = CP.L('opp.detail.bad_seize', params)
        Line(tCase, rec, 'rs_bad_seize', { by = officerSrc, detail = detail })
        if CP.AntiCheat and CP.AntiCheat.flag then
            local ok, err = pcall(CP.AntiCheat.flag, tCase.run, officerSrc, 'rs_bad_seize', detail)
            if not ok then LogError('flag', 'CP.AntiCheat.flag failed: %s', tostring(err)) end
        end
    else
        params.name = info and info.name or GetPlayerName(officerSrc) or tostring(officerSrc)
        params.by = officerSrc
        Opp.note(tCase.run, 'rs_bad_seize', CP.L('opp.detail.bad_seize_outsider', params), rec.cid)
    end
end

-- ============================================================================
--                         THE WATCH PASS (V4's onTick)
-- ============================================================================

-- Once per case on every watch pass: the weapon in each tracked suspect's hand (GetPlayerPed and
-- GetSelectedPedWeapon only; no Qbox export, no database).
local function Tick(case, now)
    for _, cid in ipairs(case.order) do
        if Opp.caseOf(case.runId) ~= case then return end
        local rec = case.suspects[cid]
        if rec.src and not DONE[rec.state] and not rec.inInstance then SeeWeapon(case, rec, now) end
    end
end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    lessCache = { list = false, set = {} }
end)

-- The other modules load in any order (fxmanifest globs): register once they are all loaded.
CreateThread(function()
    Wait(0)
    if CP.Hooks and CP.Hooks.on then
        CP.Hooks.on('settings:changed', function() lessCache.list = false end)
    end
    local P = CP.ScPolice
    if P and P.on then
        P.on('seizeCash', OnSeize)
    else
        CP.err(TAG, 'modules/integrations/sc_police is missing: cash seizures from real suspects are not audited')
    end
    if Opp.onTick then
        Opp.onTick(Tick)
    else
        CP.err(TAG, 'modules/opponents is missing: the weapon a suspect holds is never seen')
    end
end)

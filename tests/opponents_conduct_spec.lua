-- CP.Opponents conduct (step V6): the armed definition (C6), the damage ledger between a case's officers and its

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
_G.GetConvar = function(_, default) return default end
_G.PerformHttpRequest = function() end

-- GetHashKey / joaat as the game hashes (Jenkins one-at-a-time of the lower-case name, a signed 32-bit answer): the
-- harness's own joaat hashes the length only, and WEAPON_STUNGUN and WEAPON_UNARMED are both 14 letters long.
local function Jenkins(s)
    s = tostring(s):lower()
    local h = 0
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xFFFFFFFF
        h = (h + (h << 10)) & 0xFFFFFFFF
        h = h ~ (h >> 6)
    end
    h = (h + (h << 3)) & 0xFFFFFFFF
    h = h ~ (h >> 11)
    h = (h + (h << 15)) & 0xFFFFFFFF
    return h
end
_G.joaat = function(s)
    local h = Jenkins(s)
    if h >= 0x80000000 then h = h - 0x100000000 end
    return h
end
_G.GetHashKey = _G.joaat
H.eq(Jenkins('WEAPON_UNARMED'), 0xA2719263, 'the spec hashes like the game (WEAPON_UNARMED)')

local function Copy(v)
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, x in pairs(v) do out[k] = Copy(x) end
    return setmetatable(out, getmetatable(v))
end

-- ============================================================================
--                        qbx_core, NATIVES AND COUNTERS
-- ============================================================================

local players = {}   -- [src] = a loaded character's Player ({ PlayerData = ... })
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

-- Player peds are src * 100 (the harness); their net ids NET(src). Modelled NPCs and cars use H.entity.
local function NET(src) return 7000 + src end
local reads = {}     -- native name -> calls
local function Count(name) reads[name] = (reads[name] or 0) + 1 end
local function PlayerOfPed(ped)
    if type(ped) ~= 'number' or ped <= 0 or ped >= 800000 or ped % 100 ~= 0 then return nil end
    local src = ped // 100
    return H.players[src] and src or nil
end
local modelNet = _G.NetworkGetEntityFromNetworkId
_G.NetworkGetEntityFromNetworkId = function(netId)
    Count('NetworkGetEntityFromNetworkId')
    local n = math.tointeger(tonumber(netId) or -1) or -1
    if n > 7000 and n < 8000 and H.players[n - 7000] then return (n - 7000) * 100 end
    return modelNet(netId)
end
local owners = {}    -- [entity handle] = the server id that simulates it (modelled NPCs and cars)
_G.NetworkGetEntityOwner = function(ent)
    Count('NetworkGetEntityOwner')
    local src = PlayerOfPed(ent)
    if src then return src end
    return owners[ent] or -1
end
-- IS_PED_A_PLAYER is a server BOOL native: the harness answers 1 / false for this function
_G.IsPedAPlayer = function(ped)
    Count('IsPedAPlayer')
    return PlayerOfPed(ped) ~= nil
end
_G.GetEntityType = function(ent)
    local e = H.entityModel.byHandle[ent]
    if e then return e.kind == 'vehicle' and 2 or (e.kind == 'ped' and 1 or 3) end
    return PlayerOfPed(ent) and 1 or 0
end
local UNARMED_U = Jenkins('WEAPON_UNARMED')
local weapons = {}   -- [src] = the weapon name in his hand (the server's GetSelectedPedWeapon answers a Hash)
_G.GetSelectedPedWeapon = function(ped)
    Count('GetSelectedPedWeapon')
    local src = PlayerOfPed(ped)
    return src and weapons[src] and Jenkins(weapons[src]) or UNARMED_U
end

local function Character(src, cid, coords, job, onduty)
    H.players[src] = H.players[src] or {}
    H.players[src].coords = coords or vec3(0.0, 0.0, 30.0)
    H.players[src].ace = H.players[src].ace or {}
    return {
        PlayerData = {
            source = src,
            citizenid = cid,
            license = 'license:' .. cid:lower(),
            charinfo = { firstname = 'First' .. src, lastname = 'Last' },
            job = {
                name = job or 'unemployed',
                label = job or 'Civilian',
                type = job and 'leo' or nil,   -- the police jobs here are type 'leo' (what sc-police's SeizeCash asks)
                onduty = onduty == true,
                grade = { level = 1 },
            },
            metadata = { ishandcuffed = false, isdead = false, inlaststand = false, injail = 0 },
        },
    }
end
local function Load(src, cid, coords, job, onduty)
    players[src] = Character(src, cid, coords, job, onduty)
    TriggerEvent('QBCore:Server:PlayerLoaded', Copy(players[src]))
end
local function Move(src, coords) H.players[src].coords = coords end

-- qbx_core's SetMetaData: the value is written, then onSetMetaData(key, old, new, src) fires at once (a TriggerEvent).
local function SetMeta(src, key, value)
    local md = players[src].PlayerData.metadata
    local old = md[key]
    md[key] = value
    TriggerEvent('qbx_core:server:onSetMetaData', key, old, value, src)
end

-- ============================================================================
--                                   MODULES
-- ============================================================================

local function Quiet(path)
    local thread = _G.CreateThread
    _G.CreateThread = function() end
    local ok, err = pcall(H.load, path)
    _G.CreateThread = thread
    if not ok then error(err, 2) end
end

local audits, flags, penalties, ends = {}, {}, {}, 0
local runsBySrc = {}
CP.Admin = {
    audit = function(...) audits[#audits + 1] = { ... } end,
}
CP.Tablet = {
    notify = function() return true end,
    notifyMany = function(srcs) return #srcs end,
}
-- CP.Runs' participant API and Record's personal form (modules/runs/server.lua: opts.src scores only that officer)
CP.Runs = {
    dispatch = function() return true end,
    isParticipant = function(run, src)
        local p = type(run) == 'table' and run.participants and run.participants[tonumber(src)]
        return p ~= nil and p.status == 'active'
    end,
    getBySrc = function(src)
        local run = runsBySrc[tonumber(src)]
        local p = run and run.participants[tonumber(src)]
        if not p or p.status ~= 'active' or run.state == 'ended' then return nil end
        return run, p
    end,
    penalize = function(run, id, opts)
        if type(run) ~= 'table' or run.state == 'ended' then return false end
        local src = opts and tonumber(opts.src)
        if src then
            local p = run.participants[src]
            if not p then return false end
            p.score[id] = (p.score[id] or 0) + 1
        else
            run.score.shared[id] = (run.score.shared[id] or 0) + 1
        end
        run.score.kinds[id] = 'penalty'
        penalties[#penalties + 1] = { run = run, id = id, src = src }
        return true
    end,
    endRun = function() ends = ends + 1 end,
    failRun = function() ends = ends + 1 end,
}
CP.Alerts = {
    foreignFlag = function() return false end,
    inArena = function(src) return (bucket[tonumber(src)] or 0) ~= 0 end,
}
CP.AntiCheat = H.realAntiCheat()
do
    local realFlag = CP.AntiCheat.flag
    CP.AntiCheat.flag = function(...)
        flags[#flags + 1] = { ... }
        return realFlag(...)
    end
end
CP.Payouts = {
    baseFor = function() return 500 end,
    sourceFor = function() return 'type' end,
}
Quiet('modules/cash/server.lua')
CP.Qbx = {
    onDutyChange = function() end,
    onGroupUpdate = function() end,
    onJobChange = function() end,
    onPlayerLoaded = function() end,
    onPlayerUnload = function() end,
    getOnlinePlayers = function() return {} end,
}
H.load('modules/access/server.lua')
CP.Qbx = nil
H.load('modules/integrations/qbx/server.lua')
H.load('modules/integrations/sc_police/server.lua')
H.load('modules/integrations/sc_ambulance/server.lua')
H.load('modules/opponents/server.lua')
H.load('modules/opponents/proof/server.lua')
H.load('modules/opponents/conduct/server.lua')
H.load('modules/scaling/server.lua')
H.load('modules/scoring/server.lua')
H.step(0)
local Opp = CP.Opponents
local RS = Config.RealSuspects

-- ============================================================================
--                                    SCENES
-- ============================================================================

-- officers 1 and 2 (SAST, on duty) are the case's participants; 3 is on duty but not in the case; 21 a bystander
Load(1, 'OFF00001', vec3(0.0, 0.0, 30.0), 'sast', true)
Load(2, 'OFF00002', vec3(2.0, 0.0, 30.0), 'sast', true)
Load(3, 'OFF00003', vec3(0.0, 2.0, 30.0), 'sast', true)
Load(21, 'BYST0021', vec3(-300.0, 300.0, 30.0))

local runSeq, runs = 0, {}
local function NewRun(officers)
    runSeq = runSeq + 1
    local run = {
        id = ('run-%04d'):format(runSeq),
        missionId = 'live_crime',
        seed = 91 + runSeq,
        state = 'in_progress',
        order = {},
        participants = {},
        score = { shared = {}, kinds = {}, values = {} },
        cashBase = 500,
    }
    for _, src in ipairs(officers) do
        run.order[#run.order + 1] = src
        run.participants[src] = { src = src, citizenid = ('OFF%05d'):format(src), status = 'active', score = {} }
        runsBySrc[src] = run
    end
    runs[#runs + 1] = run
    return run
end

local nextSrc = 40
-- A fresh case with one suspect next to officers 1 and 2.
local function Scene(cid, opts)
    opts = opts or {}
    nextSrc = nextSrc + 1
    local src = nextSrc
    local at = vec3(0.0, 0.0, 30.0)
    H.resetNetLimits()
    local run = NewRun(opts.officers or { 1, 2 })
    Load(src, cid, vec3(at.x + 1.0, at.y + 1.0, at.z))
    Move(1, at)
    Move(2, vec3(at.x + 2.0, at.y, at.z))
    Move(3, vec3(at.x, at.y + 2.0, at.z))
    local case = Opp.open(run, { kind = 'live', members = { cid } })
    H.step(0)
    return run, case, case.suspects[cid], src
end

local function Tick(seconds) H.advance((seconds or 1) * 1000, 1000) end

-- One weaponDamageEvent from `from`'s game: weaponType as the event carries it (an unsigned hash), the victim's net
-- id, and the damage's parent (the sender's own ped unless the packet says otherwise). Returns whether any handler
-- cancelled it.
local function Hit(from, to, weapon, extra)
    local data = {
        weaponType = Jenkins(weapon),
        hitGlobalId = NET(to),
        willKill = false,
        parentGlobalId = NET(from),
        weaponDamage = 30,
    }
    for k, v in pairs(extra or {}) do data[k] = v end
    return H.fire('weaponDamageEvent', from, from, data)
end

local function Seize(officer, target) H.fire('police:server:SeizeCash', officer, target) end

local function FlagsOf(run, reason)
    local out = {}
    for _, f in ipairs(flags) do
        if f[1] == run and f[3] == reason then out[#out + 1] = f end
    end
    return out
end
local function PenaltiesOf(run, id)
    local out = {}
    for _, p in ipairs(penalties) do
        if p.run == run and p.id == id then out[#out + 1] = p end
    end
    return out
end
local function Audited(action)
    local out = {}
    for _, a in ipairs(audits) do if a[4] == action then out[#out + 1] = a end end
    return out
end
local function NotesOf(case, reason)
    local out = {}
    for _, n in ipairs(case.notes) do if n.what == reason then out[#out + 1] = n end end
    return out
end
local function CashStatus(run, src)
    local p = run.participants[src]
    p.result = 'completed'
    local _, info = CP.Cash.compute(run, p)
    p.result = nil
    return info.status
end

-- ============================================================================
--                         SHIPPED VALUES (config.lua)
-- ============================================================================

do
    H.eq(table.concat(RS.lessLethal or {}, ','), 'WEAPON_STUNGUN,WEAPON_STUNGUN_MP,WEAPON_NIGHTSTICK,WEAPON_FLASHLIGHT',
        'lessLethal: the taser (both), the baton and the flashlight')
    H.eq(RS.armedMemory, 15, 'armedMemory ships 15 s')
    H.eq(RS.downGrace, 3, 'downGrace ships 3 s')
    H.eq(RS.damageLogMax, 200, 'damageLogMax ships 200')
    for _, id in ipairs({ 'rs_unarmed_shot', 'rs_ran_over' }) do
        local b = Config.Bonuses[id] or {}
        H.eq(b.kind, 'pct', id .. ' is a share of P')
        H.eq(b.value, -0.25, id .. ' is -25%')
        H.eq(b.each, true, id .. ' counts each time')
        H.eq(b.engineOnly, true, id .. ' is engine-only (never offered in the Builder)')
        H.ok(CP.Locale.has('penalty.' .. id), id .. ' has its penalty label')
    end
    for _, reason in ipairs({ 'rs_excessive_force', 'rs_unarmed_shot', 'rs_vdm', 'rs_bad_seize' }) do
        H.ok(CP.Locale.has('flag.' .. reason), 'flag.' .. reason .. ' has its line')
    end
    H.ok(CP.Locale.has('admin.action.seizeCash'), 'the seizeCash audit action has its label')
end

-- ============================================================================
--                    (a) NO CASE: THE HANDLER READS NOTHING
-- ============================================================================

do
    H.eq(Opp.active(), false, '(a) no case is open')
    reads = {}
    Hit(1, 21, 'WEAPON_PISTOL')
    Hit(21, 1, 'WEAPON_PISTOL')
    H.eq(next(reads), nil, '(a) no case: weaponDamageEvent reads no native (count = 0)')
    Seize(1, 21)
    H.step(0)
    H.eq(#audits, 0, '(a) no case: a cash seizure is not audited')
    -- with a case open, a packet from someone who is neither its officer nor its suspect reads nothing either
    local run = Scene('NOCA0001')
    reads = {}
    Hit(21, 3, 'WEAPON_PISTOL')
    Hit(3, 21, 'WEAPON_PISTOL')
    H.eq(next(reads), nil, '(a) a stranger\'s packet reads no native while a case is open')
    Opp.close(run)
end

-- ============================================================================
--                                (b) ARMED (C6)
-- ============================================================================

do
    -- by the weapon sample on the watch pass, kept armedMemory s
    local run, case, rec, src = Scene('ARMD0001')
    weapons[src] = 'WEAPON_STUNGUN'
    Tick(2)
    H.eq(rec.everArmed, false, '(b) a taser in his hand is not armed')
    weapons[src] = 'WEAPON_FLASHLIGHT'
    Tick(2)
    H.eq(rec.everArmed, false, '(b) nor a flashlight')
    reads = {}
    Tick(3)
    H.eq(reads.GetSelectedPedWeapon, 3, '(b) one weapon read per suspect per watch pass')
    weapons[src] = 'WEAPON_PISTOL'
    Tick(1)
    local now = GetGameTimer()
    H.eq(rec.everArmed, true, '(b) a pistol seen in his hand: armed')
    H.ok(rec.armedUntil and rec.armedUntil > now and rec.armedUntil <= now + 15000, '(b) armedUntil = now + 15 s')
    local armedNow, ever = Opp.armedState('ARMD0001')
    H.ok(armedNow and ever, '(b) armedState: armed now and armed in this case')
    weapons[src] = nil
    Tick(RS.armedMemory + 1)
    armedNow, ever = Opp.armedState('ARMD0001')
    H.eq(armedNow, false, '(b) the sample expires after armedMemory')
    H.eq(ever, true, '(b) and he stays armed in this case')
    Hit(1, src, 'WEAPON_PISTOL')
    H.eq(#PenaltiesOf(run, 'rs_unarmed_shot'), 0, '(b) a pistol hit on a suspect seen armed: no penalty')
    H.eq(#FlagsOf(run, 'rs_unarmed_shot'), 0, '(b) and no flag')
    local armedLines = 0
    for _, e in ipairs(case.timeline) do if e.what == 'armed' then armedLines = armedLines + 1 end end
    H.eq(armedLines, 1, '(b) one timeline line when he is first armed')
    Opp.close(run)

    -- by damage dealt to an officer of the case (a punch counts)
    run, case, rec, src = Scene('ARMD0002')
    Hit(src, 1, 'WEAPON_UNARMED')
    H.eq(rec.everArmed, true, '(b) a suspect who hit an officer of the case is armed')
    H.eq(case.ledger[1] and case.ledger[1].dir, 'suspect', '(b) the hit is in the ledger (suspect -> officer)')
    H.eq(case.ledger[1] and case.ledger[1].from, src, '(b) from the suspect')
    H.eq(case.ledger[1] and case.ledger[1].to, 1, '(b) to the officer')
    Hit(2, src, 'WEAPON_PISTOL')
    H.eq(#PenaltiesOf(run, 'rs_unarmed_shot'), 0, '(b) then an officer\'s pistol hit costs nothing')
    Opp.close(run)

    -- a suspect hitting a bystander is not in the ledger and does not make him armed
    run, case, rec, src = Scene('ARMD0003')
    Hit(src, 21, 'WEAPON_PISTOL')
    H.eq(#case.ledger, 0, '(b) a hit on someone outside the case is not in the ledger')
    H.eq(rec.everArmed, false, '(b) and is not "armed" (only damage to an officer of the case is)')
    -- by Crimson-Contracts' crew shot (Opp.noteArmed)
    H.eq(Opp.noteArmed('ARMD0003'), true, '(b) noteArmed answers true for a tracked suspect')
    H.eq(rec.everArmed, true, '(b) a crew shot reported by Crimson-Contracts: armed')
    Hit(1, src, 'WEAPON_PISTOL')
    H.eq(#PenaltiesOf(run, 'rs_unarmed_shot'), 0, '(b) then a pistol hit costs nothing')
    Opp.close(run)

    -- he drew between two watch passes: the server reads his hand at the hit too
    run, case, rec, src = Scene('ARMD0004')
    Tick(1)
    weapons[src] = 'WEAPON_PISTOL'
    Hit(1, src, 'WEAPON_PISTOL')
    H.eq(#PenaltiesOf(run, 'rs_unarmed_shot'), 0, '(b) a gun in his hand at the hit: armed, no penalty')
    weapons[src] = nil
    Opp.close(run)
end

-- ============================================================================
--                   (c) THE UNARMED-SHOT PENALTY (personal)
-- ============================================================================

do
    local run, case, rec, src = Scene('UNAR0001')
    Hit(1, src, 'WEAPON_STUNGUN')
    Hit(1, src, 'WEAPON_NIGHTSTICK')
    Hit(2, src, 'WEAPON_UNARMED')
    H.eq(#PenaltiesOf(run, 'rs_unarmed_shot'), 0, '(c) a taser, baton or punch on an unarmed suspect: no penalty')
    H.eq(#FlagsOf(run, 'rs_unarmed_shot'), 0, '(c) and no flag')
    H.ok(#case.ledger >= 3, '(c) every hit is in the ledger')
    Hit(1, src, 'WEAPON_PISTOL')
    local list = PenaltiesOf(run, 'rs_unarmed_shot')
    H.eq(#list, 1, '(c) a pistol hit on a never-armed suspect: one rs_unarmed_shot')
    H.eq(list[1] and list[1].src, 1, '(c) personal: the officer who fired')
    H.eq(run.participants[1].score.rs_unarmed_shot, 1, '(c) in his own score')
    H.eq(run.participants[2].score.rs_unarmed_shot, nil, '(c) not his partner\'s')
    H.eq(run.score.shared.rs_unarmed_shot, nil, '(c) never shared')
    H.eq(run.score.kinds.rs_unarmed_shot, 'penalty', '(c) recorded as a penalty')
    Hit(1, src, 'WEAPON_PISTOL')
    Hit(1, src, 'WEAPON_CARBINERIFLE')
    H.eq(run.participants[1].score.rs_unarmed_shot, 1, '(c) once per officer per suspect')
    local f = FlagsOf(run, 'rs_unarmed_shot')
    H.eq(#f, 1, '(c) and the flag rs_unarmed_shot once')
    H.eq(f[1] and f[1][2], 1, '(c) with the shooter\'s server id')
    H.eq(run.participants[1].flagged and run.participants[1].flagged.reason, 'rs_unarmed_shot',
        '(c) the shooter is flagged')
    H.eq(run.participants[2].flagged, nil, '(c) his partner is not')
    H.eq(run.flagged, nil, '(c) the run is not (nobody else is held)')
    H.eq(CashStatus(run, 1), 'held', '(c) the shooter\'s cash waits for review')
    H.eq(CashStatus(run, 2), 'none', '(c) his partner\'s is not held')
    -- scored as Config.Bonuses says: -25% of P on the shooter's row only (an engine-only id, any mission)
    local fake = {
        mission = { id = 'live_crime', type = 'investigation', objectives = {}, bonuses = {}, penalties = {} },
        missionId = 'live_crime',
        pointsBase = 160,
        stats = {},
        score = run.score,
        participants = {},
        flags = {},
    }
    local function Line(src)
        local p = { src = src, score = run.participants[src].score, department = 'sast', status = 'active' }
        local b = CP.Scoring.compute(fake, p, 'completed', { durationS = 600, departments = 1 })
        for _, l in ipairs(b.penalties or {}) do if l.id == 'rs_unarmed_shot' then return l end end
        return nil
    end
    H.eq(Line(1) and Line(1).points, -40, '(c) the shooter\'s row: -25% of P (160 -> -40)')
    H.eq(Line(2), nil, '(c) his partner\'s row: no such line')
    -- the partner's own shot is his own penalty
    Hit(2, src, 'WEAPON_PISTOL')
    H.eq(run.participants[2].score.rs_unarmed_shot, 1, '(c) the partner\'s own shot: his own penalty')
    H.eq(run.state, 'in_progress', '(c) the run goes on')
    Opp.close(run)
end

-- ============================================================================
--                  (d) EXCESSIVE FORCE: CP'S OWN CUSTODY (C7)
-- ============================================================================

do
    local run, case, rec, src = Scene('FORC0001')
    H.fire('police:server:CuffPlayer', 1, src, false)
    SetMeta(src, 'ishandcuffed', true)
    H.eq(rec.state, 'cuffed', '(d) cuffed through the sc-police cuff pair')
    local cancelled = Hit(2, src, 'WEAPON_NIGHTSTICK')
    local f = FlagsOf(run, 'rs_excessive_force')
    H.eq(#f, 1, '(d) a hit on a CP-cuffed suspect: rs_excessive_force')
    H.eq(f[1] and f[1][2], 2, '(d) on the officer who hit him')
    H.eq(run.participants[2].flagged and run.participants[2].flagged.reason, 'rs_excessive_force',
        '(d) his points wait for a supervisor')
    H.eq(run.participants[1].flagged, nil, '(d) his partner (who cuffed) is not flagged')
    H.eq(CashStatus(run, 1), 'none', '(d) his partner\'s cash is not held')
    H.eq(run.flagged, nil, '(d) the run as a whole is not flagged')
    H.eq(run.state, 'in_progress', '(d) the run is still in progress (never an automatic fail)')
    H.eq(ends, 0, '(d) nothing ended or failed the run')
    H.eq(cancelled, false, '(d) the hit is never cancelled')
    H.eq(#PenaltiesOf(run, 'rs_unarmed_shot'), 0, '(d) a baton is never a shot')
    Hit(2, src, 'WEAPON_NIGHTSTICK')
    H.eq(#FlagsOf(run, 'rs_excessive_force'), 1, '(d) once per officer per suspect')
    local line = nil
    for _, e in ipairs(case.timeline) do if e.what == 'rs_excessive_force' then line = e end end
    H.eq(line and line.by, 2, '(d) a timeline line names the officer')
    Tick(RS.custodyHoldSeconds + 1)
    H.eq(rec.state, 'detained', '(d) detained')
    Hit(1, src, 'WEAPON_STUNGUN')
    H.eq(#FlagsOf(run, 'rs_excessive_force'), 2, '(d) a taser on a detained suspect: the cuffing officer too')
    Opp.close(run)

    -- raw metadata says cuffed, CP never proved it (no cuff pair): no flag
    run, case, rec, src = Scene('FORC0002')
    Opp.noteArmed('FORC0002')
    SetMeta(src, 'ishandcuffed', true)
    H.eq(rec.state, 'free', '(d) metadata cuffed with no sc-police cuff: still free for CP')
    Hit(1, src, 'WEAPON_PISTOL')
    H.eq(#FlagsOf(run, 'rs_excessive_force'), 0, '(d) a hit on him is no excessive force (C7)')
    Opp.close(run)

    -- free of his cuffs again: what the suspect does himself never holds an officer's points (critic 2 #12).
    -- (1) he frees himself during the hold: a hit while the release waits for its explanation, and after his
    -- self-uncuff detain (he draws and fires at officer 2, who fires back)
    run, case, rec, src = Scene('FORC0003')
    H.fire('police:server:CuffPlayer', 1, src, false)
    SetMeta(src, 'ishandcuffed', true)
    Tick(2)
    SetMeta(src, 'ishandcuffed', false)
    H.eq(rec.state == 'cuffed' and rec.freedAt ~= nil, true, '(d) cuffs off, waiting for the explanation')
    Hit(2, src, 'WEAPON_NIGHTSTICK')
    H.eq(#FlagsOf(run, 'rs_excessive_force'), 0, '(d) a hit while his cuffs are off and unexplained: no flag')
    Tick(3)
    H.eq(rec.state, 'detained', '(d) a self-uncuff is detained')
    H.eq(#NotesOf(case, 'rs_self_uncuff'), 1, '(d) with the rs_self_uncuff note')
    weapons[src] = 'WEAPON_PISTOL'
    Hit(src, 2, 'WEAPON_PISTOL')
    Hit(2, src, 'WEAPON_PISTOL')
    H.eq(#FlagsOf(run, 'rs_excessive_force'), 0, '(d) detained by his own self-uncuff, then a pistol hit: no flag')
    H.eq(run.participants[2].flagged, nil, '(d) officer 2\'s points are not held')
    weapons[src] = nil
    Opp.close(run)

    -- (2) detained by an escort while down (never cuffed): a hit while he is still down is excessive force; revived
    -- by EMS he runs, and another officer's taser to cuff him is not
    run, case, rec, src = Scene('FORC0004')
    SetMeta(src, 'isdead', true)
    H.fire('police:server:EscortPlayer', 1, src)
    H.eq(rec.state, 'detained', '(d) detained by the escort of a downed suspect')
    Tick(RS.downGrace + 1)
    Hit(1, src, 'WEAPON_NIGHTSTICK')
    local held = FlagsOf(run, 'rs_excessive_force')
    H.eq(#held, 1, '(d) a hit on him detained and down past downGrace: rs_excessive_force')
    H.eq(held[1] and held[1][2], 1, '(d) on the officer who hit him')
    SetMeta(src, 'isdead', false)
    H.eq(rec.down, false, '(d) revived')
    Hit(2, src, 'WEAPON_STUNGUN')
    H.eq(#FlagsOf(run, 'rs_excessive_force'), 1, '(d) escort, revive, a taser hit: no flag for officer 2')
    H.eq(run.participants[2].flagged, nil, '(d) and his points are not held')
    Opp.close(run)

    -- (3) after the hold a friend's bobby pin frees him ('detained' stays): a hit is not excessive force, and a cash
    -- seizure within 3 m still is not a bad one (he was arrested: on purpose), audited as not CP-cuffed
    run, case, rec, src = Scene('FORC0005')
    Opp.noteArmed('FORC0005')
    H.fire('police:server:CuffPlayer', 1, src, false)
    SetMeta(src, 'ishandcuffed', true)
    Tick(RS.custodyHoldSeconds + 1)
    H.eq(rec.state, 'detained', '(d) detained after the hold')
    SetMeta(src, 'ishandcuffed', false)
    H.eq(rec.state, 'detained', '(d) the cuffs off after the hold: still detained for CP')
    Hit(2, src, 'WEAPON_PISTOL')
    H.eq(#FlagsOf(run, 'rs_excessive_force'), 0, '(d) freed after the hold, then a hit: no flag')
    audits = {}
    Seize(1, src)
    H.step(0)
    H.eq(#FlagsOf(run, 'rs_bad_seize'), 0, '(d) Seize Cash on a detained suspect within 3 m: no flag')
    local a = Audited('seizeCash')
    H.ok(a[1] and tostring(a[1][8]):find('CP-cuffed): No', 1, true) ~= nil, '(d) audited as not CP-cuffed')
    Opp.close(run)
end

-- ============================================================================
--                     (e) EXCESSIVE FORCE: HIT WHILE DOWN
-- ============================================================================

do
    local run, case, rec, src = Scene('DOWN0001')
    Opp.noteArmed('DOWN0001')
    Hit(1, src, 'WEAPON_PISTOL')
    Tick(1)
    SetMeta(src, 'isdead', true)
    H.eq(rec.down, true, '(e) he is down')
    Tick(1)
    Hit(1, src, 'WEAPON_PISTOL')
    H.eq(#FlagsOf(run, 'rs_excessive_force'), 0, '(e) down 1 s ago: no flag (downGrace)')
    Tick(4)
    Hit(1, src, 'WEAPON_PISTOL')
    local f = FlagsOf(run, 'rs_excessive_force')
    H.eq(#f, 1, '(e) down 5 s with earlier hits: rs_excessive_force')
    H.eq(f[1] and f[1][2], 1, '(e) on the officer who kept shooting')
    H.eq(run.participants[2].flagged, nil, '(e) not his partner')
    H.eq(run.state, 'in_progress', '(e) the run goes on')
    Opp.close(run)

    -- down 5 s, but no officer of the case hit him before he went down: no flag
    run, case, rec, src = Scene('DOWN0002')
    Opp.noteArmed('DOWN0002')
    SetMeta(src, 'inlaststand', true)
    Tick(5)
    Hit(2, src, 'WEAPON_PISTOL')
    H.eq(#FlagsOf(run, 'rs_excessive_force'), 0, '(e) down 5 s with no earlier hits from the case: no flag')
    Opp.close(run)
end

-- ============================================================================
--                      (f) RAN OVER (rs_ran_over, rs_vdm)
-- ============================================================================

do
    local run, case, rec, src = Scene('VDMX0001')
    Hit(1, src, 'WEAPON_RUN_OVER_BY_CAR')
    local list = PenaltiesOf(run, 'rs_ran_over')
    H.eq(#list, 1, '(f) a run-over on foot: rs_ran_over')
    H.eq(list[1] and list[1].src, 1, '(f) for the officer who drove')
    local f = FlagsOf(run, 'rs_vdm')
    H.eq(#f, 1, '(f) and the flag rs_vdm')
    H.eq(f[1] and f[1][2], 1, '(f) on him')
    H.eq(run.participants[2].flagged, nil, '(f) never on his partner')
    H.eq(#PenaltiesOf(run, 'rs_unarmed_shot'), 0, '(f) a run-over is not also an unarmed shot')
    Hit(1, src, 'WEAPON_RUN_OVER_BY_CAR')
    Hit(1, src, 'WEAPON_RAMMED_BY_CAR')
    H.eq(#PenaltiesOf(run, 'rs_ran_over'), 1, '(f) once per officer per suspect')
    Opp.close(run)

    -- in a car: ramming the car he flees in is never penalised
    run, case, rec, src = Scene('VDMX0002')
    H.players[src].vehicle = 4242
    Hit(1, src, 'WEAPON_RAMMED_BY_CAR')
    Hit(2, src, 'WEAPON_RUN_OVER_BY_CAR')
    H.eq(#PenaltiesOf(run, 'rs_ran_over'), 0, '(f) in a car: no penalty')
    H.eq(#FlagsOf(run, 'rs_vdm'), 0, '(f) and no flag')
    H.eq(#PenaltiesOf(run, 'rs_unarmed_shot'), 0, '(f) and ramming is no unarmed shot')
    H.eq(#case.ledger, 2, '(f) both hits are in the ledger')
    H.players[src].vehicle = nil
    Opp.close(run)
end

-- ============================================================================
--                    (g) A HIT IS BLAMED ONLY ON ITS SENDER
-- ============================================================================

do
    local run, case, rec, src = Scene('FORG0001')
    -- officer 2's game sends a packet that names officer 1's ped as the shooter: only officer 2 is blamed
    Hit(2, src, 'WEAPON_PISTOL', { parentGlobalId = NET(1) })
    H.eq(run.participants[2].score.rs_unarmed_shot, 1, '(g) a forged packet from player X blames X')
    H.eq(run.participants[1].score.rs_unarmed_shot, nil, '(g) never the player it names')
    H.eq(run.participants[1].flagged, nil, '(g) who is not flagged either')
    H.eq(case.ledger[#case.ledger].from, 2, '(g) the ledger names the sender')
    -- and a car officer 1 drives
    local car = H.entity(9100, { kind = 'vehicle', seats = { [-1] = 100 } })
    owners[car.handle] = 1
    Hit(3, src, 'WEAPON_RUN_OVER_BY_CAR', { parentGlobalId = 9100 })
    H.eq(#PenaltiesOf(run, 'rs_ran_over'), 0, '(g) a packet from an officer outside the case costs nobody')
    -- the bystander forging a hit "by officer 1" costs officer 1 nothing
    reads = {}
    Hit(21, src, 'WEAPON_PISTOL', { parentGlobalId = NET(1) })
    H.eq(run.participants[1].score.rs_unarmed_shot, nil, '(g) a bystander\'s packet costs officer 1 nothing')
    H.eq(next(reads), nil, '(g) and reads nothing')
    -- damage from an NPC the sender's game simulates is nobody's
    local npc = H.entity(9200, { kind = 'ped' })
    owners[npc.handle] = 1
    Hit(1, src, 'WEAPON_PISTOL', { parentGlobalId = 9200 })
    H.eq(run.participants[1].score.rs_unarmed_shot, nil, '(g) an NPC officer 1 simulates shot him: not officer 1')
    Opp.close(run)
    H.resetEntities()
end

-- ============================================================================
--                      (h) THE LEDGER: MERGED AND CAPPED
-- ============================================================================

do
    local run, case, rec, src = Scene('LEDG0001')
    Opp.noteArmed('LEDG0001')
    for _ = 1, 5 do Hit(1, src, 'WEAPON_CARBINERIFLE') end
    H.eq(#case.ledger, 1, '(h) a burst from one officer with one weapon is one line')
    H.eq(case.ledger[1].n, 5, '(h) with its count')
    H.eq(case.ledger[1].cid, 'LEDG0001', '(h) about the suspect')
    H.eq(case.ledger[1].dir, 'officer', '(h) officer -> suspect')
    Hit(2, src, 'WEAPON_PISTOL')
    H.eq(#case.ledger, 2, '(h) another officer: a new line')
    local saved = RS.damageLogMax
    RS.damageLogMax = 10
    for i = 1, 15 do
        Tick(3)
        Hit(i % 2 + 1, src, 'WEAPON_PISTOL')
    end
    H.eq(#case.ledger, 10, '(h) capped at damageLogMax (the oldest go first)')
    RS.damageLogMax = saved
    -- in an instance nothing is logged
    local before = #case.ledger
    bucket[2] = 7
    Hit(2, src, 'WEAPON_PISTOL')
    H.eq(#case.ledger, before, '(h) an officer in another routing bucket: not logged')
    bucket[2] = nil
    Opp.close(run)
end

-- ============================================================================
--                              (i) CASH SEIZURES
-- ============================================================================

do
    local run, case, rec, src = Scene('SEIZ0001')
    audits = {}
    Seize(1, src)
    H.step(0)
    local a = Audited('seizeCash')
    H.eq(#a, 1, '(i) a seizure by an officer of the case is audited')
    H.eq(a[1] and a[1][1], 1, '(i) by the officer (his citizenid is resolved by the audit)')
    H.eq(a[1] and a[1][3], 'flags', '(i) in the flags category')
    H.eq(a[1] and a[1][5], run.id, '(i) about the case\'s run')
    H.eq(a[1] and a[1][6], 'own_suspect', '(i) the target is a suspect of his case')
    H.eq(a[1] and a[1][7], 'free', '(i) CP\'s state of the target')
    H.ok(a[1] and tostring(a[1][8]):find('1.4 m', 1, true) ~= nil, '(i) with the server distance')
    H.ok(a[1] and tostring(a[1][8]):find('CP-cuffed): No', 1, true) ~= nil, '(i) and not CP-cuffed')
    local f = FlagsOf(run, 'rs_bad_seize')
    H.eq(#f, 1, '(i) a seizure from a suspect who is not in custody: rs_bad_seize')
    H.eq(f[1] and f[1][2], 1, '(i) on the seizing officer')
    H.eq(run.participants[2].flagged, nil, '(i) not his partner')
    H.eq(CashStatus(run, 2), 'none', '(i) whose cash is not held')
    Opp.close(run)

    -- CP-cuffed and close: audited, no flag; detained but 5 m away: flagged
    run, case, rec, src = Scene('SEIZ0002')
    H.fire('police:server:CuffPlayer', 1, src, false)
    SetMeta(src, 'ishandcuffed', true)
    audits = {}
    Seize(2, src)
    H.step(0)
    a = Audited('seizeCash')
    H.eq(#a, 1, '(i) a seizure from a CP-cuffed suspect is audited')
    H.ok(a[1] and tostring(a[1][8]):find('CP-cuffed): Yes', 1, true) ~= nil, '(i) as CP-cuffed')
    H.eq(#FlagsOf(run, 'rs_bad_seize'), 0, '(i) in custody within 3 m: no flag')
    Tick(RS.custodyHoldSeconds + 1)
    H.eq(rec.state, 'detained', '(i) detained')
    Move(2, vec3(6.0, 1.0, 30.0))
    Seize(2, src)
    H.eq(#FlagsOf(run, 'rs_bad_seize'), 1, '(i) from more than 3 m away: rs_bad_seize')
    Opp.close(run)

    -- an officer outside the case cannot be flagged on its run: a staff note
    run, case, rec, src = Scene('SEIZ0003')
    Seize(3, src)
    H.step(0)
    H.eq(#FlagsOf(run, 'rs_bad_seize'), 0, '(i) an officer outside the case is not flagged on it')
    local notes = NotesOf(case, 'rs_bad_seize')
    H.eq(#notes, 1, '(i) a staff note instead')
    H.ok(notes[1] and tostring(notes[1].detail):find('server id 3', 1, true) ~= nil, '(i) naming him')
    H.eq(run.flagged, nil, '(i) the run is not flagged')
    H.eq(run.participants[1].flagged, nil, '(i) nor its officers')
    -- an officer of the case seizing from a bystander: audited as not a suspect, no flag
    audits = {}
    Seize(1, 21)
    H.step(0)
    a = Audited('seizeCash')
    H.eq(#a, 1, '(i) a seizure by an officer on a case from anyone is audited')
    H.eq(a[1] and a[1][6], 'not_suspect', '(i) not a suspect')
    H.eq(#FlagsOf(run, 'rs_bad_seize'), 0, '(i) and not flagged')
    Opp.close(run)

    -- sc-police acts only for an on-duty 'leo': anyone else's event is no seizure (no audit, no flag, no note)
    run, case, rec, src = Scene('SEIZ0004')
    Load(4, 'OFF00004', vec3(0.0, 1.0, 30.0), 'sast', false)
    Move(21, vec3(1.0, 0.0, 30.0))
    audits = {}
    Seize(21, src)
    Seize(4, src)
    H.step(0)
    H.eq(#Audited('seizeCash'), 0, '(i) a civilian\'s or an off-duty officer\'s Seize Cash is not audited')
    H.eq(#NotesOf(case, 'rs_bad_seize'), 0, '(i) nor a staff note')
    H.eq(#FlagsOf(run, 'rs_bad_seize'), 0, '(i) nor a flag')
    -- the records say what is known: Seize Cash was used (sc-police takes nothing from a target with no cash)
    Seize(1, src)
    H.step(0)
    a = Audited('seizeCash')
    H.ok(a[1] and tostring(a[1][8]):find('Seize Cash used', 1, true) ~= nil, '(i) the audit says Seize Cash was used')
    f = FlagsOf(run, 'rs_bad_seize')
    H.ok(f[1] and tostring(f[1][4]):find('used Seize Cash on him', 1, true) ~= nil, '(i) and so does the flag')
    Move(21, vec3(-300.0, 300.0, 30.0))
    Opp.close(run)
end

-- ============================================================================
--                 (j) ONLY THE OFFICER WHO ACTED IS EVER HELD
-- ============================================================================

do
    H.ok(#flags > 0, '(j) flags were raised above')
    local wrong = {}
    for _, f in ipairs(flags) do
        local run, src = f[1], f[2]
        if src == nil then wrong[#wrong + 1] = 'whole case: ' .. tostring(f[3]) end
        if run.flagged then wrong[#wrong + 1] = 'run.flagged on ' .. run.id end
    end
    H.eq(table.concat(wrong, '; '), '', '(j) every flag names one officer; no run is flagged as a whole')
    -- the watch: after every case closed, nothing is read
    reads = {}
    Tick(5)
    H.eq(reads.GetSelectedPedWeapon or 0, 0, '(j) no case: no weapon read on the watch')
    H.eq(Opp.active(), false, '(j) every case is closed')
end

return H

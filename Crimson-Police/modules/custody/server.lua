-- CP.Custody (server): contact truths and facts, police actions, grading, the custody chain and the service
-- vehicles (prisoner transport, tow truck, coroner van). Truths never leave this file except as revealed facts.

CP.Custody = CP.Custody or {}
local Custody = CP.Custody
local U = CP.U
local TAG = 'custody'

local ACTION_EVENT = 'crimson-police:server:custody'
local STUN_EVENT = 'crimson-police:server:stunHit'
local ACT_EVENT = 'crimson-police:client:contactAct'
local CONFIRM_EVENT = 'crimson-police:client:contactConfirm'
local SERVICE_EVENT = 'crimson-police:client:serviceVehicle'
local ROAD_CALLBACK = 'crimson-police:client:roadPoint'

local TICK_MS = 1000
local REACH_SLACK_M = 1.0          -- position lag allowed around every reach
local DWELL_SLACK_MS = 2000        -- a sampled action must have been in reach for its time minus this
local SAMPLED_FROM_S = 3           -- actions this long or longer are sampled every second
local DECIDE_REACH_M = 25.0        -- a tablet decision needs the officer this close to the contact
local HANDOVER_REACH_M = 6.0       -- Hand over: the officer at the van's rear doors
local FRONT_DOT = 0.2              -- Run plate from a vehicle: the car must be in front of the officer's vehicle
local CONFIRM_KEEP_MS = 60000      -- an ox_target choice waiting for its tablet confirm
local FORCE_WINDOW_MS = 10000      -- excessive_force at most once per person in this window
local STUN_MATCH_MS = 1000         -- a stun_hit must match a ragdoll or state change this recent
local PLAYER_CLEAR_M = 30.0        -- a service vehicle spawn point this far from every player
local PARK_RANGE_M = 15.0          -- a service vehicle this close to its parking point has arrived
local PARK_SPEED = 1.5             -- m/s: and slower than this
local LOAD_RANGE_M = 8.0           -- the towed car this close to the flatbed is loaded
local ROAD_RETRY_MS = 3000
local EXIT_WAIT_MS = 3000          -- a released occupant of a car that stays gets this long to get out
local GONE_AFTER_S = 25            -- a leaving service vehicle is deleted this long after it drives off
local MAX_NETID = 0xFFFFFF
local MAX_RUNID = 64
local MAX_FACTS = 24
local RNG_SALT = 0x43555354        -- 'CUST'

-- Every action a client can name, with its target kind. Decisions are dispositions (graded).
local ACTIONS = {
    talk = 'person',
    frisk = 'person',
    detain = 'person',
    searchPerson = 'person',
    explain = 'person',
    warn = 'person',
    release = 'person',
    arrest = 'person',
    escort = 'person',
    seat = 'person',
    handover = 'person',
    lookInside = 'vehicle',
    runPlate = 'vehicle',
    runPlateFromVehicle = 'vehicle',
    inspect = 'vehicle',
    orderOut = 'vehicle',
    searchVehicle = 'vehicle',
    impound = 'vehicle',
    noAction = 'vehicle',
    cite = 'any',
}
local DECISIONS = { warn = true, cite = true, release = true, arrest = true, impound = true, noAction = true }
local PERSON_CHOICES = { 'release', 'warn', 'cite', 'arrest' }
local VEHICLE_CHOICES = { 'noAction', 'cite', 'impound' }
local CHAIN_ACTIONS = { searchPerson = true, escort = true, seat = true, handover = true }
local TIME_OF = { runPlateFromVehicle = 'runPlate', arrest = false }

-- Person states that can be talked to, frisked, detained; states that count as in custody.
local STOPPED = { idle = true, contacted = true, cuffed = true }
local IN_CUSTODY = { cuffed = true, escorted = true, seated = true, handed_over = true }
local GONE = { dead = true, released = true, handed_over = true }
-- Seats behind the four door bones of a car (GetPedInVehicleSeat index).
local DOOR_SEATS = { door_dside_f = -1, door_pside_f = 0, door_dside_r = 1, door_pside_r = 2 }
-- Truths that running from a lawful order turns into Evading (warrant, armed and intoxicated stay stricter).
local EVADE_OVER = { clean = true, minor = true, suspended = true, narcotics = true, tools = true }
local CONTRABAND = { armed = 'weapon', narcotics = 'narcotics', tools = 'tools' }
local GUILTY = { warrant = true, narcotics = true, tools = true, armed = true, evading = true }
local CAUSE_FACTS = {
    plain_view = 'plain_view',
    intoxicated = 'odour',
    odour_cannabis = 'odour',
    admission = 'admission',
    consent = 'consent',
    weapon = 'weapon',
    stolen = 'stolen',
}
local MINOR_OFFENCES = { 'expired_licence', 'open_container', 'loitering' }
-- Penalty ids that a mission's decisions table can make stricter (e.g. { wrongfulArrest = 'fail' }).
local OVERRIDE_OF = {
    wrong_citation = 'wrongCitation',
    missed_offence = 'missedOffence',
    wrongful_arrest = 'wrongfulArrest',
    missed_arrest = 'missedArrest',
    wrongful_impound = 'wrongfulImpound',
    missed_impound = 'missedImpound',
}

local books = {}       -- [runId] = book (see BookOf)

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function Now() return GetGameTimer() end
local function Cfg() return Config.Custody or {} end
local function Dec() return Config.Decisions or {} end

local function ToInt(v, lo, hi)
    if type(v) ~= 'number' or v ~= v then return nil end
    local n = math.tointeger(v)
    if not n or n < lo or n > hi then return nil end
    return n
end

local function Num(v, d)
    v = tonumber(v)
    if not v or v ~= v then return d end
    return v
end

local function Exists(e) return type(e) == 'number' and e ~= 0 and DoesEntityExist(e) == true end

local function Has(mod, fn) return CP[mod] ~= nil and type(CP[mod][fn]) == 'function' end

local function Call(mod, fn, ...)
    if not Has(mod, fn) then return false end
    local res = table.pack(pcall(CP[mod][fn], ...))
    if not res[1] then
        CP.err(TAG, 'CP.%s.%s failed: %s', mod, fn, tostring(res[2]))
        return false
    end
    return true, table.unpack(res, 2, res.n)
end

local function RunById(id)
    if type(id) ~= 'string' then return nil end
    local ok, run = Call('Runs', 'get', id)
    if ok and type(run) == 'table' then return run end
    return nil
end

local function IsLive(run) return type(run) == 'table' and run.state == 'in_progress' end

local function ActiveP(run, src)
    src = tonumber(src)
    local p = src and type(run.participants) == 'table' and run.participants[src] or nil
    if type(p) == 'table' and p.status == 'active' then return p end
    return nil
end

local function ActiveSrcs(run)
    local ok, list = Call('Runs', 'activeSrcs', run)
    return ok and type(list) == 'table' and list or {}
end

local function InArena(src)
    local ok, res = Call('Alerts', 'inArena', src)
    return ok and res == true
end

local function OnDuty(src)
    if not Has('Access', 'getOfficer') then return true end
    local ok, officer = Call('Access', 'getOfficer', src)
    return ok and officer ~= nil
end

local function Notify(src, kind, key, vars)
    Call('Tablet', 'notify', src, kind, key, vars)
end

local function PlayerCoords(src)
    local ped = GetPlayerPed(src)
    if not Exists(ped) then return nil, nil end
    return GetEntityCoords(ped), ped
end

local function EntityOf(run, netId)
    local e = type(run.entities) == 'table' and run.entities[netId] or nil
    if e and Exists(e.entity) then return e.entity, e end
    return nil, e
end

local function CoordsOf(run, netId)
    local ent = EntityOf(run, netId)
    return ent and GetEntityCoords(ent) or nil
end

local function WeightedPick(rng, weights)
    if type(weights) ~= 'table' then return nil end
    local keys, total = {}, 0
    for k, w in pairs(weights) do
        if type(w) == 'number' and w > 0 then
            keys[#keys + 1] = k
            total = total + w
        end
    end
    if total <= 0 then return nil end
    table.sort(keys)
    local x = rng:next() * total
    for _, k in ipairs(keys) do
        x = x - weights[k]
        if x < 0 then return k end
    end
    return keys[#keys]
end

local function TimeOf(action)
    local key = TIME_OF[action]
    if key == false then return 0 end
    local t = (Cfg().times or {})[key or action]
    return Num(t, 0)
end

local function ParticipantName(run, src)
    local p = run.participants and run.participants[src]
    return p and (p.callsign and p.callsign ~= '' and ('%s %s'):format(p.callsign, p.name or '') or p.name)
        or ('#%s'):format(tostring(src))
end

local function Heading2(h)
    local r = math.rad(Num(h, 0.0))
    return -math.sin(r), math.cos(r)
end

-- ============================================================================
--                                   THE BOOK
-- ============================================================================
-- One per live run: contacts = { [netId] = contact }, begins = { [src] = { netId, action, at } }, services,
-- confirms, the force window and the label counters. Contacts hold the truth: nothing here is replicated.

local function BookOf(run)
    local b = books[run.id]
    if not b then
        b = {
            runId = run.id,
            contacts = {},
            begins = {},
            confirms = {},
            services = {},
            transport = nil,
            force = {},
            labels = { person = 0, vehicle = 0 },
            nextService = 0,
        }
        books[run.id] = b
    end
    return b
end

local function LabelFor(b, kind)
    b.labels[kind] = b.labels[kind] + 1
    local n = b.labels[kind]
    if kind == 'person' then
        if n <= 26 then return string.char(64 + n) end
        return ('P%d'):format(n)
    end
    return ('V%d'):format(n)
end

local function ObjOf(run, index)
    local ok, ctx = Call('Runs', 'ctx', run, index)
    return ok and type(ctx) == 'table' and ctx.obj or {}
end

local function DecisionRules(run, c)
    local out = {}
    for k, v in pairs(Dec()) do out[k] = v end
    local m = run.mission and run.mission.decisions
    if type(m) == 'table' then for k, v in pairs(m) do out[k] = v end end
    local o = ObjOf(run, c.obj).decisions
    if type(o) == 'table' then for k, v in pairs(o) do out[k] = v end end
    return out
end

-- ============================================================================
--                               TRUTHS AND CUES
-- ============================================================================

function Custody.rollTruth(rng, setName, role)
    local sets = Cfg().profileSets or {}
    local set = sets[setName] or sets.scene or {}
    local weights = set[role]
    if weights == nil and role ~= 'vehicle' then weights = set.person or set.driver end
    return WeightedPick(rng, weights) or (role == 'vehicle' and 'legal' or 'clean')
end

function Custody.rollDemeanour(rng, truthKey)
    local weights = (Cfg().demeanour or {})[truthKey] or { compliant = 1 }
    local w = {}
    for k, v in pairs(weights) do
        if k ~= 'hostile' or truthKey == 'armed' then w[k] = v end
    end
    return WeightedPick(rng, w) or 'compliant'
end

-- The whole hidden profile of a person, rolled in a fixed order from rng: truth, demeanour and the cues that
-- decide which lawful paths exist (where the contraband is, plain view, odour, admission, consent, bolting).
function Custody.rollProfile(rng, setName, role, hasCar, truth)
    truth = truth or Custody.rollTruth(rng, setName, role)
    local c = Cfg()
    local cues = c.cues or {}
    local demeanour = Custody.rollDemeanour(rng, truth)
    local p = { truth = truth, demeanour = demeanour, cues = {} }
    local k = p.cues
    k.where = 'person'
    if CONTRABAND[truth] and hasCar and demeanour ~= 'hostile' and rng:chance(0.5) then k.where = 'car' end
    k.plainView = k.where == 'car' and rng:chance(Num(cues.plainView, 0.4)) or false
    k.odour = truth == 'narcotics' and rng:chance(Num(cues.odour, 0.3)) or false
    k.admits = CONTRABAND[truth] ~= nil and rng:chance(Num(c.admission, 0.2)) or false
    local consent = c.consent or {}
    k.consents = rng:chance(GUILTY[truth] and Num(consent.guilty, 0.15) or Num(consent.clean, 0.6))
    -- nervous people run on 15% of orders (Order out, a frisk); runners always
    k.bolts = demeanour == 'runner' or (demeanour == 'nervous' and rng:chance(0.15))
    k.minor = truth == 'minor' and MINOR_OFFENCES[rng:int(1, #MINOR_OFFENCES)] or nil
    return p
end

-- ============================================================================
--                                 REGISTRATION
-- ============================================================================
-- contact = { kind = 'person'|'vehicle', role, label, truth, demeanour, cues, vehicleOf, spot = { rule, street },
-- actions = { ... }, revealed = { factKey }, observed, evading, allowWarn, owner (vehicle: the registered owner's
-- netId), level (parking violation 'cite'|'impound') }. The bag gets the label, kind and actions only.

local function BagContact(c)
    return { label = c.label, kind = c.kind, actions = U.copy(c.actions or {}) }
end

local function SetState(run, c, state, extra)
    extra = extra or {}
    extra.contact = BagContact(c)
    c.state = state
    local ok, res = Call('Npc', 'setState', run, c.netId, state, extra)
    return ok and res ~= false
end

function Custody.register(run, obj, netId, contact)
    netId = ToInt(tonumber(netId), 1, MAX_NETID)
    if type(run) ~= 'table' or run.state == 'ended' or not netId or type(contact) ~= 'table' then return nil end
    if not (run.entities and run.entities[netId]) then return nil end
    local b = BookOf(run)
    local kind = contact.kind == 'vehicle' and 'vehicle' or 'person'
    local c = {
        netId = netId,
        obj = math.tointeger(tonumber(obj) or -1) or 1,
        kind = kind,
        role = contact.role or (kind == 'vehicle' and 'parked' or 'pedestrian'),
        label = contact.label or LabelFor(b, kind),
        truth = contact.truth or (kind == 'vehicle' and 'legal' or 'clean'),
        demeanour = contact.demeanour or 'compliant',
        cues = contact.cues or {},
        vehicleOf = tonumber(contact.vehicleOf),
        owner = tonumber(contact.owner),
        spot = type(contact.spot) == 'table' and U.copy(contact.spot) or nil,
        level = contact.level,
        actions = U.copy(contact.actions or {}),
        allowWarn = contact.allowWarn == true,
        observed = contact.observed,
        evading = contact.evading == true,
        custody = contact.custody,
        facts = {},
        factBy = {},
        done = {},
        decided = nil,
        state = contact.state or 'idle',
        acted = {},
        chain = contact.chain == true,
        seat = contact.seat,
        consensual = contact.consensual == true,
        transportPoint = contact.transportPoint,
        caught = contact.caught == true,
        ran = contact.ran == true,
    }
    b.contacts[netId] = c
    if kind == 'person' then Call('Runs', 'notePerson', run, netId, { label = c.label, demeanour = c.demeanour }) end
    SetState(run, c, c.state, contact.bag)
    for _, key in ipairs(type(contact.revealed) == 'table' and contact.revealed or {}) do
        Custody.reveal(run, netId, key, nil, { revealed = true, silent = true })
    end
    if c.evading then Custody.reveal(run, netId, 'evading', nil, { silent = true }) end
    CP.log(TAG, 'run %s: %s contact %s (%d) registered to objective %d', run.id, kind, c.label, netId, c.obj)
    return c
end

function Custody.get(run, netId)
    local b = type(run) == 'table' and books[run.id]
    netId = math.tointeger(tonumber(netId) or -1)
    return b and netId and b.contacts[netId] or nil
end

function Custody.contactsOf(run, obj)
    local out = {}
    local b = type(run) == 'table' and books[run.id]
    if not b then return out end
    for netId, c in pairs(b.contacts) do
        if obj == nil or c.obj == obj then out[#out + 1] = c end
    end
    table.sort(out, function(a, x) return a.netId < x.netId end)
    return out
end

local function Occupants(b, vehNetId)
    local out = {}
    for _, c in pairs(b.contacts) do
        if c.kind == 'person' and c.vehicleOf == vehNetId then out[#out + 1] = c end
    end
    table.sort(out, function(a, x) return a.netId < x.netId end)
    return out
end

-- ============================================================================
--                                    FACTS
-- ============================================================================

local function FactText(c, f)
    local vars = U.copy(f.data or {})
    vars.label = c.label
    return CP.L('custody.fact.' .. f.key, vars)
end

local function PushViews(run)
    if not (Has('Tablet', 'push') and Has('Runs', 'view')) then return end
    for _, src in ipairs(ActiveSrcs(run)) do
        local ok, view = Call('Runs', 'view', run, src)
        if ok then Call('Tablet', 'push', src, 'run', view) end
    end
end

local function HudContact(run, srcs, patch)
    for _, src in ipairs(srcs) do Call('Runs', 'hudFor', run, src, { contact = patch }) end
end

-- A fact reaches the run: every active participant from now on (knownTo), the Contact panel and a HUD line.
-- data.suppressed = found by an unlawful search (shown struck through, never graded).
function Custody.reveal(run, netId, factKey, src, data)
    local c = Custody.get(run, netId)
    if not c or type(factKey) ~= 'string' then return false end
    data = type(data) == 'table' and data or {}
    local suppressed = data.suppressed == true
    local f = c.factBy[factKey]
    if f and (f.suppressed == suppressed or not f.suppressed) then return false end
    local t = Now()
    if not f then
        if #c.facts >= MAX_FACTS then return false end
        f = { key = factKey, sentTo = {} }
        c.facts[#c.facts + 1] = f
        c.factBy[factKey] = f
    else
        -- an inadmissible fact found again lawfully: known from now on
        f.sentTo = {}
    end
    f.by = src and ParticipantName(run, src) or nil
    f.bySrc = src
    f.at = os.time()
    f.atMs = t
    f.suppressed = suppressed
    f.revealed = data.revealed == true
    f.cause = CAUSE_FACTS[factKey] ~= nil
    f.data = type(data.vars) == 'table' and data.vars or nil
    local srcs = ActiveSrcs(run)
    for _, s in ipairs(srcs) do
        if not f.sentTo[s] then f.sentTo[s] = { ms = t, ts = f.at } end
    end
    if not data.silent then
        HudContact(run, srcs, { label = c.label, fact = FactText(c, f), hint = false, suppressed = suppressed })
    end
    CP.log(TAG, 'run %s: fact %s on %s (%d)%s', run.id, factKey, c.label, netId, suppressed and ' (inadmissible)' or '')
    return true
end

-- When the server sent that fact to that officer (GetGameTimer ms), or nil. Inadmissible facts never count.
function Custody.knownTo(run, factKey, netId, src)
    local c = Custody.get(run, netId)
    local f = c and c.factBy[factKey]
    if not f or f.suppressed then return nil end
    local s = f.sentTo[tonumber(src)]
    return s and s.ms or nil
end

local function KnownAt(c, factKey, src)
    local f = c.factBy[factKey]
    local s = f and not f.suppressed and f.sentTo[tonumber(src)]
    return s and s.ts or nil
end

local function Lawful(c, factKey)
    local f = c.factBy[factKey]
    return f ~= nil and not f.suppressed
end

-- A contact cuffed through CP.Npc's "Cuff suspect" (after running or drawing): detained, and a caught runner.
function Custody.onCuffed(run, netId, src)
    local c = Custody.get(run, netId)
    if not c then return false end
    local prev = c.state
    c.detainedBy = src
    c.walking = false
    -- one act, one reward: a person who ran or drew earns subject_alive for the catch, their Arrest 0 points
    if c.ran or c.drew or prev == 'hostile' or prev == 'fleeing' then c.caught = true end
    Call('Runs', 'notePerson', run, c.netId, { did = 'cuffed' })
    SetState(run, c, 'cuffed')
    PushViews(run)
    return true
end

-- A contact that left the scene for good (walked off a consensual contact, or escaped).
function Custody.markGone(run, netId, how)
    local c = Custody.get(run, netId)
    if not c then return false end
    c.escaped = true
    c.goneHow = how
    if c.kind == 'person' and (how == 'escaped' or how == 'walked') then
        Call('Runs', 'notePerson', run, c.netId, { did = how == 'walked' and 'walked_away' or 'escaped' })
    end
    PushViews(run)
    return true
end

function Custody.markDead(run, netId)
    local c = Custody.get(run, netId)
    if not c then return false end
    c.dead = true
    c.state = 'dead'
    if c.kind == 'person' then Call('Runs', 'notePerson', run, c.netId, { did = 'killed' }) end
    PushViews(run)
    return true
end

-- ============================================================================
--                                PROBABLE CAUSE
-- ============================================================================

function Custody.probableCause(run, vehNetId)
    local b = books[run.id]
    local veh = b and b.contacts[tonumber(vehNetId)]
    if not veh then return false, {} end
    local sources = {}
    local function add(s) if not U.contains(sources, s) then sources[#sources + 1] = s end end
    if Lawful(veh, 'plain_view') then add('plain_view') end
    if Lawful(veh, 'stolen') then add('stolen') end
    for _, o in ipairs(Occupants(b, veh.netId)) do
        for key, source in pairs(CAUSE_FACTS) do
            if key ~= 'plain_view' and key ~= 'stolen' and Lawful(o, key) then add(source) end
        end
        if o.decided and o.decided.choice == 'arrest' then add('arrest') end
    end
    table.sort(sources)
    return #sources > 0, sources
end

-- Whether any lawful path to a person's contraband in a car existed (the cues rolled with the truth, a stolen
-- plate, or another occupant who could lawfully be arrested).
local function CarPathOpen(b, c)
    local k = c.cues or {}
    if k.plainView or k.odour or k.admits or k.consents then return true end
    local veh = c.vehicleOf and b.contacts[c.vehicleOf]
    if veh and veh.truth == 'stolen' then return true end
    for _, o in ipairs(c.vehicleOf and Occupants(b, c.vehicleOf) or {}) do
        if o ~= c then
            local ok = o.cues or {}
            if o.truth == 'warrant' or o.truth == 'intoxicated' or (CONTRABAND[o.truth] and ok.where ~= 'car') then
                return true
            end
        end
    end
    return false
end

local function Discoverable(b, c)
    if c.kind == 'vehicle' then return true end
    local t = c.truth
    if CONTRABAND[t] and (c.cues or {}).where == 'car' then return CarPathOpen(b, c) end
    return true
end

-- ============================================================================
--                                   GRADING
-- ============================================================================

local function EffectiveTruth(b, c)
    if c.kind == 'vehicle' then
        if c.truth == 'stolen' then return 'stolen' end
        if c.truth == 'violation' then return c.level == 'impound' and 'blocking' or 'meter' end
        for _, key in ipairs({ 'veh_weapon', 'veh_narcotics', 'veh_tools' }) do
            if Lawful(c, key) then return 'evidence' end
        end
        -- the driver or the registered owner arrested (or a suspended driver): nobody may drive it away
        for _, o in ipairs(Occupants(b, c.netId)) do
            local keyPerson = o.role == 'driver' or o.netId == c.owner
            if keyPerson and ((o.decided and o.decided.choice == 'arrest') or o.truth == 'suspended') then
                return 'unattended'
            end
        end
        return 'legal'
    end
    local t = c.truth
    if c.evading and EVADE_OVER[t] then t = 'evading' end
    if c.observed and c.role == 'driver' and t == 'clean' then t = 'minor' end
    return t
end

-- The fact that decides a truth's Best, and whether it reached the run lawfully.
local function DecidingFact(c, truth)
    local list
    if truth == 'warrant' then
        list = { 'warrant' }
    elseif truth == 'armed' then
        list = { 'weapon', 'veh_weapon' }
    elseif truth == 'narcotics' then
        list = { 'narcotics', 'veh_narcotics', 'admission' }
    elseif truth == 'tools' then
        list = { 'tools', 'veh_tools', 'admission' }
    elseif truth == 'intoxicated' then
        list = { 'intoxicated' }
    elseif truth == 'suspended' then
        list = { 'suspended' }
    elseif truth == 'minor' then
        if c.observed then return 'observed', true end
        list = { 'minor' }
    elseif truth == 'evading' then
        return 'evading', true
    elseif truth == 'stolen' then
        list = { 'stolen' }
    elseif truth == 'meter' or truth == 'blocking' then
        list = { 'spot_meter', 'spot_permit', 'spot_blocking' }
    elseif truth == 'evidence' then
        list = { 'veh_weapon', 'veh_narcotics', 'veh_tools' }
    else
        return nil, true
    end
    for _, k in ipairs(list) do
        if Lawful(c, k) then return k, true end
    end
    return list[1], false
end

local BEST = {
    clean = 'release',
    minor = 'cite',
    suspended = 'cite',
    warrant = 'arrest',
    armed = 'arrest',
    narcotics = 'arrest',
    tools = 'arrest',
    intoxicated = 'arrest',
    evading = 'arrest',
    legal = 'noAction',
    meter = 'cite',
    blocking = 'impound',
    stolen = 'impound',
    evidence = 'impound',
    unattended = 'impound',
}

-- verdict, bonusId, knowing factKey (for a case fail)
local function Verdict(b, c, truth, choice, knows, rules)
    local lets = choice == 'release' or choice == 'warn' or choice == 'cite'
    if c.kind == 'person' then
        if truth == 'clean' then
            if choice == 'release' then return 'best' end
            if choice == 'warn' then return 'ok' end
            if choice == 'cite' then return 'wrong', 'wrong_citation' end
            return 'wrong', 'wrongful_arrest'
        elseif truth == 'minor' or truth == 'suspended' then
            if choice == 'cite' then return 'best' end
            if choice == 'warn' and truth == 'minor' then return 'ok' end
            if choice == 'arrest' then return 'wrong', 'wrongful_arrest' end
            return 'wrong', 'missed_offence'
        elseif truth == 'warrant' or truth == 'armed' then
            if choice == 'arrest' then return 'best' end
            local key = truth == 'warrant' and 'warrant' or (knows('weapon') and 'weapon' or 'veh_weapon')
            if rules.failOnKnownDanger ~= false and knows(key) then return 'critical', nil, key end
            if truth == 'armed' and rules.undiscoverableIsOk ~= false and not Discoverable(b, c) then return 'ok' end
            return 'wrong', 'missed_arrest'
        elseif truth == 'narcotics' or truth == 'tools' then
            if choice == 'arrest' then return 'best' end
            if choice == 'cite' then return 'ok' end
            local _, lawful = DecidingFact(c, truth)
            if lawful then return 'wrong', 'missed_arrest' end
            if Discoverable(b, c) then return 'wrong', 'missed_offence' end
            if rules.undiscoverableIsOk ~= false then return 'ok' end
            return 'wrong', 'missed_offence'
        elseif truth == 'intoxicated' then
            if choice == 'arrest' then return 'best' end
            return 'wrong', 'missed_arrest'
        elseif truth == 'evading' then
            if choice == 'arrest' then return 'best' end
            if choice == 'cite' then return 'ok' end
            return 'wrong', 'missed_arrest'
        end
        return lets and 'ok' or 'wrong', lets and nil or 'wrongful_arrest'
    end
    if truth == 'legal' then
        if choice == 'noAction' then return 'best' end
        if choice == 'cite' then return 'wrong', 'wrong_citation' end
        return 'wrong', 'wrongful_impound'
    elseif truth == 'meter' then
        if choice == 'cite' then return 'best' end
        if choice == 'impound' then return 'wrong', 'wrongful_impound' end
        return 'wrong', 'missed_offence'
    elseif truth == 'blocking' then
        if choice == 'impound' then return 'best' end
        if choice == 'cite' then return 'ok' end
        return 'wrong', 'missed_offence'
    elseif truth == 'stolen' then
        if choice == 'impound' then return 'best' end
        if rules.failOnKnownStolen ~= false and knows('stolen') then return 'critical', nil, 'stolen' end
        return 'wrong', 'missed_impound'
    elseif truth == 'evidence' then
        if choice == 'impound' then return 'best' end
        return 'wrong', 'missed_impound'
    elseif truth == 'unattended' then
        if choice == 'impound' then return 'best' end
        if choice == 'noAction' then return 'ok' end
        return 'wrong', 'wrong_citation'
    end
    return 'ok'
end

-- Pure: the CP.Runs.decide entry for this choice, graded against the truth and the facts that reached src before
-- beginMs (a partner's fact that arrives while the bar runs is not known). Returns entry, factKey (case fail).
function Custody.grade(run, netId, choice, src, beginMs)
    local b = books[run.id]
    local c = b and b.contacts[tonumber(netId)]
    if not c then return nil end
    beginMs = beginMs or Now()
    local rules = DecisionRules(run, c)
    local truth = EffectiveTruth(b, c)
    local function knows(key)
        local at = Custody.knownTo(run, key, c.netId, src)
        return at ~= nil and at <= beginMs
    end
    local verdict, bonusId, failFact = Verdict(b, c, truth, choice, knows, rules)
    local factKey, lawful = DecidingFact(c, truth)
    local best = BEST[truth] or (c.kind == 'vehicle' and 'noAction' or 'release')
    -- Best needs the deciding fact found lawfully; an arrest resting on nothing lawful is Acceptable at best
    if verdict == 'best' and not lawful then verdict = 'ok' end
    local points = nil
    if verdict == 'best' then
        bonusId = 'correct_disposition'
        local obj = ObjOf(run, c.obj)
        points = Num(obj.bestPoints, nil)
        -- one act, one reward: a caught runner earned subject_alive; a fact given from the start earns nothing
        local f = factKey and c.factBy[factKey]
        if c.caught or (f and f.revealed) then points = 0 end
    end
    local failKey = nil
    if verdict == 'critical' then
        failKey = failFact == 'stolen' and 'reason.known_stolen' or 'reason.known_error'
    elseif verdict == 'wrong' and bonusId and rules[OVERRIDE_OF[bonusId] or ''] == 'fail' then
        verdict = 'critical'
        failKey = 'reason.decision_fail'
    end
    local facts, factLog = {}, {}
    for _, f in ipairs(c.facts) do
        local sent = not f.suppressed and f.sentTo[tonumber(src)]
        if sent and sent.ms <= beginMs then
            facts[#facts + 1] = f.key
            factLog[#factLog + 1] = { key = f.key, text = FactText(c, f), at = sent.ts }
        end
    end
    local knownAt = factKey and KnownAt(c, factKey, src) or nil
    local entry = {
        contact = c.label,
        kind = c.kind,
        choice = choice,
        verdict = verdict,
        bonusId = verdict ~= 'ok' and bonusId or nil,
        points = points,
        truthKey = truth,
        bestChoice = best,
        facts = facts,
        factLog = factLog,
        discoverable = Discoverable(b, c),
        knownAt = knownAt,
        failKey = failKey,
        netId = c.netId,
    }
    return entry, failFact
end

-- ============================================================================
--                       BEHAVIOURS (the only leak path)
-- ============================================================================
-- A truth-derived behaviour reaches the run host only at the moment it starts. tell_then_draw arms the ped
-- (CP.Runs.arm) when the tell ends, then turns it hostile.

local function TellSeconds(rng)
    local r = (Config.Npc or {}).tellSeconds or { 1.5, 3.0 }
    local lo, hi = Num(r[1], 1.5), Num(r[2], 3.0)
    return lo + (hi - lo) * (rng and rng:next() or 0.5)
end

local function TellHints(run, c, tell)
    local n = Config.Npc or {}
    if n.tellHints == false then return end
    local pc = CoordsOf(run, c.netId)
    if not pc then return end
    local near = {}
    for _, s in ipairs(ActiveSrcs(run)) do
        local sc = PlayerCoords(s)
        if sc and U.dist(sc, pc) <= Num(n.tellRange, 25.0) then near[#near + 1] = s end
    end
    HudContact(run, near, { label = c.label, fact = false, hint = CP.Lt('custody.tell.' .. tell), suppressed = false })
end

local TELLS = { tell_then_draw = 'hands', flee_on_approach = 'looking', flee_on_order = 'looking' }

-- The behaviour itself, once its tell has played (tellSeen is set only now).
local function StartBehaviour(run, c, behaviour, args)
    if not IsLive(run) or c.state == 'dead' or IN_CUSTODY[c.state] or GONE[c.state] then return end
    local tell = TELLS[behaviour]
    if tell then c.tellSeen = tell end
    local extra = type(args) == 'table' and args.points and { cfg = { fleePoints = args.points } } or nil
    local did = (behaviour == 'tell_then_draw' and 'drew') or (behaviour == 'walk_away' and 'walked_away')
        or ((behaviour == 'flee_on_approach' or behaviour == 'flee_on_order') and 'ran') or nil
    if did then Call('Runs', 'notePerson', run, c.netId, { did = did }) end
    if behaviour == 'tell_then_draw' then
        c.drew = true
        Call('Runs', 'arm', run, c.netId)
        SetState(run, c, 'hostile')
    elseif behaviour == 'flee_on_approach' or behaviour == 'flee_on_order' then
        c.ran = true
        SetState(run, c, 'fleeing', extra)
    elseif behaviour == 'walk_away' then
        c.walking = true
        if extra then SetState(run, c, c.state, extra) end
    end
    PushViews(run)
end

-- Tells the run host to start a behaviour now (walk_away, flee_on_approach, flee_on_order, tell_then_draw,
-- leave). Running and drawing first play a 1.5-3 s tell every participant sees; the weapon is given only when
-- the tell ends. The only way a truth-derived fact reaches a client before a police action reveals it.
function Custody.act(run, netId, behaviour, args)
    local c = Custody.get(run, netId)
    if not c or not IsLive(run) or type(behaviour) ~= 'string' then return false end
    if c.acted[behaviour] then return false end
    c.acted[behaviour] = true
    local payload = { runId = run.id, netId = c.netId, behaviour = behaviour, args = args }
    local tell = TELLS[behaviour]
    if tell then
        local b = BookOf(run)
        b.rng = b.rng or U.rng((math.floor(Num(run.seed, 1)) ~ RNG_SALT) & 0x7FFFFFFF)
        local secs = TellSeconds(b.rng)
        payload.seconds = secs
        if run.host then TriggerClientEvent(ACT_EVENT, run.host, payload) end
        c.telling = behaviour
        TellHints(run, c, tell)
        SetTimeout(math.floor(secs * 1000), function()
            c.telling = nil
            StartBehaviour(run, c, behaviour, args)
        end)
        return true
    end
    if run.host then TriggerClientEvent(ACT_EVENT, run.host, payload) end
    StartBehaviour(run, c, behaviour, args)
    return true
end

-- ============================================================================
--                            STATE ORDER AND REACH
-- ============================================================================

local function Allowed(c, action)
    if action == 'runPlateFromVehicle' then action = 'runPlate' end
    return U.contains(c.actions or {}, action)
end

local function Seated(run, c)
    local ent = EntityOf(run, c.netId)
    if not ent then return false end
    local veh = GetVehiclePedIsIn(ent, false)
    return veh ~= nil and veh ~= 0
end

-- Whether action fits the contact's state now (refused actions never reveal anything).
local function StateOk(run, b, c, action, src)
    if c.decided and DECISIONS[action] then return false, 'err.custody_decided' end
    if GONE[c.state] and action ~= 'handover' then return false, 'err.custody_state' end
    local s = c.state
    if c.kind == 'vehicle' then
        if s == 'impounded' or s == 'released' then return false, 'err.custody_state' end
        if action == 'orderOut' then
            for _, o in ipairs(Occupants(b, c.netId)) do
                if not GONE[o.state] and Seated(run, o) and o.state == 'idle' then return true end
            end
            return false, 'err.custody_nobody_inside'
        end
        if action == 'cite' and c.role ~= 'parked' then return false, 'err.custody_state' end
        return true
    end
    if action == 'talk' then return STOPPED[s] == true or s == 'seated', 'err.custody_state' end
    if action == 'frisk' then
        return (s == 'contacted' or s == 'cuffed') and not Seated(run, c), 'err.custody_state'
    end
    if action == 'detain' then return s == 'contacted' and not Seated(run, c), 'err.custody_state' end
    if action == 'searchPerson' then return s == 'cuffed' or s == 'escorted', 'err.custody_state' end
    if action == 'explain' then return c.arguing == true, 'err.custody_state' end
    if action == 'arrest' then return s == 'cuffed', 'err.custody_not_detained' end
    if action == 'release' or action == 'warn' or action == 'cite' then
        if action == 'warn' and not c.allowWarn then return false, 'err.custody_state' end
        return STOPPED[s] == true, 'err.custody_state'
    end
    if action == 'escort' then
        if s == 'escorted' then return c.escortBy == src, 'err.custody_state' end
        return (s == 'cuffed' or s == 'seated') and (c.decided and c.decided.choice == 'arrest' or c.chain),
            'err.custody_state'
    end
    if action == 'seat' then return s == 'escorted' and c.escortBy == src, 'err.custody_not_escorting' end
    if action == 'handover' then return true end
    return true
end

local function ReachFor(c, action, seated)
    local r = Cfg().reach or {}
    if action == 'runPlateFromVehicle' then return Num(r.plateFromVehicle, 20.0) end
    if action == 'handover' then return HANDOVER_REACH_M end
    if action == 'seat' then return Num(r.seatVehicle, 5.0) end
    if c.kind == 'vehicle' then return Num(r.vehicle, 3.0) end
    if seated then return Num(r.vehicle, 3.0) end
    if action == 'frisk' then return Num(r.frisk, 1.5) end
    return Num(r.person, 2.0)
end

-- src's distance to the contact (a seated person is reached at their door: the car's distance).
local function DistTo(run, c, src)
    local sc = PlayerCoords(src)
    local pc = CoordsOf(run, c.netId)
    if not sc or not pc then return math.huge end
    return U.dist(sc, pc)
end

-- What an action is measured to: the contact, or for Hand over the van (Run plate from a vehicle: the car it
-- picked; Place in vehicle is checked against the officer's car when it runs).
local function WatchTarget(run, c, action)
    if action == 'handover' then
        local b = books[run.id]
        local t = b and b.transport
        return t and t.veh or nil
    end
    return c.netId
end

local function InReach(run, c, action, src)
    if action == 'escort' and c.state == 'escorted' then return true end
    if action == 'seat' then return true end
    local target = WatchTarget(run, c, action)
    if not target then return false end
    local sc, tc = PlayerCoords(src), CoordsOf(run, target)
    if not sc or not tc then return false end
    return U.dist(sc, tc) <= ReachFor(c, action, Seated(run, c)) + REACH_SLACK_M
end

-- The person in a seat of a contact car (door options: the car hides them from a raycast).
local function SeatedPerson(run, b, vehNetId, seat)
    local veh = EntityOf(run, vehNetId)
    if not veh then return nil end
    local ped = GetPedInVehicleSeat(veh, seat)
    if not Exists(ped) then return nil end
    for netId, c in pairs(b.contacts) do
        local e = EntityOf(run, netId)
        if e == ped and c.kind == 'person' then return c end
    end
    return nil
end

-- Run plate from a vehicle: the nearest contact car within 20 m in front of the officer's own vehicle.
local function CarInFront(run, b, src)
    local _, ped = PlayerCoords(src)
    if not ped then return nil end
    local veh = GetVehiclePedIsIn(ped, false)
    if not veh or veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then return nil end
    local vc = GetEntityCoords(veh)
    local fx, fy = Heading2(GetEntityHeading(veh))
    local range = Num((Cfg().reach or {}).plateFromVehicle, 20.0)
    local best, bestD = nil, math.huge
    for netId, c in pairs(b.contacts) do
        if c.kind == 'vehicle' and IsLive(run) and not c.decided then
            local cc = CoordsOf(run, netId)
            local ent = EntityOf(run, netId)
            if cc and ent ~= veh then
                local dx, dy = cc.x - vc.x, cc.y - vc.y
                local d = math.sqrt(dx * dx + dy * dy)
                if d <= range and d > 0.1 and (dx * fx + dy * fy) / d >= FRONT_DOT and d < bestD then
                    best, bestD = c, d
                end
            end
        end
    end
    return best
end

-- ============================================================================
--                              THE CUSTODY CHAIN
-- ============================================================================
-- After an arrest: Search person → Escort → Place in vehicle → Hand over to transport. Delivers
-- { type = 'handed_over', netId } to the owning objective.

local function ChainActions()
    return { 'searchPerson', 'escort', 'seat', 'handover' }
end

function Custody.enableChain(run, netId, opts)
    netId = math.tointeger(tonumber(netId) or -1)
    if not IsLive(run) or not netId or not run.entities[netId] then return false end
    opts = type(opts) == 'table' and opts or {}
    local c = Custody.get(run, netId)
    if not c then
        c = Custody.register(run, opts.obj or run.entities[netId].obj, netId, {
            kind = 'person',
            role = run.entities[netId].role or 'suspect',
            actions = ChainActions(),
            chain = true,
            state = 'cuffed',
        })
        if not c then return false end
    else
        for _, a in ipairs(ChainActions()) do
            if not U.contains(c.actions, a) then c.actions[#c.actions + 1] = a end
        end
    end
    c.custody = 'handover'
    c.chainOpen = true
    SetState(run, c, c.state == 'idle' and 'cuffed' or c.state)
    local coords = opts.coords or CoordsOf(run, netId)
    if coords then Custody.requestTransport(run, coords, { obj = c.obj, point = opts.transport }) end
    return true
end

local function StopEscort(run, c)
    if c.state ~= 'escorted' then return end
    c.escortBy = nil
    SetState(run, c, 'cuffed', { escortBy = false })
end

-- ============================================================================
--                               SERVICE VEHICLES
-- ============================================================================
-- serviceVehicle(run, kind, coords, opts) -> handle. The driving client (nearest participant, else the host)
-- gives a road point that the server checks, the vehicle spawns there and that client drives it; the AI moves
-- when that client leaves or is beyond serviceHandoff, and after serviceTimeout the server places the van or
-- fades the towed car.

local function KindCfg(kind)
    local c = Cfg()
    if kind == 'transport' then return c.transport or {} end
    if kind == 'tow' then return c.tow or {} end
    return c.coroner or {}
end

local function PickDriver(run, coords, except)
    local best, bestD = nil, math.huge
    for _, s in ipairs(ActiveSrcs(run)) do
        if s ~= except and not InArena(s) then
            local sc = PlayerCoords(s)
            local d = sc and coords and U.dist(sc, coords) or math.huge
            if d < bestD then best, bestD = s, d end
        end
    end
    if not best and run.host and run.host ~= except and ActiveP(run, run.host) then best = run.host end
    return best
end

local function Vec4Of(v, h)
    local x, y, z = U.xyz(v)
    if not x then return nil end
    local w = h or (type(v) == 'table' or type(v) == 'vector4') and tonumber(v.w or v[4] or v.heading) or 0.0
    return vector4(x + 0.0, y + 0.0, z + 0.0, (tonumber(w) or 0.0) + 0.0)
end

-- A road point from the driving client, checked with server coordinates: within spawnDistance of the scene
-- and PLAYER_CLEAR_M from every player. nil when refused.
function Custody.checkRoadPoint(run, s, point)
    if type(point) ~= 'table' then return nil end
    local c = Vec4Of(point.coords or point, tonumber(point.heading))
    if not c then return nil end
    local sd = KindCfg(s.kind).spawnDistance or { 150.0, 250.0 }
    local d = U.dist(c, s.near)
    if d < Num(sd[1], 150.0) - 5.0 or d > Num(sd[2], 250.0) + 5.0 then return nil end
    for _, pl in ipairs(GetPlayers()) do
        local pc = PlayerCoords(tonumber(pl))
        if pc and U.dist(pc, c) < PLAYER_CLEAR_M then return nil end
    end
    return c
end

local function SendService(run, s, op)
    if not s.driverSrc then return end
    TriggerClientEvent(SERVICE_EVENT, s.driverSrc, {
        runId = run.id,
        id = s.id,
        op = op,
        kind = s.kind,
        veh = s.veh,
        driver = s.driverNet,
        dest = s.dest,
        target = s.target,
        away = s.spawnAt,
    })
end

local function SpawnService(run, s, at)
    local kc = KindCfg(s.kind)
    local ok, veh, vehNet = Call('Runs', 'spawnVehicle', run,
        { obj = s.obj, model = kc.model or 'policet', coords = at, role = 'service', tag = s.kind })
    if not ok or not vehNet then return false end
    local okP, ped, pedNet = Call('Runs', 'spawnPed', run,
        { obj = s.obj, model = kc.driver or 's_m_y_cop_01', coords = at, role = 'service_driver', tag = s.kind })
    if okP and ped and SetPedIntoVehicle then SetPedIntoVehicle(ped, veh, -1) end
    if SetVehicleDoorsLocked then SetVehicleDoorsLocked(veh, 2) end
    s.veh, s.vehEnt, s.driverNet = vehNet, veh, okP and pedNet or nil
    s.spawnAt = at
    s.spawnedAt = Now()
    CP.log(TAG, 'run %s: %s %d spawned for objective %d', run.id, s.kind, vehNet, s.obj)
    return true
end

local function Placed(run, s)
    local ent = s.veh and EntityOf(run, s.veh)
    if ent and s.dest and SetEntityCoords then
        SetEntityCoords(ent, s.dest.x + 0.0, s.dest.y + 0.0, s.dest.z + 0.0, false, false, false, false)
        if SetEntityHeading then SetEntityHeading(ent, (s.dest.w or 0.0) + 0.0) end
    end
end

local function Impounded(run, s, carNet)
    local c = Custody.get(run, carNet)
    if c then SetState(run, c, 'impounded') end
    Call('Runs', 'entityEvent', run, carNet, { type = 'impounded', netId = carNet, src = s and s.decider })
    PushViews(run)
end

local function FadeCar(run, s, carNet)
    Impounded(run, s, carNet)
    Call('Runs', 'deleteEntity', run, carNet)
end

local function ServiceGone(run, s)
    s.status = 'gone'
    if s.veh then Call('Runs', 'deleteEntity', run, s.veh) end
    if s.driverNet then Call('Runs', 'deleteEntity', run, s.driverNet) end
    for _, netId in ipairs(s.cargo or {}) do Call('Runs', 'deleteEntity', run, netId) end
    local b = books[run.id]
    if b and b.transport == s then b.transport = nil end
end

local function Leave(run, s)
    if s.status == 'leaving' or s.status == 'gone' then return end
    s.status = 'leaving'
    s.leftAt = Now()
    SendService(run, s, 'leave')
    PushViews(run)
end

function Custody.serviceVehicle(run, kind, coords, opts)
    if not IsLive(run) or not coords then return nil end
    opts = type(opts) == 'table' and opts or {}
    local b = BookOf(run)
    if kind == 'tow' and (Cfg().tow or {}).enabled == false then
        if opts.target then FadeCar(run, { decider = opts.decider }, opts.target) end
        return nil
    end
    b.nextService = b.nextService + 1
    local x, y, z = U.xyz(coords)
    local s = {
        id = b.nextService,
        kind = kind,
        obj = opts.obj or run.objectiveIndex,
        near = vector3(x + 0.0, y + 0.0, z + 0.0),
        dest = Vec4Of(opts.point or coords),
        -- parked within this of dest: a placed point (transport point, coroner point) is exact; with none the
        -- prisoner van may stop anywhere within Config.Custody.transport.parkWithin of the scene
        parkRange = opts.point and PARK_RANGE_M or math.max(PARK_RANGE_M, Num(KindCfg(kind).parkWithin, PARK_RANGE_M)),
        target = opts.target,
        decider = opts.decider,
        status = 'pending',
        requestedAt = Now(),
        cargo = {},
    }
    b.services[#b.services + 1] = s
    CP.log(TAG, 'run %s: %s requested for objective %d', run.id, kind, s.obj)
    return s
end

local function AskRoadPoint(run, s)
    if s.asking or (s.askedAt and Now() - s.askedAt < ROAD_RETRY_MS) then return end
    s.driverSrc = PickDriver(run, s.near)
    if not s.driverSrc then return end
    s.asking = true
    s.askedAt = Now()
    local sd = KindCfg(s.kind).spawnDistance or { 150.0, 250.0 }
    CreateThread(function()
        local ok, reply = pcall(lib.callback.await, ROAD_CALLBACK, s.driverSrc,
            { near = s.near, min = Num(sd[1], 150.0), max = Num(sd[2], 250.0) })
        s.asking = false
        if s.status ~= 'pending' or not IsLive(run) then return end
        local at = ok and Custody.checkRoadPoint(run, s, reply) or nil
        if not at then
            CP.log(TAG, 'run %s: road point for %s refused', run.id, s.kind)
            return
        end
        s.roadPoint = at
    end)
end

local function DriverOk(run, s)
    local p = s.driverSrc and ActiveP(run, s.driverSrc)
    if not p or InArena(s.driverSrc) then return false end
    local ok, down = Call('Qbx', 'isDowned', s.driverSrc)
    if ok and down == true then return false end
    local sc = PlayerCoords(s.driverSrc)
    local vc = s.veh and CoordsOf(run, s.veh)
    if sc and vc and U.dist(sc, vc) > Num(Cfg().serviceHandoff, 250.0) then return false end
    return sc ~= nil
end

local function Arrived(run, s)
    local ent = s.veh and EntityOf(run, s.veh)
    if not ent or not s.dest then return false end
    return U.dist(GetEntityCoords(ent), s.dest) <= (s.parkRange or PARK_RANGE_M)
        and Num(GetEntitySpeed(ent), 0) <= PARK_SPEED
end

local function TickService(run, s)
    local timeout = Num(Cfg().serviceTimeout, 60) * 1000
    local t = Now()
    if s.status == 'pending' then
        if s.roadPoint then
            -- the caps: a service vehicle waits for room, it is never cut
            local okC, can = Call('Runs', 'canSpawn', run, 2, false)
            if okC and can and SpawnService(run, s, s.roadPoint) then
                s.status = 'coming'
                SendService(run, s, 'drive')
            end
        elseif t - s.requestedAt >= timeout then
            -- nobody gave a usable road point in time: the vehicle is placed at its parking point
            local okC, can = Call('Runs', 'canSpawn', run, 2, false)
            if okC and can and SpawnService(run, s, s.dest) then
                s.status = 'parked'
                s.parkedAt = t
                s.placed = true
            end
        else
            AskRoadPoint(run, s)
        end
        return
    end
    if s.status == 'gone' then return end
    if s.veh and not EntityOf(run, s.veh) then
        ServiceGone(run, s)
        return
    end
    if s.status == 'coming' or s.status == 'loading' or s.status == 'leaving' then
        if not DriverOk(run, s) then
            local next = PickDriver(run, s.veh and CoordsOf(run, s.veh) or s.near, s.driverSrc)
            if next and next ~= s.driverSrc then
                s.driverSrc = next
                SendService(run, s, s.status == 'loading' and 'load' or (s.status == 'leaving' and 'leave' or 'drive'))
                CP.log(TAG, 'run %s: %s %d AI moved to %d', run.id, s.kind, s.veh or 0, next)
            end
        end
    end
    if s.status == 'coming' then
        if Arrived(run, s) then
            s.status = 'parked'
            s.parkedAt = t
            if s.kind == 'tow' then
                s.status = 'loading'
                SendService(run, s, 'load')
            end
            PushViews(run)
        elseif t - (s.spawnedAt or t) >= timeout then
            if s.kind == 'tow' then
                FadeCar(run, s, s.target)
                Leave(run, s)
            else
                Placed(run, s)
                s.status = 'parked'
                s.parkedAt = t
                s.placed = true
                PushViews(run)
            end
        end
    elseif s.status == 'loading' then
        local cc = s.target and CoordsOf(run, s.target)
        local vc = CoordsOf(run, s.veh)
        if cc and vc and U.dist(cc, vc) <= LOAD_RANGE_M then
            s.cargo[#s.cargo + 1] = s.target
            Impounded(run, s, s.target)
            Leave(run, s)
        elseif not cc or t - (s.parkedAt or t) >= timeout then
            FadeCar(run, s, s.target)
            Leave(run, s)
        end
    elseif s.status == 'parked' then
        local o = run.objectives and run.objectives[s.obj]
        if s.kind == 'transport' and o and o.status == 'done' then
            s.doneAt = s.doneAt or t
            if t - s.doneAt >= Num(KindCfg('transport').leaveAfter, 60) * 1000 then Leave(run, s) end
        elseif s.kind ~= 'transport' and s.released then
            Leave(run, s)
        end
    elseif s.status == 'leaving' then
        if t - (s.leftAt or t) >= GONE_AFTER_S * 1000 then ServiceGone(run, s) end
    end
end

-- ============================================================================
--                                  TRANSPORT
-- ============================================================================

function Custody.requestTransport(run, coords, opts)
    if not IsLive(run) or not coords then return nil end
    opts = type(opts) == 'table' and opts or {}
    local b = BookOf(run)
    local t = b.transport
    if t and t.status ~= 'leaving' and t.status ~= 'gone' then
        if opts.obj and t.obj ~= opts.obj then
            t.obj = opts.obj
            t.doneAt = nil
        end
        return t
    end
    b.transport = Custody.serviceVehicle(run, 'transport', coords, { obj = opts.obj, point = opts.point })
    PushViews(run)
    return b.transport
end

function Custody.transport(run, src)
    local b = type(run) == 'table' and books[run.id]
    local t = b and b.transport
    if not t then return nil end
    local status = (t.status == 'parked' and 'parked') or (t.status == 'leaving' and 'leaving') or 'coming'
    local distance = nil
    local vc = t.veh and CoordsOf(run, t.veh)
    local sc = src and PlayerCoords(src)
    if vc and sc then distance = math.floor(U.dist(vc, sc) + 0.5) end
    return { status = status, netId = t.veh, distance = distance }
end

-- ============================================================================
--                                   IMPOUND
-- ============================================================================

function Custody.impound(run, netId, src)
    local c = Custody.get(run, netId)
    if not c or c.kind ~= 'vehicle' or not IsLive(run) then return false end
    local coords = CoordsOf(run, c.netId)
    SetState(run, c, 'stopped')
    c.towing = true
    local s = Custody.serviceVehicle(run, 'tow', coords,
        { obj = c.obj, target = c.netId, decider = src, point = coords })
    return s ~= nil or (Cfg().tow or {}).enabled == false
end

-- ============================================================================
--                                  DECISIONS
-- ============================================================================

local function ReleaseLater(run, netId)
    local secs = Num(Cfg().releaseDespawn, 30)
    SetTimeout(math.floor(secs * 1000), function()
        if run.state ~= 'ended' then Call('Runs', 'deleteEntity', run, netId) end
    end)
end

-- Released, warned or cited: uncuffed, they walk or drive off and are removed later.
local function LetGo(run, c)
    c.waitCar = nil
    SetState(run, c, 'released', { escortBy = false })
    Custody.act(run, c.netId, 'leave')
    ReleaseLater(run, c.netId)
end

-- A car's occupants once every one of them is settled: with No action and nobody arrested the car is released
-- and drives off with the people who waited in it; otherwise (impounded, or its driver arrested) they get out
-- and walk off.
local function SettleOccupants(run, b, veh)
    if not veh or veh.kind ~= 'vehicle' or not veh.decided then return end
    local occ = Occupants(b, veh.netId)
    local arrested = false
    for _, o in ipairs(occ) do
        local settled = o.decided or o.dead or o.escaped or GONE[o.state]
        if not settled then return end
        if o.decided and o.decided.choice == 'arrest' then arrested = true end
    end
    local drives = veh.decided.choice == 'noAction' and not arrested and veh.role ~= 'parked'
    if drives and veh.state ~= 'released' then
        SetState(run, veh, 'released')
        ReleaseLater(run, veh.netId)
    end
    for _, o in ipairs(occ) do
        if o.waitCar then
            if drives then
                LetGo(run, o)
            else
                o.waitCar = nil
                Custody.act(run, o.netId, 'exit_and_stand', { veh = veh.netId })
                SetTimeout(EXIT_WAIT_MS, function()
                    if IsLive(run) and o.state ~= 'released' then LetGo(run, o) end
                end)
            end
        end
    end
end

local function Dispatch(run, c, src, ev)
    ev.netId = c.netId
    Call('Runs', 'entityEvent', run, c.netId, ev)
end

local function AfterPersonDecision(run, b, c, choice, src)
    if choice == 'arrest' then
        c.arrestedBy = src
        b.arrests = b.arrests or {}
        b.arrests[src] = b.arrests[src] or {}
        b.arrests[src][#b.arrests[src] + 1] = c.netId
        if c.custody == 'handover' then
            Custody.enableChain(run, c.netId, { obj = c.obj, transport = c.transportPoint })
        else
            c.arrestDone = true
        end
        SettleOccupants(run, b, c.vehicleOf and b.contacts[c.vehicleOf])
        return
    end
    local veh = c.vehicleOf and b.contacts[c.vehicleOf]
    -- still seated in a contact car nobody has decided: the host would drive the car away, so they wait in it
    if veh and veh.state ~= 'released' and veh.state ~= 'impounded' and Seated(run, c)
        and not (veh.decided and veh.decided.choice == 'noAction') then
        c.waitCar = true
        SettleOccupants(run, b, veh)
        return
    end
    LetGo(run, c)
    SettleOccupants(run, b, veh)
end

local function Decide(run, b, c, choice, src, opts)
    opts = opts or {}
    local entry, failFact = Custody.grade(run, c.netId, choice, src, opts.beginMs)
    if not entry then return false, 'err.custody_unknown' end
    if entry.verdict == 'critical' and Dec().confirmKnownErrors ~= false and not opts.confirmed
        and entry.failKey ~= 'reason.decision_fail' then
        b.confirms[('%d:%d'):format(src, c.netId)] = { choice = choice, beginMs = opts.beginMs or Now(), at = Now() }
        if opts.viaTarget then
            TriggerClientEvent(CONFIRM_EVENT, src, { netId = c.netId, choice = choice, factKey = failFact })
            HudContact(run, { src }, {
                label = c.label,
                fact = false,
                hint = false,
                confirm = CP.Lt('custody.confirm.' .. tostring(failFact)),
            })
            PushViews(run)
        end
        return 'confirm', failFact
    end
    c.decided = {
        choice = choice,
        by = ParticipantName(run, src),
        bySrc = src,
        verdict = entry.verdict,
        offence = opts.offence,
    }
    local okD, recorded = Call('Runs', 'decide', run, src, entry)
    if not okD or not recorded then
        c.decided = nil
        return false, 'err.custody_refused'
    end
    if not IsLive(run) then return true end
    local good = entry.verdict == 'best' or entry.verdict == 'ok'
    if choice == 'cite' and good then Call('Runs', 'noteStat', run, src, 'citations', 1) end
    if choice == 'impound' and good then Call('Runs', 'noteStat', run, src, 'impounds', 1) end
    if c.kind == 'person' then
        AfterPersonDecision(run, b, c, choice, src)
    else
        if choice == 'impound' then Custody.impound(run, c.netId, src) end
        SettleOccupants(run, b, c)
    end
    Dispatch(run, c, src,
        { type = 'decide', choice = choice, offence = opts.offence, verdict = entry.verdict, src = src })
    HudContact(run, { src }, { label = c.label, fact = false, hint = false, confirm = false })
    PushViews(run)
    return true
end

-- A contact the objective ended with no disposition: missed (Config.Decisions.undecidedAtEnd), never a fail.
-- Charged to the officer who last worked it, else the host.
function Custody.closeObjective(run, obj)
    local b = type(run) == 'table' and books[run.id]
    if not b or not IsLive(run) then return 0 end
    local n = 0
    for _, c in ipairs(Custody.contactsOf(run, obj)) do
        if not c.decided and not c.chain and not GONE[c.state] and not c.escaped and not c.dead then
            local src = (c.lastBy and ActiveP(run, c.lastBy) and c.lastBy) or run.host
            if src and ActiveP(run, src) then
                local id = Dec().undecidedAtEnd or 'missed_offence'
                c.decided = { choice = 'none', by = ParticipantName(run, src), bySrc = src, verdict = 'wrong' }
                Call('Runs', 'decide', run, src, {
                    contact = c.label,
                    kind = c.kind,
                    choice = 'none',
                    verdict = 'wrong',
                    bonusId = id,
                    truthKey = EffectiveTruth(b, c),
                    bestChoice = BEST[EffectiveTruth(b, c)] or 'release',
                    facts = {},
                    discoverable = Discoverable(b, c),
                    netId = c.netId,
                })
                n = n + 1
            end
        end
    end
    return n
end

-- ============================================================================
--                                 THE ACTIONS
-- ============================================================================

local function RevealTalk(run, b, c, src)
    local t = c.truth
    local k = c.cues or {}
    if t == 'suspended' then
        Custody.reveal(run, c.netId, 'suspended', src)
    else
        Custody.reveal(run, c.netId, 'id_ok', src)
    end
    Custody.reveal(run, c.netId, t == 'warrant' and 'warrant' or 'clear', src)
    if t == 'intoxicated' then Custody.reveal(run, c.netId, 'intoxicated', src) end
    if k.odour then Custody.reveal(run, c.netId, 'odour_cannabis', src) end
    if t == 'minor' then
        Custody.reveal(run, c.netId, 'minor', src, { vars = { offence = CP.L('custody.minor.' .. tostring(k.minor)) } })
    end
    if k.admits then
        Custody.reveal(run, c.netId, 'admission', src, { vars = { item = CP.L('custody.item.' .. CONTRABAND[t]) } })
    end
    if c.vehicleOf and b.contacts[c.vehicleOf] then
        Custody.reveal(run, c.netId, k.consents and 'consent' or 'refused', src)
    end
end

local function Bolt(run, c, src, behaviour)
    c.evading = true
    c.ran = true
    Call('Runs', 'notePerson', run, c.netId, { did = 'ran' })
    Custody.reveal(run, c.netId, 'evading', src)
    local obj = ObjOf(run, c.obj)
    local points = nil
    local key = obj.fleeTo
    local list = type(key) == 'string' and run.location and run.location[key] or nil
    if type(list) == 'table' and #list > 0 then points = U.serialize(list[((c.netId - 1) % #list) + 1]) end
    Custody.act(run, c.netId, behaviour or 'flee_on_order', { points = points })
end

local function Draw(run, c)
    Custody.act(run, c.netId, 'tell_then_draw')
end

local function ApplyOrderOut(run, b, veh, src)
    for _, o in ipairs(Occupants(b, veh.netId)) do
        if o.state == 'idle' and Seated(run, o) then
            if o.demeanour == 'hostile' and o.truth == 'armed' then
                Draw(run, o)
            elseif (o.cues or {}).bolts then
                Bolt(run, o, src, 'flee_on_order')
            else
                SetState(run, o, 'contacted')
                Custody.act(run, o.netId, 'exit_and_stand', { veh = veh.netId })
            end
        end
    end
end

local function ApplySearchVehicle(run, b, veh, src)
    local needCause = ObjOf(run, veh.obj).probableCause ~= false
    local lawful = not needCause or Custody.probableCause(run, veh.netId)
    if not lawful then Call('Runs', 'penalize', run, 'unlawful_search', { src = src }) end
    local found = false
    local owners = Occupants(b, veh.netId)
    for _, o in pairs(b.contacts) do
        if o.kind == 'person' and o.vehicleOf == veh.netId and not U.contains(owners, o) then
            owners[#owners + 1] = o
        end
    end
    for _, o in ipairs(owners) do
        local item = CONTRABAND[o.truth]
        if item and (o.cues or {}).where == 'car' then
            found = true
            local key = 'veh_' .. item
            Custody.reveal(run, veh.netId, key, src, { suppressed = not lawful })
            -- the find also counts for the person it belongs to
            Custody.reveal(run, o.netId, key, src, { suppressed = not lawful, silent = true })
        end
    end
    if not found then Custody.reveal(run, veh.netId, 'veh_clear', src, { suppressed = not lawful }) end
    return lawful
end

local function ApplyLookInside(run, b, veh, src)
    for _, o in ipairs(Occupants(b, veh.netId)) do
        local k = o.cues or {}
        if CONTRABAND[o.truth] and k.where == 'car' and k.plainView then
            Custody.reveal(run, veh.netId, 'plain_view', src,
                { vars = { item = CP.L('custody.item.' .. CONTRABAND[o.truth]) } })
            return
        end
    end
    Custody.reveal(run, veh.netId, 'plain_clear', src)
end

local function ApplyRunPlate(run, b, veh, src)
    if veh.truth == 'stolen' then
        Custody.reveal(run, veh.netId, 'stolen', src)
        return
    end
    Custody.reveal(run, veh.netId, 'plate_valid', src)
    local owner = veh.owner and b.contacts[veh.owner]
    if owner and owner.truth == 'warrant' then
        Custody.reveal(run, veh.netId, 'owner_warrant', src)
        Custody.reveal(run, owner.netId, 'warrant', src)
    end
end

local SPOT_FACT = { metered = 'spot_meter', permit = 'spot_permit' }

local function ApplyInspect(run, veh, src)
    local rule = veh.spot and veh.spot.rule or 'free'
    local vars = { rule = CP.L('custody.rule.' .. tostring(rule)), street = veh.spot and veh.spot.street or '' }
    if veh.truth == 'violation' then
        Custody.reveal(run, veh.netId, SPOT_FACT[rule] or 'spot_blocking', src, { vars = vars })
    else
        Custody.reveal(run, veh.netId, 'spot_legal', src, { vars = vars })
    end
end

local function OfficerVehicle(run, src)
    local p = run.participants[src]
    local netId = p and p.vehicle and tonumber(p.vehicle.lastNetId)
    if not netId then return nil end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if not Exists(ent) then return nil end
    return ent, netId
end

local function ApplySeat(run, c, src)
    local veh = OfficerVehicle(run, src)
    local sc = PlayerCoords(src)
    if not veh or not sc
        or U.dist(sc, GetEntityCoords(veh)) > Num((Cfg().reach or {}).seatVehicle, 5.0) + REACH_SLACK_M then
        return false, 'err.custody_no_vehicle'
    end
    local seat = nil
    for _, s in ipairs({ 1, 2 }) do
        if not Exists(GetPedInVehicleSeat(veh, s)) then
            seat = s
            break
        end
    end
    if not seat then return false, 'err.custody_vehicle_full' end
    c.escortBy = nil
    c.seatedIn = NetworkGetNetworkIdFromEntity(veh)
    c.seatedBy = src
    SetState(run, c, 'seated', { escortBy = false, seatedIn = c.seatedIn, seat = seat })
    local ped = EntityOf(run, c.netId)
    if ped and SetPedIntoVehicle then SetPedIntoVehicle(ped, veh, seat) end
    return true
end

local function ApplyHandover(run, b, src)
    local t = b.transport
    local van = t and t.veh and EntityOf(run, t.veh)
    local sc = PlayerCoords(src)
    if not van or not sc or U.dist(sc, GetEntityCoords(van)) > HANDOVER_REACH_M then
        return false, 'err.custody_no_transport'
    end
    local vc = GetEntityCoords(van)
    local range = Num((Cfg().reach or {}).van, 20.0)
    local moved = 0
    local seats = { 1, 2, 0 }
    local list = {}
    for _, c in pairs(b.contacts) do list[#list + 1] = c end
    table.sort(list, function(a, x) return a.netId < x.netId end)
    for _, c in ipairs(list) do
        local mine = (c.state == 'escorted' and c.escortBy == src) or (c.state == 'seated' and c.seatedBy == src)
        local cc = CoordsOf(run, c.netId)
        if mine and cc and U.dist(cc, vc) <= range then
            local armedUnsearched = c.truth == 'armed' and (c.cues or {}).where ~= 'car' and not c.done.searchPerson
                and not c.done.frisk
            if armedUnsearched then Call('Runs', 'penalize', run, 'unsearched_transport', { src = src }) end
            c.handedBy = src
            c.escortBy = nil
            SetState(run, c, 'handed_over', { escortBy = false })
            local ped = EntityOf(run, c.netId)
            local seat = nil
            for i, s in ipairs(seats) do
                if not Exists(GetPedInVehicleSeat(van, s)) then
                    seat = s
                    table.remove(seats, i)
                    break
                end
            end
            if ped and seat and SetPedIntoVehicle then
                SetPedIntoVehicle(ped, van, seat)
                t.cargo[#t.cargo + 1] = c.netId
            end
            moved = moved + 1
            Dispatch(run, c, src, { type = 'handed_over', src = src })
            if not seat then Call('Runs', 'deleteEntity', run, c.netId) end
        end
    end
    if moved == 0 then return false, 'err.custody_nobody_to_hand_over' end
    return true
end

-- The effect of a validated finish. Returns ok, errKey.
local function Apply(run, b, c, action, src, extra, beginMs)
    c.done[action == 'runPlateFromVehicle' and 'runPlate' or action] = true
    c.lastBy = src
    if action == 'talk' then
        if c.state == 'idle' and not Seated(run, c) then SetState(run, c, 'contacted') end
        c.walking = false
        RevealTalk(run, b, c, src)
    elseif action == 'frisk' then
        if (c.cues or {}).bolts and c.state == 'contacted' and not c.acted.flee_on_order then
            Bolt(run, c, src, 'flee_on_order')
        else
            local armedHere = c.truth == 'armed' and (c.cues or {}).where ~= 'car'
            Custody.reveal(run, c.netId, armedHere and 'weapon' or 'frisk_clear', src)
        end
    elseif action == 'detain' then
        c.detainedBy = src
        SetState(run, c, 'cuffed')
    elseif action == 'searchPerson' then
        local item = CONTRABAND[c.truth]
        if item and (c.cues or {}).where ~= 'car' then
            Custody.reveal(run, c.netId, item, src)
        else
            Custody.reveal(run, c.netId, 'search_clear', src)
        end
    elseif action == 'lookInside' then
        ApplyLookInside(run, b, c, src)
    elseif action == 'runPlate' or action == 'runPlateFromVehicle' then
        ApplyRunPlate(run, b, c, src)
    elseif action == 'inspect' then
        ApplyInspect(run, c, src)
    elseif action == 'orderOut' then
        ApplyOrderOut(run, b, c, src)
    elseif action == 'searchVehicle' then
        ApplySearchVehicle(run, b, c, src)
    elseif action == 'explain' then
        c.arguing = false
    elseif action == 'escort' then
        if c.state == 'escorted' then
            StopEscort(run, c)
        else
            if c.state == 'seated' then
                local ped = EntityOf(run, c.netId)
                if ped and ClearPedTasksImmediately then ClearPedTasksImmediately(ped) end
            end
            c.escortBy = src
            c.seatedIn, c.seatedBy = nil, nil
            SetState(run, c, 'escorted', { escortBy = src })
        end
    elseif action == 'seat' then
        local ok, why = ApplySeat(run, c, src)
        if not ok then return false, why end
    elseif action == 'handover' then
        local ok, why = ApplyHandover(run, b, src)
        if not ok then return false, why end
    elseif DECISIONS[action] then
        local res, why = Decide(run, b, c, action, src,
            { beginMs = beginMs, offence = extra.offence, viaTarget = true })
        if res == 'confirm' then return true end
        if not res then return false, why end
        return true
    end
    Dispatch(run, c, src, { type = 'action', action = action, phase = 'finish', src = src })
    PushViews(run)
    return true
end

-- ============================================================================
--                         BEGIN AND FINISH (net event)
-- ============================================================================

local function Refuse(src, key, why)
    CP.log(TAG, 'action by %s refused: %s', tostring(src), why or key)
    if key then Notify(src, 'error', key) end
    return false, key
end

-- Checks shared by both halves. Returns run, book, contact or false, errKey.
local function Resolve(src, runId, netId, action, extra)
    if type(runId) ~= 'string' or #runId == 0 or #runId > MAX_RUNID then return false, 'err.npc_invalid' end
    if type(action) ~= 'string' or not ACTIONS[action] then return false, 'err.npc_invalid' end
    local run = RunById(runId)
    if not IsLive(run) then return false, 'err.npc_run_not_active' end
    local p = ActiveP(run, src)
    if not p then return false, 'err.npc_not_on_run' end
    if not p.arrived then return false, 'err.npc_not_arrived' end
    if InArena(src) then return false, 'err.npc_in_arena' end
    if not OnDuty(src) then return false, 'err.npc_not_officer' end
    local b = books[run.id]
    if not b then return false, 'err.npc_unknown' end
    local c
    if action == 'runPlateFromVehicle' then
        c = CarInFront(run, b, src)
        if not c then return false, 'err.custody_no_car_ahead' end
    elseif action == 'seat' or action == 'handover' then
        c = b.contacts[ToInt(tonumber(netId), 1, MAX_NETID) or -1]
        if not c then
            for _, x in pairs(b.contacts) do
                if x.state == 'escorted' and x.escortBy == src then c = x end
            end
        end
        if not c and action == 'handover' then
            for _, x in pairs(b.contacts) do
                if x.state == 'seated' and x.seatedBy == src then c = x end
            end
        end
    else
        netId = ToInt(tonumber(netId), 1, MAX_NETID)
        if not netId then return false, 'err.npc_invalid' end
        local seat = extra and DOOR_SEATS[extra.door]
        if seat ~= nil then
            c = SeatedPerson(run, b, netId, seat)
        else
            c = b.contacts[netId]
        end
    end
    if not c then return false, 'err.npc_unknown' end
    if not run.entities[c.netId] or run.entities[c.netId].dead then return false, 'err.npc_unknown' end
    local kind = ACTIONS[action]
    if kind ~= 'any' and kind ~= c.kind then return false, 'err.npc_invalid' end
    -- the owning objective (after any adoption) must be the current one
    local okO, owner = Call('Runs', 'ownerOf', run, c.netId)
    local o = okO and owner and run.objectives[owner]
    if not o or o.status ~= 'active' then return false, 'err.custody_not_current' end
    c.obj = owner
    if not Allowed(c, action) then return false, 'err.custody_action' end
    return run, b, c
end

local function HandcuffsOk(src)
    local item = Cfg().handcuffsItem
    if not item or item == '' then return true end
    if GetResourceState('ox_inventory') ~= 'started' then return false end
    local ok, n = pcall(function() return exports.ox_inventory:Search(src, 'count', item) end)
    return ok and (tonumber(n) or 0) > 0
end

function Custody.begin(src, runId, netId, action, extra)
    local run, b, c = Resolve(src, runId, netId, action, extra)
    if not run then return Refuse(src, b, 'resolve') end
    local ok, why = StateOk(run, b, c, action, src)
    if not ok then return Refuse(src, why, 'state ' .. tostring(c.state)) end
    if not InReach(run, c, action, src) then return Refuse(src, 'err.npc_too_far', 'reach at begin') end
    if action == 'detain' and not HandcuffsOk(src) then return Refuse(src, 'err.custody_no_handcuffs') end
    local target = WatchTarget(run, c, action)
    b.begins[src] = { netId = c.netId, action = action, at = Now(), target = target }
    if TimeOf(action) >= SAMPLED_FROM_S and action ~= 'seat' then
        Call('Npc', 'watch', run, target, src, ReachFor(c, action, Seated(run, c)) + REACH_SLACK_M)
    end
    return true
end

function Custody.finish(src, runId, netId, action, extra)
    extra = type(extra) == 'table' and extra or {}
    local run, b, c = Resolve(src, runId, netId, action, extra)
    if not run then return Refuse(src, b, 'resolve') end
    local bg = b.begins[src]
    b.begins[src] = nil
    if not bg or bg.netId ~= c.netId or bg.action ~= action then
        return Refuse(src, 'err.npc_too_fast', 'finish without a begin')
    end
    local need = (TimeOf(action) - Num(Cfg().actionSlack, 0.5)) * 1000
    local t = Now()
    if t - bg.at < need then return Refuse(src, 'err.npc_too_fast', ('%d ms of %d'):format(t - bg.at, need)) end
    local ok, why = StateOk(run, b, c, action, src)
    if not ok then return Refuse(src, why, 'state at finish') end
    if not InReach(run, c, action, src) then return Refuse(src, 'err.npc_too_far', 'reach at finish') end
    if TimeOf(action) >= SAMPLED_FROM_S and action ~= 'seat' then
        local okS, since = Call('Npc', 'inReachSince', run, bg.target, src)
        Call('Npc', 'unwatch', bg.target, src)
        local dwell = TimeOf(action) * 1000 - DWELL_SLACK_MS
        if okS and (not since or t - since < dwell) then
            return Refuse(src, 'err.npc_too_fast', 'not in reach for the action')
        end
    end
    local done, why = Apply(run, b, c, action, src, extra, bg.at)
    if not done then return Refuse(src, why, 'effect') end
    return true
end

RegisterNetEvent(ACTION_EVENT, function(runId, netId, action, phase, extra)
    local src = source
    if not CP.Net.rateOk(src, ACTION_EVENT, 4, 2000) then
        CP.log(TAG, 'custody action from %s rate limited', tostring(src))
        return
    end
    local fn = phase == 'begin' and Custody.begin or (phase == 'finish' and Custody.finish or nil)
    if not fn then return end
    local ok, err = pcall(fn, src, runId, netId, action, type(extra) == 'table' and extra or nil)
    if not ok then
        CP.err(TAG, 'custody %s/%s from %s failed: %s', tostring(action), tostring(phase), src, tostring(err))
    end
end)

-- ============================================================================
--                   TABLET DECISIONS (server:contactDecide)
-- ============================================================================

local function ContactDecide(src, payload)
    if type(payload) ~= 'table' then return false, 'err.npc_invalid' end
    local choice = payload.choice
    if type(choice) ~= 'string' or not DECISIONS[choice] then return false, 'err.npc_invalid' end
    local run, b, c = Resolve(src, payload.runId, payload.netId, choice, nil)
    if not run then return false, b end
    local ok, why = StateOk(run, b, c, choice, src)
    if not ok then return false, why end
    if DistTo(run, c, src) > DECIDE_REACH_M then return false, 'err.npc_too_far' end
    local offence = type(payload.offence) == 'string' and payload.offence:sub(1, 32) or nil
    local key = ('%d:%d'):format(src, c.netId)
    local pending = b.confirms[key]
    local beginMs = Now()
    if payload.confirmed == true and pending and pending.choice == choice and Now() - pending.at <= CONFIRM_KEEP_MS then
        beginMs = pending.beginMs
    end
    b.confirms[key] = nil
    local res, fact = Decide(run, b, c, choice, src,
        { beginMs = beginMs, offence = offence, confirmed = payload.confirmed == true })
    if res == 'confirm' then return true, { confirm = { factKey = fact } } end
    if not res then return false, fact end
    return true, { ok = true }
end

CP.Net.action('server:contactDecide', ContactDecide, { rate = 3 })

-- ============================================================================
--                          EXCESSIVE FORCE (stun_hit)
-- ============================================================================

-- One excessive_force per person per FORCE_WINDOW_MS (CP.Npc calls this for weaponDamageEvent and health drops).
function Custody.noteForce(run, netId, src)
    local b = type(run) == 'table' and BookOf(run)
    if not b or not IsLive(run) or not ActiveP(run, src) then return false end
    local t = Now()
    local last = b.force[netId]
    if last and t - last < FORCE_WINDOW_MS then return false end
    b.force[netId] = t
    Call('Runs', 'penalize', run, 'excessive_force', { src = src })
    Notify(src, 'warning', 'custody.excessive_force')
    return true
end

RegisterNetEvent(STUN_EVENT, function(netId)
    local src = source
    if not CP.Net.rateOk(src, STUN_EVENT, 2, 1000) then return end
    netId = ToInt(tonumber(netId), 1, MAX_NETID)
    if not netId then return end
    local ok, err = pcall(function()
        local okM, matched = Call('Npc', 'stunMatches', netId, STUN_MATCH_MS)
        if not okM or not matched then return end
        local okR, run = Call('Npc', 'runOf', netId)
        if not okR or not IsLive(run) or not ActiveP(run, src) or InArena(src) then return end
        local okS, state = Call('Npc', 'getState', netId)
        if okS and (state == 'cuffed' or state == 'escorted' or state == 'seated' or state == 'contacted') then
            Custody.noteForce(run, netId, src)
        end
    end)
    if not ok then CP.err(TAG, 'stunHit from %s failed: %s', tostring(src), tostring(err)) end
end)

-- ============================================================================
--                                     VIEW
-- ============================================================================

local NOT_CHECKED = {
    person = { { 'id', 'talk' }, { 'frisk', 'frisk' }, { 'search', 'searchPerson' } },
    vehicle = { { 'plate', 'runPlate' }, { 'inside', 'lookInside' }, { 'search', 'searchVehicle' } },
}

local function OffencesFor(c)
    local list = (Cfg().offences or {})[c.kind == 'vehicle' and 'vehicle' or 'person'] or {}
    local out = {}
    for _, id in ipairs(list) do out[#out + 1] = { id = id, label = CP.L('custody.offence.' .. id) } end
    return out
end

local function EntryOf(run, b, c, src)
    local facts = {}
    for _, f in ipairs(c.facts) do
        facts[#facts + 1] = {
            key = f.key,
            text = FactText(c, f),
            by = f.by,
            at = f.at,
            suppressed = f.suppressed == true,
            cause = f.cause == true,
        }
    end
    local notChecked = {}
    for _, pair in ipairs(NOT_CHECKED[c.kind]) do
        if U.contains(c.actions, pair[2]) and not c.done[pair[2]] then notChecked[#notChecked + 1] = pair[1] end
    end
    local actions = {}
    for _, a in ipairs(c.actions) do
        if not DECISIONS[a] and StateOk(run, b, c, a, src) then actions[#actions + 1] = a end
    end
    local choices = {}
    if not c.decided and not c.chain then
        for _, choice in ipairs(c.kind == 'vehicle' and VEHICLE_CHOICES or PERSON_CHOICES) do
            if U.contains(c.actions, choice) and StateOk(run, b, c, choice, src) then
                -- only a knowing error is flagged: a mission's stricter rule would give the truth away
                local entry = Custody.grade(run, c.netId, choice, src, Now())
                choices[#choices + 1] = {
                    id = choice,
                    label = CP.L('custody.choice.' .. choice),
                    failsCase = entry ~= nil and entry.verdict == 'critical'
                        and entry.failKey ~= 'reason.decision_fail',
                }
            end
        end
    end
    local freeToLeave = c.kind == 'person' and c.consensual == true and c.state ~= 'cuffed' and not c.evading
        and not IN_CUSTODY[c.state]
    return {
        netId = c.netId,
        label = c.label,
        kind = c.kind,
        role = c.role,
        state = c.state,
        tellSeen = c.tellSeen,
        freeToLeave = freeToLeave,
        notChecked = notChecked,
        facts = facts,
        actions = actions,
        choices = choices,
        offences = OffencesFor(c),
        decided = c.decided and { choice = c.decided.choice, by = c.decided.by } or nil,
        confirm = b.confirms[('%d:%d'):format(src, c.netId)] and {
            choice = b.confirms[('%d:%d'):format(src, c.netId)].choice,
        } or nil,
    }
end

-- ContactView for objective obj as src sees it (web/src/types/custody.ts), or nil when it has no contacts.
function Custody.view(run, obj, src)
    local b = type(run) == 'table' and books[run.id]
    if not b then return nil end
    src = tonumber(src)
    local entries, cause = {}, {}
    for _, c in ipairs(Custody.contactsOf(run, obj)) do
        if c.state ~= 'handed_over' or not c.chain then entries[#entries + 1] = EntryOf(run, b, c, src) end
        if c.kind == 'vehicle' then cause[c.netId] = Custody.probableCause(run, c.netId) == true end
    end
    if #entries == 0 then return nil end
    return { entries = entries, probableCause = cause, transport = Custody.transport(run, src) }
end

-- ============================================================================
--                                   THE TICK
-- ============================================================================

local function TickBook(run, b)
    for _, s in ipairs(U.copy(b.services)) do
        local ok, err = pcall(TickService, run, s)
        if not ok then CP.err(TAG, 'service %s of run %s failed: %s', tostring(s.kind), run.id, tostring(err)) end
    end
    local keep = {}
    for _, s in ipairs(b.services) do if s.status ~= 'gone' then keep[#keep + 1] = s end end
    b.services = keep
    -- an escort whose officer left the run or entered the arena stops and waits where they are
    for _, c in pairs(b.contacts) do
        if c.state == 'escorted' and (not ActiveP(run, c.escortBy) or InArena(c.escortBy)) then StopEscort(run, c) end
    end
    local t = Now()
    for key, cf in pairs(b.confirms) do
        if t - cf.at > CONFIRM_KEEP_MS then b.confirms[key] = nil end
    end
end

function Custody._tick()
    for runId, b in pairs(books) do
        local run = RunById(runId)
        if not run or run.state == 'ended' then
            books[runId] = nil
        elseif run.state == 'in_progress' then
            TickBook(run, b)
        end
    end
end

CreateThread(function()
    while true do
        Wait(TICK_MS)
        local ok, err = pcall(Custody._tick)
        if not ok then CP.err(TAG, 'tick failed: %s', tostring(err)) end
    end
end)

-- The objective's service vehicle (coroner): mark it released so it leaves.
function Custody.releaseService(run, s)
    if type(s) == 'table' then s.released = true end
end

-- The service vehicles of a run (tests and the admin debug view).
function Custody._servicesOf(run)
    local b = type(run) == 'table' and books[run.id]
    return b and b.services or {}
end

function Custody.serviceStatus(s)
    if type(s) ~= 'table' then return nil end
    return s.status, s.veh
end

-- ============================================================================
--                            THE EVIDENCE BAG ITEM
-- ============================================================================
-- Config.Custody.evidenceItem (off by default): one per participant of a run with a contact or scene objective,
-- given when the run starts, tagged like every mission item and taken back by the engine when the run ends.

local EVIDENCE_BLOCKS = { field_contact = true, process_scene = true }

local function UsesEvidence(run)
    local list = type(run.mission) == 'table' and run.mission.objectives or nil
    for _, o in ipairs(type(list) == 'table' and list or {}) do
        if type(o) == 'table' and EVIDENCE_BLOCKS[o.block] then return true end
    end
    return false
end

function Custody.giveEvidence(run)
    local item = Cfg().evidenceItem
    if type(item) ~= 'string' or item == '' or not IsLive(run) or not UsesEvidence(run) then return 0 end
    if GetResourceState('ox_inventory') ~= 'started' then return 0 end
    local n = 0
    for _, src in ipairs(ActiveSrcs(run)) do
        local p = run.participants[src]
        if p and not p.evidenceGiven and not InArena(src) then
            local ok, res = pcall(function()
                return exports.ox_inventory:AddItem(src, item, 1, { cpRun = run.id, cpItem = true })
            end)
            if ok and res then
                p.evidenceGiven = true
                p.items = p.items or {}
                p.items[#p.items + 1] = { name = item, count = 1 }
                n = n + 1
            else
                CP.warn(TAG, 'could not give %s to %s for run %s', item, tostring(src), run.id)
            end
        end
    end
    return n
end

if CP.Hooks and CP.Hooks.on then
    CP.Hooks.on('run:inProgress', function(run) Custody.giveEvidence(run) end)
end

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if not src then return end
    for _, b in pairs(books) do b.begins[src] = nil end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    books = {}
end)

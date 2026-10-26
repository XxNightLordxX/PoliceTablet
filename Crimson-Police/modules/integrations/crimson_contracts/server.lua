-- CP.CrimsonContracts (server): the adapter for Crimson-Contracts' server-only contract events (its step VC3, sent only
-- with ContractsConfig.LifecycleEvents = true). The only Crimson-Police file that knows their names and payloads: it
-- checks each one and hands a clean copy to CP.LiveCrime. Every server id in a payload is ignored (C9).

CP.CrimsonContracts = CP.CrimsonContracts or {}
local CC = CP.CrimsonContracts
local TAG = 'crimson_contracts'

local PREFIX = 'crimson-contracts:server:'
local WARN_EVERY = 60             -- seconds between two warnings about the same script and event
local MAX_MEMBERS = 16            -- crew members one contract can report
local MAX_COORD = 100000.0        -- a coordinate further from 0 than this is not on the map
local NAME_PATTERN = '^[%w_%-]+$' -- a uid, a contract key, a citizenid, a call id

-- Each event and the CP.LiveCrime function that gets its clean payload as (resource, data).
CC.EVENTS = {
    contractStarted = 'onStarted',
    dispatchSent = 'onAlert',
    contractEnded = 'onEnded',
    memberRejoined = 'onRejoined',
    crewShot = 'onCrewShot',
}

local warnedAt = {}               -- [what] = os.time() of its last warning

-- ============================================================================
--                                   HELPERS
-- ============================================================================

-- Read on every event, so turning it on in Admin UI → Settings needs no restart (C29).
local function On() return type(Config.LiveCrime) == 'table' and Config.LiveCrime.enabled == true end

local function WarnOnce(what, fmt, ...)
    local now = os.time()
    if warnedAt[what] and now - warnedAt[what] < WARN_EVERY then return end
    warnedAt[what] = now
    CP.warn(TAG, fmt, ...)
end

-- Whether this resource may report a crime (Config.LiveCrime.sources, read now).
local function Allowed(res)
    local list = Config.LiveCrime.sources
    if type(res) ~= 'string' or res == '' or type(list) ~= 'table' then return false end
    for _, name in ipairs(list) do
        if name == res then return true end
    end
    return false
end

-- Crimson-Contracts' contract number (a whole number from 1), or nil.
local function Id(v)
    local n = type(v) == 'number' and math.tointeger(v) or nil
    if not n or n < 1 or n > 2147483647 then return nil end
    return n
end

-- A name of letters, digits, '_' and '-' with at most max characters, or nil.
local function Name(v, max)
    if type(v) ~= 'string' then return nil end
    v = CP.U.trim(v)
    if v == '' or #v > max or not v:find(NAME_PATTERN) then return nil end
    return v
end

-- Text that people may read later (a label, a call title, a street): no control characters, trimmed, cut to max
-- bytes. nil when it is not a string.
local function Text(v, max)
    if type(v) ~= 'string' then return nil end
    return CP.U.trim(CP.U.clip((v:gsub('%c', ' ')), max))
end

local function Coord(c) return type(c) == 'number' and c == c and math.abs(c) <= MAX_COORD end

local function Coords(v)
    if type(v) ~= 'table' or not (Coord(v.x) and Coord(v.y) and Coord(v.z)) then return nil end
    return vec3(v.x + 0.0, v.y + 0.0, v.z + 0.0)
end

-- { [citizenid] = true } from Crimson-Contracts' { [citizenid] = server id }: the server ids are never read (C9).
local function Members(v)
    if type(v) ~= 'table' then return nil end
    local out, n = {}, 0
    for cid in pairs(v) do
        n = n + 1
        local clean = Name(cid, 50)
        if n > MAX_MEMBERS or not clean then return nil end
        out[clean] = true
    end
    return n > 0 and out or nil
end

local function Bool(v) return v == nil or type(v) == 'boolean' end

-- ============================================================================
--                        PAYLOAD CHECKS (one per event)
-- ============================================================================
-- Each returns the clean table, or nil when the payload is not what Crimson-Contracts sends (then it is dropped).

local CHECK = {}

function CHECK.contractStarted(p)
    local id, uid, key = Id(p.id), Name(p.uid, 32), Name(p.key, 64)
    local label, place = Text(p.label, 64), Text(p.locationLabel, 64)
    local coords, members = Coords(p.coords), Members(p.members)
    if not (id and uid and key and label and place and coords and members) or not Bool(p.test) then return nil end
    local started = type(p.startedAt) == 'number' and math.tointeger(p.startedAt) or nil
    return {
        id = id,
        uid = uid,
        key = key,
        label = label,
        locationLabel = place,
        coords = coords,
        members = members,
        leader = Name(p.leaderCitizenId, 50),
        startedAt = started,
        test = p.test == true,
    }
end

function CHECK.dispatchSent(p)
    local id, uid = Id(p.id), Name(p.uid, 32)
    local title, street = Text(p.title, 50), Text(p.street, 100)
    local dispatchId = Name(p.dispatchId, 64)
    local coords = Coords(p.coords)
    if not (id and uid and title and street) then return nil end
    if (p.dispatchId ~= nil and not dispatchId) or (p.coords ~= nil and not coords) then return nil end
    return { id = id, uid = uid, dispatchId = dispatchId, title = title, street = street, coords = coords }
end

function CHECK.contractEnded(p)
    local id, uid, outcome = Id(p.id), Name(p.uid, 32), Name(p.outcome, 16)
    if not (id and uid and outcome) then return nil end
    return { id = id, uid = uid, outcome = outcome, reason = Text(p.reason, 128) }
end

-- p.src (the new server id) is ignored: CP.Opponents finds him again by his citizenid when his character loads.
function CHECK.memberRejoined(p)
    local id, uid, cid = Id(p.id), Name(p.uid, 32), Name(p.citizenid, 50)
    if not (id and uid and cid) then return nil end
    return { id = id, uid = uid, citizenid = cid }
end

function CHECK.crewShot(p)
    local id, uid, cid = Id(p.id), Name(p.uid, 32), Name(p.citizenid, 50)
    local trigger = Name(p.trigger, 16)
    if not (id and uid and cid and trigger) or not Bool(p.suppressed) then return nil end
    return { id = id, uid = uid, citizenid = cid, suppressed = p.suppressed == true, trigger = trigger }
end

-- ============================================================================
--                                   HANDLERS
-- ============================================================================
-- AddEventHandler only, never RegisterNetEvent: clients cannot send a server event, so only server scripts reach
-- these. Registered always and off at once while Config.LiveCrime.enabled is not true.

local function Handle(name, payload)
    if not On() then return end
    local res = GetInvokingResource()
    if not Allowed(res) then
        WarnOnce('source:' .. tostring(res), '%s from %s ignored: that script is not in Config.LiveCrime.sources',
            PREFIX .. name, tostring(res or 'an unknown script'))
        return
    end
    local data = type(payload) == 'table' and CHECK[name](payload) or nil
    if not data then
        WarnOnce('payload:' .. res .. ':' .. name, '%s from %s ignored: its data is not what Crimson-Contracts sends',
            PREFIX .. name, res)
        return
    end
    local fnName = CC.EVENTS[name]
    local fn = CP.LiveCrime and CP.LiveCrime[fnName]
    if type(fn) ~= 'function' then return end
    local ok, err = pcall(fn, res, data)
    if not ok then WarnOnce('error:' .. name, 'CP.LiveCrime.%s failed: %s', fnName, tostring(err)) end
end

for name in pairs(CC.EVENTS) do
    AddEventHandler(PREFIX .. name, function(payload) Handle(name, payload) end)
end

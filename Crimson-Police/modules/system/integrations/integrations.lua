-- CP.Integrations (server): which other script serves each job Crimson-Police shares with the city (dispatch,

-- CP.Integrations (server): which other script serves each job Crimson-Police shares with the city (dispatch,
-- ambulance, banking, police actions), and the one front door per job that every module calls (CP.Dispatch,
-- CP.Ambulance, CP.Banking, CP.Police). Each supported script has one adapter file next to this one that registers
-- itself here; a city adds its own the same way (docs/dev/INTEGRATIONS.md "Adding an adapter").
--
-- Config.Integrations.<kind>: 'auto' = the first started script of ORDER[kind] (the owner's scripts first), a
-- resource name = that script only, 'none' = no script (the feature that needs one turns itself off). Read on every
-- call, so a change in Admin UI -> Settings needs no restart. 'auto' keeps the script it found (a restart of it does
-- not move the job to another script).
--
-- Public API
--   CP.Integrations.register(kind, resource, adapter) -> boolean   an adapter file adds itself (a resource not in
--                                                                   ORDER joins the end of the auto order)
--   CP.Integrations.pick(kind) -> resource|nil, why                 the script serving kind now; why = 'off' |
--                                                                   'missing' | 'no_adapter' when nil
--   CP.Integrations.adapter(kind) -> table|nil                      that script's adapter
--   CP.Integrations.is(kind, resource) -> boolean                   resource serves kind now
--   CP.Integrations.status() -> { { kind, setting, active, why } }  for Config health and Admin UI -> System
--   CP.Integrations.featureOff(featureKey) -> text|nil              why a feature of Settings -> Features is off
--   CP.Integrations.realSuspectsBlocked() -> boolean                live crimes and volunteers need cuff + jail facts

CP.Integrations = CP.Integrations or {}
local I = CP.Integrations
local TAG = 'integrations'

local KINDS = { 'dispatch', 'ambulance', 'banking', 'police' }
-- 'auto' tries these in order: the first one that is started serves the job.
local ORDER = {
    dispatch = { 'sc-dispatch', 'ps-dispatch' },
    ambulance = { 'sc-ambulance', 'qbx_ambulancejob' },
    banking = { 'Renewed-Banking' },
    police = { 'sc-police', 'qbx_policejob' },
}
local REPORT_DELAY_MS = 5000   -- the start-up lines: after the other scripts of server.cfg have started

local adapters = { dispatch = {}, ambulance = {}, banking = {}, police = {} } -- adapters[kind][resource] = table
local found = {} -- found[kind] = the script 'auto' found (kept)
local said = {} -- said[kind] = what the last console line said, so each change prints one line

I.KINDS, I.ORDER = KINDS, ORDER

local function Setting(kind)
    local all = type(Config.Integrations) == 'table' and Config.Integrations or {}
    local v = all[kind]
    if type(v) ~= 'string' or v == '' then return 'auto' end
    return v
end

local function Started(res) return GetResourceState(res) == 'started' end

function I.register(kind, resource, adapter)
    if not adapters[kind] or type(resource) ~= 'string' or resource == '' or type(adapter) ~= 'table' then
        CP.err(TAG, 'register: unknown kind \'%s\' or a bad adapter for \'%s\'', tostring(kind), tostring(resource))
        return false
    end
    adapters[kind][resource] = adapter
    local order = ORDER[kind]
    for i = 1, #order do
        if order[i] == resource then return true end
    end
    order[#order + 1] = resource
    return true
end

function I.pick(kind)
    if not adapters[kind] then return nil, 'no_adapter' end
    local set = Setting(kind)
    if set == 'none' then return nil, 'off' end
    if set ~= 'auto' then
        if not adapters[kind][set] then return nil, 'no_adapter' end
        return set
    end
    local keep = found[kind]
    if keep and adapters[kind][keep] then return keep end
    for _, res in ipairs(ORDER[kind]) do
        if adapters[kind][res] and Started(res) then
            found[kind] = res
            return res
        end
    end
    return nil, 'missing'
end

function I.adapter(kind)
    local res = I.pick(kind)
    return res and adapters[kind][res] or nil
end

function I.is(kind, resource) return I.pick(kind) == resource end

function I.status()
    local out = {}
    for _, kind in ipairs(KINDS) do
        local res, why = I.pick(kind)
        out[#out + 1] = { kind = kind, setting = Setting(kind), active = res, why = why }
    end
    return out
end

-- One console line per kind each time what serves it changes: which script, or that its features are off and why.
function I.report()
    for _, s in ipairs(I.status()) do
        local key = s.active or ('-' .. tostring(s.why))
        -- (a kind with no adapter file loaded at all, as in a test that loads one adapter: nothing to say)
        local known = next(adapters[s.kind]) ~= nil or s.setting == 'none'
        if known and said[s.kind] ~= key then
            said[s.kind] = key
            if s.active then
                CP.log(TAG, '%s: %s', s.kind, s.active)
            else
                CP.warn(TAG, '%s', CP.L('integrations.off.' .. s.kind, { setting = s.setting, why = s.why }))
            end
        end
    end
end

-- ============================================================================
--                         FEATURES THAT NEED A SCRIPT
-- ============================================================================

-- Live crimes and volunteer suspects detain and book a real player through the police script's cuff and jail facts.
-- (No police adapter registered at all, as in a test that loads none: nothing to judge, not blocked.)
function I.realSuspectsBlocked()
    if Setting('police') ~= 'none' and next(adapters.police) == nil then return false end
    local P = CP.Police
    return not (P and P.has and P.has('cuff') and P.has('jail'))
end

local FEATURE_NEEDS = {
    live_crimes = function() return I.realSuspectsBlocked() and 'integrations.needs.police_facts' or nil end,
    volunteers = function() return I.realSuspectsBlocked() and 'integrations.needs.police_facts' or nil end,
}

function I.featureOff(featureKey)
    local need = FEATURE_NEEDS[featureKey]
    local key = need and need() or nil
    if not key then return nil end
    return CP.L(key, { police = I.pick('police') or Setting('police') })
end

-- ============================================================================
--                          THE FRONT DOOR OF EACH JOB
-- ============================================================================
-- Each function goes to the serving script's adapter function of that name (Via), or answers the default when no
-- script serves the job (or its adapter has no such function).

-- The serving script's adapter function name(...), or default when no script serves (or its adapter lacks it).
local function Via(kind, name, default, ...)
    local a = I.adapter(kind)
    local fn = a and a[name]
    if type(fn) ~= 'function' then return default end
    return fn(...)
end

-- Listener lists: listeners[name] = { fn, ... }; fn added once.
local function Listeners() return {} end

local function AddTo(list, fn)
    for i = 1, #list do
        if list[i] == fn then return end
    end
    list[#list + 1] = fn
end

local errorAt = {}             -- errorAt[key] = os.time() of the last listener error logged (one a minute)

local function LogOnce(key, fmt, ...)
    local now = os.time()
    if errorAt[key] and now - errorAt[key] < 60 then return end
    errorAt[key] = now
    CP.err(TAG, fmt, ...)
end

-- True only while CP.Opponents says a real-suspect case is open; false while that module is missing.
function I.caseOpen()
    local opp = CP.Opponents
    if not (opp and opp.active) then return false end
    local ok, on = pcall(opp.active)
    return ok and on == true
end

-- A whole number lo..hi, or nil.
function I.whole(v, lo, hi)
    local n = tonumber(v)
    n = n and math.tointeger(n)
    if n and n >= lo and n <= hi then return n end
    return nil
end

-- ---------------------------------------------------------------- DISPATCH --
-- CP.Dispatch: real calls (who responds, which calls are active, cleared calls) and the person-down and shots-fired
-- alerts the mission flag clears. Adapter functions: available, isSuspended, lookupActiveCall, clearNotification,
-- realCallSummary, mdtCommendations. Adapters pass events on with CP.Dispatch._emit(kind, ...).
CP.Dispatch = CP.Dispatch or {}
local D = CP.Dispatch
function D.available() return Via('dispatch', 'available', false) end
function D.isSuspended(citizenid, jobName) return Via('dispatch', 'isSuspended', false, citizenid, jobName) end
function D.lookupActiveCall(callId) return Via('dispatch', 'lookupActiveCall', nil, callId) end
function D.clearNotification(uniqueId, jobs) return Via('dispatch', 'clearNotification', false, uniqueId, jobs) end
function D.realCallSummary() return Via('dispatch', 'realCallSummary', nil) end
function D.mdtCommendations(citizenid) return Via('dispatch', 'mdtCommendations', nil, citizenid) end

function D.normalizeCallId(id)
    local t = type(id)
    if t == 'number' then
        if id ~= id or id == math.huge or id == -math.huge then return tostring(id) end
        local i = math.tointeger(id)
        if i then return ('%d'):format(i) end
        return tostring(id)
    elseif t == 'string' then
        local s = CP.U.trim(id)
        if s:match('^%d+$') or s:match('^%d+%.0*$') then
            local i = math.tointeger(tonumber(s))
            if i then return ('%d'):format(i) end
        end
        return id
    elseif id == nil then
        return ''
    end
    return tostring(id)
end

local dispatchListeners = {
    responding = Listeners(),
    cleared = Listeners(),
    restart = Listeners(),
    shots = Listeners(),
    down = Listeners(),
    dead = Listeners(),
}

local function AddDispatch(kind, fn)
    if type(fn) ~= 'function' then
        CP.warn(TAG, 'a dispatch %s listener must be a function (got %s)', kind, type(fn))
        return
    end
    AddTo(dispatchListeners[kind], fn)
end

-- Every listener of kind in its own thread (listeners may yield).
function D._emit(kind, ...)
    local list = dispatchListeners[kind]
    if not list or #list == 0 then return end
    local args = table.pack(...)
    for i = 1, #list do
        local fn = list[i]
        CreateThread(function()
            local ok, err = pcall(fn, table.unpack(args, 1, args.n))
            if not ok then CP.err(TAG, 'dispatch %s listener failed: %s', kind, tostring(err)) end
        end)
    end
end

function D.onResponding(fn) AddDispatch('responding', fn) end
function D.onCallCleared(fn) AddDispatch('cleared', fn) end
function D.onDispatchRestart(fn) AddDispatch('restart', fn) end
function D.onShotsFired(fn) AddDispatch('shots', fn) end
function D.onPlayerDown(fn) AddDispatch('down', fn) end
function D.onPlayerDead(fn) AddDispatch('dead', fn) end

-- --------------------------------------------------------------- AMBULANCE --
-- CP.Ambulance: on-duty EMS, the revive a pick-up ends with, and hospital respawns of real suspects. Adapter
-- functions: doctorCount() -> integer, revive(src) -> boolean, emsRequest = the name the client sends the EMS request
-- for (modules/system/client/ambulance). With no ambulance script: no EMS (0), Crimson-Police's own revive, and the
-- base-game death check (CP.Qbx.isDowned reads the ped's health).
CP.Ambulance = CP.Ambulance or {}
local A = CP.Ambulance
local respawnListeners = Listeners()

function A.doctorCount()
    local a = I.adapter('ambulance')
    if not (a and a.doctorCount) then return 0 end
    local ok, n = pcall(a.doctorCount)
    if not ok then
        LogOnce('doctorCount', 'doctorCount failed: %s', tostring(n))
        return 0
    end
    n = math.floor(tonumber(n) or 0)
    return n > 0 and n or 0
end

-- CP.Alerts.inArena (guarded: an error counts as in the arena, so nobody is revived by mistake).
local function InArena(src)
    if not (CP.Alerts and CP.Alerts.inArena) then return false end
    local ok, res = pcall(CP.Alerts.inArena, src)
    if not ok then
        LogOnce('inArena', 'CP.Alerts.inArena failed: %s', tostring(res))
        return true
    end
    return res == true
end

-- Refused for a bad or disconnected id and for a Crimson-Arena player (the arena revives its own players).
function A.revive(src)
    local n = I.whole(src, 1, 65535)
    if not n then
        CP.err(TAG, 'revive refused an invalid server id (%s)', tostring(src))
        return false
    end
    if GetPlayerName(n) == nil then
        CP.log(TAG, 'revive: player %d is not connected', n)
        return false
    end
    if InArena(n) then
        CP.warn(TAG, 'revive refused for player %d: they are in Crimson-Arena, which handles their revive', n)
        return false
    end
    local a = I.adapter('ambulance')
    if a and a.revive then
        local ok, res = pcall(a.revive, n)
        if not ok then LogOnce('revive', 'revive failed: %s', tostring(res)) end
        return ok and res == true
    end
    TriggerClientEvent(CP.e('client:revive'), n)
    CP.log(TAG, 'own revive sent to %d (no ambulance script)', n)
    return true
end

-- The name of the EMS request the downed player's client sends ('' = none: no ambulance script).
function A.emsRequest()
    local a = I.adapter('ambulance')
    return a and type(a.emsRequest) == 'string' and a.emsRequest or ''
end

-- true while no ambulance script serves: downed = the ped is dead (no isdead / inlaststand metadata is written).
function A.downedByPed() return I.adapter('ambulance') == nil end

-- 'respawn' (src, hospitalIndex): a player who chose to respawn at a hospital. fn runs inside the event and must not
-- yield. Returns false for an unknown kind or a missing function.
function A.on(kind, fn)
    if kind ~= 'respawn' or type(fn) ~= 'function' then
        CP.err(TAG, 'Ambulance.on: unknown kind \'%s\' or no function', tostring(kind))
        return false
    end
    AddTo(respawnListeners, fn)
    return true
end

-- An adapter's respawn fact: only while a real-suspect case is open and that script serves (else nothing runs at all).
function A._respawned(resource, src, index)
    if #respawnListeners == 0 or not I.caseOpen() or not I.is('ambulance', resource) then return end
    src = I.whole(src, 1, 65535)
    if not src or not CP.Net.rateOk(src, 'scp:respawn', 6, 1000) then return end
    index = I.whole(index, 1, 255)
    if not index then return end
    for i = 1, #respawnListeners do
        local ok, err = pcall(respawnListeners[i], src, index)
        if not ok then LogOnce('on:respawn', 'a \'respawn\' listener failed: %s', tostring(err)) end
    end
end

-- ----------------------------------------------------------------- BANKING --
-- CP.Banking: the bank history entries of a payout and the department (society) accounts. With no banking script the
-- entries are skipped and Config.Cash.source = 'society' pays new money, as 'server' does (CP.Banking.societyOn).
CP.Banking = CP.Banking or {}
local B = CP.Banking
-- (account or citizenid, amount, message, issuer, receiver, transId) -> boolean
function B.recordDeposit(...) return Via('banking', 'recordDeposit', false, ...) end
function B.recordWithdraw(...) return Via('banking', 'recordWithdraw', false, ...) end
function B.recordSocietyDeposit(...) return Via('banking', 'recordSocietyDeposit', false, ...) end
function B.recordSocietyWithdraw(...) return Via('banking', 'recordSocietyWithdraw', false, ...) end
function B.withdrawSociety(account, amount) return Via('banking', 'withdrawSociety', false, account, amount) end
function B.depositSociety(account, amount) return Via('banking', 'depositSociety', false, account, amount) end
function B.societyBalance(account) return Via('banking', 'societyBalance', nil, account) end
function B.findTxn(transId, opts) return Via('banking', 'findTxn', nil, transId, opts) end

-- Config.Cash.source = 'society' and a banking script serves the society accounts.
function B.societyOn()
    return type(Config.Cash) == 'table' and Config.Cash.source == 'society' and I.adapter('banking') ~= nil
end

-- ------------------------------------------------------------------ POLICE --
-- CP.Police: second, read-only handlers on the police script's events; they never trigger, cancel or answer one.
-- An adapter calls CP.Police.addFacts(resource, facts) with { event, kind, read(src, ...) } entries; each handler
-- runs only while that script serves the police job, then (but for 'impound') only while a real-suspect case is open.
CP.Police = CP.Police or {}
local P = CP.Police
local MAX_NETID = 0xFFFFFF
local POLICE_KINDS = {
    cuff = true,       -- (officerSrc, targetSrc, isSoftcuff)
    uncuff = true,     -- (officerSrc, targetSrc)
    cuffBreak = true,  -- (suspectSrc, officerSrc)
    escort = true,     -- (officerSrc, targetSrc)
    jail = true,       -- (officerSrc, targetSrc, jailTimeRaw)
    bobbyPin = true,   -- (pickerSrc, success)
    seizeCash = true,  -- (officerSrc, targetSrc)
}
local policeListeners = {}     -- policeListeners[kind] = { fn, ... }
local provides = {}            -- provides[resource][kind] = true

-- A server id 1..65535, or nil.
function P.playerId(v) return I.whole(v, 1, 65535) end

-- The serving police script sends this kind of fact.
function P.has(kind)
    local res = I.pick('police')
    return res ~= nil and provides[res] ~= nil and provides[res][kind] == true
end

function P.on(kind, fn)
    if not POLICE_KINDS[kind] or type(fn) ~= 'function' then
        CP.err(TAG, 'Police.on: unknown kind \'%s\' or no function', tostring(kind))
        return false
    end
    policeListeners[kind] = policeListeners[kind] or {}
    AddTo(policeListeners[kind], fn)
    return true
end

local function Fire(kind, ...)
    if (...) == nil then return end
    local list = policeListeners[kind]
    for i = 1, #list do
        local ok, err = pcall(list[i], ...)
        if not ok then LogOnce('police:' .. kind, 'a \'%s\' listener failed: %s', kind, tostring(err)) end
    end
end

-- The live run that owns this net id as one of its vehicles, or nil.
local function RunVehicle(netId)
    if not (CP.Runs and CP.Runs.all) then return nil end
    local ok, list = pcall(CP.Runs.all)
    if not ok or type(list) ~= 'table' then return nil end
    for _, run in pairs(list) do
        local e = type(run) == 'table' and run.state ~= 'ended' and type(run.entities) == 'table'
            and run.entities[netId]
        if e and e.kind == 'vehicle' then return run, e end
    end
    return nil
end

-- The sender's server-side distance to the car when the event arrived (the police script may check neither).
local function DistanceTo(src, e)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or not e or not e.entity or not DoesEntityExist(e.entity) then return nil end
    return CP.U.dist(GetEntityCoords(ped), GetEntityCoords(e.entity))
end

-- A police impound of a vehicle: tells the engine who removed a run vehicle.
function P.onImpound(src, netId)
    netId = math.tointeger(tonumber(netId) or -1)
    if not netId or netId <= 0 or netId > MAX_NETID then return false end
    local run, e = RunVehicle(netId)
    if not run then return false end
    local dist = DistanceTo(src, e)
    CP.log(TAG, 'police impound from %s on vehicle %d of run %s (%.1f m)', tostring(src), netId, run.id, dist or -1)
    if CP.Runs and CP.Runs.noteExternalRemoval then
        local ok, err = pcall(CP.Runs.noteExternalRemoval, netId, src, 'sc_impound', dist)
        if not ok then CP.err(TAG, 'noteExternalRemoval failed: %s', tostring(err)) end
    end
    return true
end

-- facts: { { event, kind, read = function(src, ...) -> listener args (sender first) | nil } }; kind 'impound' reads
-- the net id instead and goes to P.onImpound.
function P.addFacts(resource, facts)
    provides[resource] = provides[resource] or {}
    for _, f in ipairs(facts) do
        local kind, read, rateKey = f.kind, f.read, 'scp:' .. f.kind
        provides[resource][kind] = true
        RegisterNetEvent(f.event, function(...)
            local src = source
            if kind == 'impound' then
                if not I.is('police', resource) then return end
                local ok, err = pcall(P.onImpound, src, read(...))
                if not ok then CP.err(TAG, '%s from %s failed: %s', f.event, tostring(src), tostring(err)) end
                return
            end
            -- nothing at all (no native read) while no listener exists or no case is open
            if not policeListeners[kind] or not I.caseOpen() or not I.is('police', resource) then return end
            src = P.playerId(src)
            if not src or not CP.Net.rateOk(src, rateKey, 6, 1000) then return end
            Fire(kind, read(src, ...))
        end)
    end
end

-- ============================================================================
--                               HEALTH AND START
-- ============================================================================

local function HealthLines()
    local out = {}
    for _, s in ipairs(I.status()) do
        if s.active then
            out[#out + 1] = { level = 'ok', text = CP.L('integrations.on.' .. s.kind, { name = s.active }) }
        else
            out[#out + 1] = {
                level = s.setting == 'none' and 'ok' or 'warn',
                text = CP.L('integrations.off.' .. s.kind, { setting = s.setting, why = s.why }),
                fix = 'Integrations.' .. s.kind,
            }
        end
    end
    local rp = type(Config.RealPlayers) == 'table' and Config.RealPlayers or {}
    local wanted = (type(rp.liveCrime) == 'table' and rp.liveCrime.enabled == true)
        or (type(rp.volunteer) == 'table' and rp.volunteer.enabled == true)
    if wanted and I.realSuspectsBlocked() then
        out[#out + 1] = { level = 'warn', text = I.featureOff('live_crimes'), fix = 'Integrations.police' }
    end
    return out
end

CreateThread(function()
    Wait(0)
    if CP.ConfigHealth and CP.ConfigHealth.register then CP.ConfigHealth.register('integrations', HealthLines) end
    if CP.Hooks and CP.Hooks.on then
        CP.Hooks.on('settings:changed', function()
            found = {}
            I.report()
        end)
    end
    Wait(REPORT_DELAY_MS)
    I.report()
end)

-- A script of ORDER that starts later than Crimson-Police: 'auto' may pick it now.
AddEventHandler('onResourceStart', function(res)
    for _, kind in ipairs(KINDS) do
        if adapters[kind][res] then
            I.report()
            return
        end
    end
end)

-- Test hook (not part of the contract): forget what 'auto' found.
I._reset = function() found, said = {}, {} end

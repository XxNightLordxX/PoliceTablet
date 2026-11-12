-- Crimson-Police on any Qbox city. CP.Integrations picks the dispatch, ambulance, banking and police script

-- Crimson-Police on any Qbox city. CP.Integrations picks the dispatch, ambulance, banking and police script
-- (Config.Integrations: 'auto' in a fixed order with the owner's scripts first, a name, or 'none'); each adapter is
-- checked against stand-ins shaped like that script's real API (ps-dispatch, qbx_ambulancejob, qbx_policejob, copied
-- from their server files), and every 'none' path answers like a missing script instead of failing.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

-- which resources this city has: 'started' | 'stopped' | nil (missing)
local city = {}
_G.GetResourceState = function(name)
    if city[name] then return city[name] end
    if name == 'oxmysql' or name == 'ox_lib' or name == 'qbx_core' then return 'started' end
    return 'missing'
end
local OWNER = { 'sc-dispatch', 'sc-ambulance', 'Renewed-Banking', 'sc-police' }
local OTHERS = { 'ps-dispatch', 'qbx_ambulancejob', 'qbx_medical', 'qbx_policejob' }
local function City(list)
    city = {}
    for _, n in ipairs(list) do city[n] = 'started' end
    CP.Integrations._reset()
end

local lines = {}   -- Config health checks by name
CP.ConfigHealth = {
    register = function(name, fn) lines[name] = fn end,
}
H.load('modules/system/integrations/integrations.lua')
for _, f in ipairs({
    'ps_dispatch',
    'qbx_ambulancejob',
    'qbx_policejob',
    'renewed_banking',
    'sc_ambulance',
    'sc_dispatch',
    'sc_police',
}) do
    H.load('modules/system/integrations/' .. f .. '.lua')
end
H.step(0)
local I, D, A, B, P = CP.Integrations, CP.Dispatch, CP.Ambulance, CP.Banking, CP.Police
CP.Opponents = {
    active = function() return true end,
} -- a real-suspect case is open
H.players[3] = { coords = vector3(0, 0, 0) }
H.players[7] = { coords = vector3(1, 0, 0) }
_G.GetPlayerName = function(src) return H.players[src] and ('P' .. src) or nil end

local function Set(kind, v) Config.Integrations[kind] = v end
local function Picks()
    return table.concat({
        I.pick('dispatch') or 'none',
        I.pick('ambulance') or 'none',
        I.pick('banking') or 'none',
        I.pick('police') or 'none',
    }, ',')
end

-- ============================================================================
--                      SHIPPED CONFIG AND THE AUTO ORDER
-- ============================================================================

do
    for _, kind in ipairs(I.KINDS) do H.eq(Config.Integrations[kind], 'auto', 'ships auto: ' .. kind) end
    City(OWNER)
    H.eq(Picks(), 'sc-dispatch,sc-ambulance,Renewed-Banking,sc-police', 'the owner\'s stack')
    -- both kinds of script running: the owner's come first
    local both = { table.unpack(OWNER) }
    for _, n in ipairs(OTHERS) do both[#both + 1] = n end
    City(both)
    H.eq(Picks(), 'sc-dispatch,sc-ambulance,Renewed-Banking,sc-police', 'auto picks the owner\'s scripts first')
    City(OTHERS)
    H.eq(Picks(), 'ps-dispatch,qbx_ambulancejob,none,qbx_policejob', 'a plain Qbox city with ps-dispatch')
    City({})
    H.eq(Picks(), 'none,none,none,none', 'nothing running')
    local _, why = I.pick('dispatch')
    H.eq(why, 'missing', 'why: nothing found')
    -- 'auto' keeps what it found: a restart of sc-dispatch does not move dispatch to ps-dispatch
    City(both)
    H.eq(I.pick('dispatch'), 'sc-dispatch', 'found')
    city['sc-dispatch'] = 'stopped'
    H.eq(I.pick('dispatch'), 'sc-dispatch', 'kept while it restarts')
    H.eq(D.available(), false, 'and not available meanwhile (as before)')
    -- a name, and 'none'
    City(both)
    Set('dispatch', 'ps-dispatch')
    H.eq(I.pick('dispatch'), 'ps-dispatch', 'a named script is used even when sc-dispatch runs')
    Set('dispatch', 'none')
    local res, why2 = I.pick('dispatch')
    H.eq(res, nil, 'none')
    H.eq(why2, 'off', 'why: turned off')
    Set('dispatch', 'cd_dispatch')
    res, why2 = I.pick('dispatch')
    H.ok(res == nil and why2 == 'no_adapter', 'a script with no adapter serves nothing')
    Set('dispatch', 'auto')
    -- a city's own adapter joins the end of the auto order
    I.register('dispatch', 'my-dispatch', {
        available = function() return true end,
    })
    H.eq(I.ORDER.dispatch[#I.ORDER.dispatch], 'my-dispatch', 'a city adapter is tried last')
    City({ 'my-dispatch' })
    H.eq(I.pick('dispatch'), 'my-dispatch', 'and is used when it is the one running')
    H.eq(D.available(), true, 'through CP.Dispatch')
    H.eq(D.isSuspended('C1', 'police'), false, 'a function it lacks answers the default')
    H.eq(D.lookupActiveCall(5), nil, 'nil default')
end

-- ============================================================================
--                                 'NONE' PATHS
-- ============================================================================

do
    City({})
    H.eq(D.available(), false, 'dispatch none: unavailable')
    H.eq(D.clearNotification('cp_x', { 'police' }), false, 'nothing to clear')
    H.eq(D.realCallSummary(), nil, 'no real-call strip')
    H.eq(A.doctorCount(), 0, 'ambulance none: no EMS, so a downed participant is picked up')
    H.eq(A.emsRequest(), '', 'no EMS request')
    H.eq(A.downedByPed(), true, 'downed = the ped is dead')
    H.reset()
    H.eq(A.revive(3), true, 'Crimson-Police revives itself')
    local ev = H.findEvents(CP.e('client:revive'))[1]
    H.eq(ev and ev.target, 3, 'own revive goes to that player only')
    H.eq(A.revive(99), false, 'not connected: refused')
    Config.Cash.source = 'society'
    H.eq(B.societyOn(), false, 'banking none: society pay is off (new money)')
    H.eq(B.recordDeposit('C1', 100, 'm', 'a', 'b', 't'), false, 'no bank history entry')
    H.eq(B.societyBalance('police'), nil, 'no balance')
    Config.Cash.source = 'server'
    H.eq(P.has('cuff'), false, 'police none: no cuff facts')
    H.eq(I.realSuspectsBlocked(), true, 'live crimes and volunteers are blocked')
    Config.RealPlayers.liveCrime.enabled = true
    local _, on = CP.RealPlayers('liveCrime')
    H.eq(on, false, 'live crimes stay off with the switch on')
    local _, onTab = CP.RealPlayers('criminalTablet')
    H.eq(onTab, Config.RealPlayers.criminalTablet.enabled == true,
        'the criminal tablet does not need the police script')
    H.ok(type(I.featureOff('live_crimes')) == 'string',
        'Settings -> Features says why: ' .. tostring(I.featureOff('live_crimes')))
    H.eq(I.featureOff('spawning'), nil, 'other features need no script')
    City(OWNER)
    _, on = CP.RealPlayers('liveCrime')
    H.eq(on, true, 'with sc-police the switch decides again')
    H.eq(I.featureOff('live_crimes'), nil, 'and Features shows nothing')
    Config.RealPlayers.liveCrime.enabled = false
end

-- ============================================================================
--                                 PS-DISPATCH
-- ============================================================================

do
    City(OTHERS)
    -- exports('GetDispatchCalls', function() return calls end) (ps-dispatch server/main.lua)
    local calls = {
        { id = 4, priority = 2, units = {} },
        { id = 9, priority = 1, units = {} },
        { id = 12, priority = 0, units = {} },
    }
    H.exportsMock['ps-dispatch'] = {
        GetDispatchCalls = function() return calls end,
    }
    H.eq(D.available(), true, 'ps-dispatch serves')
    H.eq(D.lookupActiveCall(9), '9', 'an active call by id')
    H.eq(D.lookupActiveCall('9'), '9', 'the id as text')
    H.eq(D.lookupActiveCall(10), nil, 'an unknown call')
    H.eq(D.lookupActiveCall('npccall-1'), nil, 'not a ps-dispatch id')
    local sum = D.realCallSummary()
    H.ok(sum and sum.total == 3 and sum.p1 == 2, 'the strip counts every call, priority 0 and 1 as urgent')
    H.eq(D.isSuspended('C1', 'police'), false, 'ps-dispatch has no suspensions')
    H.eq(D.mdtCommendations('C1'), nil, 'and no MDT commendations')
    local got = {}
    D.onResponding(function(src, id, on) got[#got + 1] = ('%d:%s:%s'):format(src, tostring(id), tostring(on)) end)
    local cleared = {}
    D.onCallCleared(function(id) cleared[#cleared + 1] = id end)
    -- TriggerServerEvent('ps-dispatch:server:attach', data.id, PlayerData) (ps-dispatch client/main.lua)
    H.fire('ps-dispatch:server:attach', 3, 9, { citizenid = 'C3' })
    H.fire('ps-dispatch:server:detach', 3, 9, { citizenid = 'C3' })
    H.fire('ps-dispatch:server:attach', 3, 'x', { citizenid = 'C3' })
    H.step(0)
    H.eq(table.concat(got, ' '), '3:9:true 3:9:false', 'attach and detach are Responding on and off')
    -- sc-dispatch's event means nothing now
    H.fire('sc-dispatch:server:ToggleResponding', 3, 4, true)
    H.step(0)
    H.eq(#got, 2, 'the other script\'s events are ignored')
    -- a refused clear (the call is still listed) is no clear; a real one is
    H.fire('ps-dispatch:server:clearCall', 3, 9)
    H.step(300)
    H.eq(#cleared, 0, 'a clear ps-dispatch refused')
    table.remove(calls, 2)
    H.fire('ps-dispatch:server:clearCall', 3, 9)
    H.step(300)
    H.eq(cleared[1], 9, 'a clear once ps-dispatch removed the call')
    -- SALE2: ps-dispatch keeps a unit on one call: an attach to another takes it off the old one with no detach event
    local moves = {}
    D.onResponding(function(src, id, on, moved)
        moves[#moves + 1] = ('%d:%s:%s:%s'):format(src, tostring(id), tostring(on), tostring(moved))
    end)
    H.fire('ps-dispatch:server:attach', 7, 4, { citizenid = 'C7' })
    H.step(0)
    H.fire('ps-dispatch:server:attach', 7, 12, { citizenid = 'C7' })
    H.step(0)
    H.fire('ps-dispatch:server:detach', 7, 12, { citizenid = 'C7' })
    H.step(0)
    H.fire('ps-dispatch:server:attach', 7, 4, { citizenid = 'C7' })
    H.step(0)
    H.eq(table.concat(moves, ' '), '7:4:true:nil 7:4:false:true 7:12:true:nil 7:12:false:nil 7:4:true:nil',
        'SALE2: the old call goes out as a moved un-mark, once; after a detach nothing is moved')
end

-- ============================================================================
--                      QBX_AMBULANCEJOB AND QBX_POLICEJOB
-- ============================================================================

do
    City(OTHERS)
    -- lib.callback.register('qbx_ambulancejob:server:getNumDoctors', ... GetDutyCountType('ems'))
    local asked
    H.exportsMock.qbx_core = H.exportsMock.qbx_core or {}
    local realCount = H.exportsMock.qbx_core.GetDutyCountType
    H.exportsMock.qbx_core.GetDutyCountType = function(t)
        asked = t
        return 2
    end
    H.eq(A.doctorCount(), 2, 'on-duty EMS from qbx_core')
    H.eq(asked, 'ems', 'the job type qbx_ambulancejob counts')
    H.exportsMock.qbx_core.GetDutyCountType = realCount
    -- exports.qbx_medical:Revive(src) (qbx_ambulancejob server/main.lua)
    local revived = {}
    H.exportsMock.qbx_medical = {
        Revive = function(src) revived[#revived + 1] = src end,
    }
    H.eq(A.revive(7), true, 'revive through qbx_medical')
    H.eq(revived[1], 7, 'that player')
    H.eq(A.emsRequest(), 'qbx_ambulancejob', 'the client sends qbx_ambulancejob\'s alert')
    H.eq(A.downedByPed(), false, 'qbx_medical writes the downed metadata')
    local respawns = {}
    A.on('respawn', function(src, index) respawns[#respawns + 1] = src .. ':' .. index end)
    -- AddEventHandler('qbx_medical:server:playerRespawned', respawn) with respawn(src)
    TriggerEvent('qbx_medical:server:playerRespawned', 7)
    H.fire('hospital:server:RespawnAtHospital', 7, 2)
    H.eq(table.concat(respawns, ' '), '7:1', 'qbx_medical respawns are seen; sc-ambulance\'s event is not')
    -- qbx_policejob: escort, jail and seizures, the same arguments as sc-police; no cuff event
    local facts = {}
    for _, kind in ipairs({ 'cuff', 'escort', 'jail', 'seizeCash' }) do
        P.on(kind, function(...)
            local parts = {}
            for _, v in ipairs({ ... }) do parts[#parts + 1] = tostring(v) end
            facts[#facts + 1] = kind .. ':' .. table.concat(parts, ',')
        end)
    end
    H.fire('police:server:EscortPlayer', 3, 7)
    H.fire('police:server:JailPlayer', 3, 7, 30)
    H.fire('police:server:SeizeCash', 3, 7)
    H.fire('police:server:CuffPlayer', 3, 7, false)
    H.eq(table.concat(facts, ' '), 'escort:3,7 jail:3,7,30 seizeCash:3,7', 'qbx_policejob facts (no cuff event)')
    H.eq(P.has('jail') and not P.has('cuff'), true, 'it reports jailing but no cuffing')
    H.eq(I.realSuspectsBlocked(), true, 'so live crimes and volunteers stay off')
    -- the owner's stack: the same events are sc-police's, cuff included
    City(OWNER)
    facts = {}
    H.fire('police:server:CuffPlayer', 3, 7, false)
    H.fire('police:server:EscortPlayer', 3, 7)
    H.eq(table.concat(facts, ' '), 'cuff:3,7,false escort:3,7', 'sc-police: each fact once')
end

-- ============================================================================
--                                CONFIG HEALTH
-- ============================================================================

do
    City({})
    local out = lines.integrations and lines.integrations() or {}
    H.eq(#out, 4, 'one line per kind')
    H.ok(out[1] and out[1].level == 'warn' and out[1].fix == 'Integrations.dispatch', 'auto with nothing: a warning')
    Set('dispatch', 'none')
    out = lines.integrations()
    H.eq(out[1].level, 'ok', 'none on purpose: no warning')
    Set('dispatch', 'auto')
    City(OWNER)
    out = lines.integrations()
    H.eq(out[2].text, CP.L('integrations.on.ambulance', { name = 'sc-ambulance' }), 'which script serves')
    -- SALE2: a script with no adapter says so (not "start sc-dispatch"); a named script that is not running warns
    Set('dispatch', 'cd_dispatch')
    out = lines.integrations()
    H.eq(out[1].text, CP.L('integrations.no_adapter', { kind = 'dispatch', setting = 'cd_dispatch' }),
        'SALE2: no adapter for the named script')
    H.ok(out[1].level == 'warn' and out[1].fix == 'Integrations.dispatch', 'SALE2: a warning that names the setting')
    Set('dispatch', 'ps-dispatch')
    out = lines.integrations()
    H.ok(
        out[1].level == 'warn'
            and out[1].text == CP.L('integrations.not_started', { kind = 'dispatch', name = 'ps-dispatch' }),
        'SALE2: a named script that is not started warns'
    )
    Set('dispatch', 'auto')
    out = lines.integrations()
    H.eq(out[1].level, 'ok', 'the owner\'s running sc-dispatch: no warning')
    -- SALE2: CP.Banking.available() follows the banking setting, not Renewed-Banking alone
    H.eq(B.available(), true, 'SALE2: Renewed-Banking serves and runs')
    Set('banking', 'none')
    H.eq(B.available(), false, 'SALE2: banking none: no banking script even while Renewed-Banking runs')
    Set('banking', 'auto')
end

return H

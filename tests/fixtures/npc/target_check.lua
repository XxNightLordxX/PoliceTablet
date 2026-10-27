-- The ox_target options of modules/npc in their own client Lua state (H.boot side = 'client'): they exist only while
-- the local player is on a run, so a player with no run pays nothing while the eye rests on a person or a car. Run by
-- tests/npc_spec.lua as a child process; prints "RESULT <passed> <failed>" (more in docs/FILE_NOTES.md).

package.path = package.path .. ';tests/?.lua'
local H = dofile('tests/harness.lua')
H.boot({ side = 'client' })

local ANSWERS = 'tests/fixtures/npc/target_answers.txt'

H.onUndefinedGlobal(function(k)
    if type(k) == 'string' and k:match('^%u%l') then
        local f = function() end
        _G[k] = f
        return f
    end
    return nil
end)

-- ============================================================================
--                                  FAKE WORLD
-- ============================================================================

local ME_PED = 100
local W = { ents = { [ME_PED] = { player = true } }, bags = {}, seats = {}, dead = false, inCar = false }
local nextNet = 900

local function AddEnt(e, bag, networked)
    local x = { netId = networked ~= false and nextNet or nil }
    nextNet = nextNet + 1
    W.ents[e] = x
    W.bags[e] = { cp = bag }
    return e
end

_G.PlayerId = function() return 0 end
_G.PlayerPedId = function() return ME_PED end
_G.GetPlayerServerId = function() return 1 end
_G.DoesEntityExist = function(e) return W.ents[e] ~= nil end
_G.IsEntityAPed = function(e) return W.ents[e] ~= nil end
_G.IsPedAPlayer = function(e) return W.ents[e] ~= nil and W.ents[e].player == true end
_G.IsEntityDead = function(e) return e == ME_PED and W.dead end
_G.IsPedInAnyVehicle = function(e) return e == ME_PED and W.inCar end
_G.NetworkGetEntityIsNetworked = function(e) return W.ents[e] ~= nil and W.ents[e].netId ~= nil end
_G.NetworkGetNetworkIdFromEntity = function(e) return W.ents[e] and W.ents[e].netId or 0 end
_G.GetPedInVehicleSeat = function(v, seat) return W.seats[v] and W.seats[v][seat] or 0 end
_G.LocalPlayer = { state = {} }
_G.Entity = function(e) return { state = W.bags[e] or {} } end
_G.AddRelationshipGroup = function(name) return true, joaat(name) end
local bagHandlers = {}
_G.AddStateBagChangeHandler = function(key, filter, fn) bagHandlers[#bagHandlers + 1] = { key = key, fn = fn } end

local T = H.mockTarget()
local R = { current = nil }
CP.Runs = {
    current = function() return R.current end,
    control = function() return true end,
}
local busy = false
CP.Custody = {
    busy = function() return busy end,
    perform = function() end,
    cancel = function() end,
}

-- every call this resource makes to ox_target (the cross-resource funcref calls a player pays for)
local targetCalls = 0
do
    local mock = H.exportsMock.ox_target
    for name, fn in pairs(mock) do
        mock[name] = function(...)
            targetCalls = targetCalls + 1
            return fn(...)
        end
    end
end

H.load('modules/npc/client.lua')

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local DOORS = { 'door_dside_f', 'door_pside_f', 'door_dside_r', 'door_pside_r' }
local ALL_PERSON = {
    'talk',
    'frisk',
    'detain',
    'searchPerson',
    'explain',
    'warn',
    'cite',
    'release',
    'arrest',
    'escort',
}
local ALL_VEHICLE = { 'inspect', 'runPlate', 'lookInside', 'orderOut', 'searchVehicle', 'cite', 'noAction', 'impound' }
local PED_NAMES = { 'crimson-police:cuff' }
for i = 1, #ALL_PERSON - 1 do PED_NAMES[#PED_NAMES + 1] = 'crimson-police:contact_' .. ALL_PERSON[i] end
PED_NAMES[#PED_NAMES + 1] = 'crimson-police:custody_escort'
local VEHICLE_NAMES = {}
for _, a in ipairs(ALL_VEHICLE) do VEHICLE_NAMES[#VEHICLE_NAMES + 1] = 'crimson-police:contact_' .. a end
for _, door in ipairs(DOORS) do
    for _, a in ipairs({ 'talk', 'warn', 'cite', 'release' }) do
        VEHICLE_NAMES[#VEHICLE_NAMES + 1] = ('crimson-police:seat_%s_%s'):format(a, door)
    end
end

local function Names(list)
    local out = {}
    for i, o in ipairs(list) do out[i] = o.name end
    return table.concat(out, ',')
end

local function Count(op, kind)
    local n = 0
    for _, c in ipairs(T.globalCalls) do
        if c.op == op and (not kind or c.kind == kind) then n = n + 1 end
    end
    return n
end

-- what the local player's run looks like to modules/npc: modules/runs sets and clears current() in its own handler,
-- which runs after modules/npc's (fxmanifest glob order)
local function StartRun(id)
    H.fire('crimson-police:client:start', 1, id, { participants = { 1 } })
    R.current = { id = id, isHost = false, state = 'accepted', participants = { 1 } }
end

local function EndRun(id)
    H.fire('crimson-police:client:runEnded', 1, id)
    if R.current and R.current.id == id then R.current = nil end
end

-- after (b) the second cuff label has its option too: it comes right after the default one
local function OptionsOn()
    local peds = { PED_NAMES[1], 'crimson-police:cuff:2', table.unpack(PED_NAMES, 2) }
    return Names(T.peds) == table.concat(peds, ',') and Names(T.vehicles) == table.concat(VEHICLE_NAMES, ',')
end

-- ============================================================================
--                     (a) NO RUN: NO GLOBAL OPTION AT ALL
-- ============================================================================

H.advance(3000)
H.eq(#T.peds, 0, 'ox_target started, no run: no ped option')
H.eq(#T.vehicles, 0, 'ox_target started, no run: no vehicle option')
H.eq(#T.globalCalls, 0, 'no run: nothing added or removed')
-- idle for a minute with the eye menu open on something: this resource does nothing with ox_target
T.active = true
local before = targetCalls
H.advance(60000, 500)
H.eq(targetCalls - before, 0, 'idle minute: no call to ox_target')
T.active = false

-- ============================================================================
--               (b) RUN START: THE SAME OPTIONS, IN ORDER, ONCE
-- ============================================================================

StartRun('run-1')
H.eq(#T.peds, 0, 'the options wait one tick: modules/runs sets the run after this handler')
H.advance(100)
H.eq(Names(T.peds), table.concat(PED_NAMES, ','), 'run start: the cuff, contact and custody options, in order')
H.eq(Names(T.vehicles), table.concat(VEHICLE_NAMES, ','), 'run start: the vehicle and door options, in order')
H.eq(Count('add', 'ped'), 2, 'run start: two ped calls (cuff, then contact and custody)')
H.eq(Count('add', 'vehicle'), 1, 'run start: one vehicle call')
H.eq(Count('remove'), 0, 'run start: nothing removed')
StartRun('run-1')
H.advance(100)
H.eq(#T.globalCalls, 3, 'a second client:start for the same run adds nothing')
-- a label seen during the run gets its own option at once
local SUSPECT = AddEnt(5001, { run = 'run-1', obj = 1, state = 'surrendered', cuff = { label = 'Detain driver' } })
for _, h in ipairs(bagHandlers) do
    if h.key == 'cp' then h.fn(('entity:%d'):format(W.ents[SUSPECT].netId), 'cp', W.bags[SUSPECT].cp) end
end
H.eq(T.peds[#T.peds].name, 'crimson-police:cuff:2', 'a new cuff label during a run: its option is added')
W.ents[SUSPECT], W.bags[SUSPECT] = nil, nil

-- ============================================================================
--          (e) EVERY canInteract ANSWER, AS BEFORE THE OPTIONS MOVED
-- ============================================================================
-- Fixed people, cars and seats, read under each player condition and run condition at three distances.

local function Person(state, extra)
    local bag = {
        run = 'run-1',
        obj = 1,
        state = state,
        contact = { label = 'P', kind = 'person', actions = ALL_PERSON },
    }
    for k, v in pairs(extra or {}) do bag[k] = v end
    return bag
end
local function Car(state, extra)
    local bag = {
        run = 'run-1',
        obj = 1,
        state = state,
        contact = { label = 'V', kind = 'vehicle', actions = ALL_VEHICLE },
    }
    for k, v in pairs(extra or {}) do bag[k] = v end
    return bag
end

local PEDS = {
    AddEnt(6001, Person('idle')),
    AddEnt(6002, Person('contacted')),
    AddEnt(6003, Person('cuffed')),
    AddEnt(6004, Person('seated')),
    AddEnt(6005, Person('escorted', { escortBy = 1 })),
    AddEnt(6006, Person('escorted', { escortBy = 2 })),
    AddEnt(6007, { run = 'run-1', obj = 1, state = 'surrendered', cuff = { maxDistance = 3.0 } }),
    AddEnt(6008, Person('idle', { contact = { label = 'X', kind = 'vehicle', actions = ALL_PERSON } })),
    AddEnt(6009, { run = 'run-1', obj = 1, state = 'idle' }),
    AddEnt(6010, Person('idle', { run = 'run-x' })),
    AddEnt(6011, Person('idle'), false),
}
local DRIVER = AddEnt(7001, Person('idle'))
local REAR = AddEnt(7002, Person('cuffed'))
local STRANGER = AddEnt(7003, Person('idle', { run = 'run-x' }))
local CARS = {
    AddEnt(8001, Car('stopped')),
    AddEnt(8002, Car('impounded')),
    AddEnt(8003, { run = 'run-1', obj = 1, state = 'stopped' }),
}
W.seats[CARS[1]] = { [-1] = DRIVER, [1] = REAR, [2] = STRANGER }
W.seats[CARS[2]] = { [-1] = DRIVER }
W.seats[CARS[3]] = { [-1] = DRIVER }

local PLAYER_CONDITIONS = {
    { 'ok', function() end },
    {
        'dead',
        function() W.dead = true end,
    },
    {
        'car',
        function() W.inCar = true end,
    },
    {
        'arena',
        function() LocalPlayer.state.crimsonArena = { active = true, source = 'crimson-arena' } end,
    },
    {
        'busy',
        function() busy = true end,
    },
}
local RUN_CONDITIONS = {
    { 'none', nil },
    { 'accepted', { id = 'run-1', state = 'accepted' } },
    { 'progress', { id = 'run-1', state = 'in_progress' } },
    { 'other', { id = 'run-9', state = 'in_progress' } },
}
local DISTANCES = { 1.0, 2.5, 3.5 }

local function Hex(bits)
    local out = {}
    for i = 1, #bits, 4 do
        local chunk = bits:sub(i, i + 3)
        chunk = chunk .. ('0'):rep(4 - #chunk)
        out[#out + 1] = ('%x'):format(tonumber(chunk, 2))
    end
    return table.concat(out)
end

-- one page is one condition: a new frame, so the options' per-frame reads start again (ox_target asks every option of
-- a pass in one frame; a condition changes between passes)
local function Page()
    H.nextFrame()
    local bits = {}
    local function Ask(list, ents)
        for _, o in ipairs(list) do
            for _, e in ipairs(ents) do
                for _, d in ipairs(DISTANCES) do bits[#bits + 1] = o.canInteract(e, d) == true and '1' or '0' end
            end
        end
    end
    Ask(T.peds, PEDS)
    Ask(T.vehicles, CARS)
    return table.concat(bits)
end

local savedRun = R.current
local pages, trues = {}, {}
for _, pc in ipairs(PLAYER_CONDITIONS) do
    for _, rc in ipairs(RUN_CONDITIONS) do
        W.dead, W.inCar, busy = false, false, false
        LocalPlayer.state.crimsonArena = nil
        pc[2]()
        R.current = rc[2]
        local bits = Page()
        local key = pc[1] .. '.' .. rc[1]
        pages[#pages + 1] = { key = key, hex = Hex(bits) }
        trues[key] = select(2, bits:gsub('1', ''))
    end
end
W.dead, W.inCar, busy = false, false, false
LocalPlayer.state.crimsonArena = nil
R.current = savedRun

local writeTo = os.getenv('CP_TARGET_SNAPSHOT')
if writeTo and writeTo ~= '' then
    local f = assert(io.open(writeTo, 'w'))
    f:write(
        '# canInteract answers of modules/npc/client.lua (tests/fixtures/npc/target_check.lua writes and reads it)\n')
    for _, p in ipairs(pages) do f:write(p.key, ' ', p.hex, '\n') end
    f:close()
else
    local want = {}
    local f = io.open(ANSWERS, 'r')
    H.ok(f ~= nil, 'the saved answers exist')
    if f then
        for line in f:lines() do
            local key, hex = line:match('^(%S+) (%x+)$')
            if key then want[key] = hex end
        end
        f:close()
    end
    for _, p in ipairs(pages) do H.eq(p.hex, want[p.key], 'canInteract answers unchanged: ' .. p.key) end
end
H.ok(trues['ok.progress'] > 40, 'the snapshot shows options (on foot, alive, run in progress)')
for _, rc in ipairs({ 'none', 'other' }) do
    H.eq(trues['ok.' .. rc], 0, 'no option shows without this run: ' .. rc)
end

-- ============================================================================
--       (f) ONE BAG READ PER FRAME, ONE VAN LOOKUP PER CONTACT KEY PRESS
-- ============================================================================
-- Every read below is a decode in the game (GetStateBagValue): each one answers a fresh copy, as the game does.

local reads = { cp = 0, arena = 0 }
local plainEntity, plainLocal = _G.Entity, _G.LocalPlayer
_G.Entity = function(e)
    return {
        state = setmetatable({}, {
            __index = function(_, k)
                if k == 'cp' then reads.cp = reads.cp + 1 end
                return CP.U.deepcopy((W.bags[e] or {})[k])
            end,
        }),
    }
end
local arenaValue = nil
_G.LocalPlayer = {
    state = setmetatable({}, {
        __index = function(_, k)
            if k == 'crimsonArena' then reads.arena = reads.arena + 1 end
            return k == 'crimsonArena' and CP.U.deepcopy(arenaValue) or nil
        end,
    }),
}

local function Ask(opts, e, d, newFrame)
    local out, bits = {}, {}
    for _, o in ipairs(opts) do
        if newFrame then H.nextFrame() end
        out[o.name] = o.canInteract(e, d) == true
        bits[#bits + 1] = out[o.name] and '1' or '0'
    end
    out.bits = table.concat(bits)
    return out
end

R.current = { id = 'run-1', state = 'in_progress' }
local TALKER = AddEnt(6101, Person('contacted'))
local alone = Ask(T.peds, TALKER, 1.0, true)
H.nextFrame()
reads.cp, reads.arena = 0, 0
local shared = Ask(T.peds, TALKER, 1.0)
H.eq(reads.cp, 1, ('every ped option of one pass: one cp bag read (%d)'):format(reads.cp))
H.eq(reads.arena, 1, ('every ped option of one pass: one crimsonArena read (%d)'):format(reads.arena))
H.eq(shared.bits, alone.bits, 'the same answers as one option per frame')
H.ok(shared['crimson-police:contact_detain'] and not shared['crimson-police:contact_arrest'],
    'a contacted person: Detain shows, Arrest does not')
-- the bag changes between passes: the next pass reads it again
W.bags[TALKER].cp.state = 'cuffed'
local sameFrame = Ask(T.peds, TALKER, 1.0)
H.ok(sameFrame['crimson-police:contact_detain'], 'within the same pass the answers stay as they were read')
H.nextFrame()
local cuffed = Ask(T.peds, TALKER, 1.0)
H.ok(not cuffed['crimson-police:contact_detain'], 'next frame, cuffed: Detain is gone')
H.ok(cuffed['crimson-police:contact_arrest'], 'next frame, cuffed: Arrest shows')
H.eq(reads.cp, 2, 'one more read for the next frame')
-- the arena flag changes between passes too
arenaValue = { active = true, source = 'crimson-arena' }
H.nextFrame()
local arena = Ask(T.peds, TALKER, 1.0)
H.ok(not arena['crimson-police:contact_arrest'], 'next frame, in Crimson-Arena: nothing shows')
arenaValue = nil

-- the contact key with the run's transport van among 200 vehicles: only the networked ones within 8 m are read
local plain = {}
for _, k in ipairs({
    'GetEntityCoords',
    'GetGamePool',
    'GetVehiclePedIsIn',
    'NetworkDoesNetworkIdExist',
    'NetworkGetEntityFromNetworkId',
}) do
    plain[k] = rawget(_G, k)
end
local performed, runAsks, pool = {}, 0, {}
local plainCurrent, plainPerform = CP.Runs.current, CP.Custody.perform
CP.Runs.current = function()
    runAsks = runAsks + 1
    return R.current
end
CP.Custody.perform = function(netId, action) performed[#performed + 1] = { netId = netId, action = action } end
W.ents[ME_PED].coords = vec3(100.0, 100.0, 30.0)
_G.GetEntityCoords = function(e) return W.ents[e] and W.ents[e].coords or vec3(0.0, 0.0, 0.0) end
_G.GetGamePool = function(kind) return kind == 'CVehicle' and pool or {} end
_G.GetVehiclePedIsIn = function() return 0 end
_G.NetworkDoesNetworkIdExist = function(netId)
    for _, x in pairs(W.ents) do if x.netId == netId then return true end end
    return false
end
_G.NetworkGetEntityFromNetworkId = function(netId)
    for e, x in pairs(W.ents) do if x.netId == netId then return e end end
    return 0
end
local function Vehicle(e, metres, bag, networked)
    AddEnt(e, bag, networked)
    W.ents[e].coords = vec3(100.0 + metres, 100.0, 30.0)
    pool[#pool + 1] = e
    return e
end
local VAN = Vehicle(9001, 6.0, { run = 'run-1', role = 'service', tag = 'transport' })
Vehicle(9002, 5.0, { run = 'run-x', role = 'service', tag = 'transport' })
Vehicle(9003, 7.0, Car('stopped'))
Vehicle(9004, 4.0, nil)
Vehicle(9005, 3.0, { run = 'run-1', role = 'service', tag = 'transport' }, false)
for i = 1, 195 do Vehicle(9100 + i, 9.0 + i, i % 5 == 0 and Car('stopped') or nil) end
local NEAR = 5
H.eq(#pool, 200, '200 vehicles in the pool')
local ESCORTED = AddEnt(6102, Person('escorted', { escortBy = 1 }))
W.ents[ESCORTED].coords = vec3(101.0, 100.0, 30.0)
for _, h in ipairs(bagHandlers) do
    if h.key == 'cp' then h.fn(('entity:%d'):format(W.ents[ESCORTED].netId), 'cp', W.bags[ESCORTED].cp) end
end

local function Press()
    performed, runAsks, reads.cp = {}, 0, 0
    H.commands.crimsonpolice_contact.fn()
    return performed[1]
end
local done = Press()
H.ok(reads.cp <= NEAR, ('the key press reads at most the %d bags within 8 m (%d)'):format(NEAR, reads.cp))
-- the key's own run check, one per list of escorted and seated people, one for the van lookup
H.eq(runAsks, 4, ('one run lookup for the van (%d in all)'):format(runAsks))
H.eq(done and done.action, 'handover', 'an escorted person and the run\'s van at 6 m: hand over')
H.eq(done and done.netId, W.ents[VAN].netId, 'to the run\'s van, not the other run\'s or a local one')
W.ents[VAN].coords = vec3(108.5, 100.0, 30.0)
done = Press()
H.ok(done ~= nil and done.action ~= 'handover',
    'the van at 8.5 m: no hand over (' .. tostring(done and done.action) .. ')')

for k, v in pairs(plain) do _G[k] = v end
CP.Runs.current, CP.Custody.perform = plainCurrent, plainPerform
_G.Entity, _G.LocalPlayer = plainEntity, plainLocal
for _, e in ipairs(pool) do W.ents[e], W.bags[e] = nil, nil end
W.ents[TALKER], W.bags[TALKER], W.ents[ESCORTED], W.bags[ESCORTED] = nil, nil, nil, nil
R.current = savedRun

-- ============================================================================
--                                 (c) RUN END
-- ============================================================================
-- EVERY OPTION REMOVED, AFTER THE EYE MENU CLOSES.

-- a stale end of an earlier run keeps the options of the run this player is on
EndRun('run-old')
H.advance(100)
H.eq(Count('remove'), 0, 'stale run end: nothing removed')
H.ok(Names(T.peds):find('crimson-police:contact_talk', 1, true) ~= nil, 'stale run end: the options stay')

EndRun('run-1')
H.advance(100)
H.eq(#T.peds, 0, 'run end: every ped option removed')
H.eq(#T.vehicles, 0, 'run end: every vehicle option removed')
local removedPed = {}
for _, c in ipairs(T.globalCalls) do
    if c.op == 'remove' and c.kind == 'ped' then
        for _, n in ipairs(c.names) do removedPed[n] = true end
    end
end
H.ok(
    removedPed['crimson-police:cuff'] and removedPed['crimson-police:cuff:2']
        and removedPed['crimson-police:custody_escort'],
    'run end: the cuff, contact and custody names are removed'
)

-- the eye menu is open: ox_target picks an option by its index, so nothing is removed until it closes
StartRun('run-2')
H.advance(100)
H.ok(OptionsOn(), 'next run: the options are back')
local calls = #T.globalCalls
local removes = Count('remove')
T.active = true
EndRun('run-2')
EndRun('run-2')
H.advance(100)
H.eq(#T.globalCalls, calls, 'run end with the eye menu open: nothing removed yet')
local asked = T.isActiveCalls
H.advance(5000, 100)
H.eq(#T.globalCalls, calls, 'menu still open after 5 s: nothing removed')
H.ok(T.isActiveCalls - asked <= 11, ('one wait, twice a second (%d asks in 5 s)'):format(T.isActiveCalls - asked))
T.active = false
H.advance(600)
H.eq(#T.peds + #T.vehicles, 0, 'menu closed: every option removed')
-- once: the cuff names, the contact and custody names, the vehicle names (one wait for the two run ends)
H.eq(Count('remove') - removes, 3, 'removed once')
before = targetCalls
H.advance(10000, 500)
H.eq(targetCalls - before, 0, 'after the run: no call to ox_target')

-- a run that starts during the wait keeps its options
StartRun('run-3')
H.advance(100)
T.active = true
EndRun('run-3')
H.advance(1000)
StartRun('run-4')
H.advance(100)
calls = #T.globalCalls
T.active = false
H.advance(1000)
H.eq(#T.globalCalls, calls, 'a run started during the wait: nothing removed or added again')
H.ok(OptionsOn(), 'a run started during the wait: its options stay')

-- ============================================================================
--              (d) AN ox_target RESTART, OUTSIDE AND DURING A RUN
-- ============================================================================

TriggerEvent('onClientResourceStop', 'ox_target')
T.restart()
TriggerEvent('onClientResourceStart', 'ox_target')
H.advance(100)
H.ok(OptionsOn(), 'ox_target restart during a run: the options are added again')
-- once: the two cuff labels, the contact and custody options, the vehicle options
H.eq(#T.globalCalls, calls + 4, 'ox_target restart during a run: added once')
EndRun('run-4')
H.advance(100)
H.eq(#T.peds + #T.vehicles, 0, 'run end after the restart: every option removed')
calls = #T.globalCalls
TriggerEvent('onClientResourceStop', 'ox_target')
T.restart()
TriggerEvent('onClientResourceStart', 'ox_target')
H.advance(100)
H.eq(#T.globalCalls, calls, 'ox_target restart outside a run: nothing added')
-- the eye menu is open when ox_target stops: the wait ends, nothing is left to remove
StartRun('run-5')
H.advance(100)
T.active = true
EndRun('run-5')
H.advance(600)
TriggerEvent('onClientResourceStop', 'ox_target')
T.restart()
H.exportsMock.ox_target.isActive = function() error('No such export isActive in resource ox_target') end
calls = #T.globalCalls
H.advance(1000)
H.eq(#T.globalCalls, calls, 'ox_target stopped during the wait: nothing is called on it')
H.exportsMock.ox_target.isActive = function() return false end
TriggerEvent('onClientResourceStart', 'ox_target')
H.advance(100)
H.eq(#T.peds + #T.vehicles, 0, 'ox_target back after that run: no option')

-- ============================================================================
--                                RESOURCE STOP
-- ============================================================================

calls = #T.globalCalls
TriggerEvent('onResourceStop', 'Crimson-Police')
H.eq(#T.globalCalls, calls, 'resource stop outside a run: nothing to remove')
StartRun('run-6')
H.advance(100)
TriggerEvent('onResourceStop', 'Crimson-Police')
H.eq(#T.peds + #T.vehicles, 0, 'resource stop during a run: every option removed')

print(('RESULT %d %d'):format(H.passes, H.failures))

-- Police vs real criminal players, step V3: second, read-only handlers for sc-police's and sc-ambulance's net events
-- pass facts to CP.ScPolice.on / CP.Ambulance.on listeners while a case is open, and read nothing otherwise.
-- Real: modules/integrations/sc_police, modules/integrations/sc_ambulance, shared/net.lua (CP.Net.rateOk).

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })
Config.Debug = true   -- run every CP.log format string too

-- Every native the handlers could read, counted while `counting` is on (H.fire only).
local counting, reads = false, {}
local function Reads(name) return reads[name] or 0 end
local function AllReads()
    local n = 0
    for _, v in pairs(reads) do n = n + v end
    return n
end
for _, name in ipairs({
    'GetPlayerPed',
    'GetEntityCoords',
    'GetGameTimer',
    'GetPlayerName',
    'GetPlayerRoutingBucket',
    'GetResourceState',
    'DoesEntityExist',
    'IsPlayerAceAllowed',
}) do
    local real = _G[name] or function() return nil end
    _G[name] = function(...)
        if counting then reads[name] = (reads[name] or 0) + 1 end
        return real(...)
    end
end
local function Fire(name, src, ...)
    counting = true
    local canceled = H.fire(name, src, ...)
    counting = false
    return canceled
end

-- CP.err lines of the two integrations
local errs = {}
do
    local realErr = CP.err
    CP.err = function(tag, fmt, ...)
        if tag == 'sc_police' or tag == 'sc_ambulance' then errs[#errs + 1] = fmt:format(...) end
        return realErr(tag, fmt, ...)
    end
end

H.load('modules/integrations/sc_police/server.lua')
H.load('modules/integrations/sc_ambulance/server.lua')
local SP, Amb = CP.ScPolice, CP.Ambulance

-- event, kind, a valid sender and arguments, what the listener gets
local CASES = {
    { 'police:server:CuffPlayer', 'cuff', 3, { 7, true }, { 3, 7, true } },
    { 'police:server:UncuffPlayer', 'uncuff', 3, { 7 }, { 3, 7 } },
    { 'police:server:CuffBreakAlert', 'cuffBreak', 7, { 3 }, { 7, 3 } },
    { 'police:server:EscortPlayer', 'escort', 3, { 7 }, { 3, 7 } },
    { 'police:server:JailPlayer', 'jail', 3, { 7, 30 }, { 3, 7, 30 } },
    { 'police:server:BobbyPinResult', 'bobbyPin', 8, { true }, { 8, true } },
    { 'police:server:SeizeCash', 'seizeCash', 3, { 7 }, { 3, 7 } },
    { 'hospital:server:RespawnAtHospital', 'respawn', 7, { 2 }, { 7, 2 } },
}

local got = {}   -- got[kind] = { { n = select('#'), ... }, ... }
local function Got(kind) return got[kind] or {} end
local function Last(kind)
    local list = Got(kind)
    return list[#list]
end
local function Reset()
    got = {}
    reads = {}
    errs = {}
end
local function Recorder(kind)
    return function(...)
        got[kind] = got[kind] or {}
        local list = got[kind]
        list[#list + 1] = { n = select('#', ...), ... }
    end
end
local function On(kind, fn)
    if kind == 'respawn' then return Amb.on(kind, fn) end
    return SP.on(kind, fn)
end
-- want.n counts a trailing nil
local function Same(rec, want)
    local n = want.n or #want
    if not rec or rec.n ~= n then return false end
    for i = 1, n do
        if rec[i] ~= want[i] then return false end
    end
    return true
end
local function Show(v)
    local ok, out = pcall(json.encode, v)
    return ok and out or tostring(v)
end
local function FireAll()
    for _, c in ipairs(CASES) do Fire(c[1], c[3], table.unpack(c[4])) end
end
local function Calls()
    local n = 0
    for _, list in pairs(got) do n = n + #list end
    return n
end

-- ============================================================================
--        1. ONE READ-ONLY HANDLER EACH, AND THE ONES CP NEVER REGISTERS
-- ============================================================================

for _, c in ipairs(CASES) do
    H.eq(#(H.handlers[c[1]] or {}), 1, c[1] .. ': one Crimson-Police handler')
end
H.eq(#(H.handlers['police:server:Impound'] or {}), 1, 'the Impound handler is still the only one for its event')

do
    -- CP reads cuffs from qbx metadata only and never touches sc-ambulance's revive
    local never = { 'police:server:SetHandcuffStatus', 'hospital:server:RevivePlayer' }
    for _, name in ipairs(never) do H.eq(H.handlers[name], nil, name .. ': no handler') end
    local hits = {}
    local p = io.popen('find "' .. H.root .. '" -name "*.lua" -not -path "*/node_modules/*"')
    for path in p:lines() do
        local f = io.open(path, 'r')
        local s = f and f:read('a') or ''
        if f then f:close() end
        s = s:gsub('%-%-[^\n]*', '')
        for _, name in ipairs(never) do
            local pat = name:gsub('%p', '%%%0')
            if s:find('RegisterNetEvent%(%s*[\'"]' .. pat) or s:find('AddEventHandler%(%s*[\'"]' .. pat) then
                hits[#hits + 1] = path .. ' ' .. name
            end
        end
    end
    p:close()
    H.eq(#hits, 0, 'no Crimson-Police file registers SetHandcuffStatus or RevivePlayer: ' .. table.concat(hits, ', '))
end

-- ============================================================================
--           2. ZERO COST WHILE NO LISTENER EXISTS OR NO CASE IS OPEN
-- ============================================================================

do
    Reset()
    CP.Opponents = {
        active = function() return true end,
    }
    FireAll()
    H.eq(AllReads(), 0, 'no listener: no native is read, even with a case open')
    H.eq(Reads('GetPlayerPed'), 0, 'no listener: GetPlayerPed is never called')
    H.eq(#errs, 0, 'no listener: nothing logged')
end

for _, c in ipairs(CASES) do H.eq(On(c[2], Recorder(c[2])), true, 'listener registered: ' .. c[2]) end

do
    -- only some kinds listened to: the others stay free
    Reset()
    CP.Opponents = nil
    FireAll()
    H.eq(Calls(), 0, 'CP.Opponents missing (before V4): no listener runs')
    H.eq(AllReads(), 0, 'CP.Opponents missing: no native is read')

    CP.Opponents = {}
    FireAll()
    H.eq(Calls(), 0, 'CP.Opponents without active(): no listener runs')

    local asked = 0
    CP.Opponents = {
        active = function()
            asked = asked + 1
            return false
        end,
    }
    FireAll()
    H.eq(Calls(), 0, 'active() false: no listener runs')
    H.eq(asked, #CASES, 'active() asked once per event')
    H.eq(AllReads(), 0, 'active() false: no native is read')
    H.eq(Reads('GetPlayerPed'), 0, 'active() false: GetPlayerPed is never called')

    CP.Opponents = {
        active = function() return 1 end,
    }
    FireAll()
    H.eq(Calls(), 0, 'active() must be exactly true (1 is not)')

    CP.Opponents = {
        active = function() error('boom') end,
    }
    FireAll()
    H.eq(Calls(), 0, 'active() raising: no listener runs and the handler does not fail')
    H.eq(#errs, 0, 'active() raising: nothing logged by the handlers')
end

-- ============================================================================
--    3. EACH FACT REACHES ITS LISTENER WITH THE RIGHT SENDER AND ARGUMENTS
-- ============================================================================

CP.Opponents = {
    active = function() return true end,
}

do
    Reset()
    for _, c in ipairs(CASES) do
        Fire(c[1], c[3], table.unpack(c[4]))
        H.eq(#Got(c[2]), 1, c[2] .. ': the listener ran once, inside the event')
        H.ok(Same(Last(c[2]), c[5]), c[2] .. ': sender and arguments ' .. Show(c[5]) .. ', got ' .. Show(Last(c[2])))
    end
    H.eq(#errs, 0, 'nothing logged')
    H.eq(Reads('GetPlayerPed'), 0, 'the handlers read no ped')
    H.eq(Reads('GetGameTimer'), #CASES, 'one clock read per event (the rate limit)')
    local ours = 0
    for _, e in ipairs(H.events) do
        local n = tostring(e.name)
        if n:find('^police:') or n:find('^hospital:') then ours = ours + 1 end
    end
    H.eq(ours, 0, 'Crimson-Police never triggers or answers a police:* or hospital:* event')
end

do
    -- the forms a game sends: string and float ids, the flags only when exactly true, jailTime as sent
    Reset()
    Fire('police:server:CuffPlayer', 3, '7', 1)
    H.ok(Same(Last('cuff'), { 3, 7, false }), 'cuff: a string id becomes a number, isSoftcuff 1 reads false')
    Fire('police:server:CuffPlayer', 3, 7.0)
    H.ok(Same(Last('cuff'), { 3, 7, false }), 'cuff: 7.0 is 7, no isSoftcuff reads false')
    Fire('police:server:CuffPlayer', '3', 7, true)
    H.ok(Same(Last('cuff'), { 3, 7, true }), 'cuff: the sender is a number')
    Fire('police:server:JailPlayer', 3, 7, '30')
    H.ok(Same(Last('jail'), { 3, 7, '30' }), 'jail: jailTime goes on raw for the listener to clamp')
    Fire('police:server:JailPlayer', 3, 7)
    H.ok(Same(Last('jail'), { 3, 7, nil, n = 3 }), 'jail: no jailTime goes on as nil')
    Fire('police:server:BobbyPinResult', 8, 'true')
    H.ok(Same(Last('bobbyPin'), { 8, false }), 'bobbyPin: only true is a success')
    Fire('police:server:BobbyPinResult', 8)
    H.ok(Same(Last('bobbyPin'), { 8, false }), 'bobbyPin: no argument is a failure')
    Fire('hospital:server:RespawnAtHospital', 7, '3')
    H.ok(Same(Last('respawn'), { 7, 3 }), 'respawn: a string index becomes a number')
    H.eq(Fire('police:server:CuffPlayer', 3, 7, true), false, 'the handler never cancels the event')
    Fire('police:server:CuffPlayer', 65535, 1)
    H.ok(Same(Last('cuff'), { 65535, 1, false }), 'ids 1 and 65535 are in range')
end

-- ============================================================================
--                      4. MALFORMED ARGUMENTS ARE DROPPED
-- ============================================================================

do
    Reset()
    local bad = { 0, -1, 65536, 1.5, 'abc', '', {}, true, 0 / 0, math.huge }
    for _, c in ipairs(CASES) do
        if c[2] ~= 'bobbyPin' then
            for _, v in ipairs(bad) do
                local args = { table.unpack(c[4]) }
                args[1] = v
                Fire(c[1], c[3], table.unpack(args, 1, #c[4]))
            end
            Fire(c[1], c[3])   -- no argument at all
        end
    end
    H.eq(Calls(), 0, 'a bad target, officer or hospital index is dropped')
    for _, src in ipairs({ 0, -1, '', 65536, 2.5 }) do
        for _, c in ipairs(CASES) do Fire(c[1], src, table.unpack(c[4])) end
    end
    H.eq(Calls(), 0, 'a sender that is not a player (0, a server-side TriggerEvent) is dropped')
    H.eq(#errs, 0, 'dropped without a log line')
end

-- ============================================================================
--                                5. RATE LIMIT
-- ============================================================================
-- 6 A SECOND PER SENDER AND KIND, DROPPED SILENTLY.

do
    H.clockMs = H.clockMs + 5000
    Reset()
    for _ = 1, 9 do Fire('police:server:EscortPlayer', 4, 7) end
    H.eq(#Got('escort'), 6, 'escort: 6 of 9 within a second reach the listener')
    Fire('police:server:EscortPlayer', 5, 7)
    H.eq(#Got('escort'), 7, 'another sender has its own limit')
    Fire('police:server:UncuffPlayer', 4, 7)
    H.eq(#Got('uncuff'), 1, 'another kind has its own limit')
    for _ = 1, 9 do Fire('hospital:server:RespawnAtHospital', 4, 1) end
    H.eq(#Got('respawn'), 6, 'respawn: 6 of 9 within a second')
    H.clockMs = H.clockMs + 1000
    Fire('police:server:EscortPlayer', 4, 7)
    H.eq(#Got('escort'), 8, 'a second later the sender is let through again')
    H.eq(#errs, 0, 'the rate limit drops without a log line')
end

-- ============================================================================
--             6. A LISTENER THAT FAILS DOES NOT STOP THE NEXT ONE
-- ============================================================================
-- ONE LOG A MINUTE.

do
    H.clockMs = H.clockMs + 5000
    Reset()
    local after = {}
    local function Boom() error('listener broke') end
    H.eq(SP.on('uncuff', Boom), true, 'a second uncuff listener')
    H.eq(SP.on('uncuff', function(src, target) after[#after + 1] = { src, target } end), true, 'a third one')
    H.eq(Amb.on('respawn', Boom), true, 'a second respawn listener')
    H.eq(Amb.on('respawn', function(src, index) after[#after + 1] = { src, index } end), true, 'a third one')
    Fire('police:server:UncuffPlayer', 3, 7)
    Fire('police:server:UncuffPlayer', 3, 8)
    Fire('hospital:server:RespawnAtHospital', 7, 2)
    Fire('hospital:server:RespawnAtHospital', 7, 3)
    H.eq(#Got('uncuff'), 2, 'the listener before the failing one ran every time')
    H.eq(#after, 4, 'the listener after the failing one ran every time')
    H.eq(after[2] and after[2][2], 8, 'with its own arguments')
    H.eq(#errs, 2, 'one error line per kind, not per event')
    H.ok(errs[1] and errs[1]:find('uncuff', 1, true) and errs[1]:find('listener broke', 1, true), 'it names the kind')
    H.time = H.time + 61
    Fire('police:server:UncuffPlayer', 3, 7)
    H.eq(#errs, 3, 'a minute later the next failure is logged again')
end

-- ============================================================================
--                          7. THE LISTENER API ITSELF
-- ============================================================================

do
    Reset()
    H.eq(SP.on('handcuff', function() end), false, 'an unknown kind is refused')
    H.eq(SP.on('cuff', 'fn'), false, 'a listener must be a function')
    H.eq(SP.on('respawn', function() end), false, 'respawn belongs to CP.Ambulance')
    H.eq(Amb.on('cuff', function() end), false, 'cuff belongs to CP.ScPolice')
    H.eq(#errs, 4, 'each refusal is logged')
    local n = 0
    local function Once() n = n + 1 end
    SP.on('seizeCash', Once)
    SP.on('seizeCash', Once)
    Fire('police:server:SeizeCash', 3, 7)
    H.eq(n, 1, 'the same function registered twice runs once')
end

-- ============================================================================
--                 8. THE EXISTING IMPOUND HANDLER STILL WORKS
-- ============================================================================
-- tests/custody_spec.lua too.

do
    Reset()
    CP.Opponents = {
        active = function() return false end,
    } -- the impound handler never waits for a case
    local noted = {}
    H.players[1] = { coords = vec3(0.0, 0.0, 0.0) }
    CP.Runs = {
        all = function()
            local car = { kind = 'vehicle', entity = 900 }
            return { run1 = { id = 'run1', state = 'active', entities = { [55] = car } } }
        end,
        noteExternalRemoval = function(netId, src, why) noted[#noted + 1] = { netId, src, why } end,
    }
    H.fire('police:server:Impound', 1, 'CPXXXXXX', true, 0, 1000.0, 1000.0, 100, 55)
    H.eq(#noted, 1, 'police:server:Impound on a run vehicle is still recorded')
    H.ok(noted[1] and noted[1][1] == 55 and noted[1][2] == 1 and noted[1][3] == 'sc_impound', 'with netId, sender, why')
    H.fire('police:server:Impound', 1, 'X', false, 0, 1000.0, 1000.0, 100, 56)
    H.eq(#noted, 1, 'not a run vehicle: ignored')
    CP.Runs = nil
end

return H

-- Client resmon (docs/dev/LOOPS.md "Resmon"): every client script of fxmanifest.lua loaded as FXServer runs it,

-- Client resmon (docs/dev/LOOPS.md "Resmon"): every client script of fxmanifest.lua loaded as FXServer runs it,
-- each native counted when a Crimson-Police file calls it. The idle game calls none; the busiest frame loop of a run
-- (the checkpoint course: two markers, the inside and contact checks) calls few per frame and builds no string; the
-- HUD sends one NUI message per change; a 'local' officer option decodes this PC's KVP only when it changed. The tired
-- runner pacer's count is in tests/fixtures/npc/client_check.lua.

local H = dofile('tests/harness.lua')
H.boot({ side = 'client' })

-- ============================================================================
--                                 NATIVE METER
-- ============================================================================
-- meter.calls[name] = calls made from a file of the resource (a harness helper reading a native is not counted:
-- cache.ped is a table read in the game). meter.on = false while allocations are measured (debug.getinfo builds a
-- table).

local meter = { calls = {}, total = 0, on = true }
local function FromResource()
    local info = debug.getinfo(3, 'S')
    return info ~= nil and info.short_src:find('Crimson%-Police/') ~= nil
end
local function Counted(name, fn)
    return function(...)
        if meter.on and FromResource() then
            meter.calls[name] = (meter.calls[name] or 0) + 1
            meter.total = meter.total + 1
        end
        return fn(...)
    end
end
local function Native(name, fn) _G[name] = Counted(name, fn) end
function meter.reset()
    meter.calls, meter.total = {}, 0
end
function meter.list()
    local out = {}
    for k, n in pairs(meter.calls) do out[#out + 1] = ('%s %d'):format(k, n) end
    table.sort(out)
    return table.concat(out, ', ')
end

-- natives the spec does not answer: nil, counted all the same
local function Nop() return nil end
H.onUndefinedGlobal(function(k)
    if type(k) == 'string' and k:match('^[A-Z]') then
        local f = Counted(k, Nop)
        rawset(_G, k, f)
        return f
    end
    return nil
end)

-- the world: the officer's ped 100 in car 900 (netId 91)
local PED, CAR = 100, 900
local world = { coords = vec3(0.0, 0.0, 30.0), vehicle = CAR, speed = 10.0 }
_G.LocalPlayer = { state = {} }
Native('PlayerId', function() return 0 end)
Native('GetPlayerServerId', function() return 1 end)
Native('PlayerPedId', function() return PED end)
Native('GetGameTimer', function() return H.clockMs end)
Native('GetEntityCoords', function() return world.coords end)
Native('GetVehiclePedIsIn', function(ped) return ped == PED and world.vehicle or 0 end)
Native('GetPedInVehicleSeat', function(veh) return veh == world.vehicle and PED or 0 end)
Native('DoesEntityExist', function(e) return e == PED or e == CAR end)
Native('GetEntitySpeed', function() return world.speed end)
Native('GetVehicleBodyHealth', function() return 1000.0 end)
Native('GetVehicleEngineHealth', function() return 1000.0 end)
Native('IsVehicleDriveable', function() return true end)
Native('HasEntityCollidedWithAnything', function() return false end)
Native('NetworkGetEntityIsNetworked', function() return true end)
Native('NetworkGetNetworkIdFromEntity', function() return 91 end)
Native('DrawMarker', function() end)
local nextBlip = 0
Native('AddBlipForCoord', function() nextBlip = nextBlip + 1; return nextBlip end)
Native('DoesBlipExist', function(b) return b ~= nil and b > 0 end)
local kvp = {}
Native('GetResourceKvpString', function(k) return kvp[k] end)
local nui = {}
Native('SendNUIMessage', function(msg) nui[#nui + 1] = msg end)
_G.Citizen.Wait = _G.Wait

local failed = {}
for _, rel in ipairs(H.manifestScripts('client_scripts')) do
    local ok, err = pcall(H.load, rel)
    if not ok then failed[#failed + 1] = rel .. ': ' .. tostring(err) end
end
H.eq(#failed, 0, 'every client script loads (' .. table.concat(failed, '; ') .. ')')

-- ============================================================================
--                            IDLE: NO NATIVE AT ALL
-- ============================================================================
-- No run, tablet closed: once the start-up waits are over nothing of Crimson-Police calls the game.

H.advance(600000, 1000)
meter.reset()
H.advance(120000, 250)
H.eq(meter.total, 0, 'idle for two minutes: no native call (' .. meter.list() .. ')')

-- ============================================================================
--                  IN A RUN: THE CHECKPOINT COURSE PER FRAME
-- ============================================================================
-- The busiest frame loop of a run: the course runs (contact and undriveable checks on), the officer drives through
-- the current checkpoint too fast ("Stop inside" every frame), both markers in view. 60 frames of 16 ms.

local FRAME_MS, FRAMES = 16, 60
-- an officer on duty: his session carries his department's officer option rules, as the server sends them
local allow, defaults, bounds = CP.OptionDefs.resolve('lspd')
CP.Access.setSession({
    ui = 'officer',
    roles = { officer = true },
    officer = { citizenid = 'CID1', name = 'A B', department = 'lspd', departmentShort = 'LSPD', rank = 'R' },
    options = {},
    config = { officerOptions = { enabled = true, allow = allow, defaults = defaults, bounds = bounds } },
})
local CR = CP.Blocks.get('checkpoint_route')
local lines = {}
local ctx = {
    runId = 'run-op1',
    index = 1,
    obj = { radius = 10.0, stopFor = 3, vehicleRequired = true },
    mission = {},
    location = {},
    isHost = true,
    radioSilence = false,
    state = {},
    participants = { 1 },
    report = function() end,
    hudDetail = function(text) lines[#lines + 1] = text or false end,
}
local data = {
    kind = 'state',
    points = { { x = 0.0, y = 0.0, z = 30.0 }, { x = 40.0, y = 0.0, z = 30.0 }, { x = 80.0, y = 0.0, z = 30.0 } },
    current = 1,
    total = 3,
    track = { contacts = true, undriveable = true },
    course = { running = true, elapsedMs = 0 },
    medals = true,
}
CR.prepare(ctx)
CR.update(ctx, data)
CR.start(ctx)
H.advance(200, FRAME_MS)

meter.reset()
local lines0 = #lines
H.advance(FRAMES * FRAME_MS, FRAME_MS)
-- the Lua memory the frames allocate, against the same frames with the course stopped (the harness's own threads)
local function KbPerFrame()
    meter.on = false
    collectgarbage('collect')
    collectgarbage('stop')
    local kb0 = collectgarbage('count')
    H.advance(FRAMES * FRAME_MS, FRAME_MS)
    local kb = (collectgarbage('count') - kb0) / FRAMES
    collectgarbage('restart')
    meter.on = true
    return kb
end
local kb = KbPerFrame()
local perFrame = meter.total / FRAMES
print(('  [resmon] checkpoint course: %.1f natives a frame, %d HUD lines in %d frames (%s)'):format(perFrame,
    #lines - lines0, FRAMES, meter.list()))
H.ok(tostring(lines[#lines]):find('stop_here', 1, true) ~= nil or tostring(lines[#lines]):find('Stop', 1, true) ~= nil,
    'the HUD shows the status line: ' .. tostring(lines[#lines]))
H.eq(#lines - lines0, 0, 'the same status line: no new HUD line')
H.eq(meter.calls.DrawMarker, FRAMES * 2, 'both markers drawn every frame')
H.eq(meter.calls.PlayerPedId, nil, 'the frame loop reads cache.ped, never PlayerPedId()')
H.eq(meter.calls.GetEntityCoords, FRAMES, 'GetEntityCoords once a frame')
H.ok((meter.calls.IsVehicleDriveable or 0) <= FRAMES // 5,
    ('the undriveable check once a sample, not a frame (%d)'):format(meter.calls.IsVehicleDriveable or 0))
H.ok(perFrame <= 12.5, ('at most 12.5 natives a frame (%.1f)'):format(perFrame))
CR.stop(ctx)
-- the same harness cost: one thread that only waits a frame, in place of the course loop
local idleLoop = true
CreateThread(function() while idleLoop do Wait(0) end end)
local base = KbPerFrame()
idleLoop = false
H.advance(FRAME_MS, FRAME_MS)
print(('  [resmon] checkpoint course: %.3f KB a frame above the idle harness'):format(kb - base))
H.ok(kb - base <= 0.02, ('no string or table built a frame (%.3f KB a frame)'):format(kb - base))

-- ============================================================================
--                          HUD: ONE MESSAGE A CHANGE
-- ============================================================================

local T = CP.Tablet
local function HudSends()
    local n = 0
    for _, m in ipairs(nui) do
        if type(m) == 'table' and m.type == 'hud' or tostring(m):find('"hud"') then n = n + 1 end
    end
    return n
end
nui = {}
T.hud({ title = 'Run', detail = 'Go to the door' })
H.eq(HudSends(), 1, 'a new HUD: one message')
for _ = 1, 20 do T.hud({ detail = 'Go to the door' }) end
T.hud({ message = false })
H.eq(HudSends(), 1, 'the same detail twenty times and a message that is not there: no message')
T.hud({ detail = 'Knock' })
H.eq(HudSends(), 2, 'a new detail: one message')
T.hud({ detail = false })
T.hud({ detail = false })
H.eq(HudSends(), 3, 'the detail cleared: one message, cleared again: none')
T.hud({ objectives = { { label = 'A' } } })
H.eq(HudSends(), 4, 'a table value always counts as a change')
T.hud(nil)
T.hud({ detail = 'Knock' })
H.eq(HudSends(), 6, 'after the HUD is hidden the next patch shows it again')

-- ============================================================================
--             OPTION READS: THE PC'S OPTIONS DECODED ONCE A CHANGE
-- ============================================================================
-- A 'local' option (the sound cues of every objective cue, the HUD target line) is read from this PC's KVP; its JSON
-- is decoded only when the KVP text changed, not at every read.

local cjson = require('cjson')
kvp['crimsonpolice:options'] = cjson.encode({ soundCues = false, hudTargetLine = false, hudScale = 1.2 })
local decodes = 0
local realDecode = json.decode
json.decode = function(...) decodes = decodes + 1; return realDecode(...) end
for _ = 1, 100 do CP.Options.get('soundCues') end
H.eq(CP.Options.get('soundCues'), false, 'the PC\'s value is read')
H.eq(decodes, 1, ('a hundred reads of the same KVP: one decode (%d)'):format(decodes))
kvp['crimsonpolice:options'] = cjson.encode({ soundCues = true })
H.eq(CP.Options.get('soundCues'), true, 'a changed KVP is read at once')
H.eq(decodes, 2, 'and decoded once')
json.decode = realDecode

return H

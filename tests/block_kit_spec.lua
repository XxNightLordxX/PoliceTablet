-- The block client kit (CP.BlockKit, blocks/_kit/client.lua): one state per run and objective, one resource-stop
-- cleanup, the entity helpers, a progress bar that never raises and one marker loop per run; and every block client
-- uses it instead of its own copy. Plain Lua: no database.

local H = dofile('tests/harness.lua')
H.boot({ side = 'client' })

local function Read(rel)
    local f = assert(io.open(H.root .. rel, 'r'))
    local s = f:read('a')
    f:close()
    return s
end

local BLOCKS = {
    'checkpoint_route',
    'escort',
    'field_contact',
    'flee_arrest',
    'hostile_waves',
    'interact_points',
    'live_response',
    'process_scene',
    'protect_rescue',
    'pursuit',
    'search_area',
    'skill_check',
}

-- ============================================================================
--                         THE MANIFEST AND THE BLOCKS
-- ============================================================================

local client = H.manifestScripts('client_scripts')
local at, count = {}, {}
for i, rel in ipairs(client) do
    at[rel] = at[rel] or i
    count[rel] = (count[rel] or 0) + 1
end
H.eq(count['blocks/_kit/client.lua'], 1, 'the kit is loaded once')
for _, b in ipairs(BLOCKS) do
    local rel = 'blocks/' .. b .. '/client.lua'
    H.eq(count[rel], 1, rel .. ' is loaded once')
    H.ok((at[rel] or 0) > (at['blocks/_kit/client.lua'] or math.huge), rel .. ' loads after the kit')
    local code = Read(rel):gsub('%-%-[^\n]*', '')
    H.eq(code:find('AddEventHandler(\'onResourceStop\'', 1, true), nil, rel .. ': no resource-stop handler of its own')
    H.eq(code:find('pcall(lib.progressBar', 1, true), nil, rel .. ': no progress-bar wrapper of its own')
    H.eq(code:find('lib.progressBar(', 1, true), nil, rel .. ': every progress bar goes through the kit')
    H.eq(code:find('NetworkGetEntityFromNetworkId', 1, true), nil, rel .. ': no entity lookup of its own')
    H.eq(code:find('local active = {}', 1, true), nil, rel .. ': no state table of its own')
    H.eq(code:find('local function V3(', 1, true), nil, rel .. ': no point helper of its own (Kit.point)')
    H.eq(code:find('local function Txt(', 1, true), nil, rel .. ': no text helper of its own (Kit.text)')
end
for _, b in ipairs({
    'escort',
    'flee_arrest',
    'interact_points',
    'process_scene',
    'protect_rescue',
    'search_area',
    'skill_check',
}) do
    H.ok(Read('blocks/' .. b .. '/client.lua'):find('Kit.markers(', 1, true) ~= nil, b .. ': its markers go to the kit')
end

-- ============================================================================
--                                    STATES
-- ============================================================================

H.load('blocks/_kit/client.lua')
local Kit = CP.BlockKit
H.ok(type(Kit) == 'table', 'CP.BlockKit is loaded')

local cleaned = {}
local K
K = Kit.states(function() return { blips = {} } end, function(S)
    cleaned[#cleaned + 1] = S.key
    S.alive = false
    K.drop(S)
end)
local a1 = { runId = 'r1', index = 1 }
local S = K.of(a1)
H.eq(S.key, 'r1:1', 'a state knows its key')
H.eq(S.runKey, 'r1', 'and its run')
H.ok(S.ctx == a1, 'and the latest ctx')
H.ok(K.of({ runId = 'r1', index = 1 }) == S, 'the same objective: the same state')
H.ok(K.find({ runId = 'r1', index = 2 }) == nil, 'find makes no state')
S.alive = true
local late = K.of({ runId = 'r0', index = 3 })   -- a late snapshot of an ended run: never started
H.ok(K.find({ runId = 'r0', index = 3 }) == late, 'a late snapshot makes a state')
K.of({ runId = 'r2', index = 1 })
H.eq(K.find({ runId = 'r0', index = 3 }), nil, 'a new state drops the states other runs left behind')
H.ok(K.find(a1) == S, 'a started state of another run stays')

local stopped = 0
Kit.onStop(function() stopped = stopped + 1 end)
TriggerEvent('onResourceStop', 'another-resource')
H.eq(#cleaned, 0, 'another resource stopping cleans nothing')
TriggerEvent('onResourceStop', GetCurrentResourceName())
H.eq(table.concat(cleaned, ','), 'r1:1', 'the resource stop cleans every started state (and only those)')
H.eq(stopped, 1, 'and runs the onStop functions')
H.eq(K.find(a1), nil, 'the cleaned state is gone')

-- H6: ox_target (re)starts: retarget runs for every started state of a list that has one, never for another resource
local retargeted = {}
local R = Kit.states(function() return {} end, function() end, function(S)
    retargeted[#retargeted + 1] = S.key
end)
local r1 = R.of({ runId = 'q1', index = 1 })
r1.alive = true
R.of({ runId = 'q1', index = 2 })   -- prepared, never started
TriggerEvent('onClientResourceStart', 'another-resource')
H.eq(#retargeted, 0, 'another resource starting retargets nothing')
TriggerEvent('onClientResourceStart', 'ox_target')
H.eq(table.concat(retargeted, ','), 'q1:1', 'ox_target starting retargets every started state (and only those)')
local okT, idT = Kit.target('test', function() return 42 end)
H.ok(okT == true and idT == 42, 'target: an add that works gives its result')
local warnedT = 0
local keepWarnT = CP.warn
CP.warn = function() warnedT = warnedT + 1 end
okT, idT = Kit.target('test', function() error('No such export addSphereZone in resource ox_target') end)
CP.warn = keepWarnT
H.ok(okT == false and idT == nil and warnedT == 1,
    'target: an add that raises (ox_target down) never raises, is logged')
R.drop(r1)

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local v = Kit.vec3({ x = 1, y = 2, z = 3 })
H.eq(v and v.x, 1.0, 'vec3 of a table')
H.eq(Kit.vec3('nowhere'), nil, 'vec3 of nothing: nil')
local pt = Kit.point({ x = 4, y = 5 })
H.ok(pt and pt.x == 4.0 and pt.z == 0.0, 'point: a missing coordinate is 0')
H.eq(Kit.text(''), nil, 'text of nothing: nil')
H.eq(Kit.text('As written'), 'As written', 'text: other text as written')
H.eq(Kit.entity(nil), nil, 'entity of no net id: nil')

local keepBar, keepActive, keepCancel = lib.progressBar, lib.progressActive, lib.cancelProgress
local warned = 0
local keepWarn = CP.warn
CP.warn = function() warned = warned + 1 end
lib.progressBar = function() error('animation dictionary failed to load') end
H.eq(Kit.progress({ duration = 10 }, 'test bar'), false, 'a bar that raises counts as cancelled')
H.eq(warned, 1, 'and is logged')
lib.progressBar = function() return true end
H.eq(Kit.progress({ duration = 10 }, 'test bar'), true, 'a bar that ran to its end')
lib.progressBar = function() return false end
H.eq(Kit.progress({ duration = 10 }, 'test bar'), false, 'a cancelled bar')
local cancels = 0
lib.progressActive = function() return true end
lib.cancelProgress = function() cancels = cancels + 1 end
Kit.cancelProgress()
H.eq(cancels, 1, 'cancelProgress stops a running bar')
lib.progressActive = function() return false end
Kit.cancelProgress()
H.eq(cancels, 1, 'and does nothing without one')
CP.warn = keepWarn

-- the skill_check recovery bar raised out of its thread before (busy stayed set): it goes through the kit now
H.ok(Read('blocks/skill_check/client.lua'):find('Kit.progress({', 1, true) ~= nil,
    'skill_check: the setback recovery bar never raises')
lib.progressBar, lib.progressActive, lib.cancelProgress = keepBar, keepActive, keepCancel

-- ============================================================================
--                           ONE MARKER LOOP PER RUN
-- ============================================================================

_G.cache = _G.cache or {}
_G.cache.ped = 77
local me = vec3(0.0, 0.0, 30.0)
local keepCoords = _G.GetEntityCoords
_G.GetEntityCoords = function() return me end
local threads = 0
local keepThread = _G.CreateThread
_G.CreateThread = function(fn)
    threads = threads + 1
    return keepThread(fn)
end
local waits = {}
local keepWait = _G.Wait
_G.Wait = function(ms)
    waits[#waits + 1] = ms
    return keepWait(ms)
end
_G.Citizen.Wait = _G.Wait

local function Source(S, p, far)
    return {
        range = 40.0,
        far = far,
        keep = function() return S.current end,
        draw = function(_, pos, rangeSq)
            local dx, dy, dz = pos.x - p.x, pos.y - p.y, pos.z - p.z
            if dx * dx + dy * dy + dz * dz > rangeSq then return false end
            S.drawn = (S.drawn or 0) + 1
            return true
        end,
    }
end

local M = Kit.states(function() return { alive = true, current = true } end, function() end)
local c1, c2 = { runId = 'm1', index = 1 }, { runId = 'm1', index = 2 }
local S1, S2 = M.of(c1), M.of(c2)
Kit.markers(c1, S1, Source(S1, vec3(0.0, 20.0, 30.0), 1500))
Kit.markers(c2, S2, Source(S2, vec3(0.0, 900.0, 30.0), 1000))
Kit.markers(c1, S1, Source(S1, vec3(0.0, 20.0, 30.0), 1500))
H.eq(threads, 1, 'two objectives of one run, three calls: one marker loop')
H.advance(1000, 50)
H.ok((S1.drawn or 0) > 0, 'the near marker is drawn')
H.eq(S2.drawn, nil, 'the far one is not')
local frames = 0
for _, ms in ipairs(waits) do if ms == 0 then frames = frames + 1 end end
H.ok(frames > 0, 'a marker in range: the loop runs per frame')

S1.current = false
H.advance(3000, 50)
waits = {}
H.advance(6000, 50)
local far = 0
for _, ms in ipairs(waits) do
    H.ok(ms ~= 0, 'nothing in range: no per-frame pass')
    if ms == 1000 then far = far + 1 end
end
H.ok(far >= 5 and far <= 7, ('nothing in range: the shortest far wait of the run (%d passes in 6 s)'):format(far))

S2.alive = false
H.advance(3000, 50)
waits = {}
H.advance(5000, 50)
H.eq(#waits, 0, 'the last source gone: the loop ended')
H.eq(S1.kitMarker, nil, 'a dropped source can be added again')

local c3 = { runId = 'm2', index = 1 }
local S3 = M.of(c3)
Kit.markers(c3, S3, Source(S3, vec3(0.0, 1.0, 30.0), 1500))
H.eq(threads, 2, 'another run: its own loop')
S3.current = false
H.advance(3000, 50)

_G.CreateThread, _G.Wait, _G.Citizen.Wait, _G.GetEntityCoords = keepThread, keepWait, keepWait, keepCoords

return H

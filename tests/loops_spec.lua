-- Loops timed right (step LP1, docs/LOOPS.md): every client script of fxmanifest.lua loaded as FXServer runs it, then
-- the game left idle (no run, tablet closed, every feature switch off). After the start-up waits have ended nothing
-- wakes; a feature's loop runs only while that feature is on and ends with it, one thread per purpose.

local H = dofile('tests/harness.lua')
H.boot({ side = 'client' })

-- natives the idle game does not need answer nil (FXServer would answer; no loop of the idle game reads them)
local function Nop() return nil end
H.onUndefinedGlobal(function(k)
    if type(k) == 'string' and k:match('^[A-Z]') then return Nop end
    return nil
end)
_G.PlayerId = function() return 0 end
_G.GetPlayerServerId = function() return 1 end
_G.LocalPlayer = { state = {} }
local pressed = {}
_G.IsControlPressed = function(_, c) return pressed[c] == true end
_G.GetDisabledControlNormal = function() return 0.0 end

-- every Wait of the resource's own files: { file, ms, co }
local waits = {}
local realWait = _G.Wait
_G.Wait = function(ms)
    local info = debug.getinfo(2, 'S')
    local file = info.short_src:match('Crimson%-Police/(.*)$')
    if file then waits[#waits + 1] = { file = file, ms = ms or 0, co = coroutine.running() } end
    return realWait(ms)
end
_G.Citizen.Wait = _G.Wait

local function From(file)
    local n, threads, list = 0, {}, {}
    for _, w in ipairs(waits) do
        if w.file == file then
            n = n + 1
            if not threads[w.co] then
                threads[w.co] = true
                list[#list + 1] = w.co
            end
        end
    end
    return n, #list
end

local failed = {}
for _, rel in ipairs(H.manifestScripts('client_scripts')) do
    local ok, err = pcall(H.load, rel)
    if not ok then failed[#failed + 1] = rel .. ': ' .. tostring(err) end
end
H.eq(#failed, 0, 'every client script loads (' .. table.concat(failed, '; ') .. ')')

-- ============================================================================
--                             IDLE: NOTHING WAKES
-- ============================================================================
-- The start-up waits (the settings list, the mission definitions retry) end within ten minutes of an unanswered
-- server; after that an idle game runs no thread of Crimson-Police at all.

H.advance(600000, 1000)
waits = {}
H.advance(120000, 250)
local byFile = {}
for _, w in ipairs(waits) do byFile[w.file] = (byFile[w.file] or 0) + 1 end
local names = {}
for f, n in pairs(byFile) do names[#names + 1] = ('%s (%d)'):format(f, n) end
table.sort(names)
H.eq(#names, 0, 'idle for two minutes: no client loop wakes (' .. table.concat(names, ', ') .. ')')

-- ============================================================================
--                                  AUTO-READY
-- ============================================================================
-- The input watcher runs only while the option is on.

local function Session(options)
    return {
        ui = 'officer',
        roles = { officer = true },
        officer = { citizenid = 'CID1', name = 'A B', department = 'lspd', departmentShort = 'LSPD', rank = 'R' },
        options = options,
    }
end
local O = CP.Options
local keepAllow = Config.OfficerOptions.allow.autoReady
Config.OfficerOptions.allow.autoReady = true
waits = {}
CP.Access.setSession(Session({ autoReady = true }))
H.eq(O.get('autoReady'), true, 'Auto-Ready on')
H.advance(5000, 250)
local n, threads = From('modules/options/client.lua')
H.ok(n >= 10, ('on: the watcher looks for input (%d waits)'):format(n))
H.eq(threads, 1, 'on: one watcher')
pressed[32] = true
H.advance(500, 250)
pressed[32] = nil
H.ok(O.activeWithin(60000), 'on: the watcher saw the input')
O.watchInput()
CP.Hooks.fire('settings:changed')
H.advance(1000, 250)
H.eq(select(2, From('modules/options/client.lua')), 1, 'a second start (hook, Settings change) keeps one watcher')

CP.Access.setSession(Session({ autoReady = false }))
H.advance(1000, 250)
waits = {}
H.advance(30000, 250)
H.eq((From('modules/options/client.lua')), 0, 'off: the watcher has ended, nothing wakes')
H.ok(not O.activeWithin(60000), 'off: the last input is forgotten')

-- turned on by a change no hook saw (a department rule in config.lua): the first Auto-Ready question starts it
Config.OfficerOptions.allow.autoReady = false
CP.Access.setSession(Session({ autoReady = true }))
H.advance(1000, 250)
waits = {}
H.advance(5000, 250)
H.eq((From('modules/options/client.lua')), 0, 'locked by config.lua: no watcher')
Config.OfficerOptions.allow.autoReady = true
H.ok(not O.activeWithin(60000), 'unlocked: the first question answers "not at the keys"')
H.advance(1000, 250)
H.ok((From('modules/options/client.lua')) > 0, 'unlocked: that question started the watcher')
CP.Access.setSession(Session({ autoReady = false }))
H.advance(1000, 250)
Config.OfficerOptions.allow.autoReady = keepAllow

-- ============================================================================
--                               CRIMINAL TABLET
-- ============================================================================
-- One Escape guard thread, extended by a second close.

waits = {}
CP.CrimTab._guardPause()
H.advance(100, 50)
CP.CrimTab._guardPause()
H.advance(100, 50)
local _, guards = From('modules/crimtab/client.lua')
H.eq(guards, 1, 'two closes in a row: one guard thread')
H.advance(2000, 50)
waits = {}
H.advance(1000, 50)
H.eq((From('modules/crimtab/client.lua')), 0, 'the guard ends once its time is up')
CP.CrimTab._guardPause()
H.advance(50, 50)
H.eq(select(2, From('modules/crimtab/client.lua')), 1, 'a later close starts a new guard')
H.advance(2000, 50)

return H

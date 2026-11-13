-- The harness's thread stubs against FXServer's scheduler (stub fidelity): CreateThread runs at once by default

-- The harness's thread stubs against FXServer's scheduler (stub fidelity): CreateThread runs at once by default
-- (the harness's long-standing order), Citizen.CreateThreadNow always runs at once (event handlers use it), and the
-- opt-in deferred mode (H.deferThreads / CP_DEFER_THREADS=1) queues a CreateThread thread to the next tick as the
-- game does (citizen/scripting/lua/scheduler.lua).

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

local ran = {}
CreateThread(function() ran[#ran + 1] = 'default' end)
H.eq(ran[1], 'default', 'default: CreateThread runs at once, up to its first Wait')
H.eq(type(Citizen.CreateThreadNow), 'function', 'Citizen.CreateThreadNow exists, as in FXServer')
Citizen.CreateThreadNow(function() ran[#ran + 1] = 'now' end)
H.eq(ran[2], 'now', 'Citizen.CreateThreadNow runs at once')

H.boot({ side = 'server', deferThreads = true })
H.eq(H.deferring, true, 'deferred mode is on with opts.deferThreads')
ran = {}
CreateThread(function()
    ran[#ran + 1] = 'deferred'
    Wait(100)
    ran[#ran + 1] = 'after wait'
end)
Citizen.CreateThread(function() ran[#ran + 1] = 'citizen deferred' end)
Citizen.CreateThreadNow(function() ran[#ran + 1] = 'now' end)
H.eq(table.concat(ran, ','), 'now', 'deferred: only CreateThreadNow ran before the next tick')
H.step(0)
H.eq(table.concat(ran, ','), 'now,deferred,citizen deferred', 'the next tick runs the queued threads in order')
H.step(100)
H.eq(ran[4], 'after wait', 'and their Waits as before')
local fired = false
SetTimeout(50, function() fired = true end)
H.step(50)
H.eq(fired, false, 'SetTimeout starts its thread on the next tick, then waits')
H.step(50)
H.eq(fired, true, 'and fires after its time')

return H

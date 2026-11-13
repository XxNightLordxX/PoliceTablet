-- Who may read one run's history (review:getRunHistory, modules/review/history.lua MayRead): an admin any run,
-- a supervisor a run of his department (reviewFlagged or handleDisputes), never a run he or one of his characters took
-- part in, never a plain officer or a supervisor of another department; a bad run id is refused first.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server', realLocale = true })
local W = dofile('tests/fixtures/adminctl/p1_world.lua')(H)
H.load('modules/review/history.lua')

-- a FIB supervisor (the world has SAST's SUP00002 only)
W.people[7] = { cid = 'SUP00007', name = 'Fred Fibsup', license = 'license:g7', job = 'fib', grade = 3 }
H.players[7] = { ace = {}, coords = vec3(0.0, 0.0, 0.0) }
W.async(function() return CP.Access.refreshOfficerRow(7) end)

H.sql('DELETE FROM cp_mission_runs')
local RUN = W.uuid()
local OWN = W.uuid()
W.row({ citizenid = 'OFF00003', department = 'sast', uuid = RUN })
W.row({ citizenid = 'OFF00006', department = 'sast', uuid = OWN })
W.row({ citizenid = 'SUP00002', department = 'sast', uuid = OWN })   -- the SAST supervisor took part in this one

local function Read(src, uuid) return W.cb('review:getRunHistory', src, { runUuid = uuid }) end
local function Events(res)
    local d = res and res.ok == true and res.data
    return type(d) == 'table' and type(d.events) == 'table' and #d.events or nil
end

local res = Read(1, RUN)
H.ok(Events(res) and Events(res) >= 1 and res.data.runUuid == RUN, 'an admin reads the timeline')
res = Read(2, RUN)
H.ok(Events(res) and Events(res) >= 1, 'a supervisor of the run\'s department reads it')
res = Read(7, RUN)
H.ok(res and res.ok == false and res.error == 'err.no_permission',
    'a supervisor of another department: err.no_permission (' .. tostring(res and res.error) .. ')')
res = Read(3, RUN)
H.ok(res and res.ok == false and res.error == 'err.no_permission',
    'a plain officer: err.no_permission (' .. tostring(res and res.error) .. ')')
res = Read(2, OWN)
H.ok(res and res.ok == false and res.error == 'err.own_run',
    'a supervisor who took part in the run: err.own_run (' .. tostring(res and res.error) .. ')')
res = Read(1, OWN)
H.ok(Events(res) and Events(res) >= 2, 'an admin reads the run another officer took part in')
for _, bad in ipairs({ 'not a uuid', 42, '' }) do
    res = Read(1, bad)
    H.ok(res and res.ok == false and res.error == 'err.invalid_run',
        'a bad run id: err.invalid_run (' .. tostring(bad) .. ')')
end
res = W.cb('review:getRunHistory', 1, nil)
H.ok(res and res.ok == false and res.error == 'err.invalid_run', 'no payload: err.invalid_run')

return H

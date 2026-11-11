-- The shared helper library (shared/lib.lua and CP.U.toSrc): sources, the store wait, toasts and pushes, export
-- calls, one-at-a-time locks and per-day caps, with the races two requests sent at once used to win.

local H = dofile('tests/harness.lua')
H.boot({ side = 'server' })

local U = CP.U

-- CP.U.toSrc: an integer above 0; 0 only for the console when asked
H.eq(U.toSrc(3), 3, 'toSrc 3')
H.eq(U.toSrc('7'), 7, 'toSrc "7"')
H.eq(U.toSrc(4.0), 4, 'toSrc 4.0 is the integer 4')
H.eq(math.type(U.toSrc('4.0')), 'integer', 'toSrc answers an integer')
H.eq(U.toSrc(2.5), nil, 'toSrc 2.5')
H.eq(U.toSrc(-1), nil, 'toSrc -1')
H.eq(U.toSrc(0), nil, 'toSrc 0 is not a player')
H.eq(U.toSrc(0, true), 0, 'toSrc 0 with console = true')
H.eq(U.toSrc('x'), nil, 'toSrc "x"')
H.eq(U.toSrc(nil), nil, 'toSrc nil')
H.eq(U.toSrc(math.huge), nil, 'toSrc inf')
H.eq(U.toSrc(0 / 0), nil, 'toSrc nan')

-- CP.Db waits for the migrations and answers true
H.eq(CP.Db(), true, 'CP.Db once started')

-- CP.notify and CP.push go through CP.Tablet; a failure is logged, never raised
do
    local savedTablet = CP.Tablet
    local seen = {}
    CP.Tablet = {
        notify = function(...) seen[#seen + 1] = { 'notify', ... } end,
        push = function(src, topic)
            if topic == 'boom' then error('bad push') end
            seen[#seen + 1] = { 'push', src, topic }
        end,
    }
    H.eq(CP.notify(5, 'info', 'k', { a = 1 }, { channel = 'social' }), true, 'notify sent')
    H.eq(seen[1][2], 5, 'notify to src 5')
    H.eq(seen[1][6].channel, 'social', 'notify keeps opts')
    H.eq(CP.notify(0, 'info', 'k'), false, 'no toast to the console')
    H.eq(CP.notify(nil, 'info', 'k'), false, 'no toast to nobody')
    H.eq(CP.push('9', 'board', {}), true, 'push sent')
    H.eq(seen[2][2], 9, 'push to src 9')
    H.eq(CP.push(9, 'boom', {}), false, 'a failing push answers false')
    CP.Tablet = nil
    H.eq(CP.notify(5, 'info', 'k'), false, 'no tablet module: false')
    CP.Tablet = savedTablet
end

-- CP.Ext.call: the started check, the results, a failing export
do
    H.exportsMock.some_res = {
        Add = function(a, b) return a + b, 'two' end,
        Boom = function() error('broken') end,
    }
    local ok, sum, extra = CP.Ext.call('some_res', 'Add', 2, 3)
    H.eq(ok, true, 'export call ok')
    H.eq(sum, 5, 'export result')
    H.eq(extra, 'two', 'second export result')
    local okB, errB = CP.Ext.call('some_res', 'Boom')
    H.eq(okB, false, 'a failing export answers false')
    H.ok(tostring(errB):find('broken', 1, true) ~= nil, 'with its error')
    local savedState = GetResourceState
    GetResourceState = function() return 'stopped' end
    local okS, errS = CP.Ext.call('some_res', 'Add', 1, 1)
    H.eq(okS, false, 'a stopped resource is not called')
    H.eq(errS, 'not_started', 'not_started')
    H.eq(CP.Ext.started('some_res'), false, 'started false')
    GetResourceState = savedState
    H.exportsMock.some_res = nil
end

-- CP.errEvery: one line a minute per tag and key; CP.Ext.call and CP.Call log their failures through it
do
    local realErr, realTime = CP.err, os.time
    local logged, now = {}, 1000000
    CP.err = function(tag, fmt, ...) logged[#logged + 1] = tag .. ':' .. fmt:format(...) end
    os.time = function() return now end
    H.eq(CP.errEvery('t', 'k', 'a %d', 1), true, 'errEvery: the first line is printed')
    H.eq(CP.errEvery('t', 'k', 'a %d', 2), false, 'errEvery: the same key within a minute is not')
    H.eq(CP.errEvery('t', 'other', 'b'), true, 'errEvery: another key is')
    H.eq(CP.errEvery('u', 'k', 'c'), true, 'errEvery: the same key of another tag is')
    now = now + 60
    H.eq(CP.errEvery('t', 'k', 'a %d', 3), true, 'errEvery: a minute later it is printed again')
    H.eq(#logged, 4, 'errEvery: four lines')
    logged = {}
    H.exportsMock.some_res = {
        Fails = function() error('broken') end,
    }
    for _ = 1, 5 do CP.Ext.call('some_res', 'Fails') end
    H.eq(#logged, 1, 'an export failing five times in a minute prints one line')
    H.exportsMock.some_res = nil
    logged = {}
    CP.Probe2 = {
        boom = function() error('boom') end,
    }
    for _ = 1, 5 do CP.Call('probe', 'Probe2', 'boom') end
    H.eq(#logged, 1, 'a module function failing five times prints one line')
    CP.Probe2 = nil
    CP.err, os.time = realErr, realTime
end

-- CP.Has and CP.can: a module that may be missing; a permission answer always carries an error key
do
    H.eq(CP.Has('Nope', 'fn'), false, 'Has: a missing module')
    CP.Probe3 = {
        fn = function() return 1 end,
        notFn = 1,
    }
    H.eq(CP.Has('Probe3', 'fn'), true, 'Has: a function')
    H.eq(CP.Has('Probe3', 'notFn'), false, 'Has: not a function')
    CP.Probe3 = nil
    local savedP, realErr = CP.Permissions, CP.err
    CP.err = function() end
    CP.Permissions = nil
    local ok, e = CP.can(1, 'openAdmin')
    H.ok(ok == false and e == 'err.no_permission', 'can: no permissions module: refused with a key')
    CP.Permissions = {
        can = function(src, action, ctx, known)
            if action == 'boom' then error('bad') end
            if action == 'none' then return false end
            if action == 'dept' then return ctx.department == 'sast' and known.admin == true, 'err.department' end
            return action == 'yes', 'err.special'
        end,
    }
    H.eq(CP.can(1, 'yes'), true, 'can: allowed')
    ok, e = CP.can(1, 'no')
    H.ok(ok == false and e == 'err.special', 'can: refused with its own key')
    ok, e = CP.can(1, 'none')
    H.ok(ok == false and e == 'err.no_permission', 'can: refused with no key: err.no_permission')
    ok, e = CP.can(1, 'boom')
    H.ok(ok == false and e == 'err.no_permission', 'can: a raising check refuses, never raises')
    H.eq(CP.can(1, 'dept', { department = 'sast' }, { admin = true }), true, 'can: ctx and known are passed on')
    CP.Permissions, CP.err = savedP, realErr
end

-- CP.srcOf, CP.notifyCitizen, CP.pushCitizen: a toast or push to the player who has a character loaded
do
    local savedQ, savedTablet = CP.Qbx, CP.Tablet
    local seen = {}
    CP.Qbx = {
        getByCitizenId = function(cid) return ({ ON001 = 4, STR01 = '6' })[cid] end,
    }
    CP.Tablet = {
        notify = function(src, kind, key) seen[#seen + 1] = { 'notify', src, kind, key } end,
        push = function(src, topic) seen[#seen + 1] = { 'push', src, topic } end,
    }
    H.eq(CP.srcOf('ON001'), 4, 'srcOf: an online character')
    H.eq(CP.srcOf('STR01'), 6, 'srcOf: a source as a string is a number')
    H.eq(CP.srcOf('OFF01'), nil, 'srcOf: offline')
    H.eq(CP.srcOf('console'), nil, 'srcOf: the console is no player')
    H.eq(CP.srcOf(nil), nil, 'srcOf: nil')
    H.eq(CP.notifyCitizen('ON001', 'info', 'k'), 4, 'notifyCitizen: the source it went to')
    H.eq(CP.notifyCitizen('OFF01', 'info', 'k'), nil, 'notifyCitizen: nil while offline')
    H.eq(CP.pushCitizen('ON001', 'profile', {}), 4, 'pushCitizen: the source it went to')
    H.eq(#seen, 2, 'one toast and one push sent, nothing to an offline character')
    H.ok(seen[1][1] == 'notify' and seen[1][2] == 4 and seen[2][1] == 'push' and seen[2][3] == 'profile',
        'to the right player')
    CP.Qbx = nil
    H.eq(CP.srcOf('ON001'), nil, 'srcOf: no player lookup: nil')
    CP.Qbx, CP.Tablet = savedQ, savedTablet
end

-- CP.Lock: one at a time, waits, frees on error
do
    local lock = CP.Lock.new()
    local order = {}
    CreateThread(function()
        local st = lock:run('cid1', 0, function()
            order[#order + 1] = 'a in'
            Wait(200)
            order[#order + 1] = 'a out'
        end)
        order[#order + 1] = 'a ' .. st
    end)
    H.eq(lock:held('cid1'), true, 'held while the first runs')
    -- a second request sent at once with no wait is refused
    local st2 = lock:run('cid1', 0, function() order[#order + 1] = 'never' end)
    H.eq(st2, 'busy', 'a second request at once is busy')
    -- one that may wait runs after the first
    CreateThread(function()
        local st, v = lock:run('cid1', 1000, function() order[#order + 1] = 'b in'; return 42 end)
        order[#order + 1] = 'b ' .. st .. ' ' .. tostring(v)
    end)
    H.advance(500, 50)
    H.eq(table.concat(order, ','), 'a in,a out,a ok,b in,b ok 42', 'b waited for a')
    H.eq(lock:held('cid1'), false, 'free after both')
    -- an error frees the key and is answered
    local st3, err3 = lock:run('cid1', 0, function() error('oops') end)
    H.eq(st3, 'error', 'error answered')
    H.ok(tostring(err3):find('oops', 1, true) ~= nil, 'with the error')
    H.eq(lock:held('cid1'), false, 'freed after an error')
    -- a wait that runs out answers busy
    CreateThread(function() lock:run('cid2', 0, function() Wait(1000) end) end)
    local late = nil
    CreateThread(function() late = lock:run('cid2', 200, function() end) end)
    H.advance(400, 50)
    H.eq(late, 'busy', 'still held after the wait: busy')
    H.advance(1000, 50)
    -- other keys never wait
    H.eq(lock:run('cid3', 0, function() return 1 end), 'ok', 'another key runs at once')
end

-- CP.Lock players: a drop frees the key; the run that held it does not free the new holder's key
do
    local lock = CP.Lock.new({ players = true })
    CreateThread(function() lock:run(12, 0, function() Wait(500) end) end)
    H.eq(lock:held(12), true, 'player 12 held')
    H.fire('playerDropped', 12)
    H.eq(lock:held(12), false, 'freed when player 12 drops')
    -- a new player gets source 12 and takes the key before the old run ends
    local second = nil
    CreateThread(function() second = lock:run(12, 0, function() Wait(1000) end) end)
    H.advance(600, 50)
    H.eq(lock:held(12), true, 'the old run ending keeps the new holder\'s key')
    H.advance(1000, 50)
    H.eq(second, 'ok', 'the new holder ran')
    H.eq(lock:held(12), false, 'free after the new holder')
    -- all keys at once or none
    CreateThread(function() lock:run(3, 0, function() Wait(300) end) end)
    H.eq(lock:runAll({ 2, 3 }, function() end), 'busy', 'one member busy: the whole unit is busy')
    H.eq(lock:held(2), false, 'nothing taken when one is busy')
    H.advance(400, 50)
    H.eq(lock:runAll({ 2, 3 }, function() return 'go' end), 'ok', 'all free: runs')
end

-- CP.Daily: the cap counts reservations, so two requests sent at once cannot both pass
do
    local day = 1
    local links = CP.Daily.new(function() return day end)
    H.eq(links:left('cid', 3), 3, 'nothing used')
    local t1 = links:reserve('cid', 1, 1)
    H.ok(t1 ~= nil, 'the first request reserves the last link')
    H.eq(links:reserve('cid', 1, 1), nil, 'a second request sent before the first saved is refused')
    links:cancel(t1)
    H.eq(links:left('cid', 1), 1, 'a cancelled reservation gives the link back')
    local t2 = links:reserve('cid', 2, 1)
    links:commit(t2)
    H.eq(links:used('cid'), 1, 'a committed reservation counts')
    H.eq(links:commit(t2), false, 'a token commits once')
    -- the race the profile sweep found: both check, both yield on the save, both count
    local passed = 0
    for _ = 1, 2 do
        CreateThread(function()
            local t = links:reserve('cid', 2, 1)
            if not t then return end
            Wait(100) -- the save
            links:commit(t)
            passed = passed + 1
        end)
    end
    H.advance(300, 50)
    H.eq(passed, 1, 'two requests at once with one link left: one passes')
    H.eq(links:used('cid'), 2, 'the cap is reached, not passed')
    -- a new day starts at 0; yesterday's reservation counts for nothing
    local old = links:reserve('cid2', 5, 2)
    day = 2
    H.eq(links:used('cid'), 0, 'a new day starts at 0')
    links:commit(old)
    H.eq(links:used('cid2'), 0, 'yesterday\'s reservation does not count today')
    links:add('cid', 2)
    H.eq(links:left('cid', 3), 1, 'add counts without a reservation')
    links:clear('cid')
    H.eq(links:used('cid'), 0, 'clear forgets one key')
    H.eq(links:reserve('cid', 0, 1), nil, 'a cap of 0 lets nothing through')
end

-- ============================================================================
--               FIN3: THE PROGRESS ENGINE AND THE SMALL HELPERS
-- ============================================================================

do
    local P = CP.Progress
    H.eq(P.counted('r.'), 'r.state = \'completed\' AND r.mission_type NOT IN (\'manual_award\', \'goal\')',
        'a counted run: completed, never a point award or goal reward row')
    local sql, params = P.where({ type = 'tactical', unit = true }, 'r.')
    H.ok(sql:find('r.mission_type = ?', 1, true) and sql:find('r.participants >= 2', 1, true), 'type and unit parts')
    H.eq(params[1], 'tactical', 'the mission type is a ? value, never in the SQL text')
    local sum, sp = P.sum({ stat = 'arrests', crossDepartment = true }, 'r.')
    H.ok(sum:find('THEN r.arrests ELSE 0', 1, true) and sum:find('r.departments_n >= 2', 1, true),
        'a stat condition sums its column over the matching runs')
    H.eq(#sp, 0, 'no values for a stat and a flag')
    H.eq((P.sum({ stat = 'final_points; DROP' })), nil, 'a stat that is not a service-record column: nothing')
    H.eq(P.value({}), '1', 'no stat: each run counts 1')
    local call = P.where({ missionCall = true, mission = 'm1' })
    H.ok(call:find('mission_call_id IS NOT NULL', 1, true) and call:find('mission_id = ?', 1, true),
        'mission call and one mission, without an alias')
end

H.eq(CP.Num0('x'), 0, 'Num0: not a number is 0')
H.eq(CP.Num0('2.5'), 2.5, 'Num0: a numeric string')
H.eq(CP.Int('7.9'), 7, 'Int: rounded down')
H.eq(math.type(CP.Int(3.0)), 'integer', 'Int: an integer')
Config.FinThreeTest = { off = false }
H.eq(CP.Cfg('FinThreeTest', 'off', true), false, 'Cfg: a switch set to false reads false')
H.eq(CP.Cfg('FinThreeTest', 'missing', 5), 5, 'Cfg: left out is the default')
H.eq(CP.Cfg('NoSuchSection', 'k', 'd'), 'd', 'Cfg: a missing section is the default')
Config.FinThreeTest = nil
H.eq(CP.NonEmpty('  a b  '), 'a b', 'NonEmpty: trimmed')
H.eq(CP.NonEmpty('   '), nil, 'NonEmpty: only spaces is nil')
H.eq(CP.cidOf(' ABC123 '), 'ABC123', 'cidOf: a trimmed citizenid')
H.eq(CP.cidOf('a b'), nil, 'cidOf: a space inside is no citizenid')
H.eq(CP.cidOf(('x'):rep(51)), nil, 'cidOf: longer than 50 is no citizenid')
H.eq(CP.SqlTs(0), os.date('%Y-%m-%d %H:%M:%S', 0), 'SqlTs: server local DATETIME text')
do
    local lines, realWarn = 0, CP.warn
    CP.warn = function() lines = lines + 1 end
    H.eq(CP.warnOnce('t', 'k', 'x'), true, 'warnOnce: the first one prints')
    H.eq(CP.warnOnce('t', 'k', 'x'), false, 'warnOnce: the same key again does not')
    H.eq(CP.warnOnce('t', 'k2', 'x'), true, 'warnOnce: another key prints')
    CP.warn = realWarn
    H.eq(lines, 2, 'two lines in all')
    local savedS = CP.Schedule
    CP.Schedule = {
        now = function() return 1234 end,
    }
    H.eq(CP.now(), 1234, 'now: CP.Schedule.now when it is there (tests move its clock)')
    CP.Schedule = savedS
end
do
    local savedQ, savedA = CP.Qbx, CP.Access
    CP.Qbx = {
        getByCitizenId = function(cid) return cid == 'ON1' and 5 or nil end,
        getInfo = function() return { job = { name = 'police' } } end,
    }
    CP.Access = {
        departmentForJob = function(job) return job == 'police' and 'sast' or nil end,
    }
    H.eq(CP.deptOfCitizen('ON1'), 'sast', 'deptOfCitizen: the online job department')
    H.eq(CP.deptOfCitizen('OFF1', { department = 'fib' }), 'fib', 'deptOfCitizen: offline, the officer row given')
    H.eq(CP.deptOfCitizen('OFF1', { department = '' }), nil, 'deptOfCitizen: an empty department is none')
    CP.Qbx, CP.Access = savedQ, savedA
end

return H

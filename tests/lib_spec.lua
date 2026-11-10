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

return H

-- CP.Net.request on the client never raises: an ox_lib raise or a server that never answers is an error reply. Logo
-- pieces are paced under FXServer's limits. On the server CP.Net.rateOk is a token bucket, and
-- Config.Limits.netRateResponse picks what a flood gets: block, log or kick.

local H = dofile('tests/harness.lua')
H.boot({ side = 'client' })

local realAwait = lib.callback.await

-- ox_lib rejects its promise on cb_invalid (and after ox:callbackTimeout), and Citizen.Await raises it
lib.callback.await = function(name) error(('callback \'%s\' does not exist'):format(name), 2) end
local okCall, res = pcall(CP.Net.request, 'getSession', { ui = 'officer' })
H.ok(okCall, 'a raising ox_lib callback does not raise')
H.eq(type(res) == 'table' and res.ok, false, 'a raising ox_lib callback: not ok')
H.eq(type(res) == 'table' and res.error, 'err.no_response', 'a raising ox_lib callback: err.no_response')

-- a server that never answers: the request gives up after its own timeout, not ox_lib's 300 s
lib.callback.await = function() while true do Wait(1000) end end
local late
CreateThread(function() late = CP.Net.request('getMissionDefs') end)
H.advance(10000)
H.eq(late, nil, 'still waiting after 10 s')
H.advance(6000)
H.eq(type(late) == 'table' and late.error, 'err.timeout', 'no answer: err.timeout after 15 s')

-- a normal answer and a non-table answer are unchanged
lib.callback.await = function(_, _, args) return { ok = true, data = args } end
local good = CP.Net.request('getBoard', { period = 'weekly' })
H.eq(good.ok, true, 'an answer is returned')
H.eq(good.data.period, 'weekly', 'the answer data')
lib.callback.await = function() return nil end
H.eq(CP.Net.request('getBoard').error, 'err.no_response', 'no table: err.no_response')

-- ============================================================================
--                    LATENT REPLIES (THE BIG ADMIN EXPORTS)
-- ============================================================================
-- opts.latent sends a reply id with the callback; an answer { latent = id } means the data comes as a latent
-- actionResult (the server's TriggerLatentClientEvent), waited for up to 60 s past the 15 s request timeout.
do
    local RESULT = 'crimson-police:client:actionResult'
    local function Deliver(id, data)
        for _, fn in ipairs(H.handlers[RESULT] or {}) do fn(id, true, data) end
    end
    local sentId
    lib.callback.await = function(_, _, _, id)
        sentId = id
        return { ok = true, latent = id }
    end
    local big = { csv = string.rep('1,2026-10-26 12:00:00,admin,x\n', 5000), rows = 5000 }
    local got
    CreateThread(function() got = CP.Net.request('admin:exportPayments', { department = 'fib' }, { latent = true }) end)
    H.advance(100)
    H.ok(type(sentId) == 'string', 'latent: the request sends a reply id: ' .. tostring(sentId))
    H.advance(20000)
    H.eq(got, nil, 'latent: still waiting for the data past the 15 s request timeout')
    Deliver(sentId, big)
    H.advance(100)
    H.eq(got and got.ok, true, 'latent: the request resolves')
    H.eq(got and got.data, big, 'latent: with the full data of the latent event')

    -- the data never comes: err.timeout 60 s after the answer, and a late one is ignored
    got = nil
    CreateThread(function() got = CP.Net.request('admin:exportAudit', {}, { latent = true }) end)
    H.advance(59000)
    H.eq(got, nil, 'latent: no data yet after 59 s')
    H.advance(2000)
    H.eq(got and got.error, 'err.timeout', 'latent: no latent event: err.timeout')
    Deliver(sentId, big)

    -- a plain answer to a latent request is returned as it is; without opts.latent no reply id is sent
    lib.callback.await = function(_, _, _, id)
        sentId = id
        return { ok = true, data = { n = 1 } }
    end
    H.eq(CP.Net.request('getBoard', {}, { latent = true }).data.n, 1, 'latent: a plain answer is returned')
    CP.Net.request('getBoard', {})
    H.eq(sentId, nil, 'no opts.latent: no reply id')
end

lib.callback.await = realAwait

-- ============================================================================
--                                 LOGO PIECES
-- ============================================================================
-- FXSERVER DROPS A PLAYER WHO SENDS OVER 128 KB A SECOND.
-- The harness's TriggerServerEvent goes through FXServer's per-player limits (netEventSize 128 KB/s, burst 384 KB). The
-- stand-in server answers every event that arrives after a 20 ms round trip (an admin on a LAN or the same PC).

do
    local RESULT = 'crimson-police:client:actionResult'
    local send = _G.TriggerServerEvent
    local sentAt = {}
    _G.TriggerServerEvent = function(name, payload, reqId)
        local before = #H.events
        send(name, payload, reqId)
        if #H.events == before then
            return
        end -- dropped by FXServer: no answer ever comes
        sentAt[#sentAt + 1] = H.clockMs
        SetTimeout(20, function()
            for _, fn in ipairs(H.handlers[RESULT] or {}) do fn(reqId, true, { received = payload.index }) end
        end)
    end
    local piece = string.rep('A', 16384)   -- one piece of the NUI: 16384 base64 characters
    local function Upload(n)
        sentAt = {}
        local results = {}
        CreateThread(function()
            for i = 1, n do
                local res = CP.Net.action('server:admin:uploadLogo', {
                    department = 'sast',
                    uploadId = '6f1c2a9e-1b7d-4c3a-9e2f-0a1b2c3d4e5f',
                    index = i,
                    total = n,
                    data = piece,
                })
                results[#results + 1] = res
                if not res.ok then break end
            end
        end)
        H.advance(n * 400 + 20000, 10)
        return results
    end

    -- the harness emulation itself: a piece is 16.5 KB as in the real CfxLua (16514 B measured)
    local size = #'crimson-police:server:admin:uploadLogo'
        + H._packSize({
            {
                department = 'sast',
                uploadId = '6f1c2a9e-1b7d-4c3a-9e2f-0a1b2c3d4e5f',
                index = 1,
                total = 64,
                data = piece,
            },
            'r1',
        })
    H.ok(size > 16450 and size < 16600, 'one piece is about 16.5 KB on the wire: ' .. size)

    -- sent back to back (no gap), a 1 MB logo gets the admin dropped part way
    Config.AdminControl.logoChunkGapMs = 0
    local fast = Upload(64)
    H.eq(H.netDrop, 'Reliable network event size overflow: crimson-police:server:admin:uploadLogo',
        'back to back: FXServer drops the admin')
    H.ok(#fast < 64 and fast[#fast].error == 'err.timeout', 'and the upload stops part way: ' .. #fast)
    H.resetNetLimits()

    -- Config.AdminControl.logoChunkGapMs (250 by default): one piece every 250 ms, half of what FXServer allows
    Config.AdminControl.logoChunkGapMs = 250
    local paced = Upload(64)
    H.eq(H.netDrop, nil, 'paced: the admin stays on the server')
    H.eq(#paced, 64, 'every piece is sent')
    local allOk = true
    for _, r in ipairs(paced) do allOk = allOk and r.ok == true end
    H.ok(allOk, 'and answered')
    local minGap = math.huge
    for i = 2, #sentAt do minGap = math.min(minGap, sentAt[i] - sentAt[i - 1]) end
    H.ok(minGap >= 250, 'one piece every 250 ms or more: ' .. tostring(minGap))
    H.ok(sentAt[#sentAt] - sentAt[1] < 64 * 300, 'a 1 MB logo takes about 16-20 s')

    -- other actions are never paced
    local t0 = H.clockMs
    local other
    CreateThread(function() other = CP.Net.action('server:admin:saveDepartment', { key = 'sast' }) end)
    H.advance(100, 10)
    H.ok(other and other.ok and sentAt[#sentAt] - t0 < 20, 'another action goes at once')
    _G.TriggerServerEvent = send
end

-- ============================================================================
--                     SERVER: RATE LIMITS (TOKEN BUCKETS)
-- ============================================================================
-- CP.Net.rateOk is a token bucket per player and key: `max` at once, then one back every windowMs / max. A fixed
-- window let 2 x max through across its edge. Config.Limits.netRateResponse says what a flood past the limit gets.

H.handlers, H.callbacks, H.commands, H.events = {}, {}, {}, {}
CP, Config = nil, nil
H.boot({ side = 'server' })

local function Calls(src, key, n, max, windowMs)
    local passed = 0
    for _ = 1, n do
        if CP.Net.rateOk(src, key, max, windowMs) then passed = passed + 1 end
    end
    return passed
end

-- (a) max calls just before a window edge and max just after: the second batch is refused
H.eq(Calls(1, 'edge', 1, 8, 1000), 1, 'edge: the first call opens the old window')
H.step(990)
H.eq(Calls(1, 'edge', 7, 8, 1000), 7, 'edge: the rest of the limit just before the edge')
H.step(10)   -- 1000 ms after the first call: a fixed window started a new one here
local afterEdge = Calls(1, 'edge', 8, 8, 1000)
H.ok(afterEdge <= 1, 'edge: max more just after the edge are refused (passed ' .. afterEdge .. ' of 8)')

-- (b) after windowMs the full capacity is back, and no more
H.step(1000)
H.eq(Calls(1, 'edge', 9, 8, 1000), 8, 'a whole window later: max calls again, and the next is refused')

-- one-shot limits keep their meaning: one call, then one again only once the whole window has passed
H.eq(Calls(2, 'oneshot', 2, 1, 5000), 1, 'one-shot: the first call only')
H.step(4999)
H.eq(Calls(2, 'oneshot', 1, 1, 5000), 0, 'one-shot: refused 1 ms before the window ends')
H.step(1)
H.eq(Calls(2, 'oneshot', 1, 1, 5000), 1, 'one-shot: allowed once the window has passed')
-- refused tries in between do not cost anything, and thirds of a window add up to exactly one call
H.eq(Calls(2, 'thirds', 1, 1, 3000), 1, 'thirds: the first call')
for _ = 1, 2 do
    H.step(1000)
    H.eq(Calls(2, 'thirds', 1, 1, 3000), 0, 'thirds: refused before the window has passed')
end
H.step(1000)
H.eq(Calls(2, 'thirds', 1, 1, 3000), 1, 'thirds: allowed after three thirds')

-- a player who leaves loses his buckets
H.eq(Calls(3, 'drop', 9, 8, 1000), 8, 'drop: the limit is used up')
H.fire('playerDropped', 3, 'Exiting')
H.eq(Calls(3, 'drop', 8, 8, 1000), 8, 'drop: a new player in the same slot starts full')

-- (c) the response to a flood: an action (8 a second) and a callback (6 a second) sent far past their limits
CP.Net.action('server:test:flood', function() return true end)
CP.Net.callback('testFlood', function() return {} end)
local ACTION = 'crimson-police:server:test:flood'
local CALLBACK = 'crimson-police:testFlood'
local warned = {}
local realWarn = CP.warn
CP.warn = function(tag, fmt, ...)
    if tag == 'net' then warned[#warned + 1] = fmt:format(...) end
    return realWarn(tag, fmt, ...)
end
local function Flood(src, n)
    H.events = {}
    for i = 1, n do H.fire(ACTION, src, {}, 'f' .. i) end
    local refused = 0
    for _, e in ipairs(H.findEvents('crimson-police:client:actionResult')) do
        if e.args[3] == 'err.rate_limited' then refused = refused + 1 end
    end
    return refused
end

-- 'block' (shipped): refused quietly, as before; no warning, no kick
H.eq(Config.Limits.netRateResponse, 'block', 'shipped: block')
H.eq(Flood(10, 108), 100, 'block: everything past 8 is refused')
H.eq(#warned, 0, 'block: no console warning')
H.eq(#H.dropped, 0, 'block: nobody is dropped')

-- 'log': one warning once one name is refused 3 x its limit (24) in a minute, then none for a minute
Config.Limits.netRateResponse = 'log'
H.step(2000)
Flood(11, 8 + 23)
H.eq(#warned, 0, 'log: 23 refusals: no warning yet')
Flood(11, 1)
H.eq(#warned, 1, 'log: the 24th refusal gives one warning')
H.ok(warned[1] and warned[1]:find('player 11 sent ' .. ACTION .. ' 24 times past its limit', 1, true) ~= nil,
    'log: the warning names the player, the request and the count: ' .. tostring(warned[1]))
H.step(30000)
Flood(11, 100)
H.eq(#warned, 1, 'log: no second warning within the minute')
H.step(30000)
Flood(11, 100)
H.eq(#warned, 2, 'log: still flooding a minute later: one more warning')
H.eq(#H.dropped, 0, 'log: nobody is dropped')

-- 'kick': the warning, and the player is dropped (callbacks too)
Config.Limits.netRateResponse = 'kick'
warned = {}
for _ = 1, 6 + 17 do H.callback(CALLBACK, 12) end
H.eq(#H.dropped, 0, 'kick: 17 refused callbacks: not yet')
local last = H.callback(CALLBACK, 12)
H.eq(last and last.error, 'err.rate_limited', 'kick: the callback is still refused')
H.eq(#H.dropped, 1, 'kick: the 18th refusal (3 x 6) drops the player')
H.eq(H.dropped[1] and H.dropped[1].src, 12, 'kick: that player')
H.eq(H.dropped[1] and H.dropped[1].reason, CP.L('err.rate_kick'), 'kick: with the err.rate_kick text')
H.eq(#warned, 1, 'kick: and one console warning')
for _ = 1, 20 do H.callback(CALLBACK, 12) end
H.eq(#H.dropped, 1, 'kick: DropPlayer is called once')
CP.warn = realWarn
Config.Limits.netRateResponse = 'block'

-- ============================================================================
--                     SERVER: LATENT REPLIES (BIG EXPORTS)
-- ============================================================================
-- ox_lib answers a callback with one reliable event, which holds back the admin's other events until it is through.
-- A callback with opts.latent sends its data with TriggerLatentClientEvent when the client sent a reply id.

do
    local big = { csv = string.rep('1,2026-10-26 12:00:00,admin,x\n', 5000), rows = 5000 }
    CP.Net.callback('testExport', function() return big end, { latent = true, rate = 100 })
    local reply, sent = H.callbackLatent('crimson-police:testExport', 5, {}, 'r7')
    H.ok(reply and reply.ok == true and reply.latent == 'r7' and reply.data == nil,
        'latent: the callback answers { ok = true, latent = id } only')
    local e = sent[1]
    H.ok(#sent == 1 and e.name == 'crimson-police:client:actionResult' and e.target == 5,
        'latent: one latent actionResult to that player')
    H.eq(e and e.bps, 200000, 'latent: at Config.Limits.exportBps')
    H.ok(e and e.args[1] == 'r7' and e.args[2] == true and e.args[3] == big, 'latent: reply id, ok, the full data')

    reply, sent = H.callbackLatent('crimson-police:testExport', 5, {}, nil)
    H.ok(reply.data == big and #sent == 0 and reply.latent == nil, 'no reply id: one plain answer, as before')
    reply, sent = H.callbackLatent('crimson-police:testExport', 5, {}, { 'r8' })
    H.ok(reply.data == big and #sent == 0, 'a reply id that is not a string or number: a plain answer')
    Config.Limits.exportBps = 50000
    reply, sent = H.callbackLatent('crimson-police:testExport', 5, {}, 'r9')
    H.eq(sent[1] and sent[1].bps, 100000, 'exportBps below 100000 counts as 100000')
    Config.Limits.exportBps = 0
    reply, sent = H.callbackLatent('crimson-police:testExport', 5, {}, 'r10')
    H.ok(reply.data == big and #sent == 0, 'exportBps = 0: one plain answer, as before')
    Config.Limits.exportBps = 200000

    CP.Net.callback('testSmall', function() return { n = 1 } end, { rate = 100 })
    reply, sent = H.callbackLatent('crimson-police:testSmall', 5, {}, 'r11')
    H.ok(reply.data.n == 1 and #sent == 0, 'a callback without opts.latent ignores a reply id')
    CP.Net.callback('testRefused', function() return nil, 'err.no_permission' end, { latent = true, rate = 100 })
    reply, sent = H.callbackLatent('crimson-police:testRefused', 5, {}, 'r12')
    H.ok(reply.ok == false and reply.error == 'err.no_permission' and #sent == 0, 'a refusal is a plain answer')
end

return H

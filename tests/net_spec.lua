-- CP.Net.request on the client never raises: an ox_lib raise or a server that never answers is an error reply.

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

return H

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

return H

-- The request/action plumbing between the NUI, the client and the server.

CP = CP or {}
CP.Net = CP.Net or {}

local RESULT_EVENT = 'crimson-police:client:actionResult'

if IsDuplicityVersion() then
    -- ---- SERVER ------------------------------------------------------------
    local buckets = {}   -- buckets[src][key] = { n, resetAt }

    -- At most `max` calls per `windowMs` for (src, key). Returns true when allowed.
    function CP.Net.rateOk(src, key, max, windowMs)
        max = max or 10
        windowMs = windowMs or 1000
        local now = GetGameTimer()
        local bySrc = buckets[src]
        if not bySrc then bySrc = {}; buckets[src] = bySrc end
        local b = bySrc[key]
        if not b or now >= b.resetAt then
            bySrc[key] = { n = 1, resetAt = now + windowMs }
            return true
        end
        b.n = b.n + 1
        return b.n <= max
    end

    AddEventHandler('playerDropped', function()
        buckets[source] = nil
    end)

    local function Reply(src, reqId, ok, data)
        if reqId ~= nil and src and src > 0 then
            TriggerClientEvent(RESULT_EVENT, src, reqId, ok == true, data)
        end
    end

    -- While CP.Maintenance holds a lock (a storage copy or switch, a backup restore, a store left behind), every
    -- action is refused except the few that keep the admins informed or end the lock (opts.maintenance = true).
    -- Callbacks (reads) keep working.
    local function MaintenanceRefusal(opts)
        if opts and opts.maintenance == true then return nil end
        if not (CP.Maintenance and CP.Maintenance.active) then return nil end
        local ok, kind = pcall(CP.Maintenance.active)
        if not ok or not kind then return nil end
        return 'err.maintenance'
    end
    CP.Net._maintenanceRefusal = MaintenanceRefusal

    -- opts: { rate = max calls per second (default 8), maintenance = true: allowed during a maintenance lock }
    function CP.Net.action(name, handler, opts)
        local eventName = 'crimson-police:' .. name
        local max = (opts and opts.rate) or 8
        RegisterNetEvent(eventName, function(payload, reqId)
            local src = source
            if type(reqId) ~= 'string' and type(reqId) ~= 'number' then reqId = nil end
            if not CP.Net.rateOk(src, eventName, max, 1000) then
                return Reply(src, reqId, false, 'err.rate_limited')
            end
            local locked = MaintenanceRefusal(opts)
            if locked then return Reply(src, reqId, false, locked) end
            local okCall, ok, data = pcall(handler, src, payload)
            if not okCall then
                CP.err('net', '%s failed: %s', eventName, tostring(ok))
                return Reply(src, reqId, false, 'err.internal')
            end
            if ok then
                Reply(src, reqId, true, data)
            else
                Reply(src, reqId, false, data or 'err.refused')
            end
        end)
    end

    -- opts: { rate = max calls per second (default 6) }
    function CP.Net.callback(name, handler, opts)
        local cbName = 'crimson-police:' .. name
        local max = (opts and opts.rate) or 6
        lib.callback.register(cbName, function(src, args)
            if not CP.Net.rateOk(src, cbName, max, 1000) then
                return { ok = false, error = 'err.rate_limited' }
            end
            local okCall, data, errKey = pcall(handler, src, args)
            if not okCall then
                CP.err('net', '%s failed: %s', cbName, tostring(data))
                return { ok = false, error = 'err.internal' }
            end
            if data == nil and errKey then
                return { ok = false, error = errKey }
            end
            return { ok = true, data = data }
        end)
    end
else
    -- ---- CLIENT ------------------------------------------------------------
    local pending, nextId = {}, 0

    RegisterNetEvent(RESULT_EVENT, function(reqId, ok, data)
        local p = pending[reqId]
        if not p then return end
        pending[reqId] = nil
        if ok then
            p:resolve({ ok = true, data = data })
        else
            p:resolve({ ok = false, error = data or 'err.refused' })
        end
    end)

    -- Trigger 'crimson-police:<name>' with (payload, reqId) and wait for the reply.
    function CP.Net.action(name, payload, timeoutMs)
        nextId = nextId + 1
        local reqId = ('r%d'):format(nextId)
        local p = promise.new()
        pending[reqId] = p
        TriggerServerEvent('crimson-police:' .. name, payload, reqId)
        SetTimeout(timeoutMs or 15000, function()
            if pending[reqId] then
                pending[reqId] = nil
                p:resolve({ ok = false, error = 'err.timeout' })
            end
        end)
        return Citizen.Await(p)
    end

    -- Call the ox_lib callback 'crimson-police:<name>' and wait for { ok, data, error }. Never raises: ox_lib
    -- raises on an unknown callback and after its own 300 s timeout, so the call runs in a thread of its own
    -- and a request with no answer in time gives err.timeout.
    function CP.Net.request(name, args, timeoutMs)
        local p, done = promise.new(), false
        local function finish(res)
            if done then return end
            done = true
            p:resolve(res)
        end
        CreateThread(function()
            local ok, res = pcall(lib.callback.await, 'crimson-police:' .. name, false, args)
            if not ok then
                CP.warn('net', '%s failed: %s', name, tostring(res))
                res = nil
            end
            if type(res) ~= 'table' then res = { ok = false, error = 'err.no_response' } end
            finish(res)
        end)
        SetTimeout(timeoutMs or 15000, function() finish({ ok = false, error = 'err.timeout' }) end)
        return Citizen.Await(p)
    end
end

-- The request/action plumbing between the NUI, the client and the server.

CP = CP or {}
CP.Net = CP.Net or {}
-- Who netRateResponse never warns about or drops; modules/access/server.lua sets it to CP.Access.isAdmin
function CP.Net.rateExempt(_) return false end

local RESULT_EVENT = 'crimson-police:client:actionResult'

if IsDuplicityVersion() then
    -- ---- SERVER ------------------------------------------------------------
    local buckets = {}   -- buckets[src][key] = { level, at }: one token bucket per player and key

    -- A token bucket per (src, key): up to `max` calls at once, then one call back every windowMs / max, so a burst
    -- just before and just after a whole window no longer gets 2 x max through. Returns true when allowed. A new key
    -- starts full. The level is kept in token x windowMs units (one call costs windowMs, a millisecond refills max),
    -- so it stays a whole number and a wait of exactly windowMs gives exactly `max` calls back.
    function CP.Net.rateOk(src, key, max, windowMs)
        max = max or 10
        windowMs = windowMs or 1000
        local now = GetGameTimer()
        local bySrc = buckets[src]
        if not bySrc then bySrc = {}; buckets[src] = bySrc end
        local full = max * windowMs
        local b = bySrc[key]
        if not b then
            b = { level = full, at = now }
            bySrc[key] = b
        else
            b.level = math.min(full, b.level + (now - b.at) * max)
            b.at = now
        end
        if b.level < windowMs then return false end
        b.level = b.level - windowMs
        return true
    end

    -- Config.Limits.netRateResponse 'log' or 'kick': refusals per player and name over the last minute.
    -- refused[src] = { warnedAt = GetGameTimer() of the last warning, kicked = true, names = { [name] = { n, at } } }
    local REFUSAL_WINDOW_MS = 60000
    local REFUSALS_PER_MAX = 3   -- the response starts once one name is refused 3 x its limit in a minute
    local REFUSALS_MIN = 20      -- and never below 20, so a few quick clicks on a rate-1 request are not a flood
    local refused = {}

    local function OnRefused(src, name, max)
        local mode = Config.Limits and Config.Limits.netRateResponse
        if mode ~= 'log' and mode ~= 'kick' then
            return
        end -- 'block' (shipped): refuse quietly, nothing kept
        -- admins are never logged or kicked for it (a slow Admin UI download clicked a few times is not a flood)
        if CP.Net.rateExempt(src) then return end
        local now = GetGameTimer()
        local r = refused[src]
        if not r then r = { names = {} }; refused[src] = r end
        local c = r.names[name]
        if not c or now - c.at >= REFUSAL_WINDOW_MS then
            c = { n = 0, at = now }
            r.names[name] = c
        end
        c.n = c.n + 1
        if c.n < math.max(REFUSALS_PER_MAX * max, REFUSALS_MIN) then return end
        local kick = mode == 'kick' and not r.kicked
        if kick or not r.warnedAt or now - r.warnedAt >= REFUSAL_WINDOW_MS then
            r.warnedAt = now
            CP.warn('net', 'player %d sent %s %d times past its limit%s', src, name, c.n,
                kick and ' (dropped: Config.Limits.netRateResponse = kick)' or '')
        end
        if kick then
            r.kicked = true
            DropPlayer(src, CP.L('err.rate_kick'))
        end
    end

    AddEventHandler('playerDropped', function()
        buckets[source] = nil
        refused[source] = nil
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

    -- A start that failed (CP.Migrations.failed(): a migration, a damaged saves folder, a store that cannot start):
    -- every action and callback answers err.not_started at once, before its handler runs, so nothing waits for a
    -- store that will never be ready and nothing reads or writes a half-upgraded one. FXServer keeps the resource
    -- started (it refuses a resource's StopResource on itself).
    local NOT_STARTED = 'err.not_started'
    local function NotStarted()
        local M = CP.Migrations
        if M and M.failed and M.failed() then return NOT_STARTED end
        return nil
    end
    CP.Net._notStarted = NotStarted

    -- opts: { rate = max calls per second (default 8), maintenance = true: allowed during a maintenance lock }
    function CP.Net.action(name, handler, opts)
        local eventName = 'crimson-police:' .. name
        local max = (opts and opts.rate) or 8
        RegisterNetEvent(eventName, function(payload, reqId)
            local src = source
            if type(reqId) ~= 'string' and type(reqId) ~= 'number' then reqId = nil end
            if not CP.Net.rateOk(src, eventName, max, 1000) then
                OnRefused(src, eventName, max)
                return Reply(src, reqId, false, 'err.rate_limited')
            end
            local down = NotStarted()
            if down then return Reply(src, reqId, false, down) end
            local locked = MaintenanceRefusal(opts)
            if locked then return Reply(src, reqId, false, locked) end
            local okCall, ok, data = pcall(handler, src, payload)
            if not okCall then
                -- the start failed while this request waited for it (CP.Migrations.ready raised)
                if ok == NOT_STARTED then return Reply(src, reqId, false, NOT_STARTED) end
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

    -- Config.Limits.exportBps: bytes a second for a latent reply, or nil to answer in one reliable message.
    local LATENT_MIN_BPS = 100000
    local function LatentBps()
        local bps = tonumber(Config.Limits and Config.Limits.exportBps) or 0
        if bps <= 0 then return nil end
        return math.max(LATENT_MIN_BPS, math.floor(bps))
    end

    -- opts: { rate = max calls per second (default 6), latent = true: a big reply (an export of up to 5000 rows) }
    -- handler(src, args) -> data | nil, errKey, details: a details table goes back with the error as its data (for
    -- example the line a pasted mission file is refused at).
    -- latent: ox_lib answers a callback with one reliable event, which holds back the player's other events until
    -- it is through. When the client sent a reply id (CP.Net.request opts.latent), the data goes as a latent
    -- RESULT_EVENT (reqId, true, data) at Config.Limits.exportBps, and the callback answers { ok = true, latent = id }.
    function CP.Net.callback(name, handler, opts)
        local cbName = 'crimson-police:' .. name
        local max = (opts and opts.rate) or 6
        local latent = opts and opts.latent == true
        lib.callback.register(cbName, function(src, args, replyId)
            if not CP.Net.rateOk(src, cbName, max, 1000) then
                OnRefused(src, cbName, max)
                return { ok = false, error = 'err.rate_limited' }
            end
            local down = NotStarted()
            if down then return { ok = false, error = down } end
            local okCall, data, errKey, details = pcall(handler, src, args)
            if not okCall then
                if data == NOT_STARTED then return { ok = false, error = NOT_STARTED } end
                CP.err('net', '%s failed: %s', cbName, tostring(data))
                return { ok = false, error = 'err.internal' }
            end
            if data == nil and errKey then
                return { ok = false, error = errKey, data = type(details) == 'table' and details or nil }
            end
            if latent and (type(replyId) == 'string' or type(replyId) == 'number') and src and src > 0 then
                local bps = LatentBps()
                if bps then
                    TriggerLatentClientEvent(RESULT_EVENT, src, bps, replyId, true, data)
                    return { ok = true, latent = replyId }
                end
            end
            return { ok = true, data = data }
        end)
    end
else
    -- ---- CLIENT ------------------------------------------------------------
    local pending, nextId = {}, 0

    -- Actions with big payloads, sent at most once every N ms (read at each send, so a setting applies at once):
    -- FXServer drops a player whose server events pass 128 KB a second (384 KB burst).
    local PACED = {
        -- Departments → Upload a logo: one 16.5 KB piece per event
        ['server:admin:uploadLogo'] = function() return Config.AdminControl and Config.AdminControl.logoChunkGapMs end,
    }
    local pacedAt = {}   -- name -> GetGameTimer() before which the next send waits

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
        local pace = PACED[name]
        if pace then
            local gap = math.max(0, tonumber(pace()) or 0)
            local now = GetGameTimer()
            local at = math.max(now, pacedAt[name] or 0)
            pacedAt[name] = at + gap
            if at > now then Wait(at - now) end
        end
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

    -- A latent reply (CP.Net.callback opts.latent) comes after the callback's answer: 3 MB at 200 KB a second
    -- takes about 15 s.
    local LATENT_WAIT_MS = 60000

    -- Call the ox_lib callback 'crimson-police:<name>' and wait for { ok, data, error }. Never raises: ox_lib
    -- raises on an unknown callback and after its own 300 s timeout, so the call runs in a thread of its own
    -- and a request with no answer in time gives err.timeout.
    -- opts: the timeout in ms (15 s by default), or { timeoutMs = n, latent = true }. latent: the call sends a reply
    -- id, and when the server answers { latent = id } the data comes as a latent RESULT_EVENT, waited for up to
    -- LATENT_WAIT_MS more.
    function CP.Net.request(name, args, opts)
        if type(opts) ~= 'table' then opts = { timeoutMs = opts } end
        local replyId, latentP
        if opts.latent then
            nextId = nextId + 1
            replyId = ('r%d'):format(nextId)
            latentP = promise.new()
            pending[replyId] = latentP
        end
        local p, done = promise.new(), false
        local function finish(res)
            if done then return end
            done = true
            p:resolve(res)
        end
        CreateThread(function()
            local ok, res = pcall(lib.callback.await, 'crimson-police:' .. name, false, args, replyId)
            if not ok then
                CP.warn('net', '%s failed: %s', name, tostring(res))
                res = nil
            end
            if type(res) ~= 'table' then res = { ok = false, error = 'err.no_response' } end
            finish(res)
        end)
        SetTimeout(tonumber(opts.timeoutMs) or 15000, function() finish({ ok = false, error = 'err.timeout' }) end)
        local res = Citizen.Await(p)
        if not replyId then return res end
        if not (res.ok and res.latent == replyId) then
            pending[replyId] = nil
            return res
        end
        -- the data may already be here (pending[replyId] is then gone and latentP resolved)
        SetTimeout(LATENT_WAIT_MS, function()
            if pending[replyId] == latentP then
                pending[replyId] = nil
                latentP:resolve({ ok = false, error = 'err.timeout' })
            end
        end)
        return Citizen.Await(latentP)
    end
end

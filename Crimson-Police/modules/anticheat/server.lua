-- CP.AntiCheat (server): objective-event checks, run flags, outside help, presence sampling, the idle check and the
-- voids -> suspension rule.

CP.AntiCheat = CP.AntiCheat or {}
local AC = CP.AntiCheat
local U = CP.U
local TAG = 'anticheat'

local EVENT_RATE = 10            -- objective events per src per second
local DUP_WINDOW_MS = 1000       -- identical evidence within this window is a duplicate
local MIN_SPEED_DT = 1.0         -- seconds: the speed check never divides by less
local PRESENCE_EVERY_MS = 5000
local SIGNATURE_MAX = 512

local state = {}                 -- runId -> { idleDone, kills, killers = { [src] = { name, n } }, recorded = { [key] = true }, recent = { [src] = { [sig] = ms } } }
local lastPresenceMs = nil

-- ============================================================================
--                                   HELPERS
-- ============================================================================

-- Clip to at most n characters without cutting a UTF-8 sequence in half, dropping bytes that are not valid
-- UTF-8 first. The cp_* columns are utf8mb4 (VARCHAR(n) counts characters) and MariaDB's strict mode
-- refuses a broken sequence (error 1366), so a byte clip (CP.U.clip) of an accented reason could make
-- the whole insert fail.
local function Clip(s, n)
    if s == nil then return nil end
    s = tostring(s)
    for _ = 1, 64 do
        local len, bad = utf8.len(s)
        if len then break end
        s = s:sub(1, bad - 1) .. s:sub(bad + 1)
    end
    if not utf8.len(s) then s = s:gsub('[\128-\255]', '?') end
    if utf8.len(s) <= n then return s end
    return s:sub(1, utf8.offset(s, n + 1) - 1)
end
local function ToSrc(v)
    local n = tonumber(v)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

local function Has(modName, fnName)
    local m = CP[modName]
    return type(m) == 'table' and type(m[fnName]) == 'function'
end

local function Call(modName, fnName, ...)
    if not Has(modName, fnName) then return false end
    local res = table.pack(pcall(CP[modName][fnName], ...))
    if not res[1] then
        CP.err(TAG, 'CP.%s.%s failed: %s', modName, fnName, tostring(res[2]))
        return false
    end
    return true, table.unpack(res, 2, res.n)
end

local function Num(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n then return default end
    return n
end

local function Cfg()
    return Config.AntiCheat or {}
end

local function StateOf(run)
    local st = state[run.id]
    if not st then
        st = { idleDone = false, kills = 0, killers = {}, recorded = {}, recent = {} }
        state[run.id] = st
    end
    return st
end

local function InArena(src)
    if CP.Alerts and CP.Alerts.inArena then
        local ok, v = pcall(CP.Alerts.inArena, src)
        return ok and v == true
    end
    return false
end

local function BucketOf(src)
    if not GetPlayerRoutingBucket then return 0 end
    local ok, b = pcall(GetPlayerRoutingBucket, src)
    return ok and tonumber(b) or 0
end

local function PedCoords(src)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return nil end
    local c = GetEntityCoords(ped)
    if not c then return nil end
    return c
end

local function ActiveSrcs(run)
    if Has('Runs', 'activeSrcs') then
        local ok, list = Call('Runs', 'activeSrcs', run)
        if ok and type(list) == 'table' then return list end
    end
    local out = {}
    for _, s in ipairs(run.order or {}) do
        local p = run.participants and run.participants[s]
        if p and p.status == 'active' then out[#out + 1] = s end
    end
    return out
end

local function NameOf(src)
    local ok, info = Call('Qbx', 'getInfo', src)
    if ok and type(info) == 'table' and info.name then
        return ('%s [%s]'):format(info.name, tostring(info.citizenid))
    end
    local n = GetPlayerName and GetPlayerName(src)
    return n and ('%s [#%d]'):format(n, src) or ('#' .. tostring(src))
end

-- ============================================================================
--                          EVIDENCE SIGNATURE (pure)
-- ============================================================================

local IGNORED_KEYS = { coords = true, time = true }

local function Encode(v, depth)
    local t = type(v)
    if t == 'table' then
        if depth > 3 then return '{…}' end
        local keys = {}
        for k in pairs(v) do
            if not (depth == 0 and IGNORED_KEYS[k]) then keys[#keys + 1] = k end
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        local parts = {}
        for _, k in ipairs(keys) do parts[#parts + 1] = tostring(k) .. '=' .. Encode(v[k], depth + 1) end
        return '{' .. table.concat(parts, ',') .. '}'
    end
    if t == 'vector3' or t == 'vector4' or t == 'vector2' then
        return ('v(%.1f,%.1f,%.1f)'):format(v.x or 0, v.y or 0, v.z or 0)
    end
    if t == 'number' then
        -- '%d' only takes a value with an integer form: a whole float past 2^63 (1e19) would throw
        local i = math.tointeger(v)
        if i then return ('%d'):format(i) end
        return ('%.3f'):format(v)
    end
    return tostring(v)
end

function AC.evidenceSignature(evidence)
    local s = Encode(type(evidence) == 'table' and evidence or { value = evidence }, 0)
    if #s > SIGNATURE_MAX then s = U.hashHex(s) .. ':' .. #s end
    return s
end

-- ============================================================================
--                                    FLAGS
-- ============================================================================

local function RecordFlag(run, p, reason, detail)
    if not Has('Admin', 'audit') then return end
    local citizenid = p and p.citizenid or nil
    CreateThread(function()
        Call('Admin', 'audit', 'console', 'console', 'flags', 'runFlagged', run.id, citizenid, reason, detail)
    end)
end

function AC.flag(run, src, reason, detail)
    if type(run) ~= 'table' or type(reason) ~= 'string' or reason == '' then return false end
    reason = Clip(reason, 64)
    if detail ~= nil then detail = Clip(tostring(detail), 255) end
    if run.test then
        CP.log(TAG, 'test run %s would be flagged %s (%s)', tostring(run.id), reason, tostring(detail))
        return false
    end
    local p = nil
    if src ~= nil then
        local n = ToSrc(src)
        p = n and run.participants and run.participants[n] or nil
        if not p then return false end
    end
    local st = StateOf(run)
    local key = reason .. '|' .. (p and tostring(p.citizenid) or '*')
    if st.recorded[key] then return false end
    st.recorded[key] = true
    if p then
        if not p.flagged then p.flagged = { reason = reason, detail = detail } end
    else
        if not run.flagged then run.flagged = { reason = reason, detail = detail } end
    end
    CP.warn(TAG, 'run %s (%s) flagged %s%s: %s', tostring(run.id), tostring(run.missionId), reason,
        p and (' for ' .. tostring(p.citizenid)) or '', tostring(detail or ''))
    RecordFlag(run, p, reason, detail)
    return true
end

-- ============================================================================
--                               OBJECTIVE EVENTS
-- ============================================================================

function AC.checkEvent(run, src, index, evidence)
    src = ToSrc(src)
    if type(run) ~= 'table' or not src then return false, 'err.invalid_run' end
    if run.state ~= 'in_progress' then return false, 'err.run_not_active' end
    local p = run.participants and run.participants[src]
    if not p or p.status ~= 'active' then return false, 'err.not_participant' end
    if InArena(src) then
        p.lastEvent = nil
        return false, 'err.in_arena'
    end
    if not CP.Net.rateOk(src, 'anticheat:event', EVENT_RATE, 1000) then return false, 'err.rate_limited' end

    index = math.tointeger(tonumber(index) or -1)
    local current = run.objectiveIndex
    if not index or index < 1 then return false, 'err.invalid_event' end
    if index > (current or 0) then
        AC.flag(run, nil, 'unexpected_event',
            ('objective %d reported by %s while %s is current'):format(index, NameOf(src), tostring(current)))
        return false, 'err.unexpected_event'
    end
    local o = run.objectives and run.objectives[index]
    if index < current or not o or o.status ~= 'active' then return false, 'err.stale_event' end

    local now = GetGameTimer()
    local st = StateOf(run)
    local recent = st.recent[src]
    if not recent then recent = {}; st.recent[src] = recent end
    local sig = index .. '|' .. AC.evidenceSignature(evidence)
    for k, at in pairs(recent) do
        if now - at > DUP_WINDOW_MS then recent[k] = nil end
    end
    if recent[sig] then return false, 'err.duplicate_event' end
    recent[sig] = now

    local coords = PedCoords(src)
    if coords then
        local bucket = BucketOf(src)
        local last = p.lastEvent
        if last and last.coords and (last.bucket == nil or last.bucket == bucket) then
            local dt = math.max(MIN_SPEED_DT, (now - (last.at or now)) / 1000)
            local dist = U.dist(coords, last.coords)
            local speed = dist / dt
            local maxSpeed = Num(Cfg().maxSpeed, 80.0)
            if speed > maxSpeed then
                AC.flag(run, nil, 'speed',
                    ('%s moved %.0f m in %.1f s (%.0f m/s, max %.0f)'):format(NameOf(src), dist, dt, speed, maxSpeed))
            end
        end
        p.lastEvent = { coords = coords, at = now, bucket = bucket }
    end
    return true
end

-- ============================================================================
--                                 OUTSIDE HELP
-- ============================================================================

function AC.onNpcKilled(run, killerSrc)
    local k = ToSrc(killerSrc)
    if type(run) ~= 'table' or not k or run.test or run.state == 'ended' then return end
    local p = run.participants and run.participants[k]
    if p and p.status == 'active' then return end
    -- the crimsonArena flag is client-writable: only a killer in another bucket is really in a match
    if InArena(k) and BucketOf(k) ~= 0 then return end
    local st = StateOf(run)
    st.kills = st.kills + 1
    local entry = st.killers[k]
    if not entry then
        entry = { name = NameOf(k), n = 0 }
        st.killers[k] = entry
    end
    entry.n = entry.n + 1
    local threshold = math.max(1, math.floor(Num(Cfg().outsideKillsToFlag, 1)))
    if st.kills >= threshold then
        local names = {}
        for _, e in pairs(st.killers) do names[#names + 1] = e.n > 1 and ('%s ×%d'):format(e.name, e.n) or e.name end
        table.sort(names)
        AC.flag(run, nil, 'outside_help',
            CP.L('admin.anticheat.outside_detail', { names = table.concat(names, ', '), kills = st.kills }))
    end
end

-- ============================================================================
--                                   PRESENCE
-- ============================================================================
-- The block's presence(ctx, src, coords) gets the engine's own ctx of that objective (CP.Runs.ctx, the table
-- every block hook gets). Without it: a read-only objective context with the same fields and helpers as
-- ARCHITECTURE §7.1 (spawning refused).
local function ReadOnlyCtx(run, i)
    local o = run.objectives and run.objectives[i]
    local base = run.mission and run.mission.objectives and run.mission.objectives[i]
    local ctx = {
        run = run,
        index = i,
        obj = (o and o.obj) or base,
        base = base,
        mission = run.mission,
        location = run.location,
        tier = run.tier,
        state = (o and o.state) or {},
        rng = U.rng((tonumber(run.seed) or 1) + i),
    }
    ctx.participants = function() return ActiveSrcs(run) end
    ctx.coords = function(s) local n = ToSrc(s); return n and PedCoords(n) or nil end
    ctx.isHost = function(s) return ToSrc(s) == run.host end
    ctx.host = function() return run.host end
    ctx.combat = function(acc, armour)
        if Has('Scaling', 'combat') then return CP.Scaling.combat(acc, armour, run.tier, run) end
        return acc, armour
    end
    ctx.complete = function() return false end
    ctx.fail = function() end
    ctx.award = function(id, opts) if Has('Runs', 'award') then return CP.Runs.award(run, id, opts) end end
    ctx.penalize = function(id, opts) if Has('Runs', 'penalize') then return CP.Runs.penalize(run, id, opts) end end
    ctx.send = function() end
    ctx.hud = function() end
    ctx.canSpawn = function() return false end
    ctx.spawnPed = function() return nil end
    ctx.spawnVehicle = function() return nil end
    ctx.spawnObject = function() return nil end
    ctx.delete = function() end
    return ctx
end

local function PresenceCtx(run, i)
    if Has('Runs', 'ctx') then
        local ok, ctx = Call('Runs', 'ctx', run, i)
        if ok and type(ctx) == 'table' then return ctx end
    end
    return ReadOnlyCtx(run, i)
end

local function PresenceRange(obj)
    local r = tonumber(obj and obj.presenceRange)
    if r and r > 0 then return r end
    local blockCfg = obj and obj.block and Config.Blocks and Config.Blocks[obj.block]
    local pr = blockCfg and blockCfg.presenceRange
    if type(pr) == 'table' and tonumber(pr[3]) then return tonumber(pr[3]) end
    return Num(Cfg().presenceRadius, 150.0)
end

-- Distance of src from objective i of run (metres), or nil when it cannot be measured.
local function DistanceFor(run, i, src, coords)
    local o = run.objectives and run.objectives[i]
    local obj = (o and o.obj) or (run.mission and run.mission.objectives and run.mission.objectives[i])
    local impl = obj and obj.block and CP.Blocks.get(obj.block)
    if impl and type(impl.presence) == 'function' then
        local ok, d = pcall(impl.presence, PresenceCtx(run, i), src, coords)
        if ok and tonumber(d) then return tonumber(d), obj end
        if not ok then
            CP.err(TAG, 'presence of %s (run %s) failed: %s', tostring(obj.block), tostring(run.id), tostring(d))
        end
    end
    local start = run.location and run.location.start and run.location.start.coords
    if start then return U.dist(coords, start), obj end
    return nil, obj
end

function AC._sample(intervalS)
    intervalS = intervalS or (PRESENCE_EVERY_MS / 1000)
    if not Has('Runs', 'all') then return end
    local ok, list = Call('Runs', 'all')
    if not ok or type(list) ~= 'table' then return end
    for _, run in ipairs(list) do
        if run.state == 'in_progress' and #(run.order or {}) >= 2 then
            local i = run.objectiveIndex
            local o = i and run.objectives and run.objectives[i]
            if o and o.status == 'active' then
                for _, s in ipairs(ActiveSrcs(run)) do
                    local p = run.participants[s]
                    if p and not InArena(s) then
                        local coords = PedCoords(s)
                        if coords then
                            local d, obj = DistanceFor(run, i, s, coords)
                            if d then
                                p.presence = p.presence or { inRange = 0, total = 0 }
                                p.presence.total = (p.presence.total or 0) + intervalS
                                if d <= PresenceRange(obj) then
                                    p.presence.inRange = (p.presence.inRange or 0) + intervalS
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end

function AC.presenceShare(p)
    local pr = type(p) == 'table' and p.presence or nil
    local total = pr and Num(pr.total, 0) or 0
    if total <= 0 then return nil end
    return Num(pr.inRange, 0) / total
end

function AC.presenceOk(run, p)
    if type(run) ~= 'table' or type(p) ~= 'table' then return true end
    if #(run.order or {}) < 2 then return true end
    local share = AC.presenceShare(p)
    if share == nil then return true end
    local need = Num(Cfg().presenceShare, 0.70)
    if share >= need then return true end
    -- Record why (once per participant) so the Review Queue can show the share.
    if p.src and not run.test then
        AC.flag(run, p.src, 'presence', CP.L('admin.anticheat.presence_detail', {
            share = math.floor(share * 100 + 0.5),
            need = math.floor(need * 100 + 0.5),
        }))
    end
    return false
end

-- ============================================================================
--                        IDLE CHECK AND BUCKET TRACKING
-- ============================================================================

function AC._idleCheck(nowTs)
    if not Has('Runs', 'all') then return end
    nowTs = nowTs or os.time()
    local ok, list = Call('Runs', 'all')
    if not ok or type(list) ~= 'table' then return end
    local after = Num(Cfg().idleCheck, 180)
    for _, run in ipairs(list) do
        if run.state == 'in_progress' and run.startedAt then
            local st = StateOf(run)
            if not st.idleDone and nowTs - run.startedAt >= after then
                st.idleDone = true
                for _, s in ipairs(ActiveSrcs(run)) do
                    local p = run.participants[s]
                    if p and p.status == 'active' and not p.arrived then
                        CP.log(TAG, 'run %s: %d never reached the start: idle', tostring(run.id), s)
                        Call('Runs', 'removeParticipant', run, s, 'idle', { notify = 'admin.anticheat.idle_notice' })
                        if run.state == 'ended' then break end
                    end
                end
            end
        end
    end
end

-- Drop the speed-check position of anyone whose routing bucket changed (or who is in the arena).
function AC._trackBuckets()
    if not Has('Runs', 'all') then return end
    local ok, list = Call('Runs', 'all')
    if not ok or type(list) ~= 'table' then return end
    local live = {}
    for _, run in ipairs(list) do
        live[run.id] = true
        for _, s in ipairs(ActiveSrcs(run)) do
            local p = run.participants[s]
            if p and p.lastEvent then
                local b = BucketOf(s)
                if b ~= 0 or (p.lastEvent.bucket ~= nil and p.lastEvent.bucket ~= b) or InArena(s) then
                    p.lastEvent = nil
                end
            end
        end
    end
    for id in pairs(state) do
        if not live[id] and not (Has('Runs', 'get') and CP.Runs.get(id)) then state[id] = nil end
    end
end

-- ============================================================================
--                             VOIDS -> suspension
-- ============================================================================

-- Only strikes count: an admin's void kind 'correction' (a bug, a retired officer) never suspends anyone.
function AC.onVoided(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return false end
    local c = Cfg()
    local needed = math.floor(Num(c.voidsToSuspend, 3))
    local days = math.floor(Num(c.voidWindowDays, 30))
    local suspendDays = math.floor(Num(c.suspendDays, 7))
    if needed <= 0 or suspendDays <= 0 then return false end
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
    local now = os.time()
    local since = now - days * 86400
    local okL, last = pcall(MySQL.scalar.await,
        'SELECT UNIX_TIMESTAMP(MAX(created_at)) AS ts FROM cp_audit WHERE action = \'autoSuspend\' AND target = ?',
        { citizenid })
    if okL and tonumber(last) and tonumber(last) > since then since = math.floor(tonumber(last)) end
    local okC, n = pcall(MySQL.scalar.await,
        [[SELECT COUNT(*) AS n FROM cp_mission_runs WHERE citizenid = ? AND voided = 1
        AND (void_kind IS NULL OR void_kind = 'strike')
        AND mission_type NOT IN ('manual_award', 'goal') AND created_at >= FROM_UNIXTIME(?)]], { citizenid, since })
    if not okC then
        CP.err(TAG, 'void count for %s failed: %s', citizenid, tostring(n))
        return false
    end
    n = math.floor(Num(n, 0))
    if n < needed then return false end
    if Has('Access', 'isSuspended') then
        local okS, suspended = Call('Access', 'isSuspended', citizenid)
        if okS and suspended then return false end
    end
    local okA, done, e = Call('Access', 'suspend', citizenid, suspendDays, 0, 'auto')
    if not okA or not done then
        CP.err(TAG, 'automatic suspension of %s failed: %s', citizenid, tostring(e))
        return false
    end
    if Has('Admin', 'audit') then
        Call('Admin', 'audit', 'console', 'console', 'audit', 'autoSuspend', citizenid, nil, ('%d'):format(suspendDays),
            CP.L('admin.anticheat.auto_suspend_reason', { count = n, days = days }))
    end
    CP.warn(TAG, '%s suspended for %d days after %d voided runs', citizenid, suspendDays, n)
    return true
end

-- The officer's strikes in the window (the Officers screen shows them).
function AC.strikeCount(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return 0 end
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
    local days = math.floor(Num(Cfg().voidWindowDays, 30))
    local okC, n = pcall(MySQL.scalar.await, [[SELECT COUNT(*) AS n FROM cp_mission_runs WHERE citizenid = ?
        AND voided = 1 AND (void_kind IS NULL OR void_kind = 'strike') AND mission_type NOT IN ('manual_award', 'goal')
        AND created_at >= FROM_UNIXTIME(?)]], { citizenid, os.time() - days * 86400 })
    return okC and math.floor(Num(n, 0)) or 0
end

-- ============================================================================
--                                     LOOP
-- ============================================================================

CreateThread(function()
    while true do
        Wait(1000)
        local now = GetGameTimer()
        local ok, err = pcall(AC._trackBuckets)
        if not ok then CP.err(TAG, 'bucket tracking failed: %s', tostring(err)) end
        ok, err = pcall(AC._idleCheck)
        if not ok then CP.err(TAG, 'idle check failed: %s', tostring(err)) end
        if lastPresenceMs == nil then lastPresenceMs = now end
        if now - lastPresenceMs >= PRESENCE_EVERY_MS then
            local interval = (now - lastPresenceMs) / 1000
            lastPresenceMs = now
            ok, err = pcall(AC._sample, math.min(interval, 10))
            if not ok then CP.err(TAG, 'presence sampling failed: %s', tostring(err)) end
        end
    end
end)

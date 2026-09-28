-- modules/integrations/qbx/server.lua · CP.Qbx (server): the only server code that talks to qbx_core.
--
-- Owns every exports.qbx_core call on the server and the qbx_core server events Crimson-Police
-- listens to. Those events are fired by qbx_core with TriggerEvent (server-local), so they are
-- registered with AddEventHandler ONLY: a net handler would let any client spoof a duty or job
-- change (docs/INTEGRATIONS.md, qbx_core-usage). The Qbox player object is never cached: every
-- check calls GetPlayer again, because an export returns a snapshot.
--
-- Public API (docs/ARCHITECTURE.md §5.1)
--   CP.Qbx.getPlayer(src) -> player|nil
--       Raw Qbox player object (fields under player.PlayerData).
--   CP.Qbx.getInfo(src) -> info|nil
--       info = { src, citizenid, name, firstname, lastname,
--                job = { name, label, type, onduty, gradeLevel, gradeName },
--                callsign, metadata, isDead, inLastStand }
--       name = charinfo first + last name; callsign = metadata.callsign trimmed, nil when empty or
--       qbx_core's default 'NO CALLSIGN'; gradeName falls back to the job definition's grade name.
--   CP.Qbx.getByCitizenId(citizenid) -> src|nil      online players only, exact (case-sensitive) match
--   CP.Qbx.getOnlinePlayers() -> { src, ... }        loaded characters, ascending (cached for 1 s)
--   CP.Qbx.getJobs() -> table                        qbx job definitions ({} when unavailable)
--   CP.Qbx.addMoney(src, account, amount, reason) -> boolean
--       player.Functions.AddMoney(account, amount, reason); amount rounded half up; 0 returns true
--       without calling qbx_core (nothing to move); negative or invalid amounts return false.
--   CP.Qbx.isDowned(src) -> boolean                  metadata.isdead == true or metadata.inlaststand == true
--   Listeners (any number; each runs in its own thread, errors are caught and logged):
--   CP.Qbx.onDutyChange(fn(src, onDuty))    QBCore:Server:SetDuty. false is passed on as is; a true is
--                                           re-read from PlayerData (SetDuty can arrive stale or out of
--                                           order when sc-police / sc-ambulance force a suspended officer
--                                           off duty inside their own handler). Listeners must still
--                                           re-read getInfo(src).job.onduty before acting on "on duty".
--   CP.Qbx.onPlayerLoaded(fn(src))          QBCore:Server:PlayerLoaded (player object argument).
--   CP.Qbx.onJobChange(fn(src, job))        QBCore:Server:OnJobUpdate; job has the getInfo job shape
--                                           (read live: PlayerData is already updated when it fires).
--   CP.Qbx.onPlayerUnload(fn(src))          QBCore:Server:OnPlayerUnload (character logout / switch).
--   CP.Qbx.onGroupUpdate(fn(src))           qbx_core:server:onGroupUpdate (job or gang added/removed;
--                                           removing the active job makes it 'unemployed' without an
--                                           OnJobUpdate, so listeners re-read the job).
--
-- All functions may be called from any thread; none of them yields.

CP.Qbx = CP.Qbx or {}
local Q = CP.Qbx
local TAG = 'qbx'
local RESOURCE = 'qbx_core'
local ONLINE_CACHE_MS = 1000

local listeners = { duty = {}, loaded = {}, job = {}, unload = {}, group = {} }
local onlineCache = { at = -1, list = {} }
local errorLoggedAt = {}

-- ── helpers ─────────────────────────────────────────────────────────────────
local function logError(key, fmt, ...)
    local now = os.time()
    if errorLoggedAt[key] and now - errorLoggedAt[key] < 60 then return end
    errorLoggedAt[key] = now
    CP.err(TAG, fmt, ...)
end

local function started()
    return GetResourceState(RESOURCE) == 'started'
end

-- A positive integer server id, or nil.
local function toSrc(src)
    local n = tonumber(src)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

local function str(v)
    if type(v) == 'string' then return v end
    return nil
end

local function normCallsign(v)
    if type(v) == 'number' then v = tostring(v) end
    if type(v) ~= 'string' then return nil end
    local s = CP.U.trim(v)
    if s == '' or s:upper() == 'NO CALLSIGN' then return nil end
    return s
end

local function gradeNameFromJobs(jobName, level)
    local jobs = Q.getJobs()
    local def = jobs[jobName]
    if type(def) ~= 'table' or type(def.grades) ~= 'table' then return nil end
    local g = def.grades[level] or def.grades[tostring(level)]
    if type(g) == 'table' and type(g.name) == 'string' and g.name ~= '' then return g.name end
    return nil
end

-- The job table in the shape documented above (never nil).
local function normJob(job)
    if type(job) ~= 'table' then
        return { name = 'unemployed', onduty = false, gradeLevel = 0 }
    end
    local level, gradeName = 0, nil
    local grade = job.grade
    if type(grade) == 'table' then
        level = tonumber(grade.level) or 0
        gradeName = str(grade.name)
    elseif type(grade) == 'number' then
        level = grade
    end
    level = math.floor(level)
    if gradeName == '' then gradeName = nil end
    local name = str(job.name)
    if not name or name == '' then name = 'unemployed' end
    if not gradeName and name ~= 'unemployed' then gradeName = gradeNameFromJobs(name, level) end
    return {
        name = name,
        label = str(job.label),
        type = str(job.type),
        onduty = job.onduty == true,
        gradeLevel = level,
        gradeName = gradeName,
    }
end

-- ── lookups ─────────────────────────────────────────────────────────────────
function Q.getPlayer(src)
    src = toSrc(src)
    if not src or not started() then return nil end
    local ok, player = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    if not ok then
        logError('GetPlayer', 'exports.qbx_core:GetPlayer failed: %s', tostring(player))
        return nil
    end
    if type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return nil end
    return player
end

function Q.getInfo(src)
    local n = toSrc(src)
    local player = Q.getPlayer(n)
    if not player then return nil end
    local pd = player.PlayerData
    if type(pd.citizenid) ~= 'string' or pd.citizenid == '' then return nil end
    local ci = type(pd.charinfo) == 'table' and pd.charinfo or {}
    local first = str(ci.firstname) and CP.U.trim(ci.firstname) or ''
    local last = str(ci.lastname) and CP.U.trim(ci.lastname) or ''
    local name = CP.U.trim(first .. ' ' .. last)
    if name == '' then name = GetPlayerName(n) or pd.citizenid end
    local md = type(pd.metadata) == 'table' and pd.metadata or {}
    return {
        src = n,
        citizenid = pd.citizenid,
        name = name,
        firstname = first,
        lastname = last,
        job = normJob(pd.job),
        callsign = normCallsign(md.callsign),
        metadata = md,
        isDead = md.isdead == true,
        inLastStand = md.inlaststand == true,
    }
end

function Q.getByCitizenId(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' or not started() then return nil end
    local ok, player = pcall(function() return exports.qbx_core:GetPlayerByCitizenId(citizenid) end)
    if not ok then
        logError('GetPlayerByCitizenId', 'exports.qbx_core:GetPlayerByCitizenId failed: %s', tostring(player))
        return nil
    end
    if type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return nil end
    return toSrc(player.PlayerData.source)
end

-- GetQBPlayers returns a map keyed by server id and copies every player's data across the export
-- boundary, so the source list is cached briefly and rebuilt on load/unload/drop.
function Q.getOnlinePlayers()
    if not started() then return {} end
    local now = GetGameTimer()
    if onlineCache.at < 0 or now - onlineCache.at >= ONLINE_CACHE_MS then
        local ok, players = pcall(function() return exports.qbx_core:GetQBPlayers() end)
        if not ok then
            logError('GetQBPlayers', 'exports.qbx_core:GetQBPlayers failed: %s', tostring(players))
            return {}
        end
        local list, seen = {}, {}
        if type(players) == 'table' then
            for key, p in pairs(players) do
                local src
                if type(p) == 'table' and type(p.PlayerData) == 'table' then src = toSrc(p.PlayerData.source) end
                src = src or toSrc(key)
                if src and not seen[src] then
                    seen[src] = true
                    list[#list + 1] = src
                end
            end
        end
        table.sort(list)
        onlineCache = { at = now, list = list }
    end
    local out = {}
    for i = 1, #onlineCache.list do out[i] = onlineCache.list[i] end
    return out
end

function Q.getJobs()
    if not started() then return {} end
    local ok, jobs = pcall(function() return exports.qbx_core:GetJobs() end)
    if not ok then
        logError('GetJobs', 'exports.qbx_core:GetJobs failed: %s', tostring(jobs))
        return {}
    end
    if type(jobs) ~= 'table' then return {} end
    return jobs
end

function Q.addMoney(src, account, amount, reason)
    amount = tonumber(amount)
    if not amount or amount ~= amount or amount == math.huge or amount == -math.huge or amount < 0 then return false end
    if type(account) ~= 'string' or account == '' then return false end
    amount = math.floor(amount + 0.5)
    if amount == 0 then return true end
    local player = Q.getPlayer(src)
    if not player or type(player.Functions) ~= 'table' then return false end
    local why = CP.U.clip(type(reason) == 'string' and reason ~= '' and reason or 'crimson-police', 64)
    local ok, res = pcall(function() return player.Functions.AddMoney(account, amount, why) end)
    if not ok then
        CP.err(TAG, 'AddMoney(%s, %d) for %s failed: %s', account, amount, tostring(src), tostring(res))
        return false
    end
    CP.log(TAG, 'AddMoney %s %d to %s (%s) -> %s', account, amount, tostring(src), why, tostring(res))
    return res == true
end

function Q.isDowned(src)
    local player = Q.getPlayer(src)
    if not player then return false end
    local md = player.PlayerData.metadata
    if type(md) ~= 'table' then return false end
    return md.isdead == true or md.inlaststand == true
end

-- ── listeners ───────────────────────────────────────────────────────────────
local function addListener(kind, fn)
    if type(fn) ~= 'function' then
        CP.warn(TAG, 'a %s listener must be a function (got %s)', kind, type(fn))
        return
    end
    local list = listeners[kind]
    list[#list + 1] = fn
end

-- Each listener runs in its own thread so one that queries the database or waits never delays
-- qbx_core's synchronous event dispatch or the other listeners.
local function emit(kind, ...)
    local list = listeners[kind]
    if #list == 0 then return end
    local args = table.pack(...)
    for i = 1, #list do
        local fn = list[i]
        CreateThread(function()
            local ok, err = pcall(fn, table.unpack(args, 1, args.n))
            if not ok then CP.err(TAG, '%s listener failed: %s', kind, tostring(err)) end
        end)
    end
end

function Q.onDutyChange(fn) addListener('duty', fn) end
function Q.onPlayerLoaded(fn) addListener('loaded', fn) end
function Q.onJobChange(fn) addListener('job', fn) end
function Q.onPlayerUnload(fn) addListener('unload', fn) end
function Q.onGroupUpdate(fn) addListener('group', fn) end

-- ── qbx_core server events (server-local: AddEventHandler only) ─────────────
AddEventHandler('QBCore:Server:SetDuty', function(src, onDuty)
    src = toSrc(src)
    if not src then return end
    local duty = onDuty == true
    if duty then
        -- A true may be stale: re-read the live value (PlayerData is updated before the event).
        local info = Q.getInfo(src)
        duty = info ~= nil and info.job.onduty == true
    end
    CP.log(TAG, 'SetDuty %d -> %s (event said %s)', src, tostring(duty), tostring(onDuty))
    emit('duty', src, duty)
end)

AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    if type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return end
    local src = toSrc(player.PlayerData.source)
    if not src then return end
    onlineCache.at = -1
    CP.log(TAG, 'PlayerLoaded %d (%s)', src, tostring(player.PlayerData.citizenid))
    emit('loaded', src)
end)

AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
    src = toSrc(src)
    if not src then return end
    local info = Q.getInfo(src)
    local current = info and info.job or normJob(job)
    CP.log(TAG, 'OnJobUpdate %d -> %s (grade %d, on duty %s)', src, current.name, current.gradeLevel, tostring(current.onduty))
    emit('job', src, current)
end)

AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    src = toSrc(src)
    if not src then return end
    onlineCache.at = -1
    CP.log(TAG, 'OnPlayerUnload %d', src)
    emit('unload', src)
end)

AddEventHandler('qbx_core:server:onGroupUpdate', function(src, groupName, grade)
    src = toSrc(src)
    if not src then return end
    CP.log(TAG, 'onGroupUpdate %d %s -> %s', src, tostring(groupName), tostring(grade))
    emit('group', src)
end)

AddEventHandler('playerDropped', function()
    onlineCache.at = -1
end)

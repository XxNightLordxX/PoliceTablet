-- CP.Qbx (server): the only server code that talks to qbx_core.

CP.Qbx = CP.Qbx or {}
local Q = CP.Qbx
local TAG = 'qbx'
local RESOURCE = 'qbx_core'
local ONLINE_CACHE_MS = 1000

local listeners = { duty = {}, loaded = {}, job = {}, unload = {}, group = {} }
local metaListeners = {}   -- { fn, keys = { [key] = true }|nil }
local onlineCache = { at = -1, list = {} }
local errorLoggedAt = {}

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function LogError(key, fmt, ...)
    local now = os.time()
    if errorLoggedAt[key] and now - errorLoggedAt[key] < 60 then return end
    errorLoggedAt[key] = now
    CP.err(TAG, fmt, ...)
end

local function Started()
    return GetResourceState(RESOURCE) == 'started'
end

-- A positive integer server id, or nil.
local function ToSrc(src)
    local n = tonumber(src)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

local function Str(v)
    if type(v) == 'string' then return v end
    return nil
end

local function NormCallsign(v)
    if type(v) == 'number' then v = tostring(v) end
    if type(v) ~= 'string' then return nil end
    local s = CP.U.trim(v)
    if s == '' or s:upper() == 'NO CALLSIGN' then return nil end
    return s
end

local function GradeNameFromJobs(jobName, level)
    local jobs = Q.getJobs()
    local def = jobs[jobName]
    if type(def) ~= 'table' or type(def.grades) ~= 'table' then return nil end
    local g = def.grades[level] or def.grades[tostring(level)]
    if type(g) == 'table' and type(g.name) == 'string' and g.name ~= '' then return g.name end
    return nil
end

-- The job table in the shape documented above (never nil).
local function NormJob(job)
    if type(job) ~= 'table' then
        return { name = 'unemployed', onduty = false, gradeLevel = 0 }
    end
    local level, gradeName = 0, nil
    local grade = job.grade
    if type(grade) == 'table' then
        level = tonumber(grade.level) or 0
        gradeName = Str(grade.name)
    elseif type(grade) == 'number' then
        level = grade
    end
    level = math.floor(level)
    if gradeName == '' then gradeName = nil end
    local name = Str(job.name)
    if not name or name == '' then name = 'unemployed' end
    if not gradeName and name ~= 'unemployed' then gradeName = GradeNameFromJobs(name, level) end
    return {
        name = name,
        label = Str(job.label),
        type = Str(job.type),
        onduty = job.onduty == true,
        gradeLevel = level,
        gradeName = gradeName,
    }
end

-- ============================================================================
--                                   LOOKUPS
-- ============================================================================

function Q.getPlayer(src)
    src = ToSrc(src)
    if not src or not Started() then return nil end
    local ok, player = pcall(function() return exports.qbx_core:GetPlayer(src) end)
    if not ok then
        LogError('GetPlayer', 'exports.qbx_core:GetPlayer failed: %s', tostring(player))
        return nil
    end
    if type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return nil end
    return player
end

function Q.getInfo(src)
    local n = ToSrc(src)
    local player = Q.getPlayer(n)
    if not player then return nil end
    local pd = player.PlayerData
    if type(pd.citizenid) ~= 'string' or pd.citizenid == '' then return nil end
    local ci = type(pd.charinfo) == 'table' and pd.charinfo or {}
    local first = Str(ci.firstname) and CP.U.trim(ci.firstname) or ''
    local last = Str(ci.lastname) and CP.U.trim(ci.lastname) or ''
    local name = CP.U.trim(first .. ' ' .. last)
    if name == '' then name = GetPlayerName(n) or pd.citizenid end
    local md = type(pd.metadata) == 'table' and pd.metadata or {}
    return {
        src = n,
        citizenid = pd.citizenid,
        license = Str(pd.license),
        name = name,
        firstname = first,
        lastname = last,
        job = NormJob(pd.job),
        callsign = NormCallsign(md.callsign),
        metadata = md,
        isDead = md.isdead == true,
        inLastStand = md.inlaststand == true,
    }
end

function Q.getByCitizenId(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' or not Started() then return nil end
    local ok, player = pcall(function() return exports.qbx_core:GetPlayerByCitizenId(citizenid) end)
    if not ok then
        LogError('GetPlayerByCitizenId', 'exports.qbx_core:GetPlayerByCitizenId failed: %s', tostring(player))
        return nil
    end
    if type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return nil end
    return ToSrc(player.PlayerData.source)
end

-- GetQBPlayers returns a map keyed by server id and copies every player's data across the export
-- boundary, so the source list is cached briefly and rebuilt on load/unload/drop.
function Q.getOnlinePlayers()
    if not Started() then return {} end
    local now = GetGameTimer()
    if onlineCache.at < 0 or now - onlineCache.at >= ONLINE_CACHE_MS then
        local ok, players = pcall(function() return exports.qbx_core:GetQBPlayers() end)
        if not ok then
            LogError('GetQBPlayers', 'exports.qbx_core:GetQBPlayers failed: %s', tostring(players))
            return {}
        end
        local list, seen = {}, {}
        if type(players) == 'table' then
            for key, p in pairs(players) do
                local src
                if type(p) == 'table' and type(p.PlayerData) == 'table' then src = ToSrc(p.PlayerData.source) end
                src = src or ToSrc(key)
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
    if not Started() then return {} end
    local ok, jobs = pcall(function() return exports.qbx_core:GetJobs() end)
    if not ok then
        LogError('GetJobs', 'exports.qbx_core:GetJobs failed: %s', tostring(jobs))
        return {}
    end
    if type(jobs) ~= 'table' then return {} end
    return jobs
end

function Q.addMoney(src, account, amount, reason)
    amount = tonumber(amount)
    if not amount or amount ~= amount or amount == math.huge or amount == -math.huge or amount < 0 then return false end
    if type(account) ~= 'string' or account == '' then return false end
    amount = CP.U.round(amount)
    if amount == 0 then return true end
    local player = Q.getPlayer(src)
    if not player or type(player.Functions) ~= 'table' then return false end
    local why = CP.U.clip(type(reason) == 'string' and reason ~= '' and reason or 'crimson-police', 64)
    local ok, res = pcall(function() return player.Functions.AddMoney(account, amount, why) end)
    if not ok then
        CP.err(TAG, 'AddMoney(%s, %d) for %s failed: %s', account, amount, tostring(src), tostring(res))
        return false, 'error'
    end
    CP.log(TAG, 'AddMoney %s %d to %s (%s) -> %s', account, amount, tostring(src), why, tostring(res))
    return res == true
end

-- The balance of one money account (bank, cash) of an online player, or nil. Qbox lets bank go below 0.
function Q.getMoney(src, account)
    if type(account) ~= 'string' or account == '' then return nil end
    local player = Q.getPlayer(src)
    if not player or type(player.PlayerData.money) ~= 'table' then return nil end
    local n = tonumber(player.PlayerData.money[account])
    if not n or n ~= n then return nil end
    return math.floor(n)
end

-- Takes money from an online player (an admin's clawback). true | false (refused, nothing taken) | false, 'error'
-- (RemoveMoney raised: the balance may already have changed).
function Q.removeMoney(src, account, amount, reason)
    amount = tonumber(amount)
    if not amount or amount ~= amount or amount == math.huge or amount <= 0 then return false end
    if type(account) ~= 'string' or account == '' then return false end
    amount = CP.U.round(amount)
    local player = Q.getPlayer(src)
    if not player or type(player.Functions) ~= 'table' or type(player.Functions.RemoveMoney) ~= 'function' then
        return false
    end
    local why = CP.U.clip(type(reason) == 'string' and reason ~= '' and reason or 'crimson-police', 64)
    local ok, res = pcall(function() return player.Functions.RemoveMoney(account, amount, why) end)
    if not ok then
        CP.err(TAG, 'RemoveMoney(%s, %d) for %s failed: %s', account, amount, tostring(src), tostring(res))
        return false, 'error'
    end
    CP.log(TAG, 'RemoveMoney %s %d from %s (%s) -> %s', account, amount, tostring(src), why, tostring(res))
    return res == true
end

function Q.isDowned(src)
    local player = Q.getPlayer(src)
    if not player then return false end
    local md = player.PlayerData.metadata
    if type(md) ~= 'table' then return false end
    return md.isdead == true or md.inlaststand == true
end

-- Whether a player owns a vehicle with this plate: a read-only look at qbx_core's player_vehicles, used only
-- to reroll a mission plate. Always the real oxmysql (CP.Storage.realMySQL with the database off), never a
-- cp_ table in the same statement. nil when the lookup fails: the caller then uses the reserved pattern alone.
function Q.plateOwned(plate)
    if type(plate) ~= 'string' or plate == '' or #plate > 8 then return nil end
    local db = (CP.Storage and CP.Storage.realMySQL) or MySQL
    if type(db) ~= 'table' or type(db.scalar) ~= 'table' then return nil end
    local ok, found = pcall(db.scalar.await, 'SELECT 1 FROM player_vehicles WHERE plate = ? LIMIT 1', { plate })
    if not ok then
        LogError('plate', 'player_vehicles plate lookup failed (mission plates use the reserved pattern only): %s',
            tostring(found))
        return nil
    end
    return found ~= nil
end

-- ============================================================================
--                       QBOX'S PLAYERS TABLE (READ ONLY)
-- ============================================================================
-- Always the real oxmysql (CP.Storage.realMySQL with the database off), never a cp_ table in the same statement.

local function QboxDb()
    local db = (CP.Storage and CP.Storage.realMySQL) or MySQL
    if type(db) ~= 'table' or type(db.single) ~= 'table' or type(db.query) ~= 'table' then return nil end
    return db
end

local function ValidCid(citizenid)
    return type(citizenid) == 'string' and citizenid ~= '' and #citizenid <= 50 and citizenid:match('^[%w_%-]+$') ~= nil
end

-- The license of a character: the online player's first, else Qbox's players table. nil when unknown.
function Q.licenseOf(citizenid)
    if not ValidCid(citizenid) then return nil end
    local src = Q.getByCitizenId(citizenid)
    if src then
        local player = Q.getPlayer(src)
        local lic = player and Str(player.PlayerData.license)
        if lic and lic ~= '' then return lic end
    end
    local db = QboxDb()
    if not db then return nil end
    local ok, row = pcall(db.single.await, 'SELECT license FROM players WHERE citizenid = ? LIMIT 1', { citizenid })
    if not ok then
        LogError('licenseOf', 'players license lookup failed: %s', tostring(row))
        return nil
    end
    if type(row) == 'table' and type(row.license) == 'string' and row.license ~= '' then return row.license end
    return nil
end

-- Whether Qbox has this character (online, or in its players table). nil when the lookup failed.
function Q.characterExists(citizenid)
    if not ValidCid(citizenid) then return false end
    if Q.getByCitizenId(citizenid) then return true end
    local db = QboxDb()
    if not db then return nil end
    local ok, row = pcall(db.single.await, 'SELECT 1 AS found FROM players WHERE citizenid = ? LIMIT 1', { citizenid })
    if not ok then
        LogError('characterExists', 'players lookup failed: %s', tostring(row))
        return nil
    end
    return type(row) == 'table'
end

-- Every citizenid Qbox has for one license (a player's characters).
function Q.citizenidsOfLicense(license)
    if type(license) ~= 'string' or license == '' or #license > 64 then return {} end
    local db = QboxDb()
    if not db then return {} end
    local ok, rows = pcall(db.query.await, 'SELECT citizenid FROM players WHERE license = ? LIMIT 20', { license })
    if not ok then
        LogError('citizenidsOfLicense', 'players lookup by license failed: %s', tostring(rows))
        return {}
    end
    local out = {}
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        if type(r.citizenid) == 'string' then out[#out + 1] = r.citizenid end
    end
    return out
end

-- ============================================================================
--                                  LISTENERS
-- ============================================================================

local function AddListener(kind, fn)
    if type(fn) ~= 'function' then
        CP.warn(TAG, 'a %s listener must be a function (got %s)', kind, type(fn))
        return
    end
    local list = listeners[kind]
    list[#list + 1] = fn
end

-- Each listener runs in its own thread so one that queries the database or waits never delays
-- qbx_core's synchronous event dispatch or the other listeners.
local function Emit(kind, ...)
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

function Q.onDutyChange(fn) AddListener('duty', fn) end
function Q.onPlayerLoaded(fn) AddListener('loaded', fn) end
function Q.onJobChange(fn) AddListener('job', fn) end
function Q.onPlayerUnload(fn) AddListener('unload', fn) end
function Q.onGroupUpdate(fn) AddListener('group', fn) end

function Q.onMetaDataChange(fn, keys)
    if type(fn) ~= 'function' then
        CP.warn(TAG, 'a metadata listener must be a function (got %s)', type(fn))
        return
    end
    local filter
    if type(keys) == 'table' then
        filter = {}
        for _, k in ipairs(keys) do if type(k) == 'string' then filter[k] = true end end
    end
    metaListeners[#metaListeners + 1] = { fn = fn, keys = filter }
end

-- ============================================================================
--                            qbx_core SERVER EVENTS
-- ============================================================================
-- server-local: AddEventHandler only.

AddEventHandler('QBCore:Server:SetDuty', function(src, onDuty)
    src = ToSrc(src)
    if not src then return end
    local duty = onDuty == true
    if duty then
        -- A true may be stale: re-read the live value (PlayerData is updated before the event).
        local info = Q.getInfo(src)
        duty = info ~= nil and info.job.onduty == true
    end
    CP.log(TAG, 'SetDuty %d -> %s (event said %s)', src, tostring(duty), tostring(onDuty))
    Emit('duty', src, duty)
end)

AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
    if type(player) ~= 'table' or type(player.PlayerData) ~= 'table' then return end
    local src = ToSrc(player.PlayerData.source)
    if not src then return end
    onlineCache.at = -1
    CP.log(TAG, 'PlayerLoaded %d (%s)', src, tostring(player.PlayerData.citizenid))
    Emit('loaded', src)
end)

AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
    src = ToSrc(src)
    if not src then return end
    local info = Q.getInfo(src)
    local current = info and info.job or NormJob(job)
    CP.log(TAG, 'OnJobUpdate %d -> %s (grade %d, on duty %s)', src, current.name, current.gradeLevel,
        tostring(current.onduty))
    Emit('job', src, current)
end)

AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    src = ToSrc(src)
    if not src then return end
    onlineCache.at = -1
    CP.log(TAG, 'OnPlayerUnload %d', src)
    Emit('unload', src)
end)

AddEventHandler('qbx_core:server:onGroupUpdate', function(src, groupName, grade)
    src = ToSrc(src)
    if not src then return end
    CP.log(TAG, 'onGroupUpdate %d %s -> %s', src, tostring(groupName), tostring(grade))
    Emit('group', src)
end)

-- qbx_core SetMetaData: TriggerEvent('qbx_core:server:onSetMetaData', key, oldValue, value, source).
AddEventHandler('qbx_core:server:onSetMetaData', function(key, old, new, src)
    if #metaListeners == 0 or type(key) ~= 'string' then return end
    src = ToSrc(src)
    if not src then return end
    for i = 1, #metaListeners do
        local l = metaListeners[i]
        if not l.keys or l.keys[key] then
            CreateThread(function()
                local ok, err = pcall(l.fn, src, key, old, new)
                if not ok then CP.err(TAG, 'metadata listener failed: %s', tostring(err)) end
            end)
        end
    end
end)

AddEventHandler('playerDropped', function()
    onlineCache.at = -1
end)

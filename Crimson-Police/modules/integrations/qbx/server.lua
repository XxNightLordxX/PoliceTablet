-- CP.Qbx (server): the only server code that talks to qbx_core.

-- Owns every exports.qbx_core call on the server and the qbx_core server events Crimson-Police
-- listens to. Those events are fired by qbx_core with TriggerEvent (server-local), so they are
-- registered with AddEventHandler ONLY: a net handler would let any client spoof a duty or job
-- change (docs/INTEGRATIONS.md, qbx_core-usage). The Qbox player object itself is never kept (getPlayer
-- always calls GetPlayer, so money Functions act on a fresh object). getInfo's answer is reused for
-- Config.Limits.playerInfoCacheMs (1000 ms; 0 = ask Qbox every time) and every Qbox change event clears
-- it at once: SetDuty, PlayerLoaded, OnJobUpdate, OnPlayerUnload, onGroupUpdate, onSetMetaData,
-- QBCore:Player:SetPlayerData (qbx_core's UpdatePlayerData, sent after every change), playerDropped and
-- a qbx_core stop or start. Each caller gets its own copy of the top level and the job table.
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
--   CP.Qbx.getOnlinePlayers() -> { src, ... }        loaded characters, ascending. Read from GetQBPlayers at
--       start, when qbx_core starts and every 60 s; PlayerLoaded adds and OnPlayerUnload / playerDropped
--       remove a player in between, with no copy (playerInfoCacheMs = 0: read every 1 s and after each
--       of those events, as before).
--   CP.Qbx.knownJob(src) -> jobName|nil             the primary job qbx_core last reported (nil = not known).
--       Kept by events and lookups only, never polled: PlayerLoaded, OnJobUpdate, QBCore:Player:SetPlayerData
--       (qbx_core's UpdatePlayerData; SetPlayerData('job', ...) fires nothing else), every getInfo, and the
--       GetQBPlayers copy of getOnlinePlayers (seeded at start and when qbx_core starts). Cleared on
--       OnPlayerUnload, playerDropped and a qbx_core stop.
--   CP.Qbx.getJobs() -> table                        qbx job definitions ({} when unavailable)
--   CP.Qbx.addMoney(src, account, amount, reason) -> boolean, why|nil
--       player.Functions.AddMoney(account, amount, reason); amount rounded half up (CP.U.round); 0 returns
--       true without calling qbx_core (nothing to move); negative or invalid amounts return false.
--       why = 'error' when AddMoney raised: the balance may already have changed, so the caller must not
--       retry or refund (CP.Cash leaves the row 'paying'). A plain false (refused, offline) has no why.
--   CP.Qbx.isDowned(src) -> boolean                  metadata.isdead == true or metadata.inlaststand == true
--       Two GetMetadata exports (src as a number; a citizenid string returns false), no Player copy. If
--       GetMetadata raises (a Qbox without it), GetPlayer is read from then on, until qbx_core starts again.
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
--   CP.Qbx.onMetaDataChange(fn(src, key, old, new), keys?)
--                                           qbx_core:server:onSetMetaData (key, oldValue, value, source),
--                                           fired by qbx_core's SetMetaData after the value is set. keys
--                                           (optional list of metadata keys) filters before any thread is
--                                           started: metadata changes constantly (hunger, thirst, stress).
--
-- All functions may be called from any thread; none of them yields.

CP.Qbx = CP.Qbx or {}
local Q = CP.Qbx
local TAG = 'qbx'
local RESOURCE = 'qbx_core'
local ONLINE_CACHE_MS = 1000      -- the old timing (Config.Limits.playerInfoCacheMs = 0): the list is read every second
local ONLINE_REREAD_MS = 60000    -- the list kept by events is read again from Qbox this often (heals a missed event)

local listeners = { duty = {}, loaded = {}, job = {}, unload = {}, group = {} }
local metaListeners = {}   -- { fn, keys = { [key] = true }|nil }
-- The loaded characters: read from GetQBPlayers at start, when qbx_core starts and every ONLINE_REREAD_MS, and kept
-- by PlayerLoaded / OnPlayerUnload / playerDropped in between. list is set's keys in order (rebuilt when dirty).
local online = { at = -1, set = {}, list = {}, dirty = false }
-- src -> { at = GetGameTimer(), info = getInfo's table }: reused for Config.Limits.playerInfoCacheMs, and cleared by
-- every qbx_core event that changes the player (duty, job, load, unload, groups, metadata, SetPlayerData) and by a drop.
local infoCache = {}
local errorLoggedAt = {}
-- src -> the player's primary Qbox job name, kept only by qbx_core's events and by lookups (never polled), so loops
-- over every player can skip non-police without copying their Player object (CP.Access.maybeOfficer).
local jobOf = {}
-- false once exports.qbx_core:GetMetadata raised (a Qbox without that export): isDowned then reads the whole Player.
local metadataExport = true

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

-- The job name exactly as NormJob gives it (no grade lookup).
local function JobName(job)
    local name = type(job) == 'table' and Str(job.name) or nil
    if not name or name == '' then return 'unemployed' end
    return name
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
    local name = JobName(job)
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

-- Milliseconds a getInfo answer is reused (Config.Limits.playerInfoCacheMs; 0 = ask Qbox every time).
local function InfoCacheMs()
    local ms = tonumber(Config.Limits and Config.Limits.playerInfoCacheMs)
    if not ms or ms ~= ms then return 1000 end
    return math.max(0, ms)
end

-- A copy a caller may change: the top level and the job table (metadata is read only).
local function CopyInfo(info)
    local out = {}
    for k, v in pairs(info) do out[k] = v end
    local job = {}
    for k, v in pairs(info.job) do job[k] = v end
    out.job = job
    if type(info.gang) == 'table' then out.gang = { name = info.gang.name, gradeLevel = info.gang.gradeLevel } end
    return out
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

-- getInfo's table read from Qbox (one GetPlayer export), or nil.
local function ReadInfo(n)
    local player = Q.getPlayer(n)
    if not player then
        if n then jobOf[n] = nil end
        return nil
    end
    local pd = player.PlayerData
    if type(pd.citizenid) ~= 'string' or pd.citizenid == '' then return nil end
    local ci = type(pd.charinfo) == 'table' and pd.charinfo or {}
    local first = Str(ci.firstname) and CP.U.trim(ci.firstname) or ''
    local last = Str(ci.lastname) and CP.U.trim(ci.lastname) or ''
    local name = CP.U.trim(first .. ' ' .. last)
    if name == '' then name = GetPlayerName(n) or pd.citizenid end
    local md = type(pd.metadata) == 'table' and pd.metadata or {}
    local job = NormJob(pd.job)
    jobOf[n] = job.name
    -- the Qbox gang and its grade (Config.Permissions.grants may name gangs); 'none' = in no gang
    local g = type(pd.gang) == 'table' and pd.gang or {}
    local gGrade = type(g.grade) == 'table' and tonumber(g.grade.level) or tonumber(g.grade) or 0
    local gang = { name = Str(g.name) and g.name ~= '' and g.name or 'none', gradeLevel = math.floor(gGrade) }
    return {
        src = n,
        citizenid = pd.citizenid,
        license = Str(pd.license),
        name = name,
        firstname = first,
        lastname = last,
        job = job,
        gang = gang,
        callsign = NormCallsign(md.callsign),
        metadata = md,
        isDead = md.isdead == true,
        inLastStand = md.inlaststand == true,
    }
end

-- Reused for Config.Limits.playerInfoCacheMs: loops over every player and getOfficer's several reads of one player in
-- one tick ask Qbox once. Every Qbox change event clears the entry at once, so a new job or duty is seen at once.
function Q.getInfo(src)
    local n = ToSrc(src)
    local ms = InfoCacheMs()
    local hit = n and ms > 0 and infoCache[n]
    if hit and GetGameTimer() - hit.at < ms and Started() then
        jobOf[n] = hit.info.job.name
        return CopyInfo(hit.info)
    end
    local info = ReadInfo(n)
    if n then infoCache[n] = info and ms > 0 and { at = GetGameTimer(), info = info } or nil end
    if info and ms > 0 then return CopyInfo(info) end
    return info
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

-- The whole list from GetQBPlayers (a map keyed by server id that copies every player's data across the export
-- boundary). false when the export failed.
local function ReadOnline(now)
    local ok, players = pcall(function() return exports.qbx_core:GetQBPlayers() end)
    if not ok then
        LogError('GetQBPlayers', 'exports.qbx_core:GetQBPlayers failed: %s', tostring(players))
        return false
    end
    local list, seen, jobs = {}, {}, {}
    if type(players) == 'table' then
        for key, p in pairs(players) do
            local src
            local pd = type(p) == 'table' and type(p.PlayerData) == 'table' and p.PlayerData or nil
            if pd then src = ToSrc(pd.source) end
            src = src or ToSrc(key)
            if src and not seen[src] then
                seen[src] = true
                list[#list + 1] = src
                if pd then jobs[src] = JobName(pd.job) end
            end
        end
    end
    table.sort(list)
    online = { at = now, set = seen, list = list, dirty = false }
    -- The same copy seeds the job map: a player Qbox does not list has no job here (unknown = a full check).
    jobOf = jobs
    return true
end

-- A player joins or leaves the list (PlayerLoaded, OnPlayerUnload, playerDropped) without a GetQBPlayers copy.
local function SetOnline(src, on)
    online.set[src] = on or nil
    online.dirty = true
    -- Config.Limits.playerInfoCacheMs = 0: the old behaviour, the whole list is read again on the next call
    if InfoCacheMs() <= 0 then online.at = -1 end
end

function Q.getOnlinePlayers()
    if not Started() then return {} end
    local now = GetGameTimer()
    local maxAge = InfoCacheMs() > 0 and ONLINE_REREAD_MS or ONLINE_CACHE_MS
    if online.at < 0 or now - online.at >= maxAge then
        if not ReadOnline(now) then return {} end
    elseif online.dirty then
        local list = {}
        for src in pairs(online.set) do list[#list + 1] = src end
        table.sort(list)
        online.list, online.dirty = list, false
    end
    local out = {}
    for i = 1, #online.list do out[i] = online.list[i] end
    return out
end

-- The primary job name Qbox last reported for src (events and lookups only), or nil when it is not known.
function Q.knownJob(src)
    return jobOf[src]
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

-- Qbox's gangs (exports.qbx_core:GetGangs): { [name] = { label, grades = { [level] = { name } } } }; {} when it fails.
function Q.getGangs()
    if not Started() then return {} end
    local ok, gangs = pcall(function() return exports.qbx_core:GetGangs() end)
    if not ok then
        LogError('GetGangs', 'exports.qbx_core:GetGangs failed: %s', tostring(gangs))
        return {}
    end
    return type(gangs) == 'table' and gangs or {}
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

-- One metadata value through qbx_core's GetMetadata export: a lookup inside qbx_core, no copy of the whole Player.
-- src must be a number: qbx_core reads its players table for a citizenid string (GetOfflinePlayer).
local function ReadMetadata(src, key)
    return pcall(function() return exports.qbx_core:GetMetadata(src, key) end)
end

-- Metadata isdead or inlaststand is true. Read with GetMetadata; on a Qbox without that export (the call raised) the
-- whole Player is read instead, from then on until qbx_core starts again.
function Q.isDowned(src)
    src = ToSrc(src)
    if not src or not Started() then return false end
    if metadataExport then
        local ok, v = ReadMetadata(src, 'isdead')
        if ok and v == true then return true end
        if ok then ok, v = ReadMetadata(src, 'inlaststand') end
        if ok then return v == true end
        metadataExport = false
        CP.log(TAG, 'exports.qbx_core:GetMetadata failed (%s): the downed check reads the whole player from now on',
            tostring(v))
    end
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

local NAMES_MAX = 500           -- citizenids one characterNames call looks up at most
local NAMES_CHUNK = 100         -- citizenids per players-table statement

local function CharName(ci)
    if type(ci) == 'string' then
        local ok, t = pcall(json.decode, ci)
        ci = ok and t or nil
    end
    if type(ci) ~= 'table' then return nil end
    local first = Str(ci.firstname) and CP.U.trim(ci.firstname) or ''
    local last = Str(ci.lastname) and CP.U.trim(ci.lastname) or ''
    local name = CP.U.trim(first .. ' ' .. last)
    return name ~= '' and name or nil
end

-- Character names for many citizenids at once (F2, staff screens): the loaded characters from the player cache (no
-- export call per citizenid), the rest from Qbox's players table, one statement per NAMES_CHUNK. -> { [citizenid] =
-- 'First Last' }; a citizenid with no name is left out.
function Q.characterNames(cids)
    local out, want, n = {}, {}, 0
    for _, cid in ipairs(type(cids) == 'table' and cids or {}) do
        if ValidCid(cid) and not want[cid] and n < NAMES_MAX then
            want[cid] = true
            n = n + 1
        end
    end
    if n == 0 then return out end
    for _, src in ipairs(Q.getOnlinePlayers()) do
        local info = Q.getInfo(src)
        if info and want[info.citizenid] and type(info.name) == 'string' and info.name ~= '' then
            out[info.citizenid] = info.name
            want[info.citizenid] = nil
            n = n - 1
        end
    end
    local db = n > 0 and QboxDb() or nil
    if not db then return out end
    local rest = {}
    for cid in pairs(want) do rest[#rest + 1] = cid end
    table.sort(rest)
    for first = 1, #rest, NAMES_CHUNK do
        local chunk, marks = {}, {}
        for i = first, math.min(#rest, first + NAMES_CHUNK - 1) do
            chunk[#chunk + 1] = rest[i]
            marks[#marks + 1] = '?'
        end
        local ok, rows = pcall(db.query.await,
            ('SELECT citizenid, charinfo FROM players WHERE citizenid IN (%s)'):format(table.concat(marks, ', ')),
            chunk)
        if not ok then
            LogError('characterNames', 'players name lookup failed: %s', tostring(rows))
            return out
        end
        for _, r in ipairs(type(rows) == 'table' and rows or {}) do
            local name = type(r.citizenid) == 'string' and CharName(r.charinfo) or nil
            if name then out[r.citizenid] = name end
        end
    end
    return out
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

-- Every license Qbox's users table keeps for the player who has this one (qbx_core server/storage/players.lua: one
-- users row per player, its license and license2), this one first. Just { license } on a qbx_core without that
-- table or when the lookup fails.
function Q.userLicenses(license)
    if type(license) ~= 'string' or license == '' or #license > 64 then return {} end
    local out, seen = { license }, { [license] = true }
    local function add(v)
        if type(v) == 'string' and v ~= '' and not seen[v] then
            seen[v] = true
            out[#out + 1] = v
        end
    end
    local db = QboxDb()
    if not db then return out end
    local ok, rows = pcall(db.query.await,
        'SELECT license, license2 FROM users WHERE license = ? OR license2 = ? LIMIT 5', { license, license })
    if not ok then
        LogError('userLicenses', 'users lookup by license failed: %s', tostring(rows))
        return out
    end
    for _, r in ipairs(type(rows) == 'table' and rows or {}) do
        add(r.license)
        add(r.license2)
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
    infoCache[src] = nil
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
    infoCache[src] = nil
    SetOnline(src, true)
    jobOf[src] = JobName(player.PlayerData.job)
    CP.log(TAG, 'PlayerLoaded %d (%s)', src, tostring(player.PlayerData.citizenid))
    Emit('loaded', src)
end)

AddEventHandler('QBCore:Server:OnJobUpdate', function(src, job)
    src = ToSrc(src)
    if not src then return end
    infoCache[src] = nil
    local info = Q.getInfo(src)
    local current = info and info.job or NormJob(job)
    jobOf[src] = current.name
    CP.log(TAG, 'OnJobUpdate %d -> %s (grade %d, on duty %s)', src, current.name, current.gradeLevel,
        tostring(current.onduty))
    Emit('job', src, current)
end)

AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    src = ToSrc(src)
    if not src then return end
    infoCache[src] = nil
    SetOnline(src, false)
    jobOf[src] = nil
    CP.log(TAG, 'OnPlayerUnload %d', src)
    Emit('unload', src)
end)

AddEventHandler('qbx_core:server:onGroupUpdate', function(src, groupName, grade)
    src = ToSrc(src)
    if not src then return end
    infoCache[src] = nil
    CP.log(TAG, 'onGroupUpdate %d %s -> %s', src, tostring(groupName), tostring(grade))
    Emit('group', src)
end)

-- qbx_core SetMetaData: TriggerEvent('qbx_core:server:onSetMetaData', key, oldValue, value, source).
AddEventHandler('qbx_core:server:onSetMetaData', function(key, old, new, src)
    src = ToSrc(src)
    if not src then return end
    infoCache[src] = nil
    if #metaListeners == 0 or type(key) ~= 'string' then return end
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

-- qbx_core's UpdatePlayerData (its SetPlayerData export, Functions.SetPlayerData, SetJob, the group functions)
-- sends the whole PlayerData here; a job set through SetPlayerData('job', ...) fires no other event.
AddEventHandler('QBCore:Player:SetPlayerData', function(pd)
    if type(pd) ~= 'table' then return end
    local src = ToSrc(pd.source)
    if not src then return end
    infoCache[src] = nil
    if type(pd.job) == 'table' then jobOf[src] = JobName(pd.job) end
end)

AddEventHandler('playerDropped', function()
    local src = ToSrc(source)
    if not src then return end
    infoCache[src] = nil
    SetOnline(src, false)
    jobOf[src] = nil
end)

-- qbx_core stopped: nothing is known; started again: the list and the job map are read from its players list.
AddEventHandler('onResourceStop', function(res)
    if res ~= RESOURCE then return end
    online = { at = -1, set = {}, list = {}, dirty = false }
    infoCache = {}
    jobOf = {}
end)

AddEventHandler('onResourceStart', function(res)
    if res ~= RESOURCE then return end
    online.at = -1
    infoCache = {}
    metadataExport = true   -- an updated qbx_core may have GetMetadata now
    Q.getOnlinePlayers()
end)

-- Read the list and seed the job map once at start (a restart of Crimson-Police with players online).
CreateThread(function()
    online.at = -1
    Q.getOnlinePlayers()
end)

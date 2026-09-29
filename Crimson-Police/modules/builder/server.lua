-- CP.Builder (server): the Mission Builder's drafts, edit locks, versions,

CP.Builder = CP.Builder or {}
local B = CP.Builder
local U = CP.U
local TAG = 'builder'

-- ============================================================================
--              CONSTANTS (numbers the spec and config leave open)
-- ============================================================================

local LIMITS = { label = 64, description = 500, objectiveLabel = 64, locationLabel = 64 }
local START_RADIUS = { 20, 150, 60 }
local MAX_LOCATIONS = 20
local MAX_ITEMS = 10
local ITEM_COUNT = { 1, 100 }
local MAX_SCALING = 20
local MAX_ROUTE_POINTS = 500
local MAX_NODES = 20000
local MAX_DEPTH = 10
local MAX_STRING = 512
local MAX_KEY = 40
local MAX_NUMBER = 1e9
local MAX_ID = 40
local SLUG_MAX = 30
local COORD_LIMIT = 10000.0
local Z_MIN, Z_MAX = -250.0, 1500.0
local AUTOSAVE_MIN_MS = 5000
local VIEWER_TTL_MS = 15 * 60 * 1000
local MAX_BACKUP_SCAN = 50
local WRAP = 100
local BOSS_ID = 'weekly_boss_kingpin'
local HEADER_FIRST = '--[[ Crimson-Police · custom mission (written by the Mission Builder)'

local LOADER_FIELDS = { 'source', 'version', 'filePath', 'defHash', 'editedInCode', 'isBoss', 'status', '_file' }
local PAYOUT_NAMES = {
    cash = true,
    cashbase = true,
    basepay = true,
    money = true,
    pay = true,
    reward = true,
    rewards = true,
}
local FORBIDDEN_ITEMS = { 'armour', 'bandage', 'ammo-*', 'weapon_*', 'money', 'black_money' }

-- ARCHITECTURE §3.3 default minimum seconds per block (used when an objective has none).
local DEFAULT_MIN_SECONDS = {
    checkpoint_route = 20,
    interact_points = 5,
    skill_check = 10,
    hostile_waves = 60,
    protect_rescue = 15,
    flee_arrest = 30,
    pursuit = 30,
    escort = 60,
    search_area = 60,
}

-- Builder units: whole percent <-> fractions, seconds <-> milliseconds (protocol §1.1).
local PERCENT_FIELDS = {
    hostile_waves = { 'surrender.chance', 'boss.surrender.chance' },
    flee_arrest = { 'responses.surrender', 'responses.flee', 'responses.fight', 'armedShare' },
    pursuit = { 'footFlee' },
    interact_points = { 'roll.outcomes.*.chance' },
}
local SECONDS_FIELDS = {
    interact_points = { 'progress.duration', 'roll.outcomes.*.followUp.duration' },
    protect_rescue = { 'freeTime' },
    flee_arrest = { 'knock.duration', 'cuff.duration' },
    hostile_waves = { 'cuff.duration' },
    pursuit = { 'arrest.duration' },
    search_area = { 'clueProgress.duration', 'cuff.duration' },
}
-- Objective fields renamed after mission files were published (block -> { old name = new name }). A file or a
-- stored draft that still uses the old name is read as the new one, silently (no warning): checkpoint_route's
-- policeVehicle became vehicleRequired when the police-vehicle check was replaced by "driving a vehicle".
local RENAMED_FIELDS = { checkpoint_route = { policeVehicle = 'vehicleRequired' } }
-- Objective fields that name NPC/vehicle spawn-point location keys (>= minSpawnFromStart from the start).
local SPAWN_FIELDS = {
    hostile_waves = { 'spawns', 'boss.spawn' },
    protect_rescue = { 'npcs' },
    flee_arrest = { 'suspect', 'associates.spawns', 'spawns' },
    pursuit = { 'spawn', 'spawns' },
    escort = { 'ambushPoints' },
    search_area = { 'hiding' },
}

-- Lua export: key order inside tables (unknown keys follow alphabetically), fraction and float keys.
local ORDER_LIST = {
    'id',
    'block',
    'name',
    'label',
    'minSeconds',
    'mode',
    'coords',
    'heading',
    'radius',
    'points',
    'pctOfPoints',
    'each',
    'path',
    'max',
    'checkpoints',
    'targets',
    'spawns',
    'spawn',
    'npcs',
    'door',
    'suspect',
    'fleeTo',
    'routes',
    'center',
    'clues',
    'hiding',
    'route',
    'ambushPoints',
    'safe',
    'use',
    'count',
    'waves',
    'nextWave',
    'aliveAtMost',
    'afterSeconds',
    'vehicles',
    'suspectsPerVehicle',
    'suspects',
    'armedShare',
    'weapons',
    'weapon',
    'accuracy',
    'armour',
    'health',
    'behaviour',
    'surrender',
    'flee',
    'fight',
    'belowHealth',
    'chance',
    'peds',
    'models',
    'model',
    'boss',
    'restrained',
    'freeTime',
    'target',
    'icon',
    'distance',
    'seconds',
    'progress',
    'duration',
    'anim',
    'roll',
    'outcomes',
    'followUp',
    'logResult',
    'choices',
    'correct',
    'hidden',
    'prop',
    'fastBonus',
    'checks',
    'missPenalty',
    'failAfter',
    'explosion',
    'responses',
    'knock',
    'associates',
    'speed',
    'style',
    'trigger',
    'stopped',
    'footFlee',
    'surrenderOnAim',
    'arrest',
    'hold',
    'lost',
    'escape',
    'givesUp',
    'aim',
    'stun',
    'close',
    'armedGivesUp',
    'cuff',
    'maxDistance',
    'aliveBonus',
    'vehicle',
    'toughness',
    'stoppedFail',
    'arrival',
    'ambush',
    'carsPerWave',
    'perCar',
    'clearRadius',
    'startRadius',
    'shrinkTo',
    'clueCount',
    'clueProps',
    'clueProgress',
    'fugitives',
    'runDistance',
    'stopFor',
    'vehicleRequired',
    'medals',
    'gold',
    'silver',
    'bronze',
    'contactPenalty',
    'timerStart',
    'failIfUndriveable',
    'safeRadius',
    'hitPenalty',
    'failIfDies',
    'blockTraffic',
    'complete',
    'ramSpeed',
    'ramPenaltyId',
    'neverShoots',
    'stops',
    'at',
    'wait',
    'loop',
    'presenceRange',
}
local ORDER = {}
for i, k in ipairs(ORDER_LIST) do if not ORDER[k] then ORDER[k] = i end end
ORDER.presenceRange = 200000   -- always the last field of an objective
local FRACTION_KEYS = {
    chance = true,
    surrender = true,
    flee = true,
    fight = true,
    armedShare = true,
    footFlee = true,
    pctOfPoints = true,
    belowHealth = true,
}
local FLOAT_KEYS = {
    radius = true,
    blockTraffic = true,
    safeRadius = true,
    fireWithin = true,
    arrival = true,
    clearRadius = true,
    runDistance = true,
    maxDistance = true,
    ahead = true,
    startRadius = true,
}
local LUA_KEYWORDS = {}
for w in
    ('and break do else elseif end false for function goto if in local nil not or repeat return then true until while'):gmatch(
        '%S+')
do
    LUA_KEYWORDS[w] = true
end

-- ============================================================================
--                                RUNTIME STATE
-- ============================================================================

local pendingTests = {}   -- missionId -> { hash, version, startedBy, at }
local viewers = {}        -- src -> GetGameTimer() of the last builder:list/get
local holders = {}        -- src -> citizenid that took an edit lock (released on drop/unload)
local lastAutosave = {}   -- 'src:id' -> GetGameTimer()
-- missionId -> { [citizenid] = true }: editors whose lock was broken. Their save/autosave no longer takes the
-- free lock back by itself (that would silently overwrite the breaker's work); an explicit lock does.
local brokenLocks = {}

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function CfgB() return Config.Builder or {} end
local function Details() return (Config.Blocks and Config.Blocks.details) or {} end
local function ExportDir()
    local p = tostring(CfgB().exportPath or 'missions/custom/')
    if p:sub(-1) ~= '/' then p = p .. '/' end
    return p
end
local function FilePathFor(id) return ExportDir() .. id .. '.lua' end
local function ArchivedPathFor(id) return ExportDir() .. 'archived/' .. id .. '.lua' end
local function BackupPathFor(id, v) return ('%s%s.v%d.lua.bak'):format(ExportDir(), id, v) end
local function DraftBackupPathFor(id) return ExportDir() .. id .. '.draft.lua.bak' end

local function IsNum(v) return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge end
local function IsInt(v) return IsNum(v) and math.floor(v) == v end
local function InRange(v, r) return IsNum(v) and type(r) == 'table' and v >= r[1] - 1e-9 and v <= r[2] + 1e-9 end
local function Round(x, places)
    local m = 10 ^ (places or 0)
    return math.floor(x * m + 0.5) / m
end
local function RoundInt(x) return math.floor(x + 0.5) end
-- A number for message variables: 2 rather than 2.0.
local function Nice(v)
    if type(v) ~= 'number' then return v end
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return math.floor(v) end
    return v
end
local function Minutes(sec) return Nice(Round((tonumber(sec) or 0) / 60, 1)) end

-- Text limits count characters, as the builder UI does (bytes for text that is not valid UTF-8).
local function TextLen(s) return utf8.len(s) or #s end

-- At most n characters, never cutting a UTF-8 character in two (the database refuses a cut character).
local function ClipText(s, n)
    if TextLen(s) <= n then return s end
    if utf8.len(s) then return s:sub(1, utf8.offset(s, n + 1) - 1) end
    local cut = n
    while cut > 0 and (s:byte(cut + 1) or 0) >= 0x80 and s:byte(cut + 1) < 0xC0 do cut = cut - 1 end
    return s:sub(1, cut)
end

local function IsList(t)
    if type(t) ~= 'table' then return false end
    local n = #t
    for k in pairs(t) do
        if type(k) ~= 'number' or k < 1 or k > n or k % 1 ~= 0 then return false end
    end
    return true
end

local function IsVecTable(t)
    local ty = type(t)
    if ty == 'vector3' or ty == 'vector4' then return true end
    if ty ~= 'table' then return false end
    if not (IsNum(t.x) and IsNum(t.y) and IsNum(t.z)) then return false end
    for k in pairs(t) do
        if k ~= 'x' and k ~= 'y' and k ~= 'z' and k ~= 'w' then return false end
    end
    return t.w == nil or IsNum(t.w)
end

local function HasW(v)
    if type(v) == 'vector4' then return true end
    return type(v) == 'table' and v.w ~= nil
end

local function IsPayoutField(k)
    if type(k) ~= 'string' then return false end
    local lower = k:lower()
    return lower:find('payout', 1, true) ~= nil or PAYOUT_NAMES[lower] == true
end

-- A payout field at any depth (a mission file has none, not even inside an objective or a location).
local function HadPayout(input, depth)
    depth = depth or 1
    if type(input) ~= 'table' or depth > MAX_DEPTH then return false end
    for k, v in pairs(input) do
        if IsPayoutField(k) or HadPayout(v, depth + 1) then return true end
    end
    return false
end

-- Removes the payout fields at any depth; onField(path) is called for each one removed.
local function StripPayout(t, onField, path, depth)
    depth = depth or 1
    if type(t) ~= 'table' or depth > MAX_DEPTH then return end
    for _, k in ipairs(U.keys(t)) do
        local p = path and (path .. '.' .. tostring(k)) or tostring(k)
        if IsPayoutField(k) then
            t[k] = nil
            if onField then onField(p) end
        else
            StripPayout(t[k], onField, p, depth + 1)
        end
    end
end

local function Now() return os.time() end

local function TierRows() return Config.Scaling or {} end
local function TierFor(n)
    if CP.Scaling and CP.Scaling.tierFor then return CP.Scaling.tierFor(n) end
    local rows = TierRows()
    for _, row in ipairs(rows) do
        if (row.maxParticipants or 0) >= n then return row end
    end
    return rows[#rows]
end
local function TierIndex(name)
    for i, row in ipairs(TierRows()) do
        if row.tier == name then return i end
    end
    return nil
end
local function RequiredTierName(maxOfficers)
    local n = tonumber(maxOfficers) or 1
    local row = TierFor(math.max(1, math.floor(n)))
    return row and row.tier or nil
end

-- Canonical text of a value (sorted keys) for a content hash.
local function Canonical(v, out)
    local t = type(v)
    if t == 'vector3' or t == 'vector4' or t == 'vector2' then v = U.vecToTable(v); t = 'table' end
    if t == 'number' then
        out[#out + 1] = 'n'
            .. ((v == math.floor(v) and math.abs(v) < 2 ^ 53) and ('%d'):format(v) or ('%.10g'):format(v))
        return
    end
    if t ~= 'table' then out[#out + 1] = t:sub(1, 1) .. tostring(v); return end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) == type(b) and (type(a) == 'number' or type(a) == 'string') then return a < b end
        return type(a) < type(b)
    end)
    out[#out + 1] = '{'
    for _, k in ipairs(keys) do
        out[#out + 1] = tostring(k) .. '='
        Canonical(v[k], out)
        out[#out + 1] = ','
    end
    out[#out + 1] = '}'
end

local function DefHash(def)
    if def == nil then return nil end
    local out = {}
    Canonical(def, out)
    return U.hashHex(table.concat(out))
end

-- Walk a dotted path with '*' for every list element; fn(parent, key, value) for each existing leaf.
local function EachPath(root, path, fn)
    local parts = {}
    for p in path:gmatch('[^%.]+') do parts[#parts + 1] = p end
    local function walk(node, i)
        if type(node) ~= 'table' then return end
        local part = parts[i]
        if part == '*' then
            for idx = 1, #node do
                if i == #parts then
                    if node[idx] ~= nil then fn(node, idx, node[idx]) end
                else
                    walk(node[idx], i + 1)
                end
            end
            return
        end
        local key = tonumber(part) or part
        if i == #parts then
            if node[key] ~= nil then fn(node, key, node[key]) end
        else
            walk(node[key], i + 1)
        end
    end
    walk(root, 1)
end

local function L(key, vars) return CP.L(key, vars) end

-- Labels owned by other slices (scoring: bonus.<id> / penalty.<id>; scaling: tier.<name>).
local function BonusLabel(id, penalty)
    local key = (penalty and 'penalty.' or 'bonus.') .. tostring(id)
    if CP.Locale and CP.Locale.has and CP.Locale.has(key) then return CP.L(key) end
    return tostring(id)
end
local function TierLabel(name)
    if CP.Scaling and CP.Scaling.label then return CP.Scaling.label(name) end
    return tostring(name)
end

-- ============================================================================
--                                   DATABASE
-- ============================================================================

local ROW_COLUMNS = [[id, mission_type, status, published_version, published_definition, draft_version,
    draft_definition, draft_tested, file_path, edited_in_code, locked_by,
    UNIX_TIMESTAMP(locked_until) AS locked_until_ts,
    TIMESTAMPDIFF(SECOND, NOW(), locked_until) AS lock_left, created_by, updated_by,
    UNIX_TIMESTAMP(updated_at) AS updated_at_ts]]

local function RowOf(r)
    if type(r) ~= 'table' or r.id == nil then return nil end
    local lockLeft = tonumber(r.lock_left)
    local lockedBy = r.locked_by
    if lockedBy == '' then lockedBy = nil end
    return {
        id = tostring(r.id),
        missionType = r.mission_type,
        status = r.status or 'draft',
        publishedVersion = tonumber(r.published_version),
        published = U.jsonField(r.published_definition),
        draftVersion = tonumber(r.draft_version),
        draft = U.jsonField(r.draft_definition),
        draftTested = U.truthy(r.draft_tested),
        filePath = (r.file_path ~= nil and r.file_path ~= '') and tostring(r.file_path) or nil,
        editedInCode = U.truthy(r.edited_in_code),
        lockedBy = lockedBy and tostring(lockedBy) or nil,
        lockLeft = lockLeft,
        lockActive = lockedBy ~= nil and lockLeft ~= nil and lockLeft > 0,
        createdBy = tostring(r.created_by or ''),
        updatedBy = tostring(r.updated_by or ''),
        updatedAt = tonumber(r.updated_at_ts) or 0,
    }
end

local function FetchRow(id)
    CP.Migrations.ready()
    local r = MySQL.single.await('SELECT ' .. ROW_COLUMNS .. ' FROM cp_custom_missions WHERE id = ?', { id })
    return RowOf(r)
end

local function FetchRows(where, params)
    CP.Migrations.ready()
    local sql = 'SELECT ' .. ROW_COLUMNS .. ' FROM cp_custom_missions'
    if where then sql = sql .. ' WHERE ' .. where end
    sql = sql .. ' ORDER BY updated_at DESC, id ASC'
    local rows = MySQL.query.await(sql, params or {}) or {}
    local out = {}
    for _, r in ipairs(rows) do
        local row = RowOf(r)
        if row then out[#out + 1] = row end
    end
    return out
end

local function Encode(t)
    if t == nil then return nil end
    return json.encode(U.serialize(t))
end

local function DisplayNames(ids)
    local list, seen = {}, {}
    for _, id in ipairs(ids) do
        if type(id) == 'string' and id ~= '' and id ~= 'console' and not seen[id] then
            seen[id] = true
            list[#list + 1] = id
        end
    end
    local out = {}
    if #list == 0 then return out end
    local marks = {}
    for i = 1, #list do marks[i] = '?' end
    local rows = MySQL.query.await(
        'SELECT citizenid, display_name FROM cp_officers WHERE citizenid IN (' .. table.concat(marks, ', ') .. ')',
        list) or {}
    for _, r in ipairs(rows) do
        if r.citizenid then out[tostring(r.citizenid)] = r.display_name and tostring(r.display_name) or nil end
    end
    return out
end

local function IdTaken(id)
    if CP.Missions and CP.Missions.get and CP.Missions.get(id) then return true end
    CP.Migrations.ready()
    local hit = MySQL.scalar.await('SELECT 1 AS taken FROM cp_custom_missions WHERE id = ? LIMIT 1', { id })
    return hit ~= nil
end

-- ============================================================================
--                                    FILES
-- ============================================================================

local function ReadFile(path)
    if type(path) ~= 'string' then return nil end
    local ok, content = pcall(LoadResourceFile, CP.resource, path)
    if ok and type(content) == 'string' and content ~= '' then return content end
    return nil
end

-- SaveResourceFile does not create folders, and a fresh clone may not have missions/custom/ or its
-- archived/ folder: create a missing folder (under the resource) before the first write into it.
-- A folder is there when a probe file can be written into it, as in CP.Storage: os.rename's answer cannot be
-- read (FXServer's Linux build returns it inverted), and FXServer refuses os.execute but has os.createdir.
local function DirWritable(abs)
    local probe = abs .. '/.cp-write-test'
    local f = io.open(probe, 'wb')
    if not f then return false end
    f:close()
    os.remove(probe)
    return true
end

local function EnsureDir(rel)
    if type(rel) ~= 'string' or rel == '' then return false end
    if not rel:match('^[%w_%-%./]+$') or rel:find('..', 1, true) or rel:sub(1, 1) == '/' then
        CP.err(TAG, 'refusing to create the export folder %q (only letters, digits, _ - . / are allowed)', rel)
        return false
    end
    if type(GetResourcePath) ~= 'function' then return false end
    local okBase, base = pcall(GetResourcePath, CP.resource)
    if not okBase or type(base) ~= 'string' or base == '' then return false end
    local abs = base .. '/' .. rel:gsub('/+$', '')
    if DirWritable(abs) then return true end
    if os.createdir then
        -- one folder per call: the parents first
        local path = base
        for part in rel:gmatch('[^/]+') do
            path = path .. '/' .. part
            pcall(os.createdir, path)
        end
    else
        local windows = package and package.config and package.config:sub(1, 1) == '\\'
        local cmd = windows and ('mkdir "%s" >NUL 2>&1'):format((abs:gsub('/', '\\')))
            or ('mkdir -p \'%s\' >/dev/null 2>&1'):format(abs)
        pcall(os.execute, cmd)
    end
    if DirWritable(abs) then
        CP.log(TAG, 'created the missing folder %s', rel)
        return true
    end
    CP.err(TAG,
        'the folder %s is missing and could not be created: create it by hand, or publishing and archiving fail', rel)
    return false
end

local function EnsureExportDirs()
    local a = EnsureDir(ExportDir())
    local b = EnsureDir(ExportDir() .. 'archived/')
    return a and b
end
B.ensureExportDirs = EnsureExportDirs

local function SaveOnce(path, content)
    local ok, res = pcall(SaveResourceFile, CP.resource, path, content, -1)
    if not ok then return false, tostring(res) end
    return res ~= false, nil
end

local function WriteFile(path, content)
    local ok, why = SaveOnce(path, content)
    if not ok then
        -- most likely a missing folder: create it and try once more
        local dir = type(path) == 'string' and path:match('^(.*)/[^/]*$') or nil
        if dir and EnsureDir(dir .. '/') then ok, why = SaveOnce(path, content) end
    end
    if not ok then
        if why then CP.err(TAG, 'could not write %s: %s', path, why) else CP.err(TAG, 'could not write %s', path) end
        return false
    end
    return true
end

local function RemoveFile(path)
    if type(GetResourcePath) ~= 'function' then return false end
    local okBase, base = pcall(GetResourcePath, CP.resource)
    if not okBase or type(base) ~= 'string' or base == '' then return false end
    local ok, res, err = pcall(os.remove, base .. '/' .. path)
    if not ok or not res then
        CP.log(TAG, 'could not remove %s: %s', path, tostring(err or res))
        return false
    end
    return true
end

local function CopyLib(lib)
    local out = {}
    for k, v in pairs(lib) do out[k] = v end
    return out
end

-- The mission loader sandbox (ARCHITECTURE §5.6): CP.Missions.parse when it exists, else the same rules.
function B.parse(content, chunkName)
    if CP.Missions and CP.Missions.parse then return CP.Missions.parse(content, chunkName) end
    if type(content) ~= 'string' or content == '' then return nil, 'the file is empty' end
    local collected = {}
    local env = {
        RegisterMission = function(def) collected[#collected + 1] = def end,
        vec3 = vec3 or vector3,
        vec4 = vec4 or vector4,
        vector3 = vector3,
        vector4 = vector4,
        math = CopyLib(math),
        string = CopyLib(string),
        table = CopyLib(table),
        pairs = pairs,
        ipairs = ipairs,
        tonumber = tonumber,
        tostring = tostring,
        type = type,
    }
    local chunk, err = load(content, '@' .. tostring(chunkName or 'mission'), 't', env)
    if not chunk then return nil, 'syntax error: ' .. tostring(err) end
    local ok, runErr = pcall(chunk)
    if not ok then return nil, 'error while running the file: ' .. tostring(runErr) end
    if #collected ~= 1 then
        return nil, ('the file must call RegisterMission exactly once (found %d)'):format(#collected)
    end
    if type(collected[1]) ~= 'table' then return nil, 'RegisterMission expects a table' end
    return collected[1]
end

-- ============================================================================
--                               UNIT CONVERSION
-- ============================================================================

local function BonusCfg(id) return Config.Bonuses and Config.Bonuses[id] or nil end

local function RenameFields(obj)
    local map = type(obj) == 'table' and RENAMED_FIELDS[obj.block] or nil
    if not map then return obj end
    for old, new in pairs(map) do
        if obj[old] ~= nil then
            if obj[new] == nil then obj[new] = obj[old] end
            obj[old] = nil
        end
    end
    return obj
end

local function RenameAll(def)
    for _, obj in ipairs(type(def) == 'table' and type(def.objectives) == 'table' and def.objectives or {}) do
        RenameFields(obj)
    end
    return def
end

local function ConvertObjective(obj, toFile)
    RenameFields(obj)
    local blockId = obj.block
    for _, path in ipairs(PERCENT_FIELDS[blockId] or {}) do
        EachPath(obj, path, function(parent, key, v)
            if IsNum(v) then
                if toFile then parent[key] = v / 100 else parent[key] = RoundInt(v * 100) end
            end
        end)
    end
    for _, path in ipairs(SECONDS_FIELDS[blockId] or {}) do
        EachPath(obj, path, function(parent, key, v)
            if IsNum(v) then
                if toFile then parent[key] = RoundInt(v * 1000) else parent[key] = v / 1000 end
            end
        end)
    end
end

local function BonusesToFile(list)
    local out = {}
    for _, e in ipairs(type(list) == 'table' and list or {}) do
        if type(e) == 'table' and type(e.id) == 'string' then
            local c = BonusCfg(e.id)
            local entry = { id = e.id }
            if c and c.kind == 'pct' then
                local pct = IsNum(e.pct) and e.pct or (IsNum(c.value) and c.value * 100 or 0)
                entry.pctOfPoints = pct / 100
            else
                entry.points = IsNum(e.points) and e.points or (c and c.value) or 0
            end
            if c and c.each then entry.each = true end
            out[#out + 1] = entry
        end
    end
    return out
end

local function BonusesFromFile(list)
    local out = {}
    for _, e in ipairs(type(list) == 'table' and list or {}) do
        if type(e) == 'table' and type(e.id) == 'string' then
            local c = BonusCfg(e.id)
            local entry = { id = e.id }
            if (c and c.kind == 'pct') or (not c and IsNum(e.pctOfPoints)) then
                if IsNum(e.pctOfPoints) then entry.pct = RoundInt(e.pctOfPoints * 100) end
            elseif IsNum(e.points) then
                entry.points = e.points
            end
            out[#out + 1] = entry
        end
    end
    return out
end

-- Builder units -> mission-file units (vectors stay { x, y, z[, w] } tables).
function B.toFileUnits(def)
    local d = U.deepcopy(U.serialize(def))
    for _, k in ipairs(LOADER_FIELDS) do d[k] = nil end
    for _, obj in ipairs(type(d.objectives) == 'table' and d.objectives or {}) do
        if type(obj) == 'table' then ConvertObjective(obj, true) end
    end
    d.bonuses = BonusesToFile(d.bonuses)
    d.penalties = BonusesToFile(d.penalties)
    return d
end

-- Mission-file units (a parsed file or a runtime definition) -> builder units.
function B.fromFileUnits(fileDef)
    local d = U.deepcopy(U.serialize(fileDef))
    for _, k in ipairs(LOADER_FIELDS) do d[k] = nil end
    for _, obj in ipairs(type(d.objectives) == 'table' and d.objectives or {}) do
        if type(obj) == 'table' then ConvertObjective(obj, false) end
    end
    d.bonuses = BonusesFromFile(d.bonuses)
    d.penalties = BonusesFromFile(d.penalties)
    return d
end

-- Vector tables -> vec3/vec4 (for block validate, CP.Missions and test runs).
function B.toRuntime(v)
    if IsVecTable(v) then
        if type(v) ~= 'table' then return v end
        return U.tableToVec(v)
    end
    if type(v) ~= 'table' then return v end
    local out = {}
    for k, val in pairs(v) do out[k] = B.toRuntime(val) end
    return out
end

-- Objective-level bonus fields of the blocks, made fit for a custom mission (a duplicate of a built-in):
-- the blocks' validate() lets custom missions use only Config.Bonuses ids (or the block's own default id)
-- and never a value written in the file, so built-in ids and values are dropped here and the block
-- defaults apply (flee_arrest aliveBonus, hostile_waves boss.aliveBonus, pursuit detainBonus /
-- allDetainedBonus / fastStop / ramPenaltyId, interact_points fastBonus). Changes def in place.
local BOSS_BONUS_ID = 'kingpin_alive'
local FAST_STOP_MAX = 120
function B.customBonusFields(def)
    for _, obj in ipairs(type(def) == 'table' and type(def.objectives) == 'table' and def.objectives or {}) do
        if type(obj) == 'table' then
            if obj.block == 'flee_arrest' and type(obj.aliveBonus) == 'table' then
                local ab = obj.aliveBonus
                ab.points, ab.pctOfPoints, ab.each = nil, nil, nil
                if not BonusCfg(ab.id) then obj.aliveBonus = nil end
            elseif obj.block == 'hostile_waves' and type(obj.boss) == 'table'
                and type(obj.boss.aliveBonus) == 'table' then
                local ab = obj.boss.aliveBonus
                ab.points, ab.pctOfPoints, ab.each = nil, nil, nil
                if ab.id ~= BOSS_BONUS_ID and not BonusCfg(ab.id) then obj.boss.aliveBonus = nil end
            elseif obj.block == 'pursuit' then
                for _, k in ipairs({ 'detainBonus', 'allDetainedBonus', 'ramPenaltyId' }) do
                    if type(obj[k]) == 'string' and not BonusCfg(obj[k]) then obj[k] = nil end
                end
                local fs = obj.fastStop
                if type(fs) == 'table' then
                    if type(fs.id) == 'string' and not BonusCfg(fs.id) then fs.id = nil end
                    if IsNum(fs.seconds) and fs.seconds > FAST_STOP_MAX then fs.seconds = FAST_STOP_MAX end
                end
            elseif obj.block == 'interact_points' and type(obj.fastBonus) == 'table' then
                if not BonusCfg(obj.fastBonus.id) then obj.fastBonus = nil end
            end
        end
    end
    return def
end

-- ============================================================================
--                       SANITISING (what may be stored)
-- ============================================================================

local function CleanValue(v, depth, budget)
    budget.n = budget.n + 1
    if budget.n > MAX_NODES then budget.over = true; return nil end
    local t = type(v)
    if t == 'string' then return ClipText(v, MAX_STRING) end
    if t == 'number' then return (IsNum(v) and math.abs(v) <= MAX_NUMBER) and v or nil end
    if t == 'boolean' then return v end
    if t == 'vector3' or t == 'vector4' or t == 'vector2' then v = U.vecToTable(v); t = 'table' end
    if t ~= 'table' then return nil end
    if depth > MAX_DEPTH then budget.over = true; return nil end
    if IsVecTable(v) then
        local out = { x = Round(v.x, 2), y = Round(v.y, 2), z = Round(v.z, 2) }
        if v.w ~= nil then out.w = Round(v.w, 2) end
        return out
    end
    local out = {}
    if IsList(v) then
        for i = 1, #v do
            local c = CleanValue(v[i], depth + 1, budget)
            if c ~= nil then out[#out + 1] = c end
        end
        return out
    end
    for k, val in pairs(v) do
        if type(k) == 'string' and #k <= MAX_KEY and k:match('^[%a_][%w_]*$') then
            local c = CleanValue(val, depth + 1, budget)
            if c ~= nil then out[k] = c end
        end
    end
    return out
end

-- Returns a builder definition that is safe to store (bounded, rounded, no loader or payout fields,
-- explicit bonus values), or nil and an error key. info = { payout = bool }.
function B.sanitize(input, id)
    if type(input) ~= 'table' then return nil, 'err.invalid_payload' end
    local budget = { n = 0, over = false }
    local d = CleanValue(input, 1, budget)
    if budget.over then return nil, 'err.builder_too_large' end
    if type(d) ~= 'table' then return nil, 'err.invalid_payload' end
    local info = { payout = HadPayout(input) }
    for _, k in ipairs(LOADER_FIELDS) do d[k] = nil end
    StripPayout(d)
    if id ~= nil then d.id = id end
    if type(d.description) == 'string' then d.description = ClipText(d.description, LIMITS.description) end
    if type(d.departments) == 'table' and not IsList(d.departments) then
        local list = {}
        for k, v in pairs(d.departments) do if v == true and type(k) == 'string' then list[#list + 1] = k end end
        table.sort(list)
        d.departments = list
    end
    for _, key in ipairs({ 'departments', 'locations', 'objectives', 'scaling', 'items', 'bonuses', 'penalties' }) do
        if d[key] == nil then d[key] = {} end
    end
    -- whole percent and millisecond-exact seconds, so the Lua file round-trips
    for _, obj in ipairs(type(d.objectives) == 'table' and d.objectives or {}) do
        if type(obj) == 'table' then
            RenameFields(obj)
            for _, path in ipairs(PERCENT_FIELDS[obj.block] or {}) do
                EachPath(obj, path, function(parent, key, v)
                    if IsNum(v) then parent[key] = RoundInt(v) end
                end)
            end
            for _, path in ipairs(SECONDS_FIELDS[obj.block] or {}) do
                EachPath(obj, path, function(parent, key, v)
                    if IsNum(v) then parent[key] = Round(v, 3) end
                end)
            end
            if obj.minSeconds == nil and DEFAULT_MIN_SECONDS[obj.block] then
                obj.minSeconds = DEFAULT_MIN_SECONDS[obj.block]
            end
            if obj.presenceRange == nil then
                local c = Config.Blocks and Config.Blocks[obj.block]
                if type(c) == 'table' and type(c.presenceRange) == 'table' then
                    obj.presenceRange = c.presenceRange[3]
                end
            end
        end
    end
    -- explicit bonus values (the config value when the builder left it out)
    for _, listKey in ipairs({ 'bonuses', 'penalties' }) do
        local list = d[listKey]
        if type(list) == 'table' then
            for _, e in ipairs(list) do
                if type(e) == 'table' and type(e.id) == 'string' then
                    local c = BonusCfg(e.id)
                    if c and c.kind == 'pct' then
                        e.points = nil
                        if not IsNum(e.pct) and IsNum(c.value) then e.pct = RoundInt(c.value * 100) end
                        if IsNum(e.pct) then e.pct = RoundInt(e.pct) end
                    elseif c then
                        e.pct = nil
                        if not IsNum(e.points) and IsNum(c.value) then e.points = c.value end
                        if IsNum(e.points) and listKey == 'penalties' and e.points > 0 then e.points = -e.points end
                    end
                    e.each = nil
                    e.pctOfPoints = nil
                end
            end
        end
    end
    return d, nil, info
end

-- ============================================================================
--                                  GUARDRAILS
-- ============================================================================

local function AddError(errors, path, key, vars, message)
    errors[#errors + 1] = { path = path, key = key, vars = vars, message = message or L(key, vars) }
end

-- Every vector in a location value, with a sub-path for messages.
local function CollectPoints(v, out)
    if IsVecTable(v) then out[#out + 1] = v; return end
    if type(v) ~= 'table' then return end
    if IsVecTable(v.coords) then out[#out + 1] = v.coords end
    if type(v.points) == 'table' then CollectPoints(v.points, out) end
    for i = 1, #v do CollectPoints(v[i], out) end
end

local function IsRoute(v)
    return type(v) == 'table' and not IsVecTable(v) and type(v.points) == 'table' and #v.points > 0
        and IsVecTable(v.points[1])
end

local function ZoneOf(p)
    for _, z in ipairs(CfgB().noBuildZones or {}) do
        if z.coords and U.dist2d(p, z.coords) <= (tonumber(z.radius) or 0) then return z end
    end
    return nil
end

local function RouteLength(points)
    local len = 0.0
    for i = 2, #points do len = len + U.dist(points[i - 1], points[i]) end
    return len
end

local function CheckRoute(errors, route, path, li, key)
    local r = CfgB().route or {}
    local pts = route.points
    local vars = { key = key, location = li }
    if #pts < 2 or #pts > MAX_ROUTE_POINTS then
        AddError(errors, path .. '.points', 'builder.error.route_points',
            { key = key, location = li, max = MAX_ROUTE_POINTS })
        return
    end
    for _, p in ipairs(pts) do
        if not IsVecTable(p) then
            AddError(errors, path .. '.points', 'builder.error.route_points',
                { key = key, location = li, max = MAX_ROUTE_POINTS })
            return
        end
    end
    local len = RouteLength(pts)
    if len < (r.minLength or 800) or len > (r.maxLength or 8000) then
        AddError(errors, path, 'builder.error.route_length', {
            key = key,
            location = li,
            min = Nice(Round((r.minLength or 800) / 1000, 1)),
            max = Nice(Round((r.maxLength or 8000) / 1000, 1)),
            length = Nice(Round(len / 1000, 2)),
        })
    end
    local gap = U.dist2d(pts[1], pts[#pts])
    if route.loop == true then
        if gap > (r.loopClose or 50) then
            AddError(errors, path, 'builder.error.route_loop',
                { key = key, location = li, max = Nice(r.loopClose or 50) })
        end
    elseif gap < (r.minStartEndGap or 300) then
        AddError(errors, path, 'builder.error.route_gap',
            { key = key, location = li, min = Nice(r.minStartEndGap or 300) })
    end
    if route.stops ~= nil then
        local esc = Config.Blocks and Config.Blocks.escort or {}
        local maxStops = type(esc.stops) == 'table' and esc.stops[2] or 5
        local waitR = type(esc.stopWait) == 'table' and esc.stopWait or { 10, 60 }
        local ok = type(route.stops) == 'table' and #route.stops <= maxStops
        if ok then
            for _, s in ipairs(route.stops) do
                if type(s) ~= 'table' or not IsInt(s.at) or s.at < 1 or s.at > #pts or not InRange(s.wait, waitR) then
                    ok = false
                end
            end
        end
        if not ok then
            AddError(errors, path .. '.stops', 'builder.error.route_stops',
                { key = key, location = li, max = maxStops, min = waitR[1], maxWait = waitR[2] })
        end
    end
    return vars
end

local function ItemForbidden(name)
    local lower = name:lower()
    if lower == 'armour' or lower == 'bandage' then return true end
    -- cash items would stand in for a payout
    if lower == 'money' or lower == 'black_money' then return true end
    if lower:sub(1, 5) == 'ammo-' then return true end
    if lower:sub(1, 7) == 'weapon_' then return true end
    return false
end

local function ItemKnown(name)
    if GetResourceState and GetResourceState('ox_inventory') ~= 'started' then return true end
    local ok, item = pcall(function() return exports.ox_inventory:Items(name) end)
    if not ok then
        return true
    end -- cannot check: ox_inventory decides when the item is given
    return item ~= nil
end

-- The item rules (CRIMSON_ARENA rule 4); B.validate and every test run check them.
local function ItemErrors(items, errors)
    if type(items) ~= 'table' or not IsList(items) then
        AddError(errors, 'items', 'builder.error.item_name', { n = 1 })
        return errors
    end
    if #items > MAX_ITEMS then AddError(errors, 'items', 'builder.error.max_items', { max = MAX_ITEMS }) end
    for i, it in ipairs(items) do
        local p = 'items.' .. i
        local name = type(it) == 'table' and it.name or nil
        if type(name) ~= 'string' or #name == 0 or #name > 50 or not name:match('^[%w_%-%.]+$') then
            AddError(errors, p .. '.name', 'builder.error.item_name', { n = i })
        elseif ItemForbidden(name) then
            AddError(errors, p .. '.name', 'builder.error.item_forbidden', { name = name })
        elseif not ItemKnown(name) then
            AddError(errors, p .. '.name', 'builder.error.item_unknown', { name = name })
        end
        if type(it) ~= 'table' or not IsInt(it.count) or not InRange(it.count, ITEM_COUNT) then
            AddError(errors, p .. '.count', 'builder.error.item_count',
                { n = i, min = ITEM_COUNT[1], max = ITEM_COUNT[2] })
        end
    end
    return errors
end

local function EffectiveObjective(impl, rtObj)
    if impl and type(impl.defaults) == 'function' then
        local ok, res = pcall(impl.defaults, U.deepcopy(rtObj))
        if ok and type(res) == 'table' then return res end
    end
    return U.deepcopy(rtObj)
end

-- The counts each block lets a custom mission scale with the tier (SPEC Scaling: only counts marked
-- "scales"; mirrors web/src/builder/schema.ts scalables, plus interact_points' hidden devices). Anything
-- else (accuracy, armour, penalties, timers, distances, points...) is refused, because a scaled value is
-- never re-checked against the block ranges.
local SCALABLE_FIELDS = {
    hostile_waves = { waves = true },
    escort = { ['ambush.waves'] = true, ['ambush.carsPerWave'] = true, ['ambush.perCar'] = true },
    pursuit = { vehicles = true, suspectsPerVehicle = true },
    protect_rescue = { count = true },
    flee_arrest = { suspects = true, ['associates.count'] = true },
    search_area = { fugitives = true },
    interact_points = { count = true, ['hidden.count'] = true },
    checkpoint_route = { count = true },
}
B.SCALABLE_FIELDS = SCALABLE_FIELDS

local function Scalable(v)
    if IsNum(v) then return true end
    if type(v) ~= 'table' or #v == 0 then return false end
    for _, x in ipairs(v) do if not IsNum(x) then return false end end
    return true
end

-- The search circle a mission's start marker must match: the first search_area objective's startRadius (its
-- block default when the objective has none). The run of such a mission starts when a participant enters the
-- search circle (Manhunt: "the run starts when the first participant enters it"), so every location's start
-- radius must equal that startRadius and is checked against Config.Blocks.search_area.startRadius instead of
-- START_RADIUS. nil when the mission has no search_area objective.
-- Returns { index, radius, range } (range = { min, max, default }).
local function SearchCircle(rtObjectives)
    for i, obj in ipairs(type(rtObjectives) == 'table' and rtObjectives or {}) do
        if type(obj) == 'table' and obj.block == 'search_area' then
            local c = Config.Blocks and Config.Blocks.search_area or {}
            local range = type(c.startRadius) == 'table' and c.startRadius or { 200, 1000, 600 }
            local eff = EffectiveObjective(CP.Blocks.get('search_area'), obj)
            local radius = eff.startRadius
            if radius == nil then radius = range[3] end
            return { index = i, radius = IsNum(radius) and radius or nil, range = range }
        end
    end
    return nil
end
-- Returns errors (list of { path, key, vars, message }) and info { armed, requiredTier }.
-- opts.publish additionally runs CP.Missions.normalize (the loader's own checks); opts.raw is the
-- unsanitised input (payout fields).
function B.validate(def, opts)
    opts = opts or {}
    local errors = {}
    local info = { armed = 0, requiredTier = nil }
    if type(def) ~= 'table' then
        AddError(errors, '', 'builder.error.definition')
        return errors, info
    end
    local d = Details()
    local bc = CfgB()

    -- details
    if HadPayout(opts.raw) or HadPayout(def) then AddError(errors, 'payout', 'builder.error.payout_field') end
    if type(def.label) ~= 'string' or U.trim(def.label) == '' or TextLen(def.label) > LIMITS.label then
        AddError(errors, 'label', 'builder.error.label', { max = LIMITS.label })
    end
    if def.description ~= nil and (type(def.description) ~= 'string' or TextLen(def.description) > LIMITS.description) then
        AddError(errors, 'description', 'builder.error.description', { max = LIMITS.description })
    end
    if type(def.type) ~= 'string' or not (Config.MissionTypes and Config.MissionTypes[def.type]) then
        AddError(errors, 'type', 'builder.error.type_required')
    end
    local deptOk = type(def.departments) == 'table' and IsList(def.departments)
    if deptOk then
        local seen = {}
        for _, k in ipairs(def.departments) do
            if type(k) ~= 'string' or not (Config.Departments and Config.Departments[k]) or seen[k] then
                deptOk = false
            end
            if type(k) == 'string' then seen[k] = true end
        end
    end
    if not deptOk then AddError(errors, 'departments', 'builder.error.departments') end
    local off = d.officers or { 1, 4 }
    if
        not (
            IsInt(def.minOfficers)
            and IsInt(def.maxOfficers)
            and InRange(def.minOfficers, off)
            and InRange(def.maxOfficers, off)
            and def.minOfficers <= def.maxOfficers
        )
    then
        AddError(errors, 'maxOfficers', 'builder.error.officers', { min = off[1], max = off[2] })
    end
    local stars = d.difficulty or { 1, 3 }
    if not (IsInt(def.difficulty) and InRange(def.difficulty, stars)) then
        AddError(errors, 'difficulty', 'builder.error.difficulty', { min = stars[1], max = stars[2] })
    end
    local tl = d.timeLimit or { 120, 1200 }
    if not (IsNum(def.timeLimit) and InRange(def.timeLimit, tl)) then
        AddError(errors, 'timeLimit', 'builder.error.time_limit', { min = Minutes(tl[1]), max = Minutes(tl[2]) })
    end
    local st = d.startTimeout or { 300, 900 }
    if not (IsNum(def.startTimeout) and InRange(def.startTimeout, st)) then
        AddError(errors, 'startTimeout', 'builder.error.start_timeout', { min = Minutes(st[1]), max = Minutes(st[2]) })
    end
    local cd = d.cooldown or { 300, 3600 }
    if not (IsNum(def.cooldown) and InRange(def.cooldown, cd)) then
        AddError(errors, 'cooldown', 'builder.error.cooldown', { min = Minutes(cd[1]), max = Minutes(cd[2]) })
    end
    if type(def.vehiclePenalties) ~= 'boolean' then
        AddError(errors, 'vehiclePenalties', 'builder.error.vehicle_penalties')
    end
    if IsInt(def.maxOfficers) then info.requiredTier = RequiredTierName(def.maxOfficers) end

    -- the runtime form (file units + vec3/vec4) that blocks and the loader validate
    local rt = B.toRuntime(B.toFileUnits(def))
    rt.source = 'custom'
    local locations = (type(def.locations) == 'table' and IsList(def.locations)) and def.locations or {}
    local rtLocations = type(rt.locations) == 'table' and rt.locations or {}

    -- objectives
    local objectives = (type(def.objectives) == 'table' and IsList(def.objectives)) and def.objectives or nil
    local maxBlocks = tonumber(bc.maxBlocks) or 6
    if not objectives or #objectives == 0 then
        AddError(errors, 'objectives', 'builder.error.no_objectives')
        objectives = {}
    elseif #objectives > maxBlocks then
        AddError(errors, 'objectives', 'builder.error.max_blocks', { max = maxBlocks })
    end
    local minTotal = 0
    local spawnKeys = {}   -- location key -> true
    local armed = 0
    local blockIds = {}
    for i, obj in ipairs(objectives) do
        local path = 'objectives.' .. i
        if type(obj) ~= 'table' then
            AddError(errors, path, 'builder.error.unknown_block', { n = i })
        else
            local blockId = obj.block
            local impl = type(blockId) == 'string' and CP.Blocks.get(blockId) or nil
            local bcfg = type(blockId) == 'string' and blockId ~= 'details' and Config.Blocks and Config.Blocks[blockId]
                or nil
            if not impl or type(bcfg) ~= 'table' then
                AddError(errors, path .. '.block', 'builder.error.unknown_block', { n = i })
            else
                blockIds[blockId] = true
                if type(obj.label) ~= 'string' or U.trim(obj.label) == ''
                    or TextLen(obj.label) > LIMITS.objectiveLabel then
                    AddError(errors, path .. '.label', 'builder.error.objective_label',
                        { n = i, max = LIMITS.objectiveLabel })
                end
                if not IsNum(obj.minSeconds) or obj.minSeconds < 1 then
                    AddError(errors, path .. '.minSeconds', 'builder.error.min_seconds', { n = i })
                else
                    minTotal = minTotal + obj.minSeconds
                end
                if type(bcfg.presenceRange) == 'table' and not InRange(obj.presenceRange, bcfg.presenceRange) then
                    AddError(errors, path .. '.presenceRange', 'builder.error.presence_range',
                        { n = i, min = bcfg.presenceRange[1], max = bcfg.presenceRange[2] })
                end
                local rtObj = type(rt.objectives) == 'table' and rt.objectives[i] or B.toRuntime(obj)
                local eff = EffectiveObjective(impl, rtObj)
                -- block guardrails (the per-block authority), once per location
                if type(impl.validate) == 'function' then
                    local seen = {}
                    local locs = #rtLocations > 0 and rtLocations or { false }
                    for li, loc in ipairs(locs) do
                        local okCall, res, reason = pcall(impl.validate, rtObj, rt, loc or nil)
                        if not okCall then
                            AddError(errors, path, nil, nil,
                                L('builder.error.block_failed', { n = i, reason = tostring(res) }))
                        elseif res ~= true then
                            local msg = tostring(reason or L('builder.error.block_invalid', { n = i }))
                            if not seen[msg] then
                                seen[msg] = true
                                AddError(errors, path, nil, { n = i, location = li }, msg)
                            end
                        end
                    end
                end
                -- required points in every location
                if type(impl.requiredPoints) == 'function' then
                    local okCall, keys = pcall(impl.requiredPoints, rtObj)
                    if okCall and type(keys) == 'table' then
                        for _, key in ipairs(keys) do
                            for li, loc in ipairs(locations) do
                                local v = type(loc) == 'table' and loc[key] or nil
                                local pts = {}
                                CollectPoints(v, pts)
                                if #pts == 0 then
                                    AddError(errors, ('locations.%d.%s'):format(li, key), 'builder.error.point_missing',
                                        { key = key, location = li, n = i })
                                end
                            end
                        end
                    end
                end
                -- armed NPC budget (block armedCount)
                if type(impl.armedCount) == 'function' then
                    local okCall, n = pcall(impl.armedCount, rtObj)
                    if okCall and IsNum(n) then armed = armed + n end
                end
                for _, field in ipairs(SPAWN_FIELDS[blockId] or {}) do
                    local key = U.getPath(eff, field)
                    if type(key) == 'string' then spawnKeys[key] = true end
                end
            end
        end
    end
    info.armed = armed
    local maxHostiles = tonumber(bc.maxHostiles) or 40
    if armed > maxHostiles then
        AddError(errors, 'objectives', 'builder.error.armed_budget', { max = maxHostiles, have = armed })
    end
    if IsNum(def.timeLimit) and minTotal > def.timeLimit then
        AddError(errors, 'objectives', 'builder.error.min_seconds_total', { total = minTotal, limit = def.timeLimit })
    end

    -- locations
    local minLoc = tonumber(bc.minLocations) or 3
    if not (type(def.locations) == 'table' and IsList(def.locations)) or #locations < minLoc then
        AddError(errors, 'locations', 'builder.error.min_locations', { min = minLoc, have = #locations })
    elseif #locations > MAX_LOCATIONS then
        AddError(errors, 'locations', 'builder.error.max_locations', { max = MAX_LOCATIONS })
    end
    local minFromStart = tonumber(bc.minSpawnFromStart) or 30
    local search = SearchCircle(rt.objectives)
    local starts = {}
    for li, loc in ipairs(locations) do
        local lp = 'locations.' .. li
        if type(loc) ~= 'table' then
            AddError(errors, lp, 'builder.error.start_missing', { location = li })
        else
            if loc.label ~= nil and (type(loc.label) ~= 'string' or TextLen(loc.label) > LIMITS.locationLabel) then
                AddError(errors, lp .. '.label', 'builder.error.location_label',
                    { location = li, max = LIMITS.locationLabel })
            end
            local start = loc.start
            local startCoords = type(start) == 'table' and IsVecTable(start.coords) and start.coords or nil
            if not startCoords then
                AddError(errors, lp .. '.start', 'builder.error.start_missing', { location = li })
            else
                starts[li] = startCoords
                if search then
                    -- the start marker is the search circle: exactly its startRadius, within the search_area range
                    if not InRange(start.radius, search.range) or not search.radius
                        or math.abs(start.radius - search.radius) > 1e-6 then
                        AddError(errors, lp .. '.start.radius', 'builder.error.start_radius_search', {
                            location = li,
                            n = search.index,
                            radius = Nice(search.radius or search.range[3]),
                            min = search.range[1],
                            max = search.range[2],
                        })
                    end
                elseif not InRange(start.radius, START_RADIUS) then
                    AddError(errors, lp .. '.start.radius', 'builder.error.start_radius',
                        { location = li, min = START_RADIUS[1], max = START_RADIUS[2] })
                end
                local z = ZoneOf(startCoords)
                if z then
                    AddError(errors, lp .. '.start', 'builder.error.point_zone',
                        { key = 'start', location = li, zone = tostring(z.label) })
                end
            end
            for _, key in ipairs(U.keys(loc)) do
                if key ~= 'label' and key ~= 'start' then
                    local v = loc[key]
                    local kp = lp .. '.' .. key
                    local pts = {}
                    CollectPoints(v, pts)
                    local badCoords, badZone, badStart = false, nil, false
                    for _, p in ipairs(pts) do
                        if math.abs(p.x) > COORD_LIMIT or math.abs(p.y) > COORD_LIMIT or p.z < Z_MIN or p.z > Z_MAX then
                            badCoords = true
                        end
                        badZone = badZone or ZoneOf(p)
                        if spawnKeys[key] and startCoords and U.dist(p, startCoords) < minFromStart then
                            badStart = true
                        end
                    end
                    if badCoords then
                        AddError(errors, kp, 'builder.error.point_coords', { key = key, location = li })
                    end
                    if badZone then
                        AddError(errors, kp, 'builder.error.point_zone',
                            { key = key, location = li, zone = tostring(badZone.label) })
                    end
                    if badStart then
                        AddError(errors, kp, 'builder.error.spawn_start',
                            { key = key, location = li, min = Nice(minFromStart) })
                    end
                    if IsRoute(v) then CheckRoute(errors, v, kp, li, key) end
                end
            end
        end
    end
    local gap = tonumber(bc.minLocationGap) or 100
    for a = 1, #locations do
        for b = a + 1, #locations do
            if starts[a] and starts[b] and U.dist2d(starts[a], starts[b]) < gap then
                AddError(errors, 'locations.' .. b .. '.start', 'builder.error.location_gap',
                    { a = a, b = b, min = Nice(gap) })
            end
        end
    end

    -- bonuses and penalties
    local cap = bc.bonusCap or { points = 50, share = 0.25 }
    local capPct = RoundInt((tonumber(cap.share) or 0.25) * 100)
    for _, listKey in ipairs({ 'bonuses', 'penalties' }) do
        local list = def[listKey]
        if type(list) ~= 'table' or not IsList(list) then
            AddError(errors, listKey, 'builder.error.bonus_unknown', { id = '?' })
        else
            local seen = {}
            for i, e in ipairs(list) do
                local p = listKey .. '.' .. i
                local c = type(e) == 'table' and type(e.id) == 'string' and BonusCfg(e.id) or nil
                if not c then
                    AddError(errors, p, 'builder.error.bonus_unknown',
                        { id = type(e) == 'table' and tostring(e.id) or '?' })
                else
                    local negative = c.kind ~= 'pct' and (tonumber(c.value) or 0) < 0
                    local label = BonusLabel(e.id, negative)
                    if seen[e.id] then AddError(errors, p, 'builder.error.bonus_duplicate', { bonus = label }) end
                    seen[e.id] = true
                    if (listKey == 'penalties') ~= negative then
                        AddError(errors, p, 'builder.error.bonus_sign', { bonus = label })
                    end
                    if c.kind == 'pct' then
                        if not IsNum(e.pct) or e.pct <= 0 or e.pct > capPct then
                            AddError(errors, p .. '.pct', 'builder.error.bonus_cap_pct',
                                { bonus = label, max = capPct })
                        end
                    else
                        local v = e.points
                        local capPts = tonumber(cap.points) or 50
                        if not IsNum(v) or v == 0 or math.abs(v) > capPts or (negative and v > 0)
                            or (not negative and v < 0) then
                            AddError(errors, p .. '.points', 'builder.error.bonus_cap_points',
                                { bonus = label, max = Nice(capPts) })
                        end
                    end
                    if c.block and not blockIds[c.block] then
                        AddError(errors, p, 'builder.error.bonus_block',
                            { bonus = label, block = L('builder.block.' .. c.block) })
                    end
                end
            end
        end
    end

    -- items (CRIMSON_ARENA rule 4)
    ItemErrors(def.items, errors)

    -- scaling paths
    if type(def.scaling) ~= 'table' or not IsList(def.scaling) then
        AddError(errors, 'scaling', 'builder.error.scaling_path', { n = 1 })
    else
        if #def.scaling > MAX_SCALING then
            AddError(errors, 'scaling', 'builder.error.max_scaling', { max = MAX_SCALING })
        end
        local effObjs = {}
        for i, obj in ipairs(type(rt.objectives) == 'table' and rt.objectives or {}) do
            local impl = type(obj) == 'table' and CP.Blocks.get(obj.block) or nil
            effObjs[i] = type(obj) == 'table' and EffectiveObjective(impl, obj) or obj
        end
        for i, entry in ipairs(def.scaling) do
            local p = 'scaling.' .. i
            local path = type(entry) == 'string' and entry or (type(entry) == 'table' and entry.path) or nil
            local rel = type(path) == 'string' and path:match('^objectives%.(%d+%..+)$') or nil
            local idx = rel and tonumber(rel:match('^(%d+)')) or nil
            if not rel or not idx or idx < 1 or idx > #effObjs then
                AddError(errors, p, 'builder.error.scaling_path', { n = i })
            elseif
                not (SCALABLE_FIELDS[type(effObjs[idx]) == 'table' and effObjs[idx].block or ''] or {})[rel:match(
                    '^%d+%.(.+)$'
                ) or '']
            then
                AddError(errors, p, 'builder.error.scaling_field', { n = i, path = path })
            elseif not Scalable(U.getPath(effObjs, rel)) then
                AddError(errors, p, 'builder.error.scaling_value', { n = i, path = path })
            elseif type(entry) == 'table' and entry.max ~= nil and not (IsNum(entry.max) and entry.max > 0) then
                AddError(errors, p .. '.max', 'builder.error.scaling_max', { n = i })
            end
        end
    end

    -- the loader's own checks (publish, tests and reloads)
    if opts.publish and #errors == 0 and CP.Missions and CP.Missions.normalize then
        local okCall, res, err = pcall(CP.Missions.normalize, rt, { source = 'custom', status = 'draft', version = 1 })
        if not okCall then
            AddError(errors, '', 'builder.error.not_playable', { reason = tostring(res) })
        elseif not res then
            AddError(errors, '', 'builder.error.not_playable', { reason = tostring(err) })
        end
    end
    return errors, info
end

-- ============================================================================
--                                  LUA EXPORT
-- ============================================================================

local function LuaString(s)
    s = tostring(s)
    local escaped = s:gsub('[%c\\\']', function(c)
        if c == '\\' then return '\\\\' end
        if c == '\'' then return '\\\'' end
        if c == '\n' then return '\\n' end
        if c == '\r' then return '\\r' end
        if c == '\t' then return '\\t' end
        return ('\\%03d'):format(c:byte())
    end)
    return '\'' .. escaped .. '\''
end

local function FmtNumber(v, key)
    if FRACTION_KEYS[key] then
        local s = ('%.2f'):format(v)
        if tonumber(s) == v then return s end
    end
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
        if FLOAT_KEYS[key] then return ('%d.0'):format(v) end
        return ('%d'):format(v)
    end
    local s = ('%.14g'):format(v)
    if tonumber(s) ~= v then s = ('%.17g'):format(v) end
    if not s:find('[%.eEn]') then s = s .. '.0' end
    return s
end

local function FmtCoord(v)
    local s = ('%.2f'):format(v)
    if tonumber(s) ~= v then
        s = ('%.14g'):format(v)
        if tonumber(s) ~= v then s = ('%.17g'):format(v) end
        if not s:find('[%.eEn]') then s = s .. '.0' end
        return s
    end
    s = s:gsub('0$', '')
    if s:sub(-1) == '.' then s = s .. '0' end
    if s == '-0.0' then s = '0.0' end
    return s
end

local function VecLiteral(v)
    if HasW(v) then
        return ('vec4(%s, %s, %s, %s)'):format(FmtCoord(v.x), FmtCoord(v.y), FmtCoord(v.z), FmtCoord(v.w))
    end
    return ('vec3(%s, %s, %s)'):format(FmtCoord(v.x), FmtCoord(v.y), FmtCoord(v.z))
end

local function KeyText(k)
    if type(k) == 'string' and k:match('^[%a_][%w_]*$') and not LUA_KEYWORDS[k] then return k end
    return '[' .. LuaString(k) .. ']'
end

local function SortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local oa, ob = ORDER[a] or 100000, ORDER[b] or 100000
        if oa ~= ob then return oa < ob end
        return tostring(a) < tostring(b)
    end)
    return keys
end

local InlineValue
local function InlineTable(t)
    if next(t) == nil then return '{}' end
    local parts = {}
    if IsList(t) then
        for i = 1, #t do parts[i] = InlineValue(t[i], nil) end
    else
        for _, k in ipairs(SortedKeys(t)) do parts[#parts + 1] = KeyText(k) .. ' = ' .. InlineValue(t[k], k) end
    end
    return '{ ' .. table.concat(parts, ', ') .. ' }'
end

InlineValue = function(v, key)
    local t = type(v)
    if t == 'string' then return LuaString(v) end
    if t == 'number' then return FmtNumber(v, key) end
    if t == 'boolean' then return tostring(v) end
    if IsVecTable(v) then return VecLiteral(v) end
    if t == 'table' then return InlineTable(v) end
    return 'nil'
end

-- A value that fits in `avail` columns stays inline; otherwise one entry per line.
local function BlockValue(v, key, indent, avail)
    local inl = InlineValue(v, key)
    if #inl <= avail or type(v) ~= 'table' or IsVecTable(v) or next(v) == nil then return inl end
    local pad = (' '):rep(indent + 2)
    local lines = { '{' }
    if IsList(v) then
        for i = 1, #v do
            lines[#lines + 1] = pad .. BlockValue(v[i], nil, indent + 2, WRAP - indent - 3) .. ','
        end
    else
        for _, k in ipairs(SortedKeys(v)) do
            local prefix = KeyText(k) .. ' = '
            lines[#lines + 1] = pad .. prefix .. BlockValue(v[k], k, indent + 2, WRAP - indent - 3 - #prefix) .. ','
        end
    end
    lines[#lines + 1] = (' '):rep(indent) .. '}'
    return table.concat(lines, '\n')
end

local function PadKey(k, width)
    if #k < width then return k .. (' '):rep(width - #k) end
    return k .. ' '
end

local function SafeHeaderText(s)
    s = tostring(s or ''):gsub('[%c]', ' ')
    -- gsub does not rescan its own output (']]]' -> '] ]]'): repeat until no ]] is left
    local n
    repeat
        s, n = s:gsub('%]%]', '] ]')
    until n == 0
    return s
end

-- Location keys in the order objectives reference them, then the rest alphabetically.
local function LocationKeyOrder(loc, objectives)
    local order, seen = {}, { label = true, start = true }
    local function add(k)
        if type(k) == 'string' and loc[k] ~= nil and not seen[k] then
            seen[k] = true
            order[#order + 1] = k
        end
    end
    for _, obj in ipairs(objectives or {}) do
        if type(obj) == 'table' then
            local impl = CP.Blocks.get(obj.block)
            if impl and type(impl.requiredPoints) == 'function' then
                local ok, keys = pcall(impl.requiredPoints, B.toRuntime(obj))
                if ok and type(keys) == 'table' then for _, k in ipairs(keys) do add(k) end end
            end
            for _, k in ipairs(SortedKeys(obj)) do
                if type(obj[k]) == 'string' then add(obj[k]) end
            end
        end
    end
    for _, k in ipairs(U.keys(loc)) do add(k) end
    return order
end

local function ObjectiveLine(obj)
    -- block, label, minSeconds first; presenceRange last (ORDER). Fields are joined on lines of at most
    -- WRAP columns; a field too long for a line of its own is written in block form.
    local keys = SortedKeys(obj)
    local lines, line = {}, '    {'
    for i, k in ipairs(keys) do
        local prefix = KeyText(k) .. ' = '
        local part = prefix .. InlineValue(obj[k], k)
        local tail = (i == #keys) and 3 or 1
        local sep = (i == 1) and ' ' or ', '
        if i == 1 or #line + #sep + #part + tail <= WRAP then
            line = line .. sep .. part
        elseif 6 + #part + tail <= WRAP then
            lines[#lines + 1] = line .. ','
            line = '      ' .. part
        else
            lines[#lines + 1] = line .. ','
            local blk = BlockValue(obj[k], k, 6, WRAP - 6 - #prefix - tail)
            local blkLines = {}
            for l in (blk .. '\n'):gmatch('(.-)\n') do blkLines[#blkLines + 1] = l end
            line = '      ' .. prefix .. blkLines[1]
            for j = 2, #blkLines do
                lines[#lines + 1] = line
                line = blkLines[j]
            end
        end
    end
    lines[#lines + 1] = line .. ' },'
    return table.concat(lines, '\n')
end

local function FormatStamp(ts)
    return os.date('%Y-%m-%d %H:%M', tonumber(ts) or Now())
end

local function AdminCommand()
    return '/' .. tostring((Config.Tablet and Config.Tablet.adminCommand) or 'CrimsonPoliceAdmin')
end

-- The mission file text in exactly the shape of the spec's custom example.
-- meta = { version, publisher, at, edited = text|nil }
function B.exportLua(def, meta)
    meta = meta or {}
    local f = B.toFileUnits(def)
    local lines = {}
    local function add(s) lines[#lines + 1] = s end
    add(HEADER_FIRST)
    add('  id:        ' .. SafeHeaderText(f.id))
    add('  version:   ' .. tostring(math.floor(tonumber(meta.version) or 1)))
    add(
        '  type:      ' .. SafeHeaderText(f.type)
            .. '   -- the payout comes from the Payouts screens, never from this file'
    )
    add('  published: ' .. FormatStamp(meta.at) .. ' by ' .. SafeHeaderText(meta.publisher or 'console'))
    if meta.edited then add('  edited:    ' .. SafeHeaderText(meta.edited)) end
    add('  Edit this file, then run: ' .. AdminCommand() .. ' reload')
    add(']]')
    add('')
    add('RegisterMission({')
    local function top(key, value, comment)
        local s = '  ' .. PadKey(key, 13) .. '= ' .. value .. ','
        if comment then
            if #s < 33 then s = s .. (' '):rep(33 - #s) else s = s .. ' ' end
            s = s .. comment
        end
        add(s)
    end
    top('id', LuaString(f.id or ''))
    top('label', LuaString(f.label or ''))
    top('description', LuaString(f.description or ''))
    top('type', LuaString(f.type or ''))
    top('departments', InlineValue(f.departments or {}, 'departments'), '-- empty = every department')
    top('minOfficers', InlineValue(f.minOfficers, 'minOfficers'))
    top('maxOfficers', InlineValue(f.maxOfficers, 'maxOfficers'))
    top('difficulty', InlineValue(f.difficulty, 'difficulty'))
    top('timeLimit', InlineValue(f.timeLimit, 'timeLimit'))
    top('vehiclePenalties', InlineValue(f.vehiclePenalties, 'vehiclePenalties'))
    top('startTimeout', InlineValue(f.startTimeout, 'startTimeout'))
    top('cooldown', InlineValue(f.cooldown, 'cooldown'))
    add('')
    add('  locations = {')
    for _, loc in ipairs(f.locations or {}) do
        add('    {')
        local keys = { 'label', 'start' }
        for _, k in ipairs(LocationKeyOrder(loc, f.objectives)) do keys[#keys + 1] = k end
        local width = 0
        for _, k in ipairs(keys) do if loc[k] ~= nil and #KeyText(k) > width then width = #KeyText(k) end end
        for _, k in ipairs(keys) do
            if loc[k] ~= nil then
                local prefix = '      ' .. PadKey(KeyText(k), width + 1) .. '= '
                add(prefix .. BlockValue(loc[k], k, 6, WRAP - #prefix - 1) .. ',')
            end
        end
        add('    },')
    end
    add('  },')
    add('')
    add('  objectives = {')
    for _, obj in ipairs(f.objectives or {}) do add(ObjectiveLine(obj)) end
    add('  },')
    add('')
    local function bottom(key, value)
        local prefix = '  ' .. PadKey(key, 10) .. '= '
        add(prefix .. BlockValue(value or {}, key, 2, WRAP - #prefix - 1) .. ',')
    end
    bottom('scaling', f.scaling)
    bottom('items', f.items)
    bottom('bonuses', f.bonuses)
    bottom('penalties', f.penalties)
    add('})')
    add('')
    return table.concat(lines, '\n')
end

-- Header update of a hand-edited file (only inside our own header comment).
local function RewriteHeader(content, version, edited)
    if content:sub(1, #HEADER_FIRST) ~= HEADER_FIRST then return content end
    local close = content:find(']]', 1, true)
    if not close then return content end
    local head, rest = content:sub(1, close - 1), content:sub(close)
    local function esc(s) return (tostring(s):gsub('%%', '%%%%')) end
    head = head:gsub('\n  version:[^\n]*', '\n  version:   ' .. esc(version), 1)
    head = head:gsub('\n  edited:[^\n]*', '', 1)
    head = head:gsub('(\n  published:[^\n]*)', '%1\n  edited:    ' .. esc(SafeHeaderText(edited)), 1)
    return head .. rest
end

-- ============================================================================
--                          ACTORS, PERMISSIONS, AUDIT
-- ============================================================================

local function PublisherText(actor)
    if not actor or actor.role == 'console' then return 'console' end
    local who = actor.name or actor.citizenid
    if actor.rank and actor.rank ~= '' then who = actor.rank .. ' ' .. who end
    return ('%s (%s, citizenid %s)'):format(who, actor.dept or 'admin', actor.citizenid)
end

local function GetActor(src)
    if src == 0 then
        return { src = 0, citizenid = 'console', name = 'console', role = 'console', isAdmin = true }
    end
    if not (CP.Access and CP.Access.isAdmin) then return nil, 'err.internal' end
    local isAdmin = CP.Access.isAdmin(src) == true
    local officer = CP.Access.getOfficer(src)
    if officer then
        return {
            src = src,
            citizenid = officer.citizenid,
            name = officer.name,
            rank = officer.rank,
            dept = officer.departmentShort,
            role = isAdmin and 'admin' or 'supervisor',
            isAdmin = isAdmin,
        }
    end
    if not isAdmin then return nil, 'err.no_permission' end
    local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(src)
    if not info or not info.citizenid then return nil, 'err.builder_no_character' end
    local dept
    if info.job and info.job.name and CP.Access.departmentForJob then
        local key = CP.Access.departmentForJob(info.job.name)
        local dep = key and CP.Access.department and CP.Access.department(key)
        dept = dep and dep.short or nil
    end
    return {
        src = src,
        citizenid = info.citizenid,
        name = info.name,
        rank = info.job and info.job.gradeName or nil,
        dept = dept,
        role = 'admin',
        isAdmin = true,
    }
end

-- The builder permission set of one request (admins: everything).
local PERM_NAMES = {
    'builderEdit',
    'builderEditAny',
    'builderPublish',
    'builderArchive',
    'builderRollback',
    'breakEditLock',
}
local function PermSet(src, actor)
    local set = {}
    for _, name in ipairs(PERM_NAMES) do
        if actor.isAdmin then
            set[name] = true
        else
            set[name] = CP.Permissions and CP.Permissions.can and CP.Permissions.can(src, name) == true or false
        end
    end
    return set
end

local function OwnerOf(row, actor) return row == nil or row.createdBy == actor.citizenid end

-- kind: edit | publish | archive | rollback | breakLock
local function Allows(perms, row, actor, kind)
    local mine = OwnerOf(row, actor)
    if kind == 'edit' then return perms.builderEdit and (mine or perms.builderEditAny) end
    if kind == 'publish' then return perms.builderPublish and (mine or perms.builderEditAny) end
    if kind == 'archive' then return perms.builderArchive and (mine or perms.builderEditAny) end
    if kind == 'rollback' then return perms.builderRollback and (mine or perms.builderEditAny) end
    if kind == 'breakLock' then return perms.breakEditLock end
    return false
end

-- Whether a custom mission shows in this actor's builder (SPEC Supervisor UI: "their drafts plus published
-- missions"). Someone else's never-published draft is only visible to admins and builderEditAny.
local function VisibleTo(row, actor, perms)
    if actor.isAdmin or perms.builderEditAny or OwnerOf(row, actor) then return true end
    return row.status == 'published' or row.publishedVersion ~= nil
end

local function Audit(actor, action, target, old, new, reason)
    if not (CP.Admin and CP.Admin.audit) then
        CP.log(TAG, 'audit %s %s by %s', action, tostring(target), actor and actor.citizenid or 'console')
        return
    end
    local who = (not actor or actor.role == 'console') and 'console' or actor.citizenid
    local role = (not actor or actor.role == 'console') and 'console' or actor.role
    local ok, err = pcall(CP.Admin.audit, who, role, 'builder', U.clip(action, 40), U.clip(target, 64),
        old ~= nil and U.clip(tostring(old), 64) or nil, new ~= nil and U.clip(tostring(new), 64) or nil,
        reason ~= nil and U.clip(tostring(reason), 255) or nil)
    if not ok then CP.err(TAG, 'audit %s failed: %s', action, tostring(err)) end
end

local function PushAll(data)
    if not (CP.Tablet and CP.Tablet.push) then return end
    local t = GetGameTimer()
    for src, at in pairs(viewers) do
        if t - at > VIEWER_TTL_MS then
            viewers[src] = nil
        else
            pcall(CP.Tablet.push, src, 'builder', data)
        end
    end
end

local function SrcOfCitizen(citizenid)
    if type(citizenid) ~= 'string' or citizenid == 'console' then return nil end
    if CP.Qbx and CP.Qbx.getByCitizenId then return CP.Qbx.getByCitizenId(citizenid) end
    return nil
end

-- Tell an editor (by citizenid) that they lost the lock or the draft. `by` = who did it (display name).
local function TellEditor(citizenid, event, id, key, vars, by)
    local src = SrcOfCitizen(citizenid)
    if not src then return end
    TriggerClientEvent(CP.e('client:builder'), src, { event = event, id = id, by = by })
    if key and CP.Tablet and CP.Tablet.notify then pcall(CP.Tablet.notify, src, 'warning', key, vars) end
end

-- ============================================================================
--                                    VIEWS
-- ============================================================================

local function CurrentDef(row) return row.draft or row.published end

local function Lifecycle(row)
    if row.status == 'archived' then return 'archived' end
    if row.status == 'published' then return 'published' end
    if row.draftTested then return 'tested' end
    return 'draft'
end

local function LockView(row, actor, names)
    if not row.lockActive then return nil end
    return {
        citizenid = row.lockedBy,
        name = names and names[row.lockedBy] or nil,
        secondsLeft = math.max(0, math.floor(row.lockLeft or 0)),
        mine = actor ~= nil and row.lockedBy == actor.citizenid,
    }
end

local function EntryView(row, actor, perms, names)
    local def = CurrentDef(row) or {}
    local lockedByOther = row.lockActive and row.lockedBy ~= actor.citizenid
    local canEdit = Allows(perms, row, actor, 'edit')
    return {
        id = row.id,
        label = tostring(def.label or row.id),
        type = def.type or row.missionType,
        source = 'custom',
        status = Lifecycle(row),
        dbStatus = row.status,
        version = row.publishedVersion,
        draftVersion = row.draftVersion,
        hasDraft = row.draft ~= nil,
        draftTested = row.draftTested,
        editedInCode = row.editedInCode,
        filePath = row.filePath,
        owner = { citizenid = row.createdBy, name = names[row.createdBy], mine = row.createdBy == actor.citizenid },
        updatedBy = { citizenid = row.updatedBy, name = names[row.updatedBy] },
        updatedAt = row.updatedAt,
        lock = LockView(row, actor, names),
        requiredTier = def.maxOfficers and RequiredTierName(def.maxOfficers) or nil,
        can = {
            edit = canEdit and not lockedByOther and row.status ~= 'archived',
            publish = Allows(perms, row, actor, 'publish') and row.draft ~= nil and not lockedByOther
                and row.status ~= 'archived',
            archive = Allows(perms, row, actor, 'archive') and row.status == 'published',
            restore = Allows(perms, row, actor, 'archive') and row.status == 'archived',
            rollback = Allows(perms, row, actor, 'rollback') and row.status == 'published'
                and (row.publishedVersion or 0) > 1,
            breakLock = Allows(perms, row, actor, 'breakLock') and lockedByOther,
            discard = canEdit and row.draft ~= nil and not lockedByOther,
        },
    }
end

local function BackupsOf(row)
    local out = {}
    local v = row.publishedVersion or 0
    local scanned = 0
    for n = v - 1, 1, -1 do
        scanned = scanned + 1
        if scanned > MAX_BACKUP_SCAN then break end
        if ReadFile(BackupPathFor(row.id, n)) then out[#out + 1] = n end
    end
    return out
end

local function RecordView(row, actor, perms)
    local names = DisplayNames({ row.createdBy, row.updatedBy, row.lockedBy })
    local e = EntryView(row, actor, perms, names)
    local def = CurrentDef(row) or {}
    local clean = RenameAll(U.deepcopy(def))
    clean._file = nil
    local published = row.published and RenameAll(U.deepcopy(row.published)) or nil
    local fileMeta = published and published._file or nil
    if published then published._file = nil end
    local errors, info = B.validate(clean)
    e.definition = clean
    e.publishedDefinition = published
    e.readOnly = not e.can.edit
    e.errors = errors
    e.armed = info.armed
    e.backups = BackupsOf(row)
    e.publishedAt = fileMeta and tonumber(fileMeta.publishedAt) or nil
    e.publishedBy = fileMeta and fileMeta.publisher or nil
    return e
end

local function BuiltinDefinition(id)
    local def = CP.Missions and CP.Missions.get and CP.Missions.get(id)
    if not def or def.source ~= 'builtin' then return nil end
    local path = def.filePath or ('missions/builtin/' .. id .. '.lua')
    local raw = nil
    local content = ReadFile(path)
    if content then raw = B.parse(content, path) end
    local b = B.fromFileUnits(raw or def)
    b.id = id
    return b, def
end

local function BuiltinRecord(id)
    local b, def = BuiltinDefinition(id)
    if not b then return nil end
    local errors, info = B.validate(b)
    return {
        id = id,
        label = tostring(def.label or id),
        type = def.type,
        source = 'builtin',
        status = 'published',
        dbStatus = 'published',
        version = nil,
        draftVersion = nil,
        hasDraft = false,
        draftTested = false,
        editedInCode = false,
        filePath = def.filePath,
        owner = nil,
        updatedBy = nil,
        updatedAt = 0,
        lock = nil,
        requiredTier = RequiredTierName(def.maxOfficers),
        can = {
            edit = false,
            publish = false,
            archive = false,
            restore = false,
            rollback = false,
            breakLock = false,
            discard = false,
        },
        definition = b,
        publishedDefinition = nil,
        readOnly = true,
        errors = errors,
        armed = info.armed,
        backups = {},
        publishedAt = nil,
        publishedBy = nil,
    }
end

-- ============================================================================
--                                     IDS
-- ============================================================================

function B.slug(label)
    local s = tostring(label or ''):lower()
    s = s:gsub('[^a-z0-9]+', '_'):gsub('_+', '_'):gsub('^_', ''):gsub('_$', '')
    if #s > SLUG_MAX then s = s:sub(1, SLUG_MAX):gsub('_$', '') end
    if s == '' then s = 'mission' end
    return s
end

-- A free 'custom_<slug>' id (currentId counts as free: a rename to itself).
local function UniqueId(label, currentId)
    local base = 'custom_' .. B.slug(label)
    for n = 1, 99 do
        local candidate = n == 1 and base or (base .. '_' .. n)
        if #candidate <= MAX_ID and (candidate == currentId or not IdTaken(candidate)) then return candidate end
    end
    return nil
end

-- ============================================================================
--                                    LOCKS
-- ============================================================================

local function AcquireLock(row, actor)
    if row.lockActive and row.lockedBy ~= actor.citizenid then return false end
    MySQL.update.await([[UPDATE cp_custom_missions SET locked_by = ?, locked_until = NOW() + INTERVAL ? MINUTE,
        updated_at = updated_at WHERE id = ? AND (locked_by IS NULL OR locked_by = ? OR locked_until IS NULL
        OR locked_until <= NOW())]],
        { actor.citizenid, math.max(1, math.floor(tonumber(CfgB().editLockMinutes) or 30)), row.id, actor.citizenid })
    local fresh = FetchRow(row.id)
    if fresh and fresh.lockActive and fresh.lockedBy == actor.citizenid then
        if actor.src and actor.src > 0 then holders[actor.src] = actor.citizenid end
        return true, fresh
    end
    return false, fresh
end

local function ReleaseLocksOf(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return end
    CP.Migrations.ready()
    MySQL.update.await(
        'UPDATE cp_custom_missions SET locked_by = NULL, locked_until = NULL, updated_at = updated_at WHERE locked_by = ?',
        { citizenid })
end

-- ============================================================================
--                               REQUEST PLUMBING
-- ============================================================================

local function ValidId(id)
    return type(id) == 'string' and #id > 0 and #id <= MAX_ID and id:match('^[%w_]+$') ~= nil
end

-- Shared prologue: builder enabled, builderEdit (or admin), the actor. Returns actor, perms or nil, errKey.
local function Begin(src)
    if CfgB().enabled == false then return nil, 'err.builder_disabled' end
    if not (CP.Permissions and CP.Permissions.can) then return nil, 'err.no_permission' end
    local ok, errKey = CP.Permissions.can(src, 'builderEdit')
    if not ok then return nil, errKey or 'err.no_permission' end
    local actor, aerr = GetActor(src)
    if not actor then return nil, aerr end
    return actor, PermSet(src, actor)
end

local function LoadRow(payload)
    if type(payload) ~= 'table' or not ValidId(payload.id) then return nil, 'err.invalid_payload' end
    local row = FetchRow(payload.id)
    if not row then
        if CP.Missions and CP.Missions.get then
            local def = CP.Missions.get(payload.id)
            if def and def.source == 'builtin' then return nil, 'err.builder_read_only' end
        end
        return nil, 'err.builder_unknown_mission'
    end
    return row
end

local function TouchViewer(src)
    if src and src > 0 then viewers[src] = GetGameTimer() end
end

-- ============================================================================
--                               PUBLISHING CORE
-- ============================================================================

local function RuntimeWithLoader(fileDefOrRuntime, row, version, filePath, hash, editedInCode)
    local def = B.toRuntime(fileDefOrRuntime)
    def.id = row.id
    def.source = 'custom'
    def.version = version
    def.filePath = filePath
    def.defHash = hash
    def.editedInCode = editedInCode == true
    def.status = 'published'
    return def
end

-- Writes the file, keeps the .bak, stores the row and registers the mission.
-- opts = { reason, version, editedInCode, keepDraft, headerEdited }
local function PublishDefinition(row, bdef, actor, opts)
    local version = opts.version
    local path = FilePathFor(row.id)
    local at = Now()
    local publisher = PublisherText(actor)
    bdef = U.deepcopy(bdef)
    bdef.id = row.id
    bdef._file = nil
    local text = B.exportLua(bdef, { version = version, publisher = publisher, at = at, edited = opts.headerEdited })
    local parsed, perr = B.parse(text, path)
    if not parsed then
        CP.err(TAG, 'export of %s does not load back: %s', row.id, tostring(perr))
        return false, 'err.internal'
    end
    local currentPath = row.filePath or path
    local previous = ReadFile(currentPath)
    local backup = nil
    if previous and CfgB().keepBackups ~= false and row.publishedVersion then
        backup = BackupPathFor(row.id, row.publishedVersion)
        if not WriteFile(backup, previous) then return false, 'err.builder_file_write' end
    end
    if not WriteFile(path, text) then return false, 'err.builder_file_write' end
    local hash = U.hashHex(text)
    local stored = U.deepcopy(bdef)
    stored._file = {
        hash = hash,
        version = version,
        publishedAt = at,
        publishedBy = actor.citizenid,
        publisher = publisher,
        reason = opts.reason,
    }
    local okDb, dbErr = pcall(function()
        if opts.keepDraft then
            MySQL.update.await([[UPDATE cp_custom_missions SET status = 'published', mission_type = ?,
                published_version = ?, published_definition = ?,
                draft_version = CASE WHEN draft_definition IS NULL THEN NULL ELSE ? END,
                file_path = ?, edited_in_code = ?, updated_by = ? WHERE id = ?]], {
                bdef.type,
                version,
                Encode(stored),
                version + 1,
                path,
                opts.editedInCode and 1 or 0,
                actor.citizenid,
                row.id,
            })
        else
            MySQL.update.await([[UPDATE cp_custom_missions SET status = 'published', mission_type = ?,
                published_version = ?, published_definition = ?, draft_version = NULL, draft_definition = NULL,
                draft_tested = 0, file_path = ?, edited_in_code = ?, locked_by = NULL, locked_until = NULL,
                updated_by = ? WHERE id = ?]],
                { bdef.type, version, Encode(stored), path, opts.editedInCode and 1 or 0, actor.citizenid, row.id })
        end
    end)
    if not okDb then
        CP.err(TAG, 'publishing %s failed in the %s: %s', row.id, CP.Storage and CP.Storage.name() or 'database',
            tostring(dbErr))
        if previous and currentPath == path then WriteFile(path, previous) else RemoveFile(path) end
        return false, 'err.internal'
    end
    if currentPath ~= path then RemoveFile(currentPath) end
    pendingTests[row.id] = nil
    if CP.Missions and CP.Missions.register then
        local def = RuntimeWithLoader(parsed, row, version, path, hash, opts.editedInCode)
        local okReg, res, err = pcall(CP.Missions.register, def)
        if not okReg or not res then
            CP.err(TAG, 'mission %s was published but not registered: %s', row.id, tostring(okReg and err or res))
        end
    end
    return true, { id = row.id, version = version, filePath = path, backup = backup }
end

-- ============================================================================
--           FILE SYNC (start + reload): missing files and hand edits
-- ============================================================================

local function RewriteMissing(row, summary)
    local pub = row.published
    if type(pub) ~= 'table' then
        CP.warn(TAG, 'custom mission %s has no file and no published definition to rewrite it from', row.id)
        summary.rejected[#summary.rejected + 1] = { id = row.id, error = 'file missing' }
        return
    end
    local meta = type(pub._file) == 'table' and pub._file or {}
    local path = FilePathFor(row.id)
    local text = B.exportLua(pub, {
        version = row.publishedVersion or meta.version or 1,
        publisher = meta.publisher or 'console',
        at = meta.publishedAt or Now(),
    })
    if not WriteFile(path, text) then
        summary.rejected[#summary.rejected + 1] = { id = row.id, error = 'file missing and could not be rewritten' }
        return
    end
    local stored = U.deepcopy(pub)
    stored._file = {
        hash = U.hashHex(text),
        version = row.publishedVersion,
        publishedAt = meta.publishedAt or Now(),
        publishedBy = meta.publishedBy,
        publisher = meta.publisher or 'console',
        reason = 'restore_file',
    }
    MySQL.update.await(
        'UPDATE cp_custom_missions SET file_path = ?, published_definition = ?, updated_at = updated_at WHERE id = ?',
        { path, Encode(stored), row.id })
    CP.warn(TAG, 'the file of custom mission %s was missing; rewrote %s from the %s', row.id, path,
        CP.Storage and CP.Storage.name() or 'database')
    summary.rewritten[#summary.rewritten + 1] = row.id
end

local function StripPayoutFields(raw, id)
    StripPayout(raw, function(path)
        CP.warn(TAG,
            'custom mission %s: field "%s" in its Lua file is ignored; payouts only come from the Payouts screens', id,
            path)
    end)
end

-- Why the mission loader refuses a parsed custom mission file exactly as written, or nil when it loads.
local function LoaderError(fileDef, version)
    if not (CP.Missions and CP.Missions.normalize) then return nil end
    local okCall, res, err = pcall(CP.Missions.normalize, B.toRuntime(fileDef),
        { source = 'custom', status = 'published', version = version })
    if not okCall then return tostring(res) end
    if not res then return tostring(err) end
    return nil
end

local function HandEdit(row, path, content, hash, summary)
    local raw, perr = B.parse(content, path)
    if not raw then
        CP.warn(TAG, 'custom mission %s: the edited file %s was not accepted (%s); version %s stays live', row.id, path,
            tostring(perr), tostring(row.publishedVersion))
        summary.rejected[#summary.rejected + 1] = { id = row.id, error = tostring(perr) }
        return
    end
    if raw.id ~= row.id then
        local msg = ('its id must stay %s'):format(row.id)
        CP.warn(TAG, 'custom mission %s: the edited file was not accepted: %s', row.id, msg)
        summary.rejected[#summary.rejected + 1] = { id = row.id, error = msg }
        return
    end
    StripPayoutFields(raw, row.id)
    local b = B.sanitize(B.fromFileUnits(raw), row.id)
    local errors = b and B.validate(b, { publish = true }) or { { message = 'invalid definition' } }
    if #errors == 0 then
        -- the checks above ran on the builder copy (rounded to builder units), but the file itself goes live
        local reason = LoaderError(raw, (row.publishedVersion or 0) + 1)
        if reason then errors = { { message = L('builder.error.not_playable', { reason = reason }) } } end
    end
    if #errors > 0 then
        local msgs = {}
        for i = 1, math.min(3, #errors) do msgs[i] = errors[i].message end
        CP.warn(TAG, 'custom mission %s: the edited file breaks the builder guardrails, version %s stays live: %s',
            row.id, tostring(row.publishedVersion), table.concat(msgs, ' | '))
        summary.rejected[#summary.rejected + 1] = { id = row.id, error = table.concat(msgs, ' | ') }
        return
    end
    local prevVersion = row.publishedVersion or 0
    local version = prevVersion + 1
    local at = Now()
    -- keep the previous published version as its .bak (rollback target)
    if CfgB().keepBackups ~= false and type(row.published) == 'table' and prevVersion > 0 then
        local bak = BackupPathFor(row.id, prevVersion)
        if not ReadFile(bak) then
            local meta = type(row.published._file) == 'table' and row.published._file or {}
            WriteFile(bak, B.exportLua(row.published,
                { version = prevVersion, publisher = meta.publisher or 'console', at = meta.publishedAt or at }))
        end
    end
    local edited = ('%s in code (reloaded with %s reload)'):format(FormatStamp(at), AdminCommand())
    local newContent = RewriteHeader(content, version, edited)
    if newContent ~= content and WriteFile(path, newContent) then
        hash = U.hashHex(newContent)
    end
    -- the draft: a changed draft conflicts with the file (the file wins)
    local conflict = false
    if type(row.draft) == 'table' then
        local pubCopy = type(row.published) == 'table' and U.deepcopy(row.published) or nil
        if pubCopy then pubCopy._file = nil end
        if DefHash(row.draft) ~= DefHash(pubCopy) then
            conflict = true
            WriteFile(DraftBackupPathFor(row.id), B.exportLua(row.draft,
                { version = row.draftVersion or version, publisher = 'unpublished builder draft', at = at }))
        end
    end
    local stored = U.deepcopy(b)
    stored._file = {
        hash = hash,
        version = version,
        publishedAt = at,
        publishedBy = 'console',
        publisher = 'code edit',
        reason = 'code_edit',
    }
    MySQL.update.await([[UPDATE cp_custom_missions SET status = 'published', mission_type = ?, published_version = ?,
        published_definition = ?, draft_version = NULL, draft_definition = NULL, draft_tested = 0,
        file_path = ?, edited_in_code = 1, locked_by = NULL, locked_until = NULL, updated_by = 'console'
        WHERE id = ?]], { b.type, version, Encode(stored), path, row.id })
    pendingTests[row.id] = nil
    if row.lockActive and row.lockedBy then
        TellEditor(row.lockedBy, 'reloaded', row.id, 'builder.reloaded_by_code', { mission = tostring(b.label) })
    end
    Audit(nil, 'codeEdit', row.id, prevVersion, version, 'edited in code')
    if conflict then
        CP.warn(TAG, 'custom mission %s: the builder draft also changed; the file wins, the draft was saved as %s',
            row.id, DraftBackupPathFor(row.id))
        Audit(nil, 'codeEditConflict', row.id, row.draftVersion, version,
            'draft saved as ' .. DraftBackupPathFor(row.id))
        summary.conflicts[#summary.conflicts + 1] = row.id
    end
    print(('[crimson-police] custom mission %s: edited in code, saved as version %d'):format(row.id, version))
    summary.edited[#summary.edited + 1] = { id = row.id, version = version }
    PushAll({ event = 'reloaded', id = row.id })
end

local function SyncFiles()
    local summary = { checked = 0, unchanged = 0, edited = {}, rejected = {}, conflicts = {}, rewritten = {} }
    for _, row in ipairs(FetchRows('status = \'published\'')) do
        summary.checked = summary.checked + 1
        local path = row.filePath or FilePathFor(row.id)
        local content = ReadFile(path)
        local meta = type(row.published) == 'table' and type(row.published._file) == 'table' and row.published._file
            or nil
        local ok, err = pcall(function()
            if not content then
                RewriteMissing(row, summary)
            else
                local hash = U.hashHex(content)
                if not meta or type(meta.hash) ~= 'string' then
                    -- no baseline yet: the file on disk is the published version
                    if type(row.published) == 'table' then
                        local stored = U.deepcopy(row.published)
                        stored._file = {
                            hash = hash,
                            version = row.publishedVersion,
                            publishedAt = Now(),
                            publishedBy = 'console',
                            publisher = 'console',
                            reason = 'restore_file',
                        }
                        MySQL.update.await(
                            'UPDATE cp_custom_missions SET published_definition = ?, file_path = ?, updated_at = updated_at WHERE id = ?',
                            { Encode(stored), path, row.id })
                    end
                    summary.unchanged = summary.unchanged + 1
                elseif hash == meta.hash then
                    summary.unchanged = summary.unchanged + 1
                else
                    HandEdit(row, path, content, hash, summary)
                end
            end
        end)
        if not ok then
            CP.err(TAG, 'checking the file of %s failed: %s', row.id, tostring(err))
            summary.rejected[#summary.rejected + 1] = { id = row.id, error = tostring(err) }
        end
    end
    return summary
end

-- ============================================================================
--                                    HOOKS
-- ============================================================================

function B.loadPublished()
    CP.Migrations.ready()
    EnsureExportDirs() -- a fresh clone has no missions/custom/archived/ (SaveResourceFile makes no folders)
    local summary = SyncFiles()
    if #summary.edited + #summary.rejected + #summary.rewritten > 0 then
        CP.log(TAG, 'file sync: %d edited, %d rejected, %d rewritten', #summary.edited, #summary.rejected,
            #summary.rewritten)
    end
    local out = {}
    for _, row in ipairs(FetchRows('status = \'published\'')) do
        local path = row.filePath or FilePathFor(row.id)
        local content = ReadFile(path)
        local meta = type(row.published) == 'table' and type(row.published._file) == 'table' and row.published._file
            or {}
        local hash = content and U.hashHex(content) or nil
        local raw = nil
        if content and hash == meta.hash then
            local perr
            raw, perr = B.parse(content, path)
            if not raw then CP.warn(TAG, 'custom mission %s: %s does not load: %s', row.id, path, tostring(perr)) end
        end
        if raw then
            StripPayoutFields(raw, row.id)
            out[#out + 1] = RuntimeWithLoader(raw, row, row.publishedVersion, path, hash, row.editedInCode)
        elseif type(row.published) == 'table' then
            -- the file has edits that were not accepted (or does not load): the last published version stays live
            local pub = U.deepcopy(row.published)
            pub._file = nil
            out[#out + 1] = RuntimeWithLoader(B.toFileUnits(pub), row, row.publishedVersion, path,
                meta.hash or DefHash(pub), row.editedInCode)
        else
            CP.warn(TAG, 'custom mission %s has no loadable file and no published definition; skipped', row.id)
        end
    end
    return out
end

function B.onReload()
    CP.Migrations.ready()
    local summary = SyncFiles()
    print(
        ('[crimson-police] custom mission files: %d checked, %d edited in code, %d rejected, %d conflicts, %d rewritten'):format(
            summary.checked, #summary.edited, #summary.rejected, #summary.conflicts, #summary.rewritten))
    return summary
end

-- defHash is the hash of the definition the test ran (server:builder:test gives it to CP.Testing, which hands it
-- back): a pass counts only for exactly that content. Without it, the last test started here must match.
function B.onDraftTested(missionId, version, tierName, passed, src, defHash)
    if type(missionId) ~= 'string' then return false end
    CP.Migrations.ready()
    local id = missionId
    if not FetchRow(id) then return false end
    local actor = (tonumber(src) and tonumber(src) > 0) and GetActor(tonumber(src)) or nil
    Audit(actor, passed and 'testPassed' or 'testFailed', id, tostring(version), tostring(tierName),
        ('draft v%s at %s'):format(tostring(version), tostring(tierName)))
    -- read the draft after the audit (it may yield), so a save made meanwhile is what gets checked
    local row = FetchRow(id)
    if not row then return false end
    local draft = row.draft
    local required = draft and RequiredTierName(draft.maxOfficers) or nil
    local pending = pendingTests[id]
    local tested = type(defHash) == 'string' and defHash or (pending and pending.hash)
    local label = draft and tostring(draft.label) or id
    local function tell(kind, key, vars)
        local s = tonumber(src)
        if s and s > 0 and CP.Tablet and CP.Tablet.notify then pcall(CP.Tablet.notify, s, kind, key, vars) end
    end
    if not passed then
        tell('warning', 'builder.test_failed', { mission = label })
        return false
    end
    if not draft or tonumber(version) ~= row.draftVersion or tested ~= DefHash(draft) then
        tell('warning', 'builder.test_outdated', { mission = label })
        return false
    end
    local reqIdx, gotIdx = TierIndex(required), TierIndex(tierName)
    local tierOk = CfgB().testAtMaxTier == false or (reqIdx ~= nil and gotIdx ~= nil and gotIdx >= reqIdx)
    if not tierOk then
        tell('warning', 'builder.test_wrong_tier',
            { mission = label, tier = TierLabel(tierName), required = TierLabel(required) })
        return false
    end
    MySQL.update.await(
        'UPDATE cp_custom_missions SET draft_tested = 1, updated_at = updated_at WHERE id = ? AND draft_version = ?',
        { id, row.draftVersion })
    pendingTests[id] = nil
    tell('success', 'builder.test_passed', { mission = label, tier = TierLabel(tierName) })
    PushAll({ event = 'tested', id = id })
    return true
end

-- ============================================================================
--                                  CALLBACKS
-- ============================================================================

CP.Net.callback('builder:list', function(src)
    local actor, perms = Begin(src)
    if not actor then return nil, perms end
    TouchViewer(src)
    local rows = {}
    for _, r in ipairs(FetchRows()) do
        if VisibleTo(r, actor, perms) then rows[#rows + 1] = r end
    end
    local ids = {}
    for _, r in ipairs(rows) do
        ids[#ids + 1] = r.createdBy
        ids[#ids + 1] = r.updatedBy
        ids[#ids + 1] = r.lockedBy
    end
    local names = DisplayNames(ids)
    local missions = {}
    for _, r in ipairs(rows) do missions[#missions + 1] = EntryView(r, actor, perms, names) end
    local builtins = {}
    if CP.Missions and CP.Missions.list then
        for _, def in ipairs(CP.Missions.list()) do
            if def.source == 'builtin' then
                builtins[#builtins + 1] = {
                    id = def.id,
                    label = def.label,
                    type = def.type,
                    source = 'builtin',
                    readOnly = true,
                }
            end
        end
    end
    return {
        missions = missions,
        builtins = builtins,
        me = actor.citizenid ~= 'console' and actor.citizenid or nil,
        serverTime = Now(),
    }
end, { rate = 4 })

CP.Net.callback('builder:get', function(src, args)
    local actor, perms = Begin(src)
    if not actor then return nil, perms end
    if type(args) ~= 'table' or not ValidId(args.id) then return nil, 'err.invalid_payload' end
    TouchViewer(src)
    local row = FetchRow(args.id)
    if row then
        if not VisibleTo(row, actor, perms) then return nil, 'err.builder_unknown_mission' end
        return RecordView(row, actor, perms)
    end
    local rec = BuiltinRecord(args.id)
    if rec then return rec end
    return nil, 'err.builder_unknown_mission'
end, { rate = 4 })

CP.Net.callback('builder:config', function(src)
    local actor, perms = Begin(src)
    if not actor then return nil, perms end
    local bc = CfgB()
    local blockList = {}
    for _, id in ipairs(U.keys(Config.Blocks or {})) do
        if id ~= 'details' then
            local c = Config.Blocks[id]
            blockList[#blockList + 1] = {
                id = id,
                labelKey = 'builder.block.' .. id,
                available = CP.Blocks.get(id) ~= nil,
                minSeconds = DEFAULT_MIN_SECONDS[id] or 0,
                presenceRange = type(c.presenceRange) == 'table' and c.presenceRange or nil,
            }
        end
    end
    local bonuses = {}
    for _, id in ipairs(U.keys(Config.Bonuses or {})) do
        local c = Config.Bonuses[id]
        local pct = c.kind == 'pct'
        local value = tonumber(c.value) or 0
        local penalty = not pct and value < 0
        bonuses[#bonuses + 1] = {
            id = id,
            kind = pct and 'pct' or 'points',
            value = pct and RoundInt(value * 100) or value,
            each = c.each == true,
            block = c.block,
            penalty = penalty,
            labelKey = (penalty and 'penalty.' or 'bonus.') .. id,
        }
    end
    local zones = {}
    for _, z in ipairs(bc.noBuildZones or {}) do
        zones[#zones + 1] = { label = z.label, coords = U.vecToTable(z.coords), radius = z.radius }
    end
    local departments = {}
    for _, key in ipairs(U.keys(Config.Departments or {})) do
        local d = Config.Departments[key]
        departments[#departments + 1] = { key = key, label = d.label, short = d.short }
    end
    local types = {}
    for _, key in ipairs(U.keys(Config.MissionTypes or {})) do
        local t = Config.MissionTypes[key]
        types[#types + 1] = { key = key, label = t.label, points = t.points }
    end
    table.sort(types, function(a, b) return (a.points or 0) < (b.points or 0) end)
    local tiers = {}
    for _, row in ipairs(TierRows()) do
        tiers[#tiers + 1] = { name = row.tier, labelKey = 'tier.' .. row.tier, maxParticipants = row.maxParticipants }
    end
    local cap = bc.bonusCap or { points = 50, share = 0.25 }
    return {
        enabled = bc.enabled ~= false,
        blocks = Config.Blocks,
        blockList = blockList,
        allowed = bc.allowed,
        maxHostiles = bc.maxHostiles,
        maxBlocks = bc.maxBlocks,
        minLocations = bc.minLocations,
        maxLocations = MAX_LOCATIONS,
        minLocationGap = bc.minLocationGap,
        minSpawnFromStart = bc.minSpawnFromStart,
        bonusCap = { points = cap.points, pct = RoundInt((tonumber(cap.share) or 0.25) * 100) },
        bonuses = bonuses,
        noBuildZones = zones,
        departments = departments,
        missionTypes = types,
        tiers = tiers,
        autosaveSeconds = bc.autosaveSeconds,
        editLockMinutes = bc.editLockMinutes,
        testAtMaxTier = bc.testAtMaxTier ~= false,
        keepBackups = bc.keepBackups ~= false,
        exportPath = ExportDir(),
        route = bc.route,
        startRadius = START_RADIUS,
        maxItems = MAX_ITEMS,
        itemCount = ITEM_COUNT,
        maxScaling = MAX_SCALING,
        limits = LIMITS,
        percentFields = PERCENT_FIELDS,
        secondsFields = SECONDS_FIELDS,
        spawnFields = SPAWN_FIELDS,
        forbiddenItems = FORBIDDEN_ITEMS,
        useStartRoute = Config.Testing and Config.Testing.useStartRoute == true or false,
        permissions = perms,
    }
end, { rate = 2 })

-- ============================================================================
--                                   ACTIONS
-- ============================================================================

local function NewSkeleton(id, label, missionType)
    local d = Details()
    local function def3(r, fallback) return type(r) == 'table' and r[3] or fallback end
    local vp = d.vehiclePenalties
    return {
        id = id,
        label = label,
        description = '',
        type = missionType,
        departments = {},
        minOfficers = type(d.officers) == 'table' and d.officers[1] or 1,
        maxOfficers = type(d.officers) == 'table' and d.officers[2] or 4,
        difficulty = def3(d.difficulty, 2),
        timeLimit = def3(d.timeLimit, 600),
        startTimeout = def3(d.startTimeout, 600),
        cooldown = def3(d.cooldown, 1200),
        vehiclePenalties = not (type(vp) == 'table' and vp.default == false),
        locations = { { label = L('builder.location_default', { n = 1 }) } },
        objectives = {},
        scaling = {},
        items = {},
        bonuses = {},
        penalties = {},
    }
end

local function InsertDraft(label, def, actor)
    for _ = 1, 3 do
        local id = UniqueId(label)
        if not id then return nil, 'err.internal' end
        def.id = id
        -- INSERT IGNORE: a clash with an id taken a moment ago inserts nothing (0 rows) and we try the next one
        local ok, n = pcall(MySQL.update.await, [[INSERT IGNORE INTO cp_custom_missions (id, mission_type, status,
            draft_version, draft_definition, draft_tested, file_path, edited_in_code, locked_by, locked_until,
            created_by, updated_by) VALUES (?, ?, 'draft', 1, ?, 0, NULL, 0, ?, NOW() + INTERVAL ? MINUTE, ?, ?)]], {
            id,
            def.type,
            Encode(def),
            actor.citizenid,
            math.max(1, math.floor(tonumber(CfgB().editLockMinutes) or 30)),
            actor.citizenid,
            actor.citizenid,
        })
        if ok and (tonumber(n) or 0) > 0 then
            if actor.src and actor.src > 0 then holders[actor.src] = actor.citizenid end
            return id
        end
    end
    return nil, 'err.internal'
end

CP.Net.action('server:builder:create', function(src, payload)
    local actor, perms = Begin(src)
    if not actor then return false, perms end
    if type(payload) ~= 'table' then return false, 'err.invalid_payload' end
    if not CP.Net.rateOk(src, 'builder:create', 1, 2000) then return false, 'err.rate_limited' end
    local missionType = payload.type
    if type(missionType) ~= 'string' or not (Config.MissionTypes and Config.MissionTypes[missionType]) then
        return false, 'err.builder_bad_type'
    end
    local label = payload.label
    if type(label) ~= 'string' or U.trim(label) == '' then
        label = L('builder.default_label', { type = Config.MissionTypes[missionType].label })
    end
    label = ClipText(U.trim(label), LIMITS.label)
    local def = NewSkeleton(nil, label, missionType)
    local id, err = InsertDraft(label, def, actor)
    if not id then return false, err end
    Audit(actor, 'create', id, nil, 'v1', missionType)
    PushAll({ event = 'changed', id = id, by = actor.name })
    return true, { id = id, record = RecordView(FetchRow(id), actor, perms) }
end, { rate = 2 })

CP.Net.action('server:builder:duplicate', function(src, payload)
    local actor, perms = Begin(src)
    if not actor then return false, perms end
    if type(payload) ~= 'table' or not ValidId(payload.id) then return false, 'err.invalid_payload' end
    if not CP.Net.rateOk(src, 'builder:create', 1, 2000) then return false, 'err.rate_limited' end
    local source
    local row = FetchRow(payload.id)
    if row then
        -- any custom mission the actor can see may be copied into an own draft (builderEdit, checked by begin)
        if not VisibleTo(row, actor, perms) then return false, 'err.builder_unknown_mission' end
        source = U.deepcopy(CurrentDef(row) or {})
        source._file = nil
    else
        source = BuiltinDefinition(payload.id)
        if not source then return false, 'err.builder_unknown_mission' end
    end
    local copy = B.sanitize(source, nil)
    if not copy then return false, 'err.builder_unknown_mission' end
    -- custom missions only use the standard bonus list
    for _, listKey in ipairs({ 'bonuses', 'penalties' }) do
        copy[listKey] = U.filter(copy[listKey] or {}, function(e)
            return type(e) == 'table' and BonusCfg(e.id) ~= nil
        end)
    end
    B.customBonusFields(copy)
    local label = ClipText(L('builder.copy_label', { label = tostring(source.label or payload.id) }), LIMITS.label)
    copy.label = label
    if not (Config.MissionTypes and Config.MissionTypes[copy.type]) then
        copy.type = U.keys(Config.MissionTypes or {})[1]
    end
    local id, err = InsertDraft(label, copy, actor)
    if not id then return false, err end
    Audit(actor, 'duplicate', id, payload.id, 'v1', nil)
    PushAll({ event = 'changed', id = id, by = actor.name })
    return true, { id = id, record = RecordView(FetchRow(id), actor, perms) }
end, { rate = 2 })

CP.Net.action('server:builder:lock', function(src, payload)
    local actor, perms = Begin(src)
    if not actor then return false, perms end
    local row, err = LoadRow(payload)
    if not row then return false, err end
    if not Allows(perms, row, actor, 'edit') then return false, 'err.no_permission' end
    if row.status == 'archived' then return false, 'err.builder_read_only' end
    TouchViewer(src)
    local ok, fresh = AcquireLock(row, actor)
    if not ok then return false, 'err.builder_locked' end
    -- an explicit lock is the editor taking the mission back after a lock break
    if brokenLocks[row.id] then brokenLocks[row.id][actor.citizenid] = nil end
    local names = DisplayNames({ fresh.lockedBy })
    return true, { id = row.id, lock = LockView(fresh, actor, names) }
end, { rate = 4 })

CP.Net.action('server:builder:unlock', function(src, payload)
    local actor, perms = Begin(src)
    if not actor then return false, perms end
    local row, err = LoadRow(payload)
    if not row then return false, err end
    MySQL.update.await(
        'UPDATE cp_custom_missions SET locked_by = NULL, locked_until = NULL, updated_at = updated_at WHERE id = ? AND locked_by = ?',
        { row.id, actor.citizenid })
    return true, { id = row.id }
end, { rate = 4 })

-- Stores a draft (save and autosave). Returns ok, data|errKey.
local function StoreDraft(src, payload, explicit)
    local actor, perms = Begin(src)
    if not actor then return false, perms end
    local row, err = LoadRow(payload)
    if not row then return false, err end
    if not Allows(perms, row, actor, 'edit') then return false, 'err.no_permission' end
    if row.status == 'archived' then return false, 'err.builder_read_only' end
    local def, serr = B.sanitize(payload.definition, row.id)
    if not def then return false, serr end
    TouchViewer(src)
    -- after a lock break the old editor must take the lock explicitly (server:builder:lock) before storing again
    if brokenLocks[row.id] and brokenLocks[row.id][actor.citizenid]
        and not (row.lockActive and row.lockedBy == actor.citizenid) then
        return false, 'err.builder_locked'
    end
    local okLock, fresh = AcquireLock(row, actor)
    if not okLock then return false, 'err.builder_locked' end
    row = fresh
    local version = row.draftVersion
    if not version then version = (row.publishedVersion or 0) + 1 end
    local changed = DefHash(def) ~= DefHash(row.draft)
    local tested = row.draftTested and not changed
    local newId, previousId = row.id, nil
    if explicit and row.publishedVersion == nil and row.status == 'draft' and type(def.label) == 'string'
        and U.trim(def.label) ~= '' and ('custom_' .. B.slug(def.label)) ~= row.id:gsub('_%d+$', '') then
        local candidate = UniqueId(def.label, row.id)
        if candidate and candidate ~= row.id then
            local n = MySQL.update.await(
                'UPDATE IGNORE cp_custom_missions SET id = ? WHERE id = ? AND published_version IS NULL',
                { candidate, row.id })
            if (tonumber(n) or 0) > 0 then
                previousId, newId = row.id, candidate
                def.id = newId
                -- the id and label are part of the tested content: a test started before the rename is outdated,
                -- and its result (under the old id, which a new mission may take) never reaches this draft
                pendingTests[previousId] = nil
                if brokenLocks[previousId] then
                    brokenLocks[newId] = brokenLocks[previousId]
                    brokenLocks[previousId] = nil
                end
            end
        end
    end
    local missionType = row.missionType
    if row.publishedVersion == nil and type(def.type) == 'string' and Config.MissionTypes
        and Config.MissionTypes[def.type] then
        missionType = def.type
    end
    MySQL.update.await([[UPDATE cp_custom_missions SET draft_definition = ?, draft_version = ?, draft_tested = ?,
        mission_type = ?, updated_by = ?, locked_by = ?, locked_until = NOW() + INTERVAL ? MINUTE WHERE id = ?]], {
        Encode(def),
        version,
        tested and 1 or 0,
        missionType,
        actor.citizenid,
        actor.citizenid,
        math.max(1, math.floor(tonumber(CfgB().editLockMinutes) or 30)),
        newId,
    })
    local saved = FetchRow(newId)
    local names = DisplayNames({ actor.citizenid })
    local result = {
        id = newId,
        version = version,
        savedAt = Now(),
        draftTested = tested,
        lock = saved and LockView(saved, actor, names) or nil,
    }
    if explicit then
        local errors = B.validate(def, { raw = payload.definition })
        result.previousId = previousId
        result.errors = errors
        result.valid = #errors == 0
        Audit(actor, 'save', newId, row.draftVersion and ('v' .. row.draftVersion) or nil, 'v' .. version,
            previousId and ('renamed from ' .. previousId) or nil)
        PushAll({ event = 'changed', id = newId, previousId = previousId, by = actor.name })
    end
    return true, result
end

CP.Net.action('server:builder:save', function(src, payload)
    if not CP.Net.rateOk(src, 'builder:save', 1, 1000) then return false, 'err.rate_limited' end
    return StoreDraft(src, payload, true)
end, { rate = 3 })

CP.Net.action('server:builder:autosave', function(src, payload)
    if type(payload) == 'table' and ValidId(payload.id) then
        local key = src .. ':' .. payload.id
        local t = GetGameTimer()
        if lastAutosave[key] and t - lastAutosave[key] < AUTOSAVE_MIN_MS then return false, 'err.rate_limited' end
        lastAutosave[key] = t
    end
    return StoreDraft(src, payload, false)
end, { rate = 3 })

CP.Net.action('server:builder:validate', function(src, payload)
    local actor, perms = Begin(src)
    if not actor then return false, perms end
    local row, err = LoadRow(payload)
    if not row then return false, err end
    TouchViewer(src)
    local def
    if payload.definition ~= nil then
        local serr
        def, serr = B.sanitize(payload.definition, row.id)
        if not def then return false, serr end
    else
        def = U.deepcopy(CurrentDef(row) or {})
        def._file = nil
    end
    local errors, info = B.validate(def, { raw = payload.definition, publish = true })
    return true,
        {
            valid = #errors == 0,
            errors = errors,
            armed = info.armed,
            maxHostiles = CfgB().maxHostiles,
            requiredTier = info.requiredTier,
        }
end, { rate = 4 })

CP.Net.action('server:builder:test', function(src, payload)
    local actor, perms = Begin(src)
    if not actor then return false, perms end
    local row, err = LoadRow(payload)
    if not row then return false, err end
    if not Allows(perms, row, actor, 'edit') then return false, 'err.no_permission' end
    if not CP.Net.rateOk(src, 'builder:test', 1, 5000) then return false, 'err.rate_limited' end
    if row.lockActive and row.lockedBy ~= actor.citizenid then return false, 'err.builder_locked' end
    if src > 0 and CP.Alerts and CP.Alerts.inArena and CP.Alerts.inArena(src) then return false, 'err.in_arena' end
    local draft = row.draft
    if type(draft) ~= 'table' then return false, 'err.builder_no_draft' end
    -- the item rules hold on a test run too: its items are really given
    if #ItemErrors(draft.items == nil and {} or draft.items, {}) > 0 then return false, 'err.builder_invalid' end
    if not (CP.Testing and CP.Testing.startDraft) then return false, 'err.builder_testing_unavailable' end
    local required = RequiredTierName(draft.maxOfficers)
    local tier = payload.tier
    if tier == nil then tier = required end
    if type(tier) ~= 'string' or not TierIndex(tier) then return false, 'err.builder_bad_tier' end
    local location = payload.location
    local nLoc = type(draft.locations) == 'table' and #draft.locations or 0
    if location == nil then location = 1 end
    if location ~= 'random' and not (IsInt(location) and location >= 1 and location <= nLoc) then
        return false, 'err.builder_bad_location'
    end
    local useStartRoute = payload.useStartRoute
    if useStartRoute == nil then useStartRoute = Config.Testing and Config.Testing.useStartRoute == true end
    if type(useStartRoute) ~= 'boolean' then return false, 'err.invalid_payload' end
    local rt = B.toRuntime(B.toFileUnits(draft))
    rt.id = row.id
    local def = rt
    if CP.Missions and CP.Missions.normalize then
        local okCall, res, nerr = pcall(CP.Missions.normalize, rt,
            { source = 'custom', version = row.draftVersion, status = 'draft', defHash = DefHash(draft) })
        if not okCall or not res then
            CP.log(TAG, 'draft %s is not playable: %s', row.id, tostring(okCall and nerr or res))
            return false, 'err.builder_invalid'
        end
        def = res
    end
    local hash = DefHash(draft)
    local okStart, startRes, startData = pcall(CP.Testing.startDraft, src, def,
        { tier = tier, location = location, useStartRoute = useStartRoute })
    if not okStart then
        CP.err(TAG, 'CP.Testing.startDraft failed: %s', tostring(startRes))
        return false, 'err.internal'
    end
    if not startRes then return false, startData or 'err.builder_testing_unavailable' end
    -- the location that actually runs (CP.Testing picks one for 'random'); the tester records the result for it
    if type(startData) == 'table' and IsInt(tonumber(startData.locationIndex)) then
        location = math.floor(tonumber(startData.locationIndex))
    end
    pendingTests[row.id] = { hash = hash, version = row.draftVersion, startedBy = actor.citizenid, at = Now() }
    Audit(actor, 'test', row.id, 'v' .. tostring(row.draftVersion), tier, ('location %s'):format(tostring(location)))
    return true, { id = row.id, version = row.draftVersion, tier = tier, location = location, requiredTier = required }
end, { rate = 2 })

CP.Net.action('server:builder:publish', function(src, payload)
    local actor, perms = Begin(src)
    if not actor then return false, perms end
    local row, err = LoadRow(payload)
    if not row then return false, err end
    if not Allows(perms, row, actor, 'publish') then return false, 'err.no_permission' end
    if not CP.Net.rateOk(src, 'builder:publish', 1, 3000) then return false, 'err.rate_limited' end
    if row.lockActive and row.lockedBy ~= actor.citizenid then return false, 'err.builder_locked' end
    -- the draft left over by archive stays read-only: publishing it would restore without builderArchive
    if row.status == 'archived' then return false, 'err.builder_read_only' end
    local draft = row.draft
    if type(draft) ~= 'table' then return false, 'err.builder_no_draft' end
    draft = U.deepcopy(draft)
    draft._file = nil
    local errors = B.validate(draft, { publish = true })
    if #errors > 0 then return false, 'err.builder_invalid' end
    if CfgB().testAtMaxTier ~= false and not row.draftTested then return false, 'err.builder_not_tested' end
    local version = row.draftVersion or ((row.publishedVersion or 0) + 1)
    if row.publishedVersion and version <= row.publishedVersion then version = row.publishedVersion + 1 end
    local ok, res = PublishDefinition(row, draft, actor, { reason = 'publish', version = version })
    if not ok then return false, res end
    Audit(actor, 'publish', row.id, row.publishedVersion and ('v' .. row.publishedVersion) or nil, 'v' .. version,
        tostring(draft.label))
    PushAll({ event = 'published', id = row.id, by = actor.name })
    return true, res
end, { rate = 2 })

local function MoveFile(from, to)
    local content = ReadFile(from)
    if not content then return false end
    if not WriteFile(to, content) then return false end
    if from ~= to then RemoveFile(from) end
    return true
end

CP.Net.action('server:builder:archive', function(src, payload)
    local actor, perms = Begin(src)
    if not actor then return false, perms end
    local row, err = LoadRow(payload)
    if not row then return false, err end
    if not Allows(perms, row, actor, 'archive') then return false, 'err.no_permission' end
    if row.status ~= 'published' then return false, 'err.builder_not_published' end
    local from = row.filePath or FilePathFor(row.id)
    local to = ArchivedPathFor(row.id)
    if not MoveFile(from, to) then
        -- no file on disk: write the archived copy from the database
        local pub = row.published
        if type(pub) ~= 'table' then return false, 'err.builder_file_write' end
        local meta = type(pub._file) == 'table' and pub._file or {}
        if
            not WriteFile(to,
                B.exportLua(pub, { version = row.publishedVersion, publisher = meta.publisher, at = meta.publishedAt }))
        then
            return false, 'err.builder_file_write'
        end
    end
    MySQL.update.await(
        'UPDATE cp_custom_missions SET status = \'archived\', file_path = ?, updated_by = ? WHERE id = ? AND status = \'published\'',
        { to, actor.citizenid, row.id })
    if CP.Missions and CP.Missions.unregister then pcall(CP.Missions.unregister, row.id) end
    Audit(actor, 'archive', row.id, 'published', 'archived', nil)
    PushAll({ event = 'archived', id = row.id, by = actor.name })
    return true, { id = row.id, filePath = to }
end, { rate = 2 })

CP.Net.action('server:builder:restore', function(src, payload)
    local actor, perms = Begin(src)
    if not actor then return false, perms end
    local row, err = LoadRow(payload)
    if not row then return false, err end
    if not Allows(perms, row, actor, 'archive') then return false, 'err.no_permission' end
    if row.status ~= 'archived' then return false, 'err.builder_not_archived' end
    local from = row.filePath or ArchivedPathFor(row.id)
    local to = FilePathFor(row.id)
    local pub = row.published
    local meta = type(pub) == 'table' and type(pub._file) == 'table' and pub._file or {}
    if not MoveFile(from, to) then
        if type(pub) ~= 'table' then return false, 'err.builder_file_write' end
        if
            not WriteFile(to,
                B.exportLua(pub, { version = row.publishedVersion, publisher = meta.publisher, at = meta.publishedAt }))
        then
            return false, 'err.builder_file_write'
        end
    end
    MySQL.update.await(
        'UPDATE cp_custom_missions SET status = \'published\', file_path = ?, updated_by = ? WHERE id = ? AND status = \'archived\'',
        { to, actor.citizenid, row.id })
    -- the restored file goes live as it is (a file edited while archived is checked on the next reload)
    local content = ReadFile(to)
    if content and CP.Missions and CP.Missions.register then
        local raw = B.parse(content, to)
        local def
        if raw and U.hashHex(content) == meta.hash then
            StripPayoutFields(raw, row.id)
            def = RuntimeWithLoader(raw, row, row.publishedVersion, to, meta.hash, row.editedInCode)
        elseif type(pub) == 'table' then
            local copy = U.deepcopy(pub)
            copy._file = nil
            def = RuntimeWithLoader(B.toFileUnits(copy), row, row.publishedVersion, to, meta.hash or DefHash(copy),
                row.editedInCode)
        end
        if def then
            local okReg, res, rerr = pcall(CP.Missions.register, def)
            if not okReg or not res then
                CP.err(TAG, 'restored %s was not registered: %s', row.id, tostring(okReg and rerr or res))
            end
        end
    end
    Audit(actor, 'restore', row.id, 'archived', 'published', nil)
    PushAll({ event = 'restored', id = row.id, by = actor.name })
    return true, { id = row.id, filePath = to }
end, { rate = 2 })

CP.Net.action('server:builder:rollback', function(src, payload)
    local actor, perms = Begin(src)
    if not actor then return false, perms end
    local row, err = LoadRow(payload)
    if not row then return false, err end
    if not Allows(perms, row, actor, 'rollback') then return false, 'err.no_permission' end
    if not CP.Net.rateOk(src, 'builder:publish', 1, 3000) then return false, 'err.rate_limited' end
    if row.status ~= 'published' or not row.publishedVersion then return false, 'err.builder_not_published' end
    local fromVersion, content
    for n = row.publishedVersion - 1, math.max(1, row.publishedVersion - MAX_BACKUP_SCAN), -1 do
        content = ReadFile(BackupPathFor(row.id, n))
        if content then fromVersion = n; break end
    end
    if not content then return false, 'err.builder_no_backup' end
    local raw, perr = B.parse(content, BackupPathFor(row.id, fromVersion))
    if not raw or raw.id ~= row.id then
        CP.warn(TAG, 'rollback of %s: %s does not load: %s', row.id, BackupPathFor(row.id, fromVersion),
            tostring(perr or 'wrong id'))
        return false, 'err.builder_invalid'
    end
    StripPayoutFields(raw, row.id)
    local b = B.sanitize(B.fromFileUnits(raw), row.id)
    local errors = b and B.validate(b, { publish = true }) or { {} }
    if #errors > 0 then
        CP.warn(TAG, 'rollback of %s to v%d refused: %s', row.id, fromVersion,
            tostring(errors[1] and errors[1].message))
        return false, 'err.builder_invalid'
    end
    local version = row.publishedVersion + 1
    local ok, res = PublishDefinition(row, b, actor, { reason = 'rollback', version = version, keepDraft = true })
    if not ok then return false, res end
    Audit(actor, 'rollback', row.id, 'v' .. row.publishedVersion, 'v' .. version, ('restored v%d'):format(fromVersion))
    PushAll({ event = 'rolledBack', id = row.id, by = actor.name })
    return true, { id = row.id, version = version, fromVersion = fromVersion }
end, { rate = 2 })

CP.Net.action('server:builder:breakLock', function(src, payload)
    local actor, perms = Begin(src)
    if not actor then return false, perms end
    local row, err = LoadRow(payload)
    if not row then return false, err end
    if not Allows(perms, row, actor, 'breakLock') then return false, 'err.no_permission' end
    if not row.lockActive then return true, { id = row.id, previous = nil } end
    local names = DisplayNames({ row.lockedBy })
    MySQL.update.await(
        'UPDATE cp_custom_missions SET locked_by = NULL, locked_until = NULL, updated_at = updated_at WHERE id = ?',
        { row.id })
    if row.lockedBy ~= actor.citizenid then
        brokenLocks[row.id] = brokenLocks[row.id] or {}
        brokenLocks[row.id][row.lockedBy] = true
    end
    local def = CurrentDef(row) or {}
    TellEditor(row.lockedBy, 'lockBroken', row.id, 'builder.lock_broken',
        { name = actor.name or actor.citizenid, mission = tostring(def.label or row.id) },
        actor.name or actor.citizenid)
    Audit(actor, 'breakLock', row.id, row.lockedBy, nil, nil)
    PushAll({ event = 'lockBroken', id = row.id, by = actor.name })
    return true, { id = row.id, previous = { citizenid = row.lockedBy, name = names[row.lockedBy] } }
end, { rate = 2 })

CP.Net.action('server:builder:discardDraft', function(src, payload)
    local actor, perms = Begin(src)
    if not actor then return false, perms end
    local row, err = LoadRow(payload)
    if not row then return false, err end
    if not Allows(perms, row, actor, 'edit') then return false, 'err.no_permission' end
    if row.lockActive and row.lockedBy ~= actor.citizenid then return false, 'err.builder_locked' end
    if type(row.draft) ~= 'table' then return false, 'err.builder_no_draft' end
    local deleted = false
    if row.publishedVersion == nil and row.status == 'draft' then
        local n = MySQL.update.await('DELETE FROM cp_custom_missions WHERE id = ? AND published_version IS NULL',
            { row.id })
        deleted = (tonumber(n) or 0) > 0
    else
        MySQL.update.await(
            [[UPDATE cp_custom_missions SET draft_definition = NULL, draft_version = NULL, draft_tested = 0,
            locked_by = NULL, locked_until = NULL, updated_by = ? WHERE id = ?]], { actor.citizenid, row.id })
    end
    pendingTests[row.id] = nil
    if deleted then brokenLocks[row.id] = nil end
    Audit(actor, 'discardDraft', row.id, row.draftVersion and ('v' .. row.draftVersion) or nil,
        deleted and 'deleted' or nil, nil)
    PushAll({ event = deleted and 'deleted' or 'changed', id = row.id, by = actor.name })
    return true, { id = row.id, deleted = deleted }
end, { rate = 2 })

-- ============================================================================
--                          LOCKS OF PLAYERS WHO LEAVE
-- ============================================================================

local function ReleaseFor(src)
    local cid = holders[src]
    holders[src] = nil
    viewers[src] = nil
    for key in pairs(lastAutosave) do
        if key:sub(1, #tostring(src) + 1) == tostring(src) .. ':' then lastAutosave[key] = nil end
    end
    if cid then
        CreateThread(function()
            local ok, err = pcall(ReleaseLocksOf, cid)
            if not ok then CP.err(TAG, 'releasing the edit locks of %s failed: %s', cid, tostring(err)) end
        end)
    end
end

AddEventHandler('playerDropped', function()
    local src = source
    ReleaseFor(src)
end)

CreateThread(function()
    if CP.Qbx and CP.Qbx.onPlayerUnload then
        CP.Qbx.onPlayerUnload(function(src) ReleaseFor(src) end)
    end
end)

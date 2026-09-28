-- modules/missions/server.lua · CP.Missions: the mission registry (loader, normaliser, validator).
--
-- Owns
--   * loading missions/builtin/index.lua (a Lua file that returns a list of ids) and every
--     missions/builtin/<id>.lua with LoadResourceFile, each run in a sandbox whose only globals are
--     RegisterMission, vec3, vec4, vector3, vector4, math, string, table (copies), pairs, ipairs,
--     tonumber, tostring and type; exactly one RegisterMission({ ... }) call per file
--   * custom missions from CP.Builder.loadPublished() (the builder owns their files and DB rows)
--   * normalising every definition (defaults from the block's defaults(), minSeconds per block,
--     presenceRange = Config.Blocks[block].presenceRange[3]) and validating it (generic checks + the
--     block's validate(obj, mission, location) for every location); invalid missions are rejected
--     with a console warning, the rest load. Payout fields in a file are ignored with a warning.
--   * loader fields: source, version (custom), filePath, defHash (CP.U.hashHex of the file content),
--     editedInCode, isBoss (weekly_boss_kingpin), status
--   * sending the definitions to clients: crimson-police:client:missions (full list, vectors as
--     { x, y, z[, w] }) after every load/change, and the getMissionDefs callback for joining players
--
-- Public API (server)
--   CP.Missions.loadAll() -> summary          summary = { loaded, builtin, custom, failed = { { id, file, error } }, warnings }
--   CP.Missions.reload() -> summary           CP.Builder.onReload() (hand edits) first, then loadAll(); summary.builder
--   CP.Missions.get(id) -> def|nil
--   CP.Missions.all() -> { [id] = def }       (a copy of the map; the defs are shared, do not mutate them)
--   CP.Missions.list() -> { def, ... }        sorted by id
--   CP.Missions.byType(missionType) -> list   sorted by id, never the Weekly Boss
--   CP.Missions.isEnabled(id) -> boolean      loaded, status 'published', not in Config.DisabledMissions
--   CP.Missions.normalize(def, meta) -> def|nil, err   pure; meta = { source, version, filePath, defHash, editedInCode, status }
--   CP.Missions.serializeForClient(def) -> table
--   CP.Missions.register(def) -> def|nil, err  publish/restore without a reload (loader fields read from def)
--   CP.Missions.unregister(id) -> boolean      archive without a reload (custom missions only)
-- Net
--   callback 'getMissionDefs' -> list of serialized definitions (err.not_ready before the first load)
--   action 'server:admin:reloadMissions' (permission reloadMissions) -> summary
--   event 'crimson-police:client:missions' (list) to every client after each load / register / unregister
--
-- Contract interpretations (details in docs/notes/engine_a.md)
--   * CP.Builder.loadPublished() entries: a definition with loader fields, { def, meta }, or meta only
--     ({ id, filePath, version }) whose file is read here; if the hook throws, loaded custom missions stay
--   * reload(): CP.Builder.onReload() first, then loadAll()
--   * design rules the builder enforces for custom missions (location count and gap, armed budget,
--     maxBlocks) are warnings here; playability rules reject the mission
--   * validation reasons are English developer-facing text (console, builder), not locale keys

CP.Missions = CP.Missions or {}
local Missions = CP.Missions

local TAG = 'missions'
local BOSS_ID = 'weekly_boss_kingpin'
local BUILTIN_DIR = 'missions/builtin/'
local INDEX_FILE = BUILTIN_DIR .. 'index.lua'

-- ARCHITECTURE §3.3: default minimum believable seconds per block.
local DEFAULT_MIN_SECONDS = {
    checkpoint_route = 20, interact_points = 5, skill_check = 10, hostile_waves = 60,
    protect_rescue = 15, flee_arrest = 30, pursuit = 30, escort = 60, search_area = 60,
}
-- Built-in missions ship with 5+ locations, these with 3+ (Mission catalog design rules).
local THREE_LOCATIONS_OK = { armored_truck_escort = true, evoc_course = true, weekly_boss_kingpin = true }
-- Fields only the loader sets; a file that sets them is overridden.
local LOADER_FIELDS = { 'source', 'version', 'filePath', 'defHash', 'editedInCode', 'isBoss', 'status' }
-- Top-level names treated as a hand-added payout (besides anything containing "payout").
local PAYOUT_NAMES = { cash = true, cashbase = true, basepay = true, money = true, pay = true, reward = true, rewards = true }

local defs = {}            -- id -> normalised definition
local loadedOnce = false
local loading = false
local lastSummary = nil
local clientList = {}      -- serialized definitions for clients, rebuilt on every change

-- ── small helpers ───────────────────────────────────────────────────────────
local function isVec(v)
    local t = type(v)
    if t == 'vector3' or t == 'vector4' then return true end
    return t == 'table' and type(v.x) == 'number' and type(v.y) == 'number' and type(v.z) == 'number'
end

local function isList(t)
    if type(t) ~= 'table' then return false end
    local n = #t
    for k in pairs(t) do
        if type(k) ~= 'number' or k < 1 or k > n or k % 1 ~= 0 then return false end
    end
    return true
end

local function isInt(v)
    return type(v) == 'number' and v == math.floor(v)
end

local function isPayoutField(k)
    if type(k) ~= 'string' then return false end
    local lower = k:lower()
    return lower:find('payout', 1, true) ~= nil or PAYOUT_NAMES[lower] == true
end

local function copyLib(lib)
    local out = {}
    for k, v in pairs(lib) do out[k] = v end
    return out
end

-- Canonical text of a value (sorted keys) for a stable hash when there is no file content.
local function canonical(v, out)
    local t = type(v)
    if t == 'vector3' or t == 'vector4' or t == 'vector2' then v = CP.U.vecToTable(v); t = 'table' end
    if t ~= 'table' then
        out[#out + 1] = t:sub(1, 1) .. tostring(v)
        return
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) == type(b) and (type(a) == 'number' or type(a) == 'string') then return a < b end
        return type(a) < type(b)
    end)
    out[#out + 1] = '{'
    for _, k in ipairs(keys) do
        out[#out + 1] = tostring(k) .. '='
        canonical(v[k], out)
        out[#out + 1] = ','
    end
    out[#out + 1] = '}'
end

local function stableHash(def)
    local out = {}
    canonical(def, out)
    return CP.U.hashHex(table.concat(out))
end

local function blockPresenceDefault(blockId)
    local cfg = Config.Blocks and Config.Blocks[blockId]
    local range = cfg and cfg.presenceRange
    if type(range) == 'table' and tonumber(range[3]) then return tonumber(range[3]) end
    return tonumber(Config.AntiCheat and Config.AntiCheat.presenceRadius) or 150.0
end

local function detailDefault(name, fallback)
    local d = Config.Blocks and Config.Blocks.details and Config.Blocks.details[name]
    if type(d) == 'table' and tonumber(d[3]) then return tonumber(d[3]) end
    return fallback
end

-- ── sandbox ─────────────────────────────────────────────────────────────────
-- Runs one mission file and returns the table passed to its single RegisterMission call.
local function runMissionFile(content, chunkName)
    if type(content) ~= 'string' or content == '' then return nil, 'the file is empty' end
    local collected = {}
    local env = {
        RegisterMission = function(def) collected[#collected + 1] = def end,
        vec3 = vec3 or vector3, vec4 = vec4 or vector4, vector3 = vector3, vector4 = vector4,
        math = copyLib(math), string = copyLib(string), table = copyLib(table),
        pairs = pairs, ipairs = ipairs, tonumber = tonumber, tostring = tostring, type = type,
    }
    local chunk, err = load(content, '@' .. chunkName, 't', env)
    if not chunk then return nil, 'syntax error: ' .. tostring(err) end
    local ok, runErr = pcall(chunk)
    if not ok then return nil, 'error while running the file: ' .. tostring(runErr) end
    if #collected == 0 then return nil, 'the file never calls RegisterMission({ ... })' end
    if #collected > 1 then
        return nil, ('the file calls RegisterMission %d times; exactly one call is allowed'):format(#collected)
    end
    if type(collected[1]) ~= 'table' then return nil, 'RegisterMission expects a table' end
    return collected[1]
end

local function readIndex()
    local content = LoadResourceFile(CP.resource, INDEX_FILE)
    if not content or content == '' then
        return nil, INDEX_FILE .. ' was not found; no built-in missions are loaded'
    end
    local chunk, err = load(content, '@' .. INDEX_FILE, 't', {})
    if not chunk then return nil, INDEX_FILE .. ': syntax error: ' .. tostring(err) end
    local ok, list = pcall(chunk)
    if not ok then return nil, INDEX_FILE .. ': ' .. tostring(list) end
    if type(list) ~= 'table' then return nil, INDEX_FILE .. ' must return a list of mission ids' end
    local ids, seen = {}, {}
    for i, id in ipairs(list) do
        if type(id) ~= 'string' or not id:match('^[%a][%w_]*$') then
            CP.warn(TAG, '%s entry %d (%s) is not a valid mission id; skipped', INDEX_FILE, i, tostring(id))
        elseif seen[id] then
            CP.warn(TAG, '%s lists %s twice; loaded once', INDEX_FILE, id)
        else
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    return ids
end

-- ── normalise and validate ──────────────────────────────────────────────────
local function checkRange(v, lo, hi)
    return type(v) == 'number' and v >= lo and v <= hi
end

local function normalizeStart(loc, i, warn)
    local start = loc.start
    if isVec(start) then
        warn(('location %d: start should be { coords = vec3, radius = n }; using radius 50'):format(i))
        start = { coords = start, radius = 50.0 }
    end
    if type(start) ~= 'table' or not isVec(start.coords) then
        return nil, ('location %d has no start = { coords = vec3(...), radius = n }'):format(i)
    end
    if start.radius == nil then
        warn(('location %d: start.radius missing; using 50'):format(i))
        start.radius = 50.0
    end
    if not (type(start.radius) == 'number' and start.radius > 0) then
        return nil, ('location %d: start.radius must be a positive number'):format(i)
    end
    loc.start = start
    return true
end

local function normalizeEntries(list, field, warn)
    local out = {}
    if list == nil then return out end
    if not isList(list) then
        warn(field .. ' must be a list; ignored')
        return out
    end
    for i, e in ipairs(list) do
        if type(e) ~= 'table' or type(e.id) ~= 'string' or e.id == '' then
            warn(('%s entry %d has no id; ignored'):format(field, i))
        else
            local known = Config.Bonuses and Config.Bonuses[e.id]
            local hasValue = type(e.points) == 'number' or type(e.pctOfPoints) == 'number'
            if (e.points ~= nil and type(e.points) ~= 'number') or (e.pctOfPoints ~= nil and type(e.pctOfPoints) ~= 'number') then
                warn(('%s entry %s: points and pctOfPoints must be numbers; ignored'):format(field, e.id))
            elseif not known and not hasValue then
                warn(('%s entry %s is not in Config.Bonuses and has no points/pctOfPoints; ignored'):format(field, e.id))
            else
                out[#out + 1] = { id = e.id, points = e.points, pctOfPoints = e.pctOfPoints, each = e.each == true or nil }
                for k, v in pairs(e) do
                    if out[#out][k] == nil and k ~= 'each' then out[#out][k] = v end
                end
            end
        end
    end
    return out
end

local function normalizeItems(list, warn)
    local out = {}
    if list == nil then return out end
    if not isList(list) then
        warn('items must be a list; ignored')
        return out
    end
    for i, it in ipairs(list) do
        if type(it) ~= 'table' or type(it.name) ~= 'string' or it.name == '' then
            warn(('items entry %d has no name; ignored'):format(i))
        else
            local count = tonumber(it.count) or 1
            if count < 1 then count = 1 end
            out[#out + 1] = { name = it.name, count = math.floor(count), metadata = it.metadata }
        end
    end
    return out
end

local function entryPath(entry)
    if CP.Scaling and CP.Scaling._entryPath then return CP.Scaling._entryPath(entry) end
    local path = type(entry) == 'string' and entry or (type(entry) == 'table' and entry.path)
    if type(path) ~= 'string' then return nil end
    path = CP.U.trim(path)
    if path:sub(1, 11) == 'objectives.' then path = path:sub(12) end
    if not path:match('^%d+') then return nil end
    return path, type(entry) == 'table' and tonumber(entry.max) or nil
end

local function isScalable(v)
    if CP.Scaling and CP.Scaling._isScalable then return CP.Scaling._isScalable(v) end
    if type(v) == 'number' then return true end
    if not isList(v) or #v == 0 then return false end
    for _, x in ipairs(v) do if type(x) ~= 'number' then return false end end
    return true
end

local function normalizeScaling(d, warn)
    local out = {}
    if d.scaling == nil then return out end
    if not isList(d.scaling) then
        warn('scaling must be a list of paths; ignored')
        return out
    end
    for i, entry in ipairs(d.scaling) do
        local path, max = entryPath(entry)
        if not path then
            warn(('scaling entry %d is not a path like objectives.1.waves; ignored'):format(i))
        else
            local value = CP.U.getPath(d.objectives, path)
            if not isScalable(value) then
                warn(('scaling objectives.%s is not a number or a list of numbers; ignored'):format(path))
            else
                if max then
                    local values = type(value) == 'number' and { value } or value
                    for _, v in ipairs(values) do
                        if v > max then warn(('scaling objectives.%s: base %s is above its max %s'):format(path, tostring(v), tostring(max))) break end
                    end
                    out[#out + 1] = { path = 'objectives.' .. path, max = max }
                else
                    out[#out + 1] = 'objectives.' .. path
                end
            end
        end
    end
    return out
end

-- Returns the normalised copy, or nil and a reason. Pure: no registry change, no broadcast.
function Missions.normalize(def, meta)
    if type(def) ~= 'table' then return nil, 'the definition is not a table' end
    meta = meta or {}
    local d = CP.U.deepcopy(def)
    local idText = tostring(d.id)
    local warnings = 0
    local function warn(msg)
        warnings = warnings + 1
        CP.warn(TAG, 'mission %s: %s', idText, msg)
    end

    for _, k in ipairs(LOADER_FIELDS) do d[k] = nil end
    for _, k in ipairs(CP.U.keys(d)) do
        if isPayoutField(k) then
            warn(('field "%s" ignored: payouts only come from the Payouts screens'):format(tostring(k)))
            d[k] = nil
        end
    end

    -- identity
    if type(d.id) ~= 'string' or not d.id:match('^[%a][%w_]*$') or #d.id > 40 then
        return nil, 'id must start with a letter and use only letters, digits and underscores (at most 40)'
    end
    if type(d.label) ~= 'string' or CP.U.trim(d.label) == '' then return nil, 'label is missing' end
    if d.description ~= nil and type(d.description) ~= 'string' then return nil, 'description must be text' end
    d.description = d.description or ''
    local isBoss = d.id == BOSS_ID
    if isBoss and d.type ~= 'tactical' then
        warn('the Weekly Boss is always stored as a Tactical mission; type set to tactical')
        d.type = 'tactical'
    end
    if type(d.type) ~= 'string' or not (Config.MissionTypes and Config.MissionTypes[d.type]) then
        return nil, ('type "%s" is not a key of Config.MissionTypes'):format(tostring(d.type))
    end

    -- departments: {} = every department; a { key = true } map is accepted too
    if d.departments == nil then d.departments = {} end
    if type(d.departments) ~= 'table' then return nil, 'departments must be a list of department keys' end
    if not isList(d.departments) then
        local list = {}
        for k, v in pairs(d.departments) do if v and type(k) == 'string' then list[#list + 1] = k end end
        table.sort(list)
        d.departments = list
    end
    for _, key in ipairs(d.departments) do
        if type(key) ~= 'string' then return nil, 'departments must be a list of department keys' end
        if not (Config.Departments and Config.Departments[key]) then
            warn(('department "%s" is not in Config.Departments'):format(key))
        end
    end

    -- officers, difficulty, timings
    d.minOfficers = d.minOfficers == nil and 1 or d.minOfficers
    d.maxOfficers = d.maxOfficers == nil and d.minOfficers or d.maxOfficers
    local maxUnit = tonumber(Config.Limits and Config.Limits.maxUnitSize) or 4
    if not (isInt(d.minOfficers) and isInt(d.maxOfficers) and d.minOfficers >= 1 and d.minOfficers <= d.maxOfficers and d.maxOfficers <= maxUnit) then
        return nil, ('minOfficers/maxOfficers must be whole numbers with 1 <= min <= max <= %d'):format(maxUnit)
    end
    if d.difficulty == nil then d.difficulty = detailDefault('difficulty', 2) end
    local stars = #((Config.Difficulty and Config.Difficulty.pointsByStars) or { 1, 1, 1 })
    if not (isInt(d.difficulty) and d.difficulty >= 1 and d.difficulty <= stars) then
        return nil, ('difficulty must be 1 to %d stars'):format(stars)
    end
    if not checkRange(d.timeLimit, 60, 3600) then return nil, 'timeLimit must be 60 to 3600 seconds' end
    d.timeLimit = math.floor(d.timeLimit)
    if d.startTimeout == nil then d.startTimeout = tonumber(Config.Limits and Config.Limits.startTimeout) or 600 end
    if not checkRange(d.startTimeout, 60, 3600) then return nil, 'startTimeout must be 60 to 3600 seconds' end
    d.startTimeout = math.floor(d.startTimeout)
    if d.cooldown == nil then d.cooldown = detailDefault('cooldown', 1200) end
    if not checkRange(d.cooldown, 0, 86400) then return nil, 'cooldown must be 0 to 86400 seconds' end
    d.cooldown = math.floor(d.cooldown)
    if d.vehiclePenalties == nil then
        local vp = Config.Blocks and Config.Blocks.details and Config.Blocks.details.vehiclePenalties
        d.vehiclePenalties = not (type(vp) == 'table' and vp.default == false)
    end
    if type(d.vehiclePenalties) ~= 'boolean' then return nil, 'vehiclePenalties must be true or false' end

    -- locations
    if not isList(d.locations) or #d.locations == 0 then return nil, 'locations must be a non-empty list' end
    for i, loc in ipairs(d.locations) do
        if type(loc) ~= 'table' then return nil, ('location %d is not a table'):format(i) end
        local ok, err = normalizeStart(loc, i, warn)
        if not ok then return nil, err end
        if loc.label == nil then loc.label = CP.L('run.location_default', { n = i }) end
        if type(loc.label) ~= 'string' then return nil, ('location %d: label must be text'):format(i) end
    end
    local source = meta.source or 'builtin'
    local minLocations = source == 'custom' and (tonumber(Config.Builder and Config.Builder.minLocations) or 3)
        or (THREE_LOCATIONS_OK[d.id] and 3 or 5)
    if #d.locations < minLocations then
        warn(('has %d location(s); %d or more are expected'):format(#d.locations, minLocations))
    end
    local gap = tonumber(Config.Builder and Config.Builder.minLocationGap) or 0
    if gap > 0 then
        for i = 1, #d.locations do
            for j = i + 1, #d.locations do
                if CP.U.dist(d.locations[i].start.coords, d.locations[j].start.coords) < gap then
                    warn(('locations %d and %d are less than %d m apart'):format(i, j, math.floor(gap)))
                end
            end
        end
    end

    -- objectives: block defaults, common defaults, generic checks
    if not isList(d.objectives) or #d.objectives == 0 then return nil, 'objectives must be a non-empty list' end
    for i, obj in ipairs(d.objectives) do
        if type(obj) ~= 'table' then return nil, ('objective %d is not a table'):format(i) end
        local blockId = obj.block
        if type(blockId) ~= 'string' then return nil, ('objective %d has no block'):format(i) end
        local impl = CP.Blocks.get(blockId)
        if not impl then return nil, ('objective %d uses unknown block "%s"'):format(i, blockId) end
        if type(impl.defaults) == 'function' then
            local ok, res = pcall(impl.defaults, obj)
            if not ok then return nil, ('objective %d (%s): defaults failed: %s'):format(i, blockId, tostring(res)) end
            if type(res) == 'table' then obj = res end
        end
        obj.block = blockId
        if obj.minSeconds == nil then obj.minSeconds = DEFAULT_MIN_SECONDS[blockId] or 0 end
        if obj.presenceRange == nil then obj.presenceRange = blockPresenceDefault(blockId) end
        if type(obj.label) ~= 'string' or CP.U.trim(obj.label) == '' then
            obj.label = CP.L('run.objective_default', { n = i })
        end
        if not (type(obj.minSeconds) == 'number' and obj.minSeconds >= 0) then
            return nil, ('objective %d (%s): minSeconds must be a number >= 0'):format(i, blockId)
        end
        if not (type(obj.presenceRange) == 'number' and obj.presenceRange > 0) then
            return nil, ('objective %d (%s): presenceRange must be a positive number'):format(i, blockId)
        end
        d.objectives[i] = obj
    end
    local maxBlocks = tonumber(Config.Builder and Config.Builder.maxBlocks) or 0
    if maxBlocks > 0 and #d.objectives > maxBlocks then
        warn(('has %d objectives; the Mission Builder allows %d'):format(#d.objectives, maxBlocks))
    end

    -- block guardrails for every location
    local armed = 0
    for i, obj in ipairs(d.objectives) do
        local impl = CP.Blocks.get(obj.block)
        if type(impl.validate) == 'function' then
            for li, loc in ipairs(d.locations) do
                local okCall, res, reason = pcall(impl.validate, obj, d, loc)
                if not okCall then
                    return nil, ('objective %d (%s), location %d: validate failed: %s'):format(i, obj.block, li, tostring(res))
                end
                if res == false or res == nil then
                    if type(reason) == 'string' and CP.Locale and CP.Locale.has and CP.Locale.has(reason) then
                        reason = CP.L(reason)
                    end
                    return nil, ('objective %d (%s), location %d (%s): %s'):format(i, obj.block, li, tostring(loc.label), tostring(reason or 'invalid'))
                end
            end
        end
        if type(impl.armedCount) == 'function' then
            local okCall, n = pcall(impl.armedCount, obj)
            if okCall and type(n) == 'number' then armed = armed + n end
        end
    end
    local maxArmed = tonumber(Config.Builder and Config.Builder.maxHostiles) or 0
    if maxArmed > 0 and armed > maxArmed then
        warn(('has %d armed NPCs before scaling; the budget is %d'):format(armed, maxArmed))
    end

    -- the rest
    d.scaling = normalizeScaling(d, warn)
    d.items = normalizeItems(d.items, warn)
    d.bonuses = normalizeEntries(d.bonuses, 'bonuses', warn)
    d.penalties = normalizeEntries(d.penalties, 'penalties', warn)

    -- loader fields
    d.source = source
    d.version = source == 'custom' and tonumber(meta.version) or nil
    d.filePath = meta.filePath
    d.defHash = meta.defHash or stableHash(def)
    d.editedInCode = meta.editedInCode == true or CP.U.truthy(meta.editedInCode)
    d.isBoss = isBoss
    d.status = meta.status or 'published'
    return d, nil, warnings
end

function Missions.serializeForClient(def)
    return CP.U.serialize(def)
end

-- ── registry ────────────────────────────────────────────────────────────────
local function sortedDefs(filter)
    local out = {}
    for _, def in pairs(defs) do
        if not filter or filter(def) then out[#out + 1] = def end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

local function broadcast()
    local list = {}
    for _, def in ipairs(sortedDefs()) do list[#list + 1] = Missions.serializeForClient(def) end
    clientList = list
    TriggerClientEvent(CP.e('client:missions'), -1, clientList)
    CP.log(TAG, 'sent %d mission definitions to clients', #clientList)
end

function Missions.get(id)
    if type(id) ~= 'string' then return nil end
    return defs[id]
end

function Missions.all()
    return CP.U.copy(defs)
end

function Missions.list()
    return sortedDefs()
end

function Missions.byType(missionType)
    return sortedDefs(function(def) return def.type == missionType and not def.isBoss end)
end

function Missions.isEnabled(id)
    local def = Missions.get(id)
    if not def then return false end
    if (def.status or 'published') ~= 'published' then return false end
    if CP.U.contains(Config.DisabledMissions or {}, id) then return false end
    return true
end

local function metaFromDef(def, defaults)
    defaults = defaults or {}
    return {
        source = def.source or defaults.source or 'custom',
        version = def.version or defaults.version,
        filePath = def.filePath or def.file_path or defaults.filePath,
        defHash = def.defHash or defaults.defHash,
        editedInCode = def.editedInCode or def.edited_in_code or defaults.editedInCode,
        status = def.status or defaults.status or 'published',
    }
end

function Missions.register(def)
    if type(def) ~= 'table' then return nil, 'the definition is not a table' end
    local meta = metaFromDef(def)
    if not meta.defHash and meta.filePath then
        local content = LoadResourceFile(CP.resource, meta.filePath)
        if content and content ~= '' then meta.defHash = CP.U.hashHex(content) end
    end
    local d, err = Missions.normalize(def, meta)
    if not d then
        CP.warn(TAG, 'mission %s was not registered: %s', tostring(def.id), tostring(err))
        return nil, err
    end
    local existing = defs[d.id]
    if existing and existing.source == 'builtin' and d.source ~= 'builtin' then
        CP.warn(TAG, 'mission %s was not registered: a built-in mission uses this id', d.id)
        return nil, 'a built-in mission already uses this id'
    end
    defs[d.id] = d
    CP.log(TAG, 'registered %s (%s v%s)', d.id, d.source, tostring(d.version))
    broadcast()
    return d
end

function Missions.unregister(id)
    local def = Missions.get(id)
    if not def then return false end
    if def.source == 'builtin' then
        CP.warn(TAG, 'built-in mission %s cannot be unregistered; turn it off in Config.DisabledMissions', id)
        return false
    end
    defs[id] = nil
    CP.log(TAG, 'unregistered %s', id)
    broadcast()
    return true
end

-- A custom entry from CP.Builder.loadPublished(): a definition (with loader fields), { def, meta },
-- or only meta ({ id, filePath, version, ... }) whose file is then read here.
local function customEntry(entry)
    if type(entry) ~= 'table' then return nil, nil, 'entry is not a table' end
    local raw, meta
    if type(entry.def) == 'table' then
        raw = entry.def
        meta = metaFromDef(entry.meta or entry, metaFromDef(raw))
    else
        raw = entry
        meta = metaFromDef(entry)
    end
    meta.source = 'custom'
    local content
    if meta.filePath then content = LoadResourceFile(CP.resource, meta.filePath) end
    if raw.objectives == nil and raw.locations == nil and meta.filePath then
        if not content or content == '' then
            return nil, meta, ('file %s was not found'):format(tostring(meta.filePath))
        end
        local fileDef, err = runMissionFile(content, meta.filePath)
        if not fileDef then return nil, meta, err end
        raw = fileDef
    end
    if not meta.defHash then
        meta.defHash = (content and content ~= '') and CP.U.hashHex(content) or stableHash(raw)
    end
    return raw, meta
end

function Missions.loadAll()
    if loading then
        -- Another load is in progress: wait for it and return its result.
        local waited = 0
        while loading and waited < 60000 do Wait(100); waited = waited + 100 end
        return lastSummary or { loaded = 0, builtin = 0, custom = 0, failed = {}, warnings = 0 }
    end
    loading = true
    local summary = { loaded = 0, builtin = 0, custom = 0, failed = {}, warnings = 0 }
    local newDefs = {}

    local function failed(id, file, err)
        summary.failed[#summary.failed + 1] = { id = id, file = file, error = err }
        CP.warn(TAG, 'mission %s (%s) was not loaded: %s', tostring(id), tostring(file or '-'), tostring(err))
    end

    local okAll, errAll = pcall(function()
        -- built-in missions
        local ids, indexErr = readIndex()
        if not ids then
            CP.warn(TAG, '%s', indexErr)
            ids = {}
        end
        for _, id in ipairs(ids) do
            local path = BUILTIN_DIR .. id .. '.lua'
            local content = LoadResourceFile(CP.resource, path)
            if not content or content == '' then
                failed(id, path, 'file not found')
            else
                local raw, err = runMissionFile(content, path)
                if not raw then
                    failed(id, path, err)
                elseif raw.id ~= id then
                    failed(id, path, ('its id "%s" does not match the file name'):format(tostring(raw.id)))
                else
                    local def, nerr, warnings = Missions.normalize(raw, {
                        source = 'builtin', filePath = path, defHash = CP.U.hashHex(content), status = 'published',
                    })
                    summary.warnings = summary.warnings + (warnings or 0)
                    if not def then
                        failed(id, path, nerr)
                    else
                        newDefs[id] = def
                        summary.builtin = summary.builtin + 1
                    end
                end
            end
        end

        -- custom missions (published), through the Mission Builder
        if CP.Builder and CP.Builder.loadPublished then
            CP.Migrations.ready()
            local okB, list = pcall(CP.Builder.loadPublished)
            if not okB then
                -- Keep the custom missions that are loaded now rather than dropping them from the pools.
                CP.err(TAG, 'CP.Builder.loadPublished failed; the loaded custom missions stay: %s', tostring(list))
                summary.builderError = tostring(list)
                for id, def in pairs(defs) do
                    if def.source == 'custom' and not newDefs[id] then
                        newDefs[id] = def
                        summary.custom = summary.custom + 1
                    end
                end
            elseif type(list) == 'table' then
                for i, entry in ipairs(list) do
                    local raw, meta, err = customEntry(entry)
                    local label = (type(entry) == 'table' and (entry.id or (entry.def and entry.def.id))) or ('#' .. i)
                    local file = meta and meta.filePath
                    if not raw then
                        failed(label, file, err)
                    else
                        local def, nerr, warnings = Missions.normalize(raw, meta)
                        summary.warnings = summary.warnings + (warnings or 0)
                        if not def then
                            failed(raw.id or label, file, nerr)
                        elseif newDefs[def.id] then
                            failed(def.id, file, 'another mission already uses this id')
                        else
                            newDefs[def.id] = def
                            summary.custom = summary.custom + 1
                        end
                    end
                end
            end
        end
    end)

    if not okAll then
        loading = false
        CP.err(TAG, 'loading missions failed; the previous missions stay loaded: %s', tostring(errAll))
        summary.error = tostring(errAll)
        summary.loaded = CP.U.count(defs)
        lastSummary = summary
        return summary
    end

    defs = newDefs
    loadedOnce = true
    loading = false
    summary.loaded = summary.builtin + summary.custom
    lastSummary = summary
    print(('[crimson-police] missions loaded: %d built-in, %d custom, %d rejected'):format(summary.builtin, summary.custom, #summary.failed))
    broadcast()
    return summary
end

function Missions.reload()
    local builderResult
    if CP.Builder and CP.Builder.onReload then
        CP.Migrations.ready()
        local ok, res = pcall(CP.Builder.onReload)
        if ok then
            builderResult = res
        else
            CP.err(TAG, 'CP.Builder.onReload failed: %s', tostring(res))
            builderResult = { error = tostring(res) }
        end
    end
    local summary = Missions.loadAll()
    summary.builder = builderResult
    return summary
end

-- ── net ─────────────────────────────────────────────────────────────────────
CP.Net.callback('getMissionDefs', function(src)
    if not loadedOnce then return nil, 'err.not_ready' end
    return clientList
end, { rate = 2 })

local function plainSummary(summary)
    local failedList = {}
    for i, f in ipairs(summary.failed or {}) do
        failedList[i] = { id = tostring(f.id), file = f.file and tostring(f.file) or nil, error = tostring(f.error) }
    end
    return {
        loaded = summary.loaded or 0, builtin = summary.builtin or 0, custom = summary.custom or 0,
        warnings = summary.warnings or 0, failed = failedList, error = summary.error,
    }
end

CP.Net.action('server:admin:reloadMissions', function(src)
    if not (CP.Permissions and CP.Permissions.can) then return false, 'err.no_permission' end
    local allowed, errKey = CP.Permissions.can(src, 'reloadMissions')
    if not allowed then return false, errKey or 'err.no_permission' end
    if not CP.Net.rateOk(src, 'missions:reload', 1, 5000) then return false, 'err.rate_limited' end
    local before = CP.U.count(defs)
    local summary = Missions.reload()
    if CP.Admin and CP.Admin.audit then
        local role = 'admin'
        if src == 0 then
            role = 'console'
        elseif CP.Access and CP.Access.role then
            role = CP.Access.role(src) or 'admin'
        end
        pcall(CP.Admin.audit, src == 0 and 'console' or src, role, 'audit', 'reloadMissions', nil,
            tostring(before), ('%d loaded, %d rejected'):format(summary.loaded or 0, #(summary.failed or {})), nil)
    end
    return true, plainSummary(summary)
end, { rate = 2 })

-- ── start ───────────────────────────────────────────────────────────────────
CreateThread(function()
    Wait(0)   -- every module and block file of the resource has been loaded by now
    Missions.loadAll()
end)

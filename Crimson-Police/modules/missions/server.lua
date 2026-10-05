-- CP.Missions: the mission registry (loader, normaliser, validator).

CP.Missions = CP.Missions or {}
local Missions = CP.Missions

local TAG = 'missions'
local BOSS_ID = 'weekly_boss_kingpin'
local BUILTIN_DIR = 'missions/builtin/'
local INDEX_FILE = BUILTIN_DIR .. 'index.lua'
local LATENT_BPS = 200000       -- bytes per second for the definitions broadcast (latent event)
local MAX_ITEMS = 10            -- mission items per definition (the builder's limit)
local MAX_ITEM_COUNT = 100      -- count per item (the builder's limit)

-- ARCHITECTURE §3.3: default minimum believable seconds per block.
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
    field_contact = 30,
    process_scene = 5,
}
-- Built-in missions ship with 5+ locations, these with 3+ (Mission catalog design rules).
local THREE_LOCATIONS_OK = { armored_truck_escort = true, evoc_course = true, weekly_boss_kingpin = true }
-- Fields only the loader sets; a file that sets them is overridden.
local LOADER_FIELDS = { 'source', 'version', 'filePath', 'defHash', 'editedInCode', 'isBoss', 'status' }
-- Top-level names treated as a hand-added payout (besides anything containing "payout").
local PAYOUT_NAMES = {
    cash = true,
    cashbase = true,
    basepay = true,
    money = true,
    pay = true,
    reward = true,
    rewards = true,
    loot = true,
    prize = true,
    prizes = true,
}
-- Keys of Config.MissionTweaks entries (re-validated like the file itself).
local TWEAK_KEYS = {
    cooldown = true,
    timeLimit = true,
    startTimeout = true,
    disabledLocations = true,
    peds = true,
    vehicles = true,
    weapons = true,
}

local defs = {}            -- id -> normalised definition
local loadedOnce = false
local loading = false
local lastSummary = nil
local clientList = {}      -- serialized definitions for clients, rebuilt on every change

-- ============================================================================
--                                SMALL HELPERS
-- ============================================================================

local function IsVec(v)
    local t = type(v)
    if t == 'vector3' or t == 'vector4' then return true end
    return t == 'table' and type(v.x) == 'number' and type(v.y) == 'number' and type(v.z) == 'number'
end

local function IsList(t)
    if type(t) ~= 'table' then return false end
    local n = #t
    for k in pairs(t) do
        if type(k) ~= 'number' or k < 1 or k > n or k % 1 ~= 0 then return false end
    end
    return true
end

local function IsInt(v)
    return type(v) == 'number' and v == math.floor(v)
end

-- A payout- or reward-like top-level name: mission files never carry pay or item rewards (Config.Rewards).
local function IsPayoutField(k)
    if type(k) ~= 'string' then return false end
    local lower = k:lower()
    return lower:find('payout', 1, true) ~= nil or lower:find('reward', 1, true) ~= nil or PAYOUT_NAMES[lower] == true
end

local function CopyLib(lib)
    local out = {}
    for k, v in pairs(lib) do out[k] = v end
    return out
end

-- Canonical text of a value (sorted keys) for a stable hash when there is no file content.
local function Canonical(v, out)
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
        Canonical(v[k], out)
        out[#out + 1] = ','
    end
    out[#out + 1] = '}'
end

local function StableHash(def)
    local out = {}
    Canonical(def, out)
    return CP.U.hashHex(table.concat(out))
end

local function BlockPresenceDefault(blockId)
    local cfg = Config.Blocks and Config.Blocks[blockId]
    local range = cfg and cfg.presenceRange
    if type(range) == 'table' and tonumber(range[3]) then return tonumber(range[3]) end
    return tonumber(Config.AntiCheat and Config.AntiCheat.presenceRadius) or 150.0
end

-- The first vector inside v (recursively) that lies in a Config.Builder.noBuildZones zone (2D, like the
-- blocks and the builder): returns zone, path. nil when every point is outside.
local function PointInNoBuildZone(v, path, depth)
    depth = depth or 0
    if depth > 12 then return nil end
    local zones = Config.Builder and Config.Builder.noBuildZones
    if type(zones) ~= 'table' or #zones == 0 then return nil end
    if IsVec(v) then
        for _, z in ipairs(zones) do
            if z.coords and CP.U.dist2d(v, z.coords) <= (tonumber(z.radius) or 0) then return z, path end
        end
        return nil
    end
    if type(v) ~= 'table' then return nil end
    for k, x in pairs(v) do
        if type(x) == 'table' or IsVec(x) then
            local z, where = PointInNoBuildZone(x, path .. '.' .. tostring(k), depth + 1)
            if z then return z, where end
        end
    end
    return nil
end

local function DetailDefault(name, fallback)
    local d = Config.Blocks and Config.Blocks.details and Config.Blocks.details[name]
    if type(d) == 'table' and tonumber(d[3]) then return tonumber(d[3]) end
    return fallback
end

-- ============================================================================
--                                   SANDBOX
-- ============================================================================
-- Runs one mission file and returns the table passed to its single RegisterMission call.
local function RunMissionFile(content, chunkName)
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

-- ARCHITECTURE §5.6: run one mission file's source in the loader sandbox and return the raw definition
-- (used by the Mission Builder for custom files and hand-edit reloads, and by CP.Testing).
-- chunkName may be given with or without the leading '@'.
function Missions.parse(luaSource, chunkName)
    local name = tostring(chunkName or 'mission')
    if name:sub(1, 1) == '@' then name = name:sub(2) end
    return RunMissionFile(luaSource, name)
end

local function ReadIndex()
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

-- ============================================================================
--                            NORMALISE AND VALIDATE
-- ============================================================================

local function CheckRange(v, lo, hi)
    return type(v) == 'number' and v >= lo and v <= hi
end

local function NormalizeStart(loc, i, warn)
    local start = loc.start
    if IsVec(start) then
        warn(('location %d: start should be { coords = vec3, radius = n }; using radius 50'):format(i))
        start = { coords = start, radius = 50.0 }
    end
    if type(start) ~= 'table' or not IsVec(start.coords) then
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

local function NormalizeEntries(list, field, warn)
    local out = {}
    if list == nil then return out end
    if not IsList(list) then
        warn(field .. ' must be a list; ignored')
        return out
    end
    for i, e in ipairs(list) do
        if type(e) ~= 'table' or type(e.id) ~= 'string' or e.id == '' then
            warn(('%s entry %d has no id; ignored'):format(field, i))
        else
            local known = Config.Bonuses and Config.Bonuses[e.id]
            local hasValue = type(e.points) == 'number' or type(e.pctOfPoints) == 'number'
            if (e.points ~= nil and type(e.points) ~= 'number')
                or (e.pctOfPoints ~= nil and type(e.pctOfPoints) ~= 'number') then
                warn(('%s entry %s: points and pctOfPoints must be numbers; ignored'):format(field, e.id))
            elseif not known and not hasValue then
                warn(
                    ('%s entry %s is not in Config.Bonuses and has no points/pctOfPoints; ignored'):format(field, e.id))
            elseif type(known) == 'table' and known.engineOnly == true then
                warn(('%s entry %s is awarded by the engine only and cannot be listed in a mission; ignored'):format(
                    field, e.id))
            else
                out[#out + 1] = {
                    id = e.id,
                    points = e.points,
                    pctOfPoints = e.pctOfPoints,
                    each = e.each == true or nil,
                }
                for k, v in pairs(e) do
                    if out[#out][k] == nil and k ~= 'each' then out[#out][k] = v end
                end
            end
        end
    end
    return out
end

-- docs/CRIMSON_ARENA.md rule 4: Crimson-Arena takes items with these names from players it believes
-- owe them, so a mission may never hand them out (and weapons are never mission items).
local function ForbiddenItem(name)
    local lower = name:lower()
    -- cash items would stand in for a payout
    if lower == 'money' or lower == 'black_money' then return true end
    return lower == 'armour' or lower == 'bandage' or lower:sub(1, 5) == 'ammo-' or lower:sub(1, 7) == 'weapon_'
end

-- Returns the item list, or nil and a reason when a forbidden item name is used.
local function NormalizeItems(list, warn)
    local out = {}
    if list == nil then return out end
    if not IsList(list) then
        warn('items must be a list; ignored')
        return out
    end
    for i, it in ipairs(list) do
        if type(it) ~= 'table' or type(it.name) ~= 'string' or it.name == '' then
            warn(('items entry %d has no name; ignored'):format(i))
        elseif ForbiddenItem(it.name) then
            return nil,
                ('items entry %d: "%s" can never be a mission item (armour, bandage, ammo-*, weapons and money are not allowed)'):format(
                    i, it.name)
        elseif #out >= MAX_ITEMS then
            warn(('items entry %d: more than %d items; ignored'):format(i, MAX_ITEMS))
        else
            local count = tonumber(it.count) or 1
            if count ~= count or count < 1 then count = 1 end
            if count > MAX_ITEM_COUNT then
                warn(('items entry %d: count %s is above %d; capped'):format(i, tostring(count), MAX_ITEM_COUNT))
                count = MAX_ITEM_COUNT
            end
            out[#out + 1] = { name = it.name, count = math.floor(count), metadata = it.metadata }
        end
    end
    return out
end

local function EntryPath(entry)
    if CP.Scaling and CP.Scaling._entryPath then return CP.Scaling._entryPath(entry) end
    local path = type(entry) == 'string' and entry or (type(entry) == 'table' and entry.path)
    if type(path) ~= 'string' then return nil end
    path = CP.U.trim(path)
    if path:sub(1, 11) == 'objectives.' then path = path:sub(12) end
    if not path:match('^%d+') then return nil end
    return path, type(entry) == 'table' and tonumber(entry.max) or nil
end

local function IsScalable(v)
    if CP.Scaling and CP.Scaling._isScalable then return CP.Scaling._isScalable(v) end
    if type(v) == 'number' then return true end
    if not IsList(v) or #v == 0 then return false end
    for _, x in ipairs(v) do if type(x) ~= 'number' then return false end end
    return true
end

local function NormalizeScaling(d, warn)
    local out = {}
    if d.scaling == nil then return out end
    if not IsList(d.scaling) then
        warn('scaling must be a list of paths; ignored')
        return out
    end
    for i, entry in ipairs(d.scaling) do
        local path, max = EntryPath(entry)
        if not path then
            warn(('scaling entry %d is not a path like objectives.1.waves; ignored'):format(i))
        else
            local value = CP.U.getPath(d.objectives, path)
            if not IsScalable(value) then
                warn(('scaling objectives.%s is not a number or a list of numbers; ignored'):format(path))
            else
                if max then
                    local values = type(value) == 'number' and { value } or value
                    for _, v in ipairs(values) do
                        if v > max then
                            warn(('scaling objectives.%s: base %s is above its max %s'):format(path, tostring(v),
                                tostring(max)))
                            break
                        end
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
        if IsPayoutField(k) then
            warn(('field "%s" ignored: payouts only come from the Payouts screens'):format(tostring(k)))
            d[k] = nil
        end
    end
    -- Loader fields first: the blocks' validate() reads mission.source (built-in missions are exempt
    -- from the Mission Builder's allowed lists), so it must be set before the guardrails run.
    local source = meta.source == 'custom' and 'custom' or 'builtin'
    d.source = source
    d.version = source == 'custom' and tonumber(meta.version) or nil
    d.filePath = meta.filePath
    d.status = meta.status or 'published'

    -- identity
    if type(d.id) ~= 'string' or not d.id:match('^[%a][%w_]*$') or #d.id > 40 then
        return nil, 'id must start with a letter and use only letters, digits and underscores (at most 40)'
    end
    if type(d.label) ~= 'string' or CP.U.trim(d.label) == '' then return nil, 'label is missing' end
    if d.description ~= nil and type(d.description) ~= 'string' then return nil, 'description must be text' end
    d.description = d.description or ''
    local isBoss = d.id == BOSS_ID
    d.isBoss = isBoss
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
    if not IsList(d.departments) then
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
    if
        not (
            IsInt(d.minOfficers)
            and IsInt(d.maxOfficers)
            and d.minOfficers >= 1
            and d.minOfficers <= d.maxOfficers
            and d.maxOfficers <= maxUnit
        )
    then
        return nil, ('minOfficers/maxOfficers must be whole numbers with 1 <= min <= max <= %d'):format(maxUnit)
    end
    if d.difficulty == nil then d.difficulty = DetailDefault('difficulty', 2) end
    local stars = #((Config.Difficulty and Config.Difficulty.pointsByStars) or { 1, 1, 1 })
    if not (IsInt(d.difficulty) and d.difficulty >= 1 and d.difficulty <= stars) then
        return nil, ('difficulty must be 1 to %d stars'):format(stars)
    end
    if not CheckRange(d.timeLimit, 60, 3600) then return nil, 'timeLimit must be 60 to 3600 seconds' end
    d.timeLimit = math.floor(d.timeLimit)
    if d.startTimeout == nil then d.startTimeout = tonumber(Config.Limits and Config.Limits.startTimeout) or 600 end
    if not CheckRange(d.startTimeout, 60, 3600) then return nil, 'startTimeout must be 60 to 3600 seconds' end
    d.startTimeout = math.floor(d.startTimeout)
    if d.cooldown == nil then d.cooldown = DetailDefault('cooldown', 1200) end
    if not CheckRange(d.cooldown, 0, 86400) then return nil, 'cooldown must be 0 to 86400 seconds' end
    d.cooldown = math.floor(d.cooldown)
    if d.vehiclePenalties == nil then
        local vp = Config.Blocks and Config.Blocks.details and Config.Blocks.details.vehiclePenalties
        d.vehiclePenalties = not (type(vp) == 'table' and vp.default == false)
    end
    if type(d.vehiclePenalties) ~= 'boolean' then return nil, 'vehiclePenalties must be true or false' end
    -- quietPatrol: lights and siren after the first arrival cost -10, personal (Beat Patrol, Business Check)
    if d.quietPatrol == nil then d.quietPatrol = false end
    if type(d.quietPatrol) ~= 'boolean' then return nil, 'quietPatrol must be true or false' end
    -- decisions: stricter overrides of Config.Decisions for this mission (graded by CP.Custody)
    if d.decisions ~= nil and type(d.decisions) ~= 'table' then return nil, 'decisions must be a table' end

    -- locations
    if not IsList(d.locations) or #d.locations == 0 then return nil, 'locations must be a non-empty list' end
    for i, loc in ipairs(d.locations) do
        if type(loc) ~= 'table' then return nil, ('location %d is not a table'):format(i) end
        local ok, err = NormalizeStart(loc, i, warn)
        if not ok then return nil, err end
        if loc.label == nil then loc.label = CP.L('run.location_default', { n = i }) end
        if type(loc.label) ~= 'string' then return nil, ('location %d: label must be text'):format(i) end
        -- docs/CRIMSON_ARENA.md rule 7: no point of a mission inside a Config.Builder.noBuildZones zone
        -- (police stations, hospitals, the prison interior and Crimson-Arena's match area and lobby).
        local zone, where = PointInNoBuildZone(loc, 'location')
        if zone then
            return nil,
                ('location %d (%s): %s is inside the no-build zone "%s"'):format(i, loc.label, where,
                    tostring(zone.label))
        end
    end
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
    if not IsList(d.objectives) or #d.objectives == 0 then return nil, 'objectives must be a non-empty list' end
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
        if obj.presenceRange == nil then obj.presenceRange = BlockPresenceDefault(blockId) end
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
                    return nil,
                        ('objective %d (%s), location %d: validate failed: %s'):format(i, obj.block, li, tostring(res))
                end
                if res == false or res == nil then
                    if type(reason) == 'string' and CP.Locale and CP.Locale.has and CP.Locale.has(reason) then
                        reason = CP.L(reason)
                    end
                    return nil,
                        ('objective %d (%s), location %d (%s): %s'):format(i, obj.block, li, tostring(loc.label),
                            tostring(reason or 'invalid'))
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
    d.scaling = NormalizeScaling(d, warn)
    local items, itemErr = NormalizeItems(d.items, warn)
    if not items then return nil, itemErr end
    d.items = items
    d.bonuses = NormalizeEntries(d.bonuses, 'bonuses', warn)
    d.penalties = NormalizeEntries(d.penalties, 'penalties', warn)

    -- remaining loader fields (source, version, filePath, status and isBoss are set above)
    d.defHash = meta.defHash or StableHash(def)
    d.editedInCode = meta.editedInCode == true or CP.U.truthy(meta.editedInCode)
    return d, nil, warnings
end

-- ============================================================================
--                           BUILT-IN MISSION TWEAKS
-- ============================================================================
-- Config.MissionTweaks[id] changes a built-in mission without editing its file. The tweaked copy goes
-- through normalize again; a tweak that names an unknown key, leaves fewer locations than the mission needs
-- or fails a guardrail is dropped with a warning and the file's definition is used.

local PED_BLOCKS = {
    hostile_waves = true,
    flee_arrest = true,
    search_area = true,
    protect_rescue = true,
    field_contact = true,
}
local VEHICLE_BLOCKS = { pursuit = true, field_contact = true }

local function StringList(v)
    if not IsList(v) or #v == 0 then return false end
    for _, x in ipairs(v) do if type(x) ~= 'string' or x == '' then return false end end
    return true
end

-- The tweaked raw definition, or nil and the reason the tweak is dropped.
local function ApplyTweak(raw, tweak)
    if type(tweak) ~= 'table' then return nil, 'the tweak is not a table' end
    for k in pairs(tweak) do
        if not TWEAK_KEYS[k] then return nil, ('unknown key "%s"'):format(tostring(k)) end
    end
    local d = CP.U.deepcopy(raw)
    for _, k in ipairs({ 'cooldown', 'timeLimit', 'startTimeout' }) do
        if tweak[k] ~= nil then
            if type(tweak[k]) ~= 'number' then return nil, k .. ' must be a number' end
            d[k] = tweak[k]
        end
    end
    if tweak.disabledLocations ~= nil then
        if not StringList(tweak.disabledLocations) then return nil, 'disabledLocations must be a list of labels' end
        local off = {}
        for _, l in ipairs(tweak.disabledLocations) do off[l] = true end
        local kept = {}
        local seen = {}
        for _, loc in ipairs(d.locations or {}) do
            local label = type(loc) == 'table' and loc.label or nil
            if not (label and off[label]) then kept[#kept + 1] = loc end
            if label then seen[label] = true end
        end
        local unknown = nil
        for l in pairs(off) do if not seen[l] then unknown = l end end
        if unknown then return nil, ('disabledLocations names an unknown location "%s"'):format(unknown) end
        local need = THREE_LOCATIONS_OK[d.id] and 3 or 5
        if #kept < need then
            return nil, ('it leaves %d location(s); the mission needs %d or more'):format(#kept, need)
        end
        d.locations = kept
    end
    for _, k in ipairs({ 'peds', 'vehicles', 'weapons' }) do
        if tweak[k] ~= nil and not StringList(tweak[k]) then return nil, k .. ' must be a list of names' end
    end
    for _, obj in ipairs(type(d.objectives) == 'table' and d.objectives or {}) do
        if type(obj) == 'table' then
            if tweak.weapons and obj.weapons ~= nil then obj.weapons = CP.U.copy(tweak.weapons) end
            if tweak.peds and PED_BLOCKS[obj.block] then
                if obj.peds ~= nil then
                    obj.peds = CP.U.copy(tweak.peds)
                elseif obj.models ~= nil then
                    obj.models = CP.U.copy(tweak.peds)
                end
            end
            if tweak.vehicles and VEHICLE_BLOCKS[obj.block] then
                if obj.vehicles ~= nil and type(obj.vehicles) == 'table' then
                    obj.vehicles = CP.U.copy(tweak.vehicles)
                elseif obj.models ~= nil then
                    obj.models = CP.U.copy(tweak.vehicles)
                end
            end
        end
    end
    return d
end

-- The built-in definition with its Config.MissionTweaks entry applied, or def when there is none or the
-- tweak is dropped.
local function Tweaked(id, raw, def, meta)
    local tweaks = Config.MissionTweaks
    local tweak = type(tweaks) == 'table' and tweaks[id] or nil
    if tweak == nil then return def end
    local d, why = ApplyTweak(raw, tweak)
    if not d then
        CP.warn(TAG, 'Config.MissionTweaks.%s was ignored: %s', id, why)
        return def
    end
    local out, err = Missions.normalize(d, meta)
    if not out then
        CP.warn(TAG, 'Config.MissionTweaks.%s was ignored: %s', id, tostring(err))
        return def
    end
    out.tweaked = true
    CP.log(TAG, 'mission %s: Config.MissionTweaks applied', id)
    return out
end
Missions._applyTweak = ApplyTweak

-- A translatable mission text: the locale key mission.<id>.<field> (mission.<id>.location.<n> for a
-- location label) wins over the file's text; custom missions keep theirs when the locale has no key.
function Missions.label(def, field, n)
    if type(def) ~= 'table' or type(field) ~= 'string' then return '' end
    local fallback
    local key
    if field == 'location' then
        local loc = type(def.locations) == 'table' and def.locations[tonumber(n) or 0] or nil
        fallback = type(loc) == 'table' and loc.label or nil
        key = ('mission.%s.location.%s'):format(tostring(def.id), tostring(n))
    else
        fallback = def[field]
        key = ('mission.%s.%s'):format(tostring(def.id), field)
    end
    if CP.Locale and CP.Locale.label then return CP.Locale.label(key, fallback or '') end
    return tostring(fallback or '')
end

function Missions.serializeForClient(def)
    return CP.U.serialize(def)
end

-- ============================================================================
--                                   REGISTRY
-- ============================================================================

local function SortedDefs(filter)
    local out = {}
    for _, def in pairs(defs) do
        if not filter or filter(def) then out[#out + 1] = def end
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

local function Broadcast()
    local list = {}
    for _, def in ipairs(SortedDefs()) do list[#list + 1] = Missions.serializeForClient(def) end
    clientList = list
    -- The full list is tens of kB (every location of every mission): send it as a latent event so it
    -- is streamed instead of flooding every client's reliable channel at once.
    if TriggerLatentClientEvent then
        TriggerLatentClientEvent(CP.e('client:missions'), -1, LATENT_BPS, clientList)
    else
        TriggerClientEvent(CP.e('client:missions'), -1, clientList)
    end
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
    return SortedDefs()
end

function Missions.byType(missionType)
    return SortedDefs(function(def) return def.type == missionType and not def.isBoss end)
end

-- Is location #index of a mission on? Config.DisabledLocations[id] lists the ones turned off, by label or number
-- (Admin UI → Missions switches them); map replaces that table (CP.Settings asks about config.lua's own).
function Missions.isLocationEnabled(id, index, map)
    if map == nil then map = Config.DisabledLocations end
    local off = type(map) == 'table' and map[id] or nil
    if type(off) ~= 'table' then return true end
    local def = Missions.get(id)
    local loc = def and type(def.locations) == 'table' and def.locations[index] or nil
    local label = type(loc) == 'table' and loc.label or nil
    for _, v in ipairs(off) do
        if v == index or (label ~= nil and v == label) then return false end
    end
    return true
end

-- The numbers of the locations of a definition that are on.
function Missions.enabledLocations(def)
    local out = {}
    if type(def) ~= 'table' or type(def.locations) ~= 'table' then return out end
    for i = 1, #def.locations do
        if Missions.isLocationEnabled(def.id, i) then out[#out + 1] = i end
    end
    return out
end

-- Published, not turned off (Config.DisabledMissions) and with at least one location on. A mission turned off
-- while a run of it goes on only stops new draws: the run finishes.
function Missions.isEnabled(id)
    local def = Missions.get(id)
    if not def then return false end
    if (def.status or 'published') ~= 'published' then return false end
    if CP.U.contains(Config.DisabledMissions or {}, id) then return false end
    if type(def.locations) == 'table' and #def.locations > 0 and #Missions.enabledLocations(def) == 0 then
        return false
    end
    return true
end

local function MetaFromDef(def, defaults)
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
    local meta = MetaFromDef(def)
    -- register is the Mission Builder's publish / restore path: always a custom mission, so the builder's
    -- allowed lists apply (a definition claiming source = 'builtin' cannot skip them; built-ins only come
    -- from missions/builtin through loadAll).
    meta.source = 'custom'
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
    Broadcast()
    return d
end

function Missions.unregister(id)
    local def = Missions.get(id)
    if not def then return false end
    if def.source == 'builtin' then
        CP.warn(TAG, 'built-in mission %s cannot be unregistered; turn it off in Admin UI → Missions', id)
        return false
    end
    defs[id] = nil
    CP.log(TAG, 'unregistered %s', id)
    Broadcast()
    return true
end

-- A custom entry from CP.Builder.loadPublished(): a definition (with loader fields), { def, meta },
-- or only meta ({ id, filePath, version, ... }) whose file is then read here.
local function CustomEntry(entry)
    if type(entry) ~= 'table' then return nil, nil, 'entry is not a table' end
    local raw, meta
    if type(entry.def) == 'table' then
        raw = entry.def
        meta = MetaFromDef(entry.meta or entry, MetaFromDef(raw))
    else
        raw = entry
        meta = MetaFromDef(entry)
    end
    meta.source = 'custom'
    local content
    if meta.filePath then content = LoadResourceFile(CP.resource, meta.filePath) end
    if raw.objectives == nil and raw.locations == nil and meta.filePath then
        if not content or content == '' then
            return nil, meta, ('file %s was not found'):format(tostring(meta.filePath))
        end
        local fileDef, err = RunMissionFile(content, meta.filePath)
        if not fileDef then return nil, meta, err end
        raw = fileDef
    end
    if not meta.defHash then
        meta.defHash = (content and content ~= '') and CP.U.hashHex(content) or StableHash(raw)
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
    -- the settings changed in game (MissionTweaks, Config.Blocks ...) are over Config once the database is ready
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
    local summary = { loaded = 0, builtin = 0, custom = 0, failed = {}, warnings = 0 }
    local newDefs = {}

    local function failed(id, file, err)
        summary.failed[#summary.failed + 1] = { id = id, file = file, error = err }
        CP.warn(TAG, 'mission %s (%s) was not loaded: %s', tostring(id), tostring(file or '-'), tostring(err))
    end

    local okAll, errAll = pcall(function()
        -- built-in missions
        local ids, indexErr = ReadIndex()
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
                local raw, err = RunMissionFile(content, path)
                if not raw then
                    failed(id, path, err)
                elseif raw.id ~= id then
                    failed(id, path, ('its id "%s" does not match the file name'):format(tostring(raw.id)))
                else
                    local meta = {
                        source = 'builtin',
                        filePath = path,
                        defHash = CP.U.hashHex(content),
                        status = 'published',
                    }
                    local def, nerr, warnings = Missions.normalize(raw, meta)
                    summary.warnings = summary.warnings + (warnings or 0)
                    if not def then
                        failed(id, path, nerr)
                    else
                        newDefs[id] = Tweaked(id, raw, def, meta)
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
                    local raw, meta, err = CustomEntry(entry)
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
    print(('[crimson-police] missions loaded: %d built-in, %d custom, %d rejected'):format(summary.builtin,
        summary.custom, #summary.failed))
    Broadcast()
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

-- ============================================================================
--                                     NET
-- ============================================================================

CP.Net.callback('getMissionDefs', function(src)
    if not loadedOnce then return nil, 'err.not_ready' end
    return clientList
end, { rate = 2 })

local function PlainSummary(summary)
    local failedList = {}
    for i, f in ipairs(summary.failed or {}) do
        failedList[i] = { id = tostring(f.id), file = f.file and tostring(f.file) or nil, error = tostring(f.error) }
    end
    return {
        loaded = summary.loaded or 0,
        builtin = summary.builtin or 0,
        custom = summary.custom or 0,
        warnings = summary.warnings or 0,
        failed = failedList,
        error = summary.error,
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
        pcall(CP.Admin.audit, src == 0 and 'console' or src, role, 'audit', 'reloadMissions', nil, tostring(before),
            ('%d loaded, %d rejected'):format(summary.loaded or 0, #(summary.failed or {})), nil)
    end
    return true, PlainSummary(summary)
end, { rate = 2 })

-- ============================================================================
--                                    START
-- ============================================================================

CreateThread(function()
    Wait(0)   -- every module and block file of the resource has been loaded by now
    Missions.loadAll()
end)

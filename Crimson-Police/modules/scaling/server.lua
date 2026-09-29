-- CP.Scaling: tiers by participant count and scaled mission counts.

CP.Scaling = CP.Scaling or {}
local Scaling = CP.Scaling

local TAG = 'scaling'

local function Rows()
    return Config.Scaling or {}
end

local function IndexOf(row)
    local list = Rows()
    for i = 1, #list do
        if list[i] == row or (type(row) == 'table' and list[i].tier == row.tier) then return i end
    end
    return nil
end

function Scaling.tierFor(n)
    local list = Rows()
    n = math.floor(tonumber(n) or 1)
    if n < 1 then n = 1 end
    for i = 1, #list do
        if (tonumber(list[i].maxParticipants) or 0) >= n then return list[i] end
    end
    return list[#list]
end

function Scaling.tierByName(name)
    if type(name) == 'table' then
        if IndexOf(name) then return name end
        name = name.tier
    end
    if type(name) ~= 'string' then return nil end
    local list = Rows()
    for i = 1, #list do
        if list[i].tier == name then return list[i] end
    end
    return nil
end

-- Accepts a row or a tier name; unknown values resolve to nil.
local function Resolve(t)
    if t == nil then return nil end
    return Scaling.tierByName(t)
end

function Scaling.lower(a, b)
    local ra, rb = Resolve(a), Resolve(b)
    if not ra then return rb end
    if not rb then return ra end
    local ia, ib = IndexOf(ra) or 1, IndexOf(rb) or 1
    if ib < ia then return rb end
    return ra
end

function Scaling.label(name)
    if type(name) == 'table' then name = name.tier end
    if type(name) ~= 'string' or name == '' then return '' end
    return CP.L('tier.' .. name)
end

function Scaling.scaleCount(base, tier)
    local b = tonumber(base)
    if not b then return base end
    local row = Resolve(tier) or Rows()[1]
    local factor = row and tonumber(row.count) or 1.0
    return CP.U.round(b * factor)
end

local function IsNumberList(v)
    if type(v) ~= 'table' or #v == 0 then return false end
    for k, x in pairs(v) do
        if type(k) ~= 'number' or type(x) ~= 'number' then return false end
    end
    return true
end

-- Split a scaling entry into (path relative to the objectives list, max|nil). nil when unusable.
local function EntryPath(entry)
    local path, max
    if type(entry) == 'string' then
        path = entry
    elseif type(entry) == 'table' and type(entry.path) == 'string' then
        path, max = entry.path, tonumber(entry.max)
    else
        return nil
    end
    path = CP.U.trim(path)
    if path:sub(1, 11) == 'objectives.' then path = path:sub(12) end
    if not path:match('^%d+') then
        return nil
    end -- must start at an objective index
    return path, max
end

-- Scale a number or a list of numbers; returns (scaled, true) or (value, false) when not scalable.
local function ScaleValue(value, row, max)
    local function one(x)
        local s = Scaling.scaleCount(x, row)
        if max and s > max then s = max end
        if s < 0 then s = 0 end
        return s
    end
    if type(value) == 'number' then return one(value), true end
    if IsNumberList(value) then
        local out = {}
        for i = 1, #value do out[i] = one(value[i]) end
        return out, true
    end
    return value, false
end

function Scaling.apply(mission, tier)
    local objectives = CP.U.deepcopy((mission and mission.objectives) or {})
    local row = Resolve(tier) or Rows()[1]
    if not mission or type(mission.scaling) ~= 'table' or not row then return objectives end
    for _, entry in ipairs(mission.scaling) do
        local path, max = EntryPath(entry)
        if not path then
            CP.warn(TAG, 'mission %s: scaling entry %s is not a valid path; ignored', tostring(mission.id),
                tostring(type(entry) == 'table' and entry.path or entry))
        else
            local current = CP.U.getPath(objectives, path)
            local scaled, ok = ScaleValue(current, row, max)
            if ok then
                CP.U.setPath(objectives, path, scaled)
            else
                CP.warn(TAG, 'mission %s: scaling path objectives.%s is not a number or a list of numbers; ignored',
                    tostring(mission.id), path)
            end
        end
    end
    return objectives
end

function Scaling.combat(baseAccuracy, baseArmour, tier, run)
    local row = Resolve(tier) or Rows()[1] or {}
    local accuracy = (tonumber(baseAccuracy) or 0) + (tonumber(row.accuracy) or 0)
    local armour = (tonumber(baseArmour) or 0) + (tonumber(row.armour) or 0)
    if type(run) == 'table' and run.modifier == 'armored_hostiles' then
        local missionType = run.missionType or (run.mission and run.mission.type)
        if missionType == 'tactical' then
            armour = armour + (tonumber(Config.Events and Config.Events.armoredArmour) or 0)
        end
    end
    accuracy = CP.U.clamp(math.floor(accuracy + 0.5), 0, 100)
    if armour < 0 then armour = 0 end
    return accuracy, math.floor(armour + 0.5)
end

-- Internal helpers for modules/missions (same slice): validate scaling entries with the rules apply() uses.
Scaling._entryPath = EntryPath
Scaling._isScalable = function(value) return type(value) == 'number' or IsNumberList(value) end

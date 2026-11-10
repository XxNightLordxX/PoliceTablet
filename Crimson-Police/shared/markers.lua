-- CP.MarkerAliases (shared): the old names of Map markers' settings, from before the mission blips were folded into

-- CP.MarkerAliases (shared): the old names of Map markers' settings, from before the mission blips were folded into
-- Config.Markers. A config.lua that still has them (Config.MissionBlips, Config.Markers.serviceVehicles,
-- Config.AdminUi.missionBlipsScreen) is read into the new names once, as it loads, on the server and every client
-- alike; a setting saved in game under an old name is read the same way at start (modules/settings). A new name that
-- is set already wins. The server prints one console line with the new names (CP.MarkerAliases.report).

CP.MarkerAliases = CP.MarkerAliases or {}
local A = CP.MarkerAliases

-- The prisoner van and the tow truck: Config.Markers.serviceVehicles became their parts' on.
local SERVICE = { 'prisonerVan', 'towTruck' }
local IS_SERVICE = { prisonerVan = true, towTruck = true }
local SERVICE_LOOK = {
    prisonerVan = { sprite = 285, colour = 3, scale = 0.8, label = '', shortRange = false },
    towTruck = { sprite = 68, colour = 3, scale = 0.8, label = '', shortRange = false },
}
local LOOK = { sprite = true, colour = true, scale = true }

A.used = A.used or {}   -- { 'old name -> new name' } read this start, in order (the console line)

local function Copy(t)
    local out = {}
    for k, v in pairs(t) do out[k] = type(v) == 'table' and Copy(v) or v end
    return out
end

local function Used(old, new)
    local line = old .. ' -> ' .. new
    for _, l in ipairs(A.used) do if l == line then return end end
    A.used[#A.used + 1] = line
end

-- The new setting paths an old saved path stands for: nil = not an old name, {} = an old name with no new one (the
-- prisoner van's and tow truck's old on, which only meant "while serviceVehicles is off").
function A.paths(path)
    if type(path) ~= 'string' then return nil end
    if path == 'Markers.serviceVehicles' then
        return { 'Markers.parts.prisonerVan.on', 'Markers.parts.towTruck.on' }
    end
    if path == 'AdminUi.missionBlipsScreen' then return { 'AdminUi.markersScreen' } end
    if path == 'MissionBlips.enabled' then return { 'Markers.extraParts' } end
    if path == 'MissionBlips.refreshEvery' then return { 'Markers.refreshEvery' } end
    if path == 'MissionBlips.rules' then return { 'Markers.rules' } end
    local part, field = path:match('^MissionBlips%.parts%.(%a+)%.(%a+)$')
    if part then
        if IS_SERVICE[part] and field == 'on' then return {} end
        return { ('Markers.parts.%s.%s'):format(part, field) }
    end
    local kind, f = path:match('^Markers%.kinds%.(%a+)%.(%a+)$')
    if kind and IS_SERVICE[kind] and LOOK[f] then return { ('Markers.parts.%s.%s'):format(kind, f) } end
    return nil
end

-- Reads cfg's old names into the new ones (a new name already set stays) and takes the old ones out. Returns the
-- number of old names read.
function A.mapConfig(cfg)
    if type(cfg) ~= 'table' or type(cfg.Markers) ~= 'table' then return 0 end
    local before = #A.used
    local m = cfg.Markers
    if type(m.parts) ~= 'table' then m.parts = {} end
    local old = cfg.MissionBlips
    if type(old) == 'table' then
        if m.extraParts == nil and old.enabled ~= nil then
            m.extraParts = old.enabled == true
            Used('Config.MissionBlips.enabled', 'Config.Markers.extraParts')
        end
        if m.refreshEvery == nil and old.refreshEvery ~= nil then
            m.refreshEvery = old.refreshEvery
            Used('Config.MissionBlips.refreshEvery', 'Config.Markers.refreshEvery')
        end
        if m.rules == nil and type(old.rules) == 'table' then
            m.rules = Copy(old.rules)
            Used('Config.MissionBlips.rules', 'Config.Markers.rules')
        end
        for id, p in pairs(type(old.parts) == 'table' and old.parts or {}) do
            if type(id) == 'string' and type(p) == 'table' and type(m.parts[id]) ~= 'table' then
                local copy = Copy(p)
                if IS_SERVICE[id] then copy.on = nil end
                m.parts[id] = copy
                Used('Config.MissionBlips.parts', 'Config.Markers.parts')
            end
        end
        cfg.MissionBlips = nil
    end
    -- the prisoner van and tow truck: their part, its look from the old kinds entry, its on from serviceVehicles
    local kinds = type(m.kinds) == 'table' and m.kinds or {}
    for _, id in ipairs(SERVICE) do
        local p = m.parts[id]
        if type(p) ~= 'table' then
            p = Copy(SERVICE_LOOK[id])
            local k = kinds[id]
            if type(k) == 'table' then
                for f in pairs(LOOK) do if k[f] ~= nil then p[f] = k[f] end end
                Used('Config.Markers.kinds.' .. id, 'Config.Markers.parts.' .. id)
            end
            m.parts[id] = p
        end
        if p.on == nil then
            p.on = m.serviceVehicles ~= false
            if m.serviceVehicles ~= nil then
                Used('Config.Markers.serviceVehicles', 'Config.Markers.parts.prisonerVan.on and parts.towTruck.on')
            end
        end
    end
    m.serviceVehicles = nil
    local ui = cfg.AdminUi
    if type(ui) == 'table' and ui.missionBlipsScreen ~= nil then
        if ui.markersScreen == nil then ui.markersScreen = ui.missionBlipsScreen end
        ui.missionBlipsScreen = nil
        Used('Config.AdminUi.missionBlipsScreen', 'Config.AdminUi.markersScreen')
    end
    return #A.used - before
end

-- A saved setting read under its new name (modules/settings at start).
function A.savedUsed(old, new) Used(old .. ' (saved in game)', new) end

-- The one console line (server, after the saved settings were read): which old names were read as which new ones.
-- Returns the line, or nil when every name is new.
function A.report()
    if #A.used == 0 or A.reported then return nil end
    A.reported = true
    local line = CP.L and CP.L('markers.console_aliases', { list = table.concat(A.used, '; ') })
        or table.concat(A.used, '; ')
    if CP.warn then CP.warn('markers', '%s', line) end
    return line
end

A.mapConfig(Config)

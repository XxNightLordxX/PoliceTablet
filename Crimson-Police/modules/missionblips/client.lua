-- CP.MissionBlips (client): the extra mission blips the server sends (Config.MissionBlips, shipped off), on the
-- minimap and the big map. Blips change only when a list comes in: one is added, moved, restyled or removed then.

-- CP.MissionBlips (client): the extra mission blips the server sends (Config.MissionBlips, shipped off), on the
-- minimap and the big map. Blips change only when a list comes in: one is added, moved, restyled or removed then.
-- A car, person or partner follows its entity once that streams in (AddBlipForEntity); until then it sits where the
-- server saw it. The follow check runs only while such a blip is on the map (CP.Perf.ms, 1 s). Everything goes
-- at the run's end, a list for another run, logout and resource stop.

CP.MissionBlips = CP.MissionBlips or {}
local MB = CP.MissionBlips
local TAG = 'missionblips'

local FOLLOW_MS = 1000          -- how often a blip waiting for its entity checks whether it streamed in
local DEFAULT_LOOK = { sprite = 1, colour = 0, scale = 0.7 }

local blips = {}                -- [key] = { id, part, netId, src, x, y, z, entity (followed entity or nil), look }
local runId = nil               -- the run the blips are of

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function Cfg() return type(Config.MissionBlips) == 'table' and Config.MissionBlips or {} end

local function PartCfg(part)
    local parts = type(Cfg().parts) == 'table' and Cfg().parts or {}
    return type(parts[part]) == 'table' and parts[part] or {}
end

local function Int(v, default)
    local n = tonumber(v)
    n = n and math.tointeger(math.floor(n)) or nil
    return n or default
end

-- The part's look, read now (Admin UI -> Settings changes it live): sprite, colour, scale, label, shortRange.
local function Look(part)
    local p = PartCfg(part)
    local label = type(p.label) == 'string' and p.label ~= '' and p.label:sub(1, 40)
        or CP.L('missionblips.part.' .. part)
    return {
        sprite = Int(p.sprite, DEFAULT_LOOK.sprite),
        colour = Int(p.colour, DEFAULT_LOOK.colour),
        scale = (tonumber(p.scale) or DEFAULT_LOOK.scale) + 0.0,
        label = label,
        shortRange = p.shortRange == true,
    }
end

local function LookSig(l)
    return ('%d|%d|%.2f|%s|%s'):format(l.sprite, l.colour, l.scale, l.label, tostring(l.shortRange))
end

local function Exists(id) return id ~= nil and id ~= 0 and DoesBlipExist(id) end

local function Remove(b)
    if b and Exists(b.id) then RemoveBlip(b.id) end
end

local function Style(b)
    local l = Look(b.part)
    SetBlipSprite(b.id, l.sprite)
    SetBlipColour(b.id, l.colour)
    SetBlipScale(b.id, l.scale)
    SetBlipAsShortRange(b.id, l.shortRange)
    SetBlipDisplay(b.id, 2) -- the minimap and the big map
    BeginTextCommandSetBlipName('STRING')
    AddTextComponentSubstringPlayerName(l.label)
    EndTextCommandSetBlipName(b.id)
    b.look = LookSig(l)
end

-- The entity a blip should follow, when it is streamed in on this game: a run entity (netId) or a partner (src).
local function EntityOf(b)
    if b.netId then
        if not NetworkDoesNetworkIdExist(b.netId) then return nil end
        local ent = NetworkGetEntityFromNetworkId(b.netId)
        if ent and ent ~= 0 and DoesEntityExist(ent) then return ent end
        return nil
    end
    if b.src then
        local player = GetPlayerFromServerId(b.src)
        if not player or player == -1 then return nil end
        local ped = GetPlayerPed(player)
        if ped and ped ~= 0 and DoesEntityExist(ped) then return ped end
    end
    return nil
end

-- (Re)make b's blip: on its entity when that is streamed in, else at the server's position.
local function Place(b)
    Remove(b)
    local ent = (b.netId or b.src) and EntityOf(b) or nil
    if ent then
        b.id = AddBlipForEntity(ent)
    else
        b.id = AddBlipForCoord(b.x, b.y, b.z)
    end
    b.entity = ent
    Style(b)
end

-- True while a blip belongs to a car, person or partner (it may stream in or out).
local function Tracking()
    for _, b in pairs(blips) do if b.netId or b.src then return true end end
    return false
end

-- One follow pass: a blip whose entity streamed in moves onto it; one whose entity went goes back to the server's
-- position. Returns true (the loop stops) when no blip belongs to an entity.
local function Follow()
    for _, b in pairs(blips) do
        if b.entity and not DoesEntityExist(b.entity) then
            b.entity = nil
            Place(b)
        elseif (b.netId or b.src) and not b.entity and EntityOf(b) then
            Place(b)
        end
    end
    return not Tracking()
end

local ArmFollow = CP.Perf.armed(TAG, function() return CP.Perf.ms(FOLLOW_MS) end, Follow)

-- ============================================================================
--                                   THE LIST
-- ============================================================================

local function Clean(it)
    if type(it) ~= 'table' or type(it.k) ~= 'string' or type(it.p) ~= 'string' then return nil end
    local x, y, z = tonumber(it.x), tonumber(it.y), tonumber(it.z) or 0.0
    if not x or not y then return nil end
    return {
        key = it.k:sub(1, 64),
        part = it.p:sub(1, 32),
        netId = Int(it.n, nil),
        src = Int(it.s, nil),
        x = x + 0.0,
        y = y + 0.0,
        z = z + 0.0,
    }
end

-- Take every mission blip off the map.
function MB.clear()
    for _, b in pairs(blips) do Remove(b) end
    blips = {}
    runId = nil
end

-- Show the list the server sent for run id: new blips are added, gone ones removed, moved ones moved, restyled
-- ones restyled; nothing else is touched.
function MB.apply(id, list)
    if id ~= runId then MB.clear() end
    runId = id
    local want, order = {}, {}
    for _, raw in ipairs(type(list) == 'table' and list or {}) do
        local it = Clean(raw)
        if it and not want[it.key] then
            want[it.key] = it
            order[#order + 1] = it.key
        end
    end
    for key, b in pairs(blips) do
        local it = want[key]
        if not it or it.part ~= b.part or it.netId ~= b.netId or it.src ~= b.src then
            Remove(b)
            blips[key] = nil
        end
    end
    for _, key in ipairs(order) do
        local it = want[key]
        local b = blips[key]
        if not b then
            blips[key] = it
            Place(it)
        else
            if not Exists(b.id) then
                b.x, b.y, b.z = it.x, it.y, it.z
                Place(b)
            elseif not b.entity and (b.x ~= it.x or b.y ~= it.y or b.z ~= it.z) then
                SetBlipCoords(b.id, it.x, it.y, it.z)
            end
            b.x, b.y, b.z = it.x, it.y, it.z
            if Exists(b.id) and b.look ~= LookSig(Look(b.part)) then Style(b) end
        end
    end
    if next(blips) == nil then runId = nil end
    if Tracking() then ArmFollow() end
end

-- How many mission blips are on the map (tests and the debug view).
function MB.count()
    local n = 0
    for _ in pairs(blips) do n = n + 1 end
    return n
end

-- ============================================================================
--                                    EVENTS
-- ============================================================================

RegisterNetEvent(CP.e('client:missionBlips'), function(data)
    if type(data) ~= 'table' or type(data.runId) ~= 'string' then return end
    local items = type(data.items) == 'table' and data.items or {}
    if #items == 0 then
        if runId == nil or runId == data.runId then MB.clear() end
        return
    end
    local run = CP.Runs and CP.Runs.current and CP.Runs.current()
    if not run or run.id ~= data.runId then return end
    MB.apply(data.runId, items)
end)

if CP.Qbx and CP.Qbx.onUnload then CP.Qbx.onUnload(function() MB.clear() end) end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    MB.clear()
end)

-- CP.Missions (client): the mission definitions sent by the server.

CP.Missions = CP.Missions or {}
local Missions = CP.Missions

local TAG = 'missions'
local defs = {}
local receivedPush = false   -- a server push is always newer than a pending callback reply

-- A table whose only keys are x, y, z (and optionally w), all numbers, is a serialized vector.
local function IsVecTable(t)
    local n = 0
    for k, v in pairs(t) do
        if (k == 'x' or k == 'y' or k == 'z' or k == 'w') and type(v) == 'number' then
            n = n + 1
        else
            return false
        end
    end
    return n >= 3 and t.x ~= nil and t.y ~= nil and t.z ~= nil
end

local function Revive(v, depth)
    if type(v) ~= 'table' then return v end
    depth = depth or 0
    if depth > 32 then return v end
    if IsVecTable(v) then
        if v.w ~= nil then return vector4(v.x + 0.0, v.y + 0.0, v.z + 0.0, v.w + 0.0) end
        return vector3(v.x + 0.0, v.y + 0.0, v.z + 0.0)
    end
    for k, val in pairs(v) do
        if type(val) == 'table' then v[k] = Revive(val, depth + 1) end
    end
    return v
end

local function Store(list)
    if type(list) ~= 'table' then return false end
    local fresh = {}
    for _, def in ipairs(list) do
        if type(def) == 'table' and type(def.id) == 'string' then
            fresh[def.id] = Revive(def)
        end
    end
    defs = fresh
    CP.log(TAG, 'received %d mission definitions', CP.U.count(defs))
    return true
end

function Missions.get(id)
    if type(id) ~= 'string' then return nil end
    return defs[id]
end

RegisterNetEvent(CP.e('client:missions'), function(list)
    if Store(list) then receivedPush = true end
end)

-- Joining player: ask once; retry with a growing delay while the server has not loaded yet.
CreateThread(function()
    Wait(1500)
    local delay = 3000
    for _ = 1, 12 do
        if receivedPush then return end
        local res = CP.Net.request('getMissionDefs')
        if receivedPush then return end
        if type(res) == 'table' and res.ok and type(res.data) == 'table' then
            Store(res.data)
            return
        end
        Wait(delay)
        if delay < 15000 then delay = delay + 3000 end
    end
    CP.warn(TAG, 'no mission definitions received from the server yet')
end)

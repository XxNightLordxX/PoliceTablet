-- CP.Ambulance (server): the only server code that talks to sc-ambulance.

CP.Ambulance = CP.Ambulance or {}
local A = CP.Ambulance
local TAG = 'sc_ambulance'
local RESOURCE = 'sc-ambulance'
local EMS_JOB = 'ambulance'          -- the only job name sc-ambulance counts as a doctor

local notStartedLogged = false
local errorLoggedAt = {}

local function LogError(key, fmt, ...)
    local now = os.time()
    if errorLoggedAt[key] and now - errorLoggedAt[key] < 60 then return end
    errorLoggedAt[key] = now
    CP.err(TAG, fmt, ...)
end

local function Started()
    if GetResourceState(RESOURCE) == 'started' then
        notStartedLogged = false
        return true
    end
    if not notStartedLogged then
        notStartedLogged = true
        CP.err(TAG, 'sc-ambulance is not started: the EMS count is 0 and a pick-up cannot revive anyone')
    end
    return false
end

-- On-duty 'ambulance' players right now, or nil when the player list is not available.
local function LiveEmsCount()
    if not (CP.Qbx and CP.Qbx.getOnlinePlayers and CP.Qbx.getInfo) then return nil end
    local list = CP.Qbx.getOnlinePlayers()
    if type(list) ~= 'table' or #list == 0 then return nil end
    local n = 0
    for i = 1, #list do
        local info = CP.Qbx.getInfo(list[i])
        if info and info.job.name == EMS_JOB and info.job.onduty then n = n + 1 end
    end
    return n
end

function A.doctorCount()
    if not Started() then return 0 end
    local ok, count = pcall(function() return exports[RESOURCE]:GetDoctorCount() end)
    if not ok then
        LogError('GetDoctorCount', 'exports[\'sc-ambulance\']:GetDoctorCount failed: %s', tostring(count))
        return 0
    end
    local n = math.floor(tonumber(count) or 0)
    if n < 0 then n = 0 end
    if n > 0 then
        local live = LiveEmsCount()
        if live ~= nil and live < n then
            CP.log(TAG, 'GetDoctorCount says %d but %d ambulance players are on duty; using %d', n, live, live)
            n = live
        end
    end
    return n
end

-- CP.Alerts.inArena (guarded: an error counts as in the arena, so nobody is revived by mistake).
local function InArena(src)
    if not (CP.Alerts and CP.Alerts.inArena) then return false end
    local ok, res = pcall(CP.Alerts.inArena, src)
    if not ok then
        LogError('inArena', 'CP.Alerts.inArena failed: %s', tostring(res))
        return true
    end
    return res == true
end

function A.revive(src)
    local n = tonumber(src)
    n = n and math.tointeger(n)
    if not n or n <= 0 then
        CP.err(TAG, 'revive refused an invalid server id (%s)', tostring(src))
        return false
    end
    if GetPlayerName(n) == nil then
        CP.log(TAG, 'revive: player %d is not connected', n)
        return false
    end
    if InArena(n) then
        CP.warn(TAG, 'revive refused for player %d: they are in Crimson-Arena, which handles their revive', n)
        return false
    end
    if not Started() then return false end
    TriggerClientEvent('hospital:client:Revive', n)
    CP.log(TAG, 'revive sent to %d', n)
    return true
end

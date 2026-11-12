-- CP.Teams (server): the helpers both parts of the teams module use (units.lua and operations.lua).

-- modules/teams/common.lua · CP.Teams (server): one team system.
--
-- The teams module holds every way officers play together: a unit (units.lua, 2+ officers from any department, built
-- by invites) and a Cross-Department Mission (operations.lua, a server-wide join list that becomes one run). Both
-- share the unit engine's ready check (CP.Units.teamReadyCheck), one leave action (server:teamLeave) and the helpers
-- below, so a fix to one of them fixes both parts. Loaded before units.lua and operations.lua (the manifest glob is
-- byte-sorted).
--
-- Public API (server)
--   CP.Teams.officer(src) -> officer|nil, errKey     CP.Access.getOfficer in pcall (err.internal on a failure)
--   CP.Teams.maybeOfficer(src) -> boolean            false only for a player in no turned-on department (no lookup)
--   CP.Teams.onRun(src) -> boolean                   an active participant of a run, or on a mission
--   CP.Teams.inArena(src) -> boolean                 inside Crimson-Arena (CP.Alerts.inArena)
--   CP.Teams.onlinePlayers() -> { src... }           CP.Qbx.getOnlinePlayers, else GetPlayers()

CP.Teams = CP.Teams or {}
local Teams = CP.Teams
local TAG = 'teams'

---@param src number
---@return table|nil officer
---@return string|nil errKey
function Teams.officer(src)
    if not (CP.Access and CP.Access.getOfficer) then return nil, 'err.not_police' end
    local ok, officer, errKey = CP.Call(TAG, 'Access', 'getOfficer', src)
    if not ok then return nil, 'err.internal' end
    return officer, errKey
end

-- The pre-filter for loops over every online player: false only for a player whose job (kept by qbx_core's events,
-- no Qbox lookup) is in no turned-on department. true = maybe: Teams.officer does the full check.
---@param src number
---@return boolean
function Teams.maybeOfficer(src)
    if not (CP.Access and CP.Access.maybeOfficer) then return true end
    local ok, maybe = CP.Call(TAG, 'Access', 'maybeOfficer', src)
    return not ok or maybe ~= false
end

---@param src number
---@return boolean
function Teams.onRun(src)
    local ok, run = CP.Call(TAG, 'Runs', 'getBySrc', src)
    if ok and type(run) == 'table' then return true end
    local ok2, on = CP.Call(TAG, 'Runs', 'isOnMission', src)
    return ok2 and on == true
end

---@param src number
---@return boolean
function Teams.inArena(src)
    local ok, v = CP.Call(TAG, 'Alerts', 'inArena', src)
    return ok and v == true
end

---@return number[]
function Teams.onlinePlayers()
    local ok, list = CP.Call(TAG, 'Qbx', 'getOnlinePlayers')
    if ok and type(list) == 'table' then return list end
    local out = {}
    if GetPlayers then
        for _, s in ipairs(GetPlayers()) do
            local n = CP.U.toSrc(s)
            if n then out[#out + 1] = n end
        end
    end
    return out
end

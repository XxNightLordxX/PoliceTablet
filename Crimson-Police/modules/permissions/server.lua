-- modules/permissions/server.lua · CP.Permissions: the one place that decides whether a role may do
-- an action. Every sup:* / admin:* handler (and every builder/test action) asks can() first.
--
-- Rules (SPEC "Supervisor & admin actions", Config.Permissions):
--   * Admins (ace Config.AdminAce, or the server console) may do every action.
--   * Supervisors may do a supervisor action only when Config.Permissions.supervisor[action] == true
--     (read at call time) and they currently qualify as a supervisor (CP.Access.isSupervisor).
--   * Admin-only, whatever the config says: setMissionPayout, clearPayout, manualAward,
--     handleFailedDispute, voidAnyRun, seasons, bountyOverride, suspend, reloadMissions, testRun, openAdmin.
--   * viewMissionList: supervisors and admins (no config switch).
--   * Nobody may approve, void or answer a dispute about a run they took part in: pass ctx.runUuid with
--     reviewFlagged, handleDisputes, handleFailedDispute or voidAnyRun and the own-run check applies to
--     admins too.
--
-- Public API (docs/ARCHITECTURE.md §5.3)
--   CP.Permissions.can(src, action, ctx) -> boolean, errKey
--       ctx (optional table):
--         runUuid      -> own-run check for the review actions above (err.own_run, err.invalid_run)
--         department / departments -> a supervisor (not an admin) must belong to that department, or to
--                         one of the list (err.other_department). Use it for "runs involving their department".
--       errKey otherwise err.no_permission.
--   CP.Permissions.actionsFor(src) -> { actionName, ... }   sorted; admins: every admin and supervisor
--       action; supervisors: the switched-on supervisor actions + viewMissionList; others: {}.
--   CP.Permissions.tookPart(citizenid, runUuid) -> boolean  any cp_mission_runs row of that run for that citizenid
--   CP.Permissions.canReviewRun(src, runUuid) -> boolean, errKey   false with err.own_run when the reviewer
--       took part (the console and players without a character can review).
-- can, actionsFor, tookPart and canReviewRun may yield (database): call them from a handler or thread.

CP.Permissions = CP.Permissions or {}
local P = CP.Permissions
local TAG = 'permissions'

local ADMIN_ONLY_LIST = {
    'setMissionPayout', 'clearPayout', 'manualAward', 'handleFailedDispute', 'voidAnyRun', 'seasons',
    'bountyOverride', 'suspend', 'reloadMissions', 'testRun', 'openAdmin',
}
local ADMIN_ONLY = {}
for _, a in ipairs(ADMIN_ONLY_LIST) do ADMIN_ONLY[a] = true end

-- Actions supervisors always have (no Config.Permissions switch).
local SUPERVISOR_ALWAYS = { viewMissionList = true }

-- Review actions: never on a run the reviewer took part in.
local REVIEW_ACTIONS = { reviewFlagged = true, handleDisputes = true, handleFailedDispute = true, voidAnyRun = true }

local function supervisorConfig()
    local perms = Config.Permissions
    local sup = type(perms) == 'table' and perms.supervisor or nil
    if type(sup) ~= 'table' then return {} end
    return sup
end

local function validRunUuid(runUuid)
    return type(runUuid) == 'string' and #runUuid > 0 and #runUuid <= 36 and runUuid:match('^[%w%-]+$') ~= nil
end

local function inDepartments(dept, ctx)
    if type(ctx.department) == 'string' and ctx.department == dept then return true end
    local list = ctx.departments
    if type(list) == 'table' then
        if list[dept] == true then return true end
        for i = 1, #list do
            if list[i] == dept then return true end
        end
    end
    return false
end

function P.tookPart(citizenid, runUuid)
    if type(citizenid) ~= 'string' or citizenid == '' or not validRunUuid(runUuid) then return false end
    CP.Migrations.ready()
    local ok, res = pcall(MySQL.scalar.await,
        'SELECT 1 AS took_part FROM cp_mission_runs WHERE run_uuid = ? AND citizenid = ? LIMIT 1',
        { runUuid, citizenid })
    if not ok then
        CP.err(TAG, 'tookPart lookup failed: %s', tostring(res))
        -- Fail closed: a reviewer who cannot be cleared is treated as a participant.
        return true
    end
    return res ~= nil
end

function P.canReviewRun(src, runUuid)
    if not validRunUuid(runUuid) then return false, 'err.invalid_run' end
    local n = tonumber(src)
    if n == 0 then return true end
    if not n or n < 0 then return false, 'err.no_permission' end
    local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(n)
    if not info then return true end
    if P.tookPart(info.citizenid, runUuid) then return false, 'err.own_run' end
    return true
end

function P.can(src, action, ctx)
    if type(action) ~= 'string' or action == '' then return false, 'err.no_permission' end
    local n = tonumber(src)
    if not n or n < 0 or not CP.Access then return false, 'err.no_permission' end
    if type(ctx) ~= 'table' then ctx = nil end

    if not CP.Access.isAdmin(n) then
        if ADMIN_ONLY[action] then return false, 'err.no_permission' end
        if not SUPERVISOR_ALWAYS[action] and supervisorConfig()[action] ~= true then
            return false, 'err.no_permission'
        end
        if not CP.Access.isSupervisor(n) then return false, 'err.no_permission' end
        if ctx and (ctx.department ~= nil or ctx.departments ~= nil) then
            local officer = CP.Access.getOfficer(n)
            if not officer then return false, 'err.no_permission' end
            if not inDepartments(officer.department, ctx) then return false, 'err.other_department' end
        end
    end

    if ctx and ctx.runUuid ~= nil and REVIEW_ACTIONS[action] then
        local ok, errKey = P.canReviewRun(n, ctx.runUuid)
        if not ok then return false, errKey end
    end
    CP.log(TAG, '%d may %s', n, action)
    return true
end

function P.actionsFor(src)
    local out = {}
    local n = tonumber(src)
    if not n or n < 0 or not CP.Access then return out end
    local sup = supervisorConfig()
    if CP.Access.isAdmin(n) then
        local set = { viewMissionList = true }
        for _, a in ipairs(ADMIN_ONLY_LIST) do set[a] = true end
        for a in pairs(sup) do
            if type(a) == 'string' then set[a] = true end
        end
        for a in pairs(set) do out[#out + 1] = a end
    elseif CP.Access.isSupervisor(n) then
        for a, v in pairs(sup) do
            if type(a) == 'string' and v == true and not ADMIN_ONLY[a] then out[#out + 1] = a end
        end
        for a in pairs(SUPERVISOR_ALWAYS) do out[#out + 1] = a end
    end
    table.sort(out)
    return out
end

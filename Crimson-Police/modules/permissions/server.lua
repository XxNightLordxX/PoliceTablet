-- CP.Permissions: the one place that decides whether a role may do an action. Every sup:* / admin:* handler (and every
-- builder/test action) asks can() first.

CP.Permissions = CP.Permissions or {}
local P = CP.Permissions
local TAG = 'permissions'

local ADMIN_ONLY_LIST = {
    'setMissionPayout',
    'clearPayout',
    'manualAward',
    'handleFailedDispute',
    'voidAnyRun',
    'seasons',
    'bountyOverride',
    'suspend',
    'reloadMissions',
    'testRun',
    'openAdmin',
    -- full admin control (docs/ARCHITECTURE.md §5.37): admins and the console only, whatever Config.Permissions says
    'officerRecords',     -- retire, look, profile cooldown, board exclusion, banned words, staff notices
    'pointsAdjust',       -- signed manual adjustments
    'bulkVoid',           -- void or restore many rows as one batch
    'restoreRun',         -- restore a voided run outside a dispute; void kinds; flag by hand
    'progression',        -- XP check and fix, badges, streaks, goals, first-run bonus
    'antiFarmOverride',   -- cooldown clears, extra runs, boss attempts, free-abandon reclassify
    'liveRuns',           -- end, recall, add time, end tests; units
    'editBuiltins',       -- built-in mission overrides in the Mission Builder
    'missionAdmin',       -- delete, bring back, change owner, import and export missions
    'boardsAdmin',        -- recounts, reposts, past windows, seasons planning and reopen
    'payments',           -- the payments ledger and its actions
    'rewardsAdmin',       -- item rewards: resolve, deliver, cancel, take back
    'deptFunds',          -- department account balances and add funds
    'departmentsAdmin',   -- add, turn off and delete departments; desks; logos
    'storageAdmin',       -- storage status, copy and switch, backups and restore
    'playerSupport',      -- check access, give the tablet item, release a stuck screen
    'recordMove',         -- move a re-created character's history
    'cleanup',            -- the nightly clean-up: status and run now
}
local ADMIN_ONLY = {}
for _, a in ipairs(ADMIN_ONLY_LIST) do ADMIN_ONLY[a] = true end

-- Actions supervisors always have (no Config.Permissions switch).
local SUPERVISOR_ALWAYS = { viewMissionList = true }

-- Review actions: never on a run the reviewer took part in.
local REVIEW_ACTIONS = { reviewFlagged = true, handleDisputes = true, handleFailedDispute = true, voidAnyRun = true }

local function SupervisorConfig()
    local perms = Config.Permissions
    local sup = type(perms) == 'table' and perms.supervisor or nil
    if type(sup) ~= 'table' then return {} end
    return sup
end

local function ValidRunUuid(runUuid)
    return type(runUuid) == 'string' and #runUuid > 0 and #runUuid <= 36 and runUuid:match('^[%w%-]+$') ~= nil
end

local function InDepartments(dept, ctx)
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

-- A row of that run for that citizenid, live or archived.
function P.tookPart(citizenid, runUuid)
    if type(citizenid) ~= 'string' or citizenid == '' or not ValidRunUuid(runUuid) then return false end
    CP.Migrations.ready()
    for _, tbl in ipairs({ 'cp_mission_runs', 'cp_mission_runs_archive' }) do
        local ok, res = pcall(MySQL.scalar.await,
            ('SELECT 1 AS took_part FROM %s WHERE run_uuid = ? AND citizenid = ? LIMIT 1'):format(tbl),
            { runUuid, citizenid })
        if not ok then
            CP.err(TAG, 'tookPart lookup failed: %s', tostring(res))
            -- Fail closed: a reviewer who cannot be cleared is treated as a participant.
            return true
        end
        if res ~= nil then return true end
    end
    return false
end

-- Whether an action is admin-only (supervisors never pass it).
function P.isAdminOnly(action) return ADMIN_ONLY[action] == true end

-- Every admin-only action key, in a fixed order.
function P.adminOnlyKeys()
    local out = {}
    for i, a in ipairs(ADMIN_ONLY_LIST) do out[i] = a end
    return out
end

-- The reviewer is (or was) a participant of that run while it is still live (no row of theirs yet).
local function InLiveRun(citizenid, runUuid)
    if type(citizenid) ~= 'string' or citizenid == '' then return false end
    if not (CP.Runs and type(CP.Runs.get) == 'function') then return false end
    local ok, run = pcall(CP.Runs.get, runUuid)
    if not ok or type(run) ~= 'table' or type(run.participants) ~= 'table' then return false end
    for _, p in pairs(run.participants) do
        if type(p) == 'table' and p.citizenid == citizenid then return true end
    end
    return false
end

function P.canReviewRun(src, runUuid)
    if not ValidRunUuid(runUuid) then return false, 'err.invalid_run' end
    local n = tonumber(src)
    if n == 0 then return true end
    if not n or n < 0 then return false, 'err.no_permission' end
    local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(n)
    if not info then return true end
    if InLiveRun(info.citizenid, runUuid) or P.tookPart(info.citizenid, runUuid) then return false, 'err.own_run' end
    return true
end

function P.can(src, action, ctx)
    if type(action) ~= 'string' or action == '' then return false, 'err.no_permission' end
    local n = tonumber(src)
    if not n or n < 0 or not CP.Access then return false, 'err.no_permission' end
    if type(ctx) ~= 'table' then ctx = nil end

    if not CP.Access.isAdmin(n) then
        if ADMIN_ONLY[action] then return false, 'err.no_permission' end
        if not SUPERVISOR_ALWAYS[action] and SupervisorConfig()[action] ~= true then
            return false, 'err.no_permission'
        end
        if not CP.Access.isSupervisor(n) then return false, 'err.no_permission' end
        if ctx and (ctx.department ~= nil or ctx.departments ~= nil) then
            local officer = CP.Access.getOfficer(n)
            if not officer then return false, 'err.no_permission' end
            if not InDepartments(officer.department, ctx) then return false, 'err.other_department' end
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
    local sup = SupervisorConfig()
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

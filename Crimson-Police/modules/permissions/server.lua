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

-- Actions supervisors always have (no Config.Permissions switch). fieldTraining: pair and unpair field training.
local SUPERVISOR_ALWAYS = { viewMissionList = true, fieldTraining = true }

-- Powers an extra grant may give besides the supervisor switches (Config.Permissions.grants): the builder Teleport
-- button, field training pairing and the criminal tablet (G2, read by CP.CrimTab while Config.CriminalTablet.access
-- is 'granted'). viewMissionList (the department report and the live list) is never granted.
local EXTRA_POWERS_LIST = { 'builderTeleport', 'fieldTraining', 'criminalTablet' }
local EXTRA_POWERS = {}
for _, a in ipairs(EXTRA_POWERS_LIST) do EXTRA_POWERS[a] = true end
-- Player powers: grantable, but no supervisor action (never in actionsFor, so never the Supervisor UI button).
local PLAYER_POWERS = { criminalTablet = true }

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

-- A grade grant of the shape { minGrade = N } (that grade and up) or { grades = { ... } } (only those grades), as
-- Config.Permissions.builderTeleport and Config.MissionControls.grants hold it: true when officer.gradeLevel fits.
function P.gradeGrant(officer, grant)
    local grade = type(officer) == 'table' and tonumber(officer.gradeLevel) or nil
    if type(grant) ~= 'table' or not grade then return false end
    if tonumber(grant.minGrade) and grade >= tonumber(grant.minGrade) then return true end
    for _, v in ipairs(type(grant.grades) == 'table' and grant.grades or {}) do
        if tonumber(v) == grade then return true end
    end
    return false
end

-- A row of that run for that citizenid, live or archived. asSuspect (the self rule over suspects, V17): a real
-- suspect of that run's case counts too (CP.Opponents.suspectOfRun: memory, then cp_pvp_pairs).
function P.tookPart(citizenid, runUuid, asSuspect)
    if type(citizenid) ~= 'string' or citizenid == '' or not ValidRunUuid(runUuid) then return false end
    if asSuspect and CP.Opponents and CP.Opponents.suspectOfRun then
        local ok, was = pcall(CP.Opponents.suspectOfRun, citizenid, runUuid)
        -- Fail closed: a suspect lookup that cannot answer counts as taking part.
        if not ok or was ~= false then
            if not ok then CP.err(TAG, 'tookPart suspect lookup failed: %s', tostring(was)) end
            return true
        end
    end
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

-- ============================================================================
--                   EXTRA GRANTS (Config.Permissions.grants)
-- ============================================================================
-- Admin UI -> Permissions -> Extra grants: a power for players who are not supervisors, by department and grade,
-- Qbox gang and grade, or single citizenid. Read at every call. Admins never come from here (Config.AdminAce and
-- Config.QboxAdmins only) and an admin-only action is never grantable.

-- Whether a power may be granted: a key of Config.Permissions.supervisor (on or off) or an extra power, never an
-- admin-only action.
function P.isGrantable(cap)
    if type(cap) ~= 'string' or cap == '' or ADMIN_ONLY[cap] then return false end
    if EXTRA_POWERS[cap] then return true end
    return type(SupervisorConfig()[cap]) == 'boolean'
end

-- Every grantable power, the supervisor switches first (config.lua order is lost in a table: sorted), then the extras.
function P.grantableKeys()
    local out = {}
    for k, v in pairs(SupervisorConfig()) do
        if type(k) == 'string' and type(v) == 'boolean' and not ADMIN_ONLY[k] and not EXTRA_POWERS[k] then
            out[#out + 1] = k
        end
    end
    table.sort(out)
    for _, k in ipairs(EXTRA_POWERS_LIST) do out[#out + 1] = k end
    return out
end

local function GrantOf(cap)
    local perms = Config.Permissions
    local all = type(perms) == 'table' and perms.grants or nil
    local g = type(all) == 'table' and all[cap] or nil
    return type(g) == 'table' and g or nil
end

-- True when an extra grant names this player for that power: his citizenid, his department with his grade, or his
-- Qbox gang with its grade. Nothing else (the supervisor rule, the switches) is checked here.
function P.granted(src, cap)
    local n = math.tointeger(tonumber(src))
    if not n or n <= 0 or not P.isGrantable(cap) then return false end
    local g = GrantOf(cap)
    if not g then return false end
    local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(n) or nil
    if type(info) ~= 'table' then return false end
    if type(g.citizenids) == 'table' and type(info.citizenid) == 'string' then
        for _, cid in ipairs(g.citizenids) do
            if cid == info.citizenid then return true end
        end
    end
    if type(g.departments) == 'table' and CP.Access and CP.Access.getOfficer then
        local officer = CP.Access.getOfficer(n)
        if type(officer) == 'table' and type(officer.department) == 'string'
            and P.gradeGrant(officer, g.departments[officer.department]) then
            return true
        end
    end
    local gang = info.gang
    if type(g.gangs) == 'table' and type(gang) == 'table' and type(gang.name) == 'string' then
        if P.gradeGrant({ gradeLevel = gang.gradeLevel }, g.gangs[gang.name]) then return true end
    end
    return false
end

-- The powers extra grants give this player (sorted); {} for most players.
function P.grantedFor(src)
    local out = {}
    local perms = Config.Permissions
    local all = type(perms) == 'table' and perms.grants or nil
    if type(all) ~= 'table' or next(all) == nil then return out end
    for _, cap in ipairs(P.grantableKeys()) do
        if all[cap] ~= nil and P.granted(src, cap) then out[#out + 1] = cap end
    end
    return out
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
    -- any character of the reviewer's licenses (live or archived rows, or still on the run) is "own" too
    if CP.AdminKit and CP.AdminKit.selfRun and CP.AdminKit.selfRun(n, runUuid) then return false, 'err.own_run' end
    local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(n)
    if not info then return true end
    if InLiveRun(info.citizenid, runUuid) or P.tookPart(info.citizenid, runUuid, true) then
        return false, 'err.own_run'
    end
    return true
end

-- A player who is not an admin asked for an admin-only action (below, AdminKit's guard and its read callbacks). No
-- officer or supervisor screen sends one, so it is almost always a cheat menu probing the money and void tools. The
-- reply stays the same; one console line (kept in Admin UI → System → Problems) names the player and the request:
-- once a minute per player and request, at most Config.AntiCheat.adminProbeLines lines a minute per player (0 = no
-- line). The console and server code (src 0) never count.
local PROBE_WINDOW_MS = 60000
local PROBE_LINES_DEFAULT = 5

local function ProbeLines()
    local ac = Config.AntiCheat
    local v = type(ac) == 'table' and tonumber(ac.adminProbeLines) or nil
    if v == nil then return PROBE_LINES_DEFAULT end
    return math.max(0, math.floor(v))
end

function P.probe(src, name)
    local n = math.tointeger(tonumber(src))
    if not n or n <= 0 then return end
    local cap = ProbeLines()
    if cap <= 0 or not (CP.Net and CP.Net.rateOk) then return end
    name = tostring(name)
    if not CP.Net.rateOk(n, 'perm:probe:' .. name, 1, PROBE_WINDOW_MS) then return end
    if not CP.Net.rateOk(n, 'perm:probe', cap, PROBE_WINDOW_MS) then return end
    CP.warn('security', 'player %d (%s) sent admin-only %s while not an admin', n, tostring(GetPlayerName(n) or '?'),
        name)
end

-- known (internal, step OP3): { admin = boolean } when the caller has just asked CP.Access.isAdmin for this player
-- (CP.AdminKit's guards), so the ace checks are not made twice for one request.
function P.can(src, action, ctx, known)
    if type(action) ~= 'string' or action == '' then return false, 'err.no_permission' end
    local n = tonumber(src)
    if not n or n < 0 or not CP.Access then return false, 'err.no_permission' end
    if type(ctx) ~= 'table' then ctx = nil end
    local admin = nil
    if type(known) == 'table' then admin = known.admin end
    if type(admin) ~= 'boolean' then admin = CP.Access.isAdmin(n) and true or false end

    if not admin then
        if ADMIN_ONLY[action] then
            P.probe(n, action)
            return false, 'err.no_permission'
        end
        if not SUPERVISOR_ALWAYS[action] and SupervisorConfig()[action] ~= true then
            return false, 'err.no_permission'
        end
        -- a supervisor by grade, or a player an extra grant names for this power
        if not CP.Access.isSupervisor(n) and not P.granted(n, action) then return false, 'err.no_permission' end
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
        local set = {}
        for a in pairs(SUPERVISOR_ALWAYS) do set[a] = true end
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
    else
        -- extra grants: the granted supervisor powers that are switched on, and the granted extra powers
        for _, a in ipairs(P.grantedFor(n)) do
            if (sup[a] == true or SUPERVISOR_ALWAYS[a] or EXTRA_POWERS[a]) and not PLAYER_POWERS[a] then
                out[#out + 1] = a
            end
        end
    end
    table.sort(out)
    return out
end

-- modules/access/server.lua · CP.Access (server): departments, roles, duty, active job, rank and
-- callsign, suspension checks.
--
-- Owns: the sanitised copy of Config.Departments (theme and logo validation with ONE console warning
-- per bad key), who counts as an officer / supervisor / admin, the Crimson-Police suspension
-- (cp_officers.suspended_until), the stored copy of rank, callsign and name (cp_officers), the
-- immediate "no longer qualifies" signal (onLost) and the server export GetDepartment.
-- All framework data comes through CP.Qbx; SC-Dispatch suspensions through CP.Dispatch.
--
-- Public API (docs/ARCHITECTURE.md §5.2)
--   CP.Access.departmentForJob(jobName) -> deptKey|nil
--   CP.Access.department(key) -> dept|nil       (a copy)
--       dept = { key, label, short, jobs = { jobName... }, supervisorGrade, societyAccount,
--                theme = { primary, accent, background, surface, text },
--                logo = { url|nil, file|nil, watermark, opacity, size, grayscale } }
--       Colours must be 6-digit hex: a missing or invalid one falls back to the Crimson-Police default
--       (one warning per department and key); a missing text colour is picked with CP.U.contrastText
--       for the background (an invalid one too, with a warning). logo.url is the configured https://
--       url, else https://cfx-nui-Crimson-Police/logos/<file> (file names only: no folders);
--       opacity is clamped to 0-0.25 (default 0.08), size to 0.05-1 (default 0.6), watermark defaults
--       to true, grayscale to false.
--   CP.Access.departments() -> { dept, ... }     sorted by key (copies)
--   CP.Access.getOfficer(src) -> officer|nil, errKey
--       officer = { src, citizenid, name, department, departmentLabel, departmentShort, job, rank,
--                   gradeLevel, callsign|nil, onduty = true, isSupervisor, isAdmin }   (§3.1)
--       Only the ACTIVE Qbox job counts (a department job held as a second sc-multijob job gives no
--       access). errKeys, in check order: err.not_police (no character, or the active job is in no
--       department), err.not_on_duty, err.suspended (Crimson-Police), err.suspended_dispatch
--       (SC-Dispatch, checked for the active job). Suspension lookups are cached for 15 s.
--   CP.Access.isAdmin(src) -> boolean            IsPlayerAceAllowed(src, Config.AdminAce); 0 = console = true
--   CP.Access.isSupervisor(src) -> boolean       a qualifying officer whose grade >= supervisorGrade
--   CP.Access.role(src) -> 'admin'|'supervisor'|'officer'|nil   (the highest)
--   CP.Access.recheck(src, jobName) -> ok, endReason
--       For a run participant who accepted with jobName: 'job_change' (active job differs from jobName,
--       or is in no department), 'off_duty', 'suspended' (either suspension). A player without a loaded
--       character returns true: the drop/unload paths end the run as disconnected.
--   CP.Access.isSuspended(citizenid) -> boolean, untilTs|nil
--   CP.Access.suspend(citizenid, days, actorSrc, reason) -> ok, errKey
--       0 days lifts it. days: a whole number 0-3650 (err.invalid_days); citizenid as stored by Qbox
--       (err.invalid_citizenid). When actorSrc is a player it must pass CP.Permissions.can(actorSrc,
--       'suspend') (err.no_permission). An online officer is told on their tablet and a new suspension
--       fires onLost(src, 'suspended'). Not audited here: the caller (modules/admin, modules/anticheat)
--       writes the audit entry.
--   CP.Access.refreshOfficerRow(src) -> boolean
--       Upsert cp_officers callsign (32 chars), rank_label (40), display_name (64) and department for a
--       player whose active job is in a department (on duty or not). Runs on character load, on a
--       job/grade change and when the tablet opens.
--   CP.Access.onLost(fn(src, endReason))
--       Fired right after a qbx duty/job/group event for a player whose last known active job (seeded at
--       start, on load and by the first getOfficer/recheck) was a department job and who no longer qualifies: 'job_change' (the active job changed, including to
--       'unemployed'), 'off_duty', 'suspended'. Listeners check whether the player is on a run.
--   Server export GetDepartment(src) -> deptKey|nil   the department of the player's active job
--                                                      (whether or not they are on duty)
-- getOfficer, isSupervisor, role, recheck, isSuspended, suspend and refreshOfficerRow may yield
-- (database): call them from a handler or thread.

CP.Access = CP.Access or {}
local A = CP.Access
local TAG = 'access'

-- The Crimson-Police default theme (the neutral admin theme; the NUI uses the same values).
local DEFAULT_THEME = { primary = '#a4161a', accent = '#e5383b', background = '#0b090a', surface = '#161a1d', text = '#f5f3f4' }
local COLOUR_KEYS = { 'primary', 'accent', 'background', 'surface' }
local LOGO_EXTENSIONS = { png = true, webp = true, svg = true, jpg = true, jpeg = true }
local NO_SUPERVISOR_GRADE = 1000
local SUSPENSION_TTL = 15
local MAX_SUSPEND_DAYS = 3650

local warned = {}
local cache = { built = false }
local suspensionCache = {}   -- citizenid -> { untilTs = ts|nil, at = os.time() }
local dispatchCache = {}     -- citizenid|job -> { suspended = bool, at = os.time() }
local lastJob = {}           -- src -> last known active job name
local lostListeners = {}

-- ── helpers ─────────────────────────────────────────────────────────────────
local function warnOnce(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    CP.warn(TAG, fmt, ...)
end

local function toSrc(src)
    local n = tonumber(src)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

-- At most n bytes, never ending in half a UTF-8 character: the cp_officers columns count characters,
-- and MariaDB's strict mode rejects the whole upsert for a string cut inside a multi-byte character
-- (CP.U.clip cuts bytes). Names and callsigns are free text, e.g. "José" or "Łukasz".
local function clipText(s, n)
    if s == nil then return nil end
    s = tostring(s)
    if #s <= n then return s end
    s = s:sub(1, n)
    local last = #s
    local j = last
    while j > 1 and j > last - 3 and s:byte(j) >= 0x80 and s:byte(j) < 0xC0 do j = j - 1 end
    local lead = s:byte(j)
    if lead >= 0xC0 then
        local need = (lead >= 0xF0 and 4) or (lead >= 0xE0 and 3) or 2
        if last - j + 1 < need then return s:sub(1, j - 1) end
    end
    return s
end
A._clipText = clipText   -- exposed for tests/core_spec.lua only

local function nonEmpty(v, max)
    if type(v) ~= 'string' then return nil end
    local s = CP.U.trim(v)
    if s == '' then return nil end
    return clipText(s, max)
end

local function describe(v)
    if v == nil then return 'missing' end
    return ('"%s"'):format(tostring(v))
end

local function notify(src, kind, key, vars)
    if CP.Tablet and CP.Tablet.notify then CP.Tablet.notify(src, kind, key, vars) end
end

-- ── department sanitising ───────────────────────────────────────────────────
local function sanitizeTheme(deptKey, theme)
    if theme ~= nil and type(theme) ~= 'table' then
        warnOnce(deptKey .. '.theme', 'Department %s: theme must be a table; using the Crimson-Police default colours', deptKey)
        theme = nil
    end
    theme = theme or {}
    local out = {}
    for _, k in ipairs(COLOUR_KEYS) do
        local v = theme[k]
        if CP.U.isHexColour(v) then
            out[k] = v:lower()
        else
            warnOnce(('%s.theme.%s'):format(deptKey, k),
                'Department %s: theme.%s is %s, not a 6-digit hex colour such as #1f4e8c; using the Crimson-Police default %s',
                deptKey, k, describe(v), DEFAULT_THEME[k])
            out[k] = DEFAULT_THEME[k]
        end
    end
    local text = theme.text
    if text == nil then
        out.text = CP.U.contrastText(out.background)
    elseif CP.U.isHexColour(text) then
        out.text = text:lower()
    else
        out.text = CP.U.contrastText(out.background)
        warnOnce(deptKey .. '.theme.text',
            'Department %s: theme.text is %s, not a 6-digit hex colour; picked %s for contrast with the background',
            deptKey, describe(text), out.text)
    end
    return out
end

local function sanitizeLogo(deptKey, logo)
    if logo ~= nil and type(logo) ~= 'table' then
        warnOnce(deptKey .. '.logo', 'Department %s: logo must be a table; no logo is shown', deptKey)
        logo = nil
    end
    logo = logo or {}
    local out = { watermark = logo.watermark ~= false, grayscale = logo.grayscale == true, opacity = 0.08, size = 0.6 }

    local url = logo.url
    if url ~= nil then
        if type(url) == 'string' and url:sub(1, 8):lower() == 'https://' and #url > 8 and #url <= 512 and not url:find('[%s"\'<>\\]') then
            out.url = url
        else
            warnOnce(deptKey .. '.logo.url', 'Department %s: logo.url must be a direct https:// image link; it is ignored', deptKey)
        end
    end
    local file = logo.file
    if not out.url and file ~= nil then
        local ext = type(file) == 'string' and file:match('%.(%w+)$') or nil
        if type(file) == 'string' and #file <= 100 and file:match('^[%w%-_%.]+$') and not file:find('..', 1, true)
            and ext and LOGO_EXTENSIONS[ext:lower()] then
            out.file = file
            out.url = ('https://cfx-nui-%s/logos/%s'):format(CP.resource, file)
        else
            warnOnce(deptKey .. '.logo.file',
                'Department %s: logo.file %s must be a PNG, WebP or SVG file name in logos/ (no folders); no logo is shown',
                deptKey, describe(file))
        end
    end
    if url == nil and file == nil then
        CP.log(TAG, 'department %s has no logo', deptKey)
    end

    local opacity = tonumber(logo.opacity)
    if logo.opacity ~= nil and (opacity == nil or opacity ~= opacity) then
        warnOnce(deptKey .. '.logo.opacity', 'Department %s: logo.opacity must be a number from 0.0 to 0.25; using 0.08', deptKey)
        opacity = nil
    end
    if opacity then
        local clamped = CP.U.clamp(opacity, 0.0, 0.25)
        if clamped ~= opacity then
            warnOnce(deptKey .. '.logo.opacity', 'Department %s: logo.opacity %s is outside 0.0-0.25; using %s', deptKey, tostring(opacity), tostring(clamped))
        end
        out.opacity = clamped
    end

    local size = tonumber(logo.size)
    if logo.size ~= nil and (size == nil or size ~= size or size <= 0) then
        warnOnce(deptKey .. '.logo.size', 'Department %s: logo.size must be a share of the tablet height above 0; using 0.6', deptKey)
        size = nil
    end
    if size then out.size = CP.U.clamp(size, 0.05, 1.0) end
    return out
end

local function sanitizeDepartment(key, cfg)
    local short = nonEmpty(cfg.short, 16)
    local label = nonEmpty(cfg.label, 64)
    if not short then
        short = clipText(key:upper(), 16)
        warnOnce(key .. '.short', 'Department %s has no short tag; using %s', key, short)
    end
    if not label then
        label = short
        warnOnce(key .. '.label', 'Department %s has no label; using %s', key, label)
    end

    local jobs, rawJobs = {}, cfg.jobs
    if type(rawJobs) == 'string' then rawJobs = { rawJobs } end
    if type(rawJobs) == 'table' then
        for _, j in ipairs(rawJobs) do
            if type(j) == 'string' and j ~= '' then jobs[#jobs + 1] = j end
        end
    end
    if #jobs == 0 then
        warnOnce(key .. '.jobs', 'Department %s lists no Qbox job names in jobs: nobody can use it', key)
    end

    local grade = tonumber(cfg.supervisorGrade)
    if not grade or grade ~= grade then
        warnOnce(key .. '.supervisorGrade', 'Department %s: supervisorGrade must be a Qbox grade level; nobody in it is a supervisor', key)
        grade = NO_SUPERVISOR_GRADE
    end

    local society = nonEmpty(cfg.societyAccount, 50)
    if not society then society = jobs[1] or key end

    return {
        key = key,
        label = label,
        short = short,
        jobs = jobs,
        supervisorGrade = math.floor(grade),
        societyAccount = society,
        theme = sanitizeTheme(key, cfg.theme),
        logo = sanitizeLogo(key, cfg.logo),
    }
end

-- The sanitised departments, rebuilt only when Config.Departments is replaced.
local function build()
    local source = Config.Departments
    if cache.built and cache.source == source then return cache end
    local list, byKey, byJob = {}, {}, {}
    if type(source) == 'table' then
        local keys = {}
        for k in pairs(source) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do
            local cfg = source[k]
            if type(k) ~= 'string' or not k:match('^[%w_]+$') or #k > 32 then
                warnOnce('key.' .. tostring(k), 'Config.Departments key %s must be letters, digits or _ (at most 32); it is ignored', describe(k))
            elseif type(cfg) ~= 'table' then
                warnOnce('entry.' .. k, 'Config.Departments.%s must be a table; it is ignored', k)
            else
                local d = sanitizeDepartment(k, cfg)
                list[#list + 1] = d
                byKey[k] = d
                for _, j in ipairs(d.jobs) do
                    if byJob[j] and byJob[j] ~= k then
                        warnOnce('job.' .. j, 'Qbox job %s is listed in departments %s and %s; %s is used', j, byJob[j], k, byJob[j])
                    else
                        byJob[j] = k
                    end
                end
            end
        end
    else
        warnOnce('departments', 'Config.Departments is missing: nobody can use Crimson-Police')
    end
    cache = { built = true, source = source, list = list, byKey = byKey, byJob = byJob }
    return cache
end

function A.departmentForJob(jobName)
    if type(jobName) ~= 'string' then return nil end
    return build().byJob[jobName]
end

function A.department(key)
    if type(key) ~= 'string' then return nil end
    local d = build().byKey[key]
    return d and CP.U.deepcopy(d) or nil
end

function A.departments()
    local out = {}
    for i, d in ipairs(build().list) do out[i] = CP.U.deepcopy(d) end
    return out
end

-- ── roles ───────────────────────────────────────────────────────────────────
function A.isAdmin(src)
    local n = tonumber(src)
    if n == 0 then return true end
    n = toSrc(n)
    if not n then return false end
    local ace = type(Config.AdminAce) == 'string' and Config.AdminAce ~= '' and Config.AdminAce or 'crimsonpolice.admin'
    local allowed = IsPlayerAceAllowed(n, ace)
    return allowed == true or allowed == 1
end

-- ── suspensions ─────────────────────────────────────────────────────────────
function A.isSuspended(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return false, nil end
    local now = os.time()
    local c = suspensionCache[citizenid]
    if not c or now - c.at >= SUSPENSION_TTL then
        CP.Migrations.ready()
        local ok, row = pcall(MySQL.single.await,
            'SELECT UNIX_TIMESTAMP(suspended_until) AS until_ts FROM cp_officers WHERE citizenid = ? AND suspended_until IS NOT NULL AND suspended_until > FROM_UNIXTIME(?) LIMIT 1',
            { citizenid, now })
        if not ok then
            CP.err(TAG, 'suspension lookup for %s failed: %s', citizenid, tostring(row))
            return false, nil
        end
        c = { untilTs = type(row) == 'table' and tonumber(row.until_ts) or nil, at = now }
        suspensionCache[citizenid] = c
    end
    if c.untilTs and c.untilTs > now then return true, c.untilTs end
    return false, nil
end

local function dispatchSuspended(citizenid, jobName)
    if not (CP.Dispatch and CP.Dispatch.isSuspended) then return false end
    local key = citizenid .. '|' .. tostring(jobName)
    local now = os.time()
    local c = dispatchCache[key]
    if c and now - c.at < SUSPENSION_TTL then return c.suspended end
    local suspended = CP.Dispatch.isSuspended(citizenid, jobName) == true
    dispatchCache[key] = { suspended = suspended, at = now }
    return suspended
end

-- ── officers ────────────────────────────────────────────────────────────────
function A.getOfficer(src)
    local n = toSrc(src)
    if not n or not (CP.Qbx and CP.Qbx.getInfo) then return nil, 'err.not_police' end
    local info = CP.Qbx.getInfo(n)
    if not info then return nil, 'err.not_police' end
    -- Only seed: the qbx event handlers (evaluate) own later changes, so a lookup racing a job switch
    -- cannot hide the onLost signal.
    if lastJob[n] == nil then lastJob[n] = info.job.name end
    local c = build()
    local deptKey = c.byJob[info.job.name]
    local dept = deptKey and c.byKey[deptKey]
    if not dept then return nil, 'err.not_police' end
    if not info.job.onduty then return nil, 'err.not_on_duty' end
    if A.isSuspended(info.citizenid) then return nil, 'err.suspended' end
    if dispatchSuspended(info.citizenid, info.job.name) then return nil, 'err.suspended_dispatch' end
    return {
        src = n,
        citizenid = info.citizenid,
        name = clipText(info.name, 64),
        department = dept.key,
        departmentLabel = dept.label,
        departmentShort = dept.short,
        job = info.job.name,
        rank = clipText(info.job.gradeName or CP.L('common.unknown'), 40),
        gradeLevel = info.job.gradeLevel,
        callsign = info.callsign and clipText(info.callsign, 32) or nil,
        onduty = true,
        isSupervisor = info.job.gradeLevel >= dept.supervisorGrade,
        isAdmin = A.isAdmin(n),
    }
end

function A.isSupervisor(src)
    local officer = A.getOfficer(src)
    return officer ~= nil and officer.isSupervisor == true
end

function A.role(src)
    if A.isAdmin(src) then return 'admin' end
    local officer = A.getOfficer(src)
    if not officer then return nil end
    if officer.isSupervisor then return 'supervisor' end
    return 'officer'
end

function A.recheck(src, jobName)
    local n = toSrc(src)
    if not n or not (CP.Qbx and CP.Qbx.getInfo) then return true end
    local info = CP.Qbx.getInfo(n)
    if not info then return true end
    local job = info.job.name
    if lastJob[n] == nil then lastJob[n] = job end
    if (type(jobName) == 'string' and jobName ~= '' and job ~= jobName) or not build().byJob[job] then
        return false, 'job_change'
    end
    if not info.job.onduty then return false, 'off_duty' end
    if A.isSuspended(info.citizenid) or dispatchSuspended(info.citizenid, job) then return false, 'suspended' end
    return true
end

-- ── onLost ──────────────────────────────────────────────────────────────────
function A.onLost(fn)
    if type(fn) ~= 'function' then
        CP.warn(TAG, 'an onLost listener must be a function (got %s)', type(fn))
        return
    end
    lostListeners[#lostListeners + 1] = fn
end

local function fireLost(src, reason)
    CP.log(TAG, 'player %d no longer qualifies (%s)', src, reason)
    for i = 1, #lostListeners do
        local fn = lostListeners[i]
        CreateThread(function()
            local ok, err = pcall(fn, src, reason)
            if not ok then CP.err(TAG, 'onLost listener failed: %s', tostring(err)) end
        end)
    end
end

local function seed(src)
    local info = CP.Qbx.getInfo(src)
    if info then lastJob[src] = info.job.name end
end

-- Compare the player's current state with their last known active job.
local function evaluate(src)
    local n = toSrc(src)
    if not n then return end
    local info = CP.Qbx.getInfo(n)
    if not info then return end
    local prev = lastJob[n]
    local job = info.job.name
    lastJob[n] = job
    local c = build()
    if not prev or not c.byJob[prev] then return end
    local reason
    if job ~= prev or not c.byJob[job] then
        reason = 'job_change'
    elseif not info.job.onduty then
        reason = 'off_duty'
    elseif A.isSuspended(info.citizenid) or dispatchSuspended(info.citizenid, job) then
        reason = 'suspended'
    end
    if reason then fireLost(n, reason) end
end

function A.suspend(citizenid, days, actorSrc, reason)
    if type(citizenid) ~= 'string' then return false, 'err.invalid_citizenid' end
    citizenid = CP.U.trim(citizenid)
    if citizenid == '' or #citizenid > 50 or not citizenid:match('^[%w_%-]+$') then return false, 'err.invalid_citizenid' end
    local d = tonumber(days)
    if not d or d ~= d or d < 0 or d > MAX_SUSPEND_DAYS or d ~= math.floor(d) then return false, 'err.invalid_days' end
    d = math.floor(d)
    local actor = tonumber(actorSrc)
    if actor and actor > 0 then
        local allowed = CP.Permissions and CP.Permissions.can and CP.Permissions.can(actor, 'suspend')
        if not allowed then return false, 'err.no_permission' end
    end

    CP.Migrations.ready()
    local now = os.time()
    if d == 0 then
        local ok, err = pcall(MySQL.update.await, 'UPDATE cp_officers SET suspended_until = NULL WHERE citizenid = ?', { citizenid })
        if not ok then
            CP.err(TAG, 'lifting the suspension of %s failed: %s', citizenid, tostring(err))
            return false, 'err.internal'
        end
        suspensionCache[citizenid] = { untilTs = nil, at = now }
    else
        local untilTs = now + d * 86400
        local ok, err = pcall(MySQL.update.await,
            'INSERT INTO cp_officers (citizenid, suspended_until) VALUES (?, FROM_UNIXTIME(?)) ON DUPLICATE KEY UPDATE suspended_until = VALUES(suspended_until)',
            { citizenid, untilTs })
        if not ok then
            CP.err(TAG, 'suspending %s failed: %s', citizenid, tostring(err))
            return false, 'err.internal'
        end
        suspensionCache[citizenid] = { untilTs = untilTs, at = now }
    end
    CP.log(TAG, '%s %s (%d days) by %s: %s', d == 0 and 'unsuspended' or 'suspended', citizenid, d,
        tostring(actorSrc), tostring(reason or ''))

    local target = CP.Qbx and CP.Qbx.getByCitizenId and CP.Qbx.getByCitizenId(citizenid)
    if target then
        if d > 0 then
            fireLost(target, 'suspended')
            notify(target, 'error', 'access.suspended_notice', { days = d })
        else
            notify(target, 'success', 'access.unsuspended_notice')
        end
    end
    return true
end

function A.refreshOfficerRow(src)
    local n = toSrc(src)
    if not n or not (CP.Qbx and CP.Qbx.getInfo) then return false end
    local info = CP.Qbx.getInfo(n)
    if not info then return false end
    local deptKey = build().byJob[info.job.name]
    if not deptKey then return false end
    CP.Migrations.ready()
    -- '' stands for NULL so the parameter list never has holes.
    local ok, err = pcall(MySQL.update.await,
        [[INSERT INTO cp_officers (citizenid, callsign, rank_label, display_name, department)
          VALUES (?, NULLIF(?, ''), NULLIF(?, ''), ?, ?)
          ON DUPLICATE KEY UPDATE callsign = VALUES(callsign), rank_label = VALUES(rank_label),
            display_name = VALUES(display_name), department = VALUES(department)]],
        { info.citizenid, clipText(info.callsign or '', 32), clipText(info.job.gradeName or '', 40),
          clipText(info.name, 64), deptKey })
    if not ok then
        CP.err(TAG, 'refreshing cp_officers for %s failed: %s', info.citizenid, tostring(err))
        return false
    end
    CP.log(TAG, 'officer row refreshed: %s %s %s', info.citizenid, deptKey, tostring(info.callsign))
    return true
end

-- ── export ──────────────────────────────────────────────────────────────────
local function getDepartment(src)
    local ok, key = pcall(function()
        local n = toSrc(src)
        if not n or not (CP.Qbx and CP.Qbx.getInfo) then return nil end
        local info = CP.Qbx.getInfo(n)
        if not info then return nil end
        return build().byJob[info.job.name]
    end)
    if ok then return key end
    CP.err(TAG, 'GetDepartment failed: %s', tostring(key))
    return nil
end

exports('GetDepartment', getDepartment)

-- ── wiring (at runtime, once every module is loaded) ───────────────────────
CreateThread(function()
    build()   -- validate Config.Departments now so its warnings appear at start
    if not CP.Qbx then
        CP.err(TAG, 'modules/integrations/qbx is missing: access cannot follow duty or job changes')
        return
    end
    CP.Qbx.onDutyChange(function(src) evaluate(src) end)
    CP.Qbx.onGroupUpdate(function(src) evaluate(src) end)
    CP.Qbx.onJobChange(function(src, job)
        evaluate(src)
        if type(job) == 'table' and build().byJob[job.name] then A.refreshOfficerRow(src) end
    end)
    CP.Qbx.onPlayerLoaded(function(src)
        seed(src)
        A.refreshOfficerRow(src)
    end)
    CP.Qbx.onPlayerUnload(function(src) lastJob[src] = nil end)
    for _, src in ipairs(CP.Qbx.getOnlinePlayers()) do seed(src) end
end)

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if src then lastJob[src] = nil end
end)

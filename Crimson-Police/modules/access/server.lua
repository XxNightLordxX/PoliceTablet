-- CP.Access (server): departments, roles, duty, active job, rank and callsign, suspension checks.

CP.Access = CP.Access or {}
local A = CP.Access
local TAG = 'access'

-- The Crimson-Police default theme (the neutral admin theme; the NUI uses the same values).
local DEFAULT_THEME = {
    primary = '#a4161a',
    accent = '#e5383b',
    background = '#0b090a',
    surface = '#161a1d',
    text = '#f5f3f4',
}
local COLOUR_KEYS = { 'primary', 'accent', 'background', 'surface' }
local LOGO_EXTENSIONS = { png = true, webp = true, svg = true, jpg = true, jpeg = true }
local NO_SUPERVISOR_GRADE = 1000
local SUSPENSION_TTL = 15
local MAX_SUSPEND_DAYS = 3650
local MAX_UNIX_TS = 2147483647   -- 2038-01-19 03:14:07 UTC: the last time FROM_UNIXTIME / UNIX_TIMESTAMP handle
local DEFAULT_ADMIN_ACE = 'crimsonpolice.admin'
local QBOX_ADMIN_ACE = 'admin'   -- the ace qbx_core checks for its admins; stock Qbox gives it to group.admin

local warned = {}
local cache = { built = false }
local suspensionCache = {}   -- citizenid -> { untilTs = ts|nil, at = os.time() }
local retiredCache = {}      -- citizenid -> { retired = bool, at = os.time() }
local licenseCache = {}      -- citizenid -> { license = string|false, at = os.time() }
local dispatchCache = {}     -- citizenid|job -> { suspended = bool, at = os.time() }
local lastJob = {}           -- src -> last known active job name
local lostListeners = {}

-- ============================================================================
--                                   HELPERS
-- ============================================================================

local function WarnOnce(key, fmt, ...)
    if warned[key] then return end
    warned[key] = true
    CP.warn(TAG, fmt, ...)
end

local function ToSrc(src)
    local n = tonumber(src)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

-- At most n bytes, never ending in half a UTF-8 character: the cp_officers columns count characters,
-- and MariaDB's strict mode rejects the whole upsert for a string cut inside a multi-byte character
-- (the same rule as CP.U.clip). Names and callsigns are free text, e.g. "José" or "Łukasz".
local function ClipText(s, n)
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

local function NonEmpty(v, max)
    if type(v) ~= 'string' then return nil end
    local s = CP.U.trim(v)
    if s == '' then return nil end
    return ClipText(s, max)
end

local function Describe(v)
    if v == nil then return 'missing' end
    return ('"%s"'):format(tostring(v))
end

local function Notify(src, kind, key, vars)
    if CP.Tablet and CP.Tablet.notify then CP.Tablet.notify(src, kind, key, vars) end
end

-- ============================================================================
--                            DEPARTMENT SANITISING
-- ============================================================================

local function SanitizeTheme(deptKey, theme)
    if theme ~= nil and type(theme) ~= 'table' then
        WarnOnce(deptKey .. '.theme', 'Department %s: theme must be a table; using the Crimson-Police default colours',
            deptKey)
        theme = nil
    end
    theme = theme or {}
    local out = {}
    for _, k in ipairs(COLOUR_KEYS) do
        local v = theme[k]
        if CP.U.isHexColour(v) then
            out[k] = v:lower()
        else
            WarnOnce(('%s.theme.%s'):format(deptKey, k),
                'Department %s: theme.%s is %s, not a 6-digit hex colour such as #1f4e8c; using the Crimson-Police default %s',
                deptKey, k, Describe(v), DEFAULT_THEME[k])
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
        WarnOnce(deptKey .. '.theme.text',
            'Department %s: theme.text is %s, not a 6-digit hex colour; picked %s for contrast with the background',
            deptKey, Describe(text), out.text)
    end
    return out
end

local function SanitizeLogo(deptKey, logo)
    if logo ~= nil and type(logo) ~= 'table' then
        WarnOnce(deptKey .. '.logo', 'Department %s: logo must be a table; no logo is shown', deptKey)
        logo = nil
    end
    logo = logo or {}
    local out = { watermark = logo.watermark ~= false, grayscale = logo.grayscale == true, opacity = 0.08, size = 0.6 }

    local url = logo.url
    if url ~= nil then
        if type(url) == 'string' and url:sub(1, 8):lower() == 'https://' and #url > 8 and #url <= 512
            and not url:find('[%s"\'<>\\]') then
            out.url = url
        else
            WarnOnce(deptKey .. '.logo.url',
                'Department %s: logo.url must be a direct https:// image link; it is ignored', deptKey)
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
            WarnOnce(deptKey .. '.logo.file',
                'Department %s: logo.file %s must be a PNG, WebP or SVG file name in logos/ (no folders); no logo is shown',
                deptKey, Describe(file))
        end
    end
    if url == nil and file == nil then
        CP.log(TAG, 'department %s has no logo', deptKey)
    end

    local opacity = tonumber(logo.opacity)
    if logo.opacity ~= nil and (opacity == nil or opacity ~= opacity) then
        WarnOnce(deptKey .. '.logo.opacity',
            'Department %s: logo.opacity must be a number from 0.0 to 0.25; using 0.08', deptKey)
        opacity = nil
    end
    if opacity then
        local clamped = CP.U.clamp(opacity, 0.0, 0.25)
        if clamped ~= opacity then
            WarnOnce(deptKey .. '.logo.opacity', 'Department %s: logo.opacity %s is outside 0.0-0.25; using %s',
                deptKey, tostring(opacity), tostring(clamped))
        end
        out.opacity = clamped
    end

    local size = tonumber(logo.size)
    if logo.size ~= nil and (size == nil or size ~= size or size <= 0) then
        WarnOnce(deptKey .. '.logo.size',
            'Department %s: logo.size must be a share of the tablet height above 0; using 0.6', deptKey)
        size = nil
    end
    if size then out.size = CP.U.clamp(size, 0.05, 1.0) end
    return out
end

local function SanitizeDepartment(key, cfg)
    local short = NonEmpty(cfg.short, 16)
    local label = NonEmpty(cfg.label, 64)
    if not short then
        short = ClipText(key:upper(), 16)
        WarnOnce(key .. '.short', 'Department %s has no short tag; using %s', key, short)
    end
    if not label then
        label = short
        WarnOnce(key .. '.label', 'Department %s has no label; using %s', key, label)
    end

    local jobs, rawJobs = {}, cfg.jobs
    if type(rawJobs) == 'string' then rawJobs = { rawJobs } end
    if type(rawJobs) == 'table' then
        for _, j in ipairs(rawJobs) do
            if type(j) == 'string' and j ~= '' then jobs[#jobs + 1] = j end
        end
    end
    if #jobs == 0 then
        WarnOnce(key .. '.jobs',
            'Department %s lists no Qbox job names in jobs: nobody can use it. Put your police job name in jobs = { } of Config.Departments.%s in config/config.lua',
            key, key)
    end

    local grade = tonumber(cfg.supervisorGrade)
    if not grade or grade ~= grade then
        WarnOnce(key .. '.supervisorGrade',
            'Department %s: supervisorGrade must be a Qbox grade level; nobody in it is a supervisor. Set supervisorGrade of Config.Departments.%s in config/config.lua to a grade number, such as 3',
            key, key)
        grade = NO_SUPERVISOR_GRADE
    end

    local society = NonEmpty(cfg.societyAccount, 50)
    if not society then society = jobs[1] or key end

    return {
        key = key,
        label = label,
        short = short,
        jobs = jobs,
        supervisorGrade = math.floor(grade),
        societyAccount = society,
        theme = SanitizeTheme(key, cfg.theme),
        logo = SanitizeLogo(key, cfg.logo),
    }
end

-- The sanitised departments, rebuilt only when Config.Departments is replaced.
local function Build()
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
                WarnOnce('key.' .. tostring(k),
                    'Config.Departments key %s must be letters, digits or _ (at most 32); it is ignored', Describe(k))
            elseif type(cfg) ~= 'table' then
                WarnOnce('entry.' .. k, 'Config.Departments.%s must be a table; it is ignored', k)
            else
                local d = SanitizeDepartment(k, cfg)
                list[#list + 1] = d
                byKey[k] = d
                for _, j in ipairs(d.jobs) do
                    if byJob[j] and byJob[j] ~= k then
                        WarnOnce('job.' .. j, 'Qbox job %s is listed in departments %s and %s; %s is used', j, byJob[j],
                            k, byJob[j])
                    else
                        byJob[j] = k
                    end
                end
            end
        end
    else
        WarnOnce('departments', 'Config.Departments is missing: nobody can use Crimson-Police')
    end
    cache = { built = true, source = source, list = list, byKey = byKey, byJob = byJob }
    return cache
end

function A.departmentForJob(jobName)
    if type(jobName) ~= 'string' then return nil end
    return Build().byJob[jobName]
end

function A.department(key)
    if type(key) ~= 'string' then return nil end
    local d = Build().byKey[key]
    return d and CP.U.deepcopy(d) or nil
end

function A.departments()
    local out = {}
    for i, d in ipairs(Build().list) do out[i] = CP.U.deepcopy(d) end
    return out
end

-- ============================================================================
--                                    ROLES
-- ============================================================================

local function AceAllowed(src, ace)
    local allowed = IsPlayerAceAllowed(src, ace)
    return allowed == true or allowed == 1
end

-- The ace that makes a player an admin (Config.AdminAce).
function A.adminAce()
    local ace = Config.AdminAce
    if type(ace) == 'string' and ace ~= '' then return ace end
    return DEFAULT_ADMIN_ACE
end

-- The Qbox admin ace while Config.QboxAdmins is true, else nil. Only an explicit true counts: a config.lua kept
-- from an older version has no such line, so an update never widens who is an admin by itself.
function A.qboxAdminAce()
    if Config.QboxAdmins == true then return QBOX_ADMIN_ACE end
    return nil
end

function A.isAdmin(src)
    local n = tonumber(src)
    if n == 0 then return true end
    n = ToSrc(n)
    if not n then return false end
    if AceAllowed(n, A.adminAce()) then return true end
    local qbox = A.qboxAdminAce()
    return qbox ~= nil and AceAllowed(n, qbox)
end

-- ============================================================================
--                                 SUSPENSIONS
-- ============================================================================

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

local function DispatchSuspended(citizenid, jobName)
    if not (CP.Dispatch and CP.Dispatch.isSuspended) then return false end
    local key = citizenid .. '|' .. tostring(jobName)
    local now = os.time()
    local c = dispatchCache[key]
    if c and now - c.at < SUSPENSION_TTL then return c.suspended end
    local suspended = CP.Dispatch.isSuspended(citizenid, jobName) == true
    dispatchCache[key] = { suspended = suspended, at = now }
    return suspended
end

-- An SC-Dispatch suspension as Crimson-Police sees it (view only: sc-dispatch is never changed).
-- { suspended, available } (available = sc-dispatch is running).
function A.dispatchSuspension(citizenid, jobName)
    if type(citizenid) ~= 'string' or citizenid == '' then return { suspended = false, available = false } end
    local available = CP.Dispatch ~= nil and CP.Dispatch.available ~= nil and CP.Dispatch.available() == true
    if not available then return { suspended = false, available = false } end
    return { suspended = DispatchSuspended(citizenid, jobName), available = true }
end

-- A retired officer (Admin UI → Officers → Retire) can't open the tablet until an admin unretires them.
function A.isRetired(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return false end
    local now = os.time()
    local c = retiredCache[citizenid]
    if not c or now - c.at >= SUSPENSION_TTL then
        CP.Migrations.ready()
        local ok, row = pcall(MySQL.single.await,
            'SELECT 1 AS retired FROM cp_officers WHERE citizenid = ? AND retired_at IS NOT NULL LIMIT 1',
            { citizenid })
        if not ok then
            CP.err(TAG, 'retired lookup for %s failed: %s', citizenid, tostring(row))
            return false
        end
        c = { retired = type(row) == 'table', at = now }
        retiredCache[citizenid] = c
    end
    return c.retired
end

-- ============================================================================
--                                   LICENSES
-- ============================================================================
-- One player has one license and may have several characters (citizenids). The S guard of the admin actions
-- treats every character of the acting admin's license as the admin.

-- The license of an online player (nil for the console or an unknown player).
function A.licenseOfSrc(src)
    local n = ToSrc(src)
    if not n then return nil end
    local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(n) or nil
    if type(info) == 'table' and type(info.license) == 'string' and info.license ~= '' then return info.license end
    if GetPlayerIdentifierByType then
        local id = GetPlayerIdentifierByType(n, 'license')
        if type(id) == 'string' and id ~= '' then return id end
    end
    return nil
end

-- The license of a character: cp_officers.license (written at every tablet open), else Qbox's own record.
function A.licenseOf(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' or #citizenid > 50 then return nil end
    local now = os.time()
    local c = licenseCache[citizenid]
    if c and now - c.at < SUSPENSION_TTL then return c.license or nil end
    CP.Migrations.ready()
    local license = nil
    local ok, row = pcall(MySQL.single.await,
        'SELECT license FROM cp_officers WHERE citizenid = ? AND license IS NOT NULL LIMIT 1', { citizenid })
    if ok and type(row) == 'table' and type(row.license) == 'string' and row.license ~= '' then
        license = row.license
    end
    if not license and CP.Qbx and CP.Qbx.licenseOf then license = CP.Qbx.licenseOf(citizenid) end
    licenseCache[citizenid] = { license = license or false, at = now }
    return license
end

-- Every citizenid of src's license (their characters), their current one first. The console has none.
function A.selfCitizenids(src)
    local n = ToSrc(src)
    if not n then return {} end
    local out, seen = {}, {}
    local function add(cid)
        if type(cid) == 'string' and cid ~= '' and not seen[cid] then
            seen[cid] = true
            out[#out + 1] = cid
        end
    end
    local info = CP.Qbx and CP.Qbx.getInfo and CP.Qbx.getInfo(n) or nil
    if type(info) == 'table' then add(info.citizenid) end
    local license = A.licenseOfSrc(n)
    if not license then return out end
    CP.Migrations.ready()
    local ok, rows = pcall(MySQL.query.await, 'SELECT citizenid FROM cp_officers WHERE license = ?', { license })
    if ok and type(rows) == 'table' then
        for _, r in ipairs(rows) do add(r.citizenid) end
    end
    if CP.Qbx and CP.Qbx.citizenidsOfLicense then
        for _, cid in ipairs(CP.Qbx.citizenidsOfLicense(license) or {}) do add(cid) end
    end
    return out
end

-- ============================================================================
--                                   OFFICERS
-- ============================================================================

function A.getOfficer(src)
    local n = ToSrc(src)
    if not n or not (CP.Qbx and CP.Qbx.getInfo) then return nil, 'err.not_police' end
    local info = CP.Qbx.getInfo(n)
    if not info then return nil, 'err.not_police' end
    -- Only seed: the qbx event handlers (evaluate) own later changes, so a lookup racing a job switch
    -- cannot hide the onLost signal.
    if lastJob[n] == nil then lastJob[n] = info.job.name end
    local c = Build()
    local deptKey = c.byJob[info.job.name]
    local dept = deptKey and c.byKey[deptKey]
    if not dept then return nil, 'err.not_police' end
    if not info.job.onduty then return nil, 'err.not_on_duty' end
    if A.isSuspended(info.citizenid) then return nil, 'err.suspended' end
    if DispatchSuspended(info.citizenid, info.job.name) then return nil, 'err.suspended_dispatch' end
    if A.isRetired(info.citizenid) then return nil, 'err.retired' end
    return {
        src = n,
        citizenid = info.citizenid,
        name = ClipText(info.name, 64),
        department = dept.key,
        departmentLabel = dept.label,
        departmentShort = dept.short,
        job = info.job.name,
        rank = ClipText(info.job.gradeName or CP.L('common.unknown'), 40),
        gradeLevel = info.job.gradeLevel,
        callsign = info.callsign and ClipText(info.callsign, 32) or nil,
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
    local n = ToSrc(src)
    if not n or not (CP.Qbx and CP.Qbx.getInfo) then return true end
    local info = CP.Qbx.getInfo(n)
    if not info then return true end
    local job = info.job.name
    if lastJob[n] == nil then lastJob[n] = job end
    if (type(jobName) == 'string' and jobName ~= '' and job ~= jobName) or not Build().byJob[job] then
        return false, 'job_change'
    end
    if not info.job.onduty then return false, 'off_duty' end
    if A.isSuspended(info.citizenid) or DispatchSuspended(info.citizenid, job) then return false, 'suspended' end
    return true
end

-- ============================================================================
--                                    onLost
-- ============================================================================

function A.onLost(fn)
    if type(fn) ~= 'function' then
        CP.warn(TAG, 'an onLost listener must be a function (got %s)', type(fn))
        return
    end
    lostListeners[#lostListeners + 1] = fn
end

local function FireLost(src, reason)
    CP.log(TAG, 'player %d no longer qualifies (%s)', src, reason)
    for i = 1, #lostListeners do
        local fn = lostListeners[i]
        CreateThread(function()
            local ok, err = pcall(fn, src, reason)
            if not ok then CP.err(TAG, 'onLost listener failed: %s', tostring(err)) end
        end)
    end
end

local function Seed(src)
    local info = CP.Qbx.getInfo(src)
    if info then lastJob[src] = info.job.name end
end

-- Compare the player's current state with their last known active job.
local function Evaluate(src)
    local n = ToSrc(src)
    if not n then return end
    local info = CP.Qbx.getInfo(n)
    if not info then return end
    local prev = lastJob[n]
    local job = info.job.name
    lastJob[n] = job
    local c = Build()
    if not prev or not c.byJob[prev] then return end
    local reason
    if job ~= prev or not c.byJob[job] then
        reason = 'job_change'
    elseif not info.job.onduty then
        reason = 'off_duty'
    elseif A.isSuspended(info.citizenid) or DispatchSuspended(info.citizenid, job) then
        reason = 'suspended'
    end
    if reason then FireLost(n, reason) end
end

-- opts: { untilTs = unix time } suspends until that exact moment (days is then ignored; it must be in the future and
-- at most MAX_SUSPEND_DAYS away).
function A.suspend(citizenid, days, actorSrc, reason, opts)
    if type(citizenid) ~= 'string' then return false, 'err.invalid_citizenid' end
    citizenid = CP.U.trim(citizenid)
    if citizenid == '' or #citizenid > 50 or not citizenid:match('^[%w_%-]+$') then
        return false, 'err.invalid_citizenid'
    end
    local exact = type(opts) == 'table' and tonumber(opts.untilTs) or nil
    if exact then
        exact = math.floor(exact)
        local now0 = os.time()
        if exact <= now0 or exact > now0 + MAX_SUSPEND_DAYS * 86400 then return false, 'err.invalid_days' end
        days = math.max(1, math.ceil((exact - now0) / 86400))
    end
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
        local ok, err = pcall(MySQL.update.await, 'UPDATE cp_officers SET suspended_until = NULL WHERE citizenid = ?',
            { citizenid })
        if not ok then
            CP.err(TAG, 'lifting the suspension of %s failed: %s', citizenid, tostring(err))
            return false, 'err.internal'
        end
        suspensionCache[citizenid] = { untilTs = nil, at = now }
    else
        -- Beyond MAX_UNIX_TS MariaDB 10.11 writes NULL (or refuses, error 1292, in strict mode) and reads the
        -- date back as NULL: a longer suspension ends there instead.
        local untilTs = math.min(exact or (now + d * 86400), MAX_UNIX_TS)
        if untilTs <= now then
            CP.err(TAG, 'suspending %s failed: the database cannot store a date after 2038-01-19', citizenid)
            return false, 'err.internal'
        end
        local ok, err = pcall(MySQL.update.await,
            'INSERT INTO cp_officers (citizenid, suspended_until) VALUES (?, FROM_UNIXTIME(?)) ON DUPLICATE KEY UPDATE suspended_until = VALUES(suspended_until)',
            { citizenid, untilTs })
        if not ok then
            CP.err(TAG, 'suspending %s failed: %s', citizenid, tostring(err))
            return false, 'err.internal'
        end
        suspensionCache[citizenid] = { untilTs = untilTs, at = now }
    end
    CP.log(TAG, '%s %s (%d days) by %s: %s', d == 0 and 'unsuspended' or 'suspended', citizenid, d, tostring(actorSrc),
        tostring(reason or ''))

    local target = CP.Qbx and CP.Qbx.getByCitizenId and CP.Qbx.getByCitizenId(citizenid)
    if target then
        if d > 0 then
            FireLost(target, 'suspended')
            Notify(target, 'error', 'access.suspended_notice', { days = d })
        else
            Notify(target, 'success', 'access.unsuspended_notice')
        end
    end
    return true
end

function A.refreshOfficerRow(src)
    local n = ToSrc(src)
    if not n or not (CP.Qbx and CP.Qbx.getInfo) then return false end
    local info = CP.Qbx.getInfo(n)
    if not info then return false end
    local deptKey = Build().byJob[info.job.name]
    if not deptKey then return false end
    CP.Migrations.ready()
    -- '' stands for NULL so the parameter list never has holes.
    -- the player's license too (the admin actions' self check: every character of one player)
    local license = A.licenseOfSrc(n)
    local ok, err = pcall(MySQL.update.await,
        [[INSERT INTO cp_officers (citizenid, callsign, rank_label, display_name, department, license)
          VALUES (?, NULLIF(?, ''), NULLIF(?, ''), ?, ?, NULLIF(?, ''))
          ON DUPLICATE KEY UPDATE callsign = VALUES(callsign), rank_label = VALUES(rank_label),
            display_name = VALUES(display_name), department = VALUES(department),
            license = COALESCE(VALUES(license), license)]], {
            info.citizenid,
            ClipText(info.callsign or '', 32),
            ClipText(info.job.gradeName or '', 40),
            ClipText(info.name, 64),
            deptKey,
            ClipText(license or '', 64),
        })
    if not ok then
        CP.err(TAG, 'refreshing cp_officers for %s failed: %s', info.citizenid, tostring(err))
        return false
    end
    if license then licenseCache[info.citizenid] = { license = license, at = os.time() } end
    CP.log(TAG, 'officer row refreshed: %s %s %s', info.citizenid, deptKey, tostring(info.callsign))
    return true
end

-- ============================================================================
--                                    EXPORT
-- ============================================================================

local function GetDepartment(src)
    local ok, key = pcall(function()
        local n = ToSrc(src)
        if not n or not (CP.Qbx and CP.Qbx.getInfo) then return nil end
        local info = CP.Qbx.getInfo(n)
        if not info then return nil end
        return Build().byJob[info.job.name]
    end)
    if ok then return key end
    CP.err(TAG, 'GetDepartment failed: %s', tostring(key))
    return nil
end

exports('GetDepartment', GetDepartment)

-- ============================================================================
--               WIRING (at runtime, once every module is loaded)
-- ============================================================================

CreateThread(function()
    Build() -- validate Config.Departments now so its warnings appear at start
    if not CP.Qbx then
        CP.err(TAG, 'modules/integrations/qbx is missing: access cannot follow duty or job changes')
        return
    end
    CP.Qbx.onDutyChange(function(src) Evaluate(src) end)
    CP.Qbx.onGroupUpdate(function(src) Evaluate(src) end)
    CP.Qbx.onJobChange(function(src, job)
        Evaluate(src)
        if type(job) == 'table' and Build().byJob[job.name] then A.refreshOfficerRow(src) end
    end)
    CP.Qbx.onPlayerLoaded(function(src)
        Seed(src)
        A.refreshOfficerRow(src)
    end)
    CP.Qbx.onPlayerUnload(function(src) lastJob[src] = nil end)
    for _, src in ipairs(CP.Qbx.getOnlinePlayers()) do Seed(src) end
end)

-- An admin action changed an officer: their suspension, retirement and license are read again at once.
CP.Hooks.on('admin:changed', function(ev)
    local cid = type(ev) == 'table' and ev.citizenid or nil
    if type(cid) ~= 'string' then return end
    suspensionCache[cid], retiredCache[cid], licenseCache[cid] = nil, nil, nil
end)

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if src then lastJob[src] = nil end
end)

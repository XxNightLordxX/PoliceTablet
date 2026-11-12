-- CP.Setup (server): Admin UI -> Home's First-start setup (Config.AdminUi.setupScreen), shown to admins until one

-- CP.Setup (server): Admin UI -> Home's First-start setup (Config.AdminUi.setupScreen), shown to admins until one
-- finishes or skips it (Config.AdminUi.setupDone). It walks through the departments and their Qbox jobs, the
-- supervisor grades, the desks, the storage, the scripts found and a preset. Every answer is saved as an ordinary
-- setting (CP.Settings.setMany: checked, audited, in the settings history), so all of it stays editable later.

CP.Setup = CP.Setup or {}
local Setup = CP.Setup
local U = CP.U
local TAG = 'setup'

local DEPT_KEY = '^[a-z0-9_]+$'
local DEPTS_MAX = 20              -- departments one finish may change or add
local LEO_TYPE = 'leo'            -- the Qbox job type of police jobs (qbx_core shared/jobs.lua)
local LOGO_URL_MAX = 512          -- characters of a new department's logo link

local function Call(modName, fnName, ...) return CP.Call(TAG, modName, fnName, ...) end

local function Ui() return type(Config.AdminUi) == 'table' and Config.AdminUi or {} end

-- true while the setup should show: setupScreen on and not finished or skipped yet.
function Setup.pending()
    local ui = Ui()
    return ui.setupScreen == true and ui.setupDone ~= true
end

-- ============================================================================
--                                WHAT IT SHOWS
-- ============================================================================

-- A Qbox job's grades from the lowest: { { level, name, boss } }.
local function Grades(job)
    local out = {}
    for k, g in pairs(type(job) == 'table' and type(job.grades) == 'table' and job.grades or {}) do
        local level = math.tointeger(tonumber(k))
        if level then
            out[#out + 1] = {
                level = level,
                name = type(g) == 'table' and type(g.name) == 'string' and g.name or tostring(level),
                boss = type(g) == 'table' and g.isboss == true,
            }
        end
    end
    table.sort(out, function(a, b) return a.level < b.level end)
    return out
end

-- The departments of Config.Departments, by key: { key, label, short, jobs, supervisorGrade, enabled, added }.
local function Departments()
    local added = {}
    local okA, list = Call('Settings', 'addedDepartments')
    for _, k in ipairs(okA and type(list) == 'table' and list or {}) do added[k] = true end
    local out = {}
    for key, d in pairs(type(Config.Departments) == 'table' and Config.Departments or {}) do
        if type(key) == 'string' and type(d) == 'table' then
            local jobs = {}
            for _, j in ipairs(type(d.jobs) == 'table' and d.jobs or {}) do
                if type(j) == 'string' then jobs[#jobs + 1] = j end
            end
            out[#out + 1] = {
                key = key,
                label = tostring(d.label or key),
                short = tostring(d.short or key),
                jobs = jobs,
                supervisorGrade = math.tointeger(tonumber(d.supervisorGrade)) or 0,
                enabled = d.enabled ~= false,
                added = added[key] == true,
            }
        end
    end
    table.sort(out, function(a, b) return a.key < b.key end)
    return out
end

-- The Qbox jobs worth offering: every police job (type 'leo') and every job a department already lists.
local function Jobs(depts)
    local okJ, all = Call('Qbx', 'getJobs')
    all = okJ and type(all) == 'table' and all or {}
    local listed = {}
    for _, d in ipairs(depts) do
        for _, j in ipairs(d.jobs) do listed[j] = d.key end
    end
    local out = {}
    for name, job in pairs(all) do
        if type(name) == 'string' and type(job) == 'table' and (job.type == LEO_TYPE or listed[name]) then
            out[#out + 1] = {
                name = name,
                label = tostring(job.label or name),
                police = job.type == LEO_TYPE,
                grades = Grades(job),
                department = listed[name],
            }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

local function Desks()
    local t = type(Config.Tablet) == 'table' and Config.Tablet or {}
    local out = {}
    for i, d in ipairs(type(t.desks) == 'table' and t.desks or {}) do
        local c = type(d) == 'table' and d.coords or nil
        out[#out + 1] = {
            index = i,
            label = tostring(type(d) == 'table' and d.label or i),
            coords = c and { x = c.x, y = c.y, z = c.z } or nil,
        }
    end
    return out
end

local function Integrations()
    local out = {}
    local okS, status = Call('Integrations', 'status')
    for _, s in ipairs(okS and type(status) == 'table' and status or {}) do
        local okO, options = Call('Settings', 'integrationOptions', s.kind)
        out[#out + 1] = {
            kind = s.kind,
            setting = s.setting,
            active = s.active,
            why = s.why,
            options = okO and options or { 'auto', 'none' },
        }
    end
    return out
end

-- Everything the setup screen shows.
function Setup.view()
    local depts = Departments()
    local db = type(Config.Database) == 'table' and Config.Database or {}
    local okP, presets = Call('Settings', 'presets')
    local cmd = type(Config.Tablet) == 'table' and Config.Tablet.adminCommand or 'CrimsonPoliceAdmin'
    return {
        pending = Setup.pending(),
        departments = depts,
        jobs = Jobs(depts),
        desks = Desks(),
        storage = {
            database = db.enabled == true,
            folder = tostring(db.folder or 'saves'),
            oxmysql = CP.Ext.started('oxmysql'),
            copyCommand = ('/%s storage copy'):format(tostring(cmd)),
        },
        integrations = Integrations(),
        presets = okP and type(presets) == 'table' and presets or {},
    }
end

-- ============================================================================
--                               SETUP CHECKLIST
-- ============================================================================

-- Whether the audit log holds one row of this action (an admin did it at least once). false when it cannot be read.
local function Audited(action)
    CP.Db()
    local ok, id = pcall(MySQL.scalar.await, 'SELECT id FROM cp_audit WHERE action = ? LIMIT 1', { action })
    return ok and id ~= nil
end

-- How many money switches (the settings that need the typed ENABLE, CP.Settings.moneySwitches) are on now.
local function MoneyOn()
    local ok, paths = Call('Settings', 'moneySwitches')
    local n = 0
    for _, path in ipairs(ok and type(paths) == 'table' and paths or {}) do
        local node = Config
        for key in path:gmatch('[^%.]+') do node = type(node) == 'table' and node[key] or nil end
        if node == true then n = n + 1 end
    end
    return n
end

-- A department's supervisor grade is a grade of one of its jobs above that job's lowest grade.
local function GradeOk(d, jobsByName)
    for _, name in ipairs(d.jobs) do
        local grades = jobsByName[name] and jobsByName[name].grades or {}
        for i, g in ipairs(grades) do
            if g.level == d.supervisorGrade and i > 1 then return true end
        end
    end
    return false
end

-- Admin UI -> Home's Setup checklist (Config.Training.setupChecklist): what a new city still has to do, each line
-- read from the real state now. { { key, done, n? } } in a fixed order; the tablet names each line and the screen
-- that fixes it.
function Setup.checklist()
    local depts = Departments()
    local jobsByName = {}
    for _, j in ipairs(Jobs(depts)) do jobsByName[j.name] = j end
    local anyDept, grades = false, true
    for _, d in ipairs(depts) do
        if d.enabled then
            local known = #d.jobs > 0
            for _, name in ipairs(d.jobs) do
                if not jobsByName[name] then known = false end
            end
            if known then anyDept = true end
            if not GradeOk(d, jobsByName) then grades = false end
        end
    end
    local tablet = type(Config.Tablet) == 'table' and Config.Tablet or {}
    local access = type(tablet.access) == 'table' and tablet.access or {}
    local desks = access.desk == false or (type(tablet.desks) == 'table' and #tablet.desks > 0)
    local db = type(Config.Database) == 'table' and Config.Database or {}
    local scripts = true
    for _, s in ipairs(Integrations()) do
        if not s.active and s.setting ~= 'auto' and s.setting ~= 'none' then scripts = false end
    end
    local money = MoneyOn()
    return {
        { key = 'departments', done = anyDept },
        { key = 'grades', done = anyDept and grades },
        { key = 'desks', done = desks == true },
        { key = 'storage', done = db.enabled == true and CP.Ext.started('oxmysql') == true },
        { key = 'scripts', done = scripts },
        { key = 'money', done = money > 0 or Audited('moneySwitch'), n = money },
        { key = 'presets', done = Audited('settingsPreset') },
        { key = 'debug', done = Config.Debug ~= true },
    }
end

-- ============================================================================
--                                 THE ANSWERS
-- ============================================================================

-- A list of job names: each a text, once, at most 20.
local function JobList(v)
    if type(v) ~= 'table' then return nil end
    local out, seen = {}, {}
    for _, j in ipairs(v) do
        if type(j) ~= 'string' or #j > 50 then return nil end
        if not seen[j] then
            seen[j] = true
            out[#out + 1] = j
        end
    end
    if #out == 0 or #out > 20 then return nil end
    return out
end

local function SameList(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

-- The lowest boss grade of a Qbox job (the supervisors), else its top grade, else 0.
local function BossGrade(job)
    local grades = Grades(job)
    for _, g in ipairs(grades) do
        if g.boss then return g.level end
    end
    return grades[#grades] and grades[#grades].level or 0
end

-- The settings an answer sheet changes: { { path, value } } | nil, errKey.
-- answers = { departments = { [key] = { jobs?, supervisorGrade?, enabled? } },
--             add = { { job, themeFrom? (a department key whose colours it copies), logoUrl? (https:// link) } },
--             desks = { kept desk indexes }, integrations = { [kind] = setting } }
function Setup.changes(answers)
    if type(answers) ~= 'table' then return nil, 'err.invalid_payload' end
    local changes = {}
    local function put(path, value) changes[#changes + 1] = { path = path, value = value } end
    local current = {}
    for _, d in ipairs(Departments()) do current[d.key] = d end

    local n = 0
    for key, a in pairs(type(answers.departments) == 'table' and answers.departments or {}) do
        local d = type(key) == 'string' and current[key] or nil
        if not d or type(a) ~= 'table' then return nil, 'err.dept_unknown' end
        n = n + 1
        if n > DEPTS_MAX then return nil, 'err.invalid_payload' end
        local jobs = d.jobs
        if a.jobs ~= nil then
            jobs = JobList(a.jobs)
            if not jobs then return nil, 'err.invalid_payload' end
        end
        local grade = a.supervisorGrade ~= nil and math.tointeger(tonumber(a.supervisorGrade)) or d.supervisorGrade
        if not grade then return nil, 'err.invalid_payload' end
        local enabled = d.enabled
        if a.enabled ~= nil then enabled = a.enabled == true end
        if d.added then
            if not SameList(jobs, d.jobs) or grade ~= d.supervisorGrade or enabled ~= d.enabled then
                local rec = U.deepcopy(Config.Departments[key])
                rec.jobs, rec.supervisorGrade, rec.enabled = jobs, grade, enabled
                put('Departments.' .. key, rec)
            end
        else
            local base = 'Departments.' .. key .. '.'
            if not SameList(jobs, d.jobs) then put(base .. 'jobs', jobs) end
            if grade ~= d.supervisorGrade then put(base .. 'supervisorGrade', grade) end
            if enabled ~= d.enabled then put(base .. 'enabled', enabled) end
        end
    end

    -- a new department for each picked Qbox job, named after it, with the colours of themeFrom (or the new-department
    -- colours) and the logo link given (Admin UI -> Departments edits all of it later, and uploads a logo file)
    local okJ, all = Call('Qbx', 'getJobs')
    all = okJ and type(all) == 'table' and all or {}
    for _, a in ipairs(type(answers.add) == 'table' and answers.add or {}) do
        if type(a) ~= 'table' then return nil, 'err.invalid_payload' end
        local name = a.job
        local job = type(name) == 'string' and all[name] or nil
        if not job or #name > 32 or not name:match(DEPT_KEY) then return nil, 'err.dept_key' end
        if current[name] then return nil, 'err.dept_exists' end
        local from = nil
        if a.themeFrom ~= nil and a.themeFrom ~= '' then
            from = type(a.themeFrom) == 'string' and current[a.themeFrom] and Config.Departments[a.themeFrom] or nil
            if not from then return nil, 'err.dept_unknown' end
        end
        local logo = nil
        if a.logoUrl ~= nil and a.logoUrl ~= '' then
            if type(a.logoUrl) ~= 'string' or #a.logoUrl > LOGO_URL_MAX then return nil, 'err.dept_logo_url' end
            logo = { url = U.trim(a.logoUrl) }
        end
        n = n + 1
        if n > DEPTS_MAX then return nil, 'err.invalid_payload' end
        local label = tostring(job.label or name):sub(1, 64)
        local theme = U.deepcopy(
            type(from) == 'table' and type(from.theme) == 'table' and from.theme or U.NEW_DEPT_THEME)
        theme.personalAccents = nil
        put('Departments.' .. name, {
            label = label,
            short = label:sub(1, 16),
            enabled = true,
            jobs = { name },
            supervisorGrade = BossGrade(job),
            societyAccount = name,
            theme = theme,
            logo = logo,
        })
    end

    if answers.desks ~= nil then
        if type(answers.desks) ~= 'table' then return nil, 'err.invalid_payload' end
        local all = type(Config.Tablet) == 'table' and type(Config.Tablet.desks) == 'table' and Config.Tablet.desks
            or {}
        local keep = {}
        for _, i in ipairs(answers.desks) do
            local idx = math.tointeger(tonumber(i))
            if not idx or not all[idx] then return nil, 'err.invalid_payload' end
            keep[idx] = true
        end
        if U.count(keep) ~= #all then
            local list = {}
            for i, d in ipairs(all) do
                if keep[i] then list[#list + 1] = U.deepcopy(d) end
            end
            put('Tablet.desks', list)
        end
    end

    local now = type(Config.Integrations) == 'table' and Config.Integrations or {}
    for kind, v in pairs(type(answers.integrations) == 'table' and answers.integrations or {}) do
        if type(kind) ~= 'string' or type(v) ~= 'string' then return nil, 'err.invalid_payload' end
        if (now[kind] or 'auto') ~= v then put('Integrations.' .. kind, v) end
    end
    return changes
end

-- Saves every answer and marks the setup done, all as one settings save, then applies the preset picked (one more
-- save, with its own audit line). true, { changed, preset? } | false, errKey.
function Setup.finish(src, answers)
    local changes, err = Setup.changes(answers)
    if not changes then return false, err end
    changes[#changes + 1] = { path = 'AdminUi.setupDone', value = true }
    local reason = CP.L('setup.reason')
    local ok, res = CP.Settings.setMany(src, changes, { reason = reason })
    if not ok then return false, res end
    local out = { changed = #changes - 1 }
    local preset = type(answers) == 'table' and answers.preset or nil
    if type(preset) == 'string' and preset ~= '' then
        local okP, resP = CP.Settings.applyPreset(src, preset)
        if okP then
            out.preset = { key = preset, changed = type(resP) == 'table' and resP.preset and resP.preset.changed or 0 }
        else
            out.presetError = resP
        end
    end
    return true, out
end

-- Skips the setup: only Config.AdminUi.setupDone is saved.
function Setup.skip(src)
    local ok, res = CP.Settings.set(src, 'AdminUi.setupDone', true, false, { reason = CP.L('setup.reason_skip') })
    if not ok then return false, res end
    return true, { changed = 0 }
end

-- ============================================================================
--                                     NET
-- ============================================================================

local Kit = CP.AdminKit
if Kit and Kit.callback then
    Kit.callback('admin:getSetup', 'openAdmin', function() return Setup.view() end, { rate = 2 })

    -- { skip = true } | { departments, add, desks, integrations, preset }
    Kit.action('server:admin:finishSetup', 'openAdmin', function(ctx)
        local p = ctx.payload
        local ok, res
        if p.skip == true then
            ok, res = Setup.skip(ctx.src)
        else
            ok, res = Setup.finish(ctx.src, p)
        end
        if not ok then return false, res end
        ctx.audit(p.skip == true and 'setupSkipped' or 'setupFinished', 'setup', nil, tostring(res.changed))
        ctx.changed('settings')
        return true, res
    end, { rate = 1 })
end

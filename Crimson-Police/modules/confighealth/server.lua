-- CP.ConfigHealth (server): the Config health list of Admin UI → Permissions. Every check reports lines of
-- { level = 'ok' | 'warn' | 'error', text }; modules add their own with register (item rewards do).

CP.ConfigHealth = CP.ConfigHealth or {}
local Health = CP.ConfigHealth
local TAG = 'confighealth'

local START_DELAY_MS = 5000       -- the first run: after every module and ox_inventory have loaded
local MAX_LADDER = 15             -- grades named in one department line
local LEVELS = { ok = true, warn = true, error = true }
local HOST_PATTERN = '^[%w][%w%-%.]*%.[%a][%a]+$'
local EXPIRING_HOSTS = { ['cdn.discordapp.com'] = true, ['media.discordapp.net'] = true }
local THEME_KEYS = { 'primary', 'accent', 'background', 'surface' }
-- ox_inventory's default inventory:imagepath: where it looks for item pictures
local OX_IMAGE_PATH = 'nui://ox_inventory/web/images'
-- The folder name that code outside this folder uses: the ox_inventory item snippet and other scripts' exports.
local RESOURCE_NAME = 'Crimson-Police'
-- The group Qbox and txAdmin put server admins in.
local QBOX_ADMIN_GROUP = 'group.admin'
-- Resources Crimson-Police works without; warn = the line when one is not running (nil = an ok line).
local OPTIONAL_RESOURCES = {
    { name = 'sc-police', warn = 'health.res.sc_police' },
    { name = 'sc-npcpolice' },
    { name = 'sc-multijob' },
    { name = 'Crimson-Arena' },
}

local checks = {}          -- { { name, fn } } in the order registered
local results = nil        -- the last run: { ConfigHealthItem }

local function Line(level, key, vars)
    return { level = level, text = CP.L(key, vars) }
end

local function CmdName()
    return (Config.Tablet and Config.Tablet.adminCommand) or 'CrimsonPoliceAdmin'
end

local function IsVec(v)
    return (type(v) == 'vector3' or type(v) == 'table') and tonumber(v.x) ~= nil and tonumber(v.y) ~= nil
        and tonumber(v.z) ~= nil
end

-- ============================================================================
--                                   REGISTRY
-- ============================================================================

-- fn() -> { { level, text } }. A second register of a name replaces the first.
function Health.register(name, fn)
    if type(name) ~= 'string' or name == '' or type(fn) ~= 'function' then return false end
    for _, c in ipairs(checks) do
        if c.name == name then
            c.fn = fn
            return true
        end
    end
    checks[#checks + 1] = { name = name, fn = fn }
    return true
end

-- Every check once: the ConfigHealthItem list (web/src/shared/types.ts), errors first.
function Health.run()
    local out = {}
    for _, c in ipairs(checks) do
        local ok, lines = pcall(c.fn)
        if not ok then
            CP.err(TAG, 'check %s failed: %s', c.name, tostring(lines))
            out[#out + 1] = { check = c.name, level = 'error', text = CP.L('health.check_failed') }
        else
            for _, l in ipairs(type(lines) == 'table' and lines or {}) do
                if type(l) == 'table' and LEVELS[l.level] and type(l.text) == 'string' then
                    out[#out + 1] = { check = c.name, level = l.level, text = l.text }
                end
            end
        end
    end
    local rank = { error = 1, warn = 2, ok = 3 }
    for i, item in ipairs(out) do item.order = i end
    table.sort(out, function(a, b)
        if rank[a.level] ~= rank[b.level] then return rank[a.level] < rank[b.level] end
        return a.order < b.order
    end)
    for _, item in ipairs(out) do item.order = nil end
    -- the console gets the problems of the first run only (the admin screen runs the checks again)
    if not results then
        for _, item in ipairs(out) do
            if item.level ~= 'ok' then CP.warn(TAG, '%s: %s', item.check, item.text) end
        end
    end
    results = out
    return out
end

-- ============================================================================
--                               THE TABLET ITEM
-- ============================================================================

local function CheckItems()
    local t = Config.Tablet or {}
    local access = type(t.access) == 'table' and t.access or {}
    local item = type(t.item) == 'string' and t.item ~= '' and t.item or nil
    if not item then
        if access.requireItem == true then return { Line('error', 'health.item.require_no_item') } end
        return { Line('ok', 'health.item.off') }
    end
    if GetResourceState('ox_inventory') ~= 'started' then
        return { Line('error', 'health.item.no_inventory', { item = item }) }
    end
    local ok, def = pcall(function() return exports.ox_inventory:Items(item) end)
    if not ok or def == nil then return { Line('warn', 'health.item.missing', { item = item }) } end
    local out = { Line('ok', 'health.item.ok', { item = item }) }
    if access.item == false and access.requireItem ~= true then
        out[#out + 1] = Line('warn', 'health.item.way_off', { item = item })
    end
    -- the picture: only where ox_inventory looks for it by default (inventory:imagepath may point at a web host)
    local imagePath = GetConvar and GetConvar('inventory:imagepath', OX_IMAGE_PATH) or OX_IMAGE_PATH
    if imagePath == OX_IMAGE_PATH then
        local png = LoadResourceFile('ox_inventory', ('web/images/%s.png'):format(item))
        if not png or png == '' then out[#out + 1] = Line('warn', 'health.item.no_image', { item = item }) end
    end
    return out
end

-- ============================================================================
--                                MISSION DESKS
-- ============================================================================

local function CheckDesks()
    local t = Config.Tablet or {}
    if type(t.access) == 'table' and t.access.desk == false then return { Line('ok', 'health.desk.off') } end
    local desks = type(t.desks) == 'table' and t.desks or {}
    if #desks == 0 then return { Line('ok', 'health.desk.none') } end
    local out, good = {}, 0
    for i, d in ipairs(desks) do
        local label = type(d) == 'table' and tostring(d.label or i) or tostring(i)
        if type(d) ~= 'table' or not IsVec(d.coords) then
            out[#out + 1] = Line('error', 'health.desk.coords', { n = i, label = label })
        elseif d.size ~= nil and not IsVec(d.size) then
            out[#out + 1] = Line('warn', 'health.desk.size', { n = i, label = label })
        else
            local unknown = {}
            for _, k in ipairs(type(d.departments) == 'table' and d.departments or {}) do
                if not (Config.Departments and Config.Departments[k]) then unknown[#unknown + 1] = tostring(k) end
            end
            if #unknown > 0 then
                out[#out + 1] = Line('warn', 'health.desk.department',
                    { n = i, label = label, departments = table.concat(unknown, ', ') })
            else
                good = good + 1
            end
        end
    end
    if GetResourceState('ox_target') ~= 'started' then out[#out + 1] = Line('error', 'health.desk.no_target') end
    table.insert(out, 1, Line('ok', 'health.desk.ok', { n = good, total = #desks }))
    return out
end

-- ============================================================================
--                   DEPARTMENT COLOURS AND PERSONAL ACCENTS
-- ============================================================================

local function CheckColours()
    local out = {}
    local keys = {}
    for k in pairs(type(Config.Departments) == 'table' and Config.Departments or {}) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, key in ipairs(keys) do
        local d = Config.Departments[key]
        local theme = type(d) == 'table' and type(d.theme) == 'table' and d.theme or {}
        for _, k in ipairs(THEME_KEYS) do
            if not CP.U.isHexColour(theme[k]) then
                out[#out + 1] = Line('warn', 'health.colour.theme', { dept = tostring(key), key = k })
            end
        end
        local accents = theme.personalAccents
        if accents ~= nil and type(accents) ~= 'table' then
            out[#out + 1] = Line('warn', 'health.colour.accents_list', { dept = tostring(key) })
        else
            local seen, n = {}, 0
            for i, a in ipairs(accents or {}) do
                local colour = type(a) == 'table' and a.colour or a
                local level = type(a) == 'table' and a.level or nil
                if not CP.U.isHexColour(colour) then
                    out[#out + 1] = Line('warn', 'health.colour.accent', { dept = tostring(key), n = i })
                elseif level ~= nil and (not math.tointeger(tonumber(level)) or tonumber(level) < 1) then
                    out[#out + 1] = Line('warn', 'health.colour.accent_level', { dept = tostring(key), n = i })
                elseif seen[colour:lower()] then
                    out[#out + 1] = Line('warn', 'health.colour.accent_twice',
                        { dept = tostring(key), colour = colour })
                else
                    seen[colour:lower()] = true
                    n = n + 1
                end
            end
            if n > 0 then out[#out + 1] = Line('ok', 'health.colour.accents', { dept = tostring(key), n = n }) end
        end
    end
    local warned = false
    for _, l in ipairs(out) do if l.level ~= 'ok' then warned = true end end
    if not warned then table.insert(out, 1, Line('ok', 'health.colour.ok')) end
    return out
end

-- ============================================================================
--                           BUILT-IN MISSION TWEAKS
-- ============================================================================

local function CheckTweaks()
    local tweaks = Config.MissionTweaks
    if type(tweaks) ~= 'table' or next(tweaks) == nil then return { Line('ok', 'health.tweak.none') } end
    local out, applied = {}, 0
    local ids = {}
    for id in pairs(tweaks) do ids[#ids + 1] = tostring(id) end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local def = CP.Missions and CP.Missions.get and CP.Missions.get(id) or nil
        if not def then
            out[#out + 1] = Line('warn', 'health.tweak.unknown', { id = id })
        elseif def.tweaked == true then
            applied = applied + 1
        else
            out[#out + 1] = Line('warn', 'health.tweak.ignored', { id = id })
        end
    end
    table.insert(out, 1, Line('ok', 'health.tweak.ok', { n = applied, total = #ids }))
    return out
end

-- ============================================================================
--                                 LOCALE FILES
-- ============================================================================

local function CheckLocale()
    local out = {}
    local raw = LoadResourceFile(CP.resource, 'locales/en.json')
    if not raw or raw == '' then return { Line('error', 'health.locale.missing') } end
    local ok, data = pcall(json.decode, raw)
    if not ok or type(data) ~= 'table' then return { Line('error', 'health.locale.invalid') } end
    local n = 0
    for _ in pairs(data) do n = n + 1 end
    out[#out + 1] = Line('ok', 'health.locale.ok', { n = n })
    -- English is the only language this build ships
    local code = Config.Locale
    if code ~= nil and code ~= 'en' then
        out[#out + 1] = Line('warn', 'health.locale.not_en', { code = tostring(code) })
    end
    return out
end

-- ============================================================================
--                              AVATAR LINK HOSTS
-- ============================================================================

local function CheckAvatarHosts()
    local urls = Config.Profile and Config.Profile.avatarUrls
    if type(urls) ~= 'table' or urls.enabled ~= true then return { Line('ok', 'health.avatar.off') } end
    local hosts = type(urls.hosts) == 'table' and urls.hosts or {}
    local out, good = {}, 0
    for _, h in ipairs(hosts) do
        if type(h) ~= 'string' or not h:lower():match(HOST_PATTERN) then
            out[#out + 1] = Line('warn', 'health.avatar.bad_host', { host = tostring(h) })
        elseif EXPIRING_HOSTS[h:lower()] then
            out[#out + 1] = Line('warn', 'health.avatar.expiring', { host = h })
        else
            good = good + 1
        end
    end
    if good == 0 then
        table.insert(out, 1, Line('warn', 'health.avatar.no_hosts'))
    else
        table.insert(out, 1, Line('ok', 'health.avatar.ok', { n = good }))
    end
    if urls.requireApproval == false then out[#out + 1] = Line('warn', 'health.avatar.no_approval') end
    return out
end

-- ============================================================================
--                      DEPARTMENTS: QBOX JOBS AND GRADES
-- ============================================================================

-- A Qbox job's grades from the lowest: { { level, name|nil } }.
local function Grades(job)
    local out = {}
    for k, g in pairs(type(job.grades) == 'table' and job.grades or {}) do
        local level = math.tointeger(tonumber(k))
        if level then
            local name = type(g) == 'table' and type(g.name) == 'string' and g.name ~= '' and g.name or nil
            out[#out + 1] = { level = level, name = name }
        end
    end
    table.sort(out, function(a, b) return a.level < b.level end)
    return out
end

local function GradeText(g)
    if g.name then return ('%d %s'):format(g.level, g.name) end
    return tostring(g.level)
end

-- '0 Recruit, 1 Officer, 2 Sergeant' (at most MAX_LADDER grades)
local function Ladder(grades)
    local parts = {}
    for i, g in ipairs(grades) do
        if i > MAX_LADDER then
            parts[#parts + 1] = '...'
            break
        end
        parts[#parts + 1] = GradeText(g)
    end
    return table.concat(parts, ', ')
end

-- The line of one Qbox job a department lists: where its supervisorGrade falls on that job's grades.
local function GradeLine(d, job, vars, gradeSet)
    local grades = Grades(job)
    vars.ladder = Ladder(grades)
    if #grades == 0 or not gradeSet then return Line('ok', 'health.dept.job_ok', vars) end
    local at, first = tonumber(d.supervisorGrade), nil
    for _, g in ipairs(grades) do
        if g.level >= at then
            first = g
            break
        end
    end
    if not first then return Line('warn', 'health.dept.grade_high', vars) end
    if first == grades[1] and #grades > 1 then return Line('warn', 'health.dept.grade_all', vars) end
    vars.first = GradeText(first)
    return Line('ok', 'health.dept.ok', vars)
end

-- Every job a department lists must be a Qbox job, and its supervisorGrade must split that job's grades. A job
-- list that is empty and a supervisorGrade that is not a number are CP.Access's own start-up warnings.
local function CheckDepartments()
    local depts = CP.Access and CP.Access.departments and CP.Access.departments() or {}
    if #depts == 0 then return {} end
    local jobs = CP.Qbx and CP.Qbx.getJobs and CP.Qbx.getJobs() or {}
    if next(jobs) == nil then return { Line('warn', 'health.dept.no_jobs') } end
    local out = {}
    for _, d in ipairs(depts) do
        local raw = type(Config.Departments) == 'table' and Config.Departments[d.key] or nil
        local gradeSet = type(raw) == 'table' and tonumber(raw.supervisorGrade) ~= nil
            and tonumber(d.supervisorGrade) ~= nil
        local names = type(d.jobs) == 'table' and d.jobs or {}
        -- a missing job locks the department only when none of its other jobs exists either
        local known = 0
        for _, jobName in ipairs(names) do if type(jobs[jobName]) == 'table' then known = known + 1 end end
        for _, jobName in ipairs(names) do
            local vars = { dept = d.short or d.key, key = d.key, job = jobName, grade = d.supervisorGrade }
            if type(jobs[jobName]) == 'table' then
                out[#out + 1] = GradeLine(d, jobs[jobName], vars, gradeSet)
            else
                out[#out + 1] = Line('warn', known == 0 and 'health.dept.no_job' or 'health.dept.no_job_other', vars)
            end
        end
    end
    return out
end

-- ============================================================================
--                                    ADMINS
-- ============================================================================

local function PrincipalAllowed(principal, ace)
    local allowed = IsPrincipalAceAllowed(principal, ace)
    return allowed == true or allowed == 1
end

-- Whether Qbox's admin group can open the Admin UI: the one server.cfg line most owners need.
local function CheckAdmins()
    local ace = CP.Access and CP.Access.adminAce and CP.Access.adminAce() or 'crimsonpolice.admin'
    local qbox = CP.Access and CP.Access.qboxAdminAce and CP.Access.qboxAdminAce() or nil
    if not IsPrincipalAceAllowed then return { Line('ok', 'health.admin.unchecked', { ace = ace }) } end
    if PrincipalAllowed(QBOX_ADMIN_GROUP, ace) then return { Line('ok', 'health.admin.ace', { ace = ace }) } end
    if qbox and PrincipalAllowed(QBOX_ADMIN_GROUP, qbox) then return { Line('ok', 'health.admin.qbox') } end
    return { Line('warn', 'health.admin.none', { ace = ace }) }
end

-- ============================================================================
--                        THE FOLDER AND OTHER RESOURCES
-- ============================================================================

-- Everything inside follows a renamed folder (GetCurrentResourceName); only names written outside it cannot. Of
-- those, only the tablet item's export line is part of this stack, so a rename warns only while the item is set.
local function CheckFolder()
    local name = tostring(CP.resource)
    if name == RESOURCE_NAME then return { Line('ok', 'health.folder.ok', { name = name }) } end
    local vars = { name = name, expected = RESOURCE_NAME }
    local item = Config.Tablet and Config.Tablet.item
    if type(item) == 'string' and item ~= '' then return { Line('warn', 'health.folder.renamed', vars) } end
    return { Line('ok', 'health.folder.renamed_no_item', vars) }
end

local function Running(name)
    local state = GetResourceState(name)
    return state == 'started' or state == 'starting'
end

local function CheckResources()
    local out = {}
    for _, r in ipairs(OPTIONAL_RESOURCES) do
        if Running(r.name) then
            out[#out + 1] = Line('ok', 'health.res.on', { name = r.name })
        elseif r.warn then
            out[#out + 1] = Line('warn', r.warn, { name = r.name })
        else
            out[#out + 1] = Line('ok', 'health.res.off', { name = r.name })
        end
    end
    return out
end

-- ============================================================================
--                               DISCORD WEBHOOKS
-- ============================================================================

local function CheckWebhooks()
    if not (CP.Admin and CP.Admin.webhooks) then return {} end
    local on, off, out = {}, {}, {}
    for _, w in ipairs(CP.Admin.webhooks()) do
        if w.state == 'on' then
            on[#on + 1] = w.category
        elseif w.state == 'invalid' then
            out[#out + 1] = Line('warn', 'health.webhook.invalid', { convar = w.convar })
        else
            off[#off + 1] = w.category
        end
    end
    local none = CP.L('health.webhook.none')
    table.insert(out, 1, Line('ok', 'health.webhook.summary', {
        on = #on > 0 and table.concat(on, ', ') or none,
        off = #off > 0 and table.concat(off, ', ') or none,
    }))
    return out
end

Health.register('items', CheckItems)
Health.register('desks', CheckDesks)
Health.register('colours', CheckColours)
Health.register('tweaks', CheckTweaks)
Health.register('locale', CheckLocale)
Health.register('avatars', CheckAvatarHosts)
Health.register('departments', CheckDepartments)
Health.register('admins', CheckAdmins)
Health.register('folder', CheckFolder)
Health.register('resources', CheckResources)
Health.register('webhooks', CheckWebhooks)

-- ============================================================================
--                                   CALLBACK
-- ============================================================================

CP.Net.callback('admin:getConfigHealth', function(src)
    if not (CP.Access and CP.Access.isAdmin and CP.Access.isAdmin(src)) then return nil, 'err.not_admin' end
    -- every call runs the checks again: the screen's "Check again" shows a fix at once
    return Health.run()
end, { rate = 2 })

CreateThread(function()
    Wait(START_DELAY_MS)
    -- a module that loads later than this file may not have registered yet: item rewards' lines come here too
    local rewards = CP.Rewards
    if type(rewards) == 'table' and type(rewards.health) == 'function' then
        Health.register('rewards', rewards.health)
    end
    -- the problems print one line each; then one line says how it went, so a clean start is visible too
    local n = { ok = 0, warn = 0, error = 0 }
    for _, item in ipairs(Health.run()) do n[item.level] = n[item.level] + 1 end
    local vars = { ok = n.ok, warn = n.warn, error = n.error, cmd = CmdName() }
    if n.warn + n.error > 0 then
        CP.warn(TAG, '%s', CP.L('health.startup_problems', vars))
    else
        print(('[crimson-police] %s'):format(CP.L('health.startup_ok', vars)))
    end
end)

-- Test hooks (not part of the contract).
Health._checks = function() return checks end
Health._reset = function() results = nil end

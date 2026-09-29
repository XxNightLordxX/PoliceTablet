-- modules/tablet/server.lua · CP.Tablet (server): sessions for the three UIs, toasts, live pushes,
-- the Admin UI opener and the department logo checks.
--
-- Owns the callback getSession, the action server:logoFailed and the server side of the client events
-- crimson-police:client:notify / client:push / client:openAdmin (docs/ARCHITECTURE.md §8.1).
--
-- Public API (docs/ARCHITECTURE.md §5.4)
--   callback getSession(args) -> Session (§9.2)
--       args = { ui = 'officer'|'supervisor'|'admin' (default 'officer'), silent = bool }
--       officer:    an officer (CP.Access.getOfficer) -> its errKey otherwise (err.not_police,
--                   err.not_on_duty, err.suspended, err.suspended_dispatch)
--       supervisor: an officer whose grade is at or above supervisorGrade, or an officer who is also
--                   an admin -> err.not_supervisor otherwise
--       admin:      the ace Config.AdminAce, on duty or not, police or not -> err.not_admin otherwise
--       roles = { officer, supervisor (= officer and (isSupervisor or admin)), admin }; officer is set
--       whenever the player qualifies as an officer (also in the Admin UI); theme = the department's
--       theme (Config.AdminTheme, validated, for the Admin UI); logo = the department logo, or nil for
--       the Admin UI, a department without a logo, or a logo file missing from logos/.
--       config = { missionTypes (key,label,points; by points), departments (key,label,short,primary),
--                  tiers (name, label = CP.Scaling.label(name), else CP.L('tier.<name>')), maxRecalcs, disputeWindowHours,
--                  periods, filters }, locale = CP.Locale.all(), serverTime = os.time().
--       Opening the Officer/Supervisor UI refreshes the stored rank/callsign (CP.Access.refreshOfficerRow);
--       silent = true (the theme fetch at login) skips that. nil fields arrive in the NUI as missing keys.
--   CP.Tablet.notify(src, kind, key, vars, opts) -> boolean
--       kind 'info'|'success'|'warning'|'error'; key/vars a locale key and its variables (translated on
--       the client); opts = { title = localeKey, duration = ms }
--   CP.Tablet.notifyMany(srcs, kind, key, vars)       the same toast for a list of players (deduplicated)
--   CP.Tablet.push(src, topic, data) -> boolean       NUI { type = 'push', topic, data } (vectors serialised)
--   CP.Tablet.openAdmin(src) -> ok, errKey            builds the admin session and opens the Admin UI
--       (client:openAdmin); err.not_admin, err.not_in_game (console). Called by modules/admin.
--   action server:logoFailed (deptKey | { department, url })   the NUI could not load a department logo:
--       one console warning per department (err.unknown_department for an unknown one).
-- At start every file-based department logo is checked with LoadResourceFile: one warning per missing
-- file, and that department's session carries no logo (no broken image in the NUI).

CP.Tablet = CP.Tablet or {}
local T = CP.Tablet
local TAG = 'tablet'

local UIS = { officer = true, supervisor = true, admin = true }
local KINDS = { info = true, success = true, warning = true, error = true }
local PERIODS = { 'weekly', 'monthly', 'season', 'alltime' }
local FILTER_EXTRAS = { 'unit', 'cross', 'department' }
local DEFAULT_THEME = { primary = '#a4161a', accent = '#e5383b', background = '#0b090a', surface = '#161a1d', text = '#f5f3f4' }
local THEME_KEYS = { 'primary', 'accent', 'background', 'surface' }

local missingLogo = {}         -- deptKey -> true when logos/<file> is not in the resource
local logoFailedWarned = {}    -- deptKey -> true once the NUI failure was reported
local themeWarned = {}

local function toSrc(src)
    local n = tonumber(src)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

-- ── session parts ───────────────────────────────────────────────────────────
local function adminTheme()
    local cfg = type(Config.AdminTheme) == 'table' and Config.AdminTheme or {}
    local out = {}
    for _, k in ipairs(THEME_KEYS) do
        if CP.U.isHexColour(cfg[k]) then
            out[k] = cfg[k]:lower()
        else
            out[k] = DEFAULT_THEME[k]
            if not themeWarned[k] then
                themeWarned[k] = true
                CP.warn(TAG, 'Config.AdminTheme.%s is not a 6-digit hex colour; using the Crimson-Police default %s', k, DEFAULT_THEME[k])
            end
        end
    end
    if CP.U.isHexColour(cfg.text) then
        out.text = cfg.text:lower()
    else
        out.text = CP.U.contrastText(out.background)
        if cfg.text ~= nil and not themeWarned.text then
            themeWarned.text = true
            CP.warn(TAG, 'Config.AdminTheme.text is not a 6-digit hex colour; picked %s for contrast', out.text)
        end
    end
    return out
end

local function missionTypes()
    local list = {}
    if type(Config.MissionTypes) == 'table' then
        for key, t in pairs(Config.MissionTypes) do
            if type(key) == 'string' and type(t) == 'table' then
                list[#list + 1] = {
                    key = key,
                    label = type(t.label) == 'string' and t.label or key,
                    points = tonumber(t.points) or 0,
                }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.points ~= b.points then return a.points < b.points end
        return a.key < b.key
    end)
    return list
end

-- Tier labels come from CP.Scaling.label (the one place that names tiers), the locale as a fallback.
local function tierLabel(name)
    if CP.Scaling and type(CP.Scaling.label) == 'function' then
        local ok, label = pcall(CP.Scaling.label, name)
        if ok and type(label) == 'string' and label ~= '' then return label end
    end
    return CP.L('tier.' .. name)
end

local function sessionConfig()
    local types = missionTypes()
    local depts = {}
    for _, d in ipairs(CP.Access.departments()) do
        depts[#depts + 1] = { key = d.key, label = d.label, short = d.short, primary = d.theme.primary }
    end
    local tiers = {}
    if type(Config.Scaling) == 'table' then
        for _, row in ipairs(Config.Scaling) do
            if type(row) == 'table' and type(row.tier) == 'string' then
                tiers[#tiers + 1] = { name = row.tier, label = tierLabel(row.tier) }
            end
        end
    end
    local filters = { 'overall' }
    for _, t in ipairs(types) do filters[#filters + 1] = t.key end
    for _, f in ipairs(FILTER_EXTRAS) do filters[#filters + 1] = f end
    local periods = {}
    for i, p in ipairs(PERIODS) do periods[i] = p end
    return {
        missionTypes = types,
        departments = depts,
        tiers = tiers,
        maxRecalcs = tonumber(Config.Route and Config.Route.maxRecalcs) or 0,
        disputeWindowHours = tonumber(Config.Disputes and Config.Disputes.windowHours) or 0,
        periods = periods,
        filters = filters,
    }
end

local function sessionLogo(dept)
    if not dept or type(dept.logo) ~= 'table' or not dept.logo.url then return nil end
    if missingLogo[dept.key] then return nil end
    local l = dept.logo
    return { url = l.url, watermark = l.watermark, opacity = l.opacity, size = l.size, grayscale = l.grayscale }
end

local function sessionOfficer(o)
    return {
        citizenid = o.citizenid,
        name = o.name,
        department = o.department,
        departmentLabel = o.departmentLabel,
        departmentShort = o.departmentShort,
        rank = o.rank,
        callsign = o.callsign,
        gradeLevel = o.gradeLevel,
    }
end

-- The Session (§9.2) for 'ui', or nil and an error key. May yield.
local function buildSession(src, ui)
    if not CP.Access then return nil, 'err.internal' end
    local isAdmin = CP.Access.isAdmin(src)
    local officer, officerErr = CP.Access.getOfficer(src)
    local roles = {
        officer = officer ~= nil,
        supervisor = officer ~= nil and (officer.isSupervisor == true or isAdmin),
        admin = isAdmin,
    }
    if ui == 'officer' then
        if not officer then return nil, officerErr or 'err.not_police' end
    elseif ui == 'supervisor' then
        if not officer then return nil, officerErr or 'err.not_police' end
        if not roles.supervisor then return nil, 'err.not_supervisor' end
    elseif ui == 'admin' then
        if not isAdmin then return nil, 'err.not_admin' end
    else
        return nil, 'err.invalid_ui'
    end

    local theme, logo
    if ui == 'admin' then
        theme = adminTheme()
    else
        local dept = CP.Access.department(officer.department)
        theme = dept and dept.theme or CP.U.copy(DEFAULT_THEME)
        logo = sessionLogo(dept)
    end
    local actions = {}
    if CP.Permissions and CP.Permissions.actionsFor then actions = CP.Permissions.actionsFor(src) end
    local title = Config.Tablet and Config.Tablet.title
    return {
        ui = ui,
        title = type(title) == 'string' and title ~= '' and title or 'Crimson-Police',
        roles = roles,
        officer = officer and sessionOfficer(officer) or nil,
        theme = theme,
        logo = logo,
        actions = actions,
        locale = CP.Locale.all(),
        config = sessionConfig(),
        serverTime = os.time(),
    }
end

CP.Net.callback('getSession', function(src, args)
    if args ~= nil and type(args) ~= 'table' then return nil, 'err.invalid_payload' end
    local ui = args and args.ui
    if ui == nil then ui = 'officer' end
    if type(ui) ~= 'string' or not UIS[ui] then return nil, 'err.invalid_ui' end
    local session, errKey = buildSession(src, ui)
    if not session then
        CP.log(TAG, 'getSession %s for %s refused: %s', ui, tostring(src), tostring(errKey))
        return nil, errKey
    end
    if ui ~= 'admin' and not (args and args.silent == true) then
        CreateThread(function() CP.Access.refreshOfficerRow(src) end)
    end
    return session
end, { rate = 4 })

-- ── client helpers ──────────────────────────────────────────────────────────
function T.notify(src, kind, key, vars, opts)
    local n = toSrc(src)
    if not n or type(key) ~= 'string' or key == '' then return false end
    if not KINDS[kind] then kind = 'info' end
    if type(opts) ~= 'table' then opts = {} end
    local duration = tonumber(opts.duration)
    TriggerClientEvent(CP.e('client:notify'), n, {
        kind = kind,
        key = key,
        vars = type(vars) == 'table' and CP.U.serialize(vars) or nil,
        title = type(opts.title) == 'string' and opts.title ~= '' and opts.title or nil,
        duration = duration and math.floor(duration) or nil,
    })
    return true
end

function T.notifyMany(srcs, kind, key, vars)
    if type(srcs) ~= 'table' then return 0 end
    local seen, sent = {}, 0
    for _, src in ipairs(srcs) do
        local n = toSrc(src)
        if n and not seen[n] then
            seen[n] = true
            if T.notify(n, kind, key, vars) then sent = sent + 1 end
        end
    end
    return sent
end

function T.push(src, topic, data)
    local n = toSrc(src)
    if not n or type(topic) ~= 'string' or topic == '' then return false end
    TriggerClientEvent(CP.e('client:push'), n, topic, CP.U.serialize(data))
    return true
end

local function openAdminNow(src)
    local session, errKey = buildSession(src, 'admin')
    if not session then
        T.notify(src, 'error', errKey or 'err.not_admin')
        return false, errKey or 'err.not_admin'
    end
    TriggerClientEvent(CP.e('client:openAdmin'), src, session)
    CP.log(TAG, 'Admin UI opened for %d', src)
    return true
end

function T.openAdmin(src)
    local n = toSrc(src)
    if not n then
        CP.warn(TAG, 'the Admin UI can only be opened in game')
        return false, 'err.not_in_game'
    end
    if coroutine.isyieldable() then return openAdminNow(n) end
    CreateThread(function() openAdminNow(n) end)
    return true
end

-- ── logos ───────────────────────────────────────────────────────────────────
CP.Net.action('server:logoFailed', function(src, payload)
    local deptKey, url
    if type(payload) == 'string' then
        deptKey = payload
    elseif type(payload) == 'table' then
        if type(payload.department) == 'string' then deptKey = payload.department end
        if type(payload.url) == 'string' then url = payload.url:sub(1, 512) end
    else
        return false, 'err.invalid_payload'
    end
    if deptKey and #deptKey > 32 then return false, 'err.invalid_payload' end
    local dept = deptKey and CP.Access.department(deptKey) or nil
    if not dept and url then
        for _, d in ipairs(CP.Access.departments()) do
            if d.logo and d.logo.url == url then dept = d break end
        end
    end
    if not dept then return false, 'err.unknown_department' end
    if not logoFailedWarned[dept.key] then
        logoFailedWarned[dept.key] = true
        CP.warn(TAG, 'Department %s: the tablet could not load its logo %s (reported by player %d). Check %s; the tablet shows no watermark for it.',
            dept.key, tostring(dept.logo and dept.logo.url), src,
            dept.logo and dept.logo.file and ('logos/' .. dept.logo.file) or 'logo.url in Config.Departments')
    end
    return true
end, { rate = 2 })

-- Check every file-based logo once at start (at runtime, when CP.Access is loaded).
CreateThread(function()
    if not CP.Access then
        CP.err(TAG, 'modules/access is missing: the tablet cannot build sessions')
        return
    end
    local warnedFile = {}
    for _, dept in ipairs(CP.Access.departments()) do
        local file = dept.logo and dept.logo.file
        if file then
            local data = LoadResourceFile(CP.resource, 'logos/' .. file)
            if not data or data == '' then
                missingLogo[dept.key] = true
                if not warnedFile[file] then
                    warnedFile[file] = true
                    CP.warn(TAG, 'Department %s: logos/%s is missing; its tablet shows no logo or watermark until the file is added and the resource restarted',
                        dept.key, file)
                end
            end
        end
    end
end)

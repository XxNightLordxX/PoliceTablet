-- CP.Tablet (server): sessions for the three UIs, toasts, live pushes, the Admin UI opener and the department logo
-- checks.

CP.Tablet = CP.Tablet or {}
local T = CP.Tablet
local TAG = 'tablet'

local UIS = { officer = true, supervisor = true, admin = true }
local KINDS = { info = true, success = true, warning = true, error = true }
local PERIODS = { 'weekly', 'monthly', 'season', 'alltime' }
local FILTER_EXTRAS = { 'unit', 'cross', 'department' }
local DEFAULT_THEME = {
    primary = '#a4161a',
    accent = '#e5383b',
    background = '#0b090a',
    surface = '#161a1d',
    text = '#f5f3f4',
}
local THEME_KEYS = { 'primary', 'accent', 'background', 'surface' }
local VIA = { command = true, keybind = true, item = true, export = true, desk = true, dispatch = true }
local AVATAR_KINDS = { initials = true, preset = true, url = true }
local DEFAULT_APPEARANCE = 'department'

local missingLogo = {}         -- deptKey -> true when logos/<file> is not in the resource
local logoFailedWarned = {}    -- deptKey -> true once the NUI failure was reported
local themeWarned = {}

local function ToSrc(src)
    local n = tonumber(src)
    if not n then return nil end
    n = math.tointeger(n)
    if not n or n <= 0 then return nil end
    return n
end

-- ============================================================================
--                                SESSION PARTS
-- ============================================================================

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
                CP.warn(TAG, 'Config.AdminTheme.%s is not a 6-digit hex colour; using the Crimson-Police default %s', k,
                    DEFAULT_THEME[k])
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
local function TierLabel(name)
    if CP.Scaling and type(CP.Scaling.label) == 'function' then
        local ok, label = pcall(CP.Scaling.label, name)
        if ok and type(label) == 'string' and label ~= '' then return label end
    end
    return CP.L('tier.' .. name)
end

local function NumOr(v, default)
    local n = tonumber(v)
    if n == nil or n ~= n then return default end
    return n
end

-- Accents of a department theme (theme.personalAccents): '#rrggbb' or { colour, level }.
local function Accents(deptKey)
    local d = deptKey and Config.Departments and Config.Departments[deptKey]
    local list = type(d) == 'table' and type(d.theme) == 'table' and d.theme.personalAccents or nil
    local out = {}
    for _, a in ipairs(type(list) == 'table' and list or {}) do
        local colour = type(a) == 'table' and a.colour or a
        if CP.U.isHexColour(colour) then
            out[#out + 1] = { colour = colour:lower(), level = type(a) == 'table' and tonumber(a.level) or nil }
        end
    end
    return out
end

local function ProfileConfig(deptKey)
    local p = Config.Profile or {}
    local presets = {}
    for _, e in ipairs(type(p.avatarPresets) == 'table' and p.avatarPresets or {}) do
        if type(e) == 'table' and type(e.id) == 'string' then
            presets[#presets + 1] = { id = e.id, level = tonumber(e.level) }
        end
    end
    local scale = type(p.uiScale) == 'table' and p.uiScale or {}
    local appearances = {}
    for _, a in ipairs(type(p.appearances) == 'table' and p.appearances or { DEFAULT_APPEARANCE }) do
        if type(a) == 'string' then appearances[#appearances + 1] = a end
    end
    return {
        bioMax = math.floor(NumOr(p.bioMax, 280)),
        bioLines = math.floor(NumOr(p.bioLines, 3)),
        presets = presets,
        urls = type(p.avatarUrls) == 'table' and p.avatarUrls.enabled == true or false,
        appearances = appearances,
        accents = Accents(deptKey),
        uiScale = { NumOr(scale[1], 0.85), NumOr(scale[2], 1.25), NumOr(scale[3], 1.0) },
    }
end

-- The parity-plus parts of Session.config (web/src/shared/types.ts). English is the only language shipped.
local function ExtraConfig(deptKey)
    local mc = Config.MissionCalls or {}
    local areas = {}
    for _, a in ipairs(type(mc.areas) == 'table' and mc.areas or {}) do
        if type(a) == 'table' and type(a.key) == 'string' then
            areas[#areas + 1] = { key = a.key, label = type(a.label) == 'string' and a.label or a.key }
        end
    end
    local metrics = {}
    local lb = Config.Leaderboard or {}
    for _, m in ipairs(type(lb.metrics) == 'table' and lb.metrics or { 'points' }) do
        if type(m) == 'string' then metrics[#metrics + 1] = m end
    end
    local kinds = {}
    local cm = Config.Commendations or {}
    if cm.enabled ~= false then
        for _, k in ipairs(type(cm.kinds) == 'table' and cm.kinds or {}) do
            if type(k) == 'string' then kinds[#kinds + 1] = k end
        end
    end
    local fmt = Config.Format or {}
    return {
        dispatch = { enabled = mc.enabled ~= false, areas = areas },
        leaderboardMetrics = metrics,
        languages = { { code = 'en', label = 'English' } },
        profile = ProfileConfig(deptKey),
        commendationKinds = kinds,
        rewards = { enabled = Config.Rewards and Config.Rewards.enabled == true or false },
        format = {
            currency = type(fmt.currency) == 'string' and fmt.currency or '$',
            currencyAfter = fmt.currencyAfter == true,
        },
    }
end

local function Initials(name)
    local out = {}
    for word in tostring(name or ''):gmatch('[^%s]+') do
        if #out < 2 then out[#out + 1] = word:sub(1, 1):upper() end
    end
    return #out > 0 and table.concat(out) or '?'
end

-- The officer's cp_officers row: XP, avatar and look (one read; nil when there is none yet).
local function ReadProfile(citizenid)
    if type(citizenid) ~= 'string' or citizenid == '' then return nil end
    if CP.Migrations and CP.Migrations.ready then CP.Migrations.ready() end
    local ok, row = pcall(MySQL.single.await, [[
        SELECT xp, avatar_kind, avatar_value, avatar_status, appearance, accent, ui_scale, language, calls_muted
        FROM cp_officers WHERE citizenid = ?
    ]], { citizenid })
    if not ok then
        CP.err(TAG, 'reading the profile of %s failed: %s', citizenid, tostring(row))
        return nil
    end
    return type(row) == 'table' and row or nil
end

local function LevelOf(xp)
    if CP.Scoring and CP.Scoring.xpLevel then
        local ok, lv = pcall(CP.Scoring.xpLevel, xp)
        if ok and type(lv) == 'table' then
            return {
                n = tonumber(lv.n) or 1,
                label = lv.label or '',
                badge = lv.badge or 'grey',
                xp = math.floor(NumOr(xp, 0)),
                levelXp = tonumber(lv.levelXp) or 0,
                nextLevelXp = tonumber(lv.nextLevelXp),
                prestige = tonumber(lv.prestige) or 0,
            }
        end
    end
    return {
        n = 1,
        label = '',
        badge = 'grey',
        xp = math.floor(NumOr(xp, 0)),
        levelXp = 0,
        nextLevelXp = nil,
        prestige = 0,
    }
end

-- The picture everyone sees: an approved link or a preset, else the initials; frame = the level badge.
local function AvatarOf(officer, row, level)
    local kind = row and AVATAR_KINDS[row.avatar_kind] and row.avatar_kind or 'initials'
    local value = row and type(row.avatar_value) == 'string' and row.avatar_value ~= '' and row.avatar_value or nil
    if kind == 'url' and not (value and row.avatar_status == 'approved') then kind, value = 'initials', nil end
    if kind == 'preset' and not value then kind = 'initials' end
    if kind == 'initials' then value = nil end
    return { kind = kind, value = value, initials = Initials(officer and officer.name), frame = level.badge }
end

local function PrefsOf(row)
    local p = Config.Profile or {}
    local scale = type(p.uiScale) == 'table' and p.uiScale or {}
    local lo, hi, default = NumOr(scale[1], 0.85), NumOr(scale[2], 1.25), NumOr(scale[3], 1.0)
    local uiScale = row and tonumber(row.ui_scale) or default
    if uiScale < lo or uiScale > hi then uiScale = default end
    return {
        appearance = row and type(row.appearance) == 'string' and row.appearance or DEFAULT_APPEARANCE,
        accent = row and CP.U.isHexColour(row.accent) and row.accent:lower() or nil,
        uiScale = uiScale,
        language = row and type(row.language) == 'string' and row.language or nil,
        callsMuted = row ~= nil and CP.U.truthy(row.calls_muted) or false,
    }
end

local function SessionConfig()
    local types = missionTypes()
    local depts = {}
    for _, d in ipairs(CP.Access.departments()) do
        depts[#depts + 1] = { key = d.key, label = d.label, short = d.short, primary = d.theme.primary }
    end
    local tiers = {}
    if type(Config.Scaling) == 'table' then
        for _, row in ipairs(Config.Scaling) do
            if type(row) == 'table' and type(row.tier) == 'string' then
                tiers[#tiers + 1] = { name = row.tier, label = TierLabel(row.tier) }
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

local function SessionLogo(dept)
    if not dept or type(dept.logo) ~= 'table' or not dept.logo.url then return nil end
    if missingLogo[dept.key] then return nil end
    local l = dept.logo
    return { url = l.url, watermark = l.watermark, opacity = l.opacity, size = l.size, grayscale = l.grayscale }
end

local function SessionOfficer(o, row)
    local level = LevelOf(row and row.xp or 0)
    return {
        avatar = AvatarOf(o, row, level),
        level = level,
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

-- The Session (§9.2) for 'ui', or nil and an error key. May yield. args: { via, desk } (how it was opened).
local function BuildSession(src, ui, args)
    if not CP.Access then return nil, 'err.internal' end
    local isAdmin = CP.Access.isAdmin(src)
    local officer, officerErr = CP.Access.getOfficer(src)
    local roles = {
        officer = officer ~= nil,
        -- Supervisor is the job grade only (SPEC Roles); admins use the Admin UI.
        supervisor = officer ~= nil and officer.isSupervisor == true,
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
        logo = SessionLogo(dept)
    end
    local actions = {}
    if CP.Permissions and CP.Permissions.actionsFor then actions = CP.Permissions.actionsFor(src) end
    local title = Config.Tablet and Config.Tablet.title
    local row = officer and ReadProfile(officer.citizenid) or nil
    local config = SessionConfig()
    for k, v in pairs(ExtraConfig(officer and officer.department)) do config[k] = v end
    args = type(args) == 'table' and args or {}
    local via = VIA[args.via] and args.via or 'command'
    local desk = math.tointeger(tonumber(args.desk) or -1)
    return {
        ui = ui,
        title = type(title) == 'string' and title ~= '' and title or 'Crimson-Police',
        roles = roles,
        officer = officer and SessionOfficer(officer, row) or nil,
        theme = theme,
        logo = logo,
        actions = actions,
        locale = CP.Locale.all(),
        config = config,
        prefs = PrefsOf(row),
        access = { via = via, desk = (via == 'desk' and desk and desk > 0) and desk or nil },
        serverTime = os.time(),
    }
end

CP.Net.callback('getSession', function(src, args)
    if args ~= nil and type(args) ~= 'table' then return nil, 'err.invalid_payload' end
    local ui = args and args.ui
    if ui == nil then ui = 'officer' end
    if type(ui) ~= 'string' or not UIS[ui] then return nil, 'err.invalid_ui' end
    local session, errKey = BuildSession(src, ui, args)
    if not session then
        CP.log(TAG, 'getSession %s for %s refused: %s', ui, tostring(src), tostring(errKey))
        return nil, errKey
    end
    if ui ~= 'admin' and not (args and args.silent == true) then
        CreateThread(function() CP.Access.refreshOfficerRow(src) end)
    end
    return session
end, { rate = 4 })

-- ============================================================================
--                                CLIENT HELPERS
-- ============================================================================

function T.notify(src, kind, key, vars, opts)
    local n = ToSrc(src)
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
        local n = ToSrc(src)
        if n and not seen[n] then
            seen[n] = true
            if T.notify(n, kind, key, vars) then sent = sent + 1 end
        end
    end
    return sent
end

function T.push(src, topic, data)
    local n = ToSrc(src)
    if not n or type(topic) ~= 'string' or topic == '' then return false end
    TriggerClientEvent(CP.e('client:push'), n, topic, CP.U.serialize(data))
    return true
end

local function OpenAdminNow(src)
    local session, errKey = BuildSession(src, 'admin')
    if not session then
        T.notify(src, 'error', errKey or 'err.not_admin')
        return false, errKey or 'err.not_admin'
    end
    TriggerClientEvent(CP.e('client:openAdmin'), src, session)
    CP.log(TAG, 'Admin UI opened for %d', src)
    return true
end

function T.openAdmin(src)
    local n = ToSrc(src)
    if not n then
        CP.warn(TAG, 'the Admin UI can only be opened in game')
        return false, 'err.not_in_game'
    end
    if coroutine.isyieldable() then return OpenAdminNow(n) end
    CreateThread(function() OpenAdminNow(n) end)
    return true
end

-- ============================================================================
--                                    LOGOS
-- ============================================================================

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
        CP.warn(TAG,
            'Department %s: the tablet could not load its logo %s (reported by player %d). Check %s; the tablet shows no watermark for it.',
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
                    CP.warn(TAG,
                        'Department %s: logos/%s is missing; its tablet shows no logo or watermark until the file is added and the resource restarted',
                        dept.key, file)
                end
            end
        end
    end
end)
